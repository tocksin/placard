; ============================================================
; placard_input.asm - Placard line input and mouse pointer helpers
; ============================================================
;
;     con_gets     type a line on the console (keyboard, with Backspace)
;     mouse_move   move a pointer position by the last mouse packet
;
; placard_lib.asm includes this file, in library bank 2.
;
; Date: 10/18/2026
; ============================================================

#addr LIB2_CODE + 0x1400

; ------------------------------------------------------------
; con_gets - read a line typed on the keyboard, echoed at the cursor
;   in:      R1:R0 = buffer, R2 = most characters to take (1-255; the
;            buffer needs one more byte for the 00 at the end)
;   out:     AC = number of characters; the buffer holds them and a 00.
;            Enter ends the line (the cursor moves to the next line);
;            Backspace takes back a character on the same text row.
;   changes: R3, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  waits for the keys: one kbd_scan per frame
;   Uses 4 stack bytes.  The console must be set up (con_clear).
; ------------------------------------------------------------
con_gets:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    clr  ac
    ld   ac, [R3]               ; characters so far
cg_wait:
    ld   1, ac
    ld   LINK_LO, x
    ld   in_r1, [x]
    ld   LINK_HI, x
    ld   in_r1 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
in_r1:
    ld   LINK_LO, x
    ld   in_r2, [x]
    ld   LINK_HI, x
    ld   in_r2 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
in_r2:
cg_key:
    ld   LINK_LO, x
    ld   in_r3, [x]
    ld   LINK_HI, x
    ld   in_r3 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
in_r3:
    beq  cg_wait
    ld   ac, [T7]
    xor  0x0A, ac
    beq  cg_end
    ld   [T7], ac
    xor  0x08, ac
    beq  cg_bs
    ld   [T7], ac               ; printable: 20-7E
    sub  0x20, ac
    blt  cg_key
    ld   [T7], ac
    sub  0x7F, ac
    bcc  cg_key
    ld   [R3], ac               ; room left?
    sub  [R2], ac
    bcc  cg_key
    ld   [R0], ac               ; address = R1:R0 + R3 (carry into R1)
    add  [R3], ac
    ld   ac, x
    ld   [R1], y
    bcc  cg_nc                  ; the carry flag from the add
    ld   [R1], ac
    inc
    ld   ac, y
cg_nc:
    ld   [T7], ac
    ld   ac, [y,x]
    ld   [R3], ac
    inc
    ld   ac, [R3]
    ld   [T7], ac
    ld   LINK_LO, x
    ld   in_r4, [x]
    ld   LINK_HI, x
    ld   in_r4 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
in_r4:
    bra  cg_key
cg_bs:
    ld   [R3], ac               ; Backspace: only with a character to
    beq  cg_key                 ; take back, on this text row
    ld   [CUR_COL], ac
    beq  cg_key
    ld   [R3], ac
    dec
    ld   ac, [R3]
    ld   [CUR_COL], ac
    dec
    ld   ac, [CUR_COL]
    ld   0x20, ac
    ld   LINK_LO, x
    ld   in_r5, [x]
    ld   LINK_HI, x
    ld   in_r5 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
in_r5:
    ld   [CUR_COL], ac
    dec
    ld   ac, [CUR_COL]
    bra  cg_key
cg_end:
    ld   0x0A, ac
    ld   LINK_LO, x
    ld   in_r6, [x]
    ld   LINK_HI, x
    ld   in_r6 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
in_r6:
    ld   [R0], ac               ; the 00 at the end
    add  [R3], ac
    ld   ac, x
    ld   [R1], y
    bcc  cg_nc2                  ; the carry flag from the add
    ld   [R1], ac
    inc
    ld   ac, y
cg_nc2:
    ld   0, [y,x]
    ld   [R3], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

#addr LIB2_CODE + 0x1500

; ------------------------------------------------------------
; mouse_move - move a pointer by the last mouse packet, kept on screen
;   in:      R1:R0 = X, 0-639; R3:R2 = Y, 0-479 (the caller keeps them);
;            MOUSE_DX, MOUSE_DY from mouse_poll
;   out:     R1:R0 = X + MOUSE_DX, R3:R2 = Y + MOUSE_DY, each held to
;            the screen (0-639, 0-479)
;   changes: AC, T0-T3
;   clocks:  about 120
;   Call it after mouse_poll returns 1.
; ------------------------------------------------------------
mouse_move:
    ld   [R0], ac               ; X: low byte + DX, and its carry
    add  [MOUSE_DX], ac
    ld   ac, [T0]
    ld   [R0], ac
    and  [MOUSE_DX], ac
    ld   ac, [T1]
    ld   [R0], ac
    or   [MOUSE_DX], ac
    ld   ac, [T2]
    ld   [T0], ac
    ld   ac, [R0]
    not
    and  [T2], ac
    or   [T1], ac
    blt  mm_xc
    clr  ac
    bra  mm_xh
mm_xc:
    ld   1, ac
mm_xh:
    add  [R1], ac               ; high byte + carry, - 1 if DX < 0
    ld   ac, [R1]
    ld   [MOUSE_DX], ac
    blt  mm_xp_b7
    bra  mm_xp
mm_xp_b7:
    ld   [R1], ac
    dec
    ld   ac, [R1]
mm_xp:
    ld   [R1], ac
    blt  mm_x0                  ; below 0
    sub  2, ac
    blt  mm_y
    bne  mm_x1                  ; 3xx
    ld   [R0], ac
    blt  mm_x1                  ; 280-2FF
    bra  mm_y
mm_x0:
    clr  ac
    ld   ac, [R0]
    ld   ac, [R1]
    bra  mm_y
mm_x1:
    ld   0x7F, ac
    ld   ac, [R0]
    ld   2, ac
    ld   ac, [R1]
mm_y:
    ld   [R2], ac               ; Y the same way
    add  [MOUSE_DY], ac
    ld   ac, [T0]
    ld   [R2], ac
    and  [MOUSE_DY], ac
    ld   ac, [T1]
    ld   [R2], ac
    or   [MOUSE_DY], ac
    ld   ac, [T2]
    ld   [T0], ac
    ld   ac, [R2]
    not
    and  [T2], ac
    or   [T1], ac
    blt  mm_yc
    clr  ac
    bra  mm_yh
mm_yc:
    ld   1, ac
mm_yh:
    add  [R3], ac
    ld   ac, [R3]
    ld   [MOUSE_DY], ac
    blt  mm_yp_b7
    bra  mm_yp
mm_yp_b7:
    ld   [R3], ac
    dec
    ld   ac, [R3]
mm_yp:
    ld   [R3], ac
    blt  mm_y0
    sub  1, ac
    blt  mm_done
    bne  mm_y1                  ; 2xx and up
    ld   [R2], ac
    and  0xE0, ac
    xor  0xE0, ac
    bne  mm_done
mm_y1:
    ld   0xDF, ac
    ld   ac, [R2]
    ld   1, ac
    ld   ac, [R3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
mm_y0:
    clr  ac
    ld   ac, [R2]
    ld   ac, [R3]
mm_done:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
