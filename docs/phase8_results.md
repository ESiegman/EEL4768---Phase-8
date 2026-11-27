# Phase 8 IPC measurements

The supplied random program retired 34,598 instructions in 61,884 cycles, down from 118,725 in Phase 7. IPC rose from 0.2914 to 0.5591, a **91.85% gain**. At the graded settings, the geometric mean gain on the original 12 programs rose from **84.02%** with arithmetic changes alone to **97.30%** with the memory changes. Nine of those 12 now exceed 25%. Including two additional memory workloads brings the 14-program geometric mean gain to **82.17%**. The hidden grading programs are available only to course staff.

## Per-program results

The graded configuration uses a four-way 2 KiB PLRU cache, 16-byte lines, next-line prefetch and four-cycle memory. All 21 reference RTL files match Phase 7 commit `39d26f0` and the team’s Phase 7 submission zip byte for byte. Both designs use the same memory model and count from reset release through retirement of `ebreak`. For identical retire streams the IPC ratio equals Phase 7 cycles divided by Phase 8 cycles.

| Program | Retired | Phase 7 cycles | Phase 8 cycles | Phase 7 IPC | Phase 8 IPC | IPC gain |
|---|---:|---:|---:|---:|---:|---:|
| `random` | 34,598 | 118,725 | 61,884 | 0.2914 | 0.5591 | +91.85% |
| `hazard` | 38 | 47 | 43 | 0.8085 | 0.8837 | +9.30% |
| `no_hazard` | 12,927 | 13,117 | 13,064 | 0.9855 | 0.9895 | +0.41% |
| `div_loop` | 262 | 6,600 | 1,452 | 0.0397 | 0.1804 | +354.55% |
| `fp_loop` | 326 | 2,537 | 1,449 | 0.1285 | 0.2250 | +75.09% |
| `int_loop` | 242 | 244 | 244 | 0.9918 | 0.9918 | +0.00% |
| `ldbr_loop` | 677 | 871 | 679 | 0.7773 | 0.9971 | +28.28% |
| `mem_loop` | 387 | 709 | 453 | 0.5458 | 0.8543 | +56.51% |
| `mixed_17` | 717 | 2,840 | 1,156 | 0.2525 | 0.6202 | +145.67% |
| `mixed_41` | 717 | 2,668 | 1,012 | 0.2687 | 0.7085 | +163.64% |
| `mixed_73` | 717 | 1,467 | 891 | 0.4888 | 0.8047 | +64.65% |
| `mul_loop` | 198 | 4,424 | 456 | 0.0448 | 0.4342 | +870.18% |
| `pointer_walk` | 740 | 1,030 | 935 | 0.7184 | 0.7914 | +10.16% |
| `read_gather` | 580 | 771 | 667 | 0.7523 | 0.8696 | +15.59% |

## Previously unchanged workloads

- The strided store/load loop and the load-dependent branch loop each issued 128 external line reads in Phase 7. All 64 loads in each program can now use recently stored words, eliminating those reads. The branch loop is within two cycles of one retirement per cycle.
- The short hazard program saves four cycles by forwarding recently stored data. With 38 retirements in 47 baseline cycles, even ideal single-issue throughput would yield only 23.68% improvement. The no-hazard program overlaps reads with other work, saving 53 cycles while issuing the same 64 external reads. Its baseline is already 0.9855 IPC.
- The integer branch/call loop already retires on every cycle following its two fill cycles. Its 244 cycles are the floor with this pipeline.

The new `pointer_walk` workload follows a shuffled chain of dependent addresses and gains 10.16%. The `read_gather` workload issues independent irregular reads and gains 15.59%. Both initialize memory with partial stores, which exercises reads without full-word store forwarding. Across the original 144 cache, latency and program combinations, 76 became faster than the arithmetic-only design and 68 tied. [All 168 per-configuration measurements](phase8_measurements.csv)

Each program has equal weight in the geometric mean below.

| Cache configuration | Latency 1 geomean gain | Latency 4 | Latency 10 |
|---|---:|---:|---:|
| graded | +71.94% | +82.17% | +94.80% |
| default | +70.98% | +75.81% | +84.27% |
| small | +72.14% | +84.61% | +98.31% |
| large | +71.78% | +81.27% | +93.84% |

## Contribution of each datapath

| Design on the graded random program | Cycles | IPC | Gain vs. Phase 7 |
|---|---:|---:|---:|
| Frozen Phase 7 | 118,725 | 0.2914 | — |
| Faster RV32M unit | 66,911 | 0.5171 | +77.44% |
| Faster RV32M and FP divide/square root | 63,116 | 0.5482 | +88.11% |
| Both arithmetic changes plus memory changes | 61,884 | 0.5591 | +91.85% |

The FP change saved 3,795 cycles on the random program and 1,088 on the FP-only loop. The memory changes saved another 1,232 cycles on the random program. Each gap below is classified by its neighboring retired instructions. A gap may include stalls from several parts of the pipeline.

| Cycles without retirement | Phase 7 | Faster RV32M | Both arithmetic changes | Plus memory changes |
|---|---:|---:|---:|---:|
| Pipeline fill | 2 | 2 | 2 | 2 |
| After branch or jump | 2,753 | 612 | 527 | 510 |
| Before load | 5,879 | 5,905 | 5,949 | 4,660 |
| Before store | 464 | 464 | 464 | 464 |
| Before integer M | 53,970 | 3,424 | 3,451 | 3,466 |
| Before FP or CSR | 19,316 | 20,161 | 16,380 | 16,437 |
| Before other ALU | 1,743 | 1,745 | 1,745 | 1,747 |
| Before trap or halt | 0 | 0 | 0 | 0 |

## Correctness checks

- The differential bench compared every retirement signal on each valid retirement, including integer/FP operands, writes, flags, trap/halt, PC and memory lanes. All 168 performance cases matched. Two directed trap programs matched at the same 12 cache/latency combinations, giving 192 matching comparisons in total.
- The cache forwarding bench passed 58 checks covering partial stores, collisions, reset, outstanding reads and same-cycle load delivery under both memory snapshot modes.
- The ALU passed one million seeded random operations across all eight M opcodes, plus directed sign, prefix-boundary, divide-by-zero, overflow, reset and stalled-consumer cases.
- The FP significand bench passed 10,000 integer-bound checks. Fresh Berkeley TestFloat vectors covered 250,000 divides and 25,000 square roots across the five rounding modes, with alternating static/dynamic rounding. The production FPU matched the expected results and exception flags for every vector. The checkout used TestFloat `a9c849f` and SoftFloat `afdc157` with the RISC-V specialization and tininess after rounding.
- Nine temporary mutations were tested independently. The table counts the failing checks produced by the corresponding unit bench.

| Unit | Injected error | Failing checks |
|---|---|---:|
| RV32M | Select the wrong multiply result half | 913 |
| RV32M | Encode quotient digit three as two | 249 |
| RV32M | Return zero for division by zero | 112 |
| FP divide/sqrt | Force the sticky bit to zero | 9,399 |
| FP divide/sqrt | Change the square-root trial constant from one to three | 4,819 |
| FP divide/sqrt | Add one to the initial division remainder | 5,000 |
| Cache | Overwrite all bytes on a partial store | 2 |
| Cache | Accept a buffered word without checking its tag | 6 |
| Cache | Delay a matching returned prefetch by one cycle | 2 |
