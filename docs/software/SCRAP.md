# SCRAPWRIGHT

`SCRAP.PLC` (`src/scripts/scrap.masm`, with `SCRAP.OVL`) is SCRAPWRIGHT,
an original top-down salvage game: you fly a small tug out to derelict
ships, walk through them in a suit, take out what is worth having, haul it
back, and build it into your own ship.  It is not in the demo menu: pick
it in the DOS's file browser and press Enter ([DOS.md](DOS.md)), or set
`BOOT.CFG` = `SCRAP.PLC` to run it at power-up.

Date: 2026-11-03

The design (proposal, phases, mock-ups) is the SCRAPWRIGHT design doc.
This is **phase 3**: the walkable wreck with the mouse panel (phase 2),
plus salvage, building the tug, air, skills and taking the suit off.  Power, hazards, enemies and the
sector map come in later phases.

![SCRAPWRIGHT in the simulator](../../reference/scrap_sim.png)

![a room without air](../../reference/scrap_sim_air.png)

## Playing

You start in your tug's corridor, docked to the KESTREL 9.  Docked, the
tug's airlock is right next to the wreck's, side by side: always aligned,
so you step from one into the other, and the air of the two corridors is
shared through them.

| Input | What it does |
|-------|--------------|
| Arrows, WASD, or the SNES pad | walk one cell (held: a step every 7 frames).  Walking into a closed door opens it, and it closes behind you unless it is held open |
| Mouse over a cell | a yellow frame on the cell, and the panel shows it: name, damage bar, info on the left, actions on the right |
| Mouse over yourself | your suit, battery, hands and pack |
| Left click on a cell | locks the panel on it, so the mouse can go down to the actions |
| Left click on an action, or keys **1-8** | does it (see below); the menu is two columns of four, each action with its key to its left, `1:` to `8:` |
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
| UNINSTALL | a part INSTALLED in the wreck: the cutter does it, in 1.5 s and 5 % of the suit battery, and needs a working cutter in a hand.  Walking away stops it.  The wreck's walls, decks and doors uninstall the same way, into a wall panel, a door kit or a deck plate.  INSTALLED in the tug: 1 s by hand (no cutter).  Either way it is LOOSE then.  On the tug the walls, decks and doors uninstall too (not the cell you stand on): a wall leaves a WALL PANEL lying on the deck, a door a PRESSURE DOOR kit, and a deck goes into a free carry slot as a SPARE PLATE, leaving open space |
| INSTALL | a LOOSE ship part on one of the tug's cells (O2 tank, scrubber, battery, fuel tank, helm, bunk, locker): 1 s, then it is INSTALLED and part of the tug.  A wall panel installs as a wall, a door kit as a closed door.  Cargo and the cutter can't be installed |
| LAY DECK PLATE | open space next to you, with a deck plate in a carry slot: it is a deck now |
| REPAIR | a damaged part, wall, deck or door next to you: 0.25 s a damage step at full speed (see **Skills**), then it has no damage.  A repaired wall or door stops leaking |
| SKILLS | on yourself: your six skill levels on the message row |
| TAKE OFF SUIT / PUT ON SUIT | on yourself: the suit goes into a free carry slot, or back on from its slot (see **The suit**) |
| PICK UP | a LOOSE part goes into the first free carry slot: left hand, right hand, back |
| PUT DOWN LEFT / RIGHT / BACK | from that carry slot onto a bare deck next to you |
| REFILL SUIT | a full O2 tank fills the suit (11 L less for each damage step) and is empty after |

You carry three things at most, one in each hand and one on your back,
and you start with the plasma cutter in your right hand.  Each part you
carry (the cutter is light) makes a step 4 frames slower.

A part that is not installed (LOOSE) is drawn in a brown crate frame,
so you can see at a glance what is fitted and what is lying about.

**Skills.**  You have six skills, 0-99, all starting at 10: MECHANICAL,
ELECTRICAL, NUCLEAR, COMPUTERS, HYDRAULICS and SUIT.  Each part needs one
or two of the first five (its info lines say which: a thruster needs
MECHANICAL and HYDRAULICS, a helm COMPUTERS and ELECTRICAL, a wall
MECHANICAL), and they set how fast you uninstall, install and repair it.
A job is 16 work units a frame of its time at full speed (install and
uninstall 1 s, the cutter 1.5 s, a repair 0.25 s a damage step), and you
do 2 + a quarter of the needed skills' average a frame (16 is full
speed).  In the suit you do half that, plus an eighth of your SUIT skill
(never more than without it).  So at the start an install takes 4 s
without the suit and 5.3 s in it.  Each job done raises the skills it
used, and SUIT when you wore it: 2 (120 - level) of 256 toward the next
level, so about a level a job at the start and slower as you get good.

**The suit.**  TAKE OFF SUIT puts your suit in a free carry slot (it
keeps its O2, and you can put it down like any part).  Without it you
work quicker but breathe the room's air: in a room under 60 you black
out at once and have 10 seconds to get air or PUT ON SUIT again.  Mind
the airlock.

**The tug.**  A part is part of the tug once it is installed on one of
the tug's cells: a part you put down there is loose, and does nothing
until you INSTALL it.  Hovering yourself shows the tug's worth (each
installed part's value, less with damage; its hull fittings too) and
whether it has air: it needs a working O2 tank and a scrubber installed.
With air, the tug tops up its rooms and fills your suit (3 L a second),
and with a battery installed it charges your suit.  Uninstall its O2
tank and the tug has no air until you install one again.

**Building.**  The tug is the cells x 0-29, y 18-46: its hull and the
space round it, so it can grow there.  Take walls out to join rooms, lay
deck plates on open space and put walls and doors round them to add
rooms.  Every change to a wall, deck or door works the rooms out again.

**Air.**  Each room (the cells joined side by side) has a pressure of
0-100.  `rooms_build` works the rooms out at the start and after every
change to the ship, in the same order as `gen_scrap.py`'s `rooms()`: a
new room's pressure is the average of its cells' old ones (a cell that
was not air brings none).  Every 8 frames, each open door and the
airlocks share their two rooms' air (the average), and the tug tops up
its own rooms (working the rooms out takes about 0.3 s, a short pause in the game).  A room next to vacuum (a hull breach, open space where a
deck or wall was taken out, the edge of the map) loses an eighth of its
air, and one more.  A wall or a closed door at 50 % damage or worse leaks:
a unit a tick to the room on its other side when that has less, two to
vacuum.  The KESTREL 9 has a cracked hull wall in its vented section.
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
  - Row 24: the name, tinted blue, INSTALLED or LOOSE for a part, the air
    of its room, and the damage bar (on yourself: the tug's worth and air).
  - Rows 25-28: the info on the left (40 columns), the action menu after
    the bar from column 42: two columns of four, actions 1-4 then 5-8.
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
| x3400-x38FF | tables (gen_scrap.py): the doors, damage bars and rooms, actions, the skills each part needs, names and values, info lines |
| x36E0-x36ED | the skill levels (6) and their progress (6) |
| x3900-x3FFF | the cell art, 4 cells a page (28 kinds, the most there is room for) |
| x4000-x407F | each room's pressure, and whether it is cold |
| x4080-x4CFF | `rooms_build`'s work space: each room's sums, the links to check, a bit a cell for the fill, its stack |
| x5400-x55FF | sector buffer for loading `SCRAP.OVL` |
| even pages x60-xBE | the map: 96 x 64 cells in 24 chunks of 16 x 16 |
| odd pages x61-xBF | the screen (2x repeat leaves the even pages free) |

Chunk k (k = 6 (y / 16) + x / 16) is page x60 + 4k (the cell types) and
x62 + 4k (the flags).  A type byte is the type (bits 4-0), bits 5-4 of
the cell's room (at 6-5) and bit 7 (a part: installed; an open door: held open); a flag byte is the damage
(bits 3-0) and bits 3-0 of the room (at 7-4).  A link (a door, an airlock
or a broken wall) has the room of one side; `rooms_build` lists the links
(64 at most) with the rooms on both sides, 0 for vacuum.  `SCRAP.OVL` is those 48
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
- uninstalling a crate in the wreck with the cutter, the battery it uses, carrying it
  (slower steps);
- opening the vented section: the corridor's air drops, the decks frost,
  the suit uses its O2;
- each warning, suffocating, and Enter starting again;
- the rooms `rooms_build` works out against `gen_scrap.py`'s `rooms()`,
  at the start and after each change below;
- a deck plate taken up (the room leaks) and laid again; a wall
  uninstalled (two rooms join, and a broken hull wall leaks), carried,
  put down and installed (two rooms again);
- each job's time against `gen_scrap.job_frames` and the skills it
  raised against `skill_gain`; a loose part drawn crated;
- SKILLS on the message row; TAKE OFF SUIT (O2 kept in air), a REPAIR
  without the suit (quicker), no air without the suit (blacking out),
  PUT ON SUIT;
- refilling the suit from a tank (it stays installed);
- Esc back to the DOS.
