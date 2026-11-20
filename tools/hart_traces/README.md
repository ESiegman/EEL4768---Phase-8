# hart_traces

Test-only scripts that make the programs and reference traces the phase 7
hart testbenches run (`hart_tb_common.vh`). Nothing here is part of the
submission, and nothing here is linted.

| File | What it does |
|---|---|
| `asm.py` | A small RV32IMF assembler with labels. The R/I/S/R4 encoders are copied from `tools/hart_diff/directed.py` (not imported, so that file can change). Load/store/addi/jalr immediates must fit in 12 signed bits. |
| `reftrace.py` | The trace format (the 15 phase 4 columns of `traces/no_hazard.trace` plus 11 FP/rdata columns, `x` = don't-care) and the conversion of `tools/hart_diff/iss.py` output into it. `iss.py` is run unmodified. |
| `gen_directed.py` | The directed programs (control, traps, trap_jump, rename, memory, mext and three out-of-order witnesses). Writes `traces/directed/<name>.hex` and `<name>.trace`. |
| `convert_hazard.py` | Converts the phase 4 cycle log `traces/hazard_fwd.trace` into retire rows, `traces/hazard_fwd_retire.trace`. |

Regenerate everything from the repo root (the output is deterministic, so
`git diff` should show nothing unless a program changed):

```
python3 tools/hart_traces/gen_directed.py
python3 tools/hart_traces/convert_hazard.py
```

## Where `iss.py` is not exact

- **FP arithmetic.** `iss.py` uses the stand-in FPU's fake math. Programs
  with FP arithmetic either run without a reference (the phase 6 random
  program, golden memory only) or mark the FP results and every `fflags`
  from the first FP arithmetic instruction on as don't-cares
  (`witness_fdiv`, where nothing reads the result). `flw`, `fsw`,
  `fmv.w.x` and `fmv.x.w` are exact and are used freely.
- **Misaligned branch/jump targets.** `iss.py` jumps to them instead of
  trapping. `trap_jump` lists each such instruction; the reference is made
  by running `iss.py` on a copy of the program where it is replaced by an
  instruction with the same architectural effect as the trapped one (no rd
  write, next pc = pc + 4, the same integer registers read: `addi x0, x0, 0`
  for `jal`, `addi x0, rs1, 0` for `jalr`, `add x0, rs1, rs2` for a taken
  branch), and the real word and `trap = 1` are put back in the row.

## Column rules (`hart_tb_common.vh`)

A field is compared only if it is not `x` in the trace **and** the phase 4
rule says to: rs1 for OP, OP-IMM, LOAD, STORE, BRANCH, JALR (plus the
integer-reading F instructions), rs2 for OP, STORE, BRANCH; `rd_wdata` when
`rd != 0`; `mem_addr`/`mask` when `mem_op != 0`; `mem_wdata` for stores, on
the masked lanes only. `trap` and `halt` are always compared.
