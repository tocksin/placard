#!/usr/bin/env python3
"""Draw what option B (docs/FETCH_TIMING.md) changes on the main board.

Reads the chip positions and the outline from kicad/placard.kicad_pcb (the
board stays Justin's; this only draws it) and marks the chips whose wiring
changes and the nets that move.  No chip has to move.  Output:
docs/option_b_board.png.  Run from the repository root.
"""
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyArrowPatch

PCB = "kicad/placard.kicad_pcb"
# footprint -> (width, height) in mm when the part is at 0 degrees
SIZES = {"DIP-24": (33, 10.2), "DIP-28": (38, 10.2), "DIP-20": (28, 10.2), "Oscillator_DIP-14": (20.3, 13.2),
         "Molex_87715": (62, 11), "CardEdge": (55, 12)}
CHANGED = {"U7": "mux, re-pinned", "U8": "mux, re-pinned", "U9": "mux, re-pinned", "U10": "mux, re-pinned",
           "U15": "Sync: + /WE, CLK_E, RW, RUN", "U11": "mem ctrl: - /WE", "U12": "I/O decode: 3 pins renamed",
           "X1": "oscillator: CLK_E", "U31": "RAM: /WE from U15", "U32": "RAM: /WE from U15",
           "U1": "State: enables also to the muxes"}


def read_board():
    s = open(PCB).read()
    parts = {}
    for m in re.finditer(r'\(footprint "([^"]+)"(.*?)\n\t\)\n', s, re.S):
        body = m.group(2)
        r = re.search(r'\(property "Reference" "([^"]+)"', body)
        at = re.search(r'\(at ([-\d.]+) ([-\d.]+)(?: ([-\d.]+))?\)', body)
        if r and at and r.group(1)[0] in "UXJ":
            fp = m.group(1).split(":")[-1]
            size = (10, 10)
            for k, v in SIZES.items():
                if fp.startswith(k):
                    size = v
            rot = float(at.group(3) or 0)
            w, h = size if rot % 180 == 0 else size[::-1]
            parts[r.group(1)] = (float(at.group(1)), float(at.group(2)), w, h)
    xs, ys = [], []
    for m in re.finditer(r'\(gr_line\s*\(start ([-\d.]+) ([-\d.]+)\)\s*\(end ([-\d.]+) ([-\d.]+)\)\s*\(stroke.*?\(layer "Edge.Cuts"\)',
                         s, re.S):
        xs += [float(m.group(1)), float(m.group(3))]
        ys += [float(m.group(2)), float(m.group(4))]
    return parts, (min(xs), max(xs), min(ys), max(ys))


def center(parts, ref):
    x, y, w, h = parts[ref]
    return x, y


def arrow(ax, p, q, color, lw=2.0, style="-|>", ls="-", rad=0.0, label=None, lpos=0.5, dx=0, dy=0):
    a = FancyArrowPatch(p, q, arrowstyle=style, mutation_scale=14, lw=lw, color=color, linestyle=ls,
                        connectionstyle=f"arc3,rad={rad}", shrinkA=4, shrinkB=4, zorder=5)
    ax.add_patch(a)
    if label:
        mx, my = p[0] + (q[0] - p[0]) * lpos + dx, p[1] + (q[1] - p[1]) * lpos + dy
        ax.text(mx, my, label, color=color, fontsize=9, ha="center", va="center", zorder=6,
                bbox=dict(fc="white", ec="none", alpha=0.85, pad=1))


def main():
    parts, (x0, x1, y0, y1) = read_board()
    fig, ax = plt.subplots(figsize=(16, 12.5))
    ax.set_aspect("equal")
    ax.set_xlim(x0 - 5, x1 + 5)
    ax.set_ylim(y1 + 26, y0 - 28)         # board coordinates: y grows downwards; notes below the board
    ax.axis("off")
    ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fc="#f4f1e8", ec="black", lw=1.5, zorder=0))
    for ref, (x, y, w, h) in parts.items():
        if ref in CHANGED:
            fc, ec, lw = "#ffd6a5", "#c0392b", 1.6
        else:
            fc, ec, lw = "#e4e4e4", "#777777", 0.8
        ax.add_patch(Rectangle((x - w / 2, y - h / 2), w, h, fc=fc, ec=ec, lw=lw, zorder=2))
        ax.text(x, y, ref, ha="center", va="center", fontsize=8 if ref in CHANGED else 7,
                weight="bold" if ref in CHANGED else "normal", zorder=3)
    c = lambda r: center(parts, r)
    GREEN, RED, BLUE, GREY = "#2e7d32", "#b22222", "#1f4e9c", "#888888"
    # the clock: X1 -> U15 CLK_E first (new), then NT2 and the old tree from near U11
    arrow(ax, c("X1"), c("U15"), GREEN, lw=2.6, rad=-0.25, label="CLK_E: X1 to U15 pin 9 first", lpos=0.45, dy=-14)
    nt2 = (c("X1")[0] + 10, c("X1")[1] - 12)
    ax.plot([nt2[0]], [nt2[1]], marker="s", color=GREEN, ms=9, zorder=6)
    ax.text(nt2[0] - 4, nt2[1] - 5, "NT2 (new net tie): the CLK tree\nstarts here, next to X1 as now", color=GREEN, fontsize=9,
            ha="right", va="bottom", bbox=dict(fc="white", ec="none", alpha=0.85))
    arrow(ax, c("U15"), nt2, GREEN, lw=2.0, ls="--", rad=0.35,
          label="then at least 420 mm of track (500 nominal) back to NT2", lpos=0.5, dy=-10, dx=20)
    # /WE: from U15 pin 20 instead of U11 pin 16
    for ram in ("U31", "U32"):
        arrow(ax, c("U15"), c(ram), RED, lw=2.0, rad=0.12)
    arrow(ax, c("U15"), c("U12"), RED, lw=1.4, rad=-0.15)
    ax.text(285, 150, "/WE now from U15 pin 20\n(was U11 pin 16): to U31, U32,\nU12 pin 1, R63, J8 and the slots", color=RED, fontsize=9,
            ha="center", bbox=dict(fc="white", ec="none", alpha=0.85))
    arrow(ax, c("U11"), c("U31"), GREY, lw=1.4, ls=":", style="-", label="old /WE route gone", lpos=0.35, dx=22)
    # the selects: U1's enables and U15's PIXEL_ENABLE to the four muxes (and U12)
    for mx in ("U7", "U8", "U9", "U10"):
        arrow(ax, c("U1"), c(mx), BLUE, lw=1.3, rad=0.0)
        arrow(ax, c("U15"), c(mx), BLUE, lw=1.0, rad=0.25, ls="-")
    arrow(ax, c("U1"), c("U12"), BLUE, lw=1.3, rad=-0.2)
    ax.text(x0, y1 + 10, "Blue: PC_ENABLE, X_ENABLE, Y_ENABLE from U1 to the four muxes and U12 (new); PIXEL_ENABLE from U15 "
            "to the muxes (new).  ADDR_SEL x3 from U15 to the muxes: gone.\n"
            "U7-U10: same sockets, every signal pin re-assigned (mux revision 02).  U11 pin 16 and U15 pins 21, 22 become free.",
            color=BLUE, fontsize=9.5, ha="left", va="top")
    ax.set_title("Option B on the main board: what is re-wired.  No chip has to move.", fontsize=15, weight="bold", loc="left")
    ax.text(x0, y0 - 10, "Orange: chips whose connections change.  Green: the clock (CLK_E tap, then the long track to NT2).  "
            "Red: /WE.  Blue: the mux selects.  Grey dotted: a route that goes away.\n"
            "Positions from kicad/placard.kicad_pcb; the straight-line X1 to U15 distance is about "
            f"{((c('X1')[0] - c('U15')[0]) ** 2 + (c('X1')[1] - c('U15')[1]) ** 2) ** 0.5:.0f} mm, "
            "so X1 -> U15 -> NT2 (next to X1) is about 400 mm of track before any serpentine.",
            fontsize=9.5, va="top")
    fig.tight_layout()
    fig.savefig("docs/option_b_board.png", dpi=110)
    print("wrote docs/option_b_board.png")


if __name__ == "__main__":
    main()
