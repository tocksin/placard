#!/usr/bin/env python3
"""
gen_state_diagram.py - draw the State PLD's state diagram as a PNG.

    python3 gen_state_diagram.py              writes reference/state_pld_state_diagram.png
    python3 gen_state_diagram.py out.png      writes out.png

Needs matplotlib (python3 -m pip install matplotlib).  The states,
transitions and outputs are typed in below from src/pld/ATF22V10_STATE.pld
(revision 12) and the STALL equation in ATF22V10_BRANCH.pld (revision 09);
update them here when those change and rerun.

Date: 2026-10-18
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Circle, FancyArrowPatch, FancyBboxPatch

fig = plt.figure(figsize=(20, 15), dpi=100)
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, 200)
ax.set_ylim(150, 0)
ax.axis("off")

R = 11
ST = {"FETCH": (25, 72, "00", "#FFF0BF"), "LOAD_IMM": (85, 40, "01", "#DDEEFC"),
      "LOAD_MEM": (85, 106, "10", "#DDEEFC"), "EXEC": (145, 72, "11", "#D3F6D8")}
DARK, RED = "#343A40", "#C92A2A"

for name, (x, y, code, fc) in ST.items():
    ax.add_patch(Circle((x, y), R, fc=fc, ec=DARK, lw=3, zorder=3))
    ax.text(x, y - 2, name, ha="center", va="center", fontsize=17, weight="bold", zorder=4)
    ax.text(x, y + 4, "Q1 Q0 = " + code, ha="center", va="center", fontsize=12, zorder=4)


def edge(a, b, label, lpos, color=DARK, fs=11.5):
    (x0, y0), (x1, y1) = ST[a][:2], ST[b][:2]
    d = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5
    ux, uy = (x1 - x0) / d, (y1 - y0) / d
    ax.annotate("", xy=(x1 - ux * R, y1 - uy * R), xytext=(x0 + ux * R, y0 + uy * R),
                arrowprops=dict(arrowstyle="-|>,head_width=0.55,head_length=1.1", lw=2.6,
                                color=color, shrinkA=0, shrinkB=0), zorder=2)
    if label:
        ax.text(*lpos, label, ha="center", va="center", fontsize=fs, color=color, zorder=5,
                bbox=dict(boxstyle="round,pad=0.25", fc="white", ec="none", alpha=0.95))


def stall_loop(name, side):
    """a self loop on the top, bottom or right of a state"""
    x, y = ST[name][:2]
    o = 0.42 * R
    if side == "top":
        p0, p1, rad, lp = (x - o, y - 0.9 * R), (x + o, y - 0.9 * R), -1.7, (x, y - 1.95 * R)
    elif side == "bottom":
        p0, p1, rad, lp = (x + o, y + 0.9 * R), (x - o, y + 0.9 * R), -1.7, (x, y + 1.95 * R)
    else:
        p0, p1, rad, lp = (x + 0.9 * R, y + o), (x + 0.9 * R, y - o), 1.7, (x + 2.2 * R, y)
    ax.add_patch(FancyArrowPatch(p0, p1, connectionstyle="arc3,rad=%g" % rad,
                                 arrowstyle="-|>,head_width=5,head_length=8", lw=2.2, color=RED,
                                 zorder=4))
    ax.text(*lp, "STALL = 1", ha="center", va="center", fontsize=11, color=RED,
            bbox=dict(boxstyle="round,pad=0.2", fc="white", ec="none"))


# ---------------------------------------------------------------- transitions
edge("FETCH", "LOAD_IMM", "source 00 (immediate)\nsource 01, MEM 000/011/100 ([0,D])\n"
     "source 1x, MEM 101 (zero-page store,\nor the pad byte of BCC ac / x)", (47, 44))
edge("FETCH", "LOAD_MEM", "source 01, MEM 001/010/110/111\n([0,X] or [Y,X] read)\n"
     "source 1x, MEM 110/111\n(store from AC or X, rev 10)", (45, 101))
edge("FETCH", "EXEC", "source 1x (AC or X),\nMEM 000-100", (62, 72))
edge("LOAD_IMM", "LOAD_MEM", "SRC0 = 1, MEM != 101\n(zero-page read: D\nnow holds the address)",
     (85, 60))
edge("LOAD_IMM", "EXEC", "otherwise", (124, 51))
edge("LOAD_MEM", "EXEC", "always", (124, 93))
ax.annotate("", xy=(25, 72 + R), xytext=(25, 134),
            arrowprops=dict(arrowstyle="-|>,head_width=0.55,head_length=1.1", lw=2.6, color=DARK,
                            shrinkA=0, shrinkB=0))
ax.plot([145, 145, 25], [72 + R, 134, 134], color=DARK, lw=2.6, zorder=1)
ax.text(85, 134, "always (next instruction)", ha="center", va="center", fontsize=11.5,
        bbox=dict(boxstyle="round,pad=0.25", fc="white", ec="none"))
ax.annotate("", xy=(25 - R, 72), xytext=(3, 72),
            arrowprops=dict(arrowstyle="-|>,head_width=0.5,head_length=0.9", lw=2.6, color=DARK))
ax.text(3, 69, "power-up", fontsize=11, color=DARK)

stall_loop("FETCH", "top")
stall_loop("LOAD_IMM", "top")
stall_loop("LOAD_MEM", "bottom")
stall_loop("EXEC", "right")

# ---------------------------------------------------------------- output boxes
def outbox(x, y, w, h, title, lines, fc):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=1.2",
                                fc=fc, ec=DARK, lw=1.8, zorder=1))
    ax.text(x + 1.5, y + 2.6, title, fontsize=12.5, weight="bold", va="center")
    for i, t in enumerate(lines):
        ax.text(x + 1.5, y + 6.6 + i * 3.6, t, fontsize=11, va="center")


outbox(2, 12, 37, 24, "FETCH outputs", ["PC_ENABLE = 1 (the PC counts)", "LOAD_INSTR = 1",
       "(instruction register <- data bus)", "X_ENABLE, Y_ENABLE <- the data", "bus memory field (registered)"],
       "#FFF8DB")
outbox(104, 14, 40, 19, "LOAD_IMM outputs", ["PC_ENABLE = 1 (the PC counts)", "LOAD_IMM = 1",
       "(D register <- data bus: operand)"], "#EEF6FE")
outbox(104, 104, 40, 23, "LOAD_MEM outputs", ["PC_ENABLE = 0 (the PC holds)", "LOAD_IMM = 1",
       "(D register <- the memory read)", "X_ENABLE / Y_ENABLE pick the address"], "#EEF6FE")
outbox(152, 8, 46, 41, "EXEC outputs", ["PC_ENABLE = 0", "MEM 000-010 -> LOAD_AC",
       "MEM 011 -> LOAD_X", "MEM 100 -> LOAD_Y", "MEM 101-111 -> MEM_WR (R/W = 0);",
       "  the memory control PLD gates /WE", "  with PIXEL_ENABLE (rev 12)",
       "BRANCH_BLOCK = 1 (a branch): none of",
       "  these; the Branch PLD loads the PC"], "#EAF9EC")
outbox(152, 100, 46, 26, "Clocks per instruction", ["register op 2, immediate 3",
       "[x] / [y,x] read or store 3", "zero-page store 3, zero-page read 4",
       "ADD / SUB into AC, X or Y: +1", "plus 1 per video stall clock"], "#F4F4F4")

ax.text(100, 5, "State PLD (ATF22V10_STATE, revision 12): state diagram", ha="center",
        fontsize=21, weight="bold", va="center")
ax.text(2, 144,
        "STALL is the State PLD's pin 2 (named PIXEL_ENABLE in the PLD file), from the Branch PLD: "
        "STALL = PIXEL_ENABLE # (EXEC & ADD/SUB & !ALU_DONE).\n"
        "While it is 1 the state holds and LOAD_INSTR, LOAD_IMM, LOAD_AC, LOAD_X and LOAD_Y are off: "
        "the video owns the bus, or an ADD or SUB waits one clock for its carry.\n"
        "Source = instruction bits 1:0 (00 immediate, 01 memory, 10 AC, 11 X); MEM = bits 4:2.  "
        "In FETCH both come from the data bus, later from the instruction register.",
        fontsize=10.5, color="#495057", va="center")

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference", "state_pld_state_diagram.png")
fig.savefig(out, facecolor="white")
print("wrote %s" % out)
