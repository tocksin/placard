# Schematics

This folder holds drawings of the Placard schematic for reading without
KiCad: exported PDFs of the real schematic, and the reference PNGs below.

The real schematic and the PCB layout are the KiCad project in
[`../kicad/`](../kicad/).

## Schematic PDFs

| File | What it is |
|------|------------|
| `placard_main.pdf` | the main board, 11 sheets (root and ten), exported from `kicad/placard.kicad_sch` |
| `placard_cartridge_64k.pdf` | the 64K ROM cartridge, one sheet, from `kicad/cartridge_64k/cartridge_64k.kicad_sch` |
| `placard_cartridge_32k.pdf` | the 32K ROM cartridge, one sheet, from `kicad/cartridge_32k/cartridge_32k.kicad_sch` |

Re-export both with `python3 src/scripts/gen_kicad_schematic.py --pdf`.  It
runs `kicad-cli sch export pdf` and then drops the bookmarks, so the PDFs open
without the bookmarks panel (Justin, 2026-10-21); keep it that way for any PDF
made for the project.

## Reference drawings

These PNGs are sketches drawn by Python scripts, not the real schematic.  They
were made before the KiCad schematic was started and show the intended wiring.

| File | Made by | Shown in |
|------|---------|----------|
| `placard_io_schematic.png` | `src/scripts/gen_io_schematic.py` | [docs/IO.md](../docs/IO.md#schematic) |
| `placard_audio_schematic.png` | `src/scripts/gen_audio_schematic.py` | [docs/SOUND.md](../docs/SOUND.md#schematic) |

Rerun a script (it needs matplotlib) to redraw its PNG here.  Both size their
text last, with `src/scripts/schematic_text.py`: every label starts large and
shrinks only where it would run into another label, a wire or a chip.
