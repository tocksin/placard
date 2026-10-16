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
;   20-BF      (free)        program   160 bytes for the program's own
;                                      variables
;   C0-FF      STACK         stack     software stack, 64 bytes, grows down
;                                      from FF
;
; Rules
;   - R0-R7 belong to the caller.  A routine changes only the R registers
;     its documentation lists as outputs or as changed.
;   - T0-T7 are scratch.  Any library routine may change any of them, so
;     never keep a value in a T register across a call.
;   - Program variables go in 20-BF.  Add them to the program, not here,
;     unless every program needs them.
;   - The stack may grow down past C0 into the program area if a program
;     nests deeper than 64 bytes; nothing checks for that.
;
; Date: 10/16/2026
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

USER_ZP    = 0x20       ; first free byte for program variables
STACK_LOW  = 0xC0       ; lowest stack byte
STACK_TOP  = 0xFF       ; SP starts here
