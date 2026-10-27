# Bill of materials: case assembly

Date: 2026-10-25

The computer in its case: the main board assembly ([BOM_MAIN_PCB.md](BOM_MAIN_PCB.md)) as one line, the case parts from [CASE.md](CASE.md), standoffs, screws and feet.  The cartridge is its own assembly.

14 lines.  Cost: **$349.24** for one assembly at these quantities.  14 lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in [BOM_CASE.csv](BOM_CASE.csv).  The other BOMs are listed in [BOM.md](BOM.md).

| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | Price from | Notes |
|--:|---|---|---|---|---|--:|--:|---|---|
| 1 |  | PLACARD main board | (assembly) | Main board assembly (BOM_MAIN_PCB.md) |  | 186.54 | 186.54 | est.: BOM_MAIN_PCB.md total without the optional expansion slot sockets | Add $18.00 with J9-J12 fitted |
| 1 |  |  |  | Tray: 2.0 mm 5052-H32, floor with the front and right walls (two bends), black powder coat, 8 PEM standoffs SO-M3-6 pressed in |  | 50.00 | 50.00 | est.: CASE.md "Cost estimate", 1 unit, China sheet metal, not quoted | case/tray.step |
| 1 |  |  |  | Back plate: 2.0 mm 5052-H32, flat with a bottom flange (one bend), black powder coat, 3 PEM nuts |  | 23.00 | 23.00 | est.: CASE.md "Cost estimate", 1 unit, China sheet metal, not quoted | case/back_plate.step |
| 1 |  |  |  | Left plate: 2.0 mm 5052-H32, flat with a bottom flange (one bend), black powder coat, 3 PEM nuts |  | 23.00 | 23.00 | est.: CASE.md "Cost estimate", 1 unit, China sheet metal, not quoted | case/left_plate.step |
| 1 |  |  |  | Acrylic top: 4 mm clear cast acrylic, 295 x 220 mm, laser cut, 10 magnet holes |  | 30.00 | 30.00 | est.: CASE.md "Cost estimate", 1 unit, laser-cut acrylic, not quoted | case/acrylic_top.step |
| 4 |  |  |  | Slot cover: 4 mm acrylic plug + 3 mm cap, solvent welded |  | 3.00 | 12.00 | est.: CASE.md "Cost estimate", 1 unit, laser-cut acrylic, not quoted | case/slot_cover.step |
| 1 |  |  |  | Cartridge cover: 4 mm acrylic plug + 3 mm cap, solvent welded |  | 8.00 | 8.00 | est.: CASE.md "Cost estimate", 1 unit, laser-cut acrylic, not quoted | case/cart_cover.step |
| 20 |  |  |  | Disc magnet, N52, 6 x 3 mm (10 in the top, 10 through the cover caps, glued) |  | 0.25 | 5.00 | est.: typical N52 magnet price |  |
| 10 |  |  |  | Steel disc, 6 x 2 mm, zinc plated (flush in the floor: parking for the covers) |  | 0.10 | 1.00 | est.: typical price |  |
| 8 |  |  |  | M3 male-female hex standoff, 27 mm (H1-H8) |  | 0.80 | 6.40 | est.: typical standoff price |  |
| 8 |  |  |  | M3 x 8 button head screw, black or stainless (acrylic top) |  | 0.15 | 1.20 | est.: typical screw price |  |
| 6 |  |  |  | M3 x 6 countersunk screw (up through the floor into the plates' flanges) |  | 0.15 | 0.90 | est.: typical screw price |  |
| 4 |  |  |  | M3 x 6 button head screw, black (back plate into each expansion card's shell) |  | 0.15 | 0.60 | est.: typical screw price |  |
| 4 |  |  |  | Rubber foot, 16 mm across, 10 mm tall, adhesive (clears the parked covers) |  | 0.40 | 1.60 | est.: typical price |  |
