; ============================================================
; placard_ps2.asm - the PS/2 keyboard and mouse: the receiver, the turns,
; the commands
; ============================================================
;
; The keyboard is a PS/2 keyboard in the lower half of the stacked dual
; socket J5 (docs/IO.md "PS/2 keyboard socket"); the mouse is in the upper
; half.  They share the PS/2 DATA line, so only one of them may send at a
; time: the port latch holds the other one's CLK low.  The one that is
; let go is the LISTENED device; its latch value is kept in PS2_LSN
; (P_FREE the mouse, P_KFREE the keyboard, P_IDLE neither).
;
; Since 2026-10-25 the bytes are received by the PS/2 receiver PLD
; (ATF22V10_PS2.pld, docs/IO.md "PS/2 receiver"): it shifts in the byte
; the listened device sends, holds the device off once the byte is in,
; and the CPU reads it:
;
;   read  x5203 (PORT_RDY)  D7 = 0 while a byte is ready (after the 11th
;                           clock: the device is held off from then on)
;   read  x5202 (PORT_RX)   the byte
;   write x5202 or x5203    re-arms the receiver (and loads the latch
;                           with the value written, like any port write)
;
; A byte costs about 60 clocks to take (ps2_take) instead of the 25,000
; the CPU spent following every clock edge before, and nothing while
; nothing comes, so programs poll as often as they like: once per frame
; from kbd_scan and mouse_poll, continuously from wait_frames_io, and
; from menu_poll and ps2_poll in between.  The driver re-arms the
; receiver with the latch value in PS2_LSN; the pads and the SD card's
; start clocks change the latch (ps2_pause first, then the value in
; PS2_LSN again).
;
; Both devices present: ps2_turn gives the mouse the even frames and the
; keyboard the odd ones (FRAME_LO, kept by frame_poll), staying with the
; mouse while it is in the middle of a packet.  Lower rates follow: with
; both, a mouse packet (3 bytes) every other frame at most, a keyboard
; byte per odd frame when only kbd_scan polls (more with wait_frames_io
; or ps2_poll in the program's loop).
;
; Scan code set 2 (the keyboard's default) is turned into key numbers by
; ps2_set2 and ps2_e0: the keys show in KBD_NOW and the key buffer as
; before, so kbd_scan, kbd_getc, con_gets, the menu and the games are
; unchanged.  The PC keys the 63-key layout has no key for give their
; character straight away: Delete 7F, Home 15, ` (Shift ~).  The
; keyboard repeats a held key itself, so a held key types again.  Caps
; Lock lights the keyboard's own Caps Lock light.
;
; The code is at PS2_CODE (placard_lib.asm) and in I/O pages 1 and B-E
; (IO_CODE, placard_io.asm), part of the library.  The variables are in
; RAM at PS2_RAM (x4D80-x4D9F), next to the FAT reader's.
;
; Date: 10/26/2026
; ============================================================

PS2V      = 0x4D        ; the page of PS2_RAM (x4D80-x4D9F)
V_NEW     = 0x80        ; x4D80-x4D87  keys pressed since kbd_scan last looked (1 = pressed)
V_KST     = 0x88        ; decoder state: bit 0 E0 seen, bit 1 F0 seen, bits 6:4 Pause bytes to skip
V_RETRY   = 0x89        ; looks for a PS/2 keyboard still to make (kbd_scan)
V_RCNT    = 0x8A        ; kbd_scan calls until the next look
V_KLAST   = 0x8B        ; FRAME_LO when kbd_scan last polled (menu_poll)
V_WLEFT   = 0x8C        ; wait_frames_io: frames left
V_MPI     = 0x8D        ; mouse: bytes of the packet in hand, 0-2 (V_MPI..V_MNEW clear together)
V_MPF     = 0x8E        ; FRAME_LO when the packet's first byte came
V_MPK     = 0x8F        ; x4D8F-x4D90  the packet's first two bytes
V_MDX     = 0x91        ; movement since mouse_poll last took it, X (signed, held to +-127)
V_MDY     = 0x92        ; and Y (down positive)
V_MB      = 0x93        ; buttons of the last packet
V_MNEW    = 0x94        ; 1 = a packet came since mouse_poll last took it
V_SAVE    = 0x95        ; PS2_LSN kept while a command is sent
V_CMD     = 0x96        ; the command byte
V_DEV     = 0x97        ; the device's latch value for it
V_RES     = 0x98        ; the result
V_ANY     = 0x99        ; 1 = a key was pressed since kbd_scan last looked (V_NEW has bits)

K_ESC     = 0           ; key numbers the decoder needs
S_DEL     = 0x80        ; decoder table: the PS/2 keyboard's own keys
S_HOME    = 0x81
S_GRAVE   = 0x82
KF_PS2    = 0x02        ; KBD_FLAGS bit 1: a PS/2 keyboard answered
KF_LED    = 0x04        ; KBD_FLAGS bit 2: its Caps Lock light is on
MS_RUN    = 0x80        ; MOUSE_ST bit 7: the mouse is running
MS_WAITED = 0x40        ; MOUSE_ST bit 6: wait_frames_io polled since mouse_poll last ran
RETRIES   = 4           ; looks after port_init's, ...
RETRY_GAP = 32          ; ... one every 32 kbd_scan calls (about 0.5 s)
STUCK     = 4           ; frames after which a half packet is given up (ps2_turn)
HOLD_N    = 190         ; ps2_pause: loop count of the 100 us hold (PS/2: a device is sure to see an inhibit of 100 us)


; ============================================================
; Page 0: reset, taking a byte, the turns
; ============================================================
#addr PS2_CODE

; ------------------------------------------------------------
; ps2_reset - port_init's second half: clear the PS/2 state and look for
;             a PS/2 keyboard
;   in:      -   (port_init jumps here with its caller's LINK)
;   out:     AC = 0 a PS/2 keyboard answered (KBD_FLAGS bit 1 = 1), 1
;            none, 2 a wrong answer.  Latch = PS2_LSN = P_IDLE.
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
    add  V_NEW, x               ; no presses waiting
    ld   0, [y,x]
    add  V_MPI, x               ; no packet in hand, no movement
    ld   0, [y,x]
    sub  1, ac
    bcc  rz_clr
    ld   V_KST, x
    ld   0, [y,x]
    ld   V_RETRY, x
    ld   RETRIES, [y,x]
    ld   V_RCNT, x
    ld   RETRY_GAP, [y,x]
    ld   V_ANY, x
    ld   0, [y,x]
    ld   P_IDLE, ac             ; nobody listened to; the receiver armed
    ld   ac, [PS2_LSN]
    ld   PORT, y
    ld   PORT_RX, x
    ld   ac, [y,x]
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
; ps2_take - take the byte in the receiver, if there is one
;   in:      PS2_LSN = the device listened to
;   out:     the byte is worked out: a keyboard byte into KBD_NOW, V_NEW
;            and the key buffer (kbd_byte), a mouse byte into the packet
;            in hand (mouse_byte); the receiver is re-armed.  A byte with
;            nobody listened to is dropped.  AC is undefined.
;   changes: AC, X, Y, T0-T6, IO_T3, IO_TMP
;   clocks:  20 with nothing ready; about 60 plus the byte's handling
;            (kbd_byte about 150-250, mouse_byte 60-200)
;   A leaf: kbd_byte and mouse_byte return for it.
; ------------------------------------------------------------
ps2_take:
    ld   PORT, y
    ld   PORT_RDY, x
    ld   [y,x], ac
    blt  tk_ret                 ; D7 = 1: nothing ready
    ld   PORT_RX, x
    ld   [y,x], ac              ; the byte
    ld   ac, [T0]
    ld   [PS2_LSN], ac          ; re-arm; the latch keeps its value
    ld   ac, [y,x]
    xor  P_KFREE, ac
    bne  tk_nk
    ld   [KBD_FLAGS], ac        ; a byte from it: the keyboard is there
    or   KF_PS2, ac
    ld   ac, [KBD_FLAGS]
    ld   [T0], ac
    ld   kbd_byte >> 8, y       ; kbd_byte returns for us
    jmp  kbd_byte
tk_nk:
    xor  P_KFREE ^ P_FREE, ac
    bne  tk_ret                 ; nobody listened to: drop it
    ld   [T0], ac
    ld   mouse_byte >> 8, y     ; mouse_byte returns for us
    jmp  mouse_byte
tk_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; ps2_turn - let the right device send
;   in:      MOUSE_ST bit 7 (the mouse runs), KBD_FLAGS bit 1 (a PS/2
;            keyboard), FRAME_LO, the packet in hand
;   out:     PS2_LSN = P_FREE (the mouse) or P_KFREE (the keyboard),
;            written to the latch (re-arming the receiver) when it
;            changed.  With no mouse the keyboard socket is listened to
;            even when no keyboard answered kbd_probe: its first byte
;            (ps2_take) marks it found.  With both devices the mouse has the even frames
;            and the keyboard the odd ones, but the mouse keeps the line
;            while a packet is half in; a packet that stays half in for
;            STUCK frames is given up.
;   changes: AC, X, Y
;   clocks:  about 60-100
;   Take the receiver's byte first (ps2_take): the write loses it.
; ------------------------------------------------------------
ps2_turn:
    ld   [MOUSE_ST], ac
    blt  tn_mr
tn_kbd:                         ; no mouse: the keyboard, found or not (a
    ld   P_KFREE, ac            ; byte from it shows it is there)
    bra  tn_set
tn_mr:
    ld   [KBD_FLAGS], ac
    and  KF_PS2, ac
    beq  tn_mouse               ; the mouse alone
    ld   PS2V, y                ; both: half a packet in?
    ld   V_MPI, x
    ld   [y,x], ac
    beq  tn_frame
    ld   V_MPF, x               ; for less than STUCK frames: the mouse
    ld   [FRAME_LO], ac
    sub  [y,x], ac
    sub  STUCK, ac
    blt  tn_mouse
    ld   V_MPI, x               ; given up
    ld   0, [y,x]
tn_frame:
    ld   [FRAME_LO], ac         ; even frames the mouse, odd the keyboard
    and  1, ac
    bne  tn_kbd
tn_mouse:
    ld   P_FREE, ac
tn_set:
    xor  [PS2_LSN], ac
    beq  tn_ret                 ; as it is
    xor  [PS2_LSN], ac
    ld   ac, [PS2_LSN]
    ld   PORT, y
    ld   PORT_RX, x
    ld   ac, [y,x]
tn_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page 1: commands to the devices
; ============================================================
#addr PS2_CODE + 0x100

; ------------------------------------------------------------
; kbd_probe - look for a PS/2 keyboard: set its lights to match caps lock
;   in:      KBD_FLAGS bit 0 = caps lock
;   out:     AC = 0 it answered: KBD_FLAGS bit 1 = 1 and bit 2 = its
;            Caps Lock light; 1 none, 2 a wrong answer: bit 1 = 0.
;            Latch = PS2_LSN again.
;   changes: X, Y, T0-T6, IO_T0-IO_T3, IO_TMP
;   clocks:  about 120,000 (5 ms); about 400,000 (16 ms) with no keyboard
;   Uses 8 stack bytes.  Sends ED (set lights): FA, then the lights: FA.
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

; ------------------------------------------------------------
; kbd_cmd - send a byte to the PS/2 keyboard and read its acknowledge (FA)
; mouse_cmd - the same to the mouse
;   in:      AC = the byte
;   out:     AC = 0 acknowledged, 1 no device (it did not clock), 2 any
;            other answer or none.  Latch = PS2_LSN again (the byte the
;            listened device may have had ready is taken first).
;   changes: X, Y, T0-T6, IO_T0-IO_T3, IO_TMP
;   clocks:  about 55,000 (2.2 ms); about 400,000 (16 ms) with no device
;   Uses 6 stack bytes.  The device is let go for the command and its
;   answer only (ps2_cmd), then the line goes back to whoever had it.
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
    ld   PS2V, y
    ld   V_DEV, x
    ld   P_KFREE, [y,x]
    bra  cmd_body
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
    ld   PS2V, y
    ld   V_DEV, x
    ld   P_FREE, [y,x]
cmd_body:
    ld   V_CMD, x               ; the byte (AC)
    ld   ac, [y,x]
    ld   V_SAVE, x              ; whose line it is
    ld   [PS2_LSN], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL ps2_pause: take, hold both
    ld   cb_p1, [x]
    ld   LINK_HI, x
    ld   cb_p1 >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
cb_p1:
    ld   PS2V, y
    ld   V_DEV, x               ; the device's line now
    ld   [y,x], ac
    ld   ac, [PS2_LSN]
    ld   V_CMD, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL ps2_cmd
    ld   cb_cm, [x]
    ld   LINK_HI, x
    ld   cb_cm >> 8, [x]
    ld   ps2_cmd >> 8, y
    jmp  ps2_cmd
cb_cm:
    ld   PS2V, y
    ld   V_RES, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL ps2_pause: take what it sent after
    ld   cb_p2, [x]
    ld   LINK_HI, x
    ld   cb_p2 >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
cb_p2:
    ld   PS2V, y
    ld   V_SAVE, x              ; the line back to whoever had it
    ld   [y,x], ac
    ld   ac, [PS2_LSN]
    ld   PORT, y
    ld   PORT_RX, x
    ld   ac, [y,x]
    ld   PS2V, y
    ld   V_RES, x
    ld   [y,x], ac
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 2: kbd_scan (xC200-xC217 stay free: the bring-up ROM's marker for
; ROM section 6 is at xC210, gen_bringup.py)
; ============================================================
#addr PS2_CODE + 0x218

; ------------------------------------------------------------
; kbd_scan - take what the keyboard sent and buffer the new key presses
;   in:      -
;   out:     KBD_NOW + c = column c's rows, bit r = 0 while the key at
;            column c, row r is down; each key pressed since the last
;            scan is put in the key buffer as a character (kbd_getc)
;   changes: AC, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 350 with nothing new, about 800 more per key, about
;            110,000 when Caps Lock changes the keyboard's light
;   Uses 8 stack bytes.
;   Call it once per frame.  It takes the bytes in the receiver (a mouse
;   byte too, into the packet in hand), gives the line to the right
;   device (ps2_turn) and works out the presses.  The keyboard sends one
;   byte, then waits for the receiver to be re-armed, so a program that
;   only calls kbd_scan gets one byte per frame it listens to the
;   keyboard; wait_frames_io and ps2_poll take more.
;   Shift and Ctrl (either one) change the character; Caps Lock (key
;   K_CAPS) turns caps lock on and off.  Fn (either Windows key) +
;   Backspace = Delete (7F), Fn + Esc = ` (Shift: ~), Fn + Left = Home
;   (15).  Keys with no character (Shift, Ctrl, Alt, Fn) only show in
;   KBD_NOW.  The key numbers and characters are in docs/IO.md,
;   "Keyboard".
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
kz_take:
    ld   PORT, y                ; take what came (D7 = 0: a byte is ready)
    ld   PORT_RDY, x
    ld   [y,x], ac
    blt  kz_turn
    ld   LINK_LO, x             ; CALL ps2_take
    ld   kz_take, [x]
    ld   LINK_HI, x
    ld   kz_take >> 8, [x]
    ld   ps2_take >> 8, y
    jmp  ps2_take
kz_turn:
    ld   LINK_LO, x             ; CALL ps2_turn
    ld   kz_tn, [x]
    ld   LINK_HI, x
    ld   kz_tn >> 8, [x]
    ld   ps2_turn >> 8, y
    jmp  ps2_turn
kz_tn:
    ld   PS2V, y
    ld   V_KLAST, x             ; (menu_poll: polled this frame)
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   [KBD_FLAGS], ac
    and  KF_PS2, ac
    bne  kz_keys
    ld   V_RETRY, x             ; no PS/2 keyboard: look again?
    ld   [y,x], ac
    beq  kz_out
    ld   V_RCNT, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    bne  kz_out
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
    bra  kz_out
kz_keys:
    ld   V_ANY, x               ; any new press?
    ld   [y,x], ac
    beq  kz_caps
    ld   0, [y,x]
    clr  ac                     ; the new presses, key by key
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
kz_caps:
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
;   out:     a key's make code clears its bit in KBD_NOW and sets it in
;            V_NEW (kbd_scan turns that into the character); its break
;            code (F0 first) sets the KBD_NOW bit again.  Delete, Home
;            and ` put their character in the key buffer.  E1 (Pause)
;            and its 7 bytes, answers (FA, AA, EE, FE) and keys with no
;            place are skipped.
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
    add  KBD_NOW, x             ; X = its KBD_NOW byte
    ld   [IO_TMP], ac
    and  2, ac
    bne  kb_up
    ld   [T4], ac               ; pressed: KBD_NOW bit = 0, V_NEW bit = 1
    not
    and  [x], ac
    ld   ac, [x]
    ld   [IO_T3], ac
    add  V_NEW, x
    ld   PS2V, y
    ld   [T4], ac
    or   [y,x], ac
    ld   ac, [y,x]
    ld   V_ANY, x
    ld   1, [y,x]
    bra  kb_out
kb_up:
    ld   [T4], ac               ; released: KBD_NOW bit = 1
    or   [x], ac
    ld   ac, [x]
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
    ld   [KBD_NOW + (K_LSHIFT >> 3)], ac    ; `, or ~ with either Shift held
    and  1 << (K_LSHIFT & 7), ac
    beq  kb_tilde
    ld   [KBD_NOW + (K_RSHIFT >> 3)], ac
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
; Page 4: wait_frames_io, ps2_pause
; ============================================================
#addr PS2_CODE + 0x400

; ------------------------------------------------------------
; wait_frames_io - wait until AC new frames have started, taking what
;                  the mouse or the PS/2 keyboard sends meanwhile
;   in:      AC = frames, 1-255 (0 waits 256)
;   out:     as wait_frames.  Bytes the devices sent are taken: mouse
;            packets add up for mouse_poll (which then returns 1 without
;            waiting), PS/2 keys go into KBD_NOW and V_NEW for kbd_scan.
;            The line is given to the right device at each frame start
;            (ps2_turn) and left with it.
;   changes: AC, X, Y, T0-T6, IO_T0-IO_T3, IO_TMP
;   clocks:  AC frames, like wait_frames
;   Uses 4 stack bytes.
;   Use it in place of wait_frames: the time the program would spin in
;   wait_frames takes the bytes as they come, so a mouse packet or a key
;   is never waiting on a frame.  With neither device it is wait_frames.
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
    ld   [MOUSE_ST], ac         ; mouse_poll: this wait polled
    or   MS_WAITED, ac
    ld   ac, [MOUSE_ST]
    ld   0x50, y                ; start from the line now
    ld   [y,x], ac
    ld   ac, [LINE_LAST]
wi_turn:
    ld   LINK_LO, x             ; CALL ps2_turn
    ld   wi_loop, [x]
    ld   LINK_HI, x
    ld   wi_loop >> 8, [x]
    ld   ps2_turn >> 8, y
    jmp  ps2_turn
wi_loop:
    ld   PORT, y                ; a byte ready (D7 = 0): take it
    ld   PORT_RDY, x
    ld   [y,x], ac
    blt  wi_line
    ld   LINK_LO, x             ; CALL ps2_take
    ld   wi_loop, [x]
    ld   LINK_HI, x
    ld   wi_loop >> 8, [x]
    ld   ps2_take >> 8, y
    jmp  ps2_take
wi_line:
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
    bne  wi_turn                ; another frame: whose turn?
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave
wi_same:
    ld   [T0], ac
    ld   ac, [LINE_LAST]
    bra  wi_loop

; ------------------------------------------------------------
; ps2_pause - hold both devices off for a routine that changes the latch
;   in:      PS2_LSN
;   out:     the byte in the receiver, if any, is taken (ps2_take); the
;            latch = P_IDLE and the receiver re-armed.  PS2_LSN is kept:
;            write it to PORT_RX afterwards to go on listening.
;   changes: AC, X, Y, T0-T6, IO_T3, IO_TMP
;   clocks:  about 2,700 (the 100 us hold) with a device on the line,
;            about 150 with none; plus a byte's handling; up to about
;            2 ms more when the mouse is half way through a packet
;   Uses 2 stack bytes.  pad_read and sd_init (the start clocks) change
;   the latch bits that hold the clocks; the edge a clock line makes
;   when it is let go or held reaches the receiver, so it is held and
;   re-armed around them.  The SD data transfers (SCK, MOSI) don't touch
;   those bits and need no pause.
;   A device whose clock is held in the middle of a byte gives the byte
;   up and sends its whole chunk again later (a mouse: the three-byte
;   packet), but only if it sees the hold: PS/2 promises that for a hold
;   of 100 us, so the pause keeps the hold that long before it returns
;   (pad_read frees the mouse's clock again while it clocks the pads,
;   /CS being the same latch bit; the mouse waits 50 us before it sends,
;   longer than pad_read takes).  A shorter hold could pass unseen while
;   the receiver, re-armed by the write, took the rest of the byte for a
;   new one.  With part of a packet in hand and the mouse on the line,
;   the pause first waits for the byte the mouse is sending (up to about
;   2 ms) and takes it, so that the packet in hand is not sent again:
;   the mouse is then between bytes and simply goes on when the line
;   comes back.  A keyboard sending a two-byte code again does no harm
;   (kbd_byte takes E0 or F0 twice as once).
; ------------------------------------------------------------
ps2_pause:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    clr  ac                     ; the wait: about 2 ms
    ld   ac, [T5]
    ld   3, ac
    ld   ac, [T6]
pz_look:
    ld   PORT, y
    ld   PORT_RDY, x
    ld   [y,x], ac
    blt  pz_none                ; D7 = 1: nothing to take
    ld   LINK_LO, x             ; CALL ps2_take, then hold
    ld   pz_hold, [x]
    ld   LINK_HI, x
    ld   pz_hold >> 8, [x]
    ld   ps2_take >> 8, y
    jmp  ps2_take
pz_none:
    ld   PS2V, y                ; the mouse half way through a packet
    ld   V_MPI, x               ; and on the line: wait for its byte
    ld   [y,x], ac
    beq  pz_hold
    ld   [PS2_LSN], ac
    xor  P_FREE, ac
    bne  pz_hold
    ld   [T5], ac
    dec
    ld   ac, [T5]
    bne  pz_look
    ld   [T6], ac
    dec
    ld   ac, [T6]
    bne  pz_look
pz_hold:
    ld   PORT, y
    ld   PORT_RX, x
    ld   P_IDLE, [y,x]          ; both held, re-armed
    ld   [PS2_LSN], ac          ; a device was on the line: keep the hold
    xor  P_IDLE, ac             ; at least 100 us, so that one in the
    beq  pz_out                 ; middle of a byte is sure to give it up
    ld   HOLD_N, ac
    ld   ac, [T5]
pz_wait:
    ld   [T5], ac
    dec
    ld   ac, [T5]
    bne  pz_wait
pz_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; I/O page 1: ps2_poll, ps2_cmd, kbd_lights
; ============================================================
#addr IO_CODE + 0x100

; ------------------------------------------------------------
; ps2_poll - take what the devices sent and give the line to the right one
;   in:      -
;   out:     as ps2_take and ps2_turn
;   changes: AC, X, Y, T0-T6, IO_T0-IO_T3, IO_TMP
;   clocks:  about 150 with nothing ready, plus each byte's handling
;   Uses 2 stack bytes.  Call it from a program's loop as often as you
;   like (it costs nothing when nothing came) to take the bytes as they
;   come; kbd_scan and mouse_poll do the same once per frame, and
;   wait_frames_io all the time it waits.
; ------------------------------------------------------------
ps2_poll:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
pl_loop:
    ld   PORT, y
    ld   PORT_RDY, x
    ld   [y,x], ac
    blt  pl_turn                ; D7 = 1: nothing (more)
    ld   LINK_LO, x             ; CALL ps2_take
    ld   pl_loop, [x]
    ld   LINK_HI, x
    ld   pl_loop >> 8, [x]
    ld   ps2_take >> 8, y
    jmp  ps2_take
pl_turn:
    ld   LINK_LO, x             ; CALL ps2_turn
    ld   pl_tn, [x]
    ld   LINK_HI, x
    ld   pl_tn >> 8, [x]
    ld   ps2_turn >> 8, y
    jmp  ps2_turn
pl_tn:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ------------------------------------------------------------
; ps2_cmd - send a byte to the listened device and read its acknowledge
;   in:      AC = the byte; PS2_LSN = the device's latch value (P_FREE
;            or P_KFREE), both devices held (ps2_pause)
;   out:     AC = 0 acknowledged (FA), 1 the device did not clock, 2 any
;            other answer or none within about 25 ms.  The device is let
;            go, the receiver armed: its next byte (a reset's AA) can be
;            read with ps2_rx.
;   changes: X, Y, T0-T3, IO_T0-IO_T2
;   clocks:  about 55,000 (2.2 ms); about 400,000 (16 ms) with no device
;   Uses 4 stack bytes.
; ------------------------------------------------------------
ps2_cmd:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   LINK_LO, x             ; CALL ps2_tx
    ld   pc_bt, [x]
    ld   LINK_HI, x
    ld   pc_bt >> 8, [x]
    ld   ps2_tx >> 8, y
    jmp  ps2_tx
pc_bt:
    bne  pc_out                 ; 1 or 2
    ld   100, ac                ; the answer within about 25 ms
    ld   ac, [IO_T1]
    clr  ac
    ld   ac, [IO_T2]
    ld   LINK_LO, x             ; CALL ps2_rx
    ld   pc_br, [x]
    ld   LINK_HI, x
    ld   pc_br >> 8, [x]
    ld   ps2_rx >> 8, y
    jmp  ps2_rx
pc_br:
    bne  pc_e2
    ld   [T0], ac
    xor  0xFA, ac
    beq  pc_out                 ; AC = 0
pc_e2:
    ld   2, ac
pc_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ------------------------------------------------------------
; kbd_lights - set the PS/2 keyboard's Caps Lock light to caps lock
;   in:      KBD_FLAGS bit 0 = caps lock
;   out:     AC = 0 done: KBD_FLAGS bit 2 = bit 0; 1 no keyboard, 2 a
;            wrong answer.  Latch = PS2_LSN again.
;   changes: as kbd_cmd
;   Uses 8 stack bytes.
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
; I/O page B: a byte to a device
; ============================================================
#addr IO_CODE + 0xB00

; ------------------------------------------------------------
; ps2_tx - send one byte to a PS/2 device (the mouse or the keyboard)
;   in:      AC = the byte; PS2_LSN = the device's latch value (P_FREE
;            the mouse, P_KFREE the keyboard)
;   out:     AC = 0 sent (the device clocked all 11 bits), 1 the device
;            did not clock (none there), 2 its clock stopped half way.
;            The latch = PS2_LSN with the receiver armed, so the
;            device's answer comes into the receiver (ps2_rx).
;   changes: X, Y, T0-T3, IO_T0, IO_T1
;   clocks:  about 30,000 (1.2 ms)
;   Holds both clocks low for about 120 us, pulls DATA low and lets the
;   device's clock go (the other device's clock stays held, so it sees
;   no request to send): the device then clocks the byte in.  The host
;   changes DATA while CLK is low; the device reads it when CLK goes
;   high.  CLK is RXCLK, D5 of x5200.  The receiver counts the device's
;   clocks too, so every bit is written to PORT_RX, which re-arms it:
;   it never reaches the 11 clocks that would hold the device off.
;   The device's acknowledge bit (DATA low on the 11th clock) is not
;   read: the answer byte tells.
; ------------------------------------------------------------
ps2_tx:
    ld   ac, [T0]
    ld   [PS2_LSN], ac          ; T3 = the latch with the device's clock
    and  0xF7, ac               ; free and DATA low
    ld   ac, [T3]
    ld   PORT, y
    ld   PORT_RX, x
    ld   P_IDLE, [y,x]          ; both clocks low (they already are, at rest)
    ld   125, ac                ; about 120 us
pt_hold:
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    dec
    bne  pt_hold
    ld   P_IDLE & 0xF7, [y,x]   ; DATA low too
    ld   [T3], ac               ; this clock free: request to send
    ld   ac, [y,x]
    clr  ac                     ; T1 = 1s sent, for the parity
    ld   ac, [T1]
    ld   10, ac                 ; 8 data bits, parity, stop
    ld   ac, [T2]
    ld   0, ac                  ; the first clock can take up to 15 ms
    ld   ac, [IO_T0]
    ld   64, ac
    ld   ac, [IO_T1]
pt_bit:
    clr  x                      ; wait for CLK low (RXCLK, D5)
    ld   [y,x], ac
    and  0x20, ac
    beq  pt_lo
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  pt_bit
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  pt_bit
    ld   1, ac                  ; the device never clocked
    bra  pt_out
pt_lo:
    ld   PORT_RX, x             ; the bit: a write re-arms the receiver
    ld   [T2], ac               ; which bit?
    xor  2, ac
    beq  pt_par
    xor  3, ac                  ; (T2 = 1: the stop bit)
    beq  pt_one
    ld   [T0], ac               ; a data bit, LSB first
    and  1, ac
    beq  pt_zero
    ld   [T1], ac
    xor  1, ac
    ld   ac, [T1]
pt_one:
    ld   [T3], ac               ; DATA 1 (free)
    or   0x08, ac
    ld   ac, [y,x]
    bra  pt_shift
pt_par:
    ld   [T1], ac               ; odd parity: 1 when the data had an even count
    and  1, ac
    bne  pt_zero
    ld   [T3], ac
    or   0x08, ac
    ld   ac, [y,x]
    bra  pt_shift
pt_zero:
    ld   [T3], ac               ; DATA 0
    ld   ac, [y,x]
pt_shift:
    ld   [T0], ac
    shr  ac
    ld   ac, [T0]
    clr  ac                     ; wait for CLK high
    ld   ac, [IO_T0]
pt_wh:
    clr  x
    ld   [y,x], ac
    and  0x20, ac
    bne  pt_hi
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  pt_wh
    ld   2, ac
    bra  pt_out
pt_hi:
    clr  ac                     ; the next clock comes within about 0.1 ms
    ld   ac, [IO_T0]
    ld   1, ac
    ld   ac, [IO_T1]
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  pt_bit
pt_ack:                         ; the 11th clock: the device's acknowledge
    ld   [y,x], ac
    and  0x20, ac
    beq  pt_ackl
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  pt_ack
    ld   2, ac
    bra  pt_out
pt_ackl:
    clr  ac                     ; and high again
    ld   ac, [IO_T0]
pt_ackh:
    ld   [y,x], ac
    and  0x20, ac
    bne  pt_done
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  pt_ackh
    ld   2, ac
    bra  pt_out
pt_done:
    ld   PORT_RX, x             ; DATA free, the receiver armed: the
    ld   [PS2_LSN], ac          ; answer comes
    ld   ac, [y,x]
    clr  ac
pt_out:
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; I/O page C: a byte from the receiver, the mouse's poll
; ============================================================
#addr IO_CODE + 0xC00

; ------------------------------------------------------------
; ps2_rx - wait for a byte from the listened device
;   in:      PS2_LSN = the device, let go, the receiver armed;
;            IO_T2:IO_T1 = how long to wait, in steps of about 0.28 ms
;            (IO_T1 = 0 counts as 256 steps)
;   out:     AC = 0 and T0 = the byte (the receiver re-armed), or AC = 1
;            nothing came
;   changes: X, Y, T0, IO_T0-IO_T2
;   clocks:  about 60 once the byte is there, plus the wait
;   The commands' answers come this way; the keys and packets go
;   through ps2_take.
; ------------------------------------------------------------
ps2_rx:
    clr  ac
    ld   ac, [IO_T0]
    ld   PORT, y
rx_w:
    ld   PORT_RDY, x            ; 28 clocks a try
    ld   [y,x], ac
    blt  rx_wait                ; D7 = 1: not yet
    bra  rx_got
rx_wait:
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  rx_w
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  rx_w
    ld   [IO_T2], ac
    beq  rx_none
    dec
    ld   ac, [IO_T2]
    bra  rx_w
rx_none:
    ld   1, ac                  ; nothing came
    ld   [LINK_HI], y
    jmp  [LINK_LO]
rx_got:
    ld   PORT_RX, x
    ld   [y,x], ac              ; the byte
    ld   ac, [T0]
    ld   [PS2_LSN], ac          ; re-arm
    ld   ac, [y,x]
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; mouse_poll - take the mouse's movement since the last poll
;   in:      -
;   out:     AC = 1 and MOUSE_B, MOUSE_DX, MOUSE_DY set from the packets
;            that came since the last poll (the movement added up, held
;            to -127..127), 0 nothing new.
;            MOUSE_B bit 0 = left, 1 = right, 2 = middle button down.
;            MOUSE_DX = right, MOUSE_DY = down, -127 to 127 (signed).
;   changes: X, Y, T0-T6, IO_T0-IO_T3, IO_TMP
;   clocks:  about 250 with nothing new or after wait_frames_io; about
;            2,000 more with a packet, plus up to about 2 ms waiting
;            for the rest of a packet that is half in (below)
;   Uses 4 stack bytes.  Call it once per frame.  It takes the bytes in
;   the receiver (ps2_take; a keyboard byte too).  The mouse sends one
;   byte, then waits for the receiver to be re-armed, so a packet that
;   is half in when the poll runs would take two more frames to arrive:
;   while the mouse has the line the poll waits for the rest, up to
;   about 2 ms a byte.  Not after wait_frames_io, which has taken the
;   bytes as they came (MOUSE_ST bit 6): then the poll only hands over
;   what came.  Then the line goes to the right device (ps2_turn).
; ------------------------------------------------------------
mouse_poll:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   [MOUSE_ST], ac
    blt  mq_run
    clr  ac                     ; not running
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave
mq_run:
    and  MS_WAITED, ac          ; IO_T3 = 0: wait for the rest of a packet
    ld   ac, [IO_T3]
    ld   [MOUSE_ST], ac
    and  0xFF ^ MS_WAITED, ac
    ld   ac, [MOUSE_ST]
mq_fresh:
    clr  ac                     ; about 2 ms a byte
    ld   ac, [IO_T0]
    ld   3, ac
    ld   ac, [IO_T1]
mq_take:
    ld   PORT, y
    ld   PORT_RDY, x
    ld   [y,x], ac
    blt  mq_none                ; D7 = 1: nothing ready
    ld   LINK_LO, x             ; CALL ps2_take
    ld   mq_fresh, [x]
    ld   LINK_HI, x
    ld   mq_fresh >> 8, [x]
    ld   ps2_take >> 8, y
    jmp  ps2_take
mq_none:
    ld   [IO_T3], ac            ; after wait_frames_io: no waiting
    bne  mq_turn
    ld   PS2V, y                ; half a packet in, the mouse on the line?
    ld   V_MPI, x
    ld   [y,x], ac
    beq  mq_turn
    ld   [PS2_LSN], ac
    xor  P_FREE, ac
    bne  mq_turn
    ld   [IO_T0], ac            ; wait for the rest
    dec
    ld   ac, [IO_T0]
    bne  mq_take
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  mq_take
mq_turn:
    ld   LINK_LO, x             ; CALL ps2_turn
    ld   mq_tn, [x]
    ld   LINK_HI, x
    ld   mq_tn >> 8, [x]
    ld   ps2_turn >> 8, y
    jmp  ps2_turn
mq_tn:
    ld   PS2V, y
    ld   V_MNEW, x
    ld   [y,x], ac
    beq  mq_out                 ; nothing new: AC = 0
    ld   0, [y,x]
    ld   V_MDX, x               ; hand the movement over
    ld   [y,x], ac
    ld   ac, [MOUSE_DX]
    ld   0, [y,x]
    ld   V_MDY, x
    ld   [y,x], ac
    ld   ac, [MOUSE_DY]
    ld   0, [y,x]
    ld   V_MB, x
    ld   [y,x], ac
    ld   ac, [MOUSE_B]
    ld   1, ac
mq_out:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; I/O page D: mouse start-up
; ============================================================
#addr IO_CODE + 0xD00

; ------------------------------------------------------------
; mouse_init - reset the PS/2 mouse and start it reporting
;   in:      -
;   out:     AC = 0 the mouse is running (MOUSE_ST bit 7 = 1), 1 no
;            mouse, 2 the mouse answered wrongly.  The line goes to the
;            right device (ps2_turn).
;   changes: X, Y, T0-T6, IO_T0-IO_T3, IO_TMP, MOUSE_B, MOUSE_DX,
;            MOUSE_DY
;   clocks:  up to about 25,000,000 (1 s) while the mouse tests itself
;            after the reset; 0.5 s is usual
;   Uses 6 stack bytes.  Sends FF (reset): FA, then AA 00 when its self
;   test is done; then F4 (reporting on): FA.  The mouse then streams
;   packets, which mouse_poll takes.
; ------------------------------------------------------------
mouse_init:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
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
    ld   ac, [MOUSE_ST]
    ld   ac, [MOUSE_B]
    ld   ac, [MOUSE_DX]
    ld   ac, [MOUSE_DY]
    ld   PS2V, y
    ld   7, ac
mi_clr:
    add  V_MPI, x               ; no packet in hand, no movement
    ld   0, [y,x]
    sub  1, ac
    bcc  mi_clr
    ld   V_SAVE, x              ; whose line it is
    ld   [PS2_LSN], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL ps2_pause: take, hold both
    ld   mi_p1, [x]
    ld   LINK_HI, x
    ld   mi_p1 >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
mi_p1:
    ld   P_FREE, ac             ; the mouse's line
    ld   ac, [PS2_LSN]
    ld   0xFF, ac               ; reset
    ld   LINK_LO, x             ; CALL ps2_cmd
    ld   mi_br, [x]
    ld   LINK_HI, x
    ld   mi_br >> 8, [x]
    ld   ps2_cmd >> 8, y
    jmp  ps2_cmd
mi_br:
    bne  mi_res                 ; 1 or 2
    clr  ac                     ; AA within about 1 s
    ld   ac, [IO_T1]
    ld   16, ac
    ld   ac, [IO_T2]
    ld   LINK_LO, x             ; CALL ps2_rx
    ld   mi_baa, [x]
    ld   LINK_HI, x
    ld   mi_baa >> 8, [x]
    ld   ps2_rx >> 8, y
    jmp  ps2_rx
mi_baa:
    bne  mi_e2
    ld   [T0], ac
    xor  0xAA, ac
    bne  mi_e2
    ld   100, ac                ; then 00 (the device ID)
    ld   ac, [IO_T1]
    clr  ac
    ld   ac, [IO_T2]
    ld   LINK_LO, x             ; CALL ps2_rx
    ld   mi_bid, [x]
    ld   LINK_HI, x
    ld   mi_bid >> 8, [x]
    ld   ps2_rx >> 8, y
    jmp  ps2_rx
mi_bid:
    bne  mi_e2
    ld   [T0], ac
    bne  mi_e2
    ld   0xF4, ac               ; reporting on
    ld   LINK_LO, x             ; CALL ps2_cmd
    ld   mi_bf4, [x]
    ld   LINK_HI, x
    ld   mi_bf4 >> 8, [x]
    ld   ps2_cmd >> 8, y
    jmp  ps2_cmd
mi_bf4:
    bne  mi_res
    ld   MS_RUN, ac             ; running
    ld   ac, [MOUSE_ST]
    clr  ac
    bra  mi_res
mi_e2:
    ld   2, ac
mi_res:
    ld   PS2V, y
    ld   V_RES, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL ps2_pause: take what it sent after
    ld   mi_p2, [x]
    ld   LINK_HI, x
    ld   mi_p2 >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
mi_p2:
    ld   PS2V, y
    ld   V_SAVE, x              ; the line back, then to the right device
    ld   [y,x], ac
    ld   ac, [PS2_LSN]
    ld   PORT, y
    ld   PORT_RX, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL ps2_turn
    ld   mi_tn, [x]
    ld   LINK_HI, x
    ld   mi_tn >> 8, [x]
    ld   ps2_turn >> 8, y
    jmp  ps2_turn
mi_tn:
    ld   PS2V, y
    ld   V_RES, x
    ld   [y,x], ac
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; I/O page E: a byte from the mouse
; ============================================================
#addr IO_CODE + 0xE00

; ------------------------------------------------------------
; mouse_byte - add one byte from the mouse to the packet in hand
;   in:      T0 = the byte
;   out:     the first byte (bit 3 set, else it is dropped) and the
;            second are kept; the third completes the packet: its
;            buttons go to V_MB, its movement (9 bits each way, held to
;            -127..127, Y turned so down is positive) is added to V_MDX
;            and V_MDY (held to -127..127), V_MNEW = 1.
;   changes: AC, X, Y, T0-T6, IO_TMP
;   clocks:  about 60 for the first two bytes, about 200 for the third
;   A leaf (ps2_take jumps here; it returns for it).
; ------------------------------------------------------------
mouse_byte:
    ld   PS2V, y
    ld   V_MPI, x
    ld   [y,x], ac
    bne  mz_n
    ld   [T0], ac               ; the first byte: bit 3 is always 1
    and  0x08, ac
    beq  mz_ret
    ld   V_MPK, x
    ld   [T0], ac
    ld   ac, [y,x]
    ld   V_MPF, x               ; the frame it came in (ps2_turn)
    ld   [FRAME_LO], ac
    ld   ac, [y,x]
    ld   V_MPI, x
    ld   1, [y,x]
mz_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]
mz_n:
    xor  1, ac
    bne  mz_third
    ld   V_MPK + 1, x           ; the second byte: X
    ld   [T0], ac
    ld   ac, [y,x]
    ld   V_MPI, x
    ld   2, [y,x]
    bra  mz_ret
mz_third:
    ld   V_MPI, x               ; the third: Y; the packet is complete
    ld   0, [y,x]
    ld   [T0], ac
    ld   ac, [T2]               ; T2 = Y
    ld   V_MPK, x
    ld   [y,x], ac
    ld   ac, [T1]               ; T1 = the first byte
    and  0x07, ac
    ld   V_MB, x
    ld   ac, [y,x]
    ld   V_MPK + 1, x
    ld   [y,x], ac
    ld   ac, [T0]               ; T0 = X
    ld   0x10, ac               ; the X pass: sign bit 4, overflow bit 6
    ld   ac, [T4]
    ld   0x40, ac
    ld   ac, [T5]
    ld   V_MDX, ac
    ld   ac, [T6]
    clr  ac
    ld   ac, [T3]               ; T3 = 0 X pass, 1 Y pass
mz_dec:
    ld   [T1], ac               ; 9 bits: the sign, the byte; held to +-127
    and  [T4], ac
    bne  mz_neg
    ld   [T1], ac
    and  [T5], ac
    bne  mz_p127                ; overflow
    ld   [T0], ac
    blt  mz_p127                ; 128-255
    bra  mz_have
mz_neg:
    ld   [T1], ac
    and  [T5], ac
    bne  mz_n127                ; overflow
    ld   [T0], ac
    blt  mz_nn
    bra  mz_n127                ; 00-7F: -256 to -129
mz_nn:
    xor  0x80, ac
    beq  mz_n127                ; -128
    ld   [T0], ac
    bra  mz_have
mz_n127:
    ld   0x81, ac
    bra  mz_have
mz_p127:
    ld   0x7F, ac
mz_have:
    ld   ac, [T0]               ; T0 = the movement
    ld   [T3], ac
    beq  mz_add
    ld   [T0], ac               ; Y: down is positive on the screen
    xor  0xFF, ac
    add  1, ac
    ld   ac, [T0]
mz_add:
    ld   [T6], x                ; add it to V_MDX or V_MDY, held to +-127
    ld   [y,x], ac
    ld   ac, [IO_TMP]           ; IO_TMP = the sum so far
    add  [T0], ac
    ld   ac, [T5]               ; T5 = the new sum
    ld   [IO_TMP], ac
    xor  [T0], ac
    blt  mz_store               ; signs differ: it fits
    ld   [IO_TMP], ac
    xor  [T5], ac
    blt  mz_sat                 ; the sign turned: too far
mz_store:
    ld   [T5], ac
    ld   ac, [y,x]
    bra  mz_next
mz_sat:
    ld   [IO_TMP], ac
    blt  mz_satn
    ld   0x7F, ac
    bra  mz_sat1
mz_satn:
    ld   0x81, ac
mz_sat1:
    ld   ac, [y,x]
mz_next:
    ld   [T3], ac
    bne  mz_done
    ld   1, ac                  ; the Y pass: sign bit 5, overflow bit 7
    ld   ac, [T3]
    ld   V_MPK, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [T2], ac
    ld   ac, [T0]
    ld   0x20, ac
    ld   ac, [T4]
    ld   0x80, ac
    ld   ac, [T5]
    ld   V_MDY, ac
    ld   ac, [T6]
    bra  mz_dec
mz_done:
    ld   V_MNEW, x
    ld   1, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]


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
