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
;     Right, Left             a 64th of the file on, or back
;     Enter                   the next file
;     Backspace               the file before
;     Esc                     back to the DOS (menu_poll)
;
; After the folder's last file the program goes back by itself.
;
; The screen is a card on a board, in Pinboard's look and with its font
; and pointer (wave_data.asm, gen_wave_data.py): the file's name, its
; number and speed; the waveform of the sector being played, 512 samples
; a pixel each, drawn again every 2nd frame in two halves when there is
; nothing else to do; a slider of 64 cells with the time under it; three
; buttons.  The mouse: a click on the slider goes to that place in the
; file (hold the button and move: it follows), the buttons pause, play the
; next file and the one before, the pin in the card's title goes back as
; Esc does.
;
; Going to a place (seek): slider cell c is the file's sector
; ceil(c x sectors / 64).  The reader starts again at the file's first
; cluster (kept from its folder entry), passes the clusters before that
; sector (fs_nextc) and is set to the sector (V_SLBA, V_SSEC, V_REM); the
; samples left, the time and the slider are worked out for it, and the
; ring is silent until the first piece from there is written.  Cell 0
; opens the file again.
;
; Pinboard's Files card runs it for a .WAV file in any folder (MB_PHOTO =
; "S" and a parent to go back to): the files are then that folder's
; (MB_PCLUS), the first one played is the one chosen (MB_PN: its number
; among the folder's .WAV files), and the end or Esc goes back to
; Pinboard.
;
; RAM: the program at x0100 (asm_expand.py pages it), the font
; x3000-x37FF and the pointer's tables x3800-x39FF, zero page x20-x9F
; (the sound driver's bytes too: it is not used), the sector x4000-x41FF,
; a page of silence x4200, the waveform's rows x4300-x44FF, the screen
; under the pointer x4500.
;
;     python3 gen_wave_data.py                        wave_data.asm
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
wv_dol  = 0x26              ; where the samples start in the file (in its
wv_doh  = 0x27              ; first sector)
wv_de   = 0x85              ; 4: the place in the file past the last sample
wv_wdue = 0x89              ; halves of the waveform still to draw: 2, 1, 0
wv_wcnt = 0x8A              ; frames (a waveform every 2nd)
wv_mb   = 0x8B              ; 1: the left button was down at the last packet
wv_drag = 0x8C              ; 1: the slider is held
wv_sc   = 0x8D              ; the cell last gone to while it is held
wv_mok  = 0x8E              ; 0: a mouse runs
wv_c    = 0x8F              ; seek: the slider cell to go to, 0-63
wv_pxl  = 0x90              ; the pointer: X 0-639
wv_pxh  = 0x91
wv_pyl  = 0x92              ; Y 0-479
wv_pyh  = 0x93
wv_son  = 0x94              ; 1: the pointer is on the screen, at:
wv_sc2  = 0x95              ;   60 + 2 x its byte column
wv_syl  = 0x96              ;   its first row
wv_syh  = 0x97
wv_sti  = 0x98              ;   its shift << 4
wv_sn   = 0x99              ;   its rows on the screen
wv_sk   = 0x9A              ;   1: its right byte is on the screen too
wv_fc   = 0x9C              ; 4: the file's first cluster

; scratch that shares wv_hb (the header is read before the file plays)
wv_wi   = 0x40              ; wave: the point, 0-255
wv_wm   = 0x41              ; its bit in the screen byte
wv_oy   = 0x42              ; the row it was drawn in
wv_ny   = 0x43              ; the row it goes in
wv_scr  = 0x44              ; the screen page of its byte column
wv_spg  = 0x45              ; the page of the samples
wv_opg  = 0x46              ; the page of the rows drawn
wv_snl  = 0x47              ; seek: the file's sector to go to
wv_snh  = 0x48
wv_p    = 0x49              ; 4: sub4's second number
wv_q    = 0x4D              ; 4: sub4's first number and the answer
wv_bw   = 0x51              ; sub4: 1 = a borrow
wv_skl  = 0x52              ; seek: clusters to pass
wv_skh  = 0x53
wv_so   = 0x54              ; the sector in its cluster

SECT      = 0x4000          ; the sector read
QUIET     = 0x4200          ; 256 bytes of 80h
OLD       = 0x4300          ; 2 pages: the row each waveform point is drawn in
PSAVE     = 0x4500          ; the screen under the pointer: 2 bytes a row
FONT      = 0x3000          ; the font, 8 pages (wave_data.asm)
PTR       = 0x3800          ; the pointer's mask and white pixels, 2 pages
MAP_RUN   = 0x07            ; the program's map: RAM to x5FFF, the ROM above
RING_LO   = 0xF3            ; the ring: x5DF3-x5FFF
RING_HI   = 0x5D
FE_LO     = FS_ENTRY & 0xFF
ROOM      = 67              ; groups free before a piece is written

; the card: text rows and columns of the 80 x 60 screen
CARD_L    = 7               ; its left edge; its 64 columns are 8-71
CARD_R    = 72              ; its right edge
ROW_T     = 24              ; its title
ROW_INFO  = 26              ; the name, "n of m", the speed
ROW_WAVE  = 28              ; the waveform: 8 text rows, pixel rows 224-287
ROW_BAR   = 37              ; the slider
ROW_TIME  = 38              ; "m:ss of m:ss"
ROW_BTN   = 40              ; the buttons
ROW_B     = 42              ; its bottom edge
BAR_COL   = 8               ; the slider's 64 cells
BTN_P     = 27              ; the one before: 6 columns
BTN_H     = 36              ; pause: 8 columns
BTN_N     = 47              ; the next: 6 columns

; the menu block's bytes for Pinboard and this program (placard_menu.asm)
MB_PHOTO  = 0x19            ; "S": Pinboard's Files card asks for a sound
MB_PCLUS  = 0x1B            ; 4: the folder of the file asked for
MB_PN     = 0x1F            ; its number among the folder's .WAV files

#include "wave_data.asm"



; ============================================================
; main - the screen, the mouse, the folder, how many files
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
    ld   0x5B, y                ; the rail's rows 456-479 tinted blue, as
    ld   23, ac                 ; Pinboard's
mn_tint:
    add  0xE8, x
    ld   0x40, [y,x]
    sub  1, ac
    bcc  mn_tint
    ld   FONT >> 8, ac
    ld   ac, [FONT_PG]
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r2, [x]
    ld   LINK_HI, x
    ld   wv_r2 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r2:
    clr  ac
    ld   ac, [wv_n]
    ld   ac, [wv_tot]
    ld   ac, [wv_from]
    ld   ac, [wv_hold]
    ld   ac, [wv_son]
    ld   ac, [wv_drag]
    ld   ac, [wv_mb]
    ld   ac, [wv_wdue]
    ld   ac, [wv_wcnt]
    ld   0x80, ac               ; the page of silence
    ld   ac, [wv_t]
    clr  ac
    ld   ac, [R0]
    ld   ac, [R2]
    ld   QUIET >> 8, ac
    ld   ac, [R1]
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL memset
    ld   wv_r3, [x]
    ld   LINK_HI, x
    ld   wv_r3 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r3:
    ld   main2 >> 8, y
    jmp  main2

; the waveform's rows (any row will do: a point is cleared where it was),
; the pointer's place, the mouse (Pinboard's runs on)
main2:
    ld   32, ac
    ld   ac, [wv_t]
    clr  ac
    ld   ac, [R0]
    ld   ac, [R2]
    ld   OLD >> 8, ac
    ld   ac, [R1]
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL memset
    ld   wv_r4, [x]
    ld   LINK_HI, x
    ld   wv_r4 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r4:
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL memset
    ld   wv_r5, [x]
    ld   LINK_HI, x
    ld   wv_r5 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r5:
    ld   320 & 0xFF, ac
    ld   ac, [wv_pxl]
    ld   1, ac
    ld   ac, [wv_pxh]
    ld   ac, [wv_pyh]
    ld   368 & 0xFF, ac
    ld   ac, [wv_pyl]
    ld   [MOUSE_ST], ac
    blt  wm_run
    ld   LINK_LO, x             ; CALL mouse_init
    ld   wv_r6, [x]
    ld   LINK_HI, x
    ld   wv_r6 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
wv_r6:
    bra  wm_set
wm_run:
    clr  ac
wm_set:
    ld   ac, [wv_mok]
    ld   board >> 8, y
    jmp  board

; ------------------------------------------------------------
; board - the board (rows 0-56), the rail under it with the keys
; ------------------------------------------------------------
card3:
    ld   ROW_BTN, ac
    ld   ac, [CUR_ROW]
    ld   BTN_P, ac
    ld   ac, [CUR_COL]
    ld   s_prev & 0xFF, ac
    ld   ac, [R0]
    ld   s_prev >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r21, [x]
    ld   LINK_HI, x
    ld   wv_r21 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r21:
    ld   BTN_N, ac
    ld   ac, [CUR_COL]
    ld   s_next & 0xFF, ac
    ld   ac, [R0]
    ld   s_next >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r22, [x]
    ld   LINK_HI, x
    ld   wv_r22 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r22:
    ld   LINK_LO, x             ; CALL fs_mount
    ld   wv_r23, [x]
    ld   LINK_HI, x
    ld   wv_r23 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
wv_r23:
    bne  mn_no
    ld   whose >> 8, y
    jmp  whose
mn_no:
    ld   nodir >> 8, y
    jmp  nodir

; ------------------------------------------------------------
; fill - the character wv_t, wv_k times, from the cursor on
; ------------------------------------------------------------

#addr 0x0200
board:
    clr  ac
    ld   ac, [CUR_ROW]
    ld   ac, [CUR_COL]
    ld   57, ac
    ld   ac, [wv_d]
wbd_row:
    ld   0x01, ac
    ld   ac, [wv_t]
    ld   80, ac
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r7, [x]
    ld   LINK_HI, x
    ld   wv_r7 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r7:
    ld   [wv_d], ac
    dec
    ld   ac, [wv_d]
    bne  wbd_row
    ld   0x10, ac
    ld   ac, [wv_t]
    ld   80, ac
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r8, [x]
    ld   LINK_HI, x
    ld   wv_r8 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r8:
    ld   0x20, ac
    ld   ac, [wv_t]
    ld   159, ac                ; (the last cell would scroll the screen)
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r9, [x]
    ld   LINK_HI, x
    ld   wv_r9 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r9:
    ld   s_keys & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys >> 8, ac
    ld   ac, [R1]
    ld   58, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r10, [x]
    ld   LINK_HI, x
    ld   wv_r10 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r10:
    ld   card >> 8, y
    jmp  card

; ------------------------------------------------------------
; card - the card: the title with its pin, the white rows between the
; edges, the bottom edge
; ------------------------------------------------------------
card:
    ld   ROW_T, ac
    ld   ac, [CUR_ROW]
    ld   CARD_L, ac
    ld   ac, [CUR_COL]
    ld   0x07, ac               ; the pin
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r11, [x]
    ld   LINK_HI, x
    ld   wv_r11 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r11:
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r12, [x]
    ld   LINK_HI, x
    ld   wv_r12 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r12:
wcd_pad:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r13, [x]
    ld   LINK_HI, x
    ld   wv_r13 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r13:
    ld   [CUR_COL], ac
    xor  CARD_R + 1, ac
    bne  wcd_pad
    ld   ROW_T + 1, ac
    ld   ac, [wv_d]
wcd_row:
    ld   [wv_d], ac
    ld   ac, [CUR_ROW]
    ld   CARD_L, ac
    ld   ac, [CUR_COL]
    ld   0x02, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r14, [x]
    ld   LINK_HI, x
    ld   wv_r14 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r14:
    ld   0xA0, ac
    ld   ac, [wv_t]
    ld   64, ac
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r15, [x]
    ld   LINK_HI, x
    ld   wv_r15 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r15:
    ld   0x03, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r16, [x]
    ld   LINK_HI, x
    ld   wv_r16 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r16:
    ld   [wv_d], ac
    inc
    ld   ac, [wv_d]
    xor  ROW_B, ac
    bne  wcd_row
    ld   card2 >> 8, y
    jmp  card2

; the bottom edge, the waveform's black rows, the buttons

#addr 0x0300
card2:
    ld   ROW_B, ac
    ld   ac, [CUR_ROW]
    ld   CARD_L, ac
    ld   ac, [CUR_COL]
    ld   0x05, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r17, [x]
    ld   LINK_HI, x
    ld   wv_r17 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r17:
    ld   0x04, ac
    ld   ac, [wv_t]
    ld   64, ac
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r18, [x]
    ld   LINK_HI, x
    ld   wv_r18 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r18:
    ld   0x06, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r19, [x]
    ld   LINK_HI, x
    ld   wv_r19 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r19:
    ld   ROW_WAVE, ac
    ld   ac, [wv_d]
wc2_row:
    ld   [wv_d], ac
    ld   ac, [CUR_ROW]
    ld   CARD_L + 1, ac
    ld   ac, [CUR_COL]
    ld   0x20, ac
    ld   ac, [wv_t]
    ld   64, ac
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r20, [x]
    ld   LINK_HI, x
    ld   wv_r20 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r20:
    ld   [wv_d], ac
    inc
    ld   ac, [wv_d]
    xor  ROW_WAVE + 8, ac
    bne  wc2_row
    ld   card3 >> 8, y
    jmp  card3

fill:
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
wfi_l:
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r24, [x]
    ld   LINK_HI, x
    ld   wv_r24 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r24:
    ld   [wv_k], ac
    dec
    ld   ac, [wv_k]
    bne  wfi_l
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; puti - the string at R1:R0 from the cursor on, black on the card
; ------------------------------------------------------------
puti:
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
wpi_l:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    beq  wpi_x
    or   0x80, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r25, [x]
    ld   LINK_HI, x
    ld   wv_r25 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r25:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  wpi_l
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  wpi_l
wpi_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; numi - AC (0-255) in decimal, black on the card
; ------------------------------------------------------------
nodir:
    ld   s_nodir & 0xFF, ac
    ld   ac, [R0]
    ld   s_nodir >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail

; ------------------------------------------------------------
; msg - the string at R1:R0 on text row AC of the card
; ------------------------------------------------------------
bad:
    ld   s_bad & 0xFF, ac
    ld   ac, [R0]
    ld   s_bad >> 8, ac
    ld   ac, [R1]
    ld   fail >> 8, y
    jmp  fail

; the name: up to 8 characters (to the first space), then ".WAV", 00
hold:
    ld   [wv_hold], ac
    xor  1, ac
    ld   ac, [wv_hold]
    ld   1, ac
    ld   ac, [wv_draw]
    ld   loop >> 8, y
    jmp  loop

; back, fwd - a slider cell (a 64th of the file) back or on

#addr 0x0400
numi:
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
    ld   0xB0, ac
    ld   ac, [wv_d]
wni_h:
    ld   [wv_t], ac
    sub  100, ac
    bcs  wni_hx
    ld   ac, [wv_t]
    ld   [wv_d], ac
    inc
    ld   ac, [wv_d]
    bra  wni_h
wni_hx:
    ld   [wv_d], ac
    xor  0xB0, ac
    beq  wni_t
    ld   [wv_d], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r26, [x]
    ld   LINK_HI, x
    ld   wv_r26 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r26:
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL two
    ld   wv_r27, [x]
    ld   LINK_HI, x
    ld   wv_r27 >> 8, [x]
    ld   two >> 8, y
    jmp  two
wv_r27:
    ld   lib_leave >> 8, y
    jmp  lib_leave
wni_t:
    ld   [wv_t], ac
    sub  10, ac
    bcs  wni_o
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL two
    ld   wv_r28, [x]
    ld   LINK_HI, x
    ld   wv_r28 >> 8, [x]
    ld   two >> 8, y
    jmp  two
wv_r28:
    ld   lib_leave >> 8, y
    jmp  lib_leave
wni_o:
    ld   [wv_t], ac
    add  0xB0, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r29, [x]
    ld   LINK_HI, x
    ld   wv_r29 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r29:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; two - AC (0-99) as two digits
two:
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
    ld   0xB0, ac
    ld   ac, [wv_d]
wtw_l:
    ld   [wv_t], ac
    sub  10, ac
    bcs  wtw_o
    ld   ac, [wv_t]
    ld   [wv_d], ac
    inc
    ld   ac, [wv_d]
    bra  wtw_l
wtw_o:
    ld   [wv_d], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r30, [x]
    ld   LINK_HI, x
    ld   wv_r30 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r30:
    ld   [wv_t], ac
    add  0xB0, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r31, [x]
    ld   LINK_HI, x
    ld   wv_r31 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r31:
    ld   lib_leave >> 8, y
    jmp  lib_leave
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
    ld   CARD_L + 2, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL puti
    ld   wv_r32, [x]
    ld   LINK_HI, x
    ld   wv_r32 >> 8, [x]
    ld   puti >> 8, y
    jmp  puti
wv_r32:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; clrinfo - the card's name row white again

#addr 0x0500
clrinfo:
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
    ld   ROW_INFO, ac
    ld   ac, [CUR_ROW]
    ld   CARD_L + 1, ac
    ld   ac, [CUR_COL]
    ld   0xA0, ac
    ld   ac, [wv_t]
    ld   64, ac
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r33, [x]
    ld   LINK_HI, x
    ld   wv_r33 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r33:
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
    ld   wv_r34, [x]
    ld   LINK_HI, x
    ld   wv_r34 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r34:
    ld   0x80, ac
    ld   LINK_LO, x             ; x5E00-x5EFF
    ld   wv_r35, [x]
    ld   LINK_HI, x
    ld   wv_r35 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r35:
    ld   0x80, ac
    ld   LINK_LO, x             ; x5F00-x5FFF
    ld   wv_r36, [x]
    ld   LINK_HI, x
    ld   wv_r36 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
wv_r36:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; whose - whose files: the folder Pinboard's Files card was in (and the
; file chosen there first), or the card's SOUNDS folder
; ------------------------------------------------------------
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
    ld   wv_r37, [x]
    ld   LINK_HI, x
    ld   wv_r37 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
wv_r37:
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
back:
    ld   [wv_cell], ac
    beq  wbk_go
    dec
wbk_go:
    ld   ac, [wv_c]
    ld   seek >> 8, y
    jmp  seek


#addr 0x0600
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
    ld   wv_r38, [x]
    ld   LINK_HI, x
    ld   wv_r38 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
wv_r38:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; count - wv_tot = the .WAV files in the folder
; ------------------------------------------------------------
count:
    ld   LINK_LO, x             ; CALL opendir
    ld   wv_r39, [x]
    ld   LINK_HI, x
    ld   wv_r39 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
wv_r39:
    bne  ct_end
ct_loop:
    ld   LINK_LO, x             ; CALL fs_next
    ld   wv_r40, [x]
    ld   LINK_HI, x
    ld   wv_r40 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
wv_r40:
    bne  ct_end
    ld   LINK_LO, x             ; CALL is_wav
    ld   wv_r41, [x]
    ld   LINK_HI, x
    ld   wv_r41 >> 8, [x]
    ld   is_wav >> 8, y
    jmp  is_wav
wv_r41:
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
    ld   show >> 8, y
    jmp  show

; ------------------------------------------------------------
; is_wav - AC = 0 when FS_ENTRY is a file named *.WAV (a leaf)
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
show:
    ld   LINK_LO, x             ; CALL opendir
    ld   wv_r42, [x]
    ld   LINK_HI, x
    ld   wv_r42 >> 8, [x]
    ld   opendir >> 8, y
    jmp  opendir
wv_r42:
    bne  sh_bad
    ld   [wv_n], ac
    ld   ac, [wv_k]
sh_next:
    ld   LINK_LO, x             ; CALL fs_next
    ld   wv_r43, [x]
    ld   LINK_HI, x
    ld   wv_r43 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
wv_r43:
    bne  sh_end
    ld   LINK_LO, x             ; CALL is_wav
    ld   wv_r44, [x]
    ld   LINK_HI, x
    ld   wv_r44 >> 8, [x]
    ld   is_wav >> 8, y
    jmp  is_wav
wv_r44:
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


#addr 0x0700
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
    ld   wv_r45, [x]
    ld   LINK_HI, x
    ld   wv_r45 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
wv_r45:
    beq  nm_ok
    ld   bad >> 8, y
    jmp  bad
nm_ok:
    ld   FS_ENTRY >> 8, y
    ld   FE_LO + 26, x
    ld   [y,x], ac
    ld   ac, [wv_fc]
    ld   FE_LO + 27, x
    ld   [y,x], ac
    ld   ac, [wv_fc + 1]
    ld   FE_LO + 20, x
    ld   [y,x], ac
    ld   ac, [wv_fc + 2]
    ld   FE_LO + 21, x
    ld   [y,x], ac
    ld   ac, [wv_fc + 3]
    ld   title >> 8, y
    jmp  title

; ------------------------------------------------------------
; title - the card's name row: the name, "n of m"; then the file's first
; sector
; ------------------------------------------------------------
title:
    ld   LINK_LO, x             ; CALL p_hide
    ld   wv_r46, [x]
    ld   LINK_HI, x
    ld   wv_r46 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
wv_r46:
    ld   LINK_LO, x             ; CALL clrinfo
    ld   wv_r47, [x]
    ld   LINK_HI, x
    ld   wv_r47 >> 8, [x]
    ld   clrinfo >> 8, y
    jmp  clrinfo
wv_r47:
    ld   wv_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   ROW_INFO, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r48, [x]
    ld   LINK_HI, x
    ld   wv_r48 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r48:
    ld   30, ac
    ld   ac, [CUR_COL]
    ld   [wv_n], ac
    inc
    ld   LINK_LO, x             ; CALL numi
    ld   wv_r49, [x]
    ld   LINK_HI, x
    ld   wv_r49 >> 8, [x]
    ld   numi >> 8, y
    jmp  numi
wv_r49:
    ld   s_of & 0xFF, ac
    ld   ac, [R0]
    ld   s_of >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL puti
    ld   wv_r50, [x]
    ld   LINK_HI, x
    ld   wv_r50 >> 8, [x]
    ld   puti >> 8, y
    jmp  puti
wv_r50:
    ld   [wv_tot], ac
    ld   LINK_LO, x             ; CALL numi
    ld   wv_r51, [x]
    ld   LINK_HI, x
    ld   wv_r51 >> 8, [x]
    ld   numi >> 8, y
    jmp  numi
wv_r51:
    ld   first >> 8, y
    jmp  first
first:
    clr  ac
    ld   ac, [R4]
    ld   SECT >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_read
    ld   wv_r52, [x]
    ld   LINK_HI, x
    ld   wv_r52 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
wv_r52:
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

#addr 0x0800
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
    ld   wv_r53, [x]
    ld   LINK_HI, x
    ld   wv_r53 >> 8, [x]
    ld   peek >> 8, y
    jmp  peek
wv_r53:
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

#addr 0x0900
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
    ld   dend >> 8, y
    jmp  dend

; dend - wv_do = the samples' place in the file, wv_de = the place past
; the last of them (wv_rem + wv_do), for seek
dend:
    ld   [wv_sl], ac
    ld   ac, [wv_dol]
    ld   [wv_sh], ac
    sub  SECT >> 8, ac
    ld   ac, [wv_doh]
    ld   [wv_rem + 1], ac
    ld   ac, [wv_de + 1]
    ld   [wv_rem + 2], ac
    ld   ac, [wv_de + 2]
    ld   [wv_rem + 3], ac
    ld   ac, [wv_de + 3]
    ld   [wv_rem], ac
    add  [wv_dol], ac
    ld   ac, [wv_de]
    bcc  de_1
    ld   [wv_de + 1], ac
    inc
    ld   ac, [wv_de + 1]
    bne  de_1
    ld   [wv_de + 2], ac
    inc
    ld   ac, [wv_de + 2]
    bne  de_1
    ld   [wv_de + 3], ac
    inc
    ld   ac, [wv_de + 3]
de_1:
    ld   [wv_de + 1], ac
    add  [wv_doh], ac
    ld   ac, [wv_de + 1]
    bcc  de_2
    ld   [wv_de + 2], ac
    inc
    ld   ac, [wv_de + 2]
    bne  de_2
    ld   [wv_de + 3], ac
    inc
    ld   ac, [wv_de + 3]
de_2:
    ld   sectors >> 8, y
    jmp  sectors

; sectors - wv_ts = wv_rem / 512 + 1, the bar's whole
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

#addr 0x0A00
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
    ld   wv_r54, [x]
    ld   LINK_HI, x
    ld   wv_r54 >> 8, [x]
    ld   take >> 8, y
    jmp  take
wv_r54:
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
bar0:
    ld   LINK_LO, x             ; CALL slider
    ld   wv_r58, [x]
    ld   LINK_HI, x
    ld   wv_r58 >> 8, [x]
    ld   slider >> 8, y
    jmp  slider
wv_r58:
    ld   LINK_LO, x             ; CALL p_show
    ld   wv_r59, [x]
    ld   LINK_HI, x
    ld   wv_r59 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
wv_r59:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   wv_r60, [x]
    ld   LINK_HI, x
    ld   wv_r60 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r60:
    ld   [FRAME_LO], ac
    ld   ac, [wv_frm]
    ld   loop >> 8, y
    jmp  loop

; ------------------------------------------------------------
; slider - the slider's 64 cells: black up to wv_cell, a line from there
; ------------------------------------------------------------
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
    ld   wv_r65, [x]
    ld   LINK_HI, x
    ld   wv_r65 >> 8, [x]
    ld   warm >> 8, y
    jmp  warm
wv_r65:
    ld   loop >> 8, y
    jmp  loop

; warm - the FAT sector of the reader's cluster into the reader's buffer

#addr 0x0B00
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
    ld   wv_r55, [x]
    ld   LINK_HI, x
    ld   wv_r55 >> 8, [x]
    ld   take >> 8, y
    jmp  take
wv_r55:
    ld   LINK_LO, x             ; CALL ends
    ld   wv_r56, [x]
    ld   LINK_HI, x
    ld   wv_r56 >> 8, [x]
    ld   ends >> 8, y
    jmp  ends
wv_r56:
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
    ld   ROW_INFO, ac
    ld   ac, [CUR_ROW]
    ld   50, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL puti
    ld   wv_r57, [x]
    ld   LINK_HI, x
    ld   wv_r57 >> 8, [x]
    ld   puti >> 8, y
    jmp  puti
wv_r57:
    ld   bar0 >> 8, y
    jmp  bar0

fwd:
    ld   [wv_cell], ac
    inc
    ld   ac, [wv_c]
    sub  64, ac
    bcs  wfw_go
    ld   loop >> 8, y
    jmp  loop
wfw_go:
    ld   seek >> 8, y
    jmp  seek

; ------------------------------------------------------------
; mouse - once a frame: the pointer moved by what the mouse sent
; ------------------------------------------------------------
seekend:
    ld   LINK_LO, x             ; CALL p_show
    ld   wv_r90, [x]
    ld   LINK_HI, x
    ld   wv_r90 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
wv_r90:
    ld   1, ac
    ld   ac, [wv_new]
    ld   finish >> 8, y
    jmp  finish

; ------------------------------------------------------------
; sub4 - wv_q = wv_q - wv_p (4 bytes), wv_bw = 1 on a borrow (a leaf)
; ------------------------------------------------------------

#addr 0x0C00
slider:
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
    ld   ROW_BAR, ac
    ld   ac, [CUR_ROW]
    ld   BAR_COL, ac
    ld   ac, [CUR_COL]
    ld   0x20, ac
    ld   ac, [wv_t]
    ld   [wv_cell], ac
    beq  wsl_rest
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r61, [x]
    ld   LINK_HI, x
    ld   wv_r61 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r61:
wsl_rest:
    ld   0xAD, ac               ; "-", black on the card
    ld   ac, [wv_t]
    ld   64, ac
    sub  [wv_cell], ac
    beq  wsl_x
    ld   ac, [wv_k]
    ld   LINK_LO, x             ; CALL fill
    ld   wv_r62, [x]
    ld   LINK_HI, x
    ld   wv_r62 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
wv_r62:
wsl_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave
; ============================================================
; the loop: the keys and the mouse once a frame, the time line when it
; changed, the next sector when this one is used up, a piece to the ring
; when there is room for it, and a half of the waveform when there is
; nothing else to do
; ============================================================
loop:
    ld   LINK_LO, x             ; the mouse's bytes as they come
    ld   wv_r63, [x]
    ld   LINK_HI, x
    ld   wv_r63 >> 8, [x]
    ld   ps2_poll >> 8, y
    jmp  ps2_poll
wv_r63:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   wv_r64, [x]
    ld   LINK_HI, x
    ld   wv_r64 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r64:
    ld   ac, [wv_g]
    ld   [FRAME_LO], ac
    xor  [wv_frm], ac
    beq  lp_same
    ld   [FRAME_LO], ac
    ld   ac, [wv_frm]
    ld   [wv_wcnt], ac          ; every 2nd frame: the waveform
    inc
    ld   ac, [wv_wcnt]
    and  1, ac
    bne  lp_keys
    ld   [wv_hold], ac
    or   [wv_new], ac
    bne  lp_keys
    ld   2, ac
    ld   ac, [wv_wdue]
lp_keys:
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
    ld   [wv_wdue], ac
    beq  lp_idle
    ld   wave >> 8, y
    jmp  wave
lp_idle:
    ld   loop >> 8, y
    jmp  loop
lp_new:
    ld   start >> 8, y
    jmp  start

; warmq - the next cluster looked up now if nothing plays yet or the ring
; is nearly full (under 21 groups free), else later
drag:
    ld   [wv_drag], ac
    beq  wdg_no
    ld   [wv_t], ac
    sub  BAR_COL, ac
    bcc  wdg_in
    clr  ac
wdg_in:
    ld   ac, [wv_c]
    sub  64, ac
    bcs  wdg_ok
    ld   63, ac
    ld   ac, [wv_c]
wdg_ok:
    ld   [wv_c], ac
    xor  [wv_sc], ac
    beq  wdg_no
    ld   [wv_c], ac
    ld   ac, [wv_sc]
    ld   seek >> 8, y
    jmp  seek
wdg_no:
    ld   loop >> 8, y
    jmp  loop

; leave - the pin: back, as Esc goes

#addr 0x0D00
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
    ld   wv_r66, [x]
    ld   LINK_HI, x
    ld   wv_r66 >> 8, [x]
    ld   fs_nextc >> 8, y
    jmp  fs_nextc
wv_r66:
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
    ld   wv_r67, [x]
    ld   LINK_HI, x
    ld   wv_r67 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
wv_r67:
    ld   [KBD_NOW + (K_ESC >> 3)], ac   ; Esc: silence and the standard
    and  1 << (K_ESC & 7), ac           ; font before the DOS takes over
    bne  ky_poll                        ; (menu_poll)
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r68, [x]
    ld   LINK_HI, x
    ld   wv_r68 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r68:
    ld   1, ac
    ld   ac, [wv_new]
    ld   LIB_FONT >> 8, ac
    ld   ac, [FONT_PG]
ky_poll:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   wv_r69, [x]
    ld   LINK_HI, x
    ld   wv_r69 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
wv_r69:
    ld   FONT >> 8, ac
    ld   ac, [FONT_PG]
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   wv_r70, [x]
    ld   LINK_HI, x
    ld   wv_r70 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
wv_r70:
    beq  ky_none
    ld   ac, [wv_key]
    xor  0x20, ac               ; Space
    beq  ky_hold
    xor  0x20 ^ 0x14, ac        ; Right
    beq  ky_fwd
    xor  0x14 ^ 0x0A, ac        ; Enter
    beq  ky_next
    xor  0x0A ^ 0x13, ac        ; Left
    beq  ky_back
    xor  0x13 ^ 0x08, ac        ; Backspace
    beq  ky_prev
ky_none:
    ld   mouse >> 8, y
    jmp  mouse
ky_hold:
    ld   hold >> 8, y
    jmp  hold
ky_next:
    ld   next >> 8, y
    jmp  next
ky_prev:
    ld   prev >> 8, y
    jmp  prev
ky_fwd:
    ld   fwd >> 8, y
    jmp  fwd
ky_back:
    ld   back >> 8, y
    jmp  back

; hold - pause, or go on
leave:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r75, [x]
    ld   LINK_HI, x
    ld   wv_r75 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r75:
    ld   1, ac
    ld   ac, [wv_new]
    ld   MENU_BLK >> 8, y
    ld   MB_MAGIC, x
    ld   [y,x], ac
    xor  0x4D, ac               ; "M"
    bne  wlv_stay
    ld   LIB_FONT >> 8, ac
    ld   ac, [FONT_PG]
    ld   MB_WHY, x
    ld   WHY_ESC, ac
    ld   ac, [y,x]
    jmp  MB_EXIT
wlv_stay:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; seek - go to slider cell wv_c of the file: the sector there, the time
; and the slider as they are there, the reader at that sector; the ring
; silent until the samples come
; ============================================================

#addr 0x0E00
mouse:
    ld   [wv_mok], ac
    bne  wmo_x
    ld   [MOUSE_ST], ac         ; the loop has taken its bytes (ps2_poll):
    or   0x40, ac               ; no waiting for the rest of a packet
    ld   ac, [MOUSE_ST]
    ld   LINK_LO, x             ; CALL mouse_poll
    ld   wv_r71, [x]
    ld   LINK_HI, x
    ld   wv_r71 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
wv_r71:
    beq  wmo_x
    ld   LINK_LO, x             ; CALL p_hide
    ld   wv_r72, [x]
    ld   LINK_HI, x
    ld   wv_r72 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
wv_r72:
    ld   [wv_pxl], ac
    ld   ac, [R0]
    ld   [wv_pxh], ac
    ld   ac, [R1]
    ld   [wv_pyl], ac
    ld   ac, [R2]
    ld   [wv_pyh], ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL mouse_move
    ld   wv_r73, [x]
    ld   LINK_HI, x
    ld   wv_r73 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
wv_r73:
    ld   [R0], ac
    ld   ac, [wv_pxl]
    ld   [R1], ac
    ld   ac, [wv_pxh]
    ld   [R2], ac
    ld   ac, [wv_pyl]
    ld   [R3], ac
    ld   ac, [wv_pyh]
    ld   LINK_LO, x             ; CALL p_show
    ld   wv_r74, [x]
    ld   LINK_HI, x
    ld   wv_r74 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
wv_r74:
    ld   click >> 8, y
    jmp  click
wmo_x:
    ld   loop >> 8, y
    jmp  loop

; click - wv_t, wv_d = the pointer's column and text row; the left button
click:
    ld   [wv_pxl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wv_t]
    ld   [wv_pxh], ac
    shl
    shl
    shl
    shl
    shl
    or   [wv_t], ac
    ld   ac, [wv_t]
    ld   [wv_pyl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wv_d]
    ld   [wv_pyh], ac
    shl
    shl
    shl
    shl
    shl
    or   [wv_d], ac
    ld   ac, [wv_d]
    ld   [MOUSE_B], ac
    and  1, ac
    bne  wck_down
    ld   ac, [wv_mb]            ; let go
    ld   ac, [wv_drag]
    ld   loop >> 8, y
    jmp  loop
wck_down:
    ld   [wv_mb], ac
    bne  wck_held
    ld   1, ac
    ld   ac, [wv_mb]
    ld   press >> 8, y
    jmp  press
wck_held:
    ld   drag >> 8, y
    jmp  drag

; press - the button went down: on the pin, a button, the slider?
seek2:
    ld   [wv_p + 2], ac
    and  63, ac
    ld   ac, [wv_t]
    ld   64, ac
    sub  [wv_t], ac
    and  63, ac
    ld   ac, [wv_bal]
    clr  ac
    ld   ac, [wv_bah]
    ld   [wv_c], ac
    ld   ac, [wv_cell]
    ld   [wv_p + 2], ac
    add  63, ac
    ld   ac, [wv_p + 2]
    bcc  ws2_1
    ld   [wv_p + 3], ac
    inc
    ld   ac, [wv_p + 3]
ws2_1:
    ld   [wv_p + 2], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wv_t]
    ld   [wv_p + 3], ac
    shl
    shl
    or   [wv_t], ac
    add  [wv_p], ac
    ld   ac, [wv_snl]
    ld   [wv_p + 1], ac
    bcc  ws2_2
    inc
ws2_2:
    ld   ac, [wv_snh]
    ld   seek3 >> 8, y
    jmp  seek3

; wv_p = the sector's place in the file (512 x); what is left of the
; samples from there (wv_tmp), none: the file is over

#addr 0x0F00
press:
    ld   [wv_d], ac
    xor  ROW_T, ac
    bne  wpr_btn
    ld   [wv_t], ac
    sub  CARD_L, ac
    bcs  wpr_no
    sub  2, ac
    bcc  wpr_no
    ld   leave >> 8, y
    jmp  leave
wpr_btn:
    xor  ROW_T ^ ROW_BTN, ac
    bne  wpr_bar
    ld   [wv_t], ac
    sub  BTN_P, ac
    bcs  wpr_no
    sub  6, ac
    bcc  wpr_b2
    ld   prev >> 8, y
    jmp  prev
wpr_b2:
    ld   [wv_t], ac
    sub  BTN_H, ac
    bcs  wpr_no
    sub  8, ac
    bcc  wpr_b3
    ld   hold >> 8, y
    jmp  hold
wpr_b3:
    ld   [wv_t], ac
    sub  BTN_N, ac
    bcs  wpr_no
    sub  6, ac
    bcc  wpr_no
    ld   next >> 8, y
    jmp  next
wpr_bar:
    ld   [wv_d], ac
    sub  ROW_BAR - 1, ac
    bcs  wpr_no
    sub  3, ac
    bcc  wpr_no
    ld   [wv_t], ac
    sub  BAR_COL, ac
    bcs  wpr_no
    sub  64, ac
    bcc  wpr_no
    ld   1, ac
    ld   ac, [wv_drag]
    ld   0xFF, ac
    ld   ac, [wv_sc]
    ld   drag >> 8, y
    jmp  drag
wpr_no:
    ld   loop >> 8, y
    jmp  loop

; drag - the slider is held: go to the cell under the pointer when it is
; another than the last
seek:
    ld   [wv_c], ac
    bne  wsk_go
    ld   LINK_LO, x             ; cell 0: the file from its start
    ld   wv_r76, [x]
    ld   LINK_HI, x
    ld   wv_r76 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r76:
    ld   show >> 8, y
    jmp  show
wsk_go:
    ld   LINK_LO, x             ; CALL p_hide
    ld   wv_r77, [x]
    ld   LINK_HI, x
    ld   wv_r77 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
wv_r77:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r78, [x]
    ld   LINK_HI, x
    ld   wv_r78 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r78:
    ld   [wv_tsl], ac           ; the file's sectors = 64 q + r
    and  63, ac
    ld   ac, [wv_q + 2]
    ld   [wv_tsl], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wv_q]
    ld   [wv_tsh], ac
    shl
    shl
    or   [wv_q], ac
    ld   ac, [wv_q]
    ld   [wv_tsh], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wv_q + 1]
    clr  ac
    ld   ac, [wv_p]
    ld   ac, [wv_p + 1]
    ld   ac, [wv_p + 2]
    ld   ac, [wv_p + 3]
    ld   [wv_c], ac
    ld   ac, [wv_k]
wsk_mul:                        ; wv_p = c q, wv_p + 2 = c r
    ld   [wv_p], ac
    add  [wv_q], ac
    ld   ac, [wv_p]
    ld   [wv_p + 1], ac
    bcc  wsk_m1
    inc
wsk_m1:
    add  [wv_q + 1], ac
    ld   ac, [wv_p + 1]
    ld   [wv_p + 2], ac
    add  [wv_q + 2], ac
    ld   ac, [wv_p + 2]
    bcc  wsk_m2
    ld   [wv_p + 3], ac
    inc
    ld   ac, [wv_p + 3]
wsk_m2:
    ld   [wv_k], ac
    dec
    ld   ac, [wv_k]
    bne  wsk_mul
    ld   seek2 >> 8, y
    jmp  seek2

; the sector: c q + (c r + 63) / 64, the first that shows cell c; the
; slider's remainder there

#addr 0x1000
seek3:
    clr  ac
    ld   ac, [wv_p]
    ld   ac, [wv_p + 3]
    ld   [wv_snl], ac
    shl
    ld   ac, [wv_p + 1]
    ld   [wv_snh], ac
    shl
    ld   ac, [wv_p + 2]
    ld   [wv_snl], ac
    blt  ws3_a
    bra  ws3_b
ws3_a:
    ld   [wv_p + 2], ac
    or   1, ac
    ld   ac, [wv_p + 2]
ws3_b:
    ld   [wv_snh], ac
    blt  ws3_c
    bra  ws3_d
ws3_c:
    ld   1, ac
    ld   ac, [wv_p + 3]
ws3_d:
    ld   [wv_de], ac
    ld   ac, [wv_q]
    ld   [wv_de + 1], ac
    ld   ac, [wv_q + 1]
    ld   [wv_de + 2], ac
    ld   ac, [wv_q + 2]
    ld   [wv_de + 3], ac
    ld   ac, [wv_q + 3]
    ld   LINK_LO, x             ; CALL sub4
    ld   wv_r79, [x]
    ld   LINK_HI, x
    ld   wv_r79 >> 8, [x]
    ld   sub4 >> 8, y
    jmp  sub4
wv_r79:
    ld   [wv_bw], ac
    bne  ws3_end
    ld   [wv_q], ac
    or   [wv_q + 1], ac
    or   [wv_q + 2], ac
    or   [wv_q + 3], ac
    beq  ws3_end
    ld   seek4 >> 8, y
    jmp  seek4
ws3_end:
    ld   seekend >> 8, y
    jmp  seekend

; the time there: the samples before it (the place less where they
; start), a second's bytes at a time
seek4:
    ld   [wv_q], ac
    ld   ac, [wv_tmp]
    ld   [wv_q + 1], ac
    ld   ac, [wv_tmp + 1]
    ld   [wv_q + 2], ac
    ld   ac, [wv_tmp + 2]
    ld   [wv_q + 3], ac
    ld   ac, [wv_tmp + 3]
    ld   [wv_p], ac
    ld   ac, [wv_q]
    ld   [wv_p + 1], ac
    ld   ac, [wv_q + 1]
    ld   [wv_p + 2], ac
    ld   ac, [wv_q + 2]
    ld   [wv_p + 3], ac
    ld   ac, [wv_q + 3]
    ld   [wv_dol], ac
    ld   ac, [wv_p]
    ld   [wv_doh], ac
    ld   ac, [wv_p + 1]
    clr  ac
    ld   ac, [wv_p + 2]
    ld   ac, [wv_p + 3]
    ld   LINK_LO, x             ; CALL sub4
    ld   wv_r80, [x]
    ld   LINK_HI, x
    ld   wv_r80 >> 8, [x]
    ld   sub4 >> 8, y
    jmp  sub4
wv_r80:
    ld   [wv_q], ac
    ld   ac, [wv_rem]
    ld   [wv_q + 1], ac
    ld   ac, [wv_rem + 1]
    ld   [wv_q + 2], ac
    ld   ac, [wv_rem + 2]
    ld   [wv_q + 3], ac
    ld   ac, [wv_rem + 3]
    clr  ac
    ld   ac, [wv_sec]
    ld   ac, [wv_min]
    ld   seek5 >> 8, y
    jmp  seek5

seek5:
    ld   [wv_kcl], ac
    ld   ac, [wv_avl]
    ld   [wv_kch], ac
    ld   ac, [wv_avh]
    ld   LINK_LO, x             ; CALL take
    ld   wv_r81, [x]
    ld   LINK_HI, x
    ld   wv_r81 >> 8, [x]
    ld   take >> 8, y
    jmp  take
wv_r81:
    ld   [wv_avl], ac
    xor  [wv_kcl], ac
    bne  ws5_end
    ld   [wv_avh], ac
    xor  [wv_kch], ac
    bne  ws5_end
    ld   [wv_sec], ac
    inc
    ld   ac, [wv_sec]
    xor  60, ac
    bne  seek5
    ld   ac, [wv_sec]
    ld   [wv_min], ac
    inc
    ld   ac, [wv_min]
    bra  seek5
ws5_end:
    ld   [wv_avl], ac
    ld   ac, [wv_acl]
    ld   [wv_avh], ac
    ld   ac, [wv_ach]
    ld   [wv_tmp], ac
    ld   ac, [wv_rem]
    ld   [wv_tmp + 1], ac
    ld   ac, [wv_rem + 1]
    ld   [wv_tmp + 2], ac
    ld   ac, [wv_rem + 2]
    ld   [wv_tmp + 3], ac
    ld   ac, [wv_rem + 3]
    ld   seek6 >> 8, y
    jmp  seek6

; the reader: from the file's first cluster, the clusters before the
; sector's passed (sector >> V_SHIFT of them)

#addr 0x1100
seek6:
    ld   [wv_fc], ac
    ld   ac, [T0]
    ld   [wv_fc + 1], ac
    ld   ac, [T1]
    ld   [wv_fc + 2], ac
    ld   ac, [T2]
    ld   [wv_fc + 3], ac
    ld   ac, [T3]
    ld   LINK_LO, x             ; CALL fs_chain
    ld   wv_r82, [x]
    ld   LINK_HI, x
    ld   wv_r82 >> 8, [x]
    ld   fs_chain >> 8, y
    jmp  fs_chain
wv_r82:
    ld   FSV, y
    ld   V_SPC, x
    ld   [y,x], ac
    dec
    and  [wv_snl], ac
    ld   ac, [wv_so]
    ld   [wv_snl], ac
    ld   ac, [wv_skl]
    ld   [wv_snh], ac
    ld   ac, [wv_skh]
    ld   V_SHIFT, x
    ld   [y,x], ac
    ld   ac, [wv_k]
ws6_sh:
    ld   [wv_k], ac
    beq  ws6_x
    dec
    ld   ac, [wv_k]
    ld   [wv_skl], ac
    shr  ac
    ld   ac, [wv_skl]
    ld   [wv_skh], ac
    and  1, ac
    beq  ws6_n
    ld   [wv_skl], ac
    or   0x80, ac
    ld   ac, [wv_skl]
ws6_n:
    ld   [wv_skh], ac
    shr  ac
    ld   ac, [wv_skh]
    bra  ws6_sh
ws6_x:
    ld   seek7 >> 8, y
    jmp  seek7

seek7:
    ld   [wv_skl], ac
    or   [wv_skh], ac
    beq  ws7_at
    ld   LINK_LO, x             ; CALL fs_nextc
    ld   wv_r83, [x]
    ld   LINK_HI, x
    ld   wv_r83 >> 8, [x]
    ld   fs_nextc >> 8, y
    jmp  fs_nextc
wv_r83:
    bne  ws7_bad
    ld   [wv_skl], ac
    dec
    ld   ac, [wv_skl]
    xor  0xFF, ac
    bne  seek7
    ld   [wv_skh], ac
    dec
    ld   ac, [wv_skh]
    bra  seek7
ws7_at:
    ld   seek8 >> 8, y
    jmp  seek8
ws7_bad:
    ld   seekend >> 8, y
    jmp  seekend

; the reader's next sector: the cluster's first + the sector in it; the
; sectors left in the cluster; the bytes left
sub4:
    ld   [wv_q], ac
    sub  [wv_p], ac
    ld   ac, [wv_q]
    bcs  sb_b0
    clr  ac
    bra  sb_s0
sb_b0:
    ld   1, ac
sb_s0:
    ld   ac, [wv_bw]
    ld   [wv_q + 1], ac
    sub  [wv_bw], ac
    bcs  sb_c1                  ; 00 less the borrow: FF, a borrow on
    sub  [wv_p + 1], ac
    ld   ac, [wv_q + 1]
    bcs  sb_b1
    clr  ac
    bra  sb_s1
sb_c1:
    sub  [wv_p + 1], ac
    ld   ac, [wv_q + 1]
sb_b1:
    ld   1, ac
sb_s1:
    ld   ac, [wv_bw]
    ld   [wv_q + 2], ac
    sub  [wv_bw], ac
    bcs  sb_c2
    sub  [wv_p + 2], ac
    ld   ac, [wv_q + 2]
    bcs  sb_b2
    clr  ac
    bra  sb_s2
sb_c2:
    sub  [wv_p + 2], ac
    ld   ac, [wv_q + 2]
sb_b2:
    ld   1, ac
sb_s2:
    ld   ac, [wv_bw]
    ld   [wv_q + 3], ac
    sub  [wv_bw], ac
    bcs  sb_c3
    sub  [wv_p + 3], ac
    ld   ac, [wv_q + 3]
    bcs  sb_b3
    clr  ac
    bra  sb_s3
sb_c3:
    sub  [wv_p + 3], ac
    ld   ac, [wv_q + 3]
sb_b3:
    ld   1, ac
sb_s3:
    ld   ac, [wv_bw]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; wave - half of the waveform: the sector's 256 samples of this half, a
; pixel each, 64 rows for the 256 levels.  A point is cleared in the row
; it was drawn in (OLD) and set in its new row.  The screen is read and
; written with every section mapped to RAM (no library call meanwhile).
; ============================================================
over:
    ld   [wv_pyh], ac
    bne  wov_hi
    ld   [wv_pyl], ac
    sub  213, ac
    bcs  wov_no
    ld   p_hide >> 8, y
    jmp  p_hide
wov_hi:
    ld   [wv_pyl], ac
    sub  32, ac
    bcc  wov_no
    ld   p_hide >> 8, y
    jmp  p_hide
wov_no:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the pointer (Pinboard's, pinboard_drv_mono.masm)
; ============================================================
; p_hide - the screen under the pointer put back (T0-T3; a leaf)

#addr 0x1200
seek8:
    ld   V_SCLUS, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   wv_r84, [x]
    ld   LINK_HI, x
    ld   wv_r84 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
wv_r84:
    ld   LINK_LO, x             ; CALL fs_clba
    ld   wv_r85, [x]
    ld   LINK_HI, x
    ld   wv_r85 >> 8, [x]
    ld   fs_clba >> 8, y
    jmp  fs_clba
wv_r85:
    ld   [wv_so], ac
    ld   ac, [T4]
    clr  ac
    ld   ac, [T5]
    ld   ac, [T6]
    ld   ac, [T7]
    ld   LINK_LO, x             ; CALL fs_add
    ld   wv_r86, [x]
    ld   LINK_HI, x
    ld   wv_r86 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
wv_r86:
    ld   V_SLBA, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   wv_r87, [x]
    ld   LINK_HI, x
    ld   wv_r87 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
wv_r87:
    ld   FSV, y
    ld   V_SPC, x
    ld   [y,x], ac
    sub  [wv_so], ac
    ld   V_SSEC, x
    ld   ac, [y,x]
    ld   V_SMODE, x
    ld   0, [y,x]
    ld   V_REM, x
    ld   [wv_rem], ac
    ld   ac, [y,x]
    ld   V_REM + 1, x
    ld   [wv_rem + 1], ac
    ld   ac, [y,x]
    ld   V_REM + 2, x
    ld   [wv_rem + 2], ac
    ld   ac, [y,x]
    ld   V_REM + 3, x
    ld   [wv_rem + 3], ac
    ld   ac, [y,x]
    clr  ac
    ld   ac, [wv_avl]
    ld   ac, [wv_avh]
    ld   ac, [wv_warm]
    ld   1, ac
    ld   ac, [wv_new]
    ld   ac, [wv_draw]
    ld   LINK_LO, x             ; CALL slider
    ld   wv_r88, [x]
    ld   LINK_HI, x
    ld   wv_r88 >> 8, [x]
    ld   slider >> 8, y
    jmp  slider
wv_r88:
    ld   LINK_LO, x             ; CALL p_show
    ld   wv_r89, [x]
    ld   LINK_HI, x
    ld   wv_r89 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
wv_r89:
    ld   loop >> 8, y
    jmp  loop

; seekend - past the file's last sample: the file is over
wave:
    ld   LINK_LO, x             ; the pointer off the waveform
    ld   wv_r91, [x]
    ld   LINK_HI, x
    ld   wv_r91 >> 8, [x]
    ld   over >> 8, y
    jmp  over
wv_r91:
    ld   [wv_wdue], ac
    xor  2, ac
    beq  ww_a
    ld   (SECT >> 8) + 1, ac
    ld   ac, [wv_spg]
    ld   (OLD >> 8) + 1, ac
    ld   ac, [wv_opg]
    ld   0x61 + 2 * (CARD_L + 33), ac
    bra  ww_go
ww_a:
    ld   SECT >> 8, ac
    ld   ac, [wv_spg]
    ld   OLD >> 8, ac
    ld   ac, [wv_opg]
    ld   0x61 + 2 * (CARD_L + 1), ac
ww_go:
    ld   ac, [wv_scr]
    ld   [wv_wdue], ac
    dec
    ld   ac, [wv_wdue]
    clr  ac
    ld   ac, [wv_wi]
    ld   1, ac
    ld   ac, [wv_wm]
    ld   0x50, y
    ld   0xFF, [y,x]
    ld   wavel >> 8, y
    jmp  wavel

next:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r93, [x]
    ld   LINK_HI, x
    ld   wv_r93 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r93:
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


#addr 0x1300
wavel:
    ld   [wv_opg], y
    ld   [wv_wi], x
    ld   [y,x], ac
    ld   ac, [wv_oy]
    ld   [wv_spg], y
    ld   [y,x], ac
    shr  ac
    shr  ac
    xor  63, ac
    ld   ac, [wv_ny]
    ld   [wv_opg], y
    ld   ac, [y,x]
    ld   [wv_wm], ac
    xor  0xFF, ac
    ld   ac, [wv_t]
    ld   [wv_scr], y
    ld   [wv_oy], x
    ld   [y,x], ac
    and  [wv_t], ac
    ld   ac, [y,x]
    ld   [wv_ny], x
    ld   [y,x], ac
    or   [wv_wm], ac
    ld   ac, [y,x]
    ld   [wv_wm], ac
    shl
    ld   ac, [wv_wm]
    bne  ww_same
    ld   1, ac
    ld   ac, [wv_wm]
    ld   [wv_scr], ac
    add  2, ac
    ld   ac, [wv_scr]
ww_same:
    ld   [wv_wi], ac
    inc
    ld   ac, [wv_wi]
    bne  wavel
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   LINK_LO, x             ; CALL p_show
    ld   wv_r92, [x]
    ld   LINK_HI, x
    ld   wv_r92 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
wv_r92:
    ld   loop >> 8, y
    jmp  loop

; over - the pointer taken off the screen when it is on the waveform's
; rows (213-287 for its 12 rows); p_hide returns
p_hide:
    ld   [wv_son], ac
    beq  ph_x
    clr  ac
    ld   ac, [wv_son]
    ld   ac, [T0]
ph_l:
    ld   [wv_syl], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [wv_syh], ac
    bcc  pra1
    inc
pra1:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb1
    inc
prb1:
    add  [wv_sc2], ac
    ld   ac, [T2]
    ld   [T0], ac
    shl
    ld   ac, x
    ld   PSAVE >> 8, y
    ld   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [wv_sk], ac
    beq  ph_n
    ld   [T0], ac
    shl
    add  1, x
    ld   PSAVE >> 8, y
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [T2], ac
    add  2, y
    ld   [T1], x
    ld   [T3], ac
    ld   ac, [y,x]
ph_n:
    ld   [T0], ac
    inc
    ld   ac, [T0]
    xor  [wv_sn], ac
    bne  ph_l
ph_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; p_show - the pointer drawn at wv_px, wv_py (T0-T3; a leaf)
prev:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r94, [x]
    ld   LINK_HI, x
    ld   wv_r94 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r94:
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
    ld   0xBA, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r112, [x]
    ld   LINK_HI, x
    ld   wv_r112 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r112:
    ld   [wv_t], ac
    ld   LINK_LO, x             ; CALL two
    ld   wv_r113, [x]
    ld   LINK_HI, x
    ld   wv_r113 >> 8, [x]
    ld   two >> 8, y
    jmp  two
wv_r113:
    ld   lib_leave >> 8, y
    jmp  lib_leave
; ------------------------------------------------------------
; finish - the file's end: a piece of silence after the last samples,
; wait until the video is in it, the whole ring silent, the next file or
; (after the last) back
; ------------------------------------------------------------
p_show:
    ld   [wv_son], ac
    bne  ps_x
    ld   [wv_mok], ac
    bne  ps_x                   ; no mouse: no pointer
    ld   1, ac
    ld   ac, [wv_son]
    ld   [wv_pxl], ac
    and  7, ac
    shl
    shl
    shl
    shl
    ld   ac, [wv_sti]
    ld   [wv_pxl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T3]
    ld   [wv_pxh], ac
    shl
    shl
    shl
    shl
    shl
    or   [T3], ac
    ld   ac, [T3]               ; the byte column
    xor  79, ac
    beq  ps_k
    ld   1, ac
ps_k:
    ld   ac, [wv_sk]
    ld   [T3], ac
    shl
    add  0x60, ac
    ld   ac, [wv_sc2]
    ld   [wv_pyl], ac
    ld   ac, [wv_syl]
    ld   [wv_pyh], ac
    ld   ac, [wv_syh]
    ld   12, ac
    ld   ac, [wv_sn]
    ld   [wv_pyh], ac
    beq  ps_go
    ld   0xE0, ac               ; rows left to 480
    sub  [wv_pyl], ac
    ld   ac, [T3]
    sub  12, ac
    bcc  ps_go
    ld   [T3], ac
    ld   ac, [wv_sn]
ps_go:
    ld   0x50, y
    ld   0xFF, [y,x]
    clr  ac
    ld   ac, [T0]
    ld   ps_l >> 8, y
    jmp  ps_l
ps_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

ps_l:
    ld   [wv_syl], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [wv_syh], ac
    bcc  pra2
    inc
pra2:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb2
    inc
prb2:
    add  [wv_sc2], ac
    ld   ac, [T2]
    ld   [T2], y                ; the left byte
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [T0], ac
    shl
    ld   ac, x
    ld   PSAVE >> 8, y
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [wv_sti], ac
    or   [T0], ac
    ld   ac, x
    ld   PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PTR >> 8) + 1, y
    or   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [wv_sk], ac
    beq  ps_n
    ld   [T2], ac               ; the right byte
    add  2, y
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [T0], ac
    shl
    add  1, x
    ld   PSAVE >> 8, y
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [wv_sti], ac
    or   [T0], ac
    or   0x80, x
    ld   PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PTR >> 8) + 1, y
    or   [y,x], ac
    ld   ac, [T3]
    ld   [T2], ac
    add  2, y
    ld   [T1], x
    ld   [T3], ac
    ld   ac, [y,x]
ps_n:
    ld   [T0], ac
    inc
    ld   ac, [T0]
    xor  [wv_sn], ac
    bne  ps_l
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

#addr 0x1500
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
sector:
    clr  ac
    ld   ac, [wv_avl]
    ld   2, ac
    ld   ac, [wv_avh]
    ld   LINK_LO, x             ; CALL take
    ld   wv_r95, [x]
    ld   LINK_HI, x
    ld   wv_r95 >> 8, [x]
    ld   take >> 8, y
    jmp  take
wv_r95:
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
    ld   wv_r96, [x]
    ld   LINK_HI, x
    ld   wv_r96 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
wv_r96:
    bne  sc_end
    ld   LINK_LO, x             ; CALL ends
    ld   wv_r97, [x]
    ld   LINK_HI, x
    ld   wv_r97 >> 8, [x]
    ld   ends >> 8, y
    jmp  ends
wv_r97:
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
    ld   LINK_LO, x             ; CALL p_hide
    ld   wv_r98, [x]
    ld   LINK_HI, x
    ld   wv_r98 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
wv_r98:
    ld   ROW_BAR, ac
    ld   ac, [CUR_ROW]
    ld   [wv_cell], ac
    add  BAR_COL, ac
    ld   ac, [CUR_COL]
    ld   [wv_cell], ac
    inc
    ld   ac, [wv_cell]
    ld   0x20, ac               ; a black cell
    ld   LINK_LO, x             ; CALL con_putc
    ld   wv_r99, [x]
    ld   LINK_HI, x
    ld   wv_r99 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wv_r99:
    ld   LINK_LO, x             ; CALL p_show
    ld   wv_r100, [x]
    ld   LINK_HI, x
    ld   wv_r100 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
wv_r100:
    bra  br_cmp
br_done:
    ld   loop >> 8, y
    jmp  loop

; piece - the next piece to the ring: silence while paused, else up to
; wv_ch of the sector's samples

#addr 0x1600
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
    ld   wv_r101, [x]
    ld   LINK_HI, x
    ld   wv_r101 >> 8, [x]
    ld   copy >> 8, y
    jmp  copy
wv_r101:
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
    ld   wv_r102, [x]
    ld   LINK_HI, x
    ld   wv_r102 >> 8, [x]
    ld   copy >> 8, y
    jmp  copy
wv_r102:
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

#addr 0x1700
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

; time - the time row: "m:ss of m:ss", and "paused" while it is; the pause
; button's word
time:
    clr  ac
    ld   ac, [wv_draw]
    ld   LINK_LO, x             ; CALL p_hide
    ld   wv_r103, [x]
    ld   LINK_HI, x
    ld   wv_r103 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
wv_r103:
    ld   ROW_TIME, ac
    ld   ac, [CUR_ROW]
    ld   CARD_L + 2, ac
    ld   ac, [CUR_COL]
    ld   [wv_min], ac
    ld   LINK_LO, x             ; CALL numi
    ld   wv_r104, [x]
    ld   LINK_HI, x
    ld   wv_r104 >> 8, [x]
    ld   numi >> 8, y
    jmp  numi
wv_r104:
    ld   [wv_sec], ac
    ld   LINK_LO, x             ; CALL dec2
    ld   wv_r105, [x]
    ld   LINK_HI, x
    ld   wv_r105 >> 8, [x]
    ld   dec2 >> 8, y
    jmp  dec2
wv_r105:
    ld   s_of & 0xFF, ac
    ld   ac, [R0]
    ld   s_of >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL puti
    ld   wv_r106, [x]
    ld   LINK_HI, x
    ld   wv_r106 >> 8, [x]
    ld   puti >> 8, y
    jmp  puti
wv_r106:
    ld   [wv_tmin], ac
    ld   LINK_LO, x             ; CALL numi
    ld   wv_r107, [x]
    ld   LINK_HI, x
    ld   wv_r107 >> 8, [x]
    ld   numi >> 8, y
    jmp  numi
wv_r107:
    ld   [wv_tsec], ac
    ld   LINK_LO, x             ; CALL dec2
    ld   wv_r108, [x]
    ld   LINK_HI, x
    ld   wv_r108 >> 8, [x]
    ld   dec2 >> 8, y
    jmp  dec2
wv_r108:
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
    ld   LINK_LO, x             ; CALL puti
    ld   wv_r109, [x]
    ld   LINK_HI, x
    ld   wv_r109 >> 8, [x]
    ld   puti >> 8, y
    jmp  puti
wv_r109:
    ld   time2 >> 8, y
    jmp  time2


#addr 0x1800
time2:
    ld   ROW_BTN, ac
    ld   ac, [CUR_ROW]
    ld   BTN_H, ac
    ld   ac, [CUR_COL]
    ld   [wv_hold], ac
    bne  t2_hold
    ld   s_bpause & 0xFF, ac
    ld   ac, [R0]
    ld   s_bpause >> 8, ac
    bra  t2_put
t2_hold:
    ld   s_bplay & 0xFF, ac
    ld   ac, [R0]
    ld   s_bplay >> 8, ac
t2_put:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wv_r110, [x]
    ld   LINK_HI, x
    ld   wv_r110 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wv_r110:
    ld   LINK_LO, x             ; CALL p_show
    ld   wv_r111, [x]
    ld   LINK_HI, x
    ld   wv_r111 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
wv_r111:
    ld   loop >> 8, y
    jmp  loop
; dec2 - ":" and AC (0-99) as two digits
finish:
    ld   [wv_new], ac
    bne  fn_quiet
fn_room:
    ld   LINK_LO, x             ; room for a piece of silence after the
    ld   wv_r114, [x]
    ld   LINK_HI, x
    ld   wv_r114 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r114:
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
    ld   wv_r115, [x]
    ld   LINK_HI, x
    ld   wv_r115 >> 8, [x]
    ld   copy >> 8, y
    jmp  copy
wv_r115:
fn_wait:
    ld   LINK_LO, x             ; until the video is in that silence
    ld   wv_r116, [x]
    ld   LINK_HI, x
    ld   wv_r116 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
wv_r116:
    sub  124, ac
    sub  [wv_wg], ac
    bcc  fn_d
    add  132, ac
fn_d:
    sub  100, ac
    bcs  fn_wait
fn_quiet:
    ld   LINK_LO, x             ; CALL quiet
    ld   wv_r117, [x]
    ld   LINK_HI, x
    ld   wv_r117 >> 8, [x]
    ld   quiet >> 8, y
    jmp  quiet
wv_r117:
    ld   after >> 8, y
    jmp  after

after:
    ld   [wv_n], ac
    inc
    ld   ac, [wv_n]
    xor  [wv_tot], ac
    beq  af_last
    ld   show >> 8, y
    jmp  show
af_last:
    ld   LIB_FONT >> 8, ac
    ld   ac, [FONT_PG]
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
    ld   FONT >> 8, ac
    ld   ac, [FONT_PG]
    clr  ac                     ; no DOS to go back to: from the first again
    ld   ac, [wv_n]
    ld   show >> 8, y
    jmp  show

; badwav - not a file the program plays: say so for 2.5 s, the next file
fail:
    ld   ROW_INFO, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r122, [x]
    ld   LINK_HI, x
    ld   wv_r122 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r122:
fl_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   wv_r123, [x]
    ld   LINK_HI, x
    ld   wv_r123 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
wv_r123:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   wv_r124, [x]
    ld   LINK_HI, x
    ld   wv_r124 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
wv_r124:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   wv_r125, [x]
    ld   LINK_HI, x
    ld   wv_r125 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
wv_r125:
    bra  fl_loop

; ============================================================
; data
; ============================================================

#addr 0x1900
badwav:
    ld   LINK_LO, x             ; CALL p_hide
    ld   wv_r118, [x]
    ld   LINK_HI, x
    ld   wv_r118 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
wv_r118:
    ld   LINK_LO, x             ; CALL clrinfo
    ld   wv_r119, [x]
    ld   LINK_HI, x
    ld   wv_r119 >> 8, [x]
    ld   clrinfo >> 8, y
    jmp  clrinfo
wv_r119:
    ld   s_not & 0xFF, ac
    ld   ac, [R0]
    ld   s_not >> 8, ac
    ld   ac, [R1]
    ld   ROW_INFO, ac
    ld   LINK_LO, x             ; CALL msg
    ld   wv_r120, [x]
    ld   LINK_HI, x
    ld   wv_r120 >> 8, [x]
    ld   msg >> 8, y
    jmp  msg
wv_r120:
    ld   150, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   wv_r121, [x]
    ld   LINK_HI, x
    ld   wv_r121 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
wv_r121:
    ld   after >> 8, y
    jmp  after
; ------------------------------------------------------------
; fail - the message at R1:R0 on the card, then wait for Esc
; ------------------------------------------------------------
s_title:
    #d " Sound player", 0x00
s_dir:
    #d "SOUNDS", 0x00
s_of:
    #d " of ", 0x00
s_go:
    #d "         ", 0x00
s_hold:
    #d "   paused", 0x00
s_prev:
    #d "  <<  ", 0x00
s_next:
    #d "  >>  ", 0x00
s_bpause:
    #d " Pause  ", 0x00
s_bplay:
    #d "  Play  ", 0x00
s_r31:
    #d "31.5 kHz", 0x00
s_r15:
    #d "15.7 kHz", 0x00
s_r7:
    #d "7.9 kHz", 0x00
s_keys:
    #d "Space: pause   Left, Right: move   Enter: next   Backspace: last   Esc: close", 0x00

#addr 0x1A00
s_nodir:
    #d "There is no SOUNDS folder on the card.  Esc: close", 0x00
s_none:
    #d "There are no .WAV files in this folder.  Esc: close", 0x00
s_bad:
    #d "The card could not be read.  Esc: close", 0x00
s_not:
    #d "Not a WAV file with 8 bits, 1 channel", 0x00
