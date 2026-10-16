# ROM layout and boot

The ROM and the RAM have their own initialization files in the FPGA model:
`src/hdl/ram.mem` (made by `src/scripts/gen_video_ram.tcl`, the video test
pattern) and `src/hdl/rom.mem` (made by `src/scripts/gen_rom.tcl`).  Both use
`sp_ram.vhd`, which takes the file name as the generic `initFile`.  Programs
and the standard library live in the ROM.

Date: 10/16/2026

## Video always reads the RAM

The memory control PLD (revision 04) enables the RAM for every video read,
whatever the map says; only CPU reads follow the ROM/RAM map.  So the ROM
under the video area (x6000-xFFFF, 40 KB) holds programs that run in place
while the screen shows the RAM.  A program that wants to read the video RAM
maps that section to RAM for the read and back afterwards (`plot1` and
`con_scroll` do this).  Writes always go to the RAM, so drawing needs no map
change.

## ROM map

| ROM address | Contents | Made from |
|-------------|----------|-----------|
| x0000-x0003 | Reset jump to the boot loader (PC starts at 0000) | `rom_boot.asm` |
| x0004-x2FFF | Free | |
| x3000-x37FF | Standard library code (`LIB_CODE`), runs in place | `rom_lib.asm` |
| x3800-x3FFF | Standard font (`LIB_FONT`) | `rom_lib.asm` |
| x4000-x4FFF | Free (section 2 reads RAM while a program runs) | |
| x5000-x5FFF | I/O window, the ROM is never read here | |
| x6000-xFBFF | Program, runs in place, entry at x6000 | the program |
| xFC00 | Boot mode: 00 = ROM program, 01 = RAM image | `gen_rom.tcl` |
| xFD00-xFD57 | Boot loader | `rom_boot.asm` |
| xFE00-xFE07 | Map switch (RAM image boot only) | `rom_boot.asm` |

## Map while a program runs

The boot loader writes map = **05**:

| Section | Address | Reads | Holds |
|---------|---------|-------|-------|
| 0 | x0000-x1FFF | RAM | Zero page, program variables and buffers |
| 1 | x2000-x3FFF | ROM | Standard library and font |
| 2 | x4000-x4FFF | RAM | Program data x4000-x49FF and x4C00-x4DF2, mode bytes, audio buffer |
| 3-7 | x6000-xFFFF | ROM | Program code and tables (the video still shows the RAM) |

`MAP_SHADOW` (x07) is set to 05.  A routine that changes the map must keep
its own section's bit (the fetch after a map write uses the old map) and put
the map back to `MAP_SHADOW` before it returns.  The library runs in section
1 and the program in 3-7, so the library can switch the video sections
freely.

## Standard places

| What | Address | Defined in |
|------|---------|------------|
| Zero page variables | RAM x0004-x00FF | `zeropage.asm` |
| Program variables and buffers | RAM x0100-x1FFF, x4000-x49FF, x4C00-x4DF2 | the program |
| Library code | ROM x3000-x37FF | `LIB_CODE` in `placard_lib.asm` |
| Font (8x8, printable ASCII) | ROM x3800-x3FFF | `LIB_FONT` in `placard_lib.asm` |
| Program entry | ROM x6000 | the program (`#addr 0x6000`) |
| Program code and tables | ROM x6000-xFBFF | the program |
| Mode bytes | RAM x4A20-x4BFF | video hardware |
| Audio buffer | RAM x4DF3-x4FFF | video hardware |
| Video | RAM x6000-xFFFF | video hardware |

The library will grow and its routines move while it is developed, so a
program is assembled with the current `placard_lib.asm` (it includes it)
rather than calling fixed numbers.  The block it lives in and the font
address stay put.  Programs use the library routines and the zero page map.

A ROM program can't keep variables in its own code area: put them in the
zero page (x20-xBF) or the RAM areas above, and set them in code at the
start (the RAM is random at power-up).  Tables and strings stay in the ROM
with the code.

```
#include "placard.asm"
#include "placard_lib.asm"

count = 0x20                    ; variables: zero page x20-xBF

#addr 0x6000
main:
    ld   STACK_TOP, ac          ; set up the stack first
    ld   ac, [SP]
    ...
```

## Boot

`src/scripts/rom_boot.asm`.  The map clears to all ROM at power-up, so the
first fetch is ROM x0000, which jumps to the boot loader at xFD00.  It reads
the boot mode byte at xFC00.

**ROM program (00):** write map = 05 and `MAP_SHADOW` = 05, then jump to
x6000.  The boot loader runs in section 7, which stays ROM, so no copy is
needed.  The program starts a few clocks after reset.

**RAM image (01):** for the older demos (pi spigot, Mandelbrot, game of life,
CPU test, test_video), which were written to run from RAM x0000 and keep
code and variables mixed there.  `gen_rom.tcl` stores such a program at ROM
x6000-xA9FF (ROM address = RAM address + x6000, the library again at its RAM
x3000) and the boot loader:

1. writes map = 01, so the zero page reads RAM for its two page counters;
2. copies RAM pages x01-x49 from ROM x6100-xA9FF, then page x00 last;
3. copies the map switch (xFE00-xFE07) into the RAM under it, because the
   fetch right after a map write still uses the old map (xFE00-xFE1F is
   the first 32 bytes of byte column 79, which never show on the screen);
4. writes map = FF and jumps to RAM x0000.

The copy takes about 21 ms.  It does not set `MAP_SHADOW`, because those
programs keep code there.

`gen_rom.tcl` treats a program as a RAM image when its hex has any byte
below x6000 other than the library's own bytes; otherwise it is a ROM
program.

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
