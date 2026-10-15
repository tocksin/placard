@echo off
rem Build cpu_test.asm into the FPGA and load it on the board.
rem Run "cpu_test noasm" to skip assembly and use the existing cpu_test.hex.
rem Date: 10/15/2026
call "%~dp0build_and_load.bat" cpu_test %*
if errorlevel 1 pause
