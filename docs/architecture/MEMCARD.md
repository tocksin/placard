# Memory expansion card, 32K

Date: 2026-11-16

A card for any expansion slot that adds 32K of RAM for data.  It is two
through-hole chips, both already used on the main board and the cartridge:

| | Part | Job |
|---|---|---|
| U1 | ATF22V10C-7PX (`src/pld/ATF22V10_MEMCARD.pld`) | Page register |
| U2 | AS7C256C-15PCN, 32K x 8, 15 ns | The memory |

plus a 100n capacitor for each (C1, C2).  The schematic is
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

    U2 /CE = /EXP (A16)     /OE = Q0 (A10)     /WE = /WE (B24)
    U2 A6:A0 = slot A6:A0   I/O7:0 = D7:D0

Its upper address, A14:A7, comes from U1, an 8-bit **page register**: 256
pages of 128 bytes.  U1 clocks on the rising edge of /WE, the end of every
write on the board, and takes the data bus only when the write is to the
card's last eight addresses (/EXP low and A6:A3 = 1111); on any other write
it keeps its value.  The shared port PLD on the main board latches the
same way.  U1 clears at power-up, so the card starts at page 0.

U1 is not in any of the SRAM's read or write paths, so the card has the
plain card's timing, the reference the slots were checked with.

| Offset in the slot | Read | Write |
|---|---|---|
| 00-77 | the page's byte | the page's byte |
| 78-7F | not used | **the page number**, 0-255 (use 7F) |

**The reserved bytes.**  The SRAM is selected by /EXP alone, so the write
that sets the page also stores that byte in the SRAM, at the same offset
of the page being left.  Offsets 78-7F of every page therefore hold
nothing useful, and a page has **120 bytes** (00-77): 30,720 bytes in all.
Keeping the SRAM off for those eight addresses would put a gate in its /CE
or /WE, and neither works: a PLD in /CE makes the read 7.5 ns later than
the slot allows a 15 ns SRAM, and a PLD in /WE ends the write up to 7.5 ns
after the data bus may change.  Eight bytes a page cost less than a third
chip.

The page register can't be read back; a program keeps a copy of the page
it set.  The SRAM is not cleared at power-up and holds nothing with the
power off.

## Using the card

With the card in slot 1 (x5100; the other slots are x5300, x5180 and
x5380), a program sets Y to the slot's page and uses X as the offset:

    ld   0x51, y
    ld   0x7F, x
    ld   12, [y,x]        ; page 12
    ld   0x00, x
    ld   [y,x], ac        ; read byte 0 of page 12
    ld   0x77, x
    ld   ac, [y,x]        ; and write it to byte 119

Byte n of the card is page n / 120, offset n mod 120.  A program that
would rather shift than divide can use 64 bytes of each page (16,384 bytes
in all), or treat the pages as 256 records of up to 120 bytes.

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
| Read: /EXP falling to data valid | 16.0 ns | 16.0: U2 tACE 15 + 1 of track |
| Read: A6:A0 to data valid | 16.0 ns | 16.0: U2 tAA 15 + 1 |
| Read: Q0 falling to data valid | 8.0 ns | 8.0: U2 tOE 7 + 1 |
| Write: select ready before /WE rises | 13.0 ns | 13.0: U2 tCW 12 + 1.  U1 needs 3.5 + 1 |
| Write: data setup before /WE rises | 9.0 ns | 9.0: U2 tDW 8 + 1.  U1 needs 3.5 + 1 |
| Write: data hold after /WE rises | 2.0 ns | 0: U2 and U1 both need 0 |
| Write: A6:A0, /EXP hold after /WE rises | 2.0 ns | 0: U2 and U1 both need 0 |

These are the plain card's numbers, and the routed rev A board passes them
with 3.4 ns to spare on the read and 1.4 ns or more on the holds.

**Changing the page.**  U1's outputs move 2 to 5.5 ns after /WE has risen.
The SRAM's write has ended by then (its address hold is 0 ns), so the page
write lands in the old page.  If the two ever overlapped, the stray byte
would fall on the same reserved offset of the new page.  The new page is
settled long before the next access of the card, which is at least one
instruction later.

**Load.**  EXPANSION.md asks for one input on each slot line.  Here
D7:D0, /EXP, /WE and A6:A3 each have two (U2 and U1), about 15 pF
together.  That is the price of two chips, and it is one of the things to
measure on the first board.

**Checks made.**  `src/sim/tb_memcard.vhd` runs the PLD's VHDL
(`src/hdl/memcard_pld.vhd`) with an SRAM model on a slot with these times
in GHDL: all 256 pages keep their bytes, only a write to 78-7F moves the
page, and the SRAM's address never moves during a write.  The PLD source
has not been compiled in WinCUPL yet.

## Why 32K

No 15 ns 5 V SRAM is made in a DIP above 32K (the 512K DIP parts are
55 ns), and a slot read needs 15 ns.  A bigger card is possible with a surface-mount SRAM
(128K or 512K at 10-12 ns in SOJ) and a second PLD for the longer page
number, three chips.  A slow 512K DIP SRAM would need five or six chips
(read-ahead and a stretched write).  This card stays with two chips and
only through-hole parts, the same two part numbers the kit already has.

## Still to do

- **Board.**  PCB PLC-1004 is not laid out.  The fingers are the
  `Card_Edge_87715-9106` footprint; a card may be up to 72 mm wide.  Keep
  U2 next to the fingers and the /WE track to U2 no longer than to U1.
- **WinCUPL.**  Compile `ATF22V10_MEMCARD.pld` and keep the .jed.
- **Shell.**  None is designed; the card works bare.
- **Library.**  No routines yet.  Candidates: find the card, copy a block
  between the card and main memory.
- **On the first card.**  Scope D7:D0 at the end of a card read (the bus
  overlap noted in EXPANSION.md) and check a read with all four slots full.
