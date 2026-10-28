# Bills of materials

Date: 2026-10-27

One BOM per assembly (Justin, 2026-10-25).  The case assembly takes the built main board as one
line; each cartridge assembly is complete with its shell and screw.  Accessories sold with a kit
(USB-C power supply and cable, SD card, programmer, controllers, keyboard and mouse) are in no BOM:
[KITTING.md](KITTING.md) and [KIT_PRICING.md](KIT_PRICING.md) list them.

| Assembly | BOM | Contents | Cost | Without optional parts | Lines estimated |
|---|---|---|--:|--:|--:|
| Main board assembly | [BOM_MAIN_PCB.md](BOM_MAIN_PCB.md), [.csv](BOM_MAIN_PCB.csv) | Bare PCB, components, sockets | $204.54 | $186.54 | 28 |
| 64K cartridge assembly | [BOM_CART_64K.md](BOM_CART_64K.md), [.csv](BOM_CART_64K.csv) | Bare PCB, components, sockets, shell, screw | $69.62 | $69.62 | 6 |
| 32K cartridge assembly | [BOM_CART_32K.md](BOM_CART_32K.md), [.csv](BOM_CART_32K.csv) | Same, 32K board | $39.67 | $39.67 | 6 |
| Case assembly | [BOM_CASE.md](BOM_CASE.md), [.csv](BOM_CASE.csv) | Main board assembly, tray and plates, acrylic, magnets, standoffs, screws, feet | $349.24 | $349.24 | 14 |

A complete machine is the case assembly plus one cartridge: **$418.86** with the 64K cartridge (the case total already holds the main board without its optional slot
sockets).  Prices are single-unit Mouser (Digi-Key where Mouser has none) for components and
rough single-unit estimates for PCBs, shells and case parts; shipping, tax and tariffs are not
included.  Stock moves, so recheck before ordering.

Parts with the same part number share a line; where no part number is chosen the column is
blank and parts with the same description and value share the line.  Lines marked "not on the
schematic" are bare PCBs, sockets, shunts, shells and screws that KiCad's BOM export leaves out.
The net tie NT1 and the cartridges' edge fingers (their J1) are copper on the PCB, so they are
not listed.  Every PLD is an ATF22V10C-7PX ([CHIPS.md](CHIPS.md#pld-speed-grades)); the notes
give each PLD's job;
[KITTING.md](KITTING.md) lists the images.

Written by `src/scripts/gen_bom.py` from the KiCad sheets (part numbers are the Manufacturer and
MPN fields set by `gen_kicad_schematic.py`) and the case parts in CASE.md.  Rerun both after a
part change.
