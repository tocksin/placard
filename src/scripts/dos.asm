; ============================================================
; made by asm_expand.py from dos.masm: change that file, then run
;     python3 asm_expand.py dos.masm
; ============================================================

; ============================================================
; dos.masm - the Placard DOS: a file browser that loads, runs and saves
; programs on the SD card.  It is a program on the card itself, DOS.PLC
; ============================================================
;
; The 32K ROM's loader (rom32.masm, docs/DOS.md) loads DOS.PLC from the
; card's root folder at power-up (unless BOOT.CFG names another program,
; or there is no card: then BASIC) and again whenever a program comes back,
; and enters it with map 07 (RAM x0000-x5FFF, the library and the FAT
; writer in ROM), the card mounted and the folder it was in current.
;
;   browser      the current folder's entries, the chosen one on a blue bar.
;                Up / Down move; Enter runs a .PLC file or opens a folder;
;                Backspace goes to the folder above; Del deletes the file;
;                B writes BOOT.CFG = the chosen file (root folder only); R
;                reads the folder again (a changed card); Esc gives a
;                command line:
;                  RUN name            run a .PLC file
;                  LOAD name hhhh      load a file's bytes at a hex address
;                                      (below x3000, where the DOS is)
;                  SAVE name hhhh hhhh [hhhh]
;                                      save memory (start, length, entry =
;                                      start) as a .PLC file (gen_plc.py
;                                      has the header; start 0000 makes a
;                                      RAM image, else a library program)
;                  DEL name, CD name, BOOT name (writes BOOT.CFG), DIR,
;                  BASIC
;   running      the DOS hands the file's name to the ROM's dos_run vector
;                (x800C), which loads it over the DOS and runs it; when it
;                comes back (x8008) the ROM loads DOS.PLC again.  A file
;                that could not be run comes back with the reason in
;                MB_ERR, which the DOS shows.  The chosen entry is kept in
;                MB_SEL / MB_TOP meanwhile.
;
; RAM: this code at x3000-x3FFF (gen_plc.py: load x3000, entry main), zero
; page x20-x5F (the DOS's variables), DOS_DIR x4000-x47FF (the folder: 128
; entries of 16 bytes: name 11, attributes, size 4), DOS_LINE x4800 (the
; command line), DOS_BUF x5400-x55FF (BOOT.CFG, the header of a SAVE), the
; menu block x5D00-x5D6F and FS_VARS / FS_BUF x4D00-x4FFF (placard_fs.asm).
;
;     python3 asm_expand.py dos.masm                       writes dos.asm
;     python3 gen_plc.py dos.asm -o ../../sdcard/DOS.PLC   the card's file
;     python3 test_dos.py                     runs it with the ROM and a card image
;
; Date: 10/26/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

DOS_CODE  = 0x3000      ; this code (DOS.PLC's load address)
DOS_TOP   = 0x4000

; the 32K ROM's vectors (rom32.masm)
dos_back  = 0x8008      ; jump: a program is done (the ROM loads DOS.PLC again)
dos_run   = 0x800C      ; jump: R1:R0 = a name, run it
fs_create = 0x8010      ; the FAT writer (placard_fsw.masm): CALL these
fs_write  = 0x8014
fs_close  = 0x8018
fs_delete = 0x801C
fs_save   = 0x8020
basic     = 0x8024      ; jump: BASIC

ERR_NOTPROG = 0x80      ; MB_ERR codes besides the FAT driver's 1-14
ERR_ISDIR   = 0x81

DOS_DIR   = 0x4000      ; the folder read: 128 entries x 16 bytes
DIR_MAX   = 128
DOS_LINE  = 0x4800      ; the command line (con_gets)
DOS_BUF   = 0x5400      ; a sector: the program file's first, BOOT.CFG
MODE_BASE = 0x5A20      ; mode byte of pixel row 0 (bits 6:4 = tint)
TINT_BAR  = 0x40        ; the chosen entry: a blue bar

; MB_CHILD, MB_PARENT, MB_DCLUS, MB_FNAME: the menu block, placard_menu.asm

LIST_ROW  = 2           ; text rows of the list
LIST_N    = 50
HELP_ROW  = 53
MSG_ROW   = 55
CMD_ROW   = 57

; zero page
d_n     = 0x20          ; entries in DOS_DIR
d_sel   = 0x21          ; the chosen entry
d_top   = 0x22          ; the first entry shown
d_i     = 0x23          ; draw_list: the entry
d_row   = 0x24          ;   and its text row
d_pl    = 0x25          ; the entry's address in DOS_DIR (dir_ptr)
d_ph    = 0x26
d_t     = 0x27          ; scratch
d_t2    = 0x28
d_el    = 0x29          ; the program's entry
d_eh    = 0x2A
d_ll    = 0x2B          ; its load address (SAVE: the next source byte)
d_lh    = 0x2C
d_cl    = 0x2D          ; its length (SAVE: bytes still to write)
d_ch    = 0x2E
d_type  = 0x2F          ; its type
d_ml    = 0x31          ; bar_set: the row's first mode byte
d_mh    = 0x32
d_al    = 0x33          ; hex4: the value (SAVE: the file's size)
d_ah    = 0x34
d_pos   = 0x35          ; the command line: next character
d_len   = 0x36          ; word / hex4: characters taken
d_k     = 0x37          ; the key
d_c     = 0x38          ; a character
d_msgl  = 0x39          ; the message to show (0 = none)
d_msgh  = 0x3A
d_err   = 0x3B          ; the error code shown after it (0 = none)
d_name  = 0x40          ; 13: a name, "NAME.EXT", 0


; ============================================================
; main - the ROM's loader enters DOS.PLC here (map 07, the card mounted)
; ============================================================

#addr 0x3000
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    clr  ac
    ld   ac, [d_msgh]
    ld   ac, [d_err]
    ld   MENU_BLK >> 8, y       ; the entry chosen before the program ran
    ld   MB_SEL, x
    ld   [y,x], ac
    ld   ac, [d_sel]
    ld   MB_TOP, x
    ld   [y,x], ac
    ld   ac, [d_top]
    ld   MB_ERR, x              ; why the last program did not run
    ld   [y,x], ac
    beq  mn_go
    ld   ac, [d_err]
    ld   0, [y,x]
    ld   [d_err], ac
    xor  ERR_NOTPROG, ac
    bne  mn_1
    ld   ac, [d_err]
    ld   s_notprog & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_notprog >> 8, ac
    ld   ac, [d_msgh]
    bra  mn_go
mn_1:
    ld   [d_err], ac
    xor  ERR_ISDIR, ac
    bne  mn_2
    ld   ac, [d_err]
    ld   s_isdir & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_isdir >> 8, ac
    ld   ac, [d_msgh]
    bra  mn_go
mn_2:
    ld   s_err & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_err >> 8, ac
    ld   ac, [d_msgh]
mn_go:
    ld   [KBD_HEAD], ac         ; forget the keys pressed meanwhile
    ld   ac, [KBD_TAIL]
    ld   browser >> 8, y
    jmp  browser

mount:
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
    ld   LINK_LO, x             ; CALL sd_init
    ld   dos_r1, [x]
    ld   LINK_HI, x
    ld   dos_r1 >> 8, [x]
    ld   sd_init >> 8, y
    jmp  sd_init
dos_r1:
    bne  m_x
    ld   LINK_LO, x             ; CALL fs_mount
    ld   dos_r2, [x]
    ld   LINK_HI, x
    ld   dos_r2 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
dos_r2:
m_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

save_dclus:
    ld   3, ac
    ld   ac, [d_t]
sv_cp:
    ld   [d_t], ac
    add  V_DCLUS, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_DCLUS, x
    ld   MENU_BLK >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  sv_cp
    ld   [LINK_HI], y
    jmp  [LINK_LO]

dclus_zero:
    ld   FSV, y
    ld   V_DCLUS, x
    ld   [y,x], ac
    ld   V_DCLUS + 1, x
    or   [y,x], ac
    ld   V_DCLUS + 2, x
    or   [y,x], ac
    ld   V_DCLUS + 3, x
    or   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the browser
; ============================================================
browser:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL dir_read
    ld   dos_r3, [x]
    ld   LINK_HI, x
    ld   dos_r3 >> 8, [x]
    ld   dir_read >> 8, y
    jmp  dir_read
dos_r3:
    ld   [d_n], ac              ; keep the choice on the list
    bne  br_c1
    ld   ac, [d_sel]
    ld   ac, [d_top]
    bra  br_c3
br_c1:
    ld   [d_sel], ac
    sub  [d_n], ac
    bcs  br_c2                  ; borrow: d_sel < d_n
    ld   [d_n], ac
    dec
    ld   ac, [d_sel]
br_c2:
    ld   [d_sel], ac
    sub  [d_top], ac
    bcs  br_c4                  ; d_sel < d_top
    sub  LIST_N, ac
    bcs  br_c3                  ; on the screen
    ld   [d_sel], ac
    sub  LIST_N - 1, ac
    ld   ac, [d_top]
    bra  br_c3
br_c4:
    ld   [d_sel], ac
    ld   ac, [d_top]
br_c3:
    ld   br_draw >> 8, y
    jmp  br_draw


#addr 0x3100
br_draw:
    ld   LINK_LO, x             ; CALL draw_list
    ld   dos_r4, [x]
    ld   LINK_HI, x
    ld   dos_r4 >> 8, [x]
    ld   draw_list >> 8, y
    jmp  draw_list
dos_r4:
    ld   LINK_LO, x             ; CALL show_msg
    ld   dos_r5, [x]
    ld   LINK_HI, x
    ld   dos_r5 >> 8, [x]
    ld   show_msg >> 8, y
    jmp  show_msg
dos_r5:
br_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   dos_r6, [x]
    ld   LINK_HI, x
    ld   dos_r6 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
dos_r6:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   dos_r7, [x]
    ld   LINK_HI, x
    ld   dos_r7 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
dos_r7:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   dos_r8, [x]
    ld   LINK_HI, x
    ld   dos_r8 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
dos_r8:
    beq  br_loop
    ld   ac, [d_k]
    ld   br_key >> 8, y
    jmp  br_key

br_key:
    ld   [d_k], ac
    xor  0x11, ac               ; Up
    bne  bk_1
    ld   k_up >> 8, y
    jmp  k_up
bk_1:
    ld   [d_k], ac
    xor  0x12, ac               ; Down
    bne  bk_2
    ld   k_down >> 8, y
    jmp  k_down
bk_2:
    ld   [d_k], ac
    xor  0x0A, ac               ; Enter
    bne  bk_3
    ld   k_enter >> 8, y
    jmp  k_enter
bk_3:
    ld   [d_k], ac
    xor  0x08, ac               ; Backspace
    bne  bk_4
    ld   k_updir >> 8, y
    jmp  k_updir
bk_4:
    ld   [d_k], ac
    xor  0x7F, ac               ; Delete
    bne  bk_5
    ld   k_del >> 8, y
    jmp  k_del
bk_5:
    ld   [d_k], ac
    and  0xDF, ac               ; b or B
    xor  0x42, ac
    bne  bk_6
    ld   k_boot >> 8, y
    jmp  k_boot
bk_6:
    ld   [d_k], ac
    and  0xDF, ac               ; r or R
    xor  0x52, ac
    bne  bk_7
    ld   browser >> 8, y
    jmp  browser
bk_7:
    ld   [d_k], ac
    xor  0x1B, ac               ; Esc
    bne  bk_8
    ld   k_cmd >> 8, y
    jmp  k_cmd
bk_8:
    ld   br_loop >> 8, y
    jmp  br_loop

k_up:
    ld   [d_sel], ac
    beq  ku_none
    clr  ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r9, [x]
    ld   LINK_HI, x
    ld   dos_r9 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r9:
    ld   [d_sel], ac
    dec
    ld   ac, [d_sel]
    sub  [d_top], ac
    bcs  ku_scroll              ; above the screen
    ld   TINT_BAR, ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r10, [x]
    ld   LINK_HI, x
    ld   dos_r10 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r10:
ku_none:
    ld   br_loop >> 8, y
    jmp  br_loop
ku_scroll:
    ld   [d_sel], ac
    ld   ac, [d_top]
    ld   br_draw >> 8, y
    jmp  br_draw

k_updir:
    ld   LINK_LO, x             ; CALL dclus_zero
    ld   dos_r15, [x]
    ld   LINK_HI, x
    ld   dos_r15 >> 8, [x]
    ld   dclus_zero >> 8, y
    jmp  dclus_zero
dos_r15:
    beq  kud_none
    ld   0x2E, ac               ; ".."
    ld   ac, [d_name]
    ld   ac, [d_name + 1]
    clr  ac
    ld   ac, [d_name + 2]
    ld   cd_name >> 8, y
    jmp  cd_name
kud_none:
    ld   br_loop >> 8, y
    jmp  br_loop

fail:
    ld   ac, [d_err]
    ld   s_err & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_err >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser

; ============================================================
; the command line (Esc)
; ============================================================
k_down:
    ld   [d_sel], ac
    inc
    sub  [d_n], ac
    bcc  kd_none                ; no borrow: the last one already
    clr  ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r11, [x]
    ld   LINK_HI, x
    ld   dos_r11 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r11:
    ld   [d_sel], ac
    inc
    ld   ac, [d_sel]
    sub  [d_top], ac
    sub  LIST_N, ac
    bcc  kd_scroll              ; below the screen
    ld   TINT_BAR, ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r12, [x]
    ld   LINK_HI, x
    ld   dos_r12 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r12:
kd_none:
    ld   br_loop >> 8, y
    jmp  br_loop
kd_scroll:
    ld   [d_sel], ac
    sub  LIST_N - 1, ac
    ld   ac, [d_top]
    ld   br_draw >> 8, y
    jmp  br_draw

k_enter:
    ld   [d_n], ac
    beq  ke_none
    ld   [d_sel], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r13, [x]
    ld   LINK_HI, x
    ld   dos_r13 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r13:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r14, [x]
    ld   LINK_HI, x
    ld   dos_r14 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r14:
    ld   [d_ph], y
    ld   [d_pl], ac
    add  11, x
    ld   [y,x], ac
    and  0x10, ac
    bne  ke_dir
    ld   [d_pl], ac             ; .PLC?
    add  8, x
    ld   [y,x], ac
    xor  0x50, ac
    bne  ke_notp
    ld   [d_pl], ac
    add  9, x
    ld   [y,x], ac
    xor  0x4C, ac
    bne  ke_notp
    ld   [d_pl], ac
    add  10, x
    ld   [y,x], ac
    xor  0x43, ac
    bne  ke_notp
    ld   run_name >> 8, y
    jmp  run_name
ke_notp:
    ld   s_notprog & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_notprog >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
ke_dir:
    ld   cd_name >> 8, y
    jmp  cd_name
ke_none:
    ld   br_loop >> 8, y
    jmp  br_loop

k_del:
    ld   [d_n], ac
    beq  kdl_none
    ld   [d_sel], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r16, [x]
    ld   LINK_HI, x
    ld   dos_r16 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r16:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r17, [x]
    ld   LINK_HI, x
    ld   dos_r17 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r17:
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_delete
    ld   dos_r18, [x]
    ld   LINK_HI, x
    ld   dos_r18 >> 8, [x]
    ld   fs_delete >> 8, y
    jmp  fs_delete
dos_r18:
    bne  kdl_err
    ld   s_deleted & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_deleted >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
kdl_err:
    ld   fail >> 8, y
    jmp  fail
kdl_none:
    ld   br_loop >> 8, y
    jmp  br_loop

run_name:
    ld   MENU_BLK >> 8, y
    ld   MB_SEL, x
    ld   [d_sel], ac
    ld   ac, [y,x]
    ld   MB_TOP, x
    ld   [d_top], ac
    ld   ac, [y,x]
    ld   MB_MODE, x
    ld   1, [y,x]
    ld   MB_WHY, x
    ld   0, [y,x]
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   dos_run >> 8, y
    jmp  dos_run


#addr 0x3300
k_boot:
    ld   [d_n], ac
    beq  kbt_none
    ld   [d_sel], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r19, [x]
    ld   LINK_HI, x
    ld   dos_r19 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r19:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r20, [x]
    ld   LINK_HI, x
    ld   dos_r20 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r20:
    ld   boot_name >> 8, y
    jmp  boot_name
kbt_none:
    ld   br_loop >> 8, y
    jmp  br_loop

cd_name:
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   dos_r21, [x]
    ld   LINK_HI, x
    ld   dos_r21 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
dos_r21:
    bne  cd_err
    ld   FSV, y                 ; a folder?
    ld   V_ENTRY + 11, x
    ld   [y,x], ac
    and  0x10, ac
    beq  cd_file
    ld   LINK_LO, x             ; CALL dclus_zero
    ld   dos_r22, [x]
    ld   LINK_HI, x
    ld   dos_r22 >> 8, [x]
    ld   dclus_zero >> 8, y
    jmp  dclus_zero
dos_r22:
    bne  cd_named
    ld   0x5C, ac               ; the root: "\"
    ld   ac, [d_name]
    clr  ac
    ld   ac, [d_name + 1]
cd_named:
    ld   LINK_LO, x             ; the ROM's loader comes back to this folder
    ld   dos_r23, [x]
    ld   LINK_HI, x
    ld   dos_r23 >> 8, [x]
    ld   save_dclus >> 8, y
    jmp  save_dclus
dos_r23:
    ld   12, ac                 ; MB_FNAME = d_name
    ld   ac, [d_t]
cd_cp:
    ld   [d_t], ac
    add  d_name, x
    ld   [x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_FNAME, x
    ld   MENU_BLK >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  cd_cp
    clr  ac
    ld   ac, [d_sel]
    ld   ac, [d_top]
    ld   browser >> 8, y
    jmp  browser
cd_file:
    ld   s_notdir & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_notdir >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
cd_err:
    ld   fail >> 8, y
    jmp  fail

cmd_dispatch2:
    ld   s_boot & 0xFF, ac
    ld   ac, [R0]
    ld   s_boot >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r36, [x]
    ld   LINK_HI, x
    ld   dos_r36 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r36:
    bne  cm_6
    ld   c_boot >> 8, y
    jmp  c_boot
cm_6:
    ld   s_dirc & 0xFF, ac
    ld   ac, [R0]
    ld   s_dirc >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r37, [x]
    ld   LINK_HI, x
    ld   dos_r37 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r37:
    bne  cm_7
    ld   browser >> 8, y
    jmp  browser
cm_7:
    ld   s_basicc & 0xFF, ac
    ld   ac, [R0]
    ld   s_basicc >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r38, [x]
    ld   LINK_HI, x
    ld   dos_r38 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r38:
    bne  cm_8
    ld   basic >> 8, y
    jmp  basic
cm_8:
    ld   s_unknown & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_unknown >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw


#addr 0x3400
boot_name:
    ld   LINK_LO, x             ; CALL dclus_zero
    ld   dos_r24, [x]
    ld   LINK_HI, x
    ld   dos_r24 >> 8, [x]
    ld   dclus_zero >> 8, y
    jmp  dclus_zero
dos_r24:
    bne  bn_root
    clr  ac                     ; DOS_BUF = the name, CR, LF
    ld   ac, [d_t]
bn_cp:
    ld   [d_t], ac
    add  d_name, x
    ld   [x], ac
    beq  bn_e
    ld   ac, [d_c]
    ld   [d_t], x
    ld   DOS_BUF >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    bra  bn_cp
bn_e:
    ld   [d_t], x
    ld   DOS_BUF >> 8, y
    ld   0x0D, [y,x]
    ld   [d_t], ac
    inc
    ld   ac, x
    ld   0x0A, [y,x]
    inc
    ld   ac, [R2]               ; the length
    clr  ac
    ld   ac, [R3]
    ld   s_cfg & 0xFF, ac
    ld   ac, [R0]
    ld   s_cfg >> 8, ac
    ld   ac, [R1]
    ld   DOS_BUF & 0xFF, ac
    ld   ac, [R4]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_save
    ld   dos_r25, [x]
    ld   LINK_HI, x
    ld   dos_r25 >> 8, [x]
    ld   fs_save >> 8, y
    jmp  fs_save
dos_r25:
    bne  bn_err
    ld   s_boots & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_boots >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
bn_root:
    ld   s_rootonly & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_rootonly >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
bn_err:
    ld   fail >> 8, y
    jmp  fail

k_cmd:
    ld   CMD_ROW, ac
    ld   LINK_LO, x             ; CALL clr_row
    ld   dos_r26, [x]
    ld   LINK_HI, x
    ld   dos_r26 >> 8, [x]
    ld   clr_row >> 8, y
    jmp  clr_row
dos_r26:
    ld   CMD_ROW + 1, ac
    ld   LINK_LO, x             ; CALL clr_row
    ld   dos_r27, [x]
    ld   LINK_HI, x
    ld   dos_r27 >> 8, [x]
    ld   clr_row >> 8, y
    jmp  clr_row
dos_r27:
    ld   CMD_ROW, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_prompt & 0xFF, ac
    ld   ac, [R0]
    ld   s_prompt >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r28, [x]
    ld   LINK_HI, x
    ld   dos_r28 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r28:
    ld   DOS_LINE & 0xFF, ac
    ld   ac, [R0]
    ld   DOS_LINE >> 8, ac
    ld   ac, [R1]
    ld   60, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL con_gets
    ld   dos_r29, [x]
    ld   LINK_HI, x
    ld   dos_r29 >> 8, [x]
    ld   con_gets >> 8, y
    jmp  con_gets
dos_r29:
    clr  ac
    ld   ac, [d_pos]
    ld   LINK_LO, x             ; CALL word
    ld   dos_r30, [x]
    ld   LINK_HI, x
    ld   dos_r30 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r30:
    beq  kc_dir
    ld   cmd_dispatch >> 8, y
    jmp  cmd_dispatch
kc_dir:
    ld   browser >> 8, y
    jmp  browser

c_run:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r39, [x]
    ld   LINK_HI, x
    ld   dos_r39 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r39:
    beq  cr_name
    ld   run_name >> 8, y
    jmp  run_name
cr_name:
    ld   need_name >> 8, y
    jmp  need_name


#addr 0x3500
cmd_dispatch:
    ld   s_run & 0xFF, ac
    ld   ac, [R0]
    ld   s_run >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r31, [x]
    ld   LINK_HI, x
    ld   dos_r31 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r31:
    bne  cm_1
    ld   c_run >> 8, y
    jmp  c_run
cm_1:
    ld   s_load & 0xFF, ac
    ld   ac, [R0]
    ld   s_load >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r32, [x]
    ld   LINK_HI, x
    ld   dos_r32 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r32:
    bne  cm_2
    ld   c_load >> 8, y
    jmp  c_load
cm_2:
    ld   s_save & 0xFF, ac
    ld   ac, [R0]
    ld   s_save >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r33, [x]
    ld   LINK_HI, x
    ld   dos_r33 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r33:
    bne  cm_3
    ld   c_save >> 8, y
    jmp  c_save
cm_3:
    ld   s_del & 0xFF, ac
    ld   ac, [R0]
    ld   s_del >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r34, [x]
    ld   LINK_HI, x
    ld   dos_r34 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r34:
    bne  cm_4
    ld   c_del >> 8, y
    jmp  c_del
cm_4:
    ld   s_cd & 0xFF, ac
    ld   ac, [R0]
    ld   s_cd >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r35, [x]
    ld   LINK_HI, x
    ld   dos_r35 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r35:
    bne  cm_5
    ld   c_cd >> 8, y
    jmp  c_cd
cm_5:
    ld   cmd_dispatch2 >> 8, y
    jmp  cmd_dispatch2

c_del:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r40, [x]
    ld   LINK_HI, x
    ld   dos_r40 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r40:
    beq  cdl_name
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_delete
    ld   dos_r41, [x]
    ld   LINK_HI, x
    ld   dos_r41 >> 8, [x]
    ld   fs_delete >> 8, y
    jmp  fs_delete
dos_r41:
    bne  cdl_err
    ld   s_deleted & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_deleted >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
cdl_err:
    ld   fail >> 8, y
    jmp  fail
cdl_name:
    ld   need_name >> 8, y
    jmp  need_name
c_cd:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r42, [x]
    ld   LINK_HI, x
    ld   dos_r42 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r42:
    beq  cdl_name
    ld   cd_name >> 8, y
    jmp  cd_name
c_boot:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r43, [x]
    ld   LINK_HI, x
    ld   dos_r43 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r43:
    beq  cdl_name
    ld   boot_name >> 8, y
    jmp  boot_name

need_name:
    ld   s_name & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_name >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
need_hex:
    ld   s_syntax & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_syntax >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw


#addr 0x3600
c_load:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r44, [x]
    ld   LINK_HI, x
    ld   dos_r44 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r44:
    beq  cl_name
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r45, [x]
    ld   LINK_HI, x
    ld   dos_r45 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r45:
    bne  cl_hex
    ld   [d_ah], ac             ; not over the DOS
    sub  DOS_CODE >> 8, ac
    sub  (DOS_TOP - DOS_CODE) >> 8, ac
    bcs  cl_dos                 ; borrow: x30-x3F
    ld   [d_al], ac
    ld   ac, [R4]
    ld   [d_ah], ac
    ld   ac, [R5]
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_load
    ld   dos_r46, [x]
    ld   LINK_HI, x
    ld   dos_r46 >> 8, [x]
    ld   fs_load >> 8, y
    jmp  fs_load
dos_r46:
    bne  cl_err
    ld   s_loaded & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_loaded >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
cl_err:
    ld   fail >> 8, y
    jmp  fail
cl_name:
    ld   need_name >> 8, y
    jmp  need_name
cl_hex:
    ld   need_hex >> 8, y
    jmp  need_hex
cl_dos:
    ld   s_dosmem & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_dosmem >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw

c_save:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r47, [x]
    ld   LINK_HI, x
    ld   dos_r47 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r47:
    beq  cs_name
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r48, [x]
    ld   LINK_HI, x
    ld   dos_r48 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r48:
    bne  cs_hex
    ld   [d_al], ac
    ld   ac, [d_ll]
    ld   ac, [d_el]
    ld   [d_ah], ac
    ld   ac, [d_lh]
    ld   ac, [d_eh]
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r49, [x]
    ld   LINK_HI, x
    ld   dos_r49 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r49:
    bne  cs_hex
    ld   [d_al], ac
    ld   ac, [d_cl]
    ld   [d_ah], ac
    ld   ac, [d_ch]
    ld   [d_cl], ac
    or   [d_ch], ac
    beq  cs_hex                 ; a length of 0
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r50, [x]
    ld   LINK_HI, x
    ld   dos_r50 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r50:
    bne  cs_go                  ; no entry given: the start
    ld   [d_al], ac
    ld   ac, [d_el]
    ld   [d_ah], ac
    ld   ac, [d_eh]
cs_go:
    ld   save_plc >> 8, y
    jmp  save_plc
cs_name:
    ld   need_name >> 8, y
    jmp  need_name
cs_hex:
    ld   need_hex >> 8, y
    jmp  need_hex

dir_ptr:
    ld   ac, [d_t]
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  DOS_DIR >> 8, ac
    ld   ac, [d_ph]
    ld   [d_t], ac
    shl
    shl
    shl
    shl
    ld   ac, [d_pl]
    ld   [LINK_HI], y
    jmp  [LINK_LO]


#addr 0x3700
        ; d_eh:d_el entry: the header, then create / write / close
save_plc:
    ld   DOS_BUF >> 8, y
    ld   0, x
    ld   0x50, [y,x]            ; "PLC"
    ld   1, x
    ld   0x4C, [y,x]
    ld   2, x
    ld   0x43, [y,x]
    ld   [d_lh], ac             ; type: 1 when the start is 0000
    or   [d_ll], ac
    bne  sp_t0
    ld   1, ac
    bra  sp_ty
sp_t0:
    clr  ac
sp_ty:
    ld   3, x
    ld   ac, [y,x]
    ld   4, x
    ld   [d_ll], ac
    ld   ac, [y,x]
    ld   5, x
    ld   [d_lh], ac
    ld   ac, [y,x]
    ld   6, x
    ld   [d_cl], ac
    ld   ac, [y,x]
    ld   7, x
    ld   [d_ch], ac
    ld   ac, [y,x]
    ld   8, x
    ld   [d_el], ac
    ld   ac, [y,x]
    ld   9, x
    ld   [d_eh], ac
    ld   ac, [y,x]
    ld   10, x                  ; bytes 10-15 = 0
    ld   0, [y,x]
    ld   11, x
    ld   0, [y,x]
    ld   12, x
    ld   0, [y,x]
    ld   13, x
    ld   0, [y,x]
    ld   14, x
    ld   0, [y,x]
    ld   15, x
    ld   0, [y,x]
sp_cp:
    ld   [d_ll], ac             ; the first 496 bytes after the header
    ld   ac, [R0]
    ld   [d_lh], ac
    ld   ac, [R1]
    ld   (DOS_BUF & 0xFF) + 16, ac
    ld   ac, [R2]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R3]
    clr  ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   dos_r51, [x]
    ld   LINK_HI, x
    ld   dos_r51 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r51:
    ld   240, ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   dos_r52, [x]
    ld   LINK_HI, x
    ld   dos_r52 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r52:
    ld   [R0], ac               ; the next source byte
    ld   ac, [d_ll]
    ld   [R1], ac
    ld   ac, [d_lh]
    ld   sp_write >> 8, y
    jmp  sp_write

        ; left out), d_n = how many.  AC = 0, or the error (also shown)
dir_read:
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
    ld   ac, [d_n]
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    bne  dr_ok
    ld   LINK_LO, x             ; no card yet
    ld   dos_r57, [x]
    ld   LINK_HI, x
    ld   dos_r57 >> 8, [x]
    ld   mount >> 8, y
    jmp  mount
dos_r57:
    bne  dr_nocard
dr_ok:
    ld   LINK_LO, x             ; CALL fs_cwd
    ld   dos_r58, [x]
    ld   LINK_HI, x
    ld   dos_r58 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
dos_r58:
    bne  dr_fail
    ld   dr_next >> 8, y
    jmp  dr_next
dr_nocard:
    ld   ac, [d_err]
    ld   s_nocard & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_nocard >> 8, ac
    ld   ac, [d_msgh]
    ld   lib_leave >> 8, y
    jmp  lib_leave
dr_fail:
    ld   ac, [d_err]
    ld   s_err & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_err >> 8, ac
    ld   ac, [d_msgh]
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0x3800
sp_write:
    ld   [d_cl], ac             ; the file's size = length + 16
    add  16, ac
    ld   ac, [d_cl]
    ld   ac, [d_al]
    ld   [d_ch], ac
    bcc  sp_w1
    inc
    ld   ac, [d_ch]
sp_w1:
    ld   ac, [d_ah]
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_create
    ld   dos_r53, [x]
    ld   LINK_HI, x
    ld   dos_r53 >> 8, [x]
    ld   fs_create >> 8, y
    jmp  fs_create
dos_r53:
    bne  sp_err
    ld   DOS_BUF & 0xFF, ac     ; the first sector
    ld   ac, [R4]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_write
    ld   dos_r54, [x]
    ld   LINK_HI, x
    ld   dos_r54 >> 8, [x]
    ld   fs_write >> 8, y
    jmp  fs_write
dos_r54:
    bne  sp_err
sp_more:
    ld   [d_ch], ac             ; 512 bytes written: more?
    sub  2, ac
    bcs  sp_close
    ld   ac, [d_ch]
    or   [d_cl], ac
    beq  sp_close
    ld   [d_ll], ac
    ld   ac, [R4]
    ld   [d_lh], ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_write
    ld   dos_r55, [x]
    ld   LINK_HI, x
    ld   dos_r55 >> 8, [x]
    ld   fs_write >> 8, y
    jmp  fs_write
dos_r55:
    bne  sp_err
    ld   [R4], ac
    ld   ac, [d_ll]
    ld   [R5], ac
    ld   ac, [d_lh]
    bra  sp_more
sp_close:
    ld   [d_al], ac
    ld   ac, [R0]
    ld   [d_ah], ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R2]
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL fs_close
    ld   dos_r56, [x]
    ld   LINK_HI, x
    ld   dos_r56 >> 8, [x]
    ld   fs_close >> 8, y
    jmp  fs_close
dos_r56:
    bne  sp_err
    ld   s_saved & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_saved >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
sp_err:
    ld   fail >> 8, y
    jmp  fail

; ============================================================
; the folder: dir_read, dir_ptr, ent_name
; ============================================================
dl_list:
    ld   [d_i], ac
    xor  [d_n], ac
    beq  dl_done
    ld   [d_row], ac
    xor  LIST_ROW + LIST_N, ac
    beq  dl_done
    ld   LINK_LO, x             ; CALL show_ent
    ld   dos_r65, [x]
    ld   LINK_HI, x
    ld   dos_r65 >> 8, [x]
    ld   show_ent >> 8, y
    jmp  show_ent
dos_r65:
    ld   [d_i], ac
    inc
    ld   ac, [d_i]
    ld   [d_row], ac
    inc
    ld   ac, [d_row]
    bra  dl_list
dl_done:
    ld   [d_n], ac
    beq  dl_x
    ld   TINT_BAR, ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r66, [x]
    ld   LINK_HI, x
    ld   dos_r66 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r66:
dl_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

streq:
    clr  ac
    ld   ac, [d_t]
sq_l:
    ld   [R1], y
    ld   [R0], ac
    add  [d_t], x
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  d_name, x
    ld   [x], ac
    xor  [d_c], ac
    bne  sq_ne
    ld   [d_c], ac
    beq  sq_eq
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    bra  sq_l
sq_ne:
    ld   1, ac
sq_eq:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; strings
; ============================================================

#addr 0x3900
dr_next:
    ld   LINK_LO, x             ; CALL fs_next
    ld   dos_r59, [x]
    ld   LINK_HI, x
    ld   dos_r59 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
dos_r59:
    bne  dr_end
    ld   FSV, y                 ; "." and "..": left out
    ld   V_ENTRY, x
    ld   [y,x], ac
    xor  0x2E, ac
    beq  dr_next
    ld   [d_n], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r60, [x]
    ld   LINK_HI, x
    ld   dos_r60 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r60:
    ld   11, ac                 ; name and attributes
    ld   ac, [d_t]
drd_cp:
    ld   [d_t], ac
    add  V_ENTRY, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_pl], ac
    add  [d_t], x
    ld   [d_ph], y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  drd_cp
    ld   3, ac                  ; the size
    ld   ac, [d_t]
dr_sz:
    ld   [d_t], ac
    add  V_ENTRY + 28, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_pl], ac
    add  12, ac
    add  [d_t], x
    ld   [d_ph], y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  dr_sz
    ld   [d_n], ac
    inc
    ld   ac, [d_n]
    xor  DIR_MAX, ac
    bne  dr_next
    ld   1, ac                  ; full: as the end
dr_end:
    xor  1, ac                  ; 1 is the end
    beq  dr_done
    xor  1, ac
    ld   dr_fail >> 8, y
    jmp  dr_fail
dr_done:
    ld   lib_leave >> 8, y
    jmp  lib_leave

ent_name:
    clr  ac
    ld   ac, [d_t]              ; the entry's character
    ld   ac, [d_t2]             ; the name's
en_b:
    ld   [d_ph], y
    ld   [d_pl], ac
    add  [d_t], x
    ld   [y,x], ac
    xor  0x20, ac
    beq  en_ext
    xor  0x20, ac
    ld   ac, [d_c]
    ld   [d_t2], ac
    add  d_name, x
    ld   [d_c], ac
    ld   ac, [x]
    ld   [d_t2], ac
    inc
    ld   ac, [d_t2]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    xor  8, ac
    bne  en_b
en_ext:
    ld   8, ac
    ld   ac, [d_t]
    ld   [d_ph], y
    ld   [d_pl], ac
    add  8, x
    ld   [y,x], ac
    xor  0x20, ac
    beq  en_end
    ld   [d_t2], ac
    add  d_name, x
    ld   0x2E, [x]
    ld   [d_t2], ac
    inc
    ld   ac, [d_t2]
en_e:
    ld   [d_ph], y
    ld   [d_pl], ac
    add  [d_t], x
    ld   [y,x], ac
    xor  0x20, ac
    beq  en_end
    xor  0x20, ac
    ld   ac, [d_c]
    ld   [d_t2], ac
    add  d_name, x
    ld   [d_c], ac
    ld   ac, [x]
    ld   [d_t2], ac
    inc
    ld   ac, [d_t2]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    xor  11, ac
    bne  en_e
en_end:
    ld   [d_t2], ac
    add  d_name, x
    ld   0, [x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the screen: draw_list, show_ent, bar_set, show_msg, clr_row
; ============================================================

#addr 0x3A00
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
    ld   LINK_LO, x             ; CALL con_clear
    ld   dos_r61, [x]
    ld   LINK_HI, x
    ld   dos_r61 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
dos_r61:
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r62, [x]
    ld   LINK_HI, x
    ld   dos_r62 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r62:
    ld   MB_FNAME, ac
    ld   ac, [R0]
    ld   MENU_BLK >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r63, [x]
    ld   LINK_HI, x
    ld   dos_r63 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r63:
    ld   HELP_ROW, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_help & 0xFF, ac
    ld   ac, [R0]
    ld   s_help >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r64, [x]
    ld   LINK_HI, x
    ld   dos_r64 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r64:
    ld   [d_top], ac
    ld   ac, [d_i]
    ld   LIST_ROW, ac
    ld   ac, [d_row]
    ld   dl_list >> 8, y
    jmp  dl_list

; a leaf)
bar_set:
    ld   ac, [d_t2]
    ld   [d_sel], ac
    sub  [d_top], ac
    add  LIST_ROW + 4, ac       ; MODE_BASE + 8 * row = x5A00 + 8 * (row + 4)
    ld   ac, [d_t]
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  MODE_BASE >> 8, ac
    ld   ac, [d_mh]
    ld   [d_t], ac
    shl
    shl
    shl
    ld   ac, [d_ml]
    ld   7, ac
    ld   ac, [d_t]
bs_l:
    ld   [d_mh], y
    ld   [d_ml], ac
    add  [d_t], x
    ld   [d_t2], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  bs_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

clr_row:
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
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   79, ac
    ld   ac, [d_t]
cr_l:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   dos_r77, [x]
    ld   LINK_HI, x
    ld   dos_r77 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
dos_r77:
    ld   [d_t], ac
    dec
    ld   ac, [d_t]
    bne  cr_l
    clr  ac
    ld   ac, [CUR_COL]
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; the command line's words: word, hex4, streq
; ============================================================
s_notdir:   #d "Not a folder", 0x00
s_deleted:  #d "Deleted", 0x00
s_prompt:   #d "> ", 0x00
s_cfg:      #d "BOOT.CFG", 0x00


#addr 0x3B00
show_ent:
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
    ld   [d_row], ac
    ld   ac, [CUR_ROW]
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   [d_i], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r67, [x]
    ld   LINK_HI, x
    ld   dos_r67 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r67:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r68, [x]
    ld   LINK_HI, x
    ld   dos_r68 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r68:
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r69, [x]
    ld   LINK_HI, x
    ld   dos_r69 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r69:
    ld   16, ac
    ld   ac, [CUR_COL]
    ld   [d_ph], y
    ld   [d_pl], ac
    add  11, x
    ld   [y,x], ac
    and  0x10, ac
    bne  se_dir
    ld   [d_pl], ac
    add  14, x
    ld   [y,x], ac
    ld   ac, [d_t]
    ld   [d_pl], ac
    add  15, x
    ld   [y,x], ac
    or   [d_t], ac
    bne  se_big
    ld   [d_pl], ac
    add  12, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [d_pl], ac
    add  13, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_dec16
    ld   dos_r70, [x]
    ld   LINK_HI, x
    ld   dos_r70 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
dos_r70:
    ld   lib_leave >> 8, y
    jmp  lib_leave
se_dir:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r71, [x]
    ld   LINK_HI, x
    ld   dos_r71 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r71:
    ld   lib_leave >> 8, y
    jmp  lib_leave
se_big:
    ld   s_big & 0xFF, ac
    ld   ac, [R0]
    ld   s_big >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r72, [x]
    ld   LINK_HI, x
    ld   dos_r72 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r72:
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0x3C00
        ; MSG_ROW, then none
show_msg:
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
    ld   [d_msgh], ac
    beq  sm_x
    ld   MSG_ROW, ac
    ld   LINK_LO, x             ; CALL clr_row
    ld   dos_r73, [x]
    ld   LINK_HI, x
    ld   dos_r73 >> 8, [x]
    ld   clr_row >> 8, y
    jmp  clr_row
dos_r73:
    ld   [d_msgl], ac
    ld   ac, [R0]
    ld   [d_msgh], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r74, [x]
    ld   LINK_HI, x
    ld   dos_r74 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r74:
    ld   [d_err], ac
    beq  sm_c
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   dos_r75, [x]
    ld   LINK_HI, x
    ld   dos_r75 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
dos_r75:
    ld   [d_err], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   dos_r76, [x]
    ld   LINK_HI, x
    ld   dos_r76 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
dos_r76:
sm_c:
    clr  ac
    ld   ac, [d_msgh]
    ld   ac, [d_err]
sm_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

        ; case (12 characters at most); AC = its length (a leaf)
word:
    clr  ac
    ld   ac, [d_len]
w_sk:
    ld   DOS_LINE >> 8, y
    ld   [d_pos], x
    ld   [y,x], ac
    xor  0x20, ac
    bne  w_cp
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    bra  w_sk
w_cp:
    ld   [d_pos], x
    ld   [y,x], ac
    beq  w_end
    xor  0x20, ac
    beq  w_end
    xor  0x20, ac
    ld   ac, [d_c]
    sub  0x61, ac               ; a-z to A-Z
    blt  w_st
    ld   [d_c], ac
    sub  0x7B, ac
    bcc  w_st
    ld   [d_c], ac
    sub  0x20, ac
    ld   ac, [d_c]
w_st:
    ld   [d_len], ac
    xor  12, ac
    beq  w_skip
    ld   [d_len], ac
    add  d_name, x
    ld   [d_c], ac
    ld   ac, [x]
    ld   [d_len], ac
    inc
    ld   ac, [d_len]
w_skip:
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    ld   DOS_LINE >> 8, y
    bra  w_cp
w_end:
    ld   [d_len], ac
    add  d_name, x
    ld   0, [x]
    ld   [d_len], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]


#addr 0x3D00
        ; AC = 0, or 1 with no digits (a leaf)
hex4:
    clr  ac
    ld   ac, [d_al]
    ld   ac, [d_ah]
    ld   ac, [d_len]
h_sk:
    ld   DOS_LINE >> 8, y
    ld   [d_pos], x
    ld   [y,x], ac
    xor  0x20, ac
    bne  h_d
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    bra  h_sk
h_d:
    ld   [d_pos], x
    ld   [y,x], ac
    ld   ac, [d_c]
    sub  0x61, ac               ; a-f to A-F
    blt  h_d1
    ld   [d_c], ac
    sub  0x20, ac
    ld   ac, [d_c]
h_d1:
    ld   [d_c], ac
    sub  0x30, ac
    blt  h_end
    ld   ac, [d_c]              ; 0-9?
    sub  10, ac
    blt  h_dig
    ld   [d_c], ac
    sub  17, ac                 ; A-F?
    blt  h_end
    add  10, ac
    ld   ac, [d_c]
    sub  16, ac
    blt  h_dig
    bra  h_end
h_dig:
    ld   [d_ah], ac
    shl
    shl
    shl
    shl
    ld   ac, [d_ah]
    ld   [d_al], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    or   [d_ah], ac
    ld   ac, [d_ah]
    ld   [d_al], ac
    shl
    shl
    shl
    shl
    or   [d_c], ac
    ld   ac, [d_al]
    ld   [d_len], ac
    inc
    ld   ac, [d_len]
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    ld   DOS_LINE >> 8, y
    bra  h_d
h_end:
    ld   [d_len], ac
    beq  h_bad
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
h_bad:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

s_loaded:   #d "Loaded", 0x00
s_saved:    #d "Saved", 0x00
s_run:      #d "RUN", 0x00
s_load:     #d "LOAD", 0x00
s_save:     #d "SAVE", 0x00
s_del:      #d "DEL", 0x00
s_cd:       #d "CD", 0x00
s_boot:     #d "BOOT", 0x00
s_dirc:     #d "DIR", 0x00
s_basicc:   #d "BASIC", 0x00
s_dosmem:   #d "x3000-x3FFF holds the DOS: load below it", 0x00

#addr 0x3E00
s_title:    #d "PLACARD DOS    folder ", 0x00
s_hold:     #d "Hold Esc for the file browser", 0x00
s_help:     #d "Up/Down move  Enter run/open  Bksp up  Del delete  B boot  R reread  Esc command", 0x00
s_dir:      #d "<DIR>", 0x00
s_big:      #d ">64K", 0x00
s_err:      #d "Error", 0x00
s_nocard:   #d "No SD card: insert one and press R", 0x00
s_notprog:  #d "Not a program (.PLC)", 0x00
s_isdir:    #d "That is a folder", 0x00


#addr 0x3F00
s_boots:    #d "BOOT.CFG written: that program runs at power-up (hold Esc for the browser)", 0x00
s_rootonly: #d "BOOT.CFG is read from the root folder: go there first", 0x00
s_unknown:  #d "Commands: RUN LOAD SAVE DEL CD BOOT DIR BASIC", 0x00
s_name:     #d "Which file?", 0x00
s_syntax:   #d "LOAD name hhhh   SAVE name hhhh(start) hhhh(length) [hhhh(entry)]", 0x00

