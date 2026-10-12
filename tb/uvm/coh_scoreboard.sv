// coh_scoreboard -- flat-memory reference model. One analysis imp; every
// transaction carries core_id. Stores update the reference at completion; every
// load completion is checked against it. Initial contents come from
// mem_init_word() (mem_init.svh), so loads to untouched words are checked too.
// Two completions to the same word in the same cycle, at least one a store, from
// different cores, is itself an error (the bus serializes them; it must not happen).
// check_phase: every touched word's coherent value (M copy, else memory) equals
// the reference.
class coh_scoreboard extends uvm_component;
    `uvm_component_utils(coh_scoreboard)

    uvm_analysis_imp #(core_txn, coh_scoreboard) imp;
    virtual bus_if                               bvif;

    bit [31:0]       ref_mem [bit [31:0]];
    // Last completion per word, for the same-cycle check.
    longint unsigned last_t     [bit [31:0]];
    int unsigned     last_core  [bit [31:0]];
    bit              last_store [bit [31:0]];

    int unsigned n_loads, n_stores, n_checked, n_mismatch, n_final_checked;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        imp = new("imp", this);
    endfunction

    function bit [31:0] ref_rd(bit [31:0] a);
        return ref_mem.exists(a) ? ref_mem[a] : mem_init_word(a);
    endfunction

    function void write(core_txn t);
        bit [31:0] a = {t.addr[31:2], 2'b00};

        if (last_t.exists(a) && last_t[a] == t.t_done && last_core[a] != t.core_id &&
            (last_store[a] || t.we))
            `uvm_error("SB_SAMECYC", $sformatf("word %08h completed by core%0d and core%0d in cycle %0d with a store",
                                               a, last_core[a], t.core_id, t.t_done))
        last_t[a]     = t.t_done;
        last_core[a]  = t.core_id;
        last_store[a] = t.we;

        if (t.we) begin
            ref_mem[a] = t.wdata;
            n_stores++;
        end else begin
            n_loads++;
            n_checked++;
            if (t.rdata !== ref_rd(a)) begin
                n_mismatch++;
                `uvm_error("SB_LOAD", $sformatf("%s: expected %08h", t.convert2string(), ref_rd(a)))
            end
        end
        `uvm_info("SB", t.convert2string(), UVM_HIGH)
    endfunction

    function void check_phase(uvm_phase phase);
        bit [31:0] got;
        foreach (last_t[a]) begin
            n_final_checked++;
            got = bvif.coherent_word(a);
            if (got !== ref_rd(a))
                `uvm_error("SB_FINAL", $sformatf("word %08h: coherent value %08h, reference %08h", a, got, ref_rd(a)))
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", $sformatf("loads=%0d (checked %0d, mismatches %0d) stores=%0d, end-of-test words checked=%0d",
                                  n_loads, n_checked, n_mismatch, n_stores, n_final_checked), UVM_NONE)
    endfunction
endclass
