`default_nettype none

// Four-entry integer RS and shared ALU. Result/metadata registers are held
// until the CDB arbiter grants them. The resolver fires at dispatch, even
// for a not-taken branch, independently of the later CDB grant.
module rs (
    input wire i_clk, i_rst,
    input wire [2:0] i_rob_head,
    input wire i_issue_valid,
    output wire o_issue_ready,
    input wire [2:0] i_issue_tag,
    input wire [31:0] i_issue_inst, i_issue_pc,
    input wire [1:0] i_issue_wait,
    input wire [5:0] i_issue_qtags,
    input wire [63:0] i_issue_values,
    input wire i_cdb_valid,
    input wire [2:0] i_cdb_tag,
    input wire [31:0] i_cdb_value,
    output wire o_dispatch_valid,
    output wire [2:0] o_dispatch_tag,
    output wire o_resolve_valid, o_redirect,
    output wire [2:0] o_resolve_tag,
    output wire [31:0] o_resolve_next_pc,
    output wire o_resolve_trap,
    output reg o_result_valid,
    input wire i_result_grant,
    output reg [2:0] o_result_tag,
    output reg [31:0] o_result_value, o_result_inst, o_result_pc,
    output reg [4:0] o_result_rd,
    output reg o_result_trap,
    output reg [63:0] o_result_operands
);
    wire ready;
    wire [1:0] slot;
    wire [2:0] tag;
    wire [66:0] payload;
    wire [95:0] sources;
    wire remove;
    reg running;
    reg [1:0] running_slot;
    reg [66:0] running_payload;
    reg [63:0] running_sources;
    wire [66:0] exec_payload = running ? running_payload : payload;
    wire [63:0] exec_sources = running ? running_sources : sources[63:0];
    wire [31:0] inst = exec_payload[31:0];
    wire [31:0] pc = exec_payload[63:32];
    wire [2:0] exec_tag = exec_payload[66:64];
    wire room = ~o_result_valid | i_result_grant;
    wire dispatch = ~i_rst & ~running & ready & room;

    reservation_station queue (
        .i_clk(i_clk), .i_rst(i_rst), .i_rob_head(i_rob_head),
        .i_issue_valid(i_issue_valid), .o_issue_ready(o_issue_ready),
        .i_issue_tag(i_issue_tag),
        .i_issue_payload({i_issue_tag, i_issue_pc, i_issue_inst}),
        .i_issue_wait({1'b0, i_issue_wait}),
        .i_issue_qtags({3'd0, i_issue_qtags}),
        .i_issue_values({32'd0, i_issue_values}),
        .i_cdb_valid(i_cdb_valid), .i_cdb_tag(i_cdb_tag), .i_cdb_value(i_cdb_value),
        .o_ready_valid(ready), .o_ready_slot(slot), .o_ready_tag(tag),
        .o_ready_payload(payload), .o_ready_values(sources),
        .i_remove_valid(remove), .i_remove_slot(running ? running_slot : slot),
        .o_empty()
    );

    wire [31:0] imm;
    wire op1_sel, op2_sel, sub, unsigned_op, arith, mext;
    wire [2:0] opsel;
    wire branch, jump, branch_eq, branch_inv, pc_sel;
    wire [4:0] rd, rd_sel;
    decoder decode (
        .i_inst(inst), .o_legal(), .o_halt(), .o_rs1(), .o_rs2(),
        .o_immediate(imm), .o_rd(rd), .o_rd_sel(rd_sel),
        .o_op1_sel(op1_sel), .o_op2_sel(op2_sel), .o_alu_opsel(opsel),
        .o_alu_sub(sub), .o_alu_unsigned(unsigned_op), .o_alu_arith(arith),
        .o_mext(mext), .o_branch(branch), .o_jump(jump),
        .o_branch_equal(branch_eq), .o_branch_unsigned(),
        .o_branch_invert(branch_inv), .o_pc_sel(pc_sel),
        .o_dmem_ren(), .o_dmem_wen(), .o_dmem_align(),
        .o_dmem_memb(), .o_dmem_memh(), .o_dmem_memw(), .o_dmem_memu(),
        .o_fpu(), .o_frs1_en(), .o_frs2_en(), .o_frs3_en(),
        .o_rs3(), .o_frd_en(), .o_uses_rs1(), .o_uses_rs2()
    );
    wire [31:0] a = exec_sources[31:0];
    wire [31:0] b = exec_sources[63:32];
    wire [31:0] result;
    wire busy, equal, less;
    wire finish = ~i_rst & room & ((running & ~busy) | (dispatch & ~mext));
    alu execute (
        .i_clk(i_clk), .i_rst(i_rst), .i_opsel(opsel), .i_sub(sub),
        .i_unsigned(unsigned_op), .i_arith(arith),
        .i_mext(mext & (running | dispatch)), .i_advance(finish),
        .i_op1(op1_sel ? pc : a), .i_op2(op2_sel ? imm : b),
        .o_result(result), .o_eq(equal), .o_slt(less), .o_busy(busy)
    );
    // For branches the decoder selects rs1/rs2 for the shared ALU and its
    // signed/unsigned comparator. JALR clears bit zero before IALIGN=32.
    wire taken = jump | (branch & ((branch_eq ? equal : less) ^ branch_inv));
    wire [31:0] target = pc_sel ? {result[31:1], 1'b0} : pc + imm;
    wire target_trap = taken & (|target[1:0]);
    assign o_dispatch_valid = dispatch;
    assign o_dispatch_tag = tag;
    assign o_resolve_valid = dispatch & (branch | jump);
    assign o_resolve_tag = tag;
    assign o_resolve_trap = o_resolve_valid & target_trap;
    assign o_redirect = o_resolve_valid & taken & ~target_trap;
    assign o_resolve_next_pc = (taken & ~target_trap) ? target : pc + 32'd4;
    assign remove = finish;

    always @(posedge i_clk) begin
        if (i_rst) begin
            running <= 1'b0;
            running_slot <= 2'd0;
            running_payload <= 67'd0;
            running_sources <= 64'd0;
            o_result_valid <= 1'b0;
            o_result_tag <= 3'd0;
            o_result_value <= 32'd0;
            o_result_inst <= 32'd0;
            o_result_pc <= 32'd0;
            o_result_rd <= 5'd0;
            o_result_trap <= 1'b0;
            o_result_operands <= 64'd0;
        end else begin
            if (i_result_grant) o_result_valid <= 1'b0;
            if (dispatch & mext) begin
                running <= 1'b1;
                running_slot <= slot;
                running_payload <= payload;
                running_sources <= sources[63:0];
            end
            if (finish) begin
                running <= 1'b0;
                o_result_valid <= 1'b1;
                o_result_tag <= exec_tag;
                o_result_value <= branch ? 32'd0 : rd_sel[2] ? pc + 32'd4 :
                                  rd_sel[1] ? imm : result;
                o_result_inst <= inst;
                o_result_pc <= pc;
                o_result_rd <= rd;
                o_result_trap <= (branch | jump) & target_trap;
                o_result_operands <= exec_sources;
            end
        end
    end
endmodule

`default_nettype wire
