# RAM write enable timing

Date: 2026-11-02

Every SRAM write is checked here against the address and data around it:
the write must not start before the address has settled, and /WE must be
high again before the address or a chip select changes, or the byte lands
at a second address.  It covers the main board RAM, the cartridge
loader's SRAM writes and the slot-1 boot card.  The summary of all paths
is in [TIMING.md](TIMING.md).

Parts: every PLD is an ATF22V10C-7PX (tPD 3.0 to 7.5, tCO 2.0 to 5.5),
the SRAMs are AS7C256C-15PCN (tAS 0, tWR 0, tAW 12, tWP 10, tDW 8, tDH 0).
Clock 25.175 MHz, T = 39.72 ns, 50 % duty unless stated.

## Summary

| Check | Datasheet | Board |
|---|---:|---:|
| End of write: address hold after /WE high | +0.5 | +0.6 |
| End of write: data hold (source F541s off after /WE) | +2.0 | +4.8 |
| Start of write, zero-page store: address before /WE can fall | +4.9 | +2.6 |
| Start of write, zero-page store: /CE_HI before /WE can fall | +9.9 | +10.5 |
| Start of write after a video stall: video address gone | +9.9 | +7.1 |
| RW settled before /WE can fall | +6.9 | +5.4 |
| Write data setup (tDW 8) | +9.2 | +2.6 |
| Write pulse (tWP 10) | +2.4 | about +1.3 |
| Cartridge SRAM, loader: address hold / setup | +79.9 / +148 | |

Every check meets on the routed board.  Since Sync PLD revision 11 /WE
waits for both clocks to fall (below); before, the start of a zero-page
store was 1.5 ns short on the board.

## Main board RAM

    /WE = !CLK_E & !CLK & !RW & !PIXEL_ENABLE,  OE = RUN      (Sync PLD U15, pin 20, revision 11)

/WE is low for the low half of a store's EXEC clock, on a clock the CPU
owns the bus.  CLK_E is the early clock tap: X1 drives the Sync PLD's
pin 9 first, then at least 420 mm of track (500 mm nominal, about 3 ns,
L below) to the net tie NT2, and only then the CLK input of every other
chip.  The Sync PLD also has CLK on pin 1, which feeds its array, so /WE
falls on the later edge (CLK) and rises on the earlier one (CLK_E): it
rises L before everything the normal clock moves and falls with the
normal clock.  The board has 459 mm, L = 2.8 ns (4.1 ns from CLK_E at
U15 pin 9 to CLK at U15 pin 1).

/WE is released while RUN is low (10k pull-up), so a boot card in slot 1
can drive it ([EXPANSION.md](../architecture/EXPANSION.md)).  The I/O
write strobes follow it: /MAP_WR is made in the Sync PLD with the /WE
equation (revision 12), and the port PLD clocks on /WE itself (revision 05).

### End of the write

A store never loads a register (its destination is RAM), so D, X and Y
hold across the edge that ends it.  Only the selects change there:
PC_ENABLE (store then FETCH) or PIXEL_ENABLE (store then a video read),
both registered.

| | ns from the CPU's clock edge |
|---|---:|
| /WE high at the RAM, latest: 7.5 − L | 4.5 |
| Address, /CE_LO, /CE_HI change, earliest: tCO 2 + mux or I/O decode 3 | 5.0 |
| Slack | **+0.5** (+0.6 on the board) |

The lead can be anything from 2.5 to about 5.3 ns at a 50 % clock: below
2.5 the hold fails, and above 5.3 the write pulse is shorter than tWP
(below).  Since /WE falls on CLK, the lead no longer moves its start.

**Data hold** (tDH 0): the source F541s let go of the bus no earlier than
/SRC_EN (State tCO 2 + Branch 3) plus the F541's 1.5 ns disable, 6.5 ns
after the edge, against /WE high by 4.5: +2.0 (+4.8 on the board).  After
that the bus floats and keeps its level until the clock falls.

### Start of the write

/WE can fall at T/2 + 3 = 22.9 ns (datasheet: CLK falls, then the PLD's
minimum tPD).  Before revision 11 it could fall at T/2 − L + 3 = 19.9.

| Write | Address settled | Datasheet | Board |
|---|---|---:|---:|
| Zero-page store after LOAD_IMM (`st [0,D]`): the D register loads the address at the same edge | F377 10.5 + mux 7.5 = 18.0 | +4.9 | +2.6 |
| Same, /CE_HI (PC in the upper 32K, store to the zero page) | selects 5.5 + I/O decode 7.5 = 13.0 | +9.9 | +10.5 |
| Store after a video stall clock in EXEC | PIXEL_ENABLE 5.5 + mux 7.5 = 13.0 | +9.9 | +7.1 |
| Store to `[0,X]` or `[Y,X]` (through LOAD_MEM: the address is already there) | a clock earlier | | |
| RW (State PLD, after the IR) before CLK falls | IR 5.5 + State 7.5 = 13.0 | +6.9 | +5.4 |

The zero-page store is the tightest because the D register (U18) gets
its clock 278 mm past NT2, about 1.2 ns after the State PLD, and D7 → U10
and ADDR7 → U31 are 264 and 170 mm.  If /WE fell before that address
settled, the RAM could write the store's data at part of the previous
address (the store's operand byte, at the PC), which in code running
from RAM is the instruction itself.  With /WE falling on CLK
(revision 11) it has 2.6 ns on the board; before, on CLK_E, it was
1.5 ns short.

### Data setup, pulse width, tAW

- **Data setup** (tDW 8): the source bus is valid by 22.5 ns (source AC
  after FETCH: IR 5.5, /AC_SEL 7.5, F541 enable 9.5; the same through
  /SRC_EN), against /WE high at T − L + 3 − 8 = 31.7: +9.2 (+2.6 on the
  board, through the series resistors and the data bus).
- **Write pulse** (tWP 10): the low half less the lead (/WE falls on CLK,
  rises on CLK_E) less the spread of the two /WE edges, 19.86 − 3 − 4.5 =
  12.4: +2.4 (about +1.3 on the board, with its 4.1 ns lead).  This now
  sets the top of the clock duty window (TIMING.md, "Clock duty").
- **tAW** (12): address by 18 ns, /WE high no earlier than T: +9.7.

## Cartridge SRAM (loader)

The cartridge PLD writes its SRAMs only while it loads them, one address
per 8-clock group, with the CPU held at the PC by STALL_OUT:

    SR_WE.D = COPY & K3        (registered: /SR_WE low for all of K4)

The address is the PC through the main board's address mux.  It is valid
by K0 + 13 ns and cannot change before the end of K6 (the release clock),
because the State PLD and both PC PLDs are stalled, PC_ENABLE stays high
and PIXEL_ENABLE stays low: the video reads are locked to clock K7.

| Check | Times | Slack |
|---|---|---:|
| Address setup to /SR_WE low | K0 + 13 vs K4 + 2.0 | +148 |
| Address hold after /SR_WE high | /SR_WE high by K5 + 5.5; address changes no earlier than K7 + 5.0 | +79.9 |
| tAW 12 | K0 + 13 to K5 + 2.0 | +176 |
| tWP 10 | one clock less 3.5 of tCO spread | +26 |
| tDW 8 | EEPROM byte valid by K0 + 178 vs K5 + 2.0 | +14.6 |
| tDH 0 | /EE_OE rises at the same edge as /SR_WE; the bus floats and holds the byte until K7's video read | held by the bus |

The main board's /WE is released while RUN is low, and the cartridge
SRAMs' /WE is only /SR_WE, so the CPU never writes them.

## Slot-1 boot card

Not designed yet ([EXPANSION.md](../architecture/EXPANSION.md),
"Booting from slot 1").  It should follow the cartridge's pattern: /WE low
only for a clock inside the stalled window (K1 to K5), a registered /WE,
and never in the clock before the release.  Then it has the same tens of
nanoseconds of margin.
