// p0_bind -- Phase 0 probe: attach p0_checker to every p0_dut instance.
module p0_bind;
    bind p0_dut p0_checker u_chk (.clk(clk), .rst(rst), .st(st));
endmodule
