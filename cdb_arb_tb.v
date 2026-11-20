`timescale 1ns / 1ps
`default_nettype none

//Testbench for cdb_arb.v
module cdb_arb_tb;

    reg [2:0] head;
    reg int_v, fp0_v, fp1_v, ld_v;
    reg [2:0] int_t, fp0_t, fp1_t, ld_t;
    reg [31:0] int_d, fp0_d, fp1_d, ld_d;
    reg [ 4:0] fp0_f, fp1_f;

    wire g_int, g_fp0, g_fp1, g_ld;
    wire valid;
    wire [2:0] tag;
    wire [31:0] value;
    wire [4:0] fflags;

    integer passed = 0;
    integer failed = 0;

    cdb_arb #(.TAG_W(3)) dut (
        .i_rob_head(head),
        .i_int_v(int_v), .i_int_tag(int_t), .i_int_value(int_d),
        .i_fp0_v(fp0_v), .i_fp0_tag(fp0_t), .i_fp0_value(fp0_d), .i_fp0_flags(fp0_f),
        .i_fp1_v(fp1_v), .i_fp1_tag(fp1_t), .i_fp1_value(fp1_d), .i_fp1_flags(fp1_f),
        .i_ld_v(ld_v), .i_ld_tag (ld_t), .i_ld_value (ld_d),
        .o_int_grant(g_int),
        .o_fp0_grant(g_fp0),
        .o_fp1_grant(g_fp1),
        .o_ld_grant(g_ld),
        .o_cdb_valid(valid),
        .o_cdb_tag(tag),
        .o_cdb_value(value),
        .o_cdb_fflags(fflags)
    );

    // ---------------------------------------------------------------------
    // Reference model: returns {grant[3:0]} one-hot (bit 0 = int ... bit 3 = ld).
    // ---------------------------------------------------------------------
    function [3:0] model_grant;
        input [2:0] h;
        input [3:0] v;
        input [2:0] t0, t1, t2, t3;
        reg [2:0] tg [0:3];
        reg [2:0] best_age, age;
        integer j, best;
        begin
            tg[0] = t0; tg[1] = t1; tg[2] = t2; tg[3] = t3;
            best = -1; best_age = 3'd7;
            for (j = 0; j < 4; j = j + 1) begin
                age = tg[j] - h;  // 3-bit wrap = mod 8
                if (v[j] && (best < 0 || age < best_age)) begin
                    best = j; best_age = age;
                end
            end
            model_grant = (best < 0) ? 4'b0000 : (4'b0001 << best);
        end
    endfunction

    // Compare every output against the model for the current inputs.
    task check_now;
        input [511:0] why;
        input verbose;
        reg [ 3:0] eg;
        reg [ 2:0] et;
        reg [31:0] ed;
        reg [ 4:0] ef;
        reg ok;
        begin
            #1;
            eg = model_grant(head, {ld_v, fp1_v, fp0_v, int_v}, int_t, fp0_t, fp1_t, ld_t);
            et = eg[0] ? int_t : eg[1] ? fp0_t : eg[2] ? fp1_t : eg[3] ? ld_t : 3'd0;
            ed = eg[0] ? int_d : eg[1] ? fp0_d : eg[2] ? fp1_d : eg[3] ? ld_d : 32'd0;
            ef = eg[1] ? fp0_f : eg[2] ? fp1_f : 5'd0;
            ok = ({g_ld, g_fp1, g_fp0, g_int} === eg) && (valid === (eg != 4'b0)) &&
                 (tag === et) && (value === ed) && (fflags === ef);
            if (ok) passed = passed + 1;
            else begin
                failed = failed + 1;
                if (verbose || failed < 10) begin
                    $display("[FAIL] %0s", why);
                    $display("         head=%0d v(int,fp0,fp1,ld)=%b%b%b%b tags=%0d,%0d,%0d,%0d",
                             head, int_v, fp0_v, fp1_v, ld_v, int_t, fp0_t, fp1_t, ld_t);
                    $display("         grants(ld..int)=%b (expected %b) valid=%b tag=%0d (exp %0d) value=%h (exp %h) fflags=%b (exp %b)",
                             {g_ld, g_fp1, g_fp0, g_int}, eg, valid, tag, et, value, ed, fflags, ef);
                end
            end
        end
    endtask

    // Directed: set requests, then check the grant against a hand-worked
    // answer (in addition to the model).
    task directed;
        input [511:0] why;
        input [2:0] h;
        input [3:0] v;            // {ld, fp1, fp0, int}
        input [2:0] t_int, t_fp0, t_fp1, t_ld;
        input [3:0] expect_g;     // {ld, fp1, fp0, int}, worked out by hand
        begin
            head = h;
            {ld_v, fp1_v, fp0_v, int_v} = v;
            int_t = t_int; fp0_t = t_fp0; fp1_t = t_fp1; ld_t = t_ld;
            #1;
            if ({g_ld, g_fp1, g_fp0, g_int} === expect_g) passed = passed + 1;
            else begin
                failed = failed + 1;
                $display("[FAIL] %0s: grants(ld..int)=%b, expected %b", why,
                         {g_ld, g_fp1, g_fp0, g_int}, expect_g);
            end
            check_now(why, 1'b1);
        end
    endtask

    integer vv, hh, a, b, c, d, seed;

    initial begin
        $dumpfile("cdb_arb.vcd");
        $dumpvars(0, cdb_arb_tb);

        int_d = 32'hAAAA_0001; fp0_d = 32'hBBBB_0002; fp1_d = 32'hCCCC_0003; ld_d = 32'hDDDD_0004;
        fp0_f = 5'b10101; fp1_f = 5'b01011;

        $display("========== cdb_arb testbench ==========");

        // --- idle ----------------------------------------------------------
        $display("--- idle ---");
        directed("no requests -> no grant, bus reads zero", 3'd0, 4'b0000, 3'd1, 3'd2, 3'd3, 3'd4, 4'b0000);

        // --- single requester ---------------------------------------------
        $display("--- single requester ---");
        directed("ALU alone wins",  3'd2, 4'b0001, 3'd5, 3'd0, 3'd0, 3'd0, 4'b0001);
        directed("FP0 alone wins",  3'd2, 4'b0010, 3'd0, 3'd5, 3'd0, 3'd0, 4'b0010);
        directed("FP1 alone wins",  3'd2, 4'b0100, 3'd0, 3'd0, 3'd5, 3'd0, 4'b0100);
        directed("load alone wins", 3'd2, 4'b1000, 3'd0, 3'd0, 3'd0, 3'd5, 4'b1000);

        // --- oldest wins, head at 0 -----------------------------------------
        $display("--- oldest wins ---");
        directed("head 0: ALU tag 3 vs load tag 1 -> load (older)", 3'd0, 4'b1001, 3'd3, 3'd0, 3'd0, 3'd1, 4'b1000);
        directed("head 0: ALU tag 1 vs load tag 3 -> ALU (older)",  3'd0, 4'b1001, 3'd1, 3'd0, 3'd0, 3'd3, 4'b0001);
        directed("head 0: FP1 tag 0 is the head -> FP1",            3'd0, 4'b1111, 3'd4, 3'd5, 3'd0, 3'd6, 4'b0100);
        directed("head 0: all four, FP0 tag 2 oldest",              3'd0, 4'b1111, 3'd7, 3'd2, 3'd5, 3'd3, 4'b0010);

        // --- wrap-around: age is relative to the head, not the raw tag ------
        $display("--- wrap-around ---");
        directed("head 6: load tag 7 (age 1) beats ALU tag 1 (age 3)", 3'd6, 4'b1001, 3'd1, 3'd0, 3'd0, 3'd7, 4'b1000);
        directed("head 6: ALU tag 6 (age 0) beats load tag 0 (age 2)", 3'd6, 4'b1001, 3'd6, 3'd0, 3'd0, 3'd0, 4'b0001);
        directed("head 5: FP0 tag 5 (age 0) beats FP1 tag 4 (age 7)",  3'd5, 4'b0110, 3'd0, 3'd5, 3'd4, 3'd0, 4'b0010);
        directed("head 4: FP1 tag 2 (age 6) beats ALU tag 3 (age 7)",  3'd4, 4'b0101, 3'd3, 3'd0, 3'd2, 3'd0, 4'b0100);
        directed("head 7: FP0 raw tag 0 (age 1) beats load tag 1 (age 2)", 3'd7, 4'b1010, 3'd0, 3'd0, 3'd0, 3'd1, 4'b0010);
        directed("head 7: load raw tag 0 (age 1) beats FP0 tag 1 (age 2)", 3'd7, 4'b1010, 3'd0, 3'd1, 3'd0, 3'd0, 4'b1000);
        directed("head 7: tags 7,0,1,2 -> tag 7 (ALU) is oldest",      3'd7, 4'b1111, 3'd7, 3'd0, 3'd1, 3'd2, 4'b0001);
        directed("head 3: tags 2,1,0,7 -> tag 7 (load, age 4) oldest", 3'd3, 4'b1111, 3'd2, 3'd1, 3'd0, 3'd7, 4'b1000);

        // --- the two FP units contend ---------------------------------------
        $display("--- dual FPU ---");
        directed("FP0 tag 3 vs FP1 tag 2, head 1 -> FP1",      3'd1, 4'b0110, 3'd0, 3'd3, 3'd2, 3'd0, 4'b0100);
        directed("FP0 tag 2 vs FP1 tag 3, head 1 -> FP0",      3'd1, 4'b0110, 3'd0, 3'd2, 3'd3, 3'd0, 4'b0010);
        fp0_f = 5'b00001; fp1_f = 5'b10000;
        directed("fflags follow the winning FP unit (FP1)",    3'd0, 4'b0110, 3'd0, 3'd4, 3'd1, 3'd0, 4'b0100);
        directed("ALU winner drives fflags 0 even if FPs wait",3'd0, 4'b0111, 3'd0, 3'd4, 3'd1, 3'd0, 4'b0001);

        // --- invalid requesters are ignored, however old -------------------
        $display("--- valid gating ---");
        directed("an invalid requester with the head tag is ignored", 3'd0, 4'b1000, 3'd0, 3'd0, 3'd0, 3'd5, 4'b1000);
        directed("only invalid requesters -> no grant",               3'd3, 4'b0000, 3'd3, 3'd4, 3'd5, 3'd6, 4'b0000);

        // --- tie break (unreachable with unique ROB tags, but defined) -----
        $display("--- ties ---");
        directed("tie ALU/load on tag 2 -> ALU",  3'd0, 4'b1001, 3'd2, 3'd0, 3'd0, 3'd2, 4'b0001);
        directed("tie FP0/FP1 on tag 4 -> FP0",   3'd0, 4'b0110, 3'd0, 3'd4, 3'd4, 3'd0, 4'b0010);
        directed("tie FP1/load on tag 1 -> FP1",  3'd0, 4'b1100, 3'd0, 3'd0, 3'd1, 3'd1, 4'b0100);
        directed("all four on tag 6 -> ALU",      3'd0, 4'b1111, 3'd6, 3'd6, 3'd6, 3'd6, 4'b0001);

        // --- exhaustive against the model ------------------------------------
        $display("--- exhaustive (valid x tags x head) ---");
        seed = 32'd552;
        for (vv = 0; vv < 16; vv = vv + 1)
          for (hh = 0; hh < 8; hh = hh + 1)
            for (a = 0; a < 8; a = a + 1)
              for (b = 0; b < 8; b = b + 1)
                for (c = 0; c < 8; c = c + 1)
                  for (d = 0; d < 8; d = d + 1) begin
                      {ld_v, fp1_v, fp0_v, int_v} = vv;
                      head = hh; int_t = a; fp0_t = b; fp1_t = c; ld_t = d;
                      int_d = $random(seed); fp0_d = $random(seed);
                      fp1_d = $random(seed); ld_d  = $random(seed);
                      fp0_f = $random(seed); fp1_f = $random(seed);
                      check_now("exhaustive vector", 1'b0);
                  end
        $display("       524288 vectors checked against the model");

        // --- verdict ------------------------------------------------------
        $display("=======================================");
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule

`default_nettype wire
