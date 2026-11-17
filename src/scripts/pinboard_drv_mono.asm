; pinboard_drv_mono.asm - the display driver MONO.DRV, expanded (after the
; lines of pinboard.asm)
; ---DRIVER---

#include "pinboard_data_mono.asm"

; ============================================================
; EMIT, HFILL, GTYPE: N_CH or N_PH:N_PL, N_CNT and N_MODE are set
; ============================================================

#addr 0x2F00
d_cells:
    ld   [N_MODE], ac
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
    beq  pgs_out
    ld   [GY], ac
    sub  [CY0], ac
    bcs  pgs_out                 ; above the clip
    ld   [GY], ac
    sub  [CY1], ac
    bcc  pgs_out                 ; below it
    ld   [GY], ac               ; row 8 x GY + x20 of the column
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [VL0]
    inc
    ld   ac, [VL0 + 1]
    inc
    ld   ac, [VL0 + 2]
    inc
    ld   ac, [VL0 + 3]
    inc
    ld   ac, [VL0 + 4]
    inc
    ld   ac, [VL0 + 5]
    inc
    ld   ac, [VL0 + 6]
    inc
    ld   ac, [VL0 + 7]
    ld   [GY], ac
    sub  28, ac
    bcs  pgs_p0
    ld   0x61, ac
    bra  pgs_p
pgs_p0:
    ld   0x60, ac
pgs_p:
    ld   ac, [VPG]
    ld   pg_loop >> 8, y
    jmp  pg_loop
pgs_out:
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

d_invc:
    ld   [GX], ac
    sub  80, ac
    bcc  iv_x
    ld   [GY], ac
    sub  60, ac
    bcc  iv_x
    ld   [GY], ac
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [VL0]
    ld   [GY], ac
    sub  28, ac
    bcs  iv_p0
    ld   0x61, ac
    bra  iv_p
iv_p0:
    ld   0x60, ac
iv_p:
    ld   ac, [VPG]
    ld   [GX], ac
    shl
    add  [VPG], ac
    ld   ac, [VH]
    ld   0x50, y
    ld   0xFF, [y,x]
    ld   8, ac
    ld   ac, [N_CNT]
iv_l:
    ld   [VH], y
    ld   [VL0], x
    ld   [y,x], ac
    xor  0xFF, ac
    ld   ac, [y,x]
    ld   [VL0], ac
    inc
    ld   ac, [VL0]
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
; the pointer
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
    ld   LINK_LO, x             ; CALL con_clear
    ld   pd_r3, [x]
    ld   LINK_HI, x
    ld   pd_r3 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
pd_r3:
    ld   0x5B, y                ; rows 456-479
    ld   23, ac
di_tint:
    add  0xE8, x
    ld   0x40, [y,x]
    sub  1, ac
    bcc  di_tint
    ld   lib_leave >> 8, y
    jmp  lib_leave

#addr 0x3000
pg_loop:
    ld   [N_MODE], ac
    beq  pg_ch
    ld   [N_PH], y
    ld   [N_PL], x
    ld   [y,x], ac
    xor  [INV], ac
    ld   ac, [N_CH]
    ld   [N_PL], ac
    inc
    ld   ac, [N_PL]
    bne  pg_ch
    ld   [N_PH], ac
    inc
    ld   ac, [N_PH]
pg_ch:
    ld   [GX], ac
    sub  [CX0], ac
    bcs  pg_skip
    ld   [GX], ac
    sub  [CX1], ac
    bcc  pg_skip
    ld   [GX], ac
    shl
    add  [VPG], ac
    ld   ac, [VH]
    ld   PB_FONT >> 8, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 1, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 1], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 2, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 2], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 3, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 3], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 4, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 4], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 5, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 5], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 6, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 6], x
    ld   ac, [y,x]
    ld   (PB_FONT >> 8) + 7, y
    ld   [N_CH], x
    ld   [y,x], ac
    ld   [VH], y
    ld   [VL0 + 7], x
    ld   ac, [y,x]
pg_skip:
    ld   [GX], ac
    inc
    ld   ac, [GX]
    ld   [N_CNT], ac
    dec
    ld   ac, [N_CNT]
    bne  pg_loop
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

; ============================================================
; INVC ( -- ): the cell at GX, GY turned over (white <-> black).  The
; video RAM is read with every section mapped to RAM (this code is in the
; RAM below x4000, so it runs on).
; ============================================================
; T0-T3)
d_hide:
    ld   [SH_ON], ac
    beq  ph_x
    clr  ac
    ld   ac, [SH_ON]
    ld   ac, [T0]
ph_l:
    ld   [SH_YL], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [SH_YH], ac
    bcc  pra6
    inc
pra6:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb6
    inc
prb6:
    add  [SH_C2], ac
    ld   ac, [T2]
    ld   [T0], ac
    shl
    ld   ac, x
    ld   PSAVE >> 8, y
    ld   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [SH_K], ac
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
    xor  [SH_N], ac
    bne  ph_l
ph_x:
    ld   [LINK_HI], y
    jmp  [LINK_LO]


#addr 0x3100
; T0-T3)
d_show:
    ld   [SH_ON], ac
    bne  ps_x
    ld   [MOK], ac
    bne  ps_x                   ; no mouse: no pointer
    ld   1, ac
    ld   ac, [SH_ON]
    ld   [PXL], ac
    and  7, ac
    shl
    shl
    shl
    shl
    ld   ac, [SH_TI]
    ld   [PXL], ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [T3]
    ld   [PXH], ac
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
    ld   ac, [SH_K]
    ld   [T3], ac
    shl
    add  0x60, ac
    ld   ac, [SH_C2]
    ld   [PYL], ac
    ld   ac, [SH_YL]
    ld   [PYH], ac
    ld   ac, [SH_YH]
    ld   12, ac
    ld   ac, [SH_N]
    ld   [PYH], ac
    beq  ps_go
    ld   0xE0, ac               ; rows left to 480
    sub  [PYL], ac
    ld   ac, [T3]
    sub  12, ac
    bcc  ps_go
    ld   [T3], ac
    ld   ac, [SH_N]
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
    ld   [SH_YL], ac
    add  [T0], ac
    ld   ac, [T1]
    ld   [SH_YH], ac
    bcc  pra7
    inc
pra7:
    ld   ac, [T2]
    ld   [T1], ac
    add  0x20, ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  prb7
    inc
prb7:
    add  [SH_C2], ac
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
    ld   [SH_TI], ac
    or   [T0], ac
    ld   ac, x
    ld   PB_PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PB_PTR >> 8) + 1, y
    or   [y,x], ac
    ld   [T2], y
    ld   [T1], x
    ld   ac, [y,x]
    ld   [SH_K], ac
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
    ld   [SH_TI], ac
    or   [T0], ac
    or   0x80, x
    ld   PB_PTR >> 8, y
    ld   [T3], ac
    and  [y,x], ac
    ld   (PB_PTR >> 8) + 1, y
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
    xor  [SH_N], ac
    bne  ps_l
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]


