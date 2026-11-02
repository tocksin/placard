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
| Start of write, zero-page store: address before /WE can fall | +1.9 | **−1.5** |
| Start of write, zero-page store: /CE_HI before /WE can fall | +6.9 | +6.4 |
| Start of write after a video stall: video address gone | +6.9 | +3.0 |
| RW settled before /WE can fall | +3.9 | +1.3 |
| Write data setup (tDW 8) | +9.2 | +2.6 |
| Write pulse (tWP 10) | +5.4 | |
| Cartridge SRAM, loader: address hold / setup | +79.9 / +148 | |

The one short check is the start of a zero-page store on the routed
board (below).

## Main board RAM

    /WE = !CLK_E & !RW & !PIXEL_ENABLE,  OE = RUN      (Sync PLD U15, pin 20)

/WE is low for the low half of a store's EXEC clock, on a clock the CPU
owns the bus.  CLK_E is the early clock tap: X1 drives the Sync PLD's
pin 9 first, then at least 420 mm of track (500 mm nominal, about 3 ns,
L below) to the net tie NT2, and only then the CLK input of every other
chip.  So /WE falls and rises L before everything the normal clock moves.
The board has 459 mm, L = 2.8 ns.

/WE is released while RUN is low (10k pull-up), so a boot card in slot 1
can drive it ([EXPANSION.md](../architecture/EXPANSION.md)).  The I/O
write strobes (/MAP_WR, /PORT_WR) are /WE through the I/O decode PLD, so
they follow it.

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

The lead can be anything from 2.5 to about 7.9 ns: below 2.5 the hold
fails, and above 7.9 /WE could fall before the address and /CE_HI have
settled.

**Data hold** (tDH 0): the source F541s let go of the bus no earlier than
/SRC_EN (State tCO 2 + Branch 3) plus the F541's 1.5 ns disable, 6.5 ns
after the edge, against /WE high by 4.5: +2.0 (+4.8 on the board).  After
that the bus floats and keeps its level until the clock falls.

### Start of the write

/WE can fall at T/2 − L + 3 = 19.9 ns (datasheet, L = 3).

| Write | Address settled | Datasheet | Board |
|---|---|---:|---:|
| Zero-page store after LOAD_IMM (`st [0,D]`): the D register loads the address at the same edge | F377 10.5 + mux 7.5 = 18.0 | +1.9 | **−1.5** |
| Same, /CE_HI (PC in the upper 32K, store to the zero page) | selects 5.5 + I/O decode 7.5 = 13.0 | +6.9 | +6.4 |
| Store after a video stall clock in EXEC | PIXEL_ENABLE 5.5 + mux 7.5 = 13.0 | +6.9 | +3.0 |
| Store to `[0,X]` or `[Y,X]` (through LOAD_MEM: the address is already there) | a clock earlier | | |
| RW (State PLD, after the IR) before CLK_E falls | IR 5.5 + State 7.5 = 13.0 | +3.9 | +1.3 |

On the board the zero-page store is short because the D register (U18)
gets its clock 278 mm past NT2, about 1.2 ns after the State PLD, and
D7 → U10 and ADDR7 → U31 are 264 and 170 mm.  For the first 1 to 2 ns of
the pulse the RAM can see part of the previous address (the store's
operand byte, at the PC) and write the store's data there.  Code running
from RAM (DOS programs) has its operand bytes in RAM, so a hit would
overwrite the instruction.  Typical parts are well clear; this is the
worst case.  Moving U18 earlier on the clock net and shortening D5-D7 and
their ADDR tracks fixes it.

### Data setup, pulse width, tAW

- **Data setup** (tDW 8): the source bus is valid by 22.5 ns (source AC
  after FETCH: IR 5.5, /AC_SEL 7.5, F541 enable 9.5; the same through
  /SRC_EN), against /WE high at T − L + 3 − 8 = 31.7: +9.2 (+2.6 on the
  board, through the series resistors and the data bus).
- **Write pulse** (tWP 10): the low half less the spread of the two /WE
  edges, 19.86 − 4.5 = 15.4: +5.4.
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
