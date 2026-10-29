@echo off
rem Build raycast_tex.asm (the textured ray casting demo) into the FPGA and load it on the board.
rem Run "raycast_tex noasm" to skip assembly and use the existing raycast_tex.hex.
rem Date: 10/24/2026
call "%~dp0build_and_load.bat" raycast_tex %*
if errorlevel 1 pause
