# gen_rom.tcl
#
# Generates rom.mem, the ROM cartridge's EEPROM image: one hex byte per line,
# 65536 lines, address 0..65535.  Loaded by sp_ram.vhd (romComp in
# cartridge.vhd) at elaboration / synthesis; the cartridge copies it into its
# SRAM at power-up.  docs/ROM.md describes the layout.
# Video reads always read the RAM, so the ROM under the video area holds
# programs:
#
#     x0000-x0004   nop, reset jump to the boot loader     rom_boot.hex
#     x1F00-x1FFF   LIB_RAM: library code the boot copies  rom_lib.hex
#                   to the RAM
#     x2000-x3FFF   more ROM program (runs in place)       the program
#     x6000-xBFFF   ROM program (runs in place, entry x6000) the program
#     xC000-xC4FF   PS/2 keyboard driver, listening        rom_lib.hex
#     xC500-xC5FF   program menu hook (menu_poll)          rom_lib.hex
#     xC600-xC6FF   expansion slot helpers                 rom_lib.hex
#     xC700-xD4FF   FAT file reader                        rom_lib.hex
#     xD500-xD6FF   line input, mouse pointer              rom_lib.hex
#     xD700-xDBFF   sound driver                           rom_lib.hex
#     xDC00-xEBFF   I/O drivers                            rom_lib.hex
#     xEC00-xF3FF   standard font                          rom_lib.hex
#     xF400-xFAFF   standard library core routines         rom_lib.hex
#     xFB00-xFBFF   jump table                             rom_lib.hex
#     xFC00         boot mode: 00 = ROM program, 01 = RAM image
#     xFD00-xFE07   boot loader                             rom_boot.hex
#
# rom32.asm (which sets the boot mode byte xFC00 to 02 itself) makes the
# 32K image instead (docs/ROM.md, "The 32K image"): x8000-xFFFF holds the
# boot loader and library as above, LIB_RAM's bytes at x9F00, rom32.asm's
# own bytes (vectors, loader, BASIC, FAT writer: x8000-x9EFF, xA000-xBFFF), BOOT_MODE = 02 and a copy of the
# reset code at x8000, and the lower half is a copy of the upper one, so a
# 32K cartridge (its one EEPROM read in both halves) and a 64K cartridge
# boot the same.  rom_32k.bin, the 32K EEPROM file, is written next to
# rom.mem.  The DOS (DOS.PLC) and the programs then come from the SD card
# (docs/DOS.md); with no card the machine starts BASIC.
#
# A program assembled at x6000-xBFFF and x2000-x3FFF (with the library
# included or not) is a ROM program (the 64K development image).  An older program written to run at
# RAM x0000 (bytes in x0000-x1FFF or x4000-x5FFF other than the library's
# own) is a RAM image instead: it is stored at ROM x6000-xA9FF (ROM address
# = RAM address + x6000), and the boot loader copies it to RAM x0000-x49FF
# and runs it from the RAM with map FF, so it can't use the library.
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
# comma separated 0x10, 0x62, ... values.  A file of exactly 65536 bytes is a
# whole ROM image and is used as it is.  If the file is missing the image is generated without a program.
# Set ::ASM_FILE to "" to skip it on purpose.
# rom_boot.hex and rom_lib.hex are read from this script's folder (remake them
# from rom_boot.asm and rom_lib.asm after changing either, or the library).
#
# The image is written to ../hdl/rom.mem (relative to this script).  Set
# ::ROM_OUT before sourcing to write to a different path instead.
#
# Date: 10/26/2026

set ROM_SIZE        65536
set ROM_IMAGE_BASE  [expr {0x6000}] ;# RAM image: ROM address of RAM x0000
set IMAGE_SIZE      [expr {0x4A00}] ;# RAM image: RAM x0000-x49FF is copied at boot
set LIB_RAM_START   [expr {0x1F00}] ;# LIB_RAM in placard_lib.asm (copied to RAM at boot)
set LIB_RAM_END     [expr {0x2000}]
set PROG2_START     [expr {0x2000}] ;# more ROM program area (section 1)
set PROG2_END       [expr {0x4000}]
set PROG_START      [expr {0x6000}] ;# ROM program area and entry
set PROG_END        [expr {0xC000}] ;# end of the ROM program area
set SYS_START       [expr {0xC000}] ;# the library block (placard_lib.asm): slot helpers,
set SYS_END         [expr {0xFC00}] ;# FAT, input, sound, I/O, font, code, jump table
set BOOT_MODE       [expr {0xFC00}] ;# 00 = ROM program, 01 = RAM image, 02 = the 32K image
set MODE_DOS        2
set DOS_START       [expr {0x8000}] ;# the 32K image's own area (vectors, loader, BASIC, FAT writer)
set DOS_END         [expr {0xC000}]
set LIB_RAM_IMAGE   [expr {0x9F00}] ;# LIB_RAM in the 32K image (read at x1F00 through the mirror)

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
# True for the addresses the library's own bytes go to in the ROM
# ---------------------------------------------------------------------------
proc lib_area {a} {
    return [expr {($a >= $::SYS_START && $a < $::SYS_END) ||
                  ($a >= $::LIB_RAM_START && $a < $::LIB_RAM_END)}]
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
        if {$b != 0 && [lib_area $a]} {
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
    foreach {lo hi} [list $::LIB_RAM_START $::LIB_RAM_END $::SYS_START $::SYS_END] {
        for {set a $lo} {$a < $hi} {incr a} {
            if {$a < [llength $lib]} {
                set rom($a) [lindex $lib $a]
            }
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

    # a whole ROM image: used as it is; its boot loader and library should
    # be the ones next to this script
    if {$n == $::ROM_SIZE} {
        set diff 0
        for {set a 0} {$a < $n} {incr a} {
            if {([lib_area $a] || $a >= $::BOOT_MODE) && [lindex $bytes $a] != $rom($a)} {
                incr diff
            }
            set rom($a) [lindex $bytes $a]
        }
        if {$diff} {
            puts "gen_rom: WARNING: $diff library or boot bytes in $::ASM_FILE differ from\
                  rom_lib.hex / rom_boot.hex (rebuild it after changing the library)"
        }
        puts "gen_rom: whole ROM image from $::ASM_FILE"
        set n 0
        set skipProgram 1
    } else {
        set skipProgram 0
    }

    # rom32.asm: the 32K image, twice (see the top of this file)
    if {!$skipProgram && $n > $::BOOT_MODE && [lindex $bytes $::BOOT_MODE] == $::MODE_DOS} {
        set dosBytes 0
        for {set a 0} {$a < $n} {incr a} {
            set b [lindex $bytes $a]
            if {$a == $::BOOT_MODE} {
                continue
            }
            if {$a >= $::DOS_START && $a < $::DOS_END} {
                if {$b != 0 && $a >= $::LIB_RAM_IMAGE && $a < $::LIB_RAM_IMAGE + 0x100} {
                    error "gen_rom: 32K image byte at [format %04X $a] is in the LIB_RAM image (9F00-9FFF)"
                }
                if {$a < 5 + $::DOS_START && $b != $rom([expr {$a - $::DOS_START}])} {
                    error "gen_rom: 32K image byte at [format %04X $a] differs from the reset code"
                }
                set rom($a) $b
                if {$b != 0} {
                    incr dosBytes
                }
                continue
            }
            if {$b != 0 && !([lib_area $a] && $b == $rom($a))} {
                error "gen_rom: 32K image byte at [format %04X $a] is outside the 32K image (8000-BFFF)"
            }
        }
        for {set a 0} {$a < 5} {incr a} {
            set rom([expr {$::DOS_START + $a}]) $rom($a)
        }
        for {set a 0} {$a < 0x100} {incr a} {
            set rom([expr {$::LIB_RAM_IMAGE + $a}]) $rom([expr {$::LIB_RAM_START + $a}])
        }
        set rom($::BOOT_MODE) $::MODE_DOS
        for {set a 0} {$a < 0x8000} {incr a} {
            set rom($a) $rom([expr {$a + 0x8000}])
        }
        puts "gen_rom: the 32K image, $dosBytes bytes (not 00) in 8000-BFFF from $::ASM_FILE,\
              in both halves"
        set fh [open [file join [file dirname $outFile] rom_32k.bin] w]
        fconfigure $fh -translation binary
        set list {}
        for {set a $::DOS_START} {$a < $::ROM_SIZE} {incr a} {
            lappend list $rom($a)
        }
        puts -nonewline $fh [binary format c* $list]
        close $fh
        puts "gen_rom: wrote the 32K EEPROM file [file join [file dirname $outFile] rom_32k.bin]"
        set skipProgram 1
    }

    # a RAM image has bytes in x0000-x1FFF or x4000-x5FFF other than the
    # library's own
    set ramImage 0
    for {set a 0} {$a < $n && $a < $::PROG_START} {incr a} {
        if {$a >= $::PROG2_START && $a < $::PROG2_END} {
            continue
        }
        set b [lindex $bytes $a]
        if {$b != 0 && !([lib_area $a] && $b == $rom($a))} {
            set ramImage 1
            break
        }
    }

    if {$skipProgram} {
    } elseif {!$ramImage} {
        set progBytes 0
        for {set a 0} {$a < $n} {incr a} {
            set b [lindex $bytes $a]
            if {($a >= $::PROG_START && $a < $::PROG_END) ||
                ($a >= $::PROG2_START && $a < $::PROG2_END)} {
                set rom($a) $b
                if {$b != 0} {
                    incr progBytes
                }
                continue
            }
            # the program's own copy of the library is not program
            if {$b != 0 && !([lib_area $a] && $b == $rom($a))} {
                error "gen_rom: program byte at [format %04X $a] is outside the ROM\
                       program area (6000-[format %04X [expr {$::PROG_END - 1}]],\
                       2000-3FFF)"
            }
        }
        set rom($::BOOT_MODE) 0
        if {$n > 0} {
            puts "gen_rom: ROM program, $progBytes bytes (not 00) in 2000-3FFF and 6000-BFFF\
                  from $::ASM_FILE"
        }
    } else {
        # customasm pads to the last byte, so only the bytes past the image
        # that are not 0 (or the program's own copy of the library) are an
        # error.  A RAM image runs with map FF, so it can't call the library.
        for {set a $::IMAGE_SIZE} {$a < $n} {incr a} {
            set b [lindex $bytes $a]
            if {$b != 0 && !([lib_area $a] && $b == $rom($a))} {
                error "gen_rom: program byte at [format %04X $a] is past the RAM\
                       image (x0000-[format %04X [expr {$::IMAGE_SIZE - 1}]])"
            }
        }
        for {set a 0} {$a < $n && $a < $::IMAGE_SIZE} {incr a} {
            set rom([expr {$::ROM_IMAGE_BASE + $a}]) [lindex $bytes $a]
        }
        set rom($::BOOT_MODE) 1
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
