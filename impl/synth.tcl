# Vivado non-project, out-of-context implementation of coh_top (defaults: N=2,
# WAYS=2) for LUT / FF / Fmax. Run from the repo root:
#   vivado -mode batch -nojournal -log results/vivado/vivado.log -source impl/synth.tcl
# Fmax = 1000 / (period - WNS) MHz from the routed design.
set part   xc7a100tcsg324-1
set period 10.000
set out    results/vivado
file mkdir $out

read_verilog [glob rtl/*.v]
read_xdc -mode out_of_context impl/coh_top.xdc
synth_design -top coh_top -part $part -mode out_of_context -include_dirs rtl
report_utilization -file $out/util_synth.rpt
opt_design
place_design
route_design
report_utilization      -file $out/util_routed.rpt
report_timing_summary   -file $out/timing_routed.rpt

set wns  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set luts [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ffs  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set lram [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DMEM}]]
set lat  [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ REGISTER.LATCH.*}]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts [format "VIVADO: part=%s LUT=%d FF=%d LUTRAM_cells=%d latches=%d WNS=%.3f ns Fmax=%.1f MHz" \
      $part $luts $ffs $lram $lat $wns $fmax]
