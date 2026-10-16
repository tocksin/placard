# Chip list

Date: 2026-10-16

Every chip in the Placard, one chip per line.  The current list follows
`basys_top.vhd`, the PLD sources in `src/pld`, [CPU.md](CPU.md),
[TIMING.md](TIMING.md#parts) and [TIMING_FIXES.md](TIMING_FIXES.md).  The
future list follows [FEATURE_PLAN.md](FEATURE_PLAN.md).  Part numbers are the
DIP parts those documents chose; stock moves, so recheck before ordering.

## Current design

| # | Part number | Type | Function in the design |
|--:|---|---|---|
| 1 | ATF22V10C-7PX | PLD (22V10, 24-pin) | State machine: FETCH / LOAD / EXEC, register loads, R/W (`ATF22V10_STATE.pld`) |
| 2 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Branch decode, LoadPCLow/High, ADD/SUB wait clock and STALL (`ATF22V10_BRANCH.pld`) |
| 3 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, low byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 4 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, high byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 5 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, low nibble: 4-bit ALU with Z flag (`ALU_SHR.pld`) |
| 6 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, high nibble: 4-bit ALU with Z flag, F3 is the sign (`ALU_SHR.pld`) |
| 7 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 3:0: PC / D / X / video address (`ATF22V10_QUAD_MUX.pld`) |
| 8 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 7:4 (`ATF22V10_QUAD_MUX.pld`) |
| 9 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 11:8: PC / Y / zero page / video address (`ATF22V10_QUAD_MUX.pld`) |
| 10 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 15:12 (`ATF22V10_QUAD_MUX.pld`) |
| 11 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Memory control: /WE, /RAM_OE, /ROM_OE from the map, and MAP_RUN reset (`ATF22V10_MEM_CTRL.pld`) |
| 12 | ATF22V10C-7PX | PLD (22V10, 24-pin) | I/O decode: upper 32K /CE_HI and the x5000-x5FFF strobes (`ATF22V10_IO_DECODE.pld`) |
| 13 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video H counter: H9:H0, HSYNC, horizontal active (`ATF22V10_HCOUNT.pld`) |
| 14 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video V counter: V9:V0 (`ATF22V10_VCOUNT.pld`) |
| 15 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video sync: VSYNC, video active, PIXEL_ENABLE and address-mux selects (`ATF22V10_SYNC.pld`) |
| 16 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Color decoder: pixel byte and line code to VGA RGB (`ATF22V10_COLORDECODER.pld`) |
| 17 | SN74F377AN | Octal D flip-flop with enable | Instruction register |
| 18 | SN74F377AN | Octal D flip-flop with enable | D register (immediate / memory operand) |
| 19 | SN74F377AN | Octal D flip-flop with enable | Accumulator (AC) |
| 20 | SN74F377AN | Octal D flip-flop with enable | X register |
| 21 | SN74F377AN | Octal D flip-flop with enable | Y register |
| 22 | SN74F377AN | Octal D flip-flop with enable | Video pixel buffer (byte read from video memory) |
| 23 | SN74F377AN | Octal D flip-flop with enable | Video line code (color mode for the line, loaded during blanking) |
| 24 | SN74F574N | Octal D flip-flop, 3-state | Video delay: H2:H0 pixel select and video active, two stages |
| 25 | CD74ACT273E | Octal D flip-flop with clear | ROM/RAM map register at x5000 (write only, cleared to all ROM at power-up) |
| 26 | SN74F541N | Octal buffer, 3-state | Source bus driver: D register |
| 27 | SN74F541N | Octal buffer, 3-state | Source bus driver: accumulator |
| 28 | SN74F541N | Octal buffer, 3-state | Source bus driver: X register |
| 29 | SN74F541N | Octal buffer, 3-state | RAM write-data buffer: source bus onto the memory data pins, enabled by /WE |
| 30 | SN74F541N | Octal buffer, 3-state | Video line read at x5000: V9:V2 onto the data bus, enabled by /LINE_RD |
| 31 | SN74F138N | 3-to-8 decoder | Source bus select: enables one of the three source bus F541s from the instruction's bits 1:0 |
| 32 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, lower 32K (x0000-x7FFF) |
| 33 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, upper 32K (x8000-xFFFF) |
| 34 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | ROM, lower 32K (interim: battery-backed SRAM) |
| 35 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | ROM, upper 32K (interim: battery-backed SRAM) |
| 36 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Audio sample slot: picks group 38 or 39 for the audio read (`ATF22V10_AUDIO.pld`, see SOUND.md) |
| 37 | SN74HCT574N | Octal D flip-flop, 3-state | Audio DAC register: copies the sample from the pixel buffer at the end of HSYNC, drives the R-2R ladder, which drives headphones directly (all passive, see SOUND.md) |

### Tally

| Part number | Type | Qty |
|---|---|--:|
| ATF22V10C-7PX | PLD (22V10) | 17 |
| SN74F377AN | Octal D flip-flop with enable | 7 |
| SN74F574N | Octal D flip-flop, 3-state | 1 |
| CD74ACT273E | Octal D flip-flop with clear | 1 |
| SN74F541N | Octal buffer, 3-state | 5 |
| SN74F138N | 3-to-8 decoder | 1 |
| AS7C256C-15PCN | SRAM, 32K x 8 | 4 |
| SN74HCT574N | Octal D flip-flop, 3-state | 1 |
| **Total** | | **37** |

**Not counted, not chosen yet:** the 25.175 MHz clock oscillator, and the
battery and power-fail switch that hold the interim ROM's /CE high while
power is off (CPU.md, "Memory parts").  The SN74F32 and SN74F04 in older
versions of TIMING.md were removed (the memory control and I/O decode PLDs
took their jobs), and the ROM/RAM select PLD became the CD74ACT273E.

## Future features

From [FEATURE_PLAN.md](FEATURE_PLAN.md).  None of these are built yet.

| # | Part number | Type | Function in the design |
|--:|---|---|---|
| 1 | SN74HC574N | Octal D flip-flop, 3-state | Shared port output latch at x5200: SCK / pad CLOCK, SD MOSI, SD /CS, pad LATCH (HC for a full 5 V high into the SNES pads) |
| 2 | SN74F138N | 3-to-8 decoder | Keyboard column driver: drives column A2:A0 low on /PORT_RD |
| 3 | SN74F541N | Octal buffer, 3-state | Shared port input at x5200: keyboard rows, both SNES pad DATA lines, SD MISO |
| 4 | CD4050BE | Hex non-inverting buffer | Level shift to 3.3 V for the SD card's SCK, MOSI and /CS |
| 5 | not chosen | 3.3 V regulator | Powers the SD card and the CD4050 |

The two expansion ports (x5500, x5600) need connectors only.

### Tally

| Part number | Type | Qty |
|---|---|--:|
| SN74HC574N | Octal D flip-flop, 3-state | 1 |
| SN74F138N | 3-to-8 decoder | 1 |
| SN74F541N | Octal buffer, 3-state | 1 |
| CD4050BE | Hex buffer / level shifter | 1 |
| 3.3 V regulator (not chosen) | Voltage regulator | 1 |
| **Total** | | **4 logic chips + 1 regulator** |

With the future features the Placard comes to 41 chips plus the regulator.
Features cut from the plan, such as the frame counter or an SPI shifter, are
listed with their cost in FEATURE_PLAN.md, "Cut for now", and are not
counted here.
