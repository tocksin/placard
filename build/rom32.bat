@echo off
rem Build the 32K ROM image (docs/ROM.md "The 32K image") into the FPGA and
rem load it on the board: the boot loader, the library, the FAT writer and
rem the loader that starts the DOS from the SD card or BASIC.
rem src\scripts\rom32.asm is assembled like any program (build_and_load);
rem gen_rom.tcl sees its boot mode byte (02) and makes the 32K image in both
rem halves of rom.mem, and writes src\hdl\rom_32k.bin, the file to program
rem into the EEPROM(s).  "rom32 fast" only updates the memory (see
rem build_and_load).
rem The DOS and the programs come from the SD card: copy the sdcard\ folder
rem of the repository onto a FAT16 or FAT32 card (DOS.PLC is the DOS;
rem BOOT.CFG names the program that runs at power-up; hold Esc for the file
rem browser).  With no card the machine starts BASIC.
rem rom32.asm is made from rom32.masm by  python asm_expand.py rom32.masm
rem (both are in the repository, so no Python is needed to build).
rem Date: 10/26/2026
call "%~dp0build_and_load.bat" rom32 %*
if errorlevel 1 pause
