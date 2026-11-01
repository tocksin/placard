@echo off
rem PLACARD router v4 whole-board bench: wb.kicad_pcb = Justin's finished main board with every track and via except
rem GND/+5V/CLK_E removed (bench\wb.kicad_pcb.zip, made by makebench.py; CLK_E is a deliberate 458 mm delay lead and stays his). Reference: bench\wb_reference_justin.score.
rem pipeline: mroute4 -> tidy (pair pass) -> corner45 -> score.
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
python score.py %TAG%_c45.kicad_pcb > %TAG%_tidy.score 2>&1
type %TAG%_tidy.score
