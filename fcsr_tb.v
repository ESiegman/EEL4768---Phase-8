`timescale 1ns/1ps
module fcsr_tb;
    reg clk=0;
    always #5 clk=~clk;
    reg rst, valid, trap;
    reg [31:0] inst, src;
    reg [4:0] flags;
    wire [7:0] csr, next_csr;
    integer passed=0, failed=0, a, f, s;
    reg [7:0] model, old, operand, result, expected;
    fcsr dut(.i_clk(clk),.i_rst(rst),.i_commit_valid(valid),.i_commit_trap(trap),
             .i_commit_inst(inst),.i_commit_xrs1(src),.i_commit_flags(flags),
             .o_fcsr(csr),.o_next_fcsr(next_csr));
    task tick;
        begin @(posedge clk); #1; @(negedge clk); #1; end
    endtask
    task check;
        input ok;
        input [8*80-1:0] why;
        begin
            if (ok === 1'b1) passed=passed+1;
            else begin failed=failed+1; $display("FAIL: %0s got %h expected %h",why,csr,expected); end
        end
    endtask
    task commit;
        input [31:0] ins, x;
        input [4:0] ff;
        input tr;
        input [7:0] want;
        begin
            valid=1; inst=ins; src=x; flags=ff; trap=tr; expected=want; #1;
            check(csr==model,"no state change before commit edge");
            check(next_csr==want,"retire flags include current commit");
            tick; check(csr==want,"architectural CSR after commit"); model=want; valid=0;
        end
    endtask
    initial begin
        rst=1; valid=0; trap=0; inst=0; src=0; flags=0; model=0;
        tick; rst=0; expected=0; check(csr==0,"reset clears frm and flags");
        flags=5'h1f; repeat(3) tick;
        check(csr==0 && next_csr==0,"completion without commit cannot accrue flags");
        commit(32'h00000013,0,5'h08,0,8'h08);
        commit(32'h00000013,0,5'h01,0,8'h09);
        commit(32'h00000013,0,5'h10,1,8'h09);
        // Every CSR form/address, including rs1/uimm zero suppression,
        // rd=x0 writes, and truncation of fflags / frm / fcsr fields.
        for(a=1;a<=3;a=a+1) begin
            for(f=1;f<=7;f=f+1) begin
                if(f!=4) begin
                    for(s=0;s<=31;s=s+31) begin
                        old=(a==1) ? {3'd0,model[4:0]} :
                            (a==2) ? {5'd0,model[7:5]} : model;
                        operand=(f>=5) ? s : 8'he5;
                        result=((f&3)==1) ? operand : ((f&3)==2) ? old|operand : old&~operand;
                        expected=model;
                        if((f&3)==1 || s!=0) begin
                            if(a!=2) expected[4:0]=result[4:0];
                            if(a!=1) expected[7:5]=(a==2) ? result[2:0] : result[7:5];
                        end
                        commit((a<<20)|(s<<15)|(f<<12)|32'h73,32'he5,0,0,expected);
                    end
                end
            end
        end
        commit(32'h00309073,32'hff,0,1,model); // trapping CSR changes nothing
        rst=1; tick; expected=0; check(csr==0,"reset clears accumulated state");
        $display("%0d passed, %0d failed",passed,failed);
        if(failed==0) $display("ALL TESTS PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
