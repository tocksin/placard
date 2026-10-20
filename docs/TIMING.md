# Timing analysis at 25.175 MHz

Date: 2026-10-20

This is a static, worst-case timing analysis of the Placard as it sits in
`src/hdl/basys_top.vhd` and the PLD sources in `src/pld`, for a real board
built from ATF22V10C PLDs, AS7C256C-15PCN SRAMs and 74F glue logic,
clocked at the VGA pixel clock of 25.175 MHz.  Every part used is a DIP part
that Mouser had in stock on 2026-10-15 (see [Parts](#parts)).

## Summary

**The design does not meet timing at 25.175 MHz.**  The clock period is
39.72 ns.  With the fastest in-stock DIP parts (ATF22V10C-7 and 74F glue),
8 of the 16 register-to-register paths checked are too long, and the RAM
write cycle fails its address setup checks and, for stores straight after
FETCH, its data setup check.

| Rank | Path | Delay | Slack |
|---:|---|---:|---:|
| 1 | ALU carry chain (8 PLD levels, 60 ns of PLD alone) | 91.0 ns | −51.3 ns |
| 2 | Video read, first byte of each line | 52.5 ns | −12.8 ns |
| 3 | X/Y-indexed RAM read right after FETCH | 50.0 ns | −10.3 ns |
| 4 | Instruction fetch through the RAM into the branch check | 46.5 ns | −6.8 ns |
| 5 | Upper 32K RAM chip select (A15 through an inverter) | 43.5 ns | −3.8 ns |
| 6 | ROM /OE (ROM_EN through an inverter) | 43.0 ns | −3.3 ns |
| 7 | Video read, other bytes | 42.0 ns | −2.3 ns |

As expected, the RAM sits in most of the failing paths (ranks 2 to 7), but the
worst path is the ALU, which does not touch the RAM.  The two 4-bit ALU PLDs
ripple the carry through eight array passes, which is 60 ns before any
register or bus delay is added, so a single-clock EXEC cannot work at
25.175 MHz with this ALU.
The ALU has since been changed to a lookahead carry with one wait clock on
ADD/SUB, which closes both ALU paths ([ALU_TIMING.md](ALU_TIMING.md)); the
tables below are the analysis of the design before that change.  The carry
flag (Branch PLD revision 11) latches the high ALU's COUT in the same two
clocks: IR 10.5 + audio PLD /AC_SEL 7.5 + '541 enable 9.5 + four ALU
passes 30 + setup 3.5 = 61 ns against 79.44 ns, 18.4 ns to spare (the
source '138 was replaced by /AC_SEL on 2026-10-19, CPU.md "Source mode").
[VIDEO_TIMING.md](VIDEO_TIMING.md) works through the video read (ranks 2
and 7) and the write glitch, which the ALU change's STALL signal spread from
the first byte of a line to every video byte.
[XY_TIMING.md](XY_TIMING.md) fixes the X/Y-indexed read after FETCH
(rank 3) and the late store address after FETCH.
[TIMING_FIXES.md](TIMING_FIXES.md) covers the rest: the ALU wait clock
bug, stores after FETCH, the `lineCode` race, the chip selects, the
fetch into the branch check (rank 4, fixed by a pad byte after BGE, now
BCC, with an AC or X target), the bus contention around a write (fixed by a memory
control PLD in place of the '32), and a write race on the upper 32K chip
select found there.

The slowest path limits the clock to about 11 MHz.  If the ALU were given two
clocks, the next limit is about 19 MHz.

Section [What it would take](#what-it-would-take) lists the changes that
recover the most time.

## Assumptions

- **Clock**: 25.175 MHz, period T = 39.72 ns, 50 % duty (high and low phases
  19.86 ns each).  A 45/55 % oscillator shortens one phase to 17.87 ns, which
  matters only for the RAM write pulse.
- **Worst case**: datasheet maximum delays and minimum setup/hold times at
  commercial temperature (0 to 70 °C).  Typical parts are faster, but a
  design that only works with typical parts will fail on some boards.
- **Not included**: clock skew between chips, board trace delay, and extra
  load capacitance on the data and address buses.  The RAM is specified into
  30 pF and the PLD into its standard test load, while the data bus here
  feeds about ten inputs.  All of these make the real numbers worse, so the
  margins below are upper bounds.
- **Parts**: only DIP parts in stock at Digikey or Mouser, and 74F wherever a
  74F part is in stock.  Every glue function has an in-stock 74F part except
  the 2-to-4 decoder: no 74F139 is stocked, so the source-bus decoder is a
  74F138 with its C input tied low.
- **PLD speed grade**: no grade is named in the design, so this assumes the
  fastest grade still made in 24-pin DIP, **ATF22V10C-7PX**.  The
  ATF22V10C-15PU, the other DIP grade, doubles every PLD delay (tPD 15 ns)
  and makes every path here worse.
  (2026-10-19: six PLDs with room to spare use the ATF22V10C-10PU, also
  DIP; see CHIPS.md, "PLD speed grades".  The paths here are unchanged.)
- **PLD pin feedback**: where a WinCUPL equation names another *combinational
  output pin* on its right-hand side (for example `ADDR_SEL = PIXEL_ENABLE #
  PC_ENABLE` in `ATF22V10_SYNC.pld`), the 22V10 takes that signal back in
  through the pin, so it costs a second full tPD.  Names that are not pins
  (intermediate variables such as `S_EXEC` in the State PLD) are expanded
  into the equation and cost nothing extra.  The fitter report (`.doc` file)
  shows which way WinCUPL built each equation.
- **Registered feedback**: a registered output used inside its own PLD
  reaches the array after tCF (2.5 ns), so a combinational output decoded from
  it is valid at tCF + tPD = 10 ns.  A registered output used by another chip
  is valid at tCO = 5.5 ns.
- **Reset**: `pixelEnAndRst` (the FPGA's `pixelEn or rstVGA`) is treated as
  PIXEL_ENABLE with no gate, because the reset OR only exists in the FPGA
  model.

## Parts

The PLDs are named in the VHDL.  The rest of the board is inferred from
`basys_top.vhd`; the chip choices below are the simplest match, and other
choices change the glue delays but not the conclusions.  Stock is Mouser,
checked 2026-10-15 (stock moves, so recheck before ordering).

| Function in `basys_top.vhd` | Part (DIP) | Qty | Mouser stock |
|---|---|---:|---:|
| State, branch, PC low/high, ALU low/high, ROM/RAM select, H/V counters, sync, colour decoder (since TIMING_FIXES.md the ROM/RAM select PLD is a CD74ACT273E map register, and the I/O decode and memory control PLDs are added) | ATF22V10C-7PX (PDIP-24) | 11 | 644 |
| Address mux (`full_mux` = 2 × `quad_4to1_mux` per byte) | ATF22V10C-7PX | 4 | (above) |
| `instReg`, `dReg`, `acReg`, `xReg`, `yReg`, `pixelBuffer` (D flip-flops with a load enable) | SN74F377AN | 6 | 764 |
| `lineCode` (F377 on the system clock since TIMING_FIXES.md; originally an F574 clocked by `videoActiveR`); the `videoActiveR` + `pixelSel` delay F574 was removed 2026-10-19 (VIDEO_TIMING.md) | SN74F377AN | 1 | 764 / 466 |
| Source bus (`srcBus` = D or AC, selected by `instReg(1)`; since 2026-10-18 also the memory data bus, enabled only in EXEC, see CPU.md "One data bus"; until 2026-10-19 also X, with a third F541 and an SN74F138N decoder) | 2 × SN74F541N | 2 | 724 |
| RAM write-data buffer (source bus onto the RAM data pins, enabled by /WE; removed 2026-10-18, kept as a fallback in CPU.md) | SN74F541N | 1 | (above) |
| `/WE = RW or CLK` (replaced in TIMING_FIXES.md by the memory control PLD, which also makes the ROM and RAM /OE) | SN74F32N | 1 | 494 |
| ROM /OE from ROM_EN, /CE of the upper 32K chip from A15 (removed in TIMING_FIXES.md: both now come from PLDs) | SN74F04N | 1 | 514 |
| 64 KB RAM | AS7C256C-15PCN (32K × 8, PDIP-28) | 2 | 232 |
| 64 KB ROM | AS7C256C-15PCN on the cartridge, loaded from 2 × AT28C256 at power-up (ROM.md) | 2 | (above) |

The AS7C256C is 32K × 8, so each 64 KB space takes two chips and A15 picks
one of them.  That adds a chip-select path that does not exist in the FPGA
model (rank 5).

**Logic levels**: 74F outputs guarantee only 2.5 V high (at 4.5 V, −1 mA),
and the AS7C256C needs 2.4 V high on its inputs at 5 V.  The source F541s
(the write-data buffer before 2026-10-18) meet this with 0.1 V to spare;
the series resistors on the shared bus carry only input leakage, so they
take almost nothing from it.  The ATF22V10C and AS7C256C outputs
(2.4 V min) drive only TTL-level inputs (PLDs, 74F), so they are fine.  Do
not put plain 74HC inputs on these buses.

## Datasheet figures used

### ATF22V10C-7 (DIP)

Source: Atmel ATF22V10C/ATF22V10CQ datasheet, 0735P–PLD–01/02, AC
characteristics.  The −7 tCO is 5.5 ns for DIP packages (note 2 of the
table); 4.5 ns applies to PLCC only.

| Parameter | Description | −7 | −15 (for reference) |
|---|---|---:|---:|
| tPD | input or feedback to combinational output | 7.5 ns max | 15 ns max |
| tCO | clock to registered output | 5.5 ns max (DIP) | 8 ns max |
| tCF | clock to feedback | 2.5 ns | 2.5 ns |
| tS | input or feedback setup | 3.5 ns min | 10 ns min |
| tH | hold | 0 ns | 0 ns |
| tW | clock width | 3.0 ns min | 6.0 ns min |
| tPD min | | 3.0 ns | 3.0 ns |
| tCO min | | 2.0 ns | 2.0 ns |
| VOH | at IOH = −4 mA | 2.4 V min | 2.4 V min |

### AS7C256C-15PCN

Source: Alliance Memory AS7C256C datasheet, Rev 1.0, June 2024 (32K × 8,
2.7 to 5.5 V).  AC test load 30 pF + 1 TTL.

| Read | | Write | |
|---|---:|---|---:|
| tRC read cycle | 15 min | tWC write cycle | 15 min |
| tAA address access | 15 max | tCW /CE to end of write | 12 min |
| tACE /CE access | 15 max | tAW address valid to end of write | 12 min |
| tOE /OE access | 7 max | tAS address setup to /WE low | 0 min |
| tOH output hold from address | 3 min | tWP write pulse width | 10 min |
| tCLZ /CE to low-Z | 4 min | tWR write recovery | 0 min |
| tCHZ /CE to high-Z | 7 max | tDW data valid to end of write | 8 min |
| tOLZ /OE to low-Z | 0 min | tDH data hold | 0 min |
| tOHZ /OE to high-Z | 7 max | tWHZ /WE low to high-Z | 8 max |
| | | tOW output active from end of write | 4 min |

All times in ns.  Inputs: VIH 2.4 V min at 5 V.  Outputs: VOH 2.4 V min at
−4 mA.  Data retention: VDR 2.0 V min with /CE ≥ VCC − 0.2 V, 2 mA max at
2.0 V, tCDR 0 ns, recovery tR = tRC.

### 74F glue logic

TI datasheets, VCC = 4.5 to 5.5 V, CL = 50 pF, RL = 500 Ω, 0 to 70 °C.

| Part | Parameter | Min | Max |
|---|---|---:|---:|
| SN74F377A (SDFS018D) | CLK to Q | 4 | 10.5 |
| | setup: data / CE low / CE high | 2 / 4.5 / 2.5 | |
| | hold: data / CE | 1 / 0 | |
| SN74F574 (SDFS005A) | CLK to Q | 3.2 | 10 |
| | setup / hold | 2 / 2 | |
| SN74F541 (SDFS021A) | A to Y | 1.5 | 6 |
| | /OE to Y enable / disable | 2.5 / 1.5 | 9.5 / 6.5 |
| SN74F138 (SDFS051B) | A, B, C to Y | 2.7 | 9 |
| SN74F32 (SDFS044B) | A, B to Y | 2.2 | 6.6 |
| SN74F04 (SDFS037A) | A to Y | 1.0 | 6 |

For comparison, a 74HCT377 takes 38 ns from clock to output (TI SCLS067D,
4.5 V, −40 to 85 °C), almost the whole clock period, so HCT glue is not
usable at this speed.

## Setup paths, ranked

Each path starts at a rising clock edge and must arrive, including the
setup time of the capturing register, within T = 39.72 ns.  "Levels" are
PLD array passes at tPD = 7.5 ns each.

| Rank | Path | Stages (ns) | Total | Slack |
|---:|---|---|---:|---:|
| 1 | **ALU, FETCH→EXEC** (source AC or X, e.g. a shift): IR clk→Q, '138 decode of `instReg(1:0)` (since 2026-10-19 the audio PLD's /AC_SEL, 7.5 ns, and no X source), '541 enable, ALU low D1→D2→D3→COUT, ALU high D1→D2→D3→F3, AC setup | 10.5 + 9 + 9.5 + 8×7.5 + 2 | 91.0 | **−51.3** |
| 2 | **ALU, LOAD→EXEC** (source D): D clk→Q, '541, 8 ALU levels, AC setup | 10.5 + 6 + 60 + 2 | 78.5 | **−38.8** |
| 3 | **Video read, first byte of a line**: HCOUNT H_VIDEO_ACTIVE tCO, Sync VIDEO_ACTIVE, PIXEL_ENABLE (pin feedback), ADDR_SEL (pin feedback), mux, tAA, pixel buffer setup | 5.5 + 4×7.5 + 15 + 2 | 52.5 | **−12.8** |
| 4 | **X/Y-indexed read right after FETCH** (FETCH→LOAD_MEM with [0,X] or [Y,X]): IR clk→Q, State X_ENABLE, Sync ADDR_SEL_LO, mux, tAA, D setup | 10.5 + 3×7.5 + 15 + 2 | 50.0 | **−10.3** |
| 5 | **Fetch, branch check**: State PC_ENABLE tCO, ADDR_SEL, mux, tAA, Branch BRANCH_BLOCK from DB7:5, State Q1 setup | 5.5 + 7.5 + 7.5 + 15 + 7.5 + 3.5 | 46.5 | **−6.8** |
| 6 | **Upper 32K chip select**: address valid (tCO + ADDR_SEL + mux = 20.5), '04 on A15, tACE, IR setup | 20.5 + 6 + 15 + 2 | 43.5 | **−3.8** |
| 7 | **ROM /OE**: address valid, ROM/RAM select ROM_EN, '04, tOE, IR setup | 20.5 + 7.5 + 6 + 7 + 2 | 43.0 | **−3.3** |
| 8 | **Video read, other bytes**: Sync H2:H0 tCF, PIXEL_ENABLE, ADDR_SEL, mux, tAA, pixel buffer setup | 2.5 + 3×7.5 + 15 + 2 | 42.0 | **−2.3** |
| 9 | Fetch, opcode into the State PLD: PC_ENABLE tCO, ADDR_SEL, mux, tAA, State setup | 5.5 + 7.5 + 7.5 + 15 + 3.5 | 39.0 | +0.7 |
| 10 | Fetch, opcode into IR: PC_ENABLE tCO, ADDR_SEL, mux, tAA, IR setup | 5.5 + 7.5 + 7.5 + 15 + 2 | 37.5 | +2.2 |
| 11 | RAM /OE (= ROM_EN, no inverter): address, ROM_EN, tOE, IR setup | 20.5 + 7.5 + 7 + 2 | 37.0 | +2.7 |
| 12 | Branch decision, FETCH→EXEC: IR clk→Q, ALU F (PASS A), Z (pin feedback), LOAD_PC_LOW, PC setup | 10.5 + 3×7.5 + 3.5 | 36.5 | +3.2 |
| 13 | Branch target, FETCH→EXEC (source AC): IR clk→Q, audio PLD /AC_SEL (the '138 until 2026-10-19, 9 ns), '541 enable, PC setup | 10.5 + 7.5 + 9.5 + 3.5 | 31.0 | +8.7 |
| 14 | PIXEL_ENABLE to a register load enable: first byte of a line, then LOAD_AC/LOAD_INSTR, '377 CE setup | 5.5 + 3×7.5 + 4.5 | 32.5 | +7.2 |
| 15 | Branch target, LOAD→EXEC (source D): D clk→Q, '541, PC setup | 10.5 + 6 + 3.5 | 20.0 | +19.7 |
| 16 | H_TC to the V counter: Sync H2:H0 tCO, HCOUNT H_TC, VCOUNT setup | 5.5 + 7.5 + 3.5 | 16.5 | +23.2 |

Notes on the paths:

- **ALU (ranks 1, 2)**.  `ALU_SHR.pld` splits the carry into D1, D2 and D3,
  which are output pins fed back into the array because the 22V10 has no
  buried nodes.  Each one is a full tPD, and COUT of the low chip is built
  from D3, so the high chip's F3 is eight levels from the B inputs.  This is
  60 ns of PLD before the operand bus and register delays, and it is longer
  than the clock period on its own.
- **Video (ranks 3, 8)**.  PIXEL_ENABLE is decoded from VIDEO_ACTIVE, and
  ADDR_SEL from PIXEL_ENABLE.  Both are output pins, so the address-mux
  select is three PLD levels deep.  The first byte of each line is worst,
  because H_VIDEO_ACTIVE arrives from the H counter PLD (tCO) rather than
  from inside the Sync PLD.
- **Fetch (ranks 5, 9, 10)**.  The address-mux select goes through the Sync
  PLD before it reaches the mux, so the RAM sees a new address 20.5 ns after
  the edge, which leaves 19.2 ns for the 15 ns RAM and everything after it.
  The branch check adds the Branch PLD after the RAM and fails; the opcode
  into the State PLD and the IR pass with little to spare.
- **X/Y after FETCH (rank 4)**.  For FETCH→LOAD_MEM (and FETCH→EXEC
  stores), the memory field that picks X/Y comes from the instruction
  register that loaded at the same edge, so the '377 clock-to-output, the
  State PLD decode and the Sync PLD decode all sit in front of the mux.
- **Chip selects (ranks 6, 7, 11)**.  /OE and /CE paths start from the
  address too, and each inverter in front of the RAM adds its full delay.

## RAM write cycle

**Since 2026-10-18 there is no write-data buffer** (CPU.md, "One data
bus"): the source F541s drive the RAM data pins directly for the whole of
EXEC, enabled by the branch PLD's /SRC_EN and selected by I1 and the audio
PLD's /AC_SEL (about 27.5 ns after the edge for source AC after FETCH, 27 ns
after a video stall clock), so write data is valid
well before T + 2.2 − 8 = 33.9 ns.  The two data rows in the table below
are the old buffer's; the address rows still apply.

`/WE = RW | CLK` makes a write pulse during the low half of an EXEC write
cycle, and the write-data buffer is enabled by /WE (CPU.md, "RAM write
timing").  The OR gate delays both edges of /WE by its own delay d (F32:
2.2 to 6.6 ns), so /WE is low from T/2 + d to T + d.  RW (MEM_WR) is valid
10 ns after the edge (tCF + tPD) in a normal EXEC, so it does not limit the
pulse.

| Check | Requirement | Slack |
|---|---|---:|
| Write pulse width | tWP ≥ 10 ns; pulse ≈ T/2 = 19.86 ns (17.87 ns at 45 % duty) | +9.9 (+7.9) |
| Write data valid before end of write | F541 enable + tDW ≤ T/2: 9.5 + 8 = 17.5 ns vs 19.86 ns (17.87 ns at 45 % duty) | +2.4 (+0.4) |
| Write data, FETCH→EXEC store (source AC) | source bus at 29 ns (IR, '138, '541 enable), plus the F541 write buffer 6 ns = 35 ns vs T + 2.2 − 8 = 33.9 ns (no buffer since 2026-10-18: 27.5 ns, +6.4) | **−1.1** |
| Address setup to /WE low (tAS = 0), LOAD_IMM→EXEC | address at 20.5 ns vs /WE low at T/2 + 2.2 = 22.1 ns | +1.6 |
| Address setup, EXEC after a video stall cycle | address at 25.0 ns (PIXEL_ENABLE falls at 10 ns, then ADDR_SEL, mux) | **−2.9** |
| Address setup, FETCH→EXEC store to [Y,X] | address at 33.0 ns (IR, X_ENABLE, ADDR_SEL_LO, mux) | **−10.9** |
| Address valid to end of write (tAW = 12), FETCH→EXEC store | address at 33.0 ns vs T + 2.2 − 12 = 29.9 ns | **−3.1** |
| Address hold after /WE high (tWR = 0) | address changes at T + 8 ns min (PC_ENABLE tCO min 2, ADDR_SEL min 3, mux min 3); /WE rises by T + 6.6 ns | +1.4 |

What these mean on the board:

- **Data setup**: a store that goes straight from FETCH to EXEC has to
  decode the source register and turn on its F541 inside the same clock, so
  the data reaches the RAM 1.1 ns too late.
- **Address setup**: while /WE is low the RAM writes to whatever address is
  on its pins, so a late address writes the byte to the previous address
  first (the video address after a stall, or the PC after a FETCH→EXEC
  store).
- **Address hold** passes with 74F, but only because the F32 is faster than
  the PLD and mux path behind the address.  CPU.md's statement that /WE
  "returns high at the rising edge, before the state, address and data
  change" depends on that; a slower OR gate (an HCT32 is up to 30 ns) would
  write the byte into the next instruction's location.
- **Write glitch on the first byte of a line**: if PIXEL_ENABLE rises in an
  EXEC write cycle, MEM_WR is low from about 10 ns until PIXEL_ENABLE
  propagates (up to 28 ns), so /WE can pulse low briefly while the address
  mux is switching to the video address.  The cycle is repeated after the
  stall, so the intended write is redone, but a short write can land on the
  video address.
  Since the ALU change, STALL sits between PIXEL_ENABLE and MEM_WR, so this
  now happens on every video byte, not just the first (see
  [VIDEO_TIMING.md](VIDEO_TIMING.md)).
- **Bus contention at the end of a write**: the buffer turns off d + tdis
  (up to 13.1 ns) after the edge, while RW rises 5.5 to 10 ns after the edge
  and turns the RAM's outputs back on with tOLZ = 0.  The two can drive the
  RAM data pins against each other for up to about 7.6 ns per write.

## Hold and race checks

- **Register hold (pass)**.  The data bus cannot change earlier than about
  11 ns after an edge (address mux minimum 8 ns plus the RAM's tOH of 3 ns),
  and the ALU result no earlier than a '377 minimum (4 ns) plus a PLD
  minimum (3 ns), both well over the F377's 1 ns data hold.  The PLD hold
  time is 0 ns.  Clock skew between chips eats directly into this margin, so
  the clock needs a short, low-skew distribution.
- **Line-mode register (fails by 1 ns)**.  `lineCode` is clocked by
  `videoActiveR`, which rises one F574 clock-to-output (up to 10 ns) after
  the edge that ends the first-byte read.  At that same edge the address mux
  is switching back to the CPU, so the data bus can start changing about
  11 ns after the edge, but the F574 needs the data held 2 ns past its own
  clock, which is 12 ns.  Clocking `lineCode` from the system clock with
  a load enable (another F377) removes the race.

## What it would take

In rough order of time recovered:

1. **ALU**: the eight-level ripple cannot fit in one 39.7 ns clock with any
   22V10 grade (8 × 5 ns = 40 ns even for the −5, which is only made in PLCC).
   The choices are to give ADD/SUB a second EXEC clock, or to cut the ripple
   (for example a separate carry-lookahead PLD, or more product terms per
   output so fewer nodes are needed).  Removing the '138 + '541 source mux
   from the path (for example selecting the source a state earlier) helps,
   but not enough on its own.
   [ALU_TIMING.md](ALU_TIMING.md) works through the options.  The lookahead
   rewrite plus one wait clock on ADD/SUB (no added chips) is now in the
   sources, which closes ranks 1 and 2 with at least 10.9 ns to spare.
2. **Register the address-mux selects**.  Decoding PIXEL_ENABLE and the mux
   selects one clock early and registering them puts the mux select at
   tCO = 5.5 ns.  The video read (ranks 3, 8) and fetch paths become
   5.5 + 7.5 + 15 + 2 = 30 ns into a '377, with 9.7 ns to spare, and the
   write-strobe glitch and the address setup after a stall go away.  If they
   stay combinational, at least flatten them: write VIDEO_ACTIVE and
   PIXEL_ENABLE as intermediate expressions and use those, not the output
   pins, in PIXEL_ENABLE and the three ADDR_SEL equations.  That saves two
   levels (15 ns), and the flattened ADDR_SEL_LO (10 product terms) and
   ADDR_SEL_HI still fit on pins 22 and 21.
3. **Decode X_ENABLE/Y_ENABLE during FETCH** from the data bus (as the State
   PLD already does for the next state) and hold them in a register, so the
   X/Y address does not wait for the instruction register (rank 4 and the
   FETCH→EXEC store).
4. **Chip selects**: keep inverters out of the access path.  Decode A15 and
   ROM_EN into the four /OE (or /CE) signals directly in a PLD, or tie /CE
   low and steer reads with /OE only, since tOE (7 ns) leaves more room than
   tACE (15 ns).
5. **Write strobe**: the 74F parts make the normal data and hold checks pass,
   but with little margin; FETCH→EXEC stores still miss data setup, and the
   end-of-write contention remains.  Enabling
   the buffer from RW for the whole write cycle, and generating /WE in a PLD
   so its edges track the address, would make it robust.

## Other observations

- `basys_top.vhd` puts the ROM data on the bus when `romEn = '0'`, but the
  ROM/RAM select PLD drives ROM_EN high for a ROM read.  The FPGA build does
  not show this because the "ROM" and RAM models load the same file.
- The ROM SRAMs are loaded by the cartridge at power-up (ROM.md, "Loading
  the cartridge"), so no battery switch sits in their /CE path.  The clock
  gate (CLK = OSC OR HOLD, 74AC32) delays every main-board clock by the
  same amount, so it moves no path's slack; the cartridge's own timing is
  in `ATF22V10_CART.pld`.
