// Tests. coh_base_test builds the env and, in run_phase, starts one sequence per
// agent in fork...join (no virtual sequencer). Subclasses pick the traffic mode
// by overriding make_seq(). +N_OPS=<n> sets accesses per core (default 1000).
class coh_base_test extends uvm_test;
    `uvm_component_utils(coh_base_test)

    coh_env      env;
    int unsigned n_ops = 1000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        if ($value$plusargs("N_OPS=%d", n_ops))
            `uvm_info("TEST", $sformatf("+N_OPS=%0d", n_ops), UVM_LOW)
        env = coh_env::type_id::create("env", this);
    endfunction

    // Traffic mode hook: a configured (not yet started) sequence for one core.
    virtual function coh_base_seq make_seq(int unsigned core);
        coh_private_seq s = coh_private_seq::type_id::create($sformatf("seq%0d", core));
        return s;
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        uvm_top.set_timeout(50ms, 0);
    endfunction

    task run_phase(uvm_phase phase);
        coh_base_seq seqs[$];
        phase.raise_objection(this);
        `uvm_info("TEST", $sformatf("%s: N=%0d, %0d ops per core",
                                    get_type_name(), env.n_cores, n_ops), UVM_NONE)
        foreach (env.agt[i]) begin
            coh_base_seq s = make_seq(i);
            s.core_id = i;
            s.n_ops   = n_ops;
            seqs.push_back(s);
        end
        fork
            begin
                foreach (seqs[i]) begin
                    automatic int k = i;
                    fork
                        seqs[k].start(env.agt[k].sqr);
                    join_none
                end
                wait fork;
            end
        join
        repeat (10) @(env.bvif.mon_cb);
        phase.drop_objection(this);
    endtask
endclass

class coh_private_test extends coh_base_test;
    `uvm_component_utils(coh_private_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass

class coh_share_test extends coh_base_test;
    `uvm_component_utils(coh_share_test)
    bit [31:0] hot[$];
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    // 2-4 hot lines, chosen once per run, same for every core. Mix of sets, and
    // two tags in one set so a WAYS=1 cache also evicts.
    function void start_of_simulation_phase(uvm_phase phase);
        int unsigned n_hot = $urandom_range(4, 2);
        bit [31:0]   cand[4] = '{coh_base_seq::line_addr(64, 0), coh_base_seq::line_addr(65, 1),
                                 coh_base_seq::line_addr(66, 0), coh_base_seq::line_addr(67, 2)};
        for (int i = 0; i < n_hot; i++) hot.push_back(cand[i]);
        `uvm_info("TEST", $sformatf("%0d hot lines", n_hot), UVM_NONE)
    endfunction
    virtual function coh_base_seq make_seq(int unsigned core);
        coh_share_seq s = coh_share_seq::type_id::create($sformatf("seq%0d", core));
        s.hot = hot;
        return s;
    endfunction
endclass

class coh_conflict_test extends coh_base_test;
    `uvm_component_utils(coh_conflict_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    virtual function coh_base_seq make_seq(int unsigned core);
        coh_conflict_seq s = coh_conflict_seq::type_id::create($sformatf("seq%0d", core));
        return s;
    endfunction
endclass

class coh_pingpong_test extends coh_base_test;
    `uvm_component_utils(coh_pingpong_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    virtual function coh_base_seq make_seq(int unsigned core);
        coh_pingpong_seq s = coh_pingpong_seq::type_id::create($sformatf("seq%0d", core));
        return s;
    endfunction
endclass

class coh_falseshare_test extends coh_base_test;
    `uvm_component_utils(coh_falseshare_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    virtual function coh_base_seq make_seq(int unsigned core);
        coh_falseshare_seq s = coh_falseshare_seq::type_id::create($sformatf("seq%0d", core));
        return s;
    endfunction
endclass
