@echo off
rem PLACARD router v4 benchmark: 108 mux-region nets on r1.kicad_pcb (a copy of the main board with those nets stripped)
rem pipeline: mroute4 -> tidy (with pair pass) -> corner45 -> score.  set BACKEND=cpu to compare with the GPU.
cd /d %~dp0
if "%BACKEND%"=="" set BACKEND=gpu
if "%TAG%"=="" set TAG=%BACKEND%
if not exist r1.kicad_pcb powershell -command "Expand-Archive -Path bench\r1.kicad_pcb.zip -DestinationPath ."
set OUT=bench_%TAG%.kicad_pcb
echo backend %BACKEND% tag %TAG%
python mroute4.py r1.kicad_pcb %OUT% > bench_%TAG%.log 2>&1
type bench_%TAG%.log
set NETS=@%OUT%.nets
python score.py %OUT% > bench_%TAG%.score 2>&1
python tidy.py %OUT% bench_%TAG%_tidy.kicad_pcb > bench_%TAG%_tidy.log 2>&1
python corner45.py bench_%TAG%_tidy.kicad_pcb bench_%TAG%_c45.kicad_pcb >> bench_%TAG%_tidy.log 2>&1
python score.py bench_%TAG%_c45.kicad_pcb > bench_%TAG%_tidy.score 2>&1
type bench_%TAG%_tidy.score
