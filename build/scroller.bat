@echo off
rem Build scroller.asm (the side-scrolling platform demo) into the FPGA and load it on the board.
rem Run "scroller noasm" to skip assembly and use the existing scroller.hex.
rem Date: 10/18/2026
call "%~dp0build_and_load.bat" scroller %*
if errorlevel 1 pause
