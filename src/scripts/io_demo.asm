; io_demo.asm - try the keyboard, SNES pads and SD card (placard_io.asm)
;
; Starts the SD card and shows the result and the last two bytes of block 0
; (55 AA on a card with a partition table or a FAT boot sector).  Then, once
; per frame, it scans the keyboard and echoes what is typed, reads both pads
; and prints their buttons (pad_read's bits, in hex) when they change, and
; prints each PS/2 mouse packet (buttons, right, down) if a mouse started.
;
; It is a ROM program (docs/ROM.md): it runs in place from ROM x6000 and calls
; the library and I/O drivers in place.  Block 0 is read into x4100-x42FF.
;
;     python3 placard_sim.py io_demo.asm --run --boot --png io.png
;     build\io_demo.bat                 (the FPGA model: docs/IO.md has the wiring)
;
; Date: 10/22/2026

#include "placard.asm"
#include "placard_lib.asm"

; program variables (zero page x20-x9F)
pad1_lo = 0x20          ; pad bits last printed
pad1_hi = 0x21
pad2_lo = 0x22
pad2_hi = 0x23
sd_rc   = 0x24          ; sd_init's answer
mouse   = 0x25          ; mouse_init's answer (0 = running)
BUF     = 0x4100        ; block 0

#addr 0x6000
main:
    ld   STACK_TOP, ac          ; stack first
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL port_init
    ld   m1, [x]
    ld   LINK_HI, x
    ld   m1 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
m1:
    ld   LINK_LO, x             ; CALL con_clear
    ld   m2, [x]
    ld   LINK_HI, x
    ld   m2 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
m2:
    ld   s_title, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   m3, [x]
    ld   LINK_HI, x
    ld   m3 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
m3:
    ld   LINK_LO, x             ; CALL sd_init
    ld   m4, [x]
    ld   LINK_HI, x
    ld   m4 >> 8, [x]
    ld   sd_init >> 8, y
    jmp  sd_init
m4:
    ld   ac, [sd_rc]
    ld   LINK_LO, x             ; CALL con_hex8: the answer
    ld   m5, [x]
    ld   LINK_HI, x
    ld   m5 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
m5:
    ld   s_codes, ac
    ld   ac, [R0]
    ld   s_codes >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   m6, [x]
    ld   LINK_HI, x
    ld   m6 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
m6:
    ld   [sd_rc], ac
    beq  m_read
    ld   go >> 8, y             ; no card: on to the keyboard and pads
    jmp  go
m_read:
    clr  ac                     ; block 0 into BUF
    ld   ac, [R0]
    ld   ac, [R1]
    ld   ac, [R2]
    ld   ac, [R3]
    ld   BUF & 0xFF, ac
    ld   ac, [R4]
    ld   BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL sd_read
    ld   m7, [x]
    ld   LINK_HI, x
    ld   m7 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
m7:
    ld   ac, [sd_rc]
    ld   s_block, ac
    ld   ac, [R0]
    ld   s_block >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   m8, [x]
    ld   LINK_HI, x
    ld   m8 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
m8:
    ld   [sd_rc], ac            ; sd_read's answer
    ld   LINK_LO, x             ; CALL con_hex8
    ld   m9, [x]
    ld   LINK_HI, x
    ld   m9 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
m9:
    ld   0x20, ac               ; " "
    ld   LINK_LO, x             ; CALL con_putc
    ld   m10, [x]
    ld   LINK_HI, x
    ld   m10 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
m10:
    ld   (BUF + 0x1FE) >> 8, y  ; the block's last two bytes
    ld   (BUF + 0x1FE) & 0xFF, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   m11, [x]
    ld   LINK_HI, x
    ld   m11 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
m11:
    ld   (BUF + 0x1FF) >> 8, y
    ld   (BUF + 0x1FF) & 0xFF, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   m12, [x]
    ld   LINK_HI, x
    ld   m12 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
m12:
    ld   go >> 8, y
    jmp  go

#addr 0x6100
go:
    ld   s_mouse, ac
    ld   ac, [R0]
    ld   s_mouse >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   g0a, [x]
    ld   LINK_HI, x
    ld   g0a >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
g0a:
    ld   LINK_LO, x             ; CALL mouse_init
    ld   g0b, [x]
    ld   LINK_HI, x
    ld   g0b >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
g0b:
    ld   ac, [mouse]
    ld   LINK_LO, x             ; CALL con_hex8
    ld   g0c, [x]
    ld   LINK_HI, x
    ld   g0c >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
g0c:
    ld   s_help, ac
    ld   ac, [R0]
    ld   s_help >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   g1, [x]
    ld   LINK_HI, x
    ld   g1 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
g1:
    clr  ac                     ; pads: nothing printed yet
    ld   ac, [pad1_lo]
    ld   ac, [pad1_hi]
    ld   ac, [pad2_lo]
    ld   ac, [pad2_hi]
loop:
    ld   1, ac                  ; once per frame (it listens to the mouse
    ld   LINK_LO, x             ; and the PS/2 keyboard while it waits)
    ld   l1, [x]
    ld   LINK_HI, x
    ld   l1 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
l1:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   l2, [x]
    ld   LINK_HI, x
    ld   l2 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
l2:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   l3, [x]
    ld   LINK_HI, x
    ld   l3 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
l3:
    beq  pads                   ; buffer empty
    ld   LINK_LO, x             ; CALL con_putc
    ld   l2, [x]
    ld   LINK_HI, x
    ld   l2 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
pads:
    ld   LINK_LO, x             ; CALL pad_read
    ld   p1, [x]
    ld   LINK_HI, x
    ld   p1 >> 8, [x]
    ld   pad_read >> 8, y
    jmp  pad_read
p1:
    ld   [R0], ac               ; changed since the last print?
    xor  [pad1_lo], ac
    bne  p_new
    ld   [R1], ac
    xor  [pad1_hi], ac
    bne  p_new
    ld   [R2], ac
    xor  [pad2_lo], ac
    bne  p_new
    ld   [R3], ac
    xor  [pad2_hi], ac
    bne  p_new
    ld   mouse_chk >> 8, y
    jmp  mouse_chk
p_new:
    ld   [R0], ac
    ld   ac, [pad1_lo]
    ld   [R1], ac
    ld   ac, [pad1_hi]
    ld   [R2], ac
    ld   ac, [pad2_lo]
    ld   [R3], ac
    ld   ac, [pad2_hi]
    ld   pr >> 8, y
    jmp  pr

#addr 0x6200
pr:                             ; "\npads hhhh hhhh\n"
    ld   s_pads, ac
    ld   ac, [R0]
    ld   s_pads >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   q1, [x]
    ld   LINK_HI, x
    ld   q1 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
q1:
    ld   [pad1_hi], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   q2, [x]
    ld   LINK_HI, x
    ld   q2 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
q2:
    ld   [pad1_lo], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   q3, [x]
    ld   LINK_HI, x
    ld   q3 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
q3:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   q4, [x]
    ld   LINK_HI, x
    ld   q4 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
q4:
    ld   [pad2_hi], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   q5, [x]
    ld   LINK_HI, x
    ld   q5 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
q5:
    ld   [pad2_lo], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   q6, [x]
    ld   LINK_HI, x
    ld   q6 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
q6:
    ld   0x0A, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   q7, [x]
    ld   LINK_HI, x
    ld   q7 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
q7:
    ld   mouse_chk >> 8, y
    jmp  mouse_chk

#addr 0x6300
mouse_chk:
    ld   [mouse], ac            ; a mouse running?
    bne  mc_done
    ld   LINK_LO, x             ; CALL mouse_poll
    ld   mc1, [x]
    ld   LINK_HI, x
    ld   mc1 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
mc1:
    xor  1, ac
    bne  mc_done                ; no new packet
    ld   s_mpk, ac              ; "\nmouse bb xx yy"
    ld   ac, [R0]
    ld   s_mpk >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   mc2, [x]
    ld   LINK_HI, x
    ld   mc2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
mc2:
    ld   [MOUSE_B], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   mc3, [x]
    ld   LINK_HI, x
    ld   mc3 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
mc3:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   mc4, [x]
    ld   LINK_HI, x
    ld   mc4 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
mc4:
    ld   [MOUSE_DX], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   mc5, [x]
    ld   LINK_HI, x
    ld   mc5 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
mc5:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   mc6, [x]
    ld   LINK_HI, x
    ld   mc6 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
mc6:
    ld   [MOUSE_DY], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   mc_done, [x]
    ld   LINK_HI, x
    ld   mc_done >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
mc_done:
    ld   loop >> 8, y
    jmp  loop

#addr 0x6400
s_title:
    #d "PLACARD I/O DEMO", 0x0A, 0x0A, "SD card: ", 0x00
s_codes:
    #d " (00 ready, 01 none, 02 did not start, 03 unusable)", 0x0A, 0x00
s_block:
    #d "block 0: ", 0x00
s_help:
    #d 0x0A, 0x0A, "Type on the keyboard and press pad buttons.", 0x0A, 0x0A, 0x00
s_pads:
    #d 0x0A, "pads ", 0x00
s_mouse:
    #d 0x0A, "Mouse: ", 0x00
s_mpk:
    #d 0x0A, "mouse ", 0x00
