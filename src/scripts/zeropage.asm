; ============================================================
; zeropage.asm - Placard zero page variable assignments
; ============================================================
;
; Every program that uses placard_lib.asm shares this map.  Include it
; first (placard_lib.asm includes it for you):
;
;     #include "placard.asm"
;     #include "placard_lib.asm"
;
; The zero page is x0000-x00FF.  It is reached with the short [0,D] and
; [0,X] modes, so it holds the variables that are used most.  Section 0
; (x0000-x1FFF) must read from RAM for these variables to work.
;
;   Address    Name          Owner     Use
;   ---------  ------------  --------  ------------------------------------
;   00-03      (reset)       program   reset code: ld main >> 8, y / jmp main
;   04         LINK_LO       call      return address low byte
;   05         LINK_HI       call      return address high byte
;   06         SP            stack     software stack pointer (next free byte)
;   07         MAP_SHADOW    map_set   copy of the write-only map register
;   08         FRAME_LO      frames    frame counter low byte
;   09         FRAME_HI      frames    frame counter high byte
;   0A         LINE_LAST     frames    last value read from the line read
;   0B         RAND_LO       rand8     random generator state, low byte
;   0C         RAND_HI       rand8     random generator state, high byte
;   0D         CUR_COL       console   cursor byte column, 0-79
;   0E         CUR_ROW       console   cursor text row, 0-59
;   0F         SAVE_AC       stack     AC parked by PUSH_LINK and lib_leave
;   10-17      R0-R7         caller    arguments and results
;   18-1F      T0-T7         library   scratch, any library routine may
;                                      change these
;   20-8F      (free)        program   112 bytes for the program's own
;                                      variables
;   90-9E      SND_*         sound     sound driver state (placard_snd.asm)
;   9F         (spare)       sound     kept for the sound driver
;   A0-A7      KBD_NOW       keyboard  rows of each column, 0 = key down
;   A8-AF      KBD_BUF       keyboard  key buffer, 8 characters
;   B0         KBD_HEAD      keyboard  next free place in KBD_BUF
;   B1         KBD_TAIL      keyboard  next character to take
;   B2         KBD_FLAGS     keyboard  bit 0 = caps lock
;   B3         IO_TMP        I/O       scratch for the I/O drivers
;   B4         SD_FLAGS      SD card   bit 0 = block addresses, bit 1 =
;                                      slow clock, bit 7 = ready
;   B5         MOUSE_B       mouse     buttons and flags of the last packet
;   B6         MOUSE_DX      mouse     X movement of the last packet
;   B7         MOUSE_DY      mouse     Y movement of the last packet
;   B8         MOUSE_ST      mouse     bit 7 = the mouse is running
;   B9-BC      IO_T0-IO_T3   I/O       scratch for the I/O drivers
;   BD-BF      (spare)       I/O       kept for the I/O drivers
;   C0-FF      STACK         stack     software stack, 64 bytes, grows down
;                                      from FF
;
; Rules
;   - R0-R7 belong to the caller.  A routine changes only the R registers
;     its documentation lists as outputs or as changed.
;   - T0-T7 are scratch.  Any library routine may change any of them, so
;     never keep a value in a T register across a call.
;   - Program variables go in 20-8F.  Add them to the program, not here,
;     unless every program needs them.  A0-BF belong to the I/O drivers
;     (placard_io.asm) and 90-9F to the sound driver (placard_snd.asm);
;     a program that never calls them may use those bytes too.
;   - The stack may grow down past C0 into the program area if a program
;     nests deeper than 64 bytes; nothing checks for that.
;
; Date: 10/18/2026
; ============================================================

LINK_LO    = 0x04
LINK_HI    = 0x05
SP         = 0x06
MAP_SHADOW = 0x07
FRAME_LO   = 0x08
FRAME_HI   = 0x09
LINE_LAST  = 0x0A
RAND_LO    = 0x0B
RAND_HI    = 0x0C
CUR_COL    = 0x0D
CUR_ROW    = 0x0E
SAVE_AC    = 0x0F

R0 = 0x10
R1 = 0x11
R2 = 0x12
R3 = 0x13
R4 = 0x14
R5 = 0x15
R6 = 0x16
R7 = 0x17

T0 = 0x18
T1 = 0x19
T2 = 0x1A
T3 = 0x1B
T4 = 0x1C
T5 = 0x1D
T6 = 0x1E
T7 = 0x1F

KBD_NOW    = 0xA0       ; A0-A7
KBD_BUF    = 0xA8       ; A8-AF
KBD_HEAD   = 0xB0
KBD_TAIL   = 0xB1
KBD_FLAGS  = 0xB2
IO_TMP     = 0xB3
SD_FLAGS   = 0xB4
MOUSE_B    = 0xB5
MOUSE_DX   = 0xB6
MOUSE_DY   = 0xB7
MOUSE_ST   = 0xB8
IO_T0      = 0xB9
IO_T1      = 0xBA
IO_T2      = 0xBB
IO_T3      = 0xBC

SND_ZP     = 0x90       ; first byte of the sound driver's variables
SND_PL     = 0x90       ; next buffer byte to write, low
SND_PH     = 0x91       ; and high
SND_VEC    = 0x92       ; low byte of the sample maker for the sound playing
SND_ACL    = 0x93       ; phase, low 7 bits (tone, noise, sample)
SND_ACH    = 0x94       ; phase high byte; noise: LFSR high; sample: source low
SND_INL    = 0x95       ; step, low 7 bits; sample: rate
SND_INH    = 0x96       ; step high byte; noise: LFSR low; sample: source high
SND_HIGH   = 0x97       ; level when the wave is high, 80h + volume
SND_LOW    = 0x98       ; level when the wave is low, 80h - volume
SND_VOL    = 0x99       ; volume, 0-127
SND_DECAY  = 0x9A       ; volume taken off every frame
SND_FRAMES = 0x9B       ; frames left, 0 = until stopped
SND_LENL   = 0x9C       ; sample: bytes left, low
SND_LENH   = 0x9D       ; and high
SND_CLEAN  = 0x9E       ; silent buffer laps, 2 = the buffer is all 80h

USER_ZP    = 0x20       ; first free byte for program variables
IO_ZP      = 0xA0       ; first byte of the I/O drivers' variables
STACK_LOW  = 0xC0       ; lowest stack byte
STACK_TOP  = 0xFF       ; SP starts here
