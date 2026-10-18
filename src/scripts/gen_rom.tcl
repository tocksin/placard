# gen_rom.tcl
#
# Generates rom.mem, the ROM's initialization file: one hex byte per line,
# 65536 lines, address 0..65535.  Loaded by sp_ram.vhd (romComp in
# basys_top.vhd) at elaboration / synthesis.  docs/ROM.md describes the layout.
# Video reads always read the RAM, so the ROM under the video area holds
# programs:
#
#     x0000-x0003   reset jump to the boot loader          rom_boot.hex
#     x2000-x2FFF   I/O drivers (runs in place)            rom_lib.hex
#     x3000-x37FF   standard library code (runs in place)  rom_lib.hex
#     x3800-x3FFF   standard font                          rom_lib.hex
#     x6000-xDFFF   ROM program (runs in place, entry x6000) the program
#     xE000-xFBFF   library bank 2: jump table page, sound,     rom_lib.hex
#                   FAT, expansion slots (runs in place)
#     xFC00         boot mode: 00 = ROM program, 01 = RAM image
#     xFD00-xFE07   boot loader                             rom_boot.hex
#
# A program assembled at x6000 and up (with the library included or not)
# is a ROM program.  An older program written to run at RAM x0000 (bytes
# below x6000 other than the library's) is a RAM image instead: it is
# stored at ROM x6000-xA9FF (ROM address = RAM address + x6000) with the
# library (not the I/O drivers) again at its RAM x3000-x3FFF, and the boot loader copies it to
# RAM x0000-x49FF and runs it from the RAM.  If such a program uses
# x3000-x3FFF for itself it replaces the library there (a note is printed).
#
# Run from the Vivado Tcl console:   source /path/to/gen_rom.tcl
# or stand-alone:                    tclsh gen_rom.tcl
#
# The program is read from the customasm output file ::ASM_FILE (default
# test_video.hex next to this script).  Make it with one of
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
# Date: 10/18/2026

set ROM_SIZE        65536
set ROM_IMAGE_BASE  [expr {0x6000}] ;# RAM image: ROM address of RAM x0000
set IMAGE_SIZE      [expr {0x4A00}] ;# RAM image: RAM x0000-x49FF is copied at boot
set IO_START        [expr {0x2000}] ;# IO_CODE in placard_io.asm (ROM programs only)
set LIB_START       [expr {0x3000}] ;# LIB_CODE in placard_lib.asm
set LIB_END         [expr {0x4000}] ;# end of LIB_FONT
set PROG_START      [expr {0x6000}] ;# ROM program area and entry
set PROG_END        [expr {0xE000}] ;# end of the ROM program area
set LIB2_START      [expr {0xE000}] ;# LIB2_CODE in placard_lib.asm: library bank 2
set LIB2_END        [expr {0xFC00}] ;# end of library bank 2
set BOOT_MODE       [expr {0xFC00}] ;# 00 = ROM program, 01 = RAM image

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
        if {$b != 0 && $a >= $::IO_START && $a < $::LIB_END} {
            error "gen_rom: rom_boot.hex has a byte at [format %04X $a],\
                   in the library or program area"
        }
        set rom($a) $b
        incr a
    }

    # ---- I/O drivers, standard library and font, in place -----------------------
    set libFile [file join $dir rom_lib.hex]
    if {![file exists $libFile]} {
        error "gen_rom: $libFile not found (assemble rom_lib.asm)"
    }
    set lib [read_asm_bytes $libFile]
    for {set a $::IO_START} {$a < $::LIB_END} {incr a} {
        if {$a < [llength $lib]} {
            set rom($a) [lindex $lib $a]
        }
    }
    for {set a $::LIB2_START} {$a < $::LIB2_END} {incr a} {
        if {$a < [llength $lib]} {
            set rom($a) [lindex $lib $a]
        }
    }

    # ---- program ----------------------------------------------------------------
    if {![info exists ::ASM_FILE]} {
        set ::ASM_FILE [file join $dir test_video.hex]
    }
    set bytes {}
    if {$::ASM_FILE eq ""} {
        puts "gen_rom: no program"
    } elseif {![file exists $::ASM_FILE]} {
        puts "gen_rom: WARNING: $::ASM_FILE not found, image has no program"
    } else {
        set bytes [read_asm_bytes $::ASM_FILE]
    }
    set n [llength $bytes]

    # a RAM image has bytes below x6000 other than the library's own
    set ramImage 0
    for {set a 0} {$a < $n && $a < $::PROG_START} {incr a} {
        set b [lindex $bytes $a]
        if {$a >= $::IO_START && $a < $::LIB_END} {
            if {$b != $rom($a)} {
                set ramImage 1
                break
            }
        } elseif {$b != 0} {
            set ramImage 1
            break
        }
    }

    if {!$ramImage} {
        for {set a $::PROG_START} {$a < $n} {incr a} {
            set b [lindex $bytes $a]
            if {$a >= $::PROG_END} {
                # the program's own copy of library bank 2 is not program
                if {$b != 0 && !($a >= $::LIB2_START && $a < $::LIB2_END && $b == $rom($a))} {
                    error "gen_rom: program byte at [format %04X $a] is past the ROM\
                           program area (6000-[format %04X [expr {$::PROG_END - 1}]])"
                }
                continue
            }
            set rom($a) $b
        }
        set rom($::BOOT_MODE) 0
        if {$n > 0} {
            puts "gen_rom: ROM program, [expr {$n > $::PROG_START ? $n - $::PROG_START : 0}]\
                  bytes at 6000 from $::ASM_FILE"
        }
    } else {
        # library again in the image, at RAM x3000-x3FFF
        for {set a $::LIB_START} {$a < $::LIB_END} {incr a} {
            set rom([expr {$::ROM_IMAGE_BASE + $a}]) $rom($a)
        }
        # customasm pads to the last byte, so only the bytes past the image
        # that are not 0 (or the program's own copy of library bank 2) are
        # an error.  A RAM image runs with map FF, so it can't call bank 2.
        for {set a $::IMAGE_SIZE} {$a < $n} {incr a} {
            set b [lindex $bytes $a]
            if {$b != 0 && !($a >= $::LIB2_START && $a < $::LIB2_END && $b == $rom($a))} {
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
        set rom($::BOOT_MODE) 1
        if {$replaced} {
            puts "gen_rom: note: the program replaces $replaced library bytes\
                  (x3000-x3FFF) in its RAM image"
        }
        puts "gen_rom: RAM image, $n program bytes for RAM 0000 (ROM\
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
