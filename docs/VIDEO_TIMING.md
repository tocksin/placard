# Video read timing options

Date: 2026-10-15

The video read of the first byte of each line is the worst path left in
[TIMING.md](TIMING.md) after the ALU fix: 52.5 ns against a 39.72 ns clock
(25.175 MHz).  This document works out how to fix it with the ATF22V10C
PLDs already on the board, and what each fix changes in the rest of the
system.  Timing figures are the same worst-case datasheet values as
TIMING.md (ATF22V10C-7, 74F glue).

**Status:** option A is implemented (Sync PLD revision 05, two-stage pixel
delay in `basys_top.vhd`, 2026-10-15).

## Recommendation

**Option A: register PIXEL_ENABLE in the Sync PLD, so the byte is read in
the second clock of each 8-clock group instead of the first, and add one
more stage to the pixel delay register.**  It adds no chips, makes every
video read 34.5 ns (+5.2 ns), and removes the write glitch that the ALU
change spread to every video byte.  The picture moves one pixel to the
right relative to HSYNC, and the CPU loses no speed.

| Option | Chips added | Video read, first byte | Video read, other bytes | Write glitch | PIXEL_ENABLE to a load enable |
|---|---:|---:|---:|---|---:|
| Now (after the ALU change) | 0 | 52.5 ns (**−12.8**) | 42.0 ns (**−2.3**) | every video byte | 40.0 ns (**−0.3**) |
| **A. Registered PIXEL_ENABLE, read in clock 1 of the group** | **0** | **34.5 ns (+5.2)** | **34.5 ns (+5.2)** | **gone (+1.6)** | **25.0 ns (+14.7)** |
| B. Flatten the Sync PLD equations, keep them combinational | 0 | 37.5 ns (+2.2) | 34.5 ns (+5.2) | every video byte | 32.5 ns (+7.2) |
| C. Registered PIXEL_ENABLE, still read in clock 0 | +1 PLD | 34.5 ns (+5.2) | 34.5 ns (+5.2) | gone (+1.6) | 25.0 ns (+14.7) |

All three still have the upper-32K chip-select inverter in front of the
RAM (TIMING.md rank 5), which is a separate fix (TIMING.md "What it would
take", item 4).  With that inverter, option A's video read is 40.5 ns
(−0.8), the same problem the CPU fetch has.

## Why the first byte is slow now

    H counter PLD   H_VIDEO_ACTIVE tCO                 5.5
    Sync PLD        VIDEO_ACTIVE (pin 17)              7.5
    Sync PLD        PIXEL_ENABLE (pin 19, from pin 17) 7.5
    Sync PLD        ADDR_SEL (pin 20, from pin 19)     7.5
    address mux     select to output                   7.5
    RAM             tAA                               15.0
    pixel buffer    F377 setup                         2.0
    total                                             52.5

VIDEO_ACTIVE and PIXEL_ENABLE are combinational output pins, and each
equation that names one goes back through the array (pin feedback), so the
mux select is four PLD levels from the clock.  Every other byte of the line
starts from the Sync PLD's own H2:H0 registers (tCF 2.5 instead of 5.5) and
skips VIDEO_ACTIVE, which gives 42.0 ns.

## The write glitch, and why the ALU change made it worse

The State PLD's MEM_WR includes !STALL, and STALL is now one level behind
PIXEL_ENABLE (Branch PLD, see [ALU_TIMING.md](ALU_TIMING.md)).  When a
video read lands on an EXEC store, MEM_WR has to go inactive before /WE can
go low at T/2 + 2.2 = 22.1 ns.  If it does not, /WE pulses low while the
address mux is switching to the video address, and the store's byte can be
written over the video byte that is about to be read.  The store itself is
redone after the stall, so the CPU sees nothing wrong; the screen does.

| MEM_WR goes inactive at | First byte | Other bytes |
|---|---:|---:|
| Before the ALU change: PIXEL_ENABLE + State | 28.0 ns | 17.5 ns (OK) |
| **Now: PIXEL_ENABLE + STALL + State** | **35.5 ns** | **25.0 ns** |
| Option A: PIXEL_ENABLE tCO 5.5 + STALL + State | 20.5 ns (OK) | 20.5 ns (OK) |
| Option B: flattened PIXEL_ENABLE + STALL + State | 28.0 ns | 25.0 ns |

So with the sources as they are, any store that coincides with a video read
can corrupt one video byte, on any byte of the line.  Option A leaves 1.6 ns
at a 50 % clock duty.  An oscillator whose high phase is only 45 % brings
/WE low at 20.1 ns, 0.4 ns before MEM_WR is safe, so option A wants a
clock that is at least 47 % high (or a divided-down clock, which is 50 %).

## Option A: registered PIXEL_ENABLE, read in clock 1

PIXEL_ENABLE becomes a registered output on the same pin, decoded from the
inputs rather than from the VIDEO_ACTIVE pin:

    PIXEL_ENABLE.D = V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & !H2 & !H1 & !H0;

It is high for the clock after H2:H0 = 000, that is H2:H0 = 001.  The
three ADDR_SEL equations do not change.  They still name PIXEL_ENABLE, but a
registered output feeds the array from its register (tCF = 2.5 ns), not
through the pin, so the mux select is valid at tCF + tPD = 10 ns on every
byte, including the first.

Decoding PIXEL_ENABLE one clock early instead (option C), so the read stays
in clock 0, needs the next clock's H_VIDEO_ACTIVE.  That is VIDEO_ON
(H = 47), which only the H counter PLD decodes, and neither the H counter
PLD nor the Sync PLD has a spare output pin to pass it across.  Reading in
clock 1 needs only what the Sync PLD already has.

**Timing**

| Path | Stages (ns) | Total | Slack |
|---|---|---:|---:|
| Video read, every byte: PIXEL_ENABLE tCF, ADDR_SEL, mux, tAA, pixel buffer setup | 2.5 + 7.5 + 7.5 + 15 + 2 | 34.5 | +5.2 |
| Video read through the upper 32K /CE inverter (until TIMING.md item 4) | 17.5 + 6 + 15 + 2 | 40.5 | −0.8 |
| PIXEL_ENABLE.D: H_VIDEO_ACTIVE tCO, Sync tS | 5.5 + 3.5 | 9.0 | +30.7 |
| STALL to a register load enable: PIXEL_ENABLE tCO, STALL, LOAD_AC/LOAD_INSTR, '377 CE setup | 5.5 + 7.5 + 7.5 + 4.5 | 25.0 | +14.7 |
| STALL to the State and PC PLD registers | 5.5 + 7.5 + 3.5 | 16.5 | +23.2 |
| MEM_WR inactive before /WE can go low (write glitch) | 5.5 + 7.5 + 7.5 vs 22.1 | 20.5 | +1.6 |
| Address back on the CPU after a stall, before /WE goes low | 2.5 + 7.5 + 7.5 vs 22.1 | 17.5 | +4.6 (was −2.9) |
| Second delay stage hold: F574 clock to Q (min) vs hold | 3.2 vs 2 | | +1.2 |

The video address itself (H counter and V counter outputs) has been stable
for a whole clock by the time it is selected, so it is not in the path.

**Impact on the rest of the system**

- **Chips**: none added.  The Sync PLD changes one equation and one pin
  from combinational to registered (pin 19 has 16 product terms, it needs
  one).
- **Pixel pipeline**: the pixel buffer now loads at the end of clock 1, one
  clock later than now.  `pixelSel` (H2:H0) and `videoActiveR` have to be
  delayed one clock more to stay lined up with it, which is a second stage
  in the delay F574.  That register has 4 of its 8 bits in use, so the
  second stage takes the other 4 (stage 1 Q outputs wired to stage 2 D
  inputs).  The colour decoder takes its H2:H0 and VIDEN from stage 2.
- **Line mode**: `lineCode` stays clocked by the rising edge of
  `videoActiveR`, now from stage 2.  That edge comes at the end of the first
  read (clock 1 of group 48) just as it comes at the end of clock 0 now, so
  it still captures the first byte of the line.  The 1 ns hold race in
  TIMING.md ("Line-mode register") is unchanged.
- **Picture position**: the pixels come out one clock (one pixel, 40 ns)
  later than HSYNC, so the back porch grows from 48 to 49 clocks and the
  front porch shrinks from 16 to 15.  That is well inside what a VGA
  monitor tolerates, and auto-adjust centres it anyway.  HSYNC and VSYNC do
  not change.
- **CPU**: still 80 stall clocks per line, one per 8-clock group, so no
  speed change.  The stall moves from clock 0 to clock 1 of each group,
  which nothing in the CPU depends on.  The State, PC, Branch and ALU PLDs
  do not change, and neither does `placard_sim.py`.
- **Software**: nothing changes.
- **Files to change**: `ATF22V10_SYNC.pld` and `sync_pld.vhd` (PIXEL_ENABLE
  registered), `basys_top.vhd` (second delay stage), and TIMING.md.

## Option B: flatten the Sync PLD equations

Write VIDEO_ACTIVE and PIXEL_ENABLE as intermediate expressions and use
those in PIXEL_ENABLE and the three ADDR_SEL equations, so each output is
one level from the Sync PLD inputs:

    PIXEL_ENABLE = V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & !H2 & !H1 & !H0;
    ADDR_SEL     = (V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & !H2 & !H1 & !H0) # PC_ENABLE;
    ADDR_SEL_HI  = !(V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & !H2 & !H1 & !H0) & (PC_ENABLE # Y_ENABLE);
    ADDR_SEL_LO  = !(V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & !H2 & !H1 & !H0) & (PC_ENABLE # X_ENABLE);

ADDR_SEL_HI and ADDR_SEL_LO become 10 product terms each, which fits pin 21
(12) and exactly fills pin 22 (10).

- **Good**: no change to the video pipeline, the picture position, or any
  other PLD.  Both video reads pass (37.5 ns first byte, 34.5 ns others).
- **Not fixed**: PIXEL_ENABLE is still combinational, so STALL and MEM_WR
  stay late and the write glitch remains on every video byte (MEM_WR
  inactive at 28.0 / 25.0 ns against 22.1 ns).  PIXEL_ENABLE to a load
  enable is 32.5 ns (+7.2).
- **Files to change**: `ATF22V10_SYNC.pld` and `sync_pld.vhd`.

## Option C: registered PIXEL_ENABLE, still read in clock 0

Same timing as option A, but the decode has to happen in clock 7 of the
previous group and needs the next H_VIDEO_ACTIVE (VIDEO_ON at H = 47, or
H_TC at H = 127).  With no spare output pin on the H counter PLD or the
Sync PLD, that means one more PLD (or moving the pixel enable into a new
chip).  It keeps the picture where it is and the delay register as it is.
A one-pixel shift is not worth a chip, so it is not recommended.

## Checked in simulation

The FPGA model (`basys_top.vhd` with the PLD entities) was run in GHDL for
the first 36 ms of `cpu_test`, once as the sources stand and once with
option A (registered PIXEL_ENABLE in `sync_pld.vhd` and the second delay
stage in `basys_top.vhd`).
From 2 ms to 36 ms (849,998 clocks, about two frames):

- The RGB output with option A is identical to the current output delayed
  by exactly one clock, with no mismatches, so every pixel and every line
  mode lines up as before, one pixel to the right.
- HSYNC and VSYNC are identical clock for clock.
- The CPU makes the same 73,403 RAM writes, with the same addresses and
  data in the same order.
