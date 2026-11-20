`timescale 1ns/1ps
module fp_rs_tb;
    reg clk=0;
    always #5 clk=~clk;
    reg rst, issue, cdb, empty, commit_valid, commit_trap;
    reg [2:0] head, itag, ctag, commit_tag;
    reg [31:0] inst, pc, cv, commit_inst, commit_x;
    reg [4:0] commit_flags;
    reg [2:0] waits;
    reg [8:0] qtags;
    reg [95:0] values;
    reg [1:0] grants;
    wire accept, serializing, dispatch, lane;
    wire [2:0] dtag;
    wire [1:0] valid, traps;
    wire [5:0] tags;
    wire [63:0] results, insts, pcs;
    wire [9:0] flags;
    wire [191:0] operands;
    wire [7:0] csr;
    integer passed=0, failed=0, n, selected;
    reg [31:0] held_result;
    reg [95:0] held_operands;
    localparam [31:0] FADD=32'h002081d3, FDIV=32'h182081d3;
    fp_rs dut (
        .i_clk(clk),.i_rst(rst),.i_rob_head(head),.i_rob_empty(empty),
        .i_issue_valid(issue),.o_issue_ready(accept),.i_issue_tag(itag),
        .i_issue_inst(inst),.i_issue_pc(pc),.i_issue_wait(waits),
        .i_issue_qtags(qtags),.i_issue_values(values),
        .i_cdb_valid(cdb),.i_cdb_tag(ctag),.i_cdb_value(cv),.i_fcsr(csr),
        .i_commit_valid(commit_valid),.i_commit_tag(commit_tag),
        .o_serializing(serializing),.o_dispatch_valid(dispatch),
        .o_dispatch_tag(dtag),.o_dispatch_lane(lane),
        .o_result_valid(valid),.i_result_grant(grants),.o_result_tag(tags),
        .o_result_value(results),.o_result_inst(insts),.o_result_pc(pcs),
        .o_result_flags(flags),.o_result_trap(traps),.o_result_operands(operands)
    );
    fcsr state (
        .i_clk(clk),.i_rst(rst),.i_commit_valid(commit_valid),
        .i_commit_trap(commit_trap),.i_commit_inst(commit_inst),
        .i_commit_xrs1(commit_x),.i_commit_flags(commit_flags),
        .o_fcsr(csr),.o_next_fcsr()
    );
    task tick;
        begin @(posedge clk); #1; @(negedge clk); #1; end
    endtask
    task check;
        input ok;
        input [8*96-1:0] why;
        begin
            if(ok === 1'b1) passed=passed+1;
            else begin failed=failed+1; $display("FAIL: %0s time %0t tags=%h results=%h",why,$time,tags,results); end
        end
    endtask
    task reset;
        begin
            rst=1; issue=0; cdb=0; empty=0; grants=0; head=6;
            itag=0; ctag=0; commit_valid=0; commit_trap=0; commit_tag=0;
            inst=0; pc=32'h1000; cv=0; waits=0; qtags=0; values=0;
            commit_inst=0; commit_x=0; commit_flags=0;
            tick; rst=0; #1;
        end
    endtask
    task enqueue;
        input [2:0] t;
        input [31:0] ins, a, b, c;
        input [2:0] w;
        begin
            itag=t; inst=ins; values={c,b,a}; waits=w; issue=1; #1;
            check(accept,"FP issue accepted"); tick; issue=0; #1;
        end
    endtask
    task await_result;
        input [2:0] t;
        input [31:0] value;
        input [4:0] ff;
        input trap;
        begin
            n=0;
            while(!((valid[0] && tags[2:0]==t) || (valid[1] && tags[5:3]==t)) && n<80)
                begin tick; n=n+1; end
            selected=(valid[0] && tags[2:0]==t) ? 0 : 1;
            check(valid[selected] && tags[3*selected +: 3]==t,"result arrives on one lane");
            check(results[32*selected +: 32]==value && flags[5*selected +: 5]==ff &&
                  traps[selected]==trap,"FP result, own flags and trap");
            check(pcs[32*selected +: 32]==32'h1000,"FP result PC metadata");
        end
    endtask
    task consume;
        begin
            grants=1<<selected; cdb=1; ctag=tags[3*selected +: 3];
            cv=results[32*selected +: 32]; tick; grants=0; cdb=0;
        end
    endtask
    task commit;
        input [2:0] t;
        input [31:0] ins, x;
        input [4:0] ff;
        input tr;
        begin
            commit_valid=1; commit_tag=t; commit_inst=ins;
            commit_x=x; commit_flags=ff; commit_trap=tr;
            tick; commit_valid=0;
        end
    endtask
    task one;
        input [31:0] ins,a,b,c,result;
        input [4:0] ff;
        begin
            enqueue(6,ins,a,b,c,0); await_result(6,result,ff,0);
            check(operands[96*selected +: 96]=={c,b,a},"FP operand snapshot"); consume;
        end
    endtask
    initial begin
        #1; reset;
        check(!dispatch && valid==0,"reset/empty cannot dispatch");
        // Both lanes can hold independent requests for one shared CDB.
        enqueue(6,FADD,32'h3f800000,32'h3f800000,0,0);
        enqueue(7,FADD,32'h3f800000,32'h40000000,0,0);
        n=0; while(valid!=3 && n<10) begin tick; n=n+1; end
        check(valid==3 && tags=={3'd7,3'd6},"both FP units request CDB concurrently");
        selected=0; consume;
        check(valid==2 && results[63:32]==32'h40400000,
              "granting one lane leaves the other request intact");
        selected=1; consume; check(valid==0,"second grant drains both requests");
        reset;
        // A younger add runs on lane 1 while an older finite divide runs
        // iteratively on lane 0, and requests the CDB first.
        enqueue(6,FDIV,32'h3f800000,32'h40400000,0,0); // 1/3 -> NX
        check(dispatch && !lane && !valid,"no same-cycle issue to complete");
        enqueue(7,FADD,32'h3f800000,32'h3f800000,0,0);
        check(dispatch && lane,"second FPU dispatch while first is busy");
        // Dependency waits on younger add, even while both lanes are busy.
        qtags=9'd7;
        enqueue(0,FADD,0,32'h3f800000,0,1);
        await_result(7,32'h40000000,0,0);
        check(!valid[0],"younger FP completes before older divide");
        held_result=results[63:32]; held_operands=operands[191:96];
        repeat(4) begin
            tick; check(valid[1] && results[63:32]==held_result &&
                        operands[191:96]==held_operands && tags[5:3]==7,
                        "losing CDB requester holds value and metadata");
        end
        check(csr==0,"FP completion has no architectural flags side effect");
        consume;
        await_result(0,32'h40400000,0,0);
        check(operands[96*selected +: 32]==32'h40000000,"CDB dependency value used"); consume;
        await_result(6,32'h3eaaaaab,5'h01,0); consume;
        check(csr==0,"both FP units leave fcsr unchanged before ROB commit");
        commit(6,FDIV,0,1,0); check(csr==1,"older instruction accrues NX at commit");
        commit(7,FADD,0,0,0); commit(0,FADD,0,0,0);
        check(csr==1,"younger flags do not overwrite accrued older flags");
        // All three FMA operands wake independently, including source 3.
        reset; qtags={3'd3,3'd2,3'd1};
        enqueue(6,32'h182081c3,0,0,0,7); // fmadd.s f3,f1,f2,f3
        cdb=1; ctag=1; cv=32'h3f800000; tick;
        ctag=2; cv=32'h40000000; tick;
        check(!dispatch,"FMA waits for third operand");
        ctag=3; cv=32'h40400000; tick; cdb=0;
        await_result(6,32'h40a00000,0,0); consume;
        // Allocation bypass must capture all matching source tags.
        cdb=1; ctag=5; cv=32'h40000000; qtags={3'd5,3'd5,3'd5};
        enqueue(7,FADD,0,0,0,3); cdb=0;
        await_result(7,32'h40800000,0,0); consume;
        one(32'hd00081d3,32'd3,0,0,32'h40400000,0); // fcvt.s.w
        one(32'hc00081d3,32'h40400000,0,0,32'd3,0); // fcvt.w.s
        one(32'he00081d3,32'hbf800000,0,0,32'hbf800000,0); // fmv.x.w
        one(32'hf00081d3,32'hdeadbeef,0,0,32'hdeadbeef,0); // fmv.w.x
        one(32'ha020a1d3,32'h3f800000,32'h3f800000,0,32'd1,0); // feq.s
        // A CSR must wait for ROB drain, then blocks younger issue until
        // its actual commit, not merely its CDB grant.
        reset; inst=32'h003091f3; issue=1; #1;
        check(!accept,"CSR admission waits for older ROB instructions");
        issue=0; empty=1;
        enqueue(6,32'h003091f3,32'h60,0,0,0); // csrrw x3,fcsr,x1 (RUP)
        check(serializing && !accept,"CSR blocks younger issue");
        await_result(6,0,0,0); consume;
        check(serializing && csr==0,"CSR CDB grant does not commit CSR state");
        commit(7,FADD,0,0,0); check(serializing,"unrelated commit cannot unlock CSR");
        commit(6,32'h003091f3,32'h60,0,0);
        check(!serializing && csr==8'h60,"matching CSR commit updates shared frm and unlocks issue");
        // Dynamic rounding consults shared frm; own flags exclude old flags.
        one(32'hd000f1d3,32'h01000001,0,0,32'h4b800001,1);
        commit(6,FADD,0,5'h10,0);
        one(FADD,32'h3f800000,32'h3f800000,0,32'h40000000,0);
        commit(6,32'h00209073,5,0,0); // frm=reserved
        enqueue(6,32'hd000f1d3,3,0,0,0);
        await_result(6,32'h40400000,0,1); consume;
        commit(6,32'hd000f1d3,3,0,1);
        check(csr==8'hb0,"trapped dynamic-rm op cannot modify shared state");
        // Fill all four slots with dependencies and test reset cancellation.
        reset; qtags=9'd5;
        enqueue(6,FADD,0,0,0,1); enqueue(7,FADD,0,0,0,1);
        enqueue(0,FADD,0,0,0,1); enqueue(1,FADD,0,0,0,1);
        check(!accept && !dispatch,"four waiting FP entries exert backpressure");
        // All four wake in the CDB cycle itself (same-cycle CDB bypass) and
        // the oldest by modular ROB age dispatches in that cycle.
        cdb=1; ctag=5; cv=32'h3f800000; #1;
        check(dispatch && dtag==6,"oldest ready uses modular ROB age");
        tick; cdb=0;
        reset; check(!serializing && valid==0 && !dispatch,"reset clears FP queue, lanes and CSR lock");
        enqueue(6,FDIV,32'h3f800000,32'h40400000,0,0); tick;
        reset; repeat(32) tick;
        check(valid==0,"reset aborts iterative FP work without a late result");
        $display("%0d passed, %0d failed",passed,failed);
        if(failed==0) $display("ALL TESTS PASSED"); else $display("TEST FAILED");
        $finish;
    end
    initial begin #100000; $display("TEST FAILED: timeout"); $finish; end
endmodule
