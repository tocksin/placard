; lib_demo.asm - example program for placard_lib.asm
; Prints text and numbers with the console routines, does some arithmetic,
; draws 200 random dots with rand8 and plot1, then halts.
;
; It is a ROM program (docs/ROM.md): it runs in place from ROM x6000 and calls
; the library in place at ROM x3000; its variables are in the RAM's zero
; page.  The boot loader maps sections 0 and 2 to RAM and jumps to x6000.
;
;     python3 placard_sim.py lib_demo.asm --run --boot --png demo.png
;
; Date: 10/18/2026

#include "placard.asm"
#include "placard_lib.asm"

; program variables (zero page x20-x8F)
count   = 0x20
px_lo   = 0x21
py_r    = 0x22

#addr 0x6000
main:
    ld   STACK_TOP, ac          ; stack first
    ld   ac, [SP]
    ld   0x5E, ac               ; random seed (any value but 0)
    ld   ac, [RAND_LO]
    ld   0x1D, ac
    ld   ac, [RAND_HI]

    ld   LINK_LO, x             ; CALL con_clear
    ld   r1, [x]
    ld   LINK_HI, x
    ld   r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
r1:
    ld   title, ac              ; R1:R0 = title
    ld   ac, [R0]
    ld   title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   r2, [x]
    ld   LINK_HI, x
    ld   r2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
r2:
    ; "200 x 123 = " then mul8 -> con_dec16
    ld   s_mul, ac
    ld   ac, [R0]
    ld   s_mul >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   r3, [x]
    ld   LINK_HI, x
    ld   r3 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
r3:
    ld   200, ac
    ld   ac, [R0]
    ld   123, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL mul8: R3:R2 = R0 * R1
    ld   r4, [x]
    ld   LINK_HI, x
    ld   r4 >> 8, [x]
    ld   mul8 >> 8, y
    jmp  mul8
r4:
    ld   [R2], ac               ; con_dec16 prints R1:R0
    ld   ac, [R0]
    ld   [R3], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_dec16
    ld   r5, [x]
    ld   LINK_HI, x
    ld   r5 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
r5:
    ld   0x0A, ac
    ld   LINK_LO, x             ; CALL con_putc (newline)
    ld   r6, [x]
    ld   LINK_HI, x
    ld   r6 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
r6:
    ; a table of n, n in hex and n * n, for n = 1, 2, 4 ... 128
    ld   1, ac
    ld   ac, [count]
row:
    ld   [count], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   r7, [x]
    ld   LINK_HI, x
    ld   r7 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
r7:
    ld   8, ac                  ; tab to column 8
    ld   ac, [CUR_COL]
    ld   [count], ac
    ld   LINK_LO, x             ; CALL con_hex8
    ld   r8, [x]
    ld   LINK_HI, x
    ld   r8 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
r8:
    ld   14, ac
    ld   ac, [CUR_COL]
    ld   [count], ac
    ld   ac, [R0]
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL mul8
    ld   r9, [x]
    ld   LINK_HI, x
    ld   r9 >> 8, [x]
    ld   mul8 >> 8, y
    jmp  mul8
r9:
    ld   [R2], ac
    ld   ac, [R0]
    ld   [R3], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_dec16
    ld   r10, [x]
    ld   LINK_HI, x
    ld   r10 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
r10:
    ld   0x0A, ac
    ld   LINK_LO, x             ; CALL con_putc (newline)
    ld   r11, [x]
    ld   LINK_HI, x
    ld   r11 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
r11:
    ld   [count], ac            ; next power of 2, until it wraps to 0
    shl
    ld   ac, [count]
    bne  row_again
    ld   dots >> 8, y
    jmp  dots
row_again:
    ld   row >> 8, y
    jmp  row

#addr 0x6100
dots:
    ; 200 random dots in x 320-575, y 200-455
    clr  ac
    ld   ac, [count]
dot:
    ld   LINK_LO, x             ; CALL rand8 -> x low byte
    ld   r12, [x]
    ld   LINK_HI, x
    ld   r12 >> 8, [x]
    ld   rand8 >> 8, y
    jmp  rand8
r12:
    ld   ac, [px_lo]
    ld   LINK_LO, x             ; CALL rand8 -> y
    ld   r13, [x]
    ld   LINK_HI, x
    ld   r13 >> 8, [x]
    ld   rand8 >> 8, y
    jmp  rand8
r13:
    ld   ac, [py_r]
    add  200, ac                ; y = 200 + r, 200-455
    ld   ac, [R2]
    ld   [py_r], ac             ; high byte 1 when r >= 56 (unsigned)
    blt  y_hi
    sub  56, ac
    bcc  y_hi
    clr  ac
    ld   ac, [R3]
    bra  y_set
y_hi:
    ld   1, ac
    ld   ac, [R3]
y_set:
    ld   [px_lo], ac            ; x = 320 + r (x140 + r, 320-575)
    add  0x40, ac
    ld   ac, [R0]
    ld   [px_lo], ac            ; high byte 2 when r >= C0 (unsigned)
    sub  0xC0, ac
    bcs  x_1
    ld   2, ac
    ld   ac, [R1]
    bra  x_set
x_1:
    ld   1, ac
    ld   ac, [R1]
x_set:
    ld   1, ac
    ld   LINK_LO, x             ; CALL plot1
    ld   r14, [x]
    ld   LINK_HI, x
    ld   r14 >> 8, [x]
    ld   plot1 >> 8, y
    jmp  plot1
r14:
    ld   [count], ac
    inc
    ld   ac, [count]
    sub  200, ac
    bne  dot_again
    ld   done >> 8, y
    jmp  done
dot_again:
    ld   dot >> 8, y
    jmp  dot

#addr 0x6200
done:
    ld   s_end, ac
    ld   ac, [R0]
    ld   s_end >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   r15, [x]
    ld   LINK_HI, x
    ld   r15 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
r15:
halt:
    bra  halt

title:
    #d "PLACARD standard library demo", 0x0A, 0x0A, 0x00
s_mul:
    #d "200 x 123 = ", 0x00
s_end:
    #d 0x0A, "done.", 0x00
