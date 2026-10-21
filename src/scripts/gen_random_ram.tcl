# gen_random_ram.tcl
#
# Generates the initialization files of the FPGA model's RAMs with random
# bytes, the way a real SRAM powers up: one hex byte per line, 65536 lines,
# address 0..65535.  Loaded by sp_ram.vhd at elaboration / synthesis.
#
#     ram.mem       the main RAM (ramComp in basys_top.vhd)
#     cart_ram.mem  the ROM cartridge's SRAM (sramComp in cartridge.vhd),
#                   which the cartridge fills from its EEPROMs (rom.mem)
#                   at power-up
#
# Programs must not count on any RAM contents they did not write.  The
# screen shows these random bytes until a program draws (the line mode
# bytes are random too).
#
# Run from the Vivado Tcl console:   source /path/to/gen_random_ram.tcl
# or stand-alone:                    tclsh gen_random_ram.tcl
#
# Each run uses a new seed (the clock) unless ::RANDOM_RAM_SEED is set.  The
# files are written to ../hdl (relative to this script); set ::RANDOM_RAM_DIR
# before sourcing to write them somewhere else.
#
# (Until 2026-10-21 ram.mem held the video test pattern of
# gen_video_ram.tcl, which is kept for reference.)
#
# Date: 10/21/2026

proc gen_random_ram {outFile seed} {
    expr {srand($seed)}
    set fh [open $outFile w]
    for {set i 0} {$i < 65536} {incr i} {
        puts $fh [format %02X [expr {int(rand() * 256)}]]
    }
    close $fh
    puts "gen_random_ram: wrote 65536 random bytes to $outFile (seed $seed)"
}

if {[info exists ::RANDOM_RAM_SEED]} {
    set randomSeed $::RANDOM_RAM_SEED
} else {
    set randomSeed [expr {[clock clicks] & 0x7FFFFFFF}]
}
if {[info exists ::RANDOM_RAM_DIR]} {
    set randomDir $::RANDOM_RAM_DIR
} else {
    # ../hdl, where the Vivado project (sp_ram.vhd initFile) looks for them
    set randomDir [file normalize [file join [file dirname [file normalize [info script]]] .. hdl]]
}
file mkdir $randomDir
gen_random_ram [file join $randomDir ram.mem]      $randomSeed
gen_random_ram [file join $randomDir cart_ram.mem] [expr {($randomSeed * 69069 + 1) & 0x7FFFFFFF}]
