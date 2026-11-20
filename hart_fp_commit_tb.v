`timescale 1ns/1ps
// Regression for moving fcsr out of the phase-6 FPU: fflags and frm are
// architectural state, written in program order at commit, so CSR reads and
// dynamic rounding see only older committed FP instructions. The program has
// no loads or stores, so main memory is tied off.
module hart_fp_commit_tb;
    reg clk=0;
    always #5 clk=~clk;
    reg [31:0] program_words [0:31];
    reg rst=1;
    // Combinational instruction port, as on the phase 7 hart.
    wire [31:0] imem_addr;
    wire [31:0] imem_data = program_words[(imem_addr-32'h00400000)>>2];
    wire valid, trap, halt, fwen;
    wire [31:0] inst, xdata, fdata;
    wire [4:0] xrd, frd, flags;
    integer n, count=0, passed=0, failed=0;
    reg [4:0] expected_flags;
    hart #(.BLOCK_SIZE(16),.CACHE_SIZE(1),.NUM_WAYS(1)) dut (
        .i_clk(clk),.i_rst(rst),
        .o_imem_raddr(imem_addr),.i_imem_rdata(imem_data),
        .i_mem_ready(1'b1),.i_mem_valid(1'b0),.i_mem_rd_data(128'd0),
        .o_retire_valid(valid),.o_retire_inst(inst),.o_retire_trap(trap),
        .o_retire_halt(halt),.o_retire_rd_waddr(xrd),.o_retire_rd_wdata(xdata),
        .o_retire_frd_wen(fwen),.o_retire_frd_waddr(frd),
        .o_retire_frd_wdata(fdata),.o_retire_fflags(flags)
    );
    task check;
        input ok;
        input [8*80-1:0] why;
        begin
            if(ok === 1'b1) passed=passed+1;
            else begin failed=failed+1; $display("FAIL: %0s retire %0d inst %h flags %h xdata %h",why,count,inst,flags,xdata); end
        end
    endtask
    always @(posedge clk) begin
        if(!rst && valid) begin
            check(count<13 && inst==program_words[count],"retirement instruction order");
            check(!trap,"legal FP/CSR program does not trap");
            expected_flags=(count>=3 && count<=4) ? 5'h08 : (count>=9) ? 5'h01 : 0;
            check(flags==expected_flags,"fflags reflect each program-order commit");
            case(count)
                4: check(xrd==2 && xdata==8,"CSR sees older divide flags");
                6: check(xrd==3 && xdata==0,"CSR frm read uses committed prior clear");
                9: check(fwen && frd==3 && fdata==32'h4b800001,"dynamic rounding uses committed RUP");
                10: check(xrd==5 && xdata==32'h61,"CSR reads committed frm and NX");
                12: begin
                    check(halt,"program halts");
                    $display("%0d passed, %0d failed",passed,failed);
                    if(failed==0) $display("ALL TESTS PASSED"); else $display("TEST FAILED");
                    $finish;
                end
            endcase
            count=count+1;
        end
    end
    initial begin
        for(n=0;n<32;n=n+1) program_words[n]=32'h00000013;
        program_words[0]=32'h3f8000b7; // lui x1,0x3f800 (1.0 bits)
        program_words[1]=32'hf00080d3; // fmv.w.x f1,x1
        program_words[2]=32'h00000013;
        program_words[3]=32'h18008153; // fdiv.s f2,f1,f0 -> DZ
        program_words[4]=32'h00102173; // csrrs x2,fflags,x0 -> 8
        program_words[5]=32'h00301073; // csrrw x0,fcsr,x0 -> clear
        program_words[6]=32'h0021e1f3; // csrrsi x3,frm,3 -> RUP
        program_words[7]=32'h01000237; // lui x4,0x01000
        program_words[8]=32'h00120213; // addi x4,x4,1 -> 16777217
        program_words[9]=32'hd00271d3; // fcvt.s.w f3,x4,dyn -> 16777218
        program_words[10]=32'h003022f3; // csrrs x5,fcsr,x0 -> 0x61
        program_words[11]=32'h00000013;
        program_words[12]=32'h00100073;
        repeat(3) @(negedge clk); rst=0;
    end
    initial begin #50000; $display("TEST FAILED: hart FP commit timeout"); $finish; end
endmodule
