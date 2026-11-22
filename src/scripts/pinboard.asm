; ============================================================
; made by asm_expand.py from pinboard.masm: change that file, then run
;     python3 asm_expand.py pinboard.masm
; ============================================================

; ============================================================
; pinboard.masm - Pinboard, the windowed desktop: the native code
; ============================================================
;
; Pinboard (docs/software/PINBOARD.md) is a program on the SD card,
; PINBOARD.PLC: cards (windows) pinned on a board, a pointer for the PS/2
; mouse, a rail along the bottom with the launcher and the open cards.
; Its cards are the file browser (it runs the card's .PLC programs), a
; clock, a calculator, a text editor, a note about itself and the choice
; of the screen's mode.
;
; The desktop itself is written in bytecode (pinboard.vm, compiled by
; vmc.py when asm_expand.py meets the .include at the end of this file),
; for the same small stack machine as BASIC's (basic.masm; docs/software/
; BASIC.md, "The bytecode machine").  This file is that machine, copied
; from basic.masm with one change, and the primitives that have to be
; fast or touch the hardware:
;
;   the change   the words are in the RAM, below x8000, so a call's first
;                byte is the word's high byte + x80 (vmc.py: RAMCALLS) and
;                next takes the x80 off
;   EMIT HFILL GTYPE   characters at the cell GX, GY, kept inside the clip
;                rectangle CX0-CX1, CY0-CY1, from Pinboard's own font
;   INVC         turns the cell at GX, GY over (the outline of a card
;                being moved)
;   PTR          shows or hides the pointer (the screen under it is kept)
;   POLL         a frame's wait, the keyboard and the mouse; the key
;
; The drawing itself is the display driver's: x2E00-x3FFF (DRV), one for
; each mode of the screen, with its font and its pointer.  This file is
; the core, the same under every driver; pinboard_drv_mono.masm is the
; 640 x 480, 2-color driver that PINBOARD.PLC starts with, and
; pinboard_drv_color.masm the two for the rev B board's 4 and 16 colors,
; which Pinboard reads from the card's PINBOARD folder (pinboard.vm:
; Display).  pinboard_hdr.masm has what they share.
;
; RAM: the core x0100-x2DFF (asm_expand.py pages it), the driver
; x2E00-x3FFF; zero page x20-x4F and x90-x9F (no sound driver); the
; data stack x53-x8F (x50-x52 the drawing's); x4000-x4AFF the Editor's
; text, x4B00 the pointer's saved screen and the desktop's variables,
; x4C00 the return stack;
; x5400-x59FF the folder read; the menu block x5D00 and the FAT reader's
; x4D00-x4FFF as for every program.
;
;     python3 gen_pinboard.py     the drivers' tables, pinboard.asm,
;                                 ../../sdcard/PINBOARD.PLC and the
;                                 drivers in ../../sdcard/PINBOARD
;     python3 test_pinboard.py    runs it from a card in the emulator
;
; Date: 11/17/2026
; ============================================================

; pinboard_hdr.masm - what pinboard.masm (the core) and its display
; drivers (pinboard_drv_*.masm) share: the constants and the macros.
; Date: 11/17/2026

#include "placard.asm"
#include "placard_lib.asm"

PB_PTR    = 0x3600      ; the pointer's tables, 2 pages
PB_FONT   = 0x3800      ; the font, 8 pages
DRV       = 0x2E00      ; the display driver: x2E00-x3FFF, a file of its own
DRV_CELLS = DRV         ;   its entries (GOTO: EMIT, HFILL and GTYPE end there)
DRV_INVC  = DRV + 4     ;   (GOTO: INVC)
DRV_HIDE  = DRV + 8     ;   (CALL: the pointer off the screen)
DRV_SHOW  = DRV + 12    ;   (CALL: the pointer on it)
DRV_INIT  = DRV + 16    ;   (CALL: the screen cleared, its rows' mode bytes)
DRV_PENS  = DRV + 0x20  ;   24 pens: FX, BG (pinboard.vm: PEN)
DRV_PAR   = DRV + 0x50  ;   columns, rows, the board's rows, the pointer's shifts, the board's character
DRV_WINIT = DRV + 0x58  ;   6 cards: x, y, w, h
MAP_RUN   = 0x07        ; sections 0-2 RAM, 3-7 ROM

; the machine's zero page (as basic.masm)
IPL     = 0x20
IPH     = 0x21
TL      = 0x22
TH      = 0x23
DSP     = 0x24
RSP     = 0x25
W0      = 0x26          ; scratch for the primitives
W1      = 0x27
W2      = 0x28
W3      = 0x29
W4      = 0x2A
W5      = 0x2B
W6      = 0x2C
W7      = 0x2D
DS_EMPTY = 0x90         ; the data stack: x50-x8F
RSTK    = 0x4C00        ; the return stack page
PSAVE   = 0x4B00        ; the screen under the pointer: 2 bytes a row

; the drawing primitives' zero page (pinboard.vm knows these too)
GX      = 0x30          ; the cell the next character goes to
GY      = 0x31
CX0     = 0x32          ; the clip rectangle: CX0 <= GX < CX1,
CY0     = 0x33          ; CY0 <= GY < CY1
CX1     = 0x34
CY1     = 0x35
CFX     = 0x2E          ; the pen (color drivers): the two colors XORed,
CBG     = 0x2F          ; and the color of a 0 bit; a whole byte of each
INV     = 0x36          ; GTYPE: 80 for black ink on a card, 00 white on black
MOK     = 0x37          ; mouse_init's answer: 0 = a mouse runs
PXL     = 0x38          ; the pointer: X 0-639
PXH     = 0x39
PYL     = 0x3A          ; Y 0-479
PYH     = 0x3B
MOVED   = 0x3C          ; POLL sets it when the mouse sent something
SH_ON   = 0x3D          ; 1: the pointer is on the screen, at:
SH_C2   = 0x3E          ;   60 + 2 x its byte column
SH_YL   = 0x3F          ;   its first row
SH_YH   = 0x40
SH_TI   = 0x41          ;   its shift << 4
SH_N    = 0x42          ;   its rows on the screen
SH_K    = 0x43          ;   1: its right byte is on the screen too
VH      = 0x44          ; a cell: its column's page
VL0     = 0x45          ; x45-x4C: the low bytes of its 8 rows
VPG     = 0x4D          ; 60 or 61: the page of the row in a column
N_CH    = 0x4E          ; the character
N_CNT   = 0x4F          ; characters to go
N_MODE  = 0x50          ; 1: GTYPE (characters from N_PH:N_PL)
N_PL    = 0x51
N_PH    = 0x52

; ------------------------------------------------------------
; macros (basic.masm)
; ------------------------------------------------------------

; ============================================================
; basic - the vector x8024 comes here (power-up with no card, the DOS's



; ============================================================
; main - the ROM's loader enters here (map 07, the card mounted)
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL mouse_init
    ld   pb_r1, [x]
    ld   LINK_HI, x
    ld   pb_r1 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
pb_r1:
    ld   ac, [MOK]
    clr  ac
    ld   ac, [SH_ON]
    ld   ac, [MOVED]
    ld   ac, [PYH]
    ld   240, ac
    ld   ac, [PYL]
    ld   320 & 0xFF, ac
    ld   ac, [PXL]
    ld   1, ac
    ld   ac, [PXH]
    ld   DS_EMPTY, ac
    ld   ac, [DSP]
    ld   0xFF, ac
    ld   ac, [RSP]
    ld   w_COLD & 0xFF, ac
    ld   ac, [IPL]
    ld   w_COLD >> 8, ac
    ld   ac, [IPH]
    ld   next >> 8, y
    jmp  next

; ============================================================
; the inner interpreter and the primitives every program of the
; machine needs, from basic.masm
; ============================================================
w_F_M_DRAW:
    #d8 1, 1, 1, 1, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 14, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 1, 1
    #d8 (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 2, 96, 93, 25, 4, 7, 2, 96, 93, (w_ZTYPE >> 8) | 0x80
    #d8 w_ZTYPE & 0xFF, 3, 4, 1, 92, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 1, 0, 12, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF
    #d8 39, 4, 11, 12, 2, 146, 75, 25, 27, (w_F_M_ROW >> 8) | 0x80, w_F_M_ROW & 0xFF, 33
    #d8 3, 239, 13, (w_INK >> 8) | 0x80, w_INK & 0xFF, (w_SBX >> 8) | 0x80, w_SBX & 0xFF, 1, 2, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1
    #d8 8, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 1, 3, 12, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 33, 39, 4, 12
    #d8 (w_SBX >> 8) | 0x80, w_SBX & 0xFF, 15, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 15, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 33, 3, 237
    #d8 13, (w_SBX >> 8) | 0x80, w_SBX & 0xFF, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 33, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 9, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF
    #d8 (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 2, 144, 75, 25, 39, 4, 30, (w_SBX >> 8) | 0x80, w_SBX & 0xFF, 2
    #d8 146, 75, 25, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 1, 3, 28, 42, 2, 144, 75
    #d8 25, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 28, 43, 16, 1, 3, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1
    #d8 17, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 1, 1, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 1, 2, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF
    #d8 2, 148, 75, 23, 12, 4, 8, 10, 147, 1, 3, 28
    #d8 5, w_CTYPE & 0xFF, w_CTYPE >> 8, 13, 2, 144, 75, 25, (w_U_GT_S >> 8) | 0x80, w_U_GT_S & 0xFF, 51, 7
    #d8 6, 32, 105, 116, 101, 109, 115, 5, w_TYPE & 0xFF, w_TYPE >> 8, 0
w_RAIL:
    #d8 1, 4, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 0, (w_BOARD_M_H >> 8) | 0x80, w_BOARD_M_H & 0xFF, (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 1, 16
    #d8 (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 50, (w_RAIL_M_Y >> 8) | 0x80, w_RAIL_M_Y & 0xFF, 12, 2, 81, 46, 25, 39, 4
    #d8 13, 1, 0, 15, (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 1, 32, (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 50, 33
    #d8 3, 235, 13, 1, 5, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 1, (w_RAIL_M_Y >> 8) | 0x80, w_RAIL_M_Y & 0xFF, (w_ABS_M_AT >> 8) | 0x80
    #d8 w_ABS_M_AT & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 7, 10, 32, 80, 105, 110, 98, 111, 97
    #d8 114, 100, 32, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 1, 0, 1, 0, 12, 1, 6
    #d8 39, 4, 84, 12, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 25, 4, 75, 15, (w_TABW >> 8) | 0x80, w_TABW & 0xFF
    #d8 42, 1, 11, 27, 12, (w_RAIL_M_Y >> 8) | 0x80, w_RAIL_M_Y & 0xFF, (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 19, 12, (w_TOPW >> 8) | 0x80
    #d8 w_TOPW & 0xFF, 37, 4, 8, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 0, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 3, 6
    #d8 (w_REV >> 8) | 0x80, w_REV & 0xFF, 1, 6, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, (w_TABW >> 8) | 0x80, w_TABW & 0xFF, 1, 8, 39, 40
    #d8 4, 4, 1, 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 12, 35, 2, (w_TITLES) & 0xFF, (w_TITLES) >> 8, 27
    #d8 23, 21, (w_TABW >> 8) | 0x80, w_TABW & 0xFF, 27, 34, 10, 48, 28, (w_CTYPE >> 8) | 0x80, w_CTYPE & 0xFF, 20
    #d8 (w_TABW >> 8) | 0x80, w_TABW & 0xFF, 27, 34, 10, 48, 28, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 14, 33, 14
    #d8 33, 3, 166, 13, 13, 5, w_RAIL_M_TIME & 0xFF, w_RAIL_M_TIME >> 8
w_F_M_INIT:
    #d8 2, 17, 93, 25, 1, 80, 37, 4, 70, 2, 19, 93
    #d8 25, 2, 145, 75, 26, 2, 20, 93, 25, 2, 146, 75
    #d8 26, 2, 21, 93, 25, 2, 140, 75, 26, 2, 21, 93
    #d8 33, 25, 2, 141, 75, 26, 2, 21, 93, 1, 2, 27
    #d8 25, 2, 142, 75, 26, 2, 25, 93, 25, 4, 50, 2
    #d8 27, 93, 2, 96, 77, 1, 4, 45, 2, 27, 93, 2
    #d8 80, 93, 1, 4, 45, 3, 30, 1, 0, 2, 145, 75
    #d8 26, 1, 0, 2, 146, 75, 26, 1, 0, 2, 140, 75
    #d8 26, 1, 0, 2, 141, 75, 26, 1, 0, 2, 142, 75
    #d8 26, 1, 0, 2, 25, 93, 26, 1, 0, 2, 17, 93
    #d8 26, 1, 0, 2, 148, 75, 24, (w_DIR_M_READ >> 8) | 0x80, w_DIR_M_READ & 0xFF, 2, 145, 75
    #d8 25, 2, 144, 75, 25, 39, 40, 4, 12, 1, 0, 2
    #d8 145, 75, 26, 1, 0, 2, 146, 75, 26, 0
w_E_M_ASK:
    #d8 1, 0, 11, 155, 1, 0, 53, 1, 3, (w_SETW >> 8) | 0x80, w_SETW & 0xFF, 1
    #d8 1, 1, 1, (w_AT >> 8) | 0x80, w_AT & 0xFF, (w_REV >> 8) | 0x80, w_REV & 0xFF, 2, (w_E_M_ASKM) & 0xFF, (w_E_M_ASKM) >> 8, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF
    #d8 2, 112, 75, 10, 155, 51, 1, 95, 49, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF, 1
    #d8 10, 28, 10, 155, 28, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 1, 53
    #d8 54, (w_TIME_M_ADV >> 8) | 0x80, w_TIME_M_ADV & 0xFF, 12, 40, 4, 3, 13, 3, 246, 12, 1
    #d8 27, 37, 4, 4, 13, 1, 0, 0, 12, 1, 10, 37
    #d8 10, 155, 40, 40, 29, 4, 23, 13, 1, 0, 10, 155
    #d8 2, 112, 75, 27, 26, 2, 112, 75, 2, 228, 75, 1
    #d8 13, 45, 2, 255, 255, 0, 12, 1, 8, 37, 4, 9
    #d8 10, 155, 4, 5, 10, 155, 34, 11, 155, 12, 1, 33
    #d8 28, 1, 94, 38, 10, 155, 1, 12, 39, 29, 4, 15
    #d8 12, 1, 97, 28, 1, 26, 38, 4, 3, 1, 32, 28
    #d8 12, (w_N_P_ >> 8) | 0x80, w_N_P_ & 0xFF, 13, 5, (w_E_M_ASK + 4) & 0xFF, (w_E_M_ASK + 4) >> 8, 0
w_C_M_DRAW:
    #d8 1, 19, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 2, 140, 75, 25, 1, 10, 43, 1
    #d8 2, (w_BIGDIG >> 8) | 0x80, w_BIGDIG & 0xFF, 1, 6, (w_BIGDIG >> 8) | 0x80, w_BIGDIG & 0xFF, 2, 141, 75, 25, 1
    #d8 10, 43, 1, 12, (w_BIGDIG >> 8) | 0x80, w_BIGDIG & 0xFF, 1, 16, (w_BIGDIG >> 8) | 0x80, w_BIGDIG & 0xFF, 2, 142
    #d8 75, 25, 1, 10, 43, 1, 22, (w_BIGDIG >> 8) | 0x80, w_BIGDIG & 0xFF, 1, 26, (w_BIGDIG >> 8) | 0x80
    #d8 w_BIGDIG & 0xFF, 1, 10, 1, 3, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 32, 49, 1, 10
    #d8 1, 5, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 32, 49, 1, 20, 1, 3, (w_AT >> 8) | 0x80
    #d8 w_AT & 0xFF, 1, 32, 49, 1, 20, 1, 5, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 32
    #d8 49, 1, 3, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 2, 1, 8, (w_AT >> 8) | 0x80, w_AT & 0xFF, (w_REV >> 8) | 0x80
    #d8 w_REV & 0xFF, 7, 4, 32, 72, 43, 32, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1
    #d8 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, (w_REV >> 8) | 0x80, w_REV & 0xFF, 7, 4, 32, 77, 43, 32, (w_TYPE >> 8) | 0x80
    #d8 w_TYPE & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, (w_REV >> 8) | 0x80, w_REV & 0xFF, 7, 5, 32
    #d8 58, 48, 48, 32, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 0, 5, w_PEN & 0xFF
    #d8 w_PEN >> 8
w_E_M_OPEN:
    #d8 2, 223, 75, 25, 4, 13, 13, 2, (w_E_M_BUSYM) & 0xFF, (w_E_M_BUSYM) >> 8, 2, 148
    #d8 75, 24, 1, 0, 5, w_UPDATE & 0xFF, w_UPDATE >> 8, 12, 1, 14, 27, 23
    #d8 14, 1, 12, 27, 23, 12, 2, 0, 10, 33, 38, 40
    #d8 17, 30, 4, 13, 13, 2, (w_E_M_BIGM) & 0xFF, (w_E_M_BIGM) >> 8, 2, 148, 75, 24
    #d8 1, 0, 5, w_UPDATE & 0xFF, w_UPDATE >> 8, 2, 112, 75, 9, 16, 2, 0
    #d8 64, 9, 20, 2, (fs_load) & 0xFF, (fs_load) >> 8, (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF, 4, 15, 13, (w_E_M_NEW >> 8) | 0x80
    #d8 w_E_M_NEW & 0xFF, 2, (w_E_M_READM) & 0xFF, (w_E_M_READM) >> 8, 2, 148, 75, 24, 1, 0, 5, w_UPDATE & 0xFF
    #d8 w_UPDATE >> 8, (w_E_M_NEW >> 8) | 0x80, w_E_M_NEW & 0xFF, 1, 0, 2, 224, 75, 26, (w_E_M_STRIP >> 8) | 0x80, w_E_M_STRIP & 0xFF, 2
    #d8 246, 75, 25, 4, 14, (w_E_M_NEW >> 8) | 0x80, w_E_M_NEW & 0xFF, 2, (w_E_M_BINM) & 0xFF, (w_E_M_BINM) >> 8, 2, 148
    #d8 75, 24, 1, 0, 5, w_UPDATE & 0xFF, w_UPDATE >> 8, 2, 112, 75, 2, 228
    #d8 75, 1, 13, 45, 2, 96, 77, 2, 242, 75, 1, 4
    #d8 45, 1, 3, (w_OPEN >> 8) | 0x80, w_OPEN & 0xFF, 1, 3, 5, w_UPDATE & 0xFF, w_UPDATE >> 8
w_E_M_SAVE:
    #d8 2, 228, 75, 25, 40, 4, 27, (w_E_M_ASK >> 8) | 0x80, w_E_M_ASK & 0xFF, 40, 4, 13
    #d8 1, 0, 53, 1, 3, (w_SETW >> 8) | 0x80, w_SETW & 0xFF, (w_E_M_INFO >> 8) | 0x80, w_E_M_INFO & 0xFF, 1, 1, 53
    #d8 0, 2, 96, 77, 2, 242, 75, 1, 4, 45, 2, 208
    #d8 75, 23, 2, 224, 75, 25, 4, 3, 13, (w_E_M_CRLF >> 8) | 0x80, w_E_M_CRLF & 0xFF, 9
    #d8 18, 2, 96, 77, 2, 128, 75, 1, 4, 45, 2, 242
    #d8 75, 2, 96, 77, 1, 4, 45, 2, 228, 75, 9, 16
    #d8 2, 0, 64, 9, 20, 1, 0, 2, 32, 128, 48, 2
    #d8 128, 75, 2, 96, 77, 1, 4, 45, 2, 224, 75, 25
    #d8 4, 11, 2, 208, 75, 23, 2, 216, 75, 23, 27, (w_E_M_STRIP >> 8) | 0x80
    #d8 w_E_M_STRIP & 0xFF, 4, 5, 2, (w_E_M_NOSAVE) & 0xFF, (w_E_M_NOSAVE) >> 8, 3, 9, 1, 0, 2, 223
    #d8 75, 26, 2, (w_E_M_SAVED) & 0xFF, (w_E_M_SAVED) >> 8, 2, 220, 75, 24, (w_DIR_M_READ >> 8) | 0x80, w_DIR_M_READ & 0xFF, 1
    #d8 0, (w_UPDATE >> 8) | 0x80, w_UPDATE & 0xFF, 1, 3, 5, w_UPDATE & 0xFF, w_UPDATE >> 8
w_F_M_VIEW:
    #d8 (w_E_M_GUARD >> 8) | 0x80, w_E_M_GUARD & 0xFF, 4, 3, 13, 13, 0, 2, 25, 93, 26, 19
    #d8 1, 0, 1, 0, 12, 2, 145, 75, 25, 39, 4, 19
    #d8 12, (w_ENT >> 8) | 0x80, w_ENT & 0xFF, 12, (w_KIND_Q_ >> 8) | 0x80, w_KIND_Q_ & 0xFF, 14, (w_DIR_Q_ >> 8) | 0x80, w_DIR_Q_ & 0xFF, 40, 29, 4
    #d8 3, 14, 33, 14, 33, 3, 229, 13, 2, 31, 93, 26
    #d8 2, 96, 77, 2, 27, 93, 1, 4, 45, 2, (fs_root) & 0xFF, (fs_root) >> 8
    #d8 (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF, 13, 21, 9, 16, 2, (fs_open) & 0xFF, (fs_open) >> 8, (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF, 4
    #d8 28, 22, 1, 0, 2, 25, 93, 26, 2, 27, 93, 2
    #d8 96, 77, 1, 4, 45, 2, (w_P_M_NONE) & 0xFF, (w_P_M_NONE) >> 8, 2, 148, 75, 24
    #d8 1, 0, 5, w_UPDATE & 0xFF, w_UPDATE >> 8, 1, 0, 2, 80, 93, 24, 1
    #d8 0, 2, 80, 93, 1, 2, 27, 24, 2, 247, 75, 25
    #d8 4, 6, 1, 135, 2, 26, 93, 26, 20, 2, 112, 75
    #d8 1, 10, 45, 5, w_F_M_GO & 0xFF, w_F_M_GO >> 8
w_DRAG:
    #d8 12, (w_SETW >> 8) | 0x80, w_SETW & 0xFF, 10, 145, 11, 157, 10, 146, 11, 158, 1
    #d8 0, 53, (w_OUTLINE >> 8) | 0x80, w_OUTLINE & 0xFF, 1, 1, 53, 54, 13, (w_TIME_M_ADV >> 8) | 0x80, w_TIME_M_ADV & 0xFF, 10
    #d8 181, 1, 1, 29, 4, 62, 10, 60, 4, 241, 1, 0
    #d8 11, 60, (w_CELL >> 8) | 0x80, w_CELL & 0xFF, 10, 149, 10, 151, 28, (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 10
    #d8 147, 28, (w_CLAMP >> 8) | 0x80, w_CLAMP & 0xFF, 10, 150, (w_BOARD_M_H >> 8) | 0x80, w_BOARD_M_H & 0xFF, 10, 148, 28, (w_CLAMP >> 8) | 0x80
    #d8 w_CLAMP & 0xFF, 18, 10, 158, 37, 14, 10, 157, 37, 29, 4, 4
    #d8 13, 13, 3, 199, 1, 0, 53, (w_OUTLINE >> 8) | 0x80, w_OUTLINE & 0xFF, 11, 158, 11
    #d8 157, (w_OUTLINE >> 8) | 0x80, w_OUTLINE & 0xFF, 1, 1, 53, 3, 183, 1, 0, 53, (w_OUTLINE >> 8) | 0x80
    #d8 w_OUTLINE & 0xFF, 1, 1, 53, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 12, 33, 25, 10, 157, 37
    #d8 15, 1, 2, 27, 25, 10, 158, 37, 29, 4, 2, 13
    #d8 0, 10, 157, 15, 33, 26, 10, 158, 14, 1, 2, 27
    #d8 26, 5, w_REFRESH_M_ALL & 0xFF, w_REFRESH_M_ALL >> 8
w_MENU:
    #d8 1, 0, 11, 159, (w_MENU_M_DRAW >> 8) | 0x80, w_MENU_M_DRAW & 0xFF, 54, (w_TIME_M_ADV >> 8) | 0x80, w_TIME_M_ADV & 0xFF, 12, 1, 17
    #d8 37, 4, 10, 10, 159, 12, 4, 1, 34, 11, 159, (w_MENU_M_DRAW >> 8) | 0x80
    #d8 w_MENU_M_DRAW & 0xFF, 12, 1, 18, 37, 4, 14, 10, 159, 33, 12, 1
    #d8 8, 37, 4, 1, 34, 11, 159, (w_MENU_M_DRAW >> 8) | 0x80, w_MENU_M_DRAW & 0xFF, 12, 1, 27
    #d8 37, 4, 4, 13, 5, w_MENU_M_CLOSE & 0xFF, w_MENU_M_CLOSE >> 8, 1, 10, 37, 4, 7
    #d8 (w_MENU_M_CLOSE >> 8) | 0x80, w_MENU_M_CLOSE & 0xFF, 10, 159, 5, w_MENU_M_DO & 0xFF, w_MENU_M_DO >> 8, 10, 55, 40, 4, 190
    #d8 (w_MENU_M_HIT >> 8) | 0x80, w_MENU_M_HIT & 0xFF, 10, 60, 4, 21, 1, 0, 11, 60, 12, 41
    #d8 40, 4, 12, 12, 10, 159, 37, 40, 4, 5, 12, 11
    #d8 159, (w_MENU_M_DRAW >> 8) | 0x80, w_MENU_M_DRAW & 0xFF, 10, 181, 1, 1, 29, 12, 10, 153, 14
    #d8 11, 153, 40, 29, 4, 12, (w_MENU_M_CLOSE >> 8) | 0x80, w_MENU_M_CLOSE & 0xFF, 12, 41, 4, 2
    #d8 13, 0, 5, w_MENU_M_DO & 0xFF, w_MENU_M_DO >> 8, 0, 13, 3, 133, 0
w_FRAME:
    #d8 1, 0, 1, 0, (w_AT >> 8) | 0x80, w_AT & 0xFF, 12, (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF, 37, 4, 13
    #d8 12, 1, 8, 27, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, (w_REV >> 8) | 0x80, w_REV & 0xFF, 1, 7, 49, 3
    #d8 13, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 22, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 135, 49, 1, 2
    #d8 (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 35, 2, (w_TITLES) & 0xFF, (w_TITLES) >> 8, 27, 23
    #d8 12, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 25, 10, 147, 14, 28, 1, 2, 28, (w_SPACES >> 8) | 0x80
    #d8 w_SPACES & 0xFF, 1, 0, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 1, 12, 10, 148, 34, 39
    #d8 4, 22, 1, 0, 15, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 2, 49, 1, 160
    #d8 10, 147, 1, 2, 28, 50, 1, 3, 49, 33, 3, 227
    #d8 1, 0, 14, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1, 5, 49, 1, 4, 10, 147
    #d8 1, 2, 28, 50, 1, 6, 49, 0
w_K_M_DIG:
    #d8 2, 187, 75, 25, 4, 23, 2, 164, 75, (w_D0_ST_ >> 8) | 0x80, w_D0_ST_ & 0xFF, 1
    #d8 0, 2, 185, 75, 26, 1, 0, 2, 189, 75, 26, 1
    #d8 0, 2, 187, 75, 26, 2, 189, 75, 25, 1, 9, 39
    #d8 4, 75, 2, 164, 75, 2, 168, 75, 1, 4, 45, 2
    #d8 164, 75, 12, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 13, 2, 164, 75, 12, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF
    #d8 13, 2, 168, 75, 2, 164, 75, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 13, 2, 164
    #d8 75, 12, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 13, 2, 168, 75, (w_D0_ST_ >> 8) | 0x80, w_D0_ST_ & 0xFF, 2, 168
    #d8 75, 24, 2, 168, 75, 2, 164, 75, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 13, 2
    #d8 164, 75, (w_D0_EQ_ >> 8) | 0x80, w_D0_EQ_ & 0xFF, 40, 4, 11, 2, 189, 75, 25, 33
    #d8 2, 189, 75, 26, 0, 13, 0
w_E_M_INS:
    #d8 2, 208, 75, 23, 2, 216, 75, 23, 27, 1, 2, 27
    #d8 2, 255, 10, 38, 40, 4, 9, 13, 2, (w_E_M_FULLM) & 0xFF, (w_E_M_FULLM) >> 8, 2
    #d8 220, 75, 24, 0, 2, 210, 75, 23, 2, 0, 64, 27
    #d8 12, 12, 33, 2, 208, 75, 23, 2, 210, 75, 23, 28
    #d8 46, 15, 14, 26, 2, 208, 75, 23, 33, 2, 208, 75
    #d8 24, 2, 210, 75, 23, 33, 2, 210, 75, 24, 1, 1
    #d8 2, 223, 75, 26, 1, 10, 37, 4, 26, 2, 216, 75
    #d8 23, 33, 2, 216, 75, 24, 2, 210, 75, 23, 2, 214
    #d8 75, 24, 1, 1, 2, 226, 75, 26, 5, w_E_M_DN1 & 0xFF, w_E_M_DN1 >> 8, 1
    #d8 1, 2, 227, 75, 26, 0
w_E_M_STRIP:
    #d8 2, 208, 75, 24, 1, 0, 2, 216, 75, 24, 1, 0
    #d8 2, 246, 75, 26, 1, 0, 1, 0, 12, 2, 208, 75
    #d8 23, 38, 4, 79, 12, (w_E_AT_ >> 8) | 0x80, w_E_AT_ & 0xFF, 12, 1, 9, 37, 4
    #d8 3, 13, 1, 32, 12, 1, 13, 37, 4, 6, 1, 1
    #d8 2, 224, 75, 26, 12, 1, 10, 37, 4, 9, 2, 216
    #d8 75, 23, 33, 2, 216, 75, 24, 12, 1, 10, 37, 15
    #d8 1, 31, 14, 39, 30, 4, 13, 17, 12, 19, 2, 0
    #d8 64, 27, 26, 20, 33, 14, 3, 12, 1, 13, 37, 40
    #d8 4, 6, 1, 1, 2, 246, 75, 26, 33, 3, 169, 13
    #d8 2, 208, 75, 24, 0
w_D_P__ST_:
    #d8 2, 192, 75, 24, 2, 190, 75, 24, 2, 190, 75, 23
    #d8 23, 2, 192, 75, 23, 23, 27, 12, 2, 190, 75, 23
    #d8 23, 38, 4, 4, 1, 1, 3, 2, 1, 0, 14, 2
    #d8 192, 75, 23, 24, 2, 190, 75, 23, 1, 2, 27, 23
    #d8 2, 192, 75, 23, 1, 2, 27, 23, 27, 12, 2, 190
    #d8 75, 23, 1, 2, 27, 23, 38, 4, 4, 1, 1, 3
    #d8 2, 1, 0, 19, 14, 15, 27, 12, 17, 38, 4, 4
    #d8 1, 1, 3, 2, 1, 0, 20, 30, 14, 2, 192, 75
    #d8 23, 1, 2, 27, 24, 0
w_F_M_GO:
    #d8 (w_E_M_GUARD >> 8) | 0x80, w_E_M_GUARD & 0xFF, 4, 1, 0, 2, 145, 75, 25, 2, 19, 93
    #d8 26, 2, 146, 75, 25, 2, 20, 93, 26, 1, 1, 2
    #d8 3, 93, 26, 1, 0, 2, 9, 93, 26, 1, 0, 2
    #d8 8, 93, 26, 1, 80, 2, 17, 93, 26, 2, 140, 75
    #d8 25, 2, 21, 93, 26, 2, 141, 75, 25, 2, 21, 93
    #d8 33, 26, 2, 142, 75, 25, 2, 21, 93, 1, 2, 27
    #d8 26, (w_ROOT_Q_ >> 8) | 0x80, w_ROOT_Q_ & 0xFF, 4, 9, 2, (w_SELF) & 0xFF, (w_SELF) >> 8, 2, 64, 93, 1
    #d8 13, 45, (w_LEAVE_M_DESK >> 8) | 0x80, w_LEAVE_M_DESK & 0xFF, 2, 112, 75, 9, 16, 1, 0, 2
    #d8 12, 128, 48, 13, 0
w_COLD:
    #d8 (w_NOCLIP >> 8) | 0x80, w_NOCLIP & 0xFF, 1, 0, 11, 144, 1, 0, 11, 153, 1, 0
    #d8 11, 156, 1, 0, 11, 60, 10, 8, 11, 154, 1, 0
    #d8 2, 138, 75, 24, 2, 64, 75, 1, 48, 1, 0, 47
    #d8 (w_F_M_INIT >> 8) | 0x80, w_F_M_INIT & 0xFF, (w_K_M_CLR >> 8) | 0x80, w_K_M_CLR & 0xFF, (w_E_M_NEW >> 8) | 0x80, w_E_M_NEW & 0xFF, 2, (w_D_M_NOTE) & 0xFF, (w_D_M_NOTE) >> 8, 2, 248, 75
    #d8 24, 2, 24, 93, 25, 12, 1, 3, 38, 40, 4, 3
    #d8 13, 1, 0, 12, 4, 8, 12, (w_DRV_M_LOAD >> 8) | 0x80, w_DRV_M_LOAD & 0xFF, 4, 3, 13
    #d8 1, 0, 12, 2, 247, 75, 26, 2, 24, 93, 26, (w_MODE_M_UP >> 8) | 0x80
    #d8 w_MODE_M_UP & 0xFF, 1, 1, 1, 0, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 26, 1, 0, (w_RAISE >> 8) | 0x80, w_RAISE & 0xFF
    #d8 (w_REFRESH_M_ALL >> 8) | 0x80, w_REFRESH_M_ALL & 0xFF, 5, w_MAIN & 0xFF, w_MAIN >> 8
w_F_M_CD:
    #d8 2, 112, 75, 9, 16, 2, (fs_open) & 0xFF, (fs_open) >> 8, (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF, 4, 24
    #d8 7, 13, 67, 97, 110, 39, 116, 32, 111, 112, 101, 110
    #d8 32, 105, 116, 2, 148, 75, 24, 1, 0, 5, w_UPDATE & 0xFF, w_UPDATE >> 8
    #d8 2, 96, 77, 2, 80, 93, 1, 4, 45, (w_ROOT_Q_ >> 8) | 0x80, w_ROOT_Q_ & 0xFF, 4
    #d8 13, 1, 92, 2, 112, 75, 26, 1, 0, 2, 112, 75
    #d8 33, 26, 2, 112, 75, 2, 96, 93, 1, 13, 45, 1
    #d8 0, 2, 145, 75, 26, 1, 0, 2, 146, 75, 26, 1
    #d8 0, 2, 148, 75, 24, (w_DIR_M_READ >> 8) | 0x80, w_DIR_M_READ & 0xFF, 1, 0, 5, w_UPDATE & 0xFF, w_UPDATE >> 8
w_D_M_SET:
    #d8 12, 2, 247, 75, 25, 37, 4, 2, 13, 0, 2, 247
    #d8 75, 25, 14, 12, (w_MODE_ST_ >> 8) | 0x80, w_MODE_ST_ & 0xFF, 4, 8, 13, 13, 2, (w_D_M_NOFILE) & 0xFF
    #d8 (w_D_M_NOFILE) >> 8, 5, w_D_M_SAY & 0xFF, w_D_M_SAY >> 8, 40, 4, 2, 13, 0, 2, (w_D_M_KEEPM) & 0xFF, (w_D_M_KEEPM) >> 8
    #d8 (w_D_M_SAY >> 8) | 0x80, w_D_M_SAY & 0xFF, 2, 88, 2, 12, 4, 42, 54, (w_TIME_M_ADV >> 8) | 0x80, w_TIME_M_ADV & 0xFF, 1
    #d8 32, 30, 12, 1, 121, 37, 14, 1, 42, 37, 30, 10
    #d8 181, 1, 1, 29, 12, 10, 153, 14, 11, 153, 40, 29
    #d8 30, 4, 8, 13, 13, 2, (w_D_M_NOTE) & 0xFF, (w_D_M_NOTE) >> 8, 5, w_D_M_SAY & 0xFF, w_D_M_SAY >> 8, 34
    #d8 3, 211, 13, (w_MODE_ST_ >> 8) | 0x80, w_MODE_ST_ & 0xFF, 13, 2, (w_D_M_NOTE) & 0xFF, (w_D_M_NOTE) >> 8, 5, w_D_M_SAY & 0xFF, w_D_M_SAY >> 8
w_K_M_CALC:
    #d8 12, 1, 43, 37, 4, 4, 13, 5, w_K_M_ADD & 0xFF, w_K_M_ADD >> 8, 12, 1
    #d8 45, 37, 4, 15, 13, 2, 185, 75, 25, 1, 1, 31
    #d8 2, 185, 75, 26, 5, w_K_M_ADD & 0xFF, w_K_M_ADD >> 8, 12, 1, 42, 37, 4
    #d8 21, 13, (w_K_M_SIGNS >> 8) | 0x80, w_K_M_SIGNS & 0xFF, (w_DMUL >> 8) | 0x80, w_DMUL & 0xFF, 4, 2, (w_K_M_BAD >> 8) | 0x80, w_K_M_BAD & 0xFF, 2, 168
    #d8 75, 2, 160, 75, 1, 4, 45, 5, w_K_M_FIN & 0xFF, w_K_M_FIN >> 8, 2, 164
    #d8 75, (w_D0_EQ_ >> 8) | 0x80, w_D0_EQ_ & 0xFF, 4, 4, 13, 5, w_K_M_BAD & 0xFF, w_K_M_BAD >> 8, (w_DDIV >> 8) | 0x80, w_DDIV & 0xFF, 1
    #d8 47, 37, 4, 7, (w_K_M_SIGNS >> 8) | 0x80, w_K_M_SIGNS & 0xFF, 2, 168, 75, 3, 3, 2
    #d8 172, 75, 2, 160, 75, 1, 4, 45, 5, w_K_M_FIN & 0xFF, w_K_M_FIN >> 8
w_DDIV:
    #d8 2, 160, 75, 2, 176, 75, 1, 4, 45, 2, 168, 75
    #d8 (w_D0_ST_ >> 8) | 0x80, w_D0_ST_ & 0xFF, 2, 172, 75, (w_D0_ST_ >> 8) | 0x80, w_D0_ST_ & 0xFF, 1, 32, 12, 4, 68
    #d8 19, 2, 176, 75, 12, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 2, 172, 75, 12, (w_D_P__ST_ >> 8) | 0x80
    #d8 w_D_P__ST_ & 0xFF, 13, 4, 11, 2, 172, 75, 23, 1, 1, 30, 2
    #d8 172, 75, 24, 2, 168, 75, 12, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 13, 2, 172
    #d8 75, 2, 164, 75, (w_DU_LT_ >> 8) | 0x80, w_DU_LT_ & 0xFF, 40, 4, 19, 2, 164, 75
    #d8 2, 172, 75, (w_D_M__ST_ >> 8) | 0x80, w_D_M__ST_ & 0xFF, 2, 168, 75, 23, 1, 1, 30
    #d8 2, 168, 75, 24, 20, 34, 3, 185, 13, 0
w_DIR_M_READ:
    #d8 1, 0, 2, 144, 75, 26, 2, (fs_cwd) & 0xFF, (fs_cwd) >> 8, (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF, 4
    #d8 1, 0, 2, 144, 75, 25, 1, 96, 39, 4, 70, 2
    #d8 (fs_next) & 0xFF, (fs_next) >> 8, (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF, 4, 1, 0, 2, 64, 77, 25, 1
    #d8 46, 37, 2, 64, 77, 1, 11, 27, 25, 1, 8, 29
    #d8 30, 40, 4, 218, 2, 64, 77, 2, 144, 75, 25, (w_ENT >> 8) | 0x80
    #d8 w_ENT & 0xFF, 1, 12, 45, 2, 64, 77, 1, 28, 27, 2, 144
    #d8 75, 25, (w_ENT >> 8) | 0x80, w_ENT & 0xFF, 1, 12, 27, 1, 4, 45, 2, 144
    #d8 75, 25, 33, 2, 144, 75, 26, 3, 177, 0
w_D_M_DRAW:
    #d8 1, 0, 12, 1, 3, 39, 4, 62, 1, 1, 15, 1
    #d8 2, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF, 12, 2, 247, 75, 25, 37, 4, 8
    #d8 (w_REV >> 8) | 0x80, w_REV & 0xFF, 1, 3, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 3, 2, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 1
    #d8 (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 12, 1, 49, 27, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 1, 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF
    #d8 12, 35, 2, (w_D_M_ITEMS) & 0xFF, (w_D_M_ITEMS) >> 8, 27, 23, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 1, 1, (w_SPACES >> 8) | 0x80
    #d8 w_SPACES & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 0, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 33, 3, 188, 13, 1
    #d8 1, 1, 6, (w_AT >> 8) | 0x80, w_AT & 0xFF, 2, 248, 75, 23, 5, w_TYPE & 0xFF, w_TYPE >> 8
w_E_M_CLICK:
    #d8 10, 152, 1, 2, 28, 12, (w_E_M_ROWS >> 8) | 0x80, w_E_M_ROWS & 0xFF, 38, 40, 4, 2
    #d8 13, 0, 19, 1, 0, 53, 1, 3, (w_SETW >> 8) | 0x80, w_SETW & 0xFF, (w_E_M_CUR >> 8) | 0x80, w_E_M_CUR & 0xFF
    #d8 2, 212, 75, 23, 1, 0, 12, 21, 37, 40, 4, 10
    #d8 15, (w_E_M_EOL >> 8) | 0x80, w_E_M_EOL & 0xFF, 2, 208, 75, 23, 38, 3, 2, 1, 0
    #d8 4, 8, 14, (w_E_M_EOL >> 8) | 0x80, w_E_M_EOL & 0xFF, 33, 14, 33, 3, 228, 22, 2
    #d8 222, 75, 26, 10, 151, 12, 4, 1, 34, 2, 218, 75
    #d8 23, 27, (w_E_M_TOCOL >> 8) | 0x80, w_E_M_TOCOL & 0xFF, (w_E_M_CUR >> 8) | 0x80, w_E_M_CUR & 0xFF, 1, 1, 53, 0
w_E_M_DRAW:
    #d8 (w_E_M_INFO >> 8) | 0x80, w_E_M_INFO & 0xFF, (w_E_M_TEXT >> 8) | 0x80, w_E_M_TEXT & 0xFF, 1, 1, (w_E_M_ROWS >> 8) | 0x80, w_E_M_ROWS & 0xFF, 1, 2, 27, (w_AT >> 8) | 0x80
    #d8 w_AT & 0xFF, 7, 40, 67, 116, 114, 108, 43, 79, 32, 115, 97
    #d8 118, 101, 32, 32, 67, 116, 114, 108, 43, 78, 32, 110
    #d8 101, 119, 32, 32, 67, 116, 114, 108, 43, 69, 32, 108
    #d8 105, 110, 101, 32, 101, 110, 100, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF, (w_CTYPE >> 8) | 0x80, w_CTYPE & 0xFF, 10
    #d8 145, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF, 27, 33, 10, 48, 28, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 1, 3
    #d8 (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF, 37, 4, 3, 5, w_E_M_CUR & 0xFF, w_E_M_CUR >> 8, 0
w_K_M_LBL:
    #d8 32, 67, 32, 32, 32, 43, 45, 32, 32, 60, 45, 32
    #d8 32, 47, 32, 32, 32, 55, 32, 32, 32, 56, 32, 32
    #d8 32, 57, 32, 32, 32, 42, 32, 32, 32, 52, 32, 32
    #d8 32, 53, 32, 32, 32, 54, 32, 32, 32, 45, 32, 32
    #d8 32, 49, 32, 32, 32, 50, 32, 32, 32, 51, 32, 32
    #d8 32, 43, 32, 32, 32, 48, 32, 32, 32, 48, 48, 32
    #d8 32, 109, 111, 100, 32, 61, 32, 32
w_F_M_CLICK:
    #d8 10, 152, 1, 1, 37, 4, 11, 10, 151, 1, 3, 39
    #d8 4, 3, 5, w_F_M_UP & 0xFF, w_F_M_UP >> 8, 0, 10, 151, 1, 0, (w_WIN >> 8) | 0x80, w_WIN & 0xFF
    #d8 1, 3, 27, 25, 1, 2, 28, 37, 4, 3, 5, w_F_M_SCROLL & 0xFF
    #d8 w_F_M_SCROLL >> 8, 10, 152, 1, 2, 28, 12, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 38, 4, 30
    #d8 2, 146, 75, 25, 27, 12, 2, 144, 75, 25, 39, 4
    #d8 15, 12, 2, 145, 75, 25, 37, 4, 4, 13, (w_F_M_OPEN >> 8) | 0x80, w_F_M_OPEN & 0xFF
    #d8 0, (w_F_M_MOVE >> 8) | 0x80, w_F_M_MOVE & 0xFF, 0, 13, 0, 13, 0
w_K_GT_S:
    #d8 2, 187, 75, 25, 4, 8, 2, 160, 75, 2, 184, 75
    #d8 3, 6, 2, 164, 75, 2, 185, 75, 25, 19, 12, (w_D0_EQ_ >> 8) | 0x80
    #d8 w_D0_EQ_ & 0xFF, 4, 4, 22, 1, 0, 19, 2, 176, 75, 1, 4
    #d8 45, 2, 196, 75, 1, 12, 27, 34, 2, 176, 75, (w_D_S_10_ST_ >> 8) | 0x80
    #d8 w_D_S_10_ST_ & 0xFF, 1, 48, 27, 15, 26, 2, 176, 75, (w_D0_EQ_ >> 8) | 0x80, w_D0_EQ_ & 0xFF, 4
    #d8 238, 20, 4, 5, 34, 1, 45, 15, 26, 2, 196, 75
    #d8 1, 12, 27, 15, 28, 0
w_E_M_CRLF:
    #d8 2, 208, 75, 23, 2, 216, 75, 23, 27, 12, 2, 136
    #d8 75, 24, 2, 208, 75, 23, 12, 2, 136, 75, 23, 38
    #d8 4, 48, 34, 2, 136, 75, 23, 34, 2, 136, 75, 24
    #d8 12, (w_E_AT_ >> 8) | 0x80, w_E_AT_ & 0xFF, 12, 2, 136, 75, 23, 2, 0, 64, 27
    #d8 26, 1, 10, 37, 4, 220, 2, 136, 75, 23, 34, 12
    #d8 2, 136, 75, 24, 2, 0, 64, 27, 1, 13, 14, 26
    #d8 3, 200, 13, 0
w_MOUSE_M_DOWN:
    #d8 (w_CELL >> 8) | 0x80, w_CELL & 0xFF, (w_BOARD_M_H >> 8) | 0x80, w_BOARD_M_H & 0xFF, 34, 10, 150, 39, 4, 3, 5, w_RAIL_M_CLICK & 0xFF
    #d8 w_RAIL_M_CLICK >> 8, (w_WIN_M_AT >> 8) | 0x80, w_WIN_M_AT & 0xFF, 12, 41, 4, 2, 13, 0, 12, (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF
    #d8 37, 40, 4, 3, 12, (w_TO_M_FRONT >> 8) | 0x80, w_TO_M_FRONT & 0xFF, 12, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 12, 33
    #d8 25, 10, 149, 14, 28, 11, 151, 1, 2, 27, 25, 10
    #d8 150, 14, 28, 11, 152, 10, 152, 4, 8, 35, 2, (w_CLICKTAB) & 0xFF
    #d8 (w_CLICKTAB) >> 8, 27, 23, 44, 0, 10, 151, 4, 3, 5, w_DRAG & 0xFF, w_DRAG >> 8
    #d8 5, w_CLOSE & 0xFF, w_CLOSE >> 8, 0
w_K_M_ADD:
    #d8 2, 184, 75, 25, 2, 185, 75, 25, 37, 4, 15, 2
    #d8 164, 75, 2, 160, 75, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 4, 2, (w_K_M_BAD >> 8) | 0x80, w_K_M_BAD & 0xFF, 5
    #d8 w_K_M_FIN & 0xFF, w_K_M_FIN >> 8, 2, 160, 75, 2, 164, 75, (w_DU_LT_ >> 8) | 0x80, w_DU_LT_ & 0xFF, 4, 27
    #d8 2, 160, 75, 2, 164, 75, (w_D_M__ST_ >> 8) | 0x80, w_D_M__ST_ & 0xFF, 2, 164, 75, 2
    #d8 160, 75, 1, 4, 45, 2, 185, 75, 25, 2, 184, 75
    #d8 26, 3, 8, 2, 164, 75, 2, 160, 75, (w_D_M__ST_ >> 8) | 0x80, w_D_M__ST_ & 0xFF, 5
    #d8 w_K_M_FIN & 0xFF, w_K_M_FIN >> 8
w_SEC_P_:
    #d8 1, 1, 11, 156, 2, 142, 75, 25, 33, 12, 1, 60
    #d8 39, 4, 5, 2, 142, 75, 26, 0, 13, 1, 0, 2
    #d8 142, 75, 26, 1, 2, 11, 156, 2, 141, 75, 25, 33
    #d8 12, 1, 60, 39, 4, 5, 2, 141, 75, 26, 0, 13
    #d8 1, 0, 2, 141, 75, 26, 2, 140, 75, 25, 33, 12
    #d8 1, 24, 37, 4, 3, 13, 1, 0, 2, 140, 75, 26
    #d8 0
w_E_M_CUT:
    #d8 2, 210, 75, 23, (w_E_AT_ >> 8) | 0x80, w_E_AT_ & 0xFF, 1, 10, 37, 4, 17, 2
    #d8 216, 75, 23, 34, 2, 216, 75, 24, 1, 1, 2, 226
    #d8 75, 26, 3, 6, 1, 1, 2, 227, 75, 26, 2, 210
    #d8 75, 23, 2, 0, 64, 27, 12, 33, 14, 2, 208, 75
    #d8 23, 2, 210, 75, 23, 28, 34, 45, 2, 208, 75, 23
    #d8 34, 2, 208, 75, 24, 1, 1, 2, 223, 75, 26, 0
w_MENU_M_DRAW:
    #d8 1, 0, 53, 1, 0, 12, 1, 8, 39, 4, 52, 1
    #d8 1, 15, (w_MENU_M_Y >> 8) | 0x80, w_MENU_M_Y & 0xFF, 27, (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 12, 10, 159, 37, 4
    #d8 8, (w_REV >> 8) | 0x80, w_REV & 0xFF, 1, 3, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 3, 6, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1
    #d8 0, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 12, 35, 2, (w_MITEMS) & 0xFF, (w_MITEMS) >> 8
    #d8 27, 23, 12, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 25, 1, 13, 14, 28, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF
    #d8 33, 3, 198, 13, 1, 0, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 1, 53, 0
w_F_M_SIZE:
    #d8 12, (w_DIR_Q_ >> 8) | 0x80, w_DIR_Q_ & 0xFF, 4, 18, 13, 10, 147, 1, 25, 28, (w_SPACES >> 8) | 0x80
    #d8 w_SPACES & 0xFF, 7, 5, 60, 68, 73, 82, 62, 5, w_TYPE & 0xFF, w_TYPE >> 8, 12
    #d8 1, 14, 27, 23, 12, 4, 26, 1, 64, 42, 14, 1
    #d8 12, 27, 23, 2, 0, 4, 43, 16, 27, 10, 147, 1
    #d8 21, 28, (w_U_D_R >> 8) | 0x80, w_U_D_R & 0xFF, 1, 75, 5, w_GLYPH & 0xFF, w_GLYPH >> 8, 13, 1, 12
    #d8 27, 23, 10, 147, 1, 20, 28, 5, w_U_D_R & 0xFF, w_U_D_R >> 8, 0
w_E_M_INFO:
    #d8 1, 1, 1, 1, (w_AT >> 8) | 0x80, w_AT & 0xFF, (w_REV >> 8) | 0x80, w_REV & 0xFF, 2, 220, 75, 23
    #d8 12, 4, 6, 12, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 25, 3, 37, 13, 2, 228
    #d8 75, 25, 4, 7, 2, 228, 75, (w_ZTYPE >> 8) | 0x80, w_ZTYPE & 0xFF, 3, 5, 2
    #d8 (w_E_M_NONE) & 0xFF, (w_E_M_NONE) >> 8, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 2, 223, 75, 25, 4, 6, 7, 2
    #d8 32, 42, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 10, 48, 10, 145, 28, 34, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF
    #d8 14, 28, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 5, w_INK & 0xFF, w_INK >> 8
w_K_M_DRAW:
    #d8 (w_K_M_DISP >> 8) | 0x80, w_K_M_DISP & 0xFF, 1, 0, 12, 1, 20, 39, 4, 50, 12, 1
    #d8 4, 43, 35, 1, 4, 27, 14, 1, 5, 42, 1, 2
    #d8 27, 14, (w_AT >> 8) | 0x80, w_AT & 0xFF, 12, 35, 35, 2, (w_K_M_LBL) & 0xFF, (w_K_M_LBL) >> 8, 27, 12
    #d8 33, 25, 1, 48, 28, 1, 10, 38, 4, 4, 1, 14
    #d8 3, 2, 1, 15, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 4, 51, 33, 3, 200
    #d8 13, 1, 0, 5, w_PEN & 0xFF, w_PEN >> 8
w_F_M_OPEN:
    #d8 2, 144, 75, 25, 40, 4, 1, 0, 2, 145, 75, 25
    #d8 (w_ENT >> 8) | 0x80, w_ENT & 0xFF, 12, (w_ENT_GT_NAME >> 8) | 0x80, w_ENT_GT_NAME & 0xFF, 12, (w_DIR_Q_ >> 8) | 0x80, w_DIR_Q_ & 0xFF, 4, 4, 13, 5
    #d8 w_F_M_CD & 0xFF, w_F_M_CD >> 8, 12, (w_PLC_Q_ >> 8) | 0x80, w_PLC_Q_ & 0xFF, 4, 4, 13, 5, w_F_M_RUN & 0xFF, w_F_M_RUN >> 8, 12
    #d8 (w_PIC_Q_ >> 8) | 0x80, w_PIC_Q_ & 0xFF, 4, 9, 13, 2, (w_P_M_NAME) & 0xFF, (w_P_M_NAME) >> 8, 1, 86, 5, w_F_M_VIEW & 0xFF
    #d8 w_F_M_VIEW >> 8, 12, (w_WAV_Q_ >> 8) | 0x80, w_WAV_Q_ & 0xFF, 4, 9, 13, 2, (w_W_M_NAME) & 0xFF, (w_W_M_NAME) >> 8, 1, 83
    #d8 5, w_F_M_VIEW & 0xFF, w_F_M_VIEW >> 8, 5, w_E_M_OPEN & 0xFF, w_E_M_OPEN >> 8
w_F_M_SCROLL:
    #d8 2, 144, 75, 25, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 28, 12, 41, 4, 3, 13
    #d8 1, 0, 10, 152, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 36, 1, 2, 27, 39, 4
    #d8 17, 13, 2, 146, 75, 25, 1, 5, 28, 12, 41, 4
    #d8 20, 13, 1, 0, 3, 15, 2, 146, 75, 25, 1, 5
    #d8 27, 18, 39, 4, 3, 13, 3, 1, 16, 2, 146, 75
    #d8 26, 1, 0, 5, w_UPDATE & 0xFF, w_UPDATE >> 8
w_OUTLINE:
    #d8 1, 0, 12, 10, 147, 39, 4, 22, 12, 10, 157, 27
    #d8 12, 10, 158, (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 52, 10, 158, 10, 148, 27, 34
    #d8 (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 52, 33, 3, 228, 13, 1, 1, 12, 10, 148
    #d8 34, 39, 4, 24, 12, 10, 158, 27, 12, 10, 157, 14
    #d8 (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 52, 10, 157, 10, 147, 27, 34, 14, (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF
    #d8 52, 33, 3, 225, 13, 0
w_MODE_M_UP:
    #d8 1, 0, 2, 16, 46, 48, 13, (w_NOCLIP >> 8) | 0x80, w_NOCLIP & 0xFF, 1, 0, 12
    #d8 1, 6, 39, 4, 17, 12, 35, 35, 2, 88, 46, 27
    #d8 15, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 33, 1, 4, 45, 33, 3, 233, 13, (w_F_M_FIX >> 8) | 0x80
    #d8 w_F_M_FIX & 0xFF, 2, 222, 75, 25, (w_E_M_ROWS >> 8) | 0x80, w_E_M_ROWS & 0xFF, 39, 40, 4, 14, 2
    #d8 214, 75, 23, 2, 212, 75, 24, 1, 0, 2, 222, 75
    #d8 26, 5, w_E_M_HS & 0xFF, w_E_M_HS >> 8
w_F_M_KEY:
    #d8 12, 1, 17, 37, 4, 13, 2, 145, 75, 25, 4, 7
    #d8 2, 145, 75, 25, 34, (w_F_M_MOVE >> 8) | 0x80, w_F_M_MOVE & 0xFF, 12, 1, 18, 37, 4
    #d8 19, 2, 145, 75, 25, 33, 2, 144, 75, 25, 39, 4
    #d8 7, 2, 145, 75, 25, 33, (w_F_M_MOVE >> 8) | 0x80, w_F_M_MOVE & 0xFF, 12, 1, 10, 37
    #d8 4, 2, (w_F_M_OPEN >> 8) | 0x80, w_F_M_OPEN & 0xFF, 1, 8, 37, 4, 3, 5, w_F_M_UP & 0xFF, w_F_M_UP >> 8
    #d8 0
w_DRV_M_LOAD:
    #d8 2, 96, 77, 2, 128, 75, 1, 4, 45, 2, 96, 77
    #d8 (w_D0_ST_ >> 8) | 0x80, w_D0_ST_ & 0xFF, 2, (w_D_M_DIR) & 0xFF, (w_D_M_DIR) >> 8, 9, 16, 2, (fs_open) & 0xFF, (fs_open) >> 8, (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF
    #d8 12, 40, 4, 21, 13, 35, 2, (w_D_M_FILES) & 0xFF, (w_D_M_FILES) >> 8, 27, 23, 9
    #d8 16, 2, 0, 46, 9, 20, 2, (fs_load) & 0xFF, (fs_load) >> 8, (w_SYS0 >> 8) | 0x80, w_SYS0 & 0xFF, 3
    #d8 1, 16, 2, 128, 75, 2, 96, 77, 1, 4, 45, 0
w_K_M_DISP1:
    #d8 1, 2, 1, 2, (w_AT >> 8) | 0x80, w_AT & 0xFF, (w_REV >> 8) | 0x80, w_REV & 0xFF, 1, 19, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF
    #d8 1, 3, 1, 2, (w_AT >> 8) | 0x80, w_AT & 0xFF, 2, 186, 75, 25, 12, 4
    #d8 3, 49, 3, 1, 13, 2, 188, 75, 25, 4, 12, 1
    #d8 15, 1, 2, (w_AT >> 8) | 0x80, w_AT & 0xFF, 2, (w_K_M_EMSG) & 0xFF, (w_K_M_EMSG) >> 8, 5, w_TYPE & 0xFF, w_TYPE >> 8, (w_K_GT_S >> 8) | 0x80
    #d8 w_K_GT_S & 0xFF, 1, 20, 15, 28, 1, 2, (w_AT >> 8) | 0x80, w_AT & 0xFF, 51, 0
w_K_M_CLICK:
    #d8 10, 152, 1, 4, 28, 12, 1, 1, 29, 4, 2, 13
    #d8 0, 36, 12, 1, 5, 38, 40, 4, 2, 13, 0, 10
    #d8 151, 1, 2, 28, 1, 5, 43, 14, 1, 4, 39, 15
    #d8 1, 4, 39, 29, 40, 4, 3, 13, 13, 0, 14, 35
    #d8 35, 27, 2, (w_K_M_KEYS) & 0xFF, (w_K_M_KEYS) >> 8, 27, 25, 5, w_K_M_DO & 0xFF, w_K_M_DO >> 8
w_BIGDIG:
    #d8 14, 35, 2, (w_DIGS) & 0xFF, (w_DIGS) >> 8, 27, 23, 1, 0, 12, 1, 5
    #d8 39, 4, 38, 19, 15, 21, 1, 2, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF, 1
    #d8 3, 12, 4, 20, 19, 12, 2, 0, 64, 29, 4, 4
    #d8 1, 32, 3, 2, 1, 160, 49, 35, 20, 34, 3, 233
    #d8 13, 20, 33, 3, 212, 13, 13, 13, 0
w_RAIL_M_CLICK:
    #d8 10, 149, 34, 1, 10, 38, 4, 3, 5, w_MENU & 0xFF, w_MENU >> 8, 10
    #d8 149, 1, 11, 28, 12, 41, 4, 2, 13, 0, (w_TABW >> 8) | 0x80, w_TABW & 0xFF
    #d8 43, 16, 1, 0, 12, 1, 6, 39, 4, 20, 12, (w_WIN >> 8) | 0x80
    #d8 w_WIN & 0xFF, 25, 4, 11, 15, 40, 4, 4, 16, 5, w_TO_M_FRONT & 0xFF, w_TO_M_FRONT >> 8
    #d8 14, 34, 14, 33, 3, 230, 13, 13, 0
w_KEY:
    #d8 12, 1, 9, 37, 4, 4, 13, 5, w_NEXT_M_WIN & 0xFF, w_NEXT_M_WIN >> 8, 12, 1
    #d8 27, 37, 4, 4, 13, 5, w_MENU & 0xFF, w_MENU >> 8, 12, 1, 23, 37
    #d8 4, 13, 13, (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF, 12, 41, 4, 2, 13, 0, 5
    #d8 w_CLOSE & 0xFF, w_CLOSE >> 8, 0, (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF, 12, 41, 4, 3, 13, 13, 0
    #d8 35, 2, (w_KEYTAB) & 0xFF, (w_KEYTAB) >> 8, 27, 23, 44, 0
w_F_M_MOVE:
    #d8 2, 145, 75, 25, 14, 2, 145, 75, 26, 2, 148, 75
    #d8 23, 40, 2, 145, 75, 25, 2, 146, 75, 25, 28, (w_F_M_ROWS >> 8) | 0x80
    #d8 w_F_M_ROWS & 0xFF, 38, 29, 4, 21, 1, 0, 53, 1, 0, (w_SETW >> 8) | 0x80, w_SETW & 0xFF
    #d8 (w_F_M_ROW >> 8) | 0x80, w_F_M_ROW & 0xFF, 2, 145, 75, 25, (w_F_M_ROW >> 8) | 0x80, w_F_M_ROW & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 1, 1
    #d8 53, 0, 13, 5, w_F_M_SHOW & 0xFF, w_F_M_SHOW >> 8, 0
w_Z_M_REMOVE:
    #d8 1, 0, 12, 10, 144, 39, 4, 43, 18, 2, 32, 75
    #d8 27, 25, 37, 4, 31, 12, 33, 10, 144, 39, 4, 16
    #d8 12, 33, 2, 32, 75, 27, 25, 15, 2, 32, 75, 27
    #d8 26, 33, 3, 233, 13, 13, 10, 144, 34, 11, 144, 0
    #d8 33, 3, 207, 13, 13, 0
w_TIME_M_ADV:
    #d8 10, 8, 12, 10, 154, 28, 1, 255, 29, 14, 11, 154
    #d8 12, 4, 34, 2, 138, 75, 23, 2, 232, 3, 27, 12
    #d8 2, 36, 234, 38, 4, 6, 2, 138, 75, 24, 3, 10
    #d8 2, 36, 234, 28, 2, 138, 75, 24, (w_SEC_P_ >> 8) | 0x80, w_SEC_P_ & 0xFF, 34, 3
    #d8 219, 13, 0
w_E_M_LINE:
    #d8 1, 1, 14, 1, 2, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF, 12, (w_E_M_EOL >> 8) | 0x80, w_E_M_EOL & 0xFF, 18
    #d8 14, 28, 2, 218, 75, 23, 28, 12, 41, 4, 3, 13
    #d8 1, 0, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF, (w_UMIN >> 8) | 0x80, w_UMIN & 0xFF, 19, 14, 2, 218, 75, 23
    #d8 27, 2, 0, 64, 27, 21, 51, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF, 20, 28, (w_SPACES >> 8) | 0x80
    #d8 w_SPACES & 0xFF, 33, 0
w_E_M_HS:
    #d8 (w_E_M_COL >> 8) | 0x80, w_E_M_COL & 0xFF, 12, 2, 218, 75, 23, 38, 4, 11, 2, 218
    #d8 75, 24, 1, 1, 2, 226, 75, 26, 0, 12, 2, 218
    #d8 75, 23, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF, 27, 38, 4, 2, 13, 0, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF
    #d8 28, 33, 2, 218, 75, 24, 1, 1, 2, 226, 75, 26
    #d8 0
w_MENU_M_DO:
    #d8 2, (w_MACT) & 0xFF, (w_MACT) >> 8, 27, 25, 12, 1, 6, 39, 4, 3, 5
    #d8 w_OPEN & 0xFF, w_OPEN >> 8, (w_E_M_GUARD >> 8) | 0x80, w_E_M_GUARD & 0xFF, 4, 2, 13, 0, (w_LEAVE_M_DESK >> 8) | 0x80, w_LEAVE_M_DESK & 0xFF, 1, 0
    #d8 2, 17, 93, 26, 1, 254, 37, 4, 8, 1, 0, 2
    #d8 36, 128, 48, 3, 6, 1, 0, 2, 8, 128, 48, 13
    #d8 0
w_E_M_TEXT:
    #d8 (w_INK >> 8) | 0x80, w_INK & 0xFF, 2, 212, 75, 23, 1, 0, 12, (w_E_M_ROWS >> 8) | 0x80, w_E_M_ROWS & 0xFF, 39
    #d8 4, 31, 15, 2, 208, 75, 23, 14, 38, 4, 14, 1
    #d8 1, 15, 1, 2, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF, (w_E_M_COLS >> 8) | 0x80, w_E_M_COLS & 0xFF, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 3
    #d8 5, 14, 15, (w_E_M_LINE >> 8) | 0x80, w_E_M_LINE & 0xFF, 14, 33, 3, 219, 13, 13, 0
w_WIN_M_AT:
    #d8 10, 144, 12, 4, 38, 34, 12, 2, 32, 75, 27, 25
    #d8 (w_W_M_RECT >> 8) | 0x80, w_W_M_RECT & 0xFF, 19, 19, 10, 150, 14, 28, 20, 14, 20, 38
    #d8 19, 10, 149, 17, 28, 14, 38, 20, 29, 4, 223, 2
    #d8 32, 75, 27, 25, 0, 3, 215, 13, 2, 255, 255, 0
w_F_M_FIX:
    #d8 2, 145, 75, 25, 2, 146, 75, 25, 39, 4, 8, 2
    #d8 145, 75, 25, 2, 146, 75, 26, 2, 145, 75, 25, 2
    #d8 146, 75, 25, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 27, 39, 40, 4, 12, 2, 145
    #d8 75, 25, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 28, 33, 2, 146, 75, 26, 0
w_K_M_COMMIT:
    #d8 2, 187, 75, 25, 4, 1, 0, 2, 186, 75, 25, 12
    #d8 4, 4, (w_K_M_CALC >> 8) | 0x80, w_K_M_CALC & 0xFF, 3, 20, 13, 2, 164, 75, 2, 160
    #d8 75, 1, 4, 45, 2, 185, 75, 25, 2, 184, 75, 26
    #d8 (w_K_M_FIN >> 8) | 0x80, w_K_M_FIN & 0xFF, 1, 1, 2, 187, 75, 26, 0
w_D_M__ST_:
    #d8 14, 2, 180, 75, 1, 4, 45, 2, 180, 75, 23, 32
    #d8 2, 180, 75, 24, 2, 180, 75, 1, 2, 27, 23, 32
    #d8 2, 180, 75, 1, 2, 27, 24, 2, 180, 75, (w_D1_P__ST_ >> 8) | 0x80, w_D1_P__ST_ & 0xFF
    #d8 2, 180, 75, 14, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 13, 0
w_DMUL:
    #d8 2, 168, 75, (w_D0_ST_ >> 8) | 0x80, w_D0_ST_ & 0xFF, 1, 0, 1, 32, 12, 4, 29
    #d8 19, 2, 168, 75, 12, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 30, 2, 164, 75, 12
    #d8 (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF, 4, 9, 2, 160, 75, 2, 168, 75, (w_D_P__ST_ >> 8) | 0x80, w_D_P__ST_ & 0xFF
    #d8 30, 20, 34, 3, 224, 13, 0
w_ENT_GT_NAME:
    #d8 1, 0, 11, 155, 12, 1, 8, (w_COPY_M_NS >> 8) | 0x80, w_COPY_M_NS & 0xFF, 12, 1, 8
    #d8 27, 25, 1, 32, 37, 40, 4, 12, 1, 46, (w_N_P_ >> 8) | 0x80, w_N_P_ & 0xFF
    #d8 12, 1, 8, 27, 1, 3, (w_COPY_M_NS >> 8) | 0x80, w_COPY_M_NS & 0xFF, 13, 1, 0, 10
    #d8 155, 2, 112, 75, 27, 26, 0
w_E_M_HOME:
    #d8 1, 0, 2, 210, 75, 24, 1, 0, 2, 212, 75, 24
    #d8 1, 0, 2, 214, 75, 24, 1, 0, 2, 218, 75, 24
    #d8 1, 0, 2, 222, 75, 26, 1, 0, 2, 220, 75, 24
    #d8 1, 0, 2, 225, 75, 26, 0
w_C_M_CLICK:
    #d8 10, 152, 1, 8, 37, 4, 35, 10, 151, 12, 1, 2
    #d8 28, 1, 4, 38, 4, 2, (w_C_M_H >> 8) | 0x80, w_C_M_H & 0xFF, 12, 1, 7, 28
    #d8 1, 4, 38, 4, 2, (w_C_M_M >> 8) | 0x80, w_C_M_M & 0xFF, 1, 12, 28, 1, 5
    #d8 38, 4, 3, 5, w_C_M_S & 0xFF, w_C_M_S >> 8, 0
w_E_M_RIGHTK:
    #d8 2, 210, 75, 23, 12, 2, 208, 75, 23, 38, 40, 4
    #d8 2, 13, 0, 12, 33, 2, 210, 75, 24, (w_E_AT_ >> 8) | 0x80, w_E_AT_ & 0xFF, 1
    #d8 10, 37, 4, 11, 2, 210, 75, 23, 2, 214, 75, 24
    #d8 5, w_E_M_DN1 & 0xFF, w_E_M_DN1 >> 8, 0
w_UPDATE:
    #d8 12, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 25, 40, 4, 2, 13, 0, 12, (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF
    #d8 37, 4, 16, 1, 0, 53, 12, (w_W_M_RECT >> 8) | 0x80, w_W_M_RECT & 0xFF, (w_SETCLIP >> 8) | 0x80, w_SETCLIP & 0xFF, (w_DRAWWIN >> 8) | 0x80
    #d8 w_DRAWWIN & 0xFF, (w_NOCLIP >> 8) | 0x80, w_NOCLIP & 0xFF, 1, 1, 53, 0, (w_W_M_RECT >> 8) | 0x80, w_W_M_RECT & 0xFF, 5, w_REFRESH & 0xFF, w_REFRESH >> 8
    #d8 0
w_E_M_LEFTK:
    #d8 2, 210, 75, 23, 12, 40, 4, 2, 13, 0, 34, 12
    #d8 2, 210, 75, 24, 2, 214, 75, 23, 38, 4, 13, 2
    #d8 210, 75, 23, (w_E_M_BOL >> 8) | 0x80, w_E_M_BOL & 0xFF, 2, 214, 75, 24, 5, w_E_M_UP1 & 0xFF, w_E_M_UP1 >> 8
    #d8 0
w_RAIL_M_TIME:
    #d8 1, 7, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 1, 6, 28, (w_RAIL_M_Y >> 8) | 0x80, w_RAIL_M_Y & 0xFF, (w_ABS_M_AT >> 8) | 0x80
    #d8 w_ABS_M_AT & 0xFF, (w_REV >> 8) | 0x80, w_REV & 0xFF, 2, 140, 75, 25, (w__D_2 >> 8) | 0x80, w__D_2 & 0xFF, 1, 58, (w_GLYPH >> 8) | 0x80
    #d8 w_GLYPH & 0xFF, 2, 141, 75, 25, (w__D_2 >> 8) | 0x80, w__D_2 & 0xFF, 1, 0, 5, w_PEN & 0xFF, w_PEN >> 8
w_MAIN:
    #d8 54, 12, 4, 4, (w_KEY >> 8) | 0x80, w_KEY & 0xFF, 3, 1, 13, 10, 55, 40
    #d8 4, 17, 10, 181, 1, 1, 29, 12, 10, 153, 14, 11
    #d8 153, 40, 29, 4, 2, (w_MOUSE_M_DOWN >> 8) | 0x80, w_MOUSE_M_DOWN & 0xFF, (w_TICK >> 8) | 0x80, w_TICK & 0xFF, 3, 221, 0
w_D_S_10_ST_:
    #d8 1, 0, 1, 4, 12, 4, 25, 34, 19, 2, 0, 1
    #d8 42, 15, 21, 27, 25, 27, 1, 10, 43, 17, 12, 21
    #d8 27, 17, 14, 26, 14, 20, 3, 228, 13, 16, 0
w_E_M_DN1:
    #d8 2, 222, 75, 25, 33, 12, (w_E_M_ROWS >> 8) | 0x80, w_E_M_ROWS & 0xFF, 39, 4, 5, 2
    #d8 222, 75, 26, 0, 13, 2, 212, 75, 23, (w_E_M_EOL >> 8) | 0x80, w_E_M_EOL & 0xFF, 33
    #d8 2, 212, 75, 24, 1, 1, 2, 226, 75, 26, 0
w_E_M_CLEAR:
    #d8 2, 223, 75, 25, 2, 225, 75, 25, 40, 29, 4, 14
    #d8 1, 1, 2, 225, 75, 26, 2, (w_E_M_DROPM) & 0xFF, (w_E_M_DROPM) >> 8, 2, 220, 75
    #d8 24, 0, (w_E_M_NEW >> 8) | 0x80, w_E_M_NEW & 0xFF, 1, 1, 2, 226, 75, 26, 0
w_E_M_UNSAVED:
    #d8 34, 78, 111, 116, 32, 115, 97, 118, 101, 100, 58, 32
    #d8 67, 116, 114, 108, 43, 79, 44, 32, 111, 114, 32, 67
    #d8 116, 114, 108, 43, 78, 32, 116, 119, 105, 99, 101
w_C_M_KEY:
    #d8 1, 32, 30, 12, 1, 104, 37, 4, 2, (w_C_M_H >> 8) | 0x80, w_C_M_H & 0xFF, 12
    #d8 1, 109, 37, 4, 2, (w_C_M_M >> 8) | 0x80, w_C_M_M & 0xFF, 12, 1, 115, 37, 14
    #d8 1, 48, 37, 30, 4, 3, 5, w_C_M_S & 0xFF, w_C_M_S >> 8, 0
w_REPAINT:
    #d8 (w_BOARD >> 8) | 0x80, w_BOARD & 0xFF, 1, 0, 12, 10, 144, 39, 4, 11, 12, 2
    #d8 32, 75, 27, 25, (w_DRAWWIN >> 8) | 0x80, w_DRAWWIN & 0xFF, 33, 3, 239, 13, (w_BOARD_M_H >> 8) | 0x80, w_BOARD_M_H & 0xFF
    #d8 10, 53, 39, 4, 3, 5, w_RAIL & 0xFF, w_RAIL >> 8, 0
w_E_M_NEW:
    #d8 1, 0, 2, 208, 75, 24, 1, 0, 2, 216, 75, 24
    #d8 1, 0, 2, 223, 75, 26, 1, 1, 2, 224, 75, 26
    #d8 1, 0, 2, 228, 75, 26, 5, w_E_M_HOME & 0xFF, w_E_M_HOME >> 8
w_E_M_DROPM:
    #d8 32, 78, 111, 116, 32, 115, 97, 118, 101, 100, 58, 32
    #d8 67, 116, 114, 108, 43, 78, 32, 97, 103, 97, 105, 110
    #d8 32, 100, 114, 111, 112, 115, 32, 105, 116
w_MODE_ST_:
    #d8 1, 0, 53, 12, (w_DRV_M_LOAD >> 8) | 0x80, w_DRV_M_LOAD & 0xFF, 4, 8, 13, 1, 1, 53
    #d8 2, 255, 255, 0, 12, 2, 247, 75, 26, 2, 24, 93
    #d8 26, (w_MODE_M_UP >> 8) | 0x80, w_MODE_M_UP & 0xFF, (w_REFRESH_M_ALL >> 8) | 0x80, w_REFRESH_M_ALL & 0xFF, 1, 0, 0
w_E_M_BUSYM:
    #d8 30, 84, 104, 101, 32, 69, 100, 105, 116, 111, 114, 39
    #d8 115, 32, 116, 101, 120, 116, 32, 105, 115, 32, 110, 111
    #d8 116, 32, 115, 97, 118, 101, 100
w_P_M_NONE:
    #d8 30, 73, 116, 115, 32, 112, 114, 111, 103, 114, 97, 109
    #d8 32, 105, 115, 32, 110, 111, 116, 32, 111, 110, 32, 116
    #d8 104, 101, 32, 99, 97, 114, 100
w_TICK:
    #d8 (w_TIME_M_ADV >> 8) | 0x80, w_TIME_M_ADV & 0xFF, 10, 156, 12, 4, 22, 1, 0, 11, 156, 1
    #d8 2, 37, 4, 8, 1, 0, 53, (w_RAIL_M_TIME >> 8) | 0x80, w_RAIL_M_TIME & 0xFF, 1, 1, 53
    #d8 1, 1, 5, w_UPDATE & 0xFF, w_UPDATE >> 8, 13, 0
w_F_M_UP:
    #d8 (w_ROOT_Q_ >> 8) | 0x80, w_ROOT_Q_ & 0xFF, 4, 1, 0, 1, 46, 2, 112, 75, 26, 1
    #d8 46, 2, 112, 75, 33, 26, 1, 0, 2, 112, 75, 1
    #d8 2, 27, 26, 5, w_F_M_CD & 0xFF, w_F_M_CD >> 8
w_E_M_UP1:
    #d8 2, 222, 75, 25, 12, 4, 6, 34, 2, 222, 75, 26
    #d8 0, 13, 2, 214, 75, 23, 2, 212, 75, 24, 1, 1
    #d8 2, 226, 75, 26, 0
w_E_M_GUARD:
    #d8 2, 223, 75, 25, 40, 4, 3, 1, 0, 0, 2, (w_E_M_UNSAVED) & 0xFF
    #d8 (w_E_M_UNSAVED) >> 8, 2, 220, 75, 24, 1, 3, (w_OPEN >> 8) | 0x80, w_OPEN & 0xFF, 1, 3, (w_UPDATE >> 8) | 0x80
    #d8 w_UPDATE & 0xFF, 2, 255, 255, 0
w_KEYS_M_UP:
    #d8 1, 120, 12, 4, 22, 54, 13, 8, 160, 8, 162, 29
    #d8 8, 164, 29, 8, 166, 29, 32, 40, 4, 2, 13, 0
    #d8 34, 3, 231, 13, 0
w_MENU_M_HIT:
    #d8 (w_CELL >> 8) | 0x80, w_CELL & 0xFF, 10, 149, 34, 1, 14, 38, 10, 150, (w_MENU_M_Y >> 8) | 0x80, w_MENU_M_Y & 0xFF
    #d8 28, 1, 8, 38, 29, 4, 6, 10, 150, (w_MENU_M_Y >> 8) | 0x80, w_MENU_M_Y & 0xFF, 28
    #d8 0, 2, 255, 255, 0
w_TO_M_FRONT:
    #d8 (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF, 14, 12, (w_RAISE >> 8) | 0x80, w_RAISE & 0xFF, 14, 12, 41, 4, 3, 13
    #d8 3, 7, (w_W_M_RECT >> 8) | 0x80, w_W_M_RECT & 0xFF, 13, 1, 1, (w_REFRESH >> 8) | 0x80, w_REFRESH & 0xFF, (w_W_M_RECT >> 8) | 0x80, w_W_M_RECT & 0xFF, (w_REFRESH >> 8) | 0x80
    #d8 w_REFRESH & 0xFF, 5, w_RAIL_M_UPD & 0xFF, w_RAIL_M_UPD >> 8
w_PLC_Q_:
    #d8 12, 1, 8, 27, 25, 1, 80, 37, 15, 1, 9, 27
    #d8 25, 1, 76, 37, 29, 14, 1, 10, 27, 25, 1, 67
    #d8 37, 29, 0
w_PIC_Q_:
    #d8 12, 1, 8, 27, 25, 1, 80, 37, 15, 1, 9, 27
    #d8 25, 1, 73, 37, 29, 14, 1, 10, 27, 25, 1, 67
    #d8 37, 29, 0
w_WAV_Q_:
    #d8 12, 1, 8, 27, 25, 1, 87, 37, 15, 1, 9, 27
    #d8 25, 1, 65, 37, 29, 14, 1, 10, 27, 25, 1, 86
    #d8 37, 29, 0
w_DU_LT_:
    #d8 15, 1, 2, 27, 23, 15, 1, 2, 27, 23, 18, 37
    #d8 4, 8, 13, 13, 14, 23, 14, 23, 38, 0, 38, 16
    #d8 16, 0
w_IN_M_CLIP:
    #d8 10, 48, 12, 10, 50, 39, 40, 14, 10, 52, 39, 29
    #d8 10, 49, 12, 10, 51, 39, 40, 14, 10, 53, 39, 29
    #d8 29, 0
w_K_M_SHOW:
    #d8 1, 2, (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF, 37, 4, 13, 1, 0, 53, 1, 2
    #d8 (w_SETW >> 8) | 0x80, w_SETW & 0xFF, (w_K_M_DISP >> 8) | 0x80, w_K_M_DISP & 0xFF, 1, 1, 53, 0, 1, 2, 5, w_UPDATE & 0xFF
    #d8 w_UPDATE >> 8, 0
w_COPY_M_NS:
    #d8 12, 4, 19, 15, 25, 12, 1, 32, 37, 4, 3, 13
    #d8 3, 2, (w_N_P_ >> 8) | 0x80, w_N_P_ & 0xFF, 14, 33, 14, 34, 3, 234, 13, 13
    #d8 0
w_E_M_DOWNK:
    #d8 2, 210, 75, 23, (w_E_M_EOL >> 8) | 0x80, w_E_M_EOL & 0xFF, 12, 2, 208, 75, 23, 38
    #d8 40, 4, 2, 13, 0, 33, (w_E_M_COL >> 8) | 0x80, w_E_M_COL & 0xFF, (w_E_M_TOCOL >> 8) | 0x80, w_E_M_TOCOL & 0xFF, 5, w_E_M_DN1 & 0xFF
    #d8 w_E_M_DN1 >> 8
w_W_M_RECT:
    #d8 (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 12, 33, 25, 14, 12, 1, 2, 27, 25, 14
    #d8 12, 1, 3, 27, 25, 14, 1, 4, 27, 25, 0
w_E_M_CUR:
    #d8 (w_E_M_COL >> 8) | 0x80, w_E_M_COL & 0xFF, 2, 218, 75, 23, 28, 33, 2, 222, 75, 25
    #d8 1, 2, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF, (w_IN_M_CLIP >> 8) | 0x80, w_IN_M_CLIP & 0xFF, 4, 1, 52, 0
w_E_M_BIGM:
    #d8 22, 84, 111, 111, 32, 98, 105, 103, 32, 102, 111, 114
    #d8 32, 116, 104, 101, 32, 69, 100, 105, 116, 111, 114
w_D_M_KEEPM:
    #d8 22, 75, 101, 101, 112, 63, 32, 89, 32, 111, 114, 32
    #d8 99, 108, 105, 99, 107, 44, 32, 49, 48, 32, 115
w_E_M_BOL:
    #d8 12, 4, 10, 12, 34, (w_E_AT_ >> 8) | 0x80, w_E_AT_ & 0xFF, 1, 10, 37, 40, 3
    #d8 2, 1, 0, 4, 3, 34, 3, 236, 0
w_D_M_M0:
    #d8 20, 54, 52, 48, 32, 120, 32, 52, 56, 48, 32, 32
    #d8 32, 50, 32, 99, 111, 108, 111, 114, 115
w_D_M_M1:
    #d8 20, 54, 52, 48, 32, 120, 32, 50, 52, 48, 32, 32
    #d8 32, 52, 32, 99, 111, 108, 111, 114, 115
w_D_M_M2:
    #d8 20, 51, 50, 48, 32, 120, 32, 50, 52, 48, 32, 32
    #d8 49, 54, 32, 99, 111, 108, 111, 114, 115
w_C_M_H:
    #d8 2, 140, 75, 25, 33, 12, 1, 24, 37, 4, 3, 13
    #d8 1, 0, 2, 140, 75, 26, 5, w_C_M_UPD & 0xFF, w_C_M_UPD >> 8
w_C_M_M:
    #d8 2, 141, 75, 25, 33, 12, 1, 60, 37, 4, 3, 13
    #d8 1, 0, 2, 141, 75, 26, 5, w_C_M_UPD & 0xFF, w_C_M_UPD >> 8
w_CELL:
    #d8 8, 56, 2, 83, 46, 25, (w_RSH >> 8) | 0x80, w_RSH & 0xFF, 11, 149, 8, 58
    #d8 2, 84, 46, 25, (w_RSH >> 8) | 0x80, w_RSH & 0xFF, 11, 150, 0
w_K_M_KEYS:
    #d8 99, 110, 8, 47, 55, 56, 57, 42, 52, 53, 54, 45
    #d8 49, 50, 51, 43, 48, 122, 109, 61
w_E_M_TOCOL:
    #d8 19, 12, (w_E_M_EOL >> 8) | 0x80, w_E_M_EOL & 0xFF, 15, 28, 20, (w_UMIN >> 8) | 0x80, w_UMIN & 0xFF, 15, 27, 2
    #d8 210, 75, 24, 2, 214, 75, 24, 0
w_E_M_UPK:
    #d8 2, 214, 75, 23, 12, 40, 4, 2, 13, 0, 34, (w_E_M_BOL >> 8) | 0x80
    #d8 w_E_M_BOL & 0xFF, (w_E_M_COL >> 8) | 0x80, w_E_M_COL & 0xFF, (w_E_M_TOCOL >> 8) | 0x80, w_E_M_TOCOL & 0xFF, 5, w_E_M_UP1 & 0xFF, w_E_M_UP1 >> 8
w_D_M_NOTE:
    #d8 19, 52, 44, 32, 49, 54, 58, 32, 114, 101, 118, 32
    #d8 66, 32, 98, 111, 97, 114, 100, 115
w_TABW:
    #d8 (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 1, 18, 28, 10, 144, 12, 40, 4, 1, 33
    #d8 43, 16, 1, 11, 5, w_UMIN & 0xFF, w_UMIN >> 8
w_RETOP:
    #d8 (w_TOPW >> 8) | 0x80, w_TOPW & 0xFF, 12, 41, 4, 3, 13, 3, 7, (w_W_M_RECT >> 8) | 0x80, w_W_M_RECT & 0xFF, 13
    #d8 1, 1, (w_REFRESH >> 8) | 0x80, w_REFRESH & 0xFF, 5, w_RAIL_M_UPD & 0xFF, w_RAIL_M_UPD >> 8
w_D_M_NOFILE:
    #d8 18, 78, 111, 32, 80, 73, 78, 66, 79, 65, 82, 68
    #d8 32, 102, 111, 108, 100, 101, 114
w_E_M_EOL:
    #d8 2, 208, 75, 23, 15, 28, 14, 2, 0, 64, 27, 14
    #d8 55, 2, 0, 64, 28, 0
w_CLAMP:
    #d8 15, 41, 4, 5, 13, 13, 1, 0, 0, 18, 14, 39
    #d8 4, 2, 16, 0, 13, 0
w_TOPW:
    #d8 10, 144, 12, 4, 7, 34, 2, 32, 75, 27, 25, 0
    #d8 13, 2, 255, 255, 0
w_E_M_FULLM:
    #d8 16, 78, 111, 32, 114, 111, 111, 109, 32, 102, 111, 114
    #d8 32, 109, 111, 114, 101
w_RAISE:
    #d8 12, (w_Z_M_REMOVE >> 8) | 0x80, w_Z_M_REMOVE & 0xFF, 10, 144, 2, 32, 75, 27, 26, 10, 144
    #d8 33, 11, 144, 0
w_DRAWWIN:
    #d8 12, (w_SETW >> 8) | 0x80, w_SETW & 0xFF, 12, (w_FRAME >> 8) | 0x80, w_FRAME & 0xFF, (w_INK >> 8) | 0x80, w_INK & 0xFF, 35, 2, (w_DRAWTAB) & 0xFF, (w_DRAWTAB) >> 8
    #d8 27, 23, 44, 0
w_CLOSE:
    #d8 1, 0, 15, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 26, 12, (w_Z_M_REMOVE >> 8) | 0x80, w_Z_M_REMOVE & 0xFF, (w_W_M_RECT >> 8) | 0x80, w_W_M_RECT & 0xFF, (w_REFRESH >> 8) | 0x80
    #d8 w_REFRESH & 0xFF, 5, w_RETOP & 0xFF, w_RETOP >> 8
w_E_M_BINM:
    #d8 15, 78, 111, 116, 32, 97, 32, 116, 101, 120, 116, 32
    #d8 102, 105, 108, 101
w_KIND_Q_:
    #d8 2, 25, 93, 25, 1, 86, 37, 4, 3, 5, w_PIC_Q_ & 0xFF, w_PIC_Q_ >> 8
    #d8 5, w_WAV_Q_ & 0xFF, w_WAV_Q_ >> 8, 0
w_D_M_CLICK:
    #d8 10, 152, 1, 2, 28, 12, 1, 3, 38, 4, 3, 5
    #d8 w_D_M_SET & 0xFF, w_D_M_SET >> 8, 13, 0
w_MITEMS:
    #d8 w_M_M_FILES & 0xFF, w_M_M_FILES >> 8, w_M_M_CLOCK & 0xFF, w_M_M_CLOCK >> 8, w_M_M_CALC & 0xFF, w_M_M_CALC >> 8, w_M_M_EDIT & 0xFF, w_M_M_EDIT >> 8, w_M_M_ABOUT & 0xFF, w_M_M_ABOUT >> 8, w_T_M_DISP & 0xFF, w_T_M_DISP >> 8
    #d8 w_M_M_BASIC & 0xFF, w_M_M_BASIC >> 8, w_M_M_DOS & 0xFF, w_M_M_DOS >> 8
w_E_M_DEL:
    #d8 2, 210, 75, 23, 2, 208, 75, 23, 38, 4, 3, 5
    #d8 w_E_M_CUT & 0xFF, w_E_M_CUT >> 8, 0
w_C_M_S:
    #d8 1, 0, 2, 142, 75, 26, 1, 0, 2, 138, 75, 24
    #d8 5, w_C_M_UPD & 0xFF, w_C_M_UPD >> 8
w_NEXT_M_WIN:
    #d8 10, 144, 1, 2, 39, 4, 1, 0, 2, 32, 75, 25
    #d8 5, w_TO_M_FRONT & 0xFF, w_TO_M_FRONT >> 8
w__D_2:
    #d8 1, 10, 43, 1, 48, 27, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 1, 48, 27, 5
    #d8 w_GLYPH & 0xFF, w_GLYPH >> 8
w_SETCLIP:
    #d8 17, 12, 11, 51, 27, 11, 53, 15, 27, 11, 52, 11
    #d8 50, 0
w_K_M_SIGNS:
    #d8 2, 184, 75, 25, 2, 185, 75, 25, 31, 2, 184, 75
    #d8 26, 0
w_ROOT_Q_:
    #d8 2, 96, 77, 23, 2, 96, 77, 1, 2, 27, 23, 30
    #d8 40, 0
w_E_M_NOSAVE:
    #d8 13, 67, 97, 110, 39, 116, 32, 115, 97, 118, 101, 32
    #d8 105, 116
w_E_M_READM:
    #d8 13, 67, 97, 110, 39, 116, 32, 114, 101, 97, 100, 32
    #d8 105, 116
w_D_M_KEY:
    #d8 1, 49, 28, 12, 1, 3, 38, 4, 3, 5, w_D_M_SET & 0xFF, w_D_M_SET >> 8
    #d8 13, 0
w_SELF:
    #d8 80, 73, 78, 66, 79, 65, 82, 68, 46, 80, 76, 67
    #d8 0
w_NOCLIP:
    #d8 1, 0, 1, 0, (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 2, 81, 46, 25, 5, w_SETCLIP & 0xFF
    #d8 w_SETCLIP >> 8
w_N_P_:
    #d8 10, 155, 2, 112, 75, 27, 26, 10, 155, 33, 11, 155
    #d8 0
w_REFRESH:
    #d8 1, 0, 53, (w_SETCLIP >> 8) | 0x80, w_SETCLIP & 0xFF, (w_REPAINT >> 8) | 0x80, w_REPAINT & 0xFF, (w_NOCLIP >> 8) | 0x80, w_NOCLIP & 0xFF, 1, 1, 53
    #d8 0
w_REFRESH_M_ALL:
    #d8 1, 0, 1, 0, (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 2, 81, 46, 25, 5, w_REFRESH & 0xFF
    #d8 w_REFRESH >> 8
w_F_M_SHOW:
    #d8 (w_F_M_FIX >> 8) | 0x80, w_F_M_FIX & 0xFF, 1, 0, 2, 148, 75, 24, 1, 0, 5, w_UPDATE & 0xFF
    #d8 w_UPDATE >> 8
w_LEAVE_M_DESK:
    #d8 (w_KEYS_M_UP >> 8) | 0x80, w_KEYS_M_UP & 0xFF, 1, 0, 53, 1, 0, 2, (con_clear) & 0xFF, (con_clear) >> 8, 48, 13
    #d8 0
w_C_M_UPD:
    #d8 1, 1, (w_UPDATE >> 8) | 0x80, w_UPDATE & 0xFF, 1, 0, 53, (w_RAIL_M_TIME >> 8) | 0x80, w_RAIL_M_TIME & 0xFF, 1, 1, 53
    #d8 0
w_TITLES:
    #d8 w_T_M_FILES & 0xFF, w_T_M_FILES >> 8, w_T_M_CLOCK & 0xFF, w_T_M_CLOCK >> 8, w_T_M_CALC & 0xFF, w_T_M_CALC >> 8, w_T_M_EDIT & 0xFF, w_T_M_EDIT >> 8, w_T_M_ABOUT & 0xFF, w_T_M_ABOUT >> 8, w_T_M_DISP & 0xFF, w_T_M_DISP >> 8
w_ZTYPE:
    #d8 12, 12, 25, 4, 3, 33, 3, 249, 15, 28, 51, 0
w_F_M_ROWS:
    #d8 1, 0, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 1, 4, 27, 25, 1, 4, 28, 0
w_D0_ST_:
    #d8 1, 0, 15, 24, 1, 0, 14, 1, 2, 27, 24, 0
w_E_M_ROWS:
    #d8 1, 3, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 1, 4, 27, 25, 1, 4, 28, 0
w_E_M_COLS:
    #d8 1, 3, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 1, 3, 27, 25, 1, 2, 28, 0
w_DRAWTAB:
    #d8 w_F_M_DRAW & 0xFF, w_F_M_DRAW >> 8, w_C_M_DRAW & 0xFF, w_C_M_DRAW >> 8, w_K_M_DRAW & 0xFF, w_K_M_DRAW >> 8, w_E_M_DRAW & 0xFF, w_E_M_DRAW >> 8, w_A_M_DRAW & 0xFF, w_A_M_DRAW >> 8, w_D_M_DRAW & 0xFF, w_D_M_DRAW >> 8
w_E_M_BKSP:
    #d8 2, 210, 75, 23, 4, 5, (w_E_M_LEFTK >> 8) | 0x80, w_E_M_LEFTK & 0xFF, 5, w_E_M_CUT & 0xFF, w_E_M_CUT >> 8, 0
w_D_M_F2:
    #d8 67, 79, 76, 79, 82, 49, 54, 46, 68, 82, 86, 0
w_KEYTAB:
    #d8 w_F_M_KEY & 0xFF, w_F_M_KEY >> 8, w_C_M_KEY & 0xFF, w_C_M_KEY >> 8, w_K_M_KEY & 0xFF, w_K_M_KEY >> 8, w_E_M_KEY & 0xFF, w_E_M_KEY >> 8, w_KDROP & 0xFF, w_KDROP >> 8, w_D_M_KEY & 0xFF, w_D_M_KEY >> 8
w_CLICKTAB:
    #d8 w_F_M_CLICK & 0xFF, w_F_M_CLICK >> 8, w_C_M_CLICK & 0xFF, w_C_M_CLICK >> 8, w_K_M_CLICK & 0xFF, w_K_M_CLICK >> 8, w_E_M_CLICK & 0xFF, w_E_M_CLICK >> 8, w_NOP & 0xFF, w_NOP >> 8, w_D_M_CLICK & 0xFF, w_D_M_CLICK >> 8
w_M_M_DOS:
    #d8 11, 66, 97, 99, 107, 32, 116, 111, 32, 68, 79, 83
w_AT:
    #d8 10, 146, 27, 11, 49, 10, 145, 27, 11, 48, 0
w_K_M_DISP:
    #d8 1, 20, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, (w_K_M_DISP1 >> 8) | 0x80, w_K_M_DISP1 & 0xFF, 1, 0, 5, w_PEN & 0xFF, w_PEN >> 8
w_E_M_NONE:
    #d8 10, 40, 110, 101, 119, 32, 116, 101, 120, 116, 41
w_RAIL_M_UPD:
    #d8 1, 0, (w_BOARD_M_H >> 8) | 0x80, w_BOARD_M_H & 0xFF, (w_COLS >> 8) | 0x80, w_COLS & 0xFF, 1, 3, 5, w_REFRESH & 0xFF, w_REFRESH >> 8
w_D_M_F1:
    #d8 67, 79, 76, 79, 82, 52, 46, 68, 82, 86, 0
w_RSH:
    #d8 12, 4, 6, 14, 36, 14, 34, 3, 247, 13, 0
w_M_M_CALC:
    #d8 10, 67, 97, 108, 99, 117, 108, 97, 116, 111, 114
w_MENU_M_CLOSE:
    #d8 1, 1, (w_MENU_M_Y >> 8) | 0x80, w_MENU_M_Y & 0xFF, 1, 14, 1, 8, 5, w_REFRESH & 0xFF, w_REFRESH >> 8
w_U_D_R:
    #d8 19, (w_U_GT_S >> 8) | 0x80, w_U_GT_S & 0xFF, 20, 15, 28, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 51, 0
w_CTYPE:
    #d8 19, 12, 33, 14, 25, 20, (w_UMIN >> 8) | 0x80, w_UMIN & 0xFF, 51, 0
w_D0_EQ_:
    #d8 12, 23, 14, 1, 2, 27, 23, 30, 40, 0
w_E_M_COL:
    #d8 2, 210, 75, 23, 2, 214, 75, 23, 28, 0
w_E_M_ASKM:
    #d8 9, 83, 97, 118, 101, 32, 97, 115, 58, 32
w_P_M_NAME:
    #d8 80, 72, 79, 84, 79, 46, 80, 76, 67, 0
w_PEN:
    #d8 35, 2, 32, 46, 27, 23, 9, 46, 0
w_K_M_CLR:
    #d8 2, 160, 75, 1, 32, 1, 0, 47, 0
w_ENT:
    #d8 35, 35, 35, 35, 2, 0, 84, 27, 0
w_OPEN:
    #d8 1, 1, 15, (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 26, 5, w_TO_M_FRONT & 0xFF, w_TO_M_FRONT >> 8
w_F_M_RUN:
    #d8 1, 0, 2, 25, 93, 26, 5, w_F_M_GO & 0xFF, w_F_M_GO >> 8
w_W_M_NAME:
    #d8 87, 65, 86, 69, 46, 80, 76, 67, 0
w_D_M_DIR:
    #d8 80, 73, 78, 66, 79, 65, 82, 68, 0
w_D_M_F0:
    #d8 77, 79, 78, 79, 46, 68, 82, 86, 0
w_D_M_SAY:
    #d8 2, 248, 75, 24, 1, 5, 5, w_UPDATE & 0xFF, w_UPDATE >> 8
w_T_M_DISP:
    #d8 7, 68, 105, 115, 112, 108, 97, 121
w_SPACES:
    #d8 1, 32, 10, 54, 31, 14, 50, 0
w_UMIN:
    #d8 18, 38, 4, 2, 13, 0, 16, 0
w_WIN:
    #d8 35, 35, 35, 2, 64, 75, 27, 0
w_DIR_Q_:
    #d8 1, 11, 27, 25, 1, 16, 29, 0
w_MACT:
    #d8 0, 1, 2, 3, 4, 5, 254, 255
w_T_M_EDIT:
    #d8 6, 69, 100, 105, 116, 111, 114
w_K_M_BAD:
    #d8 1, 1, 2, 188, 75, 26, 0
w_M_M_EDIT:
    #d8 6, 69, 100, 105, 116, 111, 114
w_T_M_CLOCK:
    #d8 5, 67, 108, 111, 99, 107
w_T_M_ABOUT:
    #d8 5, 65, 98, 111, 117, 116
w_TYPE:
    #d8 12, 33, 14, 25, 51, 0
w_K_M_EMSG:
    #d8 5, 69, 114, 114, 111, 114
w_SBX:
    #d8 10, 147, 1, 2, 28, 0
w_E_AT_:
    #d8 2, 0, 64, 27, 25, 0
w_D_M_ITEMS:
    #d8 w_D_M_M0 & 0xFF, w_D_M_M0 >> 8, w_D_M_M1 & 0xFF, w_D_M_M1 >> 8, w_D_M_M2 & 0xFF, w_D_M_M2 >> 8
w_E_M_SAVED:
    #d8 5, 83, 97, 118, 101, 100
w_D_M_FILES:
    #d8 w_D_M_F0 & 0xFF, w_D_M_F0 >> 8, w_D_M_F1 & 0xFF, w_D_M_F1 >> 8, w_D_M_F2 & 0xFF, w_D_M_F2 >> 8
w_MENU_M_Y:
    #d8 (w_BOARD_M_H >> 8) | 0x80, w_BOARD_M_H & 0xFF, 1, 8, 28, 0
w_M_M_FILES:
    #d8 5, 70, 105, 108, 101, 115
w_M_M_CLOCK:
    #d8 5, 67, 108, 111, 99, 107
w_M_M_ABOUT:
    #d8 5, 65, 98, 111, 117, 116
w_M_M_BASIC:
    #d8 5, 66, 65, 83, 73, 67
w_T_M_CALC:
    #d8 4, 67, 97, 108, 99
w_GLYPH:
    #d8 10, 54, 31, 49, 0
w_INK:
    #d8 1, 128, 11, 54, 0
w_REV:
    #d8 1, 0, 11, 54, 0
w_ABS_M_AT:
    #d8 11, 49, 11, 48, 0
w_COLS:
    #d8 2, 80, 46, 25, 0
w_BOARD_M_H:
    #d8 2, 82, 46, 25, 0
w_SYS0:
    #d8 1, 0, 14, 48, 0
w_KDROP:
    #d8 13, 0

#addr 0x2000
vm_jump:
    ld   p_exit >> 8, y
    jmp  p_exit
    ld   p_lit8 >> 8, y
    jmp  p_lit8
    ld   p_lit16 >> 8, y
    jmp  p_lit16
    ld   p_br >> 8, y
    jmp  p_br
    ld   p_0br >> 8, y
    jmp  p_0br
    ld   p_lbr >> 8, y
    jmp  p_lbr
    ld   p_l0br >> 8, y
    jmp  p_l0br
    ld   p_slit >> 8, y
    jmp  p_slit
    ld   p_zpat >> 8, y
    jmp  p_zpat
    ld   p_zpst >> 8, y
    jmp  p_zpst
    ld   p_zpcat >> 8, y
    jmp  p_zpcat
    ld   p_zpcst >> 8, y
    jmp  p_zpcst
    ld   p_dup >> 8, y
    jmp  p_dup
    ld   p_drop >> 8, y
    jmp  p_drop
    ld   p_swap >> 8, y
    jmp  p_swap
    ld   p_over >> 8, y
    jmp  p_over
    ld   p_nip >> 8, y
    jmp  p_nip
    ld   p_rot >> 8, y
    jmp  p_rot
    ld   p_2dup >> 8, y
    jmp  p_2dup
    ld   p_tor >> 8, y
    jmp  p_tor
    ld   p_rfrom >> 8, y
    jmp  p_rfrom
    ld   p_rat >> 8, y
    jmp  p_rat
    ld   p_rdrop >> 8, y
    jmp  p_rdrop
    ld   p_at >> 8, y
    jmp  p_at
    ld   p_store >> 8, y
    jmp  p_store
    ld   p_cat >> 8, y
    jmp  p_cat
    ld   p_cstore >> 8, y
    jmp  p_cstore
    ld   p_add >> 8, y
    jmp  p_add
    ld   p_sub >> 8, y
    jmp  p_sub
    ld   p_and >> 8, y
    jmp  p_and
    ld   p_or >> 8, y
    jmp  p_or
    ld   p_xor >> 8, y
    jmp  p_xor
    ld   p_invert >> 8, y
    jmp  p_invert
    ld   p_inc >> 8, y
    jmp  p_inc
    ld   p_dec >> 8, y
    jmp  p_dec
    ld   p_2mul >> 8, y
    jmp  p_2mul
    ld   p_2div >> 8, y
    jmp  p_2div
    ld   p_eq >> 8, y
    jmp  p_eq
    ld   p_ult >> 8, y
    jmp  p_ult
    ld   p_lt >> 8, y
    jmp  p_lt
    ld   p_0eq >> 8, y
    jmp  p_0eq
    ld   p_0lt >> 8, y
    jmp  p_0lt
    ld   p_mul >> 8, y
    jmp  p_mul
    ld   p_umod >> 8, y
    jmp  p_umod
    ld   p_execute >> 8, y
    jmp  p_execute
    ld   p_cmove >> 8, y
    jmp  p_cmove
    ld   p_cmoveu >> 8, y
    jmp  p_cmoveu
    ld   p_fill >> 8, y
    jmp  p_fill
    ld   p_sys >> 8, y
    jmp  p_sys
    ld   p_emit >> 8, y
    jmp  p_emit
    ld   p_hfill >> 8, y
    jmp  p_hfill
    ld   p_gtype >> 8, y
    jmp  p_gtype
    ld   p_invc >> 8, y
    jmp  p_invc
    ld   p_ptr >> 8, y
    jmp  p_ptr
    ld   p_poll >> 8, y
    jmp  p_poll
    ld   p_scan >> 8, y
    jmp  p_scan
p_invc:
    ld   DRV_INVC >> 8, y
    jmp  DRV_INVC

w_SETW:
    #d8 (w_WIN >> 8) | 0x80, w_WIN & 0xFF, 12, 33, 25, 11, 145, 12, 1, 2, 27, 25
    #d8 11, 146, 12, 1, 3, 27, 25, 11, 147, 1, 4, 27
    #d8 25, 11, 148, 0
; DUP DROP LIT8 (the most used: they
; branch back to next)
next:
    ld   [IPH], y               ; Y:X = IP, then IP + 1
    ld   [IPL], x
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    beq  nx_c
nx_f:
    ld   [y,x], ac
    blt  nx_call
    shl                         ; the primitive: vm_jump + opcode x 4
    shl
    ld   vm_jump >> 8, y
    jmp  ac
nx_c:
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  nx_f
nx_call:                        ; AC = the word's high byte + x80, IP at its low byte
    and  0x7F, ac
    ld   ac, [W0]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W1]
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    bne  nx_2
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
nx_2:
    ld   [RSP], x               ; push IP on the return stack
    ld   RSTK >> 8, y
    ld   [IPH], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  1, x
    ld   [IPL], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  2, ac
    ld   ac, [RSP]
    ld   [W1], ac
    ld   ac, [IPL]
    ld   [W0], ac
    ld   ac, [IPH]
    bra  next
ip2:
    ld   [IPL], ac
    add  2, ac
    ld   ac, [IPL]
    bcc  next
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  next
ip1:
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    bne  next
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  next
p_br:                           ; BR n: IP = IP + 1 + n (n signed)
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    add  [IPL], ac
    ld   ac, [IPL]
    bcc  br_nc
    ld   [W0], ac
    blt  ip1                    ; back, with a carry: the same page
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  ip1
br_nc:
    ld   [W0], ac
    blt  br_dec
    bra  ip1
br_dec:
    ld   [IPH], ac
    dec
    ld   ac, [IPH]
    bra  ip1
p_0br:                          ; 0BR n: branch if TOS = 0, drop it
    ld   [TL], ac
    or   [TH], ac
    ld   ac, [W2]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [W2], ac
    beq  p_br
    bra  ip1
p_dup:
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    bra  next
p_drop:
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    bra  next
p_lit8:                         ; LIT8 n ( -- n )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    bra  ip1


w_RAIL_M_Y:
    #d8 (w_BOARD_M_H >> 8) | 0x80, w_BOARD_M_H & 0xFF, 33, 0
p_exit:
    ld   [RSP], ac
    add  1, x
    ld   RSTK >> 8, y
    ld   [y,x], ac
    ld   ac, [IPL]
    ld   [RSP], ac
    add  2, x
    ld   [y,x], ac
    ld   ac, [IPH]
    ld   [RSP], ac
    add  2, ac
    ld   ac, [RSP]
    ld   next >> 8, y
    jmp  next
p_l0br:                         ; L0BR a: IP = a if TOS = 0, drop it
    ld   [TL], ac
    or   [TH], ac
    ld   ac, [W2]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [W2], ac
    beq  p_lbr
    ld   ip2 >> 8, y
    jmp  ip2
p_lbr:                          ; LBR a: IP = a
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   [IPL], ac
    inc
    ld   ac, x
    bne  lb_1
    ld   [IPH], ac
    inc
    ld   ac, y
lb_1:
    ld   [y,x], ac
    ld   ac, [IPH]
    ld   [W0], ac
    ld   ac, [IPL]
    ld   next >> 8, y
    jmp  next
p_execute:                      ; EXECUTE ( a -- ): call the word at a
    ld   [RSP], x
    ld   RSTK >> 8, y
    ld   [IPH], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  1, x
    ld   [IPL], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  2, ac
    ld   ac, [RSP]
    ld   [TL], ac
    ld   ac, [IPL]
    ld   [TH], ac
    ld   ac, [IPH]
    ld   p_drop >> 8, y
    jmp  p_drop

p_lit16:                        ; LIT16 n ( -- n )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [TL]
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    bne  ii15
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
ii15:
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [TH]
    ld   ip1 >> 8, y
    jmp  ip1
p_slit:                         ; SLIT n "..." ( -- a ): a = the length byte's address
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPL], ac
    ld   ac, [TL]
    ld   [IPH], ac
    ld   ac, [TH]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    inc
    add  [IPL], ac
    ld   ac, [IPL]
    bcc  sl_nc
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
sl_nc:
    ld   next >> 8, y
    jmp  next

w_K_M_KEY:
    #d8 12, 1, 10, 37, 4, 3, 13, 1, 61, 12, 1, 127
    #d8 37, 4, 3, 13, 1, 99, 12, 1, 37, 37, 4, 3
    #d8 13, 1, 109, 1, 64, 15, 39, 4, 3, 1, 32, 30
    #d8 5, w_K_M_DO & 0xFF, w_K_M_DO >> 8
p_zpat:                         ; ZP@ n ( -- [n] )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   ac, x
    ld   [x], ac
    ld   ac, [TL]
    ld   [W0], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   ip1 >> 8, y
    jmp  ip1
p_zpcat:                        ; ZPC@ n ( -- [n] ), one byte
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, x
    ld   [x], ac
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   ip1 >> 8, y
    jmp  ip1
p_zpst:                         ; ZP! n ( v -- )
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [W0], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   ip1 >> 8, y
    jmp  ip1
p_zpcst:                        ; ZPC! n ( v -- ), one byte
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   ip1 >> 8, y
    jmp  ip1

p_at:                           ; @ ( a -- [a] )
    ld   [TH], y
    ld   [TL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   [TL], ac
    inc
    ld   ac, x
    bne  at_1
    ld   [TH], ac
    inc
    ld   ac, y
at_1:
    ld   [y,x], ac
    ld   ac, [TH]
    ld   [W0], ac
    ld   ac, [TL]
    ld   next >> 8, y
    jmp  next
p_cat:                          ; C@ ( a -- [a] ), one byte
    ld   [TH], y
    ld   [TL], x
    ld   [y,x], ac
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_store:                        ; ! ( v a -- )
    ld   [DSP], ac              ; W0 = v high
    add  1, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], x               ; v low
    ld   [x], ac
    ld   [TH], y
    ld   [TL], x
    ld   ac, [y,x]
    ld   [TL], ac
    inc
    ld   ac, x
    bne  st_1
    ld   [TH], ac
    inc
    ld   ac, y
st_1:
    ld   [W0], ac
    ld   ac, [y,x]
st_pop2:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next
p_cstore:                       ; C! ( v a -- )
    ld   [DSP], x
    ld   [x], ac
    ld   [TH], y
    ld   [TL], x
    ld   ac, [y,x]
    bra  st_pop2

w_NOP:
    #d8 0
p_nip:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next
p_swap:
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [W0]
    ld   [TL], ac
    ld   ac, [x]
    ld   [W0], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [TH], ac
    ld   ac, [x]
    ld   [W0], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_over:                         ; ( a b -- a b a )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  2, x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  3, x
    ld   [x], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_2dup:                         ; ( a b -- a b a b )
    ld   [DSP], ac              ; W1:W0 = a
    ld   ac, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    ld   [DSP], ac              ; two cells more: b, then a below TOS
    sub  4, ac
    ld   ac, [DSP]
    add  2, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  3, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [DSP], x
    ld   [W0], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [W1], ac
    ld   ac, [x]
    ld   next >> 8, y
    jmp  next

p_add:
    ld   [DSP], x
    ld   [x], ac
    add  [TL], ac
    ld   ac, [TL]
    bcc  vad_1
    ld   [TH], ac
    inc
    ld   ac, [TH]
vad_1:
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    add  [TH], ac
    ld   ac, [TH]
ad_nip:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next
p_sub:                          ; - ( a b -- a-b )
    ld   [DSP], x
    ld   [x], ac
    sub  [TL], ac
    ld   ac, [TL]
    bcc  sb_1
    ld   [TH], ac               ; a borrow: take one more from the high byte
    inc
    ld   ac, [TH]
sb_1:
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    sub  [TH], ac
    ld   ac, [TH]
    bra  ad_nip
p_and:
    ld   [DSP], x
    ld   [x], ac
    and  [TL], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    and  [TH], ac
    ld   ac, [TH]
    bra  ad_nip
p_or:
    ld   [DSP], x
    ld   [x], ac
    or   [TL], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    or   [TH], ac
    ld   ac, [TH]
    bra  ad_nip
p_xor:
    ld   [DSP], x
    ld   [x], ac
    xor  [TL], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    xor  [TH], ac
    ld   ac, [TH]
    bra  ad_nip

w_DIGS:
    #d8 111, 123, 151, 44, 231, 115, 207, 115, 201, 91, 207, 121
    #d8 239, 121, 73, 114, 239, 123, 207, 123
p_rot:                          ; ( a b c -- b c a )
    ld   [DSP], ac              ; W1:W0 = a (at DSP + 2)
    add  2, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  3, x
    ld   [x], ac
    ld   ac, [W1]
    ld   [DSP], x               ; DSP + 2 = b
    ld   [x], ac
    ld   ac, [W2]
    ld   [DSP], ac
    add  2, x
    ld   [W2], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W2]
    ld   [DSP], ac
    add  3, x
    ld   [W2], ac
    ld   ac, [x]
    ld   [DSP], x               ; DSP = c
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [W0], ac               ; TOS = a
    ld   ac, [TL]
    ld   [W1], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_tor:                          ; >R ( a -- )
    ld   [RSP], x
    ld   RSTK >> 8, y
    ld   [TH], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  1, x
    ld   [TL], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  2, ac
    ld   ac, [RSP]
    ld   p_drop >> 8, y
    jmp  p_drop
p_rfrom:                        ; R> ( -- a )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [RSP], ac
    add  2, ac
    ld   ac, [RSP]
    bra  rf_get
p_rat:                          ; R@ ( -- a )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [RSP], ac
    add  2, ac
rf_get:                         ; TOS = the return stack entry at AC - 1 (low), AC (high)
    ld   ac, [W0]
    ld   ac, x
    ld   RSTK >> 8, y
    ld   [y,x], ac
    ld   ac, [TH]
    ld   [W0], ac
    sub  1, x
    ld   [y,x], ac
    ld   ac, [TL]
    ld   next >> 8, y
    jmp  next
p_rdrop:
    ld   [RSP], ac
    add  2, ac
    ld   ac, [RSP]
    ld   next >> 8, y
    jmp  next

p_fill:
    ld   [TL], ac               ; W4 = c, TOS = n, W1:W0 = a
    ld   ac, [W4]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
fi_lp:
    ld   [TL], ac
    or   [TH], ac
    beq  fi_done
    ld   [W1], y
    ld   [W0], x
    ld   [W4], ac
    ld   ac, [y,x]
    ld   [W0], ac
    inc
    ld   ac, [W0]
    bne  fi_1
    ld   [W1], ac
    inc
    ld   ac, [W1]
fi_1:
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  fi_lp
    ld   [TH], ac
    dec
    ld   ac, [TH]
    bra  fi_lp
fi_done:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   p_drop >> 8, y
    jmp  p_drop

w_T_M_FILES:
    #d8 5, 70, 105, 108, 101, 115
p_invert:
    ld   [TL], ac
    not
    ld   ac, [TL]
    ld   [TH], ac
    not
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_inc:
    ld   [TL], ac
    inc
    ld   ac, [TL]
    bne  in_1
    ld   [TH], ac
    inc
    ld   ac, [TH]
in_1:
    ld   next >> 8, y
    jmp  next
p_dec:
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  in_1
    ld   [TH], ac
    dec
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_2mul:
    ld   [TL], ac
    shl
    ld   ac, [TL]
    ld   [TH], ac
    bcc  m2_1
    shl
    or   1, ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
m2_1:
    shl
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_2div:                         ; arithmetic: the sign stays
    ld   [TL], ac
    shr  ac
    ld   ac, [TL]
    ld   [TH], ac
    and  1, ac
    beq  d2_1
    ld   [TL], ac
    or   0x80, ac
    ld   ac, [TL]
d2_1:
    ld   [TH], ac
    and  0x80, ac
    ld   ac, [W0]
    ld   [TH], ac
    shr  ac
    or   [W0], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next

p_eq:
    ld   [DSP], x
    ld   [x], ac
    xor  [TL], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    xor  [TH], ac
    or   [W0], ac
    beq  t_true
    bra  t_false
p_ult:
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    sub  [TH], ac
    bcs  t_true
    bne  t_false
ult_lo:
    ld   [DSP], x
    ld   [x], ac
    sub  [TL], ac
    bcs  t_true
t_false:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
u_false:
    clr  ac
    ld   ac, [TL]
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_lt:                           ; signed: compare with the sign bits flipped
    ld   [TH], ac
    xor  0x80, ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    xor  0x80, ac
    sub  [W0], ac
    bcs  t_true
    bne  t_false
    bra  ult_lo
t_true:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
u_true:
    ld   0xFF, ac
    ld   ac, [TL]
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_0eq:
    ld   [TL], ac
    or   [TH], ac
    beq  u_true
    bra  u_false
p_0lt:
    ld   [TH], ac
    blt  u_true
    bra  u_false

w_BOARD:
    #d8 1, 1, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 10, 51, 12, 10, 53, 39, 15, (w_BOARD_M_H >> 8) | 0x80
    #d8 w_BOARD_M_H & 0xFF, 39, 29, 4, 18, 10, 50, 15, (w_ABS_M_AT >> 8) | 0x80, w_ABS_M_AT & 0xFF, 2, 85
    #d8 46, 25, 10, 52, 10, 50, 28, 50, 33, 3, 227, 13
    #d8 1, 0, 5, w_PEN & 0xFF, w_PEN >> 8
p_mul:
    ld   [DSP], x               ; W1:W0 = a, W3:W2 = 0
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    clr  ac
    ld   ac, [W2]
    ld   ac, [W3]
mu_lp:
    ld   [TL], ac
    and  1, ac
    beq  mu_sh
    ld   [W2], ac
    add  [W0], ac
    ld   ac, [W2]
    bcc  mu_hi
    ld   [W3], ac
    inc
    ld   ac, [W3]
mu_hi:
    ld   [W3], ac
    add  [W1], ac
    ld   ac, [W3]
mu_sh:
    ld   [W0], ac               ; a << 1
    shl
    ld   ac, [W0]
    ld   [W1], ac
    bcc  mu_a0
    shl
    or   1, ac
    bra  mu_a1
mu_a0:
    shl
mu_a1:
    ld   ac, [W1]
    ld   [TL], ac               ; b >> 1
    shr  ac
    ld   ac, [TL]
    ld   [TH], ac
    and  1, ac
    beq  mu_b0
    ld   [TL], ac
    or   0x80, ac
    ld   ac, [TL]
mu_b0:
    ld   [TH], ac
    shr  ac
    ld   ac, [TH]
    or   [TL], ac
    bne  mu_lp
    ld   [W2], ac
    ld   ac, [TL]
    ld   [W3], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next

p_umod:
    ld   [DSP], x               ; W1:W0 = a (becomes the quotient)
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    clr  ac                     ; W3:W2 = the remainder
    ld   ac, [W2]
    ld   ac, [W3]
    ld   16, ac
    ld   ac, [W4]
um_lp:
    ld   [W0], ac               ; W3:W2:W1:W0 << 1
    shl
    ld   ac, [W0]
    ld   [W1], ac
    bcc  um_1
    shl
    or   1, ac
    bra  um_2
um_1:
    shl
um_2:
    ld   ac, [W1]
    ld   [W2], ac
    bcc  um_3
    shl
    or   1, ac
    bra  um_4
um_3:
    shl
um_4:
    ld   ac, [W2]
    ld   [W3], ac
    bcc  um_5
    shl
    or   1, ac
    ld   ac, [W3]
    bra  um_sub                 ; bit 16 set: the remainder is more than b
um_5:
    shl
    ld   ac, [W3]
    sub  [TH], ac               ; remainder >= b?
    bcs  um_next
    bne  um_sub
    ld   [W2], ac
    sub  [TL], ac
    bcs  um_next
um_sub:
    ld   [W2], ac               ; remainder - b, quotient bit 1
    sub  [TL], ac
    ld   ac, [W2]
    ld   [W3], ac
    bcc  um_6
    dec
um_6:
    sub  [TH], ac
    ld   ac, [W3]
    ld   [W0], ac
    or   1, ac
    ld   ac, [W0]
um_next:
    ld   [W4], ac
    dec
    ld   ac, [W4]
    bne  um_lp
    ld   [DSP], x               ; below: the remainder, TOS: the quotient
    ld   [W2], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [W3], ac
    ld   ac, [x]
    ld   [W0], ac
    ld   ac, [TL]
    ld   [W1], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next

w_D1_P__ST_:
    #d8 12, 23, 33, 12, 19, 15, 24, 20, 4, 2, 13, 0
    #d8 1, 2, 27, 12, 23, 33, 14, 24, 0

#addr 0x2800
p_cmove:
    ld   [DSP], x               ; W1:W0 = to, W3:W2 = from, TOS = n
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    ld   [DSP], ac
    add  2, x
    ld   [x], ac
    ld   ac, [W2]
    ld   [DSP], ac
    add  3, x
    ld   [x], ac
    ld   ac, [W3]
cm_lp:
    ld   [TL], ac
    or   [TH], ac
    beq  cm_done
    ld   [W3], y
    ld   [W2], x
    ld   [y,x], ac
    ld   [W1], y
    ld   [W0], x
    ld   ac, [y,x]
    ld   [W2], ac
    inc
    ld   ac, [W2]
    bne  cm_1
    ld   [W3], ac
    inc
    ld   ac, [W3]
cm_1:
    ld   [W0], ac
    inc
    ld   ac, [W0]
    bne  cm_2
    ld   [W1], ac
    inc
    ld   ac, [W1]
cm_2:
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  cm_lp
    ld   [TH], ac
    dec
    ld   ac, [TH]
    bra  cm_lp
cm_done:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   p_drop >> 8, y
    jmp  p_drop

p_cmoveu:
    ld   [DSP], x               ; W1:W0 = to + n, W3:W2 = from + n
    ld   [x], ac
    add  [TL], ac
    ld   ac, [W0]
    ld   [TH], ac
    bcc  cu_1
    inc
cu_1:
    ld   ac, [W1]
    ld   [DSP], ac
    add  1, x
    ld   [W1], ac
    add  [x], ac
    ld   ac, [W1]
    ld   [DSP], ac
    add  2, x
    ld   [x], ac
    add  [TL], ac
    ld   ac, [W2]
    ld   [TH], ac
    bcc  cu_2
    inc
cu_2:
    ld   ac, [W3]
    ld   [DSP], ac
    add  3, x
    ld   [W3], ac
    add  [x], ac
    ld   ac, [W3]
cu_lp:
    ld   [TL], ac
    or   [TH], ac
    beq  cu_done
    ld   [W2], ac               ; from - 1
    sub  1, ac
    ld   ac, [W2]
    bcc  cu_3
    ld   [W3], ac
    dec
    ld   ac, [W3]
cu_3:
    ld   [W0], ac               ; to - 1
    sub  1, ac
    ld   ac, [W0]
    bcc  cu_4
    ld   [W1], ac
    dec
    ld   ac, [W1]
cu_4:
    ld   [W3], y
    ld   [W2], x
    ld   [y,x], ac
    ld   [W1], y
    ld   [W0], x
    ld   ac, [y,x]
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  cu_lp
    ld   [TH], ac
    dec
    ld   ac, [TH]
    bra  cu_lp
cu_done:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   p_drop >> 8, y
    jmp  p_drop

w_K_M_FIN:
    #d8 2, 160, 75, 1, 3, 27, 25, 1, 128, 29, 4, 2
    #d8 (w_K_M_BAD >> 8) | 0x80, w_K_M_BAD & 0xFF, 2, 160, 75, (w_D0_EQ_ >> 8) | 0x80, w_D0_EQ_ & 0xFF, 4, 6, 1, 0, 2
    #d8 184, 75, 26, 0
p_scan:
    ld   [DSP], x               ; TOS = n, W1:W0 = a
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
pscn_lp:
    ld   [TL], ac
    or   [TH], ac
    beq  pscn_done
    ld   [W1], y
    ld   [W0], x
    ld   [y,x], ac
    xor  10, ac
    beq  pscn_done
    ld   [W0], ac
    inc
    ld   ac, [W0]
    bne  pscn_1
    ld   [W1], ac
    inc
    ld   ac, [W1]
pscn_1:
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  pscn_lp
    ld   [TH], ac
    dec
    ld   ac, [TH]
    bra  pscn_lp
pscn_done:
    ld   [W0], ac
    ld   ac, [TL]
    ld   [W1], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next

; R0-R7 as set
p_sys:
    ld   [TL], ac
    ld   ac, [W0]
    ld   [TH], ac
    ld   ac, [W1]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   LINK_LO, x
    ld   sy_back, [x]
    ld   LINK_HI, x
    ld   sy_back >> 8, [x]
    ld   [TL], ac
    ld   [W1], y
    jmp  [W0]
sy_back:
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next

; ============================================================
; EMIT ( c -- )  HFILL ( c n -- )  GTYPE ( a n -- )
; Characters at the cell GX, GY, GX moving on; nothing is drawn outside
; the clip rectangle.  GTYPE's characters are XORed with INV.
; ============================================================
p_emit:
    ld   [TL], ac
    ld   ac, [N_CH]
    ld   1, ac
    ld   ac, [N_CNT]
    clr  ac
    ld   ac, [N_MODE]
    ld   DRV_CELLS >> 8, y
    jmp  DRV_CELLS
p_hfill:
    ld   [TL], ac
    ld   ac, [N_CNT]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [TL], ac
    ld   ac, [N_CH]
    clr  ac
    ld   ac, [N_MODE]
    ld   DRV_CELLS >> 8, y
    jmp  DRV_CELLS
p_gtype:
    ld   [TL], ac
    ld   ac, [N_CNT]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [TL], ac
    ld   ac, [N_PL]
    ld   [TH], ac
    ld   ac, [N_PH]
    ld   1, ac
    ld   ac, [N_MODE]
    ld   DRV_CELLS >> 8, y
    jmp  DRV_CELLS

w_U_GT_S:
    #d8 2, 128, 75, 1, 6, 27, 2, 136, 75, 24, 1, 10
    #d8 43, 14, 1, 48, 27, 2, 136, 75, 23, 34, 12, 2
    #d8 136, 75, 24, 26, 12, 40, 4, 234, 13, 2, 136, 75
    #d8 23, 2, 128, 75, 1, 6, 27, 15, 28, 0
p_ptr:
    ld   [TL], ac
    ld   ac, [W2]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [W2], ac
    beq  pp_h
    ld   LINK_LO, x             ; CALL DRV_SHOW
    ld   pb_r2, [x]
    ld   LINK_HI, x
    ld   pb_r2 >> 8, [x]
    ld   DRV_SHOW >> 8, y
    jmp  DRV_SHOW
pb_r2:
    ld   next >> 8, y
    jmp  next
pp_h:
    ld   LINK_LO, x             ; CALL DRV_HIDE
    ld   pb_r3, [x]
    ld   LINK_HI, x
    ld   pb_r3 >> 8, [x]
    ld   DRV_HIDE >> 8, y
    jmp  DRV_HIDE
pb_r3:
    ld   next >> 8, y
    jmp  next

; ============================================================
; POLL ( -- key ): waits for the next frame, then the keyboard and the
; mouse: the pointer moves with it (PX, PY, and on the screen when it is
; shown), MOVED = 1 when the mouse sent something (MOUSE_B has its
; buttons); key = the key pressed or 0
; ============================================================
p_poll:
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   pb_r4, [x]
    ld   LINK_HI, x
    ld   pb_r4 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
pb_r4:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   pb_r5, [x]
    ld   LINK_HI, x
    ld   pb_r5 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
pb_r5:
    ld   [MOK], ac
    bne  pl_k
    ld   LINK_LO, x             ; CALL mouse_poll
    ld   pb_r6, [x]
    ld   LINK_HI, x
    ld   pb_r6 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
pb_r6:
    beq  pl_k
    ld   [PXL], ac
    ld   ac, [R0]
    ld   [PXH], ac
    ld   ac, [R1]
    ld   [PYL], ac
    ld   ac, [R2]
    ld   [PYH], ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL mouse_move
    ld   pb_r7, [x]
    ld   LINK_HI, x
    ld   pb_r7 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
pb_r7:
    ld   1, ac
    ld   ac, [MOVED]
    ld   [SH_ON], ac
    ld   ac, [W2]
    ld   LINK_LO, x             ; CALL DRV_HIDE
    ld   pb_r8, [x]
    ld   LINK_HI, x
    ld   pb_r8 >> 8, [x]
    ld   DRV_HIDE >> 8, y
    jmp  DRV_HIDE
pb_r8:
    ld   [R0], ac
    ld   ac, [PXL]
    ld   [R1], ac
    ld   ac, [PXH]
    ld   [R2], ac
    ld   ac, [PYL]
    ld   [R3], ac
    ld   ac, [PYH]
    ld   [W2], ac
    beq  pl_k
    ld   LINK_LO, x             ; CALL DRV_SHOW
    ld   pb_r9, [x]
    ld   LINK_HI, x
    ld   pb_r9 >> 8, [x]
    ld   DRV_SHOW >> 8, y
    jmp  DRV_SHOW
pb_r9:
pl_k:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   pb_r10, [x]
    ld   LINK_HI, x
    ld   pb_r10 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
pb_r10:
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next

; ============================================================
; made by vmc.py from pinboard.vm: change that file
; ============================================================

VM_P_EXIT = 0
VM_P_LIT8 = 1
VM_P_LIT16 = 2
VM_P_BR = 3
VM_P_0BR = 4
VM_P_LBR = 5
VM_P_L0BR = 6
VM_P_SLIT = 7
VM_P_ZPAT = 8
VM_P_ZPST = 9
VM_P_ZPCAT = 10
VM_P_ZPCST = 11
VM_P_DUP = 12
VM_P_DROP = 13
VM_P_SWAP = 14
VM_P_OVER = 15
VM_P_NIP = 16
VM_P_ROT = 17
VM_P_2DUP = 18
VM_P_TOR = 19
VM_P_RFROM = 20
VM_P_RAT = 21
VM_P_RDROP = 22
VM_P_AT = 23
VM_P_STORE = 24
VM_P_CAT = 25
VM_P_CSTORE = 26
VM_P_ADD = 27
VM_P_SUB = 28
VM_P_AND = 29
VM_P_OR = 30
VM_P_XOR = 31
VM_P_INVERT = 32
VM_P_INC = 33
VM_P_DEC = 34
VM_P_2MUL = 35
VM_P_2DIV = 36
VM_P_EQ = 37
VM_P_ULT = 38
VM_P_LT = 39
VM_P_0EQ = 40
VM_P_0LT = 41
VM_P_MUL = 42
VM_P_UMOD = 43
VM_P_EXECUTE = 44
VM_P_CMOVE = 45
VM_P_CMOVEU = 46
VM_P_FILL = 47
VM_P_SYS = 48
VM_P_EMIT = 49
VM_P_HFILL = 50
VM_P_GTYPE = 51
VM_P_INVC = 52
VM_P_PTR = 53
VM_P_POLL = 54
VM_P_SCAN = 55

w_A_M_DRAW:
    #d8 1, 1, 1, 2, (w_AT >> 8) | 0x80, w_AT & 0xFF, 7, 8, 80, 73, 78, 66
    #d8 79, 65, 82, 68, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 1, 1, 1, 4, (w_AT >> 8) | 0x80, w_AT & 0xFF
    #d8 7, 35, 65, 32, 100, 101, 115, 107, 116, 111, 112, 32
    #d8 102, 111, 114, 32, 116, 104, 101, 32, 80, 76, 65, 67
    #d8 65, 82, 68, 32, 99, 111, 109, 112, 117, 116, 101, 114
    #d8 58, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 1, 1, 1, 5, (w_AT >> 8) | 0x80, w_AT & 0xFF, 7, 24, 99
    #d8 97, 114, 100, 115, 32, 112, 105, 110, 110, 101, 100, 32
    #d8 111, 110, 32, 97, 32, 98, 111, 97, 114, 100, 46, (w_TYPE >> 8) | 0x80
    #d8 w_TYPE & 0xFF, 1, 1, 1, 7, (w_AT >> 8) | 0x80, w_AT & 0xFF, 7, 35, 77, 111, 117
    #d8 115, 101, 32, 32, 100, 114, 97, 103, 32, 97, 32, 116
    #d8 105, 116, 108, 101, 32, 116, 111, 32, 109, 111, 118, 101
    #d8 32, 97, 32, 99, 97, 114, 100, 44, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 1, 1
    #d8 1, 8, (w_AT >> 8) | 0x80, w_AT & 0xFF, 7, 36, 32, 32, 32, 32, 32, 32
    #d8 32, 99, 108, 105, 99, 107, 32, 105, 116, 115, 32, 112
    #d8 105, 110, 32, 116, 111, 32, 116, 97, 107, 101, 32, 105
    #d8 116, 32, 100, 111, 119, 110, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 1, 1, 1, 9
    #d8 (w_AT >> 8) | 0x80, w_AT & 0xFF, 7, 38, 84, 97, 98, 32, 32, 32, 32, 116
    #d8 104, 101, 32, 110, 101, 120, 116, 32, 99, 97, 114, 100
    #d8 32, 32, 32, 32, 32, 69, 115, 99, 32, 32, 108, 97
    #d8 117, 110, 99, 104, 101, 114, (w_TYPE >> 8) | 0x80, w_TYPE & 0xFF, 1, 1, 1, 10
    #d8 (w_AT >> 8) | 0x80, w_AT & 0xFF, 7, 31, 67, 116, 114, 108, 43, 87, 32, 116
    #d8 97, 107, 101, 32, 116, 104, 101, 32, 102, 114, 111, 110
    #d8 116, 32, 99, 97, 114, 100, 32, 100, 111, 119, 110, (w_TYPE >> 8) | 0x80
    #d8 w_TYPE & 0xFF, 0
w_E_M_KEY:
    #d8 12, 1, 15, 37, 4, 4, 13, 5, w_E_M_SAVE & 0xFF, w_E_M_SAVE >> 8, 1, 0
    #d8 53, 1, 3, (w_SETW >> 8) | 0x80, w_SETW & 0xFF, (w_E_M_CUR >> 8) | 0x80, w_E_M_CUR & 0xFF, 1, 0, 2, 226, 75
    #d8 26, 1, 0, 2, 227, 75, 26, 1, 0, 2, 220, 75
    #d8 24, 12, 1, 14, 37, 4, 4, (w_E_M_CLEAR >> 8) | 0x80, w_E_M_CLEAR & 0xFF, 3, 6, 1
    #d8 0, 2, 225, 75, 26, 12, 1, 17, 37, 4, 2, (w_E_M_UPK >> 8) | 0x80
    #d8 w_E_M_UPK & 0xFF, 12, 1, 18, 37, 4, 2, (w_E_M_DOWNK >> 8) | 0x80, w_E_M_DOWNK & 0xFF, 12, 1, 20
    #d8 37, 4, 2, (w_E_M_RIGHTK >> 8) | 0x80, w_E_M_RIGHTK & 0xFF, 12, 1, 19, 37, 4, 2, (w_E_M_LEFTK >> 8) | 0x80
    #d8 w_E_M_LEFTK & 0xFF, 12, 1, 21, 37, 4, 8, 2, 214, 75, 23, 2
    #d8 210, 75, 24, 12, 1, 5, 37, 4, 10, 2, 210, 75
    #d8 23, (w_E_M_EOL >> 8) | 0x80, w_E_M_EOL & 0xFF, 2, 210, 75, 24, 12, 1, 8, 37, 4
    #d8 2, (w_E_M_BKSP >> 8) | 0x80, w_E_M_BKSP & 0xFF, 12, 1, 127, 37, 4, 2, (w_E_M_DEL >> 8) | 0x80, w_E_M_DEL & 0xFF, 12
    #d8 1, 10, 37, 15, 1, 32, 28, 1, 95, 38, 30, 4
    #d8 3, 12, (w_E_M_INS >> 8) | 0x80, w_E_M_INS & 0xFF, 13, (w_E_M_HS >> 8) | 0x80, w_E_M_HS & 0xFF, 2, 226, 75, 25, 4
    #d8 4, (w_E_M_TEXT >> 8) | 0x80, w_E_M_TEXT & 0xFF, 3, 17, 2, 227, 75, 25, 4, 11, 2
    #d8 214, 75, 23, 2, 222, 75, 25, (w_E_M_LINE >> 8) | 0x80, w_E_M_LINE & 0xFF, 13, (w_E_M_INFO >> 8) | 0x80, w_E_M_INFO & 0xFF
    #d8 (w_E_M_CUR >> 8) | 0x80, w_E_M_CUR & 0xFF, 1, 1, 53, 0
w_K_M_DO:
    #d8 12, 1, 99, 37, 4, 6, 13, (w_K_M_CLR >> 8) | 0x80, w_K_M_CLR & 0xFF, 5, w_K_M_SHOW & 0xFF, w_K_M_SHOW >> 8
    #d8 2, 188, 75, 25, 4, 2, 13, 0, 12, 1, 48, 28
    #d8 1, 10, 38, 4, 8, 1, 48, 28, (w_K_M_DIG >> 8) | 0x80, w_K_M_DIG & 0xFF, 5, w_K_M_SHOW & 0xFF
    #d8 w_K_M_SHOW >> 8, 12, 1, 122, 37, 4, 20, 13, 2, 187, 75, 25
    #d8 40, 4, 11, 1, 0, (w_K_M_DIG >> 8) | 0x80, w_K_M_DIG & 0xFF, 1, 0, (w_K_M_DIG >> 8) | 0x80, w_K_M_DIG & 0xFF, 5
    #d8 w_K_M_SHOW & 0xFF, w_K_M_SHOW >> 8, 0, 12, 1, 8, 37, 4, 30, 13, 2, 187
    #d8 75, 25, 40, 4, 21, 2, 164, 75, (w_D_S_10_ST_ >> 8) | 0x80, w_D_S_10_ST_ & 0xFF, 13, 2
    #d8 189, 75, 25, 12, 4, 1, 34, 2, 189, 75, 26, 5
    #d8 w_K_M_SHOW & 0xFF, w_K_M_SHOW >> 8, 0, 12, 1, 110, 37, 4, 25, 13, 2, 187
    #d8 75, 25, 4, 5, 2, 184, 75, 3, 3, 2, 185, 75
    #d8 12, 25, 1, 1, 31, 14, 26, 5, w_K_M_SHOW & 0xFF, w_K_M_SHOW >> 8, 12, 1
    #d8 61, 37, 4, 12, 13, (w_K_M_COMMIT >> 8) | 0x80, w_K_M_COMMIT & 0xFF, 1, 0, 2, 186, 75
    #d8 26, 5, w_K_M_SHOW & 0xFF, w_K_M_SHOW >> 8, 12, 1, 43, 37, 15, 1, 45, 37
    #d8 30, 15, 1, 42, 37, 30, 15, 1, 47, 37, 30, 15
    #d8 1, 109, 37, 30, 4, 9, (w_K_M_COMMIT >> 8) | 0x80, w_K_M_COMMIT & 0xFF, 2, 186, 75, 26
    #d8 5, w_K_M_SHOW & 0xFF, w_K_M_SHOW >> 8, 13, 0
w_F_M_ROW:
    #d8 12, 2, 146, 75, 25, 28, 12, (w_F_M_ROWS >> 8) | 0x80, w_F_M_ROWS & 0xFF, 38, 40, 4
    #d8 3, 13, 13, 0, 1, 1, 14, 1, 2, 27, (w_AT >> 8) | 0x80, w_AT & 0xFF
    #d8 12, 2, 145, 75, 25, 37, 12, 19, 4, 8, (w_REV >> 8) | 0x80, w_REV & 0xFF
    #d8 1, 3, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 3, 2, (w_INK >> 8) | 0x80, w_INK & 0xFF, 12, 2, 144, 75
    #d8 25, 39, 40, 4, 14, 13, 10, 147, 1, 4, 28, (w_SPACES >> 8) | 0x80
    #d8 w_SPACES & 0xFF, 22, 1, 0, 5, w_PEN & 0xFF, w_PEN >> 8, (w_ENT >> 8) | 0x80, w_ENT & 0xFF, 12, (w_DIR_Q_ >> 8) | 0x80, w_DIR_Q_ & 0xFF
    #d8 4, 4, 1, 11, 3, 11, 12, (w_PLC_Q_ >> 8) | 0x80, w_PLC_Q_ & 0xFF, 4, 4, 1
    #d8 12, 3, 2, 1, 13, 21, 40, 4, 6, 12, 1, 5
    #d8 27, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 12, 1, 13, 37, 4, 8, 15, (w_PIC_Q_ >> 8) | 0x80, w_PIC_Q_ & 0xFF
    #d8 4, 3, 13, 1, 18, (w_GLYPH >> 8) | 0x80, w_GLYPH & 0xFF, 20, 40, 4, 4, 1
    #d8 0, (w_PEN >> 8) | 0x80, w_PEN & 0xFF, 1, 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 12, (w_ENT_GT_NAME >> 8) | 0x80, w_ENT_GT_NAME & 0xFF, 2, 112
    #d8 75, 10, 155, 51, 1, 13, 10, 155, 28, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, (w_F_M_SIZE >> 8) | 0x80
    #d8 w_F_M_SIZE & 0xFF, 1, 1, (w_SPACES >> 8) | 0x80, w_SPACES & 0xFF, 1, 0, 5, w_PEN & 0xFF, w_PEN >> 8

; pinboard_drv_mono.asm - the display driver MONO.DRV, expanded (after the
; lines of pinboard.asm)
; ---DRIVER---

#include "pinboard_data_mono.asm"

; ============================================================
; EMIT, HFILL, GTYPE: N_CH or N_PH:N_PL, N_CNT and N_MODE are set
; ============================================================

#addr 0x2F00
d_cells:
    ld   [N_MODE], ac
    ld   LINK_LO, x             ; a long repaint: the frames are counted
    ld   pd_r1, [x]
    ld   LINK_HI, x
    ld   pd_r1 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
pd_r1:
    ld   LINK_LO, x             ; and the mouse's bytes taken as they come
    ld   pd_r2, [x]
    ld   LINK_HI, x
    ld   pd_r2 >> 8, [x]
    ld   ps2_poll >> 8, y
    jmp  ps2_poll
pd_r2:
    ld   [N_CNT], ac
    beq  pgs_out
    ld   [GY], ac
    sub  [CY0], ac
    bcs  pgs_out                 ; above the clip
    ld   [GY], ac
    sub  [CY1], ac
    bcc  pgs_out                 ; below it
    ld   [GY], ac               ; row 8 x GY + x20 of the column
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [VL0]
    inc
    ld   ac, [VL0 + 1]
    inc
    ld   ac, [VL0 + 2]
    inc
    ld   ac, [VL0 + 3]
    inc
    ld   ac, [VL0 + 4]
    inc
    ld   ac, [VL0 + 5]
    inc
    ld   ac, [VL0 + 6]
    inc
    ld   ac, [VL0 + 7]
    ld   [GY], ac
    sub  28, ac
    bcs  pgs_p0
    ld   0x61, ac
    bra  pgs_p
pgs_p0:
    ld   0x60, ac
pgs_p:
    ld   ac, [VPG]
    ld   pg_loop >> 8, y
    jmp  pg_loop
pgs_out:
    ld   [GX], ac
    add  [N_CNT], ac
    ld   ac, [GX]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next

d_invc:
    ld   [GX], ac
    sub  80, ac
    bcc  iv_x
    ld   [GY], ac
    sub  60, ac
    bcc  iv_x
    ld   [GY], ac
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [VL0]
    ld   [GY], ac
    sub  28, ac
    bcs  iv_p0
    ld   0x61, ac
    bra  iv_p
iv_p0:
    ld   0x60, ac
iv_p:
    ld   ac, [VPG]
    ld   [GX], ac
    shl
    add  [VPG], ac
    ld   ac, [VH]
    ld   0x50, y
    ld   0xFF, [y,x]
    ld   8, ac
    ld   ac, [N_CNT]
iv_l:
    ld   [VH], y
    ld   [VL0], x
    ld   [y,x], ac
    xor  0xFF, ac
    ld   ac, [y,x]
    ld   [VL0], ac
    inc
    ld   ac, [VL0]
    ld   [N_CNT], ac
    dec
    ld   ac, [N_CNT]
    bne  iv_l
    ld   0x50, y
    ld   MAP_RUN, [y,x]
iv_x:
    ld   next >> 8, y
    jmp  next

; ============================================================
; the pointer
; ============================================================

d_init:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   LINK_LO, x             ; CALL con_clear
    ld   pd_r3, [x]
    ld   LINK_HI, x
    ld   pd_r3 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
pd_r3:
    ld   0x5B, y                ; rows 456-479
    ld   23, ac
di_tint:
    add  0xE8, x
    ld   0x40, [y,x]
    sub  1, ac
    bcc  di_tint
    ld   lib_leave >> 8, y
    jmp  lib_leave

#addr 0x3000
pg_loop:
    ld   [N_MODE], ac
    beq  pg_ch
    ld   [N_PH], y
    ld   [N_PL], x
    ld   [y,x], ac
    xor  [INV], ac
    ld   ac, [N_CH]
    ld   [N_PL], ac
    inc
    ld   ac, [N_PL]
    bne  pg_ch
    ld   [N_PH], ac
    inc
    ld   ac, [N_PH]
pg_ch:
    ld   [GX], ac
    sub  [CX0], ac
    bcs  pg_skip
    ld   [GX], ac
    sub  [CX1], ac
    bcc  pg_skip
    ld   [GX], ac
    shl
    add  [VPG], ac
    ld   ac, [VH]
    ld   PB_FONT >> 8, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 1, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 1], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 2, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 2], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 3, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 3], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 4, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 4], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 5, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 5], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 6, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 6], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 7, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 7], x
    ld   ac, [y,x]
pg_skip:
    ld   [GX], ac
    inc
    ld   ac, [GX]
    ld   [N_CNT], ac
    dec
    ld   ac, [N_CNT]
    bne  pg_loop
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next

; ============================================================
; INVC ( -- ): the cell at GX, GY turned over (white <-> black).  The
; video RAM is read with every section mapped to RAM (this code is in the
; RAM below x4000, so it runs on).
; ============================================================
; T0-T3)
d_hide:
    ld   [SH_ON], ac
    beq  ph_x
    clr  ac
    ld   ac, [SH_ON]
    ld   ac, [T0]
ph_l:
    ld   [SH_YL], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [SH_YH], ac
    bcc  pra6
    inc
pra6:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb6
    inc
prb6:
    add  [SH_C2], ac
    ld   ac, [T2]
    ld   [T0], ac
    shl
    ld   ac, x
    ld   PSAVE >> 8, y
    ld   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [SH_K], ac
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
    xor  [SH_N], ac
    bne  ph_l
ph_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]


#addr 0x3100
; T0-T3)
d_show:
    ld   [SH_ON], ac
    bne  ps_x
    ld   [MOK], ac
    bne  ps_x                   ; no mouse: no pointer
    ld   1, ac
    ld   ac, [SH_ON]
    ld   [PXL], ac
    and  7, ac
    shl
    shl
    shl
    shl
    ld   ac, [SH_TI]
    ld   [PXL], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T3]
    ld   [PXH], ac
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
    ld   ac, [SH_K]
    ld   [T3], ac
    shl
    add  0x60, ac
    ld   ac, [SH_C2]
    ld   [PYL], ac
    ld   ac, [SH_YL]
    ld   [PYH], ac
    ld   ac, [SH_YH]
    ld   12, ac
    ld   ac, [SH_N]
    ld   [PYH], ac
    beq  ps_go
    ld   0xE0, ac               ; rows left to 480
    sub  [PYL], ac
    ld   ac, [T3]
    sub  12, ac
    bcc  ps_go
    ld   [T3], ac
    ld   ac, [SH_N]
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
    ld   [SH_YL], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [SH_YH], ac
    bcc  pra7
    inc
pra7:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb7
    inc
prb7:
    add  [SH_C2], ac
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
    ld   [SH_TI], ac
    or   [T0], ac
    ld   ac, x
    ld   PB_PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PB_PTR >> 8) + 1, y
    or   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [SH_K], ac
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
    ld   [SH_TI], ac
    or   [T0], ac
    or   0x80, x
    ld   PB_PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PB_PTR >> 8) + 1, y
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
    xor  [SH_N], ac
    bne  ps_l
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]


