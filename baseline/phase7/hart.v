`default_nettype none

module hart #(
    // After reset, the program counter (PC) starts here.
    parameter RESET_ADDR = 32'h00400000,
    // Kept for the skeleton's parameter list. The backend never reads a
    // register that is being written back (the RAT and the ROB cover it).
    parameter BYPASS_EN = 1,
    // Cache configuration, passed unchanged to the data cache inside the LSU.
    parameter EVICT_POLICY = 0,
    parameter NUM_WAYS     = 1,
    parameter CACHE_SIZE   = 16,
    parameter BLOCK_SIZE   = 128,
    parameter PREFETCH_EN  = 0,
    // Kept for the skeleton's parameter list so a testbench that sets it
    // still elaborates. 0 is the phase 5 write policy the cache already
    // implements (write-back on a hit, write-through with no allocate on a
    // miss), so nothing reads it.
    parameter WRITE_ALLOCATE = 0
) (
    // Global clock.
    input  wire        i_clk,
    // Synchronous active-high reset.
    input  wire        i_rst,
    // Instruction memory: combinational read, as in phase 4.
    output wire [31:0] o_imem_raddr,
    input  wire [31:0] i_imem_rdata,
    // Data memory is behind the data cache inside the LSU: one block per
    // transfer, against a main memory with a fixed delay. i_mem_ready is
    // unused (the phase 5 cache has no such input).
    input  wire                    i_mem_ready,
    input  wire                    i_mem_valid,
    input  wire [BLOCK_SIZE*8-1:0] i_mem_rd_data,
    output wire                    o_mem_rd,
    output wire                    o_mem_wr,
    output wire [31:0]             o_mem_rd_addr,
    output wire [31:0]             o_mem_wr_addr,
    output wire [BLOCK_SIZE*8-1:0] o_mem_wr_data,
    output wire [BLOCK_SIZE-1:0]   o_mem_wr_be,
    // The output `retire` interface is used to signal to the testbench that
    // the CPU has completed and retired an instruction. A single cycle
    // implementation will assert this every cycle; however, a pipelined
    // implementation that needs to stall (due to internal hazards or waiting
    // on memory accesses) will not assert the signal on cycles where the
    // instruction in the writeback stage is not retiring.
    //
    // Asserted when an instruction is being retired this cycle. If this is
    // not asserted, the other retire signals are ignored and may be left invalid.
    output wire        o_retire_valid,
    // The 32 bit instruction word of the instrution being retired. This
    // should be the unmodified instruction word fetched from instruction
    // memory.
    output wire [31:0] o_retire_inst,
    // Asserted if the instruction produced a trap, due to an illegal
    // instruction, unaligned data memory access, or unaligned instruction
    // address on a taken branch or jump.
    output wire        o_retire_trap,
    // Asserted if the instruction is an `ebreak` instruction used to halt the
    // processor. This is used for debugging and testing purposes to end
    // a program.
    output wire        o_retire_halt,
    // The first register address read by the instruction being retired. If
    // the instruction does not read from a register (like `lui`), this
    // should be 5'd0.
    output wire [ 4:0] o_retire_rs1_raddr,
    // The second register address read by the instruction being retired. If
    // the instruction does not read from a second register (like `addi`), this
    // should be 5'd0.
    output wire [ 4:0] o_retire_rs2_raddr,
    // The first source register data read from the register file (in the
    // decode stage) for the instruction being retired. If rs1 is 5'd0, this
    // should also be 32'd0.
    output wire [31:0] o_retire_rs1_rdata,
    // The second source register data read from the register file (in the
    // decode stage) for the instruction being retired. If rs2 is 5'd0, this
    // should also be 32'd0.
    output wire [31:0] o_retire_rs2_rdata,
    // The destination register address written by the instruction being
    // retired. If the instruction does not write to a register (like `sw`),
    // this should be 5'd0.
    output wire [ 4:0] o_retire_rd_waddr,
    // The destination register data written to the register file in the
    // writeback stage by this instruction. If rd is 5'd0, this field is
    // ignored and can be treated as a don't care.
    output wire [31:0] o_retire_rd_wdata,
    output wire [31:0] o_retire_dmem_addr,
    output wire [ 3:0] o_retire_dmem_mask,
    output wire        o_retire_dmem_ren,
    output wire        o_retire_dmem_wen,
    output wire [31:0] o_retire_dmem_rdata,
    output wire [31:0] o_retire_dmem_wdata,
    // The current program counter of the instruction being retired - i.e.
    // the instruction memory address that the instruction was fetched from.
    output wire [31:0] o_retire_pc,
    // the next program counter after the instruction is retired. For most
    // instructions, this is `o_retire_pc + 4`, but must be the branch or jump
    // target for *taken* branches and jumps.
    output wire [31:0] o_retire_next_pc,
    // Complete: one pulse per CDB broadcast (integer ALU, lui, auipc, jal,
    // jalr, branches, non-trapping loads, FP and CSR ops). Stores, ebreak,
    // illegal and misaligned instructions never broadcast. Completes happen
    // out of order; retires stay in order.
    output wire        o_complete_valid,
    output wire [ 2:0] o_complete_tag,
    output wire [ 4:0] o_complete_rd,
    output wire [31:0] o_complete_value,
    output wire [31:0] o_complete_pc,
    // F extension retire fields. The floating-point source registers read
    // by the instruction being retired (addresses are the instruction's rs1,
    // rs2 and rs3 fields) and their values as read in the decode stage; they
    // are only meaningful for instructions that read them.
    output wire [ 4:0] o_retire_frs1_raddr,
    output wire [31:0] o_retire_frs1_rdata,
    output wire [ 4:0] o_retire_frs2_raddr,
    output wire [31:0] o_retire_frs2_rdata,
    output wire [ 4:0] o_retire_frs3_raddr,
    output wire [31:0] o_retire_frs3_rdata,
    // Asserted when the instruction being retired writes floating-point
    // register `o_retire_frd_waddr` with `o_retire_frd_wdata`. (f0 is an
    // ordinary register, so an enable is needed.)
    output wire        o_retire_frd_wen,
    output wire [ 4:0] o_retire_frd_waddr,
    output wire [31:0] o_retire_frd_wdata,
    // The accrued floating-point exception flags (fflags) after the
    // instruction being retired.
    output wire [ 4:0] o_retire_fflags

`ifdef RISCV_FORMAL
    ,`RVFI_OUTPUTS,
`endif
);
  // -------------------------------------------------------------------------
  // Phase 7 out-of-order hart (non-speculative, single issue).
  //
  // Issue is in order, one instruction per cycle, straight from the
  // combinational instruction port. It stalls while the ROB, the target
  // reservation station or the LSU is full, while a branch or jump is in
  // flight (the design is non-speculative, nothing younger issues until it
  // resolves), and while an FP CSR instruction serializes. A resolved taken
  // branch or jump redirects the PC.
  //
  // Backend interface (tag width 3, ROB = 8 entries, tags are allocated
  // consecutively mod 8 from the ROB tail):
  //  * CDB bundle {valid, tag, value, fflags}: one shared broadcast, picked by
  //    cdb_arb among the ALU, FP unit 0, FP unit 1 and the LSU load result.
  //    Every requester holds {valid, tag, value} until its grant.
  //  * ROB: allocate at issue (tail), mark done when the CDB broadcasts the
  //    tag, commit from the head. The integer and FP register files and fcsr
  //    are written only at commit.
  //  * ebreak and illegal instructions are done at issue (no unit).
  //  * A trapped instruction writes nothing. A consumer that waits on a
  //    trapped producer is woken at the producer's commit with the old
  //    architectural register value (see "wake" below).
  //
  // rat.v (Bradly), combinational lookups, registered state:
  //   rat dut (.i_clk, .i_rst,
  //     .i_rs1_idx/.i_rs2_idx/.i_frs1_idx/.i_frs2_idx/.i_frs3_idx [4:0]
  //     .o_rs1_busy/.o_rs1_tag [2:0] ... (one pair per lookup)
  //     .i_ren_valid/.i_ren_idx/.i_ren_tag   rename an x register at issue
  //     .i_fren_valid/.i_fren_idx/.i_fren_tag rename an f register at issue
  //     .i_clr_valid/.i_clr_idx/.i_clr_tag   commit: clear x idx only if its
  //     .i_fclr_valid/.i_fclr_idx/.i_fclr_tag tag still matches (f likewise))
  //   x0 is never busy. A rename in the same cycle as a clear wins.
  // cdb_arb.v (Bradly), oldest wins, age = (tag - i_rob_head) mod 8:
  //   cdb_arb dut (.i_rob_head,
  //     .i_int_v/.i_int_tag/.i_int_value,
  //     .i_fp0_v/.i_fp0_tag/.i_fp0_value/.i_fp0_flags,
  //     .i_fp1_v/.i_fp1_tag/.i_fp1_value/.i_fp1_flags,
  //     .i_ld_v/.i_ld_tag/.i_ld_value,
  //     .o_int_grant/.o_fp0_grant/.o_fp1_grant/.o_ld_grant,
  //     .o_cdb_valid/.o_cdb_tag/.o_cdb_value/.o_cdb_fflags)
  //   Purely combinational from the requests, at most one grant, a grant
  //   only for a request.
  // -------------------------------------------------------------------------

  // ---------------- state ----------------
  reg  [31:0] pc;
  reg         halted;      // an ebreak has issued: nothing younger issues
  reg         br_pending;  // a branch or jump is in flight

  reg  [ 3:0] rob_head_p;  // 4-bit pointers, bit 3 is the wrap bit
  reg  [ 3:0] rob_tail_p;
  wire [ 2:0] rob_head = rob_head_p[2:0];
  wire [ 2:0] rob_tail = rob_tail_p[2:0];
  wire        rob_empty = (rob_head_p == rob_tail_p);
  wire        rob_full  = (rob_head_p[2:0] == rob_tail_p[2:0]) & (rob_head_p[3] != rob_tail_p[3]);

  reg  [ 7:0] rob_done;
  reg  [ 7:0] rob_trap;
  reg  [ 7:0] rob_halt;
  reg  [31:0] rob_pc    [0:7];
  reg  [31:0] rob_inst  [0:7];
  reg  [31:0] rob_npc   [0:7];
  reg  [31:0] rob_val   [0:7];
  reg  [ 4:0] rob_flags [0:7];
  reg  [31:0] rob_op0   [0:7];
  reg  [31:0] rob_op1   [0:7];
  reg  [31:0] rob_op2   [0:7];
  reg  [ 4:0] rob_rd    [0:7];   // integer destination, 0 if none
  reg  [ 4:0] rob_crd   [0:7];   // rd reported on the complete port
  reg  [ 5:0] rob_meta  [0:7];   // {uses_rs1, uses_rs2, frs1, frs2, frs3, frd}

  // ---------------- decode of the instruction at pc ----------------
  // A branch or jump that resolves taken this cycle fetches its target right
  // away, and that target may issue in the same cycle.
  wire        rs_redirect;
  wire [31:0] rs_resolve_next_pc;
  wire [31:0] fetch_pc = rs_redirect ? rs_resolve_next_pc : pc;
  wire [31:0] id_inst = i_imem_rdata;
  assign o_imem_raddr = fetch_pc;

  wire        dec_legal, dec_halt;
  wire [ 4:0] dec_rs1, dec_rs2, dec_rd, dec_rs3;
  wire [31:0] dec_immediate;
  wire        dec_branch, dec_jump, dec_dmem_ren, dec_dmem_wen;
  wire        dec_fpu, dec_frs1_en, dec_frs2_en, dec_frs3_en, dec_frd_en;
  wire        dec_uses_rs1, dec_uses_rs2;

  decoder decoder_inst (
      .i_inst           (id_inst),
      .o_legal          (dec_legal),
      .o_halt           (dec_halt),
      .o_rs1            (dec_rs1),
      .o_rs2            (dec_rs2),
      .o_rd             (dec_rd),
      .o_immediate      (dec_immediate),
      .o_op1_sel        (),
      .o_op2_sel        (),
      .o_alu_opsel      (),
      .o_alu_sub        (),
      .o_alu_unsigned   (),
      .o_alu_arith      (),
      .o_branch         (dec_branch),
      .o_jump           (dec_jump),
      .o_branch_equal   (),
      .o_branch_unsigned(),
      .o_branch_invert  (),
      .o_dmem_ren       (dec_dmem_ren),
      .o_dmem_wen       (dec_dmem_wen),
      .o_dmem_align     (),
      .o_dmem_memb      (),
      .o_dmem_memh      (),
      .o_dmem_memw      (),
      .o_dmem_memu      (),
      .o_rd_sel         (),
      .o_mext           (),
      .o_fpu            (dec_fpu),
      .o_frs1_en        (dec_frs1_en),
      .o_frs2_en        (dec_frs2_en),
      .o_frs3_en        (dec_frs3_en),
      .o_rs3            (dec_rs3),
      .o_frd_en         (dec_frd_en),
      .o_pc_sel         (),
      .o_uses_rs1       (dec_uses_rs1),
      .o_uses_rs2       (dec_uses_rs2)
  );

  wire is_ebreak   = dec_legal & dec_halt;
  wire rob_only    = is_ebreak | ~dec_legal;       // done at issue
  wire is_mem      = dec_legal & (dec_dmem_ren | dec_dmem_wen);
  wire is_fp       = dec_legal & dec_fpu;
  wire is_int      = ~rob_only & ~is_mem & ~is_fp;
  wire is_ctrl     = dec_legal & (dec_branch | dec_jump);

  wire [ 4:0] id_rs1  = dec_uses_rs1 ? dec_rs1 : 5'd0;
  wire [ 4:0] id_rs2  = dec_uses_rs2 ? dec_rs2 : 5'd0;
  wire        id_f1   = dec_legal & dec_frs1_en;
  wire        id_f2   = dec_legal & dec_frs2_en;
  wire        id_f3   = dec_legal & dec_frs3_en;
  wire        id_frd  = dec_legal & dec_frd_en;
  wire [ 4:0] id_rd   = dec_legal ? dec_rd : 5'd0;
  wire        id_u1   = dec_legal & dec_uses_rs1;
  wire        id_u2   = dec_legal & dec_uses_rs2;

  // ---------------- units ----------------
  wire        wake;                 // trapped producer commits: wake consumers
  wire [ 2:0] cdb_head_tag = rob_head;

  // RAT lookups
  wire        r1_busy, r2_busy, f1_busy, f2_busy, f3_busy;
  wire [ 2:0] r1_tag, r2_tag, f1_tag, f2_tag, f3_tag;

  // register file
  wire [31:0] rf_rs1_data, rf_rs2_data, rf_frs1_data, rf_frs2_data, rf_frs3_data;
  wire [ 4:0] rf_rd_waddr;
  wire [31:0] rf_rd_wdata;
  wire        rf_frd_wen;
  wire [ 4:0] rf_frd_waddr;
  wire [31:0] rf_frd_wdata;

  // Operand resolution at issue: a value from the register file when the
  // register is not renamed, from the ROB when its producer already
  // finished (not trapped), otherwise wait on the producer's tag. A same-
  // cycle CDB broadcast is caught by the units themselves.
  // Source n resolves to {wait, qtag, value}.
  wire dn_x1 = rob_done[r1_tag] & ~rob_trap[r1_tag];
  wire dn_x2 = rob_done[r2_tag] & ~rob_trap[r2_tag];
  wire dn_f1 = rob_done[f1_tag] & ~rob_trap[f1_tag];
  wire dn_f2 = rob_done[f2_tag] & ~rob_trap[f2_tag];
  wire dn_f3 = rob_done[f3_tag] & ~rob_trap[f3_tag];

  // x[rs1] / x[rs2] are looked up only when used (address 0 is never busy).
  wire [35:0] s_x1 = ~r1_busy ? {1'b0, 3'd0, rf_rs1_data} :
                     dn_x1    ? {1'b0, 3'd0, rob_val[r1_tag]} : {1'b1, r1_tag, 32'd0};
  wire [35:0] s_x2 = ~r2_busy ? {1'b0, 3'd0, rf_rs2_data} :
                     dn_x2    ? {1'b0, 3'd0, rob_val[r2_tag]} : {1'b1, r2_tag, 32'd0};
  wire [35:0] s_f1 = ~id_f1   ? 36'd0 :
                     ~f1_busy ? {1'b0, 3'd0, rf_frs1_data} :
                     dn_f1    ? {1'b0, 3'd0, rob_val[f1_tag]} : {1'b1, f1_tag, 32'd0};
  wire [35:0] s_f2 = ~id_f2   ? 36'd0 :
                     ~f2_busy ? {1'b0, 3'd0, rf_frs2_data} :
                     dn_f2    ? {1'b0, 3'd0, rob_val[f2_tag]} : {1'b1, f2_tag, 32'd0};
  wire [35:0] s_f3 = ~id_f3   ? 36'd0 :
                     ~f3_busy ? {1'b0, 3'd0, rf_frs3_data} :
                     dn_f3    ? {1'b0, 3'd0, rob_val[f3_tag]} : {1'b1, f3_tag, 32'd0};

  // Source 0 of the FP unit is x[rs1] for fmv.w.x, fcvt.s.w[u] and the CSR
  // register forms, f[rs1] otherwise.
  wire [35:0] fp_s0 = id_u1 ? s_x1 : s_f1;
  // fsw stores f[rs2], other stores x[rs2].
  wire [35:0] st_data = id_f2 ? s_f2 : s_x2;

  // ---------------- issue ----------------
  wire        rs_issue_ready, fp_issue_ready, lsu_full, fp_serializing;
  wire        unit_ok = rob_only | (is_mem ? ~lsu_full :
                                    is_fp  ? fp_issue_ready : rs_issue_ready);
  wire        rs_resolve_valid;
  // Issue resumes in the cycle the in-flight branch or jump resolves.
  wire        issue = ~i_rst & ~halted & ~(br_pending & ~rs_resolve_valid) & ~fp_serializing &
                      ~rob_full & ~wake & unit_ok;

  wire        issue_rs  = issue & is_int;
  wire        issue_fp  = issue & is_fp;
  wire        issue_lsu = issue & is_mem;

  // RAT and register file read addresses. During a wake cycle issue is held
  // and the read ports fetch the committing instruction's old destination.
  wire [ 4:0] head_rd;
  wire [ 4:0] head_frd;
  wire        head_frd_en;
  wire [ 4:0] rf_r1_addr  = wake ? head_rd  : id_rs1;
  wire [ 4:0] rf_f1_addr  = wake ? head_frd : dec_rs1;

  // ---------------- execution units ----------------
  wire        rs_dispatch_valid, rs_resolve_trap;
  wire [ 2:0] rs_dispatch_tag, rs_resolve_tag;
  wire        rs_result_valid, rs_result_trap;
  wire [ 2:0] rs_result_tag;
  wire [31:0] rs_result_value, rs_result_inst, rs_result_pc;
  wire [ 4:0] rs_result_rd;
  wire [63:0] rs_result_operands;

  wire [ 1:0] fp_result_valid, fp_result_trap, fp_grant;
  wire [ 5:0] fp_result_tag;
  wire [63:0] fp_result_value, fp_result_inst, fp_result_pc;
  wire [ 9:0] fp_result_flags;
  wire [191:0] fp_result_operands;
  wire        fp_dispatch_valid, fp_dispatch_lane;
  wire [ 2:0] fp_dispatch_tag;

  wire        lsu_result_valid;
  wire [ 2:0] lsu_result_tag;
  wire [31:0] lsu_result_value;

  wire        int_grant, ld_grant;
  wire        arb_valid;
  wire [ 2:0] arb_tag;
  wire [31:0] arb_value;
  wire [ 4:0] arb_flags;

  // cdb as seen by the units: the arbiter's broadcast, except that a trapped
  // result is not broadcast to consumers, and the wake overrides everything.
  wire        g_trap = (int_grant & rs_result_trap) |
                       (fp_grant[0] & fp_result_trap[0]) |
                       (fp_grant[1] & fp_result_trap[1]);
  wire        cdb_real = arb_valid & ~wake;               // ROB and complete
  wire [31:0] wake_value = head_frd_en ? rf_frs1_data : rf_rs1_data;
  wire        cdb_u_valid = wake | (cdb_real & ~g_trap);
  wire [ 2:0] cdb_u_tag   = wake ? rob_head : arb_tag;
  wire [31:0] cdb_u_value = wake ? wake_value : arb_value;

  rs int_rs (
      .i_clk(i_clk), .i_rst(i_rst),
      .i_rob_head(rob_head),
      .i_issue_valid(issue_rs), .o_issue_ready(rs_issue_ready),
      .i_issue_tag(rob_tail),
      .i_issue_inst(id_inst), .i_issue_pc(fetch_pc),
      .i_issue_wait({s_x2[35], s_x1[35]}),
      .i_issue_qtags({s_x2[34:32], s_x1[34:32]}),
      .i_issue_values({s_x2[31:0], s_x1[31:0]}),
      .i_cdb_valid(cdb_u_valid), .i_cdb_tag(cdb_u_tag), .i_cdb_value(cdb_u_value),
      .o_dispatch_valid(rs_dispatch_valid), .o_dispatch_tag(rs_dispatch_tag),
      .o_resolve_valid(rs_resolve_valid), .o_redirect(rs_redirect),
      .o_resolve_tag(rs_resolve_tag), .o_resolve_next_pc(rs_resolve_next_pc),
      .o_resolve_trap(rs_resolve_trap),
      .o_result_valid(rs_result_valid), .i_result_grant(int_grant & ~wake),
      .o_result_tag(rs_result_tag), .o_result_value(rs_result_value),
      .o_result_inst(rs_result_inst), .o_result_pc(rs_result_pc),
      .o_result_rd(rs_result_rd), .o_result_trap(rs_result_trap),
      .o_result_operands(rs_result_operands)
  );

  wire [ 7:0] architectural_fcsr;
  wire [ 7:0] next_fcsr;
  wire        commit;
  wire        head_trap;
  wire [31:0] head_inst, head_op0;
  wire [ 4:0] head_flags;

  fp_rs fp_rs_inst (
      .i_clk(i_clk), .i_rst(i_rst),
      .i_rob_head(rob_head), .i_rob_empty(rob_empty),
      .i_issue_valid(issue_fp), .o_issue_ready(fp_issue_ready),
      .i_issue_tag(rob_tail),
      .i_issue_inst(id_inst), .i_issue_pc(fetch_pc),
      .i_issue_wait({s_f3[35], s_f2[35], fp_s0[35]}),
      .i_issue_qtags({s_f3[34:32], s_f2[34:32], fp_s0[34:32]}),
      .i_issue_values({s_f3[31:0], s_f2[31:0], fp_s0[31:0]}),
      .i_cdb_valid(cdb_u_valid), .i_cdb_tag(cdb_u_tag), .i_cdb_value(cdb_u_value),
      .i_fcsr(architectural_fcsr),
      .i_commit_valid(commit), .i_commit_tag(rob_head),
      .o_serializing(fp_serializing),
      .o_dispatch_valid(fp_dispatch_valid), .o_dispatch_tag(fp_dispatch_tag),
      .o_dispatch_lane(fp_dispatch_lane),
      .o_result_valid(fp_result_valid),
      .i_result_grant(fp_grant & {2{~wake}}),
      .o_result_tag(fp_result_tag), .o_result_value(fp_result_value),
      .o_result_inst(fp_result_inst), .o_result_pc(fp_result_pc),
      .o_result_flags(fp_result_flags), .o_result_trap(fp_result_trap),
      .o_result_operands(fp_result_operands)
  );

  // LSU (owns the data cache). Its head ports answer for the ROB head.
  wire        lsu_head_valid, lsu_head_ready, lsu_head_trap;
  wire [31:0] lsu_head_base, lsu_head_data, lsu_head_addr, lsu_head_rdata, lsu_head_wdata;
  wire [ 3:0] lsu_head_mask;
  wire        lsu_head_ren, lsu_head_wen;

  lsu #(
      .EVICT_POLICY(EVICT_POLICY),
      .NUM_WAYS    (NUM_WAYS),
      .CACHE_SIZE  (CACHE_SIZE),
      .BLOCK_SIZE  (BLOCK_SIZE),
      .PREFETCH_EN (PREFETCH_EN)
  ) lsu_inst (
      .i_clk             (i_clk),
      .i_rst             (i_rst),
      .i_alloc_valid     (issue_lsu),
      .o_full            (lsu_full),
      .i_alloc_tag       (rob_tail),
      .i_alloc_store     (dec_dmem_wen),
      .i_alloc_funct3    (id_inst[14:12]),
      .i_alloc_imm       (dec_immediate),
      .i_alloc_base_wait (s_x1[35]),
      .i_alloc_base_qtag (s_x1[34:32]),
      .i_alloc_base_value(s_x1[31:0]),
      .i_alloc_data_wait (dec_dmem_wen ? st_data[35] : 1'b0),
      .i_alloc_data_qtag (st_data[34:32]),
      .i_alloc_data_value(dec_dmem_wen ? st_data[31:0] : 32'd0),
      .i_cdb_valid       (cdb_u_valid),
      .i_cdb_tag         (cdb_u_tag),
      .i_cdb_value       (cdb_u_value),
      .o_result_valid    (lsu_result_valid),
      .i_result_grant    (ld_grant & ~wake),
      .o_result_tag      (lsu_result_tag),
      .o_result_value    (lsu_result_value),
      .i_rob_head        (rob_head),
      .i_commit_valid    (commit),
      .o_head_valid      (lsu_head_valid),
      .o_head_ready      (lsu_head_ready),
      .o_head_trap       (lsu_head_trap),
      .o_head_base       (lsu_head_base),
      .o_head_data       (lsu_head_data),
      .o_head_dmem_addr  (lsu_head_addr),
      .o_head_dmem_mask  (lsu_head_mask),
      .o_head_dmem_ren   (lsu_head_ren),
      .o_head_dmem_wen   (lsu_head_wen),
      .o_head_dmem_rdata (lsu_head_rdata),
      .o_head_dmem_wdata (lsu_head_wdata),
      .o_mem_rd          (o_mem_rd),
      .o_mem_rd_addr     (o_mem_rd_addr),
      .i_mem_valid       (i_mem_valid),
      .i_mem_rd_data     (i_mem_rd_data),
      .o_mem_wr          (o_mem_wr),
      .o_mem_wr_addr     (o_mem_wr_addr),
      .o_mem_wr_data     (o_mem_wr_data),
      .o_mem_wr_be       (o_mem_wr_be)
  );

  cdb_arb #(.TAG_W(3)) cdb_arb_inst (
      .i_rob_head (rob_head),
      .i_int_v    (rs_result_valid),
      .i_int_tag  (rs_result_tag),
      .i_int_value(rs_result_value),
      .i_fp0_v    (fp_result_valid[0]),
      .i_fp0_tag  (fp_result_tag[2:0]),
      .i_fp0_value(fp_result_value[31:0]),
      .i_fp0_flags(fp_result_flags[4:0]),
      .i_fp1_v    (fp_result_valid[1]),
      .i_fp1_tag  (fp_result_tag[5:3]),
      .i_fp1_value(fp_result_value[63:32]),
      .i_fp1_flags(fp_result_flags[9:5]),
      .i_ld_v     (lsu_result_valid),
      .i_ld_tag   (lsu_result_tag),
      .i_ld_value (lsu_result_value),
      .o_int_grant(int_grant),
      .o_fp0_grant(fp_grant[0]),
      .o_fp1_grant(fp_grant[1]),
      .o_ld_grant (ld_grant),
      .o_cdb_valid(arb_valid),
      .o_cdb_tag  (arb_tag),
      .o_cdb_value(arb_value),
      .o_cdb_fflags(arb_flags)
  );

  rat rat_inst (
      .i_clk(i_clk), .i_rst(i_rst),
      .i_rs1_idx(id_rs1),  .o_rs1_busy(r1_busy),  .o_rs1_tag(r1_tag),
      .i_rs2_idx(id_rs2),  .o_rs2_busy(r2_busy),  .o_rs2_tag(r2_tag),
      .i_frs1_idx(dec_rs1), .o_frs1_busy(f1_busy), .o_frs1_tag(f1_tag),
      .i_frs2_idx(dec_rs2), .o_frs2_busy(f2_busy), .o_frs2_tag(f2_tag),
      .i_frs3_idx(dec_rs3), .o_frs3_busy(f3_busy), .o_frs3_tag(f3_tag),
      .i_ren_valid(issue & (id_rd != 5'd0)),
      .i_ren_idx(id_rd), .i_ren_tag(rob_tail),
      .i_fren_valid(issue & id_frd),
      .i_fren_idx(id_inst[11:7]), .i_fren_tag(rob_tail),
      .i_clr_valid(commit & (head_rd != 5'd0)),
      .i_clr_idx(head_rd), .i_clr_tag(rob_head),
      .i_fclr_valid(commit & head_frd_en),
      .i_fclr_idx(head_frd), .i_fclr_tag(rob_head)
  );

  rf rf_instance (
      .i_clk       (i_clk),
      .i_rst       (i_rst),
      .i_rs1_raddr (rf_r1_addr),
      .o_rs1_rdata (rf_rs1_data),
      .i_rs2_raddr (id_rs2),
      .o_rs2_rdata (rf_rs2_data),
      .i_rd_waddr  (rf_rd_waddr),
      .i_rd_wdata  (rf_rd_wdata),
      .i_frs1_raddr(rf_f1_addr),
      .o_frs1_rdata(rf_frs1_data),
      .i_frs2_raddr(dec_rs2),
      .o_frs2_rdata(rf_frs2_data),
      .i_frs3_raddr(dec_rs3),
      .o_frs3_rdata(rf_frs3_data),
      .i_frd_wen   (rf_frd_wen),
      .i_frd_waddr (rf_frd_waddr),
      .i_frd_wdata (rf_frd_wdata)
  );

  // ---------------- ROB: writes ----------------
  // Operands of the instruction that just broadcast (for retire).
  wire [95:0] g_opnd = int_grant   ? {32'd0, rs_result_operands} :
                       fp_grant[0] ? fp_result_operands[95:0] :
                       fp_grant[1] ? fp_result_operands[191:96] : 96'd0;

  wire [ 5:0] id_meta = {id_u1, id_u2, id_f1, id_f2, id_f3, id_frd};

  integer k;
  always @(posedge i_clk) begin
    if (i_rst) begin
      rob_head_p <= 4'd0;
      rob_tail_p <= 4'd0;
      rob_done   <= 8'd0;
      rob_trap   <= 8'd0;
      rob_halt   <= 8'd0;
      pc         <= RESET_ADDR;
      halted     <= 1'b0;
      br_pending <= 1'b0;
      for (k = 0; k < 8; k = k + 1) begin
        rob_pc[k]    <= 32'd0;
        rob_inst[k]  <= 32'd0;
        rob_npc[k]   <= 32'd0;
        rob_val[k]   <= 32'd0;
        rob_flags[k] <= 5'd0;
        rob_op0[k]   <= 32'd0;
        rob_op1[k]   <= 32'd0;
        rob_op2[k]   <= 32'd0;
        rob_rd[k]    <= 5'd0;
        rob_crd[k]   <= 5'd0;
        rob_meta[k]  <= 6'd0;
      end
    end else begin
      // CDB: finished result for a tag.
      if (cdb_real) begin
        rob_done[arb_tag]  <= 1'b1;
        rob_val[arb_tag]   <= arb_value;
        rob_flags[arb_tag] <= arb_flags;
        rob_trap[arb_tag]  <= g_trap;
        rob_op0[arb_tag]   <= g_opnd[31:0];
        rob_op1[arb_tag]   <= g_opnd[63:32];
        rob_op2[arb_tag]   <= g_opnd[95:64];
      end
      // Branch / jump resolved at dispatch: its next pc.
      if (rs_resolve_valid) begin
        rob_npc[rs_resolve_tag] <= rs_resolve_next_pc;
        br_pending <= 1'b0;
      end
      // Issue allocates the tail entry.
      if (issue) begin
        rob_pc[rob_tail]    <= fetch_pc;
        rob_inst[rob_tail]  <= id_inst;
        rob_npc[rob_tail]   <= fetch_pc + 32'd4;
        rob_val[rob_tail]   <= 32'd0;
        rob_flags[rob_tail] <= 5'd0;
        rob_op0[rob_tail]   <= 32'd0;
        rob_op1[rob_tail]   <= 32'd0;
        rob_op2[rob_tail]   <= 32'd0;
        rob_rd[rob_tail]    <= id_rd;
        rob_crd[rob_tail]   <= id_frd ? id_inst[11:7] : id_rd;
        rob_meta[rob_tail]  <= id_meta;
        rob_done[rob_tail]  <= rob_only;
        rob_trap[rob_tail]  <= ~dec_legal;
        rob_halt[rob_tail]  <= is_ebreak;
        rob_tail_p <= rob_tail_p + 4'd1;
        if (is_ebreak) halted <= 1'b1;
        if (is_ctrl)   br_pending <= 1'b1;
      end
      if (issue)            pc <= fetch_pc + 32'd4;
      else if (rs_redirect) pc <= rs_resolve_next_pc;
      if (commit) rob_head_p <= rob_head_p + 4'd1;
    end
  end

  // ---------------- ROB: commit ----------------
  // The head view. An entry commits no earlier than the cycle after its
  // complete (the testbench requires the complete to come first).
  assign head_rd       = rob_rd[rob_head];
  wire [ 5:0] head_meta = rob_meta[rob_head];
  assign head_frd_en = head_meta[0];
  assign head_frd      = rob_inst[rob_head][11:7];
  assign head_inst     = rob_inst[rob_head];
  wire [31:0] head_val = rob_val[rob_head];
  assign head_flags    = rob_flags[rob_head];
  assign head_op0      = rob_op0[rob_head];
  wire [31:0] head_op1 = rob_op1[rob_head];
  wire [31:0] head_op2 = rob_op2[rob_head];
  assign head_trap     = lsu_head_valid ? lsu_head_trap : rob_trap[rob_head];

  assign commit = ~i_rst & ~rob_empty &
                  (lsu_head_valid ? lsu_head_ready : rob_done[rob_head]);
  assign wake   = commit & head_trap & ((head_rd != 5'd0) | head_frd_en);

  wire        head_u1 = head_meta[5];
  wire        head_u2 = head_meta[4];

  // Wake: the old architectural value of the trapped producer's register is
  // read on the issue read ports (issue is held in this cycle).

  // fcsr: flags accumulate and CSR instructions write in program order.
  fcsr architectural_fp_state (
      .i_clk(i_clk), .i_rst(i_rst),
      .i_commit_valid(commit), .i_commit_trap(head_trap),
      .i_commit_inst(head_inst), .i_commit_xrs1(head_op0),
      .i_commit_flags(head_flags),
      .o_fcsr(architectural_fcsr), .o_next_fcsr(next_fcsr)
  );

  assign rf_rd_waddr  = (commit & ~head_trap) ? head_rd : 5'd0;
  assign rf_rd_wdata  = head_val;
  assign rf_frd_wen   = commit & ~head_trap & head_frd_en;
  assign rf_frd_waddr = head_frd;
  assign rf_frd_wdata = head_val;

  // ---------------- Retire ----------------
  assign o_retire_valid      = commit;
  assign o_retire_inst       = head_inst;
  assign o_retire_trap       = head_trap;
  assign o_retire_halt       = rob_halt[rob_head];
  assign o_retire_rs1_raddr  = head_u1 ? head_inst[19:15] : 5'd0;
  assign o_retire_rs1_rdata  = lsu_head_valid ? lsu_head_base : (head_u1 ? head_op0 : 32'd0);
  assign o_retire_rs2_raddr  = head_u2 ? head_inst[24:20] : 5'd0;
  assign o_retire_rs2_rdata  = head_u2 ? (lsu_head_valid ? lsu_head_data : head_op1) : 32'd0;
  assign o_retire_rd_waddr   = head_trap ? 5'd0 : head_rd;
  assign o_retire_rd_wdata   = head_val;
  assign o_retire_dmem_addr  = lsu_head_valid ? lsu_head_addr  : 32'd0;
  assign o_retire_dmem_mask  = lsu_head_valid ? lsu_head_mask  : 4'd0;
  assign o_retire_dmem_ren   = lsu_head_valid & lsu_head_ren;
  assign o_retire_dmem_wen   = lsu_head_valid & lsu_head_wen;
  assign o_retire_dmem_rdata = lsu_head_valid ? lsu_head_rdata : 32'd0;
  assign o_retire_dmem_wdata = lsu_head_valid ? lsu_head_wdata : 32'd0;
  assign o_retire_pc         = rob_pc[rob_head];
  assign o_retire_next_pc    = rob_npc[rob_head];
  assign o_retire_frs1_raddr = head_meta[3] ? head_inst[19:15] : 5'd0;
  assign o_retire_frs1_rdata = head_meta[3] ? head_op0 : 32'd0;
  assign o_retire_frs2_raddr = head_meta[2] ? head_inst[24:20] : 5'd0;
  assign o_retire_frs2_rdata = head_meta[2] ? (lsu_head_valid ? lsu_head_data : head_op1) : 32'd0;
  assign o_retire_frs3_raddr = head_meta[1] ? head_inst[31:27] : 5'd0;
  assign o_retire_frs3_rdata = head_meta[1] ? head_op2 : 32'd0;
  assign o_retire_frd_wen    = head_frd_en & ~head_trap;
  assign o_retire_frd_waddr  = (head_frd_en & ~head_trap) ? head_frd : 5'd0;
  assign o_retire_frd_wdata  = head_val;
  assign o_retire_fflags     = next_fcsr[4:0];

  // ---------------- Complete ----------------
  assign o_complete_valid = cdb_real;
  assign o_complete_tag   = arb_tag;
  assign o_complete_rd    = rob_crd[arb_tag];
  assign o_complete_value = arb_value;
  assign o_complete_pc    = rob_pc[arb_tag];

endmodule

`default_nettype wire
