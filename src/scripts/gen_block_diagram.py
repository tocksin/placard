#!/usr/bin/env python3
"""
gen_block_diagram.py - draw the Placard block diagram as a PNG, with the
number of chips in each block.

    python3 gen_block_diagram.py              writes reference/placard_block_diagram.png
    python3 gen_block_diagram.py out.png      writes out.png

Needs matplotlib (python3 -m pip install matplotlib).  The blocks and
their chip counts are typed in below from docs/CHIPS.md; update them here when
the chip list changes and rerun.  The counts must add up to the docs/CHIPS.md
total (the script checks).

Date: 2026-10-21
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle

CHIPS_TOTAL = 34            # docs/CHIPS.md main board, plus the 3.3 V regulator

# fill colors by area
CPU, CTRL, MEM, IO, VID, SND, DEV = ("#E4DAFF", "#FFF2BF", "#D3F6D8", "#FFE3C8",
                                     "#DDEEFC", "#CDEFEA", "#F2F2F2")
# bus colors
ADDR, DATA, SRC, RES, OTH = "#D9480F", "#1C7ED6", "#2F9E44", "#7048E8", "#868E96"

fig = plt.figure(figsize=(22, 16), dpi=100)
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, 220)
ax.set_ylim(160, 0)
ax.axis("off")

counted = []


def box(x, y, w, h, title, chips, parts, fc, fs=12.5):
    """a block: title, the parts in it, and a badge with its chip count"""
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=1.2",
                                fc=fc, ec="#343A40", lw=2, zorder=3))
    ax.text(x + w / 2, y + h / 2 - (1.6 if parts else 0), title, ha="center", va="center",
            fontsize=fs, weight="bold", zorder=4)
    if parts:
        ax.text(x + w / 2, y + h / 2 + 2.6, parts, ha="center", va="center", fontsize=9.5,
                color="#495057", zorder=4)
    if chips is not None:
        counted.append(chips)
        label = "%d chip%s" % (chips, "" if chips == 1 else "s") if chips else "no chips"
        ax.text(x + w - 0.8, y + 0.9, label, ha="right", va="top", fontsize=9.5, weight="bold",
                color="white", zorder=5,
                bbox=dict(boxstyle="round,pad=0.25", fc="#343A40" if chips else "#868E96", ec="none"))
    return (x, y, w, h)


def wire(pts, color, lw=6, arrow=True, label=None, lpos=None, lcolor=None, fs=11):
    xs, ys = zip(*pts)
    ax.plot(xs, ys, color=color, lw=lw, solid_capstyle="butt", zorder=2)
    if arrow:
        (x0, y0), (x1, y1) = pts[-2], pts[-1]
        ax.annotate("", xy=(x1, y1), xytext=(x0 + (x1 - x0) * 0.6, y0 + (y1 - y0) * 0.6),
                    arrowprops=dict(arrowstyle="-|>,head_width=0.5,head_length=0.9", color=color,
                                    lw=lw * 0.5, shrinkA=0, shrinkB=0), zorder=2)
    if label:
        lx, ly = lpos if lpos else ((xs[0] + xs[-1]) / 2, (ys[0] + ys[-1]) / 2)
        ax.text(lx, ly, label, ha="center", va="center", fontsize=fs, weight="bold",
                color=lcolor or color, zorder=6,
                bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.9))


# ---------------------------------------------------------------- title
ax.text(3, 4, "Placard: block diagram", fontsize=24, weight="bold", va="center")
ax.text(3, 9, "%d chips and a 3.3 V regulator on the main board (docs/CHIPS.md).  The badge on each block is its "
        "chip count.  Control strobes, flags and clocks are not shown." % CHIPS_TOTAL,
        fontsize=12.5, color="#495057", va="center")

# ---------------------------------------------------------------- CPU, top row
vt = box(3, 16, 30, 16, "Video timing", 3, "H counter, V counter,\nSync PLDs", VID)
ct = box(38, 16, 30, 16, "Control", 2, "State PLD, Branch PLD", CTRL)
pc = box(73, 16, 28, 16, "Program counter", 2, "2 x 8-bit counter PLDs", CPU)
am = box(106, 16, 28, 16, "Address mux", 4, "4 PLDs: PC, D/X, Y/0,\nvideo address", CPU)

# ---------------------------------------------------------------- memory column
mapr = box(152, 14, 30, 11, "Map register x5000", 1, "ACT273: ROM or RAM\nper 8 KB section", MEM, fs=11.5)
mc = box(186, 14, 31, 11, "Memory control", 1, "PLD: /WE, /RAM_OE,\n/ROM_OE from the map", MEM, fs=11.5)
ram = box(152, 32, 30, 22, "RAM 64 KB", 2, "2 x AS7C256C\n(video reads RAM)", MEM, fs=14)
rom = box(186, 32, 31, 22, "ROM 64 KB", None, "2 x AS7C256C on the\ncartridge, loaded from\n2 x AT28C256 at power-up", MEM, fs=14)
wb = box(152, 60, 30, 11, "Bus resistors", None, "8 x R: the source bus is\nthe data bus in EXEC", DEV, fs=11.5)

# ---------------------------------------------------------------- registers row
sd = box(3, 50, 22, 16, "Source bus\ndrivers", 2, "2 x F541:\nD or AC", CPU, fs=12)
acc = box(30, 50, 15, 16, "AC", 1, "F377", CPU, fs=14)
alu = box(50, 50, 24, 16, "ALU", 2, "2 x 4-bit PLDs", CPU, fs=14)
xr = box(80, 50, 14, 16, "X", 1, "F377", CPU, fs=14)
yr = box(99, 50, 14, 16, "Y", 1, "F377", CPU, fs=14)
dr = box(3, 76, 22, 12, "D", 1, "F377: operand,\nmemory read", CPU, fs=14)
ir = box(30, 76, 22, 12, "Instruction\nregister", 1, "PLD", CTRL, fs=11.5)

# ---------------------------------------------------------------- video and sound row
lr = box(58, 102, 22, 12, "Line read x5000", 1, "F541: V9:V2", VID, fs=11)
pb = box(84, 102, 22, 12, "Pixel buffer", 1, "F377", VID, fs=12)
lc = box(110, 102, 22, 12, "Line code\nregister", 1, "F377: mode byte", VID, fs=11)
au = box(136, 102, 24, 12, "Audio / mode slots", 1, "PLD: groups 45-47,\nline repeat rows", VID, fs=11)
cd = box(110, 120, 22, 11, "Color decoder", 1, "PLD", VID, fs=12)
vga = box(110, 136, 22, 8, "Resistor DAC, VGA", None, "", DEV, fs=11)
dac = box(136, 120, 24, 11, "Audio DAC register", 1, "HCT574, R-2R ladder", SND, fs=11)
hp = box(136, 136, 24, 8, "Headphones", None, "", DEV, fs=11)

# ---------------------------------------------------------------- I/O row
iod = box(3, 102, 26, 14, "I/O decode", 1, "PLD: x5000-x53FF,\n/CE_HI for the ROM", IO, fs=12)
port = box(3, 124, 68, 20, "Shared port x5200", 3,
           "HC574 latch, port PLD (columns, pad DATA),\nF541 input (rows, MISO, PS/2),\n"
           "resistor dividers to 3.3 V for the SD card", IO, fs=13)
kb = box(3, 149, 16, 9, "Keyboard", None, "8 x 8 matrix", DEV, fs=10.5)
pads = box(21, 149, 16, 9, "2 SNES pads", None, "", DEV, fs=10.5)
sdc = box(39, 149, 16, 9, "SD card", None, "+ 3.3 V reg.", DEV, fs=10.5)
ms = box(57, 149, 14, 9, "PS/2 mouse", None, "", DEV, fs=10.5)
exp = box(166, 102, 51, 20, "4 expansion slots", 0,
          "x5100-x53FF, 128 bytes each; data, source\nbus, A7:A0, RW, /WE, clock.  A card\n"
          "with a \"PLC\" boot header runs at power-up", IO, fs=13)
cart = box(186, 60, 31, 11, "ROM cartridge slot", 0, "cartridge: 5 chips, stalls\nthe CPU while loading", MEM, fs=11.5)

total = sum(counted)
assert total == CHIPS_TOTAL, "blocks add up to %d chips, docs/CHIPS.md says %d" % (total, CHIPS_TOTAL)

# ---------------------------------------------------------------- buses
# address bus
wire([(134, 24), (152, 24)], ADDR, lw=9, arrow=False)
wire([(148, 24), (148, 28.5), (167, 28.5), (167, 32)], ADDR, lw=9)
wire([(167, 28.5), (201, 28.5), (201, 32)], ADDR, lw=9)
wire([(141, 24), (141, 95), (16, 95), (16, 102)], ADDR, lw=6, label="ADDRESS BUS (16)",
     lpos=(141, 36), lcolor=ADDR)
wire([(141, 95), (191, 95), (191, 102)], ADDR, lw=6, label="A7:A0", lpos=(178, 95))

# source bus
wire([(14, 50), (14, 42), (148, 42)], SRC, lw=8, arrow=False, label="SOURCE BUS (8)",
     lpos=(40, 42))
wire([(62, 42), (62, 50)], SRC, lw=6)                      # ALU B
wire([(87, 42), (87, 32)], SRC, lw=6, label="PC low", lpos=(91, 37), fs=10)
wire([(144, 42), (144, 65.5), (152, 65.5)], SRC, lw=6)       # series resistors
wire([(137, 42), (137, 20), (152, 20)], SRC, lw=5, label="map", lpos=(137, 30), fs=9.5)
wire([(144, 65.5), (144, 98), (40, 98), (40, 124)], SRC, lw=5,
     label="write data", lpos=(100, 98), fs=10)
wire([(144, 98), (200, 98), (200, 102)], SRC, lw=5)

# data bus
wire([(167, 54), (167, 57), (184, 57)], DATA, lw=6, arrow=False)
wire([(201, 54), (201, 57), (184, 57)], DATA, lw=6, arrow=False)
wire([(167, 60), (167, 57)], OTH, lw=4)                     # series resistors -> memory data
wire([(184, 57), (184, 74), (60, 74), (14, 74), (14, 76)], DATA, lw=9,
     label="DATA BUS (8)", lpos=(100, 74))
wire([(41, 74), (41, 76)], DATA, lw=6)
wire([(95, 74), (95, 102)], DATA, lw=6)
wire([(121, 74), (121, 102)], DATA, lw=6)
wire([(69, 102), (69, 74)], DATA, lw=6)                     # line read drives it
wire([(30, 124), (30, 92), (60, 92), (60, 74)], DATA, lw=6, label="read", lpos=(45, 92), fs=10)
wire([(172, 102), (172, 74)], DATA, lw=6, label="card reads", lpos=(172, 86), fs=10)

# ALU result bus
wire([(62, 66), (62, 70), (37, 70), (37, 66)], RES, lw=6)
wire([(62, 70), (87, 70), (87, 66)], RES, lw=6)
wire([(87, 70), (106, 70), (106, 66)], RES, lw=6, label="ALU RESULT", lpos=(97, 70), fs=10)

# other connections
wire([(18, 16), (18, 11), (120, 11), (120, 16)], OTH, lw=4, label="video address",
     lpos=(70, 11), fs=10)
wire([(101, 24), (106, 24)], OTH, lw=4)
wire([(45, 58), (50, 58)], OTH, lw=4)                       # AC -> ALU A
wire([(30, 62), (25, 62)], OTH, lw=4)                       # AC -> drivers
wire([(25, 82), (27, 82), (27, 68), (20, 68), (20, 66)], OTH, lw=4)  # D -> drivers
wire([(87, 50), (87, 46), (114, 46), (114, 32)], OTH, lw=4)          # X -> mux
wire([(106, 50), (106, 47), (124, 47), (124, 32)], OTH, lw=4, label="X, Y",
     lpos=(119, 47), fs=9.5)
wire([(95, 114), (95, 125.5), (110, 125.5)], OTH, lw=4)    # pixel buffer -> color decoder
wire([(121, 114), (121, 120)], OTH, lw=4)
wire([(121, 131), (121, 136)], OTH, lw=4)
wire([(103, 114), (103, 117), (148, 117), (148, 120)], OTH, lw=4, label="sample",
     lpos=(140, 117), fs=9.5)
wire([(148, 131), (148, 136)], OTH, lw=4)
wire([(132, 108), (136, 108)], OTH, lw=4)
wire([(182, 19.5), (186, 19.5)], OTH, lw=4)                # map -> memory control
wire([(29, 112), (34, 112), (34, 124)], OTH, lw=4, label="strobes", lpos=(36, 109), fs=9.5)
for d in (kb, pads, sdc, ms):
    cx = d[0] + d[2] / 2
    wire([(cx, 144), (cx, 149)], OTH, lw=3, arrow=False)

# ---------------------------------------------------------------- legend
ly = 128
for name, col in (("Address bus (16 bits)", ADDR), ("Data bus: memory and I/O reads", DATA),
                  ("Source bus: D or AC; write data", SRC), ("ALU result", RES),
                  ("Other connections", OTH)):
    ax.add_patch(Rectangle((166, ly), 7, 2.2, fc=col, ec="none"))
    ax.text(175, ly + 1.1, name, va="center", fontsize=11.5)
    ly += 4.6
ax.text(166, 154, "Section reads follow the map register; video reads and all writes use RAM.\n"
        "Source: docs/CHIPS.md, docs/IO.md, docs/EXPANSION.md, docs/SOUND.md, docs/VIDEO.md on 2026-10-19.",
        fontsize=10, color="#495057", va="top")

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference", "placard_block_diagram.png")
fig.savefig(out, facecolor="white")
print("wrote %s (%d chips in the blocks)" % (out, total))
