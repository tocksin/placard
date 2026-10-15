@echo off
rem Build cpu_test.asm into the FPGA and load it on the board.
rem Date: 10/15/2026
call "%~dp0build_and_load.bat" cpu_test
if errorlevel 1 pause
