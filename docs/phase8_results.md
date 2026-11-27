# Phase 8 IPC measurements

The supplied random program retired 34,598 instructions in 63,116 cycles, down from 118,725 cycles in Phase 7. IPC rose from 0.2914 to 0.5482, an **88.11% gain**. Across 12 programs the geometric mean gain was **84.02%** at the graded cache settings. Seven programs exceeded 25%. The five control and memory workloads took the same number of cycles on both designs. The course measures the final grade on separate hidden programs.

## Per-program results

The graded configuration uses a four-way 2 KiB PLRU cache, 16-byte lines, next-line prefetch and four-cycle memory. All 21 reference RTL files match Phase 7 commit `39d26f0` and the team’s Phase 7 submission zip byte for byte. Both designs use the same memory model and count from reset release through retirement of `ebreak`. For identical retire streams the IPC ratio equals Phase 7 cycles divided by Phase 8 cycles.

| Program | Retired | Phase 7 cycles | Phase 8 cycles | Phase 7 IPC | Phase 8 IPC | IPC gain |
|---|---:|---:|---:|---:|---:|---:|
| `random` | 34,598 | 118,725 | 63,116 | 0.2914 | 0.5482 | +88.11% |
| `hazard` | 38 | 47 | 47 | 0.8085 | 0.8085 | +0.00% |
| `no_hazard` | 12,927 | 13,117 | 13,117 | 0.9855 | 0.9855 | +0.00% |
| `div_loop` | 262 | 6,600 | 1,452 | 0.0397 | 0.1804 | +354.55% |
| `fp_loop` | 326 | 2,537 | 1,449 | 0.1285 | 0.2250 | +75.09% |
| `int_loop` | 242 | 244 | 244 | 0.9918 | 0.9918 | +0.00% |
| `ldbr_loop` | 677 | 871 | 871 | 0.7773 | 0.7773 | +0.00% |
| `mem_loop` | 387 | 709 | 709 | 0.5458 | 0.5458 | +0.00% |
| `mixed_17` | 717 | 2,840 | 1,156 | 0.2525 | 0.6202 | +145.67% |
| `mixed_41` | 717 | 2,668 | 1,012 | 0.2687 | 0.7085 | +163.64% |
| `mixed_73` | 717 | 1,467 | 915 | 0.4888 | 0.7836 | +60.33% |
| `mul_loop` | 198 | 4,424 | 456 | 0.0448 | 0.4342 | +870.18% |

Each program has equal weight in the geometric mean. The integer branch/call loop and the two supplied hazard programs spend zero retirement gaps waiting for M or FP work in Phase 7. The two strided memory controls exercise accesses beyond the graded cache capacity. The multiplier and divider accelerate workloads in proportion to their use of the changed datapaths. [All 144 per-configuration measurements](phase8_measurements.csv)

| Cache configuration | Latency 1 geomean gain | Latency 4 | Latency 10 |
|---|---:|---:|---:|
| graded | +84.59% | +84.02% | +81.79% |
| default | +84.88% | +84.71% | +84.08% |
| small | +84.52% | +83.47% | +79.59% |
| large | +84.83% | +84.54% | +83.45% |

## Contribution of each datapath

| Design on the graded random program | Cycles | IPC | Gain vs. Phase 7 |
|---|---:|---:|---:|
| Frozen Phase 7 | 118,725 | 0.2914 | — |
| Faster RV32M unit | 66,911 | 0.5171 | +77.44% |
| Faster RV32M and FP divide/square root | 63,116 | 0.5482 | +88.11% |

The FP change saved another 3,795 cycles on the random program and 1,088 on the FP-only loop. The random program still spends 16,380 cycles without retirement immediately before an FP or CSR instruction. These counts classify a gap by neighboring retired instructions. They do not measure execution-unit occupancy.

| Cycles without retirement | Phase 7 | Faster RV32M | Both changes |
|---|---:|---:|---:|
| Pipeline fill | 2 | 2 | 2 |
| After branch or jump | 2,753 | 612 | 527 |
| Before load | 5,879 | 5,905 | 5,949 |
| Before store | 464 | 464 | 464 |
| Before integer M | 53,970 | 3,424 | 3,451 |
| Before FP or CSR | 19,316 | 20,161 | 16,380 |
| Before other ALU | 1,743 | 1,745 | 1,745 |
| Before trap or halt | 0 | 0 | 0 |

## Correctness checks

- The differential bench compared every retirement signal on each valid retirement, including integer/FP operands, writes, flags, trap/halt, PC and memory lanes. All 144 performance cases matched. Two directed trap programs matched at the same 12 cache/latency combinations, giving 168 matching comparisons in total.
- The ALU passed one million seeded random operations across all eight M opcodes, plus directed sign, prefix-boundary, divide-by-zero, overflow, reset and stalled-consumer cases.
- The FP significand bench passed 10,000 integer-bound checks. Fresh Berkeley TestFloat vectors covered 250,000 divides and 25,000 square roots across the five rounding modes, with alternating static/dynamic rounding. The production FPU matched the expected results and exception flags for every vector. The checkout used TestFloat `a9c849f` and SoftFloat `afdc157` with the RISC-V specialization and tininess after rounding.
- Six temporary mutations were tested independently. The table counts the failing checks produced by the corresponding unit bench.

| Unit | Injected error | Failing checks |
|---|---|---:|
| RV32M | Select the wrong multiply result half | 913 |
| RV32M | Encode quotient digit three as two | 249 |
| RV32M | Return zero for division by zero | 112 |
| FP divide/sqrt | Force the sticky bit to zero | 9,399 |
| FP divide/sqrt | Change the square-root trial constant from one to three | 4,819 |
| FP divide/sqrt | Add one to the initial division remainder | 5,000 |
