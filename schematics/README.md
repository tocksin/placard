# Schematics

This folder holds the Placard schematic: the EDA project files for the real
schematic, plus exported PDFs/PNGs for reading without the tool.

The PCB layout lives in [`../pcb/`](../pcb/).  Part numbers and U-numbers come
from [docs/CHIPS.md](../docs/CHIPS.md); the PLD pinouts come from the `.pld`
files in `src/`.

## Reference drawings

These PNGs are sketches drawn by Python scripts, not the real schematic.  They
were made before the schematic capture started and show the intended wiring.

| File | Made by | Shown in |
|------|---------|----------|
| `placard_io_schematic.png` | `src/scripts/gen_io_schematic.py` | [docs/IO.md](../docs/IO.md#schematic) |
| `placard_audio_schematic.png` | `src/scripts/gen_audio_schematic.py` | [docs/SOUND.md](../docs/SOUND.md#schematic) |

Rerun a script (it needs matplotlib) to redraw its PNG here.
