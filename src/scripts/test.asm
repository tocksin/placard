; ============================================================
; made by asm_expand.py from test.masm: change that file, then run
;     python3 asm_expand.py test.masm
; ============================================================

; ============================================================
; test.masm - TEST.PLC: the system test, a program on the SD card
; ============================================================
;
; A library program the DOS runs from the card (T in the demo menu, Enter
; on TEST.PLC in the browser, or BOOT.CFG = "TEST.PLC" to run it at every
; power-up).  It checks the parts of the machine a program can reach and
; shows one line for each (docs/software/TEST.md):
;
;     RAM         two passes over the free RAM, both chips: every byte
;                 written with its address (low byte xor high byte, then
;                 the complement), then read back.  The screen shows noise
;                 while the video RAM is tested (about half a second).
;     Card slots  the card ID in each expansion slot (slot_id), -- for an
;                 empty slot or a card with no "PLC" header
;     Keyboard    whether a PS/2 keyboard has answered (KBD_FLAGS bit 1);
;                 kept up to date, so a keyboard plugged in later shows
;     Mouse       whether a device in the mouse socket acknowledges F5
;                 (disable reporting: harmless), or the mouse already runs
;     SD card     sd_init and fs_mount again
;     Sound       two beeps, A 440 Hz then A 880 Hz
;
; Keys: Space runs the tests again, B beeps again, Esc goes back
; (menu_poll).
;
; RAM: the program at x0100-x0BFF, zero page x20-x3F.  The RAM test
; covers x0C00-x1EFF, x2000-x4CFF (the DOS's own x3000-x3FFF too: the
; ROM loads DOS.PLC again afterwards), x5400-x59FF, x5C00-x5CFF and the
; video RAM x6000-xFFFF.  It leaves out the zero page and stack, this
; program, LIB_RAM (x1F00), the SD and PS/2 variables (x4D00-x4FFF), the
; I/O window, the mode bytes, the menu block and the audio buffer.
;
;     python3 asm_expand.py test.masm                 test.asm
;     python3 gen_plc.py test.asm -o ../../sdcard/TEST.PLC
;     python3 test_systest.py                         runs it in placard_sim
;
; Date: 11/02/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

t_pg    = 0x20              ; RAM test: page (address high byte)
t_k     = 0x21              ;   the page's key: page xor seed
t_i     = 0x22              ;   byte in the page (X is not a source)
t_seed  = 0x23              ;   00 the first pass, FF the second
t_ph    = 0x24              ;   0 writing, 1 reading back
t_ri    = 0x25              ;   range 0-4
t_d     = 0x26              ;   the bits that differ
t_ecl   = 0x27              ;   errors, low byte (stops at FFFF)
t_ech   = 0x28              ;   errors, high byte
t_bah   = 0x29              ;   the first bad address, high byte
t_bal   = 0x2A              ;   low byte
t_exp   = 0x2B              ;   what was written there
t_got   = 0x2C              ;   what was read
t_bits  = 0x2D              ;   every bit that was ever wrong
t_s     = 0x2E              ; slot loop: slot 1-4
t_res   = 0x2F              ; a result code
t_fc    = 0x30              ; frames since the tests ran
t_kbd   = 0x31              ; the keyboard line as last drawn (KBD_FLAGS bit 1)

NRANGE     = 5
TITLE_TINT = 0x30           ; the title rows: gold
LABEL_COL  = 2
VAL_COL    = 14
ROW_RAM    = 3
ROW_RAM2   = 4
ROW_SLOT   = 6
ROW_KBD    = 8
ROW_MOUSE  = 10
ROW_SD     = 12
ROW_SND    = 14
ROW_KEYS   = 17
NOTE_1     = 69             ; A 440 Hz
NOTE_2     = 81             ; A 880 Hz
BEEP_GAP   = 20             ; frames between the beeps
MAP_ALL    = 0xFF           ; every section RAM (the RAM test)


; ============================================================
; main
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   run_all >> 8, y
    jmp  run_all

; ------------------------------------------------------------
; run_all - every test, then the frame loop
; ------------------------------------------------------------
run_all:
    ld   LINK_LO, x             ; silence while the RAM test runs
    ld   st_r1, [x]
    ld   LINK_HI, x
    ld   st_r1 >> 8, [x]
    ld   snd_init >> 8, y
    jmp  snd_init
st_r1:
    ld   LINK_LO, x             ; CALL con_clear
    ld   st_r2, [x]
    ld   LINK_HI, x
    ld   st_r2 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
st_r2:
    ld   LINK_LO, x             ; CALL title
    ld   st_r3, [x]
    ld   LINK_HI, x
    ld   st_r3 >> 8, [x]
    ld   title >> 8, y
    jmp  title
st_r3:
    ld   VAL_COL, ac
    ld   ac, [CUR_COL]
    ld   ROW_RAM, ac
    ld   ac, [CUR_ROW]
    ld   s_testing & 0xFF, ac
    ld   ac, [R0]
    ld   s_testing >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r4, [x]
    ld   LINK_HI, x
    ld   st_r4 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r4:
    ld   LINK_LO, x             ; CALL ram_test
    ld   st_r5, [x]
    ld   LINK_HI, x
    ld   st_r5 >> 8, [x]
    ld   ram_test >> 8, y
    jmp  ram_test
st_r5:
    ld   LINK_LO, x             ; the RAM test wrote over the screen
    ld   st_r6, [x]
    ld   LINK_HI, x
    ld   st_r6 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
st_r6:
    ld   LINK_LO, x             ; CALL title
    ld   st_r7, [x]
    ld   LINK_HI, x
    ld   st_r7 >> 8, [x]
    ld   title >> 8, y
    jmp  title
st_r7:
    ld   LINK_LO, x             ; CALL labels
    ld   st_r8, [x]
    ld   LINK_HI, x
    ld   st_r8 >> 8, [x]
    ld   labels >> 8, y
    jmp  labels
st_r8:
    ld   LINK_LO, x             ; CALL show_ram
    ld   st_r9, [x]
    ld   LINK_HI, x
    ld   st_r9 >> 8, [x]
    ld   show_ram >> 8, y
    jmp  show_ram
st_r9:
    ld   LINK_LO, x             ; CALL show_slots
    ld   st_r10, [x]
    ld   LINK_HI, x
    ld   st_r10 >> 8, [x]
    ld   show_slots >> 8, y
    jmp  show_slots
st_r10:
    ld   LINK_LO, x             ; CALL show_kbd
    ld   st_r11, [x]
    ld   LINK_HI, x
    ld   st_r11 >> 8, [x]
    ld   show_kbd >> 8, y
    jmp  show_kbd
st_r11:
    ld   LINK_LO, x             ; CALL show_mouse
    ld   st_r12, [x]
    ld   LINK_HI, x
    ld   st_r12 >> 8, [x]
    ld   show_mouse >> 8, y
    jmp  show_mouse
st_r12:
    ld   LINK_LO, x             ; CALL show_sd
    ld   st_r13, [x]
    ld   LINK_HI, x
    ld   st_r13 >> 8, [x]
    ld   show_sd >> 8, y
    jmp  show_sd
st_r13:
    ld   NOTE_1, ac
    ld   LINK_LO, x             ; CALL snd_beep
    ld   st_r14, [x]
    ld   LINK_HI, x
    ld   st_r14 >> 8, [x]
    ld   snd_beep >> 8, y
    jmp  snd_beep
st_r14:
    clr  ac
    ld   ac, [t_fc]
    ld   loop >> 8, y
    jmp  loop

; ------------------------------------------------------------
; loop - once a frame: sound, the second beep, the keyboard line, keys
; ------------------------------------------------------------
RLO:     #d8 0x0C, 0x20, 0x54, 0x5C, 0x60     ; the ranges' first pages
RHI:     #d8 0x1E, 0x4C, 0x59, 0x5C, 0xFF     ; and last pages

; ------------------------------------------------------------
; title - the title on a gold band
; ------------------------------------------------------------
LB_ROW:  #d8 ROW_RAM, ROW_RAM2, ROW_SLOT, ROW_KBD, ROW_MOUSE, ROW_SD, ROW_SND, ROW_SND, ROW_KEYS, 0
LB_COL:  #d8 LABEL_COL, VAL_COL, LABEL_COL, LABEL_COL, LABEL_COL, LABEL_COL, LABEL_COL, VAL_COL, LABEL_COL
LB_L:    #d8 s_ram & 0xFF, s_ranges & 0xFF, s_slots & 0xFF, s_kbd & 0xFF, s_mouse & 0xFF
         #d8 s_sd & 0xFF, s_snd & 0xFF, s_beeps & 0xFF, s_keys & 0xFF
LB_H:    #d8 s_ram >> 8, s_ranges >> 8, s_slots >> 8, s_kbd >> 8, s_mouse >> 8
         #d8 s_sd >> 8, s_snd >> 8, s_beeps >> 8, s_keys >> 8

; ------------------------------------------------------------
; at_val - the cursor to VAL_COL of row AC (a leaf)
; ------------------------------------------------------------

#addr 0x0200
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   st_r15, [x]
    ld   LINK_HI, x
    ld   st_r15 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
st_r15:
    ld   LINK_LO, x             ; CALL snd_update
    ld   st_r16, [x]
    ld   LINK_HI, x
    ld   st_r16 >> 8, [x]
    ld   snd_update >> 8, y
    jmp  snd_update
st_r16:
    ld   [t_fc], ac
    xor  BEEP_GAP, ac
    bne  lp_1
    ld   NOTE_2, ac
    ld   LINK_LO, x             ; CALL snd_beep
    ld   st_r17, [x]
    ld   LINK_HI, x
    ld   st_r17 >> 8, [x]
    ld   snd_beep >> 8, y
    jmp  snd_beep
st_r17:
lp_1:
    ld   [t_fc], ac             ; counts to FF and stays
    add  1, ac
    beq  lp_2
    ld   ac, [t_fc]
lp_2:
    ld   [KBD_FLAGS], ac        ; the keyboard line when it changed
    and  KF_PS2, ac
    xor  [t_kbd], ac
    beq  lp_3
    ld   LINK_LO, x             ; CALL show_kbd
    ld   st_r18, [x]
    ld   LINK_HI, x
    ld   st_r18 >> 8, [x]
    ld   show_kbd >> 8, y
    jmp  show_kbd
st_r18:
lp_3:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   st_r19, [x]
    ld   LINK_HI, x
    ld   st_r19 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
st_r19:
    ld   LINK_LO, x             ; Esc: back
    ld   st_r20, [x]
    ld   LINK_HI, x
    ld   st_r20 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
st_r20:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   st_r21, [x]
    ld   LINK_HI, x
    ld   st_r21 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
st_r21:
    ld   ac, [t_res]
    xor  0x20, ac               ; Space: everything again
    beq  lp_all
    ld   [t_res], ac
    and  0xDF, ac               ; B or b: the beeps again
    xor  0x42, ac
    bne  loop
    ld   NOTE_1, ac
    ld   LINK_LO, x             ; CALL snd_beep
    ld   st_r22, [x]
    ld   LINK_HI, x
    ld   st_r22 >> 8, [x]
    ld   snd_beep >> 8, y
    jmp  snd_beep
st_r22:
    clr  ac
    ld   ac, [t_fc]
    bra  loop
lp_all:
    ld   run_all >> 8, y
    jmp  run_all

; ------------------------------------------------------------
; ram_test - write every tested byte with its address, read it back, two
;            passes (seed 00, then FF)
;   out:     t_ech:t_ecl errors, t_bah:t_bal the first bad address,
;            t_exp / t_got what was written / read there, t_bits every
;            bit that was ever wrong
;   A leaf.  Runs with every section RAM (map FF) to reach the video RAM,
;   so it calls nothing; it runs from x0100, RAM in either map.
; ------------------------------------------------------------
title:
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
    ld   0x5A, y                ; the title band (screen rows 0-15)
    ld   15, ac
tt_b:
    add  0x20, x
    ld   TITLE_TINT, [y,x]
    sub  1, ac
    bcc  tt_b
    ld   LABEL_COL, ac
    ld   ac, [CUR_COL]
    clr  ac
    ld   ac, [CUR_ROW]
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r23, [x]
    ld   LINK_HI, x
    ld   st_r23 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r23:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; labels - the fixed text: (column, row, string) from the tables
; ------------------------------------------------------------
at_val:
    ld   ac, [CUR_ROW]
    ld   VAL_COL, ac
    ld   ac, [CUR_COL]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; show_ram - "OK", or the number of errors, the first bad address and the bits
; ------------------------------------------------------------

#addr 0x0300
ram_test:
    clr  ac
    ld   ac, [t_ecl]
    ld   ac, [t_ech]
    ld   ac, [t_bits]
    ld   ac, [t_seed]
    ld   0x50, y                ; map FF
    ld   MAP_ALL, [y,x]
rt_pass:
    clr  ac                     ; write first
    ld   ac, [t_ph]
rt_phase:
    clr  ac
    ld   ac, [t_ri]
rt_range:
    ld   [t_ri], ac             ; t_pg = the range's first page
    add  RLO & 0xFF, x
    ld   RLO >> 8, y
    ld   [y,x], ac
    ld   ac, [t_pg]
rt_page:
    ld   [t_pg], ac
    xor  [t_seed], ac
    ld   ac, [t_k]
    ld   [t_pg], y
    clr  ac
    ld   ac, [t_i]
    ld   [t_ph], ac
    bne  rt_r
rt_w:                           ; AC = byte: byte xor key into it
    ld   ac, x
    xor  [t_k], ac
    ld   ac, [y,x]
    xor  [t_k], ac
    add  1, ac
    bne  rt_w
    bra  rt_next
rt_r:
    ld   [t_i], x
    ld   [y,x], ac
    xor  [t_k], ac
    xor  [t_i], ac
    bne  rt_bad
rt_rc:
    ld   [t_i], ac
    add  1, ac
    ld   ac, [t_i]
    bne  rt_r
rt_next:
    ld   [t_ri], ac             ; the range's last page done?
    add  RHI & 0xFF, x
    ld   RHI >> 8, y
    ld   [y,x], ac
    xor  [t_pg], ac
    beq  rt_rend
    ld   [t_pg], ac
    add  1, ac
    ld   ac, [t_pg]
    bra  rt_page
rt_rend:
    ld   [t_ri], ac
    add  1, ac
    ld   ac, [t_ri]
    xor  NRANGE, ac
    bne  rt_range
    ld   [t_ph], ac             ; written: now read it back
    bne  rt_pdone
    ld   1, ac
    ld   ac, [t_ph]
    bra  rt_phase
rt_pdone:
    ld   [t_seed], ac           ; both passes done?
    bne  rt_done
    ld   0xFF, ac
    ld   ac, [t_seed]
    bra  rt_pass
rt_done:
    ld   [MAP_SHADOW], ac       ; the map back
    ld   0x50, y
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
rt_bad:                         ; AC = the bits that differ
    ld   ac, [t_d]
    or   [t_bits], ac
    ld   ac, [t_bits]
    ld   [t_ecl], ac            ; the first error: where and what
    or   [t_ech], ac
    bne  rt_b2
    ld   [t_pg], ac
    ld   ac, [t_bah]
    ld   [t_i], ac
    ld   ac, [t_bal]
    xor  [t_k], ac
    ld   ac, [t_exp]
    xor  [t_d], ac
    ld   ac, [t_got]
rt_b2:
    ld   [t_ecl], ac            ; count it, up to FFFF
    and  [t_ech], ac
    xor  0xFF, ac
    beq  rt_b3
    ld   [t_ecl], ac
    add  1, ac
    ld   ac, [t_ecl]
    bne  rt_b3
    ld   [t_ech], ac
    add  1, ac
    ld   ac, [t_ech]
rt_b3:
    ld   [t_pg], y
    bra  rt_rc

show_ram:
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
    ld   ROW_RAM, ac
    ld   LINK_LO, x             ; CALL at_val
    ld   st_r25, [x]
    ld   LINK_HI, x
    ld   st_r25 >> 8, [x]
    ld   at_val >> 8, y
    jmp  at_val
st_r25:
    ld   [t_ecl], ac
    or   [t_ech], ac
    bne  sr_bad
    ld   s_ok & 0xFF, ac
    ld   ac, [R0]
    ld   s_ok >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r26, [x]
    ld   LINK_HI, x
    ld   st_r26 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r26:
    ld   lib_leave >> 8, y
    jmp  lib_leave
sr_bad:
    ld   show_ram_bad >> 8, y
    jmp  show_ram_bad


#addr 0x0400
labels:
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
    ld   ac, [t_s]
lb_line:
    ld   [t_s], ac
    add  LB_ROW & 0xFF, x
    ld   LB_ROW >> 8, y
    ld   [y,x], ac
    beq  lb_done
    ld   ac, [CUR_ROW]
    ld   [t_s], ac
    add  LB_COL & 0xFF, x
    ld   [y,x], ac
    ld   ac, [CUR_COL]
    ld   [t_s], ac
    add  LB_L & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [t_s], ac
    add  LB_H & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r24, [x]
    ld   LINK_HI, x
    ld   st_r24 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r24:
    ld   [t_s], ac
    inc
    ld   ac, [t_s]
    bra  lb_line
lb_done:
    ld   lib_leave >> 8, y
    jmp  lib_leave

show_kbd:
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
    ld   ROW_KBD, ac
    ld   LINK_LO, x             ; CALL at_val
    ld   st_r48, [x]
    ld   LINK_HI, x
    ld   st_r48 >> 8, [x]
    ld   at_val >> 8, y
    jmp  at_val
st_r48:
    ld   [KBD_FLAGS], ac
    and  KF_PS2, ac
    ld   ac, [t_kbd]
    bne  sk_yes
    ld   s_knone & 0xFF, ac
    ld   ac, [R0]
    ld   s_knone >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r49, [x]
    ld   LINK_HI, x
    ld   st_r49 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r49:
    ld   lib_leave >> 8, y
    jmp  lib_leave
sk_yes:
    ld   s_kfound & 0xFF, ac
    ld   ac, [R0]
    ld   s_kfound >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r50, [x]
    ld   LINK_HI, x
    ld   st_r50 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r50:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; show_mouse - "running", or what F5 got: "found", "none", "wrong answer"
; ------------------------------------------------------------

#addr 0x0500
show_ram_bad:                   ; show_ram's link is pushed already
    ld   s_fail & 0xFF, ac      ; "FAILED: n errors, first at x"
    ld   ac, [R0]
    ld   s_fail >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r27, [x]
    ld   LINK_HI, x
    ld   st_r27 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r27:
    ld   [t_ecl], ac
    ld   ac, [R0]
    ld   [t_ech], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_dec16
    ld   st_r28, [x]
    ld   LINK_HI, x
    ld   st_r28 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
st_r28:
    ld   s_first & 0xFF, ac
    ld   ac, [R0]
    ld   s_first >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r29, [x]
    ld   LINK_HI, x
    ld   st_r29 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r29:
    ld   [t_bah], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   st_r30, [x]
    ld   LINK_HI, x
    ld   st_r30 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
st_r30:
    ld   [t_bal], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   st_r31, [x]
    ld   LINK_HI, x
    ld   st_r31 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
st_r31:
    ld   s_wrote & 0xFF, ac
    ld   ac, [R0]
    ld   s_wrote >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r32, [x]
    ld   LINK_HI, x
    ld   st_r32 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r32:
    ld   [t_exp], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   st_r33, [x]
    ld   LINK_HI, x
    ld   st_r33 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
st_r33:
    ld   s_read & 0xFF, ac
    ld   ac, [R0]
    ld   s_read >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r34, [x]
    ld   LINK_HI, x
    ld   st_r34 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r34:
    ld   [t_got], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   st_r35, [x]
    ld   LINK_HI, x
    ld   st_r35 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
st_r35:
    ld   s_bits & 0xFF, ac
    ld   ac, [R0]
    ld   s_bits >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r36, [x]
    ld   LINK_HI, x
    ld   st_r36 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r36:
    ld   [t_bits], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   st_r37, [x]
    ld   LINK_HI, x
    ld   st_r37 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
st_r37:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; show_slots - "1: 4C  2: --  3: --  4: --"
; ------------------------------------------------------------

#addr 0x0600
show_slots:
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
    ld   ROW_SLOT, ac
    ld   LINK_LO, x             ; CALL at_val
    ld   st_r38, [x]
    ld   LINK_HI, x
    ld   st_r38 >> 8, [x]
    ld   at_val >> 8, y
    jmp  at_val
st_r38:
    ld   1, ac
    ld   ac, [t_s]
ss_slot:
    ld   [t_s], ac              ; "n: "
    add  0x30, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   st_r39, [x]
    ld   LINK_HI, x
    ld   st_r39 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
st_r39:
    ld   0x3A, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   st_r40, [x]
    ld   LINK_HI, x
    ld   st_r40 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
st_r40:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   st_r41, [x]
    ld   LINK_HI, x
    ld   st_r41 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
st_r41:
    ld   [t_s], ac
    ld   LINK_LO, x             ; CALL slot_id
    ld   st_r42, [x]
    ld   LINK_HI, x
    ld   st_r42 >> 8, [x]
    ld   slot_id >> 8, y
    jmp  slot_id
st_r42:
    beq  ss_none
    ld   LINK_LO, x             ; CALL con_hex8
    ld   st_r43, [x]
    ld   LINK_HI, x
    ld   st_r43 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
st_r43:
    bra  ss_next
ss_none:
    ld   0x2D, ac               ; "--"
    ld   LINK_LO, x             ; CALL con_putc
    ld   st_r44, [x]
    ld   LINK_HI, x
    ld   st_r44 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
st_r44:
    ld   0x2D, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   st_r45, [x]
    ld   LINK_HI, x
    ld   st_r45 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
st_r45:
ss_next:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   st_r46, [x]
    ld   LINK_HI, x
    ld   st_r46 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
st_r46:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   st_r47, [x]
    ld   LINK_HI, x
    ld   st_r47 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
st_r47:
    ld   [t_s], ac
    add  1, ac
    ld   ac, [t_s]
    xor  5, ac
    bne  ss_slot
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; show_kbd - "found" or "none" from KBD_FLAGS bit 1 (t_kbd = that bit)
; ------------------------------------------------------------

#addr 0x0700
show_mouse:
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
    ld   ROW_MOUSE, ac
    ld   LINK_LO, x             ; CALL at_val
    ld   st_r51, [x]
    ld   LINK_HI, x
    ld   st_r51 >> 8, [x]
    ld   at_val >> 8, y
    jmp  at_val
st_r51:
    ld   [MOUSE_ST], ac
    blt  sm_run
    ld   0xF5, ac               ; disable reporting: FA if anything is there
    ld   LINK_LO, x             ; CALL mouse_cmd
    ld   st_r52, [x]
    ld   LINK_HI, x
    ld   st_r52 >> 8, [x]
    ld   mouse_cmd >> 8, y
    jmp  mouse_cmd
st_r52:
    ld   ac, [t_res]
    beq  sm_yes
    xor  1, ac
    beq  sm_none
    ld   s_mwrong & 0xFF, ac
    ld   ac, [R0]
    ld   s_mwrong >> 8, ac
    ld   ac, [R1]
    bra  sm_put
sm_run:
    ld   s_mrun & 0xFF, ac
    ld   ac, [R0]
    ld   s_mrun >> 8, ac
    ld   ac, [R1]
    bra  sm_put
sm_yes:
    ld   s_mfound & 0xFF, ac
    ld   ac, [R0]
    ld   s_mfound >> 8, ac
    ld   ac, [R1]
    bra  sm_put
sm_none:
    ld   s_mnone & 0xFF, ac
    ld   ac, [R0]
    ld   s_mnone >> 8, ac
    ld   ac, [R1]
sm_put:
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r53, [x]
    ld   LINK_HI, x
    ld   st_r53 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r53:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; show_sd - sd_init and fs_mount: "ready, SDHC, FAT mounted" or the error
; ------------------------------------------------------------

#addr 0x0800
show_sd:
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
    ld   ROW_SD, ac
    ld   LINK_LO, x             ; CALL at_val
    ld   st_r54, [x]
    ld   LINK_HI, x
    ld   st_r54 >> 8, [x]
    ld   at_val >> 8, y
    jmp  at_val
st_r54:
    ld   LINK_LO, x             ; CALL sd_init
    ld   st_r55, [x]
    ld   LINK_HI, x
    ld   st_r55 >> 8, [x]
    ld   sd_init >> 8, y
    jmp  sd_init
st_r55:
    ld   ac, [t_res]
    beq  sd_ok
    ld   s_sdbad & 0xFF, ac     ; "sd_init error n"
    ld   ac, [R0]
    ld   s_sdbad >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r56, [x]
    ld   LINK_HI, x
    ld   st_r56 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r56:
    ld   [t_res], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   st_r57, [x]
    ld   LINK_HI, x
    ld   st_r57 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
st_r57:
    ld   lib_leave >> 8, y
    jmp  lib_leave
sd_ok:
    ld   s_sdok & 0xFF, ac
    ld   ac, [R0]
    ld   s_sdok >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r58, [x]
    ld   LINK_HI, x
    ld   st_r58 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r58:
    ld   [SD_FLAGS], ac
    and  1, ac
    beq  sd_sc
    ld   s_sdhc & 0xFF, ac
    ld   ac, [R0]
    ld   s_sdhc >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r59, [x]
    ld   LINK_HI, x
    ld   st_r59 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r59:
sd_sc:
    ld   LINK_LO, x             ; CALL fs_mount
    ld   st_r60, [x]
    ld   LINK_HI, x
    ld   st_r60 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
st_r60:
    ld   ac, [t_res]
    beq  sd_m
    ld   s_fsbad & 0xFF, ac     ; ", fs_mount error n"
    ld   ac, [R0]
    ld   s_fsbad >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r61, [x]
    ld   LINK_HI, x
    ld   st_r61 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r61:
    ld   [t_res], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   st_r62, [x]
    ld   LINK_HI, x
    ld   st_r62 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
st_r62:
    ld   lib_leave >> 8, y
    jmp  lib_leave
sd_m:
    ld   s_fsok & 0xFF, ac
    ld   ac, [R0]
    ld   s_fsok >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   st_r63, [x]
    ld   LINK_HI, x
    ld   st_r63 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
st_r63:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; text
; ============================================================

#addr 0x0900
s_title:  #d "PLACARD SYSTEM TEST", 0x00
s_testing: #d "testing...", 0x00
s_ram:    #d "RAM", 0x00
s_ranges: #d "x0C00-x1EFF x2000-x4CFF x5400-x59FF x5C00-x5CFF x6000-xFFFF", 0x00
s_slots:  #d "Card slots", 0x00
s_kbd:    #d "Keyboard", 0x00
s_mouse:  #d "Mouse", 0x00
s_sd:     #d "SD card", 0x00
s_snd:    #d "Sound", 0x00
s_beeps:  #d "two beeps: A 440 Hz, then A 880 Hz", 0x00
s_keys:   #d "Space: test again   B: beep again   Esc: back", 0x00

#addr 0x0A00
s_ok:     #d "OK, 2 passes", 0x00
s_fail:   #d "FAILED, errors: ", 0x00
s_first:  #d ", first x", 0x00
s_wrote:  #d " wrote ", 0x00
s_read:   #d " read ", 0x00
s_bits:   #d ", bad bits ", 0x00
s_kfound: #d "found", 0x00
s_knone:  #d "none   ", 0x00
s_mrun:   #d "found (running)", 0x00
s_mfound: #d "found", 0x00
s_mnone:  #d "none", 0x00
s_mwrong: #d "wrong answer", 0x00
s_sdok:   #d "ready", 0x00
s_sdhc:   #d ", SDHC", 0x00
s_sdbad:  #d "sd_init error ", 0x00
s_fsok:   #d ", FAT mounted", 0x00
s_fsbad:  #d ", fs_mount error ", 0x00
