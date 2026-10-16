; Placard video test: write a binary-count pattern down the left edge of
; the screen.  Runs from ROM at PC = 0000.
;
; Video RAM layout: address = 0x6020 + byte_column * 512 + screen_row, and
; byte column 0 is the first column of pixel data (each row's mode byte is
; read in horizontal blanking from 0x4A20 + row, so it takes no column).
; Row r of column 0 is 0x6020 + r.  Writing 0x20..0xFF to 0x6020..0x60FF
; puts the counter value in the leftmost 8 pixels of rows 0..223.
;
; Web version: paste placard.asm above this code and delete the #include.
; Command line:  customasm test_video.asm -f hexstr -o test_video.hex
; then run gen_video_ram.tcl, which merges the code in at address 0000.

#include "placard.asm"

start:
    ld   0x60, y        ; Y = high byte of 0x6020 (column 0, row 0)
    ld   0x20, ac       ; AC = 0x20: first row offset and first pattern byte
loop:
    ld   ac, x          ; X = low address byte
    ld   ac, [y,x]      ; write pattern byte to [Y,X]
    inc                 ; next row / next pattern value
    bne  loop           ; repeat until AC wraps to 0 after 0xFF
done:
    bra  done           ; halt
