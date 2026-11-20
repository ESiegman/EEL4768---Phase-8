`default_nettype none
// TEST ONLY stand-in for Bradly's cdb_arb.v, with the interface hart.v
// expects. One grant per cycle among the ALU, FP0, FP1 and load requests;
// the oldest wins, age = (tag - i_rob_head) mod 8.
module cdb_arb #(parameter TAG_W = 3) (
    input  wire [TAG_W-1:0] i_rob_head,
    input  wire i_int_v, input wire [TAG_W-1:0] i_int_tag, input wire [31:0] i_int_value,
    input  wire i_fp0_v, input wire [TAG_W-1:0] i_fp0_tag, input wire [31:0] i_fp0_value, input wire [4:0] i_fp0_flags,
    input  wire i_fp1_v, input wire [TAG_W-1:0] i_fp1_tag, input wire [31:0] i_fp1_value, input wire [4:0] i_fp1_flags,
    input  wire i_ld_v,  input wire [TAG_W-1:0] i_ld_tag,  input wire [31:0] i_ld_value,
    output wire o_int_grant, o_fp0_grant, o_fp1_grant, o_ld_grant,
    output wire o_cdb_valid,
    output wire [TAG_W-1:0] o_cdb_tag,
    output wire [31:0] o_cdb_value,
    output wire [4:0] o_cdb_fflags
);
    wire [TAG_W-1:0] a0 = i_int_tag - i_rob_head;
    wire [TAG_W-1:0] a1 = i_fp0_tag - i_rob_head;
    wire [TAG_W-1:0] a2 = i_fp1_tag - i_rob_head;
    wire [TAG_W-1:0] a3 = i_ld_tag  - i_rob_head;
    assign o_int_grant = i_int_v & (~i_fp0_v | a0 < a1) & (~i_fp1_v | a0 < a2) & (~i_ld_v | a0 < a3);
    assign o_fp0_grant = i_fp0_v & ~o_int_grant & (~i_fp1_v | a1 < a2) & (~i_ld_v | a1 < a3);
    assign o_fp1_grant = i_fp1_v & ~o_int_grant & ~o_fp0_grant & (~i_ld_v | a2 < a3);
    assign o_ld_grant  = i_ld_v & ~o_int_grant & ~o_fp0_grant & ~o_fp1_grant;
    assign o_cdb_valid = o_int_grant | o_fp0_grant | o_fp1_grant | o_ld_grant;
    assign o_cdb_tag   = o_int_grant ? i_int_tag : o_fp0_grant ? i_fp0_tag :
                         o_fp1_grant ? i_fp1_tag : i_ld_tag;
    assign o_cdb_value = o_int_grant ? i_int_value : o_fp0_grant ? i_fp0_value :
                         o_fp1_grant ? i_fp1_value : i_ld_value;
    assign o_cdb_fflags = o_fp0_grant ? i_fp0_flags : o_fp1_grant ? i_fp1_flags : 5'd0;
endmodule
`default_nettype wire
