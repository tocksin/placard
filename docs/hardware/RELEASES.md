# Board releases

Date: 2026-11-06

Board revisions use letters from A (skipping I, O, Q, S, X, Z). The letter is
in each board's title block, on its silkscreen ("PLC-100x REV n"), in the
schematic title blocks and on the bare-PCB line of the BOMs.

## Rev A (ordered 2026-11-06)

Git tag `rev-A` on main commit `e4799a7` (merge of PR #262). Everything in
that commit is the design as ordered: board files, schematics, BOMs and the
fab outputs in `kicad/fab/`.

| Board | Part numbers | Board file | Ordered | Gerber zip (SHA-1) |
|---|---|---|---|---|
| Main board | PCB PLC-1001, assembly PLC-2001 | `kicad/placard.kicad_pcb` | yes | `placard_main_gerbers.zip` `4f975d66142b251a5e752421ac863c41b1a99c54` |
| ROM cartridge, 32K | PCB PLC-1002, assembly PLC-2002 | `kicad/cartridge_32k/cartridge_32k.kicad_pcb` | yes | `placard_cart32k_gerbers.zip` `1ab318145ab561f18fc52649f5f901d40ca46b22` |
| ROM cartridge, 64K | PCB PLC-1003, assembly PLC-2003 | `kicad/cartridge_64k/cartridge_64k.kicad_pcb` | no | `placard_cart64k_gerbers.zip` `3a4db973e88f1fcec0a51de96483cc8b9bb62aff` |

- The Gerber files in each zip are byte-identical to `kicad/fab/<board>/gerber/`
  at the tag (checked 2026-11-06). The zips themselves are git-ignored; copies
  are in the project files (`hardware/fab/`) and on the release page for the
  `rev-A` tag.
- ODB++ zips (SHA-1): main `c0547a759e20bd6f33d692bedb2824b61b626e7f`,
  32K cart `2addf5afebe522911c20f4392b9e1f20df460a44`.
- Main board: kicad-cli 9.0.8, teardrops refilled, DRC with schematic parity
  0 violations, 0 unconnected, 0 parity issues. 32K cart: DRC 0/0/0
  (2026-10-29 export).
- The 64K cart was not ordered. It stays at rev A until it is ordered.

## Rev B (working)

From 2026-11-06 every change to the main board or the 32K cart is rev B. The
working board files, schematics and BOMs on main already say rev B. The fab
files in `kicad/fab/main/` and `kicad/fab/cart32k/` are still the rev A
outputs; regenerate them before ordering rev B.

### Changes since rev A

- (none yet)
