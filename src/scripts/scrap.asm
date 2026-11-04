; ============================================================
; made by asm_expand.py from scrap.masm: change that file, then run
;     python3 asm_expand.py scrap.masm
; ============================================================

; ============================================================
; scrap.masm - SCRAP.PLC: SCRAPWRIGHT, phase 3 (salvage, the tug, air)
; ============================================================
;
; A library program the DOS runs from the card.  SCRAPWRIGHT is a
; top-down salvage game (docs/software/SCRAP.md): you walk a salvage tug's
; docked wreck, look at what is in it with the mouse, and (in later
; phases) cut it out, haul it home and build it into your own ship.
; Phase 2 is the walking: the tug and the KESTREL 9 on one 96 x 64 map,
; doors, the camera, the item panel and the mouse.  Phase 3 adds salvage
; (CUT FREE, PICK UP, PUT DOWN, three carry slots), the tug (its worth,
; its air from an O2 tank and a scrubber on board) and air: rooms with a
; pressure each, shared through open doors, lost through a breach; the
; suit's O2 and battery, staged warnings, suffocating (Enter: again).
; Parts count for the tug once INSTALLed on its cells (UNINSTALL takes
; one out); doors close behind the player unless held open (HOLD OPEN).
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
; More code and strings go in the even pages from xC000 (the overlay
; region): SCRAP.OVL holds them after the map, and ovl_load reads both.
;
;     python3 gen_scrap.py                            scrap_types.asm, scrap_data.masm, scrap_map.bin
;     python3 asm_expand.py scrap.masm                scrap.asm
;     python3 gen_plc.py scrap.asm -o ../../sdcard/SCRAP.PLC --overlay 0xC000,2 --overlay-head scrap_map.bin
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
wk_l    = 0x4D              ; the job: work left (16 bits), done at wk_r a frame
wk_h    = 0x4E
wk_r    = 0x4F
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
wk_m    = 0x5F              ; the job's skills (bit k skill k; SK_SUIT in the suit)
s_t     = 0x60              ; the panel's subject: type
s_f     = 0x61              ;   damage step 0-15
n_act   = 0x62              ;   actions 0-8 (two columns of 4)
act0    = 0x36F0            ;   the action codes, x36F0-x36F7 (not zero page)
JB_B    = 0x36F8            ; the job's bar: its frames at full speed (a 16th of the work),
JB_N    = 0x36F9            ;   the 16ths done,
JB_TL   = 0x36FA            ;   the work left at the next 16th
JB_TH   = 0x36FB
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
cl_t    = 0x73              ; carried: left hand, right hand, back (types, 0 empty)
cr_t    = 0x74
cb_t    = 0x75
cl_d    = 0x76              ;   their damage steps (cl_t + 3)
cr_d    = 0x77
cb_d    = 0x78
o2      = 0x79              ; suit O2, litres (0-90)
batt    = 0x7A              ; suit battery, percent
air_t   = 0x7B              ; frames to the next air tick (every 8)
sec_t   = 0x7C              ; frames into the second
cut_t   = 0x7D              ; 1 while a job runs (job_start, work_tick)
cut_x   = 0x7E              ;   the cell being cut
cut_y   = 0x7F
stage   = 0x80              ; the air warning: 0 none, 1 caution, 2 warning,
                            ; 3 critical, 4 collapse, 5 dead
col_t   = 0x81              ; seconds collapsed (no suit O2)
dead    = 0x82              ; 1: suffocated, Enter starts again
c_r     = 0x83              ; map_get: the cell's room, 0 none
c_b     = 0x84              ;   80: bolted (a part not cut free yet)
sup     = 0x85              ; 1: the tug has air (a working O2 tank and scrubber)
s_r     = 0x86              ; the panel's subject: its room
s_b     = 0x87              ;   bolted
v0 = 0x88                   ; scratch, the air and the tug
v1 = 0x89
v2 = 0x8A
v3 = 0x8B
v4 = 0x8C
v5 = 0x8D
v6 = 0x8E
v7 = 0x8F
n_o2    = 0x90              ; the tug's working parts (tug_scan); the sound
n_scr   = 0x91              ; driver's bytes, not used here
n_bat   = 0x92
n_fuel  = 0x93
val_l   = 0x94              ; the tug's worth, in $10
val_h   = 0x95
num_l   = 0x96              ; put_dec: the number
num_h   = 0x97
num_z   = 0x98              ;   1: a digit was printed
cut_m   = 0x99              ; the job: 0 a cut, 1 installing, 2 uninstalling, 3 repairing
n_door  = 0x9A              ; the links in DOOR_PG (rooms_build)
n_room  = 0x9B              ; the rooms, 1 to n_room - 1
rb_go   = 0x9C              ; 1: the rooms are worked out again (cut_done)
stk_l   = 0x9D              ; rooms_build: the fill stack's top (x4700 up)
stk_h   = 0x9E
suit_on = 0x9F              ; 1: the player wears the suit
rb_x    = w0                ; rooms_build (nothing it calls uses the w's):
rb_y    = w1                ;   the cell scanned
rb_n    = w2                ;   the room being filled
rb_cx   = w3                ;   the cell taken off the stack
rb_cy   = w4
rb_k    = w5                ;   its neighbour 0-3
rb_t    = w6                ;   scratch (rl_side)

ROOM_P  = 0x4000            ; + room: its pressure, 0-100 (start: RM_P0)
ROOM_C  = 0x4040            ; + room: 1 while it is cold (pressure under COLD_P)
; rooms_build's work space (x4080-x4CFF; the file system's from x4D00)
RB_DY   = 0x4080            ; + i: the links' y (to check), the x at RB_DX
RB_S0   = 0x4100            ; + room: the old pressures of its cells, summed (3 bytes)
RB_S1   = 0x4140
RB_S2   = 0x4180
RB_CL   = 0x41C0            ; + room: its cells (2 bytes)
RB_CH   = 0x4200
RB_LK   = 0x4240            ; + room: 1 it leaks
RB_TG   = 0x4280            ; + room: 1 a room of the tug
RB_DX   = 0x42C0
RB_VIS  = 0x43              ; x4300-x46FF: a bit a cell, filled (16 bytes a row)
RB_STK  = 0x47              ; x4700-x4CFF: the fill stack, x and y a cell
COLD_P  = 40                ; a room under this draws its deck frosted
BREATHE_P = 60              ; a room under this: the suit uses its own O2
SUIT_O2 = 90
CUT_FRAMES = 90             ; 1.5 seconds to cut a part free
CUT_BATT = 5                ; battery percent a cut uses
INST_FRAMES = 60            ; 1 second to install or uninstall a part
HEAVY_FRAMES = 4            ; walking: frames more a step for each part carried
COLLAPSE_S = 10             ; seconds without O2 before you die
TINT_WARN = 0x10            ; the message row with a warning: red

; MAP07 / MAPFF - the map register (x5000): the library's map, all RAM

; CELLADDR - dc_cx, dc_cy: dc_sp = the cell's first column's page,
; dc_base = its first line pair's offset (16 line pairs a cell row, the
; 2x layout: pair p at 2p + 32, or 2p - 223 from pair 112)

; VISADDR - g_x, g_y: u2:u3 = the address of its bit in rooms_build's fill
; map (RB_VIS + y >> 4 : 16 (y & 15) + x >> 3), u4 = the bit

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
    ld   LINK_LO, x             ; CALL game_init
    ld   scw_r4, [x]
    ld   LINK_HI, x
    ld   scw_r4 >> 8, [x]
    ld   game_init >> 8, y
    jmp  game_init
scw_r4:
    ld   LINK_LO, x             ; CALL camera_fit
    ld   scw_r5, [x]
    ld   LINK_HI, x
    ld   scw_r5 >> 8, [x]
    ld   camera_fit >> 8, y
    jmp  camera_fit
scw_r5:
    ld   LINK_LO, x             ; CALL screen_init
    ld   scw_r6, [x]
    ld   LINK_HI, x
    ld   scw_r6 >> 8, [x]
    ld   screen_init >> 8, y
    jmp  screen_init
scw_r6:
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r7, [x]
    ld   LINK_HI, x
    ld   scw_r7 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r7:
    ld   s_welcome & 0xFF, ac
    ld   ac, [R0]
    ld   s_welcome >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r8, [x]
    ld   LINK_HI, x
    ld   scw_r8 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r8:
    ld   LINK_LO, x             ; CALL draw_panel
    ld   scw_r9, [x]
    ld   LINK_HI, x
    ld   scw_r9 >> 8, [x]
    ld   draw_panel >> 8, y
    jmp  draw_panel
scw_r9:
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
    ld   ac, [u0]
    ld   [a_pg], y
    ld   [a_ix], x
    ld   [y,x], ac
    and  0x60, ac
    or   [u0], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; map_setd - AC = the new damage step of the cell map_get last found.  A
; leaf.

#addr 0x0200
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames_io
    ld   scw_r10, [x]
    ld   LINK_HI, x
    ld   scw_r10 >> 8, [x]
    ld   l_wait_frames_io >> 8, y
    jmp  l_wait_frames_io
scw_r10:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   scw_r11, [x]
    ld   LINK_HI, x
    ld   scw_r11 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
scw_r11:
    ld   LINK_LO, x             ; CALL l_menu_poll
    ld   scw_r12, [x]
    ld   LINK_HI, x
    ld   scw_r12 >> 8, [x]
    ld   l_menu_poll >> 8, y
    jmp  l_menu_poll
scw_r12:
    ld   [dead], ac
    bne  lp_dead
    ld   LINK_LO, x             ; CALL input_mouse
    ld   scw_r13, [x]
    ld   LINK_HI, x
    ld   scw_r13 >> 8, [x]
    ld   input_mouse >> 8, y
    jmp  input_mouse
scw_r13:
    ld   LINK_LO, x             ; CALL input_keys
    ld   scw_r14, [x]
    ld   LINK_HI, x
    ld   scw_r14 >> 8, [x]
    ld   input_keys >> 8, y
    jmp  input_keys
scw_r14:
    ld   LINK_LO, x             ; CALL input_walk
    ld   scw_r15, [x]
    ld   LINK_HI, x
    ld   scw_r15 >> 8, [x]
    ld   input_walk >> 8, y
    jmp  input_walk
scw_r15:
    ld   LINK_LO, x             ; CALL game_tick
    ld   scw_r16, [x]
    ld   LINK_HI, x
    ld   scw_r16 >> 8, [x]
    ld   game_tick >> 8, y
    jmp  game_tick
scw_r16:
    ld   LINK_LO, x             ; CALL update_panel
    ld   scw_r17, [x]
    ld   LINK_HI, x
    ld   scw_r17 >> 8, [x]
    ld   update_panel >> 8, y
    jmp  update_panel
scw_r17:
    ld   loop >> 8, y
    jmp  loop
lp_dead:
    ld   LINK_LO, x             ; dead: Enter starts again
    ld   scw_r18, [x]
    ld   LINK_HI, x
    ld   scw_r18 >> 8, [x]
    ld   update_panel >> 8, y
    jmp  update_panel
scw_r18:
    ld   LINK_LO, x             ; CALL l_kbd_getc
    ld   scw_r19, [x]
    ld   LINK_HI, x
    ld   scw_r19 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
scw_r19:
    xor  0x0A, ac
    bne  lp_d
    ld   main >> 8, y
    jmp  main
lp_d:
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
    ld   scw_r20, [x]
    ld   LINK_HI, x
    ld   scw_r20 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
scw_r20:
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
    ld   scw_r21, [x]
    ld   LINK_HI, x
    ld   scw_r21 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
scw_r21:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

map_setd:
    ld   ac, [u0]
    ld   [a_pg], ac
    add  2, ac
    ld   ac, y
    ld   [a_ix], x
    ld   [y,x], ac
    and  0xF0, ac
    or   [u0], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; drawing the view
; ============================================================

; draw_cell - the art of type dc_t at screen cell dc_cx, dc_cy.  A leaf.

#addr 0x0300
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
    ld   scw_r22, [x]
    ld   LINK_HI, x
    ld   scw_r22 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
scw_r22:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r23, [x]
    ld   LINK_HI, x
    ld   scw_r23 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
scw_r23:
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
    ld   scw_r24, [x]
    ld   LINK_HI, x
    ld   scw_r24 >> 8, [x]
    ld   pad_read >> 8, y
    jmp  pad_read
scw_r24:
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
    ld   scw_r25, [x]
    ld   LINK_HI, x
    ld   scw_r25 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
scw_r25:
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
    ld   scw_r26, [x]
    ld   LINK_HI, x
    ld   scw_r26 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
scw_r26:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r27, [x]
    ld   LINK_HI, x
    ld   scw_r27 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
scw_r27:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r28, [x]
    ld   LINK_HI, x
    ld   scw_r28 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
scw_r28:
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
    ld   scw_r29, [x]
    ld   LINK_HI, x
    ld   scw_r29 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
scw_r29:
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
    ld   scw_r30, [x]
    ld   LINK_HI, x
    ld   scw_r30 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
scw_r30:
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
    ld   scw_r31, [x]
    ld   LINK_HI, x
    ld   scw_r31 >> 8, [x]
    ld   vid_mode >> 8, y
    jmp  vid_mode
scw_r31:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ------------------------------------------------------------
; ovl_load - SCRAP.OVL (the map) into the even pages from MAP_PAGE: a
; sector holds two of them (tracker.masm's ovl_load)
; ------------------------------------------------------------
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
    ld   scw_r32, [x]
    ld   LINK_HI, x
    ld   scw_r32 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
scw_r32:
    bne  ov_e
    ld   MAP_PAGE, ac
    ld   ac, [u5]
ov_s:
    ld   FBUF & 0xFF, ac
    ld   ac, [R4]
    ld   FBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_read
    ld   scw_r33, [x]
    ld   LINK_HI, x
    ld   scw_r33 >> 8, [x]
    ld   l_fs_read >> 8, y
    jmp  l_fs_read
scw_r33:
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
    ld   scw_r34, [x]
    ld   LINK_HI, x
    ld   scw_r34 >> 8, [x]
    ld   l_vid_mode >> 8, y
    jmp  l_vid_mode
scw_r34:
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
    ld   [y,x], ac              ; the flag byte: room bits 3:0, damage
    ld   ac, [u0]
    and  0x0F, ac
    ld   ac, [c_f]
    ld   [u0], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [c_r]
    ld   [a_pg], y
    ld   [y,x], ac              ; the type byte: bolted, room bits 5:4, type
    ld   ac, [u0]
    and  0x80, ac
    ld   ac, [c_b]
    ld   [u0], ac
    and  0x60, ac
    shr  ac
    or   [c_r], ac
    ld   ac, [c_r]
    ld   [u0], ac
    and  0x1F, ac
    ld   ac, [c_t]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; map_put - AC = the new type of the cell map_get last found (its room
; kept, not bolted).  A leaf.
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
draw_cell_at:                   ; (or the art at dc_ap:dc_ai)
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
BIT_TAB:
    #d8 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80

; inst_action - INSTALL or UNINSTALL (w3) the part the panel shows, from
; next to it: INST_FRAMES of work (cut_done).  The rest of do_action.
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
    ld   scw_r35, [x]
    ld   LINK_HI, x
    ld   scw_r35 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r35:
    ld   ac, [dc_t]
    xor  T_FLOOR, ac
    bne  vc_p
    ld   ROOM_C >> 8, y         ; a deck in a cold room: frosted
    ld   [c_r], ac
    add  ROOM_C & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    beq  vc_p
    ld   T_VENT, ac
    ld   ac, [dc_t]
vc_p:
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
    ld   scw_r36, [x]
    ld   LINK_HI, x
    ld   scw_r36 >> 8, [x]
    ld   draw_cell >> 8, y
    jmp  draw_cell
scw_r36:
    ld   LINK_LO, x             ; CALL cell_extra
    ld   scw_r37, [x]
    ld   LINK_HI, x
    ld   scw_r37 >> 8, [x]
    ld   cell_extra >> 8, y
    jmp  cell_extra
scw_r37:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_view - every cell of the view, then the frame
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

#addr 0x0800
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
    ld   scw_r38, [x]
    ld   LINK_HI, x
    ld   scw_r38 >> 8, [x]
    ld   view_cell >> 8, y
    jmp  view_cell
scw_r38:
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
    ld   scw_r39, [x]
    ld   LINK_HI, x
    ld   scw_r39 >> 8, [x]
    ld   frame_set >> 8, y
    jmp  frame_set
scw_r39:
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
    ld   scw_r40, [x]
    ld   LINK_HI, x
    ld   scw_r40 >> 8, [x]
    ld   view_cell >> 8, y
    jmp  view_cell
scw_r40:
    ld   [fr_on], ac
    beq  rc_e
    ld   [g_x], ac
    xor  [fr_x], ac
    bne  rc_e
    ld   [g_y], ac
    xor  [fr_y], ac
    bne  rc_e
    ld   LINK_LO, x             ; CALL draw_frame
    ld   scw_r41, [x]
    ld   LINK_HI, x
    ld   scw_r41 >> 8, [x]
    ld   draw_frame >> 8, y
    jmp  draw_frame
scw_r41:
rc_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; frame_set - the frame off its old cell, onto h_x, h_y (when h_on)
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
    ld   scw_r42, [x]
    ld   LINK_HI, x
    ld   scw_r42 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r42:
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
    ld   scw_r43, [x]
    ld   LINK_HI, x
    ld   scw_r43 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r43:
fs_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; camera_fit - the view around the player (start).  A leaf.
cut_pay:
    ld   [batt], ac
    sub  CUT_BATT, ac
    ld   ac, [batt]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; struct_done - a wall taken out is a wall panel on the deck, a door a
; door kit; a deck plate goes to a free carry slot and leaves open space.
; The rest of cut_done.

#addr 0x0900
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
    ld   scw_r44, [x]
    ld   LINK_HI, x
    ld   scw_r44 >> 8, [x]
    ld   l_mouse_poll >> 8, y
    jmp  l_mouse_poll
scw_r44:
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
    ld   scw_r45, [x]
    ld   LINK_HI, x
    ld   scw_r45 >> 8, [x]
    ld   l_mouse_move >> 8, y
    jmp  l_mouse_move
scw_r45:
    ld   [R0], ac
    ld   ac, [m_xl]
    ld   [R1], ac
    ld   ac, [m_xh]
    ld   [R2], ac
    ld   ac, [m_yl]
    ld   [R3], ac
    ld   ac, [m_yh]
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r46, [x]
    ld   LINK_HI, x
    ld   scw_r46 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r46:
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
    ld   scw_r47, [x]
    ld   LINK_HI, x
    ld   scw_r47 >> 8, [x]
    ld   click_left >> 8, y
    jmp  click_left
scw_r47:
im_r:
    ld   [mb_new], ac
    and  2, ac
    beq  im_e
    ld   LINK_LO, x             ; CALL click_right
    ld   scw_r48, [x]
    ld   LINK_HI, x
    ld   scw_r48 >> 8, [x]
    ld   click_right >> 8, y
    jmp  click_right
scw_r48:
im_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; in_view - AC = 1 when the pointer is over the view (y < 384).  A leaf.

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
    ld   scw_r49, [x]
    ld   LINK_HI, x
    ld   scw_r49 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r49:
    bne  hu_v
    ld   LINK_LO, x             ; CALL hover_panel
    ld   scw_r50, [x]
    ld   LINK_HI, x
    ld   scw_r50 >> 8, [x]
    ld   hover_panel >> 8, y
    jmp  hover_panel
scw_r50:
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
    ld   scw_r51, [x]
    ld   LINK_HI, x
    ld   scw_r51 >> 8, [x]
    ld   frame_set >> 8, y
    jmp  frame_set
scw_r51:
    ld   [lock], ac
    bne  hu_e
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r52, [x]
    ld   LINK_HI, x
    ld   scw_r52 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r52:
hu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; hover_panel - m_sel = the action under the pointer (FF none): rows
; 25-28, column 44 up (actions 0-3), from column 62 (4-7).  A leaf.
hover_panel:
    ld   0xFF, ac
    ld   ac, [u3]
    ld   [m_yh], ac             ; y >= 256
    beq  hp_s
    ld   [m_xl], ac             ; the text column, x / 8
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u4]
    ld   [m_xh], ac
    shl
    shl
    shl
    shl
    shl
    or   [u4], ac
    sub  44, ac
    bcs  hp_s
    sub  18, ac
    bcs  hp_a
    ld   4, ac
    bra  hp_b
hp_a:
    clr  ac
hp_b:
    ld   ac, [u5]
    ld   [m_yl], ac             ; text row (y - 384) / 16, rows 25-28
    sub  0x80, ac
    bcs  hp_s
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    dec
    ld   ac, [u4]
    sub  4, ac
    bcc  hp_s
    ld   [u4], ac
    add  [u5], ac
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
act_done:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r157, [x]
    ld   LINK_HI, x
    ld   scw_r157 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r157:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; put_action - PUT DOWN: the part from carry slot w3 - A_PUTL onto the
; deck the panel shows.  The rest of do_action.
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
    ld   scw_r53, [x]
    ld   LINK_HI, x
    ld   scw_r53 >> 8, [x]
    ld   do_action >> 8, y
    jmp  do_action
scw_r53:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cl_v:
    ld   LINK_LO, x             ; CALL in_view
    ld   scw_r54, [x]
    ld   LINK_HI, x
    ld   scw_r54 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r54:
    beq  cl_e
    ld   1, ac
    ld   ac, [lock]
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r55, [x]
    ld   LINK_HI, x
    ld   scw_r55 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r55:
cl_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; click_right - the panel follows the pointer again
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
    ld   scw_r56, [x]
    ld   LINK_HI, x
    ld   scw_r56 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r56:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; keys and walking
; ============================================================

; input_keys - 1-8: the panel's actions
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
    ld   scw_r57, [x]
    ld   LINK_HI, x
    ld   scw_r57 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
scw_r57:
    beq  ik_e
    ld   ac, [key]
    sub  0x31, ac
    ld   ac, [u1]
    sub  8, ac
    bcc  ik_e
    ld   [u1], ac
    ld   LINK_LO, x             ; CALL do_action
    ld   scw_r58, [x]
    ld   LINK_HI, x
    ld   scw_r58 >> 8, [x]
    ld   do_action >> 8, y
    jmp  do_action
scw_r58:
ik_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; input_walk - the held directions (arrows, WASD, pad 1) or WALK HERE:
; a step every WALK_FRAMES frames
add_act:
    ld   ac, [u1]
    ld   [n_act], ac
    xor  8, ac
    beq  aa_e
    ld   act0 >> 8, y
    ld   [n_act], ac
    add  act0 & 0xFF, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   [n_act], ac
    inc
    ld   ac, [n_act]
aa_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; draw_dmg - "DAMAGE [###-------] 19%" at row 24, column 54
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
    ld   scw_r132, [x]
    ld   LINK_HI, x
    ld   scw_r132 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r132:
    bra  pd_l
pd_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_msg - row 29: the message (tinted) or nothing
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
    ld   scw_r59, [x]
    ld   LINK_HI, x
    ld   scw_r59 >> 8, [x]
    ld   l_pad_read >> 8, y
    jmp  l_pad_read
scw_r59:
    ld   LINK_LO, x             ; CALL read_dirs
    ld   scw_r60, [x]
    ld   LINK_HI, x
    ld   scw_r60 >> 8, [x]
    ld   read_dirs >> 8, y
    jmp  read_dirs
scw_r60:
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
    ld   LINK_LO, x             ; CALL walk_delay
    ld   scw_r61, [x]
    ld   LINK_HI, x
    ld   scw_r61 >> 8, [x]
    ld   walk_delay >> 8, y
    jmp  walk_delay
scw_r61:
    ld   ac, [walk_t]
    ld   [dirs], ac
    bne  iw_man
    ld   LINK_LO, x             ; CALL auto_step
    ld   scw_r62, [x]
    ld   LINK_HI, x
    ld   scw_r62 >> 8, [x]
    ld   auto_step >> 8, y
    jmp  auto_step
scw_r62:
    ld   sc_leave >> 8, y
    jmp  sc_leave
iw_man:
    ld   LINK_LO, x             ; CALL man_step
    ld   scw_r63, [x]
    ld   LINK_HI, x
    ld   scw_r63 >> 8, [x]
    ld   man_step >> 8, y
    jmp  man_step
scw_r63:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; read_dirs - dirs from the pad (R0 after pad_read, 1 = down) and the keys
; (KBD_NOW, 0 = down).  A leaf.
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

#addr 0x0D00
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
    ld   scw_r64, [x]
    ld   LINK_HI, x
    ld   scw_r64 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r64:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; auto_step - WALK HERE: a step toward wk_x, wk_y (across first, then
; down or up); stops there, or when both ways are blocked
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
    ld   scw_r65, [x]
    ld   LINK_HI, x
    ld   scw_r65 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r65:
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
    ld   scw_r66, [x]
    ld   LINK_HI, x
    ld   scw_r66 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r66:
    bne  as_e
as_blk:
    ld   s_blocked & 0xFF, ac
    ld   ac, [R0]
    ld   s_blocked >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r67, [x]
    ld   LINK_HI, x
    ld   scw_r67 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r67:
as_done:
    clr  ac
    ld   ac, [wk_on]
as_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; try_move - a step to n_x, n_y: AC = 0 blocked, 1 moved, 2 a closed
; door there opened (the step is the next one)
rb_leak:
    ld   RB_LK >> 8, y
    ld   [rb_n], ac
    add  RB_LK & 0xFF, x
    ld   1, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_nb - g_x, g_y = neighbour rb_k of rb_cx, rb_cy (0 right, 1 left, 2
; down, 3 up); AC = 0 when it is off the map.  A leaf.

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
    ld   scw_r68, [x]
    ld   LINK_HI, x
    ld   scw_r68 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r68:
    xor  T_DOOR, ac
    bne  tm_w
    ld   T_DOORO, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r69, [x]
    ld   LINK_HI, x
    ld   scw_r69 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r69:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r70, [x]
    ld   LINK_HI, x
    ld   scw_r70 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r70:
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
    ld   scw_r71, [x]
    ld   LINK_HI, x
    ld   scw_r71 >> 8, [x]
    ld   move_player >> 8, y
    jmp  move_player
scw_r71:
    ld   1, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
tm_no:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; move_player - the player to n_x, n_y: both cells drawn, the camera, the
; hover and the panel; an open door the player leaves closes unless it is
; held open
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
    ld   scw_r89, [x]
    ld   LINK_HI, x
    ld   scw_r89 >> 8, [x]
    ld   draw_panel >> 8, y
    jmp  draw_panel
scw_r89:
    ld   sc_leave >> 8, y
    jmp  sc_leave
up_2:
    ld   [dirty], ac
    and  2, ac
    beq  up_3
    clr  ac
    ld   ac, [dirty]
    ld   LINK_LO, x             ; CALL draw_msg
    ld   scw_r90, [x]
    ld   LINK_HI, x
    ld   scw_r90 >> 8, [x]
    ld   draw_msg >> 8, y
    jmp  draw_msg
scw_r90:
up_3:
    ld   [m_sel], ac
    xor  [o_sel], ac
    beq  up_e
    ld   LINK_LO, x             ; CALL draw_menu
    ld   scw_r91, [x]
    ld   LINK_HI, x
    ld   scw_r91 >> 8, [x]
    ld   draw_menu >> 8, y
    jmp  draw_menu
scw_r91:
up_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_panel - the whole panel
WARN_TAB:
    #d8 s_w1 & 0xFF, s_w2 & 0xFF, s_w3 & 0xFF, s_w4 & 0xFF, s_w5 & 0xFF
    #d8 s_w1 >> 8, s_w2 >> 8, s_w3 >> 8, s_w4 >> 8, s_w5 >> 8
PD_TAB:
    #d8 0x10, 0xE8, 0x64, 0x0A, 0x01
    #d8 0x27, 0x03, 0x00, 0x00, 0x00

; put_dec8 - AC in decimal

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
    ld   [cut_t], ac
    beq  mp_c
    clr  ac
    ld   ac, [cut_t]
    ld   s_cutstop & 0xFF, ac
    ld   ac, [R0]
    ld   s_cutstop >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r72, [x]
    ld   LINK_HI, x
    ld   scw_r72 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r72:
mp_c:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; an open door left behind closes (not held)
    ld   scw_r73, [x]
    ld   LINK_HI, x
    ld   scw_r73 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r73:
    xor  T_DOORO, ac
    bne  mp_m
    ld   [c_b], ac
    bne  mp_m
    ld   T_DOOR, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r74, [x]
    ld   LINK_HI, x
    ld   scw_r74 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r74:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
mp_m:
    ld   [n_x], ac
    ld   ac, [p_x]
    ld   [n_y], ac
    ld   ac, [p_y]
    ld   LINK_LO, x             ; the old cell, without the player
    ld   scw_r75, [x]
    ld   LINK_HI, x
    ld   scw_r75 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r75:
    ld   LINK_LO, x             ; CALL camera_follow
    ld   scw_r76, [x]
    ld   LINK_HI, x
    ld   scw_r76 >> 8, [x]
    ld   camera_follow >> 8, y
    jmp  camera_follow
scw_r76:
    beq  mp_s
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r77, [x]
    ld   LINK_HI, x
    ld   scw_r77 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r77:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r78, [x]
    ld   LINK_HI, x
    ld   scw_r78 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r78:
    bra  mp_p
mp_s:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r79, [x]
    ld   LINK_HI, x
    ld   scw_r79 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r79:
mp_p:
    ld   [lock], ac
    bne  mp_e
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r80, [x]
    ld   LINK_HI, x
    ld   scw_r80 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r80:
mp_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; actions
; ============================================================

; do_action - AC = the panel's action 0-7
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
    ld   scw_r120, [x]
    ld   LINK_HI, x
    ld   scw_r120 >> 8, [x]
    ld   menu_row >> 8, y
    jmp  menu_row
scw_r120:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  dm_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; menu_row - text row 25 + w2: "| ", then actions w2 and w2 + 4 (two
; columns from 44 and 62)

#addr 0x1000
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
    ld   act0 >> 8, y
    ld   [u0], ac
    add  act0 & 0xFF, x
    ld   [y,x], ac
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
    ld   scw_r81, [x]
    ld   LINK_HI, x
    ld   scw_r81 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r81:
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r82, [x]
    ld   LINK_HI, x
    ld   scw_r82 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r82:
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
    ld   [w3], ac
    xor  A_PICK, ac
    bne  da_3
    ld   pick_action >> 8, y
    jmp  pick_action
da_3:
    ld   [w3], ac
    xor  A_CUT, ac
    bne  da_4
    ld   cut_action >> 8, y
    jmp  cut_action
da_4:
    ld   [w3], ac
    xor  A_REFILL, ac
    bne  da_5
    ld   refill_action >> 8, y
    jmp  refill_action
da_5:
    ld   [w3], ac
    sub  A_HOLD, ac
    blt  da_p
    beq  da_6
    ld   inst_action >> 8, y
    jmp  inst_action
da_p:
    ld   [w3], ac
    sub  A_PUTL, ac
    blt  da_6
    ld   put_action >> 8, y
    jmp  put_action
da_6:
    ld   door_action >> 8, y
    jmp  door_action
da_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; door_action - OPEN, HOLD OPEN or CLOSE (w3) the door the panel shows,
; from next to it (the rest of do_action: its LEAVE).  Held open is bit 7
; of the type byte (map_put clears it: OPEN and CLOSE let go)
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
tug_sum:
    ld   [v4], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [v6]
    ld   [v5], ac
    shl
    shl
    shl
    shl
    or   [v6], ac
    ld   ac, [val_l]
    ld   [v5], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [val_h]
    clr  ac
    ld   ac, [sup]
    ld   [n_o2], ac
    beq  tu_e
    ld   [n_scr], ac
    beq  tu_e
    ld   1, ac
    ld   ac, [sup]
tu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; near - AC = 1 when the panel's cell is the player's or next to it
; (diagonals too).  A leaf.

#addr 0x1100
door_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r83, [x]
    ld   LINK_HI, x
    ld   scw_r83 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r83:
    beq  dr_far
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   [w3], ac
    xor  A_OPEN, ac
    bne  dr_h
    ld   T_DOORO, ac
    bra  dr_set
dr_h:
    ld   [w3], ac
    xor  A_HOLD, ac
    bne  dr_cl
    ld   T_DOORO | 0x80, ac
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
    ld   scw_r84, [x]
    ld   LINK_HI, x
    ld   scw_r84 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r84:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dr_ok:
    ld   T_DOOR, ac
dr_set:
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r85, [x]
    ld   LINK_HI, x
    ld   scw_r85 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r85:
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r86, [x]
    ld   LINK_HI, x
    ld   scw_r86 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r86:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r87, [x]
    ld   LINK_HI, x
    ld   scw_r87 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r87:
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
    ld   scw_r88, [x]
    ld   LINK_HI, x
    ld   scw_r88 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r88:
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
    ld   scw_r118, [x]
    ld   LINK_HI, x
    ld   scw_r118 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r118:
    ld   [R1], ac
    beq  di_n
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r119, [x]
    ld   LINK_HI, x
    ld   scw_r119 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r119:
di_n:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  di_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_menu - the actions, two columns on rows 25-28 from column 42 (the
; one under the pointer in inverse)

#addr 0x1200
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
    ld   scw_r92, [x]
    ld   LINK_HI, x
    ld   scw_r92 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r92:
    clr  ac
    ld   ac, [n_act]
    ld   [s_who], ac
    beq  dp_m
    ld   LINK_LO, x             ; CALL subj_load
    ld   scw_r93, [x]
    ld   LINK_HI, x
    ld   scw_r93 >> 8, [x]
    ld   subj_load >> 8, y
    jmp  subj_load
scw_r93:
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
    ld   scw_r94, [x]
    ld   LINK_HI, x
    ld   scw_r94 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r94:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r95, [x]
    ld   LINK_HI, x
    ld   scw_r95 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r95:
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_DMG, ac
    beq  dp_i
    ld   LINK_LO, x             ; CALL draw_dmg
    ld   scw_r96, [x]
    ld   LINK_HI, x
    ld   scw_r96 >> 8, [x]
    ld   draw_dmg >> 8, y
    jmp  draw_dmg
scw_r96:
dp_i:
    ld   [s_who], ac
    xor  2, ac
    bne  dp_c
    ld   LINK_LO, x             ; CALL draw_player
    ld   scw_r97, [x]
    ld   LINK_HI, x
    ld   scw_r97 >> 8, [x]
    ld   draw_player >> 8, y
    jmp  draw_player
scw_r97:
    bra  dp_m
dp_c:
    ld   LINK_LO, x             ; CALL draw_tags
    ld   scw_r98, [x]
    ld   LINK_HI, x
    ld   scw_r98 >> 8, [x]
    ld   draw_tags >> 8, y
    jmp  draw_tags
scw_r98:
    ld   LINK_LO, x             ; CALL draw_info
    ld   scw_r99, [x]
    ld   LINK_HI, x
    ld   scw_r99 >> 8, [x]
    ld   draw_info >> 8, y
    jmp  draw_info
scw_r99:
dp_m:
    ld   LINK_LO, x             ; CALL draw_menu
    ld   scw_r100, [x]
    ld   LINK_HI, x
    ld   scw_r100 >> 8, [x]
    ld   draw_menu >> 8, y
    jmp  draw_menu
scw_r100:
    ld   LINK_LO, x             ; CALL draw_msg
    ld   scw_r101, [x]
    ld   LINK_HI, x
    ld   scw_r101 >> 8, [x]
    ld   draw_msg >> 8, y
    jmp  draw_msg
scw_r101:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; subj_load - s_t, s_f, n_act and the action codes of the subject
near:
    ld   [s_x], ac
    sub  [p_x], ac
    inc
    sub  3, ac
    bcc  nr_n
    ld   [s_y], ac
    sub  [p_y], ac
    inc
    sub  3, ac
    bcc  nr_n
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
nr_n:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; walk_delay - AC = frames between steps: more for each part carried
; (the cutter is light).  A leaf.
on_tug:
    ld   [s_x], ac
    sub  TUG_X0, ac
    sub  TUG_X1 - TUG_X0 + 1, ac
    bcc  ot_n
    ld   [s_y], ac
    sub  TUG_Y0, ac
    sub  TUG_Y1 - TUG_Y0 + 1, ac
    bcc  ot_n
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ot_n:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; refill_action - REFILL SUIT: a full tank fills the suit (11 L less for
; each damage step) and is empty.  The rest of do_action.

#addr 0x1300
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
    ld   ac, [s_r]
    ld   ac, [s_b]
    ld   ac, [n_act]
    ld   LINK_LO, x             ; CALL player_acts
    ld   scw_r102, [x]
    ld   LINK_HI, x
    ld   scw_r102 >> 8, [x]
    ld   player_acts >> 8, y
    jmp  player_acts
scw_r102:
    bra  sl_a
sl_c:
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r103, [x]
    ld   LINK_HI, x
    ld   scw_r103 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r103:
    ld   ac, [s_t]
    ld   [c_f], ac
    ld   ac, [s_f]
    ld   [c_r], ac
    ld   ac, [s_r]
    ld   [c_b], ac
    ld   ac, [s_b]
    ld   LINK_LO, x             ; CALL dyn_acts
    ld   scw_r104, [x]
    ld   LINK_HI, x
    ld   scw_r104 >> 8, [x]
    ld   dyn_acts >> 8, y
    jmp  dyn_acts
scw_r104:
sl_a:
    ld   [s_t], ac              ; ACT_PG: 4 t + i
    shl
    shl
    ld   ac, [u0]
sl_l:
    ld   [n_act], ac
    xor  8, ac
    beq  sl_e
    ld   ACT_PG, y
    ld   [u0], x
    ld   [y,x], ac
    beq  sl_e
    ld   ac, [u1]
    xor  A_HOLD, ac             ; a door held open: no HOLD OPEN
    bne  sl_k
    ld   [s_b], ac
    bne  sl_n
sl_k:
    ld   act0 >> 8, y
    ld   [n_act], ac
    add  act0 & 0xFF, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   [n_act], ac
    inc
    ld   ac, [n_act]
sl_n:
    ld   [u0], ac               ; the type's 4 at most
    inc
    ld   ac, [u0]
    and  3, ac
    bne  sl_l
sl_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dyn_acts - the actions the subject cell has now: for a bolted part CUT
; FREE (in the tug: UNINSTALL), for a loose one INSTALL (a ship system on
; the tug) and PICK UP; REFILL for a full O2 tank; PUT DOWN for each
; carried part on a deck.  n_act from 0.
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
; at" line for damage step s_f, a 02 the seal line (ts_seal)
dyn_acts:
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
    ld   ac, [n_act]
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    beq  dy_o
    ld   [s_b], ac
    beq  dy_in
    ld   A_UNINST, ac           ; in a wreck it takes the cutter
    bra  dy_a
dy_in:
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_INST, ac
    beq  dy_pk
    ld   LINK_LO, x             ; CALL on_tug
    ld   scw_r105, [x]
    ld   LINK_HI, x
    ld   scw_r105 >> 8, [x]
    ld   on_tug >> 8, y
    jmp  on_tug
scw_r105:
    beq  dy_pk
    ld   A_INSTALL, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r106, [x]
    ld   LINK_HI, x
    ld   scw_r106 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r106:
dy_pk:
    ld   A_PICK, ac
dy_a:
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r107, [x]
    ld   LINK_HI, x
    ld   scw_r107 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r107:
dy_o:
    ld   [s_t], ac
    xor  T_O2, ac
    bne  dy_f
    ld   A_REFILL, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r108, [x]
    ld   LINK_HI, x
    ld   scw_r108 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r108:
dy_f:
    ld   [s_t], ac
    xor  T_FLOOR, ac
    bne  dy_e
    ld   [cl_t], ac
    beq  dy_1
    ld   A_PUTL, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r109, [x]
    ld   LINK_HI, x
    ld   scw_r109 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r109:
dy_1:
    ld   [cr_t], ac
    beq  dy_2
    ld   A_PUTR, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r110, [x]
    ld   LINK_HI, x
    ld   scw_r110 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r110:
dy_2:
    ld   [cb_t], ac
    beq  dy_e
    ld   A_PUTB, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r111, [x]
    ld   LINK_HI, x
    ld   scw_r111 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r111:
dy_e:
    ld   dyn_struct >> 8, y
    jmp  dyn_struct

; add_act - AC = an action code, added to the subject's list (8 at most).
; A leaf.
walk_delay:
    ld   WALK_FRAMES, ac
    ld   ac, [u2]
    ld   cl_t, ac
    ld   ac, [u3]
wd_l:
    ld   [u3], x
    ld   [x], ac
    beq  wd_n
    xor  T_CUTTER, ac
    beq  wd_n
    ld   [u2], ac
    add  HEAVY_FRAMES, ac
    ld   ac, [u2]
wd_n:
    ld   [u3], ac
    inc
    ld   ac, [u3]
    xor  cb_t + 1, ac
    bne  wd_l
    ld   [u2], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; pick_action - PICK UP: the part into the first free carry slot (left
; hand, right hand, back); a bare deck is left.  The rest of do_action.
free_slot:
    ld   [cl_t], ac
    bne  fs_1
    ld   cl_t, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
fs_1:
    ld   [cr_t], ac
    bne  fs_2
    ld   cr_t, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
fs_2:
    ld   [cb_t], ac
    bne  fs_3
    ld   cb_t, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
fs_3:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; plate_room - AC = 0 (and the message) when the panel shows a deck and
; no carry slot is free for its plate; else 1

#addr 0x1500
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
    ld   scw_r112, [x]
    ld   LINK_HI, x
    ld   scw_r112 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r112:
    ld   BAR_PG, ac
    ld   ac, [u5]
    ld   [s_f], ac
    ld   ac, [u6]
    add  16, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r113, [x]
    ld   LINK_HI, x
    ld   scw_r113 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r113:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r114, [x]
    ld   LINK_HI, x
    ld   scw_r114 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r114:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r115, [x]
    ld   LINK_HI, x
    ld   scw_r115 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r115:
    ld   TAB_PG, ac
    ld   ac, [u5]
    ld   [s_f], ac
    add  TB_DMGL, ac
    ld   ac, [u6]
    ld   [s_f], ac
    add  TB_DMGH, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r116, [x]
    ld   LINK_HI, x
    ld   scw_r116 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r116:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r117, [x]
    ld   LINK_HI, x
    ld   scw_r117 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r117:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_info - the subject's 4 info lines, rows 25-28 from column 1
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
    ld   42, ac
    ld   ac, [CUR_COL]
    ld   [s_who], ac
    beq  mr_sp
    ld   0x7C, ac               ; |
    bra  mr_c
mr_sp:
    ld   0x20, ac
mr_c:
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r121, [x]
    ld   LINK_HI, x
    ld   scw_r121 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r121:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r122, [x]
    ld   LINK_HI, x
    ld   scw_r122 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r122:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL menu_item
    ld   scw_r123, [x]
    ld   LINK_HI, x
    ld   scw_r123 >> 8, [x]
    ld   menu_item >> 8, y
    jmp  menu_item
scw_r123:
    ld   [w2], ac
    add  4, ac
    ld   LINK_LO, x             ; CALL menu_item
    ld   scw_r124, [x]
    ld   LINK_HI, x
    ld   scw_r124 >> 8, [x]
    ld   menu_item >> 8, y
    jmp  menu_item
scw_r124:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; menu_item - action AC at the cursor: " 1: OPEN" (its key, its name) in
; 18 columns, inverse under the pointer; blank past n_act

#addr 0x1600
menu_item:
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
    ld   [CUR_COL], ac
    add  18, ac
    ld   ac, [w5]               ; the column after it
    ld   [w4], ac
    sub  [n_act], ac
    bcc  mi_pad
    ld   [w4], ac
    xor  [m_sel], ac
    bne  mi_ni
    ld   0x80, ac
    ld   ac, [p_inv]
mi_ni:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r125, [x]
    ld   LINK_HI, x
    ld   scw_r125 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r125:
    ld   [w4], ac
    add  0x31, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r126, [x]
    ld   LINK_HI, x
    ld   scw_r126 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r126:
    ld   0x3A, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r127, [x]
    ld   LINK_HI, x
    ld   scw_r127 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r127:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r128, [x]
    ld   LINK_HI, x
    ld   scw_r128 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r128:
    ld   act0 >> 8, y
    ld   [w4], ac
    add  act0 & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   ACT_PG, ac
    ld   ac, [u5]
    ld   [u0], ac
    add  TB_ASTRL, ac
    ld   ac, [u6]
    ld   [u0], ac
    add  TB_ASTRH, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r129, [x]
    ld   LINK_HI, x
    ld   scw_r129 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r129:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r130, [x]
    ld   LINK_HI, x
    ld   scw_r130 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r130:
mi_pad:
    ld   [CUR_COL], ac
    xor  [w5], ac
    beq  mi_e
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r131, [x]
    ld   LINK_HI, x
    ld   scw_r131 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r131:
    bra  mi_pad
mi_e:
    clr  ac
    ld   ac, [p_inv]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pad80 - spaces to the end of the text row
work_end:
    ld   [rb_go], ac
    beq  we_t
    ld   LINK_LO, x             ; CALL rooms_build
    ld   scw_r177, [x]
    ld   LINK_HI, x
    ld   scw_r177 >> 8, [x]
    ld   rooms_build >> 8, y
    jmp  rooms_build
scw_r177:
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r178, [x]
    ld   LINK_HI, x
    ld   scw_r178 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r178:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r179, [x]
    ld   LINK_HI, x
    ld   scw_r179 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r179:
we_t:
    ld   LINK_LO, x             ; CALL tug_scan
    ld   scw_r180, [x]
    ld   LINK_HI, x
    ld   scw_r180 >> 8, [x]
    ld   tug_scan >> 8, y
    jmp  tug_scan
scw_r180:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; cut_pay - a cut's battery (cut_m 0).  A leaf.

#addr 0x1700
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
    ld   scw_r133, [x]
    ld   LINK_HI, x
    ld   scw_r133 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r133:
    ld   [msg_t], ac
    bne  dm_on
    ld   [stage], ac
    beq  dm_off
    ld   draw_warn >> 8, y
    jmp  draw_warn
dm_on:
    ld   TINT_MSG | 0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r134, [x]
    ld   LINK_HI, x
    ld   scw_r134 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r134:
    ld   29, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   [msg_l], ac
    ld   ac, [R0]
    ld   [msg_h], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r135, [x]
    ld   LINK_HI, x
    ld   scw_r135 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r135:
    ld   [cut_t], ac
    beq  dm_x
    ld   LINK_LO, x             ; CALL job_bar
    ld   scw_r136, [x]
    ld   LINK_HI, x
    ld   scw_r136 >> 8, [x]
    ld   job_bar >> 8, y
    jmp  job_bar
scw_r136:
dm_x:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dm_off:
    ld   0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r137, [x]
    ld   LINK_HI, x
    ld   scw_r137 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r137:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; msg_tint - AC = the mode byte of row 29's lines (x5BF0-x5BFF).  A leaf.
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
    xor  3, ac
    bne  ts_c
    ld   ts_seal >> 8, y
    jmp  ts_seal
ts_c:
    xor  2, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r138, [x]
    ld   LINK_HI, x
    ld   scw_r138 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r138:
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
    ld   scw_r139, [x]
    ld   LINK_HI, x
    ld   scw_r139 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r139:
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
; phase 3: carrying, cutting, the tug, the air
; ============================================================

; PSTR-style loads are spelled out: R1:R0 = a string, then tputs.

; game_init - the suit, the hands, the rooms' air, the tug (start, and
; again after dying)

#addr 0x1800
game_init:
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
    ld   ac, [cl_t]
    ld   ac, [cb_t]
    ld   ac, [cl_d]
    ld   ac, [cr_d]
    ld   ac, [cb_d]
    ld   ac, [air_t]
    ld   ac, [sec_t]
    ld   ac, [cut_t]
    ld   ac, [stage]
    ld   ac, [col_t]
    ld   ac, [dead]
    ld   ac, [v0]
    ld   T_CUTTER, ac
    ld   ac, [cr_t]
    ld   LINK_LO, x             ; CALL skills_init
    ld   scw_r140, [x]
    ld   LINK_HI, x
    ld   scw_r140 >> 8, [x]
    ld   skills_init >> 8, y
    jmp  skills_init
scw_r140:
    ld   SUIT_O2, ac
    ld   ac, [o2]
    ld   100, ac
    ld   ac, [batt]
gi_l:
    ld   ROOM_PG, y             ; ROOM_P = RM_P0, ROOM_C = under COLD_P
    ld   [v0], ac
    add  RM_P0, x
    ld   [y,x], ac
    ld   ac, [v1]
    ld   ROOM_P >> 8, y
    ld   [v0], x
    ld   ac, [y,x]
    ld   [v0], ac
    add  ROOM_C & 0xFF, x
    ld   [v1], ac
    sub  COLD_P, ac
    bcs  gi_c
    ld   0, [y,x]
    bra  gi_n
gi_c:
    ld   1, [y,x]
gi_n:
    ld   [v0], ac
    inc
    ld   ac, [v0]
    xor  0x40, ac
    bne  gi_l
    ld   LINK_LO, x             ; CALL rooms_build
    ld   scw_r141, [x]
    ld   LINK_HI, x
    ld   scw_r141 >> 8, [x]
    ld   rooms_build >> 8, y
    jmp  rooms_build
scw_r141:
    ld   LINK_LO, x             ; CALL tug_scan
    ld   scw_r142, [x]
    ld   LINK_HI, x
    ld   scw_r142 >> 8, [x]
    ld   tug_scan >> 8, y
    jmp  tug_scan
scw_r142:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; game_tick - once a frame: cutting, the air (every 8 frames), the suit
; (every second)
game_tick:
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
    ld   [cut_t], ac
    beq  gt_1
    ld   LINK_LO, x             ; CALL work_tick
    ld   scw_r143, [x]
    ld   LINK_HI, x
    ld   scw_r143 >> 8, [x]
    ld   work_tick >> 8, y
    jmp  work_tick
scw_r143:
gt_1:
    ld   [air_t], ac
    inc
    and  7, ac
    ld   ac, [air_t]
    bne  gt_2
    ld   LINK_LO, x             ; CALL air_tick
    ld   scw_r144, [x]
    ld   LINK_HI, x
    ld   scw_r144 >> 8, [x]
    ld   air_tick >> 8, y
    jmp  air_tick
scw_r144:
gt_2:
    ld   [sec_t], ac
    inc
    ld   ac, [sec_t]
    xor  60, ac
    bne  gt_e
    ld   ac, [sec_t]            ; AC = 0
    ld   LINK_LO, x             ; CALL second_tick
    ld   scw_r145, [x]
    ld   LINK_HI, x
    ld   scw_r145 >> 8, [x]
    ld   second_tick >> 8, y
    jmp  second_tick
scw_r145:
gt_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; air_tick - open doors and the airlocks share their rooms' air (the
; average), then air_leak
more_action:
    ld   [w3], ac
    xor  A_REPAIR, ac
    bne  ma_1
    ld   repair_action >> 8, y
    jmp  repair_action
ma_1:
    ld   [w3], ac
    xor  A_SKILLS, ac
    bne  ma_2
    ld   skills_action >> 8, y
    jmp  skills_action
ma_2:
    ld   suit_action >> 8, y
    jmp  suit_action

; repair_action - REPAIR: a damaged part next to the player, REPAIR_FRAMES
; (15) a damage step at full speed (cut_done: repair_done).  The rest of
; do_action

#addr 0x1900
air_tick:
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
    ld   ac, [v0]
at_d:
    ld   [v0], ac
    xor  [n_door], ac
    beq  at_e
    ld   DOOR_PG, y
    ld   [v0], x
    ld   [y,x], ac
    ld   ac, [v1]
    ld   [v0], ac
    add  0x40, x
    ld   [y,x], ac
    ld   ac, [v2]
    ld   [v1], y
    ld   [v2], x
    ld   [y,x], ac
    and  0x1F, ac
    ld   ac, [v3]
    xor  T_DOORO, ac
    beq  at_o
    ld   [v3], ac
    xor  T_LOCK, ac
    beq  at_o
    ld   LINK_LO, x             ; a closed door or a wall: leaks if broken
    ld   scw_r146, [x]
    ld   LINK_HI, x
    ld   scw_r146 >> 8, [x]
    ld   air_crack >> 8, y
    jmp  air_crack
scw_r146:
    bra  at_n
at_o:
    ld   DOOR_PG, y
    ld   [v0], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [v1]
    ld   [v0], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [v2]
    ld   ROOM_P >> 8, y
    ld   [v1], x
    ld   [y,x], ac
    ld   ac, [v3]
    ld   [v2], x
    ld   [y,x], ac
    add  [v3], ac
    shr  ac
    ld   ac, [y,x]
    ld   [v1], x
    ld   ac, [y,x]
at_n:
    ld   [v0], ac
    inc
    ld   ac, [v0]
    bra  at_d
at_e:
    ld   ROOM_P >> 8, y         ; room 0 is vacuum
    clr  x
    ld   0, [y,x]
    ld   air_leak >> 8, y
    jmp  air_leak

; air_leak - a breach empties its room (an eighth and one a tick); the
; tug's air tops its rooms up while it has a working O2 tank and
; scrubber.  The rest of air_tick.
air_leak:
    clr  ac
    ld   ac, [v0]
lk_l:
    ld   ROOM_PG, y
    ld   [v0], ac
    add  RM_LEAK, x
    ld   [y,x], ac
    beq  lk_e
    ld   ac, x
    ld   ROOM_P >> 8, y
    ld   [y,x], ac
    ld   ac, [v1]
    shr  ac
    shr  ac
    shr  ac
    inc
    ld   ac, [v2]
    ld   [v1], ac
    sub  [v2], ac
    bcc  lk_s
    clr  ac
lk_s:
    ld   ac, [y,x]
    ld   [v0], ac
    inc
    ld   ac, [v0]
    bra  lk_l
lk_e:
    ld   [sup], ac
    beq  sp_e
    ld   1, ac
    ld   ac, [v0]
sp_l:
    ld   [v0], ac
    xor  [n_room], ac
    beq  sp_e
    ld   ROOM_PG, y
    ld   [v0], ac
    add  RM_FL, x
    ld   [y,x], ac
    and  1, ac
    beq  sp_n
    ld   ROOM_P >> 8, y
    ld   [v0], x
    ld   [y,x], ac
    sub  AIR_FULL, ac
    bcc  sp_n
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
sp_n:
    ld   [v0], ac
    inc
    ld   ac, [v0]
    bra  sp_l
sp_e:
    ld   air_cold >> 8, y
    jmp  air_cold

; air_cold - ROOM_C again; a room that turned cold or warm: the view
; drawn again.  The rest of air_tick.
skills_init:
    ld   1, ac
    ld   ac, [suit_on]
    ld   SK_LV >> 8, y
    clr  ac
    ld   ac, [u0]
ki_l:
    ld   [u0], ac
    add  SK_LV & 0xFF, x
    ld   SKILL_START, [y,x]
    ld   [u0], ac
    add  SK_PR & 0xFF, x
    ld   0, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  6, ac
    bne  ki_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; job_start - a job of AC frames at full speed on the panel's part (s_t):
; 16 AC of work (wk), done at wk_r a frame (work_tick): 2 + the average
; of the quarters of the skills the part needs (TB_SKILL); in the suit
; half that and an eighth of the suit skill (not over it).  cut_t = 1
; while it runs.  A leaf.

#addr 0x1A00
air_cold:
    clr  ac
    ld   ac, [v3]
    ld   1, ac
    ld   ac, [v0]
ac_l:
    ld   [v0], ac
    xor  [n_room], ac
    beq  ac_e
    ld   ROOM_P >> 8, y
    ld   [v0], x
    ld   [y,x], ac
    sub  COLD_P, ac
    bcs  ac_c
    clr  ac
    bra  ac_s
ac_c:
    ld   1, ac
ac_s:
    ld   ac, [v1]
    ld   [v0], ac
    add  ROOM_C & 0xFF, x
    ld   [y,x], ac
    xor  [v1], ac
    beq  ac_n
    ld   [v1], ac
    ld   ac, [y,x]
    ld   1, ac
    ld   ac, [v3]
ac_n:
    ld   [v0], ac
    inc
    ld   ac, [v0]
    bra  ac_l
ac_e:
    ld   [v3], ac
    beq  ac_x
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r147, [x]
    ld   LINK_HI, x
    ld   scw_r147 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r147:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
ac_x:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; second_tick - once a second: the tug's parts; the suit uses its O2 in a
; room without air, and fills up (and charges) in the tug's air; then
; stage_set
second_tick:
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
    ld   LINK_LO, x             ; CALL tug_scan
    ld   scw_r148, [x]
    ld   LINK_HI, x
    ld   scw_r148 >> 8, [x]
    ld   tug_scan >> 8, y
    jmp  tug_scan
scw_r148:
    ld   [suit_on], ac
    bne  st_0
    ld   nosuit_tick >> 8, y
    jmp  nosuit_tick
st_0:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r149, [x]
    ld   LINK_HI, x
    ld   scw_r149 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r149:
    ld   ROOM_P >> 8, y
    ld   [c_r], x
    ld   [y,x], ac
    sub  BREATHE_P, ac
    bcc  st_air
    ld   [o2], ac               ; no air: the suit's
    beq  st_g
    dec
    ld   ac, [o2]
    bra  st_g
st_air:
    ld   ROOM_PG, y
    ld   [c_r], ac
    add  RM_FL, x
    ld   [y,x], ac
    and  1, ac
    beq  st_g
    ld   [sup], ac
    beq  st_b
    ld   [o2], ac
    add  3, ac
    ld   ac, [o2]
    sub  SUIT_O2 + 1, ac
    bcs  st_b
    ld   SUIT_O2, ac
    ld   ac, [o2]
st_b:
    ld   [n_bat], ac
    beq  st_g
    ld   [batt], ac
    xor  100, ac
    beq  st_g
    ld   [batt], ac
    inc
    ld   ac, [batt]
st_g:
    ld   stage_set >> 8, y
    jmp  stage_set

; stage_set - the warning stage from the suit's O2; ten seconds without
; any: dead.  A worse stage shows at once.  The rest of second_tick.
rb_pop:
    ld   [stk_l], ac
    bne  rq_1
    ld   [stk_h], ac
    xor  RB_STK, ac
    beq  rq_e
    ld   [stk_h], ac
    dec
    ld   ac, [stk_h]
rq_1:
    ld   [stk_l], ac
    sub  2, ac
    ld   ac, [stk_l]
    ld   [stk_h], y
    ld   [stk_l], x
    ld   [y,x], ac
    ld   ac, [rb_cx]
    ld   [stk_l], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [rb_cy]
    ld   1, ac
rq_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; set_room - AC = the room of the cell map_get last found (type byte bits
; 6-5: room bits 5-4; flag byte bits 7-4: room bits 3-0).  A leaf.

#addr 0x1B00
stage_set:
    ld   [o2], ac
    beq  ss_4
    clr  ac
    ld   ac, [col_t]
    ld   [o2], ac
    sub  9, ac
    bcs  ss_3
    ld   [o2], ac
    sub  23, ac
    bcs  ss_2
    ld   [o2], ac
    sub  45, ac
    bcs  ss_1
    clr  ac
    bra  ss_n
ss_1:
    ld   1, ac
    bra  ss_n
ss_2:
    ld   2, ac
    bra  ss_n
ss_3:
    ld   3, ac
    bra  ss_n
ss_4:
    ld   [col_t], ac
    inc
    ld   ac, [col_t]
    sub  COLLAPSE_S, ac
    bcs  ss_c
    ld   1, ac
    ld   ac, [dead]
    ld   5, ac
    bra  ss_n
ss_c:
    ld   4, ac
ss_n:
    ld   ac, [v0]
    xor  [stage], ac
    beq  ss_e
    ld   [v0], ac
    sub  [stage], ac
    bcs  ss_u
    clr  ac                     ; worse: the warning replaces the message
    ld   ac, [msg_t]
ss_u:
    ld   [v0], ac
    ld   ac, [stage]
    ld   [dirty], ac
    or   2, ac
    ld   ac, [dirty]
ss_e:
    ld   [s_who], ac
    beq  ss_x
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
ss_x:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; tug_scan - the tug's cells: its working O2 tanks, scrubbers, batteries
; and fuel tanks, and its worth (each part's value x (16 - damage) / 16,
; in $10); a part counts once it is installed (bolted).  Then tug_sum
pick_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r151, [x]
    ld   LINK_HI, x
    ld   scw_r151 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r151:
    beq  pk_far
    ld   cl_t, ac
    ld   ac, [v0]
pk_l:
    ld   [v0], x
    ld   [x], ac
    beq  pk_s
    ld   [v0], ac
    inc
    ld   ac, [v0]
    xor  cb_t + 1, ac
    bne  pk_l
    ld   s_full & 0xFF, ac
    ld   ac, [R0]
    ld   s_full >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r152, [x]
    ld   LINK_HI, x
    ld   scw_r152 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r152:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pk_s:
    ld   [s_t], ac
    ld   ac, [x]
    ld   [v0], ac
    add  3, x
    ld   [s_f], ac
    ld   ac, [x]
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r153, [x]
    ld   LINK_HI, x
    ld   scw_r153 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r153:
    ld   T_FLOOR, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r154, [x]
    ld   LINK_HI, x
    ld   scw_r154 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r154:
    clr  ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r155, [x]
    ld   LINK_HI, x
    ld   scw_r155 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r155:
    ld   act_done >> 8, y
    jmp  act_done
pk_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r156, [x]
    ld   LINK_HI, x
    ld   scw_r156 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r156:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; act_done - the cell g_x, g_y drawn again, the panel too.  The end of an
; action (do_action's LEAVE).

#addr 0x1C00
tug_scan:
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
    ld   ac, [n_o2]
    ld   ac, [n_scr]
    ld   ac, [n_bat]
    ld   ac, [n_fuel]
    ld   ac, [v4]
    ld   ac, [v5]
    ld   TUG_Y0, ac
    ld   ac, [v1]
ty_y:
    ld   TUG_X0, ac
    ld   ac, [v0]
ty_x:
    ld   [v0], ac
    ld   ac, [g_x]
    ld   [v1], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r150, [x]
    ld   LINK_HI, x
    ld   scw_r150 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r150:
    ld   ac, x                  ; a loose part is not part of the tug
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    beq  ty_i
    ld   [c_b], ac
    beq  ty_n
ty_i:
    ld   [c_t], ac
    add  TB_VAL, x
    ld   [y,x], ac
    beq  ty_c
    ld   ac, [v2]
    ld   16, ac
    sub  [c_f], ac
    ld   ac, [v3]
ty_v:
    ld   [v4], ac
    add  [v2], ac
    ld   ac, [v4]
    ld   [v5], ac
    bcc  ty_v1
    inc
    ld   ac, [v5]
ty_v1:
    ld   [v3], ac
    dec
    ld   ac, [v3]
    bne  ty_v
ty_c:
    ld   [c_f], ac
    sub  8, ac
    bcc  ty_n
    ld   [c_t], ac
    xor  T_O2, ac
    bne  ty_1
    ld   [n_o2], ac
    inc
    ld   ac, [n_o2]
ty_1:
    ld   [c_t], ac
    xor  T_SCRUB, ac
    bne  ty_2
    ld   [n_scr], ac
    inc
    ld   ac, [n_scr]
ty_2:
    ld   [c_t], ac
    xor  T_BATT, ac
    bne  ty_3
    ld   [n_bat], ac
    inc
    ld   ac, [n_bat]
ty_3:
    ld   [c_t], ac
    xor  T_FUEL, ac
    bne  ty_n
    ld   [n_fuel], ac
    inc
    ld   ac, [n_fuel]
ty_n:
    ld   [v0], ac
    inc
    ld   ac, [v0]
    xor  TUG_X1 + 1, ac
    bne  ty_x
    ld   [v1], ac
    inc
    ld   ac, [v1]
    xor  TUG_Y1 + 1, ac
    bne  ty_y
    ld   tug_sum >> 8, y
    jmp  tug_sum

; tug_sum - val = the sum / 16; sup = a working O2 tank and scrubber.
; The rest of tug_scan.
set_room:
    ld   ac, [u0]
    ld   [a_pg], y
    ld   [a_ix], x
    ld   [y,x], ac
    and  0x9F, ac
    ld   ac, [u1]
    ld   [u0], ac
    and  0x30, ac
    shl
    or   [u1], ac
    ld   ac, [y,x]
    ld   [a_pg], ac
    add  2, ac
    ld   ac, y
    ld   [y,x], ac
    and  0x0F, ac
    ld   ac, [u1]
    ld   [u0], ac
    shl
    shl
    shl
    shl
    or   [u1], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_links - each listed door, airlock or broken wall: the rooms on two
; opposite sides (a room, or 0 for vacuum and the edge; a solid cell is
; none) make a link in DOOR_PG when they differ (64 at most); the cell
; gets the room of a side.  The rest of rooms_build.
ts_seal:
    ld   ROOM_PG, y
    ld   [s_f], ac
    add  0x20, x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   [s_f], ac
    add  0x30, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   ts_wl >> 8, y
    jmp  ts_wl

; cell_extra - over a cell view_cell drew: the player without the suit
; (PL_NOSUIT), or a loose part's crate frame

#addr 0x1D00
put_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r158, [x]
    ld   LINK_HI, x
    ld   scw_r158 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r158:
    beq  pu_far
    ld   [s_x], ac
    xor  [p_x], ac
    bne  pu_ok
    ld   [s_y], ac
    xor  [p_y], ac
    bne  pu_ok
    ld   s_inway & 0xFF, ac
    ld   ac, [R0]
    ld   s_inway >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r159, [x]
    ld   LINK_HI, x
    ld   scw_r159 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r159:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pu_ok:
    ld   [w3], ac
    sub  A_PUTL, ac
    add  cl_t, ac
    ld   ac, [v0]
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r160, [x]
    ld   LINK_HI, x
    ld   scw_r160 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r160:
    xor  T_FLOOR, ac
    bne  pu_e
    ld   [v0], x
    ld   [x], ac
    beq  pu_e
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r161, [x]
    ld   LINK_HI, x
    ld   scw_r161 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r161:
    ld   [v0], ac
    add  3, x
    ld   [x], ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r162, [x]
    ld   LINK_HI, x
    ld   scw_r162 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r162:
    ld   [v0], x
    clr  ac
    ld   ac, [x]
    ld   act_done >> 8, y
    jmp  act_done
pu_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r163, [x]
    ld   LINK_HI, x
    ld   scw_r163 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r163:
pu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; cut_action - CUT FREE: needs a working cutter in a hand and battery;
; cutting takes CUT_FRAMES (cut_done).  The rest of do_action.
plate_room:
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
    ld   [s_t], ac
    xor  T_FLOOR, ac
    bne  pr_ok
    ld   LINK_LO, x             ; CALL free_slot
    ld   scw_r188, [x]
    ld   LINK_HI, x
    ld   scw_r188 >> 8, [x]
    ld   free_slot >> 8, y
    jmp  free_slot
scw_r188:
    bne  pr_ok
    ld   s_full & 0xFF, ac
    ld   ac, [R0]
    ld   s_full >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r189, [x]
    ld   LINK_HI, x
    ld   scw_r189 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r189:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
pr_ok:
    ld   1, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; lay_action - LAY DECK PLATE: a carried deck plate onto the open space
; the panel shows, next to the player.  The rest of do_action.
dyn_rep:
    ld   [s_f], ac
    beq  dq_e
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_DMG, ac
    beq  dq_e
    ld   A_REPAIR, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r272, [x]
    ld   LINK_HI, x
    ld   scw_r272 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r272:
dq_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; player_acts - the player's menu: SKILLS, then TAKE OFF SUIT, or PUT ON
; SUIT with the suit in a carry slot

#addr 0x1E00
cut_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r164, [x]
    ld   LINK_HI, x
    ld   scw_r164 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r164:
    beq  cu_far
    ld   [cl_t], ac
    xor  T_CUTTER, ac
    bne  cu_r
    ld   [cl_d], ac
    sub  8, ac
    bcs  cu_ok
cu_r:
    ld   [cr_t], ac
    xor  T_CUTTER, ac
    bne  cu_no
    ld   [cr_d], ac
    sub  8, ac
    bcs  cu_ok
cu_no:
    ld   s_nocut & 0xFF, ac
    ld   ac, [R0]
    ld   s_nocut >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r165, [x]
    ld   LINK_HI, x
    ld   scw_r165 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r165:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cu_ok:
    ld   LINK_LO, x             ; CALL plate_room
    ld   scw_r166, [x]
    ld   LINK_HI, x
    ld   scw_r166 >> 8, [x]
    ld   plate_room >> 8, y
    jmp  plate_room
scw_r166:
    beq  cu_e
    ld   [batt], ac
    sub  CUT_BATT, ac
    bcs  cu_nb
    clr  ac
    ld   ac, [cut_m]
    ld   CUT_FRAMES, ac
    ld   LINK_LO, x             ; CALL job_start
    ld   scw_r167, [x]
    ld   LINK_HI, x
    ld   scw_r167 >> 8, [x]
    ld   job_start >> 8, y
    jmp  job_start
scw_r167:
    ld   [s_x], ac
    ld   ac, [cut_x]
    ld   [s_y], ac
    ld   ac, [cut_y]
    ld   s_cutting & 0xFF, ac
    ld   ac, [R0]
    ld   s_cutting >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r168, [x]
    ld   LINK_HI, x
    ld   scw_r168 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r168:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cu_nb:
    ld   s_nobatt & 0xFF, ac
    ld   ac, [R0]
    ld   s_nobatt >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r169, [x]
    ld   LINK_HI, x
    ld   scw_r169 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r169:
cu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cu_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r170, [x]
    ld   LINK_HI, x
    ld   scw_r170 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r170:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; cut_done - the part at cut_x, cut_y is cut free (the battery pays),
; installed or uninstalled (cut_m); a wall, deck or door of the ship is
; taken out (struct_done); a wall panel or door installed is a wall or
; door again.  Then the rooms (if the ship changed) and the tug again
dyn_struct:
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_STRUCT, ac
    beq  ds_v
    ld   [s_x], ac
    xor  [p_x], ac
    bne  ds_1
    ld   [s_y], ac
    xor  [p_y], ac
    beq  ds_e
ds_1:
    ld   A_UNINST, ac
    bra  ds_a
ds_v:
    ld   [s_t], ac
    xor  T_SPACE, ac
    beq  ds_p
    ld   [s_t], ac
    xor  T_STAR, ac
    bne  ds_e
ds_p:
    ld   [cl_t], ac
    xor  T_PLATE, ac
    beq  ds_l
    ld   [cr_t], ac
    xor  T_PLATE, ac
    beq  ds_l
    ld   [cb_t], ac
    xor  T_PLATE, ac
    bne  ds_e
ds_l:
    ld   A_LAY, ac
ds_a:
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r196, [x]
    ld   LINK_HI, x
    ld   scw_r196 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r196:
ds_e:
    ld   dyn_rep >> 8, y
    jmp  dyn_rep

; air_crack - a link that is not open (v1:v2 its type byte, v3 its type):
; from 50 % damage it leaks, a unit a tick toward the lower side; to
; vacuum (room 0) two.  The rest of air_tick's loop (its v0)

#addr 0x2000
cut_done:
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
    ld   ac, [rb_go]
    ld   [cut_x], ac
    ld   ac, [g_x]
    ld   [cut_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r171, [x]
    ld   LINK_HI, x
    ld   scw_r171 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r171:
    ld   [cut_m], ac
    xor  3, ac
    bne  cd_0
    ld   repair_done >> 8, y
    jmp  repair_done
cd_0:
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_STRUCT, ac
    beq  cd_i
    ld   struct_done >> 8, y
    jmp  struct_done
cd_i:
    ld   [cut_m], ac
    xor  1, ac
    bne  cd_f
    ld   [c_t], ac              ; installed: a wall panel a wall, a door a door
    xor  T_PANEL, ac
    bne  cd_k
    ld   T_WALL, ac
    bra  cd_s
cd_k:
    ld   [c_t], ac
    xor  T_DOORK, ac
    bne  cd_b
    ld   T_DOOR, ac
cd_s:
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r172, [x]
    ld   LINK_HI, x
    ld   scw_r172 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r172:
    ld   1, ac
    ld   ac, [rb_go]
    bra  cd_im
cd_b:
    ld   [c_t], ac              ; a part: bolted
    or   0x80, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r173, [x]
    ld   LINK_HI, x
    ld   scw_r173 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r173:
cd_im:
    ld   s_instdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_instdone >> 8, ac
    bra  cd_m
cd_f:
    ld   [c_t], ac
    ld   LINK_LO, x             ; the same type, not bolted
    ld   scw_r174, [x]
    ld   LINK_HI, x
    ld   scw_r174 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r174:
    ld   [cut_m], ac
    beq  cd_c
    ld   s_uninstdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_uninstdone >> 8, ac
    bra  cd_m
cd_c:
    ld   LINK_LO, x             ; CALL cut_pay
    ld   scw_r175, [x]
    ld   LINK_HI, x
    ld   scw_r175 >> 8, [x]
    ld   cut_pay >> 8, y
    jmp  cut_pay
scw_r175:
    ld   s_cutdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_cutdone >> 8, ac
cd_m:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r176, [x]
    ld   LINK_HI, x
    ld   scw_r176 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r176:
    ld   work_end >> 8, y
    jmp  work_end

; work_end - the rooms again if the ship changed (rb_go), the tug, the
; panel.  The end of cut_done (its LEAVE).
rl_set:
    ld   [rb_cx], ac
    ld   ac, [g_x]
    ld   [rb_cy], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r218, [x]
    ld   LINK_HI, x
    ld   scw_r218 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r218:
    ld   [v6], ac
    ld   LINK_LO, x             ; CALL set_room
    ld   scw_r219, [x]
    ld   LINK_HI, x
    ld   scw_r219 >> 8, [x]
    ld   set_room >> 8, y
    jmp  set_room
scw_r219:
    ld   [rb_x], ac
    inc
    ld   ac, [rb_x]
    ld   rl_l >> 8, y
    jmp  rl_l

; rl_side - AC = the room of neighbour rb_k of the link cell: 0 vacuum or
; the edge, xFF a solid cell.  An airlock there (two docked side by side):
; the cell past it.  Uses rb_y, rb_t, v3 (free in rb_links).

#addr 0x2100
struct_done:
    ld   1, ac
    ld   ac, [rb_go]
    ld   [c_t], ac
    xor  T_FLOOR, ac
    beq  sd_f
    ld   [c_t], ac
    xor  T_WALL, ac
    bne  sd_d
    ld   T_PANEL, ac
    bra  sd_p
sd_d:
    ld   T_DOORK, ac            ; a door, open or closed
sd_p:
    ld   LINK_LO, x             ; loose, its damage kept
    ld   scw_r181, [x]
    ld   LINK_HI, x
    ld   scw_r181 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r181:
    bra  sd_m
sd_f:
    ld   LINK_LO, x             ; CALL free_slot
    ld   scw_r182, [x]
    ld   LINK_HI, x
    ld   scw_r182 >> 8, [x]
    ld   free_slot >> 8, y
    jmp  free_slot
scw_r182:
    beq  sd_full
    ld   ac, [v0]
    ld   [v0], x
    ld   T_PLATE, ac
    ld   ac, [x]
    ld   [v0], ac
    add  3, x
    ld   [c_f], ac
    ld   ac, [x]
    ld   T_SPACE, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r183, [x]
    ld   LINK_HI, x
    ld   scw_r183 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r183:
    clr  ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r184, [x]
    ld   LINK_HI, x
    ld   scw_r184 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r184:
sd_m:
    ld   [cut_m], ac
    bne  sd_u
    ld   LINK_LO, x             ; CALL cut_pay
    ld   scw_r185, [x]
    ld   LINK_HI, x
    ld   scw_r185 >> 8, [x]
    ld   cut_pay >> 8, y
    jmp  cut_pay
scw_r185:
sd_u:
    ld   [c_t], ac
    xor  T_FLOOR, ac
    beq  sd_pl
    ld   [cut_m], ac
    beq  sd_c
    ld   s_uninstdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_uninstdone >> 8, ac
    bra  sd_e
sd_c:
    ld   s_cutdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_cutdone >> 8, ac
    bra  sd_e
sd_pl:
    ld   s_plate & 0xFF, ac
    ld   ac, [R0]
    ld   s_plate >> 8, ac
sd_e:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r186, [x]
    ld   LINK_HI, x
    ld   scw_r186 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r186:
    ld   work_end >> 8, y
    jmp  work_end
sd_full:
    ld   s_full & 0xFF, ac
    ld   ac, [R0]
    ld   s_full >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r187, [x]
    ld   LINK_HI, x
    ld   scw_r187 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r187:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; free_slot - AC = the first empty carry slot's address (cl_t, cr_t,
; cb_t), 0 none.  A leaf.
rooms_build:
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
    ld   RB_S0 >> 8, ac         ; x4100-x46FF cleared
    ld   ac, [v0]
rb_c:
    clr  ac
    ld   ac, [v1]
rb_c2:
    ld   [v0], y
    ld   [v1], x
    ld   0, [y,x]
    ld   [v1], ac
    inc
    ld   ac, [v1]
    bne  rb_c2
    ld   [v0], ac
    inc
    ld   ac, [v0]
    xor  RB_STK, ac
    bne  rb_c
    clr  ac
    ld   ac, [rb_n]
    ld   ac, [n_door]
    ld   ac, [rb_y]
    ld   ac, [stk_l]
    ld   RB_STK, ac
    ld   ac, [stk_h]
    ld   rb_scan >> 8, y
    jmp  rb_scan

; rb_scan - every cell in map order: a solid cell's room is 0 (a link is
; listed), an air cell not filled yet starts a room.  The rest of
; rooms_build.

#addr 0x2200
lay_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r190, [x]
    ld   LINK_HI, x
    ld   scw_r190 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r190:
    beq  ly_far
    ld   cl_t, ac
    ld   ac, [v0]
ly_l:
    ld   [v0], x
    ld   [x], ac
    xor  T_PLATE, ac
    beq  ly_ok
    ld   [v0], ac
    inc
    ld   ac, [v0]
    xor  cb_t + 1, ac
    bne  ly_l
    ld   sc_leave >> 8, y
    jmp  sc_leave
ly_ok:
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r191, [x]
    ld   LINK_HI, x
    ld   scw_r191 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r191:
    ld   T_FLOOR, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r192, [x]
    ld   LINK_HI, x
    ld   scw_r192 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r192:
    ld   [v0], ac
    add  3, x
    ld   [x], ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r193, [x]
    ld   LINK_HI, x
    ld   scw_r193 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r193:
    ld   [v0], x
    clr  ac
    ld   ac, [x]
    ld   s_laid & 0xFF, ac
    ld   ac, [R0]
    ld   s_laid >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r194, [x]
    ld   LINK_HI, x
    ld   scw_r194 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r194:
    ld   1, ac
    ld   ac, [rb_go]
    ld   work_end >> 8, y
    jmp  work_end
ly_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r195, [x]
    ld   LINK_HI, x
    ld   scw_r195 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r195:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dyn_struct - the ship's own cells (not the player's): UNINSTALL (by hand
; on the tug, with the cutter in a wreck); LAY DECK PLATE on open space with a plate in
; a carry slot.  The rest of dyn_acts.
rb_solid:
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
    ld   [c_t], ac
    xor  T_WALL, ac
    bne  rs_d
    ld   [c_f], ac
    sub  8, ac
    bcs  rs_z
    bra  rs_l
rs_d:
    ld   [c_t], ac
    xor  T_DOOR, ac
    beq  rs_l
    ld   [c_t], ac
    xor  T_DOORO, ac
    beq  rs_l
    ld   [c_t], ac
    xor  T_LOCK, ac
    bne  rs_z
rs_l:
    ld   [n_door], ac
    xor  64, ac
    beq  rs_z
    ld   RB_DX >> 8, y
    ld   [n_door], ac
    add  RB_DX & 0xFF, x
    ld   [rb_x], ac
    ld   ac, [y,x]
    ld   RB_DY >> 8, y
    ld   [n_door], ac
    add  RB_DY & 0xFF, x
    ld   [rb_y], ac
    ld   ac, [y,x]
    ld   [n_door], ac
    inc
    ld   ac, [n_door]
rs_z:
    ld   [c_r], ac              ; most are 0 already
    beq  rs_e
    clr  ac
    ld   LINK_LO, x             ; CALL set_room
    ld   scw_r201, [x]
    ld   LINK_HI, x
    ld   scw_r201 >> 8, [x]
    ld   set_room >> 8, y
    jmp  set_room
scw_r201:
rs_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; rb_fill - the room rb_n from the cells on the stack: each cell's old
; pressure summed, its room set, its neighbours (rb_nbs)

#addr 0x2300
air_crack:
    ld   [v1], ac               ; the damage, two pages up
    add  2, ac
    ld   ac, y
    ld   [v2], x
    ld   [y,x], ac
    and  0x0F, ac
    sub  8, ac
    bcs  ak_e
    ld   DOOR_PG, y
    ld   [v0], ac
    add  0x80, x
    ld   [y,x], ac
    ld   ac, [v4]
    ld   [v0], ac
    add  0xC0, x
    ld   [y,x], ac
    ld   ac, [v5]
    beq  ak_v
    ld   [v4], ac
    bne  ak_r
    ld   [v5], ac               ; vacuum on side a: side b drains
    ld   ac, [v4]
ak_v:
    ld   ROOM_P >> 8, y
    ld   [v4], x
    ld   [y,x], ac
    sub  2, ac
    bcc  ak_s
    clr  ac
ak_s:
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ak_r:
    ld   ROOM_P >> 8, y         ; room to room: a unit from the higher
    ld   [v4], x
    ld   [y,x], ac
    ld   ac, [v6]
    ld   [v5], x
    ld   [y,x], ac
    ld   ac, [v7]
    ld   [v6], ac
    sub  [v7], ac
    bcs  ak_b                   ; a under b
    sub  2, ac
    bcs  ak_e                   ; a not 2 or more over b
    ld   [v6], ac
    dec
    ld   [v4], x
    ld   ac, [y,x]
    ld   [v7], ac
    inc
    ld   [v5], x
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ak_b:
    ld   [v7], ac
    sub  [v6], ac
    sub  2, ac
    bcs  ak_e
    ld   [v7], ac
    dec
    ld   [v5], x
    ld   ac, [y,x]
    ld   [v6], ac
    inc
    ld   [v4], x
    ld   ac, [y,x]
ak_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; rooms_build - the rooms worked out from the map: every air cell's room
; (a fill from each cell not yet filled, in map order: the same numbers
; as gen_scrap.py's rooms()), each room's pressure (the average of its
; cells' old pressures), whether it leaks (next to vacuum or the map's
; edge, the docking tube aside) and is the tug's; the links (doors,
; airlocks, broken walls) with their two rooms; ROOM_C.  After a wall,
; deck or door is taken out or put in.
; ============================================================
rb_fill:
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
rf_l:
    ld   LINK_LO, x             ; CALL rb_pop
    ld   scw_r202, [x]
    ld   LINK_HI, x
    ld   scw_r202 >> 8, [x]
    ld   rb_pop >> 8, y
    jmp  rb_pop
scw_r202:
    beq  rf_e
    ld   [rb_cx], ac
    ld   ac, [g_x]
    ld   [rb_cy], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r203, [x]
    ld   LINK_HI, x
    ld   scw_r203 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r203:
    ld   LINK_LO, x             ; CALL rb_acc
    ld   scw_r204, [x]
    ld   LINK_HI, x
    ld   scw_r204 >> 8, [x]
    ld   rb_acc >> 8, y
    jmp  rb_acc
scw_r204:
    ld   [rb_n], ac
    ld   LINK_LO, x             ; CALL set_room
    ld   scw_r205, [x]
    ld   LINK_HI, x
    ld   scw_r205 >> 8, [x]
    ld   set_room >> 8, y
    jmp  set_room
scw_r205:
    clr  ac
    ld   ac, [rb_k]
    ld   rb_nbs >> 8, y
    jmp  rb_nbs
rf_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; rb_nbs - the four neighbours of rb_cx, rb_cy: vacuum or the edge next
; to it, the room leaks; an air cell not filled yet goes on the stack.
; Back to rb_fill's loop.
rb_cold:
    clr  ac
    ld   ac, [rb_x]
rc_l:
    ld   ROOM_P >> 8, y
    ld   [rb_x], x
    ld   [y,x], ac
    sub  COLD_P, ac
    bcs  rc_c
    clr  ac
    bra  rc_s
rc_c:
    ld   1, ac
rc_s:
    ld   ac, [v0]
    ld   [rb_x], ac
    add  ROOM_C & 0xFF, x
    ld   [v0], ac
    ld   ac, [y,x]
    ld   [rb_x], ac
    inc
    ld   ac, [rb_x]
    xor  64, ac
    bne  rc_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; the bits of a byte, for the fill's map (VISADDR)

#addr 0x2400
rb_scan:
rb_sy:
    clr  ac
    ld   ac, [rb_x]
rb_sx:
    ld   [rb_x], ac
    ld   ac, [g_x]
    ld   [rb_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r197, [x]
    ld   LINK_HI, x
    ld   scw_r197 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r197:
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_SOLID, ac
    beq  rb_air
    ld   LINK_LO, x             ; CALL rb_solid
    ld   scw_r198, [x]
    ld   LINK_HI, x
    ld   scw_r198 >> 8, [x]
    ld   rb_solid >> 8, y
    jmp  rb_solid
scw_r198:
    bra  rb_nx
rb_air:
    ld   [g_y], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  RB_VIS, ac
    ld   ac, [u2]
    ld   [g_y], ac
    and  0x0F, ac
    shl
    shl
    shl
    shl
    ld   ac, [u3]
    ld   [g_x], ac
    shr  ac
    shr  ac
    shr  ac
    or   [u3], ac
    ld   ac, [u3]
    ld   [g_x], ac
    and  7, ac
    add  BIT_TAB & 0xFF, x
    ld   BIT_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [u4]
    ld   [u2], y
    ld   [u3], x
    ld   [y,x], ac
    and  [u4], ac
    bne  rb_nx
    ld   [rb_n], ac             ; a new room (63 at most)
    xor  63, ac
    beq  rb_f
    ld   [rb_n], ac
    inc
    ld   ac, [rb_n]
rb_f:
    ld   LINK_LO, x             ; CALL rb_push
    ld   scw_r199, [x]
    ld   LINK_HI, x
    ld   scw_r199 >> 8, [x]
    ld   rb_push >> 8, y
    jmp  rb_push
scw_r199:
    ld   LINK_LO, x             ; CALL rb_fill
    ld   scw_r200, [x]
    ld   LINK_HI, x
    ld   scw_r200 >> 8, [x]
    ld   rb_fill >> 8, y
    jmp  rb_fill
scw_r200:
rb_nx:
    ld   [rb_x], ac
    inc
    ld   ac, [rb_x]
    xor  MAP_W, ac
    bne  rb_sx
    ld   [rb_y], ac
    inc
    ld   ac, [rb_y]
    xor  MAP_H, ac
    bne  rb_sy
    ld   rb_links >> 8, y
    jmp  rb_links

; rb_solid - the solid cell map_get found: room 0; a door, an airlock or
; a wall from 50 % damage goes on the list to link (64 at most)
rb_acc:
    ld   ROOM_P >> 8, y
    ld   [c_r], x
    ld   [y,x], ac
    ld   ac, [u5]
    ld   RB_S0 >> 8, y
    ld   [rb_n], x
    ld   [y,x], ac
    add  [u5], ac
    ld   ac, [y,x]
    bcc  ra_1
    ld   [rb_n], ac
    add  RB_S1 & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bne  ra_1
    ld   [rb_n], ac
    add  RB_S2 & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
ra_1:
    ld   [rb_n], ac
    add  RB_CL & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bne  ra_2
    ld   RB_CH >> 8, y
    ld   [rb_n], x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
ra_2:
    ld   [rb_cx], ac
    sub  TUG_X0, ac
    sub  TUG_X1 - TUG_X0 + 1, ac
    bcc  ra_e
    ld   [rb_cy], ac
    sub  TUG_Y0, ac
    sub  TUG_Y1 - TUG_Y0 + 1, ac
    bcc  ra_e
    ld   RB_TG >> 8, y
    ld   [rb_n], ac
    add  RB_TG & 0xFF, x
    ld   1, [y,x]
ra_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_leak - room rb_n leaks.  A leaf.

#addr 0x2500
rb_nbs:
rn_l:
    ld   LINK_LO, x             ; CALL rb_nb
    ld   scw_r206, [x]
    ld   LINK_HI, x
    ld   scw_r206 >> 8, [x]
    ld   rb_nb >> 8, y
    jmp  rb_nb
scw_r206:
    bne  rn_in
    ld   LINK_LO, x             ; CALL rb_leak
    ld   scw_r207, [x]
    ld   LINK_HI, x
    ld   scw_r207 >> 8, [x]
    ld   rb_leak >> 8, y
    jmp  rb_leak
scw_r207:
    bra  rn_k
rn_in:
    ld   [g_y], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  RB_VIS, ac
    ld   ac, [u2]
    ld   [g_y], ac
    and  0x0F, ac
    shl
    shl
    shl
    shl
    ld   ac, [u3]
    ld   [g_x], ac
    shr  ac
    shr  ac
    shr  ac
    or   [u3], ac
    ld   ac, [u3]
    ld   [g_x], ac
    and  7, ac
    add  BIT_TAB & 0xFF, x
    ld   BIT_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [u4]
    ld   [u2], y
    ld   [u3], x
    ld   [y,x], ac
    and  [u4], ac
    bne  rn_k
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r208, [x]
    ld   LINK_HI, x
    ld   scw_r208 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r208:
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    ld   ac, [v1]
    and  F_VAC, ac
    beq  rn_s
    ld   LINK_LO, x             ; CALL rb_leak
    ld   scw_r209, [x]
    ld   LINK_HI, x
    ld   scw_r209 >> 8, [x]
    ld   rb_leak >> 8, y
    jmp  rb_leak
scw_r209:
rn_s:
    ld   [v1], ac
    and  F_SOLID, ac
    bne  rn_k
    ld   LINK_LO, x             ; CALL rb_push
    ld   scw_r210, [x]
    ld   LINK_HI, x
    ld   scw_r210 >> 8, [x]
    ld   rb_push >> 8, y
    jmp  rb_push
scw_r210:
rn_k:
    ld   [rb_k], ac
    inc
    ld   ac, [rb_k]
    xor  4, ac
    bne  rn_l
    ld   rf_l >> 8, y
    jmp  rf_l

; rb_acc - the cell map_get found: its old room's pressure added to room
; rb_n's sum, a cell counted, the tug's room marked.  A leaf.
rb_nb:
    ld   [rb_cx], ac
    ld   ac, [g_x]
    ld   [rb_cy], ac
    ld   ac, [g_y]
    ld   [rb_k], ac
    beq  nb_r
    xor  1, ac
    beq  nb_l
    ld   [rb_k], ac
    xor  2, ac
    beq  nb_d
    ld   [g_y], ac
    beq  nb_o
    dec
    ld   ac, [g_y]
    bra  nb_i
nb_r:
    ld   [g_x], ac
    inc
    ld   ac, [g_x]
    xor  MAP_W, ac
    beq  nb_o
    bra  nb_i
nb_l:
    ld   [g_x], ac
    beq  nb_o
    dec
    ld   ac, [g_x]
    bra  nb_i
nb_d:
    ld   [g_y], ac
    inc
    ld   ac, [g_y]
    xor  MAP_H, ac
    beq  nb_o
nb_i:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
nb_o:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_push - g_x, g_y marked filled and on the stack (not when it is
; full).  A leaf.
JB_TAB:
    #d8 zj_0 & 0xFF, zj_1 & 0xFF, zj_2 & 0xFF, zj_3 & 0xFF, zj_4 & 0xFF, zj_5 & 0xFF, zj_6 & 0xFF, zj_7 & 0xFF, zj_8 & 0xFF, zj_9 & 0xFF, zj_10 & 0xFF, zj_11 & 0xFF, zj_12 & 0xFF, zj_13 & 0xFF, zj_14 & 0xFF, zj_15 & 0xFF, zj_16 & 0xFF
    #d8 zj_0 >> 8, zj_1 >> 8, zj_2 >> 8, zj_3 >> 8, zj_4 >> 8, zj_5 >> 8, zj_6 >> 8, zj_7 >> 8, zj_8 >> 8, zj_9 >> 8, zj_10 >> 8, zj_11 >> 8, zj_12 >> 8, zj_13 >> 8, zj_14 >> 8, zj_15 >> 8, zj_16 >> 8


#addr 0x2600
rb_push:
    ld   [stk_h], ac
    xor  0x4D, ac
    beq  rp_e
    ld   [g_y], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  RB_VIS, ac
    ld   ac, [u2]
    ld   [g_y], ac
    and  0x0F, ac
    shl
    shl
    shl
    shl
    ld   ac, [u3]
    ld   [g_x], ac
    shr  ac
    shr  ac
    shr  ac
    or   [u3], ac
    ld   ac, [u3]
    ld   [g_x], ac
    and  7, ac
    add  BIT_TAB & 0xFF, x
    ld   BIT_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [u4]
    ld   [u2], y
    ld   [u3], x
    ld   [y,x], ac
    or   [u4], ac
    ld   ac, [y,x]
    ld   [stk_h], y
    ld   [stk_l], x
    ld   [g_x], ac
    ld   ac, [y,x]
    ld   [stk_l], ac
    add  1, x
    ld   [g_y], ac
    ld   ac, [y,x]
    ld   [stk_l], ac
    add  2, ac
    ld   ac, [stk_l]
    bne  rp_e
    ld   [stk_h], ac
    inc
    ld   ac, [stk_h]
rp_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_pop - rb_cx, rb_cy off the stack, AC = 1; AC = 0 when it is empty.
; A leaf.
rb_links:
    ld   [n_door], ac
    ld   ac, [v7]
    clr  ac
    ld   ac, [n_door]
    ld   ac, [rb_x]
rl_l:
    ld   [rb_x], ac
    xor  [v7], ac
    bne  rl_1
    ld   rb_press >> 8, y
    jmp  rb_press
rl_1:
    ld   RB_DX >> 8, y
    ld   [rb_x], ac
    add  RB_DX & 0xFF, x
    ld   [y,x], ac
    ld   ac, [rb_cx]
    ld   ac, [g_x]
    ld   RB_DY >> 8, y
    ld   [rb_x], ac
    add  RB_DY & 0xFF, x
    ld   [y,x], ac
    ld   ac, [rb_cy]
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r211, [x]
    ld   LINK_HI, x
    ld   scw_r211 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r211:
    ld   [a_pg], ac
    ld   ac, [v1]
    ld   [a_ix], ac
    ld   ac, [v2]
    clr  ac
    ld   ac, [v6]
    ld   1, ac                  ; left and right
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r212, [x]
    ld   LINK_HI, x
    ld   scw_r212 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r212:
    ld   ac, [v4]
    clr  ac
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r213, [x]
    ld   LINK_HI, x
    ld   scw_r213 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r213:
    ld   ac, [v3]
    ld   LINK_LO, x             ; CALL rl_add
    ld   scw_r214, [x]
    ld   LINK_HI, x
    ld   scw_r214 >> 8, [x]
    ld   rl_add >> 8, y
    jmp  rl_add
scw_r214:
    ld   3, ac                  ; up and down
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r215, [x]
    ld   LINK_HI, x
    ld   scw_r215 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r215:
    ld   ac, [v4]
    ld   2, ac
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r216, [x]
    ld   LINK_HI, x
    ld   scw_r216 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r216:
    ld   ac, [v3]
    ld   LINK_LO, x             ; CALL rl_add
    ld   scw_r217, [x]
    ld   LINK_HI, x
    ld   scw_r217 >> 8, [x]
    ld   rl_add >> 8, y
    jmp  rl_add
scw_r217:
    ld   rl_set >> 8, y
    jmp  rl_set

; rl_set - the link cell's room (v6).  Back to rb_links' loop.

#addr 0x2700
rl_side:
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
    ld   LINK_LO, x             ; CALL rb_nb
    ld   scw_r220, [x]
    ld   LINK_HI, x
    ld   scw_r220 >> 8, [x]
    ld   rb_nb >> 8, y
    jmp  rb_nb
scw_r220:
    beq  sd_0
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r221, [x]
    ld   LINK_HI, x
    ld   scw_r221 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r221:
    xor  T_LOCK, ac
    bne  sd_1
    ld   [rb_cx], ac            ; step over the other lock
    ld   ac, [rb_y]
    ld   [rb_cy], ac
    ld   ac, [rb_t]
    ld   [g_x], ac
    ld   ac, [rb_cx]
    ld   [g_y], ac
    ld   ac, [rb_cy]
    ld   LINK_LO, x             ; CALL rb_nb
    ld   scw_r222, [x]
    ld   LINK_HI, x
    ld   scw_r222 >> 8, [x]
    ld   rb_nb >> 8, y
    jmp  rb_nb
scw_r222:
    ld   ac, [v3]
    ld   [rb_y], ac             ; the link cell back
    ld   ac, [rb_cx]
    ld   [rb_t], ac
    ld   ac, [rb_cy]
    ld   [v3], ac
    beq  sd_0
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r223, [x]
    ld   LINK_HI, x
    ld   scw_r223 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r223:
sd_1:
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    ld   ac, [u5]
    and  F_VAC, ac
    bne  sd_0
    ld   [u5], ac
    and  F_SOLID, ac
    beq  sd_r
    ld   0xFF, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
sd_r:
    ld   [c_r], ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
sd_0:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; rl_add - a link v4 - v3 (rooms, 0 vacuum, xFF none) for the cell at
; v1:v2 when both sides are something, not both vacuum, and differ; v6 =
; the room of a side.  A leaf.
rl_add:
    ld   [v4], ac
    xor  0xFF, ac
    beq  la_e
    ld   [v3], ac
    xor  0xFF, ac
    beq  la_e
    ld   [v3], ac
    xor  [v4], ac
    beq  la_e
    ld   [n_door], ac
    xor  64, ac
    beq  la_e
    ld   DOOR_PG, y
    ld   [n_door], x
    ld   [v1], ac
    ld   ac, [y,x]
    ld   [n_door], ac
    add  0x40, x
    ld   [v2], ac
    ld   ac, [y,x]
    ld   [n_door], ac
    add  0x80, x
    ld   [v4], ac
    ld   ac, [y,x]
    ld   [n_door], ac
    add  0xC0, x
    ld   [v3], ac
    ld   ac, [y,x]
    ld   [n_door], ac
    inc
    ld   ac, [n_door]
    ld   [v4], ac
    bne  la_s
    ld   [v3], ac
la_s:
    ld   ac, [v6]
la_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_press - each room's pressure (the sum / the cells), whether it is the
; tug's, the leaking rooms' list; the rooms past the last emptied; then
; ROOM_C.  The rest of rooms_build.
put_dec8:
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
    ld   ac, [num_l]
    clr  ac
    ld   ac, [num_h]
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r262, [x]
    ld   LINK_HI, x
    ld   scw_r262 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r262:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; put_dec - num_h:num_l in decimal, no leading zeros

#addr 0x2800
rb_press:
    ld   1, ac
    ld   ac, [rb_x]
    clr  ac
    ld   ac, [rb_y]
rp_l:
    ld   [rb_n], ac
    sub  [rb_x], ac
    bcs  rp_z
    ld   LINK_LO, x             ; CALL rb_avg
    ld   scw_r224, [x]
    ld   LINK_HI, x
    ld   scw_r224 >> 8, [x]
    ld   rb_avg >> 8, y
    jmp  rb_avg
scw_r224:
    ld   ROOM_P >> 8, y
    ld   [rb_x], x
    ld   ac, [y,x]
    ld   RB_TG >> 8, y
    ld   [rb_x], ac
    add  RB_TG & 0xFF, x
    ld   [y,x], ac
    ld   ac, [v0]
    ld   ROOM_PG, y
    ld   [rb_x], ac
    add  RM_FL, x
    ld   [v0], ac
    ld   ac, [y,x]
    ld   RB_LK >> 8, y
    ld   [rb_x], ac
    add  RB_LK & 0xFF, x
    ld   [y,x], ac
    beq  rp_n
    ld   ROOM_PG, y
    ld   [rb_y], ac
    add  RM_LEAK, x
    ld   [rb_x], ac
    ld   ac, [y,x]
    ld   [rb_y], ac
    inc
    ld   ac, [rb_y]
    bra  rp_n
rp_z:
    ld   ROOM_P >> 8, y
    ld   [rb_x], x
    ld   0, [y,x]
    ld   ROOM_PG, y
    ld   [rb_x], ac
    add  RM_FL, x
    ld   0, [y,x]
rp_n:
    ld   [rb_x], ac
    inc
    ld   ac, [rb_x]
    xor  64, ac
    bne  rp_l
    ld   ROOM_PG, y
    ld   [rb_y], ac
    add  RM_LEAK, x
    ld   0, [y,x]
    ld   [rb_n], ac
    inc
    ld   ac, [n_room]
    ld   rb_cold >> 8, y
    jmp  rb_cold

; rb_avg - AC = room rb_x's sum / its cells (0-100).  A leaf.
rb_avg:
    ld   RB_S0 >> 8, y
    ld   [rb_x], x
    ld   [y,x], ac
    ld   ac, [v0]
    ld   [rb_x], ac
    add  RB_S1 & 0xFF, x
    ld   [y,x], ac
    ld   ac, [v1]
    ld   [rb_x], ac
    add  RB_S2 & 0xFF, x
    ld   [y,x], ac
    ld   ac, [v2]
    ld   [rb_x], ac
    add  RB_CL & 0xFF, x
    ld   [y,x], ac
    ld   ac, [v3]
    ld   RB_CH >> 8, y
    ld   [rb_x], x
    ld   [y,x], ac
    ld   ac, [v4]
    clr  ac
    ld   ac, [v5]
dv_l:
    ld   [v5], ac
    xor  AIR_FULL, ac
    beq  dv_e
    ld   [v0], ac               ; v2:v1:v0 - v4:v3, stop on a borrow
    sub  [v3], ac
    ld   ac, [v6]
    bcs  dv_b0
    ld   [v1], ac
    sub  [v4], ac
    ld   ac, [v7]
    bcs  dv_b1
    ld   [v2], ac
    bra  dv_ok
dv_b0:
    ld   [v1], ac
    sub  [v4], ac
    ld   ac, [v7]
    bcs  dv_bb
    ld   [v7], ac
    beq  dv_bz
    dec
    ld   ac, [v7]
    ld   [v2], ac
    bra  dv_ok
dv_bz:
    ld   0xFF, ac
    ld   ac, [v7]
    bra  dv_b1
dv_bb:
    ld   [v7], ac
    dec
    ld   ac, [v7]
dv_b1:
    ld   [v2], ac
    beq  dv_e
    dec
dv_ok:
    ld   ac, [v2]
    ld   [v6], ac
    ld   ac, [v0]
    ld   [v7], ac
    ld   ac, [v1]
    ld   [v5], ac
    inc
    ld   ac, [v5]
    bra  dv_l
dv_e:
    ld   [v5], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_cold - ROOM_C from the new pressures.  The end of rooms_build.

#addr 0x2900
inst_action:
    ld   [w3], ac
    sub  A_REPAIR, ac
    bcs  in_0
    ld   more_action >> 8, y
    jmp  more_action
in_0:
    ld   [w3], ac
    xor  A_LAY, ac
    bne  in_1
    ld   lay_action >> 8, y
    jmp  lay_action
in_1:
    ld   [w3], ac               ; UNINSTALL off the tug: the cutter's work
    xor  A_UNINST, ac
    bne  in_2
    ld   LINK_LO, x             ; CALL on_tug
    ld   scw_r225, [x]
    ld   LINK_HI, x
    ld   scw_r225 >> 8, [x]
    ld   on_tug >> 8, y
    jmp  on_tug
scw_r225:
    bne  in_2
    ld   cut_action >> 8, y
    jmp  cut_action
in_2:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r226, [x]
    ld   LINK_HI, x
    ld   scw_r226 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r226:
    beq  in_far
    ld   LINK_LO, x             ; CALL plate_room
    ld   scw_r227, [x]
    ld   LINK_HI, x
    ld   scw_r227 >> 8, [x]
    ld   plate_room >> 8, y
    jmp  plate_room
scw_r227:
    beq  in_e
    ld   INST_FRAMES, ac
    ld   LINK_LO, x             ; CALL job_start
    ld   scw_r228, [x]
    ld   LINK_HI, x
    ld   scw_r228 >> 8, [x]
    ld   job_start >> 8, y
    jmp  job_start
scw_r228:
    ld   [s_x], ac
    ld   ac, [cut_x]
    ld   [s_y], ac
    ld   ac, [cut_y]
    ld   [w3], ac
    xor  A_INSTALL, ac
    bne  in_u
    ld   1, ac
    ld   ac, [cut_m]
    ld   s_inst & 0xFF, ac
    ld   ac, [R0]
    ld   s_inst >> 8, ac
    bra  in_m
in_u:
    ld   2, ac
    ld   ac, [cut_m]
    ld   s_uninst & 0xFF, ac
    ld   ac, [R0]
    ld   s_uninst >> 8, ac
in_m:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r229, [x]
    ld   LINK_HI, x
    ld   scw_r229 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r229:
in_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
in_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r230, [x]
    ld   LINK_HI, x
    ld   scw_r230 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r230:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; on_tug - AC = 1 when the panel's cell is one of the tug's.  A leaf.
draw_player3:
    ld   24, ac                 ; on the name row
    ld   ac, [CUR_ROW]
    ld   22, ac
    ld   ac, [CUR_COL]
    ld   s_tug & 0xFF, ac
    ld   ac, [R0]
    ld   s_tug >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r250, [x]
    ld   LINK_HI, x
    ld   scw_r250 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r250:
    ld   [val_l], ac
    ld   ac, [num_l]
    ld   [val_h], ac
    ld   ac, [num_h]
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r251, [x]
    ld   LINK_HI, x
    ld   scw_r251 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r251:
    ld   [sup], ac
    beq  d3_off
    ld   s_airon & 0xFF, ac
    ld   ac, [R0]
    ld   s_airon >> 8, ac
    bra  d3_p
d3_off:
    ld   s_airoff & 0xFF, ac
    ld   ac, [R0]
    ld   s_airoff >> 8, ac
d3_p:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r252, [x]
    ld   LINK_HI, x
    ld   scw_r252 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r252:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; put_name - the name of type AC (EMPTY for 0)

#addr 0x2A00
refill_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r231, [x]
    ld   LINK_HI, x
    ld   scw_r231 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r231:
    beq  rf_far
    ld   [s_f], ac
    sub  8, ac
    bcs  rf_ok
    ld   s_broken & 0xFF, ac
    ld   ac, [R0]
    ld   s_broken >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r232, [x]
    ld   LINK_HI, x
    ld   scw_r232 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r232:
    ld   sc_leave >> 8, y
    jmp  sc_leave
rf_ok:
    ld   SUIT_O2, ac
    ld   ac, [v1]
    ld   [s_f], ac
    ld   ac, [v2]
rf_d:
    ld   [v2], ac
    beq  rf_a
    dec
    ld   ac, [v2]
    ld   [v1], ac
    sub  11, ac
    ld   ac, [v1]
    bra  rf_d
rf_a:
    ld   [o2], ac
    add  [v1], ac
    ld   ac, [o2]
    sub  SUIT_O2 + 1, ac
    bcs  rf_c
    ld   SUIT_O2, ac
    ld   ac, [o2]
rf_c:
    ld   s_refill & 0xFF, ac
    ld   ac, [R0]
    ld   s_refill >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r233, [x]
    ld   LINK_HI, x
    ld   scw_r233 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r233:
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r234, [x]
    ld   LINK_HI, x
    ld   scw_r234 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r234:
    ld   T_O2E, ac              ; still installed if it was
    or   [c_b], ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r235, [x]
    ld   LINK_HI, x
    ld   scw_r235 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r235:
    ld   act_done >> 8, y
    jmp  act_done
rf_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r236, [x]
    ld   LINK_HI, x
    ld   scw_r236 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r236:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_player - the player's rows 25-28: suit O2, battery, hands, back
; and the tug
put_name:
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
    beq  pn_e
    add  TB_NAMEL, ac
    ld   ac, [u6]
    add  TB_NAMEH - TB_NAMEL, ac
    ld   ac, [u7]
    ld   TAB_PG, ac
    ld   ac, [u5]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r253, [x]
    ld   LINK_HI, x
    ld   scw_r253 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r253:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r254, [x]
    ld   LINK_HI, x
    ld   scw_r254 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r254:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pn_e:
    ld   s_empty & 0xFF, ac
    ld   ac, [R0]
    ld   s_empty >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r255, [x]
    ld   LINK_HI, x
    ld   scw_r255 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r255:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_tags - row 24 of a cell: INSTALLED (bolted) or LOOSE for
; a part, HELD OPEN for a door; its room's air

#addr 0x2B00
draw_player:
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
    ld   25, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   [suit_on], ac
    bne  dp_s
    ld   s_pl_nosuit & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_nosuit >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r237, [x]
    ld   LINK_HI, x
    ld   scw_r237 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r237:
    bra  dp_26
dp_s:
    ld   s_pl_suit & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_suit >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r238, [x]
    ld   LINK_HI, x
    ld   scw_r238 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r238:
    ld   [o2], ac
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r239, [x]
    ld   LINK_HI, x
    ld   scw_r239 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r239:
    ld   s_pl_of & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_of >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r240, [x]
    ld   LINK_HI, x
    ld   scw_r240 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r240:
dp_26:
    ld   26, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_pl_batt & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_batt >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r241, [x]
    ld   LINK_HI, x
    ld   scw_r241 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r241:
    ld   [batt], ac
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r242, [x]
    ld   LINK_HI, x
    ld   scw_r242 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r242:
    ld   0x25, ac               ; %
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r243, [x]
    ld   LINK_HI, x
    ld   scw_r243 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r243:
    ld   draw_player2 >> 8, y
    jmp  draw_player2

draw_warn:
    ld   TINT_WARN | 0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r260, [x]
    ld   LINK_HI, x
    ld   scw_r260 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r260:
    ld   29, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   WARN_TAB >> 8, y
    ld   [stage], ac
    add  (WARN_TAB & 0xFF) - 1, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [stage], ac
    add  (WARN_TAB & 0xFF) + 4, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r261, [x]
    ld   LINK_HI, x
    ld   scw_r261 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r261:
    ld   sc_leave >> 8, y
    jmp  sc_leave


#addr 0x2C00
draw_player2:
    ld   27, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_pl_hands & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_hands >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r244, [x]
    ld   LINK_HI, x
    ld   scw_r244 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r244:
    ld   [cl_t], ac
    ld   LINK_LO, x             ; CALL put_name
    ld   scw_r245, [x]
    ld   LINK_HI, x
    ld   scw_r245 >> 8, [x]
    ld   put_name >> 8, y
    jmp  put_name
scw_r245:
    ld   s_slash & 0xFF, ac
    ld   ac, [R0]
    ld   s_slash >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r246, [x]
    ld   LINK_HI, x
    ld   scw_r246 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r246:
    ld   [cr_t], ac
    ld   LINK_LO, x             ; CALL put_name
    ld   scw_r247, [x]
    ld   LINK_HI, x
    ld   scw_r247 >> 8, [x]
    ld   put_name >> 8, y
    jmp  put_name
scw_r247:
    ld   28, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_pl_back & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_back >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r248, [x]
    ld   LINK_HI, x
    ld   scw_r248 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r248:
    ld   [cb_t], ac
    ld   LINK_LO, x             ; CALL put_name
    ld   scw_r249, [x]
    ld   LINK_HI, x
    ld   scw_r249 >> 8, [x]
    ld   put_name >> 8, y
    jmp  put_name
scw_r249:
    ld   draw_player3 >> 8, y
    jmp  draw_player3

put_dec:
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
    ld   ac, [num_z]
    ld   ac, [v6]
pd_p:
    clr  ac
    ld   ac, [v7]
    ld   PD_TAB >> 8, y
    ld   [v6], ac
    add  PD_TAB & 0xFF, x
    ld   [y,x], ac
    ld   ac, [v4]
    ld   [v6], ac
    add  (PD_TAB & 0xFF) + 5, x
    ld   [y,x], ac
    ld   ac, [v5]
pd_s:
    ld   [num_h], ac
    sub  [v5], ac
    bcs  pd_d
    ld   ac, [v3]
    ld   [num_l], ac
    sub  [v4], ac
    ld   ac, [v2]
    bcc  pd_ok
    ld   [v3], ac
    beq  pd_d
    dec
    ld   ac, [v3]
pd_ok:
    ld   [v2], ac
    ld   ac, [num_l]
    ld   [v3], ac
    ld   ac, [num_h]
    ld   [v7], ac
    inc
    ld   ac, [v7]
    bra  pd_s
pd_d:
    ld   [v7], ac
    or   [num_z], ac
    bne  pd_o
    ld   [v6], ac
    xor  4, ac
    bne  pd_n
pd_o:
    ld   1, ac
    ld   ac, [num_z]
    ld   [v7], ac
    add  0x30, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r263, [x]
    ld   LINK_HI, x
    ld   scw_r263 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r263:
pd_n:
    ld   [v6], ac
    inc
    ld   ac, [v6]
    xor  5, ac
    bne  pd_p
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; the art, tables and strings (gen_scrap.py)
; ============================================================
; ============================================================
; skills, jobs, the suit
; ============================================================

; skills_init - every skill at SKILL_START, no progress; the suit on.  A
; leaf.

#addr 0x2D00
draw_tags:
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
    ld   22, ac
    ld   ac, [CUR_COL]
    ld   [s_t], ac
    xor  T_DOORO, ac
    bne  dt_i
    ld   [s_b], ac
    beq  dt_a
    ld   s_held & 0xFF, ac
    ld   ac, [R0]
    ld   s_held >> 8, ac
    bra  dt_p
dt_i:
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    beq  dt_a
    ld   [s_b], ac
    beq  dt_l
    ld   s_installed & 0xFF, ac
    ld   ac, [R0]
    ld   s_installed >> 8, ac
    bra  dt_p
dt_l:
    ld   s_loose & 0xFF, ac
    ld   ac, [R0]
    ld   s_loose >> 8, ac
dt_p:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r256, [x]
    ld   LINK_HI, x
    ld   scw_r256 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r256:
dt_a:
    ld   [s_r], ac
    beq  dt_e
    ld   34, ac
    ld   ac, [CUR_COL]
    ld   s_air & 0xFF, ac
    ld   ac, [R0]
    ld   s_air >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r257, [x]
    ld   LINK_HI, x
    ld   scw_r257 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r257:
    ld   ROOM_P >> 8, y
    ld   [s_r], x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r258, [x]
    ld   LINK_HI, x
    ld   scw_r258 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r258:
    ld   0x25, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r259, [x]
    ld   LINK_HI, x
    ld   scw_r259 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r259:
dt_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_warn - row 29 with the warning of the stage, red.  The rest of
; draw_msg.
work_tick:
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
    ld   [wk_l], ac
    sub  [wk_r], ac
    ld   ac, [wk_l]
    bcc  wt_z
    ld   [wk_h], ac             ; a borrow
    beq  wt_d
    dec
    ld   ac, [wk_h]
    ld   jb_tick >> 8, y
    jmp  jb_tick
wt_z:
    bne  wt_x
    ld   [wk_h], ac
    bne  wt_x
wt_d:
    clr  ac
    ld   ac, [cut_t]
    ld   LINK_LO, x             ; CALL sk_gain
    ld   scw_r264, [x]
    ld   LINK_HI, x
    ld   scw_r264 >> 8, [x]
    ld   sk_gain >> 8, y
    jmp  sk_gain
scw_r264:
    ld   LINK_LO, x             ; CALL cut_done
    ld   scw_r265, [x]
    ld   LINK_HI, x
    ld   scw_r265 >> 8, [x]
    ld   cut_done >> 8, y
    jmp  cut_done
scw_r265:
    ld   sc_leave >> 8, y
    jmp  sc_leave
wt_x:
    ld   jb_tick >> 8, y
    jmp  jb_tick

; jb_tick - the job's bar: a 16th more done each time the work left
; reaches JB_TH:JB_TL (then JB_B less); the message row drawn again and
; kept up.  The rest of work_tick

#addr 0x2E00
job_start:
    ld   JB_B >> 8, y
    ld   JB_B & 0xFF, x
    ld   ac, [y,x]
    ld   ac, [u0]
    shl
    shl
    shl
    shl
    ld   ac, [wk_l]
    ld   [u0], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wk_h]
    ld   ACT_PG, y
    ld   [s_t], ac
    add  TB_SKILL, x
    ld   [y,x], ac
    ld   ac, [wk_m]
    ld   ac, [u0]               ; the skills, shifted down
    clr  ac
    ld   ac, [u1]               ; the quarters, summed
    ld   ac, [u3]               ; how many
    ld   ac, [u4]               ; skill k
js_l:
    ld   [u0], ac
    and  1, ac
    beq  js_n
    ld   SK_LV >> 8, y
    ld   [u4], ac
    add  SK_LV & 0xFF, x
    ld   [y,x], ac
    shr  ac
    shr  ac
    add  [u1], ac
    ld   ac, [u1]
    ld   [u3], ac
    inc
    ld   ac, [u3]
js_n:
    ld   [u0], ac
    shr  ac
    ld   ac, [u0]
    ld   [u4], ac
    inc
    ld   ac, [u4]
    xor  5, ac
    bne  js_l
    ld   [u3], ac
    bne  js_d
    ld   SKILL_MAX >> 2, ac     ; no skill needed: full speed
    bra  js_r
js_d:
    clr  ac
    ld   ac, [u2]               ; the average: u1 / u3
js_q:
    ld   [u1], ac
    sub  [u3], ac
    bcs  js_a
    ld   ac, [u1]
    ld   [u2], ac
    inc
    ld   ac, [u2]
    bra  js_q
js_a:
    ld   [u2], ac
js_r:
    add  2, ac
    ld   ac, [wk_r]
    ld   [suit_on], ac
    beq  js_e
    ld   [wk_m], ac
    or   SK_SUIT, ac
    ld   ac, [wk_m]
    ld   SK_LV >> 8, y
    ld   (SK_LV & 0xFF) + 5, x
    ld   [y,x], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u1]
    ld   [wk_r], ac
    shr  ac
    add  [u1], ac
    ld   ac, [u1]               ; half the rate and the suit's eighth
    sub  [wk_r], ac
    bcc  js_e                   ; not over the rate
    ld   [u1], ac
    ld   ac, [wk_r]
js_e:
    ld   JB_B >> 8, y           ; the bar: none done, the next 16th at
    ld   JB_N & 0xFF, x         ; 15 JB_B of work left
    ld   0, [y,x]
    ld   JB_B & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [wk_l], ac
    sub  [u2], ac
    ld   JB_TL & 0xFF, x
    ld   ac, [y,x]
    ld   [wk_h], ac
    bcc  js_t
    dec
js_t:
    ld   JB_TH & 0xFF, x
    ld   ac, [y,x]
    ld   1, ac
    ld   ac, [cut_t]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; work_tick - a frame of the job: wk less wk_r.  Done: the skills it
; used gain (sk_gain), then cut_done
job_bar:
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
    ld   44, ac
    ld   ac, [CUR_COL]
    ld   JB_N >> 8, y
    ld   JB_N & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   JB_TAB >> 8, y
    add  JB_TAB & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [u0], ac
    add  (JB_TAB & 0xFF) + 17, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r266, [x]
    ld   LINK_HI, x
    ld   scw_r266 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r266:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; sk_gain - a job done: each skill it used (wk_m) gains 2 (120 - its
; level) of 256 toward the next level (SKILL_MAX at most).  A leaf.

#addr 0x2F00
jb_tick:
jt_l:
    ld   JB_N >> 8, y
    ld   JB_N & 0xFF, x
    ld   [y,x], ac
    xor  16, ac
    beq  jt_e
    ld   JB_TH & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   JB_TL & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [wk_h], ac
    sub  [u0], ac
    bcs  jt_y                   ; the high byte under: reached
    bne  jt_e                   ; over: not yet
    ld   [u1], ac
    sub  [wk_l], ac
    bcs  jt_e                   ; the low byte over: not yet
jt_y:
    ld   JB_N & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    ld   JB_B & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u1], ac
    sub  [u2], ac
    ld   JB_TL & 0xFF, x
    ld   ac, [y,x]
    ld   [u0], ac
    bcc  jt_m
    dec
jt_m:
    ld   JB_TH & 0xFF, x
    ld   ac, [y,x]
    ld   MSG_FRAMES, ac
    ld   ac, [msg_t]
    ld   [dirty], ac
    or   2, ac
    ld   ac, [dirty]
    bra  jt_l
jt_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; job_bar - after the message while a job runs: its bar, "[####----]
; 25%", from column 44 (JB_TAB by JB_N)
sk_gain:
    ld   [wk_m], ac
    ld   ac, [u0]
    clr  ac
    ld   ac, [u4]
sg_l:
    ld   [u0], ac
    and  1, ac
    beq  sg_n
    ld   SK_LV >> 8, y
    ld   [u4], ac
    add  SK_LV & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u1]               ; the level
    xor  SKILL_MAX, ac
    beq  sg_n
    ld   120, ac
    sub  [u1], ac
    shl
    ld   ac, [u2]               ; the gain
    ld   [u4], ac
    add  SK_PR & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u3]               ; the progress before
    add  [u2], ac
    ld   ac, [y,x]
    sub  [u3], ac               ; under it: round past 256, a level
    bcc  sg_n
    ld   [u4], ac
    add  SK_LV & 0xFF, x
    ld   [u1], ac
    inc
    ld   ac, [y,x]
sg_n:
    ld   [u0], ac
    shr  ac
    ld   ac, [u0]
    ld   [u4], ac
    inc
    ld   ac, [u4]
    xor  6, ac
    bne  sg_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; more_action - REPAIR, SKILLS, TAKE OFF SUIT, PUT ON SUIT (w3).  The
; rest of do_action
repair_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r267, [x]
    ld   LINK_HI, x
    ld   scw_r267 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r267:
    beq  rpa_far
    ld   [s_f], ac
    beq  rpa_e
    shl
    shl
    shl
    shl
    sub  [s_f], ac
    ld   LINK_LO, x             ; CALL job_start
    ld   scw_r268, [x]
    ld   LINK_HI, x
    ld   scw_r268 >> 8, [x]
    ld   job_start >> 8, y
    jmp  job_start
scw_r268:
    ld   3, ac
    ld   ac, [cut_m]
    ld   [s_x], ac
    ld   ac, [cut_x]
    ld   [s_y], ac
    ld   ac, [cut_y]
    ld   s_repair & 0xFF, ac
    ld   ac, [R0]
    ld   s_repair >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r269, [x]
    ld   LINK_HI, x
    ld   scw_r269 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r269:
rpa_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
rpa_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r270, [x]
    ld   LINK_HI, x
    ld   scw_r270 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r270:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; repair_done - the cell cut_done read (map_get) has no damage now; a
; wall or door: the rooms again.  The rest of cut_done

#addr 0x3000
repair_done:
    ld   [a_pg], ac             ; the flag byte, two pages up
    add  2, ac
    ld   ac, y
    ld   [a_ix], x
    ld   [y,x], ac
    and  0xF0, ac
    ld   ac, [y,x]
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_STRUCT, ac
    beq  rd_m
    ld   1, ac
    ld   ac, [rb_go]
rd_m:
    ld   s_repdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_repdone >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r271, [x]
    ld   LINK_HI, x
    ld   scw_r271 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r271:
    ld   work_end >> 8, y
    jmp  work_end

; dyn_rep - REPAIR for a damaged part, wall, deck or door.  The end of
; dyn_acts
player_acts:
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
    ld   A_SKILLS, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r273, [x]
    ld   LINK_HI, x
    ld   scw_r273 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r273:
    ld   [suit_on], ac
    beq  pa_1
    ld   A_SUITOFF, ac
    bra  pa_a
pa_1:
    ld   LINK_LO, x             ; CALL suit_slot
    ld   scw_r274, [x]
    ld   LINK_HI, x
    ld   scw_r274 >> 8, [x]
    ld   suit_slot >> 8, y
    jmp  suit_slot
scw_r274:
    beq  pa_e
    ld   A_SUITON, ac
pa_a:
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r275, [x]
    ld   LINK_HI, x
    ld   scw_r275 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r275:
pa_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; suit_slot - AC = the address of the carry slot that holds the suit, 0
; none.  A leaf.
suit_slot:
    ld   [cl_t], ac
    xor  T_SUIT, ac
    bne  ss_1x
    ld   cl_t, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ss_1x:
    ld   [cr_t], ac
    xor  T_SUIT, ac
    bne  ss_2x
    ld   cr_t, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ss_2x:
    ld   [cb_t], ac
    xor  T_SUIT, ac
    bne  ss_3x
    ld   cb_t, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ss_3x:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; suit_action - TAKE OFF SUIT: into the first free carry slot; PUT ON
; SUIT: out of its slot.  The rest of do_action
nosuit_tick:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r281, [x]
    ld   LINK_HI, x
    ld   scw_r281 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r281:
    ld   ROOM_P >> 8, y
    ld   [c_r], x
    ld   [y,x], ac
    sub  BREATHE_P, ac
    bcc  nt_ok
    ld   ss_4 >> 8, y
    jmp  ss_4
nt_ok:
    clr  ac
    ld   ac, [col_t]
    ld   ss_n >> 8, y
    jmp  ss_n

; ts_seal - tputs' 02: a wall's or door's seal for damage step s_f
; (ROOM_PG + x20 + step, high bytes + x30).  Back into tputs

#addr 0x3100
suit_action:
    ld   [w3], ac
    xor  A_SUITOFF, ac
    bne  su_on
    ld   LINK_LO, x             ; CALL free_slot
    ld   scw_r276, [x]
    ld   LINK_HI, x
    ld   scw_r276 >> 8, [x]
    ld   free_slot >> 8, y
    jmp  free_slot
scw_r276:
    beq  su_full
    ld   ac, [u0]
    ld   ac, x
    ld   T_SUIT, ac
    ld   ac, [x]
    ld   [u0], ac
    add  3, x
    clr  ac
    ld   ac, [x]
    ld   ac, [suit_on]
    ld   s_suitoff & 0xFF, ac
    ld   ac, [R0]
    ld   s_suitoff >> 8, ac
    bra  su_m
su_on:
    ld   LINK_LO, x             ; CALL suit_slot
    ld   scw_r277, [x]
    ld   LINK_HI, x
    ld   scw_r277 >> 8, [x]
    ld   suit_slot >> 8, y
    jmp  suit_slot
scw_r277:
    beq  su_e
    ld   ac, [u0]
    ld   ac, x
    clr  ac
    ld   ac, [x]
    ld   [u0], ac
    add  3, x
    clr  ac
    ld   ac, [x]
    ld   1, ac
    ld   ac, [suit_on]
    ld   s_suiton & 0xFF, ac
    ld   ac, [R0]
    ld   s_suiton >> 8, ac
su_m:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r278, [x]
    ld   LINK_HI, x
    ld   scw_r278 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r278:
    ld   [p_x], ac              ; the player drawn again, in or out of it
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r279, [x]
    ld   LINK_HI, x
    ld   scw_r279 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r279:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
su_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
su_full:
    ld   s_full & 0xFF, ac
    ld   ac, [R0]
    ld   s_full >> 8, ac
    bra  su_m

; skills_action - SKILLS: the levels into SK_MSG (at SK_POS, two digits,
; a space for a leading 0) on the message row.  The rest of do_action
skills_action:
    clr  ac
    ld   ac, [u4]
sa_l:
    ld   SK_LV >> 8, y
    ld   [u4], ac
    add  SK_LV & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u1]               ; the ones
    ld   0x20, ac
    ld   ac, [u2]               ; the tens
sa_t:
    ld   [u1], ac
    sub  10, ac
    bcs  sa_p
    ld   ac, [u1]
    ld   [u2], ac
    xor  0x20, ac
    bne  sa_i
    ld   0x30, ac
    ld   ac, [u2]
sa_i:
    ld   [u2], ac
    inc
    ld   ac, [u2]
    bra  sa_t
sa_p:
    ld   SK_POS >> 8, y
    ld   [u4], ac
    add  SK_POS & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u3]
    ld   ac, x
    ld   SK_MSG >> 8, y
    ld   [u2], ac
    ld   ac, [y,x]
    ld   [u3], ac
    add  1, x
    ld   [u1], ac
    add  0x30, ac
    ld   ac, [y,x]
    ld   [u4], ac
    inc
    ld   ac, [u4]
    xor  6, ac
    bne  sa_l
    ld   SK_MSG & 0xFF, ac
    ld   ac, [R0]
    ld   SK_MSG >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r280, [x]
    ld   LINK_HI, x
    ld   scw_r280 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r280:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nosuit_tick - second_tick without the suit: the room's air or nothing
; (collapsing, stage_set's ss_4); the suit keeps its O2.  The rest of
; second_tick

#addr 0x3200
cell_extra:
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
    ld   [dc_t], ac
    xor  T_PLAYER, ac
    bne  ce_c
    ld   [suit_on], ac
    bne  ce_e
    ld   PL_NOSUIT >> 8, ac
    ld   ac, [dc_ap]
    ld   PL_NOSUIT & 0xFF, ac
    ld   ac, [dc_ai]
    ld   LINK_LO, x             ; CALL draw_cell_at
    ld   scw_r282, [x]
    ld   LINK_HI, x
    ld   scw_r282 >> 8, [x]
    ld   draw_cell_at >> 8, y
    jmp  draw_cell_at
scw_r282:
    ld   sc_leave >> 8, y
    jmp  sc_leave
ce_c:
    ld   LINK_LO, x             ; CALL crate_mark
    ld   scw_r283, [x]
    ld   LINK_HI, x
    ld   scw_r283 >> 8, [x]
    ld   crate_mark >> 8, y
    jmp  crate_mark
scw_r283:
ce_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; crate_mark - a loose part on screen cell dc_cx, dc_cy (map_get's c_t,
; c_b) gets a crate's frame, brown.  A leaf.
crate_mark:
    ld   [c_b], ac
    bne  cm_e
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    beq  cm_e
    ld   [dc_cx], ac
    shl
    shl
    shl
    add  0x61, ac
    ld   ac, [dc_sp]
    ld   [dc_cy], ac
    sub  7, ac
    blt  ca_lo45
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    sub  223, ac
    bra  ca_go45
ca_lo45:
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    add  32, ac
ca_go45:
    ld   ac, [dc_base]
    ld   [dc_sp], ac
    ld   ac, [u0]
    ld   4, ac
    ld   ac, [dc_c]
cm_tb:
    ld   [u0], y                ; the top and bottom line pairs
    ld   [dc_base], x
    ld   CRATE_COL * 0x11, [y,x]
    ld   [dc_base], ac
    add  30, ac
    ld   ac, x
    ld   CRATE_COL * 0x11, [y,x]
    ld   [u0], ac
    add  2, ac
    ld   ac, [u0]
    ld   [dc_c], ac
    dec
    ld   ac, [dc_c]
    bne  cm_tb
    ld   [dc_base], ac          ; the sides
    add  2, ac
    ld   ac, [dc_so]
    ld   14, ac
    ld   ac, [dc_n]
cm_s:
    ld   [dc_sp], y
    ld   [dc_so], x
    ld   [y,x], ac
    and  0xF0, ac
    or   CRATE_COL, ac
    ld   ac, [y,x]
    ld   [dc_sp], ac
    add  6, ac
    ld   ac, y
    ld   [y,x], ac
    and  0x0F, ac
    or   CRATE_COL << 4, ac
    ld   ac, [y,x]
    ld   [dc_so], ac
    add  2, ac
    ld   ac, [dc_so]
    ld   [dc_n], ac
    dec
    ld   ac, [dc_n]
    bne  cm_s
cm_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; scrap_data.masm - generated by gen_scrap.py, do not edit by hand
; the art, tables and strings of scrap.masm (included at its end)


#addr 0x3300
zi_0_0:
    #d "VACUUM.  NO AIR, NO FLOOR.", 0x00
zi_0_1:
    #d "LAY A DECK PLATE HERE TO BUILD ON IT", 0x00
zi_0_2:
    #d "SPACEWALK: YOUR SUIT AIR ONLY", 0x00
zi_1_0:
    #d "VACUUM.  NO AIR, NO FLOOR.", 0x00
zi_1_1:
    #d "LAY A DECK PLATE HERE TO BUILD ON IT", 0x00
zi_1_2:
    #d "SPACEWALK: YOUR SUIT AIR ONLY", 0x00
zi_2_0:
    #d "STEEL DECK PLATE", 0x00
zi_2_1:
    #d "WALKABLE", 0x00


#addr 0x3400
DOOR_TAB:
    #d8 0x70, 0x68, 0x6C, 0x6C, 0x84, 0x84, 0x80, 0x84
    #d8 0x88, 0x8C, 0x7C, 0x7C, 0x94, 0x94, 0x94, 0x94
    #d8 0x98, 0x9C, 0xA0, 0x98, 0x9C, 0x9C, 0xA0, 0xBC
    #d8 0xB4, 0xB4, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 172, 205, 202, 206, 138, 142, 230, 228
    #d8 229, 227, 241, 248, 13, 14, 17, 24
    #d8 38, 36, 44, 143, 142, 228, 236, 26
    #d8 74, 78, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 4, 1, 2, 3, 7, 3, 6, 7
    #d8 8, 5, 9, 10, 11, 11, 11, 11
    #d8 3, 3, 3, 14, 3, 15, 16, 18
    #d8 17, 3, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 5, 2, 3, 4, 3, 8, 3, 3
    #d8 3, 3, 11, 11, 3, 3, 12, 13
    #d8 14, 15, 16, 15, 16, 17, 18, 0
    #d8 3, 18, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

ROOM_TAB:
    #d8 zb_0 & 0xFF, zb_1 & 0xFF, zb_2 & 0xFF, zb_3 & 0xFF, zb_4 & 0xFF, zb_5 & 0xFF, zb_6 & 0xFF, zb_7 & 0xFF
    #d8 zb_8 & 0xFF, zb_9 & 0xFF, zb_10 & 0xFF, zb_11 & 0xFF, zb_12 & 0xFF, zb_13 & 0xFF, zb_14 & 0xFF, zb_15 & 0xFF
    #d8 zb_0 >> 8, zb_1 >> 8, zb_2 >> 8, zb_3 >> 8, zb_4 >> 8, zb_5 >> 8, zb_6 >> 8, zb_7 >> 8
    #d8 zb_8 >> 8, zb_9 >> 8, zb_10 >> 8, zb_11 >> 8, zb_12 >> 8, zb_13 >> 8, zb_14 >> 8, zb_15 >> 8
    #d8 zs_0 & 0xFF, zs_1 & 0xFF, zs_2 & 0xFF, zs_3 & 0xFF, zs_4 & 0xFF, zs_5 & 0xFF, zs_6 & 0xFF, zs_7 & 0xFF
    #d8 zs_8 & 0xFF, zs_9 & 0xFF, zs_10 & 0xFF, zs_11 & 0xFF, zs_12 & 0xFF, zs_13 & 0xFF, zs_14 & 0xFF, zs_15 & 0xFF
    #d8 zs_0 >> 8, zs_1 >> 8, zs_2 >> 8, zs_3 >> 8, zs_4 >> 8, zs_5 >> 8, zs_6 >> 8, zs_7 >> 8
    #d8 zs_8 >> 8, zs_9 >> 8, zs_10 >> 8, zs_11 >> 8, zs_12 >> 8, zs_13 >> 8, zs_14 >> 8, zs_15 >> 8
    #d8 0, 100, 100, 100, 100, 100, 100, 100
    #d8 100, 100, 100, 100, 100, 100, 100, 100
    #d8 100, 100, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 1, 1, 1, 1, 1, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 18, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

ACT_TAB:
    #d8 4, 3, 0, 0, 4, 3, 0, 0
    #d8 4, 3, 0, 0, 3, 0, 0, 0
    #d8 1, 11, 3, 0, 2, 11, 3, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 4, 3, 0, 0, 4, 3, 0, 0
    #d8 4, 3, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 4, 3, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, za_1 & 0xFF, za_2 & 0xFF, za_3 & 0xFF, za_4 & 0xFF, za_5 & 0xFF, za_6 & 0xFF, za_7 & 0xFF
    #d8 za_8 & 0xFF, za_9 & 0xFF, za_10 & 0xFF, za_11 & 0xFF, za_12 & 0xFF, za_13 & 0xFF, za_14 & 0xFF, za_15 & 0xFF
    #d8 za_16 & 0xFF, za_17 & 0xFF, za_18 & 0xFF, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, za_1 >> 8, za_2 >> 8, za_3 >> 8, za_4 >> 8, za_5 >> 8, za_6 >> 8, za_7 >> 8
    #d8 za_8 >> 8, za_9 >> 8, za_10 >> 8, za_11 >> 8, za_12 >> 8, za_13 >> 8, za_14 >> 8, za_15 >> 8
    #d8 za_16 >> 8, za_17 >> 8, za_18 >> 8, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 1, 1, 17, 17, 16, 6
    #d8 2, 1, 1, 10, 1, 9, 2, 1
    #d8 17, 1, 17, 16, 18, 0, 16, 2
    #d8 1, 17, 1, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

TAB:
    #d8 97, 97, 19, 50, 50, 51, 14, 2
    #d8 14, 6, 14, 14, 14, 34, 3, 3
    #d8 35, 6, 34, 14, 14, 97, 14, 6
    #d8 14, 14, 6, 0, 0, 0, 0, 0
    #d8 zn_0 & 0xFF, zn_1 & 0xFF, zn_2 & 0xFF, zn_3 & 0xFF, zn_4 & 0xFF, zn_5 & 0xFF, zn_6 & 0xFF, zn_7 & 0xFF
    #d8 zn_8 & 0xFF, zn_9 & 0xFF, zn_10 & 0xFF, zn_11 & 0xFF, zn_12 & 0xFF, zn_13 & 0xFF, zn_14 & 0xFF, zn_15 & 0xFF
    #d8 zn_16 & 0xFF, zn_17 & 0xFF, zn_18 & 0xFF, zn_19 & 0xFF, zn_20 & 0xFF, zn_21 & 0xFF, zn_22 & 0xFF, zn_23 & 0xFF
    #d8 zn_24 & 0xFF, zn_25 & 0xFF, zn_26 & 0xFF, zn_27 & 0xFF, 0, 0, 0, 0
    #d8 zn_0 >> 8, zn_1 >> 8, zn_2 >> 8, zn_3 >> 8, zn_4 >> 8, zn_5 >> 8, zn_6 >> 8, zn_7 >> 8
    #d8 zn_8 >> 8, zn_9 >> 8, zn_10 >> 8, zn_11 >> 8, zn_12 >> 8, zn_13 >> 8, zn_14 >> 8, zn_15 >> 8
    #d8 zn_16 >> 8, zn_17 >> 8, zn_18 >> 8, zn_19 >> 8, zn_20 >> 8, zn_21 >> 8, zn_22 >> 8, zn_23 >> 8
    #d8 zn_24 >> 8, zn_25 >> 8, zn_26 >> 8, zn_27 >> 8, 0, 0, 0, 0
    #d8 zx_0 & 0xFF, zx_1 & 0xFF, zx_2 & 0xFF, zx_3 & 0xFF, zx_4 & 0xFF, zx_5 & 0xFF, zx_6 & 0xFF, zx_7 & 0xFF
    #d8 zx_8 & 0xFF, zx_9 & 0xFF, zx_10 & 0xFF, zx_11 & 0xFF, zx_12 & 0xFF, zx_13 & 0xFF, zx_14 & 0xFF, zx_15 & 0xFF
    #d8 zx_16 & 0xFF, zx_17 & 0xFF, zx_18 & 0xFF, zx_19 & 0xFF, zx_20 & 0xFF, zx_21 & 0xFF, zx_22 & 0xFF, zx_23 & 0xFF
    #d8 zx_24 & 0xFF, zx_25 & 0xFF, zx_26 & 0xFF, zx_27 & 0xFF, 0, 0, 0, 0
    #d8 zx_0 >> 8, zx_1 >> 8, zx_2 >> 8, zx_3 >> 8, zx_4 >> 8, zx_5 >> 8, zx_6 >> 8, zx_7 >> 8
    #d8 zx_8 >> 8, zx_9 >> 8, zx_10 >> 8, zx_11 >> 8, zx_12 >> 8, zx_13 >> 8, zx_14 >> 8, zx_15 >> 8
    #d8 zx_16 >> 8, zx_17 >> 8, zx_18 >> 8, zx_19 >> 8, zx_20 >> 8, zx_21 >> 8, zx_22 >> 8, zx_23 >> 8
    #d8 zx_24 >> 8, zx_25 >> 8, zx_26 >> 8, zx_27 >> 8, 0, 0, 0, 0
    #d8 zd_0 & 0xFF, zd_1 & 0xFF, zd_2 & 0xFF, zd_3 & 0xFF, zd_4 & 0xFF, zd_5 & 0xFF, zd_6 & 0xFF, zd_7 & 0xFF
    #d8 zd_8 & 0xFF, zd_9 & 0xFF, zd_10 & 0xFF, zd_11 & 0xFF, zd_12 & 0xFF, zd_13 & 0xFF, zd_14 & 0xFF, zd_15 & 0xFF
    #d8 zd_0 >> 8, zd_1 >> 8, zd_2 >> 8, zd_3 >> 8, zd_4 >> 8, zd_5 >> 8, zd_6 >> 8, zd_7 >> 8
    #d8 zd_8 >> 8, zd_9 >> 8, zd_10 >> 8, zd_11 >> 8, zd_12 >> 8, zd_13 >> 8, zd_14 >> 8, zd_15 >> 8
    #d8 zw_0 & 0xFF, zw_1 & 0xFF, zw_2 & 0xFF, zw_3 & 0xFF, zw_4 & 0xFF, zw_5 & 0xFF, zw_6 & 0xFF, zw_7 & 0xFF
    #d8 zw_8 & 0xFF, zw_9 & 0xFF, zw_10 & 0xFF, zw_11 & 0xFF, zw_12 & 0xFF, zw_13 & 0xFF, zw_14 & 0xFF, zw_15 & 0xFF
    #d8 zw_0 >> 8, zw_1 >> 8, zw_2 >> 8, zw_3 >> 8, zw_4 >> 8, zw_5 >> 8, zw_6 >> 8, zw_7 >> 8
    #d8 zw_8 >> 8, zw_9 >> 8, zw_10 >> 8, zw_11 >> 8, zw_12 >> 8, zw_13 >> 8, zw_14 >> 8, zw_15 >> 8
    #d8 0, 0, 0, 0, 0, 0, 20, 250
    #d8 30, 15, 5, 60, 6, 40, 0, 0
    #d8 0, 0, 50, 25, 35, 0, 8, 12
    #d8 3, 8, 2, 0, 0, 0, 0, 0

INFO_TAB:
    #d8 zi_0_0 & 0xFF, zi_0_1 & 0xFF, zi_0_2 & 0xFF, 0, zi_1_0 & 0xFF, zi_1_1 & 0xFF, zi_1_2 & 0xFF, 0
    #d8 zi_2_0 & 0xFF, zi_2_1 & 0xFF, zi_2_2 & 0xFF, zi_2_3 & 0xFF, zi_3_0 & 0xFF, zi_3_1 & 0xFF, zi_3_2 & 0xFF, zi_3_3 & 0xFF
    #d8 zi_4_0 & 0xFF, zi_4_1 & 0xFF, zi_4_2 & 0xFF, zi_4_3 & 0xFF, zi_5_0 & 0xFF, zi_5_1 & 0xFF, zi_5_2 & 0xFF, zi_5_3 & 0xFF
    #d8 zi_6_0 & 0xFF, zi_6_1 & 0xFF, zi_6_2 & 0xFF, zi_6_3 & 0xFF, zi_7_0 & 0xFF, zi_7_1 & 0xFF, zi_7_2 & 0xFF, zi_7_3 & 0xFF
    #d8 zi_8_0 & 0xFF, zi_8_1 & 0xFF, zi_8_2 & 0xFF, zi_8_3 & 0xFF, zi_9_0 & 0xFF, zi_9_1 & 0xFF, zi_9_2 & 0xFF, zi_9_3 & 0xFF
    #d8 zi_10_0 & 0xFF, zi_10_1 & 0xFF, zi_10_2 & 0xFF, zi_10_3 & 0xFF, zi_11_0 & 0xFF, zi_11_1 & 0xFF, zi_11_2 & 0xFF, zi_11_3 & 0xFF
    #d8 zi_12_0 & 0xFF, zi_12_1 & 0xFF, zi_12_2 & 0xFF, zi_12_3 & 0xFF, zi_13_0 & 0xFF, zi_13_1 & 0xFF, zi_13_2 & 0xFF, zi_13_3 & 0xFF
    #d8 zi_14_0 & 0xFF, zi_14_1 & 0xFF, zi_14_2 & 0xFF, zi_14_3 & 0xFF, zi_15_0 & 0xFF, zi_15_1 & 0xFF, zi_15_2 & 0xFF, zi_15_3 & 0xFF
    #d8 zi_16_0 & 0xFF, zi_16_1 & 0xFF, zi_16_2 & 0xFF, zi_16_3 & 0xFF, zi_17_0 & 0xFF, zi_17_1 & 0xFF, zi_17_2 & 0xFF, zi_17_3 & 0xFF
    #d8 zi_18_0 & 0xFF, zi_18_1 & 0xFF, zi_18_2 & 0xFF, zi_18_3 & 0xFF, zi_19_0 & 0xFF, zi_19_1 & 0xFF, zi_19_2 & 0xFF, zi_19_3 & 0xFF
    #d8 zi_20_0 & 0xFF, zi_20_1 & 0xFF, zi_20_2 & 0xFF, zi_20_3 & 0xFF, zi_21_0 & 0xFF, zi_21_1 & 0xFF, zi_21_2 & 0xFF, 0
    #d8 zi_22_0 & 0xFF, zi_22_1 & 0xFF, zi_22_2 & 0xFF, zi_22_3 & 0xFF, zi_23_0 & 0xFF, zi_23_1 & 0xFF, zi_23_2 & 0xFF, zi_23_3 & 0xFF
    #d8 zi_24_0 & 0xFF, zi_24_1 & 0xFF, zi_24_2 & 0xFF, zi_24_3 & 0xFF, zi_25_0 & 0xFF, zi_25_1 & 0xFF, zi_25_2 & 0xFF, zi_25_3 & 0xFF
    #d8 zi_26_0 & 0xFF, zi_26_1 & 0xFF, zi_26_2 & 0xFF, zi_26_3 & 0xFF, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zi_0_0 >> 8, zi_0_1 >> 8, zi_0_2 >> 8, 0, zi_1_0 >> 8, zi_1_1 >> 8, zi_1_2 >> 8, 0
    #d8 zi_2_0 >> 8, zi_2_1 >> 8, zi_2_2 >> 8, zi_2_3 >> 8, zi_3_0 >> 8, zi_3_1 >> 8, zi_3_2 >> 8, zi_3_3 >> 8
    #d8 zi_4_0 >> 8, zi_4_1 >> 8, zi_4_2 >> 8, zi_4_3 >> 8, zi_5_0 >> 8, zi_5_1 >> 8, zi_5_2 >> 8, zi_5_3 >> 8
    #d8 zi_6_0 >> 8, zi_6_1 >> 8, zi_6_2 >> 8, zi_6_3 >> 8, zi_7_0 >> 8, zi_7_1 >> 8, zi_7_2 >> 8, zi_7_3 >> 8
    #d8 zi_8_0 >> 8, zi_8_1 >> 8, zi_8_2 >> 8, zi_8_3 >> 8, zi_9_0 >> 8, zi_9_1 >> 8, zi_9_2 >> 8, zi_9_3 >> 8
    #d8 zi_10_0 >> 8, zi_10_1 >> 8, zi_10_2 >> 8, zi_10_3 >> 8, zi_11_0 >> 8, zi_11_1 >> 8, zi_11_2 >> 8, zi_11_3 >> 8
    #d8 zi_12_0 >> 8, zi_12_1 >> 8, zi_12_2 >> 8, zi_12_3 >> 8, zi_13_0 >> 8, zi_13_1 >> 8, zi_13_2 >> 8, zi_13_3 >> 8
    #d8 zi_14_0 >> 8, zi_14_1 >> 8, zi_14_2 >> 8, zi_14_3 >> 8, zi_15_0 >> 8, zi_15_1 >> 8, zi_15_2 >> 8, zi_15_3 >> 8
    #d8 zi_16_0 >> 8, zi_16_1 >> 8, zi_16_2 >> 8, zi_16_3 >> 8, zi_17_0 >> 8, zi_17_1 >> 8, zi_17_2 >> 8, zi_17_3 >> 8
    #d8 zi_18_0 >> 8, zi_18_1 >> 8, zi_18_2 >> 8, zi_18_3 >> 8, zi_19_0 >> 8, zi_19_1 >> 8, zi_19_2 >> 8, zi_19_3 >> 8
    #d8 zi_20_0 >> 8, zi_20_1 >> 8, zi_20_2 >> 8, zi_20_3 >> 8, zi_21_0 >> 8, zi_21_1 >> 8, zi_21_2 >> 8, 0
    #d8 zi_22_0 >> 8, zi_22_1 >> 8, zi_22_2 >> 8, zi_22_3 >> 8, zi_23_0 >> 8, zi_23_1 >> 8, zi_23_2 >> 8, zi_23_3 >> 8
    #d8 zi_24_0 >> 8, zi_24_1 >> 8, zi_24_2 >> 8, zi_24_3 >> 8, zi_25_0 >> 8, zi_25_1 >> 8, zi_25_2 >> 8, zi_25_3 >> 8
    #d8 zi_26_0 >> 8, zi_26_1 >> 8, zi_26_2 >> 8, zi_26_3 >> 8, 0, 0, 0, 0
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
; SUIT
    #d8 0x77, 0x77, 0xA7, 0xA7, 0xA7, 0x77, 0xB7, 0xAB, 0xAB, 0xAB, 0xB7, 0x77, 0xA7, 0xA7, 0xB7, 0x77
    #d8 0x77, 0xAA, 0x1A, 0x11, 0x1A, 0xAA, 0xAA, 0xAA, 0x8A, 0xAA, 0xAA, 0xAA, 0x7A, 0x7A, 0x7B, 0x77
    #d8 0x77, 0xAA, 0xA1, 0x11, 0xA1, 0xAA, 0xAA, 0xAA, 0xA8, 0xAA, 0xAA, 0xAA, 0xA7, 0xA7, 0xB7, 0x77
    #d8 0x77, 0x77, 0x7A, 0x7A, 0x7A, 0x77, 0x7B, 0xBA, 0xBA, 0xBA, 0x7B, 0x77, 0x7A, 0x7A, 0x7B, 0x77
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
; O2E
    #d8 0x77, 0x77, 0xB7, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0xBB, 0xBB, 0xB7, 0x77, 0x77
    #d8 0xB7, 0xAB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0x77
    #d8 0x7B, 0xBA, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0x77
    #d8 0x77, 0x77, 0x7B, 0xBB, 0xBB, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xB0, 0xBB, 0x7B, 0x77, 0x77
; CUTTER
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0xB7, 0xB7, 0xB7, 0x77, 0x77, 0x00
    #d8 0x77, 0xE7, 0xE7, 0xEB, 0xBB, 0xAB, 0xBB, 0xBB, 0x4B, 0xBB, 0x66, 0x66, 0x66, 0xBB, 0x77, 0x00
    #d8 0x77, 0x77, 0x77, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0xB6, 0xB6, 0xB6, 0x7B, 0x77, 0x00
    #d8 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x00

; PANEL
    #d8 0x77, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0x77, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0x77, 0x00
    #d8 0x77, 0xBB, 0xBA, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0xBA, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x77, 0x00
    #d8 0x77, 0xBB, 0xBB, 0xBB, 0x7B, 0xBB, 0xBB, 0x77, 0xBB, 0xBB, 0xBB, 0xB7, 0xBB, 0xBB, 0x77, 0x00
    #d8 0x07, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0xB7, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x07, 0x00
; DOORK
    #d8 0x77, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0x77, 0x77, 0x00
    #d8 0x77, 0xBB, 0x66, 0xD6, 0x66, 0x0E, 0xE0, 0x0E, 0x66, 0xD6, 0x66, 0x66, 0xBB, 0x77, 0x77, 0x00
    #d8 0x77, 0xBB, 0x66, 0xD6, 0x66, 0x0E, 0xE0, 0x0E, 0x66, 0xD6, 0x66, 0x66, 0xBB, 0x77, 0x77, 0x00
    #d8 0x07, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x07, 0x07, 0x00
; PLATE
    #d8 0x11, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0x71, 0xB1, 0x11
    #d8 0x11, 0x77, 0x7B, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x7B, 0x77, 0xBB, 0x11
    #d8 0x11, 0x77, 0xB7, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0xB7, 0x77, 0xBB, 0x11
    #d8 0x11, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xBB, 0x11
; PLAYER
    #d8 0x77, 0x77, 0xA7, 0xA7, 0xA7, 0x77, 0xB7, 0xAB, 0xAB, 0xAB, 0xB7, 0x77, 0xA7, 0xA7, 0xB7, 0x77
    #d8 0x77, 0xAA, 0x8A, 0x88, 0x8A, 0xAA, 0xAA, 0xAA, 0xEA, 0xAA, 0xAA, 0xAA, 0x7A, 0x7A, 0x7B, 0x77
    #d8 0x77, 0xAA, 0xA8, 0x88, 0xA8, 0xAA, 0xAA, 0xAA, 0xAE, 0xAA, 0xAA, 0xAA, 0xA7, 0xA7, 0xB7, 0x77
    #d8 0x77, 0x77, 0x7A, 0x7A, 0x7A, 0x77, 0x7B, 0xBA, 0xBA, 0xBA, 0x7B, 0x77, 0x7A, 0x7A, 0x7B, 0x77


#overlay 0xC000
zi_2_2:
    #d "TAKEN UP, IT LEAVES OPEN SPACE", 0x00
zi_2_3:
    #d "SKILL: MECHANICAL", 0x00
zi_3_0:
    #d "STEEL BULKHEAD, LEAKS FROM 50% DAMAGE", 0x00
zi_3_1:
    #d 0x02, 0x00
zi_3_2:
    #d "UNINSTALL IT (IN A WRECK: A CUTTER)", 0x00
zi_3_3:
    #d "SKILL: MECHANICAL", 0x00
zi_4_0:
    #d "PRESSURE DOOR, LEAKS FROM 50% DAMAGE", 0x00
zi_4_1:
    #d 0x02, 0x00
zi_4_2:
    #d "CLOSES BEHIND YOU UNLESS HELD OPEN", 0x00


#overlay 0xC200
zi_4_3:
    #d "SKILLS: MECHANICAL, HYDRAULICS", 0x00
zi_5_0:
    #d "PRESSURE DOOR, OPEN", 0x00
zi_5_1:
    #d 0x02, 0x00
zi_5_2:
    #d "CLOSES BEHIND YOU UNLESS HELD OPEN", 0x00
zi_5_3:
    #d "SKILLS: MECHANICAL, HYDRAULICS", 0x00
zi_6_0:
    #d "CAPACITY 120 L, FULL", 0x00
zi_6_1:
    #d 0x01, 0x00
zi_6_2:
    #d "HEAVY.  SKILL: HYDRAULICS", 0x00
zi_6_3:
    #d "REFILLS A SUIT ONCE (LESS IF DAMAGED)", 0x00
zi_7_0:
    #d "FUSION CORE, 40 KW", 0x00
zi_7_1:
    #d 0x01, 0x00


#overlay 0xC400
zi_7_2:
    #d "TOO HEAVY TO CARRY WHOLE", 0x00
zi_7_3:
    #d "SKILLS: NUCLEAR, ELECTRICAL", 0x00
zi_8_0:
    #d "STORAGE CELL, 8 KWH", 0x00
zi_8_1:
    #d 0x01, 0x00
zi_8_2:
    #d "HEAVY.  SKILL: ELECTRICAL", 0x00
zi_8_3:
    #d "INSTALLED ON THE TUG: CHARGES YOUR SUIT", 0x00
zi_9_0:
    #d "SEALED CARGO CRATE", 0x00
zi_9_1:
    #d "CONTENTS UNKNOWN", 0x00
zi_9_2:
    #d "OPEN IT TO SEE (LATER PHASE)", 0x00
zi_9_3:
    #d "SKILL: MECHANICAL", 0x00
zi_10_0:
    #d "CREW BUNK", 0x00
zi_10_1:
    #d 0x01, 0x00


#overlay 0xC600
zi_10_2:
    #d "LIGHT SCRAP", 0x00
zi_10_3:
    #d "SKILL: MECHANICAL", 0x00
zi_11_0:
    #d "FLIGHT CONSOLE", 0x00
zi_11_1:
    #d 0x01, 0x00
zi_11_2:
    #d "HOLDS THE SHIP LOG (LATER PHASE)", 0x00
zi_11_3:
    #d "SKILLS: COMPUTERS, ELECTRICAL", 0x00
zi_12_0:
    #d "STEEL LOCKER, 4 SLOTS", 0x00
zi_12_1:
    #d 0x01, 0x00
zi_12_2:
    #d "MAY HOLD GEAR (LATER PHASE)", 0x00
zi_12_3:
    #d "SKILL: MECHANICAL", 0x00
zi_13_0:
    #d "WALL TURRET, ARC TYPE", 0x00
zi_13_1:
    #d 0x01, 0x00
zi_13_2:
    #d "DORMANT - NO POWER", 0x00


#overlay 0xC800
zi_13_3:
    #d "SKILLS: COMPUTERS, MECHANICAL", 0x00
zi_14_0:
    #d "CONDUIT UNDER THE DECK", 0x00
zi_14_1:
    #d 0x01, 0x00
zi_14_2:
    #d "CARRIES POWER BETWEEN PARTS", 0x00
zi_14_3:
    #d "SKILL: ELECTRICAL", 0x00
zi_15_0:
    #d "DECK PLATE IN VACUUM", 0x00
zi_15_1:
    #d "THIS ROOM HAS LOST ITS AIR", 0x00
zi_15_2:
    #d "YOUR SUIT AIR ONLY", 0x00
zi_15_3:
    #d "SKILL: MECHANICAL", 0x00
zi_16_0:
    #d "DOCKING AIRLOCK", 0x00
zi_16_1:
    #d 0x01, 0x00
zi_16_2:
    #d "JOINS THE TUG TO THE WRECK", 0x00


#overlay 0xCA00
zi_16_3:
    #d "SKILLS: MECHANICAL, HYDRAULICS", 0x00
zi_17_0:
    #d "MK1 WORK SUIT, 90 L OF O2", 0x00
zi_17_1:
    #d 0x01, 0x00
zi_17_2:
    #d "PUT IT ON: HOVER YOURSELF, PUT ON SUIT", 0x00
zi_17_3:
    #d "SKILL: MECHANICAL", 0x00
zi_18_0:
    #d "MAIN THRUSTER, 2 KN", 0x00
zi_18_1:
    #d 0x01, 0x00
zi_18_2:
    #d "BOLTED TO THE HULL", 0x00
zi_18_3:
    #d "SKILLS: MECHANICAL, HYDRAULICS", 0x00
zi_19_0:
    #d "FUEL TANK, 400 L", 0x00
zi_19_1:
    #d 0x01, 0x00
zi_19_2:
    #d "HEAVY: TAKES ONE CARRY SLOT", 0x00


#overlay 0xCC00
zi_19_3:
    #d "SKILL: HYDRAULICS", 0x00
zi_20_0:
    #d "CO2 SCRUBBER", 0x00
zi_20_1:
    #d 0x01, 0x00
zi_20_2:
    #d "WITH AN O2 TANK INSTALLED: AIR", 0x00
zi_20_3:
    #d "SKILLS: HYDRAULICS, ELECTRICAL", 0x00
zi_21_0:
    #d "A HOLE IN THE HULL", 0x00
zi_21_1:
    #d "AIR ESCAPES THROUGH HERE", 0x00
zi_21_2:
    #d "YOU CAN CLIMB OUT THROUGH IT", 0x00
zi_22_0:
    #d "CAPACITY 120 L, EMPTY", 0x00
zi_22_1:
    #d 0x01, 0x00
zi_22_2:
    #d "HEAVY.  SKILL: HYDRAULICS", 0x00


#overlay 0xCE00
zi_22_3:
    #d "A STATION REFILLS IT (LATER PHASE)", 0x00
zi_23_0:
    #d "HAND TOOL: UNINSTALLS IN A WRECK", 0x00
zi_23_1:
    #d 0x01, 0x00
zi_23_2:
    #d "WORKS FROM A HAND.  SKILL: ELECTRICAL", 0x00
zi_23_3:
    #d "EACH CUT USES 5% OF THE SUIT BATTERY", 0x00
zi_24_0:
    #d "A BULKHEAD SECTION, TAKEN OUT", 0x00
zi_24_1:
    #d 0x02, 0x00
zi_24_2:
    #d "HEAVY.  SKILL: MECHANICAL", 0x00
zi_24_3:
    #d "INSTALL IT ON THE TUG: A WALL", 0x00


#overlay 0xD000
zi_25_0:
    #d "A DOOR AND ITS FRAME, TAKEN OUT", 0x00
zi_25_1:
    #d 0x02, 0x00
zi_25_2:
    #d "HEAVY.  SKILLS: MECH., HYDRAULICS", 0x00
zi_25_3:
    #d "INSTALL IT ON THE TUG: A DOOR", 0x00
zi_26_0:
    #d "A DECK PLATE, TAKEN UP", 0x00
zi_26_1:
    #d 0x01, 0x00
zi_26_2:
    #d "LAY IT ON OPEN SPACE NEXT TO YOU", 0x00
zi_26_3:
    #d "SKILL: MECHANICAL", 0x00
zn_0:
    #d "OPEN SPACE", 0x00
zx_0:
    #d "NOTHING OUT THERE BUT DEBRIS AND COLD.", 0x00
zn_1:
    #d "OPEN SPACE", 0x00


#overlay 0xD200
zx_1:
    #d "A DISTANT STAR.  NOT FOR SALE.", 0x00
zn_2:
    #d "DECK PLATE", 0x00
zx_2:
    #d "SCUFFED DECK PLATE.  SOMEONE WALKED HERE A LOT.", 0x00
zn_3:
    #d "BULKHEAD", 0x00
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


#overlay 0xD400
zn_6:
    #d "O2 TANK", 0x00
zx_6:
    #d "AN OXYGEN TANK.  THE GAUGE STILL MOVES.", 0x00
zn_7:
    #d "REACTOR CORE", 0x00
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


#overlay 0xD600
zx_10:
    #d "A CREW BUNK.  THE BLANKET IS FOLDED NEATLY.", 0x00
zn_11:
    #d "HELM CONSOLE", 0x00
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


#overlay 0xD800
zx_14:
    #d "A POWER CONDUIT RUNS UNDER THE DECK HERE.", 0x00
zn_15:
    #d "DECK (NO AIR)", 0x00
zx_15:
    #d "FROST ON THE DECK.  THE AIR IS GONE.", 0x00
zn_16:
    #d "AIRLOCK", 0x00
zx_16:
    #d "A DOCKING AIRLOCK.  THE SEAL IS HOLDING.", 0x00
zn_17:
    #d "WORK SUIT", 0x00
zx_17:
    #d "YOUR WORK SUIT.  IT SMELLS OF HARD WORK.", 0x00
zn_18:
    #d "THRUSTER", 0x00
zx_18:
    #d "A THRUSTER NOZZLE, BLACK WITH SOOT.", 0x00


#overlay 0xDA00
zn_19:
    #d "FUEL TANK", 0x00
zx_19:
    #d "A FUEL TANK.  IT SLOSHES WHEN YOU KNOCK.", 0x00
zn_20:
    #d "AIR SCRUBBER", 0x00
zx_20:
    #d "AN AIR SCRUBBER.  THE FILTERS NEED CHANGING.", 0x00
zn_21:
    #d "HULL BREACH", 0x00
zx_21:
    #d "SOMETHING PUNCHED RIGHT THROUGH THE HULL.", 0x00
zn_22:
    #d "EMPTY O2 TANK", 0x00
zx_22:
    #d "AN EMPTY OXYGEN TANK.  THE GAUGE READS ZERO.", 0x00
zn_23:
    #d "PLASMA CUTTER", 0x00


#overlay 0xDC00
zx_23:
    #d "A PLASMA CUTTER.  KEEP YOUR FINGERS CLEAR.", 0x00
zn_24:
    #d "WALL PANEL", 0x00
zx_24:
    #d "A SECTION OF BULKHEAD.  THE BOLT HOLES ARE CLEAN.", 0x00
zn_25:
    #d "PRESSURE DOOR", 0x00
zx_25:
    #d "A PRESSURE DOOR IN ITS FRAME, READY TO FIT.", 0x00
zn_26:
    #d "SPARE PLATE", 0x00
zx_26:
    #d "A STEEL DECK PLATE.  IT RINGS WHEN YOU TAP IT.", 0x00
zn_27:
    #d "YOU", 0x00


#overlay 0xDE00
zx_27:
    #d "THAT IS YOU, IN A WORK SUIT THAT HAS SEEN BETTER DAYS.", 0x00
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


#overlay 0xE000
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
za_1:
    #d "OPEN", 0x00
za_2:
    #d "CLOSE", 0x00
za_3:
    #d "INSPECT", 0x00
za_4:
    #d "WALK HERE", 0x00
za_5:
    #d "PICK UP", 0x00
za_6:
    #d "CUT FREE", 0x00
za_7:
    #d "PUT DOWN LEFT", 0x00


#overlay 0xE200
za_8:
    #d "PUT DOWN RIGHT", 0x00
za_9:
    #d "PUT DOWN BACK", 0x00
za_10:
    #d "REFILL SUIT", 0x00
za_11:
    #d "HOLD OPEN", 0x00
za_12:
    #d "INSTALL", 0x00
za_13:
    #d "UNINSTALL", 0x00
za_14:
    #d "LAY DECK PLATE", 0x00
za_15:
    #d "REPAIR", 0x00
za_16:
    #d "SKILLS", 0x00
za_17:
    #d "TAKE OFF SUIT", 0x00
za_18:
    #d "PUT ON SUIT", 0x00
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


#overlay 0xE400
zb_8:
    #d "[#####-----]", 0x00
zb_9:
    #d "[######----]", 0x00
zb_10:
    #d "[######----]", 0x00
zb_11:
    #d "[#######---]", 0x00
zb_12:
    #d "[########--]", 0x00
zb_13:
    #d "[########--]", 0x00
zb_14:
    #d "[#########-]", 0x00
zb_15:
    #d "[#########-]", 0x00
zs_0:
    #d "SEALED - NO LEAKS", 0x00
zs_1:
    #d "SEALED - NO LEAKS", 0x00
zs_2:
    #d "SEALED - NO LEAKS", 0x00
zs_3:
    #d "SEALED - NO LEAKS", 0x00
zs_4:
    #d "SEALED - NO LEAKS", 0x00
zs_5:
    #d "SEALED - NO LEAKS", 0x00
zs_6:
    #d "SEALED - NO LEAKS", 0x00


#overlay 0xE600
zs_7:
    #d "SEALED - NO LEAKS", 0x00
zs_8:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zs_9:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zs_10:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zs_11:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zs_12:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zs_13:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zs_14:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zs_15:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00


#overlay 0xE800
s_welcome:
    #d "DOCKED TO THE KESTREL 9.  ARROWS OR WASD WALK, MOUSE SHOWS AND CLICKS.", 0x00
s_toofar:
    #d "TOO FAR AWAY - WALK NEXT TO IT FIRST.", 0x00
s_inway:
    #d "SOMETHING IS IN THE WAY.", 0x00
s_blocked:
    #d "THE WAY IS BLOCKED.", 0x00
s_full:
    #d "YOUR HANDS AND BACK ARE FULL - PUT SOMETHING DOWN.", 0x00


#overlay 0xEA00
s_nocut:
    #d "IN A WRECK IT TAKES A WORKING CUTTER IN A HAND.", 0x00
s_nobatt:
    #d "THE SUIT BATTERY IS TOO LOW FOR THE CUTTER.", 0x00
s_cutting:
    #d "UNINSTALLING WITH THE CUTTER...", 0x00
s_cutdone:
    #d "UNINSTALLED.  IT CAN BE PICKED UP NOW.", 0x00
s_cutstop:
    #d "STOPPED - YOU WALKED AWAY.", 0x00
s_inst:
    #d "INSTALLING...", 0x00


#overlay 0xEC00
s_instdone:
    #d "INSTALLED.  IT IS PART OF THE TUG NOW.", 0x00
s_uninst:
    #d "UNINSTALLING...", 0x00
s_uninstdone:
    #d "UNINSTALLED.  IT CAN BE PICKED UP NOW.", 0x00
s_installed:
    #d "INSTALLED", 0x00
s_held:
    #d "HELD OPEN", 0x00
s_plate:
    #d "THE DECK PLATE IS YOURS - OPEN SPACE UNDER IT NOW.", 0x00
s_laid:
    #d "DECK PLATE LAID.", 0x00
s_refill:
    #d "SUIT REFILLED.  THE TANK IS EMPTY NOW.", 0x00


#overlay 0xEE00
s_broken:
    #d "IT IS BROKEN - IT DOES NOT WORK.", 0x00
s_repair:
    #d "REPAIRING...", 0x00
s_repdone:
    #d "REPAIRED.  GOOD AS NEW.", 0x00
s_suitoff:
    #d "SUIT OFF: QUICKER WORK, BUT YOU BREATHE THE ROOM AIR - MIND THE VACUUM.", 0x00
s_suiton:
    #d "SUIT ON.", 0x00
s_pl_nosuit:
    #d "SUIT   NONE: YOU BREATHE THE ROOM AIR", 0x00
s_pl_suit:
    #d "SUIT   MK1 WORK SUIT     O2 ", 0x00
s_pl_of:
    #d " OF 90 L", 0x00


#overlay 0xF000
s_pl_batt:
    #d "BATT   SMALL CELL        CHARGE ", 0x00
s_pl_hands:
    #d "HANDS  ", 0x00
s_pl_back:
    #d "BACK   ", 0x00
s_slash:
    #d " / ", 0x00
s_empty:
    #d "EMPTY", 0x00
s_tug:
    #d "TUG $", 0x00
s_airon:
    #d "0, AIR ON", 0x00
s_airoff:
    #d "0, NO AIR", 0x00
s_air:
    #d "AIR ", 0x00
s_loose:
    #d "LOOSE", 0x00
s_w1:
    #d "CAUTION: SUIT O2 BELOW HALF.", 0x00
s_w2:
    #d "WARNING: SUIT O2 LOW - GET BACK TO THE TUG OR FIND AN O2 TANK.", 0x00
s_w3:
    #d "CRITICAL: SUIT O2 ALMOST GONE!", 0x00


#overlay 0xF200
s_w4:
    #d "YOU ARE BLACKING OUT - GET AIR NOW!", 0x00
s_w5:
    #d "YOU SUFFOCATED.  PRESS ENTER TO TRY AGAIN.", 0x00
zj_0:
    #d "[----------------] 0%", 0x00
zj_1:
    #d "[#---------------] 6%", 0x00
zj_2:
    #d "[##--------------] 12%", 0x00
zj_3:
    #d "[###-------------] 18%", 0x00
zj_4:
    #d "[####------------] 25%", 0x00
zj_5:
    #d "[#####-----------] 31%", 0x00
zj_6:
    #d "[######----------] 37%", 0x00


#overlay 0xF400
zj_7:
    #d "[#######---------] 43%", 0x00
zj_8:
    #d "[########--------] 50%", 0x00
zj_9:
    #d "[#########-------] 56%", 0x00
zj_10:
    #d "[##########------] 62%", 0x00
zj_11:
    #d "[###########-----] 68%", 0x00
zj_12:
    #d "[############----] 75%", 0x00
zj_13:
    #d "[#############---] 81%", 0x00
zj_14:
    #d "[##############--] 87%", 0x00
zj_15:
    #d "[###############-] 93%", 0x00
zj_16:
    #d "[################] 100%", 0x00


#overlay 0xF600
PL_NOSUIT:
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x37, 0x33, 0x33, 0x3C, 0x3C, 0x77, 0x77, 0x77, 0x77, 0x77
    #d8 0x67, 0x66, 0xC6, 0xCC, 0xCC, 0xC7, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x73, 0x73, 0x76, 0x77
    #d8 0x76, 0x66, 0x6C, 0xCC, 0xCC, 0x7C, 0x33, 0x33, 0x3E, 0x33, 0x33, 0x33, 0x37, 0x37, 0x67, 0x77
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x73, 0x33, 0x33, 0xC3, 0xC3, 0x77, 0x77, 0x77, 0x77, 0x77

SK_MSG:
    #d "MECHANICAL 00  ELECTRICAL 00  NUCLEAR 00  COMPUTERS 00  HYDRAULICS 00  SUIT 00", 0x00
SK_POS:
    #d8 (SK_MSG & 0xFF) + 11, (SK_MSG & 0xFF) + 26, (SK_MSG & 0xFF) + 38, (SK_MSG & 0xFF) + 52, (SK_MSG & 0xFF) + 67, (SK_MSG & 0xFF) + 76
