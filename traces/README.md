# traces

Programs and reference traces for the hart testbenches (`hart_tb_common.vh`).

| File | Source |
|---|---|
| `no_hazard_program.hex`, `no_hazard.trace` | Phase 4 course trace (12927 instructions, column format). |
| `hazard_program.hex`, `hazard_fwd.trace` | Phase 4 course trace, a cycle-by-cycle log of an in-order pipeline with forwarding (49 cycles in its own count). |
| `hazard_fwd_retire.trace` | `hazard_fwd.trace` converted to retire rows in the column format. |
| `random_program.hex`, `random_dmem.hex` | Phase 6: the random M+F program and its golden data memory. |
| `directed/*.hex`, `directed/*.trace` | Directed phase 7 programs and their `iss.py` reference traces. |

Regenerate the converted and directed files with
`python3 tools/hart_traces/gen_directed.py && python3 tools/hart_traces/convert_hazard.py`
(see `tools/hart_traces/README.md`).
