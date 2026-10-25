# Vivado non-project build for one window size.
# Usage (from the repository root):
#   vivado -mode batch -source scripts/build.tcl -tclargs <W>
# Writes the bitstream to build/W<W>/ and the reports to reports/W<W>/.
# Every W uses the same part, clock constraint and tool settings.

set W    [lindex $argv 0]
# Work from the repository root with relative paths, because Vivado splits
# absolute paths at the spaces in this project's folder name.
cd [file normalize [file join [file dirname [info script]] ..]]
set out  build/W$W
set rep  reports/W$W
file mkdir $out $rep

read_verilog [glob rtl/*.v]
read_xdc constraints/zedboard.xdc

synth_design -top top_zedboard -part xc7z020clg484-1 -generic W=$W
report_utilization -file [file join $rep synth_utilization.rpt]

opt_design
place_design
phys_opt_design
route_design

report_utilization                -file [file join $rep impl_utilization.rpt]
report_utilization -hierarchical  -file [file join $rep impl_utilization_hier.rpt]
report_timing_summary -max_paths 5 -file [file join $rep timing_summary.rpt]
report_timing -max_paths 5 -nworst 1 -path_type full -file [file join $rep critical_paths.rpt]
report_drc                        -file [file join $rep drc.rpt]

write_bitstream -force [file join $out top_W$W.bit]
puts "BUILD DONE W=$W"
