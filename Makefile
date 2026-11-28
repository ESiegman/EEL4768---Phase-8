.PHONY: help test ci schematics fv speedup bench bench-full submission clean

help:
	@echo "make test        run your testbenches (writes results/local.txt)"
	@echo "make ci          same thing, under the name CI uses (results/ci.txt)"
	@echo "make schematics  synthesize alu/imm/rf/decoder/cache/fpu/rat/cdb_arb/hart with yosys and"
	@echo "                 render gate-level SVGs with netlistsvg (build/schematics/)"
	@echo "make fv          formal check: fv/riscv/run.sh on riscv_fv.v, cdb_arb.v, rat.v"
	@echo "                 (needs the OSS CAD Suite on PATH, phase_7.pdf 6.3)"
	@echo "make speedup     IPC vs the frozen phase 7 design (baseline/phase7/)"
	@echo "make bench       compare retire traces and IPC on 14 workloads"
	@echo "make bench-full  run every workload at four cache settings and three latencies"
	@echo "make submission  package the submission RTL in build/phase8_submission.zip"
	@echo "make clean       remove results/ and build/"
	@echo
	@echo "Details:      ./run_test.sh <name> [submission_dir]"
	@echo "Write your own <check>_tb.v for alu, imm, rf_bypass, rf_no_bypass,"
	@echo "decoder, cache, cache_forward, plru, fpu, fpu_round, rs, fp_rs, fcsr, rat, cdb_arb,"
	@echo "fpu_divsqrt, lsu, hart_fp_commit, hart_no_hazard,"
	@echo "hart_hazard, hart_ooo_witness and hart_cpi -- see README.md and"
	@echo "example/opmux_tb.v."
	@echo "Run pip install ./lint once so make test also runs the ece552 rule"
	@echo "checker. There is no autograder for phase 8; this only runs the"
	@echo "testbenches you write."

test:
	@./run_test.sh local

ci:
	@./run_test.sh ci

schematics:
	@./gen_schematics.sh

speedup:
	@./tools/speedup/compare.sh

bench:
	@python3 tools/bench/compare.py

bench-full:
	@python3 tools/bench/compare.py --full

# Keep the archive layout identical to Phase 7.
submission:
	@mkdir -p build
	@zip -q -FS build/phase8_submission.zip $(filter-out %_tb.v,$(wildcard *.v cache/*.v))

fv:
	@./fv/riscv/run.sh .

clean:
	rm -rf results build
