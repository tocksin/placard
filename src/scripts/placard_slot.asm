; ============================================================
; placard_slot.asm - Placard expansion slot helpers
; ============================================================
;
; The four expansion slots (docs/EXPANSION.md) each answer 128 addresses.  A
; card that wants to be found starts with a boot header in offsets 00-5F,
; which the boot loader (rom_boot.asm) checks and runs at power-up:
;
;   offset  00-02  "PLC"
;           03     card ID (0 = none: pick any other value)
;           04     code length n, 1-90 (0 = no boot code)
;           05     checksum: the sum of the n code bytes, mod 256
;           06-    the code, run at RAM x0100 with AC = slot number and
;                  R1:R0 = the slot's base address
;   60-7F  free for the card's registers
;
; placard_lib.asm includes this file, in library bank 2.
;
; Date: 10/18/2026
; ============================================================

#addr LIB2_CODE + 0x580

; ------------------------------------------------------------
; slot_id - which card is in a slot?
;   in:      AC = slot, 1-4
;   out:     AC = the card ID (offset 03) if the card starts with "PLC",
;            else 0; R1:R0 = the slot's base address (x5100, x5300,
;            x5180 or x5380), for reaching its registers
;   changes: X, Y
;   clocks:  about 110
; ------------------------------------------------------------
slot_id:
    sub  1, ac
    and  3, ac
    ld   ac, [R0]
    add  slot_hi & 0xFF, x
    ld   slot_hi >> 8, y
    ld   [y,x], ac
    ld   ac, [R1]
    ld   [R0], ac
    add  slot_lo & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    xor  0x50, ac
    bne  sl_none
    ld   [R0], ac
    add  1, x
    ld   [y,x], ac
    xor  0x4C, ac
    bne  sl_none
    ld   [R0], ac
    add  2, x
    ld   [y,x], ac
    xor  0x43, ac
    bne  sl_none
    ld   [R0], ac
    add  3, x
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sl_none:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

slot_hi:    ; slots 1-4
    #d8 0x51, 0x53, 0x51, 0x53
slot_lo:
    #d8 0x00, 0x00, 0x80, 0x80
