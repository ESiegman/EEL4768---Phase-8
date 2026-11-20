`default_nettype none

// One independent FP execution lane. Inputs and fcsr are captured at
// dispatch; the registered CDB request and all metadata remain stable until
// granted. There is no architectural state in the FPU itself.
module fp_exec (
    input wire i_clk, i_rst,
    input wire i_dispatch_valid,
    output wire o_dispatch_ready,
    input wire [2:0] i_dispatch_tag,
    input wire [31:0] i_dispatch_inst, i_dispatch_pc,
    input wire [95:0] i_dispatch_operands,
    input wire [7:0] i_fcsr,
    output reg o_result_valid,
    input wire i_result_grant,
    output reg [2:0] o_result_tag,
    output reg [31:0] o_result_value, o_result_inst, o_result_pc,
    output reg [4:0] o_result_flags,
    output reg o_result_trap,
    output reg [95:0] o_result_operands,
    output wire o_idle
);
    reg active;
    reg [2:0] tag;
    reg [31:0] inst, pc;
    reg [95:0] operands;
    reg [7:0] csr;
    wire [31:0] fp_result, int_result;
    wire [4:0] flags;
    wire busy, trap;
    // OP-FP conversions/comparisons/moves to x and every CSR return x data.
    wire integer_result = (inst[6:0] == 7'h73) |
                          ((inst[6:0] == 7'h53) &
                           ((inst[31:25] == 7'h50) |
                            (inst[31:25] == 7'h60) |
                            (inst[31:25] == 7'h70)));
    wire finish = ~i_rst & active & ~busy;
    assign o_idle = ~active & ~o_result_valid;
    assign o_dispatch_ready = ~i_rst & ~active & (~o_result_valid | i_result_grant);
    fpu execute (
        .i_clk(i_clk), .i_rst(i_rst), .i_inst(inst), .i_valid(active),
        .i_advance(finish), .i_fcsr(csr),
        .i_frs1(operands[31:0]), .i_frs2(operands[63:32]),
        .i_frs3(operands[95:64]), .i_xrs1(operands[31:0]),
        .o_fp_result(fp_result), .o_int_result(int_result),
        .o_fflags(), .o_flags(flags), .o_busy(busy), .o_rm_trap(trap)
    );
    always @(posedge i_clk) begin
        if (i_rst) begin
            active <= 1'b0;
            tag <= 3'd0;
            inst <= 32'd0;
            pc <= 32'd0;
            operands <= 96'd0;
            csr <= 8'd0;
            o_result_valid <= 1'b0;
            o_result_tag <= 3'd0;
            o_result_value <= 32'd0;
            o_result_inst <= 32'd0;
            o_result_pc <= 32'd0;
            o_result_flags <= 5'd0;
            o_result_trap <= 1'b0;
            o_result_operands <= 96'd0;
        end else begin
            if (i_result_grant) o_result_valid <= 1'b0;
            if (i_dispatch_valid & o_dispatch_ready) begin
                active <= 1'b1;
                tag <= i_dispatch_tag;
                inst <= i_dispatch_inst;
                pc <= i_dispatch_pc;
                operands <= i_dispatch_operands;
                csr <= i_fcsr;
            end
            if (finish) begin
                active <= 1'b0;
                o_result_valid <= 1'b1;
                o_result_tag <= tag;
                o_result_value <= integer_result ? int_result : fp_result;
                o_result_inst <= inst;
                o_result_pc <= pc;
                o_result_flags <= flags;
                o_result_trap <= trap;
                o_result_operands <= operands;
            end
        end
    end
endmodule

`default_nettype wire
