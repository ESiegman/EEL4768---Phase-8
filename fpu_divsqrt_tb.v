`timescale 1ns/1ps
`default_nettype none

// The normalized inputs have unsigned 24-bit significands. Verify the
// *unrounded* answer using integer bounds, including the guard and sticky
// bits passed to the shared rounder. This oracle uses no restoring steps.
module fpu_divsqrt_tb;
    reg clk = 0, rst = 1, valid = 0, advance = 0;
    reg sqrt_op, sign_a, sign_b;
    reg [9:0] exp_a, exp_b;
    reg [23:0] sig_a, sig_b;
    wire busy, sign_out;
    wire [9:0] exp_out;
    wire [25:0] sig_out;
    fpu_divsqrt dut(.i_clk(clk), .i_rst(rst), .i_valid(valid), .i_advance(advance),
                    .i_sqrt(sqrt_op), .i_a_sign(sign_a), .i_a_exp(exp_a), .i_a_sig(sig_a),
                    .i_b_sign(sign_b), .i_b_exp(exp_b), .i_b_sig(sig_b), .o_busy(busy),
                    .o_sign(sign_out), .o_exp(exp_out), .o_sig(sig_out));
    always #5 clk = ~clk;

    integer passed = 0, failed = 0, seed = 4768, i;
    task check_result;
        input mode;
        input [23:0] a, b;
        input integer ea, eb;
        reg [63:0] numerator, q, lo, hi;
        reg [9:0] want_exp;
        reg want_sign, ok;
        integer cycles;
        begin
            sqrt_op = mode;
            exp_a = ea; exp_b = eb; sig_a = a; sig_b = b;
            sign_a = $random(seed); sign_b = $random(seed);
            valid = 1; advance = 0;
            want_sign = mode ? 1'b0 : sign_a ^ sign_b;
            if (mode) begin
                numerator = a;
                numerator = numerator << (25 + ((ea - 127) & 1));
                want_exp = ((ea - 127) >>> 1) + 127;
            end else begin
                numerator = a;
                numerator = numerator << (24 + (a < b));
                want_exp = ea - eb + 127 - (a < b);
            end
            #1;
            ok = busy === 1'b1;
            @(negedge clk);
            // Only the launch edge owns these inputs.
            sqrt_op = !mode; sig_a = ~a; sig_b = ~b;
            exp_a = ~exp_a; exp_b = ~exp_b; sign_a = ~sign_a; sign_b = ~sign_b;
            cycles = 1;
            while (busy === 1'b1 && cycles < 32) begin
                @(negedge clk); cycles = cycles + 1;
            end
            q = sig_out[25:1];
            lo = mode ? q * q : q * b;
            hi = mode ? (q + 1) * (q + 1) : (q + 1) * b;
            ok = ok && busy === 1'b0 && cycles == 9 && sign_out === want_sign &&
                 exp_out === want_exp && lo <= numerator && numerator < hi &&
                 sig_out[0] === (lo != numerator);
            if (ok) passed = passed + 1;
            else begin
                if (failed < 5) $display("[FAIL] sqrt=%b a=%h b=%h cycles=%d sig=%h", mode, a, b, cycles, sig_out);
                failed = failed + 1;
            end
            advance = 1;
            @(negedge clk);
        end
    endtask

    reg [23:0] a, b;
    integer ea, eb;
    initial begin
        @(negedge clk); rst = 0;
        for (i = 0; i < 10000; i = i + 1) begin
            a = $random(seed) | 24'h800000;
            b = $random(seed) | 24'h800000;
            ea = ({$random(seed)} % 277) - 22;
            eb = ({$random(seed)} % 277) - 22;
            // Include exact quotients, exact roots and exponent parity boundaries.
            if (i % 11 == 0) b = a;
            if (i % 13 == 0) a = 24'h800000;
            check_result(i[0], a, b, ea, eb);
        end
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0) $display("ALL TESTS PASSED");
        else $display("TEST FAILED");
        $finish;
    end
endmodule
`default_nettype wire
