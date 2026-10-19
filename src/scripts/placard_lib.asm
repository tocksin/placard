; ============================================================
; placard_lib.asm - Placard standard library
; ============================================================
;
; Subroutines for Placard programs: calls and a software stack, 16-bit
; and multiply / divide arithmetic, memory fill and copy, random numbers,
; frame timing, pixels and a text console.  docs/LIBRARY.md documents every
; routine; each routine's header below lists the same facts.
;
; USE
;     #include "placard.asm"
;     #include "placard_lib.asm"      ; also includes zeropage.asm
;
;     #addr 0x6000                    ; a ROM program (docs/ROM.md)
;     main:
;         ld   STACK_TOP, ac         ; set up the stack first
;         ld   ac, [SP]
;         ...
;
; The library is one block at the top of the ROM, xC600-xFBFF (sections 6
; and 7), below the boot loader, with the most used parts highest:
;     xFB00-xFBFF  LIB_JT      jump table
;     xF400-xFAFF  LIB_CODE    core routines (this file)
;     xEC00-xF3FF  LIB_FONT    8x8 font (lib_font.asm)
;     xDC00-xEBFF  IO_CODE     I/O drivers (placard_io.asm)
;     xD700-xDBFF  SND_CODE    sound driver (placard_snd.asm)
;     xD500-xD6FF  INPUT_CODE  line input, mouse pointer (placard_input.asm)
;     xC700-xD4FF  FS_CODE     FAT file reader (placard_fs.asm)
;     xC600-xC6FF  SLOT_CODE   expansion slot helpers (placard_slot.asm)
; xC000-xC5FF is kept free for the library to grow down into.  It runs in
; place from the ROM, so sections 6 and 7 must read ROM whenever a program
; calls the library.  These are standard places that every program shares,
; so keep them; moving them means changing gen_rom.tcl and placard_sim.py
; too (docs/ROM.md).  Every base is a multiple of 0x100, because every
; routine keeps its branches inside one 256-byte page.
;
; JUMP TABLE: LIB_JT (xFB00-xFBFF) holds one 4-byte entry per public
; routine (ld routine >> 8, y / jmp routine), in a fixed order that only
; ever grows, so code built without this file (a card's boot code, a
; program loaded from the SD card) can CALL a routine at its table address
; (jt_<name>) even after the library changes.  Code that includes this file
; may call the routines directly (4 clocks faster).  docs/LIBRARY.md lists
; the entries.
;
; LIB_RAM: the code that reads the video RAM (the end of plot1 and all of
; con_scroll) maps sections 3-7 to RAM while it runs, which would take the
; ROM it runs from away.  So it is assembled at LIB_RAM, x1F00-x1FFF (in
; section 0, which is RAM in every map a program uses), and the boot loader
; copies those bytes from the ROM into the RAM before anything else.
; Programs must leave RAM x1F00-x1FFF alone.
;
; ------------------------------------------------------------
; CALLING CONVENTION
; ------------------------------------------------------------
; There is no call instruction.  The caller puts the return address in
; LINK_LO / LINK_HI and jumps; the routine returns with an indirect jump.
;
;   CALL (6 instructions, 12 bytes, 18 clocks; AC kept, X and Y changed)
;         ld   LINK_LO, x
;         ld   back, [x]            ; return address low byte
;         ld   LINK_HI, x
;         ld   back >> 8, [x]       ; return address high byte
;         ld   routine >> 8, y
;         jmp  routine
;     back:                         ; every call needs its own label
;
;   RETURN from a routine that makes no calls (a leaf), 2 instructions,
;   8 clocks, AC and X kept:
;         ld   [LINK_HI], y
;         jmp  [LINK_LO]
;
;   Arguments go in AC and R0-R7; results come back in AC, X and R0-R7.
;   Y can never carry a result, because the return jump loads it.
;
; ------------------------------------------------------------
; SOFTWARE STACK
; ------------------------------------------------------------
; The stack is in the zero page, STACK_LOW-STACK_TOP (xC0-xFF).  SP holds
; the address of the next free byte and the stack grows down.  Set it up
; once at the start of the program:
;         ld   STACK_TOP, ac
;         ld   ac, [SP]
;
;   PUSH AC (6 instructions, 19 clocks; AC kept, X changed)
;         ld   [SP], x
;         ld   ac, [x]
;         ld   x, ac
;         dec
;         ld   ac, [SP]
;         ld   [x], ac
;
;   POP AC (5 instructions, 16 clocks; X changed, the N/Z test on AC works
;   straight after it)
;         ld   [SP], ac
;         inc
;         ld   ac, [SP]
;         ld   ac, x
;         ld   [x], ac
;
;   To push X, copy it first (ld x, ac) and push AC.
;
; A routine that calls another routine (not a leaf) must save its own
; return address on the stack first, because the inner CALL overwrites
; LINK.  It starts with PUSH_LINK and ends by jumping to lib_leave:
;
;   PUSH_LINK (13 instructions, 42 clocks; AC kept, X changed)
;         ld   ac, [SAVE_AC]
;         ld   [SP], x
;         ld   [LINK_HI], ac
;         ld   ac, [x]
;         ld   x, ac
;         dec
;         ld   ac, x
;         ld   [LINK_LO], ac
;         ld   ac, [x]
;         ld   x, ac
;         dec
;         ld   ac, [SP]
;         ld   [SAVE_AC], ac
;
;   LEAVE (pops the return address and returns, 49 clocks; AC kept, X
;   changed)
;         ld   lib_leave >> 8, y
;         jmp  lib_leave
;
; Anything pushed inside the routine must be popped before LEAVE.
;
; ------------------------------------------------------------
; REGISTERS AND ZERO PAGE
; ------------------------------------------------------------
; R0-R7 belong to the caller: a routine changes only the ones it lists.
; T0-T7 are scratch for every routine: never keep a value there across a
; call.  X and Y are changed by every CALL.  See zeropage.asm for the map.
;
; Clock counts assume no video stalls (the CPU loses 1 clock in 8 during
; active video) and include the 8-clock RETURN but not the 18-clock CALL.
; test_lib.py measures them.
;
; Date: 10/19/2026
; ============================================================

#include "zeropage.asm"

LIB_JT     = 0xFB00     ; jump table, 64 entries, xFB00-xFBFF
LIB_CODE   = 0xF400     ; core routines, xF400-xFAFF
LIB_FONT   = 0xEC00     ; 2 KB font, xEC00-xF3FF (see lib_font.asm)
IO_CODE    = 0xDC00     ; I/O drivers, xDC00-xEBFF (placard_io.asm)
SND_CODE   = 0xD700     ; sound driver, xD700-xDBFF (placard_snd.asm)
INPUT_CODE = 0xD500     ; line input, mouse pointer, xD500-xD6FF (placard_input.asm)
FS_CODE    = 0xC700     ; FAT file reader, xC700-xD4FF (placard_fs.asm)
SLOT_CODE  = 0xC600     ; expansion slot helpers, xC600-xC6FF (placard_slot.asm)
LIB_RAM    = 0x1F00     ; 256 bytes of library code copied to RAM by the boot

#include "lib_font.asm"
#include "placard_io.asm"     ; I/O drivers at IO_CODE (docs/IO.md)
#include "placard_snd.asm"    ; sound driver at SND_CODE (docs/SOUND.md)
#include "placard_slot.asm"   ; expansion slot helpers at SLOT_CODE (docs/EXPANSION.md)
#include "placard_fs.asm"     ; FAT file reading at FS_CODE (docs/IO.md)
#include "placard_input.asm"  ; line input, mouse pointer at INPUT_CODE (docs/IO.md)


; ============================================================
; Page 0: stack exit, video address, map register, frames, random
; ============================================================
#addr LIB_CODE

; ------------------------------------------------------------
; lib_leave - end of a non-leaf routine: pop the return address that
; PUSH_LINK saved and return there.  Reach it with a jump, not a CALL:
;         ld   lib_leave >> 8, y
;         jmp  lib_leave
;   in:      the stack top holds the return address (from PUSH_LINK)
;   out:     AC unchanged
;   changes: X, Y, LINK_LO, LINK_HI, SAVE_AC, SP (+2)
;   clocks:  49, including the jump to lib_leave
; ------------------------------------------------------------
lib_leave:
    ld   ac, [SAVE_AC]
    ld   [SP], ac
    inc
    ld   ac, x
    ld   [x], ac
    ld   ac, [LINK_LO]
    ld   x, ac
    inc
    ld   ac, x
    ld   ac, [SP]
    ld   [x], ac
    ld   ac, y
    ld   [SAVE_AC], ac
    jmp  [LINK_LO]

; ------------------------------------------------------------
; map_set - write the ROM/RAM map register (x5000) and its copy
;   in:      AC = map, bit n = 1 reads section n from RAM
;   out:     MAP_SHADOW = AC
;   changes: Y
;   clocks:  18
;   The return jump is the first fetch after the write, so the caller's
;   section must read the same byte from ROM and RAM, or keep its map bit
;   (README.md, memory map).
; ------------------------------------------------------------
map_set:
    ld   ac, [MAP_SHADOW]
    ld   0x50, y
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; frame_poll - read the video line and count frames
;   in:      -
;   out:     AC = line read value (V9:V2, 124-255; 136-255 visible)
;            FRAME_HI:FRAME_LO + 1 if a new frame started since the last
;            poll; LINE_LAST = AC
;   changes: X, Y, T0
;   clocks:  39-53
;   Call it at least once per frame (16.8 ms), or frames are missed.
; ------------------------------------------------------------
frame_poll:
    ld   0x50, y
    ld   [y,x], ac
    ld   ac, [T0]
    xor  [LINE_LAST], ac
    blt  fp_diff
    ld   [T0], ac               ; same top bit: the difference has the sign
    sub  [LINE_LAST], ac
    blt  fp_tick
    bra  fp_same
fp_diff:
    ld   [T0], ac               ; top bits differ: new < last if new < 128
    blt  fp_same
fp_tick:
    ld   [FRAME_LO], ac
    inc
    ld   ac, [FRAME_LO]
    bne  fp_same
    ld   [FRAME_HI], ac
    inc
    ld   ac, [FRAME_HI]
fp_same:
    ld   [T0], ac
    ld   ac, [LINE_LAST]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; wait_frames - wait until AC new frames have started
;   in:      AC = frames, 1-255 (0 waits 256)
;   out:     FRAME_HI:FRAME_LO + AC, LINE_LAST = the last line read
;   changes: AC, X, Y, T0, T1
;   clocks:  AC frames (the first may be partly over: the wait is
;            between AC - 1 and AC frames)
; ------------------------------------------------------------
wait_frames:
    ld   ac, [T1]
    ld   0x50, y
    ld   [y,x], ac
    ld   ac, [LINE_LAST]        ; start from the line now
wf_loop:
    ld   [y,x], ac
    ld   ac, [T0]
    xor  [LINE_LAST], ac
    blt  wf_diff
    ld   [T0], ac
    sub  [LINE_LAST], ac
    blt  wf_tick
    bra  wf_same
wf_diff:
    ld   [T0], ac
    blt  wf_same
wf_tick:
    ld   [T0], ac
    ld   ac, [LINE_LAST]
    ld   [FRAME_LO], ac
    inc
    ld   ac, [FRAME_LO]
    bne  wf_count
    ld   [FRAME_HI], ac
    inc
    ld   ac, [FRAME_HI]
wf_count:
    ld   [T1], ac
    dec
    ld   ac, [T1]
    bne  wf_loop
    ld   [LINK_HI], y
    jmp  [LINK_LO]
wf_same:
    ld   [T0], ac
    ld   ac, [LINE_LAST]
    bra  wf_loop

; ------------------------------------------------------------
; rand8 - next random number (xorshift16, period 65535)
;   in:      RAND_HI:RAND_LO = state, not both 0 (seed it once)
;   out:     AC = random byte (the new RAND_LO), state stepped
;   changes: T0
;   clocks:  73-93
;   x ^= x << 7;  x ^= x >> 9;  x ^= x << 8
; ------------------------------------------------------------
rand8:
    ld   [RAND_LO], ac
    shr  ac
    ld   ac, [T0]               ; t = x << 7, high byte = hi bit 0 : lo >> 1
    ld   [RAND_HI], ac
    and  1, ac
    beq  rn_1
    ld   [T0], ac
    or   0x80, ac
    ld   ac, [T0]
rn_1:
    ld   [RAND_HI], ac
    xor  [T0], ac
    ld   ac, [RAND_HI]
    ld   [RAND_LO], ac          ; low byte of x << 7 = lo bit 0 << 7
    and  1, ac
    beq  rn_2
    ld   [RAND_LO], ac
    xor  0x80, ac
    ld   ac, [RAND_LO]
rn_2:
    ld   [RAND_HI], ac          ; x ^= x >> 9
    shr  ac
    xor  [RAND_LO], ac
    ld   ac, [RAND_LO]
    xor  [RAND_HI], ac          ; x ^= x << 8
    ld   ac, [RAND_HI]
    ld   [RAND_LO], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; tables
; ------------------------------------------------------------
lib_bits:       ; 1 << n
    #d8 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
lib_hex:        ; "0123456789ABCDEF"
    #d8 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37
    #d8 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46


; ============================================================
; Page 1: 16-bit add and subtract, 8 x 8 multiply, memory fill
; ============================================================
#addr LIB_CODE + 0x100

; ------------------------------------------------------------
; add16 - 16-bit add
;   in:      R1:R0 = a, R3:R2 = b
;   out:     R1:R0 = a + b (mod 65536), AC = R1
;   changes: nothing else
;   clocks:  36-40
; ------------------------------------------------------------
add16:
    ld   [R0], ac
    add  [R2], ac
    ld   ac, [R0]
    ld   [R1], ac
    bcc  a16_n                  ; the carry out of the low byte
    inc
a16_n:
    add  [R3], ac
    ld   ac, [R1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

#addr LIB_CODE + 0x134            ; entry addresses stay fixed (carry flag rewrite left a gap)

; ------------------------------------------------------------
; sub16 - 16-bit subtract
;   in:      R1:R0 = a, R3:R2 = b
;   out:     R1:R0 = a - b (mod 65536), AC = R1
;   changes: nothing else
;   clocks:  36-40
; ------------------------------------------------------------
sub16:
    ld   [R0], ac
    sub  [R2], ac
    ld   ac, [R0]
    ld   [R1], ac
    bcc  s16_n                  ; the borrow out of the low byte
    dec
s16_n:
    sub  [R3], ac
    ld   ac, [R1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

#addr LIB_CODE + 0x16C            ; entry addresses stay fixed (carry flag rewrite left a gap)

; ------------------------------------------------------------
; mul8 - 8 x 8 bit unsigned multiply
;   in:      R0 = a, R1 = b
;   out:     R3:R2 = a * b, AC = R3
;   changes: T0, T1
;   clocks:  476-719 (476 + about 12-30 per 1 bit in b)
; ------------------------------------------------------------
mul8:
    clr  ac
    ld   ac, [R2]
    ld   ac, [R3]
    ld   [R1], ac
    ld   ac, [T0]               ; multiplier, read from bit 7 down
    ld   8, ac
    ld   ac, [T1]
m8_loop:
    ld   [R3], ac               ; product <<= 1
    shl
    ld   ac, [R3]
    ld   [R2], ac
    shl                         ; carry = bit 7 of the low byte
    ld   ac, [R2]
    bcc  m8_s
    ld   [R3], ac
    or   1, ac
    ld   ac, [R3]
m8_s:
    ld   [T0], ac               ; next multiplier bit
    blt  m8_add
    shl
    ld   ac, [T0]
    bra  m8_next
m8_add:
    shl
    ld   ac, [T0]
    ld   [R2], ac               ; product += a
    add  [R0], ac
    ld   ac, [R2]
    bcc  m8_next                ; the carry flag from the add
    ld   [R3], ac
    inc
    ld   ac, [R3]
m8_next:
    ld   [T1], ac
    dec
    ld   ac, [T1]
    bne  m8_loop
    ld   [R3], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; memset - fill memory with a byte
;   in:      AC = value, R1:R0 = address, R2 = count (0 = 256)
;   out:     R1:R0 = address + count, R2 = 0
;   changes: X, Y, T0
;   clocks:  12 + 41 per byte
;   Any address, including the I/O window, so be careful with x5000.
; ------------------------------------------------------------
#addr LIB_CODE + 0x1C7            ; entry addresses stay fixed (carry flag rewrite left a gap)
memset:
    ld   ac, [T0]
ms_loop:
    ld   [R0], x
    ld   [R1], y
    ld   [T0], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [R0]
    bne  ms_nc
    ld   [R1], ac
    inc
    ld   ac, [R1]
ms_nc:
    ld   [R2], ac
    dec
    ld   ac, [R2]
    bne  ms_loop
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page 2: divide, memory copy
; ============================================================
#addr LIB_CODE + 0x200

; ------------------------------------------------------------
; div8 - 8 / 8 bit unsigned divide
;   in:      R0 = dividend, R1 = divisor (not 0)
;   out:     AC = quotient, X = remainder
;            (divisor 0 gives quotient 255, remainder = dividend)
;   changes: T0, T1, T2, T3
;   clocks:  about 580-790
; ------------------------------------------------------------
div8:
    ld   [R0], ac
    ld   ac, [T0]               ; dividend, becomes the quotient
    clr  ac
    ld   ac, [T1]               ; remainder
    ld   8, ac
    ld   ac, [T2]
d8_loop:
    ld   [T1], ac               ; remainder:quotient <<= 1
    and  0x80, ac
    ld   ac, [T3]               ; remainder bit 8 after the shift
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [T0], ac
    shl                         ; carry = quotient bit 7
    ld   ac, [T0]
    bcc  d8_s
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
d8_s:
    ld   [T3], ac               ; remainder >= 256: subtract
    bne  d8_sub
    ld   [T1], ac               ; remainder >= divisor ?
    sub  [R1], ac
    bcs  d8_next                ; a borrow: no
    bra  d8_one
d8_sub:
    ld   [T1], ac
    sub  [R1], ac
d8_one:
    ld   ac, [T1]
    ld   [T0], ac
    or   1, ac
    ld   ac, [T0]
d8_next:
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  d8_loop
    ld   [T1], x
    ld   [T0], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ------------------------------------------------------------
; div16 - 16 / 8 bit unsigned divide
;   in:      R1:R0 = dividend, R2 = divisor (not 0)
;   out:     R1:R0 = quotient, AC = X = remainder
;   changes: T1, T2, T3
;   clocks:  about 1300-1890
; ------------------------------------------------------------
#addr LIB_CODE + 0x257            ; entry addresses stay fixed (carry flag rewrite left a gap)
div16:
    clr  ac
    ld   ac, [T1]               ; remainder
    ld   16, ac
    ld   ac, [T2]
d16_loop:
    ld   [T1], ac               ; remainder:R1:R0 <<= 1
    and  0x80, ac
    ld   ac, [T3]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [R1], ac
    shl                         ; carry = R1 bit 7
    ld   ac, [R1]
    bcc  d16_s1
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
d16_s1:
    ld   [R0], ac
    shl                         ; carry = R0 bit 7
    ld   ac, [R0]
    bcc  d16_s2
    ld   [R1], ac
    or   1, ac
    ld   ac, [R1]
d16_s2:
    ld   [T3], ac
    bne  d16_sub
    ld   [T1], ac               ; remainder >= divisor ?
    sub  [R2], ac
    bcs  d16_next               ; a borrow: no
    bra  d16_one
d16_sub:
    ld   [T1], ac
    sub  [R2], ac
d16_one:
    ld   ac, [T1]
    ld   [R0], ac
    or   1, ac
    ld   ac, [R0]
d16_next:
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  d16_loop
    ld   [T1], ac
    ld   ac, x
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; memcpy - copy memory, first byte first
;   in:      R1:R0 = source, R3:R2 = destination, R4 = count (0 = 256)
;   out:     R1:R0 and R3:R2 advanced by count, R4 = 0
;   changes: AC, X, Y
;   clocks:  9 + 64 per byte
;   Overlap is fine when the destination is below the source.
; ------------------------------------------------------------
#addr LIB_CODE + 0x2B8            ; entry addresses stay fixed (carry flag rewrite left a gap)
memcpy:
mc_loop:
    ld   [R0], x
    ld   [R1], y
    ld   [y,x], ac
    ld   [R2], x
    ld   [R3], y
    ld   ac, [y,x]
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  mc_1
    ld   [R1], ac
    inc
    ld   ac, [R1]
mc_1:
    ld   [R2], ac
    inc
    ld   ac, [R2]
    bne  mc_2
    ld   [R3], ac
    inc
    ld   ac, [R3]
mc_2:
    ld   [R4], ac
    dec
    ld   ac, [R4]
    bne  mc_loop
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page 3: screen clear, modes, pixels, scroll
; ============================================================
#addr LIB_CODE + 0x300

; ------------------------------------------------------------
; vid_clear - clear the screen and set every row's mode byte
;   in:      AC = mode byte: bits 1:0 = 1, 2, 4 or 8 bpp (0-3),
;            bits 3:2 = line repeat (0 = 1x, 1 = 2x, 2 = 4x), see vid_mode
;   out:     x6000-xFFFF = 0, mode bytes (x5A20-x5BFF) = AC
;   changes: AC, X, Y, T0, T1
;   clocks:  503,394 (20.0 ms)
; ------------------------------------------------------------
vid_clear:
    ld   ac, [T0]
    ld   0x60, ac
    ld   ac, [T1]
vc_pg:
    ld   [T1], y
    clr  ac
vc_b:
    ld   ac, x
    ld   0x00, [y,x]
    inc
    bne  vc_b
    ld   [T1], ac
    inc
    ld   ac, [T1]
    bne  vc_pg
    ld   [T0], ac
    ; fall into vid_mode

; ------------------------------------------------------------
; vid_mode - set every row's mode byte, leave the pixels alone
;   in:      AC = mode byte (see vid_clear)
;   out:     mode bytes x5A20-x5BFF = AC
;   changes: AC, X, Y, T0
;   clocks:  8,661
;   To change some rows only, write their mode bytes: row r's mode
;   byte is at x5A20 + r.  The video circuit reads it in horizontal
;   blanking, from the RAM.
;   Line repeat (bits 3:2): in 2x mode each byte shows on two lines and
;   in 4x on four, so a 2x screen uses half the video RAM and a 4x
;   screen a quarter.  The rows move within each byte column; vid_addr
;   and plot1 follow each row's own mode byte.  Give both lines of a 2x
;   pair (all four of a 4x group) the same mode byte.  See docs/VIDEO.md.
; ------------------------------------------------------------
vid_mode:
    ld   ac, [T0]
    ld   0x5A, y
    ld   0x20, ac
vm_0:
    ld   ac, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    bne  vm_0
    ld   0x5B, y
vm_1:
    ld   ac, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    bne  vm_1
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; vid_addr - address of a screen byte, following the row's line repeat
;   in:      AC = byte column, 0-79
;            R3:R2 = row, 0-479
;   out:     AC = address high byte, X = address low byte
;            (then: ld ac, y / ld [y,x], ac reads the byte)
;   changes: T0, T1, T4
;   clocks:  see docs/LIBRARY.md
;   With v = row + 32 (9 bits), the byte is in page x60 + 2 * column:
;       1x:  page + v8,  low byte v7:v0
;       2x:  page + 1,   low byte v7:v1, v8
;       4x:  page + 1,   low byte 1, v6:v2, v8, v7
;   (the address bits the audio slot PLD remaps, see docs/VIDEO.md)
; ------------------------------------------------------------
vid_addr:
    shl
    add  0x60, ac
    ld   ac, [T0]               ; T0 = x60 + 2 * column
    ld   [R2], ac
    add  0x20, ac
    ld   ac, [T1]               ; T1 = v7:v0
    ld   ac, x
    ld   [R3], ac
    bcc  va_v8
    inc                         ; row low + x20 carried
va_v8:
    ld   ac, [T4]               ; T4 = v8
    add  0x5A, ac
    ld   ac, y
    ld   [y,x], ac              ; the row's mode byte, x5A00 + v
    and  0x0C, ac
    beq  va_1x
    sub  0x04, ac
    beq  va_2x
    ld   [T1], ac               ; 4x: 1, v6:v2, v8, v7
    blt  va_4h
    ld   [T4], ac
    shl
    bra  va_4m
va_4h:
    ld   [T4], ac
    shl
    or   1, ac
va_4m:
    or   0x80, ac
    ld   ac, x
    ld   [T1], ac
    and  0x7C, ac
    or   x, ac
    ld   ac, x
    ld   [T0], ac
    inc
    ld   [LINK_HI], y
    jmp  [LINK_LO]
va_2x:
    ld   [T1], ac               ; 2x: v7:v1, v8
    and  0xFE, ac
    or   [T4], ac
    ld   ac, x
    ld   [T0], ac
    inc
    ld   [LINK_HI], y
    jmp  [LINK_LO]
va_1x:
    ld   [T1], ac               ; 1x: v7:v0
    ld   ac, x
    ld   [T0], ac
    add  [T4], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

#addr LIB_CODE + 0x396            ; entry addresses stay fixed (carry flag rewrite left a gap)

; ------------------------------------------------------------
; plot1 - set or clear one pixel on a 1 bpp row
;   in:      R1:R0 = x, 0-639 (0 is the first visible pixel)
;            R3:R2 = y, 0-479
;            AC = 0 to clear the pixel, anything else to set it
;   out:     -
;   changes: AC, X, Y, T0-T6
;   clocks:  see docs/LIBRARY.md
;   The row may be 1x, 2x or 4x (it calls vid_addr, which reads the
;   row's mode byte).  It maps sections 3-7 to RAM while it reads the
;   pixel byte (MAP_SHADOW or F8) and writes MAP_SHADOW back to the map
;   before it returns; that part (pl_back) runs from LIB_RAM.
; ------------------------------------------------------------
plot1:
    ld   ac, [T2]               ; T2 = set or clear
    ld   [LINK_LO], ac          ; keep the return address for the call
    ld   ac, [T5]
    ld   [LINK_HI], ac
    ld   ac, [T6]
    ld   [R0], ac               ; mask = 1 << (x & 7)
    and  7, ac
    add  lib_bits & 0xFF, ac
    ld   ac, x
    ld   lib_bits >> 8, y
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [R1], ac               ; byte column = x >> 3
    shl
    shl
    shl
    shl
    shl
    ld   ac, [T0]
    ld   [R0], ac
    shr  ac
    shr  ac
    shr  ac
    or   [T0], ac
    ld   LINK_LO, x             ; CALL vid_addr
    ld   pl_back, [x]
    ld   LINK_HI, x
    ld   pl_back >> 8, [x]
    ld   vid_addr >> 8, y
    jmp  vid_addr
                                ; vid_addr returns to pl_back in LIB_RAM

; ============================================================
; Page 4: text console - character output
; ============================================================
; 80 columns x 60 rows of 8 x 8 characters on 1 bpp rows.  The cursor is
; CUR_COL (byte column 0-79) and CUR_ROW (text row 0-59); write them to
; move the cursor.  Codes 80-FF print 00-7F in inverse video.
#addr LIB_CODE + 0x400

; ------------------------------------------------------------
; con_putc - print a character at the cursor and move the cursor on
;   in:      AC = character; 0A (newline) moves to the next line
;   out:     AC = character; cursor moved, past row 59 the screen
;            scrolls up one text row
;   changes: X, Y, T0-T5
;   clocks:  313, or 1,233,301 (49.0 ms) when it scrolls
;   The cursor must be valid: call con_clear or con_home first.
; ------------------------------------------------------------
con_putc:
    ld   ac, [T0]
    sub  0x0A, ac
    beq  cp_nl
    ld   [CUR_ROW], ac          ; glyph's top row: 8 * CUR_ROW + x20
    sub  28, ac
    blt  cp_top
    shl                         ; rows 224-479 are in the column's 2nd page
    shl
    shl
    ld   ac, [T1]
    ld   [CUR_COL], ac
    shl
    add  0x61, ac
    ld   ac, [T2]
    bra  cp_draw
cp_top:
    add  32, ac
    shl
    shl
    shl
    ld   ac, [T1]
    ld   [CUR_COL], ac
    shl
    add  0x60, ac
    ld   ac, [T2]
cp_draw:
    ld   [T0], x                ; row 0
    ld   (LIB_FONT >> 8) + 0, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [T1]
    ld   [T0], x                ; row 1
    ld   (LIB_FONT >> 8) + 1, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [T1]
    ld   [T0], x                ; row 2
    ld   (LIB_FONT >> 8) + 2, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [T1]
    ld   [T0], x                ; row 3
    ld   (LIB_FONT >> 8) + 3, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [T1]
    ld   [T0], x                ; row 4
    ld   (LIB_FONT >> 8) + 4, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [T1]
    ld   [T0], x                ; row 5
    ld   (LIB_FONT >> 8) + 5, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [T1]
    ld   [T0], x                ; row 6
    ld   (LIB_FONT >> 8) + 6, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [T1]
    ld   [T0], x                ; row 7
    ld   (LIB_FONT >> 8) + 7, y
    ld   [y,x], ac
    ld   [T1], x
    ld   [T2], y
    ld   ac, [y,x]
    ld   [CUR_COL], ac          ; next column
    inc
    ld   ac, [CUR_COL]
    sub  80, ac
    beq  cp_nl
    ld   [T0], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
cp_nl:
    ld   [T0], ac
    ; fall into con_newline

; ------------------------------------------------------------
; con_newline - move the cursor to the start of the next line,
; scrolling the screen up one text row past row 59
;   in:      -
;   out:     AC unchanged; CUR_COL = 0, CUR_ROW + 1 (at most 59)
;   changes: X, Y, T0-T5
;   clocks:  39, or 1,233,287 (49.0 ms) when it scrolls
; ------------------------------------------------------------
con_newline:
    ld   ac, [T0]
    clr  ac
    ld   ac, [CUR_COL]
    ld   [CUR_ROW], ac
    inc
    ld   ac, [CUR_ROW]
    sub  60, ac
    beq  cn_scroll
    ld   [T0], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
cn_scroll:
    ld   59, ac
    ld   ac, [CUR_ROW]
    ld   [T0], ac
    ld   con_scroll >> 8, y     ; tail call: con_scroll returns to our caller
    jmp  con_scroll

; ------------------------------------------------------------
; con_home - put the cursor at the top left (column 0, row 0)
;   in:      -
;   out:     AC unchanged
;   changes: X
;   clocks:  20
; ------------------------------------------------------------
con_home:
    ld   CUR_COL, x
    ld   0, [x]
    ld   CUR_ROW, x
    ld   0, [x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; con_clear - clear the screen to 1 bpp and home the cursor
;   in:      -
;   out:     every row 1 bpp, all pixels 0, cursor at column 0, row 0
;   changes: AC, X, Y, T0, T1
;   clocks:  503,414 (20.0 ms)
; ------------------------------------------------------------
con_clear:
    ld   CUR_COL, x
    ld   0, [x]
    ld   CUR_ROW, x
    ld   0, [x]
    clr  ac
    ld   vid_clear >> 8, y      ; tail call
    jmp  vid_clear


; ============================================================
; Page 5: text console - strings, hex and 16-bit decimal
; ============================================================
#addr LIB_CODE + 0x500

; ------------------------------------------------------------
; con_puts - print a string that ends with a 0 byte
;   in:      R1:R0 = address of the string
;   out:     R1:R0 = address of the 0 byte
;   changes: AC, X, Y, T0-T5
;   clocks:  about 355 per character
;   Uses 2 stack bytes.
; ------------------------------------------------------------
con_puts:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
ps_loop:
    ld   [R0], x
    ld   [R1], y
    ld   [y,x], ac
    beq  ps_done
    ld   LINK_LO, x             ; CALL con_putc
    ld   ps_back, [x]
    ld   LINK_HI, x
    ld   ps_back >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ps_back:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  ps_loop
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  ps_loop
ps_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ------------------------------------------------------------
; con_hex8 - print a byte as two hex digits
;   in:      AC = value
;   out:     AC = value
;   changes: X, Y, T0-T5
;   clocks:  829
;   Uses 3 stack bytes.
; ------------------------------------------------------------
con_hex8:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   [SP], x                ; PUSH AC
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [x], ac
    shr  ac                     ; high digit
    shr  ac
    shr  ac
    shr  ac
    add  lib_hex & 0xFF, ac
    ld   ac, x
    ld   lib_hex >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   hx_back1, [x]
    ld   LINK_HI, x
    ld   hx_back1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
hx_back1:
    ld   [SP], ac               ; POP AC
    inc
    ld   ac, [SP]
    ld   ac, x
    ld   [x], ac
    and  0x0F, ac               ; low digit
    add  lib_hex & 0xFF, ac
    ld   ac, x
    ld   lib_hex >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   hx_back2, [x]
    ld   LINK_HI, x
    ld   hx_back2 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
hx_back2:
    ld   [SP], x                ; the value is still in the free stack byte
    ld   [x], ac
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ------------------------------------------------------------
; con_dec16 - print a 16-bit value in decimal, no leading zeros
;   in:      R1:R0 = value, 0-65535
;   out:     R1:R0 = 0, R2 = 10
;   changes: AC, X, Y, T0-T5
;   clocks:  about 2,000 per digit (2,000-10,780)
;   Uses up to 8 stack bytes.
; ------------------------------------------------------------
con_dec16:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    clr  ac                     ; PUSH 0, the end marker
    ld   [SP], x
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
d16p_div:
    ld   10, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL div16
    ld   d16p_back1, [x]
    ld   LINK_HI, x
    ld   d16p_back1 >> 8, [x]
    ld   div16 >> 8, y
    jmp  div16
d16p_back1:
    add  0x30, ac               ; PUSH the digit
    ld   [SP], x
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [R0], ac
    or   [R1], ac
    bne  d16p_div
d16p_out:
    ld   [SP], ac               ; POP a digit, most significant first
    inc
    ld   ac, [SP]
    ld   ac, x
    ld   [x], ac
    beq  d16p_done
    ld   LINK_LO, x             ; CALL con_putc
    ld   d16p_back2, [x]
    ld   LINK_HI, x
    ld   d16p_back2 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
d16p_back2:
    bra  d16p_out
d16p_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 6: text console - 8-bit decimal
; ============================================================
#addr LIB_CODE + 0x600

; ------------------------------------------------------------
; con_dec8 - print a byte in decimal, no leading zeros
;   in:      AC = value, 0-255
;   out:     AC = last digit printed (character)
;   changes: X, Y, T0-T7
;   clocks:  552-1481
;   Uses 4 stack bytes.
; ------------------------------------------------------------
con_dec8:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   ac, [T5]               ; T5 = value, T6 = hundreds, T7 = tens
    clr  ac
    ld   ac, [T6]
    ld   ac, [T7]
    ld   [T5], ac
    blt  cd_big
    sub  100, ac                ; value < 128
    blt  cd_tens
    ld   ac, [T5]
    bra  cd_h1
cd_big:
    sub  200, ac                ; value >= 128: value - 200 fits in signed
    blt  cd_100
    ld   ac, [T5]
    ld   2, ac
    ld   ac, [T6]
    bra  cd_tens
cd_100:
    ld   [T5], ac
    sub  100, ac
    ld   ac, [T5]
cd_h1:
    ld   1, ac
    ld   ac, [T6]
cd_tens:
    ld   [T5], ac
    sub  10, ac
    blt  cd_units
    ld   ac, [T5]
    ld   [T7], ac
    inc
    ld   ac, [T7]
    bra  cd_tens
cd_units:
    ld   [T5], ac               ; PUSH units digit
    add  0x30, ac
    ld   [SP], x
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [T7], ac               ; PUSH tens digit
    add  0x30, ac
    ld   [SP], x
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [T6], ac
    beq  cd_noh
    add  0x30, ac
    ld   LINK_LO, x             ; CALL con_putc (hundreds)
    ld   cd_back1, [x]
    ld   LINK_HI, x
    ld   cd_back1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
cd_back1:
    ld   [SP], ac               ; POP tens
    inc
    ld   ac, [SP]
    ld   ac, x
    ld   [x], ac
    bra  cd_t
cd_noh:
    ld   [SP], ac               ; POP tens
    inc
    ld   ac, [SP]
    ld   ac, x
    ld   [x], ac
    sub  0x30, ac               ; no hundreds: skip a 0 tens digit
    beq  cd_u
    add  0x30, ac
cd_t:
    ld   LINK_LO, x             ; CALL con_putc (tens)
    ld   cd_back2, [x]
    ld   LINK_HI, x
    ld   cd_back2 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
cd_back2:
cd_u:
    ld   [SP], ac               ; POP units
    inc
    ld   ac, [SP]
    ld   ac, x
    ld   [x], ac
    ld   LINK_LO, x             ; CALL con_putc (units)
    ld   cd_back3, [x]
    ld   LINK_HI, x
    ld   cd_back3 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
cd_back3:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Jump table (LIB_JT, xFB00-xFBFF): entry n at xFB00 + 4n, in this order for good
; ============================================================
; Add new entries only at the end, and never reorder or remove one: code
; built without this file CALLs the table address (jt_<name>).  64 fit.
#addr LIB_JT
jt_lib_leave:       ; xFB00
    ld   lib_leave >> 8, y
    jmp  lib_leave
jt_map_set:         ; xFB04
    ld   map_set >> 8, y
    jmp  map_set
jt_frame_poll:      ; xFB08
    ld   frame_poll >> 8, y
    jmp  frame_poll
jt_wait_frames:     ; xFB0C
    ld   wait_frames >> 8, y
    jmp  wait_frames
jt_rand8:           ; xFB10
    ld   rand8 >> 8, y
    jmp  rand8
jt_add16:           ; xFB14
    ld   add16 >> 8, y
    jmp  add16
jt_sub16:           ; xFB18
    ld   sub16 >> 8, y
    jmp  sub16
jt_mul8:            ; xFB1C
    ld   mul8 >> 8, y
    jmp  mul8
jt_div8:            ; xFB20
    ld   div8 >> 8, y
    jmp  div8
jt_div16:           ; xFB24
    ld   div16 >> 8, y
    jmp  div16
jt_memset:          ; xFB28
    ld   memset >> 8, y
    jmp  memset
jt_memcpy:          ; xFB2C
    ld   memcpy >> 8, y
    jmp  memcpy
jt_vid_clear:       ; xFB30
    ld   vid_clear >> 8, y
    jmp  vid_clear
jt_vid_mode:        ; xFB34
    ld   vid_mode >> 8, y
    jmp  vid_mode
jt_vid_addr:        ; xFB38
    ld   vid_addr >> 8, y
    jmp  vid_addr
jt_plot1:           ; xFB3C
    ld   plot1 >> 8, y
    jmp  plot1
jt_con_putc:        ; xFB40
    ld   con_putc >> 8, y
    jmp  con_putc
jt_con_newline:     ; xFB44
    ld   con_newline >> 8, y
    jmp  con_newline
jt_con_home:        ; xFB48
    ld   con_home >> 8, y
    jmp  con_home
jt_con_clear:       ; xFB4C
    ld   con_clear >> 8, y
    jmp  con_clear
jt_con_puts:        ; xFB50
    ld   con_puts >> 8, y
    jmp  con_puts
jt_con_hex8:        ; xFB54
    ld   con_hex8 >> 8, y
    jmp  con_hex8
jt_con_dec8:        ; xFB58
    ld   con_dec8 >> 8, y
    jmp  con_dec8
jt_con_dec16:       ; xFB5C
    ld   con_dec16 >> 8, y
    jmp  con_dec16
jt_con_scroll:      ; xFB60
    ld   con_scroll >> 8, y
    jmp  con_scroll
jt_port_init:       ; xFB64
    ld   port_init >> 8, y
    jmp  port_init
jt_kbd_scan:        ; xFB68
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
jt_kbd_getc:        ; xFB6C
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
jt_pad_read:        ; xFB70
    ld   pad_read >> 8, y
    jmp  pad_read
jt_spi_byte:        ; xFB74
    ld   spi_byte >> 8, y
    jmp  spi_byte
jt_sd_init:         ; xFB78
    ld   sd_init >> 8, y
    jmp  sd_init
jt_sd_read:         ; xFB7C
    ld   sd_read >> 8, y
    jmp  sd_read
jt_sd_write:        ; xFB80
    ld   sd_write >> 8, y
    jmp  sd_write
jt_mouse_init:      ; xFB84
    ld   mouse_init >> 8, y
    jmp  mouse_init
jt_mouse_poll:      ; xFB88
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
jt_mouse_cmd:       ; xFB8C
    ld   mouse_cmd >> 8, y
    jmp  mouse_cmd
jt_snd_init:        ; xFB90
    ld   snd_init >> 8, y
    jmp  snd_init
jt_snd_update:      ; xFB94
    ld   snd_update >> 8, y
    jmp  snd_update
jt_snd_tone:        ; xFB98
    ld   snd_tone >> 8, y
    jmp  snd_tone
jt_snd_note:        ; xFB9C
    ld   snd_note >> 8, y
    jmp  snd_note
jt_snd_beep:        ; xFBA0
    ld   snd_beep >> 8, y
    jmp  snd_beep
jt_snd_noise:       ; xFBA4
    ld   snd_noise >> 8, y
    jmp  snd_noise
jt_snd_play:        ; xFBA8
    ld   snd_play >> 8, y
    jmp  snd_play
jt_snd_stop:        ; xFBAC
    ld   snd_stop >> 8, y
    jmp  snd_stop
jt_snd_busy:        ; xFBB0
    ld   snd_busy >> 8, y
    jmp  snd_busy
jt_slot_id:         ; xFBB4
    ld   slot_id >> 8, y
    jmp  slot_id
jt_fs_mount:        ; xFBB8
    ld   fs_mount >> 8, y
    jmp  fs_mount
jt_fs_root:         ; xFBBC
    ld   fs_root >> 8, y
    jmp  fs_root
jt_fs_next:         ; xFBC0
    ld   fs_next >> 8, y
    jmp  fs_next
jt_fs_open:         ; xFBC4
    ld   fs_open >> 8, y
    jmp  fs_open
jt_fs_read:         ; xFBC8
    ld   fs_read >> 8, y
    jmp  fs_read
jt_fs_load:         ; xFBCC
    ld   fs_load >> 8, y
    jmp  fs_load
jt_con_gets:        ; xFBD0
    ld   con_gets >> 8, y
    jmp  con_gets
jt_mouse_move:      ; xFBD4
    ld   mouse_move >> 8, y
    jmp  mouse_move


; ============================================================
; LIB_RAM (x1F00-x1FFF): code that runs from the RAM
; ============================================================
; These routines map the video sections (3-7) to RAM, which would take
; away the ROM the rest of the library runs from (sections 6 and 7).  They
; are assembled at their RAM address; gen_rom.tcl puts the bytes at the
; same address in the ROM, and the boot loader copies ROM x1F00-x1FFF to
; RAM x1F00-x1FFF (map 00, before the first map write).  Every branch
; stays inside this page.
#addr LIB_RAM

; ------------------------------------------------------------
; pl_back - the end of plot1: read, change and write the pixel byte
;   in:      AC = page, X = low byte (from vid_addr), T2 = set or clear,
;            T3 = bit mask, T6:T5 = plot1's return address
; ------------------------------------------------------------
pl_back:
    ld   ac, [T0]               ; T0 = page, X = low byte
    ld   [MAP_SHADOW], ac       ; video sections read RAM while the byte is read
    or   0xF8, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   [T0], y
    ld   [T2], ac
    beq  pl_clr
    ld   [T3], ac
    or   [y,x], ac
    bra  pl_put
pl_clr:
    ld   [T3], ac
    not
    and  [y,x], ac
pl_put:
    ld   ac, [y,x]
    ld   [MAP_SHADOW], ac       ; map back
    ld   0x50, y
    ld   ac, [y,x]
    ld   [T6], y
    jmp  [T5]

; ------------------------------------------------------------
; con_scroll - move pixel rows 8-479 up to 0-471 in byte columns 0-79
; and clear rows 472-479 (scroll the text up one row)
;   in:      -
;   out:     AC unchanged; the cursor is not moved
;   changes: X, Y, T1-T5
;   clocks:  see docs/LIBRARY.md
;   It maps sections 3-7 to RAM while it copies (MAP_SHADOW or F8) and
;   writes MAP_SHADOW back to the map before it returns, so it runs from
;   LIB_RAM.
; ------------------------------------------------------------
con_scroll:
    ld   ac, [T4]
    ld   [MAP_SHADOW], ac       ; video sections read RAM while it copies
    or   0xF8, ac
    ld   0x50, y
    ld   ac, [y,x]
    ld   0x60, ac
    ld   ac, [T1]               ; column's first page (rows 0-223)
cs_col:
    ld   [T1], y                ; rows 8-223 -> 0-215, same page
    ld   0x28, ac
cs_a:
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T3]
    ld   x, ac
    sub  8, ac
    ld   ac, x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   x, ac
    add  9, ac
    bne  cs_a
    ld   [T1], ac               ; rows 224-231 -> 216-223, page to page
    inc
    ld   ac, [T2]
    clr  ac
    ld   ac, [T5]
cs_b:
    ld   [T5], x
    ld   [T2], y
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [T5], ac
    add  0xF8, ac
    ld   ac, x
    ld   [T1], y
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [T5], ac
    inc
    ld   ac, [T5]
    sub  8, ac
    bne  cs_b
    ld   [T2], y                ; rows 232-479 -> 224-471, same page
    ld   0x08, ac
cs_c:
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T3]
    ld   x, ac
    sub  8, ac
    ld   ac, x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   x, ac
    add  9, ac
    bne  cs_c
    ld   0xF8, ac               ; clear rows 472-479
cs_d:
    ld   ac, x
    ld   0x00, [y,x]
    inc
    bne  cs_d
    ld   [T1], ac               ; next column
    add  2, ac
    ld   ac, [T1]
    bne  cs_col
    ld   [MAP_SHADOW], ac       ; map back
    ld   0x50, y
    ld   ac, [y,x]
    ld   [T4], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
