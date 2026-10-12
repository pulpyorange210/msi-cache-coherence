// coh_pkg -- every UVM class of the coherence testbench.
`include "uvm_macros.svh"
package coh_pkg;
    import uvm_pkg::*;

    `include "mem_init.svh"

    `include "core_txn.sv"
    `include "coh_seqs.sv"
    `include "core_driver.sv"
    `include "core_monitor.sv"
    `include "core_agent.sv"
    `include "bus_monitor.sv"
    `include "coh_scoreboard.sv"
    `include "coh_env.sv"
    `include "coh_tests.sv"
endpackage
