// core_monitor -- passive. Opens a transaction at the edge that samples
// req_valid && req_ready (accept), closes it at the edge that samples resp_valid
// (completion), and publishes it with core_id and both cycle stamps.
class core_monitor extends uvm_monitor;
    `uvm_component_utils(core_monitor)

    virtual core_if                vif;
    int unsigned                   core_id;
    uvm_analysis_port #(core_txn)  ap;

    // Stats
    int unsigned     n_ops, n_hits;
    longint unsigned lat_max, lat_sum;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        core_txn         open_t;
        longint unsigned cyc = 0;
        forever begin
            @(vif.mon_cb);
            cyc++;
            if (vif.mon_cb.rst) begin
                open_t = null;
                continue;
            end
            // Completion first: a response and the next accept can share an edge.
            if (vif.mon_cb.resp_valid) begin
                if (open_t == null)
                    `uvm_error("MON", $sformatf("core%0d: resp_valid with no request outstanding", core_id))
                else begin
                    open_t.rdata  = vif.mon_cb.resp_rdata;
                    open_t.t_done = cyc;
                    n_ops++;
                    if (open_t.latency() == 1) n_hits++;
                    lat_sum += open_t.latency();
                    if (open_t.latency() > lat_max) lat_max = open_t.latency();
                    ap.write(open_t);
                    open_t = null;
                end
            end
            if (vif.mon_cb.req_valid && vif.mon_cb.req_ready) begin
                if (open_t != null)
                    `uvm_error("MON", $sformatf("core%0d: request accepted with one outstanding", core_id))
                open_t         = core_txn::type_id::create("mon_t");
                open_t.core_id = core_id;
                open_t.we      = vif.mon_cb.req_we;
                open_t.addr    = vif.mon_cb.req_addr;
                open_t.wdata   = vif.mon_cb.req_wdata;
                open_t.t_acc   = cyc;
            end
        end
    endtask
endclass
