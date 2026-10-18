# Chip-count review

Date: 2026-10-18

A proposal, not applied.  The design is 41 chips plus a 3.3 V regulator
(CHIPS.md).  Two changes remove a chip each without giving up anything;
the rest of the design was checked and has no other chip to remove with
parts in stock.  Per the standing note to hold optimization until the
project is near done, nothing here changes a source file yet.

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
  pins 14-16 and the audio PLD's free pins 16 and 21 (2 inputs, 2
  outputs).  That uses up spare pins kept for later features, so the mux
  version is better.

### 2. The SD level shifter becomes three resistor dividers (-1)

The CD74HC4050E only shifts SCK, MOSI and /CS from 5 V to 3.3 V.  A
divider per line (for example 1.8k from the latch, 3.3k to ground, giving
3.2 V) does the same at the drivers' speeds: SCK is at most about 1 MHz
bit-banged, and 1.2k of source impedance into about 10 pF of card input is
a 12 ns edge.  Many 5 V SD adapters work this way.

- **Cost:** about 1.5 mA per line while it is high; the latch rests with
  SCK and MOSI high (FB), so about 3 mA at rest.  The card's input high
  threshold (0.625 x 3.3 V = 2.1 V) is met with margin.
- The 3.3 V regulator stays: the card needs it.

With both, the count goes from 41 to **39 chips plus the regulator**.

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
| Map register inside the memory control PLD | It has one free pin and takes all 8 map bits as inputs |
| Audio DAC register shared with the line code register | Both hold a byte for the whole line: one the mode, one the sample |
| Video delay F574 into the color decoder | The color decoder uses all 24 pins |
| H counter, V counter and sync in fewer PLDs | Each uses all 10 outputs |

## Free PLD pins after this proposal

| PLD | Free pins |
|---|---|
| Branch | 14, 15, 16 (I/O) |
| Audio | 16, 21 (I/O) |
| Memory control | 22 (I/O) |
| Port | 9, 10, 11, 13 (inputs) |
| High address muxes | pins 5 and 11 on each (inputs) |
| H counter, V counter | inputs only (no free outputs) |
