program test_qc_coupling
  use ESMF
  use qc_coupling_mod
  implicit none

  integer                       :: rc
  real(ESMF_KIND_R8)            :: min_val, max_val
  logical                       :: is_known
  real(ESMF_KIND_R8)            :: test_array(3)
  real(ESMF_KIND_R8), parameter :: TOLERANCE = 1.0e-5_ESMF_KIND_R8

  print *, "--- Starting QC Coupling Unit Tests ---"

  call ESMF_Initialize(rc=rc)

  print *, "Testing YAML Initialization..."
  call init_qc_registry('test_fd.yaml', rc)
  if (rc /= ESMF_SUCCESS) then
     print *, "FAIL: Could not parse test_fd.yaml"
     stop 1
  end if

  ! ---------------------------------------------------------
  ! TEST SUITE A: YAML Parsing & Binary Search Verification
  ! ---------------------------------------------------------
  call get_limits('test_temp', min_val, max_val, is_known)
  if (.not. is_known) stop 10
  if (abs(min_val - 150.5_ESMF_KIND_R8) > TOLERANCE) stop 11
  if (abs(max_val - 350.5_ESMF_KIND_R8) > TOLERANCE) stop 12
  print *, "  PASS: test_temp parsed correctly."

  call get_limits('test_fraction', min_val, max_val, is_known)
  if (.not. is_known) stop 20
  if (abs(min_val - 0.0_ESMF_KIND_R8) > TOLERANCE) stop 21
  if (abs(max_val - 1.0_ESMF_KIND_R8) > TOLERANCE) stop 22
  print *, "  PASS: test_fraction parsed correctly."

  call get_limits('test_unbounded', min_val, max_val, is_known)
  if (is_known) stop 30
  print *, "  PASS: test_unbounded safely ignored."

  call get_limits('missing_var', min_val, max_val, is_known)
  if (is_known) stop 40
  print *, "  PASS: missing_var handled correctly."

  ! ---------------------------------------------------------
  ! TEST SUITE B: Array Clamping Execution
  ! ---------------------------------------------------------
  print *, "Testing Active Array QC Clamping..."
  
  test_array(1) = 200.0_ESMF_KIND_R8 ! Valid
  test_array(2) = 50.0_ESMF_KIND_R8  ! Too cold
  test_array(3) = 400.0_ESMF_KIND_R8 ! Too hot

  call apply_qc_check('test_temp', test_array, QC_ACTION_CLAMP, rc)

  if (abs(test_array(1) - 200.0_ESMF_KIND_R8) > TOLERANCE) stop 50
  if (abs(test_array(2) - 150.5_ESMF_KIND_R8) > TOLERANCE) stop 51
  if (abs(test_array(3) - 350.5_ESMF_KIND_R8) > TOLERANCE) stop 52

  print *, "  PASS: Arrays safely bounded to physical limits."
  print *, "SUCCESS: All QC Coupling tests passed!"
  
  call ESMF_Finalize(rc=rc)
end program test_qc_coupling
