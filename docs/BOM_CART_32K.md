# Bill of materials: 32K cartridge assembly

Date: 2026-10-27

The 32K ROM cartridge, built: the bare PCB, its parts and sockets, and its shell and screw.  A machine takes one cartridge, 64K or 32K.

10 lines, 6 parts on the schematic.  Cost: **$39.67** for one assembly at these quantities.  6 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_CART_32K.csv](BOM_CART_32K.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  |  |  | PCB, 32K cartridge, 39 x 66.0 mm, 2-layer, ENIG, hard-gold bevelled fingers |  | 3.50 | 3.50 | est.: JLCPCB/PCBWay typical (smaller than the 64K board) | Not on the schematic. |
| 1 | U1 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 2.99 | Mouser | Cartridge loader U1 |
| 1 | U2 | AT28C256-15PU | Microchip | EEPROM, 32K x 8, 150 ns, PDIP-28 0.6" (programmed) |  | 12.38 | 12.38 | Mouser |  |
| 1 | U3 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 15.21 | Mouser |  |
| 3 | C1-C3 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.23 | 0.69 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 1 | U1 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 0.40 | est.: On Shore ED241DT | Not on the schematic. |
| 1 | U3 | ED281DT | On Shore | IC socket, DIP-28 0.3" |  | 0.45 | 0.45 | est.: On Shore ED281DT | Not on the schematic. |
| 1 | U2 | ED28DT | On Shore | IC socket, DIP-28 0.6" |  | 0.45 | 0.45 | est.: On Shore ED28DT | Not on the schematic. |
| 1 |  |  |  | Cartridge shell, 32K height (front and back halves) |  | 3.50 | 3.50 | est.: 3D print or moulding, not quoted | Not on the schematic.  Not designed yet: two halves round the card and J8's body, 44 x 19.25 mm outside (EXPANSION.md "Shell keepouts"); one design takes either card, only its height differs |
| 1 |  |  |  | M3 x 6 pan head screw (card to shell at H1) |  | 0.10 | 0.10 | est.: any M3 x 6 machine screw | Not on the schematic. |
