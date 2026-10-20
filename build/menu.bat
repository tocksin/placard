@echo off
rem Build the menu ROM (all the demos with a menu, docs/MENU.md) into the FPGA
rem and load it on the board.  gen_menu_rom.py assembles the programs from their
rem .asm files and writes menu.hex, the whole ROM.  "menu noasm" (or -noasm)
rem uses the menu.hex in the repository; so does a PC without Python, with a
rem warning.  "menu fast" only updates the memory (see build_and_load).
rem Date: 10/20/2026
setlocal EnableExtensions
set "NOASM="
set "OPTS="
for %%A in (%*) do (
    for %%O in (noasm -noasm /noasm) do if /i "%%~A"=="%%O" set "NOASM=1"
    for %%O in (fast -fast /fast) do if /i "%%~A"=="%%O" set "OPTS=fast"
)
if defined NOASM goto build
set "PYTHON="
python -c "import sys" >nul 2>&1 && set "PYTHON=python"
if not defined PYTHON ( py -3 -c "import sys" >nul 2>&1 && set "PYTHON=py -3" )
if not defined PYTHON (
    echo menu: WARNING Python not found, using the existing src\scripts\menu.hex
    goto build
)
pushd "%~dp0..\src\scripts"
%PYTHON% gen_menu_rom.py
if errorlevel 1 ( popd & echo menu: gen_menu_rom.py failed & pause & exit /b 1 )
popd
:build
call "%~dp0build_and_load.bat" menu noasm %OPTS%
if errorlevel 1 pause
