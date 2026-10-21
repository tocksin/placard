# update_mem.tcl
#
# Vivado batch script for the fast path of build_and_load.bat (option "fast"):
# makes ram.mem, cart_ram.mem and rom.mem for one program, puts them into the
# existing bitstream with updatemem (no synthesis or implementation) and
# programs the board.  ramComp gets ram.mem, sramComp (the cartridge SRAM)
# cart_ram.mem and romComp (the cartridge EEPROMs) rom.mem.  The RAM images
# are new random bytes each time.
#
#     vivado -mode batch -source update_mem.tcl -tclargs <hexFile>
#
# Files in the impl_1 run folder:
#     <top>.bit           full-build bitstream (not changed)
#     <top>_built_ram.mem, <top>_built_cart_ram.mem, <top>_built_rom.mem
#                         memory images <top>.bit was built with (written by
#                         build_and_load.tcl)
#     <top>.mmi           block RAM map of the implemented design (write_mmi.tcl);
#                         remade when the bitstream or write_mmi.tcl is newer
#                         than it.  When it is made, both bit numberings are
#                         tried: the one whose updatemem output with the
#                         built images matches <top>.bit is kept, so a wrong
#                         map is an error instead of a scrambled image.
#     <top>_update_ram.mem, <top>_update_cart_ram.mem, <top>_update_rom.mem
#                         new memory images in updatemem format
#     <top>_fast.bit      result, programmed into the board
#
# The design (HDL, constraints) must not have changed since the last full
# build; only the memory contents are replaced.
#
# Date: 10/21/2026

set tclDir   [file dirname [file normalize [info script]]]
set repoDir  [file normalize [file join $tclDir .. ..]]
set xprFile  [file join $repoDir project placard.xpr]
set ramFile  [file join $repoDir src hdl ram.mem]
set cartFile [file join $repoDir src hdl cart_ram.mem]
set romFile  [file join $repoDir src hdl rom.mem]
set memDepth 65536
set memWidth 8

source [file join $tclDir write_mmi.tcl]

# ---- 1. memory initialization files -----------------------------------------
set hexFile [lindex $argv 0]
if {$hexFile ne ""} {
    set hexFile [file normalize $hexFile]
}
source [file join $repoDir src scripts gen_random_ram.tcl]
set ::ASM_FILE $hexFile
source [file join $repoDir src scripts gen_rom.tcl]

# ---- 2. block RAM map of the existing implementation ------------------------
if {![file exists $xprFile]} {
    error "update_mem: no Vivado project yet, run a full build first"
}
open_project $xprFile
set implRun   [get_runs impl_1]
set implDir   [get_property DIRECTORY $implRun]
set top       [get_property TOP [current_fileset]]
set baseBit   [file join $implDir $top.bit]
set builtMems [dict create ramComp  [file join $implDir ${top}_built_ram.mem] \
                           sramComp [file join $implDir ${top}_built_cart_ram.mem] \
                           romComp  [file join $implDir ${top}_built_rom.mem]]
set mmiFile   [file join $implDir $top.mmi]
set updateMems [dict create ramComp  [file join $implDir ${top}_update_ram.mem] \
                            sramComp [file join $implDir ${top}_update_cart_ram.mem] \
                            romComp  [file join $implDir ${top}_update_rom.mem]]
set fastBit   [file join $implDir ${top}_fast.bit]

if {[get_property PROGRESS $implRun] ne "100%" || ![file exists $baseBit]} {
    error "update_mem: no implemented bitstream yet, run a full build first"
}
dict for {inst builtMem} $builtMems {
    if {![file exists $builtMem] || [file mtime $builtMem] < [file mtime $baseBit]} {
        error "update_mem: $builtMem is missing or older than the bitstream,\
               run one full build (without fast) first"
    }
}

if {![file exists $mmiFile]
    || [file mtime $mmiFile] < [file mtime $baseBit]
    || [file mtime $mmiFile] < [file mtime [file join $tclDir write_mmi.tcl]]} {
    puts "update_mem: opening the implemented design to map the block RAMs"
    file delete -force $mmiFile
    open_run impl_1
    foreach order {msbFirst lsbFirst} {
        write_mmi [file join $implDir ${top}_$order.mmi] $memDepth $memWidth $order
    }
    close_design

    # updatemem with the image the bitstream was built with must give back
    # the same bitstream
    set verifyBit [file join $implDir ${top}_verify.bit]
    foreach order {msbFirst lsbFirst} {
        run_updatemem [file join $implDir ${top}_$order.mmi] $baseBit $builtMems $verifyBit
        set diff($order) [bit_diff_blocks $baseBit $verifyBit]
        puts "update_mem: $order map, $diff($order) blocks differ from the full build"
    }
    file delete -force $verifyBit
    if {$diff(msbFirst) == 0} {
        set order msbFirst
    } elseif {$diff(lsbFirst) == 0} {
        set order lsbFirst
    } else {
        error "update_mem: neither block RAM map reproduces the full-build\
               bitstream (msbFirst $diff(msbFirst), lsbFirst $diff(lsbFirst) blocks\
               differ); use a full build"
    }
    file copy -force [file join $implDir ${top}_$order.mmi] $mmiFile
    puts "update_mem: verified the $order block RAM map"
} else {
    puts "update_mem: using verified map $mmiFile"
}
close_project

# ---- 3. new image into the bitstream ----------------------------------------
write_update_mem $ramFile [dict get $updateMems ramComp] $memDepth
write_update_mem $cartFile [dict get $updateMems sramComp] $memDepth
write_update_mem $romFile [dict get $updateMems romComp] $memDepth
run_updatemem $mmiFile $baseBit $updateMems $fastBit
puts "update_mem: wrote $fastBit"

# ---- 4. program the board ---------------------------------------------------
set bitFile $fastBit
source [file join $tclDir program_board.tcl]
