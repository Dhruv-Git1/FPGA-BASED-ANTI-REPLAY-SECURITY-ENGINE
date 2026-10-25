# Load a built bitstream onto the ZedBoard over the PROG (JTAG) USB port.
# Usage (from the repository root):
#   vivado -mode batch -source scripts/program.tcl -tclargs <W>
# The board's boot-mode jumpers must select JTAG mode.

set W    [lindex $argv 0]
cd [file normalize [file join [file dirname [info script]] ..]]
set bit  build/W$W/top_W$W.bit
if {![file exists $bit]} { error "Bitstream not found: $bit. Build it first." }

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7z020*] 0]
if {$dev eq ""} { error "No xc7z020 found on the JTAG chain. Is the board on and connected to PROG?" }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAMMED $dev with $bit"
close_hw_target
disconnect_hw_server
close_hw_manager
