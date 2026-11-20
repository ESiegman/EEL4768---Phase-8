`default_nettype none
module cdb_arb #(
    parameter TAG_W = 3 // ROB tag width (8-entry ROB)
) (
    // ROB head tag: the reference point for measuring each request's age.
    input wire [TAG_W-1:0] i_rob_head,

    // Requests: {valid, ROB tag, result value} from each producer (the FP
    // units also send their exception flags).

    input wire i_int_v,
    input wire [TAG_W-1:0] i_int_tag,
    input wire [31:0] i_int_value,

    input wire i_fp0_v,
    input wire [TAG_W-1:0] i_fp0_tag,
    input wire [31:0] i_fp0_value,
    input wire [4:0] i_fp0_flags,

    input wire i_fp1_v,
    input wire [TAG_W-1:0] i_fp1_tag,
    input wire [31:0] i_fp1_value,
    input wire [4:0] i_fp1_flags,

    input wire i_ld_v,
    input wire [TAG_W-1:0] i_ld_tag,
    input wire [31:0] i_ld_value,

    // Grants: one-hot, tells the winning producer to drop its request.
    output wire o_int_grant,
    output wire o_fp0_grant,
    output wire o_fp1_grant,
    output wire o_ld_grant,

    // The broadcast seen by the ROB, reservation stations and LSU.
    output wire o_cdb_valid,
    output wire [TAG_W-1:0] o_cdb_tag,
    output wire [31:0] o_cdb_value,
    output wire [4:0] o_cdb_fflags
);

    // Ages relative to the ROB head. TAG_W-bit subtraction wraps, giving mod.
    wire [TAG_W-1:0] age_int = i_int_tag - i_rob_head;
    wire [TAG_W-1:0] age_fp0 = i_fp0_tag - i_rob_head;
    wire [TAG_W-1:0] age_fp1 = i_fp1_tag - i_rob_head;
    wire [TAG_W-1:0] age_ld = i_ld_tag - i_rob_head;

    // Pairwise "older than" (strict order, ties go to the lower-numbered
    // requester: int=0, fp0=1, fp1=2, ld=3). a_over_b means a beats b, so
    // "b beats a" is just ~a_over_b.
    wire int_over_fp0 = (age_int <= age_fp0);
    wire int_over_fp1 = (age_int <= age_fp1);
    wire int_over_ld = (age_int <= age_ld);
    wire fp0_over_fp1 = (age_fp0 <= age_fp1);
    wire fp0_over_ld = (age_fp0 <= age_ld);
    wire fp1_over_ld = (age_fp1 <= age_ld);

    // A requester wins when it beats every other valid requester.
    assign o_int_grant = i_int_v & (~i_fp0_v | int_over_fp0) & (~i_fp1_v | int_over_fp1) & (~i_ld_v | int_over_ld);

    assign o_fp0_grant = i_fp0_v & (~i_int_v | ~int_over_fp0) & (~i_fp1_v | fp0_over_fp1) & (~i_ld_v | fp0_over_ld);

    assign o_fp1_grant = i_fp1_v & (~i_int_v | ~int_over_fp1) & (~i_fp0_v | ~fp0_over_fp1) & (~i_ld_v | fp1_over_ld);

    assign o_ld_grant = i_ld_v & (~i_int_v | ~int_over_ld) & (~i_fp0_v | ~fp0_over_ld) & (~i_fp1_v | ~fp1_over_ld);

    // The grant is one-hot, so the bus is a plain AND-OR mux. With no grant
    // every field reads as zero.
    assign o_cdb_valid = o_int_grant | o_fp0_grant | o_fp1_grant | o_ld_grant;

    assign o_cdb_tag = ({TAG_W{o_int_grant}} & i_int_tag) | ({TAG_W{o_fp0_grant}} & i_fp0_tag) | ({TAG_W{o_fp1_grant}} & i_fp1_tag) | ({TAG_W{o_ld_grant }} & i_ld_tag);

    assign o_cdb_value = ({32{o_int_grant}} & i_int_value) | ({32{o_fp0_grant}} & i_fp0_value) | ({32{o_fp1_grant}} & i_fp1_value) | ({32{o_ld_grant }} & i_ld_value);

    // Only the FP units raise exception flags.
    assign o_cdb_fflags = ({5{o_fp0_grant}} & i_fp0_flags) | ({5{o_fp1_grant}} & i_fp1_flags);

endmodule

`default_nettype wire
