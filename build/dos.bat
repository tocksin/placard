@echo off
rem Build the DOS (the 32K ROM image, docs/DOS.md and docs/ROM.md "The 32K
rem image") into the FPGA and load it on the board.  src\scripts\dos.asm is
rem assembled like any program (build_and_load); gen_rom.tcl sees its boot
rem mode byte (02) and makes the 32K image in both halves of rom.mem, and
rem writes src\hdl\rom_32k.bin, the file to program into the EEPROM(s).
rem "dos fast" only updates the memory (see build_and_load).
rem The programs come from the SD card: copy the sdcard\ folder of the
rem repository onto a FAT16 or FAT32 card (BOOT.CFG names the program that
rem runs at power-up; hold Esc for the file browser).
rem dos.asm is made from dos.masm by  python asm_expand.py dos.masm  (both are
rem in the repository, so no Python is needed to build).
rem Date: 10/26/2026
call "%~dp0build_and_load.bat" dos %*
if errorlevel 1 pause
