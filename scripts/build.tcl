# Vivado non-project build for one window size and one UART variant.
# Usage (from the repository root):
#   vivado -mode batch -source scripts/build.tcl -tclargs <W> [pmod|ps]
#
#   pmod (default)  PC link through a Pmod USBUART on JA. Pure FPGA logic.
#                   Bitstream in build/W<W>/, reports in reports/W<W>/.
#   ps              PC link through the ZedBoard's own UART port (J14), relayed by
#                   the ARM processor. Bitstream and ps7_init.tcl in build/ps_W<W>/,
#                   reports in reports/ps_W<W>/.
# Every W uses the same part, clock constraint and tool settings.

set W       [lindex $argv 0]
set variant [expr {[llength $argv] > 1 ? [lindex $argv 1] : "pmod"}]
# Work from the repository root with relative paths, because Vivado splits
# absolute paths at the spaces in this project's folder name.
cd [file normalize [file join [file dirname [info script]] ..]]
set tag  [expr {$variant eq "ps" ? "ps_W$W" : "W$W"}]
set out  build/$tag
set rep  reports/$tag
file mkdir $out $rep

if {$variant eq "ps"} {
    # Board files must be registered before the project is created.
    set board_repo [expr {[info exists ::env(BOARD_REPO)] ? $::env(BOARD_REPO) \
        : "C:/AMDDesignTools2/XilinxBoardStore-2025.2/XilinxBoardStore-2025.2"}]
    set_param board.repoPaths [list $board_repo]
}
create_project -in_memory -part xc7z020clg484-1
read_verilog [glob rtl/*.v]
read_xdc constraints/zedboard_base.xdc

if {$variant eq "ps"} {
    # The ZedBoard preset sets up DDR, clocks and the MIO pins, including UART1
    # on the J14 USB-UART chip. UART0 is routed to the FPGA logic through EMIO.
    set board [lindex [lsort -dictionary [get_board_parts -quiet digilentinc.com:zedboard:part0:*]] end]
    if {$board eq ""} { error "ZedBoard board files not found in $board_repo. Set BOARD_REPO." }
    set_property board_part $board [current_project]

    create_bd_design -dir $out ps_bridge
    create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
    apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
        -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
        [get_bd_cells ps7]
    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0 {0} \
        CONFIG.PCW_EN_CLK0_PORT {0} \
        CONFIG.PCW_EN_RST0_PORT {0} \
        CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
        CONFIG.PCW_UART0_UART0_IO {EMIO} \
    ] [get_bd_cells ps7]
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:uart_rtl:1.0 UART_0
    connect_bd_intf_net [get_bd_intf_pins ps7/UART_0] [get_bd_intf_ports UART_0]
    validate_bd_design
    save_bd_design

    set bd [get_files ps_bridge.bd]
    set_property synth_checkpoint_mode None $bd
    generate_target all $bd
    make_wrapper -files $bd -top
    read_verilog $out/ps_bridge/hdl/ps_bridge_wrapper.v
    file copy -force [lindex [glob $out/ps_bridge/ip/*/ps7_init.tcl] 0] $out/ps7_init.tcl
    set top top_zedboard_ps
} else {
    read_xdc constraints/pmod_uart.xdc
    set top top_zedboard
}

synth_design -top $top -part xc7z020clg484-1 -generic W=$W
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

write_bitstream -force [file join $out top_$tag.bit]
puts "BUILD DONE $tag"
