; ============================================================
; placard_io.asm - Placard I/O drivers: the key buffer, SNES pads, SD card
; (the PS/2 keyboard and mouse are in placard_ps2.asm)
; ============================================================
;
; Drivers for the shared port at x5200 (docs/IO.md).  placard_lib.asm
; includes this file, so a program that includes the standard library
; has them too.  They use the library's calling convention (docs/LIBRARY.md)
; and the I/O zero page bytes xA0-xBF (zeropage.asm).
;
; The code sits at IO_CODE (xDC00-xEBFF, set in placard_lib.asm), part of
; the library block at the top of the ROM, and runs in place.
;
; ------------------------------------------------------------
; THE SHARED PORT (x5200-x52FF)
; ------------------------------------------------------------
; Write (any address): the port latch, five registers in the port PLD
; (rev 04):
;     bit 0  SCK, and the pads' CLOCK
;     bit 1  MOSI, and the pads' LATCH
;     bit 2  SD /CS.  0 also holds the mouse's PS/2 CLK line low (the
;            mouse can't send while it is low)
;     bit 3  0 holds the PS/2 DATA line low (one line, shared by the
;            mouse and the PS/2 keyboard)
;     bit 4  0 holds the PS/2 keyboard's CLK line low
;     bits 7:5  not stored (software writes 1s)
;     A write to x5202 or x5203 also re-arms the PS/2 receiver PLD
;     (placard_ps2.asm).
; Read x5200: D7 = SD MISO, D5 = RXCLK (the free PS/2 device's clock).
; Read x5201: D7 = pad 1 DATA, D6 = pad 2 DATA (0 = button down),
;     D5 = RXCLK.
; Read x5202: the byte the PS/2 receiver holds; x5203: D7 = 1 while a
;     byte is ready.  The other bits read 1 (pull-ups): mask them.
;
; The pads, the SD card, the mouse and the PS/2 keyboard share the port.
; The PS/2 device that may send is the one whose clock the latch lets
; go: PS2_LSN holds that latch value (P_IDLE neither, P_FREE the mouse,
; P_KFREE the keyboard; placard_ps2.asm) and every routine here leaves
; the latch at PS2_LSN.  The pads and the SD card's start clocks change
; the bits that hold the clocks, so those routines hold both devices
; off first (ps2_pause) and let the listened one go again after; the SD
; transfers only toggle SCK and MOSI.
;
; Date: 10/25/2026
; ============================================================

PORT      = 0x52        ; the shared port's page
PORT_RX   = 0x02        ; x5202: the PS/2 receiver's byte; a write re-arms it
PORT_RDY  = 0x03        ; x5203: D7 = a byte is ready; a write re-arms it too
P_IDLE    = 0xEB        ; latch at rest: both PS/2 clocks held, PS/2 DATA free, /CS low, MOSI 1, SCK 1
P_FREE    = 0xEF        ; the same with /CS high (SD deselected, the mouse's clock free)
P_KFREE   = 0xFB        ; the same with the PS/2 keyboard's clock free (/CS low, the mouse held)

; key numbers (column * 8 + row) the keyboard driver treats specially
K_CTRL    = 28          ; column 3, row 4 (left Ctrl)
K_LSHIFT  = 41          ; column 5, row 1
K_RSHIFT  = 52          ; column 6, row 4
K_CAPS    = 54          ; column 6, row 6
K_FN      = 55          ; column 6, row 7
K_RCTRL   = 59          ; column 7, row 3
K_BKSP    = 13          ; column 1, row 5
K_LEFT    = 61          ; column 7, row 5


; ============================================================
; Page 0: port, key buffer, pads
; ============================================================
#addr IO_CODE

; ------------------------------------------------------------
; port_init - put the port at rest and clear the keyboard state
;   in:      -
;   out:     latch = PS2_LSN = P_IDLE, the PS/2 receiver armed; no keys
;            down, key buffer empty, caps lock off, SD card not
;            initialized, mouse not initialized; looks for a PS/2
;            keyboard (ps2_reset, placard_ps2.asm): KBD_FLAGS bit 1 = 1
;            if one answered
;   changes: AC, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP, PS2_LSN
;   clocks:  about 400,000 (16 ms) with no PS/2 keyboard, about 120,000
;            (5 ms) with one
;   Uses 10 stack bytes.  Call it once at the start of a program that
;   uses the port.  With no PS/2 keyboard, kbd_scan asks again a few
;   times in the next 2 seconds (a keyboard is still testing itself
;   for up to about 1 s after power-up).
; ------------------------------------------------------------
port_init:
    ld   PORT, y
    ld   PORT_RX, x
    ld   P_IDLE, [y,x]
    ld   7, ac
pi_loop:
    add  KBD_NOW, x             ; X = KBD_NOW + AC, AC = 7 ... 0
    ld   0xFF, [x]              ; every key up
    sub  1, ac
    bcc  pi_loop                ; no borrow, AC was not 0
    clr  ac
    ld   ac, [KBD_HEAD]
    ld   ac, [KBD_TAIL]
    ld   ac, [KBD_FLAGS]
    ld   ac, [SD_FLAGS]
    ld   ac, [MOUSE_ST]
    ld   ps2_reset >> 8, y      ; the PS/2 keyboard's state, and look for one
    jmp  ps2_reset

; ------------------------------------------------------------
; kbd_getc - take the next character from the key buffer
;   in:      -
;   out:     AC = character, or 0 if the buffer is empty
;   changes: X
;   clocks:  20 (empty), 39
;   kbd_scan fills the buffer.
; ------------------------------------------------------------
kbd_getc:
    ld   [KBD_TAIL], ac
    xor  [KBD_HEAD], ac
    beq  kg_ret                 ; empty: AC = 0
    ld   [KBD_TAIL], ac
    add  KBD_BUF, x
    inc
    and  7, ac
    ld   ac, [KBD_TAIL]
    ld   [x], ac
kg_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; pad_read - read both SNES pads
;   in:      -
;   out:     R1:R0 = pad 1, R3:R2 = pad 2: bit n = 1 while button n is
;            down.  0 B, 1 Y, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left,
;            7 Right, 8 A, 9 X, 10 L, 11 R; bits 12-15 are 0 for a pad.
;            An empty socket reads 0000 (its pull-up reads as no
;            buttons); a SNES mouse reads bits 12-15 as 1000.
;   changes: AC, X, Y, T0-T6, IO_T3, IO_TMP
;   clocks:  about 3,700 (32 us with /CS high, after ps2_pause's 100 us
;            hold), plus a PS/2 byte's handling when one was ready
;   Uses 4 stack bytes.  The PS/2 devices are held off while the pads
;   are clocked (ps2_pause) and the listened one let go again after.
;   The pads' CLOCK idles high and is held low about 0.2 us per bit.
; ------------------------------------------------------------
pad_read:
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
    ld   LINK_LO, x             ; CALL ps2_pause
    ld   pr_pz, [x]
    ld   LINK_HI, x
    ld   pr_pz >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
pr_pz:
    ld   PORT, y
    ld   1, x                   ; odd address: reads return the pads
    ld   P_FREE, [y,x]          ; LATCH high: the pads load
    clr  ac
    ld   ac, [R0]
    ld   ac, [R1]
    ld   ac, [R2]
    ld   ac, [R3]
    ld   0xED, [y,x]            ; LATCH low: bit 0 (B) on DATA
    ld   1, ac
pr_lo:
    ld   ac, [T0]               ; T0 = 1 << bit
    ld   [y,x], ac
    ld   ac, [T1]
    blt  pr_l1                  ; pad 1 DATA high: up
    ld   [R0], ac
    or   [T0], ac
    ld   ac, [R0]
pr_l1:
    ld   [T1], ac
    and  0x40, ac
    bne  pr_l2                  ; pad 2 DATA high: up
    ld   [R2], ac
    or   [T0], ac
    ld   ac, [R2]
pr_l2:
    ld   0xEC, [y,x]            ; CLOCK low
    nop
    ld   0xED, [y,x]            ; CLOCK high: the next bit
    ld   [T0], ac
    shl
    bne  pr_lo
    ld   1, ac
pr_hi:
    ld   ac, [T0]
    ld   [y,x], ac
    ld   ac, [T1]
    blt  pr_h1
    ld   [R1], ac
    or   [T0], ac
    ld   ac, [R1]
pr_h1:
    ld   [T1], ac
    and  0x40, ac
    bne  pr_h2
    ld   [R3], ac
    or   [T0], ac
    ld   ac, [R3]
pr_h2:
    ld   0xEC, [y,x]
    nop
    ld   0xED, [y,x]
    ld   [T0], ac
    shl
    bne  pr_hi
    ld   PORT, y                ; the PS/2 line back to whoever had it
    ld   PORT_RX, x
    ld   [PS2_LSN], ac
    ld   ac, [y,x]
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 2: one key press to a character
; ============================================================
#addr IO_CODE + 0x200

; ------------------------------------------------------------
; kbd_key - put the character of a key press in the key buffer
;   in:      AC = key number (column * 8 + row), KBD_NOW for Shift,
;            Ctrl and Fn
;   out:     the character in the key buffer (dropped if it is full,
;            nothing for a key with no character); caps lock turned
;            on or off for K_CAPS
;   changes: AC, X, Y, IO_T3, IO_TMP
;   clocks:  about 90-140
;   kbd_scan calls it; a program can call it to type a key itself.
; ------------------------------------------------------------
kbd_key:
    ld   ac, [IO_TMP]
    xor  K_CAPS, ac
    bne  kk_nc
    ld   [KBD_FLAGS], ac        ; Caps Lock
    xor  1, ac
    ld   ac, [KBD_FLAGS]
    bra  kk_ret
kk_nc:
    ld   [KBD_NOW + (K_FN >> 3)], ac
    and  1 << (K_FN & 7), ac
    bne  kk_nofn
    ld   0x7F, ac               ; Fn held: Fn + Backspace = Delete
    ld   ac, [IO_T3]
    ld   [IO_TMP], ac
    xor  K_BKSP, ac
    beq  kk_put
    ld   0x15, ac               ; Fn + Left = Home
    ld   ac, [IO_T3]
    ld   [IO_TMP], ac
    xor  K_LEFT, ac
    beq  kk_put
    ld   [IO_TMP], ac
    bne  kk_nofn                ; not Esc: as without Fn
    ld   0x60, ac               ; Fn + Esc = `
    ld   ac, [IO_T3]
    ld   [KBD_NOW + (K_LSHIFT >> 3)], ac
    and  1 << (K_LSHIFT & 7), ac
    beq  kk_tilde
    ld   [KBD_NOW + (K_RSHIFT >> 3)], ac
    and  1 << (K_RSHIFT & 7), ac
    bne  kk_put
kk_tilde:
    ld   0x7E, ac               ; Shift: ~
    ld   ac, [IO_T3]
    bra  kk_put
kk_nofn:
    ld   [KBD_NOW + (K_LSHIFT >> 3)], ac
    and  1 << (K_LSHIFT & 7), ac
    beq  kk_sh
    ld   [KBD_NOW + (K_RSHIFT >> 3)], ac
    and  1 << (K_RSHIFT & 7), ac
    beq  kk_sh
    ld   [IO_TMP], ac           ; no Shift: kbd_map
    bra  kk_tb
kk_sh:
    ld   [IO_TMP], ac           ; Shift: kbd_map + 64
    or   0x40, ac
kk_tb:
    ld   ac, x
    ld   kbd_map >> 8, y
    ld   [y,x], ac
    beq  kk_ret                 ; no character
    ld   ac, [IO_T3]
    ld   [KBD_FLAGS], ac        ; caps lock: a-z and A-Z swap
    and  1, ac
    beq  kk_ctl
    ld   [IO_T3], ac
    or   0x20, ac
    sub  0x61, ac               ; 'a'
    blt  kk_ctl
    sub  26, ac
    bcc  kk_ctl
    ld   [IO_T3], ac
    xor  0x20, ac
    ld   ac, [IO_T3]
kk_ctl:
    ld   [KBD_NOW + (K_CTRL >> 3)], ac
    and  1 << (K_CTRL & 7), ac
    beq  kk_cc
    ld   [KBD_NOW + (K_RCTRL >> 3)], ac
    and  1 << (K_RCTRL & 7), ac
    bne  kk_put
kk_cc:
    ld   [IO_T3], ac            ; Ctrl: the control code
    and  0x1F, ac
    ld   ac, [IO_T3]
; kbd_putc - put the character in AC in the key buffer (dropped if it is
; full).  Changes X.  The PS/2 keyboard's own keys (Delete, Home, `) use it.
kbd_putc:
    ld   ac, [IO_T3]
kk_put:
    ld   [KBD_HEAD], ac
    inc
    and  7, ac
    xor  [KBD_TAIL], ac
    beq  kk_ret                 ; buffer full
    ld   [KBD_HEAD], ac
    add  KBD_BUF, x
    ld   [IO_T3], ac
    ld   ac, [x]
    ld   [KBD_HEAD], ac
    inc
    and  7, ac
    ld   ac, [KBD_HEAD]
kk_ret:
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page 3: SPI byte and SD commands
; ============================================================
#addr IO_CODE + 0x300

; ------------------------------------------------------------
; spi_byte - send and receive one byte on the SD card's SPI bus
;   in:      AC = byte to send; /CS low (the latch at P_IDLE: both PS/2
;            devices held, ps2_pause; sd_init, sd_read and sd_write do that)
;   out:     AC = byte received
;   changes: X, Y, T0-T2
;   clocks:  about 480 (about 1,150 with the slow clock for sd_init)
;   SPI mode 3: SCK idles high, the card samples MOSI on the rising
;   edge and changes MISO on the falling edge (SD cards take mode 0
;   or 3).  MSB first.  Leaves SCK high and /CS low.
; ------------------------------------------------------------
spi_byte:
    ld   ac, [T0]
    ld   8, ac
    ld   ac, [T2]
    ld   PORT, y
    clr  x
sb_bit:
    ld   [T0], ac
    blt  sb_one
    ld   0xE8, [y,x]            ; SCK low, MOSI 0
    ld   0xE9, [y,x]            ; SCK high
    bra  sb_rd
sb_one:
    ld   0xEA, [y,x]            ; SCK low, MOSI 1
    ld   0xEB, [y,x]            ; SCK high
sb_rd:
    ld   [SD_FLAGS], ac
    and  2, ac
    beq  sb_fast
    ld   12, ac                 ; slow clock (below 400 kHz) for sd_init
sb_wait:
    dec
    bne  sb_wait
sb_fast:
    ld   [y,x], ac              ; D7 = MISO
    blt  sb_m1
    ld   [T1], ac
    shl
    bra  sb_st
sb_m1:
    ld   [T1], ac
    shl
    or   1, ac
sb_st:
    ld   ac, [T1]
    ld   [T0], ac
    shl
    ld   ac, [T0]
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  sb_bit
    ld   [T1], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; sd_cmdt - send an SD command from the table sd_cmds
;   in:      AC = offset of the command in sd_cmds (SD_CMD0 ...)
;   out:     as sd_cmd
;   Copies the 5 bytes to T3-T7 and goes on into sd_cmd.
; ------------------------------------------------------------
sd_cmdt:
    ld   ac, [T7]               ; keep the offset (T7 is written last)
    add  sd_cmds & 0xFF, x
    ld   sd_cmds >> 8, y
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [T7], ac
    add  (sd_cmds + 1) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [T4]
    ld   [T7], ac
    add  (sd_cmds + 2) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [T5]
    ld   [T7], ac
    add  (sd_cmds + 3) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [T6]
    ld   [T7], ac
    add  (sd_cmds + 4) & 0xFF, x
    ld   [y,x], ac
    ld   ac, [T7]

; ------------------------------------------------------------
; sd_cmd - send a command to the SD card and read its R1 answer
;   in:      T3 = 40 + command number, T4-T7 = argument, high byte
;            first
;   out:     AC = R1 (00 ready, 01 idle, other bits are errors; FF = no
;            answer in 8 bytes)
;   changes: X, Y, T0-T2, IO_TMP
;   clocks:  about 5,000 (about 12,000 slow)
;   Uses 2 stack bytes.  Sends one FF first, then the 6-byte command
;   (the CRC is right for CMD0 and CMD8; the card ignores it for the
;   rest), then reads up to 8 bytes for the answer.  More answer
;   bytes (R3, R7, data) follow with spi_byte.
; ------------------------------------------------------------
sd_cmd:
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
    ld   T3, ac                 ; IO_TMP walks T3-T7
    ld   ac, [IO_TMP]
    ld   0xFF, ac
sc_send:
    ld   LINK_LO, x             ; CALL spi_byte
    ld   sc_back1, [x]
    ld   LINK_HI, x
    ld   sc_back1 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sc_back1:
    ld   [IO_TMP], ac
    xor  T7 + 1, ac
    beq  sc_crc
    ld   [IO_TMP], x
    ld   [IO_TMP], ac
    inc
    ld   ac, [IO_TMP]
    ld   [x], ac
    bra  sc_send
sc_crc:
    ld   [T3], ac
    xor  0x40, ac
    bne  sc_n0
    ld   0x95, ac               ; CMD0's CRC
    bra  sc_c
sc_n0:
    xor  0x08, ac               ; T3 xor 48
    bne  sc_n8
    ld   0x87, ac               ; CMD8's CRC (argument 1AA)
    bra  sc_c
sc_n8:
    ld   0x01, ac               ; end bit; the CRC is not checked
sc_c:
    ld   LINK_LO, x             ; CALL spi_byte
    ld   sc_back2, [x]
    ld   LINK_HI, x
    ld   sc_back2 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sc_back2:
    ld   8, ac
    ld   ac, [IO_TMP]
sc_r1:
    ld   0xFF, ac
    ld   LINK_LO, x             ; CALL spi_byte
    ld   sc_back3, [x]
    ld   LINK_HI, x
    ld   sc_back3 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sc_back3:
    blt  sc_done_b7
    bra  sc_done                ; bit 7 clear: the answer
sc_done_b7:
    ld   [IO_TMP], ac
    dec
    ld   ac, [IO_TMP]
    bne  sc_r1
    ld   0xFF, ac               ; no answer
sc_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ============================================================
; Page 4: SD card start-up
; ============================================================
#addr IO_CODE + 0x400

; ------------------------------------------------------------
; sd_init - start the SD card in SPI mode
;   in:      -
;   out:     AC = 0 if the card is ready, else
;              1  no card (no answer to CMD0)
;              2  the card did not finish starting (ACMD41, about 1 s)
;              3  a card this driver can't use
;            SD_FLAGS bit 0 = 1 for an SDHC or SDXC card (block
;            addresses), bit 7 = 1 when ready
;   changes: X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 200,000 for a card that starts at once (8 ms)
;   Uses 4 stack bytes.  Runs the bus below 400 kHz, as a card needs
;   until it has started.  The PS/2 devices are held off meanwhile
;   (ps2_pause: /CS is also the mouse's clock hold) and the listened
;   one let go again at the end.
; ------------------------------------------------------------
sd_init:
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
    ld   2, ac                  ; slow clock, not ready
    ld   ac, [SD_FLAGS]
    ld   LINK_LO, x             ; CALL ps2_pause
    ld   si_pz, [x]
    ld   LINK_HI, x
    ld   si_pz >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
si_pz:
    ld   PORT, y                ; 80 clocks with /CS high and MOSI high,
    clr  x                      ; below 400 kHz (about 200 us; the one
    ld   80, ac                 ; place /CS stays high over 50 us, see
    ld   ac, [IO_T1]            ; docs/IO.md)
si_clk:
    ld   0xEE, [y,x]            ; SCK low, MOSI 1, /CS high
    ld   7, ac
si_w1:
    dec
    bne  si_w1
    ld   0xEF, [y,x]            ; SCK high
    ld   6, ac
si_w2:
    dec
    bne  si_w2
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  si_clk
    ld   P_IDLE, [y,x]          ; /CS low
    ld   10, ac                 ; CMD0 (go to SPI mode), up to 10 tries
    ld   ac, [IO_T0]
si_c0:
    ld   SD_CMD0, ac
    ld   LINK_LO, x             ; CALL sd_cmdt
    ld   si_b0, [x]
    ld   LINK_HI, x
    ld   si_b0 >> 8, [x]
    ld   sd_cmdt >> 8, y
    jmp  sd_cmdt
si_b0:
    xor  0x01, ac
    beq  si_c8
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  si_c0
    ld   1, ac                  ; no card
    bra  si_out1
si_c8:
    ld   SD_CMD8, ac            ; CMD8: version 2 cards answer 01
    ld   LINK_LO, x
    ld   si_b8, [x]
    ld   LINK_HI, x
    ld   si_b8 >> 8, [x]
    ld   sd_cmdt >> 8, y
    jmp  sd_cmdt
si_b8:
    xor  0x01, ac
    beq  si_v2
    clr  ac                     ; illegal command: a version 1 card
    bra  si_ver
si_v2:
    ld   3, ac                  ; R7: 3 bytes, then the check pattern
    ld   ac, [IO_T0]
si_r7:
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   si_b7, [x]
    ld   LINK_HI, x
    ld   si_b7 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
si_b7:
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  si_r7
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   si_bp, [x]
    ld   LINK_HI, x
    ld   si_bp >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
si_bp:
    xor  0xAA, ac
    beq  si_pat
    ld   3, ac                  ; check pattern wrong
    bra  si_out1
si_pat:
    ld   1, ac                  ; version 2: read the OCR later
si_ver:
    ld   ac, [IO_T2]            ; IO_T2 = 1 for a version 2 card, 0 for version 1
    ld   si_start >> 8, y
    jmp  si_start
si_out1:
    ld   ac, [IO_TMP]           ; the PS/2 line back to whoever had it
    ld   PORT, y
    ld   PORT_RX, x
    ld   [PS2_LSN], ac
    ld   ac, [y,x]
    ld   [IO_TMP], ac
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 5: SD card start-up, continued
; ============================================================
#addr IO_CODE + 0x500

si_start:
    clr  ac                     ; ACMD41 for about 1 s: 5 x 256 tries
    ld   ac, [IO_T0]
    ld   5, ac
    ld   ac, [IO_T1]
si_a41:
    ld   SD_CMD55, ac
    ld   LINK_LO, x
    ld   si_b55, [x]
    ld   LINK_HI, x
    ld   si_b55 >> 8, [x]
    ld   sd_cmdt >> 8, y
    jmp  sd_cmdt
si_b55:
    ld   SD_ACMD41, ac
    ld   LINK_LO, x
    ld   si_b41, [x]
    ld   LINK_HI, x
    ld   si_b41 >> 8, [x]
    ld   sd_cmdt >> 8, y
    jmp  sd_cmdt
si_b41:
    beq  si_rdy                 ; 00: started
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  si_a41
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  si_a41
    ld   2, ac                  ; did not start
    bra  si_out
si_rdy:
    ld   [IO_T2], ac
    beq  si_c16                 ; version 1: byte addresses
    ld   SD_CMD58, ac           ; read the OCR: CCS = block addresses
    ld   LINK_LO, x
    ld   si_b58, [x]
    ld   LINK_HI, x
    ld   si_b58 >> 8, [x]
    ld   sd_cmdt >> 8, y
    jmp  sd_cmdt
si_b58:
    bne  si_bad
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   si_bo, [x]
    ld   LINK_HI, x
    ld   si_bo >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
si_bo:
    and  0x40, ac               ; CCS
    beq  si_ocr
    ld   [SD_FLAGS], ac
    or   1, ac
    ld   ac, [SD_FLAGS]
si_ocr:
    ld   3, ac                  ; the rest of the OCR
    ld   ac, [IO_T0]
si_or:
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   si_bq, [x]
    ld   LINK_HI, x
    ld   si_bq >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
si_bq:
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  si_or
si_c16:
    ld   SD_CMD16, ac           ; 512-byte blocks (an SDSC card)
    ld   LINK_LO, x
    ld   si_b16, [x]
    ld   LINK_HI, x
    ld   si_b16 >> 8, [x]
    ld   sd_cmdt >> 8, y
    jmp  sd_cmdt
si_b16:
    bne  si_bad
    ld   [SD_FLAGS], ac         ; full speed, ready
    and  1, ac
    or   0x80, ac
    ld   ac, [SD_FLAGS]
    clr  ac
    bra  si_out
si_bad:
    ld   3, ac
si_out:
    ld   ac, [IO_TMP]           ; the PS/2 line back to whoever had it
    ld   PORT, y
    ld   PORT_RX, x
    ld   [PS2_LSN], ac
    ld   ac, [y,x]
    ld   [IO_TMP], ac
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 6: SD block read
; ============================================================
#addr IO_CODE + 0x600

; ------------------------------------------------------------
; sd_read - read one 512-byte block from the SD card
;   in:      R3:R0 = block number, R5:R4 = buffer address
;   out:     AC = 0 when done, else
;              4  the card refused the command
;              5  no data (an error token, or none in about 100 ms)
;            R5:R4 = buffer + 512
;   changes: X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 130,000 (5 ms)
;   Uses 4 stack bytes.  sd_init first.  The PS/2 devices are held off
;   meanwhile (ps2_pause) and the listened one let go again at the end.
; ------------------------------------------------------------
sd_read:
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
    ld   LINK_LO, x             ; CALL ps2_pause
    ld   sr_pz, [x]
    ld   LINK_HI, x
    ld   sr_pz >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
sr_pz:
    ld   0x51, ac               ; CMD17
    ld   LINK_LO, x             ; CALL sd_arg
    ld   sr_ba, [x]
    ld   LINK_HI, x
    ld   sr_ba >> 8, [x]
    ld   sd_arg >> 8, y
    jmp  sd_arg
sr_ba:
    ld   LINK_LO, x             ; CALL sd_cmd
    ld   sr_bc, [x]
    ld   LINK_HI, x
    ld   sr_bc >> 8, [x]
    ld   sd_cmd >> 8, y
    jmp  sd_cmd
sr_bc:
    bne  sr_e4
    clr  ac                     ; wait for the data token: 16 x 256 tries
    ld   ac, [IO_T0]
    ld   16, ac
    ld   ac, [IO_T1]
sr_tok:
    ld   0xFF, ac
    ld   LINK_LO, x             ; CALL spi_byte
    ld   sr_bt, [x]
    ld   LINK_HI, x
    ld   sr_bt >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sr_bt:
    xor  0xFE, ac
    beq  sr_data
    xor  0x01, ac               ; FF: not yet
    bne  sr_e5                  ; an error token
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  sr_tok
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  sr_tok
sr_e5:
    ld   5, ac
    bra  sr_out
sr_e4:
    ld   4, ac
    bra  sr_out
sr_data:
    ld   LINK_LO, x             ; CALL sd_rx512
    ld   sr_bd, [x]
    ld   LINK_HI, x
    ld   sr_bd >> 8, [x]
    ld   sd_rx512 >> 8, y
    jmp  sd_rx512
sr_bd:
    ld   0xFF, ac               ; the CRC, 2 bytes, not checked
    ld   LINK_LO, x
    ld   sr_bk1, [x]
    ld   LINK_HI, x
    ld   sr_bk1 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sr_bk1:
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   sr_bk2, [x]
    ld   LINK_HI, x
    ld   sr_bk2 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sr_bk2:
    clr  ac
sr_out:
    ld   ac, [IO_TMP]           ; the PS/2 line back to whoever had it
    ld   PORT, y
    ld   PORT_RX, x
    ld   [PS2_LSN], ac
    ld   ac, [y,x]
    ld   [IO_TMP], ac
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 7: SD block write
; ============================================================
#addr IO_CODE + 0x700

; ------------------------------------------------------------
; sd_write - write one 512-byte block to the SD card
;   in:      R3:R0 = block number, R5:R4 = buffer address
;   out:     AC = 0 when written, else
;              4  the card refused the command
;              6  the card refused the data
;              7  the card stayed busy (about 400 ms)
;            R5:R4 = buffer + 512
;   changes: X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 130,000 plus the card's busy time
;   Uses 4 stack bytes.  sd_init first.  The PS/2 devices are held off
;   meanwhile (ps2_pause) and the listened one let go again at the end.
; ------------------------------------------------------------
sd_write:
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
    ld   LINK_LO, x             ; CALL ps2_pause
    ld   sw_pz, [x]
    ld   LINK_HI, x
    ld   sw_pz >> 8, [x]
    ld   ps2_pause >> 8, y
    jmp  ps2_pause
sw_pz:
    ld   0x58, ac               ; CMD24
    ld   LINK_LO, x             ; CALL sd_arg
    ld   sw_ba, [x]
    ld   LINK_HI, x
    ld   sw_ba >> 8, [x]
    ld   sd_arg >> 8, y
    jmp  sd_arg
sw_ba:
    ld   LINK_LO, x             ; CALL sd_cmd
    ld   sw_bc, [x]
    ld   LINK_HI, x
    ld   sw_bc >> 8, [x]
    ld   sd_cmd >> 8, y
    jmp  sd_cmd
sw_bc:
    bne  sw_e4
    ld   0xFF, ac               ; one byte gap
    ld   LINK_LO, x
    ld   sw_bg, [x]
    ld   LINK_HI, x
    ld   sw_bg >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sw_bg:
    ld   0xFE, ac               ; data token
    ld   LINK_LO, x
    ld   sw_bt, [x]
    ld   LINK_HI, x
    ld   sw_bt >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sw_bt:
    ld   LINK_LO, x             ; CALL sd_tx512
    ld   sw_bd, [x]
    ld   LINK_HI, x
    ld   sw_bd >> 8, [x]
    ld   sd_tx512 >> 8, y
    jmp  sd_tx512
sw_bd:
    ld   0xFF, ac               ; CRC, 2 bytes (not checked by the card)
    ld   LINK_LO, x
    ld   sw_bk1, [x]
    ld   LINK_HI, x
    ld   sw_bk1 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sw_bk1:
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   sw_bk2, [x]
    ld   LINK_HI, x
    ld   sw_bk2 >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sw_bk2:
    ld   8, ac                  ; data response: xxx0 0101 = accepted,
    ld   ac, [IO_T0]            ; the first byte that is not FF, in up
sw_dr:                          ; to 8 bytes
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   sw_br, [x]
    ld   LINK_HI, x
    ld   sw_br >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sw_br:
    xor  0xFF, ac
    bne  sw_dr1
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  sw_dr
sw_dr1:
    xor  0xFF, ac
    and  0x1F, ac
    xor  0x05, ac
    bne  sw_e6
    clr  ac                     ; busy (MISO low) for up to 64 x 256 bytes
    ld   ac, [IO_T0]
    ld   64, ac
    ld   ac, [IO_T1]
sw_busy:
    ld   0xFF, ac
    ld   LINK_LO, x
    ld   sw_bb, [x]
    ld   LINK_HI, x
    ld   sw_bb >> 8, [x]
    ld   spi_byte >> 8, y
    jmp  spi_byte
sw_bb:
    xor  0xFF, ac
    beq  sw_out                 ; FF: done, AC = 0
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  sw_busy
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  sw_busy
    ld   7, ac
    bra  sw_out
sw_e6:
    ld   6, ac
    bra  sw_out
sw_e4:
    ld   4, ac
sw_out:
    ld   ac, [IO_TMP]           ; the PS/2 line back to whoever had it
    ld   PORT, y
    ld   PORT_RX, x
    ld   [PS2_LSN], ac
    ld   ac, [y,x]
    ld   [IO_TMP], ac
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave


; ============================================================
; Page 8: 512 bytes in at full speed
; ============================================================
#addr IO_CODE + 0x800

; ------------------------------------------------------------
; sd_rx512 - receive 512 bytes into memory (sending FF)
;   in:      R5:R4 = buffer address; /CS low
;   out:     R5:R4 = buffer + 512
;   changes: AC, X, Y, T1, IO_T0, IO_T1
;   clocks:  about 115,000
; ------------------------------------------------------------
sd_rx512:
    clr  ac
    ld   ac, [IO_T0]
    ld   2, ac
    ld   ac, [IO_T1]
rx_byte:
    ld   PORT, y
    clr  x
    ld   0xEA, [y,x]            ; bit 7: SCK low (MOSI 1)
    ld   0xEB, [y,x]            ; SCK high
    ld   [y,x], ac              ; D7 = MISO
    blt  rx_7
    clr  ac
    bra  rx_7s
rx_7:
    ld   1, ac
rx_7s:
    ld   ac, [T1]               ; T1 = bit 7 in bit 0; 7 more shifts move it up
    ld   0xEA, [y,x]            ; bit 6
    ld   0xEB, [y,x]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [y,x], ac
    blt  rx_6_b7
    bra  rx_6
rx_6_b7:
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
rx_6:
    ld   0xEA, [y,x]            ; bit 5
    ld   0xEB, [y,x]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [y,x], ac
    blt  rx_5_b7
    bra  rx_5
rx_5_b7:
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
rx_5:
    ld   0xEA, [y,x]            ; bit 4
    ld   0xEB, [y,x]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [y,x], ac
    blt  rx_4_b7
    bra  rx_4
rx_4_b7:
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
rx_4:
    ld   0xEA, [y,x]            ; bit 3
    ld   0xEB, [y,x]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [y,x], ac
    blt  rx_3_b7
    bra  rx_3
rx_3_b7:
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
rx_3:
    ld   0xEA, [y,x]            ; bit 2
    ld   0xEB, [y,x]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [y,x], ac
    blt  rx_2_b7
    bra  rx_2
rx_2_b7:
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
rx_2:
    ld   0xEA, [y,x]            ; bit 1
    ld   0xEB, [y,x]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [y,x], ac
    blt  rx_1_b7
    bra  rx_1
rx_1_b7:
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
rx_1:
    ld   0xEA, [y,x]            ; bit 0
    ld   0xEB, [y,x]
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [y,x], ac
    blt  rx_0_b7
    bra  rx_0
rx_0_b7:
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
rx_0:
    ld   [R4], x                ; store it
    ld   [R5], y
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [R4], ac
    inc
    ld   ac, [R4]
    bne  rx_nc
    ld   [R5], ac
    inc
    ld   ac, [R5]
rx_nc:
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  rx_byte
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  rx_byte
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page 9: 512 bytes out
; ============================================================
#addr IO_CODE + 0x900

; ------------------------------------------------------------
; sd_tx512 - send 512 bytes from memory (MISO is ignored)
;   in:      R5:R4 = buffer address; /CS low
;   out:     R5:R4 = buffer + 512
;   changes: AC, X, Y, T0, T2, IO_T0, IO_T1
;   clocks:  about 130,000
; ------------------------------------------------------------
sd_tx512:
    clr  ac
    ld   ac, [IO_T0]
    ld   2, ac
    ld   ac, [IO_T1]
tx_byte:
    ld   [R4], x
    ld   [R5], y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [R4], ac
    inc
    ld   ac, [R4]
    bne  tx_nc
    ld   [R5], ac
    inc
    ld   ac, [R5]
tx_nc:
    ld   PORT, y
    ld   8, ac
    ld   ac, [T2]
tx_bit:
    ld   [T0], ac
    blt  tx_one
    ld   0xE8, [y,x]            ; SCK low, MOSI 0
    ld   0xE9, [y,x]            ; SCK high
    bra  tx_sh
tx_one:
    ld   0xEA, [y,x]            ; SCK low, MOSI 1
    ld   0xEB, [y,x]
tx_sh:
    ld   [T0], ac
    shl
    ld   ac, [T0]
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  tx_bit
    ld   [IO_T0], ac
    dec
    ld   ac, [IO_T0]
    bne  tx_byte
    ld   [IO_T1], ac
    dec
    ld   ac, [IO_T1]
    bne  tx_byte
    ld   0xEB, [y,x]            ; MOSI high again
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page A: block address
; ============================================================
#addr IO_CODE + 0xA00

; ------------------------------------------------------------
; sd_arg - set up T3-T7 for a block command
;   in:      AC = 40 + command number, R3:R0 = block number
;   out:     T3 = AC, T4-T7 = the card's address of the block: the
;            block number for an SDHC or SDXC card (SD_FLAGS bit 0),
;            else the byte address, block number * 512
;   changes: AC
; ------------------------------------------------------------
sd_arg:
    ld   ac, [T3]
    ld   [SD_FLAGS], ac
    and  1, ac
    beq  sa_byte
    ld   [R3], ac
    ld   ac, [T4]
    ld   [R2], ac
    ld   ac, [T5]
    ld   [R1], ac
    ld   ac, [T6]
    ld   [R0], ac
    ld   ac, [T7]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
sa_byte:
    ld   [R2], ac               ; T4 = R2 << 1 | R1 >> 7
    shl
    ld   ac, [T4]
    ld   [R1], ac               ; T5 = R1 << 1 | R0 >> 7
    shl                         ; carry = R1 bit 7
    ld   ac, [T5]
    bcc  sa_1
    ld   [T4], ac
    or   1, ac
    ld   ac, [T4]
sa_1:
    ld   [R0], ac               ; T6 = R0 << 1
    shl                         ; carry = R0 bit 7
    ld   ac, [T6]
    bcc  sa_2
    ld   [T5], ac
    or   1, ac
    ld   ac, [T5]
sa_2:
    clr  ac
    ld   ac, [T7]
    ld   [LINK_HI], y
    jmp  [LINK_LO]



; ============================================================
; Page F: tables
; ============================================================
#addr IO_CODE + 0xF00

; ------------------------------------------------------------
; kbd_map - the character of each key, by key number (column * 8 +
; row): 64 bytes without Shift, then 64 with Shift.  0 = no character.
; Special keys: Enter 0A, Backspace 08, Tab 09, Esc 1B, Up 11, Down 12,
; Left 13, Right 14 (Delete 7F, Home 15 and ` ~ come from Fn, in
; kbd_key).  docs/IO.md has the layout.
; ------------------------------------------------------------
kbd_map:
    ; column 0: Esc 1 2 3 4 5 6 7
    #d8 0x1B, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37
    ; column 1: 8 9 0 - = Backspace Tab q
    #d8 0x38, 0x39, 0x30, 0x2D, 0x3D, 0x08, 0x09, 0x71
    ; column 2: w e r t y u i o
    #d8 0x77, 0x65, 0x72, 0x74, 0x79, 0x75, 0x69, 0x6F
    ; column 3: p [ ] \ LCtrl a s d
    #d8 0x70, 0x5B, 0x5D, 0x5C, 0x00, 0x61, 0x73, 0x64
    ; column 4: f g h j k l ; '
    #d8 0x66, 0x67, 0x68, 0x6A, 0x6B, 0x6C, 0x3B, 0x27
    ; column 5: Enter LShift z x c v b n
    #d8 0x0A, 0x00, 0x7A, 0x78, 0x63, 0x76, 0x62, 0x6E
    ; column 6: m , . / RShift Up CapsLock Fn
    #d8 0x6D, 0x2C, 0x2E, 0x2F, 0x00, 0x11, 0x00, 0x00
    ; column 7: RAlt LAlt Space RCtrl (spare) Left Down Right
    #d8 0x00, 0x00, 0x20, 0x00, 0x00, 0x13, 0x12, 0x14
kbd_map_sh:
    #d8 0x1B, 0x21, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26
    #d8 0x2A, 0x28, 0x29, 0x5F, 0x2B, 0x08, 0x09, 0x51
    #d8 0x57, 0x45, 0x52, 0x54, 0x59, 0x55, 0x49, 0x4F
    #d8 0x50, 0x7B, 0x7D, 0x7C, 0x00, 0x41, 0x53, 0x44
    #d8 0x46, 0x47, 0x48, 0x4A, 0x4B, 0x4C, 0x3A, 0x22
    #d8 0x0A, 0x00, 0x5A, 0x58, 0x43, 0x56, 0x42, 0x4E
    #d8 0x4D, 0x3C, 0x3E, 0x3F, 0x00, 0x11, 0x00, 0x00
    #d8 0x00, 0x00, 0x20, 0x00, 0x00, 0x13, 0x12, 0x14

; ------------------------------------------------------------
; sd_cmds - the SD commands sd_init sends: 40 + number, then the
; argument, high byte first.  sd_cmdt takes the offset.
; ------------------------------------------------------------
sd_cmds:
    #d8 0x40, 0x00, 0x00, 0x00, 0x00    ; CMD0  go idle (SPI mode)
    #d8 0x48, 0x00, 0x00, 0x01, 0xAA    ; CMD8  interface condition, 2.7-3.6 V, check AA
    #d8 0x77, 0x00, 0x00, 0x00, 0x00    ; CMD55 next is an ACMD
    #d8 0x69, 0x40, 0x00, 0x00, 0x00    ; ACMD41 start, HCS = 1
    #d8 0x7A, 0x00, 0x00, 0x00, 0x00    ; CMD58 read OCR
    #d8 0x50, 0x00, 0x00, 0x02, 0x00    ; CMD16 block length 512

SD_CMD0   = 0
SD_CMD8   = 5
SD_CMD55  = 10
SD_ACMD41 = 15
SD_CMD58  = 20
SD_CMD16  = 25
