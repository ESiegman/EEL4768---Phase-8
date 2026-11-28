# Phase 8 processor changes

On the supplied random program, Phase 7 spent 53,970 cycles without a retirement immediately before an integer M instruction. An iterative multiply or divide held the shared integer ALU for 33 busy cycles. Independent integer work queued behind it. Finite floating-point divide and square root also took 26 busy cycles, and an older unfinished operation could hold up retirement even when a younger operation had completed.

## Integer multiply and divide

The multiplier forms all 32 shifted partial products of the unsigned operand magnitudes. A balanced tree sums them. The first clock edge captures four sums of eight partial products each. The second captures their 64-bit sum. The output sign correction and half selection implement all four multiply instructions, including signed-by-unsigned high multiply.

The divider consumes two dividend bits per step. Starting with a remainder smaller than the divisor, the next trial remainder is smaller than four times the divisor. Three parallel subtractions test one, two and three times the divisor. The largest successful subtraction gives both the next base-four quotient digit and the new remainder.

When the upper 24 or 16 dividend bits already form a remainder smaller than the divisor, their quotient digits would all be zero. Loading that prefix directly leaves four or eight iterations. A full-width quotient takes sixteen. Division by zero, division by magnitude one and a dividend smaller than the divisor finish at launch. Including launch, the divider uses 1, 5, 9 or 17 busy cycles. Sign correction gives a signed remainder the dividend’s sign, including the required zero-divisor and signed-overflow cases.

## Floating-point divide and square root

Normalized finite inputs and exponent adjustment put the result significand in the interval [1, 2). Its leading bit is known. The launch edge stores that bit and the remainder from its subtraction. Each of the next eight cycles computes three successive quotient or root bits. In square-root mode each step brings down two bits of the radicand. In divide mode it brings down the next binary place of the remainder. The shared rounder receives the same 24 significand bits, guard bit and final-remainder sticky bit as in Phase 7. The FPU continues to handle special operands, rounding modes and exception flags.

Both units hold a completed result through backpressure until the consumer advances. The additional adders and trial subtractors trade area and combinational delay for fewer clocks. The measurements use RTL simulation. Measuring maximum clock frequency and elapsed hardware time would require a target device, synthesis constraints and timing analysis.

## Forwarding from committed stores

Phase 7 writes a store miss through to memory without allocating the line in L1. A later load of the same word can then stall to fetch data the processor already supplied. The hart now keeps 64 recently stored words in a direct-mapped buffer. The index folds two groups of six address bits with XOR so that common power-of-two strides spread across slots. The remaining 24 tag bits, the 32-bit word and a valid bit cost 456 bytes of storage in total.

A complete store installs its word only when the cache accepts the store. A byte or halfword store updates the enabled lanes if the address already matches. A partial store alone cannot establish the contents of all four lanes. A load first checks L1, then uses a matching buffered word on an L1 miss. The LSU still delivers the full raw word on the retirement interface and separately extracts the requested signed or unsigned value.

## Starting confirmed loads earlier

The LSU can send a cache-line address as soon as an aligned load enters the queue with a ready base, when the head load receives its base on the common data bus, or when the load immediately following the head already has an address. It keeps these lookups behind older queued stores. The cache issues a read in an unused request slot after checking the L1, store-word buffer and outstanding addresses. It leaves two FIFO slots for ordinary traffic. A matching prefetch response can supply the head load on its arrival cycle. Stores still update memory in order, and the existing completion and retirement logic controls when a load becomes architecturally visible.

The existing front end resolves a ready branch at dispatch and can issue the target in that cycle. The integer branch/call loop already retires 242 instructions in 244 cycles, with just two cycles for pipeline fill. The load-dependent branch loop also reaches this limit once forwarding makes its branch operands available. These results favored accelerating actual loads over adding branch prediction and recovery logic. [Measurement table](phase8_results.md)

## Submission contents

`make submission` writes `build/phase8_submission.zip` with these 21 RTL files in the course layout.

- Core and integer backend — `hart.v`, `alu.v`, `imm.v`, `rf.v`, `decoder.v`, `rs.v`, `reservation_station.v`, `rat.v`, `cdb_arb.v` and `lsu.v`.
- Floating point — `fp_rs.v`, `fp_exec.v`, `fcsr.v`, `fpu.v`, `fpu_fma.v`, `fpu_divsqrt.v`, `fpu_round.v` and `fpu_cvt.v`.
- Cache and formal harness — `cache/cache.v`, `cache/plru.v` and `riscv_fv.v`.
