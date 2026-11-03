# SCRAPWRIGHT

`SCRAP.PLC` (`src/scripts/scrap.masm`, with `SCRAP.OVL`) is SCRAPWRIGHT,
an original top-down salvage game: you fly a small tug out to derelict
ships, walk through them in a suit, cut out what is worth having, haul it
back, and build it into your own ship.  It is not in the demo menu: pick
it in the DOS's file browser and press Enter ([DOS.md](DOS.md)), or set
`BOOT.CFG` = `SCRAP.PLC` to run it at power-up.

Date: 2026-11-03

The design (proposal, phases, mock-ups) is the SCRAPWRIGHT design doc.
This is **phase 3**: the walkable wreck with the mouse panel (phase 2),
plus salvage, building the tug and air.  Power, hazards, enemies and the
sector map come in later phases.

![SCRAPWRIGHT in the simulator](../../reference/scrap_sim.png)

![a room without air](../../reference/scrap_sim_air.png)

## Playing

You start in your tug's corridor, docked to the KESTREL 9.  A docking
tube from the tug's airlock leads to the wreck's airlock.

| Input | What it does |
|-------|--------------|
| Arrows, WASD, or the SNES pad | walk one cell (held: a step every 7 frames).  Walking into a closed door opens it, and it closes behind you unless it is held open |
| Mouse over a cell | a yellow frame on the cell, and the panel shows it: name, damage bar, info on the left, actions on the right |
| Mouse over yourself | your suit, battery, hands and pack |
| Left click on a cell | locks the panel on it, so the mouse can go down to the actions |
| Left click on an action, or keys **1-4** | does it (see below) |
| Right click | unlocks the panel |
| Esc | back to the DOS |

The actions, on the cell the panel shows (all but WALK HERE and INSPECT
need you next to it, diagonals count):

| Action | What it does |
|--------|--------------|
| OPEN / CLOSE | a door (not while you stand in it).  An opened door closes again once you have walked through it |
| HOLD OPEN | opens a door and keeps it open: it stays open behind you (the panel says HELD OPEN) until you CLOSE it.  The doors that start open are held open |
| WALK HERE | walks toward the cell, across first, then up or down |
| INSPECT | a line about it on the message row |
| CUT FREE | a part in the wreck is BOLTED: cutting takes 1.5 s and 5 % of the suit battery, and needs a working cutter in a hand.  Walking away stops it |
| UNINSTALL | a part INSTALLED in the tug: 1 s by hand (no cutter), then it is LOOSE |
| INSTALL | a LOOSE ship part on one of the tug's cells (O2 tank, scrubber, battery, fuel tank, helm, bunk, locker): 1 s, then it is INSTALLED and part of the tug.  Cargo and the cutter can't be installed |
| PICK UP | a LOOSE part goes into the first free carry slot: left hand, right hand, back |
| PUT DOWN LEFT HAND / RIGHT HAND / FROM BACK | on a bare deck next to you |
| REFILL SUIT FROM IT | a full O2 tank fills the suit (11 L less for each damage step) and is empty after |

You carry three things at most, one in each hand and one on your back,
and you start with the plasma cutter in your right hand.  Each part you
carry (the cutter is light) makes a step 4 frames slower.

**The tug.**  A part is part of the tug once it is installed on one of
the tug's cells: a part you put down there is loose, and does nothing
until you INSTALL it.  Hovering yourself shows the tug's worth (each
installed part's value, less with damage; its hull fittings too) and
whether it has air: it needs a working O2 tank and a scrubber installed.
With air, the tug tops up its rooms and fills your suit (3 L a second),
and with a battery installed it charges your suit.  Uninstall its O2
tank and the tug has no air until you install one again.

**Air.**  Each room (the cells joined side by side, found by
`gen_scrap.py`) has a pressure of 0-100.  Every 8 frames, each open door
and the airlocks share their two rooms' air (the average), a hull breach
lets an eighth of its room's air out, and the tug tops up its own rooms.
A deck in a room under 40 is drawn frosted.  In a room under 60 your suit
uses its own O2, 1 L a second (90 L is a minute and a half).  The
warnings show on the message row in red, and a worse one shows at once:

| Suit O2 | Warning |
|---------|---------|
| under 45 L | CAUTION |
| under 23 L | WARNING |
| under 9 L | CRITICAL |
| 0 | YOU ARE BLACKING OUT: 10 seconds to get air |
| then | YOU SUFFOCATED: Enter starts the game again |

The KESTREL 9's aft section lost its air through a breach; its doors are
shut.  Open one and the air of the rooms beyond it goes too, until you
close it again.

The camera moves one cell when you come within 4 cells of the view's
side (3 of its top or bottom) and redraws the view (no smooth scroll).  There is no arrow pointer yet: the frame on the cell, and the
inverse action row in the panel, show where the mouse is.

## The screen

- Lines 0-383: 4 bpp, 2x line repeat, 20 x 12 cells.  A cell is 8 x 16
  pixels of art (32 x 32 on the monitor), 64 bytes.
- Lines 384-479: 1 bpp, 2x, the panel (text rows 24-29, 80 columns).
  - Row 24: the name, tinted blue, BOLTED or LOOSE for a part, the air
    of its room, and the damage bar.
  - Rows 25-28: the info on the left, the action menu after the bar on the
    right.
  - Row 29: messages, tinted gold, cleared after 4 seconds; a warning,
    tinted red, while there is no message.

Every item has a damage score of 0-15 (6.25 % a step).  Its output falls
from full at 0 % to nothing at 50 %, and from step 8 (50 %) on it is
broken: the info line says `WORKS AT nn%` or `BROKEN - NEEDS REPAIR`.

## Memory

| Address | What |
|---------|------|
| x0100-x33FF | the program (asm_expand.py pages it) |
| even pages xC0-xFE | more of the program: code and strings that `SCRAP.OVL` brings in after the map (asm_expand.py's overlay region, as in the tracker) |
| x3400-x38FF | tables (gen_scrap.py): the doors, damage bars and rooms, actions, names and values, info lines |
| x3900-x3FFF | the cell art, 4 cells a page (25 kinds now, room for 28) |
| x4000-x407F | each room's pressure, and whether it is cold |
| x5400-x55FF | sector buffer for loading `SCRAP.OVL` |
| even pages x60-xBE | the map: 96 x 64 cells in 24 chunks of 16 x 16 |
| odd pages x61-xBF | the screen (2x repeat leaves the even pages free) |

Chunk k (k = 6 (y / 16) + x / 16) is page x60 + 4k (the cell types) and
x62 + 4k (the flags).  A type byte is the type (bits 4-0), bits 5-4 of
the cell's room (at 6-5) and bit 7 (a part: bolted, or on the tug
installed; an open door: held open); a flag byte is the damage
(bits 3-0) and bits 3-0 of the room (at 7-4).  A door's room is the room
on one side of it; `gen_scrap.py` lists the doors with the rooms on both
sides.  `SCRAP.OVL` is those 48
pages in order (12 KB), then the program's pages for xC0 up, read
straight from the card.  A later phase pages
bigger maps from the card a chunk at a time.

Like the tracker, the program runs with the map at FF (every section RAM)
to reach the video RAM and its map, and calls the library through `l_*`
stubs that switch to map 07 around the call.

## Building

```
cd src\scripts
python gen_scrap.py                              scrap_types.asm, scrap_data.masm, scrap_map.bin
python asm_expand.py scrap.masm                  scrap.asm
python gen_plc.py scrap.asm -o ..\..\sdcard\SCRAP.PLC --overlay 0xC000,2 --overlay-head scrap_map.bin
                                                 SCRAP.PLC, and SCRAP.OVL: the map, then the code
python test_scrap_sim.py --png scrap.png         SCRAP.PLC in placard_sim (also scrap_air.png)
```

`gen_scrap.py` holds the cell art, the item types (names, info lines,
actions, inspect text) and the map generator.  `test_scrap_sim.py` boots
the card in `placard_sim.py` with a PS/2 mouse and checks:

- the map is loaded;
- all 240 view cells against the map and the art;
- the panel;
- walking and walls;
- the mouse frame, lock and unlock;
- CLOSE / OPEN / HOLD OPEN / INSPECT from the keys;
- a bump opening a door, the door closing behind, a held door staying open;
- the camera step;
- uninstalling the tug's O2 tank (the tug loses its air), carrying it,
  putting it down (still no air while loose), installing it (air again);
- cutting a crate free in the wreck, the battery it uses, carrying it
  (slower steps);
- opening the vented section: the corridor's air drops, the decks frost,
  the suit uses its O2;
- each warning, suffocating, and Enter starting again;
- refilling the suit from a tank (it stays installed);
- Esc back to the DOS.
