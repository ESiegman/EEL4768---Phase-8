# Phase 8 IPC measurements

All 21 reference files match Phase 7 commit `39d26f0` and the team’s Phase 7 submission zip byte for byte. The comparison uses the same programs, memory model, cache parameters and reset-to-`ebreak` interval for both designs. The retire count includes the terminating instruction.

## Phase 7 baseline

| Program | Retired | Graded cache, latency 4 (cycles) | Default cache, latency 1 (cycles) |
|---|---:|---:|---:|
| random | 34598 | 118725 | 113469 |
| hazard | 38 | 47 | 45 |
| no_hazard | 12927 | 13117 | 12938 |
| div_loop | 262 | 6600 | 6600 |
| fp_loop | 326 | 2537 | 2537 |
| int_loop | 242 | 244 | 244 |
| ldbr_loop | 677 | 871 | 679 |
| mem_loop | 387 | 709 | 490 |
| mixed_17 | 717 | 2840 | 2852 |
| mixed_41 | 717 | 2668 | 2668 |
| mixed_73 | 717 | 1467 | 1446 |
| mul_loop | 198 | 4424 | 4424 |
