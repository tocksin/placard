# Placard
## PLA computer
This project is a computer designed using some Programmable Logic Arrays (PLA) 
or Programable Array Logic (PAL) or Programmable Array Devices (PLD) chips.  
This started as a pure 7400-series chip computer, but changed over to using 
some PLA/PLDs to increase the usability while not greatly increasing the chip 
count.  The first PLA was created in 1970 by Texas Instruments.  The PAL was 
created in 1978 by Monolithic Memories which is owned by Lattice Semi today. 
There are some differences between the three types of chips, but this project 
isn't going to distinguished between them.

The design documents are in [docs/](docs/README.md), grouped by subject.

## Project goals
The project has some hard-goals to maintain:
- Use only through-hole chips similar to the 7400-series DIP chips (or PLA of course)
- Use only active production chips.  No hunting sketchy websites for parts.
- Design true von Neumann CPU from scratch.  No Harvard.  Bare-metal programming on the computer is a must (native compiler).
- Have a video output.  The video standard is open, but probably a legacy output (VGA/Composite/etc).
- Make the instruction set "fun" to program.  This means no racing the beam to draw the screen.  Counting instructions is not fun.
- A PS/2 keyboard and mouse, read by the machine's own PLD receiver.  No USB.
- Native storage capabilities.  Need to be able to save/load programs as you create them on the computer.

## Block diagram
Each block shows how many chips it uses (33 and a 3.3 V regulator on the main board; the expansion and cartridge slots add none, the cartridge itself has 5).  See [docs/architecture/CHIPS.md](docs/architecture/CHIPS.md) for the parts.

![Placard block diagram](reference/placard_block_diagram.png)

The drawing is made by `src/scripts/gen_block_diagram.py` (CPU on the left, memory, I/O and audio in the middle, video on the right); rerun it when the design changes.

The I/O circuitry (SNES pads, SD card, PS/2 keyboard and mouse) is drawn as a schematic in
[docs/architecture/IO.md](docs/architecture/IO.md#schematic) (`schematics/placard_io_schematic.png`).
The audio circuitry (sample read, DAC register, R-2R ladder, audio line out jack) is drawn in
[docs/sound/SOUND.md](docs/sound/SOUND.md#schematic) (`schematics/placard_video_audio_schematic.png`).

The real schematic and PCB layout are a KiCad project in [kicad/](kicad/).

To build a board one chip at a time, testing each with a multimeter as it goes in, follow [docs/hardware/BRINGUP.md](docs/hardware/BRINGUP.md); it has a bring-up test ROM that checks the CPU and memory and shows the I/O on the screen.

## Memory Map
The Placard has 64kB of memory arranged in a 16-bit address bus and 8-bit databus.  The video RAM starts at x6020 and ends at xFFFF, and each row's mode byte (color mode and line repeat) is at x5A20 + row.  There is a 64kB RAM and a 64kB ROM behind the same addresses.  The address space is divided into eight 8kB sections, and a write-only map register at x5000 picks whether each section reads from the RAM or the ROM.

- **Writes always go to the RAM**, even in a section mapped to ROM.  The write strobe (/WE) is not decoded by address, so a write in the I/O window x5000-x53FF also lands in the RAM underneath it.
- **The map register** is a CD74ACT273E clocked by /MAP_WR from the I/O decode PLD; it latches the source bus at the end of the write.  Bit n = 1 makes section n read from RAM, 0 from ROM.  Bit 2 maps x4000-x4FFF and x5400-x5FFF, because x5000-x53FF is the I/O window.  It is write only, so software keeps a copy of the last value it wrote.
- **At power-up every section reads as ROM.**  RUN from the ROM cartridge holds the register's /MR low while the cartridge loads its SRAM and the CPU is held, so the CPU boots from ROM ([docs/architecture/ROM.md](docs/architecture/ROM.md#loading-the-cartridge)).
- **x5000-x53FF is the I/O window.**  The memory control PLD keeps both the RAM and the ROM off the bus there, so I/O always has priority.
- **Only `[Y,X]` reaches the I/O window**; `[0,D]` and `[0,X]` only address the zero page.
- **Video reads always read the RAM** (memory control PLD); only CPU reads follow the map.  The CPU can run code from the ROM under the video area while the screen shows the RAM, and a program that wants to read the video RAM maps that section to RAM.
- **The ROM is grouped by 8 KB section.**  The machine's 32K ROM (x8000-xFFFF, read at x0000-x7FFF too) holds the boot loader, the library, BASIC and a loader that runs the DOS and programs from the SD card, and each map section holds one kind of thing: section 7 what almost every program uses (jump table, core routines, PS/2 keyboard, pads, mouse, line input), section 6 the files (SD card driver, FAT reader and writer), section 5 BASIC, section 4 the loader, sound driver and font.  A program that maps a section to RAM gives up just that; the font is read through a zero page pointer (`FONT_PG`), so a program can put its own font anywhere.  The library runs in place.  The boot loader copies the library's RAM code to x1F00, gives each expansion card a chance to run its own boot code (like the Apple II), then maps sections 0 and 2 to RAM (map = 05) and starts the loader.  A development ROM (64K cartridge) adds one program in the first 32K, run in place at x6000-x7FFF and x2000-x3FFF, or copied to RAM x0000 for the older demos.  See [docs/architecture/ROM.md](docs/architecture/ROM.md) and [docs/software/DOS.md](docs/software/DOS.md).
- **After a map write**, the next instruction must not be fetched from a section whose map bit that write changed, unless the ROM and RAM hold the same byte there (the new map arrives 2.6 ns too late for that fetch).  Copying the ROM into the RAM underneath and then switching the section is safe.  See [docs/timing/TIMING.md](docs/timing/TIMING.md#video-and-the-rest).

The memory control PLD (`ATF22V10_MEM_CTRL.pld`) makes /ROM_OE and /RAM_OE from the address, the map, RW and PIXEL_ENABLE, using only the low half of each clock.  The RAM's /WE comes from the Sync PLD, off an early tap of the clock ([docs/timing/WE_TIMING.md](docs/timing/WE_TIMING.md)).  The I/O decode PLD (`ATF22V10_IO_DECODE.pld`) makes the upper RAM/ROM chip select (/CE_HI) and the I/O strobes.

The RAM is two AS7C256C-15PCN (32K × 8, 15 ns) chips.  The ROM is two more AS7C256C-15PCN on the ROM cartridge, loaded at power-up from two AT28C256 EEPROMs by the cartridge while it stalls the CPU ([docs/architecture/ROM.md](docs/architecture/ROM.md#loading-the-cartridge)).  See [docs/architecture/CPU.md](docs/architecture/CPU.md#memory-parts) and [docs/timing/TIMING.md](docs/timing/TIMING.md).

| Address | Map bit | Function  |
|---------|---------|------|
| x0000-x1FFF | 0 | RAM/ROM (zero page, program variables, library RAM code at x1F00; ROM: reset jump) |
| x2000-x3FFF | 1 | RAM/ROM (development ROM: program) |
| x4000-x4FFF | 2 | RAM/ROM (program data; FAT variables and buffer at x4D00-x4FFF) |
| x5000-x53FF | none | I/O window (see below) |
| x5400-x5FFF | 2 | RAM/ROM (mode bytes at x5A20-x5BFF, audio buffer at x5DF3-x5FFF) |
| x6000-x7FFF | 3 | RAM/ROM (Video Memory from x6020; development ROM: program from x6000) |
| x8000-x9FFF | 4 | RAM/ROM (Video Memory; ROM: vectors x8000, loader and the end of BASIC x8100, sound driver x9200, font x9700, LIB_RAM copy x9F00) |
| xA000-xBFFF | 5 | RAM/ROM (Video Memory; ROM: BASIC) |
| xC000-xDFFF | 6 | RAM/ROM (Video Memory; ROM: files: SD card driver xC000, FAT reader xC800, FAT writer xD600) |
| xE000-xFFFF | 7 | RAM/ROM (Video Memory; ROM: PS/2 keyboard, pads, mouse, line input, menu hook, slot helpers, core routines xF400, jump table xFB00, boot loader xFD00) |

![Placard memory map](reference/memory_map.png)

The drawing is made by `src/scripts/gen_memory_map.py`; rerun it when the map changes.

### I/O window
Each I/O page has its own select from the I/O decode PLD (revision 07), made straight from the address and valid about 13 ns into the clock.  A write is the select with /WE: devices latch the source bus on the rising edge at the end of /WE.  A read is the select with Q0 low (the LOAD_MEM clock, when the CPU latches the bus into D), and nothing waits for STALL.  The shared port is described in [docs/architecture/IO.md](docs/architecture/IO.md) and the expansion slots in [docs/architecture/EXPANSION.md](docs/architecture/EXPANSION.md).

| Address | Select | R/W | Function |
|---------|--------|-----|----------|
| x5000-x50FF | /P0 (write: /MAP_WR from the Sync PLD) | W | ROM/RAM map register (built) |
| x5000-x50FF | /P0 and Q0 | R | Video line counter, V9:V2 (built) |
| x5100-x517F | /EXP1 | R/W | Expansion slot 1 |
| x5180-x51FF | /EXP3 | R/W | Expansion slot 3 |
| x5200-x52FF | /PORT and /WE | W | Shared port latch (port PLD registers): SD card SCK, MOSI and /CS, SNES pad clock and latch, PS/2 lines; a write to x5202/x5203 also re-arms the PS/2 receiver |
| x5200-x52FF | /PORT and Q0 | R | Shared port: SD MISO and the free PS/2 clock (x5200), SNES pad data (x5201), PS/2 receiver byte (x5202) and ready flag (x5203) |
| x5300-x537F | /EXP2 | R/W | Expansion slot 2 |
| x5380-x53FF | /EXP4 | R/W | Expansion slot 4 |

### Sound
The video circuit reads one 8-bit sample per scan line from x5DF3-x5FFF (525 bytes, one frame) and plays it through a 74HCT574 and a resistor ladder DAC, at the line rate of 31.47 kHz.  80h is silence.  The library's sound driver (`snd_update` once a frame, with `snd_tone`, `snd_beep`, `snd_note`, `snd_noise` and `snd_play`) refills the buffer behind the line being played.  See [docs/sound/SOUND.md](docs/sound/SOUND.md).

### Video line read
A read anywhere in x5000-x50FF returns the upper 8 bits of the video line counter, V9:V2.  The V counter in the V Counter PLD counts 499 to 1023, and one 74F541 enabled by /P0 and Q0 puts V9:V2 on the data bus.  The ROM/RAM map register shares the page but is write only, so there is no conflict.  Read it with `ld 0x50, y` then `ld [y,x], ac`.

- **It is a single byte**, so it can't tear between reads.
- **Resolution is 4 lines** (128 us).  Visible rows start at V = 544, so `row / 4 = value - 136`.  A value below 136 means vertical blanking.
- **There is no frame counter.**  Software keeps time by polling: each time the value goes down (from 255 back to 124), a frame has passed.  At the FPGA's 25.000 MHz clock a frame is 525 lines, about 16.8 ms (59.5 Hz).
- **Software must poll at least once per frame**, or it misses a wrap.  Elapsed time is then frames x 16.8 ms plus the line position for finer detail.

## Video
The video is designed to be 640x480 VGA 60Hz standard.  This means a 25.175 MHz clock.  This requires two counters: a horizontal and vertical.  They count 800 and 600 pixels.  This needs a 10-bit counter for each.  The counters form the RAM address space to read the pixel values.  The video memory is organized in a non-traditional way with H,V instead of V,H.

### Line repeat
Bits 3:2 of a row's mode byte make each byte of video memory show on 1, 2 or 4 lines (640 × 480, 240 or 120).  A full 2x screen leaves 20 KB of the video area free (the even pages x60, x62 ... xFE) and a full 4x screen 30 KB.  The audio slot PLD remaps four row address bits, so no chips were added.  See [docs/video/VIDEO.md](docs/video/VIDEO.md#line-repeat).

### Text demo
`src/scripts/text_demo.asm` draws a demo screen with the CPU and keeps a test running on it: 80 column text (2 colors, 1x, on row tints: a blue status panel and a rainbow raster bar that bounces behind the text), a 16 color band (4 bpp, 4x), 40 column text (2 bpp, 2x) and a 256 color band (8 bpp, 4x) with "256" in shades of red, blue and green and a turning rainbow ring.  Each frame it tests one page of RAM (85 pages: x0100-x1EFF, x2000-x4FFF, x5400-x59FF and x5C00-x5CFF, 14 patterns each, with a progress bar, pass and error counts) and updates a frame counter, an uptime clock, a spinner, a turning color wheel, the ring and a message that scrolls a pixel a frame.  It runs from the SD card (`TEXT.PLC`, `gen_text_demo_sd.py`, in the demo menu), and `src/scripts/text_demo_sim.py` runs and checks it in the simulator (`--gif` makes an animation).  `gen_text_demo_sd.py` makes the SD card version (`TEXT.PLC`, in the demo menu), whose RAM test covers only the RAM the program leaves free ([docs/software/MENU.md](docs/software/MENU.md#the-text-demo-on-the-card)).

![text_demo in the simulator](reference/text_demo_sim.gif)

### DOS, BASIC and demo menu
The machine ships the 32K ROM image (`src/scripts/rom32.masm`, `build\rom32.bat`): the boot loader, the library, PLACARD BASIC (a 16-bit integer BASIC with strings, graphics, sound and SAVE/LOAD on the card, [docs/software/BASIC.md](docs/software/BASIC.md)) and a loader that runs `.PLC` programs from the SD card.  The DOS is one of those programs (`DOS.PLC`, `src/scripts/dos.masm`).  At power-up the loader runs the program named in `BOOT.CFG`, or the DOS's file browser (hold Esc) that runs, deletes and picks the boot program, with a command line for `LOAD` and `SAVE` of memory as files.  With no card, or no `DOS.PLC` on it, BASIC starts.  Ctrl+B in the browser starts BASIC.  The demo menu is one of those programs (`MENU.PLC`, `src/scripts/menu.masm`): the CPU test, pi, Mandelbrot, the Game of Life, the Boing ball, the 3D ships, the ray caster, the side scroller, the textured ray caster and the text demo run in turn, each until it is done or for 2 minutes (Mandelbrot 3); Esc in any program shows the menu (Up / Down and Enter, or 1-9 and 0), a program picked there runs until Esc, and after 2 minutes with no key the menu goes back to running them in turn.  The `sdcard/` folder holds the files for the card; `src/scripts/test_dos.py`, `test_menu.py` and `test_basic.py` check them in the simulator; the `.BAS` files on the card are BASIC examples.  See [docs/software/DOS.md](docs/software/DOS.md), [docs/software/MENU.md](docs/software/MENU.md) and [docs/architecture/ROM.md](docs/architecture/ROM.md#the-32k-image).

### Game demos
Four demos show what the CPU can do with no sprite or collision hardware.  The first three are written by a Python generator (the tables, the unrolled drawing code and a bit-exact model of the picture), and each has a simulator test that checks every frame against the model.

`sdcard/RAYCAST.PLC` (`gen_raycast.py`, which writes `src/scripts/raycast_sd.asm`) is a ray caster: an 80 × 112 view at 8 bpp (4x line repeat) of a maze with shaded, two-tone walls and a dithered floor and ceiling, walked by a demo script until a key or pad button takes over (arrow keys or SNES pad 1: Up / Down walk, Left / Right turn).  A view takes 143k-170k clocks (a column about 2,000), so it runs at the full 60 views a second using under 40 % of each frame.  It is in the demo menu and `src/scripts/test_raycast_sim.py` checks it.

![raycast in the simulator](reference/raycast_sim.gif)

`sdcard/RAYTEX.PLC` (`gen_raycast_tex.py`, with `RAYTEX.OVL`) is the same maze and demo walk with textured walls, in the style of Wolfenstein 3D: seven 32 × 32 textures drawn by the generator (stone, brick, wood, riveted metal, mossy stone, a circuit board with a 22V10 and a framed Mandelbrot picture), y sides darker than x sides and four levels of distance shading.  Each column finds where the ray hit the wall (two 8 × 8 multiplies), copies that texture column through a shading table into zero page, and draws the wall with a compiled scaler: one unrolled routine per wall height that stores the right texel into each cell.  A view takes 229k-261k clocks (about 3,000 a column), so it still runs at 60 views a second, with room left for sprites.  T turns the textures off (one flat, shaded color a wall) and on again.  `src/scripts/test_raycast_tex_sim.py` checks it.  It is in the demo menu: its textures and scalers go into the video RAM the screen leaves free ([docs/software/MENU.md](docs/software/MENU.md#the-ray-casters-and-the-scroller-on-the-card)).

![textured raycast in the simulator](reference/raycast_tex_sim.gif)

`sdcard/SCROLLER.PLC` (`gen_scroller.py`, with `SCROLLER.OVL`) is a side-scrolling platformer at 160 × 112, 4 bpp: three parallax bands (clouds, mountains, hills at 1/8, 1/4 and 1/2 speed) over a tiled level, with a robot that runs, jumps, collects coins and stomps slimes, all at 60 frames a second.  The background is redrawn every frame by unrolled strips, top to bottom ahead of the beam, so nothing has to be erased.  The sprites are compiled: each frame of art is its own routine in RAM that stores its bytes (masked where a byte is half transparent) straight into video memory.  Background and sprites take about 93k of the 420k clocks in a frame.  The demo player plays until a key or pad button is pressed (arrow keys or SNES pad 1: Left / Right to run, Up, Space or pad B to jump).  `src/scripts/test_scroller_sim.py` checks it.  It is in the demo menu: its background strips go into the video RAM the screen leaves free ([docs/software/MENU.md](docs/software/MENU.md#the-ray-casters-and-the-scroller-on-the-card)).

![scroller in the simulator](reference/scroller_sim.gif)

`sdcard/WIRE3D.PLC` (`gen_wire3d.py`) is an Elite-style 3D demo and benchmark: six convex ships tumbling in 3D at 320 × 240, switching every 20 seconds between wireframes with hidden lines removed and filled, shaded faces painted far to near.  Quarter-square multiplies, projection by log tables, Elite's face test in each ship's own space, XOR lines erased by drawing them again, and filled ships erased by blanking only what their new outline does not cover.  Six ships is the limit with margin: filled mode stays above 20 fps (seven ships touch 20), wireframes hold the 30 fps cap with half the CPU spare.  [docs/software/WIRE3D.md](docs/software/WIRE3D.md) has the measurements; `src/scripts/test_wire3d_sim.py` checks every frame against a model.

![wire3d in the simulator](reference/wire3d_sim.gif)

`sdcard/PLAY.PLC` (`src/scripts/play.masm`) plays `DEMO.SNG` with the music player (`src/scripts/placard_mus.masm`, [docs/sound/MUSIC.md](docs/sound/MUSIC.md)): four SID-style voices (pulse with a swept width, saw, triangle, noise or a custom wave, each with an ADSR envelope) and a fifth for sound effects, driven once a frame by patterns, instruments with wave and pulse programs, and effects (arpeggio, slides, portamento, vibrato, volumes, speed), mixed into the line-fetched audio buffer at 15.7 kHz on about 20 % of the CPU.  `mus_tool.py` turns a song written as text (`src/music/demo.mus`, which shows off every feature in 54 seconds) into the `.SNG` file and a WAV, and `test_mus.py` checks the player against its Python model sample for sample.  `sdcard/TRACKER.PLC` (`tracker.masm`, with `TRACKER.OVL`) is the editor on the machine: the orderlists, the four patterns side by side, the instruments and the wave and pulse tables on an 80 x 30 screen, played while you edit, loaded from and saved to `.SNG` files on the card.

`sdcard/BOING.PLC` (`gen_boing.py`) is the Amiga's Boing Ball: a red and white checkered ball, tilted 17 degrees, spinning and bouncing in front of a purple grid with its shadow on the wall, at 160 × 120, 4 bpp.  It holds 60 fps on about a third of the CPU.  The Placard has no palette registers for the Amiga's color-cycling trick, so the spin is 8 phases worked out ahead of time, and each frame redraws only the rows the ball and its shadow touch.  It draws from a clean copy of the background kept in the video RAM that 4x rows leave free, top to bottom and ahead of the beam.  [docs/software/BOING.md](docs/software/BOING.md) has the details and `src/scripts/test_boing_sim.py` checks every frame against a model.

![Boing Ball in the simulator](reference/boing_sim.gif)

`sdcard/SCRAP.PLC` (`src/scripts/scrap.masm`, `gen_scrap.py`, with everything else it reads, `SCRAP.OVL`, the swap files and the part text, in `sdcard/SCRAP/`) is SCRAPWRIGHT, an original top-down ship salvage game in progress: run it from the DOS's file browser.  You walk from a salvage tug docked to a derelict on one 96 × 64 map: 20 × 12 cells of 8 × 16 pixel art in 4 bpp, and a 1 bpp panel that shows the cell under the PS/2 mouse (name, damage bar, info and an action menu).  Phase 3 adds salvage and air: uninstall the wreck's parts with the plasma cutter (the tug's by hand), carry three (two hands and your back, shown on an inventory screen), install them from there or from the deck, in the tug or in a wreck, take its walls, decks and doors out and put them back wherever you like (the rooms and their air are worked out again; broken walls leak), repair what is damaged (anything broken is drawn cracked; nothing goes on a broken deck), lay power conduit, fit a comms antenna and a radar outside, feed the air from an O2 tank through a pump and the thrusters' nitrogen through an intake, with six skills (mechanical, electrical, nuclear, computers, hydraulics, suit) that set how long each job takes and grow as you use them, take your suit off to work quicker (and mind the vacuum), and watch your suit's O2: every room holds its own air, open doors share it, a hull breach drains it, and the warnings go from caution to blacking out.  The navigation mode has begun: NAVIGATE at the helm opens a sector map (a station on an asteroid and derelicts to visit, the tug a triangle that turns with its heading, a zoom in doubling steps, a target picked with the mouse or Tab) above a boxed control panel (flight, propulsion, and the target's range, radar return, registry and the tug's speed toward it and across), where you undock, fly the tug on its thrusters' nitrogen (its mass and thrust from the parts you built in), and dock again; it keeps cruising while you walk, and flying into the wreck damages the tug.  `test_scrap_sim.py` checks it ([docs/software/SCRAP.md](docs/software/SCRAP.md)).

![SCRAPWRIGHT in the simulator](reference/scrap_sim.png)

`sdcard/SKYWARD.PLC` (`src/scripts/gen_skyward.py`, with its courses in `sdcard/SKYWARD/`) is Skyward Tobi, a port of World 1 of *Skyward Tobi 4*, an NES platform game by Mark Szlemko (MIT License): four side-scrolling courses at 160 × 112, 4 bpp, on the scroller's engine with five rows of tiles, each course a file read from the card.  Tobi runs, jumps, glides, lands on Bumblers and Buzzbees, collects Stunt Medals and meets Baron Rook in Crow Keep.  Run it from the DOS's file browser (arrow keys or SNES pad 1; Up, Space or pad B to jump).  `test_skyward_sim.py` plays it through with a bot ([docs/software/SKYWARD.md](docs/software/SKYWARD.md)).

![Skyward Tobi's four courses](reference/skyward_courses.png)

`sdcard/LAMP.PLC` (`src/scripts/gen_lamp.py` and `lamp_code.masm`, with its rooms and tile sets in `sdcard/LAMP/`) is Lamplighter, an original exploration platform game in progress: Wick, a beacon keeper, climbs down through the hollow moon Cairn to relight its great lamp.  Rooms of up to 32 × 16 tiles scroll both ways at 160 × 112, 4 bpp, and join at their edges into a world that branches from a central shaft; a room is a 1 KB file read from the card as Wick enters it.  The playfield is redrawn every frame, tile row by tile row just behind the beam, each tile one jump into unrolled code, and compiled sprites go over it.  Stage 1 is the engine and six rooms: walking, jumping, crawling through ducts, a lantern that fires sparks, doors that open to a shot.  Run it from the DOS's file browser (arrow keys or SNES pad 1; Z, Space or pad B to jump, X or pad Y to fire, Down to crawl).  `test_lamp_sim.py` plays it with a bot that plans its route by searching a Python model of the rules, and compares the program with that model on every frame ([docs/software/LAMPLIGHTER.md](docs/software/LAMPLIGHTER.md)).

![Lamplighter's first six rooms](reference/lamp_rooms.png)

## Standard library
`src/scripts/placard_lib.asm` holds subroutines for new programs: 16-bit
arithmetic, multiply and divide, memory fill and copy, random numbers, frame
timing, pixels, a text console with line input, the keyboard, SNES pad,
PS/2 mouse and SD card drivers, a FAT16/FAT32 file reader, a sound driver
and expansion card lookup.  It also sets the calling convention, the
software stack and the zero page variable map (`zeropage.asm`).  See
[docs/software/LIBRARY.md](docs/software/LIBRARY.md).

## Emulator
Open `web/index.html` in a browser to run the PLACARD without hardware: the
32K ROM (or one you load), an SD card (the `sdcard/` folder, a folder of
your own or a card image), the screen, sound, keyboard, mouse and game
controllers, at the real clock rate.  No server is needed.  See
[docs/software/EMULATOR.md](docs/software/EMULATOR.md).

## Building and loading a program
The `build` folder has one Windows batch file per assembly program
(`cpu_test.bat`, `test_video.bat`, `mandelbrot.bat`, `pi_spigot.bat`,
`game_of_life.bat`, `lib_demo.bat`, `io_demo.bat`) and `rom32.bat` for the
released 32K ROM.  The larger demos run from the SD card only.  Each one assembles
`src/scripts/<program>.asm` (customasm, or `placard_sim.py` if customasm is not
on the PATH), writes the RAM initialization files `src/hdl/ram.mem` (main
RAM) and `cart_ram.mem` (cartridge SRAM), random bytes like a real SRAM at
power-up (`gen_random_ram.tcl`), and the cartridge EEPROM image
`src/hdl/rom.mem` (boot loader, standard library and font, and the program,
`gen_rom.tcl`; see [docs/architecture/ROM.md](docs/architecture/ROM.md)), runs
Vivado in batch mode through synthesis, implementation and bitstream, and
programs the Basys 3 over JTAG.  Any other program builds with
`build\build_and_load.bat <program>`.  Add `noasm` (e.g. `cpu_test.bat noasm`)
to skip assembly and use the existing `.hex` file.  Vivado is found on the PATH or under
`C:\AMDDesignTools` / `C:\Xilinx`; set `VIVADO` to the full path of
`vivado.bat` to pick a version.  Logs go to `build/logs`; the Vivado Tcl scripts
behind the batch files are in `build/tcl`.
Add `fast` (e.g. `mandelbrot.bat fast`) to change only the memory contents:
the new `ram.mem`, `cart_ram.mem` and `rom.mem` are written into the last implemented bitstream with
`updatemem` (block RAM map from `build/tcl/write_mmi.tcl`), so synthesis and
implementation are skipped.  It needs one full build first, and a full build
again after any HDL or constraint change.  The first `fast` run after a full
build checks the block RAM map by putting the full build's own image back into
its bitstream; if that does not give the same bitstream it stops with an error.
`build\download_latest.bat` programs the board with the newest bitstream in
`project/placard.runs/impl_1` (`basys_top.bit` or `basys_top_fast.bit`) without
rebuilding.
The batch files play a sound when they finish (`build\ding.bat`): the
Windows "Ding" when the build worked and "Critical Stop" when it failed.
Set `PLACARD_QUIET=1` to turn it off.

### Vivado project
The Vivado project (`project/placard.xpr` and everything else in `project/`)
is not kept in git, because Vivado rewrites the `.xpr` every time it opens it.
`build/tcl/create_project.tcl` makes it from the sources in `src/`, with the
part, file list, testbench and run settings.  The first build makes it by
itself; to open the project in the GUI after a fresh clone, run
`build\create_project.bat` once.  Every `.vhd` file in `src/hdl` is a design
source, so after adding or removing one run `build\create_project.bat force`.
Testbenches and other settings are listed in `create_project.tcl`; change them
there, because a change made only in the GUI is lost the next time the project
is made.
`src/hdl/ram.mem`, `cart_ram.mem` and `rom.mem` are not kept in git either; every
build makes them, and `create_project.tcl` makes the default images if they
are missing.  A project made before the ROM had its own file lists
`video_ram.mem`; the next build swaps it for the new files, or run
`build\create_project.bat force`.

## License
Placard is open hardware and open software.  Each kind of work has the license written for it:

| Part | License |
|------|---------|
| Hardware: the KiCad boards and schematics (`kicad/`, `schematics/`), the PLD equations and VHDL (`src/pld/`, `src/hdl/`, `src/sim/`) and the case (`case/`) | [CERN-OHL-S v2](LICENSES/CERN-OHL-S-2.0.txt) |
| Software: the ROM, BASIC, DOS, demos, games, tools and emulator (`src/scripts/`, `src/music/`, `sdcard/`, `web/`, `build/`) | [GPL v3 or later](LICENSES/GPL-3.0-or-later.txt) |
| Documentation and images (`README.md`, `docs/`, `reference/`) | [CC BY-SA 4.0](LICENSES/CC-BY-SA-4.0.txt) |

All three are share-alike: you may build, change and sell the design, and you pass your changes on under the same license.  A program you write for the Placard, loaded from the SD card or a cartridge, is your own work under any license you choose.  [LICENSE](LICENSE) has the full folder list and the third-party parts (KiCad library copies, the Digilent debouncer, the Inter lettering in the logo).

The PLD's datasheet is not kept here; it is on Microchip's [ATF22V10C product page](https://www.microchip.com/en-us/product/ATF22V10C).
