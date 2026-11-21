; ============================================================
; made by asm_expand.py from wifi.masm: change that file, then run
;     python3 asm_expand.py wifi.masm
; ============================================================

; ============================================================
; wifi.masm - WIFI.PLC: tries the WiFi expansion card
; ============================================================
;
; A library program the DOS runs from the card (Enter on WIFI.PLC in the
; browser).  It is the WiFi card's driver and an example of its use
; (docs/architecture/WIFICARD.md):
;
;   1. finds the card in slots 1-4 (wf_find) and shows the module's
;      firmware name
;   2. asks for the network's name and password (Enter alone: the network
;      the module has kept from last time) and joins it
;   3. shows the address the network gave, and the time
;   4. asks for a web site (Enter alone: example.com), fetches its first
;      page with HTTP and prints what comes back, headers and all
;
; Esc goes back to the DOS wherever the program waits (menu_poll).
;
; THE DRIVER (copy these four routines into a program that uses the card)
;   wf_find   find the card: AC = 0 and wf_y, wf_x set, or AC = 1
;   wf_ready  wait until the module is ready for a transfer
;   wf_byte   one byte out and one in, as the SD card's spi_byte
;   wf_xfer   one request and its reply: AC = command, wf_n = the number
;             of request bytes in WF_TX; gives AC = wf_st = status (00 =
;             done), wf_len reply bytes in WF_RX and a 00 after them
;
; The card's register (offset 60h of its slot): bit 0 SCK, bit 1 MOSI,
; bit 2 /CS, bit 3 = 1 the module runs.  A read gives D7 = MISO and D6 =
; READY.  SPI mode 3, as the SD card.
;
; RAM: the program at x0100 (asm_expand.py pages it), zero page x20-x2F,
; x4000-x40FF the request, x4100-x41FF the reply, x4200-x423F the web
; site's name.
;
;     python3 asm_expand.py wifi.masm                 wifi.asm
;     python3 gen_plc.py wifi.asm -o ../../sdcard/WIFI.PLC
;     python3 test_wifi.py                            runs it in placard_sim
;
; Date: 11/21/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"

wf_y    = 0x20              ; the card's page: x51 (slots 1, 3) or x53 (2, 4)
wf_x    = 0x21              ; its register's offset: x60 (slots 1, 2) or xE0 (3, 4)
wf_st   = 0x22              ; status of the last reply
wf_len  = 0x23              ; data bytes of the last reply
wf_cmd  = 0x24              ; the command being sent
wf_n    = 0x25              ; request bytes in WF_TX
wf_i    = 0x26              ; counter (after wf_find: the slot, 0-3)
wf_try  = 0x27              ; tries left
wf_mark = 0x28              ; the module's first byte of the request
w_k     = 0x29              ; scratch
w_j     = 0x2A              ; scratch
w_hl    = 0x2B              ; the web site's name: address low
w_hh    = 0x2C              ; and high

WF_TX   = 0x4000            ; request bytes (255 at most)
WF_RX   = 0x4100            ; reply bytes (255 at most) and a 00
W_HOST  = 0x4200            ; the name typed

WF_IDLE = 0x0F              ; the register at rest: the module runs, /CS, MOSI, SCK high
WF_SEL  = 0x0B              ; /CS low, SCK high
WF_TMO  = 0                 ; wf_ready gives up after 256 x 65536 looks (about 15 s)

C_INFO  = 0x01
C_JOIN  = 0x02
C_STATE = 0x03
C_OPEN  = 0x10
C_SEND  = 0x11
C_RECV  = 0x12
C_CLOSE = 0x13
C_TIME  = 0x20


; ============================================================
; main - the card, the module's name
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL con_clear
    ld   wf_r1, [x]
    ld   LINK_HI, x
    ld   wf_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
wf_r1:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r2, [x]
    ld   LINK_HI, x
    ld   wf_r2 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r2:
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r3, [x]
    ld   LINK_HI, x
    ld   wf_r3 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r3:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r4, [x]
    ld   LINK_HI, x
    ld   wf_r4 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r4:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r5, [x]
    ld   LINK_HI, x
    ld   wf_r5 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r5:
    ld   LINK_LO, x             ; CALL wf_find
    ld   wf_r6, [x]
    ld   LINK_HI, x
    ld   wf_r6 >> 8, [x]
    ld   wf_find >> 8, y
    jmp  wf_find
wf_r6:
    beq  mn_card
    ld   s_nocard & 0xFF, ac
    ld   ac, [R0]
    ld   s_nocard >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r7, [x]
    ld   LINK_HI, x
    ld   wf_r7 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r7:
    ld   halt >> 8, y
    jmp  halt
mn_card:
    ld   s_slot & 0xFF, ac
    ld   ac, [R0]
    ld   s_slot >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r8, [x]
    ld   LINK_HI, x
    ld   wf_r8 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r8:
    ld   [wf_i], ac
    inc
    ld   LINK_LO, x             ; CALL con_dec8
    ld   wf_r9, [x]
    ld   LINK_HI, x
    ld   wf_r9 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
wf_r9:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r10, [x]
    ld   LINK_HI, x
    ld   wf_r10 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r10:
    ld   info >> 8, y
    jmp  info

info:
    clr  ac
    ld   ac, [wf_n]
    ld   C_INFO, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r11, [x]
    ld   LINK_HI, x
    ld   wf_r11 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r11:
    beq  in_ok
    ld   linkfail >> 8, y
    jmp  linkfail
in_ok:
    ld   s_fw & 0xFF, ac
    ld   ac, [R0]
    ld   s_fw >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r12, [x]
    ld   LINK_HI, x
    ld   wf_r12 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r12:
    clr  ac
    ld   ac, [R0]
    ld   WF_RX >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r13, [x]
    ld   LINK_HI, x
    ld   wf_r13 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r13:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r14, [x]
    ld   LINK_HI, x
    ld   wf_r14 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r14:
    ld   ask >> 8, y
    jmp  ask

; ------------------------------------------------------------
; ask - the network's name and password into the request
; ------------------------------------------------------------

#addr 0x0200
ask:
    ld   s_name & 0xFF, ac
    ld   ac, [R0]
    ld   s_name >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r15, [x]
    ld   LINK_HI, x
    ld   wf_r15 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r15:
    clr  ac
    ld   ac, [R0]
    ld   WF_TX >> 8, ac
    ld   ac, [R1]
    ld   32, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL con_gets
    ld   wf_r16, [x]
    ld   LINK_HI, x
    ld   wf_r16 >> 8, [x]
    ld   con_gets >> 8, y
    jmp  con_gets
wf_r16:
    ld   ac, [wf_n]
    beq  ak_join                ; nothing typed: the network the module kept
    ld   s_pass & 0xFF, ac
    ld   ac, [R0]
    ld   s_pass >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r17, [x]
    ld   LINK_HI, x
    ld   wf_r17 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r17:
    ld   [wf_n], ac
    inc                         ; past the name's 00
    ld   ac, [R0]
    ld   ac, [w_k]
    ld   WF_TX >> 8, ac
    ld   ac, [R1]
    ld   63, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL con_gets
    ld   wf_r18, [x]
    ld   LINK_HI, x
    ld   wf_r18 >> 8, [x]
    ld   con_gets >> 8, y
    jmp  con_gets
wf_r18:
    add  [w_k], ac
    inc                         ; and the password's 00
    ld   ac, [wf_n]
ak_join:
    ld   join >> 8, y
    jmp  join

; ------------------------------------------------------------
; join - start the join, then ask how it goes three times a second
; ------------------------------------------------------------
join:
    ld   C_JOIN, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r19, [x]
    ld   LINK_HI, x
    ld   wf_r19 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r19:
    beq  jn_wait
    xor  1, ac
    beq  jn_none
    ld   [wf_st], ac
    ld   linkfail >> 8, y
    jmp  linkfail
jn_none:
    ld   s_nosaved & 0xFF, ac
    ld   ac, [R0]
    ld   s_nosaved >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r20, [x]
    ld   LINK_HI, x
    ld   wf_r20 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r20:
    ld   halt >> 8, y
    jmp  halt
jn_wait:
    ld   s_joining & 0xFF, ac
    ld   ac, [R0]
    ld   s_joining >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r21, [x]
    ld   LINK_HI, x
    ld   wf_r21 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r21:
    ld   poll >> 8, y
    jmp  poll

put2:
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
    ld   ac, [w_k]
    sub  10, ac
    bcc  p2_big
    ld   0x30, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wf_r39, [x]
    ld   LINK_HI, x
    ld   wf_r39 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wf_r39:
p2_big:
    ld   [w_k], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   wf_r40, [x]
    ld   LINK_HI, x
    ld   wf_r40 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
wf_r40:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; host - the web site's name, then OPEN: flags 0, port 80, the name
; ------------------------------------------------------------

#addr 0x0300
poll:
    ld   20, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   wf_r22, [x]
    ld   LINK_HI, x
    ld   wf_r22 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
wf_r22:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   wf_r23, [x]
    ld   LINK_HI, x
    ld   wf_r23 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
wf_r23:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   wf_r24, [x]
    ld   LINK_HI, x
    ld   wf_r24 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
wf_r24:
    clr  ac
    ld   ac, [wf_n]
    ld   C_STATE, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r25, [x]
    ld   LINK_HI, x
    ld   wf_r25 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r25:
    beq  pl_got
    ld   linkfail >> 8, y
    jmp  linkfail
pl_got:
    ld   WF_RX >> 8, y
    clr  x
    ld   [y,x], ac              ; 1 joining, 2 joined, 3 failed
    xor  1, ac
    bne  pl_done
    ld   0x2E, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wf_r26, [x]
    ld   LINK_HI, x
    ld   wf_r26 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wf_r26:
    bra  poll
pl_done:
    xor  3, ac
    beq  pl_ok
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r27, [x]
    ld   LINK_HI, x
    ld   wf_r27 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r27:
    ld   s_failed & 0xFF, ac
    ld   ac, [R0]
    ld   s_failed >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r28, [x]
    ld   LINK_HI, x
    ld   wf_r28 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r28:
    ld   halt >> 8, y
    jmp  halt
pl_ok:
    ld   showip >> 8, y
    jmp  showip

; ------------------------------------------------------------
; showip - the four bytes after the state are the address
; ------------------------------------------------------------
showip:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r29, [x]
    ld   LINK_HI, x
    ld   wf_r29 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r29:
    ld   s_ip & 0xFF, ac
    ld   ac, [R0]
    ld   s_ip >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r30, [x]
    ld   LINK_HI, x
    ld   wf_r30 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r30:
    ld   1, ac
    ld   ac, [w_k]
si_loop:
    ld   [w_k], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   wf_r31, [x]
    ld   LINK_HI, x
    ld   wf_r31 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
wf_r31:
    ld   [w_k], ac
    xor  4, ac
    beq  si_end
    ld   0x2E, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wf_r32, [x]
    ld   LINK_HI, x
    ld   wf_r32 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wf_r32:
    ld   [w_k], ac
    inc
    ld   ac, [w_k]
    bra  si_loop
si_end:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r33, [x]
    ld   LINK_HI, x
    ld   wf_r33 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r33:
    ld   time >> 8, y
    jmp  time

; ------------------------------------------------------------
; time - year - 2000, month, day, hour, minute, second (UTC)
; ------------------------------------------------------------
ap_str:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    beq  as_end
    ld   [wf_n], x
    ld   WF_TX >> 8, y
    ld   ac, [y,x]
    ld   [wf_n], ac
    inc
    ld   ac, [wf_n]
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bra  ap_str
as_end:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; recv - RECV up to 255 bytes at a time and print them, until the
; site closes
; ------------------------------------------------------------
time:
    clr  ac
    ld   ac, [wf_n]
    ld   C_TIME, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r34, [x]
    ld   LINK_HI, x
    ld   wf_r34 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r34:
    bne  tm_skip                ; the module has no time yet
    ld   s_time & 0xFF, ac
    ld   ac, [R0]
    ld   s_time >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r35, [x]
    ld   LINK_HI, x
    ld   wf_r35 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r35:
    clr  ac
    ld   ac, [w_j]
tm_loop:
    ld   [w_j], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL put2
    ld   wf_r36, [x]
    ld   LINK_HI, x
    ld   wf_r36 >> 8, [x]
    ld   put2 >> 8, y
    jmp  put2
wf_r36:
    ld   [w_j], ac
    xor  5, ac
    beq  tm_end
    ld   [w_j], ac
    add  tm_sep & 0xFF, x
    ld   tm_sep >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wf_r37, [x]
    ld   LINK_HI, x
    ld   wf_r37 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wf_r37:
    ld   [w_j], ac
    inc
    ld   ac, [w_j]
    bra  tm_loop
tm_end:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r38, [x]
    ld   LINK_HI, x
    ld   wf_r38 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r38:
tm_skip:
    ld   host >> 8, y
    jmp  host
tm_sep:
    #d "-- ::"

; ------------------------------------------------------------
; put2 - AC = 0-99 as two digits
; ------------------------------------------------------------
host:
    ld   s_host & 0xFF, ac
    ld   ac, [R0]
    ld   s_host >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r41, [x]
    ld   LINK_HI, x
    ld   wf_r41 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r41:
    clr  ac
    ld   ac, [R0]
    ld   ac, [w_hl]
    ld   W_HOST >> 8, ac
    ld   ac, [R1]
    ld   ac, [w_hh]
    ld   60, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL con_gets
    ld   wf_r42, [x]
    ld   LINK_HI, x
    ld   wf_r42 >> 8, [x]
    ld   con_gets >> 8, y
    jmp  con_gets
wf_r42:
    bne  hs_open
    ld   s_def & 0xFF, ac       ; nothing typed
    ld   ac, [w_hl]
    ld   s_def >> 8, ac
    ld   ac, [w_hh]
hs_open:
    ld   WF_TX >> 8, y
    clr  x
    ld   0, [y,x]               ; flags: 1 would be TLS
    ld   1, x
    ld   0, [y,x]               ; port, high byte
    ld   2, x
    ld   80, [y,x]              ; and low
    ld   3, ac
    ld   ac, [wf_n]
    ld   [w_hl], ac
    ld   ac, [R0]
    ld   [w_hh], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ap_str
    ld   wf_r43, [x]
    ld   LINK_HI, x
    ld   wf_r43 >> 8, [x]
    ld   ap_str >> 8, y
    jmp  ap_str
wf_r43:
    ld   C_OPEN, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r44, [x]
    ld   LINK_HI, x
    ld   wf_r44 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r44:
    beq  hs_ok
    ld   s_noopen & 0xFF, ac
    ld   ac, [R0]
    ld   s_noopen >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r45, [x]
    ld   LINK_HI, x
    ld   wf_r45 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r45:
    ld   halt >> 8, y
    jmp  halt
hs_ok:
    ld   get >> 8, y
    jmp  get

; ------------------------------------------------------------
; get - SEND the HTTP request
; ------------------------------------------------------------

#addr 0x0500
get:
    clr  ac
    ld   ac, [wf_n]
    ld   s_get1 & 0xFF, ac
    ld   ac, [R0]
    ld   s_get1 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ap_str
    ld   wf_r46, [x]
    ld   LINK_HI, x
    ld   wf_r46 >> 8, [x]
    ld   ap_str >> 8, y
    jmp  ap_str
wf_r46:
    ld   [w_hl], ac
    ld   ac, [R0]
    ld   [w_hh], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ap_str
    ld   wf_r47, [x]
    ld   LINK_HI, x
    ld   wf_r47 >> 8, [x]
    ld   ap_str >> 8, y
    jmp  ap_str
wf_r47:
    ld   s_get2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_get2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ap_str
    ld   wf_r48, [x]
    ld   LINK_HI, x
    ld   wf_r48 >> 8, [x]
    ld   ap_str >> 8, y
    jmp  ap_str
wf_r48:
    ld   C_SEND, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r49, [x]
    ld   LINK_HI, x
    ld   wf_r49 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r49:
    beq  gt_ok
    ld   linkfail >> 8, y
    jmp  linkfail
gt_ok:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r50, [x]
    ld   LINK_HI, x
    ld   wf_r50 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r50:
    ld   recv >> 8, y
    jmp  recv

; ------------------------------------------------------------
; ap_str - add the string at R1:R0 (ending in 00, in one page) to the
; request: WF_TX + wf_n on, wf_n moved on
; ------------------------------------------------------------
recv:
    ld   WF_TX >> 8, y
    clr  x
    ld   255, [y,x]
    ld   1, ac
    ld   ac, [wf_n]
    ld   C_RECV, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r51, [x]
    ld   LINK_HI, x
    ld   wf_r51 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r51:
    bne  rc_end                 ; 3: closed and nothing left
    ld   [wf_len], ac
    beq  rc_idle
    clr  ac
    ld   ac, [w_k]
rc_put:
    ld   [w_k], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   ac, [w_j]
    xor  0x0A, ac
    beq  rc_ok                  ; a new line
    ld   [w_j], ac
    sub  0x20, ac
    bcs  rc_skip                ; other control codes: not printed
    ld   [w_j], ac
    blt  rc_skip                ; nor 80h and above
rc_ok:
    ld   [w_j], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   wf_r52, [x]
    ld   LINK_HI, x
    ld   wf_r52 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
wf_r52:
rc_skip:
    ld   [w_k], ac
    inc
    ld   ac, [w_k]
    xor  [wf_len], ac
    bne  rc_put
    bra  recv
rc_idle:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   wf_r53, [x]
    ld   LINK_HI, x
    ld   wf_r53 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
wf_r53:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   wf_r54, [x]
    ld   LINK_HI, x
    ld   wf_r54 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
wf_r54:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   wf_r55, [x]
    ld   LINK_HI, x
    ld   wf_r55 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
wf_r55:
    bra  recv
rc_end:
    ld   done >> 8, y
    jmp  done


#addr 0x0600
done:
    clr  ac
    ld   ac, [wf_n]
    ld   C_CLOSE, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   wf_r56, [x]
    ld   LINK_HI, x
    ld   wf_r56 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
wf_r56:
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r57, [x]
    ld   LINK_HI, x
    ld   wf_r57 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r57:
    ld   s_done & 0xFF, ac
    ld   ac, [R0]
    ld   s_done >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r58, [x]
    ld   LINK_HI, x
    ld   wf_r58 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r58:
    ld   halt >> 8, y
    jmp  halt

; ------------------------------------------------------------
; linkfail - AC = wf_xfer's status; halt - wait for Esc
; ------------------------------------------------------------
linkfail:
    ld   ac, [w_k]
    ld   LINK_LO, x             ; CALL con_newline
    ld   wf_r59, [x]
    ld   LINK_HI, x
    ld   wf_r59 >> 8, [x]
    ld   con_newline >> 8, y
    jmp  con_newline
wf_r59:
    ld   s_link & 0xFF, ac
    ld   ac, [R0]
    ld   s_link >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   wf_r60, [x]
    ld   LINK_HI, x
    ld   wf_r60 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
wf_r60:
    ld   [w_k], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   wf_r61, [x]
    ld   LINK_HI, x
    ld   wf_r61 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
wf_r61:
halt:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   wf_r62, [x]
    ld   LINK_HI, x
    ld   wf_r62 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
wf_r62:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   wf_r63, [x]
    ld   LINK_HI, x
    ld   wf_r63 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
wf_r63:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   wf_r64, [x]
    ld   LINK_HI, x
    ld   wf_r64 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
wf_r64:
    bra  halt

; ============================================================
; the driver
; ============================================================

; ------------------------------------------------------------
; wf_find - look for the WiFi card in slots 1-4
;   out:     AC = 0: found, wf_y and wf_x = its register's page and
;            offset, wf_i = slot - 1.  AC = 1: no card
;   changes: X, Y, wf_i
;   The card's two read addresses differ in D5:D2: 1010 at the even
;   one, 0101 at the odd one.  An empty slot, or a memory card, reads
;   the same bits at both.
; ------------------------------------------------------------
wf_find:
    clr  ac
    ld   ac, [wf_i]
ff_loop:
    ld   [wf_i], ac
    add  ff_hi & 0xFF, x
    ld   ff_hi >> 8, y
    ld   [y,x], ac
    ld   ac, [wf_y]
    ld   [wf_i], ac
    add  ff_lo & 0xFF, x
    ld   [y,x], ac
    ld   ac, [wf_x]
    ld   [wf_y], y
    ld   [wf_x], x
    ld   [y,x], ac
    and  0x3C, ac
    xor  0x28, ac
    bne  ff_next
    ld   [wf_x], ac
    add  1, x
    ld   [y,x], ac
    and  0x3C, ac
    xor  0x14, ac
    bne  ff_next
    ld   [LINK_HI], y           ; AC = 0
    jmp  [LINK_LO]
ff_next:
    ld   [wf_i], ac
    inc
    ld   ac, [wf_i]
    xor  4, ac
    bne  ff_loop
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
ff_hi:      ; slots 1-4
    #d8 0x51, 0x53, 0x51, 0x53
ff_lo:
    #d8 0x60, 0x60, 0xE0, 0xE0

; ------------------------------------------------------------
; wf_ready - wait until the module is ready for a transfer (READY, D6)
;   out:     AC = 0: ready.  AC = 1: not within about 15 seconds
;   changes: X, Y, T0-T2
; ------------------------------------------------------------

#addr 0x0700
wf_ready:
    ld   [wf_y], y
    ld   [wf_x], x
    clr  ac
    ld   ac, [T0]
    ld   ac, [T1]
    ld   ac, [T2]
wr_loop:
    ld   [y,x], ac
    and  0x40, ac
    bne  wr_ok
    ld   [T0], ac
    inc
    ld   ac, [T0]
    bne  wr_loop
    ld   [T1], ac
    inc
    ld   ac, [T1]
    bne  wr_loop
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  WF_TMO, ac
    bne  wr_loop
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
wr_ok:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; wf_byte - send and receive one byte on the card's SPI port
;   in:      AC = byte to send; /CS low (the register at WF_SEL)
;   out:     AC = byte received
;   changes: X, Y, T0-T2
;   SPI mode 3, most significant bit first, as spi_byte: the module
;   takes MOSI on the rising edge of SCK and changes MISO on the
;   falling edge.  Leaves SCK high and /CS low.
; ------------------------------------------------------------
wf_byte:
    ld   ac, [T0]
    ld   8, ac
    ld   ac, [T2]
    ld   [wf_y], y
    ld   [wf_x], x
wb_bit:
    ld   [T0], ac
    blt  wb_one
    ld   0x08, [y,x]            ; SCK low, MOSI 0
    ld   0x09, [y,x]            ; SCK high
    bra  wb_rd
wb_one:
    ld   0x0A, [y,x]            ; SCK low, MOSI 1
    ld   0x0B, [y,x]            ; SCK high
wb_rd:
    ld   [y,x], ac              ; D7 = MISO
    blt  wb_m1
    ld   [T1], ac
    shl
    bra  wb_st
wb_m1:
    ld   [T1], ac
    shl
    or   1, ac
wb_st:
    ld   ac, [T1]
    ld   [T0], ac
    shl
    ld   ac, [T0]
    ld   [T2], ac
    dec
    ld   ac, [T2]
    bne  wb_bit
    ld   [T1], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; wf_xfer - one request to the module and its reply
;   in:      AC = command, wf_n = request bytes (0-255) in WF_TX
;   out:     AC = wf_st = the reply's status: 00 done, others as the
;            command says; FE = the module is not ready (no module, or
;            it is busy longer than wf_ready waits), FD = its answer
;            is not a reply.  wf_len = data bytes in WF_RX, and a 00
;            after them
;   changes: X, Y, T0-T2, wf_cmd, wf_i, wf_try, wf_mark
;   Uses 2 stack bytes.
;   A request is one transfer (/CS low to /CS high): the command, the
;   length, the bytes.  The module's first byte in it is 52h when it
;   was waiting for a request.  If it was not (a program left before
;   reading a reply), that transfer threw the old reply away and the
;   request is sent once more.  The reply is the next transfer: 41h,
;   status, length, data.
; ------------------------------------------------------------
wf_xfer:
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
    ld   ac, [wf_cmd]
    ld   2, ac
    ld   ac, [wf_try]
wx_again:
    ld   LINK_LO, x             ; CALL wf_ready
    ld   wf_r65, [x]
    ld   LINK_HI, x
    ld   wf_r65 >> 8, [x]
    ld   wf_ready >> 8, y
    jmp  wf_ready
wf_r65:
    bne  wx_dead
    ld   [wf_y], y
    ld   [wf_x], x
    ld   WF_SEL, [y,x]          ; /CS low
    ld   [wf_cmd], ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   wf_r66, [x]
    ld   LINK_HI, x
    ld   wf_r66 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
wf_r66:
    ld   ac, [wf_mark]
    ld   [wf_n], ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   wf_r67, [x]
    ld   LINK_HI, x
    ld   wf_r67 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
wf_r67:
    clr  ac
    ld   ac, [wf_i]
wx_out:
    ld   [wf_i], ac
    xor  [wf_n], ac
    beq  wx_sent
    ld   [wf_i], x
    ld   WF_TX >> 8, y
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   wf_r68, [x]
    ld   LINK_HI, x
    ld   wf_r68 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
wf_r68:
    ld   [wf_i], ac
    inc
    ld   ac, [wf_i]
    bra  wx_out
wx_sent:
    ld   wx_reply >> 8, y
    jmp  wx_reply
wx_dead:
    ld   0xFE, ac
    ld   ac, [wf_st]
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0x0800
wx_reply:
    ld   [wf_y], y
    ld   [wf_x], x
    ld   WF_IDLE, [y,x]         ; /CS high: the request ends
    ld   [wf_mark], ac
    xor  0x52, ac
    beq  wx_rd
    ld   [wf_try], ac           ; the module was not waiting for a request
    dec
    ld   ac, [wf_try]
    beq  wx_lost
    ld   wx_again >> 8, y
    jmp  wx_again
wx_rd:
    ld   LINK_LO, x             ; CALL wf_ready
    ld   wf_r69, [x]
    ld   LINK_HI, x
    ld   wf_r69 >> 8, [x]
    ld   wf_ready >> 8, y
    jmp  wf_ready
wf_r69:
    bne  wx_gone
    ld   [wf_y], y
    ld   [wf_x], x
    ld   WF_SEL, [y,x]
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   wf_r70, [x]
    ld   LINK_HI, x
    ld   wf_r70 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
wf_r70:
    xor  0x41, ac
    bne  wx_bad
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   wf_r71, [x]
    ld   LINK_HI, x
    ld   wf_r71 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
wf_r71:
    ld   ac, [wf_st]
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   wf_r72, [x]
    ld   LINK_HI, x
    ld   wf_r72 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
wf_r72:
    ld   ac, [wf_len]
    clr  ac
    ld   ac, [wf_i]
    ld   wx_in >> 8, y
    jmp  wx_in
wx_bad:
    ld   [wf_y], y
    ld   [wf_x], x
    ld   WF_IDLE, [y,x]
wx_lost:
    ld   0xFD, ac
    ld   ac, [wf_st]
    ld   lib_leave >> 8, y
    jmp  lib_leave
wx_gone:
    ld   0xFE, ac
    ld   ac, [wf_st]
    ld   lib_leave >> 8, y
    jmp  lib_leave

wx_in:
    ld   [wf_i], ac
    xor  [wf_len], ac
    beq  wx_end
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   wf_r73, [x]
    ld   LINK_HI, x
    ld   wf_r73 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
wf_r73:
    ld   [wf_i], x
    ld   WF_RX >> 8, y
    ld   ac, [y,x]
    ld   [wf_i], ac
    inc
    ld   ac, [wf_i]
    bra  wx_in
wx_end:
    ld   [wf_len], x
    ld   WF_RX >> 8, y
    ld   0, [y,x]               ; a 00 after the data
    ld   [wf_y], y
    ld   [wf_x], x
    ld   WF_IDLE, [y,x]         ; /CS high: the reply ends
    ld   [wf_st], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; data
; ============================================================

#addr 0x0900
s_title:
    #d "  PLACARD WIFI", 0x00
s_nocard:
    #d "  There is no WiFi card in a slot.  Esc: exit", 0x00
s_slot:
    #d "  WiFi card in slot ", 0x00
s_fw:
    #d "  Module: ", 0x00
s_name:
    #d "  Network name (Enter: the one used last): ", 0x00
s_pass:
    #d "  Password: ", 0x00
s_nosaved:
    #d "  The module has no network kept.  Esc: exit", 0x00

#addr 0x0A00
s_joining:
    #d "  Joining ", 0x00
s_failed:
    #d "  Could not join that network.  Esc: exit", 0x00
s_ip:
    #d "  Joined.  Address ", 0x00
s_time:
    #d "  Time (UTC) 20", 0x00
s_host:
    #d "  Web site (Enter: example.com): ", 0x00
s_def:
    #d "example.com", 0x00
s_noopen:
    #d "  Could not reach that site.  Esc: exit", 0x00

#addr 0x0B00
s_get1:
    #d "GET / HTTP/1.0", 0x0D, 0x0A, "Host: ", 0x00
s_get2:
    #d 0x0D, 0x0A, "Connection: close", 0x0D, 0x0A, 0x0D, 0x0A, 0x00
s_done:
    #d "  The site closed.  Esc: exit", 0x00
s_link:
    #d "  The module does not answer.  Esc: exit.  Error ", 0x00
