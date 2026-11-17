# Bill of materials: 512K memory card assembly PLC-2004

Date: 2026-11-16

The 512K memory expansion card ([MEMCARD.md](../architecture/MEMCARD.md)), built: the bare PCB, its three chips and the two PLDs' sockets (the SRAM is soldered).  Optional: it goes in any expansion slot, which needs that slot's socket fitted on the main board.  With its printed shell, the shell's screws and nuts and the insert for the case's card screw.

9 lines, 6 parts on the schematic.  Cost: **$30.21** for one assembly at these quantities.  6 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_MEMORY_CARD.csv](BOM_MEMORY_CARD.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  | PLC-1004 rev A | (custom PCB) | PCB, 512K memory card, 72 x 42.7 mm, 4-layer, ENIG, hard-gold bevelled fingers |  | 4.00 | 4.00 | est.: JLCPCB/PCBWay typical; the board is routed (MEMCARD.md) | Not on the schematic. |
| 2 | U1, U2 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 5.98 | Mouser | Memory card page high and decode U1; Memory card page low U2 |
| 1 | U3 | AS7C4096A-12JIN | Alliance Memory | SRAM, 512K x 8, 12 ns, SOJ-36 0.4" (surface mount, 1.27 mm pitch) |  | 14.74 | 14.74 | Mouser | The card's one surface-mount part (Justin, 2026-11-16): no 512K SRAM this fast is made in a DIP |
| 3 | C1-C3 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.23 | 0.69 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 2 | U1, U2 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 0.80 | est.: On Shore ED241DT | Not on the schematic. |
| 1 |  |  |  | Memory card shell (front and back halves, case/memcard_shell_*.stl) |  | 3.50 | 3.50 | est.: 3D print, not quoted | Not on the schematic.  77 x 22.6 x 48.2 mm outside (MEMCARD.md, "Shell") |
| 2 |  |  |  | M3 x 8 pan head screw (back half and card to the front half) |  | 0.10 | 0.20 | est.: any M3 x 8 machine screw | Not on the schematic. |
| 2 |  |  |  | M3 hex nut, ISO 4032 (in the front half's bosses) |  | 0.05 | 0.10 | est.: any M3 nut | Not on the schematic. |
| 1 |  |  |  | M3 heat-set insert, M3 x 5.7, 4.0 mm hole (card screw from the case's back plate) |  | 0.20 | 0.20 | est.: any M3 x 5.7 brass heat-set insert | Not on the schematic. |
