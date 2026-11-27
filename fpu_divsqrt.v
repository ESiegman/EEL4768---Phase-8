`default_nettype none

// fdiv.s / fsqrt.s significand datapath (phase_6.pdf 5.3.2). Restoring
// division and square root, three result bits per iteration.
//
// The top (fpu.v) resolves every special operand, so this unit only sees
// finite, nonzero operands (and positive ones for square root). Each operand
// arrives normalized: sig[23] = 1, and a signed 10-bit exponent biased by
// 127 that may be below 1 for a subnormal input.
//
// The result goes unrounded to fpu_round: o_sig[25:2] is the 24-bit
// significand (o_sig[25] = 1), o_sig[1] the guard bit and o_sig[0] the
// sticky bit (a nonzero final remainder).
//
// Handshake (same as the other multi-cycle units):
//  * cycle 1: i_valid rises, o_busy goes high, operands are latched
//  * cycles 2-9: three bits per cycle after the known leading one
//  * then o_busy drops and the result is held until i_advance
// The unit never restarts while a finished result is held, so a cache
// freeze after the operation finishes cannot rerun it.
module fpu_divsqrt (
    input  wire        i_clk,
    input  wire        i_rst,
    // Start/continue the operation (the fpu's ds_valid).
    input  wire        i_valid,
    // The instruction in EX moves to MEM at the next edge.
    input  wire        i_advance,
    // 1: square root of a. 0: a / b.
    input  wire        i_sqrt,
    input  wire        i_a_sign,
    input  wire [ 9:0] i_a_exp,
    input  wire [23:0] i_a_sig,
    input  wire        i_b_sign,
    input  wire [ 9:0] i_b_exp,
    input  wire [23:0] i_b_sig,
    output wire        o_busy,
    output wire        o_sign,
    output wire [ 9:0] o_exp,
    output wire [25:0] o_sig
);

    // ------------------------------------------------------------------
    // Set-up, computed from the operands on the start cycle.
    // ------------------------------------------------------------------
    // Divide: prescale a by 2 when a_sig < b_sig, so the quotient lands
    // in [1, 2) and its first bit is always 1.
    wire        a_lt_b   = (i_a_sig < i_b_sig);
    wire [25:0] div_rem0 = a_lt_b ? {1'b0, i_a_sig, 1'b0} : {2'b00, i_a_sig};
    wire [ 9:0] div_exp  = i_a_exp - i_b_exp + 10'd127 - {9'd0, a_lt_b};

    // Square root: make the unbiased exponent even by doubling the
    // significand when it is odd, then halve it. The radicand m is in
    // [1, 4), so its root is in [1, 2).
    wire [ 9:0] sq_unb   = i_a_exp - 10'd127;
    wire        sq_odd   = sq_unb[0];
    wire [ 9:0] sq_even  = sq_unb - {9'd0, sq_odd};
    wire [ 9:0] sq_exp   = {sq_even[9], sq_even[9:1]} + 10'd127;
    // m = sig_scaled / 2^23. The radicand X = m * 2^48 = sig_scaled * 2^25,
    // so its 25-bit integer root is sqrt(m) * 2^24.
    wire [24:0] sq_scaled = sq_odd ? {i_a_sig, 1'b0} : {1'b0, i_a_sig};
    wire [49:0] sq_rad0   = {sq_scaled, 25'd0};

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    reg         running;   // stepping
    reg         done;      // finished, result held until i_advance
    reg  [ 2:0] count;     // groups of three remaining bits processed, 0..7
    reg         mode_sqrt;
    reg         res_sign;
    reg  [ 9:0] res_exp;
    reg  [27:0] rem;       // partial remainder
    reg  [24:0] res;       // quotient or root bits so far
    reg  [23:0] divisor;
    reg  [49:0] radicand;  // square root: bit pairs still to bring down

    // ------------------------------------------------------------------
    // The normalized answer is in [1, 2). Its first bit is one, so the
    // launch edge can capture the state just after that first subtraction.
    // Division carries twice the remainder into the next bit. Square root
    // consumes the top radicand pair and subtracts the first trial (one).
    wire [25:0] div_first_rem = div_rem0 - {2'b0, i_b_sig};
    wire [1:0]  sq_first_rem = sq_rad0[49:48] - 2'd1;

    // Each stage uses a single trial subtraction for either operation.
    // The borrow selects the restored remainder and the next result bit.
    wire [27:0] step_rem [0:3];
    wire [24:0] step_res [0:3];
    wire [49:0] step_rad [0:3];
    assign step_rem[0] = rem;
    assign step_res[0] = res;
    assign step_rad[0] = radicand;
    genvar bit_index;
    generate
        for (bit_index = 0; bit_index < 3; bit_index = bit_index + 1) begin : restore
            wire [27:0] partial = mode_sqrt ?
                {step_rem[bit_index][25:0], step_rad[bit_index][49:48]} : step_rem[bit_index];
            wire [27:0] trial = mode_sqrt ? {1'b0, step_res[bit_index], 2'b01} :
                                            {4'b0, divisor};
            wire [28:0] diff = {1'b0, partial} - {1'b0, trial};
            wire take_bit = ~diff[28];
            wire [27:0] restored = take_bit ? diff[27:0] : partial;
            assign step_rem[bit_index+1] = mode_sqrt ? restored : {restored[26:0], 1'b0};
            assign step_res[bit_index+1] = {step_res[bit_index][23:0], take_bit};
            assign step_rad[bit_index+1] = {step_rad[bit_index][47:0], 2'b00};
        end
    endgenerate

    wire        start = i_valid & ~running & ~done;

    always @(posedge i_clk) begin
        if (i_rst | i_advance | ~i_valid) begin
            running <= 1'b0;
            done    <= 1'b0;
            count   <= 3'd0;
        end else if (start) begin
            running   <= 1'b1;
            count     <= 3'd0;
            mode_sqrt <= i_sqrt;
            res_sign  <= i_sqrt ? 1'b0 : (i_a_sign ^ i_b_sign);
            res_exp   <= i_sqrt ? sq_exp : div_exp;
            rem       <= i_sqrt ? {26'd0, sq_first_rem} : {1'b0, div_first_rem, 1'b0};
            res       <= 25'd1;
            divisor   <= i_b_sig;
            radicand  <= {sq_rad0[47:0], 2'b00};
        end else if (running) begin
            rem      <= step_rem[3];
            res      <= step_res[3];
            radicand <= step_rad[3];
            count    <= count + 3'd1;
            if (count == 3'd7) begin
                running <= 1'b0;
                done    <= 1'b1;
            end
        end
    end

    assign o_busy = i_valid & ~done;
    assign o_sign = res_sign;
    assign o_exp  = res_exp;
    // The divide remainder is kept shifted left once, which doesn't change
    // whether it is zero.
    assign o_sig  = {res, |rem};

endmodule

`default_nettype wire
