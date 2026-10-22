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

## Main board

51 lines, 158 parts on the schematic.

| Qty | References | Part number | Manufacturer | Description | Value | Notes |
|--:|---|---|---|---|---|---|
| 12 | U1, U5-U12, U15, U17, U38 | ATF22V10C-7PX | Microchip | PLD, 22V10, 7.5 ns, PDIP-24 0.3" (programmed) |  | State U1; ALU U5, U6; Address mux U7-U10; Memory control U11; I/O decode U12; Sync U15; Instruction register U17; Shared port U38 |
| 7 | U2-U4, U13, U14, U16, U35 | ATF22V10C-10PU | Microchip | PLD, 22V10, 10 ns, PDIP-24 0.3" (programmed) |  | Branch U2; PC U3, U4; H counter U13; V counter U14; Color decoder U16; Audio slot U35 |
| 6 | U18-U23 | SN74F377AN | Texas Instruments | Octal D flip-flop with enable, 74F, DIP-20 |  |  |
| 1 | U25 | CD74ACT273E | Texas Instruments | Octal D flip-flop with clear, 74ACT, DIP-20 |  |  |
| 4 | U26, U27, U29, U39 | SN74F541N | Texas Instruments | Octal buffer, 3-state, 74F, DIP-20 |  |  |
| 2 | U31, U32 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  |  |
| 1 | U36 | SN74HCT574N | Texas Instruments | Octal D flip-flop, 3-state, 74HCT, DIP-20 |  |  |
| 1 | U37 | SN74HC574N | Texas Instruments | Octal D flip-flop, 3-state, 74HC, DIP-20 |  |  |
| 1 | U40 | MCP1700-3302E/TO | Microchip | 3.3 V LDO regulator, 250 mA, TO-92 |  |  |
| 1 | X1 |  |  | Clock oscillator, 25.175 MHz, 5 V, full-size DIP-14 can | 25.175 MHz | Not chosen yet |
| 1 | J1 |  |  | Box header, 2 x 10, 2.54 mm, shrouded and keyed, vertical |  |  |
| 2 | J2, J3 |  |  | SNES controller socket, 7 pin | SNES pad |  |
| 1 | J4 |  |  | SD card socket | SD (SPI) |  |
| 1 | J5 | KMDGX-6S/6S-S4N | Kycon | Stacked dual mini-DIN-6 receptacle (PS/2), right angle, shielded: mouse top, keyboard bottom | PS/2 kbd + mouse |  |
| 1 | J6 |  |  | 3.5 mm stereo headphone jack | 3.5 mm |  |
| 1 | J7 |  |  | DE-15 high-density receptacle (VGA), with mounting holes | VGA |  |
| 1 | J8 | 87715-9106 | Molex | Cartridge slot: card edge, 64 contacts, 1.0 mm, keyed (PCIe x4 style), vertical TH |  |  |
| 4 | J9-J12 |  |  | Expansion slot: 2 x 20 card-edge socket, 0.1", 1.6 mm card, TH |  | Candidate: Sullins EBC20DCAN family, not stock-checked (EXPANSION.md) |
| 1 | J13 | USB4125-GF-A | GCT | USB-C receptacle, power only (6 pin), top mount |  |  |
| 1 | SW1 | ANT11TFHQE | CIT Relay and Switch | Power on/off: SPDT on-on toggle, 5 A 28 V DC, right-angle PCB, 1/4-40 bushing |  |  |
| 1 | SW2 | E112SD1A3QE | C&K | Reset: SPDT momentary pushbutton, NC contact used, 4 A 28 V DC, right-angle PCB |  |  |
| 1 | F1 | MF-RG300 | Bourns | Polyfuse, 3 A hold, radial | 3 A hold | Part number from the footprint (Fuse_Bourns_MF-RG300) |
| 6 | D1-D6 | BAT85 | Vishay | Schottky diode, DO-35 |  | Any BAT85 (Vishay, Nexperia, onsemi) |
| 2 | R1, R2 |  |  | Resistor, metal film 1%, 1/4 W, axial | 5.1k |  |
| 7 | R3, R4, R13, R39-R41, R48 |  |  | Resistor, metal film 1%, 1/4 W, axial | 10k |  |
| 8 | R5-R12 |  |  | Resistor, metal film 1%, 1/4 W, axial | 47 |  |
| 2 | R14, R17 |  |  | Resistor, metal film 1%, 1/4 W, axial | 3.24k |  |
| 2 | R15, R18 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1.69k |  |
| 2 | R16, R19 |  |  | Resistor, metal film 1%, 1/4 W, axial | 825 |  |
| 1 | R20 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1.43k |  |
| 1 | R21 |  |  | Resistor, metal film 1%, 1/4 W, axial | 715 |  |
| 1 | R22 |  |  | Resistor, metal film 1%, 1/4 W, axial | 2.2 |  |
| 9 | R23-R31 |  |  | Resistor, metal film 1%, 1/4 W, axial | 2k |  |
| 11 | R32-R38, R51-R54 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1k |  |
| 3 | R42-R44 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1.8k |  |
| 3 | R45-R47 |  |  | Resistor, metal film 1%, 1/4 W, axial | 3.3k |  |
| 3 | R49, R50, R55 |  |  | Resistor, metal film 1%, 1/4 W, axial | 4.7k |  |
| 1 | RN1 |  |  | Resistor network, 8 bussed, SIP-9 | 10k |  |
| 1 | RN2 |  |  | Resistor network, 8 bussed, SIP-9 | 4.7k |  |
| 35 | C1-C23, C25-C27, C29, C31, C32, C35-C39, C43 |  |  | Ceramic capacitor, 5 mm pitch | 100n |  |
| 2 | C40, C42 |  |  | Ceramic capacitor, 5 mm pitch | 1u |  |
| 1 | C41 |  |  | Electrolytic capacitor, radial 8.0 mm, 3.50 mm pitch | 220u 10V |  |
| 1 | C44 |  |  | Electrolytic capacitor, radial 6.3 mm, 2.50 mm pitch | 220u |  |
| 1 | C45 |  |  | Ceramic capacitor, 5 mm pitch | 15n C0G |  |
| 1 | C46 |  |  | Ceramic capacitor, 5 mm pitch | 22u |  |
| 2 | JP1, JP2 |  |  | Pin header, 1 x 2, 2.54 mm (bring-up jumper) |  |  |
| 1 | X1 |  |  | IC socket, DIP-14 0.3" |  | Not on the schematic.  Or a 4-pin oscillator socket |
| 13 | U18-U23, U25-U27, U29, U36, U37, U39 |  |  | IC socket, DIP-20 0.3" |  | Not on the schematic. |
| 19 | U1-U17, U35, U38 |  |  | IC socket, DIP-24 0.3" |  | Not on the schematic. |
| 2 | U31, U32 |  |  | IC socket, DIP-28 0.3" |  | Not on the schematic. |
| 2 | JP1, JP2 |  |  | Jumper shunt, 2.54 mm |  | Not on the schematic.  Bring-up jumpers |

## Cartridge

7 lines, 10 parts on the schematic.

| Qty | References | Part number | Manufacturer | Description | Value | Notes |
|--:|---|---|---|---|---|---|
| 1 | U1 | ATF22V10C-10PU | Microchip | PLD, 22V10, 10 ns, PDIP-24 0.3" (programmed) |  | Cartridge loader U1 |
| 2 | U2, U3 | AT28C256-15PU | Microchip | EEPROM, 32K x 8, 150 ns, PDIP-28 0.6" (programmed) |  |  |
| 2 | U4, U5 | AS7C256C-15PCN | Alliance Memory | SRAM, 32K x 8, 15 ns, PDIP-28 0.3" |  |  |
| 5 | C1-C5 |  |  | Ceramic capacitor, 5 mm pitch | 100n |  |
| 1 | U1 |  |  | IC socket, DIP-24 0.3" |  | Not on the schematic. |
| 2 | U4, U5 |  |  | IC socket, DIP-28 0.3" |  | Not on the schematic. |
| 2 | U2, U3 |  |  | IC socket, DIP-28 0.6" |  | Not on the schematic. |

## Keyboard

9 lines, 190 parts on the schematic.

| Qty | References | Part number | Manufacturer | Description | Value | Notes |
|--:|---|---|---|---|---|---|
| 1 | J1 |  |  | Box header, 2 x 10, 2.54 mm, shrouded and keyed, vertical |  |  |
| 63 | SW1-SW63 |  |  | Key switch, Cherry MX style, PCB mount (5 pin) |  | Switch type (color) not chosen; footprints have LED pads 3/4; sizes 1 u, 1.25 u, 1.5 u, 1.75 u, 2 u, 2.25 u, 6.25 u |
| 63 | D1-D63 | BAT85 | Vishay | Schottky diode, DO-35 |  | Any BAT85 (Vishay, Nexperia, onsemi) |
| 63 | R1-R63 |  |  | Resistor, metal film 1%, 1/4 W, axial | 1k |  |
| 63 | SW1-SW63 |  |  | LED, 3 mm, through-hole |  | Not on the schematic.  Optional, always on; one in each key switch (pads 3 K, 4 A) |
| 63 | SW1-SW63 |  |  | Keycap, Cherry MX stem |  | Not on the schematic.  Sizes as the key switches |
| 3 | SW6, SW14, SW41 | G99-0742 | Cherry | Stabilizer set, PCB mount, 2 u (also 2.25 u, 2.75 u): 2 housings, 2 sliders, wire |  | Not on the schematic.  One complete set per key, ordered as one part (Mouser 540-G99-0742) |
| 1 | SW24 |  | Durock | Stabilizer set, PCB screw-in, 6.25 u: 2 housings, 2 stems, wire, 2 screws, 2 washers |  | Not on the schematic.  Durock V2 screw-in, 6.25 u option (keyboard shops, no distributor part number); Cherry sells no 6.25 u PCB set through distributors |
| 1 |  | M3AAA-2006J | 3M | Ribbon cable assembly, 20 way, IDC socket to socket, 2.54 mm, 6 in (152 mm) |  | Not on the schematic.  Keyboard J1 to main board J1, pre-assembled, pin 1 to pin 1; check on the datasheet that the socket key fits the box header.  Last two digits = length in inches (M3AAA-2018J = 18 in) |
