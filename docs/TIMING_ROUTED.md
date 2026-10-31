# Timing with the routed main board

Date: 2026-10-31

This checks the CPU's memory and control paths again with the trace
lengths of the main board as Justin routed it (his board saved 2026-10-31
6:51 PM ET), with option B in place ([FETCH_TIMING.md](FETCH_TIMING.md)).
Every number is compared with the last fully routed board in the repository
before it (commit 2e1dfa0, 2026-10-29) and with the datasheet figures
alone.  Nothing in the design is changed here.

## Summary

The new routing changed little.  One path got much better and a few got
slightly worse:

- **Better: the STALL path** (video stall and the cartridge loader into the
  State PLD's register strobes) went from **−0.8 ns to +0.4 ns**, because
  STALL_OUT from the cartridge to the State PLD is now 190 mm instead of
  370 mm.
- **Worse, by 0.1 to 0.25 ns:** every read whose data has to travel the
  data bus to the State and IR PLDs, because DATABUS0 from the RAMs and the
  cartridge to U1 got about 47 mm longer (561 to 608 mm).
- **The CLK_E rule holds:** 458 mm of track from U15 pin 9 to NT2 (rule:
  420 mm or more), then 64 mm more to the first clock load (U11), unchanged.

But this full pass of option B with trace delays turns up **three
paths that are short on the board, on both boards**, which the earlier
notes did not catch:

| Path | Datasheet | Oct 29 board | **Oct 31 board** |
|---|---:|---:|---:|
| Instruction fetch from the cartridge ROM, through /ROM_OE | +1.9 | −2.0 | **−2.2** |
| Instruction fetch from RAM, through /RAM_OE | +1.9 | −1.2 | **−1.3** |
| Immediate operand from the cartridge ROM into D, through /ROM_OE | +3.4 | +0.2 | **−0.0** |

All three have the same cause: **a memory read only starts when the clock
falls** (memory control PLD, "every memory bus cycle uses the low half of
the clock"), so the RAM or ROM has half a clock less the memory control
PLD (7.5 ns) and tOE (7 ns) to get its byte to the State and IR PLDs, which
need it 3.5 ns before the edge.  That leaves 1.9 ns for all the traces, and
the data bus takes 3.4 to 3.9 ns of it alone: DATABUS0, DATABUS1 and
DATABUS3 run from the RAMs and the cartridge connector up to the expansion
slots, along the slot row, down the left side to the D register and the
ALU, and only then to the IR and State PLDs (550 to 615 mm), while
DATABUS2 and DATABUS4 reach the same pins in 220 to 300 mm.

These paths were never checked against routed traces before: the old
WE_TIMING.md and FETCH_TIMING.md figures only had the address side (tAA),
and the "CPU read through /OE" row in FETCH_TIMING.md still used the
instruction register's old F377 setup (2 ns) instead of the IR PLD's
3.5 ns.

## All paths

Slack in ns, worst bit and chip.  "Datasheet" is the figure with no trace
delay and the option B clock lead taken as exactly 3 ns.

| Path | Datasheet | Oct 29 | Oct 31 | Change | Worst case |
|---|---:|---:|---:|---:|---|
| Fetch, address side (PC_ENABLE, mux, tAA, State/IR setup) | +8.2 | +3.0 | +2.9 | −0.1 | U31 → U1, DATABUS0 |
| Fetch after a branch (PC loads at the same edge) | +8.2 | +3.0 | +2.9 | −0.1 | same |
| **Fetch from RAM through /RAM_OE** | +1.9 | −1.2 | **−1.3** | −0.1 | U32 → U1, DATABUS0 |
| **Fetch from the ROM cartridge through /ROM_OE** (64K cart) | +1.9 | −2.0 | **−2.2** | −0.2 | cart U5 → U1, DATABUS0 |
| Operand from RAM into D (LOAD_IMM) | +3.4 | +1.0 | +0.9 | −0.1 | U32 → U18, DATABUS0 |
| **Operand from the ROM cartridge into D** | +3.4 | +0.2 | **−0.0** | −0.2 | cart U5 → U18, DATABUS0 |
| X/Y-indexed read after FETCH into D | +3.4 | +1.0 | +0.9 | −0.1 | U32 → U18 |
| Zero-page read `[0,D]` after LOAD_IMM into D | +3.4 | +0.2 | +0.1 | −0.1 | D5, then DATABUS0 |
| Video read into the pixel buffer | +3.4 | +2.6 | +2.9 | +0.2 | U32 → U22, DATABUS6 |
| Single-clock ALU op, source AC after FETCH | +7.7 | +2.1 | +2.5 | +0.4 | DATABUS4 |
| Zero-page store start: address before /WE falls | +1.9 | +0.3 | +0.3 | 0 | D register, D5 |
| Zero-page store start: /CE_HI before /WE falls | +6.9 | +6.4 | +6.4 | 0 | |
| Store after a video stall: address before /WE falls | +6.9 | +3.2 | +3.3 | +0.1 | |
| RW settled before /WE can fall | +3.9 | +1.0 | +1.0 | 0 | |
| End of write: address hold after /WE | +0.5 | +0.7 | +0.7 | 0 | U32, store then FETCH |
| End of write: data hold (source F541s off after /WE) | +2.0 | +5.0 | +5.0 | 0 | |
| Write data setup (tDW 8) | +9.2 | +3.2 | +3.4 | +0.2 | U31, DATABUS0 |
| STALL to the State PLD strobes and an F377 /E | +7.2 | −0.8 | **+0.4** | **+1.2** | /LOAD_IMM to U18 |
| STALL to the PC PLDs | +15.7 | +9.1 | +10.2 | +1.2 | U4 |

Two datasheet figures in the earlier notes were also off, and are
corrected here:

- **Zero-page store start**, +6.9 in FETCH_TIMING.md: that counted only
  the mux selects.  The D register loads at the same edge (it is the
  store's address), and F377 10.5 + mux 7.5 = 18 ns against /WE falling at
  T/2 − L + 3 = 19.9 ns is **+1.9**; with the traces it is +0.3 (D5 runs
  341 mm from U18 to U9).  It is still positive.
- **Source AC after FETCH**, 27.5 ns in CPU.md, TIMING.md and
  FETCH_TIMING.md: that used the F377 instruction register (10.5 ns).
  With the IR PLD (5.5 ns, since 2026-10-21) it is 22.5 ns, so the write
  data setup and the single-clock ALU op have 5 ns more than written.

## What would fix the three short reads

1. **Route DATABUS0, DATABUS1 and DATABUS3 to the IR and State PLDs the
   way DATABUS2 and DATABUS4 go** (about 220 to 290 mm from the RAMs and
   J8, instead of 550 to 615 mm through the slot row and the D register).
   That alone gives about +0.6 for the RAM fetch and about −0.3 for the
   ROM fetch; getting every data bus bit to U1 and U17 within about
   230 mm of J8 brings the ROM fetch to about +0.1.  No chip has to move:
   the RAMs, J8, U17 and U1 are within about 140 mm of each other in a
   straight line.  The board is Justin's.
2. **Shorten D5, D6 and D7** (U18 to the muxes U9 and U10, 262 to 341 mm;
   D0 to D4 are 119 to 206 mm).  With their ADDR traces to the RAM they
   are the limit of the zero-page store start (+0.3) and the zero-page
   read (+0.1); brought to the length of D4, both gain about 0.8 ns.
3. If routing cannot get there, the reads could start earlier: the memory
   control PLD's clock input (pin 1, it has no registers) could come from
   the early tap CLK_E instead of CLK, so /RAM_OE and /ROM_OE fall and rise
   about 3 ns earlier and every read through /OE gains about 3 ns.  That
   brings back the bus hand-over questions at both ends of a read (the
   source F541s turning off after EXEC, and the data holding until the
   destination's clock edge), so it needs its own check first.  Not
   proposed yet.

Typical parts are well clear (typical PLD delays are about half the
maximum), so a first board will likely run; these are worst-case figures,
and the trace delay used is the unloaded one, so the data bus, with about
19 loads, is somewhat slower than shown.

## Method

- Board: `kicad/placard.kicad_pcb` from Justin's PC (2026-10-31 22:51 UTC,
  6:51 PM ET), against the repository's board at commit 2e1dfa0 (the last
  one with every connection routed; the later 2026-10-30 commits left the
  expansion slot nets open while Justin rerouted them).  The 64K cartridge
  board (`kicad/cartridge_64k`) for the ROM paths; its traces are 30 to
  100 mm.
- Each length is the shortest path along the net's tracks and vias from
  the driving pin to the load pin (vias join layers where the track end
  touches the via's copper).  Velocity 6 ps/mm (FR4, outer layer,
  unloaded).
- Clocks: CLK_E reaches U15 pin 9 after 209 mm and NT2 after 667 mm; CLK
  then reaches U11 64 mm, U18 78 mm, U2 138 mm, U3 159 mm, U1 182 mm, U17
  217 mm and U15 pin 1 329 mm past NT2.  Each path is measured from the
  clock edge at X1 to the clock edge at the destination chip, so clock skew
  is included.
- Delays as in [TIMING.md](TIMING.md): ATF22V10C-7PX tPD 3.0 to 7.5, tCO
  2.0 to 5.5, tS 3.5; AS7C256C-15 tAA and tACE 15, tOE 7; F377 tCO 10.5,
  data setup 2, /E setup 4.5; F541 enable 9.5, disable 1.5 min.
- The scripts (`meas.py` for the lengths, `timing.py` for the paths) and
  their outputs are in the project files under
  `hardware/routing/timing_2026-10-31/`; rerun them after a routing change.

Key lengths (driver to load, mm, Oct 29 → Oct 31):

| Net | From → to | Oct 29 | Oct 31 |
|---|---|---:|---:|
| CLK_E | X1 → U15 pin 9 / → NT2 | 208 / 666 | 209 / 667 |
| CLK | NT2 → U15 pin 1 | 343 | 329 |
| /WE | U15 → U31, U32 | 173, 192 | 173, 192 |
| PC_ENABLE | U1 → muxes U9, U8, U10, U7 | 50 to 120 | 50 to 120 |
| PIXEL_ENABLE | U15 → muxes, U2 | 224 to 303, 284 | 224 to 304, 284 |
| STALL_IN | U2 → J8 | 193 | 194 |
| STALL_OUT | J8 → U1, U3, U4 | 370, 310, 383 | **190, 130, 203** |
| DATABUS0 | U32 → U1 / J8 → U1 | 561 / 567 | **608 / 613** |
| DATABUS1, 3 | U32 → U1 | 223, 590 | 223, 563 |
| DATABUS0, 1 | U32 → U17 | 511, 531 | 557, 570 |
| DATABUS2, 4 | U32 → U1 | 292, 277 | 290, 281 |
| D5 | U18 → U9 | 341 | 341 |
| /ROM_OE | U11 → J8 (+ 55 on the 64K cart) | 81 | 81 |
| Y4, Y5 | U21 → U9 | 234, 249 | 234, 249 |
