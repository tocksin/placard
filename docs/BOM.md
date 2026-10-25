# Bill of materials

Date: 2026-10-25

Every part of the three boards, one line per part number: the main
board and the two ROM cartridges (64K and 32K, separate boards since
2026-10-24; a machine takes one).  The keyboard is a PS/2 keyboard
(the Cherry MX keyboard board was dropped on 2026-10-25).  Parts with
the same part number share a line; where no part number is chosen yet
the column is blank and parts with the same description and value
share the line.  Lines marked "not on the schematic" are sockets
and shunts that KiCad's own BOM export leaves out.
The net tie NT1 and the cartridges' edge fingers (their J1) are copper
on the PCB, so they are not listed.

Written by `src/scripts/gen_bom.py` from the KiCad sheets (the part
numbers are the Manufacturer and MPN fields set by
`gen_kicad_schematic.py`); the same list is in [BOM.csv](BOM.csv).
Rerun both after a part change.  Stock moves, so recheck before
ordering.

The PLDs come in two speed grades, so they are two lines: each chip's
grade follows its timing ([CHIPS.md](CHIPS.md#pld-speed-grades)).  The
notes give each PLD's job; [KITTING.md](KITTING.md) lists the images.

## Component cost

One of each board, priced at the quantities below (Mouser first, Digi-Key where Mouser has
no stock), on 2026-10-22.  Lines marked *est.* are typical prices for the part named, not
read from a price list; PCBs, the case, shipping and tax are not included.  The expansion
slot sockets J9-J12 are optional: a builder fits only the slots a card will use.

| Board | Components | Without optional parts | Lines estimated |
|---|--:|--:|--:|
| Main board | $213.95 | $170.79 | 30 |
| Cartridge, 64K | $61.52 | $61.52 | 3 |
| Cartridge, 32K | $32.57 | $32.57 | 3 |
| **Main and 64K cartridge** | **$275.47** | **$232.31** | |

## Main board

57 lines, 175 parts on the schematic.

Components: **$213.95** for one board at these quantities, **$170.79** without the optional parts.

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
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
| 11 | D1-D6, D8-D11, D19 | BAT85S-TAP | Vishay | Schottky diode, DO-35 | BAT85 | 0.22 | 2.42 | Mouser: Vishay BAT85S-TAP | Any BAT85 (Vishay BAT85S is the one Mouser stocks; Nexperia, onsemi) |
| 1 | D7 | SA5.0A | Littelfuse | D_Zener |  | 0.64 | 0.64 | Mouser |  |
| 6 | D12-D17 | 1N4148-TAP | Vishay | Small-signal diode, DO-35 | 1N4148 | 0.26 | 1.56 | Mouser: Vishay 1N4148-TAP | Any 1N4148 (Vishay, onsemi, Diodes Inc.) |
| 1 | D18 | WP7113ID | Kingbright | Power LED, 5 mm, red diffused, through hole (on +5V after K1) |  | 0.21 | 0.21 | Mouser | D18 with R59 (1k, about 3 mA); any 5 mm LED fits, pick the color (was Lite-On LTL2R3KRD-EM, out of stock 2026-10-25) |
| 2 | R1, R2 | MFR-25FBF52-5K1 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 5.1k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 7 | R3, R4, R13, R39-R41, R48 | MFR-25FBF52-10K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 10k | 0.10 | 0.70 | est.: Yageo MFR-25FBF52 series |  |
| 10 | R5-R12, R61, R62 | MFR-25FBF52-47R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 47 | 0.04 | 0.40 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R14, R17 | MFR-25FBF52-3K24 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 3.24k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R15, R18 | MFR-25FBF52-1K69 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1.69k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R16, R19 | MFR-25FBF52-825R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 825 | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R20 | MFR-25FBF52-1K43 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1.43k | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R21 | MFR-25FBF52-715R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 715 | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R22 | MFR-25FBF52-2R2 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 2.2 | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 9 | R23-R31 | MFR-25FBF52-2K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 2k | 0.10 | 0.90 | est.: Yageo MFR-25FBF52 series |  |
| 12 | R32-R38, R51-R54, R59 | MFR-25FBF52-1K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1k | 0.04 | 0.48 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R42-R44 | MFR-25FBF52-1K8 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 1.8k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R45-R47 | MFR-25FBF52-3K3 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 3.3k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R49, R50, R55 | MFR-25FBF52-4K7 | Yageo | Resistor, metal film 1%, 1/4 W, axial | 4.7k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R56-R58 | MFR-25FBF52-910R | Yageo | Resistor, metal film 1%, 1/4 W, axial | 910 | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R60 | MFR-25FBF52-22K | Yageo | Resistor, metal film 1%, 1/4 W, axial | 22k | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | RN1 | 4609X-101-103LF | Bourns | Resistor network, 8 bussed, SIP-9 | 10k | 0.39 | 0.39 | Mouser: Bourns 4609X-101-103LF |  |
| 34 | C1-C23, C25-C27, C29, C31, C32, C35, C36, C38, C42, C43 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.10 | 3.40 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 2 | C40, C47 | C330C105K5R5TA | KEMET | Ceramic capacitor, 5 mm pitch | 1u | 0.57 | 1.14 | Mouser: KEMET C330C105K5R5TA |  |
| 1 | C41 | EEU-FR1E221 | Panasonic | Electrolytic capacitor, radial 8.0 mm, 3.50 mm pitch | 220u 10V | 0.35 | 0.35 | est.: Panasonic FR series |  |
| 1 | C44 | EEU-FR1C221 | Panasonic | Electrolytic capacitor, radial 6.3 mm, 2.50 mm pitch | 220u | 0.35 | 0.35 | est.: Panasonic FR series |  |
| 1 | C45 | FG24C0G1H153JNT06 | TDK | Ceramic capacitor, 5 mm pitch | 15n C0G | 0.58 | 0.58 | Mouser: TDK FG24C0G1H153JNT06 (KEMET C320C153K1G5TA non-stocked) |  |
| 1 | C46 | FG24X5R1A226MRT06 | TDK | Ceramic capacitor, 5 mm pitch | 22u | 1.00 | 1.00 | est.: TDK FG24X5R1A226MRT06 (Digi-Key; Mouser does not list it) |  |
| 2 | JP1, JP2 | PREC002SAAN-RC | Sullins | Pin header, 1 x 2, 2.54 mm (bring-up jumper) |  | 0.15 | 0.30 | est.: Sullins PREC002SAAN-RC |  |
| 1 | X1 | ED14DT | On Shore | IC socket, DIP-14 0.3" |  | 0.25 | 0.25 | est.: On Shore ED14DT | Not on the schematic.  Or a 4-pin oscillator socket |
| 11 | U18-U23, U25-U27, U29, U36 | ED20DT | On Shore | IC socket, DIP-20 0.3" |  | 0.30 | 3.30 | est.: On Shore ED20DT | Not on the schematic. |
| 20 | U1-U17, U35, U38, U42 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 8.00 | est.: On Shore ED241DT | Not on the schematic. |
| 2 | U31, U32 | ED281DT | On Shore | IC socket, DIP-28 0.3" |  | 0.45 | 0.90 | est.: On Shore ED281DT | Not on the schematic. |
| 1 |  | MFR-25FBF52-10K | Yageo | Resistor, 10k (/WE pull-up), 1/4 W, axial | 10k | 0.10 | 0.10 | est.: Yageo MFR-25FBF52-10K | Not on the schematic.  Memory control rev 09 lets go of /WE while RUN is low; not drawn on the schematic yet (EXPANSION.md, "Booting from slot 1") |
| 2 | JP1, JP2 | QPC02SXGN-RC | Sullins | Jumper shunt, 2.54 mm |  | 0.10 | 0.20 | est.: Sullins QPC02SXGN-RC | Not on the schematic.  Bring-up jumpers |
| 1 |  | SWI20C-T-N | CUI Devices | USB-C power supply, wall plug (North America), 5 V 3 A / 9 V / 12 V, 20 W USB PD |  | 16.81 | 16.81 | Mouser | Not on the schematic.  Optional (Justin, 2026-10-25).  Any USB-C charger that gives 5 V at 3 A will do |
| 1 |  | USB2CC1MNC | StarTech | USB-C to USB-C cable, 1 m, 3 A (60 W) |  | 8.35 | 8.35 | Mouser | Not on the schematic.  Optional (Justin, 2026-10-25).  Any USB-C to USB-C cable (all are 3 A) |

## Cartridge, 64K

7 lines, 10 parts on the schematic.

Components: **$61.52** for one board at these quantities.

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 | U1 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 2.99 | Mouser | Cartridge loader U1 |
| 2 | U2, U3 | AT28C256-15PU | Microchip | EEPROM, 32K x 8, 150 ns, PDIP-28 0.6" (programmed) |  | 12.38 | 24.76 | Mouser |  |
| 2 | U4, U5 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 30.42 | Mouser |  |
| 5 | C1-C5 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.23 | 1.15 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 1 | U1 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 0.40 | est.: On Shore ED241DT | Not on the schematic. |
| 2 | U4, U5 | ED281DT | On Shore | IC socket, DIP-28 0.3" |  | 0.45 | 0.90 | est.: On Shore ED281DT | Not on the schematic. |
| 2 | U2, U3 | ED28DT | On Shore | IC socket, DIP-28 0.6" |  | 0.45 | 0.90 | est.: On Shore ED28DT | Not on the schematic. |

## Cartridge, 32K

7 lines, 6 parts on the schematic.

Components: **$32.57** for one board at these quantities.

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 | U1 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 2.99 | Mouser | Cartridge loader U1 |
| 1 | U2 | AT28C256-15PU | Microchip | EEPROM, 32K x 8, 150 ns, PDIP-28 0.6" (programmed) |  | 12.38 | 12.38 | Mouser |  |
| 1 | U3 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 15.21 | Mouser |  |
| 3 | C1-C3 | FG28X7R1H104KNT00 | TDK | Ceramic capacitor, 5 mm pitch | 100n | 0.23 | 0.69 | Mouser: TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser) |  |
| 1 | U1 | ED241DT | On Shore | IC socket, DIP-24 0.3" |  | 0.40 | 0.40 | est.: On Shore ED241DT | Not on the schematic. |
| 1 | U3 | ED281DT | On Shore | IC socket, DIP-28 0.3" |  | 0.45 | 0.45 | est.: On Shore ED281DT | Not on the schematic. |
| 1 | U2 | ED28DT | On Shore | IC socket, DIP-28 0.6" |  | 0.45 | 0.45 | est.: On Shore ED28DT | Not on the schematic. |
