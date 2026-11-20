`default_nettype none

// TEST ONLY (not part of the submission, not linted). A hart with the phase 7
// ports (skeletons/hart.v) built around the phase 6 pipelined hart, renamed
// hart_p6 by build.sh, so the phase 7 testbenches can be validated before
// the out-of-order hart exists.
//
//  * Instruction fetch: hart_p6 has an instruction cache that asks for whole
//    lines. Each line request is queued and served by reading the line's
//    words one per cycle through the combinational o_imem_raddr /
//    i_imem_rdata port, then returned on i_imem_valid. Fetch is therefore
//    slow, and cycle counts / CPI from this stand-in mean nothing.
//  * Data memory: hart_p6's data cache port is passed straight through.
//    i_mem_ready is ignored, as the phase 5 cache has no such input.
//  * Retire: hart_p6's whole retire stream, delayed by one cycle.
//  * Complete: driven from the undelayed retire stream, so each complete is
//    one cycle before its retire, in program order (never out of order).
//    Tags count up by one per retired instruction, mod 8. Only the CDB
//    classes pulse it (integer ALU, lui, auipc, jal, jalr, branches,
//    non-trapping loads, FP and CSR ops); stores, ebreak, illegal and
//    misaligned ops do not.
module hart #(
    parameter RESET_ADDR     = 32'h00000000,
    parameter BYPASS_EN      = 1,
    parameter EVICT_POLICY   = 0,
    parameter NUM_WAYS       = 1,
    parameter CACHE_SIZE     = 16,
    parameter BLOCK_SIZE     = 128,
    parameter PREFETCH_EN    = 0,
    parameter WRITE_ALLOCATE = 0
) (
    input  wire                    i_clk,
    input  wire                    i_rst,
    output wire [31:0]             o_imem_raddr,
    input  wire [31:0]             i_imem_rdata,
    input  wire                    i_mem_ready,
    input  wire                    i_mem_valid,
    input  wire [BLOCK_SIZE*8-1:0] i_mem_rd_data,
    output wire                    o_mem_rd,
    output wire                    o_mem_wr,
    output wire [31:0]             o_mem_rd_addr,
    output wire [31:0]             o_mem_wr_addr,
    output wire [BLOCK_SIZE*8-1:0] o_mem_wr_data,
    output wire [BLOCK_SIZE-1:0]   o_mem_wr_be,
    output reg         o_retire_valid,
    output reg  [31:0] o_retire_inst,
    output reg         o_retire_trap,
    output reg         o_retire_halt,
    output reg  [ 4:0] o_retire_rs1_raddr,
    output reg  [ 4:0] o_retire_rs2_raddr,
    output reg  [31:0] o_retire_rs1_rdata,
    output reg  [31:0] o_retire_rs2_rdata,
    output reg  [ 4:0] o_retire_rd_waddr,
    output reg  [31:0] o_retire_rd_wdata,
    output reg  [31:0] o_retire_dmem_addr,
    output reg  [ 3:0] o_retire_dmem_mask,
    output reg         o_retire_dmem_ren,
    output reg         o_retire_dmem_wen,
    output reg  [31:0] o_retire_dmem_rdata,
    output reg  [31:0] o_retire_dmem_wdata,
    output reg  [31:0] o_retire_pc,
    output reg  [31:0] o_retire_next_pc,
    output wire        o_complete_valid,
    output wire [ 2:0] o_complete_tag,
    output wire [ 4:0] o_complete_rd,
    output wire [31:0] o_complete_value,
    output wire [31:0] o_complete_pc,
    output reg  [ 4:0] o_retire_frs1_raddr,
    output reg  [31:0] o_retire_frs1_rdata,
    output reg  [ 4:0] o_retire_frs2_raddr,
    output reg  [31:0] o_retire_frs2_rdata,
    output reg  [ 4:0] o_retire_frs3_raddr,
    output reg  [31:0] o_retire_frs3_rdata,
    output reg         o_retire_frd_wen,
    output reg  [ 4:0] o_retire_frd_waddr,
    output reg  [31:0] o_retire_frd_wdata,
    output reg  [ 4:0] o_retire_fflags
);
    localparam WORDS = BLOCK_SIZE / 4;

    // ---------------------------------------------------------------- p6
    wire                    p_imem_rd;
    wire [31:0]             p_imem_rd_addr;
    reg                     p_imem_valid;
    reg  [BLOCK_SIZE*8-1:0] p_imem_line;

    wire        rv, rtrap, rhalt, rdren, rdwen, rfwen;
    wire [31:0] rinst, rs1d, rs2d, rdd, daddr, drdata, dwdata, rpc, rnpc, f1d, f2d, f3d, fdd;
    wire [ 4:0] rs1a, rs2a, rda, f1a, f2a, f3a, fda, ffl;
    wire [ 3:0] dmask;

    hart_p6 #(
        .RESET_ADDR  (RESET_ADDR),
        .BYPASS_EN   (BYPASS_EN),
        .EVICT_POLICY(EVICT_POLICY),
        .NUM_WAYS    (NUM_WAYS),
        .CACHE_SIZE  (CACHE_SIZE),
        .BLOCK_SIZE  (BLOCK_SIZE),
        .PREFETCH_EN (PREFETCH_EN)
    ) p6 (
        .i_clk(i_clk), .i_rst(i_rst),
        .o_imem_rd(p_imem_rd), .o_imem_rd_addr(p_imem_rd_addr),
        .i_imem_valid(p_imem_valid), .i_imem_rd_data(p_imem_line),
        .o_dmem_rd(o_mem_rd), .o_dmem_rd_addr(o_mem_rd_addr),
        .i_dmem_valid(i_mem_valid), .i_dmem_rd_data(i_mem_rd_data),
        .o_dmem_wr(o_mem_wr), .o_dmem_wr_addr(o_mem_wr_addr),
        .o_dmem_wr_data(o_mem_wr_data), .o_dmem_wr_be(o_mem_wr_be),
        .o_retire_valid(rv), .o_retire_inst(rinst), .o_retire_trap(rtrap),
        .o_retire_halt(rhalt), .o_retire_rs1_raddr(rs1a), .o_retire_rs2_raddr(rs2a),
        .o_retire_rs1_rdata(rs1d), .o_retire_rs2_rdata(rs2d), .o_retire_rd_waddr(rda),
        .o_retire_rd_wdata(rdd), .o_retire_dmem_addr(daddr), .o_retire_dmem_mask(dmask),
        .o_retire_dmem_ren(rdren), .o_retire_dmem_wen(rdwen), .o_retire_dmem_rdata(drdata),
        .o_retire_dmem_wdata(dwdata), .o_retire_pc(rpc), .o_retire_next_pc(rnpc),
        .o_retire_frs1_raddr(f1a), .o_retire_frs1_rdata(f1d),
        .o_retire_frs2_raddr(f2a), .o_retire_frs2_rdata(f2d),
        .o_retire_frs3_raddr(f3a), .o_retire_frs3_rdata(f3d),
        .o_retire_frd_wen(rfwen), .o_retire_frd_waddr(fda), .o_retire_frd_wdata(fdd),
        .o_retire_fflags(ffl)
    );

    // ---------------------------------------------------------------- fetch
    reg  [31:0]             q [0:7];
    reg  [2:0]              qh, qt;
    reg  [3:0]              qn;
    reg                     busy;
    reg  [31:0]             cur;
    reg  [7:0]              widx;
    reg  [BLOCK_SIZE*8-1:0] line_buf;
    reg  [BLOCK_SIZE*8-1:0] tmp;

    assign o_imem_raddr = cur + {widx, 2'b00};

    always @(posedge i_clk) begin
        p_imem_valid <= 1'b0;
        if (i_rst) begin
            qh <= 0; qt <= 0; qn <= 0; busy <= 0; cur <= RESET_ADDR; widx <= 0;
        end else begin
            if (busy) begin
                tmp = line_buf;
                tmp[32*widx +: 32] = i_imem_rdata;
                line_buf <= tmp;
                if (widx == WORDS - 1) begin
                    busy <= 1'b0;
                    p_imem_valid <= 1'b1;
                    p_imem_line <= tmp;
                end else begin
                    widx <= widx + 1;
                end
            end
            if (!busy && qn != 0) begin
                busy <= 1'b1;
                cur  <= q[qh];
                widx <= 0;
                qh   <= qh + 1;
            end
            if (p_imem_rd) begin
                q[qt] <= p_imem_rd_addr;
                qt <= qt + 1;
            end
            qn <= qn + (p_imem_rd ? 1 : 0) - ((!busy && qn != 0) ? 1 : 0);
        end
    end

    // ---------------------------------------------------------------- retire
    always @(posedge i_clk) begin
        if (i_rst) begin
            o_retire_valid <= 1'b0;
        end else begin
            o_retire_valid      <= rv;
            o_retire_inst       <= rinst;
            o_retire_trap       <= rtrap;
            o_retire_halt       <= rhalt;
            o_retire_rs1_raddr  <= rs1a;
            o_retire_rs2_raddr  <= rs2a;
            o_retire_rs1_rdata  <= rs1d;
            o_retire_rs2_rdata  <= rs2d;
            o_retire_rd_waddr   <= rda;
            o_retire_rd_wdata   <= rdd;
            o_retire_dmem_addr  <= daddr;
            o_retire_dmem_mask  <= dmask;
            o_retire_dmem_ren   <= rdren;
            o_retire_dmem_wen   <= rdwen;
            o_retire_dmem_rdata <= drdata;
            o_retire_dmem_wdata <= dwdata;
            o_retire_pc         <= rpc;
            o_retire_next_pc    <= rnpc;
            o_retire_frs1_raddr <= f1a;
            o_retire_frs1_rdata <= f1d;
            o_retire_frs2_raddr <= f2a;
            o_retire_frs2_rdata <= f2d;
            o_retire_frs3_raddr <= f3a;
            o_retire_frs3_rdata <= f3d;
            o_retire_frd_wen    <= rfwen;
            o_retire_frd_waddr  <= fda;
            o_retire_frd_wdata  <= fdd;
            o_retire_fflags     <= ffl;
        end
    end

    // ---------------------------------------------------------------- complete
    wire [6:0] opc = rinst[6:0];
    wire is_store = (opc == 7'h23) || (opc == 7'h27);
    wire is_load  = (opc == 7'h03) || (opc == 7'h07);
    wire is_br    = (opc == 7'h63);
    wire is_jump  = (opc == 7'h6F) || (opc == 7'h67);
    // decoder.v's legality rules (same mirror as hart_tb_common.vh).
    function legal_inst;
        input [31:0] i;
        reg [6:0] o, f7;
        reg [2:0] f3;
        reg [4:0] r2;
        reg       rm_ok;
        begin
            o = i[6:0]; f3 = i[14:12]; f7 = i[31:25]; r2 = i[24:20];
            rm_ok = (f3 != 3'b101) && (f3 != 3'b110);
            case (o)
                7'h37, 7'h17, 7'h6F: legal_inst = 1'b1;
                7'h67: legal_inst = (f3 == 3'b000);
                7'h63: legal_inst = (f3 != 3'b010) && (f3 != 3'b011);
                7'h03: legal_inst = (f3 != 3'b011) && (f3 != 3'b110) && (f3 != 3'b111);
                7'h23: legal_inst = (f3 <= 3'b010);
                7'h13: legal_inst = (f3 != 3'b001 || f7 == 7'h00) &&
                                    (f3 != 3'b101 || f7 == 7'h00 || f7 == 7'h20);
                7'h33: legal_inst = (f7 == 7'h00) || (f7 == 7'h01) ||
                                    (f7 == 7'h20 && (f3 == 3'b000 || f3 == 3'b101));
                7'h07, 7'h27: legal_inst = (f3 == 3'b010);
                7'h53: legal_inst =
                    ((f7 == 7'h00 || f7 == 7'h04 || f7 == 7'h08 || f7 == 7'h0C) && rm_ok) ||
                    (f7 == 7'h2C && r2 == 5'd0 && rm_ok) ||
                    (f7 == 7'h10 && f3 <= 3'b010) || (f7 == 7'h14 && f3 <= 3'b001) ||
                    (f7 == 7'h50 && f3 <= 3'b010) ||
                    (f7 == 7'h70 && r2 == 5'd0 && f3 <= 3'b001) ||
                    ((f7 == 7'h60 || f7 == 7'h68) && rm_ok && r2 <= 5'd1) ||
                    (f7 == 7'h78 && r2 == 5'd0 && f3 == 3'b000);
                7'h73: legal_inst = (i == 32'h00100073) ||
                    (f3 != 3'b000 && f3 != 3'b100 &&
                     (i[31:20] == 12'h001 || i[31:20] == 12'h002 || i[31:20] == 12'h003));
                7'h43, 7'h47, 7'h4B, 7'h4F: legal_inst = (i[26:25] == 2'b00) && rm_ok;
                default: legal_inst = 1'b0;
            endcase
        end
    endfunction
    wire illegal  = ~legal_inst(rinst);
    wire cdb      = rv & ~rhalt & ~is_store & ~illegal & ~(is_load & rtrap);

    reg [2:0] tag_ctr;
    always @(posedge i_clk) begin
        if (i_rst)
            tag_ctr <= 3'd0;
        else if (rv)
            tag_ctr <= tag_ctr + 3'd1;
    end

    assign o_complete_valid = cdb;
    assign o_complete_tag   = tag_ctr;
    assign o_complete_rd    = is_br ? 5'd0 : rfwen ? rinst[11:7] : rda;
    assign o_complete_value = rfwen ? fdd : is_jump ? rpc + 32'd4 : is_br ? 32'd0 : rdd;
    assign o_complete_pc    = rpc;

endmodule

`default_nettype wire
