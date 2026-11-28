`timescale 1ns/1ps
`include "hart_tb_common.vh"

// Use the same memory model, clock boundaries and architectural checks as CI.
module bench_tb;
    parameter PROGRAM = "";
    parameter LATENCY = 4;
    parameter TRAPS_OK = 0;
    wire done;
    hart_harness #(.LABEL("bench"), `BENCH_CONFIG, .LATENCY(LATENCY),
                   .PROG(PROGRAM), .REF(""), .TRAPS_OK(TRAPS_OK)) h (1'b1, done);

    integer fd, count;
    reg [8*512-1:0] trace_path;
    initial begin
        count = 0;
        if (!$value$plusargs("trace=%s", trace_path)) $fatal(1, "missing trace path");
        fd = $fopen(trace_path, "w");
        if (fd == 0) $fatal(1, "cannot open trace");
    end

    // Capture every retirement field, even inactive lanes. Binary format
    // preserves each individual X/Z bit during four-state simulation.
    always @(negedge h.clk) begin
        if (!h.rst && h.retire_valid) begin
            $fdisplay(fd, "%b", {h.retire_valid, h.retire_pc, h.retire_next_pc,
                h.retire_inst, h.retire_trap, h.retire_halt,
                h.retire_rs1_raddr, h.retire_rs1_rdata, h.retire_rs2_raddr, h.retire_rs2_rdata,
                h.retire_rd_waddr, h.retire_rd_wdata, h.retire_dmem_addr, h.retire_dmem_mask,
                h.retire_dmem_ren, h.retire_dmem_wen, h.retire_dmem_rdata, h.retire_dmem_wdata,
                h.retire_frs1_raddr, h.retire_frs1_rdata, h.retire_frs2_raddr, h.retire_frs2_rdata,
                h.retire_frs3_raddr, h.retire_frs3_rdata, h.retire_frd_wen, h.retire_frd_waddr,
                h.retire_frd_wdata, h.retire_fflags});
            count = count + 1;
        end
    end

    initial begin
        wait (done);
        $fclose(fd);
        if (h.failed || !h.halted || count != h.retired || count == 0)
            $fatal(1, "incomplete or incorrect benchmark");
        $display("MEASURE %0d %0d", h.retired, h.cycles);
        $finish;
    end
endmodule
