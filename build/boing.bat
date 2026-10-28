@echo off
rem Build boing_rom.asm (the Boing Ball demo as a 64K development image, a ROM
rem build for testing without the SD card) into the FPGA and load it on the
rem board.  The stub copies the program to RAM x0100 and runs it as the DOS
rem would.  Run "boing noasm" to use the existing boing_rom.hex.
rem gen_boing.py makes boing_rom.asm (it is in the repository, so no Python is
rem needed to build).
rem Date: 10/28/2026
call "%~dp0build_and_load.bat" boing_rom %*
if errorlevel 1 pause
