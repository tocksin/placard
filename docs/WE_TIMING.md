# RAM write enable timing

Date: 2026-10-27

This checks every SRAM write against the address and data around it: the
write must not start before the address has settled, and /WE must be high
again before the address or the chip select changes, or the byte lands at a
second address.  It covers the main board RAM (memory control PLD, revision
09), the cartridge loader's SRAM writes (cartridge PLD, revision 04) and the
slot-1 boot card.  Nothing in the design is changed here.

Parts: every PLD is an ATF22V10C-7PX (tPD 3.0 to 7.5 ns, tCO 2.0 to 5.5 ns,
tCF 2.5 ns max with no minimum given), the SRAMs are AS7C256C-15PCN (tAS 0,
tWR 0, tAW 12, tWP 10, tDW 8, tDH 0), 74F as in [TIMING.md](TIMING.md).
Clock 25.175 MHz, T = 39.72 ns, 50 % duty unless stated.

## Summary

| Write | Address hold after /WE (the question) | Address setup before /WE | Verdict |
|---|---:|---:|---|
| Main RAM, store then FETCH | +0.5 datasheet, **+3.3** with the board's traces | +2.4 datasheet, **−2.3** with traces (zero-page store) | end OK; start short on the routed board |
| Main RAM, store then a video read | −1.5 to +0.5 datasheet, **+0.8** with traces | +1.2 with traces (store after a video stall) | end OK on the routed board |
| Main RAM data hold | −1.0 datasheet, **+1.6** with traces, plus the floating bus | | OK |
| Cartridge SRAM, loader copy | **+79.9** | **+140** | OK, large margin |
| Slot-1 boot card | not designed yet | | must hold the address the same way |

**/WE always rises before the address changes on the board as it is
routed.**  On datasheet figures alone the end of a write is a race between
two minimum-delay PLD paths and one maximum-delay PLD path (0.5 ns to spare
after a normal store, and 1.5 ns short in the strictest reading after a
store followed by a video read), but on the routed board the clock reaches
the memory control PLD (U11) first and the address changes come from chips
the clock reaches later and travel 460 to 540 mm of trace, which adds 2.7 to
3.1 ns in /WE's favor, leaving +3.3 and +0.8 ns.

**The start of a write is the weaker end.**  The same trace lengths delay
the address of a zero-page store (`st [0,D]`, LOAD_IMM then EXEC) by about
5 ns, while /WE can fall 3 ns after the clock falls, so the write can begin
up to about 2.3 ns before the address has left the operand's address (the
PC).  The upper chip's /CE_HI is about 0.9 ns late the same way.  That is the
same failure the question is about, at the other end of the pulse: a short
write to the wrong address.

## Method

Each check compares the earliest possible time of one event with the latest
possible time of the other, at the SRAM pins, measured from the clock edge
at the oscillator X1:

- PLD and gate delays: datasheet minimum for the event that must come
  later, maximum for the one that must come first.
- Board traces: the routed length of each net in `kicad/placard.kicad_pcb`
  (main, 2026-10-27), taken as the shortest track path from the driving pin
  to each load pin.  Velocity 6 ps/mm (FR4, outer layer, unloaded).  Long
  nets with many loads are slower than that, which helps the end-of-write
  checks and hurts the start-of-write checks, so the start figures below
  are the better case.
- [TIMING.md](TIMING.md) and [TIMING_FIXES.md](TIMING_FIXES.md) leave trace
  delay and clock skew out; the "datasheet" columns here are their figures.

Trace lengths that matter:

| Net | From | To | mm | ns |
|---|---|---|---:|---:|
| CLK | X1 | U11 memory control | 61 | 0.36 |
| CLK | X1 | U1 State | 176 | 1.06 |
| CLK | X1 | U15 Sync | 337 | 2.02 |
| PC_ENABLE | U1 | U15 | 235 | 1.41 |
| ADDR_SEL / ADDR_SEL_HI | U15 | nearest mux (U9, U10) | 104 to 148 | 0.6 to 0.9 |
| ADDR_SEL / ADDR_SEL_LO | U15 | farthest mux (U7) | 245 to 248 | 1.5 |
| A[11:8] | U9 | U32 | 42 to 80 | 0.25 to 0.5 |
| A[3:0] | U7 | U31, U32 | 126 to 196 | 0.8 to 1.2 |
| /CE_HI | U12 | U32 | 41 | 0.25 |
| /WE | U11 | U32, U31 | 22, 41 | 0.13, 0.25 |
| /SRC_EN | U2 | source F541s U26, U27 | 219, 238 | 1.3, 1.4 |

## Main board RAM

    WE = !CLK & !RW & !PIXEL_ENABLE        (memory control PLD, pin 16)

/WE is low for the low half of a store's EXEC clock.  It falls one PLD pass
after the clock falls and rises one PLD pass after the clock rises: 3.0 to
7.5 ns, plus 0.36 ns of clock trace to U11 and up to 0.25 ns of /WE trace.

### End of the write: /WE high before the address changes

A store never loads a register (its destination is RAM), so D, X and Y hold
across the edge that ends it.  Only the address mux selects change there.

**Store, then FETCH.**  PC_ENABLE (State PLD pin 15, registered) rises,
the Sync PLD switches ADDR_SEL, and the mux switches to the PC.

| | Datasheet | With traces |
|---|---:|---:|
| /WE high at the RAM, latest | T + 7.5 | T + 0.36 + 7.5 + 0.25 = T + 8.1 |
| Address changes at the RAM, earliest: CLK to U1, tCO 2.0, PC_ENABLE trace, Sync 3.0, ADDR_SEL trace, mux 3.0, address trace | T + 8.0 | T + 1.06 + 2.0 + 1.41 + 3.0 + 0.62 + 3.0 + 0.25 = T + 11.4 |
| Slack | **+0.5** | **+3.3** |

**Store, then a video read.**  PIXEL_ENABLE (Sync PLD pin 19, registered)
rises at the same edge, and inside the Sync PLD it reaches ADDR_SEL through
the register feedback, whose minimum the datasheet does not give.  Taking
clock to ADDR_SEL as one tPD (3.0 ns) is the strictest reading; taking it
as tCO plus tPD (5.0 ns) is the reading TIMING.md used for PC_ENABLE.

| | Datasheet | With traces |
|---|---:|---:|
| /WE high at the RAM, latest | T + 7.5 | T + 8.1 |
| Address changes at the RAM, earliest: CLK to U15, clock to ADDR_SEL 3.0 to 5.0, ADDR_SEL trace, mux 3.0, address trace | T + 6.0 to T + 8.0 | T + 2.02 + 3.0 + 0.62 + 3.0 + 0.25 = T + 8.9 |
| Slack | **−1.5 to +0.5** | **+0.8** (+2.8 at 5.0 ns) |

This happens on about one store in eight during active video, and on the
mode byte and audio reads in blanking.  The chip selects change no earlier
than the address: the lower chip's /CE is the mux's A15, and /CE_HI is one
more PLD pass after ADDR_SEL (I/O decode PLD).

So the end of the write holds on this board, and it holds because of the
board: U11 is near the start of the clock net and the address-changing
chips (U1, U15) are near its end.  **If the board is re-placed, keep U11
on the clock net ahead of U1 and U15**, or the end of the write goes back
to the datasheet race above.

### Start of the write: address settled before /WE falls

| | Datasheet | With traces |
|---|---:|---:|
| /WE low at the RAM, earliest | T/2 + 3.0 = 22.9 | T/2 + 0.36 + 3.0 + 0.13 = 23.4 |
| **Zero-page store after LOAD_IMM** (`st [0,D]`): PC_ENABLE falls, Sync, mux to D; latest bit A3:A0 through U7 | 5.5 + 7.5 + 7.5 = 20.5 | 1.06 + 5.5 + 1.41 + 7.5 + 1.49 + 7.5 + 1.18 = 25.6 |
| Slack | +2.4 | **−2.3** |
| Same, /CE_HI (PC in the upper 32K, store to the zero page): selects, I/O decode | 5.5 + 7.5 + 7.5 = 20.5 | 1.06 + 5.5 + 1.41 + 7.5 + 1.04 + 7.5 + 0.25 = 24.3 |
| Slack | +2.4 | **−0.9** |
| Store after a video stall in EXEC: PIXEL_ENABLE falls, Sync, mux | 2.5 + 7.5 + 7.5 = 17.5 | 2.02 + 2.5 + 7.5 + 1.49 + 7.5 + 1.18 = 22.2 |
| Slack | +5.4 | +1.2 |
| Store to [0,X] or [Y,X] (through LOAD_MEM: the address is already there) | a clock | a clock |

The D register path (F377 tCO 10.5, mux 7.5, traces) settles by about
20.2 ns and is not the limit; the mux select is.

At a 47 % high half (the lower end of the duty TIMING_FIXES.md allows) the
clock falls 1.2 ns sooner and the zero-page store is −3.5 ns.

What it does: for the first 2 to 3 ns of the pulse the RAM can see the
LOAD_IMM address (the store's own operand byte, at the PC) or a mix of the
two addresses, and write the store's data there.  Code running from RAM
(DOS programs) has its operand bytes in RAM, so a hit would overwrite the
instruction.  Typical parts are well clear (with typical PLD delays the
address settles about 5 ns before /WE falls); this is a worst-case figure.

### Data hold and data setup

- **Data hold** (tDH 0): the source F541s let go of the bus at the earliest
  T + 1.06 + 2.0 (State tCO) + 3.0 (Branch /SRC_EN) + 1.3 (trace) + 1.5
  (F541 disable) + 0.8 (data trace to the RAM) = T + 9.7, against /WE high
  by T + 8.1: **+1.6**.  After that the bus floats and keeps its level (10k
  pull-ups, bus capacitance), and nothing drives it until the clock falls.
  Datasheet alone it is −1.0, covered by the floating bus (CPU.md, "End of
  a write").
- **Data setup** (tDW 8): the store data is on the bus by about 22.5 ns (27
  ns after a video stall), against T + 3.0 − 8 = 34.7: +7.7 or more.
- **Write pulse** (tWP 10): the low half less the spread of the two /WE
  edges, 19.86 − 4.5 = 15.4 (13.4 at 45 % low): +3.4 or more.
- **tAW** (12): for the worst store above, address 25.6 against /WE high at
  T + 3.0 = 42.7: +5.1.

## Cartridge SRAM (loader)

The cartridge PLD writes its SRAMs only while it loads them, one address per
8-clock group, with the CPU held at the PC by STALL_OUT:

    SR_WE.D = COPY & K3        (registered: /SR_WE low for all of K4)

The address is the PC through the main board's address mux.  It is valid by
K0 + 20.5 ns and cannot change before the end of K6 (the release clock),
because the State PLD and both PC PLDs are stalled, PC_ENABLE stays high
and PIXEL_ENABLE stays low: the video reads are locked to clock K7 (the
group counter restarts after each video read, and every video read,
including the blanking reads, is on H2:H0 = 111).

| Check | Times | Slack |
|---|---|---:|
| Address setup to /SR_WE low | K0 + 20.5 vs K4 + 2.0 | +140 |
| **Address hold after /SR_WE high** | /SR_WE high by K5 + 5.5; address changes no earlier than K7 + 5.0 (PC tCO 2.0, mux 3.0) | **+79.9** |
| tAW 12 | K0 + 20.5 to K5 + 2.0 | +180 |
| tWP 10 | one clock less 3.5 of tCO spread | +26 |
| tDW 8 | EEPROM byte valid by K0 + 178 vs K5 + 2.0 | +14.6 |
| tDH 0 | /EE_OE rises at the same edge as /SR_WE (both tCO 2.0 to 5.5); the bus floats and holds the byte, nothing drives it until K7's video read | held by the bus |

The main board's /WE is released while RUN is low (memory control PLD
revision 09), and the cartridge SRAMs' /WE is only /SR_WE, so the CPU never
writes them.  The loader passes with large margins.

## Slot-1 boot card

Not designed yet (held).  EXPANSION.md, "Booting from slot 1", has it load
the main RAM the way the cartridge loads its SRAM.  It should copy the
cartridge's pattern: /WE low only for a clock inside the stalled window
(K1 to K5), a registered /WE, and never in the clock before the release.
Then it has the same tens of nanoseconds of margin.

## Proposed fix (not applied)

The end of the write needs nothing, as long as U11 stays early on the clock
net.  For the start of a zero-page store, in the order I would try them:

1. **Shorten the select path in the layout.**  The address of a zero-page
   store waits on PC_ENABLE (U1, bottom of the board) crossing to the Sync
   PLD (U15, top right, 235 mm) and ADDR_SEL coming back to the mux row
   (up to 248 mm).  Placing U1, U15 and the muxes U7-U10 together, with the
   RAMs beside the muxes, takes about 2.5 to 3 ns off this path.  No chips
   and no logic change, and the same path is the instruction fetch (see
   below), so it helps there too.  Keep U11 at the start of the clock net
   while doing it.  The board file is Justin's.
2. **A wait clock for `st [0,D]`.**  Go LOAD_IMM, then one clock with the
   address on D and no write and no load, then EXEC, the way stores to
   [0,X] and [Y,X] already go through LOAD_MEM (State PLD; LOAD_MEM itself
   can't be reused because it loads D).  The address is then a whole clock
   old when /WE falls.  Costs one clock per zero-page store and a State PLD
   revision, and changes cycle counts in the simulators.

## Related: trace delay on the fetch path

The instruction fetch uses the same PC_ENABLE, Sync, mux path, then the
RAM's tAA and the data bus back to the State PLD.  TIMING.md gives it +0.7
ns without traces.  With this board's traces it is about 1.06 + 5.5 + 1.41
+ 7.5 + 1.49 + 7.5 + 1.18 + 15 + 0.7 + 3.5 = 44.8 ns, against the next edge
at U1 (T + 1.06 = 40.8): about **−4 ns**.  A full pass of TIMING.md with
the routed trace lengths is worth doing before the board is ordered.
