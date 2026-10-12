// core_driver -- one outstanding request at a time. Waits txn.gap idle cycles,
// raises req_valid with the request held stable until accepted (req_ready
// depends on req_addr, D11), then waits for resp_valid before the next item.
class core_driver extends uvm_driver #(core_txn);
    `uvm_component_utils(core_driver)

    virtual core_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        vif.drv_cb.req_valid <= 1'b0;
        vif.drv_cb.req_we    <= 1'b0;
        vif.drv_cb.req_addr  <= '0;
        vif.drv_cb.req_wdata <= '0;
        do @(vif.drv_cb); while (vif.drv_cb.rst !== 1'b0);

        forever begin
            seq_item_port.get_next_item(req);
            repeat (req.gap) @(vif.drv_cb);
            vif.drv_cb.req_valid <= 1'b1;
            vif.drv_cb.req_we    <= req.we;
            vif.drv_cb.req_addr  <= req.addr;
            vif.drv_cb.req_wdata <= req.wdata;
            // Accepted at the first edge that samples req_ready with req_valid high.
            do @(vif.drv_cb); while (vif.drv_cb.req_ready !== 1'b1);
            vif.drv_cb.req_valid <= 1'b0;
            do @(vif.drv_cb); while (vif.drv_cb.resp_valid !== 1'b1);
            seq_item_port.item_done();
        end
    endtask
endclass
