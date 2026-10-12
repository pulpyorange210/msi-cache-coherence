// core_txn -- one core access. Stimulus fields are random; the monitor fills the
// observed fields (rdata, accept/complete cycle) and publishes on completion.
class core_txn extends uvm_sequence_item;
    rand bit          we;
    rand bit [31:0]   addr;     // word-aligned byte address
    rand bit [31:0]   wdata;
    rand int unsigned gap;      // idle cycles the driver waits before issuing

    // Observed (monitor)
    int unsigned      core_id;
    bit [31:0]        rdata;
    longint unsigned  t_acc;    // cycle the request was accepted
    longint unsigned  t_done;   // cycle resp_valid was sampled

    constraint c_aligned { addr[1:0] == 2'b00; }
    constraint c_gap     { gap inside {[0:3]}; gap dist {0 := 6, [1:3] := 4}; }

    `uvm_object_utils_begin(core_txn)
        `uvm_field_int(we,      UVM_ALL_ON)
        `uvm_field_int(addr,    UVM_ALL_ON | UVM_HEX)
        `uvm_field_int(wdata,   UVM_ALL_ON | UVM_HEX)
        `uvm_field_int(core_id, UVM_ALL_ON | UVM_DEC)
        `uvm_field_int(rdata,   UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end

    function new(string name = "core_txn");
        super.new(name);
    endfunction

    function longint unsigned latency();
        return t_done - t_acc;
    endfunction

    function string convert2string();
        return $sformatf("core%0d %s %08h %s %08h  acc@%0d done@%0d", core_id, we ? "ST" : "LD",
                         addr, we ? "<=" : "=>", we ? wdata : rdata, t_acc, t_done);
    endfunction
endclass
