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

Drop the Sync hop.  Each mux PLD takes PIXEL_ENABLE (Sync, registered),
PC_ENABLE (State, registered) and X_ENABLE or Y_ENABLE (State, registered)
as three selects:

    Y = PIXEL_ENABLE & VIDEO
      # !PIXEL_ENABLE & PC_ENABLE & PC
      # !PIXEL_ENABLE & !PC_ENABLE & X_ENABLE & XREG
      # !PIXEL_ENABLE & !PC_ENABLE & !X_ENABLE & DREG      (low byte)

The high byte's default source is 00h, so its fourth term is dropped and
it needs only 12 data pins.  The low byte needs 16 data + 3 selects + 4
outputs = 23 pins, one more than a 22V10 has, so the bits are re-split and
A15 moves into the Sync PLD, which gains the pins the selects free:

| Chip | Bits | Pins |
|---|---|---:|
| Mux 1 | A2:A0 (4 sources), A8 (3 sources) | 22 |
| Mux 2 | A5:A3, A9 | 22 |
| Mux 3 | A7:A6, A11:A10 | 21 |
| Mux 4 | A14:A12 | 15 |
| Sync PLD | A15 = `PIXEL_ENABLE & H9 # !PIXEL_ENABLE & PC_ENABLE & PC15 # !PIXEL_ENABLE & !PC_ENABLE & Y_ENABLE & Y7` | 22 (was 22: loses ADDR_SEL x3 and X_ENABLE, gains PC15, Y7, H9, A15) |
| I/O decode PLD | /CE_HI from A15 instead of rebuilding it from the selects | 18 (frees 4) |

Still four mux chips, but three different mux sources instead of one.

| | Datasheet | Current board | Packed placement |
|---|---:|---:|---:|
| Fetch: 5.5 + 7.5 + 15 + 3.5 = 31.5 | **+8.2** | +4.5 | +6.5 |
| X/Y read after FETCH: 5.5 + 7.5 + 15 + 2 | +9.7 | | |
| Zero-page store, address 13 vs /WE low at 22.9 | +9.9 | +6 | +8 |
| Upper 32K /CE_HI: A15 13 + 7.5 = 20.5 (unchanged) | +2.4 | | |
| **Address hold after /WE**: address can change at T + 2 + 3 = 5 vs /WE high at T + 7.5 | **−2.5** | −0.7 | −1.5 |

The last row is the catch: the Sync hop was also 3 ns of minimum delay
that kept the address still until /WE had risen.  Without it the end of
every write fails on paper.  Fixes for that row, either of which closes
it:

- **Memory control PLD as a -5 PLCC** (one part): /WE high by T + 5.0,
  against the address at T + 5.0: 0.0 datasheet, +1.8 on the current
  board (U11 gets the clock 0.7 ns before U1 and the address has 1.3 ns of
  trace).  Keep U11 at the start of the clock net.
- **Clock skew by routing**: the clock to U11 at least 2.5 ns (420 mm of
  trace) shorter than to U1 and U15.  Free but fragile, and it costs every
  path leaving U1 or U15 for another chip 2.5 ns.

With the -5 memory control PLD the end of a write before a video read is
the same figure (PIXEL_ENABLE now goes straight to the muxes, tCO min 2 +
mux 3 = 5).

Cost: three mux PLD sources instead of one, Sync revision 10, I/O decode
revision 05, memory control PLD as PLCC, a pin change on every mux (the
board's mux wiring is redone), and one -5 part.  The gain is the biggest,
and it also takes the X/Y read, the zero-page store and the fetch all well
clear.

## Recommendation

Option A for the Sync PLD and four muxes is the smallest change and gives
+5.7 ns on paper, enough with the packed placement (+3.5) and still
positive on the board as routed.  Option B is worth more (+8.2) and fixes
the store timing outright, but it rewires the muxes and needs the -5
memory control PLD to keep the end of the write safe; it is the one to do
if the board is being re-placed anyway.

Both keep every PLD except the -5 parts as the ATF22V10C-7PX.
