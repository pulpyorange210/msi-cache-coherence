// p0_tb -- Phase 0 toolchain gate. Passes (UVM_ERROR : 0, UVM_FATAL : 0) only if:
//   1. a UVM test runs on xsim,
//   2. the bound covergroup prints a COV: percentage (expect 100.00%),
//   3. the bound concurrent assertion fires exactly once (stimulus drives 2'b11
//      for one cycle; a report catcher counts and demotes that one expected error),
//   4. a hierarchical reference into dut.g_way[1] resolves to a live value.
`timescale 1ns/1ps
`include "uvm_macros.svh"

package p0_pkg;
    import uvm_pkg::*;

    class p0_catcher extends uvm_report_catcher;
        int unsigned n_caught;
        function new(string name = "p0_catcher");
            super.new(name);
        endfunction
        function action_e catch();
            if (get_id() == "P0_SVA" && get_severity() == UVM_ERROR) begin
                n_caught++;
                set_severity(UVM_INFO);
                set_message({"[expected] ", get_message()});
            end
            return THROW;
        endfunction
    endclass

    class p0_test extends uvm_test;
        `uvm_component_utils(p0_test)
        p0_catcher catcher;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            catcher = new("catcher");
            uvm_report_cb::add(null, catcher);
        endfunction

        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            `uvm_info("P0", "hello from UVM on xsim", UVM_NONE)
            #400ns;
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            if (catcher.n_caught != 1)
                `uvm_error("P0", $sformatf("P0_SVA fired %0d times, expected exactly 1", catcher.n_caught))
            else
                `uvm_info("P0", "P0_SVA fired exactly once, as expected", UVM_NONE)
        endfunction
    endclass
endpackage

module p0_tb;
    import uvm_pkg::*;
    import p0_pkg::*;

    logic       clk = 1'b0;
    logic       rst = 1'b1;
    logic [1:0] in  = 2'b00;
    logic [1:0] seq [0:5] = '{2'b00, 2'b01, 2'b10, 2'b01, 2'b11, 2'b00};

    always #5 clk = ~clk;

    p0_dut #(.WAYS(2)) dut (.clk(clk), .rst(rst), .in(in), .st());
    p0_bind u_bind ();

    // Stimulus: I, S, M, then one illegal 2'b11, then idle.
    initial begin
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        foreach (seq[i]) begin
            @(posedge clk);
            in <= seq[i];
        end
        @(posedge clk);
        in <= 2'b00;
    end

    // Hierarchical reference into a generate block.
    initial begin
        repeat (20) @(posedge clk);
        if ($isunknown(dut.g_way[1].cnt) || dut.g_way[1].cnt == 8'd0)
            `uvm_error("P0_HIER", $sformatf("dut.g_way[1].cnt = %0h, expected a live nonzero count", dut.g_way[1].cnt))
        else
            `uvm_info("P0_HIER", $sformatf("dut.g_way[1].cnt = %0d (resolved)", dut.g_way[1].cnt), UVM_NONE)
    end

    initial run_test("p0_test");
endmodule
