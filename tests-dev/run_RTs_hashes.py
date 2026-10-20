#!/usr/bin/env python3
"""
UFS Weather Model Regression Test & Metrics Driver
- driver_rtconf: Sets up and dispatches parallel tests for multiple model hashes.
- driver_slurm_metrics: Queries and parses Slurm 'sacct' for performance metrics.
Includes built-in unit tests for all components.
"""

import os
import sys
import subprocess
import urllib.request
import urllib.error
import unittest
import tempfile
import datetime
from pathlib import Path
from unittest.mock import patch, MagicMock

# =====================================================================
# RT Setup Functions
# =====================================================================

def verify_local_matches_remote(local_path: Path, repo_url: str, hash_val: str, rel_path: str) -> bool:
    """Verifies that a checked-out local file matches the remote file on GitHub."""
    if not local_path.exists():
        return False

    base_url = repo_url.replace('https://github.com/', 'https://raw.githubusercontent.com/')
    if base_url.endswith('.git'):
        base_url = base_url[:-4]
    
    raw_url = f"{base_url}/{hash_val}/{rel_path}"
    
    try:
        with urllib.request.urlopen(raw_url) as response:
            remote_content = response.read().decode('utf-8')
        local_content = local_path.read_text(encoding='utf-8')
        return remote_content == local_content
    except urllib.error.URLError:
        return False

def write_test_instance(rt_base: str, test_out_path: Path):
    """Write a valid RT test that sources a base test."""
    s = f'''# from run_RTs_hashes.py : write_test_instance
source "${{PATHRT}}"/tests/{rt_base}

TEST_DESCR+=" copy instance"
'''
    test_out_path.write_text(s)

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
# Slurm Metrics Functions
# =====================================================================

def get_sacct_output(hours_lookback: int) -> str:
    """Executes the sacct command and returns the raw stdout."""
    start_time = (datetime.datetime.now() - datetime.timedelta(hours=hours_lookback)).strftime('%Y-%m-%dT%H:%M:%S')
    user = os.environ.get('USER', '')
    
    cmd = [
        'sacct',
        '-u', user,
        '-S', start_time,
        '--format=JobID,JobName,State,Elapsed,TotalCPU,MaxRSS',
        '--parsable2',  # Pipe-separated, no trailing pipe
        '-X'            # Main allocations only
    ]
    
    try:
        return subprocess.check_output(cmd, text=True)
    except FileNotFoundError:
        raise RuntimeError("ERROR: 'sacct' command not found. Are you on a Slurm login node?")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"ERROR: Failed to query Slurm: {e}")

def parse_slurm_metrics(raw_output: str, filter_str: str = None) -> list:
    """Parses pipe-separated sacct output into a list of dictionaries."""
    lines = raw_output.strip().split('\n')
    if not lines or len(lines) <= 1:
        return []

    headers = [h.strip() for h in lines[0].split('|')]
    parsed_jobs = []
    
    for line in lines[1:]:
        parts = [p.strip() for p in line.split('|')]
        if len(parts) == len(headers):
            job_dict = dict(zip(headers, parts))
            if filter_str and filter_str not in job_dict.get('JobName', ''):
                continue
            parsed_jobs.append(job_dict)
            
    return parsed_jobs

# =====================================================================
# Drivers
# =====================================================================

def driver_slurm_metrics(hours_lookback: int = 24, filter_str: str = 'cpld_control'):
    """Driver to fetch, parse, and print Slurm performance metrics."""
    print(f"Querying Slurm accounting (past {hours_lookback}h, filtering by '{filter_str}')...\n")
    
    try:
        raw_output = get_sacct_output(hours_lookback)
    except RuntimeError as e:
        print(e)
        return

    jobs = parse_slurm_metrics(raw_output, filter_str)
    
    if not jobs:
        print("No matching jobs found in the specified timeframe.")
        return

    print(f"{'JobID':<12} | {'JobName':<25} | {'State':<15} | {'Elapsed':<12} | {'TotalCPU':<12} | {'MaxRSS':<12}")
    print("-" * 100)
    for j in jobs:
        print(f"{j.get('JobID',''):<12} | {j.get('JobName','')[:25]:<25} | {j.get('State',''):<15} | "
              f"{j.get('Elapsed',''):<12} | {j.get('TotalCPU',''):<12} | {j.get('MaxRSS',''):<12}")

def driver_rtconf(
    hashes=['f6b6c78', '6dc3648'], 
    rt_base='cpld_control_sfs', 
    n_inst=5,
    base_path='/scratch3/NCEPDEV/nems/Nick.Szapiro/tasks/cm_ufs/uwm_3315/'
):
    """Driver to set up workspaces and dispatch UWM tests."""
    base_dir = Path(base_path)
    base_dir.mkdir(parents=True, exist_ok=True)
    repo_url = 'https://github.com/ufs-community/ufs-weather-model.git'
    
    base_repo_path = base_dir / 'ufs-weather-model-base'
    if not base_repo_path.exists():
        print(f"Cloning base UWM repository from {repo_url}...")
        subprocess.run(['git', 'clone', repo_url, str(base_repo_path)], check=True)

    for hash_val in hashes:
        print(f"\n{'='*50}\nProcessing Hash: {hash_val}\n{'='*50}")
        dir_path = base_dir / f'uwm_{hash_val}'
        uwm_path = dir_path / 'ufs-weather-model'
        
        if not uwm_path.exists():
            dir_path.mkdir(parents=True, exist_ok=True)
            subprocess.run(['git', 'clone', '--local', str(base_repo_path), str(uwm_path)], check=True)

        print(f"Checking out {hash_val} and updating submodules...")
        subprocess.run(['git', 'checkout', hash_val], cwd=uwm_path, check=True)
        subprocess.run(['git', 'submodule', 'update', '--init', '--recursive', '-j', '5'], cwd=uwm_path, check=True)

        test_file_rel = 'README.md' 
        is_match = verify_local_matches_remote(uwm_path / test_file_rel, repo_url, hash_val, test_file_rel)
        if not is_match:
            print(f"CRITICAL ERROR: Checkout failed verification for {hash_val}. Skipping.")
            continue

        tests_dir = uwm_path / 'tests' / 'tests'
        tests_dir.mkdir(parents=True, exist_ok=True)
        
        tests_nInst = []
        for n in range(n_inst):
            new_test = f'{rt_base}_{n}'
            tests_nInst.append(new_test)
            write_test_instance(rt_base, tests_dir / new_test)
        
        conf_file = uwm_path / 'tests' / 'my_rt.conf'
        conf_file.write_text(build_rt_conf_test(tests_nInst))

        tests_root = uwm_path / 'tests'
        cmd = 'nohup ./rt.sh -a nems -e -k -l my_rt.conf > rt_run.log 2>&1 &'
        
        print(f"Executing: {cmd}")
        subprocess.Popen(cmd, shell=True, cwd=tests_root)
        print(f"Job dispatched for {hash_val}. Logs tracking at {tests_root / 'rt_run.log'}")

# =====================================================================
# Unit Tests
# =====================================================================

class TestSlurmInterface(unittest.TestCase):
    def setUp(self):
        # Fake output identical to what `sacct --parsable2` returns
        self.mock_sacct_output = (
            "JobID|JobName|State|Elapsed|TotalCPU|MaxRSS\n"
            "12345|cpld_control_sfs_0|COMPLETED|00:45:12|12:30:00|14500K\n"
            "12346|cpld_control_sfs_1|RUNNING|00:15:00|04:10:00|\n"
            "12347|other_random_job|FAILED|00:01:00|00:00:10|500K"
        )

    @patch('subprocess.check_output')
    def test_get_sacct_output_success(self, mock_subproc):
        """Ensure sacct command is formatted correctly and executed."""
        mock_subproc.return_value = self.mock_sacct_output
        result = get_sacct_output(hours_lookback=2)
        self.assertEqual(result, self.mock_sacct_output)
        
        # Verify the subprocess call arguments
        called_args = mock_subproc.call_args[0][0]
        self.assertEqual(called_args[0], 'sacct')
        self.assertIn('--parsable2', called_args)

    @patch('subprocess.check_output')
    def test_get_sacct_output_missing_slurm(self, mock_subproc):
        """Ensure clear error is raised when sacct is not in PATH."""
        mock_subproc.side_effect = FileNotFoundError()
        with self.assertRaisesRegex(RuntimeError, "sacct' command not found"):
            get_sacct_output(24)

    def test_parse_slurm_metrics_no_filter(self):
        """Ensure pipe-separated data parses into correct dictionaries."""
        parsed = parse_slurm_metrics(self.mock_sacct_output, filter_str=None)
        self.assertEqual(len(parsed), 3)
        self.assertEqual(parsed[0]['JobID'], '12345')
        self.assertEqual(parsed[0]['MaxRSS'], '14500K')

    def test_parse_slurm_metrics_with_filter(self):
        """Ensure filtering strictly returns matched JobNames."""
        parsed = parse_slurm_metrics(self.mock_sacct_output, filter_str='cpld_control')
        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0]['JobName'], 'cpld_control_sfs_0')
        self.assertEqual(parsed[1]['State'], 'RUNNING')

    def test_parse_slurm_metrics_empty(self):
        """Ensure parser handles empty queries gracefully."""
        self.assertEqual(parse_slurm_metrics("JobID|JobName|State|Elapsed|TotalCPU|MaxRSS\n"), [])
        self.assertEqual(parse_slurm_metrics(""), [])

class TestRTSetup(unittest.TestCase):
    def test_build_rt_conf_test(self):
        conf_output = build_rt_conf_test(['cpld_control_sfs_0'])
        self.assertIn('RUN | cpld_control_sfs_0 |', conf_output)

    @patch('urllib.request.urlopen')
    def test_verify_local_matches_remote(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"test"
        mock_resp.__enter__.return_value = mock_resp
        mock_urlopen.return_value = mock_resp
        
        with tempfile.TemporaryDirectory() as tmpdir:
            f = Path(tmpdir) / 't.md'
            f.write_text("test")
            self.assertTrue(verify_local_matches_remote(f, 'https://github.com/a.git', 'hash', 't.md'))
            f.write_text("bad")
            self.assertFalse(verify_local_matches_remote(f, 'https://github.com/a.git', 'hash', 't.md'))

if __name__ == '__main__':
    if len(sys.argv) > 1:
        if sys.argv[1] == '--test':
            sys.argv.pop(1)
            unittest.main()
        elif sys.argv[1] == '--metrics':
            # Default to pulling 48 hours to ensure we catch tests dispatched yesterday
            driver_slurm_metrics(hours_lookback=48, filter_str='cpld_control')
        else:
            print("Usage: ./run_RTs_hashes.py [--test | --metrics]")
    else:
        driver_rtconf()
