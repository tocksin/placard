; lib_dec16.asm - con_dec16 for placard_lib.asm, which includes it right
; after placard_slot.asm: it goes on in the free end of the slot helpers'
; page (xC600-xC6FF), the one library page with room for all of it, so
; it runs without jumps between pages.  Every branch stays in this page.
;
; Date: 11/10/2026

; ------------------------------------------------------------
; con_dec16 - print a 16-bit value in decimal, no leading zeros
;   in:      R1:R0 = value, 0-65535
;   out:     R1:R0 = 0, R2 = 10
;   changes: AC, X, Y, T0-T5
;   clocks:  about 900-4,200 (about 800 a digit, con_putc included)
;   Uses 2 stack bytes.  It is in the free end of the slot helpers' page
;   (xC600, SLOT_CODE), the one library page with room for all of it.  Each digit is the count of times its power of
;   ten can be taken off.  R1:R0 = the value left, R2 = the power's index
;   (bit 7 set once a digit is printed); con_putc keeps them.
; ------------------------------------------------------------
con_dec16:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    clr  ac
    ld   ac, [R2]
cw_dig:
    ld   [R2], ac               ; T2:T1 = the power: 10000, 1000, 100, 10
    and  0x03, ac
    add  cw_pow & 0xFF, x
    ld   cw_pow >> 8, y
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [R2], ac
    and  0x03, ac
    add  (cw_pow & 0xFF) + 4, x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   0x30, ac
    ld   ac, [T0]               ; the digit, as a character
cw_sub:
    ld   [R1], ac               ; value >= power?  high bytes first
    sub  [T2], ac
    bcs  cw_out
    ld   ac, [T4]
    ld   [R0], ac
    sub  [T1], ac
    ld   ac, [T3]
    bcc  cw_ok
    ld   [T4], ac               ; a borrow from the high byte
    beq  cw_out
    dec
    ld   ac, [T4]
cw_ok:
    ld   [T3], ac               ; value -= power, digit + 1
    ld   ac, [R0]
    ld   [T4], ac
    ld   ac, [R1]
    ld   [T0], ac
    inc
    ld   ac, [T0]
    bra  cw_sub
cw_out:
    ld   [R2], ac               ; a 0 before any other digit is not printed
    blt  cw_put
    ld   [T0], ac
    xor  0x30, ac
    beq  cw_next
cw_put:
    ld   [R2], ac
    or   0x80, ac
    ld   ac, [R2]
    ld   [T0], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   cw_back1, [x]
    ld   LINK_HI, x
    ld   cw_back1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
cw_back1:
cw_next:
    ld   [R2], ac
    inc
    ld   ac, [R2]
    and  0x7F, ac
    xor  4, ac
    bne  cw_dig
    ld   [R0], ac               ; the units, always printed
    add  0x30, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   cw_back2, [x]
    ld   LINK_HI, x
    ld   cw_back2 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
cw_back2:
    clr  ac
    ld   ac, [R0]
    ld   10, ac
    ld   ac, [R2]
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

cw_pow:                         ; the powers of ten
    #d8 0x10, 0xE8, 0x64, 0x0A  ; 10000, 1000, 100, 10: low bytes
    #d8 0x27, 0x03, 0x00, 0x00  ;   high bytes
