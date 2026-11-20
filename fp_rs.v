`default_nettype none

// Four FP reservation slots, oldest-ready single dispatch to two independent
// FPU lanes. Both result ports request the shared CDB independently.
module fp_rs (
    input wire i_clk, i_rst,
    input wire [2:0] i_rob_head,
    input wire i_rob_empty,
    input wire i_issue_valid,
    output wire o_issue_ready,
    input wire [2:0] i_issue_tag,
    input wire [31:0] i_issue_inst, i_issue_pc,
    input wire [2:0] i_issue_wait,
    input wire [8:0] i_issue_qtags,
    input wire [95:0] i_issue_values,
    input wire i_cdb_valid,
    input wire [2:0] i_cdb_tag,
    input wire [31:0] i_cdb_value,
    input wire [7:0] i_fcsr,
    input wire i_commit_valid,
    input wire [2:0] i_commit_tag,
    // Stall ALL younger issue while this is high, not just FP issue.
    output wire o_serializing,
    output wire o_dispatch_valid,
    output wire [2:0] o_dispatch_tag,
    output wire o_dispatch_lane,
    output wire [1:0] o_result_valid,
    input wire [1:0] i_result_grant,
    output wire [5:0] o_result_tag,
    output wire [63:0] o_result_value, o_result_inst, o_result_pc,
    output wire [9:0] o_result_flags,
    output wire [1:0] o_result_trap,
    output wire [191:0] o_result_operands
);
    wire queue_ready, queue_empty, ready;
    wire [1:0] slot;
    wire [2:0] tag;
    wire [66:0] payload;
    wire [95:0] operands;
    wire [1:0] lane_ready, lane_idle;
    reg csr_pending;
    reg [2:0] csr_tag;
    wire issue_csr = (i_issue_inst[6:0] == 7'h73);
    assign o_issue_ready = queue_ready & ~csr_pending &
                           (~issue_csr | (i_rob_empty & queue_empty & (&lane_idle)));
    wire issue = i_issue_valid & o_issue_ready;
    // CSR admission drains older ROB instructions first. No younger FP
    // enters until its commit, so both lanes use the same architectural frm.
    assign o_serializing = csr_pending;
    always @(posedge i_clk) begin
        if (i_rst) begin
            csr_pending <= 1'b0;
            csr_tag <= 3'd0;
        end else begin
            if (csr_pending & i_commit_valid & (i_commit_tag == csr_tag))
                csr_pending <= 1'b0;
            if (issue & issue_csr) begin
                csr_pending <= 1'b1;
                csr_tag <= i_issue_tag;
            end
        end
    end
    wire dispatch = ready & (|lane_ready);
    wire lane = ~lane_ready[0];
    assign o_dispatch_valid = dispatch;
    assign o_dispatch_tag = tag;
    assign o_dispatch_lane = lane;
    reservation_station queue (
        .i_clk(i_clk), .i_rst(i_rst), .i_rob_head(i_rob_head),
        .i_issue_valid(issue), .o_issue_ready(queue_ready),
        .i_issue_tag(i_issue_tag),
        .i_issue_payload({i_issue_tag, i_issue_pc, i_issue_inst}),
        .i_issue_wait(i_issue_wait), .i_issue_qtags(i_issue_qtags),
        .i_issue_values(i_issue_values),
        .i_cdb_valid(i_cdb_valid), .i_cdb_tag(i_cdb_tag), .i_cdb_value(i_cdb_value),
        .o_ready_valid(ready), .o_ready_slot(slot), .o_ready_tag(tag),
        .o_ready_payload(payload), .o_ready_values(operands),
        .i_remove_valid(dispatch), .i_remove_slot(slot), .o_empty(queue_empty)
    );
    genvar n;
    generate for (n = 0; n < 2; n = n + 1) begin : g_lane
        fp_exec execute (
            .i_clk(i_clk), .i_rst(i_rst),
            .i_dispatch_valid(dispatch & (lane == n)), .o_dispatch_ready(lane_ready[n]),
            .i_dispatch_tag(tag), .i_dispatch_inst(payload[31:0]),
            .i_dispatch_pc(payload[63:32]), .i_dispatch_operands(operands),
            .i_fcsr(i_fcsr), .o_result_valid(o_result_valid[n]),
            .i_result_grant(i_result_grant[n]),
            .o_result_tag(o_result_tag[3*n +: 3]),
            .o_result_value(o_result_value[32*n +: 32]),
            .o_result_inst(o_result_inst[32*n +: 32]),
            .o_result_pc(o_result_pc[32*n +: 32]),
            .o_result_flags(o_result_flags[5*n +: 5]),
            .o_result_trap(o_result_trap[n]),
            .o_result_operands(o_result_operands[96*n +: 96]),
            .o_idle(lane_idle[n])
        );
    end endgenerate
endmodule

`default_nettype wire
