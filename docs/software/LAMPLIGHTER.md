# Lamplighter

`sdcard/LAMP.PLC` is an exploration platform game for the Placard: rooms
that scroll sideways and up and down, joined into a world that branches
from a central shaft, doors that a shot opens, and (in the stages to come)
power-ups that must be found and that open new ways through it.  It is a
library program for the SD card (run it from the DOS's file browser; Esc
goes back), made by `src/scripts/gen_lamp.py` from
`src/scripts/lamp_code.masm`.  Everything it reads after it starts is in
the card's `LAMP/` folder.

Date: 11/13/2026

The game, its world, its names, its art and its map are original, written
for the Placard.  It is in the exploration-platformer genre.

![The Landing Ledge, the Keeper's Duct, the Wellshaft and the West Gallery in the simulator](../../reference/lamp_sim.png)

![The six rooms of stage 1](../../reference/lamp_rooms.png)

## The game

The hollow moon Cairn carried the great lamp that ships steered by.  The
lamp has gone dark.  Wick, a beacon keeper, lands on the crust and climbs
down the Wellshaft to find out why, with a lantern that throws sparks.

- **Controls:** arrow keys or SNES pad 1 Left / Right to walk, Down to
  crawl, Z, Space or pad B / A to jump (hold the key for a higher jump),
  X or pad Y / X to fire, with Up held to fire upward.  Esc goes back to
  the DOS.
- **Rooms** are up to 32 × 16 tiles (the screen shows 10 × 7) and scroll
  both ways.  Walking off a room's open edge, or jumping or falling
  through a gap in its ceiling or floor, leads into the next room.
- **Doors** open to a shot and shut again after 2.5 s.  The door on the
  far side of a room's edge opens as Wick comes through.
- **Crawling** takes Wick through ducts half a tile high.
- **Jumping** reaches a little over 3 tiles; a room above is reached from
  a ledge under the gap.

### The plan

The game is built in stages, each merged when it passes its test.

| Stage | What | State |
|---|---|---|
| 1 | The engine: two-way scrolling rooms from the card, the hero, shots, doors, crawling; six rooms of the Wellshaft | Done |
| 2 | The whole Wellshaft and the first area, enemies, energy and damage, the first power-ups, the first boss | |
| 3 | The other areas, power-ups and bosses | |
| 4 | Music, the title and the ending, saving to the card at save lamps | |

The world is a hub, the Wellshaft (a tall shaft of rooms one above the
other, with passages off it at different depths), and four areas: the
Glasswort Gardens, the Slagworks, the Brine Vaults and the Orrery, which
the bosses of the other three open.  The power-ups: the Burrow Rig
(crawling; in stage 1 Wick starts with it), the Updraft Bellows (a second
jump in the air), the Ash Sail (a slow fall over wide gaps), the Kiln
Charge (hold fire for a blast that breaks sooted blocks), the Wide Flame (a
three-way shot), the Cinder Coat (half the damage, and no harm from hot
rooms), the Ballast Boots (walking as usual under water) and Oil Flasks
(more energy).  Every boss can be beaten with the lantern alone; the
power-ups make it much easier.

## What the Placard changes

| A console of the genre | Here | Why |
|---|---|---|
| 256 × 240, 16 × 15 tiles on the screen | 160 × 112, 10 × 7 tiles | The 4 bpp 4x mode is the one a frame can redraw |
| Scroll registers and hardware sprites | The whole playfield drawn again every frame, and the sprites over it | The Placard has neither; see "How it draws" |
| Corridors and shafts many screens long | Rooms of up to 3.2 × 2.3 screens, joined at their edges | Positions fit in a byte, which keeps the rules small and fast; a long shaft is rooms one above the other |
| The whole map in the cartridge | A room is a 1 KB file read as Wick enters it (a tenth of a second) | The RAM holds one room; the card is fast |
| One set of tiles and sprites in the cartridge | A tile set and a sprite set for each area, read when the area changes (about 0.3 s) | Tiles and sprites are code (below), about 25 tiles and the sprites fit in the free video RAM |
| A password | Saving to the card (stage 4) | The card can be written |

## The screen

| Rows | Mode | What |
|---|---|---|
| 0-31 | 1 bpp, 1x | Four lines of 80-column text: the room's name, the energy |
| 32-479 | 4 bpp, 4x | The playfield, 160 × 112 pixels of 4 × 4, 16 colors |

## How it draws

The method is `gen_skyward.py`'s and `gen_scroller.py`'s (unrolled code
that stores a tile's bytes with immediates, compiled sprites), changed so
the picture can also move up and down:

1. **Wait for the beam** to reach the playfield's last tile row (the line
   counter read through `frame_poll`, value 240).
2. **Draw the playfield, tile row by tile row from the top** (8,960 to
   10,240 bytes).  The beam is below every row as it is drawn, and it has
   left the playfield before the last rows are, so nothing tears.  For a
   tile row the 16 video offsets of its cells go into the zero page
   (`ROWT`; cells above or below the playfield get an offset nothing
   shows).  Then each tile of the row is one jump: its routine stores its
   8 byte columns one after the other through `ROWT`, steps the column's
   video page by 2 after each, and comes back at the tile's end or when
   the page passes column 79 (the add's carry).  So a tile costs one map
   lookup, whatever the scroll.
   A tile whose byte columns are all the same (the empty tile, a ledge) is
   one routine that loops; a run of three or more equal bytes is stored
   from AC.
3. **Draw the sprites** over it with the blitter (each sprite frame is
   compiled code as well).  They are done before the beam is back at the
   playfield's first row: the drawing takes about 78 % of that time in the
   test.
4. **Sound, pads, keyboard, the rules, the sprite list, the text** while
   the beam draws the playfield.

Starting at the vertical blanking, as the Skyward engine does, would draw
the sprites of the top rows after the beam has passed them.  Starting at
the last tile row gives the drawing the rest of the frame and the blanking,
and the rules the time the beam spends on the picture.

## Memory and files

| Where | What |
|---|---|
| x0100-x02FF | `ROWX` and `VPG`: video offset of a cell, video page of a byte column |
| x0300-x1EFF, x2000-x3FFF | The program (3.5 KB in stage 1) |
| x4000-x43FF | The area's tables: tile routine addresses (2 pages), tile attributes, sprite routine addresses |
| x4400-x45FF | The room's tile map, 32 × 16 bytes (tile number × 8) |
| x4600-x46FF | The room's header: size, camera limits, exits, name |
| x5400 | The sprite list |
| x6000-xFFFF, offsets x040-x17F of each byte column | The area's tile routines and sprite routines (the 4x playfield and the text rows leave these bytes free) |

| File | What |
|---|---|
| `LAMP/An.TS` | Area n: the 4 pages of tables, then a straight image of the RAM from x6000 |
| `LAMP/Rnn.RM` | Room nn (hex): the tile map, the header, a spare page |

A tile has attribute bits: solid in its upper half, solid in its lower half
(both: a wall; one: a ledge or a duct's roof), a door, a door's lower
tile.  Tiles 0-4 are the same in every area: empty, and a door's two
tiles, shut and open.

A room is rows of letters in `gen_lamp.py` (`ROOMS`) with its exits: the
side, the tiles of the edge it covers, the room it leads to and how far
along the edge Wick comes in.  `check_rooms` checks that every exit is
open, has an exit back and lands in the open.  A rock letter becomes one
of three rock tiles by what is above and below it.

## Testing

`python3 src/scripts/test_lamp_sim.py` boots the 32K ROM in
`placard_sim.py` from a card with `BOOT.CFG` = `LAMP.PLC` and plays the
game through pad 1 with a bot.  `gen_lamp.py` has the rules a second time,
in Python (`Model`).  The bot plans each leg of its route by searching
that model (which buttons, 4 frames at a time, reach the next room or
place), so the route needs no hand-written key presses and the program is
compared with the model on every frame: the hero, the camera, the shots,
the door, the room and the tile map.  For every frame it also checks the
playfield byte for byte against the model's picture, before and after the
sprites, and that each tile row is drawn behind the beam and the sprites
are done before it is back.  At the end: that the bot got through its
route (every room, the duct, up and down both shafts), that the routines
in the video RAM are unchanged and that Esc brings the DOS back.  The
route is about 2,600 frames and takes about 45 minutes.

`python3 src/scripts/gen_lamp.py --preview DIR` draws every room.
