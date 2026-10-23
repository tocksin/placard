# Software roadmap

Date: 2026-10-23

Programs to write for the Placard, what each needs, and where it fits.
This replaces the program list in [FEATURE_PLAN.md](FEATURE_PLAN.md)
("Software"); the libraries it builds on are in [LIBRARY.md](LIBRARY.md)
and [IO.md](IO.md).  The sizes below are estimates, to be replaced by real
numbers as each program is written.

## The long-term plan

The ROM holds only the essentials: the library (core routines, font, I/O
drivers, FAT, sound), the boot loader, and a small resident program that
can find and load everything else from the SD card.  Other programs are
files on the SD card, loaded into RAM one at a time.  The cartridge can be
32 KB (x8000-xFFFF, mirrored) or 64 KB (ROM.md, "Loading the cartridge"),
so the resident set should fit in **x8000-xBFFF (16 KB)** plus whatever the
library has room for below xC000.

### What the machine gives a program

| Resource | Amount | Notes |
|---|---|---|
| Clock | 25.175 MHz | one frame = 800 × 525 = 420,000 clocks, 59.94 Hz |
| CPU time | about 380,000 clocks a frame | 80 video stall clocks per drawn line (38,400 a frame); blanked rows give them back (VIDEO.md, "Blank line") |
| Native instructions | 2-4 clocks each, about 3 typical | about 125,000 a frame, 7.5 million a second |
| ROM, resident | x8000-xBFFF (16 KB) on a 32 KB cart | plus x2000-x3FFF and x6000-x7FFF on a 64 KB cart |
| RAM for a loaded program | x0100-x1EFF (7.75 KB) and x2000-x3FFF (8 KB, map section 1 to RAM) | about 15.75 KB of code; x1F00-x1FFF is `LIB_RAM` |
| RAM for data | x4000-x4CFF (3.25 KB), x5400-x5A1F, x5C00-x5DF2 | x4D00-x4FFF is the FAT buffer |
| Video RAM freed | 20 KB with an 80 × 28 text screen | see below |

**Text screen versus free RAM.**  The full 80 × 60 console uses all 37.5 KB
of video RAM.  A program that needs memory (editor, assembler, BASIC, CP/M)
can use text rows 0-27 only (1x rows 0-223, which use the low 256 bytes of
each video column) and blank the rest of the screen: that leaves the high
256 bytes of every column free, 80 pages (x61, x63 ... xFF), 20 KB, and the
blanked lines give back about 20,000 clocks a frame.  The pages are not
contiguous, so programs keep their data in 256-byte pages through a page
list.  Reading them needs sections 3-7 mapped to RAM, so that code runs
from RAM (as `plot1` and `con_scroll` do), not from ROM x6000-xFFFF.

## Missing pieces in the library

| Piece | Needed by | Size | Notes |
|---|---|---|---|
| FAT write | DOS, editor, assembler, BASIC SAVE | 3-4 KB | create, write, extend, delete, rename, make folder; update both FATs.  `sd_write` (raw blocks) already exists.  The library has no free pages, so this goes below xC000. |
| Program file format | DOS, loader, every SD program | small | a header like the expansion card's ("PLC", type, load address, length, entry, checksum), so the loader knows where a file goes and whether it is a RAM program or data |
| Faster scroll / partial redraw | editor, monitor, BASIC | 0.5-1 KB | `con_scroll` takes 46 ms for the full 60 rows; an editor redraws only changed lines and scrolls a 28-row window (about half the time) |

## Programs

### 1. Monitor (resident, ROM)

Examine and change memory, hex dump, fill, copy, compare, jump to an
address, load and save memory ranges to SD files, and a disassembler built
from the opcode table (`reference/opcode_map.html`).  It is the first
program to write, because everything after it is debugged with it.

- Needs: console, keyboard (`kbd_getc`, `con_gets`), FAT read; FAT write for
  "save".
- Size: 3-5 KB, plus 1.5-2 KB for the disassembler.  RAM: a line buffer.
- Fits in the resident 16 KB together with the DOS below.

### 2. DOS: SD card command line (resident, ROM)

One command line that joins the monitor, the SD loader and the boot menu:
`DIR`, `CD`, `TYPE`, `COPY`, `DEL`, `REN`, `MD`, `RD`, `RUN` (or just a
program's name), `BOOT` (pick what starts at power-up), plus the monitor's
commands.  A file browser (cursor keys or pad) can be a mode of it.

- Needs: FAT write, the program file format, console, keyboard.
- Size: 3-5 KB on top of the library's FAT write.  Monitor + DOS + loader
  together: about 10-12 KB, inside x8000-xBFFF.
- Remembers the boot choice in a small file on the card (`BOOT.CFG`); a key
  held at power-up skips it.

### 3. Text editor (SD program)

A full-screen editor for assembly source: 80 × 28 window, cursor keys,
insert/delete, line join/split, search, go to line, load/save, and maybe
cut/paste of a line range.

- Needs: keyboard (both the matrix and PS/2 keyboards), console, FAT read
  and write, faster redraw.
- Code: 4-6 KB.  Text buffer: the 20 KB of freed video pages plus
  x4000-x4CFF, about 23 KB of text, as a list of 256-byte pages holding
  lines (a gap per page) so inserting never moves the whole file.
- Files bigger than that are split with `#include`.

### 4. Assembler (SD program)

A native assembler for the Placard's own syntax, the subset of the
customasm rules the repo uses: labels, `NAME = value`, `#addr`, `#d`
(bytes and strings), `#include`, expressions with `+ - * / & | ^ >> <<`,
`>>8` and `&0xFF` for address halves.  Two passes, reading the source from
SD each pass, writing a program file (or a raw binary) to SD.  It warns
about a branch that leaves its page, like `placard_sim.py`.

- Needs: FAT read and write, console for errors, the library's jump table
  names (an include file with the `jt_` addresses, which never change).
- Code: 6-8 KB.  Symbol table: about 12 bytes a symbol, so 1,000-1,500
  symbols in 12-18 KB of freed video pages.
- Speed: the SD card reads 75 KB/s and parsing costs a few hundred native
  instructions a line, so a 20 KB source assembles in a few seconds.
- With the editor this makes the machine self-hosting.  Editor and
  assembler can later share one program (edit, assemble, run, back to the
  editor) if the memory allows.

### 5. BASIC (SD program, or ROM on a 64 KB cart)

A 16-bit integer BASIC in the style of Tiny BASIC or Apple Integer BASIC:
line numbers, `PRINT`, `INPUT`, `IF`, `GOTO`, `GOSUB`, `FOR`, arrays,
strings, `PEEK`, `POKE`, `CALL`, `LOAD`, `SAVE`, `DIR`.  Placard extras:
`PLOT`, `LINE`, `MODE` (row colour mode and repeat), `TINT`, `PAD`,
`SOUND`, `WAIT` (frames).  Floating point later, probably as a library of
its own.

- Needs: console, keyboard, FAT read and write, sound, pixel routines
  (`plot1`, and the 2/4/8 bpp plots still to write).
- Code: 6-10 KB (integer), 3-4 KB more for floating point.  Program space:
  the freed video pages, about 20 KB, or more when a program draws in 2x/4x
  rows.
- Speed: a tokenised interpreter should do a few thousand simple
  statements a second, ahead of the 1 MHz home computers' BASICs.

### 6. Console emulator: CHIP-8 and SUPER-CHIP (SD program)

The realistic console emulator.  CHIP-8 is a small virtual machine made for
hobby games (35 opcodes, 64 × 32 display, 16 keys, two 60 Hz timers);
SUPER-CHIP adds 128 × 64 and scrolling.  Hundreds of free games exist.

- Needs: keyboard or SNES pad, sound (`snd_beep`), FAT read for the game
  files, a file picker.
- Code: 2-3 KB.  RAM: 4 KB for the machine.
- Speed: games run 500-1,000 CHIP-8 instructions a second; at 50-100 native
  instructions each that is about 5 % of the CPU.  Each CHIP-8 pixel can be
  one whole byte of a 1 bpp row (8 pixels wide) with 4x line repeat, so
  drawing is just storing 00 or FF.
- Runs at full speed with room to spare: a good first emulator.

### 7. CP/M emulator (SD program)

An 8080 emulator with the BDOS and BIOS written natively (CP/M's calls to
address 0005 and the BIOS jump table trap into Placard code), so the 8080
memory holds only the program area.  Disks are disk image files on the SD
card, read and written block by block in place (the image is made full
size on a PC, so the FAT never has to grow it).

- Needs: FAT read, `sd_write` into an existing file, console with a 24-line
  terminal (ADM-3A or VT52 codes), keyboard.
- Code: the 8080 core, BDOS and BIOS, 10-14 KB, run from RAM x0100-x3FFF so
  sections 3-7 can stay mapped to RAM while the 8080 runs.
- 8080 memory: through a page table (the 8080's high address byte picks a
  Placard page), from the freed video pages and x4000-x4CFF: about 26-30 KB
  of TPA.  Enough for many CP/M programs (Microsoft BASIC-80, small
  assemblers and editors); some want 48 KB or more and will not run.
- Speed: about 40-50 native instructions per 8080 instruction, so about
  150,000-190,000 8080 instructions a second, roughly a 1-1.3 MHz 8080.
  Usable, a bit slower than a real 2 MHz CP/M machine.
- A RAM expansion card (a banked 128 KB SRAM behind a slot's I/O window)
  would give a full 64 KB TPA later; not designed.
- The BDOS and BIOS are our own code, so no Digital Research code has to
  ship; the CP/M programs themselves come from disk images.
- Z80 instead of 8080 (most later CP/M software) costs more decode work
  and about 20-30 % more time per instruction.

### Possible later: a 6502 machine (Apple 1 style)

The same approach for a 6502: about 35-45 native instructions per 6502
instruction gives roughly a 0.5 MHz 6502.  An Apple 1 (40 × 24 terminal,
keyboard, 8-32 KB RAM) is the simplest target that runs real software
(Woz Monitor, Integer BASIC; check the licence of any ROM image).  Lower
priority than CP/M, which has more useful software.

## Atari 2600: not feasible at full speed

The 2600 is cheap for a real 2600 because its video chip (the TIA) does the
pixel work in hardware.  An emulator has to do the TIA's work in software
as well as the 6507's, and keep the two in step to the cycle, because
2600 games "race the beam": they rewrite the TIA's registers in the middle
of a line to change the playfield, move sprites and change colours.

**What one 2600 frame needs:**

| Job | Work | Placard clocks |
|---|---|---|
| 6507 | 262 lines × 76 cycles = 19,912 cycles; about 4,000-6,000 instructions executed (the rest is waiting in WSYNC) | 5,000 × ~40 native × 3 = **about 600,000** |
| TIA picture | 192 lines × 160 pixels: playfield, 2 sprites, 2 missiles, ball, priorities, 15 collision bits, writes split at their colour clock | at least ~5 native per output byte plus ~150 per line: **about 320,000** |
| TIA sound | 2 channels of polynomial counters, one sample a line | about 15,000 |
| **Total** | | **about 935,000** |
| Placard has | | **about 380,000** |

So even a carefully written emulator runs about **2.5 times too slow**: a
game would play at about 40 % speed (24 frames a second instead of 60),
with its music slowed to match.  That is a best case; cycle-exact sprite
positioning (`RESPx`, `HMOVE` and its comb), collisions for every pixel and
bank switching add to it, and the first version would likely be 4-8 times
too slow.

The picture is a second problem: the 2600 has 128 colours at 160 pixels
across.  The Placard's 4 bpp rows are 160 across but a fixed 16-colour
palette, and its 8 bpp rows have 256 colours but only 80 pixels across.

**Verdict:** a slow-motion demo of a simple 4 KB game is possible as a
stunt, but a usable 2600 emulator is not; it is left off the list.
Realistic instead:

- CHIP-8 / SUPER-CHIP (program 6), at full speed.
- **Native 2600-style games**: the Placard is far faster than a 2600 when
  it runs its own code (the side-scroller and ray caster already run at
  60 frames a second).  Remakes of 2600 classics written in Placard code,
  or a "fantasy console" (a small sprite and tile engine in the library
  plus a game file format loaded from SD), give the same games at full
  speed and in colour.

## Order

1. FAT write and the program file format (library).
2. Monitor and DOS, resident in ROM (with the SD loader and boot choice).
3. Text editor.
4. Assembler (the machine is then self-hosting).
5. BASIC.
6. CHIP-8 / SUPER-CHIP.
7. CP/M (8080).
8. Later: a 6502 machine, native games or a fantasy console engine.

Each program gets a Python model and a `placard_sim.py` test like the
library and the demos, and the ROM layout in ROM.md is updated when the
resident set moves into x8000-xBFFF.
