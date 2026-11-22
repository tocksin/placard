; ============================================================
; made by asm_expand.py from web.masm: change that file, then run
;     python3 asm_expand.py web.masm
; ============================================================

; ============================================================
; web.masm - WEB.PLC: a web browser for the WiFi card
; ============================================================
;
; A library program the DOS runs from the card (Enter on WEB.PLC in the
; browser, or in Pinboard's Files card).  It needs the WiFi expansion
; card (docs/architecture/WIFICARD.md) with the module's firmware 1.1.
;
; The module does the work (src/firmware/wifi_card/: browser.cpp,
; html.cpp, image.cpp): it fetches the page (HTTP or HTTPS), turns its
; HTML into lines of text 76 characters wide, keeps the links, and turns
; the page's pictures into pixels this board shows.  This program asks
; for the lines on the screen and draws them, and sends the keys' and
; the mouse's choices back: "The browser's commands" in WIFICARD.md.
; docs/software/WEB.md is the program's page.
;
; The screen, in Pinboard's look and with its font and pointer
; (wave_data.asm): the page's title beside the pin; its address; the page,
; black on white, 43 lines of 76 characters, a line every 10 pixel rows so
; that a link's underline has room under the letters; the rail with the
; keys and a line of messages.  Links are underlined, the link chosen is
; white on black and its address is in the rail.  A picture in the page
; is 1 bit a pixel (the module dithers it); a picture opened alone fills
; the screen in 256 colors, 80 pixels across or 160 on a rev B board
; (the photo viewer's rows, docs/video/HIRES.md).
;
;     Down, Up                3 lines on, or back
;     Space, B                a screen on, or back;  Home: the page's top
;     Tab, Right, Left        the next link, the one before
;     Enter                   open the link chosen (a picture: alone)
;     Backspace               the page before (the module keeps 8)
;     G, Ctrl+L               type an address, or words to search for
;     R                       fetch the page again
;     H                       a picture alone: 160 across or 80
;     Esc                     back to the DOS or Pinboard (menu_poll)
;
; The mouse: a click on a link opens it, the right button goes back, the
; pin in the title closes the program.
;
; The pictures of a page come after its text, one at a time while no key
; is down (IMGLOAD): the lines under a picture move down as it arrives.
;
; RAM: the program at x0100 (asm_expand.py pages it), the font
; x3000-x37FF and the pointer's tables x3800-x39FF, zero page x20-x8F,
; the request x4000, the reply x4100, the links on the screen
; x4200-x46FF, the screen under the pointer x4700.
;
;     python3 gen_wave_data.py                        wave_data.asm
;     python3 asm_expand.py web.masm                  web.asm
;     python3 gen_plc.py web.asm -o ../../sdcard/WEB.PLC
;     python3 test_web.py                             runs it in the emulator
;
; Date: 11/22/2026
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
wf_tmo  = 0x29              ; wf_ready gives up after this many times 15 s

wb_t    = 0x2A              ; scratch
wb_d    = 0x2B              ; scratch
wb_k    = 0x2C              ; counter; the link to choose
wb_topl = 0x2D              ; the page line at the top of the screen
wb_toph = 0x2E
wb_nl   = 0x2F              ; lines in the page
wb_nh   = 0x30
wb_flag = 0x31              ; the page: bit 1 = it is a picture
wb_pend = 0x32              ; pictures of the page not fetched yet
wb_ln   = 0x33              ; draw: the screen line, 0-42
wb_ll   = 0x34              ; the page line
wb_lh   = 0x35
wb_pg   = 0x36              ; the screen page of the character's column
wb_ch   = 0x37              ; the character
wb_l0   = 0x38              ; 10: the low bytes of the line's pixel rows
wb_u8   = 0x42              ; what goes in rows 8 and 9 under a character:
wb_u9   = 0x43              ;   FF white, 00 black (the underline)
wb_inv  = 0x44              ; 80: black on white.  00: the link chosen
wb_bold = 0x45              ; 80: bold
wb_col  = 0x46              ; the column, 0-75
wb_i    = 0x47              ; the place in the reply
wb_inl  = 0x48              ; 1: in a link
wb_idh  = 0x49              ; its number
wb_idl  = 0x4A
wb_c0   = 0x4B              ; its first column in the line
wb_half = 0x4C              ; 1: the line is in its columns' second pages
wb_dt   = 0x4D              ; draw's scratch
wb_part = 0x4E              ; a picture's strip: the part asked for
wb_sc   = 0x4F              ; its byte columns to go
wb_runs = 0x50              ; links on the screen (a link is one for each line it is in)
wb_tab  = 0x51              ; 1: the lines drawn fill the table of them
wb_has  = 0x52              ; 1: a link is chosen:
wb_sel  = 0x53              ;   its first place in the table
wb_selh = 0x54              ;   its number
wb_sell = 0x55
wb_auto = 0x56              ; 1: choose the screen's first link when it is drawn
wb_r    = 0x57              ; a place in the table
wb_last = 0x58              ; the line last drawn again
wb_key  = 0x59              ; the key
wb_frm  = 0x5A              ; FRAME_LO when the keys were last read
wb_cmd  = 0x5B              ; the command that fetches a page
wb_mode = 0x5C              ; a picture alone: its rows' mode byte
wb_w    = 0x5D              ; its width in bytes
wb_c    = 0x5E              ; its column
wb_a    = 0x5F              ; scratch
wb_b    = 0x60
wb_e    = 0x61
wb_f    = 0x62
wb_io   = 0x63              ; input: where in the request the line goes
wb_im   = 0x64              ; and the most characters
wb_mb   = 0x65              ; 1: a button was down at the last packet
wb_mok  = 0x66              ; 0: a mouse runs
wb_pxl  = 0x67              ; the pointer: X 0-639
wb_pxh  = 0x68
wb_pyl  = 0x69              ; Y 0-479
wb_pyh  = 0x6A
wb_son  = 0x6B              ; 1: the pointer is on the screen, at:
wb_sc2  = 0x6C              ;   60 + 2 x its byte column
wb_syl  = 0x6D              ;   its first row
wb_syh  = 0x6E
wb_sti  = 0x6F              ;   its shift << 4
wb_sn   = 0x70              ;   its rows on the screen
wb_sk   = 0x71              ;   1: its right byte is on the screen too

WF_TX     = 0x4000          ; request bytes (255 at most)
WF_RX     = 0x4100          ; reply bytes (255 at most) and a 00
LN_LINE   = 0x4200          ; the links on the screen: the screen line,
LN_C0     = 0x4300          ;   the first column,
LN_C1     = 0x4400          ;   the column after the last,
LN_HI     = 0x4500          ;   the link's number
LN_LO     = 0x4600
PSAVE     = 0x4700          ; the screen under the pointer: 2 bytes a row
FONT      = 0x3000          ; the font, 8 pages (wave_data.asm)
PTR       = 0x3800          ; the pointer's mask and white pixels, 2 pages
MAP_RUN   = 0x07            ; the program's map: RAM to x5FFF, the ROM above

WF_IDLE   = 0x0F            ; the register at rest: the module runs, /CS, MOSI, SCK high
WF_SEL    = 0x0B            ; /CS low, SCK high
TMO_SHORT = 1               ; 15 s: the module's own commands
TMO_LONG  = 12              ; 3 minutes: a page and its redirects

C_JOIN    = 0x02            ; the card's commands (WIFICARD.md)
C_STATE   = 0x03
B_VIEW    = 0x30            ; the browser's
B_GO      = 0x31
B_LINK    = 0x32
B_BACK    = 0x33
B_RELOAD  = 0x34
B_INFO    = 0x35
B_ROW     = 0x36
B_IMGLOAD = 0x37
B_LNINFO  = 0x38
B_PICTURE = 0x39
B_PICDATA = 0x3A
B_PICEND  = 0x3B

COLS      = 76              ; characters in a line: the screen's columns 2-77
LINES     = 43              ; lines on the screen: pixel rows 24-453
PITCH     = 10              ; pixel rows a line
STEP      = 3               ; lines Down and Up move
PAGE      = 40              ; lines Space and B move
MODE_160  = 0x87            ; a picture alone: 160-read rows, 2x, 8 bits a pixel (rev B)
MODE_80   = 0x07            ; normal rows, 2x, 8 bits a pixel

MB_PWIDE  = 0x1A            ; the menu block: the photo viewer's mode byte (Pinboard sets it)

#include "wave_data.asm"



; ============================================================
; main - the mouse, the screen
; ============================================================

#addr 0x0100
main:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    clr  ac
    ld   ac, [wb_son]
    ld   ac, [wb_mb]
    ld   ac, [wb_has]
    ld   ac, [wb_pend]
    ld   ac, [wb_nl]
    ld   ac, [wb_nh]
    ld   ac, [wb_topl]
    ld   ac, [wb_toph]
    ld   ac, [wb_runs]
    ld   ac, [wb_tab]
    ld   ac, [wb_auto]
    ld   ac, [wb_pyh]
    ld   1, ac
    ld   ac, [wb_pxh]
    ld   320 & 0xFF, ac
    ld   ac, [wb_pxl]
    ld   240, ac
    ld   ac, [wb_pyl]
    ld   TMO_SHORT, ac
    ld   ac, [wf_tmo]
    ld   MODE_80, ac
    ld   ac, [wb_mode]
    ld   MENU_BLK >> 8, y       ; Pinboard in a color mode: a rev B board
    ld   MB_MAGIC, x
    ld   [y,x], ac
    xor  0x4D, ac
    bne  mn_mouse
    ld   MB_PWIDE, x
    ld   [y,x], ac
    xor  MODE_160, ac
    bne  mn_mouse
    ld   MODE_160, ac
    ld   ac, [wb_mode]
mn_mouse:
    ld   [MOUSE_ST], ac         ; Pinboard's mouse runs on
    blt  mn_run
    ld   LINK_LO, x             ; CALL mouse_init
    ld   web_r1, [x]
    ld   LINK_HI, x
    ld   web_r1 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
web_r1:
    bra  mn_set
mn_run:
    clr  ac
mn_set:
    ld   ac, [wb_mok]
    ld   LINK_LO, x             ; CALL screen
    ld   web_r2, [x]
    ld   LINK_HI, x
    ld   web_r2 >> 8, [x]
    ld   screen >> 8, y
    jmp  screen
web_r2:
    ld   find >> 8, y
    jmp  find

; ------------------------------------------------------------
; screen - the title's row and the page white, the address's row black,
; the rail with the keys
; ------------------------------------------------------------
screen:
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
    ld   web_r3, [x]
    ld   LINK_HI, x
    ld   web_r3 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
web_r3:
    ld   0x5B, y                ; the rail's rows 456-479 tinted blue, as
    ld   23, ac                 ; Pinboard's
sc_tint:
    add  0xE8, x
    ld   0x40, [y,x]
    sub  1, ac
    bcc  sc_tint
    ld   FONT >> 8, ac
    ld   ac, [FONT_PG]
    clr  ac
    ld   ac, [wb_son]
    ld   ac, [CUR_ROW]
    ld   ac, [CUR_COL]
    ld   0xA0, ac
    ld   ac, [wb_t]
    ld   80, ac
    ld   ac, [wb_k]
    ld   LINK_LO, x             ; CALL fill
    ld   web_r4, [x]
    ld   LINK_HI, x
    ld   web_r4 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
web_r4:
    ld   2, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   55, ac
    ld   ac, [wb_d]
sc_row:
    ld   80, ac
    ld   ac, [wb_k]
    ld   LINK_LO, x             ; CALL fill
    ld   web_r5, [x]
    ld   LINK_HI, x
    ld   web_r5 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
web_r5:
    ld   [wb_d], ac
    dec
    ld   ac, [wb_d]
    bne  sc_row
    ld   screen2 >> 8, y
    jmp  screen2

wipe:
    ld   LINK_LO, x             ; CALL blank
    ld   web_r58, [x]
    ld   LINK_HI, x
    ld   web_r58 >> 8, [x]
    ld   blank >> 8, y
    jmp  blank
web_r58:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; blank - columns wb_col to 75 of the line white (a leaf)
back:
    clr  ac
    ld   ac, [wf_n]
    ld   B_BACK, ac
    ld   load >> 8, y
    jmp  load

; redraw - the screen from a new top line; no link chosen, or the first

#addr 0x0200
screen2:
    ld   0x10, ac
    ld   ac, [wb_t]
    ld   80, ac
    ld   ac, [wb_k]
    ld   LINK_LO, x             ; CALL fill
    ld   web_r6, [x]
    ld   LINK_HI, x
    ld   web_r6 >> 8, [x]
    ld   fill >> 8, y
    jmp  fill
web_r6:
    ld   s_keys & 0xFF, ac
    ld   ac, [R0]
    ld   s_keys >> 8, ac
    ld   ac, [R1]
    ld   58, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL con_puts
    ld   web_r7, [x]
    ld   LINK_HI, x
    ld   web_r7 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
web_r7:
    clr  ac
    ld   ac, [CUR_ROW]
    ld   ac, [CUR_COL]
    ld   0x87, ac               ; the pin
    ld   LINK_LO, x             ; CALL con_putc
    ld   web_r8, [x]
    ld   LINK_HI, x
    ld   web_r8 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
web_r8:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; fill - the character wb_t, wb_k times, from the cursor on
; ------------------------------------------------------------
fill:
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
fi_l:
    ld   [wb_t], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   web_r9, [x]
    ld   LINK_HI, x
    ld   web_r9 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
web_r9:
    ld   [wb_k], ac
    dec
    ld   ac, [wb_k]
    bne  fi_l
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; text - the string at R1:R0 from the cursor on in wb_k cells: cut
; there, or spaces after it; wb_t = 80 for black on white
; ------------------------------------------------------------
text:
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
tx_l:
    ld   [wb_k], ac
    beq  tx_x
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    beq  tx_pad
    and  0x7F, ac
    or   [wb_t], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   web_r10, [x]
    ld   LINK_HI, x
    ld   web_r10 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
web_r10:
    ld   [wb_k], ac
    dec
    ld   ac, [wb_k]
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  tx_l
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  tx_l
tx_pad:
    ld   0x20, ac
    or   [wb_t], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   web_r11, [x]
    ld   LINK_HI, x
    ld   web_r11 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
web_r11:
    ld   [wb_k], ac
    dec
    ld   ac, [wb_k]
    bne  tx_pad
tx_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; status - the message at AC in s_msg's page in the rail's last row
; (status2, status3: in s_msg2's, s_msg3's); statrx - the reply's text
; ------------------------------------------------------------
set_modes:
    ld   0x5A, y
    ld   0x20, ac
    ld   ac, [wb_t]
sm_1:
    ld   [wb_t], x
    ld   [wb_mode], ac
    ld   ac, [y,x]
    ld   [wb_t], ac
    inc
    ld   ac, [wb_t]
    bne  sm_1
    ld   0x5B, y
sm_2:
    ld   [wb_t], x
    ld   [wb_mode], ac
    ld   ac, [y,x]
    ld   [wb_t], ac
    inc
    ld   ac, [wb_t]
    bne  sm_2
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; pcol - column wb_c of the picture: 240 bytes, top to bottom.  The
; column is a page of the video RAM (160 across: x60 + c; 80 across: the
; odd pages, x61 + 2 c); row r is at low byte 32 + 2 r (rows 0-111) or
; 2 r - 223 (rows 112-239), as the photo viewer's files have it.

#addr 0x0300
status:
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
    ld   ac, [R0]
    ld   s_msg >> 8, ac
    ld   ac, [R1]
    bra  stt_go
statrx:
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
    ld   ac, [R0]
    ld   WF_RX >> 8, ac
    ld   ac, [R1]
stt_go:
    ld   LINK_LO, x             ; CALL p_hide
    ld   web_r12, [x]
    ld   LINK_HI, x
    ld   web_r12 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
web_r12:
    ld   59, ac
    ld   ac, [CUR_ROW]
    ld   1, ac
    ld   ac, [CUR_COL]
    clr  ac
    ld   ac, [wb_t]
    ld   78, ac
    ld   ac, [wb_k]
    ld   LINK_LO, x             ; CALL text
    ld   web_r13, [x]
    ld   LINK_HI, x
    ld   web_r13 >> 8, [x]
    ld   text >> 8, y
    jmp  text
web_r13:
    ld   lib_leave >> 8, y
    jmp  lib_leave

status2:
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
    ld   ac, [R0]
    ld   s_msg2 >> 8, ac
    ld   ac, [R1]
    ld   stt_go >> 8, y
    jmp  stt_go
status3:
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
    ld   ac, [R0]
    ld   s_msg3 >> 8, ac
    ld   ac, [R1]
    ld   stt_go >> 8, y
    jmp  stt_go

; ------------------------------------------------------------
; chrome - the page's title and address in the first two rows
; ------------------------------------------------------------
chrome:
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
    ld   LINK_LO, x             ; CALL p_hide
    ld   web_r14, [x]
    ld   LINK_HI, x
    ld   web_r14 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
web_r14:
    ld   WF_TX >> 8, y
    clr  x
    ld   0, [y,x]
    ld   1, ac
    ld   ac, [wf_n]
    ld   B_INFO, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r15, [x]
    ld   LINK_HI, x
    ld   web_r15 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r15:
    clr  ac
    ld   ac, [R0]
    ld   ac, [CUR_ROW]
    ld   WF_RX >> 8, ac
    ld   ac, [R1]
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   0x80, ac
    ld   ac, [wb_t]
    ld   77, ac
    ld   ac, [wb_k]
    ld   LINK_LO, x             ; CALL text
    ld   web_r16, [x]
    ld   LINK_HI, x
    ld   web_r16 >> 8, [x]
    ld   text >> 8, y
    jmp  text
web_r16:
    ld   chrome2 >> 8, y
    jmp  chrome2


#addr 0x0400
chrome2:
    ld   WF_TX >> 8, y
    clr  x
    ld   1, [y,x]
    ld   1, ac
    ld   ac, [wf_n]
    ld   B_INFO, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r17, [x]
    ld   LINK_HI, x
    ld   web_r17 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r17:
    clr  ac
    ld   ac, [R0]
    ld   ac, [wb_t]
    ld   WF_RX >> 8, ac
    ld   ac, [R1]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   ac, [CUR_COL]
    ld   78, ac
    ld   ac, [wb_k]
    ld   LINK_LO, x             ; CALL text
    ld   web_r18, [x]
    ld   LINK_HI, x
    ld   web_r18 >> 8, [x]
    ld   text >> 8, y
    jmp  text
web_r18:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; input - a line typed in the address's row into the request from
; wb_io on, wb_im characters at most; AC = its length
; ------------------------------------------------------------
input:
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
    ld   LINK_LO, x             ; CALL p_hide
    ld   web_r19, [x]
    ld   LINK_HI, x
    ld   web_r19 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
web_r19:
    ld   s_empty & 0xFF, ac
    ld   ac, [R0]
    ld   s_empty >> 8, ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [wb_t]
    ld   78, ac
    ld   ac, [wb_k]
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL text
    ld   web_r20, [x]
    ld   LINK_HI, x
    ld   web_r20 >> 8, [x]
    ld   text >> 8, y
    jmp  text
web_r20:
    ld   1, ac
    ld   ac, [CUR_ROW]
    ld   ac, [CUR_COL]
    ld   [wb_io], ac
    ld   ac, [R0]
    ld   WF_TX >> 8, ac
    ld   ac, [R1]
    ld   [wb_im], ac
    ld   ac, [R2]
    ld   LIB_FONT >> 8, ac      ; (Esc leaves from in there)
    ld   ac, [FONT_PG]
    ld   LINK_LO, x             ; CALL con_gets
    ld   web_r21, [x]
    ld   LINK_HI, x
    ld   web_r21 >> 8, [x]
    ld   con_gets >> 8, y
    jmp  con_gets
web_r21:
    ld   ac, [wb_t]
    ld   FONT >> 8, ac
    ld   ac, [FONT_PG]
    ld   [wb_t], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; esc - menu_poll, with the standard font back first when Esc is down
; ------------------------------------------------------------
esc:
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
    ld   [KBD_NOW + (K_ESC >> 3)], ac
    and  1 << (K_ESC & 7), ac
    bne  es_poll
    ld   LIB_FONT >> 8, ac
    ld   ac, [FONT_PG]
es_poll:
    ld   LINK_LO, x             ; CALL menu_poll
    ld   web_r22, [x]
    ld   LINK_HI, x
    ld   web_r22 >> 8, [x]
    ld   menu_poll >> 8, y
    jmp  menu_poll
web_r22:
    ld   FONT >> 8, ac
    ld   ac, [FONT_PG]
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; fail - the message at AC (s_msg's page), then wait for Esc
; ------------------------------------------------------------
leave:
    ld   MENU_BLK >> 8, y
    ld   MB_MAGIC, x
    ld   [y,x], ac
    xor  0x4D, ac               ; "M"
    bne  lv_stay
    ld   LIB_FONT >> 8, ac
    ld   ac, [FONT_PG]
    ld   MB_WHY, x
    ld   WHY_ESC, ac
    ld   ac, [y,x]
    jmp  MB_EXIT
lv_stay:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the pointer (Pinboard's, pinboard_drv_mono.masm)
; ============================================================
; p_hide - the screen under the pointer put back (T0-T3; a leaf)

#addr 0x0500
fail:
    ld   LINK_LO, x             ; CALL status
    ld   web_r23, [x]
    ld   LINK_HI, x
    ld   web_r23 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r23:
    ld   LINK_LO, x             ; CALL p_show
    ld   web_r24, [x]
    ld   LINK_HI, x
    ld   web_r24 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
web_r24:
fl_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   web_r25, [x]
    ld   LINK_HI, x
    ld   web_r25 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
web_r25:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   web_r26, [x]
    ld   LINK_HI, x
    ld   web_r26 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
web_r26:
    ld   LINK_LO, x             ; CALL esc
    ld   web_r27, [x]
    ld   LINK_HI, x
    ld   web_r27 >> 8, [x]
    ld   esc >> 8, y
    jmp  esc
web_r27:
    bra  fl_loop

; ============================================================
; find - the card; state - is its network joined?
; ============================================================
find:
    ld   LINK_LO, x             ; CALL wf_find
    ld   web_r28, [x]
    ld   LINK_HI, x
    ld   web_r28 >> 8, [x]
    ld   wf_find >> 8, y
    jmp  wf_find
web_r28:
    beq  state
    ld   s_nocard & 0xFF, ac
    ld   fail >> 8, y
    jmp  fail
state:
    clr  ac
    ld   ac, [wf_n]
    ld   C_STATE, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r29, [x]
    ld   LINK_HI, x
    ld   web_r29 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r29:
    beq  sx_got
    ld   s_dead & 0xFF, ac
    ld   fail >> 8, y
    jmp  fail
sx_got:
    ld   WF_RX >> 8, y
    clr  x
    ld   [y,x], ac              ; 1 joining, 2 joined, 3 failed, 0 none
    xor  2, ac
    beq  sx_on
    xor  2 ^ 1, ac
    beq  sx_wait
    xor  1 ^ 3, ac
    bne  sx_ask
    ld   s_failed & 0xFF, ac
    ld   LINK_LO, x             ; CALL status2
    ld   web_r30, [x]
    ld   LINK_HI, x
    ld   web_r30 >> 8, [x]
    ld   status2 >> 8, y
    jmp  status2
web_r30:
    ld   90, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   web_r31, [x]
    ld   LINK_HI, x
    ld   web_r31 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
web_r31:
sx_ask:
    ld   ask >> 8, y
    jmp  ask
sx_wait:
    ld   s_join & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r32, [x]
    ld   LINK_HI, x
    ld   web_r32 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r32:
    ld   20, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   web_r33, [x]
    ld   LINK_HI, x
    ld   web_r33 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
web_r33:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   web_r34, [x]
    ld   LINK_HI, x
    ld   web_r34 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
web_r34:
    ld   LINK_LO, x             ; CALL esc
    ld   web_r35, [x]
    ld   LINK_HI, x
    ld   web_r35 >> 8, [x]
    ld   esc >> 8, y
    jmp  esc
web_r35:
    bra  state
sx_on:
    ld   view >> 8, y
    jmp  view

; ------------------------------------------------------------
; ask - the network's name and password, typed; JOIN
; ------------------------------------------------------------

#addr 0x0600
ask:
    ld   s_net & 0xFF, ac
    ld   LINK_LO, x             ; CALL status2
    ld   web_r36, [x]
    ld   LINK_HI, x
    ld   web_r36 >> 8, [x]
    ld   status2 >> 8, y
    jmp  status2
web_r36:
    clr  ac
    ld   ac, [wb_io]
    ld   32, ac
    ld   ac, [wb_im]
    ld   LINK_LO, x             ; CALL input
    ld   web_r37, [x]
    ld   LINK_HI, x
    ld   web_r37 >> 8, [x]
    ld   input >> 8, y
    jmp  input
web_r37:
    ld   ac, [wf_n]
    beq  ak_join                ; nothing typed: the network the module kept
    ld   s_pass & 0xFF, ac
    ld   LINK_LO, x             ; CALL status2
    ld   web_r38, [x]
    ld   LINK_HI, x
    ld   web_r38 >> 8, [x]
    ld   status2 >> 8, y
    jmp  status2
web_r38:
    ld   [wf_n], ac
    inc                         ; past the name's 00
    ld   ac, [wb_io]
    ld   ac, [wb_d]
    ld   63, ac
    ld   ac, [wb_im]
    ld   LINK_LO, x             ; CALL input
    ld   web_r39, [x]
    ld   LINK_HI, x
    ld   web_r39 >> 8, [x]
    ld   input >> 8, y
    jmp  input
web_r39:
    add  [wb_d], ac
    inc                         ; and the password's 00
    ld   ac, [wf_n]
ak_join:
    ld   C_JOIN, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r40, [x]
    ld   LINK_HI, x
    ld   web_r40 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r40:
    beq  ak_wait
    ld   s_nokept & 0xFF, ac
    ld   LINK_LO, x             ; CALL status2
    ld   web_r41, [x]
    ld   LINK_HI, x
    ld   web_r41 >> 8, [x]
    ld   status2 >> 8, y
    jmp  status2
web_r41:
    ld   90, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   web_r42, [x]
    ld   LINK_HI, x
    ld   web_r42 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
web_r42:
    bra  ask
ak_wait:
    ld   state >> 8, y
    jmp  state

; ------------------------------------------------------------
; view - tell the module the page's size: 76 columns, 10 pixel rows a
; line, pictures in the page
; ------------------------------------------------------------
newpage2:
    ld   LINK_LO, x             ; CALL chrome
    ld   web_r52, [x]
    ld   LINK_HI, x
    ld   web_r52 >> 8, [x]
    ld   chrome >> 8, y
    jmp  chrome
web_r52:
    ld   [wb_flag], ac
    and  2, ac
    beq  np_page
    ld   0xFF, ac               ; the address is a picture: shown alone
    ld   ac, [wb_selh]
    ld   ac, [wb_sell]
    ld   picture >> 8, y
    jmp  picture
np_page:
    ld   LINK_LO, x             ; CALL draw
    ld   web_r53, [x]
    ld   LINK_HI, x
    ld   web_r53 >> 8, [x]
    ld   draw >> 8, y
    jmp  draw
web_r53:
    ld   s_empty & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r54, [x]
    ld   LINK_HI, x
    ld   web_r54 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r54:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; draw - the page's lines from wb_top on the screen, and the table of
; the links in them
; ============================================================
dl2:
    ld   [wb_lh], ac            ; a line of the page?
    sub  [wb_nh], ac
    bcs  dl_in
    bne  dl_out
    ld   [wb_ll], ac
    sub  [wb_nl], ac
    bcs  dl_in
dl_out:
    ld   wipe >> 8, y
    jmp  wipe
dl_in:
    ld   WF_TX >> 8, y
    clr  x
    ld   [wb_ll], ac
    ld   ac, [y,x]
    ld   1, x
    ld   [wb_lh], ac
    ld   ac, [y,x]
    ld   2, x
    ld   0, [y,x]
    ld   3, ac
    ld   ac, [wf_n]
    ld   B_ROW, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r57, [x]
    ld   LINK_HI, x
    ld   web_r57 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r57:
    bne  dl_out
    ld   WF_RX >> 8, y
    clr  x
    ld   [y,x], ac              ; 0: text.  1: a strip of a picture
    bne  dl_strip
    ld   dltext >> 8, y
    jmp  dltext
dl_strip:
    ld   strip >> 8, y
    jmp  strip

; wipe - the rest of the line white; the line is done
view:
    ld   WF_TX >> 8, y
    clr  x
    ld   COLS, [y,x]
    ld   1, x
    ld   PITCH, [y,x]
    ld   2, x
    ld   1, [y,x]
    ld   3, ac
    ld   ac, [wf_n]
    ld   B_VIEW, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r43, [x]
    ld   LINK_HI, x
    ld   web_r43 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r43:
    beq  addr
    xor  0xFF, ac
    beq  vw_old
    ld   s_dead & 0xFF, ac
    ld   fail >> 8, y
    jmp  fail
vw_old:
    ld   s_old & 0xFF, ac
    ld   fail >> 8, y
    jmp  fail

; ------------------------------------------------------------
; addr - an address typed (or words to search for): GO
; ------------------------------------------------------------
addr:
    ld   s_addr & 0xFF, ac
    ld   LINK_LO, x             ; CALL status3
    ld   web_r44, [x]
    ld   LINK_HI, x
    ld   web_r44 >> 8, [x]
    ld   status3 >> 8, y
    jmp  status3
web_r44:
    ld   2, ac
    ld   ac, [wb_io]
    ld   76, ac
    ld   ac, [wb_im]
    ld   LINK_LO, x             ; CALL input
    ld   web_r45, [x]
    ld   LINK_HI, x
    ld   web_r45 >> 8, [x]
    ld   input >> 8, y
    jmp  input
web_r45:
    beq  ad_none
    add  2, ac
    ld   ac, [wf_n]
    ld   WF_TX >> 8, y
    clr  x
    ld   [wb_topl], ac
    ld   ac, [y,x]
    ld   1, x
    ld   [wb_toph], ac
    ld   ac, [y,x]
    ld   B_GO, ac
    ld   load >> 8, y
    jmp  load
ad_none:
    ld   LINK_LO, x             ; CALL chrome
    ld   web_r46, [x]
    ld   LINK_HI, x
    ld   web_r46 >> 8, [x]
    ld   chrome >> 8, y
    jmp  chrome
web_r46:
    ld   s_empty & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r47, [x]
    ld   LINK_HI, x
    ld   web_r47 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r47:
    ld   loop >> 8, y
    jmp  loop

; ------------------------------------------------------------
; load - the request that fetches a page (AC = its command), and the
; page it gives
; ------------------------------------------------------------
draw:
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
    ld   LINK_LO, x             ; CALL p_hide
    ld   web_r55, [x]
    ld   LINK_HI, x
    ld   web_r55 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
web_r55:
    clr  ac
    ld   ac, [wb_runs]
    ld   ac, [wb_ln]
    ld   1, ac
    ld   ac, [wb_tab]
    ld   [wb_topl], ac
    ld   ac, [wb_ll]
    ld   [wb_toph], ac
    ld   ac, [wb_lh]
dr_l:
    ld   LINK_LO, x             ; CALL drawline
    ld   web_r56, [x]
    ld   LINK_HI, x
    ld   web_r56 >> 8, [x]
    ld   drawline >> 8, y
    jmp  drawline
web_r56:
    ld   [wb_ll], ac
    inc
    ld   ac, [wb_ll]
    bne  dr_n
    ld   [wb_lh], ac
    inc
    ld   ac, [wb_lh]
dr_n:
    ld   [wb_ln], ac
    inc
    ld   ac, [wb_ln]
    xor  LINES, ac
    bne  dr_l
    clr  ac
    ld   ac, [wb_tab]
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; drawline - page line wb_lh:wb_ll in screen line wb_ln
;   Screen line n is pixel rows 24 + 10 n and the 9 after: in a column's
;   first page from low byte 56 + 10 n (lines 0-19), in its second from
;   10 (n - 20) (lines 20-42); no line is in both.
; ------------------------------------------------------------

#addr 0x0800
load:
    ld   ac, [wb_cmd]
    ld   s_loading & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r48, [x]
    ld   LINK_HI, x
    ld   web_r48 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r48:
    ld   TMO_LONG, ac
    ld   ac, [wf_tmo]
    ld   [wb_cmd], ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r49, [x]
    ld   LINK_HI, x
    ld   web_r49 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r49:
    ld   TMO_SHORT, ac
    ld   ac, [wf_tmo]
    ld   [wf_st], ac
    beq  newpage
    xor  1, ac
    beq  ld_cant
    xor  1 ^ 2, ac
    beq  ld_net
    ld   s_dead & 0xFF, ac
    ld   fail >> 8, y
    jmp  fail
ld_cant:
    ld   s_cant & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r50, [x]
    ld   LINK_HI, x
    ld   web_r50 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r50:
    ld   loop >> 8, y
    jmp  loop
ld_net:
    ld   s_nonet & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r51, [x]
    ld   LINK_HI, x
    ld   web_r51 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r51:
    ld   loop >> 8, y
    jmp  loop

; the reply: flags, lines, pictures to come, the line to show first
newpage:
    ld   WF_RX >> 8, y
    clr  x
    ld   [y,x], ac
    ld   ac, [wb_flag]
    ld   1, x
    ld   [y,x], ac
    ld   ac, [wb_nl]
    ld   2, x
    ld   [y,x], ac
    ld   ac, [wb_nh]
    ld   3, x
    ld   [y,x], ac
    ld   ac, [wb_pend]
    ld   4, x
    ld   [y,x], ac
    ld   ac, [wb_topl]
    ld   5, x
    ld   [y,x], ac
    ld   ac, [wb_toph]
    clr  ac
    ld   ac, [wb_has]
    ld   newpage2 >> 8, y
    jmp  newpage2

drawline:
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
    ld   [wb_ln], ac
    sub  20, ac
    bcs  dl_top
    ld   ac, [wb_dt]
    shl
    ld   ac, [wb_half]
    shl
    shl
    add  [wb_half], ac
    ld   ac, [wb_dt]
    ld   1, ac
    ld   ac, [wb_half]
    ld   [wb_dt], ac
    bra  dl_rows
dl_top:
    ld   [wb_ln], ac
    shl
    ld   ac, [wb_dt]
    shl
    shl
    add  [wb_dt], ac
    add  56, ac
    ld   ac, [wb_dt]
    clr  ac
    ld   ac, [wb_half]
    ld   [wb_dt], ac
dl_rows:
    ld   ac, [wb_l0 + 0]
    inc
    ld   ac, [wb_l0 + 1]
    inc
    ld   ac, [wb_l0 + 2]
    inc
    ld   ac, [wb_l0 + 3]
    inc
    ld   ac, [wb_l0 + 4]
    inc
    ld   ac, [wb_l0 + 5]
    inc
    ld   ac, [wb_l0 + 6]
    inc
    ld   ac, [wb_l0 + 7]
    inc
    ld   ac, [wb_l0 + 8]
    inc
    ld   ac, [wb_l0 + 9]
    ld   [wb_half], ac
    add  0x64, ac
    ld   ac, [wb_pg]
    clr  ac
    ld   ac, [wb_col]
    ld   dl2 >> 8, y
    jmp  dl2


#addr 0x0900
blank:
    ld   [wb_col], ac
    xor  COLS, ac
    beq  bl_x
    ld   [wb_pg], y
    ld   0xFF, ac
    ld   [wb_l0 + 0], x
    ld   ac, [y,x]
    ld   [wb_l0 + 1], x
    ld   ac, [y,x]
    ld   [wb_l0 + 2], x
    ld   ac, [y,x]
    ld   [wb_l0 + 3], x
    ld   ac, [y,x]
    ld   [wb_l0 + 4], x
    ld   ac, [y,x]
    ld   [wb_l0 + 5], x
    ld   ac, [y,x]
    ld   [wb_l0 + 6], x
    ld   ac, [y,x]
    ld   [wb_l0 + 7], x
    ld   ac, [y,x]
    ld   [wb_l0 + 8], x
    ld   ac, [y,x]
    ld   [wb_l0 + 9], x
    ld   ac, [y,x]
    ld   [wb_pg], ac
    add  2, ac
    ld   ac, [wb_pg]
    ld   [wb_col], ac
    inc
    ld   ac, [wb_col]
    bra  blank
bl_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; dltext - a line of text: characters, and the marks 01 hi lo (a link
; starts), 02 (it ends), 03 and 04 (bold starts, ends)
; ------------------------------------------------------------
dltext:
    ld   1, ac
    ld   ac, [wb_i]
    clr  ac
    ld   ac, [wb_inl]
    ld   ac, [wb_bold]
    ld   0xFF, ac
    ld   ac, [wb_u8]
    ld   ac, [wb_u9]
    ld   0x80, ac
    ld   ac, [wb_inv]
dt_next:
    ld   [wb_i], ac
    xor  [wf_len], ac
    beq  dt_end
    ld   [wb_i], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_ch]
    ld   [wb_i], ac
    inc
    ld   ac, [wb_i]
    ld   [wb_ch], ac
    sub  5, ac
    bcs  dt_mark
    ld   [wb_col], ac
    xor  COLS, ac
    beq  dt_next
    ld   [wb_ch], ac
    and  0x7F, ac
    or   [wb_inv], ac
    ld   ac, [wb_ch]
    ld   [wb_bold], ac
    and  [wb_inv], ac
    bne  dt_bold
    ld   LINK_LO, x             ; CALL putch
    ld   web_r59, [x]
    ld   LINK_HI, x
    ld   web_r59 >> 8, [x]
    ld   putch >> 8, y
    jmp  putch
web_r59:
    bra  dt_cnt
dt_bold:
    ld   LINK_LO, x             ; CALL putchb
    ld   web_r60, [x]
    ld   LINK_HI, x
    ld   web_r60 >> 8, [x]
    ld   putchb >> 8, y
    jmp  putchb
web_r60:
dt_cnt:
    ld   [wb_col], ac
    inc
    ld   ac, [wb_col]
    bra  dt_next
dt_mark:
    ld   mark >> 8, y
    jmp  mark
dt_end:
    ld   LINK_LO, x             ; CALL endrun
    ld   web_r61, [x]
    ld   LINK_HI, x
    ld   web_r61 >> 8, [x]
    ld   endrun >> 8, y
    jmp  endrun
web_r61:
    ld   wipe >> 8, y
    jmp  wipe

endrun:
    ld   [wb_inl], ac
    beq  er_x
    clr  ac
    ld   ac, [wb_inl]
    ld   0xFF, ac
    ld   ac, [wb_u8]
    ld   ac, [wb_u9]
    ld   0x80, ac
    ld   ac, [wb_inv]
    ld   [wb_tab], ac
    beq  er_x
    ld   [wb_runs], ac
    xor  255, ac
    beq  er_x
    ld   [wb_c0], ac
    xor  [wb_col], ac
    beq  er_x
    ld   [wb_runs], x
    ld   LN_LINE >> 8, y
    ld   [wb_ln], ac
    ld   ac, [y,x]
    ld   LN_C0 >> 8, y
    ld   [wb_c0], ac
    ld   ac, [y,x]
    ld   LN_C1 >> 8, y
    ld   [wb_col], ac
    ld   ac, [y,x]
    ld   LN_HI >> 8, y
    ld   [wb_idh], ac
    ld   ac, [y,x]
    ld   LN_LO >> 8, y
    ld   [wb_idl], ac
    ld   ac, [y,x]
    ld   [wb_runs], ac
    inc
    ld   ac, [wb_runs]
er_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; putch - the character wb_ch in the column at page wb_pg, rows 8 and 9
; from wb_u8 and wb_u9; wb_pg moved on (a leaf)

#addr 0x0A00
mark:
    ld   [wb_ch], ac
    xor  1, ac
    beq  mk_link
    xor  1 ^ 2, ac
    beq  mk_end
    xor  2 ^ 3, ac
    beq  mk_b
    xor  3 ^ 4, ac
    beq  mk_nb
    ld   dt_next >> 8, y
    jmp  dt_next
mk_b:
    ld   0x80, ac
    ld   ac, [wb_bold]
    ld   dt_next >> 8, y
    jmp  dt_next
mk_nb:
    clr  ac
    ld   ac, [wb_bold]
    ld   dt_next >> 8, y
    jmp  dt_next
mk_end:
    ld   LINK_LO, x             ; CALL endrun
    ld   web_r62, [x]
    ld   LINK_HI, x
    ld   web_r62 >> 8, [x]
    ld   endrun >> 8, y
    jmp  endrun
web_r62:
    ld   dt_next >> 8, y
    jmp  dt_next
mk_link:
    ld   LINK_LO, x             ; CALL endrun
    ld   web_r63, [x]
    ld   LINK_HI, x
    ld   web_r63 >> 8, [x]
    ld   endrun >> 8, y
    jmp  endrun
web_r63:
    ld   [wb_i], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_idh]
    ld   [wb_i], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [wb_idl]
    ld   [wb_i], ac
    add  2, ac
    ld   ac, [wb_i]
    ld   1, ac
    ld   ac, [wb_inl]
    ld   [wb_col], ac
    ld   ac, [wb_c0]
    clr  ac
    ld   ac, [wb_u9]            ; underlined
    ld   [wb_has], ac
    beq  mk_go
    ld   [wb_idh], ac
    xor  [wb_selh], ac
    bne  mk_go
    ld   [wb_idl], ac
    xor  [wb_sell], ac
    bne  mk_go
    clr  ac                     ; the link chosen: white on black
    ld   ac, [wb_inv]
    ld   ac, [wb_u8]
mk_go:
    ld   dt_next >> 8, y
    jmp  dt_next

; endrun - a link's characters in the line end: into the table (a leaf)
putch:
    ld   (FONT >> 8) + 0, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 0], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 1, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 1], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 2, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 2], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 3, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 3], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 4, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 4], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 5, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 5], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 6, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 6], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 7, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 7], x
    ld   ac, [y,x]
    ld   [wb_l0 + 8], x
    ld   [wb_u8], ac
    ld   ac, [y,x]
    ld   [wb_l0 + 9], x
    ld   [wb_u9], ac
    ld   ac, [y,x]
    ld   [wb_pg], ac
    add  2, ac
    ld   ac, [wb_pg]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; putchb - the same in bold: every black pixel twice (black on white only)

#addr 0x0B00
putchb:
    ld   (FONT >> 8) + 0, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 0], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 1, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 1], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 2, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 2], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 3, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 3], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 4, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 4], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 5, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 5], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 6, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 6], x
    ld   ac, [y,x]
    ld   (FONT >> 8) + 7, y
    ld   [wb_ch], x
    ld   [y,x], ac
    ld   ac, [wb_dt]
    shl
    or   1, ac
    and  [wb_dt], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 7], x
    ld   ac, [y,x]
    ld   [wb_l0 + 8], x
    ld   [wb_u8], ac
    ld   ac, [y,x]
    ld   [wb_l0 + 9], x
    ld   [wb_u9], ac
    ld   ac, [y,x]
    ld   [wb_pg], ac
    add  2, ac
    ld   ac, [wb_pg]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; strip - a line of a picture's pixels: the reply is 1, the first byte
; column, the columns, 1 for the last part, then 10 bytes a column
; ------------------------------------------------------------
loop:
    ld   LINK_LO, x             ; CALL p_show
    ld   web_r67, [x]
    ld   LINK_HI, x
    ld   web_r67 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
web_r67:
    ld   LINK_LO, x             ; the mouse's bytes as they come
    ld   web_r68, [x]
    ld   LINK_HI, x
    ld   web_r68 >> 8, [x]
    ld   ps2_poll >> 8, y
    jmp  ps2_poll
web_r68:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   web_r69, [x]
    ld   LINK_HI, x
    ld   web_r69 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
web_r69:
    ld   [FRAME_LO], ac
    xor  [wb_frm], ac
    beq  lp_idle
    ld   [FRAME_LO], ac
    ld   ac, [wb_frm]
    ld   keys >> 8, y
    jmp  keys
lp_idle:
    ld   [wb_pend], ac
    beq  loop
    ld   imgs >> 8, y
    jmp  imgs


#addr 0x0C00
strip:
    ld   LINK_LO, x             ; CALL blank
    ld   web_r64, [x]
    ld   LINK_HI, x
    ld   web_r64 >> 8, [x]
    ld   blank >> 8, y
    jmp  blank
web_r64:
    clr  ac
    ld   ac, [wb_part]
sp_part:
    ld   WF_RX >> 8, y
    ld   1, x
    ld   [y,x], ac
    shl
    add  [wb_half], ac
    add  0x64, ac
    ld   ac, [wb_pg]
    ld   2, x
    ld   [y,x], ac
    ld   ac, [wb_sc]
    ld   4, ac
    ld   ac, [wb_i]
sp_col:
    ld   [wb_sc], ac
    beq  sp_done
    ld   LINK_LO, x             ; CALL stripcol
    ld   web_r65, [x]
    ld   LINK_HI, x
    ld   web_r65 >> 8, [x]
    ld   stripcol >> 8, y
    jmp  stripcol
web_r65:
    ld   [wb_sc], ac
    dec
    ld   ac, [wb_sc]
    bra  sp_col
sp_done:
    ld   WF_RX >> 8, y
    ld   3, x
    ld   [y,x], ac
    bne  sp_x
    ld   [wb_part], ac
    inc
    ld   ac, [wb_part]
    ld   WF_TX >> 8, y
    ld   2, x
    ld   ac, [y,x]
    clr  x
    ld   [wb_ll], ac
    ld   ac, [y,x]
    ld   1, x
    ld   [wb_lh], ac
    ld   ac, [y,x]
    ld   3, ac
    ld   ac, [wf_n]
    ld   B_ROW, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r66, [x]
    ld   LINK_HI, x
    ld   web_r66 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r66:
    beq  sp_part
sp_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; stripcol - 10 bytes of the reply from wb_i to the column at page wb_pg (a leaf)
stripcol:
    ld   [wb_i], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 0], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  1, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 1], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  2, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 2], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  3, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 3], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  4, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 4], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  5, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 5], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  6, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 6], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  7, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 7], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  8, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 8], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  9, x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   [wb_pg], y
    ld   [wb_l0 + 9], x
    ld   ac, [y,x]
    ld   [wb_i], ac
    add  10, ac
    ld   ac, [wb_i]
    ld   [wb_pg], ac
    add  2, ac
    ld   ac, [wb_pg]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; loop - the pointer, the keys once a frame, a picture of the page when
; there is nothing else to do
; ============================================================

#addr 0x0D00
keys:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   web_r70, [x]
    ld   LINK_HI, x
    ld   web_r70 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
web_r70:
    ld   LINK_LO, x             ; CALL esc
    ld   web_r71, [x]
    ld   LINK_HI, x
    ld   web_r71 >> 8, [x]
    ld   esc >> 8, y
    jmp  esc
web_r71:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   web_r72, [x]
    ld   LINK_HI, x
    ld   web_r72 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
web_r72:
    beq  ky_none
    ld   ac, [wb_key]
    xor  0x12, ac               ; Down
    beq  ky_dn
    xor  0x12 ^ 0x11, ac        ; Up
    beq  ky_up
    xor  0x11 ^ 0x20, ac        ; Space
    beq  ky_pd
    xor  0x20 ^ 0x09, ac        ; Tab
    beq  ky_nx
    xor  0x09 ^ 0x14, ac        ; Right
    beq  ky_nx
    xor  0x14 ^ 0x13, ac        ; Left
    beq  ky_pv
    xor  0x13 ^ 0x0A, ac        ; Enter
    beq  ky_go
    xor  0x0A ^ 0x08, ac        ; Backspace
    beq  ky_bk
    ld   keys2 >> 8, y
    jmp  keys2
ky_none:
    ld   mouse >> 8, y
    jmp  mouse
ky_dn:
    ld   STEP, ac
    ld   down >> 8, y
    jmp  down
ky_up:
    ld   STEP, ac
    ld   up >> 8, y
    jmp  up
ky_pd:
    ld   PAGE, ac
    ld   down >> 8, y
    jmp  down
ky_nx:
    ld   nextl >> 8, y
    jmp  nextl
ky_pv:
    ld   prevl >> 8, y
    jmp  prevl
ky_go:
    ld   follow >> 8, y
    jmp  follow
ky_bk:
    ld   back >> 8, y
    jmp  back

keys2:
    ld   [wb_key], ac
    or   0x20, ac               ; a letter, small or capital
    xor  0x67, ac               ; G
    beq  k2_g
    xor  0x67 ^ 0x72, ac        ; R
    beq  k2_r
    xor  0x72 ^ 0x62, ac        ; B
    beq  k2_b
    ld   [wb_key], ac
    xor  0x0C, ac               ; Ctrl+L
    beq  k2_g
    xor  0x0C ^ 0x15, ac        ; Home
    beq  k2_home
    ld   mouse >> 8, y
    jmp  mouse
k2_g:
    ld   addr >> 8, y
    jmp  addr
k2_b:
    ld   PAGE, ac
    ld   up >> 8, y
    jmp  up
k2_home:
    ld   [wb_topl], ac
    or   [wb_toph], ac
    beq  k2_no
    clr  ac
    ld   ac, [wb_topl]
    ld   ac, [wb_toph]
    ld   redraw >> 8, y
    jmp  redraw
k2_no:
    ld   loop >> 8, y
    jmp  loop
k2_r:
    ld   WF_TX >> 8, y
    clr  x
    ld   [wb_topl], ac
    ld   ac, [y,x]
    ld   1, x
    ld   [wb_toph], ac
    ld   ac, [y,x]
    ld   2, ac
    ld   ac, [wf_n]
    ld   B_RELOAD, ac
    ld   load >> 8, y
    jmp  load

; back - the page before
redraw:
    clr  ac
    ld   ac, [wb_has]
    ld   LINK_LO, x             ; CALL draw
    ld   web_r73, [x]
    ld   LINK_HI, x
    ld   web_r73 >> 8, [x]
    ld   draw >> 8, y
    jmp  draw
web_r73:
    ld   s_empty & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r74, [x]
    ld   LINK_HI, x
    ld   web_r74 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r74:
    ld   [wb_auto], ac
    beq  rd_x
    clr  ac
    ld   ac, [wb_auto]
    ld   ac, [wb_k]
    ld   [wb_runs], ac
    beq  rd_x
    ld   select >> 8, y
    jmp  select
rd_x:
    ld   loop >> 8, y
    jmp  loop

; ------------------------------------------------------------
; down - AC lines on, but not past the page's last screen
; ------------------------------------------------------------

#addr 0x0E00
down:
    ld   ac, [R2]
    clr  ac
    ld   ac, [R3]
    ld   [wb_topl], ac
    ld   ac, [R0]
    ld   [wb_toph], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL add16
    ld   web_r75, [x]
    ld   LINK_HI, x
    ld   web_r75 >> 8, [x]
    ld   add16 >> 8, y
    jmp  add16
web_r75:
    ld   [R0], ac
    ld   ac, [wb_a]             ; the new top
    ld   [R1], ac
    ld   ac, [wb_b]
    ld   [wb_nl], ac
    ld   ac, [R0]
    ld   [wb_nh], ac
    ld   ac, [R1]
    ld   LINES, ac
    ld   ac, [R2]
    clr  ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; the last screen's top: lines - 43
    ld   web_r76, [x]
    ld   LINK_HI, x
    ld   web_r76 >> 8, [x]
    ld   sub16 >> 8, y
    jmp  sub16
web_r76:
    blt  dn_zero
    ld   [R0], ac
    ld   ac, [wb_e]
    ld   [R1], ac
    ld   ac, [wb_f]
    ld   [wb_a], ac
    ld   ac, [R2]
    ld   [wb_b], ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL sub16
    ld   web_r77, [x]
    ld   LINK_HI, x
    ld   web_r77 >> 8, [x]
    ld   sub16 >> 8, y
    jmp  sub16
web_r77:
    blt  dn_most
    ld   down2 >> 8, y
    jmp  down2
dn_zero:
    clr  ac
    ld   ac, [wb_e]
    ld   ac, [wb_f]
dn_most:
    ld   [wb_e], ac
    ld   ac, [wb_a]
    ld   [wb_f], ac
    ld   ac, [wb_b]
    ld   down2 >> 8, y
    jmp  down2

down2:
    ld   [wb_a], ac
    xor  [wb_topl], ac
    bne  d2_go
    ld   [wb_b], ac
    xor  [wb_toph], ac
    bne  d2_go
    clr  ac                     ; it is there already
    ld   ac, [wb_auto]
    ld   loop >> 8, y
    jmp  loop
d2_go:
    ld   [wb_a], ac
    ld   ac, [wb_topl]
    ld   [wb_b], ac
    ld   ac, [wb_toph]
    ld   redraw >> 8, y
    jmp  redraw

; up - AC lines back
up:
    ld   ac, [R2]
    ld   [wb_topl], ac
    or   [wb_toph], ac
    beq  up_no
    clr  ac
    ld   ac, [R3]
    ld   [wb_topl], ac
    ld   ac, [R0]
    ld   [wb_toph], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL sub16
    ld   web_r78, [x]
    ld   LINK_HI, x
    ld   web_r78 >> 8, [x]
    ld   sub16 >> 8, y
    jmp  sub16
web_r78:
    blt  up_zero
    ld   [R0], ac
    ld   ac, [wb_topl]
    ld   [R1], ac
    ld   ac, [wb_toph]
    ld   redraw >> 8, y
    jmp  redraw
up_zero:
    clr  ac
    ld   ac, [wb_topl]
    ld   ac, [wb_toph]
    ld   redraw >> 8, y
    jmp  redraw
up_no:
    ld   loop >> 8, y
    jmp  loop

; ------------------------------------------------------------
; nextl, prevl - the link after the one chosen, the one before; past
; the screen's last or first: the next screen, the one before
; ------------------------------------------------------------
unsel:
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
    ld   [wb_has], ac
    beq  us_x
    clr  ac
    ld   ac, [wb_has]
    ld   LINK_LO, x             ; CALL relines
    ld   web_r83, [x]
    ld   LINK_HI, x
    ld   web_r83 >> 8, [x]
    ld   relines >> 8, y
    jmp  relines
web_r83:
us_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; relines - the lines with link wb_selh:wb_sell in them drawn again

#addr 0x0F00
nextl:
    ld   [wb_has], ac
    bne  nl_from
    ld   [wb_runs], ac
    beq  nl_page
    clr  ac
    bra  nl_sel
nl_from:
    ld   [wb_sel], ac
nl_skip:
    inc
    ld   ac, [wb_k]
    xor  [wb_runs], ac
    beq  nl_page
    ld   [wb_k], x
    ld   LN_HI >> 8, y
    ld   [y,x], ac
    xor  [wb_selh], ac
    bne  nl_new
    ld   LN_LO >> 8, y
    ld   [y,x], ac
    xor  [wb_sell], ac
    bne  nl_new
    ld   [wb_k], ac
    bra  nl_skip
nl_new:
    ld   [wb_k], ac
nl_sel:
    ld   ac, [wb_k]
    ld   select >> 8, y
    jmp  select
nl_page:
    ld   1, ac
    ld   ac, [wb_auto]
    ld   PAGE, ac
    ld   down >> 8, y
    jmp  down

prevl:
    ld   [wb_has], ac
    beq  pl_page
    ld   [wb_sel], ac
    beq  pl_page
    dec
    ld   ac, [wb_k]
pl_first:
    ld   [wb_k], ac
    beq  pl_sel
    ld   [wb_k], x
    ld   LN_HI >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_a]
    ld   LN_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_b]
    ld   [wb_k], ac
    sub  1, x
    ld   [y,x], ac
    xor  [wb_b], ac
    bne  pl_sel
    ld   LN_HI >> 8, y
    ld   [y,x], ac
    xor  [wb_a], ac
    bne  pl_sel
    ld   [wb_k], ac
    dec
    ld   ac, [wb_k]
    bra  pl_first
pl_sel:
    ld   select >> 8, y
    jmp  select
pl_page:
    ld   PAGE, ac
    ld   up >> 8, y
    jmp  up

; ------------------------------------------------------------
; select - the link at wb_k of the table is the one chosen: its lines
; drawn again, its address in the rail
; ------------------------------------------------------------
select:
    ld   LINK_LO, x             ; CALL unsel
    ld   web_r79, [x]
    ld   LINK_HI, x
    ld   web_r79 >> 8, [x]
    ld   unsel >> 8, y
    jmp  unsel
web_r79:
    ld   [wb_k], ac
    ld   ac, [wb_sel]
    ld   [wb_k], x
    ld   LN_HI >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_selh]
    ld   LN_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_sell]
    ld   1, ac
    ld   ac, [wb_has]
    ld   LINK_LO, x             ; CALL relines
    ld   web_r80, [x]
    ld   LINK_HI, x
    ld   web_r80 >> 8, [x]
    ld   relines >> 8, y
    jmp  relines
web_r80:
    ld   WF_TX >> 8, y
    clr  x
    ld   [wb_sell], ac
    ld   ac, [y,x]
    ld   1, x
    ld   [wb_selh], ac
    ld   ac, [y,x]
    ld   2, ac
    ld   ac, [wf_n]
    ld   B_LNINFO, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r81, [x]
    ld   LINK_HI, x
    ld   web_r81 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r81:
    bne  sl_x
    ld   LINK_LO, x             ; CALL statrx
    ld   web_r82, [x]
    ld   LINK_HI, x
    ld   web_r82 >> 8, [x]
    ld   statrx >> 8, y
    jmp  statrx
web_r82:
sl_x:
    ld   loop >> 8, y
    jmp  loop

; unsel - no link chosen

#addr 0x1000
relines:
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
    ld   LINK_LO, x             ; CALL p_hide
    ld   web_r84, [x]
    ld   LINK_HI, x
    ld   web_r84 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
web_r84:
    clr  ac
    ld   ac, [wb_r]
    ld   0xFF, ac
    ld   ac, [wb_last]
rl_l:
    ld   [wb_r], ac
    xor  [wb_runs], ac
    beq  rl_x
    ld   [wb_r], x
    ld   LN_HI >> 8, y
    ld   [y,x], ac
    xor  [wb_selh], ac
    bne  rl_n
    ld   LN_LO >> 8, y
    ld   [y,x], ac
    xor  [wb_sell], ac
    bne  rl_n
    ld   LN_LINE >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_ln]
    xor  [wb_last], ac
    beq  rl_n
    ld   [wb_ln], ac
    ld   ac, [wb_last]
    add  [wb_topl], ac
    ld   ac, [wb_ll]
    ld   [wb_toph], ac
    bcc  rl_nc
    inc
rl_nc:
    ld   ac, [wb_lh]
    ld   LINK_LO, x             ; CALL drawline
    ld   web_r85, [x]
    ld   LINK_HI, x
    ld   web_r85 >> 8, [x]
    ld   drawline >> 8, y
    jmp  drawline
web_r85:
rl_n:
    ld   [wb_r], ac
    inc
    ld   ac, [wb_r]
    bra  rl_l
rl_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; follow - open the link chosen: a page (LINK), the next part of this
; one (FFFE), or a picture (8000 and up)
; ------------------------------------------------------------
follow:
    ld   [wb_has], ac
    bne  fw_go
    ld   loop >> 8, y
    jmp  loop
fw_go:
    ld   [wb_selh], ac
    blt  fo_hi
fo_link:
    ld   WF_TX >> 8, y
    clr  x
    ld   [wb_sell], ac
    ld   ac, [y,x]
    ld   1, x
    ld   [wb_selh], ac
    ld   ac, [y,x]
    ld   2, x
    ld   [wb_topl], ac
    ld   ac, [y,x]
    ld   3, x
    ld   [wb_toph], ac
    ld   ac, [y,x]
    ld   4, ac
    ld   ac, [wf_n]
    ld   B_LINK, ac
    ld   load >> 8, y
    jmp  load
fo_hi:
    xor  0xFF, ac
    bne  fo_pic
    ld   [wb_sell], ac
    xor  0xFE, ac
    beq  fo_link
fo_pic:
    ld   picture >> 8, y
    jmp  picture

; ------------------------------------------------------------
; imgs - the next picture of the page (IMGLOAD): the reply is pictures
; still to come, the line it went in at, the lines it added, the page's
; lines now
; ------------------------------------------------------------
imgs:
    ld   s_pics & 0xFF, ac
    ld   LINK_LO, x             ; CALL status3
    ld   web_r86, [x]
    ld   LINK_HI, x
    ld   web_r86 >> 8, [x]
    ld   status3 >> 8, y
    jmp  status3
web_r86:
    clr  ac
    ld   ac, [wf_n]
    ld   B_IMGLOAD, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r87, [x]
    ld   LINK_HI, x
    ld   web_r87 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r87:
    beq  im_ok
    clr  ac
    ld   ac, [wb_pend]
    ld   loop >> 8, y
    jmp  loop
im_ok:
    ld   WF_RX >> 8, y
    clr  x
    ld   [y,x], ac
    ld   ac, [wb_pend]
    ld   1, x
    ld   [y,x], ac
    ld   ac, [wb_a]
    ld   2, x
    ld   [y,x], ac
    ld   ac, [wb_b]
    ld   5, x
    ld   [y,x], ac
    ld   ac, [wb_nl]
    ld   6, x
    ld   [y,x], ac
    ld   ac, [wb_nh]
    ld   3, x
    ld   [y,x], ac
    ld   ac, [wb_e]
    ld   imgs2 >> 8, y
    jmp  imgs2


#addr 0x1100
imgs2:
    ld   [wb_e], ac
    beq  im_done
    ld   [wb_b], ac             ; above the screen: the screen stays on its lines
    sub  [wb_toph], ac
    bcs  im_above
    bne  im_draw
    ld   [wb_a], ac
    sub  [wb_topl], ac
    bcs  im_above
im_draw:
    clr  ac
    ld   ac, [wb_has]
    ld   LINK_LO, x             ; CALL draw
    ld   web_r88, [x]
    ld   LINK_HI, x
    ld   web_r88 >> 8, [x]
    ld   draw >> 8, y
    jmp  draw
web_r88:
    bra  im_done
im_above:
    ld   [wb_topl], ac
    add  [wb_e], ac
    ld   ac, [wb_topl]
    bcc  im_done
    ld   [wb_toph], ac
    inc
    ld   ac, [wb_toph]
im_done:
    ld   [wb_pend], ac
    bne  im_more
    ld   s_empty & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r89, [x]
    ld   LINK_HI, x
    ld   web_r89 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r89:
im_more:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; picture - picture wb_selh:wb_sell alone: the whole screen in 256
; colors, 240 rows of 80 or 160; a key brings the page back
; ============================================================
picture:
    ld   s_picl & 0xFF, ac
    ld   LINK_LO, x             ; CALL status3
    ld   web_r90, [x]
    ld   LINK_HI, x
    ld   web_r90 >> 8, [x]
    ld   status3 >> 8, y
    jmp  status3
web_r90:
    ld   WF_TX >> 8, y
    clr  x
    ld   [wb_sell], ac
    ld   ac, [y,x]
    ld   1, x
    ld   [wb_selh], ac
    ld   ac, [y,x]
    ld   2, x
    ld   [wb_mode], ac
    and  0x80, ac
    ld   ac, [y,x]
    ld   3, ac
    ld   ac, [wf_n]
    ld   TMO_LONG, ac
    ld   ac, [wf_tmo]
    ld   B_PICTURE, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r91, [x]
    ld   LINK_HI, x
    ld   web_r91 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r91:
    ld   TMO_SHORT, ac
    ld   ac, [wf_tmo]
    ld   [wf_st], ac
    beq  pc_ok
    xor  1, ac
    bne  pc_dead
    ld   LINK_LO, x             ; why not
    ld   web_r92, [x]
    ld   LINK_HI, x
    ld   web_r92 >> 8, [x]
    ld   statrx >> 8, y
    jmp  statrx
web_r92:
    ld   loop >> 8, y
    jmp  loop
pc_dead:
    ld   s_dead & 0xFF, ac
    ld   fail >> 8, y
    jmp  fail
pc_ok:
    ld   WF_RX >> 8, y
    clr  x
    ld   [y,x], ac
    ld   ac, [wb_w]
    ld   LINK_LO, x             ; CALL p_hide
    ld   web_r93, [x]
    ld   LINK_HI, x
    ld   web_r93 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
web_r93:
    ld   LINK_LO, x             ; CALL con_clear
    ld   web_r94, [x]
    ld   LINK_HI, x
    ld   web_r94 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
web_r94:
    ld   LINK_LO, x             ; CALL set_modes
    ld   web_r95, [x]
    ld   LINK_HI, x
    ld   web_r95 >> 8, [x]
    ld   set_modes >> 8, y
    jmp  set_modes
web_r95:
    clr  ac
    ld   ac, [wb_c]
    ld   pcol >> 8, y
    jmp  pcol

; set_modes - every row's mode byte (x5A20-x5BFF) = wb_mode (a leaf)

#addr 0x1200
pcol:
    ld   WF_TX >> 8, y
    clr  x
    ld   [wb_c], ac
    ld   ac, [y,x]
    ld   1, ac
    ld   ac, [wf_n]
    ld   B_PICDATA, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r96, [x]
    ld   LINK_HI, x
    ld   web_r96 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r96:
    bne  pc_end
    ld   [wb_mode], ac
    blt  pc_160
    ld   [wb_c], ac
    shl
    add  0x61, ac
    bra  pc_pg
pc_160:
    ld   [wb_c], ac
    add  0x60, ac
pc_pg:
    ld   ac, [wb_pg]
    clr  ac
    ld   ac, [wb_i]
pc_a:
    ld   [wb_i], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_t]
    ld   [wb_i], ac
    shl
    add  32, x
    ld   [wb_pg], y
    ld   [wb_t], ac
    ld   ac, [y,x]
    ld   [wb_i], ac
    inc
    ld   ac, [wb_i]
    xor  112, ac
    bne  pc_a
pc_b:
    ld   [wb_i], x
    ld   WF_RX >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_t]
    ld   [wb_i], ac
    shl
    add  33, x
    ld   [wb_pg], y
    ld   [wb_t], ac
    ld   ac, [y,x]
    ld   [wb_i], ac
    inc
    ld   ac, [wb_i]
    xor  240, ac
    bne  pc_b
    ld   [wb_c], ac
    inc
    ld   ac, [wb_c]
    xor  [wb_w], ac
    bne  pcol
pc_end:
    ld   pwait >> 8, y
    jmp  pwait

; pwait - a key: H shows it the other way, any other brings the page back
; (the page before, when the address was the picture's own)
mouse:
    ld   [wb_mok], ac
    bne  mo_x
    ld   [MOUSE_ST], ac         ; the loop has taken its bytes (ps2_poll):
    or   0x40, ac               ; no waiting for the rest of a packet
    ld   ac, [MOUSE_ST]
    ld   LINK_LO, x             ; CALL mouse_poll
    ld   web_r107, [x]
    ld   LINK_HI, x
    ld   web_r107 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
web_r107:
    beq  mo_x
    ld   LINK_LO, x             ; CALL p_hide
    ld   web_r108, [x]
    ld   LINK_HI, x
    ld   web_r108 >> 8, [x]
    ld   p_hide >> 8, y
    jmp  p_hide
web_r108:
    ld   [wb_pxl], ac
    ld   ac, [R0]
    ld   [wb_pxh], ac
    ld   ac, [R1]
    ld   [wb_pyl], ac
    ld   ac, [R2]
    ld   [wb_pyh], ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL mouse_move
    ld   web_r109, [x]
    ld   LINK_HI, x
    ld   web_r109 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
web_r109:
    ld   [R0], ac
    ld   ac, [wb_pxl]
    ld   [R1], ac
    ld   ac, [wb_pxh]
    ld   [R2], ac
    ld   ac, [wb_pyl]
    ld   [R3], ac
    ld   ac, [wb_pyh]
    ld   LINK_LO, x             ; CALL p_show
    ld   web_r110, [x]
    ld   LINK_HI, x
    ld   web_r110 >> 8, [x]
    ld   p_show >> 8, y
    jmp  p_show
web_r110:
    ld   click >> 8, y
    jmp  click
mo_x:
    ld   loop >> 8, y
    jmp  loop

; click - wb_t = the pointer's column; the buttons

#addr 0x1300
pwait:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames
    ld   web_r97, [x]
    ld   LINK_HI, x
    ld   web_r97 >> 8, [x]
    ld   wait_frames >> 8, y
    jmp  wait_frames
web_r97:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   web_r98, [x]
    ld   LINK_HI, x
    ld   web_r98 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
web_r98:
    ld   LINK_LO, x             ; CALL esc
    ld   web_r99, [x]
    ld   LINK_HI, x
    ld   web_r99 >> 8, [x]
    ld   esc >> 8, y
    jmp  esc
web_r99:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   web_r100, [x]
    ld   LINK_HI, x
    ld   web_r100 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
web_r100:
    beq  pwait
    or   0x20, ac
    xor  0x68, ac
    bne  pw_back
    ld   [wb_mode], ac
    xor  0x80, ac
    ld   ac, [wb_mode]
    ld   LINK_LO, x             ; CALL screen
    ld   web_r101, [x]
    ld   LINK_HI, x
    ld   web_r101 >> 8, [x]
    ld   screen >> 8, y
    jmp  screen
web_r101:
    ld   picture >> 8, y
    jmp  picture
pw_back:
    clr  ac
    ld   ac, [wf_n]
    ld   B_PICEND, ac
    ld   LINK_LO, x             ; CALL wf_xfer
    ld   web_r102, [x]
    ld   LINK_HI, x
    ld   web_r102 >> 8, [x]
    ld   wf_xfer >> 8, y
    jmp  wf_xfer
web_r102:
    ld   LINK_LO, x             ; CALL screen
    ld   web_r103, [x]
    ld   LINK_HI, x
    ld   web_r103 >> 8, [x]
    ld   screen >> 8, y
    jmp  screen
web_r103:
    ld   LINK_LO, x             ; CALL chrome
    ld   web_r104, [x]
    ld   LINK_HI, x
    ld   web_r104 >> 8, [x]
    ld   chrome >> 8, y
    jmp  chrome
web_r104:
    ld   LINK_LO, x             ; CALL draw
    ld   web_r105, [x]
    ld   LINK_HI, x
    ld   web_r105 >> 8, [x]
    ld   draw >> 8, y
    jmp  draw
web_r105:
    ld   s_empty & 0xFF, ac
    ld   LINK_LO, x             ; CALL status
    ld   web_r106, [x]
    ld   LINK_HI, x
    ld   web_r106 >> 8, [x]
    ld   status >> 8, y
    jmp  status
web_r106:
    ld   [wb_flag], ac          ; the address was the picture: the page
    and  2, ac                  ; before it
    beq  pw_loop
    ld   back >> 8, y
    jmp  back
pw_loop:
    ld   loop >> 8, y
    jmp  loop

; ============================================================
; the mouse
; ============================================================
click:
    ld   [wb_pxl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wb_t]
    ld   [wb_pxh], ac
    shl
    shl
    shl
    shl
    shl
    or   [wb_t], ac
    ld   ac, [wb_t]
    ld   [wb_pyl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [wb_d]
    ld   [wb_pyh], ac
    shl
    shl
    shl
    shl
    shl
    or   [wb_d], ac
    ld   ac, [wb_d]
    ld   [MOUSE_B], ac
    and  3, ac
    bne  ck_down
    ld   ac, [wb_mb]            ; let go
    ld   loop >> 8, y
    jmp  loop
ck_down:
    ld   ac, [wb_a]
    ld   [wb_mb], ac
    bne  ck_held
    ld   1, ac
    ld   ac, [wb_mb]
    ld   [wb_a], ac
    and  2, ac
    beq  ck_left
    ld   back >> 8, y           ; the right button
    jmp  back
ck_left:
    ld   press >> 8, y
    jmp  press
ck_held:
    ld   loop >> 8, y
    jmp  loop

; press - the left button went down: on the pin, or a line of the page
; (rows 24 + 10 n: wb_a = n)

#addr 0x1400
press:
    ld   [wb_pyh], ac
    bne  pr_low
    ld   [wb_pyl], ac
    sub  24, ac
    bcs  pr_top
    bra  pr_div
pr_low:
    ld   [wb_pyl], ac
    add  32, ac                 ; row 256 + y is line 20 + (y + 32) / 10
pr_div:
    ld   ac, [R0]
    ld   PITCH, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL div8
    ld   web_r111, [x]
    ld   LINK_HI, x
    ld   web_r111 >> 8, [x]
    ld   div8 >> 8, y
    jmp  div8
web_r111:
    ld   ac, [wb_a]
    ld   [wb_pyh], ac
    beq  pr_ln
    ld   [wb_a], ac
    add  20, ac
    ld   ac, [wb_a]
pr_ln:
    ld   hit >> 8, y
    jmp  hit
pr_top:
    ld   [wb_pyl], ac
    sub  8, ac
    bcc  pr_no
    ld   [wb_t], ac
    sub  2, ac
    bcc  pr_no
    ld   leave >> 8, y
    jmp  leave
pr_no:
    ld   loop >> 8, y
    jmp  loop

; hit - the link at column wb_t of screen line wb_a, if there is one
hit:
    ld   [wb_t], ac
    sub  2, ac
    bcs  ht_no
    ld   ac, [wb_b]
    clr  ac
    ld   ac, [wb_r]
ht_l:
    ld   [wb_r], ac
    xor  [wb_runs], ac
    beq  ht_no
    ld   [wb_r], x
    ld   LN_LINE >> 8, y
    ld   [y,x], ac
    xor  [wb_a], ac
    bne  ht_n
    ld   LN_C0 >> 8, y
    ld   [wb_b], ac
    sub  [y,x], ac
    bcs  ht_n
    ld   LN_C1 >> 8, y
    ld   [wb_b], ac
    sub  [y,x], ac
    bcc  ht_n
    ld   LN_HI >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_selh]
    ld   LN_LO >> 8, y
    ld   [y,x], ac
    ld   ac, [wb_sell]
    ld   [wb_r], ac
    ld   ac, [wb_sel]
    ld   1, ac
    ld   ac, [wb_has]
    ld   follow >> 8, y
    jmp  follow
ht_n:
    ld   [wb_r], ac
    inc
    ld   ac, [wb_r]
    bra  ht_l
ht_no:
    ld   loop >> 8, y
    jmp  loop

; leave - the pin: back, as Esc goes
p_hide:
    ld   [wb_son], ac
    beq  ph_x
    clr  ac
    ld   ac, [wb_son]
    ld   ac, [T0]
ph_l:
    ld   [wb_syl], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [wb_syh], ac
    bcc  pra1
    inc
pra1:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb1
    inc
prb1:
    add  [wb_sc2], ac
    ld   ac, [T2]
    ld   [T0], ac
    shl
    ld   ac, x
    ld   PSAVE >> 8, y
    ld   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [wb_sk], ac
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
    xor  [wb_sn], ac
    bne  ph_l
ph_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; p_show - the pointer drawn at wb_px, wb_py (T0-T3; a leaf)

#addr 0x1500
p_show:
    ld   [wb_son], ac
    bne  ps_x
    ld   [wb_mok], ac
    bne  ps_x                   ; no mouse: no pointer
    ld   1, ac
    ld   ac, [wb_son]
    ld   [wb_pxl], ac
    and  7, ac
    shl
    shl
    shl
    shl
    ld   ac, [wb_sti]
    ld   [wb_pxl], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T3]
    ld   [wb_pxh], ac
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
    ld   ac, [wb_sk]
    ld   [T3], ac
    shl
    add  0x60, ac
    ld   ac, [wb_sc2]
    ld   [wb_pyl], ac
    ld   ac, [wb_syl]
    ld   [wb_pyh], ac
    ld   ac, [wb_syh]
    ld   12, ac
    ld   ac, [wb_sn]
    ld   [wb_pyh], ac
    beq  ps_go
    ld   0xE0, ac               ; rows left to 480
    sub  [wb_pyl], ac
    ld   ac, [T3]
    sub  12, ac
    bcc  ps_go
    ld   [T3], ac
    ld   ac, [wb_sn]
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
    ld   [wb_syl], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [wb_syh], ac
    bcc  pra2
    inc
pra2:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb2
    inc
prb2:
    add  [wb_sc2], ac
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
    ld   [wb_sti], ac
    or   [T0], ac
    ld   ac, x
    ld   PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PTR >> 8) + 1, y
    or   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [wb_sk], ac
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
    ld   [wb_sti], ac
    or   [T0], ac
    or   0x80, x
    ld   PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PTR >> 8) + 1, y
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
    xor  [wb_sn], ac
    bne  ps_l
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the WiFi card's driver (wifi.masm), with a wait as long as wf_tmo says
; ============================================================

#addr 0x1600
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
;   out:     AC = 0: ready.  AC = 1: not within wf_tmo x 15 seconds
;   changes: X, Y, T0-T3
; ------------------------------------------------------------
wf_ready:
    ld   [wf_y], y
    ld   [wf_x], x
    clr  ac
    ld   ac, [T0]
    ld   ac, [T1]
    ld   ac, [T2]
    ld   ac, [T3]
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
    bne  wr_loop
    ld   [T3], ac
    inc
    ld   ac, [T3]
    xor  [wf_tmo], ac
    bne  wr_loop
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
wr_ok:
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

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
wx_in:
    ld   [wf_i], ac
    xor  [wf_len], ac
    beq  wx_end
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   web_r120, [x]
    ld   LINK_HI, x
    ld   web_r120 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
web_r120:
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

#addr 0x1700
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
    ld   web_r112, [x]
    ld   LINK_HI, x
    ld   web_r112 >> 8, [x]
    ld   wf_ready >> 8, y
    jmp  wf_ready
web_r112:
    bne  wx_dead
    ld   [wf_y], y
    ld   [wf_x], x
    ld   WF_SEL, [y,x]          ; /CS low
    ld   [wf_cmd], ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   web_r113, [x]
    ld   LINK_HI, x
    ld   web_r113 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
web_r113:
    ld   ac, [wf_mark]
    ld   [wf_n], ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   web_r114, [x]
    ld   LINK_HI, x
    ld   web_r114 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
web_r114:
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
    ld   web_r115, [x]
    ld   LINK_HI, x
    ld   web_r115 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
web_r115:
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
    ld   web_r116, [x]
    ld   LINK_HI, x
    ld   web_r116 >> 8, [x]
    ld   wf_ready >> 8, y
    jmp  wf_ready
web_r116:
    bne  wx_gone
    ld   [wf_y], y
    ld   [wf_x], x
    ld   WF_SEL, [y,x]
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   web_r117, [x]
    ld   LINK_HI, x
    ld   web_r117 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
web_r117:
    xor  0x41, ac
    bne  wx_bad
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   web_r118, [x]
    ld   LINK_HI, x
    ld   web_r118 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
web_r118:
    ld   ac, [wf_st]
    clr  ac
    ld   LINK_LO, x             ; CALL wf_byte
    ld   web_r119, [x]
    ld   LINK_HI, x
    ld   web_r119 >> 8, [x]
    ld   wf_byte >> 8, y
    jmp  wf_byte
web_r119:
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


#addr 0x1800
s_msg:
s_empty:
    #d 0x00
s_nocard:
    #d "There is no WiFi card in a slot.  Esc: close", 0x00
s_dead:
    #d "The WiFi module does not answer.  Esc: close", 0x00
s_old:
    #d "The module's firmware has no browser: it needs 1.1.  Esc: close", 0x00
s_join:
    #d "Joining the network...", 0x00
s_loading:
    #d "Loading...", 0x00
s_cant:
    #d "There is no page before this one.", 0x00
s_nonet:
    #d "The network is not joined.", 0x00

#addr 0x1900
s_msg2:
s_net:
    #d "The network's name, then Enter (Enter alone: the network used last)", 0x00
s_pass:
    #d "Its password, then Enter", 0x00
s_failed:
    #d "Could not join that network.", 0x00
s_nokept:
    #d "The module has no network kept.", 0x00
s_keys:
    #d "Arrows, Space, B: move  Tab: link  Enter: open  Bksp: back  G: go to  R: again", 0x00

#addr 0x1A00
s_msg3:
s_addr:
    #d "Type an address, or words to search for, then Enter (Enter alone: stay here)", 0x00
s_pics:
    #d "Loading the page's pictures...", 0x00
s_picl:
    #d "Loading the picture...", 0x00
