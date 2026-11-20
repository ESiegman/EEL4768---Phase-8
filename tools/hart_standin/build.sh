#!/usr/bin/env bash
set -euo pipefail

# TEST ONLY. Runs the phase 7 hart testbenches against a stand-in hart: the
# phase 6 pipelined hart and its submodules, extracted from git (commit
# e26772d by default) with module `hart` renamed to `hart_p6`, inside
# hart_adapter.v, which has the phase 7 ports. Nothing at the repo root is
# compiled except the testbench under test, so later changes to fpu.v and
# friends do not affect the stand-in. See README.md.
#
# usage: tools/hart_standin/build.sh [tb ...]
#   tb: hart_no_hazard_tb hart_hazard_tb hart_ooo_witness_tb hart_cpi_tb
#       (default: all four)
# env:  OUT      scratch directory (default build/hart_standin; not committed)
#       REV      git revision of the phase 6 hart (default e26772d)
#       ADAPTER  adapter source (default tools/hart_standin/hart_adapter.v);
#                point it at a modified copy to check that a bug is caught

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${TOOL_DIR}/../.." && pwd)"
OUT="${OUT:-${REPO}/build/hart_standin}"
REV="${REV:-e26772d}"
ADAPTER="${ADAPTER:-${TOOL_DIR}/hart_adapter.v}"
TBS=("$@")
if [[ ${#TBS[@]} -eq 0 ]]; then
    TBS=(hart_no_hazard_tb hart_hazard_tb hart_ooo_witness_tb hart_cpi_tb)
fi

SRC="${OUT}/src"
rm -rf "${SRC}"
mkdir -p "${SRC}/cache" "${REPO}/build"

git -C "${REPO}" show "${REV}:hart.v" | sed -e 's/^module hart #(/module hart_p6 #(/' > "${SRC}/hart_p6.v"
grep -q '^module hart_p6 #(' "${SRC}/hart_p6.v" || { echo "rename of module hart failed" >&2; exit 1; }
for f in alu decoder imm rf fpu fpu_fma fpu_cvt fpu_round fpu_divsqrt; do
    git -C "${REPO}" show "${REV}:${f}.v" > "${SRC}/${f}.v"
done
for f in cache plru; do
    git -C "${REPO}" show "${REV}:cache/${f}.v" > "${SRC}/cache/${f}.v"
done
cp "${ADAPTER}" "${SRC}/hart_adapter.v"

status=0
for tb in "${TBS[@]}"; do
    sim="${OUT}/${tb}.sim"
    log="${OUT}/${tb}.log"
    if ! iverilog -g2005 -I "${REPO}" -s "${tb}" -o "${sim}" "${REPO}/${tb}.v" \
            "${SRC}"/*.v "${SRC}"/cache/*.v > "${log}" 2>&1; then
        echo "FAIL ${tb}: compile error, see ${log}"
        status=1
        continue
    fi
    # vvp runs from build/, like make test, so the testbench finds ../traces.
    start=$(date +%s)
    ( cd "${REPO}/build" && vvp -n "${sim}" ) >> "${log}" 2>&1
    secs=$(( $(date +%s) - start ))
    tally=$(grep -E '^[0-9]+ passed, [0-9]+ failed$' "${log}" | tail -1)
    verdict=$(grep -E '^(ALL TESTS PASSED|TEST FAILED)$' "${log}" | tail -1)
    echo "${verdict:-NO VERDICT} ${tb}: ${tally} (${secs} s, ${log})"
    [[ "${verdict}" == "ALL TESTS PASSED" ]] || status=1
done
exit "${status}"
