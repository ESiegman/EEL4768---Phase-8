`timescale 1ns/1ps
`include "mem_model.vh"

// Check the hart's optional store forwarding and confirmed-load lookahead
// against both memory timing conventions supported by the course model.
module cache_forward_case #(parameter SAMPLE_AT_RESPONSE=0) (output reg done);
    localparam A = 32'h10010000;
    localparam CONFLICT = A + 32'h104; // same folded index as A, different tag
    localparam B = A + 32'h200, C = A + 32'h400;
    reg clk=0, rst=1, ren=0, wen=0, hint=0;
    reg [31:0] addr=0, wdata=0, hint_addr=0;
    reg [3:0] mask=0;
    wire ready, rd, wr, mem_valid;
    wire [31:0] rdata, rd_addr, wr_addr;
    wire [127:0] rd_data, wr_data;
    wire [15:0] wr_be;
    integer passed=0, failed=0, reads, waited;
    always #5 clk = ~clk;

    cache #(.NUM_WAYS(2), .CACHE_SIZE(1), .BLOCK_SIZE(16), .PREFETCH_EN(1),
            .FORWARD_STORES(1), .LOAD_LOOKAHEAD(1)) dut (
        .i_clk(clk), .i_rst(rst), .i_hint_valid(hint), .i_hint_addr(hint_addr),
        .i_ren(ren), .i_wen(wen), .i_addr(addr), .i_mask(mask), .i_wdata(wdata),
        .o_ready(ready), .o_rdata(rdata), .o_mem_rd(rd), .o_mem_rd_addr(rd_addr),
        .i_mem_valid(mem_valid), .i_mem_rd_data(rd_data), .o_mem_wr(wr),
        .o_mem_wr_addr(wr_addr), .o_mem_wr_data(wr_data), .o_mem_wr_be(wr_be));
    main_mem #(.BLOCK_SIZE(16), .LATENCY(4), .BASE_ADDR(A), .SIZE_WORDS(1024),
               .SAMPLE_AT_RESPONSE(SAMPLE_AT_RESPONSE)) mem (
        .i_clk(clk), .i_rst(rst), .i_rd(rd), .i_rd_addr(rd_addr),
        .o_rd_valid(mem_valid), .o_rd_data(rd_data), .i_wr(wr),
        .i_wr_addr(wr_addr), .i_wr_data(wr_data), .i_wr_be(wr_be));

    task check;
        input condition;
        input [8*90-1:0] message;
        begin
            if (condition === 1'b1) passed = passed + 1;
            else begin
                failed = failed + 1;
                $display("[FAIL] sample_at_response=%0d %0s", SAMPLE_AT_RESPONSE, message);
            end
        end
    endtask

    // Drive at negedge. Check combinational data before the acceptance edge.
    task access_word;
        input store;
        input [31:0] address, value;
        input [3:0] lanes;
        begin
            addr=address; wdata=value; mask=lanes; wen=store; ren=!store;
            waited=0;
            #1;
            while (ready !== 1'b1 && waited < 30) begin
                @(negedge clk); #1; waited=waited+1;
            end
            check(ready, "access completed");
            if (!store) check(rdata === value, "all four returned bytes match");
            @(negedge clk); ren=0; wen=0;
        end
    endtask

    task send_hint;
        input [31:0] address;
        begin
            hint=1; hint_addr=address; #1;
            check(rd && rd_addr == address, "idle port issued confirmed load line");
            @(negedge clk); hint=0;
        end
    endtask

    initial begin
        done=0;
        repeat(2) @(negedge clk); rst=0;
        reads=mem.n_rd;
        // A partial store to an untracked word cannot supply the other bytes.
        // A full store can, including later byte and halfword updates.
        access_word(1,A,32'h11223344,4'hf);
        access_word(1,A,32'h0000aa00,4'b0010);
        access_word(1,A,32'hcafe0000,4'b1100);
        access_word(0,A,32'hcafeaa44,4'b0001);
        check(waited==0 && mem.n_rd==reads, "complete word forwarded on a byte load");
        access_word(1,CONFLICT,32'hface1234,4'hf);
        access_word(1,A,32'h55,4'b0001);
        access_word(0,A,32'hcafeaa55,4'hf);
        check(mem.n_rd>reads, "partial store after slot collision required a line read");
        access_word(0,CONFLICT,32'hface1234,4'hf);
        repeat(8) @(negedge clk);

        // A matching hint in flight coalesces with the later demand.
        mem.poke(B,32'h24681357);
        reads=mem.n_rd; send_hint(B);
        addr=B; mask=4'hf; ren=1; #1;
        check(!ready, "load waits for its in-flight line");
        wait(mem_valid); #1;
        check(ready && rdata==32'h24681357, "matching load consumes the actual fill cycle");
        @(negedge clk); // hold through the following acceptance edge
        @(negedge clk); ren=0;
        repeat(8) @(negedge clk);
        check(mem.n_rd==reads+2, "exactly one read each for the hint and next line");

        // A write may neither race an older read snapshot nor leave stale
        // bytes in the forwarding buffer. Exercise an in-flight *next line*.
        mem.poke(C+16,32'haabbccdd);
        send_hint(C);
        access_word(1,C+16,32'h00880000,4'b0100);
        check(waited>0, "store waited for the outstanding read of its line");
        access_word(0,C+16,32'haa88ccdd,4'hf);
        repeat(8) @(negedge clk);

        // No read may sample stale memory alongside a write-through.
        hint=1; hint_addr=C+64; addr=C+64; mask=4'hf; wen=1; wdata=32'hbabe1234; #1;
        check(wr && !rd, "same-line store takes precedence over a new hint");
        @(negedge clk); wen=0; hint=0;
        access_word(0,C+64,32'hbabe1234,4'hf);
        rst=1; @(negedge clk); rst=0;
        mem.poke(C+64,32'h456789ab);
        access_word(0,C+64,32'h456789ab,4'hf);
        check(waited>0, "reset invalidated both L1 and the store word");
        check(mem.errors==0, "memory protocol stayed valid");
        done=1;
    end
endmodule

module cache_forward_tb;
    wire d0, d1;
    cache_forward_case #(0) issue_sample(d0);
    cache_forward_case #(1) return_sample(d1);
    integer failures;
    initial begin
        wait(d0 && d1);
        failures=issue_sample.failed + return_sample.failed;
        $display("%0d passed, %0d failed", issue_sample.passed + return_sample.passed, failures);
        if (failures==0) $display("ALL TESTS PASSED");
        else $display("TEST FAILED");
        $finish;
    end
    initial begin #10000; $fatal(1,"cache forward timeout"); end
endmodule
