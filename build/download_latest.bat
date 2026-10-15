@echo off
rem ===========================================================================
rem download_latest.bat
rem
rem Programs the Basys 3 with the most recently built bitstream
rem (project\placard.runs\impl_1\basys_top.bit), whichever program it was
rem built for.  Nothing is assembled or rebuilt.
rem
rem Date: 10/15/2026
rem ===========================================================================
setlocal EnableExtensions

set "BUILD_DIR=%~dp0"
for %%I in ("%BUILD_DIR%..") do set "REPO_DIR=%%~fI"
set "BIT_FILE=%REPO_DIR%\project\placard.runs\impl_1\basys_top.bit"

if not exist "%BIT_FILE%" (
    echo download_latest: %BIT_FILE% not found, build a program first
    goto failed
)
for %%F in ("%BIT_FILE%") do echo download_latest: %%~nxF built %%~tF

call "%BUILD_DIR%find_vivado.bat" || goto failed
echo download_latest: using %VIVADO%

set "LOG_DIR=%BUILD_DIR%logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
pushd "%LOG_DIR%"
call "%VIVADO%" -mode batch -nojournal -log "download_latest_vivado.log" ^
    -source "%BUILD_DIR%program_board.tcl" -tclargs "%BIT_FILE%"
set "RESULT=%errorlevel%"
popd

if not "%RESULT%"=="0" (
    echo.
    echo download_latest: FAILED, see %LOG_DIR%\download_latest_vivado.log
    goto failed
)
echo.
echo download_latest: board programmed
exit /b 0

:failed
pause
exit /b 1
