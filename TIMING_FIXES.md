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
| Upper 32K RAM /CE through the '04 (reads) | −3.8 ns | **Fixed**, new I/O decode PLD (+2.2) |
| Upper 32K RAM /CE through the '04 (writes, **found here**) | −4.4 ns | **Fixed**, new I/O decode PLD (+1.6) |
| ROM /OE through the '04 | −3.3 ns | **Fixed**, ROM/RAM select PLD rev 03 (+2.7) |
| Bus contention at the start of a write | up to about 10 ns | **Fixed**, RAM /OE is high for the whole write (+0.1) |
| Bus contention at the end of a write | up to 7.6 ns | Reduced to 5.1 ns |
| Fetch into the branch check | −6.8 ns | **Fixed**, BGE with an AC or X target has a pad byte (State PLD rev 11, Branch PLD rev 08); the fetch is now 39.0 (+0.7) |

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

## Memory and I/O decode (two PLDs)

The upper chip select, the ROM /OE and the I/O decode planned in
[FEATURE_PLAN.md](FEATURE_PLAN.md) are done together by reworking the
ROM/RAM select PLD and adding one PLD, the I/O decode PLD.  The '04 is no
longer needed, so the chip count stays the same as before the I/O decode
was planned.

### The problems

- **Upper 32K chip select.**  The upper chip's /CE was !A15 through the
  '04.  For reads that is TIMING.md rank 5 (43.5 ns, −3.8).  The write side
  was missed in TIMING.md and is worse, because it corrupts memory: when a
  store's A15 is 0 and the address before it had A15 = 1, the upper chip
  stays selected until !A15 comes out of the '04, after /WE can go low
  (22.1 ns), so the upper chip also takes a short write at the same low 15
  address bits.  After a video stall in the right half of a line (video
  A15 = H9 = 1) followed by a store to the lower 32K (zero page, for
  example), !A15 settled at 23.5 ns (−1.4), which happens in ordinary
  programs.  After LOAD_IMM with the program in the upper 32K it was 26.5 ns
  (−4.4).
- **ROM /OE.**  The ROM's /OE was !ROM_EN through the '04 (43.0 ns, −3.3),
  because the ROM/RAM select PLD had no macrocell left for a second polarity.
- **I/O priority.**  FEATURE_PLAN.md gated the RAM and ROM read enables with
  spare OR gates and the I/O decoder's IO_SEL.  IO_SEL is a PLD level after
  the address, so the RAM read through that gate would be 43.6 ns (−3.9).

### ROM/RAM select PLD, revision 03

- **Two read enables, no inverter.**  ROM_OE (pin 14) and RAM_OE (pin 15)
  are separate active-low outputs, each one array pass from the address.
  Both are high on a write, and both are high in 5000h-5FFFh, so the I/O
  device has the bus to itself on an I/O read.
- **Section 2 has no map bit.**  The two new outputs and the A12 input
  needed the pins of one map bit.  Section 2 (4000h-5FFFh) is the natural
  one to fix, because its upper half is the I/O window: 4000h-4FFFh is
  always RAM.  Bit 2 of a map write is ignored.
- **The map loads from the source bus** on the rising edge of /MAP_WR, at
  the end of the write.  The source bus holds the store data well past the
  end of the write; the RAM-side data bus does not (the write buffer turns
  off 3.7 ns after the edge at best, and /MAP_WR can rise 7.5 ns after it).

### I/O decode PLD (new)

- **/CE_HI** is !A15 rebuilt from the high-byte mux's own selects and
  sources (ADDR_SEL, ADDR_SEL_HI, PC15, H9, Y7), not from the mux output, so
  it settles with the mux output (20.5 ns) instead of a gate after it.  The
  lower chip's /CE stays the mux's A15.  The same rebuilt A15 is used in the
  I/O window decode, which saves the A15 input pin.
- **I/O strobes** as in FEATURE_PLAN.md: /MAP_WR and /LINE_RD (page 0),
  /SND_WR (1), /PORT_WR and /PORT_RD (2), /EXP1 (5), /EXP2 (6).  Write
  strobes are low with /WE, so a device latches on the rising edge at the
  end of the write; read strobes are low on a read the CPU latches into D
  (LOAD_IMM).  A11 is not decoded, so 5800h-5FFFh repeats 5000h-57FFh.
- **Pins**: 14 inputs (/WE, ADDR_SEL, ADDR_SEL_HI, PC15, H9, Y7, A14, A13,
  A12, A10, A9, A8, RW, LOAD_IMM) and 8 outputs, all 22 pins.  WinCUPL fits
  each strobe in 7 product terms (EXP2: 7 of 10, the tightest) and /CE_HI in
  3.  The term count does not change the timing: every output is still one
  array pass.

### Timing

| Path | Before | After | Slack |
|---|---:|---:|---:|
| Upper 32K read through /CE: selects 13, /CE_HI 7.5, tACE 15, IR setup 2 | 43.5 | 37.5 | +2.2 |
| Upper 32K deselected before /WE can go low (22.1 ns) | 26.5 | 20.5 | +1.6 |
| ROM read through /OE: address 20.5, ROM_OE 7.5, tOE 7, IR setup 2 | 43.0 | 37.0 | +2.7 |
| RAM read through /OE (unchanged) | 37.0 | 37.0 | +2.7 |
| I/O read: address 20.5, /xx_RD 7.5, F541 enable 9.5, D setup 2 | | 39.5 | +0.2 |
| I/O write strobe address before /WE can go low | | 20.5 vs 22.1 | +1.6 |
| RAM stops driving before the write buffer starts: RW 10, RAM_OE 7.5, tOHZ 7 vs /WE 22.1 + F541 enable 2.5 | overlap | 24.5 vs 24.6 | +0.1 |
| End of write: RAM drives again at RW 5 + RAM_OE 3 (minimums) vs buffer off by 13.1 | 7.6 overlap | 5.1 overlap | |

The I/O read leaves only 0.2 ns, so the devices on the read bus need an
F541 or something at least as fast (FEATURE_PLAN.md already uses F541s).

### Checked in simulation

- `cpu_test` to completion: all 81,746 RAM writes match.
- A short program that writes F9h to 5000h and 5Ah to 5100h: one /MAP_WR
  pulse, one /SND_WR pulse, and the map registers read back bits 7, 3, 1, 0
  as 1, 1, 0, 1.  Over 25,000 clocks (including video reads), the rebuilt
  A15 matched the mux's A15 on every clock.
- The FPGA model reads every address from its RAM block, as it did before
  (it used to by way of the `romEn` polarity bug noted in TIMING.md), because
  no program sets the map yet and the map powers up as all ROM.

### Changes to FEATURE_PLAN.md's I/O decode

1. RAM/ROM priority is inside the ROM/RAM select PLD; no OR gates.
2. Section 2 has no map bit; 4000h-4FFFh is always RAM.
3. The map, and any other device latch, takes its data from the source bus
   and latches on the rising edge of its write strobe.
4. The decoder takes /WE instead of CLK, and the mux selects and A15
   sources instead of A15.  A11 is not decoded.
5. There is no IO_SEL output and no spare output; the eighth output is
   /CE_HI.
6. Devices that drive the read bus must enable in 9.5 ns or less.

## Fixed: fetch into the branch check (State PLD rev 11, Branch PLD rev 08)

    before: PC_ENABLE tCO 5.5, Sync ADDR_SEL 7.5, mux 7.5, RAM tAA 15,
            Branch PLD BRANCH_BLOCK (from DB7:5) 7.5, State Q1 setup 3.5 = 46.5 ns
    after:  PC_ENABLE tCO 5.5, Sync ADDR_SEL 7.5, mux 7.5, RAM tAA 15,
            State Q0/Q1 setup 3.5 = 39.0 ns (+0.7)

The State PLD used BRANCH_BLOCK in FETCH for one case only: source AC/X with
MEM 101 is a zero-page store on an ALU op (go to LOAD_IMM for the address)
but BGE on a branch (go straight to EXEC).  The State PLD has no spare pin
for DB7:5 itself, so the branch decode came from the Branch PLD, one array
pass after the RAM.

Now source AC/X with MEM 101 always goes to LOAD_IMM, and the assembler
puts a pad byte (00) after `bge ac` and `bge x`.  LOAD_IMM loads the pad
into D and steps the PC past it; EXEC then branches to AC or X as before,
with BRANCH_BLOCK still blocking the write.  The rest of the fetch is the
opcode into the State PLD and the IR, which already passed (39.0 and 37.5).

- **Instruction set**: `bge ac` and `bge x` are 2 bytes and 3 clocks (were
  1 byte and 2 clocks).  Every other instruction is unchanged.  None of
  pi_spigot, mandelbrot or game_of_life uses those forms, so their hex
  files are unchanged; cpu_test uses them 9 times.
- **State PLD rev 11**: one Q1 term removed (Q1 9 of 10 terms), comments.
- **Branch PLD rev 08**: the FETCH decode of DB7:5 (block B) is gone, so
  pins 14-16 are unused and need no wires.  BRANCH_BLOCK = BRANCH_A.
- **Assembler**: `placard.asm` (customasm) and `placard_sim.py` emit the
  pad byte, and the simulator fetches it.
- **Checked**: `placard_sim.py` runs the regenerated cpu_test to the end
  with every test passing.  The GHDL model with the new State and Branch
  PLDs runs it to the end too, and its 81,746 RAM writes (address and data,
  in order) are identical to the simulator's.

## Open: end-of-write contention (5.1 ns)

The write buffer turns off up to 13.1 ns after the edge, and the RAM can
drive again 8 ns after it.  Closing it fully needs the read enables held
off for the first half of the clock after a write, which needs CLK and a
register in the ROM/RAM select PLD, and it has no pin left.
