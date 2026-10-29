# Fabrication files

Generated 2026-10-29 with kicad-cli 9.0.8 from copies of the board files
(the boards themselves were not changed), main board as of PR #178 (rev A).
Zone fills are the ones saved in each .kicad_pcb; kicad-cli 9 has no refill
option, so refill (B) and save in pcbnew before regenerating if a board was
edited after its last fill.

| Folder | Board | Size (mm) | Layers |
|---|---|---|---|
| `main/` | `kicad/placard.kicad_pcb` | 290.1 x 215.1 | 4, 1.6 mm |
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
- DRC (all three boards, run with each project's own rules and footprint
  library; main board uses the PCBWay-margin rules): 0 errors, 0 warnings,
  0 unconnected pads.
- Saved fills checked against a fresh refill: main and 32K identical; the
  64K cart's inner GND and VCC planes have a small stale void (about 1.4 mm
  square, under U4 near 113.5, 138.8 mm) that a refill would close. It is
  harmless (DRC is clean both ways); refill and regenerate to remove it.
