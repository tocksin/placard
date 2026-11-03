# SCRAPWRIGHT

`SCRAP.PLC` (`src/scripts/scrap.masm`, with `SCRAP.OVL`) is SCRAPWRIGHT,
an original top-down salvage game: you fly a small tug out to derelict
ships, walk through them in a suit, cut out what is worth having, haul it
back, and build it into your own ship.  It is not in the demo menu: pick
it in the DOS's file browser and press Enter ([DOS.md](DOS.md)), or set
`BOOT.CFG` = `SCRAP.PLC` to run it at power-up.

Date: 2026-11-03

The design (proposal, phases, mock-ups) is the SCRAPWRIGHT design doc.
This is **phase 2**: the walkable wreck with the mouse panel.  Salvage,
building, air and power, enemies and the sector map come in later phases.

![SCRAPWRIGHT in the simulator](../../reference/scrap_sim.png)

## Playing

You start in your tug's corridor, docked to the KESTREL 9.  A docking
tube from the tug's airlock leads to the wreck's airlock.

| Input | What it does |
|-------|--------------|
| Arrows, WASD, or the SNES pad | walk one cell (held: a step every 7 frames).  Walking into a closed door opens it |
| Mouse over a cell | a yellow frame on the cell, and the panel shows it: name, damage bar, info on the left, actions on the right |
| Mouse over yourself | your suit, battery, hands and pack |
| Left click on a cell | locks the panel on it, so the mouse can go down to the actions |
| Left click on an action, or keys **1-4** | does it: **OPEN** / **CLOSE** (a door next to you), **WALK HERE** (walks toward the cell), **INSPECT** (a line about it) |
| Right click | unlocks the panel |
| Esc | back to the DOS |

The camera moves one cell when you come within 4 cells of the view's
side (3 of its top or bottom) and redraws the view (no smooth scroll).  There is no arrow pointer yet: the frame on the cell, and the
inverse action row in the panel, show where the mouse is.

## The screen

- Lines 0-383: 4 bpp, 2x line repeat, 20 x 12 cells.  A cell is 8 x 16
  pixels of art (32 x 32 on the monitor), 64 bytes.
- Lines 384-479: 1 bpp, 2x, the panel (text rows 24-29, 80 columns).
  - Row 24: the name, tinted blue, and the damage bar.
  - Rows 25-28: the info on the left, the action menu after the bar on the
    right.
  - Row 29: messages, tinted gold, cleared after 4 seconds.

Every item has a damage score of 0-15 (6.25 % a step).  Its output falls
from full at 0 % to nothing at 50 %, and from step 8 (50 %) on it is
broken: the info line says `WORKS AT nn%` or `BROKEN - NEEDS REPAIR`.

## Memory

| Address | What |
|---------|------|
| x0100-x23FF | the program (asm_expand.py pages it) |
| x3600-x39FF | tables: damage bars, actions, info lines, names, flags (gen_scrap.py) |
| x3A00-x3FFF | the cell art, 4 cells a page (23 kinds now, room for 24) |
| x5400-x55FF | sector buffer for loading `SCRAP.OVL` |
| even pages x60-xBE | the map: 96 x 64 cells in 24 chunks of 16 x 16 |
| odd pages x61-xBF | the screen (2x repeat leaves the even pages free) |

Chunk k (k = 6 (y / 16) + x / 16) is page x60 + 4k (the cell types) and
x62 + 4k (the flags; the damage is bits 3-0).  `SCRAP.OVL` is those 48
pages in order (12 KB), read straight from the card.  A later phase pages
bigger maps from the card a chunk at a time.

Like the tracker, the program runs with the map at FF (every section RAM)
to reach the video RAM and its map, and calls the library through `l_*`
stubs that switch to map 07 around the call.

## Building

```
cd src\scripts
python gen_scrap.py                              scrap_types.asm, scrap_data.masm, ..\..\sdcard\SCRAP.OVL
python asm_expand.py scrap.masm                  scrap.asm
python gen_plc.py scrap.asm -o ..\..\sdcard\SCRAP.PLC
python test_scrap_sim.py --png scrap.png         SCRAP.PLC in placard_sim
```

`gen_scrap.py` holds the cell art, the item types (names, info lines,
actions, inspect text) and the map generator.  `test_scrap_sim.py` boots
the card in `placard_sim.py` with a PS/2 mouse and checks:

- the map is loaded;
- all 240 view cells against the map and the art;
- the panel;
- walking and walls;
- the mouse frame, lock and unlock;
- CLOSE / OPEN / INSPECT from the keys;
- a bump opening a door;
- the camera step;
- Esc back to the DOS.
