; ============================================================
; made by asm_expand.py from scrap.masm: change that file, then run
;     python3 asm_expand.py scrap.masm
; ============================================================

; ============================================================
; scrap.masm - SCRAP.PLC: SCRAPWRIGHT, phase 2 (a wreck to walk through)
; ============================================================
;
; A library program the DOS runs from the card.  SCRAPWRIGHT is a
; top-down salvage game (docs/software/SCRAP.md): you walk a salvage tug's
; docked wreck, look at what is in it with the mouse, and (in later
; phases) cut it out, haul it home and build it into your own ship.  This
; phase is the walking: the tug and the KESTREL 9 on one 96 x 64 map,
; doors, the camera, the item panel and the mouse.
;
; The screen (2x line repeat everywhere):
;   lines 0-383     4 bpp: 20 x 12 cells of 8 x 16 pixels (32 x 32 on
;                   the monitor); the cell under the mouse has a yellow
;                   frame
;   lines 384-479   1 bpp: the panel, text rows 24-29 (tracker.masm's
;                   2x text layout).  Row 24: the name of the cell the
;                   panel shows, its damage bar; rows 25-28: its info on
;                   the left, its actions on the right (the one under the
;                   mouse in inverse); row 29: a message, tinted yellow
;
; The panel shows the cell under the mouse; a left click on a cell locks
; it there (the mouse can then go down to the actions), a right click
; unlocks.  A left click on an action, or keys 1-4, does it: OPEN and
; CLOSE a door next to you, WALK HERE (steps toward the cell), INSPECT
; (a line about it).  Arrows, WASD or the pad walk; walking into a closed
; door opens it.  Esc goes back (menu_poll).
;
; Memory.  The program and its tables are at x0100-x3FFF (the art at
; x3A00, the tables at x3600-x39FF: gen_scrap.py makes them in
; scrap_data.masm).  The map is in the even video pages x60-xBE that the
; 2x screen leaves free (gen_scrap.py: chunk k of 16 x 16 cells is page
; x60 + 4k, the types, and x62 + 4k, the flags); main reads it from
; SCRAP.OVL.  The video RAM is above x6000, so like the tracker this
; program runs with the map at FF (every section RAM) and calls the
; library through the l_* stubs, which switch to 07 around the call.
;
;     python3 gen_scrap.py                            scrap_types.asm, scrap_data.masm, SCRAP.OVL
;     python3 asm_expand.py scrap.masm                scrap.asm
;     python3 gen_plc.py scrap.asm -o ../../sdcard/SCRAP.PLC
;     python3 test_scrap_sim.py                       runs it in placard_sim
;
; Date: 11/03/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"
#include "scrap_types.asm"

dos_back = 0x8008
FBUF     = 0x5400           ; 512-byte sector buffer while loading SCRAP.OVL
VIEW_W   = 20
VIEW_H   = 12
WALK_FRAMES = 7             ; frames between steps while a direction is held
MSG_FRAMES  = 240           ; a message stays 4 seconds
FRAME_COL   = 0xE           ; the hover frame: yellow
TINT_NAME   = 0x40          ; the panel's name row: blue
TINT_MSG    = 0x30          ; the message row: gold (red + green)

; zero page x20-x7F
v_x     = 0x20              ; the view's top left cell on the map
v_y     = 0x21
p_x     = 0x22              ; the player
p_y     = 0x23
h_x     = 0x24              ; the map cell under the mouse
h_y     = 0x25
h_on    = 0x26              ; 1: the mouse is over the view (h_x, h_y valid)
lock    = 0x27              ; 1: the panel stays on its cell
s_x     = 0x28              ; the cell the panel shows
s_y     = 0x29
s_who   = 0x2A              ; 0 nothing, 1 the cell s_x, s_y, 2 the player
m_xl    = 0x2B              ; the mouse, 0-639 and 0-479
m_xh    = 0x2C
m_yl    = 0x2D
m_yh    = 0x2E
m_ok    = 0x2F              ; 1: mouse_init found a mouse
m_b     = 0x30              ; the buttons last frame
m_sel   = 0x31              ; the action row under the mouse (FF none)
walk_t  = 0x32              ; frames to the next step
dirs    = 0x33              ; held: 1 up, 2 down, 4 left, 8 right
key     = 0x34
msg_t   = 0x35              ; frames the message has left
dirty   = 0x36              ; 1 panel, 2 message row
c_t     = 0x37              ; map_get: the cell's type
c_f     = 0x38              ;   its flags
a_pg    = 0x39              ;   its address: the type page, the index
a_ix    = 0x3A
g_x     = 0x3B              ; a map cell (map_get, refresh_cell)
g_y     = 0x3C
dc_cx   = 0x3D              ; draw_cell: the screen cell 0-19, 0-11
dc_cy   = 0x3E
dc_t    = 0x3F              ;   the cell type to draw
dc_sp   = 0x40              ;   screen page
dc_so   = 0x41              ;   screen offset
dc_ap   = 0x42              ;   art page
dc_ai   = 0x43              ;   art index
dc_n    = 0x44
dc_c    = 0x45
dc_base = 0x46              ;   the cell row's first offset
p_ch    = 0x47              ; text output (tputc)
p_k     = 0x48
p_pg    = 0x49
p_off   = 0x4A
p_st    = 0x4B
p_inv   = 0x4C              ; 80: inverse text
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
w6 = 0x5E
s_t     = 0x60              ; the panel's subject: type
s_f     = 0x61              ;   damage step 0-15
n_act   = 0x62              ;   actions 0-4
act0    = 0x63              ;   the action codes, x63-x66
wk_on   = 0x67              ; WALK HERE: 1 while walking to wk_x, wk_y
wk_x    = 0x68
wk_y    = 0x69
msg_l   = 0x6A              ; the message string
msg_h   = 0x6B
o_sel   = 0x6C              ; the action row drawn in inverse
mb_new  = 0x6D              ; buttons pressed this frame
n_x     = 0x6E              ; try_move: the cell to step to
n_y     = 0x6F
fr_on   = 0x70              ; 1: the frame is drawn on fr_x, fr_y
fr_x    = 0x71
fr_y    = 0x72

; MAP07 / MAPFF - the map register (x5000): the library's map, all RAM

; CELLADDR - dc_cx, dc_cy: dc_sp = the cell's first column's page,
; dc_base = its first line pair's offset (16 line pairs a cell row, the
; 2x layout: pair p at 2p + 32, or 2p - 223 from pair 112)

; the text cursor's glyph address (tracker.masm): p_pg:p_off, p_st

; MSG name - the message at label name


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
    ld   scw_r1, [x]
    ld   LINK_HI, x
    ld   scw_r1 >> 8, [x]
    ld   l_fs_mount >> 8, y
    jmp  l_fs_mount
scw_r1:
    ld   LINK_LO, x             ; CALL ovl_load
    ld   scw_r2, [x]
    ld   LINK_HI, x
    ld   scw_r2 >> 8, [x]
    ld   ovl_load >> 8, y
    jmp  ovl_load
scw_r2:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   start >> 8, y
    jmp  start

start:
    ld   LINK_LO, x             ; CALL l_mouse_init
    ld   scw_r3, [x]
    ld   LINK_HI, x
    ld   scw_r3 >> 8, [x]
    ld   l_mouse_init >> 8, y
    jmp  l_mouse_init
scw_r3:
    bne  st_nm
    ld   1, ac
    bra  st_m
st_nm:
    clr  ac
st_m:
    ld   ac, [m_ok]
    clr  ac
    ld   ac, [m_b]
    ld   ac, [m_xh]
    ld   ac, [m_yh]
    ld   ac, [lock]
    ld   ac, [h_on]
    ld   ac, [fr_on]
    ld   ac, [wk_on]
    ld   ac, [walk_t]
    ld   ac, [dirty]
    ld   ac, [p_inv]
    ld   0x40, ac               ; the pointer starts at 320, 240
    ld   ac, [m_xl]
    ld   1, ac
    ld   ac, [m_xh]
    ld   0xF0, ac
    ld   ac, [m_yl]
    ld   0xFF, ac
    ld   ac, [m_sel]
    ld   ac, [o_sel]
    ld   2, ac
    ld   ac, [s_who]
    ld   START_X, ac
    ld   ac, [p_x]
    ld   START_Y, ac
    ld   ac, [p_y]
    ld   LINK_LO, x             ; CALL camera_fit
    ld   scw_r4, [x]
    ld   LINK_HI, x
    ld   scw_r4 >> 8, [x]
    ld   camera_fit >> 8, y
    jmp  camera_fit
scw_r4:
    ld   LINK_LO, x             ; CALL screen_init
    ld   scw_r5, [x]
    ld   LINK_HI, x
    ld   scw_r5 >> 8, [x]
    ld   screen_init >> 8, y
    jmp  screen_init
scw_r5:
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r6, [x]
    ld   LINK_HI, x
    ld   scw_r6 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r6:
    ld   s_welcome & 0xFF, ac
    ld   ac, [R0]
    ld   s_welcome >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r7, [x]
    ld   LINK_HI, x
    ld   scw_r7 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r7:
    ld   LINK_LO, x             ; CALL draw_panel
    ld   scw_r8, [x]
    ld   LINK_HI, x
    ld   scw_r8 >> 8, [x]
    ld   draw_panel >> 8, y
    jmp  draw_panel
scw_r8:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the frame loop
; ============================================================
s_ovl:
    #d "SCRAP.OVL", 0x00
s_dmg:
    #d "DAMAGE ", 0x00

; ------------------------------------------------------------
; sc_leave - the library's lib_leave (LEAVE) copied into the RAM: the
; ROM is mapped out while this program runs
; ------------------------------------------------------------
sc_leave:
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
; l_* - the library routines, called under the library's map
; ------------------------------------------------------------
map_put:
    ld   [a_pg], y
    ld   [a_ix], x
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; drawing the view
; ============================================================

; draw_cell - the art of type dc_t at screen cell dc_cx, dc_cy.  A leaf.
in_view:
    ld   [m_yh], ac
    beq  iv_y
    ld   [m_yl], ac
    sub  0x80, ac
    bcs  iv_y
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
iv_y:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; hover_update - from the pointer: the cell under it (the frame, and the
; panel when it is not locked), or the action row under it

#addr 0x0200
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames_io
    ld   scw_r9, [x]
    ld   LINK_HI, x
    ld   scw_r9 >> 8, [x]
    ld   l_wait_frames_io >> 8, y
    jmp  l_wait_frames_io
scw_r9:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   scw_r10, [x]
    ld   LINK_HI, x
    ld   scw_r10 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
scw_r10:
    ld   LINK_LO, x             ; CALL l_menu_poll
    ld   scw_r11, [x]
    ld   LINK_HI, x
    ld   scw_r11 >> 8, [x]
    ld   l_menu_poll >> 8, y
    jmp  l_menu_poll
scw_r11:
    ld   LINK_LO, x             ; CALL input_mouse
    ld   scw_r12, [x]
    ld   LINK_HI, x
    ld   scw_r12 >> 8, [x]
    ld   input_mouse >> 8, y
    jmp  input_mouse
scw_r12:
    ld   LINK_LO, x             ; CALL input_keys
    ld   scw_r13, [x]
    ld   LINK_HI, x
    ld   scw_r13 >> 8, [x]
    ld   input_keys >> 8, y
    jmp  input_keys
scw_r13:
    ld   LINK_LO, x             ; CALL input_walk
    ld   scw_r14, [x]
    ld   LINK_HI, x
    ld   scw_r14 >> 8, [x]
    ld   input_walk >> 8, y
    jmp  input_walk
scw_r14:
    ld   LINK_LO, x             ; CALL update_panel
    ld   scw_r15, [x]
    ld   LINK_HI, x
    ld   scw_r15 >> 8, [x]
    ld   update_panel >> 8, y
    jmp  update_panel
scw_r15:
    ld   loop >> 8, y
    jmp  loop

; the file the library reads (below x6000: it runs under map 07)
l_wait_frames_io:
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
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   scw_r16, [x]
    ld   LINK_HI, x
    ld   scw_r16 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
scw_r16:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r17, [x]
    ld   LINK_HI, x
    ld   scw_r17 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
scw_r17:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r18, [x]
    ld   LINK_HI, x
    ld   scw_r18 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
scw_r18:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

set_msg:
    ld   [R0], ac
    ld   ac, [msg_l]
    ld   [R1], ac
    ld   ac, [msg_h]
    ld   MSG_FRAMES, ac
    ld   ac, [msg_t]
    ld   [dirty], ac
    or   2, ac
    ld   ac, [dirty]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the panel
; ============================================================

; update_panel - once a frame: the message's time, what changed

#addr 0x0300
l_menu_poll:
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
    ld   LINK_LO, x             ; CALL menu_poll
    ld   scw_r19, [x]
    ld   LINK_HI, x
    ld   scw_r19 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
scw_r19:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

l_pad_read:
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
    ld   LINK_LO, x             ; CALL pad_read
    ld   scw_r20, [x]
    ld   LINK_HI, x
    ld   scw_r20 >> 8, [x]
    ld   pad_read >> 8, y
    jmp  pad_read
scw_r20:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

l_mouse_init:
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
    ld   LINK_LO, x             ; CALL mouse_init
    ld   scw_r21, [x]
    ld   LINK_HI, x
    ld   scw_r21 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
scw_r21:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

l_mouse_poll:
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
    ld   LINK_LO, x             ; CALL mouse_poll
    ld   scw_r22, [x]
    ld   LINK_HI, x
    ld   scw_r22 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
scw_r22:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

l_mouse_move:
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
    ld   LINK_LO, x             ; CALL mouse_move
    ld   scw_r23, [x]
    ld   LINK_HI, x
    ld   scw_r23 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
scw_r23:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

tab_ptr:
    ld   [u5], y
    ld   [u6], x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [u7], x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; text (tracker.masm's tputc, with p_inv)
; ============================================================

; tputc - AC at CUR_ROW, CUR_COL (2x text rows), CUR_COL + 1.  A leaf.

#addr 0x0400
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
    ld   scw_r24, [x]
    ld   LINK_HI, x
    ld   scw_r24 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
scw_r24:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r25, [x]
    ld   LINK_HI, x
    ld   scw_r25 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
scw_r25:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r26, [x]
    ld   LINK_HI, x
    ld   scw_r26 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
scw_r26:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r27, [x]
    ld   LINK_HI, x
    ld   scw_r27 >> 8, [x]
    ld   vid_mode >> 8, y
    jmp  vid_mode
scw_r27:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ------------------------------------------------------------
; ovl_load - SCRAP.OVL (the map) into the even pages from MAP_PAGE: a
; sector holds two of them (tracker.masm's ovl_load)
; ------------------------------------------------------------
map_get:
    ld   [g_x], ac              ; page x60 + 4 (6 (y >> 4) + (x >> 4))
    and  0xF0, ac
    shr  ac
    shr  ac
    ld   ac, [a_pg]
    ld   [g_y], ac
    and  0xF0, ac               ; 16 (y >> 4), then x 1.5 = 24 (y >> 4)
    ld   ac, [u0]
    shr  ac
    add  [u0], ac
    add  [a_pg], ac
    add  MAP_PAGE, ac
    ld   ac, [a_pg]
    ld   [g_y], ac              ; index 16 (y & 15) + (x & 15)
    shl
    shl
    shl
    shl
    ld   ac, [u0]
    ld   [g_x], ac
    and  0x0F, ac
    or   [u0], ac
    ld   ac, [a_ix]
    ld   [a_pg], ac
    add  2, ac
    ld   ac, y
    ld   [a_ix], x
    ld   [y,x], ac
    ld   ac, [c_f]
    ld   [a_pg], y
    ld   [y,x], ac
    ld   ac, [c_t]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; map_put - AC = the new type of the cell map_get last found.  A leaf.

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
    ld   scw_r28, [x]
    ld   LINK_HI, x
    ld   scw_r28 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
scw_r28:
    bne  ov_e
    ld   MAP_PAGE, ac
    ld   ac, [u5]
ov_s:
    ld   FBUF & 0xFF, ac
    ld   ac, [R4]
    ld   FBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_read
    ld   scw_r29, [x]
    ld   LINK_HI, x
    ld   scw_r29 >> 8, [x]
    ld   l_fs_read >> 8, y
    jmp  l_fs_read
scw_r29:
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
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ------------------------------------------------------------
; screen_init - the pixels (the odd pages) cleared; every line 4 bpp
; 2x, the panel's lines 1 bpp 2x, its name row tinted
; ------------------------------------------------------------
screen_init:
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
sci_p:
    ld   [u0], y
    clr  ac
sci_b:
    ld   ac, x
    ld   0x00, [y,x]
    inc
    bne  sci_b
    ld   [u0], ac
    add  2, ac
    ld   ac, [u0]
    xor  0x01, ac
    bne  sci_p
    ld   0x06, ac               ; 4 bpp, 2x
    ld   LINK_LO, x             ; CALL l_vid_mode
    ld   scw_r30, [x]
    ld   LINK_HI, x
    ld   scw_r30 >> 8, [x]
    ld   l_vid_mode >> 8, y
    jmp  l_vid_mode
scw_r30:
    ld   0x5B, y                ; lines 384-479: x5BA0-x5BFF
    ld   0xA0, ac
    ld   ac, [u1]
sci_m:
    ld   [u1], x
    ld   [u1], ac
    sub  0xB0, ac
    bcc  si_m4
    ld   TINT_NAME | 0x04, [y,x]
    bra  sci_mn
si_m4:
    ld   0x04, [y,x]
sci_mn:
    ld   [u1], ac
    inc
    ld   ac, [u1]
    bne  sci_m
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; the map
; ============================================================

; map_get - g_x, g_y: c_t = the type, c_f = the flags, a_pg:a_ix = the
; type byte's address (the flags are two pages up).  AC = c_t.  A leaf.
camera_fit:
    ld   [p_x], ac
    sub  9, ac
    bcc  cf_1
    clr  ac
cf_1:
    ld   ac, [v_x]
    sub  MAP_W - VIEW_W + 1, ac
    bcs  cf_2
    ld   MAP_W - VIEW_W, ac
    ld   ac, [v_x]
cf_2:
    ld   [p_y], ac
    sub  6, ac
    bcc  cf_3
    clr  ac
cf_3:
    ld   ac, [v_y]
    sub  MAP_H - VIEW_H + 1, ac
    bcs  cf_4
    ld   MAP_H - VIEW_H, ac
    ld   ac, [v_y]
cf_4:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; camera_follow - the view one cell over when the player is within 4
; cells of its side (3 of its top or bottom).  AC = 1 when it moved.  A
; leaf.

#addr 0x0600
draw_cell:
    ld   [dc_t], ac
    shr  ac
    shr  ac
    add  ART_PG, ac
    ld   ac, [dc_ap]
    ld   [dc_t], ac
    and  3, ac
    shl
    shl
    shl
    shl
    shl
    shl
    ld   ac, [dc_ai]
    ld   [dc_cx], ac
    shl
    shl
    shl
    add  0x61, ac
    ld   ac, [dc_sp]
    ld   [dc_cy], ac
    sub  7, ac
    blt  ca_lo26
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    sub  223, ac
    bra  ca_go26
ca_lo26:
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    add  32, ac
ca_go26:
    ld   ac, [dc_base]
    ld   4, ac
    ld   ac, [dc_c]
dc_col:
    ld   [dc_base], ac
    ld   ac, [dc_so]
    ld   16, ac
    ld   ac, [dc_n]
dc_byte:
    ld   [dc_ap], y
    ld   [dc_ai], x
    ld   [y,x], ac
    ld   [dc_sp], y
    ld   [dc_so], x
    ld   ac, [y,x]
    ld   [dc_ai], ac
    inc
    ld   ac, [dc_ai]
    ld   [dc_so], ac
    add  2, ac
    ld   ac, [dc_so]
    ld   [dc_n], ac
    dec
    ld   ac, [dc_n]
    bne  dc_byte
    ld   [dc_sp], ac
    add  2, ac
    ld   ac, [dc_sp]
    ld   [dc_c], ac
    dec
    ld   ac, [dc_c]
    bne  dc_col
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; draw_frame - a yellow frame around screen cell dc_cx, dc_cy (over what
; is drawn there).  A leaf.
draw_frame:
    ld   [dc_cx], ac
    shl
    shl
    shl
    add  0x61, ac
    ld   ac, [dc_sp]
    ld   [dc_cy], ac
    sub  7, ac
    blt  ca_lo27
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    sub  223, ac
    bra  ca_go27
ca_lo27:
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    add  32, ac
ca_go27:
    ld   ac, [dc_base]
    ld   [dc_sp], ac
    ld   ac, [u0]
    ld   4, ac
    ld   ac, [dc_c]
fr_tb:
    ld   [u0], y                ; the top and bottom line pairs
    ld   [dc_base], x
    ld   FRAME_COL * 0x11, [y,x]
    ld   [dc_base], ac
    add  30, ac
    ld   ac, x
    ld   FRAME_COL * 0x11, [y,x]
    ld   [u0], ac
    add  2, ac
    ld   ac, [u0]
    ld   [dc_c], ac
    dec
    ld   ac, [dc_c]
    bne  fr_tb
    ld   [dc_base], ac          ; the sides: the left pixel of column 0,
    add  2, ac                  ; the right pixel of column 3
    ld   ac, [dc_so]
    ld   14, ac
    ld   ac, [dc_n]
fr_s:
    ld   [dc_sp], y
    ld   [dc_so], x
    ld   [y,x], ac
    and  0xF0, ac
    or   FRAME_COL, ac
    ld   ac, [y,x]
    ld   [dc_sp], ac
    add  6, ac
    ld   ac, y
    ld   [y,x], ac
    and  0x0F, ac
    or   FRAME_COL << 4, ac
    ld   ac, [y,x]
    ld   [dc_so], ac
    add  2, ac
    ld   ac, [dc_so]
    ld   [dc_n], ac
    dec
    ld   ac, [dc_n]
    bne  fr_s
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; view_cell - screen cell dc_cx, dc_cy from the map (the player on it
; when it is the player's cell); g_x, g_y = that map cell

#addr 0x0700
view_cell:
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
    ld   [v_x], ac
    add  [dc_cx], ac
    ld   ac, [g_x]
    ld   [v_y], ac
    add  [dc_cy], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r31, [x]
    ld   LINK_HI, x
    ld   scw_r31 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r31:
    ld   ac, [dc_t]
    ld   [g_x], ac
    xor  [p_x], ac
    bne  vc_d
    ld   [g_y], ac
    xor  [p_y], ac
    bne  vc_d
    ld   T_PLAYER, ac
    ld   ac, [dc_t]
vc_d:
    ld   LINK_LO, x             ; CALL draw_cell
    ld   scw_r32, [x]
    ld   LINK_HI, x
    ld   scw_r32 >> 8, [x]
    ld   draw_cell >> 8, y
    jmp  draw_cell
scw_r32:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_view - every cell of the view, then the frame
draw_view:
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
    ld   ac, [fr_on]
    ld   ac, [dc_cy]
dv_row:
    clr  ac
    ld   ac, [dc_cx]
dv_cell:
    ld   LINK_LO, x             ; CALL view_cell
    ld   scw_r33, [x]
    ld   LINK_HI, x
    ld   scw_r33 >> 8, [x]
    ld   view_cell >> 8, y
    jmp  view_cell
scw_r33:
    ld   [dc_cx], ac
    inc
    ld   ac, [dc_cx]
    xor  VIEW_W, ac
    bne  dv_cell
    ld   [dc_cy], ac
    inc
    ld   ac, [dc_cy]
    xor  VIEW_H, ac
    bne  dv_row
    ld   LINK_LO, x             ; CALL frame_set
    ld   scw_r34, [x]
    ld   LINK_HI, x
    ld   scw_r34 >> 8, [x]
    ld   frame_set >> 8, y
    jmp  frame_set
scw_r34:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; refresh_cell - map cell g_x, g_y drawn again if it is in the view (with
; the frame when the frame is on it)
refresh_cell:
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
    ld   [g_x], ac
    sub  [v_x], ac
    ld   ac, [dc_cx]
    sub  VIEW_W, ac
    bcc  rc_e
    ld   [g_y], ac
    sub  [v_y], ac
    ld   ac, [dc_cy]
    sub  VIEW_H, ac
    bcc  rc_e
    ld   LINK_LO, x             ; CALL view_cell
    ld   scw_r35, [x]
    ld   LINK_HI, x
    ld   scw_r35 >> 8, [x]
    ld   view_cell >> 8, y
    jmp  view_cell
scw_r35:
    ld   [fr_on], ac
    beq  rc_e
    ld   [g_x], ac
    xor  [fr_x], ac
    bne  rc_e
    ld   [g_y], ac
    xor  [fr_y], ac
    bne  rc_e
    ld   LINK_LO, x             ; CALL draw_frame
    ld   scw_r36, [x]
    ld   LINK_HI, x
    ld   scw_r36 >> 8, [x]
    ld   draw_frame >> 8, y
    jmp  draw_frame
scw_r36:
rc_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; frame_set - the frame off its old cell, onto h_x, h_y (when h_on)

#addr 0x0800
frame_set:
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
    ld   [fr_on], ac
    beq  fs_n
    clr  ac
    ld   ac, [fr_on]
    ld   [fr_x], ac
    ld   ac, [g_x]
    ld   [fr_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r37, [x]
    ld   LINK_HI, x
    ld   scw_r37 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r37:
fs_n:
    ld   [h_on], ac
    beq  fs_e
    ld   ac, [fr_on]
    ld   [h_x], ac
    ld   ac, [fr_x]
    ld   ac, [g_x]
    ld   [h_y], ac
    ld   ac, [fr_y]
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r38, [x]
    ld   LINK_HI, x
    ld   scw_r38 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r38:
fs_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; camera_fit - the view around the player (start).  A leaf.
camera_follow:
    clr  ac
    ld   ac, [u7]
    ld   [p_x], ac
    sub  [v_x], ac
    ld   ac, [u0]
    sub  4, ac
    bcc  cw_r
    ld   [v_x], ac
    beq  cw_y
    dec
    ld   ac, [v_x]
    ld   1, ac
    ld   ac, [u7]
    bra  cw_y
cw_r:
    ld   [u0], ac
    sub  VIEW_W - 4, ac
    bcs  cw_y
    ld   [v_x], ac
    xor  MAP_W - VIEW_W, ac
    beq  cw_y
    ld   [v_x], ac
    inc
    ld   ac, [v_x]
    ld   1, ac
    ld   ac, [u7]
cw_y:
    ld   [p_y], ac
    sub  [v_y], ac
    ld   ac, [u0]
    sub  3, ac
    bcc  cw_d
    ld   [v_y], ac
    beq  cw_e
    dec
    ld   ac, [v_y]
    ld   1, ac
    ld   ac, [u7]
    bra  cw_e
cw_d:
    ld   [u0], ac
    sub  VIEW_H - 3, ac
    bcs  cw_e
    ld   [v_y], ac
    xor  MAP_H - VIEW_H, ac
    beq  cw_e
    ld   [v_y], ac
    inc
    ld   ac, [v_y]
    ld   1, ac
    ld   ac, [u7]
cw_e:
    ld   [u7], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the mouse
; ============================================================

; input_mouse - the pointer moved: the hover; new presses: the clicks
hover_panel:
    ld   0xFF, ac
    ld   ac, [u3]
    ld   [m_xh], ac             ; x >= 432 (column 54)
    beq  hp_s
    ld   [m_xl], ac
    sub  0xB0, ac
    bcs  hp_s
    ld   [m_yl], ac             ; text row (y - 384) / 16, rows 25-28
    sub  0x80, ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    dec
    ld   ac, [u4]
    sub  [n_act], ac
    bcc  hp_s
    ld   [u4], ac
    ld   ac, [u3]
hp_s:
    ld   [u3], ac
    ld   ac, [m_sel]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; subject_hover - the panel on the cell under the pointer.  A leaf.
msg_tint:
    ld   ac, [u0]
    ld   0xF0, ac
    ld   ac, [u1]
    ld   0x5B, y
mt_l:
    ld   [u1], x
    ld   [u0], ac
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    bne  mt_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; clear_rows - the text from offset AC (odd) to 255 in every odd page:
; 161 the panel, 241 its last row.  A leaf.

#addr 0x0900
input_mouse:
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
    ld   [m_ok], ac
    beq  im_e
    ld   LINK_LO, x             ; CALL l_mouse_poll
    ld   scw_r39, [x]
    ld   LINK_HI, x
    ld   scw_r39 >> 8, [x]
    ld   l_mouse_poll >> 8, y
    jmp  l_mouse_poll
scw_r39:
    beq  im_b
    ld   [m_xl], ac
    ld   ac, [R0]
    ld   [m_xh], ac
    ld   ac, [R1]
    ld   [m_yl], ac
    ld   ac, [R2]
    ld   [m_yh], ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL l_mouse_move
    ld   scw_r40, [x]
    ld   LINK_HI, x
    ld   scw_r40 >> 8, [x]
    ld   l_mouse_move >> 8, y
    jmp  l_mouse_move
scw_r40:
    ld   [R0], ac
    ld   ac, [m_xl]
    ld   [R1], ac
    ld   ac, [m_xh]
    ld   [R2], ac
    ld   ac, [m_yl]
    ld   [R3], ac
    ld   ac, [m_yh]
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r41, [x]
    ld   LINK_HI, x
    ld   scw_r41 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r41:
im_b:
    ld   [m_b], ac
    xor  0xFF, ac
    and  [MOUSE_B], ac
    ld   ac, [mb_new]
    ld   [MOUSE_B], ac
    ld   ac, [m_b]
    ld   [mb_new], ac
    and  1, ac
    beq  im_r
    ld   LINK_LO, x             ; CALL click_left
    ld   scw_r42, [x]
    ld   LINK_HI, x
    ld   scw_r42 >> 8, [x]
    ld   click_left >> 8, y
    jmp  click_left
scw_r42:
im_r:
    ld   [mb_new], ac
    and  2, ac
    beq  im_e
    ld   LINK_LO, x             ; CALL click_right
    ld   scw_r43, [x]
    ld   LINK_HI, x
    ld   scw_r43 >> 8, [x]
    ld   click_right >> 8, y
    jmp  click_right
scw_r43:
im_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; in_view - AC = 1 when the pointer is over the view (y < 384).  A leaf.
subject_hover:
    ld   [h_on], ac
    beq  sh_e
    ld   [h_x], ac
    ld   ac, [s_x]
    ld   [h_y], ac
    ld   ac, [s_y]
    ld   1, ac
    ld   ac, [s_who]
    ld   [h_x], ac
    xor  [p_x], ac
    bne  sh_d
    ld   [h_y], ac
    xor  [p_y], ac
    bne  sh_d
    ld   2, ac
    ld   ac, [s_who]
sh_d:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
sh_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; click_left - on an action: do it; on the view: lock the panel there
click_right:
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
    ld   ac, [lock]
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r51, [x]
    ld   LINK_HI, x
    ld   scw_r51 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r51:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; keys and walking
; ============================================================

; input_keys - 1-4: the panel's actions

#addr 0x0A00
hover_update:
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
    ld   LINK_LO, x             ; CALL in_view
    ld   scw_r44, [x]
    ld   LINK_HI, x
    ld   scw_r44 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r44:
    bne  hu_v
    ld   LINK_LO, x             ; CALL hover_panel
    ld   scw_r45, [x]
    ld   LINK_HI, x
    ld   scw_r45 >> 8, [x]
    ld   hover_panel >> 8, y
    jmp  hover_panel
scw_r45:
    ld   sc_leave >> 8, y
    jmp  sc_leave
hu_v:
    ld   [m_xl], ac             ; screen cell x = m_x >> 5
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u0]
    ld   [m_xh], ac
    shl
    shl
    shl
    or   [u0], ac
    add  [v_x], ac
    ld   ac, [u1]
    ld   [m_yl], ac             ; screen cell y = m_y >> 5
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u0]
    ld   [m_yh], ac
    shl
    shl
    shl
    or   [u0], ac
    add  [v_y], ac
    ld   ac, [u2]
    ld   0xFF, ac
    ld   ac, [m_sel]
    ld   [h_on], ac
    beq  hu_ch
    ld   [u1], ac
    xor  [h_x], ac
    bne  hu_ch
    ld   [u2], ac
    xor  [h_y], ac
    beq  hu_e
hu_ch:
    ld   [u1], ac
    ld   ac, [h_x]
    ld   [u2], ac
    ld   ac, [h_y]
    ld   1, ac
    ld   ac, [h_on]
    ld   LINK_LO, x             ; CALL frame_set
    ld   scw_r46, [x]
    ld   LINK_HI, x
    ld   scw_r46 >> 8, [x]
    ld   frame_set >> 8, y
    jmp  frame_set
scw_r46:
    ld   [lock], ac
    bne  hu_e
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r47, [x]
    ld   LINK_HI, x
    ld   scw_r47 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r47:
hu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; hover_panel - m_sel = the action row under the pointer (FF none).  A
; leaf.
click_left:
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
    ld   [m_sel], ac
    xor  0xFF, ac
    beq  cl_v
    ld   [m_sel], ac
    ld   LINK_LO, x             ; CALL do_action
    ld   scw_r48, [x]
    ld   LINK_HI, x
    ld   scw_r48 >> 8, [x]
    ld   do_action >> 8, y
    jmp  do_action
scw_r48:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cl_v:
    ld   LINK_LO, x             ; CALL in_view
    ld   scw_r49, [x]
    ld   LINK_HI, x
    ld   scw_r49 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r49:
    beq  cl_e
    ld   1, ac
    ld   ac, [lock]
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r50, [x]
    ld   LINK_HI, x
    ld   scw_r50 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r50:
cl_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; click_right - the panel follows the pointer again

#addr 0x0B00
input_keys:
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
    ld   LINK_LO, x             ; CALL l_kbd_getc
    ld   scw_r52, [x]
    ld   LINK_HI, x
    ld   scw_r52 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
scw_r52:
    beq  ik_e
    ld   ac, [key]
    sub  0x31, ac
    ld   ac, [u1]
    sub  4, ac
    bcc  ik_e
    ld   [u1], ac
    ld   LINK_LO, x             ; CALL do_action
    ld   scw_r53, [x]
    ld   LINK_HI, x
    ld   scw_r53 >> 8, [x]
    ld   do_action >> 8, y
    jmp  do_action
scw_r53:
ik_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; input_walk - the held directions (arrows, WASD, pad 1) or WALK HERE:
; a step every WALK_FRAMES frames
input_walk:
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
    ld   LINK_LO, x             ; CALL l_pad_read
    ld   scw_r54, [x]
    ld   LINK_HI, x
    ld   scw_r54 >> 8, [x]
    ld   l_pad_read >> 8, y
    jmp  l_pad_read
scw_r54:
    ld   LINK_LO, x             ; CALL read_dirs
    ld   scw_r55, [x]
    ld   LINK_HI, x
    ld   scw_r55 >> 8, [x]
    ld   read_dirs >> 8, y
    jmp  read_dirs
scw_r55:
    ld   [dirs], ac
    bne  iw_go
    ld   [wk_on], ac
    bne  iw_t
    clr  ac
    ld   ac, [walk_t]
    ld   sc_leave >> 8, y
    jmp  sc_leave
iw_go:
    clr  ac
    ld   ac, [wk_on]
iw_t:
    ld   [walk_t], ac
    beq  iw_step
    dec
    ld   ac, [walk_t]
    ld   sc_leave >> 8, y
    jmp  sc_leave
iw_step:
    ld   WALK_FRAMES, ac
    ld   ac, [walk_t]
    ld   [dirs], ac
    bne  iw_man
    ld   LINK_LO, x             ; CALL auto_step
    ld   scw_r56, [x]
    ld   LINK_HI, x
    ld   scw_r56 >> 8, [x]
    ld   auto_step >> 8, y
    jmp  auto_step
scw_r56:
    ld   sc_leave >> 8, y
    jmp  sc_leave
iw_man:
    ld   LINK_LO, x             ; CALL man_step
    ld   scw_r57, [x]
    ld   LINK_HI, x
    ld   scw_r57 >> 8, [x]
    ld   man_step >> 8, y
    jmp  man_step
scw_r57:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; read_dirs - dirs from the pad (R0 after pad_read, 1 = down) and the keys
; (KBD_NOW, 0 = down).  A leaf.
draw_menu:
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
    ld   [m_sel], ac
    ld   ac, [o_sel]
    clr  ac
    ld   ac, [w2]
dm_l:
    ld   LINK_LO, x             ; CALL menu_row
    ld   scw_r99, [x]
    ld   LINK_HI, x
    ld   scw_r99 >> 8, [x]
    ld   menu_row >> 8, y
    jmp  menu_row
scw_r99:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  dm_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; menu_row - action row w2

#addr 0x0C00
read_dirs:
    clr  ac
    ld   ac, [dirs]
    ld   [R0], ac               ; up: pad bit 4, Up (key 53), W (16)
    and  0x10, ac
    bne  rd_u
    ld   [KBD_NOW + 6], ac
    and  0x20, ac
    beq  rd_u
    ld   [KBD_NOW + 2], ac
    and  0x01, ac
    bne  rd_1
rd_u:
    ld   1, ac
    ld   ac, [dirs]
rd_1:
    ld   [R0], ac               ; down: pad bit 5, Down (62), S (30)
    and  0x20, ac
    bne  rd_d
    ld   [KBD_NOW + 7], ac
    and  0x40, ac
    beq  rd_d
    ld   [KBD_NOW + 3], ac
    and  0x40, ac
    bne  rd_2
rd_d:
    ld   [dirs], ac
    or   2, ac
    ld   ac, [dirs]
rd_2:
    ld   [R0], ac               ; left: pad bit 6, Left (61), A (29)
    and  0x40, ac
    bne  rd_l
    ld   [KBD_NOW + 7], ac
    and  0x20, ac
    beq  rd_l
    ld   [KBD_NOW + 3], ac
    and  0x20, ac
    bne  rd_3
rd_l:
    ld   [dirs], ac
    or   4, ac
    ld   ac, [dirs]
rd_3:
    ld   [R0], ac               ; right: pad bit 7, Right (63), D (31)
    and  0x80, ac
    bne  rd_r
    ld   [KBD_NOW + 7], ac
    and  0x80, ac
    beq  rd_r
    ld   [KBD_NOW + 3], ac
    and  0x80, ac
    bne  rd_e
rd_r:
    ld   [dirs], ac
    or   8, ac
    ld   ac, [dirs]
rd_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; man_step - one step the way dirs says (up, down, left, right first)
man_step:
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
    ld   [p_x], ac
    ld   ac, [n_x]
    ld   [p_y], ac
    ld   ac, [n_y]
    ld   [dirs], ac
    and  1, ac
    beq  ms_1
    ld   [n_y], ac
    dec
    ld   ac, [n_y]
    bra  ms_go
ms_1:
    ld   [dirs], ac
    and  2, ac
    beq  ms_2
    ld   [n_y], ac
    inc
    ld   ac, [n_y]
    bra  ms_go
ms_2:
    ld   [dirs], ac
    and  4, ac
    beq  ms_3
    ld   [n_x], ac
    dec
    ld   ac, [n_x]
    bra  ms_go
ms_3:
    ld   [n_x], ac
    inc
    ld   ac, [n_x]
ms_go:
    ld   LINK_LO, x             ; CALL try_move
    ld   scw_r58, [x]
    ld   LINK_HI, x
    ld   scw_r58 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r58:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; auto_step - WALK HERE: a step toward wk_x, wk_y (across first, then
; down or up); stops there, or when both ways are blocked
pad80:
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
pd_l:
    ld   [CUR_COL], ac
    xor  80, ac
    beq  pd_e
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r106, [x]
    ld   LINK_HI, x
    ld   scw_r106 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r106:
    bra  pd_l
pd_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_msg - row 29: the message (tinted) or nothing

#addr 0x0D00
auto_step:
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
    ld   [wk_x], ac
    sub  [p_x], ac
    ld   ac, [w5]
    ld   [wk_y], ac
    sub  [p_y], ac
    ld   ac, [w6]
    ld   [w5], ac
    or   [w6], ac
    beq  as_done
    ld   [p_y], ac
    ld   ac, [n_y]
    ld   [p_x], ac
    ld   ac, [n_x]
    ld   [w5], ac
    beq  as_y
    blt  as_xm
    ld   [n_x], ac
    inc
    bra  as_xs
as_xm:
    ld   [n_x], ac
    dec
as_xs:
    ld   ac, [n_x]
    ld   LINK_LO, x             ; CALL try_move
    ld   scw_r59, [x]
    ld   LINK_HI, x
    ld   scw_r59 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r59:
    bne  as_e
as_y:
    ld   [p_x], ac
    ld   ac, [n_x]
    ld   [p_y], ac
    ld   ac, [n_y]
    ld   [w6], ac
    beq  as_blk
    blt  as_ym
    ld   [n_y], ac
    inc
    bra  as_ys
as_ym:
    ld   [n_y], ac
    dec
as_ys:
    ld   ac, [n_y]
    ld   LINK_LO, x             ; CALL try_move
    ld   scw_r60, [x]
    ld   LINK_HI, x
    ld   scw_r60 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r60:
    bne  as_e
as_blk:
    ld   s_blocked & 0xFF, ac
    ld   ac, [R0]
    ld   s_blocked >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r61, [x]
    ld   LINK_HI, x
    ld   scw_r61 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r61:
as_done:
    clr  ac
    ld   ac, [wk_on]
as_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; try_move - a step to n_x, n_y: AC = 0 blocked, 1 moved, 2 a closed
; door there opened (the step is the next one)
update_panel:
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
    ld   [msg_t], ac
    beq  up_1
    dec
    ld   ac, [msg_t]
    bne  up_1
    ld   [dirty], ac
    or   2, ac
    ld   ac, [dirty]
up_1:
    ld   [dirty], ac
    and  1, ac
    beq  up_2
    clr  ac
    ld   ac, [dirty]
    ld   LINK_LO, x             ; CALL draw_panel
    ld   scw_r79, [x]
    ld   LINK_HI, x
    ld   scw_r79 >> 8, [x]
    ld   draw_panel >> 8, y
    jmp  draw_panel
scw_r79:
    ld   sc_leave >> 8, y
    jmp  sc_leave
up_2:
    ld   [dirty], ac
    and  2, ac
    beq  up_3
    clr  ac
    ld   ac, [dirty]
    ld   LINK_LO, x             ; CALL draw_msg
    ld   scw_r80, [x]
    ld   LINK_HI, x
    ld   scw_r80 >> 8, [x]
    ld   draw_msg >> 8, y
    jmp  draw_msg
scw_r80:
up_3:
    ld   [m_sel], ac
    xor  [o_sel], ac
    beq  up_e
    ld   LINK_LO, x             ; CALL draw_menu
    ld   scw_r81, [x]
    ld   LINK_HI, x
    ld   scw_r81 >> 8, [x]
    ld   draw_menu >> 8, y
    jmp  draw_menu
scw_r81:
up_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_panel - the whole panel

#addr 0x0E00
try_move:
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
    ld   [n_x], ac
    sub  MAP_W, ac
    bcc  tm_no
    ld   [n_y], ac
    sub  MAP_H, ac
    bcc  tm_no
    ld   [n_x], ac
    ld   ac, [g_x]
    ld   [n_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r62, [x]
    ld   LINK_HI, x
    ld   scw_r62 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r62:
    xor  T_DOOR, ac
    bne  tm_w
    ld   T_DOORO, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r63, [x]
    ld   LINK_HI, x
    ld   scw_r63 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r63:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r64, [x]
    ld   LINK_HI, x
    ld   scw_r64 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r64:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   2, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
tm_w:
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_WALK, ac
    beq  tm_no
    ld   LINK_LO, x             ; CALL move_player
    ld   scw_r65, [x]
    ld   LINK_HI, x
    ld   scw_r65 >> 8, [x]
    ld   move_player >> 8, y
    jmp  move_player
scw_r65:
    ld   1, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
tm_no:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; move_player - the player to n_x, n_y: both cells drawn, the camera, the
; hover and the panel
do_action:
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
    ld   ac, [u0]
    sub  [n_act], ac
    bcc  da_e
    ld   [u0], ac
    add  act0, ac
    ld   ac, x
    ld   [x], ac
    ld   ac, [w3]
    xor  A_INSPECT, ac
    bne  da_1
    ld   TAB_PG, ac             ; INSPECT: the type's line
    ld   ac, [u5]
    ld   [s_t], ac
    add  TB_INSPL, ac
    ld   ac, [u6]
    ld   [s_t], ac
    add  TB_INSPH, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r72, [x]
    ld   LINK_HI, x
    ld   scw_r72 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r72:
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r73, [x]
    ld   LINK_HI, x
    ld   scw_r73 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r73:
    ld   sc_leave >> 8, y
    jmp  sc_leave
da_1:
    ld   [w3], ac
    xor  A_WALK, ac
    bne  da_2
    ld   [s_x], ac              ; WALK HERE
    ld   ac, [wk_x]
    ld   [s_y], ac
    ld   ac, [wk_y]
    ld   1, ac
    ld   ac, [wk_on]
    ld   sc_leave >> 8, y
    jmp  sc_leave
da_2:
    ld   door_action >> 8, y
    jmp  door_action
da_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; door_action - OPEN or CLOSE (w3) the door the panel shows, from next
; to it (the rest of do_action: its LEAVE)

#addr 0x0F00
move_player:
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
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   [n_x], ac
    ld   ac, [p_x]
    ld   [n_y], ac
    ld   ac, [p_y]
    ld   LINK_LO, x             ; the old cell, without the player
    ld   scw_r66, [x]
    ld   LINK_HI, x
    ld   scw_r66 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r66:
    ld   LINK_LO, x             ; CALL camera_follow
    ld   scw_r67, [x]
    ld   LINK_HI, x
    ld   scw_r67 >> 8, [x]
    ld   camera_follow >> 8, y
    jmp  camera_follow
scw_r67:
    beq  mp_s
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r68, [x]
    ld   LINK_HI, x
    ld   scw_r68 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r68:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r69, [x]
    ld   LINK_HI, x
    ld   scw_r69 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r69:
    bra  mp_p
mp_s:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r70, [x]
    ld   LINK_HI, x
    ld   scw_r70 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r70:
mp_p:
    ld   [lock], ac
    bne  mp_e
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r71, [x]
    ld   LINK_HI, x
    ld   scw_r71 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r71:
mp_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; actions
; ============================================================

; do_action - AC = the panel's action row 0-3
subj_load:
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
    ld   [s_who], ac
    xor  2, ac
    bne  sl_c
    ld   T_PLAYER, ac
    ld   ac, [s_t]
    clr  ac
    ld   ac, [s_f]
    bra  sl_a
sl_c:
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r90, [x]
    ld   LINK_HI, x
    ld   scw_r90 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r90:
    ld   ac, [s_t]
    ld   [c_f], ac
    and  0x0F, ac
    ld   ac, [s_f]
sl_a:
    clr  ac
    ld   ac, [n_act]
    ld   [s_t], ac              ; ACT_PG: 4 t + i
    shl
    shl
    ld   ac, [u0]
sl_l:
    ld   ACT_PG, y
    ld   [u0], x
    ld   [y,x], ac
    beq  sl_e
    ld   ac, [u1]
    ld   [n_act], ac
    add  act0, ac
    ld   ac, x
    ld   [u1], ac
    ld   ac, [x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    ld   [n_act], ac
    inc
    ld   ac, [n_act]
    xor  4, ac
    bne  sl_l
sl_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_dmg - "DAMAGE [###-------] 19%" at row 24, column 54

#addr 0x1000
door_action:
    ld   [s_x], ac              ; within one cell of the player
    sub  [p_x], ac
    inc
    sub  3, ac
    bcc  dr_far
    ld   [s_y], ac
    sub  [p_y], ac
    inc
    sub  3, ac
    bcc  dr_far
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   [w3], ac
    xor  A_OPEN, ac
    bne  dr_cl
    ld   T_DOORO, ac
    bra  dr_set
dr_cl:
    ld   [s_x], ac              ; not on the player
    xor  [p_x], ac
    bne  dr_ok
    ld   [s_y], ac
    xor  [p_y], ac
    bne  dr_ok
    ld   s_inway & 0xFF, ac
    ld   ac, [R0]
    ld   s_inway >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r74, [x]
    ld   LINK_HI, x
    ld   scw_r74 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r74:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dr_ok:
    ld   T_DOOR, ac
dr_set:
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r75, [x]
    ld   LINK_HI, x
    ld   scw_r75 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r75:
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r76, [x]
    ld   LINK_HI, x
    ld   scw_r76 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r76:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r77, [x]
    ld   LINK_HI, x
    ld   scw_r77 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r77:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   sc_leave >> 8, y
    jmp  sc_leave
dr_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r78, [x]
    ld   LINK_HI, x
    ld   scw_r78 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r78:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; set_msg - the message R1:R0 on row 29 for MSG_FRAMES.  A leaf.
draw_info:
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
di_l:
    ld   [w2], ac
    add  25, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   INFO_PG, ac
    ld   ac, [u5]
    ld   [s_t], ac
    shl
    shl
    add  [w2], ac
    ld   ac, [u6]
    add  0x80, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r97, [x]
    ld   LINK_HI, x
    ld   scw_r97 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r97:
    ld   [R1], ac
    beq  di_n
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r98, [x]
    ld   LINK_HI, x
    ld   scw_r98 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r98:
di_n:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  di_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_menu - the action column, rows 25-28 from column 52 (the row
; under the pointer in inverse)

#addr 0x1100
draw_panel:
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
    ld   161, ac                ; rows 24-29: offsets 161-255
    ld   LINK_LO, x             ; CALL clear_rows
    ld   scw_r82, [x]
    ld   LINK_HI, x
    ld   scw_r82 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r82:
    clr  ac
    ld   ac, [n_act]
    ld   [s_who], ac
    beq  dp_m
    ld   LINK_LO, x             ; CALL subj_load
    ld   scw_r83, [x]
    ld   LINK_HI, x
    ld   scw_r83 >> 8, [x]
    ld   subj_load >> 8, y
    jmp  subj_load
scw_r83:
    ld   24, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   TAB_PG, ac
    ld   ac, [u5]
    ld   [s_t], ac
    add  TB_NAMEL, ac
    ld   ac, [u6]
    ld   [s_t], ac
    add  TB_NAMEH, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r84, [x]
    ld   LINK_HI, x
    ld   scw_r84 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r84:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r85, [x]
    ld   LINK_HI, x
    ld   scw_r85 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r85:
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_DMG, ac
    beq  dp_i
    ld   LINK_LO, x             ; CALL draw_dmg
    ld   scw_r86, [x]
    ld   LINK_HI, x
    ld   scw_r86 >> 8, [x]
    ld   draw_dmg >> 8, y
    jmp  draw_dmg
scw_r86:
dp_i:
    ld   LINK_LO, x             ; CALL draw_info
    ld   scw_r87, [x]
    ld   LINK_HI, x
    ld   scw_r87 >> 8, [x]
    ld   draw_info >> 8, y
    jmp  draw_info
scw_r87:
dp_m:
    ld   LINK_LO, x             ; CALL draw_menu
    ld   scw_r88, [x]
    ld   LINK_HI, x
    ld   scw_r88 >> 8, [x]
    ld   draw_menu >> 8, y
    jmp  draw_menu
scw_r88:
    ld   LINK_LO, x             ; CALL draw_msg
    ld   scw_r89, [x]
    ld   LINK_HI, x
    ld   scw_r89 >> 8, [x]
    ld   draw_msg >> 8, y
    jmp  draw_msg
scw_r89:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; subj_load - s_t, s_f, n_act and the action codes of the subject
clear_rows:
    ld   ac, [u1]
    ld   0x61, ac
    ld   ac, [u0]
cr_p:
    ld   [u0], y
    ld   [u1], ac
cr_b:
    ld   ac, x
    ld   0x00, [y,x]
    add  2, ac
    bcc  cr_b
    ld   [u0], ac
    add  2, ac
    ld   ac, [u0]
    xor  0x01, ac
    bne  cr_p
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tab_ptr - R1:R0 = the pointer whose low byte is at page u5 + u6 and
; high byte at page u5 + u7.  A leaf.

#addr 0x1200
draw_dmg:
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
    ld   54, ac
    ld   ac, [CUR_COL]
    ld   s_dmg & 0xFF, ac
    ld   ac, [R0]
    ld   s_dmg >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r91, [x]
    ld   LINK_HI, x
    ld   scw_r91 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r91:
    ld   BAR_PG, ac
    ld   ac, [u5]
    ld   [s_f], ac
    ld   ac, [u6]
    add  16, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r92, [x]
    ld   LINK_HI, x
    ld   scw_r92 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r92:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r93, [x]
    ld   LINK_HI, x
    ld   scw_r93 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r93:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r94, [x]
    ld   LINK_HI, x
    ld   scw_r94 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r94:
    ld   TAB_PG, ac
    ld   ac, [u5]
    ld   [s_f], ac
    add  TB_DMGL, ac
    ld   ac, [u6]
    ld   [s_f], ac
    add  TB_DMGH, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r95, [x]
    ld   LINK_HI, x
    ld   scw_r95 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r95:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r96, [x]
    ld   LINK_HI, x
    ld   scw_r96 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r96:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_info - the subject's 4 info lines, rows 25-28 from column 1
draw_msg:
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
    ld   241, ac                ; row 29: offsets 241-255
    ld   LINK_LO, x             ; CALL clear_rows
    ld   scw_r107, [x]
    ld   LINK_HI, x
    ld   scw_r107 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r107:
    ld   [msg_t], ac
    beq  dm_off
    ld   TINT_MSG | 0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r108, [x]
    ld   LINK_HI, x
    ld   scw_r108 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r108:
    ld   29, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   [msg_l], ac
    ld   ac, [R0]
    ld   [msg_h], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r109, [x]
    ld   LINK_HI, x
    ld   scw_r109 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r109:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dm_off:
    ld   0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r110, [x]
    ld   LINK_HI, x
    ld   scw_r110 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r110:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; msg_tint - AC = the mode byte of row 29's lines (x5BF0-x5BFF).  A leaf.

#addr 0x1300
menu_row:
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
    ld   [w2], ac
    add  25, ac
    ld   ac, [CUR_ROW]
    ld   52, ac
    ld   ac, [CUR_COL]
    ld   [s_who], ac
    beq  mr_sp
    ld   0x7C, ac               ; |
    bra  mr_c
mr_sp:
    ld   0x20, ac
mr_c:
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r100, [x]
    ld   LINK_HI, x
    ld   scw_r100 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r100:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r101, [x]
    ld   LINK_HI, x
    ld   scw_r101 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r101:
    ld   [w2], ac
    sub  [n_act], ac
    bcc  mr_pad
    ld   [w2], ac
    xor  [m_sel], ac
    bne  mr_ni
    ld   0x80, ac
    ld   ac, [p_inv]
mr_ni:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r102, [x]
    ld   LINK_HI, x
    ld   scw_r102 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r102:
    ld   [w2], ac
    add  act0, ac
    ld   ac, x
    ld   [x], ac
    ld   ac, [u0]
    ld   TAB_PG, ac
    ld   ac, [u5]
    ld   [u0], ac
    add  TB_ASTRL, ac
    ld   ac, [u6]
    ld   [u0], ac
    add  TB_ASTRH, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r103, [x]
    ld   LINK_HI, x
    ld   scw_r103 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r103:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r104, [x]
    ld   LINK_HI, x
    ld   scw_r104 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r104:
mr_pad:
    ld   LINK_LO, x             ; CALL pad80
    ld   scw_r105, [x]
    ld   LINK_HI, x
    ld   scw_r105 >> 8, [x]
    ld   pad80 >> 8, y
    jmp  pad80
scw_r105:
    clr  ac
    ld   ac, [p_inv]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pad80 - spaces to the end of the text row

#addr 0x1400
tputc:
    or   [p_inv], ac
    ld   ac, [p_ch]
    ld   [CUR_COL], ac
    sub  80, ac
    bcc  tp_off
    ld   [CUR_COL], ac
    shl
    add  0x61, ac
    ld   ac, [p_pg]
    ld   2, ac
    ld   ac, [p_st]
    ld   [CUR_ROW], ac
    sub  14, ac
    blt  ta_2a31
    shl                         ; rows 14-29: 16 (r - 14) + 1
    shl
    shl
    shl
    inc
    ld   ac, [p_off]
    bra  ta_go31
ta_2a31:
    add  16, ac                 ; rows 0-13: 16 r + 32
    shl
    shl
    shl
    shl
    ld   ac, [p_off]
ta_go31:
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
    ld   [p_ch], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tputs - the string at R1:R0 (ending in 00); a 01 in it is the "works
; at" line for damage step s_f
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
    xor  1, ac
    beq  ts_w
    xor  1, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r111, [x]
    ld   LINK_HI, x
    ld   scw_r111 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r111:
ts_n:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  ts_l
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  ts_l
ts_w:
    ld   TAB_PG, y
    ld   [s_f], ac
    add  TB_WRKL, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   [s_f], ac
    add  TB_WRKH, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [w1]
ts_wl:
    ld   [w1], y
    ld   [w0], x
    ld   [y,x], ac
    beq  ts_n
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r112, [x]
    ld   LINK_HI, x
    ld   scw_r112 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r112:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    bne  ts_wl
    ld   [w1], ac
    inc
    ld   ac, [w1]
    bra  ts_wl
ts_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; the art, tables and strings (gen_scrap.py)
; ============================================================
; scrap_data.masm - generated by gen_scrap.py, do not edit by hand
; the art, tables and strings of scrap.masm (included at its end)


#addr 0x1500
zi_0_0:
    #d "VACUUM.  NO AIR, NO FLOOR.", 0x00
zi_1_0:
    #d "VACUUM.  NO AIR, NO FLOOR.", 0x00
zi_2_0:
    #d "STEEL DECK PLATE", 0x00
zi_2_1:
    #d "WALKABLE", 0x00
zi_3_0:
    #d "STEEL BULKHEAD, AIRTIGHT", 0x00
zi_3_1:
    #d "HOLDS AIR WHILE UNDER 50% DAMAGE", 0x00
zi_3_2:
    #d "CUT FREE WITH A CUTTER (LATER PHASE)", 0x00
zi_4_0:
    #d "PRESSURE DOOR, SEALS WHEN CLOSED", 0x00
zi_4_1:
    #d 0x01, 0x00
zi_4_2:
    #d "WALK INTO IT OR CLICK OPEN", 0x00


#addr 0x1600
zi_5_0:
    #d "PRESSURE DOOR, OPEN", 0x00
zi_5_1:
    #d 0x01, 0x00
zi_5_2:
    #d "AIR FLOWS THROUGH IT", 0x00
zi_6_0:
    #d "CAPACITY 120 L", 0x00
zi_6_1:
    #d 0x01, 0x00
zi_6_2:
    #d "HEAVY: TAKES ONE CARRY SLOT", 0x00
zi_6_3:
    #d "WORTH ABOUT $200 UNDAMAGED", 0x00
zi_7_0:
    #d "FUSION CORE, 40 KW", 0x00
zi_7_1:
    #d 0x01, 0x00
zi_7_2:
    #d "TOO HEAVY TO CARRY WHOLE", 0x00
zi_7_3:
    #d "WORTH ABOUT $2,500 UNDAMAGED", 0x00
zi_8_0:
    #d "STORAGE CELL, 8 KWH", 0x00
zi_8_1:
    #d 0x01, 0x00
zi_8_2:
    #d "HEAVY: TAKES ONE CARRY SLOT", 0x00


#addr 0x1700
zi_8_3:
    #d "WORTH ABOUT $300 UNDAMAGED", 0x00
zi_9_0:
    #d "SEALED CARGO CRATE", 0x00
zi_9_1:
    #d "CONTENTS UNKNOWN", 0x00
zi_9_2:
    #d "OPEN IT TO SEE (LATER PHASE)", 0x00
zi_10_0:
    #d "CREW BUNK", 0x00
zi_10_1:
    #d 0x01, 0x00
zi_10_2:
    #d "LIGHT SCRAP", 0x00
zi_11_0:
    #d "FLIGHT CONSOLE", 0x00
zi_11_1:
    #d 0x01, 0x00
zi_11_2:
    #d "HOLDS THE SHIP LOG (LATER PHASE)", 0x00
zi_12_0:
    #d "STEEL LOCKER, 4 SLOTS", 0x00
zi_12_1:
    #d 0x01, 0x00
zi_12_2:
    #d "MAY HOLD GEAR (LATER PHASE)", 0x00
zi_13_0:
    #d "WALL TURRET, ARC TYPE", 0x00


#addr 0x1800
zi_13_1:
    #d 0x01, 0x00
zi_13_2:
    #d "DORMANT - NO POWER", 0x00
zi_14_0:
    #d "CONDUIT UNDER THE DECK", 0x00
zi_14_1:
    #d 0x01, 0x00
zi_14_2:
    #d "CARRIES POWER BETWEEN PARTS", 0x00
zi_15_0:
    #d "DECK PLATE IN VACUUM", 0x00
zi_15_1:
    #d "THIS ROOM HAS LOST ITS AIR", 0x00
zi_15_2:
    #d "YOUR SUIT AIR ONLY", 0x00
zi_16_0:
    #d "DOCKING AIRLOCK", 0x00
zi_16_1:
    #d 0x01, 0x00
zi_16_2:
    #d "JOINS THE TUG TO THE WRECK", 0x00
zi_17_0:
    #d "FLEXIBLE DOCKING TUBE", 0x00
zi_17_1:
    #d "PRESSURIZED", 0x00
zi_18_0:
    #d "MAIN THRUSTER, 2 KN", 0x00


#addr 0x1900
zi_18_1:
    #d 0x01, 0x00
zi_18_2:
    #d "BOLTED TO THE HULL", 0x00
zi_19_0:
    #d "FUEL TANK, 400 L", 0x00
zi_19_1:
    #d 0x01, 0x00
zi_19_2:
    #d "HEAVY: TAKES ONE CARRY SLOT", 0x00
zi_20_0:
    #d "CO2 SCRUBBER", 0x00
zi_20_1:
    #d 0x01, 0x00
zi_20_2:
    #d "KEEPS A ROOM BREATHABLE", 0x00
zi_21_0:
    #d "A HOLE IN THE HULL", 0x00
zi_21_1:
    #d "AIR ESCAPES THROUGH HERE", 0x00
zi_pl_0:
    #d "SUIT   MK1 WORK SUIT     O2 90 OF 90 L", 0x00
zi_pl_1:
    #d "BATT   SMALL CELL        CHARGE 100%", 0x00


#addr 0x1A00
zi_pl_2:
    #d "HANDS  CUTTER / EMPTY    BACK  SMALL PACK 0/4", 0x00
zi_pl_3:
    #d "NO WARNINGS", 0x00
zn_0:
    #d "OPEN SPACE", 0x00
zx_0:
    #d "NOTHING OUT THERE BUT DEBRIS AND COLD.", 0x00
zn_1:
    #d "OPEN SPACE", 0x00
zx_1:
    #d "A DISTANT STAR.  NOT FOR SALE.", 0x00
zn_2:
    #d "DECK PLATE", 0x00
zx_2:
    #d "SCUFFED DECK PLATE.  SOMEONE WALKED HERE A LOT.", 0x00
zn_3:
    #d "BULKHEAD", 0x00


#addr 0x1B00
zx_3:
    #d "A SOLID BULKHEAD.  THE PAINT SAYS DECK 2.", 0x00
zn_4:
    #d "DOOR (CLOSED)", 0x00
zx_4:
    #d "A PRESSURE DOOR.  THE HAZARD STRIPES ARE FADED.", 0x00
zn_5:
    #d "DOOR (OPEN)", 0x00
zx_5:
    #d "AN OPEN PRESSURE DOOR.", 0x00
zn_6:
    #d "O2 TANK", 0x00
zx_6:
    #d "AN OXYGEN TANK.  THE GAUGE STILL MOVES.", 0x00
zn_7:
    #d "REACTOR CORE", 0x00


#addr 0x1C00
zx_7:
    #d "A REACTOR CORE.  IT IS HUMMING VERY QUIETLY.", 0x00
zn_8:
    #d "BATTERY", 0x00
zx_8:
    #d "A SHIP BATTERY.  STILL WARM.", 0x00
zn_9:
    #d "CARGO CRATE", 0x00
zx_9:
    #d "THE LABEL READS ", 0x22, "MINING CHARGES - DO NOT DROP", 0x22, ".", 0x00
zn_10:
    #d "BUNK", 0x00
zx_10:
    #d "A CREW BUNK.  THE BLANKET IS FOLDED NEATLY.", 0x00
zn_11:
    #d "HELM CONSOLE", 0x00


#addr 0x1D00
zx_11:
    #d "THE HELM.  THE LAST LOG ENTRY IS 212 DAYS OLD.", 0x00
zn_12:
    #d "LOCKER", 0x00
zx_12:
    #d "A LOCKER.  THE LOCK IS RUSTED SHUT.", 0x00
zn_13:
    #d "SECURITY TURRET", 0x00
zx_13:
    #d "A SECURITY TURRET.  ITS LIGHT IS DARK, FOR NOW.", 0x00
zn_14:
    #d "POWER CONDUIT", 0x00
zx_14:
    #d "A POWER CONDUIT RUNS UNDER THE DECK HERE.", 0x00
zn_15:
    #d "DECK (NO AIR)", 0x00


#addr 0x1E00
zx_15:
    #d "FROST ON THE DECK.  THE AIR IS GONE.", 0x00
zn_16:
    #d "AIRLOCK", 0x00
zx_16:
    #d "A DOCKING AIRLOCK.  THE SEAL IS HOLDING.", 0x00
zn_17:
    #d "DOCKING TUBE", 0x00
zx_17:
    #d "THE DOCKING TUBE FLEXES UNDER YOUR BOOTS.", 0x00
zn_18:
    #d "THRUSTER", 0x00
zx_18:
    #d "A THRUSTER NOZZLE, BLACK WITH SOOT.", 0x00
zn_19:
    #d "FUEL TANK", 0x00
zx_19:
    #d "A FUEL TANK.  IT SLOSHES WHEN YOU KNOCK.", 0x00


#addr 0x2000
zn_20:
    #d "AIR SCRUBBER", 0x00
zx_20:
    #d "AN AIR SCRUBBER.  THE FILTERS NEED CHANGING.", 0x00
zn_21:
    #d "HULL BREACH", 0x00
zx_21:
    #d "SOMETHING PUNCHED RIGHT THROUGH THE HULL.", 0x00
zn_22:
    #d "YOU", 0x00
zx_22:
    #d "THAT IS YOU, IN A WORK SUIT THAT HAS SEEN BETTER DAYS.", 0x00
za_1:
    #d "OPEN", 0x00
za_2:
    #d "CLOSE", 0x00
za_3:
    #d "INSPECT", 0x00
za_4:
    #d "WALK HERE", 0x00
zd_0:
    #d "0%", 0x00
zw_0:
    #d "WORKS AT 100%", 0x00
zd_1:
    #d "6%", 0x00
zw_1:
    #d "WORKS AT 88%", 0x00
zd_2:
    #d "13%", 0x00


#addr 0x2100
zw_2:
    #d "WORKS AT 75%", 0x00
zd_3:
    #d "19%", 0x00
zw_3:
    #d "WORKS AT 63%", 0x00
zd_4:
    #d "25%", 0x00
zw_4:
    #d "WORKS AT 50%", 0x00
zd_5:
    #d "31%", 0x00
zw_5:
    #d "WORKS AT 38%", 0x00
zd_6:
    #d "38%", 0x00
zw_6:
    #d "WORKS AT 25%", 0x00
zd_7:
    #d "44%", 0x00
zw_7:
    #d "WORKS AT 13%", 0x00
zd_8:
    #d "50%", 0x00
zw_8:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_9:
    #d "56%", 0x00
zw_9:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_10:
    #d "63%", 0x00
zw_10:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_11:
    #d "69%", 0x00
zw_11:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_12:
    #d "75%", 0x00
zw_12:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_13:
    #d "81%", 0x00


#addr 0x2200
zw_13:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_14:
    #d "88%", 0x00
zw_14:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_15:
    #d "94%", 0x00
zw_15:
    #d "BROKEN - NEEDS REPAIR", 0x00
zb_0:
    #d "[----------]", 0x00
zb_1:
    #d "[#---------]", 0x00
zb_2:
    #d "[#---------]", 0x00
zb_3:
    #d "[##--------]", 0x00
zb_4:
    #d "[###-------]", 0x00
zb_5:
    #d "[###-------]", 0x00
zb_6:
    #d "[####------]", 0x00
zb_7:
    #d "[####------]", 0x00
zb_8:
    #d "[#####-----]", 0x00
zb_9:
    #d "[######----]", 0x00
zb_10:
    #d "[######----]", 0x00
zb_11:
    #d "[#######---]", 0x00


#addr 0x2300
zb_12:
    #d "[########--]", 0x00
zb_13:
    #d "[########--]", 0x00
zb_14:
    #d "[#########-]", 0x00
zb_15:
    #d "[#########-]", 0x00
s_welcome:
    #d "DOCKED TO THE KESTREL 9.  ARROWS OR WASD WALK, MOUSE SHOWS AND CLICKS.", 0x00
s_toofar:
    #d "TOO FAR AWAY - WALK NEXT TO IT FIRST.", 0x00
s_inway:
    #d "SOMETHING IS IN THE WAY.", 0x00
s_blocked:
    #d "THE WAY IS BLOCKED.", 0x00

#addr 0x3600
BAR_TAB:
    #d8 zb_0 & 0xFF, zb_1 & 0xFF, zb_2 & 0xFF, zb_3 & 0xFF, zb_4 & 0xFF, zb_5 & 0xFF, zb_6 & 0xFF, zb_7 & 0xFF
    #d8 zb_8 & 0xFF, zb_9 & 0xFF, zb_10 & 0xFF, zb_11 & 0xFF, zb_12 & 0xFF, zb_13 & 0xFF, zb_14 & 0xFF, zb_15 & 0xFF
    #d8 zb_0 >> 8, zb_1 >> 8, zb_2 >> 8, zb_3 >> 8, zb_4 >> 8, zb_5 >> 8, zb_6 >> 8, zb_7 >> 8
    #d8 zb_8 >> 8, zb_9 >> 8, zb_10 >> 8, zb_11 >> 8, zb_12 >> 8, zb_13 >> 8, zb_14 >> 8, zb_15 >> 8


#addr 0x3700
ACT_TAB:
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 4, 3, 0, 0, 3, 0, 0, 0
    #d8 1, 3, 0, 0, 2, 4, 3, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 4, 3, 0, 0, 4, 3, 0, 0
    #d8 4, 3, 0, 0, 4, 3, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0


#addr 0x3800
INFO_TAB:
    #d8 zi_0_0 & 0xFF, 0, 0, 0, zi_1_0 & 0xFF, 0, 0, 0
    #d8 zi_2_0 & 0xFF, zi_2_1 & 0xFF, 0, 0, zi_3_0 & 0xFF, zi_3_1 & 0xFF, zi_3_2 & 0xFF, 0
    #d8 zi_4_0 & 0xFF, zi_4_1 & 0xFF, zi_4_2 & 0xFF, 0, zi_5_0 & 0xFF, zi_5_1 & 0xFF, zi_5_2 & 0xFF, 0
    #d8 zi_6_0 & 0xFF, zi_6_1 & 0xFF, zi_6_2 & 0xFF, zi_6_3 & 0xFF, zi_7_0 & 0xFF, zi_7_1 & 0xFF, zi_7_2 & 0xFF, zi_7_3 & 0xFF
    #d8 zi_8_0 & 0xFF, zi_8_1 & 0xFF, zi_8_2 & 0xFF, zi_8_3 & 0xFF, zi_9_0 & 0xFF, zi_9_1 & 0xFF, zi_9_2 & 0xFF, 0
    #d8 zi_10_0 & 0xFF, zi_10_1 & 0xFF, zi_10_2 & 0xFF, 0, zi_11_0 & 0xFF, zi_11_1 & 0xFF, zi_11_2 & 0xFF, 0
    #d8 zi_12_0 & 0xFF, zi_12_1 & 0xFF, zi_12_2 & 0xFF, 0, zi_13_0 & 0xFF, zi_13_1 & 0xFF, zi_13_2 & 0xFF, 0
    #d8 zi_14_0 & 0xFF, zi_14_1 & 0xFF, zi_14_2 & 0xFF, 0, zi_15_0 & 0xFF, zi_15_1 & 0xFF, zi_15_2 & 0xFF, 0
    #d8 zi_16_0 & 0xFF, zi_16_1 & 0xFF, zi_16_2 & 0xFF, 0, zi_17_0 & 0xFF, zi_17_1 & 0xFF, 0, 0
    #d8 zi_18_0 & 0xFF, zi_18_1 & 0xFF, zi_18_2 & 0xFF, 0, zi_19_0 & 0xFF, zi_19_1 & 0xFF, zi_19_2 & 0xFF, 0
    #d8 zi_20_0 & 0xFF, zi_20_1 & 0xFF, zi_20_2 & 0xFF, 0, zi_21_0 & 0xFF, zi_21_1 & 0xFF, 0, 0
    #d8 zi_pl_0 & 0xFF, zi_pl_1 & 0xFF, zi_pl_2 & 0xFF, zi_pl_3 & 0xFF, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zi_0_0 >> 8, 0, 0, 0, zi_1_0 >> 8, 0, 0, 0
    #d8 zi_2_0 >> 8, zi_2_1 >> 8, 0, 0, zi_3_0 >> 8, zi_3_1 >> 8, zi_3_2 >> 8, 0
    #d8 zi_4_0 >> 8, zi_4_1 >> 8, zi_4_2 >> 8, 0, zi_5_0 >> 8, zi_5_1 >> 8, zi_5_2 >> 8, 0
    #d8 zi_6_0 >> 8, zi_6_1 >> 8, zi_6_2 >> 8, zi_6_3 >> 8, zi_7_0 >> 8, zi_7_1 >> 8, zi_7_2 >> 8, zi_7_3 >> 8
    #d8 zi_8_0 >> 8, zi_8_1 >> 8, zi_8_2 >> 8, zi_8_3 >> 8, zi_9_0 >> 8, zi_9_1 >> 8, zi_9_2 >> 8, 0
    #d8 zi_10_0 >> 8, zi_10_1 >> 8, zi_10_2 >> 8, 0, zi_11_0 >> 8, zi_11_1 >> 8, zi_11_2 >> 8, 0
    #d8 zi_12_0 >> 8, zi_12_1 >> 8, zi_12_2 >> 8, 0, zi_13_0 >> 8, zi_13_1 >> 8, zi_13_2 >> 8, 0
    #d8 zi_14_0 >> 8, zi_14_1 >> 8, zi_14_2 >> 8, 0, zi_15_0 >> 8, zi_15_1 >> 8, zi_15_2 >> 8, 0
    #d8 zi_16_0 >> 8, zi_16_1 >> 8, zi_16_2 >> 8, 0, zi_17_0 >> 8, zi_17_1 >> 8, 0, 0
    #d8 zi_18_0 >> 8, zi_18_1 >> 8, zi_18_2 >> 8, 0, zi_19_0 >> 8, zi_19_1 >> 8, zi_19_2 >> 8, 0
    #d8 zi_20_0 >> 8, zi_20_1 >> 8, zi_20_2 >> 8, 0, zi_21_0 >> 8, zi_21_1 >> 8, 0, 0
    #d8 zi_pl_0 >> 8, zi_pl_1 >> 8, zi_pl_2 >> 8, zi_pl_3 >> 8, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

TAB:
    #d8 0, 0, 3, 2, 2, 3, 2, 2
    #d8 2, 2, 2, 2, 2, 2, 3, 3
    #d8 3, 3, 2, 2, 2, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zn_0 & 0xFF, zn_1 & 0xFF, zn_2 & 0xFF, zn_3 & 0xFF, zn_4 & 0xFF, zn_5 & 0xFF, zn_6 & 0xFF, zn_7 & 0xFF
    #d8 zn_8 & 0xFF, zn_9 & 0xFF, zn_10 & 0xFF, zn_11 & 0xFF, zn_12 & 0xFF, zn_13 & 0xFF, zn_14 & 0xFF, zn_15 & 0xFF
    #d8 zn_16 & 0xFF, zn_17 & 0xFF, zn_18 & 0xFF, zn_19 & 0xFF, zn_20 & 0xFF, zn_21 & 0xFF, zn_22 & 0xFF, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zn_0 >> 8, zn_1 >> 8, zn_2 >> 8, zn_3 >> 8, zn_4 >> 8, zn_5 >> 8, zn_6 >> 8, zn_7 >> 8
    #d8 zn_8 >> 8, zn_9 >> 8, zn_10 >> 8, zn_11 >> 8, zn_12 >> 8, zn_13 >> 8, zn_14 >> 8, zn_15 >> 8
    #d8 zn_16 >> 8, zn_17 >> 8, zn_18 >> 8, zn_19 >> 8, zn_20 >> 8, zn_21 >> 8, zn_22 >> 8, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zx_0 & 0xFF, zx_1 & 0xFF, zx_2 & 0xFF, zx_3 & 0xFF, zx_4 & 0xFF, zx_5 & 0xFF, zx_6 & 0xFF, zx_7 & 0xFF
    #d8 zx_8 & 0xFF, zx_9 & 0xFF, zx_10 & 0xFF, zx_11 & 0xFF, zx_12 & 0xFF, zx_13 & 0xFF, zx_14 & 0xFF, zx_15 & 0xFF
    #d8 zx_16 & 0xFF, zx_17 & 0xFF, zx_18 & 0xFF, zx_19 & 0xFF, zx_20 & 0xFF, zx_21 & 0xFF, zx_22 & 0xFF, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zx_0 >> 8, zx_1 >> 8, zx_2 >> 8, zx_3 >> 8, zx_4 >> 8, zx_5 >> 8, zx_6 >> 8, zx_7 >> 8
    #d8 zx_8 >> 8, zx_9 >> 8, zx_10 >> 8, zx_11 >> 8, zx_12 >> 8, zx_13 >> 8, zx_14 >> 8, zx_15 >> 8
    #d8 zx_16 >> 8, zx_17 >> 8, zx_18 >> 8, zx_19 >> 8, zx_20 >> 8, zx_21 >> 8, zx_22 >> 8, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, za_1 & 0xFF, za_2 & 0xFF, za_3 & 0xFF, za_4 & 0xFF, 0, 0, 0
    #d8 0, za_1 >> 8, za_2 >> 8, za_3 >> 8, za_4 >> 8, 0, 0, 0
    #d8 zd_0 & 0xFF, zd_1 & 0xFF, zd_2 & 0xFF, zd_3 & 0xFF, zd_4 & 0xFF, zd_5 & 0xFF, zd_6 & 0xFF, zd_7 & 0xFF
    #d8 zd_8 & 0xFF, zd_9 & 0xFF, zd_10 & 0xFF, zd_11 & 0xFF, zd_12 & 0xFF, zd_13 & 0xFF, zd_14 & 0xFF, zd_15 & 0xFF
    #d8 zd_0 >> 8, zd_1 >> 8, zd_2 >> 8, zd_3 >> 8, zd_4 >> 8, zd_5 >> 8, zd_6 >> 8, zd_7 >> 8
    #d8 zd_8 >> 8, zd_9 >> 8, zd_10 >> 8, zd_11 >> 8, zd_12 >> 8, zd_13 >> 8, zd_14 >> 8, zd_15 >> 8
    #d8 zw_0 & 0xFF, zw_1 & 0xFF, zw_2 & 0xFF, zw_3 & 0xFF, zw_4 & 0xFF, zw_5 & 0xFF, zw_6 & 0xFF, zw_7 & 0xFF
    #d8 zw_8 & 0xFF, zw_9 & 0xFF, zw_10 & 0xFF, zw_11 & 0xFF, zw_12 & 0xFF, zw_13 & 0xFF, zw_14 & 0xFF, zw_15 & 0xFF
    #d8 zw_0 >> 8, zw_1 >> 8, zw_2 >> 8, zw_3 >> 8, zw_4 >> 8, zw_5 >> 8, zw_6 >> 8, zw_7 >> 8
    #d8 zw_8 >> 8, zw_9 >> 8, zw_10 >> 8, zw_11 >> 8, zw_12 >> 8, zw_13 >> 8, zw_14 >> 8, zw_15 >> 8
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

ART:
; SPACE
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
; STAR
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0xA1, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x13, 0x11, 0x11, 0x11
; FLOOR
    #d8 0x77, 0xB7, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x00
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x00
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0xB7, 0x77, 0x00
    #d8 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x00
; WALL
    #d8 0xBA, 0xBA, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0xBA, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77
    #d8 0xBB, 0xBB, 0xB7, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77
    #d8 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0xBB, 0xBB, 0xB7, 0xBB, 0xBB, 0xBB, 0xBB, 0x77
    #d8 0xBB, 0xBB, 0x7B, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77

; DOOR
    #d8 0xBB, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0xEB, 0x0B, 0xEB, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0xBB
    #d8 0xBB, 0x66, 0x66, 0x6D, 0x66, 0x66, 0xE0, 0x0E, 0xE0, 0x66, 0x66, 0x6D, 0x66, 0x66, 0x66, 0xBB
    #d8 0xBB, 0x66, 0x66, 0xD6, 0x66, 0x66, 0xE0, 0x0E, 0xE0, 0x66, 0x66, 0xD6, 0x66, 0x66, 0x66, 0xBB
    #d8 0xBB, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB0, 0xBE, 0xB0, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xBB
; DOORO
    #d8 0xBB, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0x6B, 0xBB
    #d8 0xBB, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0xBB
    #d8 0xBB, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0xBB
    #d8 0xBB, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xB6, 0xBB
; O2
    #d8 0x77, 0x77, 0x87, 0xA8, 0xA8, 0xA8, 0xA8, 0xA8, 0xA8, 0xA8, 0xA8, 0x88, 0x88, 0x87, 0x77, 0x77
    #d8 0xB7, 0xAB, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x77, 0x77
    #d8 0x7B, 0xBA, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x77, 0x77
    #d8 0x77, 0x77, 0x78, 0x88, 0x88, 0x83, 0x83, 0x83, 0x83, 0x83, 0x83, 0x83, 0x88, 0x78, 0x77, 0x77
; REACT
    #d8 0xBB, 0x7B, 0x7B, 0x97, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0xF9, 0x97, 0x7B, 0x7B, 0x7B, 0x7B, 0xBB
    #d8 0xBB, 0x77, 0xF9, 0xEF, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xAE, 0xEF, 0xF9, 0x77, 0x7E, 0x77, 0xBB
    #d8 0xBB, 0x77, 0x9F, 0xFE, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xFE, 0x9F, 0x77, 0x7E, 0x77, 0xBB
    #d8 0xBB, 0xB7, 0xB7, 0x79, 0x9F, 0x9F, 0x9F, 0x9F, 0x9F, 0x9F, 0x79, 0xB7, 0xB7, 0xB7, 0xB7, 0xBB

; BATT
    #d8 0x77, 0x77, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0x77, 0x77
    #d8 0x77, 0x7B, 0xBB, 0x00, 0xE0, 0xE0, 0x00, 0xE0, 0xE0, 0x00, 0xE0, 0xE0, 0x00, 0xBB, 0x77, 0x77
    #d8 0x77, 0xB7, 0xBB, 0x00, 0x0E, 0x0E, 0x00, 0x0E, 0x0E, 0x00, 0x0E, 0x0E, 0x00, 0xBB, 0x77, 0x77
    #d8 0x77, 0x77, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x77, 0x77
; CRATE
    #d8 0x66, 0xD6, 0x66, 0x66, 0x66, 0x66, 0xD6, 0x66, 0xDD, 0x66, 0xD6, 0x66, 0x66, 0x66, 0xD6, 0x66
    #d8 0x66, 0x66, 0x6D, 0xD6, 0xD6, 0x6D, 0x66, 0x66, 0xDD, 0x66, 0x66, 0x6D, 0xD6, 0x6D, 0x66, 0x66
    #d8 0x66, 0x66, 0xD6, 0x6D, 0x6D, 0xD6, 0x66, 0x66, 0xDD, 0x66, 0x66, 0xD6, 0x6D, 0xD6, 0x66, 0x66
    #d8 0x66, 0x6D, 0x66, 0x66, 0x66, 0x66, 0x6D, 0x66, 0xDD, 0x66, 0x6D, 0x66, 0x66, 0x66, 0x6D, 0x66
; BUNK
    #d8 0x77, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0x77, 0x77
    #d8 0x77, 0xBB, 0xAA, 0xAA, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0xBB, 0x77, 0x77
    #d8 0x77, 0xBB, 0xAA, 0xAA, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0xBB, 0x77, 0x77
    #d8 0x77, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x77, 0x77
; HELM
    #d8 0x77, 0xBB, 0x3B, 0x3B, 0x3B, 0x3B, 0x3B, 0xBB, 0xB7, 0xB7, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77
    #d8 0x77, 0xBB, 0x33, 0x88, 0x38, 0x88, 0x33, 0xBB, 0xE4, 0xBB, 0x77, 0xB7, 0xBB, 0x2B, 0x2B, 0x77
    #d8 0x77, 0xBB, 0x33, 0x88, 0x83, 0x88, 0x33, 0xBB, 0xF9, 0xBB, 0x77, 0x7B, 0xBB, 0xB2, 0xB2, 0x77
    #d8 0x77, 0xBB, 0xB3, 0xB3, 0xB3, 0xB3, 0xB3, 0xBB, 0x7B, 0x7B, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77

; LOCKER
    #d8 0xBB, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0xBB, 0x77
    #d8 0xBB, 0x77, 0xBB, 0x7B, 0xBB, 0x77, 0x77, 0xE7, 0x77, 0x77, 0xBB, 0x7B, 0xBB, 0x77, 0xBB, 0x77
    #d8 0xBB, 0x77, 0xBB, 0xB7, 0xBB, 0x77, 0x77, 0x77, 0x77, 0x77, 0xBB, 0xB7, 0xBB, 0x77, 0xBB, 0x77
    #d8 0xBB, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xBB, 0x77
; TURRET
    #d8 0xBB, 0xBB, 0x7B, 0x7B, 0x47, 0x47, 0x47, 0x47, 0x47, 0x47, 0x7B, 0x7B, 0xBB, 0xBB, 0xBB, 0xBB
    #d8 0xBB, 0x77, 0x77, 0x44, 0x44, 0xD4, 0xAD, 0xAD, 0xD4, 0x44, 0x44, 0x77, 0x4B, 0x4B, 0x4B, 0x7B
    #d8 0xBB, 0x77, 0x77, 0x44, 0x44, 0x4D, 0xDA, 0xDA, 0x4D, 0x44, 0x44, 0x77, 0xB4, 0xB4, 0xB4, 0xB7
    #d8 0xBB, 0xBB, 0xB7, 0xB7, 0x74, 0x74, 0x74, 0x74, 0x74, 0x74, 0xB7, 0xB7, 0xBB, 0xBB, 0xBB, 0xBB
; PIPE
    #d8 0x77, 0xB7, 0x77, 0x77, 0x77, 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x00
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x00
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0x77, 0x77, 0xB7, 0x77, 0x00
    #d8 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0xEE, 0xE6, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x00
; VENT
    #d8 0x00, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x77
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x77
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70, 0x00, 0x77
    #d8 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x70, 0x00, 0x70, 0x77

; LOCK
    #d8 0xBB, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0xBB
    #d8 0xBB, 0x88, 0xBB, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0xBB, 0x88, 0xBB
    #d8 0xBB, 0x88, 0xBB, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xBB, 0x88, 0xBB
    #d8 0xBB, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0xBB
; TUBE
    #d8 0xBB, 0x7B, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x7B, 0xBB
    #d8 0xBB, 0x7B, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x7B, 0xBB
    #d8 0xBB, 0x7B, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x7B, 0xBB
    #d8 0xBB, 0x7B, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x7B, 0xBB
; THRUST
    #d8 0x11, 0xB1, 0xB1, 0xB1, 0xB1, 0xB1, 0x11, 0x11, 0xB1, 0xB1, 0xD1, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0xBB, 0x7B, 0x77, 0x77, 0x77, 0x7B, 0xBB, 0x7B, 0x7B, 0x77, 0xDD, 0xED, 0xED, 0xD1, 0x11, 0x11
    #d8 0xBB, 0xB7, 0x77, 0x77, 0x77, 0xB7, 0xBB, 0xB7, 0xB7, 0x77, 0xDD, 0xDE, 0xDE, 0x1D, 0x1D, 0x11
    #d8 0x11, 0x1B, 0x1B, 0x1B, 0x1B, 0x1B, 0x11, 0x11, 0x1B, 0x1B, 0x1D, 0x11, 0x11, 0x11, 0x11, 0x11
; FUEL
    #d8 0x77, 0x67, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0x67, 0x77, 0x77
    #d8 0x66, 0xDD, 0xDD, 0x66, 0xDD, 0xDD, 0xDD, 0x66, 0xDD, 0xDD, 0xDD, 0x66, 0xDD, 0xDD, 0x66, 0x77
    #d8 0x66, 0xDD, 0xDD, 0x66, 0xDD, 0xDD, 0xDD, 0x66, 0xDD, 0xDD, 0xDD, 0x66, 0xDD, 0xDD, 0x66, 0x77
    #d8 0x77, 0x76, 0x6D, 0x6D, 0x6D, 0x6D, 0x6D, 0x6D, 0x6D, 0x6D, 0x6D, 0x6D, 0x6D, 0x76, 0x77, 0x77

; SCRUB
    #d8 0x77, 0xBB, 0x8B, 0x9B, 0x8B, 0x9B, 0x8B, 0x9B, 0x8B, 0x9B, 0x8B, 0x9B, 0xBB, 0xB7, 0xB7, 0x77
    #d8 0x77, 0xBB, 0x89, 0x98, 0x89, 0x98, 0x89, 0x98, 0x89, 0x98, 0x89, 0x98, 0xBB, 0x77, 0x77, 0x77
    #d8 0x77, 0xBB, 0x89, 0x98, 0x89, 0x98, 0x89, 0x98, 0x89, 0x98, 0x89, 0x98, 0xBB, 0x77, 0x77, 0x77
    #d8 0x77, 0xBB, 0xB9, 0xB8, 0xB9, 0xB8, 0xB9, 0xB8, 0xB9, 0xB8, 0xB9, 0xB8, 0xBB, 0x7B, 0x7B, 0x77
; BREACH
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0xA1, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x1A, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1A, 0x11, 0x11
; PLAYER
    #d8 0x77, 0x77, 0xA7, 0xA7, 0xA7, 0x77, 0xB7, 0xAB, 0xAB, 0xAB, 0xB7, 0x77, 0xA7, 0xA7, 0xB7, 0x77
    #d8 0x77, 0xAA, 0x8A, 0x88, 0x8A, 0xAA, 0xAA, 0xAA, 0xEA, 0xAA, 0xAA, 0xAA, 0x7A, 0x7A, 0x7B, 0x77
    #d8 0x77, 0xAA, 0xA8, 0x88, 0xA8, 0xAA, 0xAA, 0xAA, 0xAE, 0xAA, 0xAA, 0xAA, 0xA7, 0xA7, 0xB7, 0x77
    #d8 0x77, 0x77, 0x7A, 0x7A, 0x7A, 0x77, 0x7B, 0xBA, 0xBA, 0xBA, 0x7B, 0x77, 0x7A, 0x7A, 0x7B, 0x77

