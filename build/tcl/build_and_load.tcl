# build_and_load.tcl
#
# Vivado batch script: make ram.mem, cart_ram.mem and rom.mem for one program, synthesize,
# implement, write the bitstream and program the Basys 3 over JTAG.
#
# Called by build_and_load.bat:
#     vivado -mode batch -source build_and_load.tcl -tclargs <hexFile> [jobs]
#
#     hexFile   customasm output for the program (put in the ROM image by
#               gen_rom.tcl, see docs/ROM.md).  "" builds the ROM without a program.
#     jobs      parallel jobs for launch_runs (default 4)
#
# The board is programmed by program_board.tcl (also used by download_latest.bat).
# project/placard.xpr is made by create_project.tcl if it does not exist.
#
# Date: 10/21/2026

set tclDir    [file dirname [file normalize [info script]]]
set repoDir   [file normalize [file join $tclDir .. ..]]
set xprFile   [file join $repoDir project placard.xpr]

set hexFile [lindex $argv 0]
set jobs    [lindex $argv 1]
if {$jobs eq ""} {
    set jobs 4
}

# ---- 1. memory initialization files -----------------------------------------
# gen_random_ram.tcl writes src/hdl/ram.mem and cart_ram.mem (random) and
# gen_rom.tcl src/hdl/rom.mem (project sources)
if {$hexFile ne ""} {
    set hexFile [file normalize $hexFile]
}
source [file join $repoDir src scripts gen_random_ram.tcl]
set ::ASM_FILE $hexFile
source [file join $repoDir src scripts gen_rom.tcl]

# ---- 2. synthesis, implementation, bitstream --------------------------------
# the project is not kept in git; make it on the first build
if {![file exists $xprFile]} {
    source [file join $tclDir create_project.tcl]
}
open_project $xprFile
# a project made before the ROM had its own image lists video_ram.mem
foreach f {ram.mem cart_ram.mem rom.mem} {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] $f]] == 0} {
        add_files -fileset sources_1 [file join $repoDir src hdl $f]
    }
}
# .vhd files added to src/hdl since the project was made (VHDL 2008, like
# create_project.tcl); removed ones still need create_project.bat force
foreach f [lsort [glob -nocomplain -directory [file join $repoDir src hdl] *.vhd]] {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] [file tail $f]]] == 0} {
        add_files -fileset sources_1 $f
        set_property file_type {VHDL 2008} [get_files $f]
        puts "build_and_load: added [file tail $f] to the project"
    }
}
set oldMem [get_files -quiet -of_objects [get_filesets sources_1] video_ram.mem]
if {[llength $oldMem] > 0} {
    remove_files -fileset sources_1 $oldMem
}
update_compile_order -fileset sources_1

# always start from synthesis so the new memory images are read
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

# keep the images this bitstream holds, so the fast path (update_mem.tcl) can
# check its block RAM map against them
source [file join $tclDir write_mmi.tcl]
set builtBase [file join [file dirname $bitFile] [file rootname [file tail $bitFile]]]
write_update_mem [file join $repoDir src hdl ram.mem] ${builtBase}_built_ram.mem 65536
write_update_mem [file join $repoDir src hdl cart_ram.mem] ${builtBase}_built_cart_ram.mem 65536
write_update_mem [file join $repoDir src hdl rom.mem] ${builtBase}_built_rom.mem 65536

# ---- 3. program the board ---------------------------------------------------
# (tclDir, not scriptDir: a sourced generator may set its own scriptDir)
source [file join $tclDir program_board.tcl]
