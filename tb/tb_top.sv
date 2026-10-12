// tb_top -- clock/reset, DUT, memory model, interfaces, run_test().
// N and WAYS are top-level parameters: override with xelab -generic_top.
// Virtual interfaces go into config_db as "core_vif_<i>" and "bus_vif"; the env
// counts core_vif_* to learn N (config_db carries nothing but virtual interfaces).
`timescale 1ns/1ps
`include "uvm_macros.svh"
module tb_top #(
    parameter int N    = 2,
    parameter int WAYS = 2
);
    import uvm_pkg::*;
    import coh_pkg::*;

    localparam int SETS   = 4;
    localparam int AW     = 32;
    localparam int WORD_W = 32;
    localparam int LINE_W = 128;
    localparam int LAW    = AW - $clog2(LINE_W / 8);
    localparam int NMAX   = 4;   // bus_if sizing: project limits (<= 4 cores, <= 2 ways)
    localparam int WMAX   = 2;
    localparam int LAT_MIN = 2;  // memory model latency range (cycles)
    localparam int LAT_MAX = 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;
    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
    end

    // ------------------------------------------------------------------
    // Interfaces
    // ------------------------------------------------------------------
    core_if #(.AW(AW), .WORD_W(WORD_W)) cif [N] (.clk(clk), .rst(rst));
    bus_if #(.NMAX(NMAX), .WMAX(WMAX), .SETS(SETS), .LAW(LAW), .LINE_W(LINE_W)) bif (.clk(clk), .rst(rst));

    wire [N-1:0]        req_valid, req_ready, req_we, resp_valid;
    wire [N*AW-1:0]     req_addr;
    wire [N*WORD_W-1:0] req_wdata, resp_rdata;

    wire                mem_req, mem_we, mem_ack;
    wire [LAW-1:0]      mem_addr;
    wire [LINE_W-1:0]   mem_wdata, mem_rdata;

    // ------------------------------------------------------------------
    // DUT and memory
    // ------------------------------------------------------------------
    coh_top #(.N(N), .WAYS(WAYS), .SETS(SETS), .AW(AW), .WORD_W(WORD_W), .LINE_W(LINE_W)) dut (
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

    mem_model #(.LAW(LAW), .LINE_W(LINE_W), .LAT_MIN(LAT_MIN), .LAT_MAX(LAT_MAX)) u_mem (
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
    // Core interfaces <-> flattened DUT ports; cache-array snapshot for bif
    // (bif is sized NMAX x WMAX; entries beyond N / WAYS are tied to zero = I).
    // ------------------------------------------------------------------
    genvar c, s, w;
    generate
        for (c = 0; c < NMAX; c = c + 1) begin : g_core
            if (c < N) begin : g_real
                assign req_valid[c]                  = cif[c].req_valid;
                assign req_we[c]                     = cif[c].req_we;
                assign req_addr [c*AW     +: AW]     = cif[c].req_addr;
                assign req_wdata[c*WORD_W +: WORD_W] = cif[c].req_wdata;
                assign cif[c].req_ready              = req_ready[c];
                assign cif[c].resp_valid             = resp_valid[c];
                assign cif[c].resp_rdata             = resp_rdata[c*WORD_W +: WORD_W];
                assign bif.bus_req[c]                = dut.c_req[c];
                assign bif.bus_gnt[c]                = dut.bus_gnt[c];

                initial uvm_config_db#(virtual core_if)::set(null, "uvm_test_top*",
                                                             $sformatf("core_vif_%0d", c), cif[c]);
            end else begin : g_none
                assign bif.bus_req[c] = 1'b0;
                assign bif.bus_gnt[c] = 1'b0;
            end

            for (s = 0; s < SETS; s = s + 1) begin : g_set
                for (w = 0; w < WMAX; w = w + 1) begin : g_way
                    if (c < N && w < WAYS) begin : g_real
                        assign bif.st  [c][s][w] = dut.g_cache[c].u_cache.u_store.st_mem  [s*WAYS + w];
                        assign bif.tag [c][s][w] = dut.g_cache[c].u_cache.u_store.tag_mem [s*WAYS + w];
                        assign bif.data[c][s][w] = dut.g_cache[c].u_cache.u_store.data_mem[s*WAYS + w];
                    end else begin : g_none
                        assign bif.st  [c][s][w] = 2'b00;
                        assign bif.tag [c][s][w] = '0;
                        assign bif.data[c][s][w] = '0;
                    end
                end
            end
        end
    endgenerate

    assign bif.bus_active = dut.bus_active;
    assign bif.bus_cmd    = dut.bus_cmd;
    assign bif.bus_addr   = dut.bus_addr;
    assign bif.bus_src    = 2'(dut.bus_src);
    assign bif.bus_rdata  = dut.bus_rdata;
    assign bif.owner_hit  = dut.owner_hit;
    assign bif.bus_done   = dut.bus_done;

    // ------------------------------------------------------------------
    // Checkers: per-cache (bound) and cross-cache
    // ------------------------------------------------------------------
    coh_bind u_bind ();

    system_checker #(.N(N), .WAYS(WAYS), .SETS(SETS), .LAW(LAW), .LINE_W(LINE_W),
                     .LAT_MAX(LAT_MAX)) u_sys (.clk(clk), .rst(rst));

    initial begin
        uvm_config_db#(virtual bus_if)::set(null, "uvm_test_top*", "bus_vif", bif);
        run_test();
    end
endmodule
