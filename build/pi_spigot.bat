@echo off
rem Build pi_spigot.asm into the FPGA and load it on the board.
rem Run "pi_spigot noasm" to skip assembly and use the existing pi_spigot.hex.
rem Date: 10/15/2026
call "%~dp0build_and_load.bat" pi_spigot %*
if errorlevel 1 pause
