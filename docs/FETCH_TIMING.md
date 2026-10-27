# Instruction fetch timing: closing it without a wait clock

Date: 2026-10-27

[WE_TIMING.md](WE_TIMING.md) found that the instruction fetch, which
[TIMING.md](TIMING.md) has at +0.7 ns, is about 4 ns short once the routed
board's trace delays are counted, and about 1 ns short even with the State,
Sync, mux and RAM chips packed together.  This note looks for a fix that
adds no clock.  Nothing here is applied.

## The loop

The fetch starts and ends in the State PLD, so clock skew cannot help it:

| Stage | ns |
|---|---:|
| State PLD, PC_ENABLE (Q1) clock to output | 5.5 |
| Sync PLD, ADDR_SEL / ADDR_SEL_HI / ADDR_SEL_LO from PC_ENABLE | 7.5 |
| Address mux PLD | 7.5 |
| RAM tAA | 15.0 |
| State PLD setup (next state from the opcode) | 3.5 |
| Total | 39.0 of 39.72 |

Traces on the current board add about 4.7 ns (clock to U1 1.1, PC_ENABLE
to U15 1.4, ADDR_SEL to U7 1.5, address to the RAM 1.2 and the data bus
back, less the 1.1 the clock is late at U1 too).  The same loop is the
address of every CPU read and write, so whatever shortens it also widens
the zero-page store check in WE_TIMING.md.

Two stages are fat: the Sync PLD hop, which is only there to OR
PIXEL_ENABLE with PC_ENABLE and to fold in X_ENABLE and Y_ENABLE, and the
15 ns RAM.

## What does not work

- **A faster RAM.**  The AS7C256C is only made in 15 and 20 ns in PDIP;
  the 10 and 12 ns grades of the AS7C256A are SOJ and TSOP.  The 12 ns IDT
  71256SA12TPG (PDIP) is discontinued with no stock.  No through-hole 32K x
  8 faster than 15 ns is in production.
- **Clock skew.**  The path is register to register inside one chip.
- **Faster glue in place of the Sync hop.**  A 74F32 for the OR saves
  0.9 ns and adds a chip, and the X/Y folding still needs a gate.
- **Registering the selects in the Sync PLD.**  The select after a FETCH
  depends on the opcode on the bus, which is the very path being fixed, so
  it cannot be registered a clock early.  Every way of doing it needs the
  State PLD's next-state logic and the Sync PLD's PIXEL_ENABLE decode in
  one chip, and neither chip has a pin or a macrocell to spare.
- **Tri-stating the PC PLDs onto the address bus** (so the mux never
  carries the PC).  The mux would have to turn off for `PC_ENABLE &
  !PIXEL_ENABLE`, and a 22V10 output enable is a single product term; the
  inverse of that AND is not one.  Every way of making it one adds a PLD
  pass back in.

## Option A: ATF22V10C-5JX for the Sync PLD and the four muxes

The -5 grade (tPD 5.0, tCO 4.0, tS 3.0 ns) is made only in PLCC-28
(ATF22V10C-5JX, Mouser 102 in stock, $6.00 each on 2026-10-27, 15-week
lead time for more), and goes on the board in a through-hole PLCC socket.
No logic changes.

| | Datasheet | Current board | Packed placement |
|---|---:|---:|---:|
| Fetch, Sync and muxes -5: 5.5 + 5 + 5 + 15 + 3.5 = 34.0 | **+5.7** | +1.0 | +3.5 |
| Fetch, State -5 too: 4 + 5 + 5 + 15 + 3 = 32.0 | **+7.7** | +3.0 | +5.5 |
| Zero-page store, address 15.5 vs /WE low at 22.9 | +7.4 | +2.8 | +5 |
| Address hold after /WE (minimum delays are the same for every grade) | +0.5 | +3.3 | +2.5 |

Cost: five (or six) PLCC parts at $6 instead of $2.50 PDIP, plus sockets,
about +$20 per board, and a second PLD part number for programming and
kitting.  Pin-outs are the same, so only the footprints change.

## Option B: give the muxes PIXEL_ENABLE and PC_ENABLE directly

Worked out in full on 2026-10-27 after Justin ruled out PLCC parts.  Every
PLD stays an ATF22V10C-7PX and the chip count does not change.  (The
first draft of this section had A15 in the Sync PLD and a -5 memory
control PLD; both are gone.)

### The muxes

Drop the Sync hop.  Each mux PLD takes PIXEL_ENABLE (Sync, registered),
PC_ENABLE, X_ENABLE and Y_ENABLE (State, registered) as its selects:

    low bit:   A = PIXEL_ENABLE & VIDEO
                 # !PIXEL_ENABLE & PC_ENABLE & PC
                 # !PIXEL_ENABLE & !PC_ENABLE & X_ENABLE & XREG
                 # !PIXEL_ENABLE & !PC_ENABLE & !X_ENABLE & DREG
    high bit:  A = PIXEL_ENABLE & VIDEO
                 # !PIXEL_ENABLE & PC_ENABLE & PC
                 # !PIXEL_ENABLE & !PC_ENABLE & Y_ENABLE & YREG     (default 00h: no term)

A chip of four low bits needs 16 data + 3 selects + 4 outputs = 23 pins,
one more than a 22V10 has.  So each chip takes **two low bits and two
high bits**: 8 + 6 data, 4 selects, 4 outputs = 22 pins, and one source
file serves all four chips (bits n, n+1, n+8, n+9 for n = 0, 2, 4, 6).
Four terms per output; every output is one array pass, as now.

| Mux chip | Bits | Sources per bit |
|---|---|---|
| U7 | A1:A0, A9:A8 | D, X, video, PC / 00h, Y, video, PC |
| U8 | A3:A2, A11:A10 | |
| U9 | A5:A4, A13:A12 | |
| U10 | A7:A6, A15:A14 | |

### The other PLDs

- **Sync PLD (rev 10)**: ADDR_SEL, ADDR_SEL_HI and ADDR_SEL_LO go, and
  with them the PC_ENABLE, X_ENABLE and Y_ENABLE inputs: 6 pins and 3
  cells free.  It takes over /WE (below): inputs CLK_E, RW and RUN, output
  /WE (OE = RUN, as the memory control PLD's revision 09).  2 pins and 2
  cells stay free.
- **Memory control PLD (rev 10)**: /WE goes (pin 16 free).  Nothing else
  changes; its address inputs now arrive at 13 ns instead of 20.5.
- **I/O decode PLD (rev 05)**: /CE_HI is rebuilt from the selects as now,
  but from PIXEL_ENABLE, PC_ENABLE and Y_ENABLE (three inputs for two), so
  it settles with the mux outputs at 13 ns.  The RW input goes to pay for
  it: `RD = IO & LOAD_IMM` is the same strobe, because LOAD_IMM is only
  low in LOAD_IMM and LOAD_MEM, where RW is always 1 (MEM_WR needs EXEC).
  /WE comes from the Sync PLD.  Still 22 pins.
- **State, Branch, PC, IR**: unchanged.  PC_ENABLE now also drives the
  four muxes and the I/O decode PLD; X_ENABLE the muxes; Y_ENABLE the
  muxes and the I/O decode PLD.

### The end of the write

The Sync hop was also 3 ns of minimum delay that kept the address still
until /WE had risen.  Without it the address, both chip selects and
/CE_HI can all change 5 ns after the edge (tCO min 2 + tPD min 3), while
/WE from a -7 PLD can take 7.5 ns to rise: **−2.5 ns**.  No DIP gate is
fast enough either (a 74F32 is 6.6 ns max), and a register cannot make a
mid-clock edge.  The one thing earlier than the clock edge is the clock
before it reaches the CPU.

So /WE is made from an **early tap of the clock**: the clock net runs
from X1 to the Sync PLD's CLK_E input first, then through at least
**420 mm of track (L = 2.5 ns at 6 ps/mm; aim for 500 mm, 3 ns)** before
its first other load.  The Sync PLD makes

    /WE = !CLK_E & !RW & !PIXEL_ENABLE,  OE = RUN

on that early clock (its own registers stay on pin 1, the normal clock),
so /WE rises L earlier than everything the normal clock moves.  Only /WE
and the I/O write strobes (which follow it) move; the read enables stay in
the memory control PLD on the normal clock, so the bus hand-overs in
CPU.md are unchanged.  The lead has room both ways:

| Check (times from the normal clock edge, L = 3) | Value | Slack |
|---|---|---:|
| Address hold after /WE high: /WE high by 7.5 − L = 4.5 vs address, /CE_LO, /CE_HI change at 5 min | | **+0.5** (+1.3 with the traces, and L is a trace too) |
| Same after a store followed by a video read (PIXEL_ENABLE is a register on the normal clock) | | +0.5 |
| Address and /CE_HI settled before /WE low: 13 (about 15 with traces) vs T/2 − L + 3 = 19.9 | | +4.9 |
| RW settled before /WE can fall (the FETCH→EXEC glitch ends at IR 5.5 + State 7.5 = 13) | | +6.9 |
| Write pulse: T/2 less the spread of the two edges | 15.4 | +5.4 |
| Write data before the end of the write: source AC after FETCH 27.5 vs T − L + 3 − 8 = 31.7 | | +4.2 |
| tAW 12: address 13 vs T − L + 3 = 39.7 | | +14.7 |
| Data hold: source F541s off at T + 9.7 (traces) vs /WE high by T − L + 7.5 | | +5.2 |
| Upper limit on L: /WE must not fall before the address and /CE_HI settle | L ≤ 7.9 | |

### Timing

| Path | Was | Now | Slack |
|---|---:|---:|---:|
| Fetch: State 5.5 + mux 7.5 + tAA 15 + State setup 3.5 | 39.0 (+0.7) | 31.5 | **+8.2** (about +6.7 on the board as routed, +7.5 packed) |
| X/Y-indexed read after FETCH: X_ENABLE 5.5 + 7.5 + 15 + 2 | 37.5 | 30.0 | +9.7 |
| Video read: PIXEL_ENABLE 5.5 + 7.5 + 15 + 2 | 34.5 | 30.0 | +9.7 |
| Upper 32K read: /CE_HI 13 + tACE 15 + 2 | 37.5 | 30.0 | +9.7 |
| Zero-page store, address and /CE_HI before /WE low | +2.4 | 13 vs 19.9 | +6.9 |
| Address hold after /WE (L = 3) | +0.5 | | +0.5 |
| CPU read through /OE: max(13 + 7.5, clock fall + 7.5) + 7 + 2 | 37.0 | 37.0 | +2.7 |

The fetch, the X/Y read, the video read, the upper-chip read and the
zero-page store all come clear by 7 ns or more, enough to absorb the
board's traces without a re-placement.  The end of the write is where it
was, and now it rests on a measured track length instead of the chance
order of the clock net.

### Checks before building it

- `tb_cart_load` and the full-top GHDL run with the new Sync, memory
  control, I/O decode and mux equations (the FPGA model's `full_mux` and
  the I/O decode take the new selects).
- The clock net: X1 → U15 CLK_E, then ≥ 420 mm (500 mm nominal) of track
  before the next load; the rest of the tree as now.  The lead can be
  anything from 2.5 to about 7 ns.
- The RW drop in the I/O decode PLD: an I/O read in LOAD_MEM (a `ld d,
  [0,X]` with X in the I/O window) reads the device as it does now.

### What it costs

Mux revision 02 (new pin-out: the muxes' wiring on the board is redone),
Sync revision 10, memory control revision 10, I/O decode revision 05, the
clock tap, the FPGA model and the schematic generator.  No new parts, no
PLCC, no extra clock.

## Recommendation

Option B.  It needs no new part and takes every address path well clear;
the one rule it adds is the length of the clock track between the Sync
PLD's early tap and the rest of the board.  Option A stays here for
reference; Justin ruled out PLCC parts on 2026-10-27.
