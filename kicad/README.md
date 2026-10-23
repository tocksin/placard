# KiCad project

The Placard schematic and PCB layout, one KiCad project (made in the KiCad 7
file format, so KiCad 7, 8 and 9 all open it; a newer KiCad upgrades the files
when it saves them).

| File | What it is |
|------|------------|
| `placard.kicad_pro` | the project; open this in KiCad |
| `placard.kicad_sch` | the schematic's root sheet (A3): one box per sheet, laid out like the block diagram |
| `power.kicad_sch` ... `expansion.kicad_sch` | the ten sheets (power and clock, control, PC and address mux, ALU and registers, data bus, memory and I/O decode, video timing, video and audio out, shared port, expansion slots), docs/SCHEMATIC_PLAN.md |
| `cartridge/` | the ROM cartridge, its own project (`cartridge.kicad_pro`, one sheet), using the same `lib/` |
| `keyboard/` | the keyboard board, its own project (`keyboard.kicad_pro`, one sheet: 63 Cherry MX keys, diodes, LEDs), using the same `lib/` |
| `placard.kicad_pcb` | the board: 4 layers (F.Cu, In1.Cu = GND, In2.Cu = VCC, B.Cu) |
| `lib/placard.kicad_sym` | PLD symbols: `ATF22V10C` (generic) and one `ATF22V10C_<name>` per `.pld` file, with its pin names |
| `lib/placard_parts.kicad_sym` | other project symbols: `AS7C256C` SRAM, `Expansion_Slot`, `Cartridge_Slot`, `SNES_Pad_Socket`, `Keyboard_Header`, `PS2_Dual_Stacked`, `USB_C_Power` |
| `lib/placard_std.kicad_sym` | copies of the stock KiCad symbols the sheets use (74xx, R, C, D, connectors, regulator) with larger pin text, written by `src/scripts/gen_kicad_std.py` |
| `lib/placard.pretty/` | project footprints: `SW_Cherry_MX_LED_<size>u_PCB` key switches with LED pads and stabilizer holes (written by `src/scripts/gen_kicad_keyswitch.py`), and the main board's connectors and switches (preliminary, written by `src/scripts/gen_kicad_connectors.py`) |
| `sym-lib-table`, `fp-lib-table` | point KiCad at the project libraries |
| `fab/` | Gerbers, drill files, BOM and placement files for a board order |

The board is 290 x 140 mm (the keyboard's width), 4 layers, with the
outline, dimensions, user connectors, cartridge slot, expansion slots,
keyboard header and mounting holes placed by `src/scripts/gen_kicad_pcb.py`
(run with `python3.12`, which KiCad 7's Python module is built for; `--png`
also draws [docs/placard_board_layout.png](../docs/placard_board_layout.png)).
The back edge carries USB-C power, headphones, VGA and the stacked PS/2;
the left side the power switch, reset button and SD card; the right side
the two SNES ports.  The cartridge and the four expansion cards stand up
through the case top in the back 75 mm, behind the keyboard, which lies over
the front 65 mm.  Rerunning the script moves only the parts it places.
It also places every other part as a fit test, unrouted
([docs/placard_placement.png](../docs/placard_placement.png)): four rows of
socketed chips under the keyboard, memory and video chips behind it, every
DIP on KiCad's `_Socket` footprint with 2.5 mm of chip-puller room clear past
each socket end, Cn beside Un, and the script reports courtyard overlaps
(KiCad DRC) and puller-room conflicts.
The footprints KiCad has no part for (cartridge slot, expansion slots,
PS/2, SNES, the two switches) are written by
`src/scripts/gen_kicad_connectors.py` from typical dimensions and are
preliminary: check their holes against the datasheets before ordering.
The sheet plan (which chips go on which sheet, and the nets between
them) is [docs/SCHEMATIC_PLAN.md](../docs/SCHEMATIC_PLAN.md).  Parts and U-numbers come from
[docs/CHIPS.md](../docs/CHIPS.md); the PLD pinouts come from the `.pld` files
in `src/`.

Every part carries Manufacturer and MPN fields (empty where no part number
is chosen yet), set from the `MPN` table in `src/scripts/gen_kicad_schematic.py`,
so KiCad's BOM export lists them.  `src/scripts/gen_bom.py` writes the grouped
bill of materials for all three boards, [docs/BOM.md](../docs/BOM.md) and
`docs/BOM.csv`, including the sockets and keyboard parts that are not on the
schematic.

Backups, autosaves, lock files, `*.kicad_prl` (per-user view settings) and
`fp-info-cache` are git-ignored.

## PLD symbols

`src/scripts/gen_kicad_symbols.py` writes `lib/placard.kicad_sym` from the
`PIN` statements in `src/pld/*.pld`; rerun it after changing a PLD's pins
(it overwrites the whole library).  The pins are placed for the schematic,
not in pin-number order: the script's `LAYOUT` table puts inputs on the
left and outputs on the right, buses together in bit order, and each
function's pins in their own group.  Where one PLD does two unrelated jobs
(the audio PLD's /AC_SEL, the port PLD's pad read, the memory control's
RUN input) a dashed line across the box separates them.  Active-low pins are
`/NAME`, VCC (24) is on top and GND (12) underneath, unused pins are `nc`
(no-connect type), and the `.pld` file name is under the part number.  The
script stops if a `.pld`'s pins and its `LAYOUT` entry no longer match.
Each symbol has the footprint `Package_DIP:DIP-24_W7.62mm` and the
ATF22V10C datasheet link.

## Other symbols

`src/scripts/gen_kicad_parts.py` writes `lib/placard_parts.kicad_sym`, in
the same style, for the parts KiCad's libraries do not have: the AS7C256C
SRAM, the expansion slot (2 x 20 card edge, contacts A1-A20 and B1-B20)
and the cartridge slot (Molex 87715-9106, 2 x 32 keyed, contacts A1-A32
and B1-B32), as in EXPANSION.md, with the +5 V and GND contacts stacked on
one pin each, the SNES pad socket, the keyboard header (IO.md) and
`USB_C_Power`, the 5 V input: a power-only 6-contact USB-C receptacle
(GCT USB4125, footprint `placard:USB_C_Receptacle_GCT_USB4125_6P_HandSolder`:
KiCad's USB4125 footprint with the SMD pads 1.5 mm longer for the iron, made by gen_kicad_connectors.py)
with a 5.1k resistor from CC1 and from CC2 to GND so a charger gives 5 V.  Make
changes in the script, since rerunning it overwrites the library.

Everything else comes from KiCad's own libraries:

| Part | KiCad symbol |
|---|---|
| SN74F377AN | `74xx:74LS377` |
| SN74F541N | `74xx:74LS541` |
| CD74ACT273E | `74xx:74HC273` |
| SN74HCT574N, SN74HC574N | `74xx:74HCT574` |
| 25.175 MHz oscillator | `Oscillator:ACO-xxxMHz` |
| 3.3 V regulator (MCP1700-3302E/TO) | `Regulator_Linear:MCP1700x-330xxTO` |
| VGA | `Connector:DE15_Receptacle_HighDensity_MountingHoles` |
| SD socket | `Connector:SD_Card` |
| Headphones | `Connector_Audio:AudioJack3` |
| Pull-up arrays | `Device:R_Network08` |

Set the Value to the real part number when placing them.
`src/scripts/render_kicad_symbols.py OUTDIR` draws all of these as PNG
review sheets (needs kicad-cli, cairosvg and Pillow).

## Schematic sheets

`src/scripts/gen_kicad_schematic.py` writes all the `.kicad_sch` files
(main board and cartridge) from its pin-by-pin net lists, so change a
connection there and rerun it; a hand edit in KiCad is lost at the next
run.  Nets with two or more pins on a sheet are wired by the small router in
`src/scripts/kicad_route.py`, and numbered groups (`D0`-`D7`, ...) are drawn
as one bus per sheet (docs/SCHEMATIC_PLAN.md, "How the sheets are drawn").
`--check` compares KiCad's exported netlist with the script's nets and
runs basic electrical checks; the full ERC needs KiCad 8 or newer (open the
project, Inspect > Electrical Rules Checker).  PDFs of both are in
[`../schematics/`](../schematics/).
