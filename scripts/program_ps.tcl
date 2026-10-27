# Load the "ps" variant onto the ZedBoard over JTAG and start the ARM bridge program.
# Usage (from the repository root):
#   xsdb scripts/program_ps.tcl <W>
# Needs build/ps_W<W>/top_ps_W<W>.bit and ps7_init.tcl (scripts/build.py --variant ps)
# and build/sw/uart_bridge.elf (scripts/build.py --firmware).

set W [lindex $argv 0]
cd [file normalize [file join [file dirname [info script]] ..]]
set bit  build/ps_W$W/top_ps_W$W.bit
set init build/ps_W$W/ps7_init.tcl
set elf  build/sw/uart_bridge.elf
foreach f [list $bit $init $elf] {
    if {![file exists $f]} { error "Missing $f. Build it first." }
}

connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 500
fpga -file $bit
source $init
ps7_init
# Enables the level shifters between the processor and the FPGA logic, which
# the EMIO UART signals pass through.
ps7_post_config
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
rst -processor
dow $elf
con
puts "PROGRAMMED $bit and started $elf"
disconnect
