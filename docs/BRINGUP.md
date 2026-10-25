# Bring-up: build order and a test for each chip

Date: 2026-10-25

This is the order to put the chips in, with a quick test after each one.
Every test needs only a multimeter with DC volts and a frequency counter
(and a VGA monitor from step 5 on).  These are assembly checks: they find a part that is
missing, wrong, reversed or badly soldered, and they take the design
itself as proven.  The power input goes in
first, alone, so a wiring or polarity fault there can't reach a chip.  The
video section comes next because it runs with no software.  The CPU comes next: it runs a known
pattern with no memory at all (the "FF free run"), and then the bring-up
test ROM checks the rest of the CPU and the memory by itself.  The I/O and
the audio go in last, and the ROM shows their state on the screen.

Every part is named by its reference designator on the schematic.  The
chips' U numbers are their numbers in [CHIPS.md](CHIPS.md); a part on the
cartridge is called "cartridge Un".  The expected
readings come from `src/scripts/bringup_signals.py`, a clock-by-clock model
of the PLD equations as they are wired at each step.  The test ROM is made
by `src/scripts/gen_bringup.py` and checked by
`src/scripts/test_bringup_sim.py` (see [The bring-up ROM](#the-bring-up-rom)).

## Before you start

**Sockets.**  Put every chip in a socket.  Each step fits only the
sockets for its own chips, each with its 100 nF decoupler (Cn sits beside
Un), and checks them before a chip goes in: power on, +5 V on the
socket's power pin and 0 V on its ground pin (24-pin PLDs pins 24 and 12;
20-pin chips (F377, F541, ACT273, HC574, HCT574) 20 and 10; the 28-pin
RAMs 28 and 14).  A few sockets go in a step or more early, empty,
because a temporary resistor ("strap") or a test pull-down plugs into
them; the step says so.  Each strap is described in the step that puts
it in and the step that takes it out.  The steps add chips one at a
time, and the CPU steps take the RAM out again for a while.

**Programming.**  Each PLD and EEPROM is programmed in the step that
fits it, just before it goes in, not all at the start.  So a chip always
carries the equations current when it is fitted, and a fault found in one
step is fixed in the source before the later chips are made.  You need a
programmer that handles the ATF22V10C (every PLD is an ATF22V10C-7PX) and
the AT28C256 EEPROM.  Each PLD's JED file is the one WinCUPL makes from
its `.pld` file in `src/pld`; each step names the file and its revision.
For every chip:

1. Program it.
2. Verify it (the programmer reads it back and compares).
3. Label it with its reference designator and the revision (a sticker on
   top), so chips that share a file (U3/U4, U5/U6, U7-U10) stay apart
   from the others.
4. Fit it.

**Without the cartridge.**  The main board's STALL_OUT pull-up keeps the
CPU stalled until a cartridge lets it go, and RUN's pull-down keeps the
ROM off and the instruction register PLD at 02h.  For the steps before
the cartridge is built, fit two jumpers: STALL_IN to STALL_OUT (JP1:
the Branch PLD's STALL reaches the State and PC PLDs directly) and RUN to
+5 V (JP2: the board reads the ROM and the IR loads opcodes).  Then
nothing loads the ROM SRAMs, so those steps only check what they can
without a ROM image (or with SRAMs loaded some other way).  Remove both
jumpers when the cartridge goes in.  The clock runs from power-up either
way.

**Reset.**  Reset is a power cycle.  SW1 (on/off toggle) and relay K1's
normally closed contact sit in series in the 5 V input after the
polyfuse.  SW2 (reset, a small tactile button) pulls in K1, so holding SW2
cuts the power and letting go powers the board up again (2026-10-22).  Hold
it for about half a second so the rail falls well below 1 V (the bulk
220 µF C41 sits ahead of K1, so only the 100 nF decouplers have to drain;
slower with chips missing during bring-up).  At power-up the ATF22V10C registers
start at 0, so the CPU starts in FETCH at x0000.  The cartridge stalls
the CPU while it loads its SRAMs (about 33 ms; the video runs and shows
the random RAM), and RUN holds the map register clear (all ROM) until it
hands off at x0000, which holds a nop.  To
restart, press SW2 or switch SW1 off and on.

**Floating inputs.**  An ATF22V10C holds an input that nothing drives at
its last level (a weak pin keeper), and an F-series input that floats reads
high.  So a missing chip is harmless unless a level matters, and those
places get a temporary resistor (a strap, from step 4 on).

**The data bus pull-ups.**  The 10k SIP on D7:D0 goes in at step 7.
With nothing driving it, the bus reads FF.  After a chip drives it and lets
go, the bus keeps that byte for about 0.5 µs (the 10k and the bus
capacitance), so "an empty bus reads FF" holds only when nothing has driven
it for a while.  That is why steps 11-16 run with the RAM taken out.

**Meter readings.**  The frequency is what the counter shows; the DC
average is what the volts range shows for a signal that toggles faster
than the meter can follow (the duty cycle times 5 V).  Many meters count
only up to about 10 MHz, so the fastest signals (the 25.175 MHz clock,
H0 at 12.59 MHz) may read wrong or zero; the slower bits next to them show
the same thing.  From step 11 on the CPU loses the clocks that video takes,
so its readings shift a little with the line and frame; read the average.

## Power

### Step 1: the power input, on/off switch and reset

Fit only the power input parts on the bare board (power sheet, 2026-10-22).
Leave U40, C40 and C47 (the 3.3 V regulator) for step 18, with the SD card.

| Part | What | Fitting note |
|---|---|---|
| J13 | USB-C receptacle (power only) | |
| R1, R2 | 5.1k, CC1 and CC2 to GND | without them a USB-C supply gives no 5 V |
| F1 | MF-RG300 polyfuse, 3 A hold | not polarised |
| D7 | SA5.0A TVS, fused VBUS (VFUSE) to GND | band (cathode) to VFUSE |
| SW1 | ANT11TFHQE toggle, on/off | |
| C41 | 220 µF 10 V electrolytic on VON (between SW1 and K1) | + to VON, stripe to GND |
| K1 | CIT J1071CS5VDC.36 relay; COM (pin 1) = VON, NC (pin 4) = +5V | |
| SW2 | PTS645VL58-2 tactile reset button, VON to the coil (KCOIL) | |
| D8 | BAT85 across K1's coil | band (cathode) to KCOIL |
| R59, D18 | 1k and the red 5 mm power LED, +5V (after K1) to GND | LED's long lead (anode) to R59, flat side (cathode) to GND |

**Before power** (meter on ohms and diode test, no supply plugged in):

- VBUS (F1's input) to GND and +5V (K1 pin 4) to GND: open, not a short.
- D7 on diode test from GND to VFUSE: about 0.6 V forward, open the other
  way.  Reversed, it shorts the supply and F1 trips.
- D8 on diode test from GND to KCOIL: about 0.3 V forward.  Reversed, it
  shorts VON as soon as SW2 is pressed.
- C41's + lead goes to VON (SW1's output side).

**Checks.**  Plug in a 5 V USB-C supply (3 A).  The empty C40 pads (the +5V side) and any GND pad make handy test
points.

| Check | SW1 | SW2 | Expect |
|---|---|---|---|
| VBUS and VFUSE | off | up | 4.75-5.25 V; stop if above 5.5 V |
| VON, +5V | off | up | 0 V |
| VON and +5V | on | up | the same as VFUSE, within 0.05 V |
| D18 (power LED) | on | up | lit |
| +5V | on | held | 0 V; K1 clicks, D18 goes dark |
| VON | on | held | still 5 V (C41 stays charged) |
| +5V | on | let go | back to 5 V, D18 lit |

Pass when every row above reads as listed.

## Video

### Step 2: the oscillator (X1)

Fit only the 25.175 MHz oscillator X1 and its decoupler C43 (100 nF);
every other part goes in with the step that first needs it.  X1 has no
socket: solder it in, with the can's dot or square corner (pin 1) on
the footprint's pin 1.

X1's pins are under the can, so probe at U15's bare pads (the Sync PLD;
its socket isn't in until step 3):

- Power on: +5 V on U15 pin 24 and 0 V on pin 12.
- X1's output (CLK) reads **25.175 MHz**, 2.5 V average, at U15 pin 1.  If the meter doesn't reach that, skip it: step 3 shows the
  clock divided down.

### Step 3: Sync PLD (U15)

**Sockets:** U15 with C15.

**Program first:** U15 Sync from `ATF22V10_SYNC.pld` (rev 09); verify
and label it.

Fit U15.  The Sync PLD's H2:H0 count the clock by themselves; no straps are needed yet.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| H0 (pin 14) | 12.59 MHz | 50 % | 2.50 V |
| H1 (pin 15) | 6.294 MHz | 50 % | 2.50 V |
| H2 (pin 16) | 3.147 MHz | 50 % | 2.50 V |

The other Sync pins depend on the counters and are checked in step 5.

### Step 4: H counter PLD (U13)

**Sockets:** U13 with C13.  Also fit the line code socket U23 (with
C23), empty, for strap S5.

**Program first:** U13 H counter from `ATF22V10_HCOUNT.pld` (rev 08);
verify and label it.

The H counter reads the line code's Q7 (blank line), so put in a strap
(a 10k resistor in an empty socket's pins, holding a line whose driver
isn't in yet; more in step 5):

- **S5**, in U23 (line code): three 10k, from pins 6, 9 and 19 (Q2, Q3,
  Q7) each to pin 10 (GND).  Q7 low keeps every line a video line; Q3:Q2
  low holds the line repeat at 1x for the audio PLD (step 6).  Out at
  step 7.

Fit U13.  H9:H3 count groups of 8 clocks, 28-127, 800 clocks a line.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| H3 (pin 14) | 1.573 MHz | 50.0 % | 2.50 V |
| H4 (pin 15) | 786.7 kHz | 50.0 % | 2.50 V |
| H5 (pin 16) | 377.6 kHz | 52.0 % | 2.60 V |
| H6 (pin 17) | 188.8 kHz | 52.0 % | 2.60 V |
| H7 (pin 18) | 94.41 kHz | 52.0 % | 2.60 V |
| H8 (pin 19) | 62.94 kHz | 64.0 % | 3.20 V |
| H9 (pin 20) | 31.47 kHz | 64.0 % | 3.20 V |
| /HSYNC (pin 21) | 31.47 kHz | 88.0 % | 4.40 V |
| H_VIDEO_ACTIVE (pin 22) | 31.47 kHz | 80.0 % | 4.00 V |
| H_TC (pin 23) | 31.47 kHz | 0.1 % | 0.01 V |

**31.47 kHz** on /HSYNC is the VGA line rate.

### Step 5: V counter PLD (U14)

**Sockets:** U14 with C14.  Also fit the State socket U1 (with C1) and
the audio socket U35 (with C35), empty, for straps S1 and S4.

**Other parts:** the VGA connector J7 and the sync series resistors R61
and R62 (47 ohm, beside U13 and U15).

**Program first:** U14 V counter from `ATF22V10_VCOUNT.pld` (rev 03);
verify and label it.

**Straps.**  A strap is a 10k resistor with its leads in an empty
socket's pins (or soldered to a spare socket that plugs in), holding a
control line whose driver isn't in yet.  The Sync outputs checked in
this step (PIXEL_ENABLE, ADDR_SEL) use three State PLD outputs and the
audio PLD's BLANK_RD, so put in:

- **S1**, in U1 (State): four 10k, from pins 15, 16, 17 and 18 each to
  pin 12 (GND).  Holds PC_ENABLE, X_ENABLE, Y_ENABLE and Q0 low, so the
  address muxes pick D (low byte) and 00 (high byte) outside video reads
  and /SRC_EN stays off.  Out at step 11.
- **S4**, in U35 (audio): pin 23 to pin 12 (GND).  Holds BLANK_RD low: no
  mode or audio reads.  Out at step 6.

Fit U14.  V9:V0 count lines, 499-1023, 525 lines a frame.  Connect a VGA monitor:
it should now lock to 640 x 480 at 60 Hz and show a **black screen** (the
colour decoder isn't in yet).

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| V0 (pin 14) | 15.7 kHz | 50.1 % | 2.50 V |
| V1 (pin 23) | 7.852 kHz | 50.1 % | 2.50 V |
| V2 (pin 22) | 3.956 kHz | 50.3 % | 2.51 V |
| V3 (pin 15) | 1.978 kHz | 50.3 % | 2.51 V |
| V4 (pin 16) | 959 Hz | 51.2 % | 2.56 V |
| V5 (pin 21) | 479.5 Hz | 51.2 % | 2.56 V |
| V6 (pin 20) | 239.8 Hz | 51.2 % | 2.56 V |
| V7 (pin 17) | 119.9 Hz | 51.2 % | 2.56 V |
| V8 (pin 18) | 59.94 Hz | 51.2 % | 2.56 V |
| V9 (pin 19) | 59.94 Hz | 97.5 % | 4.88 V |
| Sync VIDEN (pin 17) | 28.77 kHz | 73.1 % | 3.66 V |
| Sync /VSYNC (pin 18) | 59.94 Hz | 99.6 % | 4.98 V |
| Sync PIXEL_ENABLE (pin 19) | 2.302 MHz | 9.1 % | 0.46 V |
| Sync ADDR_SEL (pin 20) | 2.302 MHz | 9.1 % | 0.46 V |
| Sync V_VIDEO_ACTIVE (pin 23) | 59.94 Hz | 91.4 % | 4.57 V |

**59.94 Hz** on /VSYNC is the frame rate.  PIXEL_ENABLE here has only the
video reads; step 6 adds the mode and audio reads.

### Step 6: audio and mode slot PLD (U35)

**Sockets:** none new; U35's socket went in at step 5.

**Program first:** U35 audio and mode slots from `ATF22V10_AUDIO.pld`
(rev 04); verify and label it.

Take out strap S4 (the 10k from U35's pin 23 to pin 12) and fit U35.
BLANK_RD now picks group 45 (mode byte) and group 46
or 47 (audio sample) on every line, and R0, R1, R7, R8 are the row address
bits (1x line repeat while S5 holds Q3:Q2 low).

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| BLANK_RD (pin 23) | 62.16 kHz | 2.0 % | 0.10 V |
| /MODE_LD (pin 22) | 31.47 kHz | 99.0 % | 4.95 V |
| R0 (pin 17) | 15.7 kHz | 50.1 % | 2.50 V |
| R1 (pin 18) | 7.852 kHz | 50.1 % | 2.50 V |
| R7 (pin 19) | 119.9 Hz | 51.2 % | 2.56 V |
| R8 (pin 20) | 59.94 Hz | 51.2 % | 2.56 V |

### Step 7: Branch PLD (U2), pixel buffer (U22), line code (U23), colour decoder (U16)

**Sockets:** U2 with C2, U22 with C22 and U16 with C16 (U23's went in at
step 4).  Also fit the RAM socket U31 (with C31), empty, for the pull-
down tests below.

**Other parts:** the data bus pull-ups RN1 (10k SIP on D7:D0), the
colour resistors R14-R21 and the row tint parts R56-R58, D9-D11 (BAT85)
and D12-D17 (1N4148).

**Program first:** U2 Branch from `ATF22V10_BRANCH.pld` (rev 15) and U16
colour decoder from `ATF22V10_COLORDECODER.pld` (rev 07); verify and
label them.  U22 and U23 are 74-series and need no programming.

The Branch PLD goes in now only for /PIX_LD (pin 15), the pixel buffer's
load strobe; the rest of it waits for the CPU.  Take out strap S5 (the
three 10k from U23's pins 6, 9 and 19 to pin 10) and fit U2, U22, U23 and U16.

Nothing drives the data bus, so every video read is FF: the line code is
mode 3 (8 bpp, 4x repeat) and every pixel is FF.  The monitor shows a
**white screen** with a black border.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Branch /PIX_LD (pin 15) | 2.365 MHz | 90.6 % | 4.53 V |
| Colour decoder outputs (pins 15-22), bus FF | 28.77 kHz | 73.1 % | 3.66 V |

Then test each output with one temporary 1k pull-down at a time: a 1k
from a data pin of the empty RAM socket U31 to its pin 14 (GND) holds that
data bus bit low (1k against RN1's 10k gives about 0.45 V, a solid low).
The data pins are D0 = pin 11, D1 = 12, D2 = 13, D3 = 15, D4 = 16,
D5 = 17, D6 = 18, D7 = 19.  Bits 1:0 of the byte are also the mode, so
pulling D1 or D0 changes the mode:

| Pull-down on | Bus | Screen | Colour decoder pins |
|---|---|---|---|
| D7 (RAM pin 19) | 7F | no green 3 | GRN3 (pin 19) 0 V, the rest 28.77 kHz |
| D6 (RAM pin 18) | BF | | GRN2 (pin 20) 0 V |
| D5 (RAM pin 17) | DF | | GRN1 (pin 17) 0 V |
| D4 (RAM pin 16) | EF | | BLU3 (pin 18) 0 V |
| D3 (RAM pin 15) | F7 | | BLU2 (pin 22) 0 V |
| D2 (RAM pin 13) | FB | | RED3 (pin 21) 0 V |
| D1 and D0 (pins 12, 11) | FC | 1 bpp: thin white and black stripes | all 8 at 2.302 MHz, 54.9 %, 2.74 V |
| D1 (pin 12) | FD | 2 bpp | RED1-3, GRN2, GRN3 2.302 MHz 54.9 %; BLU2, BLU3, GRN1 28.77 kHz 73.1 % |
| D0 (pin 11) | FE | 4 bpp | RED1, GRN1-3 28.77 kHz 73.1 %; RED2, RED3 2.302 MHz 36.6 %, 1.83 V; BLU2, BLU3 0 V |

A pin that reads 0 V with no pull-down, or stays at 28.77 kHz with its own
bit pulled low, points at that pin's wiring or the colour decoder.  If the
whole screen is the wrong colour, check the line code register (U23) Q1:Q0
(pins 5 and 2) against the bus bits 1:0.

### Step 8: D register (U18) and the address muxes (U7-U10)

**Sockets:** U18 with C18 and U7-U10 with C7-C10.

**Program first:** U7, U8, U9 and U10 address muxes, four copies of
`ATF22V10_QUAD_MUX.pld` (rev 01); verify and label them.

The D register's load strobe /LOAD_IMM comes from the State PLD, so
put in:

- **S3**, in U1 (State): pin 19 to pin 12 (GND).  Holds /LOAD_IMM low, so
  the D register loads the bus every clock.  Out at step 11.

Fit U18 and U7-U10.  The D register loads the bus every clock (strap S3) and so holds FF.  The
muxes give the video address during video reads and D (FF) on A7:A0, 00 on
A15:A8 the rest of the time (strap S1).  Measure A15:A0 at the mux outputs
(or the RAM socket address pins):

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| A0, A1 | 1.106 MHz | 95.6 % | 4.78 V |
| A2, A3, A4 | 1.182 MHz | 95.3 % | 4.77 V |
| A5, A6 | 1.105 MHz | 95.6 % | 4.78 V |
| A7 | 30.69 kHz | 99.9 % | 4.99 V |
| A8 | 2.334 MHz | 9.3 % | 0.46 V |
| A9 | 1.213 MHz | 4.8 % | 0.24 V |
| A10 | 1.182 MHz | 4.7 % | 0.23 V |
| A11, A12 | 1.214 MHz | 4.8 % | 0.24 V |
| A13 | 1.381 MHz | 5.5 % | 0.27 V |
| A14 | 1.444 MHz | 5.7 % | 0.29 V |
| A15 | 1.841 MHz | 7.3 % | 0.37 V |

The screen stays white.

### Step 9: memory control (U11), map register (U25), I/O decode (U12)

**Sockets:** U11 with C11, U25 with C25 and U12 with C12.

**Other parts:** the 10k /WE pull-up (in the BOM, not on the schematic
yet), and for the cartridge lines R3 (10k, STALL_OUT pull-up), R4 (10k,
RUN pull-down) and the bring-up jumpers JP1 (STALL_IN to STALL_OUT) and
JP2 (RUN to +5 V), both with a shunt on (see "Without the cartridge").

**Program first:** U11 memory control from `ATF22V10_MEM_CTRL.pld`
(rev 09) and U12 I/O decode from `ATF22V10_IO_DECODE.pld` (rev 04); verify
and label them.

Memory control and I/O decode read the State PLD's R/W, so put in:

- **S2**, in U1 (State): pin 23 to pin 24 (+5 V).  Holds R/W high: no
  writes.  Out at step 11.

Fit U11, U25 and U12.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Mem ctrl /RAM_OE (pin 18) | 2.365 MHz | 95.3 % | 4.77 V |
| Mem ctrl /ROM_OE (pin 19) | 22.81 MHz (most meters can't count it) | 54.7 % | 2.73 V |
| Mem ctrl /WE (pin 16) | 0 | | 5 V |
| Mem ctrl RUN (pin 17, input from the cartridge or the jumper) | 0 | | 5 V |
| I/O decode /CE_HI (pin 15) | 1.841 MHz | 92.7 % | 4.63 V |
| I/O decode /MAP_WR, /LINE_RD, /PORT_WR, /PORT_RD, /EXP1, /EXP2 (pins 16, 17, 19-22) | 0 | | 5 V |
| Map register Q0-Q7 (pins 2, 5, 6, 9, 12, 15, 16, 19) | 0 | | 0 V (map 00, all ROM) |

### Step 10: RAM (U31, U32)

**Sockets:** U32 with C32 (U31's went in at step 7).

Take the 1k pull-down out of U31 and fit both RAM chips, U31 and U32.
The video now reads the RAM, which powers up random: the monitor shows
**random coloured noise**, in a mix of modes and line repeats (each line's mode byte is
random too).  Nothing writes the RAM yet (strap S2), so the picture holds
still.  Power off and on: a different picture.

## CPU

### The FF free run

With no ROM and no RAM, every byte the CPU reads is FF.  FF is a branch
always (BRA) with source 11, which is the accumulator (the same as
`bra ac`; it was X before 2026-10-19), and memory field 111, which goes
FETCH, LOAD_MEM, EXEC: three clocks.  With no AC source buffer (U27) the
source bus is FF too, so EXEC loads PC low with FF.  The next fetch is at xxFF,
and its increment carries into PC high.  So the CPU runs one instruction
every 3 clocks it owns, about 7.6 million a second, PC low goes FF, 00,
FF, ... and PC high counts up by one every instruction.  This exercises
the State, Branch and PC chips with no memory and no software.

### Step 11: take out the RAM and straps S1-S3; fit the instruction register PLD (U17) and the State PLD (U1)

**Sockets:** U17 with C17 (U1's went in at step 5).

**Program first:** U1 State from `ATF22V10_STATE.pld` (rev 15) and U17
instruction register from `ATF22V10_IR.pld` (rev 01); verify and label
them.

Pull both RAM chips U31 and U32 (the screen goes white again).  Take
straps S1 (the four 10k from pins 15-18 to pin 12), S2 (pin 23 to pin 24)
and S3 (pin 19 to pin 12) out of the State socket U1, then fit the State
PLD U1 and the instruction register U17.  The instruction register loads FF.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| State Q0 (pin 18) | 7.603 MHz | 33.3 % | 1.67 V |
| State PC_ENABLE (pin 15) | 7.603 MHz | 33.3 % | 1.67 V |
| State X_ENABLE, Y_ENABLE (pins 16, 17) | 0 | | 5 V |
| State /LOAD_INSTR (pin 14) | 7.603 MHz | 69.8 % | 3.49 V |
| State /LOAD_IMM (pin 19) | 7.603 MHz | 69.8 % | 3.49 V |
| State /LOAD_X, /LOAD_Y, /LOAD_AC (pins 20-22) | 0 | | 5 V |
| State R/W (pin 23) | 0 | | 5 V |
| Branch STALL (pin 19) | 2.365 MHz | 9.4 % | 0.47 V |
| Branch LOAD_PC_LOW (pin 21) | 7.603 MHz | 30.2 % | 1.51 V |
| Branch LOAD_PC_HIGH (pin 22) | 0 | | 0 V |
| Branch BRANCH_BLOCK (pin 23) | 0 | | 5 V |
| Branch /SRC_EN (pin 16) | 7.603 MHz | 69.8 % | 3.49 V |
| Branch ALU_DONE (pin 18) | 0 | | 0 V |
| Audio /AC_SEL (pin 21) | 0 | | 0 V (instruction bit 1 is 1) |
| Instruction register Q0-Q7 | 0 | | 5 V (FF) |

### Step 12: PC low (U3)

**Sockets:** U3 with C3.

**Program first:** U3 PC low from `ATF22V10_PC_COUNTER8.pld` (rev 02);
verify and label it.

Fit U3.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Q0-Q7 (pins 15, 22, 21, 16, 20, 17, 19, 18) | 7.603 MHz | 33.3 % | 1.67 V |
| CO (pin 23) | 7.603 MHz | 33.3 % | 1.67 V |

All eight bits move together (FF, 00, FF).

### Step 13: PC high (U4)

**Sockets:** U4 with C4.

**Program first:** U4 PC high from `ATF22V10_PC_COUNTER8.pld` (rev 02),
the same file as U3; verify and label it.

Fit U4.  PC high is a binary counter now: each bit is half the one below.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Q0 = A8 (pin 15) | 3.802 MHz | 50 % | 2.50 V |
| Q1 = A9 (pin 22) | 1.901 MHz | 50 % | 2.50 V |
| Q2 = A10 (pin 21) | 950.4 kHz | 50 % | 2.50 V |
| Q3 = A11 (pin 16) | 475.2 kHz | 50 % | 2.50 V |
| Q4 = A12 (pin 20) | 237.6 kHz | 50 % | 2.50 V |
| Q5 = A13 (pin 17) | 118.8 kHz | 50 % | 2.50 V |
| Q6 = A14 (pin 19) | 59.4 kHz | 50 % | 2.50 V |
| Q7 = A15 (pin 18) | 29.73 kHz | 50 % | 2.50 V |

### Step 14: accumulator (U19), ALU low (U5), ALU high (U6)

**Sockets:** U19 with C19, U5 with C5 and U6 with C6.

**Program first:** U5 ALU low and U6 ALU high, two copies of
`ALU_SHR.pld` (rev 07); verify and label them.

Fit U19, U5 and U6.  The accumulator powers up random and is never loaded in the free run.  The
ALU does PASS A for a branch, so each ALU F output must equal the
accumulator bit it comes from, at a steady 0 V or 5 V: low ALU F0-F3
(pins 17, 20, 16, 21) = AC Q0-Q3, high ALU F0-F3 = AC Q4-Q7 (F377 pins 2,
5, 6, 9, 12, 15, 16, 19).  Each ALU's Z (pin 14) is 5 V when its four
bits are all 0.  Power off and on a few times to see other values.  The PC
readings of steps 12 and 13 must not change.

### Step 15: X (U20) and Y (U21) registers

**Sockets:** U20 with C20 and U21 with C21.

Fit U20 and U21.  Also random and never loaded: their Q pins read steady 0 V or 5 V.  The
free run readings must not change.

### Step 16: D source buffer (U26)

**Sockets:** U26 with C26.

**Other parts:** R5-R12, the 47 ohm series resistors from the source
buffers onto the data bus.

Fit U26.  The free run never selects it (its /OE2 is instruction bit 1, which is 1),
so the readings of steps 11-13 must not change.  If they do, the buffer is
driving the bus when it shouldn't: check its /OE1 (Branch /SRC_EN, pin 16)
and /OE2 (instruction register PLD I1, pin 15) wiring.

### Step 17: AC source buffer (U27), line read buffer (U29), RAM back, the cartridge

**Sockets:** U27 with C27 and U29 with C29.

**Other parts:** the cartridge slot J8 and R13 (10k, /CART pull-up).

The free run does select the AC source buffer (source 11), and the
accumulator is random, so it goes in with the memories.  Fit the AC
source buffer U27, the line read buffer U29 and both RAM chips U31 and
U32.

Build the 64K cartridge: sockets and C1-C5 (100 nF) first, then program
and fit its chips one at a time:

1. **Loader PLD.**  Program cartridge U1 from `ATF22V10_CART.pld`
   (rev 04), verify, label and fit it.
2. **EEPROMs.**  Make the bring-up ROM image: `python3 test_bringup_sim.py
   --bin` in `src/scripts` writes `bringup_lo.bin` (ROM x0000-x7FFF) and
   `bringup_hi.bin` (x8000-xFFFF).  It is a complete image with its own
   reset code, so it replaces the normal ROM (boot loader and library)
   until the board works.  Program cartridge U2 (the lower AT28C256) with
   `bringup_lo.bin` and cartridge U3 (the upper one) with
   `bringup_hi.bin`, verify both, label them "lo" and "hi", and fit them.
   The cartridge copies them into its SRAMs at power-up
   ([ROM.md](ROM.md#loading-the-cartridge)).
3. **SRAMs.**  Fit cartridge U4 and U5 (no programming).

Take the shunts off JP1 and JP2 on the main board and plug
the cartridge into J8.  Power on: within about half a second the
screen shows the bring-up ROM's status screen ([below](#the-bring-up-rom)).
If it doesn't, read where the CPU stopped (next section).

## The bring-up ROM

At power-up it runs these tests from the ROM, using only the CPU, the ROM,
the RAM and the map register:

| N | Test | What it needs |
|--:|---|---|
| 1 | Branches on AC: BEQ, BNE, BLT, BLE | Branch PLD, ALU Z (pin 14) and F3 (sign) to the Branch PLD pins 7, 13, 8 |
| 2 | AND | ALU PLDs, AC, D register, D source buffer |
| 3 | OR | as 2 |
| 4 | XOR | as 2 |
| 5 | ADD | as 2, the carry between the ALU PLDs, the Branch PLD's ALU wait clock |
| 6 | SUB | as 5 |
| 7 | Carry flag: BCS, BCC | high ALU COUT (pin 18) to Branch pin 14, Branch CARRY (pin 20) |
| 8 | SHR | the ALU's shift-in wiring (SHIFT_RIGHT_IN, pin 23) |
| 9 | AC to X, immediate to X, read back through [Y,X] from the ROM table at x3F00 | X register, AC source buffer and /AC_SEL (audio PLD pin 21); X can't be a source, so this also needs the address path of tests 10-12 |
| 10 | Y as the address high byte | Y register, the high address muxes (U9, U10), Y_ENABLE |
| 11 | X as the address low byte | the low address muxes (U7, U8), X_ENABLE |
| 12 | ROM data (a 256-byte table) | the ROM chips' data and low address pins, /ROM_OE |
| 13 | RAM data: [0,D], [0,X], [Y,X] in both chips | RAM data pins, /WE, /RAM_OE, the source buffers on a store, the series resistors, map bits 0 and 4 |
| 14 | Map register, all 8 bits | ACT273 (U25), /MAP_WR, RUN, memory control RAMSEL pins |
| 15 | RAM address lines, both chips | RAM A14:A0, the lower chip's /CE (A15) and /CE_HI |
| 16 | Video line read (x5000) | line read buffer (U29), /LINE_RD |

The code that runs these tests uses only a few instructions before test 1
(a jump and the map write), so a CPU that can't run the tests usually
still reaches a fail loop.

**A failed test stops the CPU in a loop of its own at ROM x0080 + 4N.**
Read N off the PC with the meter:

- PC high (U4) Q0-Q7 all **0 V**
- PC low (U3) Q7 (pin 18) **5 V**; Q6:Q2 (pins 19, 17, 20, 16, 21) are N
  in binary, 5 V for a 1 (Q6 is the high bit); Q1 and Q0 toggle (the loop
  is a 3-clock branch, PC low goes F, F+1, F+2)

For example test 13 = 01101: Q6 0 V, Q5 5 V, Q4 5 V, Q3 0 V, Q2 5 V.

A PC that keeps moving with no status screen means the CPU is lost before
or between the tests.  The usual cause is the ALU or a register load:
every register (AC, X, Y, the PC's jump target) loads through the ALU, so
one stuck ALU output can break the very first jump.  An ALU output pin
stuck can also hide from the tests that compare with XOR (the compare goes
through the same pin) and show up first as 1, 5 or 6.  In either case go
back to the free run (pull the ROM and the RAM) and check steps 11-16
again, then the ALU outputs against the accumulator as in step 14.

When all pass, the ROM sets up the library, draws the status screen and
runs a loop once a frame:

| Row | Shows |
|---|---|
| 0 | title, FRAME (counts 60 a second) |
| 2-3 | the core tests (1-14) run again every frame; LOOPS counts them |
| 5 | RAM page test: one 256-byte page a frame with 6 patterns, over the 49 pages programs use (x0100-x1EFF, x4000-x4CFF, x5400-x59FF); PASSES, ERRORS, the last bad address, what was written and what was read |
| 8-9 | keyboard: the 8 bytes of `KBD_NOW` (FF = no key held; a held key clears its bit) and the typed keys (echoed) |
| 12 | SNES pads 1 and 2 (pad_read, 0000 = no button) |
| 14-15 | SD card: SD_INIT and FS_MOUNT results (S tries again) |
| 17-18 | mouse: MOUSE_INIT result, X (0-639), Y (0-479) and buttons |
| 20 | sound: T toggles a 1 kHz test tone |
| 22 | the video line read (V9:V2), changes every read |
| 44 | legend for the colour bands below it: rows 368-399 16 colours (4 bpp), 400-415 4 colours (2 bpp), 416-479 256 colours (8 bpp) |

A good board: FRAME and LOOPS count up together, PASSES goes up about
every 0.8 s and ERRORS stays 0.  If a core test fails later, the CPU stops
in its fail loop as above and the screen freezes.

The source is `src/scripts/gen_bringup.py`, which writes `bringup.asm`.
`python3 test_bringup_sim.py` runs it in the simulator on a good machine
(screen, counters, keys, tone, SD retry) and with faults: a RAM data bit
stuck (fail 13), a map register bit stuck (14), a RAM address line stuck
(15), a line read bit stuck (16), an ALU output stuck (1, 5, or lost before
the tests), and a RAM bit that goes bad after start-up (counted by the
page test).  It takes several minutes.

## I/O and audio

### Step 18: shared port: port PLD (U38) and PS/2 receiver PLD (U42)

**Sockets:** U38 with C38 and U42 with C42.

**Program first:** U38 shared port from `ATF22V10_PORT.pld` (rev 04) and
U42 PS/2 receiver from `ATF22V10_PS2.pld` (rev 02); verify and label
them.

Fit the two PLDs U38 and U42 and their parts ([IO.md](IO.md)):

- The 3.3 V regulator U40, with C40 on its input and C47 on its output
  (1 µF each).
- SNES pads: J2 and J3 with R40 and R41 (10k data pull-ups).
- PS/2: J5 with R49, R50 and R55 (4.7k pull-ups on the two clocks and
  DATA); the hold diodes D2 (/CS to the mouse CLK), D3 (DATA) and D6 (K0
  to the keyboard CLK); the receiver's inhibit diodes D5 (mouse CLK) and
  D19 (keyboard CLK) from U42 pin 14; and the RXCLK diode-OR D1
  (keyboard CLK), D4 (mouse CLK) with its 22k pull-down R60 (all BAT85).
- SD card: J4, the dividers R42-R44 (1.8k) and R45-R47 (3.3k) and R48
  (10k MISO pull-up to 3.3 V; MISO goes straight to U38 pin 13).
  Before plugging the SD card in, check 3.2-3.4 V at
U40's output and at the SD socket's pin 4.

- **Port PLD high level.**  The port register drives the pads' CLOCK and
  LATCH (CMOS, high at least 3.5 V) and the SD dividers; the ATF22V10C
  only promises 2.4 V at 4 mA.  With a pad and a card plugged in, measure
  U38 pins 20 (SCK) and 19 (MOSI) at rest: expect close to 5 V.  Under
  3.5 V the pads will misread; a 4.7k pull-up on each would fix it.
- **The port rests at EB** (the register clears at power-up): U38 pin 16
  (K0) 0 V, pin 17 (DATA hold) 5 V, pin 18 (/CS) 0 V, pins 19 and 20 5 V.
  Both PS/2 clock lines are held low at the socket (J5 pin 5 of each half)
  and RXCLK (U38 pin 11, U42 pin 1) is 0 V.  With no PS/2 device the
  keyboard CLK goes high only while the driver looks for a keyboard.
- With no key down row 8 shows FF in every byte; hold a key and its byte
  loses a bit.  Typed keys echo on row 9.
- Press buttons on a SNES pad: row 12 changes.  While the pads are read
  the mouse's clock is let go for about 30 us (after a 100 us hold): a
  scope on J5's mouse CLK pin shows the short high pulse once a frame.
- With no card SD_INIT is 01; with a card it should be 00, and FS_MOUNT 00
  on a FAT16 or FAT32 card.  Press S to try again after changing cards.
- Plug the mouse in and power on: MOUSE_INIT 00, and moving it changes X
  and Y (buttons in the last column).  The mouse is started once, at
  power-up.
- PS/2 keyboard socket (J5 bottom): plug a PS/2 keyboard in and power on:
  `port_init` finds it (its lights flash once as the driver sets them),
  typed keys echo, and Caps Lock lights its Caps Lock light.  Check
  typing with the mouse plugged in too, and that both keep working
  together (they share DATA, and take turns frame by frame).
- **RXCLK and the receiver** (scope, two channels: the device's CLK at
  J5 and RXCLK at U42 pin 1).  A byte is 11 clock pulses; RXCLK follows
  the free device's clock with a high of about 3.9 V (pull-up, diode,
  22k).  Check that each pulse is one clean edge at U42 (no double
  clocking: the PLD's clock input has no hysteresis, and the PS/2 edges
  are slow); the fix would be a smaller pull-down (10k) or 100 pF from
  RXCLK to ground.  After the 11th rising edge U42 pin 14 goes low and
  the device's CLK stays low until the CPU takes the byte (within a
  frame), then the line is let go and the next byte follows.  A device
  that sends the same byte twice in a row points at the inhibit coming
  too early (it should fall after the 11th pulse, not the 10th).
- **Holding mid-byte.**  Type while a SNES pad is being read (row 12
  changes every frame): nothing should be lost or doubled.  `ps2_pause`
  holds both clocks for at least 100 us before a pad read, so a device
  caught in the middle of a byte gives it up and sends its chunk again;
  a keyboard whose keys double up on the display points at a hold the
  keyboard does not see (it should be 100 us or more on the scope).

### Step 19: audio DAC (U36)

**Sockets:** U36 with C36.

Fit the DAC register U36, its supply
filter R22 (2.2 ohm) and C44 (220 µF), the R-2R ladder R23-R31 (2k) and
R32-R38 (1k), the output filter C45 (15 nF) and C46 (22 µF), R39 (10k)
and the jack J6 ([SOUND.md](SOUND.md)).
With no sound playing the sample is 80h:

| DAC pin | Silent | With T (1 kHz tone, 80h ± 48 = B0h / 50h) |
|---|---|---|
| Q7 (pin 12) | 5 V | about 1 kHz, 2.5 V |
| Q6, Q5 (pins 13, 14) | 0 V | about 1 kHz, 2.5 V |
| Q4 (pin 15) | 0 V | 5 V |
| Q3-Q0 (pins 16-19) | 0 V | 0 V |

The ladder output sits at about 2.5 V when silent.  Press T: a 1 kHz tone
from the line out (into an amplifier or powered speakers); T again stops it.

When everything passes, load the normal ROM image: take cartridge U2
and U3 out, program them with the two halves of the normal image
(`gen_rom.tcl`, [ROM.md](ROM.md)), verify, relabel and refit them.

## Expansion slots

The slots J9-J12 are optional: fit only the ones a card will use, each
with its select resistor (R51 for J9 through R54 for J12, 1k).  With a
card in, the boot ROM finds it ([EXPANSION.md](EXPANSION.md)).
