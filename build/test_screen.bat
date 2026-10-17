@echo off
rem Build test_screen.asm (the video test screen drawn by the CPU) into the FPGA and load it on the board.
rem Run "test_screen noasm" to skip assembly and use the existing test_screen.hex.
rem Date: 10/17/2026
call "%~dp0build_and_load.bat" test_screen %*
if errorlevel 1 pause
