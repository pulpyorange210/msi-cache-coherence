// bus_if -- passive view of the shared bus (for bus_monitor) plus a snapshot of
// every cache's tag/state/data arrays (driven hierarchically by tb_top), so the
// scoreboard's end-of-test check can compute the coherent value of any word:
// the M copy if some cache holds the line in M, else memory.
//
// Sized to the project's hard limits (NMAX = 4 cores, WMAX = 2 ways), not to the
// DUT's N/WAYS: the UVM package then names one non-parameterized `virtual bus_if`
// whatever N and WAYS the snapshot is elaborated with. tb_top drives the entries
// that exist and ties the rest to zero (state I, no request, no grant).
`timescale 1ns/1ps
interface bus_if #(
    parameter int NMAX   = 4,
    parameter int WMAX   = 2,
    parameter int SETS   = 4,
    parameter int LAW    = 28,
    parameter int LINE_W = 128,
    // Derived -- do not override.
    parameter int IDX_W  = $clog2(SETS),
    parameter int TAG_W  = LAW - IDX_W
) (
    input logic clk,
    input logic rst
);
    // Bus (cache i at bit i of bus_req / bus_gnt)
    logic [NMAX-1:0]   bus_req;
    logic [NMAX-1:0]   bus_gnt;
    logic              bus_active;
    logic [1:0]        bus_cmd;
    logic [LAW-1:0]    bus_addr;
    logic [1:0]        bus_src;
    logic [LINE_W-1:0] bus_rdata;
    logic              owner_hit;
    logic              bus_done;

    // Cache array snapshot: [cache][set][way]
    logic [1:0]        st   [NMAX][SETS][WMAX];
    logic [TAG_W-1:0]  tag  [NMAX][SETS][WMAX];
    logic [LINE_W-1:0] data [NMAX][SETS][WMAX];

    clocking mon_cb @(posedge clk);
        default input #1step;
        input bus_req, bus_gnt, bus_active, bus_cmd, bus_addr, bus_src, bus_rdata, owner_hit, bus_done, rst;
    endclocking

    // M copy of the line holding `addr`, if any cache has one.
    function automatic bit m_copy(input logic [31:0] addr, output logic [31:0] word);
        logic [LAW-1:0]   line;
        logic [IDX_W-1:0] idx;
        logic [TAG_W-1:0] tg;
        line = addr[31 -: LAW];
        idx  = line[IDX_W-1:0];
        tg   = line[LAW-1 -: TAG_W];
        word = '0;
        for (int c = 0; c < NMAX; c++)
            for (int w = 0; w < WMAX; w++)
                if (st[c][idx][w] == 2'b10 && tag[c][idx][w] == tg) begin
                    word = data[c][idx][w][addr[3:2]*32 +: 32];
                    return 1'b1;
                end
        return 1'b0;
    endfunction

    // Coherent value of the word at `addr`: the M copy if any, else memory.
    // u_mem resolves upward to tb_top.u_mem (this interface lives in tb_top).
    function automatic logic [31:0] coherent_word(input logic [31:0] addr);
        logic [31:0]       word;
        logic [LINE_W-1:0] line;
        if (m_copy(addr, word)) return word;
        line = u_mem.peek(addr[31 -: LAW]);
        return line[addr[3:2]*32 +: 32];
    endfunction
endinterface
