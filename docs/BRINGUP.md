# Bring-up: build order and a test for each chip

Date: 2026-10-21

This is the order to put the chips in, with a quick test after each one.
Every test needs only a multimeter with DC volts and a frequency counter
(and a VGA monitor from step 4 on).  The video section goes in first
because it runs with no software.  The CPU comes next: it runs a known
pattern with no memory at all (the "FF free run"), and then the bring-up
test ROM checks the rest of the CPU and the memory by itself.  The I/O and
the audio go in last, and the ROM shows their state on the screen.

Chip numbers (#n) are the ones in [CHIPS.md](CHIPS.md).  The expected
readings come from `src/scripts/bringup_signals.py`, a clock-by-clock model
of the PLD equations as they are wired at each step.  The test ROM is made
by `src/scripts/gen_bringup.py` and checked by
`src/scripts/test_bringup_sim.py` (see [The bring-up ROM](#the-bring-up-rom)).

## Before you start

**Sockets.**  Put every chip in a socket.  The steps add chips one at a
time, the CPU steps take the RAM out again for a while, and a few steps
put temporary resistors into empty sockets.

**Program the PLDs** from the JED files that WinCUPL makes from
`src/pld`, with a programmer that handles the ATF22V10C.  Label each one
with its chip number.

| Chip | Source | Chip | Source |
|---|---|---|---|
| #1 State | `ATF22V10_STATE.pld` (rev 15) | #11 Memory control | `ATF22V10_MEM_CTRL.pld` |
| #2 Branch | `ATF22V10_BRANCH.pld` (rev 15) | #12 I/O decode | `ATF22V10_IO_DECODE.pld` (rev 04) |
| #3, #4 PC low, PC high | `ATF22V10_PC_COUNTER8.pld` (two copies) | #13 H counter | `ATF22V10_HCOUNT.pld` |
| #5, #6 ALU low, ALU high | `ALU_SHR.pld` (two copies) | #14 V counter | `ATF22V10_VCOUNT.pld` |
| #7-#10 Address muxes | `ATF22V10_QUAD_MUX.pld` (four copies) | #15 Sync | `ATF22V10_SYNC.pld` |
| #16 Colour decoder | `ATF22V10_COLORDECODER.pld` | #35 Audio and mode slots | `ATF22V10_AUDIO.pld` (rev 04) |
| #38 Shared port | `ATF22V10_PORT.pld` | | |

**Load the bring-up ROM.**  `python3 test_bringup_sim.py --bin` in
`src/scripts` writes `bringup_lo.bin` (ROM x0000-x7FFF, for #33) and
`bringup_hi.bin` (x8000-xFFFF, for #34; since 2026-10-20 these are
the cartridge's two AT28C256 EEPROMs, lower and upper).
It is a complete image with its own reset code, so it replaces the normal
ROM (boot loader and library) until the board works; then load the normal
image (`gen_rom.tcl`, [ROM.md](ROM.md)).  Program the EEPROMs in an
external programmer; the cartridge copies them into its SRAMs at
power-up ([ROM.md](ROM.md#loading-the-cartridge)).

**Without the cartridge.**  The main board's STALL_OUT pull-up keeps the
CPU stalled until a cartridge lets it go, and RUN's pull-down keeps the
ROM off and the instruction register PLD at 02h.  For the steps before
the cartridge is built, fit two jumpers: STALL_IN to STALL_OUT (JP201:
the Branch PLD's STALL reaches the State and PC PLDs directly) and RUN to
+5 V (JP202: the board reads the ROM and the IR loads opcodes).  Then
nothing loads the ROM SRAMs, so those steps only check what they can
without a ROM image (or with SRAMs loaded some other way).  Remove both
jumpers when the cartridge goes in.  The clock runs from power-up either
way.

**Reset.**  There is no reset button.  At power-up the ATF22V10C registers
start at 0, so the CPU starts in FETCH at x0000.  The cartridge stalls
the CPU while it loads its SRAMs (about 33 ms; the video runs and shows
the random RAM), and RUN holds the map register clear (all ROM) until it
hands off at x0000, which holds a nop.  To
restart, switch the power off and on.

**Floating inputs.**  An ATF22V10C holds an input that nothing drives at
its last level (a weak pin keeper), and an F-series input that floats reads
high.  So a missing chip is harmless unless a level matters, and those
places get a temporary resistor (below).

**The data bus pull-ups.**  The 10k SIP on D7:D0 goes in with the passives.
With nothing driving it, the bus reads FF.  After a chip drives it and lets
go, the bus keeps that byte for about 0.5 µs (the 10k and the bus
capacitance), so "an empty bus reads FF" holds only when nothing has driven
it for a while.  That is why steps 10-15 run with the RAM taken out.

**Meter readings.**  The frequency is what the counter shows; the DC
average is what the volts range shows for a signal that toggles faster
than the meter can follow (the duty cycle times 5 V).  Many meters count
only up to about 10 MHz, so the fastest signals (the 25.175 MHz clock,
H0 at 12.59 MHz) may read wrong or zero; the slower bits next to them show
the same thing.  From step 10 on the CPU loses the clocks that video takes,
so its readings shift a little with the line and frame; read the average.

## Temporary resistors

10k resistors pushed into the empty sockets (or soldered to a spare
socket) hold the control lines whose drivers aren't in yet.  Take each one
out when its step says so.

| Strap | Where (socket pins) | Holds | From | Take out at |
|---|---|---|---|---|
| S1 | State #1: pins 15, 16, 17, 18 to pin 12 (GND), one 10k each | PC_ENABLE, X_ENABLE, Y_ENABLE and Q0 low: the address muxes pick D (low byte) and 00 (high byte) outside video reads, /SRC_EN stays off | step 1 | step 10 |
| S2 | State #1: pin 23 to pin 24 (+5 V) | R/W high: no writes | step 1 | step 10 |
| S3 | State #1: pin 19 to pin 12 (GND) | /LOAD_IMM low: the D register loads the bus every clock | step 1 | step 10 |
| S4 | Audio #35: pin 23 to pin 12 (GND) | BLANK_RD low: no mode or audio reads | step 1 | step 5 |
| S5 | Line code #23: pins 6 and 9 (Q2, Q3) to pin 10 (GND) | line repeat 1x for the audio PLD | step 1 | step 6 |

Step 6 also uses **1k pull-downs** on single data bus bits, from a data pin
of the empty RAM socket #31 to its pin 14 (GND), to set a constant byte for
the colour decoder: D0 = pin 11, D1 = 12, D2 = 13, D3 = 15, D4 = 16,
D5 = 17, D6 = 18, D7 = 19.  1k against the 10k pull-up gives about 0.45 V,
a solid low.

## Video

### Step 1: power, passives and the oscillator

Build the board with no chips: sockets, the bus pull-up SIP, the series
resistors, the VGA resistor network and connector, the power jack and
decoupling.  Put in straps S1-S5.

- With no chips and power on, check +5 V on every socket's power pin and
  0 V on its ground pin: 24-pin PLDs 24 and 12; 20-pin chips (F377, F541,
  ACT273, HC574, HCT574) 20 and 10; the 28-pin RAM and
  ROM 28 and 14.  Current with no chips: a few mA (the pull-ups).
- Fit the 25.175 MHz oscillator.  Its output reads **25.175 MHz**, 2.5 V
  average.  If the meter doesn't reach that, skip it: step 2 shows the
  clock divided down.

### Step 2: Sync PLD (#15)

The Sync PLD's H2:H0 count the clock by itself.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| H0 (pin 14) | 12.59 MHz | 50 % | 2.50 V |
| H1 (pin 15) | 6.294 MHz | 50 % | 2.50 V |
| H2 (pin 16) | 3.147 MHz | 50 % | 2.50 V |

The other Sync pins depend on the counters and are checked in step 4.

### Step 3: H counter PLD (#13)

H9:H3 count groups of 8 clocks, 28-127, 800 clocks a line.

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

### Step 4: V counter PLD (#14)

V9:V0 count lines, 499-1023, 525 lines a frame.  Connect a VGA monitor:
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
| Sync VSYNC (pin 18) | 59.94 Hz | 99.6 % | 4.98 V |
| Sync PIXEL_ENABLE (pin 19) | 2.302 MHz | 9.1 % | 0.46 V |
| Sync ADDR_SEL (pin 20) | 2.302 MHz | 9.1 % | 0.46 V |
| Sync V_VIDEO_ACTIVE (pin 23) | 59.94 Hz | 91.4 % | 4.57 V |

**59.94 Hz** on VSYNC is the frame rate.  PIXEL_ENABLE here has only the
video reads; step 5 adds the mode and audio reads.

### Step 5: audio and mode slot PLD (#35)

Take out strap S4.  BLANK_RD now picks group 45 (mode byte) and group 46
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

### Step 6: Branch PLD (#2), pixel buffer (#22), line code (#23), colour decoder (#16)

The Branch PLD goes in now only for /PIX_LD (pin 15), the pixel buffer's
load strobe; the rest of it waits for the CPU.  Take out strap S5 when the
line code register goes in.

Nothing drives the data bus, so every video read is FF: the line code is
mode 3 (8 bpp, 4x repeat) and every pixel is FF.  The monitor shows a
**white screen** with a black border.

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Branch /PIX_LD (pin 15) | 2.365 MHz | 90.6 % | 4.53 V |
| Colour decoder outputs (pins 15-22), bus FF | 28.77 kHz | 73.1 % | 3.66 V |

Then test each output with one 1k pull-down at a time (see "Temporary
resistors").  Bits 1:0 of the byte are also the mode, so pulling D1 or D0
changes the mode:

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
whole screen is the wrong colour, check the line code register (#23) Q1:Q0
(pins 5 and 2) against the bus bits 1:0.

### Step 7: D register (#18) and the address muxes (#7-#10)

The D register loads the bus every clock (strap S3) and so holds FF.  The
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

### Step 8: memory control (#11), map register (#25), I/O decode (#12)

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Mem ctrl /RAM_OE (pin 18) | 2.365 MHz | 95.3 % | 4.77 V |
| Mem ctrl /ROM_OE (pin 19) | 22.81 MHz (most meters can't count it) | 54.7 % | 2.73 V |
| Mem ctrl /WE (pin 16) | 0 | | 5 V |
| Mem ctrl RUN (pin 17, input from the cartridge or the jumper) | 0 | | 5 V |
| I/O decode /CE_HI (pin 15) | 1.841 MHz | 92.7 % | 4.63 V |
| I/O decode /MAP_WR, /LINE_RD, /PORT_WR, /PORT_RD, /EXP1, /EXP2 (pins 16, 17, 19-22) | 0 | | 5 V |
| Map register Q0-Q7 (pins 2, 5, 6, 9, 12, 15, 16, 19) | 0 | | 0 V (map 00, all ROM) |

### Step 9: RAM (#31, #32)

Take the 1k pull-down out of #31 and fit both RAM chips.  The video now
reads the RAM, which powers up random: the monitor shows **random coloured
noise**, in a mix of modes and line repeats (each line's mode byte is
random too).  Nothing writes the RAM yet (strap S2), so the picture holds
still.  Power off and on: a different picture.

## CPU

### The FF free run

With no ROM and no RAM, every byte the CPU reads is FF.  FF is a branch
always (BRA) with source 11, which is the accumulator (the same as
`bra ac`; it was X before 2026-10-19), and memory field 111, which goes
FETCH, LOAD_MEM, EXEC: three clocks.  With no AC source buffer (#27) the
source bus is FF too, so EXEC loads PC low with FF.  The next fetch is at xxFF,
and its increment carries into PC high.  So the CPU runs one instruction
every 3 clocks it owns, about 7.6 million a second, PC low goes FF, 00,
FF, ... and PC high counts up by one every instruction.  This exercises
the State, Branch and PC chips with no memory and no software.

### Step 10: take out the RAM and straps S1-S3; fit the instruction register PLD (#17) and the State PLD (#1)

Pull both RAM chips (the screen goes white again).  Take straps S1, S2
and S3 out of the State socket, then fit the State PLD and the instruction
register.  The instruction register loads FF.

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

### Step 11: PC low (#3)

| Pin | Frequency | Duty | DC average |
|---|---|---|---|
| Q0-Q7 (pins 15, 22, 21, 16, 20, 17, 19, 18) | 7.603 MHz | 33.3 % | 1.67 V |
| CO (pin 23) | 7.603 MHz | 33.3 % | 1.67 V |

All eight bits move together (FF, 00, FF).

### Step 12: PC high (#4)

PC high is a binary counter now: each bit is half the one below.

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

### Step 13: accumulator (#19), ALU low (#5), ALU high (#6)

The accumulator powers up random and is never loaded in the free run.  The
ALU does PASS A for a branch, so each ALU F output must equal the
accumulator bit it comes from, at a steady 0 V or 5 V: low ALU F0-F3
(pins 17, 20, 16, 21) = AC Q0-Q3, high ALU F0-F3 = AC Q4-Q7 (F377 pins 2,
5, 6, 9, 12, 15, 16, 19).  Each ALU's Z (pin 14) is 5 V when its four
bits are all 0.  Power off and on a few times to see other values.  The PC
readings of steps 11 and 12 must not change.

### Step 14: X (#20) and Y (#21) registers

Also random and never loaded: their Q pins read steady 0 V or 5 V.  The
free run readings must not change.

### Step 15: D source buffer (#26)

The free run never selects it (its /OE2 is instruction bit 1, which is 1),
so the readings of steps 10-12 must not change.  If they do, the buffer is
driving the bus when it shouldn't: check its /OE1 (Branch /SRC_EN, pin 16)
and /OE2 (instruction register PLD I1, pin 15) wiring.

### Step 16: AC source buffer (#27), line read buffer (#29), RAM back, the ROM

The free run does select the AC source buffer (source 11), and the
accumulator is random, so it goes in with the memories.  Fit the AC
source buffer, the line read buffer, both RAM chips and both ROM
chips with the bring-up ROM.  Power on: within about half a second the
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
| 10 | Y as the address high byte | Y register, the high address muxes (#9, #10), Y_ENABLE |
| 11 | X as the address low byte | the low address muxes (#7, #8), X_ENABLE |
| 12 | ROM data (a 256-byte table) | the ROM chips' data and low address pins, /ROM_OE |
| 13 | RAM data: [0,D], [0,X], [Y,X] in both chips | RAM data pins, /WE, /RAM_OE, the source buffers on a store, the series resistors, map bits 0 and 4 |
| 14 | Map register, all 8 bits | ACT273 (#25), /MAP_WR, RUN, memory control RAMSEL pins |
| 15 | RAM address lines, both chips | RAM A14:A0, the lower chip's /CE (A15) and /CE_HI |
| 16 | Video line read (x5000) | line read buffer (#29), /LINE_RD |

The code that runs these tests uses only a few instructions before test 1
(a jump and the map write), so a CPU that can't run the tests usually
still reaches a fail loop.

**A failed test stops the CPU in a loop of its own at ROM x0080 + 4N.**
Read N off the PC with the meter:

- PC high (#4) Q0-Q7 all **0 V**
- PC low (#3) Q7 (pin 18) **5 V**; Q6:Q2 (pins 19, 17, 20, 16, 21) are N
  in binary, 5 V for a 1 (Q6 is the high bit); Q1 and Q0 toggle (the loop
  is a 3-clock branch, PC low goes F, F+1, F+2)

For example test 13 = 01101: Q6 0 V, Q5 5 V, Q4 5 V, Q3 0 V, Q2 5 V.

A PC that keeps moving with no status screen means the CPU is lost before
or between the tests.  The usual cause is the ALU or a register load:
every register (AC, X, Y, the PC's jump target) loads through the ALU, so
one stuck ALU output can break the very first jump.  An ALU output pin
stuck can also hide from the tests that compare with XOR (the compare goes
through the same pin) and show up first as 1, 5 or 6.  In either case go
back to the free run (pull the ROM and the RAM) and check steps 10-15
again, then the ALU outputs against the accumulator as in step 13.

When all pass, the ROM sets up the library, draws the status screen and
runs a loop once a frame:

| Row | Shows |
|---|---|
| 0 | title, FRAME (counts 60 a second) |
| 2-3 | the core tests (1-14) run again every frame; LOOPS counts them |
| 5 | RAM page test: one 256-byte page a frame with 6 patterns, over the 49 pages programs use (x0100-x1EFF, x4000-x4CFF, x5400-x59FF); PASSES, ERRORS, the last bad address, what was written and what was read |
| 8-9 | keyboard: the 8 columns' row bytes (FF = no key) and the typed keys (echoed) |
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

### Step 17: shared port: latch (#37), port PLD (#38), row buffer (#39)

Fit the three chips, the 3.3 V regulator, the SD dividers and the
connectors ([IO.md](IO.md)).  Before plugging the SD card in, check
3.3 V at the SD socket's pin 4.

- The keyboard is scanned every frame: each /COL pin (port PLD pins 14-21)
  reads about **59.94 Hz**, mostly high.  With no key down row 8 shows FF
  in every column; hold a key and its column's byte loses a bit.  Typed
  keys echo on row 9.
- Press buttons on a SNES pad: row 12 changes.
- With no card SD_INIT is 01; with a card it should be 00, and FS_MOUNT 00
  on a FAT16 or FAT32 card.  Press S to try again after changing cards.
- Plug the mouse in and power on: MOUSE_INIT 00, and moving it changes X
  and Y (buttons in the last column).  The mouse is started once, at
  power-up.

### Step 18: audio DAC (#36)

Fit the DAC register, the R-2R ladder and the jack ([SOUND.md](SOUND.md)).
With no sound playing the sample is 80h:

| DAC pin | Silent | With T (1 kHz tone, 80h ± 48 = B0h / 50h) |
|---|---|---|
| Q7 (pin 12) | 5 V | about 1 kHz, 2.5 V |
| Q6, Q5 (pins 13, 14) | 0 V | about 1 kHz, 2.5 V |
| Q4 (pin 15) | 0 V | 5 V |
| Q3-Q0 (pins 16-19) | 0 V | 0 V |

The ladder output sits at about 2.5 V when silent.  Press T: a 1 kHz tone
in the headphones; T again stops it.

When everything passes, load the normal ROM image.
