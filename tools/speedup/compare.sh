#!/usr/bin/env bash
set -uo pipefail

# Phase 8 speedup check (extra_credit.pdf 4.2): runs hart_cpi_tb.v on the
# frozen phase 7 design in baseline/phase7/ and on the current design, then
# reports the IPC speedup per program in the graded configuration (PLRU,
# 4 ways, 2 KB, 16 B blocks, prefetch on, 4-cycle memory). hart_cpi_tb.v
# also checks every run's retire stream, so a wrong answer fails here too.
#
# usage: tools/speedup/compare.sh [submission_dir]
# Last line: "<PASS|BELOW> random +X.X% | hazard +Y.Y% | no_hazard +Z.Z%".
# The 25% goal is checked on the random program; no_hazard is already at
# CPI 1.0, the single-issue limit.

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TOOL_DIR}/../.." && pwd)"
SUB_DIR="$(cd "${1:-${REPO_DIR}}" && pwd)"
OUT_DIR="${REPO_DIR}/build/speedup"
mkdir -p "${OUT_DIR}"

GOAL=25

sources() {
    ( find "$1" -maxdepth 1 -name '*.v' ! -name '*_tb.v'
      find "$1/cache" -maxdepth 1 -name '*.v' ! -name '*_tb.v' 2>/dev/null ) | sort
}

# Runs hart_cpi_tb against one design and prints its "graded lat4" line.
run_cpi() {
    local name="$1" dir="$2" srcs=()
    while IFS= read -r f; do srcs+=("${f}"); done < <(sources "${dir}")
    if ! iverilog -g2005 -I "${REPO_DIR}" -s hart_cpi_tb -o "${OUT_DIR}/${name}_sim" \
            "${REPO_DIR}/hart_cpi_tb.v" "${srcs[@]}" > "${OUT_DIR}/${name}.log" 2>&1; then
        echo "compile error in ${name}, see build/speedup/${name}.log" >&2
        return 1
    fi
    ( cd "${REPO_DIR}" && vvp -n "${OUT_DIR}/${name}_sim" ) >> "${OUT_DIR}/${name}.log" 2>&1
    if ! grep -q '^ALL TESTS PASSED$' "${OUT_DIR}/${name}.log"; then
        echo "hart_cpi_tb failed on ${name}, see build/speedup/${name}.log" >&2
        return 1
    fi
    grep -E '^ *graded lat4 ' "${OUT_DIR}/${name}.log" | tail -1
}

base_line="$(run_cpi baseline "${REPO_DIR}/baseline/phase7")" || exit 1
new_line="$(run_cpi current "${SUB_DIR}")" || exit 1

# "| no_hazard  13117 cyc ... | hazard   47 cyc ... | random 118725 cyc ..."
cycles() {
    sed -n "s/.*| *$2 *\([0-9][0-9]*\) cyc.*/\1/p" <<< "$1"
}

result=""
met=1
for prog in random hazard no_hazard; do
    old="$(cycles "${base_line}" "${prog}")"
    new="$(cycles "${new_line}" "${prog}")"
    # Same instructions retired, so IPC_new / IPC_old = cycles_old / cycles_new.
    if [[ -z "${old}" || -z "${new}" || "${new}" == 0 ]]; then
        echo "missing or invalid cycle count for ${prog}" >&2
        exit 1
    fi
    pct="$(awk -v o="${old}" -v n="${new}" 'BEGIN { printf "%+.1f", (o / n - 1) * 100 }')"
    echo "${prog}: phase 7 ${old} cycles, now ${new} cycles, speedup ${pct}%"
    result="${result}${result:+ | }${prog} ${pct}%"
    if [[ "${prog}" == "random" ]] && (( 100 * old < (100 + GOAL) * new )); then
        met=0
    fi
done

if [[ "${met}" -eq 1 ]]; then
    echo "PASS ${result}"
else
    echo "BELOW ${result}"
    exit 1
fi
