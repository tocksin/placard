# Expansion slots and ROM cartridge slot

Date: 2026-10-18

The Placard has four expansion slots and one ROM cartridge slot, all the
same connector: a 2 x 20, 0.1" (2.54 mm) pitch card-edge socket.  The
expansion slots stand in a bay at one back corner, front to back at 0.8"
pitch, so a card's outer end can carry its own connector at the back edge,
like a PC card.  The cartridge slot is top loading, inboard.  Board sizes
are in `hardware/pcb_size_estimate.md` (project files).

No chips are added for the slots: they are wired straight to the buses.

## Expansion slot addresses

The I/O decode PLD has two expansion selects and no free pins, so the four
slots share them and split each 256-byte page by A7.  Each slot also has a
**SEL** pin, tied on the main board, that tells the card which half it
answers, so the same card works in any slot without a jumper.

| Slot | Select | SEL pin | Card answers when | Addresses |
|---|---|---|---|---|
| 1 | /EXP1 | GND | A7 = 0 | x5100-x517F |
| 2 | /EXP2 | GND | A7 = 0 | x5300-x537F |
| 3 | /EXP1 | +5 V | A7 = 1 | x5180-x51FF |
| 4 | /EXP2 | +5 V | A7 = 1 | x5380-x53FF |

A card has 128 addresses (A6:A0).

## Expansion slot pinout

Side A is the card's component side.  Contact 1 is at the end nearest the
back edge of the main board.

| # | Side A | Side B |
|--:|---|---|
| 1 | GND | GND |
| 2 | +5 V | +5 V |
| 3 | D0 | D1 |
| 4 | D2 | D3 |
| 5 | D4 | D5 |
| 6 | D6 | D7 |
| 7 | GND | GND |
| 8 | SD0 | SD1 |
| 9 | SD2 | SD3 |
| 10 | SD4 | SD5 |
| 11 | SD6 | SD7 |
| 12 | GND | CLK |
| 13 | A0 | A1 |
| 14 | A2 | A3 |
| 15 | A4 | A5 |
| 16 | A6 | A7 |
| 17 | /EXP | SEL |
| 18 | RW | LOAD_IMM |
| 19 | /WE | /RESET |
| 20 | GND | GND |

| Signal | Direction | Meaning |
|---|---|---|
| D7:D0 | card drives on its reads | The CPU's read bus (into the D register) |
| SD7:SD0 | to card | The source bus: write data, held past the end of a write |
| A7:A0 | to card | Address low byte |
| /EXP | to card | /EXP1 (slots 1, 3) or /EXP2 (slots 2, 4), address only: low for any access to the page |
| SEL | to card | GND (slots 1, 2) or +5 V (slots 3, 4) through a 1k resistor: the A7 value the card answers |
| RW | to card | 1 = read cycle |
| LOAD_IMM | to card | 1 when the CPU latches the read bus into D (the State PLD's strobe, stall clocks already excluded) |
| /WE | to card | The write pulse, low in the low half of a write clock (about 20 ns) |
| CLK | to card | The 25.175 MHz CPU clock |
| /RESET | to card | MAP_RUN from the memory control PLD: low from power-up to the first clock edge only |
| +5 V, GND | | 2 power and 7 ground contacts, the grounds spread between the fast groups |

## Building a card

**Writes.**  A card's write strobe is `/EXP low, /WE low, A7 = SEL` (plus
any A6:A0 register select).  Latch SD7:SD0 on the strobe's rising edge, at
the end of /WE, as the main board's devices do.  The source bus holds the
data past that edge; the read bus does not.

**Reads must not put a decoder after /EXP.**  An I/O read has one 39.7 ns
clock: the address is valid at 20.5 ns and /EXP at 28 ns, which leaves
9.5 ns for the card's buffer to drive the bus before the 2 ns setup of the
D register.  So the card's read buffer (a 74F541, or a 74F245 with DIR set
by RW) takes /EXP straight on one enable, and everything else on its other
enable:

    74F541 /OE1 = /EXP
    74F541 /OE2 = card PLD: low when RW = 1, LOAD_IMM = 1, A7 = SEL
                  (and the A6:A0 register select, if any)

The card's PLD works from the address, RW and LOAD_IMM, which are valid
by 20.5 ns, so its 7.5 ns is in parallel with the I/O decode's and both
enables arrive by 28 ns.  A card PLD output that drives the bus directly
(with an output enable term) must also use /EXP in that same term, not a
strobe made from it.

**Load.**  The slots are unbuffered and every bus line reaches all four.
Give each line one input (or one 3-state output) on a card, keep traces
short, and keep the card's read buffer close to the edge fingers.

**Reset.**  /RESET is only one clock long.  A card that needs a reset makes
its own: a 22V10's registers clear at power-up, and other parts need an RC
power-on reset or a reset register the software writes.

**Power.**  Two +5 V contacts carry about 2 A together on a typical socket
(1 A per contact; check the socket's rating).  Keep each card well under
that, since the four slots share the main board's supply.

## ROM cartridge slot

The ROM (two AS7C256C 32K x 8 chips with battery backup for now, CPU.md)
moves to a plug-in cartridge.  The cartridge gets the address and data
lines and the same chip selects the ROM chips have on the main board.

| # | Side A | Side B |
|--:|---|---|
| 1 | GND | GND |
| 2 | +5 V | +5 V |
| 3 | A0 | A1 |
| 4 | A2 | A3 |
| 5 | A4 | A5 |
| 6 | A6 | A7 |
| 7 | GND | GND |
| 8 | A8 | A9 |
| 9 | A10 | A11 |
| 10 | A12 | A13 |
| 11 | A14 | /CE_LO (A15 from the address mux: lower chip) |
| 12 | GND | /CE_HI (I/O decode PLD: upper chip) |
| 13 | D0 | D1 |
| 14 | D2 | D3 |
| 15 | D4 | D5 |
| 16 | D6 | D7 |
| 17 | GND | /ROM_OE (memory control PLD) |
| 18 | /ROM_WE (pulled high on the main board) | /CART (GND on the cartridge: one is plugged in) |
| 19 | spare | spare |
| 20 | GND | GND |

- D7:D0 is the memory data bus that the RAM also drives.  The ROM chips'
  timing on the cartridge is the same as on the main board, plus the
  connector, so keep the cartridge's traces short.
- **/ROM_WE** is not driven by the main board (writes always go to the
  RAM).  It is there for a cartridge programmer, and the main board holds
  it high through a 10k resistor.
- **/CART** lets the main board tell an empty slot: with no cartridge, a
  pull-up reads high.  Nothing reads it yet; with no ROM the CPU would
  start on an open bus, so the board needs a cartridge to start (a boot
  ROM on the main board is the alternative).
- The battery and the power-fail switch that keep the SRAM's /CE high are
  on the cartridge, so a cartridge keeps its contents when it is pulled.

## To check

- **Glitches on /EXP.**  /EXP is decoded from the address only, and /WE
  goes low (22.1 ns) before /EXP has settled (28 ns), so a card's write
  strobe can see a short low pulse while the address changes.  A latch
  that clocks on the strobe's rising edge then takes a wrong value.  The
  first card should check this on a scope; if it shows, the I/O decode
  PLD's /EXP terms can include /WE for writes (a PLD change), or the card
  can qualify its strobe with CLK.
- **Read bus loading.**  Four slots of trace and the cards' 3-state
  outputs add capacitance to D7:D0, which every read uses.  The read path
  has 0.2 ns of margin, so measure the read timing with four cards in.
- **Socket.**  A 2 x 20, 0.1" card-edge socket with 1.6 mm (0.062") card
  slot, through-hole, in active stock (for example the Sullins EBC20DCAN
  family); not stock-checked yet.  Cards need hard gold fingers with a
  bevelled edge.
