@echo off
rem PLACARD router v4 whole-board bench on the fine 0.0625 mm grid (rounds 4-5): same pipeline as run_wb.bat with GRID=0.0625
rem and via costs doubled in cells (same mm): router VIA=240; the first tidy is already the ladder's first rung (VIA=400,
rem AGAINST=2), then LADDER=800 1600 (LADDER=none skips). STAGE=route stops after the router + score; STAGE=tidy skips the
rem router (tidy + ladder on an existing %TAG%.kicad_pcb). WORKERS=N (tidy worker processes, default min(cpus,8)).
cd /d %~dp0
if "%BACKEND%"=="" set BACKEND=gpu
if "%TAG%"=="" set TAG=wbf_%BACKEND%
if not exist wb.kicad_pcb powershell -command "Expand-Archive -Path bench\wb.kicad_pcb.zip -DestinationPath ."
set GRID=0.0625
set OUT=%TAG%.kicad_pcb
echo backend %BACKEND% tag %TAG% grid %GRID%
if "%STAGE%"=="tidy" goto tidy
set VIA=240
python mroute4.py wb.kicad_pcb %OUT% > %TAG%.log 2>&1
type %TAG%.log
set NETS=@%OUT%.nets
python score.py %OUT% > %TAG%.score 2>&1
type %TAG%.score
if "%STAGE%"=="route" goto :eof
:tidy
set NETS=@%OUT%.nets
set VIA=400
set AGAINST=2
python tidy.py %OUT% %TAG%_tidy.kicad_pcb > %TAG%_tidy.log 2>&1
python corner45.py %TAG%_tidy.kicad_pcb %TAG%_c45.kicad_pcb >> %TAG%_tidy.log 2>&1
python score.py %TAG%_c45.kicad_pcb > %TAG%_tidy.score 2>&1
type %TAG%_tidy.score
if "%KIPY%"=="" set KIPY=C:\Program Files\KiCad\9.0\bin\python.exe
if not "%SNAP%"=="none" "%KIPY%" snapends.py %TAG%_c45.kicad_pcb %TAG%_c45_snap.kicad_pcb >> %TAG%_tidy.log 2>&1
if "%LADDER%"=="" set LADDER=800 1600
if "%LADDER%"=="none" goto :eof
setlocal enabledelayedexpansion
set PREV=%TAG%_tidy.kicad_pcb
for %%v in (%LADDER%) do (
  set VIA=%%v
  python tidy.py !PREV! %TAG%_v%%v.kicad_pcb > %TAG%_v%%v_tidy.log 2>&1
  python corner45.py %TAG%_v%%v.kicad_pcb %TAG%_v%%v_c45.kicad_pcb >> %TAG%_v%%v_tidy.log 2>&1
  python score.py %TAG%_v%%v_c45.kicad_pcb > %TAG%_v%%v.score 2>&1
  type %TAG%_v%%v.score
  if not "%SNAP%"=="none" "%KIPY%" snapends.py %TAG%_v%%v_c45.kicad_pcb %TAG%_v%%v_c45_snap.kicad_pcb >> %TAG%_v%%v_tidy.log 2>&1
  set PREV=%TAG%_v%%v.kicad_pcb
)
endlocal
