# PLACARD case: quote package

Date: 2026-10-30  
Revision: A

Everything a sheet metal service or a laser cutter needs to quote the PLACARD computer case:
three bent aluminium parts and the clear acrylic top. Quote quantities 1, 10 and 100 sets.

## Parts

| Part | Qty per case | Material | Finish | Process | Size (mm) |
|---|--:|---|---|---|---|
| tray | 1 | Aluminium 5052-H32, 2.0 mm (0.080 in) | Black powder coat, stock color, texture or matte, both sides | laser cut, bend (press brake), countersink, powder coat | bent 295.0 x 220.0 x 36.6; flat 328.1 x 253.1 |
| back_plate | 1 | Aluminium 5052-H32, 2.0 mm (0.080 in) | Black powder coat, stock color, texture or matte, both sides | laser cut, bend (press brake), powder coat | bent 291.0 x 16.0 x 34.6; flat 291.0 x 47.1 |
| left_plate | 1 | Aluminium 5052-H32, 2.0 mm (0.080 in) | Black powder coat, stock color, texture or matte, both sides | laser cut, bend (press brake), powder coat | bent 16.0 x 218.0 x 34.6; flat 218.0 x 47.1 |
| acrylic_top | 1 | Clear cast acrylic (PMMA), 4 mm, protective film both sides | none | laser cut | 295.0 x 220.0 x 4 |

PARTS.csv has the same list with the hardware and the files for each part.

## Files

- `step/`: 3D models. The tray and plates are bent, with 2.0 mm inside bend radius and corner and end reliefs. The acrylic top is flat.
- `dxf/`: cutting files in mm. `*_flat.dxf` are the flat patterns of the bent parts: layer CUT is the outline and holes, and layer BEND is the bend lines, at the middle of each bend. All bends go up 90 degrees toward the viewer, with the inside face up.
- `pdf/`: one A3 drawing per part, with the flat pattern, overall sizes, bends, hole sizes, hardware, material, finish and tolerances.

## Sheet metal (tray, back plate, left plate)

- Aluminium 5052-H32, 2.0 mm (0.080 in).
- Four bends in all (two in the tray, one in each plate), each 90 degrees, inside radius 2.0 mm. The flat patterns use K = 0.44 (bend allowance 4.524 mm). Please develop the flat from the STEP with your own bend tables and tell us if anything changes.
- No PEM or other pressed hardware in any part. Each plate's flange has 3 plain 3.4 mm holes.
- Tray: 14 countersunk holes, 90 degrees, 6.5 mm on the underside.
- Finish: black powder coat on all three parts, in a stock color, matte or fine texture. Mask the tray's 14 countersinks.
- No printing, engraving or silkscreen.
- Some cut-outs sit close to a bend, so check them. On the back plate, the bottom of the USB-C cut-out is about 1.8 mm above the bend tangent. On the left plate, the bottom of the SD slot is about 3 mm above it. Tell us if those need moving or cutting after the bend.
- Suggested services:
  - SendCutSend: upload the STEP for bent parts, or the flat DXF for the cut alone.
  - PCBWay sheet metal, Xometry and Protocase: STEP plus the PDF.

## Acrylic (top)

- Clear cast acrylic, 4 mm, laser cut from the DXF. One per case.
- The 14 small slots (6.4 x 2.2 mm) take the covers' snap tabs, so keep them to size.

## Not in this package

- The slot and cartridge covers, which are 3D printed (case/slot_cover.stl, case/cart_cover.stl).
- Fasteners, standoffs and feet. We supply those; see docs/BOM_CASE.md in the PLACARD repository.

Made by `src/scripts/gen_case_quote.py` from the board file. Rerun it after the board or the case changes.
