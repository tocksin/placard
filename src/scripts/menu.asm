; ============================================================
; made by asm_expand.py from menu.masm: change that file, then run
;     python3 asm_expand.py menu.masm
; ============================================================

; ============================================================
; menu.masm - the demo menu, a program on the SD card (MENU.PLC)
; ============================================================
;
; The menu shows the demo programs and runs them in turn (docs/MENU.md).
; It is a library program the DOS loads from the SD card (docs/DOS.md):
; BOOT.CFG = "MENU.PLC" makes it the program that runs at power-up (hold
; Esc for the DOS's file browser instead).  The demos are .PLC files in
; the same folder (gen_plc.py makes them, ../../sdcard):
;
;     CPUTEST.PLC  PI.PLC  MANDEL.PLC  LIFE.PLC
;
; At power-up the programs run in turn: each one until it is done or for
; its time limit (2 minutes, Mandelbrot 3).  Esc in a program shows the
; menu.  Up / Down or 1-4 pick a program and Enter runs it until Esc.
; With no key for IDLE_SECS (2 minutes) the menu goes back to running
; them in turn, from the highlighted one.  Esc in the menu goes to the
; DOS's file browser.
;
; How a program is run: the menu writes its name in MB_PARENT, the time
; limit and mode in the menu block, and asks the DOS to run the file
; (dos_run, the vector at x800C).  The program's hook (menu_hook.py; the
; library's menu_poll for a library program) comes back to the DOS on Esc
; or when the time is up, with the reason in MB_WHY, and the DOS runs
; MENU.PLC again because MB_PARENT names it.  MB_MENU (x5D11) = "M" says
; the menu is being run again, not started from the browser.
;
; RAM: the program at x0100 (asm_expand.py pages it), zero page x20-x2A,
; the menu block x5D00 (placard_menu.asm).
;
;     python3 asm_expand.py menu.masm                 menu.asm
;     python3 gen_plc.py menu.asm -o ../../sdcard/MENU.PLC
;     python3 test_menu.py                            runs it in placard_sim
;
; Date: 10/26/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

NPROG      = 4
IDLE_SECS  = 120        ; menu seconds with no key before running in turn again
ROT_FRAMES = 7193       ; 2 minutes in turn
MAN_FRAMES = 10789      ; 3 minutes: Mandelbrot finishes
HOLD_FRAMES = 599       ; 10 s to show a finished result
DOS_RUN    = 0x800C     ; the DOS vectors (dos.masm)
DOS_BACK   = 0x8008

m_sel   = 0x20          ; highlighted program
m_p     = 0x21          ; program to run
m_t     = 0x22          ; scratch
m_t2    = 0x23
m_i     = 0x24          ; draw_list: item
m_ptl   = 0x25          ;   string pointer
m_pth   = 0x26
m_sec   = 0x27          ; seconds left before the programs run in turn again
m_fc    = 0x28          ;   frames into this second
m_bar   = 0x29          ; draw_list: the item's first bar mode byte (low)

BAR_TINT   = 0x40       ; the highlighted program: a blue bar
TITLE_TINT = 0x30       ; the title: a gold band, screen rows 20-35
LIST_ROW   = 12         ; text row of program 1 (then every other row)
LIST_COL   = 6
SEC_ROW    = 30
SEC_COL    = 61


; ============================================================
; main - started by the DOS: the first time, or again after a program
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MENU_BLK >> 8, y
    ld   MB_MENU, x
    ld   [y,x], ac
    xor  0x4D, ac
    bne  m_fresh
    ld   0, [y,x]               ; run again after a program: why did it stop?
    ld   MB_WHY, x
    ld   [y,x], ac
    xor  WHY_NEXT, ac
    bne  m_show                 ; Esc (or no reason): the menu
    ld   next_prog >> 8, y
    jmp  next_prog
m_fresh:
    ld   MB_HOLD, x
    ld   HOLD_FRAMES & 0xFF, [y,x]
    ld   MB_HOLD + 1, x
    ld   HOLD_FRAMES >> 8, [y,x]
    ld   MB_PROG, x
    ld   NPROG - 1, [y,x]       ; so the first turn runs program 0
    ld   next_prog >> 8, y
    jmp  next_prog
m_show:
    ld   menu_show >> 8, y
    jmp  menu_show

; ------------------------------------------------------------
; next_prog - running in turn: the program after MB_PROG
; ------------------------------------------------------------
next_prog:
    ld   MENU_BLK >> 8, y
    ld   MB_PROG, x
    ld   [y,x], ac
    inc
    ld   ac, [m_p]
    xor  NPROG, ac
    bne  np_1
    ld   ac, [m_p]              ; past the last: AC = 0, program 0
np_1:
    ld   MB_MODE, x
    ld   0x00, [y,x]            ; 0 = in turn
    ld   launch >> 8, y
    jmp  launch

; ------------------------------------------------------------
; launch - run program m_p (MB_MODE set) through the DOS
; ------------------------------------------------------------
launch:
    ld   MENU_BLK >> 8, y
    ld   [m_p], ac
    ld   MB_PROG, x
    ld   ac, [y,x]
    ld   [m_p], ac              ; its time limit (frames), P_RH:P_RL
    add  P_RL & 0xFF, x
    ld   P_RL >> 8, y
    ld   [y,x], ac
    ld   MENU_BLK >> 8, y
    ld   MB_LEFT, x
    ld   ac, [y,x]
    ld   [m_p], ac
    add  P_RH & 0xFF, x
    ld   P_RH >> 8, y
    ld   [y,x], ac
    ld   MENU_BLK >> 8, y
    ld   MB_LEFT + 1, x
    ld   ac, [y,x]
    ld   MB_SYNC, x
    ld   0x00, [y,x]
    ld   MB_WHY, x
    ld   0x00, [y,x]
    ld   MB_MENU, x
    ld   0x4D, [y,x]            ; "M": run me again afterwards
    ld   8, ac                  ; MB_PARENT = "MENU.PLC"
    ld   ac, [m_t]
ln_cp:
    ld   [m_t], ac
    add  s_self & 0xFF, x
    ld   s_self >> 8, y
    ld   [y,x], ac
    ld   ac, [m_t2]
    ld   [m_t], ac
    add  MB_PARENT, x
    ld   MENU_BLK >> 8, y
    ld   [m_t2], ac
    ld   ac, [y,x]
    ld   [m_t], ac
    sub  1, ac
    ld   ac, [m_t]
    bcc  ln_cp
    ld   [m_p], ac              ; R1:R0 = the program's file name
    add  NAME_L & 0xFF, x
    ld   NAME_L >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [m_p], ac
    add  NAME_H & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   DOS_RUN >> 8, y
    jmp  DOS_RUN & 0xFF

; ============================================================
; menu_show - the menu screen
; ============================================================
draw_secs:
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
    ld   SEC_COL, ac
    ld   ac, [CUR_COL]
    ld   SEC_ROW, ac
    ld   ac, [CUR_ROW]
    ld   [m_sec], ac            ; right aligned in 3 columns
    sub  100, ac
    bcc  ds_2
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   menu_r11, [x]
    ld   LINK_HI, x
    ld   menu_r11 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
menu_r11:
    ld   [m_sec], ac
    sub  10, ac
    bcc  ds_2
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   menu_r12, [x]
    ld   LINK_HI, x
    ld   menu_r12 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
menu_r12:
ds_2:
    ld   [m_sec], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   menu_r13, [x]
    ld   LINK_HI, x
    ld   menu_r13 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
menu_r13:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; draw_list - the program names, m_sel on a tinted bar
; ------------------------------------------------------------

#addr 0x0200
menu_show:
    ld   LINK_LO, x             ; CALL con_clear
    ld   menu_r1, [x]
    ld   LINK_HI, x
    ld   menu_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
menu_r1:
    clr  ac                     ; the fixed lines: (column, row, string)
    ld   ac, [m_i]
ms_line:
    ld   [m_i], ac
    add  TEXT_COL & 0xFF, x
    ld   TEXT_COL >> 8, y
    ld   [y,x], ac
    beq  ms_done
    ld   ac, [CUR_COL]
    ld   [m_i], ac
    add  TEXT_ROW & 0xFF, x
    ld   [y,x], ac
    ld   ac, [CUR_ROW]
    ld   [m_i], ac
    add  TEXT_L & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [m_i], ac
    add  TEXT_H & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   menu_r2, [x]
    ld   LINK_HI, x
    ld   menu_r2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
menu_r2:
    ld   [m_i], ac
    inc
    ld   ac, [m_i]
    bra  ms_line
ms_done:
    ld   0x5A, y                ; the title band (rows 20-35, text row 3)
    ld   15, ac
ms_tb:
    add  0x20 + 20, x
    ld   TITLE_TINT, [y,x]
    sub  1, ac
    bcc  ms_tb
    ld   MENU_BLK >> 8, y       ; highlight the program that ran last
    ld   MB_PROG, x
    ld   [y,x], ac
    ld   ac, [m_sel]
    ld   LINK_LO, x             ; CALL draw_list
    ld   menu_r3, [x]
    ld   LINK_HI, x
    ld   menu_r3 >> 8, [x]
    ld   draw_list >> 8, y
    jmp  draw_list
menu_r3:
    ld   menu_idle >> 8, y
    jmp  menu_idle

; ============================================================
; the menu loop
; ============================================================
menu_idle:
    ld   IDLE_SECS, ac          ; the idle count starts again
    ld   ac, [m_sec]
    clr  ac
    ld   ac, [m_fc]
    ld   LINK_LO, x             ; CALL draw_secs
    ld   menu_r4, [x]
    ld   LINK_HI, x
    ld   menu_r4 >> 8, [x]
    ld   draw_secs >> 8, y
    jmp  draw_secs
menu_r4:
menu_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   menu_r5, [x]
    ld   LINK_HI, x
    ld   menu_r5 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
menu_r5:
    ld   [m_fc], ac             ; a whole second?
    inc
    ld   ac, [m_fc]
    sub  60, ac
    blt  ml_keys
    ld   ac, [m_fc]             ; AC = 0
    ld   [m_sec], ac
    dec
    ld   ac, [m_sec]
    beq  ml_idle                ; idle long enough: run them in turn again
    ld   LINK_LO, x             ; CALL draw_secs
    ld   menu_r6, [x]
    ld   LINK_HI, x
    ld   menu_r6 >> 8, [x]
    ld   draw_secs >> 8, y
    jmp  draw_secs
menu_r6:
ml_keys:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   menu_r7, [x]
    ld   LINK_HI, x
    ld   menu_r7 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
menu_r7:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   menu_r8, [x]
    ld   LINK_HI, x
    ld   menu_r8 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
menu_r8:
    beq  menu_loop              ; no key
    ld   ac, [m_t]
    ld   IDLE_SECS, ac          ; a key: the idle count starts again
    ld   ac, [m_sec]
    clr  ac
    ld   ac, [m_fc]
    ld   LINK_LO, x             ; CALL draw_secs
    ld   menu_r9, [x]
    ld   LINK_HI, x
    ld   menu_r9 >> 8, [x]
    ld   draw_secs >> 8, y
    jmp  draw_secs
menu_r9:
    ld   menu_key >> 8, y
    jmp  menu_key
ml_idle:
    ld   MENU_BLK >> 8, y       ; in turn again, from the highlighted program
    ld   MB_MODE, x
    ld   0x00, [y,x]
    ld   [m_sel], ac
    ld   ac, [m_p]
    ld   launch >> 8, y
    jmp  launch

; ------------------------------------------------------------
; menu_key - m_t = the key
; ------------------------------------------------------------

#addr 0x0300
menu_key:
    ld   [m_t], ac
    xor  0x11, ac               ; Up
    beq  mk_up
    ld   [m_t], ac
    xor  0x12, ac               ; Down
    beq  mk_down
    ld   [m_t], ac
    xor  0x0A, ac               ; Enter
    beq  mk_run
    ld   [m_t], ac
    xor  0x20, ac               ; Space
    beq  mk_run
    ld   [m_t], ac
    xor  0x1B, ac               ; Esc: the DOS
    beq  mk_dos
    ld   [m_t], ac              ; 1 - NPROG: run that one
    sub  0x31, ac
    blt  mk_none
    ld   ac, [m_t2]
    sub  NPROG, ac
    bcc  mk_none                ; no borrow: too big
    ld   [m_t2], ac
    ld   ac, [m_sel]
mk_run:
    ld   MENU_BLK >> 8, y       ; picked: runs until Esc
    ld   MB_MODE, x
    ld   0x01, [y,x]
    ld   [m_sel], ac
    ld   ac, [m_p]
    ld   launch >> 8, y
    jmp  launch
mk_up:
    ld   [m_sel], ac
    bne  mk_u1
    ld   NPROG, ac
mk_u1:
    sub  1, ac
    ld   ac, [m_sel]
    bra  mk_draw
mk_down:
    ld   [m_sel], ac
    add  1, ac
    ld   ac, [m_sel]
    xor  NPROG, ac
    bne  mk_draw
    ld   ac, [m_sel]            ; AC = 0
mk_draw:
    ld   LINK_LO, x             ; CALL draw_list
    ld   menu_r10, [x]
    ld   LINK_HI, x
    ld   menu_r10 >> 8, [x]
    ld   draw_list >> 8, y
    jmp  draw_list
menu_r10:
mk_none:
    ld   menu_loop >> 8, y
    jmp  menu_loop
mk_dos:
    ld   DOS_BACK >> 8, y
    jmp  DOS_BACK & 0xFF

; ------------------------------------------------------------
; draw_secs - "nnn" at SEC_ROW, SEC_COL: m_sec
; ------------------------------------------------------------
draw_list:
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
    ld   ac, [m_i]
dl_item:
    ld   [m_i], ac              ; row LIST_ROW + 2 * item
    add  [m_i], ac
    add  LIST_ROW, ac
    ld   ac, [CUR_ROW]
    ld   LIST_COL, ac
    ld   ac, [CUR_COL]
    ld   [CUR_ROW], ac
    shl                         ; its bar: screen rows 8 * row - 4 to
    shl                         ; 8 * row + 11, mode bytes x5A1C + 8 * row
    shl
    add  0x1C, ac
    ld   ac, [m_bar]
    ld   0x5A, y
    ld   [m_i], ac
    xor  [m_sel], ac
    bne  dl_off
    ld   15, ac                 ; the highlighted program: tinted bar
dl_on:
    add  [m_bar], x
    ld   BAR_TINT, [y,x]
    sub  1, ac
    bcc  dl_on
    bra  dl_1
dl_off:
    ld   15, ac                 ; the others: no tint
dl_of:
    add  [m_bar], x
    ld   0x00, [y,x]
    sub  1, ac
    bcc  dl_of
dl_1:
    ld   [m_i], ac
    add  TITLE_L & 0xFF, x
    ld   TITLE_L >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [m_i], ac
    add  TITLE_H & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   menu_r14, [x]
    ld   LINK_HI, x
    ld   menu_r14 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
menu_r14:
    ld   [m_i], ac
    inc
    ld   ac, [m_i]
    xor  NPROG, ac
    bne  dl_item
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; tables and text
; ============================================================

#addr 0x0400
P_RL:    #d8 ROT_FRAMES & 0xFF, ROT_FRAMES & 0xFF, MAN_FRAMES & 0xFF, ROT_FRAMES & 0xFF
P_RH:    #d8 ROT_FRAMES >> 8, ROT_FRAMES >> 8, MAN_FRAMES >> 8, ROT_FRAMES >> 8
NAME_L:  #d8 nm_0 & 0xFF, nm_1 & 0xFF, nm_2 & 0xFF, nm_3 & 0xFF
NAME_H:  #d8 nm_0 >> 8, nm_1 >> 8, nm_2 >> 8, nm_3 >> 8
TITLE_L: #d8 ti_0 & 0xFF, ti_1 & 0xFF, ti_2 & 0xFF, ti_3 & 0xFF
TITLE_H: #d8 ti_0 >> 8, ti_1 >> 8, ti_2 >> 8, ti_3 >> 8
TEXT_COL: #d8 17, LIST_COL, LIST_COL, LIST_COL, SEC_COL + 4, LIST_COL, 0
TEXT_ROW: #d8 3, 9, 26, 30, 30, 32
TEXT_L:  #d8 tx_0 & 0xFF, tx_1 & 0xFF, tx_2 & 0xFF, tx_3 & 0xFF, tx_4 & 0xFF, tx_5 & 0xFF
TEXT_H:  #d8 tx_0 >> 8, tx_1 >> 8, tx_2 >> 8, tx_3 >> 8, tx_4 >> 8, tx_5 >> 8
s_self:  #d "MENU.PLC", 0x00
nm_0:    #d "CPUTEST.PLC", 0x00
nm_1:    #d "PI.PLC", 0x00
nm_2:    #d "MANDEL.PLC", 0x00
nm_3:    #d "LIFE.PLC", 0x00
tx_0:    #d "P L A C A R D       D E M O       P R O G R A M S", 0x00
tx_1:    #d "Pick a program:", 0x00
tx_2:    #d "Up / Down or 1-4 choose, Enter runs it.  Esc in a program comes back.", 0x00


#addr 0x0500
tx_3:    #d "With no key pressed, the programs run in turn again in", 0x00
tx_4:    #d "s.", 0x00
tx_5:    #d "In turn, each runs until it is done, or for 2 minutes (Mandelbrot 3).  Esc here: the DOS.", 0x00


#addr 0x0600
ti_0:    #d " 1  CPU test        every instruction, checked on a pass / fail grid", 0x00
ti_1:    #d " 2  Pi              1000 digits with a spigot, timed", 0x00
ti_2:    #d " 3  Mandelbrot      the set in 1, 2, 4 and 8 bpp, timed", 0x00
ti_3:    #d " 4  Game of Life    632 x 480 cells, 1000 generations", 0x00
