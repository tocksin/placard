; ============================================================
; menu.asm - the program menu: the demo programs in one ROM, in turn
; ============================================================
;
; The menu ROM holds the CPU test, pi, Mandelbrot, the Game of Life, the
; text demo and the ray caster together (docs/MENU.md).  gen_menu_rom.py
; builds it: it assembles every program, writes menu_data.asm (the program
; table, the names and the packed RAM programs) and puts this menu, the two
; ROM programs and the library into one 64 KB image, menu.hex.
;
; At power-up the programs run in turn: each one until it is done or for
; its time limit (P_RH:P_RL: 2 minutes, Mandelbrot 3).  Esc in any program
; shows the menu.  Up / Down or
; 1-6 pick a program and Enter runs it until Esc.  With no key for
; IDLE_SECS (2 minutes) the menu goes back to running them in turn, from
; the highlighted one.
;
; How a program is run:
;   - a ROM program (text demo, ray caster) runs in place: the menu jumps
;     to its entry with map 05, as the boot loader would;
;   - a RAM program (CPU test, pi, Mandelbrot, Game of Life) is copied
;     into the RAM first, as the boot loader does for a RAM image: RAM
;     x0000-x49FF cleared, the program's bytes copied from the ROM (runs
;     from x2800-x5FFF, and one program's x0100-x1EFF kept at the same
;     address in ROM section 0), then map FF and a jump to x0000 through
;     MB_GO in the RAM.
; Every program calls the menu hook about once per frame (menu_poll in the
; library, or its own copy from menu_hook.py), which comes back here
; through MB_EXIT (map 05, then menu_back) with the reason in MB_WHY.
;
; ROM: x6000-x6003 jump here (the boot's entry), x2000-x25FF this code,
; x2600 on menu_data.asm.  RAM: the menu block x5D00-x5D2F
; (placard_menu.asm), zero page x20-x2F, the loader's bytes xF0-xF9.
;
;     python3 gen_menu_rom.py                 menu_data.asm, menu.hex (the whole ROM)
;     python3 test_menu.py                    runs it in placard_sim
;
; Date: 10/20/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"
#include "menu_data.asm"

m_sel   = 0x20          ; highlighted program
m_p     = 0x21          ; program to run
m_t     = 0x22          ; scratch
m_t2    = 0x23
m_rl    = 0x24          ; return address of draw_list / draw_secs
m_rh    = 0x25
m_i     = 0x26          ; draw_list: item
m_inv   = 0x27          ;   0 or 80 (inverse)
m_ptl   = 0x28          ;   string pointer
m_pth   = 0x29
m_sec   = 0x2A          ; seconds left before the programs run in turn again
m_fc    = 0x2B          ;   frames into this second
m_last  = 0x2C          ; FRAME_LO last seen

L_PG    = 0xF0          ; loader (the zero page is cleared under it)
L_P     = 0xF1          ;   program
L_I     = 0xF2          ;   run, and the program's last run + 1
L_END   = 0xF3
L_SH    = 0xF4          ;   source, destination, bytes left (0 = 256)
L_SL    = 0xF5
L_DH    = 0xF6
L_DL    = 0xF7
L_N     = 0xF8
L_T     = 0xF9

; LIST_ROW, LIST_COL (the list), SEC_ROW, SEC_COL (the idle seconds) are
; in menu_data.asm

; ------------------------------------------------------------
; the boot loader jumps to x6000
; ------------------------------------------------------------
#addr 0x6000
    ld   menu_start >> 8, y
    jmp  menu_start

; ============================================================
; start: the menu block, then the first program
; ============================================================
#addr 0x2000
menu_start:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MENU_BLK >> 8, y       ; the mark, the hold time and the program
    ld   MB_MAGIC, x
    ld   0x4D, [y,x]            ; "MNU"
    ld   MB_MAGIC + 1, x
    ld   0x4E, [y,x]
    ld   MB_MAGIC + 2, x
    ld   0x55, [y,x]
    ld   MB_HOLD, x
    ld   HOLD_FRAMES & 0xFF, [y,x]
    ld   MB_HOLD + 1, x
    ld   HOLD_FRAMES >> 8, [y,x]
    ld   MB_PROG, x
    ld   NPROG - 1, [y,x]       ; so the first turn runs program 0
    clr  ac                     ; MB_EXIT and MB_GO code into the RAM
    ld   ac, [m_t]
ms_cp:
    ld   [m_t], ac
    add  stubs & 0xFF, x
    ld   stubs >> 8, y
    ld   [y,x], ac
    ld   ac, [m_t2]
    ld   [m_t], ac
    add  MB_EXIT, x
    ld   MENU_BLK >> 8, y
    ld   [m_t2], ac
    ld   ac, [y,x]
    ld   [m_t], ac
    inc
    ld   ac, [m_t]
    xor  16, ac
    bne  ms_cp

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

; ------------------------------------------------------------
; launch - run program m_p (MB_MODE set)
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
    ld   [m_p], ac
    add  P_KIND & 0xFF, x
    ld   P_KIND >> 8, y
    ld   [y,x], ac
    bne  ln_ram
    ld   [m_p], ac              ; ROM program: jump to its entry (map 05)
    add  P_EH & 0xFF, x
    ld   [y,x], ac
    ld   ac, [m_t]
    ld   [m_p], ac
    add  P_EL & 0xFF, x
    ld   [y,x], ac
    ld   [m_t], y
    jmp  ac
ln_ram:
    ld   loader >> 8, y
    jmp  loader

; the code copied to MB_EXIT (x5D20) and MB_GO (x5D28): it runs from the
; RAM because the fetch after a map write still uses the old map
stubs:
    ld   0x50, y                ; MB_EXIT: map 05, back to the menu
    ld   0x05, [y,x]
    ld   menu_back >> 8, y
    jmp  menu_back
    ld   0x50, y                ; MB_GO: map FF, the RAM program's reset
    ld   0xFF, [y,x]
    ld   0x00, y
    jmp  0x00

; ============================================================
; menu_back - a program stopped (MB_EXIT): Esc shows the menu, time up or
; done runs the next program
; ============================================================
#addr 0x2100
menu_back:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   0x05, ac
    ld   ac, [MAP_SHADOW]
    ld   0x50, y                ; LIB_RAM again (a RAM program may have
    ld   0x00, [y,x]            ; used x1F00): map 00, ROM to RAM
    ld   LIB_RAM >> 8, y
    clr  ac
mb_lr:
    ld   ac, x
    ld   [y,x], [y,x]
    inc
    bne  mb_lr
    ld   0x50, y
    ld   0x05, [y,x]            ; map 05
    ld   LINK_LO, x             ; CALL port_init
    ld   mb_1, [x]
    ld   LINK_HI, x
    ld   mb_1 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
mb_1:
    ld   MENU_BLK >> 8, y
    ld   MB_WHY, x
    ld   [y,x], ac
    xor  WHY_NEXT, ac
    bne  menu_show
    ld   next_prog >> 8, y
    jmp  next_prog

; ------------------------------------------------------------
; menu_show - the menu screen
; ------------------------------------------------------------
menu_show:
    ld   LINK_LO, x             ; CALL con_clear
    ld   ms_1, [x]
    ld   LINK_HI, x
    ld   ms_1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ms_1:
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
    ld   ms_2, [x]
    ld   LINK_HI, x
    ld   ms_2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ms_2:
    ld   [m_i], ac
    inc
    ld   ac, [m_i]
    bra  ms_line
ms_done:
    ld   MENU_BLK >> 8, y       ; highlight the program that ran last
    ld   MB_PROG, x
    ld   [y,x], ac
    ld   ac, [m_sel]
    ld   ms_3, ac               ; draw_list
    ld   ac, [m_rl]
    ld   ms_3 >> 8, ac
    ld   ac, [m_rh]
    ld   draw_list >> 8, y
    jmp  draw_list
ms_3:
    ld   menu_idle >> 8, y
    jmp  menu_idle

; ============================================================
; the menu loop
; ============================================================
#addr 0x2200
menu_idle:
    ld   IDLE_SECS, ac          ; the idle count starts again
    ld   ac, [m_sec]
    clr  ac
    ld   ac, [m_fc]
    ld   mi_1, ac               ; draw_secs
    ld   ac, [m_rl]
    ld   mi_1 >> 8, ac
    ld   ac, [m_rh]
    ld   draw_secs >> 8, y
    jmp  draw_secs
mi_1:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   mi_2, [x]
    ld   LINK_HI, x
    ld   mi_2 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
mi_2:
    ld   [FRAME_LO], ac
    ld   ac, [m_last]
menu_loop:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   ml_1, [x]
    ld   LINK_HI, x
    ld   ml_1 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
ml_1:
    ld   [FRAME_LO], ac         ; m_fc += frames since the last pass
    sub  [m_last], ac
    beq  ml_keys
    add  [m_fc], ac
    ld   ac, [m_fc]
    ld   [FRAME_LO], ac
    ld   ac, [m_last]
    ld   [m_fc], ac             ; a whole second?
    sub  60, ac
    blt  ml_keys
    ld   ac, [m_fc]
    ld   [m_sec], ac
    sub  1, ac
    ld   ac, [m_sec]
    beq  ml_idle                ; idle long enough: run them in turn again
    ld   ml_2, ac               ; draw_secs
    ld   ac, [m_rl]
    ld   ml_2 >> 8, ac
    ld   ac, [m_rh]
    ld   draw_secs >> 8, y
    jmp  draw_secs
ml_2:
ml_keys:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ml_3, [x]
    ld   LINK_HI, x
    ld   ml_3 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ml_3:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   ml_4, [x]
    ld   LINK_HI, x
    ld   ml_4 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ml_4:
    beq  menu_loop              ; no key
    ld   ac, [m_t]
    ld   mk_1, ac               ; a key: the idle count starts again
    ld   ac, [m_rl]
    ld   mk_1 >> 8, ac
    ld   ac, [m_rh]
    ld   IDLE_SECS, ac
    ld   ac, [m_sec]
    clr  ac
    ld   ac, [m_fc]
    ld   draw_secs >> 8, y
    jmp  draw_secs
mk_1:
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
#addr 0x2300
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
    ld   mk_none, ac            ; draw_list
    ld   ac, [m_rl]
    ld   mk_none >> 8, ac
    ld   ac, [m_rh]
    ld   draw_list >> 8, y
    jmp  draw_list
mk_none:
    ld   menu_loop >> 8, y
    jmp  menu_loop

; ------------------------------------------------------------
; draw_secs - "nnn" at SEC_ROW, SEC_COL: m_sec
;   return: m_rh:m_rl.  Changes AC, X, Y, T0-T7
; ------------------------------------------------------------
draw_secs:
    ld   SEC_COL, ac
    ld   ac, [CUR_COL]
    ld   SEC_ROW, ac
    ld   ac, [CUR_ROW]
    ld   [m_sec], ac            ; right aligned in 3 columns
    sub  100, ac
    bcc  ds_2
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   ds_1, [x]
    ld   LINK_HI, x
    ld   ds_1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ds_1:
    ld   [m_sec], ac
    sub  10, ac
    bcc  ds_2
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   ds_2, [x]
    ld   LINK_HI, x
    ld   ds_2 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ds_2:
    ld   [m_sec], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   ds_3, [x]
    ld   LINK_HI, x
    ld   ds_3 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
ds_3:
    ld   [m_rh], y
    jmp  [m_rl]

; ------------------------------------------------------------
; draw_list - the program names, m_sel in inverse video
;   return: m_rh:m_rl.  Changes AC, X, Y, T0-T5
; ------------------------------------------------------------
#addr 0x2400
draw_list:
    clr  ac
    ld   ac, [m_i]
dl_item:
    ld   [m_i], ac              ; row LIST_ROW + 2 * item
    add  [m_i], ac
    add  LIST_ROW, ac
    ld   ac, [CUR_ROW]
    ld   LIST_COL, ac
    ld   ac, [CUR_COL]
    clr  ac
    ld   ac, [m_inv]
    ld   [m_i], ac
    xor  [m_sel], ac
    bne  dl_1
    ld   0x80, ac
    ld   ac, [m_inv]
dl_1:
    ld   [m_i], ac
    add  NAME_L & 0xFF, x
    ld   NAME_L >> 8, y
    ld   [y,x], ac
    ld   ac, [m_ptl]
    ld   [m_i], ac
    add  NAME_H & 0xFF, x
    ld   [y,x], ac
    ld   ac, [m_pth]
dl_ch:
    ld   [m_pth], y
    ld   [m_ptl], x
    ld   [y,x], ac
    beq  dl_next
    or   [m_inv], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   dl_2, [x]
    ld   LINK_HI, x
    ld   dl_2 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
dl_2:
    ld   [m_ptl], ac
    add  1, ac
    ld   ac, [m_ptl]
    bcc  dl_ch
    ld   [m_pth], ac
    add  1, ac
    ld   ac, [m_pth]
    bra  dl_ch
dl_next:
    ld   [m_i], ac
    inc
    ld   ac, [m_i]
    xor  NPROG, ac
    bne  dl_item
    ld   [m_rh], y
    jmp  [m_rl]

; ============================================================
; loader - copy RAM program MB_PROG into the RAM and run it
; ============================================================
#addr 0x2500
loader:
    clr  ac                     ; RAM x0000-x49FF = 0, as the boot's copy
ld_z0:                          ; leaves it: the zero page first
    ld   ac, x
    ld   0x00, [x]
    inc
    bne  ld_z0
    ld   1, ac
    ld   ac, [L_PG]
ld_z1:
    ld   [L_PG], y
    clr  ac
ld_z2:
    ld   ac, x
    ld   0x00, [y,x]
    inc
    bne  ld_z2
    ld   [L_PG], ac
    inc
    ld   ac, [L_PG]
    xor  0x4A, ac
    bne  ld_z1
    ld   MENU_BLK >> 8, y       ; its runs: L_I up to L_END
    ld   MB_PROG, x
    ld   [y,x], ac
    ld   ac, [L_P]
    add  P_RF & 0xFF, x
    ld   P_RF >> 8, y
    ld   [y,x], ac
    ld   ac, [L_I]
    ld   [L_P], ac
    add  P_RE & 0xFF, x
    ld   [y,x], ac
    ld   ac, [L_END]
    ld   0x50, y                ; map 01: the zero page reads RAM, the rest ROM
    ld   0x01, [y,x]
    ld   [L_P], ac              ; its part kept in place in ROM x0100-x1EFF:
    add  P_IB & 0xFF, x         ; RAM pages P_IA up to P_IB (none if P_IB = 0)
    ld   P_IB >> 8, y
    ld   [y,x], ac
    ld   ac, [L_SL]
    ld   [L_P], ac
    add  P_IA & 0xFF, x
    ld   [y,x], ac
    ld   ac, [L_SH]
    ld   [L_SL], ac
    beq  ld_runs
    ld   MENU_BLK >> 8, y       ; the zero page reads ROM while this copies,
    ld   MB_IA, x               ; so the pages are counted in the menu block
    ld   ac, [y,x]
    ld   [L_SH], ac
    ld   MB_IA + 1, x
    ld   ac, [y,x]
    ld   0x50, y                ; map 04: section 0 reads ROM, section 2
    ld   0x04, [y,x]            ; (the menu block) RAM
ld_ip:
    ld   MENU_BLK >> 8, y
    ld   MB_IA + 1, x
    ld   [y,x], ac
    ld   ac, y
    clr  ac
ld_ib:
    ld   ac, x
    ld   [y,x], [y,x]           ; ROM to the RAM under it
    inc
    bne  ld_ib
    ld   MENU_BLK >> 8, y
    ld   MB_IA + 1, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    ld   MB_IA, x
    xor  [y,x], ac
    bne  ld_ip
    ld   0x50, y                ; map 01 again
    ld   0x01, [y,x]

ld_runs:
    ld   [L_I], ac
    xor  [L_END], ac
    beq  ld_done
    ld   [L_I], ac              ; source, destination and length of run L_I
    add  R_SH & 0xFF, x
    ld   R_SH >> 8, y
    ld   [y,x], ac
    ld   ac, [L_SH]
    ld   [L_I], ac
    add  R_SL & 0xFF, x
    ld   R_SL >> 8, y
    ld   [y,x], ac
    ld   ac, [L_SL]
    ld   [L_I], ac
    add  R_DH & 0xFF, x
    ld   R_DH >> 8, y
    ld   [y,x], ac
    ld   ac, [L_DH]
    ld   [L_I], ac
    add  R_DL & 0xFF, x
    ld   R_DL >> 8, y
    ld   [y,x], ac
    ld   ac, [L_DL]
    ld   [L_I], ac
    add  R_N & 0xFF, x
    ld   R_N >> 8, y
    ld   [y,x], ac
    ld   ac, [L_N]
ld_b:
    ld   [L_SH], y
    ld   [L_SL], x
    ld   [y,x], ac
    ld   [L_DH], y
    ld   [L_DL], x
    ld   ac, [y,x]
    ld   [L_SL], ac
    add  1, ac
    ld   ac, [L_SL]
    bcc  ld_s
    ld   [L_SH], ac
    add  1, ac
    ld   ac, [L_SH]
ld_s:
    ld   [L_DL], ac
    add  1, ac
    ld   ac, [L_DL]
    bcc  ld_d
    ld   [L_DH], ac
    add  1, ac
    ld   ac, [L_DH]
ld_d:
    ld   [L_N], ac
    sub  1, ac
    ld   ac, [L_N]
    bne  ld_b
    ld   [L_I], ac
    inc
    ld   ac, [L_I]
    bra  ld_runs
ld_done:
    clr  ac                     ; the loader's zero page bytes back to 0
    ld   ac, [L_PG]
    ld   ac, [L_P]
    ld   ac, [L_I]
    ld   ac, [L_END]
    ld   ac, [L_SH]
    ld   ac, [L_SL]
    ld   ac, [L_DH]
    ld   ac, [L_DL]
    ld   ac, [L_N]
    ld   ac, [L_T]
    ld   0x50, y                ; map 05 (section 2 reads RAM), then MB_GO
    ld   0x05, [y,x]
    ld   MENU_BLK >> 8, y
    jmp  MB_GO
