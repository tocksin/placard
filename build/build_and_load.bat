@echo off
rem ===========================================================================
rem build_and_load.bat  <program> [noasm] [fast]
rem
rem Builds one assembly program into the FPGA and loads it on the board:
rem   1. assembles src\scripts\<program>.asm into <program>.hex, and the ROM's
rem      boot loader and library (rom_boot.asm, rom_lib.asm)
rem      (customasm if it is on the PATH, otherwise placard_sim.py with
rem      Python; if neither is found the existing .hex files are used)
rem   2. makes src\hdl\ram.mem and cart_ram.mem (gen_random_ram.tcl, random
rem      bytes like a real SRAM at power-up) and src\hdl\rom.mem (gen_rom.tcl:
rem      the cartridge EEPROM image, boot loader, library and the program, see
rem      docs/ROM.md)
rem   3. runs Vivado in batch mode: synthesis, implementation, bitstream
rem   4. programs the Basys 3 through the local hw_server
rem
rem Examples:  build_and_load.bat cpu_test
rem            build_and_load.bat cpu_test noasm    skip step 1, use the existing
rem                                                 src\scripts\cpu_test.hex
rem            build_and_load.bat cpu_test fast     skip step 3: put the new memory
rem                                                 image into the last bitstream
rem
rem fast only changes the RAM, cartridge SRAM and ROM contents.  It needs one full build first, and a
rem full build again after any HDL or constraint change.  It writes
rem impl_1\basys_top_fast.bit and leaves basys_top.bit as built (see
rem tcl\update_mem.tcl and tcl\write_mmi.tcl).
rem
rem Vivado is found on the PATH, else under C:\AMDDesignTools or C:\Xilinx
rem (newest version).  Set VIVADO to the full path of vivado.bat to override.
rem
rem Date: 10/21/2026
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

if "%~1"=="" (
    echo usage: %~nx0 ^<program^> [noasm] [fast]    e.g. %~nx0 cpu_test fast
    exit /b 1
)

set "PROG=%~n1"
set "BUILD_DIR=%~dp0"
for %%I in ("%BUILD_DIR%..") do set "REPO_DIR=%%~fI"
set "TCL_DIR=%BUILD_DIR%tcl\"
set "NOASM="
set "FAST="
:nextOpt
shift
if "%~1"=="" goto optsDone
set "OPT=%~1"
if "%OPT:~0,1%"=="-" set "OPT=%OPT:~1%"
if "%OPT:~0,1%"=="/" set "OPT=%OPT:~1%"
if /i "%OPT%"=="noasm" ( set "NOASM=1" & goto nextOpt )
if /i "%OPT%"=="fast" ( set "FAST=1" & goto nextOpt )
echo build_and_load: unknown option %~1, the options are noasm and fast
exit /b 1
:optsDone
set "OPTS_ON="
if defined NOASM set "OPTS_ON=!OPTS_ON! noasm"
if defined FAST set "OPTS_ON=!OPTS_ON! fast"
if not defined OPTS_ON set "OPTS_ON= none"
echo build_and_load: program %PROG%, options:!OPTS_ON!
if defined NOASM (echo   noasm  on : use the existing %PROG%.hex, skip the assembler) else (echo   noasm  off: assemble %PROG%.asm)
if defined FAST (echo   fast   on : update the memory in the last bitstream, no synthesis or implementation) else (echo   fast   off: full synthesis, implementation and bitstream)
echo.
set "SCRIPTS_DIR=%REPO_DIR%\src\scripts"
set "ASM_FILE=%SCRIPTS_DIR%\%PROG%.asm"
set "HEX_FILE=%SCRIPTS_DIR%\%PROG%.hex"

if not exist "%ASM_FILE%" if not exist "%HEX_FILE%" (
    echo build_and_load: neither %ASM_FILE% nor %HEX_FILE% exists
    exit /b 1
)

rem ---- 1. assemble -----------------------------------------------------------
if defined NOASM echo build_and_load: noasm, using existing %PROG%.hex
if not defined NOASM (
    for %%P in (rom_boot rom_lib %PROG%) do (
        if exist "%SCRIPTS_DIR%\%%P.asm" (
            call :assemble %%P || exit /b 1
        )
    )
)
if not exist "%HEX_FILE%" (
    echo build_and_load: %HEX_FILE% not found
    exit /b 1
)

rem ---- find Vivado -------------------------------------------------------------
call "%BUILD_DIR%find_vivado.bat" || exit /b 1
echo build_and_load: using %VIVADO%

rem ---- 2..4. memory image, build, program ---------------------------------------
set "JOBS=%NUMBER_OF_PROCESSORS%"
if not defined JOBS set "JOBS=4"
set "LOG_DIR=%BUILD_DIR%logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

if defined FAST goto fastPath

pushd "%LOG_DIR%"
call "%VIVADO%" -mode batch -nojournal -log "%PROG%_vivado.log" ^
    -source "%TCL_DIR%build_and_load.tcl" -tclargs "%HEX_FILE%" %JOBS%
set "RESULT=%errorlevel%"
popd

if not "%RESULT%"=="0" (
    echo.
    echo build_and_load: FAILED for %PROG%, see %LOG_DIR%\%PROG%_vivado.log
    exit /b %RESULT%
)
echo.
echo build_and_load: %PROG% built and loaded on the board
exit /b 0

rem ---- assemble one program: call :assemble <name> -----------------------------
:assemble
pushd "%SCRIPTS_DIR%"
where customasm >nul 2>&1
if !errorlevel! equ 0 (
    echo build_and_load: customasm %~1.asm
    customasm "%~1.asm" -f hexstr -o "%~1.hex"
    if !errorlevel! neq 0 ( popd & echo build_and_load: assembly of %~1 failed & exit /b 1 )
) else (
    set "PYTHON="
    where python >nul 2>&1 && set "PYTHON=python"
    if not defined PYTHON ( where py >nul 2>&1 && set "PYTHON=py -3" )
    if defined PYTHON (
        echo build_and_load: customasm not found, assembling %~1.asm with placard_sim.py
        !PYTHON! placard_sim.py "%~1.asm" -o "%~1.hex"
        if !errorlevel! neq 0 ( popd & echo build_and_load: assembly of %~1 failed & exit /b 1 )
    ) else (
        echo build_and_load: WARNING no customasm or Python found, using existing %~1.hex
    )
)
popd
exit /b 0

rem ---- fast: new memory images into the existing bitstream ---------------------
:fastPath
pushd "%LOG_DIR%"
call "%VIVADO%" -mode batch -nojournal -log "%PROG%_fast_vivado.log" ^
    -source "%TCL_DIR%update_mem.tcl" -tclargs "%HEX_FILE%"
set "RESULT=%errorlevel%"
popd
if not "%RESULT%"=="0" (
    echo.
    echo build_and_load: FAILED for %PROG%, see %LOG_DIR%\%PROG%_fast_vivado.log
    exit /b %RESULT%
)
echo.
echo build_and_load: %PROG% memory updated and loaded on the board (no rebuild)
exit /b 0
