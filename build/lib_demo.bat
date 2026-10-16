@echo off
rem Build lib_demo.asm (the placard_lib.asm example) into the FPGA and load it on the board.
rem Run "lib_demo noasm" to skip assembly and use the existing lib_demo.hex.
rem Date: 10/16/2026
call "%~dp0build_and_load.bat" lib_demo %*
if errorlevel 1 pause
