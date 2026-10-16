# gen_rom.tcl
#
# Generates rom.mem, the ROM's initialization file: one hex byte per line,
# 65536 lines, address 0..65535.  Loaded by sp_ram.vhd (romComp in
# basys_top.vhd) at elaboration / synthesis.  ROM.md describes the layout:
#
#     x0000-x0003   reset jump to the boot loader          rom_boot.hex
#     x6000-xA9FF   RAM image, copied to RAM x0000-x49FF at boot
#                   (ROM address = RAM address + x6000):
#         x6000-x8FFF   program, RAM x0000-x2FFF            the program's hex
#         x9000-x97FF   standard library code, RAM x3000    rom_lib.hex
#         x9800-x9FFF   standard font, RAM x3800            rom_lib.hex
#         xA000-xA9FF   program, RAM x4000-x49FF            the program's hex
#     xFD00-xFE07   boot loader                             rom_boot.hex
#
# The library goes in first and the program over it, so a program that
# includes placard_lib.asm puts the same bytes there, and an older program
# that uses x3000-x3FFF for itself replaces the library (a note is printed).
#
# Run from the Vivado Tcl console:   source /path/to/gen_rom.tcl
# or stand-alone:                    tclsh gen_rom.tcl
#
# The program is read from the customasm output file ::ASM_FILE (default
# test_video.hex next to this script), assembled at its RAM address (the
# program's reset code at x0000).  Make it with one of
#     customasm test_video.asm -f hexstr -o test_video.hex
#     customasm test_video.asm -f binary -o test_video.bin
#     python3 placard_sim.py test_video.asm
# (the web version offers the same "hexstr" / "binary" output formats).
# Accepted formats: raw binary (*.bin), a hex string "10620020...", or
# comma separated 0x10, 0x62, ... values.  If the file is missing the image is
# generated without a program.  Set ::ASM_FILE to "" to skip it on purpose.
# rom_boot.hex and rom_lib.hex are read from this script's folder (remake them
# from rom_boot.asm and rom_lib.asm after changing either, or the library).
#
# The image is written to ../hdl/rom.mem (relative to this script).  Set
# ::ROM_OUT before sourcing to write to a different path instead.
#
# Date: 10/16/2026

set ROM_SIZE        65536
set ROM_IMAGE_BASE  0x6000     ;# ROM address of RAM x0000
set IMAGE_SIZE      0x4A00     ;# RAM x0000-x49FF is copied at boot
set LIB_START       0x3000     ;# LIB_CODE in placard_lib.asm
set LIB_END         0x4000     ;# end of LIB_FONT

# ---------------------------------------------------------------------------
# Read a customasm output file; returns a list of byte values (0..255)
# ---------------------------------------------------------------------------
proc read_asm_bytes {fileName} {
    set bytes {}
    if {[string tolower [file extension $fileName]] eq ".bin"} {
        set fh [open $fileName rb]
        set data [read $fh]
        close $fh
        binary scan $data c* signed
        foreach b $signed {
            lappend bytes [expr {$b & 0xFF}]
        }
        return $bytes
    }
    set fh [open $fileName r]
    set text [read $fh]
    close $fh
    # drop any 0x prefixes, then turn commas / whitespace into nothing
    set text [string map {0x {} 0X {} , { }} $text]
    set tokens [regexp -all -inline {[0-9A-Fa-f]+} $text]
    if {[llength $tokens] == 0} {
        error "read_asm_bytes: no hex data in $fileName"
    }
    if {[llength $tokens] == 1} {
        # one continuous hex string: split it into byte pairs
        set hex [lindex $tokens 0]
        if {[string length $hex] % 2} {
            error "read_asm_bytes: odd number of hex digits in $fileName"
        }
        set tokens {}
        for {set i 0} {$i < [string length $hex]} {incr i 2} {
            lappend tokens [string range $hex $i [expr {$i + 1}]]
        }
    }
    foreach tok $tokens {
        scan $tok %x v
        lappend bytes [expr {$v & 255}]
    }
    return $bytes
}

# ---------------------------------------------------------------------------
# Build the image
# ---------------------------------------------------------------------------
proc gen_rom {outFile} {
    set dir [file dirname [file normalize [info script]]]
    if {[info exists ::GEN_ROM_DIR]} {
        set dir $::GEN_ROM_DIR
    }
    for {set i 0} {$i < $::ROM_SIZE} {incr i} {
        set rom($i) 0
    }

    # ---- boot loader: reset jump at x0000, loader at xFD00 ------------------
    set bootFile [file join $dir rom_boot.hex]
    if {![file exists $bootFile]} {
        error "gen_rom: $bootFile not found (assemble rom_boot.asm)"
    }
    set a 0
    foreach b [read_asm_bytes $bootFile] {
        if {$b != 0 && $a >= $::ROM_IMAGE_BASE
            && $a < $::ROM_IMAGE_BASE + $::IMAGE_SIZE} {
            error "gen_rom: rom_boot.hex has a byte at [format %04X $a], in the RAM image"
        }
        set rom($a) $b
        incr a
    }

    # ---- standard library and font -------------------------------------------
    set libFile [file join $dir rom_lib.hex]
    if {![file exists $libFile]} {
        error "gen_rom: $libFile not found (assemble rom_lib.asm)"
    }
    set lib [read_asm_bytes $libFile]
    for {set a $::LIB_START} {$a < $::LIB_END && $a < [llength $lib]} {incr a} {
        set rom([expr {$::ROM_IMAGE_BASE + $a}]) [lindex $lib $a]
    }

    # ---- program --------------------------------------------------------------
    if {![info exists ::ASM_FILE]} {
        set ::ASM_FILE [file join $dir test_video.hex]
    }
    if {$::ASM_FILE eq ""} {
        puts "gen_rom: no program"
    } elseif {![file exists $::ASM_FILE]} {
        puts "gen_rom: WARNING: $::ASM_FILE not found, image has no program"
    } else {
        set bytes [read_asm_bytes $::ASM_FILE]
        set n [llength $bytes]
        # customasm pads to the last byte, so only the bytes past the image
        # that are not 0 are an error
        for {set a $::IMAGE_SIZE} {$a < $n} {incr a} {
            if {[lindex $bytes $a] != 0} {
                error "gen_rom: program byte at [format %04X $a] is past the RAM\
                       image (x0000-[format %04X [expr {$::IMAGE_SIZE - 1}]])"
            }
        }
        set replaced 0
        for {set a 0} {$a < $n && $a < $::IMAGE_SIZE} {incr a} {
            set r [expr {$::ROM_IMAGE_BASE + $a}]
            set b [lindex $bytes $a]
            if {$a >= $::LIB_START && $a < $::LIB_END && $b != $rom($r)} {
                incr replaced
            }
            set rom($r) $b
        }
        if {$replaced} {
            puts "gen_rom: note: the program replaces $replaced library bytes\
                  (x3000-x3FFF), so the standard library is not loaded"
        }
        puts "gen_rom: merged $n program bytes at RAM 0000 (ROM\
              [format %04X $::ROM_IMAGE_BASE]) from $::ASM_FILE"
    }

    # ---- write file ------------------------------------------------------------
    set fh [open $outFile w]
    for {set i 0} {$i < $::ROM_SIZE} {incr i} {
        puts $fh [format %02X $rom($i)]
    }
    close $fh
    puts "gen_rom: wrote $::ROM_SIZE bytes to $outFile"
}

if {[info exists ::ROM_OUT]} {
    gen_rom $::ROM_OUT
} else {
    # write to ../hdl, where the Vivado project (sp_ram.vhd initFile) looks
    # for it
    set romHdlDir [file normalize [file join [file dirname [file normalize [info script]]] .. hdl]]
    file mkdir $romHdlDir
    gen_rom [file join $romHdlDir rom.mem]
}
