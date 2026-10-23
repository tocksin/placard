#!/usr/bin/env python3
"""
gen_audio_schematic.py - draw the Placard audio circuitry as a schematic PNG:
the audio slot PLD, the Sync PLD pins that make the blanking reads, the
pixel buffer, the DAC register and its filtered supply, the R-2R ladder,
the filter and the audio line out jack, plus the timing of one line.

    python3 gen_audio_schematic.py              writes schematics/placard_audio_schematic.png
    python3 gen_audio_schematic.py out.png      writes out.png

Needs matplotlib (python3 -m pip install matplotlib).  The pin numbers are
typed in from ATF22V10_AUDIO.pld, ATF22V10_SYNC.pld, ATF22V10_HCOUNT.pld,
ATF22V10_QUAD_MUX.pld, docs/SOUND.md, docs/CHIPS.md and the parts' data
sheets; update them here when those change and rerun.  Nets with the same
label are connected.  Same drawing style as gen_io_schematic.py.

Date: 2026-10-23
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from schematic_text import fit_text
from matplotlib.patches import Rectangle, Polygon, Circle, Arc

W, H = 320, 180
P = 3.2                     # pin pitch
STUB = 4                    # pin stub length
INK, WIRE, NET, PWR, MUTE = "#212529", "#1A5FB4", "#C01C28", "#2F7D32", "#6C757D"
CHIP, CONN, BOARD = "#FFF8E1", "#E8F1FB", "#F7F7F7"

fig = plt.figure(figsize=(W / 10, H / 10), dpi=100)
ax = fig.add_axes([0, 0, 1, 1])
ax.set_xlim(0, W)
ax.set_ylim(H, 0)
ax.axis("off")


def T(x, y, s, fs=8, ha="left", va="center", color=INK, weight="normal", rot=0, z=6, **kw):
    ax.text(x, y, s, fontsize=fs, ha=ha, va=va, color=color, weight=weight, rotation=rot,
            zorder=z, **kw)


def wire(pts, color=WIRE, lw=1.3):
    xs, ys = zip(*pts)
    ax.plot(xs, ys, color=color, lw=lw, solid_capstyle="round", zorder=3)


def dot(x, y, color=WIRE):
    ax.add_patch(Circle((x, y), 0.45, color=color, zorder=5))


def net(x, y, name, side="r", fs=7.5):
    """a net label at the end of a wire; side = which way the text runs"""
    ha = {"r": "left", "l": "right"}[side]
    dx = 0.6 if side == "r" else -0.6
    T(x + dx, y, name, fs=fs, ha=ha, color=NET, weight="bold")


def gnd(x, y, label="AGND"):
    wire([(x, y), (x, y + 1.2)], INK)
    for i, w in enumerate((1.6, 1.0, 0.4)):
        wire([(x - w, y + 1.2 + i * 0.55), (x + w, y + 1.2 + i * 0.55)], INK, lw=1.2)
    if label:
        T(x + 2, y + 2.0, label, fs=5.8, color=MUTE)


def rail(x, y, name):
    wire([(x, y), (x, y - 1.2)], INK)
    wire([(x - 1.4, y - 1.2), (x + 1.4, y - 1.2)], PWR, lw=2)
    T(x, y - 2.4, name, fs=7, ha="center", color=PWR, weight="bold")


def res(x, y0, y1, ref, val, side="r", color=INK, fs=6.5):
    """vertical resistor from y0 to y1 (zigzag in the middle)"""
    m0, m1 = y0 + (y1 - y0) * 0.25, y0 + (y1 - y0) * 0.75
    pts = [(x, y0), (x, m0)]
    n = 6
    for i in range(n):
        pts.append((x + (0.9 if i % 2 == 0 else -0.9), m0 + (m1 - m0) * (i + 0.5) / n))
    pts += [(x, m1), (x, y1)]
    wire(pts, color)
    ha = "left" if side == "r" else "right"
    dx = 1.4 if side == "r" else -1.4
    if val:
        T(x + dx, (y0 + y1) / 2 - 0.9, ref, fs=fs, ha=ha)
        T(x + dx, (y0 + y1) / 2 + 0.9, val, fs=fs, ha=ha, color=MUTE)
    elif ref:
        T(x + dx, (y0 + y1) / 2, ref, fs=fs, ha=ha)


def resh(x0, x1, y, ref, val, color=INK, fs=6.5):
    """horizontal resistor"""
    m0, m1 = x0 + (x1 - x0) * 0.25, x0 + (x1 - x0) * 0.75
    pts = [(x0, y), (m0, y)]
    n = 6
    for i in range(n):
        pts.append((m0 + (m1 - m0) * (i + 0.5) / n, y + (0.8 if i % 2 == 0 else -0.8)))
    pts += [(m1, y), (x1, y)]
    wire(pts, color)
    T((x0 + x1) / 2, y - 1.6, (ref + "  " + val).strip(), fs=fs, ha="center")


def cap(x, y0, y1, ref, val, polar=False):
    """vertical capacitor; polar: + at the top, curved bottom plate"""
    m = (y0 + y1) / 2
    wire([(x, y0), (x, m - 0.4)], INK)
    wire([(x, m + 0.4), (x, y1)], INK)
    wire([(x - 1.3, m - 0.4), (x + 1.3, m - 0.4)], INK, lw=1.8)
    if polar:
        ax.add_patch(Arc((x, m + 1.6), 2.8, 2.4, theta1=200, theta2=340, color=INK, lw=1.8, zorder=4))
        T(x - 1.9, m - 1.4, "+", fs=6.5, ha="center")
    else:
        wire([(x - 1.3, m + 0.4), (x + 1.3, m + 0.4)], INK, lw=1.8)
    T(x + 1.8, m - 0.8, ref, fs=6.5)
    T(x + 1.8, m + 0.9, val, fs=6.5, color=MUTE)


def caph(x0, x1, y, ref, val, polar=False):
    """horizontal capacitor; polar: + on the x0 side, curved plate on x1"""
    m = (x0 + x1) / 2
    wire([(x0, y), (m - 0.4, y)], INK)
    wire([(m + 0.4, y), (x1, y)], INK)
    wire([(m - 0.4, y - 1.3), (m - 0.4, y + 1.3)], INK, lw=1.8)
    if polar:
        ax.add_patch(Arc((m + 1.6, y), 2.4, 2.8, theta1=110, theta2=250, color=INK, lw=1.8, zorder=4))
        T(m - 1.4, y - 1.9, "+", fs=6.5, ha="center")
    else:
        wire([(m + 0.4, y - 1.3), (m + 0.4, y + 1.3)], INK, lw=1.8)
    T(m, y - 3.2, ref, fs=6.5, ha="center")
    T(m, y + 2.8, val, fs=6.5, ha="center", color=MUTE)


def ic(x, y, w, ref, part, left, right, top=None, bottom=None, fc=CHIP, title=None,
       top_rail="+5V", bottom_label="GND"):
    """an IC symbol.  left/right: lists of (pin, name) or None (a gap).
    top/bottom: (pin, name).  Returns {name: (x, y)} of the stub ends,
    also keyed "p<pin>"."""
    n = max(len(left), len(right))
    h = P * (n + 1)
    ax.add_patch(Rectangle((x, y), w, h, fc=fc, ec=INK, lw=1.6, zorder=2))
    pins = {}

    def add(pin, name, px, py):
        pins[name] = (px, py)
        pins.setdefault("p%s" % pin, (px, py))

    for side, lst in (("l", left), ("r", right)):
        for i, item in enumerate(lst):
            if item is None:
                continue
            pin, name = item
            py = y + P * (i + 1)
            if side == "l":
                wire([(x - STUB, py), (x, py)], INK)
                T(x - 0.6, py - 0.75, str(pin), fs=6, ha="right", color=MUTE)
                T(x + 0.8, py, name, fs=7)
                add(pin, name, x - STUB, py)
            else:
                wire([(x + w, py), (x + w + STUB, py)], INK)
                T(x + w + 0.6, py - 0.75, str(pin), fs=6, ha="left", color=MUTE)
                T(x + w - 0.8, py, name, fs=7, ha="right")
                add(pin, name, x + w + STUB, py)
    for item, sgn in ((top, -1), (bottom, 1)):
        if item is None:
            continue
        pin, name = item
        px = x + w / 2
        py0 = y if sgn < 0 else y + h
        wire([(px, py0), (px, py0 + sgn * STUB)], INK)
        T(px + 0.6, py0 + sgn * 1.2, str(pin), fs=6, color=MUTE)
        T(px, py0 - sgn * 1.2, name, fs=6.5, ha="center")
        add(pin, name, px, py0 + sgn * STUB)
        if sgn < 0 and top_rail:
            rail(px, py0 - STUB, top_rail)
        elif sgn > 0:
            gnd(px, py0 + STUB, bottom_label)
    T(x, y - 1.3, ref, fs=9, weight="bold", va="bottom")
    T(x + w, y - 1.3, part, fs=7, ha="right", va="bottom", color=MUTE)
    if title:
        T(x + w / 2, y + h + 1.6 + (STUB + 3.6 if bottom else 0), title, fs=7, ha="center", va="top",
          color=MUTE, style="italic")
    return pins


def frame(x, y, w, h, label, where="tl"):
    ax.add_patch(Rectangle((x, y), w, h, fc="none", ec=MUTE, lw=1.1, ls=(0, (5, 3)), zorder=1))
    lx = x + 1 if where[1] == "l" else x + w - 1
    ly = y + 1.6 if where[0] == "t" else y + h - 1.6
    T(lx, ly, label, fs=8.5, weight="bold", color=MUTE, ha="left" if where[1] == "l" else "right",
      bbox=dict(fc="white", ec="none", pad=0.5))


# ================================================================ title
T(4, 5, "Placard: audio schematic", fs=20, weight="bold")
T(4, 10.5, "Line-fetched 8-bit audio: one sample per scan line read from x5DF3-x5FFF into the pixel "
   "buffer, copied to a 74HCT574 when H_VIDEO_ACTIVE rises, an R-2R ladder straight to the audio line out (no headphone amp).  "
   "Pin numbers from ATF22V10_AUDIO.pld rev 03, ATF22V10_SYNC.pld rev 08 and docs/SOUND.md.  "
   "Red labels are nets.", fs=9.5, color=MUTE)

# ================================================================ U35 audio slot PLD
frame(3, 14, 92, 96, "Audio slot PLD (blanking reads, row address)")
u35 = ic(42, 22, 22, "U35", "ATF22V10C-7PX",
         [(2, "H9"), (3, "H8"), (4, "H7"), (5, "H6"), (6, "H5"), (7, "H4"), (8, "H3"), None,
          (9, "V9"), (1, "V0"), (10, "V1"), (11, "V7"), (13, "V8"), None, (14, "LC2"), (15, "LC3"),
          None, (16, "nc")],
         [(23, "BLANK_RD"), (22, "/MODE_LD"), None, None, (17, "R0"), (18, "R1"), (19, "R7"),
          (20, "R8"), None, (21, "nc")],
         top=(24, "VCC"), bottom=(12, "GND"), title="ATF22V10_AUDIO.pld rev 03", bottom_label="")
hpin = {"H9": 20, "H8": 19, "H7": 18, "H6": 17, "H5": 16, "H4": 15, "H3": 14}
vpin = {"V9": 19, "V0": 14, "V1": 23, "V7": 17, "V8": 18}
for name, pin in hpin.items():
    net(*u35[name], "%s  (U13 pin %d)" % (name, pin), "l", fs=6.8)
for name, pin in vpin.items():
    net(*u35[name], "%s  (U14 pin %d)" % (name, pin), "l", fs=6.8)
net(*u35["LC2"], "LC2  (U23 Q2)", "l", fs=6.8)
net(*u35["LC3"], "LC3  (U23 Q3)", "l", fs=6.8)
for name in ("p16", "p21"):
    x, y = u35[name]
    T(x + (-0.6 if name == "p16" else 0.6), y, "nc", fs=6.5, ha="right" if name == "p16" else "left",
      color=MUTE)
x, y = u35["/MODE_LD"]
net(x, y, "/MODE_LD", fs=6.8)
T(x + 1, y + 2.2, "U23 /E (line code F377)", fs=6.2, color=MUTE)
for name, dest in (("R0", "U7 pin 3, video A0"), ("R1", "U7 pin 7, video A1"),
                   ("R7", "U8 pin 18, video A7"), ("R8", "U9 pin 3, video A8")):
    x, y = u35[name]
    net(x, y, name, fs=6.8)
    T(x + 4.5, y, "(" + dest + ")", fs=6.2, color=MUTE)
T(6, 96.0, "BLANK_RD  = group 47 & V9   (lines 512-1023, x5E00-x5FFF)", fs=6.6, family="monospace")
T(6, 98.4, "          # group 46 & !V9  (lines 499-511,  x5DF3-x5DFF)", fs=6.6, family="monospace")
T(6, 100.8, "          # group 45        (mode byte, x5A00 + V8:V0)", fs=6.6, family="monospace")
T(6, 103.2, "/MODE_LD  = group 45", fs=6.6, family="monospace")
T(6, 105.6, "R0 R1 R7 R8: V0 V1 V7 V8 in groups 32-47, line repeat remap in 48-127", fs=6.6,
  family="monospace")
T(6, 108.0, "group = H9:H3;  45 = 0101101, 46 = 0101110, 47 = 0101111", fs=6.6, color=MUTE,
  family="monospace")

# ================================================================ U15 sync (audio pins) and U22 pixel buffer
frame(98, 14, 76, 96, "The read: Sync PLD and pixel buffer")
u15 = ic(126, 22, 24, "U15", "ATF22V10C-7PX",
         [(1, "CLK"), (13, "BLANK_RD"), (8, "H_VIDEO_ACT")],
         [(19, "PIXEL_ENABLE"), (20, "ADDR_SEL"), (21, "ADDR_SEL_HI")],
         title="ATF22V10_SYNC.pld rev 08 (pins used here)")
net(*u15["CLK"], "CLK 25 MHz", "l", fs=6.8)
net(*u15["H_VIDEO_ACT"], "H_VIDEO_ACTIVE", "l", fs=6.8)
for name in ("ADDR_SEL", "ADDR_SEL_HI"):
    x, y = u15[name]
    T(x + 0.6, y, "to the address mux", fs=6.2, color=MUTE)
# BLANK_RD from U35 pin 23 to U15 pin 13
x0, y0 = u35["BLANK_RD"]
x1, y1 = u15["BLANK_RD"]
wire([(x0, y0), (104, y0), (104, y1), (x1, y1)])
T(x0 + 1, y0 - 0.8, "BLANK_RD", fs=6.5, color=NET, weight="bold")

u22 = ic(126, 52, 18, "U22", "SN74F377AN",
         [(1, "/E"), (11, "CLK"), None, (3, "D0"), (4, "D1"), (7, "D2"), (8, "D3"), (13, "D4"),
          (14, "D5"), (17, "D6"), (18, "D7")],
         [None, None, None, (2, "Q0"), (5, "Q1"), (6, "Q2"), (9, "Q3"), (12, "Q4"), (15, "Q5"),
          (16, "Q6"), (19, "Q7")],
         top=(20, "VCC"), bottom=(10, "GND"), title="pixel buffer", bottom_label="")
net(*u22["CLK"], "CLK 25 MHz", "l", fs=6.8)
# PIXEL_ENABLE from U15 pin 19 to the pixel buffer's load enable
x0, y0 = u15["PIXEL_ENABLE"]
x1, y1 = u22["/E"]
wire([(x0, y0), (156, y0), (156, 43.5), (116, 43.5), (116, y1), (x1, y1)])
T(x0 + 1, y0 - 0.8, "PIXEL_ENABLE", fs=6.5, color=NET, weight="bold")
# memory data bus into D7:D0
BX = 108
wire([(BX, u22["D0"][1] - 1), (BX, u22["D7"][1] + 1)], WIRE, lw=3.5)
for i in range(8):
    x, y = u22["D%d" % i]
    wire([(x, y), (BX + 1, y), (BX, y - 1)])
    T(BX + 1.3, y - 0.7, "D%d" % i, fs=5.8, color=NET)
T(BX - 0.8, 82, "D7:D0", fs=7, color=WIRE, weight="bold", ha="right")
T(BX - 0.8, 85, "memory data", fs=6, color=MUTE, ha="right")
T(BX - 0.8, 87.5, "bus (RAM)", fs=6, color=MUTE, ha="right")

# ================================================================ U36 DAC register and its supply
frame(177, 14, 76, 96, "DAC register, filtered supply, R-2R ladder")
u36 = ic(192, 52, 18, "U36", "SN74HCT574N",
         [(1, "/OE"), (11, "CLK"), None, (2, "D0"), (3, "D1"), (4, "D2"), (5, "D3"), (6, "D4"),
          (7, "D5"), (8, "D6"), (9, "D7")],
         [None, None, None, (19, "Q0"), (18, "Q1"), (17, "Q2"), (16, "Q3"), (15, "Q4"),
          (14, "Q5"), (13, "Q6"), (12, "Q7")],
         top=(20, "VCC"), bottom=(10, "GND"), top_rail=None, title="DAC register (HCT: rail-to-rail Q)")
x, y = u36["/OE"]
wire([(x, y), (x - 2, y)], INK)
T(x - 2.6, y, "GND", fs=7, ha="right", color=PWR, weight="bold")
x, y = u36["CLK"]
wire([(x, y), (172, y)])
net(172, y, "H_VIDEO_ACTIVE", "l", fs=6.8)
T(175.5, y + 2.4, "(U13 pin 22, rises at group 48)", fs=6, color=MUTE, ha="right")
# pixel buffer Q7:Q0 straight across to U36 D7:D0; also on to the line code reg and the colour decoder
TAP = 160
for i in range(8):
    xq, yq = u22["Q%d" % i]
    xd, yd = u36["D%d" % i]
    wire([(xq, yq), (xd, yd)])
    dot(TAP, yq)
    T(xq + 1, yq - 0.7, "P%d" % i, fs=5.8, color=NET)
wire([(TAP, u22["Q0"][1]), (TAP, 104.5), (TAP - 2, 104.5)])
T(TAP - 2.5, 104.5, "also to U23 D7:D0 (line code) and U16 (colour decoder)", fs=6, color=MUTE, ha="right")
# DAC 5V: +5V - 2.2R - node with 220uF and 100nF to AGND - U36 VCC
vx, vy = u36["VCC"]
fy = 30
rail(182, fy, "+5V")
resh(182, 193, fy, "R12", "2.2")
wire([(193, fy), (226, fy)], INK)
dot(vx, fy, INK)
wire([(vx, fy), (vx, vy)], INK)
for cx, ref, val, pol in ((212, "C3", "220uF", True), (224, "C4", "100nF", False)):
    dot(cx, fy, INK)
    cap(cx, fy, fy + 8, ref, val, polar=pol)
    gnd(cx, fy + 8)
T(vx + 1, fy - 1.5, "DAC 5V", fs=7, color=NET, weight="bold")
T(203, 45, "ladder full scale = this rail, so it is filtered", fs=6.2, color=MUTE)

# ================================================================ R-2R ladder
frame(256, 14, 61, 96, "Filter and audio line out", "tr")
NX = 233
nodes = []
for i in range(8):
    xq, yq = u36["Q%d" % i]
    resh(xq, xq + 12, yq, "R%d" % (13 + i), "", fs=5.8)
    wire([(xq + 12, yq), (NX, yq)], INK)
    dot(NX, yq, INK) if 0 < i < 7 else None
    nodes.append((NX, yq))
for i in range(7):
    res(NX, nodes[i][1], nodes[i + 1][1], "R%d" % (22 + i), "", fs=5.8)
# termination: node 0 (LSB) 2k to AGND
y0 = nodes[0][1]
dot(NX, y0, INK)
resh(NX, NX + 10, y0, "R21", "", fs=5.8)
gnd(NX + 10, y0)
T(214, 112.5 - 64, "R13-R21  2.00k 1% (2R)", fs=6.4)
T(214, 115.1 - 64, "R22-R28  1.00k 1% (R)", fs=6.4)
T(214, 117.7 - 64, "out = DAC 5V x code / 256, Rout 1k", fs=6.2, color=MUTE)
# ladder out (node 7, MSB) to the filter, coupling cap and jack
oy = nodes[7][1]
dot(NX, oy, INK)
wire([(NX, oy), (NX, oy + 4), (272, oy + 4)])
ly = oy + 4
T(NX + 1, ly - 0.9, "AUDIO", fs=6.5, color=NET, weight="bold")
dot(266, ly)
cap(266, ly, ly + 7, "C5", "15nF C0G")
gnd(266, ly + 7)
caph(272, 282, ly, "C6", "22uF 10V", polar=True)
wire([(282, ly), (296, ly)])
dot(287, ly)
res(287, ly, ly + 7, "R29", "10k")
gnd(287, ly + 7)
j6 = ic(300, 60, 10, "J6", "3.5 mm", [("", "T"), ("", "R"), ("", "S")], [], fc=CONN,
        title="line out jack")
for k in ("T", "R"):
    x, y = j6[k]
    wire([(296, y), (x, y)])
    dot(296, y) if k == "R" else None
wire([(296, j6["T"][1]), (296, ly)])
x, y = j6["S"]
wire([(x, y), (293, y), (293, y + 3)], INK)
gnd(293, y + 3)
T(298, 77.5, "tip + ring tied:", fs=6, color=MUTE)
T(298, 80, "mono on L and R", fs=6, color=MUTE)

# ================================================================ timing of one line
TX0, TW = 40, 22
groups = [44, 45, 46, 47, 48, 49]
TY = 120
T(4, TY - 3, "One line, groups 44-49 (8 clocks each; a line is groups 28-127, 800 clocks)", fs=10,
  weight="bold")
for k, g in enumerate(groups):
    gx = TX0 + k * TW
    ax.add_patch(Rectangle((gx, TY), TW, 3.4, fc=BOARD, ec=MUTE, lw=0.8, zorder=2))
    T(gx + TW / 2, TY + 1.7, "group %d" % g, fs=6.5, ha="center")
    wire([(gx, TY + 3.4), (gx, TY + 47)], "#DEE2E6", lw=0.8)
wire([(TX0 + 6 * TW, TY + 3.4), (TX0 + 6 * TW, TY + 47)], "#DEE2E6", lw=0.8)
rows = ["BLANK_RD", "/MODE_LD", "PIXEL_ENABLE", "pixel buffer Q", "H_VIDEO_ACTIVE", "DAC register Q",
        "address read"]


def gx(g, clk=0.0):
    return TX0 + (g - 44) * TW + clk * TW / 8


def level(r, segs):
    """segs: list of (x, high) breakpoints; draws a digital waveform on row r"""
    y = TY + 8 + r * 5.6
    lo, hi = y + 1.6, y - 1.6
    pts = []
    for i, (x, h) in enumerate(segs):
        yy = hi if h else lo
        if pts:
            pts.append((x, pts[-1][1]))
        pts.append((x, yy))
    pts.append((gx(50), pts[-1][1]))
    wire(pts, WIRE, lw=1.4)


def bus(r, segs):
    """segs: list of (x0, x1, label)"""
    y = TY + 8 + r * 5.6
    for x0, x1, s in segs:
        ax.add_patch(Polygon([(x0, y), (x0 + 0.8, y - 1.6), (x1 - 0.8, y - 1.6), (x1, y),
                              (x1 - 0.8, y + 1.6), (x0 + 0.8, y + 1.6)], closed=True,
                             fc="#E8F1FB" if s not in ("?",) else "white", ec=WIRE, lw=1.1, zorder=3))
        T((x0 + x1) / 2, y, s, fs=6.2, ha="center")


for r, name in enumerate(rows):
    T(TX0 - 1.5, TY + 8 + r * 5.6, name, fs=7, ha="right", color=NET if r < 6 else INK,
      weight="bold" if r < 6 else "normal")
level(0, [(gx(44), 0), (gx(45), 1), (gx(46), 0), (gx(47), 1), (gx(48), 0)])
level(1, [(gx(44), 1), (gx(45), 0), (gx(46), 1)])
level(2, [(gx(44), 0), (gx(45, 1), 1), (gx(45, 2), 0), (gx(47, 1), 1), (gx(47, 2), 0),
          (gx(48, 1), 1), (gx(48, 2), 0), (gx(49, 1), 1), (gx(49, 2), 0)])
bus(3, [(gx(44), gx(45, 2), "last pixel"), (gx(45, 2), gx(47, 2), "mode byte"),
        (gx(47, 2), gx(48, 2), "sample"), (gx(48, 2), gx(49, 2), "pixel 0"), (gx(49, 2), gx(50), "pixel 1")])
level(4, [(gx(44), 0), (gx(48), 1)])
bus(5, [(gx(44), gx(48, 0.6), "previous line's sample"), (gx(48, 0.6), gx(50), "this line's sample")])
y = TY + 8 + 6 * 5.6
for g, s in ((45, "x5A00+V8:V0"), (47, "x5E00+V8:V0"), (48, "pixels")):
    T(gx(g) + TW / 2, y, s, fs=6.2, ha="center", color=MUTE)
# the copy edge
ex = gx(48, 0.3)
ax.annotate("", xy=(ex, TY + 8 + 5 * 5.6 - 2), xytext=(ex, TY + 8 + 4 * 5.6 + 1.6),
            arrowprops=dict(arrowstyle="->", color=NET, lw=1.2), zorder=6)
T(4, TY + 51, "Lines 512-1023 read in group 47 (shown); lines 499-511 read in group 46, so V9 lands "
   "on A9 and each of the 525 lines has its own byte.  The rising edge of", fs=6.8, color=MUTE)
T(4, TY + 54, "H_VIDEO_ACTIVE copies the sample before the first pixel read replaces it, so every sample "
   "lasts exactly one line (31.47 kHz).  Each read stalls the CPU for one clock.", fs=6.8, color=MUTE)

# ================================================================ notes
nx, ny = 182, 117
T(nx, ny, "Audio buffer and parts", fs=10, weight="bold")
notes = [("Buffer", "x5DF3-x5FFF, 525 bytes = one frame, played in order and repeated"),
         ("Format", "8-bit unsigned mono, x80 = silence (2.49 V before C6)"),
         ("Ladder", "1k output resistance at every code; each bit sources at most 2.5 mA"),
         ("C5", "into a 10k or higher line input: one pole at about 11 kHz"),
         ("C6, R29", "blocks the 2.49 V offset (under 1 Hz corner into 10k); R29 stops plug-in pops"),
         ("Level", "line out: about 4.2 V p-p full scale into a 10k line input; not for headphones"),
         ("AGND", "R21, C3-C6, R29 and the jack sleeve meet logic ground at one point"),
         ("", "at the power input"),
         ("FPGA", "basys_top.vhd audioDacProc, Q7:Q0 on Pmod JA10..JA1 (3.3 V)")]
for i, (a, b) in enumerate(notes):
    T(nx, ny + 4.5 + i * 3.4, a, fs=7.0, weight="bold")
    T(nx + 13, ny + 4.5 + i * 3.4, b, fs=7.0)
T(nx, ny + 37, "Each chip has a 100 nF capacitor across its supply pins.  U-numbers as in "
   "docs/CHIPS.md.  Source: docs/SOUND.md,", fs=6.8, color=MUTE)
T(nx, ny + 39.8, "docs/VIDEO.md, the PLD files, 2026-10-19.", fs=6.8, color=MUTE)

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "schematics", "placard_audio_schematic.png")
fit_text(fig, ax)
fig.savefig(out, dpi=100)
print("wrote", os.path.normpath(out))
