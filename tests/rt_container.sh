#!/usr/bin/env bash
# rt_container.sh — UFS-WM regression test driver for container-based runs.
#
# Usage:  ./rt_container.sh [rt_container.conf]
#
# Reads a three-header-line configuration file (default: rt_container.conf in
# the same directory as this script) and runs compile + test phases for each
# configuration sequentially:
#   for each compile configuration:
#     1. Compile the model inside the container
#     2. Run every listed test case sequentially, waiting for each to finish
#
# Scheduler job templates used:
#   fv3_conf/compile_slurm.IN_container  or  compile_qsub.IN_container
#   fv3_conf/fv3_slurm.IN_container      or  fv3_qsub.IN_container
# (machine-specific fv3_slurm.IN_container_<MACHINE_ID> variants, when present,
#  are checked first by run_test.sh.)
#
# Users must prepare before running:
#   modulefiles/ufs_container.<compiler>.lua   — inside-container build module
#   modulefiles/ufs_container.runtime.lua      — host-side runtime module
# and review/adapt the fv3_conf/*.IN_container templates listed above.

set -uo pipefail

###############################################################################
# Locate this script; set PATHRT and PATHTR
###############################################################################

SCRIPT_REALPATH=$(realpath "${BASH_SOURCE[0]}")
PATHRT=$(dirname "${SCRIPT_REALPATH}")
PATHTR=$(cd "${PATHRT}/.." && pwd)

readonly PATHRT PATHTR

###############################################################################
# Helpers
###############################################################################

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf "%s" "${s}"
}

###############################################################################
# Configuration file
###############################################################################

input_file="${1:-${PATHRT}/rt_container.conf}"

if [[ ! -f "${input_file}" ]]; then
    echo "ERROR: configuration file not found: ${input_file}" >&2
    exit 1
fi

###############################################################################
# Parse rt_container.conf
#
# Header line 1: RT_COMPILER | CONTAINER_IMG | BIND_DIRS
# Header line 2: TPN | SCHEDULER | USE_ROCOTO | ACCNR | PARTITION | QUEUE
# Header line 3: DISKNM
# Header line 4: INPUTDATA_ROOT
# Header line 5: RUNDIR_ROOT
#
# Configuration line (after headers): compile_id | MAKE_OPT   (contains '|')
# Case line         (after headers):  test_case_name           (no '|')
###############################################################################

declare -a compile_ids=()
declare -a make_opts=()
declare -A tests_by_compile_id

header_lines_read=0
current_compile_id=""

while IFS= read -r line || [[ -n "${line}" ]]; do

    line="${line%$'\r'}"

    # Skip blank lines; a blank line also closes the current configuration block.
    if [[ -z "${line//[[:space:]]/}" ]]; then
        current_compile_id=""
        continue
    fi

    # Skip comment lines.
    if [[ "${line}" =~ ^[[:space:]]*# ]]; then
        continue
    fi

    # ------------------------------------------------------------------
    # Header line 1: RT_COMPILER | CONTAINER_IMG | BIND_DIRS
    # ------------------------------------------------------------------
    if [[ ${header_lines_read} -eq 0 ]]; then
        IFS='|' read -r f1 f2 f3 _rest <<< "${line}"
        RT_COMPILER=$(trim "${f1:-}")
        CONTAINER_IMG=$(trim "${f2:-}")
        CONTAINER_BIND=$(trim "${f3:-}")
        header_lines_read=1
        echo "RT_COMPILER=${RT_COMPILER}"
        echo "CONTAINER_IMG=${CONTAINER_IMG}"
        echo "BIND_DIRS=${CONTAINER_BIND}"
        continue
    fi

    # ------------------------------------------------------------------
    # Header line 2: TPN | SCHEDULER | USE_ROCOTO | ACCNR | PARTITION | QUEUE
    # ------------------------------------------------------------------
    if [[ ${header_lines_read} -eq 1 ]]; then
        IFS='|' read -r f1 f2 f3 f4 f5 f6 _rest <<< "${line}"
        TPN=$(trim "${f1:-40}")
        SCHEDULER=$(trim "${f2:-slurm}")
        USE_ROCOTO=$(trim "${f3:-false}")
        ACCNR=$(trim "${f4:-}")
        PARTITION=$(trim "${f5:-}")
        QUEUE=$(trim "${f6:-}")
        header_lines_read=2
        echo "TPN=${TPN}  SCHEDULER=${SCHEDULER}  USE_ROCOTO=${USE_ROCOTO}"
        echo "ACCNR=${ACCNR}  PARTITION=${PARTITION}  QUEUE=${QUEUE}"
        continue
    fi

    # ------------------------------------------------------------------
    # Header line 3: DISKNM
    # ------------------------------------------------------------------
    if [[ ${header_lines_read} -eq 2 ]]; then
        DISKNM=$(trim "${line}")
        header_lines_read=3
        echo "DISKNM=${DISKNM}"
        continue
    fi

    # ------------------------------------------------------------------
    # Header line 4: INPUTDATA_ROOT
    # ------------------------------------------------------------------
    if [[ ${header_lines_read} -eq 3 ]]; then
        INPUTDATA_ROOT=$(trim "${line}")
        header_lines_read=4
        echo "INPUTDATA_ROOT=${INPUTDATA_ROOT}"
        continue
    fi

    # ------------------------------------------------------------------
    # Header line 5: RUNDIR_ROOT
    # ------------------------------------------------------------------
    if [[ ${header_lines_read} -eq 4 ]]; then
        RUNDIR_ROOT=$(trim "${line}")
        header_lines_read=5
        echo "RUNDIR_ROOT=${RUNDIR_ROOT}"
        continue
    fi

    # ------------------------------------------------------------------
    # Configuration line: compile_id | MAKE_OPT   (contains '|')
    # Case line:          test_case_name           (no '|')
    # ------------------------------------------------------------------
    if [[ "${line}" == *"|"* ]]; then
        IFS='|' read -r f1 f2 _rest <<< "${line}"
        current_compile_id=$(trim "${f1:-}")
        make_opt="${f2:-}"
        make_opt="${make_opt#"${make_opt%%[![:space:]]*}"}"  # ltrim only
        compile_ids+=( "${current_compile_id}" )
        make_opts+=( "${make_opt}" )
        tests_by_compile_id["${current_compile_id}"]=""
    else
        test_case=$(trim "${line}")
        if [[ -z "${current_compile_id}" ]]; then
            echo "WARNING: case '${test_case}' has no active configuration — skipping" >&2
            continue
        fi
        tests_by_compile_id["${current_compile_id}"]+="${test_case}"$'\n'
    fi

done < "${input_file}"

if [[ ${header_lines_read} -lt 5 ]]; then
    echo "ERROR: fewer than 5 header lines found in ${input_file}" >&2
    exit 1
fi

if [[ ${#compile_ids[@]} -eq 0 ]]; then
    echo "ERROR: no compile configuration sections found in ${input_file}" >&2
    exit 1
fi

echo ""
echo "Found ${#compile_ids[@]} compile configuration(s):"
for i in "${!compile_ids[@]}"; do
    echo "  $((i+1)): ${compile_ids[$i]}  [${make_opts[$i]}]"
done
echo ""

###############################################################################
# Validate prerequisites
###############################################################################

if [[ ! -f "${PATHTR}/modulefiles/ufs_container.${RT_COMPILER}.lua" ]]; then
    echo "ERROR: modulefiles/ufs_container.${RT_COMPILER}.lua not found under ${PATHTR}" >&2
    echo "       Provide this modulefile for the inside-container build environment." >&2
    exit 1
fi

if [[ ! -f "${PATHTR}/modulefiles/ufs_container.runtime.lua" ]]; then
    echo "ERROR: modulefiles/ufs_container.runtime.lua not found under ${PATHTR}" >&2
    echo "       Provide this host-side runtime modulefile before running." >&2
    exit 1
fi

if [[ ! -f "${CONTAINER_IMG}" ]]; then
    echo "ERROR: container image not found: ${CONTAINER_IMG}" >&2
    exit 1
fi

###############################################################################
# Set up run directory and logging
###############################################################################

LOG_DIR="${RUNDIR_ROOT}/logs"
mkdir -p "${LOG_DIR}"

echo "LOG_DIR=${LOG_DIR}"
echo ""

###############################################################################
# Export variables used by run_compile.sh, run_test.sh, and atparse
###############################################################################

export MACHINE_ID=container
export RT_COMPILER TPN CONTAINER_IMG CONTAINER_BIND
export SCHEDULER USE_ROCOTO ACCNR PARTITION QUEUE
export DISKNM INPUTDATA_ROOT PATHRT PATHTR RUNDIR_ROOT LOG_DIR

# run_compile.sh and run_test.sh check the variable ROCOTO (not USE_ROCOTO).
export ROCOTO="${USE_ROCOTO}"
export ECFLOW=false

###############################################################################
# Source atparse (used by run_compile.sh/run_test.sh; sourced here so the
# script can verify it is present before starting any work)
###############################################################################

source "${PATHRT}/atparse.bash"

###############################################################################
# Confirm before starting
###############################################################################

read -r -n 1 -s -p "Configuration above — press any key to start, or Ctrl-C to abort... "
echo ""
echo ""

###############################################################################
# Tracking
###############################################################################

declare -a failed_compiles=()
declare -a failed_tests=()
declare -a skipped_tests=()

###############################################################################
# Main loop: compile then run all tests for each configuration, sequentially
###############################################################################

for i in "${!compile_ids[@]}"; do

    export COMPILE_ID="${compile_ids[$i]}"
    export MAKE_OPT="${make_opts[$i]}"
    export BUILD_NAME="fv3_${COMPILE_ID}"
    export JBNME="compile_${COMPILE_ID}"

    echo "====================================================================="
    echo "Compile $((i+1)) of ${#compile_ids[@]}: COMPILE_ID=${COMPILE_ID}"
    echo "MAKE_OPT=${MAKE_OPT}"
    echo "====================================================================="

    # ------------------------------------------------------------------
    # Write the compile environment file (sourced by run_compile.sh).
    # env file is sourced twice in run_compile.sh (before and after
    # default_vars.sh), so variables here survive the defaults reset.
    # ------------------------------------------------------------------
    mkdir -p "${RUNDIR_ROOT}"
    cat > "${RUNDIR_ROOT}/${JBNME}.env" << ENV_EOF
export MACHINE_ID=container
export PATHTR=${PATHTR}
export PATHRT=${PATHRT}
export RUNDIR_ROOT=${RUNDIR_ROOT}
export LOG_DIR=${LOG_DIR}
export RT_COMPILER=${RT_COMPILER}
export SCHEDULER=${SCHEDULER}
export ROCOTO=${USE_ROCOTO}
export ECFLOW=false
export ACCNR=${ACCNR}
export PARTITION=${PARTITION}
export QUEUE=${QUEUE}
export TPN=${TPN}
export CONTAINER_IMG=${CONTAINER_IMG}
export CONTAINER_BIND=${CONTAINER_BIND}
export WLCLK=120
ENV_EOF

    # ------------------------------------------------------------------
    # Submit compile job and wait (submit_and_wait inside run_compile.sh
    # blocks until the scheduler job completes).
    # run_compile.sh exits 0 even on failure in non-rocoto mode; check
    # the fail file instead.
    # ------------------------------------------------------------------
    "${PATHRT}/run_compile.sh" \
        "${PATHRT}" "${RUNDIR_ROOT}" "${MAKE_OPT}" "${COMPILE_ID}" || true

    if [[ -f "${PATHRT}/fail_${JBNME}" ]]; then
        echo "ERROR: compile failed for COMPILE_ID=${COMPILE_ID}" >&2
        echo "       See ${PATHRT}/fail_${JBNME} and ${LOG_DIR}/${JBNME}.log" >&2
        failed_compiles+=("${COMPILE_ID}")
        continue
    fi

    if [[ ! -f "${PATHRT}/fv3_${COMPILE_ID}.exe" ]]; then
        echo "WARNING: fv3_${COMPILE_ID}.exe not found after compile — skipping tests" >&2
        skipped_tests+=("${COMPILE_ID}:ALL:missing_executable")
        continue
    fi

    echo "Compile ${COMPILE_ID} succeeded — ${PATHRT}/fv3_${COMPILE_ID}.exe"
    echo ""

    # ------------------------------------------------------------------
    # Run test cases for this configuration, one at a time
    # ------------------------------------------------------------------
    mapfile -t test_cases <<< "${tests_by_compile_id[$COMPILE_ID]}"

    if [[ ${#test_cases[@]} -eq 0 ]]; then
        echo "WARNING: no test cases listed for COMPILE_ID=${COMPILE_ID}" >&2
        skipped_tests+=("${COMPILE_ID}:ALL:no_tests")
        continue
    fi

    for TEST_NAME in "${test_cases[@]}"; do
        [[ -z "${TEST_NAME}" ]] && continue

        export TEST_NAME
        export TEST_ID="${TEST_NAME}_${RT_COMPILER}"

        echo "---------------------------------------------------------------------"
        echo "Test: ${TEST_NAME}  (COMPILE_ID=${COMPILE_ID})"
        echo "---------------------------------------------------------------------"

        # Write the test environment file (sourced by run_test.sh).
        # RTPWD points to the top-level directory where baselines are kept;
        # DISKNM from header line 3 of rt_container.conf.
        cat > "${RUNDIR_ROOT}/run_test_${TEST_ID}.env" << ENV_EOF
export MACHINE_ID=container
export PATHTR=${PATHTR}
export PATHRT=${PATHRT}
export RUNDIR_ROOT=${RUNDIR_ROOT}
export LOG_DIR=${LOG_DIR}
export RT_COMPILER=${RT_COMPILER}
export SCHEDULER=${SCHEDULER}
export ROCOTO=${USE_ROCOTO}
export ECFLOW=false
export ACCNR=${ACCNR}
export PARTITION=${PARTITION}
export QUEUE=${QUEUE}
export TPN=${TPN}
export CONTAINER_IMG=${CONTAINER_IMG}
export CONTAINER_BIND=${CONTAINER_BIND}
export RTPWD=${DISKNM}
export INPUTDATA_ROOT=${INPUTDATA_ROOT}
export CNTL_DIR=${TEST_NAME}
export RT_SUFFIX=
export BL_SUFFIX=
export CREATE_BASELINE=false
export WLCLK=60
ENV_EOF

        rm -f "${PATHRT}/fail_test_${TEST_ID}"

        "${PATHRT}/run_test.sh" \
            "${PATHRT}" "${RUNDIR_ROOT}" "${TEST_NAME}" "${TEST_ID}" "${COMPILE_ID}" || true

        if [[ -f "${PATHRT}/fail_test_${TEST_ID}" ]]; then
            echo "FAIL: ${TEST_NAME}" >&2
            failed_tests+=("${COMPILE_ID}:${TEST_NAME}")
        else
            echo "PASS: ${TEST_NAME}"
        fi

    done

    echo ""

done

###############################################################################
# Summary
###############################################################################

echo ""
echo "====================================================================="
echo "rt_container.sh finished"
echo "====================================================================="

if [[ ${#skipped_tests[@]} -gt 0 ]]; then
    echo ""
    echo "Skipped:"
    for s in "${skipped_tests[@]}"; do
        IFS=':' read -r sc st sr <<< "${s}"
        echo "  COMPILE_ID=${sc}  TEST=${st}  reason=${sr}"
    done
fi

if [[ ${#failed_compiles[@]} -gt 0 ]]; then
    echo ""
    echo "Failed compiles:"
    for fc in "${failed_compiles[@]}"; do
        echo "  ${fc}"
    done
fi

if [[ ${#failed_tests[@]} -gt 0 ]]; then
    echo ""
    echo "Failed tests:"
    for ft in "${failed_tests[@]}"; do
        IFS=':' read -r fc ft_name <<< "${ft}"
        echo "  COMPILE_ID=${fc}  TEST=${ft_name}"
    done
    exit 1
fi

if [[ ${#failed_compiles[@]} -gt 0 ]]; then
    exit 1
fi

echo ""
echo "All tests completed successfully."
exit 0
