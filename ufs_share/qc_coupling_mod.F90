module qc_coupling_mod
  use ESMF
  implicit none
  private

  ! Public API
  public :: init_qc_registry
  public :: apply_qc_check
  public :: get_limits        ! Exposed for unit testing and direct queries
  
  ! Configurable QC Actions 
  integer, parameter, public :: QC_ACTION_IGNORE = 0
  integer, parameter, public :: QC_ACTION_WARN   = 1
  integer, parameter, public :: QC_ACTION_CLAMP  = 2
  integer, parameter, public :: QC_ACTION_ABORT  = 3

  ! Internal registry structure
  type :: qc_rule
    character(len=64)  :: var_name
    real(ESMF_KIND_R8) :: qc_min
    real(ESMF_KIND_R8) :: qc_max
  end type qc_rule

  ! Memory-resident dictionary of QC limits
  type(qc_rule), allocatable, save :: qc_registry(:)
  
  ! Thread-local guard to prevent redundant file I/O on the same MPI PET
  logical, save :: is_initialized = .false.

  interface apply_qc_check
    module procedure apply_qc_check_2d_r8
    module procedure apply_qc_check_1d_r8
    module procedure apply_qc_check_2d_r4
    module procedure apply_qc_check_1d_r4
  end interface

contains

  ! ==============================================================================
  ! SUBROUTINE: init_qc_registry
  ! ==============================================================================
  subroutine init_qc_registry(yaml_file, rc)
    character(len=*), intent(in)  :: yaml_file
    integer,          intent(out) :: rc
    
    type(ESMF_HConfig)         :: config
    type(qc_rule), allocatable :: temp_registry(:)
    integer                    :: num_entries, i, valid_count
    logical                    :: isPresent
    character(len=8)           :: idx_str
    character(len=256)         :: base_path

    rc = ESMF_SUCCESS
    if (is_initialized) return

    config = ESMF_HConfigCreate(yaml_file, rc=rc)
    if (rc /= ESMF_SUCCESS) return

    call ESMF_HConfigGetAttribute(config, num_entries, label="field_dictionary::entries", rc=rc)
    allocate(qc_registry(num_entries))
    valid_count = 0

    do i = 1, num_entries
      write(idx_str, '(I0)') i
      base_path = "field_dictionary::entries::" // trim(adjustl(idx_str))

      call ESMF_HConfigGetAttribute(config, isPresent=isPresent, &
           label=trim(base_path)//"::qc_min", rc=rc)
      
      if (isPresent) then
        valid_count = valid_count + 1
        call ESMF_HConfigGetAttribute(config, qc_registry(valid_count)%var_name, &
             label=trim(base_path)//"::StandardName", rc=rc)
        call ESMF_HConfigGetAttribute(config, qc_registry(valid_count)%qc_min, &
             label=trim(base_path)//"::qc_min", rc=rc)
        call ESMF_HConfigGetAttribute(config, qc_registry(valid_count)%qc_max, &
             label=trim(base_path)//"::qc_max", rc=rc)
      end if
    end do

    ! Resize registry to drop empty rows
    if (valid_count > 0) then
      allocate(temp_registry(valid_count))
      temp_registry = qc_registry(1:valid_count)
      call move_alloc(temp_registry, qc_registry) 

      if (size(qc_registry) > 1) then
        call quicksort_registry(1, size(qc_registry))
      end if
    else
      deallocate(qc_registry)
    end if

    call ESMF_HConfigDestroy(config, rc=rc)
    is_initialized = .true.
  end subroutine init_qc_registry

  ! ==============================================================================
  ! PRIVATE HELPER: quicksort_registry
  ! ==============================================================================
  recursive subroutine quicksort_registry(first, last)
    integer, intent(in) :: first, last
    type(qc_rule)       :: temp
    integer             :: i, j
    character(len=64)   :: pivot

    if (first >= last) return

    pivot = qc_registry((first + last) / 2)%var_name
    i = first
    j = last

    do while (i <= j)
      do while (qc_registry(i)%var_name < pivot)
        i = i + 1
      end do
      do while (qc_registry(j)%var_name > pivot)
        j = j - 1
      end do
      
      if (i <= j) then
        temp = qc_registry(i)
        qc_registry(i) = qc_registry(j)
        qc_registry(j) = temp
        i = i + 1
        j = j - 1
      end if
    end do

    if (first < j) call quicksort_registry(first, j)
    if (i < last)  call quicksort_registry(i, last)
  end subroutine quicksort_registry

  ! ==============================================================================
  ! PUBLIC HELPER: get_limits (O(log N) Binary Search)
  ! ==============================================================================
  subroutine get_limits(var_name, limit_min, limit_max, is_known)
    character(len=*),   intent(in)  :: var_name
    real(ESMF_KIND_R8), intent(out) :: limit_min, limit_max
    logical,            intent(out) :: is_known
    
    integer           :: low, high, mid
    character(len=64) :: target_name

    is_known = .false.
    if (.not. allocated(qc_registry)) return

    target_name = var_name
    low = 1
    high = size(qc_registry)

    do while (low <= high)
      mid = (low + high) / 2
      
      if (qc_registry(mid)%var_name == target_name) then
        limit_min = qc_registry(mid)%qc_min
        limit_max = qc_registry(mid)%qc_max
        is_known  = .true.
        return
      else if (qc_registry(mid)%var_name < target_name) then
        low = mid + 1
      else
        high = mid - 1
      end if
    end do
  end subroutine get_limits

  ! ==============================================================================
  ! CPP INCLUSIONS FOR GENERIC INTERFACES
  ! ==============================================================================

#define ROUTINE_NAME apply_qc_check_2d_r8
#define VAR_KIND ESMF_KIND_R8
#define VAR_RANK :,:
#include "apply_qc_check_template.inc"
#undef ROUTINE_NAME
#undef VAR_KIND
#undef VAR_RANK

#define ROUTINE_NAME apply_qc_check_1d_r8
#define VAR_KIND ESMF_KIND_R8
#define VAR_RANK :
#include "apply_qc_check_template.inc"
#undef ROUTINE_NAME
#undef VAR_KIND
#undef VAR_RANK

#define ROUTINE_NAME apply_qc_check_2d_r4
#define VAR_KIND ESMF_KIND_R4
#define VAR_RANK :,:
#include "apply_qc_check_template.inc"
#undef ROUTINE_NAME
#undef VAR_KIND
#undef VAR_RANK

#define ROUTINE_NAME apply_qc_check_1d_r4
#define VAR_KIND ESMF_KIND_R4
#define VAR_RANK :
#include "apply_qc_check_template.inc"
#undef ROUTINE_NAME
#undef VAR_KIND
#undef VAR_RANK

end module qc_coupling_mod
