#!/usr/bin/env python3
"""Draw the instruction fetch and /WE timing paths, now and with option B.

Only the chips on the two paths are drawn (docs/FETCH_TIMING.md).  Output:
docs/fetch_paths.png.  Run from the repository root.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

PLD = "#dbe9ff"
RAM = "#ffe6c7"
OSC = "#e2f5d9"
ADDR = "#1f4e9c"     # address path color
WE = "#b22222"       # write enable path color
CLKC = "#2e7d32"     # clock


def box(ax, x, y, w, h, title, sub, color):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.15",
                                fc=color, ec="black", lw=1.4))
    ax.text(x + w / 2, y + h * 0.66, title, ha="center", va="center", fontsize=13, weight="bold")
    ax.text(x + w / 2, y + h * 0.30, sub, ha="center", va="center", fontsize=10.5)
    return (x, y, w, h)


def port(b, side, frac=0.5):
    x, y, w, h = b
    return {"l": (x, y + h * frac), "r": (x + w, y + h * frac),
            "t": (x + w * frac, y + h), "b": (x + w * frac, y)}[side]


def arrow(ax, p, q, color, label=None, lw=2.2, rad=0.0, lpos=0.5, dy=0.22, fs=11):
    a = FancyArrowPatch(p, q, arrowstyle="-|>", mutation_scale=16, lw=lw, color=color,
                        connectionstyle=f"arc3,rad={rad}", shrinkA=0, shrinkB=0)
    ax.add_patch(a)
    if label:
        mx = p[0] + (q[0] - p[0]) * lpos
        my = p[1] + (q[1] - p[1]) * lpos + dy
        ax.text(mx, my, label, ha="center", va="bottom", fontsize=fs, color=color,
                bbox=dict(fc="white", ec="none", pad=1.2))


def panel(ax, title, option_b):
    ax.set_xlim(0, 20)
    ax.set_ylim(0, 9.2)
    ax.axis("off")
    ax.text(0.2, 8.85, title, fontsize=16, weight="bold", va="center")

    y0 = 5.6
    osc = box(ax, 0.3, y0, 1.9, 1.5, "X1", "25.175 MHz", OSC)
    state = box(ax, 3.2, y0, 2.6, 1.5, "U1 State PLD", "PC_ENABLE\ntCO 5.5", PLD)
    if option_b:
        mux = box(ax, 7.1, y0, 2.8, 1.5, "U7-U10 muxes", "2 low + 2 high bits\ntPD 7.5", PLD)
        ram = box(ax, 11.3, y0, 2.6, 1.5, "U31/U32 RAM", "AS7C256C-15\ntAA 15", RAM)
        back = box(ax, 15.3, y0, 2.6, 1.5, "U1 State PLD", "next state\nsetup 3.5", PLD)
        arrow(ax, port(state, "r"), port(mux, "l"), ADDR, "PC_ENABLE, X/Y_ENABLE")
        arrow(ax, port(mux, "r"), port(ram, "l"), ADDR, "A15:A0")
        arrow(ax, port(ram, "r"), port(back, "l"), ADDR, "D7:D0")
        ax.text(10.0, 4.75, "Fetch: 5.5 + 7.5 + 15 + 3.5 = 31.5 ns of 39.7   (+8.2 ns)",
                fontsize=13, color=ADDR, ha="center", weight="bold")
    else:
        sync = box(ax, 6.3, y0, 2.4, 1.5, "U15 Sync PLD", "ADDR_SEL = P # E\ntPD 7.5", PLD)
        mux = box(ax, 9.6, y0, 2.6, 1.5, "U7-U10 muxes", "4:1, 4 bits each\ntPD 7.5", PLD)
        ram = box(ax, 13.1, y0, 2.4, 1.5, "U31/U32 RAM", "AS7C256C-15\ntAA 15", RAM)
        back = box(ax, 16.4, y0, 2.4, 1.5, "U1 State PLD", "next state\nsetup 3.5", PLD)
        arrow(ax, port(state, "r"), port(sync, "l"), ADDR, "PC_ENABLE")
        arrow(ax, port(sync, "r"), port(mux, "l"), ADDR, "ADDR_SEL x3")
        arrow(ax, port(mux, "r"), port(ram, "l"), ADDR, "A15:A0")
        arrow(ax, port(ram, "r"), port(back, "l"), ADDR, "D7:D0")
        ax.text(10.0, 4.75, "Fetch: 5.5 + 7.5 + 7.5 + 15 + 3.5 = 39.0 ns of 39.7   (+0.7 ns, about -4 with traces)",
                fontsize=13, color=ADDR, ha="center", weight="bold")

    # write enable path
    y1 = 1.4
    if option_b:
        wsrc = box(ax, 3.2, y1, 2.6, 1.5, "U15 Sync PLD", "/WE = !CLK_E & !RW & !P\ntPD 7.5", PLD)
        wram = box(ax, 11.3, y1, 2.6, 1.5, "U31/U32 RAM", "/WE, tWR 0", RAM)
        arrow(ax, port(wsrc, "r"), port(wram, "l"), WE, "/WE high by 7.5 - 3 = 4.5 ns after the CPU edge")
        # clock: X1 -> CLK_E first, then the 500 mm track to the rest
        arrow(ax, port(osc, "b"), (1.25, y1 + 0.75), CLKC, lw=1.8)
        arrow(ax, (1.25, y1 + 0.75), port(wsrc, "l"), CLKC, "CLK_E (early tap)", dy=0.15, fs=10)
        arrow(ax, (1.25, y1 + 0.75), (1.25, 0.45), CLKC, lw=1.8)
        arrow(ax, (1.25, 0.45), (2.7, 0.45), CLKC, lw=1.8)
        ax.text(4.6, 0.45, "500 mm of track = 3 ns, then CLK to every other chip (U1, U15 pin 1, PCs, ...)",
                fontsize=10.5, color=CLKC, va="center")
        arrow(ax, (2.7, 0.45), (2.7, y0 + 0.4), CLKC, lw=1.8)
        arrow(ax, (2.7, y0 + 0.4), (3.2, y0 + 0.4), CLKC, lw=1.8)
        arrow(ax, (2.7, 0.45), (4.4, 0.45), CLKC, lw=1.8)
        ax.text(10.0, 3.55, "Address, /CE_LO and /CE_HI can change 2 + 3 = 5 ns after the CPU edge: hold +0.5 ns",
                fontsize=12.5, color=WE, ha="center", weight="bold")
    else:
        wsrc = box(ax, 3.2, y1, 2.6, 1.5, "U11 Mem ctrl PLD", "/WE = !CLK & !RW & !P\ntPD 7.5", PLD)
        wram = box(ax, 13.1, y1, 2.4, 1.5, "U31/U32 RAM", "/WE, tWR 0", RAM)
        arrow(ax, port(wsrc, "r"), port(wram, "l"), WE, "/WE high by 7.5 ns after the edge")
        arrow(ax, port(osc, "b"), (1.25, y1 + 0.75), CLKC, lw=1.8)
        arrow(ax, (1.25, y1 + 0.75), port(wsrc, "l"), CLKC, "CLK (61 mm)", dy=0.15, fs=10)
        arrow(ax, (1.25, y1 + 0.75), (1.25, 0.45), CLKC, lw=1.8)
        arrow(ax, (1.25, 0.45), (2.7, 0.45), CLKC, lw=1.8)
        ax.text(4.6, 0.45, "CLK to U1 (176 mm) and U15 (337 mm): the order of the clock net is what keeps the hold positive",
                fontsize=10.5, color=CLKC, va="center")
        arrow(ax, (2.7, 0.45), (2.7, y0 + 0.4), CLKC, lw=1.8)
        arrow(ax, (2.7, y0 + 0.4), (3.2, y0 + 0.4), CLKC, lw=1.8)
        arrow(ax, (2.7, 0.45), (4.4, 0.45), CLKC, lw=1.8)
        ax.text(10.0, 3.55, "Address can change 2 + 3 + 3 = 8 ns after the edge (the Sync hop is 3 ns of minimum delay): hold +0.5 ns",
                fontsize=12.5, color=WE, ha="center", weight="bold")


fig, axes = plt.subplots(2, 1, figsize=(20, 18.4))
panel(axes[0], "Now: fetch through the Sync PLD, /WE from the memory control PLD", False)
panel(axes[1], "Option B: selects straight into the muxes, /WE from an early clock tap", True)
fig.text(0.5, 0.005, "Blue: instruction fetch (address) path.  Red: write enable.  Green: clock.  "
         "Datasheet maximums (ATF22V10C-7PX, AS7C256C-15PCN); traces not included.",
         ha="center", fontsize=11.5)
fig.tight_layout(rect=(0, 0.015, 1, 1))
fig.savefig("docs/fetch_paths.png", dpi=110)
print("wrote docs/fetch_paths.png")
