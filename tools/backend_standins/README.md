# backend_standins

Test-only `rat.v` and `cdb_arb.v` with the interfaces `hart.v` expects (see
the comment block at the top of the hart body). They let `hart.v` build and
run the hart testbenches until Bradly's real files land at the repo root.
Not compiled by `run_test.sh` (it only globs the repo root).

    iverilog -g2005 -s hart_no_hazard_tb -o /tmp/nh hart_no_hazard_tb.v \
      hart.v alu.v rf.v decoder.v imm.v lsu.v rs.v reservation_station.v \
      fp_rs.v fp_exec.v fcsr.v cache/*.v fpu*.v \
      tools/backend_standins/rat.v tools/backend_standins/cdb_arb.v
