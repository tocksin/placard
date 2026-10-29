@echo off
rem ===========================================================================
rem find_vivado.bat
rem
rem Sets VIVADO to the full path of vivado.bat, unless it is already set.
rem Looks on the PATH, then under C:\AMDDesignTools and C:\Xilinx (newest
rem version).  Called by build_and_load.bat and download_latest.bat; exits
rem with errorlevel 1 if Vivado is not found.
rem
rem Date: 10/15/2026
rem ===========================================================================
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
    echo Vivado not found. Add it to the PATH or set VIVADO=^<path^>\vivado.bat
    exit /b 1
)
exit /b 0
