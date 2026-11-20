`timescale 1ns / 1ps
`default_nettype none
`include "hart_tb_common.vh"

// Hazards / integration (phase_7.pdf 2, 5). Three groups, each with its own
// subtotal so a failure in one is easy to tell apart:
//
//  1. hazard: traps/hazard_program.hex against traces/hazard_fwd_retire.trace
//     (the phase 4 cycle log traces/hazard_fwd.trace converted to retire
//     rows by tools/hart_traces/convert_hazard.py)
//  2. directed: the programs in traces/directed/ against their iss.py
//     reference traces (tools/hart_traces/gen_directed.py): control,
//     traps, trap_jump, rename, memory, mext. memory ends with a flush
//     loop, so main memory must equal the stores for it; it also runs at
//     the small and large configurations
//  3. random (M+F integration): phase 6's traces/random_program.hex with
//     traces/random_dmem.hex as the golden memory. No per-instruction
//     reference: the retire invariants, the complete stream, and every
//     golden section. This is the only full test of M and F through the
//     out-of-order machine; its FP sections fail until the FP path works.
// Every run also does all of hart_tb_common.vh's checks.
module hart_hazard_tb;
    localparam N = 17;
    reg  [N-1:0] start;
    wire [N-1:0] done;
    integer k, gp, gf, passed, failed;

`define HZ_RUN(inst, idx, lbl, cfg, lat, prog, rf, fl) \
    hart_harness #(.LABEL(lbl), cfg, .LATENCY(lat), .PROG(prog), .REF(rf), .FLUSHES(fl)) \
        inst (.i_start(start[idx]), .o_done(done[idx]));

    // 1. hazard
    `HZ_RUN(h0,  0,  "hazard default lat4",     `HART_CFG_DEFAULT, 4,  "traces/hazard_program.hex", "traces/hazard_fwd_retire.trace", 0)
    `HZ_RUN(h1,  1,  "hazard graded lat4",      `HART_CFG_GRADED,  4,  "traces/hazard_program.hex", "traces/hazard_fwd_retire.trace", 0)
    // 2. directed
    `HZ_RUN(h2,  2,  "control default lat4",    `HART_CFG_DEFAULT, 4,  "traces/directed/control.hex",   "traces/directed/control.trace",   0)
    `HZ_RUN(h3,  3,  "control graded lat4",     `HART_CFG_GRADED,  4,  "traces/directed/control.hex",   "traces/directed/control.trace",   0)
    `HZ_RUN(h4,  4,  "traps default lat4",      `HART_CFG_DEFAULT, 4,  "traces/directed/traps.hex",     "traces/directed/traps.trace",     0)
    `HZ_RUN(h5,  5,  "traps graded lat4",       `HART_CFG_GRADED,  4,  "traces/directed/traps.hex",     "traces/directed/traps.trace",     0)
    `HZ_RUN(h6,  6,  "trap_jump default lat4",  `HART_CFG_DEFAULT, 4,  "traces/directed/trap_jump.hex", "traces/directed/trap_jump.trace", 0)
    `HZ_RUN(h7,  7,  "trap_jump graded lat4",   `HART_CFG_GRADED,  4,  "traces/directed/trap_jump.hex", "traces/directed/trap_jump.trace", 0)
    `HZ_RUN(h8,  8,  "rename default lat4",     `HART_CFG_DEFAULT, 4,  "traces/directed/rename.hex",    "traces/directed/rename.trace",    0)
    `HZ_RUN(h9,  9,  "rename graded lat4",      `HART_CFG_GRADED,  4,  "traces/directed/rename.hex",    "traces/directed/rename.trace",    0)
    `HZ_RUN(h10, 10, "memory default lat4",     `HART_CFG_DEFAULT, 4,  "traces/directed/memory.hex",    "traces/directed/memory.trace",    1)
    `HZ_RUN(h11, 11, "memory graded lat4",      `HART_CFG_GRADED,  4,  "traces/directed/memory.hex",    "traces/directed/memory.trace",    1)
    `HZ_RUN(h12, 12, "memory small lat1",       `HART_CFG_SMALL,   1,  "traces/directed/memory.hex",    "traces/directed/memory.trace",    1)
    `HZ_RUN(h13, 13, "memory large lat10",      `HART_CFG_LARGE,   10, "traces/directed/memory.hex",    "traces/directed/memory.trace",    1)
    `HZ_RUN(h14, 14, "mext default lat4",       `HART_CFG_DEFAULT, 4,  "traces/directed/mext.hex",      "traces/directed/mext.trace",      0)
    `HZ_RUN(h15, 15, "mext graded lat4",        `HART_CFG_GRADED,  4,  "traces/directed/mext.hex",      "traces/directed/mext.trace",      0)
    // 3. random (M+F integration)
    hart_harness #(.LABEL("random graded lat4"), `HART_CFG_GRADED, .LATENCY(4),
                   .PROG("traces/random_program.hex"), .REF(""), .GOLD("traces/random_dmem.hex"),
                   .FLUSHES(1), .TRAPS_OK(0))
        h16 (.i_start(start[16]), .o_done(done[16]));

    task run_group;
        input [8*40-1:0] name;
        input integer    first;
        input integer    last;
        begin
            $display("=== group: %0s ===", name);
            for (k = first; k <= last; k = k + 1) begin
                start[k] = 1'b1;
                wait (done[k] === 1'b1);
            end
        end
    endtask

    initial begin
        $display("========== hart hazard / integration testbench ==========");
        start = 0;
        run_group("hazard (phase 4 hazard program)", 0, 1);
        gp = h0.passed + h1.passed;
        gf = h0.failed + h1.failed;
        $display("=== group hazard: %0d passed, %0d failed ===", gp, gf);
        passed = gp; failed = gf;

        run_group("directed programs", 2, 15);
        gp = h2.passed + h3.passed + h4.passed + h5.passed + h6.passed + h7.passed + h8.passed +
             h9.passed + h10.passed + h11.passed + h12.passed + h13.passed + h14.passed + h15.passed;
        gf = h2.failed + h3.failed + h4.failed + h5.failed + h6.failed + h7.failed + h8.failed +
             h9.failed + h10.failed + h11.failed + h12.failed + h13.failed + h14.failed + h15.failed;
        $display("=== group directed: %0d passed, %0d failed ===", gp, gf);
        passed = passed + gp; failed = failed + gf;

        run_group("random program (M+F integration)", 16, 16);
        $display("=== group random (M+F): %0d passed, %0d failed ===", h16.passed, h16.failed);
        passed = passed + h16.passed; failed = failed + h16.failed;

        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
