# Chip list

Date: 2026-10-23

Every chip in the Placard, one chip per line.  The current list follows
`basys_top.vhd`, the PLD sources in `src/pld`, [CPU.md](CPU.md),
[TIMING.md](TIMING.md#parts) and [TIMING_FIXES.md](TIMING_FIXES.md).  The
shared port is in [IO.md](IO.md).  Part numbers are the
DIP parts those documents chose; stock moves, so recheck before ordering.

## Current design

| # | Part number | Type | Function in the design |
|--:|---|---|---|
| 1 | ATF22V10C-7PX | PLD (22V10, 24-pin) | State machine: FETCH / LOAD / EXEC, register loads (active low, to the F377 /E pins and the IR PLD), R/W; frozen by STALL_OUT from the cartridge (`ATF22V10_STATE.pld`) |
| 2 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Branch decode, LoadPCLow/High, ADD/SUB wait clock and STALL, /SRC_EN to the source F541s' /OE1 and the memory control, carry flag for BCS/BCC (COUT from the high ALU PLD on pin 14), /PIX_LD for the pixel buffer (pin 15) (`ATF22V10_BRANCH.pld`) |
| 3 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, low byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 4 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, high byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 5 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, low nibble: 4-bit ALU with Z flag (`ALU_SHR.pld`) |
| 6 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, high nibble: 4-bit ALU with Z flag, F3 is the sign (`ALU_SHR.pld`) |
| 7 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 3:0: PC / D / X / video address (`ATF22V10_QUAD_MUX.pld`) |
| 8 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 7:4 (`ATF22V10_QUAD_MUX.pld`) |
| 9 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 11:8: PC / Y / zero page / video address (`ATF22V10_QUAD_MUX.pld`) |
| 10 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 15:12 (`ATF22V10_QUAD_MUX.pld`) |
| 11 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Memory control: /WE, /RAM_OE, /ROM_OE from the map; /ROM_OE only while RUN from the cartridge is high (revision 09, pin 17 is the RUN input; /WE floats while RUN is low so a slot-1 boot card can write the RAM) (`ATF22V10_MEM_CTRL.pld`) |
| 12 | ATF22V10C-7PX | PLD (22V10, 24-pin) | I/O decode: upper 32K /CE_HI and the x5000-x53FF strobes (`ATF22V10_IO_DECODE.pld`) |
| 13 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video H counter: H9:H3, HSYNC, horizontal active, blank line from mode byte bit 7 (`ATF22V10_HCOUNT.pld`) |
| 14 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video V counter: V9:V0 (`ATF22V10_VCOUNT.pld`) |
| 15 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video sync: H2:H0 (also the color decoder's pixel select), /VSYNC, VIDEN, PIXEL_ENABLE and address-mux selects (`ATF22V10_SYNC.pld`) |
| 16 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Color decoder: pixel byte and line code to VGA RGB (`ATF22V10_COLORDECODER.pld`) |
| 17 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Instruction register: loads the opcode on /LOAD_INSTR, holds 02h (`ld ac, ac`) while RUN is low so the CPU only walks the image while the cartridge loads (`ATF22V10_IR.pld`; was an SN74F377AN until 2026-10-21) |
| 18 | SN74F377AN | Octal D flip-flop with enable | D register (immediate / memory operand) |
| 19 | SN74F377AN | Octal D flip-flop with enable | Accumulator (AC) |
| 20 | SN74F377AN | Octal D flip-flop with enable | X register |
| 21 | SN74F377AN | Octal D flip-flop with enable | Y register |
| 22 | SN74F377AN | Octal D flip-flop with enable | Video pixel buffer (byte read from video memory); /E from the Branch PLD's /PIX_LD (pin 15), low on a video read |
| 23 | CD74HCT377E (was SN74F377AN until 2026-10-22) | Octal D flip-flop with enable | Video line code (the row's mode byte): D from the pixel buffer outputs, /E from /MODE_LD, so it copies the mode byte read in group 45 (see VIDEO.md); Q1:Q0 to the color decoder, Q3:Q2 to the audio slot PLD (line repeat), Q6:Q4 to the row tint resistors, Q7 to the H counter (blank line).  HCT because the tint outputs source about 3 mA |
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
| 36 | SN74HCT574N | Octal D flip-flop, 3-state | Audio DAC register: copies the sample from the pixel buffer when H_VIDEO_ACTIVE rises (start of group 48), drives the R-2R ladder, which drives the audio line out directly (all passive, no headphone amplifier, see SOUND.md) |
| 37 | SN74HC574N | Octal D flip-flop, 3-state | Shared port latch at x5200 (IO.md): SCK and pad CLOCK, MOSI and pad LATCH, SD /CS (also holds the PS/2 mouse off), PS/2 DATA, keyboard column code (bit 4 also holds the PS/2 keyboard off when no column is driven).  HC for a full 5 V high into the pads |
| 38 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Shared port: keyboard columns /COL0-/COL7 from the latch, pad DATA (and the PS/2 keyboard's CLK on D6) onto D7/D6 on odd reads (`ATF22V10_PORT.pld`, rev 02) |
| 39 | SN74F541N | Octal buffer, 3-state | Shared port input on even reads: keyboard rows, with SD MISO and the PS/2 lines on rows 7, 6 and 5 |
| 40 | not chosen | 3.3 V regulator | Powers the SD card (its SCK, MOSI and /CS come down to 3.3 V through resistor dividers, IO.md) |
| 41 | — | — | Removed 2026-10-21: the 74AC32 clock gate (CLK = OSC OR HOLD).  The cartridge now holds the CPU's STALL line instead of the clock (ROM.md, "Loading the cartridge") |

### Tally

| Part number | Type | Qty |
|---|---|--:|
| ATF22V10C-7PX | PLD (22V10) | 19 |
| SN74F377AN | Octal D flip-flop with enable | 5 |
| CD74HCT377E | Octal D flip-flop with enable (line code) | 1 |
| CD74ACT273E | Octal D flip-flop with clear | 1 |
| SN74F541N | Octal buffer, 3-state | 4 |
| AS7C256C-15PCN | SRAM, 32K x 8 | 2 |
| SN74HCT574N | Octal D flip-flop, 3-state | 1 |
| SN74HC574N | Octal D flip-flop, 3-state | 1 |
| **Total** | | **34 + a 3.3 V regulator** |

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
| ATF22V10C-7PX | PLD (22V10, 24-pin) | Loader: holds the CPU's STALL at each PC address, makes the EEPROM /OE and SRAM /WE, raises RUN at the PC wrap (`ATF22V10_CART.pld` revision 04) |

Five chips.  The battery and power-fail switch of the interim
battery-backed ROM are gone; the main board loses #33 and #34.

**Changed 2026-10-21: no clock gate, no cartridge 74AC541.**  The
cartridge holds the CPU's STALL line (STALL_IN from the Branch PLD,
STALL_OUT back to the State and PC PLDs) instead of the board clock, and
the instruction register became a PLD that holds 02h while RUN is low, so
the 74AC32 (#41) and the cartridge's 74AC541 are gone and the cartridge
PLD moved to the -7 grade (STALL_OUT is on the State PLD's strobe path).

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
and tEA 10, against 7.5, 5.5, 3.5 and 7.5 for the -7PX.  Seven main-board
PLDs and the cartridge's have the room for it; the other twelve stay -7.

2026-10-21: the instruction register is a PLD now (tCO 5.5 ns, the F377's
was 10.5), so every path that starts at the IR gained 5 ns; the rows below
that start at the IR show the new slack.  That moved the Branch and audio
slot PLDs to -10 (Justin, 2026-10-21), and the cartridge PLD with them.
`tb_cart_load.vhd` passes with every PLD at -10 delays.

**2026-10-23: every PLD is an ATF22V10C-7PX** (Justin): one part number
to buy, program and kit, for $2.52 more per main board ($0.36 a chip at
Mouser) and more timing margin.  The table keeps the grade each PLD could
use ("Could be"); the slack at -7 is what the board has now.

| # | PLD | Worst path through it | Slack at -7 | Slack at -10 | Could be |
|--:|---|---|---:|---:|---|
| 3, 4 | PC low, PC high | Branch decision: IR 5.5, ALU F, Z, Branch LOAD_PC_LOW, PC setup | +8.2 | +7.2 | -10 |
| 13 | H counter | H_TC to the V counter (both -10) | +23.2 | +19.7 | -10 |
| 14 | V counter | V_VIDEO_ACTIVE.D: V tCO, Sync setup | +30.7 | +29.7 | -10 |
| 16 | Color decoder | Pixel buffer 10.5, two levels, to the DAC (no register after it): settled 25.5 / 30.5 ns into a 39.7 ns pixel | | | -10 |
| 1 | State | Opcode fetch: PC_ENABLE tCO, ADDR_SEL, mux, tAA, State setup | +0.7 | −1.3 | -7 |
| 17 | Instruction register | Same opcode fetch, into the IR (tS 3.5) | +0.7 | −1.3 | -7 |
| 15 | Sync | Same fetch path (ADDR_SEL) | +0.7 | −1.8 | -7 |
| 7-10 | Address mux | Same fetch path | +0.7 | −1.8 | -7 |
| 11 | Memory control | Opcode through /OE into the State PLD; address hold after /WE | +1.2; +0.5 | −1.3; −2.0 | -7 |
| 12 | I/O decode | I/O read: address, /xx_RD, F541 enable, D setup | +0.2 | −2.3 | -7 |
| 5, 6 | ALU | Logic op after a video stall; branch decision (F and Z) | +1.7; +8.2 | −0.8; +3.2 | -7 |
| 38 | Port | Pad read: address, /PORT_RD, port tEA, D setup | +2.2 | −0.3 | -7 |
| 2 | Branch | Branch decision into the PC PLDs; PIXEL_ENABLE through STALL and the cartridge to the State strobes; /SRC_EN to the source F541s | +8.2; +7.2; +7.7 | +4.7 (PCs at -10); +2.2 (cartridge at -10); +5.2 | -10 |
| 35 | Audio slot | /AC_SEL (since revision 04): IR 5.5, /AC_SEL, F541 enable 9.5, ALU 7.5, AC setup 2 (the video paths have +19.7 at -10) | +7.7 | +5.2 | -10 |
| cart | Cartridge loader | STALL through it to the State PLD's strobe and an F377 /E (37.5 ns with it and the Branch PLD at -10) | +7.2 | +2.2 | -10 |

The branch decision runs through the Branch PLD and into both PC PLDs;
until the IR became a PLD only one side could be -10, and now both are.
The video address (H, V and the audio PLD's row bits) changes at the start
of clock 0 of a group and is read in clock 1, so it has over a clock to
settle.  A slower color decoder moves every pixel later by the same amount;
the settled part of each pixel shrinks from about 21 to about 16 ns.

## Future features

Nothing else is planned yet.  The four expansion slots and the ROM
cartridge slot are connectors only ([EXPANSION.md](EXPANSION.md)).  The
PS/2 mouse and PS/2 keyboard (stacked dual socket) use the shared port and add only diodes, pull-ups and the socket.
Features cut from the plan, such as the frame counter or an SPI shifter,
are listed with their cost in FEATURE_PLAN.md, "Cut for now".
