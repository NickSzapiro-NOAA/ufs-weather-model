
#"ORTs" - dbg, dcp, fhz, mpi, rst, thr

def make_dcp_test(RT_base, fNameOut):
  s = '''
#
#  decomposition test
#

source ${{PATHRT}}/tests/{0}

export TEST_DESCR+=" dcp test"

export INPES=$((INPES*2))
export JNPES=$((JNPES/2))

export OCN_tasks=$((OCN_tasks+10))
export ICE_tasks=$((ICE_tasks+6))

export CICE_NPROC=$ICE_tasks
export np2=`expr $CICE_NPROC / 2`
export CICE_BLCKX=`expr $NX_GLB / $np2`
export CICE_BLCKY=`expr $NY_GLB / 2`
'''
  with open(fNameOut,'w') as fOut:
    fOut.write(s.format(RT_base))

def make_thr_test(RT_base, fNameOut):
  s = '''
#
#  threading on/off test
#

source ${{PATHRT}}/tests/{0}

export TEST_DESCR+=" thr test"

#nthreads was 1, make 2
export JNPES=$(( JNPES / 2 ))
export WRTTASK_PER_GROUP=$(( WRTTASK_PER_GROUP * 2 ))

export atm_omp_num_threads=2
export chm_omp_num_threads=$atm_omp_num_threads
export med_omp_num_threads=$atm_omp_num_threads

'''
  with open(fNameOut,'w') as fOut:
    fOut.write(s.format(RT_base))

def demo_make_ORT_suite():
  RTs_base = ['cpld_control_gfsv17_nowav_iau', 'cpld_restart_gfsv17_nowav_iau']
  for RT_base in RTs_base:
    fNameOut = RT_base+'_dcp'
    make_dcp_test(RT_base, fNameOut)
  
    fNameOut = RT_base+'_thr'
    make_thr_test(RT_base, fNameOut)

if __name__=='__main__':
  demo_make_ORT_suite()
