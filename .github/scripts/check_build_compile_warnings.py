#!/usr/bin/env python3
import os, sys, re, subprocess, glob

def get_changed_lines(repo_path, diff_args, path_prefix=""):
    """Recursively parses diffs, seamlessly traversing nested submodules and fork changes."""
    # diff_args is passed as a list so we can dynamically swap between "A...B" and "A" "B"
    cmd = ["git", "-C", repo_path, "diff", "--unified=0"] + diff_args
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    changed = {}
    current_file = None
    old_hash = None
    
    for line in result.stdout.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            changed[f"{path_prefix}{current_file}"] = set()
            
        elif line.startswith("@@ ") and current_file:
            m = re.search(r'\+([0-9]+)(?:,([0-9]+))?', line)
            if m:
                start = int(m.group(1))
                count = int(m.group(2)) if m.group(2) else 1
                for i in range(start, start + count):
                    changed[f"{path_prefix}{current_file}"].add(i)
                    
        # Submodule updates 
        elif line.startswith("-Subproject commit "):
            old_hash = line.split()[2]
        elif line.startswith("+Subproject commit ") and current_file and old_hash:
            new_hash = line.split()[2]
            sub_name = current_file 
            sub_path_full = os.path.join(repo_path, sub_name) if repo_path != "." else sub_name
            
            print(f"📦 Traversing nested submodule: '{path_prefix}{sub_name}'...")
            
            subprocess.run(["git", "-C", repo_path, "submodule", "update", "--init", sub_name], capture_output=True)
            
            old_url, new_url = "", ""
            
            # Use diff_args[0].split("...")[0] to grab the base reference for the old .gitmodules
            base_ref_for_gm = diff_args[0].split("...")[0] if "..." in diff_args[0] else old_hash
            
            old_gm = subprocess.run(["git", "-C", repo_path, "show", f"{base_ref_for_gm}:.gitmodules"], capture_output=True, text=True)
            if old_gm.returncode == 0:
                temp_old = os.path.join(repo_path, ".gitmodules_old_temp")
                with open(temp_old, "w") as f: f.write(old_gm.stdout)
                url_cmd = subprocess.run(["git", "config", "--file", temp_old, f"submodule.{sub_name}.url"], capture_output=True, text=True)
                old_url = url_cmd.stdout.strip()
            
            new_gm = subprocess.run(["git", "-C", repo_path, "show", "HEAD:.gitmodules"], capture_output=True, text=True)
            if new_gm.returncode == 0:
                temp_new = os.path.join(repo_path, ".gitmodules_new_temp")
                with open(temp_new, "w") as f: f.write(new_gm.stdout)
                url_cmd = subprocess.run(["git", "config", "--file", temp_new, f"submodule.{sub_name}.url"], capture_output=True, text=True)
                new_url = url_cmd.stdout.strip()
            
            if old_url:
                subprocess.run(["git", "-C", sub_path_full, "fetch", old_url, old_hash], capture_output=True)
            if new_url:
                subprocess.run(["git", "-C", sub_path_full, "fetch", new_url, new_hash], capture_output=True)
            
            # RECURSION: Pass the hashes as TWO SEPARATE items in the list for a direct tree comparison!
            sub_changed = get_changed_lines(sub_path_full, [old_hash, new_hash], f"{path_prefix}{sub_name}/")
            for filepath, lines in sub_changed.items():
                if filepath not in changed:
                    changed[filepath] = set()
                changed[filepath].update(lines)
            
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
    
    # 1. Main PR diff uses the three-dot syntax as a single string in the list
    changed_lines = get_changed_lines(".", [f"origin/{base_branch}...HEAD"])
    
    # 2. DEBUG PRINT: Show exactly what files and lines the script mapped
    print("\n--- DEBUG: MODIFIED FILES DETECTED ---")
    if not changed_lines:
        print("No modified code files found in diff.")
    for f, lines in changed_lines.items():
        print(f"  - {f} ({len(lines)} lines modified)")
    print("--------------------------------------\n")
    
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
  
