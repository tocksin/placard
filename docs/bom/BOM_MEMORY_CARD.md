# Bill of materials: 32K memory card assembly PLC-2004

Date: 2026-11-16

The 32K memory expansion card ([MEMCARD.md](../architecture/MEMCARD.md)), built: the bare PCB, its two chips and their sockets.  Optional: it goes in any expansion slot, which needs that slot's socket fitted on the main board.  No shell is designed for it yet.

6 lines, 4 parts on the schematic.  Cost: **$23.51** for one assembly at these quantities.  3 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_MEMORY_CARD.csv](BOM_MEMORY_CARD.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  | PLC-1004 rev A | (custom PCB) | PCB, 32K memory card, 4-layer, ENIG, hard-gold bevelled fingers |  | 4.00 | 4.00 | est.: JLCPCB/PCBWay typical; the board is not laid out yet (MEMCARD.md) | Not on the schematic. |
| 1 | U1 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 2.99 | Mouser | Memory card page register U1 |
| 1 | U2 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 15.21 | Mouser |  |
| 2 | C1, C2 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.23 | 0.46 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 1 | U1 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 0.40 | est.: On Shore ED241DT | Not on the schematic. |
| 1 | U2 | ED281DT | On Shore | IC socket, DIP-28 0.3" |  | 0.45 | 0.45 | est.: On Shore ED281DT | Not on the schematic. |
