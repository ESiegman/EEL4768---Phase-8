#!/usr/bin/env python3
"""TEST ONLY. Converts the phase 4 cycle log traces/hazard_fwd.trace into the
column format (tools/hart_traces/reftrace.py), one row per retired
instruction, for an out-of-order hart whose retire timing differs.

usage: convert_hazard.py [in.trace] [out.trace]
       (default: traces/hazard_fwd.trace -> traces/hazard_fwd_retire.trace)

Input lines look like
    cycle=00016 [00400028] 000ea683 r[29]=10010010 r[--]=-------- w[13]=00000032 l[10010010,1111]=00000032
    cycle=00017 BUBBLE
BUBBLE lines and cycle numbers are dropped. Kept: pc, inst, the two source
reads (r[--] = not read -> don't-care), the rd write (no w[] -> rd 0), and
load (l[addr,mask]=data) / store (s[addr,mask]=data) fields. Masks are
binary in the log and hex in the column format.
trap = 0 and halt = (inst == ebreak) are derived from the instruction: the
log has no trap marker and the program has no illegal or misaligned
instruction (checked here with the decoder mirror in reftrace.py). Load
addresses are word aligned in this program, so addr is the word address.
Everything else (next_pc, all FP columns) is a don't-care.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import reftrace  # noqa: E402

REPO = os.path.join(HERE, "..", "..")
LINE = re.compile(r"^cycle=(\d+) \[(\w{8})\] (\w{8}) r\[(..)\]=(\S{8}) r\[(..)\]=(\S{8})(.*)$")


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "traces", "hazard_fwd.trace")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(REPO, "traces", "hazard_fwd_retire.trace")
    rows = []
    last_cycle = None
    for ln in open(src):
        ln = ln.rstrip("\n")
        if not ln.startswith("cycle=") or "BUBBLE" in ln:
            m = re.match(r"Program halted after (\d+) cycles", ln)
            if m:
                last_cycle = int(m.group(1))
            continue
        m = LINE.match(ln)
        if not m:
            raise ValueError("unparsed line: " + ln)
        pc, inst = int(m.group(2), 16), int(m.group(3), 16)
        if not reftrace.legal(inst):
            raise ValueError("illegal instruction in the hazard trace: %08x" % inst)
        r1a, r1d, r2a, r2d, rest = m.group(4), m.group(5), m.group(6), m.group(7), m.group(8)
        row = ["%08x" % pc, "%08x" % inst, "0", "1" if inst == 0x00100073 else "0"]
        for a, d in ((r1a, r1d), (r2a, r2d)):
            if a == "--":
                row += ["xx", "xxxxxxxx"]
            else:
                row += ["%02x" % int(a), d.lower()]
        w = re.search(r"w\[\s*(\d+)\]=(\w{8})", rest)
        row += ["%02x" % int(w.group(1)), w.group(2).lower()] if w else ["00", "xxxxxxxx"]
        ld = re.search(r"l\[(\w{8}),([01]{4})\]=(\w{8})", rest)
        st = re.search(r"s\[(\w{8}),([01]{4})\]=(\w{8})", rest)
        if ld:
            row += ["1", ld.group(1).lower(), "%x" % int(ld.group(2), 2), "xxxxxxxx"]
        elif st:
            row += ["2", st.group(1).lower(), "%x" % int(st.group(2), 2), st.group(3).lower()]
        else:
            row += ["0", "xxxxxxxx", "x", "xxxxxxxx"]
        row.append("xxxxxxxx")   # next_pc
        row += ["xx", "xxxxxxxx"] * 3 + ["x", "xx", "xxxxxxxx", "xx", "xxxxxxxx"]
        rows.append(row)
    notes = ["Converted from traces/hazard_fwd.trace (phase 4 + forwarding, %s cycles) by" % last_cycle,
             "tools/hart_traces/convert_hazard.py: retire rows only; trap/halt derived from inst;",
             "next_pc and FP columns are don't-cares."]
    reftrace.write_trace(dst, rows, "hazard_fwd: phase 4 hazard program, retire order", notes)
    print("%s: %d retired (phase 4 took %s cycles)" % (dst, len(rows), last_cycle))


if __name__ == "__main__":
    main()
