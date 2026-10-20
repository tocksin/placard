# Chip list

Date: 2026-10-20

Every chip in the Placard, one chip per line.  The current list follows
`basys_top.vhd`, the PLD sources in `src/pld`, [CPU.md](CPU.md),
[TIMING.md](TIMING.md#parts) and [TIMING_FIXES.md](TIMING_FIXES.md).  The
shared port is in [IO.md](IO.md).  Part numbers are the
DIP parts those documents chose; stock moves, so recheck before ordering.

## Current design

| # | Part number | Type | Function in the design |
|--:|---|---|---|
| 1 | ATF22V10C-7PX | PLD (22V10, 24-pin) | State machine: FETCH / LOAD / EXEC, register loads (active low, to the F377 /E pins), R/W (`ATF22V10_STATE.pld`) |
| 2 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Branch decode, LoadPCLow/High, ADD/SUB wait clock and STALL, /SRC_EN to the source F541s' /OE1 and the memory control, carry flag for BCS/BCC (COUT from the high ALU PLD on pin 14), /PIX_LD for the pixel buffer (pin 15) (`ATF22V10_BRANCH.pld`) |
| 3 | ATF22V10C-10PU | PLD (22V10, 24-pin) | Program counter, low byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 4 | ATF22V10C-10PU | PLD (22V10, 24-pin) | Program counter, high byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 5 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, low nibble: 4-bit ALU with Z flag (`ALU_SHR.pld`) |
| 6 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, high nibble: 4-bit ALU with Z flag, F3 is the sign (`ALU_SHR.pld`) |
| 7 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 3:0: PC / D / X / video address (`ATF22V10_QUAD_MUX.pld`) |
| 8 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 7:4 (`ATF22V10_QUAD_MUX.pld`) |
| 9 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 11:8: PC / Y / zero page / video address (`ATF22V10_QUAD_MUX.pld`) |
| 10 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 15:12 (`ATF22V10_QUAD_MUX.pld`) |
| 11 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Memory control: /WE, /RAM_OE, /ROM_OE from the map; /ROM_OE only while RUN from the cartridge is high (revision 08, pin 17 is the RUN input) (`ATF22V10_MEM_CTRL.pld`) |
| 12 | ATF22V10C-7PX | PLD (22V10, 24-pin) | I/O decode: upper 32K /CE_HI and the x5000-x53FF strobes (`ATF22V10_IO_DECODE.pld`) |
| 13 | ATF22V10C-10PU | PLD (22V10, 24-pin) | Video H counter: H9:H3, HSYNC, horizontal active (`ATF22V10_HCOUNT.pld`) |
| 14 | ATF22V10C-10PU | PLD (22V10, 24-pin) | Video V counter: V9:V0 (`ATF22V10_VCOUNT.pld`) |
| 15 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video sync: H2:H0 (also the color decoder's pixel select), VSYNC, VIDEN, PIXEL_ENABLE and address-mux selects (`ATF22V10_SYNC.pld`) |
| 16 | ATF22V10C-10PU | PLD (22V10, 24-pin) | Color decoder: pixel byte and line code to VGA RGB (`ATF22V10_COLORDECODER.pld`) |
| 17 | SN74F377AN | Octal D flip-flop with enable | Instruction register (/E from the State PLD's /LOAD_INSTR; the F377s load when /E is low) |
| 18 | SN74F377AN | Octal D flip-flop with enable | D register (immediate / memory operand) |
| 19 | SN74F377AN | Octal D flip-flop with enable | Accumulator (AC) |
| 20 | SN74F377AN | Octal D flip-flop with enable | X register |
| 21 | SN74F377AN | Octal D flip-flop with enable | Y register |
| 22 | SN74F377AN | Octal D flip-flop with enable | Video pixel buffer (byte read from video memory); /E from the Branch PLD's /PIX_LD (pin 15), low on a video read |
| 23 | SN74F377AN | Octal D flip-flop with enable | Video line code (color mode for the line): D from the pixel buffer outputs, /E from /MODE_LD, so it copies the mode byte read in group 45 (see VIDEO.md); Q1:Q0 to the color decoder, Q3:Q2 to the audio slot PLD (line repeat) |
| 24 | — | — | Removed 2026-10-19: the video delay F574 (H2:H0 pixel select and video active, two stages).  The Sync PLD now makes both two clocks later itself (VIDEO_TIMING.md, "Delay register removed").  The numbers below are kept as they were |
| 25 | CD74ACT273E | Octal D flip-flop with clear | ROM/RAM map register at x5000 (write only, /MR = RUN: all ROM until the cartridge hands off) |
| 26 | SN74F541N | Octal buffer, 3-state | Source bus driver: D register, sources 00 and 01 (/OE1 = /SRC_EN, /OE2 = I1; the source bus is also the memory data bus) |
| 27 | SN74F541N | Octal buffer, 3-state | Source bus driver: accumulator, sources 10 and 11 (/OE1 = /SRC_EN, /OE2 = /AC_SEL from the audio slot PLD) |
| 28 | — | — | Removed 2026-10-19: the X register's source bus driver (X is no longer a source, CPU.md "Source mode") |
| 29 | SN74F541N | Octal buffer, 3-state | Video line read at x5000: V9:V2 onto the data bus, enabled by /LINE_RD |
| 30 | — | — | Removed 2026-10-19: the source select '138.  The two source F541s are picked by I1 and /AC_SEL and enabled by /SRC_EN (CPU.md, "Source mode") |
| 31 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, lower 32K (x0000-x7FFF) |
| 32 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, upper 32K (x8000-xFFFF) |
| 33 | — | — | Moved to the ROM cartridge 2026-10-20 (see "ROM cartridge" below) |
| 34 | — | — | Moved to the ROM cartridge 2026-10-20 |
| 35 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Audio and mode slots, row address: picks group 45 for the mode byte read and group 46 or 47 for the audio read, makes /MODE_LD for the line code register, and remaps video address bits A0, A1, A7, A8 for the line repeat (`ATF22V10_AUDIO.pld`, see SOUND.md and VIDEO.md).  Also /AC_SEL (= !I1, revision 04) for the AC source F541 |
| 36 | SN74HCT574N | Octal D flip-flop, 3-state | Audio DAC register: copies the sample from the pixel buffer when H_VIDEO_ACTIVE rises (start of group 48), drives the R-2R ladder, which drives headphones directly (all passive, see SOUND.md) |
| 37 | SN74HC574N | Octal D flip-flop, 3-state | Shared port latch at x5200 (IO.md): SCK and pad CLOCK, MOSI and pad LATCH, SD /CS (also holds the PS/2 mouse off), PS/2 DATA, keyboard column code.  HC for a full 5 V high into the pads |
| 38 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Shared port: keyboard columns /COL0-/COL7 from the latch, pad DATA onto D7/D6 on odd reads (`ATF22V10_PORT.pld`) |
| 39 | SN74F541N | Octal buffer, 3-state | Shared port input on even reads: keyboard rows, with SD MISO and the PS/2 lines on rows 7, 6 and 5 |
| 40 | not chosen | 3.3 V regulator | Powers the SD card (its SCK, MOSI and /CS come down to 3.3 V through resistor dividers, IO.md) |
| 41 | SN74AC32N | Quad 2-input OR | Clock gate: CLK = OSC OR HOLD, so the ROM cartridge can hold the board while it loads (ROM.md, "Loading the cartridge"); HOLD pulled up with 10k.  Three gates spare |

### Tally

| Part number | Type | Qty |
|---|---|--:|
| ATF22V10C-7PX | PLD (22V10) | 13 |
| ATF22V10C-10PU | PLD (22V10) | 5 |
| SN74F377AN | Octal D flip-flop with enable | 7 |
| CD74ACT273E | Octal D flip-flop with clear | 1 |
| SN74F541N | Octal buffer, 3-state | 4 |
| AS7C256C-15PCN | SRAM, 32K x 8 | 2 |
| SN74AC32N | Quad 2-input OR | 1 |
| SN74HCT574N | Octal D flip-flop, 3-state | 1 |
| SN74HC574N | Octal D flip-flop, 3-state | 1 |
| **Total** | | **35 + a 3.3 V regulator** |

**Not counted, not chosen yet:** the 25.175 MHz clock oscillator.  The SN74F32 and SN74F04 in older
versions of TIMING.md were removed (the memory control and I/O decode PLDs
took their jobs), and the ROM/RAM select PLD became the CD74ACT273E.
Also not counted: the series resistors (8, one per bit, for example a
bussed or isolated resistor array) between the source F541 outputs and
the data bus, which limit the current while the bus changes hands at the
start of EXEC (CPU.md, "One data bus").

**ROM cartridge (2026-10-20), not counted above:**

| Part number | Type | Function |
|---|---|---|
| AS7C256C-15PCN (2) | SRAM, 32K x 8, 15 ns | The ROM as the CPU sees it (was #33, #34); /WE from the cartridge PLD |
| AT28C256-15PU (2) | EEPROM, 32K x 8, 150 ns | The ROM image, programmed off the board; copied into the SRAMs at power-up |
| ATF22V10C-10PU | PLD (22V10, 24-pin) | Loader: holds the board's clock, steps it, makes the EEPROM /OE and SRAM /WE, raises RUN at the PC wrap (`ATF22V10_CART.pld`) |

The CPU's opcode while loading, `ld ac, ac`, is FFh (the opcode byte is
stored XOR FDh, CPU.md "Opcode byte"), which is what the data bus floats
to through its 3.3k pull-ups, so no chip drives it.  A 74AC541 wired to
02h did until the cartridge PLD's revision 02 (2026-10-20).

The battery and power-fail switch of the interim battery-backed ROM are
gone; the main board loses #33 and #34 and gains the 74AC32 (#41).

**Removed 2026-10-19: the X source F541 and the source '138.**  X is no
longer a source: source codes 00 and 01 drive D and 10 and 11 drive AC,
picked by instruction bit 1 (the D F541's /OE2) and the audio slot PLD's
/AC_SEL (the AC F541's /OE2), with the branch PLD's /SRC_EN on both
/OE1 pins.  The audio slot PLD moved to the -7 grade for it.  Software
reads X from a copy in RAM or keeps the value in AC (CPU.md, "Source
mode").

**Removed 2026-10-18: the RAM write-data buffer** (an SN74F541N, source
bus onto the RAM data pins, enabled by /WE).  The source bus is now the
memory data bus.  It is kept as a fallback for the prototype: see CPU.md,
"Fallback: the write-data buffer".

**Removed 2026-10-18: the CD74HC4050E level shifter.**  Three resistor
dividers (1.8k over 3.3k) bring the SD card's SCK, MOSI and /CS down to
3.2 V (IO.md, "SD card").

## PLD speed grades

Checked 2026-10-19 with the worst-case method of [TIMING.md](TIMING.md).
The ATF22V10C-10PU (PDIP-24, like the -7PX) has tPD 10 ns, tCO 6.5, tS 4.5
and tEA 10, against 7.5, 5.5, 3.5 and 7.5 for the -7PX.  Five PLDs have the
room for it; the other thirteen sit on paths with 0.2 to 2.7 ns to spare.

| # | PLD | Worst path through it | Slack at -7 | Slack at -10 | Grade |
|--:|---|---|---:|---:|---|
| 3, 4 | PC low, PC high | Branch decision: IR 10.5, ALU F, Z, Branch LOAD_PC_LOW, PC setup | +3.2 | +2.2 | -10 |
| 13 | H counter | H_TC to the V counter (both -10) | +23.2 | +19.7 | -10 |
| 14 | V counter | V_VIDEO_ACTIVE.D: V tCO, Sync setup | +30.7 | +29.7 | -10 |
| 16 | Color decoder | Pixel buffer 10.5, two levels, to the DAC (no register after it): settled 25.5 / 30.5 ns into a 39.7 ns pixel | | | -10 |
| 1 | State | Opcode fetch: PC_ENABLE tCO, ADDR_SEL, mux, tAA, State setup | +0.7 | −1.3 | -7 |
| 15 | Sync | Same fetch path (ADDR_SEL) | +0.7 | −1.8 | -7 |
| 7-10 | Address mux | Same fetch path | +0.7 | −1.8 | -7 |
| 11 | Memory control | Opcode through /OE into the State PLD; address hold after /WE | +1.2; +0.5 | −1.3; −2.0 | -7 |
| 12 | I/O decode | I/O read: address, /xx_RD, F541 enable, D setup | +0.2 | −2.3 | -7 |
| 5, 6 | ALU | Logic op after a video stall; branch decision (F and Z) | +1.7; +3.2 | −0.8; −1.8 | -7 |
| 38 | Port | Pad read: address, /PORT_RD, port tEA, D setup | +2.2 | −0.3 | -7 |
| 2 | Branch | Branch decision into the PC PLDs | +3.2 | +0.7 with the PCs at -7, −0.3 with them at -10 | -7 |
| 35 | Audio slot | /AC_SEL (since revision 04): IR 10.5, /AC_SEL, F541 enable 9.5, ALU 7.5, AC setup 2 (the video paths have +19.7 at -10) | +2.7 | +0.2 | -7 |

The branch decision runs through the Branch PLD and into both PC PLDs, so
only one side can be -10; the PCs are two chips and keep more margin.
The video address (H, V and the audio PLD's row bits) changes at the start
of clock 0 of a group and is read in clock 1, so it has over a clock to
settle.  A slower color decoder moves every pixel later by the same amount;
the settled part of each pixel shrinks from about 21 to about 16 ns.

## Future features

Nothing else is planned yet.  The four expansion slots and the ROM
cartridge slot are connectors only ([EXPANSION.md](EXPANSION.md)).  The
PS/2 mouse uses the shared port and adds only diodes and a socket.
Features cut from the plan, such as the frame counter or an SPI shifter,
are listed with their cost in FEATURE_PLAN.md, "Cut for now".
