program test_qc_coupling
  use ESMF
  use qc_coupling_mod
  implicit none

  integer                       :: rc
  real(ESMF_KIND_R8)            :: min_val, max_val
  logical                       :: is_known
  real(ESMF_KIND_R8)            :: test_array(3)
  real(ESMF_KIND_R8), parameter :: TOLERANCE = 1.0e-5_ESMF_KIND_R8

  print *, "--- Starting QC Coupling Unit Tests (Namelist Version) ---"

  call ESMF_Initialize(rc=rc)

  print *, "Testing Namelist Initialization..."
  call init_qc_registry('test_qc.nml', rc)
  if (rc /= ESMF_SUCCESS) then
     print *, "FAIL: Could not parse test_qc.nml"
     stop 1
  end if

  ! ---------------------------------------------------------
  ! TEST SUITE A: Namelist Parsing & Binary Search Verification
  ! ---------------------------------------------------------
  print *, "Testing Namelist parsing and usage..."

  call get_limits('test_temp', min_val, max_val, is_known)
  if (.not. is_known) stop 10
  if (abs(min_val - 150.5_ESMF_KIND_R8) > TOLERANCE) stop 11
  if (abs(max_val - 350.5_ESMF_KIND_R8) > TOLERANCE) stop 12
  print *, "  PASS: test_temp parsed correctly."

  call get_limits('test_multiline', min_val, max_val, is_known)
  if (.not. is_known) stop 20
  if (abs(min_val - (-10.0_ESMF_KIND_R8)) > TOLERANCE) stop 21
  if (abs(max_val - 10.0_ESMF_KIND_R8) > TOLERANCE) stop 22
  print *, "  PASS: test_multiline (spaced format) parsed correctly."

  call get_limits('missing_var', min_val, max_val, is_known)
  if (is_known) stop 30
  print *, "  PASS: missing_var handled correctly."

  print *, "Testing internal Quicksort routine..."
  
  ! If the array wasn't sorted perfectly, the Binary Search will fail to find these
  call get_limits('Z_var', min_val, max_val, is_known)
  if (.not. is_known) stop 31
  
  call get_limits('A_var_1', min_val, max_val, is_known)
  if (.not. is_known) stop 32
  
  call get_limits('A_var_2', min_val, max_val, is_known)
  if (.not. is_known) stop 33
  
  call get_limits('X_var', min_val, max_val, is_known)
  if (.not. is_known) stop 34

  print *, "  PASS: Quicksort correctly alphabetized reversed and similar strings."

  ! ---------------------------------------------------------
  ! TEST SUITE B: Array Clamping Execution
  ! ---------------------------------------------------------
  print *, "Testing QC Clamping..."
  
  test_array(1) = 200.0_ESMF_KIND_R8 ! Valid
  test_array(2) = 50.0_ESMF_KIND_R8  ! Too cold
  test_array(3) = 400.0_ESMF_KIND_R8 ! Too hot

  call apply_qc_check('test_temp', test_array, QC_ACTION_CLAMP, rc)

  if (abs(test_array(1) - 200.0_ESMF_KIND_R8) > TOLERANCE) stop 50
  if (abs(test_array(2) - 150.5_ESMF_KIND_R8) > TOLERANCE) stop 51
  if (abs(test_array(3) - 350.5_ESMF_KIND_R8) > TOLERANCE) stop 52

  print *, "  PASS: Arrays safely bounded to physical limits."
  print *, "SUCCESS: All QC Coupling Namelist tests passed!"
  
  call ESMF_Finalize(rc=rc)
end program test_qc_coupling
