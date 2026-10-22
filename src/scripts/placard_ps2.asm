; ============================================================
; placard_ps2.asm - the PS/2 keyboard, and listening to the PS/2 devices
; ============================================================
;
; The second PS/2 socket (the lower half of the stacked dual socket J5,
; docs/IO.md "PS/2 keyboard socket") takes a PS/2 keyboard, for people
; who use their own keyboard instead of the Placard keyboard board.  Both
; can be plugged in at once.  The PS/2 keyboard shares the PS/2 DATA line
; with the mouse; its CLK is held low by latch bit 4 and read on D6 of an
; odd read while latch bit 4 is 1 (port PLD rev 02).  The drivers free
; one PS/2 clock at a time, so only one device can drive DATA.
;
; The PS/2 keyboard feeds the same state as the key matrix: KBD_NOW (its
; keys show as the matrix keys they match) and the key buffer, so
; kbd_scan, kbd_getc, con_gets, the menu and the games work with either
; keyboard.  Scan code set 2 (the keyboard's default) is turned into key
; numbers by ps2_set2 and ps2_e0 (the same mapping as the FPGA model,
; ps2_key_matrix.vhd).  The PC keys the 63-key layout has no key for
; give their character straight away: Delete 7F, Home 15, ` (Shift ~).
; The keyboard repeats a held key itself, so a held key types again.
; Caps Lock lights the keyboard's own Caps Lock light.
;
; Listening costs time: the CPU has to watch every clock edge of a byte,
; and a PS/2 device starts sending only some time after its clock is let
; go.  Two things keep that down:
;   - ps2_listen lets a device go only as long as it has been seen to
;     take to start (plus a margin), not a fixed 1 ms;
;   - wait_frames_io listens while the program waits for the next frame,
;     time the program was not using anyway.
;
; The code is at PS2_CODE (placard_lib.asm), part of the library.  The
; variables are in RAM at PS2_RAM (x4D80-x4D9F), next to the FAT reader's.
;
; Date: 10/22/2026
; ============================================================

PS2V      = 0x4D        ; the page of PS2_RAM (x4D80-x4D9F)
V_NOW     = 0x80        ; x4D80-x4D87  the PS/2 keyboard's keys, like KBD_NOW (0 = down)
V_NEW     = 0x88        ; x4D88-x4D8F  keys pressed since kbd_scan last looked (1 = pressed)
V_KST     = 0x90        ; decoder state: bit 0 E0 seen, bit 1 F0 seen, bits 6:4 Pause bytes to skip
V_DLY     = 0x91        ; x4D91-x4D92  per device (mouse, keyboard): the most 64 us units it took to start, FF = not seen yet
V_CNT     = 0x93        ; x4D93-x4D94  per device: listens, for the full-length listen every 32nd time
V_RETRY   = 0x95        ; looks for a PS/2 keyboard still to make (kbd_scan)
V_RCNT    = 0x96        ; kbd_scan calls until the next look
V_KLAST   = 0x97        ; FRAME_LO when the PS/2 keyboard was last listened to
V_WLEFT   = 0x98        ; wait_frames_io: frames left
V_WREL    = 0x99        ; wait_frames_io: 1 while the device's clock is free
V_WCUT    = 0x9B        ; wait_frames_io: last line read value to let it go in the last frame
V_WFREE   = 0x9C        ; wait_frames_io: the latch that lets the device go, 0 = no device
V_KCNT    = 0x9D        ; kbd_ps2_poll: bytes still allowed in this poll

K_ESC     = 0           ; key numbers the decoder needs
S_DEL     = 0x80        ; decoder table: the PS/2 keyboard's own keys
S_HOME    = 0x81
S_GRAVE   = 0x82
KF_PS2    = 0x02        ; KBD_FLAGS bit 1: a PS/2 keyboard answered
KF_LED    = 0x04        ; KBD_FLAGS bit 2: its Caps Lock light is on
KF_WAITED = 0x40        ; KBD_FLAGS bit 6: wait_frames_io listened to it
RETRIES   = 4           ; looks after port_init's, ...
RETRY_GAP = 32          ; ... one every 32 kbd_scan calls (about 0.5 s)
CUT_MOUSE = 227         ; a packet needs about 3.5 ms: let the mouse go up to line read 227
CUT_KBD   = 244         ; a byte needs about 1.3 ms: let the keyboard go up to line read 244


; ============================================================
; Page 0: reset, listening, finding the keyboard
; ============================================================
#addr PS2_CODE

; ------------------------------------------------------------
; ps2_reset - port_init's second half: clear the PS/2 state and look for
;             a PS/2 keyboard
;   in:      -   (port_init jumps here with its caller's LINK)
;   out:     AC = 0 a PS/2 keyboard answered (KBD_FLAGS bit 1 = 1), 1
;            none, 2 a wrong answer.  Latch = P_IDLE.
;   changes: as port_init
; ------------------------------------------------------------
ps2_reset:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   PS2V, y
    ld   7, ac
rz_clr:
    add  V_NOW, x               ; every key up
    ld   0xFF, [y,x]
    add  V_NEW, x               ; no presses waiting
    ld   0, [y,x]
    sub  1, ac
    bcc  rz_clr
    ld   V_KST, x
    ld   0, [y,x]
    ld   V_DLY, x               ; how soon the devices start: not seen yet
    ld   0xFF, [y,x]
    ld   V_DLY + 1, x
    ld   0xFF, [y,x]
    ld   V_CNT, x
    ld   0, [y,x]
    ld   V_CNT + 1, x
    ld   0, [y,x]
    ld   V_RETRY, x
    ld   RETRIES, [y,x]
    ld   V_RCNT, x
    ld   RETRY_GAP, [y,x]
    ld   LINK_LO, x             ; CALL kbd_probe
    ld   rz_back, [x]
    ld   LINK_HI, x
    ld   rz_back >> 8, [x]
    ld   kbd_probe >> 8, y
    jmp  kbd_probe
rz_back:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ------------------------------------------------------------
; ps2_listen - let a PS/2 device start a byte
;   in:      PS2_DEV, PS2_CM (ps2_rx); the latch already lets the
;            device's clock go
;   out:     AC = 0 its clock went low (the start bit: read the byte
;            with ps2_rx now), 1 it did not start
;   changes: X, Y, IO_T0-IO_T2, IO_TMP
;   clocks:  about 1,600 per 64 us unit listened
;   Listens up to the most 64 us units this device has taken to start
;   so far, plus 3 (at most MOUSE_WAIT = 16, about 1 ms); every 32nd
;   listen, and until the device has been seen to start, the full 16.
;   A device that starts later is not lost: it is held off again before
;   it starts, keeps its data and tries again at the next listen.
; ------------------------------------------------------------
ps2_listen:
    ld   PS2V, y
    ld   [PS2_DEV], ac
    add  V_CNT, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    and  31, ac
    beq  ln_full                ; every 32nd listen: the full length
    ld   [PS2_DEV], ac
    add  V_DLY, x
    ld   [y,x], ac
    blt  ln_full                ; not seen to start yet
    add  3, ac
    ld   ac, [IO_T1]
    sub  MOUSE_WAIT, ac
    blt  ln_go                  ; shorter than the full length
ln_full:
    ld   MOUSE_WAIT, ac
    ld   ac, [IO_T1]
ln_go:
    ld   [IO_T1], ac            ; IO_T2 = the units this listen started with
    ld   ac, [IO_T2]
    ld   PORT, y
    ld   [PS2_DEV], x           ; CLK: even (mouse) or odd (keyboard) address
ln_unit:
    ld   64, ac                 ; one unit: 64 tries, about 64 us
    ld   ac, [IO_T0]
ln_try:
    ld   [y,x], ac
    and  [PS2_CM], ac
    beq  ln_start
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  ln_try
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  ln_unit
    ld   1, ac                  ; it did not start
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ln_start:
    ld   [IO_T2], ac            ; the units it took: IO_T2 - IO_T1 + 1
    sub  [IO_T1], ac
    inc
    ld   ac, [IO_TMP]
    ld   PS2V, y
    ld   [PS2_DEV], ac
    add  V_DLY, x
    ld   [y,x], ac
    blt  ln_set                 ; the first start seen
    sub  [IO_TMP], ac
    bcc  ln_keep                ; no longer than before
ln_set:
    ld   [IO_TMP], ac
    ld   ac, [y,x]
ln_keep:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; kbd_probe - look for a PS/2 keyboard: set its lights to match caps lock
;   in:      KBD_FLAGS bit 0 = caps lock
;   out:     AC = 0 it answered: KBD_FLAGS bit 1 = 1 and bit 2 = its
;            Caps Lock light; 1 none, 2 a wrong answer: bit 1 = 0.
;            Latch = P_IDLE.
;   changes: X, Y, T0-T3, IO_T0-IO_T2, IO_TMP, PS2_DEV, PS2_CM
;   clocks:  about 120,000 (5 ms); about 400,000 (16 ms) with no keyboard
;   Uses 4 stack bytes.  Sends ED (set lights): FA, then the lights: FA.
; ------------------------------------------------------------
kbd_probe:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   [KBD_FLAGS], ac        ; not there until it answers
    and  0xFF ^ KF_PS2, ac
    ld   ac, [KBD_FLAGS]
    ld   LINK_LO, x             ; CALL kbd_lights
    ld   kp_back, [x]
    ld   LINK_HI, x
    ld   kp_back >> 8, [x]
    ld   kbd_lights >> 8, y
    jmp  kbd_lights
kp_back:
    bne  kp_out
    ld   [KBD_FLAGS], ac
    or   KF_PS2, ac
    ld   ac, [KBD_FLAGS]
    clr  ac
kp_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 1: commands to the devices, the Caps Lock light
; ============================================================
#addr PS2_CODE + 0x100

; ------------------------------------------------------------
; kbd_cmd - send a byte to the PS/2 keyboard and read its acknowledge (FA)
;   in:      AC = the byte
;   out:     AC = 0 acknowledged, 1 no keyboard, 2 any other answer.
;            Latch = P_IDLE.  PS2_DEV, PS2_CM = the keyboard's.
;   changes: X, Y, T0-T3, IO_T0-IO_T2, IO_TMP, PS2_DEV, PS2_CM
;   clocks:  about 55,000 (2.2 ms); about 400,000 (16 ms) with no keyboard
;   Uses 2 stack bytes.
; ------------------------------------------------------------
kbd_cmd:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   PS2_DEV, x             ; the keyboard: CLK on D6 (odd reads)
    ld   1, [x]
    ld   PS2_CM, x
    ld   0x40, [x]
    ld   LINK_LO, x             ; CALL ps2_tx
    ld   kc_bt, [x]
    ld   LINK_HI, x
    ld   kc_bt >> 8, [x]
    ld   ps2_tx >> 8, y
    jmp  ps2_tx
kc_bt:
    bne  kc_out                 ; 1 or 2
    ld   100, ac                ; the answer within about 25 ms
    ld   ac, [IO_T1]
    clr  ac
    ld   ac, [IO_T2]
    ld   LINK_LO, x             ; CALL ps2_rx
    ld   kc_br, [x]
    ld   LINK_HI, x
    ld   kc_br >> 8, [x]
    ld   ps2_rx >> 8, y
    jmp  ps2_rx
kc_br:
    bne  kc_e2
    ld   [T0], ac
    xor  0xFA, ac
    beq  kc_out                 ; AC = 0
kc_e2:
    ld   2, ac
kc_out:
    ld   PORT, y                ; hold the keyboard off again
    ld   P_IDLE, [y,x]
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ------------------------------------------------------------
; mouse_cmd - send a byte to the mouse and read its acknowledge (FA)
;   in:      AC = the byte
;   out:     AC = 0 acknowledged, 1 no mouse, 2 any other answer.  The
;            latch is left at P_FREE.  PS2_DEV, PS2_CM = the mouse's.
;   changes: X, Y, T0-T3, IO_T0-IO_T2, IO_TMP, PS2_DEV, PS2_CM
;   clocks:  about 55,000 (2.2 ms)
;   Uses 2 stack bytes.
; ------------------------------------------------------------
mouse_cmd:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   PS2_DEV, x             ; the mouse: CLK on row 5 (even reads)
    ld   0, [x]
    ld   PS2_CM, x
    ld   0x20, [x]
    ld   LINK_LO, x             ; CALL ps2_tx
    ld   mc_bt, [x]
    ld   LINK_HI, x
    ld   mc_bt >> 8, [x]
    ld   ps2_tx >> 8, y
    jmp  ps2_tx
mc_bt:
    bne  mc_out                 ; 1 or 2
    ld   100, ac                ; the answer within about 25 ms
    ld   ac, [IO_T1]
    clr  ac
    ld   ac, [IO_T2]
    ld   LINK_LO, x             ; CALL ps2_rx
    ld   mc_br, [x]
    ld   LINK_HI, x
    ld   mc_br >> 8, [x]
    ld   ps2_rx >> 8, y
    jmp  ps2_rx
mc_br:
    bne  mc_e2
    ld   [T0], ac
    xor  0xFA, ac
    beq  mc_out                 ; AC = 0
mc_e2:
    ld   2, ac
mc_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ------------------------------------------------------------
; kbd_lights - set the PS/2 keyboard's Caps Lock light to caps lock
;   in:      KBD_FLAGS bit 0 = caps lock
;   out:     AC = 0 done: KBD_FLAGS bit 2 = bit 0; 1 no keyboard, 2 a
;            wrong answer.  Latch = P_IDLE.
;   changes: as kbd_cmd
;   Uses 4 stack bytes.
; ------------------------------------------------------------
kbd_lights:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   0xED, ac               ; set the lights
    ld   LINK_LO, x             ; CALL kbd_cmd
    ld   kl_b1, [x]
    ld   LINK_HI, x
    ld   kl_b1 >> 8, [x]
    ld   kbd_cmd >> 8, y
    jmp  kbd_cmd
kl_b1:
    bne  kl_out
    ld   [KBD_FLAGS], ac        ; bit 2 = Caps Lock (bit 0 = Scroll, 1 = Num)
    and  1, ac
    shl
    shl
    ld   LINK_LO, x             ; CALL kbd_cmd
    ld   kl_b2, [x]
    ld   LINK_HI, x
    ld   kl_b2 >> 8, [x]
    ld   kbd_cmd >> 8, y
    jmp  kbd_cmd
kl_b2:
    bne  kl_out
    ld   [KBD_FLAGS], ac        ; the light now matches caps lock
    and  0xFF ^ KF_LED, ac
    ld   ac, [IO_TMP]
    ld   [KBD_FLAGS], ac
    and  1, ac
    shl
    shl
    or   [IO_TMP], ac
    ld   ac, [KBD_FLAGS]
    clr  ac
kl_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 2: kbd_scan (xC200-xC217 stay free: the bring-up ROM's marker for
; ROM section 6 is at xC210, gen_bringup.py)
; ============================================================
#addr PS2_CODE + 0x218

; ------------------------------------------------------------
; kbd_scan - scan the keyboard and buffer the new key presses
;   in:      -
;   out:     KBD_NOW + c = column c's rows, bit r = 0 while the key at
;            column c, row r is down (on the key matrix or the PS/2
;            keyboard); each key pressed since the last scan is put in
;            the key buffer as a character (kbd_getc)
;   changes: AC, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP, PS2_DEV, PS2_CM
;   clocks:  matrix only: about 700 with no new key, about 430 more per
;            new key.  With a PS/2 keyboard about 2,500 more, plus the
;            listen (ps2_listen: about 8,000-26,000 with nothing typed;
;            none after wait_frames_io) and about 25,000 per byte it
;            sends; about 110,000 when Caps Lock changes its light.
;   Uses 8 stack bytes.
;   Call it once per frame.  The matrix keys are not debounced: a key
;   bounces for less than a frame, so at most one scan sees a bounce and
;   it reads the key either way.  Scanning faster than about every 10 ms
;   can see a bounce twice and give a key twice.
;   Shift and Ctrl (either one) change the character; Caps Lock (key
;   K_CAPS) turns caps lock on and off.  Fn + Backspace = Delete (7F),
;   Fn + Esc = ` (Shift: ~), Fn + Left = Home (15).  Keys with no
;   character (Shift, Ctrl, Alt, Fn) only show in KBD_NOW.  The key
;   numbers and characters are in docs/IO.md, "Keyboard".
;   With no PS/2 keyboard found by port_init, every 32nd call looks for
;   one again, 4 times (about 16 ms each), for one that was still
;   testing itself after power-up.  A PS/2 keyboard that stops
;   answering (when its light is set) counts as unplugged.
; ------------------------------------------------------------
kbd_scan:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   [KBD_FLAGS], ac
    and  KF_PS2, ac
    bne  kz_ps2
    ld   PS2V, y                ; no PS/2 keyboard: look again?
    ld   V_RETRY, x
    ld   [y,x], ac
    beq  kz_matrix
    ld   V_RCNT, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    bne  kz_matrix
    ld   RETRY_GAP, [y,x]
    ld   V_RETRY, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL kbd_probe
    ld   kz_pb, [x]
    ld   LINK_HI, x
    ld   kz_pb >> 8, [x]
    ld   kbd_probe >> 8, y
    jmp  kbd_probe
kz_pb:
    bne  kz_matrix
kz_ps2:
    ld   [KBD_FLAGS], ac        ; wait_frames_io listened already?
    and  KF_WAITED, ac
    beq  kz_poll
    ld   [KBD_FLAGS], ac
    and  0xFF ^ KF_WAITED, ac
    ld   ac, [KBD_FLAGS]
    bra  kz_matrix
kz_poll:
    ld   LINK_LO, x             ; CALL kbd_ps2_poll
    ld   kz_pp, [x]
    ld   LINK_HI, x
    ld   kz_pp >> 8, [x]
    ld   kbd_ps2_poll >> 8, y
    jmp  kbd_ps2_poll
kz_pp:
kz_matrix:
    ld   LINK_LO, x             ; CALL kbd_mscan
    ld   kz_ms, [x]
    ld   LINK_HI, x
    ld   kz_ms >> 8, [x]
    ld   kbd_mscan >> 8, y
    jmp  kbd_mscan
kz_ms:
    ld   [KBD_FLAGS], ac
    and  KF_PS2, ac
    beq  kz_out
    ld   PS2V, y                ; KBD_NOW: the PS/2 keyboard's keys too
    ld   7, ac
kz_and:
    ld   ac, [T0]
    add  V_NOW, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [T0], ac
    add  KBD_NOW, x
    ld   [T1], ac
    and  [x], ac
    ld   ac, [x]
    ld   [T0], ac
    sub  1, ac
    bcc  kz_and
    clr  ac                     ; then its new presses, key by key
    ld   ac, [T6]               ; T6 = column, T7 = its new presses,
kz_col:                         ; T5 = key number
    ld   PS2V, y
    ld   [T6], ac
    add  V_NEW, x
    ld   [y,x], ac
    ld   ac, [T7]
    ld   0, [y,x]
    ld   [T6], ac
    shl
    shl
    shl
    ld   ac, [T5]
kz_bit:
    ld   [T7], ac
    beq  kz_ncol
    and  1, ac
    beq  kz_nob
    ld   [T5], ac
    ld   LINK_LO, x             ; CALL kbd_key
    ld   kz_kb, [x]
    ld   LINK_HI, x
    ld   kz_kb >> 8, [x]
    ld   kbd_key >> 8, y
    jmp  kbd_key
kz_kb:
kz_nob:
    ld   [T5], ac
    inc
    ld   ac, [T5]
    ld   [T7], ac
    shr  ac
    ld   ac, [T7]
    bra  kz_bit
kz_ncol:
    ld   [T6], ac
    inc
    ld   ac, [T6]
    xor  8, ac
    bne  kz_col
    ld   [KBD_FLAGS], ac        ; Caps Lock light out of step with caps lock?
    shl
    shl
    xor  [KBD_FLAGS], ac
    and  KF_LED, ac
    beq  kz_out
    ld   LINK_LO, x             ; CALL kbd_probe (sets the light; no
    ld   kz_lt, [x]             ; answer: the keyboard is gone)
    ld   LINK_HI, x
    ld   kz_lt >> 8, [x]
    ld   kbd_probe >> 8, y
    jmp  kbd_probe
kz_lt:
kz_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 3: scan code set 2 decoder
; ============================================================
#addr PS2_CODE + 0x300

; ------------------------------------------------------------
; kbd_byte - work out one byte from the PS/2 keyboard
;   in:      AC = the byte (scan code set 2)
;   out:     the PS/2 key state: a key's make code clears its bit in
;            V_NOW and sets it in V_NEW; its break code (F0 first) sets
;            it in V_NOW again.  Delete, Home and ` put their character
;            in the key buffer.  E1 (Pause) and its 7 bytes, answers
;            (FA, AA, EE, FE) and keys with no place are skipped.
;   changes: AC, X, Y, T4, IO_T3, IO_TMP
;   Uses no stack (a leaf; Delete, Home and ` end in kbd_putc).
; ------------------------------------------------------------
kbd_byte:
    ld   ac, [T4]               ; T4 = the byte
    ld   PS2V, y
    ld   V_KST, x
    ld   [y,x], ac              ; skipping the Pause key's bytes?
    and  0x70, ac
    beq  kb_ns
    ld   [y,x], ac
    sub  0x10, ac
    ld   ac, [y,x]
    bra  kb_out
kb_ns:
    ld   [T4], ac
    xor  0xE1, ac
    bne  kb_ne1
    ld   0x70, [y,x]            ; E1: skip the 7 bytes after it
    bra  kb_out
kb_ne1:
    ld   [T4], ac
    xor  0xE0, ac
    bne  kb_ne0
    ld   [y,x], ac              ; E0: the next code is an extended key
    or   1, ac
    ld   ac, [y,x]
    bra  kb_out
kb_ne0:
    ld   [T4], ac
    xor  0xF0, ac
    bne  kb_nf0
    ld   [y,x], ac              ; F0: the next code is a release
    or   2, ac
    ld   ac, [y,x]
    bra  kb_out
kb_nf0:
    ld   [T4], ac               ; above 83: not a key (answers)
    sub  0x84, ac
    bcc  kb_clr
    ld   [y,x], ac
    and  1, ac
    bne  kb_ext
    ld   [T4], ac               ; IO_T3 = the key from ps2_set2
    add  ps2_set2 & 0xFF, x
    ld   ps2_set2 >> 8, y
    bra  kb_look
kb_ext:
    clr  ac                     ; look the code up in ps2_e0
    ld   ac, [IO_TMP]
kb_find:
    ld   [IO_TMP], ac
    add  ps2_e0 & 0xFF, x
    ld   ps2_e0 >> 8, y
    ld   [y,x], ac
    beq  kb_none                ; the end: not a key
    xor  [T4], ac
    beq  kb_found
    ld   [IO_TMP], ac
    add  2, ac
    ld   ac, [IO_TMP]
    bra  kb_find
kb_none:
    ld   0xFF, ac
    ld   ac, [IO_T3]
    bra  kb_key
kb_found:
    ld   [IO_TMP], ac
    add  (ps2_e0 & 0xFF) + 1, x
kb_look:
    ld   [y,x], ac
    ld   ac, [IO_T3]
kb_key:
    ld   PS2V, y                ; IO_TMP = the state: F0 seen?
    ld   V_KST, x
    ld   [y,x], ac
    ld   ac, [IO_TMP]
    ld   0, [y,x]
    ld   [IO_T3], ac
    xor  0xFF, ac
    beq  kb_out                 ; no key
    ld   [IO_T3], ac
    blt  kb_spec                ; 80-82: a key of its own
    and  7, ac                  ; T4 = the key's bit
    add  lib_bits & 0xFF, x
    ld   lib_bits >> 8, y
    ld   [y,x], ac
    ld   ac, [T4]
    ld   [IO_T3], ac            ; IO_T3 = its column
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [IO_T3]
    add  V_NOW, x
    ld   PS2V, y
    ld   [IO_TMP], ac
    and  2, ac
    bne  kb_up
    ld   [T4], ac               ; pressed: V_NOW bit = 0, V_NEW bit = 1
    not
    and  [y,x], ac
    ld   ac, [y,x]
    ld   [IO_T3], ac
    add  V_NEW, x
    ld   [T4], ac
    or   [y,x], ac
    ld   ac, [y,x]
    bra  kb_out
kb_up:
    ld   [T4], ac               ; released: V_NOW bit = 1
    or   [y,x], ac
    ld   ac, [y,x]
    bra  kb_out
kb_clr:
    ld   0, [y,x]               ; (Y, X = V_KST)
kb_out:
    ld   [LINK_HI], y           ; return
    jmp  [LINK_LO]
kb_spec:
    ld   [IO_TMP], ac           ; only when pressed
    and  2, ac
    bne  kb_out
    ld   [IO_T3], ac
    xor  S_DEL, ac
    bne  kb_s1
    ld   0x7F, ac               ; Delete
    bra  kb_put
kb_s1:
    xor  S_DEL ^ S_HOME, ac
    bne  kb_s2
    ld   0x15, ac               ; Home
    bra  kb_put
kb_s2:
    ld   PS2V, y                ; `, or ~ with either Shift held
    ld   V_NOW + (K_LSHIFT >> 3), x
    ld   [y,x], ac
    and  1 << (K_LSHIFT & 7), ac
    beq  kb_tilde
    ld   V_NOW + (K_RSHIFT >> 3), x
    ld   [y,x], ac
    and  1 << (K_RSHIFT & 7), ac
    beq  kb_tilde
    ld   0x60, ac
    bra  kb_put
kb_tilde:
    ld   0x7E, ac
kb_put:
    ld   kbd_putc >> 8, y       ; kbd_putc returns for it
    jmp  kbd_putc


; ============================================================
; Page 4: wait_frames_io
; ============================================================
#addr PS2_CODE + 0x400

; ------------------------------------------------------------
; wait_frames_io - wait until AC new frames have started, and let the
;                  mouse or the PS/2 keyboard send while waiting
;   in:      AC = frames, 1-255 (0 waits 256)
;   out:     as wait_frames.  Bytes the device sent are read: a mouse
;            packet into MOUSE_B, MOUSE_DX, MOUSE_DY (mouse_poll then
;            returns 1), PS/2 keys into the PS/2 key state (kbd_scan
;            adds them).  Latch = P_IDLE.
;   changes: AC, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP, PS2_DEV, PS2_CM
;   clocks:  AC frames, like wait_frames.  A byte that starts is always
;            finished before the wait ends: in the last frame the device
;            is let go only up to line read CUT_MOUSE (a 3-byte packet)
;            or CUT_KBD (one byte).
;   Uses 4 stack bytes.
;   Use it in place of wait_frames: the time the program would spin in
;   wait_frames is used to listen, so mouse_poll and kbd_scan don't have
;   to (they see MOUSE_ST bit 6 and KBD_FLAGS bit 6 and only take what
;   was read).  With both the mouse (running) and a PS/2 keyboard, it
;   listens to the mouse in even frames and the keyboard in odd ones.
;   With neither it is wait_frames.
; ------------------------------------------------------------
wait_frames_io:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   PS2V, y
    ld   V_WLEFT, x
    ld   ac, [y,x]
    ld   V_WREL, x
    ld   0, [y,x]
    ld   [MOUSE_ST], ac         ; mouse_poll: this wait listens
    or   0x40, ac
    ld   ac, [MOUSE_ST]
    ld   [KBD_FLAGS], ac        ; kbd_scan: this wait listens
    or   KF_WAITED, ac
    ld   ac, [KBD_FLAGS]
    and  KF_PS2, ac             ; T3 = PS/2 keyboard
    ld   ac, [T3]
    ld   V_WFREE, x             ; the latch that lets it go, 0 = none
    ld   0, [y,x]
    ld   [MOUSE_ST], ac         ; mouse running?
    blt  wi_mr
    bra  wi_k
wi_mr:
    ld   [T3], ac
    beq  wi_m
    ld   [FRAME_LO], ac         ; both: even frames the mouse
    and  1, ac
    bne  wi_k
wi_m:
    ld   P_FREE, [y,x]
    ld   V_WCUT, x
    ld   CUT_MOUSE, [y,x]
    ld   PS2_DEV, x
    ld   0, [x]
    ld   PS2_CM, x
    ld   0x20, [x]
    bra  wi_line
wi_k:
    ld   [T3], ac
    beq  wi_line                ; neither
    ld   P_KFREE, [y,x]
    ld   V_WCUT, x
    ld   CUT_KBD, [y,x]
    ld   V_KLAST, x             ; (menu_poll: it is listened to)
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   PS2_DEV, x
    ld   1, [x]
    ld   PS2_CM, x
    ld   0x40, [x]
wi_line:
    ld   0x50, y                ; start from the line now
    ld   [y,x], ac
    ld   ac, [LINE_LAST]
wi_loop:
    ld   0x50, y
    ld   [y,x], ac
    ld   ac, [T0]
    xor  [LINE_LAST], ac
    blt  wi_diff
    ld   [T0], ac
    sub  [LINE_LAST], ac
    blt  wi_tick
    bra  wi_same
wi_diff:
    ld   [T0], ac
    blt  wi_same
wi_tick:
    ld   [T0], ac               ; a new frame
    ld   ac, [LINE_LAST]
    ld   [FRAME_LO], ac
    inc
    ld   ac, [FRAME_LO]
    bne  wi_count
    ld   [FRAME_HI], ac
    inc
    ld   ac, [FRAME_HI]
wi_count:
    ld   PS2V, y
    ld   V_WLEFT, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    bne  wi_dev
    ld   PORT, y                ; done: hold the devices off
    ld   P_IDLE, [y,x]
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave
wi_same:
    ld   [T0], ac
    ld   ac, [LINE_LAST]
wi_dev:
    ld   PS2V, y
    ld   V_WFREE, x
    ld   [y,x], ac
    beq  wi_loop                ; no device: just wait
    ld   V_WLEFT, x             ; may it send now?  Yes with 2 or more
    ld   [y,x], ac              ; frames left, or before the cut line
    xor  1, ac
    bne  wi_ok
    ld   V_WCUT, x
    ld   [y,x], ac
    sub  [LINE_LAST], ac
    bcc  wi_ok
    ld   V_WREL, x              ; no: hold it off
    ld   0, [y,x]
    ld   PORT, y
    ld   P_IDLE, [y,x]
    bra  wi_loop
wi_ok:
    ld   V_WREL, x
    ld   [y,x], ac
    bne  wi_look
    ld   1, [y,x]               ; let it go
    ld   V_WFREE, x
    ld   [y,x], ac
    ld   PORT, y
    ld   ac, [y,x]
wi_look:
    ld   PORT, y                ; its clock low: it has started a byte
    ld   [PS2_DEV], x
    ld   [y,x], ac
    and  [PS2_CM], ac
    bne  wi_loop
    ld   PS2V, y                ; read it (that holds it off again)
    ld   V_WREL, x
    ld   0, [y,x]
    ld   LINK_LO, x             ; CALL mouse_pkt or kbd_rx1
    ld   wi_back, [x]
    ld   LINK_HI, x
    ld   wi_back >> 8, [x]
    ld   [PS2_DEV], ac
    bne  wi_kb
    ld   mouse_pkt >> 8, y
    jmp  mouse_pkt
wi_kb:
    ld   kbd_rx1 >> 8, y
    jmp  kbd_rx1
wi_back:
    bra  wi_loop


; ============================================================
; In the slot helpers' page: the PS/2 keyboard's poll
; ============================================================
#addr PS2_POLL_CODE

; ------------------------------------------------------------
; kbd_ps2_poll - read what the PS/2 keyboard has to send
;   in:      a PS/2 keyboard is there (KBD_FLAGS bit 1)
;   out:     its keys in the PS/2 key state (kbd_scan adds them to
;            KBD_NOW and the key buffer).  Latch = P_IDLE.
;   changes: X, Y, T0-T6, IO_T0-IO_T3, IO_TMP, PS2_DEV, PS2_CM
;   clocks:  the listen (ps2_listen), and about 26,000 per byte
;   Uses 4 stack bytes.  Reads up to 6 bytes, holding the keyboard off
;   while it works each one out and listening again for the next.
; ------------------------------------------------------------
kbd_ps2_poll:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   PS2_DEV, x             ; the keyboard: CLK on D6 (odd reads)
    ld   1, [x]
    ld   PS2_CM, x
    ld   0x40, [x]
    ld   PS2V, y
    ld   V_KLAST, x
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   V_KCNT, x
    ld   6, [y,x]
kq_next:
    ld   PORT, y                ; let the keyboard go
    ld   P_KFREE, [y,x]
    ld   LINK_LO, x             ; CALL ps2_listen
    ld   kq_ls, [x]
    ld   LINK_HI, x
    ld   kq_ls >> 8, [x]
    ld   ps2_listen >> 8, y
    jmp  ps2_listen
kq_ls:
    bne  kq_out                 ; nothing (more)
    ld   LINK_LO, x             ; CALL kbd_rx1
    ld   kq_rx, [x]
    ld   LINK_HI, x
    ld   kq_rx >> 8, [x]
    ld   kbd_rx1 >> 8, y
    jmp  kbd_rx1
kq_rx:
    bne  kq_out                 ; a bad byte: it is sent again later
    ld   PS2V, y
    ld   V_KCNT, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    bne  kq_next
kq_out:
    ld   PORT, y
    ld   P_IDLE, [y,x]
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; In an I/O page: one byte from the PS/2 keyboard
; ============================================================
#addr PS2_RX_CODE

; ------------------------------------------------------------
; kbd_rx1 - read the byte the PS/2 keyboard has started, and work it out
;   in:      the keyboard's clock is free (P_KFREE) and it has started
;   out:     AC = 0 a good byte (in the PS/2 key state), 1 nothing came,
;            2 a bad byte.  Latch = P_IDLE.
;   changes: X, Y, T0-T6, IO_T0-IO_T2, IO_TMP, PS2_DEV, PS2_CM
;   Uses 2 stack bytes.
; ------------------------------------------------------------
kbd_rx1:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   PS2_DEV, x
    ld   1, [x]
    ld   PS2_CM, x
    ld   0x40, [x]
    ld   4, ac                  ; it has started: about 1 ms is plenty
    ld   ac, [IO_T1]
    clr  ac
    ld   ac, [IO_T2]
    ld   LINK_LO, x             ; CALL ps2_rx
    ld   kr_rx, [x]
    ld   LINK_HI, x
    ld   kr_rx >> 8, [x]
    ld   ps2_rx >> 8, y
    jmp  ps2_rx
kr_rx:
    ld   PORT, y                ; hold it off while the byte is worked out
    ld   P_IDLE, [y,x]
    bne  kr_out
    ld   PS2V, y
    ld   V_KLAST, x
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   [T0], ac
    ld   LINK_LO, x             ; CALL kbd_byte
    ld   kr_kb, [x]
    ld   LINK_HI, x
    ld   kr_kb >> 8, [x]
    ld   kbd_byte >> 8, y
    jmp  kbd_byte
kr_kb:
    clr  ac
kr_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; In an I/O page: tables
; ============================================================
#addr PS2_TAB_CODE


; ps2_set2 - scan code set 2 (00-83) to key number (column * 8 + row,
; docs/IO.md); FF = no key; 80-82 = the PS/2 keyboard's own keys
ps2_set2:
    ;    x0    x1    x2    x3    x4    x5    x6    x7    x8    x9    xA    xB    xC    xD    xE    xF
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 14,   0x82, 0xFF  ; 0x  Tab `
    #d8 0xFF, 57,   41,   0xFF, 28,   15,   1,    0xFF, 0xFF, 0xFF, 42,   30,   29,   16,   2,    0xFF  ; 1x  LAlt LShift LCtrl q 1 z s a w 2
    #d8 0xFF, 44,   43,   31,   17,   4,    3,    0xFF, 0xFF, 58,   45,   32,   19,   18,   5,    0xFF  ; 2x  c x d e 4 3 Space v f t r 5
    #d8 0xFF, 47,   46,   34,   33,   20,   6,    0xFF, 0xFF, 0xFF, 48,   35,   21,   7,    8,    0xFF  ; 3x  n b h g y 6 m j u 7 8
    #d8 0xFF, 49,   36,   22,   23,   10,   9,    0xFF, 0xFF, 50,   51,   37,   38,   24,   11,   0xFF  ; 4x  , k i o 0 9 . / l ; p -
    #d8 0xFF, 0xFF, 39,   0xFF, 25,   12,   0xFF, 0xFF, 54,   52,   40,   26,   0xFF, 27,   0xFF, 0xFF  ; 5x  ' [ = Caps RShift Enter ] \
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 13,   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 6x  Backspace
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0,    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 7x  Esc
    #d8 0xFF, 0xFF, 0xFF, 0xFF                                                                          ; 80-83

; ps2_e0 - E0 codes: pairs of code, key number; 00 ends the list
ps2_e0:
    #d8 0x14, 59                ; right Ctrl
    #d8 0x11, 56                ; right Alt
    #d8 0x1F, 55                ; left Windows = Fn
    #d8 0x27, 55                ; right Windows = Fn
    #d8 0x5A, 40                ; keypad Enter
    #d8 0x75, 53                ; Up
    #d8 0x6B, 61                ; Left
    #d8 0x72, 62                ; Down
    #d8 0x74, 63                ; Right
    #d8 0x71, S_DEL             ; Delete
    #d8 0x6C, S_HOME            ; Home
    #d8 0x00
