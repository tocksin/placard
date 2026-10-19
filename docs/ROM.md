# ROM layout and boot

The ROM and the RAM have their own initialization files in the FPGA model:
`src/hdl/ram.mem` (made by `src/scripts/gen_video_ram.tcl`, the video test
pattern) and `src/hdl/rom.mem` (made by `src/scripts/gen_rom.tcl`).  Both use
`sp_ram.vhd`, which takes the file name as the generic `initFile`.  Programs
and the standard library live in the ROM.

Date: 10/19/2026

## Video always reads the RAM

The memory control PLD (revision 04) enables the RAM for every video read,
whatever the map says; only CPU reads follow the ROM/RAM map.  So the ROM
under the video area (x6000-xFFFF, 40 KB) holds programs that run in place
while the screen shows the RAM.  A program that wants to read the video RAM
maps that section to RAM for the read and back afterwards (`plot1` and
`con_scroll` do this).  Writes always go to the RAM, so drawing needs no map
change.

## ROM map

The library is one block at the top of the ROM, under the boot loader,
with the most used parts highest: the jump table, then the core routines,
the font, the I/O drivers and the rest.  It grows down into xC000-xC5FF.

| ROM address | Contents | Made from |
|-------------|----------|-----------|
| x0000-x0003 | Reset jump to the boot loader (PC starts at 0000) | `rom_boot.asm` |
| x0004-x1EFF | Free | |
| x1F00-x1FFF | `LIB_RAM`: library code the boot copies to RAM x1F00 (the end of `plot1`, `con_scroll`) | `rom_lib.asm` |
| x2000-x3FFF | Program, more code and tables (runs in place) | the program |
| x4000-x4FFF | Free (section 2 reads RAM while a program runs) | |
| x5000-x53FF | I/O window, the ROM is never read here | |
| x5400-x5FFF | Free (section 2 reads RAM while a program runs) | |
| x6000-xBFFF | Program, runs in place, entry at x6000 | the program |
| xC000-xC5FF | Free, for the library to grow into | |
| xC600-xC6FF | Expansion slot helpers (`SLOT_CODE`): `slot_id` | `rom_lib.asm` |
| xC700-xD4FF | FAT file reader (`FS_CODE`) | `rom_lib.asm` |
| xD500-xD6FF | Line input and mouse pointer (`INPUT_CODE`): `con_gets`, `mouse_move` | `rom_lib.asm` |
| xD700-xDBFF | Sound driver (`SND_CODE`) | `rom_lib.asm` |
| xDC00-xEBFF | I/O drivers (`IO_CODE`): keyboard, pads, SD card, mouse ([IO.md](IO.md)) | `rom_lib.asm` |
| xEC00-xF3FF | Standard font (`LIB_FONT`) | `rom_lib.asm` |
| xF400-xFAFF | Standard library core routines (`LIB_CODE`) | `rom_lib.asm` |
| xFB00-xFBFF | Jump table (`LIB_JT`), 54 of 64 entries used ([LIBRARY.md](LIBRARY.md#jump-table)) | `rom_lib.asm` |
| xFC00 | Boot mode: 00 = ROM program, 01 = RAM image | `gen_rom.tcl` |
| xFD00-xFD7E | Boot loader | `rom_boot.asm` |
| xFE00-xFE07 | Map switch (RAM image boot only) | `rom_boot.asm` |
| xFE08-xFEA1 | Expansion card scan | `rom_boot.asm` |

## Map while a program runs

The boot loader writes map = **05**:

| Section | Address | Reads | Holds |
|---------|---------|-------|-------|
| 0 | x0000-x1FFF | RAM | Zero page, program variables and buffers, `LIB_RAM` at x1F00 |
| 1 | x2000-x3FFF | ROM | Program code and tables |
| 2 | x4000-x4FFF, x5400-x5FFF | RAM | Program data x4000-x4CFF, SD/FAT buffers x4D00-x4FFF, x5400-x5A1F and x5C00-x5DF2, mode bytes, audio buffer |
| 3-5 | x6000-xBFFF | ROM | Program code and tables (the video still shows the RAM) |
| 6-7 | xC000-xFFFF | ROM | The library and the boot loader |

`MAP_SHADOW` (x07) is set to 05.  A routine that changes the map must keep
its own section's bit (the fetch after a map write uses the old map) and put
the map back to `MAP_SHADOW` before it returns.  Sections 6 and 7 must read
ROM whenever the library is called.  The library code that reads the video
RAM (the end of `plot1`, and `con_scroll`) maps sections 3-7 to RAM, so it
runs from `LIB_RAM` in the RAM at x1F00-x1FFF, which the boot copies there
first; programs must leave x1F00-x1FFF alone.

## Standard places

| What | Address | Defined in |
|------|---------|------------|
| Zero page variables | RAM x0004-x00FF | `zeropage.asm` |
| Program variables and buffers | RAM x0100-x1EFF, x4000-x4CFF, x5400-x5A1F, x5C00-x5DF2 | the program |
| Library RAM code | RAM x1F00-x1FFF | `LIB_RAM` in `placard_lib.asm` |
| Jump table | ROM xFB00-xFBFF | `LIB_JT` in `placard_lib.asm` |
| Library core routines | ROM xF400-xFAFF | `LIB_CODE` in `placard_lib.asm` |
| Font (8x8, printable ASCII) | ROM xEC00-xF3FF | `LIB_FONT` in `placard_lib.asm` |
| I/O drivers | ROM xDC00-xEBFF | `IO_CODE` in `placard_lib.asm` |
| Sound driver | ROM xD700-xDBFF | `SND_CODE` in `placard_lib.asm` |
| Line input, mouse pointer | ROM xD500-xD6FF | `INPUT_CODE` in `placard_lib.asm` |
| FAT file reader | ROM xC700-xD4FF | `FS_CODE` in `placard_lib.asm` |
| Expansion slot helpers | ROM xC600-xC6FF | `SLOT_CODE` in `placard_lib.asm` |
| SD/FAT variables and sector buffer | RAM x4D00-x4FFF | `FS_VARS`, `FS_BUF` in `placard_fs.asm` |
| Program entry | ROM x6000 | the program (`#addr 0x6000`) |
| Program code and tables | ROM x6000-xBFFF and x2000-x3FFF | the program |
| Mode bytes | RAM x5A20-x5BFF | video hardware |
| Audio buffer | RAM x5DF3-x5FFF | video hardware |
| Video | RAM x6000-xFFFF | video hardware |

A program is assembled with the current `placard_lib.asm` (it includes it)
and may call the routines directly.  Code built without it (a card's boot
code, a program loaded from the SD card) calls the jump table entries,
whose addresses never change.  Programs use the library routines and the zero page map.

A ROM program can't keep variables in its own code area: put them in the
zero page (x20-x8F) or the RAM areas above, and set them in code at the
start (the RAM is random at power-up).  Tables and strings stay in the ROM
with the code.

```
#include "placard.asm"
#include "placard_lib.asm"

count = 0x20                    ; variables: zero page x20-x8F

#addr 0x6000
main:
    ld   STACK_TOP, ac          ; set up the stack first
    ld   ac, [SP]
    ...
```

## Boot

`src/scripts/rom_boot.asm`.  The map clears to all ROM at power-up, so the
first fetch is ROM x0000, which jumps to the boot loader at xFD00.  Its
first job is to copy `LIB_RAM` (ROM x1F00-x1FFF) into the RAM under it,
while the map is still 00 (reads from ROM, writes to RAM), about 3,000
clocks.  It reads the boot mode byte at xFC00 after the expansion card scan
below.

**Expansion card scan (Apple II style):** the boot writes map = 01 (the
zero page reads RAM) and, unless Esc is held, looks at slots 4, 3, 2 and 1.
A card whose first bytes are "PLC", card ID, code length n (1-90) and a
checksum (the sum of the n code bytes) has its code copied to RAM x0100 and
called with AC = slot number, R1:R0 = the slot's base address, SP = FE and
`MAP_SHADOW` = 01.  The code returns to go on with the scan and the normal
boot, or never returns to take the boot over.  An empty slot reads FF and
fails the check.  [EXPANSION.md](EXPANSION.md) has the header and rules.

**ROM program (00):** write map = 05 and `MAP_SHADOW` = 05, then jump to
x6000.  The boot loader runs in section 7, which stays ROM, so no copy is
needed.  The program starts a few clocks after reset.

**RAM image (01):** for the older demos (pi spigot, Mandelbrot, game of life,
CPU test, test_video), which were written to run from RAM x0000 and keep
code and variables mixed there and don't use the library.  `gen_rom.tcl`
stores such a program at ROM x6000-xA9FF (ROM address = RAM address +
x6000) and the boot loader:

1. writes map = 01, so the zero page reads RAM for its two page counters;
2. copies RAM pages x01-x49 from ROM x6100-xA9FF, then page x00 last;
3. copies the map switch (xFE00-xFE07) into the RAM under it, because the
   fetch right after a map write still uses the old map (xFE00-xFE1F is
   the first 32 bytes of byte column 79, which never show on the screen);
4. writes map = FF and jumps to RAM x0000.

The copy takes about 21 ms.  It does not set `MAP_SHADOW`, because those
programs keep code there.

`gen_rom.tcl` treats a program as a RAM image when its hex has any byte in
x0000-x1FFF or x4000-x5FFF other than the library's own bytes; otherwise it
is a ROM program, with its bytes in x2000-x3FFF and x6000-xBFFF.

## Building

`build\build_and_load.bat <program>` assembles `rom_boot.asm`, `rom_lib.asm`
and the program, then makes `ram.mem` and `rom.mem`.  The `fast` path puts
both files into the last bitstream with `updatemem` (`ramComp` gets
`ram.mem`, `romComp` gets `rom.mem`).  By hand:

```
customasm rom_boot.asm -f hexstr -o rom_boot.hex
customasm rom_lib.asm  -f hexstr -o rom_lib.hex
customasm lib_demo.asm -f hexstr -o lib_demo.hex
tclsh gen_video_ram.tcl
tclsh gen_rom.tcl          # ::ASM_FILE = the program's hex, default test_video.hex
```

`placard_sim.py` runs a program from the ROM image like the board does:

```
python3 placard_sim.py lib_demo.asm --run --png demo.png
```

`--boot` (automatic for a ROM program) builds the same ROM image as
`gen_rom.tcl` (`build_rom` in `placard_sim.py`), starts with an empty RAM and
the map at 00, and follows the map on every CPU read.  The simulator doesn't
model video reads; `--png` draws the RAM.

## Changing the layout

The constants are in three places, which must agree: `rom_boot.asm`
(`ROM_IMAGE`, `IMAGE_END`, `MAP_ROM_RUN`, `PROG_START`, `BOOT_MODE`),
`gen_rom.tcl` and `placard_sim.py` (`ROM_IMAGE_BASE`, `IMAGE_SIZE`,
`LIB_START`, `LIB_END`, `PROG_START`, `PROG_END`, `BOOT_MODE`).
