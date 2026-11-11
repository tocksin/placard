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

The PDFs are the rev A schematic, as the boards were ordered
([docs/hardware/RELEASES.md](../docs/hardware/RELEASES.md)).  The working
sheets in `kicad/` say rev B and have no circuit change since (compared
2026-11-11), so export again when rev B changes something.

Date: 2026-11-11

Re-export all three with `python3 src/scripts/gen_kicad_schematic.py --pdf`.  It
runs `kicad-cli sch export pdf` and then drops the bookmarks, so the PDFs open
without the bookmarks panel (Justin, 2026-10-21); keep it that way for any PDF
made for the project.

## Reference drawings

| File | Made by | Shown in |
|------|---------|----------|
| `placard_io_schematic.png` | page 10 (the shared port sheet) of `placard_main.pdf`, rendered at 150 dpi (`pdftoppm -f 10 -l 10 -r 150 -png`) | [docs/architecture/IO.md](../docs/architecture/IO.md#schematic) |
| `placard_video_audio_schematic.png` | page 9 (the video and audio out sheet) of `placard_main.pdf`, rendered the same way (`-f 9 -l 9`) | [docs/sound/SOUND.md](../docs/sound/SOUND.md#schematic) |

Re-render a page after its sheet changes.  The audio sketch that was here
(drawn by `src/scripts/gen_audio_schematic.py` before the KiCad schematic
was started) is in [docs/archive/](../docs/archive/README.md).
