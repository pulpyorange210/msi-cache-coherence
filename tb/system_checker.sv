// system_checker -- cross-cache SVA. Instantiated in tb_top; reads dut and u_mem
// hierarchically. Every failure goes through `uvm_error.
//
//   SYS_SWMR        single writer / multiple readers: a line held M by one cache
//                   is held by no other cache (invariant 2)
//   SYS_S_NEQ_MEM   every S line equals memory (invariant 3)
//   SYS_OWNERS      at most one owner_hit per transaction
//   SYS_GNT_ONEHOT  bus_gnt is one-hot or zero, and nonzero exactly while the bus
//                   is active (grant through bus_done)
//   SYS_GNT_HELD    bus_gnt is held unchanged from grant to bus_done
//   SYS_LATENCY     every accepted request responds within K cycles
//
// Latency bound K (cycles from the accept edge to the edge that samples
// resp_valid):
//   One bus transaction occupies at most T = LAT_MAX + 5 cycles of bus time:
//   1 ARB (grant registered) + 1 SNOOP + (LAT_MAX + 2) MEM (mem_model samples
//   mem_req on the first MEM edge, acks LAT edges later, the bus sees the ack one
//   edge after that) + 1 DONE. Owner + BusRdX is shorter (3).
//   A request needs at most 2 transactions of its own (BusWB of a dirty victim,
//   then the fill): after the BusWB the victim way is invalid, so the second
//   decision cannot need another writeback.
//   Round-robin: before each of those grants, each of the other N-1 caches can
//   win at most one grant (the pointer moves past every winner), so at most
//   2(N-1) foreign transactions interleave.
//   K = 2N * T + 1 (the +1 is the cycle from bus_done to resp_valid being sampled).
//   N=2, LAT_MAX=8: T = 13, K = 53.  N=1: K = 27 (the measured N=1 worst case).
// Latency is measured from accept; the snoop-beats-local stall before accept is
// bounded separately by one transaction (the ARB cycle between transactions
// always reopens req_ready) and is not part of K.
`timescale 1ns/1ps
`include "uvm_macros.svh"
module system_checker #(
    parameter int N       = 2,
    parameter int WAYS    = 2,
    parameter int SETS    = 4,
    parameter int LAW     = 28,
    parameter int LINE_W  = 128,
    parameter int LAT_MAX = 8,
    // Derived -- do not override.
    parameter int IDX_W   = $clog2(SETS),
    parameter int TAG_W   = LAW - IDX_W,
    parameter int T_MAX   = LAT_MAX + 5,
    parameter int K       = 2 * N * T_MAX + 1
) (
    input logic clk,
    input logic rst
);
    import uvm_pkg::*;

    localparam logic [1:0] I = 2'b00, S = 2'b01, M = 2'b10;

    // ------------------------------------------------------------------
    // Snapshot of every cache: [cache][set][way]
    // ------------------------------------------------------------------
    logic [1:0]        st   [N][SETS][WAYS];
    logic [TAG_W-1:0]  tg   [N][SETS][WAYS];
    logic [LINE_W-1:0] data [N][SETS][WAYS];

    genvar gc, gs, gw;
    generate
        for (gc = 0; gc < N; gc++) begin : g_c
            for (gs = 0; gs < SETS; gs++) begin : g_s
                for (gw = 0; gw < WAYS; gw++) begin : g_w
                    assign st  [gc][gs][gw] = dut.g_cache[gc].u_cache.u_store.st_mem  [gs*WAYS + gw];
                    assign tg  [gc][gs][gw] = dut.g_cache[gc].u_cache.u_store.tag_mem [gs*WAYS + gw];
                    assign data[gc][gs][gw] = dut.g_cache[gc].u_cache.u_store.data_mem[gs*WAYS + gw];
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Invariants 2 and 3, checked at negedge: every register and the memory
    // model (which writes with a blocking assignment at posedge) are settled.
    // A violation is reported when it appears, not again every cycle it persists.
    // ------------------------------------------------------------------
    bit          swmr_q [N][SETS][WAYS];
    bit          sneq_q [N][SETS][WAYS];
    int unsigned n_state_checks;

    always @(negedge clk) begin
        if (rst) begin
            swmr_q = '{default: 0};
            sneq_q = '{default: 0};
        end else begin
            for (int c = 0; c < N; c++)
                for (int s = 0; s < SETS; s++)
                    for (int w = 0; w < WAYS; w++) begin
                        automatic bit swmr = 1'b0, sneq = 1'b0;
                        if (st[c][s][w] == M)
                            for (int c2 = 0; c2 < N; c2++)
                                for (int w2 = 0; w2 < WAYS; w2++)
                                    if (c2 != c && st[c2][s][w2] != I && tg[c2][s][w2] == tg[c][s][w])
                                        swmr = 1'b1;
                        if (st[c][s][w] == S)
                            sneq = (data[c][s][w] !== u_mem.peek({tg[c][s][w], s[IDX_W-1:0]}));
                        n_state_checks++;

                        a_swmr: assert (!(swmr && !swmr_q[c][s][w]))
                            else `uvm_error("SYS_SWMR", $sformatf("cache%0d holds line %07h in M while another cache holds it",
                                                                  c, {tg[c][s][w], s[IDX_W-1:0]}))
                        a_s_eq_mem: assert (!(sneq && !sneq_q[c][s][w]))
                            else `uvm_error("SYS_S_NEQ_MEM", $sformatf("cache%0d S line %07h differs from memory",
                                                                       c, {tg[c][s][w], s[IDX_W-1:0]}))
                        swmr_q[c][s][w] = swmr;
                        sneq_q[c][s][w] = sneq;
                    end
        end
    end

    // ------------------------------------------------------------------
    // Bus rules
    // ------------------------------------------------------------------
    a_one_owner: assert property (@(posedge clk) disable iff (rst) $onehot0(dut.c_owner_hit))
        else `uvm_error("SYS_OWNERS", $sformatf("owner_hit from more than one cache: %b", dut.c_owner_hit))

    a_gnt_onehot: assert property (@(posedge clk) disable iff (rst)
            $onehot0(dut.bus_gnt) && ((|dut.bus_gnt) == dut.bus_active))
        else `uvm_error("SYS_GNT_ONEHOT", $sformatf("bus_gnt %b with bus_active %b", dut.bus_gnt, dut.bus_active))

    a_gnt_held: assert property (@(posedge clk) disable iff (rst)
            ((|dut.bus_gnt) && !dut.bus_done) |=> (dut.bus_gnt == $past(dut.bus_gnt)))
        else `uvm_error("SYS_GNT_HELD", "bus_gnt changed before bus_done")

    // ------------------------------------------------------------------
    // Latency bound
    // ------------------------------------------------------------------
    longint unsigned cyc;
    longint unsigned t_acc [N];
    int unsigned     lat_worst;
    int unsigned     n_resp;

    always @(posedge clk) begin
        cyc++;
        if (!rst) begin
            for (int c = 0; c < N; c++) begin
                if (dut.resp_valid[c]) begin
                    automatic int unsigned lat = cyc - t_acc[c];
                    n_resp++;
                    if (lat > lat_worst) lat_worst = lat;
                    a_latency: assert (lat <= K)
                        else `uvm_error("SYS_LATENCY", $sformatf("core%0d request took %0d cycles, bound K = %0d", c, lat, K))
                end
                if (dut.req_valid[c] && dut.req_ready[c]) t_acc[c] = cyc;
            end
        end
    end

    final $display("LAT: worst=%0d K=%0d (N=%0d, LAT_MAX=%0d, T=%0d) responses=%0d state_checks=%0d",
                   lat_worst, K, N, LAT_MAX, T_MAX, n_resp, n_state_checks);
endmodule
