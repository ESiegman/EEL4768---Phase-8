`timescale 1ns / 1ps
`default_nettype none
`include "mem_model.vh"

// Unit test for lsu.v (docs/lsu_interface.md) with the real cache/cache.v
// inside it and main_mem from mem_model.vh behind it.
//
// Each run generates a random program of memory ops (lb lh lw lbu lhu flw
// sb sh sw fsw; flw/fsw are lw/sw to the LSU) mixed with "ALU" producers,
// executes it once sequentially to get the expected value of every load
// (golden model), then drives it through the LSU with behavioral models of
//  * issue: in program order, random gaps, operands as {wait, qtag, value};
//    a producer broadcasting in the allocate cycle is passed as a Q-tag half
//    the time (the LSU must catch it) and as a bypassed value otherwise
//  * the ROB: 8 tags allocated consecutively, commit at the head, random
//    commit delays (a store that was written may be committed later)
//  * the CDB: one broadcast per cycle, from the LSU or a ready ALU producer
//  * the arbiter: grants the LSU's request after a random delay
// Operands come from ready values, ALU producers, and older loads (pointer
// chasing through a table that no store writes). Addresses are biased
// towards recently used words, bytes in them, neighbors and the next line,
// with far addresses for misses and evictions, and some deliberately
// misaligned halfword and word accesses.
//
// Checks, per run:
//  * cache requests: completed accesses follow program order exactly over
//    the aligned memory ops (each once: loads when they read, stores when
//    they write), a request is held unchanged until o_ready, never ren and
//    wen together, never a request for a misaligned op
//  * a store writes only while it is the ROB head, exactly once; the ROB
//    commits it in that cycle unless the model chose to delay
//  * the word a load reads equals the golden memory; its CDB value equals
//    the golden extended value and, at commit, the value computed from a
//    reference memory updated in commit order
//  * each aligned load raises exactly one CDB request, held with the same
//    tag and value until granted, only after its cache read; stores and
//    misaligned ops never request
//  * o_head_valid/ready/trap and the retire fields of every committed op;
//    o_head_ready never early
//  * o_full equals "8 entries in use"; every op allocated commits once
//  * the memory model saw no protocol errors
// Runs: several cache configurations, each at memory latency 1, 4 and 10.

module lsu_harness #(
    parameter LABEL        = "lsu",
    parameter EVICT_POLICY = 0,
    parameter NUM_WAYS     = 1,
    parameter CACHE_SIZE   = 1,
    parameter BLOCK_SIZE   = 16,
    parameter PREFETCH_EN  = 0,
    parameter LATENCY      = 4,
    parameter SEED         = 1,
    parameter N            = 3000
) (
    input  wire i_start,
    output reg  o_done
);

    localparam [31:0] DBASE  = 32'h10010000;   // data region, 64 KB
    localparam        DWORDS = 16384;
    localparam [31:0] PBASE  = 32'h10020000;   // pointer table, 1 KB
    localparam        PWORDS = 256;
    localparam        GUARD  = BLOCK_SIZE / 4;
    localparam        MEMW   = DWORDS + PWORDS;
    localparam        MAX_MSGS = 20;
    localparam        IDLE_LIMIT = 4000;

    integer passed;
    integer failed;

    // ------------------------------------------------------------------
    // Clock, DUT, memory
    // ------------------------------------------------------------------
    reg clk;
    reg rst;
    reg running;
    always begin
        wait (running);
        #5 clk = ~clk;
    end

    reg         alloc_valid;
    reg  [ 2:0] alloc_tag;
    reg         alloc_store;
    reg  [ 2:0] alloc_f3;
    reg  [31:0] alloc_imm;
    reg         base_wait;
    reg  [ 2:0] base_qtag;
    reg  [31:0] base_value;
    reg         data_wait;
    reg  [ 2:0] data_qtag;
    reg  [31:0] data_value;
    reg         cdb_valid;
    reg  [ 2:0] cdb_tag;
    reg  [31:0] cdb_value;
    reg         result_grant;
    reg  [ 2:0] rob_head;
    reg         commit_valid;

    wire        full;
    wire        result_valid;
    wire [ 2:0] result_tag;
    wire [31:0] result_value;
    wire        head_valid, head_ready, head_trap;
    wire [31:0] head_base, head_data, head_addr, head_rdata, head_wdata;
    wire [ 3:0] head_mask;
    wire        head_ren, head_wen;

    wire                    mem_rd, mem_valid, mem_wr;
    wire [31:0]             mem_rd_addr, mem_wr_addr;
    wire [BLOCK_SIZE*8-1:0] mem_rd_data, mem_wr_data;
    wire [BLOCK_SIZE-1:0]   mem_wr_be;

    lsu #(
        .EVICT_POLICY(EVICT_POLICY),
        .NUM_WAYS    (NUM_WAYS),
        .CACHE_SIZE  (CACHE_SIZE),
        .BLOCK_SIZE  (BLOCK_SIZE),
        .PREFETCH_EN (PREFETCH_EN)
    ) dut (
        .i_clk             (clk),
        .i_rst             (rst),
        .i_alloc_valid     (alloc_valid),
        .o_full            (full),
        .i_alloc_tag       (alloc_tag),
        .i_alloc_store     (alloc_store),
        .i_alloc_funct3    (alloc_f3),
        .i_alloc_imm       (alloc_imm),
        .i_alloc_base_wait (base_wait),
        .i_alloc_base_qtag (base_qtag),
        .i_alloc_base_value(base_value),
        .i_alloc_data_wait (data_wait),
        .i_alloc_data_qtag (data_qtag),
        .i_alloc_data_value(data_value),
        .i_cdb_valid       (cdb_valid),
        .i_cdb_tag         (cdb_tag),
        .i_cdb_value       (cdb_value),
        .o_result_valid    (result_valid),
        .i_result_grant    (result_grant),
        .o_result_tag      (result_tag),
        .o_result_value    (result_value),
        .i_rob_head        (rob_head),
        .i_commit_valid    (commit_valid),
        .o_head_valid      (head_valid),
        .o_head_ready      (head_ready),
        .o_head_trap       (head_trap),
        .o_head_base       (head_base),
        .o_head_data       (head_data),
        .o_head_dmem_addr  (head_addr),
        .o_head_dmem_mask  (head_mask),
        .o_head_dmem_ren   (head_ren),
        .o_head_dmem_wen   (head_wen),
        .o_head_dmem_rdata (head_rdata),
        .o_head_dmem_wdata (head_wdata),
        .o_mem_rd          (mem_rd),
        .o_mem_rd_addr     (mem_rd_addr),
        .i_mem_valid       (mem_valid),
        .i_mem_rd_data     (mem_rd_data),
        .o_mem_wr          (mem_wr),
        .o_mem_wr_addr     (mem_wr_addr),
        .o_mem_wr_data     (mem_wr_data),
        .o_mem_wr_be       (mem_wr_be)
    );

    main_mem #(
        .BLOCK_SIZE(BLOCK_SIZE),
        .LATENCY   (LATENCY),
        .BASE_ADDR (DBASE),
        .SIZE_WORDS(MEMW + GUARD),
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
    // Helpers
    // ------------------------------------------------------------------
    integer seed;
    function integer rnd;          // 0 .. k-1
        input integer k;
        begin
            rnd = ($random(seed) & 32'h7fffffff) % k;
        end
    endfunction

    task check;
        input [8*96-1:0] what;
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
    integer errs;
    integer cyc;
    task err;
        input [8*96-1:0] what;
        input integer    j;
        input [31:0]     got;
        input [31:0]     want;
        begin
            errs = errs + 1;
            if (msgs < MAX_MSGS)
                $display("[FAIL] %0s: %0s (op #%0d, cycle %0d): got %h, expected %h",
                         LABEL, what, j, cyc, got, want);
            else if (msgs == MAX_MSGS)
                $display("[FAIL] %0s: further errors not shown", LABEL);
            msgs = msgs + 1;
        end
    endtask

    function [3:0] lane_mask;
        input [2:0]  f3;
        input [31:0] a;
        begin
            case (f3[1:0])
                2'b00:   lane_mask = 4'b0001 << a[1:0];
                2'b01:   lane_mask = a[1] ? 4'b1100 : 4'b0011;
                default: lane_mask = 4'b1111;
            endcase
        end
    endfunction

    function [31:0] extend;
        input [2:0]  f3;
        input [31:0] a;
        input [31:0] w;
        reg   [31:0] s;
        begin
            s = w >> (8 * a[1:0]);
            case (f3)
                3'b000:  extend = {{24{s[7]}}, s[7:0]};
                3'b001:  extend = {{16{s[15]}}, s[15:0]};
                3'b100:  extend = {24'd0, s[7:0]};
                3'b101:  extend = {16'd0, s[15:0]};
                default: extend = w;
            endcase
        end
    endfunction

    function misaligned;
        input [2:0]  f3;
        input [31:0] a;
        begin
            misaligned = (f3[1:0] == 2'b01) ? a[0] :
                         (f3[1:0] == 2'b10) ? (a[1:0] != 2'b00) : 1'b0;
        end
    endfunction

    function [31:0] merge;         // store lanes into a word
        input [31:0] old;
        input [31:0] lanes;
        input [3:0]  m;
        integer b;
        begin
            merge = old;
            for (b = 0; b < 4; b = b + 1)
                if (m[b]) merge[8*b +: 8] = lanes[8*b +: 8];
        end
    endfunction

    // ------------------------------------------------------------------
    // Program
    // ------------------------------------------------------------------
    reg         p_mem  [0:N-1];
    reg         p_st   [0:N-1];
    reg  [ 2:0] p_f3   [0:N-1];
    reg  [31:0] p_imm  [0:N-1];
    integer     p_bsrc [0:N-1];    // -1: ready value
    reg  [31:0] p_bval [0:N-1];
    integer     p_dsrc [0:N-1];
    reg  [31:0] p_dval [0:N-1];
    reg  [31:0] p_ea   [0:N-1];
    reg         p_mis  [0:N-1];
    reg  [31:0] p_val  [0:N-1];    // ALU value, or a load's extended value
    reg  [31:0] p_raw  [0:N-1];    // the word a load reads
    reg         p_ptr  [0:N-1];    // load from the pointer table
    integer     p_lat  [0:N-1];    // ALU producer latency
    integer     acc    [0:N-1];    // aligned memory ops in program order
    integer     n_acc;

    reg  [31:0] gmem [0:MEMW-1];   // golden, sequential
    reg  [31:0] rmem [0:MEMW-1];   // reference, updated in commit order
    reg  [31:0] recent [0:7];
    integer     n_recent;
    integer     n_loads, n_stores, n_mis, n_alu, n_dep_base, n_dep_data;

    // Index of the youngest earlier instruction (within 12) that can
    // produce a base (ALU or pointer load) or store data (ALU or aligned
    // load), or -1.
    function integer pick_src;
        input integer i;
        input         for_base;
        integer k, start, j;
        begin
            pick_src = -1;
            start = rnd(12);
            for (k = 0; k < 12 && pick_src < 0; k = k + 1) begin
                j = i - 1 - ((start + k) % 12);
                if (j >= 0) begin
                    if (!p_mem[j])
                        pick_src = j;
                    else if (!p_st[j] && !p_mis[j] && (p_ptr[j] || !for_base))
                        pick_src = j;
                end
            end
        end
    endfunction

    // A target address in the data region, biased towards recent words.
    function [31:0] pick_target;
        input integer dummy;
        integer r;
        reg [31:0] base;
        reg [31:0] t;
        begin
            r = rnd(100);
            base = recent[rnd(n_recent > 0 ? (n_recent < 8 ? n_recent : 8) : 1)];
            if (n_recent == 0 || r >= 50)
                t = DBASE + rnd(DWORDS * 4);
            else if (r < 25)
                t = base + rnd(4);                       // same word
            else if (r < 40)
                t = base + 4 * (rnd(5) - 2);             // neighbors
            else
                t = base + (16 << rnd(4));               // next line
            if (t < DBASE || t >= DBASE + DWORDS * 4)
                t = DBASE + rnd(DWORDS * 4);
            pick_target = t;
        end
    endfunction

    integer i, k, r, sz, src, w;
    reg [31:0] t, imm, v;

    task generate_program;
        begin
            n_acc = 0; n_recent = 0;
            n_loads = 0; n_stores = 0; n_mis = 0; n_alu = 0;
            n_dep_base = 0; n_dep_data = 0;
            for (i = 0; i < DWORDS; i = i + 1) begin
                gmem[i] = $random(seed);
            end
            for (i = 0; i < PWORDS; i = i + 1)        // pointers into the data region
                gmem[DWORDS + i] = DBASE + 2048 + rnd(DWORDS * 4 - 4096);
            for (i = 0; i < MEMW; i = i + 1) begin
                rmem[i] = gmem[i];
                u_mem.mem[i] = gmem[i];
            end

            for (i = 0; i < N; i = i + 1) begin
                p_mem[i] = 1'b0; p_st[i] = 1'b0; p_f3[i] = 3'd0; p_imm[i] = 32'd0;
                p_bsrc[i] = -1; p_bval[i] = 32'd0; p_dsrc[i] = -1; p_dval[i] = 32'd0;
                p_ea[i] = 32'd0; p_mis[i] = 1'b0; p_val[i] = 32'd0; p_raw[i] = 32'd0;
                p_ptr[i] = 1'b0; p_lat[i] = 1;
                if (rnd(100) < 25) begin
                    // ALU producer: its value is usable as a base.
                    n_alu = n_alu + 1;
                    p_val[i] = DBASE + 2048 + rnd(DWORDS * 4 - 4096);
                    p_lat[i] = (rnd(10) == 0) ? 20 + rnd(20) : 1 + rnd(8);
                end else begin
                    p_mem[i] = 1'b1;
                    r = rnd(100);
                    if (r < 8) begin
                        // lw/flw from the pointer table.
                        p_ptr[i] = 1'b1;
                        p_f3[i] = 3'b010;
                        t = PBASE + 4 * rnd(PWORDS);
                        p_imm[i] = rnd(4096) - 2048;
                        p_bval[i] = t - p_imm[i];
                        p_ea[i] = t;
                    end else begin
                        case (rnd(10))
                            0: begin p_f3[i] = 3'b000; end          // lb
                            1: begin p_f3[i] = 3'b001; end          // lh
                            2: begin p_f3[i] = 3'b010; end          // lw
                            3: begin p_f3[i] = 3'b100; end          // lbu
                            4: begin p_f3[i] = 3'b101; end          // lhu
                            5: begin p_f3[i] = 3'b010; end          // flw
                            6: begin p_f3[i] = 3'b000; p_st[i] = 1'b1; end // sb
                            7: begin p_f3[i] = 3'b001; p_st[i] = 1'b1; end // sh
                            8: begin p_f3[i] = 3'b010; p_st[i] = 1'b1; end // sw
                            default: begin p_f3[i] = 3'b010; p_st[i] = 1'b1; end // fsw
                        endcase
                        sz = p_f3[i][1:0];
                        // Base: ready, or from a producer in flight.
                        src = (rnd(100) < 50) ? pick_src(i, 1'b1) : -1;
                        if (src >= 0) begin
                            n_dep_base = n_dep_base + 1;
                            p_bsrc[i] = src;
                            p_bval[i] = p_val[src];
                            imm = rnd(4080) - 2040;
                            t = p_bval[i] + imm;
                        end else begin
                            t = pick_target(0);
                            imm = rnd(4080) - 2040;
                        end
                        // Alignment: some halfword/word accesses misaligned.
                        if (sz != 0 && rnd(100) < 8) begin
                            t = (t & ~32'd3) | ((sz == 1) ? (rnd(2) ? 32'd1 : 32'd3) : (1 + rnd(3)));
                        end else if (sz == 1) begin
                            t = t & ~32'd1;
                        end else if (sz == 2) begin
                            t = t & ~32'd3;
                        end
                        if (src >= 0)
                            imm = t - p_bval[i];
                        else
                            p_bval[i] = t - imm;
                        p_imm[i] = imm;
                        p_ea[i] = t;
                        p_mis[i] = misaligned(p_f3[i], t);
                        if (p_st[i]) begin
                            src = (rnd(100) < 60) ? pick_src(i, 1'b0) : -1;
                            if (src >= 0) begin
                                n_dep_data = n_dep_data + 1;
                                p_dsrc[i] = src;
                                p_dval[i] = p_val[src];
                            end else begin
                                p_dval[i] = $random(seed);
                            end
                        end
                    end
                    // Golden execution.
                    if (p_mis[i]) begin
                        n_mis = n_mis + 1;
                    end else begin
                        w = (p_ea[i] - DBASE) >> 2;
                        acc[n_acc] = i;
                        n_acc = n_acc + 1;
                        if (p_st[i]) begin
                            n_stores = n_stores + 1;
                            gmem[w] = merge(gmem[w], p_dval[i] << (8 * p_ea[i][1:0]),
                                            lane_mask(p_f3[i], p_ea[i]));
                        end else begin
                            n_loads = n_loads + 1;
                            p_raw[i] = gmem[w];
                            p_val[i] = extend(p_f3[i], p_ea[i], gmem[w]);
                        end
                        if (!p_ptr[i]) begin
                            recent[n_recent % 8] = p_ea[i] & ~32'd3;
                            n_recent = n_recent + 1;
                        end
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Execution model
    // ------------------------------------------------------------------
    integer idle;
    integer rob_prog [0:7];
    integer tag_of   [0:N-1];
    integer tb_head, tb_tail, rob_count, lsu_count, nxt, n_committed;
    reg     done_    [0:N-1];   // broadcast on the CDB in an earlier cycle
    integer issued_c [0:N-1];
    integer granted  [0:N-1];
    integer reqs     [0:N-1];   // request periods seen
    integer writes   [0:N-1];
    integer write_c  [0:N-1];
    reg     got      [0:N-1];   // its cache read completed in an earlier cycle
    reg [31:0] cdbv  [0:N-1];
    integer acc_ptr;

    // Observations of the previous cycle.
    reg         prev_pend, prev_ren, prev_wen;
    reg  [31:0] prev_addr, prev_wdata;
    reg  [ 3:0] prev_mask;
    reg         prev_req, prev_gnt;
    reg  [ 2:0] prev_rtag;
    reg  [31:0] prev_rval;

    // This cycle's decisions.
    reg         c_ren, c_wen, c_ready;
    reg  [31:0] c_addr, c_wdata, c_rdata;
    reg  [ 3:0] c_mask;
    integer     acc_j;              // op whose cache access completes, or -1
    integer     bc_j;               // op broadcast on the CDB, or -1
    reg         bc_lsu;
    integer     iss_j;              // op issued, or -1
    integer     com_j;              // op committed, or -1
    integer     lsu_wait;
    integer     h, s, cand, start;
    reg  [3:0]  m;

    // Statistics.
    integer full_cycles, max_lsu, stall_full, n_delayed_commit, n_snoop_alloc, n_read_hits;

    // An operand source has broadcast in an earlier cycle (or is a value).
    function src_ready;
        input integer sj;
        begin
            src_ready = (sj < 0) || done_[sj];
        end
    endfunction

    // A misaligned memory op older than op sj is still in the ROB.
    function older_mis_in_flight;
        input integer sj;
        integer q, pj;
        begin
            older_mis_in_flight = 1'b0;
            for (q = 0; q < 8; q = q + 1) begin
                pj = rob_prog[q];
                if (pj >= 0 && pj < sj && p_mem[pj] && p_mis[pj])
                    older_mis_in_flight = 1'b1;
            end
        end
    endfunction

    task resolve;                   // operand of an op issued this cycle
        input  integer    srcj;
        input  [31:0]     ready_val;
        output            o_wait;
        output [2:0]      o_qtag;
        output [31:0]     o_val;
        begin
            o_wait = 1'b0; o_qtag = 3'd0; o_val = ready_val;
            if (srcj >= 0) begin
                o_qtag = tag_of[srcj];
                o_val  = p_val[srcj];
                if (done_[srcj]) begin
                    o_wait = 1'b0;
                end else if (bc_j == srcj) begin
                    // Broadcasting right now: let the LSU catch it half the time.
                    o_wait = rnd(2);
                    if (o_wait) n_snoop_alloc = n_snoop_alloc + 1;
                end else begin
                    o_wait = 1'b1;
                    o_val  = 32'hDEADBEEF;   // must not be used
                end
            end
        end
    endtask

    task run;
        begin
            cyc = 0; idle = 0;
            tb_head = 0; tb_tail = 0; rob_count = 0; lsu_count = 0; nxt = 0; n_committed = 0;
            acc_ptr = 0; lsu_wait = 0;
            prev_pend = 0; prev_req = 0; prev_gnt = 0;
            full_cycles = 0; max_lsu = 0; stall_full = 0; n_delayed_commit = 0;
            n_snoop_alloc = 0; n_read_hits = 0;
            for (i = 0; i < 8; i = i + 1) rob_prog[i] = -1;
            for (i = 0; i < N; i = i + 1) begin
                done_[i] = 0; issued_c[i] = -1; granted[i] = 0; reqs[i] = 0;
                writes[i] = 0; write_c[i] = -1; got[i] = 0; tag_of[i] = 0; cdbv[i] = 0;
            end

            while (n_committed < N && idle < IDLE_LIMIT) begin
                @(negedge clk);
                cyc = cyc + 1;
                idle = idle + 1;
                alloc_valid = 0; cdb_valid = 0; result_grant = 0; commit_valid = 0;
                rob_head = tb_head;
                acc_j = -1; bc_j = -1; bc_lsu = 0; iss_j = -1; com_j = -1;
                #1;

                // ---- the cache port this cycle -------------------------
                c_ren = dut.dcache.i_ren; c_wen = dut.dcache.i_wen;
                c_addr = dut.dcache.i_addr; c_mask = dut.dcache.i_mask;
                c_wdata = dut.dcache.i_wdata; c_ready = dut.dcache.o_ready;
                c_rdata = dut.dcache.o_rdata;
                if (c_ren !== 1'b0 && c_ren !== 1'b1 || c_wen !== 1'b0 && c_wen !== 1'b1)
                    err("cache ren/wen X/Z", -1, {c_ren, c_wen}, 0);
                if (c_ren === 1'b1 && c_wen === 1'b1)
                    err("cache ren and wen together", -1, 1, 0);
                if (prev_pend && (c_ren !== prev_ren || c_wen !== prev_wen ||
                                  c_addr !== prev_addr || c_mask !== prev_mask ||
                                  (prev_wen && c_wdata !== prev_wdata)))
                    err("cache request changed before o_ready", -1, c_addr, prev_addr);
                if ((c_ren === 1'b1 || c_wen === 1'b1) && !prev_pend && c_ready === 1'b1 && c_ren === 1'b1)
                    n_read_hits = n_read_hits + 1;
                // Promptness: the port is not left idle while the next
                // access in program order is ready (a load with its base, or
                // the head store with base and data), unless a misaligned op
                // in front of it is still being stepped over.
                if (acc_ptr < n_acc && c_ren !== 1'b1 && c_wen !== 1'b1) begin
                    s = acc[acc_ptr];
                    if (issued_c[s] >= 0 && issued_c[s] < cyc && src_ready(p_bsrc[s]) &&
                        (!p_st[s] || (src_ready(p_dsrc[s]) && rob_count > 0 &&
                                      rob_prog[tb_head] == s)) &&
                        !older_mis_in_flight(s))
                        err("cache idle while the next access is ready", s, 0, 1);
                end
                if ((c_ren === 1'b1 || c_wen === 1'b1) && c_ready === 1'b1) begin
                    if (acc_ptr >= n_acc) begin
                        err("cache access with none left in program order", -1, c_addr, 0);
                    end else begin
                        acc_j = acc[acc_ptr];
                        acc_ptr = acc_ptr + 1;
                        m = lane_mask(p_f3[acc_j], p_ea[acc_j]);
                        if (c_wen !== p_st[acc_j])
                            err("cache access out of program order (load/store)", acc_j, c_wen, p_st[acc_j]);
                        else if (c_addr !== {p_ea[acc_j][31:2], 2'b00})
                            err("cache access out of program order (address)", acc_j, c_addr, {p_ea[acc_j][31:2], 2'b00});
                        else if (c_wen === 1'b1 && c_mask !== m)
                            err("store byte mask", acc_j, c_mask, m);
                        else if (c_wen === 1'b1 &&
                                 (merge(32'd0, c_wdata, m) !== merge(32'd0, p_dval[acc_j] << (8 * p_ea[acc_j][1:0]), m)))
                            err("store lane data", acc_j, c_wdata, p_dval[acc_j] << (8 * p_ea[acc_j][1:0]));
                        else if (c_ren === 1'b1 && c_rdata !== p_raw[acc_j])
                            err("word read by a load (golden memory)", acc_j, c_rdata, p_raw[acc_j]);
                        if (issued_c[acc_j] < 0 || issued_c[acc_j] >= cyc)
                            err("cache access for an op not yet allocated", acc_j, 0, 0);
                        if (c_wen === 1'b1) begin
                            if (rob_count == 0 || rob_prog[tb_head] != acc_j)
                                err("store written while not the ROB head", acc_j, 0, 0);
                            writes[acc_j] = writes[acc_j] + 1;
                            write_c[acc_j] = cyc;
                        end
                    end
                end
                prev_pend  = (c_ren === 1'b1 || c_wen === 1'b1) && c_ready !== 1'b1;
                prev_ren   = c_ren;  prev_wen = c_wen;
                prev_addr  = c_addr; prev_mask = c_mask; prev_wdata = c_wdata;

                // ---- the LSU's CDB request ------------------------------
                if (result_valid === 1'b1) begin
                    h = rob_prog[result_tag];
                    if (h < 0 || issued_c[h] < 0 || tag_of[h] != result_tag)
                        err("CDB request for a tag not in flight", -1, result_tag, 0);
                    else if (!p_mem[h] || p_st[h] || p_mis[h])
                        err("CDB request from a store, misaligned op or non-memory op", h, result_tag, 0);
                    else if (!got[h] && acc_j != h)
                        // A load may request the CDB in the cycle the cache
                        // answers it (cache ready + grant), or later.
                        err("CDB request before the load read the cache", h, result_tag, 0);
                    else if (granted[h] != 0)
                        err("second CDB request for a load", h, result_tag, 0);
                    else if (result_value !== p_val[h])
                        err("load value on the CDB request (golden)", h, result_value, p_val[h]);
                    if (prev_req && !prev_gnt && (result_tag !== prev_rtag || result_value !== prev_rval))
                        err("CDB request changed before its grant", h, result_tag, prev_rtag);
                    if (h >= 0 && !(prev_req && !prev_gnt))
                        reqs[h] = reqs[h] + 1;
                end else if (result_valid !== 1'b0) begin
                    err("o_result_valid X/Z", -1, 0, 0);
                end else if (prev_req && !prev_gnt) begin
                    err("CDB request dropped before its grant", -1, prev_rtag, 0);
                end
                // Promptness: the request is for the oldest load in flight
                // whose word was latched in an earlier cycle and that has not
                // been broadcast yet.
                cand = -1;
                for (k = 0; k < rob_count && cand < 0; k = k + 1) begin
                    s = rob_prog[(tb_head + k) % 8];
                    if (p_mem[s] && !p_st[s] && !p_mis[s] && got[s] && granted[s] == 0)
                        cand = s;
                end
                if (cand >= 0 && (result_valid !== 1'b1 || rob_prog[result_tag] != cand))
                    err("CDB request is not the oldest load with its data latched", cand,
                        result_valid === 1'b1 ? rob_prog[result_tag] : -1, cand);
                // With no latched load waiting, a load the cache answers this
                // cycle requests the CDB in the same cycle.
                if (cand < 0 && acc_j >= 0 && !p_st[acc_j] && !p_mis[acc_j] &&
                    (result_valid !== 1'b1 || rob_prog[result_tag] != acc_j))
                    err("load answered by the cache this cycle does not request the CDB", acc_j,
                        result_valid === 1'b1 ? rob_prog[result_tag] : -1, acc_j);

                // ---- this cycle's CDB -----------------------------------
                cand = -1;
                start = rnd(8);
                for (k = 0; k < 8 && cand < 0; k = k + 1) begin
                    s = rob_prog[(start + k) % 8];
                    if (s >= 0 && !p_mem[s] && !done_[s] && issued_c[s] >= 0 &&
                        cyc - issued_c[s] >= p_lat[s])
                        cand = s;
                end
                r = rnd(100);
                if (result_valid === 1'b1 && (r < 40 || lsu_wait >= 10 || (cand < 0 && r < 75))) begin
                    bc_lsu = 1; bc_j = rob_prog[result_tag];
                    result_grant = 1; cdb_valid = 1;
                    cdb_tag = result_tag; cdb_value = result_value;
                end else if (cand >= 0 && r < 92) begin
                    bc_j = cand;
                    cdb_valid = 1; cdb_tag = tag_of[cand]; cdb_value = p_val[cand];
                end
                lsu_wait = (result_valid === 1'b1 && !bc_lsu) ? lsu_wait + 1 : 0;

                // ---- issue ----------------------------------------------
                if (full !== (lsu_count == 8))
                    err("o_full vs 8 entries in use", -1, full, lsu_count == 8);
                if (full === 1'b1) full_cycles = full_cycles + 1;
                if (nxt < N && rob_count < 8 && rnd(100) < 80) begin
                    if (p_mem[nxt] && full === 1'b1) begin
                        stall_full = stall_full + 1;
                    end else begin
                        iss_j = nxt;
                        if (p_mem[nxt]) begin
                            alloc_valid = 1;
                            alloc_tag   = tb_tail;
                            alloc_store = p_st[nxt];
                            alloc_f3    = p_f3[nxt];
                            alloc_imm   = p_imm[nxt];
                            resolve(p_bsrc[nxt], p_bval[nxt], base_wait, base_qtag, base_value);
                            if (p_st[nxt]) begin
                                resolve(p_dsrc[nxt], p_dval[nxt], data_wait, data_qtag, data_value);
                            end else begin
                                data_wait = rnd(2); data_qtag = rnd(8); data_value = $random(seed);
                            end
                        end
                    end
                end
                #1;

                // ---- the ROB head ---------------------------------------
                if (rob_count > 0) begin
                    h = rob_prog[tb_head];
                    if (!p_mem[h]) begin
                        if (head_valid !== 1'b0)
                            err("o_head_valid for a non-memory head", h, head_valid, 0);
                        if (done_[h] && rnd(100) < 85)
                            com_j = h;
                    end else if (issued_c[h] < cyc) begin
                        if (head_valid !== 1'b1)
                            err("o_head_valid low for a memory op at the head", h, head_valid, 1);
                        if (head_ready === 1'b1) begin
                            // Never early.
                            if (p_bsrc[h] >= 0 && !done_[p_bsrc[h]])
                                err("o_head_ready before the base arrived", h, 0, 0);
                            if (p_st[h] && p_dsrc[h] >= 0 && !done_[p_dsrc[h]])
                                err("o_head_ready before the store data arrived", h, 0, 0);
                            if (!p_st[h] && !p_mis[h] && granted[h] != 1)
                                err("o_head_ready for a load not yet broadcast", h, granted[h], 1);
                            if (p_st[h] && !p_mis[h] && writes[h] != 1)
                                err("o_head_ready for a store not yet written", h, writes[h], 1);
                            // Retire fields.
                            m = p_mis[h] ? 4'b0000 : lane_mask(p_f3[h], p_ea[h]);
                            v = p_dval[h] << (8 * p_ea[h][1:0]);
                            if (head_trap !== p_mis[h])
                                err("o_head_trap", h, head_trap, p_mis[h]);
                            if (head_addr !== {p_ea[h][31:2], 2'b00})
                                err("o_head_dmem_addr", h, head_addr, {p_ea[h][31:2], 2'b00});
                            if (head_mask !== m)
                                err("o_head_dmem_mask", h, head_mask, m);
                            if (head_ren !== (!p_st[h] && !p_mis[h]) || head_wen !== (p_st[h] && !p_mis[h]))
                                err("o_head_dmem_ren/wen", h, {head_ren, head_wen}, {!p_st[h] && !p_mis[h], p_st[h] && !p_mis[h]});
                            if (head_base !== p_bval[h])
                                err("o_head_base (rs1 used)", h, head_base, p_bval[h]);
                            if (p_st[h] && head_data !== p_dval[h])
                                err("o_head_data (store data used)", h, head_data, p_dval[h]);
                            if (!p_st[h] && !p_mis[h] && head_rdata !== p_raw[h])
                                err("o_head_dmem_rdata", h, head_rdata, p_raw[h]);
                            if (p_st[h] && head_wdata !== v)
                                err("o_head_dmem_wdata", h, head_wdata, v);
                            if (p_st[h] && !p_mis[h] && write_c[h] == cyc) begin
                                if (rnd(100) < 90) com_j = h;
                                else n_delayed_commit = n_delayed_commit + 1;
                            end else if (rnd(100) < 85) begin
                                com_j = h;
                            end
                        end else if (head_ready !== 1'b0) begin
                            err("o_head_ready X/Z", h, 0, 0);
                        end
                    end
                end
                commit_valid = (com_j >= 0);

                @(posedge clk);

                // ---- bookkeeping ----------------------------------------
                if (acc_j >= 0 && !p_st[acc_j]) got[acc_j] = 1;
                if (bc_j >= 0) begin
                    done_[bc_j] = 1;
                    cdbv[bc_j] = cdb_value;
                    if (bc_lsu) granted[bc_j] = granted[bc_j] + 1;
                end
                prev_req = (result_valid === 1'b1);
                prev_gnt = bc_lsu;
                prev_rtag = result_tag;
                prev_rval = result_value;
                if (com_j >= 0) begin
                    idle = 0;
                    if (p_mem[com_j]) begin
                        w = (p_ea[com_j] - DBASE) >> 2;
                        m = lane_mask(p_f3[com_j], p_ea[com_j]);
                        if (p_mis[com_j]) begin
                            if (writes[com_j] != 0 || granted[com_j] != 0 || reqs[com_j] != 0)
                                err("misaligned op used the cache or the CDB", com_j, writes[com_j], 0);
                        end else if (p_st[com_j]) begin
                            if (writes[com_j] != 1)
                                err("committed store not written exactly once", com_j, writes[com_j], 1);
                            rmem[w] = merge(rmem[w], p_dval[com_j] << (8 * p_ea[com_j][1:0]), m);
                        end else begin
                            if (granted[com_j] != 1 || reqs[com_j] != 1)
                                err("load not requested/granted exactly once", com_j, reqs[com_j], 1);
                            if (cdbv[com_j] !== extend(p_f3[com_j], p_ea[com_j], rmem[w]))
                                err("load value vs commit-order memory", com_j, cdbv[com_j],
                                    extend(p_f3[com_j], p_ea[com_j], rmem[w]));
                        end
                        if (reqs[com_j] != 0 && (p_st[com_j] || p_mis[com_j]))
                            err("store or trap requested the CDB", com_j, reqs[com_j], 0);
                        lsu_count = lsu_count - 1;
                    end
                    rob_prog[tb_head] = -1;
                    tb_head = (tb_head + 1) % 8;
                    rob_count = rob_count - 1;
                    n_committed = n_committed + 1;
                end
                if (iss_j >= 0) begin
                    tag_of[iss_j] = tb_tail;
                    rob_prog[tb_tail] = iss_j;
                    issued_c[iss_j] = cyc;
                    tb_tail = (tb_tail + 1) % 8;
                    rob_count = rob_count + 1;
                    if (p_mem[iss_j]) lsu_count = lsu_count + 1;
                    if (lsu_count > max_lsu) max_lsu = lsu_count;
                    nxt = nxt + 1;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    integer extra;
    initial begin
        clk = 0; rst = 1; running = 0; o_done = 0;
        passed = 0; failed = 0; msgs = 0; errs = 0;
        seed = SEED;
        alloc_valid = 0; alloc_tag = 0; alloc_store = 0; alloc_f3 = 0; alloc_imm = 0;
        base_wait = 0; base_qtag = 0; base_value = 0;
        data_wait = 0; data_qtag = 0; data_value = 0;
        cdb_valid = 0; cdb_tag = 0; cdb_value = 0; result_grant = 0;
        rob_head = 0; commit_valid = 0;

        wait (i_start === 1'b1);
        generate_program;
        $display("--- %0s: EVICT_POLICY=%0d NUM_WAYS=%0d CACHE_SIZE=%0d BLOCK_SIZE=%0d PREFETCH_EN=%0d, latency %0d, seed %0d ---",
                 LABEL, EVICT_POLICY, NUM_WAYS, CACHE_SIZE, BLOCK_SIZE, PREFETCH_EN, LATENCY, SEED);
        running = 1;
        repeat (4) @(posedge clk);
        @(negedge clk) rst = 0;

        // Reset clears everything: nothing is requested, nothing at the head.
        #1;
        check("after reset: not full, no CDB request, no cache request, head empty",
              full === 1'b0 && result_valid === 1'b0 && dut.dcache.i_ren === 1'b0 &&
              dut.dcache.i_wen === 1'b0 && head_valid === 1'b0);

        run;

        // Nothing more happens once everything has committed.
        extra = 0;
        repeat (4 * LATENCY + 20) begin
            @(negedge clk);
            if (dut.dcache.i_ren !== 1'b0 || dut.dcache.i_wen !== 1'b0 || result_valid !== 1'b0)
                extra = extra + 1;
        end
        running = 0;

        check("every op allocated, completed and committed", n_committed == N);
        check("all aligned memory ops used the cache, in program order", acc_ptr == n_acc);
        check("no LSU protocol or value errors (see [FAIL] lines)", errs == 0);
        check("idle after the last commit", extra == 0);
        check("memory model protocol", u_mem.errors == 0);
        $display("  %0s: %0d ops (%0d loads, %0d stores, %0d misaligned, %0d ALU; %0d dependent bases, %0d dependent store data) in %0d cycles",
                 LABEL, N, n_loads, n_stores, n_mis, n_alu, n_dep_base, n_dep_data, cyc);
        $display("  %0s: cache read hits %0d, memory reads %0d, write-backs %0d, write-throughs %0d | full %0d cycles (%0d issue stalls), max %0d entries, %0d allocate-cycle snoops, %0d delayed store commits | %0d errors",
                 LABEL, n_read_hits, u_mem.n_rd, u_mem.n_wb, u_mem.n_wt, full_cycles, stall_full,
                 max_lsu, n_snoop_alloc, n_delayed_commit, errs);
        o_done = 1;
    end

endmodule

module lsu_tb;
    localparam NRUNS = 15;
    reg  [NRUNS-1:0] start;
    wire [NRUNS-1:0] done;
    integer passed, failed, k;

    // Cache configurations x memory latency 1, 4, 10.
    //   A: skeleton defaults (direct mapped, 16 KB, 128 B lines)
    //   B: 4-way PLRU, 2 KB, 16 B lines, prefetch (phase 6 graded config)
    //   C: direct mapped LRU, 1 KB, 16 B lines
    //   D: 4-way LRU, 4 KB, 64 B lines, prefetch
    //   E: direct mapped, 1 KB, 64 B lines, prefetch
`define LSU_RUN(inst, idx, lbl, ep, nw, cs, bs, pf, lat, sd) \
    lsu_harness #(.LABEL(lbl), .EVICT_POLICY(ep), .NUM_WAYS(nw), .CACHE_SIZE(cs), \
                  .BLOCK_SIZE(bs), .PREFETCH_EN(pf), .LATENCY(lat), .SEED(sd)) \
        inst (.i_start(start[idx]), .o_done(done[idx]));

    `LSU_RUN(r0, 0,  "A lat1",  0, 1, 16, 128, 0, 1,  11)
    `LSU_RUN(r1, 1,  "A lat4",  0, 1, 16, 128, 0, 4,  12)
    `LSU_RUN(r2, 2,  "A lat10", 0, 1, 16, 128, 0, 10, 13)
    `LSU_RUN(r3, 3,  "B lat1",  1, 4, 2,  16,  1, 1,  21)
    `LSU_RUN(r4, 4,  "B lat4",  1, 4, 2,  16,  1, 4,  22)
    `LSU_RUN(r5, 5,  "B lat10", 1, 4, 2,  16,  1, 10, 23)
    `LSU_RUN(r6, 6,  "C lat1",  0, 1, 1,  16,  0, 1,  31)
    `LSU_RUN(r7, 7,  "C lat4",  0, 1, 1,  16,  0, 4,  32)
    `LSU_RUN(r8, 8,  "C lat10", 0, 1, 1,  16,  0, 10, 33)
    `LSU_RUN(r9, 9,  "D lat1",  0, 4, 4,  64,  1, 1,  41)
    `LSU_RUN(r10, 10, "D lat4",  0, 4, 4,  64,  1, 4,  42)
    `LSU_RUN(r11, 11, "D lat10", 0, 4, 4,  64,  1, 10, 43)
    `LSU_RUN(r12, 12, "E lat1",  0, 1, 1,  64,  1, 1,  51)
    `LSU_RUN(r13, 13, "E lat4",  0, 1, 1,  64,  1, 4,  52)
    `LSU_RUN(r14, 14, "E lat10", 0, 1, 1,  64,  1, 10, 53)

    initial begin
        $display("========== lsu testbench ==========");
        start = 0;
        for (k = 0; k < NRUNS; k = k + 1) begin
            start[k] = 1'b1;
            wait (done[k] === 1'b1);
        end
        passed = r0.passed + r1.passed + r2.passed + r3.passed + r4.passed +
                 r5.passed + r6.passed + r7.passed + r8.passed + r9.passed +
                 r10.passed + r11.passed + r12.passed + r13.passed + r14.passed;
        failed = r0.failed + r1.failed + r2.failed + r3.failed + r4.failed +
                 r5.failed + r6.failed + r7.failed + r8.failed + r9.failed +
                 r10.failed + r11.failed + r12.failed + r13.failed + r14.failed;
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end
endmodule

`default_nettype wire
