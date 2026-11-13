# Skyward Tobi

`sdcard/SKYWARD.PLC` is a side-scrolling platform game: World 1 of
*Skyward Tobi 4*, an NES game by Mark Szlemko
(github.com/Zebshine/skyward-tobi-4), ported to the Placard.  It is a
library program for the SD card (run it from the DOS's file browser; Esc
goes back), made by `src/scripts/gen_skyward.py`.  Everything it reads
after it starts is in the card's `SKYWARD/` folder.

Date: 11/13/2026

![The title, Breezy Meadow, Kite Cliffs and Crow Keep in the simulator](../../reference/skyward_sim.png)

![Whistling Cave, Gale Fort, Shellback Beach, Skyrail Rise, Thorn Garden and Bouncy Boughs](../../reference/skyward_courses.png)

## The game

Baron Rook's lightning broke Mabel Tailspin's biplane, her Stunt Medals fell
across Breezy Isle and his crows carried her off to Crow Keep.  Tobi, the
isle's young mechanic, runs after them.

| File | Course | Name | The idea |
|---|---|---|---|
| `CA` | title | | The story; the jump key starts the game |
| `CB` | 1-1 | Breezy Meadow | Running, jumping, the first Bumblers, one gap |
| `CC` | 1-2 | Bramble Bluffs | Bluffs two blocks high, Buzzbees at head height, more gaps |
| `CD` | 1-3 | Kite Cliffs | The glider: islands with gaps too wide to jump |
| `CE` | 1-4 | Whistling Cave | Air vents that carry Tobi over walls and out of pits; Spindles |
| `CF` | fort | Gale Fort | Thorns, fire pits, a bounce drum, then Captain Squall |
| `CG` | 1-5 | Shellback Beach | Shellbys and their sliding shells; Snapjaws in their stumps |
| `CH` | 1-6 | Skyrail Rise | Lifts that run back and forth over the gaps |
| `CI` | 1-7 | Thorn Garden | The Tengu Geta walks on thorns; bridges for those without it |
| `CJ` | 1-8 | Bouncy Boughs | Bounce drums: over tall walls and wide gaps |
| `CK` | bonus | Cloud Cellar | A room of medals and a Glide Feather |
| `CL` | keep | Crow Keep | Fire pits, then Baron Rook: land on him three times |
| `CM` | ending | | Mabel is free |

- **Controls:** arrow keys or SNES pad 1 Left / Right to run; Up, Space,
  pad B or A to jump; Esc back to the DOS.  A jump needs a new key press.
- **Glider:** hold the jump key in the air and Tobi falls slowly (3/8 of a
  pixel a frame, against up to 5).  Kite Cliffs and Crow Keep give it; the
  Glide Feather gives it anywhere.
- **Enemies:** land on a Bumbler or a Buzzbee for 100 points.  A **Spindle**
  is all needles and a **Snapjaw** all teeth: they cannot be landed on.  A
  Snapjaw is up out of its stump for 64 frames and down for 64.  A
  **Shellby** landed on pulls into its shell; touch the shell and it slides
  away, knocking out whatever it meets, until the end of its run.  A sliding
  shell hurts unless it is landed on, which stops it.
- **Bosses:** Captain Squall (Gale Fort) and Baron Rook (Crow Keep) take
  three landings each (1,100 points).
- **Crates:** jump into one from below.  A **Sky Berry** takes one hit for
  Tobi; a **Glide Feather** does too, and is a glider; the **Tengu Geta**
  is a sandal that walks on thorns and lands on Spindles and Snapjaws, and
  takes a hit of its own.  What Tobi carries is on the score line and goes
  on to the next course.
- **Course pieces:** thorns hurt from above; a bounce drum throws Tobi
  about six blocks up; an air vent lifts him as long as he is in it; a lift
  carries him.
- **Medals** are 10 points each.  The windsock ends a course.
- **Lives:** three.  After a lost life Tobi comes back where he last stood
  and blinks for 1.5 s, safe.  With none left the game goes back to the title.
- Each course starts on a card with its name and two lines of text and
  waits for the jump key.

## What is from Skyward Tobi 4, and what is not

Used, under its MIT License (Copyright (c) 2026 Mark Szlemko; the notice
is in `gen_skyward.py`, next to the art): the story, the cast, the course
names and each course's idea, the Stunt Medals, the glider, the power-ups,
and the sprite frames of Tobi, the Bumbler, the Buzzbee, the Spindle,
Shellby, the Snapjaw, the Tengu Geta, Captain Squall and Baron Rook
(`skyward_art.py` holds the newer ones), recolored for the Placard's 16
colors.

Changed or left out:

| NES game | Here | Why |
|---|---|---|
| 256 × 240, 13 rows of tiles, hardware scrolling and sprites | 160 × 112, 5 rows of tiles, all drawn in software | The Placard has no scroll registers or sprites; see "How it draws" |
| Courses laid out on 13 rows, about 200 tiles long | Each course built again around its idea on 5 rows, 128 tiles long (1,024 byte columns, so positions wrap for free) | The screen, and the engine's 10-bit positions |
| 2 worlds, a world map, treasure houses, secret exits, Sun Bell Tower | World 1's courses in a row; World 2 is to come | In stages |
| Run button, speed that builds up, a run meter, a status box | One running speed; the score is a text line | The Placard's screen: four text lines over the playfield |
| Big and small Tobi; the jacket's color shows the power-up | Small Tobi; the power-up is named on the score line | 16 × 16 sprites, drawn in software |
| Ember Pepper, a reserve box | Not yet | With World 2, whose courses use the pepper |
| A shell can be carried, and breaks bricks | It slides and knocks out enemies | Kept simple |
| Captain Squall runs at Tobi and leaps | He runs the hall end to end | Kept simple |
| Music on seven channels, story pictures | Sound effects only, story as text | To come |
| Battery save | None | |

## The screen

| Rows | Mode | What |
|---|---|---|
| 0-31 | 1 bpp, 1x | Four lines of 80-column text: the course's name, the score line (score, medals, lives, power-up, geta), two lines of story or help |
| 32-479 | 4 bpp, 4x | The playfield, 160 × 112 pixels of 4 × 4 |

The playfield has three bands: the high sky (cells 0-15, scrolls at 1/8 of
the course's speed), the clouds (16-31, 1/2) and the course (32-111, five
rows of 16 × 16 tiles).  In the forts the two sky bands are the wall, in
the cave the roof.

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
reach the course's first row.  The tile map is in the RAM, so a crate that
has been opened is one byte changed in it.

## Memory and files

| Where | What |
|---|---|
| x0100-x1EFF | `ROWX` and `VPG` tables, the blitter (`draw_sprites`), 14 of the 16 common sprite frames (Tobi's twelve and the medal) |
| x2000-x3FFF | The program |
| x4000-x4BFF | The course's tables (6 sectors of its file): band and tile strip addresses, the tile map (5 × 128), each tile's type, the objects, the sprite routines' addresses, three lines of text |
| x5400-x55FF | The objects' state, the power-up and the geta, the medals taken |
| x6000-xFFFF, offsets x040-x17F of each byte column | The course's strips and the sprite frames that are not in the low RAM (the 4x playfield and the text rows leave these bytes free) |

`SKYWARD/CA.LVL` to `CM.LVL` are the title, the eleven courses and the
ending.  A file is the 6 sectors of tables and then a straight image of the
RAM from x6000, as many whole byte columns (sectors) as the course's strips
reach: 21 to 34 KB.  `load_course` reads the tables to x4000 and the rest
to x6000 on (about 0.4 s); the playfield goes black a column at a time as
the image passes over it, and the first frame draws it again.

A course is 5 rows of 128 letters in `gen_skyward.py` (`COURSES`).  Tiles:
`#` ground, `H` `B` `K` `D` blocks, `=` a bridge, `^` thorns, `U` a bounce
drum, `$` an air vent, `1` `3` `4` a crate (Sky Berry, Glide Feather, Tengu
Geta), `u` a stump.  Things that stand in it: `S` the start, `o` a medal,
`e` a Bumbler, `z` a Buzzbee, `x` a Spindle, `k` a Shellby, `j` a Snapjaw,
`l` a lift, `G` the windsock, `Q` Captain Squall, `R` Baron Rook, `M`
Mabel, `p` the biplane.  The first two and the last four tile columns are a
wall, so the wrap from byte column 1,023 to 0 never shows.  A course may
have 8 objects, 40 medals and 32 different (tile row, tile) pairs.

A tile's type is a byte: 1 solid, + 2 thorns, + 4 a bounce drum, 8 an air
vent, x10 a crate with its power-up in the top bits.  An object's kind is
bits as well: 1 a 32 × 32 boss with three hits, 2 a picture, 4 spiked, 8 a
Snapjaw, x10 a lift, x20 a Shellby, x40 one that moves every frame.

## Testing

`python3 src/scripts/test_skyward_sim.py` boots the 32K ROM in
`placard_sim.py` from a card with `BOOT.CFG` = `SKYWARD.PLC` and plays the
game through pad 1 with a bot.  The bot looks ahead with a Python model of
the rules (the same file), so the model and the program are compared on
every frame too.  For every frame the test checks the background and the
sprites byte for byte against `gen_skyward.py`'s model and that the
drawing is ahead of the beam; at the end, that every course was cleared in
order, that the strips are unchanged and that Esc brings the DOS back.
A whole game is about 13,000 frames and takes about an hour and a half;
`--course n` starts at course n, `--stop-after n` stops when course n
loads, `--stomp` has the bot land on every enemy it can (the Shellbys'
shells, the crates), and `--course 1 --lives 1 --walk --stop-after 0` (a
bot that only walks, with one life) checks that the title comes back when
the last life is lost.

`python3 src/scripts/gen_skyward.py --preview DIR` draws every course's
whole length.
