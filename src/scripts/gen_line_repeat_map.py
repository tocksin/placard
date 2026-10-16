#!/usr/bin/env python3
"""
gen_line_repeat_map.py - draw one video column's 512 bytes in each line
repeat mode (VIDEO.md, line repeat).

    python3 gen_line_repeat_map.py            writes reference/line_repeat_map.png

Date: 10/16/2026

Offset within a column = video address A8:A0.  Column c starts at x6000 + c*x200.
Visible row r is line V = 544 + r, so V8:V0 = 32 + r.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from matplotlib import cm

W, H = 32, 16          # grid: 32 bytes per grid row, 16 grid rows = 512 bytes


def rot8(p):
    return ((p << 1) & 0xFF) | (p >> 7)


def rot7(s):
    return ((s << 2) & 0x7F) | (s >> 5)


def offset(row, rep, shift=False):
    v = 32 + row
    if rep == 1:
        return v
    if rep == 2:
        p = v >> 1
        return 256 + (p if shift else rot8(p))
    s = v >> 2
    return 384 + (s if shift else rot7(s))


def layout(modes, shift=False):
    """modes(row) -> repeat factor.  Returns {offset: [rows]}."""
    used = {}
    for r in range(480):
        used.setdefault(offset(r, modes(r), shift), []).append(r)
    return used


PANELS = [
    ("1x on every row: 640 x 480", lambda r: 1, False),
    ("2x on every row: 640 x 240", lambda r: 2, False),
    ("4x on every row: 640 x 120", lambda r: 4, False),
    ("Mixed: 1x rows 0-223, 2x rows 224-479", lambda r: 1 if r < 224 else 2, False),
]

# a few lines called out in every panel
MARK = {0: "#D9534F", 1: "#E8A33D", 2: "#8E6CC9", 3: "#3DAE6B", 224: "#111111", 225: "#C2185B"}
FREE, HIDDEN = "#BFE8C8", "#FFFFFF"
cmap = matplotlib.colormaps["Blues"]

fig, axes = plt.subplots(len(PANELS), 1, figsize=(17, 4.0 * len(PANELS) + 1.6), dpi=120)
fig.suptitle("One video column (512 bytes) in each line-repeat mode", fontsize=18, weight="bold", y=0.995)
fig.text(0.5, 0.975,
         "Column 0 shown (x6000-x61FF); column c is the same pattern at x6000 + c * x200, so multiply the free "
         "space by 80.  Each cell is one byte; blue shade = screen row (lighter at the top of the screen).",
         ha="center", fontsize=11, color="#444")

for ax, (title, modes, shift) in zip(axes, PANELS):
    used = layout(modes, shift)
    free = sum(1 for o in range(512) if o not in used)
    ax.set_xlim(-0.5, W + 0.2)
    ax.set_ylim(H, 0)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(f"{title}      free: {free} B per column, {free * 80 / 1024:.1f} KB for 80 columns",
                 fontsize=12.5, weight="bold", loc="left")
    for o in range(512):
        x, y = o % W, o // W
        rows = used.get(o)
        if rows is None:
            ax.add_patch(Rectangle((x, y), 1, 1, facecolor=FREE, edgecolor="#9CCBA6", lw=0.4))
            continue
        hit = [r for r in rows if r in MARK]
        color = MARK[hit[0]] if hit else cmap(0.25 + 0.7 * rows[0] / 479)
        ax.add_patch(Rectangle((x, y), 1, 1, facecolor=color, edgecolor="white", lw=0.4))
        if hit:
            label = f"{rows[0]}" if len(rows) == 1 else f"{rows[0]}-{rows[-1]}"
            ax.text(x + 0.5, y + 0.5, label, ha="center", va="center", fontsize=6.2,
                    color="white", weight="bold")
    for gy in range(H):
        ax.text(-0.6, gy + 0.5, f"x{0x6000 + gy * W:04X}", ha="right", va="center", fontsize=7.5,
                family="monospace")
    ax.plot([0, W], [8, 8], color="#333", lw=1.2)
    ax.text(W + 0.2, 4, "low half\nx6000-x60FF", fontsize=8, va="center")
    ax.text(W + 0.2, 12, "high half\nx6100-x61FF", fontsize=8, va="center")

handles = [Rectangle((0, 0), 1, 1, facecolor=FREE, edgecolor="#9CCBA6"),
           Rectangle((0, 0), 1, 1, facecolor=cmap(0.6))] + \
          [Rectangle((0, 0), 1, 1, facecolor=c) for c in MARK.values()]
labels = ["free (never read by the video)", "pixel byte of some screen row"] + \
         [f"screen row {r}" for r in MARK]
fig.legend(handles, labels, loc="lower center", ncol=8, fontsize=10, frameon=False)
fig.text(0.5, 0.025,
         "Cells labelled 0-1 or 0-3 are one byte shown on 2 or 4 lines.  In 1x, offsets x00-x1F of each column "
         "are in vertical blanking, so they are free in 1x too.",
         ha="center", fontsize=10, color="#444")
plt.subplots_adjust(left=0.06, right=0.94, top=0.95, bottom=0.06, hspace=0.35)
import os
import sys
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference", "line_repeat_map.png")
plt.savefig(out)
print(out)
