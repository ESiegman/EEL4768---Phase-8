# Phase 8 arithmetic datapaths

On the supplied random program, Phase 7 spent 53,970 cycles without a retirement immediately before an integer M instruction. An iterative multiply or divide held the shared integer ALU for 33 busy cycles. Independent integer work queued behind it. Finite floating-point divide and square root also took 26 busy cycles, and an older unfinished operation could hold up retirement even when a younger operation had completed.

## Integer multiply and divide

The multiplier forms all 32 shifted partial products of the unsigned operand magnitudes. A balanced tree sums them. The first clock edge captures four sums of eight partial products each. The second captures their 64-bit sum. The output sign correction and half selection implement all four multiply instructions, including signed-by-unsigned high multiply.

The divider consumes two dividend bits per step. Starting with a remainder smaller than the divisor, the next trial remainder is smaller than four times the divisor. Three parallel subtractions test one, two and three times the divisor. The largest successful subtraction gives both the next base-four quotient digit and the new remainder.

When the upper 24 or 16 dividend bits already form a remainder smaller than the divisor, their quotient digits would all be zero. Loading that prefix directly leaves four or eight iterations. A full-width quotient takes sixteen. Division by zero, division by magnitude one and a dividend smaller than the divisor finish at launch. Including launch, the divider uses 1, 5, 9 or 17 busy cycles. Sign correction gives a signed remainder the dividend’s sign, including the required zero-divisor and signed-overflow cases.

## Floating-point divide and square root

Normalized finite inputs and exponent adjustment put the result significand in the interval [1, 2). Its leading bit is known. The launch edge stores that bit and the remainder from its subtraction. Each of the next eight cycles computes three successive quotient or root bits. In square-root mode each step brings down two bits of the radicand. In divide mode it brings down the next binary place of the remainder. The shared rounder receives the same 24 significand bits, guard bit and final-remainder sticky bit as in Phase 7. The FPU continues to handle special operands, rounding modes and exception flags.

Both units hold a completed result through backpressure until the consumer advances. The additional adders and trial subtractors trade area and combinational delay for fewer clocks. The measurements use RTL simulation. Measuring maximum clock frequency and elapsed hardware time would require a target device, synthesis constraints and timing analysis.

## Why arithmetic

Phase 7 already resolves a ready branch at dispatch, and the target can issue in that cycle. Its integer branch/call loop took 244 cycles for 242 instructions. Even ideal single-issue throughput could recover less than 1% there. The load-dependent branch loop spent 871 cycles retiring 677 instructions at the graded settings. Its 64-byte stride stresses the memory system, which these arithmetic changes do not accelerate. The final measurements include both controls. [Measurement table](phase8_results.md)

## Submission contents

`make submission` writes `build/phase8_submission.zip` with these 21 RTL files in the course layout.

- Core and integer backend — `hart.v`, `alu.v`, `imm.v`, `rf.v`, `decoder.v`, `rs.v`, `reservation_station.v`, `rat.v`, `cdb_arb.v` and `lsu.v`.
- Floating point — `fp_rs.v`, `fp_exec.v`, `fcsr.v`, `fpu.v`, `fpu_fma.v`, `fpu_divsqrt.v`, `fpu_round.v` and `fpu_cvt.v`.
- Cache and formal harness — `cache/cache.v`, `cache/plru.v` and `riscv_fv.v`.
