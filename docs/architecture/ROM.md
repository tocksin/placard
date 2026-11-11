# ROM layout and boot

Each memory has its own initialization file in the FPGA model:
`src/hdl/rom.mem` (made by `src/scripts/gen_rom.tcl`) is the ROM
cartridge's EEPROM image, and `src/hdl/ram.mem` (the main RAM) and
`cart_ram.mem` (the cartridge SRAM) are random bytes from
`src/scripts/gen_random_ram.tcl`, as a real SRAM powers up.  All use
`sp_ram.vhd`, which takes the file name as the generic `initFile`; the
cartridge model is `src/hdl/cartridge.vhd`.  Programs and the standard
library live in the ROM.

Date: 2026-11-11

The ROM that ships is the **32K image** (x8000-xFFFF: boot loader, library,
card loader, BASIC and the FAT writer, "The 32K image" below).  It is the
only release; programs come from the SD card.  A **development ROM** is the
same 32K in the upper half of a 64K ROM with one program in the lower half
("Development ROMs" below); `build\<program>.bat` builds one for the FPGA.

## Video always reads the RAM

The memory control PLD enables the RAM for every video read,
whatever the map says; only CPU reads follow the ROM/RAM map.  So the ROM
under the video area (x6000-xFFFF, 40 KB) holds programs that run in place
while the screen shows the RAM.  A program that wants to read the video RAM
maps that section to RAM for the read and back afterwards (`plot1` and
`con_scroll` do this).  Writes always go to the RAM, so drawing needs no map
change.

## ROM map

The 32K image is laid out by ROM section (the 8 KB pieces the map register
switches between ROM and RAM), one job to a section, so that a program can
switch a section it does not need to RAM and use the 8 KB:

| Section | Address | Holds | A program that maps it to RAM loses |
|---------|---------|-------|-------------------------------------|
| 7 | xE000-xFFFF | Boot loader, jump table, core routines, keys, pads, mouse, PS/2 keyboard, line input, slots, menu hook | Never: the library is called through here |
| 6 | xC000-xDFFF | Files: SD card driver, FAT reader, FAT writer | Files only |
| 5 | xA000-xBFFF | BASIC (8 KB of it) | BASIC only |
| 4 | x8000-x9FFF | Vectors, card loader, the rest of BASIC, sound driver, standard font, `LIB_RAM`'s bytes | The way back to the DOS (x8008), sound, the standard font |

Section 7 calls sections 6 and 4 only through the jump table (`fs_*`, `sd_*`,
`spi_byte`, `snd_*`), so a program that calls none of those may map them to
RAM.  The font is read through `FONT_PG` (zero page xBF), so a program with
its own font does not need the standard one.

| ROM address | Contents | Made from |
|-------------|----------|-----------|
| x8000-x8004 | nop (for the cartridge hand-off), reset jump to the boot loader: a 32K cartridge shows it at x0000, where the PC starts | `rom_boot.asm` |
| x8005 | Boot mode 02 (read at x0005; see "Development ROMs") | `gen_rom.tcl` |
| x8008-x8027 | Vectors: `dos_back`, `dos_run`, `fs_create`, `fs_write`, `fs_close`, `fs_delete`, `fs_save`, `basic` ([DOS.md](../software/DOS.md#dos-vectors)); x8028-x80FF free for more | `rom32.masm` |
| x8100-x91FF | The card loader (power-up, BOOT.CFG, running `.PLC` files, about 1.5 KB), then the part of BASIC that does not fit in section 5 | `rom32.masm`, `basic.masm`, `basic.vm` |
| x9200-x96FF | Sound driver (`SND_CODE`) | `rom_lib.asm` |
| x9700-x9EFF | Standard font (`LIB_FONT`) | `rom_lib.asm` |
| x9F00-x9FFF | `LIB_RAM`'s bytes: library code the boot copies to RAM x1F00 (the end of `plot1`, `con_scroll`, `memset`'s loop, and `lib_far` at x1FA0); the boot reads them at x1F00 | `rom_lib.asm` |
| xA000-xBFFF | BASIC ([BASIC.md](../software/BASIC.md)); about 1.2 KB free at the end | `basic.masm`, `basic.vm` |
| xC000-xC7FF | SD card driver (`SD_CODE`) ([IO.md](IO.md)) | `rom_lib.asm` |
| xC800-xD5FF | FAT file reader (`FS_CODE`) | `rom_lib.asm` |
| xD600-xD617 | Free (the bring-up ROM's section 6 marker) | |
| xD618-xDFFF | FAT file writer ([DOS.md](../software/DOS.md#the-fat-writer)); it also fills the free ends of the pages xC000-xD5FF (`lib_gaps.py`) | `placard_fsw.masm` |
| xE000-xE2FF | I/O drivers (`IO_CODE`): port, key buffer, pads, key to character | `rom_lib.asm` |
| xE300-xE7FF | PS/2 keyboard driver and listening (`PS2_CODE`): `wait_frames_io` ([IO.md](IO.md)) | `rom_lib.asm` |
| xE800-xE9FF | Line input and mouse pointer (`INPUT_CODE`): `con_gets`, `mouse_move` | `rom_lib.asm` |
| xEA00-xEAFF | Menu hook (`MENU_CODE`): `menu_poll` ([MENU.md](../software/MENU.md)) | `rom_lib.asm` |
| xEB00-xEFFF | I/O drivers: PS/2 bytes, mouse, key tables | `rom_lib.asm` |
| xF000-xF0FF | Expansion slot helpers (`SLOT_CODE`): `slot_id`; `con_dec16` | `rom_lib.asm` |
| xF100-xF19A | PS/2 keyboard tables (`PS2_TAB_CODE`); xF19B-xF3FF free (613 bytes) | `rom_lib.asm` |
| xF400-xFAFF | Standard library core routines (`LIB_CODE`) | `rom_lib.asm` |
| xFB00-xFBFF | Jump table (`LIB_JT`), 57 of 64 entries used ([LIBRARY.md](../software/LIBRARY.md#jump-table)) | `rom_lib.asm` |
| xFC00 | 02: marks `rom32.asm` as the 32K image's program for the tools (the boot does not read it) | `rom32.masm` |
| xFC01-xFCFF | `mul8`'s quarter squares, high bytes (`SQ_HI` + 1) | `lib_sqtab.asm` in `rom_boot.asm` |
| xFD00-xFDF5 | Boot loader | `rom_boot.asm` |
| xFE00-xFE07 | Map switch (RAM image boot only) | `rom_boot.asm` |
| xFE08-xFEA9 | Expansion card scan | `rom_boot.asm` |
| xFF00-xFFFF | `mul8`'s quarter squares, low bytes (`SQ_LO`) | `lib_sqtab.asm` in `rom_boot.asm` |

About 4.7 KB of the 32K is free: 487 bytes in section 4, 1,190 in section
5, 873 in section 6 and 2,126 in section 7 (measured 2026-11-11), mostly
page ends.

## Development ROMs

A development ROM is a 64K ROM for the FPGA or a 64K cartridge: the 32K
image above in x8000-xFFFF, unchanged, and one program in x0000-x7FFF.

| ROM address | Contents |
|-------------|----------|
| x0000-x0004 | nop, reset jump to the boot loader |
| x0005 | Boot mode: 00 = ROM program, 01 = RAM image.  On a 32K cartridge (and in the 32K image's own ROM) the boot reads x8005 here, 02 |
| x1F00-x1FFF | `LIB_RAM`'s bytes |
| x2000-x3FFF | ROM program, more code and tables; or a RAM image's x2000-x3FFF |
| x4000-x49FF | A RAM image's x4000-x49FF |
| x5000-x53FF | I/O window, the ROM is never read here |
| x6000-x7FFF | ROM program, entry at x6000; or a RAM image's x0000-x1FFF |

A program that runs in place therefore has 16 KB (x6000-x7FFF and
x2000-x3FFF).  Until 2026-11-11 it had x6000-xBFFF; the ray casters, the
side scroller, the text demo and the ROM builds of the Boing and wireframe
demos needed that and are card programs only now.

## Cartridge sizes

There are two cartridge boards, and a machine takes either:

- **64K** (`kicad/cartridge_64k`, 5 chips): EEPROMs U2 (x0000-x7FFF,
  `/CE_LO`) and U3 (x8000-xFFFF, `/CE_HI`), SRAMs U4 and U5.  It takes
  the 32K image twice, or a development ROM.
- **32K** (`kicad/cartridge_32k`, 3 chips): one EEPROM U2 and one SRAM U3,
  both always selected (/CE tied to GND), so the same 32K appears at
  x0000-x7FFF and again at x8000-xFFFF.  The loader copies it twice (the
  PC walks all 64K), which needs no change to the loader PLD.

## The 32K image

The 32K image is x8000-xFFFF only ("ROM map" above), so it fits one 32K
EEPROM; `gen_rom.tcl` puts the same 32K in both halves of `rom.mem` (and writes
`src/hdl/rom_32k.bin`, the EEPROM file), so a 64K cartridge with two EEPROMs
takes the same image twice and boots the same way.  Everything below x8000
that the boot needs (the reset code, the boot mode at x0005, `LIB_RAM` at
x1F00) is read through the mirror.

The boot loader copies `LIB_RAM` from x1F00 (the mirror of
x9F00), scans the expansion slots, and for mode 02 writes map 05 and jumps
to the loader at x8100.  The loader runs with map **07**: RAM x0000-x5FFF
for the programs it loads (x0100-x3FFF) and their data (x4000-x5FFF), the
loader, BASIC and the library in ROM x8000-xFFFF.  It starts the DOS
(`DOS.PLC` on the SD card) or BASIC when there is no card
([DOS.md](../software/DOS.md#at-power-up)).  `placard_sim.py rom32.asm` builds the same
image (`build_dos_rom`) and `test_dos.py` runs it.

Programs are `.PLC` files on the SD card ([DOS.md](../software/DOS.md#program-files-plc)):
library programs assembled for RAM x0100-x3FFF (16 KB), or the older RAM
images (x0000-x49FF).  The DOS and the demo menu are two of them
([MENU.md](../software/MENU.md)).

## Map while a program runs

The boot loader writes map = **05**:

| Section | Address | Reads | Holds |
|---------|---------|-------|-------|
| 0 | x0000-x1FFF | RAM | Zero page, program variables and buffers, `LIB_RAM` at x1F00 |
| 1 | x2000-x3FFF | ROM | Program code and tables |
| 2 | x4000-x4FFF, x5400-x5FFF | RAM | Program data x4000-x4CFF, SD/FAT buffers x4D00-x4FFF, x5400-x5A1F and x5C00-x5DF2, mode bytes, audio buffer |
| 3 | x6000-x7FFF | ROM | Program code and tables (the video still shows the RAM) |
| 4-7 | x8000-xFFFF | ROM | The 32K image: the library and the boot loader ("ROM map" above) |

`MAP_SHADOW` (x07) is set to 05.  A routine that changes the map must keep
its own section's bit (the fetch after a map write uses the old map) and put
the map back to `MAP_SHADOW` before it returns.  Section 7 must read ROM
whenever the library is called, section 6 for the file routines, and
section 4 for sound and for text in the standard font.  The library code that reads the video
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
| Font (8x8, printable ASCII) | ROM x9700-x9EFF, or wherever `FONT_PG` (zero page xBF) points | `LIB_FONT` in `placard_lib.asm` |
| I/O drivers | ROM xE000-xE2FF, xEB00-xEFFF; SD card xC000-xC7FF (`SD_CODE`) | `IO_CODE` in `placard_lib.asm` |
| Sound driver | ROM x9200-x96FF | `SND_CODE` in `placard_lib.asm` |
| Line input, mouse pointer | ROM xE800-xE9FF | `INPUT_CODE` in `placard_lib.asm` |
| FAT file reader | ROM xC800-xD5FF | `FS_CODE` in `placard_lib.asm` |
| Expansion slot helpers | ROM xF000-xF0FF | `SLOT_CODE` in `placard_lib.asm` |
| SD/FAT variables and sector buffer | RAM x4D00-x4FFF | `FS_VARS`, `FS_BUF` in `placard_fs.asm` |
| Program entry | ROM x6000 | the program (`#addr 0x6000`) |
| Program code and tables (development ROM) | ROM x6000-x7FFF and x2000-x3FFF | the program |
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

## Loading the cartridge

The ROM the CPU sees is two AS7C256C-15PCN SRAMs (15 ns) on the
cartridge.  They lose their contents at power-off, so the image is kept
in two AT28C256-15PU EEPROMs (32K x 8, 150 ns, PDIP-28, reprogrammable,
programmed off the board) on the same address lines.  No production
through-hole non-volatile part is fast enough for the fetch path, so the
cartridge copies the EEPROMs into the SRAMs at every power-up.

The cartridge stalls the CPU while it loads, and the CPU's PC is the
address counter.  The board clock runs free from power-up; nothing gates
it.

- **STALL is held.**  The CPU already has a line that freezes it for
  video reads and the ALU wait: the Branch PLD's STALL, which holds the
  State PLD (no state change, every load strobe off) and both PC PLDs.
  It goes through the cartridge: STALL_IN (Branch PLD pin 19) goes
  out to the cartridge PLD, which sends back STALL_OUT = STALL_IN OR its
  own hold, to the State PLD (pin 2) and the PC PLDs (pin 14).  The main
  board pulls STALL_OUT up, so with no cartridge the CPU stays stalled.
- **RUN is low.**  RUN (cartridge to main board, pulled down there): the
  memory control PLD (pin 17) keeps /ROM_OE high while RUN is low, so the
  SRAMs stay off the bus; RUN also holds the map register clear (all ROM)
  and the expansion cards in reset.
- **The CPU only walks the image.**  The instruction register is an
  ATF22V10C-7 (`ATF22V10_IR.pld`, chip #17) that
  holds 02h (`ld ac, ac`) while RUN is low, whatever is on the bus.  02h
  writes nothing (the destination comes from the IR), so the CPU can't
  disturb anything.  The State PLD still reads the fetched byte's bits
  4:0 for its next state, so the CPU goes from FETCH to LOAD_IMM,
  LOAD_MEM or EXEC as the image's own instruction would.  The PC is on
  the address bus in FETCH and LOAD_IMM (PC_ENABLE high) and steps by one
  in each, so every address is a FETCH or a LOAD_IMM read exactly once.
- **One copy per PC address.**  The cartridge PLD (`ATF22V10_CART.pld`,
  ATF22V10C-7PX, on the board clock) holds STALL_OUT high
  whenever RUN is low and PC_ENABLE is high, except for one release
  clock.  A video read comes in one clock of every 8-clock group, always
  the same one, so the PLD counts the group's clocks (K0-K7, restarting
  after each video read) and copies in K0-K6:

  | Clock | What happens |
  |---|---|
  | K0 | the CPU is stalled with the PC on the address bus (valid 13 ns after the edge) |
  | K1-K4 | EEPROM /OE low (COPY); the byte is valid by K0 + 178 ns |
  | K4 | the SRAM's /WE low (the chip is picked by /CE_LO or /CE_HI as usual) |
  | K5 | /WE and the EEPROM's /OE go high together; the EEPROM is off the bus by K6 + 15.8 ns |
  | K6 | release: STALL_OUT low, the CPU takes one step at the end of K6 |
  | K7 | a video read, or the CPU's next state |

  The State PLD reads the bus at the end of K6, after the EEPROM has let
  go: the bus still holds the EEPROM's byte (its capacitance against the
  10k pull-ups keeps it for microseconds).  LOAD_MEM and EXEC are not
  held.  If the step after a release is an operand read in the I/O
  window, an I/O device drives the bus from K6 + 37.5 ns, 21.7 ns after
  the EEPROM let go.
- **Hand-off.**  When a copy would start with A15 = 0 after a copy with
  A15 = 1, the PC has wrapped from xFFFF to x0000 and every address has
  been copied (the I/O window's bytes too, which are not used).  The PLD
  raises RUN instead: STALL_OUT follows STALL_IN only, /ROM_OE works, the
  map stays clear and the IR loads the next opcode.  The CPU is then at
  x0000 in FETCH or in LOAD_IMM, depending on how the image's last
  instruction ended, so **the image keeps a 1-byte `nop` (02h) at
  x0000**: fetched, it does nothing; read as an operand, it is skipped.
  The CPU fetches x0001 next.

The load takes about **33 ms** (28-33 ms: the image steers how the CPU
walks it).  `src/sim/tb_cart_load.vhd` runs the real cartridge, IR,
State, Branch and memory control PLD equations against a timed model of
the board and checks the setup times, that the IR is 02h in every EXEC,
that nothing writes, bus overlap and the hand-off;
`src/sim/tb_top_load.vhd` runs the whole FPGA model from power-up and
checks every cartridge read after the hand-off against `rom.mem`.  The
video runs throughout and shows whatever the random RAM holds: a quirk of
the system.

Timing: PIXEL_ENABLE through the Branch PLD's STALL, STALL_OUT and the
State PLD's load strobe to an F377 /E is 32.5 ns (+7.2 ns from the
datasheets, +1.2 on the routed board); the cartridge write cycle has tens
of nanoseconds to spare ([WE_TIMING.md](../timing/WE_TIMING.md#cartridge-sram-loader)).

Pins between the main board and the cartridge for the loader: CLK,
PIXEL_ENABLE, PC_ENABLE and STALL_IN (to the cartridge), STALL_OUT and
RUN (from it).

**Without a cartridge** a boot card in expansion slot 1 can load the
main RAM the same way and start the machine from RAM, with no ROM
([EXPANSION.md](EXPANSION.md), "Booting from slot 1"); the Sync PLD, which
makes /WE, lets go of it while RUN is low so the card can write the RAM.  A
fitted cartridge always wins.  For bring-up with neither, jumper STALL_IN
to STALL_OUT and RUN to +5 V; the board then runs from power-up, but
nothing loads the ROM.

## Boot

`src/scripts/rom_boot.asm`.  The map is clear (all ROM) when the cartridge
hands off, so the CPU runs ROM x0000 (the nop) and x0001, which jumps to the boot loader at xFD00.  Its
first job is to copy `LIB_RAM` (ROM x1F00-x1FFF) into the RAM under it,
while the map is still 00 (reads from ROM, writes to RAM), about 3,000
clocks.  After the expansion card scan below it writes map = 00 again and
reads the boot mode byte at ROM x0005 (a 32K cartridge shows x8005 there:
02).

**Expansion card scan (Apple II style):** the boot writes map = 01 (the
zero page reads RAM) and looks at slots 4, 3, 2 and 1.  When it finds a
valid card it waits up to about a second for a PS/2 keyboard to send Esc
(`esc_wait`: the keyboard's clock is let go and the receiver read; a
keyboard that is still starting up sends AA first, which buys it a little
longer); Esc skips the cards.  With no card found there is no wait.
A card whose first bytes are "PLC", card ID, code length n (1-90) and a
checksum (the sum of the n code bytes) has its code copied to RAM x0100 and
called with AC = slot number, R1:R0 = the slot's base address, SP = FE and
`MAP_SHADOW` = 01.  The code returns to go on with the scan and the normal
boot, or never returns to take the boot over.  An empty slot reads FF and
fails the check.  [EXPANSION.md](EXPANSION.md) has the header and rules.

**ROM program (00):** write map = 05 and `MAP_SHADOW` = 05, set `FONT_PG`
to the standard font, then jump to x6000.  The boot loader runs in section 7, which stays ROM, so no copy is
needed.  The program starts a few clocks after reset.

**The 32K image (02):** write map = 05 and `MAP_SHADOW` = 05, then jump to
the loader at x8100 ("The 32K image" above).

**RAM image (01):** for the older demos (pi spigot, Mandelbrot, game of life,
CPU test, test_video), which were written to run from RAM x0000 and keep
code and variables mixed there and don't use the library.  `gen_rom.tcl`
stores such a program in the lower half of the ROM, RAM x0000-x1FFF at
ROM x6000-x7FFF and RAM x2000-x49FF at its own address, and the boot
loader:

1. writes map = 01, so the zero page reads RAM for its two page counters;
2. copies RAM pages x01-x1F from ROM x6100-x7FFF and pages x20-x49 from
   the ROM at the same address (a read comes from the ROM, a write goes
   to the RAM), then page x00 from ROM x6000 last;
3. copies the map switch (xFE00-xFE07) into the RAM under it, because the
   fetch right after a map write still uses the old map (xFE00-xFE1F is
   the first 32 bytes of byte column 79, which never show on the screen);
4. writes map = FF and jumps to RAM x0000.

The copy takes about 23 ms.  It does not set `MAP_SHADOW`, because those
programs keep code there.

`gen_rom.tcl` always puts the 32K image in the upper half (from `rom32.hex`,
which holds the library too).  It makes the 32K image in both halves when
the program's byte at xFC00 is 02 (`rom32.asm` sets it), treats a program
as a RAM image when its hex has any byte in x0000-x1FFF or x4000-x5FFF
other than the library's own bytes, and otherwise as a ROM program, with
its bytes in x2000-x3FFF and x6000-x7FFF.  `placard_sim.py`'s `build_rom`
makes the same bytes.

## Building

`build\build_and_load.bat <program>` assembles `rom_boot.asm`, `rom_lib.asm`
and the program, then makes `ram.mem`, `cart_ram.mem` and `rom.mem`.  The
`fast` path puts the files into the last bitstream with `updatemem`
(`ramComp` gets `ram.mem`, `sramComp` `cart_ram.mem`, `romComp`
`rom.mem`).  By hand:

```
customasm rom_boot.asm -f hexstr -o rom_boot.hex
customasm rom_lib.asm  -f hexstr -o rom_lib.hex
customasm lib_demo.asm -f hexstr -o lib_demo.hex
tclsh gen_random_ram.tcl
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
(`ROM_IMAGE`, `IMAGE_END`, `MAP_ROM_RUN`, `PROG_START`, `DOS_START`,
`BOOT_MODE`), `gen_rom.tcl` and `placard_sim.py` (`ROM_IMAGE_BASE`,
`IMAGE_SIZE`, `LIB_START`, `LIB_END`, `PROG_START`, `PROG_END`,
`DOS_START`, `DOS_END`, `LIB_RAM_IMAGE`, `BOOT_MODE`); the 32K image's own places
are in `rom32.masm` (`ROM_CODE`, `ROM_TOP`, `ROM_CODE2`, `ROM_TOP2`, the vectors) and
`placard_fsw.masm` (`FSW_CODE`).
