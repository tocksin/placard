@echo off
rem Build the menu ROM (all the demos with a menu, docs/MENU.md) into the FPGA
rem and load it on the board.  gen_menu_rom.py assembles the programs from their
rem .asm files and writes menu.hex, the whole ROM; "menu noasm" uses the
rem existing menu.hex.  "menu fast" only updates the memory (see build_and_load).
rem Date: 10/20/2026
setlocal
set "NOASM="
for %%A in (%*) do if /i "%%~A"=="noasm" set "NOASM=1"
if not defined NOASM (
    pushd "%~dp0..\src\scripts"
    python gen_menu_rom.py || py -3 gen_menu_rom.py || (popd & echo menu: gen_menu_rom.py failed & pause & exit /b 1)
    popd
)
set "OPTS="
for %%A in (%*) do if /i "%%~A"=="fast" set "OPTS=fast"
call "%~dp0build_and_load.bat" menu noasm %OPTS%
if errorlevel 1 pause
