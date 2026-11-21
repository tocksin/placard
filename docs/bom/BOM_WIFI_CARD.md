# Bill of materials: WiFi card assembly PLC-2005

Date: 2026-11-21

The WiFi expansion card ([WIFICARD.md](../architecture/WIFICARD.md)), built: the bare PCB, its PLD and socket, the WiFi board (soldered in on its own pin headers) and the passives.  Optional: it goes in any expansion slot, which needs that slot's socket fitted on the main board.  No shell yet.

10 lines, 13 parts on the schematic.  Cost: **$16.87** for one assembly at these quantities.  8 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_WIFI_CARD.csv](BOM_WIFI_CARD.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  | PLC-1005 rev A | (custom PCB) | PCB, WiFi card, 72 x 44.0 mm, 4-layer, ENIG, hard-gold bevelled fingers |  | 4.00 | 4.00 | est.: JLCPCB/PCBWay typical; the board is placed, not routed (WIFICARD.md) | Not on the schematic. |
| 1 | U1 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 2.99 | Mouser | WiFi card SPI port U1 |
| 1 | U2 | ESP32-C3-DevKitM-1-N4X | Espressif Systems | WiFi board, ESP32-C3-MINI-1-N4X module, USB, 3.3 V regulator, two 1 x 15 pin headers fitted |  | 8.00 | 8.00 | est.: Mouser 356-ESP32C3DVKTM1N4X, in stock 2026-11-21 (CA$11.52 on mouser.ca; the US price was not read) |  |
| 3 | R1-R3 | MFR-25FBF52-1K8 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1.8k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R4-R6 | MFR-25FBF52-3K3 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 3.3k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R7, R8 | MFR-25FBF52-10K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 10k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R9 | MFR-25FBF52-470R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 470 | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | C1 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.23 | 0.23 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 1 | C2 | 25YXJ220M6.3X11 | Rubycon | Electrolytic capacitor, radial 6.3 mm, 2.50 mm pitch | 220u | 0.35 | 0.35 | est.: Rubycon YXJ series (Digi-Key; Panasonic EEU-FR1C221 out of stock) |  |
| 1 | U1 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 0.40 | est.: On Shore ED241DT | Not on the schematic. |
