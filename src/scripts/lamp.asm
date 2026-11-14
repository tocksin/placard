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
;     LAMP/An.TS      area n's tile set and sprites: 6 pages of tables to
;                     x4000 (tile routine addresses, tile attributes, sprite
;                     routine addresses, the area's creatures), then a
;                     straight image of the RAM
;                     from x6000: the tile routines and the sprite routines,
;                     in the video RAM the screen leaves free
;     LAMP/Rnn.RM     room nn (hex): the tile map (32 x 16, 512 bytes) to
;                     x4600, then its header (size, exits, objects, name) to
;                     x4800
;
; Controls: arrow keys or SNES pad Left / Right to walk, Z, Space or pad
; B / A to jump (hold for a higher jump), X or pad Y / X to fire (hold Up to
; fire up), Down to crawl (with the Burrow Rig), Esc back to the DOS.
;
; A room has up to 6 things (creatures, their bolts, items, embers); what a
; kind of thing does, its frames, hits, harm and size are in its area's
; table.  Model.obj_step has the rules.
;
; Date: 11/13/2026

#include "placard.asm"
#include "placard_lib.asm"
dos_back = 0x8008
fs_save = 0x8020

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
items      = 0x7F       ; the power-ups found: 1 Burrow Rig, 2 Updraft Bellows, 4 Ash Sail
tcnt       = 0x80       ; byte columns left of the tile being drawn
ob_i       = 0x81       ; the thing being moved, and a copy of it:
ob_k       = 0x82       ;   its kind (0: none)
ob_x       = 0x83       ;   byte column, cell
ob_y       = 0x84
ob_d       = 0x85       ;   0 right, 2 left (an item: its type)
ob_t       = 0x86       ;   its timer
ob_hp      = 0x87       ;   hits left
ob_p       = 0x88       ;   an item: type << 5 | number
ob_b       = 0x89       ;   what it does (B_...)
inv        = 0x8A       ; frames Wick cannot be hurt
ajump      = 0x8B       ; the jump in the air is used
chg        = 0x8C       ; the Kiln Charge: frames the fire key is held
blast_i    = 0x8D       ; 1 + the shot that is a blast (0: none)
wet        = 0x8E
touchf     = 0x8F       ; the thing touches Wick

mus_init   = 0x3797       ; the music player
mus_play   = 0x3D8B       ; the music player
mus_frame  = 0xFC40       ; the music player
mus_stop   = 0xFCD0       ; the music player
mus_sfx    = 0xF0EC       ; the music player
MODE_PF     = 10
LINE_GO     = 235
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
FR          = 15872
AREA_BLK    = 13056
AREA_END    = 17152
PCODE_B     = 22528
PROG2_END   = 9984
MAP         = 21504
HDR         = 22016
SL          = 18688
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
START_EMAX  = 50
FLASK       = 25
EMBER       = 5
AIRV_LO     = 128
AIRV_HI     = 252
HURTV_HI    = 254
INV_FRAMES  = 60
PUFF_FRAMES = 12
EMBER_FRAMES = 250
MSG_FRAMES  = 240
MAXOBJ      = 6
SPEC        = 16128
SPEC_BEH    = 0
SPEC_FRAME  = 16
SPEC_HP     = 32
SPEC_DMG    = 48
SPEC_ANIM   = 64
SPEC_DIRM   = 80
SPEC_W      = 96
SPEC_H      = 112
SPEC_SPIT   = 128
SPEC_WIDE   = 144
S_BOLT      = 4
BOLT_FRAMES = 90
DROP_NEAR   = 12
SPEC_AIM    = 160
CHG_FULL    = 45
BLAST_PW    = 4
HOP_REST    = 24
A_SOOT      = 8
IT_KILN     = 8
IT_WIDE     = 16
IT_COAT     = 32
IT_BOOTS    = 64
F_BLAST     = 11
H_FLAGS     = 8
HF_HOT      = 1
V_MSG       = 160
V_MSG_T     = 161
V_MSG_D     = 162
OBJ         = 18944
O_KIND      = 0
O_X         = 8
O_Y         = 16
O_D         = 24
O_T         = 32
O_HP        = 40
O_P         = 48
GOT         = 19200
HO_KIND     = 64
HO_X        = 72
HO_Y        = 80
HO_P        = 88
B_WALK      = 5
S_ITEM      = 1
S_EMBER     = 2
S_PUFF      = 3
IT_SAIL     = 4
SAILV       = 96
IT_RIG      = 1
IT_BELLOWS  = 2
M_DEAD      = 9
A_WATER     = 16
A_SEAL      = 32
H_SEALN     = 9
H_SEAL      = 10
H_MSG       = 14
G_BEAT      = 32
V_MODE      = 163
V_SAVED     = 164
V_SROOM     = 165
V_SX        = 166
V_SY        = 167
V_SITEMS    = 168
V_SEMAX     = 169
V_FR        = 170
V_SEC       = 171
V_MIN       = 172
V_HASSAVE   = 173
M_SAVE      = 12
END_ROOM    = 33
N_ITEMS     = 14
M_TITLE     = 1
M_END       = 2
WETV_LO     = 0
WETV_HI     = 253
SONG        = 13056
ZSAVE       = 23552
SFX_BEEP    = 15
SFX_NOISE   = 14
; ============================================================
; lamp_code.masm - LAMPLIGHTER's code.  gen_lamp.py puts the constants
; and the zero page in front of it, fills in the marked parts (tables
; and unrolled loops) and runs asm_expand over it: lamp.asm.
;
; The frame (docs/software/LAMPLIGHTER.md, "How it draws"):
;   frame      wait until the beam is near the playfield's last tile row
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
    ld   LINK_LO, x             ; (silence in the buffer until the first song)
    ld   lp_r2, [x]
    ld   LINK_HI, x
    ld   lp_r2 >> 8, [x]
    ld   snd_init >> 8, y
    jmp  snd_init
lp_r2:
    ld   ZSAVE >> 8, y          ; no song yet
    ld   ZV_ON, x
    ld   0, [y,x]
    ld   ZV_SN, x
    ld   0, [y,x]
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
    ld   title_go >> 8, y
    jmp  title_go

; reset: the program's variables and the found things as at the start
reset:
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
    ld   START_EMAX, ac
    ld   ac, [emax]
    ld   GOT >> 8, y            ; nothing found yet
    clr  ac
m_g:
    ld   ac, x
    ld   0, [y,x]
    inc
    bne  m_g
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; the title: the Landing Ledge without Wick, and the keys
title_go:
    ld   LINK_LO, x             ; CALL reset
    ld   lp_r3, [x]
    ld   LINK_HI, x
    ld   lp_r3 >> 8, [x]
    ld   reset >> 8, y
    jmp  reset
lp_r3:
    ld   GOT >> 8, y
    ld   V_MODE, x
    ld   M_TITLE, [y,x]
    ld   LINK_LO, x             ; a saved game on the card?  (the card
    ld   lp_r4, [x]
    ld   LINK_HI, x
    ld   lp_r4 >> 8, [x]
    ld   fs_root >> 8, y
    jmp  fs_root
lp_r4:
    ld   s_dir & 0xFF, ac       ; comes with a blank LAMP/SAVE.DAT, as the
    ld   ac, [R0]               ; writer never grows a folder)
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r5, [x]
    ld   LINK_HI, x
    ld   lp_r5 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r5:
    ld   s_save & 0xFF, ac
    ld   ac, [R0]
    ld   s_save >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r6, [x]
    ld   LINK_HI, x
    ld   lp_r6 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r6:
    bne  tg_1
    clr  ac                     ; (to the tile map: the room is read after)
    ld   ac, [R4]
    ld   MAP >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r7, [x]
    ld   LINK_HI, x
    ld   lp_r7 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r7:
    ld   MAP >> 8, y
    ld   V_SAVED, x
    ld   [y,x], ac
    beq  tg_1
    ld   GOT >> 8, y
    ld   V_HASSAVE, x
    ld   1, [y,x]
tg_1:
    ld   LINK_LO, x             ; CALL load_room
    ld   lp_r8, [x]
    ld   LINK_HI, x
    ld   lp_r8 >> 8, [x]
    ld   load_room >> 8, y
    jmp  load_room
lp_r8:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r9, [x]
    ld   LINK_HI, x
    ld   lp_r9 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r9:
    ld   title_txt >> 8, y
    jmp  title_txt


#addr 0x0400
title_txt:
    clr  ac
    ld   ac, [hud_dirty]
    ld   ac, [tmp]
tt_lp:
    clr  ac
    ld   ac, [CUR_COL]
    ld   [tmp], ac
    ld   ac, [CUR_ROW]
    add  t_lo & 0xFF, x
    ld   t_lo >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [tmp], ac
    add  t_hi & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r10, [x]
    ld   LINK_HI, x
    ld   lp_r10 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r10:
    ld   [tmp], ac
    inc
    ld   ac, [tmp]
    xor  3, ac
    bne  tt_lp
    ld   3, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   GOT >> 8, y
    ld   V_HASSAVE, x
    ld   [y,x], ac
    bne  tt_s
    ld   s_blank & 0xFF, ac
    ld   ac, [R0]
    ld   s_blank >> 8, ac
    bra  tt_p
tt_s:
    ld   s_t3 & 0xFF, ac
    ld   ac, [R0]
    ld   s_t3 >> 8, ac
tt_p:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r11, [x]
    ld   LINK_HI, x
    ld   lp_r11 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r11:
    ld   frame >> 8, y
    jmp  frame
t_lo: #d8 s_t0 & 0xFF, s_blank & 0xFF, s_t2 & 0xFF
t_hi: #d8 s_t0 >> 8, s_blank >> 8, s_t2 >> 8

; a new game
new_game:
    ld   LINK_LO, x             ; CALL reset
    ld   lp_r12, [x]
    ld   LINK_HI, x
    ld   lp_r12 >> 8, [x]
    ld   reset >> 8, y
    jmp  reset
lp_r12:
    ld   LINK_LO, x             ; CALL load_room
    ld   lp_r13, [x]
    ld   LINK_HI, x
    ld   lp_r13 >> 8, [x]
    ld   load_room >> 8, y
    jmp  load_room
lp_r13:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r14, [x]
    ld   LINK_HI, x
    ld   lp_r14 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r14:
    ld   g_spr >> 8, y
    jmp  g_spr

; go on from the game saved on the card
go_on:
    ld   LINK_LO, x             ; CALL reset
    ld   lp_r15, [x]
    ld   LINK_HI, x
    ld   lp_r15 >> 8, [x]
    ld   reset >> 8, y
    jmp  reset
lp_r15:
    ld   LINK_LO, x             ; CALL fs_root
    ld   lp_r16, [x]
    ld   LINK_HI, x
    ld   lp_r16 >> 8, [x]
    ld   fs_root >> 8, y
    jmp  fs_root
lp_r16:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r17, [x]
    ld   LINK_HI, x
    ld   lp_r17 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r17:
    ld   s_save & 0xFF, ac
    ld   ac, [R0]
    ld   s_save >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r18, [x]
    ld   LINK_HI, x
    ld   lp_r18 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r18:
    beq  gn_rd
    ld   new_game >> 8, y
    jmp  new_game
gn_rd:
    clr  ac                     ; (to the tile map: the room is read after)
    ld   ac, [R4]
    ld   MAP >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r19, [x]
    ld   LINK_HI, x
    ld   lp_r19 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r19:
    clr  ac
    ld   ac, [tmp]
gn_cp:
    ld   [tmp], x
    ld   MAP >> 8, y
    ld   [y,x], ac
    ld   GOT >> 8, y
    ld   ac, [y,x]
    ld   [tmp], ac
    inc
    ld   ac, [tmp]
    bne  gn_cp
    ld   go_on2 >> 8, y
    jmp  go_on2


#addr 0x0500
go_on2:
    ld   GOT >> 8, y
    ld   V_SROOM, x
    ld   [y,x], ac
    ld   ac, [room]
    ld   V_SX, x
    ld   [y,x], ac
    ld   ac, [px]
    ld   V_SY, x
    ld   [y,x], ac
    ld   ac, [py]
    ld   V_SITEMS, x
    ld   [y,x], ac
    ld   ac, [items]
    ld   V_SEMAX, x
    ld   [y,x], ac
    ld   ac, [emax]
    ld   ac, [energy]
    ld   LINK_LO, x             ; CALL load_room
    ld   lp_r20, [x]
    ld   LINK_HI, x
    ld   lp_r20 >> 8, [x]
    ld   load_room >> 8, y
    jmp  load_room
lp_r20:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r21, [x]
    ld   LINK_HI, x
    ld   lp_r21 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r21:
    ld   g_spr >> 8, y
    jmp  g_spr

; the title and the ending: a key, and no rules
mode_step:
    ld   [inp_prev], ac
    and  IN_JUMP, ac
    bne  ms_f
    ld   [inp], ac
    and  IN_JUMP, ac
    beq  ms_f
    ld   GOT >> 8, y
    ld   V_MODE, x
    ld   [y,x], ac
    xor  M_TITLE, ac
    beq  ms_new
    ld   title_go >> 8, y
    jmp  title_go
ms_new:
    ld   new_game >> 8, y
    jmp  new_game
ms_f:
    ld   GOT >> 8, y
    ld   V_MODE, x
    ld   [y,x], ac
    xor  M_TITLE, ac
    bne  ms_end
    ld   V_HASSAVE, x
    ld   [y,x], ac
    beq  ms_t
    ld   [inp_prev], ac
    and  IN_FIRE, ac
    bne  ms_t
    ld   [inp], ac
    and  IN_FIRE, ac
    beq  ms_t
    ld   go_on >> 8, y
    jmp  go_on
ms_t:
    clr  ac                     ; (the title: no sprites)
    ld   ac, [sl_n]
    ld   frame >> 8, y
    jmp  frame
ms_end:
    ld   g_spr >> 8, y
    jmp  g_spr

; ------------------------------------------------------------
; frame: wait for the beam, then draw behind it
; ------------------------------------------------------------
frame:
    ld   LINK_LO, x             ; AC = the line (V9:V2)
    ld   lp_r22, [x]
    ld   LINK_HI, x
    ld   lp_r22 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
lp_r22:
    sub  LINE_GO, ac
    bcs  frame
    sub  2, ac                  ; (past it, after a room was read: the next time round)
    bcc  frame
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

ob_lo: #d8 ob_item & 0xFF, ob_ember & 0xFF, ob_puff & 0xFF, ob_bolt & 0xFF, ob_lamp & 0xFF, ob_walk & 0xFF, ob_fly & 0xFF, ob_sit & 0xFF, ob_drop & 0xFF, ob_hop & 0xFF, ob_hover & 0xFF
ob_hi: #d8 ob_item >> 8, ob_ember >> 8, ob_puff >> 8, ob_bolt >> 8, ob_lamp >> 8, ob_walk >> 8, ob_fly >> 8, ob_sit >> 8, ob_drop >> 8, ob_hop >> 8, ob_hover >> 8
hopdy: #d8 0xFC, 0xFC, 0xFD, 0xFD, 0xFE, 0xFE, 0xFF, 0xFF, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04

; ob_store: the copy back to thing ob_i

#addr 0x0600
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
    ld   LINK_LO, x             ; CALL pad_read
    ld   lp_r23, [x]
    ld   LINK_HI, x
    ld   lp_r23 >> 8, [x]
    ld   pad_read >> 8, y
    jmp  pad_read
lp_r23:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   lp_r24, [x]
    ld   LINK_HI, x
    ld   lp_r24 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
lp_r24:
    ld   LINK_LO, x             ; (Esc: back to the DOS)
    ld   lp_r25, [x]
    ld   LINK_HI, x
    ld   lp_r25 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
lp_r25:
    ld   [inp], ac
    ld   ac, [inp_prev]
    clr  ac
    ld   ac, [inp]
    ld   read_input >> 8, y
    jmp  read_input

ob_save:
    ld   LINK_LO, x             ; CALL ob_store
    ld   lp_r58, [x]
    ld   LINK_HI, x
    ld   lp_r58 >> 8, [x]
    ld   ob_store >> 8, y
    jmp  ob_store
lp_r58:
    ld   ob_next >> 8, y
    jmp  ob_next

; an item: found when Wick touches it
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
    ld   mus_tick >> 8, y       ; done: the music (map FF), then map 07
    jmp  mus_tick
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
    ld   GOT >> 8, y
    ld   V_MODE, x
    ld   [y,x], ac
    beq  gm_1
    ld   mode_step >> 8, y
    jmp  mode_step
gm_1:
    ld   V_FR, x                ; the time played
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    xor  60, ac
    bne  gm_2
    ld   ac, [y,x]
    ld   V_SEC, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    xor  60, ac
    bne  gm_2
    ld   ac, [y,x]
    ld   V_MIN, x
    ld   [y,x], ac
    inc
    beq  gm_2
    ld   ac, [y,x]
gm_2:
    ld   game2 >> 8, y
    jmp  game2

game2:
    ld   [fcnt], ac
    inc
    ld   ac, [fcnt]
    ld   [inp], ac              ; Down on the ground: crawl
    and  IN_DOWN, ac
    beq  gc_up
    ld   [onground], ac
    beq  gc_up
    ld   [items], ac            ; (with the Burrow Rig)
    and  IT_RIG, ac
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
    ld   lp_r26, [x]
    ld   LINK_HI, x
    ld   lp_r26 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r26:
    bne  gc_done
    ld   [px], ac
    add  6, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r27, [x]
    ld   LINK_HI, x
    ld   lp_r27 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r27:
    bne  gc_done
    clr  ac
    ld   ac, [crawl]
gc_done:
    ld   g_wet >> 8, y
    jmp  g_wet

; under water (the tile at his middle), without the Ballast Boots

#addr 0x0800
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
g_wet:
    ld   [px], ac
    add  4, ac
    ld   ac, [ta_x]
    ld   [py], ac
    add  8, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r28, [x]
    ld   LINK_HI, x
    ld   lp_r28 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r28:
    ld   [ta_a], ac
    and  A_WATER, ac
    ld   ac, [wet]
    ld   [items], ac
    and  IT_BOOTS, ac
    beq  gw_1
    clr  ac
    ld   ac, [wet]
gw_1:
    ld   g_horiz >> 8, y
    jmp  g_horiz

; ------------------------------------------------------------
; game: sideways
; ------------------------------------------------------------
msg_set:
    ld   GOT >> 8, y
    ld   V_MSG, x
    ld   ac, [y,x]
    ld   V_MSG_T, x
    ld   MSG_FRAMES, [y,x]
    ld   V_MSG_D, x
    ld   1, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; an ember: energy when Wick touches it, gone after a while
; a puff: where a creature was; then, every other time, an ember
ob_sit:
    ld   [px], ac
    sub  [ob_x], ac
    bcs  os_l
    clr  ac
    bra  os_1
os_l:
    ld   2, ac
os_1:
    ld   ac, [ob_d]
    ld   ob_spit >> 8, y
    jmp  ob_spit

; ob_spit: a kind that spits: a bolt toward Wick when its timer & the
; kind's mask is 0, in the first free place

#addr 0x0900
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
    ld   [crawl], ac            ; a step 3 frames of 4; crawling or in water, every other
    or   [wet], ac
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

g_right:
    ld   [px], ac               ; a wall at byte column px + 7?
    add  7, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL side_free
    ld   lp_r29, [x]
    ld   LINK_HI, x
    ld   lp_r29 >> 8, [x]
    ld   side_free >> 8, y
    jmp  side_free
lp_r29:
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
    ld   lp_r30, [x]
    ld   LINK_HI, x
    ld   lp_r30 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r30:
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
    ld   lp_r31, [x]
    ld   LINK_HI, x
    ld   lp_r31 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r31:
    beq  gl_no
    ld   do_exit >> 8, y
    jmp  do_exit
gl_1:
    ld   ac, [ta_x]             ; a wall at byte column px?
    ld   LINK_LO, x             ; CALL side_free
    ld   lp_r32, [x]
    ld   LINK_HI, x
    ld   lp_r32 >> 8, [x]
    ld   side_free >> 8, y
    jmp  side_free
lp_r32:
    bne  gl_no
    ld   [px], ac
    dec
    ld   ac, [px]
gl_no:
    ld   g_jump >> 8, y
    jmp  g_jump

; side_free: AC = 0 when byte column ta_x is open beside the hero
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

#addr 0x0A00
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
    ld   lp_r33, [x]
    ld   LINK_HI, x
    ld   lp_r33 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r33:
    bne  sf_out
sf_low:
    ld   [py], ac
    add  8, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r34, [x]
    ld   LINK_HI, x
    ld   lp_r34 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r34:
    bne  sf_out
    ld   [py], ac
    add  15, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r35, [x]
    ld   LINK_HI, x
    ld   lp_r35 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r35:
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
gs_soot2:
    ld   [ta_pg], ac
    ld   ac, [tmp2]
    ld   [ta_i], ac
    sub  32, ac
    ld   ac, [tmp]
    ld   [ta_i], ac
    sub  32, ac
    bcc  gt_1
    ld   [tmp2], ac
    dec
    ld   ac, [tmp2]
gt_1:
    ld   [tmp2], y
    ld   [tmp], x
    ld   [y,x], ac
    ld   ac, x
    ld   ATTR >> 8, y
    ld   [y,x], ac
    and  A_SOOT, ac
    beq  gt_2
    ld   [tmp2], y
    ld   [tmp], x
    ld   0, [y,x]
gt_2:
    ld   gs_kill >> 8, y
    jmp  gs_kill

; a shot in the open: does it hit a creature?

#addr 0x0B00
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
    ld   lp_r36, [x]
    ld   LINK_HI, x
    ld   lp_r36 >> 8, [x]
    ld   load_room >> 8, y
    jmp  load_room
lp_r36:
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
    ld   lp_r37, [x]
    ld   LINK_HI, x
    ld   lp_r37 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r37:
    ld   [ta_a], ac
    and  A_DOOR, ac
    beq  de_done
    ld   LINK_LO, x             ; CALL open_door
    ld   lp_r38, [x]
    ld   LINK_HI, x
    ld   lp_r38 >> 8, [x]
    ld   open_door >> 8, y
    jmp  open_door
lp_r38:
de_done:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r39, [x]
    ld   LINK_HI, x
    ld   lp_r39 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r39:
    ld   g_spr >> 8, y
    jmp  g_spr

; open_door: open the door whose tile tile_at just found (ta_a, ta_pg,
; ta_i), shutting the one that is open
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
ob_enemy:
    ld   [touchf], ac
    beq  on_x
    ld   LINK_LO, x             ; CALL hurt
    ld   lp_r90, [x]
    ld   LINK_HI, x
    ld   lp_r90 >> 8, [x]
    ld   hurt >> 8, y
    jmp  hurt
lp_r90:
on_x:
    ld   ob_save >> 8, y
    jmp  ob_save

; hurt: thing ob_k's harm off Wick's energy (not again for a second)

#addr 0x0C00
g_jump:
    ld   [inp], ac
    and  IN_JUMP, ac
    beq  gj_no
    ld   [inp_prev], ac         ; a new press, not crawling
    and  IN_JUMP, ac
    bne  gj_grav
    ld   [crawl], ac
    bne  gj_grav
    ld   [onground], ac
    bne  gj_do
    ld   [items], ac            ; in the air: once, with the Updraft Bellows
    and  IT_BELLOWS, ac
    beq  gj_grav
    ld   [ajump], ac
    bne  gj_grav
    ld   1, ac
    ld   ac, [ajump]
    ld   AIRV_LO, ac
    ld   ac, [vyl]
    ld   AIRV_HI, ac
    ld   ac, [vyh]
    ld   77, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r40, [x]
    ld   LINK_HI, x
    ld   lp_r40 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r40:
    bra  gj_grav
gj_do:
    ld   [wet], ac
    bne  gj_wet
    ld   JUMPV_LO, ac
    ld   ac, [vyl]
    ld   JUMPV_HI, ac
    ld   ac, [vyh]
    ld   72, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r41, [x]
    ld   LINK_HI, x
    ld   lp_r41 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r41:
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
    ld   g_grav >> 8, y
    jmp  g_grav
gj_wet:
    ld   WETV_LO, ac
    ld   ac, [vyl]
    ld   WETV_HI, ac
    ld   ac, [vyh]
    ld   66, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r42, [x]
    ld   LINK_HI, x
    ld   lp_r42 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r42:
    ld   g_grav >> 8, y
    jmp  g_grav

g_grav:
    ld   [vyl], ac              ; gravity
    add  GRAV, ac
    ld   ac, [vyl]
    ld   [vyh], ac
    bcc  gj_g1
    inc
gj_g1:
    ld   ac, [vyh]
    blt  gj_move
    ld   [items], ac            ; the Ash Sail, the jump key held: a slow fall
    and  IT_SAIL, ac
    beq  gj_cap
    ld   [inp], ac
    and  IN_JUMP, ac
    beq  gj_cap
    ld   [vyh], ac
    bne  gj_sail
    ld   [vyl], ac
    sub  SAILV, ac
    bcs  gj_move
gj_sail:
    clr  ac
    ld   ac, [vyh]
    ld   SAILV, ac
    ld   ac, [vyl]
    bra  gj_move
gj_cap:
    ld   [vyh], ac
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

ob_fwd:
    ld   [ob_d], ac
    bne  ofw_l
    ld   [ob_x], ac
    inc
    ld   ac, [ob_x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ofw_l:
    ld   [ob_x], ac
    dec
    ld   ac, [ob_x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; a creature that touches Wick hurts him

#addr 0x0D00
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
    ld   lp_r43, [x]
    ld   LINK_HI, x
    ld   lp_r43 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r43:
    bne  gu_bump
    ld   [px], ac
    add  6, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r44, [x]
    ld   LINK_HI, x
    ld   lp_r44 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r44:
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
    ld   lp_r45, [x]
    ld   LINK_HI, x
    ld   lp_r45 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r45:
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
    ld   lp_r46, [x]
    ld   LINK_HI, x
    ld   lp_r46 >> 8, [x]
    ld   find_exit >> 8, y
    jmp  find_exit
lp_r46:
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
    ld   lp_r47, [x]
    ld   LINK_HI, x
    ld   lp_r47 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r47:
    bne  gd_land
    ld   [px], ac
    add  6, ac
    ld   ac, [ta_x]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r48, [x]
    ld   LINK_HI, x
    ld   lp_r48 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r48:
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
    ld   ac, [ajump]
    ld   1, ac
    ld   ac, [onground]
    ld   g_post >> 8, y
    jmp  g_post

; camera: sx, sy from the hero's place

#addr 0x0E00
g_post:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r49, [x]
    ld   LINK_HI, x
    ld   lp_r49 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r49:
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
    ld   lp_r50, [x]
    ld   LINK_HI, x
    ld   lp_r50 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r50:
    beq  gs_obj
    ld   [ta_a], ac             ; a wall stops it; a door opens
    and  A_DOOR, ac
    beq  gs_soot
    ld   LINK_LO, x             ; CALL open_door
    ld   lp_r51, [x]
    ld   LINK_HI, x
    ld   lp_r51 >> 8, [x]
    ld   open_door >> 8, y
    jmp  open_door
lp_r51:
    ld   8, ac
    ld   ac, [R0]
    ld   10, ac
    ld   ac, [R2]
    ld   6, ac
    ld   ac, [R3]
    ld   60, ac
    ld   LINK_LO, x             ; CALL sfx_n
    ld   lp_r52, [x]
    ld   LINK_HI, x
    ld   lp_r52 >> 8, [x]
    ld   sfx_n >> 8, y
    jmp  sfx_n
lp_r52:
gs_kill:
    ld   [o_i], ac
    add  SH_T, x
    ld   0, [x]
gs_keep:
    ld   gs_nx >> 8, y
    jmp  gs_nx
gs_obj:
    ld   gs_hit >> 8, y
    jmp  gs_hit
gs_soot:
    ld   [ta_a], ac             ; a blast breaks a sooted block
    and  A_SOOT, ac
    beq  gs_kill
    ld   [o_i], ac
    inc
    xor  [blast_i], ac
    bne  gs_kill
    ld   [ta_pg], y
    ld   [ta_i], x
    ld   0, [y,x]
    ld   gs_soot2 >> 8, y
    jmp  gs_soot2

; ... and the sooted block right over it
gf_kind:
    ld   [o_i], ac              ; which of the shots is the blast
    inc
    ld   ac, [tmp]
    ld   [tmp3], ac
    beq  gf_n
    ld   [tmp], ac
    ld   ac, [blast_i]
    ld   60, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r56, [x]
    ld   LINK_HI, x
    ld   lp_r56 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r56:
    ld   g_door >> 8, y
    jmp  g_door
gf_n:
    ld   [tmp], ac
    xor  [blast_i], ac
    bne  gf_b
    ld   ac, [blast_i]
gf_b:
    ld   84, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r57, [x]
    ld   LINK_HI, x
    ld   lp_r57 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r57:
    ld   g_door >> 8, y
    jmp  g_door

; ------------------------------------------------------------
; game: the open door shuts again (not on the hero)
; ------------------------------------------------------------

#addr 0x0F00
gs_hit:
    clr  ac
    ld   ac, [ob_i]
sq_lp:
    ld   OBJ >> 8, y
    ld   [ob_i], x
    ld   [y,x], ac
    ld   ac, [ob_k]
    add  SPEC_BEH, x
    ld   SPEC >> 8, y
    ld   [y,x], ac
    sub  B_WALK, ac
    bcs  sq_nx
    ld   OBJ >> 8, y
    ld   [ob_i], ac
    add  O_X, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [ta_x], ac
    sub  [tmp], ac
    ld   ac, [tmp]
    ld   [ob_k], ac
    add  SPEC_W, x
    ld   SPEC >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [tmp], ac
    sub  [tmp2], ac
    bcc  sq_nx
    ld   OBJ >> 8, y
    ld   [ob_i], ac
    add  O_Y, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [ta_y], ac
    sub  [tmp], ac
    ld   ac, [tmp]
    ld   [ob_k], ac
    add  SPEC_H, x
    ld   SPEC >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [tmp], ac
    sub  [tmp2], ac
    bcc  sq_nx
    ld   OBJ >> 8, y
    ld   [o_i], ac              ; a hit: the shot is gone
    add  SH_T, x
    ld   0, [x]
    ld   sq_2 >> 8, y
    jmp  sq_2
sq_nx:
    ld   [ob_i], ac
    inc
    ld   ac, [ob_i]
    xor  MAXOBJ, ac
    beq  sq_x1
    ld   sq_lp >> 8, y
    jmp  sq_lp
sq_x1:
    ld   gs_nx >> 8, y
    jmp  gs_nx

sq_2:
    ld   OBJ >> 8, y
    ld   [ob_i], ac
    add  O_HP, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   1, ac                  ; a spark takes 1 hit off it, a blast more
    ld   ac, [tmp2]
    ld   [o_i], ac
    inc
    xor  [blast_i], ac
    bne  sq_p
    ld   BLAST_PW, ac
    ld   ac, [tmp2]
sq_p:
    ld   [tmp], ac
    sub  [tmp2], ac
    bcc  sq_h
    clr  ac
sq_h:
    ld   ac, [tmp]
    ld   [ob_i], ac
    add  O_HP, x
    ld   [tmp], ac
    ld   ac, [y,x]
    bne  sq_snd
    ld   [ob_i], x              ; its last: a puff
    ld   S_PUFF, [y,x]
    ld   [ob_i], ac
    add  O_T, x
    ld   PUFF_FRAMES, [y,x]
    ld   [ob_i], ac
    add  O_D, x
    ld   0, [y,x]
    ld   10, ac
    ld   ac, [R0]
    ld   8, ac
    ld   ac, [R2]
    ld   4, ac
    ld   ac, [R3]
    ld   50, ac
    ld   LINK_LO, x             ; CALL sfx_n
    ld   lp_r53, [x]
    ld   LINK_HI, x
    ld   lp_r53 >> 8, [x]
    ld   sfx_n >> 8, y
    jmp  sfx_n
lp_r53:
    bra  sq_x
sq_snd:
    ld   60, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r54, [x]
    ld   LINK_HI, x
    ld   lp_r54 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r54:
sq_x:
    ld   gs_nx >> 8, y
    jmp  gs_nx

op_beat:
    ld   [ob_p], ac
    and  31, ac
    add  G_BEAT, x
    ld   GOT >> 8, y
    ld   1, [y,x]
    ld   LINK_LO, x             ; CALL seal_check
    ld   lp_r125, [x]
    ld   LINK_HI, x
    ld   lp_r125 >> 8, [x]
    ld   seal_check >> 8, y
    jmp  seal_check
lp_r125:
    ld   [ob_p], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [ob_d]
    ld   S_ITEM, ac
    ld   ac, [ob_k]
    ld   ob_keep >> 8, y
    jmp  ob_keep

; seal_check: the room's seal opens (its tiles become empty) when every
; keeper it names is beaten.  tmp3: 0 when it stays shut

#addr 0x1000
g_fire:
    clr  ac
    ld   ac, [tmp3]             ; (1: a blast)
    ld   [inp], ac              ; a new press of the fire key, not crawling: a spark
    and  IN_FIRE, ac
    beq  gf_chg
    ld   [inp_prev], ac
    and  IN_FIRE, ac
    bne  gf_chg
    ld   [crawl], ac
    bne  gf_chg
    ld   gf_find >> 8, y
    jmp  gf_find
gf_chg:
    ld   [items], ac            ; the Kiln Charge: the key held fills it; let
    and  IT_KILN, ac            ; go when it is full: a blast
    beq  gf_no
    ld   [inp], ac
    and  IN_FIRE, ac
    beq  gf_rel
    ld   [chg], ac
    xor  CHG_FULL, ac
    beq  gf_no
    ld   [chg], ac
    inc
    ld   ac, [chg]
    xor  CHG_FULL, ac
    bne  gf_no
    ld   91, ac                 ; (full)
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r55, [x]
    ld   LINK_HI, x
    ld   lp_r55 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r55:
gf_no:
    ld   g_door >> 8, y
    jmp  g_door
gf_rel:
    ld   [chg], ac
    ld   ac, [tmp]
    clr  ac
    ld   ac, [chg]
    ld   [tmp], ac
    xor  CHG_FULL, ac
    bne  gf_no
    ld   [crawl], ac
    bne  gf_no
    ld   1, ac
    ld   ac, [tmp3]
    ld   gf_find >> 8, y
    jmp  gf_find

gf_find:
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
    ld   gf_wide >> 8, y
    jmp  gf_wide

; the Wide Flame: a spark each side of it, in the free places
m_lo: #d8 s_m0 & 0xFF, s_m1 & 0xFF, s_m2 & 0xFF, s_m3 & 0xFF, s_m4 & 0xFF, s_m5 & 0xFF, s_m6 & 0xFF, s_m7 & 0xFF, s_m8 & 0xFF, s_m9 & 0xFF, s_m10 & 0xFF, s_m11 & 0xFF, s_m12 & 0xFF
m_hi: #d8 s_m0 >> 8, s_m1 >> 8, s_m2 >> 8, s_m3 >> 8, s_m4 >> 8, s_m5 >> 8, s_m6 >> 8, s_m7 >> 8, s_m8 >> 8, s_m9 >> 8, s_m10 >> 8, s_m11 >> 8, s_m12 >> 8


#addr 0x1100
gf_wide:
    ld   [tmp3], ac             ; (a blast stays one)
    bne  gw_x
    ld   [items], ac
    and  IT_WIDE, ac
    beq  gw_x
    ld   0xFF, ac               ; the spread: -1, then 1
    ld   ac, [ta_a]
    clr  ac
    ld   ac, [ta_i]
gw_lp:
    ld   [ta_i], ac
    add  SH_T, x
    ld   [x], ac
    bne  gw_nx
    ld   SHOT_FRAMES, [x]
    ld   [o_i], ac
    add  SH_X, x
    ld   [x], ac
    ld   ac, [tmp]
    ld   [ta_i], ac
    add  SH_X, x
    ld   [tmp], ac
    ld   ac, [x]
    ld   [o_i], ac
    add  SH_Y, x
    ld   [x], ac
    ld   ac, [tmp]
    ld   [ta_i], ac
    add  SH_Y, x
    ld   [tmp], ac
    ld   ac, [x]
    ld   [o_i], ac
    add  SH_DX, x
    ld   [x], ac
    ld   ac, [tmp]
    ld   [ta_i], ac
    add  SH_DX, x
    ld   [tmp], ac
    ld   ac, [x]
    ld   [o_i], ac
    add  SH_DY, x
    ld   [x], ac
    ld   ac, [tmp]
    ld   [ta_i], ac
    add  SH_DY, x
    ld   [tmp], ac
    ld   ac, [x]
    ld   [ta_i], ac             ; sideways: up or down a little; upward: left or right
    add  SH_DX, x
    ld   [x], ac
    bne  gw_dy
    ld   [ta_a], ac
    ld   ac, [x]
    bra  gw_bl
gw_dy:
    ld   [ta_i], ac
    add  SH_DY, x
    ld   [ta_a], ac
    ld   ac, [x]
gw_bl:
    ld   [ta_i], ac             ; (it is not the blast that was here)
    inc
    xor  [blast_i], ac
    bne  gw_s
    ld   ac, [blast_i]
gw_s:
    ld   1, ac
    ld   ac, [ta_a]
gw_nx:
    ld   [ta_i], ac
    inc
    ld   ac, [ta_i]
    xor  3, ac
    bne  gw_lp
gw_x:
    ld   gf_kind >> 8, y
    jmp  gf_kind

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
    ld   g_obj >> 8, y
    jmp  g_obj

; ------------------------------------------------------------
; game: the room's things (creatures, items, embers)
; ------------------------------------------------------------
ob_touch:
    clr  ac                     ; does it touch Wick?
    ld   ac, [touchf]
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_W, x
    ld   [y,x], ac
    add  3, ac
    ld   ac, [tmp]
    ld   [px], ac
    sub  [ob_x], ac
    add  5, ac
    sub  [tmp], ac
    bcc  ob_go
    ld   [ob_k], ac
    add  SPEC_H, x
    ld   [y,x], ac
    add  13, ac
    ld   ac, [tmp]
    ld   [crawl], ac
    beq  ob_t1
    ld   [tmp], ac
    sub  8, ac
    ld   ac, [tmp]
ob_t1:
    ld   [py], ac
    sub  [ob_y], ac
    add  13, ac
    sub  [tmp], ac
    bcc  ob_go
    ld   1, ac
    ld   ac, [touchf]
ob_go:
    ld   [ob_b], ac             ; what it does
    add  ob_hi & 0xFF, x
    ld   ob_hi >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [ob_b], ac
    add  ob_lo & 0xFF, x
    ld   [y,x], ac
    ld   [tmp2], y
    jmp  ac


#addr 0x1200
g_obj:
    clr  ac
    ld   ac, [ob_i]
ob_lp:
    ld   OBJ >> 8, y
    ld   [ob_i], x
    ld   [y,x], ac
    bne  ob_live
ob_next:
    ld   [ob_i], ac
    inc
    ld   ac, [ob_i]
    xor  MAXOBJ, ac
    bne  ob_lp
    ld   g_inv >> 8, y
    jmp  g_inv
ob_live:
    ld   ac, [ob_k]             ; a copy of it in the zero page
    add  SPEC_BEH, x
    ld   SPEC >> 8, y
    ld   [y,x], ac
    ld   ac, [ob_b]
    ld   OBJ >> 8, y
    ld   [ob_i], ac
    add  O_X, x
    ld   [y,x], ac
    ld   ac, [ob_x]
    ld   [ob_i], ac
    add  O_Y, x
    ld   [y,x], ac
    ld   ac, [ob_y]
    ld   [ob_i], ac
    add  O_D, x
    ld   [y,x], ac
    ld   ac, [ob_d]
    ld   [ob_i], ac
    add  O_T, x
    ld   [y,x], ac
    ld   ac, [ob_t]
    ld   [ob_i], ac
    add  O_HP, x
    ld   [y,x], ac
    ld   ac, [ob_hp]
    ld   [ob_i], ac
    add  O_P, x
    ld   [y,x], ac
    ld   ac, [ob_p]
    ld   ob_touch >> 8, y
    jmp  ob_touch

ob_store:
    ld   OBJ >> 8, y
    ld   [ob_i], x
    ld   [ob_k], ac
    ld   ac, [y,x]
    ld   [ob_i], ac
    add  O_X, x
    ld   [ob_x], ac
    ld   ac, [y,x]
    ld   [ob_i], ac
    add  O_Y, x
    ld   [ob_y], ac
    ld   ac, [y,x]
    ld   [ob_i], ac
    add  O_D, x
    ld   [ob_d], ac
    ld   ac, [y,x]
    ld   [ob_i], ac
    add  O_T, x
    ld   [ob_t], ac
    ld   ac, [y,x]
    ld   [ob_i], ac
    add  O_HP, x
    ld   [ob_hp], ac
    ld   ac, [y,x]
    ld   [ob_i], ac
    add  O_P, x
    ld   [ob_p], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

ob_item:
    ld   [touchf], ac
    bne  oi_get
    ld   ob_next >> 8, y
    jmp  ob_next
oi_get:
    clr  ac
    ld   ac, [ob_k]
    ld   [ob_p], ac
    and  31, ac
    ld   ac, x
    ld   GOT >> 8, y
    ld   1, [y,x]
    ld   [ob_d], ac             ; its type: 0 an Oil Flask, else a power-up
    bne  oi_pow
    ld   [emax], ac
    add  FLASK, ac
    ld   ac, [emax]
    bra  oi_fill
oi_pow:
    add  (s_bits - 1) & 0xFF, x
    ld   s_bits >> 8, y
    ld   [y,x], ac
    or   [items], ac
    ld   ac, [items]
oi_fill:
    ld   [emax], ac
    ld   ac, [energy]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   [ob_d], ac
    inc
    ld   LINK_LO, x             ; CALL msg_set
    ld   lp_r59, [x]
    ld   LINK_HI, x
    ld   lp_r59 >> 8, [x]
    ld   msg_set >> 8, y
    jmp  msg_set
lp_r59:
    ld   79, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r60, [x]
    ld   LINK_HI, x
    ld   lp_r60 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r60:
    ld   ob_save >> 8, y
    jmp  ob_save

; a save lamp: touched, once a visit: the lantern is filled and the game
; is written to the card (LAMP/SAVE.DAT: the found-things page)

#addr 0x1300
ob_lamp:
    ld   [touchf], ac
    beq  ol_n
    ld   [ob_t], ac
    beq  ol_s
ol_n:
    ld   ob_next >> 8, y
    jmp  ob_next
ol_s:
    ld   1, ac
    ld   ac, [ob_t]
    ld   GOT >> 8, y
    ld   V_SAVED, x
    ld   1, [y,x]
    ld   V_SROOM, x
    ld   [room], ac
    ld   ac, [y,x]
    ld   V_SX, x
    ld   [px], ac
    ld   ac, [y,x]
    ld   V_SY, x
    ld   [py], ac
    ld   ac, [y,x]
    ld   V_SITEMS, x
    ld   [items], ac
    ld   ac, [y,x]
    ld   V_SEMAX, x
    ld   [emax], ac
    ld   ac, [y,x]
    ld   ac, [energy]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   M_SAVE, ac
    ld   LINK_LO, x             ; CALL msg_set
    ld   lp_r61, [x]
    ld   LINK_HI, x
    ld   lp_r61 >> 8, [x]
    ld   msg_set >> 8, y
    jmp  msg_set
lp_r61:
    ld   ol_w >> 8, y
    jmp  ol_w

ol_w:
    ld   LINK_LO, x             ; (a few frames of card writes)
    ld   lp_r62, [x]
    ld   LINK_HI, x
    ld   lp_r62 >> 8, [x]
    ld   mus_quiet >> 8, y
    jmp  mus_quiet
lp_r62:
    ld   LINK_LO, x             ; CALL fs_root
    ld   lp_r63, [x]
    ld   LINK_HI, x
    ld   lp_r63 >> 8, [x]
    ld   fs_root >> 8, y
    jmp  fs_root
lp_r63:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r64, [x]
    ld   LINK_HI, x
    ld   lp_r64 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r64:
    ld   s_save & 0xFF, ac
    ld   ac, [R0]
    ld   s_save >> 8, ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R4]
    ld   ac, [R2]
    ld   GOT >> 8, ac
    ld   ac, [R5]
    ld   1, ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL fs_save
    ld   lp_r65, [x]
    ld   LINK_HI, x
    ld   lp_r65 >> 8, [x]
    ld   fs_save >> 8, y
    jmp  fs_save
lp_r65:
    clr  ac                     ; (mus_quiet before: the song again)
    ld   LINK_LO, x             ; CALL mus_start
    ld   lp_r66, [x]
    ld   LINK_HI, x
    ld   lp_r66 >> 8, [x]
    ld   mus_start >> 8, y
    jmp  mus_start
lp_r66:
    ld   88, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r67, [x]
    ld   LINK_HI, x
    ld   lp_r67 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r67:
    ld   ob_save >> 8, y
    jmp  ob_save

; msg_set: message AC on the third text line, for a while
ob_walk:
    ld   [fcnt], ac
    and  1, ac
    beq  ow_x
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_H, x
    ld   [y,x], ac
    ld   ac, [tmp2]
    sub  4, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL ob_front
    ld   lp_r69, [x]
    ld   LINK_HI, x
    ld   lp_r69 >> 8, [x]
    ld   ob_front >> 8, y
    jmp  ob_front
lp_r69:
    bne  ow_turn
    ld   [ob_y], ac             ; (ob_front left ta_x there)
    add  [tmp2], ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r70, [x]
    ld   LINK_HI, x
    ld   lp_r70 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r70:
    beq  ow_turn
    ld   LINK_LO, x             ; CALL ob_fwd
    ld   lp_r71, [x]
    ld   LINK_HI, x
    ld   lp_r71 >> 8, [x]
    ld   ob_fwd >> 8, y
    jmp  ob_fwd
lp_r71:
    bra  ow_x
ow_turn:
    ld   [ob_d], ac
    xor  2, ac
    ld   ac, [ob_d]
ow_x:
    ld   ob_spit >> 8, y
    jmp  ob_spit

; a sitter: it faces Wick
ob_ember:
    ld   [ob_t], ac
    dec
    ld   ac, [ob_t]
    beq  ob_gone
    ld   [touchf], ac
    beq  ob_keep
    ld   [energy], ac
    add  EMBER, ac
    ld   ac, [energy]
    sub  [emax], ac
    bcs  oe_ok
    ld   [emax], ac
    ld   ac, [energy]
oe_ok:
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   81, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r68, [x]
    ld   LINK_HI, x
    ld   lp_r68 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r68:
ob_gone:
    clr  ac
    ld   ac, [ob_k]
ob_keep:
    ld   ob_save >> 8, y
    jmp  ob_save
ob_puff:
    ld   [ob_t], ac
    dec
    ld   ac, [ob_t]
    bne  ob_keep
    ld   [ob_p], ac             ; what it guarded
    bne  op_item
    ld   [fcnt], ac
    and  1, ac
    beq  ob_gone
    ld   S_EMBER, ac
    ld   ac, [ob_k]
    ld   EMBER_FRAMES, ac
    ld   ac, [ob_t]
    bra  ob_keep
op_item:
    ld   op_beat >> 8, y
    jmp  op_beat

; a walker: a step every other frame; it turns at a wall and at the end
; of its floor
ob_spit:
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_SPIT, x
    ld   [y,x], ac
    beq  ot_x
    ld   ac, [tmp]
    ld   [ob_k], ac             ; wounded (aim bit 1, under half its hits): twice as often
    add  SPEC_AIM, x
    ld   [y,x], ac
    and  2, ac
    beq  ot_m
    ld   [ob_k], ac
    add  SPEC_HP, x
    ld   [y,x], ac
    shr  ac
    ld   ac, [tmp2]
    ld   [ob_hp], ac
    sub  [tmp2], ac
    bcc  ot_m
    ld   [tmp], ac
    shr  ac
    ld   ac, [tmp]
ot_m:
    ld   [ob_t], ac
    inc
    ld   ac, [ob_t]
    and  [tmp], ac
    bne  ot_x
    clr  ac
    ld   ac, [tmp]
ot_lp:
    ld   OBJ >> 8, y
    ld   [tmp], x
    ld   [y,x], ac
    beq  ot_put
    ld   [tmp], ac
    inc
    ld   ac, [tmp]
    xor  MAXOBJ, ac
    bne  ot_lp
ot_x:
    ld   ob_enemy >> 8, y
    jmp  ob_enemy
ot_put:
    ld   S_BOLT, [y,x]
    ld   ot_1 >> 8, y
    jmp  ot_1

ot_1:
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_AIM, x
    ld   [y,x], ac
    beq  ot_side
    ld   [ob_k], ac             ; down: from the middle of its underside
    add  SPEC_W, x
    ld   [y,x], ac
    shr  ac
    sub  2, ac
    add  [ob_x], ac
    ld   ac, [tmp3]
    ld   4, ac
    bra  ot_d
ot_side:
    ld   [px], ac
    sub  [ob_x], ac
    bcs  ot_left
    ld   SPEC >> 8, y           ; to the right: from its right edge
    ld   [ob_k], ac
    add  SPEC_W, x
    ld   [y,x], ac
    add  [ob_x], ac
    ld   ac, [tmp3]
    clr  ac
    bra  ot_d
ot_left:
    ld   [ob_x], ac
    sub  4, ac
    ld   ac, [tmp3]
    ld   2, ac
ot_d:
    ld   ac, [tmp2]
    ld   ot_2 >> 8, y
    jmp  ot_2


#addr 0x1500
ot_2:
    ld   OBJ >> 8, y
    ld   [tmp], ac
    add  O_D, x
    ld   [tmp2], ac
    ld   ac, [y,x]
    ld   [tmp], ac
    add  O_X, x
    ld   [tmp3], ac
    ld   ac, [y,x]
    ld   [tmp], ac
    add  O_T, x
    ld   BOLT_FRAMES, [y,x]
    ld   [tmp], ac
    add  O_HP, x
    ld   0, [y,x]
    ld   [tmp], ac
    add  O_P, x
    ld   0, [y,x]
    ld   SPEC >> 8, y           ; cell: its top + 4, every other one 16 lower when it is tall
    ld   [ob_k], ac
    add  SPEC_AIM, x
    ld   [y,x], ac
    beq  ot_y1
    ld   [ob_k], ac             ; (down: its underside)
    add  SPEC_H, x
    ld   [y,x], ac
    add  [ob_y], ac
    ld   ac, [tmp2]
    bra  ot_y2
ot_y1:
    ld   [ob_k], ac
    add  SPEC_H, x
    ld   [y,x], ac
    sub  16, ac
    ld   ac, [tmp2]
    ld   [ob_t], ac
    shr  ac
    shr  ac
    and  [tmp2], ac
    add  [ob_y], ac
    add  4, ac
    ld   ac, [tmp2]
ot_y2:
    ld   OBJ >> 8, y
    ld   [tmp], ac
    add  O_Y, x
    ld   [tmp2], ac
    ld   ac, [y,x]
    ld   66, ac
    ld   LINK_LO, x             ; CALL sfx_b
    ld   lp_r72, [x]
    ld   LINK_HI, x
    ld   lp_r72 >> 8, [x]
    ld   sfx_b >> 8, y
    jmp  sfx_b
lp_r72:
    ld   ob_enemy >> 8, y
    jmp  ob_enemy

; a bolt: 2 byte columns a frame until a wall, the room's edge or Wick
ob_bolt:
    ld   [ob_t], ac
    dec
    ld   ac, [ob_t]
    beq  ol_gone
    ld   [ob_d], ac
    xor  4, ac
    bne  ol_side
    ld   [ob_x], ac             ; down
    add  2, ac
    ld   ac, [ta_x]
    ld   [ob_y], ac
    add  8, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r73, [x]
    ld   LINK_HI, x
    ld   lp_r73 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r73:
    bne  ol_gone
    ld   [ob_y], ac
    add  2, ac
    ld   ac, [ob_y]
    bra  ol_t
ol_side:
    ld   4, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL ob_front
    ld   lp_r74, [x]
    ld   LINK_HI, x
    ld   lp_r74 >> 8, [x]
    ld   ob_front >> 8, y
    jmp  ob_front
lp_r74:
    bne  ol_gone
    ld   LINK_LO, x             ; CALL ob_fwd
    ld   lp_r75, [x]
    ld   LINK_HI, x
    ld   lp_r75 >> 8, [x]
    ld   ob_fwd >> 8, y
    jmp  ob_fwd
lp_r75:
    ld   LINK_LO, x             ; CALL ob_fwd
    ld   lp_r76, [x]
    ld   LINK_HI, x
    ld   lp_r76 >> 8, [x]
    ld   ob_fwd >> 8, y
    jmp  ob_fwd
lp_r76:
ol_t:
    ld   [touchf], ac
    beq  ol_keep
    ld   LINK_LO, x             ; CALL hurt
    ld   lp_r77, [x]
    ld   LINK_HI, x
    ld   lp_r77 >> 8, [x]
    ld   hurt >> 8, y
    jmp  hurt
lp_r77:
ol_gone:
    clr  ac
    ld   ac, [ob_k]
ol_keep:
    ld   ob_save >> 8, y
    jmp  ob_save

; a hopper: it sits, then hops toward Wick: 16 frames of an arc, then a
; fall until it lands

#addr 0x1600
ob_hop:
    ld   [ob_t], ac
    sub  HOP_REST, ac
    bcc  oh_air
    ld   [ob_t], ac
    inc
    ld   ac, [ob_t]
    xor  HOP_REST, ac
    bne  oh_e
    ld   [px], ac
    sub  [ob_x], ac
    bcs  oh_fl
    clr  ac
    bra  oh_fd
oh_fl:
    ld   2, ac
oh_fd:
    ld   ac, [ob_d]
oh_e:
    ld   ob_enemy >> 8, y
    jmp  ob_enemy
oh_air:
    ld   ac, [tmp2]
    sub  16, ac
    bcc  oh_fall
    ld   [tmp2], ac
    add  hopdy & 0xFF, x
    ld   hopdy >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp2]
    ld   [ob_t], ac
    inc
    ld   ac, [ob_t]
    ld   8, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL ob_front
    ld   lp_r78, [x]
    ld   LINK_HI, x
    ld   lp_r78 >> 8, [x]
    ld   ob_front >> 8, y
    jmp  ob_front
lp_r78:
    bne  oh_v
    ld   LINK_LO, x             ; CALL ob_fwd
    ld   lp_r79, [x]
    ld   LINK_HI, x
    ld   lp_r79 >> 8, [x]
    ld   ob_fwd >> 8, y
    jmp  ob_fwd
lp_r79:
    bra  oh_v
oh_fall:
    ld   4, ac
    ld   ac, [tmp2]
oh_v:
    ld   ob_hop2 >> 8, y
    jmp  ob_hop2

ob_hop2:
    ld   [ob_x], ac
    add  4, ac
    ld   ac, [ta_x]
    ld   [tmp2], ac
    blt  oh_up
    add  [ob_y], ac             ; down: does it land?
    ld   ac, [ob_y]
    add  16, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r80, [x]
    ld   LINK_HI, x
    ld   lp_r80 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r80:
    beq  oh_e2
    ld   [ta_y], ac
    and  0xF8, ac
    sub  16, ac
    ld   ac, [ob_y]
    clr  ac
    ld   ac, [ob_t]
    bra  oh_e2
oh_up:
    add  [ob_y], ac             ; up, when nothing is in the way
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r81, [x]
    ld   LINK_HI, x
    ld   lp_r81 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r81:
    bne  oh_e2
    ld   [ta_y], ac
    ld   ac, [ob_y]
oh_e2:
    ld   ob_enemy >> 8, y
    jmp  ob_enemy

; a hoverer: every other frame a step toward the place over Wick
ob_drop:
    ld   [ob_t], ac
    bne  od_fall
    ld   [px], ac
    sub  [ob_x], ac
    add  DROP_NEAR, ac
    sub  2 * DROP_NEAR + 1, ac
    bcc  od_x
    ld   1, ac
    ld   ac, [ob_t]
    bra  od_x
od_fall:
    ld   [ob_x], ac
    add  4, ac
    ld   ac, [ta_x]
    ld   [ob_y], ac
    add  16, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r84, [x]
    ld   LINK_HI, x
    ld   lp_r84 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r84:
    bne  od_burst
    ld   [ob_y], ac
    add  3, ac
    ld   ac, [ob_y]
od_x:
    ld   ob_enemy >> 8, y
    jmp  ob_enemy
od_burst:
    ld   S_PUFF, ac
    ld   ac, [ob_k]
    ld   PUFF_FRAMES, ac
    ld   ac, [ob_t]
    clr  ac
    ld   ac, [ob_d]
    ld   ob_save >> 8, y
    jmp  ob_save

; a flyer: a step sideways every other frame, turning at a wall; between
; them up for 16 frames, then down for 16

#addr 0x1700
ob_hover:
    ld   [fcnt], ac
    and  1, ac
    bne  ov_go
    ld   SPEC >> 8, y           ; (wounded, aim bit 1: every frame)
    ld   [ob_k], ac
    add  SPEC_AIM, x
    ld   [y,x], ac
    and  2, ac
    beq  ov_x
    ld   [ob_k], ac
    add  SPEC_HP, x
    ld   [y,x], ac
    shr  ac
    ld   ac, [tmp]
    ld   [ob_hp], ac
    sub  [tmp], ac
    bcc  ov_x
ov_go:
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_W, x
    ld   [y,x], ac
    shr  ac
    sub  4, ac
    add  [ob_x], ac
    ld   ac, [tmp]
    ld   [px], ac
    sub  [tmp], ac
    beq  ov_x
    bcs  ov_l
    clr  ac
    bra  ov_d
ov_l:
    ld   2, ac
ov_d:
    ld   ac, [ob_d]
    ld   8, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL ob_front
    ld   lp_r82, [x]
    ld   LINK_HI, x
    ld   lp_r82 >> 8, [x]
    ld   ob_front >> 8, y
    jmp  ob_front
lp_r82:
    bne  ov_x
    ld   LINK_LO, x             ; CALL ob_fwd
    ld   lp_r83, [x]
    ld   LINK_HI, x
    ld   lp_r83 >> 8, [x]
    ld   ob_fwd >> 8, y
    jmp  ob_fwd
lp_r83:
ov_x:
    ld   ob_spit >> 8, y
    jmp  ob_spit

; a dropper: it hangs until Wick is under it, falls, and bursts on the floor
ob_fly:
    ld   [ob_t], ac
    inc
    and  63, ac
    ld   ac, [ob_t]
    and  1, ac
    beq  of_vert
    ld   8, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL ob_front
    ld   lp_r85, [x]
    ld   LINK_HI, x
    ld   lp_r85 >> 8, [x]
    ld   ob_front >> 8, y
    jmp  ob_front
lp_r85:
    bne  of_turn
    ld   LINK_LO, x             ; CALL ob_fwd
    ld   lp_r86, [x]
    ld   LINK_HI, x
    ld   lp_r86 >> 8, [x]
    ld   ob_fwd >> 8, y
    jmp  ob_fwd
lp_r86:
    bra  of_x
of_turn:
    ld   [ob_d], ac
    xor  2, ac
    ld   ac, [ob_d]
    bra  of_x
of_vert:
    ld   [ob_x], ac
    add  4, ac
    ld   ac, [ta_x]
    ld   [ob_t], ac
    and  32, ac
    beq  of_up
    ld   [ob_y], ac
    add  16, ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r87, [x]
    ld   LINK_HI, x
    ld   lp_r87 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r87:
    bne  of_x
    ld   [ob_y], ac
    inc
    bra  of_sy
of_up:
    ld   [ob_y], ac
    dec
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r88, [x]
    ld   LINK_HI, x
    ld   lp_r88 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r88:
    bne  of_x
    ld   [ob_y], ac
    dec
of_sy:
    ld   ac, [ob_y]
of_x:
    ld   ob_enemy >> 8, y
    jmp  ob_enemy

; ob_front: AC != 0 when the thing cannot step the way it faces: the
; room's edge, or a wall at cell ob_y + tmp3 of the byte column in front
; (which is left in ta_x)

#addr 0x1800
ob_front:
    ld   [LINK_LO], ac
    ld   ac, [sv_lo]
    ld   [LINK_HI], ac
    ld   ac, [sv_hi]
    ld   [ob_d], ac
    bne  of_left
    ld   [ob_x], ac
    sub  [rwx], ac
    bcc  of_edge
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_W, x
    ld   [y,x], ac
    add  [ob_x], ac
    bra  of_chk
of_left:
    ld   [ob_x], ac
    sub  2, ac
    bcs  of_edge
    ld   [ob_x], ac
    dec
of_chk:
    ld   ac, [ta_x]
    ld   [ob_y], ac
    add  [tmp3], ac
    ld   ac, [ta_y]
    ld   LINK_LO, x             ; CALL tile_at
    ld   lp_r89, [x]
    ld   LINK_HI, x
    ld   lp_r89 >> 8, [x]
    ld   tile_at >> 8, y
    jmp  tile_at
lp_r89:
    bra  of_out
of_edge:
    ld   1, ac
of_out:
    ld   ac, [tmp]
    ld   [sv_lo], ac
    ld   ac, [LINK_LO]
    ld   [sv_hi], ac
    ld   ac, [LINK_HI]
    ld   [tmp], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ob_fwd: a step the way the thing faces
hurt:
    ld   [inv], ac
    bne  hu_r
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   INV_FRAMES, ac
    ld   ac, [inv]
    ld   1, ac
    ld   ac, [hud_dirty]
    ld   [ob_k], ac
    add  SPEC_DMG, x
    ld   SPEC >> 8, y
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   [items], ac            ; (the Cinder Coat: half)
    and  IT_COAT, ac
    beq  hu_d
    ld   [tmp], ac
    inc
    shr  ac
    ld   ac, [tmp]
hu_d:
    ld   [energy], ac
    sub  [tmp], ac
    bcc  hu_e
    clr  ac
hu_e:
    ld   ac, [energy]
    ld   [crawl], ac
    bne  hu_s
    ld   HURTV_HI, ac           ; a hop
    ld   ac, [vyh]
    clr  ac
    ld   ac, [vyl]
hu_s:
    ld   12, ac
    ld   ac, [R0]
    ld   10, ac
    ld   ac, [R2]
    ld   3, ac
    ld   ac, [R3]
    ld   30, ac
    ld   LINK_LO, x             ; CALL sfx_n
    ld   lp_r91, [x]
    ld   LINK_HI, x
    ld   lp_r91 >> 8, [x]
    ld   sfx_n >> 8, y
    jmp  sfx_n
lp_r91:
    ld   lib_leave >> 8, y
    jmp  lib_leave
hu_r:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; after the things: the time Wick cannot be hurt; no energy left: back to
; the landing, with what was found
g_inv:
    ld   [inv], ac
    beq  gi_1
    dec
    ld   ac, [inv]
gi_1:
    ld   HDR >> 8, y            ; a hot room without the Cinder Coat
    ld   H_FLAGS, x
    ld   [y,x], ac
    and  HF_HOT, ac
    beq  gi_2
    ld   [items], ac
    and  IT_COAT, ac
    bne  gi_2
    ld   [fcnt], ac
    and  15, ac
    bne  gi_2
    ld   [energy], ac
    beq  gi_2
    dec
    ld   ac, [energy]
    ld   1, ac
    ld   ac, [hud_dirty]
gi_2:
    ld   [energy], ac
    bne  gi_x
    ld   g_dead >> 8, y
    jmp  g_dead
gi_x:
    ld   g_spr >> 8, y
    jmp  g_spr

; the lantern went out: back at the last save lamp, or the start

#addr 0x1900
g_dead:
    ld   START_ROOM, ac
    ld   ac, [room]
    ld   START_X, ac
    ld   ac, [px]
    ld   START_Y, ac
    ld   ac, [py]
    ld   GOT >> 8, y
    ld   V_SAVED, x
    ld   [y,x], ac
    beq  gd_s
    ld   V_SROOM, x
    ld   [y,x], ac
    ld   ac, [room]
    ld   V_SX, x
    ld   [y,x], ac
    ld   ac, [px]
    ld   V_SY, x
    ld   [y,x], ac
    ld   ac, [py]
gd_s:
    ld   START_ENERGY, ac
    ld   ac, [energy]
    clr  ac
    ld   ac, [pyf]
    ld   ac, [vyl]
    ld   ac, [vyh]
    ld   ac, [crawl]
    ld   ac, [inv]
    ld   M_DEAD, ac
    ld   LINK_LO, x             ; CALL msg_set
    ld   lp_r92, [x]
    ld   LINK_HI, x
    ld   lp_r92 >> 8, [x]
    ld   msg_set >> 8, y
    jmp  msg_set
lp_r92:
    ld   LINK_LO, x             ; CALL load_room
    ld   lp_r93, [x]
    ld   LINK_HI, x
    ld   lp_r93 >> 8, [x]
    ld   load_room >> 8, y
    jmp  load_room
lp_r93:
    ld   LINK_LO, x             ; CALL camera
    ld   lp_r94, [x]
    ld   LINK_HI, x
    ld   lp_r94 >> 8, [x]
    ld   camera >> 8, y
    jmp  camera
lp_r94:
    ld   g_spr >> 8, y
    jmp  g_spr

; ------------------------------------------------------------
; game: the sprite list
; ------------------------------------------------------------
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
    ld   [inv], ac              ; (hurt: he blinks)
    and  2, ac
    bne  sp_4
    ld   [px], ac
    sub  [sx], ac
    add  8, ac
    ld   ac, [tmp2]
    ld   [py], ac
    sub  [sy], ac
    add  32, ac
    ld   ac, [tmp3]
    ld   LINK_LO, x             ; CALL sl_add
    ld   lp_r95, [x]
    ld   LINK_HI, x
    ld   lp_r95 >> 8, [x]
    ld   sl_add >> 8, y
    jmp  sl_add
lp_r95:
sp_4:
    ld   sp_shots >> 8, y
    jmp  sp_shots

sp_shots:
    clr  ac                     ; the shots
    ld   ac, [o_i]
sp_lp:
    ld   [o_i], ac
    add  SH_T, x
    ld   [x], ac
    beq  sp_nx
    ld   [o_i], ac
    inc
    xor  [blast_i], ac
    beq  sp_bl
    ld   F_SHOT, ac
    bra  sp_sf
sp_bl:
    ld   F_BLAST, ac
sp_sf:
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
    ld   lp_r96, [x]
    ld   LINK_HI, x
    ld   lp_r96 >> 8, [x]
    ld   sl_add >> 8, y
    jmp  sl_add
lp_r96:
sp_nx:
    ld   [o_i], ac
    inc
    ld   ac, [o_i]
    xor  3, ac
    bne  sp_lp
    ld   sp_obj >> 8, y
    jmp  sp_obj


#addr 0x1A00
sp_obj:
    clr  ac                     ; the things on the screen
    ld   ac, [ob_i]
so_lp:
    ld   OBJ >> 8, y
    ld   [ob_i], x
    ld   [y,x], ac
    beq  so_nx
    ld   ac, [ob_k]
    ld   [ob_i], ac
    add  O_X, x
    ld   [y,x], ac
    sub  [sx], ac
    add  8, ac
    ld   ac, [tmp2]
    sub  88, ac
    bcc  so_nx
    ld   [ob_i], ac
    add  O_Y, x
    ld   [y,x], ac
    sub  [sy], ac
    add  32, ac
    ld   ac, [tmp3]
    sub  144, ac
    bcc  so_nx
    ld   [ob_i], ac             ; frame: the kind's + the way it faces + 0 or 1
    add  O_D, x
    ld   [y,x], ac
    ld   ac, [tmp]
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_DIRM, x
    ld   [y,x], ac
    and  [tmp], ac
    ld   ac, [tmp]
    ld   [ob_k], ac
    add  SPEC_ANIM, x
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [fcnt], ac
    shr  ac
    shr  ac
    shr  ac
    and  [T0], ac
    add  [tmp], ac
    ld   ac, [tmp]
    ld   [ob_k], ac
    add  SPEC_FRAME, x
    ld   [y,x], ac
    add  [tmp], ac
    ld   ac, [tmp]
    ld   LINK_LO, x             ; CALL sl_add
    ld   lp_r97, [x]
    ld   LINK_HI, x
    ld   lp_r97 >> 8, [x]
    ld   sl_add >> 8, y
    jmp  sl_add
lp_r97:
    ld   SPEC >> 8, y           ; 32 pixels wide: its right half
    ld   [ob_k], ac
    add  SPEC_WIDE, x
    ld   [y,x], ac
    beq  so_nx
    add  [tmp], ac
    ld   ac, [tmp]
    ld   [tmp2], ac
    add  8, ac
    ld   ac, [tmp2]
    sub  88, ac
    bcc  so_nx
    ld   LINK_LO, x             ; CALL sl_add
    ld   lp_r98, [x]
    ld   LINK_HI, x
    ld   lp_r98 >> 8, [x]
    ld   sl_add >> 8, y
    jmp  sl_add
lp_r98:
so_nx:
    ld   [ob_i], ac
    inc
    ld   ac, [ob_i]
    xor  MAXOBJ, ac
    bne  so_lp
    ld   g_hud >> 8, y
    jmp  g_hud

; sl_add: add frame tmp at byte column + 8 tmp2, cell + 32 tmp3 to the list
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
    ld   lp_r99, [x]
    ld   LINK_HI, x
    ld   lp_r99 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
lp_r99:
    ld   s_sp & 0xFF, ac
    ld   ac, [R0]
    ld   s_sp >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r100, [x]
    ld   LINK_HI, x
    ld   lp_r100 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r100:
hu_x:
    ld   g_msg >> 8, y
    jmp  g_msg


#addr 0x1B00
g_msg:
    ld   GOT >> 8, y            ; the message line: blank again after a while
    ld   V_MSG_T, x
    ld   [y,x], ac
    beq  hu_1
    dec
    ld   ac, [y,x]
    bne  hu_1
    ld   V_MSG, x
    ld   ac, [y,x]
    ld   V_MSG_D, x
    ld   1, [y,x]
hu_1:
    ld   V_MSG_D, x
    ld   [y,x], ac
    beq  hu_2
    ld   0, [y,x]
    clr  ac
    ld   ac, [CUR_COL]
    ld   2, ac
    ld   ac, [CUR_ROW]
    ld   V_MSG, x
    ld   [y,x], ac
    ld   ac, [tmp]
    add  m_lo & 0xFF, x
    ld   m_lo >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [tmp], ac
    add  m_hi & 0xFF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r101, [x]
    ld   LINK_HI, x
    ld   lp_r101 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r101:
hu_2:
    ld   frame >> 8, y
    jmp  frame

; ------------------------------------------------------------
; load_room: read LAMP/Rnn.RM (nn = room, hex) to MAP and HDR, and its
; area's tiles when they are not the ones loaded
; ------------------------------------------------------------
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
    ld   lp_r102, [x]
    ld   LINK_HI, x
    ld   lp_r102 >> 8, [x]
    ld   fs_root >> 8, y
    jmp  fs_root
lp_r102:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r103, [x]
    ld   LINK_HI, x
    ld   lp_r103 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r103:
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
    ld   lp_r104, [x]
    ld   LINK_HI, x
    ld   lp_r104 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r104:
    beq  lr_ok
    ld   dos_back >> 8, y
    jmp  dos_back
lr_ok:
    ld   LINK_LO, x             ; CALL mus_poll
    ld   lp_r105, [x]
    ld   LINK_HI, x
    ld   lp_r105 >> 8, [x]
    ld   mus_poll >> 8, y
    jmp  mus_poll
lp_r105:
    clr  ac
    ld   ac, [R4]
    ld   MAP >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r106, [x]
    ld   LINK_HI, x
    ld   lp_r106 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r106:
    ld   LINK_LO, x             ; (R4, R5 kept)
    ld   lp_r107, [x]
    ld   LINK_HI, x
    ld   lp_r107 >> 8, [x]
    ld   mus_poll >> 8, y
    jmp  mus_poll
lp_r107:
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r108, [x]
    ld   LINK_HI, x
    ld   lp_r108 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r108:
    ld   LINK_LO, x             ; CALL mus_poll
    ld   lp_r109, [x]
    ld   LINK_HI, x
    ld   lp_r109 >> 8, [x]
    ld   mus_poll >> 8, y
    jmp  mus_poll
lp_r109:
    ld   lr_2 >> 8, y
    jmp  lr_2


#addr 0x1C00
lr_2:
    ld   HDR >> 8, y
    ld   H_AREA, x
    ld   [y,x], ac
    xor  [area], ac
    beq  lr_3
    xor  [area], ac
    ld   ac, [area]
    ld   LINK_LO, x             ; CALL load_area
    ld   lp_r110, [x]
    ld   LINK_HI, x
    ld   lp_r110 >> 8, [x]
    ld   load_area >> 8, y
    jmp  load_area
lp_r110:
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
    ld   ac, [blast_i]
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
    ld   lp_r111, [x]
    ld   LINK_HI, x
    ld   lp_r111 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r111:
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
    ld   lp_r112, [x]
    ld   LINK_HI, x
    ld   lp_r112 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r112:
    clr  ac                     ; the room's things
    ld   ac, [ob_i]
ls_lp:
    ld   HDR >> 8, y
    ld   [ob_i], ac
    add  HO_KIND, x
    ld   [y,x], ac
    ld   ac, [ob_k]
    ld   [ob_i], ac
    add  HO_X, x
    ld   [y,x], ac
    ld   ac, [ob_x]
    ld   [ob_i], ac
    add  HO_Y, x
    ld   [y,x], ac
    ld   ac, [ob_y]
    ld   [ob_i], ac
    add  HO_P, x
    ld   [y,x], ac
    ld   ac, [ob_p]
    ld   ls_2 >> 8, y
    jmp  ls_2

ls_2:
    clr  ac
    ld   ac, [ob_d]
    ld   ac, [ob_t]
    ld   SPEC >> 8, y
    ld   [ob_k], ac
    add  SPEC_HP, x
    ld   [y,x], ac
    ld   ac, [ob_hp]
    ld   [ob_p], ac             ; with an item: none when it is found
    beq  ls_put
    and  31, ac
    ld   ac, x
    ld   GOT >> 8, y
    ld   [y,x], ac
    beq  ls_3
    clr  ac
    ld   ac, [ob_k]
    bra  ls_put
ls_3:
    ld   [ob_k], ac             ; an item: its type picks its frame
    xor  S_ITEM, ac
    bne  ls_put
    ld   [ob_p], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [ob_d]
ls_put:
    ld   LINK_LO, x             ; CALL ob_store
    ld   lp_r113, [x]
    ld   LINK_HI, x
    ld   lp_r113 >> 8, [x]
    ld   ob_store >> 8, y
    jmp  ob_store
lp_r113:
    ld   [ob_i], ac
    inc
    ld   ac, [ob_i]
    xor  MAXOBJ, ac
    beq  ls_x
    ld   ls_lp >> 8, y
    jmp  ls_lp
ls_x:
    ld   ls_end >> 8, y
    jmp  ls_end

; the end of a room's reading: its seal, its message

#addr 0x1D00
ls_end:
    ld   LINK_LO, x             ; CALL seal_check
    ld   lp_r114, [x]
    ld   LINK_HI, x
    ld   lp_r114 >> 8, [x]
    ld   seal_check >> 8, y
    jmp  seal_check
lp_r114:
    ld   [tmp3], ac             ; (no message while the seal is shut)
    beq  le_x
    ld   HDR >> 8, y
    ld   H_MSG, x
    ld   [y,x], ac
    beq  le_x
    ld   LINK_LO, x             ; CALL msg_set
    ld   lp_r115, [x]
    ld   LINK_HI, x
    ld   lp_r115 >> 8, [x]
    ld   msg_set >> 8, y
    jmp  msg_set
lp_r115:
le_x:
    ld   [room], ac
    xor  END_ROOM, ac
    bne  le_y
    ld   ending >> 8, y
    jmp  ending
le_y:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; the end: the time and the things found on the fourth line; then a key
ending:
    ld   1, ac                  ; the song's subtune 1: the ending's
    ld   LINK_LO, x             ; CALL mus_start
    ld   lp_r116, [x]
    ld   LINK_HI, x
    ld   lp_r116 >> 8, [x]
    ld   mus_start >> 8, y
    jmp  mus_start
lp_r116:
    ld   GOT >> 8, y
    ld   V_MODE, x
    ld   M_END, [y,x]
    ld   V_MSG_T, x             ; (the message stays)
    ld   0, [y,x]
    clr  ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   s_time & 0xFF, ac
    ld   ac, [R0]
    ld   s_time >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r117, [x]
    ld   LINK_HI, x
    ld   lp_r117 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r117:
    ld   GOT >> 8, y
    ld   V_MIN, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   lp_r118, [x]
    ld   LINK_HI, x
    ld   lp_r118 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
lp_r118:
    ld   0x3A, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   lp_r119, [x]
    ld   LINK_HI, x
    ld   lp_r119 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
lp_r119:
    ld   GOT >> 8, y
    ld   V_SEC, x
    ld   [y,x], ac
    sub  10, ac
    bcc  en_1
    ld   0x30, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   lp_r120, [x]
    ld   LINK_HI, x
    ld   lp_r120 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
lp_r120:
en_1:
    ld   GOT >> 8, y
    ld   V_SEC, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   lp_r121, [x]
    ld   LINK_HI, x
    ld   lp_r121 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
lp_r121:
    ld   ending2 >> 8, y
    jmp  ending2

s_dir:    #d "LAMP", 0x00
s_room:   #d "R00.RM", 0x00
s_area:   #d "A0.TS", 0x00
s_hex:    #d "0123456789ABCDEF"
s_energy: #d "ENERGY", 0x00
s_save:   #d "SAVE.DAT", 0x00


#addr 0x1E00
ending2:
    clr  ac                     ; things found: GOT 1-31
    ld   ac, [tmp]
    ld   1, ac
    ld   ac, [tmp2]
en_lp:
    ld   GOT >> 8, y
    ld   [tmp2], x
    ld   [y,x], ac
    beq  en_n
    ld   [tmp], ac
    inc
    ld   ac, [tmp]
en_n:
    ld   [tmp2], ac
    inc
    ld   ac, [tmp2]
    xor  32, ac
    bne  en_lp
    ld   s_found & 0xFF, ac
    ld   ac, [R0]
    ld   s_found >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r122, [x]
    ld   LINK_HI, x
    ld   lp_r122 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r122:
    ld   [tmp], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   lp_r123, [x]
    ld   LINK_HI, x
    ld   lp_r123 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
lp_r123:
    ld   s_of & 0xFF, ac
    ld   ac, [R0]
    ld   s_of >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   lp_r124, [x]
    ld   LINK_HI, x
    ld   lp_r124 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
lp_r124:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; the thing that a beaten creature guarded; its keeper is beaten
seal_check:
    ld   1, ac
    ld   ac, [tmp3]
    ld   HDR >> 8, y
    ld   H_SEALN, x
    ld   [y,x], ac
    beq  sc_x
    ld   ac, [tmp3]
    ld   H_SEAL, ac
    ld   ac, [tmp2]
sc_lp:
    ld   HDR >> 8, y
    ld   [tmp2], x
    ld   [y,x], ac
    add  G_BEAT, x
    ld   GOT >> 8, y
    ld   [y,x], ac
    beq  sc_shut
    ld   [tmp2], ac
    inc
    ld   ac, [tmp2]
    ld   [tmp3], ac
    dec
    ld   ac, [tmp3]
    bne  sc_lp
    ld   MAP >> 8, ac
    ld   ac, [tmp3]
    clr  ac
    ld   ac, [tmp2]
sc_t:
    ld   [tmp3], y
    ld   [tmp2], x
    ld   [y,x], ac
    ld   ac, x
    ld   ATTR >> 8, y
    ld   [y,x], ac
    and  A_SEAL, ac
    beq  sc_n
    ld   [tmp3], y
    ld   [tmp2], x
    ld   0, [y,x]
sc_n:
    ld   [tmp2], ac
    inc
    ld   ac, [tmp2]
    bne  sc_t
    ld   [tmp3], ac
    inc
    ld   ac, [tmp3]
    xor  (MAP >> 8) + 2, ac
    bne  sc_t
sc_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sc_shut:
    ld   ac, [tmp3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; load_area: read LAMP/An.TS (n = area): 8 sectors to AREA_BLK on (the
; song, player code, the tables), one to PCODE_B, the rest to x6000 on

#addr 0x2000
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
    ld   LINK_LO, x             ; (the player's code is read again)
    ld   lp_r126, [x]
    ld   LINK_HI, x
    ld   lp_r126 >> 8, [x]
    ld   mus_quiet >> 8, y
    jmp  mus_quiet
lp_r126:
    ld   LINK_LO, x             ; CALL fs_root
    ld   lp_r127, [x]
    ld   LINK_HI, x
    ld   lp_r127 >> 8, [x]
    ld   fs_root >> 8, y
    jmp  fs_root
lp_r127:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   lp_r128, [x]
    ld   LINK_HI, x
    ld   lp_r128 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r128:
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
    ld   lp_r129, [x]
    ld   LINK_HI, x
    ld   lp_r129 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
lp_r129:
    beq  la_ok
    ld   dos_back >> 8, y
    jmp  dos_back
la_ok:
    clr  ac
    ld   ac, [R4]
    ld   AREA_BLK >> 8, ac
    ld   ac, [R5]
la_rd:
    ld   LINK_LO, x             ; CALL fs_read
    ld   lp_r130, [x]
    ld   LINK_HI, x
    ld   lp_r130 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
lp_r130:
    bne  la_done
    ld   [R5], ac               ; after the block: PCODE_B
    xor  AREA_END >> 8, ac
    beq  la_b
    xor  (AREA_END ^ (PCODE_B + 0x200)) >> 8, ac
    bne  la_rd                  ; after that: the video RAM
    ld   0x60, ac
    ld   ac, [R5]
    bra  la_rd
la_b:
    ld   PCODE_B >> 8, ac
    ld   ac, [R5]
    bra  la_rd
la_done:
    ld   GOT >> 8, y            ; the song: subtune 1 on the title, else 0
    ld   V_MODE, x
    ld   [y,x], ac
    xor  M_TITLE, ac
    beq  la_t
    clr  ac
    ld   LINK_LO, x             ; CALL mus_start
    ld   lp_r131, [x]
    ld   LINK_HI, x
    ld   lp_r131 >> 8, [x]
    ld   mus_start >> 8, y
    jmp  mus_start
lp_r131:
    ld   lib_leave >> 8, y
    jmp  lib_leave
la_t:
    ld   1, ac
    ld   LINK_LO, x             ; CALL mus_start
    ld   lp_r132, [x]
    ld   LINK_HI, x
    ld   lp_r132 >> 8, [x]
    ld   mus_start >> 8, y
    jmp  mus_start
lp_r132:
    ld   lib_leave >> 8, y
    jmp  lib_leave

zswap:
    ld   0x60, ac
zs_l:
    ld   ac, [T1]
    ld   ac, x
    ld   [x], ac
    ld   ac, [T0]
    ld   ZSAVE >> 8, y
    ld   [y,x], ac
    ld   ac, [x]
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [T1], ac
    inc
    xor  0x90, ac
    beq  zs_d
    xor  0x90, ac
    bra  zs_l
zs_d:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; mus_tick: (GOTO, map FF after the sprites) the waiting sound effect and
; mus_frame, then map 07 and the rules
sfx_b:
    sub  12, ac                 ; (the player's C-0 is note 0)
    ld   ZSAVE >> 8, y
    ld   ZV_SN, x
    ld   ac, [y,x]
    ld   ZV_SI, x
    ld   SFX_BEEP, [y,x]
    ld   ZV_SF, x
    ld   12, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sfx_n:
    sub  12, ac
    ld   ZSAVE >> 8, y
    ld   ZV_SN, x
    ld   ac, [y,x]
    ld   ZV_SI, x
    ld   SFX_NOISE, [y,x]
    ld   ZV_SF, x
    ld   6, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
s_t0:     #d "LAMPLIGHTER                             ", 0x00
s_t2:     #d "JUMP: A NEW GAME                        ", 0x00
s_t3:     #d "FIRE: GO ON FROM THE LAST SAVE LAMP     ", 0x00
s_blank:  #d "                                        ", 0x00
s_time:   #d "TIME ", 0x00
s_found:  #d "   FOUND ", 0x00
s_of:     #d " OF 14   JUMP: THE TITLE", 0x00
s_sp:     #d "  ", 0x00
s_bits:   #d8 1, 2, 4, 8, 16, 32, 64, 128


#addr 0x2200
s_m0: #d "                                        ", 0x00
s_m1: #d "OIL FLASK: THE LANTERN HOLDS MORE       ", 0x00
s_m2: #d "BURROW RIG: HOLD DOWN TO CRAWL          ", 0x00
s_m3: #d "UPDRAFT BELLOWS: JUMP AGAIN IN THE AIR  ", 0x00
s_m4: #d "ASH SAIL: HOLD JUMP TO FALL SLOWLY      ", 0x00

#addr 0x2300
s_m5: #d "KILN CHARGE: HOLD FIRE, LET GO: A BLAST ", 0x00
s_m6: #d "WIDE FLAME: THREE SPARKS AT A TIME      ", 0x00
s_m7: #d "CINDER COAT: HALF THE HARM, NO HEAT     ", 0x00
s_m8: #d "BALLAST BOOTS: NO DRAG UNDER WATER      ", 0x00
s_m9: #d "THE LANTERN WENT OUT                    ", 0x00

#addr 0x2400
s_m10: #d "THREE KEEPERS DOWN: THE SEAL IS OPEN    ", 0x00
s_m11: #d "THE GREAT LAMP BURNS AGAIN              ", 0x00
s_m12: #d "SAVED AT THE LAMP: THE LANTERN IS FULL  ", 0x00

; ------------------------------------------------------------
; music: the player (placard_mus.masm, assembled apart by gen_lamp.py:
; part of its code is in the video RAM and the area block) runs in map FF,
; with x60-x8F of the zero page its own: zswap trades them with ZSAVE.
; The game asks for a sound effect with sfx_b / sfx_n (map 07); mus_tick
; plays it and calls mus_frame once a frame, after the drawing.
; ------------------------------------------------------------
ZV_ON  = 0x00                   ; (ZSAVE page) 1: a song is set up
ZV_SN  = 0x01                   ; a sound effect waiting: its note (0: none)
ZV_SI  = 0x02                   ;   instrument
ZV_SF  = 0x03                   ;   frames

; zswap: x60-x8F <-> ZSAVE + x60-x8F.  Changes AC, X, Y, T0, T1.
mus_tick:
    ld   ZSAVE >> 8, y
    ld   ZV_ON, x
    ld   [y,x], ac
    beq  mt_x
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r133, [x]
    ld   LINK_HI, x
    ld   lp_r133 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r133:
    ld   ZSAVE >> 8, y
    ld   ZV_SI, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   ZV_SF, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   ZV_SN, x
    ld   [y,x], ac
    beq  mt_f
    ld   0, [y,x]
    ld   LINK_LO, x             ; CALL mus_sfx
    ld   lp_r134, [x]
    ld   LINK_HI, x
    ld   lp_r134 >> 8, [x]
    ld   mus_sfx >> 8, y
    jmp  mus_sfx
lp_r134:
mt_f:
    ld   LINK_LO, x             ; CALL mus_frame
    ld   lp_r135, [x]
    ld   LINK_HI, x
    ld   lp_r135 >> 8, [x]
    ld   mus_frame >> 8, y
    jmp  mus_frame
lp_r135:
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r136, [x]
    ld   LINK_HI, x
    ld   lp_r136 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r136:
mt_x:
    ld   0x50, y                ; map 07 (the library)
    ld   0x07, [y,x]
    ld   logic >> 8, y
    jmp  logic

; mus_start: AC = subtune: the area's song (SONG) from the start

#addr 0x2500
mus_start:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
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
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r137, [x]
    ld   LINK_HI, x
    ld   lp_r137 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r137:
    ld   0x50, y                ; map FF: the player
    ld   0xFF, [y,x]
    ld   SONG >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL mus_init
    ld   lp_r138, [x]
    ld   LINK_HI, x
    ld   lp_r138 >> 8, [x]
    ld   mus_init >> 8, y
    jmp  mus_init
lp_r138:
    ld   [R2], ac
    ld   LINK_LO, x             ; CALL mus_play
    ld   lp_r139, [x]
    ld   LINK_HI, x
    ld   lp_r139 >> 8, [x]
    ld   mus_play >> 8, y
    jmp  mus_play
lp_r139:
    ld   0x50, y
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r140, [x]
    ld   LINK_HI, x
    ld   lp_r140 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r140:
    ld   ZSAVE >> 8, y
    ld   ZV_ON, x
    ld   1, [y,x]
    ld   ZV_SN, x
    ld   0, [y,x]
    ld   lib_leave >> 8, y
    jmp  lib_leave

; mus_quiet: silence in the buffer and no more ticks (before the player's
; code or the song is read again, or a long card write)
mus_quiet:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   ZSAVE >> 8, y
    ld   ZV_ON, x
    ld   [y,x], ac
    beq  mq_x
    ld   0, [y,x]
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r141, [x]
    ld   LINK_HI, x
    ld   lp_r141 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r141:
    ld   0x50, y
    ld   0xFF, [y,x]
    ld   SONG >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL mus_init
    ld   lp_r142, [x]
    ld   LINK_HI, x
    ld   lp_r142 >> 8, [x]
    ld   mus_init >> 8, y
    jmp  mus_init
lp_r142:
    ld   0x50, y
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r143, [x]
    ld   LINK_HI, x
    ld   lp_r143 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r143:
mq_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; mus_poll: mus_frame from the rules (map 07), while the card is read

#addr 0x2600
mus_poll:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   ZSAVE >> 8, y
    ld   ZV_ON, x
    ld   [y,x], ac
    beq  mp_x
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r144, [x]
    ld   LINK_HI, x
    ld   lp_r144 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r144:
    ld   0x50, y
    ld   0xFF, [y,x]
    ld   LINK_LO, x             ; CALL mus_frame
    ld   lp_r145, [x]
    ld   LINK_HI, x
    ld   lp_r145 >> 8, [x]
    ld   mus_frame >> 8, y
    jmp  mus_frame
lp_r145:
    ld   0x50, y
    ld   0x07, [y,x]
    ld   LINK_LO, x             ; CALL zswap
    ld   lp_r146, [x]
    ld   LINK_HI, x
    ld   lp_r146 >> 8, [x]
    ld   zswap >> 8, y
    jmp  zswap
lp_r146:
mp_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; sfx_b: AC = MIDI note: a short fading note.  sfx_n: AC = MIDI note
; (the noise's pitch): a hit.  The latest asked for in a frame plays.
