# update_mem.tcl
#
# Vivado batch script for the fast path of build_and_load.bat (option "fast"):
# makes video_ram.mem for one program and prepares the files updatemem needs
# to put it into the existing bitstream, without synthesis or implementation.
#
#     vivado -mode batch -source update_mem.tcl -tclargs <hexFile>
#
# Writes, in the impl_1 run folder:
#     <top>.mmi           block RAM map of the implemented design (write_mmi.tcl);
#                         remade only when the bitstream is newer than it
#     <top>_update.mem    video_ram.mem in updatemem format
#     <top>_procs.txt     memory instance names, one per line (updatemem -proc)
#
# The design (HDL, constraints) must not have changed since the last full
# build; only the memory contents are replaced.
#
# Date: 10/15/2026

set buildDir [file dirname [file normalize [info script]]]
set repoDir  [file normalize [file join $buildDir ..]]
set xprFile  [file join $repoDir project placard.xpr]
set memFile  [file join $repoDir src hdl video_ram.mem]
set memDepth 65536
set memWidth 8

source [file join $buildDir write_mmi.tcl]

# ---- 1. memory initialization file ------------------------------------------
set hexFile [lindex $argv 0]
if {$hexFile ne ""} {
    set hexFile [file normalize $hexFile]
}
set ::ASM_FILE $hexFile
source [file join $repoDir src scripts gen_video_ram.tcl]

# ---- 2. block RAM map of the existing implementation ------------------------
open_project $xprFile
set implRun [get_runs impl_1]
set implDir [get_property DIRECTORY $implRun]
set top     [get_property TOP [current_fileset]]
set bitFile [file join $implDir $top.bit]
set mmiFile [file join $implDir $top.mmi]

if {[get_property PROGRESS $implRun] ne "100%" || ![file exists $bitFile]} {
    error "update_mem: no implemented bitstream yet, run a full build first"
}
if {![file exists $mmiFile] || [file mtime $mmiFile] < [file mtime $bitFile]} {
    puts "update_mem: opening the implemented design to map the block RAMs"
    open_run impl_1
    write_mmi $mmiFile $memDepth $memWidth
    close_design
} else {
    puts "update_mem: using existing $mmiFile"
}
close_project

set fh [open $mmiFile r]
set procs [regexp -all -inline -- {InstPath="([^"]+)"} [read $fh]]
close $fh
set fh [open [file join $implDir ${top}_procs.txt] w]
foreach {match inst} $procs {
    puts $fh $inst
}
close $fh

# ---- 3. video_ram.mem in updatemem format (@address then data bytes) --------
set fh [open $memFile r]
set bytes [regexp -all -inline {[0-9A-Fa-f]+} [read $fh]]
close $fh
if {[llength $bytes] != $memDepth} {
    error "update_mem: $memFile has [llength $bytes] bytes, expected $memDepth"
}
set fh [open [file join $implDir ${top}_update.mem] w]
for {set a 0} {$a < $memDepth} {incr a 16} {
    puts $fh "@[format %08X $a] [join [lrange $bytes $a [expr {$a + 15}]] { }]"
}
close $fh
puts "update_mem: wrote [file join $implDir ${top}_update.mem]"
