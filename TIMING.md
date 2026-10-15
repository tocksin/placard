# Timing analysis at 25.175 MHz

Date: 2026-10-15

This is a static, worst-case timing analysis of the Placard as it sits in
`src/hdl/basys_top.vhd` and the PLD sources in `src/pld`, for a real board
built from ATF22V10C PLDs, AS7C256C-15PCN SRAMs and 74-series glue logic,
clocked at the VGA pixel clock of 25.175 MHz.

## Summary

**The design does not meet timing at 25.175 MHz.**  The clock period is
39.72 ns.  Even with the fastest through-hole parts (ATF22V10C-7 and 74ACT
glue logic), 10 of the 16 register-to-register paths checked are too long,
and the RAM write cycle fails its data setup, address setup and address hold
checks.

| Rank | Path | 74ACT glue | 74HCT glue |
|---:|---|---:|---:|
| 1 | ALU carry chain (8 PLD levels, 60 ns of PLD alone) | 99.2 ns | 194.0 ns |
| 2 | Video read, first byte of each line | 56.0 ns | 65.5 ns |
| 3 | X/Y-indexed RAM read right after FETCH | 54.0 ns | 90.5 ns |
| 4 | Upper 32K RAM chip select (A15 through an inverter) | 50.0 ns | 75.5 ns |
| 5 | ROM /OE (ROM_EN through an inverter) | 49.5 ns | 75.0 ns |
| 6 | Instruction fetch through the RAM into the branch check | 46.5 ns | 46.5 ns |

As expected, the RAM sits in most of the failing paths (ranks 2 to 6), but the
worst path is the ALU, which does not touch the RAM.  The two 4-bit ALU PLDs
ripple the carry through eight array passes, which is 60 ns before any
register or bus delay is added, so a single-clock EXEC cannot work at
25.175 MHz with this ALU.

With 74ACT glue, the slowest path limits the clock to about 10 MHz.  If the
ALU were given two clocks, the next limit is about 18 MHz.  74HCT glue is
not usable at this speed: a 74HCT377's clock-to-output alone is 38 ns.

Section [What it would take](#what-it-would-take) lists the changes that
recover the most time.

## Assumptions

- **Clock**: 25.175 MHz, period T = 39.72 ns, 50 % duty (high and low phases
  19.86 ns each).  A 45/55 % oscillator shortens one phase to 17.87 ns, which
  matters only for the RAM write pulse.
- **Worst case**: datasheet maximum delays and minimum setup/hold times,
  commercial temperature for the PLD and RAM (0 to 70 °C) and −40 to 85 °C for
  the logic (the only maximum column the logic datasheets give).  Typical
  parts are faster, but a design that only works with typical parts will
  fail on some boards.
- **Not included**: clock skew between chips, board trace delay, and extra
  load capacitance on the data and address buses.  The RAM is specified into
  30 pF and the PLD into its standard test load, while the data bus here
  feeds about ten inputs.  All of these make the real numbers worse, so the
  margins below are upper bounds.
- **PLD speed grade**: no grade is named in the design, so this assumes the
  fastest grade still made in 24-pin DIP, **ATF22V10C-7PX** (active at
  Microchip).  The ATF22V10C-15PU, the other DIP grade, doubles every PLD
  delay (tPD 15 ns) and makes every path here worse.
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

## Chips inferred from the top level

The PLDs are named in the VHDL.  The rest of the board is inferred from
`basys_top.vhd`; the chip choices below are the simplest match, and other
choices change the glue delays but not the conclusions.

| Function in `basys_top.vhd` | Inferred part | Qty |
|---|---|---:|
| State, branch, PC low/high, ALU low/high, ROM/RAM select, H/V counters, sync, colour decoder | ATF22V10C-7PX | 11 |
| Address mux (`full_mux` = 2 × `quad_4to1_mux` per byte) | ATF22V10C-7PX | 4 |
| `instReg`, `dReg`, `acReg`, `xReg`, `yReg`, `pixelBuffer` (D flip-flops with a load enable) | 74x377 | 6 |
| `lineCode` (clocked by `videoActiveR`), `videoActiveR` + `pixelSel` delay | 74x574 | 2 |
| Source bus (`srcBus` = D, AC or X, selected by `instReg(1:0)`) | 3 × 74x541 + 74x139 decoder | 4 |
| RAM write-data buffer (source bus onto the RAM data pins, enabled by /WE, see CPU.md) | 74x541 | 1 |
| `/WE = RW or CLK` | 74x32 | 1 |
| ROM /OE from ROM_EN, /CE of the upper 32K chip from A15 | 74x04 | 1 |
| 64 KB RAM | AS7C256C-15PCN (32K × 8) | 2 |
| 64 KB ROM, interim | AS7C256C-15PCN, battery backed | 2 |

The AS7C256C is 32K × 8, so each 64 KB space takes two chips and A15 picks
one of them.  That adds a chip-select path that does not exist in the FPGA
model (rank 4).

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
−4 mA (TTL levels, so anything the RAM drives needs TTL-level inputs, such as
HCT or ACT, which the PLDs already have).  Data retention: VDR 2.0 V min with
/CE ≥ VCC − 0.2 V, 2 mA max at 2.0 V, tCDR 0 ns, recovery tR = tRC.

### Glue logic

VCC = 4.5 V (HCT) or 5 V ± 0.5 V (ACT), CL = 50 pF, maximum over −40 to
85 °C.  HCT is the usual through-hole choice; ACT is the fastest family still
made in DIP for these functions.

| Part | Parameter | 74HCT | 74ACT |
|---|---|---:|---:|
| '377 | CLK to Q | 38 | 11 |
| '377 | data or enable setup | 15 | 5.5 |
| '377 | data hold / enable hold | 3 / 5 | 1 / 1 |
| '541 | A to Y | 29 | 7.5 |
| '541 | /OE to Y enable / disable | 38 / 38 | 12.2 / 12.2 |
| '139 | A/B to Y | 43 | 10.5 |
| '32 | A/B to Y | 30 (min not given) | 10 (min 1) |
| '04 | A to Y | 25 | 9 (min 1) |
| '574 | CLK to Q / setup / hold | 45 / 25 / 5 | not used in a critical path |

FEATURE_PLAN.md prefers 74F where it is in stock.  74F is in the same speed
range as 74ACT (for example the SN74F574, SDFS005A: 10 ns clock to Q, 2 ns
setup, 12.5 ns output enable, 0 to 70 °C), so the ACT column is a fair stand-in
for an F build.  A DIP 74F377 was not checked.

Sources: TI SN74HCT377 (SCLS067D), SN74HCT541 (SCLS306E), SN74HCT139
(SCLS066E), SN74HCT32 (SCLS064G), SN74HCT04 (SCLS042F), SN74HCT574
(SCLS177H); onsemi MC74AC377/MC74ACT377 (Rev. 11, Feb 2024; DIP part
74ACT377PC), TI CD74ACT541 (SCHS285B), CD74ACT139 (SCHS337), SN74ACT32
(SCAS530E), SN74ACT04 (SCAS518F).

## Setup paths, ranked

Each path starts at a rising clock edge and must arrive, including the
setup time of the capturing register, within T = 39.72 ns.  "Levels" are
PLD array passes at tPD = 7.5 ns each.

| Rank | Path | Stages (ns, ACT) | ACT total | ACT slack | HCT total | HCT slack |
|---:|---|---|---:|---:|---:|---:|
| 1 | **ALU, FETCH→EXEC** (source AC or X, e.g. a shift): IR clk→Q, '139 decode of `instReg(1:0)`, '541 enable, ALU low D1→D2→D3→COUT, ALU high D1→D2→D3→F3, AC setup | 11 + 10.5 + 12.2 + 8×7.5 + 5.5 | 99.2 | **−59.5** | 194.0 | −154.3 |
| 2 | **ALU, LOAD→EXEC** (source D): D clk→Q, '541, 8 ALU levels, AC setup | 11 + 7.5 + 60 + 5.5 | 84.0 | **−44.3** | 142.0 | −102.3 |
| 3 | **Video read, first byte of a line**: HCOUNT H_VIDEO_ACTIVE tCO, Sync VIDEO_ACTIVE, PIXEL_ENABLE (pin feedback), ADDR_SEL (pin feedback), mux, tAA, pixel buffer setup | 5.5 + 4×7.5 + 15 + 5.5 | 56.0 | **−16.3** | 65.5 | −25.8 |
| 4 | **X/Y-indexed read right after FETCH** (FETCH→LOAD_MEM with [0,X] or [Y,X]): IR clk→Q, State X_ENABLE, Sync ADDR_SEL_LO, mux, tAA, D setup | 11 + 3×7.5 + 15 + 5.5 | 54.0 | **−14.3** | 90.5 | −50.8 |
| 5 | **Upper 32K chip select**: address valid (tCO + ADDR_SEL + mux = 20.5), '04 on A15, tACE, IR setup | 20.5 + 9 + 15 + 5.5 | 50.0 | **−10.3** | 75.5 | −35.8 |
| 6 | **ROM /OE**: address valid, ROM/RAM select ROM_EN, '04, tOE, IR setup | 20.5 + 7.5 + 9 + 7 + 5.5 | 49.5 | **−9.8** | 75.0 | −35.3 |
| 7 | **Fetch, branch check**: State PC_ENABLE tCO, ADDR_SEL, mux, tAA, Branch BRANCH_BLOCK from DB7:5, State Q1 setup | 5.5 + 7.5 + 7.5 + 15 + 7.5 + 3.5 | 46.5 | **−6.8** | 46.5 | −6.8 |
| 8 | **Video read, other bytes**: Sync H2:H0 tCF, PIXEL_ENABLE, ADDR_SEL, mux, tAA, pixel buffer setup | 2.5 + 3×7.5 + 15 + 5.5 | 45.5 | **−5.8** | 55.0 | −15.3 |
| 9 | **Fetch, opcode into IR**: PC_ENABLE tCO, ADDR_SEL, mux, tAA, IR setup | 5.5 + 7.5 + 7.5 + 15 + 5.5 | 41.0 | **−1.3** | 50.5 | −10.8 |
| 10 | **RAM /OE** (= ROM_EN, no inverter): address, ROM_EN, tOE, IR setup | 20.5 + 7.5 + 7 + 5.5 | 40.5 | **−0.8** | 50.0 | −10.3 |
| 11 | Fetch, opcode into the State PLD: PC_ENABLE tCO, ADDR_SEL, mux, tAA, State setup | 5.5 + 7.5 + 7.5 + 15 + 3.5 | 39.0 | +0.7 | 39.0 | +0.7 |
| 12 | Branch target, FETCH→EXEC (source AC): IR clk→Q, '139, '541 enable, PC setup | 11 + 10.5 + 12.2 + 3.5 | 37.2 | +2.5 | 122.5 | −82.8 |
| 13 | Branch decision, FETCH→EXEC: IR clk→Q, ALU F (PASS A), Z (pin feedback), LOAD_PC_LOW, PC setup | 11 + 3×7.5 + 3.5 | 37.0 | +2.7 | 64.0 | −24.3 |
| 14 | PIXEL_ENABLE to a register load enable: first byte of a line, then LOAD_AC/LOAD_INSTR, '377 enable setup | 5.5 + 3×7.5 + 5.5 | 33.5 | +6.2 | 43.0 | −3.3 |
| 15 | Branch target, LOAD→EXEC (source D): D clk→Q, '541, PC setup | 11 + 7.5 + 3.5 | 22.0 | +17.7 | 70.5 | −30.8 |
| 16 | H_TC to the V counter: Sync H2:H0 tCO, HCOUNT H_TC, VCOUNT setup | 5.5 + 7.5 + 3.5 | 16.5 | +23.2 | 16.5 | +23.2 |

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
- **Fetch (ranks 7, 9, 11)**.  The address-mux select goes through the Sync
  PLD before it reaches the mux, so the RAM sees a new address 20.5 ns after
  the edge, which leaves 19.2 ns for the 15 ns RAM and everything after it.
- **X/Y after FETCH (rank 4)**.  For FETCH→LOAD_MEM (and FETCH→EXEC
  stores), the memory field that picks X/Y comes from the instruction
  register that loaded at the same edge, so the '377 clock-to-output, the
  State PLD decode and the Sync PLD decode all sit in front of the mux.
- **Chip selects (ranks 5, 6, 10)**.  /OE and /CE paths start from the
  address too, and each inverter in front of the RAM adds its full delay.

## RAM write cycle

`/WE = RW | CLK` makes a write pulse during the low half of an EXEC write
cycle, and the write-data buffer is enabled by /WE (CPU.md, "RAM write
timing").  The OR gate delays both edges of /WE by its own delay d (ACT32:
1 to 10 ns; HCT32 up to 30 ns), so /WE is low from T/2 + d to T + d.  RW
(MEM_WR) is valid 10 ns after the edge (tCF + tPD) in a normal EXEC, so it
does not limit the pulse.

| Check | Requirement | ACT | HCT |
|---|---|---:|---:|
| Write pulse width | tWP ≥ 10 ns; pulse ≈ T/2 = 19.86 ns (17.87 ns at 45 % duty) | +9.9 (+7.9) | +9.9 (+7.9) |
| Write data valid before end of write | buffer enable + tDW ≤ T/2: 12.2 + 8 = 20.2 ns vs 19.86 ns | **−0.3** | **−26.1** |
| Address setup to /WE low (tAS = 0), LOAD_IMM→EXEC | address at 20.5 ns vs /WE low at T/2 + 1 ns | +0.4 | (OR min not given) |
| Address setup, EXEC after a video stall cycle | address at 25.0 ns (PIXEL_ENABLE falls at 10 ns, then ADDR_SEL, mux) | **−4.1** | **−4.1** or worse |
| Address setup, FETCH→EXEC store to [Y,X] | address at 33.5 ns (IR, X_ENABLE, ADDR_SEL_LO, mux) | **−12.6** | **−39.6** |
| Address hold after /WE high (tWR = 0) | address changes at T + 8 ns min (PC_ENABLE tCO min 2, ADDR_SEL min 3, mux min 3); /WE rises at T + d | **−2.0** | **−22.0** |

What these mean on the board:

- **Data setup**: the buffer cannot both turn on and give the RAM 8 ns of
  data inside a half clock, so written data can be wrong.
- **Address setup**: while /WE is low the RAM writes to whatever address is
  on its pins, so a late address writes the byte to the previous address
  first (the operand address of the previous cycle, the video address after
  a stall, or the PC).
- **Address hold**: at the end of an EXEC write the mux switches to the PC
  before /WE has gone high, so the byte can also land in the next
  instruction's location.  CPU.md says /WE "returns high at the rising edge,
  before the state, address and data change", but that is only true when
  the OR gate is faster than the PLD and mux path behind the address,
  which the datasheets do not guarantee.
- **Write glitch on the first byte of a line**: if PIXEL_ENABLE rises in an
  EXEC write cycle, MEM_WR is low from about 10 ns until PIXEL_ENABLE
  propagates (up to 28 ns), so /WE can pulse low briefly while the address
  mux is switching to the video address.  The cycle is repeated after the
  stall, so the intended write is redone, but a short write can land on the
  video address.
- **Bus contention at the end of a write**: the buffer turns off d + tdis
  (up to 22 ns with ACT) after the edge, while RW rises 5.5 to 10 ns after
  the edge and turns the RAM's outputs back on with tOLZ = 0.  The two drive
  the RAM data pins against each other for up to about 16 ns per write.

## Hold and race checks

- **Register hold (pass)**.  The data bus cannot change earlier than about
  11 ns after an edge (address mux minimum 8 ns plus the RAM's tOH of 3 ns),
  and the ALU result no earlier than a '377 minimum plus a PLD minimum, both
  well over the '377 hold of 1 ns (ACT) or 3 to 5 ns (HCT).  The PLD hold time
  is 0 ns.  Clock skew between chips eats directly into this margin, so the
  clock needs a short, low-skew distribution.
- **Line-mode register (marginal with ACT, fails with HCT)**.  `lineCode`
  is clocked by `videoActiveR`, which rises one '574 clock-to-output after
  the edge that ends the first-byte read.  At that same edge the address mux
  is switching back to the CPU, so the data bus can start changing about
  11 ns after the edge.  With an HCT574 (45 ns clock-to-output, 5 ns hold),
  `lineCode` samples a bus that has already changed.

## What it would take

In rough order of time recovered:

1. **ALU**: the eight-level ripple cannot fit in one 39.7 ns clock with any
   22V10 grade (8 × 5 ns = 40 ns even for the −5, which is only made in PLCC).
   The choices are to give ADD/SUB a second EXEC clock, or to cut the ripple
   (for example a separate carry-lookahead PLD, or more product terms per
   output so fewer nodes are needed).  Removing the '139 + '541 source mux
   from the path (for example selecting the source a state earlier) helps,
   but not enough on its own.
2. **Use 74ACT (or AC) glue, not HCT**.  A 74HCT377 takes 38 ns from clock to
   output, almost the whole period.  The 74ACT377, 74ACT541, 74ACT139,
   74ACT32 and 74ACT04 are all available in DIP and are three to four times
   faster.
3. **Register the address-mux selects**.  Decoding PIXEL_ENABLE and the mux
   selects one clock early and registering them puts the mux select at
   tCO = 5.5 ns.  The video read (ranks 3, 8) and fetch-to-IR (rank 9) paths
   become 5.5 + 7.5 + 15 + 5.5 = 33.5 ns, with 6.2 ns to spare, and the
   write-strobe glitch goes away.  If they stay combinational, at least
   flatten them: write VIDEO_ACTIVE and PIXEL_ENABLE as intermediate
   expressions and use those, not the output pins, in PIXEL_ENABLE and the
   three ADDR_SEL equations.  That saves two levels (15 ns), and the
   flattened ADDR_SEL_LO (10 product terms) and ADDR_SEL_HI still fit on
   pins 22 and 21.
4. **Decode X_ENABLE/Y_ENABLE during FETCH** from the data bus (as the State
   PLD already does for the next state) and hold them in a register, so the
   X/Y address does not wait for the instruction register (rank 4).
5. **Rework the RAM write strobe and data buffer**.  The data buffer needs
   to be on before /WE goes low, and /WE needs to end before the address
   can change.  This needs a design choice (for example enabling the buffer
   from RW for the whole write cycle and generating /WE inside a PLD so its
   edges track the address), which is worth its own task.
6. **Chip selects**: keep inverters out of the access path.  Decode A15 and
   ROM_EN into the four /OE (or /CE) signals directly in a PLD, or tie /CE
   low and steer reads with /OE only, since tOE (7 ns) leaves more room than
   tACE (15 ns).

## Other observations

- `basys_top.vhd` puts the ROM data on the bus when `romEn = '0'`, but the
  ROM/RAM select PLD drives ROM_EN high for a ROM read.  The FPGA build does
  not show this because the "ROM" and RAM models load the same file.
- The interim ROM (battery-backed AS7C256C) needs its /CE held at or above
  VCC − 0.2 V while VCC falls to the 2.0 V retention level.  A power-fail
  switch in the /CE line adds its delay to the /CE access path, so tie that
  switch's output to /CE and select the chip with /OE (see item 6).  Because
  the ROM/RAM select PLD never writes the ROM, loading it needs a separate
  write path or an external programmer.
