// cache_checker -- per-cache SVA, LRU shadow checker and covergroups. Bound into
// every cache_ctrl by coh_bind.sv; ports connect to cache_ctrl internals, and the
// tag/state arrays are read upward-hierarchically from u_store (cache_ctrl's
// cache_store instance). Every failure goes through `uvm_error.
//
// Checks
//   CC_ILLEGAL_ST   no state is ever 2'b11
//   CC_DUP_TAG      no two valid ways of a set hold the same tag
//   CC_SNOOP_LOCAL  no local hit is serviced in a set under another cache's
//                   transaction (invariant 5)
//   CC_VICTIM_INV   a fill into a set with an invalid way uses the lowest one
//   CC_LRU          otherwise the victim (fill or writeback) is not the shadow MRU
//                   way, where the shadow MRU is built from observed local hits
//                   and completed fills only (invariant 8)
// Coverage (printed in `final` with a COV: prefix; type coverage, so it merges
// every cache instance of this run)
//   cg_local   {I,S,M} x {PrRd, PrWr}
//   cg_snoop   {I,S,M} x {snooped BusRd, snooped BusRdX}
//   cg_event   dirty eviction, silent S eviction, S->M upgrade, owner transfer,
//              contention, race: victim demoted M->S while waiting, race: S line
//              invalidated while waiting to upgrade
//   cg_way     (WAYS > 1 only) hit way, victim from invalid vs LRU way, M/S
//              eviction x way
`timescale 1ns/1ps
`include "uvm_macros.svh"
module cache_checker #(
    parameter int N      = 2,
    parameter int MY_ID  = 0,
    parameter int WAYS   = 1,
    parameter int SETS   = 4,
    parameter int TAG_W  = 26,
    // Derived -- do not override.
    parameter int IDX_W  = $clog2(SETS),
    parameter int LAW    = TAG_W + IDX_W,
    parameter int WAY_W  = (WAYS > 1) ? $clog2(WAYS) : 1,
    parameter int SRC_W  = (N > 1) ? $clog2(N) : 1
) (
    input logic             clk,
    input logic             rst,
    input logic [1:0]       cs,          // cache_ctrl FSM: 0 IDLE, 1 WAIT, 2 BUS
    input logic             accept,
    input logic             req_we,
    input logic             local_hit,
    input logic             a_hit,
    input logic [1:0]       a_hit_st,
    input logic [WAY_W-1:0] a_hit_way,
    input logic             a_has_inv,
    input logic [WAY_W-1:0] vic_way,
    input logic [1:0]       vic_st,
    input logic [IDX_W-1:0] a_idx,
    input logic [TAG_W-1:0] a_tagq,
    input logic             bus_req,
    input logic             bus_gnt,
    input logic             bus_active,
    input logic [1:0]       bus_cmd,
    input logic [LAW-1:0]   bus_addr,
    input logic [SRC_W-1:0] bus_src,
    input logic             bus_done,
    input logic [1:0]       txn_cmd,
    input logic [WAY_W-1:0] txn_way,
    input logic             snoop_en,
    input logic             s_hit,
    input logic [1:0]       s_hit_st,
    input logic             owner_hit_o
);
    import uvm_pkg::*;

    localparam logic [1:0] I = 2'b00, S = 2'b01, M = 2'b10;
    localparam logic [1:0] C_WAIT = 2'd1, C_BUS = 2'd2;
    localparam logic [1:0] CMD_RD = 2'b01, CMD_RDX = 2'b10, CMD_WB = 2'b11;
    localparam logic [SRC_W-1:0] MY_SRC = MY_ID;

    // ------------------------------------------------------------------
    // Array view: [set][way]
    // ------------------------------------------------------------------
    logic [1:0]       st [SETS][WAYS];
    logic [TAG_W-1:0] tg [SETS][WAYS];
    genvar gs, gw;
    generate
        for (gs = 0; gs < SETS; gs++) begin : g_s
            for (gw = 0; gw < WAYS; gw++) begin : g_w
                assign st[gs][gw] = u_store.st_mem [gs*WAYS + gw];
                assign tg[gs][gw] = u_store.tag_mem[gs*WAYS + gw];

                a_no_illegal_state: assert property (@(posedge clk) disable iff (rst) st[gs][gw] != 2'b11)
                    else `uvm_error("CC_ILLEGAL_ST", $sformatf("cache%0d set %0d way %0d state 2'b11", MY_ID, gs, gw))

                for (genvar gw2 = gw + 1; gw2 < WAYS; gw2++) begin : g_w2
                    a_no_dup_tag: assert property (@(posedge clk) disable iff (rst)
                            !(st[gs][gw] != I && st[gs][gw2] != I && tg[gs][gw] == tg[gs][gw2]))
                        else `uvm_error("CC_DUP_TAG", $sformatf("cache%0d set %0d ways %0d,%0d both hold tag %0h",
                                                               MY_ID, gs, gw, gw2, tg[gs][gw]))
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Invariant 5: snoops beat local accesses
    // ------------------------------------------------------------------
    wire other_txn_on_set = bus_active && (bus_src != MY_SRC) && (bus_addr[IDX_W-1:0] == a_idx);

    a_snoop_beats_local: assert property (@(posedge clk) disable iff (rst)
            (accept && local_hit) |-> !other_txn_on_set)
        else `uvm_error("CC_SNOOP_LOCAL", $sformatf("cache%0d serviced a local hit in set %0d during cache%0d's transaction",
                                                    MY_ID, a_idx, bus_src))

    // ------------------------------------------------------------------
    // Derived events (all evaluated on pre-edge values at posedge clk)
    // ------------------------------------------------------------------
    wire my_done   = (cs == C_BUS) && bus_done;
    wire grant_now = (cs == C_WAIT) && bus_gnt;     // one edge per grant
    wire hit_ev    = accept && local_hit;

    // Lowest invalid way of the set under port A, and whether one exists.
    logic             inv_any;
    logic [WAY_W-1:0] inv_low;
    always_comb begin
        inv_any = 1'b0;
        inv_low = '0;
        for (int w = WAYS - 1; w >= 0; w--)
            if (st[a_idx][w] == I) begin
                inv_any = 1'b1;
                inv_low = w[WAY_W-1:0];
            end
    end

    // A completed fill is an upgrade if the line is already present in txn_way.
    wire fill_done = my_done && (txn_cmd != CMD_WB);
    wire fill_upg  = fill_done && st[a_idx][txn_way] != I && tg[a_idx][txn_way] == a_tagq;
    wire fill_miss = fill_done && !fill_upg;
    wire wb_done   = my_done && (txn_cmd == CMD_WB);

    // State of the request at accept time, for the race bins (first grant only).
    logic             rq_pending;     // accepted miss, first grant not seen yet
    logic             rq_vic_m;       // victim was M at request
    logic [WAY_W-1:0] rq_vic_way;
    logic [TAG_W-1:0] rq_vic_tag;
    logic             rq_upg;         // write to an S line at request

    wire race_demote = grant_now && rq_pending && rq_vic_m &&
                       st[a_idx][rq_vic_way] == S && tg[a_idx][rq_vic_way] == rq_vic_tag;
    wire race_inval  = grant_now && rq_pending && rq_upg && !a_hit;
    wire silent_ev   = grant_now && !a_hit && !a_has_inv && vic_st == S;
    wire upgrade_ev  = grant_now && a_hit;
    wire owner_ev    = owner_hit_o && bus_done;
    wire contend_ev  = (cs == C_WAIT) && bus_req && bus_active && (bus_src != MY_SRC) && !bus_done;
    wire snoop_ev    = snoop_en && bus_done;

    // ------------------------------------------------------------------
    // LRU shadow checker
    // ------------------------------------------------------------------
    logic [WAY_W-1:0] mru   [SETS];
    logic             mru_v [SETS];
    int unsigned      n_lru_checks;

    always @(posedge clk) begin
        if (rst) begin
            for (int s = 0; s < SETS; s++) begin
                mru[s]   <= '0;
                mru_v[s] <= 1'b0;
            end
            rq_pending <= 1'b0;
        end else begin
            // Victim choice on a fill (not an upgrade) and on a writeback.
            if (fill_miss) begin
                n_lru_checks++;
                if (inv_any) begin
                    if (txn_way != inv_low)
                        `uvm_error("CC_VICTIM_INV", $sformatf("cache%0d set %0d: filled way %0d, lowest invalid way is %0d",
                                                              MY_ID, a_idx, txn_way, inv_low))
                end else if (WAYS > 1 && mru_v[a_idx] && txn_way == mru[a_idx])
                    `uvm_error("CC_LRU", $sformatf("cache%0d set %0d: filled over way %0d, the most recently used way",
                                                   MY_ID, a_idx, txn_way))
            end
            if (wb_done && WAYS > 1) begin
                n_lru_checks++;
                if (mru_v[a_idx] && txn_way == mru[a_idx])
                    `uvm_error("CC_LRU", $sformatf("cache%0d set %0d: wrote back way %0d, the most recently used way",
                                                   MY_ID, a_idx, txn_way))
            end
            // Shadow MRU: observed local hits and completed fills only.
            if (hit_ev) begin
                mru[a_idx]   <= a_hit_way;
                mru_v[a_idx] <= 1'b1;
            end
            if (fill_done) begin
                mru[a_idx]   <= txn_way;
                mru_v[a_idx] <= 1'b1;
            end

            // Request-time snapshot for the race bins.
            if (accept && !local_hit) begin
                rq_pending <= 1'b1;
                rq_vic_m   <= !a_hit && !a_has_inv && vic_st == M;
                rq_vic_way <= vic_way;
                rq_vic_tag <= tg[a_idx][vic_way];
                rq_upg     <= a_hit && req_we && a_hit_st == S;
            end else if (grant_now)
                rq_pending <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Coverage
    // ------------------------------------------------------------------
    wire [1:0] loc_st = a_hit ? a_hit_st : I;
    wire [1:0] snp_st = s_hit ? s_hit_st : I;

    covergroup cg_local @(posedge clk);
        option.per_instance = 0;
        cp_st: coverpoint loc_st iff (!rst && accept) { bins I = {I}; bins S = {S}; bins M = {M}; }
        cp_ev: coverpoint req_we iff (!rst && accept) { bins PrRd = {0}; bins PrWr = {1}; }
        x_st_ev: cross cp_st, cp_ev;
    endgroup

    covergroup cg_snoop @(posedge clk);
        option.per_instance = 0;
        cp_st: coverpoint snp_st  iff (!rst && snoop_ev) { bins I = {I}; bins S = {S}; bins M = {M}; }
        cp_ev: coverpoint bus_cmd iff (!rst && snoop_ev) { bins BusRd = {CMD_RD}; bins BusRdX = {CMD_RDX}; }
        x_st_ev: cross cp_st, cp_ev;
    endgroup

    covergroup cg_event @(posedge clk);
        option.per_instance = 0;
        cp_dirty_evict:  coverpoint wb_done     iff (!rst) { bins hit = {1}; }
        cp_silent_evict: coverpoint silent_ev   iff (!rst) { bins hit = {1}; }
        cp_upgrade:      coverpoint upgrade_ev  iff (!rst) { bins hit = {1}; }
        cp_owner_xfer:   coverpoint owner_ev    iff (!rst) { bins hit = {1}; }
        cp_contention:   coverpoint contend_ev  iff (!rst) { bins hit = {1}; }
        cp_race_demote:  coverpoint race_demote iff (!rst) { bins hit = {1}; }
        cp_race_inval:   coverpoint race_inval  iff (!rst) { bins hit = {1}; }
    endgroup

    // 2-way bins. Eviction kind: 0 = dirty (BusWB of txn_way), 1 = silent S (vic_way at grant).
    wire             evict_ev   = wb_done || silent_ev;
    wire             evict_kind = !wb_done;
    wire [WAY_W-1:0] evict_way  = wb_done ? txn_way : vic_way;

    covergroup cg_way @(posedge clk);
        option.per_instance = 0;
        cp_hit_way:   coverpoint a_hit_way iff (!rst && hit_ev)    { bins way[] = {[0:WAYS-1]}; }
        cp_victim:    coverpoint inv_any   iff (!rst && fill_miss) { bins from_lru = {0}; bins from_invalid = {1}; }
        cp_evict_way: coverpoint evict_way iff (!rst && evict_ev)  { bins way[] = {[0:WAYS-1]}; }
        cp_evict_kind: coverpoint evict_kind iff (!rst && evict_ev) { bins M_evict = {0}; bins S_evict = {1}; }
        x_evict: cross cp_evict_way, cp_evict_kind;
    endgroup

    cg_local cgl = new();
    cg_snoop cgs = new();
    cg_event cge = new();
    cg_way   cgw;
    initial if (WAYS > 1) cgw = new();

    // Event counts (for the log; coverage only says hit / not hit).
    int unsigned n_dirty, n_silent, n_upg, n_owner, n_contend, n_race_demote, n_race_inval;
    always @(posedge clk) if (!rst) begin
        n_dirty       += wb_done;
        n_silent      += silent_ev;
        n_upg         += upgrade_ev;
        n_owner       += owner_ev;
        n_contend     += contend_ev;
        n_race_demote += race_demote;
        n_race_inval  += race_inval;
    end

    // Per-bin hit counts mirroring the covergroup bins (cross bins for local and
    // snoop). Printed as COV_BINS (name=count) so regress.ps1 can union bins across
    // runs -- xsim covergroups are per-run. Fixed int arrays: a string-keyed
    // associative array here crashed the xsim 2025.1 kernel.
    int unsigned h_local [3][2];      // [I,S,M][PrRd,PrWr]
    int unsigned h_snoop [3][2];      // [I,S,M][BusRd,BusRdX]
    int unsigned h_hitw  [WAYS];
    int unsigned h_evict [WAYS][2];   // [way][M,S]
    int unsigned h_vic   [2];         // [from_lru, from_invalid]

    always @(posedge clk) if (!rst) begin
        if (accept && loc_st != 2'b11) h_local[loc_st][req_we]++;
        if (snoop_ev && snp_st != 2'b11 && (bus_cmd == CMD_RD || bus_cmd == CMD_RDX))
            h_snoop[snp_st][bus_cmd == CMD_RDX]++;
        if (hit_ev)    h_hitw[a_hit_way]++;
        if (fill_miss) h_vic[inv_any]++;
        if (evict_ev)  h_evict[evict_way][evict_kind]++;
    end

    final begin
        string line;
        string nm [3];
        nm   = '{"I", "S", "M"};
        line = $sformatf("COV_BINS: cache%0d", MY_ID);
        for (int s = 0; s < 3; s++)
            line = {line, $sformatf(" local_%s_PrRd=%0d local_%s_PrWr=%0d snoop_%s_BusRd=%0d snoop_%s_BusRdX=%0d",
                    nm[s], h_local[s][0], nm[s], h_local[s][1], nm[s], h_snoop[s][0], nm[s], h_snoop[s][1])};
        line = {line, $sformatf(" ev_dirty_evict=%0d ev_silent_evict=%0d ev_upgrade=%0d ev_owner_xfer=%0d ev_contention=%0d ev_race_demote=%0d ev_race_inval=%0d",
                n_dirty, n_silent, n_upg, n_owner, n_contend, n_race_demote, n_race_inval)};
        if (WAYS > 1) begin
            for (int w = 0; w < WAYS; w++)
                line = {line, $sformatf(" way_hit_w%0d=%0d way_evictM_w%0d=%0d way_evictS_w%0d=%0d",
                        w, h_hitw[w], w, h_evict[w][0], w, h_evict[w][1])};
            line = {line, $sformatf(" way_victim_from_lru=%0d way_victim_from_invalid=%0d", h_vic[0], h_vic[1])};
        end
        $display("%s", line);
    end

    final begin
        real total;
        int  ng;
        total = cgl.get_coverage() + cgs.get_coverage() + cge.get_coverage();
        ng    = 3;
        if (cgw != null) begin
            total += cgw.get_coverage();
            ng++;
        end
        $display("COV: cache%0d local=%0.2f%% snoop=%0.2f%% event=%0.2f%% way=%0.2f%% total=%0.2f%%",
                 MY_ID, cgl.get_coverage(), cgs.get_coverage(), cge.get_coverage(),
                 (cgw != null) ? cgw.get_coverage() : 0.0, total / ng);
        $display("COV_EVENTS: cache%0d dirty_evict=%0d silent_evict=%0d upgrade=%0d owner_xfer=%0d contention=%0d race_demote=%0d race_inval=%0d lru_checks=%0d",
                 MY_ID, n_dirty, n_silent, n_upg, n_owner, n_contend, n_race_demote, n_race_inval, n_lru_checks);
    end
endmodule
