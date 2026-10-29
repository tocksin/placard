@echo off
rem ===========================================================================
rem ding.bat  [ok|fail]
rem
rem Plays a sound when a build script finishes: the Windows "Ding" for ok
rem (the default), "Critical Stop" for fail.  The sound plays to the end
rem before the script goes on, so a following pause or exit does not cut it
rem off.  Called by build_and_load.bat, create_project.bat and
rem download_latest.bat.  Set PLACARD_QUIET=1 for no sound.
rem
rem Date: 10/26/2026
rem ===========================================================================
if defined PLACARD_QUIET exit /b 0
setlocal
set "WAV=Windows Ding.wav"
set "SYS=Asterisk"
if /i "%~1"=="fail" (
    set "WAV=Windows Critical Stop.wav"
    set "SYS=Hand"
)
powershell -NoProfile -NonInteractive -Command ^
    "$f = Join-Path $env:WINDIR 'Media\%WAV%';" ^
    "if (Test-Path $f) { (New-Object Media.SoundPlayer $f).PlaySync() }" ^
    "else { [Media.SystemSounds]::%SYS%.Play(); Start-Sleep -Milliseconds 800 }" >nul 2>&1
exit /b 0
