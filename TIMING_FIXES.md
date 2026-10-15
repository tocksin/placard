# Remaining timing fixes

Date: 2026-10-15

This covers what was left in [TIMING.md](TIMING.md) after the ALU
([ALU_TIMING.md](ALU_TIMING.md)), video read
([VIDEO_TIMING.md](VIDEO_TIMING.md)) and X/Y address
([XY_TIMING.md](XY_TIMING.md)) fixes.  Timing figures are the same
worst-case datasheet values as TIMING.md (ATF22V10C-7, 74F glue,
AS7C256C-15).

## Summary

| Problem | Before | Status |
|---|---:|---|
| ALU wait clock came after the AC load (bug in Branch PLD rev 06) | ADD/SUB had one clock, not two | **Fixed**, Branch PLD rev 07 |
| Store from AC/X straight after FETCH: write data | −1.1 ns | **Fixed**, State PLD rev 10 (+0.3 to 0.8 % clocks) |
| `lineCode` hold race | −1.0 ns | **Fixed**, F377 on the system clock (same chip count) |
| Fetch into the branch check | −6.8 ns | Open: needs one more PLD, or an instruction encoding change |
| Upper 32K RAM /CE through the '04 (reads) | −3.8 ns | Open: needs one more PLD |
| Upper 32K RAM /CE through the '04 (writes, **found here**) | −4.4 ns | Open: needs one more PLD |
| ROM /OE through the '04 | −3.3 ns | Open: waits on the ROM choice |
| End-of-write bus contention | up to 7.6 ns | Open: unchanged |

## Fixed

### ALU wait clock (Branch PLD rev 07)

Revision 06 set ALU_WAIT at the end of the first EXEC clock and used it to
stall the next one.  But STALL was low during the first EXEC clock, so the
State PLD loaded AC at its end and moved on to FETCH; the wait clock was a
stalled FETCH after the load.  The GHDL model showed it: in every ADD/SUB
EXEC clock, `acLoad` was 1 and the wait register was 0.  The extra clock was
spent, but the ALU still had only one clock.

Revision 07 stalls the first EXEC clock instead:

    STALL      = PIXEL_ENABLE
               # EXEC & ADDSUB_REG & !ALU_DONE
    ALU_DONE.D = EXEC & !PIXEL_ENABLE & ADDSUB_REG & !ALU_DONE
               # ALU_DONE & PIXEL_ENABLE

ALU_DONE replaces ALU_WAIT on pin 18.  It is set by the first EXEC clock the
CPU owns, so the second clock loads the result, and it holds through a video
stall so a stalled second clock does not cost another wait.  STALL is 3
product terms (pin 19 has 16) and ALU_DONE 3 (pin 18 has 16).  The clock
count is the same as revision 06, so the speed figures in ALU_TIMING.md
stand.

| Path | Total | Slack |
|---|---:|---:|
| ADD/SUB result into AC/X/Y (two clocks, lookahead ALU) | 68.5 of 79.4 | +10.9 |
| STALL (EXEC tCO, IR, Branch) to a '377 load enable via the State PLD | 10.5 + 7.5 + 7.5 + 4.5 = 30.0 | +9.7 |
| STALL to the State and PC PLD registers | 10.5 + 7.5 + 3.5 = 21.5 | +18.2 |
| PIXEL_ENABLE to MEM_WR inactive (write glitch, VIDEO_TIMING.md) | 5.5 + 7.5 + 7.5 = 20.5 | +1.6 |

### Stores from AC or X to [0,X] or [Y,X] (State PLD rev 10)

These went straight from FETCH to EXEC, so the write clock started with the
instruction register loading, the '138 decoding the source, and the '541
turning on: the data reached the RAM at 35 ns, 1.1 ns after the latest time
the write allows.  They now pass through LOAD_MEM, which reads the target
location into D (not used by a store from AC or X) and does not touch the
PC.  In EXEC the instruction register, source bus and address are all a
clock old, so the data and address checks pass with most of a clock to
spare.

- **Equations**: only Q0's FETCH terms change (Q1 is unchanged, because
  LOAD_MEM and EXEC both have Q1 = 1).  Q0 goes from 8 to 9 product terms,
  so it moves from pin 14 (8 terms) to pin 18 (16 terms), and LOAD_INSTR
  (1 term) moves to pin 14.  The Branch PLD's Q0 input now comes from State
  PLD pin 18.
- **Branches**: BLE and BRA with an AC or X target share the encoding
  (source 1x, MEM 110/111), so they take the same path and one more clock.
  They still work, because LOAD_MEM does not change the PC.
- **Speed**, from `placard_sim.py` (30 M instructions each):

  | Program | Extra clocks |
  |---|---:|
  | pi_spigot | +0.30 % |
  | mandelbrot | +0.01 % |
  | game_of_life | +0.80 % |

- **Setup into the new Q0 terms**: the same data bus inputs as before, 39.0
  ns (+0.7), TIMING.md rank 9.

### Line-mode register

`lineCode` was an F574 clocked by the rising edge of `videoActiveR`, which
came up to 10 ns after the system clock edge and needed the data bus held
2 ns past that, 1 ns longer than the bus is guaranteed to stay.  It is now
an F377 on the system clock with its load enable tied to `videoActiveR`:
it loads the data bus on every clock while `videoActiveR` is low and stops
when it goes high, so it keeps the value from the edge that ends the first
byte read of the line.  The loads during blanking are not seen, because the
colour decoder blanks the output while `videoActiveR` is low.

- **Chips**: the F574 becomes an F377 (SN74F377AN, in stock), no gates.
- **Timing**: data setup is the pixel buffer's (34.5 ns, +5.2), data hold is
  1 ns against at least 11 ns, and the enable comes from the delay F574
  (3.2 to 10 ns) against the F377's 4.5 ns enable setup and 0 ns hold.

### Checked in simulation

In GHDL with `cpu_test` run to completion (60 ms), all 81,746 RAM writes
(address and data, in order) match the design before any of today's timing
changes.  In every ADD/SUB, `acLoad` is now 0 in the first EXEC clock and 1
in the second.  With a halted CPU and a different mode byte on each of the
480 lines, the new `lineCode` register captures the same 480 values as the
old one, and each matches the byte written for that line.

## Open: needs a decision

### Fetch into the branch check (−6.8 ns)

    PC_ENABLE tCO 5.5, Sync ADDR_SEL 7.5, mux 7.5, RAM tAA 15,
    Branch PLD BRANCH_BLOCK (from DB7:5) 7.5, State Q1 setup 3.5 = 46.5 ns

The State PLD only uses BRANCH_BLOCK in FETCH for one case: source AC/X with
MEM 101 goes to LOAD_IMM for a zero-page store but straight to EXEC for BGE.
The State PLD has no spare pin for DB7:5 itself.

### Upper 32K RAM chip select (−3.8 ns reads, −4.4 ns writes)

The upper chip's /CE is !A15 through the '04.  For reads that is TIMING.md
rank 5 (43.5 ns).  The write side was missed in TIMING.md and is worse,
because it can corrupt memory:

- When a write's A15 is 0 and the address before it had A15 = 1, the upper
  chip stays selected until !A15 comes out of the '04.  /WE can go low at
  22.1 ns, so the upper chip also sees a short write at the same low 15
  address bits.
- After a zero-page store that follows LOAD_IMM with the program running in
  the upper 32K, !A15 settles at 26.5 ns (−4.4).
- After a video stall in the right half of a line (H9 = 1, so video A15 = 1)
  followed by a store to the lower 32K (zero page, for example), !A15
  settles at 23.5 ns (−1.4).  That happens in ordinary programs.

The reverse case (a write to the upper chip) is safe: the lower chip's /CE
is A15 itself and deselects in time, and the upper chip's late /CE still
leaves 15.4 ns of the 12 ns /CE-to-end-of-write time.

### Options

**A. Add one PLD for A15 and Q1 (recommended).**  It takes the high-byte mux
selects (ADDR_SEL, ADDR_SEL_HI) and the three A15 sources (PC15, video H9,
Y7), and makes A15 and !A15 from the same array, so both chip selects are
valid when the mux output is (20.5 ns).  It also takes the State PLD's Q1
register, with DB7:0 straight off the data bus, so the branch case no
longer goes through the Branch PLD.

| Pin use | Count |
|---|---:|
| Inputs: CLK, DB7:0, STALL, Q0, ADDR_SEL, ADDR_SEL_HI, PC15, H9, Y7 | 16 |
| Outputs: PC_ENABLE (= !Q1, registered), /CE lower (A15), /CE upper (!A15) | 3 |
| Spare I/O pins | 3 |

| Path | After |
|---|---:|
| Fetch into Q1 (data bus straight into the new PLD's Q1 register) | 35.5 + 3.5 = 39.0 (+0.7) |
| Upper 32K read through /CE: 20.5 + tACE 15 + IR setup 2 | 37.5 (+2.2) |
| Upper 32K chip deselected before /WE goes low | 20.5 vs 22.1 (+1.6) |

The State PLD's pin 15 becomes the Q1 input (from PC_ENABLE) and its Q1
equation moves out, so it no longer needs BRANCH_BLOCK in FETCH.  The '04
keeps only the ROM /OE inverter.

**B. No new chip.**  Give BGE with an AC or X target a padding byte, so it
goes through LOAD_IMM like a zero-page store and the State PLD no longer
needs BRANCH_BLOCK in FETCH.  None of pi_spigot, mandelbrot or
game_of_life uses that form; cpu_test does 9 times.  That fixes only the
branch check (it changes the instruction encoding and the assembler).  The
upper chip select problems stay.

### ROM /OE (−3.3 ns)

The ROM's /OE is !ROM_EN through the '04, and the RAM's /OE is ROM_EN, so the
ROM/RAM select PLD needs both polarities, but all 10 of its macrocells are
in use (8 map bits and ROM_EN, with pin 23 as the RW input).  The ROM part
is still undecided, so this waits on that choice.  If the battery-backed
AS7C256C stays, one way with no added chip is to fix section 0 as ROM (the
reset code is there anyway), which frees a map macrocell for a separate,
non-inverted ROM /OE.

### End-of-write contention

Unchanged: the write buffer turns off up to 13.1 ns after the edge while the
RAM can drive again from about 6 ns, so the two can fight for a few ns per
write.  Fixing it needs separate RAM and ROM read enables with a hold-off
after a write, which also needs ROM/RAM select PLD macrocells, so it goes
with the ROM /OE decision.
