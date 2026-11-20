`default_nettype none

// Four issue slots shared by the integer and FP schedulers. Each source is
// either a value or a ROB Q-tag. Selection only sees registered slots, so an
// instruction can never dispatch on its issue edge. A waiting source is also
// ready in the cycle its tag is on the CDB (value bypassed from the CDB). Removal is explicit so
// the integer scheduler can retain a multiply/divide slot until it finishes.
module reservation_station #(
    parameter PAYLOAD_WIDTH = 67
) (
    input wire i_clk, i_rst,
    input wire [2:0] i_rob_head,
    input wire i_issue_valid,
    output wire o_issue_ready,
    input wire [2:0] i_issue_tag,
    input wire [PAYLOAD_WIDTH-1:0] i_issue_payload,
    input wire [2:0] i_issue_wait,
    input wire [8:0] i_issue_qtags,
    input wire [95:0] i_issue_values,
    input wire i_cdb_valid,
    input wire [2:0] i_cdb_tag,
    input wire [31:0] i_cdb_value,
    output wire o_ready_valid,
    output wire [1:0] o_ready_slot,
    output wire [2:0] o_ready_tag,
    output wire [PAYLOAD_WIDTH-1:0] o_ready_payload,
    output wire [95:0] o_ready_values,
    input wire i_remove_valid,
    input wire [1:0] i_remove_slot,
    output wire o_empty
);
    wire [3:0] occupied, ready;
    wire [2:0] tags [0:3];
    wire [PAYLOAD_WIDTH-1:0] payload [0:3];
    wire [95:0] values [0:3];
    wire [4:0] free_seen, pick_valid;
    wire [1:0] free_slot [0:4];
    wire [1:0] pick_slot [0:4];
    wire [2:0] pick_age [0:4];
    assign free_seen[0] = 1'b0;
    assign free_slot[0] = 2'd0;
    assign pick_valid[0] = 1'b0;
    assign pick_slot[0] = 2'd0;
    assign pick_age[0] = 3'd0;

    genvar n, s;
    generate for (n = 0; n < 4; n = n + 1) begin : g_slot
        reg valid;
        reg [2:0] tag;
        reg [PAYLOAD_WIDTH-1:0] data;
        wire allocate = i_issue_valid & o_issue_ready & (free_slot[4] == n);
        wire remove = i_remove_valid & (i_remove_slot == n);
        wire [2:0] waiting;
        wire [2:0] age = tag - i_rob_head; // three-bit subtraction is mod 8
        wire choose = ready[n] & (~pick_valid[n] | (age < pick_age[n]));
        assign occupied[n] = valid;
        assign tags[n] = tag;
        assign payload[n] = data;
        assign ready[n] = valid & ~(|waiting);
        assign free_seen[n+1] = free_seen[n] | ~valid;
        assign free_slot[n+1] = free_seen[n] ? free_slot[n] : n;
        assign pick_valid[n+1] = pick_valid[n] | ready[n];
        assign pick_slot[n+1] = choose ? n : pick_slot[n];
        assign pick_age[n+1] = choose ? age : pick_age[n];
        always @(posedge i_clk) begin
            if (i_rst) begin
                valid <= 1'b0;
                tag <= 3'd0;
                data <= {PAYLOAD_WIDTH{1'b0}};
            end else if (allocate) begin
                valid <= 1'b1;
                tag <= i_issue_tag;
                data <= i_issue_payload;
            end else if (remove) begin
                valid <= 1'b0;
            end
        end
        for (s = 0; s < 3; s = s + 1) begin : g_source
            reg wait_tag;
            reg [2:0] qtag;
            reg [31:0] value;
            wire issue_hit = i_cdb_valid &
                             (i_issue_qtags[3*s +: 3] == i_cdb_tag);
            // Same-cycle CDB bypass: a source whose producer broadcasts this
            // cycle counts as ready and takes the value straight off the CDB,
            // so a dependent can dispatch in its producer's broadcast cycle.
            wire hit_now = wait_tag & i_cdb_valid & (qtag == i_cdb_tag);
            assign waiting[s] = wait_tag & ~hit_now;
            assign values[n][32*s +: 32] = hit_now ? i_cdb_value : value;
            always @(posedge i_clk) begin
                if (i_rst) begin
                    wait_tag <= 1'b0;
                    qtag <= 3'd0;
                    value <= 32'd0;
                end else if (allocate) begin
                    wait_tag <= i_issue_wait[s] & ~issue_hit;
                    qtag <= i_issue_qtags[3*s +: 3];
                    value <= (i_issue_wait[s] & issue_hit) ? i_cdb_value :
                             i_issue_values[32*s +: 32];
                end else if (valid & wait_tag & i_cdb_valid & (qtag == i_cdb_tag)) begin
                    wait_tag <= 1'b0;
                    value <= i_cdb_value;
                end
            end
        end
    end endgenerate
    assign o_issue_ready = ~i_rst & (|(~occupied));
    assign o_empty = ~(|occupied);
    assign o_ready_valid = ~i_rst & pick_valid[4];
    assign o_ready_slot = pick_slot[4];
    assign o_ready_tag = tags[pick_slot[4]];
    assign o_ready_payload = payload[pick_slot[4]];
    assign o_ready_values = values[pick_slot[4]];
endmodule

`default_nettype wire
