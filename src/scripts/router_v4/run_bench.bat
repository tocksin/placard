@echo off
rem PLACARD router v4 benchmark: 108 mux-region nets on r1.kicad_pcb (a copy of the main board with those nets stripped)
cd /d %~dp0
if "%BACKEND%"=="" set BACKEND=gpu
if not exist r1.kicad_pcb powershell -command "Expand-Archive -Path bench\r1.kicad_pcb.zip -DestinationPath ."
set OUT=bench_%BACKEND%.kicad_pcb
echo backend %BACKEND%
python mroute4.py r1.kicad_pcb %OUT% > bench_%BACKEND%.log 2>&1
type bench_%BACKEND%.log
set NETS=@%OUT%.nets
python tidy.py %OUT% bench_%BACKEND%_tidy.kicad_pcb >> bench_%BACKEND%.log 2>&1
python score.py bench_%BACKEND%_tidy.kicad_pcb > bench_%BACKEND%.score 2>&1
type bench_%BACKEND%.score
