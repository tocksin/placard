# ROM layout and boot

Each memory has its own initialization file in the FPGA model:
`src/hdl/rom.mem` (made by `src/scripts/gen_rom.tcl`) is the ROM
cartridge's EEPROM image, and `src/hdl/ram.mem` (the main RAM) and
`cart_ram.mem` (the cartridge SRAM) are random bytes from
`src/scripts/gen_random_ram.tcl`, as a real SRAM powers up.  All use
`sp_ram.vhd`, which takes the file name as the generic `initFile`; the
cartridge model is `src/hdl/cartridge.vhd`.  Programs and the standard
library live in the ROM.

Date: 10/22/2026

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
the font, the I/O drivers and the rest, down to xC000.

| ROM address | Contents | Made from |
|-------------|----------|-----------|
| x0000-x0004 | nop (for the cartridge hand-off), reset jump to the boot loader (PC starts at 0000) | `rom_boot.asm` |
| x0004-x1EFF | Free | |
| x1F00-x1FFF | `LIB_RAM`: library code the boot copies to RAM x1F00 (the end of `plot1`, `con_scroll`) | `rom_lib.asm` |
| x2000-x3FFF | Program, more code and tables (runs in place) | the program |
| x4000-x4FFF | Free (section 2 reads RAM while a program runs) | |
| x5000-x53FF | I/O window, the ROM is never read here | |
| x5400-x5FFF | Free (section 2 reads RAM while a program runs) | |
| x6000-xBFFF | Program, runs in place, entry at x6000 | the program |
| xC000-xC4FF | PS/2 keyboard driver and listening (`PS2_CODE`): `wait_frames_io` ([IO.md](IO.md)) | `rom_lib.asm` |
| xC500-xC5FF | Menu hook (`MENU_CODE`): `menu_poll` ([MENU.md](MENU.md)) | `rom_lib.asm` |
| xC600-xC6FF | Expansion slot helpers (`SLOT_CODE`): `slot_id` | `rom_lib.asm` |
| xC700-xD4FF | FAT file reader (`FS_CODE`) | `rom_lib.asm` |
| xD500-xD6FF | Line input and mouse pointer (`INPUT_CODE`): `con_gets`, `mouse_move` | `rom_lib.asm` |
| xD700-xDBFF | Sound driver (`SND_CODE`) | `rom_lib.asm` |
| xDC00-xEBFF | I/O drivers (`IO_CODE`): keyboard, pads, SD card, mouse ([IO.md](IO.md)) | `rom_lib.asm` |
| xEC00-xF3FF | Standard font (`LIB_FONT`) | `rom_lib.asm` |
| xF400-xFAFF | Standard library core routines (`LIB_CODE`) | `rom_lib.asm` |
| xFB00-xFBFF | Jump table (`LIB_JT`), 55 of 64 entries used ([LIBRARY.md](LIBRARY.md#jump-table)) | `rom_lib.asm` |
| xFC00 | Boot mode: 00 = ROM program, 01 = RAM image | `gen_rom.tcl` |
| xFD00-xFD7E | Boot loader | `rom_boot.asm` |
| xFE00-xFE07 | Map switch (RAM image boot only) | `rom_boot.asm` |
| xFE08-xFEA1 | Expansion card scan | `rom_boot.asm` |

## Cartridge sizes

There are two cartridge boards (2026-10-24), and a machine takes either:

- **64K** (`kicad/cartridge_64k`, 5 chips): EEPROMs U2 (x0000-x7FFF,
  `/CE_LO`) and U3 (x8000-xFFFF, `/CE_HI`), SRAMs U4 and U5.  The map
  above is for this one; development uses it.
- **32K** (`kicad/cartridge_32k`, 3 chips): one EEPROM U2 and one SRAM U3,
  both always selected (/CE tied to GND), so the same 32K appears at
  x0000-x7FFF and again at x8000-xFFFF.  The loader copies it twice (the
  PC walks all 64K), which needs no change to the loader PLD.

Not done yet: a 32K ROM layout.  The 64K image above does not fit.  The
plan (2026-10-21) is an image of x8000-xFFFF only: the reset nop and jump
at x8000 (read as x0000 at reset), the menu and an SD program loader in
x8000-xBFFF, the library where it is now (xC000-xFFFF); other programs
load from the SD card.  `gen_rom.tcl`, `placard_sim.py` and the library
constants still build the 64K image only.

## The demo menu ROM

`gen_menu_rom.py` builds a different image: six demos and a menu in one
ROM, using the free areas above for the RAM programs.  See
[MENU.md](MENU.md).

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

## Loading the cartridge

The ROM the CPU sees is two AS7C256C-15PCN SRAMs (15 ns) on the
cartridge.  They lose their contents at power-off, so the image is kept
in two AT28C256-15PU EEPROMs (32K x 8, 150 ns, PDIP-28, reprogrammable,
programmed off the board) on the same address lines.  No production
through-hole non-volatile part is fast enough for the fetch path, and a
battery-backed SRAM drains a CR2032 in about two weeks (0.3 mA typical
retention current per chip), so the cartridge copies the EEPROMs into
the SRAMs at every power-up.

The cartridge stalls the CPU while it loads, and the CPU's PC is the
address counter.  The board clock runs free from power-up; nothing gates
it.

- **STALL is held.**  The CPU already has a line that freezes it for
  video reads and the ALU wait: the Branch PLD's STALL, which holds the
  State PLD (no state change, every load strobe off) and both PC PLDs.
  It now goes through the cartridge: STALL_IN (Branch PLD pin 19) goes
  out to the cartridge PLD, which sends back STALL_OUT = STALL_IN OR its
  own hold, to the State PLD (pin 2) and the PC PLDs (pin 14).  The main
  board pulls STALL_OUT up, so with no cartridge the CPU stays stalled.
- **RUN is low.**  RUN (cartridge to main board, pulled down there): the
  memory control PLD (pin 17) keeps /ROM_OE high while RUN is low, so the
  SRAMs stay off the bus; RUN also holds the map register clear (all ROM)
  and the expansion cards in reset.
- **The CPU only walks the image.**  The instruction register is an
  ATF22V10C-7 (`ATF22V10_IR.pld`, chip #17, in place of the 74F377) that
  holds 02h (`ld ac, ac`) while RUN is low, whatever is on the bus.  02h
  writes nothing (the destination comes from the IR), so the CPU can't
  disturb anything.  The State PLD still reads the fetched byte's bits
  4:0 for its next state, so the CPU goes from FETCH to LOAD_IMM,
  LOAD_MEM or EXEC as the image's own instruction would.  The PC is on
  the address bus in FETCH and LOAD_IMM (PC_ENABLE high) and steps by one
  in each, so every address is a FETCH or a LOAD_IMM read exactly once.
- **One copy per PC address.**  The cartridge PLD (`ATF22V10_CART.pld`
  revision 04, ATF22V10C-7PX, on the board clock) holds STALL_OUT high
  whenever RUN is low and PC_ENABLE is high, except for one release
  clock.  A video read comes in one clock of every 8-clock group, always
  the same one, so the PLD counts the group's clocks (K0-K7, restarting
  after each video read) and copies in K0-K6:

  | Clock | What happens |
  |---|---|
  | K0 | the CPU is stalled with the PC on the address bus (valid 20.5 ns after the edge) |
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

Timing (every PLD is a -7 part since 2026-10-23): PIXEL_ENABLE
through the Branch PLD's STALL, STALL_OUT and the State PLD's load strobe
to an F377 /E is 32.5 ns (+7.2 ns; +2.2 when the Branch and cartridge PLDs
were -10); PC_ENABLE to STALL_OUT to the State and PC setup is 16.5 ns.  The IR PLD's opcode setup (3.5 ns) leaves the fetch
path +0.7 ns, the same as the State PLD's, and its clock to output (5.5
ns, the F377's was 10.5) gives every path that starts at the IR 5 ns
more.

Pins between the main board and the cartridge for the loader: CLK,
PIXEL_ENABLE, PC_ENABLE and STALL_IN (to the cartridge), STALL_OUT and
RUN (from it).  There is no clock gate and no 74AC541 on the cartridge.

**Without a cartridge** a boot card in expansion slot 1 can load the
main RAM the same way and start the machine from RAM, with no ROM
(EXPANSION.md, "Booting from slot 1"); the memory control PLD (revision
09) lets go of /WE while RUN is low so the card can write the RAM.  A
fitted cartridge always wins.  For bring-up with neither, jumper STALL_IN
to STALL_OUT and RUN to +5 V; the board then runs from power-up, but
nothing loads the ROM.

## Boot

`src/scripts/rom_boot.asm`.  The map is clear (all ROM) when the cartridge
hands off, so the CPU runs ROM x0000 (the nop) and x0001, which jumps to the boot loader at xFD00.  Its
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

The copy takes about 23 ms.  It does not set `MAP_SHADOW`, because those
programs keep code there.

`gen_rom.tcl` treats a program as a RAM image when its hex has any byte in
x0000-x1FFF or x4000-x5FFF other than the library's own bytes; otherwise it
is a ROM program, with its bytes in x2000-x3FFF and x6000-xBFFF.

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
(`ROM_IMAGE`, `IMAGE_END`, `MAP_ROM_RUN`, `PROG_START`, `BOOT_MODE`),
`gen_rom.tcl` and `placard_sim.py` (`ROM_IMAGE_BASE`, `IMAGE_SIZE`,
`LIB_START`, `LIB_END`, `PROG_START`, `PROG_END`, `BOOT_MODE`).
