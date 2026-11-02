@echo off
rem PLACARD router v4 whole-board bench: wb.kicad_pcb = Justin's finished main board with every track and via except
rem GND/+5V/CLK_E removed (bench\wb.kicad_pcb.zip, made by makebench.py; CLK_E is a deliberate 458 mm delay lead and stays his). Reference: bench\wb_reference_justin.score.
rem pipeline: mroute4 -> tidy (net + pair passes) -> corner45 -> [meander when MINLEN=NET:mm is set] -> score -> via-cost ladder (LADDER).
cd /d %~dp0
if "%BACKEND%"=="" set BACKEND=gpu
if "%TAG%"=="" set TAG=wb_%BACKEND%
if not exist wb.kicad_pcb powershell -command "Expand-Archive -Path bench\wb.kicad_pcb.zip -DestinationPath ."
set OUT=%TAG%.kicad_pcb
echo backend %BACKEND% tag %TAG%
python mroute4.py wb.kicad_pcb %OUT% > %TAG%.log 2>&1
type %TAG%.log
set NETS=@%OUT%.nets
python score.py %OUT% > %TAG%.score 2>&1
python tidy.py %OUT% %TAG%_tidy.kicad_pcb > %TAG%_tidy.log 2>&1
python corner45.py %TAG%_tidy.kicad_pcb %TAG%_c45.kicad_pcb >> %TAG%_tidy.log 2>&1
if not "%MINLEN%"=="" python meander.py %TAG%_c45.kicad_pcb %TAG%_c45m.kicad_pcb %MINLEN% >> %TAG%_tidy.log 2>&1 && copy /y %TAG%_c45m.kicad_pcb %TAG%_c45.kicad_pcb >nul
python score.py %TAG%_c45.kicad_pcb > %TAG%_tidy.score 2>&1
type %TAG%_tidy.score
rem via-cost ladder (round 4): further tidy rounds with a rising via cost trade a little track for far fewer vias
rem (wb4: 656 -> 588 -> 541 -> 524 vias for 38.96 -> 39.54 -> 39.98 -> 40.51 m). LADDER=none skips it.
if "%LADDER%"=="" set LADDER=400 800 1600
if "%LADDER%"=="none" goto :eof
setlocal enabledelayedexpansion
set PREV=%TAG%_tidy.kicad_pcb
set AGAINST=2
for %%v in (%LADDER%) do (
  set VIA=%%v
  python tidy.py !PREV! %TAG%_v%%v.kicad_pcb > %TAG%_v%%v_tidy.log 2>&1
  python corner45.py %TAG%_v%%v.kicad_pcb %TAG%_v%%v_c45.kicad_pcb >> %TAG%_v%%v_tidy.log 2>&1
  python score.py %TAG%_v%%v_c45.kicad_pcb > %TAG%_v%%v.score 2>&1
  type %TAG%_v%%v.score
  set PREV=%TAG%_v%%v.kicad_pcb
)
endlocal
