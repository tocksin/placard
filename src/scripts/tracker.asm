; ============================================================
; made by asm_expand.py from tracker.masm: change that file, then run
;     python3 asm_expand.py tracker.masm
; ============================================================

; ============================================================
; tracker.masm - TRACKER.PLC: the PLACARD music editor (docs/MUSIC.md)
; ============================================================
;
; A library program the DOS runs from the card.  It edits a song for the
; music player (placard_mus.masm) on the machine: the orderlists, the
; patterns of the four voices side by side, the instruments and the wave
; and pulse tables, plays it while editing, and loads and saves .SNG
; files on the card (the same files mus_tool.py makes).  It starts with
; DEMO.SNG when the card has it, else with a blank song.
;
; The screen is 80 x 30 text on 2x lines (VIDEO.md, line repeat): the
; editor and the player are more code than the RAM beside a 1x screen
; holds, and the even video pages that 2x frees hold most of the code and
; the patterns.
;
;
;   row 0        the header: file, title, octave, instrument, mode, state
;   rows 2-10    left: the orderlists (8 positions, the > marks the one
;                shown below); right: the instrument and its fields
;   row 12-13    the pattern's title and the voice columns
;   rows 14-     the four voices' patterns at the order position, a row
;                per line: note, instrument, effect (or the wave or
;                pulse table when that pane is shown)
;   rows -2, -1  the status line and the keys
;
; Tints: the header and the keys gold, the active pane's cursor row blue,
; the row being played green (cyan when the cursor follows it).
;
; Memory.  TRACKER.PLC loads at x0100-x3DFF (code to x33FF, then the
; player's tables); the rest of the code is TRACKER.OVL, which main reads
; into the even pages xA8, xAA ... xFE (gen_plc.py --overlay).  Every
; pattern has a 256-byte slot of its own: the 40 slots are the even pages
; x60 ... xA6 and the RAM pages x57, x58, x59, x5C.  The song's header
; pages (title, tables, instruments, custom waves) are at x4800-x4CFF and
; the orderlists at x5600 (64 bytes a voice); the player reads the
; patterns where they are through the offsets in page 0, which this
; program keeps.  The decoded form of the orderlists is in the player's
; own state pages (x4310-x436D and the same in the next three pages); a
; pattern being edited is decoded into x5400 (64 rows x 4 bytes);
; x5400-x55FF is the file buffer while loading and saving.
;
; The map.  The CPU reads the ROM above x6000 under the map a library
; program runs with (07), so this program sets the map to FF (every
; section RAM) and goes back to 07 only inside the l_* stubs below, which
; wrap each library and DOS routine it calls, and in tputc while it reads
; the font.  LEAVE goes to tr_leave, a copy of lib_leave in the RAM.  The
; stubs, tr_leave, tputc, ovl_load and exit_dos must therefore sit below
; x3400 (they do: they come first in the file).
;
; Keys (no function keys on the 63-key layout; Ctrl-Q/R/S/T are the
; arrows, so the file keys are Ctrl-O, Ctrl-W, Ctrl-N, Ctrl-E, Ctrl-X):
;
;   Z-M , L .      notes, the lower octave      Q-I 9 O 0 P  the upper
;   1              key off (note column)        - =          octave
;   < >            the instrument for new notes
;   Tab            next pane: pattern, order, instrument, wave, pulse
;   arrows         move                         Del, Backspace  clear
;   0-9 A-F        a hex digit into the field under the cursor
;   [ ]            order pane: transpose; instrument and table panes: -1 +1
;   I / L / S      order pane: insert a position / loop here / stop here
;   Enter          play the song from the start
;   Space          play from the order position shown (stop when playing)
;   Esc            stop
;   Ctrl-L         pattern length 64 > 16 > 32 > 64
;   Ctrl-O / W     load / save a .SNG (the name is asked on the status row)
;   Ctrl-N         a blank song
;   Ctrl-X         back to the DOS (twice when the song is not saved)
;
;     python3 asm_expand.py tracker.masm              tracker.asm
;     python3 gen_plc.py tracker.asm -o ../../sdcard/TRACKER.PLC --overlay 0xA800,2
;                                                     (and TRACKER.OVL)
;     python3 test_tracker.py                         runs it in placard_sim
;
; Date: 11/01/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

MUS_TABLES = 0x3400         ; the player's tables, 10 pages (in the file)
MUS_RAM    = 0x3E00         ; the player's RAM, 10 pages
VSPAGE     = (MUS_RAM >> 8) + 5   ; voice state pages (voice v at VSPAGE + v)
SONG       = 0x4800         ; the song's header pages 0-4
OLIST      = 0x5600         ; the encoded orderlists, voice v at v x 64
EMPTY_LO   = 0x07           ; SONG + 7 holds FF: the pattern of unused slots
OLH        = (OLIST - SONG) >> 8   ; the orderlists' offset, high byte
OVL_PAGE   = 0xA8           ; the overlay's first page (every 2nd page from there)
CAP        = 40             ; pattern slots
CAP_VID    = 36             ; of them in the video pages x60 + 2n; the rest in ramsl
SLOT_LO    = 0              ; a slot's low byte (256-byte slots)
ROWS       = 30             ; text rows
PV         = 14             ; pattern rows shown
SCRATCH    = 0x5400         ; the decoded pattern: 64 rows x 4 bytes
ENCBUF     = 0x5500         ; a pattern being encoded
FBUF       = 0x5400         ; 512-byte file buffer (both pages) while loading, saving
PTAB_PG    = 0x5D           ; slot table: x5D00 + n = page, x5D40 + n = low byte
PTAB_HI    = 0x00
PTAB_LO    = 0x40
FS_REM_LO  = 0x4D28         ; the FAT reader's bytes left (placard_fs.asm V_REM)
FS_REM_HI  = 0x4D29
dos_back   = 0x8008
fs_create  = 0x8010         ; the DOS's FAT writer (docs/DOS.md)
fs_write   = 0x8014
fs_close   = 0x8018

; decoded orderlists, in the voice state pages (below the player's x76)
OD_PAT  = 0x10              ; + 2k: pattern of position k (k < 30)
OD_TR   = 0x11              ; + 2k: its transpose (signed)
OD_LEN  = 0x4C              ; positions
OD_END  = 0x4D              ; FE stop, FF loop
OD_TGT  = 0x4E              ; the loop's position
OD_OFF  = 0x50              ; + k: byte offset of position k in the encoded list (k <= len)
OD_MAX  = 30

; the decoded pattern: SCRATCH + 4 x row
D_NOTE = 0                  ; 00-5F, 60 key off, 61 none
D_INS  = 1                  ; FF none
D_FX   = 2                  ; FF none
D_PAR  = 3

; instrument bytes
I_AD = 0
I_SR = 1
I_WAVE = 2
I_PULSE = 3
I_PW = 4
I_FLAGS = 5
I_VDLY = 6
I_VIB = 7
I_VOL = 8
I_NAME = 9

; screen
ROW_HDR  = 0
ROW_ORD  = 3                ; first of 8 orderlist rows (titles on row 2)
ROW_INS  = 2                ; instrument panel rows 2-8
COL_INS  = 40
ROW_PTIT = 12
ROW_GRID = 14               ; first pattern row
COL_GRID = 6                ; voice 0's cell; a voice is 12 columns
ORD_ROWS = 8

TINT_GOLD  = 0x30
TINT_BLUE  = 0x40
TINT_GREEN = 0x20

; zero page x20-x5F
e_res   = 0x20              ; load_cmd: load_song's result across the redraw
e_pane  = 0x23              ; 0 pattern, 1 order, 2 instrument, 3 wave, 4 pulse
e_oct   = 0x26
e_ins   = 0x27
e_op    = 0x28              ; order position shown
e_otop  = 0x29              ; first order position on the screen
c_v     = 0x2A              ; pattern cursor: voice
c_row   = 0x2B              ;   row
c_col   = 0x2C              ;   column 0 note, 1-2 instrument, 3 effect, 4-5 parameter
c_top   = 0x2D              ; first pattern row on the screen
o_v     = 0x2E              ; order cursor: voice
o_k     = 0x2F              ;   position
o_f     = 0x30              ;   0 pattern, 1 transpose
i_f     = 0x31              ; instrument field 0-11
t_e     = 0x32              ; table entry 1-63
t_f     = 0x33              ; table side 0 left, 1 right
e_play  = 0x34
e_dirty = 0x35              ; 01 grid, 02 order, 04 instrument, 08 header, 10 table, 20 title
e_drow  = 0x36              ; grid draw: next voice column
p_len   = 0x37              ; rows of the decoded pattern
p_pat   = 0x38              ; which pattern SCRATCH holds (FF none)
e_plop  = 0x39              ; the position voice 1 plays (FF none)
e_plrow = 0x3A              ; the row it plays
s_col   = 0x3B              ; status: the column after its string (prompt)
e_mod   = 0x3C              ; the song changed since it was saved
e_key   = 0x3D
e_name  = 0x3E              ; x3E-x4A: the file name and a 00
p_ch    = 0x4B              ; text output
p_k     = 0x4C
p_pg    = 0x4D
p_off   = 0x4E
p_st    = 0x4F
u0 = 0x50                   ; scratch, the lower routines
u1 = 0x51
u2 = 0x52
u3 = 0x53
u4 = 0x54
u5 = 0x55
u6 = 0x56
u7 = 0x57
w0 = 0x58                   ; scratch, the higher routines
w1 = 0x59
w2 = 0x5A
w3 = 0x5B
w4 = 0x5C
w5 = 0x5D
i_np    = 0x5E              ; the name character being typed
e_fl    = 0x5F              ; bit 0: Ctrl-X pressed once

; MAP07 / MAPFF - the map register (x5000): the library's map, all RAM


; ============================================================
; main
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   0x07, ac
    ld   ac, [MAP_SHADOW]
    ld   LINK_LO, x             ; CALL l_fs_mount
    ld   tr_r1, [x]
    ld   LINK_HI, x
    ld   tr_r1 >> 8, [x]
    ld   l_fs_mount >> 8, y
    jmp  l_fs_mount
tr_r1:
    ld   LINK_LO, x             ; CALL ovl_load
    ld   tr_r2, [x]
    ld   LINK_HI, x
    ld   tr_r2 >> 8, [x]
    ld   ovl_load >> 8, y
    jmp  ovl_load
tr_r2:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    clr  ac
    ld   ac, [e_pane]
    ld   ac, [e_ins]
    ld   ac, [e_op]
    ld   ac, [e_otop]
    ld   ac, [c_v]
    ld   ac, [c_row]
    ld   ac, [c_col]
    ld   ac, [c_top]
    ld   ac, [o_v]
    ld   ac, [o_k]
    ld   ac, [o_f]
    ld   ac, [i_f]
    ld   ac, [t_f]
    ld   ac, [e_play]
    ld   ac, [e_mod]
    ld   ac, [e_fl]
    ld   ac, [i_np]
    ld   1, ac
    ld   ac, [t_e]
    ld   4, ac
    ld   ac, [e_oct]
    ld   0xFF, ac
    ld   ac, [p_pat]
    ld   ac, [e_plop]
    ld   ac, [e_plrow]
    ld   LINK_LO, x             ; CALL set_slots
    ld   tr_r3, [x]
    ld   LINK_HI, x
    ld   tr_r3 >> 8, [x]
    ld   set_slots >> 8, y
    jmp  set_slots
tr_r3:
    ld   LINK_LO, x             ; CALL clear_screen
    ld   tr_r4, [x]
    ld   LINK_HI, x
    ld   tr_r4 >> 8, [x]
    ld   clear_screen >> 8, y
    jmp  clear_screen
tr_r4:
    ld   LINK_LO, x             ; CALL new_song
    ld   tr_r5, [x]
    ld   LINK_HI, x
    ld   tr_r5 >> 8, [x]
    ld   new_song >> 8, y
    jmp  new_song
tr_r5:
    ld   s_demo & 0xFF, ac      ; DEMO.SNG when the card has it
    ld   ac, [R0]
    ld   s_demo >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL copy_name
    ld   tr_r6, [x]
    ld   LINK_HI, x
    ld   tr_r6 >> 8, [x]
    ld   copy_name >> 8, y
    jmp  copy_name
tr_r6:
    ld   LINK_LO, x             ; CALL load_song
    ld   tr_r7, [x]
    ld   LINK_HI, x
    ld   tr_r7 >> 8, [x]
    ld   load_song >> 8, y
    jmp  load_song
tr_r7:
    ld   LINK_LO, x             ; CALL redraw_all
    ld   tr_r8, [x]
    ld   LINK_HI, x
    ld   tr_r8 >> 8, [x]
    ld   redraw_all >> 8, y
    jmp  redraw_all
tr_r8:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the frame loop
; ============================================================
s_ovl:
    #d "TRACKER.OVL", 0x00
s_demo:
    #d "DEMO.SNG", 0x00

; ------------------------------------------------------------
; tr_leave - the library's lib_leave (LEAVE) copied into the RAM: the
; ROM is mapped out while this program runs
; ------------------------------------------------------------
tr_leave:
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

; ------------------------------------------------------------
; l_* - the library and DOS routines, called under the library's map
; (see the header); exit_dos - back to the DOS under its map
; ------------------------------------------------------------
exit_dos:
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   dos_back >> 8, y
    jmp  dos_back

; ------------------------------------------------------------
; ovl_load - TRACKER.OVL (the code gen_plc.py put in the overlay) into
; the even pages from OVL_PAGE: a sector holds two of them
; ------------------------------------------------------------
tat:
    ld   [R2], ac
    ld   ac, [CUR_ROW]
    ld   [R3], ac
    ld   ac, [CUR_COL]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tclr - AC spaces from the cursor; cursor back where it was
slot_addr:
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; pat_of - AC = voice: AC = its pattern at e_op, FF when the orderlist
; is shorter
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames
    ld   tr_r9, [x]
    ld   LINK_HI, x
    ld   tr_r9 >> 8, [x]
    ld   l_wait_frames >> 8, y
    jmp  l_wait_frames
tr_r9:
    ld   LINK_LO, x             ; CALL mus_frame
    ld   tr_r10, [x]
    ld   LINK_HI, x
    ld   tr_r10 >> 8, [x]
    ld   mus_frame >> 8, y
    jmp  mus_frame
tr_r10:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   tr_r11, [x]
    ld   LINK_HI, x
    ld   tr_r11 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
tr_r11:
    ld   LINK_LO, x             ; CALL follow
    ld   tr_r12, [x]
    ld   LINK_HI, x
    ld   tr_r12 >> 8, [x]
    ld   follow >> 8, y
    jmp  follow
tr_r12:
    ld   LINK_LO, x             ; CALL l_kbd_getc
    ld   tr_r13, [x]
    ld   LINK_HI, x
    ld   tr_r13 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
tr_r13:
    beq  lp_draw
    ld   ac, [e_key]
    ld   LINK_LO, x             ; CALL handle_key
    ld   tr_r14, [x]
    ld   LINK_HI, x
    ld   tr_r14 >> 8, [x]
    ld   handle_key >> 8, y
    jmp  handle_key
tr_r14:
lp_draw:
    ld   LINK_LO, x             ; CALL draw_step
    ld   tr_r15, [x]
    ld   LINK_HI, x
    ld   tr_r15 >> 8, [x]
    ld   draw_step >> 8, y
    jmp  draw_step
tr_r15:
    ld   loop >> 8, y
    jmp  loop

; the file names the library reads (it runs under map 07, so they must be
; below x6000, not in the overlay)
l_wait_frames:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL wait_frames
    ld   tr_r16, [x]
    ld   LINK_HI, x
    ld   tr_r16 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
tr_r16:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_kbd_scan:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   tr_r17, [x]
    ld   LINK_HI, x
    ld   tr_r17 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
tr_r17:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_kbd_getc:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   tr_r18, [x]
    ld   LINK_HI, x
    ld   tr_r18 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
tr_r18:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

need:
    xor  [p_pat], ac
    beq  nd_ok
    xor  [p_pat], ac
    ld   decode_pat >> 8, y
    jmp  decode_pat
nd_ok:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; encode_pat - SCRATCH (p_len rows) -> ENCBUF, then pattern p_pat's slot
; (the rest of the slot FF).  AC = 0 done, 1 too long for the slot (the
; slot is left as it was)
; ------------------------------------------------------------

en_fail:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ENCBUF (u1 bytes, 256 when u1 = 0) -> the slot, FF to its end

#addr 0x0300
l_fs_mount:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL fs_mount
    ld   tr_r19, [x]
    ld   LINK_HI, x
    ld   tr_r19 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
tr_r19:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_fs_open:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL fs_open
    ld   tr_r20, [x]
    ld   LINK_HI, x
    ld   tr_r20 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
tr_r20:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_fs_read:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL fs_read
    ld   tr_r21, [x]
    ld   LINK_HI, x
    ld   tr_r21 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
tr_r21:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_fs_create:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL fs_create
    ld   tr_r22, [x]
    ld   LINK_HI, x
    ld   tr_r22 >> 8, [x]
    ld   fs_create >> 8, y
    jmp  fs_create
tr_r22:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_fs_write:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL fs_write
    ld   tr_r23, [x]
    ld   LINK_HI, x
    ld   tr_r23 >> 8, [x]
    ld   fs_write >> 8, y
    jmp  fs_write
tr_r23:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

ord_end:
    ld   ac, [u0]
    ld   [o_v], ac
    add  VSPAGE, y
    ld   OD_END, x
    ld   [u0], ac
    ld   ac, [y,x]
    ld   OD_TGT, x
    ld   0, [y,x]
    ld   ord_changed >> 8, y
    jmp  ord_changed

; ord_insert - a position (pattern 00) at the cursor

#addr 0x0400
l_fs_close:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL fs_close
    ld   tr_r24, [x]
    ld   LINK_HI, x
    ld   tr_r24 >> 8, [x]
    ld   fs_close >> 8, y
    jmp  fs_close
tr_r24:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_vid_mode:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL vid_mode
    ld   tr_r25, [x]
    ld   LINK_HI, x
    ld   tr_r25 >> 8, [x]
    ld   vid_mode >> 8, y
    jmp  vid_mode
tr_r25:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

l_vid_clear:
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
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL vid_clear
    ld   tr_r26, [x]
    ld   LINK_HI, x
    ld   tr_r26 >> 8, [x]
    ld   vid_clear >> 8, y
    jmp  vid_clear
tr_r26:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave

set_slots:
    clr  ac
    ld   ac, [u0]
sls_l:
    ld   [u0], ac
    sub  CAP_VID, ac
    bcc  sls_r
    ld   [u0], ac
    shl
    add  0x60, ac
    bra  sls_p
sls_r:
    add  ramsl & 0xFF, x
    ld   ramsl >> 8, y
    ld   [y,x], ac
sls_p:
    ld   ac, [u1]
    ld   PTAB_PG, y
    ld   [u0], ac
    add  PTAB_HI, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   SLOT_LO, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  CAP, ac
    bne  sls_l
    ld   set_offsets >> 8, y
    jmp  set_offsets

; the song's page 0: pattern n's offset = slot n - SONG (the empty pattern
; at SONG + 7 for n past the capacity); the orderlist offsets x500 + 64v;
; one subtune; byte 7 = FF (the empty pattern)
tputs:
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
ts_l:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    beq  ts_e
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r29, [x]
    ld   LINK_HI, x
    ld   tr_r29 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r29:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  ts_l
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  ts_l
ts_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; tspc - AC spaces

#addr 0x0500
ovl_load:
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
    ld   s_ovl & 0xFF, ac
    ld   ac, [R0]
    ld   s_ovl >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_fs_open
    ld   tr_r27, [x]
    ld   LINK_HI, x
    ld   tr_r27 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
tr_r27:
    bne  ov_e
    ld   OVL_PAGE, ac
    ld   ac, [u5]
ov_s:
    ld   FBUF & 0xFF, ac
    ld   ac, [R4]
    ld   FBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_read
    ld   tr_r28, [x]
    ld   LINK_HI, x
    ld   tr_r28 >> 8, [x]
    ld   l_fs_read >> 8, y
    jmp  l_fs_read
tr_r28:
    bne  ov_e
    ld   FBUF >> 8, ac
    ld   ac, [u6]
    ld   2, ac
    ld   ac, [u7]
ov_p:
    clr  ac
    ld   ac, [u4]
ov_b:
    ld   [u6], y
    ld   [u4], x
    ld   [y,x], ac
    ld   [u5], y
    ld   ac, [y,x]
    ld   [u4], ac
    inc
    ld   ac, [u4]
    bne  ov_b
    ld   [u6], ac
    inc
    ld   ac, [u6]
    ld   [u5], ac
    add  2, ac
    ld   ac, [u5]
    beq  ov_e
    ld   [u7], ac
    dec
    ld   ac, [u7]
    bne  ov_p
    bra  ov_s
ov_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; set_slots - the slot table: slot n is the even video page x60 + 2n
; (n < CAP_VID), then the RAM pages in ramsl; low byte 0.  Then the
; song's offsets
; ------------------------------------------------------------
set_offsets:
    clr  ac
    ld   ac, [u0]
so_l:
    ld   [u0], ac
    sub  CAP, ac
    bcc  so_e
    ld   PTAB_PG, y
    ld   [u0], ac
    add  PTAB_HI, x
    ld   [y,x], ac
    sub  SONG >> 8, ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    bra  so_w
so_e:
    clr  ac
    ld   ac, [u1]
    ld   EMPTY_LO, ac
    ld   ac, [u2]
so_w:
    ld   SONG >> 8, y
    ld   [u0], ac
    add  0x80, x
    ld   [u2], ac
    ld   ac, [y,x]
    ld   [u0], ac
    add  0xC0, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  64, ac
    bne  so_l
    ld   SONG >> 8, y
    ld   0x04, x
    ld   1, [y,x]
    ld   0x07, x
    ld   0xFF, [y,x]
    ld   0x41, x
    ld   0x00, [y,x]
    ld   0x42, x
    ld   OLH, [y,x]
    ld   0x43, x
    ld   0x40, [y,x]
    ld   0x44, x
    ld   OLH, [y,x]
    ld   0x45, x
    ld   0x80, [y,x]
    ld   0x46, x
    ld   OLH, [y,x]
    ld   0x47, x
    ld   0xC0, [y,x]
    ld   0x48, x
    ld   OLH, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; text output.  con_putc only knows the 1x screen, so the editor writes
; its own characters: tputc draws the glyph of AC at CUR_ROW, CUR_COL in
; the 1x or 2x layout (docs/VIDEO.md, "Line repeat") and moves on.
; ============================================================

; the address of the glyph's first byte: p_pg:p_off, p_st = the stride

ins_changed:
    ld   1, ac
    ld   ac, [e_mod]
    ld   [e_dirty], ac
    or   0x04, ac
    ld   ac, [e_dirty]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; key_tab - the wave and pulse table panes
; ------------------------------------------------------------

#addr 0x0600
tputc:
    ld   ac, [p_ch]
    ld   [CUR_COL], ac
    sub  80, ac
    bcc  tp_off                 ; past the right edge: nothing
    ld   [CUR_COL], ac
    shl
    add  0x61, ac
    ld   ac, [p_pg]
    ld   2, ac
    ld   ac, [p_st]
    ld   [CUR_ROW], ac
    sub  14, ac
    blt  ta_2a25
    shl                         ; rows 14-29: 16 (r - 14) + 1
    shl
    shl
    shl
    inc
    ld   ac, [p_off]
    bra  ta_go25
ta_2a25:
    add  16, ac                 ; rows 0-13: 16 r + 32
    shl
    shl
    shl
    shl
    ld   ac, [p_off]
ta_go25:
    ld   0x50, y
    clr  x
    ld   0x07, [y,x]
    clr  ac
    ld   ac, [p_k]
tp_l:
    ld   [p_k], ac
    add  LIB_FONT >> 8, y
    ld   [p_ch], x
    ld   [y,x], ac
    ld   [p_pg], y
    ld   [p_off], x
    ld   ac, [y,x]
    ld   [p_off], ac
    add  [p_st], ac
    ld   ac, [p_off]
    ld   [p_k], ac
    inc
    ld   ac, [p_k]
    xor  8, ac
    bne  tp_l
    ld   [CUR_COL], ac
    inc
    ld   ac, [CUR_COL]
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
tp_off:
    ld   [p_ch], ac             ; AC kept (callers print a character twice)
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tmark - underline AC characters from the cursor (the glyph's last line)
tmark:
    ld   ac, [p_k]
tm_l:
    ld   [CUR_COL], ac
    sub  80, ac
    bcc  tm_off
    ld   [CUR_COL], ac
    shl
    add  0x61, ac
    ld   ac, [p_pg]
    ld   2, ac
    ld   ac, [p_st]
    ld   [CUR_ROW], ac
    sub  14, ac
    blt  ta_2a28
    shl                         ; rows 14-29: 16 (r - 14) + 1
    shl
    shl
    shl
    inc
    ld   ac, [p_off]
    bra  ta_go28
ta_2a28:
    add  16, ac                 ; rows 0-13: 16 r + 32
    shl
    shl
    shl
    shl
    ld   ac, [p_off]
ta_go28:
    ld   [p_st], ac             ; + 7 x stride
    shl
    shl
    shl
    sub  [p_st], ac
    add  [p_off], ac
    ld   ac, x
    ld   [p_pg], y
    ld   0xFF, [y,x]
    ld   [CUR_COL], ac
    inc
    ld   ac, [CUR_COL]
    ld   [p_k], ac
    dec
    ld   ac, [p_k]
    bne  tm_l
tm_off:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tputs - the string at R1:R0 (ending in 00)
tspc:
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
    ld   ac, [u7]
    beq  tsp_e
tsp_l:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r30, [x]
    ld   LINK_HI, x
    ld   tr_r30 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r30:
    ld   [u7], ac
    dec
    ld   ac, [u7]
    bne  tsp_l
tsp_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; thex1 - the low nibble of AC as a hex digit
pat_of:
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [e_op], ac
    sub  [y,x], ac
    bcc  po_n
    ld   [e_op], ac
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
po_n:
    ld   0xFF, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; decode_pat - AC = pattern: SCRATCH = its rows (p_len of them, the rest
; empty), p_pat = AC.  A blank slot (FF first) is 64 empty rows.
; ------------------------------------------------------------

#addr 0x0700
thex1:
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
    and  15, ac
    add  hexdig & 0xFF, x
    ld   hexdig >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r31, [x]
    ld   LINK_HI, x
    ld   tr_r31 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r31:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; thex2 - AC as two hex digits
thex2:
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
    ld   ac, [u6]
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r32, [x]
    ld   LINK_HI, x
    ld   tr_r32 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r32:
    ld   [u6], ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r33, [x]
    ld   LINK_HI, x
    ld   tr_r33 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r33:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; tdec2 - AC (0-99) as two decimal digits
tdec2:
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
    ld   ac, [u6]
    clr  ac
    ld   ac, [u5]
td_l:
    ld   [u6], ac
    sub  10, ac
    bcs  td_d
    ld   ac, [u6]
    ld   [u5], ac
    inc
    ld   ac, [u5]
    bra  td_l
td_d:
    ld   [u5], ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r34, [x]
    ld   LINK_HI, x
    ld   tr_r34 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r34:
    ld   [u6], ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r35, [x]
    ld   LINK_HI, x
    ld   tr_r35 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r35:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; tsigned - AC as a signed byte: +nn / -nn (decimal)
tsigned:
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
    ld   ac, [u4]
    blt  tsg_n
    ld   0x2B, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r36, [x]
    ld   LINK_HI, x
    ld   tr_r36 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r36:
    ld   [u4], ac
    bra  tsg_d
tsg_n:
    ld   0x2D, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r37, [x]
    ld   LINK_HI, x
    ld   tr_r37 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r37:
    clr  ac
    sub  [u4], ac
tsg_d:
    ld   LINK_LO, x             ; CALL tdec2
    ld   tr_r38, [x]
    ld   LINK_HI, x
    ld   tr_r38 >> 8, [x]
    ld   tdec2 >> 8, y
    jmp  tdec2
tr_r38:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; tnote - AC = a pattern note: C-4, === (key off), ... (none)

#addr 0x0800
tnote:
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
    ld   ac, [u4]
    sub  0x60, ac
    bcs  tn_n
    beq  tn_off
    ld   s_dots & 0xFF, ac
    ld   ac, [R0]
    ld   s_dots >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r39, [x]
    ld   LINK_HI, x
    ld   tr_r39 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r39:
    ld   tr_leave >> 8, y
    jmp  tr_leave
tn_off:
    ld   s_koff & 0xFF, ac
    ld   ac, [R0]
    ld   s_koff >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r40, [x]
    ld   LINK_HI, x
    ld   tr_r40 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r40:
    ld   tr_leave >> 8, y
    jmp  tr_leave
tn_n:
    ld   tnote_name >> 8, y
    jmp  tnote_name

tnote_name:
    clr  ac                     ; octave = note / 12
    ld   ac, [u5]
tnn_o:
    ld   [u4], ac
    sub  12, ac
    bcs  tnn_d
    ld   ac, [u4]
    ld   [u5], ac
    inc
    ld   ac, [u5]
    bra  tnn_o
tnn_d:
    ld   [u4], ac
    add  [u4], ac
    add  notes & 0xFF, x
    ld   notes >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r41, [x]
    ld   LINK_HI, x
    ld   tr_r41 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r41:
    ld   [u4], ac
    add  [u4], ac
    add  (notes + 1) & 0xFF, x
    ld   notes >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r42, [x]
    ld   LINK_HI, x
    ld   tr_r42 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r42:
    ld   [u5], ac
    add  0x30, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r43, [x]
    ld   LINK_HI, x
    ld   tr_r43 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r43:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; tat - cursor to R2 = row, R3 = column
tclr:
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
    ld   ac, [u3]
    ld   [CUR_COL], ac
    ld   ac, [u2]
    ld   [u3], ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r44, [x]
    ld   LINK_HI, x
    ld   tr_r44 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r44:
    ld   [u2], ac
    ld   ac, [CUR_COL]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; tint_row - AC = text row, R0 = tint bits: the row's 16 mode bytes
; (with the 2x line repeat bit)
; ------------------------------------------------------------
status_clear:
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
    ld   s_empty & 0xFF, ac
    ld   ac, [R0]
    ld   s_empty >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r48, [x]
    ld   LINK_HI, x
    ld   tr_r48 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r48:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ============================================================
; the song: patterns in their slots, the decoded pattern, the orderlists
; ============================================================

; SLOTADDR - AC = pattern: u1 = page, u2 = low byte of its slot

; slot_addr - the same as a routine (for callers that keep their link)
tint_row:
    ld   ac, [u0]
    ld   [u0], ac               ; 2x: lines 16r .. 16r+15
    shl
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [u1]
    ld   0x5A, ac
    ld   ac, [u2]
    ld   [u0], ac
    sub  14, ac
    blt  tr_2a
    ld   0x5B, ac
    ld   ac, [u2]
tr_2a:
    ld   16, ac
    ld   ac, [u3]
    ld   [R0], ac
    or   0x04, ac
tr_go:
    ld   ac, [u4]
    ld   [u2], y
tr_l:
    ld   [u1], x
    ld   [u4], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    ld   [u3], ac
    dec
    ld   ac, [u3]
    bne  tr_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; clear_screen - the pixels in the odd pages (the text; the even pages
; hold patterns and code), the mode bytes: 2x, no tint
; ------------------------------------------------------------
clear_screen:
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
    ld   0x61, ac
    ld   ac, [u0]
csc_p:
    ld   [u0], y
    clr  ac
csc_b:
    ld   ac, x
    ld   0x00, [y,x]
    inc
    bne  csc_b
    ld   [u0], ac
    add  2, ac
    ld   ac, [u0]
    xor  0x01, ac
    bne  csc_p
    ld   0x04, ac
    ld   LINK_LO, x             ; CALL l_vid_mode
    ld   tr_r45, [x]
    ld   LINK_HI, x
    ld   tr_r45 >> 8, [x]
    ld   l_vid_mode >> 8, y
    jmp  l_vid_mode
tr_r45:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; status - the string at R1:R0 on the status row, the rest cleared
; ------------------------------------------------------------
status:
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
    ld   ROWS - 2, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r46, [x]
    ld   LINK_HI, x
    ld   tr_r46 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r46:
    ld   [CUR_COL], ac
    ld   ac, [s_col]
    ld   80, ac
    sub  [CUR_COL], ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r47, [x]
    ld   LINK_HI, x
    ld   tr_r47 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r47:
    ld   tr_leave >> 8, y
    jmp  tr_leave

encode_all:
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
    ld   ac, [w5]
ea_l:
    ld   [w5], ac
    ld   LINK_LO, x             ; CALL encode_ol
    ld   tr_r49, [x]
    ld   LINK_HI, x
    ld   tr_r49 >> 8, [x]
    ld   encode_ol >> 8, y
    jmp  encode_ol
tr_r49:
    ld   [w5], ac
    inc
    ld   ac, [w5]
    xor  4, ac
    bne  ea_l
    ld   tr_leave >> 8, y
    jmp  tr_leave

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

#addr 0x0A00
decode_pat:
    ld   ac, [p_pat]
    ld   SCRATCH >> 8, y
    clr  ac
    ld   ac, [u0]
dp_c:
    ld   [u0], ac
    ld   ac, x
    ld   0x61, [y,x]
    inc
    ld   ac, x
    ld   0xFF, [y,x]
    inc
    ld   ac, x
    ld   0xFF, [y,x]
    inc
    ld   ac, x
    ld   0x00, [y,x]
    inc
    ld   ac, [u0]
    bne  dp_c
    ld   ac, [p_len]
    ld   [p_pat], ac
    sub  CAP, ac
    bcc  dp_none                ; none, or past the capacity
    ld   [p_pat], ac
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u1], y
    ld   [u2], x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  dp_go
    ld   64, ac                 ; blank: 64 empty rows
    ld   ac, [p_len]
dp_none:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
dp_go:
    ld   dp_parse >> 8, y
    jmp  dp_parse

dp_parse:
    clr  ac
    ld   ac, [u4]               ; rows so far
    ld   0xFF, ac
    ld   ac, [u5]               ; pending instrument
    ld   ac, [u6]               ; pending effect
    clr  ac
    ld   ac, [u7]
dpp_l:
    ld   [u4], ac
    xor  64, ac
    beq  dpp_end
    ld   [u1], y
    ld   [u2], x
    ld   [y,x], ac
    ld   ac, [u3]
    ld   [u2], ac
    inc
    ld   ac, [u2]
    ld   [u3], ac
    xor  0xFF, ac
    beq  dpp_end
    ld   [u3], ac
    sub  0xE0, ac
    bcc  dpp_fx
    ld   [u3], ac
    sub  0xC0, ac
    bcc  dpp_ins
    ld   [u3], ac
    sub  0x80, ac
    bcc  dpp_empty
    ld   [u4], ac               ; a note: row u4 = note, pending ins, fx, par
    shl
    shl
    ld   ac, [u0]
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [u3], ac
    ld   ac, [y,x]
    ld   [u0], ac
    add  1, x
    ld   [u5], ac
    ld   ac, [y,x]
    ld   [u0], ac
    add  2, x
    ld   [u6], ac
    ld   ac, [y,x]
    ld   [u0], ac
    add  3, x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   0xFF, ac
    ld   ac, [u5]
    ld   ac, [u6]
    ld   [u4], ac
    inc
    ld   ac, [u4]
    bra  dpp_l
dpp_fx:
    and  0x0F, ac
    ld   ac, [u6]
    ld   [u1], y
    ld   [u2], x
    ld   [y,x], ac
    ld   ac, [u7]
    ld   [u2], ac
    inc
    ld   ac, [u2]
    bra  dpp_l
dpp_ins:
    and  0x1F, ac
    ld   ac, [u5]
    bra  dpp_l
dpp_empty:
    and  0x3F, ac               ; this row and that many more
    inc
    add  [u4], ac
    ld   ac, [u4]
    sub  65, ac
    bcs  dpp_e2
    ld   64, ac
    ld   ac, [u4]
dpp_e2:
    ld   0xFF, ac
    ld   ac, [u5]
    ld   ac, [u6]
    bra  dpp_l
dpp_end:
    ld   [u4], ac
    ld   ac, [p_len]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; need - AC = pattern: decoded into SCRATCH unless it is there already
; ------------------------------------------------------------
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

#addr 0x0B00
encode_pat:
    clr  ac
    ld   ac, [u0]               ; row
    ld   ac, [u1]               ; bytes out
    ld   ac, [u5]               ; full
    ld   0xFF, ac
    ld   ac, [u2]               ; the instrument emitted last
en_l:
    ld   [u0], ac
    xor  [p_len], ac
    beq  en_end
    ld   [u0], ac
    shl
    shl
    ld   ac, [u3]
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    ld   ac, [u4]               ; note
    xor  0x61, ac
    bne  en_row
    ld   [u3], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  en_row
    ld   [u3], ac
    add  2, ac
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  en_row
    ld   en_run >> 8, y
    jmp  en_run
en_row:
    ld   en_note >> 8, y
    jmp  en_note
en_end:
    ld   0xFF, ac
    ld   ac, [u7]
    ld   [u5], ac               ; EMIT: the byte in u7 -> ENCBUF
    bne  en_full31
    ld   ENCBUF >> 8, y
    ld   [u1], x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  SLOT_LO, ac
    bne  en_ok31
    ld   1, ac
    ld   ac, [u5]
en_ok31:
    bra  en_done31
en_full31:
    ld   en_fail >> 8, y
    jmp  en_fail
en_done31:
    ld   en_copy >> 8, y
    jmp  en_copy

; a run of empty rows from row u0: count them (64 at most), one byte
en_run:
    clr  ac
    ld   ac, [u6]               ; the count
er_l:
    ld   [u0], ac
    add  [u6], ac
    xor  [p_len], ac
    beq  er_d
    ld   [u0], ac
    add  [u6], ac
    shl
    shl
    ld   ac, [u3]
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    xor  0x61, ac
    bne  er_d
    ld   [u3], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  er_d
    ld   [u3], ac
    add  2, ac
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  er_d
    ld   [u6], ac
    inc
    ld   ac, [u6]
    xor  64, ac
    bne  er_l
er_d:
    ld   [u6], ac
    dec
    or   0x80, ac
    ld   ac, [u7]
    ld   [u5], ac               ; EMIT: the byte in u7 -> ENCBUF
    bne  en_full32
    ld   ENCBUF >> 8, y
    ld   [u1], x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  SLOT_LO, ac
    bne  en_ok32
    ld   1, ac
    ld   ac, [u5]
en_ok32:
    bra  en_done32
en_full32:
    ld   en_fail >> 8, y
    jmp  en_fail
en_done32:
    ld   [u0], ac
    add  [u6], ac
    ld   ac, [u0]
    ld   en_l >> 8, y
    jmp  en_l

; a row with something in it: [instrument] [effect, parameter] note
slot_len:
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    clr  ac
    ld   ac, [u3]
sl_l:
    ld   [u1], y
    ld   [u3], ac
    add  [u2], ac
    ld   ac, x
    ld   [u3], ac
    inc
    ld   ac, [u3]
    ld   [y,x], ac
    xor  0xFF, ac
    beq  sl_e
    ld   [u3], ac
    xor  SLOT_LO, ac
    bne  sl_l
sl_e:
    ld   [u3], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; slot_fix - AC = pattern: an FF at the slot's last byte when it has none
; ------------------------------------------------------------

#addr 0x0C00
en_note:
    ld   [u3], ac
    inc
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    ld   ac, [u6]               ; its instrument
    xor  0xFF, ac
    beq  en_fx
    ld   [u6], ac
    xor  [u2], ac
    beq  en_fx
    ld   [u6], ac
    ld   ac, [u2]
    or   0xC0, ac
    ld   ac, [u7]
    ld   [u5], ac               ; EMIT: the byte in u7 -> ENCBUF
    bne  en_full33
    ld   ENCBUF >> 8, y
    ld   [u1], x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  SLOT_LO, ac
    bne  en_ok33
    ld   1, ac
    ld   ac, [u5]
en_ok33:
    bra  en_done33
en_full33:
    ld   en_fail >> 8, y
    jmp  en_fail
en_done33:
en_fx:
    ld   [u3], ac
    add  2, ac
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    xor  0xFF, ac
    beq  en_n
    ld   [y,x], ac
    or   0xE0, ac
    ld   ac, [u7]
    ld   [u5], ac               ; EMIT: the byte in u7 -> ENCBUF
    bne  en_full34
    ld   ENCBUF >> 8, y
    ld   [u1], x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  SLOT_LO, ac
    bne  en_ok34
    ld   1, ac
    ld   ac, [u5]
en_ok34:
    bra  en_done34
en_full34:
    ld   en_fail >> 8, y
    jmp  en_fail
en_done34:
    ld   [u3], ac
    add  3, ac
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    ld   ac, [u7]
    ld   [u5], ac               ; EMIT: the byte in u7 -> ENCBUF
    bne  en_full35
    ld   ENCBUF >> 8, y
    ld   [u1], x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  SLOT_LO, ac
    bne  en_ok35
    ld   1, ac
    ld   ac, [u5]
en_ok35:
    bra  en_done35
en_full35:
    ld   en_fail >> 8, y
    jmp  en_fail
en_done35:
en_n:
    ld   [u3], ac
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    ld   ac, [u7]
    ld   [u5], ac               ; EMIT: the byte in u7 -> ENCBUF
    bne  en_full36
    ld   ENCBUF >> 8, y
    ld   [u1], x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  SLOT_LO, ac
    bne  en_ok36
    ld   1, ac
    ld   ac, [u5]
en_ok36:
    bra  en_done36
en_full36:
    ld   en_fail >> 8, y
    jmp  en_fail
en_done36:
    ld   [u0], ac
    inc
    ld   ac, [u0]
    ld   en_l >> 8, y
    jmp  en_l

decode_all:
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
    ld   ac, [w5]
da_l:
    ld   [w5], ac
    ld   LINK_LO, x             ; CALL decode_ol
    ld   tr_r50, [x]
    ld   LINK_HI, x
    ld   tr_r50 >> 8, [x]
    ld   decode_ol >> 8, y
    jmp  decode_ol
tr_r50:
    ld   [w5], ac
    inc
    ld   ac, [w5]
    xor  4, ac
    bne  da_l
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; slot_blank - AC = pattern: AC = 1 when its slot is blank (FF, or BF FF:
; 64 empty rows), else 0
; ------------------------------------------------------------

#addr 0x0D00
en_copy:
    ld   [p_pat], ac
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    clr  ac
    ld   ac, [u3]
ec_l:
    ld   ENCBUF >> 8, y
    ld   [u3], x
    ld   [y,x], ac
    ld   ac, [u4]
    ld   [u1], y
    ld   [u3], ac
    add  [u2], ac
    ld   ac, x
    ld   [u4], ac
    ld   ac, [y,x]
    ld   [u3], ac
    inc
    ld   ac, [u3]
    xor  [u1], ac
    bne  ec_l
ec_p:
    ld   [u3], ac
    xor  SLOT_LO, ac
    beq  ec_e
    ld   [u1], y
    ld   [u3], ac
    add  [u2], ac
    ld   ac, x
    ld   0xFF, [y,x]
    ld   [u3], ac
    inc
    ld   ac, [u3]
    bra  ec_p
ec_e:
    ld   1, ac
    ld   ac, [e_mod]
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; encode_ol - AC = voice: its decoded orderlist -> OLIST + 64 v, with
; the byte offset of each position in OD_OFF (every position gets its
; transpose byte, so a loop lands on the right transpose)
; ------------------------------------------------------------
encode_ol:
    ld   ac, [u0]
    shl
    shl
    shl
    shl
    shl
    shl
    ld   ac, [u1]               ; 64 v: the list's first byte
    ld   ac, [u2]               ; the write pointer (low byte)
    clr  ac
    ld   ac, [u3]               ; position k
eo_l:
    ld   [u0], ac
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [u3], ac
    xor  [y,x], ac
    beq  eo_end
    ld   [u2], ac               ; OD_OFF + k = offset
    sub  [u1], ac
    ld   ac, [u4]
    ld   [u3], ac
    add  OD_OFF, x
    ld   [u4], ac
    ld   ac, [y,x]
    ld   [u3], ac
    shl
    add  OD_TR, x
    ld   [y,x], ac
    add  0xA0, ac
    ld   ac, [u5]
    ld   [u3], ac
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    ld   ac, [u6]
    ld   OLIST >> 8, y
    ld   [u2], x
    ld   [u5], ac
    ld   ac, [y,x]
    ld   [u2], ac
    inc
    ld   ac, x
    ld   [u6], ac
    ld   ac, [y,x]
    ld   [u2], ac
    add  2, ac
    ld   ac, [u2]
    ld   [u3], ac
    inc
    ld   ac, [u3]
    bra  eo_l
eo_end:
    ld   [u2], ac               ; OD_OFF + len = the end's offset
    sub  [u1], ac
    ld   ac, [u4]
    ld   [u3], ac
    add  OD_OFF, x
    ld   [u4], ac
    ld   ac, [y,x]
    ld   OD_END, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  eo_stop
    ld   OD_TGT, x              ; FF, the target's offset
    ld   [y,x], ac
    add  OD_OFF, x
    ld   [y,x], ac
    ld   ac, [u5]
    ld   OLIST >> 8, y
    ld   [u2], x
    ld   0xFF, [y,x]
    ld   [u2], ac
    inc
    ld   ac, x
    ld   [u5], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
eo_stop:
    ld   OLIST >> 8, y
    ld   [u2], x
    ld   0xFE, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; decode_ol - AC = voice: OLIST + 64 v -> its decoded orderlist (at most
; OD_MAX positions; a loop lands on the position holding its byte)
; ------------------------------------------------------------
slot_clear:
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u1], y
    ld   [u2], x
    ld   0xFF, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; drawing
; ============================================================

; ------------------------------------------------------------
; draw_step - once a frame: the blocks marked in e_dirty; the pattern
; grid one voice column a frame (the player must run every frame)
; ------------------------------------------------------------

#addr 0x0E00
decode_ol:
    ld   ac, [u0]
    shl
    shl
    shl
    shl
    shl
    shl
    ld   ac, [u1]               ; the list's first byte
    ld   ac, [u2]               ; the read pointer
    clr  ac
    ld   ac, [u3]               ; position k
    ld   ac, [u4]               ; transpose
    ld   ac, [u6]               ; a transpose byte started the position
    ld   [u0], ac
    add  VSPAGE, y
    ld   OD_END, x
    ld   0xFE, [y,x]
    ld   OD_TGT, x
    ld   0x00, [y,x]
do_l:
    ld   OLIST >> 8, y
    ld   [u2], x
    ld   [y,x], ac
    ld   ac, [u5]
    xor  0xFE, ac
    beq  do_end
    ld   [u5], ac
    xor  0xFF, ac
    beq  do_loop
    ld   [u5], ac
    sub  0x80, ac
    bcs  do_pat
    ld   [u5], ac
    sub  0xC0, ac
    bcc  do_pat                 ; C0-FD: taken as a pattern byte (& 3F)
    ld   [u5], ac               ; a transpose
    sub  0xA0, ac
    ld   ac, [u4]
    ld   [u6], ac
    bne  do_t2
    ld   [u2], ac               ; the position starts here
    sub  [u1], ac
    ld   ac, [u7]
    ld   1, ac
    ld   ac, [u6]
do_t2:
    ld   [u2], ac
    inc
    ld   ac, [u2]
    bra  do_l
do_pat:
    ld   [u6], ac
    bne  do_p2
    ld   [u2], ac
    sub  [u1], ac
    ld   ac, [u7]
do_p2:
    ld   [u3], ac
    xor  OD_MAX, ac
    beq  do_end                 ; too many: the rest is dropped
    ld   [u0], ac
    add  VSPAGE, y
    ld   [u3], ac
    add  OD_OFF, x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u3], ac
    shl
    add  OD_PAT, x
    ld   [u5], ac
    and  0x3F, ac
    ld   ac, [y,x]
    ld   [u3], ac
    shl
    add  OD_TR, x
    ld   [u4], ac
    ld   ac, [y,x]
    ld   [u3], ac
    inc
    ld   ac, [u3]
    clr  ac
    ld   ac, [u6]
    ld   [u2], ac
    inc
    ld   ac, [u2]
    bra  do_l
do_loop:
    ld   do_loop2 >> 8, y
    jmp  do_loop2
do_end:
    ld   [u0], ac
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [u3], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; FF nn: the loop; OD_OFF + len = the FF's offset; target = the first
; position whose next position starts after nn
do_loop2:
    ld   [u0], ac
    add  VSPAGE, y
    ld   OD_END, x
    ld   0xFF, [y,x]
    ld   [u3], ac
    add  OD_OFF, x
    ld   [u2], ac
    sub  [u1], ac
    ld   ac, [y,x]
    ld   OLIST >> 8, y
    ld   [u2], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [u5]               ; nn
    ld   [u0], ac
    add  VSPAGE, y
    clr  ac
    ld   ac, [u7]               ; j
dl_l:
    ld   [u7], ac
    xor  [u3], ac
    beq  dl_0                   ; past the end: 0
    ld   [u7], ac
    add  OD_OFF + 1, x
    ld   [y,x], ac              ; start of j + 1
    sub  [u5], ac
    bcs  dl_n                   ; start(j+1) <= nn: not this one
    beq  dl_n
    ld   OD_TGT, x
    ld   [u7], ac
    ld   ac, [y,x]
    bra  dl_e
dl_n:
    ld   [u7], ac
    inc
    ld   ac, [u7]
    bra  dl_l
dl_0:
    ld   OD_TGT, x
    ld   0, [y,x]
dl_e:
    ld   OD_LEN, x
    ld   [u3], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; encode_all - the four orderlists
; ------------------------------------------------------------

#addr 0x0F00
slot_blank:
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u1], y
    ld   [u2], x
    ld   [y,x], ac
    xor  0xFF, ac
    beq  sb_y
    ld   [y,x], ac
    xor  0xBF, ac
    bne  sb_n
    ld   [u2], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  sb_n
sb_y:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sb_n:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; slot_len - AC = pattern: AC = the bytes of its pattern up to and with
; the FF (the slot's size when there is no FF)
; ------------------------------------------------------------
slot_fix:
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    clr  ac
    ld   ac, [u3]
sf_l:
    ld   [u1], y
    ld   [u3], ac
    add  [u2], ac
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    beq  sf_e
    ld   [u3], ac
    inc
    ld   ac, [u3]
    xor  SLOT_LO, ac
    bne  sf_l
    ld   [u3], ac               ; none: the last byte
    dec
    add  [u2], ac
    ld   ac, x
    ld   0xFF, [y,x]
sf_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; slot_clear - AC = pattern: its slot = FF (blank)
; ------------------------------------------------------------
draw_step:
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
    ld   [e_dirty], ac
    and  0x08, ac
    beq  ds_t
    ld   LINK_LO, x             ; CALL draw_header
    ld   tr_r51, [x]
    ld   LINK_HI, x
    ld   tr_r51 >> 8, [x]
    ld   draw_header >> 8, y
    jmp  draw_header
tr_r51:
    ld   [e_dirty], ac
    and  0xF7, ac
    ld   ac, [e_dirty]
ds_t:
    ld   [e_dirty], ac
    and  0x20, ac
    beq  ds_o
    ld   LINK_LO, x             ; CALL draw_ptitle
    ld   tr_r52, [x]
    ld   LINK_HI, x
    ld   tr_r52 >> 8, [x]
    ld   draw_ptitle >> 8, y
    jmp  draw_ptitle
tr_r52:
    ld   [e_dirty], ac
    and  0xDF, ac
    ld   ac, [e_dirty]
ds_o:
    ld   [e_dirty], ac
    and  0x02, ac
    beq  ds_i
    ld   LINK_LO, x             ; CALL draw_order
    ld   tr_r53, [x]
    ld   LINK_HI, x
    ld   tr_r53 >> 8, [x]
    ld   draw_order >> 8, y
    jmp  draw_order
tr_r53:
    ld   [e_dirty], ac
    and  0xFD, ac
    ld   ac, [e_dirty]
ds_i:
    ld   [e_dirty], ac
    and  0x04, ac
    beq  ds_g
    ld   LINK_LO, x             ; CALL draw_ins
    ld   tr_r54, [x]
    ld   LINK_HI, x
    ld   tr_r54 >> 8, [x]
    ld   draw_ins >> 8, y
    jmp  draw_ins
tr_r54:
    ld   [e_dirty], ac
    and  0xFB, ac
    ld   ac, [e_dirty]
ds_g:
    ld   draw_step2 >> 8, y
    jmp  draw_step2

view_refresh:
    ld   [e_pane], ac
    sub  3, ac
    bcc  vr_t
    ld   [e_dirty], ac
    or   0x21, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
vr_t:
    ld   [e_dirty], ac
    or   0x30, ac
    ld   ac, [e_dirty]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; hexval - AC = key: AC = 0-15, or FF when it is no hex digit

#addr 0x1000
draw_step2:
    ld   [e_pane], ac
    sub  3, ac
    bcc  ds_tab
    ld   [e_dirty], ac
    and  0x01, ac
    beq  ds_e
    ld   [e_drow], ac
    ld   LINK_LO, x             ; CALL draw_grid_col
    ld   tr_r55, [x]
    ld   LINK_HI, x
    ld   tr_r55 >> 8, [x]
    ld   draw_grid_col >> 8, y
    jmp  draw_grid_col
tr_r55:
    ld   [e_drow], ac
    inc
    ld   ac, [e_drow]
    xor  4, ac
    bne  ds_e
    ld   LINK_LO, x             ; CALL draw_rownums
    ld   tr_r56, [x]
    ld   LINK_HI, x
    ld   tr_r56 >> 8, [x]
    ld   draw_rownums >> 8, y
    jmp  draw_rownums
tr_r56:
    ld   LINK_LO, x             ; CALL grid_tints
    ld   tr_r57, [x]
    ld   LINK_HI, x
    ld   tr_r57 >> 8, [x]
    ld   grid_tints >> 8, y
    jmp  grid_tints
tr_r57:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r58, [x]
    ld   LINK_HI, x
    ld   tr_r58 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r58:
    ld   [e_dirty], ac
    and  0xFE, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   tr_leave >> 8, y
    jmp  tr_leave
ds_tab:
    ld   [e_dirty], ac
    and  0x11, ac
    beq  ds_e
    ld   LINK_LO, x             ; CALL draw_table
    ld   tr_r59, [x]
    ld   LINK_HI, x
    ld   tr_r59 >> 8, [x]
    ld   draw_table >> 8, y
    jmp  draw_table
tr_r59:
    ld   [e_dirty], ac
    and  0xEE, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
ds_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; redraw_all - the screen from scratch
; ------------------------------------------------------------
redraw_all:
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
    ld   LINK_LO, x             ; CALL clear_screen
    ld   tr_r60, [x]
    ld   LINK_HI, x
    ld   tr_r60 >> 8, [x]
    ld   clear_screen >> 8, y
    jmp  clear_screen
tr_r60:
    ld   LINK_LO, x             ; CALL draw_footer
    ld   tr_r61, [x]
    ld   LINK_HI, x
    ld   tr_r61 >> 8, [x]
    ld   draw_footer >> 8, y
    jmp  draw_footer
tr_r61:
    ld   0x3F, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_header - row 0: file, title, octave, instrument, mode, state
; ------------------------------------------------------------
draw_header2:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r70, [x]
    ld   LINK_HI, x
    ld   tr_r70 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r70:
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r71, [x]
    ld   LINK_HI, x
    ld   tr_r71 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r71:
    ld   [e_play], ac
    bne  dh_p
    ld   s_stop & 0xFF, ac
    ld   ac, [R0]
    ld   s_stop >> 8, ac
    ld   ac, [R1]
    bra  dh_s
dh_p:
    ld   s_play & 0xFF, ac
    ld   ac, [R0]
    ld   s_play >> 8, ac
    ld   ac, [R1]
dh_s:
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r72, [x]
    ld   LINK_HI, x
    ld   tr_r72 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r72:
    clr  ac
    ld   ac, [R0]
    ld   TINT_GOLD, ac
    ld   ac, [R0]
    clr  ac
    ld   LINK_LO, x             ; CALL tint_row
    ld   tr_r73, [x]
    ld   LINK_HI, x
    ld   tr_r73 >> 8, [x]
    ld   tint_row >> 8, y
    jmp  tint_row
tr_r73:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_footer - the keys on the last row
; ------------------------------------------------------------
draw_header:
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
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_hdr & 0xFF, ac
    ld   ac, [R0]
    ld   s_hdr >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r62, [x]
    ld   LINK_HI, x
    ld   tr_r62 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r62:
    ld   e_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r63, [x]
    ld   LINK_HI, x
    ld   tr_r63 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r63:
    ld   31, ac
    sub  [CUR_COL], ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r64, [x]
    ld   LINK_HI, x
    ld   tr_r64 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r64:
    ld   0x20, ac
    ld   ac, [w0]
dh_t:
    ld   SONG >> 8, y
    ld   [w0], x
    ld   [y,x], ac
    bne  dh_t2
    ld   0x20, ac
dh_t2:
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r65, [x]
    ld   LINK_HI, x
    ld   tr_r65 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r65:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  0x38, ac
    bne  dh_t
    ld   s_oct & 0xFF, ac
    ld   ac, [R0]
    ld   s_oct >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r66, [x]
    ld   LINK_HI, x
    ld   tr_r66 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r66:
    ld   [e_oct], ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r67, [x]
    ld   LINK_HI, x
    ld   tr_r67 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r67:
    ld   s_ins & 0xFF, ac
    ld   ac, [R0]
    ld   s_ins >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r68, [x]
    ld   LINK_HI, x
    ld   tr_r68 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r68:
    ld   [e_ins], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r69, [x]
    ld   LINK_HI, x
    ld   tr_r69 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r69:
    ld   draw_header2 >> 8, y
    jmp  draw_header2

ins_byte:
    ld   ac, [u0]
    ld   [e_ins], ac
    and  0x0F, ac
    shl
    shl
    shl
    shl
    add  [u0], ac
    ld   ac, x
    ld   [e_ins], ac
    and  0x10, ac
    beq  ib_2
    ld   (SONG >> 8) + 3, y
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ib_2:
    ld   (SONG >> 8) + 2, y
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ins_addr - AC = offset: Y:X = the byte's address (for a store)
ins_addr:
    ld   ac, [u0]
    ld   [e_ins], ac
    and  0x0F, ac
    shl
    shl
    shl
    shl
    add  [u0], ac
    ld   ac, x
    ld   [e_ins], ac
    and  0x10, ac
    beq  ia_2
    ld   (SONG >> 8) + 3, y
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ia_2:
    ld   (SONG >> 8) + 2, y
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; draw_ptitle - rows 12-13: the pattern under the cursor, the columns
; ------------------------------------------------------------

#addr 0x1200
draw_footer:
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
    ld   ROWS, ac
    dec
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_keys & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r74, [x]
    ld   LINK_HI, x
    ld   tr_r74 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r74:
    ld   TINT_GOLD, ac
    ld   ac, [R0]
    ld   ROWS, ac
    dec
    ld   LINK_LO, x             ; CALL tint_row
    ld   tr_r75, [x]
    ld   LINK_HI, x
    ld   tr_r75 >> 8, [x]
    ld   tint_row >> 8, y
    jmp  tint_row
tr_r75:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_order - the orderlist block: rows 2-10
; ------------------------------------------------------------
draw_order:
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
    ld   2, ac
    ld   ac, [CUR_ROW]
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   s_order & 0xFF, ac
    ld   ac, [R0]
    ld   s_order >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r76, [x]
    ld   LINK_HI, x
    ld   tr_r76 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r76:
    clr  ac
    ld   ac, [w0]               ; the screen row - 3
do_r:
    ld   [w0], ac
    add  ROW_ORD, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   [w0], ac
    add  [e_otop], ac
    ld   ac, [w1]               ; the position
    ld   0x20, ac
    ld   [w1], ac
    xor  [e_op], ac
    bne  do_m
    ld   0x3E, ac
do_m:
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r77, [x]
    ld   LINK_HI, x
    ld   tr_r77 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r77:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r78, [x]
    ld   LINK_HI, x
    ld   tr_r78 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r78:
    ld   [w1], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r79, [x]
    ld   LINK_HI, x
    ld   tr_r79 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r79:
    clr  ac
    ld   ac, [w2]               ; the voice
do_v:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL draw_oentry
    ld   tr_r80, [x]
    ld   LINK_HI, x
    ld   tr_r80 >> 8, [x]
    ld   draw_oentry >> 8, y
    jmp  draw_oentry
tr_r80:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  do_v
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  ORD_ROWS, ac
    bne  do_r
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r81, [x]
    ld   LINK_HI, x
    ld   tr_r81 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r81:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; one orderlist entry: voice AC, position w1, at column 8 + 7 v

#addr 0x1300
draw_oentry:
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
    ld   ac, [w3]
    shl
    shl
    shl
    sub  [w3], ac
    add  8, ac
    ld   ac, [CUR_COL]
    ld   [w3], ac
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [w1], ac
    sub  [y,x], ac
    bcs  doe_p
    bne  doe_blank
    ld   OD_END, x              ; the end row
    ld   [y,x], ac
    xor  0xFF, ac
    bne  doe_stop
    ld   s_loop & 0xFF, ac
    ld   ac, [R0]
    ld   s_loop >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r82, [x]
    ld   LINK_HI, x
    ld   tr_r82 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r82:
    ld   [w3], ac
    add  VSPAGE, y
    ld   OD_TGT, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r83, [x]
    ld   LINK_HI, x
    ld   tr_r83 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r83:
    ld   tr_leave >> 8, y
    jmp  tr_leave
doe_stop:
    ld   s_stop6 & 0xFF, ac
    ld   ac, [R0]
    ld   s_stop6 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r84, [x]
    ld   LINK_HI, x
    ld   tr_r84 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r84:
    ld   tr_leave >> 8, y
    jmp  tr_leave
doe_blank:
    ld   6, ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r85, [x]
    ld   LINK_HI, x
    ld   tr_r85 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r85:
    ld   tr_leave >> 8, y
    jmp  tr_leave
doe_p:
    ld   [w1], ac
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r86, [x]
    ld   LINK_HI, x
    ld   tr_r86 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r86:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r87, [x]
    ld   LINK_HI, x
    ld   tr_r87 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r87:
    ld   [w3], ac
    add  VSPAGE, y
    ld   [w1], ac
    shl
    add  OD_TR, x
    ld   [y,x], ac
    bne  doe_t
    ld   3, ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r88, [x]
    ld   LINK_HI, x
    ld   tr_r88 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r88:
    ld   tr_leave >> 8, y
    jmp  tr_leave
doe_t:
    ld   LINK_LO, x             ; CALL tsigned
    ld   tr_r89, [x]
    ld   LINK_HI, x
    ld   tr_r89 >> 8, [x]
    ld   tsigned >> 8, y
    jmp  tsigned
tr_r89:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_ins - the instrument panel, rows 2-8 from column 40
; ------------------------------------------------------------
ifield:
    ld   ac, [u0]
    shl
    add  [u0], ac
    add  ifld & 0xFF, x
    ld   ifld >> 8, y
    ld   [y,x], ac
    ld   ac, [R2]
    ld   [u0], ac
    shl
    add  [u0], ac
    add  (ifld + 1) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R3]
    ld   [u0], ac
    shl
    add  [u0], ac
    add  (ifld + 2) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R4]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tcell - AC = table entry 1-63: R2 = row, R3 = column of its text

#addr 0x1400
draw_ins:
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
    ld   ROW_INS, ac
    ld   ac, [CUR_ROW]
    ld   COL_INS, ac
    ld   ac, [CUR_COL]
    ld   s_instr & 0xFF, ac
    ld   ac, [R0]
    ld   s_instr >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r90, [x]
    ld   LINK_HI, x
    ld   tr_r90 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r90:
    ld   [e_ins], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r91, [x]
    ld   LINK_HI, x
    ld   tr_r91 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r91:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r92, [x]
    ld   LINK_HI, x
    ld   tr_r92 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r92:
    ld   I_NAME, ac
    ld   ac, [w0]
di_n:
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL ins_byte
    ld   tr_r93, [x]
    ld   LINK_HI, x
    ld   tr_r93 >> 8, [x]
    ld   ins_byte >> 8, y
    jmp  ins_byte
tr_r93:
    bne  di_n2
    ld   0x20, ac
di_n2:
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r94, [x]
    ld   LINK_HI, x
    ld   tr_r94 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r94:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  16, ac
    bne  di_n
    ld   ROW_INS + 1, ac        ; the field rows, from a script
    ld   ac, [CUR_ROW]
    ld   COL_INS, ac
    ld   ac, [CUR_COL]
    ld   s_ifields & 0xFF, ac
    ld   ac, [R0]
    ld   s_ifields >> 8, ac
    ld   ac, [R1]
    ld   draw_ins2 >> 8, y
    jmp  draw_ins2

; the script: text, then a code byte: 01-7F a character, 80 + n the high
; nibble of instrument byte n, 90 + n its low nibble, A0 + n the byte,
; B0 + n bit 0 of it, FE a new row, FF the end
draw_ttitle:
    ld   [e_pane], ac
    xor  3, ac
    bne  dtt_p
    ld   s_wtab & 0xFF, ac
    ld   ac, [R0]
    ld   s_wtab >> 8, ac
    ld   ac, [R1]
    bra  dtt_s
dtt_p:
    ld   s_ptab & 0xFF, ac
    ld   ac, [R0]
    ld   s_ptab >> 8, ac
    ld   ac, [R1]
dtt_s:
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r117, [x]
    ld   LINK_HI, x
    ld   tr_r117 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r117:
    ld   80, ac
    sub  [CUR_COL], ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r118, [x]
    ld   LINK_HI, x
    ld   tr_r118 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r118:
    ld   ROW_PTIT + 1, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   80, ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r119, [x]
    ld   LINK_HI, x
    ld   tr_r119 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r119:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_grid_col - AC = voice: its pattern's rows from c_top, PV of them
; ------------------------------------------------------------
edit_del:
    ld   SCRATCH >> 8, y
    ld   [c_col], ac
    sub  3, ac
    bcc  ed_fx
    ld   [w1], ac
    inc
    ld   ac, x
    ld   0xFF, [y,x]
    ld   commit >> 8, y
    jmp  commit
ed_fx:
    ld   [w1], ac
    add  2, ac
    ld   ac, x
    ld   0xFF, [y,x]
    inc
    ld   ac, x
    ld   0x00, [y,x]
    ld   commit >> 8, y
    jmp  commit

; commit - the decoded pattern back into its slot, the row drawn again;
; commit_adv also moves the cursor down a row

#addr 0x1500
draw_ins2:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  di2_a
    ld   [R1], ac
    inc
    ld   ac, [R1]
di2_a:
    ld   [w1], ac
    xor  0xFF, ac
    beq  di2_end
    ld   [w1], ac
    xor  0xFE, ac
    beq  di2_row
    ld   [w1], ac
    sub  0x80, ac
    bcs  di2_ch
    and  0x0F, ac
    ld   LINK_LO, x             ; CALL ins_byte
    ld   tr_r95, [x]
    ld   LINK_HI, x
    ld   tr_r95 >> 8, [x]
    ld   ins_byte >> 8, y
    jmp  ins_byte
tr_r95:
    ld   ac, [w2]
    ld   [w1], ac
    and  0x30, ac
    beq  di2_hi
    sub  0x10, ac
    beq  di2_lo
    sub  0x10, ac
    beq  di2_by
    ld   [w2], ac
    and  1, ac
    add  0x30, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r96, [x]
    ld   LINK_HI, x
    ld   tr_r96 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r96:
    bra  draw_ins2
di2_hi:
    ld   [w2], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r97, [x]
    ld   LINK_HI, x
    ld   tr_r97 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r97:
    bra  draw_ins2
di2_lo:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r98, [x]
    ld   LINK_HI, x
    ld   tr_r98 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r98:
    bra  draw_ins2
di2_by:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r99, [x]
    ld   LINK_HI, x
    ld   tr_r99 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r99:
    bra  draw_ins2
di2_ch:
    ld   [w1], ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r100, [x]
    ld   LINK_HI, x
    ld   tr_r100 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r100:
    bra  draw_ins2
di2_row:
    ld   [CUR_ROW], ac
    inc
    ld   ac, [CUR_ROW]
    ld   COL_INS, ac
    ld   ac, [CUR_COL]
    bra  draw_ins2
di2_end:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r101, [x]
    ld   LINK_HI, x
    ld   tr_r101 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r101:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ins_byte - AC = offset 0-15: AC = that byte of instrument e_ins
grid_tints:
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
    ld   ac, [w4]
gts_l:
    ld   [w4], ac
    add  [c_top], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r140, [x]
    ld   LINK_HI, x
    ld   tr_r140 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r140:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    xor  PV, ac
    bne  gts_l
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; pane_tint - the active pane's cursor row (not the grid: grid_tint)
; R0 = the tint (blue, or 0 to take it off)
; ------------------------------------------------------------

#addr 0x1600
draw_ptitle:
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
    ld   ROW_PTIT, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   [e_pane], ac
    sub  3, ac
    bcs  dpt_pat
    ld   dpt_tab >> 8, y
    jmp  dpt_tab
dpt_pat:
    ld   s_pattern & 0xFF, ac
    ld   ac, [R0]
    ld   s_pattern >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r102, [x]
    ld   LINK_HI, x
    ld   tr_r102 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r102:
    ld   [c_v], ac
    ld   LINK_LO, x             ; CALL pat_of
    ld   tr_r103, [x]
    ld   LINK_HI, x
    ld   tr_r103 >> 8, [x]
    ld   pat_of >> 8, y
    jmp  pat_of
tr_r103:
    ld   ac, [w0]
    xor  0xFF, ac
    beq  dpt_none
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r104, [x]
    ld   LINK_HI, x
    ld   tr_r104 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r104:
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL need
    ld   tr_r105, [x]
    ld   LINK_HI, x
    ld   tr_r105 >> 8, [x]
    ld   need >> 8, y
    jmp  need
tr_r105:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r106, [x]
    ld   LINK_HI, x
    ld   tr_r106 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r106:
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r107, [x]
    ld   LINK_HI, x
    ld   tr_r107 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r107:
    ld   [p_len], ac
    ld   LINK_LO, x             ; CALL tdec2
    ld   tr_r108, [x]
    ld   LINK_HI, x
    ld   tr_r108 >> 8, [x]
    ld   tdec2 >> 8, y
    jmp  tdec2
tr_r108:
    ld   s_rows & 0xFF, ac
    ld   ac, [R0]
    ld   s_rows >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r109, [x]
    ld   LINK_HI, x
    ld   tr_r109 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r109:
    ld   draw_ptitle2 >> 8, y
    jmp  draw_ptitle2
dpt_none:
    ld   s_nopat & 0xFF, ac
    ld   ac, [R0]
    ld   s_nopat >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r110, [x]
    ld   LINK_HI, x
    ld   tr_r110 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r110:
    ld   draw_ptitle2 >> 8, y
    jmp  draw_ptitle2

tcell:
    dec
    ld   ac, [u0]
    clr  ac
    ld   ac, [u1]               ; the column
tc_l:
    ld   [u0], ac
    sub  PV, ac
    bcs  tc_d
    ld   ac, [u0]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    bra  tc_l
tc_d:
    ld   [u0], ac
    add  ROW_GRID, ac
    ld   ac, [R2]
    ld   [u1], ac
    shl
    shl
    shl
    shl
    ld   ac, [R3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; cursor_show - the underline under the field of the active pane
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


#addr 0x1700
draw_ptitle2:
    ld   s_voice & 0xFF, ac
    ld   ac, [R0]
    ld   s_voice >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r111, [x]
    ld   LINK_HI, x
    ld   tr_r111 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r111:
    ld   [c_v], ac
    add  0x31, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r112, [x]
    ld   LINK_HI, x
    ld   tr_r112 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r112:
    ld   s_pos & 0xFF, ac
    ld   ac, [R0]
    ld   s_pos >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r113, [x]
    ld   LINK_HI, x
    ld   tr_r113 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r113:
    ld   [e_op], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r114, [x]
    ld   LINK_HI, x
    ld   tr_r114 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r114:
    ld   80, ac
    sub  [CUR_COL], ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r115, [x]
    ld   LINK_HI, x
    ld   tr_r115 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r115:
    ld   ROW_PTIT + 1, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_cols & 0xFF, ac
    ld   ac, [R0]
    ld   s_cols >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r116, [x]
    ld   LINK_HI, x
    ld   tr_r116 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r116:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dpt_tab:
    ld   draw_ttitle >> 8, y
    jmp  draw_ttitle

draw_grid_col:
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
    ld   ac, [w0]
    ld   LINK_LO, x             ; CALL pat_of
    ld   tr_r120, [x]
    ld   LINK_HI, x
    ld   tr_r120 >> 8, [x]
    ld   pat_of >> 8, y
    jmp  pat_of
tr_r120:
    ld   LINK_LO, x             ; CALL need
    ld   tr_r121, [x]
    ld   LINK_HI, x
    ld   tr_r121 >> 8, [x]
    ld   need >> 8, y
    jmp  need
tr_r121:
    clr  ac
    ld   ac, [w2]
dgc_l:
    ld   [w2], ac
    add  [c_top], ac
    ld   ac, [w1]
    ld   LINK_LO, x             ; CALL draw_cell
    ld   tr_r122, [x]
    ld   LINK_HI, x
    ld   tr_r122 >> 8, [x]
    ld   draw_cell >> 8, y
    jmp  draw_cell
tr_r122:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  PV, ac
    bne  dgc_l
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_cell - voice w0, pattern row w1 (from the decoded pattern in
; SCRATCH, which must be the voice's): note, instrument, effect
; ------------------------------------------------------------
hexval:
    ld   ac, [u0]
    sub  0x30, ac
    blt  hv_n
    sub  10, ac
    bcs  hv_d
    ld   [u0], ac
    sub  0x61, ac
    blt  hv_n
    sub  6, ac
    bcs  hv_a
hv_n:
    ld   0xFF, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
hv_d:
    ld   [u0], ac
    sub  0x30, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
hv_a:
    ld   [u0], ac
    sub  0x61 - 10, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; piano - AC = key: AC = semitone from the octave (0-28), FF when none

#addr 0x1800
draw_cell:
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
    ld   [w1], ac
    sub  [c_top], ac
    add  ROW_GRID, ac
    ld   ac, [CUR_ROW]
    ld   [w0], ac
    shl
    add  [w0], ac
    shl
    shl
    add  COL_GRID, ac
    ld   ac, [CUR_COL]
    ld   [w1], ac
    sub  [p_len], ac
    bcs  dc_r
    ld   10, ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r123, [x]
    ld   LINK_HI, x
    ld   tr_r123 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r123:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dc_r:
    ld   [w1], ac
    shl
    shl
    ld   ac, [w3]
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL tnote
    ld   tr_r124, [x]
    ld   LINK_HI, x
    ld   tr_r124 >> 8, [x]
    ld   tnote >> 8, y
    jmp  tnote
tr_r124:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r125, [x]
    ld   LINK_HI, x
    ld   tr_r125 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r125:
    ld   [w3], ac
    inc
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    xor  0xFF, ac
    beq  dc_noins
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r126, [x]
    ld   LINK_HI, x
    ld   tr_r126 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r126:
    ld   draw_cell2 >> 8, y
    jmp  draw_cell2
dc_noins:
    ld   0x2D, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r127, [x]
    ld   LINK_HI, x
    ld   tr_r127 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r127:
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r128, [x]
    ld   LINK_HI, x
    ld   tr_r128 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r128:
    ld   draw_cell2 >> 8, y
    jmp  draw_cell2

draw_cell2:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r129, [x]
    ld   LINK_HI, x
    ld   tr_r129 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r129:
    ld   [w3], ac
    add  2, ac
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    xor  0xFF, ac
    beq  dc_nofx
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL thex1
    ld   tr_r130, [x]
    ld   LINK_HI, x
    ld   tr_r130 >> 8, [x]
    ld   thex1 >> 8, y
    jmp  thex1
tr_r130:
    ld   [w3], ac
    add  3, ac
    ld   ac, x
    ld   SCRATCH >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r131, [x]
    ld   LINK_HI, x
    ld   tr_r131 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r131:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dc_nofx:
    ld   s_dots & 0xFF, ac
    ld   ac, [R0]
    ld   s_dots >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r132, [x]
    ld   LINK_HI, x
    ld   tr_r132 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r132:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_rownums - the row numbers down the grid
; ------------------------------------------------------------

#addr 0x1900
draw_rownums:
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
    ld   ac, [w2]
dr_l:
    ld   [w2], ac
    add  ROW_GRID, ac
    ld   ac, [CUR_ROW]
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   [w2], ac
    add  [c_top], ac
    ld   ac, [w1]
    sub  64, ac
    bcc  dr_b
    ld   [w1], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r133, [x]
    ld   LINK_HI, x
    ld   tr_r133 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r133:
    bra  dr_n
dr_b:
    ld   2, ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r134, [x]
    ld   LINK_HI, x
    ld   tr_r134 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r134:
dr_n:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  PV, ac
    bne  dr_l
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_row - pattern row AC of all four voices (when on the screen)
; ------------------------------------------------------------
draw_row:
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
    ld   ac, [w1]
    sub  [c_top], ac
    bcs  drw_e
    sub  PV, ac
    bcc  drw_e
    clr  ac
    ld   ac, [w0]
drw_l:
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL pat_of
    ld   tr_r135, [x]
    ld   LINK_HI, x
    ld   tr_r135 >> 8, [x]
    ld   pat_of >> 8, y
    jmp  pat_of
tr_r135:
    ld   LINK_LO, x             ; CALL need
    ld   tr_r136, [x]
    ld   LINK_HI, x
    ld   tr_r136 >> 8, [x]
    ld   need >> 8, y
    jmp  need
tr_r136:
    ld   LINK_LO, x             ; CALL draw_cell
    ld   tr_r137, [x]
    ld   LINK_HI, x
    ld   tr_r137 >> 8, [x]
    ld   draw_cell >> 8, y
    jmp  draw_cell
tr_r137:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  4, ac
    bne  drw_l
    ld   [w1], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r138, [x]
    ld   LINK_HI, x
    ld   tr_r138 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r138:
drw_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; grid_tint - pattern row AC: its tint (blue under the cursor in the
; pattern pane, green when it is being played), when on the screen
; ------------------------------------------------------------
handle_key2:
    ld   [e_key], ac
    xor  0x3C, ac
    bne  hk2_1
    ld   [e_ins], ac
    beq  hk2_e
    dec
    bra  hk2_i
hk2_1:
    ld   [e_key], ac
    xor  0x3E, ac
    bne  hk2_2
    ld   [e_ins], ac
    xor  31, ac
    beq  hk2_e
    ld   [e_ins], ac
    inc
hk2_i:
    ld   ac, [e_ins]
    ld   [e_dirty], ac
    or   0x0C, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [i_np]
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_2:
    ld   handle_key3 >> 8, y
    jmp  handle_key3


#addr 0x1A00
grid_tint:
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
    ld   ac, [u7]
    sub  [c_top], ac
    bcs  gt_e
    sub  PV, ac
    bcc  gt_e
    clr  ac
    ld   ac, [R0]
    ld   [e_pane], ac
    bne  gt_p
    ld   [u7], ac
    xor  [c_row], ac
    bne  gt_p
    ld   TINT_BLUE, ac
    ld   ac, [R0]
gt_p:
    ld   [e_play], ac
    beq  gt_w
    ld   [e_plop], ac
    xor  [e_op], ac
    bne  gt_w
    ld   [u7], ac
    xor  [e_plrow], ac
    bne  gt_w
    ld   [R0], ac
    or   TINT_GREEN, ac
    ld   ac, [R0]
gt_w:
    ld   [u7], ac
    sub  [c_top], ac
    add  ROW_GRID, ac
    ld   LINK_LO, x             ; CALL tint_row
    ld   tr_r139, [x]
    ld   LINK_HI, x
    ld   tr_r139 >> 8, [x]
    ld   tint_row >> 8, y
    jmp  tint_row
tr_r139:
gt_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; grid_tints - every grid row on the screen
pane_tint:
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
    ld   [e_pane], ac
    xor  1, ac
    bne  pt_2
    ld   [o_k], ac
    sub  [e_otop], ac
    add  ROW_ORD, ac
    ld   LINK_LO, x             ; CALL tint_row
    ld   tr_r141, [x]
    ld   LINK_HI, x
    ld   tr_r141 >> 8, [x]
    ld   tint_row >> 8, y
    jmp  tint_row
tr_r141:
    ld   tr_leave >> 8, y
    jmp  tr_leave
pt_2:
    ld   [e_pane], ac
    xor  2, ac
    bne  pt_3
    ld   [i_f], ac
    ld   LINK_LO, x             ; CALL ifield
    ld   tr_r142, [x]
    ld   LINK_HI, x
    ld   tr_r142 >> 8, [x]
    ld   ifield >> 8, y
    jmp  ifield
tr_r142:
    ld   [R2], ac
    ld   LINK_LO, x             ; CALL tint_row
    ld   tr_r143, [x]
    ld   LINK_HI, x
    ld   tr_r143 >> 8, [x]
    ld   tint_row >> 8, y
    jmp  tint_row
tr_r143:
    ld   tr_leave >> 8, y
    jmp  tr_leave
pt_3:
    ld   [e_pane], ac
    sub  3, ac
    bcs  pt_e
    ld   [t_e], ac
    ld   LINK_LO, x             ; CALL tcell
    ld   tr_r144, [x]
    ld   LINK_HI, x
    ld   tr_r144 >> 8, [x]
    ld   tcell >> 8, y
    jmp  tcell
tr_r144:
    ld   [R2], ac
    ld   LINK_LO, x             ; CALL tint_row
    ld   tr_r145, [x]
    ld   LINK_HI, x
    ld   tr_r145 >> 8, [x]
    ld   tint_row >> 8, y
    jmp  tint_row
tr_r145:
pt_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ifield - AC = instrument field: R2 = row, R3 = column, R4 = width
ord_trans:
    ld   ac, [u0]
    ld   [o_k], ac
    xor  [w3], ac
    beq  ot_e
    ld   [o_v], ac
    add  VSPAGE, y
    ld   [o_k], ac
    shl
    add  OD_TR, x
    ld   [y,x], ac
    add  [u0], ac
    ld   ac, [u1]
    add  32, ac
    sub  64, ac
    bcc  ot_e                   ; out of -32..31
    ld   [u1], ac
    ld   ac, [y,x]
    ld   ord_changed >> 8, y
    jmp  ord_changed
ot_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ord_end - AC = FE stop / FF loop at the end of the list
cursor_show:
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
    ld   [e_pane], ac
    bne  cs_1
    ld   [c_row], ac
    sub  [c_top], ac
    bcs  cs_e
    sub  PV, ac
    bcc  cs_e
    ld   [c_row], ac
    sub  [c_top], ac
    add  ROW_GRID, ac
    ld   ac, [CUR_ROW]
    ld   [c_v], ac
    shl
    add  [c_v], ac
    shl
    shl
    add  COL_GRID, ac
    ld   ac, [u0]
    ld   [c_col], ac
    add  ccol & 0xFF, x
    ld   ccol >> 8, y
    ld   [y,x], ac
    add  [u0], ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [u1]
    ld   [c_col], ac
    beq  cs_m
    ld   1, ac
    ld   ac, [u1]
cs_m:
    ld   [u1], ac
    ld   LINK_LO, x             ; CALL tmark
    ld   tr_r146, [x]
    ld   LINK_HI, x
    ld   tr_r146 >> 8, [x]
    ld   tmark >> 8, y
    jmp  tmark
tr_r146:
cs_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cs_1:
    ld   cursor_show2 >> 8, y
    jmp  cursor_show2

cursor_hide:
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
    ld   [e_pane], ac
    bne  ch_1
    ld   [c_v], ac
    ld   ac, [w0]
    ld   LINK_LO, x             ; CALL pat_of
    ld   tr_r157, [x]
    ld   LINK_HI, x
    ld   tr_r157 >> 8, [x]
    ld   pat_of >> 8, y
    jmp  pat_of
tr_r157:
    ld   LINK_LO, x             ; CALL need
    ld   tr_r158, [x]
    ld   LINK_HI, x
    ld   tr_r158 >> 8, [x]
    ld   need >> 8, y
    jmp  need
tr_r158:
    ld   [c_row], ac
    sub  [c_top], ac
    bcs  ch_e
    sub  PV, ac
    bcc  ch_e
    ld   [c_row], ac
    ld   ac, [w1]
    ld   LINK_LO, x             ; CALL draw_cell
    ld   tr_r159, [x]
    ld   LINK_HI, x
    ld   tr_r159 >> 8, [x]
    ld   draw_cell >> 8, y
    jmp  draw_cell
tr_r159:
ch_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ch_1:
    ld   [e_pane], ac
    xor  1, ac
    bne  ch_2
    ld   [o_k], ac
    sub  [e_otop], ac
    add  ROW_ORD, ac
    ld   ac, [CUR_ROW]
    ld   [o_k], ac
    ld   ac, [w1]
    ld   [o_v], ac
    ld   LINK_LO, x             ; CALL draw_oentry
    ld   tr_r160, [x]
    ld   LINK_HI, x
    ld   tr_r160 >> 8, [x]
    ld   draw_oentry >> 8, y
    jmp  draw_oentry
tr_r160:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ch_2:
    ld   [e_pane], ac
    xor  2, ac
    bne  ch_3
    ld   4, ac
    ld   ac, [e_dirty]          ; the whole panel is cheap
    ld   tr_leave >> 8, y
    jmp  tr_leave
ch_3:
    ld   [t_e], ac
    ld   LINK_LO, x             ; CALL draw_tentry
    ld   tr_r161, [x]
    ld   LINK_HI, x
    ld   tr_r161 >> 8, [x]
    ld   draw_tentry >> 8, y
    jmp  draw_tentry
tr_r161:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; draw_table - the wave or pulse table, entries 1-63 in columns
; ------------------------------------------------------------

#addr 0x1C00
cursor_show2:
    ld   [e_pane], ac
    xor  1, ac
    bne  cs2_2
    ld   [o_k], ac              ; the orderlist
    sub  [e_otop], ac
    add  ROW_ORD, ac
    ld   ac, [CUR_ROW]
    ld   [o_v], ac
    shl
    shl
    shl
    sub  [o_v], ac
    add  8, ac
    ld   ac, [CUR_COL]
    ld   [o_v], ac
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [o_k], ac
    xor  [y,x], ac
    bne  cs2_f
    ld   6, ac                  ; the end row
    ld   LINK_LO, x             ; CALL tmark
    ld   tr_r147, [x]
    ld   LINK_HI, x
    ld   tr_r147 >> 8, [x]
    ld   tmark >> 8, y
    jmp  tmark
tr_r147:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cs2_f:
    ld   [o_f], ac
    beq  cs2_p
    ld   [CUR_COL], ac
    add  3, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   LINK_LO, x             ; CALL tmark
    ld   tr_r148, [x]
    ld   LINK_HI, x
    ld   tr_r148 >> 8, [x]
    ld   tmark >> 8, y
    jmp  tmark
tr_r148:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cs2_p:
    ld   2, ac
    ld   LINK_LO, x             ; CALL tmark
    ld   tr_r149, [x]
    ld   LINK_HI, x
    ld   tr_r149 >> 8, [x]
    ld   tmark >> 8, y
    jmp  tmark
tr_r149:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cs2_2:
    ld   [e_pane], ac
    xor  2, ac
    bne  cs2_3
    ld   [i_f], ac              ; the instrument field
    ld   LINK_LO, x             ; CALL ifield
    ld   tr_r150, [x]
    ld   LINK_HI, x
    ld   tr_r150 >> 8, [x]
    ld   ifield >> 8, y
    jmp  ifield
tr_r150:
    ld   LINK_LO, x             ; CALL tat
    ld   tr_r151, [x]
    ld   LINK_HI, x
    ld   tr_r151 >> 8, [x]
    ld   tat >> 8, y
    jmp  tat
tr_r151:
    ld   [R4], ac
    ld   LINK_LO, x             ; CALL tmark
    ld   tr_r152, [x]
    ld   LINK_HI, x
    ld   tr_r152 >> 8, [x]
    ld   tmark >> 8, y
    jmp  tmark
tr_r152:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cs2_3:
    ld   [t_e], ac              ; the table entry
    ld   LINK_LO, x             ; CALL tcell
    ld   tr_r153, [x]
    ld   LINK_HI, x
    ld   tr_r153 >> 8, [x]
    ld   tcell >> 8, y
    jmp  tcell
tr_r153:
    ld   LINK_LO, x             ; CALL tat
    ld   tr_r154, [x]
    ld   LINK_HI, x
    ld   tr_r154 >> 8, [x]
    ld   tat >> 8, y
    jmp  tat
tr_r154:
    ld   [t_f], ac
    beq  cs2_l
    ld   [CUR_COL], ac
    add  9, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   LINK_LO, x             ; CALL tmark
    ld   tr_r155, [x]
    ld   LINK_HI, x
    ld   tr_r155 >> 8, [x]
    ld   tmark >> 8, y
    jmp  tmark
tr_r155:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cs2_l:
    ld   [CUR_COL], ac
    add  3, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   LINK_LO, x             ; CALL tmark
    ld   tr_r156, [x]
    ld   LINK_HI, x
    ld   tr_r156 >> 8, [x]
    ld   tmark >> 8, y
    jmp  tmark
tr_r156:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; cursor_hide - draw the field again without the underline
; ------------------------------------------------------------
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


#addr 0x1D00
draw_table:
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
    ld   ac, [w4]               ; clear the rows first
dt_c:
    ld   [w4], ac
    add  ROW_GRID, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   80, ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r162, [x]
    ld   LINK_HI, x
    ld   tr_r162 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r162:
    clr  ac
    ld   ac, [R0]
    ld   [w4], ac
    add  ROW_GRID, ac
    ld   LINK_LO, x             ; CALL tint_row
    ld   tr_r163, [x]
    ld   LINK_HI, x
    ld   tr_r163 >> 8, [x]
    ld   tint_row >> 8, y
    jmp  tint_row
tr_r163:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    xor  PV, ac
    bne  dt_c
    ld   1, ac
    ld   ac, [w4]
dt_l:
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL draw_tentry
    ld   tr_r164, [x]
    ld   LINK_HI, x
    ld   tr_r164 >> 8, [x]
    ld   draw_tentry >> 8, y
    jmp  draw_tentry
tr_r164:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    xor  64, ac
    bne  dt_l
    ld   TINT_BLUE, ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r165, [x]
    ld   LINK_HI, x
    ld   tr_r165 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r165:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r166, [x]
    ld   LINK_HI, x
    ld   tr_r166 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r166:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; draw_tentry - AC = entry: "nn left right" at its place
draw_tentry:
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
    ld   ac, [w0]
    ld   LINK_LO, x             ; CALL tcell
    ld   tr_r167, [x]
    ld   LINK_HI, x
    ld   tr_r167 >> 8, [x]
    ld   tcell >> 8, y
    jmp  tcell
tr_r167:
    ld   LINK_LO, x             ; CALL tat
    ld   tr_r168, [x]
    ld   LINK_HI, x
    ld   tr_r168 >> 8, [x]
    ld   tat >> 8, y
    jmp  tat
tr_r168:
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r169, [x]
    ld   LINK_HI, x
    ld   tr_r169 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r169:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r170, [x]
    ld   LINK_HI, x
    ld   tr_r170 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r170:
    ld   [e_pane], ac
    xor  4, ac
    beq  dte_p
    ld   draw_wentry >> 8, y
    jmp  draw_wentry
dte_p:
    ld   draw_pentry >> 8, y
    jmp  draw_pentry

; the wave table: left = the waveform name, right = the note
ord_changed:
    ld   [o_v], ac
    ld   LINK_LO, x             ; CALL encode_ol
    ld   tr_r253, [x]
    ld   LINK_HI, x
    ld   tr_r253 >> 8, [x]
    ld   encode_ol >> 8, y
    jmp  encode_ol
tr_r253:
    ld   1, ac
    ld   ac, [e_mod]
    ld   [e_dirty], ac
    or   0x23, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; key_ins - the instrument pane
; ------------------------------------------------------------
draw_wentry:
    ld   (SONG >> 8) + 1, y
    ld   [w0], x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   [w0], ac
    add  0x40, x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   [w1], ac
    sub  13, ac
    bcs  dw_nm                  ; 0-12: the names
    ld   [w1], ac
    xor  0x7F, ac
    beq  dw_off
    ld   [w1], ac
    xor  0xFE, ac
    beq  dw_end
    ld   [w1], ac
    xor  0xFF, ac
    beq  dw_loop
    ld   16, ac
    bra  dw_nm2
dw_off:
    ld   13, ac
    bra  dw_nm2
dw_end:
    ld   14, ac
    bra  dw_nm2
dw_loop:
    ld   15, ac
dw_nm2:
    ld   ac, [w1]
dw_nm:
    ld   [w1], ac
    ld   LINK_LO, x             ; CALL wname
    ld   tr_r171, [x]
    ld   LINK_HI, x
    ld   tr_r171 >> 8, [x]
    ld   wname >> 8, y
    jmp  wname
tr_r171:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r172, [x]
    ld   LINK_HI, x
    ld   tr_r172 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r172:
    ld   [w1], ac
    xor  15, ac
    bne  dw_r
    ld   [w2], ac               ; LOOP nn
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r173, [x]
    ld   LINK_HI, x
    ld   tr_r173 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r173:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r174, [x]
    ld   LINK_HI, x
    ld   tr_r174 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r174:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dw_r:
    ld   [w1], ac
    xor  14, ac
    bne  dw_r2
    ld   3, ac                  ; END
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r175, [x]
    ld   LINK_HI, x
    ld   tr_r175 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r175:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dw_r2:
    ld   [w2], ac
    blt  dw_abs
    ld   [w2], ac               ; relative: 7-bit two's complement
    and  0x40, ac
    beq  dw_rel
    ld   [w2], ac
    or   0x80, ac
    ld   ac, [w2]
dw_rel:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL tsigned
    ld   tr_r176, [x]
    ld   LINK_HI, x
    ld   tr_r176 >> 8, [x]
    ld   tsigned >> 8, y
    jmp  tsigned
tr_r176:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dw_abs:
    ld   [w2], ac
    and  0x7F, ac
    ld   LINK_LO, x             ; CALL tnote
    ld   tr_r177, [x]
    ld   LINK_HI, x
    ld   tr_r177 >> 8, [x]
    ld   tnote >> 8, y
    jmp  tnote
tr_r177:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; wname - AC = name index 0-16: five characters
piano:
    ld   ac, [u0]
    clr  ac
    ld   ac, [u1]
pi_l:
    ld   [u1], ac
    add  pkeys & 0xFF, x
    ld   pkeys >> 8, y
    ld   [y,x], ac
    beq  pi_n
    xor  [u0], ac
    beq  pi_f
    ld   [u1], ac
    add  2, ac
    ld   ac, [u1]
    bra  pi_l
pi_f:
    ld   [u1], ac
    add  (pkeys + 1) & 0xFF, x
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
pi_n:
    ld   0xFF, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; key_pat - the pattern pane
; ------------------------------------------------------------

#addr 0x2000
wname:
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
    ld   ac, [w3]
    shl
    shl
    add  [w3], ac
    ld   ac, [w3]
    ld   5, ac
    ld   ac, [w5]
wn_l:
    ld   [w3], ac
    add  wnames & 0xFF, x
    ld   wnames >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r178, [x]
    ld   LINK_HI, x
    ld   tr_r178 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r178:
    ld   [w3], ac
    inc
    ld   ac, [w3]
    ld   [w5], ac
    dec
    ld   ac, [w5]
    bne  wn_l
    ld   tr_leave >> 8, y
    jmp  tr_leave

; the pulse table: 00 END, 80 SET nn, FF LOOP nn, else xTT +ss
next_pane:
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
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r205, [x]
    ld   LINK_HI, x
    ld   tr_r205 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r205:
    clr  ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r206, [x]
    ld   LINK_HI, x
    ld   tr_r206 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r206:
    ld   [e_pane], ac
    ld   ac, [w4]               ; the old pane
    inc
    ld   ac, [e_pane]
    xor  5, ac
    bne  npn_a
    clr  ac
    ld   ac, [e_pane]
npn_a:
    ld   [w4], ac
    bne  np_b
    ld   [c_row], ac            ; leaving the pattern pane: no blue there
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r207, [x]
    ld   LINK_HI, x
    ld   tr_r207 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r207:
np_b:
    ld   [w4], ac
    xor  4, ac
    beq  np_view
    ld   [e_pane], ac
    sub  3, ac
    bcc  np_view
    ld   [e_pane], ac
    bne  np_c
    ld   [c_row], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r208, [x]
    ld   LINK_HI, x
    ld   tr_r208 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r208:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r209, [x]
    ld   LINK_HI, x
    ld   tr_r209 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r209:
    ld   tr_leave >> 8, y
    jmp  tr_leave
np_c:
    ld   TINT_BLUE, ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r210, [x]
    ld   LINK_HI, x
    ld   tr_r210 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r210:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r211, [x]
    ld   LINK_HI, x
    ld   tr_r211 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r211:
    ld   tr_leave >> 8, y
    jmp  tr_leave
np_view:
    ld   LINK_LO, x             ; CALL view_refresh
    ld   tr_r212, [x]
    ld   LINK_HI, x
    ld   tr_r212 >> 8, [x]
    ld   view_refresh >> 8, y
    jmp  view_refresh
tr_r212:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; view_refresh - the main view (grid or table) and its title again

#addr 0x2100
draw_pentry:
    ld   (SONG >> 8) + 1, y
    ld   [w0], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   [w0], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   [w1], ac
    beq  dp_end
    ld   [w1], ac
    xor  0x80, ac
    beq  dp_set
    ld   [w1], ac
    xor  0xFF, ac
    beq  dp_loop
    ld   0x78, ac               ; x
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r179, [x]
    ld   LINK_HI, x
    ld   tr_r179 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r179:
    ld   [w1], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r180, [x]
    ld   LINK_HI, x
    ld   tr_r180 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r180:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r181, [x]
    ld   LINK_HI, x
    ld   tr_r181 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r181:
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r182, [x]
    ld   LINK_HI, x
    ld   tr_r182 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r182:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL tsigned
    ld   tr_r183, [x]
    ld   LINK_HI, x
    ld   tr_r183 >> 8, [x]
    ld   tsigned >> 8, y
    jmp  tsigned
tr_r183:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dp_end:
    ld   14, ac
    ld   LINK_LO, x             ; CALL wname
    ld   tr_r184, [x]
    ld   LINK_HI, x
    ld   tr_r184 >> 8, [x]
    ld   wname >> 8, y
    jmp  wname
tr_r184:
    ld   4, ac
    ld   LINK_LO, x             ; CALL tspc
    ld   tr_r185, [x]
    ld   LINK_HI, x
    ld   tr_r185 >> 8, [x]
    ld   tspc >> 8, y
    jmp  tspc
tr_r185:
    ld   tr_leave >> 8, y
    jmp  tr_leave
dp_set:
    ld   17, ac
    ld   LINK_LO, x             ; CALL wname
    ld   tr_r186, [x]
    ld   LINK_HI, x
    ld   tr_r186 >> 8, [x]
    ld   wname >> 8, y
    jmp  wname
tr_r186:
    bra  dp_v
dp_loop:
    ld   15, ac
    ld   LINK_LO, x             ; CALL wname
    ld   tr_r187, [x]
    ld   LINK_HI, x
    ld   tr_r187 >> 8, [x]
    ld   wname >> 8, y
    jmp  wname
tr_r187:
dp_v:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r188, [x]
    ld   LINK_HI, x
    ld   tr_r188 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r188:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL thex2
    ld   tr_r189, [x]
    ld   LINK_HI, x
    ld   tr_r189 >> 8, [x]
    ld   thex2 >> 8, y
    jmp  thex2
tr_r189:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r190, [x]
    ld   LINK_HI, x
    ld   tr_r190 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r190:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ============================================================
; keys
; ============================================================

; handle_key - AC = the key (e_key)
scroll_to:
    ld   [c_row], ac
    sub  [c_top], ac
    bcs  st_m
    sub  PV, ac
    bcs  st_ok
st_m:
    ld   PV, ac             ; centre it
    shr  ac
    ld   ac, [u0]
    ld   [c_row], ac
    sub  [u0], ac
    bcs  st_0
    ld   ac, [c_top]
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
st_0:
    clr  ac
    ld   ac, [c_top]
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
st_ok:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; edit_cell - a key into the field under the pattern cursor
; ------------------------------------------------------------

#addr 0x2200
handle_key:
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
    sub  0x41, ac               ; A-Z (caps lock) -> a-z
    blt  hk_a
    sub  26, ac
    bcc  hk_a
    ld   [e_key], ac
    or   0x20, ac
    ld   ac, [e_key]
hk_a:
    ld   [e_key], ac
    xor  0x18, ac
    beq  hk_b
    ld   [e_fl], ac             ; any other key: Ctrl-X must be pressed twice again
    and  0xFE, ac
    ld   ac, [e_fl]
hk_b:
    ld   [e_key], ac
    xor  0x09, ac
    bne  hk_1
    ld   LINK_LO, x             ; CALL next_pane
    ld   tr_r191, [x]
    ld   LINK_HI, x
    ld   tr_r191 >> 8, [x]
    ld   next_pane >> 8, y
    jmp  next_pane
tr_r191:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk_1:
    ld   [e_key], ac
    xor  0x0A, ac
    bne  hk_2
    clr  ac
    ld   LINK_LO, x             ; CALL do_play
    ld   tr_r192, [x]
    ld   LINK_HI, x
    ld   tr_r192 >> 8, [x]
    ld   do_play >> 8, y
    jmp  do_play
tr_r192:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk_2:
    ld   [e_key], ac
    xor  0x20, ac
    bne  hk_3
    ld   [e_play], ac
    beq  hk_2p
    ld   LINK_LO, x             ; CALL do_stop
    ld   tr_r193, [x]
    ld   LINK_HI, x
    ld   tr_r193 >> 8, [x]
    ld   do_stop >> 8, y
    jmp  do_stop
tr_r193:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk_2p:
    ld   [e_op], ac
    ld   LINK_LO, x             ; CALL do_play
    ld   tr_r194, [x]
    ld   LINK_HI, x
    ld   tr_r194 >> 8, [x]
    ld   do_play >> 8, y
    jmp  do_play
tr_r194:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk_3:
    ld   [e_key], ac
    xor  0x1B, ac
    bne  hk_4
    ld   LINK_LO, x             ; CALL do_stop
    ld   tr_r195, [x]
    ld   LINK_HI, x
    ld   tr_r195 >> 8, [x]
    ld   do_stop >> 8, y
    jmp  do_stop
tr_r195:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk_4:
    ld   [e_key], ac
    xor  0x2D, ac
    bne  hk_5
    ld   [e_oct], ac
    beq  hk_e
    dec
    ld   ac, [e_oct]
    ld   8, ac
    ld   ac, [e_dirty]
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk_5:
    ld   [e_key], ac
    xor  0x3D, ac
    bne  hk_6
    ld   [e_oct], ac
    xor  7, ac
    beq  hk_e
    ld   [e_oct], ac
    inc
    ld   ac, [e_oct]
    ld   8, ac
    ld   ac, [e_dirty]
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk_6:
    ld   handle_key2 >> 8, y
    jmp  handle_key2
hk_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

copy_name:
    clr  ac
    ld   ac, [u0]
cn_l:
    ld   [R1], y
    ld   [u0], ac
    add  [R0], ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  e_name, x
    ld   [u1], ac
    ld   ac, [x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  13, ac
    bne  cn_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; load_song - the file e_name from the card into the song's places:
; the header pages as they come, then each orderlist and pattern (in
; the order of their offsets, as mus_tool.py and this program write
; them) into its own place.  L_ERR = 0 loaded, 1 not found / unreadable
; ============================================================
L_K    = 0x80               ; x5D80: the object being filled
L_NLO  = 0x81               ; the next object's offset
L_NHI  = 0x82
L_DPG  = 0x83               ; where the bytes go
L_DLO  = 0x84
L_LLO  = 0x85               ; bytes still taken (0 when the rest is dropped)
L_LHI  = 0x86
L_ERR  = 0x87
L_SZ   = 0x88               ; x5D88-x5D8B: the orderlists' sizes (saving)
L_NPAT = 0x8C


#addr 0x2300
handle_key3:
    ld   [e_key], ac
    xor  0x0F, ac
    bne  hk2_3
    ld   LINK_LO, x             ; CALL load_cmd
    ld   tr_r196, [x]
    ld   LINK_HI, x
    ld   tr_r196 >> 8, [x]
    ld   load_cmd >> 8, y
    jmp  load_cmd
tr_r196:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_3:
    ld   [e_key], ac
    xor  0x17, ac
    bne  hk2_4
    ld   LINK_LO, x             ; CALL save_cmd
    ld   tr_r197, [x]
    ld   LINK_HI, x
    ld   tr_r197 >> 8, [x]
    ld   save_cmd >> 8, y
    jmp  save_cmd
tr_r197:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_4:
    ld   [e_key], ac
    xor  0x0E, ac
    bne  hk2_6
    ld   LINK_LO, x             ; CALL new_cmd
    ld   tr_r198, [x]
    ld   LINK_HI, x
    ld   tr_r198 >> 8, [x]
    ld   new_cmd >> 8, y
    jmp  new_cmd
tr_r198:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_6:
    ld   [e_key], ac
    xor  0x18, ac
    bne  hk2_7
    ld   LINK_LO, x             ; CALL exit_cmd
    ld   tr_r199, [x]
    ld   LINK_HI, x
    ld   tr_r199 >> 8, [x]
    ld   exit_cmd >> 8, y
    jmp  exit_cmd
tr_r199:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_7:
    ld   [e_key], ac
    xor  0x0C, ac
    bne  hk2_8
    ld   LINK_LO, x             ; CALL len_cmd
    ld   tr_r200, [x]
    ld   LINK_HI, x
    ld   tr_r200 >> 8, [x]
    ld   len_cmd >> 8, y
    jmp  len_cmd
tr_r200:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_8:
    ld   [e_pane], ac
    bne  hk2_p1
    ld   LINK_LO, x             ; CALL key_pat
    ld   tr_r201, [x]
    ld   LINK_HI, x
    ld   tr_r201 >> 8, [x]
    ld   key_pat >> 8, y
    jmp  key_pat
tr_r201:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_p1:
    ld   [e_pane], ac
    xor  1, ac
    bne  hk2_p2
    ld   LINK_LO, x             ; CALL key_ord
    ld   tr_r202, [x]
    ld   LINK_HI, x
    ld   tr_r202 >> 8, [x]
    ld   key_ord >> 8, y
    jmp  key_ord
tr_r202:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_p2:
    ld   [e_pane], ac
    xor  2, ac
    bne  hk2_p3
    ld   LINK_LO, x             ; CALL key_ins
    ld   tr_r203, [x]
    ld   LINK_HI, x
    ld   tr_r203 >> 8, [x]
    ld   key_ins >> 8, y
    jmp  key_ins
tr_r203:
    ld   tr_leave >> 8, y
    jmp  tr_leave
hk2_p3:
    ld   LINK_LO, x             ; CALL key_tab
    ld   tr_r204, [x]
    ld   LINK_HI, x
    ld   tr_r204 >> 8, [x]
    ld   key_tab >> 8, y
    jmp  key_tab
tr_r204:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; next_pane - Tab
; ------------------------------------------------------------
ord_field:
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
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r247, [x]
    ld   LINK_HI, x
    ld   tr_r247 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r247:
    ld   [w4], ac
    and  1, ac
    ld   ac, [o_f]
    ld   [w4], ac
    shr  ac
    ld   ac, [o_v]
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r248, [x]
    ld   LINK_HI, x
    ld   tr_r248 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r248:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ord_move - the order cursor to position AC; the grid shows it

#addr 0x2400
key_pat:
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
    ld   [e_key], ac
    xor  0x11, ac
    bne  kp_1
    ld   [c_row], ac
    beq  kp_e
    dec
    ld   LINK_LO, x             ; CALL move_row
    ld   tr_r213, [x]
    ld   LINK_HI, x
    ld   tr_r213 >> 8, [x]
    ld   move_row >> 8, y
    jmp  move_row
tr_r213:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kp_1:
    ld   [e_key], ac
    xor  0x12, ac
    bne  kp_2
    ld   [c_row], ac
    xor  63, ac
    beq  kp_e
    ld   [c_row], ac
    inc
    ld   LINK_LO, x             ; CALL move_row
    ld   tr_r214, [x]
    ld   LINK_HI, x
    ld   tr_r214 >> 8, [x]
    ld   move_row >> 8, y
    jmp  move_row
tr_r214:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kp_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kp_2:
    ld   key_pat2 >> 8, y
    jmp  key_pat2

move_row:
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
    ld   ac, [w5]
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r222, [x]
    ld   LINK_HI, x
    ld   tr_r222 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r222:
    ld   [c_row], ac
    ld   ac, [w4]
    ld   [w5], ac
    ld   ac, [c_row]
    ld   LINK_LO, x             ; CALL scroll_to
    ld   tr_r223, [x]
    ld   LINK_HI, x
    ld   tr_r223 >> 8, [x]
    ld   scroll_to >> 8, y
    jmp  scroll_to
tr_r223:
    bne  mr_full
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r224, [x]
    ld   LINK_HI, x
    ld   tr_r224 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r224:
    ld   [c_row], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r225, [x]
    ld   LINK_HI, x
    ld   tr_r225 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r225:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r226, [x]
    ld   LINK_HI, x
    ld   tr_r226 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r226:
    ld   tr_leave >> 8, y
    jmp  tr_leave
mr_full:
    ld   [e_dirty], ac
    or   0x01, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; scroll_to - c_row on the screen: AC = 1 when c_top moved (a redraw)
prompt_bs:
    ld   [w0], ac
    bne  pb_a
    ld   pr_l >> 8, y
    jmp  pr_l
pb_a:
    dec
    ld   ac, [w0]
    ld   [w1], ac
    dec
    ld   ac, [w1]
    ld   ac, [CUR_COL]
    ld   s_cur & 0xFF, ac
    ld   ac, [R0]
    ld   s_cur >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r335, [x]
    ld   LINK_HI, x
    ld   tr_r335 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r335:
    ld   pr_l >> 8, y
    jmp  pr_l


#addr 0x2500
key_pat2:
    ld   [e_key], ac
    xor  0x13, ac
    bne  kp_3
    ld   [c_col], ac
    bne  kp_2a
    ld   [c_v], ac
    beq  kp_e2
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r215, [x]
    ld   LINK_HI, x
    ld   tr_r215 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r215:
    ld   [c_v], ac
    dec
    ld   ac, [c_v]
    ld   6, ac
    ld   ac, [c_col]
    ld   [e_dirty], ac
    or   0x20, ac
    ld   ac, [e_dirty]
kp_2a:
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r216, [x]
    ld   LINK_HI, x
    ld   tr_r216 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r216:
    ld   [c_col], ac
    dec
    ld   ac, [c_col]
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r217, [x]
    ld   LINK_HI, x
    ld   tr_r217 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r217:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kp_3:
    ld   [e_key], ac
    xor  0x14, ac
    bne  kp_4
    ld   [c_col], ac
    xor  5, ac
    bne  kp_3a
    ld   [c_v], ac
    xor  3, ac
    beq  kp_e2
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r218, [x]
    ld   LINK_HI, x
    ld   tr_r218 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r218:
    ld   [c_v], ac
    inc
    ld   ac, [c_v]
    ld   0xFF, ac
    ld   ac, [c_col]
    ld   [e_dirty], ac
    or   0x20, ac
    ld   ac, [e_dirty]
kp_3a:
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r219, [x]
    ld   LINK_HI, x
    ld   tr_r219 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r219:
    ld   [c_col], ac
    inc
    ld   ac, [c_col]
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r220, [x]
    ld   LINK_HI, x
    ld   tr_r220 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r220:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kp_4:
    ld   LINK_LO, x             ; CALL edit_cell
    ld   tr_r221, [x]
    ld   LINK_HI, x
    ld   tr_r221 >> 8, [x]
    ld   edit_cell >> 8, y
    jmp  edit_cell
tr_r221:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kp_e2:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; move_row - the pattern cursor to row AC (the view follows)
ord_hex:
    ld   [o_v], ac
    add  VSPAGE, y
    ld   [o_k], ac
    xor  [w3], ac
    beq  oh_end
    ld   [o_f], ac
    bne  oh_e
    ld   [o_k], ac
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    shl
    shl
    shl
    shl
    or   [w2], ac
    and  0x3F, ac
    ld   ac, [y,x]
    ld   ord_changed >> 8, y
    jmp  ord_changed
oh_end:
    ld   OD_END, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  oh_e
    ld   OD_TGT, x
    ld   [y,x], ac
    shl
    shl
    shl
    shl
    or   [w2], ac
    and  0x3F, ac
    ld   ac, [u0]
    sub  [w3], ac
    bcs  oh_t
    clr  ac
    ld   ac, [u0]
oh_t:
    ld   [u0], ac
    ld   ac, [y,x]
    ld   ord_changed >> 8, y
    jmp  ord_changed
oh_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ord_trans - AC = +1 / -1 on the transpose (-32..31)

#addr 0x2600
edit_cell:
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
    ld   [c_v], ac
    ld   LINK_LO, x             ; CALL pat_of
    ld   tr_r227, [x]
    ld   LINK_HI, x
    ld   tr_r227 >> 8, [x]
    ld   pat_of >> 8, y
    jmp  pat_of
tr_r227:
    ld   ac, [w0]
    xor  0xFF, ac
    bne  edc_a
    ld   s_nopat2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_nopat2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r228, [x]
    ld   LINK_HI, x
    ld   tr_r228 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r228:
    ld   tr_leave >> 8, y
    jmp  tr_leave
edc_a:
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL need
    ld   tr_r229, [x]
    ld   LINK_HI, x
    ld   tr_r229 >> 8, [x]
    ld   need >> 8, y
    jmp  need
tr_r229:
    ld   [c_row], ac
    sub  [p_len], ac
    bcs  edc_b
    ld   s_pastend & 0xFF, ac
    ld   ac, [R0]
    ld   s_pastend >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r230, [x]
    ld   LINK_HI, x
    ld   tr_r230 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r230:
    ld   tr_leave >> 8, y
    jmp  tr_leave
edc_b:
    ld   [c_row], ac
    shl
    shl
    ld   ac, [w1]               ; the row's first byte
    ld   [c_col], ac
    bne  edc_c
    ld   edit_note >> 8, y
    jmp  edit_note
edc_c:
    ld   [e_key], ac            ; the other columns: hex digits, Del
    xor  0x7F, ac
    beq  edc_del
    ld   [e_key], ac
    xor  0x08, ac
    beq  edc_del
    ld   [e_key], ac
    ld   LINK_LO, x             ; CALL hexval
    ld   tr_r231, [x]
    ld   LINK_HI, x
    ld   tr_r231 >> 8, [x]
    ld   hexval >> 8, y
    jmp  hexval
tr_r231:
    ld   ac, [w2]
    xor  0xFF, ac
    beq  edc_e
    ld   edit_hex >> 8, y
    jmp  edit_hex
edc_del:
    ld   edit_del >> 8, y
    jmp  edit_del
edc_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; the note column: the piano keys, 1 = key off, Del
ins_field:
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
    ld   ac, [w4]
    clr  ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r261, [x]
    ld   LINK_HI, x
    ld   tr_r261 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r261:
    ld   [w4], ac
    ld   ac, [i_f]
    clr  ac
    ld   ac, [i_np]
    ld   TINT_BLUE, ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r262, [x]
    ld   LINK_HI, x
    ld   tr_r262 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r262:
    ld   [e_dirty], ac
    or   0x04, ac
    ld   ac, [e_dirty]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ikind - the field i_f: u0 = its byte offset, u1 = its kind (0 high
; nibble, 1 low nibble, 2 byte, 3 bit 0)

; ins_adj - AC = +1 / -1 on the field
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
edit_note:
    ld   [e_key], ac
    xor  0x31, ac
    bne  edn_a
    ld   SCRATCH >> 8, y
    ld   [w1], x
    ld   0x60, [y,x]
    ld   commit_adv >> 8, y
    jmp  commit_adv
edn_a:
    ld   [e_key], ac
    xor  0x7F, ac
    beq  edn_del
    ld   [e_key], ac
    xor  0x08, ac
    beq  edn_del
    ld   [e_key], ac
    ld   LINK_LO, x             ; CALL piano
    ld   tr_r232, [x]
    ld   LINK_HI, x
    ld   tr_r232 >> 8, [x]
    ld   piano >> 8, y
    jmp  piano
tr_r232:
    ld   ac, [w2]
    xor  0xFF, ac
    beq  edn_e
    ld   [e_oct], ac
    shl
    add  [e_oct], ac
    shl
    shl
    add  [w2], ac               ; 12 x octave + semitone
    ld   ac, [w2]
    sub  96, ac
    bcs  edn_ok
    ld   s_high & 0xFF, ac
    ld   ac, [R0]
    ld   s_high >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r233, [x]
    ld   LINK_HI, x
    ld   tr_r233 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r233:
    ld   tr_leave >> 8, y
    jmp  tr_leave
edn_ok:
    ld   SCRATCH >> 8, y
    ld   [w1], x
    ld   [w2], ac
    ld   ac, [y,x]
    ld   [w1], ac
    inc
    ld   ac, x
    ld   [e_ins], ac
    ld   ac, [y,x]
    ld   [e_play], ac           ; hear it when the song is not playing
    bne  edn_c
    ld   [e_ins], ac
    ld   ac, [R0]
    ld   20, ac
    ld   ac, [R1]
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL mus_sfx
    ld   tr_r234, [x]
    ld   LINK_HI, x
    ld   tr_r234 >> 8, [x]
    ld   mus_sfx >> 8, y
    jmp  mus_sfx
tr_r234:
edn_c:
    ld   commit_adv >> 8, y
    jmp  commit_adv
edn_del:
    ld   SCRATCH >> 8, y
    ld   [w1], x
    ld   0x61, [y,x]
    ld   [w1], ac
    inc
    ld   ac, x
    ld   0xFF, [y,x]
    ld   commit >> 8, y
    jmp  commit
edn_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; a hex digit (w2) into the instrument or effect columns
key_ord2:
    ld   [e_key], ac
    xor  0x5B, ac
    bne  ko2_1
    ld   0xFF, ac
    ld   ord_trans >> 8, y
    jmp  ord_trans
ko2_1:
    ld   [e_key], ac
    xor  0x5D, ac
    bne  ko2_2
    ld   1, ac
    ld   ord_trans >> 8, y
    jmp  ord_trans
ko2_2:
    ld   [e_key], ac
    xor  0x69, ac
    bne  ko2_3
    ld   ord_insert >> 8, y
    jmp  ord_insert
ko2_3:
    ld   [e_key], ac
    xor  0x7F, ac
    beq  ko2_del
    ld   [e_key], ac
    xor  0x08, ac
    bne  ko2_4
ko2_del:
    ld   ord_delete >> 8, y
    jmp  ord_delete
ko2_4:
    ld   [e_key], ac
    xor  0x6C, ac
    bne  ko2_5
    ld   0xFF, ac
    ld   ord_end >> 8, y
    jmp  ord_end
ko2_5:
    ld   [e_key], ac
    xor  0x73, ac
    bne  ko2_6
    ld   0xFE, ac
    ld   ord_end >> 8, y
    jmp  ord_end
ko2_6:
    ld   [e_key], ac
    ld   LINK_LO, x             ; CALL hexval
    ld   tr_r252, [x]
    ld   LINK_HI, x
    ld   tr_r252 >> 8, [x]
    ld   hexval >> 8, y
    jmp  hexval
tr_r252:
    ld   ac, [w2]
    xor  0xFF, ac
    beq  ko2_e
    ld   ord_hex >> 8, y
    jmp  ord_hex
ko2_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ord_hex - the digit w2 into the pattern number, or the loop target on
; the end row

#addr 0x2800
edit_hex:
    ld   SCRATCH >> 8, y
    ld   [c_col], ac
    xor  3, ac
    beq  eh_fx
    ld   [c_col], ac
    sub  4, ac
    bcc  eh_par
    ld   [w1], ac               ; the instrument: 1 = high nibble (0-1), 2 = low
    inc
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  eh_i1
    clr  ac
    ld   ac, [y,x]
eh_i1:
    ld   [c_col], ac
    xor  1, ac
    bne  eh_i2
    ld   [w2], ac
    and  1, ac
    shl
    shl
    shl
    shl
    ld   ac, [w3]
    ld   [y,x], ac
    and  0x0F, ac
    or   [w3], ac
    ld   ac, [y,x]
    ld   commit >> 8, y
    jmp  commit
eh_i2:
    ld   [y,x], ac
    and  0x10, ac
    or   [w2], ac
    ld   ac, [y,x]
    ld   commit >> 8, y
    jmp  commit
eh_fx:
    ld   [w1], ac
    add  2, ac
    ld   ac, x
    ld   [w2], ac
    ld   ac, [y,x]
    ld   commit >> 8, y
    jmp  commit
eh_par:
    ld   [w1], ac               ; the parameter: an effect 0 when none yet
    add  2, ac
    ld   ac, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  eh_p1
    clr  ac
    ld   ac, [y,x]
eh_p1:
    ld   [w1], ac
    add  3, ac
    ld   ac, x
    ld   [c_col], ac
    xor  4, ac
    bne  eh_p2
    ld   [w2], ac
    shl
    shl
    shl
    shl
    ld   ac, [w3]
    ld   [y,x], ac
    and  0x0F, ac
    or   [w3], ac
    ld   ac, [y,x]
    ld   commit >> 8, y
    jmp  commit
eh_p2:
    ld   [y,x], ac
    and  0xF0, ac
    or   [w2], ac
    ld   ac, [y,x]
    ld   commit >> 8, y
    jmp  commit

; Del in the instrument or effect columns
ord_move:
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
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r249, [x]
    ld   LINK_HI, x
    ld   tr_r249 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r249:
    clr  ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r250, [x]
    ld   LINK_HI, x
    ld   tr_r250 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r250:
    ld   [w4], ac
    ld   ac, [o_k]
    ld   ac, [e_op]
    sub  [e_otop], ac
    bcs  om_up
    sub  ORD_ROWS, ac
    bcs  om_ok
    ld   [o_k], ac
    sub  ORD_ROWS - 1, ac
    ld   ac, [e_otop]
    bra  om_ok
om_up:
    ld   [o_k], ac
    ld   ac, [e_otop]
om_ok:
    ld   [e_dirty], ac
    or   0x23, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   TINT_BLUE, ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r251, [x]
    ld   LINK_HI, x
    ld   tr_r251 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r251:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; the orderlist's editing keys: hex digits, [ ], i, Del, l, s
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

#addr 0x2900
commit_adv:
    ld   LINK_LO, x             ; CALL encode_pat
    ld   tr_r235, [x]
    ld   LINK_HI, x
    ld   tr_r235 >> 8, [x]
    ld   encode_pat >> 8, y
    jmp  encode_pat
tr_r235:
    bne  cm_full
    ld   [c_row], ac
    ld   LINK_LO, x             ; CALL draw_row
    ld   tr_r236, [x]
    ld   LINK_HI, x
    ld   tr_r236 >> 8, [x]
    ld   draw_row >> 8, y
    jmp  draw_row
tr_r236:
    ld   [c_row], ac
    xor  63, ac
    beq  cm_s
    ld   [c_row], ac
    inc
    ld   LINK_LO, x             ; CALL move_row
    ld   tr_r237, [x]
    ld   LINK_HI, x
    ld   tr_r237 >> 8, [x]
    ld   move_row >> 8, y
    jmp  move_row
tr_r237:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cm_s:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r238, [x]
    ld   LINK_HI, x
    ld   tr_r238 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r238:
    ld   tr_leave >> 8, y
    jmp  tr_leave
commit:
    ld   LINK_LO, x             ; CALL encode_pat
    ld   tr_r239, [x]
    ld   LINK_HI, x
    ld   tr_r239 >> 8, [x]
    ld   encode_pat >> 8, y
    jmp  encode_pat
tr_r239:
    bne  cm_full
    ld   [c_row], ac
    ld   LINK_LO, x             ; CALL draw_row
    ld   tr_r240, [x]
    ld   LINK_HI, x
    ld   tr_r240 >> 8, [x]
    ld   draw_row >> 8, y
    jmp  draw_row
tr_r240:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r241, [x]
    ld   LINK_HI, x
    ld   tr_r241 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r241:
    ld   tr_leave >> 8, y
    jmp  tr_leave
cm_full:
    ld   0xFF, ac               ; the slot is as it was: decode it again
    ld   ac, [p_pat]
    ld   s_full & 0xFF, ac
    ld   ac, [R0]
    ld   s_full >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r242, [x]
    ld   LINK_HI, x
    ld   tr_r242 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r242:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; key_ord - the orderlist pane
; ------------------------------------------------------------
ord_insert:
    ld   [w3], ac
    xor  OD_MAX, ac
    beq  oi_e
    ld   [o_v], ac
    add  VSPAGE, y
    ld   [w3], ac               ; from the last down to o_k: entry k+1 = entry k
    ld   ac, [u0]
oi_l:
    ld   [u0], ac
    xor  [o_k], ac
    beq  oi_d
    ld   [u0], ac
    dec
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    dec
    shl
    add  OD_TR, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u0], ac
    shl
    add  OD_PAT, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   [u0], ac
    shl
    add  OD_TR, x
    ld   [u2], ac
    ld   ac, [y,x]
    ld   [u0], ac
    dec
    ld   ac, [u0]
    bra  oi_l
oi_d:
    ld   [o_k], ac
    shl
    add  OD_PAT, x
    ld   0, [y,x]
    ld   [o_k], ac
    shl
    add  OD_TR, x
    ld   0, [y,x]
    ld   OD_LEN, x
    ld   [w3], ac
    inc
    ld   ac, [y,x]
    ld   ac, [w3]
    ld   ord_changed >> 8, y
    jmp  ord_changed
oi_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ord_delete - the position at the cursor

#addr 0x2A00
key_ord:
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
    ld   [o_v], ac
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [y,x], ac
    ld   ac, [w3]               ; the voice's positions
    ld   [e_key], ac
    xor  0x11, ac
    bne  ko_1
    ld   [o_k], ac
    beq  ko_e
    dec
    ld   LINK_LO, x             ; CALL ord_move
    ld   tr_r243, [x]
    ld   LINK_HI, x
    ld   tr_r243 >> 8, [x]
    ld   ord_move >> 8, y
    jmp  ord_move
tr_r243:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ko_1:
    ld   [e_key], ac
    xor  0x12, ac
    bne  ko_2
    ld   [o_k], ac
    xor  [w3], ac
    beq  ko_e
    ld   [o_k], ac
    inc
    ld   LINK_LO, x             ; CALL ord_move
    ld   tr_r244, [x]
    ld   LINK_HI, x
    ld   tr_r244 >> 8, [x]
    ld   ord_move >> 8, y
    jmp  ord_move
tr_r244:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ko_2:
    ld   [e_key], ac
    xor  0x13, ac
    bne  ko_3
    ld   [o_v], ac
    shl
    add  [o_f], ac
    beq  ko_e
    dec
    ld   LINK_LO, x             ; CALL ord_field
    ld   tr_r245, [x]
    ld   LINK_HI, x
    ld   tr_r245 >> 8, [x]
    ld   ord_field >> 8, y
    jmp  ord_field
tr_r245:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ko_3:
    ld   [e_key], ac
    xor  0x14, ac
    bne  ko_4
    ld   [o_v], ac
    shl
    add  [o_f], ac
    xor  7, ac
    beq  ko_e
    ld   [o_v], ac
    shl
    add  [o_f], ac
    inc
    ld   LINK_LO, x             ; CALL ord_field
    ld   tr_r246, [x]
    ld   LINK_HI, x
    ld   tr_r246 >> 8, [x]
    ld   ord_field >> 8, y
    jmp  ord_field
tr_r246:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ko_4:
    ld   key_ord2 >> 8, y
    jmp  key_ord2
ko_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ord_field - the order cursor to field AC (2 voice + field)
tab_move:
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
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r279, [x]
    ld   LINK_HI, x
    ld   tr_r279 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r279:
    clr  ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r280, [x]
    ld   LINK_HI, x
    ld   tr_r280 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r280:
    ld   [w4], ac
    ld   ac, [t_e]
    ld   TINT_BLUE, ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL pane_tint
    ld   tr_r281, [x]
    ld   LINK_HI, x
    ld   tr_r281 >> 8, [x]
    ld   pane_tint >> 8, y
    jmp  pane_tint
tr_r281:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r282, [x]
    ld   LINK_HI, x
    ld   tr_r282 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r282:
    ld   tr_leave >> 8, y
    jmp  tr_leave


#addr 0x2B00
ord_delete:
    ld   [o_k], ac
    xor  [w3], ac
    beq  od_e
    ld   [o_v], ac
    add  VSPAGE, y
    ld   [o_k], ac
    ld   ac, [u0]
od_l:
    ld   [u0], ac
    inc
    xor  [w3], ac
    beq  od_d
    ld   [u0], ac
    inc
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    inc
    shl
    add  OD_TR, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u0], ac
    shl
    add  OD_PAT, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   [u0], ac
    shl
    add  OD_TR, x
    ld   [u2], ac
    ld   ac, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    bra  od_l
od_d:
    ld   OD_LEN, x
    ld   [w3], ac
    dec
    ld   ac, [y,x]
    ld   ac, [w3]
    ld   OD_TGT, x
    ld   [y,x], ac
    sub  [w3], ac
    bcs  od_t
    ld   OD_TGT, x
    ld   0, [y,x]
od_t:
    ld   ord_changed >> 8, y
    jmp  ord_changed
od_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ord_changed - voice o_v's list encoded again, the block drawn again
; (and the grid when the position shown changed)
ins_adj:
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
    ld   ac, [w0]
    ld   [i_f], ac
    shl
    add  ikinds & 0xFF, x
    ld   ikinds >> 8, y
    ld   [y,x], ac
    ld   ac, [u0]
    ld   [i_f], ac
    shl
    add  (ikinds + 1) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    ld   LINK_LO, x             ; CALL ins_byte
    ld   tr_r263, [x]
    ld   LINK_HI, x
    ld   tr_r263 >> 8, [x]
    ld   ins_byte >> 8, y
    jmp  ins_byte
tr_r263:
    ld   ac, [w1]
    ld   [u1], ac
    bne  iad_1
    ld   [w1], ac               ; the high nibble
    and  0x0F, ac
    ld   ac, [w3]
    ld   [w1], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  [w0], ac
    shl
    shl
    shl
    shl
    or   [w3], ac
    bra  iad_w
iad_1:
    ld   [u1], ac
    xor  1, ac
    bne  iad_2
    ld   [w1], ac               ; the low nibble
    add  [w0], ac
    and  0x0F, ac
    ld   ac, [w3]
    ld   [w1], ac
    and  0xF0, ac
    or   [w3], ac
    bra  iad_w
iad_2:
    ld   [u1], ac
    xor  2, ac
    bne  iad_3
    ld   [w1], ac               ; the byte
    add  [w0], ac
    bra  iad_w
iad_3:
    ld   [w1], ac               ; the bit
    xor  1, ac
iad_w:
    ld   ac, [w1]
    ld   [u0], ac
    ld   LINK_LO, x             ; CALL ins_addr
    ld   tr_r264, [x]
    ld   LINK_HI, x
    ld   tr_r264 >> 8, [x]
    ld   ins_addr >> 8, y
    jmp  ins_addr
tr_r264:
    ld   [w1], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL ins_changed
    ld   tr_r265, [x]
    ld   LINK_HI, x
    ld   tr_r265 >> 8, [x]
    ld   ins_changed >> 8, y
    jmp  ins_changed
tr_r265:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ins_digit - the hex digit w2 into the field

#addr 0x2C00
key_ins:
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
    ld   [e_key], ac
    xor  0x11, ac
    bne  ki_1
    ld   [i_f], ac
    beq  ki_e
    dec
    ld   LINK_LO, x             ; CALL ins_field
    ld   tr_r254, [x]
    ld   LINK_HI, x
    ld   tr_r254 >> 8, [x]
    ld   ins_field >> 8, y
    jmp  ins_field
tr_r254:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ki_1:
    ld   [e_key], ac
    xor  0x12, ac
    bne  ki_2
    ld   [i_f], ac
    xor  11, ac
    beq  ki_e
    ld   [i_f], ac
    inc
    ld   LINK_LO, x             ; CALL ins_field
    ld   tr_r255, [x]
    ld   LINK_HI, x
    ld   tr_r255 >> 8, [x]
    ld   ins_field >> 8, y
    jmp  ins_field
tr_r255:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ki_2:
    ld   [i_f], ac
    xor  11, ac
    beq  ki_name
    ld   [e_key], ac
    xor  0x5B, ac
    bne  ki_3
    ld   0xFF, ac
    ld   LINK_LO, x             ; CALL ins_adj
    ld   tr_r256, [x]
    ld   LINK_HI, x
    ld   tr_r256 >> 8, [x]
    ld   ins_adj >> 8, y
    jmp  ins_adj
tr_r256:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ki_3:
    ld   [e_key], ac
    xor  0x5D, ac
    bne  ki_4
    ld   1, ac
    ld   LINK_LO, x             ; CALL ins_adj
    ld   tr_r257, [x]
    ld   LINK_HI, x
    ld   tr_r257 >> 8, [x]
    ld   ins_adj >> 8, y
    jmp  ins_adj
tr_r257:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ki_4:
    ld   [e_key], ac
    ld   LINK_LO, x             ; CALL hexval
    ld   tr_r258, [x]
    ld   LINK_HI, x
    ld   tr_r258 >> 8, [x]
    ld   hexval >> 8, y
    jmp  hexval
tr_r258:
    ld   ac, [w2]
    xor  0xFF, ac
    beq  ki_e
    ld   LINK_LO, x             ; CALL ins_digit
    ld   tr_r259, [x]
    ld   LINK_HI, x
    ld   tr_r259 >> 8, [x]
    ld   ins_digit >> 8, y
    jmp  ins_digit
tr_r259:
    ld   tr_leave >> 8, y
    jmp  tr_leave
ki_name:
    ld   LINK_LO, x             ; CALL ins_name
    ld   tr_r260, [x]
    ld   LINK_HI, x
    ld   tr_r260 >> 8, [x]
    ld   ins_name >> 8, y
    jmp  ins_name
tr_r260:
ki_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ins_field - the cursor to field AC
tab_side:
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
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r283, [x]
    ld   LINK_HI, x
    ld   tr_r283 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r283:
    ld   [w4], ac
    ld   ac, [t_f]
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r284, [x]
    ld   LINK_HI, x
    ld   tr_r284 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r284:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; tab_addr - Y:X = the byte under the table cursor


#addr 0x2D00
ins_digit:
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
    ld   [i_f], ac
    shl
    add  ikinds & 0xFF, x
    ld   ikinds >> 8, y
    ld   [y,x], ac
    ld   ac, [u0]
    ld   [i_f], ac
    shl
    add  (ikinds + 1) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    ld   LINK_LO, x             ; CALL ins_byte
    ld   tr_r266, [x]
    ld   LINK_HI, x
    ld   tr_r266 >> 8, [x]
    ld   ins_byte >> 8, y
    jmp  ins_byte
tr_r266:
    ld   ac, [w1]
    ld   [u1], ac
    bne  id_1
    ld   [w2], ac
    shl
    shl
    shl
    shl
    ld   ac, [w3]
    ld   [w1], ac
    and  0x0F, ac
    or   [w3], ac
    bra  id_w
id_1:
    ld   [u1], ac
    xor  1, ac
    bne  id_2
    ld   [w1], ac
    and  0xF0, ac
    or   [w2], ac
    bra  id_w
id_2:
    ld   [u1], ac
    xor  2, ac
    bne  id_3
    ld   [w1], ac
    shl
    shl
    shl
    shl
    or   [w2], ac
    bra  id_w
id_3:
    ld   [w2], ac
    and  1, ac
id_w:
    ld   ac, [w1]
    ld   [u0], ac
    ld   LINK_LO, x             ; CALL ins_addr
    ld   tr_r267, [x]
    ld   LINK_HI, x
    ld   tr_r267 >> 8, [x]
    ld   ins_addr >> 8, y
    jmp  ins_addr
tr_r267:
    ld   [w1], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL ins_changed
    ld   tr_r268, [x]
    ld   LINK_HI, x
    ld   tr_r268 >> 8, [x]
    ld   ins_changed >> 8, y
    jmp  ins_changed
tr_r268:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ins_name - a character into the name (Backspace takes one back)
tab_adj:
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
    ld   ac, [w0]
    ld   (SONG >> 8) + 1, y
    ld   [e_pane], ac
    xor  4, ac
    bne  tad_w44
    ld   0x80, ac
    bra  tad_s44
tad_w44:
    clr  ac
tad_s44:
    ld   ac, [u2]
    ld   [t_f], ac
    beq  tad_l44
    ld   [u2], ac
    add  0x40, ac
    ld   ac, [u2]
tad_l44:
    ld   [u2], ac
    add  [t_e], ac
    ld   ac, x
    ld   [y,x], ac
    add  [w0], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL tab_changed
    ld   tr_r285, [x]
    ld   LINK_HI, x
    ld   tr_r285 >> 8, [x]
    ld   tab_changed >> 8, y
    jmp  tab_changed
tr_r285:
    ld   tr_leave >> 8, y
    jmp  tr_leave

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

#addr 0x2E00
ins_name:
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
    ld   [e_key], ac
    xor  0x08, ac
    bne  in_c
    ld   [i_np], ac
    beq  in_e
    dec
    ld   ac, [i_np]
    ld   0x20, ac
    bra  in_w
in_c:
    ld   [e_key], ac
    sub  0x20, ac
    blt  in_e
    ld   [e_key], ac
    sub  0x61, ac               ; a-z -> A-Z
    blt  in_p
    sub  26, ac
    bcc  in_p
    ld   [e_key], ac
    and  0xDF, ac
    ld   ac, [e_key]
in_p:
    ld   [i_np], ac
    xor  7, ac
    beq  in_e
    ld   [e_key], ac
in_w:
    ld   ac, [w1]
    ld   [i_np], ac
    add  I_NAME, ac
    ld   LINK_LO, x             ; CALL ins_addr
    ld   tr_r269, [x]
    ld   LINK_HI, x
    ld   tr_r269 >> 8, [x]
    ld   ins_addr >> 8, y
    jmp  ins_addr
tr_r269:
    ld   [w1], ac
    ld   ac, [y,x]
    ld   [e_key], ac
    xor  0x08, ac
    beq  in_d
    ld   [i_np], ac
    inc
    ld   ac, [i_np]
in_d:
    ld   LINK_LO, x             ; CALL ins_changed
    ld   tr_r270, [x]
    ld   LINK_HI, x
    ld   tr_r270 >> 8, [x]
    ld   ins_changed >> 8, y
    jmp  ins_changed
tr_r270:
in_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

tab_digit:
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
    ld   (SONG >> 8) + 1, y
    ld   [e_pane], ac
    xor  4, ac
    bne  tad_w45
    ld   0x80, ac
    bra  tad_s45
tad_w45:
    clr  ac
tad_s45:
    ld   ac, [u2]
    ld   [t_f], ac
    beq  tad_l45
    ld   [u2], ac
    add  0x40, ac
    ld   ac, [u2]
tad_l45:
    ld   [u2], ac
    add  [t_e], ac
    ld   ac, x
    ld   [y,x], ac
    shl
    shl
    shl
    shl
    or   [w2], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL tab_changed
    ld   tr_r286, [x]
    ld   LINK_HI, x
    ld   tr_r286 >> 8, [x]
    ld   tab_changed >> 8, y
    jmp  tab_changed
tr_r286:
    ld   tr_leave >> 8, y
    jmp  tr_leave

tab_changed:
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
    ld   ac, [e_mod]
    ld   [t_e], ac
    ld   LINK_LO, x             ; CALL draw_tentry
    ld   tr_r287, [x]
    ld   LINK_HI, x
    ld   tr_r287 >> 8, [x]
    ld   draw_tentry >> 8, y
    jmp  draw_tentry
tr_r287:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r288, [x]
    ld   LINK_HI, x
    ld   tr_r288 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r288:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ============================================================
; playing
; ============================================================

; do_play - AC = the order position to start at

#addr 0x2F00
key_tab:
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
    ld   [e_key], ac
    xor  0x11, ac
    bne  kt_1
    ld   [t_e], ac
    xor  1, ac
    beq  kt_e
    ld   [t_e], ac
    dec
    ld   LINK_LO, x             ; CALL tab_move
    ld   tr_r271, [x]
    ld   LINK_HI, x
    ld   tr_r271 >> 8, [x]
    ld   tab_move >> 8, y
    jmp  tab_move
tr_r271:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kt_1:
    ld   [e_key], ac
    xor  0x12, ac
    bne  kt_2
    ld   [t_e], ac
    xor  63, ac
    beq  kt_e
    ld   [t_e], ac
    inc
    ld   LINK_LO, x             ; CALL tab_move
    ld   tr_r272, [x]
    ld   LINK_HI, x
    ld   tr_r272 >> 8, [x]
    ld   tab_move >> 8, y
    jmp  tab_move
tr_r272:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kt_2:
    ld   [e_key], ac
    xor  0x13, ac
    bne  kt_3
    clr  ac
    ld   LINK_LO, x             ; CALL tab_side
    ld   tr_r273, [x]
    ld   LINK_HI, x
    ld   tr_r273 >> 8, [x]
    ld   tab_side >> 8, y
    jmp  tab_side
tr_r273:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kt_3:
    ld   [e_key], ac
    xor  0x14, ac
    bne  kt_4
    ld   1, ac
    ld   LINK_LO, x             ; CALL tab_side
    ld   tr_r274, [x]
    ld   LINK_HI, x
    ld   tr_r274 >> 8, [x]
    ld   tab_side >> 8, y
    jmp  tab_side
tr_r274:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kt_4:
    ld   [e_key], ac
    xor  0x5B, ac
    bne  kt_5
    ld   0xFF, ac
    ld   LINK_LO, x             ; CALL tab_adj
    ld   tr_r275, [x]
    ld   LINK_HI, x
    ld   tr_r275 >> 8, [x]
    ld   tab_adj >> 8, y
    jmp  tab_adj
tr_r275:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kt_5:
    ld   [e_key], ac
    xor  0x5D, ac
    bne  kt_6
    ld   1, ac
    ld   LINK_LO, x             ; CALL tab_adj
    ld   tr_r276, [x]
    ld   LINK_HI, x
    ld   tr_r276 >> 8, [x]
    ld   tab_adj >> 8, y
    jmp  tab_adj
tr_r276:
    ld   tr_leave >> 8, y
    jmp  tr_leave
kt_6:
    ld   [e_key], ac
    ld   LINK_LO, x             ; CALL hexval
    ld   tr_r277, [x]
    ld   LINK_HI, x
    ld   tr_r277 >> 8, [x]
    ld   hexval >> 8, y
    jmp  hexval
tr_r277:
    ld   ac, [w2]
    xor  0xFF, ac
    beq  kt_e
    ld   LINK_LO, x             ; CALL tab_digit
    ld   tr_r278, [x]
    ld   LINK_HI, x
    ld   tr_r278 >> 8, [x]
    ld   tab_digit >> 8, y
    jmp  tab_digit
tr_r278:
kt_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

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


#addr 0x3000
do_play:
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
    ld   ac, [w0]
    clr  ac
    ld   LINK_LO, x             ; CALL mus_play
    ld   tr_r289, [x]
    ld   LINK_HI, x
    ld   tr_r289 >> 8, [x]
    ld   mus_play >> 8, y
    jmp  mus_play
tr_r289:
    ld   [w0], ac
    beq  dpl_s
    clr  ac                     ; each voice's orderlist pointer to the position
    ld   ac, [w1]
dpl_v:
    ld   [w1], ac
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [w0], ac
    sub  [y,x], ac
    bcs  dpl_k
    ld   [y,x], ac              ; past its end: the end
    bra  dpl_k2
dpl_k:
    ld   [w0], ac
dpl_k2:
    add  OD_OFF, x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   [w1], ac
    shl
    shl
    shl
    shl
    shl
    shl
    add  [w2], ac
    ld   ac, [w2]
    ld   W_OLL, x
    ld   [w2], ac
    ld   ac, [y,x]
    ld   [w1], ac
    inc
    ld   ac, [w1]
    xor  4, ac
    bne  dpl_v
dpl_s:
    ld   1, ac
    ld   ac, [e_play]
    ld   0xFF, ac
    ld   ac, [e_plop]
    ld   ac, [e_plrow]
    ld   [e_dirty], ac
    or   0x08, ac
    ld   ac, [e_dirty]
    ld   tr_leave >> 8, y
    jmp  tr_leave

do_stop:
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
    ld   LINK_LO, x             ; CALL mus_stop
    ld   tr_r290, [x]
    ld   LINK_HI, x
    ld   tr_r290 >> 8, [x]
    ld   mus_stop >> 8, y
    jmp  mus_stop
tr_r290:
    clr  ac
    ld   ac, [e_play]
    ld   [e_plrow], ac          ; the green off
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r291, [x]
    ld   LINK_HI, x
    ld   tr_r291 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r291:
    ld   0xFF, ac
    ld   ac, [e_plop]
    ld   ac, [e_plrow]
    ld   [e_dirty], ac
    or   0x08, ac
    ld   ac, [e_dirty]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; follow - once a frame while playing: voice 1's position and row from
; the player's state; the grid follows them
; ------------------------------------------------------------
new_cmd:
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
    ld   LINK_LO, x             ; CALL do_stop
    ld   tr_r306, [x]
    ld   LINK_HI, x
    ld   tr_r306 >> 8, [x]
    ld   do_stop >> 8, y
    jmp  do_stop
tr_r306:
    ld   LINK_LO, x             ; CALL new_song
    ld   tr_r307, [x]
    ld   LINK_HI, x
    ld   tr_r307 >> 8, [x]
    ld   new_song >> 8, y
    jmp  new_song
tr_r307:
    ld   LINK_LO, x             ; CALL redraw_all
    ld   tr_r308, [x]
    ld   LINK_HI, x
    ld   tr_r308 >> 8, [x]
    ld   redraw_all >> 8, y
    jmp  redraw_all
tr_r308:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; new_song - a blank song: one instrument, a pattern per voice
; ------------------------------------------------------------

#addr 0x3100
follow:
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
    ld   [e_play], ac
    beq  fl_e
    ld   VSPAGE, y
    ld   W_STOP, x
    ld   [y,x], ac
    bne  fl_e
    ld   W_PPH, x
    ld   [y,x], ac
    beq  fl_e
    ld   W_OLL, x               ; which position: OD_OFF[j] = the pointer, j - 1
    ld   [y,x], ac
    ld   ac, [w0]
    ld   OD_LEN, x
    ld   [y,x], ac
    ld   ac, [w1]
    clr  ac
    ld   ac, [w2]
fl_j:
    ld   [w2], ac
    add  OD_OFF, x
    ld   [y,x], ac
    xor  [w0], ac
    beq  fl_f
    ld   [w2], ac
    xor  [w1], ac
    beq  fl_e
    ld   [w2], ac
    inc
    ld   ac, [w2]
    bra  fl_j
fl_f:
    ld   [w2], ac
    beq  fl_e
    dec
    ld   ac, [w2]               ; the position
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    ld   ac, [w3]               ; its pattern
    ld   W_PPL, x
    ld   [y,x], ac
    ld   ac, [w4]
    ld   W_EMPTY, x
    ld   [y,x], ac
    ld   ac, [w5]
    ld   follow2 >> 8, y
    jmp  follow2
fl_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; the row: the rows encoded before the pointer, less the empty ones
; still to come
follow2:
    ld   [w3], ac
    sub  CAP, ac
    bcc  fl2_e
    ld   [w3], ac
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [w4], ac
    sub  [u2], ac
    ld   ac, [w4]               ; the offset in the pattern
    clr  ac
    ld   ac, [u3]               ; bytes passed
    ld   ac, [u4]               ; rows
fl2_l:
    ld   [u3], ac
    sub  [w4], ac
    bcc  fl2_d
    ld   [u1], y
    ld   [u3], ac
    add  [u2], ac
    ld   ac, x
    ld   [u3], ac
    inc
    ld   ac, [u3]
    ld   [y,x], ac
    ld   ac, [u5]
    xor  0xFF, ac
    beq  fl2_d
    ld   [u5], ac
    sub  0xE0, ac
    bcc  fl2_fx
    ld   [u5], ac
    sub  0xC0, ac
    bcc  fl2_l
    ld   [u5], ac
    sub  0x80, ac
    bcc  fl2_run
    ld   [u4], ac
    inc
    ld   ac, [u4]
    bra  fl2_l
fl2_fx:
    ld   [u3], ac
    inc
    ld   ac, [u3]
    bra  fl2_l
fl2_run:
    and  0x3F, ac
    inc
    add  [u4], ac
    ld   ac, [u4]
    bra  fl2_l
fl2_d:
    ld   [u4], ac
    beq  fl2_0
    dec
    sub  [w5], ac
    blt  fl2_0
    bra  fl2_r
fl2_0:
    clr  ac
fl2_r:
    ld   ac, [w4]               ; the row
    ld   [w2], ac
    xor  [e_plop], ac
    bne  fl2_pos
    ld   [w4], ac
    xor  [e_plrow], ac
    bne  fl2_row
fl2_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave
fl2_pos:
    ld   follow_pos >> 8, y
    jmp  follow_pos
fl2_row:
    ld   follow_row >> 8, y
    jmp  follow_row

; a new position: the grid shows it

#addr 0x3200
follow_pos:
    ld   [w2], ac
    ld   ac, [e_plop]
    ld   [w4], ac
    ld   ac, [e_plrow]
    ld   [w2], ac
    xor  [e_op], ac
    bne  fp_new
    ld   follow_row2 >> 8, y    ; the same position shown already
    jmp  follow_row2
fp_new:
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r292, [x]
    ld   LINK_HI, x
    ld   tr_r292 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r292:
    ld   [w2], ac
    ld   ac, [e_op]
    ld   ac, [o_k]
    sub  [e_otop], ac
    bcs  fp_up
    sub  ORD_ROWS, ac
    bcs  fp_ok
    ld   [o_k], ac
    sub  ORD_ROWS - 1, ac
    ld   ac, [e_otop]
    bra  fp_ok
fp_up:
    ld   [o_k], ac
    ld   ac, [e_otop]
fp_ok:
    ld   [w4], ac
    ld   ac, [c_row]
    ld   LINK_LO, x             ; CALL scroll_to
    ld   tr_r293, [x]
    ld   LINK_HI, x
    ld   tr_r293 >> 8, [x]
    ld   scroll_to >> 8, y
    jmp  scroll_to
tr_r293:
    ld   [e_dirty], ac
    or   0x23, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; a new row in the position shown: the cursor follows
follow_row:
    ld   [e_plrow], ac
    ld   ac, [w3]               ; the old row
follow_row_b:
    ld   [w4], ac
    ld   ac, [e_plrow]
    ld   LINK_LO, x             ; CALL cursor_hide
    ld   tr_r294, [x]
    ld   LINK_HI, x
    ld   tr_r294 >> 8, [x]
    ld   cursor_hide >> 8, y
    jmp  cursor_hide
tr_r294:
    ld   [c_row], ac
    ld   ac, [w5]
    ld   [w4], ac
    ld   ac, [c_row]
    ld   LINK_LO, x             ; CALL scroll_to
    ld   tr_r295, [x]
    ld   LINK_HI, x
    ld   tr_r295 >> 8, [x]
    ld   scroll_to >> 8, y
    jmp  scroll_to
tr_r295:
    bne  fr_full
    ld   [w3], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r296, [x]
    ld   LINK_HI, x
    ld   tr_r296 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r296:
    ld   [w5], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r297, [x]
    ld   LINK_HI, x
    ld   tr_r297 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r297:
    ld   [c_row], ac
    ld   LINK_LO, x             ; CALL grid_tint
    ld   tr_r298, [x]
    ld   LINK_HI, x
    ld   tr_r298 >> 8, [x]
    ld   grid_tint >> 8, y
    jmp  grid_tint
tr_r298:
    ld   LINK_LO, x             ; CALL cursor_show
    ld   tr_r299, [x]
    ld   LINK_HI, x
    ld   tr_r299 >> 8, [x]
    ld   cursor_show >> 8, y
    jmp  cursor_show
tr_r299:
    ld   tr_leave >> 8, y
    jmp  tr_leave
fr_full:
    ld   [e_dirty], ac
    or   0x01, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
    ld   tr_leave >> 8, y
    jmp  tr_leave
follow_row2:
    ld   0xFF, ac
    ld   ac, [w3]
    bra  follow_row_b

; ============================================================
; commands
; ============================================================

; len_cmd - Ctrl-L: the pattern's length 64 > 16 > 32 > 64
prompt_done:
    ld   PTAB_PG, y             ; the name typed -> e_name, with a 00
    ld   [w0], ac
    add  0x90, x
    ld   0, [y,x]
    clr  ac
    ld   ac, [w1]
pd_l:
    ld   [w1], ac
    add  0x90, x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   [w1], ac
    add  e_name, x
    ld   [w2], ac
    ld   ac, [x]
    ld   [w1], ac
    inc
    ld   ac, [w1]
    xor  13, ac
    bne  pd_l
    ld   LINK_LO, x             ; CALL status_clear
    ld   tr_r336, [x]
    ld   LINK_HI, x
    ld   tr_r336 >> 8, [x]
    ld   status_clear >> 8, y
    jmp  status_clear
tr_r336:
    clr  ac
    ld   tr_leave >> 8, y
    jmp  tr_leave

; copy_name - the string at R1:R0 -> e_name (13 bytes)
len_cmd:
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
    ld   [e_pane], ac
    bne  lc_e
    ld   [c_v], ac
    ld   LINK_LO, x             ; CALL pat_of
    ld   tr_r300, [x]
    ld   LINK_HI, x
    ld   tr_r300 >> 8, [x]
    ld   pat_of >> 8, y
    jmp  pat_of
tr_r300:
    ld   ac, [w0]
    xor  0xFF, ac
    beq  lc_e
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL need
    ld   tr_r301, [x]
    ld   LINK_HI, x
    ld   tr_r301 >> 8, [x]
    ld   need >> 8, y
    jmp  need
tr_r301:
    ld   [p_len], ac
    xor  64, ac
    bne  lc_1
    ld   16, ac
    bra  lc_s
lc_1:
    ld   [p_len], ac
    xor  16, ac
    bne  lc_2
    ld   32, ac
    bra  lc_s
lc_2:
    ld   64, ac
lc_s:
    ld   ac, [p_len]
    ld   LINK_LO, x             ; CALL encode_pat
    ld   tr_r302, [x]
    ld   LINK_HI, x
    ld   tr_r302 >> 8, [x]
    ld   encode_pat >> 8, y
    jmp  encode_pat
tr_r302:
    ld   [e_dirty], ac
    or   0x21, ac
    ld   ac, [e_dirty]
    clr  ac
    ld   ac, [e_drow]
lc_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; exit_cmd - Ctrl-X: back to the DOS (twice when the song is not saved)
exit_cmd:
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
    ld   [e_mod], ac
    beq  xc_go
    ld   [e_fl], ac
    and  1, ac
    bne  xc_go
    ld   [e_fl], ac
    or   1, ac
    ld   ac, [e_fl]
    ld   s_unsaved & 0xFF, ac
    ld   ac, [R0]
    ld   s_unsaved >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r303, [x]
    ld   LINK_HI, x
    ld   tr_r303 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r303:
    ld   tr_leave >> 8, y
    jmp  tr_leave
xc_go:
    ld   LINK_LO, x             ; CALL mus_stop
    ld   tr_r304, [x]
    ld   LINK_HI, x
    ld   tr_r304 >> 8, [x]
    ld   mus_stop >> 8, y
    jmp  mus_stop
tr_r304:
    clr  ac
    ld   LINK_LO, x             ; CALL l_vid_clear
    ld   tr_r305, [x]
    ld   LINK_HI, x
    ld   tr_r305 >> 8, [x]
    ld   l_vid_clear >> 8, y
    jmp  l_vid_clear
tr_r305:
    ld   exit_dos >> 8, y
    jmp  exit_dos

; new_cmd - Ctrl-N: a blank song
s_pulse:
    #d "PULSE  "
hexdig:
    #d "0123456789ABCDEF"
notes:
    #d "C-C#D-D#E-F-F#G-G#A-A#B-"
ramsl:
    #d8 0x57, 0x58, 0x59, 0x5C
ccol:
    #d8 0, 4, 5, 7, 8, 9


#addr 0x3400
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

#overlay 0xA800
new_song:
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
    ld   LINK_LO, x             ; CALL mus_stop
    ld   tr_r309, [x]
    ld   LINK_HI, x
    ld   tr_r309 >> 8, [x]
    ld   mus_stop >> 8, y
    jmp  mus_stop
tr_r309:
    ld   SONG >> 8, ac
    ld   ac, [w0]
ns_p:
    ld   [w0], y
    clr  ac
ns_b:
    ld   ac, x
    ld   0x00, [y,x]
    inc
    bne  ns_b
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  (SONG >> 8) + 5, ac
    bne  ns_p
    ld   SONG >> 8, y
    ld   0x00, x
    ld   0x50, [y,x]
    ld   0x01, x
    ld   0x4D, [y,x]
    ld   0x02, x
    ld   0x55, [y,x]
    ld   0x03, x
    ld   0x01, [y,x]
    ld   0x05, x
    ld   4, [y,x]
    ld   0x06, x
    ld   1, [y,x]
    ld   0x40, x
    ld   6, [y,x]
    ld   0x20, ac               ; the title
    ld   ac, [w0]
ns_t:
    ld   [w0], ac
    sub  0x20, ac
    add  s_newsong & 0xFF, x
    ld   s_newsong >> 8, y
    ld   [y,x], ac
    ld   SONG >> 8, y
    ld   [w0], x
    ld   ac, [y,x]
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  0x40, ac
    bne  ns_t
    ld   new_song2 >> 8, y
    jmp  new_song2

song_ready:
    ld   LINK_LO, x             ; CALL set_offsets
    ld   tr_r312, [x]
    ld   LINK_HI, x
    ld   tr_r312 >> 8, [x]
    ld   set_offsets >> 8, y
    jmp  set_offsets
tr_r312:
    ld   SONG >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL mus_init
    ld   tr_r313, [x]
    ld   LINK_HI, x
    ld   tr_r313 >> 8, [x]
    ld   mus_init >> 8, y
    jmp  mus_init
tr_r313:
    clr  ac
    ld   ac, [e_op]
    ld   ac, [e_otop]
    ld   ac, [o_k]
    ld   ac, [o_f]
    ld   ac, [c_row]
    ld   ac, [c_top]
    ld   ac, [e_mod]
    ld   ac, [e_play]
    ld   ac, [e_fl]
    ld   0xFF, ac
    ld   ac, [p_pat]
    ld   ac, [e_plop]
    ld   ac, [e_plrow]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; load_cmd / save_cmd - Ctrl-O, Ctrl-W: the name is asked for
; ------------------------------------------------------------
prompt_char:
    ld   PTAB_PG, y
    ld   [w0], ac
    add  0x90, x
    ld   [w2], ac
    ld   ac, [y,x]
    ld   [w0], ac
    inc
    ld   ac, [w0]
    ld   [w1], ac
    ld   ac, [CUR_COL]
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL tputc
    ld   tr_r333, [x]
    ld   LINK_HI, x
    ld   tr_r333 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
tr_r333:
    ld   s_cur & 0xFF, ac
    ld   ac, [R0]
    ld   s_cur >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r334, [x]
    ld   LINK_HI, x
    ld   tr_r334 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r334:
    ld   [w1], ac
    inc
    ld   ac, [w1]
    ld   pr_l >> 8, y
    jmp  pr_l


#overlay 0xAA00
new_song2:
    ld   (SONG >> 8) + 1, y     ; wave table: 1 = pulse +0, 2 = end
    ld   0x01, x
    ld   0x01, [y,x]
    ld   0x02, x
    ld   0xFE, [y,x]
    ld   (SONG >> 8) + 2, y     ; instrument 0
    ld   I_AD, x
    ld   0x0A, [y,x]
    ld   I_SR, x
    ld   0xA8, [y,x]
    ld   I_WAVE, x
    ld   0x01, [y,x]
    ld   I_PW, x
    ld   0x80, [y,x]
    ld   I_VOL, x
    ld   15, [y,x]
    clr  ac
    ld   ac, [w0]
ns_n:
    ld   [w0], ac
    add  s_pulse & 0xFF, x
    ld   s_pulse >> 8, y
    ld   [y,x], ac
    ld   ac, [w1]
    ld   [w0], ac
    add  I_NAME, x
    ld   (SONG >> 8) + 2, y
    ld   [w1], ac
    ld   ac, [y,x]
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  7, ac
    bne  ns_n
    clr  ac                     ; orderlists: voice v plays pattern v, loops
    ld   ac, [w0]
ns_o:
    ld   [w0], ac
    add  VSPAGE, y
    ld   OD_PAT, x
    ld   [w0], ac
    ld   ac, [y,x]
    ld   OD_TR, x
    ld   0, [y,x]
    ld   OD_LEN, x
    ld   1, [y,x]
    ld   OD_END, x
    ld   0xFF, [y,x]
    ld   OD_TGT, x
    ld   0, [y,x]
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  4, ac
    bne  ns_o
    ld   LINK_LO, x             ; CALL encode_all
    ld   tr_r310, [x]
    ld   LINK_HI, x
    ld   tr_r310 >> 8, [x]
    ld   encode_all >> 8, y
    jmp  encode_all
tr_r310:
    clr  ac
    ld   ac, [w0]
ns_s:
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL slot_clear
    ld   tr_r311, [x]
    ld   LINK_HI, x
    ld   tr_r311 >> 8, [x]
    ld   slot_clear >> 8, y
    jmp  slot_clear
tr_r311:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  CAP, ac
    bne  ns_s
    ld   song_ready >> 8, y
    jmp  song_ready

; song_ready - after a new or loaded song: the offsets, the player, the
; cursors
obj_next:
    ld   PTAB_PG, y
    ld   L_K, x
    ld   [y,x], ac
    ld   ac, [u2]
    sub  4, ac
    bcc  on_pat
    ld   [u2], ac               ; orderlist k: x41 + 2k
    shl
    add  0x41, ac
    bra  on_rd
on_pat:
    ld   ac, [u3]               ; pattern n = k - 4, n < the file's count
    ld   SONG >> 8, y
    ld   0x05, x
    ld   [u3], ac
    sub  [y,x], ac
    bcc  on_none
    ld   [u3], ac
    add  0x80, ac
on_rd:
    ld   ac, [u4]
    ld   SONG >> 8, y
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [u5]
    ld   [u2], ac
    sub  4, ac
    bcc  on_rd2
    ld   [u4], ac               ; an orderlist: the high byte follows
    inc
    ld   ac, x
    ld   [y,x], ac
    bra  on_w
on_rd2:
    ld   [u4], ac               ; a pattern: the high bytes at xC0
    add  0x40, ac
    ld   ac, x
    ld   [y,x], ac
on_w:
    ld   ac, [u6]
    ld   PTAB_PG, y
    ld   L_NLO, x
    ld   [u5], ac
    ld   ac, [y,x]
    ld   L_NHI, x
    ld   [u6], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
on_none:
    ld   PTAB_PG, y
    ld   L_NLO, x
    ld   0xFF, [y,x]
    ld   L_NHI, x
    ld   0xFF, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; obj_start - object L_K's place and size: L_DPG:L_DLO, L_LHI:L_LLO;
; then L_K + 1

#overlay 0xAC00
load_cmd:
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
    ld   LINK_LO, x             ; CALL do_stop
    ld   tr_r314, [x]
    ld   LINK_HI, x
    ld   tr_r314 >> 8, [x]
    ld   do_stop >> 8, y
    jmp  do_stop
tr_r314:
    ld   s_askload & 0xFF, ac
    ld   ac, [R0]
    ld   s_askload >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL prompt
    ld   tr_r315, [x]
    ld   LINK_HI, x
    ld   tr_r315 >> 8, [x]
    ld   prompt >> 8, y
    jmp  prompt
tr_r315:
    bne  lcm_c
    ld   LINK_LO, x             ; CALL load_song
    ld   tr_r316, [x]
    ld   LINK_HI, x
    ld   tr_r316 >> 8, [x]
    ld   load_song >> 8, y
    jmp  load_song
tr_r316:
    ld   PTAB_PG, y
    ld   L_ERR, x
    ld   [y,x], ac
    ld   ac, [e_res]            ; (the drawing uses the w's)
    ld   LINK_LO, x             ; CALL redraw_all
    ld   tr_r317, [x]
    ld   LINK_HI, x
    ld   tr_r317 >> 8, [x]
    ld   redraw_all >> 8, y
    jmp  redraw_all
tr_r317:
    ld   [e_res], ac
    bne  lcm_f
    ld   s_loaded & 0xFF, ac
    ld   ac, [R0]
    ld   s_loaded >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r318, [x]
    ld   LINK_HI, x
    ld   tr_r318 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r318:
    ld   tr_leave >> 8, y
    jmp  tr_leave
lcm_f:
    ld   s_notfound & 0xFF, ac
    ld   ac, [R0]
    ld   s_notfound >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r319, [x]
    ld   LINK_HI, x
    ld   tr_r319 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r319:
    ld   tr_leave >> 8, y
    jmp  tr_leave
lcm_c:
    ld   LINK_LO, x             ; CALL status_clear
    ld   tr_r320, [x]
    ld   LINK_HI, x
    ld   tr_r320 >> 8, [x]
    ld   status_clear >> 8, y
    jmp  status_clear
tr_r320:
    ld   tr_leave >> 8, y
    jmp  tr_leave

load_fix:
    clr  ac
    ld   ac, [w4]
lf_l:
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL slot_fix
    ld   tr_r345, [x]
    ld   LINK_HI, x
    ld   tr_r345 >> 8, [x]
    ld   slot_fix >> 8, y
    jmp  slot_fix
tr_r345:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    xor  CAP, ac
    bne  lf_l
    ld   LINK_LO, x             ; CALL decode_all
    ld   tr_r346, [x]
    ld   LINK_HI, x
    ld   tr_r346 >> 8, [x]
    ld   decode_all >> 8, y
    jmp  decode_all
tr_r346:
    ld   LINK_LO, x             ; CALL encode_all
    ld   tr_r347, [x]
    ld   LINK_HI, x
    ld   tr_r347 >> 8, [x]
    ld   encode_all >> 8, y
    jmp  encode_all
tr_r347:
    ld   LINK_LO, x             ; CALL song_ready
    ld   tr_r348, [x]
    ld   LINK_HI, x
    ld   tr_r348 >> 8, [x]
    ld   song_ready >> 8, y
    jmp  song_ready
tr_r348:
    clr  ac
    ld   ac, [w0]
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ============================================================
; save_song - the song as a .SNG file named e_name: the header pages,
; the orderlists, the patterns used (and one FF for the rest).
; AC = 0 saved, 1 failed
; ============================================================
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

#overlay 0xAE00
save_cmd:
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
    ld   LINK_LO, x             ; CALL do_stop
    ld   tr_r321, [x]
    ld   LINK_HI, x
    ld   tr_r321 >> 8, [x]
    ld   do_stop >> 8, y
    jmp  do_stop
tr_r321:
    ld   s_asksave & 0xFF, ac
    ld   ac, [R0]
    ld   s_asksave >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL prompt
    ld   tr_r322, [x]
    ld   LINK_HI, x
    ld   tr_r322 >> 8, [x]
    ld   prompt >> 8, y
    jmp  prompt
tr_r322:
    bne  scm_c
    ld   LINK_LO, x             ; CALL save_song
    ld   tr_r323, [x]
    ld   LINK_HI, x
    ld   tr_r323 >> 8, [x]
    ld   save_song >> 8, y
    jmp  save_song
tr_r323:
    bne  scm_f
    ld   s_saved & 0xFF, ac
    ld   ac, [R0]
    ld   s_saved >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r324, [x]
    ld   LINK_HI, x
    ld   tr_r324 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r324:
    ld   tr_leave >> 8, y
    jmp  tr_leave
scm_f:
    ld   s_savefail & 0xFF, ac
    ld   ac, [R0]
    ld   s_savefail >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL status
    ld   tr_r325, [x]
    ld   LINK_HI, x
    ld   tr_r325 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r325:
    ld   tr_leave >> 8, y
    jmp  tr_leave
scm_c:
    ld   LINK_LO, x             ; CALL status_clear
    ld   tr_r326, [x]
    ld   LINK_HI, x
    ld   tr_r326 >> 8, [x]
    ld   status_clear >> 8, y
    jmp  status_clear
tr_r326:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ------------------------------------------------------------
; prompt - R1:R0 = the question on the status row; a name typed after
; it (Enter) goes to e_name, AC = 0; Esc or an empty line: AC = 1
; ------------------------------------------------------------
ld_sector:
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
    ld   ac, [w4]
    ld   ac, [w5]
lds_l:
    ld   [w0], ac
    xor  [w2], ac
    bne  lds_a
    ld   [w1], ac
    xor  [w3], ac
    beq  lds_e
lds_a:
    ld   [w5], ac
    xor  2, ac
    beq  lds_e
    ld   [w5], ac
    add  FBUF >> 8, y
    ld   [w4], x
    ld   [y,x], ac
    ld   ac, [u7]
    ld   [w1], ac
    sub  5, ac
    bcc  lds_obj
    ld   [w1], ac
    add  SONG >> 8, y
    ld   [w0], x
    ld   [u7], ac
    ld   ac, [y,x]
lds_n:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    bne  lds_n2
    ld   [w1], ac
    inc
    ld   ac, [w1]
lds_n2:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    bne  lds_l
    ld   [w5], ac
    inc
    ld   ac, [w5]
    bra  lds_l
lds_obj:
    ld   LINK_LO, x             ; CALL ld_byte
    ld   tr_r341, [x]
    ld   LINK_HI, x
    ld   tr_r341 >> 8, [x]
    ld   ld_byte >> 8, y
    jmp  ld_byte
tr_r341:
    ld   PTAB_PG, y
    ld   L_ERR, x
    ld   [y,x], ac
    beq  lds_n
lds_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ld_byte - the byte u7 at offset w1:w0 (x500 and up): into the object
; it belongs to

#overlay 0xB000
prompt:
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
    ld   LINK_LO, x             ; CALL status
    ld   tr_r327, [x]
    ld   LINK_HI, x
    ld   tr_r327 >> 8, [x]
    ld   status >> 8, y
    jmp  status
tr_r327:
    ld   [s_col], ac
    ld   ac, [CUR_COL]
    ld   s_cur & 0xFF, ac
    ld   ac, [R0]
    ld   s_cur >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   tr_r328, [x]
    ld   LINK_HI, x
    ld   tr_r328 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
tr_r328:
    ld   [CUR_COL], ac
    dec
    ld   ac, [w1]               ; the column of the next character
    clr  ac
    ld   ac, [w0]               ; characters so far
pr_l:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames
    ld   tr_r329, [x]
    ld   LINK_HI, x
    ld   tr_r329 >> 8, [x]
    ld   l_wait_frames >> 8, y
    jmp  l_wait_frames
tr_r329:
    ld   LINK_LO, x             ; CALL mus_frame
    ld   tr_r330, [x]
    ld   LINK_HI, x
    ld   tr_r330 >> 8, [x]
    ld   mus_frame >> 8, y
    jmp  mus_frame
tr_r330:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   tr_r331, [x]
    ld   LINK_HI, x
    ld   tr_r331 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
tr_r331:
    ld   LINK_LO, x             ; CALL l_kbd_getc
    ld   tr_r332, [x]
    ld   LINK_HI, x
    ld   tr_r332 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
tr_r332:
    beq  pr_l
    ld   ac, [w2]
    xor  0x1B, ac
    beq  pr_cancel
    ld   [w2], ac
    xor  0x0A, ac
    beq  pr_enter
    ld   [w2], ac
    xor  0x08, ac
    beq  pr_bs
    ld   [w0], ac
    xor  12, ac
    beq  pr_l
    ld   [w2], ac
    sub  0x21, ac
    blt  pr_l
    ld   [w2], ac
    sub  0x61, ac               ; a-z -> A-Z
    blt  pr_c
    sub  26, ac
    bcc  pr_c
    ld   [w2], ac
    and  0xDF, ac
    ld   ac, [w2]
pr_c:
    ld   prompt_char >> 8, y
    jmp  prompt_char
pr_bs:
    ld   prompt_bs >> 8, y
    jmp  prompt_bs
pr_enter:
    ld   [w0], ac
    beq  pr_cancel
    ld   prompt_done >> 8, y
    jmp  prompt_done
pr_cancel:
    ld   1, ac
    ld   tr_leave >> 8, y
    jmp  tr_leave

s_askload:
    #d "Load: ", 0x00
s_asksave:
    #d "Save as: ", 0x00
s_loaded:
    #d "Loaded", 0x00
s_notfound:
    #d "Not found, or not a song", 0x00
s_saved:
    #d "Saved", 0x00
s_savefail:
    #d "Save failed", 0x00

; ============================================================
; the player
; ============================================================
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


#overlay 0xB200
load_song:
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
    ld   e_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_fs_open
    ld   tr_r337, [x]
    ld   LINK_HI, x
    ld   tr_r337 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
tr_r337:
    beq  ls_ok
    ld   PTAB_PG, y
    ld   L_ERR, x
    ld   1, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave
ls_ok:
    ld   FS_REM_LO & 0xFF, x
    ld   FS_REM_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [w2]
    ld   FS_REM_HI & 0xFF, x
    ld   [y,x], ac
    ld   ac, [w3]
    clr  ac
    ld   ac, [w0]
    ld   ac, [w1]
    ld   PTAB_PG, y
    ld   L_ERR, x
    ld   0, [y,x]
    clr  ac                     ; blank slots and orderlists first
    ld   ac, [w4]
ls_c:
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL slot_clear
    ld   tr_r338, [x]
    ld   LINK_HI, x
    ld   tr_r338 >> 8, [x]
    ld   slot_clear >> 8, y
    jmp  slot_clear
tr_r338:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    xor  CAP, ac
    bne  ls_c
    ld   OLIST >> 8, y
    clr  ac
ls_o:
    ld   ac, x
    ld   0xFE, [y,x]
    inc
    bne  ls_o
ls_l:
    ld   [w0], ac
    xor  [w2], ac
    bne  ls_r
    ld   [w1], ac
    xor  [w3], ac
    beq  ls_done
ls_r:
    ld   FBUF & 0xFF, ac
    ld   ac, [R4]
    ld   FBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_read
    ld   tr_r339, [x]
    ld   LINK_HI, x
    ld   tr_r339 >> 8, [x]
    ld   l_fs_read >> 8, y
    jmp  l_fs_read
tr_r339:
    sub  2, ac
    bcc  ls_fail
    ld   LINK_LO, x             ; CALL ld_sector
    ld   tr_r340, [x]
    ld   LINK_HI, x
    ld   tr_r340 >> 8, [x]
    ld   ld_sector >> 8, y
    jmp  ld_sector
tr_r340:
    ld   PTAB_PG, y
    ld   L_ERR, x
    ld   [y,x], ac
    beq  ls_l
ls_fail:
    ld   load_fix >> 8, y       ; what came is kept
    jmp  load_fix
ls_done:
    ld   load_fix >> 8, y
    jmp  load_fix

; ld_sector - the 512 bytes in FBUF (up to the file's size)
sv_put:
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
    ld   [w5], y
    ld   [w4], x
    ld   ac, [y,x]
    ld   [w4], ac
    inc
    ld   ac, [w4]
    bne  sp_e
    ld   [w5], ac
    inc
    ld   ac, [w5]
    xor  (FBUF >> 8) + 2, ac
    bne  sp_e
    ld   FBUF & 0xFF, ac
    ld   ac, [R4]
    ld   FBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_write
    ld   tr_r363, [x]
    ld   LINK_HI, x
    ld   tr_r363 >> 8, [x]
    ld   l_fs_write >> 8, y
    jmp  l_fs_write
tr_r363:
    ld   FBUF >> 8, ac
    ld   ac, [w5]
sp_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; ============================================================
; data
; ============================================================

#overlay 0xB400
ld_byte:
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
    ld   [w1], ac
    xor  5, ac
    bne  lb_c
    ld   [w0], ac
    bne  lb_c
    ld   PTAB_PG, y             ; the first byte past the header: object 0
    ld   L_K, x
    ld   0, [y,x]
    ld   L_LLO, x
    ld   0, [y,x]
    ld   L_LHI, x
    ld   0, [y,x]
    ld   LINK_LO, x             ; CALL obj_next
    ld   tr_r342, [x]
    ld   LINK_HI, x
    ld   tr_r342 >> 8, [x]
    ld   obj_next >> 8, y
    jmp  obj_next
tr_r342:
lb_c:
    ld   PTAB_PG, y
    ld   L_NHI, x
    ld   [w1], ac
    xor  [y,x], ac
    bne  lb_c2
    ld   L_NLO, x
    ld   [w0], ac
    xor  [y,x], ac
    bne  lb_c2
    ld   LINK_LO, x             ; this object begins here
    ld   tr_r343, [x]
    ld   LINK_HI, x
    ld   tr_r343 >> 8, [x]
    ld   obj_start >> 8, y
    jmp  obj_start
tr_r343:
    ld   LINK_LO, x             ; CALL obj_next
    ld   tr_r344, [x]
    ld   LINK_HI, x
    ld   tr_r344 >> 8, [x]
    ld   obj_next >> 8, y
    jmp  obj_next
tr_r344:
    bra  lb_c
lb_c2:
    ld   PTAB_PG, y
    ld   L_NHI, x
    ld   [w1], ac
    sub  [y,x], ac
    bcs  lb_put                 ; before the next object
    bne  lb_bad
    ld   L_NLO, x
    ld   [w0], ac
    sub  [y,x], ac
    bcs  lb_put
lb_bad:
    ld   L_ERR, x               ; the objects are not in order: stop
    ld   1, [y,x]
    ld   tr_leave >> 8, y
    jmp  tr_leave
lb_put:
    ld   L_LLO, x
    ld   [y,x], ac
    ld   L_LHI, x
    or   [y,x], ac
    beq  lb_e
    ld   L_LLO, x
    ld   [y,x], ac
    bne  lb_p2
    ld   L_LHI, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
lb_p2:
    ld   L_LLO, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    ld   L_DPG, x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   L_DLO, x
    ld   [y,x], ac
    ld   ac, [u1]
    inc
    ld   ac, [y,x]
    ld   [u0], y
    ld   [u1], x
    ld   [u7], ac
    ld   ac, [y,x]
lb_e:
    ld   tr_leave >> 8, y
    jmp  tr_leave

; obj_next - L_NHI:L_NLO = the offset of object L_K (FFFF past the last)
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


#overlay 0xB600
obj_start:
    ld   PTAB_PG, y
    ld   L_K, x
    ld   [y,x], ac
    ld   ac, [u2]
    sub  4, ac
    bcc  os_pat
    ld   [u2], ac               ; orderlist k: OLIST + 64 k, 64 bytes
    shl
    shl
    shl
    shl
    shl
    shl
    ld   ac, [u1]
    ld   L_DLO, x
    ld   ac, [y,x]
    ld   L_DPG, x
    ld   OLIST >> 8, [y,x]
    ld   L_LLO, x
    ld   64, [y,x]
    ld   L_LHI, x
    ld   0, [y,x]
    bra  os_k
os_pat:
    ld   ac, [u3]
    sub  CAP, ac
    bcc  os_drop
    ld   [u3], ac
    ld   ac, [u0]
    ld   PTAB_PG, y
    add  PTAB_HI, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    add  PTAB_LO, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   PTAB_PG, y
    ld   L_DPG, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   L_DLO, x
    ld   [u2], ac
    ld   ac, [y,x]
    ld   L_LLO, x
    ld   SLOT_LO, ac
    ld   ac, [y,x]
    ld   L_LHI, x
    ld   SLOT_LO, ac
    bne  os_k2
    ld   1, [y,x]               ; 256
    bra  os_k
os_k2:
    ld   0, [y,x]
    bra  os_k
os_drop:
    ld   L_LLO, x
    ld   0, [y,x]
    ld   L_LHI, x
    ld   0, [y,x]
os_k:
    ld   L_K, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; load_fix - after the file: every slot ends, the orderlists decoded,
; the live offsets, the player
save_song:
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
    clr  ac                     ; the patterns to write: up to the highest
    ld   ac, [w0]               ; used or referenced
    ld   ac, [w1]               ; the highest + 1
sv_n:
    ld   [w0], ac
    ld   LINK_LO, x             ; CALL slot_blank
    ld   tr_r349, [x]
    ld   LINK_HI, x
    ld   tr_r349 >> 8, [x]
    ld   slot_blank >> 8, y
    jmp  slot_blank
tr_r349:
    bne  sv_n2
    ld   [w0], ac
    inc
    ld   ac, [w1]
sv_n2:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  CAP, ac
    bne  sv_n
    clr  ac
    ld   ac, [w2]               ; the orderlists' references
sv_v:
    ld   [w2], ac
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [y,x], ac
    ld   ac, [w3]
    clr  ac
    ld   ac, [w4]
sv_k:
    ld   [w4], ac
    xor  [w3], ac
    beq  sv_kd
    ld   [w4], ac
    shl
    add  OD_PAT, x
    ld   [y,x], ac
    inc
    sub  [w1], ac
    bcs  sv_k2
    beq  sv_k2
    ld   [y,x], ac
    inc
    ld   ac, [w1]
sv_k2:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    bra  sv_k
sv_kd:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  sv_v
    ld   [w1], ac
    bne  sv_np
    ld   1, ac
sv_np:
    ld   PTAB_PG, y
    ld   L_NPAT, x
    ld   ac, [y,x]
    ld   save_offsets >> 8, y
    jmp  save_offsets

; the offsets in the header: the orderlists from x500, then the patterns

#overlay 0xB800
save_offsets:
    clr  ac
    ld   ac, [w0]               ; the running offset, low
    ld   5, ac
    ld   ac, [w1]               ; high
    clr  ac
    ld   ac, [w2]               ; the voice
so2_v:
    ld   [w2], ac
    shl
    add  0x41, ac
    ld   ac, x
    ld   SONG >> 8, y
    ld   [w0], ac
    ld   ac, [y,x]
    ld   [w2], ac
    shl
    add  0x42, ac
    ld   ac, x
    ld   [w1], ac
    ld   ac, [y,x]
    ld   [w2], ac               ; its size: OD_OFF[len] + 1 (stop) or 2 (loop)
    add  VSPAGE, y
    ld   OD_LEN, x
    ld   [y,x], ac
    add  OD_OFF, x
    ld   [y,x], ac
    inc
    ld   ac, [w3]
    ld   OD_END, x
    ld   [y,x], ac
    xor  0xFF, ac
    bne  so2_s
    ld   [w3], ac
    inc
    ld   ac, [w3]
so2_s:
    ld   PTAB_PG, y
    ld   [w2], ac
    add  L_SZ, x
    ld   [w3], ac
    ld   ac, [y,x]
    add  [w0], ac
    ld   ac, [w0]
    bcc  so2_c
    ld   [w1], ac
    inc
    ld   ac, [w1]
so2_c:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  so2_v
    clr  ac
    ld   ac, [w2]               ; the patterns
so2_p:
    ld   SONG >> 8, y
    ld   [w2], ac
    add  0x80, x
    ld   [w0], ac
    ld   ac, [y,x]
    ld   [w2], ac
    add  0xC0, x
    ld   [w1], ac
    ld   ac, [y,x]
    ld   PTAB_PG, y
    ld   L_NPAT, x
    ld   [w2], ac
    sub  [y,x], ac
    bcc  so2_n                  ; past the count: the FF at the end
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL slot_len
    ld   tr_r350, [x]
    ld   LINK_HI, x
    ld   tr_r350 >> 8, [x]
    ld   slot_len >> 8, y
    jmp  slot_len
tr_r350:
    add  [w0], ac
    ld   ac, [w0]
    bcc  so2_n
    ld   [w1], ac
    inc
    ld   ac, [w1]
so2_n:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  64, ac
    bne  so2_p
    ld   save_header >> 8, y
    jmp  save_header

s_pattern:
    #d "PATTERN ", 0x00
s_rows:
    #d " rows", 0x00
s_nopat:
    #d "no pattern", 0x00
s_voice:
    #d "   voice ", 0x00
s_pos:
    #d "   position ", 0x00
s_cols:
    #d " ROW V1          V2          V3          V4", 0x00

#overlay 0xBA00
save_header:
    ld   [w0], ac               ; + the FF: the length
    inc
    ld   ac, [w0]
    bne  sh_a
    ld   [w1], ac
    inc
    ld   ac, [w1]
sh_a:
    ld   SONG >> 8, y
    ld   0x08, x
    ld   [w0], ac
    ld   ac, [y,x]
    ld   0x09, x
    ld   [w1], ac
    ld   ac, [y,x]
    ld   0x04, x
    ld   1, [y,x]
    ld   0x07, x
    ld   0, [y,x]
    ld   0x05, x
    ld   PTAB_PG, y
    ld   L_NPAT, x
    ld   [y,x], ac
    ld   SONG >> 8, y
    ld   0x05, x
    ld   ac, [y,x]
    ld   e_name, ac             ; the file
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_fs_create
    ld   tr_r351, [x]
    ld   LINK_HI, x
    ld   tr_r351 >> 8, [x]
    ld   l_fs_create >> 8, y
    jmp  l_fs_create
tr_r351:
    beq  sh_go
    ld   LINK_LO, x             ; CALL set_offsets
    ld   tr_r352, [x]
    ld   LINK_HI, x
    ld   tr_r352 >> 8, [x]
    ld   set_offsets >> 8, y
    jmp  set_offsets
tr_r352:
    ld   1, ac
    ld   tr_leave >> 8, y
    jmp  tr_leave
sh_go:
    clr  ac
    ld   ac, [w4]               ; the sink: FBUF page w5, offset w4
    ld   FBUF >> 8, ac
    ld   ac, [w5]
    ld   SONG >> 8, ac          ; pages 0-4
    ld   ac, [w2]
sh_p:
    clr  ac
    ld   ac, [w3]
sh_b:
    ld   [w2], y
    ld   [w3], x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL sv_put
    ld   tr_r353, [x]
    ld   LINK_HI, x
    ld   tr_r353 >> 8, [x]
    ld   sv_put >> 8, y
    jmp  sv_put
tr_r353:
    ld   [w3], ac
    inc
    ld   ac, [w3]
    bne  sh_b
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  (SONG >> 8) + 5, ac
    bne  sh_p
    ld   save_lists >> 8, y
    jmp  save_lists

save_end:
    ld   [w4], ac               ; a part sector left: write it
    bne  se_w
    ld   [w5], ac
    xor  FBUF >> 8, ac
    beq  se_c
se_w:
    ld   FBUF & 0xFF, ac
    ld   ac, [R4]
    ld   FBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_write
    ld   tr_r359, [x]
    ld   LINK_HI, x
    ld   tr_r359 >> 8, [x]
    ld   l_fs_write >> 8, y
    jmp  l_fs_write
tr_r359:
    bne  se_f
se_c:
    ld   SONG >> 8, y           ; the size from the header
    ld   0x08, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   0x09, x
    ld   [y,x], ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R2]
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL l_fs_close
    ld   tr_r360, [x]
    ld   LINK_HI, x
    ld   tr_r360 >> 8, [x]
    ld   l_fs_close >> 8, y
    jmp  l_fs_close
tr_r360:
    bne  se_f
    ld   LINK_LO, x             ; CALL set_offsets
    ld   tr_r361, [x]
    ld   LINK_HI, x
    ld   tr_r361 >> 8, [x]
    ld   set_offsets >> 8, y
    jmp  set_offsets
tr_r361:
    clr  ac
    ld   ac, [e_mod]
    ld   ac, [e_fl]
    ld   tr_leave >> 8, y
    jmp  tr_leave
se_f:
    ld   LINK_LO, x             ; CALL set_offsets
    ld   tr_r362, [x]
    ld   LINK_HI, x
    ld   tr_r362 >> 8, [x]
    ld   set_offsets >> 8, y
    jmp  set_offsets
tr_r362:
    ld   1, ac
    ld   tr_leave >> 8, y
    jmp  tr_leave

; sv_put - the byte AC into the file (a sector at a time)

#overlay 0xBC00
save_lists:
    clr  ac
    ld   ac, [w2]               ; the voice
sl2_v:
    ld   PTAB_PG, y
    ld   [w2], ac
    add  L_SZ, x
    ld   [y,x], ac
    ld   ac, [w1]               ; its size
    ld   [w2], ac
    shl
    shl
    shl
    shl
    shl
    shl
    ld   ac, [w3]               ; its first byte
sl2_b:
    ld   OLIST >> 8, y
    ld   [w3], x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL sv_put
    ld   tr_r354, [x]
    ld   LINK_HI, x
    ld   tr_r354 >> 8, [x]
    ld   sv_put >> 8, y
    jmp  sv_put
tr_r354:
    ld   [w3], ac
    inc
    ld   ac, [w3]
    ld   [w1], ac
    dec
    ld   ac, [w1]
    bne  sl2_b
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  sl2_v
    clr  ac
    ld   ac, [w2]               ; the patterns
sl2_p:
    ld   PTAB_PG, y
    ld   L_NPAT, x
    ld   [w2], ac
    xor  [y,x], ac
    beq  sl2_d
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL slot_len
    ld   tr_r355, [x]
    ld   LINK_HI, x
    ld   tr_r355 >> 8, [x]
    ld   slot_len >> 8, y
    jmp  slot_len
tr_r355:
    ld   ac, [w1]
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL slot_addr
    ld   tr_r356, [x]
    ld   LINK_HI, x
    ld   tr_r356 >> 8, [x]
    ld   slot_addr >> 8, y
    jmp  slot_addr
tr_r356:
    clr  ac
    ld   ac, [w3]
sl2_pb:
    ld   [u1], y
    ld   [w3], ac
    add  [u2], ac
    ld   ac, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL sv_put
    ld   tr_r357, [x]
    ld   LINK_HI, x
    ld   tr_r357 >> 8, [x]
    ld   sv_put >> 8, y
    jmp  sv_put
tr_r357:
    ld   [w3], ac
    inc
    ld   ac, [w3]
    ld   [w1], ac
    dec
    ld   ac, [w1]
    bne  sl2_pb
    ld   [w2], ac
    inc
    ld   ac, [w2]
    bra  sl2_p
sl2_d:
    ld   0xFF, ac
    ld   LINK_LO, x             ; CALL sv_put
    ld   tr_r358, [x]
    ld   LINK_HI, x
    ld   tr_r358 >> 8, [x]
    ld   sv_put >> 8, y
    jmp  sv_put
tr_r358:
    ld   save_end >> 8, y
    jmp  save_end

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


#overlay 0xBE00
s_hdr:
    #d "PLACARD TRACKER  ", 0x00
s_oct:
    #d "  oct ", 0x00
s_ins:
    #d "  ins ", 0x00
s_stop:
    #d "STOP", 0x00
s_play:
    #d "PLAY", 0x00
s_keys:
    #d " Z-M Q-P notes 1 off -= oct <> ins Tab pane  Ent/Spc play  Esc stop  ^O ^W ^N ^X", 0x00
s_order:
    #d "ORDER V1     V2     V3     V4", 0x00
s_loop:
    #d "LOOP", 0x00
s_stop6:
    #d "STOP  ", 0x00
s_instr:
    #d "INSTRUMENT ", 0x00
s_dots:
    #d "...", 0x00
s_koff:
    #d "===", 0x00
s_empty:
    #d 0x00
s_cur:
    #d "_ ", 0x00
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

#overlay 0xC000
s_ifields:
    #d "Attack  ", 0x80, "   Decay   ", 0x90, 0xFE
    #d "Sustain ", 0x81, "   Release ", 0x91, 0xFE
    #d "Wave    ", 0xA2, "  Pulse   ", 0xA3, 0xFE
    #d "PW      ", 0xA4, "  HardRst ", 0xB5, 0xFE
    #d "VibDly  ", 0xA6, "  Vibrato ", 0xA7, 0xFE
    #d "Volume  ", 0xA8, 0xFF
ifld:
    #d8 3, 48, 1,  3, 60, 1,  4, 48, 1,  4, 60, 1
    #d8 5, 48, 2,  5, 60, 2,  6, 48, 2,  6, 60, 1
    #d8 7, 48, 2,  7, 60, 2,  8, 48, 2,  2, 54, 7
ikinds:
    #d8 0, 0,  0, 1,  1, 0,  1, 1,  2, 2,  3, 2
    #d8 4, 2,  5, 3,  6, 2,  7, 2,  8, 1,  9, 4
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


#overlay 0xC200
wnames:
    #d "-----pulsesaw  tri  noisecw0  cw1  cw2  cw3  cw4  cw5  cw6  cw7  off  END  LOOP ?    SET  "
pkeys:
    #d "z", 0x00, "s", 0x01, "x", 0x02, "d", 0x03, "c", 0x04, "v", 0x05, "g", 0x06, "b", 0x07
    #d "h", 0x08, "n", 0x09, "j", 0x0A, "m", 0x0B, 0x2C, 0x0C, "l", 0x0D, ".", 0x0E, "q", 0x0C
    #d "2", 0x0D, "w", 0x0E, "3", 0x0F, "e", 0x10, "r", 0x11, "5", 0x12, "t", 0x13, "6", 0x14
    #d "y", 0x15, "7", 0x16, "u", 0x17, "i", 0x18, "9", 0x19, "o", 0x1A, "0", 0x1B, "p", 0x1C
    #d 0x00

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


#overlay 0xC400
s_wtab:
    #d "WAVE TABLE   entry: waveform, note (+n from the note played, or absolute)", 0x00
s_ptab:
    #d "PULSE TABLE  entry: xTT ticks +step, SET width, LOOP nn, END", 0x00
s_newsong:
    #d "NEW SONG                        "

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

#overlay 0xC600
s_nopat2:
    #d "No pattern at this position for this voice", 0x00
s_pastend:
    #d "Past the end of the pattern (Ctrl-L: its length)", 0x00
s_high:
    #d "Note too high", 0x00
s_full:
    #d "Pattern full: too many bytes for its slot", 0x00
s_unsaved:
    #d "Not saved: Ctrl-X again to leave", 0x00

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


#overlay 0xC800
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

#overlay 0xCA00
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

#overlay 0xCC00
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

#overlay 0xCE00
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

#overlay 0xD000
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

#overlay 0xD200
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

#overlay 0xD400
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

#overlay 0xD600
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

#overlay 0xD800
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

#overlay 0xDA00
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

#overlay 0xDC00
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

#overlay 0xDE00
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

#overlay 0xE000
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

#overlay 0xE200
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

#overlay 0xE400
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

#overlay 0xE600
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

#overlay 0xE800
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
