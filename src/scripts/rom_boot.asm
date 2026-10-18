; ============================================================
; rom_boot.asm - Placard ROM boot loader
; ============================================================
;
; The ROM/RAM map clears to all ROM at power-up, so the CPU starts here,
; in the ROM, at PC = 0000.  Video reads always read the RAM (memory
; control PLD revision 04); only CPU reads follow the map.  The byte at
; BOOT_MODE (written by gen_rom.tcl) picks one of two ways to start the
; program.  ROM.md has the ROM layout.
;
; BOOT_MODE = 00: ROM program (the standard way).
;   The program runs in place from ROM x6000-xFBFF and calls the standard
;   library in place at ROM x3000-x3FFF.  The boot writes map = 05:
;   sections 0 (zero page, x0000-x1FFF) and 2 (x4000-x4FFF: mode bytes,
;   audio, program data) read RAM; 1 (library) and 3-7 (program) read
;   ROM, while the video still shows the RAM.  It sets MAP_SHADOW = 05 and
;   jumps to the program's entry at x6000.
;
; BOOT_MODE = 01: RAM image (the older demos, written to run at RAM x0000).
;     ROM x6000-xA9FF  ->  RAM x0000-x49FF      (ROM address = RAM + x6000)
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
;      because the older demos keep code there).
;   The copy takes 25 clocks a byte, about 19 ms for the 18,944 bytes.
;
;     customasm rom_boot.asm -f hexstr -o rom_boot.hex
;     python3 placard_sim.py rom_boot.asm
;
; gen_rom.tcl merges rom_boot.hex, rom_lib.hex and the program into
; rom.mem.  The CPU's PC starts at 0000, so x0000-x0003 of the ROM is
; this file's reset jump, not the program's.
;
; Date: 10/18/2026

#include "placard.asm"

ROM_IMAGE   = 0x60      ; ROM page that holds RAM page x00
IMAGE_END   = 0x4A      ; first RAM page not copied (x4A00; the older demos fit below it)
MAP_PORT    = 0x50      ; ROM/RAM map register page (write only)
DST         = 0xFE      ; RAM page being written (zero page, during the copy)
SRC         = 0xFF      ; ROM page being read
MAP_SHADOW  = 0x07      ; zeropage.asm: copy of the map register
MAP_ROM_RUN = 0x05      ; ROM program: sections 0 and 2 read RAM, 1 and 3-7 ROM
PROG_START  = 0x6000    ; ROM program entry
BOOT_MODE   = 0xFC00    ; 00 = ROM program, 01 = RAM image (set by gen_rom.tcl)
PORT        = 0x5200    ; shared port latch (placard_io.asm)
P_IDLE      = 0xFB      ; the latch at rest

#addr 0x0000
reset:
    ld   boot >> 8, y
    jmp  boot

#addr BOOT_MODE
boot_mode:
    #d8 0x00                    ; gen_rom.tcl writes the mode here

#addr 0xFD00
boot:
    ld   PORT >> 8, y           ; shared port at rest (IO.md): no keyboard
    ld   P_IDLE, [y,x]          ; column, SD /CS low (also holds the PS/2
                                ; mouse off), SCK and MOSI high
    ld   BOOT_MODE >> 8, y
    ld   BOOT_MODE & 0xFF, x
    ld   [y,x], ac
    bne  boot_copy

    ld   MAP_PORT, y            ; ROM program
    ld   MAP_ROM_RUN, [y,x]     ; map = 05 (section 7 keeps its bit)
    ld   MAP_ROM_RUN, ac
    ld   ac, [MAP_SHADOW]
    ld   PROG_START >> 8, y
    jmp  PROG_START & 0xFF

boot_copy:                      ; RAM image
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
