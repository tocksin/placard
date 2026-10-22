# Bill of materials

Date: 2026-10-22

Every part of the three boards, one line per part number: the main
board, the ROM cartridge and the keyboard.  Parts with the same part
number share a line; where no part number is chosen yet the column is
blank and parts with the same description and value share the line.
Lines marked "not on the schematic" are sockets, shunts, keyboard
parts and the keyboard cable that KiCad's own BOM export leaves out.
The net tie NT1, the cartridge's edge fingers (its J1) and its 32K/64K
solder jumper JP1 are copper on the PCB, so they are not listed.

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
read from a price list; PCBs, the case, shipping and tax are not included.

| Board | Components | Lines estimated |
|---|--:|--:|
| Main board | $189.58 | 39 |
| Cartridge | $61.36 | 4 |
| Keyboard | $145.96 | 6 |
| **All three** | **$396.90** | |

## Main board

52 lines, 158 parts on the schematic.

Components: **$189.58** for one board at these quantities.

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 12 | U1, U5-U12, U15, U17, U38 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | 2.99 | 35.88 | Mouser | State U1; ALU U5, U6; Address mux U7-U10; Memory control U11; I/O decode U12; Sync U15; Instruction register U17; Shared port U38 |
| 7 | U2-U4, U13, U14, U16, U35 | ATF22V10C-10PU | Microchip | PLD, 22V10, 10 ns, PDIP-24 0.3" (programmed) |  | 2.63 | 18.41 | Mouser | Branch U2; PC U3, U4; H counter U13; V counter U14; Color decoder U16; Audio slot U35 |
| 6 | U18-U23 | SN74F377AN | Texas Instruments | Octal D flip-flop with enable, 74F, DIP-20 |  | 1.05 | 6.30 | Mouser |  |
| 1 | U25 | CD74ACT273E | Texas Instruments | Octal D flip-flop with clear, 74ACT, DIP-20 |  | 2.45 | 2.45 | Mouser |  |
| 4 | U26, U27, U29, U39 | SN74F541N | Texas Instruments | Octal buffer, 3-state, 74F, DIP-20 |  | 1.49 | 5.96 | Mouser |  |
| 2 | U31, U32 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 30.42 | Mouser |  |
| 1 | U36 | SN74HCT574N | Texas Instruments | Octal D flip-flop, 3-state, 74HCT, DIP-20 |  | 1.41 | 1.41 | Mouser |  |
| 1 | U37 | SN74HC574N | Texas Instruments | Octal D flip-flop, 3-state, 74HC, DIP-20 |  | 0.93 | 0.93 | Mouser |  |
| 1 | U40 | MCP1700-3302E/TO | Microchip | 3.3 V LDO regulator, 250 mA, TO-92 |  | 0.50 | 0.50 | Mouser |  |
| 1 | X1 |  |  | Clock oscillator, 25.175 MHz, 5 V, full-size DIP-14 can | 25.175 MHz | 3.00 | 3.00 | est.: ECS-100A-251.7 (Digi-Key; Mouser has no stock); no 5 V DIP 25.175 MHz part is stocked at Mouser | Not chosen yet |
| 1 | J1 |  |  | Box header, 2 x 10, 2.54 mm, shrouded and keyed, vertical |  | 0.60 | 0.60 | est.: Wurth 61202021621 |  |
| 2 | J2, J3 |  |  | SNES controller socket, 7 pin | SNES pad | 4.00 | 8.00 | est.: ZedLabz right-angle SNES port (Amazon/eBay) |  |
| 1 | J4 |  |  | SD card socket | SD (SPI) | 2.50 | 2.50 | est.: through-hole SD socket |  |
| 1 | J5 | KMDGX-6S/6S-S4N | Kycon | Stacked dual mini-DIN-6 receptacle (PS/2), right angle, shielded: mouse top, keyboard bottom | PS/2 kbd + mouse | 3.72 | 3.72 | Mouser |  |
| 1 | J6 |  |  | 3.5 mm stereo headphone jack | 3.5 mm | 1.10 | 1.10 | est.: CUI SJ1-3523N |  |
| 1 | J7 |  |  | DE-15 high-density receptacle (VGA), with mounting holes | VGA | 1.50 | 1.50 | est.: Assmann A-HDF 15 A-KG/T |  |
| 1 | J8 | 87715-9106 | Molex | Cartridge slot: card edge, 64 contacts, 1.0 mm, keyed (PCIe x4 style), vertical TH |  | 2.81 | 2.81 | Mouser |  |
| 4 | J9-J12 |  |  | Expansion slot: 2 x 20 card-edge socket, 0.1", 1.6 mm card, TH |  | 4.50 | 18.00 | est.: Sullins EBC20DCAN | Candidate: Sullins EBC20DCAN family, not stock-checked (EXPANSION.md) |
| 1 | J13 | USB4125-GF-A | GCT | USB-C receptacle, power only (6 pin), top mount |  | 0.61 | 0.61 | Mouser: USB4125-GF-A-0190 (the stocked packaging of the same part) |  |
| 1 | SW1 | ANT11TFHQE | CIT Relay and Switch | Power on/off: SPDT on-on toggle, 5 A 28 V DC, right-angle PCB, 1/4-40 bushing |  | 4.50 | 4.50 | est.: Digi-Key; Mouser has no stock |  |
| 1 | SW2 | E112SD1A3QE | C&K | Reset: SPDT momentary pushbutton, NC contact used, 4 A 28 V DC, right-angle PCB |  | 11.00 | 11.00 | est.: Digi-Key; Mouser has no stock below 160 |  |
| 1 | F1 | MF-RG300 | Bourns | Polyfuse, 3 A hold, radial | 3 A hold | 0.73 | 0.73 | Mouser: MF-RG300-0 | Part number from the footprint (Fuse_Bourns_MF-RG300) |
| 6 | D1-D6 | BAT85 | Vishay | Schottky diode, DO-35 |  | 0.16 | 0.96 | est.: Vishay BAT85 | Any BAT85 (Vishay, Nexperia, onsemi) |
| 2 | R1, R2 |  |  | Resistor, metal film 1%, 1/4 W, axial | 5.1k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 7 | R3, R4, R13, R39-R41, R48 |  |  | Resistor, metal film 1%, 1/4 W, axial | 10k | 0.10 | 0.70 | est.: Yageo MFR-25FBF52 series |  |
| 8 | R5-R12 |  |  | Resistor, metal film 1%, 1/4 W, axial | 47 | 0.10 | 0.80 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R14, R17 |  |  | Resistor, metal film 1%, 1/4 W, axial | 3.24k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R15, R18 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1.69k | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 2 | R16, R19 |  |  | Resistor, metal film 1%, 1/4 W, axial | 825 | 0.10 | 0.20 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R20 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1.43k | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R21 |  |  | Resistor, metal film 1%, 1/4 W, axial | 715 | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 1 | R22 |  |  | Resistor, metal film 1%, 1/4 W, axial | 2.2 | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 series |  |
| 9 | R23-R31 |  |  | Resistor, metal film 1%, 1/4 W, axial | 2k | 0.10 | 0.90 | est.: Yageo MFR-25FBF52 series |  |
| 11 | R32-R38, R51-R54 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1k | 0.04 | 0.44 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R42-R44 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1.8k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R45-R47 |  |  | Resistor, metal film 1%, 1/4 W, axial | 3.3k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 3 | R49, R50, R55 |  |  | Resistor, metal film 1%, 1/4 W, axial | 4.7k | 0.10 | 0.30 | est.: Yageo MFR-25FBF52 series |  |
| 1 | RN1 |  |  | Resistor network, 8 bussed, SIP-9 | 10k | 0.40 | 0.40 | est.: Bourns 4609X-101 series |  |
| 1 | RN2 |  |  | Resistor network, 8 bussed, SIP-9 | 4.7k | 0.40 | 0.40 | est.: Bourns 4609X-101 series |  |
| 35 | C1-C23, C25-C27, C29, C31, C32, C35-C39, C43 |  |  | Ceramic capacitor, 5 mm pitch | 100n | 0.18 | 6.30 | est.: KEMET C320C104K5R5TA |  |
| 2 | C40, C42 |  |  | Ceramic capacitor, 5 mm pitch | 1u | 0.50 | 1.00 | est.: KEMET C330C105K5R5TA |  |
| 1 | C41 |  |  | Electrolytic capacitor, radial 8.0 mm, 3.50 mm pitch | 220u 10V | 0.35 | 0.35 | est.: Panasonic FR series |  |
| 1 | C44 |  |  | Electrolytic capacitor, radial 6.3 mm, 2.50 mm pitch | 220u | 0.35 | 0.35 | est.: Panasonic FR series |  |
| 1 | C45 |  |  | Ceramic capacitor, 5 mm pitch | 15n C0G | 0.40 | 0.40 | est.: KEMET C315C153J1G5TA |  |
| 1 | C46 |  |  | Ceramic capacitor, 5 mm pitch | 22u | 1.00 | 1.00 | est.: TDK FG24X5R1A226MRT06 |  |
| 2 | JP1, JP2 |  |  | Pin header, 1 x 2, 2.54 mm (bring-up jumper) |  | 0.15 | 0.30 | est.: 1 x 2 header |  |
| 1 | X1 |  |  | IC socket, DIP-14 0.3" |  | 0.25 | 0.25 | est.: On Shore ED14DT | Not on the schematic.  Or a 4-pin oscillator socket |
| 13 | U18-U23, U25-U27, U29, U36, U37, U39 |  |  | IC socket, DIP-20 0.3" |  | 0.30 | 3.90 | est.: On Shore ED20DT | Not on the schematic. |
| 19 | U1-U17, U35, U38 |  |  | IC socket, DIP-24 0.3" |  | 0.40 | 7.60 | est.: On Shore ED24DT | Not on the schematic. |
| 2 | U31, U32 |  |  | IC socket, DIP-28 0.3" |  | 0.45 | 0.90 | est.: On Shore ED28DT | Not on the schematic. |
| 1 |  |  |  | Resistor, 10k (/WE pull-up), 1/4 W, axial | 10k | 0.10 | 0.10 | est.: Yageo MFR-25FBF52 | Not on the schematic.  Memory control rev 09 lets go of /WE while RUN is low; not drawn on the schematic yet (EXPANSION.md, "Booting from slot 1") |
| 2 | JP1, JP2 |  |  | Jumper shunt, 2.54 mm |  | 0.10 | 0.20 | est.: 2.54 mm shunt | Not on the schematic.  Bring-up jumpers |

## Cartridge

7 lines, 10 parts on the schematic.

Components: **$61.36** for one board at these quantities.

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 | U1 | ATF22V10C-10PU | Microchip | PLD, 22V10, 10 ns, PDIP-24 0.3" (programmed) |  | 2.63 | 2.63 | Mouser | Cartridge loader U1 |
| 2 | U2, U3 | AT28C256-15PU | Microchip | EEPROM, 32K x 8, 150 ns, PDIP-28 0.6" (programmed) |  | 12.38 | 24.76 | Mouser |  |
| 2 | U4, U5 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  | 15.21 | 30.42 | Mouser |  |
| 5 | C1-C5 |  |  | Ceramic capacitor, 5 mm pitch | 100n | 0.27 | 1.35 | est.: KEMET C320C104K5R5TA |  |
| 1 | U1 |  |  | IC socket, DIP-24 0.3" |  | 0.40 | 0.40 | est.: On Shore ED24DT | Not on the schematic. |
| 2 | U4, U5 |  |  | IC socket, DIP-28 0.3" |  | 0.45 | 0.90 | est.: On Shore ED28DT | Not on the schematic. |
| 2 | U2, U3 |  |  | IC socket, DIP-28 0.6" |  | 0.45 | 0.90 | est.: On Shore ED281DT | Not on the schematic. |

## Keyboard

9 lines, 190 parts on the schematic.

Components: **$145.96** for one board at these quantities.

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 | J1 |  |  | Box header, 2 x 10, 2.54 mm, shrouded and keyed, vertical |  | 0.60 | 0.60 | est.: Wurth 61202021621 |  |
| 63 | SW1-SW63 |  |  | Key switch, Cherry MX style, PCB mount (5 pin) |  | 1.24 | 78.12 | Mouser: Cherry MX2A-L1NB (red, clear housing for the LED, PCB pins), 10+ break; not stocked at Mouser, check Digi-Key | Switch type (color) not chosen; footprints have LED pads 3/4; sizes 1 u, 1.25 u, 1.5 u, 1.75 u, 2 u, 2.25 u, 6.25 u |
| 63 | D1-D63 | BAT85 | Vishay | Schottky diode, DO-35 |  | 0.10 | 6.30 | est.: Vishay BAT85 | Any BAT85 (Vishay, Nexperia, onsemi) |
| 63 | R1-R63 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1k | 0.04 | 2.52 | est.: Yageo MFR-25FBF52 series |  |
| 63 | SW1-SW63 |  |  | LED, 3 mm, through-hole |  | 0.15 | 9.45 | est.: any 3 mm LED, 100 break | Not on the schematic.  Optional, always on; one in each key switch (pads 3 K, 4 A) |
| 63 | SW1-SW63 |  |  | Keycap, Cherry MX stem |  | 0.60 | 37.80 | est.: a full MX keycap set, about $35-40 | Not on the schematic.  Sizes as the key switches |
| 3 | SW6, SW14, SW41 | G99-0742 | Cherry | Stabilizer set, PCB mount, 2 u (also 2.25 u, 2.75 u): 2 housings, 2 sliders, wire |  | 0.39 | 1.17 | Mouser | Not on the schematic.  One complete set per key, ordered as one part (Mouser 540-G99-0742) |
| 1 | SW24 |  | Durock | Stabilizer set, PCB screw-in, 6.25 u: 2 housings, 2 stems, wire, 2 screws, 2 washers |  | 3.50 | 3.50 | Divinikey: Durock V2 screw-in 6.25 u | Not on the schematic.  Durock V2 screw-in, 6.25 u option (keyboard shops, no distributor part number); Cherry sells no 6.25 u PCB set through distributors |
| 1 |  | M3AAA-2006J | 3M | Ribbon cable assembly, 20 way, IDC socket to socket, 2.54 mm, 6 in (152 mm) |  | 6.50 | 6.50 | est.: Digi-Key (3M 20-way assemblies $6-7.50) | Not on the schematic.  Keyboard J1 to main board J1, pre-assembled, pin 1 to pin 1; check on the datasheet that the socket key fits the box header.  Last two digits = length in inches (M3AAA-2018J = 18 in) |
