; ============================================================
; placard_menu.asm - the program menu's hook, for programs in the menu ROM
; ============================================================
;
; The menu ROM (menu.asm, gen_menu_rom.py, docs/MENU.md) runs one program
; at a time and takes the machine back when Esc is pressed or, while it is
; rotating through the programs, when the program's time is up.  There
; are no interrupts, so each program calls a hook about once per frame:
;
;   - a ROM program (it uses this library) calls menu_poll;
;   - a RAM program (the older demos, which run with map FF and can't
;     reach the library) carries its own copy of the same check, written
;     by menu_hook.py.  Its copy reads only the key matrix's Esc: in
;     those programs a PS/2 keyboard's Esc does nothing (time up still
;     works, and the menu itself takes either keyboard).
;
; Both talk to the menu through the menu block at RAM x5D00 (MENU_BLK),
; which the menu fills in before it starts a program.  Without the menu
; the block holds no "MNU" mark and the hooks return at once, so the same
; program builds run by themselves too.
;
;   x5D00-x5D02  MB_MAGIC   "MNU" while the menu is in charge
;   x5D03        MB_MODE    0 = rotating (time limit), 1 = picked from the
;                           menu (runs until Esc)
;   x5D04-x5D05  MB_LEFT    frames left before the next program (rotating),
;                           low byte first; the program leaves when it goes
;                           below 0
;   x5D06        MB_LAST    last line read (RAM programs' hook)
;   x5D07        MB_FRAME   last FRAME_LO seen (menu_poll)
;   x5D08        MB_SYNC    0 = MB_FRAME not set yet (the first menu_poll sets it)
;   x5D09        MB_WHY     why the program stopped: 1 = Esc, 2 = time up or done
;   x5D0A        MB_CUR     scratch for the RAM programs' hook
;   x5D0B-x5D0C  MB_HOLD    frames a finished program shows its result
;                           (RAM programs' hk_hold), low byte first
;   x5D0D        MB_PROG    the program running (the menu's own)
;   x5D0E-x5D0F  MB_IA      the menu's loader: last page + 1, page
;   x5D10-x5D1F  free
;   x5D20-x5D27  MB_EXIT    code: map = 05, then jump to the menu
;   x5D28-x5D2F  MB_GO      code: map = FF, then jump to RAM x0000
;
; x5D00-x5DF2 is program RAM (docs/ROM.md) that none of the menu's programs
; use; the audio buffer starts at x5DF3.
;
; placard_lib.asm includes this file; its code is at MENU_CODE (xC500).
;
; Date: 10/22/2026
; ============================================================

MENU_BLK  = 0x5D00
MB_MAGIC  = 0x00
MB_MODE   = 0x03
MB_LEFT   = 0x04
MB_LAST   = 0x06
MB_FRAME  = 0x07
MB_SYNC   = 0x08
MB_WHY    = 0x09
MB_CUR    = 0x0A
MB_HOLD   = 0x0B
MB_PROG   = 0x0D
MB_IA     = 0x0E
MB_EXIT   = 0x20
MB_GO     = 0x28
WHY_ESC   = 1
WHY_NEXT  = 2

#addr MENU_CODE

; ------------------------------------------------------------
; menu_poll - give the menu its chance: call it about once per frame
;   in:      FRAME_LO kept by frame_poll (the program calls it every frame)
;   out:     returns when the program goes on; never returns when Esc is
;            down or the program's time is up (it jumps to the menu)
;   changes: AC, X, Y, T0; with a PS/2 keyboard, every 4th frame
;            also as kbd_scan (see below)
;   clocks:  15 without the menu; about 75 with it (about 100 with a PS/2
;            keyboard), plus the PS/2 keyboard's listen when it runs
;   Uses 6 stack bytes (only for that listen).
;   Without the menu ROM it returns at once.  The time limit counts the
;   frames FRAME_LO moved on since the last call, so a program can call it
;   less often than every frame, but at least every 255 frames.
;   Esc on a PS/2 keyboard counts too.  A program that doesn't call
;   kbd_scan (or wait_frames_io) never listens to the PS/2 keyboard, so
;   when it hasn't been listened to for 4 frames menu_poll listens to it
;   itself (kbd_ps2_poll: about 8,000-26,000 clocks, more if keys come);
;   its Esc is then seen at the next call.
; ------------------------------------------------------------
menu_poll:
    ld   MENU_BLK >> 8, y
    ld   MB_MAGIC, x
    ld   [y,x], ac
    xor  0x4D, ac               ; "M"
    bne  mp_ret
    ld   MB_MAGIC + 1, x
    ld   [y,x], ac
    xor  0x4E, ac               ; "N"
    bne  mp_ret
    ld   MB_MAGIC + 2, x
    ld   [y,x], ac
    xor  0x55, ac               ; "U"
    bne  mp_ret
    ld   PORT, y                ; Esc: key column 0, row 0
    clr  x
    ld   0x0F, [y,x]            ; drive column 0 (/CS high)
    nop                         ; rows settle
    nop
    nop
    nop
    ld   [y,x], ac
    ld   P_IDLE, [y,x]
    and  1, ac
    beq  mp_esc
    ld   [KBD_FLAGS], ac        ; a PS/2 keyboard (placard_ps2.asm)?
    and  KF_PS2, ac
    beq  mp_time
    ld   PS2V, y                ; its Esc down?
    ld   V_NOW + (K_ESC >> 3), x
    ld   [y,x], ac
    and  1 << (K_ESC & 7), ac
    beq  mp_esc
    ld   [FRAME_LO], ac         ; not listened to for 4 frames: the program
    ld   V_KLAST, x             ; doesn't call kbd_scan, so listen here
    sub  [y,x], ac
    sub  4, ac
    bcc  mp_kpoll
mp_time:
    ld   MENU_BLK >> 8, y
    ld   MB_MODE, x
    ld   [y,x], ac
    bne  mp_ret                 ; picked: no time limit
    ld   MB_SYNC, x
    ld   [y,x], ac
    bne  mp_count
    ld   1, [y,x]               ; first call: start counting from here
    ld   [FRAME_LO], ac
    ld   MB_FRAME, x
    ld   ac, [y,x]
    bra  mp_ret
mp_count:
    ld   [FRAME_LO], ac         ; T0 = frames since the last call
    ld   MB_FRAME, x
    sub  [y,x], ac
    ld   ac, [T0]
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   MB_LEFT, x             ; MB_LEFT -= T0
    ld   [y,x], ac
    sub  [T0], ac
    ld   ac, [y,x]
    bcc  mp_ret                 ; no borrow
    ld   MB_LEFT + 1, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    blt  mp_next                ; below 0: time up
mp_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
mp_esc:
    ld   WHY_ESC, ac
    bra  mp_go
mp_next:
    ld   WHY_NEXT, ac
mp_go:
    ld   MENU_BLK >> 8, y
    ld   MB_WHY, x
    ld   ac, [y,x]
    jmp  MB_EXIT                ; the menu's exit code in the RAM (x5D20)
mp_kpoll:
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
    ld   LINK_LO, x             ; CALL kbd_ps2_poll (Esc is seen next time)
    ld   mp_kp, [x]
    ld   LINK_HI, x
    ld   mp_kp >> 8, [x]
    ld   kbd_ps2_poll >> 8, y
    jmp  kbd_ps2_poll
mp_kp:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave
