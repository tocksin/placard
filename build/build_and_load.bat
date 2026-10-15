@echo off
rem ===========================================================================
rem build_and_load.bat  <program>
rem
rem Builds one assembly program into the FPGA and loads it on the board:
rem   1. assembles src\scripts\<program>.asm into <program>.hex
rem      (customasm if it is on the PATH, otherwise placard_sim.py with
rem      Python; if neither is found the existing .hex is used)
rem   2. merges the program into src\hdl\video_ram.mem (gen_video_ram.tcl)
rem   3. runs Vivado in batch mode: synthesis, implementation, bitstream
rem   4. programs the Basys 3 through the local hw_server
rem
rem Example:   build_and_load.bat cpu_test
rem
rem Vivado is found on the PATH, else under C:\AMDDesignTools or C:\Xilinx
rem (newest version).  Set VIVADO to the full path of vivado.bat to override.
rem
rem Date: 10/15/2026
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

if "%~1"=="" (
    echo usage: %~nx0 ^<program^>    e.g. %~nx0 cpu_test
    exit /b 1
)

set "PROG=%~n1"
set "BUILD_DIR=%~dp0"
for %%I in ("%BUILD_DIR%..") do set "REPO_DIR=%%~fI"
set "SCRIPTS_DIR=%REPO_DIR%\src\scripts"
set "ASM_FILE=%SCRIPTS_DIR%\%PROG%.asm"
set "HEX_FILE=%SCRIPTS_DIR%\%PROG%.hex"

if not exist "%ASM_FILE%" if not exist "%HEX_FILE%" (
    echo build_and_load: neither %ASM_FILE% nor %HEX_FILE% exists
    exit /b 1
)

rem ---- 1. assemble -----------------------------------------------------------
if exist "%ASM_FILE%" (
    pushd "%SCRIPTS_DIR%"
    where customasm >nul 2>&1
    if !errorlevel! equ 0 (
        echo build_and_load: customasm %PROG%.asm
        customasm "%PROG%.asm" -f hexstr -o "%PROG%.hex"
        if !errorlevel! neq 0 ( popd & echo build_and_load: assembly failed & exit /b 1 )
    ) else (
        set "PYTHON="
        where python >nul 2>&1 && set "PYTHON=python"
        if not defined PYTHON ( where py >nul 2>&1 && set "PYTHON=py -3" )
        if defined PYTHON (
            echo build_and_load: customasm not found, assembling with placard_sim.py
            !PYTHON! placard_sim.py "%PROG%.asm" -o "%PROG%.hex"
            if !errorlevel! neq 0 ( popd & echo build_and_load: assembly failed & exit /b 1 )
        ) else (
            echo build_and_load: WARNING no customasm or Python found, using existing %PROG%.hex
        )
    )
    popd
)
if not exist "%HEX_FILE%" (
    echo build_and_load: %HEX_FILE% not found
    exit /b 1
)

rem ---- find Vivado -------------------------------------------------------------
if not defined VIVADO (
    for /f "delims=" %%V in ('where vivado.bat 2^>nul') do if not defined VIVADO set "VIVADO=%%V"
)
if not defined VIVADO (
    for /d %%D in ("C:\AMDDesignTools\*") do if exist "%%D\Vivado\bin\vivado.bat" set "VIVADO=%%D\Vivado\bin\vivado.bat"
)
if not defined VIVADO (
    for /d %%D in ("C:\Xilinx\Vivado\*") do if exist "%%D\bin\vivado.bat" set "VIVADO=%%D\bin\vivado.bat"
)
if not defined VIVADO (
    echo build_and_load: Vivado not found. Add it to the PATH or set VIVADO=^<path^>\vivado.bat
    exit /b 1
)
echo build_and_load: using %VIVADO%

rem ---- 2..4. memory image, build, program ---------------------------------------
set "JOBS=%NUMBER_OF_PROCESSORS%"
if not defined JOBS set "JOBS=4"
set "LOG_DIR=%BUILD_DIR%logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

pushd "%LOG_DIR%"
call "%VIVADO%" -mode batch -nojournal -log "%PROG%_vivado.log" ^
    -source "%BUILD_DIR%build_and_load.tcl" -tclargs "%HEX_FILE%" %JOBS%
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
