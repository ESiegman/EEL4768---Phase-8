`timescale 1ns / 1ps
`default_nettype none
`include "hart_tb_common.vh"

// Out-of-order completion witness (phase_7.pdf 2, 4.10.3, 5): o_complete_*
// may be out of program order while o_retire_* stays in order and correct.
//
// Each witness program (traces/directed/, tools/hart_traces/gen_directed.py)
// is built so that a younger instruction must complete before an older one
// on a Tomasulo machine, and must still retire exactly as its iss.py
// reference says. Each run requires at least one out-of-order complete:
//   witness_load  a load that misses, then independent ALU ops
//   witness_div   a divide (holds the shared ALU), then load hits
//   witness_fdiv  an fdiv, then independent integer ops (FP results and
//                 fflags are don't-cares in the reference: iss.py's FP math
//                 is fake; nothing reads the fdiv result)
// at the phase 6 graded config and at the skeleton defaults, latency 4.
// An in-order hart fails these with 0 out-of-order completes.
// Then no_hazard at the graded config, with its out-of-order count printed
// as INFO (its correctness checks still count).
module hart_ooo_witness_tb;
    localparam N = 7;
    reg  [N-1:0] start;
    wire [N-1:0] done;
    integer k, passed, failed;

`define WIT_RUN(inst, idx, lbl, cfg, prog, rf) \
    hart_harness #(.LABEL(lbl), cfg, .LATENCY(4), .PROG(prog), .REF(rf), .MIN_OOO(1)) \
        inst (.i_start(start[idx]), .o_done(done[idx]));

    `WIT_RUN(h0, 0, "witness_load graded",   `HART_CFG_GRADED,  "traces/directed/witness_load.hex", "traces/directed/witness_load.trace")
    `WIT_RUN(h1, 1, "witness_load default",  `HART_CFG_DEFAULT, "traces/directed/witness_load.hex", "traces/directed/witness_load.trace")
    `WIT_RUN(h2, 2, "witness_div graded",    `HART_CFG_GRADED,  "traces/directed/witness_div.hex",  "traces/directed/witness_div.trace")
    `WIT_RUN(h3, 3, "witness_div default",   `HART_CFG_DEFAULT, "traces/directed/witness_div.hex",  "traces/directed/witness_div.trace")
    `WIT_RUN(h4, 4, "witness_fdiv graded",   `HART_CFG_GRADED,  "traces/directed/witness_fdiv.hex", "traces/directed/witness_fdiv.trace")
    `WIT_RUN(h5, 5, "witness_fdiv default",  `HART_CFG_DEFAULT, "traces/directed/witness_fdiv.hex", "traces/directed/witness_fdiv.trace")
    hart_harness #(.LABEL("no_hazard graded (INFO ooo count)"), `HART_CFG_GRADED, .LATENCY(4),
                   .PROG("traces/no_hazard_program.hex"), .REF("traces/no_hazard.trace"))
        h6 (.i_start(start[6]), .o_done(done[6]));

    initial begin
        $display("========== hart out-of-order witness testbench ==========");
        start = 0;
        for (k = 0; k < N; k = k + 1) begin
            start[k] = 1'b1;
            wait (done[k] === 1'b1);
        end
        $display("  INFO witness out-of-order completes: load %0d/%0d, div %0d/%0d, fdiv %0d/%0d (graded/default)",
                 h0.n_ooo, h1.n_ooo, h2.n_ooo, h3.n_ooo, h4.n_ooo, h5.n_ooo);
        $display("  INFO no_hazard at the graded config: %0d of %0d completes out of order, at most %0d completed-not-retired",
                 h6.n_ooo, h6.n_complete, h6.max_inflight_done);
        passed = h0.passed + h1.passed + h2.passed + h3.passed + h4.passed + h5.passed + h6.passed;
        failed = h0.failed + h1.failed + h2.failed + h3.failed + h4.failed + h5.failed + h6.failed;
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
