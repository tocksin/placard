# Fabrication files

Generated 2026-10-27 with kicad-cli 9.0.6 from copies of the board files
(the boards themselves were not changed). Zone fills are the ones saved in
each .kicad_pcb; kicad-cli 9.0.6 has no refill option, so refill (B) and save
in pcbnew before regenerating if a board was edited after its last fill.

| Folder | Board | Size (mm) | Layers |
|---|---|---|---|
| `main/` | `kicad/placard.kicad_pcb` | 290 x 290 | 4, 1.6 mm |
| `cart32k/` | `kicad/cartridge_32k/cartridge_32k.kicad_pcb` | 39.1 x 66.1 | 4, 1.57 mm |
| `cart64k/` | `kicad/cartridge_64k/cartridge_64k.kicad_pcb` | 39.1 x 102.25 | 4, 1.57 mm |

Each folder holds `gerber/` (the files to zip and upload) and `drc.rpt`.
The upload zips (`placard_<board>_gerbers.zip`, Gerber files at the zip root)
and the ODB++ zips (`placard_<board>_odb.zip`) are git-ignored; copies are
in the project files under `hardware/fab/`.

## Gerber and drill settings

- Gerber RS-274X with X2 attributes, Protel extensions (.gtl .gbl .gto .gbo
  .gts .gbs .gtp .gbp .gm1; inner layers .g1 = In1 GND, .g2 = In2 VCC),
  soldermask subtracted from silkscreen, plus a Gerber job file (.gbrjob).
- Drill: Excellon, mm, decimal zeros, absolute origin, oval holes in
  alternate (G85) mode, PTH and NPTH in separate files, drill maps in Gerber X2.
- These settings match the JLCPCB and PCBWay KiCad guides, so one zip works
  for both.

## Ordering notes

- Upload the Gerber zip to JLCPCB or PCBWay. Both quote and check
  Gerber + Excellon zips; the ODB++ zip is for fabs or assembly houses that
  ask for it.
- Cartridges: the edge fingers mate with a Molex 87715-9106 (PCIe style)
  slot, so order 1.6 mm (1.57) thickness with gold fingers (hard gold / ENIG)
  and a 45 degree finger bevel.
- DRC (all three boards): 0 unconnected pads, 0 clearance or zone errors.
  The only warnings are "footprint library 'placard' not in the
  configuration", because kicad-cli was run without the project's
  fp-lib-table; they do not affect the copper.
