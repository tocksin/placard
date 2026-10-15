@echo off
rem Build game_of_life.asm into the FPGA and load it on the board.
rem Run "game_of_life noasm" to skip assembly and use the existing game_of_life.hex.
rem Date: 10/15/2026
call "%~dp0build_and_load.bat" game_of_life %*
if errorlevel 1 pause
