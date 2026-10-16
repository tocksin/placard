; ============================================================
; rom_boot.asm - Placard ROM boot loader
; ============================================================
;
; The ROM/RAM map clears to all ROM at power-up, so the CPU starts here,
; in the ROM, at PC = 0000.  The boot loader copies the RAM image (the
; program, the standard library and its font) from the upper ROM, where
; the video draws in the RAM, down into the RAM, maps every section to
; RAM and jumps to the program's reset code at RAM x0000.  ROM.md has the
; ROM layout.
;
;     ROM x6000-xA9FF  ->  RAM x0000-x49FF      (ROM address = RAM + x6000)
;
; Steps
;   1. map = 01: section 0 (the zero page) reads RAM, so the loop can keep
;      its page counters there.  The boot loader runs in section 7, whose
;      map bit does not change, so the next fetch is safe.
;   2. copy RAM pages x01-x49 from ROM pages x61-xA9, then page x00 from
;      ROM x60 (last, because it holds the loop's counters).
;   3. copy map_switch (8 bytes) from the ROM into the RAM under it, so the
;      fetch after the map write reads the same bytes from either memory.
;      map_switch is in byte column 79's first 32 bytes (xFE00-xFE1F),
;      which the video reads only in vertical blanking, so they are never
;      seen on the screen.
;   4. map = FF (every section reads RAM), jump to x0000.  The RAM's zero
;      page is then exactly the program's page x00 (MAP_SHADOW is not set,
;      because the older demos keep code there; a program that calls
;      map_set stores FF in MAP_SHADOW first).
;
; The copy takes 25 clocks a byte, about 19 ms for the 18,944 bytes.
;
;     customasm rom_boot.asm -f hexstr -o rom_boot.hex
;     python3 placard_sim.py rom_boot.asm
;
; gen_rom.tcl merges rom_boot.hex, rom_lib.hex and the program into
; rom.mem.  The CPU's PC starts at 0000, so x0000-x0003 of the ROM is
; this file's reset jump, not the program's.
;
; Date: 10/16/2026

#include "placard.asm"

ROM_IMAGE   = 0x60      ; ROM page that holds RAM page x00
IMAGE_END   = 0x4A      ; first RAM page not copied (x4A00, the mode bytes' page)
MAP_PORT    = 0x50      ; ROM/RAM map register page (write only)
DST         = 0xFE      ; RAM page being written (zero page, during the copy)
SRC         = 0xFF      ; ROM page being read

#addr 0x0000
reset:
    ld   boot >> 8, y
    jmp  boot

#addr 0xFD00
boot:
    ld   MAP_PORT, y
    ld   0x01, [y,x]            ; map = 01: section 0 reads RAM, the rest ROM

    ld   0x01, ac               ; pages x01-x49 first
    ld   ac, [DST]
    ld   ROM_IMAGE + 1, ac
    ld   ac, [SRC]
    clr  x
copy_byte:                      ; X = byte in the page, 00 at the start of a page
    ld   [SRC], y
    ld   [y,x], ac              ; read the ROM (sections 3-7 read ROM)
    ld   [DST], y
    ld   ac, [y,x]              ; write the RAM (every write goes to RAM)
    ld   x, ac
    inc
    ld   ac, x
    bne  copy_byte
    ld   [SRC], ac              ; next page; X is 00 again
    inc
    ld   ac, [SRC]
    ld   [DST], ac
    inc
    ld   ac, [DST]
    xor  IMAGE_END, ac
    bne  copy_byte

copy_page0:                     ; page x00 last: it overwrites DST and SRC
    ld   ROM_IMAGE, y
    ld   [y,x], ac
    ld   0x00, y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  copy_page0

    ld   map_switch >> 8, y     ; map_switch into the RAM under it
    ld   map_switch, x
copy_switch:
    ld   [y,x], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    xor  (map_switch + 8) & 0xFF, ac
    bne  copy_switch
    jmp  map_switch             ; Y is still map_switch's page

#addr 0xFE00
map_switch:                     ; also in the RAM: the fetches after the map write
    ld   MAP_PORT, y
    ld   0xFF, [y,x]            ; map = FF: every section reads RAM
    ld   0x00, y
    jmp  0x00                   ; the program's reset code in the RAM
