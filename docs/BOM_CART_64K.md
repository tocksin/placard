# Bill of materials: 64K cartridge assembly PLC-2003

Date: 2026-10-29

The 64K ROM cartridge, built: the bare PCB, its parts and sockets, and its shell and screw.  A machine takes one cartridge, 64K or 32K.

10 lines, 10 parts on the schematic.  Cost: **$69.62** for one assembly at these quantities.  6 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_CART_64K.csv](BOM_CART_64K.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  | PLC-1003 rev A | (custom PCB) | PCB, 64K cartridge, 39 x 102.2 mm, 2-layer, ENIG, hard-gold bevelled fingers |  | 4.00 | 4.00 | est.: JLCPCB/PCBWay typical, KIT_PRICING.md | Not on the schematic. |
| 1 | U1 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 2.99 | Mouser | Cartridge loader U1 |
| 2 | U2, U3 | AT28C256-15PU | Microchip | EEPROM, 32K x 8, 150 ns, PDIP-28 0.6" (programmed) |  | 12.38 | 24.76 | Mouser |  |
| 2 | U4, U5 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 30.42 | Mouser |  |
| 5 | C1-C5 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.23 | 1.15 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 1 | U1 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 0.40 | est.: On Shore ED241DT | Not on the schematic. |
| 2 | U4, U5 | ED281DT | On Shore | IC socket, DIP-28 0.3" |  | 0.45 | 0.90 | est.: On Shore ED281DT | Not on the schematic. |
| 2 | U2, U3 | ED28DT | On Shore | IC socket, DIP-28 0.6" |  | 0.45 | 0.90 | est.: On Shore ED28DT | Not on the schematic. |
| 1 |  |  |  | Cartridge shell, 64K height (front and back halves) |  | 4.00 | 4.00 | est.: 3D print or moulding, not quoted | Not on the schematic.  Not designed yet: two halves round the card and J8's body, 44 x 19.25 mm outside (EXPANSION.md "Shell keepouts"); one design takes either card, only its height differs |
| 1 |  |  |  | M3 x 6 pan head screw (card to shell at H1) |  | 0.10 | 0.10 | est.: any M3 x 6 machine screw | Not on the schematic. |
