; ============================================================
; made by asm_expand.py from lamp.masm: change that file, then run
;     python3 asm_expand.py lamp.masm
; ============================================================

; lamp.asm - LAMPLIGHTER, made by gen_lamp.py from lamp_code.masm: do not edit
;
; platform game on the SD card (a library program in the RAM)
;
;     python3 gen_lamp.py                 writes lamp.asm next to this script,
;                                         ../../sdcard/LAMP.PLC and the files of
;                                         ../../sdcard/LAMP/ (An.TS, Rnn.RM)
;     python3 gen_lamp.py --preview DIR   also draws every room with the Python
;                                         model
;     python3 test_lamp_sim.py            plays it in placard_sim from a card
;
; Wick, a beacon keeper, lands on the hollow moon Cairn after its great lamp
; goes dark and climbs down through it.  The world is rooms of up to 32 x 16
; tiles that scroll both ways, joined at their edges and by doors that a
; shot opens; a central shaft (the Wellshaft) branches into the areas.
; docs/software/LAMPLIGHTER.md has the game and the engine.
;
; SCREEN
;     rows   0-31   1 bpp, 1x   four lines of 80 column text: the room's name,
;                               the energy line
;     rows  32-479  4 bpp, 4x   the playfield: 160 x 112 pixels of 4 x 4,
;                               16 colors: 10 x 7 tiles of 16 x 16
;
; FILES ON THE CARD
;     LAMP.PLC        the program (x0100-x3FFF)
;     LAMP/An.TS      area n's tile set and sprites: 4 pages of tables to
;                     x4000 (tile routine addresses, tile attributes, sprite
;                     routine addresses), then a straight image of the RAM
;                     from x6000: the tile routines and the sprite routines,
;                     in the video RAM the screen leaves free
;     LAMP/Rnn.RM     room nn (hex): the tile map (32 x 16, 512 bytes) to
;                     x4400, then its header (size, exits, name) to x4600
;
; Controls: arrow keys or SNES pad Left / Right to walk, Down to crawl, Z,
; Space or pad B / A to jump (hold for a higher jump), X or pad Y / X to
; fire (hold Up to fire up), Esc back to the DOS.
;
; Date: 11/13/2026

#include "placard.asm"
#include "placard_lib.asm"
dos_back = 0x8008

; ---------------------------------------------------------------------------
; program variables (zero page x20-x8F)
; ---------------------------------------------------------------------------
colpage    = 0x20       ; video page of the column being drawn (x61 + 2 * col)
rl         = 0x21       ; where a tile routine returns
rh         = 0x22
tmp        = 0x23
tmp2       = 0x24
tmp3       = 0x25
sx         = 0x26       ; the camera: byte column and cell of the screen's corner
sy         = 0x27
px         = 0x28       ; the hero: left byte column (the box is px + 1 to px + 6)
py         = 0x29       ;   top cell
pyf        = 0x2A       ;   and 1/256 cell
vyl        = 0x2B       ; vertical speed, cells / 256 a frame, signed
vyh        = 0x2C
onground   = 0x2D
facing     = 0x2E       ; 0 right, 1 left
moving     = 0x2F       ; a walk key is down
inp        = 0x30       ; 1 right, 2 left, 4 jump, 8 fire, 16 up, 32 down
inp_prev   = 0x31
room       = 0x32
area       = 0x33       ; the area whose tiles are loaded (FF: none)
rw         = 0x34       ; the camera's largest sx, sy
rcy        = 0x35
rwx        = 0x36       ; px here: the right edge;  py here: the bottom edge
rhy        = 0x37
crawl      = 0x38
energy     = 0x39
emax       = 0x3A
hud_dirty  = 0x3B
ta_x       = 0x3C       ; tile_at: byte column, cell
ta_y       = 0x3D
ta_a       = 0x3E       ;   the tile's attributes
ta_pg      = 0x3F       ;   its place in the map
ta_i       = 0x40
sl_n       = 0x41       ; sprites in the list
s_i        = 0x42
sc         = 0x43       ; this sprite: byte column + 8, top cell + 32
spy        = 0x44
srl        = 0x45       ; where a sprite routine returns
srh        = 0x46
fcnt       = 0x47       ; frames
vpg        = 0x48       ; x48-x4F: video page of each of the sprite's 8 columns
ROWT       = 0x50       ; x50-x5F: video offset of each of the tile row's 16 cells
rowb       = 0x60       ; ROWX index of the tile row's first cell
mrow       = 0x61       ; the tile row's first map byte
mpg        = 0x62
mx         = 0x63
j0         = 0x64       ; the first tile's first byte column
o_i        = 0x65
SH_T       = 0x66       ; shots (3): frames left, byte column, cell, speeds
SH_X       = 0x69
SH_Y       = 0x6C
SH_DX      = 0x6F
SH_DY      = 0x72
door_t     = 0x75       ; frames the open door stays open (0: none)
door_pg    = 0x76       ;   its upper tile in the map
door_i     = 0x77
door_x     = 0x78       ;   its byte column
ex_side    = 0x79
ex_pos     = 0x7A
ex_i       = 0x7B
ex_d       = 0x7C
sv_lo      = 0x7D       ; side_free's return address
sv_hi      = 0x7E
items      = 0x7F
tcnt       = 0x80       ; byte columns left of the tile being drawn

MODE_PF     = 10
LINE_GO     = 240
GRAV        = 40
JUMPV_LO    = 0
JUMPV_HI    = 252
MAXFALL_HI  = 4
SHOT_FRAMES = 30
DOOR_FRAMES = 150
CAM_X       = 36
CAM_Y       = 48
START_ROOM  = 0
START_X     = 24
START_Y     = 80
START_ENERGY = 30
IN_RIGHT    = 1
IN_LEFT     = 2
IN_JUMP     = 4
IN_FIRE     = 8
IN_UP       = 16
IN_DOWN     = 32
A_DOOR      = 4
A_DBOT      = 64
EX_L        = 1
EX_R        = 2
EX_U        = 3
EX_D        = 4
TS_LO       = 16384
TS_HI       = 16640
ATTR        = 16896
FR          = 17152
TABLES_END  = 17408
MAP         = 17408
HDR         = 17920
SL          = 21504
SL_LO       = 0
SL_HI       = 16
SL_C        = 32
SL_G        = 48
H_AREA      = 2
H_RW        = 4
H_RCY       = 5
H_RWX       = 6
H_RHY       = 7
HX_SIDE     = 16
HX_LO       = 24
HX_HI       = 32
HX_DEST     = 40
HX_DELTA    = 48
H_NAME      = 128
T_DT        = 8
T_DB        = 16
T_DOT       = 24
T_DOB       = 32
NPF         = 5
F_RUN1      = 1
F_JUMP      = 3
F_CRAWL     = 4
F_SHOT      = 10
; ============================================================
; lamp_code.masm - LAMPLIGHTER's code.  gen_lamp.py puts the constants
; and the zero page in front of it, fills in the marked parts (tables
; and unrolled loops) and runs asm_expand over it: lamp.asm.
;
; The frame (docs/software/LAMPLIGHTER.md, "How it draws"):
;   frame      wait until the beam is in the playfield's last tile row
;   draw_bg    the playfield from the tile map, tile row by tile row from
;              the top (map FF: the tile routines are in the video RAM)
;   draw_spr   the sprite list over it
;   logic      sound, pads, keys, the rules, the sprite list, the text
; ============================================================



#addr 0x0100
; ROWX: video offset (low byte) of top cell + 32, x10 off the playfield
ROWX:
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0xC0, 0xC4, 0xC8, 0xCC, 0xD0, 0xD4, 0xD8, 0xDC, 0xE0, 0xE4, 0xE8, 0xEC, 0xF0, 0xF4, 0xF8, 0xFC
    #d8 0x81, 0x85, 0x89, 0x8D, 0x91, 0x95, 0x99, 0x9D, 0xA1, 0xA5, 0xA9, 0xAD, 0xB1, 0xB5, 0xB9, 0xBD
    #d8 0xC1, 0xC5, 0xC9, 0xCD, 0xD1, 0xD5, 0xD9, 0xDD, 0xE1, 0xE5, 0xE9, 0xED, 0xF1, 0xF5, 0xF9, 0xFD
    #d8 0x82, 0x86, 0x8A, 0x8E, 0x92, 0x96, 0x9A, 0x9E, 0xA2, 0xA6, 0xAA, 0xAE, 0xB2, 0xB6, 0xBA, 0xBE
    #d8 0xC2, 0xC6, 0xCA, 0xCE, 0xD2, 0xD6, 0xDA, 0xDE, 0xE2, 0xE6, 0xEA, 0xEE, 0xF2, 0xF6, 0xFA, 0xFE
    #d8 0x83, 0x87, 0x8B, 0x8F, 0x93, 0x97, 0x9B, 0x9F, 0xA3, 0xA7, 0xAB, 0xAF, 0xB3, 0xB7, 0xBB, 0xBF
    #d8 0xC3, 0xC7, 0xCB, 0xCF, 0xD3, 0xD7, 0xDB, 0xDF, 0xE3, 0xE7, 0xEB, 0xEF, 0xF3, 0xF7, 0xFB, 0xFF
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10
    #d8 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10

; VPG: video page of byte column + 8, x60 off the screen
VPG:
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x61, 0x63, 0x65, 0x67, 0x69, 0x6B, 0x6D, 0x6F
    #d8 0x71, 0x73, 0x75, 0x77, 0x79, 0x7B, 0x7D, 0x7F, 0x81, 0x83, 0x85, 0x87, 0x89, 0x8B, 0x8D, 0x8F
    #d8 0x91, 0x93, 0x95, 0x97, 0x99, 0x9B, 0x9D, 0x9F, 0xA1, 0xA3, 0xA5, 0xA7, 0xA9, 0xAB, 0xAD, 0xAF
    #d8 0xB1, 0xB3, 0xB5, 0xB7, 0xB9, 0xBB, 0xBD, 0xBF, 0xC1, 0xC3, 0xC5, 0xC7, 0xC9, 0xCB, 0xCD, 0xCF
    #d8 0xD1, 0xD3, 0xD5, 0xD7, 0xD9, 0xDB, 0xDD, 0xDF, 0xE1, 0xE3, 0xE5, 0xE7, 0xE9, 0xEB, 0xED, 0xEF
    #d8 0xF1, 0xF3, 0xF5, 0xF7, 0xF9, 0xFB, 0xFD, 0xFF, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60
    #d8 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60

; ------------------------------------------------------------
; main
; ------------------------------------------------------------
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL con_clear
    ld   lp_r1, [x]
    ld   LINK_HI, x
    ld   lp_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
lp_r1:
    ld   LINK_LO, x             ; CALL snd_init
    ld   lp_r2, [x]
    ld   LINK_HI, x
    ld   lp_r2 >> 8, [x]
    ld   snd_init >> 8, y
    jmp  snd_init
lp_r2:
    ld   0x5A, y                ; rows 32-479 (x5A40-x5BFF): 4 bpp 4x
    ld   0x40, ac
m_mb1:
    ld   ac, x
    ld   MODE_PF, [y,x]
    inc
    bne  m_mb1
    ld   0x5B, y
m_mb2:
    ld   ac, x
    ld   MODE_PF, [y,x]
    inc
    bne  m_mb2
    ld   0x20, ac               ; program variables x20-x8F = 0
m_z:
    ld   ac, x
    ld   0, [x]
    inc
    xor  0x90, ac
    beq  m_z1
    xor  0x90, ac
    bra  m_z
m_z1:
    ld   0xFF, ac               ; no area loaded
    ld   ac, [area]
    ld   START_ROOM, ac
    ld   ac, [room]
    ld   START_X, ac
    ld   ac, [px]
    ld   START_Y, ac
    ld   ac, [py]
    ld   START_ENERGY, ac
    ld   ac, [energy]
    ld   ac, [emax]
    ld   LINK_LO, x             ; CALL load_room
    ld   lp_r3, [x]
    ld   LINK_HI, x
    ld   lp_r3 >> 8, [x]
    ld   load_room >> 8, y
    jmp  load_room
lp_r3:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r4, [x]
    ld   LINK_HI, x
    ld   lp_r4 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r4:
    ld   frame >> 8, y
    jmp  frame

; ------------------------------------------------------------
; frame: wait for the beam, then draw behind it
; ------------------------------------------------------------
frame:
    ld   LINK_LO, x             ; AC = the line (V9:V2)
    ld   lp_r5, [x]
    ld   LINK_HI, x
    ld   lp_r5 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
lp_r5:
    sub  LINE_GO, ac
    bcs  frame
frame_go:
    ld   0x50, y                ; map FF: the tile and sprite routines are in
    ld   0xFF, [y,x]            ; the video RAM
    ld   [sy], ac               ; the first tile row's top: ROWX index 32 - (sy & 15)
    and  15, ac
    ld   ac, [tmp]
    ld   32, ac
    sub  [tmp], ac
    ld   ac, [rowb]
    ld   [sx], ac               ; the first tile's first byte column
    and  7, ac
    ld   ac, [j0]
    ld   [sx], ac               ; map byte of the first tile: (ty << 5) | tx
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [tmp]
    ld   [sy], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [tmp2]
    and  7, ac
    shl
    shl
    shl
    shl
    shl
    or   [tmp], ac
    ld   ac, [mrow]
    ld   [tmp2], ac
    shr  ac
    shr  ac
    shr  ac
    add  MAP >> 8, ac
    ld   ac, [mpg]
    ld   t_ret & 0xFF, ac       ; every tile routine comes back to t_ret
    ld   ac, [rl]
    ld   t_ret >> 8, ac
    ld   ac, [rh]
    ld   bg_row >> 8, y
    jmp  bg_row

find_exit:
    clr  ac
    ld   ac, [ex_i]
fe_lp:
    ld   HDR >> 8, y
    ld   [ex_i], ac
    add  HX_SIDE, x
    ld   [y,x], ac
    xor  [ex_side], ac
    bne  fe_nx
    ld   [ex_i], ac
    add  HX_LO, x
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [ex_pos], ac
    sub  [T0], ac
    bcs  fe_nx
    ld   [ex_i], ac
    add  HX_HI, x
    ld   [y,x], ac
    sub  [ex_pos], ac
    bcs  fe_nx
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
fe_nx:
    ld   [ex_i], ac
    inc
    ld   ac, [ex_i]
    xor  8, ac
    bne  fe_lp
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; do_exit: through exit ex_i into its room (the frame ends here)
; ------------------------------------------------------------

#addr 0x0400
bg_row:
    ld   ROWX >> 8, y           ; the video offsets of this tile row's 16 cells
    ld   [rowb], x
    ld   [y,x], ac
    ld   ac, [ROWT + 0]
    ld   [rowb], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [ROWT + 1]
    ld   [rowb], ac
    add  2, x
    ld   [y,x], ac
    ld   ac, [ROWT + 2]
    ld   [rowb], ac
    add  3, x
    ld   [y,x], ac
    ld   ac, [ROWT + 3]
    ld   [rowb], ac
    add  4, x
    ld   [y,x], ac
    ld   ac, [ROWT + 4]
    ld   [rowb], ac
    add  5, x
    ld   [y,x], ac
    ld   ac, [ROWT + 5]
    ld   [rowb], ac
    add  6, x
    ld   [y,x], ac
    ld   ac, [ROWT + 6]
    ld   [rowb], ac
    add  7, x
    ld   [y,x], ac
    ld   ac, [ROWT + 7]
    ld   [rowb], ac
    add  8, x
    ld   [y,x], ac
    ld   ac, [ROWT + 8]
    ld   [rowb], ac
    add  9, x
    ld   [y,x], ac
    ld   ac, [ROWT + 9]
    ld   [rowb], ac
    add  10, x
    ld   [y,x], ac
    ld   ac, [ROWT + 10]
    ld   [rowb], ac
    add  11, x
    ld   [y,x], ac
    ld   ac, [ROWT + 11]
    ld   [rowb], ac
    add  12, x
    ld   [y,x], ac
    ld   ac, [ROWT + 12]
    ld   [rowb], ac
    add  13, x
    ld   [y,x], ac
    ld   ac, [ROWT + 13]
    ld   [rowb], ac
    add  14, x
    ld   [y,x], ac
    ld   ac, [ROWT + 14]
    ld   [rowb], ac
    add  15, x
    ld   [y,x], ac
    ld   ac, [ROWT + 15]
    ld   0x61, ac
    ld   ac, [colpage]
    ld   8, ac                  ; the first tile: from byte column j0
    sub  [j0], ac
    ld   ac, [tcnt]
    ld   [mrow], ac
    ld   ac, [mx]
    ld   ac, x
    ld   [mpg], y
    ld   [y,x], ac
    or   [j0], ac
    bra  t_go
t_ret:
    bcs  row_done               ; past column 79
    ld   8, ac
    ld   ac, [tcnt]
    ld   [mx], ac               ; the next tile
    inc
    ld   ac, [mx]
    ld   ac, x
    ld   [mpg], y
    ld   [y,x], ac
t_go:
    ld   ac, x                  ; its routine for that byte column
    ld   TS_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   TS_HI >> 8, y
    ld   [y,x], ac
    ld   ac, y
    ld   [tmp], ac
    jmp  ac
row_done:
    ld   [rowb], ac             ; the next tile row, while it is on the screen
    add  16, ac
    ld   ac, [rowb]
    sub  144, ac
    bcc  bg_done
    ld   [mrow], ac
    add  32, ac
    ld   ac, [mrow]
    bcc  bg_row
    ld   [mpg], ac
    inc
    ld   ac, [mpg]
    bra  bg_row
bg_done:
    ld   draw_spr >> 8, y
    jmp  draw_spr

; ------------------------------------------------------------
; draw_spr: draw the sprite list (still map FF), then the map back
; ------------------------------------------------------------
logic:
    ld   LINK_LO, x             ; CALL snd_update
    ld   lp_r6, [x]
    ld   LINK_HI, x
    ld   lp_r6 >> 8, [x]
    ld   snd_update >> 8, y
    jmp  snd_update
lp_r6:
    ld   LINK_LO, x             ; CALL pad_read
    ld   lp_r7, [x]
    ld   LINK_HI, x
    ld   lp_r7 >> 8, [x]
    ld   pad_read >> 8, y
    jmp  pad_read
lp_r7:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   lp_r8, [x]
    ld   LINK_HI, x
    ld   lp_r8 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
lp_r8:
    ld   LINK_LO, x             ; (Esc: back to the DOS)
    ld   lp_r9, [x]
    ld   LINK_HI, x
    ld   lp_r9 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
lp_r9:
    ld   [inp], ac
    ld   ac, [inp_prev]
    clr  ac
    ld   ac, [inp]
    ld   read_input >> 8, y
    jmp  read_input


#addr 0x0500
draw_spr:
    ld   ds_next & 0xFF, ac     ; every sprite routine returns to ds_next
    ld   ac, [srl]
    ld   ds_next >> 8, ac
    ld   ac, [srh]
    clr  ac
    ld   ac, [s_i]
ds_next:
    ld   [s_i], ac
    sub  [sl_n], ac
    bne  ds_one
    ld   0x50, y                ; done: map 07 (the library)
    ld   0x07, [y,x]
    ld   logic >> 8, y
    jmp  logic
ds_one:
    ld   SL >> 8, y
    ld   [s_i], ac
    add  SL_C, x
    ld   [y,x], ac
    ld   ac, [sc]
    ld   [s_i], ac
    add  SL_G, x
    ld   [y,x], ac
    ld   ac, [spy]
    ld   [s_i], ac
    add  SL_HI, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [s_i], ac
    add  SL_LO, x
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   VPG >> 8, y
    ld   [sc], ac
    add  0, x
    ld   [y,x], ac
    ld   ac, [vpg + 0]
    ld   [sc], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [vpg + 1]
    ld   [sc], ac
    add  2, x
    ld   [y,x], ac
    ld   ac, [vpg + 2]
    ld   [sc], ac
    add  3, x
    ld   [y,x], ac
    ld   ac, [vpg + 3]
    ld   [sc], ac
    add  4, x
    ld   [y,x], ac
    ld   ac, [vpg + 4]
    ld   [sc], ac
    add  5, x
    ld   [y,x], ac
    ld   ac, [vpg + 5]
    ld   [sc], ac
    add  6, x
    ld   [y,x], ac
    ld   ac, [vpg + 6]
    ld   [sc], ac
    add  7, x
    ld   [y,x], ac
    ld   ac, [vpg + 7]
    ld   [s_i], ac
    inc
    ld   ac, [s_i]
    ld   [tmp], y
    ld   [tmp2], ac
    jmp  ac

; ------------------------------------------------------------
; logic: sound, input
; ------------------------------------------------------------
game:
    ld   [fcnt], ac
    inc
    ld   ac, [fcnt]
    ld   [inp], ac              ; Down on the ground: crawl
    and  IN_DOWN, ac
    beq  gc_up
    ld   [onground], ac
    beq  gc_up
    ld   1, ac
    ld   ac, [crawl]
    bra  gc_done
gc_up:
    ld   [crawl], ac
    beq  gc_done
    ld   [py], ac               ; stand up when the upper half is free
    ld   ac, [ta_y]
    ld   [px], ac
    inc
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r10, [x]
    ld   LINK_HI, x
    ld   lp_r10 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r10:
    bne  gc_done
    ld   [px], ac
    add  6, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r11, [x]
    ld   LINK_HI, x
    ld   lp_r11 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r11:
    bne  gc_done
    clr  ac
    ld   ac, [crawl]
gc_done:
    ld   g_horiz >> 8, y
    jmp  g_horiz

; ------------------------------------------------------------
; game: sideways
; ------------------------------------------------------------
camera:
    ld   [px], ac
    sub  CAM_X, ac
    bcc  cm_1
    clr  ac
cm_1:
    ld   ac, [sx]
    ld   [rw], ac
    sub  [sx], ac
    bcc  cm_2
    ld   [rw], ac
    ld   ac, [sx]
cm_2:
    ld   [py], ac
    sub  CAM_Y, ac
    bcc  cm_3
    clr  ac
cm_3:
    ld   ac, [sy]
    ld   [rcy], ac
    sub  [sy], ac
    bcc  cm_4
    ld   [rcy], ac
    ld   ac, [sy]
cm_4:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; game: the camera, the shots
; ------------------------------------------------------------

#addr 0x0600
read_input:
    ld   [R0], ac
    and  0x80, ac
    beq  in_1
    ld   [inp], ac
    or   1, ac
    ld   ac, [inp]
in_1:
    ld   [R0], ac
    and  0x40, ac
    beq  in_2
    ld   [inp], ac
    or   2, ac
    ld   ac, [inp]
in_2:
    ld   [R0], ac
    and  0x10, ac
    beq  in_3
    ld   [inp], ac
    or   16, ac
    ld   ac, [inp]
in_3:
    ld   [R0], ac
    and  0x20, ac
    beq  in_4
    ld   [inp], ac
    or   32, ac
    ld   ac, [inp]
in_4:
    ld   [R0], ac
    and  0x01, ac
    bne  in_5_s
    ld   [R1], ac
    and  0x01, ac
    beq  in_5
in_5_s:
    ld   [inp], ac
    or   4, ac
    ld   ac, [inp]
in_5:
    ld   [R0], ac
    and  0x02, ac
    bne  in_6_s
    ld   [R1], ac
    and  0x02, ac
    beq  in_6
in_6_s:
    ld   [inp], ac
    or   8, ac
    ld   ac, [inp]
in_6:
    ld   [KBD_NOW + 7], ac
    and  0x80, ac
    bne  in_7
    ld   [inp], ac
    or   1, ac
    ld   ac, [inp]
in_7:
    ld   [KBD_NOW + 7], ac
    and  0x20, ac
    bne  in_8
    ld   [inp], ac
    or   2, ac
    ld   ac, [inp]
in_8:
    ld   [KBD_NOW + 6], ac
    and  0x20, ac
    bne  in_9
    ld   [inp], ac
    or   16, ac
    ld   ac, [inp]
in_9:
    ld   [KBD_NOW + 7], ac
    and  0x40, ac
    bne  in_10
    ld   [inp], ac
    or   32, ac
    ld   ac, [inp]
in_10:
    ld   [KBD_NOW + 7], ac
    and  0x04, ac
    bne  in_11
    ld   [inp], ac
    or   4, ac
    ld   ac, [inp]
in_11:
    ld   [KBD_NOW + 5], ac
    and  0x04, ac
    bne  in_12
    ld   [inp], ac
    or   4, ac
    ld   ac, [inp]
in_12:
    ld   [KBD_NOW + 5], ac
    and  0x08, ac
    bne  in_13
    ld   [inp], ac
    or   8, ac
    ld   ac, [inp]
in_13:
    ld   game >> 8, y
    jmp  game

; ------------------------------------------------------------
; game: crawling
; ------------------------------------------------------------
g_horiz:
    clr  ac
    ld   ac, [moving]
    ld   [inp], ac
    and  IN_RIGHT, ac
    beq  gh_1
    clr  ac
    ld   ac, [facing]
    ld   1, ac
    ld   ac, [moving]
    bra  gh_gate
gh_1:
    ld   [inp], ac
    and  IN_LEFT, ac
    beq  gh_none
    ld   1, ac
    ld   ac, [facing]
    ld   ac, [moving]
gh_gate:
    ld   [crawl], ac            ; a step 3 frames of 4; crawling, every other
    bne  gh_slow
    ld   [fcnt], ac
    and  3, ac
    xor  3, ac
    beq  gh_none
    bra  gh_go
gh_slow:
    ld   [fcnt], ac
    and  1, ac
    beq  gh_none
gh_go:
    ld   [facing], ac
    bne  gh_left
    ld   g_right >> 8, y
    jmp  g_right
gh_left:
    ld   g_left >> 8, y
    jmp  g_left
gh_none:
    ld   g_jump >> 8, y
    jmp  g_jump


#addr 0x0700
g_right:
    ld   [px], ac               ; a wall at byte column px + 7?
    add  7, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL side_free
    ld   lp_r12, [x]
    ld   LINK_HI, x
    ld   lp_r12 >> 8, [x]
    ld   side_free >> 8, y
    jmp  side_free
lp_r12:
    bne  gr_no
    ld   [px], ac
    inc
    ld   ac, [px]
    sub  [rwx], ac
    bcs  gr_no
    ld   [py], ac               ; at the right edge: an exit?
    add  8, ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [ex_pos]
    ld   EX_R, ac
    ld   ac, [ex_side]
    ld   LINK_LO, x             ; CALL find_exit
    ld   lp_r13, [x]
    ld   LINK_HI, x
    ld   lp_r13 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r13:
    bne  gr_exit
    ld   [px], ac               ; none: back
    dec
    ld   ac, [px]
gr_no:
    ld   g_jump >> 8, y
    jmp  g_jump
gr_exit:
    ld   do_exit >> 8, y
    jmp  do_exit

g_left:
    ld   [px], ac
    bne  gl_1
    ld   [py], ac               ; at the left edge: an exit?
    add  8, ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [ex_pos]
    ld   EX_L, ac
    ld   ac, [ex_side]
    ld   LINK_LO, x             ; CALL find_exit
    ld   lp_r14, [x]
    ld   LINK_HI, x
    ld   lp_r14 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r14:
    beq  gl_no
    ld   do_exit >> 8, y
    jmp  do_exit
gl_1:
    ld   ac, [ta_x]             ; a wall at byte column px?
    ld   LINK_LO, x             ; CALL side_free
    ld   lp_r15, [x]
    ld   LINK_HI, x
    ld   lp_r15 >> 8, [x]
    ld   side_free >> 8, y
    jmp  side_free
lp_r15:
    bne  gl_no
    ld   [px], ac
    dec
    ld   ac, [px]
gl_no:
    ld   g_jump >> 8, y
    jmp  g_jump

; side_free: AC = 0 when byte column ta_x is open beside the hero
side_free:
    ld   [LINK_LO], ac
    ld   ac, [sv_lo]
    ld   [LINK_HI], ac
    ld   ac, [sv_hi]
    ld   [crawl], ac
    bne  sf_low
    ld   [py], ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r16, [x]
    ld   LINK_HI, x
    ld   lp_r16 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r16:
    bne  sf_out
sf_low:
    ld   [py], ac
    add  8, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r17, [x]
    ld   LINK_HI, x
    ld   lp_r17 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r17:
    bne  sf_out
    ld   [py], ac
    add  15, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r18, [x]
    ld   LINK_HI, x
    ld   lp_r18 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r18:
sf_out:
    ld   ac, [tmp]
    ld   [sv_lo], ac
    ld   ac, [LINK_LO]
    ld   [sv_hi], ac
    ld   ac, [LINK_HI]
    ld   [tmp], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; tile_at: AC = 0 when cell ta_y of byte column ta_x is open; ta_a = the
; tile's attributes, ta_pg / ta_i = its place in the map.  Changes X, Y, T0.

#addr 0x0800
tile_at:
    ld   [ta_y], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T0]
    shr  ac
    shr  ac
    shr  ac
    add  MAP >> 8, ac
    ld   ac, [ta_pg]
    ld   ac, y
    ld   [T0], ac
    and  7, ac
    shl
    shl
    shl
    shl
    shl
    ld   ac, [T0]
    ld   [ta_x], ac
    shr  ac
    shr  ac
    shr  ac
    or   [T0], ac
    ld   ac, [ta_i]
    ld   ac, x
    ld   [y,x], ac
    ld   ac, x
    ld   ATTR >> 8, y
    ld   [y,x], ac
    ld   ac, [ta_a]
    ld   [ta_y], ac
    and  8, ac
    bne  ta_low
    ld   [ta_a], ac
    and  1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ta_low:
    ld   [ta_a], ac
    and  2, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; find_exit: AC = 0 when the room has no exit on side ex_side at tile
; ex_pos; else ex_i = the exit
do_exit:
    ld   HDR >> 8, y
    ld   [ex_i], ac
    add  HX_DELTA, x
    ld   [y,x], ac
    ld   ac, [ex_d]
    ld   [ex_i], ac
    add  HX_DEST, x
    ld   [y,x], ac
    ld   ac, [room]
    ld   LINK_LO, x             ; CALL load_room
    ld   lp_r19, [x]
    ld   LINK_HI, x
    ld   lp_r19 >> 8, [x]
    ld   load_room >> 8, y
    jmp  load_room
lp_r19:
    ld   [ex_side], ac
    xor  EX_L, ac
    beq  de_l
    xor  3, ac                  ; (EX_L ^ EX_R)
    beq  de_r
    xor  1, ac                  ; (EX_R ^ EX_U)
    beq  de_u
    clr  ac                     ; down: in at the top
    ld   ac, [py]
    bra  de_v
de_u:
    ld   [rhy], ac              ; up: in at the bottom
    dec
    ld   ac, [py]
de_v:
    clr  ac
    ld   ac, [pyf]
    ld   [ex_d], ac
    shl
    shl
    shl
    add  [px], ac
    ld   ac, [px]
    ld   de_done >> 8, y
    jmp  de_done
de_l:
    ld   [rwx], ac              ; left: in at the right edge
    dec
    ld   ac, [px]
    sub  7, ac
    ld   ac, [ta_x]
    bra  de_h
de_r:
    ld   1, ac                  ; right: in at the left edge
    ld   ac, [px]
    ld   8, ac
    ld   ac, [ta_x]
de_h:
    ld   [ex_d], ac
    shl
    shl
    shl
    shl
    add  [py], ac
    ld   ac, [py]
    add  8, ac                  ; a door in the way opens
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r20, [x]
    ld   LINK_HI, x
    ld   lp_r20 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r20:
    ld   [ta_a], ac
    and  A_DOOR, ac
    beq  de_done
    ld   LINK_LO, x             ; CALL open_door
    ld   lp_r21, [x]
    ld   LINK_HI, x
    ld   lp_r21 >> 8, [x]
    ld   open_door >> 8, y
    jmp  open_door
lp_r21:
de_done:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r22, [x]
    ld   LINK_HI, x
    ld   lp_r22 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r22:
    ld   g_spr >> 8, y
    jmp  g_spr

; open_door: open the door whose tile tile_at just found (ta_a, ta_pg,
; ta_i), shutting the one that is open

#addr 0x0900
open_door:
    ld   [door_t], ac
    beq  od_0
    ld   [door_pg], y           ; shut the other door
    ld   [door_i], x
    ld   T_DT, [y,x]
    ld   [door_i], ac
    add  32, ac
    ld   ac, x
    bcc  od_c1
    ld   [door_pg], ac
    inc
    ld   ac, y
od_c1:
    ld   T_DB, [y,x]
od_0:
    ld   [ta_a], ac             ; hit in its lower tile: the upper one is a row up
    and  A_DBOT, ac
    beq  od_top
    ld   [ta_i], ac
    sub  32, ac
    ld   ac, [ta_i]
    bcc  od_top
    ld   [ta_pg], ac
    dec
    ld   ac, [ta_pg]
od_top:
    ld   [ta_pg], ac
    ld   ac, [door_pg]
    ld   ac, y
    ld   [ta_i], ac
    ld   ac, [door_i]
    ld   ac, x
    ld   T_DOT, [y,x]
    add  32, ac
    ld   ac, x
    bcc  od_1
    ld   [door_pg], ac
    inc
    ld   ac, y
od_1:
    ld   T_DOB, [y,x]
    ld   DOOR_FRAMES, ac
    ld   ac, [door_t]
    ld   [door_i], ac
    and  31, ac
    shl
    shl
    shl
    ld   ac, [door_x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; game: jumping and gravity
; ------------------------------------------------------------
g_jump:
    ld   [inp], ac
    and  IN_JUMP, ac
    beq  gj_no
    ld   [inp_prev], ac         ; a new press, on the ground, not crawling
    and  IN_JUMP, ac
    bne  gj_grav
    ld   [onground], ac
    beq  gj_grav
    ld   [crawl], ac
    bne  gj_grav
    ld   JUMPV_LO, ac
    ld   ac, [vyl]
    ld   JUMPV_HI, ac
    ld   ac, [vyh]
    ld   72, ac
    ld   LINK_LO, x             ; CALL snd_beep
    ld   lp_r23, [x]
    ld   LINK_HI, x
    ld   lp_r23 >> 8, [x]
    ld   snd_beep >> 8, y
    jmp  snd_beep
lp_r23:
    bra  gj_grav
gj_no:
    ld   [vyh], ac              ; the key let go: a fast rise is cut to 1 cell a frame
    blt  gj_c1
    bra  gj_grav
gj_c1:
    xor  0xFF, ac
    beq  gj_grav
    ld   0xFF, ac
    ld   ac, [vyh]
    clr  ac
    ld   ac, [vyl]
gj_grav:
    ld   [vyl], ac              ; gravity
    add  GRAV, ac
    ld   ac, [vyl]
    ld   [vyh], ac
    bcc  gj_g1
    inc
gj_g1:
    ld   ac, [vyh]
    blt  gj_move
    sub  MAXFALL_HI, ac
    bcs  gj_move
    ld   MAXFALL_HI, ac
    ld   ac, [vyh]
    clr  ac
    ld   ac, [vyl]
gj_move:
    ld   [py], ac               ; y += vy
    ld   ac, [tmp2]
    ld   [pyf], ac
    add  [vyl], ac
    ld   ac, [pyf]
    ld   [py], ac
    bcc  gj_m1
    inc
gj_m1:
    add  [vyh], ac
    ld   ac, [py]
    ld   [vyh], ac
    blt  gj_up
    ld   g_down >> 8, y
    jmp  g_down
gj_up:
    ld   g_up >> 8, y
    jmp  g_up

g_door:
    ld   [door_t], ac
    beq  gd_x
    dec
    ld   ac, [door_t]
    bne  gd_x
    ld   [px], ac               ; in the doorway: wait
    sub  [door_x], ac
    add  6, ac
    sub  13, ac
    bcs  gd_hold
    ld   [door_pg], y
    ld   [door_i], x
    ld   T_DT, [y,x]
    ld   [door_i], ac
    add  32, ac
    ld   ac, x
    bcc  gd_c1
    ld   [door_pg], ac
    inc
    ld   ac, y
gd_c1:
    ld   T_DB, [y,x]
    bra  gd_x
gd_hold:
    ld   1, ac
    ld   ac, [door_t]
gd_x:
    ld   g_spr >> 8, y
    jmp  g_spr

; ------------------------------------------------------------
; game: the sprite list
; ------------------------------------------------------------

#addr 0x0A00
g_up:
    clr  ac
    ld   ac, [onground]
    ld   [tmp2], ac             ; past the top (py wrapped)?
    sub  [py], ac
    bcs  gu_wrap
    ld   [crawl], ac            ; the head in a solid tile?
    shl
    shl
    shl
    add  [py], ac
    ld   ac, [ta_y]
    ld   [px], ac
    inc
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r24, [x]
    ld   LINK_HI, x
    ld   lp_r24 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r24:
    bne  gu_bump
    ld   [px], ac
    add  6, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r25, [x]
    ld   LINK_HI, x
    ld   lp_r25 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r25:
    beq  gu_free
gu_bump:
    ld   [ta_y], ac             ; below that half tile
    and  0xF8, ac
    add  8, ac
    ld   ac, [py]
    ld   [crawl], ac
    beq  gu_b1
    ld   [py], ac
    sub  8, ac
    ld   ac, [py]
gu_b1:
    clr  ac
    ld   ac, [pyf]
    ld   ac, [vyl]
    ld   ac, [vyh]
gu_free:
    ld   g_post >> 8, y
    jmp  g_post
gu_wrap:
    ld   [px], ac               ; an exit above?
    add  4, ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [ex_pos]
    ld   EX_U, ac
    ld   ac, [ex_side]
    ld   LINK_LO, x             ; CALL find_exit
    ld   lp_r26, [x]
    ld   LINK_HI, x
    ld   lp_r26 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r26:
    beq  gu_top
    ld   do_exit >> 8, y
    jmp  do_exit
gu_top:
    clr  ac                     ; none: stop at the top
    ld   ac, [py]
    bra  gu_b1

g_down:
    ld   [py], ac               ; at the bottom edge?
    sub  [rhy], ac
    bcs  gd_in
    ld   [px], ac               ; an exit below?
    add  4, ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [ex_pos]
    ld   EX_D, ac
    ld   ac, [ex_side]
    ld   LINK_LO, x             ; CALL find_exit
    ld   lp_r27, [x]
    ld   LINK_HI, x
    ld   lp_r27 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r27:
    beq  gd_floor
    ld   do_exit >> 8, y
    jmp  do_exit
gd_floor:
    ld   [rhy], ac
    ld   ac, [py]
    bra  gd_landed
gd_in:
    ld   [py], ac               ; the feet on a solid half tile?
    add  16, ac
    ld   ac, [ta_y]
    ld   [px], ac
    inc
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r28, [x]
    ld   LINK_HI, x
    ld   lp_r28 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r28:
    bne  gd_land
    ld   [px], ac
    add  6, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r29, [x]
    ld   LINK_HI, x
    ld   lp_r29 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r29:
    bne  gd_land
    clr  ac
    ld   ac, [onground]
    ld   g_post >> 8, y
    jmp  g_post
gd_land:
    ld   [ta_y], ac
    and  0xF8, ac
    sub  16, ac
    ld   ac, [py]
gd_landed:
    clr  ac
    ld   ac, [pyf]
    ld   ac, [vyl]
    ld   ac, [vyh]
    ld   1, ac
    ld   ac, [onground]
    ld   g_post >> 8, y
    jmp  g_post

; camera: sx, sy from the hero's place

#addr 0x0B00
g_post:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r30, [x]
    ld   LINK_HI, x
    ld   lp_r30 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r30:
    clr  ac
    ld   ac, [o_i]
gs_lp:
    ld   [o_i], ac
    add  SH_T, x
    ld   [x], ac
    bne  gs_live
gs_nx:
    ld   [o_i], ac
    inc
    ld   ac, [o_i]
    xor  3, ac
    bne  gs_lp
    ld   g_fire >> 8, y
    jmp  g_fire
gs_live:
    dec
    ld   ac, [x]
    beq  gs_nx
    ld   [o_i], ac              ; x += dx, y += dy
    add  SH_DX, x
    ld   [x], ac
    ld   ac, [tmp]
    ld   [o_i], ac
    add  SH_X, x
    ld   [x], ac
    add  [tmp], ac
    ld   ac, [x]
    ld   ac, [ta_x]
    ld   [o_i], ac
    add  SH_DY, x
    ld   [x], ac
    ld   ac, [tmp]
    ld   [o_i], ac
    add  SH_Y, x
    ld   [x], ac
    add  [tmp], ac
    ld   ac, [x]
    ld   ac, [ta_y]
    ld   gs_test >> 8, y
    jmp  gs_test

gs_test:
    ld   [ta_x], ac             ; off the screen: gone
    sub  [sx], ac
    sub  80, ac
    bcc  gs_kill
    ld   [ta_y], ac
    sub  [sy], ac
    sub  112, ac
    bcc  gs_kill
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r31, [x]
    ld   LINK_HI, x
    ld   lp_r31 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r31:
    beq  gs_keep
    ld   [ta_a], ac             ; a wall stops it; a door opens
    and  A_DOOR, ac
    beq  gs_kill
    ld   LINK_LO, x             ; CALL open_door
    ld   lp_r32, [x]
    ld   LINK_HI, x
    ld   lp_r32 >> 8, [x]
    ld   open_door >> 8, y
    jmp  open_door
lp_r32:
    ld   8, ac
    ld   ac, [R0]
    ld   10, ac
    ld   ac, [R2]
    ld   6, ac
    ld   ac, [R3]
    ld   60, ac
    ld   LINK_LO, x             ; CALL snd_noise
    ld   lp_r33, [x]
    ld   LINK_HI, x
    ld   lp_r33 >> 8, [x]
    ld   snd_noise >> 8, y
    jmp  snd_noise
lp_r33:
gs_kill:
    ld   [o_i], ac
    add  SH_T, x
    ld   0, [x]
gs_keep:
    ld   gs_nx >> 8, y
    jmp  gs_nx

sl_add:
    ld   [tmp], x
    ld   FR >> 8, y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [tmp], ac
    add  128, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   SL >> 8, y
    ld   [sl_n], ac
    add  SL_C, x
    ld   [tmp2], ac
    ld   ac, [y,x]
    ld   [sl_n], ac
    add  SL_G, x
    ld   [tmp3], ac
    ld   ac, [y,x]
    ld   [sl_n], ac
    add  SL_LO, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [sl_n], ac
    add  SL_HI, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [sl_n], ac
    inc
    ld   ac, [sl_n]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; the text lines
; ------------------------------------------------------------

#addr 0x0C00
g_fire:
    ld   [inp], ac              ; a new press of the fire key, not crawling
    and  IN_FIRE, ac
    beq  gf_no
    ld   [inp_prev], ac
    and  IN_FIRE, ac
    bne  gf_no
    ld   [crawl], ac
    bne  gf_no
    clr  ac                     ; a free shot
    ld   ac, [o_i]
gf_lp:
    ld   [o_i], ac
    add  SH_T, x
    ld   [x], ac
    beq  gf_slot
    ld   [o_i], ac
    inc
    ld   ac, [o_i]
    xor  3, ac
    bne  gf_lp
gf_no:
    ld   g_door >> 8, y
    jmp  g_door
gf_slot:
    ld   SHOT_FRAMES, [x]
    ld   [inp], ac
    and  IN_UP, ac
    bne  gf_up
    ld   [o_i], ac              ; sideways, from the lantern
    add  SH_DY, x
    ld   0, [x]
    ld   [o_i], ac
    add  SH_Y, x
    ld   [py], ac
    add  6, ac
    ld   ac, [x]
    ld   [facing], ac
    bne  gf_left
    ld   [o_i], ac
    add  SH_DX, x
    ld   2, [x]
    ld   [o_i], ac
    add  SH_X, x
    ld   [px], ac
    add  7, ac
    ld   ac, [x]
    bra  gf_snd
gf_left:
    ld   [o_i], ac
    add  SH_DX, x
    ld   0xFE, [x]
    ld   [o_i], ac
    add  SH_X, x
    ld   [px], ac
    ld   ac, [x]
    bra  gf_snd
gf_up:
    ld   [o_i], ac              ; up, from the head
    add  SH_DX, x
    ld   0, [x]
    ld   [o_i], ac
    add  SH_DY, x
    ld   0xFC, [x]
    ld   [o_i], ac
    add  SH_X, x
    ld   [px], ac
    add  3, ac
    ld   ac, [x]
    ld   [o_i], ac
    add  SH_Y, x
    ld   [py], ac
    sub  4, ac
    ld   ac, [x]
gf_snd:
    ld   84, ac
    ld   LINK_LO, x             ; CALL snd_beep
    ld   lp_r34, [x]
    ld   LINK_HI, x
    ld   lp_r34 >> 8, [x]
    ld   snd_beep >> 8, y
    jmp  snd_beep
lp_r34:
    ld   g_door >> 8, y
    jmp  g_door

; ------------------------------------------------------------
; game: the open door shuts again (not on the hero)
; ------------------------------------------------------------
g_hud:
    ld   [hud_dirty], ac
    beq  hu_x
    clr  ac
    ld   ac, [hud_dirty]
    ld   7, ac
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   [energy], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   lp_r37, [x]
    ld   LINK_HI, x
    ld   lp_r37 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
lp_r37:
    ld   s_sp & 0xFF, ac
    ld   ac, [R0]
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r38, [x]
    ld   LINK_HI, x
    ld   lp_r38 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r38:
hu_x:
    ld   frame >> 8, y
    jmp  frame

; ------------------------------------------------------------
; load_room: read LAMP/Rnn.RM (nn = room, hex) to MAP and HDR, and its
; area's tiles when they are not the ones loaded
; ------------------------------------------------------------
s_dir:    #d "LAMP", 0x00
s_room:   #d "R00.RM", 0x00
s_area:   #d "A0.TS", 0x00
s_hex:    #d "0123456789ABCDEF"
s_energy: #d "ENERGY", 0x00
s_sp:     #d "  ", 0x00

#addr 0x0D00
g_spr:
    clr  ac
    ld   ac, [sl_n]
    ld   [crawl], ac            ; the hero's frame
    beq  sp_1
    ld   F_CRAWL, ac
    bra  sp_f
sp_1:
    ld   [onground], ac
    bne  sp_2
    ld   F_JUMP, ac
    bra  sp_f
sp_2:
    ld   [moving], ac
    beq  sp_f
    ld   [fcnt], ac
    shr  ac
    shr  ac
    shr  ac
    and  1, ac
    add  F_RUN1, ac
sp_f:
    ld   ac, [tmp]
    ld   [facing], ac
    beq  sp_3
    ld   [tmp], ac
    add  NPF, ac
    ld   ac, [tmp]
sp_3:
    ld   [px], ac
    sub  [sx], ac
    add  8, ac
    ld   ac, [tmp2]
    ld   [py], ac
    sub  [sy], ac
    add  32, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL sl_add
    ld   lp_r35, [x]
    ld   LINK_HI, x
    ld   lp_r35 >> 8, [x]
    ld   sl_add >> 8, y
    jmp  sl_add
lp_r35:
    clr  ac                     ; the shots
    ld   ac, [o_i]
sp_lp:
    ld   [o_i], ac
    add  SH_T, x
    ld   [x], ac
    beq  sp_nx
    ld   F_SHOT, ac
    ld   ac, [tmp]
    ld   [o_i], ac
    add  SH_X, x
    ld   [x], ac
    sub  [sx], ac
    add  8, ac
    ld   ac, [tmp2]
    ld   [o_i], ac
    add  SH_Y, x
    ld   [x], ac
    sub  [sy], ac
    add  32, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL sl_add
    ld   lp_r36, [x]
    ld   LINK_HI, x
    ld   lp_r36 >> 8, [x]
    ld   sl_add >> 8, y
    jmp  sl_add
lp_r36:
sp_nx:
    ld   [o_i], ac
    inc
    ld   ac, [o_i]
    xor  3, ac
    bne  sp_lp
    ld   g_hud >> 8, y
    jmp  g_hud

; sl_add: add frame tmp at byte column + 8 tmp2, cell + 32 tmp3 to the list
lr_2:
    ld   HDR >> 8, y
    ld   H_AREA, x
    ld   [y,x], ac
    xor  [area], ac
    beq  lr_3
    xor  [area], ac
    ld   ac, [area]
    ld   LINK_LO, x             ; CALL load_area
    ld   lp_r44, [x]
    ld   LINK_HI, x
    ld   lp_r44 >> 8, [x]
    ld   load_area >> 8, y
    jmp  load_area
lp_r44:
lr_3:
    ld   HDR >> 8, y
    ld   H_RW, x
    ld   [y,x], ac
    ld   ac, [rw]
    ld   H_RCY, x
    ld   [y,x], ac
    ld   ac, [rcy]
    ld   H_RWX, x
    ld   [y,x], ac
    ld   ac, [rwx]
    ld   H_RHY, x
    ld   [y,x], ac
    ld   ac, [rhy]
    clr  ac
    ld   ac, [door_t]
    ld   ac, [SH_T]
    ld   ac, [SH_T + 1]
    ld   ac, [SH_T + 2]
    ld   ac, [CUR_COL]          ; row 0: the room's name
    ld   ac, [CUR_ROW]
    ld   H_NAME, ac
    ld   ac, [R0]
    ld   HDR >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r45, [x]
    ld   LINK_HI, x
    ld   lp_r45 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r45:
    clr  ac                     ; row 1: the energy
    ld   ac, [CUR_COL]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   ac, [hud_dirty]
    ld   s_energy & 0xFF, ac
    ld   ac, [R0]
    ld   s_energy >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r46, [x]
    ld   LINK_HI, x
    ld   lp_r46 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r46:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; load_area: read LAMP/An.TS (n = area): 4 pages of tables to TS_LO on,
; the rest to x6000 on

#addr 0x0E00
load_room:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   LINK_LO, x             ; CALL fs_root
    ld   lp_r39, [x]
    ld   LINK_HI, x
    ld   lp_r39 >> 8, [x]
    ld   fs_root >> 8, y
    jmp  fs_root
lp_r39:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r40, [x]
    ld   LINK_HI, x
    ld   lp_r40 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r40:
    ld   [room], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  s_hex & 0xFF, x
    ld   s_hex >> 8, y
    ld   [y,x], ac
    ld   (s_room + 1) & 0xFF, x
    ld   ac, [y,x]
    ld   [room], ac
    and  15, ac
    add  s_hex & 0xFF, x
    ld   [y,x], ac
    ld   (s_room + 2) & 0xFF, x
    ld   ac, [y,x]
    ld   s_room & 0xFF, ac
    ld   ac, [R0]
    ld   s_room >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r41, [x]
    ld   LINK_HI, x
    ld   lp_r41 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r41:
    beq  lr_ok
    ld   dos_back >> 8, y
    jmp  dos_back
lr_ok:
    clr  ac
    ld   ac, [R4]
    ld   MAP >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r42, [x]
    ld   LINK_HI, x
    ld   lp_r42 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r42:
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r43, [x]
    ld   LINK_HI, x
    ld   lp_r43 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r43:
    ld   lr_2 >> 8, y
    jmp  lr_2


#addr 0x0F00
load_area:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   LINK_LO, x             ; CALL fs_root
    ld   lp_r47, [x]
    ld   LINK_HI, x
    ld   lp_r47 >> 8, [x]
    ld   fs_root >> 8, y
    jmp  fs_root
lp_r47:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r48, [x]
    ld   LINK_HI, x
    ld   lp_r48 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r48:
    ld   [area], ac
    add  0x30, ac
    ld   s_area >> 8, y
    ld   (s_area + 1) & 0xFF, x
    ld   ac, [y,x]
    ld   s_area & 0xFF, ac
    ld   ac, [R0]
    ld   s_area >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r49, [x]
    ld   LINK_HI, x
    ld   lp_r49 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r49:
    beq  la_ok
    ld   dos_back >> 8, y
    jmp  dos_back
la_ok:
    clr  ac
    ld   ac, [R4]
    ld   TS_LO >> 8, ac
    ld   ac, [R5]
la_rd:
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r50, [x]
    ld   LINK_HI, x
    ld   lp_r50 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r50:
    bne  la_done
    ld   [R5], ac               ; after the tables: the video RAM
    xor  TABLES_END >> 8, ac
    bne  la_rd
    ld   0x60, ac
    ld   ac, [R5]
    bra  la_rd
la_done:
    ld   lib_leave >> 8, y
    jmp  lib_leave

