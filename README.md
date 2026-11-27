# EEL4768---Phase-8
[![CI](https://github.com/ESiegman/EEL4768---Phase-8/actions/workflows/ci.yml/badge.svg)](https://github.com/ESiegman/EEL4768---Phase-8/actions/workflows/ci.yml)

An out-of-order (Tomasulo-style) RV32I hart with the M and F extensions.
Phase 8 (extra credit, [documentation/extra_credit.pdf](documentation/extra_credit.pdf))
raises IPC from 0.2914 to 0.5482 (+88.11%) on the supplied 34,598-instruction
random program at the graded cache settings. The frozen Phase 7 reference in
`baseline/phase7/` matches Phase 7 commit `39d26f0`.
Everything in the phase 7 assignment,
[documentation/phase_7.pdf](documentation/phase_7.pdf), still applies, and the
LSU interface is described in [docs/lsu_interface.md](docs/lsu_interface.md).

`make test` runs every testbench, the `ece552` rule checker and the formal
check, and writes a summary to `results/local.txt`. Logs go to `build/`.
`make help` lists the other targets.

## Tools

- **Icarus Verilog** (`iverilog`, `vvp`): required. `brew install icarus-verilog`,
  `apt install iverilog`, or `conda env create -f environment.yaml`.
- **Rule checker** (`ece552`): `pip install ./lint`. Use Python 3.10 to 3.13;
  its `pyslang==9.1.0` dependency has no wheel for 3.14. CI uses 3.12.
- **Formal** (`sby`): the OSS CAD Suite on PATH, as in phase_7.pdf 6.3. CI pins
  the 2026-10-22 release.

A missing rule checker or `sby` shows as SKIP, not FAIL. CI installs all
three, so its run is the full check.


## Reproduce the Phase 8 results

`make speedup` runs the supplied programs and checks the 25% target on the random program. `make bench` compares every retirement field between Phase 7 and Phase 8 on 12 workloads. It reports per-program cycles, IPC and percentage gains at the graded and default cache settings. Python 3.8+ and Icarus Verilog are required. The hidden grading programs are available only to course staff.

```sh
make bench-full > measurements.csv
python3 tools/bench/compare.py --full --program traps --program trap_jump
make submission
```

The full benchmark crosses four caches with memory latencies of 1, 4 and 10 cycles. `python3 tools/bench/generate.py` regenerates the nine committed loops. The submission archive is `build/phase8_submission.zip`.

For the extended arithmetic tests, run `make test` first, then `vvp -n build/alu_sim +no_dump +m_vectors=1000000`. With a RISC-V-specialized Berkeley TestFloat build, `python3 tools/bench/testfloat.py /path/to/testfloat_gen` checks an additional 275,000 divide and square-root vectors. [TestFloat build instructions](tools/fpu_vectors/README.md)

[Benchmark results](docs/phase8_results.md) · [Datapath design](docs/phase8_design.md)
