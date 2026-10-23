#!/usr/bin/env python3
"""
gen_cart_placement.py - placement study for the ROM cartridge card: how wide
and tall the card must be with its chips lying horizontally (long side
parallel to the edge fingers), for the 64K build (5 chips) and the 32K
build (3 chips: U1 PLD, U3 ROM, U5 SRAM; ROM.md, JP1).

    python3 gen_cart_placement.py

Draws docs/cart_placement_5chip.png and docs/cart_placement_3chip.png from
the real footprints in kicad/lib/placard.pretty (socket outline, courtyard,
chip-puller boxes, pads) and KiCad's disc capacitor.  No board file is
written: this only fixes the card outline that the shell keepout on J8
(gen_kicad_connectors.py CART_W) is sized from.

Card coordinates: x along the edge fingers (x = 0 at the card's left edge),
y up from the bottom of the finger tab.  The card is centred on the middle
of J8's contacts.

Date: 2026-10-23
"""

import math
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Circle, FancyBboxPatch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_kicad_connectors as gc  # noqa: E402

LIB = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib", "placard.pretty"))
STOCK = os.environ.get("KICAD7_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
DOCS = os.path.normpath(os.path.join(HERE, "..", "..", "docs"))

SLOT_LEN = 39.0              # 87715-9106 body length: the shell's skirt goes round it
CARD_W = gc.CART_W           # card width (= SLOT_LEN: the slot, not the chips, sets it)
TAB_H = 8.0                  # finger tab below the card's shoulder (inside the slot)
PART_Y0 = TAB_H + 2.0        # lowest part edge: 2 mm above the shoulder, clear of the slot top
ROW_GAP = 3.5                # courtyard to courtyard between rows: room for the row's 100n disc
TOP_MARGIN = 1.0             # top courtyard to the card's top edge

# middle of J8's contacts in card x: the card is centred on it
MID = CARD_W / 2
FINGER_X0 = MID - 16.5       # x of contact 1 (J8 footprint x = 0)


def parse(path):
    """Lines on F.Fab, F.CrtYd, Eco1.User and pads from a .kicad_mod (footprint coordinates)."""
    src = open(path).read()
    lines = []
    for m in re.finditer(r'\(fp_line \(start ([-\d.]+) ([-\d.]+)\) \(end ([-\d.]+) ([-\d.]+)\).*?\(layer "([^"]+)"\)', src):
        x1, y1, x2, y2 = map(float, m.groups()[:4])
        lines.append((m.group(5), x1, y1, x2, y2))
    pads = []
    for m in re.finditer(r'\(pad "([^"]*)" thru_hole (\w+) \(at ([-\d.]+) ([-\d.]+)(?: [-\d.]+)?\) \(size ([-\d.]+) ([-\d.]+)\)', src):
        pads.append((m.group(1), m.group(2), float(m.group(3)), float(m.group(4)), float(m.group(5)), float(m.group(6))))
    return lines, pads


def bbox(lines, layer):
    xs = [v for l in lines if l[0] == layer for v in (l[1], l[3])]
    ys = [v for l in lines if l[0] == layer for v in (l[2], l[4])]
    return min(xs), min(ys), max(xs), max(ys)


class Part:
    def __init__(self, ref, value, path, rot):
        self.ref, self.value, self.rot = ref, value, rot
        self.lines, self.pads = parse(path)
        self.at = (0.0, 0.0)

    def tf(self, x, y):
        """Footprint -> card coordinates: rotate (degrees, y up on the card), then move."""
        a = math.radians(self.rot)
        rx, ry = x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)
        return self.at[0] + rx, self.at[1] + ry

    def box(self, layer):
        x0, y0, x1, y1 = bbox(self.lines, layer)
        pts = [self.tf(x, y) for x, y in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]]
        return (min(p[0] for p in pts), min(p[1] for p in pts),
                max(p[0] for p in pts), max(p[1] for p in pts))

    def place(self, cx, y_bottom):
        """Courtyard centred on x = cx, its bottom edge on y_bottom."""
        self.at = (0.0, 0.0)
        x0, y0, x1, y1 = self.box("F.CrtYd")
        self.at = (cx - (x0 + x1) / 2, y_bottom - y0)

    def draw(self, ax):
        for layer, x1, y1, x2, y2 in self.lines:
            style = {"F.Fab": dict(color="#333333", lw=0.9),
                     "F.CrtYd": dict(color="#d62728", lw=0.5, ls=(0, (2, 2))),
                     "Eco1.User": dict(color="#9467bd", lw=0.35)}.get(layer)
            if style:
                p, q = self.tf(x1, y1), self.tf(x2, y2)
                ax.plot([p[0], q[0]], [p[1], q[1]], **style)
        for num, shape, x, y, w, h in self.pads:
            px, py = self.tf(x, y)
            if shape == "rect":
                ax.add_patch(Rectangle((px - w / 2, py - h / 2), w, h, color="#b8860b"))
            else:
                ax.add_patch(Circle((px, py), w / 2, color="#b8860b"))
        x0, y0, x1, y1 = self.box("F.CrtYd")
        size = 2.2 if (y1 - y0) > 12 else 1.8
        ax.text((x0 + x1) / 2, (y0 + y1) / 2, "%s  %s" % (self.ref, self.value), ha="center",
                va="center", fontsize=7 if size > 2 else 6, weight="bold", color="#1f3b73")


def sockets(build):
    w15 = os.path.join(LIB, "DIP-28_W15.24mm_Socket_Puller.kicad_mod")
    w7 = os.path.join(LIB, "DIP-28_W7.62mm_Socket_Puller.kicad_mod")
    w24 = os.path.join(LIB, "DIP-24_W7.62mm_Socket_Puller.kicad_mod")
    # bottom (next to the fingers) to top: the PLD drives the loader signals, the ROMs go
    # on top where they are easiest to take out
    rows = [("U1", "ATF22V10C-7PX", w24, "C1"),
            ("U4", "AS7C256C", w7, "C4"), ("U5", "AS7C256C", w7, "C5"),
            ("U2", "AT28C256", w15, "C2"), ("U3", "AT28C256", w15, "C3")]
    if build == 3:
        rows = [r for r in rows if r[0] in ("U1", "U5", "U3")]
    return rows


def layout(build):
    cap = os.path.join(STOCK, "Capacitor_THT.pretty", "C_Disc_D5.0mm_W2.5mm_P5.00mm.kicad_mod")
    parts = []
    y = PART_Y0
    for ref, value, path, cref in sockets(build):
        # pin 1 at the bottom left: footprint +y (down the pin row) turned to card +x
        p = Part(ref, value, path, 90)
        p.place(MID, y)
        parts.append(p)
        y = p.box("F.CrtYd")[3] + ROW_GAP
        c = Part(cref, "100n", cap, 0)
        c.place(CARD_W - 6.0, y - ROW_GAP / 2 - 1.5)
        parts.append(c)
    top = y - ROW_GAP + TOP_MARGIN
    # the last decap sits above the top row: the card ends above it
    top = max(top, parts[-1].box("F.CrtYd")[3] + TOP_MARGIN)
    return parts, top


def draw(build, out):
    parts, top = layout(build)
    fig, ax = plt.subplots(figsize=(5.0, 1.5 + top / 11.0), dpi=150)
    # card: body plus the finger tab
    tab0, tab1 = FINGER_X0 - 1.25, FINGER_X0 + 33 + 1.25
    ax.add_patch(Rectangle((0, TAB_H), CARD_W, top - TAB_H, fc="#2e7d32", alpha=0.18, ec="#1b5e20", lw=1.2))
    ax.add_patch(Rectangle((tab0, 0), tab1 - tab0, TAB_H, fc="#2e7d32", alpha=0.18, ec="#1b5e20", lw=1.2))
    for n in range(1, 33):
        x = FINGER_X0 + (n - 1 if n <= 11 else n + 1)
        ax.add_patch(Rectangle((x - 0.35, 0.6), 0.7, 5.5, color="#d4a017"))
    kx = FINGER_X0 + 11.5
    ax.add_patch(Rectangle((kx - 0.6, 0), 1.2, 4.0, color="white", ec="#1b5e20", lw=0.8))
    ax.text(kx, 4.6, "key", ha="center", fontsize=6)
    for p in parts:
        p.draw(ax)
    # dimensions
    ax.annotate("", (0, top + 3), (CARD_W, top + 3), arrowprops=dict(arrowstyle="<->", lw=0.8))
    ax.text(CARD_W / 2, top + 3.6, "card %.1f mm wide (= J8 body length)" % CARD_W, ha="center", fontsize=8)
    ax.annotate("", (CARD_W + 3, 0), (CARD_W + 3, top), arrowprops=dict(arrowstyle="<->", lw=0.8))
    ax.text(CARD_W + 4, top / 2, "%.1f mm\n(%.1f above\nthe tab)" % (top, top - TAB_H), va="center", fontsize=8)
    ax.text(-1.0, TAB_H + 0.8, "shoulder:\nrests over\nJ8's top", ha="right", va="bottom", fontsize=6, color="#555555")
    ax.text(-1.0, TAB_H / 2, "tab in J8\n(%.0f mm)" % TAB_H, ha="right", va="center", fontsize=6, color="#555555")
    ax.set_xlim(-14, CARD_W + 17)
    ax.set_ylim(-7, top + 8)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title("ROM cartridge, %s build (%d chips), chips horizontal, side A" %
                 ("64K" if build == 5 else "32K", build), fontsize=9, weight="bold")
    ax.text(CARD_W / 2, -2.0, "red dashed: courtyard; purple: chip-puller room\n(may hang past the card edge)",
            ha="center", va="top", fontsize=6)
    fig.tight_layout()
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    widest = max(p.box("F.CrtYd")[2] - p.box("F.CrtYd")[0] for p in parts)
    print("wrote %s: card %.1f x %.1f mm, widest courtyard %.2f mm" % (out, CARD_W, top, widest))


def main():
    draw(5, os.path.join(DOCS, "cart_placement_5chip.png"))
    draw(3, os.path.join(DOCS, "cart_placement_3chip.png"))


if __name__ == "__main__":
    main()
