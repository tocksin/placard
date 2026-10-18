; ============================================================
; rom_boot.asm - Placard ROM boot loader
; ============================================================
;
; The ROM/RAM map clears to all ROM at power-up, so the CPU starts here,
; in the ROM, at PC = 0000.  Video reads always read the RAM (memory
; control PLD revision 04); only CPU reads follow the map.  The byte at
; BOOT_MODE (written by gen_rom.tcl) picks one of two ways to start the
; program.  docs/ROM.md has the ROM layout.
;
; BOOT_MODE = 00: ROM program (the standard way).
;   The program runs in place from ROM x6000-xDFFF and calls the standard
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
;
; EXPANSION CARDS (docs/EXPANSION.md), before either mode, like the Apple II's
; slot scan:
;   1. map = 01, so the zero page is RAM.
;   2. Unless Esc is held, for slots 4, 3, 2, 1: if the card's first bytes
;      are "PLC", card ID, code length n (1-90), checksum (the sum of the
;      n code bytes), then the n code bytes are copied to RAM x0100 and
;      called (the library's CALL) with AC = slot number, R1:R0 = the
;      slot's base address, SP = FE and MAP_SHADOW = 01.  The card's code
;      returns to go on with the next slot and then the normal boot, or
;      never returns to take the boot over (load its own program, start
;      from its own ROM).  It may use the library and the I/O drivers.
;      It must keep zero page xFF (the slot being scanned), leave map 01
;      when it returns, and keep section 7 reading the ROM.
;   An empty slot reads FF (the read bus pull-ups), so it fails the check.
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
P_COL0      = 0x0B      ; the same with keyboard column 0 driven (Esc is row 0)
MAP_ZP_RAM  = 0x01      ; section 0 reads RAM, the rest ROM
CARD_CODE   = 0x0100    ; where a card's boot code is copied and run
CARD_MAX    = 90        ; longest card boot code (offsets 06-5F)

LINK_LO     = 0x04      ; zeropage.asm
LINK_HI     = 0x05
SP          = 0x06
R0          = 0x10
R1          = 0x11
T0          = 0x18      ; code length
T1          = 0x19      ; checksum from the card
T2          = 0x1A      ; byte being copied
T3          = 0x1B      ; sum of the bytes copied
T4          = 0x1C
SLOT        = 0xFF      ; slot being scanned, 4 down to 1

#addr 0x0000
reset:
    ld   boot >> 8, y
    jmp  boot

#addr BOOT_MODE
boot_mode:
    #d8 0x00                    ; gen_rom.tcl writes the mode here

#addr 0xFD00
boot:
    ld   PORT >> 8, y           ; shared port at rest (docs/IO.md): no keyboard
    ld   P_IDLE, [y,x]          ; column, SD /CS low (also holds the PS/2
                                ; mouse off), SCK and MOSI high
    ld   MAP_PORT, y
    ld   MAP_ZP_RAM, [y,x]      ; map = 01: the zero page is RAM
    ld   PORT >> 8, y
    clr  x                      ; an even address reads the key rows
    ld   P_COL0, [y,x]
    ld   [y,x], ac
    ld   P_IDLE, [y,x]
    and  1, ac
    beq  boot_go                ; Esc held: skip the cards
    ld   4, ac
    ld   ac, [SLOT]
    ld   scan >> 8, y
    jmp  scan

boot_go:
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

; ------------------------------------------------------------
; the expansion card scan, slots 4 down to 1
; ------------------------------------------------------------
scan:
    ld   [SLOT], ac             ; R1:R0 = the slot's base address
    add  (slot_hi - 1) & 0xFF, x
    ld   slot_hi >> 8, y
    ld   [y,x], ac
    ld   ac, [R1]
    ld   [SLOT], ac
    add  (slot_lo - 1) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [R1], y
    ld   [R0], x                ; "PLC"
    ld   [y,x], ac
    xor  0x50, ac
    bne  next
    ld   [R0], ac
    add  1, x
    ld   [y,x], ac
    xor  0x4C, ac
    bne  next
    ld   [R0], ac
    add  2, x
    ld   [y,x], ac
    xor  0x43, ac
    bne  next
    ld   [R0], ac               ; code length, 1-90
    add  4, x
    ld   [y,x], ac
    ld   ac, [T0]
    beq  next
    blt  next
    sub  CARD_MAX + 1, ac
    bcc  next
    ld   [R0], ac               ; checksum
    add  5, x
    ld   [y,x], ac
    ld   ac, [T1]
    clr  ac
    ld   ac, [T2]
    ld   ac, [T3]
copy_card:                      ; card offset 6 + n to RAM x0100 + n
    ld   [R0], ac
    add  6, ac
    add  [T2], x
    ld   [R1], y
    ld   [y,x], ac
    ld   ac, [T4]
    add  [T3], ac
    ld   ac, [T3]
    ld   [T2], x
    ld   CARD_CODE >> 8, y
    ld   [T4], ac
    ld   ac, [y,x]
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  [T0], ac
    bne  copy_card
    ld   [T3], ac
    xor  [T1], ac
    bne  next
    ld   0xFE, ac               ; run it: stack below SLOT
    ld   ac, [SP]
    ld   MAP_ZP_RAM, ac
    ld   ac, [MAP_SHADOW]
    ld   LINK_LO, x
    ld   card_back, [x]
    ld   LINK_HI, x
    ld   card_back >> 8, [x]
    ld   [SLOT], ac
    ld   CARD_CODE >> 8, y
    jmp  CARD_CODE & 0xFF
card_back:
    ld   MAP_PORT, y
    ld   MAP_ZP_RAM, [y,x]
next:
    ld   [SLOT], ac
    dec
    ld   ac, [SLOT]
    bne  scan
    ld   boot_go >> 8, y
    jmp  boot_go

slot_hi:    ; slots 1-4: x5100, x5300, x5180, x5380
    #d8 0x51, 0x53, 0x51, 0x53
slot_lo:
    #d8 0x00, 0x00, 0x80, 0x80
