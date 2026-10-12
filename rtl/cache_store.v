// cache_store -- tag / state / data / LRU arrays for one cache, way-generic.
// Entry (set s, way w) lives at s*WAYS + w. Reads are combinational.
//   Port A: local lookup (core request, or the latched request while missing).
//   Port B: snoop lookup (bus_addr).
// Writes:
//   lw_*: full line write (tag + state + data) -- fill, or store hit (merged line).
//   sw_*: state-only write -- snoop transition, or invalidation after BusWB.
//   lu_*: mark a way most recently used.
// A cycle can carry one lw and one sw only to different sets (cache_ctrl
// guarantees this via the snoop-beats-local block).
module cache_store #(
    parameter WAYS   = 1,
    parameter SETS   = 4,
    parameter TAG_W  = 26,
    parameter LINE_W = 128,
    // Derived -- do not override.
    parameter IDX_W  = $clog2(SETS),
    parameter WAY_W  = (WAYS > 1) ? $clog2(WAYS) : 1
) (
    input  wire                     clk,
    input  wire                     rst,
    // Read port A
    input  wire [IDX_W-1:0]         a_idx,
    output wire [WAYS*TAG_W-1:0]    a_tag,   // way w at [w*TAG_W +: TAG_W]
    output wire [WAYS*2-1:0]        a_st,    // way w at [w*2 +: 2]
    output wire [WAYS*LINE_W-1:0]   a_data,  // way w at [w*LINE_W +: LINE_W]
    output wire [WAY_W-1:0]         a_lru,   // LRU way of set a_idx
    // Read port B
    input  wire [IDX_W-1:0]         b_idx,
    output wire [WAYS*TAG_W-1:0]    b_tag,
    output wire [WAYS*2-1:0]        b_st,
    output wire [WAYS*LINE_W-1:0]   b_data,
    // Line write
    input  wire                     lw_en,
    input  wire [IDX_W-1:0]         lw_idx,
    input  wire [WAY_W-1:0]         lw_way,
    input  wire [TAG_W-1:0]         lw_tag,
    input  wire [1:0]               lw_st,
    input  wire [LINE_W-1:0]        lw_data,
    // State write
    input  wire                     sw_en,
    input  wire [IDX_W-1:0]         sw_idx,
    input  wire [WAY_W-1:0]         sw_way,
    input  wire [1:0]               sw_st,
    // LRU update
    input  wire                     lu_en,
    input  wire [IDX_W-1:0]         lu_idx,
    input  wire [WAY_W-1:0]         lu_way
);
    `include "coh_defs.vh"

    localparam ENTRIES = SETS * WAYS;

    reg [TAG_W-1:0]  tag_mem  [0:ENTRIES-1];
    reg [1:0]        st_mem   [0:ENTRIES-1];
    reg [LINE_W-1:0] data_mem [0:ENTRIES-1];
    reg [WAY_W-1:0]  lru_mem  [0:SETS-1];     // LRU way per set

    integer i;

    genvar w;
    generate
        for (w = 0; w < WAYS; w = w + 1) begin : g_rd
            assign a_tag [w*TAG_W  +: TAG_W ] = tag_mem [a_idx*WAYS + w];
            assign a_st  [w*2      +: 2     ] = st_mem  [a_idx*WAYS + w];
            assign a_data[w*LINE_W +: LINE_W] = data_mem[a_idx*WAYS + w];
            assign b_tag [w*TAG_W  +: TAG_W ] = tag_mem [b_idx*WAYS + w];
            assign b_st  [w*2      +: 2     ] = st_mem  [b_idx*WAYS + w];
            assign b_data[w*LINE_W +: LINE_W] = data_mem[b_idx*WAYS + w];
        end
    endgenerate
    assign a_lru = lru_mem[a_idx];

    // Tags and data need no reset: every way starts in I.
    always @(posedge clk) begin
        if (lw_en) begin
            tag_mem [lw_idx*WAYS + lw_way] <= lw_tag;
            data_mem[lw_idx*WAYS + lw_way] <= lw_data;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1) st_mem[i]  <= ST_I;
            for (i = 0; i < SETS;    i = i + 1) lru_mem[i] <= {WAY_W{1'b0}};
        end else begin
            if (lw_en) st_mem[lw_idx*WAYS + lw_way] <= lw_st;
            if (sw_en) st_mem[sw_idx*WAYS + sw_way] <= sw_st;
            // WAYS is 1 or 2: with 2 ways the LRU way is the one not just used.
            if (lu_en) lru_mem[lu_idx] <= (WAYS == 2) ? ~lu_way : {WAY_W{1'b0}};
        end
    end
endmodule
