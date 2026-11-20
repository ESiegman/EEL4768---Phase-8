`timescale 1ns / 1ps
`default_nettype none
`include "hart_tb_common.vh"

// Basic correctness (phase_7.pdf 2, 5): traces/no_hazard_program.hex
// against the retire rows of traces/no_hazard.trace (the phase 4 course
// trace, 12927 instructions), column by column with the phase 4 don't-care
// rules, plus every retire, complete-stream and memory check in
// hart_tb_common.vh. Run once per cache configuration:
//   skeleton defaults, latency 4
//   phase 6 graded config (PLRU 4-way 2 KB 16 B, prefetch), latency 4
//   direct mapped LRU 1 KB 16 B, latency 1
//   8-way LRU 16 KB 64 B, latency 10
// The program never flushes the cache, so main memory is only compared
// with the retire-stream stores as INFO (loads are checked against them).
module hart_no_hazard_tb;
    localparam N = 4;
    reg  [N-1:0] start;
    wire [N-1:0] done;
    integer k, passed, failed;

    hart_harness #(.LABEL("no_hazard default lat4"), `HART_CFG_DEFAULT, .LATENCY(4),
                   .PROG("traces/no_hazard_program.hex"), .REF("traces/no_hazard.trace"))
        h0 (.i_start(start[0]), .o_done(done[0]));
    hart_harness #(.LABEL("no_hazard graded lat4"), `HART_CFG_GRADED, .LATENCY(4),
                   .PROG("traces/no_hazard_program.hex"), .REF("traces/no_hazard.trace"))
        h1 (.i_start(start[1]), .o_done(done[1]));
    hart_harness #(.LABEL("no_hazard small lat1"), `HART_CFG_SMALL, .LATENCY(1),
                   .PROG("traces/no_hazard_program.hex"), .REF("traces/no_hazard.trace"))
        h2 (.i_start(start[2]), .o_done(done[2]));
    hart_harness #(.LABEL("no_hazard large lat10"), `HART_CFG_LARGE, .LATENCY(10),
                   .PROG("traces/no_hazard_program.hex"), .REF("traces/no_hazard.trace"))
        h3 (.i_start(start[3]), .o_done(done[3]));

    initial begin
        $display("========== hart no_hazard testbench ==========");
        start = 0;
        for (k = 0; k < N; k = k + 1) begin
            start[k] = 1'b1;
            wait (done[k] === 1'b1);
        end
        passed = h0.passed + h1.passed + h2.passed + h3.passed;
        failed = h0.failed + h1.failed + h2.failed + h3.failed;
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
