# Archive

Date: 2026-11-11

Drawings the design has moved on from.  They are kept because development
work can be useful later; none of them describes the machine as it is now.
The current drawings are listed in [../README.md](../README.md).

## hardware/

| File | What it was | Replaced by |
|---|---|---|
| `placard_board_layout_290x290_2026-10-23.png` | The first main board outline and connector plan, when the board was 290 x 290 mm, with the keyboard over the front and the SNES ports on the right side (`src/scripts/gen_kicad_pcb.py --png`) | [`../hardware/placard_board_layout.png`](../hardware/placard_board_layout.png), the routed 290 x 215 mm board |
| `placard_placement_290x290_2026-10-23.png` | The fit test on that board: every part placed in six rows of chips, nothing routed | the same, and [`../hardware/placard_board_routing.png`](../hardware/placard_board_routing.png) |
| `cart_placement_32k_2026-10-24.png`, `cart_placement_64k_2026-10-24.png` | Cartridge placement drawings before the boards were routed, with the outline and mounting hole dimensions (39 mm wide, 66.0 and 102.2 mm tall, H1 19.5 mm from the left edge and 25.1 mm above the finger edge, all still right) | [`../hardware/cart_board_32k.png`](../hardware/cart_board_32k.png), [`cart_board_64k.png`](../hardware/cart_board_64k.png) |
| `connector_3d_models_2026-10-23.png` | The first 3D models of the connectors and switches, from when the expansion slots were 2 x 20 edge connectors with mounting ears and the SNES sockets were plain blocks | the models on the board picture |

## schematics/

| File | What it was | Replaced by |
|---|---|---|
| `placard_audio_sketch_2026-10-19.png` | A sketch of the audio circuit drawn before the KiCad schematic (`src/scripts/gen_audio_schematic.py`).  Its part numbers (R12-R29, C3-C6) and PLD revisions are the ones of that day; the timing of one line around the audio read at the bottom is still how it works | sheet 9 of `schematics/placard_main.pdf` ([`placard_video_audio_schematic.png`](../../schematics/placard_video_audio_schematic.png)) |
