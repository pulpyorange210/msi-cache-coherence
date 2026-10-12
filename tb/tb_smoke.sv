// tb_smoke -- Phase 1 directed smoke test. N=1, WAYS=1, bus present, no snoopers.
// Covers: read miss, read hit (1-cycle), write miss, write hit, S->M upgrade,
// dirty eviction with writeback, silent clean eviction, refetch after writeback.
// Every load is checked against a flat reference; bus transactions are counted
// at bus_done and checked per step. Ends with "SMOKE: PASS" or "SMOKE: FAIL".
`timescale 1ns/1ps
module tb_smoke;
    localparam int N      = 1;
    localparam int WAYS   = 1;
    localparam int SETS   = 4;
    localparam int LAW    = 28;
    localparam int LINE_W = 128;

    `include "mem_init.svh"

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic              req_valid = 1'b0;
    logic              req_we    = 1'b0;
    logic [31:0]       req_addr  = '0;
    logic [31:0]       req_wdata = '0;
    wire               req_ready;
    wire               resp_valid;
    wire  [31:0]       resp_rdata;

    wire               mem_req, mem_we, mem_ack;
    wire  [LAW-1:0]    mem_addr;
    wire  [LINE_W-1:0] mem_wdata, mem_rdata;

    coh_top #(.N(N), .WAYS(WAYS), .SETS(SETS)) dut (
        .clk        (clk),
        .rst        (rst),
        .req_valid  (req_valid),
        .req_ready  (req_ready),
        .req_we     (req_we),
        .req_addr   (req_addr),
        .req_wdata  (req_wdata),
        .resp_valid (resp_valid),
        .resp_rdata (resp_rdata),
        .mem_req    (mem_req),
        .mem_we     (mem_we),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_rdata  (mem_rdata),
        .mem_ack    (mem_ack)
    );

    mem_model #(.LAW(LAW), .LINE_W(LINE_W)) u_mem (
        .clk       (clk),
        .rst       (rst),
        .mem_req   (mem_req),
        .mem_we    (mem_we),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_rdata (mem_rdata),
        .mem_ack   (mem_ack)
    );

    // ------------------------------------------------------------------
    // Reference model and counters
    // ------------------------------------------------------------------
    logic [31:0] ref_mem [logic [31:0]];
    function automatic logic [31:0] ref_rd(input logic [31:0] a);
        a[1:0] = 2'b00;
        return ref_mem.exists(a) ? ref_mem[a] : mem_init_word(a);
    endfunction

    int errors = 0;
    int cyc    = 0;
    int n_rd = 0, n_rdx = 0, n_wb = 0;

    always @(posedge clk) begin
        cyc++;
        if (dut.bus_done) begin
            case (dut.bus_cmd)
                2'b01: n_rd++;
                2'b10: n_rdx++;
                2'b11: n_wb++;
                default: begin
                    errors++;
                    $error("SMOKE: bus_done with bus_cmd %b", dut.bus_cmd);
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // One access: drive at negedge, handshake at posedge, wait for response.
    // Latency = cycles from the accept cycle to the cycle resp_valid is high.
    // ------------------------------------------------------------------
    task automatic access(input bit we, input logic [31:0] addr, input logic [31:0] wdata,
                          input string what, output int lat, output logic [31:0] rdata);
        int t_acc;
        @(negedge clk);
        req_valid = 1'b1;
        req_we    = we;
        req_addr  = addr;
        req_wdata = wdata;
        while (!req_ready) @(negedge clk);
        t_acc = cyc;
        @(negedge clk);
        req_valid = 1'b0;
        while (!resp_valid) @(negedge clk);
        lat   = cyc - t_acc;
        rdata = resp_rdata;
        if (we) begin
            ref_mem[{addr[31:2], 2'b00}] = wdata;
            $display("SMOKE: %-28s ST %08h <= %08h  lat %0d", what, addr, wdata, lat);
        end else begin
            $display("SMOKE: %-28s LD %08h => %08h  lat %0d", what, addr, rdata, lat);
            if (rdata !== ref_rd(addr)) begin
                errors++;
                $error("SMOKE: %s: load %08h got %08h, expected %08h", what, addr, rdata, ref_rd(addr));
            end
        end
    endtask

    task automatic expect_eq(input string what, input int got, input int exp);
        if (got != exp) begin
            errors++;
            $error("SMOKE: %s = %0d, expected %0d", what, got, exp);
        end
    endtask

    task automatic expect_bus(input string what, input int rd, input int rdx, input int wb);
        expect_eq({what, ": BusRd count"},  n_rd,  rd);
        expect_eq({what, ": BusRdX count"}, n_rdx, rdx);
        expect_eq({what, ": BusWB count"},  n_wb,  wb);
    endtask

    // ------------------------------------------------------------------
    // Directed sequence. Index = addr[5:4], tag = addr[31:6].
    //   A, A1 : set 0, same line
    //   B, B2 : set 1, tag 0x80;  C : set 1, tag 0xC0 (conflicts with B)
    // ------------------------------------------------------------------
    localparam logic [31:0] A  = 32'h0000_1000;
    localparam logic [31:0] A1 = 32'h0000_1004;
    localparam logic [31:0] B  = 32'h0000_2010;
    localparam logic [31:0] B2 = 32'h0000_2018;
    localparam logic [31:0] C  = 32'h0000_3010;

    initial begin
        int          lat;
        logic [31:0] rd;
        logic [LINE_W-1:0] line;

        repeat (4) @(posedge clk);
        rst <= 1'b0;

        access(0, A,  '0,           "read miss (I->S)",        lat, rd);
        expect_bus("read miss", 1, 0, 0);
        if (lat < 4) begin errors++; $error("SMOKE: read miss latency %0d too short", lat); end

        access(0, A1, '0,           "read hit (S)",            lat, rd);
        expect_eq("read hit latency", lat, 1);
        expect_bus("read hit", 1, 0, 0);

        access(1, B,  32'hDEAD_0001, "write miss (I->M)",      lat, rd);
        expect_bus("write miss", 1, 1, 0);

        access(0, B,  '0,           "read hit (M)",            lat, rd);
        expect_eq("read hit (M) latency", lat, 1);

        access(1, B2, 32'hDEAD_0002, "write hit (M)",          lat, rd);
        expect_eq("write hit latency", lat, 1);
        expect_bus("write hit", 1, 1, 0);

        access(0, B2, '0,           "read after write hit",    lat, rd);

        access(1, A,  32'hBEEF_0003, "write to S (upgrade)",   lat, rd);
        expect_bus("upgrade", 1, 2, 0);

        // Dirty eviction: C maps to B's set; B is M -> BusWB, then BusRd for C.
        access(0, C,  '0,           "read miss, dirty evict",  lat, rd);
        expect_bus("dirty eviction", 2, 2, 1);
        line = u_mem.peek(B[31:4]);
        expect_eq("memory word B after WB",  line[0*32 +: 32], 32'hDEAD_0001);
        expect_eq("memory word B2 after WB", line[2*32 +: 32], 32'hDEAD_0002);

        // Refetch B: C is S -> silent eviction (no BusWB), data must come from memory.
        access(0, B,  '0,           "refetch after WB",        lat, rd);
        access(0, B2, '0,           "refetch hit",             lat, rd);
        expect_bus("silent eviction", 3, 2, 1);

        // A is still M in set 0.
        access(0, A,  '0,           "read hit on upgraded A",  lat, rd);
        expect_eq("read hit (upgraded) latency", lat, 1);

        repeat (5) @(posedge clk);
        $display("SMOKE: bus BusRd=%0d BusRdX=%0d BusWB=%0d, mem reads=%0d writes=%0d, max mem latency=%0d",
                 n_rd, n_rdx, n_wb, u_mem.n_reads, u_mem.n_writes, u_mem.lat_max_seen);
        if (errors == 0) $display("SMOKE: PASS");
        else             $display("SMOKE: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #100us;
        $display("SMOKE: FAIL (timeout)");
        $finish;
    end
endmodule
