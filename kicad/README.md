# KiCad project

The Placard schematic and PCB layout, one KiCad project (made in the KiCad 7
file format, so KiCad 7, 8 and 9 all open it; a newer KiCad upgrades the files
when it saves them).

| File | What it is |
|------|------------|
| `placard.kicad_pro` | the project; open this in KiCad |
| `placard.kicad_sch` | the schematic (root sheet, A3) |
| `placard.kicad_pcb` | the board: 4 layers (F.Cu, In1.Cu = GND, In2.Cu = VCC, B.Cu) |
| `lib/placard.kicad_sym` | project symbols (the PLDs with their pin names, etc.) |
| `lib/placard.pretty/` | project footprints (card-edge slots, cartridge, etc.) |
| `sym-lib-table`, `fp-lib-table` | point KiCad at the two project libraries |
| `fab/` | Gerbers, drill files, BOM and placement files for a board order |

The board outline is a placeholder, 11.4" x 5.5" (keyboard width, 4-layer),
from the size estimate in the project files (`hardware/pcb_size_estimate.md`);
change it once the case is settled.  Parts and U-numbers come from
[docs/CHIPS.md](../docs/CHIPS.md); the PLD pinouts come from the `.pld` files
in `src/`.

Backups, autosaves, lock files, `*.kicad_prl` (per-user view settings) and
`fp-info-cache` are git-ignored.
