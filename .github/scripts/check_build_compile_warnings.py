#!/usr/bin/env python3
import os, sys, re, subprocess, glob

def get_changed_lines(base_ref):
    """Returns a dict of { 'filename': set(changed_line_numbers) } for the current PR."""
    cmd = ["git", "diff", "--unified=0", f"origin/{base_ref}...HEAD"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    
    changed = {}
    current_file = None
    old_hash = None
    
    for line in result.stdout.splitlines():
        # 1. Standard repository changes
        if line.startswith("+++ b/"):
            current_file = line[6:]
            changed[current_file] = set()
        elif line.startswith("@@ ") and current_file:
            m = re.search(r'\+([0-9]+)(?:,([0-9]+))?', line)
            if m:
                start = int(m.group(1))
                count = int(m.group(2)) if m.group(2) else 1
                for i in range(start, start + count):
                    changed[current_file].add(i)
                    
        # 2. Submodule updates! 
        elif line.startswith("-Subproject commit "):
            old_hash = line.split()[2]
        elif line.startswith("+Subproject commit ") and current_file and old_hash:
            new_hash = line.split()[2]
            sub_path = current_file
            
            print(f"📦 Detected submodule update in '{sub_path}'. Recursively tracking lines...")
            
            # Run git diff internally inside the submodule
            sub_cmd = ["git", "-C", sub_path, "diff", "--unified=0", f"{old_hash}...{new_hash}"]
            sub_result = subprocess.run(sub_cmd, capture_output=True, text=True)
            
            sub_file = None
            for sub_line in sub_result.stdout.splitlines():
                if sub_line.startswith("+++ b/"):
                    # Reconstruct the full path (e.g. CICE/src/ice_domain.F90)
                    sub_file = f"{sub_path}/{sub_line[6:]}"
                    changed[sub_file] = set()
                elif sub_line.startswith("@@ ") and sub_file:
                    m = re.search(r'\+([0-9]+)(?:,([0-9]+))?', sub_line)
                    if m:
                        start = int(m.group(1))
                        count = int(m.group(2)) if m.group(2) else 1
                        for i in range(start, start + count):
                            changed[sub_file].add(i)
            
            # Reset the hash tracker for the next submodule
            old_hash = None 

    return changed

def parse_spack_logs(log_dir):
    """Parses Spack build logs to find warnings and strips staging paths."""
    warnings = []
    log_files = []
    
    # 1. Replicate the bash 'find' command to catch all build-out files, regardless of extension
    for root, _, files in os.walk(log_dir):
        for file in files:
            if "build-out" in file:
                log_files.append(os.path.join(root, file))
                
    print(f"🔍 Found {len(log_files)} Spack log files to parse.")
    
    for filepath in log_files:
        with open(filepath, 'r', errors='replace') as f:
            current_file, current_line = None, None
            
            for line in f:
                # 1. Match ANY absolute file path that ends in a source extension and has a line number
                loc_match = re.search(r'(/.*?\.(?:F90|f90|F|f|c|cpp|h))(?::|\()([0-9]+)[:\)]', line, re.IGNORECASE)
                
                if loc_match:
                    raw_path = loc_match.group(1)
                    current_line = int(loc_match.group(2))
                    
                    # Clean the path to make it relative to the git repo root
                    current_file = raw_path
                    for marker in ['spack-devpkg-ufs-weather-model/', 'spack-src/', 'ufs-weather-model/']:
                        if marker in current_file:
                            current_file = current_file.split(marker)[-1]
                            break
                            
                    current_file = current_file.strip()
                    
                    # Intel compiler often prints warning on the same line as the path
                    if 'warning' in line.lower(): 
                        warnings.append({'file': current_file, 'line': current_line, 'msg': line.strip()})
                        current_file, current_line = None, None
                    continue
                
                # 2. Match GNU multiline warnings (e.g. "Warning: Possible change...")
                if current_file and current_line and re.search(r'^[Ww]arning:', line.strip()):
                    warnings.append({
                        'file': current_file,
                        'line': current_line,
                        'msg': line.strip()
                    })
                    # Reset context to avoid attaching future warnings to the wrong line
                    current_file, current_line = None, None 
                    
    return warnings

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 check_build_compile_warnings.py <path_to_spack_logs>")
        sys.exit(1)
        
    log_directory = sys.argv[1]
    base_branch = "develop"
    
    print(f"Checking diff against origin/{base_branch}...")
    changed_lines = get_changed_lines(base_branch)
    all_warnings = parse_spack_logs(log_directory)
    
    # 1. Save the full list of legacy warnings to a file for monitoring
    with open("all_compiler_warnings.txt", "w") as f:
        for w in all_warnings:
            # This ONLY writes to the artifact text file, it does not print to the screen
            f.write(f"{w['file']}:{w['line']} {w['msg']}\n")
    
    new_warnings = []
    for w in all_warnings:
        if w['file'] in changed_lines and w['line'] in changed_lines[w['file']]:
            new_warnings.append(w)
            
    # 2. Write a native Markdown summary to the GitHub Actions UI
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as summary:
            summary.write("## 🛠️ Compiler Warnings Report\n\n")
            summary.write(f"**Total Warnings in Codebase:** {len(all_warnings)}\n")
            summary.write(f"**New Warnings Introduced:** {len(new_warnings)}\n\n")
            summary.write("> *Download `all_compiler_warnings.txt` from the artifacts below to see the full legacy list.*\n")

    # 3. Handle the PR outcome
    if not new_warnings:
        print(f"Success! System has {len(all_warnings)} legacy warnings, but ZERO new warnings.")
        sys.exit(0)
        
    print(f"FAILED: Found {len(new_warnings)} new warnings introduced in this PR!\n")
    for w in new_warnings:
        # 1. Print a human-readable version so developers can read the raw text logs
        print(f"File: {w['file']} | Line: {w['line']}")
        print(f"Message: {w['msg']}\n")
        
        # 2. Native GitHub inline PR comment (GitHub intercepts this specific syntax)
        print(f"::error file={w['file']},line={w['line']}::{w['msg']}")
        
    sys.exit(1)
