
#"ORTs" - dbg, dcp, fhz, mpi, rst, thr

def make_dcp_test(RT_base, fNameOut):
  s = '''
#
#  decomposition test
#

source ${{PATHRT}}/tests/{0}

export TEST_DESCR+=" dcp test"

#export INPES=$((INPES/2))
#export JNPES=$((JNPES*2))
export INPES=4
export JNPES=6

export OCN_tasks=$((OCN_tasks+10))
export ICE_tasks=$((ICE_tasks+12))
#export WAV_tasks=$((WAV_tasks+10))

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

#tasks with no threads
export THRD=2
#export INPES=$(( INPES * 2 ))
#export JNPES=$(( JNPES * 2 ))
#export WRTTASK_PER_GROUP=$(( WPG_cpl_bmrk * THRD_cpl_bmrk ))
'''
  with open(fNameOut,'w') as fOut:
    fOut.write(s.format(RT_base))

def demo_make_aoflux_ORTs():
  aoflux_opts = ['agrid', 'ogrid', 'xgrid']
  for aoflux_opt in aoflux_opts:
    RT_base = 'cpld_control_noaero_p8_{0}'.format(aoflux_opt)
    
    fNameOut = RT_base+'_dcp'
    make_dcp_test(RT_base, fNameOut)

    fNameOut = RT_base+'_thr'
    make_thr_test(RT_base, fNameOut)

if __name__=='__main__':
  demo_make_aoflux_ORTs()
