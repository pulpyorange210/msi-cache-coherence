// p0_checker -- Phase 0 probe: module covergroup + concurrent assertion that
// reports through `uvm_error (the project's one error channel). Bound to p0_dut.
`include "uvm_macros.svh"
module p0_checker (
    input logic       clk,
    input logic       rst,
    input logic [1:0] st
);
    import uvm_pkg::*;

    covergroup cg_st @(posedge clk);
        cp_st: coverpoint st iff (!rst) {
            bins st_i = {2'b00};
            bins st_s = {2'b01};
            bins st_m = {2'b10};
        }
    endgroup
    cg_st cg = new();

    a_no_illegal_state: assert property (@(posedge clk) disable iff (rst) st != 2'b11)
        else `uvm_error("P0_SVA", "state 2'b11 observed")

    final $display("COV: p0_checker cg_st %0.2f%%", cg.get_inst_coverage());
endmodule
