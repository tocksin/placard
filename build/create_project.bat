@echo off
rem ===========================================================================
rem create_project.bat  [force]
rem
rem Makes the Vivado project project\placard.xpr from the sources in src\
rem (tcl\create_project.tcl).  The project folder is not kept in git, so run
rem this once after cloning before opening the project in the Vivado GUI.
rem build_and_load.bat makes the project by itself if it is missing.
rem
rem   force   delete the existing project and make it again (for example
rem           after a source file was added to or removed from
rem           create_project.tcl)
rem
rem Plays a sound when it finishes (ding.bat; set PLACARD_QUIET=1 for none).
rem
rem Date: 10/26/2026
rem ===========================================================================
setlocal EnableExtensions

set "BUILD_DIR=%~dp0"
for %%I in ("%BUILD_DIR%..") do set "REPO_DIR=%%~fI"
set "TCL_DIR=%BUILD_DIR%tcl\"
set "FORCE="
if /i "%~1"=="force" set "FORCE=force"

if exist "%REPO_DIR%\project\placard.xpr" if not defined FORCE (
    echo create_project: project\placard.xpr already exists, use "create_project.bat force" to make it again
    goto failed
)

call "%BUILD_DIR%find_vivado.bat" || goto failed
echo create_project: using %VIVADO%

set "LOG_DIR=%BUILD_DIR%logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
pushd "%LOG_DIR%"
call "%VIVADO%" -mode batch -nojournal -log "create_project_vivado.log" ^
    -source "%TCL_DIR%create_project.tcl" -tclargs %FORCE%
set "RESULT=%errorlevel%"
popd

if not "%RESULT%"=="0" (
    echo.
    echo create_project: FAILED, see %LOG_DIR%\create_project_vivado.log
    goto failed
)
echo.
echo create_project: made %REPO_DIR%\project\placard.xpr
call "%BUILD_DIR%ding.bat" ok
exit /b 0

:failed
call "%BUILD_DIR%ding.bat" fail
pause
exit /b 1
