; ============================================================
; made by asm_expand.py from photo.masm: change that file, then run
;     python3 asm_expand.py photo.masm
; ============================================================

; ============================================================
; photo.masm - PHOTO.PLC: shows the pictures in the card's PHOTOS folder
; ============================================================
;
; A library program the DOS runs from the card (Enter on PHOTO.PLC in the
; browser, or BOOT.CFG = "PHOTO.PLC").  It opens the folder PHOTOS in the
; card's root and shows its .PIC files one at a time, in the order they
; are in the folder.
;
; A .PIC file is the video RAM x6000-xFFFF as it is: 40,960 bytes, 80
; sectors, which fs_read puts straight on the screen (about 0.6 s; the
; picture comes in from the left).  gen_photos.py makes the files from
; photographs: 160 x 240 pixels, 256 colors, for a screen of 160-read
; rows with 2x line repeat on a rev B board (mode byte x87,
; docs/video/HIRES.md).
;
; A rev A board has no 160-read rows (bit 7 of the mode byte is its blank
; line), so the program asks first.  With mode byte x07 (a normal 8 bpp
; row, 2x) a board reads the odd byte columns of the same file: the
; picture 80 pixels across, on either board.
;
;     H           at the start: 160 across (rev B).  Any other key: 80
;                 across.  While a picture shows: change between the two
;     Space, Right, Enter    the next picture
;     Left, Backspace        the picture before
;     S           slide show on or off (a picture about every 9 seconds)
;     Esc         back to the DOS (menu_poll)
;
; Pinboard's Files card runs it for a .PIC file in any folder (MB_PHOTO =
; "V" and a parent to go back to): the pictures are then that folder's
; (MB_PCLUS), the first one shown is the one chosen (MB_PN: its number
; among the folder's .PIC files), and Esc goes back to Pinboard.  It asks
; H or not only until it has been told once (MB_PWIDE keeps the rows' mode
; byte until power-off; Pinboard sets it in a color mode, which only a
; rev B board shows).
;
; RAM: the program at x0100 (asm_expand.py pages it), zero page x20-x3F.
; The whole video RAM is the picture.
;
;     python3 asm_expand.py photo.masm                photo.asm
;     python3 gen_plc.py photo.asm -o ../../sdcard/PHOTO.PLC
;     python3 gen_photos.py                           sdcard/PHOTOS/*.PIC
;     python3 test_photo.py                           runs it in placard_sim
;
; Date: 11/22/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

ph_n    = 0x20              ; the picture shown, 0 = the folder's first
ph_tot  = 0x21              ; pictures in the folder
ph_k    = 0x22              ; counter
ph_mode = 0x23              ; the rows' mode byte: MODE_160 or MODE_80
ph_t    = 0x24              ; scratch
ph_d    = 0x25              ; scratch
ph_show = 0x26              ; 1: slide show
ph_tl   = 0x27              ; frames since the picture came up
ph_th   = 0x28
ph_key  = 0x29              ; the key
ph_dc   = 0x2A              ; 4: the pictures' folder (its first cluster)
ph_from = 0x2E              ; 1: Pinboard's Files card asked for a picture
ph_name = 0x30              ; the file's name, "NAME.PIC", 00 (13 bytes)

MODE_160  = 0x87            ; 160-read row, 2x, 8 bits per pixel (rev B)
MODE_80   = 0x07            ; normal row, 2x, 8 bits per pixel
SECTORS   = 80              ; a picture: x6000-xFFFF
SHOW_HI   = 2               ; slide show: 2 x 256 frames a picture
FE_LO     = FS_ENTRY & 0xFF

; the menu block's bytes for Pinboard and this program (placard_menu.asm)
MB_PWIDE  = 0x1A            ; the rows' mode byte last used, 0: not chosen yet
MB_PCLUS  = 0x1B            ; 4: the folder of the picture asked for
MB_PN     = 0x1F            ; its number among the folder's .PIC files


; ============================================================
; main - the text screen, the folder, how many pictures
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL con_clear
    ld   ph_r1, [x]
    ld   LINK_HI, x
    ld   ph_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ph_r1:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r2, [x]
    ld   LINK_HI, x
    ld   ph_r2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r2:
    clr  ac
    ld   ac, [ph_n]
    ld   ac, [ph_tot]
    ld   ac, [ph_show]
    ld   ac, [ph_from]
    ld   LINK_LO, x             ; CALL fs_mount
    ld   ph_r3, [x]
    ld   LINK_HI, x
    ld   ph_r3 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
ph_r3:
    bne  mn_no
    ld   whose >> 8, y
    jmp  whose
mn_no:
    ld   nodir >> 8, y
    jmp  nodir

nodir:
    ld   s_nodir & 0xFF, ac
    ld   ac, [R0]
    ld   s_nodir >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail

; ------------------------------------------------------------
; whose - whose pictures: the folder Pinboard's Files card was in (and the
; picture chosen there first), or the card's PHOTOS folder
; ------------------------------------------------------------
whose:
    ld   MENU_BLK >> 8, y
    ld   MB_PHOTO, x
    ld   [y,x], ac
    xor  0x56, ac               ; "V"
    bne  fr_own
    ld   MB_PARENT, x           ; and Pinboard to go back to
    ld   [y,x], ac
    beq  fr_own
    ld   MB_PCLUS, x
    ld   [y,x], ac
    ld   ac, [ph_dc]
    ld   MB_PCLUS + 1, x
    ld   [y,x], ac
    ld   ac, [ph_dc + 1]
    ld   MB_PCLUS + 2, x
    ld   [y,x], ac
    ld   ac, [ph_dc + 2]
    ld   MB_PCLUS + 3, x
    ld   [y,x], ac
    ld   ac, [ph_dc + 3]
    ld   MB_PN, x
    ld   [y,x], ac
    ld   ac, [ph_n]
    ld   1, ac
    ld   ac, [ph_from]
    ld   count >> 8, y
    jmp  count
fr_own:
    ld   own >> 8, y
    jmp  own

own:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   ph_r4, [x]
    ld   LINK_HI, x
    ld   ph_r4 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
ph_r4:
    bne  ow_no
    ld   FSV, y
    ld   V_DCLUS, x
    ld   [y,x], ac
    ld   ac, [ph_dc]
    ld   V_DCLUS + 1, x
    ld   [y,x], ac
    ld   ac, [ph_dc + 1]
    ld   V_DCLUS + 2, x
    ld   [y,x], ac
    ld   ac, [ph_dc + 2]
    ld   V_DCLUS + 3, x
    ld   [y,x], ac
    ld   ac, [ph_dc + 3]
    ld   count >> 8, y
    jmp  count
ow_no:
    ld   nodir >> 8, y
    jmp  nodir

; ------------------------------------------------------------
; opendir - the reader at the start of the pictures' folder: AC = 0, or
; the error
; ------------------------------------------------------------
opendir:
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
    ld   FSV, y
    ld   V_DCLUS, x
    ld   [ph_dc], ac
    ld   ac, [y,x]
    ld   V_DCLUS + 1, x
    ld   [ph_dc + 1], ac
    ld   ac, [y,x]
    ld   V_DCLUS + 2, x
    ld   [ph_dc + 2], ac
    ld   ac, [y,x]
    ld   V_DCLUS + 3, x
    ld   [ph_dc + 3], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL fs_cwd
    ld   ph_r5, [x]
    ld   LINK_HI, x
    ld   ph_r5 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
ph_r5:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; count - ph_tot = the .PIC files in the folder
; ------------------------------------------------------------

#addr 0x0200
count:
    ld   LINK_LO, x             ; CALL opendir
    ld   ph_r6, [x]
    ld   LINK_HI, x
    ld   ph_r6 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
ph_r6:
    bne  ct_end
ct_loop:
    ld   LINK_LO, x             ; CALL fs_next
    ld   ph_r7, [x]
    ld   LINK_HI, x
    ld   ph_r7 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
ph_r7:
    bne  ct_end
    ld   LINK_LO, x             ; CALL is_pic
    ld   ph_r8, [x]
    ld   LINK_HI, x
    ld   ph_r8 >> 8, [x]
    ld   is_pic >> 8, y
    jmp  is_pic
ph_r8:
    bne  ct_loop
    ld   [ph_tot], ac
    inc
    ld   ac, [ph_tot]
    xor  255, ac                ; (255 at most)
    bne  ct_loop
ct_end:
    ld   [ph_tot], ac
    bne  ct_some
    ld   s_none & 0xFF, ac
    ld   ac, [R0]
    ld   s_none >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail
ct_some:
    ld   [ph_from], ac          ; from Pinboard, and the width known: no
    beq  ct_ask                 ; questions, the picture
    ld   MENU_BLK >> 8, y
    ld   MB_PWIDE, x
    ld   [y,x], ac
    beq  ct_ask
    ld   ac, [ph_mode]
    ld   begin >> 8, y
    jmp  begin
ct_ask:
    ld   intro >> 8, y
    jmp  intro

; ------------------------------------------------------------
; is_pic - AC = 0 when FS_ENTRY is a file named *.PIC (a leaf)
; ------------------------------------------------------------
is_pic:
    ld   FS_ENTRY >> 8, y
    ld   FE_LO + 11, x
    ld   [y,x], ac
    and  0x18, ac               ; a folder, the volume name
    bne  ip_no
    ld   FE_LO + 8, x
    ld   [y,x], ac
    xor  0x50, ac               ; P
    bne  ip_no
    ld   FE_LO + 9, x
    ld   [y,x], ac
    xor  0x49, ac               ; I
    bne  ip_no
    ld   FE_LO + 10, x
    ld   [y,x], ac
    xor  0x43, ac               ; C
    bne  ip_no
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ip_no:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; intro - the keys, then H (160 across) or any other key (80 across)
; ------------------------------------------------------------
intro:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   [ph_tot], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   ph_r9, [x]
    ld   LINK_HI, x
    ld   ph_r9 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
ph_r9:
    ld   s_found & 0xFF, ac
    ld   ac, [R0]
    ld   s_found >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r10, [x]
    ld   LINK_HI, x
    ld   ph_r10 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r10:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   6, ac
    ld   ac, [CUR_ROW]
    ld   s_keys1 & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys1 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r11, [x]
    ld   LINK_HI, x
    ld   ph_r11 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r11:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   7, ac
    ld   ac, [CUR_ROW]
    ld   s_keys2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r12, [x]
    ld   LINK_HI, x
    ld   ph_r12 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r12:
    ld   intro2 >> 8, y
    jmp  intro2

bad:
    ld   LINK_LO, x             ; CALL con_clear
    ld   ph_r24, [x]
    ld   LINK_HI, x
    ld   ph_r24 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ph_r24:
    ld   s_bad & 0xFF, ac
    ld   ac, [R0]
    ld   s_bad >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail

; the name: up to 8 characters (to the first space), then ".PIC", 00

#addr 0x0300
intro2:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   10, ac
    ld   ac, [CUR_ROW]
    ld   s_ask1 & 0xFF, ac
    ld   ac, [R0]
    ld   s_ask1 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r13, [x]
    ld   LINK_HI, x
    ld   ph_r13 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r13:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   11, ac
    ld   ac, [CUR_ROW]
    ld   s_ask2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_ask2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r14, [x]
    ld   LINK_HI, x
    ld   ph_r14 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r14:
in_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   ph_r15, [x]
    ld   LINK_HI, x
    ld   ph_r15 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
ph_r15:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r16, [x]
    ld   LINK_HI, x
    ld   ph_r16 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r16:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   ph_r17, [x]
    ld   LINK_HI, x
    ld   ph_r17 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
ph_r17:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   ph_r18, [x]
    ld   LINK_HI, x
    ld   ph_r18 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ph_r18:
    beq  in_loop
    or   0x20, ac               ; h or H
    xor  0x68, ac
    beq  in_160
    ld   MODE_80, ac
    bra  in_go
in_160:
    ld   MODE_160, ac
in_go:
    ld   ac, [ph_mode]
    ld   begin >> 8, y
    jmp  begin

begin:
    ld   LINK_LO, x             ; black under the first picture
    ld   ph_r19, [x]
    ld   LINK_HI, x
    ld   ph_r19 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ph_r19:
    ld   LINK_LO, x             ; CALL set_modes
    ld   ph_r20, [x]
    ld   LINK_HI, x
    ld   ph_r20 >> 8, [x]
    ld   set_modes >> 8, y
    jmp  set_modes
ph_r20:
    ld   show >> 8, y
    jmp  show

; ------------------------------------------------------------
; set_modes - every row's mode byte (x5A20-x5BFF) = ph_mode, which
; MB_PWIDE keeps for the next time Pinboard asks (a leaf)
; ------------------------------------------------------------
set_modes:
    ld   MENU_BLK >> 8, y
    ld   MB_PWIDE, x
    ld   [ph_mode], ac
    ld   ac, [y,x]
    ld   0x5A, y
    ld   0x20, ac
    ld   ac, [ph_t]
sm_1:
    ld   [ph_t], x
    ld   [ph_mode], ac
    ld   ac, [y,x]
    ld   [ph_t], ac
    inc
    ld   ac, [ph_t]
    bne  sm_1
    ld   0x5B, y
sm_2:
    ld   [ph_t], x
    ld   [ph_mode], ac
    ld   ac, [y,x]
    ld   [ph_t], ac
    inc
    ld   ac, [ph_t]
    bne  sm_2
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; show - picture ph_n to the screen: the folder from its start, the
; ph_n-th .PIC file's name, the file's 80 sectors to x6000.  A number
; past the folder's last picture shows the first
; ------------------------------------------------------------
load:
    clr  ac
    ld   ac, [R4]
    ld   0x60, ac
    ld   ac, [R5]
    ld   SECTORS, ac
    ld   ac, [ph_k]
ld_sec:
    ld   LINK_LO, x             ; CALL fs_read
    ld   ph_r26, [x]
    ld   LINK_HI, x
    ld   ph_r26 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
ph_r26:
    bne  ld_end                 ; a short file: what there is of it
    ld   [ph_k], ac
    dec
    ld   ac, [ph_k]
    bne  ld_sec
ld_end:
    clr  ac
    ld   ac, [ph_tl]
    ld   ac, [ph_th]
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the frame loop: the keys, the slide show's clock
; ============================================================
prev:
    ld   [ph_n], ac
    bne  pv_dec
    ld   [ph_tot], ac           ; before the first: the last
pv_dec:
    dec
    ld   ac, [ph_n]
    ld   show >> 8, y
    jmp  show

; ------------------------------------------------------------
; fail - the message at R1:R0 on text row 3, then wait for Esc
; ------------------------------------------------------------

#addr 0x0400
show:
    ld   LINK_LO, x             ; CALL opendir
    ld   ph_r21, [x]
    ld   LINK_HI, x
    ld   ph_r21 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
ph_r21:
    bne  sh_bad
    ld   [ph_n], ac
    ld   ac, [ph_k]
sh_next:
    ld   LINK_LO, x             ; CALL fs_next
    ld   ph_r22, [x]
    ld   LINK_HI, x
    ld   ph_r22 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
ph_r22:
    bne  sh_end
    ld   LINK_LO, x             ; CALL is_pic
    ld   ph_r23, [x]
    ld   LINK_HI, x
    ld   ph_r23 >> 8, [x]
    ld   is_pic >> 8, y
    jmp  is_pic
ph_r23:
    bne  sh_next
    ld   [ph_k], ac
    beq  sh_found
    dec
    ld   ac, [ph_k]
    bra  sh_next
sh_found:
    ld   name >> 8, y
    jmp  name
sh_end:
    ld   [ph_n], ac
    beq  sh_bad
    clr  ac
    ld   ac, [ph_n]
    bra  show
sh_bad:
    ld   bad >> 8, y
    jmp  bad

name:
    ld   FE_LO, ac
    ld   ac, [ph_t]
    ld   ph_name, ac
    ld   ac, [ph_d]
    ld   8, ac
    ld   ac, [ph_k]
nm_ch:
    ld   [ph_t], x
    ld   FS_ENTRY >> 8, y
    ld   [y,x], ac
    xor  0x20, ac
    beq  nm_ext
    xor  0x20, ac
    ld   [ph_d], x
    ld   ac, [x]
    ld   [ph_t], ac
    inc
    ld   ac, [ph_t]
    ld   [ph_d], ac
    inc
    ld   ac, [ph_d]
    ld   [ph_k], ac
    dec
    ld   ac, [ph_k]
    bne  nm_ch
nm_ext:
    ld   [ph_d], ac
    ld   ac, x
    ld   0x2E, [x]
    add  1, x
    ld   0x50, [x]
    add  2, x
    ld   0x49, [x]
    add  3, x
    ld   0x43, [x]
    add  4, x
    ld   0x00, [x]
    ld   ph_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   ph_r25, [x]
    ld   LINK_HI, x
    ld   ph_r25 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
ph_r25:
    beq  nm_ok
    ld   bad >> 8, y
    jmp  bad
nm_ok:
    ld   load >> 8, y
    jmp  load

keys2:
    ld   [ph_key], ac
    or   0x20, ac
    xor  0x68, ac               ; H: 160 or 80 across
    bne  k2_s
    ld   [ph_mode], ac
    xor  0x80, ac
    ld   ac, [ph_mode]
    ld   LINK_LO, x             ; CALL set_modes
    ld   ph_r31, [x]
    ld   LINK_HI, x
    ld   ph_r31 >> 8, [x]
    ld   set_modes >> 8, y
    jmp  set_modes
ph_r31:
    ld   loop >> 8, y
    jmp  loop
k2_s:
    xor  0x68 ^ 0x73, ac        ; S: slide show
    bne  k2_no
    ld   [ph_show], ac
    xor  1, ac
    ld   ac, [ph_show]
    clr  ac
    ld   ac, [ph_tl]
    ld   ac, [ph_th]
k2_no:
    ld   loop >> 8, y
    jmp  loop

next:
    ld   [ph_n], ac
    inc
    ld   ac, [ph_n]
    xor  [ph_tot], ac
    bne  nx_go
    ld   ac, [ph_n]             ; past the last: the first
nx_go:
    ld   show >> 8, y
    jmp  show


#addr 0x0500
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   ph_r27, [x]
    ld   LINK_HI, x
    ld   ph_r27 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
ph_r27:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r28, [x]
    ld   LINK_HI, x
    ld   ph_r28 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r28:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   ph_r29, [x]
    ld   LINK_HI, x
    ld   ph_r29 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
ph_r29:
    ld   [ph_show], ac
    beq  lp_key
    ld   [ph_tl], ac
    inc
    ld   ac, [ph_tl]
    bne  lp_key
    ld   [ph_th], ac
    inc
    ld   ac, [ph_th]
    xor  SHOW_HI, ac
    bne  lp_key
    ld   next >> 8, y
    jmp  next
lp_key:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   ph_r30, [x]
    ld   LINK_HI, x
    ld   ph_r30 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ph_r30:
    beq  loop
    ld   ac, [ph_key]
    xor  0x20, ac               ; Space
    beq  lp_next
    xor  0x20 ^ 0x14, ac        ; Right
    beq  lp_next
    xor  0x14 ^ 0x0A, ac        ; Enter
    beq  lp_next
    xor  0x0A ^ 0x13, ac        ; Left
    beq  lp_prev
    xor  0x13 ^ 0x08, ac        ; Backspace
    beq  lp_prev
    ld   keys2 >> 8, y
    jmp  keys2
lp_next:
    ld   next >> 8, y
    jmp  next
lp_prev:
    ld   prev >> 8, y
    jmp  prev

fail:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r32, [x]
    ld   LINK_HI, x
    ld   ph_r32 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r32:
fl_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   ph_r33, [x]
    ld   LINK_HI, x
    ld   ph_r33 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
ph_r33:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r34, [x]
    ld   LINK_HI, x
    ld   ph_r34 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r34:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   ph_r35, [x]
    ld   LINK_HI, x
    ld   ph_r35 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
ph_r35:
    bra  fl_loop

; ============================================================
; data
; ============================================================

#addr 0x0600
s_title:
    #d "PLACARD PHOTOS", 0x00
s_dir:
    #d "PHOTOS", 0x00
s_found:
    #d " pictures in this folder", 0x00
s_nodir:
    #d "There is no PHOTOS folder on the card.  Esc: exit", 0x00
s_none:
    #d "There are no .PIC files in this folder.  Esc: exit", 0x00
s_bad:
    #d "The card could not be read.  Esc: exit", 0x00

#addr 0x0700
s_keys1:
    #d "Space, Right or Enter: next   Left or Backspace: the one before", 0x00
s_keys2:
    #d "S: slide show on or off   H: 160 or 80 across   Esc: exit", 0x00
s_ask1:
    #d "Press H for 160 across (a rev B board),", 0x00
s_ask2:
    #d "or any other key for 80 across (any board).", 0x00
