@echo off
rem PLACARD router v4 whole-board bench on the fine 0.0625 mm grid (round 4): same pipeline as run_wb.bat with GRID=0.0625
rem and via costs doubled in cells (same mm): router VIA=240, tidy VIA=400.
cd /d %~dp0
if "%BACKEND%"=="" set BACKEND=gpu
if "%TAG%"=="" set TAG=wbf_%BACKEND%
if not exist wb.kicad_pcb powershell -command "Expand-Archive -Path bench\wb.kicad_pcb.zip -DestinationPath ."
set GRID=0.0625
set OUT=%TAG%.kicad_pcb
echo backend %BACKEND% tag %TAG% grid %GRID%
set VIA=240
python mroute4.py wb.kicad_pcb %OUT% > %TAG%.log 2>&1
type %TAG%.log
set NETS=@%OUT%.nets
python score.py %OUT% > %TAG%.score 2>&1
set VIA=400
python tidy.py %OUT% %TAG%_tidy.kicad_pcb > %TAG%_tidy.log 2>&1
python corner45.py %TAG%_tidy.kicad_pcb %TAG%_c45.kicad_pcb >> %TAG%_tidy.log 2>&1
python score.py %TAG%_c45.kicad_pcb > %TAG%_tidy.score 2>&1
type %TAG%_tidy.score
