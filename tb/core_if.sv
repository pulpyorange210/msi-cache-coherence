// core_if -- one core's request/response port. The driver uses drv_cb, the
// monitor mon_cb; both sample one step before the clock edge, so a request is
// accepted at edge E exactly when mon_cb sees req_valid && req_ready at E.
// req_ready depends on req_addr (snoop-beats-local, D11): the driver holds the
// request stable while req_valid is high.
`timescale 1ns/1ps
interface core_if #(
    parameter int AW     = 32,
    parameter int WORD_W = 32
) (
    input logic clk,
    input logic rst
);
    logic              req_valid;
    logic              req_ready;
    logic              req_we;
    logic [AW-1:0]     req_addr;
    logic [WORD_W-1:0] req_wdata;
    logic              resp_valid;
    logic [WORD_W-1:0] resp_rdata;

    clocking drv_cb @(posedge clk);
        default input #1step output #0;
        output req_valid, req_we, req_addr, req_wdata;
        input  req_ready, resp_valid, resp_rdata, rst;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input req_valid, req_ready, req_we, req_addr, req_wdata, resp_valid, resp_rdata, rst;
    endclocking
endinterface
