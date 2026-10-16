# program_board.tcl
#
# Programs the Basys 3 (xc7a35t) through the local hw_server.
#
# Sourced by build_and_load.tcl with $bitFile already set, or run on its own
# (download_latest.bat):
#     vivado -mode batch -source program_board.tcl -tclargs <bitFile>
#
# Date: 10/16/2026

if {![info exists bitFile]} {
    set bitFile [file normalize [lindex $argv 0]]
}
if {![file exists $bitFile]} {
    error "program_board: bitstream $bitFile not found"
}

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set hwDevice [lindex [get_hw_devices xc7a35t*] 0]
if {$hwDevice eq ""} {
    error "program_board: no xc7a35t found on the JTAG chain (is the board on?)"
}
current_hw_device $hwDevice
refresh_hw_device -update_hw_probes false $hwDevice
set_property PROBES.FILE {} $hwDevice
set_property FULL_PROBES.FILE {} $hwDevice
set_property PROGRAM.FILE $bitFile $hwDevice
program_hw_devices $hwDevice

close_hw_target
disconnect_hw_server
close_hw_manager
puts "program_board: programmed $hwDevice with $bitFile"
