@echo off
rem Build wire3d_rom.asm (the 3D wireframe demo as a 64K development image, a
rem temporary ROM build for testing without the SD card) into the FPGA and load
rem it on the board.  The stub copies the program to RAM x0100 and runs it as the
rem DOS would.  Run "wire3d noasm" to use the existing wire3d_rom.hex.
rem gen_wire3d.py makes wire3d_rom.asm (it is in the repository, so no Python
rem is needed to build).
rem Date: 10/28/2026
call "%~dp0build_and_load.bat" wire3d_rom %*
if errorlevel 1 pause
