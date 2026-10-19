; test_screen.asm - video test screen drawn by the CPU, with a live CPU test
;
; Draws a test screen that uses all four color depths and the line repeat
; modes, then keeps running and shows it on the screen:
;
;   rows   0-95   1 bpp, 1x   80 column text: title, the whole character set
;                             (normal and inverse), the live status lines,
;                             a column ruler and a legend for the bands below
;   rows  96-223  4 bpp, 4x   16 colors (160 x 32): "16 COLORS" in big
;                             letters, the 16 color bars and a spinning wheel
;   rows 224-351  2 bpp, 2x   40 column text (320 x 64), 8 rows of 8 x 16
;                             characters in the 4 colors, with a scrolling
;                             message on the bottom row
;   rows 352-479  8 bpp, 4x   all 256 colors (80 x 32), a 16 x 16 grid
;
; The bands are placed so no two rows share a video byte (docs/VIDEO.md, line
; repeat): 1x rows 0-95 use offsets x020-x07F of each byte column, 4x rows
; 96-223 x181 + 4n, 2x rows 224-351 the odd offsets x101-x17F and 4x rows
; 352-479 x183 + 4n.
;
; While it runs, once per frame (frame_poll):
;   - RAM test: one 256-byte page of x0100-x1EFF and x4000-x4FFF (46 pages;
;     x1F00-x1FFF holds the library's RAM code, LIB_RAM)
;     per frame, 14 patterns each (00, FF, 55, AA, walking 1, and the
;     address XOR a seed and its complement), write then read back.  The
;     progress bar fills a block per page (an inverse E marks a page with
;     errors); PASS counts full passes and ERRORS counts bad reads.
;   - the frame counter, the uptime clock (60 frames = 1 s), the text
;     spinner, the 16-color wheel (one step every 3 frames) and the
;     scrolling message (one character every 8 frames).
;
; It is a ROM program (docs/ROM.md): it runs in place from ROM x6000, uses the
; standard library (docs/LIBRARY.md) and the zero page map, and keeps its
; variables in the zero page x20-x6F.
;
;     python3 gen_test_screen_tables.py         (writes test_screen_tables.asm)
;     python3 placard_sim.py test_screen.asm --run --max-steps 3000000 --png ts.png
;     python3 test_screen_sim.py                (frames and an animated GIF)
;
; Date: 10/19/2026

#include "placard.asm"
#include "placard_lib.asm"

; ---------------------------------------------------------------------------
; program variables (zero page x20-x8F)
; ---------------------------------------------------------------------------
last_frame = 0x20       ; FRAME_LO when the last frame was handled
spin_div   = 0x21       ; frames until the text spinner steps
spin_ph    = 0x22       ; text spinner phase 0-3
big_div    = 0x23       ; frames until the wheel steps
big_ph     = 0x24       ; wheel phase 0-7 (the bright dot)
sec_div    = 0x25       ; frames until the next second
marq_div   = 0x26       ; frames until the message scrolls
marq_lo    = 0x27       ; first character of the message window
marq_hi    = 0x28
CLK        = 0x29       ; uptime "hhmmss", 6 ASCII digits x29-x2E
FRM        = 0x2F       ; frame count, 5 ASCII digits x2F-x33
rt_idx     = 0x34       ; RAM test: page number 0-46 in the pass
rt_page    = 0x35       ;   page address high byte
rt_pat     = 0x36       ;   pattern 0-13
rt_am      = 0x37       ;   pattern address mask (00 or FF)
rt_pv      = 0x38       ;   pattern value
rt_bad     = 0x39       ;   1 when this page had an error
pass_lo    = 0x3A       ;   passes done
pass_hi    = 0x3B
err_lo     = 0x3C       ;   bad reads
err_hi     = 0x3D
rt_i       = 0x3E       ;   byte in the page (X is not a source)
dg_i       = 0x3F       ; ts_tick_frames / ts_tick_clock: digit being stepped

p_col      = 0x40       ; ts_fill_run / ts_put_gbuf / ts_rect: first byte column
p_n        = 0x41       ;   bytes across
p_rlo      = 0x42       ;   screen row 0-479
p_rhi      = 0x43
p_val      = 0x44       ;   fill byte
p_hi       = 0x45       ;   (working address high byte)
p_rows     = 0x46       ;   ts_rect: rows to fill
p_step     = 0x47       ;   ts_rect: row step (the line repeat: 1, 2 or 4)
p_cnt      = 0x48       ;   (working count)
gb0        = 0x49       ; ts_put_gbuf bytes 0-3
gb1        = 0x4A
gb2        = 0x4B
gb3        = 0x4C
c_ch       = 0x4D       ; ts_char2 / ts_char4: character
c_col      = 0x4E       ;   text column 0-39 (char2) or byte column (char4)
c_row      = 0x4F       ;   text row 0-7 (char2) or block row 0-31 (char4)
c_fr       = 0x50       ;   (font row)
c_fg       = 0x51       ;   foreground fill XOR background fill
c_bg       = 0x52       ;   background fill
c_i        = 0x53       ; ts_puts4: character number
s_attr     = 0x54       ; ts_put_str / ts_put_range: OR mask (80 = inverse)
tp_lo      = 0x55       ; ts_tbl_next: table pointer
tp_hi      = 0x56
tb_v       = 0x57
i0         = 0x58       ; loop counters
i1         = 0x59
pz_n       = 0x5A       ; ts_print_zp: count
pr_c       = 0x5B       ; ts_put_range: character
pr_n       = 0x5C       ;   count
pr_inc     = 0x5D       ;   0 = repeat, 1 = count up
dot_k      = 0x5E       ; wheel dot 0-7

; screen places (80 column text)
SPIN_COL   = 13         ; text spinner, row 6
CLK_COL    = 37         ; uptime digits hh at 37, mm at 40, ss at 43, row 6
FRM_COL    = 58         ; frame count, row 6
PAGE_COL   = 37         ; RAM test page, row 7
PASS_COL   = 47         ; RAM test passes, row 7
ERR_COL    = 63         ; RAM test errors, row 7
BAR_COL    = 11         ; progress bar, row 8
NPAGES     = 46         ; RAM test pages per pass
NPAT       = 14         ; RAM test patterns per page

; tables (ROM)
EXP2_LO    = 0x9000     ; font expansion, test_screen_tables.asm
EXP2_HI    = 0x9100
EXP4_0     = 0x9200
EXP4_1     = 0x9300
EXP4_2     = 0x9400
EXP4_3     = 0x9500
TBL        = 0x9600     ; small tables, one page (see the end of this file)

; ===========================================================================
; main: draw the screen, then run the frame loop
; ===========================================================================
#addr 0x6000
main:
    ld   STACK_TOP, ac          ; stack first
    ld   ac, [SP]

    ld   LINK_LO, x             ; CALL con_clear: all 1 bpp 1x, cursor 0, 0
    ld   ts_m1, [x]
    ld   LINK_HI, x
    ld   ts_m1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ts_m1:
    ; row mode bytes: rows 96-223 (x5A80-x5AFF) 4 bpp 4x = 0A,
    ; rows 224-351 (x5B00-x5B7F) 2 bpp 2x = 05, rows 352-479 (x5B80-x5BFF)
    ; 8 bpp 4x = 0B.  Rows 0-95 stay 1 bpp 1x (00).
    ld   0x5A, y
    ld   0x80, ac
ts_mb1:
    ld   ac, x
    ld   0x0A, [y,x]
    inc
    bne  ts_mb1
    ld   0x5B, y
    clr  ac
ts_mb2:
    ld   ac, x
    ld   0x05, [y,x]
    inc
    blt  ts_mb2_b7
    bra  ts_mb2
ts_mb2_b7:
ts_mb3:
    ld   ac, x
    ld   0x0B, [y,x]
    inc
    bne  ts_mb3

    ; ---- 80 column text -------------------------------------------------
    ld   text_a, ac             ; the text list
    ld   ac, [tp_lo]
    ld   text_a >> 8, ac
    ld   ac, [tp_hi]
    ld   LINK_LO, x             ; CALL ts_text_list
    ld   ts_m2, [x]
    ld   LINK_HI, x
    ld   ts_m2 >> 8, [x]
    ld   ts_text_list >> 8, y
    jmp  ts_text_list
ts_m2:
    ld   1, ac                  ; character set 20-6F on row 2
    ld   ac, [pr_inc]
    clr  ac
    ld   ac, [CUR_COL]
    ld   ac, [s_attr]
    ld   2, ac
    ld   ac, [CUR_ROW]
    ld   80, ac
    ld   ac, [pr_n]
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL ts_put_range
    ld   ts_m3, [x]
    ld   LINK_HI, x
    ld   ts_m3 >> 8, [x]
    ld   ts_put_range >> 8, y
    jmp  ts_put_range
ts_m3:
    clr  ac                     ; 70-7E on row 3
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   15, ac
    ld   ac, [pr_n]
    ld   0x70, ac
    ld   LINK_LO, x             ; CALL ts_put_range
    ld   ts_m4, [x]
    ld   LINK_HI, x
    ld   ts_m4 >> 8, [x]
    ld   ts_put_range >> 8, y
    jmp  ts_put_range
ts_m4:
    clr  ac                     ; 20-6F in inverse video on row 4
    ld   ac, [CUR_COL]
    ld   4, ac
    ld   ac, [CUR_ROW]
    ld   80, ac
    ld   ac, [pr_n]
    ld   0x80, ac
    ld   ac, [s_attr]
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL ts_put_range
    ld   ts_m5, [x]
    ld   LINK_HI, x
    ld   ts_m5 >> 8, [x]
    ld   ts_put_range >> 8, y
    jmp  ts_put_range
ts_m5:
    clr  ac                     ; progress bar: 46 dots
    ld   ac, [pr_inc]
    ld   ac, [s_attr]
    ld   BAR_COL, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   NPAGES, ac
    ld   ac, [pr_n]
    ld   0x2E, ac
    ld   LINK_LO, x             ; CALL ts_put_range
    ld   ts_m6, [x]
    ld   LINK_HI, x
    ld   ts_m6 >> 8, [x]
    ld   ts_put_range >> 8, y
    jmp  ts_put_range
ts_m6:
    ; ---- 16 colors: 4 bpp, 4x, rows 96-223 ------------------------------
    ld   s_16col, ac            ; "16 COLORS" in rainbow letters
    ld   ac, [R0]
    ld   s_16col >> 8, ac
    ld   ac, [R1]
    ld   2, ac
    ld   ac, [c_col]
    clr  ac
    ld   ac, [c_row]
    ld   ac, [c_bg]
    ld   LINK_LO, x             ; CALL ts_puts4
    ld   ts_m7, [x]
    ld   LINK_HI, x
    ld   ts_m7 >> 8, [x]
    ld   ts_puts4 >> 8, y
    jmp  ts_puts4
ts_m7:
    ld   ts_bars >> 8, y
    jmp  ts_bars

; ---------------------------------------------------------------------------
#addr 0x6200
ts_bars:
    clr  ac                     ; 16 color bars, 3 bytes (6 pixels) wide,
    ld   ac, [i0]               ; block rows 10-30
ts_bb:
    ld   [i0], ac               ; fill = color * x11
    shl
    shl
    shl
    shl
    or   [i0], ac
    ld   ac, [p_val]
    ld   [i0], ac               ; byte column 2 + 3 * color
    shl
    add  [i0], ac
    add  2, ac
    ld   ac, [p_col]
    ld   96 + 4 * 10, ac
    ld   ac, [p_rlo]
    clr  ac
    ld   ac, [p_rhi]
    ld   3, ac
    ld   ac, [p_n]
    ld   21, ac
    ld   ac, [p_rows]
    ld   4, ac
    ld   ac, [p_step]
    ld   LINK_LO, x             ; CALL ts_rect
    ld   ts_bb1, [x]
    ld   LINK_HI, x
    ld   ts_bb1 >> 8, [x]
    ld   ts_rect >> 8, y
    jmp  ts_rect
ts_bb1:
    ld   [i0], ac
    inc
    ld   ac, [i0]
    sub  16, ac
    bne  ts_bb

    ; ---- 40 column text: 2 bpp, 2x, rows 224-351 ------------------------
    ld   text_c, ac
    ld   ac, [tp_lo]
    ld   text_c >> 8, ac
    ld   ac, [tp_hi]
    ld   LINK_LO, x             ; CALL ts_text2_list
    ld   ts_bb2, [x]
    ld   LINK_HI, x
    ld   ts_bb2 >> 8, [x]
    ld   ts_text2_list >> 8, y
    jmp  ts_text2_list
ts_bb2:
    ld   ts_grid >> 8, y
    jmp  ts_grid

; ---------------------------------------------------------------------------
#addr 0x6300
ts_grid:
    ; ---- 256 colors: 8 bpp, 4x, rows 352-479 ----------------------------
    ; a 16 x 16 grid, each cell 5 bytes by 2 block rows (8 lines); the color
    ; byte (G3 G2 G1 B3 B2 R3 R2 R1) is ROWPART[row] OR COLPART[column]
    clr  ac
    ld   ac, [i0]               ; grid row
ts_gr:
    clr  ac
    ld   ac, [i1]               ; grid column
ts_gc:
    ld   TBL >> 8, y
    ld   [i1], ac
    add  COLPART & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [p_val]
    ld   [i0], ac
    add  ROWPART & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    or   [p_val], ac
    ld   ac, [p_val]
    ld   [i1], ac               ; byte column 5 * column
    shl
    shl
    add  [i1], ac
    ld   ac, [p_col]
    ld   [i0], ac               ; row 352 + 8 * row = x100 + 96 + 8 * row
    shl
    shl
    shl
    add  96, ac
    ld   ac, [p_rlo]
    ld   1, ac
    ld   ac, [p_rhi]
    ld   5, ac
    ld   ac, [p_n]
    ld   2, ac
    ld   ac, [p_rows]
    ld   4, ac
    ld   ac, [p_step]
    ld   LINK_LO, x             ; CALL ts_rect
    ld   ts_gr1, [x]
    ld   LINK_HI, x
    ld   ts_gr1 >> 8, [x]
    ld   ts_rect >> 8, y
    jmp  ts_rect
ts_gr1:
    ld   [i1], ac
    inc
    ld   ac, [i1]
    sub  16, ac
    bne  ts_gc
    ld   [i0], ac
    inc
    ld   ac, [i0]
    sub  16, ac
    bne  ts_gr

    ; ---- variables ----------------------------------------------------
    ld   0x30, ac               ; uptime 00:00:00, frame count 00000
    ld   ac, [CLK + 0]
    ld   ac, [CLK + 1]
    ld   ac, [CLK + 2]
    ld   ac, [CLK + 3]
    ld   ac, [CLK + 4]
    ld   ac, [CLK + 5]
    ld   ac, [FRM + 0]
    ld   ac, [FRM + 1]
    ld   ac, [FRM + 2]
    ld   ac, [FRM + 3]
    ld   ac, [FRM + 4]
    ld   1, ac                  ; every divider runs out on the first frame
    ld   ac, [spin_div]
    ld   ac, [big_div]
    ld   ac, [marq_div]
    ld   60, ac
    ld   ac, [sec_div]
    clr  ac
    ld   ac, [spin_ph]
    ld   ac, [big_ph]
    ld   ac, [rt_idx]
    ld   ac, [pass_lo]
    ld   ac, [pass_hi]
    ld   ac, [err_lo]
    ld   ac, [err_hi]
    ld   msg, ac
    ld   ac, [marq_lo]
    ld   msg >> 8, ac
    ld   ac, [marq_hi]
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]
    ld   ts_loop >> 8, y
    jmp  ts_loop

; ===========================================================================
; the frame loop
; ===========================================================================
#addr 0x6400
ts_loop:
    ld   LINK_LO, x             ; CALL frame_poll
    ld   ts_l1, [x]
    ld   LINK_HI, x
    ld   ts_l1 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
ts_l1:
    ld   [FRAME_LO], ac         ; wait for a new frame
    xor  [last_frame], ac
    beq  ts_loop
    ld   [FRAME_LO], ac
    ld   ac, [last_frame]

    ld   LINK_LO, x             ; CALL ts_ram_page: test one page
    ld   ts_l2, [x]
    ld   LINK_HI, x
    ld   ts_l2 >> 8, [x]
    ld   ts_ram_page >> 8, y
    jmp  ts_ram_page
ts_l2:
    ld   LINK_LO, x             ; CALL ts_tick_frames
    ld   ts_l3, [x]
    ld   LINK_HI, x
    ld   ts_l3 >> 8, [x]
    ld   ts_tick_frames >> 8, y
    jmp  ts_tick_frames
ts_l3:
    ld   [spin_div], ac         ; text spinner every 4 frames
    dec
    ld   ac, [spin_div]
    bne  ts_l4
    ld   4, ac
    ld   ac, [spin_div]
    ld   [spin_ph], ac
    inc
    and  3, ac
    ld   ac, [spin_ph]
    add  SPIN & 0xFF, ac
    ld   ac, x
    ld   TBL >> 8, y
    ld   [y,x], ac
    ld   ac, [tb_v]
    ld   SPIN_COL, ac
    ld   ac, [CUR_COL]
    ld   6, ac
    ld   ac, [CUR_ROW]
    ld   [tb_v], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   ts_l4, [x]
    ld   LINK_HI, x
    ld   ts_l4 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ts_l4:
    ld   [big_div], ac          ; wheel every 3 frames
    dec
    ld   ac, [big_div]
    bne  ts_l5
    ld   3, ac
    ld   ac, [big_div]
    ld   [big_ph], ac
    inc
    and  7, ac
    ld   ac, [big_ph]
    ld   LINK_LO, x             ; CALL ts_wheel
    ld   ts_l5, [x]
    ld   LINK_HI, x
    ld   ts_l5 >> 8, [x]
    ld   ts_wheel >> 8, y
    jmp  ts_wheel
ts_l5:
    ld   [sec_div], ac          ; uptime clock every 60 frames
    dec
    ld   ac, [sec_div]
    bne  ts_l6
    ld   60, ac
    ld   ac, [sec_div]
    ld   LINK_LO, x             ; CALL ts_tick_clock
    ld   ts_l6, [x]
    ld   LINK_HI, x
    ld   ts_l6 >> 8, [x]
    ld   ts_tick_clock >> 8, y
    jmp  ts_tick_clock
ts_l6:
    ld   [marq_div], ac         ; message every 8 frames
    dec
    ld   ac, [marq_div]
    bne  ts_l7
    ld   8, ac
    ld   ac, [marq_div]
    ld   LINK_LO, x             ; CALL ts_marquee
    ld   ts_l7, [x]
    ld   LINK_HI, x
    ld   ts_l7 >> 8, [x]
    ld   ts_marquee >> 8, y
    jmp  ts_marquee
ts_l7:
    ld   ts_loop >> 8, y
    jmp  ts_loop

; ===========================================================================
; ts_ram_page - test one page of the RAM test and show the result
;   Writes each of the NPAT patterns to the whole page and reads it back.
;   Fixed patterns are PAT_P; address patterns (PAT_AM = FF) are the low
;   address byte XOR PAT_P XOR (pass_lo XOR page), so they change every
;   pass.  Then marks the progress bar, shows the page, PASS and ERRORS,
;   and moves on to the next page.
; ===========================================================================
#addr 0x6600
ts_ram_page:
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

    ld   [rt_idx], ac           ; page = PAGES[rt_idx]
    add  PAGES & 0xFF, ac
    ld   ac, x
    ld   TBL >> 8, y
    ld   [y,x], ac
    ld   ac, [rt_page]
    clr  ac
    ld   ac, [rt_bad]
    ld   ac, [rt_pat]
ts_rp_pat:
    ld   TBL >> 8, y            ; rt_am = PAT_AM[rt_pat]
    ld   [rt_pat], ac
    add  PAT_AM & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [rt_am]
    ld   [pass_lo], ac          ; rt_pv = PAT_P[rt_pat] ^ (am & (pass ^ page))
    xor  [rt_page], ac
    and  [rt_am], ac
    ld   ac, [rt_pv]
    ld   [rt_pat], ac
    add  PAT_P & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    xor  [rt_pv], ac
    ld   ac, [rt_pv]
    ld   [rt_page], y
    clr  ac
ts_rp_wr:                       ; AC = rt_i = the byte in the page
    ld   ac, x                  ; [page, X] = (X & am) ^ pv
    ld   ac, [rt_i]
    and  [rt_am], ac
    xor  [rt_pv], ac
    ld   ac, [y,x]
    ld   [rt_i], ac
    inc
    bne  ts_rp_wr
ts_rp_vf:
    ld   ac, x                  ; read it back
    ld   ac, [rt_i]
    and  [rt_am], ac
    xor  [rt_pv], ac
    xor  [y,x], ac
    beq  ts_rp_ok
    ld   1, ac                  ; bad read
    ld   ac, [rt_bad]
    ld   [err_lo], ac
    inc
    ld   ac, [err_lo]
    bne  ts_rp_ok
    ld   [err_hi], ac
    inc
    ld   ac, [err_hi]
ts_rp_ok:
    ld   [rt_i], ac
    inc
    bne  ts_rp_vf
    ld   [rt_pat], ac
    inc
    ld   ac, [rt_pat]
    sub  NPAT, ac
    bne  ts_rp_pat

    ld   [rt_idx], ac           ; progress bar cell: block, or inverse E
    add  BAR_COL, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [rt_bad], ac
    beq  ts_rp_blk
    ld   0xC5, ac
    bra  ts_rp_put
ts_rp_blk:
    ld   0xA0, ac
ts_rp_put:
    ld   LINK_LO, x             ; CALL con_putc
    ld   ts_rp1, [x]
    ld   LINK_HI, x
    ld   ts_rp1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ts_rp1:
    ld   PAGE_COL, ac           ; page address
    ld   ac, [CUR_COL]
    ld   7, ac
    ld   ac, [CUR_ROW]
    ld   [rt_page], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   ts_rp2, [x]
    ld   LINK_HI, x
    ld   ts_rp2 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ts_rp2:
    ld   ERR_COL, ac            ; errors
    ld   ac, [CUR_COL]
    ld   [err_lo], ac
    ld   ac, [R0]
    ld   [err_hi], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_dec16
    ld   ts_rp3, [x]
    ld   LINK_HI, x
    ld   ts_rp3 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ts_rp3:
    ld   [rt_idx], ac           ; next page
    inc
    ld   ac, [rt_idx]
    sub  NPAGES, ac
    bne  ts_rp_more
    ld   ts_rp_pass >> 8, y
    jmp  ts_rp_pass
ts_rp_more:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

#addr 0x6700
ts_rp_pass:
    clr  ac                     ; end of a pass: back to the first page
    ld   ac, [rt_idx]
    ld   [pass_lo], ac
    inc
    ld   ac, [pass_lo]
    bne  ts_rp_p1
    ld   [pass_hi], ac
    inc
    ld   ac, [pass_hi]
ts_rp_p1:
    ld   PASS_COL, ac           ; passes
    ld   ac, [CUR_COL]
    ld   [pass_lo], ac
    ld   ac, [R0]
    ld   [pass_hi], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_dec16
    ld   ts_rp4, [x]
    ld   LINK_HI, x
    ld   ts_rp4 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ts_rp4:
    clr  ac                     ; progress bar back to dots
    ld   ac, [pr_inc]
    ld   ac, [s_attr]
    ld   BAR_COL, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   NPAGES, ac
    ld   ac, [pr_n]
    ld   0x2E, ac
    ld   LINK_LO, x             ; CALL ts_put_range
    ld   ts_rp5, [x]
    ld   LINK_HI, x
    ld   ts_rp5 >> 8, [x]
    ld   ts_put_range >> 8, y
    jmp  ts_put_range
ts_rp5:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ===========================================================================
; ts_tick_frames - add one to the frame count and show it
; ts_tick_clock  - add one second to the uptime clock and show it
; ===========================================================================
#addr 0x6800
ts_tick_frames:
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
    ld   4, ac                  ; last digit first
ts_tf_d:
    ld   ac, [dg_i]
    add  FRM, x                 ; X = FRM + digit
    ld   [x], ac
    inc
    ld   ac, [x]
    sub  0x3A, ac
    bne  ts_tf_show
    ld   0x30, [x]              ; 9 + 1: 0 and carry
    ld   [dg_i], ac
    sub  1, ac
    bcc  ts_tf_d                ; a borrow: it was the first digit
ts_tf_show:
    ld   FRM_COL, ac
    ld   ac, [CUR_COL]
    ld   6, ac
    ld   ac, [CUR_ROW]
    ld   FRM, ac
    ld   ac, [R0]
    ld   5, ac
    ld   ac, [pz_n]
    ld   LINK_LO, x             ; CALL ts_print_zp
    ld   ts_tf1, [x]
    ld   LINK_HI, x
    ld   ts_tf1 >> 8, [x]
    ld   ts_print_zp >> 8, y
    jmp  ts_print_zp
ts_tf1:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

ts_tick_clock:
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
    ld   TBL >> 8, y            ; TBL + x29.. holds each digit's limit
    ld   5, ac                  ; seconds digit first
ts_tc_d:
    ld   ac, [dg_i]
    add  CLK, x                 ; X = CLK + digit
    ld   [x], ac
    inc
    ld   ac, [x]
    xor  [y,x], ac
    bne  ts_tc_show
    ld   0x30, [x]              ; at its limit: 0 and carry
    ld   [dg_i], ac
    sub  1, ac
    bcc  ts_tc_d                ; a borrow: it was the first digit
ts_tc_show:
    ld   CLK_COL, ac            ; hh
    ld   ac, [CUR_COL]
    ld   6, ac
    ld   ac, [CUR_ROW]
    ld   CLK, ac
    ld   ac, [R0]
    ld   2, ac
    ld   ac, [pz_n]
    ld   LINK_LO, x             ; CALL ts_print_zp
    ld   ts_tc1, [x]
    ld   LINK_HI, x
    ld   ts_tc1 >> 8, [x]
    ld   ts_print_zp >> 8, y
    jmp  ts_print_zp
ts_tc1:
    ld   CLK_COL + 3, ac        ; mm
    ld   ac, [CUR_COL]
    ld   CLK + 2, ac
    ld   ac, [R0]
    ld   2, ac
    ld   ac, [pz_n]
    ld   LINK_LO, x             ; CALL ts_print_zp
    ld   ts_tc2, [x]
    ld   LINK_HI, x
    ld   ts_tc2 >> 8, [x]
    ld   ts_print_zp >> 8, y
    jmp  ts_print_zp
ts_tc2:
    ld   CLK_COL + 6, ac        ; ss
    ld   ac, [CUR_COL]
    ld   CLK + 4, ac
    ld   ac, [R0]
    ld   2, ac
    ld   ac, [pz_n]
    ld   LINK_LO, x             ; CALL ts_print_zp
    ld   ts_tc3, [x]
    ld   LINK_HI, x
    ld   ts_tc3 >> 8, [x]
    ld   ts_print_zp >> 8, y
    jmp  ts_print_zp
ts_tc3:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ===========================================================================
; ts_wheel - draw the 16-color wheel for phase big_ph
;   Eight 4 x 4 pixel dots on a circle in the 4 bpp band; dot k gets color
;   TAIL[(big_ph - k) & 7], so the white dot leads a fading tail and the
;   wheel turns clockwise as big_ph counts up.
; ===========================================================================
#addr 0x6A00
ts_wheel:
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
    ld   ac, [dot_k]
ts_wh_dot:
    ld   TBL >> 8, y
    ld   [big_ph], ac           ; color
    sub  [dot_k], ac
    and  7, ac
    add  TAIL & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [p_val]
    ld   [dot_k], ac            ; place
    add  DOTC & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [p_col]
    ld   [dot_k], ac
    add  DOTR & 0xFF, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [p_rlo]
    clr  ac
    ld   ac, [p_rhi]
    ld   2, ac
    ld   ac, [p_n]
    ld   4, ac
    ld   ac, [p_rows]
    ld   ac, [p_step]
    ld   LINK_LO, x             ; CALL ts_rect
    ld   ts_wh1, [x]
    ld   LINK_HI, x
    ld   ts_wh1 >> 8, [x]
    ld   ts_rect >> 8, y
    jmp  ts_rect
ts_wh1:
    ld   [dot_k], ac
    inc
    ld   ac, [dot_k]
    sub  8, ac
    bne  ts_wh_dot
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ===========================================================================
; ts_marquee - draw 40 characters of the message on text row 7 of the
;   40 column band, starting at marq_hi:marq_lo, then move the start on by
;   one character (wrapping at the 00 at the end of the message)
; ===========================================================================
#addr 0x6B00
ts_marquee:
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
    ld   [marq_lo], ac
    ld   ac, [R0]
    ld   [marq_hi], ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [c_col]
    ld   7, ac
    ld   ac, [c_row]
    ld   0xFF, ac               ; gold (AA) on blue (55)
    ld   ac, [c_fg]
    ld   0x55, ac
    ld   ac, [c_bg]
ts_mq_ch:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    bne  ts_mq_put
    ld   msg, ac                ; end of the message: wrap
    ld   ac, [R0]
    ld   msg >> 8, ac
    ld   ac, [R1]
    bra  ts_mq_ch
ts_mq_put:
    ld   ac, [c_ch]
    ld   LINK_LO, x             ; CALL ts_char2
    ld   ts_mq1, [x]
    ld   LINK_HI, x
    ld   ts_mq1 >> 8, [x]
    ld   ts_char2 >> 8, y
    jmp  ts_char2
ts_mq1:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  ts_mq2
    ld   [R1], ac
    inc
    ld   ac, [R1]
ts_mq2:
    ld   [c_col], ac
    inc
    ld   ac, [c_col]
    sub  40, ac
    bne  ts_mq_ch
    ld   [marq_hi], y           ; move the start on
    ld   [marq_lo], ac
    inc
    ld   ac, [marq_lo]
    bne  ts_mq3
    ld   [marq_hi], ac
    inc
    ld   ac, [marq_hi]
    ld   ac, y
ts_mq3:
    ld   [marq_lo], x
    ld   [y,x], ac
    bne  ts_mq4
    ld   msg, ac
    ld   ac, [marq_lo]
    ld   msg >> 8, ac
    ld   ac, [marq_hi]
ts_mq4:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ===========================================================================
; drawing routines
; ===========================================================================

; ---------------------------------------------------------------------------
; ts_fill_run - write p_val to p_n bytes across, from byte column p_col,
;   on screen row p_rhi:p_rlo (any mode and line repeat, via vid_addr)
;   changes: AC, X, Y, R2, R3, T0, T1, T4, p_hi, p_cnt
; ---------------------------------------------------------------------------
#addr 0x6C00
ts_fill_run:
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
    ld   [p_rlo], ac
    ld   ac, [R2]
    ld   [p_rhi], ac
    ld   ac, [R3]
    ld   [p_col], ac
    ld   LINK_LO, x             ; CALL vid_addr
    ld   ts_fr1, [x]
    ld   LINK_HI, x
    ld   ts_fr1 >> 8, [x]
    ld   vid_addr >> 8, y
    jmp  vid_addr
ts_fr1:
    ld   ac, [p_hi]
    ld   [p_n], ac
    ld   ac, [p_cnt]
ts_fr_loop:
    ld   [p_hi], y
    ld   [p_val], ac
    ld   ac, [y,x]
    ld   [p_hi], ac             ; next byte column: 2 pages on
    add  2, ac
    ld   ac, [p_hi]
    ld   [p_cnt], ac
    dec
    ld   ac, [p_cnt]
    bne  ts_fr_loop
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_rect - fill p_rows rows, p_step apart, from row p_rhi:p_rlo, with
;   ts_fill_run (p_val, p_col, p_n).  p_step is the band's line repeat, so
;   each row of video memory is written once.
;   changes: as ts_fill_run, and p_rlo, p_rhi, p_rows
; ---------------------------------------------------------------------------
ts_rect:
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
ts_rc_row:
    ld   LINK_LO, x             ; CALL ts_fill_run
    ld   ts_rc1, [x]
    ld   LINK_HI, x
    ld   ts_rc1 >> 8, [x]
    ld   ts_fill_run >> 8, y
    jmp  ts_fill_run
ts_rc1:
    ld   [p_rlo], ac            ; row + step, carry into p_rhi
    add  [p_step], ac
    ld   ac, [p_rlo]
    bcc  ts_rc_nc
    ld   [p_rhi], ac
    inc
    ld   ac, [p_rhi]
ts_rc_nc:
    ld   [p_rows], ac
    dec
    ld   ac, [p_rows]
    bne  ts_rc_row
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_put_gbuf - write gb0.. (p_n = 1-4 bytes) across from byte column
;   p_col on row p_rhi:p_rlo
;   changes: AC, X, Y, R2, R3, T0, T1, T4, p_hi, p_cnt
; ---------------------------------------------------------------------------
#addr 0x6D00
ts_put_gbuf:
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
    ld   [p_rlo], ac
    ld   ac, [R2]
    ld   [p_rhi], ac
    ld   ac, [R3]
    ld   [p_col], ac
    ld   LINK_LO, x             ; CALL vid_addr
    ld   ts_pg1, [x]
    ld   LINK_HI, x
    ld   ts_pg1 >> 8, [x]
    ld   vid_addr >> 8, y
    jmp  vid_addr
ts_pg1:
    ld   ac, y
    ld   ac, [p_hi]
    ld   [gb0], ac
    ld   ac, [y,x]
    ld   [p_n], ac
    dec
    beq  ts_pg_done
    ld   ac, [p_cnt]
    ld   [p_hi], ac
    add  2, ac
    ld   ac, [p_hi]
    ld   ac, y
    ld   [gb1], ac
    ld   ac, [y,x]
    ld   [p_cnt], ac
    dec
    beq  ts_pg_done
    ld   ac, [p_cnt]
    ld   [p_hi], ac
    add  2, ac
    ld   ac, [p_hi]
    ld   ac, y
    ld   [gb2], ac
    ld   ac, [y,x]
    ld   [p_cnt], ac
    dec
    beq  ts_pg_done
    ld   [p_hi], ac
    add  2, ac
    ld   ac, y
    ld   [gb3], ac
    ld   ac, [y,x]
ts_pg_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_char2 - one 8 x 8 character on the 2 bpp, 2x band (rows 224-351)
;   in: c_ch, c_col = text column 0-39, c_row = text row 0-7,
;       c_fg = foreground fill XOR c_bg, c_bg = background fill
;       (fills: 00 black, 55 blue, AA gold, FF white)
;   Each font row is 2 bytes (8 pixels) on one 2x row pair, so the
;   character is 16 lines tall.
;   changes: AC, X, Y, R2, R3, T0, T1, T4, p_*, gb0, gb1, c_fr
; ---------------------------------------------------------------------------
ts_char2:
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
    ld   [c_row], ac            ; row 224 + 16 * text row; the 8 font rows
    shl                         ; (+ 0-14) never cross a 256-row boundary
    shl
    shl
    shl
    add  224, ac
    ld   ac, [p_rlo]
    ld   1, ac                  ; high byte 1 from text row 2 on
    ld   ac, [p_rhi]
    ld   [c_row], ac
    sub  2, ac
    bcc  ts_c2_hi
    clr  ac
    ld   ac, [p_rhi]
ts_c2_hi:
    ld   [c_col], ac            ; 2 byte columns per character
    shl
    ld   ac, [p_col]
    clr  ac
    ld   ac, [c_fr]
    ld   ts_c2_row >> 8, y
    jmp  ts_c2_row
#addr 0x6E00
ts_c2_row:
    ld   [c_fr], ac             ; font byte
    add  LIB_FONT >> 8, ac
    ld   ac, y
    ld   [c_ch], x
    ld   [y,x], ac
    ld   ac, x
    ld   EXP2_LO >> 8, y        ; pixels 0-3
    ld   [y,x], ac
    and  [c_fg], ac
    xor  [c_bg], ac
    ld   ac, [gb0]
    ld   EXP2_HI >> 8, y        ; pixels 4-7
    ld   [y,x], ac
    and  [c_fg], ac
    xor  [c_bg], ac
    ld   ac, [gb1]
    ld   2, ac
    ld   ac, [p_n]
    ld   LINK_LO, x             ; CALL ts_put_gbuf
    ld   ts_c2_1, [x]
    ld   LINK_HI, x
    ld   ts_c2_1 >> 8, [x]
    ld   ts_put_gbuf >> 8, y
    jmp  ts_put_gbuf
ts_c2_1:
    ld   [p_rlo], ac            ; next row pair
    add  2, ac
    ld   ac, [p_rlo]
    ld   [c_fr], ac
    inc
    ld   ac, [c_fr]
    sub  8, ac
    bne  ts_c2_row
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_char4 - one 8 x 8 character on the 4 bpp, 4x band (rows 96-223)
;   in: c_ch, c_col = byte column (4 per character), c_row = block row
;       0-24 (4 lines each), c_fg = foreground fill XOR c_bg, c_bg
;       (fill = color * 11)
;   changes: AC, X, Y, R2, R3, T0, T1, T4, p_*, gb0-gb3, c_fr
; ---------------------------------------------------------------------------
ts_char4:
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
    ld   [c_row], ac            ; row 96 + 4 * block row
    shl
    shl
    add  96, ac
    ld   ac, [p_rlo]
    clr  ac
    ld   ac, [p_rhi]
    ld   ac, [c_fr]
    ld   [c_col], ac
    ld   ac, [p_col]
    ld   ts_c4_row >> 8, y
    jmp  ts_c4_row
#addr 0x6F00
ts_c4_row:
    ld   [c_fr], ac             ; font byte
    add  LIB_FONT >> 8, ac
    ld   ac, y
    ld   [c_ch], x
    ld   [y,x], ac
    ld   ac, x
    ld   EXP4_0 >> 8, y         ; pixels 0-1
    ld   [y,x], ac
    and  [c_fg], ac
    xor  [c_bg], ac
    ld   ac, [gb0]
    ld   EXP4_1 >> 8, y         ; pixels 2-3
    ld   [y,x], ac
    and  [c_fg], ac
    xor  [c_bg], ac
    ld   ac, [gb1]
    ld   EXP4_2 >> 8, y         ; pixels 4-5
    ld   [y,x], ac
    and  [c_fg], ac
    xor  [c_bg], ac
    ld   ac, [gb2]
    ld   EXP4_3 >> 8, y         ; pixels 6-7
    ld   [y,x], ac
    and  [c_fg], ac
    xor  [c_bg], ac
    ld   ac, [gb3]
    ld   4, ac
    ld   ac, [p_n]
    ld   LINK_LO, x             ; CALL ts_put_gbuf
    ld   ts_c4_1, [x]
    ld   LINK_HI, x
    ld   ts_c4_1 >> 8, [x]
    ld   ts_put_gbuf >> 8, y
    jmp  ts_put_gbuf
ts_c4_1:
    ld   [p_rlo], ac            ; next block row
    add  4, ac
    ld   ac, [p_rlo]
    ld   [c_fr], ac
    inc
    ld   ac, [c_fr]
    sub  8, ac
    bne  ts_c4_row
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_puts4 - string R1:R0 (ending in 00) on the 4 bpp band with ts_char4,
;   from c_col, c_row, each character in the next RAINBOW color, c_bg = 00
;   changes: AC, X, Y, R0-R3, T0, T1, T4, c_col, c_i and as ts_char4
; ---------------------------------------------------------------------------
#addr 0x7000
ts_puts4:
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
    ld   ac, [c_i]
ts_p4_ch:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    beq  ts_p4_done
    ld   ac, [c_ch]
    ld   [c_i], ac              ; color
    add  RAINBOW & 0xFF, ac
    ld   ac, x
    ld   TBL >> 8, y
    ld   [y,x], ac
    ld   ac, [c_fg]
    ld   LINK_LO, x             ; CALL ts_char4
    ld   ts_p4_1, [x]
    ld   LINK_HI, x
    ld   ts_p4_1 >> 8, [x]
    ld   ts_char4 >> 8, y
    jmp  ts_char4
ts_p4_1:
    ld   [c_col], ac
    add  4, ac
    ld   ac, [c_col]
    ld   [c_i], ac
    inc
    ld   ac, [c_i]
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  ts_p4_ch
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  ts_p4_ch
ts_p4_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_text2_list - draw a list of strings on the 40 column band
;   tp_hi:tp_lo = list of (text column, text row, fg XOR bg, bg, string low,
;   string high) entries, ending with FF
; ---------------------------------------------------------------------------
#addr 0x7100
ts_text2_list:
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
ts_t2_ent:
    ld   LINK_LO, x             ; CALL ts_tbl_next: column, or FF
    ld   ts_t2_1, [x]
    ld   LINK_HI, x
    ld   ts_t2_1 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_t2_1:
    blt  ts_t2_done
    ld   ac, [c_col]
    ld   LINK_LO, x             ; CALL ts_tbl_next: row
    ld   ts_t2_2, [x]
    ld   LINK_HI, x
    ld   ts_t2_2 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_t2_2:
    ld   ac, [c_row]
    ld   LINK_LO, x             ; CALL ts_tbl_next: fg XOR bg
    ld   ts_t2_3, [x]
    ld   LINK_HI, x
    ld   ts_t2_3 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_t2_3:
    ld   ac, [c_fg]
    ld   LINK_LO, x             ; CALL ts_tbl_next: bg
    ld   ts_t2_4, [x]
    ld   LINK_HI, x
    ld   ts_t2_4 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_t2_4:
    ld   ac, [c_bg]
    ld   LINK_LO, x             ; CALL ts_tbl_next: string low
    ld   ts_t2_5, [x]
    ld   LINK_HI, x
    ld   ts_t2_5 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_t2_5:
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL ts_tbl_next: string high
    ld   ts_t2_6, [x]
    ld   LINK_HI, x
    ld   ts_t2_6 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_t2_6:
    ld   ac, [R1]
ts_t2_ch:
    ld   [R1], y                ; the string
    ld   [R0], x
    ld   [y,x], ac
    beq  ts_t2_ent
    ld   ac, [c_ch]
    ld   LINK_LO, x             ; CALL ts_char2
    ld   ts_t2_7, [x]
    ld   LINK_HI, x
    ld   ts_t2_7 >> 8, [x]
    ld   ts_char2 >> 8, y
    jmp  ts_char2
ts_t2_7:
    ld   [c_col], ac
    inc
    ld   ac, [c_col]
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  ts_t2_ch
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  ts_t2_ch
ts_t2_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_text_list - print a list of strings with the console
;   tp_hi:tp_lo = list of (column, row, attribute, string low, string high)
;   entries, ending with FF; the attribute is ORed into each character
;   (80 = inverse video)
; ---------------------------------------------------------------------------
#addr 0x7200
ts_text_list:
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
ts_tl_ent:
    ld   LINK_LO, x             ; CALL ts_tbl_next: column, or FF
    ld   ts_tl_1, [x]
    ld   LINK_HI, x
    ld   ts_tl_1 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_tl_1:
    blt  ts_tl_done
    ld   ac, [CUR_COL]
    ld   LINK_LO, x             ; CALL ts_tbl_next: row
    ld   ts_tl_2, [x]
    ld   LINK_HI, x
    ld   ts_tl_2 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_tl_2:
    ld   ac, [CUR_ROW]
    ld   LINK_LO, x             ; CALL ts_tbl_next: attribute
    ld   ts_tl_3, [x]
    ld   LINK_HI, x
    ld   ts_tl_3 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_tl_3:
    ld   ac, [s_attr]
    ld   LINK_LO, x             ; CALL ts_tbl_next: string low
    ld   ts_tl_4, [x]
    ld   LINK_HI, x
    ld   ts_tl_4 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_tl_4:
    ld   ac, [R0]
    ld   LINK_LO, x             ; CALL ts_tbl_next: string high
    ld   ts_tl_5, [x]
    ld   LINK_HI, x
    ld   ts_tl_5 >> 8, [x]
    ld   ts_tbl_next >> 8, y
    jmp  ts_tbl_next
ts_tl_5:
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL ts_put_str
    ld   ts_tl_ent, [x]
    ld   LINK_HI, x
    ld   ts_tl_ent >> 8, [x]
    ld   ts_put_str >> 8, y
    jmp  ts_put_str
ts_tl_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_put_str - print string R1:R0 (ending in 00) at the cursor, each
;   character ORed with s_attr
;   changes: AC, X, Y, R0, R1, T0-T5
; ---------------------------------------------------------------------------
#addr 0x7300
ts_put_str:
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
ts_ps_ch:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    beq  ts_ps_done
    or   [s_attr], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   ts_ps_1, [x]
    ld   LINK_HI, x
    ld   ts_ps_1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ts_ps_1:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  ts_ps_ch
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  ts_ps_ch
ts_ps_done:
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_put_range - print pr_n characters at the cursor, starting with AC,
;   adding pr_inc each time (0 repeats the character), each ORed with s_attr
;   changes: AC, X, Y, T0-T5, pr_c, pr_n
; ---------------------------------------------------------------------------
ts_put_range:
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
    ld   ac, [pr_c]
ts_pr_ch:
    ld   [pr_c], ac
    or   [s_attr], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   ts_pr_1, [x]
    ld   LINK_HI, x
    ld   ts_pr_1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ts_pr_1:
    ld   [pr_c], ac
    add  [pr_inc], ac
    ld   ac, [pr_c]
    ld   [pr_n], ac
    dec
    ld   ac, [pr_n]
    bne  ts_pr_ch
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_print_zp - print pz_n characters from the zero page, from R0 on
;   changes: AC, X, Y, R0, T0-T5, pz_n
; ---------------------------------------------------------------------------
#addr 0x7400
ts_print_zp:
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
ts_pz_ch:
    ld   [R0], x
    ld   [x], ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   ts_pz_1, [x]
    ld   LINK_HI, x
    ld   ts_pz_1 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ts_pz_1:
    ld   [R0], ac
    inc
    ld   ac, [R0]
    ld   [pz_n], ac
    dec
    ld   ac, [pz_n]
    bne  ts_pz_ch
    ld   lib_leave >> 8, y      ; LEAVE
    jmp  lib_leave

; ---------------------------------------------------------------------------
; ts_tbl_next - AC = the byte at tp_hi:tp_lo, and move the pointer on
;   (a leaf routine; changes X, Y, tb_v)
; ---------------------------------------------------------------------------
ts_tbl_next:
    ld   [tp_hi], y
    ld   [tp_lo], x
    ld   [y,x], ac
    ld   ac, [tb_v]
    ld   [tp_lo], ac
    inc
    ld   ac, [tp_lo]
    bne  ts_tn_1
    ld   [tp_hi], ac
    inc
    ld   ac, [tp_hi]
ts_tn_1:
    ld   [tb_v], ac
    ld   [LINK_HI], y           ; RETURN
    jmp  [LINK_LO]

; ===========================================================================
; text
; ===========================================================================
#addr 0x8000
; 80 column text: column, row, attribute, string
text_a:
    #d8 0, 0, 0x80, s_title & 0xFF, s_title >> 8
    #d8 17, 3, 0, s_fox & 0xFF, s_fox >> 8
    #d8 0, 6, 0, s_cpu & 0xFF, s_cpu >> 8
    #d8 30, 6, 0, s_up & 0xFF, s_up >> 8
    #d8 52, 6, 0, s_frm & 0xFF, s_frm >> 8
    #d8 0, 7, 0, s_ram & 0xFF, s_ram >> 8
    #d8 32, 7, 0, s_addr & 0xFF, s_addr >> 8
    #d8 42, 7, 0, s_pass & 0xFF, s_pass >> 8
    #d8 56, 7, 0, s_err & 0xFF, s_err >> 8
    #d8 0, 8, 0, s_prog & 0xFF, s_prog >> 8
    #d8 58, 8, 0, s_close & 0xFF, s_close >> 8
    #d8 0, 10, 0, s_ruler & 0xFF, s_ruler >> 8
    #d8 0, 11, 0x80, s_legend & 0xFF, s_legend >> 8
    #d8 0xFF

s_title:
    #d " PLACARD COMPUTER  -  VIDEO TEST SCREEN             80 COLUMNS  1 BPP  1X LINES ", 0x00
s_fox:
    #d "The quick brown fox jumps over the lazy dog.  0123456789", 0x00
s_cpu:
    #d "CPU TEST    [ ]  RUNNING", 0x00
s_up:
    #d "UPTIME 00:00:00", 0x00
s_frm:
    #d "FRAME 00000", 0x00
s_ram:
    #d "RAM TEST    0100-1FFF 4000-4FFF", 0x00
s_addr:
    #d "PAGE 0100", 0x00
s_pass:
    #d "PASS 0", 0x00
s_err:
    #d "ERRORS 0", 0x00
s_prog:
    #d "PROGRESS  [", 0x00
s_close:
    #d "]", 0x00
s_ruler:
    #d "....:....1....:....2....:....3....:....4....:....5....:....6....:....7....:....8", 0x00
s_legend:
    #d " BELOW: 16 COLORS  4 BPP  4X  |  40 COLUMNS  2 BPP  2X  |  256 COLORS  8 BPP  4X", 0x00

; 40 column text: column, row, fg XOR bg, bg, string
text_c:
    #d8 0, 0, 0xAA, 0x55, s_c0 & 0xFF, s_c0 >> 8
    #d8 1, 2, 0xAA, 0x00, s_c2 & 0xFF, s_c2 >> 8
    #d8 1, 3, 0xFF, 0x00, s_c3 & 0xFF, s_c3 >> 8
    #d8 1, 5, 0xAA, 0x55, s_blue & 0xFF, s_blue >> 8
    #d8 8, 5, 0xAA, 0xAA, s_gold & 0xFF, s_gold >> 8
    #d8 15, 5, 0xFF, 0xFF, s_white & 0xFF, s_white >> 8
    #d8 24, 5, 0x55, 0x00, s_res & 0xFF, s_res >> 8
    #d8 0xFF

s_c0:
    #d " 40 COLUMNS  4 COLORS  2X LINES         ", 0x00
s_c2:
    #d "The quick brown fox jumps over the lazy", 0x00
s_c3:
    #d "dog.  0123456789  !?#$%&*+-=<>()[]{}", 0x00
s_blue:
    #d " BLUE ", 0x00
s_gold:
    #d " GOLD ", 0x00
s_white:
    #d " WHITE ", 0x00
s_res:
    #d "320 X 240 PIXELS", 0x00

s_16col:
    #d "16 COLORS", 0x00

msg:
    #d "*** PLACARD: AN 8-BIT COMPUTER BUILT FROM ATF22V10C PLDS    "
    #d "*** THIS SCREEN IS DRAWN BY THE CPU IN ASSEMBLY    "
    #d "*** LINE REPEAT: 1X, 2X AND 4X ROWS SAVE VIDEO RAM    ", 0x00

; ===========================================================================
; small tables (one page, TBL)
; ===========================================================================
#addr TBL
SPIN:                           ; text spinner | / - \
    #d8 0x7C, 0x2F, 0x2D, 0x5C
#addr TBL + 0x08
TAIL:                           ; wheel: white head, yellow, bright red,
    #d8 0xFF, 0xEE, 0xCC, 0x44, 0x88, 0x88, 0x88, 0x88  ; red, dark gray
#addr TBL + 0x10
DOTC:                           ; wheel dot byte columns, clockwise from 3:00
    #d8 74, 73, 69, 65, 64, 65, 69, 73
#addr TBL + 0x18
DOTR:                           ; wheel dot rows, 96 + 4 * block row
    #d8 96 + 4 * 14, 96 + 4 * 21, 96 + 4 * 24, 96 + 4 * 21
    #d8 96 + 4 * 14, 96 + 4 * 7, 96 + 4 * 4, 96 + 4 * 7
#addr TBL + CLK
CLKLIM:                         ; uptime digit limits: h h : m m : s s
    #d8 0x3A, 0x3A, 0x36, 0x3A, 0x36, 0x3A
#addr TBL + 0x40
RAINBOW:                        ; "16 COLORS"
    #d8 0xCC, 0xEE, 0x00, 0xAA, 0xBB, 0x99, 0xDD, 0xCC, 0xEE
#addr TBL + 0x50
PAGES:                          ; RAM test pages: x01-x1E, x40-x4F
    #d8 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08
    #d8 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
    #d8 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18
    #d8 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E
    #d8 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47
    #d8 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F
#addr TBL + 0x80
PAT_AM:                         ; RAM test patterns: address mask
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    #d8 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF
#addr TBL + 0x90
PAT_P:                          ;   value
    #d8 0x00, 0xFF, 0x55, 0xAA, 0x01, 0x02, 0x04, 0x08
    #d8 0x10, 0x20, 0x40, 0x80, 0x00, 0xFF
#addr TBL + 0xA0
COLPART:                        ; 256 grid: column -> B2 R3 R2 R1
    #d8 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07
    #d8 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
#addr TBL + 0xB0
ROWPART:                        ;   row -> G3 G2 G1 B3
    #d8 0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0
    #d8 0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0

#include "test_screen_tables.asm"
