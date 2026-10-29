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

| File | Made by | Shown in |
|------|---------|----------|
| `placard_io_schematic.png` | page 10 (the shared port sheet) of `placard_main.pdf`, rendered at 150 dpi (`pdftoppm -f 10 -l 10 -r 150 -png`) | [docs/IO.md](../docs/IO.md#schematic) |
| `placard_audio_schematic.png` | `src/scripts/gen_audio_schematic.py`, a sketch drawn before the KiCad schematic was started | [docs/SOUND.md](../docs/SOUND.md#schematic) |

Re-render the I/O page after the shared port sheet changes.  The audio
sketch's script (it needs matplotlib) sizes its text last, with
`src/scripts/schematic_text.py`: every label starts large and shrinks only
where it would run into another label, a wire or a chip.  (The hand-drawn
I/O sketch and `gen_io_schematic.py` went on 2026-10-25, when the shared
port was redrawn around the port PLD and the PS/2 receiver.)
