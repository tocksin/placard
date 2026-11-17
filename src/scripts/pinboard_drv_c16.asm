; pinboard_drv_c16.asm - the display driver COLOR16.DRV, expanded (after the
; lines of pinboard.asm)
; ---DRIVER---

VLB     = 0x45          ; the low byte of the cell's first row
C0      = 0x46          ; the pages of the cell's byte columns
C1      = 0x47
C2      = 0x48
C3      = 0x49
DPSAVE  = PB_PTR + 0xC0 ; the screen under the pointer: 60 bytes
NB      = 4
PNB     = 5
PSTEP   = 0x20         ; byte << 5 | shift << 4 | row
COLS    = 40
IMASK   = 0xAA         ; INVC: white (A) <-> black (0)
MODEB   = 0x86         ; 160 reads, 2x, 4 bpp
T16L    = DRV + 0x100  ; the left two pixels' byte of a font byte
T16H    = DRV + 0x200  ; the right two

#include "pinboard_data_c16.asm"



#addr 0x3100
d_cells:
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
    beq  dc_out
    ld   [GY], ac
    sub  [CY0], ac
    bcs  dc_out                 ; above the clip
    ld   [GY], ac
    sub  [CY1], ac
    bcc  dc_out                 ; below it
    ld   [GY], ac
    shl
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [VLB]
    ld   [GY], ac
    sub  14, ac
    bcs  vl1
    ld   [VLB], ac
    inc
    ld   ac, [VLB]
vl1:
    ld   dc_loop >> 8, y
    jmp  dc_loop
dc_out:
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

dc_loop:
    ld   [N_MODE], ac
    beq  dc_ch
    ld   [N_PH], y
    ld   [N_PL], x
    ld   [y,x], ac
    xor  [INV], ac
    ld   ac, [N_CH]
    ld   [N_PL], ac
    inc
    ld   ac, [N_PL]
    bne  dc_ch
    ld   [N_PH], ac
    inc
    ld   ac, [N_PH]
dc_ch:
    ld   [GX], ac
    sub  [CX0], ac
    bcs  dc_skip
    ld   [GX], ac
    sub  [CX1], ac
    bcc  dc_skip
    ld   [N_CH], ac
    and  0x7F, ac
    ld   ac, [W0]               ; the font's left byte is at W0,
    or   0x80, ac
    ld   ac, [W1]               ; its right byte at W1
    ld   [N_CH], ac
    and  0x80, ac
    beq  dc_b0
    ld   [CFX], ac              ; from x80 up: the colors swapped
dc_b0:
    xor  [CBG], ac
    ld   ac, [W2]               ; the color of a 0 bit
    ld   [GX], ac
    shl
    shl
    add  0x60, ac
    ld   ac, [C0]
    inc
    ld   ac, [C1]
    inc
    ld   ac, [C2]
    inc
    ld   ac, [C3]
    ld   [VLB], ac
    ld   ac, [W5]               ; the row's low byte
    ld   [W0], ac
    xor  0x20, ac
    beq  dc_sp                  ; a space: one color
    ld   PB_FONT >> 8, ac
    ld   ac, [W4]               ; the font's page of the row
    ld   dc_rows >> 8, y
    jmp  dc_rows
dc_sp:
    ld   dc_fill >> 8, y
    jmp  dc_fill
dc_skip:
    ld   [GX], ac
    inc
    ld   ac, [GX]
    ld   [N_CNT], ac
    dec
    ld   ac, [N_CNT]
    bne  dc_loop
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


#addr 0x3200
dc_fill:
    ld   8, ac
    ld   ac, [W4]
df_l:
    ld   [W5], x
    ld   [W2], ac
    ld   [C0], y
    ld   ac, [y,x]
    ld   [C1], y
    ld   ac, [y,x]
    ld   [C2], y
    ld   ac, [y,x]
    ld   [C3], y
    ld   ac, [y,x]
    ld   [W5], ac
    add  2, ac
    ld   ac, [W5]
    ld   [W4], ac
    dec
    ld   ac, [W4]
    bne  df_l
    ld   dc_skip >> 8, y
    jmp  dc_skip

dc_rows:
    ld   [W4], y
    ld   [W0], x
    ld   [y,x], ac
    ld   ac, [W3]               ; the left 4 pixels
    ld   T16L >> 8, y
    ld   ac, x
    ld   [y,x], ac
    and  [CFX], ac
    xor  [W2], ac
    ld   [C0], y
    ld   [W5], x
    ld   ac, [y,x]
    ld   T16H >> 8, y
    ld   [W3], x
    ld   [y,x], ac
    and  [CFX], ac
    xor  [W2], ac
    ld   [C1], y
    ld   [W5], x
    ld   ac, [y,x]
    ld   [W4], y
    ld   [W1], x
    ld   [y,x], ac
    ld   ac, [W3]               ; the right 4
    ld   T16L >> 8, y
    ld   ac, x
    ld   [y,x], ac
    and  [CFX], ac
    xor  [W2], ac
    ld   [C2], y
    ld   [W5], x
    ld   ac, [y,x]
    ld   T16H >> 8, y
    ld   [W3], x
    ld   [y,x], ac
    and  [CFX], ac
    xor  [W2], ac
    ld   [C3], y
    ld   [W5], x
    ld   ac, [y,x]
    ld   [W5], ac
    add  2, ac
    ld   ac, [W5]
    ld   [W4], ac
    inc
    ld   ac, [W4]
    xor  (PB_FONT >> 8) + 8, ac
    bne  dc_rows
    ld   dc_skip >> 8, y
    jmp  dc_skip

; ============================================================
; INVC ( -- ): the cell at GX, GY turned over.  The video RAM is read
; with every section mapped to RAM (this code is in the RAM below x4000,
; so it runs on).
; ============================================================
d_invc:
    ld   [GX], ac
    sub  COLS, ac
    bcc  iv_x
    ld   [GY], ac
    sub  30, ac
    bcc  iv_x
    ld   [GY], ac
    shl
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [VLB]
    ld   [GY], ac
    sub  14, ac
    bcs  vl6
    ld   [VLB], ac
    inc
    ld   ac, [VLB]
vl6:
    ld   [GX], ac
    shl
    shl
    add  0x60, ac
    ld   ac, [C0]
    ld   0x50, y
    ld   0xFF, [y,x]
    ld   8, ac
    ld   ac, [N_CNT]
iv_l:
    ld   [C0], y
    ld   [VLB], x
    ld   [y,x], ac
    xor  IMASK, ac
    ld   ac, [y,x]
    ld   [C0], ac
    add  1, y
    ld   [VLB], x
    ld   [y,x], ac
    xor  IMASK, ac
    ld   ac, [y,x]
    ld   [C0], ac
    add  2, y
    ld   [VLB], x
    ld   [y,x], ac
    xor  IMASK, ac
    ld   ac, [y,x]
    ld   [C0], ac
    add  3, y
    ld   [VLB], x
    ld   [y,x], ac
    xor  IMASK, ac
    ld   ac, [y,x]
    ld   [VLB], ac
    add  2, ac
    ld   ac, [VLB]
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
; the pointer: 8 pixels of the mode by 12 rows, PNB bytes across.
; SH_C2 = the page of its first byte column, SH_YL = its first row,
; SH_TI = its shift << 4, SH_N = its rows and SH_K = its bytes on the
; screen.  T0 the row, T1 its low byte, T2 the byte, T4 the place in
; DPSAVE, T5 the place in the tables, T6 the column's page.
; ============================================================


#addr 0x3300
; T0-T6)
d_hide:
    ld   [SH_ON], ac
    beq  ph_x
    clr  ac
    ld   ac, [SH_ON]
    ld   ac, [T0]
    ld   0xC0, ac
    ld   ac, [T4]
ph_l:
    ld   [SH_YL], ac
    add  [T0], ac
    ld   ac, [T1]
    sub  112, ac
    bcs  pla8
    ld   [T1], ac
    shl
    add  0x21, ac
    bra  plb8
pla8:
    ld   [T1], ac
    shl
    add  0x20, ac
plb8:
    ld   ac, [T1]
    ld   [SH_C2], ac
    ld   ac, [T6]
    clr  ac
    ld   ac, [T2]
ph_b:
    ld   DPSAVE >> 8, y
    ld   [T4], x
    ld   [y,x], ac
    ld   [T6], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [T6], ac
    inc
    ld   ac, [T6]
    ld   [T4], ac
    inc
    ld   ac, [T4]
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  [SH_K], ac
    bne  ph_b
    ld   [T0], ac
    inc
    ld   ac, [T0]
    xor  [SH_N], ac
    bne  ph_l
ph_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; T0-T6)
d_show:
    ld   [SH_ON], ac
    bne  ps_x
    ld   [MOK], ac
    bne  ps_x                   ; no mouse: no pointer
    ld   1, ac
    ld   ac, [SH_ON]
    ld   [PXL], ac
    and  2, ac                  ; PX is 0-639: a pixel is 2 of it
    shl
    shl
    shl
    ld   ac, [SH_TI]
    ld   [PXL], ac
    shr  ac
    shr  ac
    ld   ac, [T3]
    ld   [PXH], ac
    shl
    shl
    shl
    shl
    shl
    shl
    or   [T3], ac
    ld   ac, [T3]               ; the byte column: PX / 4
    add  0x60, ac
    ld   ac, [SH_C2]
    ld   160, ac                ; bytes left to the right edge
    sub  [T3], ac
    ld   ac, [SH_K]
    sub  PNB, ac
    bcs  ps_k
    ld   PNB, ac
    ld   ac, [SH_K]
ps_k:
    ld   ps_y >> 8, y
    jmp  ps_y
ps_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

ps_y:
    ld   [PYL], ac              ; the row: PY / 2
    shr  ac
    ld   ac, [SH_YL]
    ld   [PYH], ac
    beq  ps_y1
    ld   [SH_YL], ac
    or   0x80, ac
    ld   ac, [SH_YL]
ps_y1:
    ld   240, ac                ; rows left to the bottom
    sub  [SH_YL], ac
    ld   ac, [SH_N]
    sub  12, ac
    bcs  ps_go
    ld   12, ac
    ld   ac, [SH_N]
ps_go:
    ld   0x50, y
    ld   0xFF, [y,x]
    clr  ac
    ld   ac, [T0]
    ld   0xC0, ac
    ld   ac, [T4]
    ld   ps_l >> 8, y
    jmp  ps_l


#addr 0x3400
ps_l:
    ld   [SH_YL], ac
    add  [T0], ac
    ld   ac, [T1]
    sub  112, ac
    bcs  pla9
    ld   [T1], ac
    shl
    add  0x21, ac
    bra  plb9
pla9:
    ld   [T1], ac
    shl
    add  0x20, ac
plb9:
    ld   ac, [T1]
    ld   [SH_C2], ac
    ld   ac, [T6]
    clr  ac
    ld   ac, [T2]
    ld   [SH_TI], ac
    or   [T0], ac
    ld   ac, [T5]
ps_b:
    ld   [T6], y
    ld   [T1], x
    ld   [y,x], ac
    ld   ac, [T3]
    ld   DPSAVE >> 8, y
    ld   [T4], x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   PB_PTR >> 8, y
    ld   [T5], x
    ld   [T3], ac
    and  [y,x], ac
    ld   (PB_PTR >> 8) + 1, y
    or   [y,x], ac
    ld   [T6], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [T6], ac
    inc
    ld   ac, [T6]
    ld   [T4], ac
    inc
    ld   ac, [T4]
    ld   [T5], ac
    add  PSTEP, ac
    ld   ac, [T5]
    ld   [T2], ac
    inc
    ld   ac, [T2]
    xor  [SH_K], ac
    bne  ps_b
    ld   [T0], ac
    inc
    ld   ac, [T0]
    xor  [SH_N], ac
    bne  ps_l
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; d_init - the screen black, every row a 160-read row of the mode (CALL
; it).  Mode bytes x5A00-x5A1F (the lines never shown) stay 0.
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
    ld   0x60, ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R0]
    ld   160, ac
    ld   ac, [W6]
di_l:
    clr  ac
    ld   ac, [R2]               ; a page of 256
    ld   LINK_LO, x             ; CALL memset
    ld   pd_r3, [x]
    ld   LINK_HI, x
    ld   pd_r3 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
pd_r3:
    ld   [W6], ac
    dec
    ld   ac, [W6]
    bne  di_l
    ld   0x5A, ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R0]
    ld   0x20, ac
    ld   ac, [R2]
    clr  ac
    ld   LINK_LO, x             ; CALL memset
    ld   pd_r4, [x]
    ld   LINK_HI, x
    ld   pd_r4 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
pd_r4:
    ld   0xE0, ac
    ld   ac, [R2]
    ld   MODEB, ac
    ld   LINK_LO, x             ; CALL memset
    ld   pd_r5, [x]
    ld   LINK_HI, x
    ld   pd_r5 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
pd_r5:
    clr  ac
    ld   ac, [R2]
    ld   MODEB, ac
    ld   LINK_LO, x             ; CALL memset
    ld   pd_r6, [x]
    ld   LINK_HI, x
    ld   pd_r6 >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
pd_r6:
    ld   lib_leave >> 8, y
    jmp  lib_leave
