#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 <name> [submission_dir]" >&2
    exit 1
fi
SUMMARY_FILE="${SCRIPT_DIR}/results/$1.txt"
SUBMISSION_ARG="${2:-${SCRIPT_DIR}}"

if [[ ! -d "${SUBMISSION_ARG}" ]]; then
    echo "ERROR: submission directory not found: ${SUBMISSION_ARG}" >&2
    exit 1
fi
SUBMISSION_DIR="$(cd "${SUBMISSION_ARG}" && pwd)"
echo "Submission under test: ${SUBMISSION_DIR}"

BUILD_DIR="${SCRIPT_DIR}/build"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${SCRIPT_DIR}/results"
: > "${SUMMARY_FILE}"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "ERROR: iverilog not found on PATH. See README.md for install instructions." >&2
    exit 1
fi

# The phase-8 checks: every phase 7 check, plus the speedup row below.
# The phase-7 checks. Each is graded by its own <name>_tb.v, which you write
# yourself -- see README.md and example/opmux_tb.v. rf is checked twice, once
# per BYPASS_EN setting, against the same rf.v (rf_bypass_tb.v and
# rf_no_bypass_tb.v, carried over from phase 4). cache and plru carry over
# from phase 5 (now under cache/), fpu and fpu_round from phase 6. rat and
# cdb_arb are the two backend modules phase 7 requires as separate files;
# lsu is the in-order load/store unit hart instantiates.
# hart is checked four times against the same hart.v, one per rubric row in
# phase_7.pdf 2:
#   hart_no_hazard    basic correctness: traces/no_hazard_program.hex against
#                     the retire lines of traces/no_hazard.trace
#   hart_hazard       hazards / integration: traces/hazard_program.hex against
#                     the retire lines of traces/hazard_fwd.trace
#   hart_ooo_witness  out-of-order completion: o_complete_* out of program order,
#                     o_retire_* still in order
#   hart_cpi          out-of-order throughput: CPI against the phase 4 baseline
# The two .trace files are the phase 4 course traces: cycle by cycle for an
# in-order pipeline, so only their retire lines (not BUBBLE lines or cycle
# numbers) apply to an out-of-order hart. traces/random_*.hex are phase 6's.
MODULES=(alu imm rf_bypass rf_no_bypass decoder cache plru fpu fpu_round fpu_divsqrt rs fp_rs fcsr rat cdb_arb lsu hart_fp_commit hart_no_hazard hart_hazard hart_ooo_witness hart_cpi)

# Most checks share a name with the .v file they test; rf's two checks both
# target rf.v and hart's four target hart.v. The phase 5 cache lives under
# cache/ (phase_7.pdf 1). No associative arrays on purpose -- macOS ships
# bash 3.2.
dut_for() {
    case "$1" in
        rf_bypass | rf_no_bypass) echo "rf" ;;
        hart_*) echo "hart" ;;
        cache | plru) echo "cache/$1" ;;
        *) echo "$1" ;;
    esac
}

# Every non-testbench .v file at the repo root, plus cache/, is a potential
# dependency (hart instantiates alu/rf/decoder/fpu/rat/cdb_arb and the cache,
# decoder instantiates imm), so every module is compiled against the full set.
# Grading compiles riscv_fv.v with iverilog too, so it is in the set.
SOURCES=()
while IFS= read -r f; do
    SOURCES+=("${f}")
done < <( (find "${SUBMISSION_DIR}" -maxdepth 1 -name '*.v' ! -name '*_tb.v';
           find "${SUBMISSION_DIR}/cache" -maxdepth 1 -name '*.v' ! -name '*_tb.v' 2>/dev/null) | sort)

overall_status=0

for name in "${MODULES[@]}"; do
    dut_name="$(dut_for "${name}")"
    dut="${SUBMISSION_DIR}/${dut_name}.v"
    tb="${SUBMISSION_DIR}/${name}_tb.v"

    if [[ ! -f "${dut}" ]]; then
        echo "SKIP Verilog: ${name}  --  ${dut_name}.v not found" >> "${SUMMARY_FILE}"
        continue
    fi
    if [[ ! -s "${tb}" ]]; then
        echo "SKIP Verilog: ${name}  --  ${name}_tb.v not written yet" >> "${SUMMARY_FILE}"
        continue
    fi

    log="${BUILD_DIR}/${name}.log"
    sim="${BUILD_DIR}/${name}_sim"

    if ! iverilog -g2005 -s "${name}_tb" -o "${sim}" "${tb}" "${SOURCES[@]}" > "${log}" 2>&1; then
        echo "FAIL Verilog: ${name}  --  compile error, see build/${name}.log" >> "${SUMMARY_FILE}"
        overall_status=1
        continue
    fi

    ( cd "${BUILD_DIR}" && vvp "${sim}" ) >> "${log}" 2>&1

    tally=$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "${log}" | tail -1)
    verdict=$(grep -E '^(ALL TESTS PASSED|TEST FAILED)$' "${log}" | tail -1)

    if [[ "${verdict}" == "ALL TESTS PASSED" ]]; then
        echo "PASS Verilog: ${name}  --  ${tally}" >> "${SUMMARY_FILE}"
    else
        echo "FAIL Verilog: ${name}  --  ${tally:-simulation did not report a verdict, see build/${name}.log}" >> "${SUMMARY_FILE}"
        overall_status=1
    fi
done

# The rule checker the autograder runs (lint/, see README.md). It compiles
# every source file as one design, so it gets one row for all of them.
if ! command -v ece552 >/dev/null 2>&1; then
    echo "SKIP Lint: ece552  --  not installed, run pip install ./lint" >> "${SUMMARY_FILE}"
elif ece552 validate -w "${SOURCES[@]}" > "${BUILD_DIR}/lint.log" 2>&1; then
    echo "PASS Lint: ece552  --  no rule violations" >> "${SUMMARY_FILE}"
else
    echo "FAIL Lint: ece552  --  rule violations, see build/lint.log" >> "${SUMMARY_FILE}"
    overall_status=1
fi

# Gate on the course random workload and independently diff full traces on
# short programs covering control, memory, integer/FP arithmetic and traps.
if speedup_out="$("${SCRIPT_DIR}/tools/speedup/compare.sh" "${SUBMISSION_DIR}" 2> "${BUILD_DIR}/speedup.err")"; then
    speedup_last="$(tail -1 <<< "${speedup_out}")"
    echo "PASS Speedup: vs phase 7  --  ${speedup_last#PASS }" >> "${SUMMARY_FILE}"
else
    speedup_err="$(head -1 "${BUILD_DIR}/speedup.err")"
    echo "FAIL Speedup: vs phase 7  --  ${speedup_err:-$(tail -1 <<< "${speedup_out}")}" >> "${SUMMARY_FILE}"
    overall_status=1
fi

if python3 "${SCRIPT_DIR}/tools/bench/compare.py" --current "${SUBMISSION_DIR}" \
        --program mixed_17 --program fp_loop --program ldbr_loop --program traps --program trap_jump \
        > "${BUILD_DIR}/retire-diff.csv" 2> "${BUILD_DIR}/retire-diff.log"; then
    echo "PASS Trace: vs phase 7  --  5 programs at 2 cache/latency settings" >> "${SUMMARY_FILE}"
else
    echo "FAIL Trace: vs phase 7  --  see build/retire-diff.log" >> "${SUMMARY_FILE}"
    overall_status=1
fi

# Formal verification (phase_7.pdf 6.2): riscv_fv.v needs at least ten
# assert statements, and fv/riscv/run.sh (the graded riscv_fv.sby) must PASS
# on riscv_fv.v, cdb_arb.v and rat.v. Needs the OSS CAD Suite (sby) on PATH.
fv_asserts=$(sed -e 's://.*$::' "${SUBMISSION_DIR}/riscv_fv.v" 2>/dev/null | grep -cE '\bassert[[:space:]]*\(' || true)
if [[ ! -f "${SUBMISSION_DIR}/rat.v" || ! -f "${SUBMISSION_DIR}/cdb_arb.v" ]]; then
    echo "SKIP FV: riscv_fv  --  rat.v or cdb_arb.v not written yet" >> "${SUMMARY_FILE}"
elif [[ "${fv_asserts}" -lt 10 ]]; then
    echo "FAIL FV: riscv_fv  --  ${fv_asserts} asserts, at least 10 needed" >> "${SUMMARY_FILE}"
    overall_status=1
elif ! command -v sby >/dev/null 2>&1; then
    echo "SKIP FV: riscv_fv  --  sby not installed, see README.md (OSS CAD Suite)" >> "${SUMMARY_FILE}"
elif "${SCRIPT_DIR}/fv/riscv/run.sh" "${SUBMISSION_DIR}" > "${BUILD_DIR}/fv.log" 2>&1 &&
     grep -q 'DONE (PASS' "${BUILD_DIR}/fv.log"; then
    echo "PASS FV: riscv_fv  --  ${fv_asserts} asserts, sby PASS" >> "${SUMMARY_FILE}"
else
    echo "FAIL FV: riscv_fv  --  sby did not pass, see build/fv.log" >> "${SUMMARY_FILE}"
    overall_status=1
fi

echo "Wrote ${SUMMARY_FILE}"
echo "Build/sim logs and waveforms: ${BUILD_DIR}"
exit "${overall_status}"
