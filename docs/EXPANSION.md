# Expansion slots and ROM cartridge slot

Date: 2026-10-20

The Placard has four expansion slots, each a 2 x 20, 0.1" (2.54 mm)
pitch card-edge socket, and one ROM cartridge slot, a keyed 2 x 32,
1.0 mm pitch socket (Molex 87715-9106, "ROM cartridge slot" below).  The
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

## Boot code on a card

Like an Apple II card, a card can change the boot.  At power-up the boot
loader (`src/scripts/rom_boot.asm`) looks at slots 4, 3, 2 and 1 before it
starts the program.  A card that wants to run code at boot starts with
this header in its first bytes (offsets from the slot's base address):

| Offset | Holds |
|---|---|
| 00-02 | "PLC" (50 4C 43) |
| 03 | Card ID, 1-255 (pick one; 0 means none) |
| 04 | Boot code length n, 1-90 (0 = no boot code, the card is only named) |
| 05 | Checksum: the sum of the n code bytes, mod 256 |
| 06-5F | The boot code |
| 60-7F | Free for the card's registers |

For each slot whose header and checksum are good, the boot loader copies
the n code bytes to RAM x0100 and calls them with the library's CALL, with
AC = the slot number (1-4), R1:R0 = the slot's base address, SP = FE and
`MAP_SHADOW` = 01 (map 01: the zero page reads RAM, the rest ROM).  The
code may use the library and the I/O drivers; it is built without the
library source, so it calls them through the jump table at xFB00, whose
entries never move ([LIBRARY.md](LIBRARY.md#jump-table)).  It then either:

- **returns**, and the scan goes on with the next slot and then the normal
  boot (a card that only sets itself up, or adds a device), or
- **never returns**, and takes the boot over: it can load a program from
  its own memory or from the SD card (`fs_load`), copy its own ROM, and so
  on.

Its code must keep zero page xFF (the slot being scanned), leave map 01
when it returns, and keep section 7 reading the ROM (the scan runs there).
90 bytes is enough for a loader that reads more of the card through its
registers.  **Holding Esc at power-up skips the scan**, to get past a card
whose code hangs.

An empty slot fails the "PLC" check: with nothing driving the read bus it
reads FF from the pull-ups below, or, if the bus has not risen yet, the
last byte on it, which is the scan's own `ld [y,x], ac` opcode (F4; the
opcode byte is stored XOR FDh, CPU.md).  A program can find cards later with the
library's `slot_id` (AC = slot 1-4 gives AC = card ID or 0, R1:R0 = base
address).

**Read bus pull-ups.**  D7:D0 get 3.3k pull-ups to +5 V on the main board
(one 9-pin bussed 3.3k SIP network; not a chip, no PLD logic), so an empty
slot or an unused I/O address reads FF rather than a floating level.  The
ROM cartridge also relies on them: while it loads, the CPU fetches the
floating FFh as `ld ac, ac` (ROM.md).  They were 10k until 2026-10-20;
3.3k lets the bus rise in about 0.5 µs, and is still within the 2.1 mA
an AT28C256 EEPROM can sink.  They
only set the level when nothing drives the bus and do not slow a driven
read.  The simulator reads an empty slot as FF.

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
| /RESET | to card | RUN from the ROM cartridge: low from power-up until the cartridge has loaded the ROM and lets the CPU run (ROM.md, "Loading the cartridge") |
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

The ROM (two AS7C256C 32K x 8 SRAMs, loaded at power-up from two
AT28C256 EEPROMs on the same cartridge by a PLD, five chips in all, ROM.md
"Loading the cartridge")
is on a plug-in cartridge.  The cartridge gets the address and data
lines and the same chip selects the ROM chips have on the main board.

The connector is a Molex 87715-9106: 64 contacts (2 x 32) at 1.0 mm
pitch, through-hole, vertical, for a 1.57 mm (0.062") card, the PCI
Express x4 socket.  Its key sits between contacts 11 and 12, so a
cartridge only goes in one way.  Each contact is rated 1.1 A.  The
cartridge needs gold fingers at 1.0 mm pitch, a bevelled edge and the key
notch.  Side A and side B are the two faces of the card; contacts 1-11
are the short section before the key and 12-32 the long one after it, as
on a PCI Express x4 card.

| # | Side A | Side B |
|--:|---|---|
| 1 | GND | GND |
| 2 | +5 V | +5 V |
| 3 | A0 | A1 |
| 4 | A2 | A3 |
| 5 | A4 | A5 |
| 6 | A6 | A7 |
| 7 | A8 | A9 |
| 8 | A10 | A11 |
| 9 | A12 | A13 |
| 10 | A14 | /CART (GND on the cartridge: one is plugged in) |
| 11 | GND | GND |
| | *key* | *key* |
| 12 | D0 | D1 |
| 13 | D2 | D3 |
| 14 | D4 | D5 |
| 15 | D6 | D7 |
| 16 | /CE_LO (A15 from the address mux: lower chip) | /CE_HI (I/O decode PLD: upper chip) |
| 17 | /ROM_OE (memory control PLD) | /SRC_EN (branch PLD, to the cartridge) |
| 18 | PIXEL_ENABLE (to the cartridge) | HOLD (from the cartridge, 10k pull-up on the main board) |
| 19 | RUN (from the cartridge, pull-down on the main board) | spare |
| 20 | OSC (25.175 MHz, before the clock gate, to the cartridge) | spare |
| 21 | GND | GND |
| 22-30 | spare | spare |
| 31 | GND | GND |
| 32 | spare | spare |

Two +5 V contacts (2.2 A together), a GND on each side every ten
contacts (8 in all), 32 signals and 22 spares (B19, B20, A22-A30, B22-B30,
A32, B32), kept for programming the EEPROMs in place, battery charging,
card detection and other functions (not assigned yet).

- D7:D0 is the memory data bus that the RAM also drives.  The ROM chips'
  timing on the cartridge is the same as on the main board, plus the
  connector, so keep the cartridge's traces short.
- **OSC** is next to the GND at 21 to keep its return path short.
- **/CART** lets the main board tell an empty slot: with no cartridge, a
  pull-up reads high.  Nothing reads it yet.  With no cartridge, HOLD's
  pull-up keeps the board stopped, so the board needs a cartridge (or the
  HOLD and RUN jumpers, BRINGUP.md) to start.
- **The loader** (ROM.md "Loading the cartridge") needs the 3.3k read bus
  pull-ups above (the CPU fetches the floating FFh while it loads) and
  OSC, HOLD, RUN, /SRC_EN and PIXEL_ENABLE.  /ROM_WE is gone: the
  cartridge makes its SRAMs' /WE.

## To check

- **Empty slot reads.**  Through 3.3k the bus rises in about 0.2-0.5 us,
  much longer than the read clock, so an empty slot really reads what the
  bus held (the opcode F4) or something between.  Either fails the header
  check; confirm on the board that an empty-slot boot skips all four slots.

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
- **Expansion socket.**  A 2 x 20, 0.1" card-edge socket with 1.6 mm (0.062") card
  slot, through-hole, in active stock (for example the Sullins EBC20DCAN
  family); not stock-checked yet.  Cards need hard gold fingers with a
  bevelled edge.
