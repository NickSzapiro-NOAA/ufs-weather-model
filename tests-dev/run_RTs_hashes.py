# Run custom tests nInstance times
# say, to compare performance of model
import os

def write_test_instance(RT_base, testOut_path):
  # Write a valid RT test given input 
  # - RT_base name (like cpld_control_sfs) 
  # - testOut_path
  s = ''' # from run_RTs_hashes.py : write_test_instance
  source "${{PATHRT}}"/tests/{0}

  TEST_DESCR+="copy instance"
  '''.format(RT_base)
  with open(testOut_path,'w') as f:
    f.write(s)
  print('Write ',testOut_path)

def build_rt_conf_test(testNames):
  s = ''' # from run_RTs_hashes.py : build_rt_conf_test
COMPILE | s2s_32bit_sfs | intel | -DAPP=S2S -D32BIT=ON -DHYDRO=ON -DCCPP_SUITES=FV3_GFS_v17_coupled_p8_ugwpv1 -DUFS_TRACING=ON | - noaacloud derecho| fv3 |
RUN | cpld_control_sfs | - noaacloud  derecho                 | baseline |
'''
  for n in testNames:
    s += 'RUN | {0} | - noaacloud  derecho  |   | \n'.format(n)
  return(s)
  
def demo_driver(hashes=['f6b6c78', '6dc3648'], RT_base='cpld_control_sfs', nInst=5,
               base_path = '/scratch3/NCEPDEV/nems/Nick.Szapiro/tasks/cm_ufs/uwm_3315/'):
  
  for hash in hashes:
    dir_path = base_path+'uwm_{0}/'.format(hash)
    os.makedirs(dir_path, exist_ok=True)

    # checkout model code at hash
    os.chdir(dir_path)
    cmd = 'git clone https://github.com/ufs-community/ufs-weather-model.git'
    print(cmd); os.system(cmd)
    uwm_path = dir_path+'ufs-weather-model/'
    os.chdir(uwm_path)
    cmd = 'git checkout {0}; git submodule update --init --recursive -j 5'.format(hash)
    print(cmd); os.system(cmd)

    # copy base RT into nInstance versions
    tests_nInst = []
    for n in range(nInst):
      newTest = '{0}_{1}'.format(RT_base, n)
      newTest_path = uwm_path+'tests/tests/'+newTest
      tests_nInst.append(newTest)
      write_test_instance(RT_base, newTest_path)
    
    # set up my_rt.conf
    s = build_rt_conf_test(tests_nInst); print('my_rt.conf: \n', s)
    fConf = uwm_path+'tests/my_rt.conf'
    with open(fConf,'w') as f:
      f.write(s)

    # submit rt.sh -l my_rt.conf
    os.chdir(uwm_path+'tests/')
    cmd = 'nohup ./rt.sh -a nems -e -k -l my_rt.conf &'
    # TODO: check if better: nohup my_app >> nohup.out 2>&1 &
    print(cmd); os.system(cmd)

if __name__ == '__main__':
  demo_driver()
