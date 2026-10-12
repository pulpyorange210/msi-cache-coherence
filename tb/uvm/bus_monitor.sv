// bus_monitor -- passive bus statistics, sampled at bus_done (when every state
// change commits): transactions per command, owner (cache-to-cache) transfers,
// and same-cycle contention (more than one bus_req when a grant is taken).
class bus_monitor extends uvm_monitor;
    `uvm_component_utils(bus_monitor)

    virtual bus_if vif;

    int unsigned n_rd, n_rdx, n_wb, n_owner, n_contend, n_bad;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function int unsigned n_txn();
        return n_rd + n_rdx + n_wb;
    endfunction

    task run_phase(uvm_phase phase);
        bit active_q = 1'b0;
        forever begin
            @(vif.mon_cb);
            if (vif.mon_cb.rst) begin
                active_q = 1'b0;
                continue;
            end
            // Grant taken this edge: bus_active rises in the first SNOOP cycle.
            if (vif.mon_cb.bus_active && !active_q && $countones(vif.mon_cb.bus_req) > 1)
                n_contend++;
            active_q = vif.mon_cb.bus_active;
            if (vif.mon_cb.bus_done) begin
                case (vif.mon_cb.bus_cmd)
                    2'b01:   n_rd++;
                    2'b10:   n_rdx++;
                    2'b11:   n_wb++;
                    default: begin
                        n_bad++;
                        `uvm_error("BUSMON", $sformatf("bus_done with bus_cmd %b", vif.mon_cb.bus_cmd))
                    end
                endcase
                if (vif.mon_cb.owner_hit) n_owner++;
            end
        end
    endtask
endclass
