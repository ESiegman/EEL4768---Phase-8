`timescale 1ns / 1ps
`default_nettype none
module rat_tb;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst;
    reg [4:0] rs1, rs2, frs1, frs2, frs3;
    reg ren_v, fren_v, clr_v, fclr_v;
    reg [4:0] ren_i, fren_i, clr_i, fclr_i;
    reg [2:0] ren_t, fren_t, clr_t, fclr_t;

    wire rs1_b, rs2_b, frs1_b, frs2_b, frs3_b;
    wire [2:0] rs1_t, rs2_t, frs1_t, frs2_t, frs3_t;

    integer passed = 0;
    integer failed = 0;

    rat dut (
        .i_clk(clk),
        .i_rst(rst),
        .i_rs1_idx(rs1), .o_rs1_busy(rs1_b), .o_rs1_tag(rs1_t),
        .i_rs2_idx(rs2), .o_rs2_busy(rs2_b), .o_rs2_tag(rs2_t),
        .i_frs1_idx(frs1), .o_frs1_busy(frs1_b), .o_frs1_tag(frs1_t),
        .i_frs2_idx(frs2), .o_frs2_busy(frs2_b), .o_frs2_tag(frs2_t),
        .i_frs3_idx(frs3), .o_frs3_busy(frs3_b), .o_frs3_tag(frs3_t),
        .i_ren_valid(ren_v), .i_ren_idx(ren_i), .i_ren_tag (ren_t),
        .i_fren_valid(fren_v), .i_fren_idx(fren_i), .i_fren_tag(fren_t),
        .i_clr_valid(clr_v), .i_clr_idx (clr_i), .i_clr_tag(clr_t),
        .i_fclr_valid(fclr_v), .i_fclr_idx(fclr_i), .i_fclr_tag(fclr_t)
    );

    // ---------------------------------------------------------------------
    // Reference model
    // ---------------------------------------------------------------------
    reg m_xb [0:31];
    reg [2:0] m_xt [0:31];
    reg m_fb [0:31];
    reg [2:0] m_ft [0:31];
    integer k;

    always @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < 32; k = k + 1) begin
                m_xb[k] <= 1'b0; m_xt[k] <= 3'd0;
                m_fb[k] <= 1'b0; m_ft[k] <= 3'd0;
            end
        end else begin
            // Clear first, rename second: a same-register rename overrides.
            if (clr_v && clr_i != 5'd0 && m_xt[clr_i] == clr_t) m_xb[clr_i] <= 1'b0;
            if (fclr_v && m_ft[fclr_i] == fclr_t) m_fb[fclr_i] <= 1'b0;
            if (ren_v && ren_i != 5'd0) begin 
              m_xb[ren_i] <= 1'b1; m_xt[ren_i] <= ren_t; 
            end
          
            if (fren_v) begin
              m_fb[fren_i] <= 1'b1; m_ft[fren_i] <= fren_t; 
            end
        end
    end

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    task check;
        input ok;
        input [511:0] why;
        begin
            if (ok === 1'b1) passed = passed + 1;
            else begin
                failed = failed + 1;
                $display("[FAIL] %0s  (t=%0t)", why, $time);
            end
        end
    endtask

    task idle; // no rename / clear this cycle
        begin
            ren_v = 0; fren_v = 0; clr_v = 0; fclr_v = 0;
        end
    endtask

    // Apply the current inputs for one clock edge, then settle.
    task tick;
        begin
            @(posedge clk); #1;
        end
    endtask

    // Look up one integer and one FP register on every port and compare to
    // the values worked out by hand.
    task expect_x;
        input [4:0] idx; input busy; input [2:0] tag; input [511:0] why;
        begin
            rs1 = idx; rs2 = idx; #1;
            check(rs1_b == busy && rs2_b == busy && (!busy || (rs1_t == tag && rs2_t == tag)), why);
        end
    endtask

    task expect_f;
        input [4:0] idx; input busy; input [2:0] tag; input [511:0] why;
        begin
            frs1 = idx; frs2 = idx; frs3 = idx; #1;
            check(frs1_b == busy && frs2_b == busy && frs3_b == busy && (!busy || (frs1_t == tag && frs2_t == tag && frs3_t == tag)), why);
        end
    endtask

    // Every register, every port, against the model (tags compared even
    // when not busy: reset defines them as 0 and a clear leaves them alone).
    task sweep;
        input [511:0] why;
        integer r, bad;
        begin
            bad = 0;
            for (r = 0; r < 32; r = r + 1) begin
                rs1 = r; rs2 = r; frs1 = r; frs2 = r; frs3 = r; #1;
                if (rs1_b !== m_xb[r] || rs2_b !== m_xb[r] ||
                    rs1_t !== m_xt[r] || rs2_t !== m_xt[r] ||
                    frs1_b !== m_fb[r] || frs2_b !== m_fb[r] || frs3_b !== m_fb[r] ||
                    frs1_t !== m_ft[r] || frs2_t !== m_ft[r] || frs3_t !== m_ft[r]) begin
                    if (bad < 4)
                        $display("       r%0d: x busy/tag %b/%0d (model %b/%0d), f busy/tag %b/%0d (model %b/%0d)",
                                 r, rs1_b, rs1_t, m_xb[r], m_xt[r], frs1_b, frs1_t, m_fb[r], m_ft[r]);
                    bad = bad + 1;
                end
            end
            check(bad == 0, why);
        end
    endtask

    task rename_x;
        input [4:0] idx; input [2:0] tag;
        begin idle; ren_v = 1; ren_i = idx; ren_t = tag; tick; idle; end
    endtask

    task clear_x;
        input [4:0] idx; input [2:0] tag;
        begin idle; clr_v = 1; clr_i = idx; clr_t = tag; tick; idle; end
    endtask

    task rename_f;
        input [4:0] idx; input [2:0] tag;
        begin idle; fren_v = 1; fren_i = idx; fren_t = tag; tick; idle; end
    endtask

    task clear_f;
        input [4:0] idx; input [2:0] tag;
        begin idle; fclr_v = 1; fclr_i = idx; fclr_t = tag; tick; idle; end
    endtask

    task do_reset;
        begin
            idle; rst = 1; tick; tick; rst = 0;
        end
    endtask

    // ---------------------------------------------------------------------
    // Test program
    // ---------------------------------------------------------------------
    integer i, seed;

    initial begin
        $dumpfile("rat.vcd");
        $dumpvars(0, rat_tb);

        rst = 0; idle;
        rs1 = 0; rs2 = 0; frs1 = 0; frs2 = 0; frs3 = 0;
        ren_i = 0; fren_i = 0; clr_i = 0; fclr_i = 0;
        ren_t = 0; fren_t = 0; clr_t = 0; fclr_t = 0;

        $display("========== rat testbench ==========");

        // --- reset -----------------------------------------------------
        $display("--- reset ---");
        do_reset;
        sweep("reset: all 63 registers free, tags 0");

        // --- basic rename / clear ---------------------------------------
        $display("--- rename / clear ---");
        rename_x(5'd5, 3'd3);
        expect_x(5'd5, 1, 3'd3, "rename x5 -> tag 3 is busy with tag 3 on rs1 and rs2");
        expect_x(5'd6, 0, 3'd0, "neighbour x6 untouched");
        expect_f(5'd5, 0, 3'd0, "f5 untouched by an integer rename");
        clear_x(5'd5, 3'd2);
        expect_x(5'd5, 1, 3'd3, "commit with stale tag 2 leaves x5 busy with tag 3");
        clear_x(5'd5, 3'd3);
        expect_x(5'd5, 0, 3'd3, "commit with matching tag 3 frees x5");
        clear_x(5'd5, 3'd3);
        expect_x(5'd5, 0, 3'd3, "clearing an already free register is harmless");

        // --- x0 ------------------------------------------------------------
        $display("--- x0 ---");
        rename_x(5'd0, 3'd4);
        expect_x(5'd0, 0, 3'd0, "rename of x0 is ignored");
        clear_x(5'd0, 3'd0);
        expect_x(5'd0, 0, 3'd0, "clear of x0 is ignored");

        // --- f0 is an ordinary register ------------------------------------
        $display("--- FP map ---");
        rename_f(5'd0, 3'd6);
        expect_f(5'd0, 1, 3'd6, "f0 can be renamed (tag 6)");
        expect_x(5'd0, 0, 3'd0, "x0 still free after an f0 rename");
        rename_f(5'd31, 3'd1);
        expect_f(5'd31, 1, 3'd1, "f31 renamed to tag 1");
        clear_f(5'd0, 3'd1);
        expect_f(5'd0, 1, 3'd6, "f0 stays busy on a commit with another register's tag");
        clear_f(5'd0, 3'd6);
        expect_f(5'd0, 0, 3'd0, "f0 freed by its own tag");
        expect_f(5'd31, 1, 3'd1, "f31 unaffected by the f0 clear");

        // --- WAW: younger rename survives the older commit ---------------
        $display("--- WAW / stale commit ---");
        rename_x(5'd7, 3'd1);
        rename_x(5'd7, 3'd4);
        expect_x(5'd7, 1, 3'd4, "second rename of x7 overwrites the tag (4)");
        clear_x(5'd7, 3'd1);
        expect_x(5'd7, 1, 3'd4, "older producer (tag 1) commits: x7 stays busy on tag 4");
        clear_x(5'd7, 3'd4);
        expect_x(5'd7, 0, 3'd0, "youngest producer commits: x7 free");

        // --- rename beats a same-cycle clear ------------------------------
        $display("--- same-cycle rename and clear ---");
        rename_x(5'd9, 3'd2);
        idle; ren_v = 1; ren_i = 5'd9; ren_t = 3'd5; clr_v = 1; clr_i = 5'd9; clr_t = 3'd2; tick; idle;
        expect_x(5'd9, 1, 3'd5, "x9: rename (tag 5) and matching clear (tag 2) together -> rename wins");
        rename_f(5'd9, 3'd2);
        idle; fren_v = 1; fren_i = 5'd9; fren_t = 3'd5; fclr_v = 1; fclr_i = 5'd9; fclr_t = 3'd2; tick; idle;
        expect_f(5'd9, 1, 3'd5, "f9: rename and matching clear together -> rename wins");

        // --- rename one register while another commits --------------------
        rename_x(5'd10, 3'd0);
        idle; ren_v = 1; ren_i = 5'd11; ren_t = 3'd1; clr_v = 1; clr_i = 5'd10; clr_t = 3'd0; tick; idle;
        expect_x(5'd10, 0, 3'd0, "x10 committed while x11 renamed in the same cycle");
        expect_x(5'd11, 1, 3'd1, "x11 renamed while x10 committed in the same cycle");

        // --- all four ports at once ---------------------------------------
        idle;
        ren_v = 1; ren_i = 5'd20; ren_t = 3'd7;
        fren_v = 1; fren_i = 5'd20; fren_t = 3'd6;
        tick; idle;
        expect_x(5'd20, 1, 3'd7, "simultaneous int and FP renames: x20 -> 7");
        expect_f(5'd20, 1, 3'd6, "simultaneous int and FP renames: f20 -> 6");
        clr_v = 1; clr_i = 5'd20; clr_t = 3'd7;
        fclr_v = 1; fclr_i = 5'd20; fclr_t = 3'd6;
        tick; idle;
        expect_x(5'd20, 0, 3'd0, "simultaneous commits free x20");
        expect_f(5'd20, 0, 3'd0, "simultaneous commits free f20");

        // --- lookups see the table before this cycle's rename -------------
        $display("--- lookup timing ---");
        idle; ren_v = 1; ren_i = 5'd12; ren_t = 3'd3; rs1 = 5'd12; #1;
        check(rs1_b == 1'b0, "a lookup in the rename cycle still sees the old (free) mapping");
        tick; idle; #1;
        check(rs1_b == 1'b1 && rs1_t == 3'd3, "the rename is visible the cycle after");

        // --- different ports, different registers --------------------------
        rename_x(5'd13, 3'd2);
        rs1 = 5'd12; rs2 = 5'd13; #1;
        check(rs1_b && rs1_t == 3'd3 && rs2_b && rs2_t == 3'd2, "rs1 and rs2 look up independent registers");
        rename_f(5'd1, 3'd1); rename_f(5'd2, 3'd2); rename_f(5'd3, 3'd3);
        frs1 = 5'd1; frs2 = 5'd2; frs3 = 5'd3; #1;
        check(frs1_t == 3'd1 && frs2_t == 3'd2 && frs3_t == 3'd3 && frs1_b && frs2_b && frs3_b,
              "frs1/frs2/frs3 look up independent registers");

        // --- every register can be renamed and freed ----------------------
        $display("--- all registers ---");
        do_reset;
        for (i = 0; i < 32; i = i + 1) begin
            idle;
            ren_v = 1; ren_i = i; ren_t = i;
            fren_v = 1; fren_i = i; fren_t = ~i;
            tick;
        end
        idle;
        sweep("rename every register (x tag = i mod 8, f tag = ~i)");
        for (i = 0; i < 32; i = i + 1) begin
            idle;
            clr_v = 1; clr_i = i; clr_t = i;
            fclr_v = 1; fclr_i = i; fclr_t = ~i;
            tick;
        end
        idle;
        sweep("commit every register with its own tag -> all free");

        // --- reset in the middle of traffic -------------------------------
        rename_x(5'd3, 3'd3); rename_f(5'd4, 3'd4);
        idle; rst = 1; ren_v = 1; ren_i = 5'd8; ren_t = 3'd1; tick; rst = 0; idle;
        sweep("reset overrides a same-cycle rename and clears everything");

        // --- random traffic against the model -----------------------------
        $display("--- random ---");
        seed = 32'd4768;
        do_reset;
        for (i = 0; i < 20000; i = i + 1) begin
            @(negedge clk);
            rst = (($random(seed) & 1023) == 0);
            ren_v  = $random(seed); fren_v = $random(seed);
            clr_v  = $random(seed); fclr_v = $random(seed);
            // A small register pool most of the time, so renames, stale and
            // matching commits of the same register collide often.
            ren_i = ($random(seed) & 1) ? ($random(seed) & 3) : $random(seed);
            clr_i = ($random(seed) & 1) ? ($random(seed) & 3) : $random(seed);
            fren_i = ($random(seed) & 1) ? ($random(seed) & 3) : $random(seed);
            fclr_i = ($random(seed) & 1) ? ($random(seed) & 3) : $random(seed);
            ren_t = $random(seed); fren_t = $random(seed);
            // Half the commits use the register's current tag (from the
            // model), so the matching-tag path is exercised heavily.
            clr_t  = ($random(seed) & 1) ? m_xt[clr_i] : $random(seed);
            fclr_t = ($random(seed) & 1) ? m_ft[fclr_i] : $random(seed);
            rs1 = $random(seed); rs2 = $random(seed);
            frs1 = $random(seed); frs2 = $random(seed); frs3 = $random(seed);
            #1;
            if (rs1_b !== m_xb[rs1] || rs1_t !== m_xt[rs1] ||
                rs2_b !== m_xb[rs2] || rs2_t !== m_xt[rs2] ||
                frs1_b !== m_fb[frs1] || frs1_t !== m_ft[frs1] ||
                frs2_b !== m_fb[frs2] || frs2_t !== m_ft[frs2] ||
                frs3_b !== m_fb[frs3] || frs3_t !== m_ft[frs3]) begin
                failed = failed + 1;
                $display("[FAIL] random cycle %0d: lookup mismatch (rs1=%0d busy %b tag %0d, model %b %0d)",
                         i, rs1, rs1_b, rs1_t, m_xb[rs1], m_xt[rs1]);
            end else begin
                passed = passed + 1;
            end
            if ((i % 1000) == 999) begin
                @(negedge clk); idle; rst = 0;
                sweep("random: periodic full-table sweep");
            end
        end
        @(negedge clk); idle; rst = 0;
        sweep("random: final full-table sweep");
        $display("20000 random cycles checked against the model");

        // --- verdict ------------------------------------------------------
        $display("===================================");
        $display("%0d passed, %0d failed", passed, failed);
        if (failed == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");
        $finish;
    end

endmodule

`default_nettype wire
