#!/usr/bin/env python3
"""
gen_memory_map.py - draw the Placard memory map as a PNG.

    python3 gen_memory_map.py                 writes reference/memory_map.png
    python3 gen_memory_map.py out.png         writes out.png

Needs matplotlib (python3 -m pip install matplotlib).  The regions are typed
in below from README.md (Memory Map), docs/ROM.md, docs/LIBRARY.md (zero
page), docs/VIDEO.md (mode byte, line repeat), docs/SOUND.md, docs/IO.md and
docs/EXPANSION.md; update them here when the map changes and rerun.

Date: 2026-10-26
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

C = {
    "video": "#4C7FD9", "videogap": "#C9D7F2",
    "mode": "#E8A33D", "audio": "#3DAE6B", "io": "#D9534F", "iodim": "#F2B8B6",
    "lib": "#8E6CC9", "font": "#B9A2E0", "drv": "#5E9FB8", "fat": "#C77DB5",
    "prog": "#F5D96B", "boot": "#555555", "zp": "#7A7A7A", "jt": "#3B3B8F",
    "free": "#EDEDED", "unused": "#FFFFFF",
}
LIGHT = {C["free"], C["unused"], C["iodim"], C["font"], C["videogap"], C["prog"]}

fig = plt.figure(figsize=(24, 14), dpi=120)
fig.suptitle("PLACARD memory map (64 KB RAM + 64 KB ROM behind one 16-bit address)", fontsize=21,
             weight="bold", y=0.978)
fig.text(0.5, 0.942,
         "Writes always go to the RAM.  CPU reads follow the map register (x5000): bit n = 1 reads section n "
         "from RAM.  Video reads always read the RAM.\n"
         "A running program uses map = 05: sections 0 and 2 read RAM; the program (x2000-x3FFF, x6000-xBFFF) "
         "and the library (xC000-xFBFF) run in place from ROM.\n"
         "The 32K image (x8000-xFFFF, the same on both cartridges) holds BASIC and a loader instead of a program; the loader "
         "runs the DOS (DOS.PLC) and programs from the SD card in RAM x0100-x3FFF with map = 07.",
         ha="center", va="top", fontsize=12, color="#444", linespacing=1.5)


def column(ax, x, regions, heights=None, width=1.0, label_dx=0.08, desc_dx=None, fs=10.5, total=None):
    """One vertical bar at x, low address at the top.  heights: drawn size of each region
    (None = to scale).  Returns the drawn height."""
    if heights is None:
        heights = [b - a + 1 for (a, b, *_) in regions]
    total = total or sum(heights)
    y = 0
    for (a, b, color, text, inside), h in zip(regions, heights):
        ax.add_patch(Rectangle((x, y), width, h, facecolor=color, edgecolor="#333", lw=0.8))
        mid = y + h / 2
        lx = x + width + label_dx
        rng = f"x{a:04X}" if a == b else f"x{a:04X}-x{b:04X}"
        if h / total < 0.045:
            ax.text(lx, mid, rng, va="center", fontsize=fs, family="monospace", weight="bold")
            ax.text(lx + (desc_dx if desc_dx else 1.05), mid, text.replace("\n", ", "), va="center",
                    fontsize=fs - 0.5, color="#222")
        else:
            ax.text(lx, mid - total * 0.006, rng, va="bottom", fontsize=fs, family="monospace", weight="bold")
            ax.text(lx, mid + total * 0.004, text, va="top", fontsize=fs - 0.5, color="#222")
        if inside:
            ax.text(x + width / 2, mid, inside, ha="center", va="center", fontsize=fs, weight="bold",
                    color="#333" if color in LIGHT else "white")
        y += h
    return y


def setup(ax, total, title, xmax):
    ax.set_xlim(-0.35, xmax)
    ax.set_ylim(total, 0)
    ax.axis("off")
    ax.set_title(title, fontsize=13.5, weight="bold", pad=26)


def side_label(ax, x, y0, y1, text, color):
    ax.plot([x, x], [y0, y1], color=color, lw=3, solid_capstyle="butt")
    ax.text(x - 0.12, (y0 + y1) / 2, text, rotation=90, va="center", ha="center", fontsize=11, color=color,
            weight="bold")


# ---- Panel A: whole 64 KB, RAM and ROM, to scale -----------------------------
axA = fig.add_axes([0.012, 0.05, 0.155, 0.77])
setup(axA, 0x10000 + 0x1400, "Whole space\n(to scale)", 2.9)
ram = [
    (0x0000, 0x1FFF, C["zp"], "", "0\nRAM"),
    (0x2000, 0x3FFF, C["free"], "", "1"),
    (0x4000, 0x4FFF, C["mode"], "", "2\nRAM"),
    (0x5000, 0x53FF, C["io"], "", None),
    (0x5400, 0x5FFF, C["mode"], "", None),
    (0x6000, 0xFFFF, C["video"], "", "3-7\n\nvideo\nRAM"),
]
rom = [
    (0x0000, 0x1FFF, C["free"], "", "0"),
    (0x2000, 0x3FFF, C["prog"], "", "1\nROM"),
    (0x4000, 0x4FFF, C["free"], "", "2"),
    (0x5000, 0x53FF, C["io"], "", None),
    (0x5400, 0x5FFF, C["free"], "", None),
    (0x6000, 0xBFFF, C["prog"], "", "3-5\n\nprogram\nROM"),
    (0xC000, 0xFFFF, C["lib"], "", "6-7\n\nlibrary\n+ boot\nROM"),
]
for x, regs in ((0.0, ram), (0.85, rom)):
    y = 0
    for (a, b, color, _, inside) in regs:
        h = b - a + 1
        axA.add_patch(Rectangle((x, a), 0.75, h, facecolor=color, edgecolor="#333", lw=0.8))
        if inside:
            axA.text(x + 0.375, a + h / 2, inside, ha="center", va="center", fontsize=10, weight="bold",
                     color="#333" if color in LIGHT else "white")
axA.text(0.375, -0x200, "RAM", ha="center", fontsize=11, weight="bold")
axA.text(1.225, -0x200, "ROM", ha="center", fontsize=11, weight="bold")
for a in (0x0000, 0x2000, 0x4000, 0x5000, 0x6000, 0x8000, 0xA000, 0xC000, 0xE000, 0x10000):
    axA.text(1.67, a, f"x{a:04X}" if a < 0x10000 else "", va="center", fontsize=9.5, family="monospace")
    axA.plot([1.6, 1.65], [a, a], color="#333", lw=0.8)
axA.text(0.0, 0x10000 + 0x600, "Number = section (map bit).\nRAM or ROM in a box = side read in map 05.",
         va="top", fontsize=9.5, color="#555")

# ---- Panel B: x0000-x3FFF, RAM and ROM ---------------------------------------
axB = fig.add_axes([0.185, 0.05, 0.215, 0.77])
low_ram = [
    (0x0000, 0x00FF, C["zp"], "Zero page", "ZP"),
    (0x0100, 0x1EFF, C["free"], "Program variables\nand buffers;\ncard boot code\nloads to x0100", None),
    (0x1F00, 0x1FFF, C["lib"], "LIB_RAM: library code\ncopied here at boot", "lib"),
    (0x2000, 0x3FFF, C["unused"], "Under the ROM;\nwrites land here", None),
]
low_rom = [
    (0x0000, 0x0003, C["boot"], "Reset jump", None),
    (0x0004, 0x1EFF, C["free"], "Free ROM", None),
    (0x1F00, 0x1FFF, C["lib"], "LIB_RAM image", "lib"),
    (0x2000, 0x3FFF, C["prog"], "Program code\nand tables\n(more room)", "program"),
]
hB_ram = [8, 44, 8, 52]
hB_rom = [6, 46, 8, 52]
setup(axB, 128, "x0000-x3FFF  (sections 0, 1)\nnot to scale", 6.2)
axB.text(0.5, -1.5, "RAM", ha="center", fontsize=11, weight="bold")
axB.text(3.4, -1.5, "ROM", ha="center", fontsize=11, weight="bold")
column(axB, 0.0, low_ram, hB_ram, total=112, desc_dx=0.0, fs=10)
column(axB, 2.9, low_rom, hB_rom, total=112, desc_dx=0.0, fs=10)
zp = ["00-03  reset code", "04-05  LINK_LO/HI", "06     SP", "07     MAP_SHADOW",
      "08-0A  frame counter", "0B-0C  RAND", "0D-0E  cursor col/row", "0F     SAVE_AC",
      "10-17  R0-R7 args", "18-1F  T0-T7 scratch", "20-8F  program vars", "90-9F  sound driver",
      "A0-BF  I/O drivers", "C0-FF  software stack"]
axB.text(0.0, 114, "Zero page x00-xFF (RAM)\n" + "\n".join(zp), va="top", fontsize=9, family="monospace",
         bbox=dict(boxstyle="round,pad=0.4", fc="#F4F4F4", ec="#999"))
axB.set_ylim(150, 0)

# ---- Panel C: x4000-x5FFF RAM ------------------------------------------------
axC = fig.add_axes([0.42, 0.05, 0.19, 0.77])
mid = [
    (0x4000, 0x4CFF, C["free"], "Program data", None),
    (0x4D00, 0x4D7F, C["fat"], "FAT reader variables (FS_VARS)", None),
    (0x4D80, 0x4DFF, C["drv"], "PS/2 keyboard variables (to x4D9F)", None),
    (0x4E00, 0x4FFF, C["fat"], "FAT sector buffer (FS_BUF)\n512 bytes", "FAT"),
    (0x5000, 0x50FF, C["io"], "W: map register  R: line counter", None),
    (0x5100, 0x51FF, C["io"], "Slot 1 (x5100) / slot 3 (x5180)", None),
    (0x5200, 0x52FF, C["io"], "Shared port: keys, SD, pads, PS/2", None),
    (0x5300, 0x53FF, C["io"], "Slot 2 (x5300) / slot 4 (x5380)", None),
    (0x5400, 0x5A1F, C["free"], "Program data", None),
    (0x5A20, 0x5BFF, C["mode"], "LINE CODES (mode bytes)\nrow r at x5A20+r, 480 rows\nbits 1:0 = 1/2/4/8 bpp\nbits 3:2 = 1x/2x/4x repeat\nbits 6:4 = R/G/B tint, 7 = blank",
     "line\ncodes"),
    (0x5C00, 0x5DF2, C["free"], "Program data", None),
    (0x5DF3, 0x5FFF, C["audio"], "AUDIO buffer, 525 bytes\n1 sample/line, 8-bit\n80h = silence", "audio"),
]
hC = [14, 4, 4, 9, 5, 5, 5, 5, 10, 16, 8, 12]
setup(axC, sum(hC), "x4000-x5FFF RAM  (section 2 + I/O)\nnot to scale", 4.4)
column(axC, 0.0, mid, hC, desc_dx=0.0, fs=10)
io0 = sum(hC[:4]); io1 = sum(hC[:8])
side_label(axC, -0.12, 0, io0, "map bit 2", "#A0681A")
side_label(axC, -0.12, io0, io1, "I/O", C["io"])
side_label(axC, -0.12, io1, sum(hC), "map bit 2", "#A0681A")
# one-line rows: put the description under the address
for t in list(axC.texts):
    pass
axC.text(0.0, sum(hC) + 1.5, "ROM under x4000-x5FFF is free.  The I/O window\nx5000-x53FF reads no RAM or ROM; a write\nthere also lands in the RAM under it.",
         va="top", fontsize=9.5, color="#555")
axC.set_ylim(sum(hC) + 12, 0)

# ---- Panel D: x6000-xFFFF ROM ------------------------------------------------
axD = fig.add_axes([0.625, 0.05, 0.16, 0.77])
hi = [
    (0x6000, 0x7FFF, C["prog"], "Program code and tables\n(64K development image:\nx6000-xBFFF, entry x6000)", "program"),
    (0x8000, 0x80FF, C["boot"], "32K image: vectors, reset copy", None),
    (0x8100, 0x9EFF, C["prog"], "32K image: program loader,\nBASIC (DOS.PLC on the card)", "BASIC"),
    (0x9F00, 0x9FFF, C["lib"], "32K image: LIB_RAM's bytes", None),
    (0xA000, 0xAFFF, C["prog"], "32K image: BASIC", None),
    (0xB000, 0xBFFF, C["fat"], "32K image: FAT file writer", None),
    (0xC000, 0xC4FF, C["drv"], "PS/2 keyboard, listening", None),
    (0xC500, 0xC5FF, C["lib"], "Menu hook (menu_poll)", None),
    (0xC600, 0xC6FF, C["lib"], "Slot helpers (slot_id)", None),
    (0xC700, 0xD4FF, C["fat"], "FAT file reader", None),
    (0xD500, 0xD6FF, C["lib"], "con_gets, mouse_move", None),
    (0xD700, 0xDBFF, C["audio"], "Sound driver", None),
    (0xDC00, 0xEBFF, C["drv"], "I/O drivers: keyboard,\npads, SD card, mouse", "I/O"),
    (0xEC00, 0xF3FF, C["font"], "8x8 font (LIB_FONT)", "font"),
    (0xF400, 0xFAFF, C["lib"], "Core routines (LIB_CODE)", "core"),
    (0xFB00, 0xFBFF, C["jt"], "Jump table (LIB_JT)", None),
    (0xFC00, 0xFC00, C["boot"], "Boot mode byte", None),
    (0xFD00, 0xFD7E, C["boot"], "Boot loader", None),
    (0xFE00, 0xFEA1, C["boot"], "Map switch, card scan", None),
]
hD = [9, 4, 7, 4, 4, 4, 4, 4, 4, 6, 4, 5, 7, 6, 6, 4, 4, 4, 4]
setup(axD, sum(hD), "x6000-xFFFF ROM  (sections 3-7)\nnot to scale", 3.7)
column(axD, 0.0, hi, hD, desc_dx=0.0, fs=10)
l0 = sum(hD[:6]); l1 = sum(hD[:16])
side_label(axD, -0.12, l0, l1, "library (most used at the top)", C["lib"])
side_label(axD, -0.12, l1, sum(hD), "boot", C["boot"])
axD.text(0.0, sum(hD) + 1.5, "Unlisted bytes in xFC01-xFFFF\nare free.", va="top", fontsize=9.5, color="#555")
axD.set_ylim(sum(hD) + 10, 0)

# one-line labels in C and D: move the description under the address so the
# narrow panels don't overflow
for ax in (axC, axD):
    texts = ax.texts
    for i, t in enumerate(texts):
        if t.get_family() == ["monospace"] and t.get_va() == "center" and i + 1 < len(texts):
            d = texts[i + 1]
            if d.get_va() == "center" and d.get_position()[0] == t.get_position()[0]:
                x, y = t.get_position()
                t.set_va("bottom"); t.set_y(y + 0.1)
                d.set_va("top"); d.set_y(y + 0.2); d.set_fontsize(9.5)

# ---- Panel E: video RAM as 2D -------------------------------------------------
axE = fig.add_axes([0.815, 0.36, 0.175, 0.46])
axE.set_title("Video RAM x6000-xFFFF (always RAM)\naddress = x6020 + column x 512 + row",
              fontsize=13, weight="bold", pad=10)
axE.add_patch(Rectangle((0, 0), 80, 32, facecolor=C["videogap"], edgecolor="#333", lw=0.8))
axE.add_patch(Rectangle((0, 32), 80, 480, facecolor=C["video"], edgecolor="#333", lw=0.8))
for c in range(0, 81, 8):
    axE.plot([c, c], [0, 512], color="white", lw=0.5, alpha=0.6)
axE.set_xlim(-2, 82)
axE.set_ylim(522, -10)
axE.set_xticks([0, 20, 40, 60, 79])
axE.set_xlabel("byte column 0-79 (A15:A9 = x30 + column)\n1 bpp: 8 pixels per byte = 640 pixels", fontsize=10)
axE.set_yticks([0, 32, 272, 511])
axE.set_yticklabels(["x000", "x020\nrow 0", "row 240", "x1FF\nrow 479"], fontsize=9)
axE.set_ylabel("offset in column (A8:A0)", fontsize=10)
axE.text(40, 16, "x00-x1F: vblank, free", ha="center", va="center", fontsize=9.5)
axE.text(40, 272, "1x: 480 rows x 80\ncolumns = 37.5 KB", ha="center", va="center", fontsize=12,
         color="white", weight="bold")
for (x, y, t, ha) in [(0, 32, "x6020", "left"), (80, 32, "xFE20", "right"),
                      (0, 512, "x61FF", "left"), (80, 512, "xFFFF", "right")]:
    axE.text(x + (0.8 if ha == "left" else -0.8), y + (16 if y == 32 else -10), t, ha=ha, va="center",
             fontsize=10, family="monospace", weight="bold", color="#FFE9A8")
axE.text(-2, 600, "Line repeat (mode byte bits 3:2) frees video RAM:\n"
         "  2x (640 x 240): the low page of each column,\n"
         "      x6000, x6200 ... xFE00 (80 x 256 B = 20 KB)\n"
         "  4x (640 x 120): all but the top 128 bytes,\n"
         "      x6000-x617F, x6200-x637F ... (30 KB)\n"
         "See reference/line_repeat_map.png.\n\n"
         "Mode bytes and the audio sample are read in\n"
         "horizontal blanking, so all 80 columns are pixels.",
         ha="left", va="top", fontsize=9.8, color="#333", family="sans-serif")

# ---- legend --------------------------------------------------------------------
items = [("Video RAM", C["video"]), ("Line codes", C["mode"]), ("Audio buffer", C["audio"]),
         ("I/O", C["io"]), ("I/O drivers", C["drv"]), ("Library", C["lib"]), ("Font", C["font"]),
         ("FAT", C["fat"]), ("Jump table", C["jt"]), ("Program (ROM)", C["prog"]), ("Boot", C["boot"]),
         ("Zero page", C["zp"]), ("Free", C["free"])]
handles = [Rectangle((0, 0), 1, 1, fc=c, ec="#333") for _, c in items]
fig.legend(handles, [n for n, _ in items], loc="lower right", bbox_to_anchor=(0.995, 0.035), ncol=3,
           fontsize=10, frameon=True)
fig.text(0.995, 0.01, "Source: README.md and docs/ on main, 2026-10-26", ha="right", fontsize=8.5,
         color="#777")

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference", "memory_map.png")
fig.savefig(out, facecolor="white")
