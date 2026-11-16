#!/usr/bin/env python3
"""
gen_kicad_memcard_pcb.py - write the 512K memory card's board,
kicad/memory_card/memory_card.kicad_pcb: placed and netted, not routed.

    python3.12 gen_kicad_memcard_pcb.py [--force]

Needs KiCad 9's Python module and kicad-cli (the SOJ-36 footprint is a
KiCad 9 file); it uses gen_kicad_cart_pcb.py's helpers.  A board file that already exists is left alone
unless --force is given, since the layout is meant to be finished by hand.

The card is 72 mm wide (EXPANSION.md, "Shell keepouts"), fingers in its
middle, parts on side A.  Card coordinates: x along the fingers from the
card's left edge (seen from side A; the right end is the case's back), y up
from the finger edge.  Bottom to top:

- the fingers
- U3, the SRAM, right above them (shortest bus stubs), with its 100n, and
  the two M3 holes H1 and H2 that screw the card into its shell
- U1 and U2, the page PLDs, side by side in sockets, each with its 100n

The corner at the right end just above the shoulder is kept clear on side A
for the shell's block that holds the card screw's insert (KEEP).

Date: 2026-11-16
"""

import os
import sys

import pcbnew

import gen_kicad_cart_pcb as cp

DATE = "2026-11-16"
CARD_W = 72.0                # expansion card width (gen_kicad_connectors.EXP_W)
HOLE_X = 12.0                # H1 from the left edge, H2 the same from the right
HOLE_Y = 15.5                # both holes above the finger edge
BOSS_R = 4.75                # the shell's boss round each hole (it holds an M3 nut)
KEEP = (65.0, 8.4, 72.0, 17.5)   # x0, y0, x1, y1: the shell's insert block, side A

cp.CARD_W = CARD_W
cp.MID = CARD_W / 2
cp.FINGER_X0 = CARD_W / 2 - 16.5
cp.HOLE_CRTYD = BOSS_R
if int(pcbnew.Version().split(".")[0]) >= 9:
    cp.KICAD_COPY = {}       # KiCad 9 reads placard.pretty's own copies of the stock footprints
    if not hasattr(pcbnew, "DIM_UNITS_MODE_MILLIMETRES"):
        pcbnew.DIM_UNITS_MODE_MILLIMETRES = pcbnew.DIM_UNITS_MODE_MM   # renamed in KiCad 9


def overlap(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def build(force):
    proj = "memory_card"
    pcb = os.path.join(cp.KDIR, proj, proj + ".kicad_pcb")
    sch = os.path.join(cp.KDIR, proj, proj + ".kicad_sch")
    if os.path.exists(pcb) and not force:
        print("kept", pcb, "(exists; --force to write it again)")
        return pcb
    syms = cp.symbols(sch)
    nets = cp.netlist(sch)
    fps = {ref: cp.load(fpid) for ref, (_u, _v, fpid) in syms.items() if fpid}
    holes = {"H1": cp.load(cp.FP_HOLE), "H2": cp.load(cp.FP_HOLE)}
    want = {"J1", "U1", "U2", "U3", "C1", "C2", "C3"}
    if set(fps) != want:
        sys.exit("memory card: schematic parts %s, layout %s" % (sorted(fps), sorted(want)))

    board = pcbnew.NewBoard(pcb)
    board.SetCopperLayerCount(4)
    layers = pcbnew.LSET.AllCuMask(4)
    layers.addLayerSet(pcbnew.LSET.AllTechMask())
    layers.addLayerSet(pcbnew.LSET.UserMask())
    board.SetEnabledLayers(layers)
    board.GetDesignSettings().SetBoardThickness(cp.mm(1.57))
    tb = board.GetTitleBlock()
    tb.SetTitle("PLACARD memory expansion card, 512K")
    tb.SetDate(DATE)
    tb.SetRevision("A")
    tb.SetComment(0, "PCB PLC-1004.  Placed by src/scripts/gen_kicad_memcard_pcb.py; not routed")

    mid = CARD_W / 2
    fps["J1"].SetPosition(cp.pt(cp.FINGER_X0, cp.EDGE_Y))
    # U3 lies along the fingers, pin 1 at the bottom left
    cp.put(fps["U3"], mid, cp.PART_Y0, 90)
    u3 = cp.crt(fps["U3"])
    cp.put(fps["C3"], u3[0] - 5.0, cp.PART_Y0 + 1.0, 90)
    # the PLDs side by side above it
    y = max(u3[3], HOLE_Y + BOSS_R) + 2.0
    for u, c, cx in (("U1", "C1", CARD_W / 4 + 0.5), ("U2", "C2", 3 * CARD_W / 4 - 0.5)):
        cp.put(fps[u], cx, y, 90)
        b = cp.crt(fps[u])
        cp.put(fps[c], b[2] - 6.0, b[3] + 0.25, 0)
    top = max(cp.crt(fps[r])[3] for r in ("C1", "C2")) + cp.TOP_MARGIN
    for ref, x in (("H1", HOLE_X), ("H2", CARD_W - HOLE_X)):
        holes[ref].SetReference(ref)
        holes[ref].SetValue("M3")
        holes[ref].SetPosition(cp.pt(x, HOLE_Y))
        holes[ref].Reference().SetVisible(False)

    for ref, fp in fps.items():
        uid, value, _ = syms[ref]
        fp.SetReference(ref)
        fp.SetValue(value)
        fp.SetPath(pcbnew.KIID_PATH("/" + uid))
        fp.SetSheetname("")
        fp.SetSheetfile(proj + ".kicad_sch")
        board.Add(fp)
    for h in holes.values():
        board.Add(h)
    netinfo = {}
    for ref, fp in fps.items():
        for p in fp.Pads():
            name = nets.get((ref, p.GetNumber()))
            if name is None:
                continue
            if name not in netinfo:
                netinfo[name] = pcbnew.NETINFO_ITEM(board, name)
                board.Add(netinfo[name])
            p.SetNet(netinfo[name])

    cp.outline(board, top)
    cp.text(board, "B.SilkS", "PLACARD MEMORY 512K", mid, top - 4.0, 2.0, mirror=True)
    cp.text(board, "B.SilkS", "PLC-1004 rev A    side B", mid, top - 8.0, 1.2, mirror=True)
    x0, y0, x1, y1 = KEEP
    for a, b in (((x0, y0), (x0, y1)), ((x0, y1), (x1, y1))):
        cp.seg(board, "Cmts.User", a, b)
    cp.text(board, "Cmts.User", "shell", (x0 + x1) / 2, (y0 + y1) / 2, 0.9)
    cp.dim(board, (0, top), (CARD_W, top), -5.0)
    cp.dim(board, (CARD_W, 0), (CARD_W, top), 7.0)
    cp.dim(board, (0, 0), (0, HOLE_Y), -7.0)
    cp.dim(board, (0, HOLE_Y), (HOLE_X, HOLE_Y), 0.0)
    notes = ["PLACARD memory card, 512K: 3 chips, 4 layers, 1.57 mm, %.1f x %.1f mm (finger tab included)" % (CARD_W, top),
             "H1, H2 M3 at x %.1f and %.1f, y %.1f from the finger edge: screws through the shell's back half into nuts in its front half"
             % (HOLE_X, CARD_W - HOLE_X, HOLE_Y),
             "Parts on side A (F.Cu fingers = the slot's A row); the right end is the case's back",
             "Placed and netted by src/scripts/gen_kicad_memcard_pcb.py, not routed"]
    for i, s in enumerate(notes):
        cp.text(board, "Cmts.User", s, 0, -8.0 - 3.0 * i, 1.2, just=-1)

    # checks: courtyards on the card body, clear of each other, the bosses and the shell block
    boxes = [(ref, cp.crt(fp)) for ref, fp in fps.items() if ref != "J1"]
    for ref, x in (("H1", HOLE_X), ("H2", CARD_W - HOLE_X)):
        boxes.append((ref, (x - BOSS_R, HOLE_Y - BOSS_R, x + BOSS_R, HOLE_Y + BOSS_R)))
    boxes.append(("shell block", KEEP))
    problems = []
    for i, (ra, a) in enumerate(boxes):
        if a[1] < cp.TAB_H or a[3] > top or a[0] < 0 or a[2] > CARD_W:
            problems.append("%s off the card body" % ra)
        for rb, b in boxes[i + 1:]:
            if overlap(a, b):
                problems.append("overlap: %s %s" % (ra, rb))
    board.Save(pcb)
    s = open(pcb).read()
    open(pcb, "w", newline="\n").write(s)
    print("wrote %s: %.1f x %.1f mm, %d nets, %d problems%s" % (
        pcb, CARD_W, top, len(netinfo), len(problems), "".join("\n  " + p for p in problems)))
    for ref, b in boxes:
        print("  %-11s x %5.1f..%5.1f  y %5.1f..%5.1f" % (ref, b[0], b[2], b[1], b[3]))
    return pcb


if __name__ == "__main__":
    build("--force" in sys.argv)
