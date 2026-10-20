# Schematic plan

Date: 2026-10-20

How the KiCad schematic (`kicad/`) is split into sheets: how many sheets,
which chips, connectors and passives go on each, and which nets run between
them.  This is a plan only; no sheet is drawn yet.  Chip numbers are the
`#` column of [CHIPS.md](CHIPS.md) and become the U-numbers (U1-U41, with
the gaps U24, U28, U30, U33 and U34 left empty, so every document's chip
numbers stay right).

## Summary

**Main board: 11 sheets** (a root sheet and 10 sub-sheets), A3 landscape,
in the one project `kicad/placard.kicad_pro`.
**Cartridge: 1 sheet**, its own project `kicad/cartridge/`, because it is
a separate board (a KiCad project has one PCB).

| Sheet | Title | Chips | Connectors and main passives |
|--:|---|---|---|
| 1 | Root: block diagram | none | sheet boxes only, drawn like `reference/placard_block_diagram.png` |
| 2 | Power and clock | U40 3.3 V regulator, U41 74AC32 clock gate, oscillator X1 | USB-C power input, polyfuse, bulk capacitor, HOLD 10k pull-up, RUN pull-down, HOLD/RUN bring-up jumpers |
| 3 | Control | U1 State, U2 Branch, U17 instruction register | bring-up straps S1-S3 (State socket pins) |
| 4 | Program counter and address mux | U3, U4 PC low/high, U7-U10 address mux | none |
| 5 | ALU and registers | U5, U6 ALU, U19 AC, U20 X, U21 Y | none |
| 6 | Data bus | U18 D register, U26 D source F541, U27 AC source F541 | 8 series resistors (source bus to data bus), 3.3k read-bus pull-up SIP |
| 7 | Memory and I/O decode | U11 memory control, U12 I/O decode, U25 map register, U31, U32 RAM | cartridge slot (Molex 87715-9106), /CART pull-up |
| 8 | Video timing | U13 H counter, U14 V counter, U15 Sync, U35 audio/mode slot PLD, U29 line read F541 | strap S4 (audio PLD) |
| 9 | Video and audio out | U22 pixel buffer, U23 line code, U16 color decoder, U36 audio DAC register | VGA resistor DAC (8 resistors) and DE-15, R-2R ladder, filter, headphone jack J6, strap S5 (line code) |
| 10 | Shared port | U37 port latch, U38 port PLD, U39 row F541 | J1 keyboard, J2/J3 SNES, J4 SD (dividers R6-R11, MISO diode and pull-up), J5 PS/2 (diodes, 4.7k pull-ups), row pull-ups, pad DATA pull-ups |
| 11 | Expansion slots | none | four 2 x 20 card-edge slots, SEL resistors (1k) |

That puts 35 chips plus the regulator and oscillator on nine sheets, no more
than six chips on a sheet, so each sheet can be drawn with large text and
room to lay out the blocks and nets first (the drawing style for this
project).  Each chip's 100 nF decoupling capacitor is drawn next to that
chip on its own sheet (see "Decoupling" below).

## Hierarchical or flat

**Hierarchical sheets, joined by global labels.**  Every sub-sheet is used
once, so the hierarchy is only for organization.  The root sheet holds the
sheet boxes arranged like the block diagram, with no hierarchical pins.
The nets between sheets are global labels and buses with the names below.

- Sheet boxes with pins would need 40-60 pins on the busiest boxes (the
  address mux, the data bus) and would crowd the root.  Global labels keep
  every sheet readable on its own and the root a clean block diagram.
- The cost of global labels is that a misspelled label makes a new net
  silently.  The ERC catches a label with only one end ("global label not
  connected anywhere else"), so run it after each sheet and fix every one.
- Buses use KiCad vector buses `A[0..15]`, `D[0..7]` and so on, drawn as
  one thick line with a bus entry for each bit, and the pins keep their own
  names (`A0`, `A1`), as the project rules ask for the VHDL too.

## Inter-sheet nets

Signal names are the PLD pin names (active low as `/NAME`).  "From" is the
sheet that drives the net.

### Buses

| Bus | Bits | From | To |
|---|---|---|---|
| `A[0..15]` | address bus (address mux outputs) | 4 | 7 (RAM, memory control, I/O decode, cartridge), 10 (A0 port PLD), 11 (A7:A0) |
| `D[0..7]` | data bus: memory, I/O and card reads | 6 (series resistors), 7 (RAM, cartridge), 8 (line read), 10 (port PLD D7/D6, row F541), 11 (cards) | 3 (instruction register, State PLD D4:D2), 6 (D register), 9 (pixel buffer) |
| `SD[0..7]` | source bus: D or AC, write data | 6 (source F541s) | 4 (PC load, address mux D inputs), 5 (ALU B), 7 (map register D), 10 (port latch D), 11 (cards), through the series resistors to `D[0..7]` |
| `F[0..7]` | ALU result | 5 | 5 (AC, X, Y inputs), shown on one sheet only |
| `I[0..7]` | instruction register outputs | 3 | 3 (State and Branch decode), 5 (ALU S2:S0, CIN), 8 (I1 to the audio PLD), 6 (I1 to U26 /OE2) |
| `X[0..7]`, `Y[0..7]` | X and Y register outputs | 5 | 4 (address mux), 7 (Y7 to I/O decode) |
| `AC[0..7]` | accumulator outputs | 5 | 5 (ALU A), 6 (U27 inputs) |
| `DR[0..7]` | D register outputs | 6 | 6 (U26 inputs), 4 (address mux D/X inputs) |
| `PC[0..15]` | program counter | 4 | 4 (address mux), 7 (PC15 to I/O decode) |
| `H[0..9]`, `V[0..9]` | video counters | 8 | 4 (video address into the muxes), 7 (H9 to I/O decode), 9 (H2:H0 to the color decoder) |
| `R0`, `R1`, `R7`, `R8` | line-repeat video address bits | 8 (audio PLD) | 4 (address mux C inputs) |
| `PIX[0..7]` | pixel buffer outputs | 9 | 9 (color decoder, line code, DAC register) |
| `RAMSEL[0..7]` | map register outputs | 7 | 7 (memory control), shown on one sheet only |

### Single nets

| Net | From | To |
|---|---|---|
| `CLK` | 2 (U41 clock gate) | every clocked chip on 3-9, 11 |
| `OSC` | 2 (oscillator) | 2 (U41), 7 (cartridge A20) |
| `HOLD` | 7 (cartridge B18) | 2 (U41, 10k pull-up) |
| `RUN` | 7 (cartridge A19) | 2 (pull-down), 7 (memory control pin 17, map register /MR), 11 (/RESET on every slot) |
| `PIXEL_ENABLE` | 8 (Sync pin 19) | 3 (State, Branch), 4 (PC PLDs), 7 (memory control, cartridge A18) |
| `ADDR_SEL`, `ADDR_SEL_HI`, `ADDR_SEL_LO` | 8 (Sync) | 4 (mux selects), 7 (I/O decode) |
| `H_VIDEO_ACTIVE`, `V_VIDEO_ACTIVE`, `VIDEN`, `HSYNC`, `VSYNC` | 8 | 9 (DAC register clock, color decoder, VGA connector) |
| `PC_ENABLE`, `X_ENABLE`, `Y_ENABLE`, `Q0` | 3 (State) | 4 (PC, mux), 8 (Sync) |
| `/LOAD_INSTR`, `/LOAD_IMM`, `/LOAD_AC`, `/LOAD_X`, `/LOAD_Y` | 3 (State) | 3, 6, 5 (register /E); `/LOAD_IMM` also 7 (I/O decode) and 11 (slot LOAD_IMM contact; check its polarity against EXPANSION.md when drawing) |
| `RW` | 3 (State pin 23) | 7 (memory control, I/O decode), 11 |
| `/SRC_EN` | 3 (Branch pin 16) | 6 (U26, U27 /OE1), 7 (memory control pin 22, cartridge B17) |
| `/PIX_LD` | 3 (Branch pin 15) | 9 (pixel buffer /E) |
| `LOAD_PC_LOW`, `LOAD_PC_HIGH`, `STALL` | 3 (Branch) | 4 (PC PLDs) |
| `Z_LOW`, `Z_HIGH`, `COUT`, `NEG` | 5 (ALU) | 3 (Branch) |
| `CARRY` | 3 (Branch pin 20) | 5 (ALU CIN) |
| `/AC_SEL` | 8 (audio PLD pin 21) | 6 (U27 /OE2) |
| `/MODE_LD`, `BLANK_RD` | 8 (audio PLD) | 9 (line code /E), 8 (Sync) |
| `LC2`, `LC3` | 9 (line code Q3:Q2) | 8 (audio PLD) |
| `/WE`, `/RAM_OE`, `/ROM_OE` | 7 (memory control) | 7 (RAM, cartridge A17), 11 (/WE on every slot) |
| `/CE_HI` | 7 (I/O decode) | 7 (RAM upper chip, cartridge B16) |
| `/MAP_WR`, `/LINE_RD` | 7 (I/O decode) | 7 (map register clock), 8 (U29 /OE) |
| `/PORT_WR`, `/PORT_RD` | 7 (I/O decode) | 10 |
| `/EXP1`, `/EXP2` | 7 (I/O decode) | 11 |
| `+5V`, `+3V3`, `GND` | 2 | power symbols on every sheet; `+3V3` only on 10 (SD card) |

The control sheet (3) and the memory sheet (7) are the two with the most
labels; the plan keeps the State and Branch PLDs together so their
mutual nets (`Q0`, `PC_ENABLE`, `BRANCH_BLOCK`) stay local.

## Sheet notes

**2. Power and clock.**  USB-C receptacle (power only) with the two 5.1k
CC pull-downs, a polyfuse, a bulk electrolytic on +5 V, the MCP1700-3302
(U40) with its 1 µF in and out, the 25.175 MHz oscillator (X1), and the
74AC32 (U41) with the three spare gates' inputs tied to GND.  HOLD's 10k
pull-up and RUN's pull-down sit here next to the clock gate, with the
bring-up HOLD and RUN jumpers ([BRINGUP.md](BRINGUP.md)).  A power LED, if
wanted, goes here too.

**Decoupling.**  Every chip's 100 nF capacitor is drawn beside that chip
on its own sheet, between its VCC and GND pins, so a sheet shows each chip
with its capacitor (Justin, 2026-10-20).  That is 36 capacitors spread over
sheets 2-10, plus the bulk capacitors on sheet 2.  On the PCB each one is
placed at its chip's VCC pin.

Each decoupling capacitor takes its chip's number: C1 goes with U1, C31
with U31, and so on (Justin, 2026-10-20), so the gaps U24, U28, U30, U33
and U34 leave C24, C28, C30, C33 and C34 unused too.  C1-C41 are kept for
these; every other capacitor uses the sheet numbering below.

**3. Control.**  State and Branch PLDs side by side, the instruction
register to their left feeding `I[0..7]`.  Straps S1-S3 drawn as
do-not-fit jumpers at the State PLD.

**4. Program counter and address mux.**  The two PC PLDs on the left, the
four mux PLDs in a column on the right, `A[0..15]` leaving on the right
edge.  The mux inputs (PC, D, X, Y, video address) come in as buses on
the left.

**5. ALU and registers.**  The two ALU nibbles with the carry chain
between them, AC, X and Y under them on `F[0..7]`.

**6. Data bus.**  The D register, the two source F541s, the 8 series
resistors from `SD[0..7]` onto `D[0..7]` (CPU.md "One data bus"), and the
3.3k bussed SIP pulling `D[0..7]` up ([EXPANSION.md](EXPANSION.md)).  The
fallback write-data F541 (CPU.md "Fallback: the write-data buffer") can be
added here as a do-not-fit footprint if the prototype should keep that
option.

**7. Memory and I/O decode.**  The two RAMs, the memory control and I/O
decode PLDs, the map register, and the cartridge slot with its pinout from
EXPANSION.md (22 spares as no-connects).  The cartridge slot is here
because it carries the ROM and its chip selects.

**8. Video timing.**  H and V counters, Sync, the audio/mode slot PLD and
the line read F541 (V9:V2 onto the data bus).

**9. Video and audio out.**  Pixel buffer, line code register, color
decoder, the VGA resistor DAC from [COLORS.md](COLORS.md) and the DE-15;
the DAC register, R-2R ladder, filter and headphone jack J6 from
[SOUND.md](SOUND.md).  The existing `schematics/placard_audio_schematic.png`
is the reference for the audio half.

**10. Shared port.**  As `schematics/placard_io_schematic.png`, without the
I/O decode PLD (it is on sheet 7, its four port strobes come in as
labels).

**11. Expansion slots.**  Four slot symbols in a row, the shared buses
running across them, SEL tied per slot through 1k (slots 1, 2 GND; 3, 4
+5 V), `/EXP1` to slots 1 and 3, `/EXP2` to 2 and 4.

## Cartridge project

`kicad/cartridge/cartridge.kicad_pro`, one A3 sheet, sharing the symbol
libraries in `kicad/lib/` through its own `sym-lib-table`:

- the card-edge fingers (the 87715-9106 mating footprint, same contact
  names as the slot symbol),
- the loader PLD (`ATF22V10_CART.pld`, ATF22V10C-10PU),
- two AT28C256 EEPROMs and two AS7C256C SRAMs,
- decoupling, and the spare contacts brought to a test header or left
  open until their use is decided.

Five chips, so one sheet holds them comfortably.  The main board and the
cartridge share the net names on the connector (`A0`, `D0`, `/CE_HI`,
`OSC` and so on), so the two schematics read the same.

## Reference designators

- **Chips:** U = CHIPS.md number, fixed (KiCad annotation set to keep
  existing references).  The cartridge uses its own U1-U5.
- **Connectors:** keep J1-J6 as IO.md and SOUND.md use them; then J7 VGA,
  J8 cartridge slot, J9-J12 expansion slots 1-4, J13 USB-C.
- **Decoupling capacitors:** C = the chip's U-number (C1 for U1),
  set by hand and kept by the annotation.  On the cartridge, C1-C5 go
  with its U1-U5 the same way.
- **Other passives:** KiCad's "sheet number x 100" annotation (R201, C301, ...)
  makes a part's sheet obvious.  IO.md's R6-R11 (the SD dividers) would
  become R1001-R1006; update IO.md and the I/O drawing when sheet 10 is
  drawn.

## Drawing order

When the sheets get drawn: 2 (power and clock) first, so every sheet has
its power symbols; then 4 and 7 (the address and memory side that
bring-up tests first), then 3, 5, 6, 8, 9, 10, 11, and the root
last, once the sheet boxes' sizes are known.
