// coh_defs.vh -- MSI state and bus-command encodings.
// Included *inside* each module body, so these are module-scoped localparams.
// No include guard on purpose: a guard would skip the localparams in every module
// after the first one compiled in the same xvlog/Yosys compilation unit.

// Per-way coherence state (2 bits). 2'b11 is illegal (cache_checker asserts this).
localparam [1:0] ST_I = 2'b00;
localparam [1:0] ST_S = 2'b01;
localparam [1:0] ST_M = 2'b10;

// Bus commands. CMD_NONE only appears when the bus is idle.
localparam [1:0] CMD_NONE   = 2'b00;
localparam [1:0] CMD_BUSRD  = 2'b01;  // fetch to read
localparam [1:0] CMD_BUSRDX = 2'b10;  // fetch with ownership (write miss or S->M upgrade)
localparam [1:0] CMD_BUSWB  = 2'b11;  // write back an evicted M line
