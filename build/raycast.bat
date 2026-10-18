@echo off
rem Build raycast.asm (the ray casting demo) into the FPGA and load it on the board.
rem Run "raycast noasm" to skip assembly and use the existing raycast.hex.
rem Date: 10/18/2026
call "%~dp0build_and_load.bat" raycast %*
if errorlevel 1 pause
