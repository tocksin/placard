@echo off
rem Build io_demo.asm (the keyboard, pad and SD card demo) into the FPGA and load it on the board.
rem Run "io_demo noasm" to skip assembly and use the existing io_demo.hex.
rem Date: 10/18/2026
call "%~dp0build_and_load.bat" io_demo %*
if errorlevel 1 pause
