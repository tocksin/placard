# ROM layout and boot

The ROM and the RAM have their own initialization files in the FPGA model:
`src/hdl/ram.mem` (made by `src/scripts/gen_video_ram.tcl`, the video test
pattern) and `src/hdl/rom.mem` (made by `src/scripts/gen_rom.tcl`).  Both use
`sp_ram.vhd`, which takes the file name as the generic `initFile`.  Programs
and the standard library live in the ROM from now on.

Date: 10/16/2026

## Why the upper ROM

Writes always go to the RAM, and the video reads x6000-xFFFF through the
ROM/RAM map, so once a program runs, those sections are mapped to RAM and the
ROM underneath them is never read.  That 40 KB of ROM is where programs and the
library are stored.  They can't run there (the screen would show the ROM), so
the boot loader copies them into the RAM at power-up.

## ROM map

| ROM address | Contents | Copied to RAM | Made from |
|-------------|----------|---------------|-----------|
| x0000-x0003 | Reset jump to the boot loader (PC starts at 0000) | | `rom_boot.asm` |
| x0004-x4FFF | Free | | |
| x5000-x5FFF | I/O window, the ROM is never read here | | |
| x6000-x8FFF | Program, RAM x0000-x2FFF | x0000-x2FFF | the program |
| x9000-x97FF | Standard library code (`LIB_CODE`) | x3000-x37FF | `rom_lib.asm` |
| x9800-x9FFF | Standard font (`LIB_FONT`) | x3800-x3FFF | `rom_lib.asm` |
| xA000-xA9FF | Program, RAM x4000-x49FF | x4000-x49FF | the program |
| xAA00-xFCFF | Free (more programs and data later) | | |
| xFD00-xFD5F | Boot loader | | `rom_boot.asm` |
| xFE00-xFE07 | Map switch (the boot loader's last 4 instructions) | xFE00-xFE07 | `rom_boot.asm` |
| xFE08-xFFFF | Free | | |

x6000-xA9FF is the **RAM image**: ROM address = RAM address + x6000.  A
program is assembled at its RAM address as before (reset code at x0000,
`main` at x0100) and `gen_rom.tcl` stores it in the image.

## Standard places

These stay the same for every program, so programs share them:

| What | RAM address | Where it is defined |
|------|-------------|---------------------|
| Program reset code | x0000-x0003 | the program (`ld main >> 8, y` / `jmp main`) |
| Zero page variables | x0004-x00FF | `zeropage.asm` |
| Program code and data | x0100-x2FFF, x4000-x49FF | the program |
| Library code | x3000-x37FF | `LIB_CODE` in `placard_lib.asm` |
| Font (8x8, printable ASCII) | x3800-x3FFF | `LIB_FONT` in `placard_lib.asm` |
| Mode bytes | x4A20-x4BFF | video hardware |
| Program buffers (not loaded from ROM) | x4C00-x4DF2 | the program |
| Audio buffer | x4DF3-x4FFF | video hardware |
| Video | x6000-xFFFF | video hardware |

The library will grow and its routines move while it is developed, so a
program is always assembled with the current `placard_lib.asm` (it includes
it) rather than calling fixed numbers.  The block it lives in, x3000-x3FFF,
and the font address stay put.

`gen_rom.tcl` puts the library in first and the program over it.  A program
that includes `placard_lib.asm` writes the same bytes there.  The older demos
(pi spigot, Mandelbrot, game of life, CPU test) predate the library and use
x3000-x3FFF for themselves; for them the image holds their bytes and
`gen_rom.tcl` prints a note.  New programs use the library and the zero page
map.

## Boot

`src/scripts/rom_boot.asm`:

1. The map clears to all ROM at power-up, so the first fetch is ROM x0000,
   which jumps to the boot loader at xFD00.
2. It writes map = 01, so section 0 (the zero page) reads RAM.  It runs in
   section 7, whose map bit doesn't change, so the next fetch is safe.
3. It copies RAM pages x01-x49 from ROM x6100-xA9FF, keeping its two page
   counters in the RAM's zero page (xFE, xFF), then page x00 from ROM
   x6000-x60FF last, so the zero page ends up exactly as the program's
   image.
4. It copies the map switch (xFE00-xFE07) into the RAM under it.  The fetch
   right after a map write uses the old map for that one instruction (see
   the [memory map](README.md#memory-map)), so the bytes after the write must
   be the same in both memories.  xFE00-xFE1F is the first 32 bytes of byte
   column 79, which the video reads only in vertical blanking, so they never
   show.
5. The map switch writes map = FF (every section reads RAM) and jumps to RAM
   x0000, the program's reset code.

The copy takes 25 clocks a byte, so the program starts about 21 ms after
reset (with the video's stall clocks).  The RAM's own contents are kept
outside the image: the video area, the mode bytes and the audio buffer, which
on the real board are random at power-up.  `con_clear` or `vid_clear` sets
them.

The boot loader does not set `MAP_SHADOW` (x07), because the older demos keep
code there.  A program that calls `map_set` stores FF in `MAP_SHADOW` first.
The boot leaves the map register's page (x5000, x5008) and xFE00-xFE07 written
in the RAM.

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

`placard_sim.py` assembles the same files (`python3 placard_sim.py
rom_boot.asm`) and runs a program from the ROM image like the board does:

```
python3 placard_sim.py lib_demo.asm --run --boot --png demo.png
```

`--boot` builds the same ROM image as `gen_rom.tcl` (`build_rom` in
`placard_sim.py`), starts with an empty RAM and the map at 00, and follows
the map on every read.  Without it the simulator runs the program from one
flat memory, as before.

## Changing the layout

The constants are in three places, which must agree: `rom_boot.asm`
(`ROM_IMAGE`, `IMAGE_END`), `gen_rom.tcl` (`ROM_IMAGE_BASE`, `IMAGE_SIZE`,
`LIB_START`, `LIB_END`) and `placard_sim.py` (`ROM_IMAGE_BASE`, `IMAGE_SIZE`,
`LIB_START`, `LIB_END`).  If the RAM map changes (for example to free RAM
for programs), change the image size there and the table above.
