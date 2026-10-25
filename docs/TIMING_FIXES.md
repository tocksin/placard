# Remaining timing fixes

Date: 2026-10-25

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
| Bus contention at the end of a write | up to 7.6 ns | **Fixed**, new memory control PLD in place of the '32 (+8.9) |
| Bus contention at the start of a write after a video stall (**found here**) | up to 5.5 ns | **Fixed**, same change (+10.9) |
| Fetch into the branch check | −6.8 ns | **Fixed**, BGE with an AC or X target has a pad byte (State PLD rev 11, Branch PLD rev 08; memory field 101 is BCC since Branch PLD rev 11, with the same pad byte); the fetch is now 39.0 (+0.7) |

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

**Superseded 2026-10-16:** the mode byte is now read in horizontal
blanking (group 37 from x4A20 + row at first, group 45 from x5A20 + row
since the I/O window shrank), and the line code F377 copies it from
the pixel buffer with /E from /MODE_LD (audio slot PLD revision 02), so it
no longer takes byte column 0.  See [VIDEO.md](VIDEO.md#mode-byte).  The
text below is the earlier fix.

`lineCode` was an F574 clocked by the rising edge of `videoActiveR`, which
came up to 10 ns after the system clock edge and needed the data bus held
2 ns past that, 1 ns longer than the bus is guaranteed to stay.  It is now
an F377 on the system clock with its load enable tied to `videoActiveR`:
it loads the data bus on every clock while `videoActiveR` is low and stops
when it goes high, so it keeps the value from the edge that ends the first
byte read of the line.  The loads during blanking are not seen, because the
color decoder blanks the output while `videoActiveR` is low.

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
the original feature plan are done together by reworking the
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
- **I/O priority.**  The original feature plan gated the RAM and ROM read enables with
  spare OR gates and the I/O decoder's IO_SEL.  IO_SEL is a PLD level after
  the address, so the RAM read through that gate would be 43.6 ns (−3.9).

### ROM/RAM select PLD, revision 03

(Revision 04 moves ROM_OE and RAM_OE to the memory control PLD; see
[Fixed: bus contention around a write](#fixed-bus-contention-around-a-write-memory-control-pld).
The PLD itself is gone since 2026-10-16: the map is now a 74ACT273; see
[ROM/RAM map register](#romram-map-register-74act273).)

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
- **I/O strobes** as in the original feature plan: /MAP_WR and /LINE_RD (page 0),
  /SND_WR (1), /PORT_WR and /PORT_RD (2), /EXP1 (5), /EXP2 (6).  Write
  strobes are low with /WE, so a device latches on the rising edge at the
  end of the write; read strobes are low on a read the CPU latches into D
  (LOAD_IMM).  A11 is not decoded, so 5800h-5FFFh repeats 5000h-57FFh.
  (Revision 03, 2026-10-16: the window is 5000h-53FFh, /SND_WR's pin is the
  A11 input, and EXP1/EXP2 are pages 1 and 3.  A11 and A10 come from the
  address mux like A12, so the strobes and the memory control PLD's read
  enables settle at the same time as before.)
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
F541 or something at least as fast (the original feature plan already used F541s).

### Checked in simulation

- `cpu_test` to completion: all 81,746 RAM writes match.
- A short program that writes F9h to 5000h and 5Ah to 5100h: one /MAP_WR
  pulse, one /SND_WR pulse, and the map registers read back bits 7, 3, 1, 0
  as 1, 1, 0, 1.  Over 25,000 clocks (including video reads), the rebuilt
  A15 matched the mux's A15 on every clock.
- The FPGA model reads every address from its RAM block, as it did before
  (it used to by way of the `romEn` polarity bug noted in TIMING.md), because
  no program sets the map yet and the map powers up as all ROM.

### Changes to the original feature plan's I/O decode

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

## Fixed: bus contention around a write (memory control PLD)

### The problem

The write buffer (an F541 enabled by /WE) turned off up to 13.1 ns after
the clock edge that ends a write (F32 6.6, F541 disable 6.5).  RW rises as
soon as the state leaves EXEC, and the ROM/RAM select PLD turned the RAM or
ROM /OE on from it, as early as 8 ns after the edge (RW 5, PLD 3, tOLZ 0),
so the two could drive the data bus against each other for 5.1 ns on every
write.

Working it through turned up a second overlap at the start of a write that
the earlier table missed.  The State PLD's write strobe went through STALL,
so on a store straight after a video stall clock RW fell 20.5 ns into the
clock (PIXEL_ENABLE 5.5, Branch STALL 7.5, State 7.5).  The RAM's /OE was
still low from the video read, so the RAM kept driving until the write pulse
turned it off (tWHZ 8 ns), while the buffer turned on 2.5 ns after the
pulse started: up to 5.5 ns of contention on a store after a video stall,
which happens in ordinary programs.

The clean fix is to keep every read off the bus for the high half of the
clock.  That needs CLK in the read-enable decode, and the ROM/RAM select PLD
had no pin left for it.

### The fix: memory control PLD (replaces the '32)

A new ATF22V10C makes the RAM write strobe and both read enables.  It takes
the place of the SN74F32 that made /WE, so the chip count does not change.
Every memory cycle, read or write, now uses only the low half of the clock:

    WRITE  = !RW & !PIXEL_ENABLE
    READ   = RW # PIXEL_ENABLE
    /WE     low when !CLK & WRITE
    /ROM_OE low when !CLK & READ & a ROM section
    /RAM_OE low when !CLK & READ & a RAM section (or 4000h-4FFFh, not I/O)

- **Memory control PLD rev 01** (`ATF22V10_MEM_CTRL.pld`, new): inputs CLK
  (pin 1, array only), A15:A12, the seven map bits, RW and PIXEL_ENABLE;
  outputs /WE (pin 16, also the write buffer enable and the I/O decode
  PLD's /WE input), /ROM_OE (pin 17, 14 product terms of 14) and /RAM_OE
  (pin 18, 16 of 16).  Pins 15 and 19-22 are free.
- **ROM/RAM select PLD rev 04**: only the map.  ROM_OE, RAM_OE and the
  A15:A12 and RW inputs are gone; the RAMSEL outputs go to the memory
  control PLD.  Pins 2-5, 14, 15 and 23 are free.  (Later replaced by a
  74ACT273; see below.)
- **State PLD rev 12**: MEM_WR no longer includes STALL, so RW is low for
  the whole EXEC state of a store and settles 10 ns into the clock.  The
  memory control PLD blocks the write during a video stall with the real
  PIXEL_ENABLE, which is valid at 5.5 ns.  (A store never waits for the
  ALU, so for a store STALL and PIXEL_ENABLE are the same.)
- **Branch PLD rev 09**: BRANCH_BLOCK = I7 & I6 & I5, straight from the
  instruction register.  It used to include EXEC and !PIXEL_ENABLE, so it
  arrived 13 ns into EXEC and the State PLD's MEM_WR showed a write for up
  to 20.5 ns at the start of every BGE, BLE and BRA (memory field 101, 110,
  111).  The '32 hid that because the clock was still high; with RW no
  longer gated by STALL it would have been a real write after a video
  stall.  The State PLD only uses BRANCH_BLOCK in EXEC, and those branches
  always reach EXEC through LOAD_IMM or LOAD_MEM, so the instruction
  register has been settled for a clock.

### Timing

Figures are for a 50 % clock, with the worse end of a 45-55 % duty in
brackets.

| Check | Before | After | Slack |
|---|---:|---:|---:|
| End of write: buffer off (/WE 7.5 + F541 disable 6.5) vs RAM or ROM driving again (clock fall + 3) | 5.1 overlap | 14.0 vs 22.9 | +8.9 (+6.9) |
| Start of write: RAM or ROM off (clock rise + 7.5, tOHZ 7) vs buffer on (clock fall + 3 + 2.5) | +0.1 | 14.5 vs 25.4 | +10.9 (+8.9) |
| Start of write after a video stall | up to 5.5 overlap | as above | +10.9 (+8.9) |
| WRITE settled before the clock falls: RW 10, PIXEL_ENABLE 5.5 | | 10 vs 19.9 | +9.9 (+7.9) |
| Write pulse width (low half) vs tWP 10 | 19.9 | 19.9 | +9.9 (+7.9) |
| Write data before end of write: F541 enable 9.5 + tDW 8 vs low half | 17.5 vs 19.9 | 17.5 vs 19.9 | +2.4 (+0.4) |
| Address setup to /WE low: address 20.5 vs clock fall + 3 | 20.5 vs 22.1 | 20.5 vs 22.9 | +2.4 (+0.4) |
| Address hold after /WE high: /WE high by T + 7.5 vs address change at T + 8 | +1.4 | +0.5 | +0.5 |
| CPU read through /OE: max(address 20.5 + 7.5, clock fall + 7.5), tOE 7, IR setup 2 | 37.0 | 37.0 | +2.7 (+1.4) |
| Opcode through /OE into the State PLD (setup 3.5) | 38.5 | 38.5 | +1.2 (−0.1) |
| Video read through /OE: max(17.5 + 7.5, clock fall + 7.5), tOE 7, pixel buffer setup 2 | 34.0 | 36.4 | +3.3 (+1.4) |

The opcode into the State PLD is limited by tAA (39.0 ns, +0.7) as before,
as long as the clock's high half is no more than 54.6 % of the period; at
55 % the /OE path is 0.1 ns over.  VIDEO_TIMING.md already wants the high
half at least 47 %, so the clock needs a 47-54 % duty.  A divided-down
oscillator (50 %) meets it with room on both sides.

Still marginal, and unchanged by this fix: on FETCH→EXEC for a register op
straight after a store, the State PLD sees the store's memory field until
the instruction register loads (10.5 + 7.5 = 18.0 ns), so RW glitches low
until then.  The '32 had the same race; the write needs the clock to fall
after 18.0 ns, which is a high half of at least 45.4 % and is inside the
47 % already required.

### Checked in simulation

- `cpu_test` to completion in GHDL: all 81,746 RAM writes (address and
  data, in order) are identical to the run before this change.
- The map and I/O test (F9h to 5000h, 5Ah to 5100h): one /MAP_WR pulse,
  one /SND_WR pulse, and the map reads back bits 7, 3, 1, 0 as 1, 1, 0, 1.
- The FPGA's RAM model is zero-delay, so the simulation checks the logic
  (no write is lost, added or moved), not the nanosecond timing above.

## ROM/RAM map register (74ACT273)

Date: 2026-10-18

The ROM/RAM map is now an 8-bit register chip, a write-only I/O device at
5000h-50FFh, in place of the ROM/RAM select PLD (which by revision 04 held
nothing but the map).  The chip count does not change.

- **Part: CD74ACT273E** (TI, PDIP-20, octal D flip-flop with clear).  Mouser
  392 and DigiKey 796 in stock (Octopart, 2026-10-16).  It needs a clear,
  because the map must read all ROM at power-up for the CPU to boot.  The
  74F377 has no clear.  The 74HCT273 is in stock too, but its minimum clock
  pulse (20 ns) is longer than the /MAP_WR pulse.
- **Wiring**: CP = /MAP_WR (I/O decode PLD, unchanged), D7:D0 = source bus,
  Q0-Q7 = RAMSEL inputs of the memory control PLD, /MR = MAP_RUN (memory
  control PLD pin 17 since revision 03).
- **Section 2 map bit (memory control PLD rev 03)**: with the map out of
  the PLD, Q2 maps x4000-x4FFF like the other sections; it was always RAM
  only because the ROM/RAM select PLD had no pin for it.  RAMSEL2 is an
  input on pin 15.  ROM_OE moved to pin 19 for its two extra product terms
  (16 of 16) and MAP_RUN to pin 17.  The read paths are unchanged.  Like
  every section, x4000-x4FFF now reads as ROM at power-up.
- **Reset**: MAP_RUN is a register in the memory control PLD (revision 02)
  with D = 1.  The ATF22V10C clears it at power-up, so it is low until the
  first rising clock edge, which is where the CPU starts too.  The map is
  cleared before the first instruction and no RC network is needed.
  (Replaced 2026-10-20: memory control revision 08 takes RUN from the ROM
  cartridge on pin 17 instead, ROM.md "Loading the cartridge".)
- **I/O decode PLD rev 02**: comments only.  /MAP_WR already strobes page 0.

| Check | Value | Slack |
|---|---|---:|
| /MAP_WR low width (low half 17.9 at 55 % high, less 4.5 of PLD skew) vs tW 5.3 | 13.4 | +8.1 |
| Data setup to CP (source bus valid early in EXEC) vs 2 | > 15 | > +13 |
| Data hold after CP: source bus holds until the next IR load (≥ T) vs /MAP_WR rise ≤ T + 15 | ≥ 20 | > +18 |
| Logic levels: source bus 74F VOH 2.5 vs ACT VIH 2.0; ACT VOH 3.8 into the PLD | | +0.5 |
| New map into the very next fetch: /MAP_WR rises by T + 15, CP→Q 12.3, MEM_CTRL 7.5, tOE 7, IR setup 2 | 43.8 | **−4.1** |
| New map into any later clock | 34.8 from the map write's end | +44 |

**Software rule**: the instruction straight after a map write must not be
fetched from a section whose map bit that write changes, unless ROM and RAM
hold the same byte there.  The usual shadow-copy (copy the ROM into the RAM
underneath, then switch the section to RAM) is safe, because both hold the
same byte, and so is putting any other instruction between the map write and
the first fetch from the switched section.  With the map in the PLD
(tCO 5.5) the next fetch had 2.7 ns to spare.

**Checked in simulation**: `cpu_test` in GHDL makes the same 81,746 RAM
writes as before, and the map test (F9h to 5000h) gives one /MAP_WR pulse
and a map that reads back bits 7, 3, 1, 0 as 1, 1, 0, 1.
