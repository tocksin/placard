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

The blocks are grouped in three panels: the CPU on the left, memory, I/O
and audio in the middle, video on the right.  The address, source and data
buses run down the gap between the CPU and the middle panel; the data bus
carries on under the middle panel and up the gap to the video panel.

Date: 2026-10-23
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patheffects as pe
from matplotlib.patches import FancyBboxPatch, Rectangle

CHIPS_TOTAL = 34            # docs/CHIPS.md main board, plus the 3.3 V regulator

# fill colors by area
CPU, CTRL, MEM, IO, VID, SND, DEV = ("#E4DAFF", "#FFF2BF", "#D3F6D8", "#FFE3C8",
                                     "#DDEEFC", "#CDEFEA", "#F2F2F2")
# panel backgrounds
P_CPU, P_MID, P_VID = "#F6F2FF", "#F4FBF2", "#F1F7FE"
# bus colors
ADDR, DATA, SRC, RES, OTH = "#D9480F", "#1C7ED6", "#2F9E44", "#7048E8", "#868E96"

# x of the bus trunks
XA, XS, XD = 85, 90, 95     # address, source, data, between the CPU and the middle
XD2 = 176                   # data bus up to the video panel
YD = 177                    # data bus under the middle panel

fig = plt.figure(figsize=(24, 18.6), dpi=100)
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, 240)
ax.set_ylim(186, 0)
ax.axis("off")

counted = []
group_chips = {}


def panel(x, y, w, h, title, fc, key):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=2",
                                fc=fc, ec="#ADB5BD", lw=2, ls="--", zorder=0))
    group_chips[key] = []
    return ax.text(x + 2, y + 4.2, title, fontsize=21, weight="bold", va="center",
                   color="#343A40", zorder=1)


def box(x, y, w, h, title, chips, parts, fc, group, fs=16, pfs=12.5):
    """a block: title, the parts in it, and a badge with its chip count"""
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=1.2",
                                fc=fc, ec="#343A40", lw=2, zorder=3))
    nl = parts.count("\n") + 1 if parts else 0
    ty = y + h / 2 - (1.0 + 1.1 * nl if parts else 0)
    ax.text(x + w / 2, ty, title, ha="center", va="center", fontsize=fs, weight="bold", zorder=4)
    if parts:
        ax.text(x + w / 2, ty + 2.3 + 1.1 * nl, parts, ha="center", va="center", fontsize=pfs,
                color="#495057", zorder=4, linespacing=1.15)
    if chips is not None:
        counted.append(chips)
        group_chips[group].append(chips)
        label = "%d chip%s" % (chips, "" if chips == 1 else "s") if chips else "no chips"
        ax.text(x + w - 0.6, y + 0.7, label, ha="right", va="top", fontsize=11.5, weight="bold",
                color="white", zorder=5,
                bbox=dict(boxstyle="round,pad=0.25", fc="#343A40" if chips else "#868E96", ec="none"))
    return (x, y, w, h)


def wire(pts, color, lw=5, arrow=True, label=None, lpos=None, fs=13, both=False, z=2):
    xs, ys = zip(*pts)
    ax.plot(xs, ys, color=color, lw=lw, solid_capstyle="butt", solid_joinstyle="miter", zorder=z)

    def head(p0, p1):
        (x0, y0), (x1, y1) = p0, p1
        ax.annotate("", xy=(x1, y1), xytext=(x1 - (x1 - x0) * 0.01, y1 - (y1 - y0) * 0.01),
                    arrowprops=dict(arrowstyle="-|>,head_width=0.55,head_length=1.0", color=color,
                                    lw=lw * 0.5, shrinkA=0, shrinkB=0), zorder=z + 0.1)
    if arrow:
        head(pts[-2], pts[-1])
    if both:
        head(pts[1], pts[0])
    if label:
        lx, ly = lpos if lpos else ((xs[0] + xs[-1]) / 2, (ys[0] + ys[-1]) / 2)
        ax.text(lx, ly, label, ha="center", va="center", fontsize=fs, weight="bold",
                color=color, zorder=6,
                bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none", alpha=0.92))


def trunk(pts, color, lw=10):
    """a bus trunk, drawn over the stubs it crosses with a white edge"""
    xs, ys = zip(*pts)
    ax.plot(xs, ys, color=color, lw=lw, solid_capstyle="butt", solid_joinstyle="miter", zorder=2.5,
            path_effects=[pe.Stroke(linewidth=lw + 5, foreground="white"), pe.Normal()])


def dot(x, y, color):
    ax.plot([x], [y], "o", ms=11, color=color, zorder=2.6)


# ---------------------------------------------------------------- title
ax.text(3, 4, "Placard: block diagram", fontsize=30, weight="bold", va="center")
ax.text(3, 9.3, "%d chips and a 3.3 V regulator on the main board, every PLD an ATF22V10C-7PX "
        "(docs/CHIPS.md).  The badge on each block is its chip count." % CHIPS_TOTAL,
        fontsize=15, color="#495057", va="center")

# ---------------------------------------------------------------- panels
h_cpu = panel(2, 15, 78, 158, "CPU", P_CPU, "cpu")
h_mid = panel(100, 15, 71, 158, "Memory, I/O and audio", P_MID, "mid")
h_vid = panel(181, 15, 57, 158, "Video", P_VID, "vid")

# ---------------------------------------------------------------- CPU
pc = box(4, 24, 33, 15, "Program counter", 2, "2 x 8-bit counter PLDs", CPU, "cpu")
am = box(43, 24, 35, 15, "Address mux", 4, "4 PLDs: PC, D or X,\nY or zero page, video", CPU, "cpu")
ct = box(4, 45, 33, 15, "Control", 2, "State PLD, Branch PLD:\nstall, carry flag", CTRL, "cpu")
ir = box(43, 45, 35, 15, "Instruction register", 1, "PLD: holds 02h (nop)\nwhile the cart loads",
         CTRL, "cpu", fs=15.5)
xr = box(4, 68, 15, 13, "X", 1, "F377", CPU, "cpu", fs=18)
yr = box(22, 68, 15, 13, "Y", 1, "F377", CPU, "cpu", fs=18)
alu = box(43, 68, 35, 13, "ALU", 2, "2 x 4-bit PLDs", CPU, "cpu", fs=18)
dr = box(4, 90, 15, 13, "D", 1, "F377", CPU, "cpu", fs=18)
acc = box(22, 90, 15, 13, "AC", 1, "F377", CPU, "cpu", fs=18)
sd = box(43, 90, 35, 13, "Source bus drivers", 2, "2 x F541: D or AC", CPU, "cpu", fs=15.5)

# ---------------------------------------------------------------- memory, I/O, audio
mapr = box(104, 24, 31, 13, "Map register", 1, "ACT273 at x5000:\nROM or RAM per 8 KB", MEM, "mid",
           fs=15)
mc = box(139, 24, 30, 13, "Memory control", 1, "PLD: /WE, /RAM_OE,\n/ROM_OE", MEM, "mid", fs=15)
ram = box(104, 44, 31, 15, "RAM 64 KB", 2, "2 x AS7C256C,\nvideo reads RAM", MEM, "mid", fs=17)
rom = box(139, 44, 30, 15, "Cartridge slot", 0, "ROM 64 KB, 5 chips:\nstalls the CPU to load",
          MEM, "mid", fs=15)
wb = box(104, 63, 31, 9, "Bus resistors", None, "8 x R: write data", DEV, "mid", fs=13.5, pfs=12)
iod = box(104, 78, 31, 14, "I/O decode", 1, "PLD: x5000-x53FF,\n/CE_HI", IO, "mid", fs=15)
exp = box(139, 78, 30, 17, "4 expansion slots", 0, "x5100-x53FF; a card\nwith a \"PLC\" header\n"
          "boots at power-up", IO, "mid", fs=14.5, pfs=12)
port = box(104, 100, 65, 16, "Shared port x5200", 3,
           "HC574 latch, port PLD, F541 input;\nresistor dividers to 3.3 V for the SD card",
           IO, "mid", fs=16)
devs = []
for i, (t, p) in enumerate((("Keyboard", "8 x 8 matrix"), ("PS/2", "keyboard\n+ mouse"),
                            ("2 SNES", "pads"), ("SD card", "3.3 V reg."))):
    devs.append(box(104 + i * 16.5, 121, 15, 12, t, None, p, DEV, "mid", fs=13, pfs=11.5))
aus = box(104, 141, 31, 16, "Audio / mode slots", 1, "PLD: groups 45-47,\nline repeat rows",
          SND, "mid", fs=14.5)
dac = box(139, 141, 30, 16, "Audio DAC", 1, "HCT574 register,\nR-2R ladder", SND, "mid", fs=15)
hp = box(139, 162, 30, 8, "Headphones", None, "", DEV, "mid", fs=13.5)

# ---------------------------------------------------------------- video
vt = box(184, 24, 52, 16, "Video timing", 3, "H counter, V counter, Sync PLDs:\nHSYNC, VSYNC, "
         "video address", VID, "vid")
lr = box(184, 46, 42, 11, "Line read x5000", 1, "F541: V9:V2", VID, "vid", fs=15)
pb = box(184, 62, 42, 12, "Pixel buffer", 1, "F377: byte read from RAM", VID, "vid", fs=15)
lc = box(184, 80, 30, 16, "Line code", 1, "HCT377: mode,\nrepeat, tint, blank", VID, "vid", fs=15)
cd = box(184, 103, 30, 13, "Color decoder", 1, "PLD: to RGB", VID, "vid", fs=15)
vga = box(184, 124, 52, 13, "Resistor DAC, VGA", None, "RGB ladders and row tint\nresistors, "
          "gated by VIDEN", DEV, "vid", fs=15)

total = sum(counted)
assert total == CHIPS_TOTAL, "blocks add up to %d chips, docs/CHIPS.md says %d" % (total, CHIPS_TOTAL)
for h, key in ((h_cpu, "cpu"), (h_mid, "mid"), (h_vid, "vid")):
    h.set_text("%s: %d chips" % (h.get_text(), sum(group_chips[key])))

# ---------------------------------------------------------------- bus trunks
trunk([(XA, 31), (XA, 85)], ADDR)
trunk([(XS, 30.5), (XS, 112)], SRC)
trunk([(XD, 52), (XD, YD), (XD2, YD), (XD2, 51.5)], DATA)
ax.text(XD2, 112, "DATA (8)", rotation=90, ha="center", va="center", fontsize=13,
        weight="bold", color=DATA, bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none"))

# ---------------------------------------------------------------- address bus
wire([(78, 31.5), (XA, 31.5)], ADDR, lw=7, arrow=False)
wire([(XA, 40.5), (152, 40.5), (152, 44)], ADDR, lw=7)
wire([(119, 40.5), (119, 44)], ADDR, lw=7)
dot(119, 40.5, ADDR)
wire([(XA, 85), (104, 85)], ADDR, lw=6)
wire([(XA, 75), (152, 75), (152, 78)], ADDR, lw=5, label="A7:A0", lpos=(144, 75))
ax.text(XA - 3, 63.5, "ADDRESS (16)", rotation=90, ha="center", va="center", fontsize=13,
        weight="bold", color=ADDR)

# ---------------------------------------------------------------- source bus
wire([(78, 96.5), (XS, 96.5)], SRC, lw=7, arrow=False)
wire([(XS, 74.5), (78, 74.5)], SRC, lw=5, label="B", lpos=(81.5, 72.5), fs=12)
wire([(XS, 42), (30, 42), (30, 39)], SRC, lw=5, label="branch target", lpos=(60, 42), fs=12)
wire([(XS, 30.5), (104, 30.5)], SRC, lw=5)
wire([(XS, 67.5), (104, 67.5)], SRC, lw=5)
wire([(119, 63), (119, 59)], SRC, lw=5)
wire([(XS, 104), (104, 104)], SRC, lw=5, label="write", lpos=(99.5, 101.5), fs=11)
ax.text(XS + 3, 125, "SOURCE BUS (8)", rotation=90, ha="center", va="center", fontsize=13,
        weight="bold", color=SRC)

# ---------------------------------------------------------------- data bus
wire([(XD, 52.5), (78, 52.5)], DATA, lw=6, label="opcode", lpos=(82, 55), fs=11)
wire([(XD, 112.5), (11.5, 112.5), (11.5, 103)], DATA, lw=6, label="operand", lpos=(30, 112.5),
     fs=12)
wire([(112, 59), (112, 61), (XD, 61)], DATA, lw=6, arrow=False)
wire([(160, 59), (160, 61), (137, 61)], DATA, lw=6, arrow=False)
wire([(137, 61), (137, 61), (112, 61)], DATA, lw=6, arrow=False)
dot(112, 61, DATA)
wire([(104, 112), (XD, 112.0)], DATA, lw=5, label="read", lpos=(99.5, 115), fs=11)
wire([(XD2, 86.5), (169, 86.5)], DATA, lw=5, both=True)
wire([(XD2, 68), (184, 68)], DATA, lw=6)
wire([(184, 51.5), (XD2, 51.5)], DATA, lw=6)
ax.text(XD + 3, 150, "DATA BUS (8)", rotation=90, ha="center", va="center", fontsize=13,
        weight="bold", color=DATA)
ax.text(136, YD + 3.2, "DATA BUS (8)", ha="center", va="center", fontsize=13, weight="bold",
        color=DATA)

# ---------------------------------------------------------------- ALU result
wire([(60, 81), (60, 85.5), (8, 85.5), (8, 81)], RES, lw=5)
wire([(26, 85.5), (26, 81)], RES, lw=5)
wire([(33, 85.5), (33, 90)], RES, lw=5)
ax.text(47, 87.7, "ALU RESULT", ha="center", va="top", fontsize=11, weight="bold", color=RES)

# ---------------------------------------------------------------- other CPU connections
wire([(37, 31.5), (43, 31.5)], OTH, lw=4)                               # PC -> mux
wire([(11.5, 68), (11.5, 64), (40, 64), (40, 36), (43, 36)], OTH, lw=4)  # X -> mux
wire([(29.5, 68), (29.5, 64)], OTH, lw=4, arrow=False)                  # Y -> mux
ax.text(25, 64, "X, Y", ha="center", va="center", fontsize=11.5, weight="bold", color=OTH,
        bbox=dict(boxstyle="round,pad=0.1", fc=P_CPU, ec="none"))
wire([(43, 52.5), (37, 52.5)], OTH, lw=4)                               # IR -> control
wire([(37, 96.5), (43, 96.5)], OTH, lw=4)                               # AC -> drivers
wire([(37, 99.5), (40, 99.5), (40, 74.5), (43, 74.5)], OTH, lw=4)       # AC -> ALU A
ax.text(41.2, 77.5, "A", ha="center", va="center", fontsize=11, weight="bold", color=OTH)
wire([(15.5, 103), (15.5, 107), (55, 107), (55, 103)], OTH, lw=4)       # D -> drivers

# ---------------------------------------------------------------- other middle connections
wire([(135, 30.5), (139, 30.5)], OTH, lw=4)                             # map -> memory control
for d in devs:
    cx = d[0] + d[2] / 2
    wire([(cx, 116), (cx, 121)], OTH, lw=3, arrow=False)
wire([(154, 157), (154, 162)], OTH, lw=4)                               # DAC -> headphones

# ---------------------------------------------------------------- video connections
wire([(224, 12), (62, 12), (62, 24)], OTH, lw=5, label="video address", lpos=(143, 12))
wire([(224, 24), (224, 12)], OTH, lw=5, arrow=False)
wire([(205, 40), (205, 46)], OTH, lw=4)                                 # V9:V2 -> line read
wire([(190, 74), (190, 80)], OTH, lw=4, label="mode", lpos=(194.5, 77), fs=11)
wire([(219, 74), (219, 109.5), (214, 109.5)], OTH, lw=4, label="pixels", lpos=(219, 100), fs=11)
wire([(199, 96), (199, 103)], OTH, lw=4)
wire([(199, 116), (199, 124)], OTH, lw=4)
wire([(214, 92), (228, 92), (228, 124)], OTH, lw=4, label="tint", lpos=(228, 110), fs=11)
wire([(214, 84), (233, 84), (233, 40)], OTH, lw=4, label="blank", lpos=(233, 60), fs=11)
wire([(184, 71), (179.5, 71), (179.5, 152), (169, 152)], OTH, lw=4, label="sample",
     lpos=(179.5, 130), fs=11)
ax.text(210, 147, "to the VGA connector", ha="center", va="center", fontsize=12.5, color="#495057")
wire([(210, 137), (210, 143)], OTH, lw=4)

# ---------------------------------------------------------------- legend
ly = 126
ax.text(4, 121, "Buses", fontsize=15, weight="bold", va="center")
for name, col in (("Address bus (16 bits)", ADDR), ("Data bus: memory and I/O reads", DATA),
                  ("Source bus: D or AC; write data", SRC), ("ALU result", RES),
                  ("Other connections", OTH)):
    ax.add_patch(Rectangle((4, ly - 1.2), 8, 2.6, fc=col, ec="none"))
    ax.text(14, ly + 0.1, name, va="center", fontsize=13.5)
    ly += 5.2
ax.text(4, 154, "Control strobes, flags and clocks are not\nshown.  Section reads follow the map "
        "register;\nvideo reads and all writes use RAM.\nCartridge: 2 SRAMs, 2 EEPROMs and a\n"
        "loader PLD that holds STALL and copies the\nEEPROMs into the SRAMs at power-up.",
        fontsize=12, color="#495057", va="top", linespacing=1.3)
ax.text(238, 184, "src/scripts/gen_block_diagram.py, 2026-10-23", ha="right", va="center",
        fontsize=11, color="#868E96")

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference", "placard_block_diagram.png")
fig.savefig(out, facecolor="white")
print("wrote %s (%d chips in the blocks)" % (out, total))
