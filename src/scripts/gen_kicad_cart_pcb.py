#!/usr/bin/env python3
"""
gen_kicad_cart_pcb.py - write the two ROM cartridge boards,
kicad/cartridge_32k/cartridge_32k.kicad_pcb and
kicad/cartridge_64k/cartridge_64k.kicad_pcb, and their placement drawings
docs/cart_placement_32k.png and docs/cart_placement_64k.png.

    python3.12 gen_kicad_cart_pcb.py [--force] [--png]

Needs KiCad 7's Python module (apt-get install kicad kicad-footprints; on
Ubuntu 24.04 it is built for python3.12), kicad-cli, and for --png cairosvg.

Two boards instead of one with a 32K/64K jumper (Justin, 2026-10-24):

- 64K: U1 loader PLD, U2/U3 AT28C256, U4/U5 AS7C256C (5 chips)
- 32K: U1 loader PLD, U2 AT28C256, U3 AS7C256C (3 chips), /CE tied to GND

Both are 39 mm wide (J8's body), 2 layers, 1.57 mm, with the chips lying
horizontally (long side along the fingers), stacked, socketed (kit socket
footprints with chip-puller room on User.Eco1; the puller room may hang past
the card edge).  Bottom to top: the fingers, U1, the case mounting hole H1,
the SRAMs, the EEPROMs (on top, easiest to take out).  H1 sits in the gap
right above U1, so it is at the same place on both boards: one shell design
screws to either card.  Each chip's 100n disc is in the gap above it, at the
right.

The board is placed and the nets are filled in from the schematic (the
footprints are linked to their symbols, as Update PCB from Schematic would
link them); nothing is routed.  A board file that already exists is left
alone unless --force is given, since the layout is meant to be finished by
hand in KiCad.

Card coordinates here: x along the fingers from the card's left edge, y up
from the finger edge; the KiCad file has the fingers at the bottom.

Date: 2026-10-24
"""

import os
import re
import subprocess
import sys
import tempfile

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_kicad_connectors as gc  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
KDIR = os.path.join(ROOT, "kicad")
DOCS = os.path.join(ROOT, "docs")
STOCK = os.environ.get("KICAD7_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
LIBS = {"placard": os.path.join(KDIR, "lib", "placard.pretty")}
DATE = "2026-10-24"

CARD_W = gc.CART_W           # 39 mm: the J8 body; the shell's skirt goes round it
TAB_H = 8.4                  # finger tab, edge to shoulder (KiCad's PCIe card: key notch to the shoulder)
PART_Y0 = TAB_H + 2.0        # lowest part edge: 2 mm above the shoulder, clear of the slot top
ROW_GAP = 3.5                # courtyard to courtyard between rows: room for the row's 100n disc
TOP_MARGIN = 1.0             # top courtyard to the card's top edge
HOLE_CRTYD = 3.45            # MountingHole_3.2mm_M3 courtyard radius: screw head / shell boss
HOLE_GAP = 2 * HOLE_CRTYD + 1.0   # the row gap that holds H1 (0.5 mm to each row's courtyard)
MID = CARD_W / 2             # the card is centred on the middle of J8's contacts
FINGER_X0 = MID - 16.5       # contact 1
EDGE_Y = 3.45                # the finger edge in the fingers footprint (Card_Edge_87715-9106)
X0, Y0 = 100.0, 200.0        # the card's bottom left corner (finger edge level) on the KiCad page

FP_HOLE = "MountingHole:MountingHole_3.2mm_M3"
FP_CAP = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"

# bottom (next to the fingers) to top: chip, its decap
BUILDS = {
    64: [("U1", "C1"), ("U4", "C4"), ("U5", "C5"), ("U2", "C2"), ("U3", "C3")],
    32: [("U1", "C1"), ("U3", "C3"), ("U2", "C2")],
}


LAYER = {"Edge.Cuts": pcbnew.Edge_Cuts, "B.SilkS": pcbnew.B_SilkS, "Cmts.User": pcbnew.Cmts_User,
         "Dwgs.User": pcbnew.Dwgs_User}


def mm(v):
    return pcbnew.FromMM(v)


def pt(x, y):
    """Card coordinates (y up from the finger edge) to a KiCad point."""
    return pcbnew.VECTOR2I(mm(X0 + x), mm(Y0 - y))


def load(fpid):
    lib, name = fpid.split(":")
    fp = pcbnew.FootprintLoad(LIBS.get(lib, os.path.join(STOCK, lib + ".pretty")), name)
    if fp is None:
        sys.exit("footprint not found: " + fpid)
    fp.SetFPID(pcbnew.LIB_ID(lib, name))
    return fp


def symbols(sch):
    """Reference -> (uuid, value, footprint) from a one-sheet schematic."""
    out = {}
    for m in re.finditer(r'^  \(symbol \(lib_id "[^"]+"\).*?\(uuid ([0-9a-f-]+)\) \(property "Reference" "([^"#]+)"'
                         r'.*?\(property "Value" "([^"]*)".*?\(property "Footprint" "([^"]*)"',
                         open(sch).read(), re.M | re.S):
        out[m.group(2)] = (m.group(1), m.group(3), m.group(4))
    return out


def netlist(sch):
    """(ref, pin) -> net name, from kicad-cli's netlist."""
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "n.net")
        subprocess.run(["kicad-cli", "sch", "export", "netlist", "-o", out, sch], check=True, capture_output=True)
        src = open(out).read()
    nets = {}
    for m in re.finditer(r'\(net \(code "\d+"\) \(name "((?:[^"\\]|\\.)*)"\)(.*?)\)\s*(?=\(net |\)\s*\)\s*$)', src, re.S):
        for n in re.finditer(r'\(node \(ref "([^"]+)"\) \(pin "([^"]+)"\)', m.group(2)):
            nets[(n.group(1), n.group(2))] = m.group(1)
    return nets


def crt(fp):
    """Courtyard (x0, y0, x1, y1) in card coordinates."""
    xs, ys = [], []
    for g in fp.GraphicalItems():
        if g.GetLayer() == pcbnew.F_CrtYd:
            b = g.GetBoundingBox()
            xs += [b.GetLeft(), b.GetRight()]
            ys += [b.GetTop(), b.GetBottom()]
    x0, x1 = min(xs) / 1e6 - X0, max(xs) / 1e6 - X0
    return x0, Y0 - max(ys) / 1e6, x1, Y0 - min(ys) / 1e6


def put(fp, cx, y_bottom, angle):
    """Courtyard centred on x = cx, its bottom edge on y_bottom."""
    fp.SetOrientationDegrees(angle)
    fp.SetPosition(pt(0, 0))
    x0, y0, x1, _ = crt(fp)
    fp.SetPosition(pt(cx - (x0 + x1) / 2, y_bottom - y0))


def seg(board, layer, a, b, w=0.1):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(pt(*a))
    s.SetEnd(pt(*b))
    s.SetLayer(LAYER[layer])
    s.SetWidth(mm(w))
    board.Add(s)


def text(board, layer, s, x, y, size=1.5, mirror=False, just=0):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(s)
    t.SetPosition(pt(x, y))
    t.SetLayer(LAYER[layer])
    t.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    t.SetTextThickness(mm(size * 0.15))
    t.SetMirrored(mirror)
    t.SetHorizJustify({-1: pcbnew.GR_TEXT_H_ALIGN_LEFT, 0: pcbnew.GR_TEXT_H_ALIGN_CENTER}[just])
    board.Add(t)


def dim(board, a, b, height, size=1.2):
    d = pcbnew.PCB_DIM_ALIGNED(board, pcbnew.PCB_DIM_ALIGNED_T)
    d.SetLayer(LAYER["Dwgs.User"])
    d.SetStart(pt(*a))
    d.SetEnd(pt(*b))
    d.SetHeight(mm(height))
    d.SetUnitsMode(pcbnew.DIM_UNITS_MODE_MILLIMETRES)
    d.SetPrecision(pcbnew.DIM_PRECISION_X_X)
    d.SetSuppressZeroes(True)
    d.SetTextSize(pcbnew.VECTOR2I(mm(size), mm(size)))
    d.SetTextThickness(mm(size * 0.15))
    d.SetLineThickness(mm(0.1))
    d.SetKeepTextAligned(True)
    d.Update()
    board.Add(d)


def outline(board, top):
    """Card body plus the finger tab (KiCad's PCIe x4 card: 0.5 mm chamfers, key notch
    between contacts 11 and 12 reaching the shoulder)."""
    fx, c, k0, k1 = FINGER_X0, 0.5, FINGER_X0 + 10.55, FINGER_X0 + 12.45
    t0, t1 = fx - 0.65, fx + 33.65
    pts = [(t0, TAB_H), (0, TAB_H), (0, top), (CARD_W, top), (CARD_W, TAB_H), (t1, TAB_H),
           (t1, c), (t1 - c, 0), (k1 + c, 0), (k1, c), (k1, TAB_H - 0.95)]
    for a, b in zip(pts, pts[1:]):
        seg(board, "Edge.Cuts", a, b)
    arc = pcbnew.PCB_SHAPE(board)
    arc.SetShape(pcbnew.SHAPE_T_ARC)
    arc.SetArcGeometry(pt(k1, TAB_H - 0.95), pt((k0 + k1) / 2, TAB_H), pt(k0, TAB_H - 0.95))
    arc.SetLayer(LAYER["Edge.Cuts"])
    arc.SetWidth(mm(0.1))
    board.Add(arc)
    pts = [(k0, TAB_H - 0.95), (k0, c), (k0 - c, 0), (t0 + c, 0), (t0, c), (t0, TAB_H)]
    for a, b in zip(pts, pts[1:]):
        seg(board, "Edge.Cuts", a, b)


def build(size, force):
    proj = "cartridge_%dk" % size
    pcb = os.path.join(KDIR, proj, proj + ".kicad_pcb")
    sch = os.path.join(KDIR, proj, proj + ".kicad_sch")
    if os.path.exists(pcb) and not force:
        print("kept", pcb, "(exists; --force to write it again)")
        return pcb
    syms = symbols(sch)
    nets = netlist(sch)
    # footprints first: KiCad 7's FootprintLoad stops working once a board exists
    fps = {ref: load(fpid) for ref, (_u, _v, fpid) in syms.items() if fpid}
    hole = load(FP_HOLE)
    rows = BUILDS[size]
    if {r for row in rows for r in row} | {"J1"} != set(fps):
        sys.exit("%s: schematic parts %s, layout %s" % (proj, sorted(fps), sorted(r for row in rows for r in row)))

    board = pcbnew.NewBoard(pcb)
    board.SetCopperLayerCount(2)
    layers = pcbnew.LSET.AllCuMask(2)
    layers.addLayerSet(pcbnew.LSET.AllTechMask())
    layers.addLayerSet(pcbnew.LSET.UserMask())
    board.SetEnabledLayers(layers)
    board.GetDesignSettings().SetBoardThickness(mm(1.57))
    tb = board.GetTitleBlock()
    tb.SetTitle("PLACARD ROM cartridge, %dK" % size)
    tb.SetDate(DATE)
    tb.SetRevision("1")
    tb.SetComment(0, "Placed by src/scripts/gen_kicad_cart_pcb.py; not routed")

    # fingers: contact 1 at FINGER_X0, the card edge at y = 0
    fps["J1"].SetPosition(pt(FINGER_X0, EDGE_Y))
    y = PART_Y0
    hole_y = None
    for i, (u, c) in enumerate(rows):
        # pin 1 at the bottom left, the pins along the fingers
        put(fps[u], MID, y, 90)
        top = crt(fps[u])[3]
        put(fps[c], CARD_W - 6.0, top + 0.25, 0)
        if i == 0:
            hole_y = top + HOLE_GAP / 2
            y = top + HOLE_GAP
        else:
            y = top + ROW_GAP
    card_top = max(y - ROW_GAP, crt(fps[rows[-1][1]])[3]) + TOP_MARGIN
    hole.SetReference("H1")
    hole.SetValue("M3")
    hole.SetPosition(pt(MID, hole_y))
    hole.Reference().SetVisible(False)

    for ref, fp in fps.items():
        uid, value, _ = syms[ref]
        fp.SetReference(ref)
        fp.SetValue(value)
        fp.SetPath(pcbnew.KIID_PATH("/" + uid))
        fp.SetProperty("Sheetname", "")
        fp.SetProperty("Sheetfile", proj + ".kicad_sch")
        board.Add(fp)
    board.Add(hole)
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

    outline(board, card_top)
    text(board, "B.SilkS", "PLACARD ROM %dK" % size, MID, card_top - 4.0, 2.0, mirror=True)
    text(board, "B.SilkS", "side B", MID, TAB_H + 1.0, 1.0, mirror=True)
    dim(board, (0, card_top), (CARD_W, card_top), -5.0)
    dim(board, (CARD_W, 0), (CARD_W, card_top), 7.0)
    dim(board, (0, 0), (0, hole_y), -7.0)
    dim(board, (0, hole_y), (MID, hole_y), 0.0)
    notes = ["PLACARD ROM cartridge, %dK: %d chips, 2 layers, 1.57 mm, %.1f x %.1f mm (finger tab included)"
             % (size, len(rows), CARD_W, card_top),
             "H1 M3 at x %.1f, y %.2f from the finger edge: the same place on the 32K and 64K boards" % (MID, hole_y),
             "Parts on side A (F.Cu fingers = J8's A row); puller room (User.Eco1) may hang past the card edge",
             "Placed and netted by src/scripts/gen_kicad_cart_pcb.py, not routed"]
    for i, s in enumerate(notes):
        text(board, "Cmts.User", s, 0, -8.0 - 3.0 * i, 1.2, just=-1)

    problems = check(fps, hole, card_top)
    board.Save(pcb)
    s = open(pcb).read()
    open(pcb, "w", newline="\n").write(s)
    print("wrote %s: %.1f x %.1f mm, H1 at (%.1f, %.2f), %d nets%s" % (
        pcb, CARD_W, card_top, MID, hole_y, len(netinfo), "".join("\n  " + p for p in problems)))
    return pcb


def check(fps, hole, top):
    boxes = [(ref, crt(fp)) for ref, fp in fps.items() if ref != "J1"]
    hx, hy = hole.GetPosition().x / 1e6 - X0, Y0 - hole.GetPosition().y / 1e6
    boxes.append(("H1", (hx - HOLE_CRTYD, hy - HOLE_CRTYD, hx + HOLE_CRTYD, hy + HOLE_CRTYD)))
    out = []
    for i, (ra, a) in enumerate(boxes):
        if a[1] < TAB_H or a[3] > top:
            out.append("%s off the card body" % ra)
        if ra[0] == "C" and (a[0] < 0 or a[2] > CARD_W):
            out.append("%s past the card edge" % ra)
        for rb, b in boxes[i + 1:]:
            if a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]:
                out.append("courtyards overlap: %s %s" % (ra, rb))
    return out


def png(pcb, out):
    import cairosvg
    svg = out[:-4] + ".svg"
    layers = "Edge.Cuts,F.Fab,F.CrtYd,F.Cu,Eco1.User,F.SilkS,Dwgs.User"
    subprocess.run(["kicad-cli", "pcb", "export", "svg", "--layers", layers, "--exclude-drawing-sheet",
                    "--page-size-mode", "2", "-o", svg, pcb], check=True, capture_output=True)
    cairosvg.svg2png(url=svg, write_to=out, output_width=1400, background_color="white")
    os.remove(svg)
    from PIL import Image, ImageChops
    im = Image.open(out).convert("RGB")
    bb = ImageChops.difference(im, Image.new("RGB", im.size, "white")).getbbox()
    im.crop((max(bb[0] - 20, 0), max(bb[1] - 20, 0), bb[2] + 20, bb[3] + 20)).save(out)
    print("wrote", out)


def main():
    for size in (64, 32):
        pcb = build(size, "--force" in sys.argv)
        if "--png" in sys.argv:
            png(pcb, os.path.join(DOCS, "cart_placement_%dk.png" % size))


if __name__ == "__main__":
    main()
