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
;     python3 gen_plc.py scrap.asm -o ../../sdcard/SCRAP.PLC --overlay 0xC000,2 --overlay-tail 0x5600,0x5A00,1 --overlay-tail 0x5C00,0x5E00,1 --overlay-head scrap_map.bin --swap 0x4100,0x4D00,INV --swap 0x4100,0x4D00,NAV,2 --swap 0x3600,0x4000,NV2,2 --swap 0x4E00,0x5000,NV3,2 --swap 0x4100,0x4D00,DCK,3 --swap 0x3600,0x4000,DK2,3 --swap 0x4E00,0x5000,DK3,3 --swap 0x5400,0x5600,DK4,3 --swap 0x3600,0x4000,ART,0
;     python3 test_scrap_sim.py                       runs it in placard_sim
;
; Date: 11/09/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"
#include "scrap_types.asm"

dos_back = 0x8008
FBUF     = 0x5400           ; 512-byte sector buffer while loading SCRAP.OVL
OVL_TAIL = 0x56             ; SCRAP.OVL's last pages: x5600-x59FF, then
OVL_END  = 0x5A             ;   x5C00-x5CFF and x5D70-x5DF2 (x5D00-x5D6F is
OVL_TAIL2 = 0x5C            ;   the DOS's menu block; from x5DF3 the audio
OVL_END2 = 0x5E             ;   buffer: silence_buf); code: the pointer, the
                            ;   repair steps, more
PRT_BUF  = FBUF             ; after the load: the text of 2 kinds (prt_load)
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
act0    = ACT_PG * 256 + 0xF0           ;   the action codes, x36F0-x36F7 (not zero page)
JB_B    = ACT_PG * 256 + 0xF8           ; the job's bar: its frames at full speed (a 16th of the work),
JB_N    = ACT_PG * 256 + 0xF9           ;   the 16ths done,
JB_TL   = ACT_PG * 256 + 0xFA           ;   the work left at the next 16th
JB_TH   = ACT_PG * 256 + 0xFB
O2_T    = ACT_PG * 256 + 0xFC           ; seconds since the suit last used a litre of O2
N_ANT   = ACT_PG * 256 + 0xFD           ; 1: a working antenna installed on the tug (tug_scan): comms
CLK_0   = ACT_PG * 256 + 0xE6           ; the ship's clock: seconds from 05-07-2175
CLK_1   = ACT_PG * 256 + 0xE7           ;   00:00:00 (24 bits; second_tick; 08:00:00
CLK_2   = ACT_PG * 256 + 0xFF           ;   at the start; SCRAP.NAV shows it)
PRT_K   = ACT_PG * 256 + 0xFE           ; the kinds pair whose text is in PRT_BUF (FF none)
                            ;   (for the navigation mode's display; not shown here)
inv     = 0x63              ; 1: the inventory screen is up (not the view)
place   = 0x64              ; INSTALL from the inventory: the carry slot's address
                            ;   while you pick the cell (0 none)
inv_k   = 0x65              ; the inventory's slot under the mouse: 0-2 the carry
                            ;   slots, 3-6 the gear (suit, battery, O2, utility), FF none
pl_t    = 0x66              ; the part being placed: its type
PL_S    = ACT_PG * 256 + 0xEF           ;   its carry slot (the job: cut_m 4)
SWAP_LO = 0x4100            ; SCRAP.INV (the inventory) is read in here, x4100-x4CFF
PWR_LO  = 0x4700            ; SCRAP.PWR (the power view, scrap_pwr.masm) here, x4700-x4CFF
INI_LO  = 0x4100            ; SCRAP.INI (the start's code, scrap_pwr.masm) here, x4100-x44FF
CB_PG   = 0xA1              ; the conduit bits: odd pages xA1-xFF, even offsets 0-30 (cb_get)
NAV3_LO = 0x4E00            ; SCRAP.NV3 (the rest of it) in the file system's buffer
NAV2_LO = 0x3600            ; SCRAP.NV2 (more of the map screen) is read in here over
                            ;   the actions table and the cell art, x3600-x3FFF;
                            ;   SCRAP.ART puts them back
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
cut_m   = 0x99              ; the job: 0 a cut, 1 installing, 2 uninstalling, 3 repairing,
                            ;   4 installing from a carry slot (place_click)
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
O2_SECS = 7                 ; the suit uses 1 L every 7 s: 90 L last 10.5 minutes
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
; x5600-x59FF: SCRAP.OVL's last pages (after xFE): the mouse pointer,
; a repair's steps
; ============================================================

; pt_hide - the pointer off (PT_SV, what was under it, back) if it is
; drawn.  pt_show - the pointer at the mouse (its tip at art pixel m_x /
; 4, m_y / 2) if it is off and the mouse is over the view area, what is
; under it kept in PT_SV.  pt_walk (their end, AC 1 draws, 0 puts back):
; 3 byte columns x 8 line pairs from byte column PT_C, line pair PT_P
; (none past the right edge or line pair 191), PT_TAB + PT_B: AND mask,
; + 8 the color.  Leaves; T0-T7 (the program does not use them) and u0.

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   0x07, ac
    ld   ac, [MAP_SHADOW]
    ld   LINK_LO, x             ; CALL l_fs_mount
    ld   scw_r3, [x]
    ld   LINK_HI, x
    ld   scw_r3 >> 8, [x]
    ld   l_fs_mount >> 8, y
    jmp  l_fs_mount
scw_r3:
    ld   LINK_LO, x             ; CALL ovl_load
    ld   scw_r4, [x]
    ld   LINK_HI, x
    ld   scw_r4 >> 8, [x]
    ld   ovl_load >> 8, y
    jmp  ovl_load
scw_r4:
    ld   LINK_LO, x             ; CALL silence_buf
    ld   scw_r5, [x]
    ld   LINK_HI, x
    ld   scw_r5 >> 8, [x]
    ld   silence_buf >> 8, y
    jmp  silence_buf
scw_r5:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   start >> 8, y
    jmp  start

start:
    ld   LINK_LO, x             ; SCRAP.INI: the start's code (pw_start)
    ld   scw_r6, [x]
    ld   LINK_HI, x
    ld   scw_r6 >> 8, [x]
    ld   ini_fetch >> 8, y
    jmp  ini_fetch
scw_r6:
    ld   LINK_LO, x             ; CALL pw_start
    ld   scw_r7, [x]
    ld   LINK_HI, x
    ld   scw_r7 >> 8, [x]
    ld   pw_start >> 8, y
    jmp  pw_start
scw_r7:
    ld   LINK_LO, x             ; (over SCRAP.INI)
    ld   scw_r8, [x]
    ld   LINK_HI, x
    ld   scw_r8 >> 8, [x]
    ld   rooms_build >> 8, y
    jmp  rooms_build
scw_r8:
    ld   LINK_LO, x             ; CALL tug_scan
    ld   scw_r9, [x]
    ld   LINK_HI, x
    ld   scw_r9 >> 8, [x]
    ld   tug_scan >> 8, y
    jmp  tug_scan
scw_r9:
    ld   LINK_LO, x             ; CALL camera_fit
    ld   scw_r10, [x]
    ld   LINK_HI, x
    ld   scw_r10 >> 8, [x]
    ld   camera_fit >> 8, y
    jmp  camera_fit
scw_r10:
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r11, [x]
    ld   LINK_HI, x
    ld   scw_r11 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r11:
    ld   s_welcome & 0xFF, ac
    ld   ac, [R0]
    ld   s_welcome >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r12, [x]
    ld   LINK_HI, x
    ld   scw_r12 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r12:
    ld   LINK_LO, x             ; CALL draw_panel
    ld   scw_r13, [x]
    ld   LINK_HI, x
    ld   scw_r13 >> 8, [x]
    ld   draw_panel >> 8, y
    jmp  draw_panel
scw_r13:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the frame loop
; ============================================================
s_prox:
    #d "PROXIMITY: SLOW DOWN.", 0x00
s_imp:
    #d "IMPACT IN 10 S: BRAKE!", 0x00

; nav_back - the map closed: C on it, the docking screen (SCRAP.DCK into
; x4100; it reads in the rest), then the map again; else the ship's art
; back.  The rest of nav_action
; (scrap_fl.masm)
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
    and  0x40, ac
    or   [u0], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; map_setd - AC = the new damage step of the cell map_get last found.  A
; leaf.
cut_pay:
    ld   [batt], ac
    sub  CUT_BATT, ac
    ld   ac, [batt]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; struct_done - a wall taken out is a wall panel on the deck, a door a
; door kit; a deck plate goes to a free carry slot and leaves open space.
; The rest of cut_done.

#addr 0x0200
loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames_io
    ld   scw_r14, [x]
    ld   LINK_HI, x
    ld   scw_r14 >> 8, [x]
    ld   l_wait_frames_io >> 8, y
    jmp  l_wait_frames_io
scw_r14:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   scw_r15, [x]
    ld   LINK_HI, x
    ld   scw_r15 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
scw_r15:
    ld   LINK_LO, x             ; CALL l_menu_poll
    ld   scw_r16, [x]
    ld   LINK_HI, x
    ld   scw_r16 >> 8, [x]
    ld   l_menu_poll >> 8, y
    jmp  l_menu_poll
scw_r16:
    ld   [dead], ac
    bne  lp_dead
    ld   LINK_LO, x             ; CALL input_mouse
    ld   scw_r17, [x]
    ld   LINK_HI, x
    ld   scw_r17 >> 8, [x]
    ld   input_mouse >> 8, y
    jmp  input_mouse
scw_r17:
    ld   LINK_LO, x             ; CALL input_keys
    ld   scw_r18, [x]
    ld   LINK_HI, x
    ld   scw_r18 >> 8, [x]
    ld   input_keys >> 8, y
    jmp  input_keys
scw_r18:
    ld   LINK_LO, x             ; CALL input_walk
    ld   scw_r19, [x]
    ld   LINK_HI, x
    ld   scw_r19 >> 8, [x]
    ld   input_walk >> 8, y
    jmp  input_walk
scw_r19:
    ld   LINK_LO, x             ; CALL game_tick
    ld   scw_r20, [x]
    ld   LINK_HI, x
    ld   scw_r20 >> 8, [x]
    ld   game_tick >> 8, y
    jmp  game_tick
scw_r20:
    ld   LINK_LO, x             ; CALL update_panel
    ld   scw_r21, [x]
    ld   LINK_HI, x
    ld   scw_r21 >> 8, [x]
    ld   update_panel >> 8, y
    jmp  update_panel
scw_r21:
    ld   LINK_LO, x             ; the mouse pointer, after all the drawing
    ld   scw_r22, [x]
    ld   LINK_HI, x
    ld   scw_r22 >> 8, [x]
    ld   pt_show >> 8, y
    jmp  pt_show
scw_r22:
    ld   loop >> 8, y
    jmp  loop
lp_dead:
    ld   LINK_LO, x             ; dead: Enter starts again
    ld   scw_r23, [x]
    ld   LINK_HI, x
    ld   scw_r23 >> 8, [x]
    ld   update_panel >> 8, y
    jmp  update_panel
scw_r23:
    ld   LINK_LO, x             ; CALL l_kbd_getc
    ld   scw_r24, [x]
    ld   LINK_HI, x
    ld   scw_r24 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
scw_r24:
    xor  0x0A, ac
    bne  lp_d
    ld   main >> 8, y
    jmp  main
lp_d:
    ld   loop >> 8, y
    jmp  loop

; the flight's alarms (scrap_fl.masm's; here, where there is room)
s_ovl:
    #d "SCRAP.OVL", 0x00
s_invf:
    #d "SCRAP.INV", 0x00
s_navf:
    #d "SCRAP.NAV", 0x00
s_nv2f:
    #d "SCRAP.NV2", 0x00
s_artf:                         ; (nav_fetch: these four share a page)
    #d "SCRAP.ART", 0x00
s_dckf:
    #d "SCRAP.DCK", 0x00
s_pwrf:
    #d "SCRAP.PWR", 0x00
s_inif:
    #d "SCRAP.INI", 0x00
PRT_NM:                         ; prt_load's: the part text file, its folder
    #d "K0A", 0x00
s_prtd:
    #d "SCRAP", 0x00
s_up:
    #d "..", 0x00
s_dmg:
    #d "HEALTH ", 0x00

; ------------------------------------------------------------
; sc_leave - the library's lib_leave (LEAVE) copied into the RAM: the
; ROM is mapped out while this program runs
; ------------------------------------------------------------

#addr 0x0300
nav_back:
    ld   FL_PG, y
    ld   FL_GO, x
    ld   [y,x], ac
    xor  2, ac
    bne  nv_a
    ld   ac, [y,x]
    ld   SWAP_LO >> 8, ac
    ld   ac, [u5]
    ld   6, ac
    ld   ac, [u6]
    ld   s_dckf & 0xFF, ac
    ld   LINK_LO, x             ; CALL nav_fetch
    ld   scw_r25, [x]
    ld   LINK_HI, x
    ld   scw_r25 >> 8, [x]
    ld   nav_fetch >> 8, y
    jmp  nav_fetch
scw_r25:
    bne  nb_m
    ld   LINK_LO, x             ; CALL dock_main
    ld   scw_r26, [x]
    ld   LINK_HI, x
    ld   scw_r26 >> 8, [x]
    ld   dock_main >> 8, y
    jmp  dock_main
scw_r26:
nb_m:
    ld   nv_ok >> 8, y
    jmp  nv_ok
nv_a:
    ld   NAV2_LO >> 8, ac       ; the art back (SCRAP.ART)
    ld   ac, [u5]
    ld   5, ac
    ld   ac, [u6]
    ld   s_artf & 0xFF, ac
    ld   LINK_LO, x             ; CALL nav_fetch
    ld   scw_r27, [x]
    ld   LINK_HI, x
    ld   scw_r27 >> 8, [x]
    ld   nav_fetch >> 8, y
    jmp  nav_fetch
scw_r27:
    ld   [rb_go], ac
    beq  nv_v
    ld   LINK_LO, x             ; CALL rooms_build
    ld   scw_r28, [x]
    ld   LINK_HI, x
    ld   scw_r28 >> 8, [x]
    ld   rooms_build >> 8, y
    jmp  rooms_build
scw_r28:
    clr  ac
    ld   ac, [rb_go]
nv_v:
    clr  ac
    ld   ac, [lock]
    ld   ac, [h_on]
    ld   ac, [wk_on]
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r29, [x]
    ld   LINK_HI, x
    ld   scw_r29 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r29:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r30, [x]
    ld   LINK_HI, x
    ld   scw_r30 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r30:
    ld   [dirty], ac
    or   3, ac
    ld   ac, [dirty]
    ld   sc_leave >> 8, y
    jmp  sc_leave

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
    ld   scw_r31, [x]
    ld   LINK_HI, x
    ld   scw_r31 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
scw_r31:
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
    ld   scw_r32, [x]
    ld   LINK_HI, x
    ld   scw_r32 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
scw_r32:
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
BIT_TAB:
    #d8 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80

; inst_action - INSTALL or UNINSTALL (w3) the part the panel shows, from
; next to it: INST_FRAMES of work (cut_done).  The rest of do_action.

#addr 0x0400
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
    ld   scw_r33, [x]
    ld   LINK_HI, x
    ld   scw_r33 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
scw_r33:
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
    ld   scw_r34, [x]
    ld   LINK_HI, x
    ld   scw_r34 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
scw_r34:
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
    ld   scw_r35, [x]
    ld   LINK_HI, x
    ld   scw_r35 >> 8, [x]
    ld   pad_read >> 8, y
    jmp  pad_read
scw_r35:
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
    ld   scw_r36, [x]
    ld   LINK_HI, x
    ld   scw_r36 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
scw_r36:
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
    ld   scw_r37, [x]
    ld   LINK_HI, x
    ld   scw_r37 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
scw_r37:
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
    ld   scw_r38, [x]
    ld   LINK_HI, x
    ld   scw_r38 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
scw_r38:
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
    ld   scw_r39, [x]
    ld   LINK_HI, x
    ld   scw_r39 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
scw_r39:
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
    ld   scw_r40, [x]
    ld   LINK_HI, x
    ld   scw_r40 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
scw_r40:
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
    ld   scw_r41, [x]
    ld   LINK_HI, x
    ld   scw_r41 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
scw_r41:
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
    ld   scw_r42, [x]
    ld   LINK_HI, x
    ld   scw_r42 >> 8, [x]
    ld   vid_mode >> 8, y
    jmp  vid_mode
scw_r42:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; silence_buf - the audio buffer x5DF3-x5FFF all silence (x80): the
; overlay's page x5D wrote its start.  A leaf.
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

#addr 0x0600
silence_buf:
    ld   0x5D, ac
    ld   ac, [u1]
    ld   0xF3, ac
sb_l:
    ld   [u1], y
    ld   ac, x
    ld   0x80, [y,x]
    inc
    bne  sb_l
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  0x60, ac
    beq  sb_e
    clr  ac
    bra  sb_l
sb_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; ovl_load - SCRAP.OVL (the map) into the even pages from MAP_PAGE: a
; sector holds two of them (tracker.masm's ovl_load)
; ------------------------------------------------------------
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
    ld   (ov_st + 1) >> 8, y    ; every 2nd page from x60
    ld   (ov_st + 1) & 0xFF, x
    ld   2, [y,x]
    ld   s_ovl & 0xFF, ac
    ld   ac, [R0]
    ld   s_ovl >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_fs_open
    ld   scw_r43, [x]
    ld   LINK_HI, x
    ld   scw_r43 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
scw_r43:
    bne  ov_e
    ld   MAP_PAGE, ac
    ld   ac, [u5]
ov_s:
    ld   FBUF & 0xFF, ac
    ld   ac, [R4]
    ld   FBUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_read
    ld   scw_r44, [x]
    ld   LINK_HI, x
    ld   scw_r44 >> 8, [x]
    ld   l_fs_read >> 8, y
    jmp  l_fs_read
scw_r44:
    bne  ov_e
    ld   FBUF >> 8, ac
    ld   ac, [u6]
    ld   2, ac
    ld   ac, [u7]
ov_p:
    clr  ac
    ld   ac, [u4]
    ld   [u5], ac               ; x5D: from x5D70, the DOS's menu block
    xor  0x5D, ac               ; (x5D00-x5D6F) kept, so Esc goes back
    bne  ov_b
    ld   0x70, ac
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
ov_st:
    add  2, ac                  ; (1 for the last pages: written below)
    ld   ac, [u5]
    bne  ov_k
    ld   (ov_st + 1) >> 8, y    ; after xFE: the pages x56-x59, one by one
    ld   (ov_st + 1) & 0xFF, x
    ld   1, [y,x]
    ld   OVL_TAIL, ac
    ld   ac, [u5]
    bra  ov_n
ov_k:
    xor  OVL_END, ac            ; after x59: x5C-x5D (past the mode bytes)
    bne  ov_k1
    ld   OVL_TAIL2, ac
    bra  ov_kk
ov_k1:
    ld   [u5], ac               ; after x5D: done
    xor  OVL_END2, ac
    beq  ov_e
    bra  ov_n
ov_kk:
    ld   ac, [u5]
ov_n:
    ld   [u7], ac
    dec
    ld   ac, [u7]
    bne  ov_p
    bra  ov_s
ov_e:
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
rb_leak:
    ld   RB_LK >> 8, y
    ld   [rb_n], ac
    add  RB_LK & 0xFF, x
    ld   1, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rb_nb - g_x, g_y = neighbour rb_k of rb_cx, rb_cy (0 right, 1 left, 2
; down, 3 up); AC = 0 when it is off the map.  A leaf.

#addr 0x0700
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
    ld   [y,x], ac              ; the type byte: bolted, room bit 4, kind
    ld   ac, [u0]
    and  0x80, ac
    ld   ac, [c_b]
    ld   [u0], ac
    and  0x40, ac
    shr  ac
    shr  ac
    or   [c_r], ac
    ld   ac, [c_r]
    ld   [u0], ac
    and  0x3F, ac
    ld   ac, [c_t]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; map_put - AC = the new type of the cell map_get last found (its room
; kept, not bolted).  A leaf.
draw_cell:
    ld   [dc_t], ac
    sub  FACE0 + 6, ac          ; a part facing down or right: dc_face
    bcs  dc_0
    ld   dc_face >> 8, y
    jmp  dc_face
dc_0:
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

; crack_cell - after draw_cell: a broken one (damage from step 8, not the
; player) gets the crack (CRACK: AND masks in the art's order).  A leaf.
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
kind_base:
    sub  FACE0 + 3, ac
    bcs  kb_x
    add  FACE0, ac
    bra  kind_base
kb_x:
    add  FACE0 + 3, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dc_face - draw_cell for a part facing down or right (kinds FACE0 + 6
; on, no art of their own): the art of kind dc_t - 6 (up, left) upside
; down (byte 16 c + r from 16 c + 15 - r) or mirrored (from 16 (3 - c) +
; r, its two pixels swapped): byte d from d xor K, K = the art's index |
; 0x0F or 0x30, kept in dc_t (not T_PLAYER: cell_extra).  A leaf.

#addr 0x0800
crack_cell:
    ld   [dc_t], ac
    xor  T_PLAYER, ac
    beq  ck_e
    ld   [c_f], ac
    sub  8, ac
    bcs  ck_e
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
    ld   CRACK & 0xFF, ac
    ld   ac, [dc_ai]
    ld   4, ac
    ld   ac, [dc_c]
ck_col:
    ld   [dc_base], ac
    ld   ac, [dc_so]
    ld   16, ac
    ld   ac, [dc_n]
ck_byte:
    ld   CRACK >> 8, y
    ld   [dc_ai], x
    ld   [y,x], ac
    ld   [dc_sp], y
    ld   [dc_so], x
    and  [y,x], ac
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
    bne  ck_byte
    ld   [dc_sp], ac
    add  2, ac
    ld   ac, [dc_sp]
    ld   [dc_c], ac
    dec
    ld   ac, [dc_c]
    bne  ck_col
ck_e:
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
    blt  ca_lo28
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    sub  223, ac
    bra  ca_go28
ca_lo28:
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    add  32, ac
ca_go28:
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
WARN_TAB:
    #d8 s_w1 & 0xFF, s_w2 & 0xFF, s_w3 & 0xFF, s_w4 & 0xFF, s_w5 & 0xFF
    #d8 s_w1 >> 8, s_w2 >> 8, s_w3 >> 8, s_w4 >> 8, s_w5 >> 8
PD_TAB:
    #d8 0x10, 0xE8, 0x64, 0x0A, 0x01
    #d8 0x27, 0x03, 0x00, 0x00, 0x00

; put_dec8 - AC in decimal

#addr 0x0900
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
    ld   LINK_LO, x             ; nothing drawn over the pointer
    ld   scw_r45, [x]
    ld   LINK_HI, x
    ld   scw_r45 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r45:
    ld   [v_x], ac
    add  [dc_cx], ac
    ld   ac, [g_x]
    ld   [v_y], ac
    add  [dc_cy], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; (undocked: no KESTREL 9)
    ld   scw_r46, [x]
    ld   LINK_HI, x
    ld   scw_r46 >> 8, [x]
    ld   map_see >> 8, y
    jmp  map_see
scw_r46:
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
    ld   scw_r47, [x]
    ld   LINK_HI, x
    ld   scw_r47 >> 8, [x]
    ld   draw_cell >> 8, y
    jmp  draw_cell
scw_r47:
    ld   LINK_LO, x             ; CALL crack_cell
    ld   scw_r48, [x]
    ld   LINK_HI, x
    ld   scw_r48 >> 8, [x]
    ld   crack_cell >> 8, y
    jmp  crack_cell
scw_r48:
    ld   LINK_LO, x             ; CALL cell_extra
    ld   scw_r49, [x]
    ld   LINK_HI, x
    ld   scw_r49 >> 8, [x]
    ld   cell_extra >> 8, y
    jmp  cell_extra
scw_r49:
    ld   PW_ST >> 8, y          ; the power view: its lines over it
    ld   PW_ST & 0xFF, x
    ld   [y,x], ac
    and  1, ac
    beq  vc_e
    ld   LINK_LO, x             ; CALL pw_over
    ld   scw_r50, [x]
    ld   LINK_HI, x
    ld   scw_r50 >> 8, [x]
    ld   pw_over >> 8, y
    jmp  pw_over
scw_r50:
vc_e:
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
    ld   [inv], ac
    beq  dv_go
    ld   inv_draw >> 8, y
    jmp  inv_draw
dv_go:
    clr  ac
    ld   ac, [fr_on]
    ld   ac, [dc_cy]
dv_row:
    clr  ac
    ld   ac, [dc_cx]
dv_cell:
    ld   LINK_LO, x             ; CALL view_cell
    ld   scw_r51, [x]
    ld   LINK_HI, x
    ld   scw_r51 >> 8, [x]
    ld   view_cell >> 8, y
    jmp  view_cell
scw_r51:
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
    ld   scw_r52, [x]
    ld   LINK_HI, x
    ld   scw_r52 >> 8, [x]
    ld   frame_set >> 8, y
    jmp  frame_set
scw_r52:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; refresh_cell - map cell g_x, g_y drawn again if it is in the view (with
; the frame when the frame is on it)
JB_PCT:
    #d8 0, 6, 12, 18, 25, 31, 37, 43, 50, 56, 62, 68, 75, 81, 87, 93, 100

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
    ld   FL_PG, y               ; the navigation screen is up: not drawn
    ld   FL_NAV, x
    ld   [y,x], ac
    beq  rc_0
    ld   sc_leave >> 8, y
    jmp  sc_leave
rc_0:
    ld   [inv], ac
    beq  rc_go
    ld   LINK_LO, x             ; CALL inv_slots
    ld   scw_r53, [x]
    ld   LINK_HI, x
    ld   scw_r53 >> 8, [x]
    ld   inv_slots >> 8, y
    jmp  inv_slots
scw_r53:
    ld   sc_leave >> 8, y
    jmp  sc_leave
rc_go:
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
    ld   scw_r54, [x]
    ld   LINK_HI, x
    ld   scw_r54 >> 8, [x]
    ld   view_cell >> 8, y
    jmp  view_cell
scw_r54:
    ld   [fr_on], ac
    beq  rc_e
    ld   [g_x], ac
    xor  [fr_x], ac
    bne  rc_e
    ld   [g_y], ac
    xor  [fr_y], ac
    bne  rc_e
    ld   LINK_LO, x             ; CALL draw_frame
    ld   scw_r55, [x]
    ld   LINK_HI, x
    ld   scw_r55 >> 8, [x]
    ld   draw_frame >> 8, y
    jmp  draw_frame
scw_r55:
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
    ld   scw_r56, [x]
    ld   LINK_HI, x
    ld   scw_r56 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r56:
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
    ld   scw_r57, [x]
    ld   LINK_HI, x
    ld   scw_r57 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r57:
fs_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; camera_fit - the view around the player (start).  A leaf.
subject_hover:
    ld   [inv], ac
    beq  sh_m
    ld   inv_subject >> 8, y
    jmp  inv_subject
sh_m:
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

#addr 0x0B00
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
    ld   ac, [place]            ; and no part to place
    ld   ac, [lock]
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r75, [x]
    ld   LINK_HI, x
    ld   scw_r75 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r75:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; keys and walking
; ============================================================

; input_keys - 1-8: the panel's actions
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

; draw_dmg - "HEALTH [########--] 81%" at row 24, column 54 (from the
; damage step: BAR_PG, TB_DMGL)

#addr 0x0C00
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
    ld   scw_r58, [x]
    ld   LINK_HI, x
    ld   scw_r58 >> 8, [x]
    ld   l_mouse_poll >> 8, y
    jmp  l_mouse_poll
scw_r58:
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
    ld   scw_r59, [x]
    ld   LINK_HI, x
    ld   scw_r59 >> 8, [x]
    ld   l_mouse_move >> 8, y
    jmp  l_mouse_move
scw_r59:
    ld   [R0], ac
    ld   ac, [m_xl]
    ld   [R1], ac
    ld   ac, [m_xh]
    ld   [R2], ac
    ld   ac, [m_yl]
    ld   [R3], ac
    ld   ac, [m_yh]
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   [y,x], ac
    bne  im_h
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r60, [x]
    ld   LINK_HI, x
    ld   scw_r60 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r60:
    bra  im_b
im_h:
    ld   LINK_LO, x             ; CALL pt_hide
    ld   scw_r61, [x]
    ld   LINK_HI, x
    ld   scw_r61 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r61:
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
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   [y,x], ac
    bne  im_p
    ld   LINK_LO, x             ; CALL click_left
    ld   scw_r62, [x]
    ld   LINK_HI, x
    ld   scw_r62 >> 8, [x]
    ld   click_left >> 8, y
    jmp  click_left
scw_r62:
    bra  im_r
im_p:
    xor  2, ac                  ; (FL_NAV 2: the docking screen's)
    bne  im_q
    ld   LINK_LO, x             ; CALL dk_pick
    ld   scw_r63, [x]
    ld   LINK_HI, x
    ld   scw_r63 >> 8, [x]
    ld   dk_pick >> 8, y
    jmp  dk_pick
scw_r63:
    bra  im_r
im_q:
    ld   LINK_LO, x             ; CALL nv_pick
    ld   scw_r64, [x]
    ld   LINK_HI, x
    ld   scw_r64 >> 8, [x]
    ld   nv_pick >> 8, y
    jmp  nv_pick
scw_r64:
im_r:
    ld   [mb_new], ac
    and  2, ac
    beq  im_e
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   [y,x], ac
    bne  im_e
    ld   LINK_LO, x             ; CALL click_right
    ld   scw_r65, [x]
    ld   LINK_HI, x
    ld   scw_r65 >> 8, [x]
    ld   click_right >> 8, y
    jmp  click_right
scw_r65:
im_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; in_view - AC = 1 when the pointer is over the view (y < 384).  A leaf.
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
    ld   LINK_LO, x             ; (the loop draws it again where it is now)
    ld   scw_r66, [x]
    ld   LINK_HI, x
    ld   scw_r66 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r66:
    ld   [inv], ac
    beq  hu_0
    ld   inv_hover >> 8, y
    jmp  inv_hover
hu_0:
    ld   LINK_LO, x             ; CALL in_view
    ld   scw_r67, [x]
    ld   LINK_HI, x
    ld   scw_r67 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r67:
    bne  hu_v
    ld   LINK_LO, x             ; CALL hover_panel
    ld   scw_r68, [x]
    ld   LINK_HI, x
    ld   scw_r68 >> 8, [x]
    ld   hover_panel >> 8, y
    jmp  hover_panel
scw_r68:
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
    ld   scw_r69, [x]
    ld   LINK_HI, x
    ld   scw_r69 >> 8, [x]
    ld   frame_set >> 8, y
    jmp  frame_set
scw_r69:
    ld   [lock], ac
    bne  hu_e
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r70, [x]
    ld   LINK_HI, x
    ld   scw_r70 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r70:
hu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; hover_panel - m_sel = the action under the pointer (FF none): rows
; 25-28, column 44 up (actions 0-3), from column 62 (4-7).  A leaf.
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
    ld   scw_r139, [x]
    ld   LINK_HI, x
    ld   scw_r139 >> 8, [x]
    ld   menu_row >> 8, y
    jmp  menu_row
scw_r139:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  dm_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; menu_row - text row 25 + w2: "| ", then actions w2 and w2 + 4 (two
; columns from 44 and 62)
act_done:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r181, [x]
    ld   LINK_HI, x
    ld   scw_r181 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r181:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; put_action - PUT DOWN: the part from carry slot w3 - A_PUTL onto the
; deck the panel shows.  The rest of do_action.

#addr 0x0E00
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
    ld   scw_r71, [x]
    ld   LINK_HI, x
    ld   scw_r71 >> 8, [x]
    ld   do_action >> 8, y
    jmp  do_action
scw_r71:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cl_v:
    ld   LINK_LO, x             ; CALL in_view
    ld   scw_r72, [x]
    ld   LINK_HI, x
    ld   scw_r72 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r72:
    beq  cl_e
    ld   [place], ac
    beq  cl_l
    ld   place_click >> 8, y
    jmp  place_click
cl_l:
    ld   [lock], ac             ; locked on this cell already: the next
    beq  cl_k                   ; thing in it (under_cycle)
    ld   LINK_LO, x             ; CALL under_cycle
    ld   scw_r73, [x]
    ld   LINK_HI, x
    ld   scw_r73 >> 8, [x]
    ld   under_cycle >> 8, y
    jmp  under_cycle
scw_r73:
    bne  cl_e
cl_k:
    ld   1, ac
    ld   ac, [lock]
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r74, [x]
    ld   LINK_HI, x
    ld   scw_r74 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r74:
cl_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; click_right - the panel follows the pointer again
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
    ld   scw_r76, [x]
    ld   LINK_HI, x
    ld   scw_r76 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
scw_r76:
    beq  ik_e
    ld   ac, [key]
    xor  0x69, ac               ; I or Tab: the inventory
    beq  ik_i
    ld   [key], ac
    xor  0x49, ac
    beq  ik_i
    ld   [key], ac
    xor  0x09, ac
    beq  ik_i
    ld   [key], ac
    xor  0x76, ac               ; V: the power view on or off
    beq  ik_v
    ld   [key], ac
    xor  0x56, ac
    beq  ik_v
    ld   [key], ac
    sub  0x31, ac
    ld   ac, [u1]
    sub  8, ac
    bcc  ik_e
    ld   [u1], ac
    ld   LINK_LO, x             ; CALL do_action
    ld   scw_r77, [x]
    ld   LINK_HI, x
    ld   scw_r77 >> 8, [x]
    ld   do_action >> 8, y
    jmp  do_action
scw_r77:
ik_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
ik_i:
    ld   inv_toggle >> 8, y
    jmp  inv_toggle
ik_v:
    ld   pw_toggle >> 8, y
    jmp  pw_toggle

; input_walk - the held directions (arrows, WASD, pad 1) or WALK HERE:
; a step every WALK_FRAMES frames
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
    ld   scw_r151, [x]
    ld   LINK_HI, x
    ld   scw_r151 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r151:
    bra  pd_l
pd_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_msg - row 29: the message (tinted) or nothing

#addr 0x0F00
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
    ld   [inv], ac
    bne  iw_inv
    ld   LINK_LO, x             ; CALL l_pad_read
    ld   scw_r78, [x]
    ld   LINK_HI, x
    ld   scw_r78 >> 8, [x]
    ld   l_pad_read >> 8, y
    jmp  l_pad_read
scw_r78:
    ld   LINK_LO, x             ; CALL read_dirs
    ld   scw_r79, [x]
    ld   LINK_HI, x
    ld   scw_r79 >> 8, [x]
    ld   read_dirs >> 8, y
    jmp  read_dirs
scw_r79:
    ld   [dirs], ac
    bne  iw_go
    ld   [wk_on], ac
    bne  iw_t
iw_inv:
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
    ld   scw_r80, [x]
    ld   LINK_HI, x
    ld   scw_r80 >> 8, [x]
    ld   walk_delay >> 8, y
    jmp  walk_delay
scw_r80:
    ld   ac, [walk_t]
    ld   [dirs], ac
    bne  iw_man
    ld   LINK_LO, x             ; CALL auto_step
    ld   scw_r81, [x]
    ld   LINK_HI, x
    ld   scw_r81 >> 8, [x]
    ld   auto_step >> 8, y
    jmp  auto_step
scw_r81:
    ld   sc_leave >> 8, y
    jmp  sc_leave
iw_man:
    ld   LINK_LO, x             ; CALL man_step
    ld   scw_r82, [x]
    ld   LINK_HI, x
    ld   scw_r82 >> 8, [x]
    ld   man_step >> 8, y
    jmp  man_step
scw_r82:
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

#addr 0x1000
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
    ld   scw_r83, [x]
    ld   LINK_HI, x
    ld   scw_r83 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r83:
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
    ld   scw_r84, [x]
    ld   LINK_HI, x
    ld   scw_r84 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r84:
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
    ld   scw_r85, [x]
    ld   LINK_HI, x
    ld   scw_r85 >> 8, [x]
    ld   try_move >> 8, y
    jmp  try_move
scw_r85:
    bne  as_e
as_blk:
    ld   s_blocked & 0xFF, ac
    ld   ac, [R0]
    ld   s_blocked >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r86, [x]
    ld   LINK_HI, x
    ld   scw_r86 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r86:
as_done:
    clr  ac
    ld   ac, [wk_on]
as_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; try_move - a step to n_x, n_y: AC = 0 blocked, 1 moved, 2 a closed
; door there opened (the step is the next one)

#addr 0x1100
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
    ld   LINK_LO, x             ; undocked: the KESTREL 9 is not there
    ld   scw_r87, [x]
    ld   LINK_HI, x
    ld   scw_r87 >> 8, [x]
    ld   fl_far >> 8, y
    jmp  fl_far
scw_r87:
    bne  tm_no
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r88, [x]
    ld   LINK_HI, x
    ld   scw_r88 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r88:
    xor  T_DOOR, ac
    bne  tm_w
    ld   [c_f], ac              ; under 50 % health: stuck shut
    sub  8, ac
    bcs  tm_op
    ld   s_jam & 0xFF, ac
    ld   ac, [R0]
    ld   s_jam >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r89, [x]
    ld   LINK_HI, x
    ld   scw_r89 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r89:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
tm_op:
    ld   T_DOORO, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r90, [x]
    ld   LINK_HI, x
    ld   scw_r90 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r90:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r91, [x]
    ld   LINK_HI, x
    ld   scw_r91 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r91:
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
    ld   scw_r92, [x]
    ld   LINK_HI, x
    ld   scw_r92 >> 8, [x]
    ld   move_player >> 8, y
    jmp  move_player
scw_r92:
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
clk_tick:
    ld   ACT_PG, y
    ld   CLK_0 & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bne  clk_e
    ld   CLK_1 & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bne  clk_e
    ld   CLK_2 & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
clk_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; second_tick - once a second: the tug's parts; the suit uses its O2 (1 L
; every O2_SECS seconds) in a
; room without air, and fills up (and charges) in the tug's air; then
; stage_set
place_done:
    ld   PL_S >> 8, y
    ld   PL_S & 0xFF, x
    ld   [y,x], ac
    ld   ac, [v0]
    ld   ac, x
    ld   [x], ac
    ld   ac, [v1]
    xor  [pl_t], ac
    beq  pq_0
    ld   work_end >> 8, y
    jmp  work_end
pq_0:
    ld   place_put >> 8, y
    jmp  place_put

; place_put - the cell type the part v1 makes, put there.  The rest of
; place_done

#addr 0x1200
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
    ld   scw_r93, [x]
    ld   LINK_HI, x
    ld   scw_r93 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r93:
mp_c:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; an open door left behind closes (not held)
    ld   scw_r94, [x]
    ld   LINK_HI, x
    ld   scw_r94 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r94:
    xor  T_DOORO, ac
    bne  mp_m
    ld   [c_b], ac
    bne  mp_m
    ld   [c_f], ac              ; under 50 % health: stuck open
    sub  8, ac
    bcc  mp_m
    ld   T_DOOR, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r95, [x]
    ld   LINK_HI, x
    ld   scw_r95 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r95:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
mp_m:
    ld   [n_x], ac
    ld   ac, [p_x]
    ld   [n_y], ac
    ld   ac, [p_y]
    ld   LINK_LO, x             ; the old cell, without the player
    ld   scw_r96, [x]
    ld   LINK_HI, x
    ld   scw_r96 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r96:
    ld   LINK_LO, x             ; CALL camera_follow
    ld   scw_r97, [x]
    ld   LINK_HI, x
    ld   scw_r97 >> 8, [x]
    ld   camera_follow >> 8, y
    jmp  camera_follow
scw_r97:
    beq  mp_s
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r98, [x]
    ld   LINK_HI, x
    ld   scw_r98 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r98:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r99, [x]
    ld   LINK_HI, x
    ld   scw_r99 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r99:
    bra  mp_p
mp_s:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r100, [x]
    ld   LINK_HI, x
    ld   scw_r100 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r100:
mp_p:
    ld   [lock], ac
    bne  mp_e
    ld   LINK_LO, x             ; CALL subject_hover
    ld   scw_r101, [x]
    ld   LINK_HI, x
    ld   scw_r101 >> 8, [x]
    ld   subject_hover >> 8, y
    jmp  subject_hover
scw_r101:
mp_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; actions
; ============================================================

; do_action - AC = the panel's action 0-7
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
    ld   fl_accel >> 8, y
    jmp  fl_accel

; near - AC = 1 when the panel's cell is the player's or next to it
; (diagonals too).  A leaf.

#addr 0x1300
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
    ld   inspect_action >> 8, y
    jmp  inspect_action
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
    ld   scw_r109, [x]
    ld   LINK_HI, x
    ld   scw_r109 >> 8, [x]
    ld   draw_panel >> 8, y
    jmp  draw_panel
scw_r109:
    ld   sc_leave >> 8, y
    jmp  sc_leave
up_2:
    ld   [dirty], ac
    and  2, ac
    beq  up_3
    clr  ac
    ld   ac, [dirty]
    ld   LINK_LO, x             ; CALL draw_msg
    ld   scw_r110, [x]
    ld   LINK_HI, x
    ld   scw_r110 >> 8, [x]
    ld   draw_msg >> 8, y
    jmp  draw_msg
scw_r110:
up_3:
    ld   [m_sel], ac
    xor  [o_sel], ac
    beq  up_e
    ld   LINK_LO, x             ; CALL draw_menu
    ld   scw_r111, [x]
    ld   LINK_HI, x
    ld   scw_r111 >> 8, [x]
    ld   draw_menu >> 8, y
    jmp  draw_menu
scw_r111:
up_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_panel - the whole panel
pwr_fetch:
    ld   s_pwrf & 0xFF, ac
    ld   ac, [R0]
    ld   s_pwrf >> 8, ac
    ld   ac, [R1]
    ld   PWR_LO >> 8, ac
    ld   ac, [u5]
    ld   3, ac
    ld   ac, [u6]
    ld   swap_fetch >> 8, y
    jmp  swap_fetch

; ini_fetch - SCRAP.INI into x4100-x44FF (2 sectors), for start

#addr 0x1400
door_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r102, [x]
    ld   LINK_HI, x
    ld   scw_r102 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r102:
    beq  dr_far
    ld   [s_f], ac              ; under 50 % health: stuck as it is
    sub  8, ac
    bcs  dr_go
    ld   s_jam & 0xFF, ac
    ld   ac, [R0]
    ld   s_jam >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r103, [x]
    ld   LINK_HI, x
    ld   scw_r103 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r103:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dr_go:
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
    ld   scw_r104, [x]
    ld   LINK_HI, x
    ld   scw_r104 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r104:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dr_ok:
    ld   T_DOOR, ac
dr_set:
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r105, [x]
    ld   LINK_HI, x
    ld   scw_r105 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r105:
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r106, [x]
    ld   LINK_HI, x
    ld   scw_r106 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r106:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r107, [x]
    ld   LINK_HI, x
    ld   scw_r107 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r107:
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
    ld   scw_r108, [x]
    ld   LINK_HI, x
    ld   scw_r108 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r108:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; set_msg - the message R1:R0 on row 29 for MSG_FRAMES.  A leaf.
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

#addr 0x1500
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
    ld   scw_r112, [x]
    ld   LINK_HI, x
    ld   scw_r112 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r112:
    clr  ac
    ld   ac, [n_act]
    ld   [s_who], ac
    beq  dp_m
    ld   LINK_LO, x             ; CALL subj_load
    ld   scw_r113, [x]
    ld   LINK_HI, x
    ld   scw_r113 >> 8, [x]
    ld   subj_load >> 8, y
    jmp  subj_load
scw_r113:
    ld   [s_who], ac
    beq  dp_m
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
    ld   scw_r114, [x]
    ld   LINK_HI, x
    ld   scw_r114 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r114:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r115, [x]
    ld   LINK_HI, x
    ld   scw_r115 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r115:
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_DMG, ac
    beq  dp_i
    ld   LINK_LO, x             ; CALL draw_dmg
    ld   scw_r116, [x]
    ld   LINK_HI, x
    ld   scw_r116 >> 8, [x]
    ld   draw_dmg >> 8, y
    jmp  draw_dmg
scw_r116:
dp_i:
    ld   [s_who], ac
    xor  2, ac
    bne  dp_c
    ld   LINK_LO, x             ; CALL draw_player
    ld   scw_r117, [x]
    ld   LINK_HI, x
    ld   scw_r117 >> 8, [x]
    ld   draw_player >> 8, y
    jmp  draw_player
scw_r117:
    bra  dp_m
dp_c:
    ld   LINK_LO, x             ; CALL draw_tags
    ld   scw_r118, [x]
    ld   LINK_HI, x
    ld   scw_r118 >> 8, [x]
    ld   draw_tags >> 8, y
    jmp  draw_tags
scw_r118:
    ld   LINK_LO, x             ; CALL draw_info
    ld   scw_r119, [x]
    ld   LINK_HI, x
    ld   scw_r119 >> 8, [x]
    ld   draw_info >> 8, y
    jmp  draw_info
scw_r119:
dp_m:
    ld   LINK_LO, x             ; CALL draw_menu
    ld   scw_r120, [x]
    ld   LINK_HI, x
    ld   scw_r120 >> 8, [x]
    ld   draw_menu >> 8, y
    jmp  draw_menu
scw_r120:
    ld   LINK_LO, x             ; CALL draw_msg
    ld   scw_r121, [x]
    ld   LINK_HI, x
    ld   scw_r121 >> 8, [x]
    ld   draw_msg >> 8, y
    jmp  draw_msg
scw_r121:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; subj_load - s_t, s_f, n_act and the action codes of the subject
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
ini_fetch:
    ld   s_inif & 0xFF, ac
    ld   ac, [R0]
    ld   s_inif >> 8, ac
    ld   ac, [R1]
    ld   INI_LO >> 8, ac
    ld   ac, [u5]
    ld   2, ac
    ld   ac, [u6]
    ld   swap_fetch >> 8, y
    jmp  swap_fetch

; PW_ST - bit 0 the power view is on, bit 1 SCRAP.PWR is in and the live
; conduits worked out (RB_VIS)

#addr 0x1600
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
    ld   scw_r122, [x]
    ld   LINK_HI, x
    ld   scw_r122 >> 8, [x]
    ld   player_acts >> 8, y
    jmp  player_acts
scw_r122:
    bra  sl_a
sl_c:
    ld   [s_who], ac
    xor  3, ac
    bne  sl_u
    ld   inv_load >> 8, y
    jmp  inv_load
sl_u:
    ld   [s_who], ac
    xor  4, ac
    bne  sl_m
    ld   under_load >> 8, y
    jmp  under_load
sl_m:
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_see
    ld   scw_r123, [x]
    ld   LINK_HI, x
    ld   scw_r123 >> 8, [x]
    ld   map_see >> 8, y
    jmp  map_see
scw_r123:
    ld   ac, [s_t]
    ld   [c_f], ac
    ld   ac, [s_f]
    ld   [c_r], ac
    ld   ac, [s_r]
    ld   [c_b], ac
    ld   ac, [s_b]
    ld   LINK_LO, x             ; CALL dyn_acts
    ld   scw_r124, [x]
    ld   LINK_HI, x
    ld   scw_r124 >> 8, [x]
    ld   dyn_acts >> 8, y
    jmp  dyn_acts
scw_r124:
sl_a:
    ld   [s_t], ac              ; ACT_PG: 4 t + i
    shl
    shl
    ld   ac, [u0]
sl_l:
    ld   [n_act], ac
    xor  8, ac
    beq  sl_e
    ld   ACTS_PG, y
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
    ld   scw_r227, [x]
    ld   LINK_HI, x
    ld   scw_r227 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r227:
ds_e:
    ld   dyn_rep >> 8, y
    jmp  dyn_rep

; air_crack - a link that is not open (v1:v2 its type byte, v3 its type):
; from 50 % damage it leaks, a unit a tick toward the lower side; to
; vacuum (room 0, a hull breach) an eighth of the room's air and one.  The rest of air_tick's loop (its v0)

#addr 0x1700
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
    ld   A_INSTALL, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r125, [x]
    ld   LINK_HI, x
    ld   scw_r125 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r125:
dy_pk:
    ld   A_PICK, ac
dy_a:
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r126, [x]
    ld   LINK_HI, x
    ld   scw_r126 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r126:
dy_o:
    ld   [s_t], ac
    xor  T_O2, ac
    bne  dy_f
    ld   A_REFILL, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r127, [x]
    ld   LINK_HI, x
    ld   scw_r127 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r127:
dy_f:
    ld   [s_t], ac              ; a deck or a conduit: PUT DOWN
    xor  T_FLOOR, ac
    beq  dy_p
    ld   [s_t], ac
    xor  T_PIPE, ac
    bne  dy_e
dy_p:
    ld   [cl_t], ac
    beq  dy_1
    ld   A_PUTL, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r128, [x]
    ld   LINK_HI, x
    ld   scw_r128 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r128:
dy_1:
    ld   [cr_t], ac
    beq  dy_2
    ld   A_PUTR, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r129, [x]
    ld   LINK_HI, x
    ld   scw_r129 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r129:
dy_2:
    ld   [cb_t], ac
    beq  dy_e
    ld   A_PUTB, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r130, [x]
    ld   LINK_HI, x
    ld   scw_r130 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r130:
dy_e:
    ld   dyn_struct >> 8, y
    jmp  dyn_struct

; add_act - AC = an action code, added to the subject's list (8 at most).
; A leaf.
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
    ld   scw_r164, [x]
    ld   LINK_HI, x
    ld   scw_r164 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r164:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
ac_x:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; clk_tick - the ship's clock a second on.  A leaf.

#addr 0x1800
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
    ld   scw_r131, [x]
    ld   LINK_HI, x
    ld   scw_r131 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r131:
    ld   BAR_PG, ac
    ld   ac, [u5]
    ld   [s_f], ac
    ld   ac, [u6]
    add  16, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r132, [x]
    ld   LINK_HI, x
    ld   scw_r132 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r132:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r133, [x]
    ld   LINK_HI, x
    ld   scw_r133 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r133:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r134, [x]
    ld   LINK_HI, x
    ld   scw_r134 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r134:
    ld   ROOM_PG, ac
    ld   ac, [u5]
    ld   [s_f], ac
    add  TB_DMGL, ac
    ld   ac, [u6]
    ld   [s_f], ac
    add  TB_DMGH, ac
    ld   ac, [u7]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r135, [x]
    ld   LINK_HI, x
    ld   scw_r135 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r135:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r136, [x]
    ld   LINK_HI, x
    ld   scw_r136 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r136:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_info - the subject's 4 info lines, rows 25-28 from column 1
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
    ld   [s_t], ac              ; its text from the card (prt_load)
    ld   LINK_LO, x             ; CALL prt_load
    ld   scw_r137, [x]
    ld   LINK_HI, x
    ld   scw_r137 >> 8, [x]
    ld   prt_load >> 8, y
    jmp  prt_load
scw_r137:
    clr  ac
    ld   ac, [w2]
di_l:
    ld   [w2], ac
    add  25, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   [s_t], ac              ; line w2: PRT_BUF + 256 (t & 1) + 48 w2
    and  1, ac
    add  PRT_BUF >> 8, ac
    ld   ac, [R1]
    ld   [w2], ac
    shl
    shl
    shl
    shl
    ld   ac, [R0]
    shl
    add  [R0], ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r138, [x]
    ld   LINK_HI, x
    ld   scw_r138 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r138:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    xor  4, ac
    bne  di_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_menu - the actions, two columns on rows 25-28 from column 42 (the
; one under the pointer in inverse)
on_space:
    add  TB_SKILL, x
    ld   ACT_PG, y
    ld   [y,x], ac
    and  0xC0, ac
    xor  0x40, ac
    beq  os_y
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
os_y:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; adj_kind - AC = a kind: 1 when one is installed and working (under 50 %
; damage) on a side of cell v0, v1 (tug_scan's), else 0.  T6, T7
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
    ld   scw_r140, [x]
    ld   LINK_HI, x
    ld   scw_r140 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r140:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r141, [x]
    ld   LINK_HI, x
    ld   scw_r141 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r141:
    ld   [w2], ac
    ld   LINK_LO, x             ; CALL menu_item
    ld   scw_r142, [x]
    ld   LINK_HI, x
    ld   scw_r142 >> 8, [x]
    ld   menu_item >> 8, y
    jmp  menu_item
scw_r142:
    ld   [w2], ac
    add  4, ac
    ld   LINK_LO, x             ; CALL menu_item
    ld   scw_r143, [x]
    ld   LINK_HI, x
    ld   scw_r143 >> 8, [x]
    ld   menu_item >> 8, y
    jmp  menu_item
scw_r143:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; menu_item - action AC at the cursor: " 1: OPEN" (its key, its name) in
; 18 columns, inverse under the pointer; blank past n_act
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
    ld   scw_r152, [x]
    ld   LINK_HI, x
    ld   scw_r152 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r152:
    ld   [msg_t], ac
    bne  dm_on
    ld   [stage], ac
    beq  dm_off
    ld   draw_warn >> 8, y
    jmp  draw_warn
dm_on:
    ld   TINT_MSG | 0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r153, [x]
    ld   LINK_HI, x
    ld   scw_r153 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r153:
    ld   29, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   [msg_l], ac
    ld   ac, [R0]
    ld   [msg_h], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r154, [x]
    ld   LINK_HI, x
    ld   scw_r154 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r154:
    ld   [cut_t], ac
    beq  dm_x
    ld   [cut_m], ac            ; a repair: the health bar shows it
    xor  3, ac
    beq  dm_x
    ld   LINK_LO, x             ; CALL job_bar
    ld   scw_r155, [x]
    ld   LINK_HI, x
    ld   scw_r155 >> 8, [x]
    ld   job_bar >> 8, y
    jmp  job_bar
scw_r155:
dm_x:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dm_off:
    ld   draw_alarm >> 8, y
    jmp  draw_alarm

; msg_tint - AC = the mode byte of row 29's lines (x5BF0-x5BFF).  A leaf.
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

#addr 0x1A00
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
    ld   scw_r144, [x]
    ld   LINK_HI, x
    ld   scw_r144 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r144:
    ld   [w4], ac
    add  0x31, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r145, [x]
    ld   LINK_HI, x
    ld   scw_r145 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r145:
    ld   0x3A, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r146, [x]
    ld   LINK_HI, x
    ld   scw_r146 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r146:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r147, [x]
    ld   LINK_HI, x
    ld   scw_r147 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r147:
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
    ld   scw_r148, [x]
    ld   LINK_HI, x
    ld   scw_r148 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r148:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r149, [x]
    ld   LINK_HI, x
    ld   scw_r149 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r149:
mi_pad:
    ld   [CUR_COL], ac
    xor  [w5], ac
    beq  mi_e
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r150, [x]
    ld   LINK_HI, x
    ld   scw_r150 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r150:
    bra  mi_pad
mi_e:
    clr  ac
    ld   ac, [p_inv]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pad80 - spaces to the end of the text row
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
    blt  ta_2a34
    shl                         ; rows 14-29: 16 (r - 14) + 1
    shl
    shl
    shl
    inc
    ld   ac, [p_off]
    bra  ta_go34
ta_2a34:
    add  16, ac                 ; rows 0-13: 16 r + 32
    shl
    shl
    shl
    shl
    ld   ac, [p_off]
ta_go34:
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
    ld   scw_r156, [x]
    ld   LINK_HI, x
    ld   scw_r156 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r156:
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
    ld   ROOM_PG, y
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
    ld   scw_r157, [x]
    ld   LINK_HI, x
    ld   scw_r157 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r157:
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

; game_tick - once a frame: cutting, the air (every 8 frames), the suit
; (every second)
ty_ant:
    ld   [c_t], ac
    ld   LINK_LO, x             ; CALL kind_base
    ld   scw_r308, [x]
    ld   LINK_HI, x
    ld   scw_r308 >> 8, [x]
    ld   kind_base >> 8, y
    jmp  kind_base
scw_r308:
    xor  T_ANT, ac
    bne  ta_n
    ld   N_ANT >> 8, y
    ld   N_ANT & 0xFF, x
    ld   1, [y,x]
ta_n:
    ld   ty_n >> 8, y
    jmp  ty_n

; kind_base - AC = a kind; AC = the plain part of a facing kind (FACE0 + 3
; on: 3 kinds back until it is one of the first three).  A leaf.

#addr 0x1C00
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
    ld   LINK_LO, x             ; the flight, every frame
    ld   scw_r158, [x]
    ld   LINK_HI, x
    ld   scw_r158 >> 8, [x]
    ld   fl_tick >> 8, y
    jmp  fl_tick
scw_r158:
    ld   [cut_t], ac
    beq  gt_1
    ld   LINK_LO, x             ; CALL work_tick
    ld   scw_r159, [x]
    ld   LINK_HI, x
    ld   scw_r159 >> 8, [x]
    ld   work_tick >> 8, y
    jmp  work_tick
scw_r159:
gt_1:
    ld   [air_t], ac
    inc
    and  7, ac
    ld   ac, [air_t]
    bne  gt_2
    ld   LINK_LO, x             ; CALL air_tick
    ld   scw_r160, [x]
    ld   LINK_HI, x
    ld   scw_r160 >> 8, [x]
    ld   air_tick >> 8, y
    jmp  air_tick
scw_r160:
    ld   LINK_LO, x             ; CALL fl_check
    ld   scw_r161, [x]
    ld   LINK_HI, x
    ld   scw_r161 >> 8, [x]
    ld   fl_check >> 8, y
    jmp  fl_check
scw_r161:
gt_2:
    ld   [sec_t], ac
    inc
    ld   ac, [sec_t]
    xor  60, ac
    bne  gt_e
    ld   ac, [sec_t]            ; AC = 0
    ld   LINK_LO, x             ; CALL second_tick
    ld   scw_r162, [x]
    ld   LINK_HI, x
    ld   scw_r162 >> 8, [x]
    ld   second_tick >> 8, y
    jmp  second_tick
scw_r162:
gt_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; air_tick - open doors and the airlocks share their rooms' air (the
; average), then air_leak
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
    and  0x3F, ac
    ld   ac, [v3]
    xor  T_DOORO, ac
    beq  at_o
    ld   [v3], ac
    xor  T_LOCK, ac
    beq  at_o
    ld   LINK_LO, x             ; a closed door or a wall: leaks if broken
    ld   scw_r163, [x]
    ld   LINK_HI, x
    ld   scw_r163 >> 8, [x]
    ld   air_crack >> 8, y
    jmp  air_crack
scw_r163:
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

#addr 0x1D00
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
    ld   LINK_LO, x             ; CALL clk_tick
    ld   scw_r165, [x]
    ld   LINK_HI, x
    ld   scw_r165 >> 8, [x]
    ld   clk_tick >> 8, y
    jmp  clk_tick
scw_r165:
    ld   LINK_LO, x             ; CALL tug_scan
    ld   scw_r166, [x]
    ld   LINK_HI, x
    ld   scw_r166 >> 8, [x]
    ld   tug_scan >> 8, y
    jmp  tug_scan
scw_r166:
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
    ld   scw_r167, [x]
    ld   LINK_HI, x
    ld   scw_r167 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r167:
    ld   ROOM_P >> 8, y
    ld   [c_r], x
    ld   [y,x], ac
    sub  BREATHE_P, ac
    bcc  st_air
    ld   [o2], ac               ; no air: the suit's, a litre every O2_SECS
    beq  st_g
    ld   O2_T >> 8, y
    ld   O2_T & 0xFF, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    sub  O2_SECS, ac
    bcs  st_g
    clr  ac
    ld   ac, [y,x]
    ld   [o2], ac
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

#addr 0x1E00
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
work_end:
    ld   PW_ST >> 8, y          ; the power view: a part's power may have
    ld   PW_ST & 0xFF, x        ;   changed, worked out and drawn again
    ld   [y,x], ac
    and  1, ac
    ld   ac, [y,x]
    or   [rb_go], ac
    beq  we_t
    ld   [inv], ac              ; in the inventory: when it closes
    bne  we_t                   ;   (rooms_build's space holds SCRAP.INV)
    ld   FL_PG, y               ;   (or SCRAP.NAV)
    ld   FL_NAV, x
    ld   [y,x], ac
    bne  we_t
    ld   [rb_go], ac
    beq  we_v
    ld   LINK_LO, x             ; CALL rooms_build
    ld   scw_r205, [x]
    ld   LINK_HI, x
    ld   scw_r205 >> 8, [x]
    ld   rooms_build >> 8, y
    jmp  rooms_build
scw_r205:
    clr  ac
    ld   ac, [rb_go]
we_v:
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r206, [x]
    ld   LINK_HI, x
    ld   scw_r206 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r206:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r207, [x]
    ld   LINK_HI, x
    ld   scw_r207 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r207:
we_t:
    ld   LINK_LO, x             ; CALL tug_scan
    ld   scw_r208, [x]
    ld   LINK_HI, x
    ld   scw_r208 >> 8, [x]
    ld   tug_scan >> 8, y
    jmp  tug_scan
scw_r208:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; cut_pay - a cut's battery (cut_m 0).  A leaf.
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

; set_room - AC = the room of the cell map_get last found (type byte bit
; 6: room bit 4; flag byte bits 7-4: room bits 3-0).  A leaf.
pw_toggle:
    ld   PW_ST >> 8, y          ; (worked out again each time)
    ld   PW_ST & 0xFF, x
    ld   [y,x], ac
    xor  1, ac
    and  1, ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r351, [x]
    ld   LINK_HI, x
    ld   scw_r351 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r351:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pw_over - the power view over the cell view_cell drew (ov_cell): first
; SCRAP.PWR read in again and the live conduits worked out, when
; rooms_build or a swap file has been over them since (PW_ST bit 1 off)

#addr 0x2000
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
    ld   LINK_LO, x             ; nothing counted yet
    ld   scw_r168, [x]
    ld   LINK_HI, x
    ld   scw_r168 >> 8, [x]
    ld   fl_scan0 >> 8, y
    jmp  fl_scan0
scw_r168:
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
    ld   scw_r169, [x]
    ld   LINK_HI, x
    ld   scw_r169 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r169:
    beq  ty_n                   ; open space: nothing (quick: most cells)
    ld   ac, x                  ; a loose part is not part of the tug
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    beq  ty_i
    ld   [c_b], ac
    beq  ty_n
ty_i:
    ld   LINK_LO, x             ; its mass, a working thruster
    ld   scw_r170, [x]
    ld   LINK_HI, x
    ld   scw_r170 >> 8, [x]
    ld   tug_mass >> 8, y
    jmp  tug_mass
scw_r170:
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
    ld   [c_t], ac              ; an O2 tank counts with a pump by it
    xor  T_O2, ac
    bne  ty_1
    ld   T_PUMP, ac
    ld   LINK_LO, x             ; CALL adj_kind
    ld   scw_r171, [x]
    ld   LINK_HI, x
    ld   scw_r171 >> 8, [x]
    ld   adj_kind >> 8, y
    jmp  adj_kind
scw_r171:
    beq  ty_o
    ld   [n_o2], ac
    inc
    ld   ac, [n_o2]
ty_o:
    ld   ty_n >> 8, y
    jmp  ty_n
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
    xor  T_FUEL, ac             ; a nitrogen tank with an intake by it: fuel
    bne  ty_4
    ld   T_INTAKE, ac
    ld   LINK_LO, x             ; CALL adj_kind
    ld   scw_r172, [x]
    ld   LINK_HI, x
    ld   scw_r172 >> 8, [x]
    ld   adj_kind >> 8, y
    jmp  adj_kind
scw_r172:
    beq  ty_o
    ld   [n_fuel], ac
    inc
    ld   ac, [n_fuel]
    ld   ty_n >> 8, y
    jmp  ty_n
ty_4:
    ld   ty_ant >> 8, y
    jmp  ty_ant
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

#addr 0x2100
pick_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r173, [x]
    ld   LINK_HI, x
    ld   scw_r173 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r173:
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
    ld   scw_r174, [x]
    ld   LINK_HI, x
    ld   scw_r174 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r174:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pk_s:
    ld   [s_t], ac
    ld   LINK_LO, x             ; a facing part: the plain one
    ld   scw_r175, [x]
    ld   LINK_HI, x
    ld   scw_r175 >> 8, [x]
    ld   kind_base >> 8, y
    jmp  kind_base
scw_r175:
    ld   [v0], x
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
    ld   scw_r176, [x]
    ld   LINK_HI, x
    ld   scw_r176 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r176:
    ld   LINK_LO, x             ; the deck, or the conduit, under it
    ld   scw_r177, [x]
    ld   LINK_HI, x
    ld   scw_r177 >> 8, [x]
    ld   cb_get >> 8, y
    jmp  cb_get
scw_r177:
    beq  pk_fl
    ld   T_PIPE, ac
    bra  pk_pt
pk_fl:
    ld   T_FLOOR, ac
pk_pt:
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r178, [x]
    ld   LINK_HI, x
    ld   scw_r178 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r178:
    clr  ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r179, [x]
    ld   LINK_HI, x
    ld   scw_r179 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r179:
    ld   act_done >> 8, y
    jmp  act_done
pk_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r180, [x]
    ld   LINK_HI, x
    ld   scw_r180 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r180:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; act_done - the cell g_x, g_y drawn again, the panel too.  The end of an
; action (do_action's LEAVE).
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
    ld   PW_ST >> 8, y          ; (over SCRAP.PWR and the live bits)
    ld   PW_ST & 0xFF, x
    ld   [y,x], ac
    and  1, ac
    ld   ac, [y,x]
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
put_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r182, [x]
    ld   LINK_HI, x
    ld   scw_r182 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r182:
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
    ld   scw_r183, [x]
    ld   LINK_HI, x
    ld   scw_r183 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r183:
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
    ld   scw_r184, [x]
    ld   LINK_HI, x
    ld   scw_r184 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r184:
    ld   LINK_LO, x             ; CALL deck_ok
    ld   scw_r185, [x]
    ld   LINK_HI, x
    ld   scw_r185 >> 8, [x]
    ld   deck_ok >> 8, y
    jmp  deck_ok
scw_r185:
    beq  pu_d
    xor  2, ac                  ; a broken deck: the message
    bne  pu_e
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r186, [x]
    ld   LINK_HI, x
    ld   scw_r186 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r186:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pu_d:
    ld   [v0], x
    ld   [x], ac
    beq  pu_e
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r187, [x]
    ld   LINK_HI, x
    ld   scw_r187 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r187:
    ld   [v0], ac
    add  3, x
    ld   [x], ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r188, [x]
    ld   LINK_HI, x
    ld   scw_r188 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r188:
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
    ld   scw_r189, [x]
    ld   LINK_HI, x
    ld   scw_r189 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r189:
pu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; cut_action - CUT FREE: needs a working cutter in a hand and battery;
; cutting takes CUT_FRAMES (cut_done).  The rest of do_action.
set_room:
    ld   ac, [u0]
    ld   [a_pg], y
    ld   [a_ix], x
    ld   [y,x], ac
    and  0xBF, ac
    ld   ac, [u1]
    ld   [u0], ac
    and  0x10, ac
    shl
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
    ld   scw_r315, [x]
    ld   LINK_HI, x
    ld   scw_r315 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r315:
dq_e:
    ld   dyn_nav >> 8, y
    jmp  dyn_nav

; player_acts - the player's menu: SKILLS, then TAKE OFF SUIT, or PUT ON
; SUIT with the suit in a carry slot

#addr 0x2300
cut_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r190, [x]
    ld   LINK_HI, x
    ld   scw_r190 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r190:
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
    ld   scw_r191, [x]
    ld   LINK_HI, x
    ld   scw_r191 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r191:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cu_ok:
    ld   LINK_LO, x             ; CALL plate_room
    ld   scw_r192, [x]
    ld   LINK_HI, x
    ld   scw_r192 >> 8, [x]
    ld   plate_room >> 8, y
    jmp  plate_room
scw_r192:
    beq  cu_e
    ld   [batt], ac
    sub  CUT_BATT, ac
    bcs  cu_nb
    clr  ac
    ld   ac, [cut_m]
    ld   CUT_FRAMES, ac
    ld   LINK_LO, x             ; CALL job_start
    ld   scw_r193, [x]
    ld   LINK_HI, x
    ld   scw_r193 >> 8, [x]
    ld   job_start >> 8, y
    jmp  job_start
scw_r193:
    ld   [s_x], ac
    ld   ac, [cut_x]
    ld   [s_y], ac
    ld   ac, [cut_y]
    ld   s_cutting & 0xFF, ac
    ld   ac, [R0]
    ld   s_cutting >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r194, [x]
    ld   LINK_HI, x
    ld   scw_r194 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r194:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cu_nb:
    ld   s_nobatt & 0xFF, ac
    ld   ac, [R0]
    ld   s_nobatt >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r195, [x]
    ld   LINK_HI, x
    ld   scw_r195 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r195:
cu_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cu_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r196, [x]
    ld   LINK_HI, x
    ld   scw_r196 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r196:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; cut_done - the part at cut_x, cut_y is cut free (the battery pays),
; installed or uninstalled (cut_m); a wall, deck or door of the ship is
; taken out (struct_done); a wall panel or door installed is a wall or
; door again.  Then the rooms (if the ship changed) and the tug again
rl_set:
    ld   [rb_cx], ac
    ld   ac, [g_x]
    ld   [rb_cy], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r249, [x]
    ld   LINK_HI, x
    ld   scw_r249 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r249:
    ld   [v6], ac
    ld   LINK_LO, x             ; CALL set_room
    ld   scw_r250, [x]
    ld   LINK_HI, x
    ld   scw_r250 >> 8, [x]
    ld   set_room >> 8, y
    jmp  set_room
scw_r250:
    ld   [rb_x], ac
    inc
    ld   ac, [rb_x]
    ld   rl_l >> 8, y
    jmp  rl_l

; rl_side - AC = the room of neighbour rb_k of the link cell: 0 vacuum or
; the edge, xFF a solid cell.  An airlock there (two docked side by side):
; the cell past it.  Uses rb_y, rb_t, v3 (free in rb_links).
fl_add24:
    ld   ac, [T0]
    ld   [w1], ac
    ld   ac, [T1]
    ld   2, ac
    ld   ac, [T2]
    bra  fa4_n
fl_addp:
    ld   ac, [T0]
    ld   [w1], ac
    ld   ac, [T1]
    ld   3, ac
    ld   ac, [T2]
fa4_n:
    ld   4, ac
    ld   ac, [T3]
    ld   fl_add >> 8, y
    jmp  fl_add

; fl_add - T2 bytes at FL_PG + T1 (signed: the top one's sign carried on)
; added into T3 bytes at FL_PG + T0 (low first).  A leaf; T0-T7.

#addr 0x2400
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
    ld   scw_r197, [x]
    ld   LINK_HI, x
    ld   scw_r197 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r197:
    ld   [cut_m], ac
    sub  3, ac
    bcs  cd_0
    ld   repair_done >> 8, y    ; (and 4, placing)
    jmp  repair_done
cd_0:
    ld   [c_t], ac              ; a thruster, antenna, radar: out to a slot
    ld   LINK_LO, x             ; CALL on_space
    ld   scw_r198, [x]
    ld   LINK_HI, x
    ld   scw_r198 >> 8, [x]
    ld   on_space >> 8, y
    jmp  on_space
scw_r198:
    bne  cd_th
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_STRUCT, ac
    beq  cd_i
cd_th:
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
    bne  cd_k2
    ld   T_DOOR, ac
    bra  cd_s
cd_k2:
    ld   [c_t], ac
    xor  T_COND, ac
    bne  cd_b
    ld   LINK_LO, x             ; (its bit)
    ld   scw_r199, [x]
    ld   LINK_HI, x
    ld   scw_r199 >> 8, [x]
    ld   cb_set >> 8, y
    jmp  cb_set
scw_r199:
    ld   T_PIPE, ac
cd_s:
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r200, [x]
    ld   LINK_HI, x
    ld   scw_r200 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r200:
    ld   1, ac
    ld   ac, [rb_go]
    bra  cd_im
cd_b:
    ld   [c_t], ac              ; a part: bolted
    or   0x80, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r201, [x]
    ld   LINK_HI, x
    ld   scw_r201 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r201:
cd_im:
    ld   s_instdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_instdone >> 8, ac
    bra  cd_m
cd_f:
    ld   [c_t], ac
    ld   LINK_LO, x             ; the same type, not bolted
    ld   scw_r202, [x]
    ld   LINK_HI, x
    ld   scw_r202 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r202:
    ld   [cut_m], ac
    beq  cd_c
    ld   s_uninstdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_uninstdone >> 8, ac
    bra  cd_m
cd_c:
    ld   LINK_LO, x             ; CALL cut_pay
    ld   scw_r203, [x]
    ld   LINK_HI, x
    ld   scw_r203 >> 8, [x]
    ld   cut_pay >> 8, y
    jmp  cut_pay
scw_r203:
    ld   s_cutdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_cutdone >> 8, ac
cd_m:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r204, [x]
    ld   LINK_HI, x
    ld   scw_r204 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r204:
    ld   work_end >> 8, y
    jmp  work_end

; work_end - the rooms again if the ship changed (rb_go), the tug, the
; panel.  The end of cut_done (its LEAVE).

#addr 0x2500
struct_done:
    ld   1, ac
    ld   ac, [rb_go]
    ld   [c_t], ac
    xor  T_FLOOR, ac
    beq  sd_f
    ld   [c_t], ac
    ld   LINK_LO, x             ; CALL on_space
    ld   scw_r209, [x]
    ld   LINK_HI, x
    ld   scw_r209 >> 8, [x]
    ld   on_space >> 8, y
    jmp  on_space
scw_r209:
    bne  sd_f
    ld   [c_t], ac
    xor  T_PIPE, ac
    bne  sd_w
    ld   LINK_LO, x             ; a conduit: its section, on the deck
    ld   scw_r210, [x]
    ld   LINK_HI, x
    ld   scw_r210 >> 8, [x]
    ld   cb_clr >> 8, y
    jmp  cb_clr
scw_r210:
    ld   T_COND, ac
    bra  sd_p
sd_w:
    ld   [c_t], ac
    xor  T_WALL, ac
    bne  sd_d
    ld   T_PANEL, ac
    bra  sd_p
sd_d:
    ld   T_DOORK, ac            ; a door, open or closed
sd_p:
    ld   LINK_LO, x             ; loose, its damage kept
    ld   scw_r211, [x]
    ld   LINK_HI, x
    ld   scw_r211 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r211:
    bra  sd_m
sd_f:
    ld   LINK_LO, x             ; CALL free_slot
    ld   scw_r212, [x]
    ld   LINK_HI, x
    ld   scw_r212 >> 8, [x]
    ld   free_slot >> 8, y
    jmp  free_slot
scw_r212:
    beq  sd_full
    ld   ac, [v0]
    ld   [c_t], ac              ; a deck: its plate; a part on open space itself
    xor  T_FLOOR, ac
    beq  sd_pp
    ld   [c_t], ac
    bra  sd_st
sd_pp:
    ld   T_PLATE, ac
sd_st:
    ld   [v0], x
    ld   ac, [x]
    ld   [v0], ac
    add  3, x
    ld   [c_f], ac
    ld   ac, [x]
    ld   T_SPACE, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r213, [x]
    ld   LINK_HI, x
    ld   scw_r213 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r213:
    clr  ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r214, [x]
    ld   LINK_HI, x
    ld   scw_r214 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r214:
sd_m:
    ld   [cut_m], ac
    bne  sd_u
    ld   LINK_LO, x             ; CALL cut_pay
    ld   scw_r215, [x]
    ld   LINK_HI, x
    ld   scw_r215 >> 8, [x]
    ld   cut_pay >> 8, y
    jmp  cut_pay
scw_r215:
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
    ld   scw_r216, [x]
    ld   LINK_HI, x
    ld   scw_r216 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r216:
    ld   work_end >> 8, y
    jmp  work_end
sd_full:
    ld   s_full & 0xFF, ac
    ld   ac, [R0]
    ld   s_full >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r217, [x]
    ld   LINK_HI, x
    ld   scw_r217 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r217:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; free_slot - AC = the first empty carry slot's address (cl_t, cr_t,
; cb_t), 0 none.  A leaf.
fl_burn2:
    ld   FL_PG, y
    ld   FL_FLL, x
    ld   [y,x], ac
    bne  fb_2
    ld   FL_FLH, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    ld   FL_FLL, x
    ld   [y,x], ac
fb_2:
    dec
    ld   ac, [y,x]
fb_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tug_mass - tug_scan's: the mass of kind c_t added in, and a working
; thruster (c_f under 8) counted.  A leaf.

#addr 0x2600
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
    beq  pr_c
    ld   [s_t], ac
    ld   LINK_LO, x             ; CALL kind_base
    ld   scw_r218, [x]
    ld   LINK_HI, x
    ld   scw_r218 >> 8, [x]
    ld   kind_base >> 8, y
    jmp  kind_base
scw_r218:
    xor  T_THRUST, ac
    bne  pr_ok
pr_c:
    ld   LINK_LO, x             ; CALL free_slot
    ld   scw_r219, [x]
    ld   LINK_HI, x
    ld   scw_r219 >> 8, [x]
    ld   free_slot >> 8, y
    jmp  free_slot
scw_r219:
    bne  pr_ok
    ld   s_full & 0xFF, ac
    ld   ac, [R0]
    ld   s_full >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r220, [x]
    ld   LINK_HI, x
    ld   scw_r220 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r220:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
pr_ok:
    ld   1, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; lay_action - LAY DECK PLATE: a carried deck plate onto the open space
; the panel shows, next to the player.  The rest of do_action.
lay_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r221, [x]
    ld   LINK_HI, x
    ld   scw_r221 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r221:
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
    ld   scw_r222, [x]
    ld   LINK_HI, x
    ld   scw_r222 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r222:
    ld   T_FLOOR, ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r223, [x]
    ld   LINK_HI, x
    ld   scw_r223 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r223:
    ld   [v0], ac
    add  3, x
    ld   [x], ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r224, [x]
    ld   LINK_HI, x
    ld   scw_r224 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r224:
    ld   [v0], x
    clr  ac
    ld   ac, [x]
    ld   s_laid & 0xFF, ac
    ld   ac, [R0]
    ld   s_laid >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r225, [x]
    ld   LINK_HI, x
    ld   scw_r225 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r225:
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
    ld   scw_r226, [x]
    ld   LINK_HI, x
    ld   scw_r226 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r226:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dyn_struct - the ship's own cells (not the player's): UNINSTALL (by hand
; on the tug, with the cutter in a wreck); LAY DECK PLATE on open space with a plate in
; a carry slot.  The rest of dyn_acts.

#addr 0x2700
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
    ld   ROOM_P >> 8, y         ; a hull breach: an eighth and one
    ld   [v4], x
    ld   [y,x], ac
    ld   ac, [v6]
    shr  ac
    shr  ac
    shr  ac
    inc
    ld   ac, [v7]
    ld   [v6], ac
    sub  [v7], ac
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
    ld   scw_r232, [x]
    ld   LINK_HI, x
    ld   scw_r232 >> 8, [x]
    ld   set_room >> 8, y
    jmp  set_room
scw_r232:
rs_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; rb_fill - the room rb_n from the cells on the stack: each cell's old
; pressure summed, its room set, its neighbours (rb_nbs)

#addr 0x2800
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
    ld   scw_r228, [x]
    ld   LINK_HI, x
    ld   scw_r228 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r228:
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_SOLID, ac
    beq  rb_air
    ld   LINK_LO, x             ; CALL rb_solid
    ld   scw_r229, [x]
    ld   LINK_HI, x
    ld   scw_r229 >> 8, [x]
    ld   rb_solid >> 8, y
    jmp  rb_solid
scw_r229:
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
    ld   [rb_n], ac             ; a new room (31 at most: more share 31)
    xor  31, ac
    beq  rb_f
    ld   [rb_n], ac
    inc
    ld   ac, [rb_n]
rb_f:
    ld   LINK_LO, x             ; CALL rb_push
    ld   scw_r230, [x]
    ld   LINK_HI, x
    ld   scw_r230 >> 8, [x]
    ld   rb_push >> 8, y
    jmp  rb_push
scw_r230:
    ld   LINK_LO, x             ; CALL rb_fill
    ld   scw_r231, [x]
    ld   LINK_HI, x
    ld   scw_r231 >> 8, [x]
    ld   rb_fill >> 8, y
    jmp  rb_fill
scw_r231:
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
    ld   scw_r233, [x]
    ld   LINK_HI, x
    ld   scw_r233 >> 8, [x]
    ld   rb_pop >> 8, y
    jmp  rb_pop
scw_r233:
    beq  rf_e
    ld   [rb_cx], ac
    ld   ac, [g_x]
    ld   [rb_cy], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r234, [x]
    ld   LINK_HI, x
    ld   scw_r234 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r234:
    ld   LINK_LO, x             ; CALL rb_acc
    ld   scw_r235, [x]
    ld   LINK_HI, x
    ld   scw_r235 >> 8, [x]
    ld   rb_acc >> 8, y
    jmp  rb_acc
scw_r235:
    ld   [rb_n], ac
    ld   LINK_LO, x             ; CALL set_room
    ld   scw_r236, [x]
    ld   LINK_HI, x
    ld   scw_r236 >> 8, [x]
    ld   set_room >> 8, y
    jmp  set_room
scw_r236:
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

#addr 0x2900
rb_nbs:
rn_l:
    ld   LINK_LO, x             ; CALL rb_nb
    ld   scw_r237, [x]
    ld   LINK_HI, x
    ld   scw_r237 >> 8, [x]
    ld   rb_nb >> 8, y
    jmp  rb_nb
scw_r237:
    bne  rn_in
    ld   LINK_LO, x             ; CALL rb_leak
    ld   scw_r238, [x]
    ld   LINK_HI, x
    ld   scw_r238 >> 8, [x]
    ld   rb_leak >> 8, y
    jmp  rb_leak
scw_r238:
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
    ld   scw_r239, [x]
    ld   LINK_HI, x
    ld   scw_r239 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r239:
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    ld   ac, [v1]
    and  F_VAC, ac
    beq  rn_s
    ld   LINK_LO, x             ; CALL rb_leak
    ld   scw_r240, [x]
    ld   LINK_HI, x
    ld   scw_r240 >> 8, [x]
    ld   rb_leak >> 8, y
    jmp  rb_leak
scw_r240:
rn_s:
    ld   [v1], ac
    and  F_SOLID, ac
    bne  rn_k
    ld   LINK_LO, x             ; CALL rb_push
    ld   scw_r241, [x]
    ld   LINK_HI, x
    ld   scw_r241 >> 8, [x]
    ld   rb_push >> 8, y
    jmp  rb_push
scw_r241:
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
fl_max:
    ld   [u1], ac
    sub  [w1], ac
    blt  mx_e
    bne  mx_u
    ld   [u0], ac
    sub  [w0], ac
    bcs  mx_e
mx_u:
    ld   [u0], ac
    ld   ac, [w0]
    ld   [u1], ac
    ld   ac, [w1]
mx_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_rel - FL_DX, FL_DY = the KESTREL 9's centre less the tug's position
; (metres, signed), w1:w0 = the gap to its hull: the larger of |dx| and
; |dy|, less WRECK_BOX (signed: under 0 inside)

#addr 0x2A00
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
    ld   scw_r242, [x]
    ld   LINK_HI, x
    ld   scw_r242 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r242:
    ld   [a_pg], ac
    ld   ac, [v1]
    ld   [a_ix], ac
    ld   ac, [v2]
    clr  ac
    ld   ac, [v6]
    ld   1, ac                  ; left and right
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r243, [x]
    ld   LINK_HI, x
    ld   scw_r243 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r243:
    ld   ac, [v4]
    clr  ac
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r244, [x]
    ld   LINK_HI, x
    ld   scw_r244 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r244:
    ld   ac, [v3]
    ld   LINK_LO, x             ; CALL rl_add
    ld   scw_r245, [x]
    ld   LINK_HI, x
    ld   scw_r245 >> 8, [x]
    ld   rl_add >> 8, y
    jmp  rl_add
scw_r245:
    ld   3, ac                  ; up and down
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r246, [x]
    ld   LINK_HI, x
    ld   scw_r246 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r246:
    ld   ac, [v4]
    ld   2, ac
    ld   ac, [rb_k]
    ld   LINK_LO, x             ; CALL rl_side
    ld   scw_r247, [x]
    ld   LINK_HI, x
    ld   scw_r247 >> 8, [x]
    ld   rl_side >> 8, y
    jmp  rl_side
scw_r247:
    ld   ac, [v3]
    ld   LINK_LO, x             ; CALL rl_add
    ld   scw_r248, [x]
    ld   LINK_HI, x
    ld   scw_r248 >> 8, [x]
    ld   rl_add >> 8, y
    jmp  rl_add
scw_r248:
    ld   rl_set >> 8, y
    jmp  rl_set

; rl_set - the link cell's room (v6).  Back to rb_links' loop.

#addr 0x2B00
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
    ld   scw_r251, [x]
    ld   LINK_HI, x
    ld   scw_r251 >> 8, [x]
    ld   rb_nb >> 8, y
    jmp  rb_nb
scw_r251:
    beq  sd_0
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r252, [x]
    ld   LINK_HI, x
    ld   scw_r252 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r252:
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
    ld   scw_r253, [x]
    ld   LINK_HI, x
    ld   scw_r253 >> 8, [x]
    ld   rb_nb >> 8, y
    jmp  rb_nb
scw_r253:
    ld   ac, [v3]
    ld   [rb_y], ac             ; the link cell back
    ld   ac, [rb_cx]
    ld   [rb_t], ac
    ld   ac, [rb_cy]
    ld   [v3], ac
    beq  sd_0
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r254, [x]
    ld   LINK_HI, x
    ld   scw_r254 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r254:
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
    xor  32, ac                 ; 32 rooms (x4060 up: the flight's)
    bne  rc_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; the bits of a byte, for the fill's map (VISADDR)

#addr 0x2C00
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
    ld   scw_r255, [x]
    ld   LINK_HI, x
    ld   scw_r255 >> 8, [x]
    ld   rb_avg >> 8, y
    jmp  rb_avg
scw_r255:
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
    xor  32, ac
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

#addr 0x2D00
inst_action:
    ld   [w3], ac
    sub  A_REPAIR, ac
    bcs  in_0
    ld   more_action >> 8, y
    jmp  more_action
in_0:
    ld   [s_who], ac
    xor  3, ac
    bne  in_0b
    ld   inv_install >> 8, y
    jmp  inv_install
in_0b:
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
    ld   scw_r256, [x]
    ld   LINK_HI, x
    ld   scw_r256 >> 8, [x]
    ld   on_tug >> 8, y
    jmp  on_tug
scw_r256:
    bne  in_2
    ld   cut_action >> 8, y
    jmp  cut_action
in_2:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r257, [x]
    ld   LINK_HI, x
    ld   scw_r257 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r257:
    beq  in_far
    ld   LINK_LO, x             ; CALL plate_room
    ld   scw_r258, [x]
    ld   LINK_HI, x
    ld   scw_r258 >> 8, [x]
    ld   plate_room >> 8, y
    jmp  plate_room
scw_r258:
    beq  in_e
    ld   INST_FRAMES, ac
    ld   LINK_LO, x             ; CALL job_start
    ld   scw_r259, [x]
    ld   LINK_HI, x
    ld   scw_r259 >> 8, [x]
    ld   job_start >> 8, y
    jmp  job_start
scw_r259:
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
    ld   scw_r260, [x]
    ld   LINK_HI, x
    ld   scw_r260 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r260:
in_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
in_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r261, [x]
    ld   LINK_HI, x
    ld   scw_r261 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r261:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; on_tug - AC = 1 when the panel's cell is one of the tug's.  A leaf.
draw_warn:
    ld   TINT_WARN | 0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r291, [x]
    ld   LINK_HI, x
    ld   scw_r291 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r291:
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
    ld   scw_r292, [x]
    ld   LINK_HI, x
    ld   scw_r292 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r292:
    ld   sc_leave >> 8, y
    jmp  sc_leave

fl_far:
    ld   [g_x], ac
    sub  WRECK_LKX, ac
    bcs  ff_n
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   [y,x], ac
    bne  ff_n
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ff_n:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dyn_nav - NAVIGATE on a working helm installed on the tug.  The end of
; dyn_acts (its LEAVE)

#addr 0x2E00
refill_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r262, [x]
    ld   LINK_HI, x
    ld   scw_r262 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r262:
    beq  rf_far
    ld   [s_f], ac
    sub  8, ac
    bcs  rf_ok
    ld   s_broken & 0xFF, ac
    ld   ac, [R0]
    ld   s_broken >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r263, [x]
    ld   LINK_HI, x
    ld   scw_r263 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r263:
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
    ld   scw_r264, [x]
    ld   LINK_HI, x
    ld   scw_r264 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r264:
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r265, [x]
    ld   LINK_HI, x
    ld   scw_r265 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r265:
    ld   T_O2E, ac              ; still installed if it was
    or   [c_b], ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r266, [x]
    ld   LINK_HI, x
    ld   scw_r266 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r266:
    ld   act_done >> 8, y
    jmp  act_done
rf_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r267, [x]
    ld   LINK_HI, x
    ld   scw_r267 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r267:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_player - the player's rows 25-28: suit O2, battery, hands, back
; and the tug
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
    ld   scw_r281, [x]
    ld   LINK_HI, x
    ld   scw_r281 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r281:
    ld   [val_l], ac
    ld   ac, [num_l]
    ld   [val_h], ac
    ld   ac, [num_h]
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r282, [x]
    ld   LINK_HI, x
    ld   scw_r282 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r282:
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
    ld   scw_r283, [x]
    ld   LINK_HI, x
    ld   scw_r283 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r283:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; put_name - the name of type AC (EMPTY for 0)

#addr 0x2F00
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
    ld   scw_r268, [x]
    ld   LINK_HI, x
    ld   scw_r268 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r268:
    bra  dp_26
dp_s:
    ld   s_pl_suit & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_suit >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r269, [x]
    ld   LINK_HI, x
    ld   scw_r269 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r269:
    ld   [o2], ac
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r270, [x]
    ld   LINK_HI, x
    ld   scw_r270 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r270:
    ld   s_pl_of & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_of >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r271, [x]
    ld   LINK_HI, x
    ld   scw_r271 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r271:
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
    ld   scw_r272, [x]
    ld   LINK_HI, x
    ld   scw_r272 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r272:
    ld   [batt], ac
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r273, [x]
    ld   LINK_HI, x
    ld   scw_r273 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r273:
    ld   0x25, ac               ; %
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r274, [x]
    ld   LINK_HI, x
    ld   scw_r274 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r274:
    ld   draw_player2 >> 8, y
    jmp  draw_player2

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
    ld   scw_r284, [x]
    ld   LINK_HI, x
    ld   scw_r284 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r284:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r285, [x]
    ld   LINK_HI, x
    ld   scw_r285 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r285:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pn_e:
    ld   s_empty & 0xFF, ac
    ld   ac, [R0]
    ld   s_empty >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r286, [x]
    ld   LINK_HI, x
    ld   scw_r286 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r286:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_tags - row 24 of a cell: INSTALLED (bolted) or LOOSE for
; a part, HELD OPEN for a door; its room's air
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
    ld   scw_r275, [x]
    ld   LINK_HI, x
    ld   scw_r275 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r275:
    ld   [cl_t], ac
    ld   LINK_LO, x             ; CALL put_name
    ld   scw_r276, [x]
    ld   LINK_HI, x
    ld   scw_r276 >> 8, [x]
    ld   put_name >> 8, y
    jmp  put_name
scw_r276:
    ld   s_slash & 0xFF, ac
    ld   ac, [R0]
    ld   s_slash >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r277, [x]
    ld   LINK_HI, x
    ld   scw_r277 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r277:
    ld   [cr_t], ac
    ld   LINK_LO, x             ; CALL put_name
    ld   scw_r278, [x]
    ld   LINK_HI, x
    ld   scw_r278 >> 8, [x]
    ld   put_name >> 8, y
    jmp  put_name
scw_r278:
    ld   28, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_pl_back & 0xFF, ac
    ld   ac, [R0]
    ld   s_pl_back >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r279, [x]
    ld   LINK_HI, x
    ld   scw_r279 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r279:
    ld   [cb_t], ac
    ld   LINK_LO, x             ; CALL put_name
    ld   scw_r280, [x]
    ld   LINK_HI, x
    ld   scw_r280 >> 8, [x]
    ld   put_name >> 8, y
    jmp  put_name
scw_r280:
    ld   draw_player3 >> 8, y
    jmp  draw_player3

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
    ld   scw_r293, [x]
    ld   LINK_HI, x
    ld   scw_r293 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r293:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; put_dec - num_h:num_l in decimal, no leading zeros
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
    ld   scw_r295, [x]
    ld   LINK_HI, x
    ld   scw_r295 >> 8, [x]
    ld   sk_gain >> 8, y
    jmp  sk_gain
scw_r295:
    ld   LINK_LO, x             ; CALL cut_done
    ld   scw_r296, [x]
    ld   LINK_HI, x
    ld   scw_r296 >> 8, [x]
    ld   cut_done >> 8, y
    jmp  cut_done
scw_r296:
    ld   sc_leave >> 8, y
    jmp  sc_leave
wt_x:
    ld   jb_tick >> 8, y
    jmp  jb_tick

; jb_tick - the job's bar: a 16th more done each time the work left
; reaches JB_TH:JB_TL (then JB_B less); the message row drawn again and
; kept up.  The rest of work_tick

#addr 0x3100
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
    ld   [s_who], ac
    xor  3, ac
    bne  dt_lo
    ld   [inv_k], ac
    add  SLOT_TAB & 0xFF, x
    ld   SLOT_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   SLOT_TAB >> 8, ac
    bra  dt_p
dt_lo:
    ld   s_loose & 0xFF, ac
    ld   ac, [R0]
    ld   s_loose >> 8, ac
dt_p:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r287, [x]
    ld   LINK_HI, x
    ld   scw_r287 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r287:
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
    ld   scw_r288, [x]
    ld   LINK_HI, x
    ld   scw_r288 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r288:
    ld   ROOM_P >> 8, y
    ld   [s_r], x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r289, [x]
    ld   LINK_HI, x
    ld   scw_r289 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r289:
    ld   0x25, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r290, [x]
    ld   LINK_HI, x
    ld   scw_r290 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r290:
dt_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_warn - row 29 with the warning of the stage, red.  The rest of
; draw_msg.
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

#addr 0x3200
DOOR_TAB:
    #d8 0x70, 0x68, 0x6C, 0x6C, 0x84, 0x84, 0x80, 0x84
    #d8 0x88, 0x8C, 0x7C, 0x94, 0x94, 0x98, 0x9C, 0xA0
    #d8 0x98, 0x9C, 0x9C, 0xA0, 0xBC, 0xBC, 0xB4, 0xB4
    #d8 0xBC, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 172, 205, 202, 206, 138, 142, 230, 228
    #d8 229, 227, 248, 13, 14, 38, 36, 44
    #d8 143, 142, 228, 236, 26, 58, 74, 78
    #d8 74, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 4, 1, 2, 3, 7, 3, 6, 7
    #d8 8, 5, 9, 10, 10, 3, 3, 3
    #d8 11, 3, 12, 13, 15, 15, 14, 3
    #d8 15, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 5, 2, 3, 4, 3, 8, 3, 3
    #d8 3, 3, 10, 3, 3, 11, 12, 13
    #d8 12, 13, 14, 15, 0, 0, 3, 15
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

zn_1 = zn_0
zb_2 = zb_1
zb_5 = zb_4
zb_7 = zb_6
zb_10 = zb_9
zb_13 = zb_12
zb_15 = zb_14
zs_1 = zs_0
zs_2 = zs_0
zs_3 = zs_0
zs_4 = zs_0
zs_5 = zs_0
zs_6 = zs_0
zs_7 = zs_0
zs_9 = zs_8
zs_10 = zs_8
zs_11 = zs_8
zs_12 = zs_8
zs_13 = zs_8
zs_14 = zs_8
zs_15 = zs_8
zw_9 = zw_8
zw_10 = zw_8
zw_11 = zw_8
zw_12 = zw_8
zw_13 = zw_8
zw_14 = zw_8
zw_15 = zw_8
s_uninstdone = s_cutdone

ROOM_TAB:
    #d8 zb_0 & 0xFF, zb_1 & 0xFF, zb_1 & 0xFF, zb_3 & 0xFF, zb_4 & 0xFF, zb_4 & 0xFF, zb_6 & 0xFF, zb_6 & 0xFF
    #d8 zb_8 & 0xFF, zb_9 & 0xFF, zb_9 & 0xFF, zb_11 & 0xFF, zb_12 & 0xFF, zb_12 & 0xFF, zb_14 & 0xFF, zb_14 & 0xFF
    #d8 zb_0 >> 8, zb_1 >> 8, zb_1 >> 8, zb_3 >> 8, zb_4 >> 8, zb_4 >> 8, zb_6 >> 8, zb_6 >> 8
    #d8 zb_8 >> 8, zb_9 >> 8, zb_9 >> 8, zb_11 >> 8, zb_12 >> 8, zb_12 >> 8, zb_14 >> 8, zb_14 >> 8
    #d8 zs_0 & 0xFF, zs_0 & 0xFF, zs_0 & 0xFF, zs_0 & 0xFF, zs_0 & 0xFF, zs_0 & 0xFF, zs_0 & 0xFF, zs_0 & 0xFF
    #d8 zs_8 & 0xFF, zs_8 & 0xFF, zs_8 & 0xFF, zs_8 & 0xFF, zs_8 & 0xFF, zs_8 & 0xFF, zs_8 & 0xFF, zs_8 & 0xFF
    #d8 zs_0 >> 8, zs_0 >> 8, zs_0 >> 8, zs_0 >> 8, zs_0 >> 8, zs_0 >> 8, zs_0 >> 8, zs_0 >> 8
    #d8 zs_8 >> 8, zs_8 >> 8, zs_8 >> 8, zs_8 >> 8, zs_8 >> 8, zs_8 >> 8, zs_8 >> 8, zs_8 >> 8
    #d8 0, 100, 100, 100, 100, 100, 100, 100
    #d8 100, 100, 100, 100, 100, 100, 100, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zd_0 & 0xFF, zd_1 & 0xFF, zd_2 & 0xFF, zd_3 & 0xFF, zd_4 & 0xFF, zd_5 & 0xFF, zd_6 & 0xFF, zd_7 & 0xFF
    #d8 zd_8 & 0xFF, zd_9 & 0xFF, zd_10 & 0xFF, zd_11 & 0xFF, zd_12 & 0xFF, zd_13 & 0xFF, zd_14 & 0xFF, zd_15 & 0xFF
    #d8 zd_0 >> 8, zd_1 >> 8, zd_2 >> 8, zd_3 >> 8, zd_4 >> 8, zd_5 >> 8, zd_6 >> 8, zd_7 >> 8
    #d8 zd_8 >> 8, zd_9 >> 8, zd_10 >> 8, zd_11 >> 8, zd_12 >> 8, zd_13 >> 8, zd_14 >> 8, zd_15 >> 8
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 1, 1, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zw_0 & 0xFF, zw_1 & 0xFF, zw_2 & 0xFF, zw_3 & 0xFF, zw_4 & 0xFF, zw_5 & 0xFF, zw_6 & 0xFF, zw_7 & 0xFF
    #d8 zw_8 & 0xFF, zw_8 & 0xFF, zw_8 & 0xFF, zw_8 & 0xFF, zw_8 & 0xFF, zw_8 & 0xFF, zw_8 & 0xFF, zw_8 & 0xFF
    #d8 zw_0 >> 8, zw_1 >> 8, zw_2 >> 8, zw_3 >> 8, zw_4 >> 8, zw_5 >> 8, zw_6 >> 8, zw_7 >> 8
    #d8 zw_8 >> 8, zw_8 >> 8, zw_8 >> 8, zw_8 >> 8, zw_8 >> 8, zw_8 >> 8, zw_8 >> 8, zw_8 >> 8
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

TAB:
    #d8 97, 97, 19, 50, 50, 51, 14, 130
    #d8 142, 6, 14, 142, 14, 162, 19, 3
    #d8 35, 6, 14, 142, 97, 14, 6, 14
    #d8 14, 6, 0, 14, 142, 142, 166, 166
    #d8 166, 166, 166, 166, 166, 166, 166, 166
    #d8 166, 166, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zn_0 & 0xFF, zn_1 & 0xFF, zn_2 & 0xFF, zn_3 & 0xFF, zn_4 & 0xFF, zn_5 & 0xFF, zn_6 & 0xFF, zn_7 & 0xFF
    #d8 zn_8 & 0xFF, zn_9 & 0xFF, zn_10 & 0xFF, zn_11 & 0xFF, zn_12 & 0xFF, zn_13 & 0xFF, zn_14 & 0xFF, zn_15 & 0xFF
    #d8 zn_16 & 0xFF, zn_17 & 0xFF, zn_18 & 0xFF, zn_19 & 0xFF, zn_20 & 0xFF, zn_21 & 0xFF, zn_22 & 0xFF, zn_23 & 0xFF
    #d8 zn_24 & 0xFF, zn_25 & 0xFF, zn_26 & 0xFF, zn_27 & 0xFF, zn_28 & 0xFF, zn_29 & 0xFF, zn_30 & 0xFF, zn_31 & 0xFF
    #d8 zn_32 & 0xFF, zn_30 & 0xFF, zn_31 & 0xFF, zn_32 & 0xFF, zn_30 & 0xFF, zn_31 & 0xFF, zn_32 & 0xFF, zn_30 & 0xFF
    #d8 zn_31 & 0xFF, zn_32 & 0xFF, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 zn_0 >> 8, zn_1 >> 8, zn_2 >> 8, zn_3 >> 8, zn_4 >> 8, zn_5 >> 8, zn_6 >> 8, zn_7 >> 8
    #d8 zn_8 >> 8, zn_9 >> 8, zn_10 >> 8, zn_11 >> 8, zn_12 >> 8, zn_13 >> 8, zn_14 >> 8, zn_15 >> 8
    #d8 zn_16 >> 8, zn_17 >> 8, zn_18 >> 8, zn_19 >> 8, zn_20 >> 8, zn_21 >> 8, zn_22 >> 8, zn_23 >> 8
    #d8 zn_24 >> 8, zn_25 >> 8, zn_26 >> 8, zn_27 >> 8, zn_28 >> 8, zn_29 >> 8, zn_30 >> 8, zn_31 >> 8
    #d8 zn_32 >> 8, zn_30 >> 8, zn_31 >> 8, zn_32 >> 8, zn_30 >> 8, zn_31 >> 8, zn_32 >> 8, zn_30 >> 8
    #d8 zn_31 >> 8, zn_32 >> 8, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 20, 250
    #d8 30, 15, 5, 60, 6, 40, 0, 0
    #d8 0, 0, 25, 35, 0, 8, 12, 3
    #d8 8, 2, 0, 4, 18, 14, 45, 55
    #d8 50, 45, 55, 50, 45, 55, 50, 45
    #d8 55, 50, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

ACT_TAB:
    #d8 0, 0, 1, 1, 17, 17, 144, 6
    #d8 130, 1, 129, 138, 129, 9, 2, 1
    #d8 17, 1, 144, 146, 0, 144, 2, 193
    #d8 209, 65, 0, 130, 145, 144, 74, 74
    #d8 81, 74, 74, 81, 74, 74, 81, 74
    #d8 74, 81, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 1, 2, 4, 4, 8, 60
    #d8 4, 10, 2, 3, 2, 12, 4, 3
    #d8 8, 1, 10, 4, 0, 3, 1, 2
    #d8 3, 1, 0, 1, 2, 2, 2, 3
    #d8 15, 2, 3, 15, 2, 3, 15, 2
    #d8 3, 15, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, za_1 & 0xFF, za_2 & 0xFF, za_3 & 0xFF, za_4 & 0xFF, za_5 & 0xFF, za_6 & 0xFF, za_7 & 0xFF
    #d8 za_8 & 0xFF, za_9 & 0xFF, za_10 & 0xFF, za_11 & 0xFF, za_12 & 0xFF, za_13 & 0xFF, za_14 & 0xFF, za_15 & 0xFF
    #d8 za_16 & 0xFF, za_17 & 0xFF, za_18 & 0xFF, za_19 & 0xFF, za_20 & 0xFF, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, za_1 >> 8, za_2 >> 8, za_3 >> 8, za_4 >> 8, za_5 >> 8, za_6 >> 8, za_7 >> 8
    #d8 za_8 >> 8, za_9 >> 8, za_10 >> 8, za_11 >> 8, za_12 >> 8, za_13 >> 8, za_14 >> 8, za_15 >> 8
    #d8 za_16 >> 8, za_17 >> 8, za_18 >> 8, za_19 >> 8, za_20 >> 8, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0

ACTS_TAB:
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
    #d8 4, 3, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 0, 0, 0, 3, 0, 0, 0
    #d8 3, 20, 0, 0, 3, 20, 0, 0
    #d8 3, 20, 0, 0, 3, 20, 0, 0
    #d8 3, 20, 0, 0, 3, 20, 0, 0
    #d8 3, 20, 0, 0, 3, 20, 0, 0
    #d8 3, 20, 0, 0, 3, 20, 0, 0
    #d8 3, 20, 0, 0, 3, 20, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 0, 0, 0
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
; COND
    #d8 0x77, 0x77, 0xE7, 0x67, 0x77, 0x77, 0xE7, 0x67, 0x77, 0x77, 0xE7, 0x67, 0x77, 0x77, 0x77, 0x00
    #d8 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0x77, 0x00
    #d8 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0xEE, 0x66, 0x77, 0x77, 0x77, 0x00
    #d8 0x07, 0x07, 0x0E, 0x06, 0x07, 0x07, 0x0E, 0x06, 0x07, 0x07, 0x0E, 0x06, 0x07, 0x07, 0x07, 0x00

; PUMP
    #d8 0x77, 0x77, 0xB7, 0x8B, 0x8B, 0x8B, 0x8B, 0x8B, 0xB7, 0x77, 0x77, 0xE7, 0x67, 0x77, 0x77, 0x77
    #d8 0x77, 0xBB, 0x88, 0x88, 0xB8, 0x7B, 0xB8, 0x88, 0x88, 0xBB, 0xB7, 0xEE, 0x66, 0xB7, 0xBB, 0x77
    #d8 0x77, 0xBB, 0x88, 0x88, 0x8B, 0xB7, 0x8B, 0x88, 0x88, 0xBB, 0x7B, 0xEE, 0x66, 0x7B, 0xBB, 0x77
    #d8 0x77, 0x77, 0x7B, 0xB8, 0xB8, 0xB8, 0xB8, 0xB8, 0x7B, 0x77, 0x77, 0x7E, 0x76, 0x77, 0x77, 0x77
; INTAKE
    #d8 0x77, 0xB7, 0x6B, 0xDB, 0x6B, 0xDB, 0x6B, 0xB7, 0x77, 0x77, 0xD7, 0x67, 0x77, 0x77, 0x77, 0x77
    #d8 0x77, 0xBB, 0x6D, 0xD6, 0x6D, 0xD6, 0x6D, 0xBB, 0xB7, 0xB7, 0xDD, 0x66, 0xB7, 0xB7, 0xBB, 0x77
    #d8 0x77, 0xBB, 0x6D, 0xD6, 0x6D, 0xD6, 0x6D, 0xBB, 0x7B, 0x7B, 0xDD, 0x66, 0x7B, 0x7B, 0xBB, 0x77
    #d8 0x77, 0x7B, 0xBD, 0xB6, 0xBD, 0xB6, 0xBD, 0x7B, 0x77, 0x77, 0x7D, 0x76, 0x77, 0x77, 0x77, 0x77
; ANT
    #d8 0x11, 0x11, 0x11, 0xBB, 0x7B, 0x7B, 0xB1, 0x11, 0x11, 0x11, 0x11, 0x11, 0xB1, 0xBB, 0xB1, 0xBB
    #d8 0x11, 0x11, 0x11, 0x1B, 0xB7, 0x77, 0x77, 0x7B, 0xB1, 0x11, 0xB1, 0xBB, 0x1B, 0xBB, 0x77, 0xBB
    #d8 0x11, 0x11, 0xB1, 0x1B, 0x1B, 0x1B, 0xB7, 0x77, 0x77, 0xBB, 0x1B, 0x11, 0x11, 0xBB, 0x1B, 0xBB
    #d8 0x11, 0x1A, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1B, 0x1B, 0x1B, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
; RADAR
    #d8 0x11, 0x11, 0x11, 0xB1, 0x7B, 0x7B, 0x7B, 0xB1, 0x11, 0x11, 0x11, 0x11, 0xB1, 0xB1, 0xB1, 0xBB
    #d8 0x11, 0x11, 0x11, 0xBB, 0x77, 0x7E, 0x77, 0xBB, 0xB1, 0xB1, 0xB1, 0xBB, 0x77, 0xA7, 0x77, 0xBB
    #d8 0x11, 0x11, 0x11, 0xBB, 0x77, 0x7E, 0x77, 0xBB, 0x1B, 0x1B, 0x1B, 0xBB, 0x77, 0x7A, 0x77, 0xBB
    #d8 0x11, 0x11, 0x11, 0x1B, 0xB7, 0xB7, 0xB7, 0x1B, 0x11, 0x11, 0x11, 0x11, 0x1B, 0x1B, 0x1B, 0xBB

; THRUST
    #d8 0xB1, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1B, 0x1B, 0xBB, 0xB6, 0xB6, 0xBB, 0x1B, 0x11, 0xB1, 0xBB
    #d8 0x6B, 0x6B, 0xBB, 0xB1, 0x71, 0x71, 0x71, 0xBB, 0x7B, 0xA7, 0xA7, 0x7B, 0xBB, 0x7B, 0xBB, 0xBB
    #d8 0xB6, 0xB6, 0xBB, 0x1B, 0x17, 0x17, 0x17, 0xBB, 0xB7, 0x7A, 0x7A, 0xB7, 0xBB, 0xB7, 0xBB, 0xBB
    #d8 0x1B, 0x11, 0x11, 0x11, 0x11, 0x11, 0xB1, 0xB1, 0xBB, 0x6B, 0x6B, 0xBB, 0xB1, 0x11, 0x1B, 0xBB
; ANT_L
    #d8 0x11, 0xB1, 0x7B, 0x7B, 0xB1, 0xB1, 0x11, 0x1A, 0x1A, 0x11, 0xB1, 0xB1, 0x7B, 0x7B, 0xB1, 0x11
    #d8 0x11, 0x1B, 0xB7, 0x77, 0x77, 0x77, 0x7B, 0x7B, 0x7B, 0x7B, 0x77, 0x77, 0x77, 0xB7, 0x1B, 0x11
    #d8 0x11, 0x11, 0x11, 0x1B, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0xB7, 0x1B, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0x11, 0xB1, 0xB1, 0xBB, 0xBB, 0xB1, 0xB1, 0x11, 0x11, 0x11, 0x11, 0x11
; RADAR_L
    #d8 0x11, 0xB1, 0x7B, 0xEB, 0x7B, 0x7B, 0x7B, 0xEB, 0xEB, 0x7B, 0x7B, 0x7B, 0x7B, 0xEB, 0x7B, 0xB1
    #d8 0x11, 0x11, 0x1B, 0x1B, 0x1B, 0x1B, 0xBB, 0xBB, 0xBB, 0xBB, 0x1B, 0x1B, 0x1B, 0x1B, 0x1B, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0xB1, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0x7B, 0xB1, 0x11, 0x11, 0x11, 0x11
    #d8 0x11, 0x11, 0x11, 0x11, 0xBB, 0xB7, 0xBA, 0xBA, 0xBA, 0xBA, 0xB7, 0xBB, 0x11, 0x11, 0x11, 0x11
; THRUST_L
    #d8 0x11, 0x11, 0x11, 0x11, 0x1B, 0xBB, 0xB6, 0xB6, 0xB6, 0xB6, 0xBB, 0x1B, 0x11, 0x11, 0x11, 0x11
    #d8 0xB1, 0x11, 0x11, 0xB1, 0xB1, 0xB1, 0xBB, 0x77, 0x77, 0xBB, 0xB1, 0xB1, 0xB1, 0x11, 0x11, 0xB1
    #d8 0x66, 0xBB, 0x77, 0xBB, 0x77, 0x77, 0xAA, 0xAA, 0xAA, 0xAA, 0x77, 0x77, 0xBB, 0x77, 0xBB, 0x66
    #d8 0x1B, 0x11, 0x11, 0x1B, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0x1B, 0x11, 0x11, 0x1B


#overlay 0x4100
FNT_A:
    #d8 0, 0, 0, 0, 0, 5, 0, 2, 2, 2, 0, 0, 0, 0, 0, 4
    #d8 7, 2, 7, 7, 5, 7, 7, 7, 7, 7, 0, 0, 0, 0, 1, 3
    #d8 0, 2, 3, 6, 3, 7, 7, 6, 5, 7, 4, 5, 1, 5, 3, 2
    #d8 3, 2, 3, 6, 7, 5, 5, 5, 5, 5, 7, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 4, 0, 2, 1, 4, 0, 0, 0, 0, 0, 4
    #d8 5, 3, 4, 4, 5, 1, 1, 4, 5, 5, 2, 0, 0, 0, 2, 4
    #d8 0, 5, 5, 1, 5, 1, 1, 1, 5, 2, 4, 5, 1, 7, 5, 5
    #d8 5, 5, 5, 1, 2, 5, 5, 5, 5, 5, 4, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 2, 0, 0, 1, 4, 0, 0, 0, 7, 0, 2
    #d8 5, 2, 7, 6, 7, 7, 7, 4, 7, 7, 0, 0, 0, 0, 4, 2
    #d8 0, 7, 3, 1, 5, 3, 3, 5, 7, 2, 4, 3, 1, 7, 5, 5
    #d8 3, 5, 3, 2, 2, 5, 5, 7, 2, 2, 2, 0, 0, 0, 0, 0
    #d8 0, 0, 0, 0, 0, 1, 0, 0, 1, 4, 0, 0, 2, 0, 0, 1
    #d8 5, 2, 1, 4, 4, 4, 5, 2, 5, 4, 2, 0, 0, 0, 2, 0
    #d8 0, 5, 5, 1, 5, 1, 1, 5, 5, 2, 5, 5, 1, 5, 5, 5
    #d8 1, 3, 5, 4, 2, 5, 5, 7, 5, 2, 1, 0, 0, 0, 0, 0

inv_draw:
    ld   LINK_LO, x             ; CALL pt_hide
    ld   scw_r424, [x]
    ld   LINK_HI, x
    ld   scw_r424 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r424:
    clr  ac                     ; the background, dark blue
    ld   ac, [fr_on]
    ld   ac, [w0]
    ld   ac, [w1]
    ld   80, ac
    ld   ac, [w4]
    ld   192, ac
    ld   ac, [w5]
    ld   0x11, ac
    ld   ac, [w6]
    ld   LINK_LO, x             ; CALL ip_fill
    ld   scw_r425, [x]
    ld   LINK_HI, x
    ld   scw_r425 >> 8, [x]
    ld   ip_fill >> 8, y
    jmp  ip_fill
scw_r425:
    clr  ac                     ; the title bar
    ld   ac, [w0]
    ld   10, ac
    ld   ac, [w5]
    ld   0x33, ac
    ld   ac, [w6]
    ld   LINK_LO, x             ; CALL ip_fill
    ld   scw_r426, [x]
    ld   LINK_HI, x
    ld   scw_r426 >> 8, [x]
    ld   ip_fill >> 8, y
    jmp  ip_fill
scw_r426:
    ld   LINK_LO, x             ; CALL ip_labels
    ld   scw_r427, [x]
    ld   LINK_HI, x
    ld   scw_r427 >> 8, [x]
    ld   ip_labels >> 8, y
    jmp  ip_labels
scw_r427:
    ld   LINK_LO, x             ; CALL inv_slots
    ld   scw_r428, [x]
    ld   LINK_HI, x
    ld   scw_r428 >> 8, [x]
    ld   inv_slots >> 8, y
    jmp  inv_slots
scw_r428:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ip_addr - w2 = the page, w3 = the offset of byte column w0, line pair
; w1.  A leaf.
ip_addr:
    ld   [w0], ac
    shl
    add  0x61, ac
    ld   ac, [w2]
    ld   [w1], ac
    sub  112, ac
    blt  pa5_lo
    ld   [w1], ac
    shl
    sub  223, ac
    ld   ac, [w3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
pa5_lo:
    ld   [w1], ac
    shl
    add  32, ac
    ld   ac, [w3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ip_fill - w4 byte columns from w0 (w0 after them), w5 line pairs from
; w1, all byte w6
ip_fill:
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
    ld   [w4], ac
    ld   ac, [v0]
pf5_c:
    ld   LINK_LO, x             ; CALL ip_addr
    ld   scw_r429, [x]
    ld   LINK_HI, x
    ld   scw_r429 >> 8, [x]
    ld   ip_addr >> 8, y
    jmp  ip_addr
scw_r429:
    ld   [w5], ac
    ld   ac, [v1]
    ld   [w2], y
    ld   [w3], x
pf5_l:
    ld   [w6], ac
    ld   ac, [y,x]
    ld   ac, x                  ; x: the next line pair
    ld   [w3], ac
    add  2, ac
    bne  pf5_n
    ld   1, ac
pf5_n:
    ld   ac, [w3]
    ld   ac, x
    ld   [v1], ac
    dec
    ld   ac, [v1]
    bne  pf5_l
    ld   [w0], ac
    inc
    ld   ac, [w0]
    ld   [v0], ac
    dec
    ld   ac, [v0]
    bne  pf5_c
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ip_color - the 3 x 5 font's colors: w4 on w5 (CMB: the four pixel
; pairs).  A leaf.
is_pos:
    ld   SPOS >> 8, y
    ld   [v7], ac
    shl
    add  SPOS & 0xFF, x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   [v7], ac
    shl
    add  (SPOS & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; is_type - AC = the part slot v7 shows (0: an empty slot, drawn black)
CMB:
    #d8 0x11, 0x1A, 0xA1, 0xAA

; scrap_inv_data.masm - made by gen_scrap.py: the inventory's font,
; labels and slots

SPOS:
    #d8 36, 22, 36, 54, 36, 86, 3, 22, 3, 54, 3, 86, 3, 118


#overlay 0x4300
ip_color:
    ld   [w5], ac
    shl
    shl
    shl
    shl
    ld   ac, [w6]               ; the background, high
    ld   CMB >> 8, y
    ld   [w5], ac
    or   [w6], ac
    ld   CMB & 0xFF, x
    ld   ac, [y,x]
    ld   [w4], ac
    or   [w6], ac
    ld   (CMB & 0xFF) + 1, x
    ld   ac, [y,x]
    ld   [w4], ac
    shl
    shl
    shl
    shl
    ld   ac, [w6]               ; the color, high
    or   [w5], ac
    ld   (CMB & 0xFF) + 2, x
    ld   ac, [y,x]
    ld   [w4], ac
    or   [w6], ac
    ld   (CMB & 0xFF) + 3, x
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ip_char - AC (20-5F) in the 3 x 5 font at byte column w0, line pair w1
; (two bytes: three pixels and a gap); w0 two on
ip_char:
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
    sub  0x20, ac
    ld   ac, [u0]
    ld   LINK_LO, x             ; CALL ip_addr
    ld   scw_r430, [x]
    ld   LINK_HI, x
    ld   scw_r430 >> 8, [x]
    ld   ip_addr >> 8, y
    jmp  ip_addr
scw_r430:
    clr  ac
    ld   ac, [u1]
pc5_l:
    ld   [u1], ac               ; the row's code: rows 0-3 in FNT_A, 4 in FNT_B
    xor  4, ac
    beq  pc5_4
    ld   [u1], ac
    shl
    shl
    shl
    shl
    shl
    shl
    add  [u0], ac
    ld   ac, x
    ld   FNT_A >> 8, y
    ld   [y,x], ac
    bra  pc5_g
pc5_4:
    ld   [u0], ac
    add  FNT_B & 0xFF, x
    ld   FNT_B >> 8, y
    ld   [y,x], ac
pc5_g:
    ld   ac, [u2]
    and  3, ac
    add  CMB & 0xFF, x
    ld   CMB >> 8, y
    ld   [y,x], ac
    ld   ac, [u3]
    ld   [u2], ac
    shr  ac
    shr  ac
    add  CMB & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u4]
    ld   [w2], y
    ld   [w3], x
    ld   [u3], ac
    ld   ac, [y,x]
    ld   [w2], ac
    add  2, ac
    ld   ac, y
    ld   [u4], ac
    ld   ac, [y,x]
    ld   [w3], ac
    add  2, ac
    bne  pc5_n
    ld   1, ac
pc5_n:
    ld   ac, [w3]
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  5, ac
    bne  pc5_l
    ld   [w0], ac
    add  2, ac
    ld   ac, [w0]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ip_text - the string at R1:R0 from w0, w1 (ip_char)
ip_text:
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
pt5_l:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    beq  pt5_e
    ld   LINK_LO, x             ; CALL ip_char
    ld   scw_r431, [x]
    ld   LINK_HI, x
    ld   scw_r431 >> 8, [x]
    ld   ip_char >> 8, y
    jmp  ip_char
scw_r431:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  pt5_l
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  pt5_l
pt5_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ip_num - AC in decimal (no leading zeros) from w0, w1

#overlay 0x4400
ip_num:
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
    ld   ac, [u5]
    clr  ac
    ld   ac, [u6]               ; 1: a digit was printed
    ld   100, ac
    ld   LINK_LO, x             ; CALL pn_dig
    ld   scw_r432, [x]
    ld   LINK_HI, x
    ld   scw_r432 >> 8, [x]
    ld   pn_dig >> 8, y
    jmp  pn_dig
scw_r432:
    ld   10, ac
    ld   LINK_LO, x             ; CALL pn_dig
    ld   scw_r433, [x]
    ld   LINK_HI, x
    ld   scw_r433 >> 8, [x]
    ld   pn_dig >> 8, y
    jmp  pn_dig
scw_r433:
    ld   1, ac
    ld   ac, [u6]
    ld   LINK_LO, x             ; CALL pn_dig
    ld   scw_r434, [x]
    ld   LINK_HI, x
    ld   scw_r434 >> 8, [x]
    ld   pn_dig >> 8, y
    jmp  pn_dig
scw_r434:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pn_dig - the digit of u5 for AC (100, 10, 1); u5 less it
pn_dig:
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
    clr  ac
    ld   ac, [v2]
pd5_l:
    ld   [u5], ac
    sub  [u7], ac
    bcs  pd5_d
    ld   ac, [u5]
    ld   [v2], ac
    inc
    ld   ac, [v2]
    bra  pd5_l
pd5_d:
    ld   [v2], ac
    or   [u6], ac
    beq  pd5_e
    ld   1, ac
    ld   ac, [u6]
    ld   [v2], ac
    add  0x30, ac
    ld   LINK_LO, x             ; CALL ip_char
    ld   scw_r435, [x]
    ld   LINK_HI, x
    ld   scw_r435 >> 8, [x]
    ld   ip_char >> 8, y
    jmp  ip_char
scw_r435:
pd5_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ip_labels - the fixed text (LBL: column, line pair, color, background,
; the string; FF ends)
ip_labels:
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
    ld   ac, [v3]
pl5_l:
    ld   LBL >> 8, y
    ld   [v3], ac
    add  LBL & 0xFF, x
    ld   [y,x], ac
    ld   ac, [w0]
    xor  0xFF, ac
    beq  pl5_e
    ld   [v3], ac
    add  (LBL & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   [v3], ac
    add  (LBL & 0xFF) + 2, x
    ld   [y,x], ac
    ld   ac, [w4]
    ld   [v3], ac
    add  (LBL & 0xFF) + 3, x
    ld   [y,x], ac
    ld   ac, [w5]
    ld   [v3], ac
    add  (LBL & 0xFF) + 4, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   LBL >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ip_color
    ld   scw_r436, [x]
    ld   LINK_HI, x
    ld   scw_r436 >> 8, [x]
    ld   ip_color >> 8, y
    jmp  ip_color
scw_r436:
    ld   LINK_LO, x             ; CALL ip_text
    ld   scw_r437, [x]
    ld   LINK_HI, x
    ld   scw_r437 >> 8, [x]
    ld   ip_text >> 8, y
    jmp  ip_text
scw_r437:
    ld   [v3], ac
    add  5, ac
    ld   ac, [v3]
    bra  pl5_l
pl5_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ip_art - the cell art at dc_ap:dc_ai (4 byte columns of 16) from byte
; column w0 (w0 after it), line pair w1

#overlay 0x4500
ip_art:
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
    ld   4, ac
    ld   ac, [v0]
pa5_c:
    ld   LINK_LO, x             ; CALL ip_addr
    ld   scw_r438, [x]
    ld   LINK_HI, x
    ld   scw_r438 >> 8, [x]
    ld   ip_addr >> 8, y
    jmp  ip_addr
scw_r438:
    ld   16, ac
    ld   ac, [v1]
pa5_l:
    ld   [dc_ap], y
    ld   [dc_ai], x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   [ip_k], ac             ; broken: the crack (CRACK, the art's order)
    beq  pa5_s
    ld   CRACK >> 8, y
    ld   [dc_ai], ac
    and  0x3F, ac
    add  CRACK & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    and  [u0], ac
    ld   ac, [u0]
pa5_s:
    ld   [u0], ac
    ld   [w2], y
    ld   [w3], x
    ld   ac, [y,x]
    ld   [dc_ai], ac
    inc
    ld   ac, [dc_ai]
    ld   [w3], ac
    add  2, ac
    bne  pa5_n
    ld   1, ac
pa5_n:
    ld   ac, [w3]
    ld   [v1], ac
    dec
    ld   ac, [v1]
    bne  pa5_l
    ld   [w0], ac
    inc
    ld   ac, [w0]
    ld   [v0], ac
    dec
    ld   ac, [v0]
    bne  pa5_c
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ip_frame - a one-pixel frame of color AC round the cell art at byte
; column w0, line pair w1 (w0, w1 kept)
fr_row:
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
    ld   [w0], ac
    dec
    ld   ac, [w0]
    ld   LINK_LO, x             ; CALL ip_addr
    ld   scw_r442, [x]
    ld   LINK_HI, x
    ld   scw_r442 >> 8, [x]
    ld   ip_addr >> 8, y
    jmp  ip_addr
scw_r442:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    ld   [w2], y
    ld   [w3], x
    ld   [y,x], ac
    and  0x0F, ac
    or   [v5], ac
    ld   ac, [y,x]
    ld   4, ac
    ld   ac, [v1]
fw5_l:
    ld   [w2], ac
    add  2, ac
    ld   ac, [w2]
    ld   ac, y
    ld   [v6], ac
    ld   ac, [y,x]
    ld   [v1], ac
    dec
    ld   ac, [v1]
    bne  fw5_l
    ld   [w2], ac
    add  2, ac
    ld   ac, y
    ld   [y,x], ac
    and  0xF0, ac
    or   [v4], ac
    ld   ac, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; inv_slots - the seven slots: each its frame, its art and what is in it
inv_subject:
    ld   [inv_k], ac
    sub  3, ac
    bcs  iu_c
    ld   [inv_k], ac
    sub  7, ac
    bcc  iu_n
    ld   2, ac
    bra  iu_w
iu_c:
    ld   [inv_k], ac
    add  cl_t, ac
    ld   ac, x
    ld   [x], ac
    beq  iu_w
    ld   3, ac
    bra  iu_w
iu_n:
    clr  ac
iu_w:
    ld   ac, [s_who]
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; inv_load - the panel's subject from carry slot inv_k: INSTALL for a part
; that says where it goes, PUT ON SUIT for the suit.  An empty slot:
; nothing.  The rest of subj_load

#overlay 0x4600
ip_frame:
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
    ld   ac, [v4]               ; v4 the color low, v5 high, v6 both
    shl
    shl
    shl
    shl
    ld   ac, [v5]
    or   [v4], ac
    ld   ac, [v6]
    ld   [w1], ac               ; the top and the bottom
    dec
    ld   ac, [w1]
    ld   LINK_LO, x             ; CALL fr_row
    ld   scw_r439, [x]
    ld   LINK_HI, x
    ld   scw_r439 >> 8, [x]
    ld   fr_row >> 8, y
    jmp  fr_row
scw_r439:
    ld   [w1], ac
    add  17, ac
    ld   ac, [w1]
    ld   LINK_LO, x             ; CALL fr_row
    ld   scw_r440, [x]
    ld   LINK_HI, x
    ld   scw_r440 >> 8, [x]
    ld   fr_row >> 8, y
    jmp  fr_row
scw_r440:
    ld   [w1], ac
    sub  16, ac
    ld   ac, [w1]
    ld   [w0], ac               ; the sides: the right pixel of the byte
    dec                         ; before, the left one of the byte after
    ld   ac, [w0]
    ld   LINK_LO, x             ; CALL ip_addr
    ld   scw_r441, [x]
    ld   LINK_HI, x
    ld   scw_r441 >> 8, [x]
    ld   ip_addr >> 8, y
    jmp  ip_addr
scw_r441:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    ld   16, ac
    ld   ac, [v1]
fs5_l:
    ld   [w2], y
    ld   [w3], x
    ld   [y,x], ac
    and  0x0F, ac
    or   [v5], ac
    ld   ac, [y,x]
    ld   [w2], ac
    add  10, ac
    ld   ac, y
    ld   [y,x], ac
    and  0xF0, ac
    or   [v4], ac
    ld   ac, [y,x]
    ld   [w3], ac
    add  2, ac
    bne  fs5_n
    ld   1, ac
fs5_n:
    ld   ac, [w3]
    ld   [v1], ac
    dec
    ld   ac, [v1]
    bne  fs5_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fr_row - line pair w1 of the frame: the right pixel of byte w0 - 1,
; bytes w0 to w0 + 3, the left pixel of w0 + 4 (ip_frame)
is_type:
    ld   [v7], ac
    sub  3, ac
    bcc  it5_g
    ld   [v7], ac
    add  cl_t, ac
    ld   ac, x
    ld   [x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
it5_g:
    ld   [v7], ac
    xor  3, ac
    bne  it5_b
    ld   [suit_on], ac          ; the suit, worn
    beq  it5_e
    ld   T_SUIT, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
it5_b:
    ld   [v7], ac
    xor  4, ac
    bne  it5_o
    ld   T_BATT, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
it5_o:
    ld   [v7], ac
    xor  5, ac
    bne  it5_e
    ld   T_O2, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
it5_e:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; is_art - slot v7's art at w0, w1
inv_install:
    ld   [inv_k], ac
    add  cl_t, ac
    ld   ac, [place]
    ld   ac, x
    ld   [x], ac
    ld   ac, [pl_t]
    ld   s_place & 0xFF, ac
    ld   ac, [R0]
    ld   s_place >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r470, [x]
    ld   LINK_HI, x
    ld   scw_r470 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r470:
    ld   inv_toggle >> 8, y
    jmp  inv_toggle

; the font's four pixel pairs for the colors (ip_color)

#overlay 0x4700
inv_slots:
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
    ld   LINK_LO, x             ; CALL pt_hide
    ld   scw_r443, [x]
    ld   LINK_HI, x
    ld   scw_r443 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r443:
    clr  ac
    ld   ac, [v7]
is5_l:
    ld   LINK_LO, x             ; CALL is_pos
    ld   scw_r444, [x]
    ld   LINK_HI, x
    ld   scw_r444 >> 8, [x]
    ld   is_pos >> 8, y
    jmp  is_pos
scw_r444:
    ld   0x0B, ac               ; the frame: gray, yellow under the mouse
    ld   ac, [u0]
    ld   [inv_k], ac
    xor  [v7], ac
    bne  is5_f
    ld   0x0E, ac
    ld   ac, [u0]
is5_f:
    ld   [u0], ac
    ld   LINK_LO, x             ; CALL ip_frame
    ld   scw_r445, [x]
    ld   LINK_HI, x
    ld   scw_r445 >> 8, [x]
    ld   ip_frame >> 8, y
    jmp  ip_frame
scw_r445:
    ld   LINK_LO, x             ; CALL is_art
    ld   scw_r446, [x]
    ld   LINK_HI, x
    ld   scw_r446 >> 8, [x]
    ld   is_art >> 8, y
    jmp  is_art
scw_r446:
    ld   LINK_LO, x             ; what is in it, after a clear
    ld   scw_r447, [x]
    ld   LINK_HI, x
    ld   scw_r447 >> 8, [x]
    ld   is_pos >> 8, y
    jmp  is_pos
scw_r447:
    ld   [w0], ac
    add  6, ac
    ld   ac, [w0]
    ld   [w1], ac
    add  10, ac
    ld   ac, [w1]
    ld   26, ac
    ld   ac, [w4]
    ld   [v7], ac
    sub  3, ac
    bcc  is5_w
    ld   38, ac
    ld   ac, [w4]
is5_w:
    ld   5, ac
    ld   ac, [w5]
    ld   0x11, ac
    ld   ac, [w6]
    ld   [w0], ac
    ld   ac, [u1]
    ld   LINK_LO, x             ; CALL ip_fill
    ld   scw_r448, [x]
    ld   LINK_HI, x
    ld   scw_r448 >> 8, [x]
    ld   ip_fill >> 8, y
    jmp  ip_fill
scw_r448:
    ld   [u1], ac
    ld   ac, [w0]
    ld   0x0A, ac
    ld   ac, [w4]
    ld   1, ac
    ld   ac, [w5]
    ld   LINK_LO, x             ; CALL ip_color
    ld   scw_r449, [x]
    ld   LINK_HI, x
    ld   scw_r449 >> 8, [x]
    ld   ip_color >> 8, y
    jmp  ip_color
scw_r449:
    ld   LINK_LO, x             ; CALL is_val
    ld   scw_r450, [x]
    ld   LINK_HI, x
    ld   scw_r450 >> 8, [x]
    ld   is_val >> 8, y
    jmp  is_val
scw_r450:
    ld   [v7], ac
    inc
    ld   ac, [v7]
    xor  7, ac
    bne  is5_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; is_pos - w0, w1 = slot v7's art (SPOS).  A leaf.
s_iempty:
    #d "EMPTY", 0x00
s_isuit:
    #d "MK1 WORK SUIT", 0x00
s_ioff:
    #d "TAKEN OFF", 0x00
s_icell:
    #d "CELL ", 0x00
s_il:
    #d " L", 0x00
s_inone:
    #d "NONE", 0x00

; ============================================================
; SCRAP.NAV: the navigation screen (scrap_nav.masm), read in at the helm
; (at SCRAP.INV's addresses: #overlay2, gen_plc.py --swap ...,NAV,2)
; ============================================================
; ============================================================
; scrap_nav.masm - SCRAPWRIGHT's navigation screen: SCRAP.NAV, SCRAP.NV2
; ============================================================
;
; Included at the end of scrap.masm as #overlay2: the region x4100-x4CFF
; (gen_plc.py --swap 0x4100,0x4D00,NAV,2: SCRAP.NAV, over SCRAP.INV's
; place, rooms_build's work space: a rebuild waits) and what does not fit
; in x3600-x3FFF (--swap 0x3600,0x4000,NV2,2: SCRAP.NV2, over the
; actions table and the cell art, which SCRAP.ART puts back when the
; screen closes).  nav_action
; reads them in when NAVIGATE is picked at the helm; nav_main reads the
; last of it, SCRAP.NV3, into the file system's buffer (x4E00-x4FFF; --swap
; 0x4E00,0x5000,NV3,2) after the sector file, its last card read.  The flight itself is
; resident (scrap_fl.masm): it goes on when you leave this screen.
;
; Row 0 is a 1 bpp status row (nv_stat): the ship's date and time, the
; nitrogen (kg), its delta-v, the batteries.  Under it the view is 2 bpp
; while the screen is up (view_mode): the sector map, 256 x 184 square
; pixels in byte columns 8-71 (a position a byte), the tug in the middle:
; a dotted blue grid fixed in space (nv_gmv); the tug a white notched triangle at
; its heading, gold dots the way it drifts; the sector's objects
; (SCRAP/K3A, read to x5400 with prt_load: gen_scrap.SECTOR): a station
; on an asteroid as a white circle its size, a derelict as a gold
; asterisk until you have visited it (FL_VIS), then a diamond; the
; selected one in gold corners.  + and - zoom in doubling steps: 4 to
; 512 m a pixel (1 to 128 km across, near enough: 1.024 km << the zoom).
;
; The panel is a control panel: boxed blocks with inverse titles, FLIGHT
; (heading, docked: no speed, which means something only against the
; target), PROPULSION (nitrogen, mass, thrusters) and TARGET (the
; selected object: name, kind, registry, range, radar return, visited,
; the tug's speed toward it and across), then the keys as inverse caps.
;
; Keys: Left / Right (A, D) spin the tug up (1/256 of a heading step a
; frame more, to NAV_SPIN; it keeps spinning: nv_spt), R stops the spin,
; Up / Down (W, S) thrust forward and back while held, Q / E sideways
; (left, right of the heading, at the back thrust), + - zoom, a click
; on an object or Tab picks the target, C the docking and comms screen
; (SCRAP.DCK, scrap_dck.masm: hailing, docking, undocking), Esc back to
; the ship.
;
; Date: 11/09/2026
; ============================================================

NV_T    = 0xB0              ; FL_PG: frames, 0-15 (the map every 8, the panel every 16)
NV_TW   = 0xB1              ;   (free)
NV_N    = 0xB2              ;   points drawn (nv_put)
NV_ZS   = 0xB3              ;   the map's shift: metres >> NV_ZS = pixels
NV_DL   = 0xB4              ;   an object from the tug: dx, dy (metres, 2 bytes each)
NV_GX   = 0xB8              ;   the grid's offsets (nv_gmv): its lines where x + GX,
NV_GY   = 0xB9              ;   y + GY are 0 mod 64 (FF: none drawn yet)
FL_SPN  = 0xBA              ; the spin: 1/256 heading steps a frame (signed), kept
FL_HF   = 0xBB              ;   the heading's 1/256 steps
FL_SFL  = 0xBC              ;   the frame counter when the spin was last worked out
FL_SFH  = 0xBD              ;   (nv_spt: the spin goes on off this screen too)
FL_STP  = 0xBE              ;   1: R, the spin brought down to 0 (1 a frame)
NV_Q    = 0xC0              ;   the status row's numbers (nv_stat): month, day, hour,
NV_QMO  = 0xC0              ;     minute, second (a byte each), then the nitrogen
NV_QD   = 0xC1              ;     (kg), the delta-v (m/s) and the batteries
NV_QH   = 0xC2              ;     (2 bytes each)
NV_QMI  = 0xC3
NV_QS   = 0xC4
NV_QL   = 0xC5
NV_QDV  = 0xC7
NV_QB   = 0xC9
NV_SEL  = 0x80              ; FL_PG + x80 up (rooms_build's, free while this is up):
                            ;   the selected object
NV_ANG  = 0x81              ;   nv_cm's angle (0-31)
NV_I    = 0x82              ;   the object being drawn
NV_AX   = 0x8A              ;   nv_atan's x, y (2 bytes each, x8A-x8D)
NV_AY   = 0x8C
NV_RS   = 0x8E              ;   nv_dot's sum (2 bytes)
NV_OX   = 0x90              ;   each object's pixel: x (x90-x97), y (x98-x9F); FF off
NV_OY   = 0x98
NV_E    = 0xA0              ;   an object's 10 bytes (nv_ent):
E_X     = 0xA0              ;     x, y (metres), its size (radius / half width)
E_Y     = 0xA2
E_R     = 0xA4
E_SH    = 0xA6              ;     0 a station (a circle), 1 a derelict
E_NM    = 0xA7              ;     its strings in page x55: name, registry, kind
E_RF    = 0xA8              ;     its radar factor (size x 100 / 16)
NV_S1   = 0xAA              ;   the strings: registry, kind (low bytes)
NV_S2   = 0xAB
NV_RG   = 0xAC              ;   the target's range, metres (2 bytes)
                            ; the points drawn, to rub out (255 at most): x, y in
                            ;   the screen bytes no line shows (offsets 0-30 even
                            ;   of pages x61-x7F, x81-x9F; nv_put)
SEC     = 0x5400            ; the sector file: the count, the objects from x5410
SEC_STR = 0x55              ;   (SEC_REC bytes each), their strings in page x55

; nav_main - the screen until Esc (or you die); FL_NAV while it is up

#overlay 0x4800
is_art:
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
    ld   LINK_LO, x             ; CALL is_type
    ld   scw_r451, [x]
    ld   LINK_HI, x
    ld   scw_r451 >> 8, [x]
    ld   is_type >> 8, y
    jmp  is_type
scw_r451:
    bne  ia5_a
    ld   4, ac                  ; empty: black
    ld   ac, [w4]
    ld   16, ac
    ld   ac, [w5]
    clr  ac
    ld   ac, [w6]
    ld   LINK_LO, x             ; CALL ip_fill
    ld   scw_r452, [x]
    ld   LINK_HI, x
    ld   scw_r452 >> 8, [x]
    ld   ip_fill >> 8, y
    jmp  ip_fill
scw_r452:
    ld   sc_leave >> 8, y
    jmp  sc_leave
ia5_a:
    ld   ac, [u0]
    shr  ac
    shr  ac
    add  ART_PG, ac
    ld   ac, [dc_ap]
    ld   [u0], ac
    and  3, ac
    shl
    shl
    shl
    shl
    shl
    shl
    ld   ac, [dc_ai]
    clr  ac                     ; a broken part in a hand or on the back:
    ld   ac, [ip_k]             ;   cracked
    ld   [v7], ac
    sub  3, ac
    bcc  ia5_k
    ld   [v7], ac
    add  cl_d, ac
    ld   ac, x
    ld   [x], ac
    sub  8, ac
    bcs  ia5_k
    ld   1, ac
    ld   ac, [ip_k]
ia5_k:
    ld   LINK_LO, x             ; CALL ip_art
    ld   scw_r453, [x]
    ld   LINK_HI, x
    ld   scw_r453 >> 8, [x]
    ld   ip_art >> 8, y
    jmp  ip_art
scw_r453:
    clr  ac
    ld   ac, [ip_k]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; is_val - what slot v7 holds, as text at w0, w1: a part's name or
; EMPTY; MK1 WORK SUIT or TAKEN OFF; CELL n%; n L; NONE
is_val:
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
    ld   [v7], ac
    sub  3, ac
    bcc  iv5_g
    ld   LINK_LO, x             ; CALL is_type
    ld   scw_r454, [x]
    ld   LINK_HI, x
    ld   scw_r454 >> 8, [x]
    ld   is_type >> 8, y
    jmp  is_type
scw_r454:
    bne  iv5_n
    ld   s_iempty & 0xFF, ac
    ld   ac, [R0]
    ld   s_iempty >> 8, ac
    bra  iv5_t
iv5_n:
    add  TB_NAMEL, ac           ; its name (put_name's)
    ld   ac, [u6]
    add  TB_NAMEH - TB_NAMEL, ac
    ld   ac, [u7]
    ld   TAB_PG, ac
    ld   ac, [u5]
    ld   LINK_LO, x             ; CALL tab_ptr
    ld   scw_r455, [x]
    ld   LINK_HI, x
    ld   scw_r455 >> 8, [x]
    ld   tab_ptr >> 8, y
    jmp  tab_ptr
scw_r455:
    ld   LINK_LO, x             ; CALL ip_text
    ld   scw_r456, [x]
    ld   LINK_HI, x
    ld   scw_r456 >> 8, [x]
    ld   ip_text >> 8, y
    jmp  ip_text
scw_r456:
    ld   sc_leave >> 8, y
    jmp  sc_leave
iv5_g:
    ld   is_gear >> 8, y
    jmp  is_gear
iv5_t:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ip_text
    ld   scw_r457, [x]
    ld   LINK_HI, x
    ld   scw_r457 >> 8, [x]
    ld   ip_text >> 8, y
    jmp  ip_text
scw_r457:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; is_gear - the gear slots' text (is_val)

#overlay 0x4900
is_gear:
    ld   [v7], ac
    xor  3, ac
    bne  ig5_b
    ld   [suit_on], ac
    beq  ig5_off
    ld   s_isuit & 0xFF, ac
    ld   ac, [R0]
    ld   s_isuit >> 8, ac
    bra  ig5_t
ig5_off:
    ld   s_ioff & 0xFF, ac
    ld   ac, [R0]
    ld   s_ioff >> 8, ac
    bra  ig5_t
ig5_b:
    ld   [v7], ac
    xor  4, ac
    bne  ig5_o
    ld   s_icell & 0xFF, ac
    ld   ac, [R0]
    ld   s_icell >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ip_text
    ld   scw_r458, [x]
    ld   LINK_HI, x
    ld   scw_r458 >> 8, [x]
    ld   ip_text >> 8, y
    jmp  ip_text
scw_r458:
    ld   [batt], ac
    ld   LINK_LO, x             ; CALL ip_num
    ld   scw_r459, [x]
    ld   LINK_HI, x
    ld   scw_r459 >> 8, [x]
    ld   ip_num >> 8, y
    jmp  ip_num
scw_r459:
    ld   0x25, ac
    ld   LINK_LO, x             ; CALL ip_char
    ld   scw_r460, [x]
    ld   LINK_HI, x
    ld   scw_r460 >> 8, [x]
    ld   ip_char >> 8, y
    jmp  ip_char
scw_r460:
    ld   sc_leave >> 8, y
    jmp  sc_leave
ig5_o:
    ld   [v7], ac
    xor  5, ac
    bne  ig5_u
    ld   [o2], ac
    ld   LINK_LO, x             ; CALL ip_num
    ld   scw_r461, [x]
    ld   LINK_HI, x
    ld   scw_r461 >> 8, [x]
    ld   ip_num >> 8, y
    jmp  ip_num
scw_r461:
    ld   s_il & 0xFF, ac
    ld   ac, [R0]
    ld   s_il >> 8, ac
    bra  ig5_t
ig5_u:
    ld   s_inone & 0xFF, ac
    ld   ac, [R0]
    ld   s_inone >> 8, ac
ig5_t:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ip_text
    ld   scw_r462, [x]
    ld   LINK_HI, x
    ld   scw_r462 >> 8, [x]
    ld   ip_text >> 8, y
    jmp  ip_text
scw_r462:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; inv_hover - the slot under the pointer (art pixel x m_x / 4, line pair
; m_y / 2): inv_k, the frames, the panel.  The rest of hover_update
inv_load:
    ld   [inv_k], ac
    add  cl_t, ac
    ld   ac, [u2]
    ld   ac, x
    ld   [x], ac
    ld   ac, [s_t]
    bne  il_ok
    clr  ac
    ld   ac, [s_who]
    ld   ac, [n_act]
    ld   sl_e >> 8, y
    jmp  sl_e
il_ok:
    ld   [u2], ac
    add  3, x
    ld   [x], ac
    ld   ac, [s_f]
    clr  ac
    ld   ac, [s_r]
    ld   ac, [s_b]
    ld   ac, [n_act]
    ld   ACT_PG, y
    ld   [s_t], ac
    add  TB_SKILL, x
    ld   [y,x], ac
    and  0xC0, ac
    beq  il_e
    ld   A_INSTALL, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r468, [x]
    ld   LINK_HI, x
    ld   scw_r468 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r468:
il_e:
    ld   [s_t], ac
    xor  T_SUIT, ac
    bne  il_g
    ld   A_SUITON, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r469, [x]
    ld   LINK_HI, x
    ld   scw_r469 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r469:
il_g:
    ld   sl_a >> 8, y
    jmp  sl_a

; inv_install - INSTALL in the inventory: back to the ship to pick the
; cell (place, pl_t).  The rest of do_action

#overlay 0x4A00
inv_hover:
    ld   LINK_LO, x             ; CALL in_view
    ld   scw_r463, [x]
    ld   LINK_HI, x
    ld   scw_r463 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r463:
    bne  ih_v
    ld   LINK_LO, x             ; the panel: no pointer drawn
    ld   scw_r464, [x]
    ld   LINK_HI, x
    ld   scw_r464 >> 8, [x]
    ld   hover_panel >> 8, y
    jmp  hover_panel
scw_r464:
    ld   sc_leave >> 8, y
    jmp  sc_leave
ih_v:
    ld   0xFF, ac
    ld   ac, [m_sel]
    ld   ac, [u3]
    ld   LINK_LO, x             ; CALL pt_xy
    ld   scw_r465, [x]
    ld   LINK_HI, x
    ld   scw_r465 >> 8, [x]
    ld   pt_xy >> 8, y
    jmp  pt_xy
scw_r465:
    ld   [u1], ac               ; the rows: 22 + 32 i, the frame a line more
    sub  21, ac
    bcs  ih_k
    ld   ac, [u1]
    and  31, ac
    sub  18, ac
    bcc  ih_k
    ld   [u1], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u4]
    sub  4, ac
    bcc  ih_k
    ld   [u2], ac               ; the columns: gear 5-68, carrying 71 on
    sub  5, ac
    bcs  ih_k
    sub  64, ac
    bcs  ih_g
    ld   [u2], ac
    sub  71, ac
    bcs  ih_k
    ld   [u4], ac
    sub  3, ac
    bcc  ih_k
    ld   [u4], ac
    ld   ac, [u3]
    bra  ih_k
ih_g:
    ld   [u4], ac
    add  3, ac
    ld   ac, [u3]
ih_k:
    ld   [inv_k], ac
    xor  [u3], ac
    beq  ih_e
    ld   [u3], ac
    ld   ac, [inv_k]
    ld   LINK_LO, x             ; (the pointer drawn again)
    ld   scw_r466, [x]
    ld   LINK_HI, x
    ld   scw_r466 >> 8, [x]
    ld   inv_slots >> 8, y
    jmp  inv_slots
scw_r466:
    ld   [lock], ac
    bne  ih_x
    ld   LINK_LO, x             ; CALL inv_subject
    ld   scw_r467, [x]
    ld   LINK_HI, x
    ld   scw_r467 >> 8, [x]
    ld   inv_subject >> 8, y
    jmp  inv_subject
scw_r467:
ih_x:
    ld   sc_leave >> 8, y
    jmp  sc_leave
ih_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; inv_subject - the panel on slot inv_k: a carried part (s_who 3), the
; gear (you, 2), nothing (0).  A leaf.
FNT_B:
    #d8 0, 0, 0, 0, 0, 5, 0, 0, 2, 2, 0, 0, 1, 0, 2, 1
    #d8 7, 7, 7, 7, 4, 7, 7, 2, 7, 7, 0, 0, 0, 0, 1, 2
    #d8 0, 5, 3, 6, 3, 7, 1, 6, 5, 7, 2, 5, 7, 5, 5, 2
    #d8 1, 6, 5, 3, 2, 7, 2, 5, 5, 2, 7, 0, 0, 0, 0, 0


#overlay 0x4B00
LBL:
    #d8 1, 3, 10, 3, zl_0 & 0xFF
    #d8 60, 3, 10, 3, zl_1 & 0xFF
    #d8 2, 14, 14, 1, zl_2 & 0xFF
    #d8 35, 14, 14, 1, zl_3 & 0xFF
    #d8 9, 25, 11, 1, zl_4 & 0xFF
    #d8 9, 57, 11, 1, zl_5 & 0xFF
    #d8 9, 89, 11, 1, zl_6 & 0xFF
    #d8 9, 121, 11, 1, zl_7 & 0xFF
    #d8 42, 25, 11, 1, zl_8 & 0xFF
    #d8 42, 57, 11, 1, zl_9 & 0xFF
    #d8 42, 89, 11, 1, zl_10 & 0xFF
    #d8 0xFF
zl_0:
    #d "INVENTORY", 0x00
zl_1:
    #d "I - CLOSE", 0x00
zl_2:
    #d "GEAR", 0x00
zl_3:
    #d "CARRYING", 0x00
zl_4:
    #d "SUIT", 0x00
zl_5:
    #d "BATTERY", 0x00
zl_6:
    #d "O2", 0x00
zl_7:
    #d "UTILITY", 0x00
zl_8:
    #d "LEFT HAND", 0x00
zl_9:
    #d "RIGHT HAND", 0x00
zl_10:
    #d "BACK", 0x00


#overlay 0x5600
pt_hide:
    ld   PT_TAB >> 8, y
    ld   PT_ON & 0xFF, x
    ld   [y,x], ac
    beq  ph_e
    ld   0, [y,x]
    clr  ac
    ld   pt_walk >> 8, y
    jmp  pt_walk
pt_show:
    ld   PT_TAB >> 8, y
    ld   PT_ON & 0xFF, x
    ld   [y,x], ac
    bne  ph_e
    ld   [m_yh], ac
    beq  ps_v
    ld   [m_yl], ac
    sub  0x80, ac
    bcc  ph_e                   ; over the panel: none
ps_v:
    ld   [m_yl], ac
    shr  ac
    ld   ac, [T1]
    ld   [m_yh], ac
    beq  ps_1
    ld   [T1], ac
    or   0x80, ac
    ld   ac, [T1]
ps_1:
    ld   [m_xl], ac
    shr  ac
    shr  ac
    ld   ac, [T0]
    ld   [m_xh], ac
    shl
    shl
    shl
    shl
    shl
    shl
    or   [T0], ac
    ld   ac, [T0]
    ld   1, [y,x]
    ld   PT_P & 0xFF, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   PT_C & 0xFF, x
    ld   [T0], ac
    shr  ac
    ld   ac, [y,x]
    ld   PT_B & 0xFF, x
    ld   [T0], ac
    and  1, ac
    beq  ps_b
    ld   48, ac                 ; an odd pixel: the shifted half
ps_b:
    ld   ac, [y,x]
    ld   1, ac
    ld   pt_walk >> 8, y
    jmp  pt_walk
ph_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

rep_bar:
    ld   JB_B >> 8, y
    ld   JB_B & 0xFF, x
    ld   240, [y,x]
    ld   [wk_l], ac
    sub  240, ac
    ld   JB_TL & 0xFF, x
    ld   ac, [y,x]
    ld   [wk_h], ac
    bcc  rbar_1
    dec
rbar_1:
    ld   JB_TH & 0xFF, x
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rep_step - a repair's damage step done: the cell cut_x, cut_y a step
; less damaged (kept if the repair stops), drawn again, the panel too
rep_step:
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
    ld   [cut_x], ac
    ld   ac, [g_x]
    ld   [cut_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r1, [x]
    ld   LINK_HI, x
    ld   scw_r1 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r1:
    ld   [c_f], ac
    beq  rst_e
    ld   [a_pg], ac             ; the flag byte, two pages up
    add  2, ac
    ld   ac, y
    ld   [a_ix], x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r2, [x]
    ld   LINK_HI, x
    ld   scw_r2 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r2:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
rst_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave



; ============================================================
; main
; ============================================================
fl_locks:
    ld   ac, [u6]
    ld   TUG_LKX, ac
    ld   ac, [u5]
fk2_l:
    ld   [u5], ac               ; chunk 6 (y >> 4) + x >> 4: page x60 + 4k
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  6 * (TUG_LKY >> 4), ac
    shl
    shl
    add  0x60, ac
    ld   ac, y
    ld   [u5], ac
    and  15, ac
    add  16 * (TUG_LKY & 15), ac
    ld   ac, x
    ld   [y,x], ac
    and  0x40, ac
    or   [u7], ac
    ld   ac, [y,x]
    ld   [u5], ac
    xor  WRECK_LKX, ac
    beq  fk2_e
    ld   WRECK_LKX, ac
    ld   ac, [u5]
    ld   [u6], ac
    ld   ac, [u7]
    bra  fk2_l
fk2_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_tick - once a frame: a held thrust (with nitrogen left) into the
; velocity, the velocity into the position; nothing while docked

#overlay 0x5700
pt_walk:
    ld   ac, [T7]               ; T7: 1 draw, 0 put back
    ld   PT_TAB >> 8, y
    ld   PT_C & 0xFF, x
    ld   [y,x], ac
    ld   ac, [T4]               ; T4: the byte column
    ld   PT_P & 0xFF, x
    ld   [y,x], ac
    ld   ac, [T5]               ; T5: the first line pair
    ld   PT_B & 0xFF, x
    ld   [y,x], ac
    ld   ac, [T6]               ; T6: PT_TAB + 16 c
    clr  ac
    ld   ac, [T3]               ; T3: PT_SV + 8 c
pw_c:
    ld   [T4], ac
    sub  80, ac
    bcc  pw_e
    ld   [T4], ac
    shl
    add  0x61, ac
    ld   ac, [T0]               ; T0, T1: the screen page, offset
    ld   [T5], ac
    sub  112, ac
    bcs  pw_lo
    ld   [T5], ac
    shl
    sub  223, ac
    bra  pw_o
pw_lo:
    ld   [T5], ac
    shl
    add  32, ac
pw_o:
    ld   ac, [T1]
    clr  ac
    ld   ac, [T2]               ; T2: the line pair r
pw_r:
    ld   [T5], ac
    add  [T2], ac
    sub  192, ac
    bcc  pw_n
    ld   PT_TAB >> 8, y
    ld   [T7], ac
    bne  pw_d
    ld   [T3], ac               ; put back
    add  [T2], ac
    add  PT_SV & 0xFF, x
    ld   [y,x], ac
    bra  pw_w
pw_d:
    ld   [T0], y                ; kept, then the pointer over it
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   PT_TAB >> 8, y
    ld   [T3], ac
    add  [T2], ac
    add  PT_SV & 0xFF, x
    ld   [u0], ac
    ld   ac, [y,x]
    ld   [T6], ac
    add  [T2], ac
    add  PT_TAB & 0xFF, x
    ld   [y,x], ac
    and  [u0], ac
    ld   ac, [u0]
    ld   [T6], ac
    add  [T2], ac
    add  (PT_TAB & 0xFF) + 8, x
    ld   [y,x], ac
    or   [u0], ac
pw_w:
    ld   [T0], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [T1], ac
    add  2, ac
    bne  pw_x
    ld   1, ac
pw_x:
    ld   ac, [T1]
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  8, ac
    bne  pw_r
pw_n:
    ld   [T4], ac
    inc
    ld   ac, [T4]
    ld   [T6], ac
    add  16, ac
    ld   ac, [T6]
    ld   [T3], ac
    add  8, ac
    ld   ac, [T3]
    xor  24, ac
    bne  pw_c
pw_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; rep_bar - after job_start for a repair: a damage step a 16th of the
; work's bar (JB_B = 16 x 15 frames' work), so jb_tick takes a step off
; each time (rep_step).  A leaf.
fl_alarm:
    clr  ac
    ld   ac, [w3]
    ld   [w2], ac
    beq  fl_al_s
    ld   [w1], ac               ; 300 = x012C
    sub  1, ac
    blt  fl_al_p
    bne  fl_al_s
    ld   [w0], ac
    sub  0x2C, ac
    bcc  fl_al_s
fl_al_p:
    ld   1, ac
    ld   ac, [w3]
    ld   [w2], ac
    ld   ac, [R0]
    ld   75, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; R3:R2 = metres in 10 s
    ld   scw_r398, [x]
    ld   LINK_HI, x
    ld   scw_r398 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r398:
    ld   [w1], ac
    sub  [R3], ac
    blt  fl_al_i
    bne  fl_al_s
    ld   [w0], ac
    sub  [R2], ac
    bcc  fl_al_s
fl_al_i:
    ld   2, ac
    ld   ac, [w3]
fl_al_s:
    ld   FL_PG, y
    ld   FL_AL, x
    ld   [y,x], ac
    xor  [w3], ac
    beq  fl_al_e
    ld   [w3], ac
    ld   ac, [y,x]
    ld   [dirty], ac
    or   2, ac
    ld   ac, [dirty]
fl_al_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fl_hit - the tug hit the KESTREL 9: by speed (w1:w0 in 1/256 m a frame)
; under 2 m/s a bump, to 20 m/s 1-3 damage steps on 4 cells of the tug,
; to 100 m/s 4-11 on 16, more: 15 (broken) on 24.  Then stopped where it
; was last clear.  The rest of fl_check

#overlay 0x5800
fl_fuel:
    ld   [n_fuel], ac
    ld   ac, [R0]
    ld   N2_TANK_L >> 1, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r378, [x]
    ld   LINK_HI, x
    ld   scw_r378 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r378:
    ld   [R2], ac               ; x 2
    shl
    ld   ac, [R2]
    ld   [R3], ac
    bcc  ff_1
    shl
    inc
    bra  ff_2
ff_1:
    shl
ff_2:
    ld   ac, [R3]
    ld   FL_PG, y
    ld   FL_FUL, x
    ld   [R2], ac
    sub  [y,x], ac
    ld   ac, [R2]
    ld   FL_FUH, x
    ld   [R3], ac
    bcc  ff_3
    dec
    blt  ff_0                   ; (R3 was 0: a borrow past it)
ff_3:
    sub  [y,x], ac
    bcs  ff_0
    ld   ac, [R3]
    bra  ff_s
ff_0:
    clr  ac
    ld   ac, [R2]
    ld   ac, [R3]
ff_s:
    ld   FL_FLL, x
    ld   [R2], ac
    ld   ac, [y,x]
    ld   FL_FLH, x
    ld   [R3], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL fl_dv
    ld   scw_r379, [x]
    ld   LINK_HI, x
    ld   scw_r379 >> 8, [x]
    ld   fl_dv >> 8, y
    jmp  fl_dv
scw_r379:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fl_dv - a frame's thrust for the heading: forward on x (cos h) and y
; (sin h = cos (h + 24)), back (half, the other way: h + 16, h + 8),
; left and right (half: h + 24, h + 16 and h + 8, h)
fl_hit:
    ld   LINK_LO, x             ; CALL fl_speed
    ld   scw_r399, [x]
    ld   LINK_HI, x
    ld   scw_r399 >> 8, [x]
    ld   fl_speed >> 8, y
    jmp  fl_speed
scw_r399:
    clr  ac
    ld   ac, [w4]               ; cells
    ld   [w1], ac
    bne  fh_2
    ld   [w0], ac
    sub  9, ac
    bcs  fh_go
    ld   [w0], ac
    sub  85, ac
    bcs  fh_1
fh_2:
    ld   [w1], ac               ; 427 = x01AB
    sub  1, ac
    blt  fh_3
    bne  fh_4
    ld   [w0], ac
    sub  0xAB, ac
    bcc  fh_4
fh_3:
    ld   16, ac
    ld   ac, [w4]
    ld   4, ac
    ld   ac, [w5]               ; the least steps
    ld   7, ac
    ld   ac, [w6]               ; and a random 0-7 more
    bra  fh_go
fh_1:
    ld   4, ac
    ld   ac, [w4]
    ld   1, ac
    ld   ac, [w5]
    ld   1, ac
    ld   ac, [w6]
    bra  fh_go
fh_4:
    ld   24, ac
    ld   ac, [w4]
    ld   15, ac
    ld   ac, [w5]
    clr  ac
    ld   ac, [w6]
fh_go:
    ld   fl_dmg >> 8, y
    jmp  fl_dmg

; fl_dmg - w4 random cells of the tug: a wall, door or part (F_DMG or
; F_STRUCT) takes w5 + (random & w6) damage steps (15 at most).  Then
; fl_stop.  The rest of fl_hit
fl_speed:
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
    ld   FL_VX + 2, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r393, [x]
    ld   LINK_HI, x
    ld   scw_r393 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r393:
    ld   [u0], ac
    ld   ac, [w0]
    ld   [u1], ac
    ld   ac, [w1]
    ld   FL_VY + 2, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r394, [x]
    ld   LINK_HI, x
    ld   scw_r394 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r394:
    ld   LINK_LO, x             ; CALL fl_max
    ld   scw_r395, [x]
    ld   LINK_HI, x
    ld   scw_r395 >> 8, [x]
    ld   fl_max >> 8, y
    jmp  fl_max
scw_r395:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fl_save - the position kept as the last one clear of the hull (FL_SV);
; fl_back (AC 1) puts it back.  A leaf.

#overlay 0x5900
draw_alarm:
    ld   FL_PG, y
    ld   FL_AL, x
    ld   [y,x], ac
    bne  da_go
    ld   0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r411, [x]
    ld   LINK_HI, x
    ld   scw_r411 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r411:
    ld   sc_leave >> 8, y
    jmp  sc_leave
da_go:
    ld   TINT_WARN | 0x04, ac
    ld   LINK_LO, x             ; CALL msg_tint
    ld   scw_r412, [x]
    ld   LINK_HI, x
    ld   scw_r412 >> 8, [x]
    ld   msg_tint >> 8, y
    jmp  msg_tint
scw_r412:
    ld   29, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_prox & 0xFF, ac
    ld   ac, [R0]
    ld   s_prox >> 8, ac
    ld   ac, [R1]
    ld   FL_PG, y
    ld   FL_AL, x
    ld   [y,x], ac
    xor  1, ac
    beq  fda_p
    ld   s_imp & 0xFF, ac
    ld   ac, [R0]
    ld   s_imp >> 8, ac
    ld   ac, [R1]
fda_p:
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r413, [x]
    ld   LINK_HI, x
    ld   scw_r413 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r413:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; map_see - map_get, but the KESTREL 9's side of the map (x from
; WRECK_LKX) is open space while the tug is undocked: what the view,
; the panel and walking see
fl_dock:
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   1, [y,x]
    ld   FL_VIS, x              ; the KESTREL 9 visited
    ld   [y,x], ac
    or   1, ac
    ld   ac, [y,x]
    ld   FL_AL, x
    ld   0x00, [y,x]
    ld   FL_VX, ac
    ld   ac, [u0]
fd_l:
    ld   [u0], x
    ld   0x00, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  FL_VY + 4, ac
    bne  fd_l
    ld   FL_PX, x
    ld   0x00, [y,x]
    ld   FL_PX + 1, x
    ld   0x00, [y,x]
    ld   FL_PX + 2, x
    ld   DOCK_X & 0xFF, [y,x]
    ld   FL_PX + 3, x
    ld   DOCK_X >> 8, [y,x]
    ld   FL_PY, x
    ld   0x00, [y,x]
    ld   FL_PY + 1, x
    ld   0x00, [y,x]
    ld   FL_PY + 2, x
    ld   DOCK_Y & 0xFF, [y,x]
    ld   FL_PY + 3, x
    ld   DOCK_Y >> 8, [y,x]
    ld   T_LOCK, ac
    ld   ac, [u7]
    ld   T_LOCK, ac
    ld   fl_locks >> 8, y
    jmp  fl_locks

; fl_locks - the tug's airlock cell (TUG_LKX, TUG_LKY) becomes kind u7, the
; KESTREL 9's (WRECK_LKX) kind AC.  A leaf (map_get's address code, inline).
map_see:
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
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r414, [x]
    ld   LINK_HI, x
    ld   scw_r414 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r414:
    ld   LINK_LO, x             ; CALL fl_far
    ld   scw_r415, [x]
    ld   LINK_HI, x
    ld   scw_r415 >> 8, [x]
    ld   fl_far >> 8, y
    jmp  fl_far
scw_r415:
    beq  ms_e
    ld   T_SPACE, ac
    ld   ac, [c_t]
    clr  ac
    ld   ac, [c_f]
    ld   ac, [c_b]
    ld   ac, [c_r]
ms_e:
    ld   [c_t], ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fl_far - AC = 1 when g_x is on the KESTREL 9's side and the tug is
; undocked.  A leaf.

#overlay 0x5C00
l_mul8:
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
    ld   LINK_LO, x             ; CALL mul8
    ld   scw_r365, [x]
    ld   LINK_HI, x
    ld   scw_r365 >> 8, [x]
    ld   mul8 >> 8, y
    jmp  mul8
scw_r365:
    bra  lm_x
l_div16:
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
    ld   LINK_LO, x             ; CALL div16
    ld   scw_r366, [x]
    ld   LINK_HI, x
    ld   scw_r366 >> 8, [x]
    ld   div16 >> 8, y
    jmp  div16
scw_r366:
    bra  lm_x
l_rand8:
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
    ld   LINK_LO, x             ; CALL rand8
    ld   scw_r367, [x]
    ld   LINK_HI, x
    ld   scw_r367 >> 8, [x]
    ld   rand8 >> 8, y
    jmp  rand8
scw_r367:
lm_x:
    ld   0x50, y
    clr  x
    ld   0xFF, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ============================================================
; scrap_fl.masm - SCRAPWRIGHT's flight: resident, so the tug flies on
; while you walk round it (the map screen is SCRAP.NAV, scrap_nav.masm)
; ============================================================
;
; Included in scrap.masm's code.  The state is in x4020-x403F and
; x4060-x407F (the rooms' tables there use 32 of their 64 entries).
;
; A sector of 64 x 64 km: positions in metres, 16.16 (4 bytes, the low
; first), the KESTREL 9's centre at WRECK_X, WRECK_Y.  Velocities in
; 1/2^24 m a frame, signed (4 bytes).  tug_scan sums the tug's mass (each
; cell's kind, TB_MASS, but loose parts) and its working thrusters once a
; second; fl_accel makes the acceleration A16 = n (THRUST_Q / mass) in
; 1/2^20 m a frame a frame, kept as FL_A8 << FL_AE.  fl_dv makes a frame's
; thrust forward (A16 cos h / 8 on x, sin on y) and back (half), and
; fl_tick adds one to the velocity each frame a thrust key is held (and
; there is nitrogen: a kg a second a thruster), then the velocity to
; the position.  Every 8 frames fl_check looks at the KESTREL 9: closer
; than WRECK_BOX metres each way from its centre is a hit (fl_hit:
; damage by speed, the tug stopped where it last was clear); closing
; within 300 m is PROXIMITY, and within 10 s of the hull IMPACT IN 10 S.
;
; Date: 11/09/2026
; ============================================================

FL_PG   = 0x40
FL_NAV  = 0x20              ; 1 while the navigation screen is up
FL_DOCK = 0x21              ; 1 docked to the KESTREL 9
FL_HD   = 0x22              ; heading 0-31 (0 east, 8 south: the screen's down)
FL_TH   = 0x23              ; this frame's thrust: its vector's offset (FL_DVX, FL_RVX, ...: SCRAP.NAV's keys), 0 none
FL_NT   = 0x24              ; working thrusters (tug_scan)
FL_ML   = 0x25              ; the tug's mass, 100 kg (tug_scan)
FL_MH   = 0x26
FL_AL   = 0x27              ; the alarm: 0, 1 proximity, 2 impact in 10 s
FL_A8   = 0x28              ; the acceleration: FL_A8 << FL_AE in 1/2^20 m a frame a frame
FL_AE   = 0x29
FL_FT   = 0x2A              ; thruster frames toward the next kg
FL_FUL  = 0x2B              ; kg burnt
FL_FUH  = 0x2C
FL_FLL  = 0x2D              ; kg left (the nitrogen by working intakes, less that burnt)
FL_FLH  = 0x2E
FL_ZM   = 0x2F              ; the map's zoom, 0-7 (SCRAP.NAV: 4 m a pixel << it)
FL_GPL  = 0x30              ; the gap to the KESTREL 9's hull at the last check, metres
FL_GPH  = 0x31
FL_CL   = 0x32              ; closing: metres in the last 8 frames (0 moving away)
FL_SV   = 0x33              ; x4033-x403A: the last position clear of the hull
FL_DX   = 0x3B              ; fl_rel: the KESTREL 9's centre from the tug, metres
FL_DY   = 0x3D
FL_VIS  = 0x3F              ; a bit a sector object: visited (docked to it); the
                            ;   KESTREL 9 is object 0
FL_PX   = 0x60              ; position x, y (16.16 metres)
FL_PY   = 0x64
FL_VX   = 0x68              ; velocity x, y (1/2^24 m a frame)
FL_VY   = 0x6C
FL_DVX  = 0x70              ; a frame's thrust forward: x, y (signed, 2 bytes each)
FL_DVY  = 0x72
FL_RVX  = 0x74              ; and back
FL_RVY  = 0x76
FL_LVX  = 0x78              ; and left (Q), right (E): half, sideways
FL_LVY  = 0x7A
FL_SVX  = 0x7C
FL_SVY  = 0x7E
                            ; x4078-x407F: SCRAP.NAV's
FL_GO   = 0xFF              ; (x40FF, rooms_build's space) the next screen: 2 the
                            ;   docking screen (SCRAP.DCK) after the map, 1 the map

; fl_init - in scrap_pwr.masm (SCRAP.PWR: the start)

; fl_dock - docked: at the port, stopped; the airlocks joined (TUG_LKX and
; WRECK_LKX, TUG_LKY, airlocks again).  A leaf; changes g_x, g_y and the
; map_get state.
fl_save:
    clr  ac
fl_back:
    ld   ac, [u3]
    ld   FL_PG, y
    clr  ac
    ld   ac, [u2]
fv_l:
    ld   [u3], ac
    bne  fv_b
    ld   [u2], ac
    add  FL_PX, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u2], ac
    add  FL_SV, x
    ld   [u1], ac
    ld   ac, [y,x]
    bra  fv_n
fv_b:
    ld   [u2], ac
    add  FL_SV, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u2], ac
    add  FL_PX, x
    ld   [u1], ac
    ld   ac, [y,x]
fv_n:
    ld   [u2], ac
    inc
    ld   ac, [u2]
    xor  8, ac
    bne  fv_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_check - every 8 frames, undocked: the KESTREL 9.  Inside its hull: a
; hit (fl_hit); else the gap kept, the closing speed and the alarm
tug_thr:
    ld   [c_t], ac
tt_b:                           ; (kind_base: a leaf here)
    sub  FACE0 + 3, ac
    bcs  tt_x
    add  FACE0, ac
    bra  tt_b
tt_x:
    add  FACE0 + 3, ac
    xor  T_THRUST, ac
    bne  tg_e
    ld   FL_PG, y
    ld   [c_f], ac
    sub  8, ac
    bcc  tg_e
    ld   FL_NT, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
tg_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_scan0 - tug_scan's: nothing counted yet (its parts, worth, antenna,
; mass, thrusters).  A leaf.

#overlay 0xC000
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
    ld   scw_r294, [x]
    ld   LINK_HI, x
    ld   scw_r294 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r294:
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

; job_start - a job of AC frames at full speed on the panel's part (s_t):
; 16 AC of work (wk), done at wk_r a frame (work_tick): 2 + the average
; of the quarters of the skills the part needs (TB_SKILL); in the suit
; half that and an eighth of the suit skill (not over it).  cut_t = 1
; while it runs.  A leaf.
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
    ld   [cut_m], ac            ; repairing: a damage step off
    xor  3, ac
    bne  jt_k
    ld   LINK_LO, x             ; CALL rep_step
    ld   scw_r297, [x]
    ld   LINK_HI, x
    ld   scw_r297 >> 8, [x]
    ld   rep_step >> 8, y
    jmp  rep_step
scw_r297:
jt_k:
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
; 25%", from column 44 (JB_N 16ths; the percent from JB_PCT)
shr16:
    ld   [R1], ac
    and  1, ac
    beq  sr_0
    ld   0x80, ac
sr_0:
    ld   ac, [T0]
    ld   [R0], ac
    shr  ac
    or   [T0], ac
    ld   ac, [R0]
    ld   [R1], ac
    shr  ac
    ld   ac, [R1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_accel - the acceleration from the mass and thrusters tug_scan found,
; then fl_fuel.  The end of tug_scan (its LEAVE)

#overlay 0xC200
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
    and  0x3F, ac               ; (bits 7:6: where it installs)
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
    ld   [w3], ac
    xor  A_NAV, ac
    bne  ma_t
    ld   nav_action >> 8, y
    jmp  nav_action
ma_t:
    ld   [w3], ac
    xor  A_TURN, ac
    bne  ma_3
    ld   turn_action >> 8, y
    jmp  turn_action
ma_3:
    ld   suit_action >> 8, y
    jmp  suit_action

; turn_action - TURN: a part that faces a way (an antenna, a radar, a
; thruster) next to the player, to its next facing (up, right, down,
; left), installed or loose as it was.  The rest of do_action
tug_mass:
    ld   ACT_PG, y
    ld   [c_t], ac
    add  TB_MASS, x
    ld   [y,x], ac
    ld   FL_PG, y
    ld   FL_ML, x
    add  [y,x], ac
    ld   ac, [y,x]
    bcc  tg_1
    ld   FL_MH, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
tg_1:
    ld   tug_thr >> 8, y
    jmp  tug_thr

; tug_thr - a working thruster counted.  The rest of tug_mass

#overlay 0xC400
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
    ld   0x5B, ac               ; [
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r298, [x]
    ld   LINK_HI, x
    ld   scw_r298 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r298:
    ld   JB_N >> 8, y
    ld   JB_N & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u6]
    clr  ac
    ld   ac, [u7]
jb_l:
    ld   [u7], ac               ; # for the 16ths done, - for the rest
    sub  [u6], ac
    ld   0x2D, ac
    bcc  jb_c
    ld   0x23, ac
jb_c:
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r299, [x]
    ld   LINK_HI, x
    ld   scw_r299 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r299:
    ld   [u7], ac
    inc
    ld   ac, [u7]
    xor  16, ac
    bne  jb_l
    ld   0x5D, ac               ; ]
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r300, [x]
    ld   LINK_HI, x
    ld   scw_r300 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r300:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r301, [x]
    ld   LINK_HI, x
    ld   scw_r301 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r301:
    ld   [u6], ac
    add  JB_PCT & 0xFF, x
    ld   JB_PCT >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r302, [x]
    ld   LINK_HI, x
    ld   scw_r302 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r302:
    ld   0x25, ac               ; %
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r303, [x]
    ld   LINK_HI, x
    ld   scw_r303 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r303:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; sk_gain - a job done: each skill it used (wk_m) gains 2 (120 - its
; level) of 256 toward the next level (SKILL_MAX at most).  A leaf.
turn_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r304, [x]
    ld   LINK_HI, x
    ld   scw_r304 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r304:
    beq  tq_far
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r305, [x]
    ld   LINK_HI, x
    ld   scw_r305 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r305:
    ld   [c_t], ac
    sub  FACE0 + 3, ac
    bcs  tq_up
    add  FACE0, ac              ; left, down, right: 3 kinds back
    bra  tq_b
tq_up:
    add  FACE0 + 12, ac         ; up: right, 9 kinds on
tq_b:
    ld   ac, [w4]
    ld   [c_b], ac
    beq  tq_p
    ld   [w4], ac
    or   0x80, ac               ; installed: it stays installed
    ld   ac, [w4]
tq_p:
    ld   [w4], ac
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r306, [x]
    ld   LINK_HI, x
    ld   scw_r306 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r306:
    ld   act_done >> 8, y
    jmp  act_done
tq_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r307, [x]
    ld   LINK_HI, x
    ld   scw_r307 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r307:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ty_ant - tug_scan's: a working antenna (any facing): comms.  The rest
; of tug_scan
nav_fetch:
    ld   ac, [R0]
    ld   s_navf >> 8, ac
    ld   ac, [R1]
    ld   swap_fetch >> 8, y
    jmp  swap_fetch


#overlay 0xC600
dc_face:
    ld   [dc_t], ac
    sub  6, ac
    shr  ac
    shr  ac
    add  ART_PG, ac
    ld   ac, [dc_ap]
    ld   [dc_t], ac
    sub  6, ac
    and  3, ac
    shl
    shl
    shl
    shl
    shl
    shl
    or   0x0F, ac
    ld   ac, [dc_ai]
    ld   [dc_t], ac
    sub  FACE0 + 9, ac
    bcs  df_k
    ld   [dc_ai], ac
    xor  0x3F, ac               ; right: 0x30
    ld   ac, [dc_ai]
df_k:
    ld   [dc_ai], ac
    ld   ac, [dc_t]
    ld   [dc_cx], ac
    shl
    shl
    shl
    add  0x61, ac
    ld   ac, [dc_sp]
    ld   [dc_cy], ac
    sub  7, ac
    blt  ca_lo48
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    sub  223, ac
    bra  ca_go48
ca_lo48:
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    add  32, ac
ca_go48:
    ld   ac, [dc_base]
    clr  ac
    ld   ac, [dc_ai]
    ld   4, ac
    ld   ac, [dc_c]
df_col:
    ld   [dc_base], ac
    ld   ac, [dc_so]
    ld   16, ac
    ld   ac, [dc_n]
df_byte:
    ld   [dc_ai], ac
    xor  [dc_t], ac
    ld   ac, x
    ld   [dc_ap], y
    ld   [y,x], ac
    ld   [dc_sp], y
    ld   [dc_so], x
    ld   ac, [y,x]
    ld   [dc_t], ac
    and  1, ac
    bne  df_n
    ld   [y,x], ac              ; mirrored: the two pixels swapped
    shl
    shl
    shl
    shl
    ld   ac, [y,x]
    ld   [dc_ai], ac
    xor  [dc_t], ac
    ld   ac, x
    ld   [dc_ap], y
    ld   [y,x], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   [dc_sp], y
    ld   [dc_so], x
    or   [y,x], ac
    ld   ac, [y,x]
df_n:
    ld   [dc_ai], ac
    inc
    ld   ac, [dc_ai]
    ld   [dc_so], ac
    add  2, ac
    ld   ac, [dc_so]
    ld   [dc_n], ac
    dec
    ld   ac, [dc_n]
    bne  df_byte
    ld   [dc_sp], ac
    add  2, ac
    ld   ac, [dc_sp]
    ld   [dc_c], ac
    dec
    ld   ac, [dc_c]
    bne  df_col
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; repair_action - REPAIR: a damaged part next to the player, REPAIR_FRAMES
; (15) a damage step at full speed (cut_done: repair_done).  The rest of
; do_action
repair_done:
    ld   [cut_m], ac
    xor  4, ac
    bne  rd_go
    ld   place_done >> 8, y
    jmp  place_done
rd_go:
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
    ld   scw_r314, [x]
    ld   LINK_HI, x
    ld   scw_r314 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r314:
    ld   work_end >> 8, y
    jmp  work_end

; dyn_rep - REPAIR for a damaged part, wall, deck or door.  The end of
; dyn_acts

#overlay 0xC800
repair_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r309, [x]
    ld   LINK_HI, x
    ld   scw_r309 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r309:
    beq  rpa_far
    ld   [s_f], ac
    beq  rpa_e
    shl
    shl
    shl
    shl
    sub  [s_f], ac
    ld   LINK_LO, x             ; CALL job_start
    ld   scw_r310, [x]
    ld   LINK_HI, x
    ld   scw_r310 >> 8, [x]
    ld   job_start >> 8, y
    jmp  job_start
scw_r310:
    ld   LINK_LO, x             ; CALL rep_bar
    ld   scw_r311, [x]
    ld   LINK_HI, x
    ld   scw_r311 >> 8, [x]
    ld   rep_bar >> 8, y
    jmp  rep_bar
scw_r311:
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
    ld   scw_r312, [x]
    ld   LINK_HI, x
    ld   scw_r312 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r312:
rpa_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
rpa_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r313, [x]
    ld   LINK_HI, x
    ld   scw_r313 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r313:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; repair_done - the cell cut_done read (map_get) has no damage now; a
; wall or door: the rooms again.  The rest of cut_done
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
    ld   scw_r316, [x]
    ld   LINK_HI, x
    ld   scw_r316 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r316:
    ld   [suit_on], ac
    beq  pa_1
    ld   A_SUITOFF, ac
    bra  pa_a
pa_1:
    ld   LINK_LO, x             ; CALL suit_slot
    ld   scw_r317, [x]
    ld   LINK_HI, x
    ld   scw_r317 >> 8, [x]
    ld   suit_slot >> 8, y
    jmp  suit_slot
scw_r317:
    beq  pa_e
    ld   A_SUITON, ac
pa_a:
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r318, [x]
    ld   LINK_HI, x
    ld   scw_r318 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r318:
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
COS32:
    #d8 127, 125, 117, 106, 90, 71, 49, 25, 0, -25 & 0xFF, -49 & 0xFF, -71 & 0xFF
    #d8 -90 & 0xFF, -106 & 0xFF, -117 & 0xFF, -125 & 0xFF, -127 & 0xFF, -125 & 0xFF
    #d8 -117 & 0xFF, -106 & 0xFF, -90 & 0xFF, -71 & 0xFF, -49 & 0xFF, -25 & 0xFF
    #d8 0, 25, 49, 71, 90, 106, 117, 125

; fl_abs - u1:u0 = |the 2 bytes at FL_PG + AC| (signed).  A leaf.

#overlay 0xCA00
suit_action:
    ld   [w3], ac
    xor  A_SUITOFF, ac
    bne  su_on
    ld   LINK_LO, x             ; CALL free_slot
    ld   scw_r319, [x]
    ld   LINK_HI, x
    ld   scw_r319 >> 8, [x]
    ld   free_slot >> 8, y
    jmp  free_slot
scw_r319:
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
    ld   scw_r320, [x]
    ld   LINK_HI, x
    ld   scw_r320 >> 8, [x]
    ld   suit_slot >> 8, y
    jmp  suit_slot
scw_r320:
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
    ld   scw_r321, [x]
    ld   LINK_HI, x
    ld   scw_r321 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r321:
    ld   [p_x], ac              ; the player drawn again, in or out of it
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r322, [x]
    ld   LINK_HI, x
    ld   scw_r322 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r322:
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
    ld   scw_r323, [x]
    ld   LINK_HI, x
    ld   scw_r323 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r323:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nosuit_tick - second_tick without the suit: the room's air or nothing
; (collapsing, stage_set's ss_4); the suit keeps its O2.  The rest of
; second_tick
dyn_nav:
    ld   [s_t], ac
    xor  T_HELM, ac
    bne  dn_e
    ld   [s_b], ac
    beq  dn_e
    ld   [s_f], ac
    sub  8, ac
    bcc  dn_e
    ld   dyn_nav2 >> 8, y
    jmp  dyn_nav2
dn_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dyn_nav2 - on the tug: NAVIGATE.  The rest of dyn_nav

#overlay 0xCC00
nosuit_tick:
    ld   [p_x], ac
    ld   ac, [g_x]
    ld   [p_y], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r324, [x]
    ld   LINK_HI, x
    ld   scw_r324 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r324:
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
    ld   scw_r325, [x]
    ld   LINK_HI, x
    ld   scw_r325 >> 8, [x]
    ld   draw_cell_at >> 8, y
    jmp  draw_cell_at
scw_r325:
    ld   sc_leave >> 8, y
    jmp  sc_leave
ce_c:
    ld   LINK_LO, x             ; CALL crate_mark
    ld   scw_r326, [x]
    ld   LINK_HI, x
    ld   scw_r326 >> 8, [x]
    ld   crate_mark >> 8, y
    jmp  crate_mark
scw_r326:
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
    blt  ca_lo50
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    sub  223, ac
    bra  ca_go50
ca_lo50:
    ld   [dc_cy], ac
    shl
    shl
    shl
    shl
    shl
    add  32, ac
ca_go50:
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


#overlay 0xCE00
zn_0:
    #d "OPEN SPACE", 0x00
zn_2:
    #d "DECK PLATE", 0x00
zn_3:
    #d "BULKHEAD", 0x00
zn_4:
    #d "DOOR (CLOSED)", 0x00
zn_5:
    #d "DOOR (OPEN)", 0x00
zn_6:
    #d "O2 TANK", 0x00
zn_7:
    #d "REACTOR CORE", 0x00
zn_8:
    #d "BATTERY", 0x00
zn_9:
    #d "CARGO CRATE", 0x00
zn_10:
    #d "BUNK", 0x00
zn_11:
    #d "HELM CONSOLE", 0x00
zn_12:
    #d "LOCKER", 0x00
zn_13:
    #d "SECURITY TURRET", 0x00
zn_14:
    #d "POWER CONDUIT", 0x00
zn_15:
    #d "DECK (NO AIR)", 0x00
zn_16:
    #d "AIRLOCK", 0x00
zn_17:
    #d "WORK SUIT", 0x00
zn_18:
    #d "NITROGEN TANK", 0x00
zn_19:
    #d "AIR SCRUBBER", 0x00
zn_20:
    #d "HULL BREACH", 0x00
zn_21:
    #d "EMPTY O2 TANK", 0x00


#overlay 0xD000
zn_22:
    #d "PLASMA CUTTER", 0x00
zn_23:
    #d "WALL PANEL", 0x00
zn_24:
    #d "PRESSURE DOOR", 0x00
zn_25:
    #d "SPARE PLATE", 0x00
zn_26:
    #d "YOU", 0x00
zn_27:
    #d "CONDUIT SECTION", 0x00
zn_28:
    #d "AIR PUMP", 0x00
zn_29:
    #d "GAS INTAKE", 0x00
zn_30:
    #d "COMMS ANTENNA", 0x00
zn_31:
    #d "RADAR ARRAY", 0x00
zn_32:
    #d "THRUSTER", 0x00
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
za_8:
    #d "PUT DOWN RIGHT", 0x00
za_9:
    #d "PUT DOWN BACK", 0x00
za_10:
    #d "REFILL SUIT", 0x00
za_11:
    #d "HOLD OPEN", 0x00


#overlay 0xD200
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
za_19:
    #d "NAVIGATE", 0x00
za_20:
    #d "TURN", 0x00
zb_0:
    #d "[##########]", 0x00
zb_1:
    #d "[#########-]", 0x00
zb_3:
    #d "[########--]", 0x00
zb_4:
    #d "[#######---]", 0x00
zb_6:
    #d "[######----]", 0x00
zb_8:
    #d "[#####-----]", 0x00
zb_9:
    #d "[####------]", 0x00
zb_11:
    #d "[###-------]", 0x00
zb_12:
    #d "[##--------]", 0x00
zb_14:
    #d "[#---------]", 0x00
zs_0:
    #d "SEALED - NO LEAKS", 0x00


#overlay 0xD400
zs_8:
    #d "LEAKS AIR - NEEDS REPAIR", 0x00
zd_0:
    #d "100%", 0x00
zw_0:
    #d "WORKS AT 100%", 0x00
zd_1:
    #d "94%", 0x00
zw_1:
    #d "WORKS AT 88%", 0x00
zd_2:
    #d "88%", 0x00
zw_2:
    #d "WORKS AT 75%", 0x00
zd_3:
    #d "81%", 0x00
zw_3:
    #d "WORKS AT 63%", 0x00
zd_4:
    #d "75%", 0x00
zw_4:
    #d "WORKS AT 50%", 0x00
zd_5:
    #d "69%", 0x00
zw_5:
    #d "WORKS AT 38%", 0x00
zd_6:
    #d "63%", 0x00
zw_6:
    #d "WORKS AT 25%", 0x00
zd_7:
    #d "56%", 0x00
zw_7:
    #d "WORKS AT 13%", 0x00
zd_8:
    #d "50%", 0x00
zw_8:
    #d "BROKEN - NEEDS REPAIR", 0x00
zd_9:
    #d "44%", 0x00
zd_10:
    #d "38%", 0x00
zd_11:
    #d "31%", 0x00
zd_12:
    #d "25%", 0x00
zd_13:
    #d "19%", 0x00
zd_14:
    #d "13%", 0x00
zd_15:
    #d "6%", 0x00

pt_xy:
    ld   [m_yl], ac
    shr  ac
    ld   ac, [u1]
    ld   [m_yh], ac
    beq  px_1
    ld   [u1], ac
    or   0x80, ac
    ld   ac, [u1]
px_1:
    ld   [m_xl], ac
    shr  ac
    shr  ac
    ld   ac, [u2]
    ld   [m_xh], ac
    shl
    shl
    shl
    shl
    shl
    shl
    or   [u2], ac
    ld   ac, [u2]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; place_click - a left click on the view while placing: the cell under
; the pointer, next to you and of the kind the part goes on, starts the
; job (place_go).  The rest of click_left

#overlay 0xD600
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

deck_ok:
    ld   [c_t], ac
    xor  T_FLOOR, ac
    beq  dk_1
    ld   [c_t], ac
    xor  T_PIPE, ac
    beq  dk_1
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
dk_1:
    ld   [c_f], ac
    sub  8, ac
    bcs  dk_ok
    ld   s_bdeck & 0xFF, ac
    ld   ac, [R0]
    ld   s_bdeck >> 8, ac
    ld   ac, [R1]
    ld   2, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
dk_ok:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; cb_get - g_x, g_y: AC = its conduit bit (0 none; u2 its byte, u4 the
; bit).  cb_set, cb_clr - set it, clear it.  The bits are in the screen
; bytes no line shows: page xA1 + (x & xF8) + 2 (y >> 4), offset
; 2 (y & 15), bit x & 7 (all 768 of them: even offsets 0-30 of the odd
; pages xA1-xFF; screen_init clears them, cb_init sets the start's).
; A leaf: u0, u2, u4, u5

#overlay 0xD800
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
s_instdone:
    #d "INSTALLED.", 0x00

s_bump:
    #d "BUMPED THE KESTREL 9: NO DAMAGE.", 0x00

#overlay 0xDA00
s_inv:
    #d "YOUR GEAR.  I OR TAB: BACK TO THE SHIP", 0x00
s_place:
    #d "CLICK WHERE IT GOES, NEXT TO YOU.  RIGHT CLICK: CANCEL", 0x00
s_wspace:
    #d "IT GOES ON OPEN SPACE.", 0x00
s_wdeck:
    #d "IT GOES ON A DECK OR A CONDUIT.", 0x00
s_wboth:
    #d "IT GOES ON A DECK, A CONDUIT OR OPEN SPACE.", 0x00

PW_ST:
    #d8 0
s_wcond:
    #d "A CONDUIT GOES ON A DECK, IN A WALL OR UNDER A PART.", 0x00

; under_cycle - a click on the cell the panel is locked on: from a part
; (no thruster) to what is under it (s_who 4), and back.  AC 1 if it
; did.  A leaf.

#overlay 0xDC00
s_bdeck:
    #d "THE DECK IS BROKEN - REPAIR IT TO 50% HEALTH FIRST.", 0x00
s_uninst:
    #d "UNINSTALLING...", 0x00
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
s_broken:
    #d "IT IS BROKEN - IT DOES NOT WORK.", 0x00


#overlay 0xDE00
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
s_pl_batt:
    #d "BATT   SMALL CELL        CHARGE ", 0x00
s_pl_hands:
    #d "HANDS  ", 0x00


#overlay 0xE000
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
s_hasc:
    #d "THERE IS A CONDUIT THERE ALREADY.", 0x00
s_jam:
    #d "THE DOOR IS JAMMED - REPAIR IT TO 50% HEALTH FIRST.", 0x00
s_air:
    #d "AIR ", 0x00
s_loose:
    #d "LOOSE", 0x00
s_w1:
    #d "CAUTION: SUIT O2 BELOW HALF.", 0x00
s_w2:
    #d "WARNING: SUIT O2 LOW - GET BACK TO THE TUG OR FIND AN O2 TANK.", 0x00


#overlay 0xE200
s_w3:
    #d "CRITICAL: SUIT O2 ALMOST GONE!", 0x00
s_w4:
    #d "YOU ARE BLACKING OUT - GET AIR NOW!", 0x00
s_w5:
    #d "YOU SUFFOCATED.  PRESS ENTER TO TRY AGAIN.", 0x00

PT_TAB:
    #d8 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x00, 0x00, 0xA0, 0xA0, 0xA0, 0xA0, 0x00, 0x00
    #d8 0xFF, 0xFF, 0xF0, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x0A, 0xAA, 0x00, 0x00, 0x00
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, 0xF0, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    #d8 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    #d8 0xFF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0xF0, 0xFF, 0x00, 0x00, 0x0A, 0xAA, 0xAA, 0x0A, 0x00, 0x00
    #d8 0xFF, 0xFF, 0xFF, 0xF0, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00
PT_SV:
    #d8 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
PT_ON:
    #d8 0
PT_C:
    #d8 0
PT_P:
    #d8 0
PT_B:
    #d8 0


#overlay 0xE400
CRACK:
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x0F
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 0x0F, 0xF0, 0x00, 0x0F, 0x0F, 0xFF, 0x0F, 0xF0, 0xF0, 0xFF, 0xFF
    #d8 0x0F, 0x0F, 0xF0, 0xF0, 0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, 0xF0, 0x0F, 0xFF, 0xFF, 0xFF
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, 0xFF, 0xFF

PL_NOSUIT:
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x37, 0x33, 0x33, 0x3C, 0x3C, 0x77, 0x77, 0x77, 0x77, 0x77
    #d8 0x67, 0x66, 0xC6, 0xCC, 0xCC, 0xC7, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x73, 0x73, 0x76, 0x77
    #d8 0x76, 0x66, 0x6C, 0xCC, 0xCC, 0x7C, 0x33, 0x33, 0x3E, 0x33, 0x33, 0x33, 0x37, 0x37, 0x67, 0x77
    #d8 0x77, 0x77, 0x77, 0x77, 0x77, 0x77, 0x73, 0x33, 0x33, 0xC3, 0xC3, 0x77, 0x77, 0x77, 0x77, 0x77

SK_MSG:
    #d "MECHANICAL 00  ELECTRICAL 00  NUCLEAR 00  COMPUTERS 00  HYDRAULICS 00  SUIT 00", 0x00
SK_POS:
    #d8 (SK_MSG & 0xFF) + 11, (SK_MSG & 0xFF) + 26, (SK_MSG & 0xFF) + 38, (SK_MSG & 0xFF) + 52, (SK_MSG & 0xFF) + 67, (SK_MSG & 0xFF) + 76

; ============================================================
; the inventory screen, and installing from it
; ============================================================
;
; I, Tab or the INVENTORY action on yourself swaps the view for your
; gear: your left hand, right hand and back in their cells (an empty one
; a bare deck plate), and you.  The mouse over one shows it in the panel
; with its menu, as on the ship.  INSTALL there goes back to the ship to
; pick the cell next to you it goes on (place): bits 7:6 of the part's
; TB_SKILL say where (x40 open space, x80 a bare deck: a ship part on a
; deck, a wall panel or a door on a deck or open space, a deck plate or a
; thruster on open space).  The job (cut_m 4) puts it there (place_done).

; inv_toggle - the inventory up (SCRAP.INV read into x4100-x4CFF, the
; work space rooms_build leaves alone between builds), or back to the
; ship (the rooms worked out then if a job changed the ship meanwhile).
; The rest of the routine that GOTOs it (its LEAVE)
fl_scan0:
    clr  ac
    ld   ac, [n_o2]
    ld   ac, [n_scr]
    ld   ac, [n_bat]
    ld   ac, [n_fuel]
    ld   ac, [v4]
    ld   ac, [v5]
    ld   N_ANT >> 8, y
    ld   N_ANT & 0xFF, x
    ld   0, [y,x]
    ld   FL_PG, y
    ld   FL_ML, x
    ld   0x00, [y,x]
    ld   FL_MH, x
    ld   0x00, [y,x]
    ld   FL_NT, x
    ld   0x00, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; shr16 - R1:R0 >>= 1 (no sign).  A leaf.

#overlay 0xE600
inv_toggle:
    ld   [inv], ac
    bne  it_c
    ld   LINK_LO, x             ; CALL inv_fetch
    ld   scw_r327, [x]
    ld   LINK_HI, x
    ld   scw_r327 >> 8, [x]
    ld   inv_fetch >> 8, y
    jmp  inv_fetch
scw_r327:
    beq  it_o
    ld   sc_leave >> 8, y
    jmp  sc_leave
it_o:
    ld   1, ac
    ld   ac, [inv]
    clr  ac                     ; nothing to place
    ld   ac, [place]
    ld   ac, [s_who]
    ld   s_inv & 0xFF, ac
    ld   ac, [R0]
    ld   s_inv >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r328, [x]
    ld   LINK_HI, x
    ld   scw_r328 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r328:
    bra  it_v
it_c:
    clr  ac
    ld   ac, [inv]
    ld   2, ac                  ; back on the ship: the panel on you
    ld   ac, [s_who]
    ld   [rb_go], ac
    beq  it_v
    ld   LINK_LO, x             ; CALL rooms_build
    ld   scw_r329, [x]
    ld   LINK_HI, x
    ld   scw_r329 >> 8, [x]
    ld   rooms_build >> 8, y
    jmp  rooms_build
scw_r329:
    clr  ac
    ld   ac, [rb_go]
it_v:
    ld   0xFF, ac
    ld   ac, [inv_k]
    clr  ac
    ld   ac, [lock]
    ld   ac, [h_on]
    ld   ac, [wk_on]
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r330, [x]
    ld   LINK_HI, x
    ld   scw_r330 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r330:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r331, [x]
    ld   LINK_HI, x
    ld   scw_r331 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r331:
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; inv_fetch - SCRAP.INV into x4100 up (6 sectors at most): AC = 0, or not
; 0 when it is not on the card.  swap_fetch - the file R1:R0 so, into
; page u5 up, u6 sectors at most
inv_fetch:
    ld   s_invf & 0xFF, ac
    ld   ac, [R0]
    ld   s_invf >> 8, ac
    ld   ac, [R1]
    ld   SWAP_LO >> 8, ac
    ld   ac, [u5]
    ld   6, ac
    ld   ac, [u6]
swap_fetch:                     ; (R1:R0 another file: nav_fetch's)
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
    ld   PW_ST >> 8, y          ; (over SCRAP.PWR and the live bits)
    ld   PW_ST & 0xFF, x
    ld   [y,x], ac
    and  1, ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL l_fs_open
    ld   scw_r332, [x]
    ld   LINK_HI, x
    ld   scw_r332 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
scw_r332:
    bne  vf_e
vf_l:
    clr  ac
    ld   ac, [R4]
    ld   [u5], ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_read
    ld   scw_r333, [x]
    ld   LINK_HI, x
    ld   scw_r333 >> 8, [x]
    ld   l_fs_read >> 8, y
    jmp  l_fs_read
scw_r333:
    bne  vf_d
    ld   [u5], ac
    add  2, ac
    ld   ac, [u5]
    ld   [u6], ac
    dec
    ld   ac, [u6]
    bne  vf_l
vf_d:
    clr  ac
vf_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pt_xy - u1, u2 = the art pixel under the mouse (m_y / 2, m_x / 4): the
; inventory's (scrap_inv.masm; resident to keep SCRAP.INV small).  A leaf.
dyn_nav2:
    ld   LINK_LO, x             ; CALL on_tug
    ld   scw_r416, [x]
    ld   LINK_HI, x
    ld   scw_r416 >> 8, [x]
    ld   on_tug >> 8, y
    jmp  on_tug
scw_r416:
    beq  dn2_e
    ld   A_NAV, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r417, [x]
    ld   LINK_HI, x
    ld   scw_r417 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r417:
dn2_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nav_action - NAVIGATE: SCRAP.NAV read into x4100 (rooms_build's space:
; a rebuild waits), its screen until Esc; then the ship again, the rooms
; worked out if the ship changed (C on the map: the docking screen,
; SCRAP.DCK, between).  The rest of do_action (its LEAVE)

#overlay 0xE800
place_click:
    ld   [h_x], ac
    ld   ac, [s_x]
    ld   ac, [g_x]
    ld   [h_y], ac
    ld   ac, [s_y]
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL near
    ld   scw_r334, [x]
    ld   LINK_HI, x
    ld   scw_r334 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r334:
    beq  pc_far
    ld   [s_x], ac
    xor  [p_x], ac
    bne  pc_1
    ld   [s_y], ac
    xor  [p_y], ac
    beq  pc_bad
pc_1:
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r335, [x]
    ld   LINK_HI, x
    ld   scw_r335 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r335:
    ld   [pl_t], ac             ; a conduit section: cond_click
    xor  T_COND, ac
    bne  pc_2
    ld   cond_click >> 8, y
    jmp  cond_click
pc_2:
    ld   LINK_LO, x             ; u5: x80 a deck (or conduit), x40 open space,
    ld   scw_r336, [x]
    ld   LINK_HI, x
    ld   scw_r336 >> 8, [x]
    ld   deck_ok >> 8, y
    jmp  deck_ok
scw_r336:
    ld   ac, [u5]               ; 1 a broken deck, 0 neither
    beq  pc_dk
    xor  2, ac
    bne  pc_sp
    ld   1, ac
    ld   ac, [u5]
    bra  pc_w
pc_dk:
    ld   0x80, ac
    ld   ac, [u5]
    bra  pc_w
pc_sp:
    ld   0x40, ac
    ld   ac, [u5]
    ld   [c_t], ac
    xor  T_SPACE, ac
    beq  pc_w
    ld   [c_t], ac
    xor  T_STAR, ac
    beq  pc_w
    clr  ac
    ld   ac, [u5]
pc_w:
    ld   ACT_PG, y              ; u6: where the part goes
    ld   [pl_t], ac
    add  TB_SKILL, x
    ld   [y,x], ac
    and  0xC0, ac
    ld   ac, [u6]
    and  [u5], ac
    beq  pc_no
    ld   place_go >> 8, y
    jmp  place_go
pc_no:
    ld   place_why >> 8, y
    jmp  place_why
pc_m:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r337, [x]
    ld   LINK_HI, x
    ld   scw_r337 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r337:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pc_far:
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r338, [x]
    ld   LINK_HI, x
    ld   scw_r338 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r338:
    ld   sc_leave >> 8, y
    jmp  sc_leave
pc_bad:
    ld   s_inway & 0xFF, ac
    ld   ac, [R0]
    ld   s_inway >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r339, [x]
    ld   LINK_HI, x
    ld   scw_r339 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r339:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; place_why - why the part does not go there (u5, u6: place_click).  The
; rest of place_click
SLOT_TAB:
    #d8 s_sl0 & 0xFF, s_sl1 & 0xFF, s_sl2 & 0xFF
s_sl0:
    #d "IN YOUR LEFT HAND", 0x00
s_sl1:
    #d "IN YOUR RIGHT HAND", 0x00
s_sl2:
    #d "ON YOUR BACK", 0x00

; ============================================================
; the flight (scrap_fl.masm): resident, in the even pages from xC000
; ============================================================
; the flight's calls into the library: under map 07 (RAM to x5FFF only), so
; not in the pages from xC000 (the test checks): first in x5C00
; l_mul8, l_div16, l_rand8 - the library's, under its map

#overlay 0xEA00
place_why:
    ld   [u5], ac               ; a broken deck, and the part goes on a deck
    xor  1, ac
    bne  py_n
    ld   [u6], ac
    and  0x80, ac
    beq  py_n
    ld   s_bdeck & 0xFF, ac
    ld   ac, [R0]
    ld   s_bdeck >> 8, ac
    ld   ac, [R1]
    bra  py_mm
py_n:
    ld   [u6], ac
    xor  0x40, ac
    bne  py_2
    ld   s_wspace & 0xFF, ac
    ld   ac, [R0]
    ld   s_wspace >> 8, ac
    bra  py_m
py_2:
    ld   [u6], ac
    xor  0x80, ac
    bne  py_3
    ld   s_wdeck & 0xFF, ac
    ld   ac, [R0]
    ld   s_wdeck >> 8, ac
    bra  py_m
py_3:
    ld   s_wboth & 0xFF, ac
    ld   ac, [R0]
    ld   s_wboth >> 8, ac
py_m:
    ld   ac, [R1]
py_mm:
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r340, [x]
    ld   LINK_HI, x
    ld   scw_r340 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r340:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; place_go - the job: installing part pl_t from its slot on cell s_x,
; s_y, at the part's skills; the panel locked on the cell.  The rest of
; place_click
place_go:
    ld   [pl_t], ac
    ld   ac, [s_t]
    ld   PL_S >> 8, y
    ld   PL_S & 0xFF, x
    ld   [place], ac
    ld   ac, [y,x]
    clr  ac
    ld   ac, [place]
    ld   INST_FRAMES, ac
    ld   LINK_LO, x             ; CALL job_start
    ld   scw_r341, [x]
    ld   LINK_HI, x
    ld   scw_r341 >> 8, [x]
    ld   job_start >> 8, y
    jmp  job_start
scw_r341:
    ld   4, ac
    ld   ac, [cut_m]
    ld   [s_x], ac
    ld   ac, [cut_x]
    ld   [s_y], ac
    ld   ac, [cut_y]
    ld   1, ac
    ld   ac, [lock]
    ld   ac, [s_who]
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   s_inst & 0xFF, ac
    ld   ac, [R0]
    ld   s_inst >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r342, [x]
    ld   LINK_HI, x
    ld   scw_r342 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r342:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; place_done - the part from slot PL_S (still pl_t) on the cell cut_done
; read: a deck plate a deck, a wall panel a wall, a door kit a closed door,
; any other part installed (bolted); the slot empty, the rooms again.  The
; rest of cut_done
cb_clr:
    ld   2, ac
    bra  cg_go
cb_set:
    ld   1, ac
    bra  cg_go
cb_get:
    clr  ac
cg_go:
    ld   ac, [u5]
    ld   [g_y], ac
    shr  ac
    shr  ac
    shr  ac
    and  0xFE, ac
    ld   ac, [u0]
    ld   [g_x], ac
    and  0xF8, ac
    add  [u0], ac
    add  CB_PG, ac
    ld   ac, [u0]
    ld   [g_x], ac
    and  7, ac
    add  BIT_TAB & 0xFF, x
    ld   BIT_TAB >> 8, y
    ld   [y,x], ac
    ld   ac, [u4]
    ld   [g_y], ac
    and  15, ac
    shl
    ld   ac, x
    ld   [u0], y
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u5], ac
    beq  cg_r
    xor  1, ac
    beq  cg_s
    ld   [u4], ac
    xor  0xFF, ac
    and  [u2], ac
    bra  cg_w
cg_s:
    ld   [u4], ac
    or   [u2], ac
cg_w:
    ld   ac, [y,x]
    ld   ac, [u2]
cg_r:
    ld   [u2], ac
    and  [u4], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; cond_click - placing a conduit section: on a whole deck, in a wall or
; under a part on a deck, where there is no conduit yet (place_go); else
; why not.  The rest of place_click

#overlay 0xEC00
place_put:
    ld   [v1], ac
    xor  T_PLATE, ac
    bne  pq_1
    ld   T_FLOOR, ac
    bra  pq_s
pq_1:
    ld   [v1], ac
    xor  T_PANEL, ac
    bne  pq_2
    ld   T_WALL, ac
    bra  pq_s
pq_2:
    ld   [v1], ac
    xor  T_DOORK, ac
    bne  pq_2c
    ld   T_DOOR, ac
    bra  pq_s
pq_2c:
    ld   [v1], ac
    xor  T_COND, ac
    bne  pq_3
    ld   LINK_LO, x             ; a conduit: its bit; a deck shows it (in a
    ld   scw_r343, [x]
    ld   LINK_HI, x
    ld   scw_r343 >> 8, [x]
    ld   cb_set >> 8, y
    jmp  cb_set
scw_r343:
    ld   [c_t], ac              ;   wall or under a part: the power view)
    xor  T_FLOOR, ac
    bne  pq_k
    ld   T_PIPE, ac
    bra  pq_s
pq_3:
    ld   [v1], ac
    or   0x80, ac
pq_s:
    ld   LINK_LO, x             ; CALL map_put
    ld   scw_r344, [x]
    ld   LINK_HI, x
    ld   scw_r344 >> 8, [x]
    ld   map_put >> 8, y
    jmp  map_put
scw_r344:
    ld   [v0], ac
    add  3, x
    ld   [x], ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r345, [x]
    ld   LINK_HI, x
    ld   scw_r345 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r345:
pq_k:
    ld   [v0], x
    clr  ac
    ld   ac, [x]
    ld   1, ac
    ld   ac, [rb_go]
    ld   s_instdone & 0xFF, ac
    ld   ac, [R0]
    ld   s_instdone >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r346, [x]
    ld   LINK_HI, x
    ld   scw_r346 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r346:
    ld   work_end >> 8, y
    jmp  work_end

; ------------------------------------------------------------
; what is under a part: a part stands on a deck (no thruster: open
; space; no turret: a wall), and that deck is never broken (deck_ok).
; The map keeps one type a cell, so a conduit is a bit a cell of its own
; (cb_get): a part's pick-up lays the conduit (PIPE) again where the bit
; is set, else a whole bare deck.  The bit stays under a wall, a door and
; any part (scrap_pwr.masm: the power view shows them).
; ------------------------------------------------------------

; deck_ok - after map_get: AC 0 a deck or a conduit at 50 % health or
; more, 1 neither, 2 a broken one (R0, R1 its message).  A leaf.
cond_click:
    ld   LINK_LO, x             ; CALL cb_get
    ld   scw_r347, [x]
    ld   LINK_HI, x
    ld   scw_r347 >> 8, [x]
    ld   cb_get >> 8, y
    jmp  cb_get
scw_r347:
    beq  cc_0
    ld   s_hasc & 0xFF, ac
    ld   ac, [R0]
    ld   s_hasc >> 8, ac
    bra  cc_m
cc_0:
    ld   [c_t], ac
    xor  T_WALL, ac
    beq  cc_go
    ld   LINK_LO, x             ; CALL deck_ok
    ld   scw_r348, [x]
    ld   LINK_HI, x
    ld   scw_r348 >> 8, [x]
    ld   deck_ok >> 8, y
    jmp  deck_ok
scw_r348:
    beq  cc_go
    xor  2, ac                  ; a broken deck (its message)
    beq  cc_mm
    ld   [c_t], ac
    ld   LINK_LO, x             ; CALL on_space
    ld   scw_r349, [x]
    ld   LINK_HI, x
    ld   scw_r349 >> 8, [x]
    ld   on_space >> 8, y
    jmp  on_space
scw_r349:
    bne  cc_no
    ld   [c_t], ac              ; a part (on a deck)
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    bne  cc_go
cc_no:
    ld   s_wcond & 0xFF, ac
    ld   ac, [R0]
    ld   s_wcond >> 8, ac
cc_m:
    ld   ac, [R1]
cc_mm:
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r350, [x]
    ld   LINK_HI, x
    ld   scw_r350 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r350:
    ld   sc_leave >> 8, y
    jmp  sc_leave
cc_go:
    ld   place_go >> 8, y
    jmp  place_go


; pw_toggle - V: the power view on or off (PW_ST bit 0; the live
; conduits worked out again), the view drawn again.  The rest of input_keys

#overlay 0xEE00
pw_over:
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
    ld   PW_ST >> 8, y
    ld   PW_ST & 0xFF, x
    ld   [y,x], ac
    and  2, ac
    bne  pwv_d
    ld   LINK_LO, x             ; CALL pwr_fetch
    ld   scw_r352, [x]
    ld   LINK_HI, x
    ld   scw_r352 >> 8, [x]
    ld   pwr_fetch >> 8, y
    jmp  pwr_fetch
scw_r352:
    bne  pwv_e
    ld   LINK_LO, x             ; CALL power_build
    ld   scw_r353, [x]
    ld   LINK_HI, x
    ld   scw_r353 >> 8, [x]
    ld   power_build >> 8, y
    jmp  power_build
scw_r353:
pwv_d:
    ld   LINK_LO, x             ; CALL ov_cell
    ld   scw_r354, [x]
    ld   LINK_HI, x
    ld   scw_r354 >> 8, [x]
    ld   ov_cell >> 8, y
    jmp  ov_cell
scw_r354:
pwv_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pwr_fetch - SCRAP.PWR into x4700-x4CFF (3 sectors): AC 0, or not 0 when
; it is not on the card
under_cycle:
    ld   [h_x], ac
    xor  [s_x], ac
    bne  uc_no
    ld   [h_y], ac
    xor  [s_y], ac
    bne  uc_no
    ld   [s_who], ac
    xor  4, ac
    bne  uc_1
    ld   1, ac
    bra  uc_s
uc_1:
    ld   [s_who], ac
    xor  1, ac
    bne  uc_no
    ld   [s_b], ac              ; installed on open space (a thruster): none
    beq  uc_2
    ld   ACT_PG, y
    ld   [s_t], ac
    add  TB_SKILL, x
    ld   [y,x], ac
    and  0xC0, ac
    xor  0x40, ac
    beq  uc_no
uc_2:
    ld   [s_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    beq  uc_no
    ld   4, ac
uc_s:
    ld   ac, [s_who]
    ld   [dirty], ac
    or   1, ac
    ld   ac, [dirty]
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
uc_no:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; under_load - the panel on the deck or conduit under the part on s_x,
; s_y: INSPECT only, whole (deck_ok); no part there now, the cell
; itself (s_who 1).  The rest of subj_load
adj_kind:
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
    ld   ac, [T6]
    clr  ac
    ld   ac, [T7]
aj_l:
    ld   ADJ >> 8, y
    ld   [T7], ac
    add  ADJ & 0xFF, x
    ld   [y,x], ac
    add  [v0], ac
    ld   ac, [g_x]
    ld   [T7], ac
    add  (ADJ & 0xFF) + 4, x
    ld   [y,x], ac
    add  [v1], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r358, [x]
    ld   LINK_HI, x
    ld   scw_r358 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r358:
    xor  [T6], ac
    bne  aj_n
    ld   [c_b], ac
    beq  aj_n
    ld   [c_f], ac
    sub  8, ac
    bcc  aj_n
    ld   1, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
aj_n:
    ld   [T7], ac
    inc
    ld   ac, [T7]
    xor  4, ac
    bne  aj_l
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; inspect_action - INSPECT: the kind's line (prt_load) copied to INSP_BUF
; for the message row.  The rest of do_action

#overlay 0xF000
under_load:
    ld   [s_x], ac
    ld   ac, [g_x]
    ld   ac, [T1]
    ld   ac, [T3]
    ld   [s_y], ac
    ld   ac, [g_y]
    ld   ac, [T2]
    ld   ac, [T4]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r355, [x]
    ld   LINK_HI, x
    ld   scw_r355 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r355:
    ld   [c_b], ac
    beq  ul_2
    ld   ACT_PG, y
    ld   [c_t], ac
    add  TB_SKILL, x
    ld   [y,x], ac
    and  0xC0, ac
    xor  0x40, ac
    beq  ul_m
ul_2:
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_ITEM, ac
    bne  ul_u
ul_m:
    ld   1, ac
    ld   ac, [s_who]
    ld   sl_m >> 8, y
    jmp  sl_m
ul_u:
    ld   [c_r], ac
    ld   ac, [s_r]
    clr  ac
    ld   ac, [s_f]
    ld   ac, [s_b]
    ld   ac, [n_act]
    ld   LINK_LO, x             ; CALL cb_get
    ld   scw_r356, [x]
    ld   LINK_HI, x
    ld   scw_r356 >> 8, [x]
    ld   cb_get >> 8, y
    jmp  cb_get
scw_r356:
    beq  ul_f
    ld   T_PIPE, ac
    bra  ul_t
ul_f:
    ld   T_FLOOR, ac
ul_t:
    ld   ac, [s_t]
    ld   A_INSPECT, ac
    ld   LINK_LO, x             ; CALL add_act
    ld   scw_r357, [x]
    ld   LINK_HI, x
    ld   scw_r357 >> 8, [x]
    ld   add_act >> 8, y
    jmp  add_act
scw_r357:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; on_space - AC = a kind: AC 1 when it goes on open space (TB_SKILL where
; bits x40: a thruster, an antenna, the radar, a deck plate), else 0.  A
; leaf.
inspect_action:
    ld   [s_t], ac
    ld   LINK_LO, x             ; CALL prt_load
    ld   scw_r359, [x]
    ld   LINK_HI, x
    ld   scw_r359 >> 8, [x]
    ld   prt_load >> 8, y
    jmp  prt_load
scw_r359:
    ld   [s_t], ac
    and  1, ac
    add  PRT_BUF >> 8, ac
    ld   ac, [u5]
    clr  ac
    ld   ac, [u0]
ia_l:
    ld   [u5], y
    ld   [u0], ac
    add  PRT_INSP, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   INSP_BUF >> 8, y
    ld   [u0], ac
    add  INSP_BUF & 0xFF, x
    ld   [u1], ac
    ld   ac, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  64, ac
    bne  ia_l
    ld   INSP_BUF & 0xFF, ac
    ld   ac, [R0]
    ld   INSP_BUF >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r360, [x]
    ld   LINK_HI, x
    ld   scw_r360 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r360:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; prt_load - AC = a kind: PRT_BUF holds the text of kinds 2k and 2k + 1
; (k = AC / 2: info line i at 256 (kind & 1) + 48 i, the INSPECT line at
; + 192), read from the card (SCRAP/Kxy, x = '0' + k / 16, y = 'A' + k % 16)
; unless it is there already (PRT_K).  Back in the program's folder after
fl_abs:
    ld   ac, [u2]
    ld   FL_PG, y
    ld   [u2], x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   [u2], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [u1]
    blt  fb_ng
    ld   [LINK_HI], y
    jmp  [LINK_LO]
fb_ng:
    ld   [u0], ac
    xor  0xFF, ac
    add  1, ac
    ld   ac, [u0]
    ld   [u1], ac
    xor  0xFF, ac
    bcc  fb_n1
    inc
fb_n1:
    ld   ac, [u1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_max - w1:w0 = the larger of w1:w0 and u1:u0 (both 0-32767).  A leaf.

#overlay 0xF200
prt_load:
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
    shr  ac
    ld   ac, [u0]
    ld   PRT_K >> 8, y
    ld   PRT_K & 0xFF, x
    ld   [y,x], ac
    xor  [u0], ac
    beq  pr_e
    ld   0xFF, [y,x]
    ld   PRT_NM >> 8, y
    ld   [u0], ac
    and  15, ac
    add  0x41, ac
    ld   (PRT_NM + 2) & 0xFF, x
    ld   ac, [y,x]
    ld   [u0], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  0x30, ac
    ld   (PRT_NM + 1) & 0xFF, x
    ld   ac, [y,x]
    ld   s_prtd & 0xFF, ac
    ld   ac, [R0]
    ld   s_prtd >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_fs_open
    ld   scw_r361, [x]
    ld   LINK_HI, x
    ld   scw_r361 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
scw_r361:
    bne  pr_e
    ld   prt_file >> 8, y
    jmp  prt_file
pr_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; prt_file - the file PRT_NM in the folder SCRAP, then back up.  The rest
; of prt_load
prt_file:
    ld   PRT_NM & 0xFF, ac
    ld   ac, [R0]
    ld   PRT_NM >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_fs_open
    ld   scw_r362, [x]
    ld   LINK_HI, x
    ld   scw_r362 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
scw_r362:
    bne  pf_u
    ld   PRT_BUF & 0xFF, ac
    ld   ac, [R4]
    ld   PRT_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL l_fs_read
    ld   scw_r363, [x]
    ld   LINK_HI, x
    ld   scw_r363 >> 8, [x]
    ld   l_fs_read >> 8, y
    jmp  l_fs_read
scw_r363:
    bne  pf_u
    ld   PRT_K >> 8, y
    ld   PRT_K & 0xFF, x
    ld   [u0], ac
    ld   ac, [y,x]
pf_u:
    ld   s_up & 0xFF, ac
    ld   ac, [R0]
    ld   s_up >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_fs_open
    ld   scw_r364, [x]
    ld   LINK_HI, x
    ld   scw_r364 >> 8, [x]
    ld   l_fs_open >> 8, y
    jmp  l_fs_open
scw_r364:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; INSPECT's line, adj_kind's sides
ADJ:
    #d8 1, 0xFF, 0, 0, 0, 0, 1, 0xFF
INSP_BUF:
    #d8 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; the panel's row 24 for a carried part (draw_tags)

#overlay 0xF400
fl_dv:
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
    ld   ac, [w3]
    ld   FL_DVX, ac
    ld   ac, [w2]
    clr  ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r380, [x]
    ld   LINK_HI, x
    ld   scw_r380 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r380:
    ld   FL_DVY, ac
    ld   ac, [w2]
    ld   24, ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r381, [x]
    ld   LINK_HI, x
    ld   scw_r381 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r381:
    ld   1, ac
    ld   ac, [w3]
    ld   FL_RVX, ac
    ld   ac, [w2]
    ld   16, ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r382, [x]
    ld   LINK_HI, x
    ld   scw_r382 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r382:
    ld   FL_RVY, ac
    ld   ac, [w2]
    ld   8, ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r383, [x]
    ld   LINK_HI, x
    ld   scw_r383 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r383:
    ld   FL_LVX, ac             ; sideways (half): left h - 8, right h + 8
    ld   ac, [w2]
    ld   24, ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r384, [x]
    ld   LINK_HI, x
    ld   scw_r384 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r384:
    ld   FL_LVY, ac
    ld   ac, [w2]
    ld   16, ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r385, [x]
    ld   LINK_HI, x
    ld   scw_r385 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r385:
    ld   FL_SVX, ac
    ld   ac, [w2]
    ld   8, ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r386, [x]
    ld   LINK_HI, x
    ld   scw_r386 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r386:
    ld   FL_SVY, ac
    ld   ac, [w2]
    clr  ac
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r387, [x]
    ld   LINK_HI, x
    ld   scw_r387 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r387:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fl_dv1 - FL_PG + w2 (2 bytes) = A8 (halved when w3) x cos (h + AC) / 8,
; << FL_AE
s_hit:
    #d "IMPACT!  HIT THE KESTREL 9: CHECK THE HULL.", 0x00

; ============================================================
; SCRAP.INV: the inventory screen (scrap_inv.masm), read in when it opens
; ============================================================
; ============================================================
; scrap_inv.masm - SCRAPWRIGHT's inventory screen: SCRAP.INV
; ============================================================
;
; Included at the end of scrap.masm, in the region SWAP_LO-x4CFF (x4100):
; gen_plc.py --swap writes these bytes to SCRAP.INV, and inv_fetch reads
; them in each time the inventory opens (rooms_build's work space, which
; the inventory does not need: a rebuild waits until it closes).
;
; The screen (gen_scrap.py inventory_screen draws the same for the test):
; the 4 bpp view area is 160 x 192 art pixels (a byte is two, the left one
; in the low nibble; line pair p of byte column b is page x61 + 2b,
; offset 2p + 32, or 2p - 223 from p 112).  A title bar, GEAR on the
; left (suit, battery, O2, utility) and CARRYING on the right (left hand,
; right hand, back): each slot the part's cell art in a one-pixel frame
; (yellow under the mouse), its label and what is in it in a 3 x 5 font.
; The mouse over a slot: the panel shows it, with its menu (a carried
; part: s_who 3, inv_k 0-2; the gear: you, s_who 2).
;
; The mouse pointer is scrap.masm's (pt_show, pt_hide): inv_draw and
; inv_slots take it off while they draw, the frame loop draws it again.
; A broken carried part (damage from 50 %) is drawn cracked.
;
; Date: 11/05/2026
; ============================================================

ip_k    = dc_n                  ; ip_art: 1 draws the art cracked (dc_* are
                                ;   free while the inventory is up)

; inv_draw - the inventory screen.  The rest of draw_view
fl_burn:
    ld   FL_PG, y
    ld   FL_NT, x
    ld   [y,x], ac
    ld   FL_FT, x
    add  [y,x], ac
    ld   ac, [y,x]
    sub  60, ac
    bcs  fb_r
    ld   ac, [y,x]
    ld   FL_FUL, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bne  fb_1
    ld   FL_FUH, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
fb_1:
    ld   fl_burn2 >> 8, y
    jmp  fl_burn2
fb_r:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_burn2 - a kg less left.  The rest of fl_burn (a leaf)

#overlay 0xF600
fl_dv1:
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
    ld   FL_PG, y
    ld   FL_HD, x
    ld   [y,x], ac
    add  [w1], ac
    and  31, ac
    add  COS32 & 0xFF, x
    ld   COS32 >> 8, y
    ld   [y,x], ac
    ld   ac, [w1]               ; cos (signed)
    blt  dv_ng
    bra  dv_ps
dv_ng:
    xor  0xFF, ac
    inc
dv_ps:
    ld   ac, [R1]
    ld   FL_PG, y
    ld   FL_A8, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [w3], ac
    beq  dv_f
    ld   [R0], ac
    shr  ac
    ld   ac, [R0]
dv_f:
    ld   LINK_LO, x             ; R3:R2
    ld   scw_r388, [x]
    ld   LINK_HI, x
    ld   scw_r388 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r388:
    ld   [R2], ac
    ld   ac, [R0]
    ld   [R3], ac
    ld   ac, [R1]
    ld   FL_PG, y
    ld   FL_AE, x
    ld   3, ac
    sub  [y,x], ac
    ld   ac, [w4]
dv_sh:
    ld   [w4], ac
    beq  dv_s
    dec
    ld   ac, [w4]
    ld   LINK_LO, x             ; CALL shr16
    ld   scw_r389, [x]
    ld   LINK_HI, x
    ld   scw_r389 >> 8, [x]
    ld   shr16 >> 8, y
    jmp  shr16
scw_r389:
    bra  dv_sh
dv_s:
    ld   [w1], ac
    blt  dv_m
    bra  dv_st
dv_m:
    ld   [R0], ac               ; negative: two's complement
    xor  0xFF, ac
    add  1, ac
    ld   ac, [R0]
    ld   [R1], ac
    xor  0xFF, ac
    bcc  dv_m1
    inc
dv_m1:
    ld   ac, [R1]
dv_st:
    ld   FL_PG, y
    ld   [w2], x
    ld   [R0], ac
    ld   ac, [y,x]
    ld   [w2], ac
    inc
    ld   ac, x
    ld   [R1], ac
    ld   ac, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

fl_add:
    ld   FL_PG, y
    clr  ac
    ld   ac, [T4]               ; the carry
    ld   ac, [T5]               ; the sign bytes past the source
    ld   [T1], ac
    add  [T2], ac
    dec
    ld   ac, x
    ld   [y,x], ac
    blt  fa_ng
    bra  fa_l
fa_ng:
    ld   0xFF, ac
    ld   ac, [T5]
fa_l:
    ld   [T5], ac
    ld   ac, [T6]
    ld   [T2], ac
    beq  fa_s
    dec
    ld   ac, [T2]
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [T6]
    ld   [T1], ac
    inc
    ld   ac, [T1]
fa_s:
    clr  ac
    ld   ac, [T7]
    ld   [T0], x
    ld   [y,x], ac
    add  [T6], ac
    ld   ac, [y,x]
    bcc  fa_c
    ld   1, ac
    ld   ac, [T7]
fa_c:
    ld   [T4], ac
    beq  fa_d
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bne  fa_d
    ld   1, ac
    ld   ac, [T7]
fa_d:
    ld   [T7], ac
    ld   ac, [T4]
    ld   [T0], ac
    inc
    ld   ac, [T0]
    ld   [T3], ac
    dec
    ld   ac, [T3]
    bne  fa_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fl_burn - a frame of thrust: FL_NT thruster frames, a kg burnt (and
; one less left) each 60.  A leaf.

#overlay 0xF800
fl_dmg:
    ld   [w4], ac
    beq  fm_e
    ld   LINK_LO, x             ; CALL l_rand8
    ld   scw_r400, [x]
    ld   LINK_HI, x
    ld   scw_r400 >> 8, [x]
    ld   l_rand8 >> 8, y
    jmp  l_rand8
scw_r400:
    and  31, ac
    sub  TUG_X1 - TUG_X0 + 1, ac
    blt  fm_x
    sub  16, ac
fm_x:
    add  TUG_X1 + 1, ac
    ld   ac, [g_x]
    ld   LINK_LO, x             ; CALL l_rand8
    ld   scw_r401, [x]
    ld   LINK_HI, x
    ld   scw_r401 >> 8, [x]
    ld   l_rand8 >> 8, y
    jmp  l_rand8
scw_r401:
    and  31, ac
    sub  TUG_Y1 - TUG_Y0 + 1, ac
    blt  fm_y
    sub  16, ac
fm_y:
    add  TUG_Y1 + 1, ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r402, [x]
    ld   LINK_HI, x
    ld   scw_r402 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r402:
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_DMG | F_STRUCT, ac
    beq  fm_n
    ld   LINK_LO, x             ; CALL l_rand8
    ld   scw_r403, [x]
    ld   LINK_HI, x
    ld   scw_r403 >> 8, [x]
    ld   l_rand8 >> 8, y
    jmp  l_rand8
scw_r403:
    and  [w6], ac
    add  [w5], ac
    add  [c_f], ac
    ld   ac, [w3]
    sub  16, ac
    bcs  fm_s
    ld   15, ac
    ld   ac, [w3]
fm_s:
    ld   [w3], ac
    ld   LINK_LO, x             ; CALL map_setd
    ld   scw_r404, [x]
    ld   LINK_HI, x
    ld   scw_r404 >> 8, [x]
    ld   map_setd >> 8, y
    jmp  map_setd
scw_r404:
    ld   LINK_LO, x             ; CALL refresh_cell
    ld   scw_r405, [x]
    ld   LINK_HI, x
    ld   scw_r405 >> 8, [x]
    ld   refresh_cell >> 8, y
    jmp  refresh_cell
scw_r405:
    ld   1, ac
    ld   ac, [rb_go]
fm_n:
    ld   [w4], ac
    dec
    ld   ac, [w4]
    bra  fl_dmg
fm_e:
    ld   fl_stop >> 8, y
    jmp  fl_stop

; fl_stop - stopped where it was last clear, the message, the rooms
; worked out again (later when a screen holds their space).  The end of
; fl_hit
fl_check:
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
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   [y,x], ac
    beq  fc_go
    ld   sc_leave >> 8, y
    jmp  sc_leave
fc_go:
    ld   LINK_LO, x             ; CALL fl_rel
    ld   scw_r396, [x]
    ld   LINK_HI, x
    ld   scw_r396 >> 8, [x]
    ld   fl_rel >> 8, y
    jmp  fl_rel
scw_r396:
    ld   [w1], ac
    blt  fc_hit
    ld   LINK_LO, x             ; CALL fl_save
    ld   scw_r397, [x]
    ld   LINK_HI, x
    ld   scw_r397 >> 8, [x]
    ld   fl_save >> 8, y
    jmp  fl_save
scw_r397:
    ld   FL_PG, y               ; closing = the last gap - this one
    ld   FL_GPL, x
    ld   [y,x], ac
    sub  [w0], ac
    ld   ac, [w2]
    ld   FL_GPH, x
    ld   [y,x], ac
    bcc  fc_1
    dec
fc_1:
    sub  [w1], ac
    blt  fc_0                   ; moving away
    beq  fc_2
    ld   255, ac
    ld   ac, [w2]
    bra  fc_2
fc_0:
    clr  ac
    ld   ac, [w2]
fc_2:
    ld   FL_CL, x
    ld   [w2], ac
    ld   ac, [y,x]
    ld   FL_GPL, x
    ld   [w0], ac
    ld   ac, [y,x]
    ld   FL_GPH, x
    ld   [w1], ac
    ld   ac, [y,x]
    ld   fl_alarm >> 8, y
    jmp  fl_alarm
fc_hit:
    ld   fl_hit >> 8, y
    jmp  fl_hit

; fl_alarm - closing (w2 metres in 8 frames) within 300 m (w1:w0 the gap):
; PROXIMITY (1); within 10 seconds (75 checks): IMPACT IN 10 S (2).  The
; message row drawn again when it changes.  The rest of fl_check

#overlay 0xFA00
fl_tick:
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
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   [y,x], ac
    bne  ft_e
    ld   FL_TH, x
    ld   [y,x], ac
    beq  ft_m
    ld   ac, [w0]
    ld   0x00, [y,x]            ; held: the keys set it again next frame
    ld   FL_FLL, x
    ld   [y,x], ac
    ld   FL_FLH, x
    or   [y,x], ac
    beq  ft_m
    ld   FL_A8, x
    ld   [y,x], ac
    beq  ft_m
    ld   [w0], ac               ; the thrust's vector (FL_DVX, FL_RVX or the
    ld   ac, [w1]               ; nav screen's sideways one)
    ld   FL_VX, ac
    ld   LINK_LO, x             ; CALL fl_add24
    ld   scw_r368, [x]
    ld   LINK_HI, x
    ld   scw_r368 >> 8, [x]
    ld   fl_add24 >> 8, y
    jmp  fl_add24
scw_r368:
    ld   [w1], ac
    add  2, ac
    ld   ac, [w1]
    ld   FL_VY, ac
    ld   LINK_LO, x             ; CALL fl_add24
    ld   scw_r369, [x]
    ld   LINK_HI, x
    ld   scw_r369 >> 8, [x]
    ld   fl_add24 >> 8, y
    jmp  fl_add24
scw_r369:
    ld   LINK_LO, x             ; CALL fl_burn
    ld   scw_r370, [x]
    ld   LINK_HI, x
    ld   scw_r370 >> 8, [x]
    ld   fl_burn >> 8, y
    jmp  fl_burn
scw_r370:
ft_m:
    ld   FL_VX + 1, ac
    ld   ac, [w1]
    ld   FL_PX, ac
    ld   LINK_LO, x             ; CALL fl_addp
    ld   scw_r371, [x]
    ld   LINK_HI, x
    ld   scw_r371 >> 8, [x]
    ld   fl_addp >> 8, y
    jmp  fl_addp
scw_r371:
    ld   FL_VY + 1, ac
    ld   ac, [w1]
    ld   FL_PY, ac
    ld   LINK_LO, x             ; CALL fl_addp
    ld   scw_r372, [x]
    ld   LINK_HI, x
    ld   scw_r372 >> 8, [x]
    ld   fl_addp >> 8, y
    jmp  fl_addp
scw_r372:
ft_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fl_add24 - the 2 bytes at FL_PG + w1 (signed) into the 4 at FL_PG + AC.
; fl_addp - the 3 at w1 (signed) into the 4 at AC.  Leaves (fl_add's).
fl_accel:
    ld   FL_PG, y               ; the mass in w1:w0, THRUST_Q in R1:R0:
    ld   FL_ML, x               ;   both halved until the mass fits a byte
    ld   [y,x], ac
    ld   ac, [w0]
    ld   FL_MH, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   THRUST_Q & 0xFF, ac
    ld   ac, [R0]
    ld   THRUST_Q >> 8, ac
    ld   ac, [R1]
fc_s:
    ld   [w1], ac
    beq  fc_d
    ld   LINK_LO, x             ; CALL shr16
    ld   scw_r373, [x]
    ld   LINK_HI, x
    ld   scw_r373 >> 8, [x]
    ld   shr16 >> 8, y
    jmp  shr16
scw_r373:
    ld   [R0], ac
    ld   ac, [w2]
    ld   [R1], ac
    ld   ac, [w3]
    ld   [w0], ac
    ld   ac, [R0]
    ld   [w1], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL shr16
    ld   scw_r374, [x]
    ld   LINK_HI, x
    ld   scw_r374 >> 8, [x]
    ld   shr16 >> 8, y
    jmp  shr16
scw_r374:
    ld   [R0], ac
    ld   ac, [w0]
    ld   [R1], ac
    ld   ac, [w1]
    ld   [w2], ac
    ld   ac, [R0]
    ld   [w3], ac
    ld   ac, [R1]
    bra  fc_s
fc_d:
    ld   255, ac                ; q = THRUST_Q / mass, 255 at most
    ld   ac, [w2]
    ld   [w0], ac
    beq  fc_q
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r375, [x]
    ld   LINK_HI, x
    ld   scw_r375 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r375:
    ld   [R1], ac
    bne  fc_q
    ld   [R0], ac
    ld   ac, [w2]
fc_q:
    ld   fl_a16 >> 8, y
    jmp  fl_a16

; fl_a16 - A16 = q (w2) x the thrusters, kept as FL_A8 << FL_AE (FL_AE 3
; at most), then fl_fuel.  The rest of fl_accel

#overlay 0xFC00
fl_rel:
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
    ld   FL_PG, y
    ld   FL_PX + 2, x
    ld   WRECK_X & 0xFF, ac
    sub  [y,x], ac
    ld   FL_DX, x
    ld   ac, [y,x]
    ld   FL_PX + 3, x
    ld   WRECK_X >> 8, ac
    bcc  fr_1
    dec
fr_1:
    sub  [y,x], ac
    ld   FL_DX + 1, x
    ld   ac, [y,x]
    ld   FL_PY + 2, x
    ld   WRECK_Y & 0xFF, ac
    sub  [y,x], ac
    ld   FL_DY, x
    ld   ac, [y,x]
    ld   FL_PY + 3, x
    ld   WRECK_Y >> 8, ac
    bcc  fr_2
    dec
fr_2:
    sub  [y,x], ac
    ld   FL_DY + 1, x
    ld   ac, [y,x]
    ld   FL_DX, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r390, [x]
    ld   LINK_HI, x
    ld   scw_r390 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r390:
    ld   [u0], ac
    ld   ac, [w0]
    ld   [u1], ac
    ld   ac, [w1]
    ld   FL_DY, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r391, [x]
    ld   LINK_HI, x
    ld   scw_r391 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r391:
    ld   LINK_LO, x             ; CALL fl_max
    ld   scw_r392, [x]
    ld   LINK_HI, x
    ld   scw_r392 >> 8, [x]
    ld   fl_max >> 8, y
    jmp  fl_max
scw_r392:
    ld   [w0], ac
    sub  WRECK_BOX, ac
    ld   ac, [w0]
    ld   [w1], ac
    bcc  fr_3
    dec
fr_3:
    ld   ac, [w1]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; fl_speed - w1:w0 = the larger of |vx| and |vy| in 1/256 m a frame (the
; velocities' top two bytes)
nav_action:
    ld   LINK_LO, x             ; CALL near
    ld   scw_r418, [x]
    ld   LINK_HI, x
    ld   scw_r418 >> 8, [x]
    ld   near >> 8, y
    jmp  near
scw_r418:
    bne  nv_ok
    ld   s_toofar & 0xFF, ac
    ld   ac, [R0]
    ld   s_toofar >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r419, [x]
    ld   LINK_HI, x
    ld   scw_r419 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r419:
    ld   sc_leave >> 8, y
    jmp  sc_leave
nv_ok:
    ld   SWAP_LO >> 8, ac       ; SCRAP.NAV into x4100 (6 sectors), SCRAP.NV2
    ld   ac, [u5]               ; over the art (x3600-x3FFF, 5: the ship view
    ld   6, ac                  ; is not drawn while the map is up)
    ld   ac, [u6]
    ld   s_navf & 0xFF, ac
    ld   LINK_LO, x             ; CALL nav_fetch
    ld   scw_r420, [x]
    ld   LINK_HI, x
    ld   scw_r420 >> 8, [x]
    ld   nav_fetch >> 8, y
    jmp  nav_fetch
scw_r420:
    beq  nv_2
    ld   sc_leave >> 8, y
    jmp  sc_leave
nv_2:
    ld   NAV2_LO >> 8, ac
    ld   ac, [u5]
    ld   5, ac
    ld   ac, [u6]
    ld   s_nv2f & 0xFF, ac
    ld   LINK_LO, x             ; CALL nav_fetch
    ld   scw_r421, [x]
    ld   LINK_HI, x
    ld   scw_r421 >> 8, [x]
    ld   nav_fetch >> 8, y
    jmp  nav_fetch
scw_r421:
    bne  nv_f
    ld   LINK_LO, x             ; CALL pt_hide
    ld   scw_r422, [x]
    ld   LINK_HI, x
    ld   scw_r422 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r422:
    ld   LINK_LO, x             ; CALL nav_main
    ld   scw_r423, [x]
    ld   LINK_HI, x
    ld   scw_r423 >> 8, [x]
    ld   nav_main >> 8, y
    jmp  nav_main
scw_r423:
    ld   nav_back >> 8, y       ; (in scrap.masm's code, where there is room)
    jmp  nav_back
nv_f:
    ld   nv_a >> 8, y
    jmp  nv_a

; nav_fetch - swap_fetch of the file whose low byte is AC (in s_navf's
; page): SCRAP.NAV, SCRAP.NV2, SCRAP.ART or SCRAP.DCK.  The rest is swap_fetch's

#overlay 0xFE00
fl_stop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL fl_back
    ld   scw_r406, [x]
    ld   LINK_HI, x
    ld   scw_r406 >> 8, [x]
    ld   fl_back >> 8, y
    jmp  fl_back
scw_r406:
    ld   FL_PG, y
    ld   FL_VX, ac
    ld   ac, [u0]
fs_vl:
    ld   [u0], x
    ld   0x00, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  FL_VY + 4, ac
    bne  fs_vl
    ld   FL_AL, x
    ld   0x00, [y,x]
    ld   s_bump & 0xFF, ac
    ld   ac, [R0]
    ld   s_bump >> 8, ac
    ld   ac, [R1]
    ld   [rb_go], ac
    beq  fs_m
    ld   s_hit & 0xFF, ac
    ld   ac, [R0]
    ld   s_hit >> 8, ac
    ld   ac, [R1]
fs_m:
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r407, [x]
    ld   LINK_HI, x
    ld   scw_r407 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r407:
    ld   [rb_go], ac
    beq  ffs_e
    ld   [inv], ac
    bne  ffs_e
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   [y,x], ac
    bne  ffs_e
    ld   LINK_LO, x             ; CALL rooms_build
    ld   scw_r408, [x]
    ld   LINK_HI, x
    ld   scw_r408 >> 8, [x]
    ld   rooms_build >> 8, y
    jmp  rooms_build
scw_r408:
    clr  ac
    ld   ac, [rb_go]
    ld   LINK_LO, x             ; CALL draw_view
    ld   scw_r409, [x]
    ld   LINK_HI, x
    ld   scw_r409 >> 8, [x]
    ld   draw_view >> 8, y
    jmp  draw_view
scw_r409:
    ld   LINK_LO, x             ; CALL hover_update
    ld   scw_r410, [x]
    ld   LINK_HI, x
    ld   scw_r410 >> 8, [x]
    ld   hover_update >> 8, y
    jmp  hover_update
scw_r410:
ffs_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; draw_alarm - the flight's alarm on the message row (red), when there is
; no message and no air warning.  The rest of draw_msg
fl_a16:
    ld   [w2], ac
    ld   ac, [R0]
    ld   FL_PG, y
    ld   FL_NT, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r376, [x]
    ld   LINK_HI, x
    ld   scw_r376 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r376:
    clr  ac
    ld   ac, [w3]
fa6_l:
    ld   [R3], ac
    beq  fa6_d
    ld   [R2], ac
    ld   ac, [R0]
    ld   [R3], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL shr16
    ld   scw_r377, [x]
    ld   LINK_HI, x
    ld   scw_r377 >> 8, [x]
    ld   shr16 >> 8, y
    jmp  shr16
scw_r377:
    ld   [R0], ac
    ld   ac, [R2]
    ld   [R1], ac
    ld   ac, [R3]
    ld   [w3], ac
    inc
    ld   ac, [w3]
    bra  fa6_l
fa6_d:
    ld   [w3], ac
    sub  4, ac
    bcs  fa6_k
    ld   255, ac                ; more than 3 shifts: the most
    ld   ac, [R2]
    ld   3, ac
    ld   ac, [w3]
fa6_k:
    ld   FL_PG, y
    ld   FL_A8, x
    ld   [R2], ac
    ld   ac, [y,x]
    ld   FL_AE, x
    ld   [w3], ac
    ld   ac, [y,x]
    ld   fl_fuel >> 8, y
    jmp  fl_fuel

; fl_fuel - the kg left: N2_TANK_L a nitrogen tank by a working intake
; (n_fuel), less those burnt, 0 at least; then fl_dv.  The rest of
; fl_accel

#overlay2 0x3600
nv_mt:
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
    ld   LINK_LO, x             ; u1:u0 its size, u2 where it is
    ld   scw_r591, [x]
    ld   LINK_HI, x
    ld   scw_r591 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r591:
    ld   FL_PG, y
    ld   [u2], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    and  0x80, ac
    ld   ac, [v6]               ; v6: under 0
    ld   [v4], ac
    and  31, ac
    add  COS32 & 0xFF, x
    ld   COS32 >> 8, y
    ld   [y,x], ac
    blt  mt_n
    bra  mt_p
mt_n:
    xor  0xFF, ac
    inc
    ld   ac, [v7]
    ld   [v6], ac
    xor  0x80, ac
    ld   ac, [v6]
    ld   [v7], ac
mt_p:
    ld   ac, [v7]               ; v7 |cos|
    ld   ac, [R1]
    ld   [u0], ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; the low byte x |cos| / 128: w0
    ld   scw_r592, [x]
    ld   LINK_HI, x
    ld   scw_r592 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r592:
    ld   [R2], ac
    and  0x80, ac
    beq  mt_0
    ld   1, ac
mt_0:
    ld   ac, [w0]
    ld   [R3], ac
    shl
    or   [w0], ac
    ld   ac, [w0]
    ld   [u1], ac
    ld   ac, [R0]
    ld   [v7], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; the high byte x |cos| x 2: w3:w2
    ld   scw_r593, [x]
    ld   LINK_HI, x
    ld   scw_r593 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r593:
    ld   [R2], ac
    shl
    ld   ac, [w2]
    ld   [R3], ac
    bcc  mt_1
    shl
    inc
    bra  mt_2
mt_1:
    shl
mt_2:
    ld   ac, [w3]
    ld   nv_mt2 >> 8, y
    jmp  nv_mt2

; nv_mt2 - the sum, its sign, added to NV_RS.  The rest of nv_mt
nv_atan2:
    clr  ac
    ld   ac, [v5]
    ld   ac, [v4]
ak_l:
    ld   [w4], ac
    ld   ac, [R0]
    ld   [v4], ac
    add  NV_TAN & 0xFF, x
    ld   NV_TAN >> 8, y
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; the larger x tan: R3 its whole part
    ld   scw_r545, [x]
    ld   LINK_HI, x
    ld   scw_r545 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r545:
    ld   [R3], ac
    sub  [w5], ac
    bcc  ak_n
    ld   [v5], ac
    inc
    ld   ac, [v5]
ak_n:
    ld   [v4], ac
    inc
    ld   ac, [v4]
    xor  4, ac
    bne  ak_l
    ld   [w6], ac               ; a = k, or 8 - k
    beq  ak_a
    ld   8, ac
    sub  [v5], ac
    ld   ac, [v5]
ak_a:
    ld   FL_PG, y
    ld   NV_AX + 1, x
    ld   [y,x], ac
    blt  ak_xn
    ld   NV_AY + 1, x
    ld   [y,x], ac
    blt  ak_4
    ld   [v5], ac               ; x+ y+: a
    bra  nk_ae
ak_4:
    ld   32, ac                 ; x+ y-: 32 - a
    sub  [v5], ac
    bra  nk_ae
ak_xn:
    ld   NV_AY + 1, x
    ld   [y,x], ac
    blt  ak_3
    ld   16, ac                 ; x- y+: 16 - a
    sub  [v5], ac
    bra  nk_ae
ak_3:
    ld   16, ac                 ; x- y-: 16 + a
    add  [v5], ac
nk_ae:
    and  31, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave


#overlay2 0x3700
nv_gmv:
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
    ld   FL_PG, y
    ld   FL_PX + 2, x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   FL_PX + 3, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   FL_PY + 2, x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   FL_PY + 3, x
    ld   [y,x], ac
    ld   ac, [w3]
    ld   NV_ZS, x
    ld   [y,x], ac
    ld   ac, [v2]
gm_s:
    ld   [v2], ac
    beq  gm_d
    dec
    ld   ac, [v2]
    ld   LINK_LO, x             ; CALL nv_sh2
    ld   scw_r509, [x]
    ld   LINK_HI, x
    ld   scw_r509 >> 8, [x]
    ld   nv_sh2 >> 8, y
    jmp  nv_sh2
scw_r509:
    bra  gm_s
gm_d:
    ld   [w0], ac
    and  63, ac
    ld   ac, [v4]
    ld   [w2], ac
    add  36, ac
    and  63, ac
    ld   ac, [v5]
    ld   FL_PG, y
    ld   NV_GX, x
    ld   [y,x], ac
    xor  [v4], ac
    bne  gm_m
    ld   NV_GY, x
    ld   [y,x], ac
    xor  [v5], ac
    beq  gm_e
gm_m:
    clr  ac
    ld   LINK_LO, x             ; CALL nv_gl
    ld   scw_r510, [x]
    ld   LINK_HI, x
    ld   scw_r510 >> 8, [x]
    ld   nv_gl >> 8, y
    jmp  nv_gl
scw_r510:
    ld   FL_PG, y
    ld   NV_GX, x
    ld   [v4], ac
    ld   ac, [y,x]
    ld   NV_GY, x
    ld   [v5], ac
    ld   ac, [y,x]
    ld   1, ac
    ld   LINK_LO, x             ; CALL nv_gl
    ld   scw_r511, [x]
    ld   LINK_HI, x
    ld   scw_r511 >> 8, [x]
    ld   nv_gl >> 8, y
    jmp  nv_gl
scw_r511:
gm_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_modes - the status row's lines (0-15) 1 bpp, the map's (16-383) 2 bpp
nv_spd:
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
    ld   ac, [v0]
    ld   NV_RS, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r584, [x]
    ld   LINK_HI, x
    ld   scw_r584 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r584:
    ld   [u1], ac
    ld   ac, [R3]
    ld   [u0], ac
    ld   ac, [R2]
    ld   [v0], ac
    beq  nsp_p
    ld   FL_PG, y
    ld   NV_RS + 1, x
    ld   [y,x], ac
    blt  nsp_n
    bra  nsp_p
nsp_n:
    ld   0x2D, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r585, [x]
    ld   LINK_HI, x
    ld   scw_r585 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r585:
nsp_p:
    ld   LINK_LO, x             ; CALL nv_q4
    ld   scw_r586, [x]
    ld   LINK_HI, x
    ld   scw_r586 >> 8, [x]
    ld   nv_q4 >> 8, y
    jmp  nv_q4
scw_r586:
    ld   LINK_LO, x             ; CALL nv_ms
    ld   scw_r587, [x]
    ld   LINK_HI, x
    ld   scw_r587 >> 8, [x]
    ld   nv_ms >> 8, y
    jmp  nv_ms
scw_r587:
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r588, [x]
    ld   LINK_HI, x
    ld   scw_r588 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r588:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_dot - NV_RS = the tug's velocity along angle AC: vx cos + vy sin

#overlay2 0x3800
nv_stat3:
    ld   FL_PG, y
    ld   FL_ML, x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   FL_MH, x
    ld   [y,x], ac
    ld   ac, [w1]
    clr  ac
    ld   ac, [w2]
    ld   5, ac
    ld   LINK_LO, x             ; CALL nv_dv
    ld   scw_r602, [x]
    ld   LINK_HI, x
    ld   scw_r602 >> 8, [x]
    ld   nv_dv >> 8, y
    jmp  nv_dv
scw_r602:
    ld   [w1], ac
    beq  dv_mq
    ld   0xFF, ac
    ld   ac, [w0]
dv_mq:
    ld   [w0], ac               ; (not 0: the tug weighs something)
    ld   ac, [v6]
    ld   FL_PG, y               ; kg x 40: low byte, then high byte x 40
    ld   NV_QL, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   40, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r603, [x]
    ld   LINK_HI, x
    ld   scw_r603 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r603:
    ld   [R2], ac
    ld   ac, [w0]
    ld   [R3], ac
    ld   ac, [w1]
    ld   FL_PG, y
    ld   NV_QL + 1, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   40, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r604, [x]
    ld   LINK_HI, x
    ld   scw_r604 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r604:
    ld   [R2], ac
    add  [w1], ac
    ld   ac, [w1]
    ld   [R3], ac
    bcc  dv_n
    inc
dv_n:
    ld   ac, [w2]
    ld   [v6], ac
    ld   LINK_LO, x             ; CALL nv_dv
    ld   scw_r605, [x]
    ld   LINK_HI, x
    ld   scw_r605 >> 8, [x]
    ld   nv_dv >> 8, y
    jmp  nv_dv
scw_r605:
    ld   FL_PG, y
    ld   NV_QDV, x
    ld   [w0], ac
    ld   ac, [y,x]
    ld   NV_QDV + 1, x
    ld   [w1], ac
    ld   ac, [y,x]
    ld   nv_strow >> 8, y
    jmp  nv_strow

; nv_strow - the status row from NV_QT: a code (0 the end, 1 a string in
; NV_STR's page, 2 a byte at FL_PG + the next byte in 2 digits, 3 two
; bytes there in decimal) and its byte.  The end of nv_stat (its LEAVE)
nv_spt:
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
    ld   FL_PG, y
    ld   FL_SFL, x
    ld   [FRAME_LO], ac
    sub  [y,x], ac
    ld   ac, [v0]
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   FL_SFH, x
    ld   [FRAME_HI], ac
    bcc  st_nb
    dec
st_nb:
    sub  [y,x], ac
    and  0x1F, ac
    ld   ac, [v1]
    ld   [FRAME_HI], ac
    ld   ac, [y,x]
    ld   FL_SPN, x              ; not spinning: nothing to work out
    ld   [y,x], ac
    beq  st_e
    clr  ac
    ld   ac, [v2]
st_l:
    ld   [v0], ac
    or   [v1], ac
    beq  st_d
    ld   LINK_LO, x             ; CALL nv_spin
    ld   scw_r503, [x]
    ld   LINK_HI, x
    ld   scw_r503 >> 8, [x]
    ld   nv_spin >> 8, y
    jmp  nv_spin
scw_r503:
    or   [v2], ac
    ld   ac, [v2]
    ld   [v0], ac
    bne  spt_1
    ld   [v1], ac
    dec
    ld   ac, [v1]
spt_1:
    ld   [v0], ac
    dec
    ld   ac, [v0]
    bra  st_l
st_d:
    ld   [v2], ac
    beq  st_e
    ld   LINK_LO, x             ; CALL fl_dv
    ld   scw_r504, [x]
    ld   LINK_HI, x
    ld   scw_r504 >> 8, [x]
    ld   fl_dv >> 8, y
    jmp  fl_dv
scw_r504:
st_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_spin - a frame of spin: R's stop (the spin 1 nearer 0), then the
; heading's fraction + the spin, a step on when it carries (AC 1, else
; 0).  A leaf (u0).
nv_stat:
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
    ld   ACT_PG, y              ; w2:w1:w0 = the clock (seconds from
    ld   CLK_0 & 0xFF, x        ; 05-07-2175 00:00:00)
    ld   [y,x], ac
    ld   ac, [w0]
    ld   CLK_1 & 0xFF, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   CLK_2 & 0xFF, x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   60, ac                 ; seconds, minutes, hours
    ld   LINK_LO, x             ; CALL nv_dv
    ld   scw_r596, [x]
    ld   LINK_HI, x
    ld   scw_r596 >> 8, [x]
    ld   nv_dv >> 8, y
    jmp  nv_dv
scw_r596:
    ld   NV_QS, ac
    ld   LINK_LO, x             ; CALL nv_qput
    ld   scw_r597, [x]
    ld   LINK_HI, x
    ld   scw_r597 >> 8, [x]
    ld   nv_qput >> 8, y
    jmp  nv_qput
scw_r597:
    ld   60, ac
    ld   LINK_LO, x             ; CALL nv_dv
    ld   scw_r598, [x]
    ld   LINK_HI, x
    ld   scw_r598 >> 8, [x]
    ld   nv_dv >> 8, y
    jmp  nv_dv
scw_r598:
    ld   NV_QMI, ac
    ld   LINK_LO, x             ; CALL nv_qput
    ld   scw_r599, [x]
    ld   LINK_HI, x
    ld   scw_r599 >> 8, [x]
    ld   nv_qput >> 8, y
    jmp  nv_qput
scw_r599:
    ld   24, ac
    ld   LINK_LO, x             ; CALL nv_dv
    ld   scw_r600, [x]
    ld   LINK_HI, x
    ld   scw_r600 >> 8, [x]
    ld   nv_dv >> 8, y
    jmp  nv_dv
scw_r600:
    ld   NV_QH, ac
    ld   LINK_LO, x             ; CALL nv_qput
    ld   scw_r601, [x]
    ld   LINK_HI, x
    ld   scw_r601 >> 8, [x]
    ld   nv_qput >> 8, y
    jmp  nv_qput
scw_r601:
    ld   nv_stat2 >> 8, y
    jmp  nv_stat2

; nv_qput - FL_PG + AC = w3 (nv_dv's remainder).  A leaf.
nv_gl:
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
    ld   ac, [u2]
    ld   FL_PG, y
    ld   NV_GX, x
    clr  ac
    sub  [y,x], ac
    ld   ac, [v2]               ; v2 = -GX, v3 = -GY
    ld   NV_GY, x
    clr  ac
    sub  [y,x], ac
    ld   ac, [v3]
    ld   [v2], ac               ; down: x = -GX mod 64, + 64 k
    and  63, ac
    ld   ac, [v0]
gv_x:
    ld   [v3], ac
    and  3, ac
    ld   ac, [v1]
gv_y:
    ld   LINK_LO, x             ; CALL nv_gp
    ld   scw_r507, [x]
    ld   LINK_HI, x
    ld   scw_r507 >> 8, [x]
    ld   nv_gp >> 8, y
    jmp  nv_gp
scw_r507:
    ld   [v1], ac
    add  4, ac
    ld   ac, [v1]
    sub  184, ac
    bcs  gv_y
    ld   [v0], ac
    add  64, ac
    ld   ac, [v0]
    bcc  gv_x
    ld   [v3], ac               ; across: y = -GY mod 64, + 64 k
    and  63, ac
    ld   ac, [v1]
gh_y:
    ld   [v2], ac
    and  3, ac
    ld   ac, [v0]
gh_x:
    ld   LINK_LO, x             ; CALL nv_gp
    ld   scw_r508, [x]
    ld   LINK_HI, x
    ld   scw_r508 >> 8, [x]
    ld   nv_gp >> 8, y
    jmp  nv_gp
scw_r508:
    ld   [v0], ac
    add  4, ac
    ld   ac, [v0]
    bcc  gh_x
    ld   [v1], ac
    add  64, ac
    ld   ac, [v1]
    sub  184, ac
    bcs  gh_y
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_gp - nv_plot at v0, v1.  The rest of the caller's (nv_plot's RET)
s_km:
    #d " KM", 0x00

; the panel's strings: one page (nv_s takes the low byte); the titles are
; inverse letters (bit 7)

#overlay2 0x3A00
nv_tg:
tg_l:
    ld   NV_DRT >> 8, y
    ld   [v6], x
    ld   [y,x], ac
    xor  0x80, ac
    beq  tg_d
    ld   [y,x], ac              ; x: u cos - w sin (cos (a + 8) = -sin)
    ld   ac, [v2]
    clr  ac
    ld   LINK_LO, x             ; CALL nv_term
    ld   scw_r533, [x]
    ld   LINK_HI, x
    ld   scw_r533 >> 8, [x]
    ld   nv_term >> 8, y
    jmp  nv_term
scw_r533:
    ld   ac, [v0]
    ld   LINK_LO, x             ; CALL nv_tw
    ld   scw_r534, [x]
    ld   LINK_HI, x
    ld   scw_r534 >> 8, [x]
    ld   nv_tw >> 8, y
    jmp  nv_tw
scw_r534:
    ld   8, ac
    ld   LINK_LO, x             ; CALL nv_term
    ld   scw_r535, [x]
    ld   LINK_HI, x
    ld   scw_r535 >> 8, [x]
    ld   nv_term >> 8, y
    jmp  nv_term
scw_r535:
    add  [v0], ac
    add  128, ac
    ld   ac, [u0]
    clr  ac                     ; y: u sin + w cos (cos (a + 24) = sin)
    ld   LINK_LO, x             ; CALL nv_term
    ld   scw_r536, [x]
    ld   LINK_HI, x
    ld   scw_r536 >> 8, [x]
    ld   nv_term >> 8, y
    jmp  nv_term
scw_r536:
    ld   ac, [v1]
    ld   NV_DRT >> 8, y
    ld   [v6], x
    ld   [y,x], ac
    ld   ac, [v2]
    ld   24, ac
    ld   LINK_LO, x             ; CALL nv_term
    ld   scw_r537, [x]
    ld   LINK_HI, x
    ld   scw_r537 >> 8, [x]
    ld   nv_term >> 8, y
    jmp  nv_term
scw_r537:
    add  [v1], ac
    add  92, ac
    ld   ac, [u1]
    ld   LINK_LO, x             ; CALL nv_put
    ld   scw_r538, [x]
    ld   LINK_HI, x
    ld   scw_r538 >> 8, [x]
    ld   nv_put >> 8, y
    jmp  nv_put
scw_r538:
    ld   [v6], ac
    add  2, ac
    ld   ac, [v6]
    bra  tg_l
tg_d:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_tw - v2 = the point's y (NV_DRT + v6 + 1).  A leaf.
nv_pn6:
    ld   28, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   s_k0 & 0xFF, ac
    ld   ac, [R0]
    ld   s_k0 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r578, [x]
    ld   LINK_HI, x
    ld   scw_r578 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r578:
    ld   0x80, ac
    ld   ac, [p_inv]
    ld   FL_PG, y               ; the range across: 1 << FL_ZM km (256
    ld   FL_ZM, x               ; pixels of 4 m << FL_ZM: 1.024 km << it)
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_bit
    ld   scw_r579, [x]
    ld   LINK_HI, x
    ld   scw_r579 >> 8, [x]
    ld   nv_bit >> 8, y
    jmp  nv_bit
scw_r579:
    ld   ac, [num_l]
    clr  ac
    ld   ac, [num_h]
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r580, [x]
    ld   LINK_HI, x
    ld   scw_r580 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r580:
    ld   s_km & 0xFF, ac
    ld   ac, [R0]
    ld   s_km >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r581, [x]
    ld   LINK_HI, x
    ld   scw_r581 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r581:
    clr  ac
    ld   ac, [p_inv]
    ld   s_k1 & 0xFF, ac
    ld   ac, [R0]
    ld   s_k1 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r582, [x]
    ld   LINK_HI, x
    ld   scw_r582 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r582:
    ld   LINK_LO, x             ; CALL draw_msg
    ld   scw_r583, [x]
    ld   LINK_HI, x
    ld   scw_r583 >> 8, [x]
    ld   draw_msg >> 8, y
    jmp  draw_msg
scw_r583:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; the range's unit

#overlay2 0x3B00
nv_draw:
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
    ld   LINK_LO, x             ; CALL pt_hide
    ld   scw_r512, [x]
    ld   LINK_HI, x
    ld   scw_r512 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r512:
    ld   LINK_LO, x             ; CALL nv_rub
    ld   scw_r513, [x]
    ld   LINK_HI, x
    ld   scw_r513 >> 8, [x]
    ld   nv_rub >> 8, y
    jmp  nv_rub
scw_r513:
    ld   FL_PG, y               ; NV_ZS = 2 + zoom
    ld   FL_ZM, x
    ld   [y,x], ac
    add  2, ac
    ld   NV_ZS, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL nv_gmv
    ld   scw_r514, [x]
    ld   LINK_HI, x
    ld   scw_r514 >> 8, [x]
    ld   nv_gmv >> 8, y
    jmp  nv_gmv
scw_r514:
    ld   FL_PG, y
    ld   NV_I, x
    ld   0x00, [y,x]
nd_l:
    ld   LINK_LO, x             ; CALL nv_cnt
    ld   scw_r515, [x]
    ld   LINK_HI, x
    ld   scw_r515 >> 8, [x]
    ld   nv_cnt >> 8, y
    jmp  nv_cnt
scw_r515:
    ld   ac, [u6]
    ld   FL_PG, y
    ld   NV_I, x
    ld   [y,x], ac
    xor  [u6], ac
    beq  nd_t
    ld   LINK_LO, x             ; CALL nv_obj
    ld   scw_r516, [x]
    ld   LINK_HI, x
    ld   scw_r516 >> 8, [x]
    ld   nv_obj >> 8, y
    jmp  nv_obj
scw_r516:
    ld   FL_PG, y
    ld   NV_I, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bra  nd_l
nd_t:
    ld   nv_tug >> 8, y
    jmp  nv_tug

; nv_ent - AC = an object: its SEC_REC bytes to NV_E (FL_PG), NV_DL = it
; from the tug (metres).  A leaf.
nv_panel:
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
    ld   161, ac
    ld   LINK_LO, x             ; CALL clear_rows
    ld   scw_r546, [x]
    ld   LINK_HI, x
    ld   scw_r546 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r546:
    clr  ac
    ld   ac, [v0]
lb_l:
    ld   NV_LAB >> 8, y
    ld   [v0], ac
    add  NV_LAB & 0xFF, x
    ld   [y,x], ac
    beq  lb_e
    ld   ac, [CUR_ROW]
    ld   [v0], ac
    add  (NV_LAB & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [CUR_COL]
    ld   [v0], ac
    add  (NV_LAB & 0xFF) + 2, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_s
    ld   scw_r547, [x]
    ld   LINK_HI, x
    ld   scw_r547 >> 8, [x]
    ld   nv_s >> 8, y
    jmp  nv_s
scw_r547:
    ld   [v0], ac
    add  3, ac
    ld   ac, [v0]
    bra  lb_l
lb_e:
    ld   nv_pn1 >> 8, y
    jmp  nv_pn1
NV_LAB:
    #d8 24, 1, s_t1 & 0xFF, 24, 20, s_t2 & 0xFF, 24, 39, s_t3 & 0xFF
    #d8 25, 1, s_head & 0xFF
    #d8 25, 20, s_n2 & 0xFF, 26, 20, s_mass & 0xFF, 27, 20, s_thr & 0xFF
    #d8 25, 62, s_reg & 0xFF, 26, 39, s_rng & 0xFF, 26, 54, s_rad & 0xFF
    #d8 27, 39, s_tow & 0xFF, 27, 57, s_acr & 0xFF, 0

; nv_pn1 - the boxes, the target's name in its title (inverse, to the
; block's end), nitrogen.  The rest of nv_panel
nv_gp:
    ld   [v0], ac
    ld   ac, [u0]
    ld   [v1], ac
    ld   ac, [u1]
    ld   nv_plot >> 8, y
    jmp  nv_plot

; nv_gmv - the grid's offsets from the tug's position (metres >> NV_ZS,
; mod 64; y + 36, so lines cross at the middle, 92): when they change, the
; old grid off and the new one on
nv_atan:
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
    ld   NV_AX, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r542, [x]
    ld   LINK_HI, x
    ld   scw_r542 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r542:
    ld   [u0], ac
    ld   ac, [w0]
    ld   [u1], ac
    ld   ac, [w1]
    ld   NV_AY, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r543, [x]
    ld   LINK_HI, x
    ld   scw_r543 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r543:
    ld   [u0], ac
    ld   ac, [w2]
    ld   [u1], ac
    ld   ac, [w3]
an_s:
    ld   [w1], ac               ; both to 8 bits
    or   [w3], ac
    beq  an_d
    ld   LINK_LO, x             ; CALL nv_sh2
    ld   scw_r544, [x]
    ld   LINK_HI, x
    ld   scw_r544 >> 8, [x]
    ld   nv_sh2 >> 8, y
    jmp  nv_sh2
scw_r544:
    bra  an_s
an_d:
    clr  ac
    ld   ac, [w6]
    ld   [w0], ac
    ld   ac, [w4]               ; w4 the larger, w5 the smaller
    ld   [w2], ac
    ld   ac, [w5]
    ld   [w0], ac
    sub  [w2], ac
    bcc  an_k
    ld   [w2], ac
    ld   ac, [w4]
    ld   [w0], ac
    ld   ac, [w5]
    ld   1, ac
    ld   ac, [w6]               ; w6: y the larger
an_k:
    ld   nv_atan2 >> 8, y
    jmp  nv_atan2

; nv_atan2 - the step in the octant, the quadrant.  The rest of nv_atan
nv_cm:
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
    ld   FL_PG, y
    ld   NV_ANG, x
    ld   [y,x], ac
    add  [w1], ac
    and  31, ac
    add  COS32 & 0xFF, x
    ld   COS32 >> 8, y
    ld   [y,x], ac
    ld   ac, [w1]
    blt  cm_n
    bra  cm_p
cm_n:
    xor  0xFF, ac
    inc
cm_p:
    ld   ac, [R0]
    ld   [v3], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r529, [x]
    ld   LINK_HI, x
    ld   scw_r529 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r529:
    ld   [R2], ac               ; rounded
    add  64, ac
    ld   ac, [R2]
    ld   [R3], ac
    bcc  cm_r
    inc
    ld   ac, [R3]
cm_r:
    ld   [R2], ac
    and  0x80, ac
    beq  cm_0
    ld   1, ac
cm_0:
    ld   ac, [w0]
    ld   [R3], ac
    shl
    or   [w0], ac
    ld   ac, [w0]
    ld   [w1], ac
    blt  cm_m
    ld   [w0], ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
cm_m:
    ld   [w0], ac
    xor  0xFF, ac
    inc
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_vert - u0, u1 = the point v3 out at NV_ANG + AC (x: v3 cos, y:
; v3 sin)
nv_tw:
    ld   NV_DRT >> 8, y
    ld   [v6], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [v2]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_term - AC = v2 (signed) x cos (NV_ANG + AC): nv_cm's, which it ends in
nv_cnt:
    ld   SEC >> 8, y
    ld   0x00, x
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_seln - AC: the new target; the map and the panel again.  The rest
; of nv_pick, nv_keys
nv_pn1:
    ld   LINK_LO, x             ; CALL nv_box
    ld   scw_r548, [x]
    ld   LINK_HI, x
    ld   scw_r548 >> 8, [x]
    ld   nv_box >> 8, y
    jmp  nv_box
scw_r548:
    ld   FL_PG, y
    ld   NV_SEL, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_ent
    ld   scw_r549, [x]
    ld   LINK_HI, x
    ld   scw_r549 >> 8, [x]
    ld   nv_ent >> 8, y
    jmp  nv_ent
scw_r549:
    ld   24, ac
    ld   ac, [CUR_ROW]
    ld   48, ac
    ld   ac, [CUR_COL]
    ld   0x80, ac
    ld   ac, [p_inv]
    ld   FL_PG, y
    ld   E_NM, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_s55
    ld   scw_r550, [x]
    ld   LINK_HI, x
    ld   scw_r550 >> 8, [x]
    ld   nv_s55 >> 8, y
    jmp  nv_s55
scw_r550:
p1_l:
    ld   [CUR_COL], ac
    xor  79, ac
    beq  p1_e
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r551, [x]
    ld   LINK_HI, x
    ld   scw_r551 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r551:
    bra  p1_l
p1_e:
    ld   ac, [p_inv]            ; (AC 0)
    ld   25, ac
    ld   ac, [CUR_ROW]
    ld   FL_PG, y
    ld   FL_FLL, x
    ld   [y,x], ac
    ld   ac, [num_l]
    ld   FL_FLH, x
    ld   [y,x], ac
    ld   ac, [num_h]
    ld   31, ac
    ld   LINK_LO, x             ; CALL nv_dec
    ld   scw_r552, [x]
    ld   LINK_HI, x
    ld   scw_r552 >> 8, [x]
    ld   nv_dec >> 8, y
    jmp  nv_dec
scw_r552:
    ld   nv_pn2 >> 8, y
    jmp  nv_pn2

; nv_dec - num in decimal from column AC (put_dec's return is the
; caller's).  nv_s - the string in NV_STR's page whose low byte is AC, at
; the cursor.  nv_s55 - the same in the sector file's strings (page x55)
nv_px:
    ld   ac, [w2]
    ld   128, ac
    bra  nx_go
nv_py:
    ld   ac, [w2]
    ld   92, ac
nx_go:
    ld   ac, [w3]               ; w3 the middle and the half size
    ld   FL_PG, y               ; w1:w0 the metres, w2 the shift
    ld   [w2], x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   [w2], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   NV_ZS, x
    ld   [y,x], ac
    add  [u7], ac
    ld   ac, [w2]
    ld   ac, [w5]
pj_l:
    ld   [w5], ac
    beq  pj_d
    dec
    ld   ac, [w5]
    ld   [w1], ac
    and  1, ac
    beq  pj_0
    ld   0x80, ac
pj_0:
    ld   ac, [w6]
    ld   [w0], ac
    shr  ac
    or   [w6], ac
    ld   ac, [w0]
    ld   [w1], ac
    and  0x80, ac
    ld   ac, [w6]
    ld   [w1], ac
    shr  ac
    or   [w6], ac
    ld   ac, [w1]
    bra  pj_l
pj_d:
    ld   [w1], ac
    beq  pj_p
    xor  0xFF, ac
    bne  pj_off
    ld   [w0], ac
    add  [w3], ac
    bcc  pj_off
    bra  pj_ok
pj_p:
    ld   [w0], ac
    sub  [w3], ac
    bcc  pj_off
pj_ok:
    ld   [w0], ac
    add  [w3], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
pj_off:
    ld   0xFF, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]




; nv_q4 - num = R3:R2 / 4.  A leaf.
nv_term:
    ld   ac, [v5]
    ld   [v2], ac
    blt  tm_n
    ld   ac, [v3]
    ld   [v5], ac
    ld   nv_cm >> 8, y
    jmp  nv_cm
tm_n:
    xor  0xFF, ac
    inc
    ld   ac, [v3]
    ld   [v5], ac
    add  16, ac
    ld   nv_cm >> 8, y
    jmp  nv_cm

; the tug's drift's dots (9, 12, 15 out): x, y pairs, then x80
nv_box:
    clr  ac
    ld   ac, [u0]
bx_c:
    ld   NV_BXC >> 8, y
    ld   [u0], ac
    add  NV_BXC & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   177, ac
    ld   ac, [u2]
bx_l:
    ld   [u1], y
    ld   [u2], x
    ld   [y,x], ac
    or   0x80, ac
    ld   ac, [y,x]
    ld   [u2], ac
    add  2, ac
    ld   ac, [u2]
    xor  225, ac
    bne  bx_l
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  6, ac
    bne  bx_c
    ld   0x63, ac               ; under: columns 1-78
    ld   ac, [u1]
bx_b:
    ld   [u1], y
    ld   223, x
    ld   0xFF, [y,x]
    ld   [u1], ac
    add  2, ac
    ld   ac, [u1]
    xor  0xFF, ac
    bne  bx_b
    ld   0x61 + 38, y           ; the gaps: columns 19 and 38 their side only
    ld   0x80, [y,x]
    ld   0x61 + 76, y
    ld   0x80, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
NV_BXC:
    #d8 0x61, 0x61 + 36, 0x61 + 38, 0x61 + 74, 0x61 + 76, 0x61 + 156

; nv_pn2 - heading, mass, docked, thrusters.  The rest of nv_panel
nv_atv:
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
    ld   ac, [u1]
    ld   FL_PG, y
    ld   [u0], x
    ld   [y,x], ac
    ld   NV_AX, x
    ld   ac, [y,x]
    ld   [u0], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   NV_AX + 1, x
    ld   ac, [y,x]
    ld   [u1], x
    ld   [y,x], ac
    ld   NV_AY, x
    ld   ac, [y,x]
    ld   [u1], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   NV_AY + 1, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL nv_atan
    ld   scw_r541, [x]
    ld   LINK_HI, x
    ld   scw_r541 >> 8, [x]
    ld   nv_atan >> 8, y
    jmp  nv_atan
scw_r541:
    ld   FL_PG, y
    ld   NV_ANG, x
    ld   ac, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_atan - AC = the angle (0-31, 0 east, 8 down) of NV_AX, NV_AY
; (signed): the octant from the signs and which is larger, then the step
; in it from the ratio against tan 5.6, 16.9, 28.1, 39.4 degrees
nv_put:
    ld   [u0], ac
    xor  0xFF, ac
    beq  np_e
    ld   [u1], ac
    sub  184, ac
    bcc  np_e
    ld   FL_PG, y
    ld   NV_N, x
    ld   [y,x], ac
    ld   ac, [u3]
    xor  255, ac
    beq  np_e
    ld   [u3], ac
    inc
    ld   ac, [y,x]
    ld   [u3], ac               ; point i: offset (i << 1) & x1E,
    shl                         ; page x61 + (i >> 3) & x1E (x), + x20 (y)
    and  0x1E, ac
    ld   ac, x
    ld   [u3], ac
    shr  ac
    shr  ac
    shr  ac
    and  0x1E, ac
    add  0x61, ac
    ld   ac, y
    ld   [u0], ac
    ld   ac, [y,x]
    ld   [u3], ac
    shr  ac
    shr  ac
    shr  ac
    and  0x1E, ac
    add  0x81, ac
    ld   ac, y
    ld   [u1], ac
    ld   ac, [y,x]
    ld   nv_plot >> 8, y
    jmp  nv_plot
np_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_rub - the points drawn put back to the grid (or black)
nv_q4:
    ld   [R2], ac
    shr  ac
    shr  ac
    ld   ac, [num_l]
    ld   [R3], ac
    shl
    shl
    shl
    shl
    shl
    shl
    or   [num_l], ac
    ld   ac, [num_l]
    ld   [R3], ac
    shr  ac
    shr  ac
    ld   ac, [num_h]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_ms - num -= num / 16: after nv_q4, 1/256 m a frame in m/s (x 15 /
; 64).  A leaf.

#overlay2 0x3F00
nv_keys2:
    ld   [key], ac
    xor  0x29, ac               ; Tab (09, or 20): the next target
    bne  nk2_c
    ld   FL_PG, y
    ld   NV_SEL, x
    ld   [y,x], ac
    inc
    ld   ac, [u0]
    ld   LINK_LO, x             ; CALL nv_cnt
    ld   scw_r502, [x]
    ld   LINK_HI, x
    ld   scw_r502 >> 8, [x]
    ld   nv_cnt >> 8, y
    jmp  nv_cnt
scw_r502:
    xor  [u0], ac
    beq  nk2_0
    ld   [u0], ac
nk2_0:
    ld   nv_seln >> 8, y
    jmp  nv_seln
nk2_c:
    xor  0x29 ^ 0x63, ac        ; c: the docking and comms screen (SCRAP.DCK:
    bne  nk2_r                  ; nav_action reads it in when this closes)
    ld   FL_PG, y
    ld   FL_GO, x
    ld   2, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave
nk2_r:
    xor  0x63 ^ 0x72, ac        ; r: the spin stopped
    bne  nk2_e
    ld   FL_PG, y
    ld   FL_STP, x
    ld   1, [y,x]
nk2_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_spt - the spin worked out to now: nv_spin for each frame since
; FL_SFL, FL_SFH (mod 8192: the heading comes round in that many at any
; spin), then fl_dv when the heading changed
nv_vert:
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
    ld   ac, [v4]
    ld   LINK_LO, x             ; CALL nv_cm
    ld   scw_r530, [x]
    ld   LINK_HI, x
    ld   scw_r530 >> 8, [x]
    ld   nv_cm >> 8, y
    jmp  nv_cm
scw_r530:
    ld   ac, [u0]
    ld   [v4], ac
    add  24, ac
    ld   LINK_LO, x             ; CALL nv_cm
    ld   scw_r531, [x]
    ld   LINK_HI, x
    ld   scw_r531 >> 8, [x]
    ld   nv_cm >> 8, y
    jmp  nv_cm
scw_r531:
    ld   ac, [u1]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_tug - the tug: a white triangle with a notch in its back, pointing along
; its heading (FL_HD, 32 steps of 11.25 degrees, 0 to the right, clockwise).
; NV_TS holds steps 0-4 (tug_32_big.py); 5-7 are 3-1 with x and y swapped,
; and the heading's quarters turn that, (x, y) to (-y, x).  Then nv_drift.
; The rest of nv_draw
nv_thr:
    ld   FL_PG, y
    ld   FL_TH, x
    ld   [dirs], ac
    and  1, ac
    beq  th_b
    ld   FL_DVX, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
th_b:
    ld   [dirs], ac
    and  2, ac
    beq  th_q
    ld   FL_RVX, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
th_q:
    ld   [KBD_NOW + 1], ac      ; Q
    and  0x80, ac
    bne  th_e
    ld   FL_LVX, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
th_e:
    ld   [KBD_NOW + 2], ac      ; E
    and  0x02, ac
    bne  th_n
    ld   FL_SVX, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
th_n:
    ld   0x00, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_cnt - AC = the sector's objects.  A leaf.
nv_mt2:
    ld   [w2], ac
    add  [w0], ac
    ld   ac, [w2]
    ld   [w3], ac
    bcc  m2_1
    inc
m2_1:
    ld   ac, [w3]
    ld   [v6], ac
    beq  m2_a
    ld   [w2], ac
    xor  0xFF, ac
    add  1, ac
    ld   ac, [w2]
    ld   [w3], ac
    xor  0xFF, ac
    bcc  m2_2
    inc
m2_2:
    ld   ac, [w3]
m2_a:
    ld   FL_PG, y
    ld   NV_RS, x
    ld   [y,x], ac
    add  [w2], ac
    ld   ac, [y,x]
    ld   NV_RS + 1, x
    ld   [y,x], ac
    bcc  m2_3
    inc
m2_3:
    add  [w3], ac
    ld   ac, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave


; nv_exit - Esc let go (or the loop would take it for the DOS's), then
; back.  The end of nav_main
nv_qput:
    ld   ac, x
    ld   FL_PG, y
    ld   [w3], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_stat2 - the date from the days (w0: May 7 is day 0), the nitrogen.
; The rest of nv_stat

#overlay2 0x4100
NV_STR:
s_q0:
    #d "-", 0x00
s_q1:
    #d "-2175  ", 0x00
s_q2:
    #d ":", 0x00
s_q3:
    #d "   NITROGEN ", 0x00
s_q5:
    #d " KG   DELTA-V ", 0x00
s_q6:
    #d " M/S   BATTERIES ", 0x00
s_t1:                           ; " FLIGHT", 18 wide
    #d8 0xA0, 0xC6, 0xCC, 0xC9, 0xC7, 0xC8, 0xD4, 0xA0, 0xA0, 0xA0, 0xA0, 0xA0
    #d8 0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0x00
s_t2:                           ; " PROPULSION", 18 wide
    #d8 0xA0, 0xD0, 0xD2, 0xCF, 0xD0, 0xD5, 0xCC, 0xD3, 0xC9, 0xCF, 0xCE, 0xA0
    #d8 0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0x00
s_t3:                           ; " TARGET: " (then its name)
    #d8 0xA0, 0xD4, 0xC1, 0xD2, 0xC7, 0xC5, 0xD4, 0xBA, 0xA0, 0x00
s_head:
    #d "HEADING", 0x00
s_n2:
    #d "N2 KG", 0x00
s_mass:
    #d "MASS T", 0x00
s_thr:
    #d "THRUSTERS", 0x00
s_reg:
    #d "REG", 0x00
s_rng:
    #d "RANGE M", 0x00
s_rad:
    #d "RADAR %", 0x00
s_tow:
    #d "TOWARD M/S", 0x00
s_acr:
    #d "ACROSS M/S", 0x00
s_dkd:
    #d "DOCKED", 0x00
s_free:
    #d "FREE FLIGHT", 0x00
s_der:
    #d "DERELICT ", 0x00
s_stn:
    #d "STATION ", 0x00
s_nvis:
    #d "NOT "
s_vis:
    #d "VISITED", 0x00

; nv_sh2 - w1:w0 >>= 1, w3:w2 >>= 1 (no sign).  A leaf.
nv_dec:
    ld   ac, [CUR_COL]
    ld   put_dec >> 8, y
    jmp  put_dec
nv_s:
    ld   ac, [R0]
    ld   NV_STR >> 8, ac
    ld   ac, [R1]
    ld   tputs >> 8, y
    jmp  tputs
nv_s55:
    ld   ac, [R0]
    ld   SEC_STR, ac
    ld   ac, [R1]
    ld   tputs >> 8, y
    jmp  tputs

; nv_next - AC = the offset after the string at offset AC of page x55.
; A leaf.

#overlay2 0x4200
nv_loop:
nm_l:
    ld   LINK_LO, x             ; CALL pt_show
    ld   scw_r479, [x]
    ld   LINK_HI, x
    ld   scw_r479 >> 8, [x]
    ld   pt_show >> 8, y
    jmp  pt_show
scw_r479:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames_io
    ld   scw_r480, [x]
    ld   LINK_HI, x
    ld   scw_r480 >> 8, [x]
    ld   l_wait_frames_io >> 8, y
    jmp  l_wait_frames_io
scw_r480:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   scw_r481, [x]
    ld   LINK_HI, x
    ld   scw_r481 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
scw_r481:
    ld   LINK_LO, x             ; (FL_NAV: a left click is nv_pick)
    ld   scw_r482, [x]
    ld   LINK_HI, x
    ld   scw_r482 >> 8, [x]
    ld   input_mouse >> 8, y
    jmp  input_mouse
scw_r482:
    ld   [KBD_NOW], ac          ; Esc (key 0; 0 = down)
    and  1, ac
    beq  nm_x
    ld   [dead], ac
    bne  nm_x
    ld   LINK_LO, x             ; CALL nv_keys
    ld   scw_r483, [x]
    ld   LINK_HI, x
    ld   scw_r483 >> 8, [x]
    ld   nv_keys >> 8, y
    jmp  nv_keys
scw_r483:
    ld   LINK_LO, x             ; CALL nv_spt
    ld   scw_r484, [x]
    ld   LINK_HI, x
    ld   scw_r484 >> 8, [x]
    ld   nv_spt >> 8, y
    jmp  nv_spt
scw_r484:
    ld   FL_PG, y               ; C: FL_GO 2, the docking screen next
    ld   FL_GO, x
    ld   [y,x], ac
    bne  nm_x
    ld   LINK_LO, x             ; CALL game_tick
    ld   scw_r485, [x]
    ld   LINK_HI, x
    ld   scw_r485 >> 8, [x]
    ld   game_tick >> 8, y
    jmp  game_tick
scw_r485:
    ld   [dirty], ac            ; the message's time and row (update_panel,
    and  0xFE, ac               ; not the ship's panel)
    ld   ac, [dirty]
    ld   LINK_LO, x             ; CALL update_panel
    ld   scw_r486, [x]
    ld   LINK_HI, x
    ld   scw_r486 >> 8, [x]
    ld   update_panel >> 8, y
    jmp  update_panel
scw_r486:
    ld   FL_PG, y
    ld   NV_T, x
    ld   [y,x], ac
    inc
    and  15, ac
    ld   ac, [y,x]
    xor  4, ac                  ; frame 4: the status row (on its own:
    bne  nm_8                   ; a frame is not enough for it and more)
    ld   LINK_LO, x             ; CALL nv_stat
    ld   scw_r487, [x]
    ld   LINK_HI, x
    ld   scw_r487 >> 8, [x]
    ld   nv_stat >> 8, y
    jmp  nv_stat
scw_r487:
    bra  nm_l
nm_8:
    ld   [y,x], ac
    and  7, ac
    bne  nm_l
    ld   LINK_LO, x             ; CALL nv_draw
    ld   scw_r488, [x]
    ld   LINK_HI, x
    ld   scw_r488 >> 8, [x]
    ld   nv_draw >> 8, y
    jmp  nv_draw
scw_r488:
    ld   FL_PG, y
    ld   NV_T, x
    ld   [y,x], ac
    bne  nm_l
    ld   LINK_LO, x             ; CALL nv_panel
    ld   scw_r489, [x]
    ld   LINK_HI, x
    ld   scw_r489 >> 8, [x]
    ld   nv_panel >> 8, y
    jmp  nv_panel
scw_r489:
    bra  nm_l
nm_x:
    ld   LINK_LO, x             ; CALL pt_hide
    ld   scw_r490, [x]
    ld   LINK_HI, x
    ld   scw_r490 >> 8, [x]
    ld   pt_hide >> 8, y
    jmp  pt_hide
scw_r490:
    ld   nv_exit >> 8, y
    jmp  nv_exit

; nv_pick - a left click (input_mouse's while FL_NAV): the object nearest
; the pointer (within 6 art pixels across, 12 down) is the target
nv_bg:
    ld   FL_PG, y
    ld   NV_GX, x
    ld   [u0], ac
    add  [y,x], ac
    ld   ac, [u3]
    ld   NV_GY, x
    ld   [u1], ac
    add  [y,x], ac
    ld   ac, [u4]
    ld   [u3], ac
    and  63, ac
    bne  bg_h
    ld   [u4], ac
    and  3, ac
    beq  bg_g
bg_h:
    ld   [u4], ac
    and  63, ac
    bne  bg_0
    ld   [u3], ac
    and  3, ac
    beq  bg_g
bg_0:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
bg_g:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_gl - the grid's dots in color AC (0: off) at NV_GX, NV_GY (nv_bg's)

#overlay2 0x4300
nv_keys:
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
    ld   scw_r496, [x]
    ld   LINK_HI, x
    ld   scw_r496 >> 8, [x]
    ld   l_pad_read >> 8, y
    jmp  l_pad_read
scw_r496:
    ld   LINK_LO, x             ; CALL read_dirs
    ld   scw_r497, [x]
    ld   LINK_HI, x
    ld   scw_r497 >> 8, [x]
    ld   read_dirs >> 8, y
    jmp  read_dirs
scw_r497:
    ld   FL_PG, y               ; docked: no thrust, no turning
    ld   FL_DOCK, x
    ld   [y,x], ac
    bne  nk_k
    ld   LINK_LO, x             ; CALL nv_thr
    ld   scw_r498, [x]
    ld   LINK_HI, x
    ld   scw_r498 >> 8, [x]
    ld   nv_thr >> 8, y
    jmp  nv_thr
scw_r498:
    ld   FL_PG, y
    ld   [dirs], ac
    and  12, ac
    beq  nk_k
    ld   FL_STP, x              ; Left / Right: the spin up (not past
    ld   0x00, [y,x]            ; NAV_SPIN either way)
    ld   FL_SPN, x
    ld   [dirs], ac
    and  4, ac
    beq  nk_r
    ld   [y,x], ac
    xor  (0 - NAV_SPIN) & 0xFF, ac
    beq  nk_k
    ld   [y,x], ac
    dec
    bra  nk_h
nk_r:
    ld   [y,x], ac
    xor  NAV_SPIN, ac
    beq  nk_k
    ld   [y,x], ac
    inc
nk_h:
    ld   ac, [y,x]
nk_k:
    ld   LINK_LO, x             ; CALL l_kbd_getc
    ld   scw_r499, [x]
    ld   LINK_HI, x
    ld   scw_r499 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
scw_r499:
    beq  nk_e
    or   0x20, ac
    ld   ac, [key]
    xor  0x2D, ac               ; -: out
    bne  nk_p
    ld   FL_PG, y
    ld   FL_ZM, x
    ld   [y,x], ac
    xor  7, ac
    beq  nk_e
    ld   [y,x], ac
    inc
    bra  nk_z
nk_p:
    xor  0x2D ^ 0x2B, ac        ; +
    beq  nk_in
    xor  0x2B ^ 0x3D, ac        ; = (+ without shift)
    bne  nk_o
nk_in:
    ld   FL_PG, y
    ld   FL_ZM, x
    ld   [y,x], ac
    beq  nk_e
    dec
nk_z:
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL nv_draw
    ld   scw_r500, [x]
    ld   LINK_HI, x
    ld   scw_r500 >> 8, [x]
    ld   nv_draw >> 8, y
    jmp  nv_draw
scw_r500:
    ld   LINK_LO, x             ; CALL nv_panel
    ld   scw_r501, [x]
    ld   LINK_HI, x
    ld   scw_r501 >> 8, [x]
    ld   nv_panel >> 8, y
    jmp  nv_panel
scw_r501:
    ld   sc_leave >> 8, y
    jmp  sc_leave
nk_o:
    ld   nv_keys2 >> 8, y
    jmp  nv_keys2
nk_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_keys2 - Tab, C.  The rest of nv_keys
NV_SHP:
SH_AST:                         ; an asterisk: a derelict not visited
    #d8 9, 0, 0, 0xFF, 0, 1, 0, 0, 0xFF, 0, 1, 0xFF, 0xFF, 1, 0xFF, 0xFF, 1, 1, 1
SH_DIA:                         ; a diamond: visited
    #d8 8, 0, 0xFE, 1, 0xFF, 2, 0, 1, 1, 0, 2, 0xFF, 1, 0xFE, 0, 0xFF, 0xFF
SH_SEL:                         ; the target's corners
    #d8 12, 0xFB, 0xFB, 0xFC, 0xFB, 0xFB, 0xFC, 0xFB, 5, 0xFC, 5, 0xFB, 4
    #d8 5, 0xFB, 4, 0xFB, 5, 0xFC, 5, 5, 4, 5, 5, 4

; nv_circ - a station: a circle of its size (E_R >> NV_ZS pixels across,
; 3 at least, 63 at most) round v0, v1, 32 points (nv_vert), teal; then
; nv_osel.  The rest of nv_obj

#overlay2 0x4400
nv_tug:
    ld   FL_PG, y
    ld   FL_HD, x
    ld   [y,x], ac
    ld   ac, [v4]               ; the heading
    and  7, ac
    ld   ac, [v3]               ; its step in the quarter
    sub  5, ac
    bcc  tu_m
    ld   0x00, ac
    ld   ac, [v7]               ; 0-4: as stored
    ld   [v3], ac
    bra  tu_s
tu_m:
    ld   1, ac
    ld   ac, [v7]               ; 5-7: 8 - step, x and y swapped
    ld   [v3], ac
    xor  0xFF, ac
    add  9, ac
tu_s:
    add  NV_TS & 0xFF, x
    ld   NV_TS >> 8, y
    ld   [y,x], ac
    ld   ac, [v6]               ; its rows
    ld   0xFC, ac
    ld   ac, [v3]               ; from y = -4
tu_r:
    ld   NV_TS >> 8, y
    ld   [v6], x
    ld   [y,x], ac
    beq  tu_d
    and  15, ac
    ld   ac, [w3]               ; a row: its length,
    ld   [y,x], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    sub  4, ac
    ld   ac, [w2]               ;   its first x (x + 4 in the high nibble)
tu_l:
    ld   [w2], ac
    ld   ac, [v0]
    ld   [v3], ac
    ld   ac, [v1]
    ld   [v7], ac
    beq  tu_n
    ld   [v1], ac               ; swapped: (x, y) to (y, x)
    ld   ac, [v2]
    ld   [v0], ac
    ld   ac, [v1]
    ld   [v2], ac
    ld   ac, [v0]
tu_n:
    ld   [v4], ac
    shr  ac
    shr  ac
    shr  ac
    and  3, ac
    ld   ac, [v5]               ; quarter turns: (x, y) to (-y, x)
tu_q:
    ld   [v5], ac
    beq  tu_p
    dec
    ld   ac, [v5]
    ld   [v1], ac
    xor  0xFF, ac
    inc
    ld   ac, [v2]
    ld   [v0], ac
    ld   ac, [v1]
    ld   [v2], ac
    ld   ac, [v0]
    bra  tu_q
tu_p:
    ld   [v0], ac
    add  128, ac
    ld   ac, [u0]
    ld   [v1], ac
    add  92, ac
    ld   ac, [u1]
    ld   3, ac
    ld   ac, [u2]
    ld   LINK_LO, x             ; CALL nv_put
    ld   scw_r532, [x]
    ld   LINK_HI, x
    ld   scw_r532 >> 8, [x]
    ld   nv_put >> 8, y
    jmp  nv_put
scw_r532:
    ld   [w2], ac
    inc
    ld   ac, [w2]
    ld   [w3], ac
    dec
    ld   ac, [w3]
    bne  tu_l
    ld   [v3], ac
    inc
    ld   ac, [v3]
    ld   [v6], ac
    inc
    ld   ac, [v6]
    bra  tu_r
tu_d:
    ld   nv_drift >> 8, y
    jmp  nv_drift

; the tug's shapes, steps 0-4 (tug_32_big.py: about 9 tall, 11 long, a
; notch in the back): a byte a row from y = -4 down, x + 4 in the high
; nibble, the length in the low; 0 the end
nv_spin:
    ld   FL_PG, y
    ld   FL_SPN, x
    ld   [y,x], ac
    ld   ac, [u0]
    ld   FL_STP, x
    ld   [y,x], ac
    beq  sp_m
    ld   [u0], ac
    beq  sp_0
    blt  sp_up
    dec
    bra  sp_w
sp_up:
    inc
sp_w:
    ld   ac, [u0]
    ld   FL_SPN, x
    ld   ac, [y,x]
    bra  sp_m
sp_0:
    ld   0x00, [y,x]            ; stopped
sp_m:
    ld   FL_HF, x
    ld   [y,x], ac
    add  [u0], ac
    ld   ac, [y,x]
    ld   FL_HD, x
    ld   [u0], ac
    blt  spn_n
    bcc  sp_no                  ; spinning right: a carry, a step on
    ld   [y,x], ac
    inc
    bra  sp_h
spn_n:
    bcs  sp_no                  ; left: no carry, a step back
    ld   [y,x], ac
    dec
sp_h:
    and  31, ac
    ld   ac, [y,x]
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sp_no:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; nv_put - map pixel u0, u1 in color u2 (off the view: nothing), kept in
; the hidden screen bytes (255 at most) to rub out.  A leaf (nv_plot's).

#overlay2 0x4500
nav_main:
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
    ld   SEC_K, ac              ; the sector's objects into x5400
    ld   LINK_LO, x             ; CALL prt_load
    ld   scw_r471, [x]
    ld   LINK_HI, x
    ld   scw_r471 >> 8, [x]
    ld   prt_load >> 8, y
    jmp  prt_load
scw_r471:
    ld   s_nv3f & 0xFF, ac      ; then SCRAP.NV3 into the file system's
    ld   ac, [R0]               ; buffer (no card reads after it while the
    ld   s_nv3f >> 8, ac        ; screen is up)
    ld   ac, [R1]
    ld   NAV3_LO >> 8, ac
    ld   ac, [u5]
    ld   1, ac
    ld   ac, [u6]
    ld   LINK_LO, x             ; CALL swap_fetch
    ld   scw_r472, [x]
    ld   LINK_HI, x
    ld   scw_r472 >> 8, [x]
    ld   swap_fetch >> 8, y
    jmp  swap_fetch
scw_r472:
    ld   0x4D, y                ; (no FAT sector in the buffer now: FS_VARS
    ld   0x2F, x                ; V_FATC + 3)
    ld   0xFF, [y,x]
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   1, [y,x]
    ld   NV_N, x
    ld   0x00, [y,x]
    ld   NV_SEL, x
    ld   0x00, [y,x]
    ld   NV_GX, x
    ld   0xFF, [y,x]
    ld   FL_GO, x
    ld   0x00, [y,x]
    ld   32, ac                 ; the view black: even offsets 32 up,
    ld   LINK_LO, x             ; then the odd ones (the panel too: drawn next)
    ld   scw_r473, [x]
    ld   LINK_HI, x
    ld   scw_r473 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r473:
    ld   1, ac
    ld   LINK_LO, x             ; CALL clear_rows
    ld   scw_r474, [x]
    ld   LINK_HI, x
    ld   scw_r474 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r474:
    ld   LINK_LO, x             ; the spin while the map was away
    ld   scw_r475, [x]
    ld   LINK_HI, x
    ld   scw_r475 >> 8, [x]
    ld   nv_spt >> 8, y
    jmp  nv_spt
scw_r475:
    ld   LINK_LO, x             ; CALL nv_modes
    ld   scw_r476, [x]
    ld   LINK_HI, x
    ld   scw_r476 >> 8, [x]
    ld   nv_modes >> 8, y
    jmp  nv_modes
scw_r476:
    ld   LINK_LO, x             ; CALL nv_draw
    ld   scw_r477, [x]
    ld   LINK_HI, x
    ld   scw_r477 >> 8, [x]
    ld   nv_draw >> 8, y
    jmp  nv_draw
scw_r477:
    ld   LINK_LO, x             ; CALL nv_panel
    ld   scw_r478, [x]
    ld   LINK_HI, x
    ld   scw_r478 >> 8, [x]
    ld   nv_panel >> 8, y
    jmp  nv_panel
scw_r478:
    ld   nv_loop >> 8, y
    jmp  nv_loop
s_nv3f:                         ; (in nav_main's chunk: not in SCRAP.NV3)
    #d "SCRAP.NV3", 0x00

; nv_loop - a frame of the screen.  The rest of nav_main
nv_dot:
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
    ld   ac, [v4]
    ld   FL_PG, y
    ld   NV_RS, x
    ld   0x00, [y,x]
    ld   NV_RS + 1, x
    ld   0x00, [y,x]
    ld   FL_VX + 2, ac
    ld   LINK_LO, x             ; CALL nv_mt
    ld   scw_r589, [x]
    ld   LINK_HI, x
    ld   scw_r589 >> 8, [x]
    ld   nv_mt >> 8, y
    jmp  nv_mt
scw_r589:
    ld   [v4], ac
    add  24, ac
    ld   ac, [v4]
    ld   FL_VY + 2, ac
    ld   LINK_LO, x             ; CALL nv_mt
    ld   scw_r590, [x]
    ld   LINK_HI, x
    ld   scw_r590 >> 8, [x]
    ld   nv_mt >> 8, y
    jmp  nv_mt
scw_r590:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_mt - NV_RS += the 2 bytes at FL_PG + AC (signed) x cos v4 (COS32:
; 127 is 1) / 128
NV_TAN:
    #d8 25, 78, 137, 210


; ============================================================
; the control panel: rows 24-27 three boxed blocks with inverse titles
; (FLIGHT, PROPULSION, TARGET), each label with its unit and its value
; to the right; row 28 the keys as inverse caps; row 29 the message
; ============================================================

; nv_panel - the panel again: the labels (NV_LAB: row, column, string in
; NV_STR's page), then nv_pn1
nv_pn4:
    ld   FL_PG, y
    ld   E_R, x
    ld   [w0], ac
    sub  [y,x], ac
    ld   ac, [w0]
    ld   E_R + 1, x
    ld   [w1], ac
    bcc  p4_1
    dec
p4_1:
    sub  [y,x], ac
    ld   ac, [w1]
    blt  p4_0
    bra  p4_2
p4_0:
    clr  ac
    ld   ac, [w0]
    ld   ac, [w1]
p4_2:
    ld   [w0], ac
    ld   ac, [num_l]
    ld   NV_RG, x
    ld   ac, [y,x]
    ld   [w1], ac
    ld   ac, [num_h]
    ld   NV_RG + 1, x
    ld   ac, [y,x]
    ld   26, ac
    ld   ac, [CUR_ROW]
    ld   47, ac
    ld   LINK_LO, x             ; CALL nv_dec
    ld   scw_r568, [x]
    ld   LINK_HI, x
    ld   scw_r568 >> 8, [x]
    ld   nv_dec >> 8, y
    jmp  nv_dec
scw_r568:
    ld   62, ac                 ; the radar return: its radar factor (size
    ld   ac, [CUR_COL]          ; x 100 / 16) / (range / 256), 99 at most
    ld   FL_PG, y
    ld   NV_RG + 1, x
    ld   [y,x], ac
    beq  p4_99
    ld   ac, [R2]
    ld   E_RF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   E_RF + 1, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r569, [x]
    ld   LINK_HI, x
    ld   scw_r569 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r569:
    ld   [R1], ac
    bne  p4_99
    ld   [R0], ac
    sub  100, ac
    bcc  p4_99
    ld   [R0], ac
    bra  p4_p
p4_99:
    ld   99, ac
p4_p:
    ld   LINK_LO, x             ; CALL put_dec8
    ld   scw_r570, [x]
    ld   LINK_HI, x
    ld   scw_r570 >> 8, [x]
    ld   put_dec8 >> 8, y
    jmp  put_dec8
scw_r570:
    ld   66, ac
    ld   ac, [CUR_COL]
    ld   FL_PG, y
    ld   NV_SEL, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_bit
    ld   scw_r571, [x]
    ld   LINK_HI, x
    ld   scw_r571 >> 8, [x]
    ld   nv_bit >> 8, y
    jmp  nv_bit
scw_r571:
    ld   ac, [u6]
    ld   FL_PG, y
    ld   FL_VIS, x
    ld   [y,x], ac
    and  [u6], ac
    beq  p4_n
    ld   s_vis & 0xFF, ac
    bra  p4_v
p4_n:
    ld   s_nvis & 0xFF, ac
p4_v:
    ld   LINK_LO, x             ; CALL nv_s
    ld   scw_r572, [x]
    ld   LINK_HI, x
    ld   scw_r572 >> 8, [x]
    ld   nv_s >> 8, y
    jmp  nv_s
scw_r572:
    ld   nv_pn5 >> 8, y
    jmp  nv_pn5

; nv_pn5 - the tug's speed toward the target (along its bearing from the
; tug: under 0 moving away) and across it.  The rest of nv_panel
nv_plot:
    ld   [u0], ac
    shr  ac
    and  0x7E, ac
    add  0x71, ac
    ld   ac, [u4]
    ld   [u1], ac
    sub  104, ac
    blt  pl_lo
    ld   [u1], ac
    shl
    sub  207, ac
    bra  pl_go
pl_lo:
    ld   [u1], ac
    shl
    add  48, ac
pl_go:
    ld   ac, [u5]
    ld   [u2], ac
    ld   ac, [u6]
    ld   [u0], ac
    and  3, ac
pl_s:
    ld   ac, [u3]               ; u6 the color moved up to its pixel
    beq  pl_w
    ld   [u6], ac
    shl
    shl
    ld   ac, [u6]
    ld   [u3], ac
    dec
    bra  pl_s
pl_w:
    ld   NV_PM >> 8, y          ; the other pixels' mask
    ld   [u0], ac
    and  3, ac
    add  NV_PM & 0xFF, x
    ld   [y,x], ac
    ld   [u4], y
    ld   [u5], x
    and  [y,x], ac
    or   [u6], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; the masks that keep the other three pixels of a byte
NV_PM:
    #d8 0xFC, 0xF3, 0xCF, 0x3F




; nv_px - AC = the x pixel of the 2 bytes at FL_PG + AC (metres from the
; tug, signed) >> NV_ZS + u7, from the middle (128), or xFF when off the
; view.  nv_py - the y pixel (92).  A leaf.
nv_strow:
    clr  ac
    ld   ac, [CUR_ROW]
    ld   ac, [CUR_COL]
    ld   ac, [p_inv]
sr_c:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r606, [x]
    ld   LINK_HI, x
    ld   scw_r606 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r606:
    ld   [CUR_COL], ac
    xor  80, ac
    bne  sr_c
    ld   1, ac
    ld   ac, [CUR_COL]
    clr  ac
    ld   ac, [v0]
sr_l:
    ld   NV_QT >> 8, y
    ld   [v0], ac
    add  NV_QT & 0xFF, x
    ld   [y,x], ac
    beq  sr_e
    ld   ac, [v1]
    ld   [v0], ac
    add  (NV_QT & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [v2]
    ld   [v0], ac
    add  2, ac
    ld   ac, [v0]
    ld   [v1], ac
    xor  1, ac
    bne  sr_n
    ld   [v2], ac
    ld   LINK_LO, x             ; CALL nv_s
    ld   scw_r607, [x]
    ld   LINK_HI, x
    ld   scw_r607 >> 8, [x]
    ld   nv_s >> 8, y
    jmp  nv_s
scw_r607:
    bra  sr_l
sr_n:
    ld   FL_PG, y
    ld   [v2], x
    ld   [y,x], ac
    ld   ac, [num_l]
    clr  ac
    ld   ac, [num_h]
    ld   [v1], ac
    xor  2, ac
    beq  sr_2
    ld   [v2], ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [num_h]
    bra  sr_d
sr_2:
    ld   [num_l], ac
    sub  10, ac
    bcc  sr_d
    ld   0x30, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r608, [x]
    ld   LINK_HI, x
    ld   scw_r608 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r608:
sr_d:
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r609, [x]
    ld   LINK_HI, x
    ld   scw_r609 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r609:
    bra  sr_l
sr_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
NV_QT:
    #d8 2, NV_QMO, 1, s_q0 & 0xFF, 2, NV_QD, 1, s_q1 & 0xFF, 2, NV_QH
    #d8 1, s_q2 & 0xFF, 2, NV_QMI, 1, s_q2 & 0xFF, 2, NV_QS
    #d8 1, s_q3 & 0xFF, 3, NV_QL
    #d8 1, s_q5 & 0xFF, 3, NV_QDV, 1, s_q6 & 0xFF, 3, NV_QB, 0

; nv_dv - w2:w1:w0 /= AC (w2:w1 / AC under 256 x AC), the remainder in w3
nv_shape:
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
    ld   ac, [v6]
    ld   NV_SHP >> 8, y
    ld   [v6], x
    ld   [y,x], ac
    ld   ac, [v5]
ns_l:
    ld   [v6], ac
    inc
    ld   ac, [v6]
    ld   ac, x
    ld   NV_SHP >> 8, y
    ld   [y,x], ac
    add  [v0], ac
    ld   ac, [u0]
    ld   [v6], ac
    inc
    ld   ac, [v6]
    ld   ac, x
    ld   [y,x], ac
    add  [v1], ac
    ld   ac, [u1]
    ld   LINK_LO, x             ; CALL nv_put
    ld   scw_r523, [x]
    ld   LINK_HI, x
    ld   scw_r523 >> 8, [x]
    ld   nv_put >> 8, y
    jmp  nv_put
scw_r523:
    ld   [v5], ac
    dec
    ld   ac, [v5]
    bne  ns_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; the shapes: a count, then x, y pairs (pixels are square)

#overlay2 0x4800
nv_obj:
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
    ld   FL_PG, y
    ld   NV_I, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_ent
    ld   scw_r517, [x]
    ld   LINK_HI, x
    ld   scw_r517 >> 8, [x]
    ld   nv_ent >> 8, y
    jmp  nv_ent
scw_r517:
    clr  ac
    ld   ac, [u7]
    ld   NV_DL, ac
    ld   LINK_LO, x             ; CALL nv_px
    ld   scw_r518, [x]
    ld   LINK_HI, x
    ld   scw_r518 >> 8, [x]
    ld   nv_px >> 8, y
    jmp  nv_px
scw_r518:
    ld   ac, [v0]
    ld   NV_DL + 2, ac
    ld   LINK_LO, x             ; CALL nv_py
    ld   scw_r519, [x]
    ld   LINK_HI, x
    ld   scw_r519 >> 8, [x]
    ld   nv_py >> 8, y
    jmp  nv_py
scw_r519:
    ld   ac, [v1]
    ld   FL_PG, y
    ld   NV_I, x
    ld   [y,x], ac
    add  NV_OX, x
    ld   [v0], ac
    ld   ac, [y,x]
    ld   NV_I, x
    ld   [y,x], ac
    add  NV_OY, x
    ld   [v1], ac
    ld   ac, [y,x]
    ld   [v0], ac
    xor  0xFF, ac
    beq  no_e
    ld   [v1], ac
    xor  0xFF, ac
    beq  no_e
    ld   E_SH, x
    ld   [y,x], ac
    bne  no_d
    ld   nv_circ >> 8, y
    jmp  nv_circ
no_d:
    ld   NV_I, x                ; visited: a diamond
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_bit
    ld   scw_r520, [x]
    ld   LINK_HI, x
    ld   scw_r520 >> 8, [x]
    ld   nv_bit >> 8, y
    jmp  nv_bit
scw_r520:
    ld   ac, [u6]
    ld   FL_PG, y
    ld   FL_VIS, x
    ld   [y,x], ac
    and  [u6], ac
    beq  no_a
    ld   SH_DIA & 0xFF, ac
    bra  no_s
no_a:
    ld   SH_AST & 0xFF, ac
no_s:
    ld   ac, [u6]
    ld   2, ac                  ; gold
    ld   ac, [u2]
    ld   [u6], ac
    ld   LINK_LO, x             ; CALL nv_shape
    ld   scw_r521, [x]
    ld   LINK_HI, x
    ld   scw_r521 >> 8, [x]
    ld   nv_shape >> 8, y
    jmp  nv_shape
scw_r521:
    ld   nv_osel >> 8, y
    jmp  nv_osel
no_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_osel - the target: yellow corners round it.  The end of nv_obj
nv_dv:
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
    ld   ac, [R2]
    ld   [w2], ac
    ld   ac, [R1]
    ld   [w1], ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r610, [x]
    ld   LINK_HI, x
    ld   scw_r610 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r610:
    ld   ac, [w3]               ; the remainder
    ld   [R1], ac               ; w2:w1 = the quotient
    ld   ac, [w2]
    ld   [R0], ac
    ld   ac, [w1]
    ld   [w3], ac               ; then the remainder:w0
    ld   ac, [R1]
    ld   [w0], ac
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r611, [x]
    ld   LINK_HI, x
    ld   scw_r611 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r611:
    ld   ac, [w3]
    ld   [R0], ac
    ld   ac, [w0]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_plot - map pixel u0, u1 in color u2 (2 bpp: 0-3): byte column 8 +
; u0 / 4 (page x71 + (u0 >> 1) & x7E), line pair u1 + 8 (under the status
; row: offset 2 u1 + 48, or 2 u1 - 207 from 104), bits 2 (u0 & 3) up (the
; first pixel the low bits).  A leaf.

#overlay2 0x4900
nv_pick:
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
    ld   scw_r491, [x]
    ld   LINK_HI, x
    ld   scw_r491 >> 8, [x]
    ld   in_view >> 8, y
    jmp  in_view
scw_r491:
    beq  pk_e
    ld   LINK_LO, x             ; u1 m_y / 2 (less 8: the map's y), u2
    ld   scw_r492, [x]
    ld   LINK_HI, x
    ld   scw_r492 >> 8, [x]
    ld   pt_xy >> 8, y
    jmp  pt_xy
scw_r492:
    ld   [u1], ac               ; m_x / 4: u0 the x (m_x / 2 - 32, to 2
    sub  8, ac                  ; pixels)
    bcs  pk_e
    ld   ac, [u1]
    ld   [u2], ac
    sub  16, ac
    bcs  pk_e
    shl
    bcs  pk_e
    ld   ac, [u0]
    ld   7, ac                  ; u3 the best distance so far, u4 its object
    ld   ac, [u3]
    ld   0xFF, ac
    ld   ac, [u4]
    clr  ac
    ld   ac, [u2]
npk_l:
    ld   LINK_LO, x             ; CALL nv_cnt
    ld   scw_r493, [x]
    ld   LINK_HI, x
    ld   scw_r493 >> 8, [x]
    ld   nv_cnt >> 8, y
    jmp  nv_cnt
scw_r493:
    xor  [u2], ac
    beq  pk_d
    ld   FL_PG, y
    ld   [u2], ac
    add  NV_OX, x
    ld   [y,x], ac
    sub  [u0], ac               ; |the difference| (a borrow: negative)
    bcc  pk_4
    xor  0xFF, ac
    inc
pk_4:
    ld   ac, [u5]
    ld   [u2], ac
    add  NV_OY, x
    ld   [y,x], ac
    sub  [u1], ac
    bcc  pk_5
    xor  0xFF, ac
    inc
pk_5:
    sub  [u5], ac               ; the larger
    bcc  pk_2
    ld   [u5], ac
    bra  pk_3
pk_2:
    add  [u5], ac
pk_3:
    sub  [u3], ac
    bcc  pk_n
    add  [u3], ac
    ld   ac, [u3]
    ld   [u2], ac
    ld   ac, [u4]
pk_n:
    ld   [u2], ac
    inc
    ld   ac, [u2]
    bra  npk_l
pk_d:
    ld   [u4], ac
    xor  0xFF, ac
    beq  pk_e
    ld   [u4], ac
    ld   nv_seln >> 8, y
    jmp  nv_seln
pk_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_thr - this frame's thrust (FL_TH: the offset of its vector): Up
; forward, Down back, Q (key 15) or E (17) sideways (fl_dv's).  A leaf.
nv_stat2:
    ld   [w0], ac               ; v3 the day of the month - 1, v4 the month
    add  6, ac
    ld   ac, [v3]
    ld   5, ac
    ld   ac, [v4]
ms_l:
    ld   NV_ML >> 8, y
    ld   [v4], ac
    add  ((NV_ML & 0xFF) - 5) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [v5]
    ld   [v3], ac
    sub  [v5], ac
    bcs  ms_d
    ld   ac, [v3]
    ld   [v4], ac
    inc
    ld   ac, [v4]
    bra  ms_l
ms_d:
    ld   FL_PG, y
    ld   NV_QMO, x
    ld   [v4], ac
    ld   ac, [y,x]
    ld   NV_QD, x
    ld   [v3], ac
    inc
    ld   ac, [y,x]
    ld   NV_QB, x               ; the batteries
    ld   [n_bat], ac
    ld   ac, [y,x]
    ld   NV_QB + 1, x
    ld   0x00, [y,x]
    ld   FL_FLL, x              ; the nitrogen, litres
    ld   [y,x], ac
    ld   ac, [w0]
    ld   NV_QL, x
    ld   ac, [y,x]
    ld   FL_FLH, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   NV_QL + 1, x
    ld   ac, [y,x]
    ld   nv_stat3 >> 8, y
    jmp  nv_stat3

; the months' days, May to December
NV_ML:
    #d8 31, 30, 31, 31, 30, 31, 30, 31

; nv_stat3 - the delta-v: kg x 40 / (the mass / 5), the mass in 100 kg
; (255 at most after / 5); then the row (NV_QT).  The rest of nv_stat

#overlay2 0x4A00
nv_pn2:
    ld   FL_PG, y
    ld   FL_HD, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   45, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r553, [x]
    ld   LINK_HI, x
    ld   scw_r553 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r553:
    ld   LINK_LO, x             ; CALL nv_q4
    ld   scw_r554, [x]
    ld   LINK_HI, x
    ld   scw_r554 >> 8, [x]
    ld   nv_q4 >> 8, y
    jmp  nv_q4
scw_r554:
    ld   12, ac
    ld   LINK_LO, x             ; CALL nv_dec
    ld   scw_r555, [x]
    ld   LINK_HI, x
    ld   scw_r555 >> 8, [x]
    ld   nv_dec >> 8, y
    jmp  nv_dec
scw_r555:
    ld   26, ac
    ld   ac, [CUR_ROW]
    ld   FL_PG, y
    ld   FL_ML, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   FL_MH, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   10, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r556, [x]
    ld   LINK_HI, x
    ld   scw_r556 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r556:
    ld   [R0], ac
    ld   ac, [num_l]
    ld   [R1], ac
    ld   ac, [num_h]
    ld   31, ac
    ld   LINK_LO, x             ; CALL nv_dec
    ld   scw_r557, [x]
    ld   LINK_HI, x
    ld   scw_r557 >> 8, [x]
    ld   nv_dec >> 8, y
    jmp  nv_dec
scw_r557:
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   [y,x], ac
    beq  p2_f
    ld   s_dkd & 0xFF, ac
    bra  p2_s
p2_f:
    ld   s_free & 0xFF, ac
p2_s:
    ld   LINK_LO, x             ; CALL nv_s
    ld   scw_r558, [x]
    ld   LINK_HI, x
    ld   scw_r558 >> 8, [x]
    ld   nv_s >> 8, y
    jmp  nv_s
scw_r558:
    ld   27, ac
    ld   ac, [CUR_ROW]
    ld   FL_PG, y
    ld   FL_NT, x
    ld   [y,x], ac
    ld   ac, [num_l]
    clr  ac
    ld   ac, [num_h]
    ld   31, ac
    ld   LINK_LO, x             ; CALL nv_dec
    ld   scw_r559, [x]
    ld   LINK_HI, x
    ld   scw_r559 >> 8, [x]
    ld   nv_dec >> 8, y
    jmp  nv_dec
scw_r559:
    ld   nv_pn3 >> 8, y
    jmp  nv_pn3

; nv_pn3 - the target: what it is, its registry; its range (the larger
; of |dx| and |dy|).  The rest of nv_panel
nv_ent:
    shl
    ld   ac, [u5]
    shl
    shl
    add  [u5], ac               ; 10 i
    add  0x10, ac
    ld   ac, [u5]
    clr  ac
    ld   ac, [u6]
ne_l:
    ld   SEC >> 8, y
    ld   [u5], ac
    add  [u6], ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [u7]
    ld   FL_PG, y
    ld   [u6], ac
    add  NV_E, x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   [u6], ac
    inc
    ld   ac, [u6]
    xor  SEC_REC, ac
    bne  ne_l
    ld   E_X, x                 ; dx = its x - the tug's
    ld   [y,x], ac
    ld   FL_PX + 2, x
    sub  [y,x], ac
    ld   NV_DL, x
    ld   ac, [y,x]
    ld   E_X + 1, x
    ld   [y,x], ac
    bcc  ne_1
    dec
ne_1:
    ld   FL_PX + 3, x
    sub  [y,x], ac
    ld   NV_DL + 1, x
    ld   ac, [y,x]
    ld   E_Y, x                 ; dy
    ld   [y,x], ac
    ld   FL_PY + 2, x
    sub  [y,x], ac
    ld   NV_DL + 2, x
    ld   ac, [y,x]
    ld   E_Y + 1, x
    ld   [y,x], ac
    bcc  ne_2
    dec
ne_2:
    ld   FL_PY + 3, x
    sub  [y,x], ac
    ld   NV_DL + 3, x
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_obj - object NV_I: its pixel (NV_OX, NV_OY: for the mouse), a
; circle (a station) or an asterisk (a derelict not visited) or a diamond,
; yellow corners when it is the target

#overlay2 0x4B00
nv_circ:
    ld   FL_PG, y
    ld   E_R, x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   E_R + 1, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   NV_ZS, x
    ld   [y,x], ac
    ld   ac, [v2]
ncs_l:
    ld   [v2], ac
    beq  nc_d
    dec
    ld   ac, [v2]
    ld   LINK_LO, x             ; CALL nv_sh2
    ld   scw_r524, [x]
    ld   LINK_HI, x
    ld   scw_r524 >> 8, [x]
    ld   nv_sh2 >> 8, y
    jmp  nv_sh2
scw_r524:
    bra  ncs_l
nc_d:
    ld   [w1], ac
    bne  nc_b
    ld   [w0], ac
    sub  64, ac
    bcc  nc_b
    ld   [w0], ac
    sub  3, ac
    bcc  nc_r
    ld   3, ac
    bra  nc_v
nc_b:
    ld   63, ac
    bra  nc_v
nc_r:
    ld   [w0], ac
nc_v:
    ld   ac, [v3]
    ld   FL_PG, y
    ld   NV_ANG, x
    ld   0x00, [y,x]
    ld   3, ac
    ld   ac, [u2]
    clr  ac
    ld   ac, [v5]
ncl:
    ld   [v5], ac
    ld   LINK_LO, x             ; CALL nv_vert
    ld   scw_r525, [x]
    ld   LINK_HI, x
    ld   scw_r525 >> 8, [x]
    ld   nv_vert >> 8, y
    jmp  nv_vert
scw_r525:
    ld   [v0], ac
    ld   ac, [u7]
    ld   [u0], ac
    ld   LINK_LO, x             ; CALL nv_addc
    ld   scw_r526, [x]
    ld   LINK_HI, x
    ld   scw_r526 >> 8, [x]
    ld   nv_addc >> 8, y
    jmp  nv_addc
scw_r526:
    ld   ac, [u0]
    ld   [v1], ac
    ld   ac, [u7]
    ld   [u1], ac
    ld   LINK_LO, x             ; CALL nv_addc
    ld   scw_r527, [x]
    ld   LINK_HI, x
    ld   scw_r527 >> 8, [x]
    ld   nv_addc >> 8, y
    jmp  nv_addc
scw_r527:
    ld   ac, [u1]
    ld   LINK_LO, x             ; CALL nv_put
    ld   scw_r528, [x]
    ld   LINK_HI, x
    ld   scw_r528 >> 8, [x]
    ld   nv_put >> 8, y
    jmp  nv_put
scw_r528:
    ld   [v5], ac
    inc
    ld   ac, [v5]
    xor  32, ac
    bne  ncl
    ld   nv_osel >> 8, y
    jmp  nv_osel

; nv_addc - AC = u7 + AC (AC signed), or xFF when that leaves 0-255.
; A leaf.
nv_rub:
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
nr_l:
    ld   FL_PG, y
    ld   NV_N, x
    ld   [y,x], ac
    beq  nr_e
    dec
    ld   ac, [y,x]
    ld   ac, [u3]               ; (nv_put's place for point u3)
    shl
    and  0x1E, ac
    ld   ac, x
    ld   [u3], ac
    shr  ac
    shr  ac
    shr  ac
    and  0x1E, ac
    add  0x61, ac
    ld   ac, y
    ld   [y,x], ac
    ld   ac, [u0]
    ld   [u3], ac
    shr  ac
    shr  ac
    shr  ac
    and  0x1E, ac
    add  0x81, ac
    ld   ac, y
    ld   [y,x], ac
    ld   ac, [u1]
    ld   LINK_LO, x             ; CALL nv_bg
    ld   scw_r505, [x]
    ld   LINK_HI, x
    ld   scw_r505 >> 8, [x]
    ld   nv_bg >> 8, y
    jmp  nv_bg
scw_r505:
    ld   ac, [u2]
    ld   LINK_LO, x             ; CALL nv_plot
    ld   scw_r506, [x]
    ld   LINK_HI, x
    ld   scw_r506 >> 8, [x]
    ld   nv_plot >> 8, y
    jmp  nv_plot
scw_r506:
    bra  nr_l
nr_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_bg - AC = the grid's color at u0, u1 (1, blue), or 0: dotted lines
; where u0 + NV_GX is 0 mod 64 (a dot where u1 + NV_GY is 0 mod 4) and
; where u1 + NV_GY is 0 mod 64 (a dot every 4 across).  A leaf.

#overlay2 0x4C00
nv_pn3:
    ld   25, ac
    ld   ac, [CUR_ROW]
    ld   39, ac
    ld   ac, [CUR_COL]
    ld   FL_PG, y
    ld   E_SH, x
    ld   [y,x], ac
    beq  p3_st
    ld   s_der & 0xFF, ac
    bra  p3_s
p3_st:
    ld   s_stn & 0xFF, ac
p3_s:
    ld   LINK_LO, x             ; CALL nv_s
    ld   scw_r560, [x]
    ld   LINK_HI, x
    ld   scw_r560 >> 8, [x]
    ld   nv_s >> 8, y
    jmp  nv_s
scw_r560:
    ld   FL_PG, y
    ld   E_NM, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_next
    ld   scw_r561, [x]
    ld   LINK_HI, x
    ld   scw_r561 >> 8, [x]
    ld   nv_next >> 8, y
    jmp  nv_next
scw_r561:
    ld   FL_PG, y
    ld   NV_S1, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL nv_next
    ld   scw_r562, [x]
    ld   LINK_HI, x
    ld   scw_r562 >> 8, [x]
    ld   nv_next >> 8, y
    jmp  nv_next
scw_r562:
    ld   LINK_LO, x             ; the kind
    ld   scw_r563, [x]
    ld   LINK_HI, x
    ld   scw_r563 >> 8, [x]
    ld   nv_s55 >> 8, y
    jmp  nv_s55
scw_r563:
    ld   66, ac
    ld   ac, [CUR_COL]
    ld   FL_PG, y
    ld   NV_S1, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; the registry
    ld   scw_r564, [x]
    ld   LINK_HI, x
    ld   scw_r564 >> 8, [x]
    ld   nv_s55 >> 8, y
    jmp  nv_s55
scw_r564:
    ld   NV_DL, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r565, [x]
    ld   LINK_HI, x
    ld   scw_r565 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r565:
    ld   [u0], ac
    ld   ac, [w0]
    ld   [u1], ac
    ld   ac, [w1]
    ld   NV_DL + 2, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r566, [x]
    ld   LINK_HI, x
    ld   scw_r566 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r566:
    ld   LINK_LO, x             ; CALL fl_max
    ld   scw_r567, [x]
    ld   LINK_HI, x
    ld   scw_r567 >> 8, [x]
    ld   fl_max >> 8, y
    jmp  fl_max
scw_r567:
    ld   nv_pn4 >> 8, y
    jmp  nv_pn4

; nv_pn4 - the range less its size (0 at least), the radar return,
; visited.  The rest of nv_panel
nv_pn5:
    ld   27, ac
    ld   ac, [CUR_ROW]
    ld   NV_DL, ac
    ld   ac, [u0]
    ld   NV_DL + 2, ac
    ld   LINK_LO, x             ; CALL nv_atv
    ld   scw_r573, [x]
    ld   LINK_HI, x
    ld   scw_r573 >> 8, [x]
    ld   nv_atv >> 8, y
    jmp  nv_atv
scw_r573:
    ld   50, ac
    ld   ac, [CUR_COL]
    ld   FL_PG, y
    ld   NV_ANG, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL nv_dot
    ld   scw_r574, [x]
    ld   LINK_HI, x
    ld   scw_r574 >> 8, [x]
    ld   nv_dot >> 8, y
    jmp  nv_dot
scw_r574:
    ld   1, ac
    ld   LINK_LO, x             ; CALL nv_spd
    ld   scw_r575, [x]
    ld   LINK_HI, x
    ld   scw_r575 >> 8, [x]
    ld   nv_spd >> 8, y
    jmp  nv_spd
scw_r575:
    ld   68, ac
    ld   ac, [CUR_COL]
    ld   FL_PG, y
    ld   NV_ANG, x
    ld   [y,x], ac
    add  8, ac
    ld   LINK_LO, x             ; CALL nv_dot
    ld   scw_r576, [x]
    ld   LINK_HI, x
    ld   scw_r576 >> 8, [x]
    ld   nv_dot >> 8, y
    jmp  nv_dot
scw_r576:
    clr  ac
    ld   LINK_LO, x             ; CALL nv_spd
    ld   scw_r577, [x]
    ld   LINK_HI, x
    ld   scw_r577 >> 8, [x]
    ld   nv_spd >> 8, y
    jmp  nv_spd
scw_r577:
    ld   nv_pn6 >> 8, y
    jmp  nv_pn6

; nv_pn6 - row 28: the keys as inverse caps (the sector file's s_k0,
; s_k1), the zoom's range in the first; then the message.  The end of
; nv_panel
NV_DRT:
    #d8 9, 0, 12, 0, 15, 0, 0x80

; nv_drift - gold dots 9-15 pixels out the way the tug drifts (when it
; does, 2/256 m a frame or more): NV_DRT in nv_tug's loop.  The end of
; nv_draw (its LEAVE)

#overlay2 0x4E00
nv_drift:
    ld   LINK_LO, x             ; CALL fl_speed
    ld   scw_r539, [x]
    ld   LINK_HI, x
    ld   scw_r539 >> 8, [x]
    ld   fl_speed >> 8, y
    jmp  fl_speed
scw_r539:
    ld   [w1], ac
    bne  ndr_go
    ld   [w0], ac
    sub  2, ac
    bcc  ndr_go
    ld   sc_leave >> 8, y
    jmp  sc_leave
ndr_go:
    ld   FL_VX + 2, ac
    ld   ac, [u0]
    ld   FL_VY + 2, ac
    ld   LINK_LO, x             ; CALL nv_atv
    ld   scw_r540, [x]
    ld   LINK_HI, x
    ld   scw_r540 >> 8, [x]
    ld   nv_atv >> 8, y
    jmp  nv_atv
scw_r540:
    ld   2, ac
    ld   ac, [u2]
    ld   NV_DRT & 0xFF, ac
    ld   ac, [v6]
    ld   tg_l >> 8, y
    jmp  tg_l

; nv_atv - NV_ANG = the angle of (the 2 bytes at FL_PG + u0, those at
; FL_PG + AC): nv_atan of them
nv_exit:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames_io
    ld   scw_r594, [x]
    ld   LINK_HI, x
    ld   scw_r594 >> 8, [x]
    ld   l_wait_frames_io >> 8, y
    jmp  l_wait_frames_io
scw_r594:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   scw_r595, [x]
    ld   LINK_HI, x
    ld   scw_r595 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
scw_r595:
    ld   [dead], ac
    bne  nx_e
    ld   [KBD_NOW], ac
    and  1, ac
    beq  nv_exit
nx_e:
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   0x00, [y,x]
    clr  ac                     ; the message off: its string may be in the
    ld   ac, [msg_t]            ; sector file (part text again from now)
    ld   0x20, ac               ; the ship's view 4 bpp again
    ld   ac, [u2]
    ld   0x06, ac
    ld   view_mode >> 8, y
    jmp  view_mode




; view_mode - AC = the mode byte of the view's lines from u2 (x20 + the
; line) to 383 (x5B9F): x06 the ship (4 bpp), x05 the map (2 bpp).  The
; end of nv_modes and nv_exit (their LEAVE)
NV_TS:
    #d8 TUG_S0 & 0xFF, TUG_S1 & 0xFF, TUG_S2 & 0xFF, TUG_S3 & 0xFF, TUG_S4 & 0xFF
TUG_S0:
    #d8 0x11, 0x13, 0x25, 0x27, 0x38, 0x27, 0x25, 0x13, 0x11, 0x00
TUG_S1:
    #d8 0x21, 0x23, 0x24, 0x35, 0x36, 0x29, 0x17, 0x03, 0x00
TUG_S2:
    #d8 0x22, 0x32, 0x33, 0x43, 0x44, 0x27, 0x0A, 0x00
TUG_S3:
    #d8 0x32, 0x33, 0x33, 0x34, 0x17, 0x08, 0x18, 0x64, 0x00
TUG_S4:
    #d8 0x42, 0x42, 0x42, 0x34, 0x07, 0x08, 0x35, 0x54, 0x72, 0x00

; nv_tg - nv_drift's dots: NV_DRT's points round the tug turned to NV_ANG
; (nv_term).  The end of nv_draw
nv_modes:
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
    ld   0x5A, y
    ld   0x2F, ac
nmd_l:
    ld   ac, x
    ld   0x04, [y,x]
    xor  0x20, ac
    beq  nmd_e
    xor  0x20, ac
    dec
    bra  nmd_l
nmd_e:
    ld   0x30, ac
    ld   ac, [u2]
    ld   0x05, ac
    ld   view_mode >> 8, y
    jmp  view_mode

; nv_draw - the map: the points rubbed out, each object, then the tug
nv_ms:
    ld   [num_l], ac            ; w1:w0 = num >> 4
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [w0]
    ld   [num_h], ac
    shl
    shl
    shl
    shl
    or   [w0], ac
    ld   ac, [w0]
    ld   [num_h], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [w1]
    ld   [num_l], ac
    sub  [w0], ac
    ld   ac, [num_l]
    ld   [num_h], ac
    bcc  nms_0
    dec
nms_0:
    sub  [w1], ac
    ld   ac, [num_h]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; what does not fit: SCRAP.NV2, read in over the actions of each kind and
; the cell art (gen_plc.py --swap 0x3600,0x4000,NV2,2; SCRAP.ART puts them
; back), then SCRAP.NV3 in the file system's buffer (--swap 0x4E00,0x5000,
; NV3,2; nav_main reads it in after its last card read)

; ============================================================
; SCRAP.DCK: the docking and comms screen (scrap_dck.masm), read in when
; C is pressed on the map (#overlay3: gen_plc.py --swap ...,DCK,3, at
; SCRAP.NAV's addresses); what does not fit in SCRAP.DK2 over SCRAP.NV2's
; (--swap 0x3600,0x4000,DK2,3), then SCRAP.DK3 in the file system's buffer
; (--swap 0x4E00,0x5000,DK3,3) and SCRAP.DK4 in the part text's (--swap
; 0x5400,0x5600,DK4,3).  dock_main is a .page chunk: at x4100, in
; SCRAP.DCK (it reads the other three in)
; ============================================================
; ============================================================
; scrap_dck.masm - SCRAPWRIGHT's docking and comms screen: SCRAP.DCK,
; SCRAP.DK2, SCRAP.DK3
; ============================================================
;
; Included at the end of scrap.masm as #overlay3: the region x4100-x4CFF
; (gen_plc.py --swap 0x4100,0x4D00,DCK,3: SCRAP.DCK, over SCRAP.NAV's
; place) and what does not fit in x3600-x3FFF (--swap 0x3600,0x4000,DK2,3:
; SCRAP.DK2, over SCRAP.NV2's), the last of it in the file system's
; buffer (--swap 0x4E00,0x5000,DK3,3: SCRAP.DK3, as SCRAP.NV3), and
; x5400-x55FF, the part text's buffer (--swap 0x5400,0x5600,DK4,3:
; SCRAP.DK4).  C on the
; map screen sets FL_GO 2 and closes it; nav_action (resident) reads
; SCRAP.DCK in and calls dock_main, which reads SCRAP.DK2, DK4 and DK3
; (dock_main must stay in SCRAP.DCK: a .page chunk, placed first, at x4100;
; the test checks), runs the screen until Esc or
; 5 BACK TO THE MAP, and nav_action opens the map again.  The flight
; goes on all the while (game_tick).
;
; The view is 1 bpp (2x lines) while the screen is up, in two boxes.
; DOCKING on the left: the range to the KESTREL 9's port (DOCK_X, DOCK_Y:
; 100 m west of its centre) and the closing speed, the tug's offset from
; the port's line sideways and up / down and their drift speeds, then the
; rings: the tug's (white, thick, a dashed cross through it) fixed in the
; middle, the port's (thin) where the port is: right or left by the
; sideways offset, up or down by the height (a height of its own, DK_Y:
; the sector map is flat), its size by the range (960 / (16 + half
; metres): the tug's ring at 2 m).  It drifts (dk_drift: small random
; pushes, every 16 frames, to the sideways speed and the height's).
; Under the rings CLEAR TO CLAMP flashes when the clamps would hold:
; docking declared, under 3.5 m to go (DK_D2 under 7), 0.75 m or less
; off each way, every speed under 0.7 m/s (3/256 m a frame).
;
; COMMS CONTROL on the right: the target, its port, the status, five
; buttons (a click, or keys 1-5; the one under the mouse in normal video,
; the rest inverse): 1 HAIL (needs a working antenna: N_ANT; the KESTREL
; 9 is a derelict, so no reply), 2 REQUEST DOCKING (hailed: declared),
; 3 REQUEST UNDOCK (docked and hailed: declared), 4 CLAMP (declared and
; clear: docked, fl_dock) or, docked, RELEASE CLAMPS (undock declared:
; 5 m/s west of the port), 5 BACK TO THE MAP.
;
; Keys: W / S forward and back, Q / E sideways, Z / X up and down (the
; height: the same thrust as sideways, the same nitrogen), Left / Right
; (A / D) turn and Up / Down pitch (as the map's spin: 1/256 of a heading
; step a frame more while held, to NAV_SPIN, and it keeps turning), R
; stops the turning, 1-5 the buttons, Esc the map.
;
; The turn comes from the map: the yaw (DK_YW) is the heading (east is
; the port's line), turning at the map's spin; the pitch (DK_PW) starts
; level, turning at half the spin up or down (the map is flat: this is
; its other part).  The port's ring is off the middle by the angles too
; (a 1/256 step an eighth of 1/16 m: a heading step 2 m), so
; the pilot stops the turn and lines up at once; the forward thrust is
; along the heading (fl_dv).  Back on the map the heading and the spin
; are the yaw's.
;
; Date: 11/08/2026
; ============================================================

DK_ST   = 0xD0              ; FL_PG (rooms_build's, free while this is up):
                            ;   bit 0 hailed, 1 docking declared, 2 undocking
DK_T    = 0xD1              ;   frames (the ring every 4, readouts, flashing)
DK_HV   = 0xD2              ;   the button under the mouse (FF none)
DK_DR   = 0xD3              ;   the buttons and the status to draw again: 6 all,
                            ;     one a frame (dk_frame)
DK_Y    = 0xD4              ;   the tug's height off the port's (16.16 m, down +)
DK_VY   = 0xD8              ;   its speed (1/2^24 m a frame)
DK_Z    = 0xDC              ;   4 zero bytes: the thrust vector up / down burns
                            ;   with (FL_TH: fl_tick burns the nitrogen)
DK_D2   = 0xE0              ;   the range in half metres, 0-239 (dk_sim)
DK_X    = 0xE1              ;   the port from the tug sideways, 1/16 m (+-112)
DK_YS   = 0xE2              ;   and up (+-112)
DK_OK   = 0xE3              ;   1: clear to clamp
DK_ON   = 0xE4              ;   1: the port's ring is drawn at DK_OX, DK_OY,
DK_OX   = 0xE5              ;     radius DK_OR (to rub out: XOR)
DK_OY   = 0xE6
DK_OR   = 0xE7
DK_K    = 0xE8              ;   a drift push (2 bytes)
DK_PC   = 0xEA              ;   the pointer drawn: its byte column, bit,
DK_PB   = 0xEB              ;     line pair, 1 while it is drawn
DK_PL   = 0xEC
DK_PO   = 0xED
DK_YR   = 0xEE              ;   the yaw's rate (1/256 steps a frame, signed)
DK_YW   = 0xEF              ;   the yaw: 1/256 steps, then steps (mod 32)
DK_PR   = 0xF1              ;   the pitch's rate
DK_PW   = 0xF2              ;   the pitch (2 bytes, as DK_YW; up +)
DK_RS   = 0xF4              ;   1: R, the turning brought down to 0
DK_RX   = 0xF8              ;   the port's ring off the middle (DK_X, DK_YS and
DK_RY   = 0xF9              ;     the angles: dk_off)
DK_UP   = 0xF6              ;   the thrust up and down (2 bytes each, half
DK_DN   = 0xFA              ;     thrust: bit 1 set, dk_thr)

DK_CX   = 80                ; the rings' middle: x / 2 (2 pixels), line pair
DK_CY   = 104
DK_TR   = 48                ; the tug's ring's radius

; dock_main - SCRAP.DK2 and SCRAP.DK3 in, the screen until Esc (or 5, or
; you die).  At x4100 (.page: placed first), in SCRAP.DCK
nv_sh2:
    ld   [w1], ac
    and  1, ac
    beq  sh_a
    ld   0x80, ac
sh_a:
    ld   ac, [w6]
    ld   [w0], ac
    shr  ac
    or   [w6], ac
    ld   ac, [w0]
    ld   [w1], ac
    shr  ac
    ld   ac, [w1]
    ld   [w3], ac
    and  1, ac
    beq  sh_b
    ld   0x80, ac
sh_b:
    ld   ac, [w6]
    ld   [w2], ac
    shr  ac
    or   [w6], ac
    ld   ac, [w2]
    ld   [w3], ac
    shr  ac
    ld   ac, [w3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_spd - NV_RS (1/256 m a frame, signed) in m/s; a - first
; when it is under 0 and AC is 1 (else its size)
view_mode:
    ld   ac, [u0]
    ld   0x5A, y
    ld   [u2], ac
vwm_1:
    ld   ac, x                  ; (the library's vid_mode, the view only)
    inc
    ld   ac, [u1]
    ld   [u0], ac
    ld   ac, [y,x]
    ld   [u1], ac
    bne  vwm_1
    ld   0x5B, y
    ld   0xA0, ac
vwm_2:
    dec
    ld   ac, x
    ld   ac, [u1]
    ld   [u0], ac
    ld   ac, [y,x]
    ld   [u1], ac
    bne  vwm_2
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_stat - the status row (row 0): the ship's date and time (CLK: seconds
; from 05-07-2175 00:00:00, 08:00:00 at the start), the nitrogen (kg),
; the delta-v it gives (a kg is 20 kN s: kg x 200 / the mass in 100 kg)
; and the working batteries (NV_QT)
nv_osel:
    ld   FL_PG, y               ; the target: yellow corners
    ld   NV_I, x
    ld   [y,x], ac
    ld   ac, [u6]
    ld   NV_SEL, x
    ld   [y,x], ac
    xor  [u6], ac
    bne  os_e
    ld   2, ac
    ld   ac, [u2]
    ld   SH_SEL & 0xFF, ac
    ld   LINK_LO, x             ; CALL nv_shape
    ld   scw_r522, [x]
    ld   LINK_HI, x
    ld   scw_r522 >> 8, [x]
    ld   nv_shape >> 8, y
    jmp  nv_shape
scw_r522:
os_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_bit - AC = 1 << AC.  A leaf.
nv_seln:
    ld   FL_PG, y
    ld   NV_SEL, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL nv_draw
    ld   scw_r494, [x]
    ld   LINK_HI, x
    ld   scw_r494 >> 8, [x]
    ld   nv_draw >> 8, y
    jmp  nv_draw
scw_r494:
    ld   LINK_LO, x             ; CALL nv_panel
    ld   scw_r495, [x]
    ld   LINK_HI, x
    ld   scw_r495 >> 8, [x]
    ld   nv_panel >> 8, y
    jmp  nv_panel
scw_r495:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; nv_keys - thrust while Up / Down is held, the spin up while Left /
; Right is (neither while docked), + - Tab C R
nv_bit:
    ld   ac, [u6]
    ld   1, ac
nb2_l:
    ld   ac, [u7]
    ld   [u6], ac
    beq  nb2_e
    dec
    ld   ac, [u6]
    ld   [u7], ac
    shl
    bra  nb2_l
nb2_e:
    ld   [u7], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_shape - the shape whose low byte (in NV_SHP's page) is AC round v0,
; v1 in color u2: its count, then x, y offsets (signed)
nv_next:
    ld   ac, [u0]
nx2_l:
    ld   SEC_STR, y
    ld   [u0], x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    ld   [u1], ac
    bne  nx2_l
    ld   [u0], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_box - the blocks' sides (bit 7: the pixel glyphs leave blank) of
; columns 0, 18, 19, 37, 38 and 78 down rows 25-27 (line pairs 8-31:
; offsets 177-223), then a line under row 27 (offset 223) but in the gaps
; between the blocks.  A leaf.
nv_addc:
    blt  ad_n
    add  [u7], ac
    bcs  ad_f
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ad_n:
    add  [u7], ac
    bcc  ad_f
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ad_f:
    ld   0xFF, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; nv_cm - AC = cos (NV_ANG + AC) x v3 / 128 (signed: 127 is 1)

#overlay3 0x3600
dk_pxr:
    clr  ac
    ld   ac, [u1]
pr_l:
    ld   DK_AR >> 8, y
    ld   [u1], ac
    add  DK_AR & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u2]
    clr  ac
    ld   ac, [u3]
    ld   FL_PG, y
    ld   DK_PB, x
    ld   [y,x], ac
    ld   ac, [u4]
pr_s:
    ld   [u4], ac
    beq  pr_d
    dec
    ld   ac, [u4]
    ld   [u3], ac
    shl
    ld   ac, [u3]
    ld   [u2], ac
    shl
    ld   ac, [u2]
    bcc  pr_s
    ld   [u3], ac
    or   1, ac
    ld   ac, [u3]
    bra  pr_s
pr_d:
    ld   DK_PL, x
    ld   [y,x], ac
    add  [u1], ac
    ld   ac, [u0]
    sub  240, ac
    bcc  dpr_e
    ld   [u0], ac
    sub  112, ac
    bcs  dpr_lo
    ld   [u0], ac
    shl
    sub  223, ac
    bra  pr_o
dpr_lo:
    ld   [u0], ac
    shl
    add  32, ac
pr_o:
    ld   ac, [u0]
    ld   DK_PC, x
    ld   [y,x], ac
    shl
    add  0x61, ac
    ld   ac, [u4]
    ld   [u4], y
    ld   [u0], x
    ld   [y,x], ac
    xor  [u2], ac
    ld   ac, [y,x]
    ld   [u4], ac
    xor  0xFF, ac
    beq  dpr_n
    ld   [u4], ac
    add  2, ac
    ld   ac, y
    ld   [y,x], ac
    xor  [u3], ac
    ld   ac, [y,x]
dpr_n:
    ld   [u1], ac
    inc
    ld   ac, [u1]
    xor  7, ac
    bne  pr_l
dpr_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
DK_AR:
    #d8 0x01, 0x03, 0x07, 0x0F, 0x1F, 0x07, 0x0D

; dk_scr - the screen: black, lines 0-383 1 bpp, the boxes, the text, the
; tug's ring; the buttons on the next frame that draws them (DK_DR)
dk_scr:
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
    ld   32, ac
    ld   LINK_LO, x             ; CALL clear_rows
    ld   scw_r704, [x]
    ld   LINK_HI, x
    ld   scw_r704 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r704:
    ld   1, ac
    ld   LINK_LO, x             ; CALL clear_rows
    ld   scw_r705, [x]
    ld   LINK_HI, x
    ld   scw_r705 >> 8, [x]
    ld   clear_rows >> 8, y
    jmp  clear_rows
scw_r705:
    ld   0x5A, y                ; the mode bytes x5A20 + the line
    ld   0x20, ac
    ld   ac, [u0]
dsc_1:
    ld   [u0], x
    ld   0x04, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    bne  dsc_1
    ld   0x5B, y
dsc_2:
    ld   [u0], x
    ld   0x04, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  0xA0, ac
    bne  dsc_2
    ld   LINK_LO, x             ; CALL dk_box
    ld   scw_r706, [x]
    ld   LINK_HI, x
    ld   scw_r706 >> 8, [x]
    ld   dk_box >> 8, y
    jmp  dk_box
scw_r706:
    ld   LINK_LO, x             ; CALL dk_labs
    ld   scw_r707, [x]
    ld   LINK_HI, x
    ld   scw_r707 >> 8, [x]
    ld   dk_labs >> 8, y
    jmp  dk_labs
scw_r707:
    ld   LINK_LO, x             ; CALL dk_tug
    ld   scw_r708, [x]
    ld   LINK_HI, x
    ld   scw_r708 >> 8, [x]
    ld   dk_tug >> 8, y
    jmp  dk_tug
scw_r708:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_box - the two boxes' lines: across at line pairs 4 and 187 (offsets
; 40, 151) but column 40, down columns 0, 39, 41 and 79 (their outer
; pixel).  A leaf.
s_l0:
    #d " DOCKING ", 0x00
s_l1:
    #d " COMMS CONTROL ", 0x00
s_l2:
    #d "RANGE M", 0x00
s_l3:
    #d "CLOSE M/S", 0x00
s_l4:
    #d "SIDE M", 0x00
s_l5:
    #d "DRIFT M/S", 0x00
s_l6:
    #d "UP M", 0x00
s_l7:
    #d "TARGET  KESTREL 9, A DERELICT", 0x00
s_l8:
    #d "PORT    1, ON ITS WEST SIDE", 0x00
s_l9:
    #d "STATUS", 0x00

s_s1:
    #d "NOT HAILED              ", 0x00
s_s2:
    #d "HAILED: NO REPLY        ", 0x00
s_s3:
    #d "DOCKING DECLARED        ", 0x00
s_s4:
    #d "CLAMPED TO PORT 1       ", 0x00
s_s5:
    #d "CLAMPED, UNDOCK DECLARED", 0x00

dk_circ:
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
    ld   ac, [v1]               ; v1 x, v2 y, v3 the error
    ld   [u7], ac
    ld   ac, [v2]
    ld   1, ac
    sub  [u7], ac
    ld   ac, [v3]
dc_l:
    ld   [v2], ac
    sub  [v1], ac
    bcs  dc_e
    ld   [v1], ac
    ld   ac, [v4]
    ld   [v2], ac
    ld   ac, [v5]
    ld   LINK_LO, x             ; CALL dk_c4
    ld   scw_r696, [x]
    ld   LINK_HI, x
    ld   scw_r696 >> 8, [x]
    ld   dk_c4 >> 8, y
    jmp  dk_c4
scw_r696:
    ld   [v1], ac
    xor  [v2], ac
    beq  dc_s
    ld   [v2], ac
    ld   ac, [v4]
    ld   [v1], ac
    ld   ac, [v5]
    ld   LINK_LO, x             ; CALL dk_c4
    ld   scw_r697, [x]
    ld   LINK_HI, x
    ld   scw_r697 >> 8, [x]
    ld   dk_c4 >> 8, y
    jmp  dk_c4
scw_r697:
dc_s:
    ld   [v3], ac
    blt  dci_n
    ld   [v1], ac
    sub  [v2], ac
    shl
    add  5, ac
    add  [v3], ac
    ld   ac, [v3]
    ld   [v2], ac
    dec
    ld   ac, [v2]
    bra  dc_x
dci_n:
    ld   [v1], ac
    shl
    add  3, ac
    add  [v3], ac
    ld   ac, [v3]
dc_x:
    ld   [v1], ac
    inc
    ld   ac, [v1]
    bra  dc_l
dc_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_c4 - the points +-v4, +-v5 from the middle (each once).  dk_c2 -
; +-v4, AC
dk_rate2:
    ld   [w3], ac
    sub  16, ac
    bcc  rt_x
    ld   [w2], ac
    ld   ac, [R0]
    ld   75, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r735, [x]
    ld   LINK_HI, x
    ld   scw_r735 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r735:
    ld   [R2], ac
    ld   ac, [w0]
    ld   [R3], ac
    ld   ac, [w1]
    ld   [w3], ac
    ld   ac, [R0]
    ld   75, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r736, [x]
    ld   LINK_HI, x
    ld   scw_r736 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r736:
    ld   [R2], ac
    add  [w1], ac
    ld   ac, [R1]
    ld   [w0], ac
    ld   ac, [R0]
    ld   5, ac
    ld   ac, [w4]
rt_s:
    ld   LINK_LO, x             ; CALL shr16
    ld   scw_r737, [x]
    ld   LINK_HI, x
    ld   scw_r737 >> 8, [x]
    ld   shr16 >> 8, y
    jmp  shr16
scw_r737:
    ld   [w4], ac
    dec
    ld   ac, [w4]
    bne  rt_s
    ld   [R0], ac
    ld   ac, [w0]
    ld   [R1], ac
    ld   ac, [w1]
    bra  rt_d
rt_x:
    ld   0x0F, ac               ; 9999
    ld   ac, [w0]
    ld   0x27, ac
    ld   ac, [w1]
rt_d:
    ld   [v6], ac
    ld   LINK_LO, x             ; CALL dk_pt
    ld   scw_r738, [x]
    ld   LINK_HI, x
    ld   scw_r738 >> 8, [x]
    ld   dk_pt >> 8, y
    jmp  dk_pt
scw_r738:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_dist - w3:w0 (metres, 16.16) to a tenth from column v6 (its sign
; xor v7): w2 x 10 + w1 x 10 / 256 under 256 m, else 999.9

#overlay3 0x3900
dk_ring2:
    ld   FL_PG, y
    ld   DK_ON, x
    ld   [y,x], ac
    beq  dr_n
    ld   DK_OX, x
    ld   [y,x], ac
    xor  [u5], ac
    bne  dr_c
    ld   DK_OY, x
    ld   [y,x], ac
    xor  [u6], ac
    bne  dr_c
    ld   DK_OR, x
    ld   [y,x], ac
    xor  [u7], ac
    bne  dr_c
    ld   sc_leave >> 8, y
    jmp  sc_leave
dr_c:
    ld   [u5], ac
    ld   ac, [w4]
    ld   [u6], ac
    ld   ac, [w5]
    ld   [u7], ac
    ld   ac, [w6]
    ld   DK_OX, x
    ld   [y,x], ac
    ld   ac, [u5]
    ld   DK_OY, x
    ld   [y,x], ac
    ld   ac, [u6]
    ld   DK_OR, x
    ld   [y,x], ac
    ld   ac, [u7]
    ld   4, ac
    ld   ac, [v0]
    ld   LINK_LO, x             ; CALL dk_circ
    ld   scw_r694, [x]
    ld   LINK_HI, x
    ld   scw_r694 >> 8, [x]
    ld   dk_circ >> 8, y
    jmp  dk_circ
scw_r694:
    ld   [w4], ac
    ld   ac, [u5]
    ld   [w5], ac
    ld   ac, [u6]
    ld   [w6], ac
    ld   ac, [u7]
dr_n:
    ld   FL_PG, y
    ld   DK_ON, x
    ld   1, [y,x]
    ld   DK_OX, x
    ld   [u5], ac
    ld   ac, [y,x]
    ld   DK_OY, x
    ld   [u6], ac
    ld   ac, [y,x]
    ld   DK_OR, x
    ld   [u7], ac
    ld   ac, [y,x]
    ld   4, ac
    ld   ac, [v0]
    ld   LINK_LO, x             ; CALL dk_circ
    ld   scw_r695, [x]
    ld   LINK_HI, x
    ld   scw_r695 >> 8, [x]
    ld   dk_circ >> 8, y
    jmp  dk_circ
scw_r695:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_circ - a circle round u5, u6 (x / 2, line pair), radius u7 (60 at
; most), XOR (dk_px; v0 0 thick, 4 thin): the midpoint way, 8 points a
; step (a point twice: drawn and rubbed out, so not twice)
dk_dist:
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
    ld   LINK_LO, x             ; CALL dk_sabs
    ld   scw_r739, [x]
    ld   LINK_HI, x
    ld   scw_r739 >> 8, [x]
    ld   dk_sabs >> 8, y
    jmp  dk_sabs
scw_r739:
    ld   [w3], ac
    bne  di_x
    ld   [w1], ac
    ld   ac, [R0]
    ld   10, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r740, [x]
    ld   LINK_HI, x
    ld   scw_r740 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r740:
    ld   [R3], ac
    ld   ac, [u3]
    ld   [w2], ac
    ld   ac, [R0]
    ld   10, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL l_mul8
    ld   scw_r741, [x]
    ld   LINK_HI, x
    ld   scw_r741 >> 8, [x]
    ld   l_mul8 >> 8, y
    jmp  l_mul8
scw_r741:
    ld   [R2], ac
    add  [u3], ac
    ld   ac, [w0]
    ld   [R3], ac
    bcc  di_c
    inc
di_c:
    ld   ac, [w1]
    bra  di_d
di_x:
    ld   0x0F, ac
    ld   ac, [w0]
    ld   0x27, ac
    ld   ac, [w1]
di_d:
    ld   [v6], ac
    ld   LINK_LO, x             ; CALL dk_pt
    ld   scw_r742, [x]
    ld   LINK_HI, x
    ld   scw_r742 >> 8, [x]
    ld   dk_pt >> 8, y
    jmp  dk_pt
scw_r742:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_pt - w1:w0 tenths from column AC (u7 its sign: 80 -), two spaces
; after.  dk_pint - w1:w0 whole

#overlay3 0x3A00
dk_flash:
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
    ld   ac, [CUR_ROW]
    ld   11, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL dk_dkd
    ld   scw_r719, [x]
    ld   LINK_HI, x
    ld   scw_r719 >> 8, [x]
    ld   dk_dkd >> 8, y
    jmp  dk_dkd
scw_r719:
    beq  fl_1
    ld   0x80, ac
    ld   ac, [p_inv]
    ld   s_dko & 0xFF, ac
    bra  fl_s
fl_1:
    ld   FL_PG, y
    ld   DK_OK, x
    ld   [y,x], ac
    beq  fl_b
    ld   DK_DR, x
    ld   6, [y,x]
    ld   DK_T, x
    ld   [y,x], ac
    and  16, ac
    shl
    shl
    shl
    ld   ac, [p_inv]
    ld   s_ctc & 0xFF, ac
    bra  fl_s
fl_b:
    ld   s_blk & 0xFF, ac
fl_s:
    ld   ac, [R0]
    ld   s_ctc >> 8, ac         ; (the three share a page: one chunk)
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r720, [x]
    ld   LINK_HI, x
    ld   scw_r720 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r720:
    clr  ac
    ld   ac, [p_inv]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_read - the readouts, rows 1-3: the range (metres) and the closing
; speed, the tug sideways (right +) and its drift, up and its drift
dk_rate:
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
    ld   LINK_LO, x             ; CALL dk_ld4
    ld   scw_r731, [x]
    ld   LINK_HI, x
    ld   scw_r731 >> 8, [x]
    ld   dk_ld4 >> 8, y
    jmp  dk_ld4
scw_r731:
    ld   LINK_LO, x             ; CALL dk_sabs
    ld   scw_r732, [x]
    ld   LINK_HI, x
    ld   scw_r732 >> 8, [x]
    ld   dk_sabs >> 8, y
    jmp  dk_sabs
scw_r732:
    ld   [w3], ac
    bne  rt_b
    ld   [w1], ac
    ld   ac, [R0]
    ld   [w2], ac
    ld   ac, [R1]
    ld   109, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r733, [x]
    ld   LINK_HI, x
    ld   scw_r733 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r733:
    ld   [R0], ac
    ld   ac, [w0]
    ld   [R1], ac
    ld   ac, [w1]
    ld   [v6], ac
    ld   LINK_LO, x             ; CALL dk_pt
    ld   scw_r734, [x]
    ld   LINK_HI, x
    ld   scw_r734 >> 8, [x]
    ld   dk_pt >> 8, y
    jmp  dk_pt
scw_r734:
    ld   sc_leave >> 8, y
    jmp  sc_leave
rt_b:
    ld   dk_rate2 >> 8, y
    jmp  dk_rate2

; dk_rate2 - 1 m a frame or more.  The rest of dk_rate
dk_hail:
    ld   N_ANT >> 8, y
    ld   N_ANT & 0xFF, x
    ld   [y,x], ac
    bne  dha_ok
    ld   s_nant & 0xFF, ac
    ld   ac, [R0]
    ld   s_nant >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg
dha_ok:
    ld   1, ac
    ld   LINK_LO, x             ; CALL dk_set
    ld   scw_r651, [x]
    ld   LINK_HI, x
    ld   scw_r651 >> 8, [x]
    ld   dk_set >> 8, y
    jmp  dk_set
scw_r651:
    ld   s_hail & 0xFF, ac
    ld   ac, [R0]
    ld   s_hail >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg

; dk_set - DK_ST |= AC.  A leaf.
dk_dkd:
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_rqd - 2 REQUEST DOCKING: not docked, hailed: declared.  The rest of
; dk_btn
s_rqd:
    #d "DOCKING DECLARED: PORT 1.", 0x00
s_rqu:
    #d "UNDOCKING DECLARED: RELEASE CLAMPS.", 0x00
s_lock:
    #d "CLAMPS LOCKED: REQUEST UNDOCK.", 0x00

dk_init:
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   2, [y,x]
    ld   DK_ST, ac
    ld   ac, [u0]
dki_l:
    ld   [u0], x
    ld   0x00, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    bne  dki_l                  ; (to FL_GO, xFF)
    ld   DK_HV, x
    ld   0xFF, [y,x]
    ld   DK_DR, x
    ld   6, [y,x]
    ld   FL_DOCK, x
    ld   [y,x], ac
    bne  dki_d
    ld   LINK_LO, x             ; CALL l_rand8
    ld   scw_r615, [x]
    ld   LINK_HI, x
    ld   scw_r615 >> 8, [x]
    ld   l_rand8 >> 8, y
    jmp  l_rand8
scw_r615:
    and  15, ac
    sub  8, ac
    ld   FL_PG, y
    ld   DK_Y + 2, x
    ld   ac, [y,x]
    blt  dki_n
    bra  dki_d
dki_n:
    ld   DK_Y + 3, x
    ld   0xFF, [y,x]
dki_d:
    ld   LINK_LO, x             ; CALL dk_turn
    ld   scw_r616, [x]
    ld   LINK_HI, x
    ld   scw_r616 >> 8, [x]
    ld   dk_turn >> 8, y
    jmp  dk_turn
scw_r616:
    ld   LINK_LO, x             ; CALL dk_scr
    ld   scw_r617, [x]
    ld   LINK_HI, x
    ld   scw_r617 >> 8, [x]
    ld   dk_scr >> 8, y
    jmp  dk_scr
scw_r617:
    ld   dk_loop >> 8, y
    jmp  dk_loop

; dk_loop - a frame: the pointer, the keys and the mouse, the flight,
; the message, then this frame's part of the screen.  The rest of
; dock_main
dk_c2:
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
    add  [u6], ac
    ld   ac, [u1]
    ld   [v4], ac
    add  [u5], ac
    ld   ac, [u0]
    ld   LINK_LO, x             ; CALL dk_px
    ld   scw_r700, [x]
    ld   LINK_HI, x
    ld   scw_r700 >> 8, [x]
    ld   dk_px >> 8, y
    jmp  dk_px
scw_r700:
    ld   [v4], ac
    beq  c2_e
    ld   [u5], ac
    sub  [v4], ac
    ld   ac, [u0]
    ld   LINK_LO, x             ; CALL dk_px
    ld   scw_r701, [x]
    ld   LINK_HI, x
    ld   scw_r701 >> 8, [x]
    ld   dk_px >> 8, y
    jmp  dk_px
scw_r701:
c2_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_px - XOR the 2 pixels u0 (x / 2) at line pair u1, both (v0 0) or the
; left one (v0 4), inside the rings' box (u0 2-157, line pairs 34-174).
; A leaf; u3, u4.

#overlay3 0x3C00
s_h0:
    #d "HAIL, THEN DECLARE DOCKING.", 0x00
s_h1:
    #d "STOP TURNING, LINE THE RINGS UP", 0x00
s_h2:
    #d "UNDER 3.5 M AND 0.7 M/S: CLAMP", 0x00

dk_read2:
    clr  ac
    ld   ac, [v7]
    ld   30, ac
    ld   ac, [v6]
    ld   FL_VY, ac
    ld   LINK_LO, x             ; CALL dk_rate
    ld   scw_r727, [x]
    ld   LINK_HI, x
    ld   scw_r727 >> 8, [x]
    ld   dk_rate >> 8, y
    jmp  dk_rate
scw_r727:
    ld   3, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [u5]
    ld   ac, [u6]
    ld   DK_Y, ac
    ld   LINK_LO, x             ; CALL dk_diff
    ld   scw_r728, [x]
    ld   LINK_HI, x
    ld   scw_r728 >> 8, [x]
    ld   dk_diff >> 8, y
    jmp  dk_diff
scw_r728:
    clr  ac
    ld   ac, [v7]
    ld   10, ac
    ld   ac, [v6]
    ld   LINK_LO, x             ; CALL dk_dist
    ld   scw_r729, [x]
    ld   LINK_HI, x
    ld   scw_r729 >> 8, [x]
    ld   dk_dist >> 8, y
    jmp  dk_dist
scw_r729:
    ld   0x80, ac
    ld   ac, [v7]
    ld   30, ac
    ld   ac, [v6]
    ld   DK_VY, ac
    ld   LINK_LO, x             ; CALL dk_rate
    ld   scw_r730, [x]
    ld   LINK_HI, x
    ld   scw_r730 >> 8, [x]
    ld   dk_rate >> 8, y
    jmp  dk_rate
scw_r730:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_sabs - u7 = the sign of w3:w0 (80 negative) xor v7, w3:w0 = its
; size.  A leaf (dk_neg inline).
dk_hov:
    ld   [m_ok], ac
    beq  dh_n
    ld   [m_yl], ac             ; the text row: m_y / 16
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u0]
    ld   [m_yh], ac
    shl
    shl
    shl
    shl
    or   [u0], ac
    sub  7, ac
    bcs  dh_n
    ld   ac, [u0]
    and  1, ac
    bne  dh_n
    ld   [u0], ac
    sub  9, ac
    bcc  dh_n
    ld   [m_xl], ac             ; the column: m_x / 8
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u1]
    ld   [m_xh], ac
    shl
    shl
    shl
    shl
    shl
    or   [u1], ac
    sub  43, ac
    bcs  dh_n
    sub  22, ac
    bcc  dh_n
    ld   [u0], ac
    shr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
dh_n:
    ld   0xFF, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_pick - a left click (input_mouse's while FL_NAV is 2): the button
; under the mouse

#overlay3 0x3D00
dk_pint:
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
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL dk_sgn
    ld   scw_r748, [x]
    ld   LINK_HI, x
    ld   scw_r748 >> 8, [x]
    ld   dk_sgn >> 8, y
    jmp  dk_sgn
scw_r748:
    ld   [w0], ac
    ld   ac, [num_l]
    ld   [w1], ac
    ld   ac, [num_h]
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r749, [x]
    ld   LINK_HI, x
    ld   scw_r749 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r749:
dk_pad:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r750, [x]
    ld   LINK_HI, x
    ld   scw_r750 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r750:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r751, [x]
    ld   LINK_HI, x
    ld   scw_r751 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r751:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_sgn - a space (w1:w0 0), + or - (u7).
dk_ring:
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
    ld   0xC0, ac
    ld   ac, [R0]
    ld   0x03, ac
    ld   ac, [R1]
    ld   FL_PG, y
    ld   DK_D2, x
    ld   [y,x], ac
    add  16, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r693, [x]
    ld   LINK_HI, x
    ld   scw_r693 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r693:
    ld   [R0], ac
    ld   ac, [u7]
    sub  2, ac
    bcc  dr_1
    ld   2, ac
    ld   ac, [u7]
dr_1:
    ld   FL_PG, y
    ld   DK_RX, x
    ld   [y,x], ac
    add  DK_CX, ac
    ld   ac, [u5]
    ld   FL_PG, y
    ld   DK_RY, x
    ld   [y,x], ac
    add  DK_CY, ac
    ld   ac, [u6]
    ld   dk_ring2 >> 8, y
    jmp  dk_ring2

; dk_ring2 - the same ring: nothing; else the old one rubbed out, the new
; one drawn.  The rest of dk_ring
dk_px:
    ld   [u0], ac
    sub  2, ac
    bcs  px_e
    ld   [u0], ac
    sub  158, ac
    bcc  px_e
    ld   [u1], ac
    sub  34, ac
    bcs  px_e
    ld   [u1], ac
    sub  175, ac
    bcc  px_e
    ld   DK_MK >> 8, y
    ld   [u0], ac
    and  3, ac
    add  [v0], ac
    add  DK_MK & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u3]
    ld   [u1], ac
    sub  112, ac
    bcs  px_l
    ld   [u1], ac
    shl
    sub  223, ac
    bra  px_o
px_l:
    ld   [u1], ac
    shl
    add  32, ac
px_o:
    ld   ac, [u4]
    ld   [u0], ac               ; byte column u0 / 4: page x61 + (u0 >> 1) & x7E
    shr  ac
    and  0x7E, ac
    add  0x61, ac
    ld   ac, y
    ld   [u4], x
    ld   [y,x], ac
    xor  [u3], ac
    ld   ac, [y,x]
px_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
DK_MK:                          ; (1 bpp: pixel i bit i)
    #d8 0x03, 0x0C, 0x30, 0xC0, 0x01, 0x04, 0x10, 0x40

; dk_pon - the pointer drawn (XOR) at the mouse: its byte column, bit
; and line pair kept.  dk_poff - rubbed out

#overlay3 0x3E00
dk_rots:
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
    ld   DK_YR, ac
    ld   LINK_LO, x             ; CALL dk_rot
    ld   scw_r646, [x]
    ld   LINK_HI, x
    ld   scw_r646 >> 8, [x]
    ld   dk_rot >> 8, y
    jmp  dk_rot
scw_r646:
    ld   DK_PR, ac
    ld   LINK_LO, x             ; CALL dk_rot
    ld   scw_r647, [x]
    ld   LINK_HI, x
    ld   scw_r647 >> 8, [x]
    ld   dk_rot >> 8, y
    jmp  dk_rot
scw_r647:
    ld   FL_PG, y
    ld   DK_YW + 1, x
    ld   [y,x], ac
    and  31, ac
    ld   ac, [u0]
    ld   FL_HD, x
    xor  [y,x], ac
    beq  drs_e
    ld   [u0], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL fl_dv
    ld   scw_r648, [x]
    ld   LINK_HI, x
    ld   scw_r648 >> 8, [x]
    ld   fl_dv >> 8, y
    jmp  fl_dv
scw_r648:
drs_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_rot - the rate at FL_PG + AC: R's stop (1 nearer 0), then into the
; angle in the 2 bytes after it.  A leaf.
dk_keys:
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
    ld   scw_r642, [x]
    ld   LINK_HI, x
    ld   scw_r642 >> 8, [x]
    ld   l_kbd_getc >> 8, y
    jmp  l_kbd_getc
scw_r642:
    beq  kk_t
    ld   ac, [u0]
    or   0x20, ac
    xor  0x72, ac               ; r: the turning stopped
    bne  kk_d
    ld   FL_PG, y
    ld   DK_RS, x
    ld   1, [y,x]
    bra  kk_t
kk_d:
    ld   [u0], ac
    sub  0x31, ac               ; 1-5
    bcs  kk_t
    ld   ac, [u0]
    sub  5, ac
    bcc  kk_t
    ld   [u0], ac
    ld   LINK_LO, x             ; CALL dk_btn
    ld   scw_r643, [x]
    ld   LINK_HI, x
    ld   scw_r643 >> 8, [x]
    ld   dk_btn >> 8, y
    jmp  dk_btn
scw_r643:
kk_t:
    ld   dk_thr >> 8, y
    jmp  dk_thr

; dk_thr - undocked: the first key of DK_KT held (0 = down) is this
; frame's thrust: forward, back, sideways (FL_TH: fl_tick's), or up /
; down (DK_VY, while there is nitrogen; FL_TH DK_Z burns it).  The rest
; of dk_keys
dk_box:
    ld   0x61, ac
    ld   ac, [u0]
bxh_l:
    ld   [u0], ac
    xor  0x61 + 80, ac
    beq  bxh_n
    ld   [u0], y
    ld   40, x
    ld   0xFF, [y,x]
    ld   151, x
    ld   0xFF, [y,x]
bxh_n:
    ld   [u0], ac
    add  2, ac
    ld   ac, [u0]
    xor  0x01, ac
    bne  bxh_l
    ld   40, ac
    ld   ac, [u1]
bxv_l:
    ld   [u1], x
    ld   0x61, y
    ld   [y,x], ac
    or   0x01, ac
    ld   ac, [y,x]
    ld   0x61 + 78, y
    ld   [y,x], ac
    or   0x80, ac
    ld   ac, [y,x]
    ld   0x61 + 82, y
    ld   [y,x], ac
    or   0x01, ac
    ld   ac, [y,x]
    ld   0xFF, y
    ld   [y,x], ac
    or   0x80, ac
    ld   ac, [y,x]
    ld   [u1], ac
    add  2, ac
    bcc  bxv_s
    ld   1, ac
bxv_s:
    ld   ac, [u1]
    xor  153, ac
    bne  bxv_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_tug - the tug's ring (thick) and a dashed cross through the middle
dk_set:
    ld   ac, [u0]
    ld   FL_PG, y
    ld   DK_ST, x
    ld   [y,x], ac
    or   [u0], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_st - AC = DK_ST & AC.  A leaf.

#overlay3 0x3F00
dk_rqd:
    ld   LINK_LO, x             ; CALL dk_dkd
    ld   scw_r652, [x]
    ld   LINK_HI, x
    ld   scw_r652 >> 8, [x]
    ld   dk_dkd >> 8, y
    jmp  dk_dkd
scw_r652:
    beq  drq_1
    ld   s_adk & 0xFF, ac
    ld   ac, [R0]
    ld   s_adk >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg
drq_1:
    ld   1, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r653, [x]
    ld   LINK_HI, x
    ld   scw_r653 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r653:
    bne  rq_2
    ld   dk_hlf >> 8, y
    jmp  dk_hlf
rq_2:
    ld   2, ac
    ld   LINK_LO, x             ; CALL dk_set
    ld   scw_r654, [x]
    ld   LINK_HI, x
    ld   scw_r654 >> 8, [x]
    ld   dk_set >> 8, y
    jmp  dk_set
scw_r654:
    ld   s_rqd & 0xFF, ac
    ld   ac, [R0]
    ld   s_rqd >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg

; dk_rqu - 3 REQUEST UNDOCK: docked, hailed: declared.  The rest of
; dk_btn
dk_rqu:
    ld   LINK_LO, x             ; CALL dk_dkd
    ld   scw_r655, [x]
    ld   LINK_HI, x
    ld   scw_r655 >> 8, [x]
    ld   dk_dkd >> 8, y
    jmp  dk_dkd
scw_r655:
    bne  ru_1
    ld   s_ndk & 0xFF, ac
    ld   ac, [R0]
    ld   s_ndk >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg
ru_1:
    ld   1, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r656, [x]
    ld   LINK_HI, x
    ld   scw_r656 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r656:
    bne  ru_2
    ld   dk_hlf >> 8, y
    jmp  dk_hlf
ru_2:
    ld   4, ac
    ld   LINK_LO, x             ; CALL dk_set
    ld   scw_r657, [x]
    ld   LINK_HI, x
    ld   scw_r657 >> 8, [x]
    ld   dk_set >> 8, y
    jmp  dk_set
scw_r657:
    ld   s_rqu & 0xFF, ac
    ld   ac, [R0]
    ld   s_rqu >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg

; dk_hlf - HAIL FIRST.  dk_msg - the message R1 (AC): R0, the buttons and
; the status again.  The end of dk_btn (its LEAVE)
dk_drift:
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
    ld   LINK_LO, x             ; CALL dk_dkd
    ld   scw_r668, [x]
    ld   LINK_HI, x
    ld   scw_r668 >> 8, [x]
    ld   dk_dkd >> 8, y
    jmp  dk_dkd
scw_r668:
    bne  dd_e
    ld   DK_VY, ac
    ld   LINK_LO, x             ; CALL dk_kick
    ld   scw_r669, [x]
    ld   LINK_HI, x
    ld   scw_r669 >> 8, [x]
    ld   dk_kick >> 8, y
    jmp  dk_kick
scw_r669:
    ld   FL_VY, ac
    ld   LINK_LO, x             ; CALL dk_kick
    ld   scw_r670, [x]
    ld   LINK_HI, x
    ld   scw_r670 >> 8, [x]
    ld   dk_kick >> 8, y
    jmp  dk_kick
scw_r670:
dd_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_kick - a random -8192 to 8128 (1/2^24 m a frame) into the 4 bytes
; at FL_PG + AC
dk_exit:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames_io
    ld   scw_r627, [x]
    ld   LINK_HI, x
    ld   scw_r627 >> 8, [x]
    ld   l_wait_frames_io >> 8, y
    jmp  l_wait_frames_io
scw_r627:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   scw_r628, [x]
    ld   LINK_HI, x
    ld   scw_r628 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
scw_r628:
    ld   [dead], ac
    bne  dx_e
    ld   [KBD_NOW], ac
    and  1, ac
    beq  dk_exit
dx_e:
    ld   FL_PG, y
    ld   FL_NAV, x
    ld   0x00, [y,x]
    ld   FL_GO, x
    ld   0x00, [y,x]
    clr  ac
    ld   ac, [msg_t]
    ld   dk_back >> 8, y
    jmp  dk_back

; dk_back - the map's heading and spin from the yaw (the frame counter
; now: nv_spt goes on from here).  The end of dock_main (its LEAVE)

#overlay3 0x4100
dock_main:
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
    ld   s_dk2f & 0xFF, ac
    ld   ac, [R0]
    ld   s_dk2f >> 8, ac
    ld   ac, [R1]
    ld   NAV2_LO >> 8, ac
    ld   ac, [u5]
    ld   5, ac
    ld   ac, [u6]
    ld   LINK_LO, x             ; CALL swap_fetch
    ld   scw_r612, [x]
    ld   LINK_HI, x
    ld   scw_r612 >> 8, [x]
    ld   swap_fetch >> 8, y
    jmp  swap_fetch
scw_r612:
    bne  dm_e
    ld   s_dk4f & 0xFF, ac      ; SCRAP.DK4 into x5400 (the part text's
    ld   ac, [R0]               ; buffer: the map reads its own in again)
    ld   s_dk4f >> 8, ac
    ld   ac, [R1]
    ld   0x54, ac
    ld   ac, [u5]
    ld   1, ac
    ld   ac, [u6]
    ld   PRT_K >> 8, y          ; (no part text there now: prt_load reads
    ld   PRT_K & 0xFF, x        ; it again)
    ld   0xFF, [y,x]
    ld   LINK_LO, x             ; CALL swap_fetch
    ld   scw_r613, [x]
    ld   LINK_HI, x
    ld   scw_r613 >> 8, [x]
    ld   swap_fetch >> 8, y
    jmp  swap_fetch
scw_r613:
    bne  dm_e
    ld   s_dk3f & 0xFF, ac      ; then SCRAP.DK3 into the file system's
    ld   ac, [R0]               ; buffer (no card reads after it while the
    ld   s_dk3f >> 8, ac        ; screen is up)
    ld   ac, [R1]
    ld   NAV3_LO >> 8, ac
    ld   ac, [u5]
    ld   1, ac
    ld   ac, [u6]
    ld   LINK_LO, x             ; CALL swap_fetch
    ld   scw_r614, [x]
    ld   LINK_HI, x
    ld   scw_r614 >> 8, [x]
    ld   swap_fetch >> 8, y
    jmp  swap_fetch
scw_r614:
    bne  dm_e
    ld   0x4D, y                ; (no FAT sector in the buffer now: FS_VARS
    ld   0x2F, x                ; V_FATC + 3)
    ld   0xFF, [y,x]
    ld   dk_init >> 8, y
    jmp  dk_init
dm_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
s_dk2f:                         ; (in dock_main's chunk: in SCRAP.DCK)
    #d "SCRAP.DK2", 0x00
s_dk3f:
    #d "SCRAP.DK3", 0x00
s_dk4f:
    #d "SCRAP.DK4", 0x00

; dk_init - FL_NAV 2, the state cleared, the height a random -8 to +7 m
; (none docked), the tug pointing east; the screen.  The rest of dock_main
dk_sim:
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
    ld   DOCK_X & 0xFF, ac
    ld   ac, [u5]
    ld   DOCK_X >> 8, ac
    ld   ac, [u6]
    ld   FL_PX, ac
    ld   LINK_LO, x             ; CALL dk_diff
    ld   scw_r675, [x]
    ld   LINK_HI, x
    ld   scw_r675 >> 8, [x]
    ld   dk_diff >> 8, y
    jmp  dk_diff
scw_r675:
    ld   [w3], ac
    bne  sm_f
    ld   [w2], ac
    sub  120, ac
    bcc  sm_b
    ld   [w2], ac
    shl
    ld   ac, [u0]
    ld   [w1], ac
    and  0x80, ac
    beq  sm_h
    ld   [u0], ac
    or   1, ac
    bra  sm_s
sm_h:
    ld   [u0], ac
    bra  sm_s
sm_f:
    xor  0xFF, ac               ; just past the port: 0
    bne  sm_b
    ld   [w2], ac
    xor  0xFF, ac
    beq  sm_s
sm_b:
    ld   239, ac
sm_s:
    ld   FL_PG, y
    ld   DK_D2, x
    ld   ac, [y,x]
    ld   dk_sim2 >> 8, y
    jmp  dk_sim2

; dk_sim2 - the offsets.  The rest of dk_sim
dk_frame:
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
    ld   LINK_LO, x             ; CALL dk_rots
    ld   scw_r633, [x]
    ld   LINK_HI, x
    ld   scw_r633 >> 8, [x]
    ld   dk_rots >> 8, y
    jmp  dk_rots
scw_r633:
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   [y,x], ac
    bne  dkf_h
    ld   DK_VY + 1, ac
    ld   ac, [w1]
    ld   DK_Y, ac
    ld   LINK_LO, x             ; CALL fl_addp
    ld   scw_r634, [x]
    ld   LINK_HI, x
    ld   scw_r634 >> 8, [x]
    ld   fl_addp >> 8, y
    jmp  fl_addp
scw_r634:
dkf_h:
    ld   LINK_LO, x             ; CALL dk_hov
    ld   scw_r635, [x]
    ld   LINK_HI, x
    ld   scw_r635 >> 8, [x]
    ld   dk_hov >> 8, y
    jmp  dk_hov
scw_r635:
    ld   ac, [u0]
    ld   FL_PG, y
    ld   DK_HV, x
    ld   [y,x], ac
    xor  [u0], ac
    beq  dkf_t
    ld   [u0], ac
    ld   ac, [y,x]
    ld   DK_DR, x
    ld   6, [y,x]
dkf_t:
    ld   DK_T, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    and  3, ac
    bne  dkf_1
    ld   [y,x], ac
    and  15, ac
    bne  dkf_s
    ld   LINK_LO, x             ; CALL dk_drift
    ld   scw_r636, [x]
    ld   LINK_HI, x
    ld   scw_r636 >> 8, [x]
    ld   dk_drift >> 8, y
    jmp  dk_drift
scw_r636:
dkf_s:
    ld   LINK_LO, x             ; CALL dk_sim
    ld   scw_r637, [x]
    ld   LINK_HI, x
    ld   scw_r637 >> 8, [x]
    ld   dk_sim >> 8, y
    jmp  dk_sim
scw_r637:
    ld   LINK_LO, x             ; CALL dk_ring
    ld   scw_r638, [x]
    ld   LINK_HI, x
    ld   scw_r638 >> 8, [x]
    ld   dk_ring >> 8, y
    jmp  dk_ring
scw_r638:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dkf_1:
    ld   [y,x], ac
    and  15, ac
    xor  2, ac
    bne  dkf_2
    ld   LINK_LO, x             ; CALL dk_read
    ld   scw_r639, [x]
    ld   LINK_HI, x
    ld   scw_r639 >> 8, [x]
    ld   dk_read >> 8, y
    jmp  dk_read
scw_r639:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dkf_2:
    xor  2 ^ 6, ac
    bne  dkf_3
    ld   LINK_LO, x             ; CALL dk_flash
    ld   scw_r640, [x]
    ld   LINK_HI, x
    ld   scw_r640 >> 8, [x]
    ld   dk_flash >> 8, y
    jmp  dk_flash
scw_r640:
    ld   sc_leave >> 8, y
    jmp  sc_leave
dkf_3:
    ld   DK_DR, x               ; one a frame: the status, buttons 4 to 0
    ld   [y,x], ac
    beq  dkf_e
    dec
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL dk_bts
    ld   scw_r641, [x]
    ld   LINK_HI, x
    ld   scw_r641 >> 8, [x]
    ld   dk_bts >> 8, y
    jmp  dk_bts
scw_r641:
dkf_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_keys - 1-5 the buttons; then the thrust (dk_thr)
dk_poff:
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
    ld   FL_PG, y
    ld   DK_PO, x
    ld   [y,x], ac
    beq  pf_e
    ld   0x00, [y,x]
    ld   LINK_LO, x             ; CALL dk_pxr
    ld   scw_r703, [x]
    ld   LINK_HI, x
    ld   scw_r703 >> 8, [x]
    ld   dk_pxr >> 8, y
    jmp  dk_pxr
scw_r703:
pf_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_pxr - XOR the arrow (DK_AR, 7 line pairs) at DK_PC, DK_PB, DK_PL (no
; line past 479, no byte past column 79).  A leaf; u0-u4.
dk_okc:
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
    ld   LINK_LO, x             ; CALL dk_dkd
    ld   scw_r685, [x]
    ld   LINK_HI, x
    ld   scw_r685 >> 8, [x]
    ld   dk_dkd >> 8, y
    jmp  dk_dkd
scw_r685:
    bne  oc_n
    ld   2, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r686, [x]
    ld   LINK_HI, x
    ld   scw_r686 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r686:
    beq  oc_n
    ld   FL_PG, y               ; (a CALL's return sets y)
    ld   DK_D2, x
    ld   [y,x], ac
    sub  7, ac
    bcc  oc_n
    ld   DK_RX, ac
    ld   LINK_LO, x             ; CALL dk_sm
    ld   scw_r687, [x]
    ld   LINK_HI, x
    ld   scw_r687 >> 8, [x]
    ld   dk_sm >> 8, y
    jmp  dk_sm
scw_r687:
    beq  oc_n
    ld   DK_RY, ac
    ld   LINK_LO, x             ; CALL dk_sm
    ld   scw_r688, [x]
    ld   LINK_HI, x
    ld   scw_r688 >> 8, [x]
    ld   dk_sm >> 8, y
    jmp  dk_sm
scw_r688:
    beq  oc_n
    ld   FL_VX, ac
    ld   LINK_LO, x             ; CALL dk_slow
    ld   scw_r689, [x]
    ld   LINK_HI, x
    ld   scw_r689 >> 8, [x]
    ld   dk_slow >> 8, y
    jmp  dk_slow
scw_r689:
    beq  oc_n
    ld   FL_VY, ac
    ld   LINK_LO, x             ; CALL dk_slow
    ld   scw_r690, [x]
    ld   LINK_HI, x
    ld   scw_r690 >> 8, [x]
    ld   dk_slow >> 8, y
    jmp  dk_slow
scw_r690:
    beq  oc_n
    ld   DK_VY, ac
    ld   LINK_LO, x             ; CALL dk_slow
    ld   scw_r691, [x]
    ld   LINK_HI, x
    ld   scw_r691 >> 8, [x]
    ld   dk_slow >> 8, y
    jmp  dk_slow
scw_r691:
    beq  oc_n
    ld   FL_PG, y               ; not turning
    ld   DK_YR, x
    ld   [y,x], ac
    ld   DK_PR, x
    or   [y,x], ac
    bne  oc_n
    ld   1, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
oc_n:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_sm - AC = 1 when |the byte at FL_PG + AC| is 6 or less (DK_RX, DK_RY:
; half size, 12/16 m).  A leaf.
dk_pon:
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
    beq  po_e
    ld   FL_PG, y
    ld   [m_xl], ac
    and  7, ac
    ld   DK_PB, x
    ld   ac, [y,x]
    ld   [m_xl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [u0]
    ld   [m_xh], ac
    shl
    shl
    shl
    shl
    shl
    or   [u0], ac
    ld   DK_PC, x
    ld   ac, [y,x]
    ld   [m_yl], ac
    shr  ac
    ld   ac, [u0]
    ld   [m_yh], ac
    beq  po_1
    ld   [u0], ac
    or   0x80, ac
    ld   ac, [u0]
po_1:
    ld   [u0], ac
    ld   DK_PL, x
    ld   ac, [y,x]
    ld   DK_PO, x
    ld   1, [y,x]
    ld   LINK_LO, x             ; CALL dk_pxr
    ld   scw_r702, [x]
    ld   LINK_HI, x
    ld   scw_r702 >> 8, [x]
    ld   dk_pxr >> 8, y
    jmp  dk_pxr
scw_r702:
po_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave


#overlay3 0x4400
dk_labs:
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
dl_l:
    ld   DK_LAB >> 8, y
    ld   [v0], ac
    add  DK_LAB & 0xFF, x
    ld   [y,x], ac
    xor  0xFF, ac
    beq  dl_e
    ld   [y,x], ac
    and  0x80, ac
    ld   ac, [p_inv]
    ld   [y,x], ac
    and  0x7F, ac
    ld   ac, [CUR_ROW]
    ld   [v0], ac
    add  (DK_LAB & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [CUR_COL]
    ld   [v0], ac
    add  (DK_LAB & 0xFF) + 2, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [v0], ac
    add  (DK_LAB & 0xFF) + 3, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r712, [x]
    ld   LINK_HI, x
    ld   scw_r712 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r712:
    ld   [v0], ac
    add  4, ac
    ld   ac, [v0]
    bra  dl_l
dl_e:
    clr  ac
    ld   ac, [p_inv]
    ld   sc_leave >> 8, y
    jmp  sc_leave
DK_LAB:
    #d8 0x80, 2, s_l0 & 0xFF, s_l0 >> 8, 0x80, 43, s_l1 & 0xFF, s_l1 >> 8
    #d8 1, 2, s_l2 & 0xFF, s_l2 >> 8, 1, 20, s_l3 & 0xFF, s_l3 >> 8
    #d8 2, 2, s_l4 & 0xFF, s_l4 >> 8, 2, 20, s_l5 & 0xFF, s_l5 >> 8
    #d8 3, 2, s_l6 & 0xFF, s_l6 >> 8, 3, 20, s_l5 & 0xFF, s_l5 >> 8
    #d8 2, 43, s_l7 & 0xFF, s_l7 >> 8, 3, 43, s_l8 & 0xFF, s_l8 >> 8
    #d8 4, 43, s_l9 & 0xFF, s_l9 >> 8
    #d8 17, 43, s_h0 & 0xFF, s_h0 >> 8, 18, 43, s_h1 & 0xFF, s_h1 >> 8
    #d8 19, 43, s_h2 & 0xFF, s_h2 >> 8
    #d8 25, 1, s_dk0 & 0xFF, s_dk0 >> 8, 26, 1, s_dk1 & 0xFF, s_dk1 >> 8
    #d8 0xFF

; dk_bts - button AC (0-4: inverse but the one under the mouse; 4
; flashing while clear to clamp, RELEASE CLAMPS while docked), or 5 the
; status (dk_frame: one a frame, DK_DR counting down from 6)
dk_kick:
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
    ld   LINK_LO, x             ; CALL l_rand8
    ld   scw_r671, [x]
    ld   LINK_HI, x
    ld   scw_r671 >> 8, [x]
    ld   l_rand8 >> 8, y
    jmp  l_rand8
scw_r671:
    ld   ac, [u6]
    shl
    shl
    shl
    shl
    shl
    shl
    ld   FL_PG, y
    ld   DK_K, x
    ld   ac, [y,x]
    ld   [u6], ac
    sub  128, ac
    ld   ac, [u5]
    shr  ac
    shr  ac
    ld   ac, [u4]
    ld   [u5], ac
    blt  kc_n
    ld   [u4], ac
    bra  kc_s
kc_n:
    ld   [u4], ac
    or   0xC0, ac
kc_s:
    ld   FL_PG, y
    ld   DK_K + 1, x
    ld   ac, [y,x]
    ld   DK_K, ac
    ld   ac, [w1]
    ld   [u7], ac
    ld   LINK_LO, x             ; CALL fl_add24
    ld   scw_r672, [x]
    ld   LINK_HI, x
    ld   scw_r672 >> 8, [x]
    ld   fl_add24 >> 8, y
    jmp  fl_add24
scw_r672:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_ld4 - w0-w3 = the 4 bytes at FL_PG + AC.  A leaf.

#overlay3 0x4500
dk_read:
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
    ld   ac, [CUR_ROW]
    ld   DOCK_X & 0xFF, ac
    ld   ac, [u5]
    ld   DOCK_X >> 8, ac
    ld   ac, [u6]
    ld   FL_PX, ac
    ld   LINK_LO, x             ; CALL dk_diff
    ld   scw_r721, [x]
    ld   LINK_HI, x
    ld   scw_r721 >> 8, [x]
    ld   dk_diff >> 8, y
    jmp  dk_diff
scw_r721:
    clr  ac
    ld   ac, [v7]
    ld   LINK_LO, x             ; CALL dk_sabs
    ld   scw_r722, [x]
    ld   LINK_HI, x
    ld   scw_r722 >> 8, [x]
    ld   dk_sabs >> 8, y
    jmp  dk_sabs
scw_r722:
    ld   [w2], ac
    ld   ac, [w0]
    ld   [w3], ac
    ld   ac, [w1]
    ld   10, ac
    ld   LINK_LO, x             ; CALL dk_pint
    ld   scw_r723, [x]
    ld   LINK_HI, x
    ld   scw_r723 >> 8, [x]
    ld   dk_pint >> 8, y
    jmp  dk_pint
scw_r723:
    clr  ac
    ld   ac, [v7]
    ld   30, ac
    ld   ac, [v6]
    ld   FL_VX, ac
    ld   LINK_LO, x             ; CALL dk_rate
    ld   scw_r724, [x]
    ld   LINK_HI, x
    ld   scw_r724 >> 8, [x]
    ld   dk_rate >> 8, y
    jmp  dk_rate
scw_r724:
    ld   2, ac
    ld   ac, [CUR_ROW]
    ld   DOCK_Y & 0xFF, ac
    ld   ac, [u5]
    ld   DOCK_Y >> 8, ac
    ld   ac, [u6]
    ld   FL_PY, ac
    ld   LINK_LO, x             ; CALL dk_diff
    ld   scw_r725, [x]
    ld   LINK_HI, x
    ld   scw_r725 >> 8, [x]
    ld   dk_diff >> 8, y
    jmp  dk_diff
scw_r725:
    ld   0x80, ac
    ld   ac, [v7]
    ld   10, ac
    ld   ac, [v6]
    ld   LINK_LO, x             ; CALL dk_dist
    ld   scw_r726, [x]
    ld   LINK_HI, x
    ld   scw_r726 >> 8, [x]
    ld   dk_dist >> 8, y
    jmp  dk_dist
scw_r726:
    ld   dk_read2 >> 8, y
    jmp  dk_read2

; dk_read2 - the rest of the readouts.  The rest of dk_read
s_dk0:
    #d "W S FWD  Q E SIDE  Z X UP DOWN  ARROWS TURN  R STOP", 0x00
s_dk1:
    #d "1-5 OR CLICK  THE BUTTONS   ESC  THE MAP", 0x00


#overlay3 0x4600
dk_turn:
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
    ld   FL_PG, y
    ld   FL_HF, x
    ld   [y,x], ac
    ld   DK_YW, x
    ld   ac, [y,x]
    ld   FL_HD, x
    ld   [y,x], ac
    ld   DK_YW + 1, x
    ld   ac, [y,x]
    ld   FL_SPN, x
    ld   [y,x], ac
    ld   DK_YR, x
    ld   ac, [y,x]
    blt  tn_n
    bra  tn_p
tn_n:
    xor  0xFF, ac
    inc
tn_p:
    shr  ac
    ld   DK_PR, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL l_rand8
    ld   scw_r629, [x]
    ld   LINK_HI, x
    ld   scw_r629 >> 8, [x]
    ld   l_rand8 >> 8, y
    jmp  l_rand8
scw_r629:
    and  1, ac
    beq  tn_s
    ld   FL_PG, y
    ld   DK_PR, x
    ld   [y,x], ac
    xor  0xFF, ac
    inc
    ld   ac, [y,x]
tn_s:
    ld   1, ac
    ld   ac, [w3]
    ld   DK_UP, ac
    ld   ac, [w2]
    ld   FL_PG, y
    ld   FL_HD, x
    ld   [y,x], ac
    xor  0xFF, ac
    add  17, ac                 ; 16 - h: -1 (up: the screen's)
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r630, [x]
    ld   LINK_HI, x
    ld   scw_r630 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r630:
    ld   DK_DN, ac
    ld   ac, [w2]
    ld   FL_PG, y
    ld   FL_HD, x
    ld   [y,x], ac
    xor  0xFF, ac
    inc
    ld   LINK_LO, x             ; CALL fl_dv1
    ld   scw_r631, [x]
    ld   LINK_HI, x
    ld   scw_r631 >> 8, [x]
    ld   fl_dv1 >> 8, y
    jmp  fl_dv1
scw_r631:
    ld   LINK_LO, x             ; CALL fl_dv
    ld   scw_r632, [x]
    ld   LINK_HI, x
    ld   scw_r632 >> 8, [x]
    ld   fl_dv >> 8, y
    jmp  fl_dv
scw_r632:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_frame - the height moved (undocked), the button under the mouse;
; frames 0, 4, 8, 12 (of 16) the ring (the drift on 0), 2 the readouts,
; 6 the flashing, others the buttons when they changed
dk_undk:
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   0x00, [y,x]
    ld   FL_VX, x
    ld   UNDOCK_B0, [y,x]
    ld   FL_VX + 1, x
    ld   UNDOCK_B1, [y,x]
    ld   FL_VX + 2, x
    ld   UNDOCK_B2, [y,x]
    ld   FL_VX + 3, x
    ld   UNDOCK_B3, [y,x]
    ld   T_DOOR, ac
    ld   ac, [u7]
    ld   T_WALL, ac
    ld   LINK_LO, x             ; CALL fl_locks
    ld   scw_r664, [x]
    ld   LINK_HI, x
    ld   scw_r664 >> 8, [x]
    ld   fl_locks >> 8, y
    jmp  fl_locks
scw_r664:
    ld   1, ac
    ld   ac, [rb_go]
    ld   LINK_LO, x             ; CALL fl_rel
    ld   scw_r665, [x]
    ld   LINK_HI, x
    ld   scw_r665 >> 8, [x]
    ld   fl_rel >> 8, y
    jmp  fl_rel
scw_r665:
    ld   FL_PG, y
    ld   FL_GPL, x
    ld   [w0], ac
    ld   ac, [y,x]
    ld   FL_GPH, x
    ld   [w1], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL fl_save
    ld   scw_r666, [x]
    ld   LINK_HI, x
    ld   scw_r666 >> 8, [x]
    ld   fl_save >> 8, y
    jmp  fl_save
scw_r666:
    ld   1, ac
    ld   LINK_LO, x             ; CALL dk_hz
    ld   scw_r667, [x]
    ld   LINK_HI, x
    ld   scw_r667 >> 8, [x]
    ld   dk_hz >> 8, y
    jmp  dk_hz
scw_r667:
    ld   s_undk & 0xFF, ac
    ld   ac, [R0]
    ld   s_undk >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg

; dk_drift - undocked: a random push to the height's speed and the
; sideways one

#overlay3 0x4700
dk_clamp:
    ld   LINK_LO, x             ; CALL dk_dkd
    ld   scw_r659, [x]
    ld   LINK_HI, x
    ld   scw_r659 >> 8, [x]
    ld   dk_dkd >> 8, y
    jmp  dk_dkd
scw_r659:
    beq  cl_u
    ld   4, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r660, [x]
    ld   LINK_HI, x
    ld   scw_r660 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r660:
    bne  cl_r
    ld   s_lock & 0xFF, ac
    ld   ac, [R0]
    ld   s_lock >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg
cl_r:
    ld   dk_undk >> 8, y
    jmp  dk_undk
cl_u:
    ld   2, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r661, [x]
    ld   LINK_HI, x
    ld   scw_r661 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r661:
    bne  dcl_d
    ld   s_ndc & 0xFF, ac
    ld   ac, [R0]
    ld   s_ndc >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg
dcl_d:
    ld   FL_PG, y
    ld   DK_OK, x
    ld   [y,x], ac
    bne  cl_on
    ld   s_miss & 0xFF, ac
    ld   ac, [R0]
    ld   s_miss >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg
cl_on:
    ld   LINK_LO, x             ; CALL fl_dock
    ld   scw_r662, [x]
    ld   LINK_HI, x
    ld   scw_r662 >> 8, [x]
    ld   fl_dock >> 8, y
    jmp  fl_dock
scw_r662:
    ld   FL_PG, y               ; clamped: lined up, not turning (DK_YR to
    ld   DK_YR, ac              ; DK_PW 0: heading east)
    ld   ac, [u0]
cz_l:
    ld   [u0], x
    ld   0x00, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  DK_RS, ac
    bne  cz_l
    ld   1, ac
    ld   ac, [rb_go]
    ld   1, ac                  ; hailed only: declare again next time
    ld   LINK_LO, x             ; CALL dk_hz
    ld   scw_r663, [x]
    ld   LINK_HI, x
    ld   scw_r663 >> 8, [x]
    ld   dk_hz >> 8, y
    jmp  dk_hz
scw_r663:
    ld   s_dkon & 0xFF, ac
    ld   ac, [R0]
    ld   s_dkon >> 8, ac
    ld   dk_msg >> 8, y
    jmp  dk_msg

; dk_hz - DK_ST &= AC, the height and its speed 0, clear to clamp off.
; A leaf.
dk_rk:
    clr  ac
    ld   ac, [v0]
rk_l:
    ld   DK_RT >> 8, y
    ld   [v0], ac
    add  DK_RT & 0xFF, x
    ld   [y,x], ac
    beq  rk_e
    add  KBD_NOW, ac
    ld   ac, [u0]
    ld   [v0], ac
    add  (DK_RT & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [v0], ac
    add  (DK_RT & 0xFF) + 2, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [v0], ac
    add  (DK_RT & 0xFF) + 3, x
    ld   [y,x], ac
    ld   ac, [u3]
    ld   0x00, y
    ld   [u0], x
    ld   [y,x], ac
    and  [u1], ac
    bne  rk_n
    ld   FL_PG, y
    ld   DK_RS, x
    ld   0x00, [y,x]
    ld   [u2], x
    ld   [y,x], ac
    add  [u3], ac
    ld   ac, [u4]
    xor  NAV_SPIN + 1, ac
    beq  rk_n
    ld   [u4], ac
    xor  (0 - NAV_SPIN - 1) & 0xFF, ac
    beq  rk_n
    ld   [u4], ac
    ld   ac, [y,x]
rk_n:
    ld   [v0], ac
    add  4, ac
    ld   ac, [v0]
    bra  rk_l
rk_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
DK_RT:
    #d8 7, 0x20, DK_YR, 0xFF, 3, 0x20, DK_YR, 0xFF   ; Left A
    #d8 7, 0x80, DK_YR, 1, 3, 0x80, DK_YR, 1         ; Right D
    #d8 6, 0x20, DK_PR, 1, 7, 0x40, DK_PR, 0xFF, 0   ; Up Down

; dk_rots - a frame of turning: the yaw and the pitch (dk_rot), the
; heading's thrust again when its step changed
dk_bts:
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
    ld   ac, [v0]
    xor  5, ac
    bne  bt_l
    ld   dk_stl >> 8, y
    jmp  dk_stl
bt_l:
    ld   [v0], ac
    shl
    add  7, ac
    ld   ac, [CUR_ROW]
    ld   43, ac
    ld   ac, [CUR_COL]
    ld   0x80, ac
    ld   ac, [v1]
    ld   FL_PG, y
    ld   DK_HV, x
    ld   [y,x], ac
    xor  [v0], ac
    bne  bt_h
    clr  ac
    ld   ac, [v1]
bt_h:
    ld   [v0], ac
    xor  3, ac
    bne  bt_p
    ld   DK_OK, x
    ld   [y,x], ac
    beq  bt_c
    ld   DK_T, x
    ld   [y,x], ac
    and  16, ac
    beq  bt_c
    ld   [v1], ac
    xor  0x80, ac
    ld   ac, [v1]
bt_c:
    ld   FL_DOCK, x
    ld   [y,x], ac
    beq  bt_p
    ld   5, ac
    bra  bt_s
bt_p:
    ld   [v0], ac
bt_s:
    shl
    ld   ac, [v2]
    ld   [v1], ac
    ld   ac, [p_inv]
    ld   DK_BL >> 8, y
    ld   [v2], ac
    add  DK_BL & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [v2], ac
    add  (DK_BL & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r713, [x]
    ld   LINK_HI, x
    ld   scw_r713 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r713:
    clr  ac
    ld   ac, [p_inv]
    ld   sc_leave >> 8, y
    jmp  sc_leave
DK_BL:
    #d8 s_b0 & 0xFF, s_b0 >> 8, s_b1 & 0xFF, s_b1 >> 8, s_b2 & 0xFF, s_b2 >> 8
    #d8 s_b3 & 0xFF, s_b3 >> 8, s_b4 & 0xFF, s_b4 >> 8, s_b5 & 0xFF, s_b5 >> 8

; dk_stl - the status (row 4, from column 52).  The rest of dk_bts
dk_tug:
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
    ld   DK_CX, ac
    ld   ac, [u5]
    ld   DK_CY, ac
    ld   ac, [u6]
    ld   DK_TR, ac
    ld   ac, [u7]
    clr  ac
    ld   ac, [v0]
    ld   LINK_LO, x             ; CALL dk_circ
    ld   scw_r709, [x]
    ld   LINK_HI, x
    ld   scw_r709 >> 8, [x]
    ld   dk_circ >> 8, y
    jmp  dk_circ
scw_r709:
    ld   DK_CX - 40, ac         ; (inside the ring: none on it)
    ld   ac, [v1]
dtg_l:
    ld   [v1], ac
    ld   ac, [u0]
    ld   DK_CY, ac
    ld   ac, [u1]
    ld   LINK_LO, x             ; CALL dk_px
    ld   scw_r710, [x]
    ld   LINK_HI, x
    ld   scw_r710 >> 8, [x]
    ld   dk_px >> 8, y
    jmp  dk_px
scw_r710:
    ld   DK_CX, ac
    ld   ac, [u0]
    ld   [v1], ac
    add  DK_CY - DK_CX, ac
    ld   ac, [u1]
    ld   LINK_LO, x             ; CALL dk_px
    ld   scw_r711, [x]
    ld   LINK_HI, x
    ld   scw_r711 >> 8, [x]
    ld   dk_px >> 8, y
    jmp  dk_px
scw_r711:
    ld   [v1], ac
    add  4, ac
    ld   ac, [v1]
    xor  DK_CX + 44, ac
    bne  dtg_l
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_labs - the fixed text (DK_LAB: row, bit 7 inverse; column; the
; string)

#overlay3 0x4900
dk_thr:
    ld   FL_PG, y
    ld   FL_DOCK, x
    ld   [y,x], ac
    bne  kt_e
    ld   LINK_LO, x             ; CALL dk_rk
    ld   scw_r644, [x]
    ld   LINK_HI, x
    ld   scw_r644 >> 8, [x]
    ld   dk_rk >> 8, y
    jmp  dk_rk
scw_r644:
    clr  ac
    ld   ac, [v0]
kt_l:
    ld   DK_KT >> 8, y
    ld   [v0], ac
    add  DK_KT & 0xFF, x
    ld   [y,x], ac
    beq  kt_e
    ld   ac, [u0]
    ld   [v0], ac
    add  (DK_KT & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [u1]
    ld   [v0], ac
    add  (DK_KT & 0xFF) + 2, x
    ld   [y,x], ac
    ld   ac, [u2]
    ld   0x00, y
    ld   [u0], ac
    add  KBD_NOW, x
    ld   [y,x], ac
    and  [u1], ac
    beq  kt_h
    ld   [v0], ac
    add  3, ac
    ld   ac, [v0]
    bra  kt_l
kt_h:
    ld   [u2], ac
    and  2, ac
    bne  kt_v
    ld   FL_PG, y
    ld   FL_TH, x
    ld   [u2], ac
    ld   ac, [y,x]
kt_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave
kt_v:
    ld   FL_PG, y
    ld   FL_FLL, x
    ld   [y,x], ac
    ld   FL_FLH, x
    or   [y,x], ac
    beq  kt_e
    ld   FL_A8, x
    ld   [y,x], ac
    beq  kt_e
    ld   FL_TH, x
    ld   DK_Z, [y,x]
    ld   [u2], ac
    ld   ac, [w1]
    ld   DK_VY, ac
    ld   LINK_LO, x             ; CALL fl_add24
    ld   scw_r645, [x]
    ld   LINK_HI, x
    ld   scw_r645 >> 8, [x]
    ld   fl_add24 >> 8, y
    jmp  fl_add24
scw_r645:
    ld   sc_leave >> 8, y
    jmp  sc_leave
DK_KT:                          ; KBD_NOW byte, bit, the vector (bit 1: up / down):
    #d8 2, 0x01, FL_DVX, 3, 0x40, FL_RVX    ; W S
    #d8 1, 0x80, FL_LVX, 2, 0x02, FL_SVX    ; Q E
    #d8 5, 0x04, DK_UP, 5, 0x08, DK_DN, 0   ; Z X

; dk_rk - the turning keys held (DK_RT: KBD_NOW byte, bit, the rate,
; + or - 1): the rate on (not past NAV_SPIN either way), R's stop off.
; A leaf.
s_undk:
    #d "CLAMPS RELEASED: 5 M/S AWAY.", 0x00
s_ndc:
    #d "NOT CLEARED: REQUEST DOCKING.", 0x00
s_dkon:
    #d "CLAMPS ON: DOCKED.", 0x00
s_miss:
    #d "CLAMPS MISSED: LINE UP, SLOW DOWN.", 0x00

; ============================================================
; SCRAP.PWR: the power view (scrap_pwr.masm), read in when the power
; view needs it (#overlay4: gen_plc.py --swap 0x4700,0x4D00,PWR,4;
; rooms_build's fill stack), then SCRAP.INI: the start's code (--swap
; 0x4100,0x4500,INI,4)
; ============================================================
; ============================================================
; scrap_pwr.masm - SCRAP.PWR: the power view (#overlay4, x4700-x4CFF),
; and SCRAP.INI: the start (x4100-x44FF)
; ============================================================
; Date: 11/09/2026
;
; A conduit is a bit a cell (cb_get, resident: the hidden screen bytes of
; the odd pages xA1-xFF), so one can run under anything on a deck and in
; a wall.  V turns the power view on and off: every conduit drawn over
; the cells as a line to each side with a conduit or a powered part
; (F_PWR, installed: it looks plugged in), and a powered part's stub to
; each side with a conduit; yellow when its network is live (a working
; reactor or installed battery on one of its cells or beside one), orange
; when it is not.  The normal view shows a bare deck's conduit (PIPE) by
; its art and hides the rest.
;
; SCRAP.PWR is read into x4700-x4CFF (rooms_build's fill stack) by
; pwr_fetch when the power view draws after rooms_build or a swap file
; overwrote it (PW_ST bit 1 clear).  SCRAP.INI (the end of this file) is
; the start's code, read in once by start.
; power_build's live bits are rooms_build's fill map (RB_VIS); its stack
; is x4100-x42FF (rooms_build's sums).

PW_LIVE = 0xEE              ; the power view: a live conduit yellow
PW_DEAD = 0xDD              ;   a dead one orange
PW_STK  = 0x41              ; power_build's stack: x4100-x42FF (rooms_build's sums)

; power_build - RB_VIS: a bit for each live conduit.  From each conduit
; not live yet with a working source on it or beside it (pw_touch), its
; network (pw_fill).  PW_ST bit 1 set.  w0, w1
dk_sim2:
    ld   DOCK_Y & 0xFF, ac
    ld   ac, [u5]
    ld   DOCK_Y >> 8, ac
    ld   ac, [u6]
    ld   FL_PY, ac
    ld   LINK_LO, x             ; CALL dk_diff
    ld   scw_r676, [x]
    ld   LINK_HI, x
    ld   scw_r676 >> 8, [x]
    ld   dk_diff >> 8, y
    jmp  dk_diff
scw_r676:
    ld   LINK_LO, x             ; CALL dk_s16
    ld   scw_r677, [x]
    ld   LINK_HI, x
    ld   scw_r677 >> 8, [x]
    ld   dk_s16 >> 8, y
    jmp  dk_s16
scw_r677:
    ld   FL_PG, y
    ld   DK_X, x
    ld   ac, [y,x]
    clr  ac
    ld   ac, [u5]
    ld   ac, [u6]
    ld   DK_Y, ac
    ld   LINK_LO, x             ; CALL dk_diff
    ld   scw_r678, [x]
    ld   LINK_HI, x
    ld   scw_r678 >> 8, [x]
    ld   dk_diff >> 8, y
    jmp  dk_diff
scw_r678:
    ld   LINK_LO, x             ; CALL dk_s16
    ld   scw_r679, [x]
    ld   LINK_HI, x
    ld   scw_r679 >> 8, [x]
    ld   dk_s16 >> 8, y
    jmp  dk_s16
scw_r679:
    ld   FL_PG, y
    ld   DK_YS, x
    ld   ac, [y,x]
    ld   DK_YW, ac              ; the angles: the yaw right moves the port
    ld   LINK_LO, x             ; left, the pitch up moves it down
    ld   scw_r680, [x]
    ld   LINK_HI, x
    ld   scw_r680 >> 8, [x]
    ld   dk_ang >> 8, y
    jmp  dk_ang
scw_r680:
    xor  0xFF, ac
    inc
    ld   ac, [u4]
    ld   DK_X, ac
    ld   LINK_LO, x             ; CALL dk_off
    ld   scw_r681, [x]
    ld   LINK_HI, x
    ld   scw_r681 >> 8, [x]
    ld   dk_off >> 8, y
    jmp  dk_off
scw_r681:
    ld   DK_PW, ac
    ld   LINK_LO, x             ; CALL dk_ang
    ld   scw_r682, [x]
    ld   LINK_HI, x
    ld   scw_r682 >> 8, [x]
    ld   dk_ang >> 8, y
    jmp  dk_ang
scw_r682:
    ld   ac, [u4]
    ld   DK_YS, ac
    ld   LINK_LO, x             ; CALL dk_off
    ld   scw_r683, [x]
    ld   LINK_HI, x
    ld   scw_r683 >> 8, [x]
    ld   dk_off >> 8, y
    jmp  dk_off
scw_r683:
    ld   dk_okd >> 8, y
    jmp  dk_okd

; dk_ang - AC = the angle at FL_PG + AC (2 bytes: 1/256 steps, steps mod
; 32, signed) / 16, held to +-64.  A leaf.
dk_stl:
    ld   4, ac
    ld   ac, [CUR_ROW]
    ld   52, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL dk_dkd
    ld   scw_r714, [x]
    ld   LINK_HI, x
    ld   scw_r714 >> 8, [x]
    ld   dk_dkd >> 8, y
    jmp  dk_dkd
scw_r714:
    beq  st_u
    ld   4, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r715, [x]
    ld   LINK_HI, x
    ld   scw_r715 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r715:
    beq  st_c
    ld   s_s5 & 0xFF, ac
    bra  st_p
st_c:
    ld   s_s4 & 0xFF, ac
    bra  st_p
st_u:
    ld   2, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r716, [x]
    ld   LINK_HI, x
    ld   scw_r716 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r716:
    beq  dst_1
    ld   s_s3 & 0xFF, ac
    bra  st_p
dst_1:
    ld   1, ac
    ld   LINK_LO, x             ; CALL dk_st
    ld   scw_r717, [x]
    ld   LINK_HI, x
    ld   scw_r717 >> 8, [x]
    ld   dk_st >> 8, y
    jmp  dk_st
scw_r717:
    beq  dst_0
    ld   s_s2 & 0xFF, ac
    bra  st_p
dst_0:
    ld   s_s1 & 0xFF, ac
st_p:
    ld   ac, [R0]
    ld   s_s1 >> 8, ac          ; (the statuses share a page: one chunk)
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL tputs
    ld   scw_r718, [x]
    ld   LINK_HI, x
    ld   scw_r718 >> 8, [x]
    ld   tputs >> 8, y
    jmp  tputs
scw_r718:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_flash - row 22: DOCKED steady, or CLEAR TO CLAMP flashing (inverse
; every other 16 frames; the clamp button with it), or blank

#overlay3 0x4B00
dk_loop:
dkl:
    ld   LINK_LO, x             ; CALL dk_pon
    ld   scw_r618, [x]
    ld   LINK_HI, x
    ld   scw_r618 >> 8, [x]
    ld   dk_pon >> 8, y
    jmp  dk_pon
scw_r618:
    ld   1, ac
    ld   LINK_LO, x             ; CALL l_wait_frames_io
    ld   scw_r619, [x]
    ld   LINK_HI, x
    ld   scw_r619 >> 8, [x]
    ld   l_wait_frames_io >> 8, y
    jmp  l_wait_frames_io
scw_r619:
    ld   LINK_LO, x             ; CALL dk_poff
    ld   scw_r620, [x]
    ld   LINK_HI, x
    ld   scw_r620 >> 8, [x]
    ld   dk_poff >> 8, y
    jmp  dk_poff
scw_r620:
    ld   LINK_LO, x             ; CALL l_kbd_scan
    ld   scw_r621, [x]
    ld   LINK_HI, x
    ld   scw_r621 >> 8, [x]
    ld   l_kbd_scan >> 8, y
    jmp  l_kbd_scan
scw_r621:
    ld   LINK_LO, x             ; (FL_NAV 2: a left click is dk_pick)
    ld   scw_r622, [x]
    ld   LINK_HI, x
    ld   scw_r622 >> 8, [x]
    ld   input_mouse >> 8, y
    jmp  input_mouse
scw_r622:
    ld   [KBD_NOW], ac          ; Esc (key 0; 0 = down)
    and  1, ac
    beq  dkl_x
    ld   [dead], ac
    bne  dkl_x
    ld   FL_PG, y               ; 5: FL_GO 1
    ld   FL_GO, x
    ld   [y,x], ac
    bne  dkl_x
    ld   LINK_LO, x             ; CALL dk_keys
    ld   scw_r623, [x]
    ld   LINK_HI, x
    ld   scw_r623 >> 8, [x]
    ld   dk_keys >> 8, y
    jmp  dk_keys
scw_r623:
    ld   LINK_LO, x             ; CALL game_tick
    ld   scw_r624, [x]
    ld   LINK_HI, x
    ld   scw_r624 >> 8, [x]
    ld   game_tick >> 8, y
    jmp  game_tick
scw_r624:
    ld   [dirty], ac            ; the message's time and row (update_panel,
    and  0xFE, ac               ; not the ship's panel)
    ld   ac, [dirty]
    ld   LINK_LO, x             ; CALL update_panel
    ld   scw_r625, [x]
    ld   LINK_HI, x
    ld   scw_r625 >> 8, [x]
    ld   update_panel >> 8, y
    jmp  update_panel
scw_r625:
    ld   LINK_LO, x             ; CALL dk_frame
    ld   scw_r626, [x]
    ld   LINK_HI, x
    ld   scw_r626 >> 8, [x]
    ld   dk_frame >> 8, y
    jmp  dk_frame
scw_r626:
    bra  dkl
dkl_x:
    ld   dk_exit >> 8, y
    jmp  dk_exit

; dk_exit - Esc let go; FL_NAV, FL_GO 0, the message off (its string is
; in this file).  The end of dock_main (its LEAVE)
dk_pt:
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
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL dk_sgn
    ld   scw_r743, [x]
    ld   LINK_HI, x
    ld   scw_r743 >> 8, [x]
    ld   dk_sgn >> 8, y
    jmp  dk_sgn
scw_r743:
    ld   [w0], ac
    ld   ac, [R0]
    ld   [w1], ac
    ld   ac, [R1]
    ld   10, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL l_div16
    ld   scw_r744, [x]
    ld   LINK_HI, x
    ld   scw_r744 >> 8, [x]
    ld   l_div16 >> 8, y
    jmp  l_div16
scw_r744:
    ld   ac, [u3]
    ld   [R0], ac
    ld   ac, [num_l]
    ld   [R1], ac
    ld   ac, [num_h]
    ld   LINK_LO, x             ; CALL put_dec
    ld   scw_r745, [x]
    ld   LINK_HI, x
    ld   scw_r745 >> 8, [x]
    ld   put_dec >> 8, y
    jmp  put_dec
scw_r745:
    ld   0x2E, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r746, [x]
    ld   LINK_HI, x
    ld   scw_r746 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r746:
    ld   [u3], ac
    add  0x30, ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r747, [x]
    ld   LINK_HI, x
    ld   scw_r747 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r747:
    ld   dk_pad >> 8, y
    jmp  dk_pad


#overlay3 0x4C00
s_b0:
    #d " 1  HAIL              ", 0x00
s_b1:
    #d " 2  REQUEST DOCKING   ", 0x00
s_b2:
    #d " 3  REQUEST UNDOCK    ", 0x00
s_b3:
    #d " 4  CLAMP             ", 0x00
s_b4:
    #d " 5  BACK TO THE MAP   ", 0x00
s_b5:
    #d " 4  RELEASE CLAMPS    ", 0x00

s_nant:
    #d "NO WORKING ANTENNA.", 0x00
s_hail:
    #d "NO REPLY: A DERELICT.  DECLARE DOCKING.", 0x00
s_hlf:
    #d "HAIL THE KESTREL 9 FIRST.", 0x00
s_adk:
    #d "ALREADY DOCKED.", 0x00
s_ndk:
    #d "NOT DOCKED.", 0x00


#overlay3 0x4E00
dk_rot:
    ld   ac, [u1]
    ld   ac, x
    ld   FL_PG, y
    ld   [y,x], ac
    ld   ac, [u0]
    ld   DK_RS, x
    ld   [y,x], ac
    beq  dr_m
    ld   [u0], ac
    beq  dr_m
    blt  dr_up
    dec
    bra  dr_w
dr_up:
    inc
dr_w:
    ld   ac, [u0]
    ld   [u1], x
    ld   ac, [y,x]
dr_m:
    ld   [u1], ac
    add  1, x
    ld   [y,x], ac
    add  [u0], ac
    ld   ac, [y,x]
    ld   [u0], ac
    blt  dro_n
    bcc  dr_e
    ld   1, ac
    bra  dro_h
dro_n:
    bcs  dr_e
    ld   0xFF, ac
dro_h:
    ld   ac, [u0]
    ld   [u1], ac
    add  2, x
    ld   [y,x], ac
    add  [u0], ac
    ld   ac, [y,x]
dr_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_hov - AC = the button under the mouse (0-4: rows 7, 9 .. 15,
; columns 43-64), FF none.  A leaf.
dk_diff:
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
    ld   LINK_LO, x             ; CALL dk_ld4
    ld   scw_r673, [x]
    ld   LINK_HI, x
    ld   scw_r673 >> 8, [x]
    ld   dk_ld4 >> 8, y
    jmp  dk_ld4
scw_r673:
    ld   LINK_LO, x             ; CALL dk_neg
    ld   scw_r674, [x]
    ld   LINK_HI, x
    ld   scw_r674 >> 8, [x]
    ld   dk_neg >> 8, y
    jmp  dk_neg
scw_r674:
    ld   [w2], ac
    add  [u5], ac
    ld   ac, [w2]
    ld   [w3], ac
    bcc  df_1
    inc
df_1:
    add  [u6], ac
    ld   ac, [w3]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_s16 - AC = w3:w0 (metres, 16.16) in 1/16 m, held to +-112 (7 m).
; A leaf.
dk_ang:
    ld   ac, [u3]
    ld   ac, x
    ld   FL_PG, y
    ld   [y,x], ac
    ld   ac, [u2]
    ld   [u3], ac
    add  1, x
    ld   [y,x], ac
    add  16, ac
    and  31, ac
    ld   ac, [u3]
    sub  20, ac
    bcc  ag_h
    ld   [u3], ac
    sub  12, ac
    bcs  ag_l
    ld   [u3], ac
    sub  16, ac
    shl
    shl
    shl
    shl
    ld   ac, [u3]
    ld   [u2], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  [u3], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ag_h:
    ld   64, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ag_l:
    ld   0xC0, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_off - (the byte at FL_PG + AC) / 2 + u4 (signed: halves, no carry
; out) to FL_PG + AC + x17 (DK_X, DK_YS: DK_RX, DK_RY, half size).  A leaf.
dk_btn:
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
    bne  db_1
    ld   dk_hail >> 8, y
    jmp  dk_hail
db_1:
    xor  1, ac
    bne  db_2
    ld   dk_rqd >> 8, y
    jmp  dk_rqd
db_2:
    xor  1 ^ 2, ac
    bne  db_3
    ld   dk_rqu >> 8, y
    jmp  dk_rqu
db_3:
    xor  2 ^ 3, ac
    bne  db_4
    ld   dk_clamp >> 8, y
    jmp  dk_clamp
db_4:
    ld   FL_PG, y               ; 5: back to the map
    ld   FL_GO, x
    ld   1, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_hail - 1 HAIL: a working antenna (N_ANT) and the KESTREL 9 hailed
; (no reply: a derelict).  The rest of dk_btn

#overlay3 0x4F00
dk_sgn:
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
    ld   0x20, ac
    ld   ac, [u2]
    ld   [w0], ac
    or   [w1], ac
    beq  sg_p
    ld   0x2B, ac
    ld   ac, [u2]
    ld   [u7], ac
    beq  sg_p
    ld   0x2D, ac
    ld   ac, [u2]
sg_p:
    ld   [u2], ac
    ld   LINK_LO, x             ; CALL tputc
    ld   scw_r752, [x]
    ld   LINK_HI, x
    ld   scw_r752 >> 8, [x]
    ld   tputc >> 8, y
    jmp  tputc
scw_r752:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ------------------------------------------------------------
; the strings
; ------------------------------------------------------------
s_ctc:
    #d " CLEAR TO CLAMP    ", 0x00
s_dko:
    #d " DOCKED: CLAMPS ON ", 0x00
s_blk:
    #d "                   ", 0x00

dk_c4:
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
    ld   [v5], ac
    ld   LINK_LO, x             ; CALL dk_c2
    ld   scw_r698, [x]
    ld   LINK_HI, x
    ld   scw_r698 >> 8, [x]
    ld   dk_c2 >> 8, y
    jmp  dk_c2
scw_r698:
    ld   [v5], ac
    beq  c4_e
    xor  0xFF, ac
    inc
    ld   LINK_LO, x             ; CALL dk_c2
    ld   scw_r699, [x]
    ld   LINK_HI, x
    ld   scw_r699 >> 8, [x]
    ld   dk_c2 >> 8, y
    jmp  dk_c2
scw_r699:
c4_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

dk_neg:
    ld   [w0], ac
    xor  0xFF, ac
    ld   ac, [w0]
    ld   [w1], ac
    xor  0xFF, ac
    ld   ac, [w1]
    ld   [w2], ac
    xor  0xFF, ac
    ld   ac, [w2]
    ld   [w3], ac
    xor  0xFF, ac
    ld   ac, [w3]
    ld   [w0], ac
    inc
    ld   ac, [w0]
    bne  ng_e
    ld   [w1], ac
    inc
    ld   ac, [w1]
    bne  ng_e
    ld   [w2], ac
    inc
    ld   ac, [w2]
    bne  ng_e
    ld   [w3], ac
    inc
    ld   ac, [w3]
ng_e:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_diff - w3:w0 = u6:u5 metres (16.16) less the position at FL_PG + AC
dk_st:
    ld   ac, [u0]
    ld   FL_PG, y
    ld   DK_ST, x
    ld   [y,x], ac
    and  [u0], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_dkd - AC = FL_DOCK.  A leaf.

#overlay3 0x5400
dk_s16:
    ld   [w3], ac
    beq  sx_p
    xor  0xFF, ac
    bne  sx_b
    ld   [w2], ac
    sub  0xF9, ac
    bcs  sx_lo
    bra  sx_ok
sx_p:
    ld   [w2], ac
    sub  7, ac
    bcc  sx_hi
sx_ok:
    ld   [w2], ac
    shl
    shl
    shl
    shl
    ld   ac, [u0]
    ld   [w1], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    or   [u0], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sx_b:
    ld   [w3], ac
    blt  sx_lo
sx_hi:
    ld   112, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sx_lo:
    ld   0x90, ac               ; -112
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_sim - every 4 frames: the range in half metres (DK_D2: 0 a metre
; past the port at most, else 239 past it or 120 m or more), the port
; sideways and up in 1/16 m (DK_X, DK_YS), clear to clamp (dk_okd)
dk_slow:
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
    add  2, ac
    ld   LINK_LO, x             ; CALL fl_abs
    ld   scw_r692, [x]
    ld   LINK_HI, x
    ld   scw_r692 >> 8, [x]
    ld   fl_abs >> 8, y
    jmp  fl_abs
scw_r692:
    ld   [u1], ac
    bne  dsl_n
    ld   [u0], ac
    sub  3, ac
    bcc  dsl_n
    ld   1, ac
    ld   sc_leave >> 8, y
    jmp  sc_leave
dsl_n:
    clr  ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_ring - the port's ring: radius 960 / (DK_D2 + 16) (2 at least), its
; middle DK_CX + DK_RX, DK_CY + DK_RY (half size: dk_off); the old one rubbed out
; (XOR) when it moved
dk_pick:
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
    ld   LINK_LO, x             ; CALL dk_hov
    ld   scw_r649, [x]
    ld   LINK_HI, x
    ld   scw_r649 >> 8, [x]
    ld   dk_hov >> 8, y
    jmp  dk_hov
scw_r649:
    xor  0xFF, ac
    beq  dpk_e
    xor  0xFF, ac
    ld   LINK_LO, x             ; CALL dk_btn
    ld   scw_r650, [x]
    ld   LINK_HI, x
    ld   scw_r650 >> 8, [x]
    ld   dk_btn >> 8, y
    jmp  dk_btn
scw_r650:
dpk_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_btn - button AC (0-4) pressed
dk_hz:
    ld   ac, [u0]
    ld   FL_PG, y
    ld   DK_ST, x
    ld   [y,x], ac
    and  [u0], ac
    ld   ac, [y,x]
    ld   DK_Y, ac
    ld   ac, [u0]
hz_l:
    ld   [u0], x
    ld   0x00, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  DK_Z, ac
    bne  hz_l
    ld   DK_OK, x
    ld   0x00, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_undk - the clamps let go: undocked, 5 m/s away from the port
; (west); the tug's airlock a closed door, the KESTREL 9's a wall while it
; is away (no air between them), the rooms worked out when the map
; closes.  The rest of dk_btn
dk_okd:
    ld   LINK_LO, x             ; CALL dk_okc
    ld   scw_r684, [x]
    ld   LINK_HI, x
    ld   scw_r684 >> 8, [x]
    ld   dk_okc >> 8, y
    jmp  dk_okc
scw_r684:
    ld   ac, [u3]
    ld   FL_PG, y
    ld   DK_OK, x
    ld   [y,x], ac
    xor  [u3], ac
    beq  ok_s
    ld   DK_DR, x
    ld   6, [y,x]
ok_s:
    ld   DK_OK, x
    ld   [u3], ac
    ld   ac, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_okc - AC = 1 when the clamps would hold: undocked, docking declared,
; under 3.5 m to go, 12/16 m or less off each way (the angles in it),
; every speed under 3/256 m a frame, not turning

#overlay3 0x5500
dk_ld4:
    ld   ac, [u4]
    ld   FL_PG, y
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [w0]
    ld   [u4], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [w1]
    ld   [u4], ac
    add  2, x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   [u4], ac
    add  3, x
    ld   [y,x], ac
    ld   ac, [w3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_neg - w3:w0 = -w3:w0.  A leaf.
dk_back:
    ld   FL_PG, y
    ld   DK_YW, x
    ld   [y,x], ac
    ld   FL_HF, x
    ld   ac, [y,x]
    ld   DK_YR, x
    ld   [y,x], ac
    ld   FL_SPN, x
    ld   ac, [y,x]
    ld   FL_STP, x
    ld   0x00, [y,x]
    ld   FL_SFL, x
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   FL_SFH, x
    ld   [FRAME_HI], ac
    ld   ac, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_turn - the turn from the map (DK_YW the heading, DK_YR the spin,
; DK_PR half of it up or down: random); DK_UP, DK_DN (half thrust, cos 1
; and -1: fl_dv1), the heading's thrust vectors.  dk_init's
dk_hlf:
    ld   s_hlf & 0xFF, ac
    ld   ac, [R0]
    ld   s_hlf >> 8, ac
dk_msg:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL set_msg
    ld   scw_r658, [x]
    ld   LINK_HI, x
    ld   scw_r658 >> 8, [x]
    ld   set_msg >> 8, y
    jmp  set_msg
scw_r658:
    ld   FL_PG, y
    ld   DK_DR, x
    ld   6, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; dk_clamp - 4: docked, RELEASE CLAMPS (undocking declared: dk_undk);
; else CLAMP: docking declared and clear to clamp (DK_OK): docked
; (fl_dock: the airlocks joined, the rooms worked out when the map
; closes).  The rest of dk_btn
dk_off:
    ld   ac, [u3]
    ld   ac, x
    ld   FL_PG, y
    ld   [y,x], ac
    blt  of_n
    shr  ac
    bra  of_a
of_n:
    shr  ac
    or   0x80, ac
of_a:
    add  [u4], ac
    ld   ac, [u5]
    ld   [u3], ac
    add  DK_RX - DK_X, x
    ld   [u5], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_okd - DK_OK from dk_okc; the buttons again when it changed.  The end
; of dk_sim (its LEAVE)
dk_sm:
    ld   ac, x
    ld   FL_PG, y
    ld   [y,x], ac
    blt  sq_n
    bra  sq_c
sq_n:
    xor  0xFF, ac
    inc
sq_c:
    sub  7, ac
    bcs  sq_y
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sq_y:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; dk_slow - AC = 1 when the speed at FL_PG + AC (4 bytes) is under 3/256
; m a frame each way
dk_sabs:
    ld   [w3], ac
    and  0x80, ac
    xor  [v7], ac
    ld   ac, [u7]
    ld   [w3], ac
    blt  sa_n
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sa_n:
    ld   dk_neg >> 8, y
    jmp  dk_neg

; dk_rate - the speed at FL_PG + AC (4 bytes, 1/2^24 m a frame) in m/s
; to a tenth from column v6 (its sign xor v7): (w2:w1) / 109 under 1 m a
; frame, (w3:w2) x 75 / 32 to 16 m a frame, else 999.9

#overlay4 0x4100
pw_start:
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
    ld   PRT_K>>8, y
    ld   PRT_K&0xFF, x
    ld   0xFF, [y,x]
    ld   LINK_LO, x             ; docked to the KESTREL 9
    ld   scw_r774, [x]
    ld   LINK_HI, x
    ld   scw_r774 >> 8, [x]
    ld   fl_init >> 8, y
    jmp  fl_init
scw_r774:
    ld   LINK_LO, x             ; CALL l_mouse_init
    ld   scw_r775, [x]
    ld   LINK_HI, x
    ld   scw_r775 >> 8, [x]
    ld   l_mouse_init >> 8, y
    jmp  l_mouse_init
scw_r775:
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
    ld   scw_r776, [x]
    ld   LINK_HI, x
    ld   scw_r776 >> 8, [x]
    ld   game_init >> 8, y
    jmp  game_init
scw_r776:
    ld   LINK_LO, x             ; CALL screen_init
    ld   scw_r777, [x]
    ld   LINK_HI, x
    ld   scw_r777 >> 8, [x]
    ld   screen_init >> 8, y
    jmp  screen_init
scw_r777:
    ld   cb_init >> 8, y
    jmp  cb_init

; game_init - the suit, the hands, the rooms' air (pw_start; start then
; works out the rooms and the tug)
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
    ld   scw_r778, [x]
    ld   LINK_HI, x
    ld   scw_r778 >> 8, [x]
    ld   skills_init >> 8, y
    jmp  skills_init
scw_r778:
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
    xor  32, ac
    bne  gi_l
    ld   sc_leave >> 8, y
    jmp  sc_leave


; ------------------------------------------------------------
; screen_init - the pixels (the odd pages) cleared; every line 4 bpp
; 2x, the panel's lines 1 bpp 2x, its name row tinted
; ------------------------------------------------------------

#overlay4 0x4200
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
    ld   scw_r779, [x]
    ld   LINK_HI, x
    ld   scw_r779 >> 8, [x]
    ld   l_vid_mode >> 8, y
    jmp  l_vid_mode
scw_r779:
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

; fl_init - docked to the KESTREL 9, heading east, nothing burnt.  A leaf
; (scrap_fl.masm's: here with the rest of the start).
CB0:
    #d8 25, 30, 26, 30, 27, 30, 38, 42, 39, 42, 40, 42, 41, 42, 42, 42
    #d8 43, 42, 44, 42, 45, 42, 35, 44, 35, 45, 35, 46, 35, 47, 35, 48
    #d8 35, 49, 35, 50, 35, 51, 35, 52, 22, 28, 23, 28, 24, 28, 25, 28
    #d8 26, 28, 27, 28, 28, 28, 29, 28, 22, 29, 22, 30, 22, 31, 22, 32
    #d8 22, 33, 22, 34, 22, 35, 23, 35, 24, 35, 25, 35, 26, 35, 27, 35
    #d8 28, 35
    #d8 0xFF
skills_init:
    clr  ac                     ; the inventory off, nothing to place
    ld   ac, [inv]
    ld   ac, [place]
    ld   0xFF, ac
    ld   ac, [inv_k]
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
    ld   CLK_0 & 0xFF, x        ; the ship's clock: 08:00:00 (28800 s)
    ld   28800 & 0xFF, [y,x]
    ld   CLK_1 & 0xFF, x
    ld   28800 >> 8, [y,x]
    ld   CLK_2 & 0xFF, x
    ld   0x00, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; scrap_pwr_data.masm - made by gen_scrap.py: the conduits at the start
; (SCRAP.PWR's cb_init sets their bits)


#overlay4 0x4300
cb_init:
    ld   PW_ST >> 8, y
    ld   PW_ST & 0xFF, x
    ld   0x00, [y,x]
    clr  ac
    ld   ac, [w0]
pwi_l:
    ld   CB0 >> 8, y
    ld   [w0], ac
    add  CB0 & 0xFF, x
    ld   [y,x], ac
    ld   ac, [g_x]
    xor  0xFF, ac
    beq  pwi_e
    ld   [w0], ac
    add  (CB0 & 0xFF) + 1, x
    ld   [y,x], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL cb_set
    ld   scw_r773, [x]
    ld   LINK_HI, x
    ld   scw_r773 >> 8, [x]
    ld   cb_set >> 8, y
    jmp  cb_set
scw_r773:
    ld   [w0], ac
    add  2, ac
    ld   ac, [w0]
    bra  pwi_l
pwi_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pw_start - the start (and again after dying), from SCRAP.INI (start
; reads it in): the flight, the mouse, the player, game_init, the screen
; and the conduits; then start works out the rooms (over this file)
fl_init:
    ld   FL_PG, y
    ld   0x20, ac
    ld   ac, [u0]
fi_l:
    ld   [u0], x
    ld   0x00, [y,x]
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  0x40, ac
    bne  fi_2
    ld   0x60, ac
    ld   ac, [u0]
fi_2:
    ld   [u0], ac
    xor  0xC0, ac               ; (x4080-x40BF too: the nav screen's, the spin)
    bne  fi_l
    ld   [RAND_LO], ac          ; rand8 needs a state that is not 0
    or   [RAND_HI], ac
    bne  fi_r
    ld   0x5A, ac
    ld   ac, [RAND_LO]
fi_r:
    ld   fl_dock >> 8, y
    jmp  fl_dock

; skills_init - every skill at SKILL_START, no progress; the suit on.  A
; leaf.

#overlay4 0x4700
ov_cell:
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
    ld   ac, [T0]
    ld   ac, [g_x]
    ld   [v_y], ac
    add  [dc_cy], ac
    ld   ac, [T1]
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_see
    ld   scw_r763, [x]
    ld   LINK_HI, x
    ld   scw_r763 >> 8, [x]
    ld   map_see >> 8, y
    jmp  map_see
scw_r763:
    xor  T_SPACE, ac            ; (the KESTREL 9 out of sight: nothing)
    beq  pwo_e
    ld   LINK_LO, x             ; CALL pw_kind
    ld   scw_r764, [x]
    ld   LINK_HI, x
    ld   scw_r764 >> 8, [x]
    ld   pw_kind >> 8, y
    jmp  pw_kind
scw_r764:
    ld   ac, [T4]
    ld   LINK_LO, x             ; CALL cb_get
    ld   scw_r765, [x]
    ld   LINK_HI, x
    ld   scw_r765 >> 8, [x]
    ld   cb_get >> 8, y
    jmp  cb_get
scw_r765:
    ld   ac, [T3]
    or   [T4], ac
    beq  pwo_e
    ld   LINK_LO, x             ; CALL pw_col
    ld   scw_r766, [x]
    ld   LINK_HI, x
    ld   scw_r766 >> 8, [x]
    ld   pw_col >> 8, y
    jmp  pw_col
scw_r766:
    ld   ac, [T5]
    clr  ac
    ld   ac, [T7]               ; the sides drawn
    ld   1, ac
    ld   ac, [T2]
pwo_l:
    ld   PWADJ >> 8, y
    ld   [T2], ac
    add  PWADJ & 0xFF, x
    ld   [y,x], ac
    add  [T0], ac
    ld   ac, [g_x]
    ld   [T2], ac
    add  (PWADJ & 0xFF) + 5, x
    ld   [y,x], ac
    add  [T1], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL cb_get
    ld   scw_r767, [x]
    ld   LINK_HI, x
    ld   scw_r767 >> 8, [x]
    ld   cb_get >> 8, y
    jmp  cb_get
scw_r767:
    bne  pwo_c
    ld   [T3], ac               ; a powered part beside a conduit here
    beq  pwo_n
    ld   LINK_LO, x             ; CALL map_see
    ld   scw_r768, [x]
    ld   LINK_HI, x
    ld   scw_r768 >> 8, [x]
    ld   map_see >> 8, y
    jmp  map_see
scw_r768:
    ld   LINK_LO, x             ; CALL pw_kind
    ld   scw_r769, [x]
    ld   LINK_HI, x
    ld   scw_r769 >> 8, [x]
    ld   pw_kind >> 8, y
    jmp  pw_kind
scw_r769:
    beq  pwo_n
    bra  pwo_m
pwo_c:
    ld   [T3], ac               ; a conduit beside: a part's stub in its colour
    bne  pwo_m
    ld   LINK_LO, x             ; CALL pw_col
    ld   scw_r770, [x]
    ld   LINK_HI, x
    ld   scw_r770 >> 8, [x]
    ld   pw_col >> 8, y
    jmp  pw_col
scw_r770:
    bra  pwo_s
pwo_m:
    ld   [T5], ac
    ld   ac, [T6]
pwo_s:
    ld   LINK_LO, x             ; CALL seg
    ld   scw_r771, [x]
    ld   LINK_HI, x
    ld   scw_r771 >> 8, [x]
    ld   seg >> 8, y
    jmp  seg
scw_r771:
    ld   1, ac
    ld   ac, [T7]
pwo_n:
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  5, ac
    bne  pwo_l
    ld   ov_dot >> 8, y
    jmp  ov_dot
pwo_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; ov_dot - a conduit with nothing beside it: a dot.  The rest of ov_cell

#overlay4 0x4800
power_build:
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
    ld   RB_VIS, ac             ; the fill map cleared (x4300-x46FF)
    ld   ac, [u0]
pwb_c:
    ld   [u0], y
    clr  ac
pwb_cb:
    ld   ac, x
    ld   0x00, [y,x]
    inc
    bne  pwb_cb
    ld   [u0], ac
    inc
    ld   ac, [u0]
    xor  RB_STK, ac
    bne  pwb_c
    ld   PW_STK, ac             ; the stack empty
    ld   ac, [stk_h]
    clr  ac
    ld   ac, [stk_l]
    ld   ac, [w1]
pwb_y:
    clr  ac
    ld   ac, [w0]
pwb_x:
    ld   [w0], ac
    ld   ac, [g_x]
    ld   [w1], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL cb_get
    ld   scw_r753, [x]
    ld   LINK_HI, x
    ld   scw_r753 >> 8, [x]
    ld   cb_get >> 8, y
    jmp  cb_get
scw_r753:
    bne  pwb_k
    ld   [u2], ac               ; none in its byte: the next byte
    bne  pwb_n
    ld   [w0], ac
    or   7, ac
    ld   ac, [w0]
    bra  pwb_n
pwb_k:
    ld   LINK_LO, x             ; CALL pw_col
    ld   scw_r754, [x]
    ld   LINK_HI, x
    ld   scw_r754 >> 8, [x]
    ld   pw_col >> 8, y
    jmp  pw_col
scw_r754:
    xor  PW_LIVE, ac
    beq  pwb_n
    ld   LINK_LO, x             ; CALL pw_touch
    ld   scw_r755, [x]
    ld   LINK_HI, x
    ld   scw_r755 >> 8, [x]
    ld   pw_touch >> 8, y
    jmp  pw_touch
scw_r755:
    beq  pwb_n
    ld   LINK_LO, x             ; CALL pw_push
    ld   scw_r756, [x]
    ld   LINK_HI, x
    ld   scw_r756 >> 8, [x]
    ld   pw_push >> 8, y
    jmp  pw_push
scw_r756:
    ld   LINK_LO, x             ; CALL pw_fill
    ld   scw_r757, [x]
    ld   LINK_HI, x
    ld   scw_r757 >> 8, [x]
    ld   pw_fill >> 8, y
    jmp  pw_fill
scw_r757:
pwb_n:
    ld   [w0], ac
    inc
    ld   ac, [w0]
    xor  MAP_W, ac
    bne  pwb_x
    ld   [w1], ac
    inc
    ld   ac, [w1]
    xor  MAP_H, ac
    bne  pwb_y
    ld   PW_ST >> 8, y
    ld   PW_ST & 0xFF, x
    ld   [y,x], ac
    or   2, ac
    ld   ac, [y,x]
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pw_fill - each cell taken off the stack: its sides' conduits not live
; yet made live and put on it (pw_push), until it is empty.  w2-w4
pw_push:
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
    ld   LINK_LO, x             ; CALL pw_col
    ld   scw_r761, [x]
    ld   LINK_HI, x
    ld   scw_r761 >> 8, [x]
    ld   pw_col >> 8, y
    jmp  pw_col
scw_r761:
    ld   [u2], y
    ld   [u3], x
    ld   [y,x], ac
    or   [u4], ac
    ld   ac, [y,x]
    ld   [stk_h], ac
    xor  RB_VIS, ac
    beq  pwp_e
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
    bne  pwp_e
    ld   [stk_h], ac
    inc
    ld   ac, [stk_h]
pwp_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pw_touch - AC 1: a working power source (a reactor, or a battery
; installed) under 50 % damage on cell g_x, g_y or beside it, else 0.
; g_x, g_y kept.  T0-T3
pw_fill:
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
pwf_l:
    ld   [stk_l], ac
    bne  pwf_q
    ld   [stk_h], ac
    xor  PW_STK, ac
    beq  pwf_e
    ld   [stk_h], ac
    dec
    ld   ac, [stk_h]
pwf_q:
    ld   [stk_l], ac
    sub  2, ac
    ld   ac, [stk_l]
    ld   [stk_h], y
    ld   [stk_l], x
    ld   [y,x], ac
    ld   ac, [w2]
    ld   [stk_l], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [w3]
    ld   1, ac
    ld   ac, [w4]
pwf_s:
    ld   PWADJ >> 8, y
    ld   [w4], ac
    add  PWADJ & 0xFF, x
    ld   [y,x], ac
    add  [w2], ac
    ld   ac, [g_x]
    ld   [w4], ac
    add  (PWADJ & 0xFF) + 5, x
    ld   [y,x], ac
    add  [w3], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL cb_get
    ld   scw_r758, [x]
    ld   LINK_HI, x
    ld   scw_r758 >> 8, [x]
    ld   cb_get >> 8, y
    jmp  cb_get
scw_r758:
    beq  pwf_n
    ld   LINK_LO, x             ; CALL pw_col
    ld   scw_r759, [x]
    ld   LINK_HI, x
    ld   scw_r759 >> 8, [x]
    ld   pw_col >> 8, y
    jmp  pw_col
scw_r759:
    xor  PW_LIVE, ac
    beq  pwf_n
    ld   LINK_LO, x             ; CALL pw_push
    ld   scw_r760, [x]
    ld   LINK_HI, x
    ld   scw_r760 >> 8, [x]
    ld   pw_push >> 8, y
    jmp  pw_push
scw_r760:
pwf_n:
    ld   [w4], ac
    inc
    ld   ac, [w4]
    xor  5, ac
    bne  pwf_s
    bra  pwf_l
pwf_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pw_push - conduit g_x, g_y live, onto the stack (full at RB_VIS: the
; rest of a very big network, 256 cells on, stays dark)
pw_touch:
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
    ld   ac, [T0]
    ld   [g_y], ac
    ld   ac, [T1]
    clr  ac
    ld   ac, [T2]
pwt_l:
    ld   PWADJ >> 8, y
    ld   [T2], ac
    add  PWADJ & 0xFF, x
    ld   [y,x], ac
    add  [T0], ac
    ld   ac, [g_x]
    ld   [T2], ac
    add  (PWADJ & 0xFF) + 5, x
    ld   [y,x], ac
    add  [T1], ac
    ld   ac, [g_y]
    ld   LINK_LO, x             ; CALL map_get
    ld   scw_r762, [x]
    ld   LINK_HI, x
    ld   scw_r762 >> 8, [x]
    ld   map_get >> 8, y
    jmp  map_get
scw_r762:
    xor  T_REACT, ac
    beq  pwt_w
    ld   [c_t], ac
    xor  T_BATT, ac
    bne  pwt_n
    ld   [c_b], ac
    beq  pwt_n
pwt_w:
    ld   [c_f], ac
    sub  8, ac
    bcs  pwt_y
pwt_n:
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  5, ac
    bne  pwt_l
    clr  ac
    bra  pwt_r
pwt_y:
    ld   1, ac
pwt_r:
    ld   ac, [T3]
    ld   [T0], ac
    ld   ac, [g_x]
    ld   [T1], ac
    ld   ac, [g_y]
    ld   [T3], ac
    ld   sc_leave >> 8, y
    jmp  sc_leave

; pw_col - AC = T6 = the colour of cell g_x, g_y's network, PW_LIVE or
; PW_DEAD (its RB_VIS bit: u2:u3, u4).  A leaf

#overlay4 0x4A00
seg:
    ld   SEGT >> 8, y
    ld   [T2], ac
    add  SEGT & 0xFF, x
    ld   [y,x], ac
    ld   ac, [u1]               ; the pixel
    ld   [T2], ac
    add  (SEGT & 0xFF) + 5, x
    ld   [y,x], ac
    ld   ac, [u2]               ; the row (even)
    ld   [T2], ac
    add  (SEGT & 0xFF) + 10, x
    ld   [y,x], ac
    ld   ac, [u5]               ; the steps
    ld   [T2], ac
    add  (SEGT & 0xFF) + 15, x
    ld   [y,x], ac
    ld   ac, [u0]               ; a step across
    ld   [T2], ac
    add  (SEGT & 0xFF) + 20, x
    ld   [y,x], ac
    ld   ac, [u4]               ;   and down
    ld   [dc_cx], ac
    shl
    shl
    shl
    add  0x61, ac
    ld   ac, [u7]               ; the cell's first column's page
pws_l:
    ld   [u1], ac               ; even pixels the high nibble
    and  1, ac
    beq  pws_h
    ld   0xF0, ac
    bra  pws_k
pws_h:
    ld   0x0F, ac
pws_k:
    ld   ac, [u3]               ; the nibble kept
    xor  0xFF, ac
    and  [T6], ac
    ld   ac, [u6]               ; the colour's
    ld   [u1], ac
    and  6, ac
    add  [u7], ac
    ld   ac, y
    ld   [u2], ac               ; rows u2 and u2 + 1
    shl
    add  [dc_base], ac
    ld   ac, x
    ld   [y,x], ac
    and  [u3], ac
    or   [u6], ac
    ld   ac, [y,x]
    ld   [u2], ac
    shl
    add  [dc_base], ac
    add  2, x
    ld   [y,x], ac
    and  [u3], ac
    or   [u6], ac
    ld   ac, [y,x]
    ld   [u1], ac
    add  [u0], ac
    ld   ac, [u1]
    ld   [u2], ac
    add  [u4], ac
    ld   ac, [u2]
    ld   [u5], ac
    dec
    ld   ac, [u5]
    bne  pws_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; PWADJ - the cell and its sides (0 itself, 1 right, 2 left, 3 down, 4
; up): x steps, then y steps.  SEGT - seg's lines for each: the first
; pixel, the first row, the steps, a step's pixels across and rows down
pw_col:
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
    beq  pwl_d
    ld   PW_LIVE, ac
    bra  pwl_s
pwl_d:
    ld   PW_DEAD, ac
pwl_s:
    ld   ac, [T6]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; pw_kind - after map_see: AC 1 when the cell is a powered part that is
; installed (a fixed one, the reactor or a turret, counts), else 0.  A leaf
PWADJ:
    #d8 0, 1, 0xFF, 0, 0
    #d8 0, 0, 0, 1, 0xFF
SEGT:
    #d8 4, 4, 0, 4, 4
    #d8 8, 8, 8, 8, 0
    #d8 1, 4, 5, 4, 5
    #d8 0, 1, 1, 0, 0
    #d8 0, 0, 0, 2, 2

; ============================================================
; SCRAP.INI: the start (scrap.masm's, fl_init from scrap_fl.masm: here
; to leave room in the program), read into x4100-x44FF by start, which
; then works out the rooms over it (#overlay4 too: gen_plc.py --swap
; 0x4100,0x4500,INI,4)
; ============================================================

; cb_init - PW_ST off, the conduits at the start (CB0) set.  The rest
; of pw_start
ov_dot:
    ld   [T7], ac
    bne  pwd_e
    ld   [T3], ac
    beq  pwd_e
    ld   [T5], ac
    ld   ac, [T6]
    clr  ac
    ld   ac, [T2]
    ld   LINK_LO, x             ; CALL seg
    ld   scw_r772, [x]
    ld   LINK_HI, x
    ld   scw_r772 >> 8, [x]
    ld   seg >> 8, y
    jmp  seg
scw_r772:
pwd_e:
    ld   sc_leave >> 8, y
    jmp  sc_leave

; seg - in screen cell dc_cx, dc_cy (dc_base: its first line pair's
; offset), colour T6: the half line to side T2 (PWADJ's: 1 right, 2 left,
; 3 down, 4 up; 0 the middle), SEGT's: pixel 4 down (1 wide), pixels
; 8-9 across (2 high).  A leaf.  u0-u7

#overlay4 0x4B00
pw_kind:
    ld   [c_t], ac
    ld   ac, x
    ld   TAB_PG, y
    ld   [y,x], ac
    and  F_PWR, ac
    beq  pwk_r
    ld   [c_b], ac
    bne  pwk_1
    ld   [y,x], ac
    and  F_ITEM, ac
    bne  pwk_0
pwk_1:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
pwk_0:
    clr  ac
pwk_r:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ov_cell - the power view over screen cell dc_cx, dc_cy: its conduit to
; each side with a conduit or a powered part (T3: a conduit here), or a
; powered part's stub to each side with a conduit (T4), in its network's
; colour (a stub: the conduit's); a conduit alone is a dot.  T0-T7
