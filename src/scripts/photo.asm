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
;     E           the picture editor (photo_edit.masm, included below)
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
; RAM: the program at x0100-x24FF (asm_expand.py pages it), zero page
; x20-x3F; the editor's tables x2500-x4CFF and x5400-x59FF and zero page
; x40-x9F.  The whole video RAM is the picture.
;
;     python3 asm_expand.py photo.masm                photo.asm
;     python3 gen_plc.py photo.asm -o ../../sdcard/PHOTO.PLC
;     python3 gen_photos.py                           sdcard/PHOTOS/*.PIC
;     python3 test_photo.py                           runs it in placard_sim
;     python3 test_photo_edit.py                      the editor, in the web emulator
;
; Date: 11/23/2026
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
etb_txt:
    #d " Pencil  Brush  Eraser  Line  Rect  Fill  Pick  Undo  Save  As  New  Hide  Exit "
etb_tab:
    #d8 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 3
    #d8 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 5, 5, 5
    #d8 5, 5, 5, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 8
    #d8 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 11
    #d8 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13

; the cross: for each of its 12 pixels, across, down, color
count:
    ld   LINK_LO, x             ; CALL tally
    ld   ph_r6, [x]
    ld   LINK_HI, x
    ld   ph_r6 >> 8, [x]
    ld   tally >> 8, y
    jmp  tally
ph_r6:
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
; tally - ph_tot = the .PIC files in the folder, and AC
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

#addr 0x0300
tally:
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
    ld   ac, [ph_tot]
    ld   LINK_LO, x             ; CALL opendir
    ld   ph_r7, [x]
    ld   LINK_HI, x
    ld   ph_r7 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
ph_r7:
    bne  ty_end
ty_loop:
    ld   LINK_LO, x             ; CALL fs_next
    ld   ph_r8, [x]
    ld   LINK_HI, x
    ld   ph_r8 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
ph_r8:
    bne  ty_end
    ld   LINK_LO, x             ; CALL is_pic
    ld   ph_r9, [x]
    ld   LINK_HI, x
    ld   ph_r9 >> 8, [x]
    ld   is_pic >> 8, y
    jmp  is_pic
ph_r9:
    bne  ty_loop
    ld   [ph_tot], ac
    inc
    ld   ac, [ph_tot]
    xor  255, ac                ; (255 at most)
    bne  ty_loop
ty_end:
    ld   [ph_tot], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; is_pic - AC = 0 when FS_ENTRY is a file named *.PIC (a leaf)
; ------------------------------------------------------------
intro:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   [ph_tot], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   ph_r10, [x]
    ld   LINK_HI, x
    ld   ph_r10 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
ph_r10:
    ld   s_found & 0xFF, ac
    ld   ac, [R0]
    ld   s_found >> 8, ac
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
    ld   6, ac
    ld   ac, [CUR_ROW]
    ld   s_keys1 & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys1 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r12, [x]
    ld   LINK_HI, x
    ld   ph_r12 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r12:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   7, ac
    ld   ac, [CUR_ROW]
    ld   s_keys2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r13, [x]
    ld   LINK_HI, x
    ld   ph_r13 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r13:
    ld   intro2 >> 8, y
    jmp  intro2

begin:
    ld   LINK_LO, x             ; black under the first picture
    ld   ph_r20, [x]
    ld   LINK_HI, x
    ld   ph_r20 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ph_r20:
    ld   LINK_LO, x             ; CALL set_modes
    ld   ph_r21, [x]
    ld   LINK_HI, x
    ld   ph_r21 >> 8, [x]
    ld   set_modes >> 8, y
    jmp  set_modes
ph_r21:
    ld   show >> 8, y
    jmp  show

; ------------------------------------------------------------
; set_modes - every row's mode byte (x5A20-x5BFF) = ph_mode, which
; MB_PWIDE keeps for the next time Pinboard asks (a leaf)
; ------------------------------------------------------------
bad:
    ld   LINK_LO, x             ; CALL con_clear
    ld   ph_r25, [x]
    ld   LINK_HI, x
    ld   ph_r25 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ph_r25:
    ld   s_bad & 0xFF, ac
    ld   ac, [R0]
    ld   s_bad >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail

; the name: up to 8 characters (to the first space), then ".PIC", 00
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


#addr 0x0400
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
    ld   ph_r14, [x]
    ld   LINK_HI, x
    ld   ph_r14 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r14:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   11, ac
    ld   ac, [CUR_ROW]
    ld   s_ask2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_ask2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r15, [x]
    ld   LINK_HI, x
    ld   ph_r15 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r15:
in_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   ph_r16, [x]
    ld   LINK_HI, x
    ld   ph_r16 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
ph_r16:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r17, [x]
    ld   LINK_HI, x
    ld   ph_r17 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r17:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   ph_r18, [x]
    ld   LINK_HI, x
    ld   ph_r18 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
ph_r18:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   ph_r19, [x]
    ld   LINK_HI, x
    ld   ph_r19 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ph_r19:
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
show:
    ld   LINK_LO, x             ; CALL opendir
    ld   ph_r22, [x]
    ld   LINK_HI, x
    ld   ph_r22 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
ph_r22:
    bne  sh_bad
    ld   [ph_n], ac
    ld   ac, [ph_k]
sh_next:
    ld   LINK_LO, x             ; CALL fs_next
    ld   ph_r23, [x]
    ld   LINK_HI, x
    ld   ph_r23 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
ph_r23:
    bne  sh_end
    ld   LINK_LO, x             ; CALL is_pic
    ld   ph_r24, [x]
    ld   LINK_HI, x
    ld   ph_r24 >> 8, [x]
    ld   is_pic >> 8, y
    jmp  is_pic
ph_r24:
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


#addr 0x0500
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
    ld   ph_r26, [x]
    ld   LINK_HI, x
    ld   ph_r26 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
ph_r26:
    beq  nm_ok
    ld   bad >> 8, y
    jmp  bad
nm_ok:
    ld   load >> 8, y
    jmp  load

load:
    clr  ac
    ld   ac, [R4]
    ld   0x60, ac
    ld   ac, [R5]
    ld   SECTORS, ac
    ld   ac, [ph_k]
ld_sec:
    ld   LINK_LO, x             ; CALL fs_read
    ld   ph_r27, [x]
    ld   LINK_HI, x
    ld   ph_r27 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
ph_r27:
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
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   ph_r28, [x]
    ld   LINK_HI, x
    ld   ph_r28 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
ph_r28:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r29, [x]
    ld   LINK_HI, x
    ld   ph_r29 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r29:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   ph_r30, [x]
    ld   LINK_HI, x
    ld   ph_r30 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
ph_r30:
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
    ld   ph_r31, [x]
    ld   LINK_HI, x
    ld   ph_r31 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ph_r31:
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


#addr 0x0600
keys2:
    ld   [ph_key], ac
    or   0x20, ac
    xor  0x68, ac               ; H: 160 or 80 across
    bne  k2_s
    ld   [ph_mode], ac
    xor  0x80, ac
    ld   ac, [ph_mode]
    ld   LINK_LO, x             ; CALL set_modes
    ld   ph_r32, [x]
    ld   LINK_HI, x
    ld   ph_r32 >> 8, [x]
    ld   set_modes >> 8, y
    jmp  set_modes
ph_r32:
    ld   loop >> 8, y
    jmp  loop
k2_s:
    xor  0x68 ^ 0x73, ac        ; S: slide show
    bne  k2_e
    ld   [ph_show], ac
    xor  1, ac
    ld   ac, [ph_show]
    clr  ac
    ld   ac, [ph_tl]
    ld   ac, [ph_th]
    ld   loop >> 8, y
    jmp  loop
k2_e:
    xor  0x73 ^ 0x65, ac        ; E: the editor (photo_edit.masm)
    bne  k2_no
    ld   edit >> 8, y
    jmp  edit
k2_no:
    ld   loop >> 8, y
    jmp  loop

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
fail:
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   LINK_LO, x             ; CALL con_puts
    ld   ph_r33, [x]
    ld   LINK_HI, x
    ld   ph_r33 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ph_r33:
fl_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   ph_r34, [x]
    ld   LINK_HI, x
    ld   ph_r34 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
ph_r34:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r35, [x]
    ld   LINK_HI, x
    ld   ph_r35 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r35:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   ph_r36, [x]
    ld   LINK_HI, x
    ld   ph_r36 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
ph_r36:
    bra  fl_loop

; ============================================================
; data
; ============================================================
e_leave:
    ld   ac, [SAVE_AC]
    ld   [SP], ac
    inc
    ld   ac, x
    inc
    ld   ac, [SP]
    ld   [x], ac
    ld   ac, [LINK_LO]
    ld   [SP], x
    ld   [x], ac
    ld   ac, y
    ld   [SAVE_AC], ac
    jmp  [LINK_LO]

; ============================================================
; edit - the editor starts: the picture ph_n is on the screen
; ============================================================
edit:
    clr  ac
    ld   ac, [ph_show]
    ld   ac, [ed_ask]
    ld   ac, [ed_drag]
    ld   ac, [ed_pn]
    ld   ac, [ed_dirty]
    ld   ac, [ed_msg]
    ld   ac, [ed_hold]
    ld   ac, [ed_tool]
    ld   ac, [ed_do]
    ld   ac, [ed_paper]
    ld   ac, [ed_tb]
    ld   ac, [ed_pyh]
    ld   1, ac
    ld   ac, [ed_named]
    ld   ac, [ed_pxh]
    ld   0xFF, ac
    ld   ac, [ed_ink]
    ld   2, ac
    ld   ac, [ed_size]
    ld   3, ac
    ld   ac, [ed_ob]
    ld   0x40, ac
    ld   ac, [ed_pxl]
    ld   200, ac
    ld   ac, [ed_pyl]
    ld   208, ac
    ld   ac, [ed_tby]
    ld   193, ac
    ld   ac, [ed_tlo]
    ld   0x5B, ac
    ld   ac, [ed_mpg]
    ld   0xC0, ac
    ld   ac, [ed_mlo]
    ld   eedit2 >> 8, y
    jmp  eedit2

e_dims:
    ld   [ed_size], ac
    ld   ac, [ed_sw]
    shl
    ld   ac, [ed_sh]
    ld   [ed_wide], ac
    bne  edm_x
    ld   [ed_sh], ac
    shl
    ld   ac, [ed_sh]
edm_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; e_jreset - an empty journal (a leaf)

#addr 0x0700
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
e_jreset:
    clr  ac
    ld   ac, [ed_jl]
    ld   ac, [ed_jh]
    ld   ac, [ed_jk]
    ld   ac, [ed_jov]
    ld   ac, [ed_tbm]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the frame loop: the mouse and the arrow keys move the pointer, the
; buttons draw or choose, then the keys
; ============================================================
e_arrow2:
    ld   [KBD_NOW + 7], ac
    and  0x20, ac
    bne  eew_r
    ld   [MOUSE_DX], ac
    sub  [ed_kx], ac
    ld   ac, [MOUSE_DX]
eew_r:
    ld   [KBD_NOW + 7], ac
    and  0x80, ac
    bne  eew_u
    ld   [MOUSE_DX], ac
    add  [ed_kx], ac
    ld   ac, [MOUSE_DX]
eew_u:
    ld   [KBD_NOW + 6], ac
    and  0x20, ac
    bne  eew_d
    ld   [MOUSE_DY], ac
    sub  [ed_ky], ac
    ld   ac, [MOUSE_DY]
eew_d:
    ld   [KBD_NOW + 7], ac
    and  0x40, ac
    bne  eew_x
    ld   [MOUSE_DY], ac
    add  [ed_ky], ac
    ld   ac, [MOUSE_DY]
eew_x:
    ld   e_btn >> 8, y
    jmp  e_btn

; the buttons: the mouse's, Space (left) and Enter (right)

#addr 0x0800
s_keys1:
    #d "Space, Right or Enter: next   Left or Backspace: the one before", 0x00
s_keys2:
    #d "S: slide show   H: 160 or 80 across   E: edit the picture   Esc: exit", 0x00
s_ask1:
    #d "Press H for 160 across (a rev B board),", 0x00
s_ask2:
    #d "or any other key for 80 across (any board).", 0x00

; ============================================================
; the editor
; ============================================================
; ============================================================
; photo_edit.masm - the picture editor of PHOTO.PLC (photo.masm includes
; this file; E while a picture shows starts it)
; ============================================================
;
; The picture on the screen is the file: video RAM x6000-xFFFF, 160
; byte columns of 256 bytes, 240 rows of them shown (photo.masm).  The
; editor draws straight into it.  On a rev B board in 160 across (mode
; byte x87) a pixel is one byte; in 80 across (x07, any board) the screen
; shows the odd byte columns, and the editor writes a pixel to the odd
; column and the even one before it, so the file is right at both widths.
;
; The bar: 32 picture rows at the bottom of the screen (M: at the top),
; drawn over the picture, whose bytes under it are kept (TBS) and put back
; when the bar goes away, moves or the picture is filled, and into the
; sectors when the picture is saved.  Its first 16 rows are two text rows
; (mode byte x04: 1 bpp, 2x, 80 characters of the ROM's font): the tools
; and commands, then the file's name, the brush size, the pointer's place
; and a message.  Its last 16 rows are 8 bpp rows of 80 cells (x07): the
; 256 colors in 4 rows of 64, the ink and the paper.
;
;     P pencil    B brush    E eraser (the brush in the paper color)
;     L line      R rectangle    F fill    K pick a color from the picture
;     U undo      S save     A save as    N new    H or Tab: the bar away
;     and back    M the bar to the other edge   [ ] brush size
;     X or Esc: back to the viewer
;     the arrows move the pointer, Space is the left button, Enter the right
;
; The mouse: the left button draws, or chooses in the bar (a color: the
; ink); the right button on a color makes it the paper, on the picture it
; takes the bar away or brings it back.
;
; Undo takes back the last thing drawn.  What a tool changes is noted as
; it draws (the journal: a pixel's place and old color, in 80 across
; the old color of both its bytes; for a fill, each run of pixels and the
; one old color, which undo gives both bytes), up to JPAGES x 256 notes.  A line
; or rectangle being pulled is undone and drawn again as the pointer
; moves.  Something bigger than the journal cannot be undone.
;
; Reading the video RAM needs the map at FF (every section RAM: the ROM
; and the library are then gone), so the drawing runs between MAPFF and
; MAP07 and returns through e_leave, a copy of lib_leave in the RAM.
;
; RAM: zero page x40-x9F and x2F, x3D-x3F; the tables below.
;
; Date: 11/23/2026
; ============================================================

ed_pxl  = 0x40              ; the pointer: X 0-639
ed_pxh  = 0x41
ed_pyl  = 0x42              ; Y 0-479
ed_pyh  = 0x43
ed_x    = 0x44              ; its pixel in the picture: 0-159 or 0-79
ed_y    = 0x45              ; its row, 0-239
ed_cc   = 0x46              ; its cell, 0-79 (X / 8)
ed_zone = 0x47              ; 0 the picture, 1 the tools, 2 the status row, 3 the colors
ed_zr   = 0x48              ; its row in the bar, 0-31
ed_wide = 0x49              ; 1: 160 across
ed_xmax = 0x4A              ; 159 or 79
ed_fst  = 0x4B              ; pages a pixel: 1 or 2
ed_pb   = 0x4C              ; the page of pixel 0: x60, or x61 (the odd one of the pair)
ed_ux   = 0x4E              ; an arrow key's step in X: 4 or 8
ed_ux3  = 0x4F              ; and when held long
ed_tool = 0x50              ; 0 pencil 1 brush 2 eraser 3 line 4 rectangle 5 fill 6 pick
ed_ink  = 0x51
ed_paper = 0x52
ed_size = 0x53              ; the brush: 1-4
ed_sw   = 0x54              ; its pixels across
ed_sh   = 0x55              ; its rows
ed_tb   = 0x56              ; 1: the bar is on the screen
ed_tby  = 0x57              ; its first row: 208 or 0
ed_tlo  = 0x58              ; that row's low byte: 193 or 32
ed_mpg  = 0x59              ; its rows' mode bytes
ed_mlo  = 0x5A
ed_cy0  = 0x5B              ; the rows there is to draw in: all but the bar's
ed_cy1  = 0x5C
ed_btn  = 0x5D              ; the buttons: bit 0 left, bit 1 right
ed_ob   = 0x5E              ; and a frame ago
ed_drag = 0x5F              ; 1: a tool is drawing, 2: colors are being picked
ed_lx   = 0x60              ; the point last drawn to
ed_ly   = 0x61
ed_ax   = 0x62              ; where a line or rectangle began
ed_ay   = 0x63
ed_ty   = 0x64              ; the pointer's row, kept out of the bar
ed_col  = 0x65              ; the color drawn
ed_stmp = 0x66              ; 1: every point is the brush
ed_jl   = 0x67              ; the journal's notes
ed_jh   = 0x68
ed_jk   = 0x69              ; 0: pixels, 1: runs (a fill)
ed_jold = 0x6A              ; the runs' old color
ed_jov  = 0x6B              ; 1: more was drawn than the journal holds
ed_tbm  = 0x6C              ; 1: the bar may cover what the journal notes
ed_dirty = 0x6D             ; 1: changed since it was saved
ed_named = 0x6E             ; 0: a new picture with no name yet
ed_ask  = 0x6F              ; 1: "Discard?", 2: a name is being typed
ed_pend = 0x70              ; what "Discard?" was asked for: 1 leave, 2 new
ed_nl   = 0x71              ; characters of the name typed
ed_key  = 0x72
ed_hold = 0x73              ; frames an arrow key has been down
ed_kx   = 0x74              ; this frame's step
ed_ky   = 0x75
ed_do   = 0x76              ; the command to do (the bar's numbers, 0 none)
ed_msg  = 0x77              ; the message shown
ed_was  = 0x78              ; the bar was on the screen
ed_mok  = 0x79              ; 0: a mouse runs
ed_qx   = 0x7A              ; a pixel: e_pset, e_getpix
ed_qy   = 0x7B
ed_t    = 0x7C              ; scratch
ed_k    = 0x7D
ed_m    = 0x7E
ed_cx   = 0x7F              ; a point: e_dot
ed_cy   = 0x80
ed_x0   = 0x81              ; a line: e_line
ed_y0   = 0x82
ed_x1   = 0x83
ed_y1   = 0x84
ed_dx   = 0x85
ed_dy   = 0x86
ed_sx   = 0x87
ed_sy   = 0x88
ed_err  = 0x89
ed_n    = 0x8A
ed_si   = 0x8B              ; the brush's counters
ed_sj   = 0x8C
ed_sox  = 0x8D
ed_soy  = 0x8E
ed_tc   = 0x8F              ; text: the column, 0-79
ed_tr   = 0x90              ; the low byte of the text row's first line
ed_inv  = 0x91              ; x80: black on white (the font's 80-FF)
ed_pn   = 0x92              ; screen bytes kept under the pointer
ed_p2   = 0x93              ; 1: each is two bytes (the page after too)
ed_bx   = 0x94              ; the cross: its middle, the last pixel across,
ed_plim = 0x95              ; the rows it may be in
ed_py0  = 0x96
ed_py1  = 0x97
ed_fpg  = 0x98              ; fill: the pixel taken from the stack
ed_flo  = 0x99
ed_fl   = 0x9A              ; its run's first and last page
ed_fr   = 0x9B
ed_ftg  = 0x9C              ; the color filled over
ed_spl  = 0x9D              ; pixels on the stack
ed_sph  = 0x9E
ed_nlo  = 0x9F              ; the row above or below
ed_run  = 0x2F              ; 1: in a run of that color
ed_bl   = 0x3D              ; TBS: the next byte
ed_bh   = 0x3E
ed_pe   = 0x3F              ; a pair's even page

TBS     = 0x2500            ; 15 pages: the picture under the bar, 48 bytes a
                            ; pair of pages (32 rows of the odd, 16 of the even)
PSV     = 0x3400            ; under the pointer: page, low byte, 2 bytes (16 each)
NB      = 0x3440            ; the name typed, 8 characters
JA      = 0x3500            ; the journal: page (a run's first page)
JB      = 0x3B00            ; low byte
JC      = 0x4100            ; old color (a run's last page)
JD      = 0x4700            ; in 80 across: the old color of the even page
JPAGES  = 6                 ; pages each: 1,536 notes
SA      = 0x5400            ; 2 pages: fill's stack, the pages
SB      = 0x5600            ; 2 pages: and the low bytes
SBUF    = 0x5800            ; 2 pages: a sector on its way to the card

fs_create = 0x8010          ; the DOS's FAT writer (docs/software/DOS.md)
fs_write  = 0x8014
fs_close  = 0x8018



; e_leave - lib_leave, in the RAM
e_swatch:
    ld   [ed_zr], ac
    and  0x0C, ac
    shl
    shl
    shl
    shl
    or   [ed_cc], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; the left button went down
epc_n:
    ld   [T5], ac
    add  3, ac
    ld   ac, [T5]
    xor  36, ac
    beq  epc_x
    ld   epc_l >> 8, y
    jmp  epc_l
epc_x:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; the arrow: 8 rows (fewer at the end of the text rows) of the byte under
; the pointer, its shape turned over

#addr 0x0900
eedit2:
    ld   [ph_mode], ac
    and  0x80, ac
    beq  ee2_c
    ld   1, ac
    ld   ac, [ed_wide]
    ld   ac, [ed_fst]
    ld   159, ac
    ld   ac, [ed_xmax]
    ld   0x60, ac
    ld   ac, [ed_pb]
    ld   4, ac
    ld   ac, [ed_ux]
    ld   12, ac
    ld   ac, [ed_ux3]
    bra  ee2_d
ee2_c:
    ld   ac, [ed_wide]
    ld   2, ac
    ld   ac, [ed_fst]
    ld   79, ac
    ld   ac, [ed_xmax]
    ld   0x61, ac
    ld   ac, [ed_pb]
    ld   8, ac
    ld   ac, [ed_ux]
    ld   24, ac
    ld   ac, [ed_ux3]
ee2_d:
    ld   LINK_LO, x             ; CALL e_dims
    ld   ph_r37, [x]
    ld   LINK_HI, x
    ld   ph_r37 >> 8, [x]
    ld   e_dims >> 8, y
    jmp  e_dims
ph_r37:
    ld   LINK_LO, x             ; CALL e_jreset
    ld   ph_r38, [x]
    ld   LINK_HI, x
    ld   ph_r38 >> 8, [x]
    ld   e_jreset >> 8, y
    jmp  e_jreset
ph_r38:
    ld   [MOUSE_ST], ac         ; Pinboard's mouse runs on
    blt  ee2_run
    ld   LINK_LO, x             ; CALL mouse_init
    ld   ph_r39, [x]
    ld   LINK_HI, x
    ld   ph_r39 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
ph_r39:
    bra  ee2_set
ee2_run:
    clr  ac
ee2_set:
    ld   ac, [ed_mok]
    ld   LINK_LO, x             ; CALL etb_show
    ld   ph_r40, [x]
    ld   LINK_HI, x
    ld   ph_r40 >> 8, [x]
    ld   etb_show >> 8, y
    jmp  etb_show
ph_r40:
    ld   LINK_LO, x             ; CALL e_locate
    ld   ph_r41, [x]
    ld   LINK_HI, x
    ld   ph_r41 >> 8, [x]
    ld   e_locate >> 8, y
    jmp  e_locate
ph_r41:
    ld   LINK_LO, x             ; CALL ep_show
    ld   ph_r42, [x]
    ld   LINK_HI, x
    ld   ph_r42 >> 8, [x]
    ld   ep_show >> 8, y
    jmp  ep_show
ph_r42:
    ld   e_loop >> 8, y
    jmp  e_loop

; e_dims - the brush's pixels and rows for its size (a leaf)
e_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   ph_r43, [x]
    ld   LINK_HI, x
    ld   ph_r43 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
ph_r43:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r44, [x]
    ld   LINK_HI, x
    ld   ph_r44 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r44:
    ld   [ed_ask], ac
    beq  eel_1
    ld   e_asking >> 8, y
    jmp  e_asking
eel_1:
    ld   ac, [ed_do]
    ld   [ed_mok], ac
    bne  eel_nom
    ld   LINK_LO, x             ; CALL mouse_poll
    ld   ph_r45, [x]
    ld   LINK_HI, x
    ld   ph_r45 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
ph_r45:
    bne  eel_keys                ; something new: MOUSE_DX, MOUSE_DY
eel_nom:
    clr  ac
    ld   ac, [MOUSE_DX]
    ld   ac, [MOUSE_DY]
eel_keys:
    ld   e_arrows >> 8, y
    jmp  e_arrows

; the arrow keys: a step at once, then after a quarter second a step a
; frame, and three a frame when held long (KBD_NOW: 0 = the key is down)
e_done:
    ld   LINK_LO, x             ; CALL e_locate
    ld   ph_r50, [x]
    ld   LINK_HI, x
    ld   ph_r50 >> 8, [x]
    ld   e_locate >> 8, y
    jmp  e_locate
ph_r50:
    ld   [ed_tb], ac
    beq  eed_1
    ld   LINK_LO, x             ; CALL est_xy
    ld   ph_r51, [x]
    ld   LINK_HI, x
    ld   ph_r51 >> 8, [x]
    ld   est_xy >> 8, y
    jmp  est_xy
ph_r51:
eed_1:
    ld   LINK_LO, x             ; CALL ep_show
    ld   ph_r52, [x]
    ld   LINK_HI, x
    ld   ph_r52 >> 8, [x]
    ld   ep_show >> 8, y
    jmp  ep_show
ph_r52:
    ld   e_keys >> 8, y
    jmp  e_keys


#addr 0x0A00
e_arrows:
    ld   [KBD_NOW + 7], ac      ; Left, Down, Right
    and  0xE0, ac
    xor  0xE0, ac
    ld   ac, [ed_t]
    ld   [KBD_NOW + 6], ac      ; Up
    and  0x20, ac
    xor  0x20, ac
    or   [ed_t], ac
    bne  eew_held
    ld   ac, [ed_hold]
eew_none:
    ld   e_btn >> 8, y
    jmp  e_btn
eew_held:
    ld   [ed_hold], ac
    beq  eew_one
    xor  40, ac
    beq  eew_fast
    ld   [ed_hold], ac
    inc
    ld   ac, [ed_hold]
    sub  15, ac
    bcs  eew_none
    bra  eew_slow
eew_one:
    ld   1, ac
    ld   ac, [ed_hold]
eew_slow:
    ld   [ed_ux], ac
    ld   ac, [ed_kx]
    ld   2, ac
    ld   ac, [ed_ky]
    bra  eew_go
eew_fast:
    ld   [ed_ux3], ac
    ld   ac, [ed_kx]
    ld   6, ac
    ld   ac, [ed_ky]
eew_go:
    ld   e_arrow2 >> 8, y
    jmp  e_arrow2

e_btn:
    ld   [ed_mok], ac
    bne  eeb_0
    ld   [MOUSE_B], ac
    and  3, ac
    bra  eeb_1
eeb_0:
    clr  ac
eeb_1:
    ld   ac, [ed_btn]
    ld   [KBD_NOW + 7], ac
    and  0x04, ac
    bne  eeb_2
    ld   [ed_btn], ac
    or   1, ac
    ld   ac, [ed_btn]
eeb_2:
    ld   [KBD_NOW + 5], ac
    and  0x01, ac
    bne  eeb_3
    ld   [ed_btn], ac
    or   2, ac
    ld   ac, [ed_btn]
eeb_3:
    ld   [MOUSE_DX], ac
    or   [MOUSE_DY], ac
    bne  eeb_move
    ld   [ed_btn], ac
    xor  [ed_ob], ac
    bne  eeb_move
    ld   e_keys >> 8, y
    jmp  e_keys
eeb_move:
    ld   e_move >> 8, y
    jmp  e_move

e_move:
    ld   LINK_LO, x             ; CALL ep_hide
    ld   ph_r46, [x]
    ld   LINK_HI, x
    ld   ph_r46 >> 8, [x]
    ld   ep_hide >> 8, y
    jmp  ep_hide
ph_r46:
    ld   [MOUSE_DX], ac
    or   [MOUSE_DY], ac
    beq  eem_1
    ld   [ed_pxl], ac
    ld   ac, [R0]
    ld   [ed_pxh], ac
    ld   ac, [R1]
    ld   [ed_pyl], ac
    ld   ac, [R2]
    ld   [ed_pyh], ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL mouse_move
    ld   ph_r47, [x]
    ld   LINK_HI, x
    ld   ph_r47 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
ph_r47:
    ld   [R0], ac
    ld   ac, [ed_pxl]
    ld   [R1], ac
    ld   ac, [ed_pxh]
    ld   [R2], ac
    ld   ac, [ed_pyl]
    ld   [R3], ac
    ld   ac, [ed_pyh]
eem_1:
    ld   LINK_LO, x             ; CALL e_locate
    ld   ph_r48, [x]
    ld   LINK_HI, x
    ld   ph_r48 >> 8, [x]
    ld   e_locate >> 8, y
    jmp  e_locate
ph_r48:
    ld   LINK_LO, x             ; CALL e_act
    ld   ph_r49, [x]
    ld   LINK_HI, x
    ld   ph_r49 >> 8, [x]
    ld   e_act >> 8, y
    jmp  e_act
ph_r49:
    ld   [ed_btn], ac
    ld   ac, [ed_ob]
    ld   [ed_do], ac
    beq  eem_2
    ld   e_do >> 8, y
    jmp  e_do
eem_2:
    ld   e_done >> 8, y
    jmp  e_done

; e_done - the pointer back on the screen, then the keys
cmd_tool:
    ld   [ed_do], ac
    dec
    ld   ac, [ed_tool]
    ld   [ed_tb], ac
    beq  edt_x
    ld   LINK_LO, x             ; CALL etb_tools
    ld   ph_r73, [x]
    ld   LINK_HI, x
    ld   ph_r73 >> 8, [x]
    ld   etb_tools >> 8, y
    jmp  etb_tools
ph_r73:
edt_x:
    ld   e_done >> 8, y
    jmp  e_done


#addr 0x0B00
e_keys:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   ph_r53, [x]
    ld   LINK_HI, x
    ld   ph_r53 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ph_r53:
    bne  eek_1
    ld   e_loop >> 8, y
    jmp  e_loop
eek_1:
    ld   ac, [ed_key]
    ld   [ed_drag], ac          ; not while something is being drawn
    bne  e_keys
    ld   ac, [ed_t]
eek_l:
    ld   [ed_t], ac
    add  ekeytab & 0xFF, x
    ld   ekeytab >> 8, y
    ld   [y,x], ac
    beq  e_keys                 ; not one of the editor's keys
    xor  [ed_key], ac
    beq  eek_hit
    ld   [ed_t], ac
    add  2, ac
    ld   ac, [ed_t]
    bra  eek_l
eek_hit:
    ld   [ed_t], ac
    add  (ekeytab & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [ed_do]
    ld   LINK_LO, x             ; CALL ep_hide
    ld   ph_r54, [x]
    ld   LINK_HI, x
    ld   ph_r54 >> 8, [x]
    ld   ep_hide >> 8, y
    jmp  ep_hide
ph_r54:
    ld   e_do >> 8, y
    jmp  e_do

; e_locate - where the pointer is: its pixel, row, cell and zone (a leaf)
e_locate:
    ld   [ed_pyl], ac
    shr  ac
    ld   ac, [ed_y]
    ld   [ed_pyh], ac
    beq  elc_1
    ld   [ed_y], ac
    or   0x80, ac
    ld   ac, [ed_y]
elc_1:
    ld   [ed_pxl], ac
    shr  ac
    shr  ac
    ld   ac, [T0]               ; X / 4
    shr  ac
    ld   ac, [ed_cc]            ; X / 8
    ld   [ed_pxh], ac
    beq  elc_3
    xor  1, ac
    bne  elc_2
    ld   [T0], ac
    or   0x40, ac
    ld   ac, [T0]
    ld   [ed_cc], ac
    or   0x20, ac
    ld   ac, [ed_cc]
    bra  elc_3
elc_2:
    ld   [T0], ac
    or   0x80, ac
    ld   ac, [T0]
    ld   [ed_cc], ac
    or   0x40, ac
    ld   ac, [ed_cc]
elc_3:
    ld   [ed_wide], ac
    bne  elc_w
    ld   [ed_cc], ac
    bra  elc_x
elc_w:
    ld   [T0], ac
elc_x:
    ld   ac, [ed_x]
    clr  ac
    ld   ac, [ed_zone]
    ld   [ed_tb], ac
    beq  elc_r
    ld   [ed_y], ac
    sub  [ed_tby], ac
    ld   ac, [ed_zr]
    sub  32, ac
    bcc  elc_r                   ; not in the bar's rows
    ld   3, ac
    ld   ac, [ed_zone]
    ld   [ed_zr], ac
    sub  16, ac
    bcc  elc_r
    ld   2, ac
    ld   ac, [ed_zone]
    ld   [ed_zr], ac
    sub  8, ac
    bcc  elc_r
    ld   1, ac
    ld   ac, [ed_zone]
elc_r:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; e_act - what the buttons do this frame
; ============================================================
e_act:
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
    ld   [ed_btn], ac
    and  1, ac
    bne  eea_down
    ld   ac, [ed_drag]          ; the left button is up
    bra  eea_right
eea_down:
    ld   [ed_ob], ac
    and  1, ac
    bne  eea_held
    ld   ea_press >> 8, y
    jmp  ea_press
eea_held:
    ld   [ed_drag], ac
    beq  eea_right
    ld   ea_drag >> 8, y
    jmp  ea_drag
eea_right:
    ld   [ed_btn], ac
    and  2, ac
    beq  eea_x
    ld   [ed_ob], ac
    and  2, ac
    bne  eea_x
    ld   ea_right >> 8, y
    jmp  ea_right
eea_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; the right button: on the picture the bar goes away or comes back, on a
; color that is the paper

#addr 0x0C00
ea_right:
    ld   [ed_zone], ac
    bne  ear_tb
    ld   12, ac
    ld   ac, [ed_do]
    ld   e_leave >> 8, y
    jmp  e_leave
ear_tb:
    xor  3, ac
    bne  ear_x
    ld   [ed_cc], ac
    sub  64, ac
    bcc  ear_x
    ld   LINK_LO, x             ; CALL e_swatch
    ld   ph_r55, [x]
    ld   LINK_HI, x
    ld   ph_r55 >> 8, [x]
    ld   e_swatch >> 8, y
    jmp  e_swatch
ph_r55:
    ld   ac, [ed_paper]
    ld   LINK_LO, x             ; CALL etb_ink
    ld   ph_r56, [x]
    ld   LINK_HI, x
    ld   ph_r56 >> 8, [x]
    ld   etb_ink >> 8, y
    jmp  etb_ink
ph_r56:
ear_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; e_swatch - AC = the color of the palette cell under the pointer (a leaf)
ea_press:
    ld   [ed_zone], ac
    beq  eap_pic
    ld   etb_click >> 8, y
    jmp  etb_click
eap_pic:
    ld   [ed_tool], ac
    xor  6, ac
    bne  eap_0
    ld   ea_pick >> 8, y
    jmp  ea_pick
eap_0:
    ld   [ed_msg], ac
    beq  eap_1
    clr  ac
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r57, [x]
    ld   LINK_HI, x
    ld   ph_r57 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r57:
eap_1:
    ld   LINK_LO, x             ; CALL e_jreset
    ld   ph_r58, [x]
    ld   LINK_HI, x
    ld   ph_r58 >> 8, [x]
    ld   e_jreset >> 8, y
    jmp  e_jreset
ph_r58:
    ld   [ed_x], ac
    ld   ac, [ed_lx]
    ld   ac, [ed_ax]
    ld   ac, [ed_cx]
    ld   ac, [ed_qx]
    ld   [ed_y], ac
    ld   ac, [ed_ly]
    ld   ac, [ed_ay]
    ld   ac, [ed_cy]
    ld   ac, [ed_qy]
    ld   [ed_ink], ac
    ld   ac, [ed_col]
    clr  ac
    ld   ac, [ed_stmp]
    ld   [ed_tool], ac
    xor  5, ac
    beq  eap_fill
    ld   ea_start >> 8, y
    jmp  ea_start
eap_fill:
    ld   ea_fill >> 8, y
    jmp  ea_fill

; pencil, brush, eraser, line, rectangle: the first point
ea_start:
    ld   [ed_tool], ac          ; the eraser draws in the paper color
    xor  2, ac
    bne  eas_1
    ld   [ed_paper], ac
    ld   ac, [ed_col]
eas_1:
    ld   [ed_tool], ac          ; the brush and the eraser: every point a stamp
    beq  eas_2
    sub  3, ac
    bcc  eas_2
    ld   1, ac
    ld   ac, [ed_stmp]
eas_2:
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL e_dot
    ld   ph_r59, [x]
    ld   LINK_HI, x
    ld   ph_r59 >> 8, [x]
    ld   e_dot >> 8, y
    jmp  e_dot
ph_r59:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   1, ac
    ld   ac, [ed_drag]
    ld   LINK_LO, x             ; CALL e_dirty
    ld   ph_r60, [x]
    ld   LINK_HI, x
    ld   ph_r60 >> 8, [x]
    ld   e_dirty >> 8, y
    jmp  e_dirty
ph_r60:
    ld   e_leave >> 8, y
    jmp  e_leave

; fill: over the whole picture, so without the bar
ea_drag:
    ld   [ed_y], ac
    ld   ac, [ed_ty]
    sub  [ed_cy0], ac
    bcc  ead_1
    ld   [ed_cy0], ac
    ld   ac, [ed_ty]
ead_1:
    ld   [ed_cy1], ac
    sub  [ed_ty], ac
    bcc  ead_2
    ld   [ed_cy1], ac
    ld   ac, [ed_ty]
ead_2:
    ld   [ed_x], ac
    xor  [ed_lx], ac
    bne  ead_go
    ld   [ed_ty], ac
    xor  [ed_ly], ac
    bne  ead_go
    ld   e_leave >> 8, y
    jmp  e_leave
ead_go:
    ld   [ed_drag], ac
    xor  2, ac
    bne  ead_3
    ld   ea_pick2 >> 8, y
    jmp  ea_pick2
ead_3:
    ld   ea_drag2 >> 8, y
    jmp  ea_drag2

ea_fill:
    ld   [ed_tb], ac
    ld   ac, [ed_was]
    beq  eaf_1
    ld   LINK_LO, x             ; CALL etb_hide
    ld   ph_r61, [x]
    ld   LINK_HI, x
    ld   ph_r61 >> 8, [x]
    ld   etb_hide >> 8, y
    jmp  etb_hide
ph_r61:
eaf_1:
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL e_fill
    ld   ph_r62, [x]
    ld   LINK_HI, x
    ld   ph_r62 >> 8, [x]
    ld   e_fill >> 8, y
    jmp  e_fill
ph_r62:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [ed_was], ac
    beq  eaf_2
    ld   LINK_LO, x             ; CALL etb_show
    ld   ph_r63, [x]
    ld   LINK_HI, x
    ld   ph_r63 >> 8, [x]
    ld   etb_show >> 8, y
    jmp  etb_show
ph_r63:
eaf_2:
    ld   LINK_LO, x             ; CALL e_dirty
    ld   ph_r64, [x]
    ld   LINK_HI, x
    ld   ph_r64 >> 8, [x]
    ld   e_dirty >> 8, y
    jmp  e_dirty
ph_r64:
    ld   e_leave >> 8, y
    jmp  e_leave

; pick: the ink is the color under the pointer, while the button is down
ea_pick:
    ld   [ed_y], ac
    ld   ac, [ed_ty]
    ld   2, ac
    ld   ac, [ed_drag]
ea_pick2:
    ld   [ed_x], ac
    ld   ac, [ed_lx]
    ld   ac, [ed_qx]
    ld   [ed_ty], ac
    ld   ac, [ed_ly]
    ld   ac, [ed_qy]
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL e_getpix
    ld   ph_r65, [x]
    ld   LINK_HI, x
    ld   ph_r65 >> 8, [x]
    ld   e_getpix >> 8, y
    jmp  e_getpix
ph_r65:
    ld   ac, [ed_ink]
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [ed_tb], ac
    beq  eak_x
    ld   LINK_LO, x             ; CALL etb_ink
    ld   ph_r66, [x]
    ld   LINK_HI, x
    ld   ph_r66 >> 8, [x]
    ld   etb_ink >> 8, y
    jmp  etb_ink
ph_r66:
eak_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; the left button is held and a tool draws: the pointer's row kept out of
; the bar; nothing to do when the pointer has not moved a pixel
ea_drag2:
    ld   [ed_tool], ac
    sub  3, ac
    bcc  ead_shape
    ld   [ed_lx], ac            ; pencil, brush, eraser: on from the last point
    ld   ac, [ed_x0]
    ld   [ed_ly], ac
    ld   ac, [ed_y0]
    ld   [ed_x], ac
    ld   ac, [ed_x1]
    ld   ac, [ed_lx]
    ld   [ed_ty], ac
    ld   ac, [ed_y1]
    ld   ac, [ed_ly]
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL e_line
    ld   ph_r67, [x]
    ld   LINK_HI, x
    ld   ph_r67 >> 8, [x]
    ld   e_line >> 8, y
    jmp  e_line
ph_r67:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   e_leave >> 8, y
    jmp  e_leave
ead_shape:
    ld   LINK_LO, x             ; line, rectangle: the one drawn last away,
    ld   ph_r68, [x]
    ld   LINK_HI, x
    ld   ph_r68 >> 8, [x]
    ld   e_jundo >> 8, y
    jmp  e_jundo
ph_r68:
    ld   [ed_x], ac             ; and one to where the pointer is now
    ld   ac, [ed_lx]
    ld   [ed_ty], ac
    ld   ac, [ed_ly]
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL e_shape
    ld   ph_r69, [x]
    ld   LINK_HI, x
    ld   ph_r69 >> 8, [x]
    ld   e_shape >> 8, y
    jmp  e_shape
ph_r69:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   e_leave >> 8, y
    jmp  e_leave

; a click in the bar: a tool or command, the brush size, a color

#addr 0x0E00
etb_click:
    ld   [ed_zone], ac
    xor  1, ac
    bne  etk_2
    ld   [ed_cc], ac
    add  80, x
    ld   etb_txt >> 8, y
    ld   [y,x], ac
    ld   ac, [ed_do]
    ld   e_leave >> 8, y
    jmp  e_leave
etk_2:
    xor  1 ^ 2, ac
    bne  etk_3
    ld   [ed_cc], ac
    sub  19, ac
    bcs  etk_x
    sub  3, ac
    bcs  etk_minus               ; "<": columns 19-21
    sub  1, ac
    bcs  etk_x
    sub  3, ac
    bcc  etk_x
    ld   16, ac                 ; ">": columns 23-25
    bra  etk_do
etk_minus:
    ld   15, ac
etk_do:
    ld   ac, [ed_do]
    ld   e_leave >> 8, y
    jmp  e_leave
etk_3:
    ld   [ed_cc], ac
    sub  64, ac
    bcc  etk_x
    ld   LINK_LO, x             ; CALL e_swatch
    ld   ph_r70, [x]
    ld   LINK_HI, x
    ld   ph_r70 >> 8, [x]
    ld   e_swatch >> 8, y
    jmp  e_swatch
ph_r70:
    ld   ac, [ed_ink]
    ld   LINK_LO, x             ; CALL etb_ink
    ld   ph_r71, [x]
    ld   LINK_HI, x
    ld   ph_r71 >> 8, [x]
    ld   etb_ink >> 8, y
    jmp  etb_ink
ph_r71:
etk_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; e_dirty - the picture is changed: the mark by its name
e_dirty:
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
    ld   [ed_dirty], ac
    bne  edy_x
    ld   1, ac
    ld   ac, [ed_dirty]
    ld   [ed_tb], ac
    beq  edy_x
    ld   LINK_LO, x             ; CALL est_name
    ld   ph_r72, [x]
    ld   LINK_HI, x
    ld   ph_r72 >> 8, [x]
    ld   est_name >> 8, y
    jmp  est_name
ph_r72:
edy_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; ============================================================
; e_do - command ed_do (the pointer is off the screen)
; ============================================================
e_do:
    ld   [ed_do], ac
    sub  8, ac
    bcc  eeo_cmd
    ld   cmd_tool >> 8, y
    jmp  cmd_tool
eeo_cmd:
    beq  eeo_undo
    xor  1, ac
    beq  eeo_save
    xor  1 ^ 2, ac
    beq  eeo_as
    xor  2 ^ 3, ac
    beq  eeo_new
    xor  3 ^ 4, ac
    beq  eeo_hide
    xor  4 ^ 5, ac
    beq  eeo_exit
    xor  5 ^ 6, ac
    beq  eeo_move
    ld   cmd_size >> 8, y
    jmp  cmd_size
eeo_undo:
    ld   cmd_undo >> 8, y
    jmp  cmd_undo
eeo_save:
    ld   cmd_save >> 8, y
    jmp  cmd_save
eeo_as:
    ld   cmd_as >> 8, y
    jmp  cmd_as
eeo_new:
    ld   cmd_new >> 8, y
    jmp  cmd_new
eeo_hide:
    ld   cmd_hide >> 8, y
    jmp  cmd_hide
eeo_exit:
    ld   cmd_exit >> 8, y
    jmp  cmd_exit
eeo_move:
    ld   cmd_move >> 8, y
    jmp  cmd_move

cmd_hide:
    ld   [ed_tb], ac
    beq  edh_show
    ld   LINK_LO, x             ; CALL etb_hide
    ld   ph_r76, [x]
    ld   LINK_HI, x
    ld   ph_r76 >> 8, [x]
    ld   etb_hide >> 8, y
    jmp  etb_hide
ph_r76:
    ld   e_done >> 8, y
    jmp  e_done
edh_show:
    ld   LINK_LO, x             ; CALL etb_show
    ld   ph_r77, [x]
    ld   LINK_HI, x
    ld   ph_r77 >> 8, [x]
    ld   etb_show >> 8, y
    jmp  etb_show
ph_r77:
    ld   e_done >> 8, y
    jmp  e_done


#addr 0x0F00
cmd_size:
    ld   [ed_do], ac
    xor  15, ac
    bne  edz_up
    ld   [ed_size], ac
    dec
    bne  edz_set
    bra  edz_x
edz_up:
    ld   [ed_size], ac
    inc
    xor  5, ac
    beq  edz_x
    xor  5, ac
edz_set:
    ld   ac, [ed_size]
    ld   LINK_LO, x             ; CALL e_dims
    ld   ph_r74, [x]
    ld   LINK_HI, x
    ld   ph_r74 >> 8, [x]
    ld   e_dims >> 8, y
    jmp  e_dims
ph_r74:
    ld   [ed_tb], ac
    beq  edz_x
    ld   LINK_LO, x             ; CALL est_size
    ld   ph_r75, [x]
    ld   LINK_HI, x
    ld   ph_r75 >> 8, [x]
    ld   est_size >> 8, y
    jmp  est_size
ph_r75:
edz_x:
    ld   e_done >> 8, y
    jmp  e_done

cmd_move:
    ld   [ed_tb], ac
    beq  edv_1
    ld   LINK_LO, x             ; CALL etb_hide
    ld   ph_r78, [x]
    ld   LINK_HI, x
    ld   ph_r78 >> 8, [x]
    ld   etb_hide >> 8, y
    jmp  etb_hide
ph_r78:
edv_1:
    ld   [ed_tby], ac
    beq  edv_dn
    clr  ac
    ld   ac, [ed_tby]
    ld   32, ac
    ld   ac, [ed_tlo]
    ld   ac, [ed_mlo]
    ld   0x5A, ac
    ld   ac, [ed_mpg]
    bra  edv_2
edv_dn:
    ld   208, ac
    ld   ac, [ed_tby]
    ld   193, ac
    ld   ac, [ed_tlo]
    ld   0x5B, ac
    ld   ac, [ed_mpg]
    ld   0xC0, ac
    ld   ac, [ed_mlo]
edv_2:
    ld   LINK_LO, x             ; CALL etb_show
    ld   ph_r79, [x]
    ld   LINK_HI, x
    ld   ph_r79 >> 8, [x]
    ld   etb_show >> 8, y
    jmp  etb_show
ph_r79:
    ld   e_done >> 8, y
    jmp  e_done

cmd_undo:
    ld   [ed_jov], ac
    beq  edu_1
    ld   4, ac
    bra  edu_msg
edu_1:
    ld   [ed_jl], ac
    or   [ed_jh], ac
    bne  edu_2
    ld   5, ac
edu_msg:
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r80, [x]
    ld   LINK_HI, x
    ld   ph_r80 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r80:
    ld   e_done >> 8, y
    jmp  e_done
edu_2:
    clr  ac
    ld   ac, [ed_was]
    ld   [ed_tb], ac
    beq  edu_3
    ld   [ed_tbm], ac
    beq  edu_3
    ld   ac, [ed_was]
    ld   LINK_LO, x             ; CALL etb_hide
    ld   ph_r81, [x]
    ld   LINK_HI, x
    ld   ph_r81 >> 8, [x]
    ld   etb_hide >> 8, y
    jmp  etb_hide
ph_r81:
edu_3:
    ld   LINK_LO, x             ; CALL e_jundo
    ld   ph_r82, [x]
    ld   LINK_HI, x
    ld   ph_r82 >> 8, [x]
    ld   e_jundo >> 8, y
    jmp  e_jundo
ph_r82:
    ld   [ed_was], ac
    beq  edu_4
    ld   LINK_LO, x             ; CALL etb_show
    ld   ph_r83, [x]
    ld   LINK_HI, x
    ld   ph_r83 >> 8, [x]
    ld   etb_show >> 8, y
    jmp  etb_show
ph_r83:
edu_4:
    ld   8, ac
    bra  edu_msg

e_needtb:
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
    ld   [ed_tb], ac
    bne  ent_x
    ld   LINK_LO, x             ; CALL etb_show
    ld   ph_r88, [x]
    ld   LINK_HI, x
    ld   ph_r88 >> 8, [x]
    ld   etb_show >> 8, y
    jmp  etb_show
ph_r88:
ent_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; ============================================================
; a question is on the status row: the keys answer it
; ============================================================

#addr 0x1000
cmd_save:
    ld   [ed_named], ac
    beq  cmd_as
    ld   edo_save >> 8, y
    jmp  edo_save
cmd_as:
    ld   LINK_LO, x             ; CALL e_needtb
    ld   ph_r84, [x]
    ld   LINK_HI, x
    ld   ph_r84 >> 8, [x]
    ld   e_needtb >> 8, y
    jmp  e_needtb
ph_r84:
    ld   2, ac
    ld   ac, [ed_ask]
    clr  ac
    ld   ac, [ed_nl]
    ld   LINK_LO, x             ; CALL enm_draw
    ld   ph_r85, [x]
    ld   LINK_HI, x
    ld   ph_r85 >> 8, [x]
    ld   enm_draw >> 8, y
    jmp  enm_draw
ph_r85:
    ld   e_done >> 8, y
    jmp  e_done

cmd_new:
    ld   2, ac
    ld   ac, [ed_pend]
    ld   [ed_dirty], ac
    bne  cmd_ask
    ld   edo_new >> 8, y
    jmp  edo_new
cmd_exit:
    ld   1, ac
    ld   ac, [ed_pend]
    ld   [ed_dirty], ac
    bne  cmd_ask
    ld   edo_exit >> 8, y
    jmp  edo_exit
cmd_ask:
    ld   LINK_LO, x             ; CALL e_needtb
    ld   ph_r86, [x]
    ld   LINK_HI, x
    ld   ph_r86 >> 8, [x]
    ld   e_needtb >> 8, y
    jmp  e_needtb
ph_r86:
    ld   1, ac
    ld   ac, [ed_ask]
    ld   6, ac
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r87, [x]
    ld   LINK_HI, x
    ld   ph_r87 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r87:
    ld   e_done >> 8, y
    jmp  e_done

; e_needtb - the bar on the screen: a message is coming
e_asking:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   ph_r89, [x]
    ld   LINK_HI, x
    ld   ph_r89 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ph_r89:
    bne  eeq_1
    ld   e_loop >> 8, y
    jmp  e_loop
eeq_1:
    ld   ac, [ed_key]
    ld   LINK_LO, x             ; CALL ep_hide
    ld   ph_r90, [x]
    ld   LINK_HI, x
    ld   ph_r90 >> 8, [x]
    ld   ep_hide >> 8, y
    jmp  ep_hide
ph_r90:
    ld   [ed_ask], ac
    xor  2, ac
    bne  eeq_yn
    ld   enm_key >> 8, y
    jmp  enm_key
eeq_yn:
    clr  ac
    ld   ac, [ed_ask]
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r91, [x]
    ld   LINK_HI, x
    ld   ph_r91 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r91:
    ld   3, ac                  ; a key still down is not a new press
    ld   ac, [ed_ob]
    ld   [ed_key], ac
    or   0x20, ac
    xor  0x79, ac               ; Y; any other key: no
    beq  eeq_yes
    ld   e_done >> 8, y
    jmp  e_done
eeq_yes:
    ld   [ed_pend], ac
    xor  1, ac
    beq  eeq_exit
    ld   edo_new >> 8, y
    jmp  edo_new
eeq_exit:
    ld   edo_exit >> 8, y
    jmp  edo_exit

; the name: Esc gives up, Enter takes it, Backspace, letters and digits
enm_done:
    clr  ac
    ld   ac, [ed_k]
enn_l:
    ld   [ed_k], ac
    add  NB & 0xFF, x
    ld   NB >> 8, y
    ld   [y,x], ac
    ld   ac, [ed_t]
    ld   [ed_k], ac
    add  ph_name, x
    ld   [ed_t], ac
    ld   ac, [x]
    ld   [ed_k], ac
    inc
    ld   ac, [ed_k]
    xor  [ed_nl], ac
    bne  enn_l
    ld   [ed_nl], ac
    add  ph_name, ac
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
    ld   1, ac
    ld   ac, [ed_named]
    clr  ac
    ld   ac, [ed_ask]
    ld   3, ac
    ld   ac, [ed_ob]
    ld   edo_save >> 8, y
    jmp  edo_save

; ============================================================
; do_save - the picture to the file ph_name in the pictures' folder: 80
; sectors, each copied to SBUF (the map at FF), the bar's rows put right
; ============================================================

#addr 0x1100
enm_key:
    ld   [ed_key], ac
    xor  0x1B, ac
    bne  enk_1
    ld   ac, [ed_ask]
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r92, [x]
    ld   LINK_HI, x
    ld   ph_r92 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r92:
    ld   3, ac
    ld   ac, [ed_ob]
    ld   e_done >> 8, y
    jmp  e_done
enk_1:
    xor  0x1B ^ 0x0A, ac
    bne  enk_2
    ld   [ed_nl], ac
    beq  enk_x
    ld   enm_done >> 8, y
    jmp  enm_done
enk_2:
    xor  0x0A ^ 0x08, ac
    bne  enk_3
    ld   [ed_nl], ac
    beq  enk_x
    dec
    ld   ac, [ed_nl]
    ld   LINK_LO, x             ; CALL enm_draw
    ld   ph_r93, [x]
    ld   LINK_HI, x
    ld   ph_r93 >> 8, [x]
    ld   enm_draw >> 8, y
    jmp  enm_draw
ph_r93:
enk_x:
    ld   e_done >> 8, y
    jmp  e_done
enk_3:
    ld   enm_char >> 8, y
    jmp  enm_char

enm_char:
    ld   [ed_key], ac           ; a-z: the capital
    sub  0x61, ac
    bcs  enc_1
    sub  26, ac
    bcc  enc_1
    ld   [ed_key], ac
    xor  0x20, ac
    ld   ac, [ed_key]
enc_1:
    ld   [ed_key], ac           ; 0-9
    sub  0x30, ac
    bcs  enc_no
    sub  10, ac
    bcs  enc_ok
    ld   [ed_key], ac           ; A-Z
    sub  0x41, ac
    bcs  enc_no
    sub  26, ac
    bcs  enc_ok
    ld   [ed_key], ac           ; _
    xor  0x5F, ac
    bne  enc_no
enc_ok:
    ld   [ed_nl], ac
    xor  8, ac
    beq  enc_no
    ld   [ed_nl], ac
    add  NB & 0xFF, x
    ld   NB >> 8, y
    ld   [ed_key], ac
    ld   ac, [y,x]
    ld   [ed_nl], ac
    inc
    ld   ac, [ed_nl]
    ld   LINK_LO, x             ; CALL enm_draw
    ld   ph_r94, [x]
    ld   LINK_HI, x
    ld   ph_r94 >> 8, [x]
    ld   enm_draw >> 8, y
    jmp  enm_draw
ph_r94:
enc_no:
    ld   e_done >> 8, y
    jmp  e_done

; nm_draw - "Save as: " and the name so far
enm_draw:
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
    ld   7, ac
    ld   LINK_LO, x             ; CALL e_mhead
    ld   ph_r95, [x]
    ld   LINK_HI, x
    ld   ph_r95 >> 8, [x]
    ld   e_mhead >> 8, y
    jmp  e_mhead
ph_r95:
    clr  ac
    ld   ac, [ed_k]
end_l:
    ld   [ed_k], ac
    xor  [ed_nl], ac
    beq  end_x
    ld   [ed_k], ac
    add  NB & 0xFF, x
    ld   NB >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r96, [x]
    ld   LINK_HI, x
    ld   ph_r96 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r96:
    ld   [ed_k], ac
    inc
    ld   ac, [ed_k]
    bra  end_l
end_x:
    ld   0x5F, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r97, [x]
    ld   LINK_HI, x
    ld   ph_r97 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r97:
    ld   LINK_LO, x             ; CALL e_mpad
    ld   ph_r98, [x]
    ld   LINK_HI, x
    ld   ph_r98 >> 8, [x]
    ld   e_mpad >> 8, y
    jmp  e_mpad
ph_r98:
    ld   e_leave >> 8, y
    jmp  e_leave

; the name typed: ph_name = it, ".PIC", 00; then the file

#addr 0x1200
edo_save:
    ld   1, ac
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r99, [x]
    ld   LINK_HI, x
    ld   ph_r99 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r99:
    ld   LINK_LO, x             ; CALL opendir
    ld   ph_r100, [x]
    ld   LINK_HI, x
    ld   ph_r100 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
ph_r100:
    bne  esv_err
    ld   ph_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_create
    ld   ph_r101, [x]
    ld   LINK_HI, x
    ld   ph_r101 >> 8, [x]
    ld   fs_create >> 8, y
    jmp  fs_create
ph_r101:
    bne  esv_err
    clr  ac
    ld   ac, [ed_bl]
    ld   TBS >> 8, ac
    ld   ac, [ed_bh]
    ld   0x60, ac
    ld   ac, [ed_pe]
    ld   esv_loop >> 8, y
    jmp  esv_loop
esv_err:
    ld   esv_fail >> 8, y
    jmp  esv_fail

esv_loop:
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL e_cpsec
    ld   ph_r102, [x]
    ld   LINK_HI, x
    ld   ph_r102 >> 8, [x]
    ld   e_cpsec >> 8, y
    jmp  e_cpsec
ph_r102:
    ld   [ed_tb], ac
    beq  esl_1
    ld   SBUF >> 8, ac
    ld   ac, [R6]
    inc
    ld   ac, [R7]
    ld   LINK_LO, x             ; CALL etb_pair
    ld   ph_r103, [x]
    ld   LINK_HI, x
    ld   ph_r103 >> 8, [x]
    ld   etb_pair >> 8, y
    jmp  etb_pair
ph_r103:
esl_1:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    clr  ac
    ld   ac, [R4]
    ld   SBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_write
    ld   ph_r104, [x]
    ld   LINK_HI, x
    ld   ph_r104 >> 8, [x]
    ld   fs_write >> 8, y
    jmp  fs_write
ph_r104:
    bne  esv_fail
    ld   [ed_pe], ac
    add  2, ac
    ld   ac, [ed_pe]
    bne  esv_loop
    ld   ac, [R0]
    ld   ac, [R2]
    ld   ac, [R3]
    ld   0xA0, ac               ; 40,960 bytes
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_close
    ld   ph_r105, [x]
    ld   LINK_HI, x
    ld   ph_r105 >> 8, [x]
    ld   fs_close >> 8, y
    jmp  fs_close
ph_r105:
    bne  esv_fail
    ld   ac, [ed_dirty]
    ld   2, ac
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r106, [x]
    ld   LINK_HI, x
    ld   ph_r106 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r106:
    ld   LINK_LO, x             ; CALL est_name
    ld   ph_r107, [x]
    ld   LINK_HI, x
    ld   ph_r107 >> 8, [x]
    ld   est_name >> 8, y
    jmp  est_name
ph_r107:
    ld   e_done >> 8, y
    jmp  e_done
esv_fail:
    ld   3, ac
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r108, [x]
    ld   LINK_HI, x
    ld   ph_r108 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r108:
    ld   e_done >> 8, y
    jmp  e_done

; e_cpsec - pages ed_pe and ed_pe + 1 to SBUF (a leaf, the map at FF)
e_getpix:
    ld   [ed_qy], ac
    add  16, ac
    shl
    bcc  lw14
    or   1, ac
lw14:
    ld   ac, [T1]
    ld   [ed_wide], ac
    bne  egp_w
    ld   [ed_qx], ac
    shl
    bra  egp_pg
egp_w:
    ld   [ed_qx], ac
egp_pg:
    add  [ed_pb], ac
    ld   ac, [T0]
    ld   ac, y
    ld   [T1], x
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; e_dot - the point ed_cx, ed_cy: a pixel, or the brush around it

#addr 0x1300
e_cpsec:
    ld   [ed_pe], ac
    ld   ac, [T0]
    ld   SBUF >> 8, ac
    ld   ac, [T1]
    clr  ac
    ld   ac, [T2]
ecs_l:
    ld   [T0], y
    ld   [T2], x
    ld   [y,x], ac
    ld   [T1], y
    ld   ac, [y,x]
    ld   [T2], ac
    inc
    ld   ac, [T2]
    bne  ecs_l
    ld   [T1], ac
    xor  (SBUF >> 8) + 1, ac
    beq  ecs_x
    ld   [T0], ac
    inc
    ld   ac, [T0]
    ld   [T1], ac
    inc
    ld   ac, [T1]
    bra  ecs_l
ecs_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; do_new - the whole picture the paper color, no name
edo_new:
    ld   [ed_tb], ac
    ld   ac, [ed_was]
    beq  edn_1
    ld   LINK_LO, x             ; CALL etb_hide
    ld   ph_r109, [x]
    ld   LINK_HI, x
    ld   ph_r109 >> 8, [x]
    ld   etb_hide >> 8, y
    jmp  etb_hide
ph_r109:
edn_1:
    ld   0x60, ac
    ld   ac, [T0]
    clr  ac
    ld   ac, [T1]
edn_l:
    ld   [T0], y
    ld   [T1], x
    ld   [ed_paper], ac
    ld   ac, [y,x]
    ld   [T1], ac
    inc
    ld   ac, [T1]
    bne  edn_l
    ld   [T0], ac
    inc
    ld   ac, [T0]
    bne  edn_l
    ld   ac, [ed_named]
    ld   ac, [ed_dirty]
    ld   ac, [ed_msg]
    ld   LINK_LO, x             ; CALL e_jreset
    ld   ph_r110, [x]
    ld   LINK_HI, x
    ld   ph_r110 >> 8, [x]
    ld   e_jreset >> 8, y
    jmp  e_jreset
ph_r110:
    ld   [ed_was], ac
    beq  edn_2
    ld   LINK_LO, x             ; CALL etb_show
    ld   ph_r111, [x]
    ld   LINK_HI, x
    ld   ph_r111 >> 8, [x]
    ld   etb_show >> 8, y
    jmp  etb_show
ph_r111:
edn_2:
    ld   e_done >> 8, y
    jmp  e_done

; do_exit - back to the viewer: the bar away, the keys up (the viewer's
; Esc leaves the program), the folder counted again, the picture from the
; card
edo_exit:
    ld   [ed_tb], ac
    beq  edx_1
    ld   LINK_LO, x             ; CALL etb_hide
    ld   ph_r112, [x]
    ld   LINK_HI, x
    ld   ph_r112 >> 8, [x]
    ld   etb_hide >> 8, y
    jmp  etb_hide
ph_r112:
edx_1:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   ph_r113, [x]
    ld   LINK_HI, x
    ld   ph_r113 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
ph_r113:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   ph_r114, [x]
    ld   LINK_HI, x
    ld   ph_r114 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ph_r114:
    ld   [KBD_NOW], ac
    and  1, ac
    beq  edx_1
edx_2:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   ph_r115, [x]
    ld   LINK_HI, x
    ld   ph_r115 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ph_r115:
    bne  edx_2
    ld   LINK_LO, x             ; CALL tally
    ld   ph_r116, [x]
    ld   LINK_HI, x
    ld   ph_r116 >> 8, [x]
    ld   tally >> 8, y
    jmp  tally
ph_r116:
    ld   show >> 8, y
    jmp  show

; ============================================================
; drawing (the map at FF)
; ============================================================
; e_pset - pixel ed_qx, ed_qy = ed_col, its old color noted in the journal
; (a leaf); nothing outside the picture or in the bar's rows
etb_mode:
    ld   [ed_mlo], ac
    ld   ac, [T2]
    ld   32, ac
    ld   ac, [T3]
etm_1:
    ld   [ed_mpg], y
    ld   [T2], x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T2], ac
    add  32, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [T2], ac
    inc
    ld   ac, [T2]
    ld   [T3], ac
    dec
    ld   ac, [T3]
    bne  etm_1
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tb_tools - the bar's first text row: the tool chosen white on black

#addr 0x1400
e_pset:
    ld   [ed_xmax], ac
    sub  [ed_qx], ac
    bcs  eps_out
    ld   [ed_qy], ac
    sub  [ed_cy0], ac
    bcs  eps_out
    ld   [ed_cy1], ac
    sub  [ed_qy], ac
    bcs  eps_out
    ld   [ed_qy], ac
    add  16, ac
    shl
    bcc  lw13
    or   1, ac
lw13:
    ld   ac, [T1]               ; T1 = the low byte
    ld   [ed_wide], ac
    bne  eps_w
    ld   [ed_qx], ac
    shl
    bra  eps_pg
eps_w:
    ld   [ed_qx], ac
eps_pg:
    add  [ed_pb], ac
    ld   ac, [T0]               ; T0 = the page
    ld   ac, y
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [T2]               ; T2 = the old color
    xor  [ed_col], ac
    beq  eps_out
    ld   [T0], ac               ; T3 = the even page's (80 across)
    sub  1, y
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [ed_jov], ac
    bne  eps_put
    ld   [ed_jh], ac
    xor  JPAGES, ac
    bne  eps_j
    ld   1, ac
    ld   ac, [ed_jov]
    bra  eps_put
eps_j:
    ld   [ed_jl], x
    ld   [ed_jh], ac
    add  JA >> 8, y
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [ed_jh], ac
    add  JB >> 8, y
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [ed_jh], ac
    add  JC >> 8, y
    ld   [T2], ac
    ld   ac, [y,x]
    ld   [ed_jh], ac
    add  JD >> 8, y
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [ed_jl], ac
    inc
    ld   ac, [ed_jl]
    bne  eps_put
    ld   [ed_jh], ac
    inc
    ld   ac, [ed_jh]
eps_put:
    ld   [T0], y
    ld   [T1], x
    ld   [ed_col], ac
    ld   ac, [y,x]
    ld   [ed_wide], ac
    bne  eps_out
    ld   [T0], ac
    sub  1, y
    ld   [ed_col], ac
    ld   ac, [y,x]
eps_out:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; e_getpix - AC = pixel ed_qx, ed_qy; T0 = its page, T1 = its low byte (a
; leaf)
e_line:
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
    ld   1, ac
    ld   ac, [ed_sx]
    ld   [ed_x1], ac
    sub  [ed_x0], ac
    bcc  eln_dxp
    ld   0xFF, ac
    ld   ac, [ed_sx]
    ld   [ed_x0], ac
    sub  [ed_x1], ac
eln_dxp:
    ld   ac, [ed_dx]
    ld   1, ac
    ld   ac, [ed_sy]
    ld   [ed_y1], ac
    sub  [ed_y0], ac
    bcc  eln_dyp
    ld   0xFF, ac
    ld   ac, [ed_sy]
    ld   [ed_y0], ac
    sub  [ed_y1], ac
eln_dyp:
    ld   ac, [ed_dy]
    ld   [ed_x0], ac
    ld   ac, [ed_cx]
    ld   [ed_y0], ac
    ld   ac, [ed_cy]
    ld   [ed_dx], ac
    sub  [ed_dy], ac
    bcs  eln_steep
    ld   eline_x >> 8, y
    jmp  eline_x
eln_steep:
    ld   eline_y >> 8, y
    jmp  eline_y


#addr 0x1500
e_dot:
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
    ld   [ed_stmp], ac
    bne  edt_st
    ld   [ed_cx], ac
    ld   ac, [ed_qx]
    ld   [ed_cy], ac
    ld   ac, [ed_qy]
    ld   LINK_LO, x             ; CALL e_pset
    ld   ph_r117, [x]
    ld   LINK_HI, x
    ld   ph_r117 >> 8, [x]
    ld   e_pset >> 8, y
    jmp  e_pset
ph_r117:
    ld   e_leave >> 8, y
    jmp  e_leave
edt_st:
    ld   [ed_sw], ac
    shr  ac
    ld   ac, [T3]
    ld   [ed_cx], ac
    sub  [T3], ac
    dec
    ld   ac, [ed_sox]
    ld   [ed_sh], ac
    shr  ac
    ld   ac, [T3]
    ld   [ed_cy], ac
    sub  [T3], ac
    dec
    ld   ac, [ed_soy]
    ld   [ed_sh], ac
    ld   ac, [ed_sj]
edt_row:
    ld   [ed_sw], ac
    ld   ac, [ed_si]
edt_col:
    ld   [ed_sox], ac
    add  [ed_si], ac
    ld   ac, [ed_qx]
    ld   [ed_soy], ac
    add  [ed_sj], ac
    ld   ac, [ed_qy]
    ld   LINK_LO, x             ; CALL e_pset
    ld   ph_r118, [x]
    ld   LINK_HI, x
    ld   ph_r118 >> 8, [x]
    ld   e_pset >> 8, y
    jmp  e_pset
ph_r118:
    ld   [ed_si], ac
    dec
    ld   ac, [ed_si]
    bne  edt_col
    ld   [ed_sj], ac
    dec
    ld   ac, [ed_sj]
    bne  edt_row
    ld   e_leave >> 8, y
    jmp  e_leave

; e_line - points from ed_x0, ed_y0 to ed_x1, ed_y1
eline_x:
    ld   [ed_dx], ac
    ld   ac, [ed_n]
    shr  ac
    ld   ac, [ed_err]
elx_loop:
    ld   LINK_LO, x             ; CALL e_dot
    ld   ph_r119, [x]
    ld   LINK_HI, x
    ld   ph_r119 >> 8, [x]
    ld   e_dot >> 8, y
    jmp  e_dot
ph_r119:
    ld   [ed_n], ac
    beq  elx_end
    dec
    ld   ac, [ed_n]
    ld   [ed_cx], ac
    add  [ed_sx], ac
    ld   ac, [ed_cx]
    ld   [ed_err], ac
    sub  [ed_dy], ac
    bcc  elx_keep
    add  [ed_dx], ac
    ld   ac, [ed_err]
    ld   [ed_cy], ac
    add  [ed_sy], ac
    ld   ac, [ed_cy]
    bra  elx_loop
elx_keep:
    ld   ac, [ed_err]
    bra  elx_loop
elx_end:
    ld   e_leave >> 8, y
    jmp  e_leave

eline_y:
    ld   [ed_dy], ac
    ld   ac, [ed_n]
    shr  ac
    ld   ac, [ed_err]
ely_loop:
    ld   LINK_LO, x             ; CALL e_dot
    ld   ph_r120, [x]
    ld   LINK_HI, x
    ld   ph_r120 >> 8, [x]
    ld   e_dot >> 8, y
    jmp  e_dot
ph_r120:
    ld   [ed_n], ac
    beq  ely_end
    dec
    ld   ac, [ed_n]
    ld   [ed_cy], ac
    add  [ed_sy], ac
    ld   ac, [ed_cy]
    ld   [ed_err], ac
    sub  [ed_dx], ac
    bcc  ely_keep
    add  [ed_dy], ac
    ld   ac, [ed_err]
    ld   [ed_cx], ac
    add  [ed_sx], ac
    ld   ac, [ed_cx]
    bra  ely_loop
ely_keep:
    ld   ac, [ed_err]
    bra  ely_loop
ely_end:
    ld   e_leave >> 8, y
    jmp  e_leave

; e_shape - the line or the rectangle from ed_ax, ed_ay to ed_lx, ed_ly

#addr 0x1600
e_shape:
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
    ld   [ed_tool], ac
    xor  3, ac
    bne  esp_rect
    ld   [ed_ax], ac
    ld   ac, [ed_x0]
    ld   [ed_ay], ac
    ld   ac, [ed_y0]
    ld   [ed_lx], ac
    ld   ac, [ed_x1]
    ld   [ed_ly], ac
    ld   ac, [ed_y1]
    ld   LINK_LO, x             ; CALL e_line
    ld   ph_r121, [x]
    ld   LINK_HI, x
    ld   ph_r121 >> 8, [x]
    ld   e_line >> 8, y
    jmp  e_line
ph_r121:
    ld   e_leave >> 8, y
    jmp  e_leave
esp_rect:
    ld   [ed_ax], ac            ; the top
    ld   ac, [ed_x0]
    ld   [ed_ay], ac
    ld   ac, [ed_y0]
    ld   ac, [ed_y1]
    ld   [ed_lx], ac
    ld   ac, [ed_x1]
    ld   LINK_LO, x             ; CALL e_line
    ld   ph_r122, [x]
    ld   LINK_HI, x
    ld   ph_r122 >> 8, [x]
    ld   e_line >> 8, y
    jmp  e_line
ph_r122:
    ld   [ed_ax], ac            ; the bottom
    ld   ac, [ed_x0]
    ld   [ed_ly], ac
    ld   ac, [ed_y0]
    ld   ac, [ed_y1]
    ld   [ed_lx], ac
    ld   ac, [ed_x1]
    ld   LINK_LO, x             ; CALL e_line
    ld   ph_r123, [x]
    ld   LINK_HI, x
    ld   ph_r123 >> 8, [x]
    ld   e_line >> 8, y
    jmp  e_line
ph_r123:
    ld   e_rect2 >> 8, y
    jmp  e_rect2

e_rect2:
    ld   [ed_ax], ac            ; the left
    ld   ac, [ed_x0]
    ld   ac, [ed_x1]
    ld   [ed_ay], ac
    ld   ac, [ed_y0]
    ld   [ed_ly], ac
    ld   ac, [ed_y1]
    ld   LINK_LO, x             ; CALL e_line
    ld   ph_r124, [x]
    ld   LINK_HI, x
    ld   ph_r124 >> 8, [x]
    ld   e_line >> 8, y
    jmp  e_line
ph_r124:
    ld   [ed_lx], ac            ; the right
    ld   ac, [ed_x0]
    ld   ac, [ed_x1]
    ld   [ed_ay], ac
    ld   ac, [ed_y0]
    ld   [ed_ly], ac
    ld   ac, [ed_y1]
    ld   LINK_LO, x             ; CALL e_line
    ld   ph_r125, [x]
    ld   LINK_HI, x
    ld   ph_r125 >> 8, [x]
    ld   e_line >> 8, y
    jmp  e_line
ph_r125:
    ld   e_leave >> 8, y
    jmp  e_leave

; e_jundo - everything the journal notes put back, the last first (a
; leaf; it only writes the video RAM)
e_fill:
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
    ld   LINK_LO, x             ; CALL e_getpix
    ld   ph_r126, [x]
    ld   LINK_HI, x
    ld   ph_r126 >> 8, [x]
    ld   e_getpix >> 8, y
    jmp  e_getpix
ph_r126:
    ld   ac, [ed_ftg]
    xor  [ed_col], ac
    bne  efl_go
    ld   e_leave >> 8, y
    jmp  e_leave
efl_go:
    ld   1, ac
    ld   ac, [ed_jk]
    ld   ac, [ed_spl]
    clr  ac
    ld   ac, [ed_sph]
    ld   [ed_ftg], ac
    ld   ac, [ed_jold]
    ld   SA >> 8, y
    ld   0, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   SB >> 8, y
    ld   [T1], ac
    ld   ac, [y,x]
    ld   efill_loop >> 8, y
    jmp  efill_loop


#addr 0x1700
e_jundo:
eju_loop:
    ld   [ed_jl], ac
    bne  eju_dec
    ld   [ed_jh], ac
    beq  eju_end
    dec
    ld   ac, [ed_jh]
    clr  ac
eju_dec:
    dec
    ld   ac, [ed_jl]
    ld   ac, x
    ld   [ed_jh], ac
    add  JA >> 8, y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [ed_jh], ac
    add  JB >> 8, y
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [ed_jh], ac
    add  JC >> 8, y
    ld   [y,x], ac
    ld   ac, [T2]
    ld   [ed_jh], ac
    add  JD >> 8, y
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [ed_jk], ac
    bne  eju_span
    ld   [T0], y
    ld   [T1], x
    ld   [T2], ac
    ld   ac, [y,x]
    ld   [ed_wide], ac
    bne  eju_loop
    ld   [T0], ac
    sub  1, y
    ld   [T3], ac
    ld   ac, [y,x]
    bra  eju_loop
eju_span:                        ; a run: pages T0 to T2 = the old color
    ld   [T1], x
eju_s1:
    ld   [T0], y
    ld   [ed_jold], ac
    ld   ac, [y,x]
    ld   [ed_wide], ac
    bne  eju_s2
    ld   [T0], ac
    sub  1, y
    ld   [ed_jold], ac
    ld   ac, [y,x]
eju_s2:
    ld   [T0], ac
    xor  [T2], ac
    beq  eju_loop
    ld   [T0], ac
    add  [ed_fst], ac
    ld   ac, [T0]
    bra  eju_s1
eju_end:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; e_fill - the pixels of one color joined to ed_qx, ed_qy = ed_col: a
; stack of pixels still to look at; for each, its whole run in its row is
; filled and noted, and the first pixel of every run of the old color in
; the rows above and below goes on the stack.  It works in pages and low
; bytes (a row above: low - 2, but 254 above 1; none above 32; a row
; below: low + 2, but 1 below 254; none below 255)
; ============================================================
efill_loop:
    ld   [ed_spl], ac
    bne  efo_dec
    ld   [ed_sph], ac
    bne  efo_hi
    ld   e_leave >> 8, y
    jmp  e_leave
efo_hi:
    dec
    ld   ac, [ed_sph]
    clr  ac
efo_dec:
    dec
    ld   ac, [ed_spl]
    ld   ac, x
    ld   [ed_sph], ac
    add  SA >> 8, y
    ld   [y,x], ac
    ld   ac, [ed_fpg]
    ld   [ed_sph], ac
    add  SB >> 8, y
    ld   [y,x], ac
    ld   ac, [ed_flo]
    ld   ac, x
    ld   [ed_fpg], y
    ld   [y,x], ac
    xor  [ed_ftg], ac
    bne  efill_loop              ; filled since it went on the stack
    ld   [ed_fpg], ac
    ld   ac, [ed_fl]
efs_l:                           ; left while the pixel before is that color
    ld   [ed_fl], ac
    xor  [ed_pb], ac
    beq  efs_lx
    ld   [ed_fl], ac
    sub  [ed_fst], ac
    ld   ac, y
    ld   ac, [T4]
    ld   [y,x], ac
    xor  [ed_ftg], ac
    bne  efs_lx
    ld   [T4], ac
    ld   ac, [ed_fl]
    bra  efs_l
efs_lx:
    ld   [ed_fpg], ac
    ld   ac, [ed_fr]
efs_r:                           ; and right
    ld   [ed_fr], ac
    xor  0xFF, ac
    beq  efs_rx
    ld   [ed_fr], ac
    add  [ed_fst], ac
    ld   ac, y
    ld   ac, [T4]
    ld   [y,x], ac
    xor  [ed_ftg], ac
    bne  efs_rx
    ld   [T4], ac
    ld   ac, [ed_fr]
    bra  efs_r
efs_rx:
    ld   efill_put >> 8, y
    jmp  efill_put


#addr 0x1800
efill_put:
    ld   [ed_flo], x
    ld   [ed_fl], ac
    ld   ac, [T4]
efu_l:
    ld   [T4], y
    ld   [ed_col], ac
    ld   ac, [y,x]
    ld   [ed_wide], ac
    bne  efu_n
    ld   [T4], ac
    sub  1, y
    ld   [ed_col], ac
    ld   ac, [y,x]
efu_n:
    ld   [T4], ac
    xor  [ed_fr], ac
    beq  efu_j
    ld   [T4], ac
    add  [ed_fst], ac
    ld   ac, [T4]
    bra  efu_l
efu_j:                           ; the run into the journal
    ld   [ed_jov], ac
    bne  efu_x
    ld   [ed_jh], ac
    xor  JPAGES, ac
    bne  efu_s
    ld   1, ac
    ld   ac, [ed_jov]
    bra  efu_x
efu_s:
    ld   [ed_jl], x
    ld   [ed_jh], ac
    add  JA >> 8, y
    ld   [ed_fl], ac
    ld   ac, [y,x]
    ld   [ed_jh], ac
    add  JB >> 8, y
    ld   [ed_flo], ac
    ld   ac, [y,x]
    ld   [ed_jh], ac
    add  JC >> 8, y
    ld   [ed_fr], ac
    ld   ac, [y,x]
    ld   [ed_jl], ac
    inc
    ld   ac, [ed_jl]
    bne  efu_x
    ld   [ed_jh], ac
    inc
    ld   ac, [ed_jh]
efu_x:
    ld   efill_nb >> 8, y
    jmp  efill_nb

efill_nb:
    ld   [ed_flo], ac           ; the row above
    xor  32, ac
    beq  efn_dn
    ld   [ed_flo], ac
    xor  1, ac
    bne  efn_u2
    ld   254, ac
    bra  efn_u3
efn_u2:
    ld   [ed_flo], ac
    sub  2, ac
efn_u3:
    ld   ac, [ed_nlo]
    ld   LINK_LO, x             ; CALL e_fscan
    ld   ph_r127, [x]
    ld   LINK_HI, x
    ld   ph_r127 >> 8, [x]
    ld   e_fscan >> 8, y
    jmp  e_fscan
ph_r127:
efn_dn:
    ld   [ed_flo], ac           ; the row below
    xor  255, ac
    beq  efn_x
    ld   [ed_flo], ac
    xor  254, ac
    bne  efn_d2
    ld   1, ac
    bra  efn_d3
efn_d2:
    ld   [ed_flo], ac
    add  2, ac
efn_d3:
    ld   ac, [ed_nlo]
    ld   LINK_LO, x             ; CALL e_fscan
    ld   ph_r128, [x]
    ld   LINK_HI, x
    ld   ph_r128 >> 8, [x]
    ld   e_fscan >> 8, y
    jmp  e_fscan
ph_r128:
efn_x:
    ld   efill_loop >> 8, y
    jmp  efill_loop

; e_fscan - row ed_nlo, pages ed_fl to ed_fr: the first pixel of each run
; of the old color onto the stack (a leaf; a full stack takes no more)
e_fscan:
    clr  ac
    ld   ac, [ed_run]
    ld   [ed_fl], ac
    ld   ac, [T4]
efc_l:
    ld   [T4], y
    ld   [ed_nlo], x
    ld   [y,x], ac
    xor  [ed_ftg], ac
    beq  efc_t
    clr  ac
    ld   ac, [ed_run]
    bra  efc_n
efc_t:
    ld   [ed_run], ac
    bne  efc_n
    ld   1, ac
    ld   ac, [ed_run]
    ld   [ed_sph], ac
    xor  2, ac
    beq  efc_n
    ld   [ed_spl], x
    ld   [ed_sph], ac
    add  SA >> 8, y
    ld   [T4], ac
    ld   ac, [y,x]
    ld   [ed_sph], ac
    add  SB >> 8, y
    ld   [ed_nlo], ac
    ld   ac, [y,x]
    ld   [ed_spl], ac
    inc
    ld   ac, [ed_spl]
    bne  efc_n
    ld   [ed_sph], ac
    inc
    ld   ac, [ed_sph]
efc_n:
    ld   [T4], ac
    xor  [ed_fr], ac
    beq  efc_x
    ld   [T4], ac
    add  [ed_fst], ac
    ld   ac, [T4]
    bra  efc_l
efc_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the bar
; ============================================================
; tb_show - the picture under the bar kept, the bar drawn, its rows' modes

#addr 0x1900
etb_show:
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
    ld   1, ac
    ld   ac, [ed_tb]
    ld   ac, [ed_tbm]
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL etb_save
    ld   ph_r129, [x]
    ld   LINK_HI, x
    ld   ph_r129 >> 8, [x]
    ld   etb_save >> 8, y
    jmp  etb_save
ph_r129:
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL etb_tools
    ld   ph_r130, [x]
    ld   LINK_HI, x
    ld   ph_r130 >> 8, [x]
    ld   etb_tools >> 8, y
    jmp  etb_tools
ph_r130:
    ld   LINK_LO, x             ; CALL etb_stat
    ld   ph_r131, [x]
    ld   LINK_HI, x
    ld   ph_r131 >> 8, [x]
    ld   etb_stat >> 8, y
    jmp  etb_stat
ph_r131:
    ld   LINK_LO, x             ; CALL etb_pal
    ld   ph_r132, [x]
    ld   LINK_HI, x
    ld   ph_r132 >> 8, [x]
    ld   etb_pal >> 8, y
    jmp  etb_pal
ph_r132:
    ld   LINK_LO, x             ; CALL etb_ink
    ld   ph_r133, [x]
    ld   LINK_HI, x
    ld   ph_r133 >> 8, [x]
    ld   etb_ink >> 8, y
    jmp  etb_ink
ph_r133:
    ld   0x04, ac
    ld   ac, [T0]
    ld   0x07, ac
    ld   ac, [T1]
    ld   LINK_LO, x             ; CALL etb_mode
    ld   ph_r134, [x]
    ld   LINK_HI, x
    ld   ph_r134 >> 8, [x]
    ld   etb_mode >> 8, y
    jmp  etb_mode
ph_r134:
    ld   [ed_tby], ac
    beq  etw_top
    clr  ac
    ld   ac, [ed_cy0]
    ld   207, ac
    ld   ac, [ed_cy1]
    ld   e_leave >> 8, y
    jmp  e_leave
etw_top:
    ld   32, ac
    ld   ac, [ed_cy0]
    ld   239, ac
    ld   ac, [ed_cy1]
    ld   e_leave >> 8, y
    jmp  e_leave

; tb_hide - the picture back, and its rows' mode
etb_hide:
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
    ld   ac, [ed_bl]
    ld   ac, [ed_tb]
    ld   ac, [ed_cy0]
    ld   239, ac
    ld   ac, [ed_cy1]
    ld   TBS >> 8, ac
    ld   ac, [ed_bh]
    ld   0x60, ac
    ld   ac, [ed_pe]
eth_l:
    ld   [ed_pe], ac
    ld   ac, [R6]
    inc
    ld   ac, [R7]
    ld   LINK_LO, x             ; CALL etb_pair
    ld   ph_r135, [x]
    ld   LINK_HI, x
    ld   ph_r135 >> 8, [x]
    ld   etb_pair >> 8, y
    jmp  etb_pair
ph_r135:
    ld   [ed_pe], ac
    add  2, ac
    ld   ac, [ed_pe]
    bne  eth_l
    ld   [ph_mode], ac
    ld   ac, [T0]
    ld   ac, [T1]
    ld   LINK_LO, x             ; CALL etb_mode
    ld   ph_r136, [x]
    ld   LINK_HI, x
    ld   ph_r136 >> 8, [x]
    ld   etb_mode >> 8, y
    jmp  etb_mode
ph_r136:
    ld   e_leave >> 8, y
    jmp  e_leave

; tb_save - the bar's rows of every pair of pages to TBS: the odd page's
; 32, then the even page's last 16 (a leaf, the map at FF)

#addr 0x1A00
etb_save:
    clr  ac
    ld   ac, [ed_bl]
    ld   TBS >> 8, ac
    ld   ac, [ed_bh]
    ld   0x60, ac
    ld   ac, [ed_pe]
ets_pair:
    ld   [ed_pe], ac
    inc
    ld   ac, [T0]
    ld   [ed_tlo], ac
    ld   ac, [T1]
    ld   32, ac
    ld   ac, [T2]
ets_b:
    ld   [T0], y
    ld   [T1], x
    ld   [y,x], ac
    ld   [ed_bh], y
    ld   [ed_bl], x
    ld   ac, [y,x]
    ld   [ed_bl], ac
    inc
    ld   ac, [ed_bl]
    bne  ets_c
    ld   [ed_bh], ac
    inc
    ld   ac, [ed_bh]
ets_c:
    ld   [T1], ac
    add  2, ac
    ld   ac, [T1]
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  ets_b
    ld   [T0], ac
    and  1, ac
    beq  ets_next
    ld   [ed_pe], ac
    ld   ac, [T0]
    ld   [ed_tlo], ac
    add  32, ac
    ld   ac, [T1]
    ld   16, ac
    ld   ac, [T2]
    bra  ets_b
ets_next:
    ld   [ed_pe], ac
    add  2, ac
    ld   ac, [ed_pe]
    bne  ets_pair
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tb_pair - the next pair's 48 bytes from TBS to the bar's rows of pages
; R7 (the odd one) and R6 (a leaf)
etb_pair:
    ld   [R7], ac
    ld   ac, [T0]
    ld   [ed_tlo], ac
    ld   ac, [T1]
    ld   32, ac
    ld   ac, [T2]
etp_b:
    ld   [ed_bh], y
    ld   [ed_bl], x
    ld   [y,x], ac
    ld   [T0], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [ed_bl], ac
    inc
    ld   ac, [ed_bl]
    bne  etp_c
    ld   [ed_bh], ac
    inc
    ld   ac, [ed_bh]
etp_c:
    ld   [T1], ac
    add  2, ac
    ld   ac, [T1]
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  etp_b
    ld   [T0], ac
    xor  [R7], ac
    bne  etp_x
    ld   [R6], ac
    ld   ac, [T0]
    ld   [ed_tlo], ac
    add  32, ac
    ld   ac, [T1]
    ld   16, ac
    ld   ac, [T2]
    bra  etp_b
etp_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tb_mode - the bar's 64 mode bytes: T0 its first 32 lines, T1 the rest
; (a leaf)
etb_tools:
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
    ld   ac, [ed_tc]
    ld   [ed_tlo], ac
    ld   ac, [ed_tr]
ett_l:
    ld   [ed_tc], ac
    add  80, x
    ld   etb_txt >> 8, y
    ld   [y,x], ac
    dec
    xor  [ed_tool], ac
    beq  ett_set
    ld   0x80, ac
ett_set:
    ld   ac, [ed_inv]
    ld   [ed_tc], x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r137, [x]
    ld   LINK_HI, x
    ld   ph_r137 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r137:
    ld   [ed_tc], ac
    xor  80, ac
    bne  ett_l
    ld   e_leave >> 8, y
    jmp  e_leave

; tb_stat - the status row

#addr 0x1B00
etb_stat:
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
    ld   [ed_tlo], ac
    add  16, ac
    ld   ac, [ed_tr]
    ld   0x80, ac
    ld   ac, [ed_inv]
    clr  ac
    ld   ac, [ed_tc]
etx_l:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r138, [x]
    ld   LINK_HI, x
    ld   ph_r138 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r138:
    ld   [ed_tc], ac
    xor  80, ac
    bne  etx_l
    ld   LINK_LO, x             ; CALL est_name
    ld   ph_r139, [x]
    ld   LINK_HI, x
    ld   ph_r139 >> 8, [x]
    ld   est_name >> 8, y
    jmp  est_name
ph_r139:
    ld   LINK_LO, x             ; CALL est_size
    ld   ph_r140, [x]
    ld   LINK_HI, x
    ld   ph_r140 >> 8, [x]
    ld   est_size >> 8, y
    jmp  est_size
ph_r140:
    ld   28, ac
    ld   ac, [ed_tc]
    ld   0x58, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r141, [x]
    ld   LINK_HI, x
    ld   ph_r141 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r141:
    ld   34, ac
    ld   ac, [ed_tc]
    ld   0x59, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r142, [x]
    ld   LINK_HI, x
    ld   ph_r142 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r142:
    ld   LINK_LO, x             ; CALL est_xy
    ld   ph_r143, [x]
    ld   LINK_HI, x
    ld   ph_r143 >> 8, [x]
    ld   est_xy >> 8, y
    jmp  est_xy
ph_r143:
    ld   [ed_msg], ac
    ld   LINK_LO, x             ; CALL est_msg
    ld   ph_r144, [x]
    ld   LINK_HI, x
    ld   ph_r144 >> 8, [x]
    ld   est_msg >> 8, y
    jmp  est_msg
ph_r144:
    ld   e_leave >> 8, y
    jmp  e_leave

; st_name - the file's name, and a * when it is changed
est_size:
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
    ld   [ed_tlo], ac
    add  16, ac
    ld   ac, [ed_tr]
    ld   0x80, ac
    ld   ac, [ed_inv]
    ld   15, ac
    ld   ac, [ed_tc]
    ld   es_size & 0xFF, ac
    ld   ac, [R0]
    ld   es_size >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL etputs
    ld   ph_r148, [x]
    ld   LINK_HI, x
    ld   ph_r148 >> 8, [x]
    ld   etputs >> 8, y
    jmp  etputs
ph_r148:
    ld   [ed_size], ac
    or   0x30, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r149, [x]
    ld   LINK_HI, x
    ld   ph_r149 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r149:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r150, [x]
    ld   LINK_HI, x
    ld   ph_r150 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r150:
    ld   0x3E, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r151, [x]
    ld   LINK_HI, x
    ld   ph_r151 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r151:
    ld   e_leave >> 8, y
    jmp  e_leave


#addr 0x1C00
est_name:
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
    ld   [ed_tlo], ac
    add  16, ac
    ld   ac, [ed_tr]
    ld   0x80, ac
    ld   ac, [ed_inv]
    ld   1, ac
    ld   ac, [ed_tc]
    ld   [ed_named], ac
    beq  esn_new
    ld   ph_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    bra  esn_p
esn_new:
    ld   es_new & 0xFF, ac
    ld   ac, [R0]
    ld   es_new >> 8, ac
    ld   ac, [R1]
esn_p:
    ld   LINK_LO, x             ; CALL etputs
    ld   ph_r145, [x]
    ld   LINK_HI, x
    ld   ph_r145 >> 8, [x]
    ld   etputs >> 8, y
    jmp  etputs
ph_r145:
esn_pad:
    ld   [ed_tc], ac
    xor  13, ac
    beq  esn_st
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r146, [x]
    ld   LINK_HI, x
    ld   ph_r146 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r146:
    bra  esn_pad
esn_st:
    ld   [ed_dirty], ac
    beq  esn_sp
    ld   0x2A, ac
    bra  esn_c
esn_sp:
    ld   0x20, ac
esn_c:
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r147, [x]
    ld   LINK_HI, x
    ld   ph_r147 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r147:
    ld   e_leave >> 8, y
    jmp  e_leave

est_xy:
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
    ld   [ed_tlo], ac
    add  16, ac
    ld   ac, [ed_tr]
    ld   0x80, ac
    ld   ac, [ed_inv]
    ld   30, ac
    ld   ac, [ed_tc]
    ld   [ed_x], ac
    ld   LINK_LO, x             ; CALL etnum
    ld   ph_r152, [x]
    ld   LINK_HI, x
    ld   ph_r152 >> 8, [x]
    ld   etnum >> 8, y
    jmp  etnum
ph_r152:
    ld   36, ac
    ld   ac, [ed_tc]
    ld   [ed_y], ac
    ld   LINK_LO, x             ; CALL etnum
    ld   ph_r153, [x]
    ld   LINK_HI, x
    ld   ph_r153 >> 8, [x]
    ld   etnum >> 8, y
    jmp  etnum
ph_r153:
    ld   e_leave >> 8, y
    jmp  e_leave

; st_msg - message AC on the status row (kept for when the bar is away)
est_msg:
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
    ld   ac, [ed_msg]
    ld   [ed_tb], ac
    beq  esm_x
    ld   [ed_msg], ac
    ld   LINK_LO, x             ; CALL e_mhead
    ld   ph_r154, [x]
    ld   LINK_HI, x
    ld   ph_r154 >> 8, [x]
    ld   e_mhead >> 8, y
    jmp  e_mhead
ph_r154:
    ld   LINK_LO, x             ; CALL e_mpad
    ld   ph_r155, [x]
    ld   LINK_HI, x
    ld   ph_r155 >> 8, [x]
    ld   e_mpad >> 8, y
    jmp  e_mpad
ph_r155:
esm_x:
    ld   e_leave >> 8, y
    jmp  e_leave


#addr 0x1D00
e_mhead:
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
    ld   ac, [ed_msg]
    add  emsgl & 0xFF, x
    ld   emsgl >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [ed_msg], ac
    add  emsgh & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   [ed_tlo], ac
    add  16, ac
    ld   ac, [ed_tr]
    ld   0x80, ac
    ld   ac, [ed_inv]
    ld   41, ac
    ld   ac, [ed_tc]
    ld   LINK_LO, x             ; CALL etputs
    ld   ph_r156, [x]
    ld   LINK_HI, x
    ld   ph_r156 >> 8, [x]
    ld   etputs >> 8, y
    jmp  etputs
ph_r156:
    ld   e_leave >> 8, y
    jmp  e_leave

e_mpad:
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
emp_l:
    ld   [ed_tc], ac
    xor  80, ac
    beq  emp_x
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r157, [x]
    ld   LINK_HI, x
    ld   ph_r157 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r157:
    bra  emp_l
emp_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; tputc - character AC at column ed_tc of the text row ed_tr, and the
; column on: 8 rows of the ROM's font to every 2nd byte of the column's
; odd page (a leaf; the map at 07)
etputc:
    xor  [ed_inv], ac
    ld   ac, [T0]
    ld   [ed_tc], ac
    shl
    add  0x61, ac
    ld   ac, [T2]
    ld   [ed_tr], ac
    ld   ac, [T1]
    clr  ac
    ld   ac, [T3]
etc_r:
    ld   [T3], ac
    add  LIB_FONT >> 8, y
    ld   [T0], x
    ld   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [T1], ac
    add  2, ac
    ld   ac, [T1]
    ld   [T3], ac
    inc
    ld   ac, [T3]
    xor  8, ac
    bne  etc_r
    ld   [ed_tc], ac
    inc
    ld   ac, [ed_tc]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tputs - the string at R1:R0
etputs:
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
etu_l:
    ld   [R0], x
    ld   [R1], y
    ld   [y,x], ac
    beq  etu_x
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r158, [x]
    ld   LINK_HI, x
    ld   ph_r158 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r158:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  etu_l
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  etu_l
etu_x:
    ld   e_leave >> 8, y
    jmp  e_leave

; tnum - AC as three digits

#addr 0x1E00
etnum:
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
    ld   ac, [ed_m]
    ld   0x30, ac
    ld   ac, [ed_k]
etn_h:
    ld   [ed_m], ac
    sub  100, ac
    bcs  etn_hx
    ld   ac, [ed_m]
    ld   [ed_k], ac
    inc
    ld   ac, [ed_k]
    bra  etn_h
etn_hx:
    ld   [ed_k], ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r159, [x]
    ld   LINK_HI, x
    ld   ph_r159 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r159:
    ld   0x30, ac
    ld   ac, [ed_k]
etn_t:
    ld   [ed_m], ac
    sub  10, ac
    bcs  etn_tx
    ld   ac, [ed_m]
    ld   [ed_k], ac
    inc
    ld   ac, [ed_k]
    bra  etn_t
etn_tx:
    ld   [ed_k], ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r160, [x]
    ld   LINK_HI, x
    ld   ph_r160 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r160:
    ld   [ed_m], ac
    or   0x30, ac
    ld   LINK_LO, x             ; CALL etputc
    ld   ph_r161, [x]
    ld   LINK_HI, x
    ld   ph_r161 >> 8, [x]
    ld   etputc >> 8, y
    jmp  etputc
ph_r161:
    ld   e_leave >> 8, y
    jmp  e_leave

; tb_pal - the 256 colors: 64 cells across, 4 rows of 4 picture rows (a
; leaf)
etb_pal:
    clr  ac
    ld   ac, [T0]
etq_j:
    ld   [T0], ac
    shl
    add  0x60, ac
    ld   ac, [T2]
    ld   [ed_tlo], ac
    add  32, ac
    ld   ac, [T1]
    ld   [T0], ac
    ld   ac, [T3]
    ld   16, ac
    ld   ac, [T4]
etq_r:
    ld   [T2], y
    ld   [T1], x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [T2], ac
    add  1, y
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [T1], ac
    add  2, ac
    ld   ac, [T1]
    ld   [T4], ac
    dec
    ld   ac, [T4]
    beq  etq_n
    and  3, ac
    bne  etq_r
    ld   [T3], ac
    add  64, ac
    ld   ac, [T3]
    bra  etq_r
etq_n:
    ld   [T0], ac
    inc
    ld   ac, [T0]
    xor  64, ac
    bne  etq_j
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tb_ink - right of the colors: the ink (cells 65-73) and the paper
; (75-79), black between (a leaf)
ep_cross2:
    ld   PSV >> 8, y
    ld   [ed_pn], x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [ed_pn], ac
    add  16, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [T0], y
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [ed_p2], ac
    beq  epc_s
    ld   [T0], ac
    add  1, y
    ld   [y,x], ac
    ld   ac, [T4]
    ld   [T3], ac
    ld   ac, [y,x]
epc_s:
    ld   PSV >> 8, y
    ld   [ed_pn], ac
    add  32, x
    ld   [T2], ac
    ld   ac, [y,x]
    ld   [ed_pn], ac
    add  48, x
    ld   [T4], ac
    ld   ac, [y,x]
    ld   [ed_pn], ac
    inc
    ld   ac, [ed_pn]
    ld   epc_n >> 8, y
    jmp  epc_n


#addr 0x2000
etb_ink:
    ld   64, ac
    ld   ac, [T0]
eti_j:
    ld   [T0], ac
    xor  64, ac
    beq  eti_v
    xor  64 ^ 74, ac
    beq  eti_v
    ld   [T0], ac
    sub  74, ac
    bcs  eti_ink
    ld   [ed_paper], ac
    bra  eti_v
eti_ink:
    ld   [ed_ink], ac
eti_v:
    ld   ac, [T3]
    ld   [T0], ac
    shl
    add  0x60, ac
    ld   ac, [T2]
    ld   [ed_tlo], ac
    add  32, ac
    ld   ac, [T1]
    ld   16, ac
    ld   ac, [T4]
eti_r:
    ld   [T2], y
    ld   [T1], x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [T2], ac
    add  1, y
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [T1], ac
    add  2, ac
    ld   ac, [T1]
    ld   [T4], ac
    dec
    ld   ac, [T4]
    bne  eti_r
    ld   [T0], ac
    inc
    ld   ac, [T0]
    xor  80, ac
    bne  eti_j
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the pointer: a cross on the picture and on the colors (white inside,
; black outside, the pixel in its middle left alone), an arrow on the
; text rows.  The screen bytes under it are kept in PSV
; ============================================================
ep_show:
    clr  ac
    ld   ac, [ed_pn]
    ld   0xFF, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [ed_zone], ac
    beq  epw_pic
    xor  3, ac
    beq  epw_pal
    ld   ep_arrow >> 8, y
    jmp  ep_arrow
epw_pic:
    ld   [ed_x], ac
    ld   ac, [ed_bx]
    ld   [ed_xmax], ac
    ld   ac, [ed_plim]
    ld   [ed_cy0], ac
    ld   ac, [ed_py0]
    ld   [ed_cy1], ac
    ld   ac, [ed_py1]
    ld   [ed_wide], ac
    xor  1, ac
    ld   ac, [ed_p2]
    ld   ep_cross >> 8, y
    jmp  ep_cross
epw_pal:
    ld   [ed_cc], ac
    ld   ac, [ed_bx]
    ld   79, ac
    ld   ac, [ed_plim]
    ld   [ed_tby], ac
    add  16, ac
    ld   ac, [ed_py0]
    add  15, ac
    ld   ac, [ed_py1]
    ld   1, ac
    ld   ac, [ed_p2]
    ld   ep_cross >> 8, y
    jmp  ep_cross

ep_cross:
    clr  ac
    ld   ac, [T5]
epc_l:
    ld   [T5], ac
    add  eptab & 0xFF, x
    ld   eptab >> 8, y
    ld   [y,x], ac
    add  [ed_bx], ac
    ld   ac, [ed_qx]
    ld   [ed_plim], ac
    sub  [ed_qx], ac
    bcs  epc_sk
    ld   [T5], ac
    add  (eptab & 0xFF) + 1, x
    ld   [y,x], ac
    add  [ed_y], ac
    ld   ac, [ed_qy]
    sub  [ed_py0], ac
    bcs  epc_sk
    ld   [ed_py1], ac
    sub  [ed_qy], ac
    bcs  epc_sk
    ld   [T5], ac
    add  (eptab & 0xFF) + 2, x
    ld   [y,x], ac
    ld   ac, [T3]               ; the color
    ld   [ed_qy], ac
    add  16, ac
    shl
    bcc  lw23
    or   1, ac
lw23:
    ld   ac, [T1]
    ld   [ed_p2], ac
    beq  epc_w
    ld   [ed_qx], ac
    shl
    bra  epc_p
epc_w:
    ld   [ed_qx], ac
epc_p:
    add  0x60, ac
    ld   ac, [T0]
    ld   ep_cross2 >> 8, y
    jmp  ep_cross2
epc_sk:
    ld   epc_n >> 8, y
    jmp  epc_n


#addr 0x2100
ep_arrow:
    clr  ac
    ld   ac, [ed_p2]
    ld   ac, [T5]
    ld   [ed_cc], ac
    shl
    add  0x61, ac
    ld   ac, [T0]
    ld   16, ac
    sub  [ed_zr], ac
    ld   ac, [T6]
    sub  9, ac
    bcs  epa_ok
    ld   8, ac
    ld   ac, [T6]
epa_ok:
    ld   [ed_zr], ac
    shl
    add  [ed_tlo], ac
    ld   ac, [T1]
epa_l:
    ld   PSV >> 8, y
    ld   [ed_pn], x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [ed_pn], ac
    add  16, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [T0], y
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   [T5], ac
    add  earrow & 0xFF, x
    ld   earrow >> 8, y
    ld   [y,x], ac
    xor  [T2], ac
    ld   [T0], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   PSV >> 8, y
    ld   [ed_pn], ac
    add  32, x
    ld   [T2], ac
    ld   ac, [y,x]
    ld   [ed_pn], ac
    inc
    ld   ac, [ed_pn]
    ld   [T1], ac
    add  2, ac
    ld   ac, [T1]
    ld   [T5], ac
    inc
    ld   ac, [T5]
    xor  [T6], ac
    bne  epa_l
    ld   0x07, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; p_hide - the screen as it was under the pointer (a leaf)
ep_hide:
epd_l:
    ld   [ed_pn], ac
    beq  epd_x
    dec
    ld   ac, [ed_pn]
    ld   ac, x
    ld   PSV >> 8, y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [ed_pn], ac
    add  16, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [ed_pn], ac
    add  32, x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   [ed_pn], ac
    add  48, x
    ld   [y,x], ac
    ld   ac, [T4]
    ld   [T0], y
    ld   [T1], x
    ld   [T2], ac
    ld   ac, [y,x]
    ld   [ed_p2], ac
    beq  epd_l
    ld   [T0], ac
    add  1, y
    ld   [T4], ac
    ld   ac, [y,x]
    bra  epd_l
epd_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; data
; ============================================================
; the bar's first text row, and for each of its columns the tool (1-7) or
; command (8-13) a click there chooses

#addr 0x2200
eptab:
    #d8 0xFF, 0x00, 0xFF,  0x01, 0x00, 0xFF,  0xFE, 0x00, 0x00,  0x02, 0x00, 0x00
    #d8 0x00, 0xFF, 0xFF,  0x00, 0xFE, 0xFF,  0x00, 0x01, 0xFF,  0x00, 0x02, 0xFF
    #d8 0x00, 0xFD, 0x00,  0x00, 0xFC, 0x00,  0x00, 0x03, 0x00,  0x00, 0x04, 0x00
earrow:
    #d8 0x01, 0x03, 0x07, 0x0F, 0x1F, 0x3F, 0x07, 0x05
; the keys: a character, its command; 00 ends
ekeytab:
    #d8 0x70, 1, 0x50, 1, 0x62, 2, 0x42, 2, 0x65, 3, 0x45, 3, 0x6C, 4, 0x4C, 4
    #d8 0x72, 5, 0x52, 5, 0x66, 6, 0x46, 6, 0x6B, 7, 0x4B, 7, 0x75, 8, 0x55, 8
    #d8 0x73, 9, 0x53, 9, 0x61, 10, 0x41, 10, 0x6E, 11, 0x4E, 11, 0x68, 12, 0x48, 12
    #d8 0x09, 12, 0x78, 13, 0x58, 13, 0x1B, 13, 0x6D, 14, 0x4D, 14
    #d8 0x5B, 15, 0x2D, 15, 0x5D, 16, 0x3D, 16, 0x2B, 16, 0
emsgl:
    #d8 es_m0 & 0xFF, es_m1 & 0xFF, es_m2 & 0xFF, es_m3 & 0xFF, es_m4 & 0xFF, es_m5 & 0xFF, es_m6 & 0xFF, es_m7 & 0xFF, es_m8 & 0xFF
emsgh:
    #d8 es_m0 >> 8, es_m1 >> 8, es_m2 >> 8, es_m3 >> 8, es_m4 >> 8, es_m5 >> 8, es_m6 >> 8, es_m7 >> 8, es_m8 >> 8


#addr 0x2300
es_m0:
    #d 0x00
es_m1:
    #d "Saving...", 0x00
es_m2:
    #d "Saved", 0x00
es_m3:
    #d "The card could not be written", 0x00
es_m4:
    #d "Too much was drawn to undo it", 0x00
es_m5:
    #d "Nothing to undo", 0x00
es_m6:
    #d "Discard the changes?  Y: yes  N: no", 0x00
es_m7:
    #d "Save as: ", 0x00
es_m8:
    #d "Undone", 0x00
es_new:
    #d "(new)", 0x00
es_size:
    #d "Size < ", 0x00
