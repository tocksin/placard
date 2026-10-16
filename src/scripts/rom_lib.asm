; rom_lib.asm - the standard library and font by themselves, for the ROM
;
; Assembles placard_lib.asm (and its font) with no program, so gen_rom.tcl
; can put them in every ROM image at their standard place: LIB_CODE x3000
; and LIB_FONT x3800 in the RAM, stored at ROM x9000-x9FFF (see ROM.md).
; A program that includes placard_lib.asm assembles the same bytes there.
;
;     customasm rom_lib.asm -f hexstr -o rom_lib.hex
;     python3 placard_sim.py rom_lib.asm
;
; Date: 10/16/2026

#include "placard.asm"
#include "placard_lib.asm"
