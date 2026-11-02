# Timing at 25.175 MHz

Date: 2026-11-02

This is the worst-case timing of the Placard as it is built: the PLD
sources in `src/pld`, the parts in [CHIPS.md](../architecture/CHIPS.md),
and the routed main board `kicad/placard.kicad_pcb` with the 64K
cartridge `kicad/cartridge_64k`.  Every path is given twice: from the
datasheets alone, and on the board with its trace delays and clock skew.

The documents next to this one go into single paths in more detail:
[FETCH_TIMING.md](FETCH_TIMING.md) (instruction fetch and the address
muxes), [WE_TIMING.md](WE_TIMING.md) (the RAM write strobe),
[ALU_TIMING.md](ALU_TIMING.md) (ALU, wait clock, carry),
[VIDEO_TIMING.md](VIDEO_TIMING.md) (video read and pixel pipeline) and
[XY_TIMING.md](XY_TIMING.md) (X/Y-indexed addresses).

## Summary

From the datasheets, every path meets 25.175 MHz with a 50 % clock.
Since I/O decode PLD revision 06 the I/O read right after a video stall
no longer waits for STALL ([I/O reads](#io-reads)), and since Sync PLD
revision 11 /WE falls with CLK, which closed the zero-page store start on
the board ([Memory writes](#memory-writes)).

On the routed board, the traces and clock skew take another 1 to 8 ns
from most paths, and four are short:

| Path | Datasheet | Board | Main cause on the board |
|---|---:|---:|---|
| Fetch from the cartridge ROM through /ROM_OE | +1.9 | **−1.1** | DATABUS0 J8 → U1 361 mm |
| Zero-page read `[0,D]` into D | +3.4 | **−1.1** | D register clock and DATABUS0 to U18 (528 mm) |
| Video read into the pixel buffer | +3.4 | **−1.1** | DATABUS0 U31 → U22 819 mm (the pixel buffer is at the far end of a 1042 mm daisy chain) |
| Fetch from RAM through /RAM_OE | +1.9 | **−0.2** | the read starts when the clock falls; DATABUS0 to U1/U17 |

These are worst-case figures.  Typical PLD and SRAM delays are about half
the maximum, so a first board is expected to run, but the routing is not
finished: the data bus (DATABUS0 most of all) and the D register's place
are where the time goes.  The scripts that measure the board are listed
under [Method](#method); rerun them after any routing change.

The clock's duty cycle is an open item: the design needs a high half of
about 42 % to 54.6 % from the datasheets ([Clock duty](#clock-duty)), and
the ECS-100A oscillator is only specified to 40/60 %.

## Clock and assumptions

- **Clock**: 25.175 MHz from oscillator X1, T = 39.72 ns.  The high half
  must be between about 42 % and 54.6 % of the period (below), so the
  oscillator needs a 50 % output or one divided down to it.
- **Clock tree**: X1 drives **CLK_E** to the Sync PLD's pin 9 first, then
  at least 420 mm of track (500 mm nominal, about 3 ns) to net tie NT2;
  **CLK**, on the far side of NT2, goes to every other chip, the Sync
  PLD's pin 1 included.  The Sync PLD makes /WE from both: it falls with
  CLK and rises on CLK_E, about 3 ns ahead of everything clocked by CLK
  ([WE_TIMING.md](WE_TIMING.md)).
- **Memory control PLD on CLK_E** (schematic 2026-11-02, timing fix 4; not
  yet on the routed board, whose numbers below are from before): U11
  pin 1 moves from CLK to the CLK_E tap next to X1, so /RAM_OE and /ROM_OE
  fall and rise about 3.7 ns earlier.  That gives every read through /OE
  (fetch, cartridge ROM fetch, operand, zero-page, video) its margin back
  and lets the high half reach 53 % with 0.5 ns to spare on the new
  placement (`src/scripts/router_v4/budgets.py U11E=1`).  The earlier /OE high
  leaves the bus to its capacitance and the 10k pull-ups until the
  capture edge, and shortens the memory/F541 overlap at the start of EXEC.
- **Worst case**: datasheet maximum delays and minimum setup times at 0 to
  70 °C.  Hold checks use the datasheet minimums (PLD tPD 3.0, tCO 2.0).
- **PLD pin feedback**: an equation that names another combinational
  output pin costs a second tPD; registered feedback reaches the array
  after tCF (2.5 ns).  Intermediate expressions cost nothing.
- **Board**: track delay 6 ps/mm (FR4, unloaded).  The data bus has about
  19 loads, so it is somewhat slower than that.  Each path is measured from
  the edge at X1 to the edge at the capturing chip, so clock skew is
  included.

## Parts and datasheet figures

| Part | Used for | Figures (ns) |
|---|---|---|
| ATF22V10C-7PX (PDIP-24) | all 20 main-board PLDs and the cartridge loader | tPD 3.0 to 7.5, tCO 2.0 to 5.5 (DIP), tCF 2.5, tS 3.5, tH 0, tEA 7.5 |
| AS7C256C-15PCN | main RAM U31, U32; cartridge SRAMs | tAA 15, tACE 15, tOE 7, tOHZ 7, tOLZ 0, tAS 0, tAW 12, tWP 10, tDW 8, tDH 0, tWR 0 |
| SN74F377AN | D, AC, X, Y, pixel buffer | CLK to Q 4 to 10.5, data setup 2, /E setup 4.5, hold 1 |
| SN74F541N | source drivers U26, U27; line read U29 | A to Y 1.5 to 6, enable 2.5 to 9.5, disable 1.5 to 6.5 |
| CD74ACT273E | ROM/RAM map register | CP to Q 12.3 |

Sources: Atmel ATF22V10C datasheet 0735P (tCO 5.5 is the DIP figure),
Alliance AS7C256C Rev 1.0 (June 2024), TI SN74F377A (SDFS018D) and
SN74F541 (SDFS021A).

**Logic levels**: 74F outputs guarantee 2.5 V high and the AS7C256C needs
2.4 V, so the source F541s drive the RAM with 0.1 V to spare; the series
resistors between them and the data bus carry only input leakage.  The
PLD and SRAM outputs (2.4 V) drive only TTL-level inputs.  No plain 74HC
input sits on the address or data bus.

## The routed board

Clock lengths (mm of track):

| Net | To | mm |
|---|---|---:|
| CLK_E | X1 → U15 pin 9 → NT2 | 207 → 665 (lead 459, rule ≥ 420) |
| CLK (past NT2) | U11 memory control | 52 |
| | U3, U1, U17, U2, U4 (PC low, State, IR, Branch, PC high) | 76, 99, 143, 145, 169 |
| | U22, U21, U15 pin 1, U20, U19, U18 (pixel buffer, Y, Sync, X, AC, D) | 188, 204, 227, 255, 259, 278 |

Other nets that set the limits:

| Net | From → to | mm |
|---|---|---:|
| /WE | U15 → U31, U32 | 109, 128 |
| PC_ENABLE | U1 → muxes U9, U8, U10, U7 | 55 to 101 |
| PIXEL_ENABLE | U15 → muxes U7, U8, U9, U10; → U2 | 247 to 372; 395 |
| STALL_IN / STALL_OUT | U2 → J8 / J8 → U1, U3, U4 | 210 / 186, 126, 168 |
| DATABUS0 | U31 → U1, U17, U18, U22 | 336, 348, 528, 819 |
| DATABUS0 | J8 → U1 | 361 |
| D5, D6, D7 | U18 → muxes | 229, 241, 264 |
| /RAM_OE, /ROM_OE | U11 → U31, U32 / → J8 | 55, 36 / 73 |
| /CE_HI | U12 → U32, J8 | 52, 93 |

## All paths

Slack in ns.  "Board" is the current main board with the 64K cartridge;
paths with more than about 8 ns from the datasheets were not measured on
the board.

### Memory reads

A CPU read starts when the clock falls: the memory control PLD gates
/RAM_OE and /ROM_OE with !CLK, so the memories only drive the bus in the
low half of a clock.  A read is therefore limited either by the address
(tAA from the address muxes) or by /OE (clock fall, memory control PLD,
tOE).

| Path | Stages (datasheet) | Datasheet | Board |
|---|---|---:|---:|
| Fetch, address side: PC_ENABLE tCO, mux, tAA, State/IR setup | 5.5 + 7.5 + 15 + 3.5 = 31.5 | +8.2 | +4.5 |
| Fetch after a branch (the PC loads at the same edge) | same | +8.2 | +4.1 |
| Fetch from RAM through /RAM_OE: clock fall, memory control, tOE, setup | 19.9 + 7.5 + 7 + 3.5 = 37.9 | +1.9 | **−0.2** |
| Fetch from the cartridge ROM through /ROM_OE | same | +1.9 | **−1.1** |
| Operand from RAM into D (LOAD_IMM) | 19.9 + 7.5 + 7 + 2 = 36.4 | +3.4 | +1.2 |
| Operand from the cartridge ROM into D | same | +3.4 | +0.4 |
| X/Y-indexed read after FETCH into D | same | +3.4 | +1.2 |
| Zero-page read `[0,D]` after LOAD_IMM (D register 10.5, mux 7.5, tAA 15, or /OE) | | +3.4 | **−1.1** |
| Upper 32K chip: /CE_HI (selects 5.5, I/O decode 7.5), tACE 15, setup 2 | 30.0 | +9.7 | |
| Video read into the pixel buffer: PIXEL_ENABLE tCO, mux, tAA, or /OE | | +3.4 | **−1.1** |

### Memory writes

/WE = !CLK_E & !CLK & !RW & !PIXEL_ENABLE (Sync PLD revision 11), so a
write uses the low half of a store's EXEC clock: it starts when CLK
falls and ends about 3 ns before the CPU's clock rises (on CLK_E).

| Check | Datasheet | Board |
|---|---:|---:|
| Zero-page store start: address (D register 10.5 + mux 7.5 = 18) before /WE can fall (T/2 + 3 = 22.9) | +4.9 | +2.6 |
| Zero-page store start: /CE_HI before /WE can fall (13 vs 22.9) | +9.9 | +10.5 |
| Store after a video stall: video address gone before /WE can fall | +9.9 | +7.1 |
| RW settled before CLK falls (IR 5.5 + State 7.5 = 13 vs T/2) | +6.9 | +5.4 |
| End of write: /WE high (7.5 − 3 = 4.5) before the address, /CE_LO, /CE_HI change (2 + 3 = 5) | +0.5 | +0.6 |
| End of write: data held until /WE is high (source F541s off) | +2.0 | +4.8 |
| Write data setup, tDW 8 (source bus valid by 22.5 ns) | +9.2 | +2.6 |
| Write pulse, tWP 10: low half less the CLK_E lead (3) less the spread of the two /WE edges (4.5), 12.4 | +2.4 | about +1.3 |
| tAW 12: address by 18 vs /WE high at T at the earliest (T − 12 = 27.7) | +9.7 | |

### CPU control, ALU and branches

| Path | Stages | Datasheet | Board |
|---|---|---:|---:|
| STALL to the State PLD strobes and an F377 /E: PIXEL_ENABLE tCO, Branch STALL, cartridge PLD, State, /E setup | 5.5 + 7.5 + 7.5 + 7.5 + 4.5 = 32.5 | +7.2 | +1.2 |
| STALL to the PC PLDs | 5.5 + 7.5 + 7.5 + 3.5 = 24.0 | +15.7 | +10.3 |
| Single-clock ALU op, source AC after FETCH: IR 5.5, /AC_SEL 7.5, F541 enable 9.5, ALU 7.5, AC setup 2 | 32.0 | +7.7 | +3.6 |
| Single-clock ALU op, source D: /SRC_EN (State 5.5, Branch 7.5), F541 enable 9.5, ALU 7.5, AC setup 2 | 32.0 | +7.7 | |
| ADD/SUB, two clocks (lookahead ALU, 5 levels) | 22.5 + 37.5 + 2 = 62.0 of 79.4 | +17.4 | |
| Carry flag: source bus 22.5, four ALU levels 30, Branch setup 3.5 | 56.0 of 79.4 | +23.4 | |
| Branch decision: IR 5.5, ALU F (PASS A) 7.5, Z 7.5, LOAD_PC_LOW 7.5, PC setup 3.5 | 31.5 | +8.2 | |
| Branch target (AC or D on the source bus) into the PC PLDs | 22.5 + 3.5 = 26.0 | +13.7 | |
| Opcode into X_ENABLE / Y_ENABLE (State PLD, from the data bus) | as the fetch | +8.2 | +4.5 |

### I/O reads

An I/O read strobe is `RD = IO & !PC_ENABLE & !Q0 & !PIXEL_ENABLE` (I/O
decode PLD revision 06): the LOAD_MEM state on a clock the CPU owns the
bus.  An I/O address is only read through [Y,X], always in LOAD_MEM.
All three are register outputs, so the strobe no longer waits for STALL,
and a read right after a video stall has the same timing as any other.
D still loads with the State PLD's /LOAD_IMM, which waits for STALL (the
STALL row under [CPU control](#cpu-control-alu-and-branches)).

| Path | Stages | Datasheet | Board |
|---|---|---:|---:|
| Line read (U29): address 13, /LINE_RD 7.5, F541 enable 9.5, D setup 2 | 32.0 | +7.7 | about +4 |
| Port (U38) or PS/2 (U42) read (PLD tEA 7.5 instead of the F541) | 30.0 | +9.7 | about +6 |

The board figures are estimates (U29 → U18 on DATABUS0 is 424 mm) and
not from the script.  Before revision 06, `RD = IO & LOAD_IMM` waited
for STALL through the Branch PLD and the cartridge, and a read right
after a video stall (about one I/O read in eight) was −7.3 (line read)
and −5.3 (port, PS/2) from the datasheets.

### Video and the rest

| Path | Stages | Datasheet |
|---|---|---:|
| Pixel buffer /E (Branch PLD /PIX_LD from PIXEL_ENABLE) | 5.5 + 7.5 + 4.5 = 17.5 | +22.2 |
| PIXEL_ENABLE.D: H_VIDEO_ACTIVE tCO, Sync setup | 5.5 + 3.5 = 9.0 | +30.7 |
| H_TC to the V counter | 5.5 + 7.5 + 3.5 = 16.5 | +23.2 |
| Color decoder: pixel buffer 10.5, two levels, settled into a 39.7 ns pixel | 25.5 | no register after it |
| Video address (H, V, audio PLD row bits): changes in clock 0 of a group, read in clock 1 | over a clock | |
| I/O write strobes: address 13 before /WE falls (22.9) | | +9.9 |
| ROM/RAM map write into the very next fetch: /MAP_WR high by T + 12, map CP→Q 12.3, memory control 7.5, tOE 7, setup 3.5 | 42.3 | −2.6 (software rule below) |

**Map write rule**: the instruction straight after a write to the map
register must not be fetched from a section whose map bit that write
changes, unless ROM and RAM hold the same byte there.  The shadow copy
(copy the ROM into the RAM under it, then map it to RAM) is safe, and so
is any instruction between the map write and the first fetch from the
switched section.

### Bus hand-overs

The source F541s and the memories share one data bus
([CPU.md](../architecture/CPU.md), "One data bus").

| Hand-over | Check | Slack |
|---|---|---:|
| End of EXEC: source F541s off (/SRC_EN 13 + disable 6.5 = 19.5) before a read can start (clock fall + 3) | 19.5 vs 22.9 | +3.4 (+2.2 at a 47 % high half) |
| Start of EXEC: the memory stops driving (/OE high by 7.5, tOHZ 7 = 14.5) while the F541s can turn on from about 7.5 ns | overlap up to 7 ns | limited by the series resistors |
| End of a write: data held, /WE high first | above | +2.0 |
| I/O reads: neither memory drives in 5000h-53FFh | | |

### Clock duty

- High half at most **54.6 %**: a fetch through /OE starts at the clock
  fall and has 1.9 ns from the datasheets (on the board it is already
  0.2 ns short at 50 %).  The write pulse (tWP) allows up to 55.9 %
  (about 53 % on the board).
- High half at least about **42 %**: the hand-over at the end of EXEC
  (source F541s off by 19.5 ns, a read starts at the clock fall + 3);
  below that the overlap is limited only by the 47 Ω series resistors.
  The zero-page store start allows 37.8 % (about 43 % on the board) and
  RW 32.7 %.
- A 50 % clock meets all of them.  **Open item**: the ECS-100A is
  specified only to 40/60 % symmetry (at 1.4 V), typical 50 ± 3 %.  The
  CTS MXO45 (full-size DIP-14, 5 V, pin-compatible) is specified to
  45/55 % at VDD/2.

## Cartridge loader

The cartridge PLD writes its SRAMs only while it loads them, one address
per 8-clock group, with the CPU held at the PC by STALL_OUT
([WE_TIMING.md](WE_TIMING.md#cartridge-sram-loader)):

| Check | Slack |
|---|---:|
| Address setup to /SR_WE low | +148 |
| Address hold after /SR_WE high | +79.9 |
| tAW 12 | +176 |
| tWP 10 | +26 |
| tDW 8 (EEPROM byte valid by K0 + 178 ns) | +14.6 |

## Hold and race checks

- **Register hold**: the data bus cannot change earlier than about 8 ns
  after an edge (PLD tCO 2 + mux 3 + the RAM's tOH 3), and the ALU result
  no earlier than F377 4 + PLD 3, against the F377's 1 ns data hold and
  the PLD's 0 ns.  The clock skew on the board (CLK reaches U11 after
  52 mm and U18 after 278 mm, 1.4 ns apart) is inside that margin.
- **RAM address hold after /WE**: +0.5 from the datasheets, +0.6 on the
  board; it rests on the CLK_E lead (≥ 420 mm of track).
- **Line code register** (CD74HCT377): copies the mode byte from the pixel
  buffer with /E from /MODE_LD in blanking; the pixel buffer holds the
  byte for several clocks around it.

## Method

- Board: `kicad/placard.kicad_pcb` and `kicad/cartridge_64k/cartridge_64k.kicad_pcb`
  as on `main` on 2026-11-02.
- Each length is the shortest path along the net's tracks and vias from
  the driving pin to the load pin, at 6 ps/mm.
- The scripts (`meas.py` for the lengths, `timing.py` for the paths, the
  I/O read lengths in `io.json` and `lr.json`) and their outputs are in the
  project files under `hardware/routing/timing_2026-11-02/`.  Rerun them
  after a routing change.
