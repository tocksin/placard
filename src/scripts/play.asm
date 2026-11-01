; ============================================================
; made by asm_expand.py from play.masm: change that file, then run
;     python3 asm_expand.py play.masm
; ============================================================

; ============================================================
; play.masm - PLAY.PLC: plays DEMO.SNG from the card with the music player
; (placard_mus.masm, docs/MUSIC.md)
; ============================================================
;
; A library program the DOS runs from the card (Enter on PLAY.PLC in the
; browser, or BOOT.CFG = "PLAY.PLC").  It loads DEMO.SNG from the card's
; current folder to x2000 (fs_load), starts subtune 0 and calls mus_frame
; once a frame.  The screen shows the song's title, each voice's note and
; instrument as it plays (the voice's row tinted while it sounds), and
; the keys:
;
;     Space      the song from the start
;     S          stop (every voice releases)
;     1 - 4      a sound effect on the fifth voice (instruments 1-4, C-4),
;                heard in voice 4's place
;     Esc        back to the DOS (menu_poll)
;
; RAM: the program at x0100 (asm_expand.py pages it), the player's tables
; at x2000-x29FF (in the program file), the song at x2A00-x3FFF (5.5 KB at
; most), the player's RAM at x4000-x49FF, zero page x20-x2F and the
; player's x60-x9F.
;
;     python3 asm_expand.py play.masm                 play.asm
;     python3 gen_plc.py play.asm -o ../../sdcard/PLAY.PLC
;     python3 test_play.py                            runs it in placard_sim
;
; Date: 11/01/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

MUS_TABLES = 0x2000         ; the player's tables, 10 pages
SONG       = 0x2A00         ; DEMO.SNG is loaded here
MUS_RAM    = 0x4000         ; the player's RAM, 10 pages

p_v     = 0x20              ; voice being shown
p_n     = 0x21              ; its note
p_oct   = 0x22              ; its octave
p_t     = 0x23              ; scratch
p_k     = 0x24              ; characters left
p_ins   = 0x25              ; instrument
p_est   = 0x26              ; envelope state (3 = released)

TITLE_TINT = 0x30           ; the title rows: gold
VOICE_ROW  = 6              ; text row of voice 1 (then every other row)
VOICE_COL  = 12
FILE_ROW   = 16


; ============================================================
; main
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL con_clear
    ld   pl_r1, [x]
    ld   LINK_HI, x
    ld   pl_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
pl_r1:
    ld   0x5A, y                ; the title band (screen rows 0-15)
    ld   15, ac
mn_tb:
    add  0x20, x
    ld   TITLE_TINT, [y,x]
    sub  1, ac
    bcc  mn_tb
    ld   2, ac
    ld   ac, [CUR_COL]
    clr  ac
    ld   ac, [CUR_ROW]
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   pl_r2, [x]
    ld   LINK_HI, x
    ld   pl_r2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
pl_r2:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   s_keys & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   pl_r3, [x]
    ld   LINK_HI, x
    ld   pl_r3 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
pl_r3:
    ld   LINK_LO, x             ; CALL fs_mount
    ld   pl_r4, [x]
    ld   LINK_HI, x
    ld   pl_r4 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
pl_r4:
    ld   s_file & 0xFF, ac      ; DEMO.SNG -> x2000
    ld   ac, [R0]
    ld   s_file >> 8, ac
    ld   ac, [R1]
    ld   SONG & 0xFF, ac
    ld   ac, [R4]
    ld   SONG >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_load
    ld   pl_r5, [x]
    ld   LINK_HI, x
    ld   pl_r5 >> 8, [x]
    ld   fs_load >> 8, y
    jmp  fs_load
pl_r5:
    beq  mn_ok
    ld   no_file >> 8, y
    jmp  no_file
mn_ok:
    ld   SONG >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL mus_init
    ld   pl_r6, [x]
    ld   LINK_HI, x
    ld   pl_r6 >> 8, [x]
    ld   mus_init >> 8, y
    jmp  mus_init
pl_r6:
    clr  ac
    ld   LINK_LO, x             ; CALL mus_play
    ld   pl_r7, [x]
    ld   LINK_HI, x
    ld   pl_r7 >> 8, [x]
    ld   mus_play >> 8, y
    jmp  mus_play
pl_r7:
    ld   show_song >> 8, y
    jmp  show_song

; ------------------------------------------------------------
; no_file - DEMO.SNG is not on the card: say so, wait for Esc
; ------------------------------------------------------------
no_file:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   FILE_ROW, ac
    ld   ac, [CUR_ROW]
    ld   s_nofile & 0xFF, ac
    ld   ac, [R0]
    ld   s_nofile >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   pl_r8, [x]
    ld   LINK_HI, x
    ld   pl_r8 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
pl_r8:
nf_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   pl_r9, [x]
    ld   LINK_HI, x
    ld   pl_r9 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
pl_r9:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   pl_r10, [x]
    ld   LINK_HI, x
    ld   pl_r10 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
pl_r10:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   pl_r11, [x]
    ld   LINK_HI, x
    ld   pl_r11 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
pl_r11:
    bra  nf_loop

; ------------------------------------------------------------
; show_song - the title from the song (32 characters), the voice labels
; ------------------------------------------------------------
mt_voice:
    ld   [M_VIDX], ac
    xor  4, ac
    bne  mv_in
    ld   [M_SFXN], ac
    bne  mv_in
    ld   mt_end >> 8, y
    jmp  mt_end
mv_in:
    ld   copy_in >> 8, y
    jmp  copy_in


#addr 0x0200
show_song:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   32, ac
    ld   ac, [p_k]
    ld   0x20, ac
    ld   ac, [p_t]
ss_ch:
    ld   [p_t], x
    ld   SONG >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r12, [x]
    ld   LINK_HI, x
    ld   pl_r12 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r12:
    ld   [p_t], ac
    inc
    ld   ac, [p_t]
    ld   [p_k], ac
    dec
    ld   ac, [p_k]
    bne  ss_ch
    clr  ac
    ld   ac, [p_v]
ss_v:
    ld   [p_v], ac              ; "Voice n" on row VOICE_ROW + 2n
    add  [p_v], ac
    add  VOICE_ROW, ac
    ld   ac, [CUR_ROW]
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   s_voice & 0xFF, ac
    ld   ac, [R0]
    ld   s_voice >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   pl_r13, [x]
    ld   LINK_HI, x
    ld   pl_r13 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
pl_r13:
    ld   [p_v], ac
    add  0x31, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r14, [x]
    ld   LINK_HI, x
    ld   pl_r14 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r14:
    ld   [p_v], ac
    inc
    ld   ac, [p_v]
    xor  4, ac
    bne  ss_v
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the frame loop: the player, the keys, the voices
; ============================================================
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   pl_r15, [x]
    ld   LINK_HI, x
    ld   pl_r15 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
pl_r15:
    ld   LINK_LO, x             ; CALL mus_frame
    ld   pl_r16, [x]
    ld   LINK_HI, x
    ld   pl_r16 >> 8, [x]
    ld   mus_frame >> 8, y
    jmp  mus_frame
pl_r16:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   pl_r17, [x]
    ld   LINK_HI, x
    ld   pl_r17 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
pl_r17:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   pl_r18, [x]
    ld   LINK_HI, x
    ld   pl_r18 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
pl_r18:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   pl_r19, [x]
    ld   LINK_HI, x
    ld   pl_r19 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
pl_r19:
    beq  lp_show
    ld   ac, [p_t]
    xor  0x20, ac               ; Space: from the start
    bne  lp_k1
    clr  ac
    ld   LINK_LO, x             ; CALL mus_play
    ld   pl_r20, [x]
    ld   LINK_HI, x
    ld   pl_r20 >> 8, [x]
    ld   mus_play >> 8, y
    jmp  mus_play
pl_r20:
    bra  lp_show
lp_k1:
    ld   [p_t], ac
    xor  0x73, ac               ; S: stop
    bne  lp_k2
    ld   LINK_LO, x             ; CALL mus_stop
    ld   pl_r21, [x]
    ld   LINK_HI, x
    ld   pl_r21 >> 8, [x]
    ld   mus_stop >> 8, y
    jmp  mus_stop
pl_r21:
    bra  lp_show
lp_k2:
    ld   [p_t], ac              ; 1-4: a sound effect, instrument 1-4
    sub  0x31, ac
    blt  lp_show
    sub  4, ac
    bcc  lp_show
    add  5, ac
    ld   ac, [R0]
    ld   12, ac
    ld   ac, [R1]
    ld   48, ac
    ld   LINK_LO, x             ; CALL mus_sfx
    ld   pl_r22, [x]
    ld   LINK_HI, x
    ld   pl_r22 >> 8, [x]
    ld   mus_sfx >> 8, y
    jmp  mus_sfx
pl_r22:
lp_show:
    clr  ac
    ld   ac, [p_v]
    ld   show_voice >> 8, y
    jmp  show_voice

; ------------------------------------------------------------
; show_voice - voice p_v's note, instrument number and name; its row
; tinted while the voice sounds.  Voice 4 shows the sound effect voice
; while one plays.
; ------------------------------------------------------------
show_voice:
    ld   [p_v], ac
    xor  3, ac
    bne  sv_a
    ld   [M_SFXN], ac
    beq  sv_a
    ld   4, ac                  ; the sfx voice's page
    bra  sv_b
sv_a:
    ld   [p_v], ac
sv_b:
    add  MUS_VS >> 8, y
    ld   W_NOTE, x
    ld   [y,x], ac
    ld   ac, [p_n]
    ld   W_INS, x
    ld   [y,x], ac
    ld   ac, [p_ins]
    ld   W_EST, x
    ld   [y,x], ac
    ld   ac, [p_est]
    ld   [p_v], ac              ; the row's tint: mode bytes x5A20 + 8 x row
    add  [p_v], ac
    add  VOICE_ROW, ac
    ld   ac, [CUR_ROW]
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [p_t]
    ld   [p_v], ac              ; red, green, blue, gold
    add  tints & 0xFF, x
    ld   tints >> 8, y
    ld   [y,x], ac
    ld   ac, [p_k]
    ld   [p_est], ac
    xor  3, ac
    bne  sv_on
    clr  ac                     ; released: no tint
    ld   ac, [p_k]
sv_on:
    ld   0x5A, y
    ld   8, ac
    ld   ac, [p_oct]
sv_tint:
    ld   [p_t], x
    ld   [p_k], ac
    ld   ac, [y,x]
    ld   [p_t], ac
    inc
    ld   ac, [p_t]
    ld   [p_oct], ac
    dec
    ld   ac, [p_oct]
    bne  sv_tint
    ld   VOICE_COL, ac
    ld   ac, [CUR_COL]
    ld   show_note >> 8, y
    jmp  show_note

; the note name (C-4), or --- when the voice is released
show_note:
    ld   [p_est], ac
    xor  3, ac
    bne  sn_name
    ld   s_off & 0xFF, ac
    ld   ac, [R0]
    ld   s_off >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   pl_r23, [x]
    ld   LINK_HI, x
    ld   pl_r23 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
pl_r23:
    ld   show_ins >> 8, y
    jmp  show_ins
sn_name:
    clr  ac
    ld   ac, [p_oct]
sn_oct:
    ld   [p_n], ac              ; octave = note / 12
    sub  12, ac
    bcs  sn_done
    ld   ac, [p_n]
    ld   [p_oct], ac
    inc
    ld   ac, [p_oct]
    bra  sn_oct
sn_done:
    ld   [p_n], ac
    add  [p_n], ac
    add  notes & 0xFF, x
    ld   notes >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r24, [x]
    ld   LINK_HI, x
    ld   pl_r24 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r24:
    ld   [p_n], ac
    add  [p_n], ac
    add  (notes + 1) & 0xFF, x
    ld   notes >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r25, [x]
    ld   LINK_HI, x
    ld   pl_r25 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r25:
    ld   [p_oct], ac
    add  0x30, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r26, [x]
    ld   LINK_HI, x
    ld   pl_r26 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r26:
    ld   show_ins >> 8, y
    jmp  show_ins

; the instrument: number (hex) and name (7 characters, at +9 in its
; 16 bytes: page 2 of the song holds 0-15, page 3 16-31)
mf_addr:
    ld   [M_RPTR], ac           ; T2:T1 = the address of group RPTR
    xor  0x7C, ac
    bne  mf_s1
    ld   0xF3, ac
    ld   ac, [T1]
    ld   0x5D, ac
    bra  mf_s3
mf_s1:
    ld   [M_RPTR], ac
    shl
    shl
    ld   ac, [T1]
    ld   [M_RPTR], ac
    blt  mf_s2
    ld   0x5D, ac
    bra  mf_s3
mf_s2:
    and  0x40, ac
    beq  mf_s4
    ld   0x5F, ac
    bra  mf_s3
mf_s4:
    ld   0x5E, ac
mf_s3:
    ld   ac, [T2]
    ld   mus_gen >> 8, y
    jmp  mus_gen


#addr 0x0400
show_ins:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r27, [x]
    ld   LINK_HI, x
    ld   pl_r27 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r27:
    ld   [p_ins], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   pl_r28, [x]
    ld   LINK_HI, x
    ld   pl_r28 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
pl_r28:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r29, [x]
    ld   LINK_HI, x
    ld   pl_r29 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r29:
    ld   [p_ins], ac
    and  15, ac
    shl
    shl
    shl
    shl
    add  9, ac
    ld   ac, [p_t]
    ld   7, ac
    ld   ac, [p_k]
si_ch:
    ld   [p_ins], ac
    and  16, ac
    beq  si_p2
    ld   (SONG >> 8) + 3, y
    bra  si_rd
si_p2:
    ld   (SONG >> 8) + 2, y
si_rd:
    ld   [p_t], x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   pl_r30, [x]
    ld   LINK_HI, x
    ld   pl_r30 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pl_r30:
    ld   [p_t], ac
    inc
    ld   ac, [p_t]
    ld   [p_k], ac
    dec
    ld   ac, [p_k]
    bne  si_ch
    ld   [p_v], ac
    inc
    ld   ac, [p_v]
    xor  4, ac
    beq  si_end
    ld   show_voice >> 8, y
    jmp  show_voice
si_end:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; data
; ============================================================
mus_frame:
    ld   [M_PLAY], ac
    blt  mf_go
    ld   [LINK_HI], y
    jmp  [LINK_LO]
mf_go:
    ld   0x50, y
    ld   [y,x], ac
    ld   ac, [T6]               ; r = the line read now
    sub  [M_REND], ac           ; d = (r - REND) mod 132: groups read since
    bcc  mf_a
    add  132, ac
mf_a:
    ld   ac, [T7]
    ld   [T6], ac
    ld   ac, [M_REND]
    ld   [M_AHEAD], ac
    sub  [T7], ac
    bcc  mf_b
    ld   [T6], ac               ; the video passed the write pointer: go on
    ld   ac, [M_RPTR]           ; from where it is now
    clr  ac
mf_b:
    ld   ac, [M_AHEAD]
mf_fill:
    ld   131, ac
    sub  [M_AHEAD], ac
    bne  mf_c
    ld   [LINK_HI], y
    jmp  [LINK_LO]
mf_c:
    ld   ac, [T5]               ; groups to write
    ld   131, ac
    ld   ac, [M_AHEAD]
    ld   mf_addr >> 8, y
    jmp  mf_addr

mf_end:
    ld   0x50, y
    ld   [y,x], ac
    ld   ac, [T6]               ; the video moved during the fill?
    sub  [M_REND], ac
    bcc  me_a
    add  132, ac
me_a:
    bne  me_b
    ld   [LINK_HI], y
    jmp  [LINK_LO]
me_b:
    ld   ac, [T7]
    ld   [T6], ac
    ld   ac, [M_REND]
    ld   [M_AHEAD], ac
    sub  [T7], ac
    ld   ac, [M_AHEAD]
    ld   mf_fill >> 8, y
    jmp  mf_fill

; ============================================================
; the tick: once a lap, between the samples for x5DF3 and x5DF4
; ============================================================
mus_tick:
    ld   MUS_VS >> 8, y
    ld   G_T5, x
    ld   [T5], ac
    ld   ac, [y,x]
    ld   G_NR, x
    ld   0, [y,x]
    ld   [M_PLAY], ac
    and  1, ac
    beq  mt_0
    ld   [M_TICK], ac
    bne  mt_0
    ld   1, [y,x]               ; a new row
mt_0:
    clr  ac
    ld   ac, [M_VIDX]
    ld   mt_voice >> 8, y
    jmp  mt_voice

rr_stop:
    ld   1, ac
    ld   ac, [W_STOP]
    ld   3, ac
    ld   ac, [W_EST]
    ld   vt >> 8, y
    jmp  vt

; ------------------------------------------------------------
; rr_note - the row's note byte (T7) with its instrument and effect
; ------------------------------------------------------------

#addr 0x0500
s_title:
    #d "PLACARD MUSIC PLAYER", 0x00
s_keys:
    #d "Space: play   S: stop   1-4: sound effects   Esc: exit", 0x00
s_file:
    #d "DEMO.SNG", 0x00
s_nofile:
    #d "DEMO.SNG is not on the card", 0x00
s_voice:
    #d "Voice ", 0x00
s_off:
    #d "---", 0x00
notes:
    #d "C-C#D-D#E-F-F#G-G#A-A#B-"
tints:
    #d8 0x10, 0x20, 0x40, 0x30

; ============================================================
; placard_mus.masm - PLACARD music player: 4 SID-like voices + a sound
; effect voice, patterns, instruments, effects (docs/MUSIC.md)
; ============================================================
;
; A program includes this file in its own .masm, after defining where the
; player's tables and RAM go (both page aligned):
;
;     MUS_TABLES = 0x3400       ; 10 pages of tables (in the program image)
;     MUS_RAM    = 0x4000       ; 10 pages of RAM (not in the image)
;     .include "placard_mus.masm"
;
; and calls (the library's CALL convention, docs/LIBRARY.md):
;
;     mus_init    R1 = the song's page (a .SNG file loaded at R1:00)
;     mus_play    AC = subtune
;     mus_frame   once a frame (or more often): fills the audio buffer
;     mus_stop    every voice releases; the song stops
;     mus_sfx     AC = note (0-95), R0 = instrument, R1 = frames: a sound
;                 effect on the fifth voice, heard in voice 4's place
;
; mus_frame replaces snd_update: a program uses one or the other.  It must
; be called at least once a frame; it writes the buffer behind the player
; (docs/SOUND.md), working out from the line read how much was played,
; and plays the song's ticks as it passes the start of the buffer, so the
; tempo does not depend on how often it is called.
;
; The player runs from RAM: the mixer's step, wave page and volume are
; operands of its own instructions (mv0_sl ... mv3_vp), which the tick
; rewrites.  It reads the song (in RAM or ROM) with sections 0-2 as the
; program has them.
;
; Memory:  zero page x60-x9F, T0-T7.  MUS_TABLES: SAW, TRI, NOISE (2),
; VOLT (4), VMUL, TAB (mus_tables.masm, made by mus_tool.py).  MUS_RAM:
; pages 0-4 the voices' own wave pages (pulse, custom), pages 5-9 the
; voices' state at x76-x9F (the same offsets as the zero page work block
; W, so a copy is ld k, x / ld [y,x], ac / ld ac, [x]); the rest of pages
; 5-9 is free for the program.
;
; mus_tool.py has the reference model (Model): test_mus.py checks this
; player against it sample for sample.  Change one, change the other.
;
; Date: 11/01/2026
; ============================================================

MUS_SAW    = MUS_TABLES
MUS_TRI    = MUS_TABLES + 0x100
MUS_NOISE  = MUS_TABLES + 0x200       ; two pages
MUS_VOLT   = MUS_TABLES + 0x400       ; four pages
MUS_VMUL   = MUS_TABLES + 0x800
MUS_TAB    = MUS_TABLES + 0x900       ; notes, attack and decay rates
MUS_PG     = MUS_RAM                  ; own wave pages, voices 0-4
MUS_VS     = MUS_RAM + 0x500          ; voice state pages, voices 0-4

; zero page
P0L = 0x60
P0H = 0x61
P1L = 0x62
P1H = 0x63
P2L = 0x64
P2H = 0x65
P3L = 0x66
P3H = 0x67
M_SPEED  = 0x68         ; frames per row
M_TICK   = 0x69         ; frame within the row
M_MASTER = 0x6A         ; master volume 0-15
M_RNG    = 0x6B         ; noise generator
M_PLAY   = 0x6C         ; bit 7 = initialised, bit 0 = a song is playing
M_RPTR   = 0x6D         ; line read (V/4) of the next group to write
M_REND   = 0x6E         ; line read at the end of the last fill
M_AHEAD  = 0x6F         ; groups written ahead of the video (0-131)
M_SONG   = 0x70         ; the song's page
M_VIDX   = 0x71         ; voice being ticked
M_SLOT   = 0x72         ; its mixer slot, FF = not heard
M_SFXN   = 0x73         ; sound effect frames left
M_T0     = 0x74
M_T1     = 0x75
W_OLL    = 0x76
W_OLH    = 0x77
W_OSL    = 0x78
W_OSH    = 0x79
W_PPL    = 0x7A
W_PPH    = 0x7B
W_TRANS  = 0x7C
W_EMPTY  = 0x7D
W_NOTE   = 0x7E
W_INS    = 0x7F
W_STL    = 0x80
W_STH    = 0x81
W_FX     = 0x82
W_FXP    = 0x83
W_ENL    = 0x84
W_ENH    = 0x85
W_EST    = 0x86
W_AD     = 0x87
W_SR     = 0x88
W_WPTR   = 0x89
W_WNOTE  = 0x8A
W_PPTR   = 0x8B
W_PCNT   = 0x8C
W_PSPD   = 0x8D
W_PW     = 0x8E
W_WAVE   = 0x8F
W_PAGEK  = 0x90
W_PAGEW  = 0x91
W_VIB    = 0x92
W_VDLY   = 0x93
W_VCNT   = 0x94
W_VDIR   = 0x95
W_VHALF  = 0x96
W_VOFL   = 0x97
W_VOFH   = 0x98
W_TGL    = 0x99
W_TGH    = 0x9A
W_VOL    = 0x9B
W_ARPI   = 0x9C
W_FLAGS  = 0x9D
W_STOP   = 0x9E
W_RET    = 0x9F
W_WPG    = W_RET      ; shared: RET only during a trigger

; globals in MUS_VS page 0 (below the state)
G_T5  = 0x00
G_NR  = 0x03

; mus_tables.masm - the music player's tables (placard_mus.masm),
; made by "python3 mus_tool.py tables": do not edit, change mus_tool.py
;
; ten pages from MUS_TABLES: SAW, TRI, NOISE (2 pages), VOLT (4 pages,
; volume L 0-15 x sample 0-63 at page L>>2, (L&3)*64+w), VMUL (a*b/15),
; TAB: note steps (low bytes x00-x5F, high x60-xBF) and the envelope rates
; per ADSR value (attack low xC0, high xD0; decay/release low xE0, high xF0).
;
; Date: 11/01/2026

mt_out:
    ld   copy_out >> 8, y
    jmp  copy_out
mt_next:
    ld   [M_VIDX], ac
    inc
    ld   ac, [M_VIDX]
    xor  5, ac
    beq  mt_n1
    ld   mt_voice >> 8, y
    jmp  mt_voice
mt_n1:
    ld   mt_end >> 8, y
    jmp  mt_end

mv_row:
    ld   [M_VIDX], ac
    xor  4, ac
    beq  mr_no
    ld   MUS_VS >> 8, y
    ld   G_NR, x
    ld   [y,x], ac
    beq  mr_no
    ld   [W_STOP], ac
    bne  mr_no
    ld   rr >> 8, y
    jmp  rr
mr_no:
    ld   vt >> 8, y
    jmp  vt

; ------------------------------------------------------------
; rr - read the voice's next row
;   T0 = instrument (FF none), T1:T2 = effect, parameter, T6 = ends seen,
;   T7 = the byte
; ------------------------------------------------------------
ve_rel:
    ld   [W_SR], ac
    and  15, ac
    ld   ac, [T0]
    ld   MUS_TAB >> 8, y
    add  0xF0, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [T0], ac
    add  0xE0, x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   [W_ENL], ac
    sub  [T2], ac
    ld   ac, [T2]
    ld   [W_ENH], ac
    bcc  vr_b
    sub  1, ac
    bcs  vr_0
vr_b:
    sub  [T1], ac
    bcs  vr_0
    ld   ac, [W_ENH]
    ld   [T2], ac
    ld   ac, [W_ENL]
    ld   vslot >> 8, y
    jmp  vslot
vr_0:
    clr  ac
    ld   ac, [W_ENH]
    ld   ac, [W_ENL]
    ld   vslot >> 8, y
    jmp  vslot

; ------------------------------------------------------------
; vslot - which mixer slot hears this voice (M_SLOT, FF none) and its wave
; page (W_WPG): pulse and custom pages are rebuilt here, noise picks a
; random page and phase
; ------------------------------------------------------------
mus_gen:
mg_loop:
    ld   [P0L], ac
mv0_sl:
    add  0x00, ac
    ld   ac, [P0L]
    ld   [P0H], ac
    bcc  mv0_n
    inc
mv0_n:
mv0_sh:
    add  0x00, ac
    ld   ac, [P0H]
    ld   ac, x
mv0_wp:
    ld   0x00, y
    ld   [y,x], ac
mv0_vo:
    add  0x00, x
mv0_vp:
    ld   0x00, y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [P1L], ac
mv1_sl:
    add  0x00, ac
    ld   ac, [P1L]
    ld   [P1H], ac
    bcc  mv1_n
    inc
mv1_n:
mv1_sh:
    add  0x00, ac
    ld   ac, [P1H]
    ld   ac, x
mv1_wp:
    ld   0x00, y
    ld   [y,x], ac
mv1_vo:
    add  0x00, x
mv1_vp:
    ld   0x00, y
    ld   [T0], ac
    add  [y,x], ac
    ld   ac, [T0]
    ld   [P2L], ac
mv2_sl:
    add  0x00, ac
    ld   ac, [P2L]
    ld   [P2H], ac
    bcc  mv2_n
    inc
mv2_n:
mv2_sh:
    add  0x00, ac
    ld   ac, [P2H]
    ld   ac, x
mv2_wp:
    ld   0x00, y
    ld   [y,x], ac
mv2_vo:
    add  0x00, x
mv2_vp:
    ld   0x00, y
    ld   [T0], ac
    add  [y,x], ac
    ld   ac, [T0]
    ld   [P3L], ac
mv3_sl:
    add  0x00, ac
    ld   ac, [P3L]
    ld   [P3H], ac
    bcc  mv3_n
    inc
mv3_n:
mv3_sh:
    add  0x00, ac
    ld   ac, [P3H]
    ld   ac, x
mv3_wp:
    ld   0x00, y
    ld   [y,x], ac
mv3_vo:
    add  0x00, x
mv3_vp:
    ld   0x00, y
    ld   [T0], ac
    add  [y,x], ac
    ld   ac, [T0]
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   [T1], ac
    add  1, x
    xor  0xF3, ac
    beq  mg_one
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T1], ac
    add  2, ac
    ld   ac, [T1]
    beq  mg_page
    and  3, ac
    bne  mg_loop
mg_grp:                         ; a group done
    ld   [M_RPTR], ac
    inc
    ld   ac, [M_RPTR]
    bne  mg_g1
    ld   0x7C, ac
    ld   ac, [M_RPTR]
mg_g1:
    ld   [T5], ac
    dec
    ld   ac, [T5]
    bne  mg_loop
    ld   mf_end >> 8, y
    jmp  mf_end
mg_page:
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  0x60, ac
    bne  mg_grp
    ld   0x5D, ac
    ld   ac, [T2]
    ld   0xF3, ac
    ld   ac, [T1]
    bra  mg_grp
mg_one:
    ld   mus_tick >> 8, y
    jmp  mus_tick

; ------------------------------------------------------------
; mus_frame - fill the buffer ahead of the video (and play the ticks)
;   in: -   out: -   changes: AC, X, Y, T0-T7
;
; The buffer is a ring of 132 groups (the line read counts them).  The
; player keeps M_AHEAD groups written ahead of the one the video is
; reading, up to 131, and never writes the one being read.  Each call
; takes off the groups the video read since the last fill, writes up to
; 131 ahead again, and repeats while the video moved during the fill.
; A call more than 131 groups (a lap less a group) after the last one
; loses the samples in between (the video replays the old ones), so a
; program calls at least once a frame.  The tick (at group x7C) takes a
; few groups' time; if the video passes the write pointer meanwhile the
; groups it passed are skipped, so the rest stays in time.  mus_init
; fills the buffer once (131 groups of silence) so the song's first tick
; starts well ahead of the video.
; ------------------------------------------------------------
vz_3:
    ld   (mv3_sl + 1) >> 8, y
    ld   (mv3_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv3_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv3_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv3_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv3_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   mt_out >> 8, y
    jmp  mt_out

; ------------------------------------------------------------
; mus_init - start the player: R1 = the song's page; all voices quiet
;   changes: AC, X, Y, T0-T7
; ------------------------------------------------------------
ms_3:
    ld   (mv3_sl + 1) >> 8, y
    ld   (mv3_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv3_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv3_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv3_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv3_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   ms_back >> 8, y
    jmp  ms_back


#addr 0x0700
mt_end:
    ld   [M_PLAY], ac
    and  1, ac
    beq  me_s
    ld   [M_TICK], ac
    inc
    ld   ac, [M_TICK]
    sub  [M_SPEED], ac
    bcs  me_s
    clr  ac
    ld   ac, [M_TICK]
me_s:
    ld   [M_SFXN], ac
    beq  me_r
    dec
    ld   ac, [M_SFXN]
me_r:
    ld   MUS_VS >> 8, y
    ld   G_T5, x
    ld   [y,x], ac
    ld   ac, [T5]
    ld   0x50, y                ; did the video pass the write pointer
    ld   [y,x], ac              ; during the tick?
    sub  [M_REND], ac
    bcc  mr_1
    add  132, ac
mr_1:
    add  [T5], ac               ; groups read since the fill began + left
    sub  133, ac                ; (written + left = 131): over by b - 1
    bcs  mr_ok
    ld   ac, [T6]
    inc
    ld   ac, [T6]               ; b groups behind: skip them
    add  0x7D, ac
    ld   ac, [M_RPTR]
    ld   [T5], ac
    sub  [T6], ac
    beq  mr_end
    bcs  mr_end
    dec                         ; and group x7C is done
    beq  mr_end
    ld   ac, [T5]
    ld   mf_addr >> 8, y
    jmp  mf_addr
mr_end:
    ld   mf_end >> 8, y
    jmp  mf_end
mr_ok:
    ld   0x5D, ac
    ld   ac, [T2]
    ld   0xF4, ac
    ld   ac, [T1]
    ld   mg_grp >> 8, y
    jmp  mg_grp

copy_in:
    ld   [M_VIDX], ac
    add  MUS_VS >> 8, y
    ld   0x76, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x77, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x78, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x79, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7A, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7B, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7C, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7D, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7E, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7F, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x80, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x81, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x82, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x83, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x84, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x85, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x86, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x87, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x88, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x89, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8A, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8B, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   copy_in2 >> 8, y
    jmp  copy_in2
ms_back:
    ld   [M_T1], ac
    bne  mb_p
    ld   mi_s2 >> 8, y
    jmp  mi_s2
mb_p:
    ld   mp_s2 >> 8, y
    jmp  mp_s2

; ------------------------------------------------------------
; mus_play - start subtune AC from its beginning
;   changes: AC, X, Y, T0-T7
; ------------------------------------------------------------
mus_stop:
    ld   0x80, ac
    ld   ac, [M_PLAY]
    ld   W_EST, x
    ld   MUS_VS >> 8, y
    ld   3, [y,x]
    ld   (MUS_VS >> 8) + 1, y
    ld   3, [y,x]
    ld   (MUS_VS >> 8) + 2, y
    ld   3, [y,x]
    ld   (MUS_VS >> 8) + 3, y
    ld   3, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; mus_sfx - AC = note 0-95, R0 = instrument, R1 = frames: a sound effect
; on voice 4, heard in voice 3's place (mixer slot 3) for R1 frames
;   changes: AC, X, Y, T0-T7
; ------------------------------------------------------------
mus_sfx:
    ld   ac, [T7]
    sub  96, ac
    bcs  sx_a
    ld   95, ac
    ld   ac, [T7]
sx_a:
    ld   [R1], ac
    ld   ac, [M_SFXN]
    ld   sfx_in >> 8, y
    jmp  sfx_in

#addr 0x0800
copy_in2:
    ld   [M_VIDX], ac
    add  MUS_VS >> 8, y
    ld   0x8C, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8D, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8E, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8F, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x90, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x91, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x92, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x93, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x94, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x95, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x96, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x97, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x98, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x99, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9A, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9B, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9C, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9D, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9E, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9F, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   mv_row >> 8, y
    jmp  mv_row
copy_out:
    ld   [M_VIDX], ac
    add  MUS_VS >> 8, y
    ld   0x76, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x77, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x78, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x79, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x80, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x81, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x82, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x83, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x84, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x85, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x86, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x87, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x88, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x89, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   copy_out2 >> 8, y
    jmp  copy_out2
ve_att:
    ld   [W_AD], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T0]
    ld   MUS_TAB >> 8, y
    add  0xD0, x
    ld   [y,x], ac
    ld   ac, [T1]               ; rate high
    ld   [T0], ac
    add  0xC0, x
    ld   [y,x], ac
    add  [W_ENL], ac
    ld   ac, [T2]
    ld   [T1], ac
    bcc  va_a
    inc
    beq  va_full
va_a:
    add  [W_ENH], ac
    bcs  va_full
    ld   ac, [T1]
    xor  0xFF, ac
    beq  va_full
    ld   [T1], ac
    ld   ac, [W_ENH]
    ld   [T2], ac
    ld   ac, [W_ENL]
    ld   vslot >> 8, y
    jmp  vslot
va_full:
    ld   0xFF, ac
    ld   ac, [W_ENH]
    clr  ac
    ld   ac, [W_ENL]
    ld   1, ac
    ld   ac, [W_EST]
    ld   vslot >> 8, y
    jmp  vslot


#addr 0x0900
copy_out2:
    ld   [M_VIDX], ac
    add  MUS_VS >> 8, y
    ld   0x8C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x90, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x91, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x92, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x93, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x94, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x95, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x96, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x97, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x98, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x99, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   mt_next >> 8, y
    jmp  mt_next

; ------------------------------------------------------------
; a new row?  (voices 0-3, on the first frame of a row, if not stopped)
; ------------------------------------------------------------
rr:
    ld   [W_EMPTY], ac
    beq  rr_go
    dec
    ld   ac, [W_EMPTY]
rr_clear:
    clr  ac
    ld   ac, [W_FX]
    ld   ac, [W_FXP]
    ld   ac, [W_ARPI]
    ld   vt >> 8, y
    jmp  vt
rr_go:
    ld   0xFF, ac
    ld   ac, [T0]
    clr  ac
    ld   ac, [T1]
    ld   ac, [T2]
    ld   ac, [T6]
rr_lp:
    ld   [W_PPH], ac
    beq  rr_end
    ld   [W_PPH], y
    ld   [W_PPL], x
    ld   [y,x], ac
    ld   ac, [T7]
    ld   [W_PPL], ac
    inc
    ld   ac, [W_PPL]
    bne  rr_n
    ld   [W_PPH], ac
    inc
    ld   ac, [W_PPH]
rr_n:
    ld   [T7], ac
    xor  0xFF, ac
    beq  rr_end
    ld   [T7], ac
    sub  0xE0, ac
    bcc  rr_fx
    ld   [T7], ac
    sub  0xC0, ac
    bcc  rr_ins
    ld   [T7], ac
    sub  0x80, ac
    bcc  rr_empty
    ld   rr_note >> 8, y
    jmp  rr_note
rr_fx:
    ld   ac, [T1]
    ld   [W_PPH], y
    ld   [W_PPL], x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   [W_PPL], ac
    inc
    ld   ac, [W_PPL]
    bne  rr_lp
    ld   [W_PPH], ac
    inc
    ld   ac, [W_PPH]
    bra  rr_lp
rr_ins:
    and  0x1F, ac
    ld   ac, [T0]
    bra  rr_lp
rr_empty:
    and  0x3F, ac
    ld   ac, [W_EMPTY]
    bra  rr_clear
rr_end:
    ld   [T6], ac
    inc
    ld   ac, [T6]
    sub  3, ac
    bcc  rr_s
    ld   np >> 8, y
    jmp  np
rr_s:
    ld   rr_stop >> 8, y
    jmp  rr_stop

; ------------------------------------------------------------
; np - the orderlist: the next pattern (M_T0 counts the bytes read)
; ------------------------------------------------------------

#addr 0x0A00
np:
    ld   64, ac
    ld   ac, [M_T0]
np_lp:
    ld   [W_OLH], y
    ld   [W_OLL], x
    ld   [y,x], ac
    ld   ac, [T7]
    ld   [W_OLL], ac
    inc
    ld   ac, [W_OLL]
    bne  np_a
    ld   [W_OLH], ac
    inc
    ld   ac, [W_OLH]
np_a:
    ld   [T7], ac
    xor  0xFE, ac
    beq  np_stop
    ld   [T7], ac
    xor  0xFF, ac
    beq  np_loop
    ld   [T7], ac
    blt  np_hi
np_pat:
    ld   [T7], ac
    and  0x3F, ac
    add  0x80, x
    ld   [M_SONG], y
    ld   [y,x], ac
    ld   ac, [W_PPL]
    ld   [T7], ac
    and  0x3F, ac
    add  0xC0, x
    ld   [y,x], ac
    add  [M_SONG], ac
    ld   ac, [W_PPH]
    ld   rr_lp >> 8, y
    jmp  rr_lp
np_hi:
    sub  0xC0, ac
    bcc  np_pat
    ld   [T7], ac
    sub  0xA0, ac
    ld   ac, [W_TRANS]
    bra  np_next
np_loop:
    ld   [W_OLH], y
    ld   [W_OLL], x
    ld   [y,x], ac
    add  [W_OSL], ac
    ld   ac, [W_OLL]
    ld   [W_OSH], ac
    bcc  np_l1
    inc
np_l1:
    ld   ac, [W_OLH]
np_next:
    ld   [M_T0], ac
    dec
    ld   ac, [M_T0]
    bne  np_lp
    ld   rr_stop >> 8, y
    jmp  rr_stop
np_stop:
    ld   [W_OLL], ac            ; back onto the FE
    bne  np_s1
    ld   [W_OLH], ac
    dec
    ld   ac, [W_OLH]
np_s1:
    ld   [W_OLL], ac
    dec
    ld   ac, [W_OLL]
    ld   rr_stop >> 8, y
    jmp  rr_stop

rr_note:
    ld   [T1], ac
    ld   ac, [W_FX]
    ld   [T2], ac
    ld   ac, [W_FXP]
    clr  ac
    ld   ac, [W_ARPI]
    ld   [T0], ac
    blt  rn_a
    ld   ac, [W_INS]
rn_a:
    ld   [T7], ac
    xor  0x60, ac
    bne  rn_b
    ld   3, ac                  ; key off
    ld   ac, [W_EST]
    bra  rn_fx
rn_b:
    ld   [T7], ac
    sub  0x60, ac
    bcc  rn_fx                  ; 61-7F: no note
    ld   [T7], ac
    add  [W_TRANS], ac
    ld   ac, [T7]
    blt  rn_lo
    sub  96, ac
    bcs  rn_ok
    ld   95, ac
    ld   ac, [T7]
    bra  rn_ok
rn_lo:
    clr  ac
    ld   ac, [T7]
rn_ok:
    ld   [W_FX], ac
    xor  3, ac
    bne  rn_trig
    ld   [T7], ac               ; portamento: a new target, no new note
    ld   ac, [W_NOTE]
    ld   ac, x
    ld   MUS_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [W_TGL]
    ld   [T7], ac
    add  96, x
    ld   [y,x], ac
    ld   ac, [W_TGH]
rn_fx:
    ld   rfx >> 8, y
    jmp  rfx
rn_trig:
    clr  ac
    ld   ac, [W_RET]
    ld   trig >> 8, y
    jmp  trig

; ------------------------------------------------------------
; trig - start note T7 with instrument W_INS; W_RET 0: back to rfx, 1: sfx
; ------------------------------------------------------------

#addr 0x0B00
trig:
    ld   [W_INS], ac
    and  0x10, ac
    beq  tr_a
    ld   1, ac
tr_a:
    add  [M_SONG], ac
    add  2, y
    ld   [W_INS], ac
    shl
    shl
    shl
    shl
    ld   ac, [T6]
    ld   [T6], x
    ld   [y,x], ac
    ld   ac, [W_AD]
    ld   [T6], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [W_SR]
    ld   [T6], ac
    add  2, x
    ld   [y,x], ac
    ld   ac, [W_WPTR]
    ld   [T6], ac
    add  3, x
    ld   [y,x], ac
    ld   ac, [W_PPTR]
    ld   [T6], ac
    add  4, x
    ld   [y,x], ac
    ld   ac, [W_PW]
    ld   [T6], ac
    add  5, x
    ld   [y,x], ac
    ld   ac, [W_FLAGS]
    ld   [T6], ac
    add  6, x
    ld   [y,x], ac
    ld   ac, [W_VDLY]
    ld   [T6], ac
    add  7, x
    ld   [y,x], ac
    ld   ac, [W_VIB]
    ld   [T6], ac
    add  8, x
    ld   [y,x], ac
    and  15, ac
    ld   ac, [W_VOL]
    clr  ac
    ld   ac, [W_PCNT]
    ld   [W_FLAGS], ac
    and  1, ac
    beq  tr_b
    clr  ac                     ; hard restart
    ld   ac, [W_ENL]
    ld   ac, [W_ENH]
tr_b:
    clr  ac
    ld   ac, [W_EST]
    ld   ac, [W_WNOTE]
    ld   ac, [W_VOFL]
    ld   ac, [W_VOFH]
    ld   ac, [W_VCNT]
    ld   ac, [W_VDIR]
    ld   1, ac
    ld   ac, [W_VHALF]
    ld   [T7], ac
    ld   ac, [W_NOTE]
    ld   ac, x
    ld   MUS_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [W_STL]
    ld   [T7], ac
    add  96, x
    ld   [y,x], ac
    ld   ac, [W_STH]
    ld   [W_RET], ac
    beq  tr_row
    ld   sfx_back >> 8, y
    jmp  sfx_back
tr_row:
    ld   rfx >> 8, y
    jmp  rfx

; ------------------------------------------------------------
; rfx - the row's instant effects
; ------------------------------------------------------------
rfx:
    ld   [W_FX], ac
    xor  5, ac
    bne  rf6
    ld   [W_FXP], ac
    ld   ac, [W_AD]
    bra  rf_x
rf6:
    ld   [W_FX], ac
    xor  6, ac
    bne  rf7
    ld   [W_FXP], ac
    ld   ac, [W_SR]
    bra  rf_x
rf7:
    ld   [W_FX], ac
    xor  7, ac
    bne  rf8
    ld   [W_FXP], ac
    ld   ac, [W_PW]
    clr  ac
    ld   ac, [W_PPTR]
    bra  rf_x
rf8:
    ld   [W_FX], ac
    xor  8, ac
    bne  rf9
    ld   [W_FXP], ac
    and  0x3F, ac
    ld   ac, [W_WPTR]
    bra  rf_x
rf9:
    ld   [W_FX], ac
    xor  9, ac
    bne  rfa
    ld   [W_FXP], ac
    and  15, ac
    ld   ac, [W_VOL]
    bra  rf_x
rfa:
    ld   [W_FX], ac
    xor  10, ac
    bne  rff
    ld   [W_FXP], ac
    and  15, ac
    ld   ac, [M_MASTER]
    bra  rf_x
rff:
    ld   [W_FX], ac
    xor  15, ac
    bne  rf_x
    ld   [W_FXP], ac
    beq  rf_x
    ld   ac, [M_SPEED]
rf_x:
    ld   vt >> 8, y
    jmp  vt

; ------------------------------------------------------------
; vt - the wave program: one step a frame (T0, T1 = the step, T6 = tries)
; ------------------------------------------------------------

#addr 0x0C00
vt:
    ld   [W_WPTR], ac
    beq  vw_x
    ld   2, ac
    ld   ac, [T6]
vw_lp:
    ld   [M_SONG], ac
    add  1, y
    ld   [W_WPTR], x
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [W_WPTR], ac
    add  0x40, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [T0], ac
    xor  0xFF, ac
    bne  vw_a
    ld   [T1], ac               ; jump
    and  0x3F, ac
    ld   ac, [W_WPTR]
    beq  vw_x
    ld   [T6], ac
    dec
    ld   ac, [T6]
    bne  vw_lp
    bra  vw_x
vw_a:
    ld   [T0], ac
    xor  0xFE, ac
    bne  vw_b
    clr  ac                     ; end
    ld   ac, [W_WPTR]
    bra  vw_x
vw_b:
    ld   [T0], ac
    beq  vw_c                   ; 0: waveform unchanged
    xor  0x7F, ac
    beq  vw_off
    ld   [T0], ac
    and  0x0F, ac
vw_off:
    ld   ac, [W_WAVE]
vw_c:
    ld   [T1], ac
    ld   ac, [W_WNOTE]
    ld   [W_WPTR], ac
    inc
    and  0x3F, ac
    ld   ac, [W_WPTR]
vw_x:
    ld   vp >> 8, y
    jmp  vp

; ------------------------------------------------------------
; vp - the pulse program and the pulse width sweep
; ------------------------------------------------------------
vp:
    ld   [W_PPTR], ac
    beq  vp_sw
    ld   [W_PCNT], ac
    bne  vp_sw
    ld   2, ac
    ld   ac, [T6]
vp_lp:
    ld   [M_SONG], ac
    add  1, y
    ld   [W_PPTR], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [W_PPTR], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [T0], ac
    xor  0xFF, ac
    bne  vp_a
    ld   [T1], ac               ; jump
    and  0x3F, ac
    ld   ac, [W_PPTR]
    beq  vp_sw
    ld   [T6], ac
    dec
    ld   ac, [T6]
    bne  vp_lp
    bra  vp_sw
vp_a:
    ld   [T0], ac
    bne  vp_b
    ld   ac, [W_PPTR]           ; end
    bra  vp_sw
vp_b:
    ld   [W_PPTR], ac
    inc
    and  0x3F, ac
    ld   ac, [W_PPTR]
    ld   [T0], ac
    blt  vp_set
    ld   ac, [W_PCNT]
    ld   [T1], ac
    ld   ac, [W_PSPD]
    bra  vp_sw
vp_set:
    ld   [T1], ac
    ld   ac, [W_PW]
vp_sw:
    ld   [W_PCNT], ac
    beq  vp_x
    dec
    ld   ac, [W_PCNT]
    ld   [W_PW], ac
    add  [W_PSPD], ac
    ld   ac, [W_PW]
vp_x:
    ld   vfx >> 8, y
    jmp  vfx

; ------------------------------------------------------------
; vfx - slides and portamento (not on a row's first frame); T1:T0 = 4 x p
; ------------------------------------------------------------

#addr 0x0D00
vfx:
    ld   [M_VIDX], ac
    xor  4, ac
    beq  vf_go
    ld   [M_TICK], ac
    beq  vf_no
vf_go:
    ld   [W_FX], ac
    beq  vf_no
    sub  4, ac
    bcc  vf_no                  ; 1-3 only
    ld   [W_FXP], ac
    shl
    shl
    ld   ac, [T0]
    ld   [W_FXP], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T1]
    ld   [W_FX], ac
    xor  1, ac
    beq  vf_up
    ld   [W_FX], ac
    xor  2, ac
    beq  vf_dn
    ld   vf_po >> 8, y
    jmp  vf_po
vf_no:
    ld   vib >> 8, y
    jmp  vib
vf_up:
    ld   [W_STL], ac
    add  [T0], ac
    ld   ac, [T2]
    ld   [W_STH], ac
    bcc  vu_1
    inc
    beq  vu_max
vu_1:
    add  [T1], ac
    bcs  vu_max
    ld   ac, [W_STH]
    ld   [T2], ac
    ld   ac, [W_STL]
    ld   vib >> 8, y
    jmp  vib
vu_max:
    ld   0xFF, ac
    ld   ac, [W_STL]
    ld   ac, [W_STH]
    ld   vib >> 8, y
    jmp  vib
vf_dn:
    ld   [W_STL], ac
    sub  [T0], ac
    ld   ac, [T2]
    ld   [W_STH], ac
    bcc  vd_1
    sub  1, ac
    bcs  vd_0
vd_1:
    sub  [T1], ac
    bcs  vd_0
    ld   ac, [W_STH]
    ld   [T2], ac
    ld   ac, [W_STL]
    ld   vib >> 8, y
    jmp  vib
vd_0:
    clr  ac
    ld   ac, [W_STL]
    ld   ac, [W_STH]
    ld   vib >> 8, y
    jmp  vib

vf_po:
    ld   [W_STH], ac            ; step < target: up
    sub  [W_TGH], ac
    bcs  po_up
    bne  po_dn
    ld   [W_STL], ac
    sub  [W_TGL], ac
    bcs  po_up
    bra  po_dn
po_up:
    ld   [W_STL], ac
    add  [T0], ac
    ld   ac, [T2]
    ld   [W_STH], ac
    bcc  pu_1
    inc
    beq  po_tgt
pu_1:
    add  [T1], ac
    bcs  po_tgt
    ld   ac, [T7]
    ld   [W_TGH], ac            ; past the target?
    sub  [T7], ac
    bcs  po_tgt
    bne  po_set
    ld   [W_TGL], ac
    sub  [T2], ac
    bcs  po_tgt
po_set:
    ld   [T7], ac
    ld   ac, [W_STH]
    ld   [T2], ac
    ld   ac, [W_STL]
    ld   vib >> 8, y
    jmp  vib
po_tgt:
    ld   [W_TGL], ac
    ld   ac, [W_STL]
    ld   [W_TGH], ac
    ld   ac, [W_STH]
    ld   vib >> 8, y
    jmp  vib
po_dn:
    ld   [W_STL], ac
    sub  [T0], ac
    ld   ac, [T2]
    ld   [W_STH], ac
    bcc  pd_1
    sub  1, ac
    bcs  po_tgt
pd_1:
    sub  [T1], ac
    bcs  po_tgt
    ld   ac, [T7]
    sub  [W_TGH], ac            ; below the target?
    bcs  po_tgt
    bne  po_set
    ld   [T2], ac
    sub  [W_TGL], ac
    bcs  po_tgt
    bra  po_set

; ------------------------------------------------------------
; vib - vibrato: T0 = speed/depth, T1 = depth, T7:T2 = step high x depth
; ------------------------------------------------------------

#addr 0x0E00
vib:
    ld   [W_FX], ac
    xor  4, ac
    bne  vb_i
    ld   [W_FXP], ac
    bra  vb_h
vb_i:
    ld   [W_VDLY], ac
    beq  vb_j
    dec
    ld   ac, [W_VDLY]
    clr  ac
    bra  vb_h
vb_j:
    ld   [W_VIB], ac
vb_h:
    ld   ac, [T0]
    and  0x0F, ac
    beq  vb_off
    ld   ac, [T1]
    ld   [T0], ac
    and  0xF0, ac
    beq  vb_off
    clr  ac
    ld   ac, [T2]
    ld   ac, [T7]
vb_m:
    ld   [T2], ac
    add  [W_STH], ac
    ld   ac, [T2]
    bcc  vb_m1
    ld   [T7], ac
    inc
    ld   ac, [T7]
vb_m1:
    ld   [T1], ac
    dec
    ld   ac, [T1]
    bne  vb_m
    ld   [T2], ac
    shr  ac
    shr  ac
    ld   ac, [T2]
    ld   [T7], ac
    shl
    shl
    shl
    shl
    shl
    shl
    or   [T2], ac
    ld   ac, [T2]
    ld   [W_VDIR], ac
    bne  vb_sub
    ld   [W_VOFL], ac
    add  [T2], ac
    ld   ac, [W_VOFL]
    ld   [W_VOFH], ac
    bcc  vb_c
    inc
    ld   ac, [W_VOFH]
    bra  vb_c
vb_off:
    clr  ac
    ld   ac, [W_VOFL]
    ld   ac, [W_VOFH]
    ld   varp >> 8, y
    jmp  varp
vb_sub:
    ld   [W_VOFL], ac
    sub  [T2], ac
    ld   ac, [W_VOFL]
    ld   [W_VOFH], ac
    bcc  vb_c
    dec
    ld   ac, [W_VOFH]
vb_c:
    ld   [W_VCNT], ac
    inc
    ld   ac, [W_VCNT]
    ld   [T0], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T1]
    ld   [W_VHALF], ac
    beq  vb_l
    ld   [T1], ac
    shr  ac
    ld   ac, [T1]
vb_l:
    ld   [T1], ac
    bne  vb_l2
    ld   1, ac
    ld   ac, [T1]
vb_l2:
    ld   [W_VCNT], ac
    sub  [T1], ac
    bcs  vb_x
    clr  ac
    ld   ac, [W_VCNT]
    ld   ac, [W_VHALF]
    ld   [W_VDIR], ac
    xor  1, ac
    ld   ac, [W_VDIR]
vb_x:
    ld   varp >> 8, y
    jmp  varp

; ------------------------------------------------------------
; varp - arpeggio offset (M_T0); then the envelope
; ------------------------------------------------------------
varp:
    clr  ac
    ld   ac, [M_T0]
    ld   [W_FX], ac
    bne  va_x
    ld   [W_FXP], ac
    beq  va_x
    ld   [W_ARPI], ac
    beq  va_n
    xor  1, ac
    bne  va_2
    ld   [W_FXP], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [M_T0]
    bra  va_n
va_2:
    ld   [W_FXP], ac
    and  15, ac
    ld   ac, [M_T0]
va_n:
    ld   [W_ARPI], ac
    xor  2, ac
    beq  va_z
    ld   [W_ARPI], ac
    inc
va_z:
    ld   ac, [W_ARPI]
va_x:
    ld   [W_EST], ac
    bne  ve_1
    ld   ve_att >> 8, y
    jmp  ve_att
ve_1:
    xor  1, ac
    bne  ve_3
    ld   ve_dec >> 8, y
    jmp  ve_dec
ve_3:
    ld   [W_EST], ac
    xor  3, ac
    bne  ve_x
    ld   ve_rel >> 8, y
    jmp  ve_rel
ve_x:
    ld   vslot >> 8, y
    jmp  vslot


#addr 0x0F00
ve_dec:
    ld   [W_SR], ac             ; M_T1 = sustain x 17
    and  0xF0, ac
    ld   ac, [M_T1]
    ld   [W_SR], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    or   [M_T1], ac
    ld   ac, [M_T1]
    ld   [W_AD], ac
    and  15, ac
    ld   ac, [T0]
    ld   MUS_TAB >> 8, y
    add  0xF0, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [T0], ac
    add  0xE0, x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   [W_ENL], ac
    sub  [T2], ac
    ld   ac, [T2]
    ld   [W_ENH], ac
    bcc  vd_b
    sub  1, ac
    bcs  vd_tgt
vd_b:
    sub  [T1], ac
    bcs  vd_tgt
    ld   ac, [T1]
    sub  [M_T1], ac
    bcs  vd_tgt
    bne  vd_set
    ld   [T2], ac
    beq  vd_tgt
vd_set:
    ld   [T1], ac
    ld   ac, [W_ENH]
    ld   [T2], ac
    ld   ac, [W_ENL]
    ld   vslot >> 8, y
    jmp  vslot
vd_tgt:
    ld   [M_T1], ac
    ld   ac, [W_ENH]
    clr  ac
    ld   ac, [W_ENL]
    ld   2, ac
    ld   ac, [W_EST]
    ld   vslot >> 8, y
    jmp  vslot

vslot:
    ld   [M_VIDX], ac
    xor  4, ac
    beq  vs_3
    ld   [M_VIDX], ac
    xor  3, ac
    bne  vs_v
    ld   [M_SFXN], ac
    beq  vs_v
    ld   0xFF, ac
    ld   ac, [M_SLOT]
    ld   vpit >> 8, y
    jmp  vpit
vs_3:
    ld   3, ac
    bra  vs_s
vs_v:
    ld   [M_VIDX], ac
vs_s:
    ld   ac, [M_SLOT]
    ld   [W_WAVE], ac
    xor  1, ac
    bne  vs_n1
    ld   vs_pulse >> 8, y
    jmp  vs_pulse
vs_n1:
    ld   [W_WAVE], ac
    xor  2, ac
    bne  vs_n2
    ld   MUS_SAW >> 8, ac
    bra  vs_wp
vs_n2:
    ld   [W_WAVE], ac
    xor  3, ac
    bne  vs_n3
    ld   MUS_TRI >> 8, ac
    bra  vs_wp
vs_n3:
    ld   [W_WAVE], ac
    xor  4, ac
    bne  vs_n4
    ld   [M_RNG], ac            ; noise: a random page and phase
    shl
    bcc  vs_r1
    xor  0x1D, ac
vs_r1:
    ld   ac, [M_RNG]
    and  1, ac
    add  MUS_NOISE >> 8, ac
    ld   ac, [W_WPG]
    ld   [M_RNG], ac
    shl
    bcc  vs_r2
    xor  0x1D, ac
vs_r2:
    ld   ac, [M_RNG]
    ld   [M_SLOT], ac
    shl
    add  P0H, x
    ld   [M_RNG], ac
    ld   ac, [x]
    ld   vpit >> 8, y
    jmp  vpit
vs_n4:
    ld   [W_WAVE], ac
    sub  5, ac
    bcs  vs_off
    ld   vs_cust >> 8, y
    jmp  vs_cust
vs_off:
    ld   MUS_SAW >> 8, ac
vs_wp:
    ld   ac, [W_WPG]
    ld   vpit >> 8, y
    jmp  vpit

; pulse: the voice's own page, [0, width) = 63, [width, 256) = 0

#addr 0x1000
vs_pulse:
    ld   [M_VIDX], ac
    add  MUS_PG >> 8, ac
    ld   ac, [W_WPG]
    ld   ac, y
    ld   [W_PAGEK], ac
    xor  1, ac
    beq  pl_inc
    clr  ac                     ; the whole page
    ld   ac, [T1]
    ld   [W_PW], ac
    ld   ac, [T2]
pl_f1:
    ld   [T1], ac
    xor  [T2], ac
    beq  pl_f2
    ld   [T1], x
    ld   63, [y,x]
    ld   [T1], ac
    inc
    ld   ac, [T1]
    bra  pl_f1
pl_f2:
    ld   [T1], x
    ld   0, [y,x]
    ld   [T1], ac
    inc
    ld   ac, [T1]
    bne  pl_f2
    bra  pl_done
pl_inc:
    ld   [W_PW], ac
    sub  [W_PAGEW], ac
    beq  pl_done
    bcs  pl_down
    ld   [W_PAGEW], ac          ; wider: [old, new) = 63
    ld   ac, [T1]
    ld   [W_PW], ac
    ld   ac, [T2]
pl_u:
    ld   [T1], x
    ld   63, [y,x]
    ld   [T1], ac
    inc
    ld   ac, [T1]
    xor  [T2], ac
    bne  pl_u
    bra  pl_done
pl_down:
    ld   [W_PW], ac             ; narrower: [new, old) = 0
    ld   ac, [T1]
    ld   [W_PAGEW], ac
    ld   ac, [T2]
pl_d:
    ld   [T1], x
    ld   0, [y,x]
    ld   [T1], ac
    inc
    ld   ac, [T1]
    xor  [T2], ac
    bne  pl_d
pl_done:
    ld   1, ac
    ld   ac, [W_PAGEK]
    ld   [W_PW], ac
    ld   ac, [W_PAGEW]
    ld   vpit >> 8, y
    jmp  vpit

; custom wave k = WAVE - 5: 32 values, each 8 times
vs_cust:
    ld   [M_VIDX], ac
    add  MUS_PG >> 8, ac
    ld   ac, [W_WPG]
    ld   [W_PAGEK], ac
    xor  [W_WAVE], ac
    bne  cw_go
    ld   vpit >> 8, y
    jmp  vpit
cw_go:
    ld   [W_WAVE], ac
    sub  5, ac
    shl
    shl
    shl
    shl
    shl
    ld   ac, [T1]               ; k x 32
    clr  ac
    ld   ac, [T2]               ; i
cw_lp:
    ld   [T2], ac
    add  [T1], x
    ld   [M_SONG], ac
    add  4, y
    ld   [y,x], ac
    and  63, ac
    ld   ac, [T0]
    ld   [W_WPG], y
    ld   [T2], ac
    shl
    shl
    shl
    ld   ac, [T6]
    ld   [T0], ac
    ld   [T6], x
    ld   ac, [y,x]
    ld   [T6], ac
    add  1, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T6], ac
    add  2, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T6], ac
    add  3, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T6], ac
    add  4, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T6], ac
    add  5, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T6], ac
    add  6, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T6], ac
    add  7, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  32, ac
    bne  cw_lp
    ld   [W_WAVE], ac
    ld   ac, [W_PAGEK]
    ld   vpit >> 8, y
    jmp  vpit

; ------------------------------------------------------------
; vpit - the step (T7:T6) and level (M_T1) for the mixer
; ------------------------------------------------------------

#addr 0x1100
vpit:
    ld   [W_WNOTE], ac
    blt  vq_abs
    ld   [W_NOTE], ac
    add  [M_T0], ac
    ld   ac, [T0]
    ld   [W_WNOTE], ac
    and  0x40, ac
    bne  vq_neg
    ld   [W_WNOTE], ac
    add  [T0], ac
    ld   ac, [T0]
    bra  vq_cl
vq_neg:
    ld   [W_WNOTE], ac
    or   0x80, ac
    add  [T0], ac
    bcs  vq_n1
    clr  ac
vq_n1:
    ld   ac, [T0]
    bra  vq_cl
vq_abs:
    and  0x7F, ac
    ld   ac, [T0]
vq_cl:
    ld   [T0], ac
    sub  96, ac
    bcs  vq_ok
    ld   95, ac
    ld   ac, [T0]
vq_ok:
    ld   [W_WNOTE], ac
    or   [M_T0], ac
    beq  vq_step
    ld   [T0], x
    ld   MUS_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [T6]
    ld   [T0], ac
    add  96, x
    ld   [y,x], ac
    ld   ac, [T7]
    bra  vq_noise
vq_step:
    ld   [W_STL], ac
    add  [W_VOFL], ac
    ld   ac, [T6]
    ld   [W_STH], ac
    bcc  vq_s1
    inc
vq_s1:
    add  [W_VOFH], ac
    ld   ac, [T7]
vq_noise:
    ld   [W_WAVE], ac
    xor  4, ac
    bne  vq_lv
    ld   [T6], ac               ; noise: step / 16
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T6]
    ld   [T7], ac
    shl
    shl
    shl
    shl
    or   [T6], ac
    ld   ac, [T6]
    ld   [T7], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T7]
vq_lv:
    ld   [W_ENH], ac
    and  0xF0, ac
    or   [W_VOL], ac
    ld   ac, x
    ld   MUS_VMUL >> 8, y
    ld   [y,x], ac
    shl
    shl
    shl
    shl
    or   [M_MASTER], ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [M_T1]
    ld   [W_WAVE], ac
    bne  vq_x
    ld   ac, [M_T1]
vq_x:
    ld   vsmc >> 8, y
    jmp  vsmc

; ------------------------------------------------------------
; vsmc - write the slot's step, wave page and volume into the mixer
; ------------------------------------------------------------
mus_init:
    ld   [R1], ac
    ld   ac, [M_SONG]
    ld   0x80, ac
    ld   ac, [M_PLAY]
    clr  ac
    ld   ac, [M_SFXN]
    ld   ac, [M_TICK]
    ld   15, ac
    ld   ac, [M_MASTER]
    ld   1, ac
    ld   ac, [M_RNG]
    ld   6, ac
    ld   ac, [M_SPEED]
    ld   0x5D, y                ; the buffer: silence
    ld   0xF3, ac
mi_a:
    ld   ac, x
    ld   0x80, [y,x]
    inc
    bne  mi_a
    ld   0x5E, y
mi_b:
    ld   ac, x
    ld   0x80, [y,x]
    inc
    bne  mi_b
    ld   0x5F, y
mi_c:
    ld   ac, x
    ld   0x80, [y,x]
    inc
    bne  mi_c
    ld   0x50, y
    ld   [y,x], ac
    ld   ac, [M_RPTR]
    ld   ac, [M_REND]
    clr  ac
    ld   ac, [M_AHEAD]
    ld   ac, [M_VIDX]
mi_v:
    ld   mus_dflt >> 8, y       ; W = a quiet voice
    jmp  mus_dflt
mi_v2:
    ld   mus_wout >> 8, y
    jmp  mus_wout
mi_v3:
    ld   [M_VIDX], ac
    inc
    ld   ac, [M_VIDX]
    xor  5, ac
    bne  mi_v
    clr  ac
    ld   ac, [M_VIDX]
mi_s:
    ld   mus_slot0 >> 8, y      ; slot M_VIDX: step 0, SAW, level 0, phase 0
    jmp  mus_slot0
mi_s2:
    ld   [M_VIDX], ac
    inc
    ld   ac, [M_VIDX]
    xor  4, ac
    bne  mi_s
    ld   mf_fill >> 8, y        ; the first fill: silence, 131 groups ahead
    jmp  mf_fill

; W = the quiet voice (mus_tool.Voice), then back by M_PLAY bit 0..: the
; callers are mus_init (mi_v2) and mus_play (mp_v2), told apart by M_T1
vsmc:
    ld   [M_SLOT], ac
    blt  vz_x
    ld   [M_T1], ac             ; T0 = (L & 3) x 64, T1 = VOLT page + L / 4
    and  3, ac
    shl
    shl
    shl
    shl
    shl
    shl
    ld   ac, [T0]
    ld   [M_T1], ac
    shr  ac
    shr  ac
    add  MUS_VOLT >> 8, ac
    ld   ac, [T1]
    ld   [M_SLOT], ac
    beq  vz_0
    xor  1, ac
    beq  vz_1
    ld   [M_SLOT], ac
    xor  2, ac
    beq  vz_2
    ld   vz_3 >> 8, y
    jmp  vz_3
vz_x:
    ld   mt_out >> 8, y
    jmp  mt_out
vz_0:
    ld   (mv0_sl + 1) >> 8, y
    ld   (mv0_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv0_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv0_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv0_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv0_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   mt_out >> 8, y
    jmp  mt_out
vz_1:
    ld   (mv1_sl + 1) >> 8, y
    ld   (mv1_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv1_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv1_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv1_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv1_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   mt_out >> 8, y
    jmp  mt_out
vz_2:
    ld   (mv2_sl + 1) >> 8, y
    ld   (mv2_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv2_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv2_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv2_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv2_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   mt_out >> 8, y
    jmp  mt_out
mus_wout:
    ld   [M_VIDX], ac
    add  MUS_VS >> 8, y
    ld   0x76, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x77, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x78, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x79, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x80, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x81, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x82, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x83, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x84, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x85, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x86, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x87, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x88, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x89, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   mus_wout2 >> 8, y
    jmp  mus_wout2

#addr 0x1300
mus_dflt:
    ld   0x00, ac
    ld   ac, [W_OLL]
    ld   0x00, ac
    ld   ac, [W_OLH]
    ld   0x00, ac
    ld   ac, [W_OSL]
    ld   0x00, ac
    ld   ac, [W_OSH]
    ld   0x00, ac
    ld   ac, [W_PPL]
    ld   0x00, ac
    ld   ac, [W_PPH]
    ld   0x00, ac
    ld   ac, [W_TRANS]
    ld   0x00, ac
    ld   ac, [W_EMPTY]
    ld   0x00, ac
    ld   ac, [W_NOTE]
    ld   0x00, ac
    ld   ac, [W_INS]
    ld   0x00, ac
    ld   ac, [W_STL]
    ld   0x00, ac
    ld   ac, [W_STH]
    ld   0x00, ac
    ld   ac, [W_FX]
    ld   0x00, ac
    ld   ac, [W_FXP]
    ld   0x00, ac
    ld   ac, [W_ENL]
    ld   0x00, ac
    ld   ac, [W_ENH]
    ld   0x03, ac
    ld   ac, [W_EST]
    ld   0x00, ac
    ld   ac, [W_AD]
    ld   0x00, ac
    ld   ac, [W_SR]
    ld   0x00, ac
    ld   ac, [W_WPTR]
    ld   0x00, ac
    ld   ac, [W_WNOTE]
    ld   0x00, ac
    ld   ac, [W_PPTR]
    ld   0x00, ac
    ld   ac, [W_PCNT]
    ld   0x00, ac
    ld   ac, [W_PSPD]
    ld   0x80, ac
    ld   ac, [W_PW]
    ld   0x00, ac
    ld   ac, [W_WAVE]
    ld   0xFF, ac
    ld   ac, [W_PAGEK]
    ld   0x00, ac
    ld   ac, [W_PAGEW]
    ld   0x00, ac
    ld   ac, [W_VIB]
    ld   0x00, ac
    ld   ac, [W_VDLY]
    ld   0x00, ac
    ld   ac, [W_VCNT]
    ld   0x00, ac
    ld   ac, [W_VDIR]
    ld   0x01, ac
    ld   ac, [W_VHALF]
    ld   0x00, ac
    ld   ac, [W_VOFL]
    ld   0x00, ac
    ld   ac, [W_VOFH]
    ld   0x00, ac
    ld   ac, [W_TGL]
    ld   0x00, ac
    ld   ac, [W_TGH]
    ld   0x0F, ac
    ld   ac, [W_VOL]
    ld   0x00, ac
    ld   ac, [W_ARPI]
    ld   0x00, ac
    ld   ac, [W_FLAGS]
    ld   0x01, ac
    ld   ac, [W_STOP]
    ld   0x00, ac
    ld   ac, [W_RET]
    ld   [M_T1], ac
    bne  md_p
    ld   mi_v2 >> 8, y
    jmp  mi_v2
md_p:
    ld   mp_v2 >> 8, y
    jmp  mp_v2

; copy W out to the page in Y, back to mi_v3 or mp_v3 (M_T1)

#addr 0x1400
mus_wout2:
    ld   [M_VIDX], ac
    add  MUS_VS >> 8, y
    ld   0x8C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x90, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x91, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x92, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x93, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x94, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x95, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x96, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x97, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x98, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x99, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   [M_T1], ac
    bne  mw_p
    ld   mi_v3 >> 8, y
    jmp  mi_v3
mw_p:
    ld   mp_v3 >> 8, y
    jmp  mp_v3

; mixer slot M_VIDX: step 0, wave page SAW, level 0, phase 0
mus_slot0:
    ld   0, ac
    ld   ac, [T6]
    ld   ac, [T7]
    ld   ac, [T0]
    ld   MUS_SAW >> 8, ac
    ld   ac, [W_WPG]
    ld   MUS_VOLT >> 8, ac
    ld   ac, [T1]
    ld   [M_VIDX], ac
    shl
    add  P0L, x
    ld   0, ac
    ld   ac, [x]
    ld   [M_VIDX], ac
    shl
    add  P0H, x
    ld   0, ac
    ld   ac, [x]
    ld   [M_VIDX], ac
    beq  ms_0
    xor  1, ac
    beq  ms_1
    ld   [M_VIDX], ac
    xor  2, ac
    beq  ms_2
    ld   ms_3 >> 8, y
    jmp  ms_3
ms_0:
    ld   (mv0_sl + 1) >> 8, y
    ld   (mv0_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv0_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv0_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv0_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv0_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   ms_back >> 8, y
    jmp  ms_back
ms_1:
    ld   (mv1_sl + 1) >> 8, y
    ld   (mv1_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv1_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv1_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv1_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv1_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   ms_back >> 8, y
    jmp  ms_back
ms_2:
    ld   (mv2_sl + 1) >> 8, y
    ld   (mv2_sl + 1) & 0xFF, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   (mv2_sh + 1) & 0xFF, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   (mv2_wp + 1) & 0xFF, x
    ld   [W_WPG], ac
    ld   ac, [y,x]
    ld   (mv2_vo + 1) & 0xFF, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   (mv2_vp + 1) & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   ms_back >> 8, y
    jmp  ms_back

#addr 0x1500
mus_play:
    ld   ac, [M_T0]               ; M_T0 = 40h + 9 x subtune
    shl
    shl
    shl
    add  [M_T0], ac
    add  0x40, ac
    ld   ac, [M_T0]
    ld   [M_SONG], y
    ld   [M_T0], x
    ld   [y,x], ac
    bne  mp_sp
    ld   6, ac
mp_sp:
    ld   ac, [M_SPEED]
    clr  ac
    ld   ac, [M_TICK]
    ld   ac, [M_VIDX]
    ld   15, ac
    ld   ac, [M_MASTER]
    ld   1, ac
    ld   ac, [M_T1]             ; the callers' tell: mus_play
mp_v:
    ld   mus_dflt >> 8, y
    jmp  mus_dflt
mp_v2:
    ld   [M_VIDX], ac           ; the orderlist: song + offset
    shl
    add  [M_T0], ac
    add  1, x
    ld   [M_SONG], y
    ld   [y,x], ac
    ld   ac, [W_OLL]
    ld   ac, [W_OSL]
    ld   [M_VIDX], ac
    shl
    add  [M_T0], ac
    add  2, x
    ld   [y,x], ac
    add  [M_SONG], ac
    ld   ac, [W_OLH]
    ld   ac, [W_OSH]
    clr  ac
    ld   ac, [W_STOP]
    ld   mus_wout >> 8, y
    jmp  mus_wout
mp_v3:
    ld   mus_slot0 >> 8, y
    jmp  mus_slot0
mp_s2:
    ld   [M_VIDX], ac
    inc
    ld   ac, [M_VIDX]
    xor  4, ac
    bne  mp_v
    clr  ac
    ld   ac, [M_T1]
    ld   0x81, ac
    ld   ac, [M_PLAY]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; mus_stop - no more rows; voices 0-3 release
;   changes: AC, X, Y
; ------------------------------------------------------------
sfx_in:
    ld   (MUS_VS >> 8) + 4, y
    ld   0x76, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x77, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x78, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x79, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7A, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7B, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7C, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7D, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7E, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x7F, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x80, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x81, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x82, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x83, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x84, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x85, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x86, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x87, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x88, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x89, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8A, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8B, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   sfx_in2 >> 8, y
    jmp  sfx_in2

#addr 0x1600
sfx_in2:
    ld   (MUS_VS >> 8) + 4, y
    ld   0x8C, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8D, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8E, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x8F, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x90, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x91, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x92, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x93, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x94, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x95, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x96, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x97, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x98, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x99, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9A, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9B, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9C, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9D, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9E, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   0x9F, x
    ld   [y,x], ac
    ld   ac, [x]
    ld   [R0], ac
    ld   ac, [W_INS]
    ld   1, ac
    ld   ac, [W_RET]
    ld   trig >> 8, y
    jmp  trig
sfx_back:
    ld   sfx_out >> 8, y
    jmp  sfx_out
sfx_out:
    ld   (MUS_VS >> 8) + 4, y
    ld   0x76, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x77, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x78, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x79, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x7F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x80, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x81, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x82, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x83, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x84, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x85, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x86, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x87, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x88, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x89, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   sfx_out2 >> 8, y
    jmp  sfx_out2

#addr 0x1700
sfx_out2:
    ld   (MUS_VS >> 8) + 4, y
    ld   0x8C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x8F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x90, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x91, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x92, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x93, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x94, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x95, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x96, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x97, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x98, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x99, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9A, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9B, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9C, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9D, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9E, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   0x9F, x
    ld   [x], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

#addr 0x2000
; MUS_SAW
    #d8 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x03, 0x03, 0x03, 0x03
    #d8 0x04, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x06, 0x07, 0x07, 0x07, 0x07
    #d8 0x08, 0x08, 0x08, 0x08, 0x09, 0x09, 0x09, 0x09, 0x0A, 0x0A, 0x0A, 0x0A, 0x0B, 0x0B, 0x0B, 0x0B
    #d8 0x0C, 0x0C, 0x0C, 0x0C, 0x0D, 0x0D, 0x0D, 0x0D, 0x0E, 0x0E, 0x0E, 0x0E, 0x0F, 0x0F, 0x0F, 0x0F
    #d8 0x10, 0x10, 0x10, 0x10, 0x11, 0x11, 0x11, 0x11, 0x12, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x13
    #d8 0x14, 0x14, 0x14, 0x14, 0x15, 0x15, 0x15, 0x15, 0x16, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x17
    #d8 0x18, 0x18, 0x18, 0x18, 0x19, 0x19, 0x19, 0x19, 0x1A, 0x1A, 0x1A, 0x1A, 0x1B, 0x1B, 0x1B, 0x1B
    #d8 0x1C, 0x1C, 0x1C, 0x1C, 0x1D, 0x1D, 0x1D, 0x1D, 0x1E, 0x1E, 0x1E, 0x1E, 0x1F, 0x1F, 0x1F, 0x1F
    #d8 0x20, 0x20, 0x20, 0x20, 0x21, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x22, 0x23, 0x23, 0x23, 0x23
    #d8 0x24, 0x24, 0x24, 0x24, 0x25, 0x25, 0x25, 0x25, 0x26, 0x26, 0x26, 0x26, 0x27, 0x27, 0x27, 0x27
    #d8 0x28, 0x28, 0x28, 0x28, 0x29, 0x29, 0x29, 0x29, 0x2A, 0x2A, 0x2A, 0x2A, 0x2B, 0x2B, 0x2B, 0x2B
    #d8 0x2C, 0x2C, 0x2C, 0x2C, 0x2D, 0x2D, 0x2D, 0x2D, 0x2E, 0x2E, 0x2E, 0x2E, 0x2F, 0x2F, 0x2F, 0x2F
    #d8 0x30, 0x30, 0x30, 0x30, 0x31, 0x31, 0x31, 0x31, 0x32, 0x32, 0x32, 0x32, 0x33, 0x33, 0x33, 0x33
    #d8 0x34, 0x34, 0x34, 0x34, 0x35, 0x35, 0x35, 0x35, 0x36, 0x36, 0x36, 0x36, 0x37, 0x37, 0x37, 0x37
    #d8 0x38, 0x38, 0x38, 0x38, 0x39, 0x39, 0x39, 0x39, 0x3A, 0x3A, 0x3A, 0x3A, 0x3B, 0x3B, 0x3B, 0x3B
    #d8 0x3C, 0x3C, 0x3C, 0x3C, 0x3D, 0x3D, 0x3D, 0x3D, 0x3E, 0x3E, 0x3E, 0x3E, 0x3F, 0x3F, 0x3F, 0x3F

; MUS_TRI
    #d8 0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05, 0x06, 0x06, 0x07, 0x07
    #d8 0x08, 0x08, 0x09, 0x09, 0x0A, 0x0A, 0x0B, 0x0B, 0x0C, 0x0C, 0x0D, 0x0D, 0x0E, 0x0E, 0x0F, 0x0F
    #d8 0x10, 0x10, 0x11, 0x11, 0x12, 0x12, 0x13, 0x13, 0x14, 0x14, 0x15, 0x15, 0x16, 0x16, 0x17, 0x17
    #d8 0x18, 0x18, 0x19, 0x19, 0x1A, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F
    #d8 0x20, 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x23, 0x24, 0x24, 0x25, 0x25, 0x26, 0x26, 0x27, 0x27
    #d8 0x28, 0x28, 0x29, 0x29, 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2F, 0x2F
    #d8 0x30, 0x30, 0x31, 0x31, 0x32, 0x32, 0x33, 0x33, 0x34, 0x34, 0x35, 0x35, 0x36, 0x36, 0x37, 0x37
    #d8 0x38, 0x38, 0x39, 0x39, 0x3A, 0x3A, 0x3B, 0x3B, 0x3C, 0x3C, 0x3D, 0x3D, 0x3E, 0x3E, 0x3F, 0x3F
    #d8 0x3F, 0x3F, 0x3E, 0x3E, 0x3D, 0x3D, 0x3C, 0x3C, 0x3B, 0x3B, 0x3A, 0x3A, 0x39, 0x39, 0x38, 0x38
    #d8 0x37, 0x37, 0x36, 0x36, 0x35, 0x35, 0x34, 0x34, 0x33, 0x33, 0x32, 0x32, 0x31, 0x31, 0x30, 0x30
    #d8 0x2F, 0x2F, 0x2E, 0x2E, 0x2D, 0x2D, 0x2C, 0x2C, 0x2B, 0x2B, 0x2A, 0x2A, 0x29, 0x29, 0x28, 0x28
    #d8 0x27, 0x27, 0x26, 0x26, 0x25, 0x25, 0x24, 0x24, 0x23, 0x23, 0x22, 0x22, 0x21, 0x21, 0x20, 0x20
    #d8 0x1F, 0x1F, 0x1E, 0x1E, 0x1D, 0x1D, 0x1C, 0x1C, 0x1B, 0x1B, 0x1A, 0x1A, 0x19, 0x19, 0x18, 0x18
    #d8 0x17, 0x17, 0x16, 0x16, 0x15, 0x15, 0x14, 0x14, 0x13, 0x13, 0x12, 0x12, 0x11, 0x11, 0x10, 0x10
    #d8 0x0F, 0x0F, 0x0E, 0x0E, 0x0D, 0x0D, 0x0C, 0x0C, 0x0B, 0x0B, 0x0A, 0x0A, 0x09, 0x09, 0x08, 0x08
    #d8 0x07, 0x07, 0x06, 0x06, 0x05, 0x05, 0x04, 0x04, 0x03, 0x03, 0x02, 0x02, 0x01, 0x01, 0x00, 0x00

; MUS_NOISE
    #d8 0x12, 0x34, 0x19, 0x35, 0x3D, 0x27, 0x2C, 0x1C, 0x34, 0x32, 0x32, 0x3A, 0x2A, 0x1C, 0x07, 0x2C
    #d8 0x21, 0x23, 0x12, 0x1F, 0x06, 0x2F, 0x20, 0x06, 0x18, 0x0E, 0x31, 0x28, 0x2D, 0x23, 0x1E, 0x32
    #d8 0x0D, 0x05, 0x37, 0x1D, 0x1C, 0x10, 0x1A, 0x39, 0x01, 0x06, 0x21, 0x3A, 0x1A, 0x24, 0x0D, 0x2B
    #d8 0x1F, 0x32, 0x0D, 0x1F, 0x28, 0x2C, 0x23, 0x10, 0x2D, 0x39, 0x07, 0x19, 0x27, 0x3D, 0x1A, 0x19
    #d8 0x32, 0x03, 0x14, 0x38, 0x0D, 0x1A, 0x0C, 0x1E, 0x2F, 0x19, 0x0D, 0x1A, 0x12, 0x22, 0x2B, 0x2F
    #d8 0x11, 0x03, 0x10, 0x1A, 0x2F, 0x25, 0x25, 0x0C, 0x1F, 0x21, 0x10, 0x01, 0x29, 0x25, 0x23, 0x2B
    #d8 0x2A, 0x3C, 0x33, 0x3A, 0x37, 0x22, 0x1C, 0x1A, 0x21, 0x1C, 0x20, 0x14, 0x2C, 0x30, 0x30, 0x2C
    #d8 0x06, 0x03, 0x28, 0x04, 0x20, 0x16, 0x0E, 0x0E, 0x0E, 0x1E, 0x27, 0x05, 0x13, 0x18, 0x20, 0x0F
    #d8 0x18, 0x30, 0x30, 0x2B, 0x13, 0x2F, 0x3A, 0x29, 0x37, 0x32, 0x28, 0x16, 0x0B, 0x31, 0x38, 0x0C
    #d8 0x35, 0x1D, 0x3C, 0x1C, 0x2A, 0x31, 0x24, 0x37, 0x37, 0x3B, 0x1C, 0x34, 0x1E, 0x01, 0x0E, 0x1D
    #d8 0x06, 0x1E, 0x13, 0x12, 0x27, 0x10, 0x26, 0x04, 0x37, 0x33, 0x18, 0x03, 0x29, 0x38, 0x22, 0x26
    #d8 0x08, 0x3B, 0x10, 0x1C, 0x25, 0x28, 0x38, 0x27, 0x1A, 0x00, 0x11, 0x22, 0x1B, 0x24, 0x27, 0x0D
    #d8 0x1D, 0x2D, 0x35, 0x00, 0x25, 0x05, 0x1B, 0x11, 0x27, 0x15, 0x26, 0x38, 0x3D, 0x36, 0x0F, 0x11
    #d8 0x32, 0x01, 0x1E, 0x3D, 0x21, 0x02, 0x0D, 0x37, 0x18, 0x15, 0x2F, 0x38, 0x37, 0x3A, 0x11, 0x17
    #d8 0x06, 0x08, 0x15, 0x0A, 0x0B, 0x07, 0x23, 0x28, 0x38, 0x09, 0x25, 0x01, 0x00, 0x28, 0x27, 0x08
    #d8 0x1B, 0x0B, 0x35, 0x0D, 0x3B, 0x3C, 0x2E, 0x06, 0x1F, 0x26, 0x06, 0x03, 0x24, 0x31, 0x2D, 0x1F

; MUS_NOISE1
    #d8 0x2C, 0x39, 0x3C, 0x2E, 0x1B, 0x04, 0x26, 0x00, 0x38, 0x29, 0x38, 0x3F, 0x15, 0x25, 0x00, 0x2F
    #d8 0x0B, 0x26, 0x11, 0x2E, 0x12, 0x0C, 0x23, 0x1D, 0x26, 0x25, 0x29, 0x21, 0x3B, 0x1F, 0x2A, 0x00
    #d8 0x28, 0x11, 0x15, 0x01, 0x30, 0x13, 0x14, 0x0E, 0x03, 0x1B, 0x32, 0x1F, 0x25, 0x3E, 0x1C, 0x31
    #d8 0x2F, 0x3C, 0x04, 0x1B, 0x2F, 0x3A, 0x02, 0x3C, 0x34, 0x2D, 0x1E, 0x36, 0x13, 0x38, 0x08, 0x34
    #d8 0x16, 0x35, 0x3E, 0x3E, 0x0F, 0x0B, 0x14, 0x18, 0x27, 0x3B, 0x3E, 0x3F, 0x1D, 0x1D, 0x1C, 0x29
    #d8 0x3A, 0x33, 0x3F, 0x31, 0x13, 0x08, 0x00, 0x00, 0x20, 0x35, 0x3B, 0x30, 0x0B, 0x0A, 0x02, 0x09
    #d8 0x3A, 0x1D, 0x35, 0x01, 0x00, 0x35, 0x00, 0x05, 0x09, 0x27, 0x21, 0x31, 0x0A, 0x37, 0x28, 0x29
    #d8 0x12, 0x30, 0x26, 0x03, 0x21, 0x2D, 0x31, 0x04, 0x1B, 0x2B, 0x04, 0x08, 0x26, 0x1D, 0x03, 0x10
    #d8 0x05, 0x1D, 0x30, 0x34, 0x32, 0x38, 0x3F, 0x2C, 0x36, 0x3C, 0x37, 0x1B, 0x0A, 0x03, 0x3E, 0x24
    #d8 0x3A, 0x0E, 0x0F, 0x27, 0x1C, 0x30, 0x30, 0x1A, 0x34, 0x35, 0x1B, 0x1B, 0x0F, 0x3D, 0x24, 0x28
    #d8 0x04, 0x23, 0x16, 0x0C, 0x3E, 0x30, 0x23, 0x12, 0x12, 0x3A, 0x20, 0x2B, 0x08, 0x15, 0x2A, 0x29
    #d8 0x2A, 0x05, 0x22, 0x34, 0x28, 0x07, 0x2D, 0x32, 0x2D, 0x12, 0x18, 0x39, 0x2F, 0x3B, 0x13, 0x1F
    #d8 0x13, 0x39, 0x03, 0x35, 0x13, 0x02, 0x3B, 0x2E, 0x32, 0x15, 0x05, 0x2B, 0x18, 0x28, 0x16, 0x11
    #d8 0x3C, 0x3E, 0x27, 0x0D, 0x0B, 0x03, 0x19, 0x35, 0x05, 0x1A, 0x31, 0x03, 0x1B, 0x28, 0x32, 0x24
    #d8 0x38, 0x3C, 0x10, 0x08, 0x2C, 0x38, 0x14, 0x35, 0x0D, 0x24, 0x1A, 0x2F, 0x25, 0x0D, 0x34, 0x25
    #d8 0x0E, 0x0A, 0x1B, 0x39, 0x29, 0x20, 0x25, 0x15, 0x10, 0x1D, 0x13, 0x13, 0x03, 0x28, 0x0B, 0x1E

; MUS_VOLT0
    #d8 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20
    #d8 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20
    #d8 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20
    #d8 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20
    #d8 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F
    #d8 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20
    #d8 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21
    #d8 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22
    #d8 0x1C, 0x1C, 0x1C, 0x1C, 0x1C, 0x1C, 0x1D, 0x1D, 0x1D, 0x1D, 0x1D, 0x1D, 0x1D, 0x1D, 0x1E, 0x1E
    #d8 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x20, 0x20, 0x20
    #d8 0x20, 0x20, 0x20, 0x20, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x22
    #d8 0x22, 0x22, 0x22, 0x23, 0x23, 0x23, 0x23, 0x23, 0x23, 0x23, 0x23, 0x24, 0x24, 0x24, 0x24, 0x24
    #d8 0x1A, 0x1A, 0x1A, 0x1A, 0x1A, 0x1B, 0x1B, 0x1B, 0x1B, 0x1B, 0x1C, 0x1C, 0x1C, 0x1C, 0x1C, 0x1D
    #d8 0x1D, 0x1D, 0x1D, 0x1D, 0x1E, 0x1E, 0x1E, 0x1E, 0x1E, 0x1F, 0x1F, 0x1F, 0x1F, 0x1F, 0x20, 0x20
    #d8 0x20, 0x20, 0x20, 0x21, 0x21, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x22, 0x22, 0x23, 0x23, 0x23
    #d8 0x23, 0x23, 0x24, 0x24, 0x24, 0x24, 0x24, 0x25, 0x25, 0x25, 0x25, 0x25, 0x26, 0x26, 0x26, 0x26

; MUS_VOLT1
    #d8 0x17, 0x18, 0x18, 0x18, 0x19, 0x19, 0x19, 0x19, 0x1A, 0x1A, 0x1A, 0x1A, 0x1B, 0x1B, 0x1B, 0x1B
    #d8 0x1C, 0x1C, 0x1C, 0x1D, 0x1D, 0x1D, 0x1D, 0x1E, 0x1E, 0x1E, 0x1E, 0x1F, 0x1F, 0x1F, 0x1F, 0x20
    #d8 0x20, 0x20, 0x21, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x22, 0x23, 0x23, 0x23, 0x23, 0x24, 0x24
    #d8 0x24, 0x25, 0x25, 0x25, 0x25, 0x26, 0x26, 0x26, 0x26, 0x27, 0x27, 0x27, 0x27, 0x28, 0x28, 0x28
    #d8 0x15, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x18, 0x18, 0x18, 0x19, 0x19, 0x19, 0x1A, 0x1A, 0x1A
    #d8 0x1B, 0x1B, 0x1B, 0x1C, 0x1C, 0x1C, 0x1D, 0x1D, 0x1D, 0x1E, 0x1E, 0x1E, 0x1F, 0x1F, 0x1F, 0x20
    #d8 0x20, 0x20, 0x21, 0x21, 0x21, 0x22, 0x22, 0x22, 0x23, 0x23, 0x23, 0x24, 0x24, 0x24, 0x25, 0x25
    #d8 0x25, 0x26, 0x26, 0x26, 0x27, 0x27, 0x27, 0x28, 0x28, 0x28, 0x29, 0x29, 0x29, 0x2A, 0x2A, 0x2A
    #d8 0x13, 0x14, 0x14, 0x14, 0x15, 0x15, 0x16, 0x16, 0x16, 0x17, 0x17, 0x18, 0x18, 0x18, 0x19, 0x19
    #d8 0x1A, 0x1A, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1E, 0x1F, 0x1F, 0x20
    #d8 0x20, 0x20, 0x21, 0x21, 0x22, 0x22, 0x22, 0x23, 0x23, 0x24, 0x24, 0x24, 0x25, 0x25, 0x26, 0x26
    #d8 0x26, 0x27, 0x27, 0x28, 0x28, 0x28, 0x29, 0x29, 0x2A, 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2C, 0x2C
    #d8 0x11, 0x12, 0x12, 0x12, 0x13, 0x13, 0x14, 0x14, 0x15, 0x15, 0x16, 0x16, 0x17, 0x17, 0x18, 0x18
    #d8 0x19, 0x19, 0x19, 0x1A, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F, 0x20
    #d8 0x20, 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x23, 0x24, 0x24, 0x25, 0x25, 0x26, 0x26, 0x27, 0x27
    #d8 0x27, 0x28, 0x28, 0x29, 0x29, 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2E

; MUS_VOLT2
    #d8 0x0F, 0x0F, 0x10, 0x11, 0x11, 0x12, 0x12, 0x13, 0x13, 0x14, 0x14, 0x15, 0x15, 0x16, 0x16, 0x17
    #d8 0x17, 0x18, 0x19, 0x19, 0x1A, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F
    #d8 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x23, 0x24, 0x24, 0x25, 0x25, 0x26, 0x26, 0x27, 0x27, 0x28
    #d8 0x29, 0x29, 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2F, 0x2F, 0x30, 0x31
    #d8 0x0D, 0x0D, 0x0E, 0x0F, 0x0F, 0x10, 0x10, 0x11, 0x12, 0x12, 0x13, 0x13, 0x14, 0x15, 0x15, 0x16
    #d8 0x16, 0x17, 0x18, 0x18, 0x19, 0x19, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F
    #d8 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x24, 0x24, 0x25, 0x25, 0x26, 0x27, 0x27, 0x28, 0x28, 0x29
    #d8 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2F, 0x30, 0x30, 0x31, 0x31, 0x32, 0x33
    #d8 0x0B, 0x0B, 0x0C, 0x0D, 0x0D, 0x0E, 0x0F, 0x0F, 0x10, 0x11, 0x11, 0x12, 0x13, 0x13, 0x14, 0x15
    #d8 0x15, 0x16, 0x17, 0x17, 0x18, 0x19, 0x19, 0x1A, 0x1B, 0x1B, 0x1C, 0x1D, 0x1D, 0x1E, 0x1F, 0x1F
    #d8 0x20, 0x21, 0x21, 0x22, 0x23, 0x23, 0x24, 0x25, 0x25, 0x26, 0x27, 0x27, 0x28, 0x29, 0x29, 0x2A
    #d8 0x2B, 0x2B, 0x2C, 0x2D, 0x2D, 0x2E, 0x2F, 0x2F, 0x30, 0x31, 0x31, 0x32, 0x33, 0x33, 0x34, 0x35
    #d8 0x09, 0x09, 0x0A, 0x0B, 0x0B, 0x0C, 0x0D, 0x0E, 0x0E, 0x0F, 0x10, 0x11, 0x11, 0x12, 0x13, 0x14
    #d8 0x14, 0x15, 0x16, 0x16, 0x17, 0x18, 0x19, 0x19, 0x1A, 0x1B, 0x1C, 0x1C, 0x1D, 0x1E, 0x1F, 0x1F
    #d8 0x20, 0x21, 0x21, 0x22, 0x23, 0x24, 0x24, 0x25, 0x26, 0x27, 0x27, 0x28, 0x29, 0x2A, 0x2A, 0x2B
    #d8 0x2C, 0x2C, 0x2D, 0x2E, 0x2F, 0x2F, 0x30, 0x31, 0x32, 0x32, 0x33, 0x34, 0x35, 0x35, 0x36, 0x37

; MUS_VOLT3
    #d8 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x12
    #d8 0x13, 0x14, 0x15, 0x16, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1E, 0x1F
    #d8 0x20, 0x21, 0x22, 0x22, 0x23, 0x24, 0x25, 0x26, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2A, 0x2B, 0x2C
    #d8 0x2D, 0x2E, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x32, 0x33, 0x34, 0x35, 0x36, 0x36, 0x37, 0x38, 0x39
    #d8 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x10, 0x11
    #d8 0x12, 0x13, 0x14, 0x15, 0x16, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1D, 0x1E, 0x1F
    #d8 0x20, 0x21, 0x22, 0x23, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2A, 0x2B, 0x2C, 0x2D
    #d8 0x2E, 0x2F, 0x30, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x37, 0x38, 0x39, 0x3A, 0x3B
    #d8 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
    #d8 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
    #d8 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E
    #d8 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D
    #d8 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
    #d8 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
    #d8 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F
    #d8 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F

; MUS_VMUL
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03
    #d8 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x03, 0x03, 0x03, 0x04
    #d8 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x03, 0x03, 0x03, 0x04, 0x04, 0x04, 0x05
    #d8 0x00, 0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x04, 0x05, 0x05, 0x06
    #d8 0x00, 0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05, 0x06, 0x06, 0x07
    #d8 0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05, 0x06, 0x06, 0x07, 0x08
    #d8 0x00, 0x00, 0x01, 0x01, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x06, 0x06, 0x07, 0x07, 0x08, 0x09
    #d8 0x00, 0x00, 0x01, 0x02, 0x02, 0x03, 0x04, 0x04, 0x05, 0x06, 0x06, 0x07, 0x08, 0x08, 0x09, 0x0A
    #d8 0x00, 0x00, 0x01, 0x02, 0x02, 0x03, 0x04, 0x05, 0x05, 0x06, 0x07, 0x08, 0x08, 0x09, 0x0A, 0x0B
    #d8 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x04, 0x05, 0x06, 0x07, 0x08, 0x08, 0x09, 0x0A, 0x0B, 0x0C
    #d8 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D
    #d8 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E
    #d8 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F

; MUS_TAB
    #d8 0x44, 0x48, 0x4C, 0x51, 0x56, 0x5B, 0x60, 0x66, 0x6C, 0x72, 0x79, 0x80, 0x88, 0x90, 0x99, 0xA2
    #d8 0xAB, 0xB5, 0xC0, 0xCC, 0xD8, 0xE5, 0xF2, 0x01, 0x10, 0x20, 0x31, 0x43, 0x57, 0x6B, 0x81, 0x97
    #d8 0xB0, 0xC9, 0xE4, 0x01, 0x20, 0x40, 0x62, 0x87, 0xAD, 0xD6, 0x01, 0x2F, 0x5F, 0x93, 0xC9, 0x03
    #d8 0x40, 0x80, 0xC5, 0x0D, 0x5A, 0xAC, 0x02, 0x5E, 0xBF, 0x25, 0x92, 0x05, 0x7F, 0x01, 0x8A, 0x1B
    #d8 0xB5, 0x58, 0x04, 0xBB, 0x7D, 0x4A, 0x24, 0x0A, 0xFF, 0x01, 0x13, 0x36, 0x69, 0xAF, 0x09, 0x76
    #d8 0xFA, 0x95, 0x48, 0x15, 0xFD, 0x02, 0x27, 0x6B, 0xD3, 0x5F, 0x11, 0xED, 0xF4, 0x29, 0x90, 0x29
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    #d8 0x01, 0x01, 0x01, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x03, 0x03, 0x03, 0x03, 0x04
    #d8 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x07, 0x07, 0x08, 0x08, 0x09, 0x09, 0x0A
    #d8 0x0A, 0x0B, 0x0C, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x10, 0x12, 0x13, 0x14, 0x15, 0x16, 0x18, 0x19
    #d8 0x1A, 0x1C, 0x1E, 0x20, 0x21, 0x24, 0x26, 0x28, 0x2A, 0x2D, 0x30, 0x32, 0x35, 0x39, 0x3C, 0x40
    #d8 0x00, 0x00, 0x00, 0x42, 0xF4, 0xF8, 0x90, 0x2E, 0x8B, 0x04, 0x82, 0x51, 0x41, 0x6B, 0xDA, 0x88
    #d8 0xFF, 0xFF, 0xFF, 0xB1, 0x6F, 0x4B, 0x3E, 0x35, 0x2A, 0x11, 0x08, 0x05, 0x04, 0x01, 0x00, 0x00
    #d8 0x00, 0x42, 0xA1, 0x16, 0x51, 0x53, 0xDB, 0xBA, 0x2E, 0xAC, 0xD6, 0xC6, 0x6B, 0x79, 0x49, 0x2D
    #d8 0xFF, 0xB1, 0x58, 0x3B, 0x25, 0x19, 0x14, 0x11, 0x0E, 0x05, 0x02, 0x01, 0x01, 0x00, 0x00, 0x00

; ============================================================
; the mixer: T5 groups (of four lines, two samples each; the line read
; counts them) from T2:T1 on, wrapping from x5FFF to x5DF3.  The line at
; x5DF3 is a group of its own with one sample, and then the tick.
; ============================================================
