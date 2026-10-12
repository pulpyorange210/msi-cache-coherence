// coh_env -- one core_agent per core_vif_<i> found in config_db (that count is
// N), one bus_monitor, one scoreboard fed by every core monitor.
class coh_env extends uvm_env;
    `uvm_component_utils(coh_env)

    int unsigned   n_cores;
    core_agent     agt[$];
    bus_monitor    bmon;
    coh_scoreboard sb;
    virtual bus_if bvif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        virtual core_if vif;
        while (uvm_config_db#(virtual core_if)::get(this, "", $sformatf("core_vif_%0d", n_cores), vif)) begin
            agt.push_back(core_agent::type_id::create($sformatf("agt%0d", n_cores), this));
            agt[n_cores].vif     = vif;
            agt[n_cores].core_id = n_cores;
            n_cores++;
        end
        if (n_cores == 0) `uvm_fatal("ENV", "no core_vif_0 in config_db")
        if (!uvm_config_db#(virtual bus_if)::get(this, "", "bus_vif", bvif))
            `uvm_fatal("ENV", "no bus_vif in config_db")
        bmon = bus_monitor::type_id::create("bmon", this);
        sb   = coh_scoreboard::type_id::create("sb", this);
        bmon.vif = bvif;
        sb.bvif  = bvif;
        `uvm_info("ENV", $sformatf("N = %0d cores", n_cores), UVM_NONE)
    endfunction

    function void connect_phase(uvm_phase phase);
        foreach (agt[i]) agt[i].mon.ap.connect(sb.imp);
    endfunction

    function void report_phase(uvm_phase phase);
        int unsigned     ops = 0, hits = 0;
        longint unsigned lat_max = 0, lat_sum = 0;
        foreach (agt[i]) begin
            ops     += agt[i].mon.n_ops;
            hits    += agt[i].mon.n_hits;
            lat_sum += agt[i].mon.lat_sum;
            if (agt[i].mon.lat_max > lat_max) lat_max = agt[i].mon.lat_max;
        end
        // One machine-readable line per run, parsed by the run scripts.
        `uvm_info("STAT", $sformatf("STAT: ops=%0d hits=%0d hit_rate=%0.3f bus_txn=%0d rd=%0d rdx=%0d wb=%0d txn_per_op=%0.3f owner=%0d contend=%0d lat_avg=%0.2f lat_max=%0d",
                                    ops, hits, ops ? real'(hits) / ops : 0.0, bmon.n_txn(), bmon.n_rd, bmon.n_rdx,
                                    bmon.n_wb, ops ? real'(bmon.n_txn()) / ops : 0.0, bmon.n_owner, bmon.n_contend,
                                    ops ? real'(lat_sum) / ops : 0.0, lat_max), UVM_NONE)
    endfunction
endclass
