# hart_standin

A test-only stand-in hart with the phase 7 ports, used to check the phase 7
hart testbenches before the out-of-order hart exists. It is the phase 6
pipelined hart from git (commit `e26772d`), renamed `hart_p6`, inside
`hart_adapter.v`:

- instruction fetch: `hart_p6`'s instruction cache asks for whole lines;
  the adapter reads each line one word per cycle through `o_imem_raddr` /
  `i_imem_rdata` and hands it back. This makes fetch slow, so **cycle counts
  and CPI from the stand-in mean nothing**;
- data memory: passed straight through (`i_mem_ready` unused);
- retire: `hart_p6`'s retire stream, one cycle late;
- complete: driven from the undelayed retire stream, in program order, one
  cycle before each retire, tags counting mod 8, only for the CDB classes.

```
tools/hart_standin/build.sh                         # all four hart testbenches
tools/hart_standin/build.sh hart_hazard_tb          # one of them
ADAPTER=/tmp/broken_adapter.v OUT=/tmp/sb tools/hart_standin/build.sh hart_no_hazard_tb
```

`build.sh` extracts the sources with `git show` into `build/hart_standin/`
(or `$OUT`), so nothing at the repo root is compiled except the testbench,
and later changes to `fpu.v` and friends do not affect it. Logs go next to
the extracted sources.

## Expected results

| Testbench | Result | Why |
|---|---|---|
| `hart_no_hazard_tb` | PASS | |
| `hart_hazard_tb` | FAIL, only `trap_jump` | The phase 6 hart never trapped on a misaligned taken branch/jump target (the skeleton says it must); it jumps there instead. Everything else passes, including all ten golden sections of the random program. |
| `hart_ooo_witness_tb` | FAIL, 0 out-of-order completes | The stand-in completes in order, which shows the witness check can fail. |
| `hart_cpi_tb` | FAIL | Fetch is slow (see above). |

All complete-stream checks report 0 errors.

## Bugs it was used to inject

Each was made in a scratch copy of `hart_adapter.v` (passed with
`ADAPTER=`) and was caught: a wrong `rs1_rdata` on one instruction, no
complete for loads, a complete for stores, a wrong complete value, a tag
repeated, a retire skipped, and a store's main memory write replayed at the
end (caught by the `memory` program, which flushes the cache).
