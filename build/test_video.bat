@echo off
rem Build test_video.asm into the FPGA and load it on the board.
rem Date: 10/15/2026
call "%~dp0build_and_load.bat" test_video
if errorlevel 1 pause
