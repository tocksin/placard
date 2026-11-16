# Memory expansion card, 512K

Date: 2026-11-16

A card for any expansion slot that adds 512K of RAM for data.  It has three
chips:

| | Part | Job |
|---|---|---|
| U1 | ATF22V10C-7PX (`src/pld/ATF22V10_MEMCARD_HI.pld`) | Page high PLD: decodes the two page addresses, holds page bits 11:8 |
| U2 | ATF22V10C-7PX (`src/pld/ATF22V10_MEMCARD_LO.pld`) | Page low PLD: holds page bits 7:0 |
| U3 | AS7C4096A-12JIN, 512K x 8, 12 ns, SOJ-36 | The memory |

plus a 100n capacitor for each (C1-C3).  U3 is the one surface-mount part:
no 5 V SRAM this fast is made in a DIP above 32K.  Its leads are on a
1.27 mm pitch and can be soldered by hand.  The schematic is
`kicad/memory_card/` ([PDF](../../schematics/placard_memory_card.pdf)) and
the parts list is [BOM_MEMORY_CARD.md](../bom/BOM_MEMORY_CARD.md).  The
board itself is not laid out yet ("Still to do" below).  The main board
needs no change.

## How it works

A slot gives a card 128 addresses ([EXPANSION.md](EXPANSION.md)), and a
program can't run from a card, so the card is storage that a program
reaches 128 bytes at a time.

The SRAM is wired to the slot exactly as the plain card of EXPANSION.md,
"Building a card":

    U3 /CE = /EXP (A16)     /OE = Q0 (A10)     /WE = /WE (B24)
    U3 A6:A0 = slot A6:A0   I/O8:1 = D7:D0

Its upper address, A18:A7, is a 12-bit **page number**: 4096 pages of 128
bytes.  One 22V10 has ten outputs, so the page number is held in two:

- **U1** sees /EXP and A6:A0.  It holds page bits 11:8 and loads them from
  D3:D0 on a write to offset 7F.  It also makes /PGLO, low while the card
  is selected at offset 7E.
- **U2** holds page bits 7:0 and loads them from D7:D0 on a write while
  /PGLO is low.

Both clock on the rising edge of /WE, the end of every write on the board,
and keep their value on any other write.  The shared port PLD on the main
board latches the same way.  Both clear at power-up, so the card starts at
page 0.

Neither PLD is in any of the SRAM's read or write paths, so the card has
the plain card's timing, the reference the slots were checked with.

| Offset in the slot | Read | Write |
|---|---|---|
| 00-7D | the page's byte | the page's byte |
| 7E | not used | **page number, low 8 bits** |
| 7F | not used | **page number, high 4 bits** (D3:D0; D7:D4 ignored) |

**The reserved bytes.**  The SRAM is selected by /EXP alone, so a write
that sets the page also stores that byte in the SRAM, at the same offset
of the page being left.  Offsets 7E and 7F of every page therefore hold
nothing useful, and a page has **126 bytes** (00-7D): 516,096 bytes in
all.  Keeping the SRAM off for those two addresses would put a gate in its
/CE or /WE, and neither works: a PLD in /CE makes the read later than the
slot allows, and a PLD in /WE ends the write up to 7.5 ns after the data
bus may change.

The page number can't be read back; a program keeps a copy of the page it
set.  The SRAM is not cleared at power-up and holds nothing with the power
off.

## Using the card

With the card in slot 1 (x5100; the other slots are x5300, x5180 and
x5380), a program sets Y to the slot's page and uses X as the offset:

    ld   0x51, y
    ld   0x7E, x
    ld   0x34, [y,x]      ; page low
    ld   0x7F, x
    ld   0x02, [y,x]      ; page high: page x234
    ld   0x00, x
    ld   [y,x], ac        ; read byte 0 of page x234
    ld   0x7D, x
    ld   ac, [y,x]        ; and write it to byte 125

A program that stays within 256 pages (32K) sets only the low byte.
Between the two page writes the page number is half old and half new; that
does no harm, because the second write lands on a reserved offset whatever
the page.

Byte n of the card is page n / 126, offset n mod 126.  A program that
would rather shift than divide can use 64 bytes of each page (262,144
bytes in all), or treat the pages as 4096 records of up to 126 bytes.

**Finding the card.**  The card has no "PLC" header (its memory is empty
at power-up), so the boot scan passes over it and `slot_id` reports no
card.  A program looks for it: set page 0 and write A5 to offset 0, set
page 1 and write 5A to offset 0, then go back to each page and read.  A
memory card reads A5 and 5A; an empty slot or any other card does not.
`src/scripts/test_memcard.py` runs this in the simulator, which has the
card as `io_devices.MemoryCard`.

A program can also write a "PLC" header with a card ID and a boot length
of 0 into page 0 once it has found the card, so later `slot_id` calls name
it until the power goes off.

## Timing

Against the card limits of EXPANSION.md, "Card timing", measured at the
edge fingers:

| Card delay | Limit | This card |
|---|---:|---|
| Read: /EXP falling to data valid | 16.0 ns | 13.0: U3 tACE 12 + 1 of track |
| Read: A6:A0 to data valid | 16.0 ns | 13.0: U3 tAA 12 + 1 |
| Read: Q0 falling to data valid | 8.0 ns | 7.0: U3 tOE 6 + 1 |
| Write: select ready before /WE rises | 13.0 ns | 12.0: U1 makes /PGLO in 7.5, U2 needs it 3.5 before the clock, + 1.  U3 needs 9.0 (tCW 8 + 1), U1 itself 4.5 |
| Write: data setup before /WE rises | 9.0 ns | 7.0: U3 tDW 6 + 1.  U1 and U2 need 3.5 + 1 |
| Write: data hold after /WE rises | 2.0 ns | 0: all three need 0 |
| Write: A6:A0, /EXP hold after /WE rises | 2.0 ns | 0: U3 and U1 need 0; /PGLO holds at least 3 ns longer for U2 |

Every line has more room than the plain 15 ns card, which the routed
rev A board passes with 3.4 ns to spare on the read and 1.4 ns or more on
the holds.  The tightest line is the /PGLO path into U2, with 1.0 ns to
the limit.

**Changing the page.**  The PLD outputs move 2 to 5.5 ns after /WE has
risen.  The SRAM's write has ended by then (its address hold is 0 ns), so
the page write lands in the old page.  If the two ever overlapped, the
stray byte would fall on the same reserved offset of the new page.  The
new page is settled long before the next access of the card, which is at
least one instruction later.

**Load.**  EXPANSION.md asks for one input on each slot line.  Here
D3:D0 and /WE each have three (U3, U1, U2), about 20 pF together; D7:D4
(U3, U2), A6:A0 and /EXP (U3, U1) have two, about 13 pF; Q0 has one.
That is the price of three chips, and it is one of the things to measure
on the first board.

**Checks made.**  `src/sim/tb_memcard.vhd` runs the two PLDs' VHDL
(`src/hdl/memcard_hi_pld.vhd`, `src/hdl/memcard_lo_pld.vhd`) with a 512K
SRAM model on a slot with these times in GHDL: all 4096 pages keep their
bytes, only writes to 7E and 7F move the page, and the SRAM's address
never moves during a write.  The PLD sources have not been compiled in
WinCUPL yet.

## Why this part

A slot read needs a 15 ns memory, and the fast 5 V SRAMs above 32K come
only in surface-mount packages.  The AS7C4096A is a current Alliance part
in a 400 mil SOJ-36, the easiest of those packages to solder by hand.  A
through-hole 512K card is possible with the 55 ns AS6C4008 DIP, but the
slot can't wait for it, so the card would latch the whole address, read
through a buffer and time its own write pulse: five chips, and
four bus writes for each byte stored.

## Still to do

- **Board.**  PCB PLC-1004 is not laid out.  The fingers are the
  `Card_Edge_87715-9106` footprint; a card may be up to 72 mm wide.  Keep
  U3 next to the fingers and the /WE track to U3 no longer than to the
  PLDs.  Check the U3 pin numbers in the symbol against the pin drawing in
  the Alliance datasheet first; they were taken from the datasheet's text.
- **WinCUPL.**  Compile both `.pld` files and keep the .jed files.
- **Shell.**  None is designed; the card works bare.
- **Library.**  No routines yet.  Candidates: find the card, copy a block
  between the card and main memory.
- **On the first card.**  Scope D7:D0 at the end of a card read (the bus
  overlap noted in EXPANSION.md) and check a read with all four slots full.
