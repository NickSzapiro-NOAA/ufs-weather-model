#!/usr/bin/env python3
"""
UFS Weather Model Regression Test Driver
Sets up, verifies, and dispatches parallel tests for multiple model hashes.
Includes built-in unit testing.
"""

import os
import sys
import subprocess
import urllib.request
import urllib.error
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch, MagicMock

# =====================================================================
# Core Functions
# =====================================================================

def verify_local_matches_remote(local_path: Path, repo_url: str, hash_val: str, rel_path: str) -> bool:
    """
    Verifies that a checked-out local file matches the remote file on GitHub at a specific hash.
    Uses GitHub's raw user content endpoint to avoid heavy git commands.
    """
    if not local_path.exists():
        print(f"Verification failed: Local file {local_path} does not exist.")
        return False

    # Convert https://github.com/org/repo.git to raw user content URL
    base_url = repo_url.replace('https://github.com/', 'https://raw.githubusercontent.com/')
    if base_url.endswith('.git'):
        base_url = base_url[:-4]
    
    raw_url = f"{base_url}/{hash_val}/{rel_path}"
    
    try:
        with urllib.request.urlopen(raw_url) as response:
            remote_content = response.read().decode('utf-8')
        
        local_content = local_path.read_text(encoding='utf-8')
        
        if remote_content == local_content:
            return True
        else:
            print(f"Verification failed: Mismatch in contents for {rel_path} at hash {hash_val}")
            return False
            
    except urllib.error.URLError as e:
        print(f"Verification failed: Could not fetch remote file at {raw_url}. {e}")
        return False

def write_test_instance(rt_base: str, test_out_path: Path):
    """Write a valid RT test that sources a base test."""
    s = f'''# from run_RTs_hashes.py : write_test_instance
source "${{PATHRT}}"/tests/{rt_base}

TEST_DESCR+=" copy instance"
'''
    test_out_path.write_text(s)
    # Only print if we aren't running in unittest mode
    if 'unittest' not in sys.modules:
        print(f'Wrote {test_out_path}')

def build_rt_conf_test(test_names: list) -> str:
    """Generate the rt.conf contents for compiling and running the tests."""
    s = '''# from run_RTs_hashes.py : build_rt_conf_test
COMPILE | s2s_32bit_sfs | intel | -DAPP=S2S -D32BIT=ON -DHYDRO=ON -DCCPP_SUITES=FV3_GFS_v17_coupled_p8_ugwpv1 -DUFS_TRACING=ON | - noaacloud derecho| fv3 |
RUN | cpld_control_sfs | - noaacloud  derecho                 | baseline |
'''
    for n in test_names:
        s += f'RUN | {n} | - noaacloud  derecho  |   | \n'
    return s
  
# =====================================================================
# Main Driver
# =====================================================================

def demo_driver(
    hashes=['f6b6c78', '6dc3648'], 
    rt_base='cpld_control_sfs', 
    n_inst=5,
    base_path='/scratch3/NCEPDEV/nems/Nick.Szapiro/tasks/cm_ufs/uwm_3315/'
):
    base_dir = Path(base_path)
    base_dir.mkdir(parents=True, exist_ok=True)
    repo_url = 'https://github.com/ufs-community/ufs-weather-model.git'
    
    # Clone a base UWM repository once to speed up local copies in the loop
    base_repo_path = base_dir / 'ufs-weather-model-base'
    if not base_repo_path.exists():
        print(f"Cloning base UWM repository from {repo_url}...")
        subprocess.run(['git', 'clone', repo_url, str(base_repo_path)], check=True)

    for hash_val in hashes:
        print(f"\n{'='*50}\nProcessing Hash: {hash_val}\n{'='*50}")
        
        dir_path = base_dir / f'uwm_{hash_val}'
        uwm_path = dir_path / 'ufs-weather-model'
        
        # Fast local clone to avoid hitting GitHub HTTP multiple times
        if not uwm_path.exists():
            dir_path.mkdir(parents=True, exist_ok=True)
            subprocess.run(['git', 'clone', '--local', str(base_repo_path), str(uwm_path)], check=True)

        print(f"Checking out {hash_val} and updating submodules...")
        subprocess.run(['git', 'checkout', hash_val], cwd=uwm_path, check=True)
        subprocess.run(['git', 'submodule', 'update', '--init', '--recursive', '-j', '5'], cwd=uwm_path, check=True)

        # Verification Step: Check a lightweight file against remote raw content
        test_file_rel = 'README.md' 
        local_test_file = uwm_path / test_file_rel
        
        is_match = verify_local_matches_remote(local_test_file, repo_url, hash_val, test_file_rel)
        if not is_match:
            print(f"CRITICAL ERROR: UWM Hash checkout failed verification for {hash_val}. Skipping run.")
            continue
        print(f"Success: Git checkout verified for {hash_val}.")

        # Create duplicated test instances
        tests_dir = uwm_path / 'tests' / 'tests'
        tests_dir.mkdir(parents=True, exist_ok=True)
        
        tests_nInst = []
        for n in range(n_inst):
            new_test = f'{rt_base}_{n}'
            new_test_path = tests_dir / new_test
            tests_nInst.append(new_test)
            write_test_instance(rt_base, new_test_path)
        
        # Set up my_rt.conf
        conf_str = build_rt_conf_test(tests_nInst)
        conf_file = uwm_path / 'tests' / 'my_rt.conf'
        conf_file.write_text(conf_str)
        print(f'my_rt.conf written to {conf_file}')

        # Submit rt.sh using ecflow manager (-e)
        tests_root = uwm_path / 'tests'
        cmd = 'nohup ./rt.sh -a nems -e -k -l my_rt.conf > rt_run.log 2>&1 &'
        
        print(f"Executing: {cmd}")
        subprocess.Popen(cmd, shell=True, cwd=tests_root)
        print(f"Job dispatched for {hash_val}. Logs tracking at {tests_root / 'rt_run.log'}")


# =====================================================================
# Unit Tests
# =====================================================================

class TestRTSetup(unittest.TestCase):

    def test_build_rt_conf_test(self):
        """Ensure rt.conf string is built correctly with dynamic tests."""
        test_names = ['cpld_control_sfs_0', 'cpld_control_sfs_1']
        conf_output = build_rt_conf_test(test_names)
        
        self.assertIn('COMPILE | s2s_32bit_sfs | intel', conf_output)
        self.assertIn('RUN | cpld_control_sfs | - noaacloud', conf_output)
        self.assertIn('RUN | cpld_control_sfs_0 |', conf_output)
        self.assertIn('RUN | cpld_control_sfs_1 |', conf_output)
        self.assertEqual(conf_output.count('RUN |'), 3)

    def test_write_test_instance(self):
        """Ensure test files are written with correct paths and variables."""
        rt_base = 'test_base_case'
        with tempfile.TemporaryDirectory() as tmpdir:
            out_path = Path(tmpdir) / 'test_out_0'
            write_test_instance(rt_base, out_path)
            
            self.assertTrue(out_path.exists())
            content = out_path.read_text()
            self.assertIn('source "${PATHRT}"/tests/test_base_case', content)
            self.assertIn('TEST_DESCR+=" copy instance"', content)

    @patch('urllib.request.urlopen')
    def test_verify_local_matches_remote(self, mock_urlopen):
        """Test GitHub hash verification logic without hitting the network."""
        repo_url = 'https://github.com/ufs-community/ufs-weather-model.git'
        hash_val = 'f6b6c78'
        rel_path = 'README.md'
        fake_content = "UFS Weather Model README content"
        
        mock_response = MagicMock()
        mock_response.read.return_value = fake_content.encode('utf-8')
        mock_response.__enter__.return_value = mock_response
        mock_urlopen.return_value = mock_response
        
        with tempfile.TemporaryDirectory() as tmpdir:
            local_file = Path(tmpdir) / rel_path
            
            # Scenario 1: Exact Match
            local_file.write_text(fake_content)
            self.assertTrue(verify_local_matches_remote(local_file, repo_url, hash_val, rel_path))
            
            expected_url = f"https://raw.githubusercontent.com/ufs-community/ufs-weather-model/{hash_val}/{rel_path}"
            mock_urlopen.assert_called_with(expected_url)
            
            # Scenario 2: Content Mismatch
            local_file.write_text("Some incorrect git checkout content")
            self.assertFalse(verify_local_matches_remote(local_file, repo_url, hash_val, rel_path))

            # Scenario 3: Missing File
            os.remove(local_file)
            self.assertFalse(verify_local_matches_remote(local_file, repo_url, hash_val, rel_path))


if __name__ == '__main__':
    # If the --test flag is passed, execute the unit tests
    if len(sys.argv) > 1 and sys.argv[1] == '--test':
        sys.argv.pop(1)
        unittest.main()
    else:
        demo_driver()
