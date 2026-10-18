#!/usr/bin/env python3
"""
gen_io_schematic.py - draw the Placard I/O circuitry as a schematic PNG:
the I/O decode PLD, the shared port at x5200 (latch, port PLD, row
buffer, SD level-shifting dividers, 3.3 V regulator) and its connectors (keyboard
matrix header, two SNES pads, SD card socket, PS/2 mouse).

    python3 gen_io_schematic.py              writes reference/placard_io_schematic.png
    python3 gen_io_schematic.py out.png      writes out.png

Needs matplotlib (python3 -m pip install matplotlib).  The pin numbers are
typed in from ATF22V10_IO_DECODE.pld, ATF22V10_PORT.pld, IO.md and the
parts' data sheets; update them here when those change and rerun.  Nets
with the same label are connected.

Date: 2026-10-18
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Polygon, Circle

W, H = 320, 222
P = 2.5                     # pin pitch
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


def gnd(x, y):
    wire([(x, y), (x, y + 1.2)], INK)
    for i, w in enumerate((1.6, 1.0, 0.4)):
        wire([(x - w, y + 1.2 + i * 0.55), (x + w, y + 1.2 + i * 0.55)], INK, lw=1.2)


def rail(x, y, name):
    wire([(x, y), (x, y - 1.2)], INK)
    wire([(x - 1.4, y - 1.2), (x + 1.4, y - 1.2)], PWR, lw=2)
    T(x, y - 2.4, name, fs=7, ha="center", color=PWR, weight="bold")


def res(x, y0, y1, ref, val, side="r", color=INK):
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
    T(x + dx, (y0 + y1) / 2 - 0.9, ref, fs=6.5, ha=ha)
    T(x + dx, (y0 + y1) / 2 + 0.9, val, fs=6.5, ha=ha, color=MUTE)


def resh(x0, x1, y, ref, val, color=INK):
    """horizontal resistor"""
    m0, m1 = x0 + (x1 - x0) * 0.25, x0 + (x1 - x0) * 0.75
    pts = [(x0, y), (m0, y)]
    n = 6
    for i in range(n):
        pts.append((m0 + (m1 - m0) * (i + 0.5) / n, y + (0.8 if i % 2 == 0 else -0.8)))
    pts += [(m1, y), (x1, y)]
    wire(pts, color)
    T((x0 + x1) / 2, y - 1.6, ref + "  " + val, fs=6.5, ha="center")


def diode(xa, xk, y, ref, color=INK):
    """horizontal diode, anode at xa, cathode at xk"""
    d = 1 if xk > xa else -1
    m = (xa + xk) / 2
    wire([(xa, y), (m - d * 0.9, y)], color)
    wire([(m + d * 0.9, y), (xk, y)], color)
    ax.add_patch(Polygon([(m - d * 0.9, y - 0.9), (m - d * 0.9, y + 0.9), (m + d * 0.9, y)],
                         closed=True, fc=INK, ec=INK, zorder=4))
    wire([(m + d * 0.9, y - 0.9), (m + d * 0.9, y + 0.9)], INK, lw=1.5)
    # Schottky hooks
    wire([(m + d * 0.9, y - 0.9), (m + d * 0.9 + 0.4, y - 0.9), (m + d * 0.9 + 0.4, y - 0.6)], INK, lw=1.2)
    wire([(m + d * 0.9, y + 0.9), (m + d * 0.9 - 0.4, y + 0.9), (m + d * 0.9 - 0.4, y + 0.6)], INK, lw=1.2)
    if ref:
        T(m, y - 1.7, ref, fs=6.5, ha="center")


def supply_down(x, y, name):
    """a supply flag below a part: bar and name under it"""
    wire([(x, y), (x, y + 1.2)], INK)
    wire([(x - 1.4, y + 1.2), (x + 1.4, y + 1.2)], PWR, lw=2)
    T(x, y + 2.5, name, fs=7, ha="center", color=PWR, weight="bold")


def rnet(xl, xr, ytop, pinxs, ref, label):
    """a bussed resistor network: 8 resistors from a common line (pin 1, at the
    right end, up to +5V) down to pins 2-9.  Returns the pin stub ends."""
    yc = ytop + 1.8
    ax.add_patch(Rectangle((xl, ytop), xr - xl, 9, fc=CHIP, ec=INK, lw=1.4, zorder=2))
    p1 = xr - 3
    wire([(p1, ytop - 2), (p1, yc)], INK)
    rail(p1, ytop - 2, "+5V")
    T(p1 + 0.6, ytop - 0.8, "1", fs=6, color=MUTE)
    wire([(pinxs[0], yc), (p1, yc)], INK)
    ends = []
    for i, x in enumerate(pinxs):
        dot(x, yc, INK)
        res(x, yc, ytop + 9, "", "")
        wire([(x, ytop + 9), (x, ytop + 11)], INK)
        T(x + 0.5, ytop + 9.9, str(i + 2), fs=6, color=MUTE)
        ends.append((x, ytop + 11))
    T(xl, ytop - 1.4, ref + "  " + label, fs=7)
    return ends


def cap(x, y0, y1, ref, val):
    m = (y0 + y1) / 2
    wire([(x, y0), (x, m - 0.4)], INK)
    wire([(x, m + 0.4), (x, y1)], INK)
    wire([(x - 1.3, m - 0.4), (x + 1.3, m - 0.4)], INK, lw=1.8)
    wire([(x - 1.3, m + 0.4), (x + 1.3, m + 0.4)], INK, lw=1.8)
    T(x + 1.8, m - 0.8, ref, fs=6.5)
    T(x + 1.8, m + 0.9, val, fs=6.5, color=MUTE)


def ic(x, y, w, ref, part, left, right, top=None, bottom=None, fc=CHIP, title=None):
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
        (rail if sgn < 0 else gnd)(px, py0 + sgn * STUB, *(("+5V",) if sgn < 0 else ()))
    T(x, y - 1.3, ref, fs=9, weight="bold", va="bottom")
    T(x + w, y - 1.3, part, fs=7, ha="right", va="bottom", color=MUTE)
    if title:
        T(x + w / 2, y + h + 1.6 + (STUB + 3.6 if bottom else 0), title, fs=7, ha="center", va="top",
          color=MUTE, style="italic")
    return pins


def conn(x, y, ref, part, pins, side="l", w=8, fc=CONN, title=None):
    """a connector: pins on one side (l or r)."""
    return ic(x, y, w, ref, part, pins if side == "l" else [], pins if side == "r" else [],
              fc=fc, title=title)


def frame(x, y, w, h, label, where="tl"):
    ax.add_patch(Rectangle((x, y), w, h, fc="none", ec=MUTE, lw=1.1, ls=(0, (5, 3)), zorder=1))
    lx = x + 1 if where[1] == "l" else x + w - 1
    ly = y + 1.6 if where[0] == "t" else y + h - 1.6
    T(lx, ly, label, fs=8.5, weight="bold", color=MUTE, ha="left" if where[1] == "l" else "right",
      bbox=dict(fc="white", ec="none", pad=0.5))


# ================================================================ title
T(4, 5, "Placard: I/O schematic", fs=20, weight="bold")
T(4, 10.5, "I/O decode, the shared port at x5200 (keyboard, SNES pads, SD card, PS/2 mouse) and "
   "its connectors.  Pin numbers from ATF22V10_IO_DECODE.pld rev 03, ATF22V10_PORT.pld rev 01 "
   "and IO.md.  Red labels are nets: the same label is the same wire.", fs=9.5, color=MUTE)

# ================================================================ U12 I/O decode
frame(3, 14, 72, 70, "I/O decode (x5000-x53FF)")
u12 = ic(32, 22, 20, "U12", "ATF22V10C-7PX",
         [(1, "/WE"), (2, "ADDR_SEL"), (3, "ADDR_SEL_HI"), (4, "PC15"), (5, "H9"), (6, "Y7"),
          (7, "A14"), (8, "A13"), (9, "A12"), (18, "A11"), (10, "A10"), (11, "A9"), (13, "A8"),
          (14, "RW"), (23, "LOAD_IMM")],
         [(15, "/CE_HI"), None, (16, "/MAP_WR"), (17, "/LINE_RD"), None, (19, "/PORT_WR"),
          (20, "/PORT_RD"), None, (21, "/EXP1"), (22, "/EXP2")],
         top=(24, "VCC"), bottom=(12, "GND"), title="ATF22V10_IO_DECODE.pld")
src = {"/WE": "mem ctrl /WE", "ADDR_SEL": "sync pin 20", "ADDR_SEL_HI": "sync pin 21",
       "PC15": "PC high bit 7", "H9": "H counter H9", "Y7": "Y reg bit 7", "RW": "state R/W",
       "LOAD_IMM": "state LOAD_IMM"}
for name in ("/WE", "ADDR_SEL", "ADDR_SEL_HI", "PC15", "H9", "Y7", "A14", "A13", "A12", "A11",
             "A10", "A9", "A8", "RW", "LOAD_IMM"):
    px, py = u12[name]
    lab = name if name.startswith("A1") or name in ("A9", "A8") else src[name]
    net(px, py, lab, "l")
dest = {"/CE_HI": "upper 32K /CE", "/MAP_WR": "map reg U25",
        "/LINE_RD": "line read U29", "/EXP1": "slots 1, 3", "/EXP2": "slots 2, 4"}
for name in ("/CE_HI", "/MAP_WR", "/LINE_RD", "/EXP1", "/EXP2"):
    px, py = u12[name]
    net(px, py, name)
    if name in dest:
        T(px + 0.6 + len(name) * 1.25 + 1.2, py, "(" + dest[name] + ")", fs=6.5, color=MUTE)

# ================================================================ data bus pull-ups
frame(3, 88, 72, 24, "Data bus pull-ups (empty slots read FF)")
rn1 = rnet(8, 73, 94, [16 + i * 7 for i in range(8)], "RN1", "10k x 8, bussed SIP-9")

# ================================================================ U37 port latch
frame(78, 14, 64, 134, "Shared port x5200")
u37 = ic(90, 22, 16, "U37", "SN74HC574N",
         [(1, "/OE"), (11, "CLK"), None, (2, "D0"), (3, "D1"), (4, "D2"), (5, "D3"), (6, "D4"),
          (7, "D5"), (8, "D6"), (9, "D7")],
         [None, None, None, (19, "Q0"), (18, "Q1"), (17, "Q2"), (16, "Q3"), (15, "Q4"),
          (14, "Q5"), (13, "Q6"), (12, "Q7")],
         top=(20, "VCC"), bottom=(10, "GND"), title="port latch, rests at FB")
x, y = u37["/OE"]
T(x - 0.6, y, "GND", fs=7, ha="right", color=PWR, weight="bold")
net(*u37["Q3"], "PS2D_DRV")
# /PORT_WR from U12 to the latch clock
x0, y0 = u12["/PORT_WR"]
cx, cy = u37["CLK"]
wire([(x0, y0), (80, y0), (80, cy), (cx, cy)])
T(x0 + 1, y0 - 0.8, "/PORT_WR", fs=6.5, color=NET, weight="bold")

# ================================================================ U38 port PLD
u38 = ic(122, 56, 18, "U38", "ATF22V10C-7PX",
         [(3, "K0"), (4, "K1"), (5, "K2"), (6, "K3"), (1, "/PORT_RD"), (2, "A0"), (7, "PAD1"),
          (8, "PAD2"), (9, "nc"), (10, "nc"), (11, "nc"), (13, "nc")],
         [(14, "/COL0"), (15, "/COL1"), (16, "/COL2"), (17, "/COL3"), (18, "/COL4"),
          (19, "/COL5"), (20, "/COL6"), (21, "/COL7"), None, (22, "D6"), (23, "D7")],
         top=(24, "VCC"), bottom=(12, "GND"), title="ATF22V10_PORT.pld")
net(*u38["A0"], "A0", "l")
net(*u38["PAD1"], "PAD1_DATA", "l")
net(*u38["PAD2"], "PAD2_DATA", "l")
# latch Q4-Q7 -> K0-K3
for i in range(4):
    qx, qy = u37["Q%d" % (i + 4)]
    kx, ky = u38["K%d" % i]
    xv = 116.5 - i * 1.6
    wire([(qx, qy), (xv, qy), (xv, ky), (kx, ky)])
# unused inputs to GND
xs = 114.5
ys = [u38["p%d" % p][1] for p in (9, 10, 11, 13)]
for yy in ys:
    wire([(u38["p9"][0], yy), (xs, yy)], INK)
    dot(xs, yy, INK) if yy != ys[-1] else None
wire([(xs, ys[0]), (xs, ys[-1] + 1)], INK)
gnd(xs, ys[-1] + 1)

# ================================================================ U39 row buffer
u39 = ic(122, 110, 18, "U39", "SN74F541N",
         [(1, "/OE1"), (19, "/OE2"), None, (18, "Y1"), (17, "Y2"), (16, "Y3"), (15, "Y4"),
          (14, "Y5"), (13, "Y6"), (12, "Y7"), (11, "Y8")],
         [None, None, None, (2, "A1"), (3, "A2"), (4, "A3"), (5, "A4"),
          (6, "A5"), (7, "A6"), (8, "A7"), (9, "A8")],
         top=(20, "VCC"), bottom=(10, "GND"), title="rows on even reads")
net(*u39["/OE2"], "A0", "l")

# /PORT_RD from U12 to the port PLD and the row buffer
x0, y0 = u12["/PORT_RD"]
px, py = u38["/PORT_RD"]
ox, oy = u39["/OE1"]
wire([(x0, y0), (78, y0), (78, py), (px, py)])
wire([(100, py), (100, oy), (ox, oy)])
dot(100, py)
T(x0 + 1, y0 + 0.9, "/PORT_RD", fs=6.5, color=NET, weight="bold")

# the data bus D7:D0: U37 inputs, U39 outputs and the RN1 pull-ups
BX, BY = 82, 107
wire([(BX, u37["D0"][1] + 1), (BX, u39["Y8"][1] + 1)], WIRE, lw=3.5)
wire([(rn1[0][0] + 1, BY), (BX, BY)], WIRE, lw=3.5)
T(BX + 1, BY - 1.6, "D7:D0", fs=7, color=WIRE, weight="bold")
for i in range(8):
    x, y = u37["D%d" % i]
    wire([(x, y), (BX + 1, y), (BX, y + 1)])
    T(BX + 1.2, y - 0.7, "D%d" % i, fs=5.8, color=NET)
    x, y = u39["Y%d" % (i + 1)]
    wire([(x, y), (BX + 1, y), (BX, y + 1)])
    T(BX + 1.2, y - 0.7, "D%d" % i, fs=5.8, color=NET)
    x, y = rn1[i]
    wire([(x, y), (x, BY - 1), (x + 1, BY)])
    T(x + 0.5, y + 0.4, "D%d" % i, fs=5.8, color=NET)
# U38's pad outputs D6 and D7: around the bottom of U38 to the bus
for name, xv, yh in (("D7", 145.5, 99.3), ("D6", 147, 100.9)):
    x, y = u38[name]
    wire([(x, y), (xv, y), (xv, yh), (BX + 1, yh), (BX, yh + 1)])
    T(BX + 1.2, yh - 0.7, name, fs=5.8, color=NET)

# ================================================================ row pull-ups and shared rows
frame(3, 116, 72, 64, "Row pull-ups, shared row lines, PS/2 and pad pull-ups")
rn2 = rnet(8, 73, 122, [16 + i * 7 for i in range(8)], "RN2", "4.7k x 8, bussed SIP-9")
for i in range(8):
    x, y = rn2[i]
    T(x + 0.5, y + 1.2, "ROW%d" % i, fs=6, color=NET, weight="bold")
# rows 5-7 carry the PS/2 and MISO lines through a diode each (anode at the row)
#   row, wire y, diode anode, cathode, node x, pull-up, supply, second diode, its net
for r, yy, dref, nname, rref, rval, sup, d2 in (
        (5, 140, "D67", "PS2_CLK", "R1", "4.7k", "+5V", ("D68", "/CS")),
        (6, 152, "D66", "PS2_DATA", "R2", "4.7k", "+5V", ("D69", "PS2D_DRV")),
        (7, 164, "D65", "MISO", "R5", "10k", "+3.3V", None)):
    x, y = rn2[r]
    wire([(x, y), (x, yy), (x - 2, yy)])
    diode(x - 2, x - 10, yy, dref)
    nx = 36 if d2 else 48
    wire([(x - 10, yy), (nx if not d2 else 30, yy)])
    dot(nx, yy)
    res(nx, yy, yy + 6, rref, rval, side="l")
    supply_down(nx, yy + 6, sup)
    if d2:
        T(nx + 0.4, yy - 1.4, nname, fs=6.5, color=NET, weight="bold")
        diode(30, 22, yy, d2[0])
        net(22, yy, d2[1], "l", fs=7)
    else:
        wire([(nx, yy), (44, yy)])
        net(44, yy, nname, "l", fs=7)
# pad DATA pull-ups
for i, (name, ref) in enumerate((("PAD1_DATA", "R3"), ("PAD2_DATA", "R4"))):
    x = 10 + i * 12
    rail(x, 164, "+5V")
    res(x, 164, 170, ref, "10k")
    wire([(x, 170), (x, 171)])
    T(x, 172.6, name, fs=6.5, ha="center", color=NET, weight="bold")
T(36, 177, "D65-D69 BAT85 (Schottky).  /CS = 0 holds the mouse off.", fs=6.5, color=MUTE)

# ================================================================ SD card: dividers, U40, J4
frame(146, 14, 170, 36, "SD card (SPI mode 3, 3.3 V)", "tr")
# 5 V to 3.3 V: a divider per line, 1.8k over 3.3k = 3.2 V
divs = {}
for i, (name, rs, rp) in enumerate((("/CS", "R8", "R11"), ("MOSI", "R7", "R10"),
                                     ("SCK", "R6", "R9"))):
    yy = 18 + i * 7
    resh(160, 172, yy, rs, "1.8k")
    wire([(172, yy), (176, yy)])
    dot(176, yy)
    res(176, yy, yy + 3.5, rp, "3.3k")
    gnd(176, yy + 3.5)
    divs[name] = (176, yy)
# from the latch: SCK straight across, MOSI and /CS step up (they cross SCK)
qy = {n: u37[q][1] for n, q in (("SCK", "Q0"), ("MOSI", "Q1"), ("/CS", "Q2"))}
qx = u37["Q0"][0]
wire([(qx, qy["SCK"]), (160, qy["SCK"])])
wire([(qx, qy["MOSI"]), (150, qy["MOSI"]), (150, 25), (160, 25)])
wire([(qx, qy["/CS"]), (153, qy["/CS"]), (153, 18), (160, 18)])
for n, extra in (("SCK", "  (pad CLOCK)"), ("MOSI", "  (pad LATCH)"), ("/CS", "")):
    T(qx + 1, qy[n] - 0.8, n + extra, fs=6.5, color=NET, weight="bold")
T(149, 46, "R6-R11: 5 V to 3.2 V, about 1.2k source into the card", fs=6.5, color=MUTE)

j4 = conn(222, 18, "J4", "SD card socket",
          [(1, "CS"), (2, "DI"), (3, "VSS1"), (4, "VDD"), (5, "CLK"), (6, "VSS2"), (7, "DO"),
           (8, "DAT1"), (9, "DAT2")], w=11, title="full-size SD socket (SPI)")
wire([divs["SCK"], (200, divs["SCK"][1]), (200, j4["CLK"][1]), j4["CLK"]])
wire([divs["MOSI"], (203, divs["MOSI"][1]), (203, j4["DI"][1]), j4["DI"]])
wire([divs["/CS"], (206, divs["/CS"][1]), (206, j4["CS"][1]), j4["CS"]])
T(184, divs["SCK"][1] - 1, "SCK_3V3", fs=6.5, color=MUTE)
T(184, divs["MOSI"][1] - 1, "MOSI_3V3", fs=6.5, color=MUTE)
T(184, divs["/CS"][1] - 1, "/CS_3V3", fs=6.5, color=MUTE)
for p in ("VSS1", "VSS2"):
    x, y = j4[p]
    T(x - 0.6, y, "GND", fs=7, ha="right", color=PWR, weight="bold")
x, y = j4["VDD"]
T(x - 0.6, y, "+3.3V", fs=7, ha="right", color=PWR, weight="bold")
x, y = j4["DO"]
wire([(x, y), (208, y)])
net(208, y, "MISO", "l")
for p in ("DAT1", "DAT2"):
    x, y = j4[p]
    T(x - 0.6, y, "nc", fs=6.5, ha="right", color=MUTE)

# U40 3.3 V regulator
u41 = ic(268, 24, 14, "U40", "LM1117-3.3 (not chosen)",
         [(3, "VIN")], [(2, "VOUT")], bottom=(1, "GND"), title="TO-220, or any 3.3 V LDO")
x, y = u41["VIN"]
wire([(x, y), (258, y)], INK)
rail(258, y, "+5V")
cap(260, y, y + 8, "C1", "10uF")
gnd(260, y + 8)
dot(260, y, INK)
x, y = u41["VOUT"]
wire([(x, y), (296, y)], INK)
dot(292, y, INK)
cap(292, y, y + 8, "C2", "10uF")
gnd(292, y + 8)
wire([(296, y), (296, y - 3)], INK)
wire([(294.6, y - 3), (297.4, y - 3)], PWR, lw=2)
T(299, y - 3, "+3.3V", fs=7, color=PWR, weight="bold")
T(268, 44.5, "+3.3V feeds J4 and R5", fs=6.5, color=MUTE)

# ================================================================ J1 keyboard header + matrix
frame(146, 53, 170, 112, "Keyboard: 8 x 8 matrix, 64 keys (key number = column x 8 + row)", "tr")
j1 = ic(166, 56, 10, "J1", "16-pin header",
        [(i + 1, "") for i in range(16)],
        [(i + 1, ("C%d" if i < 8 else "R%d") % (i % 8)) for i in range(16)], fc=CONN,
        title="1 x 16, 2.54 mm, to the keyboard")
# wire the columns straight from U38 (same rows as J1 pins 1-8)
for i in range(8):
    ux, uy = u38["/COL%d" % i]
    jx, jy = j1["p%d" % (i + 1)]
    if abs(uy - jy) < 0.01:
        wire([(ux, uy), (jx, jy)])
    else:
        wire([(ux, uy), (153, uy), (153, jy), (jx, jy)])
    T(ux + 3.5, uy - 0.7, "/COL%d" % i, fs=6, color=NET, weight="bold")
# the rows from U39 up to J1 pins 9-16
for i in range(8):
    jx, jy = j1["p%d" % (i + 9)]
    ux, uy = u39["A%d" % (i + 1)]
    xv = 150 + i * 1.5
    wire([(ux, uy), (xv, uy), (xv, jy), (jx, jy)])
    T(ux + 0.4, uy - 0.7, "ROW%d" % i, fs=5.8, color=NET, weight="bold")
# the matrix on the keyboard board
keys = [["Esc", "1", "2", "3", "4", "5", "6", "7"],
        ["8", "9", "0", "-", "=", "Bksp", "Tab", "Q"],
        ["W", "E", "R", "T", "Y", "U", "I", "O"],
        ["P", "[", "]", "\\", "Ctrl", "A", "S", "D"],
        ["F", "G", "H", "J", "K", "L", ";", "'"],
        ["Enter", "LShft", "Z", "X", "C", "V", "B", "N"],
        ["M", ",", ".", "/", "RShft", "Up", "Caps", "Fn"],
        ["`", "Alt", "Space", "Del", "Home", "Left", "Down", "Right"]]
frame(186, 78, 128, 86, "Keyboard board (off the main board)", "tr")
cx0, cdx = 213, 12.5       # column line x
ry0, rdy = 96, 8           # row line y
xr_end = cx0 + 7 * cdx + 3
colx = [cx0 + c * cdx for c in range(8)]
rowy = [ry0 + r * rdy for r in range(8)]
# columns: from J1 right pins 1-8 over to their vertical lines
for c in range(8):
    jx, jy = j1["C%d" % c]
    wire([(jx, jy), (colx[c], jy), (colx[c], rowy[7] + 4)])
    T(colx[c] + 0.6, 84, "COL%d" % c, fs=6.5, color=NET, weight="bold", rot=0)
# rows: from J1 right pins 9-16 down to their horizontal lines
for r in range(8):
    jx, jy = j1["R%d" % r]
    xv = 196 - r * 1.3
    wire([(jx, jy), (xv, jy), (xv, rowy[r]), (xr_end, rowy[r])])
    T(xv + 1, rowy[r] - 0.9, "ROW%d" % r, fs=6, color=NET, weight="bold")
# each key: switch from the row, then a diode to the column (cathode at the column)
for c in range(8):
    for r in range(8):
        X, Y = colx[c], rowy[r]
        a = X - 8.5
        dot(a, Y)
        wire([(a, Y), (a, Y + 2.2), (a + 1.0, Y + 2.2)], INK, lw=1)
        ax.add_patch(Circle((a + 1.3, Y + 2.2), 0.3, fc="white", ec=INK, lw=0.8, zorder=4))
        ax.add_patch(Circle((a + 3.3, Y + 2.2), 0.3, fc="white", ec=INK, lw=0.8, zorder=4))
        wire([(a + 1.5, Y + 2.0), (a + 3.4, Y + 1.0)], INK, lw=1)
        wire([(a + 3.6, Y + 2.2), (a + 4.5, Y + 2.2)], INK, lw=1)
        # diode a+4.5 .. X
        m = a + 6.4
        wire([(a + 4.5, Y + 2.2), (m - 0.6, Y + 2.2)], INK, lw=1)
        ax.add_patch(Polygon([(m - 0.6, Y + 1.6), (m - 0.6, Y + 2.8), (m + 0.6, Y + 2.2)],
                             closed=True, fc=INK, ec=INK, zorder=4))
        wire([(m + 0.6, Y + 1.5), (m + 0.6, Y + 2.9)], INK, lw=1.2)
        wire([(m + 0.6, Y + 2.2), (X, Y + 2.2)], INK, lw=1)
        dot(X, Y + 2.2)
        T(a + 2.3, Y + 4.1, keys[c][r], fs=5.6, ha="center", color=MUTE)
T(189, 160.5, "Each key: switch in series with a Schottky diode (BAT85 or 1N5817), cathode toward "
   "the column, so any number of keys can be down with no ghosting.", fs=6.8, color=MUTE)

# ================================================================ SNES pads and PS/2
frame(146, 168, 170, 38, "Game pads and mouse")
for k, (ref, padnet, x0) in enumerate((("J2", "PAD1_DATA", 160), ("J3", "PAD2_DATA", 207))):
    j = conn(x0 + 12, 173, ref, "SNES pad %d socket" % (k + 1),
             [(1, "+5V"), (2, "CLOCK"), (3, "LATCH"), (4, "DATA"), (5, "nc"), (6, "nc"),
              (7, "GND")], w=11)
    x, y = j["+5V"]
    T(x - 0.6, y, "+5V", fs=7, ha="right", color=PWR, weight="bold")
    net(*j["CLOCK"], "SCK", "l")
    net(*j["LATCH"], "MOSI", "l")
    net(*j["DATA"], padnet, "l")
    x, y = j["GND"]
    wire([(x, y), (x - 2, y)], INK)
    gnd(x - 2, y)
    for p in (5, 6):
        x, y = j["p%d" % p]
        T(x - 0.6, y, "nc", fs=6.5, ha="right", color=MUTE)
T(172, 202.5, "Pads share CLOCK (latch Q0) and LATCH (latch Q1); DATA goes to U38 pins 7 and 8.",
  fs=6.5, color=MUTE)
j5 = conn(272, 173, "J5", "mini-DIN 6 (PS/2)",
          [(1, "DATA"), (2, "nc"), (3, "GND"), (4, "+5V"), (5, "CLK"), (6, "nc")], w=11,
          title="PS/2 mouse")
net(*j5["DATA"], "PS2_DATA", "l")
net(*j5["CLK"], "PS2_CLK", "l")
x, y = j5["GND"]
wire([(x, y), (x - 7, y)], INK)
gnd(x - 7, y)
x, y = j5["+5V"]
T(x - 0.6, y, "+5V", fs=7, ha="right", color=PWR, weight="bold")
for p in (2, 6):
    x, y = j5["p%d" % p]
    T(x - 0.6, y, "nc", fs=6.5, ha="right", color=MUTE)

# ================================================================ notes
nx, ny = 4, 186
T(nx, ny, "Port x5200", fs=10, weight="bold")
rows = [("Write any x52xx", "Q0 SCK + pad CLOCK,  Q1 MOSI + pad LATCH,  Q2 SD /CS (0 also holds PS/2 CLK low),"),
        ("", "Q3 0 = PS/2 DATA low,  Q7:Q4 column 0-7 (8-15 none).  At rest FB."),
        ("Read even x52xx", "U39: D7:D0 = rows 7:0 of the driven column, 0 = down (row 7 MISO, 6 PS/2 DATA, 5 PS/2 CLK)"),
        ("Read odd x52xx", "U38: D7 = pad 1 DATA, D6 = pad 2 DATA, D5:D0 not driven")]
for i, (a, b) in enumerate(rows):
    T(nx, ny + 4 + i * 3.3, a, fs=7.2, weight="bold")
    T(nx + 21, ny + 4 + i * 3.3, b, fs=7.2)
T(nx, ny + 19, "Each chip has a 100 nF capacitor across its supply pins.  D0-D7 is the shared "
   "data bus (CPU.md).  U12 also makes the strobes for", fs=7.2, color=MUTE)
T(nx, ny + 22.3, "the map register, the line read and the expansion slots (EXPANSION.md).  "
   "Source: IO.md, CHIPS.md, the PLD files, 2026-10-18.", fs=7.2, color=MUTE)

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "reference", "placard_io_schematic.png")
fig.savefig(out, dpi=100)
print("wrote", os.path.normpath(out))
