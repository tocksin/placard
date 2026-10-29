# Bring-up: build order and a test for each chip

Date: 2026-10-29

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
because a temporary resistor ("strap") plugs into
them; the step says so.  Each strap is described in the step that puts
it in and the step that takes it out.  The steps add chips one at a
time, and the CPU steps take the RAM out again for a while.

**Two kinds of 377.**  The board has six octal D flip-flops with enable
of two types that share a pinout: five 74F377 (U18-U22, marked
SN74F377AN) and one 74HCT377 (U23 only, marked CD74HCT377E).  The
silkscreen above each socket says which one goes there.  Read the marking
on the chip before you insert it.  A swap damages nothing, but an HCT377
in U18-U22 is too slow for the CPU and video, and an F377 in U23 makes
the row tint weak.

**Two kinds of diode.**  The Schottky diodes (D1-D6, D8-D11, D19) are
1N5817s in a black body; the six 1N4148s (D12-D17, row tint) are glass.
Don't swap them: a 1N4148 in a PS/2 place leaves the line too high to
read as low, and the row tint's clamp needs the Schottky's low drop.

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
4. With the power switch off, insert it into its socket, then turn the
   power switch on to measure.

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
places get a temporary resistor (a strap, from step 6 on).

**The data bus pull-ups.**  The 10k SIP on D7:D0 goes in at step 8.
With nothing driving it, the bus reads FF.  After a chip drives it and lets
go, the bus keeps that byte for about 0.5 µs (the 10k and the bus
capacitance), so "an empty bus reads FF" holds only when nothing has driven
it for a while.  That is why steps 13-18 run with the RAM taken out.

**Meter readings.**  The frequency is what the counter shows; the DC
average is what the volts range shows for a signal that toggles faster
than the meter can follow (the duty cycle times 5 V).  Many meters count
only up to about 10 MHz, so the fastest signals (the 25.175 MHz clock,
H0 at 12.59 MHz) may read wrong or zero; the slower bits next to them show
the same thing.  From step 13 on the CPU loses the clocks that video takes,
so its readings shift a little with the line and frame; read the average.

## Power

### Step 1: the power input, on/off switch and reset

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| J13 | USB-C receptacle (power only) | GCT USB4125-GF-A-0190 |  |
| R1, R2 | Resistor | 5.1k | CC1 and CC2 to GND; without them a USB-C supply gives no 5 V |
| F1 | Polyfuse, 3 A hold | Bourns MF-RG300-0 | not polarised |
| D7 | TVS diode, fused VBUS (VFUSE) to GND | Littelfuse SA5.0A | band (cathode) to VFUSE |
| SW1 | Toggle switch, on/off | CIT ANT11TFHQE |  |
| C41 | Electrolytic capacitor, on VON (between SW1 and K1) | 220 µF (Rubycon 25YXJ220M6.3X11) | + to VON, stripe to GND |
| K1 | Relay | CIT J1071CS6VDC.36 | COM (pin 1) = VON, NC (pin 4) = +5V |
| SW2 | Tactile reset button, VON to the coil (KCOIL) | C&K PTS645VL58-2 LFS |  |
| D8 | Schottky diode, across K1's coil | 1N5817 (black) | band (cathode) to KCOIL |
| R59 | Resistor, power LED | 1k |  |
| D18 | Power LED, red 5 mm, +5V (after K1) to GND | Kingbright WP7113ID | long lead (anode) to R59, flat side (cathode) to GND |

Fit only these power input parts on the bare board (power sheet, 2026-10-22).
Leave U40, C40 and C47 (the 3.3 V regulator) for step 20, with the SD card.

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

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| X1 | Oscillator, 25.175 MHz, full-size DIP-14 can | ECS ECS-100A-251.7 | no socket: solder it in, pin 1 (dot or square corner) on the footprint's pin 1 |
| C43 | Capacitor, beside X1 | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

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

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U15 | PLD, Sync | ATF22V10C-7PX, programmed from `ATF22V10_SYNC.pld` |  |
| U15 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C15 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

**Program first:** U15 Sync from `ATF22V10_SYNC.pld` (rev 10); verify
and label it.

Turn off the power switch.  Insert U15 into its socket.  Turn on the
power switch.  The Sync PLD's H2:H0 count the clock by themselves.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| H0 (pin 14) | 12.59 MHz | 50 % | 2.50 V |
| H1 (pin 15) | 6.294 MHz | 50 % | 2.50 V |
| H2 (pin 16) | 3.147 MHz | 50 % | 2.50 V |
| CLK_E (pin 9, input) | 25.175 MHz | 50 % | 2.50 V |
| /WE (pin 20) | 0 | | 5 V (output off while RUN is low, pull-up R63) |

CLK_E is the clock straight from X1, before the long track that takes it
to every other chip (CPU.md, "RAM write timing"); U15 makes the RAM's
/WE from it (rev 10), but lets go of the pin while RUN (pin 11) is low,
which R4 holds it at until step 12.

### Step 4: H counter PLD (U13)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U13 | PLD, H counter | ATF22V10C-7PX, programmed from `ATF22V10_HCOUNT.pld` |  |
| U13 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C13 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

**Program first:** U13 H counter from `ATF22V10_HCOUNT.pld` (rev 08);
verify and label it.

Turn off the power switch.  Insert U13 into its socket.  Turn on the
power switch.  H9:H3 count groups of 8 clocks, 28-127, 800 clocks a line.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| H3 (pin 14) | 1.573 MHz | 50.0 % | 2.50 V |
| H4 (pin 15) | 786.7 kHz | 50.0 % | 2.50 V |
| H5 (pin 16) | 377.6 kHz | 52.0 % | 2.60 V |
| H6 (pin 17) | 188.8 kHz | 52.0 % | 2.60 V |
| H7 (pin 18) | 94.41 kHz | 52.0 % | 2.60 V |
| H8 (pin 19) | 62.94 kHz | 64.0 % | 3.20 V |
| H9 (pin 20) | 31.47 kHz | 64.0 % | 3.20 V |

### Step 5: V counter PLD (U14)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U14 | PLD, V counter | ATF22V10C-7PX, programmed from `ATF22V10_VCOUNT.pld` |  |
| U14 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C14 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| J7 | VGA connector, DE-15 | Assmann A-HDF 15 A-KG/T |  |
| R61, R62 | Resistor, sync series (beside U13 and U15) | 47 ohm |  |

**Program first:** U14 V counter from `ATF22V10_VCOUNT.pld` (rev 03);
verify and label it.

Turn off the power switch.  Insert U14 into its socket, and connect a VGA
monitor.  Turn on the power switch.  V9:V0 count lines, 499-1023, 525
lines a frame.  The monitor should now lock to 640 x 480 at 60 Hz and show a **black screen** (the
color decoder isn't in yet).

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

### Step 6: color decoder (U16)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U16 | PLD, color decoder | ATF22V10C-7PX, programmed from `ATF22V10_COLORDECODER.pld` |  |
| U16 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C16 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| R14, R17 | Resistor, color | 3.3k |  |
| R15, R18 | Resistor, color | 1.6k |  |
| R16, R19 | Resistor, color | 820 ohm |  |
| R20 | Resistor, color | 1.43k |  |
| R21 | Resistor, color | 715 ohm |  |
| U23 socket | IC socket | DIP-20 0.3" (On Shore ED20DT) | empty for now, holds straps S1 and S2 |
| C23 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| S1 | Strap (temporary), in U23's socket | 10k | out at step 11 |
| S2 | Strap (temporary), in U23's socket | 10k | out at step 11 |
| (leads) | Test leads, 2: a clip on one end, a probe tip on the other | in the kit | one for ground, one for power |

**Program first:** U16 color decoder from `ATF22V10_COLORDECODER.pld`
(rev 07); verify and label it.

**Straps.**  A strap is a 10k resistor (or a wire link, where the step says so) with its leads in an empty
socket's pins (or soldered to a spare socket that plugs in), holding a
control line whose driver isn't in yet.  The H counter reads the line
code's Q7 as "blank line", so turn off the power switch and put in:

- **S1**, in U23 (line code): pin 19 (Q7) to pin 10 (GND).  Holds LC7
  low, so every line is a video line.  Out at step 11.
- **S2**, in U23 (line code): pin 20 (+5 V) to pin 12 (Q4, which goes
  only to the tint resistor R56, not fitted until step 11).  A 10k high
  source for the power test lead.  Out at step 11.

**Test leads.**  The color decoder's pixel inputs D0-D7 (pins 2-9) and
mode inputs MODE0, MODE1 (pins 10, 11) have no driver yet (the pixel
buffer U22 and the line code register U23 come later).  Each one holds
the last level it was touched to (the pin keeper), so you set them by
touching them through the straps' 10k, which keeps a slip onto a wrong
pin harmless.  With the power still off, clip on both test leads, so
nothing needs clipping while the board is powered:

- **Ground lead:** clip it to strap S1's lead at U23's pin 19 (10k to GND).
- **Power lead:** clip it to strap S2's lead at U23's pin 12 (10k to +5 V).

Insert U16 into its socket, and connect the monitor and USB power cable.
Turn on the power switch.  The screen shows a random color at first (the
inputs power up at no particular level).  These are the pins to touch:

| U16 pin | Input | What it sets |
|---|---|---|
| 2 | D0 | pixel bit 0 (8 bpp: RED1, pin 15) |
| 3 | D1 | pixel bit 1 (8 bpp: RED2, pin 16) |
| 4 | D2 | pixel bit 2 (8 bpp: RED3, pin 21) |
| 5 | D3 | pixel bit 3 (8 bpp: BLU2, pin 22) |
| 6 | D4 | pixel bit 4 (8 bpp: BLU3, pin 18) |
| 7 | D5 | pixel bit 5 (8 bpp: GRN1, pin 17) |
| 8 | D6 | pixel bit 6 (8 bpp: GRN2, pin 20) |
| 9 | D7 | pixel bit 7 (8 bpp: GRN3, pin 19) |
| 10 | MODE0 | color mode, with MODE1 |
| 11 | MODE1 | color mode: MODE1 MODE0 = 00 1 bpp, 01 2 bpp, 10 4 bpp, 11 8 bpp |

1. Touch the ground probe to each of these pins in turn: the screen
   turns **black** (1 bpp, every pixel 0), and every output (pins 15-22)
   reads 0 V.
2. Touch the power probe to each of them in turn: the screen turns
   **white** with a black border (8 bpp, every pixel FF), and every
   output reads 28.77 kHz, 73.1 %, 3.66 V.

You'll see each touch change the picture along the way.  Feel free to
touch any of these pins with either the power or ground probe in any
order to explore the different colors and color modes.  In 8 bpp
(MODE0 and MODE1 high) each pixel pin drives the one output named in the
table, which drops to 0 V when that pin is low.

A color output that stays at 0 V when it should toggle, or toggles when it
should be 0 V, points at that pin's wiring or the color resistors
(R14-R21).  Turn off the power switch and unclip both test leads; S1 and
S2 stay until step 11.

### Step 7: address muxes (U7-U10)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U7-U10 | PLD, address mux | ATF22V10C-7PX, programmed from `ATF22V10_QUAD_MUX.pld` |  |
| U7-U10 sockets | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C7-C10 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

**Program first:** U7, U8, U9 and U10 address muxes, four copies of
`ATF22V10_QUAD_MUX.pld` (rev 02); verify and label them.

The mux selects are PIXEL_ENABLE from the Sync PLD and PC_ENABLE,
X_ENABLE and Y_ENABLE from the State PLD (rev 02; the Sync PLD decoded
them before).  On a video read PIXEL_ENABLE picks the video address
whatever the missing State PLD's enables float at, so the muxes need no
straps.  The rest of the time they pass the CPU side's
address, which holds still while PC, D, X and Y are missing (each mux
input keeps whatever level it powered up at).  Turn off the power switch.
Insert U7-U10 into their sockets.  Turn on the power switch.

Measure A15:A0 at the mux outputs, pins 20-23 (LO0, LO1, HI0, HI1) of
each mux: U7 gives A0, A1, A8, A9; U8 A2, A3, A10, A11; U9 A4, A5, A12,
A13; and U10 A6, A7, A14, A15.  The exact readings depend on
the levels the CPU side came up at, so look only for a toggling signal:

| Address bits | Video read gives | Reading |
|---|---|---|
| A15:A9 | H9:H3 (the byte column) | toggling: a frequency, DC average between 0 and 5 V |
| A6:A2 | V6:V2 (the line) | toggling |
| A8, A7, A1, A0 | row bits from the audio PLD U35 (not in yet) | may sit at 0 V or 5 V until step 11 |

A bit in the first two rows that sits still at 0 V or 5 V points at that
mux's wiring or its H or V input.

### Step 8: RAM (U31), pixel buffer (U22)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U31 | SRAM, 32K x 8 (lower half) | Alliance AS7C256C-15PCN |  |
| U22 | Pixel buffer, octal D flip-flop | TI SN74F377AN |  |
| U31 socket | IC socket | DIP-28 0.3" (On Shore ED281DT) |  |
| U22 socket | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C31, C22 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| RN1 | Resistor network, 8 bussed, SIP-9 (data bus pull-ups) | 10k (Bourns 4609X-101-103LF) | dot (pin 1, common) to +5V |
| R63 | Resistor, /WE pull-up | 10k |  |
| U2 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) | empty for now, holds strap S3 |
| C2 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| U11 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) | empty for now, holds strap S4 |
| C11 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| S3 | Strap (temporary), in U2's socket | wire link | out at step 9 |
| S4 | Strap (temporary), in U11's socket | 10k | out at step 12 |

U31 and U22 need no programming.  U22 must be marked SN74F377AN (the
silkscreen above its socket says 74F377), not the CD74HCT377E that goes
in U23.

The video now reads the RAM.  Nothing writes it:
U15 lets go of /WE while RUN is low, so R63 holds it high.  The pixel
buffer's load strobe /PIX_LD and the RAM's /OE come from PLDs that aren't
in yet, so turn off the power switch and put in:

- **S3**, in U2 (Branch): a wire link from pin 15 (/PIX_LD) to pin 12
  (GND).  The pixel buffer loads the data bus every clock.  A wire, not
  a 10k: an F377 input needs more current to pull low than 10k passes.
  Out at step 9.
- **S4**, in U11 (memory control): 10k from pin 18 (/RAM_OE) to pin 12
  (GND).  The RAM drives the bus all the time.  Out at step 12.

Insert U31 and U22 into their sockets.  Turn on the power switch.

The monitor shows **one byte over and over**, with a thin stripe in every
8 pixels.  In 7 clocks of every 8 the muxes point at the CPU side's
address, which stays put while PC, D, X and Y are missing, and the pixel
buffer loads that one byte; in the eighth, the video read, the byte from
the video address shows through.  Only U31 is in, so only the left 16 byte
columns (A15 = 0) read the RAM; the other 64 read FF from RN1.

The color mode is wherever MODE1:MODE0 came up.  To try other modes, clip
the test leads on as in step 6 before you turn the power on and touch
only MODE0 and MODE1 (pins 10, 11); the pixel pins are driven by U22 now.

### Step 9: Branch PLD (U2)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U2 | PLD, Branch | ATF22V10C-7PX, programmed from `ATF22V10_BRANCH.pld` | socket fitted at step 8 |

**Program first:** U2 Branch from `ATF22V10_BRANCH.pld` (rev 15); verify
and label it.

The Branch PLD goes in now only for /PIX_LD (pin 15), which is just
PIXEL_ENABLE inverted; the rest of it waits for the CPU, and it needs no
straps.  Turn off the power switch.  Take strap S3 (U2 pin 15 to pin 12)
out, then insert U2 into its socket.  Turn on the power switch.

The pixel buffer now loads only on the video read, and the left 16 byte
columns show **random RAM** in the color mode on MODE1:MODE0.  Rows
repeat in bands (the audio slot PLD U35 isn't in, so four of the row
address bits are stuck).  The other 64 columns read FF (white in 1 bpp
and 8 bpp).

### Step 10: RAM (U32) and I/O decode (U12)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U32 | SRAM, 32K x 8 (upper half) | Alliance AS7C256C-15PCN |  |
| U12 | PLD, I/O decode | ATF22V10C-7PX, programmed from `ATF22V10_IO_DECODE.pld` |  |
| U32 socket | IC socket | DIP-28 0.3" (On Shore ED281DT) |  |
| U12 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C32, C12 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

**Program first:** U12 I/O decode from `ATF22V10_IO_DECODE.pld`
(rev 04); verify and label it.

U32's chip enable /CE_HI (U12 pin 15) is low when A15 is 1; on a video
read A15 is H9.  Turn off the power switch.  Insert U32 and U12 into their
sockets.  Turn on the power switch.  All 80 byte columns now show
**random RAM**.

### Step 11: audio and mode slot PLD (U35), line code (U23)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U35 | PLD, audio and mode slots | ATF22V10C-7PX, programmed from `ATF22V10_AUDIO.pld` |  |
| U23 | Line code register, octal D flip-flop | TI CD74HCT377E | socket fitted at step 6 |
| U35 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C35 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| R56-R58 | Resistor, row tint | 910 ohm |  |
| D9-D11 | Schottky diode, row tint | 1N5817 (black) | band (cathode) as on the silkscreen |
| D12-D17 | Diode, row tint | 1N4148 | band (cathode) as on the silkscreen |

**Program first:** U35 audio and mode slots from `ATF22V10_AUDIO.pld`
(rev 04); verify and label it.  U23 needs no programming; it is the
one CD74HCT377E (the silkscreen above its socket says 74HCT377).

Turn off the power switch.  Take straps S1 (U23 pin 19 to pin 10) and S2
(pin 20 to pin 12) out, then insert U35 and U23 into their sockets.  Turn
on the power switch.  BLANK_RD now picks group 45 (mode byte) and group
46 or 47 (audio sample) on every line, and the line code register loads
each line's mode byte.  The RAM is random, so the monitor shows **random
colored noise** in a mix of modes, line repeats and row tints, with about
half the lines black (bit 7 of a random mode byte blanks the line).
Nothing writes the RAM (R63 holds /WE high), so the picture holds still.  Power off and on: a
different picture.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| BLANK_RD (pin 23) | 62.16 kHz | 2.0 % | 0.10 V |
| /MODE_LD (pin 22) | 31.47 kHz | 99.0 % | 4.95 V |

### Step 12: memory control (U11) and map register (U25)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U11 | PLD, memory control | ATF22V10C-7PX, programmed from `ATF22V10_MEM_CTRL.pld` | socket fitted at step 8 |
| U25 | Map register, octal D flip-flop with clear | TI CD74ACT273E |  |
| U25 socket | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C25 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| R4 | Resistor, RUN pull-down | 10k |  |
| JP2 | Pin header, 1 x 2 (bring-up jumper) | Sullins PREC002SAAN-RC | RUN to +5 V |
| JP2 shunt | Jumper shunt | Sullins QPC02SXGN-RC | on only for the write check |

**Program first:** U11 memory control from `ATF22V10_MEM_CTRL.pld`
(rev 10); verify and label it.  U25 needs no programming.

With no cartridge and no JP2 shunt, R4 holds RUN low.  That keeps the
ROM off, holds the map register clear and keeps U15's /WE output off, so
R63 still stops any writes.  Turn off the power switch.  Take
strap S4 (U11 pin 18 to pin 12) out, then insert U11 and U25 into their
sockets and solder the JP2 header (leave its shunt off).  Turn on the
power switch.

**Reads.**  U11 now drives /RAM_OE low for the low half of each video
read and high the rest of the time (the map is clear, so no CPU read is
of RAM).  The picture is the same as in step 11.  If the RAM were never
enabled, the screen would go white or blank; if it were enabled all the
time, pin 18 would still read 0 V, as it did with S4.  /RAM_OE must read
the same frequency as PIXEL_ENABLE.  The readings below are for a screen
with no blank lines; random mode bytes may blank some lines, which lowers
both frequencies alike.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Sync PIXEL_ENABLE (pin 19) | 2.365 MHz | 9.4 % | 0.47 V |
| Mem ctrl /RAM_OE (pin 18) | 2.365 MHz | 95.3 % | 4.77 V |
| Mem ctrl RUN (pin 17, input) | 0 | | 0 V |
| Sync /WE (U15 pin 20) | 0 | | 5 V (output off, pull-up) |
| Mem ctrl /ROM_OE (pin 19) | 0 | | 5 V |
| Map register Q0-Q7 (pins 2, 5, 6, 9, 12, 15, 16, 19) | 0 | | 0 V (held clear by RUN) |

**Writes.**  Turn off the power switch, put the shunt on JP2 (RUN to
+5 V) and turn the power on.  One end of R4 is RUN and now reads 5 V;
the other end is GND.
Clip the ground test lead to that GND end of R4 and touch its tip to
U15 pin 10 (RW, a store; the State PLD that drives it isn't in yet; the
same net is U11 pin 14).  The pin keepers in U11 and U15 hold RW low
after you lift the tip.  U15 now drives /WE low for the low half of
every clock that isn't a video read:

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Sync /WE (U15 pin 20), RUN high, RW low | 22.81 MHz | 54.7 % | 2.73 V |

Each of these stores writes FF (the bus pull-ups) to the one CPU-side
address the muxes point at, so one byte of the picture may change; that
is harmless.  Turn off the power switch, unclip the lead and take the
shunt off JP2.  Turn the power on: /WE reads a steady 5 V again.

## CPU

### The FF free run

With no ROM and no RAM, every byte the CPU reads is FF.  FF is a branch
always (BRA) with source 11, which is the accumulator (the same as
`bra ac`; it was X before 2026-10-19), and memory field 111, which goes
FETCH, LOAD_MEM, EXEC: three clocks.  With no AC source buffer (U27) the
source bus is FF too, so EXEC loads PC low with FF.  The next fetch is at xxFF,
and its increment carries into PC high.  So the CPU runs one instruction
every 3 clocks it owns, about 8.4 million a second (the lines are blank,
so video takes only the mode and audio reads), PC low goes FF, 00,
FF, ... and PC high counts up by one every instruction.  This exercises
the State, Branch and PC chips with no memory and no software.

### Step 13: take out the RAM; fit the State PLD (U1), instruction register PLD (U17) and D register (U18)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U1 | PLD, State | ATF22V10C-7PX, programmed from `ATF22V10_STATE.pld` |  |
| U17 | PLD, instruction register | ATF22V10C-7PX, programmed from `ATF22V10_IR.pld` |  |
| U18 | D register, octal D flip-flop | TI SN74F377AN |  |
| U1, U17 sockets | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| U18 socket | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C1, C17, C18 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| R3 | Resistor, STALL_OUT pull-up | 10k |  |
| JP1 | Pin header, 1 x 2 (bring-up jumper) | Sullins PREC002SAAN-RC | STALL_IN to STALL_OUT (JP2, RUN to +5 V, is in from step 12) |
| JP1 shunt | Jumper shunt | Sullins QPC02SXGN-RC | on, with the JP2 shunt (see "Without the cartridge") |

**Program first:** U1 State from `ATF22V10_STATE.pld` (rev 15) and U17
instruction register from `ATF22V10_IR.pld` (rev 01); verify and label
them.  U18 needs no programming; check it is marked SN74F377AN.

Turn off the power switch.  Pull both RAM chips U31 and U32.  Put the
shunts on JP1 and JP2, then insert the State PLD U1, the instruction
register U17 and the D register U18 into their sockets.  Turn on the
power switch (the screen is black, with no RAM).  The instruction register
and the D register load FF.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| State Q0 (pin 18) | 8.371 MHz | 33.5 % | 1.67 V |
| State PC_ENABLE (pin 15) | 8.371 MHz | 33.3 % | 1.66 V |
| State X_ENABLE, Y_ENABLE (pins 16, 17) | 0 | | 5 V |
| State /LOAD_INSTR (pin 14) | 8.371 MHz | 66.8 % | 3.34 V |
| State /LOAD_IMM (pin 19) | 8.371 MHz | 66.8 % | 3.34 V |
| State /LOAD_X, /LOAD_Y, /LOAD_AC (pins 20-22) | 0 | | 5 V |
| State R/W (pin 23) | 0 | | 5 V |
| Branch STALL (pin 19) | 62.94 kHz | 0.2 % | 0.01 V |
| Branch LOAD_PC_LOW (pin 21) | 8.371 MHz | 33.2 % | 1.66 V |
| Branch LOAD_PC_HIGH (pin 22) | 0 | | 0 V |
| Branch BRANCH_BLOCK (pin 23) | 0 | | 5 V |
| Branch /SRC_EN (pin 16) | 8.371 MHz | 66.8 % | 3.34 V |
| Branch ALU_DONE (pin 18) | 0 | | 0 V |
| Audio /AC_SEL (pin 21) | 0 | | 0 V (instruction bit 1 is 1) |
| Instruction register Q0-Q7 | 0 | | 5 V (FF) |
| D register U18 Q0-Q7 (pins 2, 5, 6, 9, 12, 15, 16, 19) | 0 | | 5 V (FF) |

### Step 14: PC low (U3)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U3 | PLD, PC low | ATF22V10C-7PX, programmed from `ATF22V10_PC_COUNTER8.pld` |  |
| U3 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C3 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

**Program first:** U3 PC low from `ATF22V10_PC_COUNTER8.pld` (rev 02);
verify and label it.

Turn off the power switch.  Insert U3 into its socket.  Turn on the
power switch.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Q0-Q7 (pins 15, 22, 21, 16, 20, 17, 19, 18) | 8.371 MHz | 33.3 % | 1.66 V |
| CO (pin 23) | 8.371 MHz | 33.3 % | 1.66 V |

All eight bits move together (FF, 00, FF).

### Step 15: PC high (U4)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U4 | PLD, PC high | ATF22V10C-7PX, programmed from `ATF22V10_PC_COUNTER8.pld` |  |
| U4 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C4 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

**Program first:** U4 PC high from `ATF22V10_PC_COUNTER8.pld` (rev 02),
the same file as U3; verify and label it.

Turn off the power switch.  Insert U4 into its socket.  Turn on the
power switch.  PC high is a binary counter now: each bit is half the one below.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Q0 = A8 (pin 15) | 4.185 MHz | 50 % | 2.50 V |
| Q1 = A9 (pin 22) | 2.093 MHz | 50 % | 2.50 V |
| Q2 = A10 (pin 21) | 1.046 MHz | 50 % | 2.50 V |
| Q3 = A11 (pin 16) | 523.2 kHz | 50 % | 2.50 V |
| Q4 = A12 (pin 20) | 261.6 kHz | 50 % | 2.50 V |
| Q5 = A13 (pin 17) | 130.8 kHz | 50 % | 2.50 V |
| Q6 = A14 (pin 19) | 65.4 kHz | 50 % | 2.50 V |
| Q7 = A15 (pin 18) | 32.73 kHz | 50 % | 2.50 V |

### Step 16: accumulator (U19), ALU low (U5), ALU high (U6)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U5, U6 | PLD, ALU low, ALU high | ATF22V10C-7PX, programmed from `ALU_SHR.pld` |  |
| U19 | Accumulator, octal D flip-flop | TI SN74F377AN |  |
| U5, U6 sockets | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| U19 socket | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C5, C6, C19 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

**Program first:** U5 ALU low and U6 ALU high, two copies of
`ALU_SHR.pld` (rev 07); verify and label them.

Turn off the power switch.  Insert U19, U5 and U6 into their sockets.
Turn on the power switch.  The accumulator powers up random and is never loaded in the free run.  The
ALU does PASS A for a branch, so each ALU F output must equal the
accumulator bit it comes from, at a steady 0 V or 5 V: low ALU F0-F3
(pins 17, 20, 16, 21) = AC Q0-Q3, high ALU F0-F3 = AC Q4-Q7 (F377 pins 2,
5, 6, 9, 12, 15, 16, 19).  Each ALU's Z (pin 14) is 5 V when its four
bits are all 0.  Power off and on a few times to see other values.  The PC
readings of steps 14 and 15 must not change.

### Step 17: X (U20) and Y (U21) registers

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U20, U21 | X and Y registers, octal D flip-flop | TI SN74F377AN |  |
| U20, U21 sockets | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C20, C21 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

Turn off the power switch.  Insert U20 and U21 into their sockets.  Turn
on the power switch.  Also random and never loaded: their Q pins read steady 0 V or 5 V.  The
free run readings must not change.

### Step 18: D source buffer (U26)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U26 | D source buffer, octal 3-state buffer | TI SN74F541N |  |
| U26 socket | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C26 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| R5-R12 | Resistor, source buffers to the data bus | 47 ohm |  |

Turn off the power switch.  Insert U26 into its socket.  Turn on the
power switch.  The free run never selects it (its /OE2 is instruction bit 1, which is 1),
so the readings of steps 13-15 must not change.  If they do, the buffer is
driving the bus when it shouldn't: check its /OE1 (Branch /SRC_EN, pin 16)
and /OE2 (instruction register PLD I1, pin 15) wiring.

### Step 19: AC source buffer (U27), line read buffer (U29), RAM back, the cartridge

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U27, U29 | AC source buffer, line read buffer, octal 3-state buffer | TI SN74F541N |  |
| U27, U29 sockets | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C27, C29 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| U31, U32 | SRAM (out since step 13, back in now) | Alliance AS7C256C-15PCN |  |
| J8 | Cartridge slot, card edge, 64 contacts | Molex 87715-9106 |  |
| R13 | Resistor, /CART pull-up | 10k |  |
| cartridge PCB | 64K cartridge board |  |  |
| cartridge U1 | PLD, cartridge loader | ATF22V10C-7PX, programmed from `ATF22V10_CART.pld` |  |
| cartridge U2, U3 | EEPROM, 32K x 8 | Microchip AT28C256-15PU, programmed with `bringup_lo.bin`, `bringup_hi.bin` |  |
| cartridge U4, U5 | SRAM, 32K x 8 | Alliance AS7C256C-15PCN |  |
| cartridge U1 socket | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| cartridge U2, U3 sockets | IC socket | DIP-28 0.6" (On Shore ED28DT) |  |
| cartridge U4, U5 sockets | IC socket | DIP-28 0.3" (On Shore ED281DT) |  |
| cartridge C1-C5 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |

The free run does select the AC source buffer (source 11), and the
accumulator is random, so it goes in with the memories.  Turn off the power switch and insert the AC
source buffer U27, the line read buffer U29 and both RAM chips U31 and
U32 into their sockets.

Build the 64K cartridge: sockets and C1-C5 (100 nF) first, then program
and insert its chips into their sockets one at a time:

1. **Loader PLD.**  Program cartridge U1 from `ATF22V10_CART.pld`
   (rev 04), verify, label and insert it into its socket.
2. **EEPROMs.**  Make the bring-up ROM image: `python3 test_bringup_sim.py
   --bin` in `src/scripts` writes `bringup_lo.bin` (ROM x0000-x7FFF) and
   `bringup_hi.bin` (x8000-xFFFF).  It is a complete image with its own
   reset code, so it replaces the normal ROM (boot loader and library)
   until the board works.  Program cartridge U2 (the lower AT28C256) with
   `bringup_lo.bin` and cartridge U3 (the upper one) with
   `bringup_hi.bin`, verify both, label them "lo" and "hi", and insert them into their sockets.
   The cartridge copies them into its SRAMs at power-up
   ([ROM.md](ROM.md#loading-the-cartridge)).
3. **SRAMs.**  Insert cartridge U4 and U5 into their sockets (no programming).

Take the shunts off JP1 and JP2 on the main board and plug
the cartridge into J8.  Turn on the power switch: within about half a second the
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
back to the free run (pull the ROM and the RAM) and check steps 13-18
again, then the ALU outputs against the accumulator as in step 16.

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
| 44 | legend for the color bands below it: rows 368-399 16 colors (4 bpp), 400-415 4 colors (2 bpp), 416-479 256 colors (8 bpp) |

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

### Step 20: shared port: port PLD (U38) and PS/2 receiver PLD (U42)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U38 | PLD, shared port | ATF22V10C-7PX, programmed from `ATF22V10_PORT.pld` |  |
| U42 | PLD, PS/2 receiver | ATF22V10C-7PX, programmed from `ATF22V10_PS2.pld` |  |
| U38, U42 sockets | IC socket | DIP-24 0.3" (On Shore ED241DT) |  |
| C38, C42 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| U40 | 3.3 V regulator, TO-92 | Microchip MCP1700-3302E/TO | flat face as on the silkscreen |
| C40, C47 | Capacitor, regulator input and output | 1 µF ceramic (KEMET C330C105K5R5TA) |  |
| J2, J3 | SNES controller socket, 7 pin |  |  |
| R40, R41 | Resistor, SNES data pull-ups | 10k |  |
| J5 | PS/2 stacked dual mini-DIN-6 | Kycon KMDGX-6S/6S-S4N | mouse top, keyboard bottom |
| R49, R50, R55 | Resistor, PS/2 clock and DATA pull-ups | 4.7k |  |
| D1-D6, D19 | Schottky diode, PS/2 hold, inhibit and RXCLK | 1N5817 (black) | band (cathode) as on the silkscreen |
| R60 | Resistor, RXCLK pull-down | 22k |  |
| J4 | SD card socket | Hirose DM1AA-SF-PEJ(82) |  |
| R42-R44 | Resistor, SD dividers | 1.8k |  |
| R45-R47 | Resistor, SD dividers | 3.3k |  |
| R48 | Resistor, MISO pull-up to 3.3 V | 10k |  |

**Program first:** U38 shared port from `ATF22V10_PORT.pld` (rev 04) and
U42 PS/2 receiver from `ATF22V10_PS2.pld` (rev 02); verify and label
them.

Turn off the power switch.  Insert the two PLDs U38 and U42 into their
sockets and fit their parts ([IO.md](IO.md)):

- The 3.3 V regulator U40, with C40 on its input and C47 on its output
  (1 µF each).
- SNES pads: J2 and J3 with R40 and R41 (10k data pull-ups).
- PS/2: J5 with R49, R50 and R55 (4.7k pull-ups on the two clocks and
  DATA); the hold diodes D2 (/CS to the mouse CLK), D3 (DATA) and D6 (K0
  to the keyboard CLK); the receiver's inhibit diodes D5 (mouse CLK) and
  D19 (keyboard CLK) from U42 pin 14; and the RXCLK diode-OR D1
  (keyboard CLK), D4 (mouse CLK) with its 22k pull-down R60 (all 1N5817).
- SD card: J4, the dividers R42-R44 (1.8k) and R45-R47 (3.3k) and R48
  (10k MISO pull-up to 3.3 V; MISO goes straight to U38 pin 13).
  Turn on the power switch and, before plugging the SD card in, check 3.2-3.4 V at
U40's output and at the SD socket's pin 4.

- **Port PLD high level.**  The port register drives the pads' CLOCK and
  LATCH (CMOS, high at least 3.5 V) and the SD dividers; the ATF22V10C
  only promises 2.4 V at 4 mA.  With a pad and a card plugged in, measure
  U38 pins 20 (SCK) and 19 (MOSI) at rest: expect close to 5 V.  Under
  3.5 V the pads will misread; a 4.7k pull-up on each would fix it.
- **The port rests at EB** (the register clears at power-up): U38 pin 16
  (K0) 0 V, pin 17 (DATA hold) 5 V, pin 18 (/CS) 0 V, pins 19 and 20 5 V.
  Both PS/2 clock lines are held low at the socket (J5 pin 5 of each half)
  and RXCLK (U38 pin 11, U42 pin 1) is 0 V.  Once the bring-up ROM's
  driver runs with no mouse, it lets the keyboard CLK go (latch FB) so
  that a keyboard can be heard: the keyboard CLK and RXCLK are then high.
- With no key down row 8 shows FF in every byte; hold a key and its byte
  loses a bit.  Typed keys echo on row 9.
- Press buttons on a SNES pad: row 12 changes.  While the pads are read
  the mouse's clock is let go for about 30 us (after a 100 us hold): a
  scope on J5's mouse CLK pin shows the short high pulse once a frame.
- With no card SD_INIT is 01; with a card it should be 00, and FS_MOUNT 00
  on a FAT16 or FAT32 card.  Press S to try again after changing cards.
- With the power switch off, plug the mouse in, then turn the power switch on: MOUSE_INIT 00, and moving it changes X
  and Y (buttons in the last column).  The mouse is started once, at
  power-up.
- The keyboard and mouse are not hot-pluggable: always plug them in with
  the power switch off.  One plugged in while the machine runs is not
  recognized until the machine is reset (SW2).
- PS/2 keyboard socket (J5 bottom): with the power switch off, plug a PS/2 keyboard in, then turn the power switch on:
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

### Step 21: audio DAC (U36)

**Parts for this step:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| U36 | DAC register, octal D flip-flop, 3-state | TI SN74HCT574N |  |
| U36 socket | IC socket | DIP-20 0.3" (On Shore ED20DT) |  |
| C36 | Capacitor | 100 nF ceramic (TDK FG28X7R1H104KNT00) |  |
| R22 | Resistor, DAC supply filter | 2.2 ohm |  |
| C44 | Electrolytic capacitor, DAC supply filter | 220 µF (Rubycon 25YXJ220M6.3X11) | + to DAC_5V (R22's DAC end), stripe to GNDA |
| R23-R31 | Resistor, R-2R ladder | 2k |  |
| R32-R38 | Resistor, R-2R ladder | 1k |  |
| C45 | Capacitor, output filter | 15 nF C0G (TDK FG24C0G1H153JNT06) |  |
| C46 | Capacitor, output coupling | 22 µF ceramic (TDK FG22X7R1E226MRT06) |  |
| R39 | Resistor, output | 10k |  |
| J6 | Audio line out jack, 3.5 mm TRRS | Tensility 54-00174 |  |

Turn off the power switch.  Insert the DAC register U36 into its socket
and fit its supply
filter R22 (2.2 ohm) and C44 (220 µF), the R-2R ladder R23-R31 (2k) and
R32-R38 (1k), the output filter C45 (15 nF) and C46 (22 µF), R39 (10k)
and the jack J6 ([SOUND.md](SOUND.md)).  Turn on the power switch.
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
(`gen_rom.tcl`, [ROM.md](ROM.md)), verify, relabel and insert them into their sockets again.

## Expansion slots

**Parts:**

| Ref | Part | Value or part number | Note |
|---|---|---|---|
| J9-J12 | Expansion slot, 2 x 20 card edge (optional) | Sullins EBC20DCAN | fit only the ones a card will use |
| R51-R54 | Resistor, slot select (R51 for J9 ... R54 for J12) | 1k | one per fitted slot |

The slots J9-J12 are optional: fit only the ones a card will use, each
with its select resistor (R51 for J9 through R54 for J12, 1k).  With a
card in, the boot ROM finds it ([EXPANSION.md](EXPANSION.md)).
