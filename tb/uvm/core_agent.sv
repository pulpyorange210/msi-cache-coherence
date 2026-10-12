// core_agent -- sequencer + driver + monitor for one core. The env sets vif and
// core_id on the handle right after create (config_db only carries the vifs).
class core_agent extends uvm_agent;
    `uvm_component_utils(core_agent)

    virtual core_if                  vif;
    int unsigned                     core_id;
    uvm_sequencer #(core_txn)        sqr;
    core_driver                      drv;
    core_monitor                     mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        sqr = uvm_sequencer#(core_txn)::type_id::create("sqr", this);
        drv = core_driver::type_id::create("drv", this);
        mon = core_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
        drv.vif     = vif;
        mon.vif     = vif;
        mon.core_id = core_id;
    endfunction
endclass
