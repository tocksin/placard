#!/usr/bin/env python3
"""
gen_memory_map.py - draw the Placard memory map as a PNG.

    python3 gen_memory_map.py                 writes reference/memory_map.png
    python3 gen_memory_map.py out.png         writes out.png

Needs matplotlib (python3 -m pip install matplotlib).  The regions are typed
in below from README.md (Memory Map), docs/VIDEO.md (Mode byte), docs/SOUND.md and
docs/LIBRARY.md; update them here when the map changes and rerun.

Date: 2026-10-18
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import sys

C = {
    "video": "#4C7FD9", "videogap": "#C9D7F2",
    "mode": "#E8A33D", "audio": "#3DAE6B", "io": "#D9534F", "iomirror": "#F2B8B6",
    "lib": "#8E6CC9", "font": "#B9A2E0", "zp": "#7A7A7A", "free": "#EDEDED",
    "unused": "#FFFFFF",
}

fig = plt.figure(figsize=(20, 12), dpi=130)
fig.suptitle("PLACARD memory map (64 KB, 16-bit address, 8-bit data)", fontsize=20, weight="bold", y=0.975)
fig.text(0.5, 0.935, "CPU reads of each 8 KB section come from RAM or ROM per the map register at x5000; video reads and all writes "
         "use RAM.  x5000-x53FF is the I/O window.  Programs run from ROM (docs/ROM.md).", ha="center", fontsize=11.5, color="#444")


LIGHT = {C["free"], C["unused"], C["iomirror"], C["font"], C["videogap"]}


def bar(ax, regions, title, heights=None, width=1.0, label_x=1.08, fs=10.5):
    """Vertical bar, low address at top.  heights: drawn size of each region (None = to scale)."""
    if heights is None:
        heights = [b - a + 1 for (a, b, *_ ) in regions]
    total = sum(heights)
    ax.set_xlim(0, 3.6)
    ax.set_ylim(total, 0)
    ax.axis("off")
    ax.set_title(title, fontsize=13, weight="bold", pad=10)
    y = 0
    for (a, b, color, text, inside), h in zip(regions, heights):
        ax.add_patch(Rectangle((0, y), width, h, facecolor=color, edgecolor="#333", lw=0.8))
        mid = y + h / 2
        one_line = h / total < 0.05
        if one_line:
            ax.text(label_x, mid, f"x{a:04X}-x{b:04X}  " + text.replace("\n", ", "), va="center", fontsize=fs - 0.5)
            ax.texts[-1].set_text(f"x{a:04X}-x{b:04X}")
            ax.texts[-1].set_family("monospace"); ax.texts[-1].set_weight("bold"); ax.texts[-1].set_fontsize(fs)
            ax.text(label_x + 1.0, mid, text.replace("\n", ", "), va="center", fontsize=fs - 0.5, color="#222")
        else:
            ax.text(label_x, mid - total * 0.012, f"x{a:04X}-x{b:04X}", va="bottom", fontsize=fs,
                    family="monospace", weight="bold")
            ax.text(label_x, mid, text, va="top", fontsize=fs - 0.5, color="#222")
        if inside and not one_line:
            ax.text(width / 2, mid, inside, ha="center", va="center", fontsize=fs + 1, weight="bold",
                    color="#333" if color in LIGHT else "white")
        y += h
    return ax


# ---- Panel A: full 64 KB ------------------------------------------------------
axA = fig.add_axes([0.02, 0.05, 0.20, 0.80])
full = [
    (0x0000, 0x1FFF, C["free"], "map bit 0\nzero page + program", "0"),
    (0x2000, 0x3FFF, C["lib"], "map bit 1\nI/O drivers + library\n+ font (ROM)", "1"),
    (0x4000, 0x4FFF, C["free"], "map bit 2: free program RAM", "2"),
    (0x5000, 0x53FF, C["io"], "I/O window (no map bit)", "I/O"),
    (0x5400, 0x5FFF, C["mode"], "map bit 2: line codes, audio", "2"),
    (0x6000, 0x7FFF, C["video"], "map bit 3\nvideo RAM\nprogram ROM x6000-xDFFF", "3"),
    (0x8000, 0x9FFF, C["video"], "map bit 4\nvideo RAM", "4"),
    (0xA000, 0xBFFF, C["video"], "map bit 5\nvideo RAM", "5"),
    (0xC000, 0xDFFF, C["video"], "map bit 6\nvideo RAM", "6"),
    (0xE000, 0xFFFF, C["video"], "map bit 7\nvideo RAM\nlibrary bank 2 (ROM)", "7"),
]
bar(axA, full, "Whole address space (to scale)")
axA.set_ylim(0x10000 + 0x900, 0)
axA.text(0.5, 0x10000 + 0x300, "box number = map bit", ha="center", va="top", fontsize=9.5, color="#555")

# ---- Panel B: x0000-x3FFF -----------------------------------------------------
axB = fig.add_axes([0.25, 0.05, 0.19, 0.80])
low = [
    (0x0000, 0x00FF, C["zp"], "Zero page (see below)", None),
    (0x0100, 0x1FFF, C["free"], "Program RAM x0100-x1FFF\n(x0100: card boot code)", None),
    (0x2000, 0x2FFF, C["lib"], "I/O drivers (IO_CODE, ROM)\nkeyboard, mouse, SD", "io"),
    (0x3000, 0x36FF, C["lib"], "Standard library code\n(LIB_CODE, ROM)", "lib"),
    (0x3700, 0x37FF, C["lib"], "Library: con_scroll", None),
    (0x3800, 0x3FFF, C["font"], "8x8 font, 2 KB\n(LIB_FONT, ROM)", "font"),
]
bar(axB, low, "x0000-x3FFF  (sections 0, 1)\nnot to scale", heights=[8, 26, 14, 14, 5, 12])
zp = ["00-03  unused (old demos: reset)", "04-05  LINK_LO/HI", "06     SP", "07     MAP_SHADOW",
      "08-0A  frame counter", "0B-0C  RAND", "0D-0E  cursor col/row", "0F     SAVE_AC",
      "10-17  R0-R7 args", "18-1F  T0-T7 scratch", "20-8F  program vars", "90-9E  sound driver", "A0-BF  I/O drivers", "C0-FF  software stack"]
axB.text(0.02, 81, "Zero page x00-xFF\n" + "\n".join(zp), va="top", fontsize=9, family="monospace",
         bbox=dict(boxstyle="round,pad=0.4", fc="#F4F4F4", ec="#999"))
axB.set_ylim(118, 0)
for y in (0x4000,):
    pass

# ---- Panel C: x4000-x5FFF -----------------------------------------------------
axC = fig.add_axes([0.47, 0.05, 0.22, 0.80])
mid = [
    (0x4000, 0x4CFF, C["free"], "Free program RAM", None),
    (0x4D00, 0x4FFF, C["lib"], "SD/FAT variables x4D00\nsector buffer x4E00-x4FFF", None),
    (0x5000, 0x50FF, C["io"], "W: map register  R: line counter", None),
    (0x5100, 0x51FF, C["io"], "/EXP1 expansion 1", None),
    (0x5200, 0x52FF, C["io"], "Shared port: SD, keys, mouse", None),
    (0x5300, 0x53FF, C["io"], "/EXP2 expansion 2", None),
    (0x5400, 0x5A1F, C["free"], "Free program RAM", None),
    (0x5A20, 0x5BFF, C["mode"], "LINE CODES (mode bytes)\nrow r at x5A20+r, 480 rows\nbits 1:0 = 1/2/4/8 bpp\nbits 3:2 = 1x/2x/4x repeat", "line\ncodes"),
    (0x5C00, 0x5DF2, C["free"], "Free program RAM", None),
    (0x5DF3, 0x5FFF, C["audio"], "AUDIO buffer, 525 bytes\n1 sample/line, 8-bit, 80h = silence", "audio"),
]
hC = [12, 6, 4, 4, 4, 4, 9, 13, 7, 11]
bar(axC, mid, "x4000-x5FFF  (section 2 + I/O window)\nnot to scale", heights=hC, fs=10)
io0 = sum(hC[:2]); end = sum(hC[:6])
axC.annotate("", xy=(-0.12, io0), xytext=(-0.12, end),
             arrowprops=dict(arrowstyle="-", lw=3, color=C["io"]))
axC.text(-0.22, (io0 + end) / 2, "I/O window", rotation=90, va="center", ha="center", fontsize=11, color=C["io"], weight="bold")
axC.annotate("", xy=(-0.12, 0), xytext=(-0.12, io0),
             arrowprops=dict(arrowstyle="-", lw=3, color=C["mode"]))
axC.text(-0.22, io0 / 2, "map bit 2", rotation=90, va="center", ha="center", fontsize=11, color="#A0681A", weight="bold")
axC.annotate("", xy=(-0.12, end), xytext=(-0.12, sum(hC)),
             arrowprops=dict(arrowstyle="-", lw=3, color=C["mode"]))
axC.text(-0.22, (end + sum(hC)) / 2, "map bit 2", rotation=90, va="center", ha="center", fontsize=11, color="#A0681A", weight="bold")
axC.set_xlim(-0.3, 3.6)

# ---- Panel D: video RAM as 2D -------------------------------------------------
axD = fig.add_axes([0.775, 0.30, 0.21, 0.52])
axD.set_title("Video RAM x6000-xFFFF as the screen sees it\naddress = x6020 + column x 512 + row (1x)",
              fontsize=13, weight="bold", pad=10)
axD.add_patch(Rectangle((0, 0), 80, 32, facecolor=C["videogap"], edgecolor="#333", lw=0.8))
axD.add_patch(Rectangle((0, 32), 80, 480, facecolor=C["video"], edgecolor="#333", lw=0.8))
for c in range(0, 81, 8):
    axD.plot([c, c], [0, 512], color="white", lw=0.5, alpha=0.6)
axD.set_xlim(-2, 82)
axD.set_ylim(522, -10)
axD.set_xticks([0, 10, 20, 30, 40, 50, 60, 70, 79])
axD.set_xlabel("byte column 0-79 (address bits A15:A9 = x30 + column)\n1 bpp: 8 pixels per byte = 640 pixels", fontsize=10)
axD.set_yticks([0, 32, 132, 232, 332, 432, 511])
axD.set_yticklabels(["x000", "x020 (row 0)", "row 100", "row 200", "row 300", "row 400", "x1FF (row 479)"], fontsize=9)
axD.set_ylabel("offset in column (A8:A0)", fontsize=10)
axD.text(40, 16, "x00-x1F of each column: vblank lines, not displayed", ha="center", va="center", fontsize=9.5)
axD.text(40, 272, "480 visible rows x 80 byte columns\n38,400 bytes", ha="center", va="center", fontsize=13,
         color="white", weight="bold")
for (x, y, t, ha) in [(0, 32, "x6020", "left"), (80, 32, "xFE20", "right"),
                      (0, 512, "x61FF", "left"), (80, 512, "xFFFF", "right")]:
    axD.text(x + (0.8 if ha == "left" else -0.8), y + (14 if y == 32 else -8), t, ha=ha, va="center",
             fontsize=10, family="monospace", weight="bold", color="#FFE9A8")
axD.text(0, -4, "x6000", ha="left", va="bottom", fontsize=9, family="monospace")
axD.text(80, -4, "xFE00", ha="right", va="bottom", fontsize=9, family="monospace")
axD.text(40, 620, "Line codes (x5A20+row) and the audio sample (x5DF3-x5FFF)\n"
         "are fetched in horizontal blanking, so all 80 columns are pixels.\n"
         "Pixel fill: the video XORs each byte into the running color.",
         ha="center", va="top", fontsize=10, color="#333")

# ---- legend --------------------------------------------------------------------
items = [("Video RAM", C["video"]), ("Line codes", C["mode"]), ("Audio buffer", C["audio"]),
         ("I/O", C["io"]), ("Std library", C["lib"]),
         ("Font", C["font"]), ("Zero page", C["zp"]), ("Free program RAM", C["free"])]
handles = [Rectangle((0, 0), 1, 1, fc=c, ec="#333") for _, c in items]
fig.legend(handles, [n for n, _ in items], loc="lower right", bbox_to_anchor=(0.985, 0.04), ncol=3, fontsize=10,
           frameon=True)
fig.text(0.985, 0.012, "Source: README.md, docs/VIDEO.md, docs/SOUND.md, docs/LIBRARY.md on main, 2026-10-18", ha="right",
         fontsize=8.5, color="#777")

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference", "memory_map.png")
fig.savefig(out, facecolor="white")
