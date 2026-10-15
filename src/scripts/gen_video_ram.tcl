# gen_video_ram.tcl
#
# Generates video_ram.mem : one hex byte per line, 65536 lines, address 0..65535.
# Loaded by sp_ram.vhd at elaboration / synthesis.
#
# Run from the Vivado Tcl console:   source /path/to/gen_video_ram.tcl
# or stand-alone:                    tclsh gen_video_ram.tcl
#
# Vivado does not run this script for you (it is not a synthesis or simulation
# hook, because a hook re-ran it with the default ASM_FILE and overwrote the
# image you made).  video_ram.mem is a project source, so after you run this
# script Vivado marks synthesis out of date and uses the new image.
#
# The image is written to ../hdl/video_ram.mem (relative to this script).  Set
# ::VIDEO_RAM_OUT before sourcing to write to a different path instead (the
# file is then left where you put it).
#
# The CPU starts at PC = 0000, so program code is merged into the same image
# at address ::ASM_BASE (default 0).  The program is read from the customasm
# output file ::ASM_FILE (default test_video.hex next to this script).  Make
# it with one of
#     customasm test_video.asm -f hexstr -o test_video.hex
#     customasm test_video.asm -f binary -o test_video.bin
# (the web version offers the same "hexstr" / "binary" output formats).
# Accepted formats: raw binary (*.bin), a hex string "10620020...", or
# comma separated 0x10, 0x62, ... values.  If the file is missing the image is
# generated without code.  Set ::ASM_FILE to "" to skip it on purpose.
#
# Date: 10/15/2026
#
# Memory-to-screen mapping:
#     A15:A9 = H9:H3 (active groups 48..127)    A8:A0 = V8:V0 (active 32..511)
#     address = VID_BASE + (byte_column * COL_STRIDE) + screen_row
#     VID_BASE = (48*512)+32 = 0x6020 : byte column 0, row 0
#
# Byte column 0 of every row is the mode byte, bits 1:0 = color mode
#     00 = 1 bpp, 01 = 2 bpp, 10 = 4 bpp, 11 = 8 bpp (other bits 0).
# Pixel data is in byte columns 1..79, LSB first within a byte.
# Drawable width = 632 / 316 / 158 / 79 pixels for 1 / 2 / 4 / 8 bpp.
#
# Four 120-row bands, one mode each:
#     rows   0..119  1 bpp  text, ruler
#     rows 120..239  2 bpp  colored text
#     rows 240..359  4 bpp  16 color palette, colored text
#     rows 360..479  8 bpp  text, RGB ramps
# 8 bpp byte format (D7..D0) = G3 G2 G1 B3 B2 R3 R2 R1

set COL_STRIDE 512
set VID_BASE   [expr {48 * 512 + 32}]
set BAND_H     120
set MEM_SIZE   65536

# ---------------------------------------------------------------------------
# 8x8 font : uppercase, digits, space - : . /
# 8 rows per glyph, MSB = leftmost pixel
# ---------------------------------------------------------------------------
array set font {
    A {70 88 88 F8 88 88 88 00}
    B {F0 88 88 F0 88 88 F0 00}
    C {70 88 80 80 80 88 70 00}
    D {F0 88 88 88 88 88 F0 00}
    E {F8 80 80 F0 80 80 F8 00}
    F {F8 80 80 F0 80 80 80 00}
    G {70 88 80 B8 88 88 78 00}
    H {88 88 88 F8 88 88 88 00}
    I {70 20 20 20 20 20 70 00}
    J {38 10 10 10 10 90 60 00}
    K {88 90 A0 C0 A0 90 88 00}
    L {80 80 80 80 80 80 F8 00}
    M {88 D8 A8 A8 88 88 88 00}
    N {88 C8 A8 98 88 88 88 00}
    O {70 88 88 88 88 88 70 00}
    P {F0 88 88 F0 80 80 80 00}
    Q {70 88 88 88 A8 90 68 00}
    R {F0 88 88 F0 A0 90 88 00}
    S {78 80 80 70 08 08 F0 00}
    T {F8 20 20 20 20 20 20 00}
    U {88 88 88 88 88 88 70 00}
    V {88 88 88 88 88 50 20 00}
    W {88 88 88 A8 A8 D8 88 00}
    X {88 88 50 20 50 88 88 00}
    Y {88 88 50 20 20 20 20 00}
    Z {F8 08 10 20 40 80 F8 00}
    0 {70 88 98 A8 C8 88 70 00}
    1 {20 60 20 20 20 20 70 00}
    2 {70 88 08 10 20 40 F8 00}
    3 {F8 10 20 10 08 88 70 00}
    4 {10 30 50 90 F8 10 10 00}
    5 {F8 80 F0 08 08 88 70 00}
    6 {30 40 80 F0 88 88 70 00}
    7 {F8 08 10 20 40 40 40 00}
    8 {70 88 88 70 88 88 70 00}
    9 {70 88 88 78 08 10 60 00}
    - {00 00 00 F8 00 00 00 00}
    : {00 20 20 00 20 20 00 00}
    . {00 00 00 00 00 60 60 00}
    / {08 10 10 20 40 40 80 00}
}
array set font [list " " {00 00 00 00 00 00 00 00}]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# address of screen row y, byte column col (column 0 = mode byte)
proc byte_addr {y col} {
    return [expr {$::VID_BASE + $col * $::COL_STRIDE + $y}]
}

# set one pixel; bpp = 1,2,4,8; x in pixels of that mode; y = screen row
# pixel data starts at byte column 1
proc put_pixel {bpp x y color} {
    set addr [byte_addr $y [expr {1 + ($x * $bpp) / 8}]]
    if {$addr < 0 || $addr >= $::MEM_SIZE} {
        return
    }
    set sh   [expr {($x * $bpp) % 8}]
    set mask [expr {((1 << $bpp) - 1) << $sh}]
    set b    $::mem($addr)
    set ::mem($addr) [expr {($b & (~$mask & 0xFF)) | (($color << $sh) & $mask)}]
}

proc fill_rect {bpp x0 y0 w h color} {
    for {set yy 0} {$yy < $h} {incr yy} {
        for {set xx 0} {$xx < $w} {incr xx} {
            put_pixel $bpp [expr {$x0 + $xx}] [expr {$y0 + $yy}] $color
        }
    }
}

proc draw_box {bpp x0 y0 w h color} {
    fill_rect $bpp $x0              $y0              $w 1 $color
    fill_rect $bpp $x0              [expr {$y0+$h-1}] $w 1 $color
    fill_rect $bpp $x0              $y0              1 $h $color
    fill_rect $bpp [expr {$x0+$w-1}] $y0             1 $h $color
}

# 8x8 characters, each font row repeated ysc times vertically
proc draw_text {bpp x0 y0 ysc str color} {
    set n [string length $str]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $str $i]
        if {![info exists ::font($ch)]} {
            continue
        }
        set g $::font($ch)
        for {set r 0} {$r < 8} {incr r} {
            set row [expr "0x[lindex $g $r]"]
            for {set c 0} {$c < 8} {incr c} {
                if {($row >> (7 - $c)) & 1} {
                    for {set s 0} {$s < $ysc} {incr s} {
                        put_pixel $bpp [expr {$x0 + $i * 8 + $c}] \
                                       [expr {$y0 + $r * $ysc + $s}] $color
                    }
                }
            }
        }
    }
}

# top line, left/right edges, optional bottom line, 2-byte x 8-row corner markers
proc frame_band {bpp y0 h is_first is_last edge_color corner_color} {
    set W  [expr {632 / $bpp}]
    set CW [expr {2 * (8 / $bpp)}]
    fill_rect $bpp 0        $y0 $W 1 $edge_color
    fill_rect $bpp 0        $y0 1  $h $edge_color
    fill_rect $bpp [expr {$W-1}] $y0 1 $h $edge_color
    if {$is_last} {
        fill_rect $bpp 0 [expr {$y0+$h-1}] $W 1 $edge_color
    }
    if {$is_first} {
        fill_rect $bpp 0            $y0 $CW 8 $corner_color
        fill_rect $bpp [expr {$W-$CW}] $y0 $CW 8 $corner_color
    }
    if {$is_last} {
        fill_rect $bpp 0            [expr {$y0+$h-8}] $CW 8 $corner_color
        fill_rect $bpp [expr {$W-$CW}] [expr {$y0+$h-8}] $CW 8 $corner_color
    }
}

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

# merge the assembled program into mem() at ASM_BASE
proc load_asm {} {
    if {![info exists ::ASM_BASE]} { set ::ASM_BASE 0 }
    if {![info exists ::ASM_FILE]} {
        set ::ASM_FILE [file join [file dirname [info script]] test_video.hex]
    }
    if {$::ASM_FILE eq ""} {
        return
    }
    if {![file exists $::ASM_FILE]} {
        puts "gen_video_ram: WARNING: $::ASM_FILE not found, image has no program"
        return
    }
    set bytes [read_asm_bytes $::ASM_FILE]
    set n [llength $bytes]
    if {$::ASM_BASE + $n > $::MEM_SIZE} {
        error "gen_video_ram: program ($n bytes at $::ASM_BASE) does not fit in memory"
    }
    set a $::ASM_BASE
    foreach b $bytes {
        set ::mem($a) $b
        incr a
    }
    puts "gen_video_ram: merged $n program bytes at [format %04X $::ASM_BASE] from $::ASM_FILE"
}

# ---------------------------------------------------------------------------
# Build the image
# ---------------------------------------------------------------------------
proc gen_video_ram {outFile} {
    for {set i 0} {$i < $::MEM_SIZE} {incr i} {
        set ::mem($i) 0
    }

    # mode byte (byte column 0) of every row: band n -> mode n
    for {set r 0} {$r < 4 * $::BAND_H} {incr r} {
        set ::mem([byte_addr $r 0]) [expr {$r / $::BAND_H}]
    }

    # ---- BAND 0 : 1 bpp, color 1 = white -----------------------------------
    frame_band 1 0 $::BAND_H 1 0 1 1
    draw_text 1 8  8 2 "1 BPP MODE - 632X480 - 2 COLORS" 1
    draw_text 1 8 32 2 "ABCDEFGHIJKLMNOPQRSTUVWXYZ" 1
    draw_text 1 8 56 2 "0123456789 -:./" 1
    draw_text 1 8 80 2 "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG" 1
    # ruler: tick every 8 pixels, tall tick every 64
    for {set i 1} {$i <= 78} {incr i} {
        if {$i % 8 == 0} {
            fill_rect 1 [expr {$i * 8}] 104 1 8 1
        } else {
            fill_rect 1 [expr {$i * 8}] 108 1 4 1
        }
    }

    # ---- BAND 1 : 2 bpp, 0 black, 1 blue, 2 orange, 3 white ----------------
    frame_band 2 120 $::BAND_H 0 0 3 3
    draw_text 2 4 128 2 "2 BPP MODE - 316X480 - 4 COLORS" 3
    draw_text 2 4 152 2 "BLUE TEXT - COLOR 1" 1
    draw_text 2 4 176 2 "ORANGE TEXT - COLOR 2" 2
    draw_text 2 4 200 2 "WHITE TEXT - COLOR 3" 3

    # ---- BAND 2 : 4 bpp, 16 colors ------------------------------------------
    frame_band 4 240 $::BAND_H 0 0 10 10
    draw_text 4 4 248 2 "4 BPP - 16 COLORS" 10
    draw_box 4 15 271 130 26 10
    for {set i 0} {$i < 16} {incr i} {
        fill_rect 4 [expr {16 + $i * 8}] 272 8 24 $i
    }
    draw_text 4  16 299 2 "0123456789ABCDEF" 10
    draw_text 4   8 322 2 "RED"    4
    draw_text 4  40 322 2 "GREEN" 15
    draw_text 4  96 322 2 "BLUE"   3
    draw_text 4   8 340 2 "CYAN"    8
    draw_text 4  48 340 2 "YELLOW" 14
    draw_text 4 112 340 2 "PINK"   12

    # ---- BAND 3 : 8 bpp, byte = G3 G2 G1 B3 B2 R3 R2 R1 --------------------
    frame_band 8 360 $::BAND_H 0 1 255 7
    draw_text 8 1 368 2 "8 BPP MODE" 255
    draw_text 8 1 392 2 "256 COLORS" 231
    for {set i 0} {$i < 8} {incr i} {
        set x [expr {8 + $i * 8}]
        fill_rect 8 $x 416 8 10 $i                                      ;# red
        fill_rect 8 $x 428 8 10 [expr {$i * 32}]                        ;# green
        fill_rect 8 $x 440 8 10 [expr {($i / 2) * 8}]                   ;# blue
        fill_rect 8 $x 452 8 10 [expr {$i + $i * 32 + ($i / 2) * 8}]    ;# white
    }

    # ---- program (CPU starts at PC = 0000) ----------------------------------
    load_asm

    # ---- write file ----------------------------------------------------------
    set fh [open $outFile w]
    for {set i 0} {$i < $::MEM_SIZE} {incr i} {
        puts $fh [format %02X $::mem($i)]
    }
    close $fh
    puts "gen_video_ram: wrote $::MEM_SIZE bytes to $outFile"
}

if {[info exists ::VIDEO_RAM_OUT]} {
    gen_video_ram $::VIDEO_RAM_OUT
} else {
    # write next to this script, then move the result to ../hdl where the
    # Vivado project (sp_ram.vhd INIT_FILE) looks for it
    set scriptDir [file dirname [file normalize [info script]]]
    set tmpFile   [file join $scriptDir video_ram.mem]
    set hdlDir    [file normalize [file join $scriptDir .. hdl]]
    gen_video_ram $tmpFile
    file mkdir $hdlDir
    file copy -force $tmpFile [file join $hdlDir video_ram.mem]
    file delete $tmpFile
    puts "gen_video_ram: moved video_ram.mem to $hdlDir"
}
