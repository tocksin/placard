; ============================================================
; made by asm_expand.py from wave.masm: change that file, then run
;     python3 asm_expand.py wave.masm
; ============================================================

; ============================================================
; wave.masm - WAVE.PLC: plays the .WAV files in the card's SOUNDS folder
; ============================================================
;
; A library program the DOS runs from the card (Enter on WAVE.PLC in the
; browser, or BOOT.CFG = "WAVE.PLC").  It opens the folder SOUNDS in the
; card's root and plays its .WAV files one after the other, in the order
; they are in the folder, reading each from the card while it plays.
;
; The file is a plain WAV file: PCM, 8 bits, one channel.  That is the
; board's own sound (docs/sound/SOUND.md: the video circuit reads one
; unsigned 8-bit sample on every scan line, 31,469 a second), so the
; file's samples go to the sound buffer as they are.  The file's sample
; rate picks one of three speeds:
;
;     31,469 Hz   every sample once      (a rate of 23,552 Hz or more)
;     15,734 Hz   every sample twice     (11,776 Hz or more)
;      7,867 Hz   every sample 4 times   (less)
;
; A file at any other rate plays at the nearest of the three, so faster
; or slower than it was recorded (32,000 Hz: 1.7 % slow).  gen_wave.py
; makes a file at the exact rate from any sound file.
;
; How it keeps up.  The sound buffer x5DF3-x5FFF is a ring of 525 bytes
; that the video reads once a frame.  The line read (x5000, V9:V2) says
; where the video is, in groups of four lines: 132 groups a lap.  The
; program reads a sector (fs_read, about 7 ms) to x4000, and copies it to
; the ring ahead of the video in pieces of at most 256 ring bytes, each
; when 67 groups (268 lines) or more are free between its write pointer
; and the video.  So the ring holds between about 260 and 520 samples not
; played yet: a card that answers up to 6 ms late is not heard, and the
; video never catches up with or is passed by the writing.
;
; A sector in a new cluster can cost fs_read a second read, of the FAT,
; and two reads are as long as the whole ring.  So when the sector just
; read was its cluster's last, the program looks the next cluster up
; itself (fs_nextc, the reader's cluster put back after it) at a moment
; the ring is full: the FAT sector is then in the reader's buffer when
; fs_read wants it.
;
;     Space                   pause, and go on
;     Right, Enter            the next file
;     Left, Backspace         the file before
;     Esc                     back to the DOS (menu_poll)
;
; After the folder's last file the program goes back by itself.
;
; Pinboard's Files card runs it for a .WAV file in any folder (MB_PHOTO =
; "S" and a parent to go back to): the files are then that folder's
; (MB_PCLUS), the first one played is the one chosen (MB_PN: its number
; among the folder's .WAV files), and the end or Esc goes back to
; Pinboard.
;
; RAM: the program at x0100 (asm_expand.py pages it), zero page x20-x8F,
; the sector x4000-x41FF, a page of silence x4200.
;
;     python3 asm_expand.py wave.masm                 wave.asm
;     python3 gen_plc.py wave.asm -o ../../sdcard/WAVE.PLC
;     python3 gen_wave.py song.mp3 -o ../../sdcard/SOUNDS/SONG.WAV
;     python3 test_wave.py                            runs it in the emulator
;
; Date: 11/22/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

wv_n    = 0x20              ; the file played, 0 = the folder's first
wv_tot  = 0x21              ; .WAV files in the folder
wv_k    = 0x22              ; counter
wv_t    = 0x24              ; scratch
wv_d    = 0x25              ; scratch
wv_key  = 0x29              ; the key
wv_dc   = 0x2A              ; 4: the files' folder (its first cluster)
wv_from = 0x2E              ; 1: Pinboard's Files card asked for a file
wv_name = 0x30              ; the file's name, "NAME.WAV", 00 (13 bytes)
wv_hb   = 0x40              ; 24: a chunk's first bytes (the header walk)
wv_pl   = 0x58              ; the chunk's address in the sector
wv_ph   = 0x59
wv_ql   = 0x5A              ; peek's pointer
wv_qh   = 0x5B
wv_rem  = 0x5C              ; 4: sample bytes of the file not taken yet
wv_avl  = 0x60              ; sample bytes left in the sector at x4000
wv_avh  = 0x61
wv_sl   = 0x62              ; the next of them
wv_sh   = 0x63
wv_dl   = 0x64              ; the ring's write pointer (x5DF3-x5FFF)
wv_dh   = 0x65
wv_cnt  = 0x66              ; copy: sample bytes to go (0 = 256)
wv_rep  = 0x67              ; times a sample is written: 1, 2, 4
wv_kk   = 0x68              ; copy: times to go
wv_smp  = 0x69              ; copy: the sample
wv_wg   = 0x6A              ; the write pointer's group, 0-131
wv_new  = 0x6B              ; 1: nothing written yet (the pointer not set)
wv_hold = 0x6C              ; 1: paused
wv_frm  = 0x6D              ; FRAME_LO when the keys were last read
wv_acl  = 0x6E              ; sample bytes copied since the last whole second
wv_ach  = 0x6F
wv_sec  = 0x70              ; played: seconds, minutes
wv_min  = 0x71
wv_tsec = 0x72              ; the file's length
wv_tmin = 0x73
wv_draw = 0x74              ; 1: the time line is to be drawn
wv_tsl  = 0x75              ; the file's sectors (for the bar)
wv_tsh  = 0x76
wv_bal  = 0x77              ; the bar's remainder
wv_bah  = 0x78
wv_cell = 0x79              ; bar cells drawn, 0-64
wv_fmt  = 0x7A              ; 1: the "fmt " chunk was read
wv_g    = 0x7B              ; the line read
wv_ch   = 0x7C              ; sample bytes in a piece: 0 (256), 128, 64
wv_kcl  = 0x7D              ; sample bytes a second
wv_kch  = 0x7E
wv_rp   = 0x7F              ; copy: wv_rep, or 1 for silence
wv_tmp  = 0x80              ; 4: wv_rem kept; the reader's cluster kept
wv_warm = 0x84              ; 1: the reader's next sector is in a new cluster

SECT      = 0x4000          ; the sector read
QUIET     = 0x4200          ; 256 bytes of 80h
RING_LO   = 0xF3            ; the ring: x5DF3-x5FFF
RING_HI   = 0x5D
FE_LO     = FS_ENTRY & 0xFF
ROOM      = 67              ; groups free before a piece is written
BAR_COL   = 3
BAR_ROW   = 9

; the menu block's bytes for Pinboard and this program (placard_menu.asm)
MB_PHOTO  = 0x19            ; "S": Pinboard's Files card asks for a sound
MB_PCLUS  = 0x1B            ; 4: the folder of the file asked for
MB_PN     = 0x1F            ; its number among the folder's .WAV files


; ============================================================
; main - the text screen, the folder, how many files
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL con_clear
    ld   wv_r1, [x]
    ld   LINK_HI, x
    ld   wv_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
wv_r1:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r2, [x]
    ld   LINK_HI, x
    ld   wv_r2 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r2:
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   1, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r3, [x]
    ld   LINK_HI, x
    ld   wv_r3 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r3:
    clr  ac
    ld   ac, [wv_n]
    ld   ac, [wv_tot]
    ld   ac, [wv_from]
    ld   ac, [wv_hold]
    ld   0x80, ac               ; the page of silence
    ld   ac, [wv_t]
    clr  ac
    ld   ac, [R0]
    ld   ac, [R2]
    ld   QUIET >> 8, ac
    ld   ac, [R1]
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL memset
    ld   wv_r4, [x]
    ld   LINK_HI, x
    ld   wv_r4 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r4:
    ld   LINK_LO, x             ; CALL fs_mount
    ld   wv_r5, [x]
    ld   LINK_HI, x
    ld   wv_r5 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
wv_r5:
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
; msg - the string at R1:R0 on text row AC, from column 2
; ------------------------------------------------------------
msg:
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
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r6, [x]
    ld   LINK_HI, x
    ld   wv_r6 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r6:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; quiet - the whole sound buffer = 80h
; ------------------------------------------------------------
quiet:
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
    ld   RING_LO, ac
    ld   ac, [R0]
    ld   RING_HI, ac
    ld   ac, [R1]
    ld   13, ac
    ld   ac, [R2]
    ld   0x80, ac
    ld   LINK_LO, x             ; x5DF3-x5DFF; R1:R0 = x5E00, R2 = 0
    ld   wv_r7, [x]
    ld   LINK_HI, x
    ld   wv_r7 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r7:
    ld   0x80, ac
    ld   LINK_LO, x             ; x5E00-x5EFF
    ld   wv_r8, [x]
    ld   LINK_HI, x
    ld   wv_r8 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r8:
    ld   0x80, ac
    ld   LINK_LO, x             ; x5F00-x5FFF
    ld   wv_r9, [x]
    ld   LINK_HI, x
    ld   wv_r9 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r9:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; whose - whose files: the folder Pinboard's Files card was in (and the
; file chosen there first), or the card's SOUNDS folder
; ------------------------------------------------------------
bad:
    ld   s_bad & 0xFF, ac
    ld   ac, [R0]
    ld   s_bad >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail

; the name: up to 8 characters (to the first space), then ".WAV", 00

#addr 0x0200
whose:
    ld   MENU_BLK >> 8, y
    ld   MB_PHOTO, x
    ld   [y,x], ac
    xor  0x53, ac               ; "S"
    bne  fr_own
    ld   MB_PARENT, x           ; and Pinboard to go back to
    ld   [y,x], ac
    beq  fr_own
    ld   MB_PCLUS, x
    ld   [y,x], ac
    ld   ac, [wv_dc]
    ld   MB_PCLUS + 1, x
    ld   [y,x], ac
    ld   ac, [wv_dc + 1]
    ld   MB_PCLUS + 2, x
    ld   [y,x], ac
    ld   ac, [wv_dc + 2]
    ld   MB_PCLUS + 3, x
    ld   [y,x], ac
    ld   ac, [wv_dc + 3]
    ld   MB_PN, x
    ld   [y,x], ac
    ld   ac, [wv_n]
    ld   1, ac
    ld   ac, [wv_from]
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
    ld   wv_r10, [x]
    ld   LINK_HI, x
    ld   wv_r10 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
wv_r10:
    bne  ow_no
    ld   FSV, y
    ld   V_DCLUS, x
    ld   [y,x], ac
    ld   ac, [wv_dc]
    ld   V_DCLUS + 1, x
    ld   [y,x], ac
    ld   ac, [wv_dc + 1]
    ld   V_DCLUS + 2, x
    ld   [y,x], ac
    ld   ac, [wv_dc + 2]
    ld   V_DCLUS + 3, x
    ld   [y,x], ac
    ld   ac, [wv_dc + 3]
    ld   count >> 8, y
    jmp  count
ow_no:
    ld   nodir >> 8, y
    jmp  nodir

; ------------------------------------------------------------
; opendir - the reader at the start of the files' folder: AC = 0, or the
; error
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
    ld   [wv_dc], ac
    ld   ac, [y,x]
    ld   V_DCLUS + 1, x
    ld   [wv_dc + 1], ac
    ld   ac, [y,x]
    ld   V_DCLUS + 2, x
    ld   [wv_dc + 2], ac
    ld   ac, [y,x]
    ld   V_DCLUS + 3, x
    ld   [wv_dc + 3], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL fs_cwd
    ld   wv_r11, [x]
    ld   LINK_HI, x
    ld   wv_r11 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
wv_r11:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; count - wv_tot = the .WAV files in the folder
; ------------------------------------------------------------
is_wav:
    ld   FS_ENTRY >> 8, y
    ld   FE_LO + 11, x
    ld   [y,x], ac
    and  0x18, ac               ; a folder, the volume name
    bne  iw_no
    ld   FE_LO + 8, x
    ld   [y,x], ac
    xor  0x57, ac               ; W
    bne  iw_no
    ld   FE_LO + 9, x
    ld   [y,x], ac
    xor  0x41, ac               ; A
    bne  iw_no
    ld   FE_LO + 10, x
    ld   [y,x], ac
    xor  0x56, ac               ; V
    bne  iw_no
    ld   [LINK_HI], y
    jmp  [LINK_LO]
iw_no:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; show - file wv_n: the folder from its start, the wv_n-th .WAV file's
; name, the file opened.  A number past the folder's last file plays the
; first
; ------------------------------------------------------------
first:
    clr  ac
    ld   ac, [R4]
    ld   SECT >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_read
    ld   wv_r28, [x]
    ld   LINK_HI, x
    ld   wv_r28 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
wv_r28:
    beq  fi_ok
    ld   badwav >> 8, y         ; an empty file
    jmp  badwav
fi_ok:
    ld   parse >> 8, y
    jmp  parse

; ============================================================
; the WAV header: "RIFF" size "WAVE", then chunks (name, size, bytes)
; of which "fmt " and "data" are wanted, all in the first sector
; ============================================================

#addr 0x0300
count:
    ld   LINK_LO, x             ; CALL opendir
    ld   wv_r12, [x]
    ld   LINK_HI, x
    ld   wv_r12 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
wv_r12:
    bne  ct_end
ct_loop:
    ld   LINK_LO, x             ; CALL fs_next
    ld   wv_r13, [x]
    ld   LINK_HI, x
    ld   wv_r13 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
wv_r13:
    bne  ct_end
    ld   LINK_LO, x             ; CALL is_wav
    ld   wv_r14, [x]
    ld   LINK_HI, x
    ld   wv_r14 >> 8, [x]
    ld   is_wav >> 8, y
    jmp  is_wav
wv_r14:
    bne  ct_loop
    ld   [wv_tot], ac
    inc
    ld   ac, [wv_tot]
    xor  255, ac                ; (255 at most)
    bne  ct_loop
ct_end:
    ld   [wv_tot], ac
    bne  ct_some
    ld   s_none & 0xFF, ac
    ld   ac, [R0]
    ld   s_none >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail
ct_some:
    ld   s_keys1 & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys1 >> 8, ac
    ld   ac, [R1]
    ld   12, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r15, [x]
    ld   LINK_HI, x
    ld   wv_r15 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r15:
    ld   s_keys2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys2 >> 8, ac
    ld   ac, [R1]
    ld   13, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r16, [x]
    ld   LINK_HI, x
    ld   wv_r16 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r16:
    ld   show >> 8, y
    jmp  show

; ------------------------------------------------------------
; is_wav - AC = 0 when FS_ENTRY is a file named *.WAV (a leaf)
; ------------------------------------------------------------
show:
    ld   LINK_LO, x             ; CALL opendir
    ld   wv_r17, [x]
    ld   LINK_HI, x
    ld   wv_r17 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
wv_r17:
    bne  sh_bad
    ld   [wv_n], ac
    ld   ac, [wv_k]
sh_next:
    ld   LINK_LO, x             ; CALL fs_next
    ld   wv_r18, [x]
    ld   LINK_HI, x
    ld   wv_r18 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
wv_r18:
    bne  sh_end
    ld   LINK_LO, x             ; CALL is_wav
    ld   wv_r19, [x]
    ld   LINK_HI, x
    ld   wv_r19 >> 8, [x]
    ld   is_wav >> 8, y
    jmp  is_wav
wv_r19:
    bne  sh_next
    ld   [wv_k], ac
    beq  sh_found
    dec
    ld   ac, [wv_k]
    bra  sh_next
sh_found:
    ld   name >> 8, y
    jmp  name
sh_end:
    ld   [wv_n], ac
    beq  sh_bad
    clr  ac
    ld   ac, [wv_n]
    bra  show
sh_bad:
    ld   bad >> 8, y
    jmp  bad

parse:
    ld   SECT >> 8, y
    ld   0, x
    ld   [y,x], ac
    xor  0x52, ac               ; R
    bne  pa_no
    ld   1, x
    ld   [y,x], ac
    xor  0x49, ac               ; I
    bne  pa_no
    ld   2, x
    ld   [y,x], ac
    xor  0x46, ac               ; F
    bne  pa_no
    ld   8, x
    ld   [y,x], ac
    xor  0x57, ac               ; W
    bne  pa_no
    ld   9, x
    ld   [y,x], ac
    xor  0x41, ac               ; A
    bne  pa_no
    ld   10, x
    ld   [y,x], ac
    xor  0x56, ac               ; V
    bne  pa_no
    ld   12, ac
    ld   ac, [wv_pl]
    ld   SECT >> 8, ac
    ld   ac, [wv_ph]
    clr  ac
    ld   ac, [wv_fmt]
    ld   walk >> 8, y
    jmp  walk
pa_no:
    ld   badwav >> 8, y
    jmp  badwav

; walk - the chunk at wv_ph:wv_pl (24 bytes of it must be in the sector)

#addr 0x0400
name:
    ld   FE_LO, ac
    ld   ac, [wv_t]
    ld   wv_name, ac
    ld   ac, [wv_d]
    ld   8, ac
    ld   ac, [wv_k]
nm_ch:
    ld   [wv_t], x
    ld   FS_ENTRY >> 8, y
    ld   [y,x], ac
    xor  0x20, ac
    beq  nm_ext
    xor  0x20, ac
    ld   [wv_d], x
    ld   ac, [x]
    ld   [wv_t], ac
    inc
    ld   ac, [wv_t]
    ld   [wv_d], ac
    inc
    ld   ac, [wv_d]
    ld   [wv_k], ac
    dec
    ld   ac, [wv_k]
    bne  nm_ch
nm_ext:
    ld   [wv_d], ac
    ld   ac, x
    ld   0x2E, [x]
    add  1, x
    ld   0x57, [x]
    add  2, x
    ld   0x41, [x]
    add  3, x
    ld   0x56, [x]
    add  4, x
    ld   0x00, [x]
    ld   wv_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   wv_r20, [x]
    ld   LINK_HI, x
    ld   wv_r20 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
wv_r20:
    beq  nm_ok
    ld   bad >> 8, y
    jmp  bad
nm_ok:
    ld   title >> 8, y
    jmp  title

; ------------------------------------------------------------
; title - row 3: the name, "n of m"; then the file's first sector
; ------------------------------------------------------------
title:
    ld   wv_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   3, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r21, [x]
    ld   LINK_HI, x
    ld   wv_r21 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r21:
tt_pad:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r22, [x]
    ld   LINK_HI, x
    ld   wv_r22 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r22:
    ld   [CUR_COL], ac
    xor  16, ac
    bne  tt_pad
    ld   [wv_n], ac
    inc
    ld   LINK_LO, x             ; CALL con_dec8
    ld   wv_r23, [x]
    ld   LINK_HI, x
    ld   wv_r23 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
wv_r23:
    ld   s_of & 0xFF, ac
    ld   ac, [R0]
    ld   s_of >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r24, [x]
    ld   LINK_HI, x
    ld   wv_r24 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r24:
    ld   [wv_tot], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   wv_r25, [x]
    ld   LINK_HI, x
    ld   wv_r25 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
wv_r25:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r26, [x]
    ld   LINK_HI, x
    ld   wv_r26 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r26:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r27, [x]
    ld   LINK_HI, x
    ld   wv_r27 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r27:
    ld   first >> 8, y
    jmp  first

ends:
    clr  ac
    ld   ac, [wv_warm]
    ld   FSV, y
    ld   V_SSEC, x
    ld   [y,x], ac
    bne  en_ret
    ld   [wv_rem], ac
    or   [wv_rem + 1], ac
    or   [wv_rem + 2], ac
    or   [wv_rem + 3], ac
    beq  en_ret
    ld   1, ac
    ld   ac, [wv_warm]
en_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; keys - once a frame

#addr 0x0500
walk:
    ld   [wv_ph], ac
    xor  SECT >> 8, ac
    beq  wk_ok
    xor  1, ac
    bne  wk_bad
    ld   0xE8, ac
    sub  [wv_pl], ac
    bcs  wk_bad
wk_ok:
    ld   LINK_LO, x             ; CALL peek
    ld   wv_r29, [x]
    ld   LINK_HI, x
    ld   wv_r29 >> 8, [x]
    ld   peek >> 8, y
    jmp  peek
wv_r29:
    ld   [wv_hb], ac
    xor  0x66, ac               ; f
    bne  wk_nf
    ld   [wv_hb + 1], ac
    xor  0x6D, ac               ; m
    bne  wk_skip
    ld   [wv_hb + 2], ac
    xor  0x74, ac               ; t
    bne  wk_skip
    ld   fmt >> 8, y
    jmp  fmt
wk_nf:
    xor  0x66 ^ 0x64, ac        ; d
    bne  wk_skip
    ld   [wv_hb + 1], ac
    xor  0x61, ac               ; a
    bne  wk_skip
    ld   [wv_hb + 2], ac
    xor  0x74, ac               ; t
    bne  wk_skip
    ld   [wv_hb + 3], ac
    xor  0x61, ac               ; a
    bne  wk_skip
    ld   data >> 8, y
    jmp  data
wk_skip:
    ld   skip >> 8, y
    jmp  skip
wk_bad:
    ld   badwav >> 8, y
    jmp  badwav

; peek - wv_hb = the 24 bytes at wv_ph:wv_pl (a leaf)
peek:
    ld   [wv_pl], ac
    ld   ac, [wv_ql]
    ld   [wv_ph], ac
    ld   ac, [wv_qh]
    ld   wv_hb, ac
    ld   ac, [wv_d]
pk_l:
    ld   [wv_qh], y
    ld   [wv_ql], x
    ld   [y,x], ac
    ld   [wv_d], x
    ld   ac, [x]
    ld   [wv_ql], ac
    inc
    ld   ac, [wv_ql]
    bne  pk_n
    ld   [wv_qh], ac
    inc
    ld   ac, [wv_qh]
pk_n:
    ld   [wv_d], ac
    inc
    ld   ac, [wv_d]
    xor  wv_hb + 24, ac
    bne  pk_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; skip - on to the next chunk: 8 + the size, and one more for an odd size
skip:
    ld   [wv_hb + 6], ac
    or   [wv_hb + 7], ac
    bne  sk_bad
    ld   [wv_hb + 5], ac
    and  0xFE, ac
    bne  sk_bad
    ld   [wv_hb + 4], ac
    and  1, ac
    add  8, ac
    add  [wv_pl], ac
    ld   ac, [wv_pl]
    bcc  sk_1
    ld   [wv_ph], ac
    inc
    ld   ac, [wv_ph]
sk_1:
    ld   [wv_hb + 4], ac
    add  [wv_pl], ac
    ld   ac, [wv_pl]
    bcc  sk_2
    ld   [wv_ph], ac
    inc
    ld   ac, [wv_ph]
sk_2:
    ld   [wv_hb + 5], ac
    add  [wv_ph], ac
    ld   ac, [wv_ph]
    ld   walk >> 8, y
    jmp  walk
sk_bad:
    ld   badwav >> 8, y
    jmp  badwav

; fmt - PCM (1), one channel, 8 bits; the rate picks the speed
data:
    ld   [wv_fmt], ac
    bne  da_ok
    ld   badwav >> 8, y
    jmp  badwav
da_ok:
    ld   [wv_hb + 4], ac
    ld   ac, [wv_rem]
    ld   [wv_hb + 5], ac
    ld   ac, [wv_rem + 1]
    ld   [wv_hb + 6], ac
    ld   ac, [wv_rem + 2]
    ld   [wv_hb + 7], ac
    ld   ac, [wv_rem + 3]
    ld   [wv_ph], ac
    ld   ac, [wv_sh]
    ld   [wv_pl], ac
    add  8, ac
    ld   ac, [wv_sl]
    bcc  da_1
    ld   [wv_sh], ac
    inc
    ld   ac, [wv_sh]
da_1:
    ld   sectors >> 8, y
    jmp  sectors

; sectors - wv_ts = wv_rem / 512 + 1, the bar's whole

#addr 0x0600
fmt:
    ld   [wv_hb + 8], ac
    xor  1, ac
    or   [wv_hb + 9], ac
    bne  fm_bad
    ld   [wv_hb + 10], ac
    xor  1, ac
    or   [wv_hb + 11], ac
    bne  fm_bad
    ld   [wv_hb + 22], ac
    xor  8, ac
    or   [wv_hb + 23], ac
    bne  fm_bad
    ld   1, ac
    ld   ac, [wv_fmt]
    ld   [wv_hb + 14], ac
    or   [wv_hb + 15], ac
    bne  fm_1
    ld   [wv_hb + 13], ac
    sub  0x5C, ac               ; 23,552 Hz or more
    bcc  fm_1
    ld   [wv_hb + 13], ac
    sub  0x2E, ac               ; 11,776 Hz or more
    bcc  fm_2
    ld   4, ac                  ; 7,867 Hz: 1EBBh bytes a second
    ld   ac, [wv_rep]
    ld   64, ac
    ld   ac, [wv_ch]
    ld   0xBB, ac
    ld   ac, [wv_kcl]
    ld   0x1E, ac
    bra  fm_set
fm_2:
    ld   2, ac                  ; 15,734 Hz: 3D77h
    ld   ac, [wv_rep]
    ld   128, ac
    ld   ac, [wv_ch]
    ld   0x77, ac
    ld   ac, [wv_kcl]
    ld   0x3D, ac
    bra  fm_set
fm_1:
    ld   1, ac                  ; 31,469 Hz: 7AEDh
    ld   ac, [wv_rep]
    clr  ac
    ld   ac, [wv_ch]
    ld   0xED, ac
    ld   ac, [wv_kcl]
    ld   0x7A, ac
fm_set:
    ld   ac, [wv_kch]
    ld   skip >> 8, y
    jmp  skip
fm_bad:
    ld   badwav >> 8, y
    jmp  badwav

; data - the samples: wv_rem = their bytes, the first at chunk + 8
sectors:
    ld   [wv_rem + 3], ac
    and  0xFE, ac
    beq  se_fit
    ld   0xFF, ac
    ld   ac, [wv_tsl]
    ld   ac, [wv_tsh]
    bra  se_done
se_fit:
    ld   [wv_rem + 1], ac
    shr  ac
    ld   ac, [wv_tsl]
    ld   [wv_rem + 2], ac
    and  1, ac
    beq  se_1
    ld   [wv_tsl], ac
    or   0x80, ac
    ld   ac, [wv_tsl]
se_1:
    ld   [wv_rem + 2], ac
    shr  ac
    ld   ac, [wv_tsh]
    ld   [wv_rem + 3], ac
    and  1, ac
    beq  se_2
    ld   [wv_tsh], ac
    or   0x80, ac
    ld   ac, [wv_tsh]
se_2:
    ld   [wv_tsl], ac
    inc
    ld   ac, [wv_tsl]
    bne  se_done
    ld   [wv_tsh], ac
    inc
    ld   ac, [wv_tsh]
se_done:
    ld   length >> 8, y
    jmp  length

; length - the file's minutes and seconds: wv_rem less a second's bytes
; until none are left (take), then wv_rem as it was
bar0:
    ld   BAR_ROW, ac
    ld   ac, [CUR_ROW]
    ld   BAR_COL - 1, ac
    ld   ac, [CUR_COL]
    ld   0x5B, ac               ; [
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r34, [x]
    ld   LINK_HI, x
    ld   wv_r34 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r34:
    ld   64, ac
    ld   ac, [wv_k]
b0_l:
    ld   0x2D, ac               ; -
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r35, [x]
    ld   LINK_HI, x
    ld   wv_r35 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r35:
    ld   [wv_k], ac
    dec
    ld   ac, [wv_k]
    bne  b0_l
    ld   0x5D, ac               ; ]
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r36, [x]
    ld   LINK_HI, x
    ld   wv_r36 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r36:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   wv_r37, [x]
    ld   LINK_HI, x
    ld   wv_r37 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r37:
    ld   [FRAME_LO], ac
    ld   ac, [wv_frm]
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the loop: the keys once a frame, the time line when it changed, the
; next sector when this one is used up, a piece to the ring when there
; is room for it
; ============================================================

#addr 0x0700
length:
    ld   [wv_rem], ac
    ld   ac, [wv_tmp]
    ld   [wv_rem + 1], ac
    ld   ac, [wv_tmp + 1]
    ld   [wv_rem + 2], ac
    ld   ac, [wv_tmp + 2]
    ld   [wv_rem + 3], ac
    ld   ac, [wv_tmp + 3]
    clr  ac
    ld   ac, [wv_tsec]
    ld   ac, [wv_tmin]
ln_loop:
    ld   [wv_kcl], ac
    ld   ac, [wv_avl]
    ld   [wv_kch], ac
    ld   ac, [wv_avh]
    ld   LINK_LO, x             ; CALL take
    ld   wv_r30, [x]
    ld   LINK_HI, x
    ld   wv_r30 >> 8, [x]
    ld   take >> 8, y
    jmp  take
wv_r30:
    ld   [wv_avl], ac
    xor  [wv_kcl], ac
    bne  ln_end
    ld   [wv_avh], ac
    xor  [wv_kch], ac
    bne  ln_end
    ld   [wv_tsec], ac
    inc
    ld   ac, [wv_tsec]
    xor  60, ac
    bne  ln_loop
    ld   ac, [wv_tsec]
    ld   [wv_tmin], ac
    inc
    ld   ac, [wv_tmin]
    bne  ln_loop
    ld   255, ac                ; (over 255 minutes)
    ld   ac, [wv_tmin]
ln_end:
    ld   [wv_tmp], ac
    ld   ac, [wv_rem]
    ld   [wv_tmp + 1], ac
    ld   ac, [wv_rem + 1]
    ld   [wv_tmp + 2], ac
    ld   ac, [wv_rem + 2]
    ld   [wv_tmp + 3], ac
    ld   ac, [wv_rem + 3]
    ld   begin >> 8, y
    jmp  begin

; ------------------------------------------------------------
; take - wv_av = the smaller of wv_av and wv_rem, and wv_rem less it
; (a leaf)
; ------------------------------------------------------------
take:
    ld   [wv_rem + 3], ac
    or   [wv_rem + 2], ac
    bne  wtk_all
    ld   [wv_rem + 1], ac
    sub  [wv_avh], ac
    bcs  wtk_less
    bne  wtk_all
    ld   [wv_rem], ac
    sub  [wv_avl], ac
    bcc  wtk_all
wtk_less:
    ld   [wv_rem], ac
    ld   ac, [wv_avl]
    ld   [wv_rem + 1], ac
    ld   ac, [wv_avh]
    clr  ac
    ld   ac, [wv_rem]
    ld   ac, [wv_rem + 1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
wtk_all:
    ld   [wv_rem], ac
    sub  [wv_avl], ac
    ld   ac, [wv_rem]
    bcc  wtk_hi
    ld   [wv_rem + 1], ac
    dec
    ld   ac, [wv_rem + 1]
    xor  0xFF, ac
    bne  wtk_hi
    ld   [wv_rem + 2], ac
    dec
    ld   ac, [wv_rem + 2]
    xor  0xFF, ac
    bne  wtk_hi
    ld   [wv_rem + 3], ac
    dec
    ld   ac, [wv_rem + 3]
wtk_hi:
    ld   [wv_rem + 1], ac
    sub  [wv_avh], ac
    ld   ac, [wv_rem + 1]
    bcc  wtk_ret
    ld   [wv_rem + 2], ac
    dec
    ld   ac, [wv_rem + 2]
    xor  0xFF, ac
    bne  wtk_ret
    ld   [wv_rem + 3], ac
    dec
    ld   ac, [wv_rem + 3]
wtk_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; begin - the first sector's samples, the speed's text, an empty bar,
; the counters; then the loop
; ------------------------------------------------------------
loop:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   wv_r38, [x]
    ld   LINK_HI, x
    ld   wv_r38 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r38:
    ld   ac, [wv_g]
    ld   [FRAME_LO], ac
    xor  [wv_frm], ac
    beq  lp_same
    ld   [FRAME_LO], ac
    ld   ac, [wv_frm]
    ld   keys >> 8, y
    jmp  keys
lp_same:
    ld   [wv_draw], ac
    beq  lp_feed
    ld   time >> 8, y
    jmp  time
lp_feed:
    ld   [wv_warm], ac
    beq  lp_cold
    ld   warmq >> 8, y
    jmp  warmq
lp_cold:
    ld   feed >> 8, y
    jmp  feed

; feed - the next sector when this one is used up, else a piece when
; there is room for it

#addr 0x0800
begin:
    clr  ac                     ; wv_av = x4200 - wv_s
    sub  [wv_sl], ac
    ld   ac, [wv_avl]
    ld   (SECT >> 8) + 2, ac
    bcc  bg_1
    dec
bg_1:
    sub  [wv_sh], ac
    ld   ac, [wv_avh]
    ld   LINK_LO, x             ; CALL take
    ld   wv_r31, [x]
    ld   LINK_HI, x
    ld   wv_r31 >> 8, [x]
    ld   take >> 8, y
    jmp  take
wv_r31:
    ld   LINK_LO, x             ; CALL ends
    ld   wv_r32, [x]
    ld   LINK_HI, x
    ld   wv_r32 >> 8, [x]
    ld   ends >> 8, y
    jmp  ends
wv_r32:
    clr  ac
    ld   ac, [wv_acl]
    ld   ac, [wv_ach]
    ld   ac, [wv_sec]
    ld   ac, [wv_min]
    ld   ac, [wv_bal]
    ld   ac, [wv_bah]
    ld   ac, [wv_cell]
    ld   1, ac
    ld   ac, [wv_new]
    ld   ac, [wv_draw]
    ld   [wv_rep], ac
    xor  1, ac
    beq  bg_31
    xor  1 ^ 2, ac
    beq  bg_15
    ld   s_r7 & 0xFF, ac
    ld   ac, [R0]
    ld   s_r7 >> 8, ac
    bra  bg_rate
bg_15:
    ld   s_r15 & 0xFF, ac
    ld   ac, [R0]
    ld   s_r15 >> 8, ac
    bra  bg_rate
bg_31:
    ld   s_r31 & 0xFF, ac
    ld   ac, [R0]
    ld   s_r31 >> 8, ac
bg_rate:
    ld   ac, [R1]
    ld   5, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r33, [x]
    ld   LINK_HI, x
    ld   wv_r33 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r33:
    ld   bar0 >> 8, y
    jmp  bar0

feed:
    ld   [wv_hold], ac
    bne  lp_room
    ld   [wv_avl], ac
    or   [wv_avh], ac
    bne  lp_room
    ld   sector >> 8, y
    jmp  sector
lp_room:
    ld   [wv_new], ac
    bne  lp_new
    ld   [wv_g], ac             ; groups from the write pointer on to the
    sub  124, ac                ; video's, less the one being read
    sub  [wv_wg], ac
    bcc  lp_d
    add  132, ac
lp_d:
    sub  ROOM, ac
    bcs  lp_wait
    ld   piece >> 8, y
    jmp  piece
lp_wait:
    ld   loop >> 8, y
    jmp  loop
lp_new:
    ld   start >> 8, y
    jmp  start

; warmq - the next cluster looked up now if nothing plays yet or the ring
; is nearly full (under 21 groups free), else later
warmq:
    ld   [wv_new], ac
    bne  wq_go
    ld   [wv_g], ac
    sub  124, ac
    sub  [wv_wg], ac
    bcc  wq_d
    add  132, ac
wq_d:
    sub  21, ac
    bcs  wq_go
    ld   feed >> 8, y
    jmp  feed
wq_go:
    ld   LINK_LO, x             ; CALL warm
    ld   wv_r39, [x]
    ld   LINK_HI, x
    ld   wv_r39 >> 8, [x]
    ld   warm >> 8, y
    jmp  warm
wv_r39:
    ld   loop >> 8, y
    jmp  loop

; warm - the FAT sector of the reader's cluster into the reader's buffer
next:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r45, [x]
    ld   LINK_HI, x
    ld   wv_r45 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r45:
    clr  ac
    ld   ac, [wv_hold]
    ld   [wv_n], ac
    inc
    ld   ac, [wv_n]
    xor  [wv_tot], ac
    bne  nx_go
    ld   ac, [wv_n]             ; past the last: the first
nx_go:
    ld   show >> 8, y
    jmp  show

prev:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r46, [x]
    ld   LINK_HI, x
    ld   wv_r46 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r46:
    clr  ac
    ld   ac, [wv_hold]
    ld   [wv_n], ac
    bne  pv_dec
    ld   [wv_tot], ac           ; before the first: the last
pv_dec:
    dec
    ld   ac, [wv_n]
    ld   show >> 8, y
    jmp  show

; start - the write pointer two groups ahead of the video

#addr 0x0900
warm:
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
    ld   ac, [wv_warm]
    ld   FSV, y
    ld   V_SCLUS, x
    ld   [y,x], ac
    ld   ac, [wv_tmp]
    ld   V_SCLUS + 1, x
    ld   [y,x], ac
    ld   ac, [wv_tmp + 1]
    ld   V_SCLUS + 2, x
    ld   [y,x], ac
    ld   ac, [wv_tmp + 2]
    ld   V_SCLUS + 3, x
    ld   [y,x], ac
    ld   ac, [wv_tmp + 3]
    ld   LINK_LO, x             ; CALL fs_nextc
    ld   wv_r40, [x]
    ld   LINK_HI, x
    ld   wv_r40 >> 8, [x]
    ld   fs_nextc >> 8, y
    jmp  fs_nextc
wv_r40:
    ld   FSV, y
    ld   V_SCLUS, x
    ld   [wv_tmp], ac
    ld   ac, [y,x]
    ld   V_SCLUS + 1, x
    ld   [wv_tmp + 1], ac
    ld   ac, [y,x]
    ld   V_SCLUS + 2, x
    ld   [wv_tmp + 2], ac
    ld   ac, [y,x]
    ld   V_SCLUS + 3, x
    ld   [wv_tmp + 3], ac
    ld   ac, [y,x]
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ends - wv_warm = 1 when the sector read was its cluster's last and the
; file goes on (a leaf)
keys:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   wv_r41, [x]
    ld   LINK_HI, x
    ld   wv_r41 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
wv_r41:
    ld   [KBD_NOW + (K_ESC >> 3)], ac   ; Esc: silence before the DOS
    and  1 << (K_ESC & 7), ac           ; takes over (menu_poll)
    bne  ky_poll
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r42, [x]
    ld   LINK_HI, x
    ld   wv_r42 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r42:
    ld   1, ac
    ld   ac, [wv_new]
ky_poll:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   wv_r43, [x]
    ld   LINK_HI, x
    ld   wv_r43 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
wv_r43:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   wv_r44, [x]
    ld   LINK_HI, x
    ld   wv_r44 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
wv_r44:
    beq  ky_none
    ld   ac, [wv_key]
    xor  0x20, ac               ; Space
    beq  ky_hold
    xor  0x20 ^ 0x14, ac        ; Right
    beq  ky_next
    xor  0x14 ^ 0x0A, ac        ; Enter
    beq  ky_next
    xor  0x0A ^ 0x13, ac        ; Left
    beq  ky_prev
    xor  0x13 ^ 0x08, ac        ; Backspace
    beq  ky_prev
ky_none:
    ld   loop >> 8, y
    jmp  loop
ky_hold:
    ld   [wv_hold], ac
    xor  1, ac
    ld   ac, [wv_hold]
    ld   1, ac
    ld   ac, [wv_draw]
    ld   loop >> 8, y
    jmp  loop
ky_next:
    ld   next >> 8, y
    jmp  next
ky_prev:
    ld   prev >> 8, y
    jmp  prev

start:
    ld   0x50, y
    ld   [y,x], ac
    sub  122, ac                ; the group + 2
    ld   ac, [wv_wg]
    sub  132, ac
    bcs  st_in
    ld   ac, [wv_wg]
st_in:
    ld   0xF0, ac               ; x5DF0 + 4 a group
    ld   ac, [wv_dl]
    ld   RING_HI, ac
    ld   ac, [wv_dh]
    ld   [wv_wg], ac
    ld   ac, [wv_k]
    bne  st_add
    ld   RING_LO, ac            ; group 0 is x5DF3 alone
    ld   ac, [wv_dl]
    bra  st_done
st_add:
    ld   [wv_dl], ac
    add  4, ac
    ld   ac, [wv_dl]
    bcc  st_n
    ld   [wv_dh], ac
    inc
    ld   ac, [wv_dh]
st_n:
    ld   [wv_k], ac
    dec
    ld   ac, [wv_k]
    bne  st_add
st_done:
    clr  ac
    ld   ac, [wv_new]
    ld   loop >> 8, y
    jmp  loop

; sector - the next 512 bytes of the file, or the end

#addr 0x0A00
sector:
    clr  ac
    ld   ac, [wv_avl]
    ld   2, ac
    ld   ac, [wv_avh]
    ld   LINK_LO, x             ; CALL take
    ld   wv_r47, [x]
    ld   LINK_HI, x
    ld   wv_r47 >> 8, [x]
    ld   take >> 8, y
    jmp  take
wv_r47:
    ld   [wv_avl], ac
    or   [wv_avh], ac
    beq  sc_end
    clr  ac
    ld   ac, [R4]
    ld   ac, [wv_sl]
    ld   SECT >> 8, ac
    ld   ac, [R5]
    ld   ac, [wv_sh]
    ld   LINK_LO, x             ; CALL fs_read
    ld   wv_r48, [x]
    ld   LINK_HI, x
    ld   wv_r48 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
wv_r48:
    bne  sc_end
    ld   LINK_LO, x             ; CALL ends
    ld   wv_r49, [x]
    ld   LINK_HI, x
    ld   wv_r49 >> 8, [x]
    ld   ends >> 8, y
    jmp  ends
wv_r49:
    ld   bar >> 8, y
    jmp  bar
sc_end:
    clr  ac
    ld   ac, [wv_avl]
    ld   ac, [wv_avh]
    ld   finish >> 8, y
    jmp  finish

; bar - 64 cells for the file's sectors: one more sector read
bar:
    ld   [wv_bal], ac
    add  64, ac
    ld   ac, [wv_bal]
    bcc  br_cmp
    ld   [wv_bah], ac
    inc
    ld   ac, [wv_bah]
br_cmp:
    ld   [wv_bah], ac
    sub  [wv_tsh], ac
    bcs  br_done
    bne  br_cell
    ld   [wv_bal], ac
    sub  [wv_tsl], ac
    bcs  br_done
br_cell:
    ld   [wv_bal], ac
    sub  [wv_tsl], ac
    ld   ac, [wv_bal]
    bcc  br_h
    ld   [wv_bah], ac
    dec
    ld   ac, [wv_bah]
br_h:
    ld   [wv_bah], ac
    sub  [wv_tsh], ac
    ld   ac, [wv_bah]
    ld   [wv_cell], ac
    xor  64, ac
    beq  br_cmp
    ld   BAR_ROW, ac
    ld   ac, [CUR_ROW]
    ld   [wv_cell], ac
    add  BAR_COL, ac
    ld   ac, [CUR_COL]
    ld   [wv_cell], ac
    inc
    ld   ac, [wv_cell]
    ld   0xA0, ac               ; a filled cell (an inverse space)
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r50, [x]
    ld   LINK_HI, x
    ld   wv_r50 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r50:
    bra  br_cmp
br_done:
    ld   loop >> 8, y
    jmp  loop

; piece - the next piece to the ring: silence while paused, else up to
; wv_ch of the sector's samples
tick:
    ld   [wv_t], ac
    bne  tc_add
    ld   [wv_ach], ac
    inc
    ld   ac, [wv_ach]
    bra  tc_cmp
tc_add:
    add  [wv_acl], ac
    ld   ac, [wv_acl]
    bcc  tc_cmp
    ld   [wv_ach], ac
    inc
    ld   ac, [wv_ach]
tc_cmp:
    ld   [wv_ach], ac
    sub  [wv_kch], ac
    bcs  tc_no
    bne  tc_sec
    ld   [wv_acl], ac
    sub  [wv_kcl], ac
    bcs  tc_no
tc_sec:
    ld   [wv_acl], ac
    sub  [wv_kcl], ac
    ld   ac, [wv_acl]
    bcc  tc_h
    ld   [wv_ach], ac
    dec
    ld   ac, [wv_ach]
tc_h:
    ld   [wv_ach], ac
    sub  [wv_kch], ac
    ld   ac, [wv_ach]
    ld   1, ac
    ld   ac, [wv_draw]
    ld   [wv_sec], ac
    inc
    ld   ac, [wv_sec]
    xor  60, ac
    bne  tc_no
    ld   ac, [wv_sec]
    ld   [wv_min], ac
    inc
    ld   ac, [wv_min]
tc_no:
    ld   loop >> 8, y
    jmp  loop

; time - row 7: "m:ss of m:ss", and "paused" while it is

#addr 0x0B00
piece:
    ld   [wv_hold], ac
    beq  pc_data
    clr  ac
    ld   ac, [wv_ql]
    ld   ac, [wv_cnt]
    ld   QUIET >> 8, ac
    ld   ac, [wv_qh]
    ld   1, ac
    ld   ac, [wv_rp]
    ld   LINK_LO, x             ; CALL copy
    ld   wv_r51, [x]
    ld   LINK_HI, x
    ld   wv_r51 >> 8, [x]
    ld   copy >> 8, y
    jmp  copy
wv_r51:
    ld   loop >> 8, y
    jmp  loop
pc_data:
    ld   [wv_avh], ac
    bne  pc_full
    ld   [wv_ch], ac
    beq  pc_av
    ld   [wv_avl], ac
    sub  [wv_ch], ac
    bcs  pc_av
pc_full:
    ld   [wv_ch], ac
    bra  pc_n
pc_av:
    ld   [wv_avl], ac
pc_n:
    ld   ac, [wv_cnt]
    ld   ac, [wv_t]
    bne  pc_sub
    ld   [wv_avh], ac           ; 256 of them
    dec
    ld   ac, [wv_avh]
    bra  pc_go
pc_sub:
    ld   [wv_avl], ac
    sub  [wv_t], ac
    ld   ac, [wv_avl]
    bcc  pc_go
    ld   [wv_avh], ac
    dec
    ld   ac, [wv_avh]
pc_go:
    ld   [wv_sl], ac
    ld   ac, [wv_ql]
    ld   [wv_sh], ac
    ld   ac, [wv_qh]
    ld   [wv_rep], ac
    ld   ac, [wv_rp]
    ld   LINK_LO, x             ; CALL copy
    ld   wv_r52, [x]
    ld   LINK_HI, x
    ld   wv_r52 >> 8, [x]
    ld   copy >> 8, y
    jmp  copy
wv_r52:
    ld   [wv_ql], ac
    ld   ac, [wv_sl]
    ld   [wv_qh], ac
    ld   ac, [wv_sh]
    ld   tick >> 8, y
    jmp  tick

; ------------------------------------------------------------
; copy - wv_cnt bytes (0 = 256) from wv_qh:wv_ql to the ring at the
; write pointer, each wv_rp times; then the pointer's group (a leaf)
; ------------------------------------------------------------
copy:
    ld   [wv_qh], y
    ld   [wv_ql], x
    ld   [y,x], ac
    ld   ac, [wv_smp]
    ld   [wv_rp], ac
    ld   ac, [wv_kk]
cp_w:
    ld   [wv_dh], y
    ld   [wv_dl], x
    ld   [wv_smp], ac
    ld   ac, [y,x]
    ld   [wv_dl], ac
    inc
    ld   ac, [wv_dl]
    bne  cp_n
    ld   [wv_dh], ac
    inc
    ld   ac, [wv_dh]
    xor  0x60, ac
    bne  cp_n
    ld   RING_HI, ac            ; around: x5DF3
    ld   ac, [wv_dh]
    ld   RING_LO, ac
    ld   ac, [wv_dl]
cp_n:
    ld   [wv_kk], ac
    dec
    ld   ac, [wv_kk]
    bne  cp_w
    ld   [wv_ql], ac
    inc
    ld   ac, [wv_ql]
    bne  cp_s
    ld   [wv_qh], ac
    inc
    ld   ac, [wv_qh]
cp_s:
    ld   [wv_cnt], ac
    dec
    ld   ac, [wv_cnt]
    bne  copy
    ld   [wv_dl], ac            ; the group: (pointer - x5DF0) / 4
    sub  0xF0, ac
    shr  ac
    shr  ac
    ld   ac, [wv_wg]
    ld   [wv_dh], ac
    bcc  cp_g
    dec
cp_g:
    sub  RING_HI, ac
    beq  cp_ret
    xor  1, ac
    beq  cp_64
    ld   [wv_wg], ac
    add  128, ac
    bra  cp_put
cp_64:
    ld   [wv_wg], ac
    add  64, ac
cp_put:
    ld   ac, [wv_wg]
cp_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tick - wv_t (0 = 256) more sample bytes: the seconds played

#addr 0x0C00
time:
    clr  ac
    ld   ac, [wv_draw]
    ld   7, ac
    ld   ac, [CUR_ROW]
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   [wv_min], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   wv_r53, [x]
    ld   LINK_HI, x
    ld   wv_r53 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
wv_r53:
    ld   [wv_sec], ac
    ld   LINK_LO, x             ; CALL dec2
    ld   wv_r54, [x]
    ld   LINK_HI, x
    ld   wv_r54 >> 8, [x]
    ld   dec2 >> 8, y
    jmp  dec2
wv_r54:
    ld   s_of & 0xFF, ac
    ld   ac, [R0]
    ld   s_of >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r55, [x]
    ld   LINK_HI, x
    ld   wv_r55 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r55:
    ld   [wv_tmin], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   wv_r56, [x]
    ld   LINK_HI, x
    ld   wv_r56 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
wv_r56:
    ld   [wv_tsec], ac
    ld   LINK_LO, x             ; CALL dec2
    ld   wv_r57, [x]
    ld   LINK_HI, x
    ld   wv_r57 >> 8, [x]
    ld   dec2 >> 8, y
    jmp  dec2
wv_r57:
    ld   [wv_hold], ac
    bne  tm_hold
    ld   s_go & 0xFF, ac
    ld   ac, [R0]
    ld   s_go >> 8, ac
    bra  tm_put
tm_hold:
    ld   s_hold & 0xFF, ac
    ld   ac, [R0]
    ld   s_hold >> 8, ac
tm_put:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r58, [x]
    ld   LINK_HI, x
    ld   wv_r58 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r58:
    ld   loop >> 8, y
    jmp  loop

; dec2 - ":" and AC (0-99) as two digits
dec2:
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
    ld   ac, [wv_t]
    ld   0x3A, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r59, [x]
    ld   LINK_HI, x
    ld   wv_r59 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r59:
    ld   0x30, ac
    ld   ac, [wv_d]
d2_l:
    ld   [wv_t], ac
    sub  10, ac
    bcs  d2_o
    ld   ac, [wv_t]
    ld   [wv_d], ac
    inc
    ld   ac, [wv_d]
    bra  d2_l
d2_o:
    ld   [wv_d], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r60, [x]
    ld   LINK_HI, x
    ld   wv_r60 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r60:
    ld   [wv_t], ac
    add  0x30, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r61, [x]
    ld   LINK_HI, x
    ld   wv_r61 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r61:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; finish - the file's end: a piece of silence after the last samples,
; wait until the video is in it, the whole ring silent, the next file or
; (after the last) back
; ------------------------------------------------------------
after:
    ld   [wv_n], ac
    inc
    ld   ac, [wv_n]
    xor  [wv_tot], ac
    beq  af_last
    ld   show >> 8, y
    jmp  show
af_last:
    ld   MENU_BLK >> 8, y       ; back, as menu_poll goes (a program that
    ld   MB_MAGIC, x            ; is done)
    ld   [y,x], ac
    xor  0x4D, ac               ; "M"
    bne  af_stay
    ld   MB_WHY, x
    ld   WHY_NEXT, ac
    ld   ac, [y,x]
    jmp  MB_EXIT
af_stay:
    clr  ac                     ; no DOS to go back to: from the first again
    ld   ac, [wv_n]
    ld   show >> 8, y
    jmp  show

; badwav - not a file the program plays: say so for 2.5 s, the next file

#addr 0x0D00
finish:
    ld   [wv_new], ac
    bne  fn_quiet
fn_room:
    ld   LINK_LO, x             ; room for a piece of silence after the
    ld   wv_r62, [x]
    ld   LINK_HI, x
    ld   wv_r62 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r62:
    sub  124, ac                ; last samples
    sub  [wv_wg], ac
    bcc  fn_r
    add  132, ac
fn_r:
    sub  ROOM, ac
    bcs  fn_room
    clr  ac
    ld   ac, [wv_ql]
    ld   ac, [wv_cnt]
    ld   QUIET >> 8, ac
    ld   ac, [wv_qh]
    ld   1, ac
    ld   ac, [wv_rp]
    ld   LINK_LO, x             ; CALL copy
    ld   wv_r63, [x]
    ld   LINK_HI, x
    ld   wv_r63 >> 8, [x]
    ld   copy >> 8, y
    jmp  copy
wv_r63:
fn_wait:
    ld   LINK_LO, x             ; until the video is in that silence
    ld   wv_r64, [x]
    ld   LINK_HI, x
    ld   wv_r64 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r64:
    sub  124, ac
    sub  [wv_wg], ac
    bcc  fn_d
    add  132, ac
fn_d:
    sub  100, ac
    bcs  fn_wait
fn_quiet:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r65, [x]
    ld   LINK_HI, x
    ld   wv_r65 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r65:
    ld   after >> 8, y
    jmp  after

badwav:
    ld   s_not & 0xFF, ac
    ld   ac, [R0]
    ld   s_not >> 8, ac
    ld   ac, [R1]
    ld   5, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r66, [x]
    ld   LINK_HI, x
    ld   wv_r66 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r66:
    ld   150, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   wv_r67, [x]
    ld   LINK_HI, x
    ld   wv_r67 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
wv_r67:
    ld   after >> 8, y
    jmp  after

; ------------------------------------------------------------
; fail - the message at R1:R0 on text row 3, then wait for Esc
; ------------------------------------------------------------
fail:
    ld   3, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r68, [x]
    ld   LINK_HI, x
    ld   wv_r68 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r68:
fl_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   wv_r69, [x]
    ld   LINK_HI, x
    ld   wv_r69 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
wv_r69:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   wv_r70, [x]
    ld   LINK_HI, x
    ld   wv_r70 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
wv_r70:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   wv_r71, [x]
    ld   LINK_HI, x
    ld   wv_r71 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
wv_r71:
    bra  fl_loop

; ============================================================
; data
; ============================================================

#addr 0x0E00
s_title:
    #d "PLACARD SOUND PLAYER", 0x00
s_dir:
    #d "SOUNDS", 0x00
s_of:
    #d " of ", 0x00
s_go:
    #d "         ", 0x00
s_hold:
    #d "   paused", 0x00
s_nodir:
    #d "There is no SOUNDS folder on the card.  Esc: exit", 0x00
s_none:
    #d "There are no .WAV files in this folder.  Esc: exit", 0x00
s_bad:
    #d "The card could not be read.  Esc: exit", 0x00

#addr 0x0F00
s_r31:
    #d "31.5 kHz                             ", 0x00
s_r15:
    #d "15.7 kHz                             ", 0x00
s_r7:
    #d "7.9 kHz                              ", 0x00
s_not:
    #d "Not a WAV file with 8 bits, 1 channel", 0x00
s_keys1:
    #d "Space: pause   Right or Enter: next   Left or Backspace: the one before", 0x00
s_keys2:
    #d "Esc: exit", 0x00
