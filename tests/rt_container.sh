#!/usr/bin/env bash
# rt_container.sh — UFS-WM regression test driver for container-based runs.
#
# Reads a five-header-line configuration file (default: rt_container.conf in
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
    echo "${s}"
}

usage() {
    echo ""
    echo "Usage: $(basename "$0") [options] [rt_container.conf]"
    echo ""
    echo "Options:"
    echo "  -a <account>  scheduler account/project (overrides conf header line 2)"
    echo "  -b <file>     create new baselines only for tests listed in <file>"
    echo "  -c            create new baseline results"
    echo "  -d            delete run directories after each test completes"
    echo "  -h            display this help"
    echo "  -k            keep RUNDIR_ROOT after rt_container.sh completes"
    echo "  -l <file>     use <file> as the configuration file"
    echo "  -m            compare against newly created baselines (requires prior -c run)"
    echo "  -n <name>     run only the single test named <name>"
    echo "  -o            compile only, skip all tests"
    echo "  -r            use Rocoto workflow manager (overrides conf header line 2)"
    echo "  -v            verbose output (set -x)"
    echo "  -w            skip comparing results against baselines"
    echo ""
}

###############################################################################
# Flag defaults
###############################################################################

CREATE_BASELINE=false
KEEP_RUNDIR=false
export delete_rundir=false
COMPILE_ONLY=false
RTPWD_NEW_BASELINE=false
NEW_BASELINES_FILE=''
RUN_SINGLE_TEST=false
SRT_NAME=''
export skip_check_results=false
export RTVERBOSE=false
OVERRIDE_ACCNR=''
OVERRIDE_ROCOTO=false
ECFLOW=false
DEFINE_CONF_FILE=false
TESTS_FILE="${PATHRT}/rt_container.conf"

###############################################################################
# Parse command-line options
###############################################################################

while getopts ":a:b:cdhl:kmn:orvw" opt; do
    case ${opt} in
        a) OVERRIDE_ACCNR=${OPTARG} ;;
        b) NEW_BASELINES_FILE=${OPTARG} ;;
        c) CREATE_BASELINE=true ;;
        d) export delete_rundir=true ;;
        h) usage; exit 0 ;;
        k) KEEP_RUNDIR=true ;;
        l) DEFINE_CONF_FILE=true; TESTS_FILE=${OPTARG} ;;
        m) RTPWD_NEW_BASELINE=true ;;
        n) RUN_SINGLE_TEST=true; SRT_NAME=${OPTARG} ;;
        o) COMPILE_ONLY=true ;;
        r) OVERRIDE_ROCOTO=true ;;
        v) export RTVERBOSE=true ;;
        w) export skip_check_results=true ;;
        \?) usage; echo "ERROR: invalid option -${OPTARG}" >&2; exit 1 ;;
        :)  usage; echo "ERROR: option -${OPTARG} requires an argument" >&2; exit 1 ;;
        *)  usage; echo "ERROR: unknown arguments" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Positional arg (conf file) after options overrides default but not -l
if [[ "${DEFINE_CONF_FILE}" == false && -n "${1:-}" ]]; then
    TESTS_FILE="$1"
fi

###############################################################################
# Validate flag combinations
###############################################################################

if [[ "${CREATE_BASELINE}" == true && "${RTPWD_NEW_BASELINE}" == true ]]; then
    echo "ERROR: -c and -m are mutually exclusive" >&2; exit 1
fi
if [[ -n "${NEW_BASELINES_FILE}" && "${RUN_SINGLE_TEST}" == true ]]; then
    echo "ERROR: -b and -n cannot be used together" >&2; exit 1
fi
if [[ -n "${NEW_BASELINES_FILE}" && ! -s "${NEW_BASELINES_FILE}" ]]; then
    echo "ERROR: baseline file is empty: ${NEW_BASELINES_FILE}" >&2; exit 1
fi
if [[ "${KEEP_RUNDIR}" == true && "${delete_rundir}" == true ]]; then
    echo "ERROR: -k and -d cannot be used together" >&2; exit 1
fi

if [[ "${RTVERBOSE}" == true ]]; then
    set -x
fi

###############################################################################
# Configuration file
###############################################################################

input_file="${TESTS_FILE}"

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
        IFS='|' read -r f1 f2 f3 f4 f5 f6 f7 _rest <<< "${line}"
        TPN=$(trim "${f1:-40}")
        SCHEDULER=$(trim "${f2:-slurm}")
        USE_ROCOTO=$(trim "${f3:-false}")
        ACCNR=$(trim "${f4:-}")
        PARTITION=$(trim "${f5:-}")
        QUEUE=$(trim "${f6:-}")
        MPI_LAUNCH=$(trim "${f7:-mpirun}")
        header_lines_read=2
        echo "TPN=${TPN}  SCHEDULER=${SCHEDULER}  USE_ROCOTO=${USE_ROCOTO}"
        echo "ACCNR=${ACCNR}  PARTITION=${PARTITION}  QUEUE=${QUEUE}"
        [[ "${SCHEDULER}" == none ]] && echo "MPI_LAUNCH=${MPI_LAUNCH}"
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
# Apply command-line overrides (after conf is parsed)
###############################################################################

# -a overrides ACCNR from conf
[[ -n "${OVERRIDE_ACCNR}" ]] && ACCNR="${OVERRIDE_ACCNR}"

# -r overrides USE_ROCOTO from conf
[[ "${OVERRIDE_ROCOTO}" == true ]] && USE_ROCOTO=true

# Baseline paths:
#   NEW_BASELINE — where new baselines are written when -c is active
#   RTPWD        — where run_test.sh looks for baseline files to compare
NEW_BASELINE="${RUNDIR_ROOT}/REGRESSION_TEST"
if [[ "${RTPWD_NEW_BASELINE}" == true ]]; then
    RTPWD="${NEW_BASELINE}"
else
    RTPWD="${DISKNM}"
fi

# Derive INPUTDATA_ROOT sub-paths (same convention as rt.sh).
# All three can be overridden by setting the variable before invoking this script.
INPUTDATA_ROOT_WW3=${INPUTDATA_ROOT_WW3:-${INPUTDATA_ROOT}/WW3_input_data_20250807}
INPUTDATA_LM4=${INPUTDATA_LM4:-${INPUTDATA_ROOT}/LM4_input_data}
INPUTDATA_GFSv17opn=${INPUTDATA_GFSv17opn:-${DISKNM}/NEMSfv3gfs/GFSv17opn_20251014}

# Load the test list for -b (baseline from file)
declare -a BASELINE_TESTS=()
if [[ -n "${NEW_BASELINES_FILE}" ]]; then
    readarray -t BASELINE_TESTS < "${NEW_BASELINES_FILE}"
fi

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

# When creating baselines, prepare the destination directory.
if [[ "${CREATE_BASELINE}" == true || -n "${NEW_BASELINES_FILE}" ]]; then
    mkdir -p "${NEW_BASELINE}"
    echo "NEW_BASELINE=${NEW_BASELINE}"
    echo ""
fi

# When -d is set, run_test.sh reads keep_tests.tmp to decide which dirs to keep.
# An empty file means every test dir gets removed.
if [[ "${delete_rundir}" == true ]]; then
    : > "${PATHRT}/keep_tests.tmp"
fi

###############################################################################
# Export variables used by run_compile.sh, run_test.sh, and atparse
###############################################################################

export MACHINE_ID=container
export RT_COMPILER TPN CONTAINER_IMG CONTAINER_BIND
export SCHEDULER USE_ROCOTO ACCNR PARTITION QUEUE MPI_LAUNCH
export DISKNM INPUTDATA_ROOT INPUTDATA_ROOT_WW3 INPUTDATA_LM4 INPUTDATA_GFSv17opn
export PATHRT PATHTR RUNDIR_ROOT LOG_DIR
export RTPWD NEW_BASELINE

# run_compile.sh and run_test.sh check ROCOTO (not USE_ROCOTO).
export ROCOTO="${USE_ROCOTO}"
export ECFLOW="${ECFLOW}"

###############################################################################
# Source atparse (used by run_compile.sh/run_test.sh; sourced here so the
# script can verify it is present before starting any work)
###############################################################################

source "${PATHRT}/atparse.bash"

###############################################################################
# Print active flags and confirm before starting
###############################################################################

echo "Active flags:"
[[ -n "${OVERRIDE_ACCNR}" ]]          && echo "  -a  account override: ${ACCNR}"
[[ -n "${NEW_BASELINES_FILE}" ]]       && echo "  -b  baselines from file: ${NEW_BASELINES_FILE}"
[[ "${CREATE_BASELINE}" == true ]]     && echo "  -c  create new baselines in: ${NEW_BASELINE}"
[[ "${delete_rundir}" == true ]]       && echo "  -d  delete run directories after each test"
[[ "${KEEP_RUNDIR}" == true ]]         && echo "  -k  keep RUNDIR_ROOT after completion"
[[ "${RTPWD_NEW_BASELINE}" == true ]]  && echo "  -m  compare against: ${NEW_BASELINE}"
[[ "${RUN_SINGLE_TEST}" == true ]]     && echo "  -n  single test: ${SRT_NAME}"
[[ "${COMPILE_ONLY}" == true ]]        && echo "  -o  compile only, skip tests"
[[ "${OVERRIDE_ROCOTO}" == true ]]     && echo "  -r  Rocoto workflow enabled"
[[ "${RTVERBOSE}" == true ]]           && echo "  -v  verbose output"
[[ "${skip_check_results}" == true ]]  && echo "  -w  skip baseline comparison"
echo ""

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

    # When running a single test, skip compiles that don't include it.
    if [[ "${RUN_SINGLE_TEST}" == true ]]; then
        if [[ $'\n'"${tests_by_compile_id[$COMPILE_ID]}" != *$'\n'"${SRT_NAME}"$'\n'* ]]; then
            echo "Skipping compile ${COMPILE_ID} (no matching test for -n ${SRT_NAME})"
            continue
        fi
    fi

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
export ECFLOW=${ECFLOW}
export ACCNR=${ACCNR}
export PARTITION=${PARTITION}
export QUEUE=${QUEUE}
export TPN=${TPN}
export CONTAINER_IMG=${CONTAINER_IMG}
export CONTAINER_BIND=${CONTAINER_BIND}
export MPI_LAUNCH=${MPI_LAUNCH}
export RTVERBOSE=${RTVERBOSE}
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

    # -o: compile only, do not run tests.
    if [[ "${COMPILE_ONLY}" == true ]]; then
        echo "(-o) Skipping tests for COMPILE_ID=${COMPILE_ID}"
        continue
    fi

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

        # -n: run only the named test.
        if [[ "${RUN_SINGLE_TEST}" == true && "${TEST_NAME}" != "${SRT_NAME}" ]]; then
            continue
        fi

        export TEST_NAME
        export TEST_ID="${TEST_NAME}_${RT_COMPILER}"

        echo "---------------------------------------------------------------------"
        echo "Test: ${TEST_NAME}  (COMPILE_ID=${COMPILE_ID})"
        echo "---------------------------------------------------------------------"

        # Determine whether this test creates baselines.
        # -c: all tests create baselines.
        # -b: only tests listed in the file create baselines.
        CREATE_BASELINE_THIS_TEST=false
        if [[ "${CREATE_BASELINE}" == true ]]; then
            CREATE_BASELINE_THIS_TEST=true
        elif [[ -n "${NEW_BASELINES_FILE}" ]]; then
            for bl_test in "${BASELINE_TESTS[@]}"; do
                if [[ "$(trim "${bl_test}")" == "${TEST_NAME}" ]]; then
                    CREATE_BASELINE_THIS_TEST=true
                    break
                fi
            done
        fi

        # Write the test environment file (sourced by run_test.sh).
        # RTPWD points to the baseline data directory (DISKNM, or NEW_BASELINE with -m).
        cat > "${RUNDIR_ROOT}/run_test_${TEST_ID}.env" << ENV_EOF
export MACHINE_ID=container
export PATHTR=${PATHTR}
export PATHRT=${PATHRT}
export RUNDIR_ROOT=${RUNDIR_ROOT}
export LOG_DIR=${LOG_DIR}
export RT_COMPILER=${RT_COMPILER}
export SCHEDULER=${SCHEDULER}
export ROCOTO=${USE_ROCOTO}
export ECFLOW=${ECFLOW}
export ACCNR=${ACCNR}
export PARTITION=${PARTITION}
export QUEUE=${QUEUE}
export TPN=${TPN}
export CONTAINER_IMG=${CONTAINER_IMG}
export CONTAINER_BIND=${CONTAINER_BIND}
export MPI_LAUNCH=${MPI_LAUNCH}
export RTPWD=${RTPWD}
export NEW_BASELINE=${NEW_BASELINE}
export INPUTDATA_ROOT=${INPUTDATA_ROOT}
export INPUTDATA_ROOT_WW3=${INPUTDATA_ROOT_WW3}
export INPUTDATA_LM4=${INPUTDATA_LM4}
export INPUTDATA_GFSv17opn=${INPUTDATA_GFSv17opn}
export CNTL_DIR=${TEST_NAME}
export RT_SUFFIX=
export BL_SUFFIX=
export CREATE_BASELINE=${CREATE_BASELINE_THIS_TEST}
export skip_check_results=${skip_check_results}
export delete_rundir=${delete_rundir}
export RTVERBOSE=${RTVERBOSE}
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
# Cleanup RUNDIR_ROOT (unless -k was specified)
###############################################################################

if [[ "${KEEP_RUNDIR}" == false && ${#failed_tests[@]} -eq 0 && ${#failed_compiles[@]} -eq 0 ]]; then
    rm -rf "${RUNDIR_ROOT}"
fi

[[ "${delete_rundir}" == true ]] && rm -f "${PATHRT}/keep_tests.tmp"

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
