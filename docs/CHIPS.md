# Chip list

Date: 2026-10-19

Every chip in the Placard, one chip per line.  The current list follows
`basys_top.vhd`, the PLD sources in `src/pld`, [CPU.md](CPU.md),
[TIMING.md](TIMING.md#parts) and [TIMING_FIXES.md](TIMING_FIXES.md).  The
shared port is in [IO.md](IO.md).  Part numbers are the
DIP parts those documents chose; stock moves, so recheck before ordering.

## Current design

| # | Part number | Type | Function in the design |
|--:|---|---|---|
| 1 | ATF22V10C-7PX | PLD (22V10, 24-pin) | State machine: FETCH / LOAD / EXEC, register loads, R/W (`ATF22V10_STATE.pld`) |
| 2 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Branch decode, LoadPCLow/High, ADD/SUB wait clock and STALL, SRC_EN to the memory control, carry flag for BCS/BCC (COUT from the high ALU PLD on pin 14) (`ATF22V10_BRANCH.pld`) |
| 3 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, low byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 4 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, high byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 5 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, low nibble: 4-bit ALU with Z flag (`ALU_SHR.pld`) |
| 6 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, high nibble: 4-bit ALU with Z flag, F3 is the sign (`ALU_SHR.pld`) |
| 7 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 3:0: PC / D / X / video address (`ATF22V10_QUAD_MUX.pld`) |
| 8 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 7:4 (`ATF22V10_QUAD_MUX.pld`) |
| 9 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 11:8: PC / Y / zero page / video address (`ATF22V10_QUAD_MUX.pld`) |
| 10 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 15:12 (`ATF22V10_QUAD_MUX.pld`) |
| 11 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Memory control: /WE, /RAM_OE, /ROM_OE from the map, and MAP_RUN reset (`ATF22V10_MEM_CTRL.pld`) |
| 12 | ATF22V10C-7PX | PLD (22V10, 24-pin) | I/O decode: upper 32K /CE_HI and the x5000-x53FF strobes (`ATF22V10_IO_DECODE.pld`) |
| 13 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video H counter: H9:H3, HSYNC, horizontal active (`ATF22V10_HCOUNT.pld`) |
| 14 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video V counter: V9:V0 (`ATF22V10_VCOUNT.pld`) |
| 15 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video sync: H2:H0 (also the color decoder's pixel select), VSYNC, VIDEN, PIXEL_ENABLE and address-mux selects (`ATF22V10_SYNC.pld`) |
| 16 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Color decoder: pixel byte and line code to VGA RGB (`ATF22V10_COLORDECODER.pld`) |
| 17 | SN74F377AN | Octal D flip-flop with enable | Instruction register |
| 18 | SN74F377AN | Octal D flip-flop with enable | D register (immediate / memory operand) |
| 19 | SN74F377AN | Octal D flip-flop with enable | Accumulator (AC) |
| 20 | SN74F377AN | Octal D flip-flop with enable | X register |
| 21 | SN74F377AN | Octal D flip-flop with enable | Y register |
| 22 | SN74F377AN | Octal D flip-flop with enable | Video pixel buffer (byte read from video memory) |
| 23 | SN74F377AN | Octal D flip-flop with enable | Video line code (color mode for the line): D from the pixel buffer outputs, /E from /MODE_LD, so it copies the mode byte read in group 45 (see VIDEO.md); Q1:Q0 to the color decoder, Q3:Q2 to the audio slot PLD (line repeat) |
| 24 | — | — | Removed 2026-10-19: the video delay F574 (H2:H0 pixel select and video active, two stages).  The Sync PLD now makes both two clocks later itself (VIDEO_TIMING.md, "Delay register removed").  The numbers below are kept as they were |
| 25 | CD74ACT273E | Octal D flip-flop with clear | ROM/RAM map register at x5000 (write only, cleared to all ROM at power-up) |
| 26 | SN74F541N | Octal buffer, 3-state | Source bus driver: D register (the source bus is also the memory data bus) |
| 27 | SN74F541N | Octal buffer, 3-state | Source bus driver: accumulator |
| 28 | SN74F541N | Octal buffer, 3-state | Source bus driver: X register |
| 29 | SN74F541N | Octal buffer, 3-state | Video line read at x5000: V9:V2 onto the data bus, enabled by /LINE_RD |
| 30 | SN74F138N | 3-to-8 decoder | Source bus select: enables one of the three source bus F541s from the instruction's bits 1:0, only in EXEC with PIXEL_ENABLE low (G1 = Q0, /G2A = PC_ENABLE, /G2B = PIXEL_ENABLE) |
| 31 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, lower 32K (x0000-x7FFF) |
| 32 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, upper 32K (x8000-xFFFF) |
| 33 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | ROM, lower 32K (interim: battery-backed SRAM) |
| 34 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | ROM, upper 32K (interim: battery-backed SRAM) |
| 35 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Audio and mode slots, row address: picks group 45 for the mode byte read and group 46 or 47 for the audio read, makes /MODE_LD for the line code register, and remaps video address bits A0, A1, A7, A8 for the line repeat (`ATF22V10_AUDIO.pld`, see SOUND.md and VIDEO.md) |
| 36 | SN74HCT574N | Octal D flip-flop, 3-state | Audio DAC register: copies the sample from the pixel buffer when H_VIDEO_ACTIVE rises (start of group 48), drives the R-2R ladder, which drives headphones directly (all passive, see SOUND.md) |
| 37 | SN74HC574N | Octal D flip-flop, 3-state | Shared port latch at x5200 (IO.md): SCK and pad CLOCK, MOSI and pad LATCH, SD /CS (also holds the PS/2 mouse off), PS/2 DATA, keyboard column code.  HC for a full 5 V high into the pads |
| 38 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Shared port: keyboard columns /COL0-/COL7 from the latch, pad DATA onto D7/D6 on odd reads (`ATF22V10_PORT.pld`) |
| 39 | SN74F541N | Octal buffer, 3-state | Shared port input on even reads: keyboard rows, with SD MISO and the PS/2 lines on rows 7, 6 and 5 |
| 40 | not chosen | 3.3 V regulator | Powers the SD card (its SCK, MOSI and /CS come down to 3.3 V through resistor dividers, IO.md) |

### Tally

| Part number | Type | Qty |
|---|---|--:|
| ATF22V10C-7PX | PLD (22V10) | 18 |
| SN74F377AN | Octal D flip-flop with enable | 7 |
| CD74ACT273E | Octal D flip-flop with clear | 1 |
| SN74F541N | Octal buffer, 3-state | 5 |
| SN74F138N | 3-to-8 decoder | 1 |
| AS7C256C-15PCN | SRAM, 32K x 8 | 4 |
| SN74HCT574N | Octal D flip-flop, 3-state | 1 |
| SN74HC574N | Octal D flip-flop, 3-state | 1 |
| **Total** | | **38 + a 3.3 V regulator** |

**Not counted, not chosen yet:** the 25.175 MHz clock oscillator, and the
battery and power-fail switch that hold the interim ROM's /CE high while
power is off (CPU.md, "Memory parts").  The SN74F32 and SN74F04 in older
versions of TIMING.md were removed (the memory control and I/O decode PLDs
took their jobs), and the ROM/RAM select PLD became the CD74ACT273E.
Also not counted: the series resistors (8, one per bit, for example a
bussed or isolated resistor array) between the source F541 outputs and
the data bus, which limit the current while the bus changes hands at the
start of EXEC (CPU.md, "One data bus").

**Removed 2026-10-18: the RAM write-data buffer** (an SN74F541N, source
bus onto the RAM data pins, enabled by /WE).  The source bus is now the
memory data bus.  It is kept as a fallback for the prototype: see CPU.md,
"Fallback: the write-data buffer".

**Removed 2026-10-18: the CD74HC4050E level shifter.**  Three resistor
dividers (1.8k over 3.3k) bring the SD card's SCK, MOSI and /CS down to
3.2 V (IO.md, "SD card").

## Future features

Nothing else is planned yet.  The four expansion slots and the ROM
cartridge slot are connectors only ([EXPANSION.md](EXPANSION.md)).  The
PS/2 mouse uses the shared port and adds only diodes and a socket.
Features cut from the plan, such as the frame counter or an SPI shifter,
are listed with their cost in FEATURE_PLAN.md, "Cut for now".
