# Schematics

This folder holds drawings of the Placard schematic for reading without
KiCad: exported PDFs of the real schematic, and the reference PNGs below.

The real schematic and the PCB layout are the KiCad project in
[`../kicad/`](../kicad/).

## Reference drawings

These PNGs are sketches drawn by Python scripts, not the real schematic.  They
were made before the KiCad schematic was started and show the intended wiring.

| File | Made by | Shown in |
|------|---------|----------|
| `placard_io_schematic.png` | `src/scripts/gen_io_schematic.py` | [docs/IO.md](../docs/IO.md#schematic) |
| `placard_audio_schematic.png` | `src/scripts/gen_audio_schematic.py` | [docs/SOUND.md](../docs/SOUND.md#schematic) |

Rerun a script (it needs matplotlib) to redraw its PNG here.
