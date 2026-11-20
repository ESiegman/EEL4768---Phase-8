`default_nettype none
module rat #(
    parameter TAG_W = 3 // ROB tag width (8-entry ROB)
) (
    input  wire             i_clk,
    input  wire             i_rst,

    // Issue-time lookups: rs1/rs2 read the integer map, frs1-frs3 the FP map.
    input  wire [4:0] i_rs1_idx,
    output wire o_rs1_busy,
    output wire [TAG_W-1:0] o_rs1_tag,
    input  wire [4:0] i_rs2_idx,
    output wire o_rs2_busy,
    output wire [TAG_W-1:0] o_rs2_tag,
    input  wire [4:0] i_frs1_idx,
    output wire o_frs1_busy,
    output wire [TAG_W-1:0] o_frs1_tag,
    input  wire [4:0] i_frs2_idx,
    output wire o_frs2_busy,
    output wire [TAG_W-1:0] o_frs2_tag,
    input  wire [4:0] i_frs3_idx,
    output wire o_frs3_busy,
    output wire [TAG_W-1:0] o_frs3_tag,

    // Rename at issue: map rd (or frd) to the issuing instruction's ROB tag.
    input  wire i_ren_valid,
    input  wire [4:0] i_ren_idx,
    input  wire [TAG_W-1:0] i_ren_tag,
    input  wire i_fren_valid,
    input  wire [4:0] i_fren_idx,
    input  wire [TAG_W-1:0] i_fren_tag,

    // Clear at commit: free rd (or frd) if it still maps to the committing tag.
    input  wire i_clr_valid,
    input  wire [4:0] i_clr_idx,
    input  wire [TAG_W-1:0] i_clr_tag,
    input  wire i_fclr_valid,
    input  wire [4:0] i_fclr_idx,
    input  wire [TAG_W-1:0] i_fclr_tag
);

    // Flattened copies of both tables so the lookups below can index them.
    // Register n's busy bit is x_busy[n]; its tag is x_tag[TAG_W*n +: TAG_W].
    wire [31:0] x_busy;
    wire [31:0] f_busy;
    wire [32*TAG_W-1:0] x_tag;
    wire [32*TAG_W-1:0] f_tag;

    genvar n, b;
    generate
        // One busy bit + one tag register per architectural register, built
        // with a generate loop (procedural loops are not allowed).
        for (n = 0; n < 32; n = n + 1) begin : g_map
            localparam [4:0] IDX = n;

            // ---------------- integer map ----------------
            if (n == 0) begin : g_x0
                // x0 has no storage: always free, renames/clears to it do nothing.
                assign x_busy[0] = 1'b0;
                assign x_tag[TAG_W-1:0]  = {TAG_W{1'b0}};
            end else begin : g_x
                reg busy;
                reg [TAG_W-1:0] tag;

                // ren: this register is the one being renamed this cycle.
                // clr: this register is committing AND still holds that tag.
                wire ren = i_ren_valid & (i_ren_idx == IDX);
                wire clr = i_clr_valid & (i_clr_idx == IDX) & (tag == i_clr_tag);

                // Reset first, then rename, then clear: checking ren before
                // clr is what makes a same-cycle rename win.
                always @(posedge i_clk) begin
                    if (i_rst) begin
                        busy <= 1'b0;
                        tag  <= {TAG_W{1'b0}};
                    end else if (ren) begin
                        busy <= 1'b1;
                        tag  <= i_ren_tag;
                    end else if (clr) begin
                        busy <= 1'b0;   // tag kept; it is ignored once free
                    end
                end

                assign x_busy[n] = busy;
                assign x_tag[TAG_W*n +: TAG_W] = tag;
            end

            // ---------------- FP map ----------------
            // Same logic as the integer entry, but f0 is an ordinary register
            // so all 32 entries have storage. (`if (1)` just names the block.)
            if (1) begin : g_f
                reg busy;
                reg [TAG_W-1:0] tag;

                wire ren = i_fren_valid & (i_fren_idx == IDX);
                wire clr = i_fclr_valid & (i_fclr_idx == IDX) & (tag == i_fclr_tag);

                always @(posedge i_clk) begin
                    if (i_rst) begin
                        busy <= 1'b0;
                        tag  <= {TAG_W{1'b0}};
                    end else if (ren) begin
                        busy <= 1'b1;
                        tag  <= i_fren_tag;
                    end else if (clr) begin
                        busy <= 1'b0;
                    end
                end

                assign f_busy[n] = busy;
                assign f_tag[TAG_W*n +: TAG_W] = tag;
            end
        end

        // Tag lookups. Selecting a TAG_W-wide slice by a variable index would
        // need idx*TAG_W (a multiply, not allowed), so instead bit b of every
        // register's tag is gathered into a 32-bit "plane" and each lookup is
        // a plain 32:1 bit-select per tag bit.
        for (b = 0; b < TAG_W; b = b + 1) begin : g_plane
            wire [31:0] xp;
            wire [31:0] fp;
            for (n = 0; n < 32; n = n + 1) begin : g_bit
                assign xp[n] = x_tag[TAG_W*n + b];
                assign fp[n] = f_tag[TAG_W*n + b];
            end
            assign o_rs1_tag[b]  = xp[i_rs1_idx];
            assign o_rs2_tag[b]  = xp[i_rs2_idx];
            assign o_frs1_tag[b] = fp[i_frs1_idx];
            assign o_frs2_tag[b] = fp[i_frs2_idx];
            assign o_frs3_tag[b] = fp[i_frs3_idx];
        end
    endgenerate

    // Busy lookups: one bit per register, so a direct bit-select.
    assign o_rs1_busy  = x_busy[i_rs1_idx];
    assign o_rs2_busy  = x_busy[i_rs2_idx];
    assign o_frs1_busy = f_busy[i_frs1_idx];
    assign o_frs2_busy = f_busy[i_frs2_idx];
    assign o_frs3_busy = f_busy[i_frs3_idx];

endmodule

`default_nettype wire
