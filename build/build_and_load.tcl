# build_and_load.tcl
#
# Vivado batch script: make video_ram.mem for one program, synthesize,
# implement, write the bitstream and program the Basys 3 over JTAG.
#
# Called by build_and_load.bat:
#     vivado -mode batch -source build_and_load.tcl -tclargs <hexFile> [jobs]
#
#     hexFile   customasm output for the program (merged at address 0000 by
#               gen_video_ram.tcl).  "" builds the image without a program.
#     jobs      parallel jobs for launch_runs (default 4)
#
# Date: 10/15/2026

set scriptDir [file dirname [file normalize [info script]]]
set repoDir   [file normalize [file join $scriptDir ..]]
set xprFile   [file join $repoDir project placard.xpr]

set hexFile [lindex $argv 0]
set jobs    [lindex $argv 1]
if {$jobs eq ""} {
    set jobs 4
}

# ---- 1. memory initialization file ------------------------------------------
# gen_video_ram.tcl writes src/hdl/video_ram.mem (a project source)
if {$hexFile ne ""} {
    set hexFile [file normalize $hexFile]
}
set ::ASM_FILE $hexFile
source [file join $repoDir src scripts gen_video_ram.tcl]

# ---- 2. synthesis, implementation, bitstream --------------------------------
open_project $xprFile
update_compile_order -fileset sources_1

# always start from synthesis so the new video_ram.mem is read
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

set synthRun [get_runs synth_1]
set implRun  [get_runs impl_1]
if {[get_property PROGRESS $synthRun] ne "100%"} {
    error "build_and_load: synthesis failed, see [get_property DIRECTORY $synthRun]/runme.log"
}
if {[get_property PROGRESS $implRun] ne "100%"} {
    error "build_and_load: implementation failed, see [get_property DIRECTORY $implRun]/runme.log"
}

set bitFile [file join [get_property DIRECTORY $implRun] \
                 "[get_property TOP [current_fileset]].bit"]
if {![file exists $bitFile]} {
    error "build_and_load: bitstream $bitFile not found"
}
puts "build_and_load: bitstream $bitFile"
close_project

# ---- 3. program the board ---------------------------------------------------
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set hwDevice [lindex [get_hw_devices xc7a35t*] 0]
if {$hwDevice eq ""} {
    error "build_and_load: no xc7a35t found on the JTAG chain (is the board on?)"
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
puts "build_and_load: programmed $hwDevice with $bitFile"
