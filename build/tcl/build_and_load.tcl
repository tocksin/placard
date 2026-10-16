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
# The board is programmed by program_board.tcl (also used by download_latest.bat).
# project/placard.xpr is made by create_project.tcl if it does not exist.
#
# Date: 10/16/2026

set tclDir    [file dirname [file normalize [info script]]]
set repoDir   [file normalize [file join $tclDir .. ..]]
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
# the project is not kept in git; make it on the first build
if {![file exists $xprFile]} {
    source [file join $tclDir create_project.tcl]
}
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
# (tclDir, not scriptDir: gen_video_ram.tcl sets its own scriptDir when sourced)
source [file join $tclDir program_board.tcl]
