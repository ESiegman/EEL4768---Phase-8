// Harness shared by the phase 7 hart testbenches (hart_no_hazard_tb.v,
// hart_hazard_tb.v, hart_ooo_witness_tb.v, hart_cpi_tb.v): one hart with
// the skeleton's phase 7 ports (skeletons/hart.v), one program, one cache
// configuration and memory latency, and every check that runs on it. A
// testbench instantiates one harness per run and starts them one after
// another, so the log reads in order.
//
// A .vh, not a .v, for the same reason as mem_model.vh: run_test.sh would
// otherwise compile it into every check and `ece552 validate` would lint it
// as a design file (it uses loops, file I/O and delays).
//
// Only the hart's ports are used: nothing here reaches into the hart.
//
// Around the hart:
//  * instruction memory: a combinational array read through o_imem_raddr /
//    i_imem_rdata, loaded with PROG at 0x00400000. Any fetch is answered
//    (out of range reads 0); only a retired PC outside the program or not
//    word aligned is an error, because wrong-path fetches are legal
//  * one main_mem (mem_model.vh) at 0x10010000 behind the data cache, with
//    i_mem_ready tied high
//
// Program sources (parameters):
//  * REF = a column trace (phase 4 no_hazard.trace format, optionally with
//    the FP columns of tools/hart_traces/reftrace.py): the retire stream is
//    compared column by column, with the phase 4 don't-care rules: x in the
//    trace, rs1/rs2 only for classes that read them, rd_wdata only when
//    rd != 0, mem fields only when mem_op != 0, store data on masked lanes.
//    trap and halt exactly. The retire count must equal the trace's, ending
//    on the ebreak. The first mismatch is shown in full, the rest counted
//  * REF = "": invariants only (the phase 6 random program); GOLD names the
//    golden data memory image, checked section by section (phase_6.pdf
//    6.1: program data, muldiv, the six FP sections, mixed, cache stall)
//
// Checks on every run:
//  * phase 6 retire invariants: shadow integer and FP register files (every
//    source a retiring instruction reports must equal the shadow value, the
//    operands the instruction actually used, PDF 4.8), FP destination
//    reporting, PC follows next_pc, the retired word matches imem, loads
//    return the shadow memory built from retiring stores, store lanes hold
//    rs2 (frs2 for fsw), fflags only gain bits except through a CSR write,
//    and a CSR read returns the shadow fcsr; a trapped instruction writes
//    no register
//  * the complete stream (PDF 4.10):
//      - o_complete_valid is never X/Z after reset; tag, rd, value and pc
//        are never X/Z while it is high
//      - a second complete on a tag before that tag's instruction retires
//      - every instruction that goes through the CDB (integer ALU, lui,
//        auipc, jal, jalr, branches, non-trapping loads, FP and fcsr CSR
//        ops) has exactly one complete in an earlier cycle, found by pc and
//        tag; stores, ebreak, illegal instructions and misaligned memory
//        ops have none
//      - integer results: complete rd == retire rd and complete value ==
//        rd_wdata when rd != 0; jal/jalr value pc + 4; branches rd 0. FP
//        results: value == frd_wdata (complete rd only with
//        CHECK_FP_COMPLETE_RD, PDF 4.10 does not define it for FP)
//      - consecutive retired instructions carry consecutive tags mod 8
//        (circular ROB), using the tags seen on completes
//  * after halt: main memory equals the retire-stream stores (every word
//    when the program flushes the cache, FLUSHES = 1; otherwise dirty lines
//    may still be in the cache and the count is INFO), nothing written past
//    the end of memory, and no memory protocol errors
//  * optional: at least MIN_OOO out-of-order completes (the witness)
// It prints cycles, instructions, CPI, completes, out-of-order completes
// (a complete of an instruction older than one that already completed),
// the most completed-but-not-retired instructions at once, memory reads,
// writes and write-backs, and where the cycles without a retire went: each
// gap before a retire is charged to "after a branch/jump" when the previous
// retire was one (issue waits for it to resolve), else to the class of the
// instruction that retires (load, store, M, FP, ALU, other); the gap before
// the first retire is "fill". Port-level only.

`ifndef HART_TB_COMMON_VH
`define HART_TB_COMMON_VH

`include "mem_model.vh"

module hart_harness #(
    // Printed in front of every message from this instance.
    parameter LABEL        = "hart",
    parameter EVICT_POLICY = 0,
    parameter NUM_WAYS     = 1,
    parameter CACHE_SIZE   = 16,
    parameter BLOCK_SIZE   = 128,
    parameter PREFETCH_EN  = 0,
    // Main memory read latency in cycles.
    parameter LATENCY      = 4,
    // Instruction memory image, reference trace ("" for none) and golden data
    // memory ("" for none), relative to the repo root.
    parameter PROG         = "traces/no_hazard_program.hex",
    parameter REF          = "traces/no_hazard.trace",
    parameter GOLD         = "",
    // The program evicts every dirty line before its ebreak.
    parameter FLUSHES      = 0,
    // 0: any trap is an error (the random program has none).
    parameter TRAPS_OK     = 1,
    // Fail unless at least this many completes are out of program order.
    parameter MIN_OOO      = 0,
    // Also require o_complete_rd == inst[11:7] for FP-register results.
    parameter CHECK_FP_COMPLETE_RD = 0,
    // Watchdogs: total cycles, and cycles in a row without a retirement.
    parameter MAX_CYCLES   = 2000000,
    parameter IDLE_LIMIT   = 5000
) (
    input  wire i_start,
    output reg  o_done
);

    localparam [31:0] IMEM_BASE   = 32'h00400000;
    localparam [31:0] DMEM_BASE   = 32'h10010000;
    localparam        IMEM_WORDS  = 40000;
    localparam        DMEM_WORDS  = 32768;
    localparam        GUARD_WORDS = BLOCK_SIZE / 4;
    localparam        MAX_REF     = 16384;
    localparam        NCOL        = 26;
    localparam        MAX_MSGS    = 20;
    localparam        N_REGIONS   = 12;
    localparam [31:0] EBREAK      = 32'h00100073;

    // Results, read by the top-level testbench.
    integer passed;
    integer failed;
    integer cycles;       // cycles from reset release to the ebreak retiring
    integer retired;
    integer n_complete;
    integer n_ooo;
    integer max_inflight_done;

    // ------------------------------------------------------------------
    // Clock (runs only while this instance is active), reset, DUT
    // ------------------------------------------------------------------
    reg clk;
    reg rst;
    reg running;

    always begin
        wait (running);
        #5 clk = ~clk;
    end

    wire [31:0]             imem_raddr;
    wire [31:0]             imem_rdata;
    wire                    mem_rd;
    wire [31:0]             mem_rd_addr;
    wire                    mem_valid;
    wire [BLOCK_SIZE*8-1:0] mem_rd_data;
    wire                    mem_wr;
    wire [31:0]             mem_wr_addr;
    wire [BLOCK_SIZE*8-1:0] mem_wr_data;
    wire [BLOCK_SIZE-1:0]   mem_wr_be;

    wire        retire_valid;
    wire [31:0] retire_inst;
    wire        retire_trap;
    wire        retire_halt;
    wire [ 4:0] retire_rs1_raddr;
    wire [ 4:0] retire_rs2_raddr;
    wire [31:0] retire_rs1_rdata;
    wire [31:0] retire_rs2_rdata;
    wire [ 4:0] retire_rd_waddr;
    wire [31:0] retire_rd_wdata;
    wire [31:0] retire_dmem_addr;
    wire [ 3:0] retire_dmem_mask;
    wire        retire_dmem_ren;
    wire        retire_dmem_wen;
    wire [31:0] retire_dmem_rdata;
    wire [31:0] retire_dmem_wdata;
    wire [31:0] retire_pc;
    wire [31:0] retire_next_pc;
    wire        complete_valid;
    wire [ 2:0] complete_tag;
    wire [ 4:0] complete_rd;
    wire [31:0] complete_value;
    wire [31:0] complete_pc;
    wire [ 4:0] retire_frs1_raddr;
    wire [31:0] retire_frs1_rdata;
    wire [ 4:0] retire_frs2_raddr;
    wire [31:0] retire_frs2_rdata;
    wire [ 4:0] retire_frs3_raddr;
    wire [31:0] retire_frs3_rdata;
    wire        retire_frd_wen;
    wire [ 4:0] retire_frd_waddr;
    wire [31:0] retire_frd_wdata;
    wire [ 4:0] retire_fflags;

    hart #(
        .RESET_ADDR  (IMEM_BASE),
        .EVICT_POLICY(EVICT_POLICY),
        .NUM_WAYS    (NUM_WAYS),
        .CACHE_SIZE  (CACHE_SIZE),
        .BLOCK_SIZE  (BLOCK_SIZE),
        .PREFETCH_EN (PREFETCH_EN),
        // The skeleton declares it, so a staff testbench may set it.
        .WRITE_ALLOCATE(0)
    ) dut (
        .i_clk              (clk),
        .i_rst              (rst),
        .o_imem_raddr       (imem_raddr),
        .i_imem_rdata       (imem_rdata),
        .i_mem_ready        (1'b1),
        .i_mem_valid        (mem_valid),
        .i_mem_rd_data      (mem_rd_data),
        .o_mem_rd           (mem_rd),
        .o_mem_wr           (mem_wr),
        .o_mem_rd_addr      (mem_rd_addr),
        .o_mem_wr_addr      (mem_wr_addr),
        .o_mem_wr_data      (mem_wr_data),
        .o_mem_wr_be        (mem_wr_be),
        .o_retire_valid     (retire_valid),
        .o_retire_inst      (retire_inst),
        .o_retire_trap      (retire_trap),
        .o_retire_halt      (retire_halt),
        .o_retire_rs1_raddr (retire_rs1_raddr),
        .o_retire_rs2_raddr (retire_rs2_raddr),
        .o_retire_rs1_rdata (retire_rs1_rdata),
        .o_retire_rs2_rdata (retire_rs2_rdata),
        .o_retire_rd_waddr  (retire_rd_waddr),
        .o_retire_rd_wdata  (retire_rd_wdata),
        .o_retire_dmem_addr (retire_dmem_addr),
        .o_retire_dmem_mask (retire_dmem_mask),
        .o_retire_dmem_ren  (retire_dmem_ren),
        .o_retire_dmem_wen  (retire_dmem_wen),
        .o_retire_dmem_rdata(retire_dmem_rdata),
        .o_retire_dmem_wdata(retire_dmem_wdata),
        .o_retire_pc        (retire_pc),
        .o_retire_next_pc   (retire_next_pc),
        .o_complete_valid   (complete_valid),
        .o_complete_tag     (complete_tag),
        .o_complete_rd      (complete_rd),
        .o_complete_value   (complete_value),
        .o_complete_pc      (complete_pc),
        .o_retire_frs1_raddr(retire_frs1_raddr),
        .o_retire_frs1_rdata(retire_frs1_rdata),
        .o_retire_frs2_raddr(retire_frs2_raddr),
        .o_retire_frs2_rdata(retire_frs2_rdata),
        .o_retire_frs3_raddr(retire_frs3_raddr),
        .o_retire_frs3_rdata(retire_frs3_rdata),
        .o_retire_frd_wen   (retire_frd_wen),
        .o_retire_frd_waddr (retire_frd_waddr),
        .o_retire_frd_wdata (retire_frd_wdata),
        .o_retire_fflags    (retire_fflags)
    );

    // Instruction memory: combinational, phase 4 style.
    reg  [31:0] imem [0:IMEM_WORDS-1];
    wire [31:0] imem_off = imem_raddr - IMEM_BASE;
    assign imem_rdata = (imem_raddr >= IMEM_BASE && imem_off < 4 * IMEM_WORDS) ?
                        imem[imem_off >> 2] : 32'h00000000;

    main_mem #(
        .BLOCK_SIZE(BLOCK_SIZE),
        .LATENCY   (LATENCY),
        .BASE_ADDR (DMEM_BASE),
        .SIZE_WORDS(DMEM_WORDS + GUARD_WORDS),
        .NAME      ({LABEL, ", mem"})
    ) u_mem (
        .i_clk     (clk),
        .i_rst     (rst),
        .i_rd      (mem_rd),
        .i_rd_addr (mem_rd_addr),
        .o_rd_valid(mem_valid),
        .o_rd_data (mem_rd_data),
        .i_wr      (mem_wr),
        .i_wr_addr (mem_wr_addr),
        .i_wr_data (mem_wr_data),
        .i_wr_be   (mem_wr_be)
    );

    // ------------------------------------------------------------------
    // Reporting
    // ------------------------------------------------------------------
    task check;
        input [8*80-1:0] what;
        input            ok;
        begin
            if (ok) begin
                passed = passed + 1;
            end else begin
                failed = failed + 1;
                $display("[FAIL] %0s: %0s", LABEL, what);
            end
        end
    endtask

    integer msgs;
    task report;
        input [8*72-1:0] what;
        input [31:0]     got;
        input [31:0]     want;
        begin
            if (msgs < MAX_MSGS)
                $display("[FAIL] %0s: %0s at pc %h (inst %h): got %h, expected %h (retire #%0d, cycle %0d)",
                         LABEL, what, retire_pc, retire_inst, got, want, retired, cycles);
            else if (msgs == MAX_MSGS)
                $display("[FAIL] %0s: further mismatches not shown", LABEL);
            msgs = msgs + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // Instruction classes (a mirror of decoder.v's legality and the
    // phase 4/6 operand rules)
    // ------------------------------------------------------------------
    localparam [6:0] OP_LUI = 7'h37, OP_AUIPC = 7'h17, OP_JAL = 7'h6F, OP_JALR = 7'h67,
                     OP_BR = 7'h63, OP_LD = 7'h03, OP_ST = 7'h23, OP_IMM = 7'h13,
                     OP_OP = 7'h33, OP_FLW = 7'h07, OP_FSW = 7'h27, OP_FP = 7'h53,
                     OP_SYS = 7'h73;

    function is_fma_op;
        input [6:0] opc;
        begin
            is_fma_op = (opc == 7'h43) || (opc == 7'h47) || (opc == 7'h4B) || (opc == 7'h4F);
        end
    endfunction

    function legal_inst;
        input [31:0] i;
        reg [6:0] opc, f7;
        reg [2:0] f3;
        reg [4:0] r2;
        reg       rm_ok;
        begin
            opc = i[6:0]; f3 = i[14:12]; f7 = i[31:25]; r2 = i[24:20];
            rm_ok = (f3 != 3'b101) && (f3 != 3'b110);
            case (opc)
                OP_LUI, OP_AUIPC, OP_JAL: legal_inst = 1'b1;
                OP_JALR: legal_inst = (f3 == 3'b000);
                OP_BR:   legal_inst = (f3 != 3'b010) && (f3 != 3'b011);
                OP_LD:   legal_inst = (f3 != 3'b011) && (f3 != 3'b110) && (f3 != 3'b111);
                OP_ST:   legal_inst = (f3 == 3'b000) || (f3 == 3'b001) || (f3 == 3'b010);
                OP_IMM:  legal_inst = (f3 != 3'b001 || f7 == 7'h00) &&
                                      (f3 != 3'b101 || f7 == 7'h00 || f7 == 7'h20);
                OP_OP:   legal_inst = (f7 == 7'h00) || (f7 == 7'h01) ||
                                      (f7 == 7'h20 && (f3 == 3'b000 || f3 == 3'b101));
                OP_FLW, OP_FSW: legal_inst = (f3 == 3'b010);
                OP_FP: legal_inst =
                    ((f7 == 7'h00 || f7 == 7'h04 || f7 == 7'h08 || f7 == 7'h0C) && rm_ok) ||
                    (f7 == 7'h2C && r2 == 5'd0 && rm_ok) ||
                    (f7 == 7'h10 && f3 <= 3'b010) || (f7 == 7'h14 && f3 <= 3'b001) ||
                    (f7 == 7'h50 && f3 <= 3'b010) ||
                    (f7 == 7'h70 && r2 == 5'd0 && f3 <= 3'b001) ||
                    ((f7 == 7'h60 || f7 == 7'h68) && rm_ok && r2 <= 5'd1) ||
                    (f7 == 7'h78 && r2 == 5'd0 && f3 == 3'b000);
                OP_SYS: legal_inst = (i == EBREAK) ||
                    (f3 != 3'b000 && f3 != 3'b100 &&
                     (i[31:20] == 12'h001 || i[31:20] == 12'h002 || i[31:20] == 12'h003));
                default: legal_inst = is_fma_op(opc) && (i[26:25] == 2'b00) && rm_ok;
            endcase
        end
    endfunction

    // Integer sources by class: phase 4 (OP, OP-IMM, LOAD, STORE, BRANCH,
    // JALR) plus the integer-reading F instructions.
    function reads_rs1;
        input [31:0] i;
        begin
            reads_rs1 = legal_inst(i) &&
                ((i[6:0] == OP_OP) || (i[6:0] == OP_IMM) || (i[6:0] == OP_LD) ||
                 (i[6:0] == OP_ST) || (i[6:0] == OP_BR) || (i[6:0] == OP_JALR) ||
                 (i[6:0] == OP_FLW) || (i[6:0] == OP_FSW) ||
                 (i[6:0] == OP_FP && (i[31:25] == 7'h68 || i[31:25] == 7'h78)) ||
                 (i[6:0] == OP_SYS && i != EBREAK && !i[14]));
        end
    endfunction

    function reads_rs2;
        input [31:0] i;
        begin
            reads_rs2 = legal_inst(i) &&
                ((i[6:0] == OP_OP) || (i[6:0] == OP_ST) || (i[6:0] == OP_BR));
        end
    endfunction

    // Instructions that broadcast on the CDB (PDF 4.4, 4.10.1).
    function cdb_class;
        input [31:0] i;
        input        trap;
        reg   [6:0]  opc;
        begin
            opc = i[6:0];
            if (!legal_inst(i) || i == EBREAK)
                cdb_class = 1'b0;
            else if (opc == OP_ST || opc == OP_FSW)
                cdb_class = 1'b0;
            else if (opc == OP_LD || opc == OP_FLW)
                cdb_class = !trap;
            else
                cdb_class = 1'b1;
        end
    endfunction

    // ------------------------------------------------------------------
    // Reference trace
    // ------------------------------------------------------------------
    // Column numbers (0-based) of the reference rows.
    localparam C_PC = 0, C_INST = 1, C_TRAP = 2, C_HALT = 3, C_RS1A = 4, C_RS1D = 5,
               C_RS2A = 6, C_RS2D = 7, C_RDA = 8, C_RDD = 9, C_MOP = 10, C_MADDR = 11,
               C_MMASK = 12, C_MWDATA = 13, C_NPC = 14, C_F1A = 15, C_F1D = 16,
               C_F2A = 17, C_F2D = 18, C_F3A = 19, C_F3D = 20, C_FWEN = 21, C_FDA = 22,
               C_FDD = 23, C_FFL = 24, C_MRDATA = 25;

    reg  [31:0] refc [0:MAX_REF*NCOL-1];
    integer     ref_n;
    integer     ref_bad;      // retires that differ from the reference
    integer     ref_first;    // index of the first one, -1 if none

    function care;
        input [31:0] v;
        begin
            care = (^v !== 1'bx);
        end
    endfunction

    task load_ref;
        input [8*256-1:0] path;
        integer     fd, r, n, k;
        reg [8*1024-1:0] line;
        reg [31:0]  c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12,
                    c13, c14, c15, c16, c17, c18, c19, c20, c21, c22, c23, c24, c25;
        begin
            ref_n = 0;
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("[FAIL] %0s: cannot open reference %0s", LABEL, path);
                failed = failed + 1;
            end else begin
                r = $fgets(line, fd);
                while (r != 0 && ref_n < MAX_REF) begin
                    {c15, c16, c17, c18, c19, c20, c21, c22, c23, c24, c25} = {11{32'hxxxxxxxx}};
                    n = $sscanf(line, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                                c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12,
                                c13, c14, c15, c16, c17, c18, c19, c20, c21, c22, c23, c24, c25);
                    if (n >= 15) begin
                        k = ref_n * NCOL;
                        refc[k+0] = c0;   refc[k+1] = c1;   refc[k+2] = c2;   refc[k+3] = c3;
                        refc[k+4] = c4;   refc[k+5] = c5;   refc[k+6] = c6;   refc[k+7] = c7;
                        refc[k+8] = c8;   refc[k+9] = c9;   refc[k+10] = c10; refc[k+11] = c11;
                        refc[k+12] = c12; refc[k+13] = c13; refc[k+14] = c14; refc[k+15] = c15;
                        refc[k+16] = c16; refc[k+17] = c17; refc[k+18] = c18; refc[k+19] = c19;
                        refc[k+20] = c20; refc[k+21] = c21; refc[k+22] = c22; refc[k+23] = c23;
                        refc[k+24] = c24; refc[k+25] = c25;
                        ref_n = ref_n + 1;
                    end
                    r = $fgets(line, fd);
                end
                $fclose(fd);
            end
        end
    endtask

    // Compares one retire with reference row k. Returns the number of
    // mismatching columns; with show = 1 prints every column.
    reg  [31:0] e_lanes;
    function [31:0] lane_bits;
        input [3:0] m;
        begin
            lane_bits = {{8{m[3]}}, {8{m[2]}}, {8{m[1]}}, {8{m[0]}}};
        end
    endfunction

    integer cmp_n;
    reg [8*400-1:0] cmp_cols;
    task cmp_field;
        input [8*12-1:0] name;
        input            do_check;
        input [31:0]     got;
        input [31:0]     want;
        input [31:0]     lanes;      // bits compared
        begin
            if (do_check && ((got & lanes) !== (want & lanes))) begin
                cmp_n = cmp_n + 1;
                if (cmp_n <= 6)
                    $sformat(cmp_cols, "%0s %0s(got %h exp %h)", cmp_cols, name, got, want);
            end
        end
    endtask

    task compare_ref;
        input integer k;
        integer   b;
        reg [31:0] mop, inst;
        begin
            b = k * NCOL;
            inst = refc[b+C_INST];
            mop = refc[b+C_MOP];
            cmp_n = 0;
            cmp_cols = "";
            cmp_field("pc",        1'b1, retire_pc, refc[b+C_PC], 32'hFFFFFFFF);
            cmp_field("inst",      1'b1, retire_inst, inst, 32'hFFFFFFFF);
            cmp_field("trap",      care(refc[b+C_TRAP]), {31'd0, retire_trap}, refc[b+C_TRAP], 32'h1);
            cmp_field("halt",      care(refc[b+C_HALT]), {31'd0, retire_halt}, refc[b+C_HALT], 32'h1);
            cmp_field("rs1_raddr", care(refc[b+C_RS1A]) && reads_rs1(inst), {27'd0, retire_rs1_raddr}, refc[b+C_RS1A], 32'h1F);
            cmp_field("rs1_rdata", care(refc[b+C_RS1D]) && reads_rs1(inst), retire_rs1_rdata, refc[b+C_RS1D], 32'hFFFFFFFF);
            cmp_field("rs2_raddr", care(refc[b+C_RS2A]) && reads_rs2(inst), {27'd0, retire_rs2_raddr}, refc[b+C_RS2A], 32'h1F);
            cmp_field("rs2_rdata", care(refc[b+C_RS2D]) && reads_rs2(inst), retire_rs2_rdata, refc[b+C_RS2D], 32'hFFFFFFFF);
            cmp_field("rd_waddr",  care(refc[b+C_RDA]), {27'd0, retire_rd_waddr}, refc[b+C_RDA], 32'h1F);
            cmp_field("rd_wdata",  care(refc[b+C_RDD]) && refc[b+C_RDA] != 0, retire_rd_wdata, refc[b+C_RDD], 32'hFFFFFFFF);
            cmp_field("mem_op",    care(mop), {30'd0, retire_dmem_wen, retire_dmem_ren}, mop, 32'h3);
            cmp_field("mem_addr",  care(refc[b+C_MADDR]) && mop != 0, retire_dmem_addr, refc[b+C_MADDR], 32'hFFFFFFFF);
            cmp_field("mem_mask",  care(refc[b+C_MMASK]) && mop != 0, {28'd0, retire_dmem_mask}, refc[b+C_MMASK], 32'hF);
            cmp_field("mem_wdata", care(refc[b+C_MWDATA]) && mop == 2, retire_dmem_wdata, refc[b+C_MWDATA],
                      lane_bits(refc[b+C_MMASK][3:0]));
            cmp_field("next_pc",   care(refc[b+C_NPC]), retire_next_pc, refc[b+C_NPC], 32'hFFFFFFFF);
            cmp_field("frs1_raddr", care(refc[b+C_F1A]), {27'd0, retire_frs1_raddr}, refc[b+C_F1A], 32'h1F);
            cmp_field("frs1_rdata", care(refc[b+C_F1D]), retire_frs1_rdata, refc[b+C_F1D], 32'hFFFFFFFF);
            cmp_field("frs2_raddr", care(refc[b+C_F2A]), {27'd0, retire_frs2_raddr}, refc[b+C_F2A], 32'h1F);
            cmp_field("frs2_rdata", care(refc[b+C_F2D]), retire_frs2_rdata, refc[b+C_F2D], 32'hFFFFFFFF);
            cmp_field("frs3_raddr", care(refc[b+C_F3A]), {27'd0, retire_frs3_raddr}, refc[b+C_F3A], 32'h1F);
            cmp_field("frs3_rdata", care(refc[b+C_F3D]), retire_frs3_rdata, refc[b+C_F3D], 32'hFFFFFFFF);
            cmp_field("frd_wen",   care(refc[b+C_FWEN]), {31'd0, retire_frd_wen}, refc[b+C_FWEN], 32'h1);
            cmp_field("frd_waddr", care(refc[b+C_FDA]) && refc[b+C_FWEN] == 1, {27'd0, retire_frd_waddr}, refc[b+C_FDA], 32'h1F);
            cmp_field("frd_wdata", care(refc[b+C_FDD]) && refc[b+C_FWEN] == 1, retire_frd_wdata, refc[b+C_FDD], 32'hFFFFFFFF);
            cmp_field("fflags",    care(refc[b+C_FFL]), {27'd0, retire_fflags}, refc[b+C_FFL], 32'h1F);
            cmp_field("mem_rdata", care(refc[b+C_MRDATA]) && mop == 1, retire_dmem_rdata, refc[b+C_MRDATA], 32'hFFFFFFFF);
            if (cmp_n != 0) begin
                ref_bad = ref_bad + 1;
                if (ref_first < 0) begin
                    ref_first = k;
                    $display("[FAIL] %0s: first retire that differs from %0s: #%0d at cycle %0d, %0d column(s):%0s",
                             LABEL, REF, k, cycles, cmp_n, cmp_cols);
                    $display("         expected: pc %h inst %h trap %h halt %h rs1 %h=%h rs2 %h=%h rd %h=%h mem %h %h %h %h npc %h",
                             refc[b+0], refc[b+1], refc[b+2], refc[b+3], refc[b+4], refc[b+5], refc[b+6],
                             refc[b+7], refc[b+8], refc[b+9], refc[b+10], refc[b+11], refc[b+12],
                             refc[b+13], refc[b+14]);
                    $display("         retired:  pc %h inst %h trap %h halt %h rs1 %h=%h rs2 %h=%h rd %h=%h mem %h %h %h %h npc %h",
                             retire_pc, retire_inst, retire_trap, retire_halt, retire_rs1_raddr,
                             retire_rs1_rdata, retire_rs2_raddr, retire_rs2_rdata, retire_rd_waddr,
                             retire_rd_wdata, {retire_dmem_wen, retire_dmem_ren}, retire_dmem_addr,
                             retire_dmem_mask, retire_dmem_wdata, retire_next_pc);
                    $display("         FP exp:   frs1 %h=%h frs2 %h=%h frs3 %h=%h frd %h %h=%h fflags %h | got frs1 %h=%h frs2 %h=%h frs3 %h=%h frd %h %h=%h fflags %h",
                             refc[b+15], refc[b+16], refc[b+17], refc[b+18], refc[b+19], refc[b+20],
                             refc[b+21], refc[b+22], refc[b+23], refc[b+24],
                             retire_frs1_raddr, retire_frs1_rdata, retire_frs2_raddr, retire_frs2_rdata,
                             retire_frs3_raddr, retire_frs3_rdata, retire_frd_wen, retire_frd_waddr,
                             retire_frd_wdata, retire_fflags);
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Complete stream
    // ------------------------------------------------------------------
    reg         pend_v     [0:7];
    reg  [31:0] pend_pc    [0:7];
    reg  [ 4:0] pend_rd    [0:7];
    reg  [31:0] pend_value [0:7];
    integer     pend_cycle [0:7];
    integer     tag_known;        // the next retiring instruction's tag is known
    integer     next_tag;
    integer     bad_cx;           // X/Z on the complete port
    integer     bad_cdup;         // second complete on a tag
    integer     bad_cmiss;        // missing complete
    integer     bad_cextra;       // complete for an instruction without one
    integer     bad_cval;         // complete rd/value
    integer     bad_ctag;         // tags not consecutive
    integer     n_cstray;         // completes never matched by a retire
    integer     n_inflight_done;
    integer     n_complete_cycles;
    integer     t, u, found, cnt;

    task observe_complete;
        begin
            if (complete_valid !== 1'b0 && complete_valid !== 1'b1) begin
                bad_cx = bad_cx + 1;
                if (bad_cx <= 3)
                    $display("[FAIL] %0s: o_complete_valid is X/Z at cycle %0d", LABEL, cycles);
            end else if (complete_valid === 1'b1) begin
                n_complete = n_complete + 1;
                n_complete_cycles = n_complete_cycles + 1;
                if (^{complete_tag, complete_rd, complete_value, complete_pc} === 1'bx) begin
                    bad_cx = bad_cx + 1;
                    if (bad_cx <= 3)
                        $display("[FAIL] %0s: o_complete_* has X/Z while valid at cycle %0d (tag %b rd %b pc %h value %h)",
                                 LABEL, cycles, complete_tag, complete_rd, complete_pc, complete_value);
                end else begin
                    if (pend_v[complete_tag]) begin
                        bad_cdup = bad_cdup + 1;
                        if (msgs < MAX_MSGS)
                            $display("[FAIL] %0s: second complete on tag %0d (pc %h) before its instruction retired (earlier complete pc %h, cycle %0d), cycle %0d",
                                     LABEL, complete_tag, complete_pc, pend_pc[complete_tag],
                                     pend_cycle[complete_tag], cycles);
                        msgs = msgs + 1;
                    end
                    pend_v[complete_tag]     = 1'b1;
                    pend_pc[complete_tag]    = complete_pc;
                    pend_rd[complete_tag]    = complete_rd;
                    pend_value[complete_tag] = complete_value;
                    pend_cycle[complete_tag] = cycles;
                    cnt = 0;
                    for (u = 0; u < 8; u = u + 1)
                        if (pend_v[u]) cnt = cnt + 1;
                    if (cnt > max_inflight_done) max_inflight_done = cnt;
                end
            end
        end
    endtask

    // At retire: find this instruction's complete (by tag, else by pc while
    // the tag sequence is not known yet) and check it.
    task retire_complete;
        input need;
        integer tg;
        begin
            tg = -1;
            if (tag_known) begin
                tg = next_tag;
                if (need && !(pend_v[tg] && pend_pc[tg] === retire_pc)) begin
                    // Is it under another tag? Then the tags are not consecutive.
                    found = -1;
                    for (u = 0; u < 8; u = u + 1)
                        if (pend_v[u] && pend_pc[u] === retire_pc && found < 0) found = u;
                    if (found >= 0) begin
                        bad_ctag = bad_ctag + 1;
                        report("complete tag not consecutive with the previous retire",
                               found, tg);
                        tg = found;
                    end
                end
            end else begin
                for (u = 0; u < 8; u = u + 1)
                    if (pend_v[u] && pend_pc[u] === retire_pc && tg < 0) tg = u;
            end

            if (need) begin
                if (tg < 0 || !pend_v[tg] || pend_pc[tg] !== retire_pc) begin
                    bad_cmiss = bad_cmiss + 1;
                    report("no o_complete before this retire (CDB class)", 32'd0, 32'd1);
                end else if (pend_cycle[tg] >= cycles) begin
                    bad_cmiss = bad_cmiss + 1;
                    report("o_complete in the same cycle as the retire", pend_cycle[tg], cycles - 1);
                end else begin
                    // Out of order: a younger instruction completed first.
                    found = 0;
                    for (u = 0; u < 8; u = u + 1)
                        if (u != tg && pend_v[u] && pend_cycle[u] < pend_cycle[tg]) found = 1;
                    if (found) n_ooo = n_ooo + 1;
                    // Values (not for a trapped branch/jump or FP op).
                    if (retire_trap !== 1'b1) begin
                        if (retire_inst[6:0] == OP_BR) begin
                            if (pend_rd[tg] !== 5'd0) begin
                                bad_cval = bad_cval + 1;
                                report("o_complete_rd of a branch", pend_rd[tg], 0);
                            end
                        end else if (retire_frd_wen === 1'b1) begin
                            if (pend_value[tg] !== retire_frd_wdata) begin
                                bad_cval = bad_cval + 1;
                                report("o_complete_value vs frd_wdata", pend_value[tg], retire_frd_wdata);
                            end
                            if (CHECK_FP_COMPLETE_RD && pend_rd[tg] !== retire_inst[11:7]) begin
                                bad_cval = bad_cval + 1;
                                report("o_complete_rd of an FP result", pend_rd[tg], retire_inst[11:7]);
                            end
                        end else begin
                            if (pend_rd[tg] !== retire_rd_waddr) begin
                                bad_cval = bad_cval + 1;
                                report("o_complete_rd vs retire rd", pend_rd[tg], retire_rd_waddr);
                            end
                            if (retire_rd_waddr !== 5'd0 && pend_value[tg] !== retire_rd_wdata) begin
                                bad_cval = bad_cval + 1;
                                report("o_complete_value vs rd_wdata", pend_value[tg], retire_rd_wdata);
                            end
                            if ((retire_inst[6:0] == OP_JAL || retire_inst[6:0] == OP_JALR) &&
                                pend_value[tg] !== retire_pc + 32'd4) begin
                                bad_cval = bad_cval + 1;
                                report("o_complete_value of jal/jalr (pc + 4)", pend_value[tg], retire_pc + 32'd4);
                            end
                        end
                    end
                    pend_v[tg] = 1'b0;
                end
            end else if (tg >= 0 && pend_v[tg] && pend_pc[tg] === retire_pc) begin
                bad_cextra = bad_cextra + 1;
                report("o_complete for an instruction that must not use the CDB", pend_value[tg], 0);
                pend_v[tg] = 1'b0;
            end

            if (tg >= 0) begin
                tag_known = 1;
                next_tag = (tg + 1) % 8;
            end else if (tag_known) begin
                next_tag = (next_tag + 1) % 8;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Retire monitor
    // ------------------------------------------------------------------
    integer bad_load, bad_inst, bad_pc, bad_lane, bad_xsrc, bad_fsrc, bad_dst;
    integer bad_flags, bad_csr, bad_rmtrap, n_traps, bad_retx;
    integer idle;
    integer n_loads, n_stores, n_fp, n_csr, prog_words;
    integer last_retire_cycle, gap, prev_ctrl;
    integer gap_ctrl, gap_load, gap_store, gap_m, gap_fp, gap_alu, gap_other, gap_fill;
    reg     halted;
    reg     have_prev;
    reg [31:0] prev_next_pc;
    reg [31:0] last_pc;

    reg [31:0] shadow [0:DMEM_WORDS-1];
    reg [31:0] golden [0:DMEM_WORDS-1];
    reg [31:0] xs [0:31];
    reg [31:0] fs [0:31];
    reg [ 4:0] sh_fflags;
    reg [ 2:0] sh_frm;

    function [1:0] mask_offset;
        input [3:0] mask;
        begin
            case (mask)
                4'b0010: mask_offset = 2'd1;
                4'b0100: mask_offset = 2'd2;
                4'b1000: mask_offset = 2'd3;
                4'b1100: mask_offset = 2'd2;
                default: mask_offset = 2'd0;
            endcase
        end
    endfunction

    function mask_ok;
        input [1:0] size;
        input [3:0] mask;
        begin
            case (size)
                2'd0:    mask_ok = (mask == 4'b0001) || (mask == 4'b0010) ||
                                   (mask == 4'b0100) || (mask == 4'b1000);
                2'd1:    mask_ok = (mask == 4'b0011) || (mask == 4'b1100);
                2'd2:    mask_ok = (mask == 4'b1111);
                default: mask_ok = 1'b0;
            endcase
        end
    endfunction

    reg  [31:0] widx, want, lanes, st_src;
    reg  [ 2:0] funct3;
    reg  [ 6:0] opcode, funct7;
    reg  [ 4:0] f_rd, f_rs1, f_rs2, f_rs3;
    integer     b;
    reg is_flw, is_fsw, is_fma, is_opfp, is_csr, is_f;
    reg rd_f1, rd_f2, rd_f3, wr_f, wr_x_fpu, can_flag, uses_rm;
    reg  [ 7:0] csr_old, csr_src, csr_new;
    reg         csr_wr;
    reg  [ 4:0] ff_after;
    reg  [ 2:0] frm_after;

    task observe_retire;
        begin
            retired = retired + 1;
            idle    = 0;
            last_pc = retire_pc;

            // Where the cycles since the previous retire went.
            gap = cycles - last_retire_cycle - 1;
            if (retired == 1)
                gap_fill = gap_fill + gap;
            else if (prev_ctrl)
                gap_ctrl = gap_ctrl + gap;
            else if (retire_trap === 1'b1 || retire_halt === 1'b1)
                gap_other = gap_other + gap;
            else if (retire_inst[6:0] == OP_LD || retire_inst[6:0] == OP_FLW)
                gap_load = gap_load + gap;
            else if (retire_inst[6:0] == OP_ST || retire_inst[6:0] == OP_FSW)
                gap_store = gap_store + gap;
            else if (retire_inst[6:0] == OP_OP && retire_inst[31:25] == 7'h01)
                gap_m = gap_m + gap;
            else if (is_fma_op(retire_inst[6:0]) || retire_inst[6:0] == OP_FP || retire_inst[6:0] == OP_SYS)
                gap_fp = gap_fp + gap;
            else
                gap_alu = gap_alu + gap;
            last_retire_cycle = cycles;
            prev_ctrl = (retire_inst[6:0] == OP_BR || retire_inst[6:0] == OP_JAL ||
                         retire_inst[6:0] == OP_JALR);
            opcode  = retire_inst[6:0];
            funct3  = retire_inst[14:12];
            funct7  = retire_inst[31:25];
            f_rd    = retire_inst[11:7];
            f_rs1   = retire_inst[19:15];
            f_rs2   = retire_inst[24:20];
            f_rs3   = retire_inst[31:27];

            if (^{retire_inst, retire_pc, retire_trap, retire_halt, retire_next_pc,
                  retire_rd_waddr, retire_frd_wen, retire_dmem_ren, retire_dmem_wen} === 1'bx) begin
                bad_retx = bad_retx + 1;
                report("X/Z on o_retire_inst/pc/trap/halt/next_pc/rd_waddr/frd_wen/dmem_ren/wen", 0, 0);
            end

            // Reference.
            if (REF != "") begin
                if (retired > ref_n) begin
                    ref_bad = ref_bad + 1;
                    if (ref_first < 0) begin
                        ref_first = retired - 1;
                        $display("[FAIL] %0s: retire #%0d (pc %h) is past the end of the reference (%0d rows)",
                                 LABEL, retired - 1, retire_pc, ref_n);
                    end
                end else begin
                    compare_ref(retired - 1);
                end
            end

            // Complete stream.
            retire_complete(cdb_class(retire_inst, retire_trap === 1'b1));

            is_flw  = (opcode == OP_FLW);
            is_fsw  = (opcode == OP_FSW);
            is_fma  = is_fma_op(opcode);
            is_opfp = (opcode == OP_FP);
            is_csr  = (opcode == OP_SYS) && (funct3 != 3'b000);
            is_f    = is_flw || is_fsw || is_fma || is_opfp || is_csr;
            rd_f1    = is_fma || (is_opfp && funct7 != 7'h68 && funct7 != 7'h78);
            rd_f2    = is_fsw || is_fma ||
                       (is_opfp && (funct7 == 7'h00 || funct7 == 7'h04 || funct7 == 7'h08 ||
                                    funct7 == 7'h0C || funct7 == 7'h10 || funct7 == 7'h14 ||
                                    funct7 == 7'h50));
            rd_f3    = is_fma;
            wr_x_fpu = is_csr || (is_opfp && (funct7 == 7'h50 || funct7 == 7'h60 || funct7 == 7'h70));
            wr_f     = is_flw || is_fma || (is_opfp && !wr_x_fpu);
            can_flag = is_fma || (is_opfp && funct7 != 7'h10 && funct7 != 7'h70 && funct7 != 7'h78);
            uses_rm  = is_fma || (is_opfp && (funct7 == 7'h00 || funct7 == 7'h04 || funct7 == 7'h08 ||
                                              funct7 == 7'h0C || funct7 == 7'h2C || funct7 == 7'h60 ||
                                              funct7 == 7'h68));
            if (is_f) n_fp = n_fp + 1;

            // Instruction word and PC.
            if (retire_pc < IMEM_BASE || retire_pc >= IMEM_BASE + 4 * IMEM_WORDS ||
                retire_pc[1:0] != 2'b00) begin
                bad_pc = bad_pc + 1;
                report("retired PC outside instruction memory or misaligned", retire_pc, IMEM_BASE);
            end else if (retire_inst !== imem[(retire_pc - IMEM_BASE) >> 2]) begin
                bad_inst = bad_inst + 1;
                report("instruction word vs imem", retire_inst, imem[(retire_pc - IMEM_BASE) >> 2]);
            end
            if (!have_prev && retire_pc !== IMEM_BASE) begin
                bad_pc = bad_pc + 1;
                report("first retired PC", retire_pc, IMEM_BASE);
            end else if (have_prev && retire_pc !== prev_next_pc) begin
                bad_pc = bad_pc + 1;
                report("PC (previous next_pc)", retire_pc, prev_next_pc);
            end
            if (((opcode != OP_BR && opcode != OP_JAL && opcode != OP_JALR) || retire_trap === 1'b1) &&
                retire_halt !== 1'b1 && retire_next_pc !== retire_pc + 32'd4) begin
                bad_pc = bad_pc + 1;
                report("next_pc of a non-jump or trapped instruction", retire_next_pc, retire_pc + 32'd4);
            end
            have_prev    = 1'b1;
            prev_next_pc = retire_next_pc;

            // Integer sources vs the shadow register file.
            if (retire_rs1_raddr !== 5'd0) begin
                if (retire_rs1_raddr !== f_rs1) begin
                    bad_xsrc = bad_xsrc + 1;
                    report("rs1 address vs inst[19:15]", retire_rs1_raddr, f_rs1);
                end else if (retire_rs1_rdata !== xs[f_rs1]) begin
                    bad_xsrc = bad_xsrc + 1;
                    report("rs1 value vs shadow register", retire_rs1_rdata, xs[f_rs1]);
                end
            end else if (reads_rs1(retire_inst) && f_rs1 != 5'd0) begin
                bad_xsrc = bad_xsrc + 1;
                report("rs1 not reported for an instruction that reads it", retire_rs1_raddr, f_rs1);
            end
            if (retire_rs2_raddr !== 5'd0) begin
                if (retire_rs2_raddr !== f_rs2) begin
                    bad_xsrc = bad_xsrc + 1;
                    report("rs2 address vs inst[24:20]", retire_rs2_raddr, f_rs2);
                end else if (retire_rs2_rdata !== xs[f_rs2]) begin
                    bad_xsrc = bad_xsrc + 1;
                    report("rs2 value vs shadow register", retire_rs2_rdata, xs[f_rs2]);
                end
            end else if (reads_rs2(retire_inst) && f_rs2 != 5'd0) begin
                bad_xsrc = bad_xsrc + 1;
                report("rs2 not reported for an instruction that reads it", retire_rs2_raddr, f_rs2);
            end

            if (retire_trap === 1'b1) begin
                n_traps = n_traps + 1;
                if (!TRAPS_OK)
                    report("unexpected trap", 1, 0);
            end

            if (uses_rm && funct3 == 3'b111 && legal_inst(retire_inst) &&
                (retire_trap === 1'b1) !== (sh_frm >= 3'd5)) begin
                bad_rmtrap = bad_rmtrap + 1;
                report("dynamic-rm trap vs shadow frm", retire_trap, sh_frm);
            end

            if (retire_trap !== 1'b1) begin
                if (rd_f1 && (retire_frs1_raddr !== f_rs1 || retire_frs1_rdata !== fs[f_rs1])) begin
                    bad_fsrc = bad_fsrc + 1;
                    report("frs1 address/value vs shadow FP register", retire_frs1_rdata, fs[f_rs1]);
                end
                if (rd_f2 && (retire_frs2_raddr !== f_rs2 || retire_frs2_rdata !== fs[f_rs2])) begin
                    bad_fsrc = bad_fsrc + 1;
                    report("frs2 address/value vs shadow FP register", retire_frs2_rdata, fs[f_rs2]);
                end
                if (rd_f3 && (retire_frs3_raddr !== f_rs3 || retire_frs3_rdata !== fs[f_rs3])) begin
                    bad_fsrc = bad_fsrc + 1;
                    report("frs3 address/value vs shadow FP register", retire_frs3_rdata, fs[f_rs3]);
                end
                if (wr_f) begin
                    if (retire_frd_wen !== 1'b1 || retire_frd_waddr !== f_rd) begin
                        bad_dst = bad_dst + 1;
                        report("frd_wen/frd vs inst[11:7]", {retire_frd_wen, retire_frd_waddr}, {1'b1, f_rd});
                    end
                    if (retire_rd_waddr !== 5'd0) begin
                        bad_dst = bad_dst + 1;
                        report("integer rd of an FP-writing instruction", retire_rd_waddr, 0);
                    end
                end else if (retire_frd_wen !== 1'b0) begin
                    bad_dst = bad_dst + 1;
                    report("frd_wen of an instruction that writes no FP register", retire_frd_wen, 0);
                end
                if (wr_x_fpu && retire_rd_waddr !== f_rd) begin
                    bad_dst = bad_dst + 1;
                    report("integer rd vs inst[11:7]", retire_rd_waddr, f_rd);
                end
            end else if (retire_frd_wen !== 1'b0 || retire_rd_waddr !== 5'd0) begin
                bad_dst = bad_dst + 1;
                report("trapped instruction writes a register", retire_rd_waddr, 0);
            end

            // fcsr (only F instructions report fflags).
            if (is_f) begin
                if (retire_trap === 1'b1) begin
                    if (retire_fflags !== sh_fflags) begin
                        bad_flags = bad_flags + 1;
                        report("fflags changed by a trapped instruction", retire_fflags, sh_fflags);
                    end
                end else if (is_csr) begin
                    n_csr   = n_csr + 1;
                    csr_old = (retire_inst[21:20] == 2'b01) ? {3'd0, sh_fflags} :
                              (retire_inst[21:20] == 2'b10) ? {5'd0, sh_frm} : {sh_frm, sh_fflags};
                    csr_src = funct3[2] ? {3'd0, f_rs1} : xs[f_rs1][7:0];
                    csr_new = (funct3[1:0] == 2'b01) ? csr_src :
                              (funct3[1:0] == 2'b10) ? (csr_old | csr_src) : (csr_old & ~csr_src);
                    csr_wr  = (funct3[1:0] == 2'b01) || (f_rs1 != 5'd0);
                    ff_after  = (csr_wr && retire_inst[21:20] != 2'b10) ? csr_new[4:0] : sh_fflags;
                    frm_after = (csr_wr && retire_inst[21:20] == 2'b10) ? csr_new[2:0] :
                                (csr_wr && retire_inst[21:20] == 2'b11) ? csr_new[7:5] : sh_frm;
                    if (retire_rd_waddr !== 5'd0 && retire_rd_wdata !== {24'd0, csr_old}) begin
                        bad_csr = bad_csr + 1;
                        report("CSR rd (old value) vs shadow fcsr", retire_rd_wdata, {24'd0, csr_old});
                    end
                    if (retire_fflags !== ff_after) begin
                        bad_flags = bad_flags + 1;
                        report("fflags after a CSR instruction", retire_fflags, ff_after);
                    end
                    sh_fflags = ff_after;
                    sh_frm    = frm_after;
                end else if (can_flag) begin
                    if ((retire_fflags & sh_fflags) !== sh_fflags) begin
                        bad_flags = bad_flags + 1;
                        report("fflags lost a bit (flags accrue)", retire_fflags, sh_fflags);
                    end
                    sh_fflags = retire_fflags;
                end else if (retire_fflags !== sh_fflags) begin
                    bad_flags = bad_flags + 1;
                    report("fflags changed by an instruction that raises none", retire_fflags, sh_fflags);
                end
            end

            // Memory access.
            if (retire_dmem_ren === 1'b1 && retire_dmem_wen === 1'b1) begin
                bad_lane = bad_lane + 1;
                report("dmem ren and wen both high", 1, 0);
            end else if (retire_dmem_ren === 1'b1 || retire_dmem_wen === 1'b1) begin
                widx = (retire_dmem_addr - DMEM_BASE) >> 2;
                if (retire_dmem_addr < DMEM_BASE || retire_dmem_addr >= DMEM_BASE + 4 * DMEM_WORDS ||
                    retire_dmem_addr[1:0] != 2'b00) begin
                    bad_lane = bad_lane + 1;
                    report("dmem address outside data memory or not word aligned", retire_dmem_addr, DMEM_BASE);
                end else if (!mask_ok(funct3[1:0], retire_dmem_mask)) begin
                    bad_lane = bad_lane + 1;
                    report("dmem mask", retire_dmem_mask, 0);
                end else if (retire_dmem_ren === 1'b1) begin
                    n_loads = n_loads + 1;
                    if (retire_dmem_rdata !== shadow[widx]) begin
                        bad_load = bad_load + 1;
                        report("load word vs shadow memory", retire_dmem_rdata, shadow[widx]);
                    end
                    if (is_flw) begin
                        if (retire_frd_wdata !== retire_dmem_rdata) begin
                            bad_lane = bad_lane + 1;
                            report("flw frd value vs rdata", retire_frd_wdata, retire_dmem_rdata);
                        end
                    end else begin
                        lanes = retire_dmem_rdata >> (8 * mask_offset(retire_dmem_mask));
                        case (funct3)
                            3'b000:  want = {{24{lanes[7]}}, lanes[7:0]};
                            3'b001:  want = {{16{lanes[15]}}, lanes[15:0]};
                            3'b100:  want = {24'd0, lanes[7:0]};
                            3'b101:  want = {16'd0, lanes[15:0]};
                            default: want = lanes;
                        endcase
                        if (retire_rd_waddr != 5'd0 && retire_rd_wdata !== want) begin
                            bad_lane = bad_lane + 1;
                            report("load rd value vs rdata", retire_rd_wdata, want);
                        end
                    end
                end else begin
                    n_stores = n_stores + 1;
                    st_src = is_fsw ? retire_frs2_rdata : retire_rs2_rdata;
                    want   = st_src << (8 * mask_offset(retire_dmem_mask));
                    for (b = 0; b < 4; b = b + 1) begin
                        if (retire_dmem_mask[b] && retire_dmem_wdata[8*b +: 8] !== want[8*b +: 8]) begin
                            bad_lane = bad_lane + 1;
                            report(is_fsw ? "store lane vs frs2" : "store lane vs rs2", retire_dmem_wdata, want);
                        end
                        if (retire_dmem_mask[b])
                            shadow[widx][8*b +: 8] = retire_dmem_wdata[8*b +: 8];
                    end
                end
            end else if ((opcode == OP_LD || opcode == OP_ST || opcode == OP_FLW || opcode == OP_FSW) &&
                         legal_inst(retire_inst) && retire_trap !== 1'b1) begin
                bad_lane = bad_lane + 1;
                report("load/store retired without dmem ren/wen and without a trap", 0, 1);
            end

            // Register writes, after every check of this instruction's sources.
            if (retire_trap !== 1'b1) begin
                if (retire_rd_waddr !== 5'd0)
                    xs[retire_rd_waddr] = retire_rd_wdata;
                if (retire_frd_wen === 1'b1)
                    fs[retire_frd_waddr] = retire_frd_wdata;
            end

            if (retire_halt === 1'b1) begin
                if (retire_inst !== EBREAK)
                    report("halt on a non-ebreak", retire_inst, EBREAK);
                halted = 1'b1;
            end
        end
    endtask

    // Sampled mid-cycle while the outputs are stable: completes first, so a
    // complete in the same cycle as its retire is seen as such.
    always @(negedge clk) begin
        if (running && !rst && !halted) begin
            cycles = cycles + 1;
            idle   = idle + 1;
            observe_complete;
            if (retire_valid === 1'b1) begin
                observe_retire;
            end else if (retire_valid !== 1'b0) begin
                bad_retx = bad_retx + 1;
                report("o_retire_valid is X/Z", 0, 0);
            end
        end
    end

    // ------------------------------------------------------------------
    // Memory regions of the random program (phase_6.pdf 6.1)
    // ------------------------------------------------------------------
    reg [8*16-1:0] rg_name [0:N_REGIONS-1];
    reg [31:0]     rg_lo   [0:N_REGIONS-1];
    reg [31:0]     rg_hi   [0:N_REGIONS-1];

    initial begin
        rg_name[0]  = "program data"; rg_lo[0]  = 32'h10010000; rg_hi[0]  = 32'h10017FFF;
        rg_name[1]  = "muldiv";       rg_lo[1]  = 32'h10020000; rg_hi[1]  = 32'h100217FF;
        rg_name[2]  = "fp move cmp";  rg_lo[2]  = 32'h10021800; rg_hi[2]  = 32'h10022FFF;
        rg_name[3]  = "fp convert";   rg_lo[3]  = 32'h10023000; rg_hi[3]  = 32'h100247FF;
        rg_name[4]  = "fp add mul";   rg_lo[4]  = 32'h10024800; rg_hi[4]  = 32'h10025FFF;
        rg_name[5]  = "fp fused";     rg_lo[5]  = 32'h10026000; rg_hi[5]  = 32'h100277FF;
        rg_name[6]  = "fp div sqrt";  rg_lo[6]  = 32'h10027800; rg_hi[6]  = 32'h10028FFF;
        rg_name[7]  = "fp csr";       rg_lo[7]  = 32'h10029000; rg_hi[7]  = 32'h1002A7FF;
        rg_name[8]  = "mixed";        rg_lo[8]  = 32'h1002A800; rg_hi[8]  = 32'h1002BFFF;
        rg_name[9]  = "cache stall";  rg_lo[9]  = 32'h1002C000; rg_hi[9]  = 32'h1002D7FF;
        rg_name[10] = "flush range";  rg_lo[10] = 32'h10018000; rg_hi[10] = 32'h1001FFFF;
        rg_name[11] = "tail";         rg_lo[11] = 32'h1002D800; rg_hi[11] = 32'h1002FFFF;
    end

    function integer count_diff;
        input        which;      // 0: main memory, 1: retire-stream shadow
        input [31:0] lo;
        input [31:0] hi;
        integer a;
        reg [31:0] v;
        begin
            count_diff = 0;
            for (a = (lo - DMEM_BASE) >> 2; a <= (hi - DMEM_BASE) >> 2; a = a + 1) begin
                v = which ? shadow[a] : u_mem.mem[a];
                if (v !== golden[a])
                    count_diff = count_diff + 1;
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // Run
    // ------------------------------------------------------------------
    reg [8*48-1:0]  why;
    reg [8*300-1:0] path;
    integer i, r, fd, n_words, sec_main, sec_shadow, main_vs_shadow, guard_bad, cpi_x100;
    reg [8*80-1:0] what;
    integer complete_errs;

    // Opens a repo-relative file from build/ (make test) or the repo root.
    task find_file;
        input  [8*256-1:0] rel;
        output [8*300-1:0] found_path;
        integer f;
        begin
            $sformat(found_path, "../%0s", rel);
            f = $fopen(found_path, "r");
            if (f == 0)
                $sformat(found_path, "%0s", rel);
            else
                $fclose(f);
        end
    endtask

    initial begin
        clk = 1'b0; rst = 1'b1; running = 1'b0; o_done = 1'b0;
        passed = 0; failed = 0; msgs = 0;
        cycles = 0; idle = 0; retired = 0; n_complete = 0; n_ooo = 0; max_inflight_done = 0;
        bad_load = 0; bad_inst = 0; bad_pc = 0; bad_lane = 0; bad_xsrc = 0; bad_fsrc = 0;
        bad_dst = 0; bad_flags = 0; bad_csr = 0; bad_rmtrap = 0; n_traps = 0; bad_retx = 0;
        bad_cx = 0; bad_cdup = 0; bad_cmiss = 0; bad_cextra = 0; bad_cval = 0; bad_ctag = 0;
        n_loads = 0; n_stores = 0; n_fp = 0; n_csr = 0;
        last_retire_cycle = 0; gap = 0; prev_ctrl = 0; n_complete_cycles = 0;
        gap_ctrl = 0; gap_load = 0; gap_store = 0; gap_m = 0; gap_fp = 0; gap_alu = 0;
        gap_other = 0; gap_fill = 0;
        ref_n = 0; ref_bad = 0; ref_first = -1;
        tag_known = 0; next_tag = 0;
        halted = 1'b0; have_prev = 1'b0;
        sh_fflags = 5'd0; sh_frm = 3'd0;
        for (i = 0; i < 8; i = i + 1) begin
            pend_v[i] = 1'b0; pend_pc[i] = 0; pend_rd[i] = 0; pend_value[i] = 0; pend_cycle[i] = 0;
        end
        for (i = 0; i < DMEM_WORDS; i = i + 1) begin
            shadow[i] = 32'd0;
            golden[i] = 32'd0;
        end
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            imem[i] = 32'd0;
        for (i = 0; i < 32; i = i + 1) begin
            xs[i] = 32'd0;
            fs[i] = 32'd0;
        end

        wait (i_start === 1'b1);

        find_file(PROG, path);
        prog_words = 0;
        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("[FAIL] %0s: cannot open program %0s", LABEL, PROG);
            failed = failed + 1;
        end else begin
            r = $fscanf(fd, "%h", widx);
            while (r == 1 && prog_words < IMEM_WORDS) begin
                imem[prog_words] = widx;
                prog_words = prog_words + 1;
                r = $fscanf(fd, "%h", widx);
            end
            $fclose(fd);
        end
        if (REF != "") begin
            find_file(REF, path);
            load_ref(path);
        end
        if (GOLD != "") begin
            find_file(GOLD, path);
            $readmemh(path, golden);
        end

        $display("--- %0s: %0s | EVICT_POLICY=%0d NUM_WAYS=%0d CACHE_SIZE=%0d BLOCK_SIZE=%0d PREFETCH_EN=%0d, latency %0d ---",
                 LABEL, PROG, EVICT_POLICY, NUM_WAYS, CACHE_SIZE, BLOCK_SIZE, PREFETCH_EN, LATENCY);

        // Reset for 5 edges, released just after a negedge: cycle 1 is the
        // first negedge after the first edge out of reset, the same count
        // the phase 4 testbench and traces use ("halted after N cycles").
        running = 1'b1;
        repeat (5) @(posedge clk);
        @(negedge clk);
        #1 rst = 1'b0;

        // o_complete_valid must be a clean 0/1 right after reset too.
        @(negedge clk);
        while (!halted && cycles < MAX_CYCLES && idle < IDLE_LIMIT &&
               retired < ((REF != "") ? ref_n + 16 : 4 * prog_words + 1000))
            @(posedge clk);

        if (!halted) begin
            $sformat(why, "%0s", idle >= IDLE_LIMIT ? "nothing retired for IDLE_LIMIT cycles" :
                                 cycles >= MAX_CYCLES ? "MAX_CYCLES reached" :
                                                        "too many instructions retired");
            if (retired == 0)
                $display("[FAIL] %0s: stopped at cycle %0d: %0s; nothing retired at all",
                         LABEL, cycles, why);
            else
                $display("[FAIL] %0s: stopped at cycle %0d: %0s; %0d retired, last retired PC %h",
                         LABEL, cycles, why, retired, last_pc);
        end

        // Let memory traffic in flight (a prefetch, a write-back) land.
        repeat (4 * LATENCY + 20) @(posedge clk);
        running = 1'b0;

        check("program loaded and fits in instruction memory", prog_words > 0 && prog_words < IMEM_WORDS);
        check("program ran to its ebreak", halted);
        if (retired > 0) begin
            if (REF != "") begin
                check("retire stream matches the reference trace", ref_bad == 0);
                check("retire count equals the reference (ends on the ebreak)", retired == ref_n);
            end
            check("retired words match imem", bad_inst == 0);
            check("retire PC sequence follows next_pc", bad_pc == 0);
            check("no X/Z on the retire port", bad_retx == 0);
            if (!TRAPS_OK)
                check("no traps", n_traps == 0);
            check("loads return the retire-stream memory", bad_load == 0);
            check("dmem address/mask/lane formatting (incl. flw/fsw)", bad_lane == 0);
            check("integer sources match the shadow register file", bad_xsrc == 0);
            check("FP sources match the shadow FP register file", bad_fsrc == 0);
            check("rd/frd reporting", bad_dst == 0);
            check("fflags accrue and match the shadow fcsr", bad_flags == 0);
            check("CSR instructions read the shadow fcsr", bad_csr == 0);
            check("dynamic-rm trap matches the shadow frm", bad_rmtrap == 0);
            check("o_complete_* never X/Z", bad_cx == 0);
            check("no second complete on a tag before it retires", bad_cdup == 0);
            check("every CDB-class instruction completes once, before it retires", bad_cmiss == 0);
            check("no complete for stores, ebreak, illegal or misaligned ops", bad_cextra == 0);
            check("complete rd/value match the retire", bad_cval == 0);
            check("consecutive retires carry consecutive tags", bad_ctag == 0);
        end
        n_cstray = 0;
        for (i = 0; i < 8; i = i + 1)
            if (pend_v[i]) n_cstray = n_cstray + 1;
        if (halted)
            check("every complete belongs to a retired instruction", n_cstray == 0);
        if (MIN_OOO > 0)
            check("out-of-order completes seen (witness)", n_ooo >= MIN_OOO);
        complete_errs = bad_cx + bad_cdup + bad_cmiss + bad_cextra + bad_cval + bad_ctag;
        $display("  %0s: retire errors: ref %0d (first #%0d) | xsrc %0d fsrc %0d dst %0d fflags %0d csr %0d rm-trap %0d lanes %0d load %0d inst %0d pc %0d x %0d | complete errors %0d (x %0d dup %0d missing %0d extra %0d value %0d tag %0d)",
                 LABEL, ref_bad, ref_first, bad_xsrc, bad_fsrc, bad_dst, bad_flags, bad_csr,
                 bad_rmtrap, bad_lane, bad_load, bad_inst, bad_pc, bad_retx, complete_errs,
                 bad_cx, bad_cdup, bad_cmiss, bad_cextra, bad_cval, bad_ctag);

        if (halted) begin
            main_vs_shadow = 0;
            for (i = 0; i < DMEM_WORDS; i = i + 1) begin
                if (u_mem.mem[i] !== shadow[i]) begin
                    if (FLUSHES && main_vs_shadow < 10)
                        $display("[FAIL] %0s: main memory at %h: %h, but the retire stream stored %h",
                                 LABEL, DMEM_BASE + 4 * i, u_mem.mem[i], shadow[i]);
                    main_vs_shadow = main_vs_shadow + 1;
                end
            end
            if (FLUSHES)
                check("main memory after halt equals the retire-stream stores", main_vs_shadow == 0);
            else
                $display("  INFO %0s: no flush before ebreak: %0d words of main memory differ from the retire-stream stores (allowed: dirty lines may still be cached)",
                         LABEL, main_vs_shadow);

            if (GOLD != "") begin
                // Sections 0-9 are graded; the flush range and tail are INFO.
                for (r = 0; r < N_REGIONS; r = r + 1) begin
                    sec_main   = count_diff(1'b0, rg_lo[r], rg_hi[r]);
                    sec_shadow = count_diff(1'b1, rg_lo[r], rg_hi[r]);
                    $display("  %0s %0s: golden %-12s %h-%h: main memory %0d words differ, retire stream %0d",
                             r < 10 ? "SECTION" : "INFO", LABEL, rg_name[r], rg_lo[r], rg_hi[r],
                             sec_main, sec_shadow);
                    if (r < 10) begin
                        $sformat(what, "golden section %0s: main memory and retire stream", rg_name[r]);
                        check(what, sec_main == 0 && sec_shadow == 0);
                    end
                end
            end

            guard_bad = 0;
            for (i = DMEM_WORDS; i < DMEM_WORDS + GUARD_WORDS; i = i + 1)
                if (u_mem.mem[i] !== 32'd0)
                    guard_bad = guard_bad + 1;
            check("nothing written past the end of data memory", guard_bad == 0);
        end
        check("memory protocol (mem_model.vh)", u_mem.errors == 0);

        cpi_x100 = retired > 0 ? (cycles * 100) / retired : 0;
        $display("  %0s: %0d cycles, %0d retired, CPI %0d.%02d | %0d completes, %0d out of order, max %0d completed-not-retired | %0d traps, %0d loads, %0d stores, %0d F/CSR | mem reads %0d, writes %0d (write-backs %0d, write-throughs %0d)",
                 LABEL, cycles, retired, cpi_x100 / 100, cpi_x100 % 100, n_complete, n_ooo,
                 max_inflight_done, n_traps, n_loads, n_stores, n_fp,
                 u_mem.n_rd, u_mem.n_wr, u_mem.n_wb, u_mem.n_wt);
        $display("  %0s: cycles without a retire: fill %0d, after br/jmp %0d, before load %0d, store %0d, M %0d, FP %0d, ALU %0d, trap/halt %0d | CDB busy %0d of %0d cycles",
                 LABEL, gap_fill, gap_ctrl, gap_load, gap_store, gap_m, gap_fp, gap_alu, gap_other,
                 n_complete_cycles, cycles);

        o_done = 1'b1;
    end

endmodule

// Cache configurations. phase_7.pdf does not say which one (or which memory
// latency) grading uses, and a hidden testbench may not override the
// skeleton defaults at all, so the defaults are always covered. All are in
// the phase 5 legal range.
//   DEFAULT  skeleton defaults: direct mapped, 16 KB, 128 B lines
//   GRADED   our phase 6 graded config: PLRU, 4-way, 2 KB, 16 B, prefetch
//   SMALL    direct mapped LRU, 1 KB, 16 B lines
//   LARGE    8-way LRU, 16 KB, 64 B lines, no prefetch
`define HART_CFG_DEFAULT .EVICT_POLICY(0), .NUM_WAYS(1), .CACHE_SIZE(16), .BLOCK_SIZE(128), .PREFETCH_EN(0)
`define HART_CFG_GRADED  .EVICT_POLICY(1), .NUM_WAYS(4), .CACHE_SIZE(2),  .BLOCK_SIZE(16),  .PREFETCH_EN(1)
`define HART_CFG_SMALL   .EVICT_POLICY(0), .NUM_WAYS(1), .CACHE_SIZE(1),  .BLOCK_SIZE(16),  .PREFETCH_EN(0)
`define HART_CFG_LARGE   .EVICT_POLICY(0), .NUM_WAYS(8), .CACHE_SIZE(16), .BLOCK_SIZE(64),  .PREFETCH_EN(0)

`endif
