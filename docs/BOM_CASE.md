# Bill of materials: case assembly

Date: 2026-10-25

The computer in its case: the main board assembly ([BOM_MAIN_PCB.md](BOM_MAIN_PCB.md)) as one line, the case parts from [CASE.md](CASE.md), standoffs, screws and feet.  The cartridge is its own assembly.

16 lines.  Cost: **$432.19** for one assembly at these quantities.  16 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_CASE.csv](BOM_CASE.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  | PLACARD main board | (assembly) | Main board assembly (BOM_MAIN_PCB.md) |  | 186.79 | 186.79 | est.: BOM_MAIN_PCB.md total without the optional expansion slot sockets | Add $18.00 with J9-J12 fitted |
| 1 |  |  |  | Lower shell: 2.0 mm 5052-H32, bent, brushed and anodized, 8 PEM standoffs SO-M3-6 and 3 PEM nuts pressed in |  | 66.25 | 66.25 | est.: CASE.md "Cost estimate", 1 unit, China sheet metal, not quoted | case/lower_shell.step |
| 1 |  |  |  | Upper shell: 2.0 mm 5052-H32, bent, brushed and anodized |  | 66.25 | 66.25 | est.: CASE.md "Cost estimate", 1 unit, China sheet metal, not quoted | case/upper_shell.step |
| 1 |  |  |  | Keyboard rail: 1.5 mm 5052, Z-shaped, 3 PEM nuts (carries the blank) |  | 9.50 | 9.50 | est.: CASE.md "Cost estimate", 1 unit, China sheet metal, not quoted | case/keyboard_rail.step |
| 2 |  |  |  | Cover garage: 1.5 mm 5052 open tray with ears |  | 9.00 | 18.00 | est.: CASE.md "Cost estimate", 1 unit, China sheet metal, not quoted | case/garage_1.step, garage_2.step |
| 1 |  |  |  | Acrylic top: 4 mm clear cast acrylic, 295 x 220 mm, laser cut, 10 magnet holes |  | 35.00 | 35.00 | est.: CASE.md "Cost estimate", 1 unit, laser-cut acrylic, not quoted | case/acrylic_top.step |
| 1 |  |  |  | Keyboard bay blank: 3 mm clear cast acrylic, laser cut |  | 15.00 | 15.00 | est.: CASE.md "Cost estimate", 1 unit, laser-cut acrylic, not quoted | case/keyboard_blank.step.  The bay's use is open since the Cherry MX keyboard was dropped (CASE.md) |
| 4 |  |  |  | Slot cover: 4 mm acrylic plug + 3 mm cap, solvent welded |  | 3.00 | 12.00 | est.: CASE.md "Cost estimate", 1 unit, laser-cut acrylic, not quoted | case/slot_cover.step |
| 1 |  |  |  | Cartridge cover: 4 mm acrylic plug + 3 mm cap, solvent welded |  | 8.00 | 8.00 | est.: CASE.md "Cost estimate", 1 unit, laser-cut acrylic, not quoted | case/cart_cover.step |
| 20 |  |  |  | Disc magnet, N52, 6 x 3 mm (10 in the top, 10 in the cover caps, glued) |  | 0.25 | 5.00 | est.: typical N52 magnet price |  |
| 5 |  |  |  | M3 male-female hex standoff, 27 mm (H1, H2, H6, H7, H8) |  | 0.80 | 4.00 | est.: typical standoff price |  |
| 3 |  |  |  | M3 male-female hex standoff, 11 mm (H3, H4, H5, under the garage ears) |  | 0.50 | 1.50 | est.: typical standoff price |  |
| 3 |  |  |  | M3 male-female hex standoff, 16 mm (H3, H4, H5, over the garage ears) |  | 0.60 | 1.80 | est.: typical standoff price |  |
| 8 |  |  |  | M3 x 8 button head screw, black or stainless (acrylic top) |  | 0.15 | 1.20 | est.: typical screw price |  |
| 6 |  |  |  | M3 x 6 button head screw (keyboard bay blank) |  | 0.15 | 0.90 | est.: typical screw price |  |
| 4 |  |  |  | Rubber foot, 2 mm thin, adhesive |  | 0.25 | 1.00 | est.: typical price |  |
