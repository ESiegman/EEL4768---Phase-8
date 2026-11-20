`default_nettype none

// The single architectural FP CSR. Drive only from the ROB commit port.
// CDB flags belong to an individual instruction and are accrued here in
// program order. A trapped instruction has no CSR or flag side effects.
module fcsr (
    input wire i_clk, i_rst,
    input wire i_commit_valid, i_commit_trap,
    input wire [31:0] i_commit_inst, i_commit_xrs1,
    input wire [4:0] i_commit_flags,
    output reg [7:0] o_fcsr,
    output wire [7:0] o_next_fcsr
);
    wire [2:0] funct3 = i_commit_inst[14:12];
    wire [4:0] rs1 = i_commit_inst[19:15];
    wire [11:0] addr = i_commit_inst[31:20];
    wire csr = (i_commit_inst[6:0] == 7'h73) & (|funct3[1:0]) &
               (addr >= 12'd1) & (addr <= 12'd3);
    wire [7:0] old = (addr == 12'd1) ? {3'd0, o_fcsr[4:0]} :
                     (addr == 12'd2) ? {5'd0, o_fcsr[7:5]} : o_fcsr;
    wire [7:0] src = funct3[2] ? {3'd0, rs1} : i_commit_xrs1[7:0];
    wire [7:0] value = (funct3[1:0] == 2'd1) ? src :
                       (funct3[1:0] == 2'd2) ? old | src : old & ~src;
    wire write_csr = csr & ((funct3[1:0] == 2'd1) | (rs1 != 5'd0));
    wire [4:0] flags = (write_csr & (addr != 12'd2)) ? value[4:0] :
                       o_fcsr[4:0] | i_commit_flags;
    wire [2:0] frm = (write_csr & (addr != 12'd1)) ?
                     ((addr == 12'd2) ? value[2:0] : value[7:5]) : o_fcsr[7:5];
    assign o_next_fcsr = (i_commit_valid & ~i_commit_trap) ? {frm, flags} : o_fcsr;
    always @(posedge i_clk) begin
        if (i_rst) o_fcsr <= 8'd0;
        else o_fcsr <= o_next_fcsr;
    end
endmodule

`default_nettype wire
