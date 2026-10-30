# PLACARD case: quote package

Date: 2026-10-30  
Revision: A

Everything a sheet metal service or a laser cutter needs to quote the PLACARD computer case:
three bent aluminium parts and the clear acrylic top and covers. Quote quantities 1, 10 and 100 sets.

## Parts

| Part | Qty per case | Material | Finish | Process | Size (mm) |
|---|--:|---|---|---|---|
| tray | 1 | Aluminium 5052-H32, 2.0 mm (0.080 in) | Black powder coat, stock color, texture or matte, both sides; mask PEM threads | laser cut, 2 bend(s), PEM insertion, powder coat | bent 295.0 x 220.0 x 36.6; flat 328.1 x 253.1 |
| back_plate | 1 | Aluminium 5052-H32, 2.0 mm (0.080 in) | Black powder coat, stock color, texture or matte, both sides; mask PEM threads | laser cut, 1 bend(s), PEM insertion, powder coat | bent 291.0 x 16.0 x 34.6; flat 291.0 x 47.1 |
| left_plate | 1 | Aluminium 5052-H32, 2.0 mm (0.080 in) | Black powder coat, stock color, texture or matte, both sides; mask PEM threads | laser cut, 1 bend(s), PEM insertion, powder coat | bent 16.0 x 218.0 x 34.6; flat 218.0 x 47.1 |
| acrylic_top | 1 | Clear cast acrylic (PMMA), 4 mm, protective film both sides | none | laser cut | 295.0 x 220.0 x 4 |
| slot_cover_plug | 4 | Clear cast acrylic (PMMA), 4 mm, protective film both sides | none | laser cut | 26.3 x 80.8 x 4 |
| slot_cover_cap | 4 | Clear cast acrylic (PMMA), 3 mm, protective film both sides | none | laser cut | 26.3 x 89.0 x 3 |
| cart_cover_plug | 1 | Clear cast acrylic (PMMA), 4 mm, protective film both sides | none | laser cut | 45.6 x 20.9 x 4 |
| cart_cover_cap | 1 | Clear cast acrylic (PMMA), 3 mm, protective film both sides | none | laser cut | 62.0 x 37.2 x 3 |

PARTS.csv has the same list with the hardware and the files for each part.

## Files

- `step/`: 3D models. The tray and plates are bent, with 2.0 mm inside bend radius and corner and end reliefs. The acrylic parts are flat.
- `dxf/`: cutting files in mm. `*_flat.dxf` are the flat patterns of the bent parts: layer CUT is the outline and holes, and layer BEND is the bend lines, at the middle of each bend. All bends go up 90 degrees toward the viewer, with the inside face up.
- `pdf/`: one A3 drawing per part, with the flat pattern, overall sizes, bends, hole sizes, hardware, material, finish and tolerances.

## Sheet metal (tray, back plate, left plate)

- Aluminium 5052-H32, 2.0 mm (0.080 in).
- Four bends in all (two in the tray, one in each plate), each 90 degrees, inside radius 2.0 mm. The flat patterns use K = 0.44 (bend allowance 4.524 mm). Please develop the flat from the STEP with your own bend tables and tell us if anything changes.
- Hardware, pressed by you:
  - Tray: 8 x PEM SO-M3-6 standoffs, pressed from the underside.
  - Each plate: 3 x PEM CLS-M3-1 nuts, pressed from the flange's top face.
  - Equivalent self-clinching parts are fine.
- Tray: 6 countersunk holes, 90 degrees, 6.5 mm on the underside.
- Finish: black powder coat on all three parts, in a stock color, matte or fine texture. Mask the PEM threads. Coat either before or after the PEM insertion, as you prefer.
- No printing, engraving or silkscreen.
- Some cut-outs sit close to a bend, so check them. On the back plate, the bottom of the USB-C cut-out is about 1.8 mm above the bend tangent. On the left plate, the bottom of the SD slot is about 3 mm above it. Tell us if those need moving or cutting after the bend.
- Suggested services:
  - SendCutSend: upload the STEP for bent parts, or the flat DXF for the cut alone.
  - PCBWay sheet metal, Xometry and Protocase: STEP plus the PDF.

## Acrylic (top and covers)

- Clear cast acrylic, 4 mm (the top and the cover plugs) and 3 mm (the cover caps), laser cut from the DXF.
- The 6.1 mm holes take 6 x 3 mm magnets, which we glue in ourselves.
- Per case: 1 top, 4 slot cover plugs and 4 caps, 1 cartridge cover plug and 1 cap.

## Not in this package

- Fasteners, standoffs, magnets, steel discs and feet. We supply those; see docs/BOM_CASE.md in the PLACARD repository.
- The magnet gluing jig, which is tooling made once, is in case/dxf/magnet_jig_*.

Made by `src/scripts/gen_case_quote.py` from the board file. Rerun it after the board or the case changes.
