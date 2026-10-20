@echo off
rem Build text_demo.asm (the text and color demo drawn by the CPU) into the FPGA and load it on the board.
rem Run "text_demo noasm" to skip assembly and use the existing text_demo.hex.
rem Date: 10/20/2026
call "%~dp0build_and_load.bat" text_demo %*
if errorlevel 1 pause
