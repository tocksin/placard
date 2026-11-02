# PLACARD logo

Date: 2026-11-02

The logo is a hand holding up a picket sign tilted 30°, with PLACARD in
the machine's own 8x8 ROM font.  It is drawn by `src/scripts/gen_logo.py`:

| File | Form |
|---|---|
| `f_hand.svg` / `.png` | outline sign |
| `f_hand_solid.svg` / `.png` | solid sign with the letters cut out |

It is on the main board as footprint `placard:PLACARD_Logo` (LOGO1, front
silkscreen, 40 x 48 mm, bottom-right corner at 310, 233.9 mm).  The
footprint is written by the same script, is board-only (no schematic
symbol) and is left out of the BOM and position files.

![on the board](f_hand_on_pcb_closeup.png)

![the logo](f_hand.png)

The SVGs are one color (black), pure filled shapes with no strokes and
the lettering already turned into outlines, so they open anywhere without
fonts and import straight into KiCad.  Change `fill="#000000"` to
recolor.  The PNGs are 1200 px wide previews.
