# coh_top, out-of-context: only the clock is constrained (the flattened core and
# memory ports exceed any package's pin count, so no I/O placement is done).
create_clock -name clk -period 10.000 [get_ports clk]
