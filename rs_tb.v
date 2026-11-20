`timescale 1ns/1ps
module rs_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, issue, cdb, grant;
    reg [2:0] head, itag, ctag;
    reg [31:0] inst, pc, cv;
    reg [1:0] waits;
    reg [5:0] qtags;
    reg [63:0] values;
    wire accept, dispatch, resolve, redirect, rtrap, valid, trap;
    wire [2:0] dtag, btag, tag;
    wire [31:0] next_pc, value, ri, rp;
    wire [4:0] rd;
    wire [63:0] operands;
    integer passed = 0, failed = 0, n;
    rs dut (
        .i_clk(clk), .i_rst(rst), .i_rob_head(head),
        .i_issue_valid(issue), .o_issue_ready(accept), .i_issue_tag(itag),
        .i_issue_inst(inst), .i_issue_pc(pc), .i_issue_wait(waits),
        .i_issue_qtags(qtags), .i_issue_values(values),
        .i_cdb_valid(cdb), .i_cdb_tag(ctag), .i_cdb_value(cv),
        .o_dispatch_valid(dispatch), .o_dispatch_tag(dtag),
        .o_resolve_valid(resolve), .o_redirect(redirect), .o_resolve_tag(btag),
        .o_resolve_next_pc(next_pc), .o_resolve_trap(rtrap),
        .o_result_valid(valid), .i_result_grant(grant), .o_result_tag(tag),
        .o_result_value(value), .o_result_inst(ri), .o_result_pc(rp),
        .o_result_rd(rd), .o_result_trap(trap), .o_result_operands(operands)
    );
    task tick;
        begin @(posedge clk); #1; @(negedge clk); #1; end
    endtask
    task check;
        input ok;
        input [8*90-1:0] why;
        begin
            if (ok === 1'b1) passed = passed + 1;
            else begin failed = failed + 1; $display("FAIL: %0s at %0t", why, $time); end
        end
    endtask
    task reset;
        begin
            rst=1; issue=0; cdb=0; grant=0; head=6;
            itag=0; ctag=0; inst=0; pc=32'h1000; cv=0;
            waits=0; qtags=0; values=0; tick; rst=0; #1;
        end
    endtask
    task enqueue;
        input [2:0] t;
        input [31:0] ins, a, b;
        input [1:0] w;
        begin
            itag=t; inst=ins; values={b,a}; waits=w; issue=1; #1;
            check(accept, "issue accepted"); tick; issue=0; #1;
        end
    endtask
    task expect_result;
        input [2:0] t;
        input [31:0] v;
        begin #1; check(valid && tag==t && value==v, "result tag/value"); end
    endtask
    task single;
        input [31:0] ins, a, b, v;
        input ctl, red, tr;
        input [31:0] npc;
        begin
            reset;
            check(!dispatch && !valid, "empty RS cannot dispatch or complete");
            enqueue(6, ins, a, b, 0);
            check(dispatch && !valid, "issue then dispatch then registered complete");
            check(resolve==ctl && redirect==red && rtrap==tr, "control resolve qualifiers");
            if (ctl) check(next_pc==npc && btag==6, "branch resolve PC/tag");
            tick; expect_result(6,v);
            check(trap==tr && operands=={b,a} && rp==32'h1000 && ri==ins,
                  "registered result metadata");
            repeat (3) begin tick; expect_result(6,v); end
            grant=1; tick; check(!valid, "grant consumes result exactly once");
        end
    endtask
    initial begin
        #1; reset;
        // A held result blocks dispatch while four queue entries fill.
        enqueue(6,32'h00108193,4,0,0); tick; expect_result(6,5);
        qtags={3'd5,3'd5};
        enqueue(7,32'h002081b3,0,0,3);
        enqueue(0,32'h002081b3,3,4,0);
        enqueue(1,32'h002081b3,0,0,3);
        enqueue(2,32'h002081b3,0,0,3);
        check(!accept && !dispatch, "four entries full under CDB backpressure");
        cdb=1; ctag=5; cv=10; tick; cdb=0;
        grant=1; tick; expect_result(7,20);
        tick; expect_result(0,7);
        tick; expect_result(1,20);
        tick; expect_result(2,20);
        tick; check(!valid, "drained all entries");
        // Catch a broadcast concurrent with allocation (no later rebroadcast).
        cdb=1; ctag=4; cv=11; qtags={3'd4,3'd4}; grant=0;
        enqueue(3,32'h002081b3,0,0,3); cdb=0;
        tick; expect_result(3,22);
        check(operands=={32'd11,32'd11}, "issue-cycle CDB bypass snapshots operands");
        // A younger ready entry bypasses an older waiting one.
        reset; qtags=6'd5;
        enqueue(6,32'h00108193,0,0,1);
        enqueue(7,32'h00108193,8,0,0);
        check(dispatch && dtag==7, "younger ready dispatches before older waiting entry");
        tick; expect_result(7,9);
        cdb=1; ctag=5; cv=30; tick; cdb=0; grant=1;
        tick; expect_result(6,31);
        // Keep all four RS slots occupied while a long DIV owns the ALU.
        reset;
        enqueue(6,{7'h01,5'd2,5'd1,3'b100,5'd3,7'h33},100,7,0);
        tick; check(!valid && !dispatch, "multiply/divide holds ALU");
        enqueue(7,32'h00108193,20,0,0);
        enqueue(0,32'h00108193,30,0,0);
        enqueue(1,32'h00108193,40,0,0);
        check(!accept, "running multiply/divide retains its RS slot");
        n=0;
        while (!valid && n<50) begin
            check(!dispatch, "no other ALU dispatch while divide runs"); tick; n=n+1;
        end
        expect_result(6,14);
        repeat (4) begin tick; expect_result(6,14); end
        grant=1; tick; expect_result(7,21);
        tick; expect_result(0,31); tick; expect_result(1,41);
        // Integer addressing, links, signed/unsigned branches and IALIGN.
        single(32'h123451b7,0,0,32'h12345000,0,0,0,0); // LUI
        single(32'h00002197,0,0,32'h3000,0,0,0,0); // AUIPC
        single(32'h4020d193,32'h80000000,0,32'he0000000,0,0,0,0); // SRAI
        single(32'h00208463,5,5,0,1,1,0,32'h1008); // BEQ +8
        single(32'h00209463,5,5,0,1,0,0,32'h1004); // BNE +8
        single(32'h0020c463,32'hffffffff,1,0,1,1,0,32'h1008); // BLT
        single(32'h0020e463,32'hffffffff,1,0,1,0,0,32'h1004); // BLTU
        single(32'h008001ef,0,0,32'h1004,1,1,0,32'h1008); // JAL
        single(32'h000081e7,32'h2001,0,32'h1004,1,1,0,32'h2000); // JALR
        single(32'h002001ef,0,0,32'h1004,1,0,1,32'h1004); // JAL +2 trap
        single(32'h00208163,1,2,0,1,0,0,32'h1004); // untaken BEQ +2
        reset; check(!valid && !resolve, "reset cancels outstanding work");
        $display("%0d passed, %0d failed",passed,failed);
        if (failed==0) $display("ALL TESTS PASSED"); else $display("TEST FAILED");
        $finish;
    end
    initial begin #100000; $display("TEST FAILED: timeout"); $finish; end
endmodule
