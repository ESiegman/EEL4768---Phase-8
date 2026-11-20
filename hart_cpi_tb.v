`timescale 1ns / 1ps
`default_nettype none
`include "hart_tb_common.vh"

// Out-of-order throughput (phase_7.pdf 2): cycles and CPI of no_hazard,
// hazard and the phase 6 random program at every cache configuration, next
// to the phase 4 + forwarding baseline. Every run also does all of
// hart_tb_common.vh's correctness checks (a wrong answer has no CPI).
//
// Pass/fail is on a near-ideal configuration only, because phase 4 had an
// ideal combinational data memory and phase 7 has a cache: the skeleton
// defaults (16 KB direct mapped, 128 B lines) at memory latency 1. There:
//  * hazard must take fewer cycles than phase 4 (its RAW, load-use and
//    branch hazards are where out-of-order execution wins);
//  * no_hazard must take no more cycles than phase 4 plus the cache's cold
//    miss penalty, LATENCY cycles per main-memory read, which phase 4's
//    ideal memory never paid. no_hazard has no hazards, so a single-issue
//    machine can at best tie an in-order pipeline on it (both retire one
//    instruction per cycle), and its 8 cold misses fall in a stretch where
//    the single cache port is busy every cycle, so no in-order LSU can hide
//    them (phase_7.pdf 4.1, 4.7).
// The other configurations, and the random program (phase 4 has no M or F),
// are printed as INFO. The staff out-of-order reference (PDF: within ~10%)
// is not available, so it is not checked.
//
// Each run prints where the cycles without a retire went (fill, after a
// branch/jump = issue stalled until it resolved, before a load/store/M/FP/
// ALU retire), from the port-level streams only.
module hart_cpi_tb;
    // Phase 4 baseline, measured on our phase 4 hart (github.com/ESiegman/
    // EEL4768---Phase-4 at ff1ff87, FWD_EN=1, BYPASS_EN=1, scored 7/7) with
    // its testbench's combinational instruction and data memories and its
    // cycle count: reset released at a negedge, cycles counted at each
    // following negedge up to and including the one where the ebreak
    // retires. hart_tb_common.vh counts the same way.
    //   no_hazard_program.hex: 12927 retired in 12930 cycles
    //   hazard_program.hex:       38 retired in    47 cycles
    // traces/hazard_fwd.trace says "halted after 49 cycles": the course
    // trace counts two more cycles of fill than the phase 4 testbench.
    localparam P4_NO_HAZARD  = 12930;
    localparam P4_HAZARD     = 47;
    localparam P4_HAZARD_TRACE = 49;

    localparam N = 15;
    reg  [N-1:0] start;
    wire [N-1:0] done;
    integer k, passed, failed, cpass, cfail;

`define CPI_RUN(inst, idx, lbl, cfg, lat, prog, rf, gold) \
    hart_harness #(.LABEL(lbl), cfg, .LATENCY(lat), .PROG(prog), .REF(rf), .GOLD(gold), \
                   .FLUSHES(gold != ""), .TRAPS_OK(gold == "")) \
        inst (.i_start(start[idx]), .o_done(done[idx]));

    // Near-ideal (graded on this one).
    `CPI_RUN(n0, 0,  "cpi no_hazard ideal",   `HART_CFG_DEFAULT, 1,  "traces/no_hazard_program.hex", "traces/no_hazard.trace", "")
    `CPI_RUN(z0, 1,  "cpi hazard ideal",      `HART_CFG_DEFAULT, 1,  "traces/hazard_program.hex", "traces/hazard_fwd_retire.trace", "")
    `CPI_RUN(r0, 2,  "cpi random ideal",      `HART_CFG_DEFAULT, 1,  "traces/random_program.hex", "", "traces/random_dmem.hex")
    // The section 2b configurations (INFO).
    `CPI_RUN(n1, 3,  "cpi no_hazard default", `HART_CFG_DEFAULT, 4,  "traces/no_hazard_program.hex", "traces/no_hazard.trace", "")
    `CPI_RUN(z1, 4,  "cpi hazard default",    `HART_CFG_DEFAULT, 4,  "traces/hazard_program.hex", "traces/hazard_fwd_retire.trace", "")
    `CPI_RUN(r1, 5,  "cpi random default",    `HART_CFG_DEFAULT, 4,  "traces/random_program.hex", "", "traces/random_dmem.hex")
    `CPI_RUN(n2, 6,  "cpi no_hazard graded",  `HART_CFG_GRADED,  4,  "traces/no_hazard_program.hex", "traces/no_hazard.trace", "")
    `CPI_RUN(z2, 7,  "cpi hazard graded",     `HART_CFG_GRADED,  4,  "traces/hazard_program.hex", "traces/hazard_fwd_retire.trace", "")
    `CPI_RUN(r2, 8,  "cpi random graded",     `HART_CFG_GRADED,  4,  "traces/random_program.hex", "", "traces/random_dmem.hex")
    `CPI_RUN(n3, 9,  "cpi no_hazard small",   `HART_CFG_SMALL,   1,  "traces/no_hazard_program.hex", "traces/no_hazard.trace", "")
    `CPI_RUN(z3, 10, "cpi hazard small",      `HART_CFG_SMALL,   1,  "traces/hazard_program.hex", "traces/hazard_fwd_retire.trace", "")
    `CPI_RUN(r3, 11, "cpi random small",      `HART_CFG_SMALL,   1,  "traces/random_program.hex", "", "traces/random_dmem.hex")
    `CPI_RUN(n4, 12, "cpi no_hazard large",   `HART_CFG_LARGE,   10, "traces/no_hazard_program.hex", "traces/no_hazard.trace", "")
    `CPI_RUN(z4, 13, "cpi hazard large",      `HART_CFG_LARGE,   10, "traces/hazard_program.hex", "traces/hazard_fwd_retire.trace", "")
    `CPI_RUN(r4, 14, "cpi random large",      `HART_CFG_LARGE,   10, "traces/random_program.hex", "", "traces/random_dmem.hex")

    task row;
        input [8*24-1:0] cfg;
        input integer    nc, nr, zc, zr, rc, rr;
        begin
            $display("  %-24s | no_hazard %6d cyc CPI %0d.%03d (x%0d.%03d of P4) | hazard %4d cyc CPI %0d.%03d (x%0d.%03d of P4) | random %6d cyc CPI %0d.%03d",
                     cfg,
                     nc, (nc * 1000 / nr) / 1000, (nc * 1000 / nr) % 1000,
                     (nc * 1000 / P4_NO_HAZARD) / 1000, (nc * 1000 / P4_NO_HAZARD) % 1000,
                     zc, (zc * 1000 / zr) / 1000, (zc * 1000 / zr) % 1000,
                     (zc * 1000 / P4_HAZARD) / 1000, (zc * 1000 / P4_HAZARD) % 1000,
                     rc, (rc * 1000 / (rr > 0 ? rr : 1)) / 1000, (rc * 1000 / (rr > 0 ? rr : 1)) % 1000);
        end
    endtask

    task cpi_check;
        input [8*80-1:0] what;
        input            ok;
        begin
            if (ok) begin
                cpass = cpass + 1;
            end else begin
                cfail = cfail + 1;
                $display("[FAIL] cpi: %0s", what);
            end
        end
    endtask

    initial begin
        $display("========== hart CPI testbench ==========");
        start = 0; cpass = 0; cfail = 0;
        for (k = 0; k < N; k = k + 1) begin
            start[k] = 1'b1;
            wait (done[k] === 1'b1);
        end

        $display("  phase 4 + forwarding baseline: no_hazard %0d cycles (CPI %0d.%03d), hazard %0d cycles (CPI %0d.%03d; course trace: %0d)",
                 P4_NO_HAZARD, (P4_NO_HAZARD * 1000 / 12927) / 1000, (P4_NO_HAZARD * 1000 / 12927) % 1000,
                 P4_HAZARD, (P4_HAZARD * 1000 / 38) / 1000, (P4_HAZARD * 1000 / 38) % 1000, P4_HAZARD_TRACE);
        row("default lat1 (graded)", n0.cycles, n0.retired, z0.cycles, z0.retired, r0.cycles, r0.retired);
        row("default lat4",          n1.cycles, n1.retired, z1.cycles, z1.retired, r1.cycles, r1.retired);
        row("graded lat4",           n2.cycles, n2.retired, z2.cycles, z2.retired, r2.cycles, r2.retired);
        row("small lat1",            n3.cycles, n3.retired, z3.cycles, z3.retired, r3.cycles, r3.retired);
        row("large lat10",           n4.cycles, n4.retired, z4.cycles, z4.retired, r4.cycles, r4.retired);

        $display("  no_hazard at default lat1: %0d cycles vs phase 4 %0d + cold-miss penalty %0d (%0d reads x latency 1) = %0d",
                 n0.cycles, P4_NO_HAZARD, n0.u_mem.n_rd, n0.u_mem.n_rd, P4_NO_HAZARD + n0.u_mem.n_rd);
        cpi_check("no_hazard at default lat1 no slower than phase 4 + forwarding plus the cold-miss penalty",
                  n0.retired == 12927 && n0.cycles <= P4_NO_HAZARD + n0.u_mem.n_rd);
        cpi_check("hazard at default lat1 beats phase 4 + forwarding",    z0.retired == 38 && z0.cycles < P4_HAZARD);

        passed = cpass + n0.passed + z0.passed + r0.passed + n1.passed + z1.passed + r1.passed +
                 n2.passed + z2.passed + r2.passed + n3.passed + z3.passed + r3.passed +
                 n4.passed + z4.passed + r4.passed;
        failed = cfail + n0.failed + z0.failed + r0.failed + n1.failed + z1.failed + r1.failed +
                 n2.failed + z2.failed + r2.failed + n3.failed + z3.failed + r3.failed +
                 n4.failed + z4.failed + r4.failed;
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
