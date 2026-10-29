# ALU timing options

Date: 2026-10-21

The ALU is the worst path in [TIMING.md](TIMING.md): 91 ns against a
39.72 ns clock (25.175 MHz).  This document works out how to fix it with
ATF22V10C PLDs and in-stock DIP parts, using as few chips as possible, and
what each fix changes in the rest of the system.  Timing figures are the
same worst-case datasheet values as TIMING.md (ATF22V10C-7, 74F glue).

**Status:** option 1 is implemented (ALU_SHR.pld revision 05, Branch PLD
revision 07, 2026-10-15).  Revision 06 put the wait clock after the load
instead of before it; revision 07 stalls the first EXEC clock instead, with
an ALU_DONE register in place of ALU_WAIT (see
[TIMING_FIXES.md](TIMING_FIXES.md)).  The ALU_WAIT equations below are the
original revision 06 description.

## Recommendation

**Option 1: rewrite the ALU carry equations (5 PLD levels instead of 8) and
give ADD/SUB one wait clock.**  It adds no chips, closes the ALU paths with
at least 10.9 ns to spare, and costs about 6 to 7 % of CPU speed on the
benchmark programs.

| Option | Chips added | Worst ALU path vs budget | Slack | CPU cost (pi / Mandelbrot) |
|---|---:|---|---:|---|
| **1. Lookahead rewrite + 1 wait clock on ADD/SUB** | **0** | 68.5 ns vs 79.4 ns | **+10.9** | **+6.0 % / +6.7 %** |
| 2. Original ALU + 2 wait clocks on ADD/SUB | 0 | 91.0 ns vs 119.2 ns | +28.2 | +11.9 % / +13.4 % |
| 3. Original ALU + 1 wait clock | 0 | 91.0 ns vs 79.4 ns | −11.6 | (does not close) |
| 4. Lookahead + carry select, no wait | +1 PLD | 53.5 ns vs 39.7 ns | −13.8 | (does not close) |
| 5. Lookahead rewrite only, no wait | 0 | 68.5 ns vs 39.7 ns | −28.8 | (does not close) |
| 6. Lookahead rewrite + whole CPU at half speed | 0 | 68.5 ns vs 79.4 ns | +10.9 | about +100 % |

## Why no option makes ADD/SUB single-clock

A single-clock ADD has to fit this between two clock edges:

    D register clock-to-Q (F377)   10.5 ns
    source bus buffer (F541)        6.0 ns
    ALU                             ?
    AC register setup (F377)        2.0 ns

That leaves 21.2 ns for the ALU, which is fewer than three PLD levels
(3 × 7.5 = 22.5 ns).  The fastest ALU found here (option 4, carry select)
is exactly three levels, so even the best case misses by 1.3 ns.  When the
instruction goes straight from FETCH to EXEC (source AC or X), the
instruction register, the '138 decoder and the '541 enable add another
12.5 ns.  So ADD and SUB need a second clock.  The other ALU functions do
not (see below).

## How the current ALU spends its time

`ALU_SHR.pld` builds the ripple carry from three carry nodes, D1, D2 and D3,
each on an output pin fed back into the array, and builds COUT from D3:

    low chip:   B → D1 → D2 → D3 → COUT          4 levels
    high chip:  CIN → D1 → D2 → D3 → F3          4 levels
    total                                         8 levels = 60 ns

## Lookahead rewrite (options 1, 4, 5)

The 22V10 has enough product terms to skip one node in each chip, by
writing the two-bit carry as an intermediate expression (not a pin), which
WinCUPL expands into the equation:

    C1   = ((A0 $ S0) & B0) # ((A0 $ S0) & CIN) # (B0 & CIN);   /* not a pin */
    D2   = ((A1 $ S0) & B1) # ((A1 $ S0) & C1)  # (B1 & C1);    /* from the inputs: 1 level */
    C3   = ((A2 $ S0) & B2) # ((A2 $ S0) & D2)  # (B2 & D2);    /* not a pin */
    D4   = ((A3 $ S0) & B3) # ((A3 $ S0) & C3)  # (B3 & C3);
    COUT = (ARITH_SEL & D4) # (SHR_SEL & A0);                   /* from the D2 pin: 2 levels */

D1 and D3 stay as they are (F1 and F3 still use them), and F0 to F3 do not
change.  The new paths are:

    low chip:   B → D2 → COUT                     2 levels
    high chip:  CIN → D2 → D3 → F3                3 levels
    total                                         5 levels = 37.5 ns

The low chip's F3 (B → D2 → D3 → F3) is 3 levels and finishes long before
the high chip.

**Product terms** (minimised by brute force, so WinCUPL should land on the
same or within a term or two):

| Output | Terms | Pin (terms available) |
|---|---:|---|
| F0 | 10 | 17 (14) |
| F1 | 10 | 20 (14) |
| F2 | 10 | 16 (12) |
| F3 | 10 | 21 (12) |
| COUT (from D2) | 14 | 18 (16) |
| D2 (from inputs) | 13 | 19 (16) |
| D1 | 5 | 15 (10) |
| D3 (from D2) | 5 | 22 (10) |
| Z | 1 | 14 (8) |
| SHIFT_RIGHT_IN | input | 23 |

It is still one program for both chips, but the pin numbers move, so the
board wiring and `alu4.vhd` change with it.

## Wait clock (options 1, 2)

The CPU already has a stall: when PIXEL_ENABLE is high, the State PLD holds
its state and blocks every register load and RAM write, and both PC PLDs
stop counting.  A wait clock reuses that by making a second stall source,
ALU_WAIT, and feeding the OR of the two to the PLDs that stall.

- **Where**: the Branch PLD has four unused I/O pins (17 to 20).  It needs
  a clock to hold a register, so I7 moves from pin 1 to pin 17 and pin 1
  becomes CLK.  That leaves pins 18 to 20 for:

        ALU_WAIT.D = Q0 & !PC_ENABLE                 /* EXEC */
                   & !PIXEL_ENABLE
                   & I7 & !I6                        /* ADD or SUB */
                   & !(M2 & (M1 # M0))               /* destination AC, X or Y */
                   & !ALU_WAIT;                      /* one clock only */

        STALL = PIXEL_ENABLE # ALU_WAIT;             /* combinational */

  Option 2 needs a two-clock count, which is one more register on the
  spare pins.
- **Wiring**: STALL replaces PIXEL_ENABLE on State PLD pin 2 and on pin 14
  of both PC PLDs.  The Sync PLD, the address mux and the pixel buffer keep
  the real PIXEL_ENABLE, so a wait clock never takes the bus from the video.
  The Branch PLD keeps using PIXEL_ENABLE internally (a branch is never an
  ADD/SUB).
- **Stores are not slowed**: an ADD/SUB with a RAM destination writes the
  source bus, not the ALU result, so it does not wait.
- **After a video stall**: if the video stalls the second clock, ALU_WAIT
  sets again and the ADD takes one more clock.  This is harmless and happens
  to about 1 in 8 ADD/SUBs during active video; avoiding it would cost
  another register.

**Timing with the wait clock.**  The ALU result now has two clocks
(79.44 ns), because the operands (D, AC, the instruction register and the
source select) are all stable from the first EXEC clock:

| Path | Original ALU | Lookahead ALU |
|---|---:|---:|
| FETCH→EXEC, source AC: IR, '138 (since 2026-10-19 the audio PLD's /AC_SEL), '541 enable, ALU, AC setup | 91.0 | 67.0 |
| LOAD→EXEC, source D: D, '541 (since 2026-10-18 enabled by /SRC_EN in EXEC), ALU, AC setup | 78.5 | 62.0 |
| Slack with 1 wait clock (79.44 ns) | −11.6 / +0.9 | **+12.4 / +17.4** |
| Slack with 2 wait clocks (119.16 ns) | +28.2 / +40.7 | |

**The other ALU functions stay single-clock.**  PASS B (LD), AND, OR, XOR,
SHR and PASS A each come out of one PLD level from their inputs.  The carry
nodes still ripple, but their terms are gated by ARITH_SEL (S2 & !S1), which
is settled 10.5 ns into the cycle, so they cannot reach F.

| Single-clock path (non-arithmetic) | Total | Slack |
|---|---:|---:|
| FETCH→EXEC, source AC: IR 5.5 (the IR PLD since 2026-10-21; the F377's 10.5 before), audio PLD /AC_SEL 7.5 (the '138's 9 until 2026-10-19), '541 enable 9.5, ALU 7.5, AC setup 2 | 32.0 | +7.7 |
| LOAD→EXEC, source D: /SRC_EN (State 5.5 + branch PLD 7.5), '541 enable 9.5, ALU 7.5, AC setup 2 | 32.0 | +7.7 |
| Branch decision (PASS A, Z): TIMING.md rank 12, with the IR PLD's 5.5 | 31.5 | +8.2 |

## Impact on the rest of the system

**Option 1 (recommended)**

- **Chips**: none added.  The two ALU PLDs get new equations and new pin
  numbers.  The Branch PLD gets two more outputs and one moved input.
- **Speed**: ADD and SUB to AC, X or Y take one more clock (2→3 or 3→4).
  Running the programs in `src/scripts` through `placard_sim.py` and
  counting those instructions gives:

  | Program | Instructions | ADD/SUB to a register | Extra clocks |
  |---|---:|---:|---:|
  | pi_spigot.asm (first 30 M instructions) | 30,000,000 | 19.9 % | +6.0 % |
  | mandelbrot.asm (first 30 M instructions) | 30,000,000 | 22.2 % | +6.7 % |
  | cpu_test.asm (to completion) | 300,887 | 26.2 % | +9.3 % |

  These are instruction-level counts; the video stalls (1 clock in 8 during
  active lines) come on top in both cases.
- **New timing path**: STALL is one PLD level after PIXEL_ENABLE.  With
  PIXEL_ENABLE combinational as it is now, the first byte of a line gives
  20.5 (PIXEL_ENABLE) + 7.5 (STALL) + 7.5 (State LOAD_*) + 4.5 ('377 enable
  setup) = 40.0 ns, which misses by 0.3 ns.  Registering PIXEL_ENABLE,
  which TIMING.md already recommends for the video read, makes it 25 ns
  (+14.7).  STALL to the PC PLDs and the State PLD registers is 31.5 ns
  (+8.2) either way.
- **Software**: nothing changes in the instruction set or the assembler.
  Cycle-counted code (none today) would see ADD/SUB one clock longer.
- **Files to change**: `ALU_SHR.pld` and `alu4.vhd` (equations and pins),
  `ATF22V10_BRANCH.pld` and `branch_pld.vhd` (ALU_WAIT, STALL, pin 1 as
  CLK), `basys_top.vhd` (STALL to the State and PC PLDs), CPU.md (clock
  counts), and `placard_sim.py` (one more clock for ADD/SUB to a register).

**Option 2 (no ALU rewrite)**

- Same Branch PLD change plus a second wait register, and no ALU change.
- Twice the speed cost (+11.9 % pi, +13.4 % Mandelbrot), for not having to
  re-pin and re-verify the ALU.

**Options 3 to 6** do not close timing (3, 4, 5) or halve the CPU speed (6).
Option 4's carry select (two high-nibble PLDs, one built for carry-in 0 and
one for carry-in 1, with the low COUT driving their output enables) makes
the ALU 22.5 ns, but it costs a PLD, wire-ORs two chips' outputs, and still
misses single-clock by 1.3 ns.  If ADD/SUB ever needs to drop back to one
clock (at a lower pixel clock, or with a faster register and bus path), it
is the starting point.
