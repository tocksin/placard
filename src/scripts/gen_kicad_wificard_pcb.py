#!/usr/bin/env python3
"""
gen_kicad_wificard_pcb.py - write the WiFi card's board,
kicad/wifi_card/wifi_card.kicad_pcb: placed and netted, not routed.

    python3 gen_kicad_wificard_pcb.py [--force] [--out FILE] [--place FILE.json]

--out writes another file and --place takes entries of the placement table
from a JSON file, to try one out.

Needs KiCad 9's Python module and kicad-cli; it uses
gen_kicad_cart_pcb.py's helpers, as gen_kicad_memcard_pcb.py does.  A board
file that already exists is left alone unless --force is given.

The card is 72 mm wide (EXPANSION.md, "Shell keepouts"), fingers in its
middle, parts on side A.  Card coordinates: x along the fingers from the
card's left edge (seen from side A; the right end is the case's back), y up
from the finger edge.

- U1, the SPI port PLD, stands upright at the left end in a socket, its
  100n beside it
- U2, the WiFi module (an ESP32-C3-DevKitM-1 board on its own pin headers),
  lies along the top of the card: antenna at the right end, toward the
  case's back, USB socket toward the PLD.  No copper under the antenna
  (ANT: a keepout on every copper layer; U2's pins 1 and 16 lie in it and
  are not connected)
- the nine resistors stand in a column between the two, the 220u and the
  M3 holes H1 and H2 under the module

The corner at the right end just above the shoulder is kept clear on side A
for a shell's block that holds the card screw's insert (KEEP), as on the
memory card.  The card has no shell yet.

Date: 2026-11-21
"""

import os
import sys

import pcbnew

import gen_kicad_cart_pcb as cp

DATE = "2026-11-21"
CARD_W = 72.0                # expansion card width (gen_kicad_connectors.EXP_W)
# The placement, in card coordinates.  Parts: (x of the courtyard's centre, y of its bottom edge, angle);
# holes: (x, y) of the centre; top: the card's top edge.
PLACE = {
    "U1": (8.0, 8.9, 0), "C1": (17.5, 9.4, 90),
    "U2": (51.5, 17.3, 270),
    "R1": (24.0, 40.3, 0), "R4": (24.0, 37.1, 0),
    "R2": (24.0, 33.9, 0), "R5": (24.0, 30.7, 0),
    "R3": (24.0, 27.5, 0), "R6": (24.0, 24.3, 0),
    "R9": (24.0, 21.1, 0), "R7": (24.0, 17.9, 0), "R8": (39.0, 13.6, 0),
    "C2": (50.0, 9.0, 0),
    "H1": (25.0, 13.0), "H2": (60.5, 12.6),
    "top": 44.0,
}
KEEP = (67.0, 8.4, 72.0, 16.5)   # x0, y0, x1, y1: a shell's insert block (and 0.5 mm round it), side A
ANT_LEN = 7.7                # no copper this far in from the module's antenna end (footprint: ANT_END + its overhang)

cp.CARD_W = CARD_W
cp.MID = CARD_W / 2
cp.FINGER_X0 = CARD_W / 2 - 16.5
if int(pcbnew.Version().split(".")[0]) >= 9:
    cp.KICAD_COPY = {}       # KiCad 9 reads placard.pretty's own copies of the stock footprints
    if not hasattr(pcbnew, "DIM_UNITS_MODE_MILLIMETRES"):
        pcbnew.DIM_UNITS_MODE_MILLIMETRES = pcbnew.DIM_UNITS_MODE_MM   # renamed in KiCad 9


def overlap(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def keepout(board, box, name):
    """A rule area: no tracks, vias or pours on any copper layer."""
    z = pcbnew.ZONE(board)
    z.SetIsRuleArea(True)
    z.SetDoNotAllowTracks(True)
    z.SetDoNotAllowVias(True)
    if hasattr(z, "SetDoNotAllowZoneFills"):
        z.SetDoNotAllowZoneFills(True)
    else:
        z.SetDoNotAllowCopperPour(True)
    z.SetDoNotAllowPads(False)
    z.SetDoNotAllowFootprints(False)
    z.SetLayerSet(pcbnew.LSET.AllCuMask(4))
    z.SetZoneName(name)
    x0, y0, x1, y1 = box
    o = z.Outline()
    o.NewOutline()
    for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        o.Append(cp.pt(x, y))
    board.Add(z)


def build(force, out=None, place=None):
    proj = "wifi_card"
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
    want = {"J1", "U1", "U2", "C1", "C2"} | {"R%d" % n for n in range(1, 10)}
    if set(fps) != want:
        sys.exit("WiFi card: schematic parts %s, layout %s" % (sorted(fps), sorted(want)))

    board = pcbnew.NewBoard(pcb)
    board.SetCopperLayerCount(4)
    layers = pcbnew.LSET.AllCuMask(4)
    layers.addLayerSet(pcbnew.LSET.AllTechMask())
    layers.addLayerSet(pcbnew.LSET.UserMask())
    board.SetEnabledLayers(layers)
    board.GetDesignSettings().SetBoardThickness(cp.mm(1.57))
    tb = board.GetTitleBlock()
    tb.SetTitle("PLACARD WiFi expansion card")
    tb.SetDate(DATE)
    tb.SetRevision("A")
    tb.SetComment(0, "PCB PLC-1005.  Placed by src/scripts/gen_kicad_wificard_pcb.py; not routed")

    mid = CARD_W / 2
    fps["J1"].SetPosition(cp.pt(cp.FINGER_X0, cp.EDGE_Y))
    for ref in sorted(fps):
        if ref != "J1":
            cx, y, ang = P[ref]
            cp.put(fps[ref], cx, y, ang)
    top = P["top"]
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
            if name is None or name.startswith("unconnected-"):
                continue
            if name not in netinfo:
                netinfo[name] = pcbnew.NETINFO_ITEM(board, name)
                board.Add(netinfo[name])
            p.SetNet(netinfo[name])

    cp.outline(board, top)
    # no copper under the module's antenna: its end of U2's courtyard, ANT_LEN in
    ux0, uy0, ux1, uy1 = cp.crt(fps["U2"])
    ant = (ux1 - 0.5 - ANT_LEN, uy0, CARD_W, top)
    keepout(board, ant, "antenna: no copper")
    cp.text(board, "Cmts.User", "antenna: no copper", (ant[0] + ant[2]) / 2, uy1 + 1.6, 0.9)
    cp.text(board, "B.SilkS", "PLACARD WIFI", 24.0, 13.0 + 6.0, 1.6, mirror=True)
    cp.text(board, "B.SilkS", "PLC-1005 rev A    side B", 44.0, 14.5, 1.2, mirror=True)
    x0, y0, x1, y1 = KEEP
    for a, b in (((x0, y0), (x0, y1)), ((x0, y1), (x1, y1))):
        cp.seg(board, "Cmts.User", a, b)
    cp.text(board, "Cmts.User", "shell", (x0 + x1) / 2, (y0 + y1) / 2, 0.9)
    cp.dim(board, (0, top), (CARD_W, top), -5.0)
    cp.dim(board, (CARD_W, 0), (CARD_W, top), 7.0)
    notes = ["PLACARD WiFi card: 1 PLD and an ESP32-C3-DevKitM-1 board, 4 layers, 1.57 mm, %.1f x %.1f mm (finger tab included)"
             % (CARD_W, top),
             "H1, H2 M3 at (%.1f, %.1f) and (%.1f, %.1f) from the left end and the finger edge, for a shell (none yet)"
             % (P["H1"] + P["H2"]),
             "Parts on side A (F.Cu fingers = the slot's A row); the right end is the case's back",
             "Placed by src/scripts/gen_kicad_wificard_pcb.py; not routed (WIFICARD.md)"]
    for i, s in enumerate(notes):
        cp.text(board, "Cmts.User", s, 0, -8.0 - 3.0 * i, 1.2, just=-1)

    # checks: courtyards on the card body, clear of each other, the holes and the shell block
    boxes = [(ref, cp.crt(fp)) for ref, fp in fps.items() if ref != "J1"]
    for ref in ("H1", "H2"):
        x, y = P[ref]
        r = cp.HOLE_CRTYD
        boxes.append((ref, (x - r, y - r, x + r, y + r)))
    boxes.append(("shell block", KEEP))
    problems = []
    for i, (ra, a) in enumerate(boxes):
        if a[1] < cp.TAB_H or a[3] > top or a[0] < 0 or a[2] > CARD_W:
            problems.append("%s off the card body" % ra)
        for rb, b in boxes[i + 1:]:
            if overlap(a, b):
                problems.append("overlap: %s %s" % (ra, rb))
    # pads under the antenna must be the two left open
    for p in fps["U2"].Pads():
        px, py = p.GetPosition().x / 1e6 - cp.X0, cp.Y0 - p.GetPosition().y / 1e6
        if px > ant[0] and p.GetNetname():
            problems.append("U2 pin %s (%s) is under the antenna" % (p.GetNumber(), p.GetNetname()))
    board.Save(pcb)
    s = open(pcb).read()
    open(pcb, "w", newline="\n").write(s)
    print("wrote %s: %.1f x %.1f mm, %d nets, %d problems%s" % (
        pcb, CARD_W, top, len(netinfo), len(problems), "".join("\n  " + p for p in problems)))
    for ref, b in sorted(boxes):
        print("  %-11s x %5.1f..%5.1f  y %5.1f..%5.1f" % (ref, b[0], b[2], b[1], b[3]))
    return pcb


if __name__ == "__main__":
    args = sys.argv[1:]
    out = args[args.index("--out") + 1] if "--out" in args else None
    place = None
    if "--place" in args:
        import json
        place = json.load(open(args[args.index("--place") + 1]))
    build("--force" in args or out is not None, out, place)
