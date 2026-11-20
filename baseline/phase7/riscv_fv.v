`default_nettype none

module riscv_fv (
  input wire i_clk,
  input wire i_rst,
  // Add ports you need to drive / observe, or keep DUT inputs free for BMC.
  // All DUT inputs are ports here, so they are free inputs for BMC.

  // cdb_arb requests
  input wire [2:0] i_rob_head,
  input wire i_int_v,
  input wire [2:0] i_int_tag,
  input wire [31:0] i_int_value,
  input wire i_fp0_v,
  input wire [2:0] i_fp0_tag,
  input wire [31:0] i_fp0_value,
  input wire [4:0] i_fp0_flags,
  input wire i_fp1_v,
  input wire [2:0] i_fp1_tag,
  input wire [31:0] i_fp1_value,
  input wire [4:0] i_fp1_flags,
  input wire i_ld_v,
  input wire [2:0] i_ld_tag,
  input wire [31:0] i_ld_value,

  // rat lookups / renames / clears
  input wire [4:0] i_rs1_idx,
  input wire [4:0] i_rs2_idx,     // watched integer register (held constant)
  input wire [4:0] i_frs1_idx,
  input wire [4:0] i_frs2_idx,    // watched FP register (held constant)
  input wire [4:0] i_frs3_idx,
  input wire i_ren_valid,
  input wire [4:0] i_ren_idx,
  input wire [2:0] i_ren_tag,
  input wire i_fren_valid,
  input wire [4:0] i_fren_idx,
  input wire [2:0] i_fren_tag,
  input wire i_clr_valid,
  input wire [4:0] i_clr_idx,
  input wire [2:0] i_clr_tag,
  input wire i_fclr_valid,
  input wire [4:0] i_fclr_idx,
  input wire [2:0] i_fclr_tag
);

  // -------------------------------------------------------------------------
  // Instantiate YOUR modules (names must match your submitted .v files).
  // -------------------------------------------------------------------------
  wire o_int_grant, o_fp0_grant, o_fp1_grant, o_ld_grant, o_cdb_valid;
  wire [2:0] o_cdb_tag;
  wire [31:0] o_cdb_value;
  wire [4:0] o_cdb_fflags;

  cdb_arb #(.TAG_W(3)) dut_cdb (
    .i_rob_head (i_rob_head),
    .i_int_v (i_int_v),
    .i_int_tag (i_int_tag),
    .i_int_value (i_int_value),
    .i_fp0_v (i_fp0_v),
    .i_fp0_tag (i_fp0_tag),
    .i_fp0_value (i_fp0_value),
    .i_fp0_flags (i_fp0_flags),
    .i_fp1_v (i_fp1_v),
    .i_fp1_tag (i_fp1_tag),
    .i_fp1_value (i_fp1_value),
    .i_fp1_flags (i_fp1_flags),
    .i_ld_v (i_ld_v),
    .i_ld_tag (i_ld_tag),
    .i_ld_value (i_ld_value),
    .o_int_grant (o_int_grant),
    .o_fp0_grant (o_fp0_grant),
    .o_fp1_grant (o_fp1_grant),
    .o_ld_grant (o_ld_grant),
    .o_cdb_valid (o_cdb_valid),
    .o_cdb_tag (o_cdb_tag),
    .o_cdb_value (o_cdb_value),
    .o_cdb_fflags(o_cdb_fflags)
  );

  wire o_rs1_busy, o_rs2_busy, o_frs1_busy, o_frs2_busy, o_frs3_busy;
  wire [ 2:0] o_rs1_tag, o_rs2_tag, o_frs1_tag, o_frs2_tag, o_frs3_tag;

  rat #(.TAG_W(3)) dut_rat (.i_clk(i_clk), .i_rst(i_rst), .i_rs1_idx(i_rs1_idx), .o_rs1_busy(o_rs1_busy), .o_rs1_tag(o_rs1_tag),
    .i_rs2_idx (i_rs2_idx), .o_rs2_busy (o_rs2_busy), .o_rs2_tag (o_rs2_tag),
    .i_frs1_idx (i_frs1_idx),.o_frs1_busy(o_frs1_busy),.o_frs1_tag(o_frs1_tag),
    .i_frs2_idx (i_frs2_idx),.o_frs2_busy(o_frs2_busy),.o_frs2_tag(o_frs2_tag),
    .i_frs3_idx (i_frs3_idx),.o_frs3_busy(o_frs3_busy),.o_frs3_tag(o_frs3_tag),
    .i_ren_valid (i_ren_valid), .i_ren_idx (i_ren_idx), .i_ren_tag (i_ren_tag),
    .i_fren_valid(i_fren_valid), .i_fren_idx(i_fren_idx),.i_fren_tag(i_fren_tag),
    .i_clr_valid (i_clr_valid), .i_clr_idx (i_clr_idx), .i_clr_tag (i_clr_tag),
    .i_fclr_valid(i_fclr_valid), .i_fclr_idx(i_fclr_idx),.i_fclr_tag(i_fclr_tag)
  );

  // The fixed riscv_fv.sby reads this file with `read -sv`, which does NOT
  // define FORMAL (only `read -formal` does), so the `ifdef FORMAL block below
  // would be silently dropped and sby would PASS without checking anything.
  // Yosys always defines YOSYS (iverilog and the ece552 lint never do), so
  // FORMAL is defined here only when Yosys reads the file.
`ifdef YOSYS
`ifndef FORMAL
`define FORMAL
`endif
`endif

`ifdef FORMAL
  // =========================================================================
  // Environment
  // =========================================================================
  reg f_past_valid;
  initial f_past_valid = 1'b0;
  always @(posedge i_clk) f_past_valid <= 1'b1;

  // Start from reset.
  always @(*) begin
    if (!f_past_valid)
      assume (i_rst);
  end

  // The watched registers stay the same for the whole trace.
  always @(posedge i_clk) begin
    if (f_past_valid) begin
      assume (i_rs2_idx  == $past(i_rs2_idx));
      assume (i_frs2_idx == $past(i_frs2_idx));
    end
  end

  // =========================================================================
  // cdb_arb properties (combinational: checked on every cycle)
  // =========================================================================
  // Reference ages, computed here independently of the RTL.
  wire [2:0] f_age_int = i_int_tag - i_rob_head;
  wire [2:0] f_age_fp0 = i_fp0_tag - i_rob_head;
  wire [2:0] f_age_fp1 = i_fp1_tag - i_rob_head;
  wire [2:0] f_age_ld  = i_ld_tag  - i_rob_head;
  wire [2:0] f_n_req = i_int_v + i_fp0_v + i_fp1_v + i_ld_v;
  wire [2:0] f_n_gnt = o_int_grant + o_fp0_grant + o_fp1_grant + o_ld_grant;

  always @(*) begin
    // C1: at most one grant per cycle (one CDB broadcast).
    assert (f_n_gnt <= 3'd1);

    // C2-C5: a grant only goes to a requester.
    assert (!o_int_grant || i_int_v);
    assert (!o_fp0_grant || i_fp0_v);
    assert (!o_fp1_grant || i_fp1_v);
    assert (!o_ld_grant || i_ld_v);

    // C6: the bus is busy exactly when someone asks (work conserving).
    assert (o_cdb_valid == (f_n_req != 3'd0));

    // C7: valid is exactly "some grant was given".
    assert (o_cdb_valid == (f_n_gnt == 3'd1));

    // C8: a lone requester always wins.
    if (f_n_req == 3'd1)
      assert ((o_int_grant == i_int_v) && (o_fp0_grant == i_fp0_v) &&
              (o_fp1_grant == i_fp1_v) && (o_ld_grant == i_ld_v));

    // C9-C12: the oldest requester wins (no valid requester is older than
    // the winner; exact ties go to int, then fp0, then fp1, then ld).
    if (o_int_grant)
      assert ((!i_fp0_v || f_age_int <= f_age_fp0) && (!i_fp1_v || f_age_int <= f_age_fp1) && (!i_ld_v  || f_age_int <= f_age_ld));
    if (o_fp0_grant)
      assert ((!i_int_v || f_age_fp0 <  f_age_int) && (!i_fp1_v || f_age_fp0 <= f_age_fp1) && (!i_ld_v  || f_age_fp0 <= f_age_ld));
    if (o_fp1_grant)
      assert ((!i_int_v || f_age_fp1 <  f_age_int) && (!i_fp0_v || f_age_fp1 <  f_age_fp0) && (!i_ld_v  || f_age_fp1 <= f_age_ld));
    if (o_ld_grant)
      assert ((!i_int_v || f_age_ld  <  f_age_int) && (!i_fp0_v || f_age_ld  <  f_age_fp0) && (!i_fp1_v || f_age_ld  <  f_age_fp1));

    // C13-C15: the broadcast carries the winner's tag, value and flags.
    if (o_int_grant) assert (o_cdb_tag == i_int_tag && o_cdb_value == i_int_value && o_cdb_fflags == 5'd0);
    if (o_fp0_grant) assert (o_cdb_tag == i_fp0_tag && o_cdb_value == i_fp0_value && o_cdb_fflags == i_fp0_flags);
    if (o_fp1_grant) assert (o_cdb_tag == i_fp1_tag && o_cdb_value == i_fp1_value && o_cdb_fflags == i_fp1_flags);
    if (o_ld_grant) assert (o_cdb_tag == i_ld_tag  && o_cdb_value == i_ld_value  && o_cdb_fflags == 5'd0);

    // C16: an idle bus drives zeros.
    if (!o_cdb_valid)
      assert (o_cdb_tag == 3'd0 && o_cdb_value == 32'd0 && o_cdb_fflags == 5'd0);
  end

  // =========================================================================
  // rat properties
  // =========================================================================
  // R1-R2: x0 is never renamed, on either integer port.
  always @(*) begin
    if (i_rs1_idx == 5'd0) assert (!o_rs1_busy);
    if (i_rs2_idx == 5'd0) assert (!o_rs2_busy);
  end

  // R3-R5: all lookup ports read the same table.
  always @(*) begin
    if (i_rs1_idx  == i_rs2_idx)  assert (o_rs1_busy == o_rs2_busy && o_rs1_tag == o_rs2_tag);
    if (i_frs1_idx == i_frs2_idx) assert (o_frs1_busy == o_frs2_busy && o_frs1_tag == o_frs2_tag);
    if (i_frs3_idx == i_frs2_idx) assert (o_frs3_busy == o_frs2_busy && o_frs3_tag == o_frs2_tag);
  end

  // Does this cycle rename / clear (with a matching tag) a watched register?
  wire f_ren_w = i_ren_valid && (i_ren_idx == i_rs2_idx);
  wire f_clr_w = i_clr_valid && (i_clr_idx == i_rs2_idx)  && (i_clr_tag  == o_rs2_tag);
  wire f_fren_w = i_fren_valid && (i_fren_idx == i_frs2_idx);
  wire f_fclr_w = i_fclr_valid && (i_fclr_idx == i_frs2_idx) && (i_fclr_tag == o_frs2_tag);

  always @(posedge i_clk) begin
    if (f_past_valid) begin
      // R6-R7: reset clears everything (every lookup port, busy and tag).
      if ($past(i_rst)) begin
        assert (!o_rs1_busy && !o_rs2_busy && o_rs1_tag == 3'd0 && o_rs2_tag == 3'd0);
        assert (!o_frs1_busy && !o_frs2_busy && !o_frs3_busy && o_frs1_tag == 3'd0 && o_frs2_tag == 3'd0 && o_frs3_tag == 3'd0);
      end

      if (!$past(i_rst)) begin
        // R8-R9: a rename maps the register to the new tag on the next cycle,
        // even if a commit clears the same register in that cycle.
        if ($past(i_ren_valid) && $past(i_ren_idx) != 5'd0 && i_rs1_idx == $past(i_ren_idx))
          assert (o_rs1_busy && o_rs1_tag == $past(i_ren_tag));
        if ($past(i_fren_valid) && i_frs1_idx == $past(i_fren_idx))
          assert (o_frs1_busy && o_frs1_tag == $past(i_fren_tag));

        // R10-R11: a commit with the matching tag frees the register.
        if ($past(f_clr_w) && !$past(f_ren_w))
          assert (!o_rs2_busy);
        if ($past(f_fclr_w) && !$past(f_fren_w))
          assert (!o_frs2_busy);

        // R12-R13: otherwise the entry holds (a commit whose tag no longer
        // matches, because a younger instruction renamed the register,
        // changes nothing).
        if (!$past(f_ren_w) && !$past(f_clr_w))
          assert (o_rs2_busy == $past(o_rs2_busy) && o_rs2_tag == $past(o_rs2_tag));
        if (!$past(f_fren_w) && !$past(f_fclr_w))
          assert (o_frs2_busy == $past(o_frs2_busy) && o_frs2_tag == $past(o_frs2_tag));

        // R14-R15: a commit never changes the tag, and never sets busy.
        if (!$past(f_ren_w))
          assert (o_rs2_tag == $past(o_rs2_tag) && (!o_rs2_busy || $past(o_rs2_busy)));
        if (!$past(f_fren_w))
          assert (o_frs2_tag == $past(o_frs2_tag) && (!o_frs2_busy || $past(o_frs2_busy)));
      end
    end
  end

  // Reachability hints for `sby` cover mode (ignored by the graded bmc job).
  always @(posedge i_clk) begin
    if (f_past_valid && !$past(i_rst)) begin
      cover (o_ld_grant && i_int_v); // load beats an ALU result
      cover ($past(o_rs2_busy) && !o_rs2_busy); // integer register freed
      cover ($past(i_clr_valid) && $past(i_clr_idx) == i_rs2_idx && !$past(f_ren_w) && o_rs2_busy);// stale clear ignored
      cover ($past(o_frs2_busy) && !o_frs2_busy); // FP register freed
    end
  end
`endif
endmodule

`default_nettype wire
