# Chip-count review

Date: 2026-10-19

Proposal 1 is not applied; proposals 2 and 3 were applied on 2026-10-18.
The design was 41 chips plus a 3.3 V regulator and is now 39 (CHIPS.md).
(2026-10-19: the video delay F574 was also removed, see VIDEO_TIMING.md
"Delay register removed"; the design is now 38.)
Three changes remove a chip each; the rest of the design was checked and
has no other chip to remove with parts in stock.  Per the standing note to
hold optimization until the project is near done, 1 waits.

## Proposed

### 1. The source-bus 74F138 goes into the high address-mux PLDs (-1)

The '138 decodes `instReg(1:0)` into the enables of the three source-bus
74F541s.  Each F541 has two active-low enables, so with the two inverted
bits !S1 and !S0 the decoder is not needed:

| Source | S1:S0 | 74F541 /OE1 | /OE2 |
|---|---|---|---|
| D | 0x | S1 | GND |
| AC | 10 | S0 | !S1 |
| X | 11 | !S0 | !S1 |

The two inverters come from pins the high-byte address-mux PLDs waste
today: their A source is the zero page high byte, wired to GND on four
pins each (pins 1, 5, 11 and 16).  Writing that source as 0 in the
equations instead (when the selects pick it, the output is 0) frees those
pins.  Pin 16 is an I/O pin, so each of the two PLDs takes one select bit
on pin 1 and puts out its inverse on pin 16:

    high mux, bits 11:8:   PIN 1 = S0;   PIN 16 = NS0;   NS0 = !S0;
    high mux, bits 15:12:  PIN 1 = S1;   PIN 16 = NS1;   NS1 = !S1;

- **Timing gets better.**  The D source loses the decoder entirely (IR
  clock-to-Q, then the F541 enable), and AC and X go through a 7.5 ns PLD
  instead of the '138's 9 ns.  The source-bus paths in TIMING.md (the
  ALU path and the store data path) each gain 1.5 ns.
- **Cost:** the high-byte muxes need their own PLD file (the low byte
  keeps `ATF22V10_QUAD_MUX.pld`), and the FPGA model needs no change
  (`srcBusProc` already selects by `instReg(1:0)`).
- **Alternative** that leaves the mux PLDs alone: the branch PLD's free
  pin 15 and the audio PLD's free pins 16 and 21.  (When this was written
  the branch PLD also had pins 14 and 16 free; since 2026-10-18 they carry
  COUT and SRC_EN.)  That uses up spare pins kept for later features, so
  the mux version is better.

### 2. The SD level shifter becomes three resistor dividers (-1) — applied 2026-10-18

Applied at Justin's request: 1.8k over 3.3k on SCK, MOSI and /CS (IO.md,
"SD card"); MISO keeps its diode onto row 7 and needs no buffer.  The
notes below are the proposal as written.

The CD74HC4050E only shifts SCK, MOSI and /CS from 5 V to 3.3 V.  A
divider per line (for example 1.8k from the latch, 3.3k to ground, giving
3.2 V) does the same at the drivers' speeds: SCK is at most about 1 MHz
bit-banged, and 1.2k of source impedance into about 10 pF of card input is
a 12 ns edge.  Many 5 V SD adapters work this way.

- **Cost:** about 1.5 mA per line while it is high; the latch rests with
  SCK and MOSI high (FB), so about 3 mA at rest.  The card's input high
  threshold (0.625 x 3.3 V = 2.1 V) is met with margin.
- The 3.3 V regulator stays: the card needs it.

With 1 and 2, the count goes from 41 to **39 chips plus the regulator**.

### 3. One bus: drop the RAM write-data buffer (-1) — applied 2026-10-18

Applied at Justin's request (branch PLD revision 10, memory control PLD
revision 06, CPU.md "One data bus"), with the write-data buffer kept as
a fallback for the prototype (CPU.md, "Fallback: the write-data
buffer").  The notes below are the proposal as written.


Today the source bus (D, AC or X through three F541s) is driven all the
time and the RAM/ROM data bus is separate; the write F541 (CHIPS.md chip
29) joins them only while /WE is low.  The source bus is only needed in
EXEC (ALU, PC low byte, store data, map and port latches), and the CPU
does not need a memory read in EXEC, so the two buses can be one:

- **Source drivers on only in EXEC, off during video reads.**  The source
  '138's three enables are unused today: G1 = Q0, /G2A = PC_ENABLE (!Q1),
  /G2B = PIXEL_ENABLE.  No new logic.
- **No CPU memory read in EXEC.**  The branch PLD already has Q0,
  PC_ENABLE and PIXEL_ENABLE; one of its free pins (14-16) outputs
  `SRC_EN = Q0 & !PC_ENABLE & !PIXEL_ENABLE` into the memory control PLD's
  free pin 22, and `CPU_READ` gains `& !SRC_EN`.  The I/O read strobes are
  already limited to the LOAD states (`RD = IO & RW & LOAD_IMM`,
  ATF22V10_IO_DECODE.pld).
- **Timing (estimated, not in TIMING.md yet).**  Source bus valid about
  24 ns into EXEC (State PLD tCO 5.5, '138 enable 9 assumed, F541 enable
  9.5): the same as today's FETCH→EXEC path, a single-clock logic op still
  fits (+6), and store data is valid well before the end of the write.
  LOAD→EXEC with source D gets later (D clock-to-Q + F541 was 16.5 ns).
  After a video stall PIXEL_ENABLE falls at 10 ns, so the bus is valid at
  about 28.5 ns; a single-clock logic op then has about +1.7.
- **Cost: bus overlap at the start of EXEC.**  The read in the clock
  before EXEC ends at the rising edge, but the RAM/ROM can drive for up to
  about 14.5 ns after it (/OE rise plus tOHZ), while the source F541s can
  turn on about 7 ns after it.  Up to about 7 ns of contention on every
  instruction, the kind TIMING_FIXES.md removed.  Justin (2026-10-18):
  acceptable with series resistors to limit the current, for example a
  resistor array between the three source F541 outputs and the shared bus.
  Size them against the extra RC delay on the ALU path (for example 47 R
  into about 50 pF is about 2.4 ns).
- **Map and port latches** load at the end of a write, up to 7.5 ns after
  the edge; the source drivers can turn off about 7 ns after it, so the
  bus floats for a moment (the 10k pull-ups hold it).  Check the hold.
- **Clashes with proposal 1.**  Without the '138 there are no spare
  enables; the gating would have to come through the high mux PLDs, and a
  PLD-to-PLD path (branch PLD then mux PLD) leaves only about +0.2 ns for
  a logic op.  Take one or the other, or feed Q0 and PC_ENABLE to the mux
  PLDs directly.
- **FPGA model:** no change needed in behaviour (it keeps the buses apart
  internally); the PLD files (branch, memory control) and CPU.md,
  TIMING.md and CHIPS.md change.

With 2 and 3 applied the count is 39.  Adding 1 as well (only if its
clash with 3 is solved) makes it 38.

## Checked and not worth it

| Idea | Why not |
|---|---|
| One 128K x 8 SRAM for the RAM (and one for the ROM cartridge) | No 15 ns 128K x 8 part is made in DIP: Alliance's AS7C1024B is TSOP and SOJ only, and the DIP 128K parts (AS6C1008) are 55 ns |
| Folding the port PLD into a PLD with free pins | None of the PLDs with free pins sees the port latch, A0 or /PORT_RD, and the I/O decode PLD is full (IO.md) |
| Keyboard columns straight from the latch | Needs 8 latch bits; the latch's 4 low bits carry SPI, pads and PS/2 |
| Pad DATA on the key rows (dropping the port PLD's read outputs) | The pads drive DATA low after the 16th bit and can't be released, so they would pull rows low during a key scan |
| Line read: the V counter PLD drives the bus itself | Its V outputs are in use all the time, so they can't be 3-state |
| Line read moved into the shared port | The port buffer's 8 inputs are rows; the V bits would corrupt key reads |
| D, AC and X registers with 3-state outputs (dropping the source F541s) | Their outputs also feed the ALU and the address mux all the time; and an 8-bit register with clock enable and 3-state outputs (the 74F825 family) is unlikely to be in active DIP stock (not checked) |
| Map register inside the memory control PLD | It has no free pins (pin 22 became SRC_EN on 2026-10-18) and already takes all 8 map bits as inputs |
| Audio DAC register shared with the line code register | Both hold a byte for the whole line: one the mode, one the sample |
| Video delay F574 into the color decoder | The color decoder uses all 24 pins.  (Done another way on 2026-10-19: the Sync PLD makes H2:H0 and VIDEN two clocks later itself, so the F574 is gone; VIDEO_TIMING.md) |
| H counter, V counter and sync in fewer PLDs | Each uses all 10 outputs |

## Free PLD pins

As of 2026-10-19 (the design as built, without proposal 1).  Product-term
counts and the spare terms in every cell are in [PLD_USAGE.md](PLD_USAGE.md).

| PLD | Free pins |
|---|---|
| Branch | 15 (I/O, 10 terms) |
| Audio slot | 16, 21 (I/O, 12 terms each) |
| H counter | 6-11, 13 (inputs); 2 is declared RESET but used by no equation |
| V counter | 3-11, 13 (inputs) |
| Port | 9, 10, 11, 13 (inputs) |
| All others | none |

Proposal 1 would also free pins 5 and 11 (inputs) on each high address mux.
