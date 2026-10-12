// coh_bus -- atomic shared snooping bus: round-robin arbitration, requester and
// owner muxing, bus FSM, memory port. Exactly one transaction from grant to done.
//
//   B_ARB    Any bus_req -> register the round-robin grant, go to B_SNOOP.
//   B_SNOOP  Requester drives cmd/addr (decided at grant); other caches look up
//            combinationally and the M owner, if any, raises owner_hit.
//              BusWB                 -> B_MEM (write victim)
//              owner + BusRd         -> B_MEM (write owner data: S must equal memory)
//              owner + BusRdX        -> B_DONE (no memory write)
//              no owner, BusRd/RdX   -> B_MEM (read)
//   B_MEM    mem_req held until mem_ack.
//   B_DONE   bus_done for one cycle; all state commits here; grant released.
module coh_bus #(
    parameter N      = 2,
    parameter LAW    = 28,
    parameter LINE_W = 128,
    // Derived -- do not override.
    parameter SRC_W  = (N > 1) ? $clog2(N) : 1
) (
    input  wire                 clk,
    input  wire                 rst,
    // From caches (cache i at [i] / [i*W +: W])
    input  wire [N-1:0]         c_req,
    input  wire [N*2-1:0]       c_cmd,
    input  wire [N*LAW-1:0]     c_addr,
    input  wire [N*LINE_W-1:0]  c_wdata,
    input  wire [N-1:0]         c_owner_hit,
    input  wire [N*LINE_W-1:0]  c_owner_data,
    // Shared bus
    output reg  [N-1:0]         bus_gnt,      // one-hot, held from grant to bus_done
    output wire                 bus_active,
    output wire [1:0]           bus_cmd,
    output wire [LAW-1:0]       bus_addr,
    output reg  [SRC_W-1:0]     bus_src,
    output wire [LINE_W-1:0]    bus_wdata,
    output wire [LINE_W-1:0]    bus_rdata,
    output wire                 owner_hit,
    output wire                 bus_done,
    // Memory port
    output wire                 mem_req,
    output wire                 mem_we,
    output wire [LAW-1:0]       mem_addr,
    output wire [LINE_W-1:0]    mem_wdata,
    input  wire [LINE_W-1:0]    mem_rdata,
    input  wire                 mem_ack
);
    `include "coh_defs.vh"

    localparam [1:0] B_ARB   = 2'd0;
    localparam [1:0] B_SNOOP = 2'd1;
    localparam [1:0] B_MEM   = 2'd2;
    localparam [1:0] B_DONE  = 2'd3;

    reg [1:0]        bs;
    reg [1:0]        cmd_r;
    reg [LAW-1:0]    addr_r;
    reg              wr_r;     // memory op is a write
    reg [LINE_W-1:0] data_r;   // write data to memory, then read data to requester

    // ------------------------------------------------------------------
    // Arbiter
    // ------------------------------------------------------------------
    wire [N-1:0] arb_gnt;
    wire         arb_take = (bs == B_ARB) && (|c_req);

    rr_arbiter #(.N(N)) u_arb (
        .clk  (clk),
        .rst  (rst),
        .req  (c_req),
        .take (arb_take),
        .gnt  (arb_gnt)
    );

    // ------------------------------------------------------------------
    // One-hot muxes: requester by bus_gnt, owner by c_owner_hit
    // ------------------------------------------------------------------
    reg [1:0]        req_cmd;
    reg [LAW-1:0]    req_addr;
    reg [LINE_W-1:0] req_wdata;
    reg [LINE_W-1:0] own_data;
    integer          i;

    always @* begin
        req_cmd   = CMD_NONE;
        req_addr  = {LAW{1'b0}};
        req_wdata = {LINE_W{1'b0}};
        own_data  = {LINE_W{1'b0}};
        bus_src   = {SRC_W{1'b0}};
        for (i = 0; i < N; i = i + 1) begin
            if (bus_gnt[i]) begin
                req_cmd   = req_cmd   | c_cmd  [i*2      +: 2];
                req_addr  = req_addr  | c_addr [i*LAW    +: LAW];
                req_wdata = req_wdata | c_wdata[i*LINE_W +: LINE_W];
                bus_src   = i[SRC_W-1:0];
            end
            if (c_owner_hit[i])
                own_data = own_data | c_owner_data[i*LINE_W +: LINE_W];
        end
    end

    assign bus_active = (bs != B_ARB);
    assign bus_cmd    = (bs == B_SNOOP) ? req_cmd  : (bus_active ? cmd_r  : CMD_NONE);
    assign bus_addr   = (bs == B_SNOOP) ? req_addr : (bus_active ? addr_r : {LAW{1'b0}});
    assign bus_wdata  = req_wdata;
    assign bus_rdata  = data_r;
    assign owner_hit  = |c_owner_hit;
    assign bus_done   = (bs == B_DONE);

    assign mem_req    = (bs == B_MEM);
    assign mem_we     = wr_r;
    assign mem_addr   = addr_r;
    assign mem_wdata  = data_r;

    // ------------------------------------------------------------------
    // Bus FSM
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            bs      <= B_ARB;
            bus_gnt <= {N{1'b0}};
            cmd_r   <= CMD_NONE;
            addr_r  <= {LAW{1'b0}};
            wr_r    <= 1'b0;
            data_r  <= {LINE_W{1'b0}};
        end else begin
            case (bs)
                B_ARB: begin
                    if (arb_take) begin
                        bus_gnt <= arb_gnt;
                        bs      <= B_SNOOP;
                    end
                end
                B_SNOOP: begin
                    cmd_r  <= req_cmd;
                    addr_r <= req_addr;
                    if (req_cmd == CMD_BUSWB) begin
                        wr_r   <= 1'b1;
                        data_r <= req_wdata;
                        bs     <= B_MEM;
                    end else if (owner_hit) begin
                        data_r <= own_data;
                        if (req_cmd == CMD_BUSRD) begin
                            wr_r <= 1'b1;
                            bs   <= B_MEM;
                        end else begin
                            wr_r <= 1'b0;
                            bs   <= B_DONE;
                        end
                    end else begin
                        wr_r <= 1'b0;
                        bs   <= B_MEM;
                    end
                end
                B_MEM: begin
                    if (mem_ack) begin
                        if (!wr_r) data_r <= mem_rdata;
                        bs <= B_DONE;
                    end
                end
                B_DONE: begin
                    bus_gnt <= {N{1'b0}};
                    bs      <= B_ARB;
                end
                default: bs <= B_ARB;
            endcase
        end
    end
endmodule
