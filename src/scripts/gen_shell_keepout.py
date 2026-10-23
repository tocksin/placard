#!/usr/bin/env python3
"""
gen_shell_keepout.py - draw docs/shell_keepout.png: how far the cartridge
and expansion card shells reach on the main board (EXPANSION.md "Shell
keepouts").

    python3 gen_shell_keepout.py

Three views, all from the constants in gen_kicad_connectors.py, so a change
there shows here after a rerun of both scripts:
- a cross-section through a card in its slot (the shell's stack-up);
- the J8 and J9-J12 footprints from above with their courtyards (the
  keepouts);
- the four expansion slots side by side at the old and new pitch.

Date: 2026-10-23
"""

import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_kicad_connectors as gc  # noqa: E402

OUT = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "shell_keepout.png"))

SLOT_H = 11.25               # 87715-9106 body height above the board
SEAT = 4.3                   # socket seat height (chip shoulders rest here)
CHIP = 4.83                  # PDIP-28 height above its seating plane, max (AT28C256 28P6)
CARD_BOTTOM = 3.0            # card's bottom edge above the board, in the slot
CARD_TOP = 60.0              # drawn height of the card (not set by the keepout)
SHELL = "#555555"
KEEP = "#d62728"


def box(ax, x0, y0, x1, y1, **kw):
    ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, **kw))


def section(ax):
    """Cut through the cartridge across the slot: x = across the card (+ = side A), y = height."""
    half = gc.CARD_PCB / 2
    ya = half + gc.CARD_PARTS + 2 * gc.SHELL_AIR + gc.SHELL_WALL
    yb = max(half + gc.CARD_LEADS, 3.75) + gc.SHELL_AIR + gc.SHELL_WALL
    top = CARD_TOP + 4
    box(ax, -30, -1.6, 30, 0, color="#2e7d32")                                     # main board
    ax.text(-29, -0.8, "main board", va="center", fontsize=8, color="white")
    box(ax, -3.75, 0, 3.75, SLOT_H, fc="#cccccc", ec="black", lw=0.6)               # slot body
    ax.text(0, 1.5, "J8", ha="center", fontsize=8)
    box(ax, -half, CARD_BOTTOM, half, CARD_TOP, color="#1b5e20")                   # card
    # socket + ROM on side A, lead stubs on side B
    for y in (18, 42):
        box(ax, half, y, half + SEAT, y + 17, fc="#999999", ec="black", lw=0.5)
        box(ax, half + SEAT, y + 0.8, half + SEAT + CHIP, y + 16.2, fc="#222222")
        box(ax, -half - gc.CARD_LEADS, y + 1, -half, y + 16, fc="#bbbbbb", ec="none")
    ax.text(half + SEAT + CHIP / 2, 50, "AT28C256", rotation=90, ha="center", va="center",
            color="white", fontsize=7)
    ax.text(half + SEAT / 2, 26.5, "socket", rotation=90, ha="center", va="center", fontsize=7)
    # shell: two walls down to the board, joined over the top
    for x0, x1 in [(-yb, -yb + gc.SHELL_WALL), (ya - gc.SHELL_WALL, ya)]:
        box(ax, x0, 0, x1, top, color=SHELL)
    box(ax, -yb, top - gc.SHELL_WALL, ya, top, color=SHELL)
    ax.text(ya + 0.3, top - 6, "shell", fontsize=8, color=SHELL)
    # keepout on the board
    m = gc.MARGIN
    ax.plot([-yb - m, ya + m], [-2.4, -2.4], color=KEEP, lw=3, solid_capstyle="butt")
    ax.text(0, -3.2, "keepout %.2f mm (shell %.2f + %.0f mm margin each side)"
            % (ya + yb + 2 * m, ya + yb, m), ha="center", va="top", fontsize=8, color=KEEP)
    # stack-up, as text
    rows = ["side A (from the card's mid-plane)",
            "  half card        %5.2f" % half,
            "  socket seat      %5.2f" % SEAT,
            "  chip (max)       %5.2f" % CHIP,
            "  air              %5.2f" % (2 * gc.SHELL_AIR),
            "  wall             %5.2f" % gc.SHELL_WALL,
            "  = %.2f" % ya,
            "side B: half the slot body",
            "  3.75 + air 0.5 + wall 2 = %.2f" % yb]
    ax.text(-29, 86, "\n".join(rows), va="top", fontsize=7.5, family="monospace")
    ax.text(ya + 1, 30, "side A\n(parts)", fontsize=8)
    ax.text(-yb - 1, 30, "side B\n(leads)", fontsize=8, ha="right")
    ax.set_xlim(-30, 30)
    ax.set_ylim(-8, 88)
    ax.set_aspect("equal")
    ax.set_title("Cross-section: cartridge in J8 (expansion card the same,\nits slot body is 9.9 mm wide)",
                 fontsize=10)
    ax.set_xlabel("mm across the slot")
    ax.set_ylabel("mm above the main board")


def top_view(ax, mid, card_w, body, slot_half, pads, title, y_off):
    """One footprint from above: body, pads, shell outline and keepout (courtyard)."""
    x0, y0, x1, y1 = gc.shell_box(mid, card_w, slot_half)
    m = gc.MARGIN
    box(ax, x0, y_off + y0, x1, y_off + y1, fc=KEEP, alpha=0.12, ec=KEEP, lw=1.2)
    box(ax, x0 + m, y_off + y0 + m, x1 - m, y_off + y1 - m, fc="none", ec=SHELL, lw=1, ls="--")
    box(ax, mid - card_w / 2, y_off - gc.CARD_PCB / 2, mid + card_w / 2, y_off + gc.CARD_PCB / 2,
        color="#1b5e20")
    box(ax, body[0], y_off + body[1], body[2], y_off + body[3], fc="#cccccc", ec="black", lw=0.6, alpha=0.8)
    ax.plot([p[0] for p in pads], [y_off + p[1] for p in pads], ".", ms=1.5, color="#b8860b")
    ax.text(x0 + 1, y_off + y1 - 1, title, va="top", fontsize=9, weight="bold")
    ax.text(x1 - 1, y_off + y1 - 1, "%.1f x %.2f mm" % (x1 - x0, y1 - y0), va="top", ha="right",
            fontsize=8, color=KEEP)
    ax.text(mid, y_off + y1 + 0.6, "side A (parts)", ha="center", fontsize=7)
    ax.text(mid, y_off + y0 - 0.6, "side B", ha="center", va="top", fontsize=7)


def top_views(ax):
    cart_pads = []
    for n in range(1, 33):
        x = n - 1 if n <= 11 else n + 1
        s = 1.9 if n % 2 else 0.0
        cart_pads += [(x, -1.0 - s), (x, 1.0 + s)]
    c = 19 * 2.54 / 2
    exp_pads = [((n - 1) * 2.54, y) for n in range(1, 21) for y in (2.54, -2.54)]
    top_view(ax, 16.5, gc.CART_W, (-2.75, -3.75, 35.75, 3.75), 3.75, cart_pads,
             "J8 cartridge (%g mm card)" % gc.CART_W, 0)
    top_view(ax, c, gc.EXP_W, (c - 35.56, -4.95, c + 35.56, 4.95), 4.95, exp_pads,
             "J9-J12 expansion card (%g mm card)" % gc.EXP_W, -32)
    ax.plot([], [], color=KEEP, lw=6, alpha=0.3, label="keepout = courtyard (DRC checks it)")
    ax.plot([], [], color=SHELL, ls="--", label="shell outside")
    ax.plot([], [], color="#1b5e20", lw=3, label="card")
    ax.legend(loc="lower center", fontsize=8, ncol=3, bbox_to_anchor=(0.5, -0.32))
    ax.set_xlim(-32, 68)
    ax.set_ylim(-46, 20)
    ax.set_aspect("equal")
    ax.set_title("Footprints from above (footprint origin = 0, 0)", fontsize=10)
    ax.set_xlabel("mm")


def pitch_view(ax):
    c = 19 * 2.54 / 2
    for row, (pitch, lab) in enumerate([(20.32, "0.8\" (20.32 mm), as now: shells collide"),
                                        (22.86, "0.9\" (22.86 mm): minimum, keepouts clear")]):
        yo = -row * 120
        for i in range(4):
            x0, y0, x1, y1 = gc.shell_box(c, gc.EXP_W, 4.95)
            # rotated 90 degrees as on the board: footprint y becomes board x
            bx = i * pitch
            box(ax, bx + y0, yo + x0 - c, bx + y1, yo + x1 - c, fc=KEEP, alpha=0.15, ec=KEEP, lw=1)
            box(ax, bx - 4.95, yo - 35.56, bx + 4.95, yo + 35.56, fc="#cccccc", ec="black", lw=0.5)
            ax.text(bx, yo, "J%d" % (9 + i), rotation=90, ha="center", va="center", fontsize=7)
        ax.text(-12, yo + 45, lab, fontsize=9, weight="bold", color=KEEP if row == 0 else "black")
    ax.set_xlim(-14, 3 * 22.86 + 18)
    ax.set_ylim(-170, 58)
    ax.set_aspect("equal")
    ax.set_title("Expansion slot pitch", fontsize=10)
    ax.set_xlabel("mm")


def main():
    fig = plt.figure(figsize=(16, 9.5), dpi=130)
    gs = fig.add_gridspec(1, 3, width_ratios=[1.0, 1.55, 0.75])
    section(fig.add_subplot(gs[0]))
    top_views(fig.add_subplot(gs[1]))
    pitch_view(fig.add_subplot(gs[2]))
    fig.suptitle("PLACARD cartridge and expansion card shell keepouts", fontsize=13, weight="bold")
    fig.tight_layout()
    fig.savefig(OUT)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
