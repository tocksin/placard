# Chip list

Date: 2026-11-11

Every chip in the Placard, one chip per line.  The numbers are the U
numbers on the schematic and the board; numbers missing from the list are
not used.  The PLD sources are in `src/pld`, the CPU in [CPU.md](CPU.md),
the shared port in [IO.md](IO.md) and the timing in
[TIMING.md](../timing/TIMING.md).  Stock moves, so recheck before
ordering.

## Main board

| # | Part number | Type | Function in the design |
|--:|---|---|---|
| 1 | ATF22V10C-7PX | PLD (22V10, 24-pin) | State machine: FETCH / LOAD / EXEC, register loads (active low, to the F377 /E pins and the IR PLD), R/W; frozen by STALL_OUT from the cartridge (`ATF22V10_STATE.pld`) |
| 2 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Branch decode, LoadPCLow/High, ADD/SUB wait clock and STALL, /SRC_EN to the source F541s' /OE1 and the memory control, carry flag for BCS/BCC (COUT from the high ALU PLD on pin 14), /PIX_LD for the pixel buffer (pin 15) (`ATF22V10_BRANCH.pld`) |
| 3 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, low byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 4 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Program counter, high byte: 8-bit loadable counter (`ATF22V10_PC_COUNTER8.pld`) |
| 5 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, low nibble: 4-bit ALU with Z flag (`ALU_SHR.pld`) |
| 6 | ATF22V10C-7PX | PLD (22V10, 24-pin) | ALU, high nibble: 4-bit ALU with Z flag, F3 is the sign (`ALU_SHR.pld`) |
| 7 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 1:0 and 9:8: PC / D / X / video address (low bits), PC / zero page / Y / video address (high bits); the selects are PIXEL_ENABLE, PC_ENABLE, X_ENABLE and Y_ENABLE (`ATF22V10_QUAD_MUX.pld`, FETCH_TIMING.md) |
| 8 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 3:2 and 11:10 (`ATF22V10_QUAD_MUX.pld`) |
| 9 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 5:4 and 13:12 (`ATF22V10_QUAD_MUX.pld`) |
| 10 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Address mux, bits 7:6 and 15:14 (`ATF22V10_QUAD_MUX.pld`) |
| 11 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Memory control: /RAM_OE, /ROM_OE from the map, in the low half of the clock; /ROM_OE only while RUN from the cartridge is high (`ATF22V10_MEM_CTRL.pld`) |
| 12 | ATF22V10C-7PX | PLD (22V10, 24-pin) | I/O decode: upper 32K /CE_HI (from PIXEL_ENABLE, PC_ENABLE, Y_ENABLE, H9, PC15, Y7) and the x5000-x53FF strobes (`ATF22V10_IO_DECODE.pld`) |
| 13 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video H counter: H9:H3, HSYNC, horizontal active, blank line from mode byte bit 7 (`ATF22V10_HCOUNT.pld`) |
| 14 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video V counter: V9:V0 (`ATF22V10_VCOUNT.pld`) |
| 15 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Video sync: H2:H0 (also the color decoder's pixel select), /VSYNC, VIDEN, PIXEL_ENABLE, and the RAM /WE from the early clock tap CLK_E on pin 9 (`ATF22V10_SYNC.pld`) |
| 16 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Color decoder: pixel byte and line code to VGA RGB (`ATF22V10_COLORDECODER.pld`) |
| 17 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Instruction register: loads the opcode on /LOAD_INSTR, holds 02h (`ld ac, ac`) while RUN is low so the CPU only walks the image while the cartridge loads (`ATF22V10_IR.pld`) |
| 18 | SN74F377AN | Octal D flip-flop with enable | D register (immediate / memory operand) |
| 19 | SN74F377AN | Octal D flip-flop with enable | Accumulator (AC) |
| 20 | SN74F377AN | Octal D flip-flop with enable | X register |
| 21 | SN74F377AN | Octal D flip-flop with enable | Y register |
| 22 | SN74F377AN | Octal D flip-flop with enable | Video pixel buffer (byte read from video memory); /E from the Branch PLD's /PIX_LD (pin 15), low on a video read |
| 23 | CD74HCT377E | Octal D flip-flop with enable | Video line code (the row's mode byte): D from the pixel buffer outputs, /E from /MODE_LD, so it copies the mode byte read in group 45 (see VIDEO.md); Q1:Q0 to the color decoder, Q3:Q2 to the audio slot PLD (line repeat), Q6:Q4 to the row tint resistors, Q7 to the H counter (blank line).  HCT because the tint outputs source about 3 mA |
| 25 | CD74ACT273E | Octal D flip-flop with clear | ROM/RAM map register at x5000 (write only, /MR = RUN: all ROM until the cartridge hands off) |
| 26 | SN74F541N | Octal buffer, 3-state | Source bus driver: D register, sources 00 and 01 (/OE1 = /SRC_EN, /OE2 = I1; the source bus is also the memory data bus) |
| 27 | SN74F541N | Octal buffer, 3-state | Source bus driver: accumulator, sources 10 and 11 (/OE1 = /SRC_EN, /OE2 = /AC_SEL from the audio slot PLD) |
| 29 | SN74F541N | Octal buffer, 3-state | Video line read at x5000: V9:V2 onto the data bus, enabled by /P0 (I/O decode PLD) and Q0 |
| 31 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, lower 32K (x0000-x7FFF) |
| 32 | AS7C256C-15PCN | SRAM, 32K x 8, 15 ns | RAM, upper 32K (x8000-xFFFF) |
| 35 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Audio and mode slots, row address: picks group 45 for the mode byte read and group 46 or 47 for the audio read, makes /MODE_LD for the line code register, and remaps video address bits A0, A1, A7, A8 for the line repeat (`ATF22V10_AUDIO.pld`, see SOUND.md and VIDEO.md).  Also /AC_SEL (= !I1, revision 04) for the AC source F541 |
| 36 | SN74HCT574N | Octal D flip-flop, 3-state | Audio DAC register: copies the sample from the pixel buffer when H_VIDEO_ACTIVE rises (start of group 48), drives the R-2R ladder, which drives the audio line out directly (all passive, no headphone amplifier, see SOUND.md) |
| 38 | ATF22V10C-7PX | PLD (22V10, 24-pin) | Shared port: the port latch (SCK and pad CLOCK, MOSI and pad LATCH, SD /CS, PS/2 DATA hold, PS/2 keyboard CLK hold), clocked by /WE while /PORT is low (rev 05); SD MISO and the free PS/2 clock onto D7/D5 on reads of x5200, pad DATA onto D7/D6 on reads of x5201 (`ATF22V10_PORT.pld`, rev 05) |
| 40 | MCP1700-3302E/TO | 3.3 V LDO regulator (TO-92) | Powers the SD card (its SCK, MOSI and /CS come down to 3.3 V through resistor dividers, IO.md) |
| 42 | ATF22V10C-7PX | PLD (22V10, 24-pin) | PS/2 receiver shifts one byte in from the PS/2 keyboard or mouse on the device's clock (RXCLK, the two clock lines diode-ORed), holds the device off after its stop bit, byte onto D7:D0 at x5202, ready flag onto D7 at x5203, re-armed by a write to x5202/x5203 (`ATF22V10_PS2.pld`, IO.md "PS/2 receiver") |

### Tally

| Part number | Type | Qty |
|---|---|--:|
| ATF22V10C-7PX | PLD (22V10) | 20 |
| SN74F377AN | Octal D flip-flop with enable | 5 |
| CD74HCT377E | Octal D flip-flop with enable (line code) | 1 |
| CD74ACT273E | Octal D flip-flop with clear | 1 |
| SN74F541N | Octal buffer, 3-state | 3 |
| AS7C256C-15PCN | SRAM, 32K x 8 | 2 |
| SN74HCT574N | Octal D flip-flop, 3-state | 1 |
| **Total** | | **33 + a 3.3 V regulator** |

**Not counted:** the 25.175 MHz clock oscillator, and the series
resistors (8, one per bit) between the source F541 outputs and the data
bus, which limit the current while the bus changes hands at the start of
EXEC (CPU.md, "One data bus").

## ROM cartridge

Not counted above:

| Part number | Type | Function |
|---|---|---|
| AS7C256C-15PCN (2) | SRAM, 32K x 8, 15 ns | The ROM as the CPU sees it; /WE from the cartridge PLD |
| AT28C256-15PU (2) | EEPROM, 32K x 8, 150 ns | The ROM image, programmed off the board; copied into the SRAMs at power-up |
| ATF22V10C-7PX | PLD (22V10, 24-pin) | Loader: holds the CPU's STALL at each PC address, makes the EEPROM /OE and SRAM /WE, raises RUN at the PC wrap (`ATF22V10_CART.pld` revision 04) |

Five chips.

**Two cartridge boards.**  The 64K cartridge
(`kicad/cartridge_64k`) has the five chips above: U1 loader PLD, U2/U3
EEPROMs (lower/upper), U4/U5 SRAMs (lower/upper).  The 32K cartridge
(`kicad/cartridge_32k`) is its own, smaller board with three: U1 loader
PLD, U2 EEPROM, U3 SRAM, both /CE tied to GND, so its 32K is seen in both
halves of the ROM space.  The case mounting hole H1 is at the same place
on both.

## PLD speed grade

Every PLD, on the main board and the cartridges, is an ATF22V10C-7PX
(PDIP-24): one part number to buy, program and kit.  The -7 is the fastest
22V10 grade made in DIP; the paths through each PLD are in
[TIMING.md](../timing/TIMING.md).
