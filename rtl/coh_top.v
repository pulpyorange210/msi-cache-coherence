// coh_top -- N private MSI caches on one atomic snooping bus, memory port out.
// Core i's signals are at [i] / [i*W +: W] of each flattened port.
module coh_top #(
    parameter N      = 2,
    parameter WAYS   = 2,     // 1 or 2 (bring-up was 1)
    parameter SETS   = 4,
    parameter AW     = 32,
    parameter WORD_W = 32,
    parameter LINE_W = 128,
    // Derived -- do not override.
    parameter LAW    = AW - $clog2(LINE_W / 8),
    parameter SRC_W  = (N > 1) ? $clog2(N) : 1
) (
    input  wire                 clk,
    input  wire                 rst,
    // Cores
    input  wire [N-1:0]         req_valid,
    output wire [N-1:0]         req_ready,
    input  wire [N-1:0]         req_we,
    input  wire [N*AW-1:0]      req_addr,
    input  wire [N*WORD_W-1:0]  req_wdata,
    output wire [N-1:0]         resp_valid,
    output wire [N*WORD_W-1:0]  resp_rdata,
    // Memory
    output wire                 mem_req,
    output wire                 mem_we,
    output wire [LAW-1:0]       mem_addr,
    output wire [LINE_W-1:0]    mem_wdata,
    input  wire [LINE_W-1:0]    mem_rdata,
    input  wire                 mem_ack
);
    wire [N-1:0]         c_req;
    wire [N*2-1:0]       c_cmd;
    wire [N*LAW-1:0]     c_addr;
    wire [N*LINE_W-1:0]  c_wdata;
    wire [N-1:0]         c_owner_hit;
    wire [N*LINE_W-1:0]  c_owner_data;

    wire [N-1:0]         bus_gnt;
    wire                 bus_active;
    wire [1:0]           bus_cmd;
    wire [LAW-1:0]       bus_addr;
    wire [SRC_W-1:0]     bus_src;
    wire [LINE_W-1:0]    bus_wdata;
    wire [LINE_W-1:0]    bus_rdata;
    wire                 owner_hit;
    wire                 bus_done;

    genvar c;
    generate
        for (c = 0; c < N; c = c + 1) begin : g_cache
            cache_ctrl #(
                .N      (N),
                .MY_ID  (c),
                .WAYS   (WAYS),
                .SETS   (SETS),
                .AW     (AW),
                .WORD_W (WORD_W),
                .LINE_W (LINE_W)
            ) u_cache (
                .clk          (clk),
                .rst          (rst),
                .req_valid    (req_valid [c]),
                .req_ready    (req_ready [c]),
                .req_we       (req_we    [c]),
                .req_addr     (req_addr  [c*AW     +: AW]),
                .req_wdata    (req_wdata [c*WORD_W +: WORD_W]),
                .resp_valid   (resp_valid[c]),
                .resp_rdata   (resp_rdata[c*WORD_W +: WORD_W]),
                .bus_req      (c_req     [c]),
                .bus_gnt      (bus_gnt   [c]),
                .bus_cmd_o    (c_cmd     [c*2      +: 2]),
                .bus_addr_o   (c_addr    [c*LAW    +: LAW]),
                .bus_wdata_o  (c_wdata   [c*LINE_W +: LINE_W]),
                .bus_active   (bus_active),
                .bus_cmd      (bus_cmd),
                .bus_addr     (bus_addr),
                .bus_src      (bus_src),
                .bus_rdata    (bus_rdata),
                .bus_done     (bus_done),
                .owner_hit_o  (c_owner_hit [c]),
                .owner_data_o (c_owner_data[c*LINE_W +: LINE_W])
            );
        end
    endgenerate

    coh_bus #(
        .N      (N),
        .LAW    (LAW),
        .LINE_W (LINE_W)
    ) u_bus (
        .clk          (clk),
        .rst          (rst),
        .c_req        (c_req),
        .c_cmd        (c_cmd),
        .c_addr       (c_addr),
        .c_wdata      (c_wdata),
        .c_owner_hit  (c_owner_hit),
        .c_owner_data (c_owner_data),
        .bus_gnt      (bus_gnt),
        .bus_active   (bus_active),
        .bus_cmd      (bus_cmd),
        .bus_addr     (bus_addr),
        .bus_src      (bus_src),
        .bus_wdata    (bus_wdata),
        .bus_rdata    (bus_rdata),
        .owner_hit    (owner_hit),
        .bus_done     (bus_done),
        .mem_req      (mem_req),
        .mem_we       (mem_we),
        .mem_addr     (mem_addr),
        .mem_wdata    (mem_wdata),
        .mem_rdata    (mem_rdata),
        .mem_ack      (mem_ack)
    );
endmodule
