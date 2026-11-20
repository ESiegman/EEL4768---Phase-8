`default_nettype none
// TEST ONLY stand-in for Bradly's rat.v, with the interface hart.v expects
// (see the comment block in hart.v). x1-x31 and f0-f31 each map to a ROB tag.
module rat (
    input  wire        i_clk, i_rst,
    input  wire [ 4:0] i_rs1_idx, i_rs2_idx, i_frs1_idx, i_frs2_idx, i_frs3_idx,
    output wire        o_rs1_busy, o_rs2_busy, o_frs1_busy, o_frs2_busy, o_frs3_busy,
    output wire [ 2:0] o_rs1_tag, o_rs2_tag, o_frs1_tag, o_frs2_tag, o_frs3_tag,
    input  wire        i_ren_valid,  input wire [4:0] i_ren_idx,  input wire [2:0] i_ren_tag,
    input  wire        i_fren_valid, input wire [4:0] i_fren_idx, input wire [2:0] i_fren_tag,
    input  wire        i_clr_valid,  input wire [4:0] i_clr_idx,  input wire [2:0] i_clr_tag,
    input  wire        i_fclr_valid, input wire [4:0] i_fclr_idx, input wire [2:0] i_fclr_tag
);
    reg [31:0] xb, fb;
    reg [2:0]  xt [0:31];
    reg [2:0]  ft [0:31];
    integer i;
    always @(posedge i_clk) begin
        if (i_rst) begin
            xb <= 32'd0; fb <= 32'd0;
            for (i = 0; i < 32; i = i + 1) begin xt[i] <= 3'd0; ft[i] <= 3'd0; end
        end else begin
            if (i_clr_valid && i_clr_idx != 5'd0 && xb[i_clr_idx] && xt[i_clr_idx] == i_clr_tag)
                xb[i_clr_idx] <= 1'b0;
            if (i_fclr_valid && fb[i_fclr_idx] && ft[i_fclr_idx] == i_fclr_tag)
                fb[i_fclr_idx] <= 1'b0;
            if (i_ren_valid && i_ren_idx != 5'd0) begin
                xb[i_ren_idx] <= 1'b1; xt[i_ren_idx] <= i_ren_tag;
            end
            if (i_fren_valid) begin
                fb[i_fren_idx] <= 1'b1; ft[i_fren_idx] <= i_fren_tag;
            end
        end
    end
    assign o_rs1_busy  = (i_rs1_idx != 5'd0) & xb[i_rs1_idx];
    assign o_rs2_busy  = (i_rs2_idx != 5'd0) & xb[i_rs2_idx];
    assign o_rs1_tag   = xt[i_rs1_idx];
    assign o_rs2_tag   = xt[i_rs2_idx];
    assign o_frs1_busy = fb[i_frs1_idx];
    assign o_frs2_busy = fb[i_frs2_idx];
    assign o_frs3_busy = fb[i_frs3_idx];
    assign o_frs1_tag  = ft[i_frs1_idx];
    assign o_frs2_tag  = ft[i_frs2_idx];
    assign o_frs3_tag  = ft[i_frs3_idx];
endmodule
`default_nettype wire
