# Schematics

This folder holds drawings of the Placard schematic for reading without
KiCad: exported PDFs of the real schematic, and the reference PNGs below.

The real schematic and the PCB layout are the KiCad project in
[`../kicad/`](../kicad/).

## Schematic PDFs

| File | What it is |
|------|------------|
| `placard_main.pdf` | the main board, 11 sheets (root and ten), exported from `kicad/placard.kicad_sch` |
| `placard_cartridge.pdf` | the ROM cartridge, one sheet, from `kicad/cartridge/cartridge.kicad_sch` |

Re-export after rerunning `src/scripts/gen_kicad_schematic.py`:
`kicad-cli sch export pdf -o schematics/placard_main.pdf kicad/placard.kicad_sch`
(and the same for the cartridge).

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
