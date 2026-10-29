# Bill of materials: main board assembly PLC-2001

Date: 2026-10-29

The main board, built: the bare PCB, every part on the schematic, and the sockets, jumper shunts that are not drawn.  It is one line of the case assembly.

54 lines, 179 parts on the schematic.  Cost: **$205.85** for one assembly at these quantities, **$187.85** without the optional parts (expansion slot sockets J9-J12).  29 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_MAIN_PCB.csv](BOM_MAIN_PCB.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  | PLC-1001 rev A | (custom PCB) | PCB, main board, 290 x 290 mm, 4-layer, 1.6 mm, HASL lead-free |  | 16.00 | 16.00 | est.: JLCPCB/PCBWay typical, KIT_PRICING.md | Not on the schematic. |
| 20 | U1-U17, U35, U38, U42 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 59.80 | Mouser | State U1; Branch U2; PC U3, U4; ALU U5, U6; Address mux U7-U10; Memory control U11; I/O decode U12; H counter U13; V counter U14; Sync U15; Color decoder U16; Instruction register U17; Audio slot U35; Shared port U38; PS/2 receiver U42 |
| 5 | U18-U22 | SN74F377AN | Texas Instruments | Octal D flip-flop with enable, 74F, DIP-20 |  | 1.54 | 7.70 | Mouser |  |
| 1 | U23 | CD74HCT377E | Texas Instruments | Octal D flip-flop with enable, 74HCT, DIP-20 (line code: drives the row tint) |  | 1.29 | 1.29 | Mouser |  |
| 1 | U25 | CD74ACT273E | Texas Instruments | Octal D flip-flop with clear, 74ACT, DIP-20 |  | 2.45 | 2.45 | Mouser |  |
| 3 | U26, U27, U29 | SN74F541N | Texas Instruments | Octal buffer, 3-state, 74F, DIP-20 |  | 1.49 | 4.47 | Mouser |  |
| 2 | U31, U32 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 30.42 | Mouser |  |
| 1 | U36 | SN74HCT574N | Texas Instruments | Octal D flip-flop, 3-state, 74HCT, DIP-20 |  | 1.46 | 1.46 | Mouser |  |
| 1 | U40 | MCP1700-3302E/TO | Microchip | 3.3 V LDO regulator, 250 mA, TO-92 |  | 0.50 | 0.50 | Mouser |  |
| 1 | X1 | ECS-100A-251.7 | ECS Inc. | Clock oscillator, 25.175 MHz, 5 V, full-size DIP-14 can | 25.175 MHz | 4.06 | 4.06 | Digi-Key: Mouser has no stock (Justin, 2026-10-22) |  |
| 2 | J2, J3 |  |  | SNES controller socket, 7 pin | SNES pad | 4.00 | 8.00 | est.: ZedLabz right-angle SNES port (Amazon/eBay) |  |
| 1 | J4 | DM1AA-SF-PEJ(82) | Hirose | SD card socket | SD (SPI) | 4.56 | 4.56 | Mouser: SMD, push-push (no horizontal through-hole SD socket exists; Kyocera 145638009511859+ went obsolete 2026-10-25) |  |
| 1 | J5 | KMDGX-6S/6S-S4N | Kycon | Stacked dual mini-DIN-6 receptacle (PS/2), right angle, shielded: mouse top, keyboard bottom | PS/2 kbd + mouse | 3.72 | 3.72 | Mouser |  |
| 1 | J6 | 54-00174 | Tensility | 3.5 mm audio line out jack, 4 pole (TRRS), right angle, TH (a TRS plug's sleeve spans R2 and S) | 3.5 mm | 0.73 | 0.73 | Digi-Key: Justin, 2026-10-22 |  |
| 1 | J7 | A-HDF 15 A-KG/T | Assmann WSW | DE-15 high-density receptacle (VGA), with mounting holes | VGA | 1.36 | 1.36 | Digi-Key: Justin, 2026-10-22 |  |
| 1 | J8 | 87715-9106 | Molex | Cartridge slot: card edge, 64 contacts, 1.0 mm, keyed (PCIe x4 style), vertical TH |  | 2.88 | 2.88 | Mouser |  |
| 4 | J9-J12 | EBC20DCAN | Sullins | Expansion slot: 2 x 20 card-edge socket, 0.1", 1.6 mm card, TH |  | 4.50 | 18.00 | est.: Sullins EBC20DCAN | Optional (Justin, 2026-10-22): fit only the slots a card will go in; the computer runs with none.  Sullins EBC20DCAN not stock-checked (EXPANSION.md) |
| 1 | J13 | USB4125-GF-A-0190 | GCT | USB-C receptacle, power only (6 pin), top mount | USB4125-GF-A | 0.61 | 0.61 | Mouser |  |
| 1 | SW1 | ANT11TFHQE | CIT Relay and Switch | Power on/off: SPDT on-on toggle, 5 A 28 V DC, right-angle PCB, 1/4-40 bushing |  | 4.50 | 4.50 | est.: Digi-Key; Mouser has no stock |  |
| 1 | SW2 | PTS645VL58-2 LFS | C&K | Reset button: tactile, SPST momentary, right angle, through hole (drives K1's coil) |  | 0.43 | 0.43 | est.: Digi-Key; Mouser has no stock until 12/23/2026 |  |
| 1 | K1 | J1071CS5VDC.36 | CIT Relay and Switch | Reset relay: SPDT, 5 V coil (69 ohm, 72 mA), 7 A 30 V DC (NO and NC), through hole, sealed; NC contact carries the 5 V |  | 1.15 | 1.15 | Digi-Key: Justin, 2026-10-25; Mouser does not sell CIT |  |
| 1 | F1 | MF-RG300-0 | Bourns | Polyfuse, 3 A hold, radial | 3 A hold | 0.73 | 0.73 | Mouser | Part number from the footprint (Fuse_Bourns_MF-RG300) |
| 11 | D1-D6, D8-D11, D19 | 1N5817-TP | Micro Commercial Co | Schottky diode, 1 A, DO-41 (black) | 1N5817 | 0.15 | 1.65 | est.: MCC 1N5817-TP | Black DO-41 Schottky, so it is not mixed up with the glass 1N4148s; any 1N5817 (MCC, onsemi, Diodes Inc.) |
| 1 | D7 | SA5.0A | Littelfuse | TVS diode, 5 V stand-off, 500 W, DO-15 axial (across the fused USB 5 V) |  | 0.64 | 0.64 | Mouser |  |
| 6 | D12-D17 | 1N4148-TAP | Vishay | Small-signal diode, DO-35 (glass) | 1N4148 | 0.26 | 1.56 | Mouser: Vishay 1N4148-TAP | Any 1N4148 (Vishay, onsemi, Diodes Inc.) |
| 1 | D18 | WP7113ID | Kingbright | Power LED, 5 mm, red diffused, through hole (on +5V after K1) |  | 0.21 | 0.21 | Mouser | D18 with R59 (1k, about 3 mA); any 5 mm LED fits, pick the color (was Lite-On LTL2R3KRD-EM, out of stock 2026-10-25) |
| 2 | R1, R2 | MFR-25FBF52-5K1 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 5.1k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 8 | R3, R4, R13, R39-R41, R48, R63 | MFR-25FBF52-10K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 10k | 0.10 | 0.80 | est.: Yageo MFR-25FBF52 series |  |
| 10 | R5-R12, R61, R62 | MFR-25FBF52-47R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 47 | 0.04 | 0.40 | est.: Yageo MFR-25FBF52 series |  |
| 5 | R14, R17, R45-R47 | MFR-25FBF52-3K3 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 3.3k | 0.10 | 0.50 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R15, R18 | MFR-25FBF52-1K6 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1.6k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R16, R19 | MFR-25FBF52-820R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 820 | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R20 | MFR-25FBF52-1K43 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1.43k | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R21 | MFR-25FBF52-715R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 715 | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R22 | MFR-25FBF52-2R2 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 2.2 | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 9 | R23-R31 | MFR-25FBF52-2K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 2k | 0.10 | 0.90 | est.: Yageo MFR-25FBF52 series |  |
| 12 | R32-R38, R51-R54, R59 | MFR-25FBF52-1K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1k | 0.04 | 0.48 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R42-R44 | MFR-25FBF52-1K8 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1.8k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R49, R50, R55 | MFR-25FBF52-4K7 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 4.7k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R56-R58 | MFR-25FBF52-910R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 910 | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R60 | MFR-25FBF52-22K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 22k | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | RN1 | 4609X-101-103LF | Bourns | Resistor network, 8 bussed, SIP-9 | 10k | 0.39 | 0.39 | Mouser: Bourns 4609X-101-103LF |  |
| 34 | C1-C23, C25-C27, C29, C31, C32, C35, C36, C38, C42, C43 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.10 | 3.40 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 2 | C40, C47 | C330C105K5R5TA | KEMET | Ceramic capacitor, 5 mm pitch | 1u | 0.57 | 1.14 | Mouser: KEMET C330C105K5R5TA |  |
| 2 | C41, C44 | 25YXJ220M6.3X11 | Rubycon | Electrolytic capacitor, radial 6.3 mm, 2.50 mm pitch | 220u | 0.35 | 0.70 | est.: Rubycon YXJ series (Digi-Key; Panasonic EEU-FR1C221 out of stock) |  |
| 1 | C45 | FG24C0G1H153JNT06 | TDK | Ceramic capacitor, 5 mm pitch | 15n C0G | 0.58 | 0.58 | Mouser: TDK FG24C0G1H153JNT06 (KEMET C320C153K1G5TA non-stocked) |  |
| 1 | C46 | FG22X7R1E226MRT06 | TDK | Ceramic capacitor, 5 mm pitch | 22u | 1.73 | 1.73 | Mouser: TDK FG22X7R1E226MRT06, 25 V X7R (FG24X5R1A226MRT06 does not exist, FG24X5R1E226MRT06 is obsolete) |  |
| 2 | JP1, JP2 | PREC002SAAN-RC | Sullins | Pin header, 1 x 2, 2.54 mm (bring-up jumper) |  | 0.15 | 0.30 | est.: Sullins PREC002SAAN-RC |  |
| 2 | TP1, TP2 | 5011 | Keystone Electronics | Test point, multipurpose loop, through hole (bring-up test lead clip point) | GND | 0.45 | 0.90 | est.: Digi-Key (Keystone 5011, black) |  |
| 1 | TP3 | 5010 | Keystone Electronics | Test point, multipurpose loop, through hole (bring-up test lead clip point) | +5V | 0.45 | 0.45 | est.: Digi-Key (Keystone 5010, red) |  |
| 11 | U18-U23, U25-U27, U29, U36 | ED20DT | On Shore | IC socket, DIP-20 0.3" |  | 0.30 | 3.30 | est.: On Shore ED20DT | Not on the schematic. |
| 20 | U1-U17, U35, U38, U42 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 8.00 | est.: On Shore ED241DT | Not on the schematic. |
| 2 | U31, U32 | ED281DT | On Shore | IC socket, DIP-28 0.3" |  | 0.45 | 0.90 | est.: On Shore ED281DT | Not on the schematic. |
| 2 | JP1, JP2 | QPC02SXGN-RC | Sullins | Jumper shunt, 2.54 mm |  | 0.10 | 0.20 | est.: Sullins QPC02SXGN-RC | Not on the schematic.  Bring-up jumpers |
