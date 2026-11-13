# Skyward Tobi

`sdcard/SKYWARD.PLC` is a side-scrolling platform game: World 1 of
*Skyward Tobi 4*, an NES game by Mark Szlemko
(github.com/Zebshine/skyward-tobi-4), ported to the Placard.  It is a
library program for the SD card (run it from the DOS's file browser; Esc
goes back), made by `src/scripts/gen_skyward.py`.  Everything it reads
after it starts is in the card's `SKYWARD/` folder.

Date: 11/13/2026

![The title, Breezy Meadow, Kite Cliffs and Crow Keep in the simulator](../../reference/skyward_sim.png)

![The four courses](../../reference/skyward_courses.png)

## The game

Baron Rook's lightning broke Mabel Tailspin's biplane, her Stunt Medals fell
across Breezy Isle and his crows carried her off to Crow Keep.  Tobi, the
isle's young mechanic, runs after them.

| Course | Name | The idea |
|---|---|---|
| title | | The story; the jump key starts the game |
| 1-1 | Breezy Meadow | Running, jumping, the first Bumblers, one gap |
| 1-2 | Bramble Bluffs | Bluffs two blocks high, Buzzbees at head height, more gaps |
| 1-3 | Kite Cliffs | The glider: islands with gaps too wide to jump |
| 1-4 | Crow Keep | Fire pits, then Baron Rook: land on him three times |
| ending | | Mabel is free |

- **Controls:** arrow keys or SNES pad 1 Left / Right to run; Up, Space,
  pad B or A to jump; Esc back to the DOS.  A jump needs a new key press.
- **Glider** (from course 1-3): hold the jump key in the air and Tobi falls
  slowly (3/8 of a pixel a frame, against up to 5).
- **Enemies:** land on a Bumbler or a Buzzbee for 100 points; touch one any
  other way and a life is lost.  Baron Rook takes three landings (1,100).
- **Medals** are 10 points each.  The windsock ends a course.
- **Lives:** three.  After a lost life Tobi comes back where he last stood
  and blinks for 1.5 s, safe.  With none left the game goes back to the title.
- Each course starts on a card with its name and two lines of text and
  waits for the jump key.

## What is from Skyward Tobi 4, and what is not

Used, under its MIT License (Copyright (c) 2026 Mark Szlemko; the notice
is in `gen_skyward.py`, next to the art): the story, the cast (Tobi, Mabel
Tailspin, Baron Rook, the Bumblers and Buzzbees), the course names and each
course's idea, the Stunt Medals, the glider, and the sprite frames of the
Bumbler, the Buzzbee, Baron Rook and Tobi's body, recolored for the
Placard's 16 colors.

Changed or left out:

| NES game | Here | Why |
|---|---|---|
| 256 × 240, 13 rows of tiles, hardware scrolling and sprites | 160 × 112, 5 rows of tiles, all drawn in software | The Placard has no scroll registers or sprites; see "How it draws" |
| 2 worlds, 24 courses, a world map, forts, treasure houses, secret exits | World 1's four main courses, in order | A first cut; each course is a file, so more can be added |
| Courses about 200 tiles long | 128 tiles (1,024 byte columns, so positions wrap for free) | The engine's 10-bit positions |
| Run button, speed that builds up, a run meter | One running speed | Kept simple; no room on screen for a meter |
| Power-ups (Sky Berry, Ember Pepper, Glide Feather, Tengu Geta), item crates, a reserve box | Only the glider, given at course 1-3 | First cut |
| Shellby (a shell that slides), Snapjaw, Spindle, Captain Squall | Not in | First cut |
| Tobi: a mustached plumber | Tobi: a young mechanic in a flying cap, goggles and a red scarf | The NES game's status box, item blocks, pipes, shells and its hero were drawn to recall Super Mario Bros. 3.  This port keeps the game's own ideas and gives those parts the Placard's own look: the score is a text line, the blocks are plain stone and brick, and there are no pipes |
| Music on seven channels | Sound effects only | The 4-bit audio and the frame budget; the tracker's player could be added |
| Battery save | None | |

## The screen

| Rows | Mode | What |
|---|---|---|
| 0-31 | 1 bpp, 1x | Four lines of 80-column text: the course's name, the score line (score, medals, lives), two lines of story or help |
| 32-479 | 4 bpp, 4x | The playfield, 160 × 112 pixels of 4 × 4 |

The playfield has three bands: the high sky (cells 0-15, scrolls at 1/8 of
the course's speed), the clouds (16-31, 1/2) and the course (32-111, five
rows of 16 × 16 tiles).  In Crow Keep the two sky bands are the keep's wall.

## How it draws

The engine is `gen_scroller.py`'s (the Runner demo), with five tile rows
instead of three and a course read from the card:

1. Wait for vertical blanking.
2. Draw the bands and the course, 8,960 bytes, top to bottom ahead of the
   beam.  Each distinct byte column of a band picture, and each of the
   eight byte columns of a tile in a tile row, is a *strip*: unrolled code
   that stores that column's bytes with immediates (video memory is
   column-major, so a column is one page pair).
3. Draw the sprites over it with a blitter in the RAM.  Each sprite frame
   is compiled code as well: a store for a solid byte, read / AND / OR /
   write for a byte that is half transparent.
4. Sound, pads, keyboard, the game's rules, the score line.

The background is finished at about 58 % of the time the beam takes to
reach the course's first row.

## Memory and files

| Where | What |
|---|---|
| x0100-x1EFF | `ROWX` and `VPG` tables, the blitter (`draw_sprites`), 13 of the 16 common sprite frames (Tobi's twelve and the medal) |
| x2000-x3FFF | The program |
| x4000-x4BFF | The course's tables (6 sectors of its file): band and tile strip addresses, the tile map (5 × 128), which tiles are solid, the objects, the sprite routines' addresses, three lines of text |
| x5400-x55FF | The objects' state, the medals taken |
| x6000-xFFFF, offsets x040-x17F of each byte column | The course's strips and the sprite frames that are not in the low RAM (the 4x playfield and the text rows leave these bytes free) |

`SKYWARD/C0.LVL` to `C5.LVL` are the title, the four courses and the
ending.  A file is the 6 sectors of tables and then a straight image of the
RAM from x6000, as many whole byte columns (sectors) as the course's strips
reach: 21 to 34 KB.  `load_course` reads the tables to x4000 and the rest
to x6000 on (about 0.4 s); the playfield goes black a column at a time as
the image passes over it, and the first frame draws it again.

A course is 5 rows of 128 letters in `gen_skyward.py` (`COURSES`): tiles,
and the things that stand in it (`S` the start, `o` a medal, `e` a Bumbler,
`z` a Buzzbee, `G` the windsock, `R` Baron Rook, `M` Mabel, `p` the
biplane).  The first two and the last four tile columns are a wall, so the
wrap from byte column 1,023 to 0 never shows.  A course may have 8 objects,
40 medals and 32 different (tile row, tile) pairs.

## Testing

`python3 src/scripts/test_skyward_sim.py` boots the 32K ROM in
`placard_sim.py` from a card with `BOOT.CFG` = `SKYWARD.PLC` and plays the
game through pad 1 with a bot.  The bot looks ahead with a Python model of
the rules (the same file), so the model and the program are compared on
every frame too.  For every frame the test checks the background and the
sprites byte for byte against `gen_skyward.py`'s model and that the
drawing is ahead of the beam; at the end, that every course was cleared in
order, that the strips are unchanged and that Esc brings the DOS back.
A whole game is about 4,650 frames and takes about 35 minutes; `--course n`
starts at course n, and `--course 3 --lives 1 --stop-after 0` checks that the
title comes back when the last life is lost.

`python3 src/scripts/gen_skyward.py --preview DIR` draws every course's
whole length.
