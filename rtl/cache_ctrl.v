// cache_ctrl -- one private write-back MSI cache: core-side hit logic, requester
// FSM, victim select, snoop response. Owns its cache_store.
//
// Requester FSM:
//   C_IDLE  req_ready unless another cache's transaction is on this request's set.
//           Accept: a hit (read, or write to M) is serviced now, resp_valid next
//           cycle. Anything else (miss, or write to S) latches and goes to C_WAIT.
//   C_WAIT  bus_req high. On bus_gnt, decide the transaction from the CURRENT state
//           (decide at grant): S-line write -> BusRdX; miss with M victim -> BusWB;
//           miss otherwise -> BusRd / BusRdX. Latch it, go to C_BUS.
//   C_BUS   Wait for bus_done. BusWB: invalidate the victim, back to C_WAIT.
//           BusRd/BusRdX: install line + state, respond, back to C_IDLE.
// Snoop side: on another cache's BusRd/BusRdX that hits here, M drives
// owner_hit_o/owner_data_o; the state transition commits on bus_done.
module cache_ctrl #(
    parameter N      = 2,
    parameter MY_ID  = 0,
    parameter WAYS   = 1,
    parameter SETS   = 4,
    parameter AW     = 32,
    parameter WORD_W = 32,
    parameter LINE_W = 128,
    // Derived -- do not override.
    parameter OFF_W  = $clog2(LINE_W / 8),       // byte offset within a line
    parameter WOFF_W = $clog2(WORD_W / 8),       // byte offset within a word
    parameter WSEL_W = $clog2(LINE_W / WORD_W),  // word select within a line
    parameter IDX_W  = $clog2(SETS),
    parameter TAG_W  = AW - OFF_W - IDX_W,
    parameter LAW    = AW - OFF_W,               // line-address width
    parameter WAY_W  = (WAYS > 1) ? $clog2(WAYS) : 1,
    parameter SRC_W  = (N > 1) ? $clog2(N) : 1
) (
    input  wire                 clk,
    input  wire                 rst,
    // Core side
    input  wire                 req_valid,
    output wire                 req_ready,
    input  wire                 req_we,
    input  wire [AW-1:0]        req_addr,
    input  wire [WORD_W-1:0]    req_wdata,
    output reg                  resp_valid,
    output reg  [WORD_W-1:0]    resp_rdata,
    // Bus, requester side (coh_bus samples these only while bus_gnt is high)
    output wire                 bus_req,
    input  wire                 bus_gnt,      // this cache's bit of the one-hot grant
    output wire [1:0]           bus_cmd_o,
    output wire [LAW-1:0]       bus_addr_o,
    output wire [LINE_W-1:0]    bus_wdata_o,
    // Bus, shared view
    input  wire                 bus_active,   // high from SNOOP through DONE
    input  wire [1:0]           bus_cmd,
    input  wire [LAW-1:0]       bus_addr,
    input  wire [SRC_W-1:0]     bus_src,
    input  wire [LINE_W-1:0]    bus_rdata,
    input  wire                 bus_done,
    // Snoop response
    output wire                 owner_hit_o,
    output wire [LINE_W-1:0]    owner_data_o  // zero unless owner_hit_o
);
    `include "coh_defs.vh"

    localparam [1:0] C_IDLE = 2'd0;
    localparam [1:0] C_WAIT = 2'd1;
    localparam [1:0] C_BUS  = 2'd2;

    localparam [SRC_W-1:0] MY_SRC = MY_ID;

    reg [1:0]        cs;

    // Latched request (valid in C_WAIT / C_BUS)
    reg              lat_we;
    reg [AW-1:0]     lat_addr;
    reg [WORD_W-1:0] lat_wdata;

    // Latched transaction (valid in C_BUS)
    reg [1:0]        txn_cmd;
    reg [WAY_W-1:0]  txn_way;
    reg [LAW-1:0]    txn_addr;
    reg [LINE_W-1:0] txn_wdata;

    // ------------------------------------------------------------------
    // Store
    // ------------------------------------------------------------------
    wire [WAYS*TAG_W-1:0]  a_tag,  b_tag;
    wire [WAYS*2-1:0]      a_st,   b_st;
    wire [WAYS*LINE_W-1:0] a_data, b_data;
    wire [WAY_W-1:0]       a_lru;

    reg                    lw_en;
    reg  [IDX_W-1:0]       lw_idx;
    reg  [WAY_W-1:0]       lw_way;
    reg  [TAG_W-1:0]       lw_tag;
    reg  [1:0]             lw_st;
    reg  [LINE_W-1:0]      lw_data;
    reg                    sw_en;
    reg  [IDX_W-1:0]       sw_idx;
    reg  [WAY_W-1:0]       sw_way;
    reg  [1:0]             sw_st;
    reg                    lu_en;
    reg  [IDX_W-1:0]       lu_idx;
    reg  [WAY_W-1:0]       lu_way;

    // Port A looks at the incoming request while idle, the latched one otherwise.
    wire [AW-1:0]     a_addr = (cs == C_IDLE) ? req_addr : lat_addr;
    wire [IDX_W-1:0]  a_idx  = a_addr[OFF_W +: IDX_W];
    wire [TAG_W-1:0]  a_tagq = a_addr[AW-1 -: TAG_W];
    wire [WSEL_W-1:0] a_wsel = a_addr[WOFF_W +: WSEL_W];
    wire [LAW-1:0]    a_line = a_addr[AW-1 -: LAW];

    // Port B looks at the bus (bus_addr is a line address).
    wire [IDX_W-1:0]  b_idx  = bus_addr[IDX_W-1:0];
    wire [TAG_W-1:0]  b_tagq = bus_addr[LAW-1 -: TAG_W];

    cache_store #(
        .WAYS   (WAYS),
        .SETS   (SETS),
        .TAG_W  (TAG_W),
        .LINE_W (LINE_W)
    ) u_store (
        .clk    (clk),
        .rst    (rst),
        .a_idx  (a_idx),
        .a_tag  (a_tag),
        .a_st   (a_st),
        .a_data (a_data),
        .a_lru  (a_lru),
        .b_idx  (b_idx),
        .b_tag  (b_tag),
        .b_st   (b_st),
        .b_data (b_data),
        .lw_en  (lw_en),
        .lw_idx (lw_idx),
        .lw_way (lw_way),
        .lw_tag (lw_tag),
        .lw_st  (lw_st),
        .lw_data(lw_data),
        .sw_en  (sw_en),
        .sw_idx (sw_idx),
        .sw_way (sw_way),
        .sw_st  (sw_st),
        .lu_en  (lu_en),
        .lu_idx (lu_idx),
        .lu_way (lu_way)
    );

    function [LINE_W-1:0] merge_word;
        input [LINE_W-1:0] line;
        input [WSEL_W-1:0] sel;
        input [WORD_W-1:0] wd;
        begin
            merge_word = line;
            merge_word[sel*WORD_W +: WORD_W] = wd;
        end
    endfunction

    // ------------------------------------------------------------------
    // Port A lookup: hit way, lowest invalid way, victim
    // ------------------------------------------------------------------
    reg             a_hit;
    reg [WAY_W-1:0] a_hit_way;
    reg [1:0]       a_hit_st;
    reg             a_has_inv;
    reg [WAY_W-1:0] a_inv_way;
    integer         w;   // port A loop
    integer         v;   // port B loop (separate: always @* blocks must not share a variable)

    always @* begin
        a_hit     = 1'b0;
        a_hit_way = {WAY_W{1'b0}};
        a_hit_st  = ST_I;
        a_has_inv = 1'b0;
        a_inv_way = {WAY_W{1'b0}};
        // Descending, so the lowest-index invalid way wins.
        for (w = WAYS - 1; w >= 0; w = w - 1) begin
            if (a_st[w*2 +: 2] == ST_I) begin
                a_has_inv = 1'b1;
                a_inv_way = w[WAY_W-1:0];
            end else if (a_tag[w*TAG_W +: TAG_W] == a_tagq) begin
                a_hit     = 1'b1;
                a_hit_way = w[WAY_W-1:0];
                a_hit_st  = a_st[w*2 +: 2];
            end
        end
    end

    wire [LINE_W-1:0] a_hit_line = a_data[a_hit_way*LINE_W +: LINE_W];
    wire [WAY_W-1:0]  vic_way    = a_has_inv ? a_inv_way : a_lru;
    wire [1:0]        vic_st     = a_st  [vic_way*2      +: 2];
    wire [TAG_W-1:0]  vic_tag    = a_tag [vic_way*TAG_W  +: TAG_W];
    wire [LINE_W-1:0] vic_data   = a_data[vic_way*LINE_W +: LINE_W];

    // A local hit is a read of S/M or a write of M. A write of S is an upgrade miss.
    wire local_hit = a_hit && (!req_we || a_hit_st == ST_M);

    // ------------------------------------------------------------------
    // Snoop-beats-local: block a local access to the set under another
    // cache's transaction, from grant through bus_done.
    // ------------------------------------------------------------------
    wire set_blocked = bus_active && (bus_src != MY_SRC) &&
                       (bus_addr[IDX_W-1:0] == req_addr[OFF_W +: IDX_W]);
    assign req_ready = (cs == C_IDLE) && !set_blocked;
    wire   accept    = req_valid && req_ready;

    // ------------------------------------------------------------------
    // Decide at grant (evaluated in C_WAIT on the latched request)
    // ------------------------------------------------------------------
    reg [1:0]        dec_cmd;
    reg [WAY_W-1:0]  dec_way;
    reg [LAW-1:0]    dec_addr;
    reg [LINE_W-1:0] dec_wdata;
    // Port A follows req_addr in C_IDLE and lat_addr after; the write flag follows
    // the same way so the decision logic is also valid at accept (used by MUT_3).
    wire             dec_we = (cs == C_IDLE) ? req_we : lat_we;

    always @* begin
        dec_cmd   = dec_we ? CMD_BUSRDX : CMD_BUSRD;
        dec_way   = vic_way;
        dec_addr  = a_line;
        dec_wdata = {LINE_W{1'b0}};
        if (a_hit) begin
            // Only reachable as a write to a line still in S: upgrade with data.
            dec_cmd = CMD_BUSRDX;
            dec_way = a_hit_way;
        end
`ifndef MUT_5
        else if (vic_st == ST_M) begin
            // Dirty victim: write it back first, re-request for the miss after.
            dec_cmd   = CMD_BUSWB;
            dec_addr  = {vic_tag, a_idx};
            dec_wdata = vic_data;
        end
`endif
        // MUT_5: the dirty victim is overwritten by the fill without a BusWB.
    end

`ifdef MUT_3
    // MUT_3: the transaction is fixed at request (accept) time and replayed at
    // grant, including "write to S = upgrade that keeps the local copy" (the line
    // was present when the decision was made). A snoop that changes the line
    // while the request waits is ignored -- the race decide-at-grant prevents.
    reg [1:0]        mq_cmd;
    reg [WAY_W-1:0]  mq_way;
    reg [LAW-1:0]    mq_addr;
    reg [LINE_W-1:0] mq_wdata;
    reg              mq_upg;
    reg              txn_upg;
    wire [1:0]        g_cmd   = mq_cmd;
    wire [WAY_W-1:0]  g_way   = mq_way;
    wire [LAW-1:0]    g_addr  = mq_addr;
    wire [LINE_W-1:0] g_wdata = mq_wdata;
`else
    wire [1:0]        g_cmd   = dec_cmd;
    wire [WAY_W-1:0]  g_way   = dec_way;
    wire [LAW-1:0]    g_addr  = dec_addr;
    wire [LINE_W-1:0] g_wdata = dec_wdata;
`endif

    assign bus_req     = (cs == C_WAIT);
    assign bus_cmd_o   = (cs == C_WAIT) ? g_cmd   : txn_cmd;
    assign bus_addr_o  = (cs == C_WAIT) ? g_addr  : txn_addr;
    assign bus_wdata_o = (cs == C_WAIT) ? g_wdata : txn_wdata;

    wire my_done = (cs == C_BUS) && bus_done;

    // ------------------------------------------------------------------
    // Snoop lookup (port B)
    // ------------------------------------------------------------------
    reg             s_hit;
    reg [WAY_W-1:0] s_hit_way;
    reg [1:0]       s_hit_st;

    always @* begin
        s_hit     = 1'b0;
        s_hit_way = {WAY_W{1'b0}};
        s_hit_st  = ST_I;
        for (v = 0; v < WAYS; v = v + 1) begin
            if (b_st[v*2 +: 2] != ST_I && b_tag[v*TAG_W +: TAG_W] == b_tagq) begin
                s_hit     = 1'b1;
                s_hit_way = v[WAY_W-1:0];
                s_hit_st  = b_st[v*2 +: 2];
            end
        end
    end

    // BusWB is never snooped: if the writer held M, nobody else holds the line.
    wire snoop_en = bus_active && (bus_src != MY_SRC) &&
                    (bus_cmd == CMD_BUSRD || bus_cmd == CMD_BUSRDX);
    wire snoop_hit = snoop_en && s_hit;

`ifdef MUT_2
    // MUT_2: the M owner stays silent on a snooped BusRd (no data, no memory
    // write) but still drops to S -- memory is stale under an S copy.
    assign owner_hit_o  = snoop_hit && (s_hit_st == ST_M) && (bus_cmd == CMD_BUSRDX);
`else
    assign owner_hit_o  = snoop_hit && (s_hit_st == ST_M);
`endif
    assign owner_data_o = owner_hit_o ? b_data[s_hit_way*LINE_W +: LINE_W] : {LINE_W{1'b0}};

    // M + BusRd -> S;  M/S + BusRdX -> I;  S + BusRd -> no change.
`ifdef MUT_1
    // MUT_1: a snooped BusRdX never invalidates (only M + BusRd -> S remains).
    wire snoop_commit = snoop_hit && bus_done && (bus_cmd == CMD_BUSRD) && (s_hit_st == ST_M);
`else
    wire snoop_commit = snoop_hit && bus_done &&
                        (bus_cmd == CMD_BUSRDX || s_hit_st == ST_M);
`endif

    // ------------------------------------------------------------------
    // Store write ports
    // ------------------------------------------------------------------
    always @* begin
        lw_en   = 1'b0;
        lw_idx  = a_idx;
        lw_way  = a_hit_way;
        lw_tag  = a_tagq;
        lw_st   = ST_M;
        lw_data = merge_word(a_hit_line, a_wsel, req_wdata);
        sw_en   = 1'b0;
        sw_idx  = b_idx;
        sw_way  = s_hit_way;
        sw_st   = ST_I;
        lu_en   = 1'b0;
        lu_idx  = a_idx;
        lu_way  = a_hit_way;

        // Local hit: LRU update; a store also rewrites the line.
        if (accept && local_hit) begin
`ifndef MUT_6
            lu_en = 1'b1;
`endif
            // MUT_6: a local hit does not update LRU (data unaffected).
            lw_en = req_we;
        end

        // Own transaction completes (port A is on the latched request here).
        if (my_done) begin
            if (txn_cmd == CMD_BUSWB) begin
                sw_en  = 1'b1;
                sw_idx = a_idx;
                sw_way = txn_way;
                sw_st  = ST_I;
            end else begin
                lw_en   = 1'b1;
                lw_way  = txn_way;
                lw_st   = (txn_cmd == CMD_BUSRDX) ? ST_M : ST_S;
                lw_data = lat_we ? merge_word(bus_rdata, a_wsel, lat_wdata) : bus_rdata;
`ifdef MUT_3
                // Upgrade decided at request: keep the (possibly stale) local copy.
                if (txn_upg)
                    lw_data = merge_word(a_data[txn_way*LINE_W +: LINE_W], a_wsel, lat_wdata);
`endif
                lu_en   = 1'b1;
                lu_way  = txn_way;
            end
        end

        // Snoop transition (never in the same cycle as my_done).
        if (snoop_commit) begin
            sw_en  = 1'b1;
            sw_idx = b_idx;
            sw_way = s_hit_way;
            sw_st  = (bus_cmd == CMD_BUSRD) ? ST_S : ST_I;
        end
    end

    // ------------------------------------------------------------------
    // Requester FSM
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            cs         <= C_IDLE;
            resp_valid <= 1'b0;
            resp_rdata <= {WORD_W{1'b0}};
            lat_we     <= 1'b0;
            lat_addr   <= {AW{1'b0}};
            lat_wdata  <= {WORD_W{1'b0}};
            txn_cmd    <= CMD_NONE;
            txn_way    <= {WAY_W{1'b0}};
            txn_addr   <= {LAW{1'b0}};
            txn_wdata  <= {LINE_W{1'b0}};
        end else begin
            resp_valid <= 1'b0;
            case (cs)
                C_IDLE: begin
                    if (accept) begin
                        if (local_hit) begin
                            resp_valid <= 1'b1;
                            resp_rdata <= req_we ? {WORD_W{1'b0}}
                                                 : a_hit_line[a_wsel*WORD_W +: WORD_W];
                        end else begin
                            lat_we    <= req_we;
                            lat_addr  <= req_addr;
                            lat_wdata <= req_wdata;
                            cs        <= C_WAIT;
`ifdef MUT_3
                            mq_cmd    <= dec_cmd;
                            mq_way    <= dec_way;
                            mq_addr   <= dec_addr;
                            mq_wdata  <= dec_wdata;
                            mq_upg    <= a_hit;
`endif
                        end
                    end
                end
                C_WAIT: begin
                    if (bus_gnt) begin
                        txn_cmd   <= g_cmd;
                        txn_way   <= g_way;
                        txn_addr  <= g_addr;
                        txn_wdata <= g_wdata;
`ifdef MUT_3
                        txn_upg   <= mq_upg;
`endif
                        cs        <= C_BUS;
                    end
                end
                C_BUS: begin
                    if (bus_done) begin
                        if (txn_cmd == CMD_BUSWB) begin
                            cs <= C_WAIT;
`ifdef MUT_3
                            // After the writeback, replay the fill into the victim way.
                            mq_cmd   <= lat_we ? CMD_BUSRDX : CMD_BUSRD;
                            mq_addr  <= a_line;
                            mq_wdata <= {LINE_W{1'b0}};
                            mq_upg   <= 1'b0;
`endif
                        end else begin
                            resp_valid <= 1'b1;
                            resp_rdata <= lat_we ? {WORD_W{1'b0}}
                                                 : bus_rdata[a_wsel*WORD_W +: WORD_W];
                            cs         <= C_IDLE;
                        end
                    end
                end
                default: cs <= C_IDLE;
            endcase
        end
    end
endmodule
