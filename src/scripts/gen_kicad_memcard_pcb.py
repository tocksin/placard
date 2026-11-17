#!/usr/bin/env python3
"""
gen_kicad_memcard_pcb.py - write the 512K memory card's board,
kicad/memory_card/memory_card.kicad_pcb: placed and netted, ready for the
router (src/scripts/router_v4/README.md, "Memory card").

    python3 gen_kicad_memcard_pcb.py [--force] [--out FILE] [--place FILE.json]

--out writes another file (the routing flow starts from such a copy) and
--place takes the placement table from a JSON file, to try one out.

Needs KiCad 9's Python module and kicad-cli (the SOJ-36 footprint is a
KiCad 9 file); it uses gen_kicad_cart_pcb.py's helpers.  A board file that already exists is left alone
unless --force is given, since the routed board lives there.

The card is 72 mm wide (EXPANSION.md, "Shell keepouts"), fingers in its
middle, parts on side A.  Card coordinates: x along the fingers from the
card's left edge (seen from side A; the right end is the case's back), y up
from the finger edge.  Bottom to top:

- the fingers
- U3, the SRAM, 2.6 mm above them (short bus stubs with room to fan out), with its 100n, and
  the two M3 holes H1 and H2 that screw the card into its shell
- U1 and U2, the page PLDs, side by side in sockets, each with its 100n

The corner at the right end just above the shoulder is kept clear on side A
for the shell's block that holds the card screw's insert (KEEP).

Date: 2026-11-17
"""

import os
import sys

import pcbnew

import gen_kicad_cart_pcb as cp

DATE = "2026-11-17"
CARD_W = 72.0                # expansion card width (gen_kicad_connectors.EXP_W)
# The placement, in card coordinates.  Parts: (x of the courtyard's centre, y of its bottom edge, angle);
# holes: (x, y) of the centre; top: the card's top edge.
PLACE = {
    "U3": (36.0, 13.0, 90), "C3": (19.0, 14.0, 90),
    "U1": (18.5, 27.6, 90), "C1": (28.1, 38.65, 0),
    "U2": (53.5, 27.6, 90), "C2": (63.1, 38.65, 0),
    "H1": (11.0, 16.5), "H2": (61.0, 16.5),
    "top": 42.7,
}
BOSS_R = 4.75                # the shell's boss round each hole (it holds an M3 nut)
KEEP = (67.0, 8.4, 72.0, 16.5)   # x0, y0, x1, y1: the shell's insert block (and 0.5 mm round it), side A

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


def build(force, out=None, place=None):
    proj = "memory_card"
    pcb = out or os.path.join(cp.KDIR, proj, proj + ".kicad_pcb")
    sch = os.path.join(cp.KDIR, proj, proj + ".kicad_sch")
    if os.path.exists(pcb) and not force:
        print("kept", pcb, "(exists; --force to write it again)")
        return pcb
    P = dict(PLACE)
    P.update(place or {})
    syms = cp.symbols(sch)
    nets = cp.netlist(sch)
    fps = {ref: cp.load(fpid) for ref, (_u, _v, fpid) in syms.items() if fpid}
    holes = {h: fps.pop(h) if h in fps else cp.load(cp.FP_HOLE) for h in ("H1", "H2")}
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
    tb.SetComment(0, "PCB PLC-1004.  Placed by src/scripts/gen_kicad_memcard_pcb.py")

    mid = CARD_W / 2
    fps["J1"].SetPosition(cp.pt(cp.FINGER_X0, cp.EDGE_Y))
    for ref in sorted(fps):
        if ref != "J1":
            cx, y, ang = P[ref]
            cp.put(fps[ref], cx, y, ang)
    # reference texts where the silkscreen is free: inside a socket's outline, beside a top-edge capacitor
    for ref in sorted(fps):
        if ref == "J1":
            continue
        x0, y0, x1, y1 = cp.crt(fps[ref])
        t = fps[ref].Reference()
        if ref in ("U1", "U2"):
            t.SetPosition(cp.pt((x0 + x1) / 2, (y0 + y1) / 2 + 1.9))
            t.SetTextAngleDegrees(0)
        elif ref in ("C1", "C2"):
            t.SetPosition(cp.pt(x0 - 1.2, (y0 + y1) / 2))
            t.SetTextAngleDegrees(0)
    top = P["top"]
    HOLE_Y = P["H1"][1]
    HOLE_X = P["H1"][0]
    for ref in ("H1", "H2"):
        holes[ref].SetReference(ref)
        holes[ref].SetValue("M3")
        holes[ref].SetPosition(cp.pt(*P[ref]))
        holes[ref].Reference().SetVisible(False)
    hole_sym = {h: syms[h] for h in holes if h in syms}

    for ref, fp in fps.items():
        uid, value, _ = syms[ref]
        fp.SetReference(ref)
        fp.SetValue(value)
        fp.SetPath(pcbnew.KIID_PATH("/" + uid))
        fp.SetSheetname("")
        fp.SetSheetfile(proj + ".kicad_sch")
        board.Add(fp)
    for ref, h in holes.items():
        if ref in hole_sym:
            h.SetPath(pcbnew.KIID_PATH("/" + hole_sym[ref][0]))
            h.SetSheetname("")
            h.SetSheetfile(proj + ".kicad_sch")
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
    # the back's text sits between the PLDs' pin rows, clear of every pad
    cp.text(board, "B.SilkS", "PLACARD MEMORY 512K", mid, top - 8.7, 2.0, mirror=True)
    cp.text(board, "B.SilkS", "PLC-1004 rev A    side B", mid, top - 11.3, 1.2, mirror=True)
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
             % (P["H1"][0], P["H2"][0], HOLE_Y),
             "Parts on side A (F.Cu fingers = the slot's A row); the right end is the case's back",
             "Placed by src/scripts/gen_kicad_memcard_pcb.py, routed by src/scripts/router_v4 (MEMCARD.md)"]
    for i, s in enumerate(notes):
        cp.text(board, "Cmts.User", s, 0, -8.0 - 3.0 * i, 1.2, just=-1)

    # checks: courtyards on the card body, clear of each other, the bosses and the shell block
    boxes = [(ref, cp.crt(fp)) for ref, fp in fps.items() if ref != "J1"]
    for ref in ("H1", "H2"):
        x, y = P[ref]
        boxes.append((ref, (x - BOSS_R, y - BOSS_R, x + BOSS_R, y + BOSS_R)))
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
    # --out FILE writes a trial board elsewhere; --place FILE.json overrides entries of PLACE (for trying placements)
    args = sys.argv[1:]
    out = args[args.index("--out") + 1] if "--out" in args else None
    place = None
    if "--place" in args:
        import json
        place = json.load(open(args[args.index("--place") + 1]))
    build("--force" in args or out is not None, out, place)
