// coh_bind -- attaches cache_checker to every cache_ctrl instance. Parameters and
// port expressions resolve in the scope of each bound cache_ctrl, so the checker
// sees that instance's N / MY_ID / WAYS and its internal signals.
module coh_bind;
    bind cache_ctrl cache_checker #(
        .N     (N),
        .MY_ID (MY_ID),
        .WAYS  (WAYS),
        .SETS  (SETS),
        .TAG_W (TAG_W)
    ) u_chk (
        .clk        (clk),
        .rst        (rst),
        .cs         (cs),
        .accept     (accept),
        .req_we     (req_we),
        .local_hit  (local_hit),
        .a_hit      (a_hit),
        .a_hit_st   (a_hit_st),
        .a_hit_way  (a_hit_way),
        .a_has_inv  (a_has_inv),
        .vic_way    (vic_way),
        .vic_st     (vic_st),
        .a_idx      (a_idx),
        .a_tagq     (a_tagq),
        .bus_req    (bus_req),
        .bus_gnt    (bus_gnt),
        .bus_active (bus_active),
        .bus_cmd    (bus_cmd),
        .bus_addr   (bus_addr),
        .bus_src    (bus_src),
        .bus_done   (bus_done),
        .txn_cmd    (txn_cmd),
        .txn_way    (txn_way),
        .snoop_en   (snoop_en),
        .s_hit      (s_hit),
        .s_hit_st   (s_hit_st),
        .owner_hit_o(owner_hit_o)
    );
endmodule
