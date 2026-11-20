`default_nettype none

// Load-store unit (phase_7.pdf 4.3, 4.7, 4.10, 7.5). Interface and protocol:
// docs/lsu_interface.md.
//
// An 8-entry queue in program order. Entries are allocated at issue and
// freed when their instruction commits from the ROB head, so the LSU can
// report the retire fields of the memory op at the head. Three pointers walk
// the queue, each with a wrap bit so that "caught up" and "full" differ:
//  * hd: oldest entry, freed at commit
//  * tl: next entry to allocate
//  * cp: oldest entry that still needs the data cache. Only that entry may
//        use the cache, so accesses happen strictly in program order and no
//        load passes a store
// A load reads the cache when it is at cp, latches the word on o_ready and
// moves cp on, so the next op can use the cache while the load waits for
// the CDB. The CDB request is always the oldest load whose word is latched
// and not yet broadcast; cache reads happen in program order, so that load
// only changes when it is granted. A store writes the cache only when it is
// the ROB head (which is then also hd and cp); the ROB commits it in the
// cycle the cache accepts the write (o_head_ready). A misaligned op never
// touches the cache. Operands wait in the entry as {wait, qtag, value} and
// wake on the CDB, including in the allocate cycle.
module lsu #(
    // Data cache configuration, passed to cache/cache.v unchanged.
    parameter EVICT_POLICY = 0,
    parameter NUM_WAYS     = 1,
    parameter CACHE_SIZE   = 16,
    parameter BLOCK_SIZE   = 128,
    parameter PREFETCH_EN  = 0
) (
    input  wire                    i_clk,
    input  wire                    i_rst,

    // Allocate, from issue: one load or store per cycle, in program order,
    // only while o_full is low.
    input  wire                    i_alloc_valid,
    output wire                    o_full,
    input  wire [ 2:0]             i_alloc_tag,
    // 1 for sb/sh/sw/fsw, 0 for lb/lh/lw/lbu/lhu/flw.
    input  wire                    i_alloc_store,
    // inst[14:12]: [1:0] is the size, [2] unsigned. flw/fsw use 3'b010.
    input  wire [ 2:0]             i_alloc_funct3,
    // Sign-extended I-type (load) or S-type (store) immediate.
    input  wire [31:0]             i_alloc_imm,
    // Base register: wait for qtag on the CDB, or use value.
    input  wire                    i_alloc_base_wait,
    input  wire [ 2:0]             i_alloc_base_qtag,
    input  wire [31:0]             i_alloc_base_value,
    // Store data (x[rs2], or f[rs2] for fsw). Ignored for loads.
    input  wire                    i_alloc_data_wait,
    input  wire [ 2:0]             i_alloc_data_qtag,
    input  wire [31:0]             i_alloc_data_value,

    // CDB snoop.
    input  wire                    i_cdb_valid,
    input  wire [ 2:0]             i_cdb_tag,
    input  wire [31:0]             i_cdb_value,

    // Load result to the CDB arbiter, held unchanged until granted. Driven
    // from registers only. fflags for a load are zero.
    output wire                    o_result_valid,
    input  wire                    i_result_grant,
    output wire [ 2:0]             o_result_tag,
    output wire [31:0]             o_result_value,

    // ROB head and commit. i_commit_valid is only used at the clock edge.
    input  wire [ 2:0]             i_rob_head,
    input  wire                    i_commit_valid,
    // The ROB head is a load/store in the LSU (always the oldest entry),
    // it may commit this cycle, and it is a misaligned access.
    output wire                    o_head_valid,
    output wire                    o_head_ready,
    output wire                    o_head_trap,
    // Retire fields of the head: operands used and the phase 6 dmem values.
    output wire [31:0]             o_head_base,
    output wire [31:0]             o_head_data,
    output wire [31:0]             o_head_dmem_addr,
    output wire [ 3:0]             o_head_dmem_mask,
    output wire                    o_head_dmem_ren,
    output wire                    o_head_dmem_wen,
    output wire [31:0]             o_head_dmem_rdata,
    output wire [31:0]             o_head_dmem_wdata,

    // Main memory port of the data cache.
    output wire                    o_mem_rd,
    output wire [31:0]             o_mem_rd_addr,
    input  wire                    i_mem_valid,
    input  wire [BLOCK_SIZE*8-1:0] i_mem_rd_data,
    output wire                    o_mem_wr,
    output wire [31:0]             o_mem_wr_addr,
    output wire [BLOCK_SIZE*8-1:0] o_mem_wr_data,
    output wire [BLOCK_SIZE-1:0]   o_mem_wr_be
);

    // ------------------------------------------------------------------
    // Pointers
    // ------------------------------------------------------------------
    reg  [3:0] hd;
    reg  [3:0] tl;
    reg  [3:0] cp;
    wire [2:0] hd_i = hd[2:0];
    wire [2:0] tl_i = tl[2:0];
    wire [2:0] cp_i = cp[2:0];
    wire [2:0] rp_i;            // entry of the CDB request (picked below)

    wire hd_has = (hd != tl);
    wire cp_has = (cp != tl);
    assign o_full = (hd_i == tl_i) & (hd[3] != tl[3]);

    wire alloc = i_alloc_valid & ~o_full;

    // ------------------------------------------------------------------
    // Entries
    // ------------------------------------------------------------------
    wire [ 2:0] e_tag   [0:7];
    wire [ 7:0] e_st;       // store
    wire [ 2:0] e_f3    [0:7];
    wire [ 7:0] e_bw;       // base still waiting
    wire [31:0] e_bv    [0:7];
    wire [ 7:0] e_dw;       // store data still waiting
    wire [31:0] e_dv    [0:7];
    wire [31:0] e_ea    [0:7];  // effective address (valid once ~bw)
    wire [ 7:0] e_mis;      // misaligned (valid once ~bw)
    wire [ 7:0] e_got;      // load: cache word latched
    wire [31:0] e_raw   [0:7];
    wire [ 7:0] e_sent;     // load: CDB granted
    wire [ 7:0] e_wrote;    // store: cache write done
    // Oldest-first pick of the CDB request, as in reservation_station.v:
    // element n+1 has looked at entries 0..n.
    wire [ 8:0] pick_v;
    wire [ 2:0] pick_n   [0:8];
    wire [ 2:0] pick_age [0:8];
    assign pick_v[0]   = 1'b0;
    assign pick_n[0]   = 3'd0;
    assign pick_age[0] = 3'd0;

    // Cache handshake for this cycle (defined below).
    wire        load_fire;
    wire        write_fire;
    wire [31:0] c_rdata;
    wire        grant_fire = o_result_valid & i_result_grant;
    wire [ 2:0] res_i;          // entry of this cycle's CDB request (below)
    wire        free = i_commit_valid & o_head_valid;

    // The allocate-cycle CDB snoop (same rule as reservation_station.v).
    wire alloc_base_hit = i_cdb_valid & (i_alloc_base_qtag == i_cdb_tag);
    wire alloc_data_hit = i_cdb_valid & (i_alloc_data_qtag == i_cdb_tag);

    genvar n;
    generate
        for (n = 0; n < 8; n = n + 1) begin : g_entry
            localparam [2:0] ID = n;
            reg         live;
            reg  [ 2:0] tag;
            reg         st;
            reg  [ 2:0] f3;
            reg  [31:0] imm;
            reg         bw;
            reg  [ 2:0] bq;
            reg  [31:0] bv;
            reg         dw;
            reg  [ 2:0] dq;
            reg  [31:0] dv;
            reg         got;
            reg  [31:0] raw;
            reg         sent;
            reg         wrote;

            wire [31:0] ea = bv + imm;
            // f3[1:0]: 00 byte, 01 half, 10 word (11 is never issued).
            assign e_mis[n] = (f3[1:0] == 2'b00) ? 1'b0 :
                              (f3[1:0] == 2'b01) ? ea[0] :
                                                   (ea[1] | ea[0]);
            assign e_tag[n]   = tag;
            assign e_st[n]    = st;
            assign e_f3[n]    = f3;
            assign e_bw[n]    = bw;
            assign e_bv[n]    = bv;
            assign e_dw[n]    = dw;
            assign e_dv[n]    = dv;
            assign e_ea[n]    = ea;
            assign e_got[n]   = got;
            assign e_raw[n]   = raw;
            assign e_sent[n]  = sent;
            assign e_wrote[n] = wrote;

            // A live load with its word latched and not yet broadcast
            // (got is only ever set for an aligned load).
            wire       want   = live & ~st & got & ~sent;
            wire [2:0] age    = ID - hd_i;      // three-bit subtraction is mod 8
            wire       choose = want & (~pick_v[n] | (age < pick_age[n]));
            assign pick_v[n+1]   = pick_v[n] | want;
            assign pick_n[n+1]   = choose ? ID : pick_n[n];
            assign pick_age[n+1] = choose ? age : pick_age[n];

            always @(posedge i_clk) begin
                if (i_rst) begin
                    live  <= 1'b0;
                    tag   <= 3'd0;
                    st    <= 1'b0;
                    f3    <= 3'd0;
                    imm   <= 32'd0;
                    bw    <= 1'b0;
                    bq    <= 3'd0;
                    bv    <= 32'd0;
                    dw    <= 1'b0;
                    dq    <= 3'd0;
                    dv    <= 32'd0;
                    got   <= 1'b0;
                    raw   <= 32'd0;
                    sent  <= 1'b0;
                    wrote <= 1'b0;
                end else if (alloc && (tl_i == ID)) begin
                    // tl is never hd while an entry is live and the queue is
                    // not full, so this never overlaps an update below.
                    live  <= 1'b1;
                    tag   <= i_alloc_tag;
                    st    <= i_alloc_store;
                    f3    <= i_alloc_funct3;
                    imm   <= i_alloc_imm;
                    bw    <= i_alloc_base_wait & ~alloc_base_hit;
                    bq    <= i_alloc_base_qtag;
                    bv    <= (i_alloc_base_wait & alloc_base_hit) ? i_cdb_value :
                                                                    i_alloc_base_value;
                    dw    <= i_alloc_store & i_alloc_data_wait & ~alloc_data_hit;
                    dq    <= i_alloc_data_qtag;
                    dv    <= ~i_alloc_store ? 32'd0 :
                             (i_alloc_data_wait & alloc_data_hit) ? i_cdb_value :
                                                                    i_alloc_data_value;
                    got   <= 1'b0;
                    raw   <= 32'd0;
                    sent  <= 1'b0;
                    wrote <= 1'b0;
                end else begin
                    if (free && (hd_i == ID))
                        live <= 1'b0;
                    if (bw && i_cdb_valid && (bq == i_cdb_tag)) begin
                        bw <= 1'b0;
                        bv <= i_cdb_value;
                    end
                    if (dw && i_cdb_valid && (dq == i_cdb_tag)) begin
                        dw <= 1'b0;
                        dv <= i_cdb_value;
                    end
                    if (load_fire && (cp_i == ID)) begin
                        got <= 1'b1;
                        raw <= c_rdata;
                    end
                    if (grant_fire && (res_i == ID))
                        sent <= 1'b1;
                    if (write_fire && (hd_i == ID))
                        wrote <= 1'b1;
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // The entries at the three pointers
    // ------------------------------------------------------------------
    wire        hd_st    = e_st[hd_i];
    wire [ 2:0] hd_f3    = e_f3[hd_i];
    wire        hd_bready = ~e_bw[hd_i];
    wire        hd_dready = ~e_dw[hd_i];
    wire [31:0] hd_ea    = e_ea[hd_i];
    wire        hd_mis   = e_mis[hd_i];
    wire [31:0] hd_dv    = e_dv[hd_i];

    wire        cp_st    = e_st[cp_i];
    wire [ 2:0] cp_f3    = e_f3[cp_i];
    wire        cp_bready = ~e_bw[cp_i];
    wire [31:0] cp_ea    = e_ea[cp_i];
    wire        cp_mis   = e_mis[cp_i];

    assign      rp_i     = pick_n[8];
    wire [ 2:0] rp_f3    = e_f3[rp_i];
    wire [ 1:0] rp_off   = e_ea[rp_i][1:0];
    wire [31:0] rp_raw   = e_raw[rp_i];

    // Byte lanes of an access (phase 6 MEM stage).
    wire [ 1:0] hd_off = hd_ea[1:0];
    wire [ 1:0] cp_off = cp_ea[1:0];
    wire [ 3:0] hd_bmask = (hd_off == 2'd0) ? 4'b0001 :
                           (hd_off == 2'd1) ? 4'b0010 :
                           (hd_off == 2'd2) ? 4'b0100 : 4'b1000;
    wire [ 3:0] hd_mask = (hd_f3[1:0] == 2'b00) ? hd_bmask :
                          (hd_f3[1:0] == 2'b01) ? (hd_off[1] ? 4'b1100 : 4'b0011) :
                                                  4'b1111;
    wire [ 3:0] cp_bmask = (cp_off == 2'd0) ? 4'b0001 :
                           (cp_off == 2'd1) ? 4'b0010 :
                           (cp_off == 2'd2) ? 4'b0100 : 4'b1000;
    wire [ 3:0] cp_mask = (cp_f3[1:0] == 2'b00) ? cp_bmask :
                          (cp_f3[1:0] == 2'b01) ? (cp_off[1] ? 4'b1100 : 4'b0011) :
                                                  4'b1111;
    // Store data moved to its byte lanes (a mux, not a variable shift).
    wire [31:0] hd_wlane = (hd_off == 2'd0) ? hd_dv :
                           (hd_off == 2'd1) ? {hd_dv[23:0], 8'b0} :
                           (hd_off == 2'd2) ? {hd_dv[15:0], 16'b0} :
                                              {hd_dv[7:0], 24'b0};

    // ------------------------------------------------------------------
    // Data cache port
    // ------------------------------------------------------------------
    // A store writes when it is the ROB head: the oldest instruction in
    // flight, so it is also hd and cp. A load reads when it is at cp.
    wire store_cand = hd_has & hd_st & hd_bready & hd_dready & ~hd_mis &
                      ~e_wrote[hd_i] & (e_tag[hd_i] == i_rob_head);
    wire load_cand  = cp_has & ~cp_st & cp_bready & ~cp_mis;

    // A load miss already sent to the cache keeps the port until o_ready.
    // Otherwise a committing store beats a load starting this cycle
    // (phase_7.pdf 4.7). With in-order cache access both are never true
    // at once, but the priority is still explicit.
    reg  load_busy;
    wire drive_store = store_cand & ~load_busy;
    wire drive_load  = load_cand & (load_busy | ~store_cand);

    wire        c_ready;
    wire [31:0] c_addr = drive_store ? {hd_ea[31:2], 2'b00} : {cp_ea[31:2], 2'b00};
    wire [ 3:0] c_mask = drive_store ? hd_mask : drive_load ? cp_mask : 4'b0000;

    assign load_fire  = drive_load & c_ready;
    assign write_fire = drive_store & c_ready;

    always @(posedge i_clk) begin
        if (i_rst)
            load_busy <= 1'b0;
        else
            load_busy <= drive_load & ~c_ready;
    end

    cache #(
        .EVICT_POLICY(EVICT_POLICY),
        .NUM_WAYS    (NUM_WAYS),
        .CACHE_SIZE  (CACHE_SIZE),
        .BLOCK_SIZE  (BLOCK_SIZE),
        .PREFETCH_EN (PREFETCH_EN)
    ) dcache (
        .i_clk        (i_clk),
        .i_rst        (i_rst),
        .i_ren        (drive_load),
        .i_wen        (drive_store),
        .i_addr       (c_addr),
        .i_mask       (c_mask),
        .i_wdata      (hd_wlane),
        .o_ready      (c_ready),
        .o_rdata      (c_rdata),
        .o_mem_rd     (o_mem_rd),
        .o_mem_rd_addr(o_mem_rd_addr),
        .i_mem_valid  (i_mem_valid),
        .i_mem_rd_data(i_mem_rd_data),
        .o_mem_wr     (o_mem_wr),
        .o_mem_wr_addr(o_mem_wr_addr),
        .o_mem_wr_data(o_mem_wr_data),
        .o_mem_wr_be  (o_mem_wr_be)
    );

    // cp moves past an entry once it is done with the cache: a misaligned
    // op as soon as its base is known, a load when its word is latched, a
    // store once written.
    wire cp_adv = cp_has & cp_bready &
                  (cp_mis | (cp_st ? (e_wrote[cp_i] | (write_fire & (cp == hd))) :
                                     load_fire));

    // ------------------------------------------------------------------
    // CDB request: the oldest load with its word latched and not yet sent
    // ------------------------------------------------------------------
    // With no latched load waiting, a load reading the cache this cycle
    // requests the CDB straight from the cache (cache ready + grant in the
    // same cycle). If it loses, its word is latched as usual and it asks
    // again from the next cycle. Loads read the cache in order, so a
    // latched load is always older than the one reading now.
    wire        direct = load_fire & ~pick_v[8];
    assign      res_i  = pick_v[8] ? rp_i : cp_i;
    wire [ 2:0] q_f3   = pick_v[8] ? rp_f3  : cp_f3;
    wire [ 1:0] q_off  = pick_v[8] ? rp_off : cp_off;
    wire [31:0] q_raw  = pick_v[8] ? rp_raw : c_rdata;
    wire [31:0] q_sh   = (q_off == 2'd0) ? q_raw :
                         (q_off == 2'd1) ? {8'b0, q_raw[31:8]} :
                         (q_off == 2'd2) ? {16'b0, q_raw[31:16]} :
                                           {24'b0, q_raw[31:24]};
    assign o_result_valid = pick_v[8] | direct;
    assign o_result_tag   = e_tag[res_i];
    assign o_result_value = (q_f3[1:0] == 2'b00) ? {{24{~q_f3[2] & q_sh[7]}}, q_sh[7:0]} :
                            (q_f3[1:0] == 2'b01) ? {{16{~q_f3[2] & q_sh[15]}}, q_sh[15:0]} :
                                                   q_raw;

    // ------------------------------------------------------------------
    // ROB head
    // ------------------------------------------------------------------
    assign o_head_valid = hd_has & (e_tag[hd_i] == i_rob_head);
    wire   hd_load_ok  = hd_mis ? hd_bready : e_sent[hd_i];
    wire   hd_store_ok = hd_bready & hd_dready & (hd_mis | e_wrote[hd_i] | write_fire);
    assign o_head_ready = o_head_valid & (hd_st ? hd_store_ok : hd_load_ok);
    assign o_head_trap  = hd_bready & hd_mis;

    assign o_head_base       = e_bv[hd_i];
    assign o_head_data       = hd_dv;
    assign o_head_dmem_addr  = {hd_ea[31:2], 2'b00};
    assign o_head_dmem_mask  = hd_mis ? 4'b0000 : hd_mask;
    assign o_head_dmem_ren   = ~hd_st & ~hd_mis;
    assign o_head_dmem_wen   = hd_st & ~hd_mis;
    assign o_head_dmem_rdata = e_raw[hd_i];
    assign o_head_dmem_wdata = hd_wlane;

    // ------------------------------------------------------------------
    // Pointer updates. A commit only frees an entry cp is done with; if cp
    // still sat on it, it moves along with hd.
    // ------------------------------------------------------------------
    wire [3:0] hd_next = free ? hd + 4'd1 : hd;
    wire [3:0] cp_step = cp_adv ? cp + 4'd1 : cp;

    always @(posedge i_clk) begin
        if (i_rst) begin
            hd <= 4'd0;
            tl <= 4'd0;
            cp <= 4'd0;
        end else begin
            hd <= hd_next;
            if (alloc)
                tl <= tl + 4'd1;
            cp <= (free && (cp == hd)) ? hd_next : cp_step;
        end
    end

endmodule

`default_nettype wire
