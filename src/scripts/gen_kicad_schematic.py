#!/usr/bin/env python3
"""Write the Placard KiCad schematic: kicad/*.kicad_sch (main board, root plus
ten sheets), kicad/cartridge/ (the ROM cartridge, one sheet) and kicad/keyboard/
(the keyboard board, one sheet).

The sheet split follows docs/SCHEMATIC_PLAN.md.  The connections follow the
PLD pin lists (src/pld/*.pld), basys_top.vhd and the docs (CHIPS.md, IO.md,
SOUND.md, COLORS.md, EXPANSION.md, ROM.md).  Every pin of every part is listed
here with its net, so a pin left out stops the script.

Nets with several pins on a sheet are wired (kicad_route.py), numbered groups
are drawn as buses, nets that run between sheets get global labels, each chip has its decoupling capacitor Cn beside it (n = the
chip's U number), and the text is large.  Rerun after a pin or part change:

    python3 src/scripts/gen_kicad_schematic.py [--pdf] [--check]

--pdf exports schematics/placard_main.pdf, placard_cartridge.pdf and placard_keyboard.pdf, set to
open without the bookmarks panel.

--check exports the netlist with kicad-cli and compares it with the nets
listed here, then runs the ERC.

Date: 2026-10-22
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kicad_sch_lib as K  # noqa: E402

DATE = "2026-10-22"
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
KDIR = os.path.join(ROOT, "kicad")
CDIR = os.path.join(KDIR, "cartridge")
BDIR = os.path.join(KDIR, "keyboard")

# ---------------------------------------------------------------- footprints
FP_DIP14 = "Package_DIP:DIP-14_W7.62mm"
FP_DIP20 = "Package_DIP:DIP-20_W7.62mm"
FP_DIP28W = "Package_DIP:DIP-28_W15.24mm"
FP_R = "Resistor_THT:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"
FP_C = "Capacitor_THT:C_Disc_D5.0mm_W2.5mm_P5.00mm"
FP_CP_S = "Capacitor_THT:CP_Radial_D6.3mm_P2.50mm"
FP_CP_L = "Capacitor_THT:CP_Radial_D8.0mm_P3.50mm"
FP_D = "Diode_THT:D_DO-35_SOD27_P7.62mm_Horizontal"
FP_SIP9 = "Resistor_THT:R_Array_SIP9"
FP_JP = "Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical"


def bus(name, n, start=0):
    return [f"{name}{i}" for i in range(start, start + n)]


D = bus("D", 8)
A = bus("A", 16)
SRC = bus("SRC", 8)
DR = bus("DR", 8)
I = bus("I", 8)
F = bus("F", 8)
AC = bus("AC", 8)
X = bus("X", 8)
Y = bus("Y", 8)
PC = bus("PC", 16)
H = bus("H", 10)
V = bus("V", 10)
PIX = bus("PIX", 8)
RAMSEL = bus("RAMSEL", 8)
VA = ["VA0", "VA1", "V2", "V3", "V4", "V5", "V6", "VA7", "VA8"] + H[3:10]   # video address 0-15

# ---------------------------------------------------------------- pin maps
F377_D = [3, 4, 7, 8, 13, 14, 17, 18]
F377_Q = [2, 5, 6, 9, 12, 15, 16, 19]


def f377(d, qn, e):
    n = {"1": e, "11": "CLK", "20": "+5V", "10": "GND"}
    for i in range(8):
        n[str(F377_D[i])] = d[i]
        n[str(F377_Q[i])] = qn[i]
    return n


def ls273(d, qn, mr, cp):
    n = f377(d, qn, mr)
    n["11"] = cp
    return n


def ls574(d, qn, oe, cp, vcc="+5V", gnd="GND"):
    n = {"1": oe, "11": cp, "20": vcc, "10": gnd}
    for i in range(8):
        n[str(2 + i)] = d[i]
        n[str(19 - i)] = qn[i]
    return n


def f541(a, yn, g1, g2):
    n = {"1": g1, "19": g2, "20": "+5V", "10": "GND"}
    for i in range(8):
        n[str(2 + i)] = a[i]
        n[str(18 - i)] = yn[i]
    return n


PLD_NAMES = {"U1": "State PLD", "U2": "Branch PLD", "U3": "PC low PLD", "U4": "PC high PLD",
             "U5": "ALU low PLD", "U6": "ALU high PLD", "U7": "Address mux 3:0", "U8": "Address mux 7:4",
             "U9": "Address mux 11:8", "U10": "Address mux 15:12", "U11": "Memory control PLD",
             "U12": "I/O decode PLD", "U13": "H counter PLD", "U14": "V counter PLD", "U15": "Sync PLD",
             "U16": "Color decoder PLD", "U17": "Instruction register PLD", "U35": "Audio slot PLD", "U38": "Shared port PLD"}


def pld(d):
    n = {str(k): v for k, v in d.items()}
    n["24"] = "+5V"
    n["12"] = "GND"
    return n


PC_Q = [15, 22, 21, 16, 20, 17, 19, 18]


def pc_counter(dn, load, cin, qn, co):
    n = {1: "CLK", 10: load, 11: "PC_ENABLE", 13: cin, 14: "STALL_OUT", 23: co}
    for i in range(8):
        n[2 + i] = dn[i]
        n[PC_Q[i]] = qn[i]
    return pld(n)


def quad_mux(a, b, c, d, s0, s1, yn):
    pins = [(1, 2, 3, 4), (5, 6, 7, 8), (11, 13, 14, 15), (16, 17, 18, 19)]
    n = {9: s0, 10: s1}
    for i in range(4):
        pa, pb, pc, pd = pins[i]
        n[pa], n[pb], n[pc], n[pd] = a[i], b[i], c[i], d[i]
        n[20 + i] = yn[i]
    return pld(n)


def alu(a, b, cin, sri, f, cout, z):
    n = {1: a[0], 2: a[1], 3: a[2], 4: a[3], 5: b[0], 6: b[1], 7: b[2], 8: b[3],
         9: "I5", 10: "I6", 11: "I7", 13: cin, 23: sri,
         17: f[0], 20: f[1], 16: f[2], 21: f[3], 18: cout, 14: z,
         15: None, 19: None, 22: None}
    return pld(n)


def sram(a15ce, oe, we):
    n = {"20": a15ce, "22": oe, "27": we, "28": "+5V", "14": "GND"}
    apins = [10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2, 26, 1]
    for i, p in enumerate(apins):
        n[str(p)] = A[i]
    for i, p in enumerate([11, 12, 13, 15, 16, 17, 18, 19]):
        n[str(p)] = D[i]
    return n


def R2(a, b):
    return {"1": a, "2": b}


# ---------------------------------------------------------------- helpers
class Board:
    def __init__(self, project, root_uuid):
        self.project = project
        self.root_uuid = root_uuid
        self.sheets = []

    def sheet(self, fname, title, page):
        su = K.det_uuid(self.project, "sheetbox", fname)
        s = K.Sheet(self.project, fname, title, page, self.root_uuid, su, DATE)
        s.names = PLD_NAMES
        self.sheets.append(s)
        return s


def decap(s, n, x, y, value="100n", lift=5.08):
    """Decoupling capacitor Cn beside chip Un, its +5V and GND symbols right on its pins.
    It sits lift above the given point, so its GND symbol clears the chip's top pins."""
    y -= lift
    s.part("placard_std:C", f"C{n}", x, y, {"1": "+5V", "2": "GND"}, value=value, footprint=FP_C, stub=0,
           ref_at=(x + 2.0, y - 0.5), value_at=(x + 2.0, y + 2.6))


def res(s, ref, x, y, a, b, value, angle=0, fp=FP_R, bare=(), ref_at=None, value_at=None):
    # angle 0: pin 1 on top; 90: pin 1 on the left
    return s.part("placard_std:R_US", ref, x, y, R2(a, b), value=value, footprint=fp, angle=angle,
           ref_at=ref_at or ((x + 2.0, y - 0.5) if angle == 0 else (x - 3.5, y - 1.6)),
           value_at=value_at or ((x + 2.0, y + 2.6) if angle == 0 else (x - 3.5, y + 1.6)), bare=bare)


def cap(s, ref, x, y, a, b, value, polar=False, angle=0, fp=None):
    s.part("placard_std:C_Polarized" if polar else "placard_std:C", ref, x, y, R2(a, b), value=value,
           footprint=fp or (FP_CP_S if polar else FP_C), angle=angle,
           ref_at=(x + 2.5, y - 0.5) if angle == 0 else (x - 3.5, y - 2.4),
           value_at=(x + 2.5, y + 2.6) if angle == 0 else (x - 3.5, y + 2.4))


def diode(s, ref, x, y, k, a, angle=0, value="BAT85", bare=(), ref_at=None, value_at=None):
    # angle 0: cathode (pin 1) on the left; 180: on the right; 270: on top
    return s.part("placard_std:D_Schottky", ref, x, y, {"1": k, "2": a}, value=value, footprint=FP_D, angle=angle,
           ref_at=ref_at or (x - 3.5, y - 1.8), value_at=value_at or (x - 3.5, y + 1.8), bare=bare)


def flag(s, net, x, y):
    """PWR_FLAG on a labelled net: flag pin at (x, y), label below it."""
    s.pwr_flag(x, y)
    s.wire(x, y, x, y + 5.08, owner=net)
    s.terminal(net, x, y + 5.08, 270)
    s.named.add(net)


def lab(s, net, x, y, angle):
    """The end of a wire the caller drew: wired to the net's other pins, or labelled."""
    s.terminal(net, x, y, angle)


def note(s, x, y, lines, size=2.5):
    for i, ln in enumerate(lines):
        s.text(ln, x, y + i * size * 1.6, size=size)


def heading(s, title, subtitle=""):
    s.text(title, 15, 22, size=6, bold=True)
    if subtitle:
        s.text(subtitle, 15, 30, size=3)


def path(s, net, *pts):
    """A hand-drawn wire of net through the points (each turn on the 1.27 mm grid)."""
    for k in range(len(pts) - 1):
        s.wire(pts[k][0], pts[k][1], pts[k + 1][0], pts[k + 1][1], owner=net)


def fan(s, links, x0, step=2.54):
    """Wires from source pins to target pins to their right, each with one jog.
    links: [(net, (sx, sy), (tx, ty))].  The jog columns are ordered so no two
    wires cross: of the wires that go up, the top one turns first; of those that
    go down, the bottom one turns first."""
    up = sorted([l for l in links if l[2][1] < l[1][1] - 0.01], key=lambda l: l[1][1])
    down = sorted([l for l in links if l[2][1] > l[1][1] + 0.01], key=lambda l: -l[1][1])
    col = {}
    for grp in (up, down):
        for i, l in enumerate(grp):
            col[id(l)] = x0 + i * step
    for l in links:
        net, (sx, sy), (tx, ty) = l
        if id(l) in col:
            x = col[id(l)]
            path(s, net, (sx, sy), (x, sy), (x, ty), (tx, ty))
        else:
            path(s, net, (sx, sy), (tx, ty))


def tag(s, net, x, y, angle=0):
    """A local label naming a hand-drawn bus member wire (the bus needs the member's name)."""
    s.label(net, x, y, angle, "passive", False)


def name(s, net, x, y, angle=0):
    """Name a hand-drawn wire: finish() puts a label there (global when the net leaves the sheet)."""
    s.terminal(net, x, y, angle, arm=False)


# ---------------------------------------------------------------- sheets
def sheet_power(b):
    s = b.sheet("power.kicad_sch", "Power and clock", 2)
    heading(s, "Power and clock", "USB-C 5 V in, 3.3 V for the SD card, 25.175 MHz oscillator (CLK), cartridge STALL and RUN")
    yr = 81.28      # the +5V rail, then +3V3, left to right
    # USB-C input: VBUS through the polyfuse onto the rail; 5.1k from CC1 and CC2 to GND
    j13 = s.part("placard_parts:USB_C_Power", "J13", 50.8, 88.9,
                 {"A9": "VBUS", "A5": "CC1", "B5": "CC2", "A12": "GND", "S1": "GND"}, stub=5.08,
                 ref_at=(36, 75), value_at=(36, 104), bare=("A9", "A5", "B5", "A12", "S1"))
    # GND and SHIELD join just right of the connector, clear of the CC wires
    xg = j13["A12"][0] + 2.54
    path(s, "GND", j13["A12"], (xg, j13["A12"][1]), (xg, j13["S1"][1]))
    path(s, "GND", j13["S1"], (xg, j13["S1"][1]), (xg, j13["S1"][1] + 5.08))
    s.junction(xg, j13["S1"][1], owner="GND")
    s.power("GND", xg, j13["S1"][1] + 5.08)
    f201 = s.part("placard_std:Polyfuse", "F1", 91.44, yr, {"1": "VBUS", "2": "+5V"}, value="3 A hold",
                  footprint="Fuse:Fuse_Bourns_MF-RG300", angle=90, bare=("1", "2"),
                  ref_at=(86.4, yr - 2.0), value_at=(86.4, yr + 2.0))
    path(s, "VBUS", j13["A9"], f201["1"])
    for net, pin, x in (("CC2", "B5", 73.66), ("CC1", "A5", 88.9)):
        r = s.part("placard_std:R_US", "R1" if net == "CC1" else "R2", x, 104.14, R2(net, "GND"), value="5.1k",
                   footprint=FP_R, bare=("1",), ref_at=(x + 2.0, 103.6), value_at=(x + 2.0, 106.7))
        path(s, net, j13[pin], (x, j13[pin][1]), r["1"])
    c201 = s.part("placard_std:C_Polarized", "C41", 114.3, yr + 3.81, {"1": "+5V", "2": "GND"},
                  value="220u 10V", footprint=FP_CP_L, bare=("1",), ref_at=(116.8, yr + 3.3), value_at=(116.8, yr + 6.4))
    # 3.3 V regulator on the same line
    u40 = s.part("placard_parts:MCP1700_TO92", "U40", 233.68, yr, {"1": "GND", "2": "+5V", "3": "+3V3"},
                 value="MCP1700-3302E/TO", bare=("2", "3"), ref_at=(223.5, yr - 10.5), value_at=(223.5, yr - 9.0))
    c40 = s.part("placard_std:C", "C40", 203.2, yr + 3.81, {"1": "+5V", "2": "GND"}, value="1u", footprint=FP_C,
                 bare=("1",), ref_at=(205.7, yr + 3.3), value_at=(205.7, yr + 6.4))
    xp, xf = 139.7, 127.0
    for pts in ([f201["2"], (c201["1"][0], yr)], [(c201["1"][0], yr), (xf, yr)], [(xf, yr), (xp, yr)],
                [(xp, yr), (c40["1"][0], yr)], [(c40["1"][0], yr), u40["2"]]):
        path(s, "+5V", *pts)
    for x in (c201["1"][0], c40["1"][0]):
        s.junction(x, yr, owner="+5V")
    s.pwr_flag(xf, yr)
    s.power("+5V", xp, yr)
    c202 = s.part("placard_std:C", "C42", 254.0, yr + 3.81, {"1": "+3V3", "2": "GND"}, value="1u", footprint=FP_C,
                  bare=("1",), ref_at=(256.5, yr + 3.3), value_at=(256.5, yr + 6.4))
    x3, xf3 = 264.16, 274.32
    path(s, "+3V3", u40["3"], (c202["1"][0], yr))
    path(s, "+3V3", (c202["1"][0], yr), (x3, yr))
    path(s, "+3V3", (x3, yr), (xf3, yr))
    s.junction(c202["1"][0], yr, owner="+3V3")
    s.power("+3V3", x3, yr)
    s.pwr_flag(xf3, yr)
    note(s, 25, 122, ["5.1k on CC1 and CC2: a USB-C source gives 5 V.",
                      "19 PLDs draw up to about 2.5 A",
                      "(130 mA each at -7, worst case): use a 3 A",
                      "supply; the polyfuse trips on a short."])
    note(s, 200, 112, ["U40: 3.3 V for the SD card only (sheet 10).", "C40 input, C42 output (1 uF ceramic)."])
    # analog ground joins logic ground at the power input
    # (each side has its power flag on the pin end and its ground symbol below)
    nt = s.part("placard_std:NetTie_2", "NT1", 165.1, 104.14, {"1": "GND", "2": "GNDA"}, value="AGND tie",
                footprint="NetTie:NetTie-2_THT_Pad0.3mm", ref_at=(158, 97), value_at=(160.5, 107),
                bare=("1", "2"))
    for net in ("GND", "GNDA"):
        (px, py) = nt["1" if net == "GND" else "2"]
        xa = px - 7.62 if net == "GND" else px + 7.62
        path(s, net, (px, py), (xa, py), (xa, py + 5.08))
        s.pwr_flag(xa, py)
        s.power(net, xa, py + 5.08)
    note(s, 152, 128, ["AGND (audio) meets GND", "here, at the power input"])
    # oscillator
    s.part("placard_parts:Oscillator_DIP14", "X1", 63.5, 170.18, {"14": "+5V", "7": "GND", "8": "CLK"},
           value="25.175 MHz", ref_at=(50, 160), value_at=(66, 181.0))
    decap(s, 43, 81.28, 160.02, lift=0)     # C43: the oscillator's, X1 has no U-number
    # the cartridge's STALL and RUN: pull-ups, and jumpers for bring-up without a cartridge
    yj = 170.18
    r203 = s.part("placard_std:R_US", "R3", 152.4, yj - 10.16, R2("+5V", "STALL_OUT"), value="10k", footprint=FP_R,
                  bare=("2",), ref_at=(154.9, yj - 10.7), value_at=(154.9, yj - 7.6))
    jp201 = s.part("placard_std:Jumper_2_Open", "JP1", 139.7, yj, {"1": "STALL_IN", "2": "STALL_OUT"}, value="STALL",
                   footprint=FP_JP, ref_at=(134, yj - 4.5), value_at=(134, yj + 2.5), bare=("2",))
    path(s, "STALL_OUT", r203["2"], (152.4, yj))
    path(s, "STALL_OUT", jp201["2"], (152.4, yj))
    path(s, "STALL_OUT", (152.4, yj), (162.56, yj))
    s.terminal("STALL_OUT", 162.56, yj, 0)
    r204 = s.part("placard_std:R_US", "R4", 236.22, yj + 10.16, R2("RUN", "GND"), value="10k", footprint=FP_R,
                  bare=("1",), ref_at=(238.7, yj + 9.6), value_at=(238.7, yj + 12.7))
    jp202 = s.part("placard_std:Jumper_2_Open", "JP2", 251.46, yj, {"1": "RUN", "2": "+5V"}, value="RUN",
                   footprint=FP_JP, ref_at=(246, yj - 4.5), value_at=(246, yj + 2.5), bare=("1",))
    path(s, "RUN", jp202["1"], (236.22, yj))
    path(s, "RUN", r204["1"], (236.22, yj))
    path(s, "RUN", (236.22, yj), (226.06, yj))
    s.terminal("RUN", 226.06, yj, 180)
    note(s, 130, 200, ["STALL_OUT (10k up) and RUN (10k down) come from the",
                       "cartridge: STALL_IN (the Branch PLD's STALL) goes out to it.",
                       "Without one, fit JP1 and JP2 for bring-up",
                       "(BRINGUP.md); take them out with a cartridge."])
    return s


def sheet_control(b):
    s = b.sheet("control.kicad_sch", "Control", 3)
    heading(s, "Control", "State and Branch PLDs, instruction register")
    # D -> U17 (instruction register) -> I -> U1 (State) and U2 (Branch), left to right.
    # U2 sits 11 rows higher than U1 so Q0 and PC_ENABLE run straight across.
    y1 = 154.94
    y2 = y1 - 27.94
    s.part("placard:ATF22V10C_IR", "U17", 71.12, y1, pld({
        1: "CLK", 2: "D0", 3: "D1", 4: "D2", 5: "D3", 6: "D4", 7: "D5", 8: "D6", 9: "D7",
        10: "~{LOAD_INSTR}", 11: "RUN", 14: "I0", 15: "I1", 16: "I2", 17: "I3", 18: "I4", 19: "I5",
        20: "I6", 21: "I7"}))
    decap(s, 17, 91.44, y1 - 33.02, lift=0)
    u1 = s.part("placard:ATF22V10C_STATE", "U1", 172.72, y1, pld({
        1: "CLK", 2: "STALL_OUT", 3: "D1", 4: "D0", 5: "I4", 6: "I3", 7: "I2", 8: "BRANCH_BLOCK",
        9: "D3", 10: "D2", 11: "D4", 13: "I0", 18: "Q0", 15: "PC_ENABLE", 16: "X_ENABLE", 17: "Y_ENABLE",
        14: "~{LOAD_INSTR}", 19: "~{LOAD_IMM}", 20: "~{LOAD_X}", 21: "~{LOAD_Y}", 22: "~{LOAD_AC}", 23: "RW"}),
        bare=("8", "18", "15"))
    decap(s, 1, 193.04, y1 - 27.94, lift=0)
    u2 = s.part("placard:ATF22V10C_BRANCH", "U2", 294.64, y2, pld({
        1: "CLK", 17: "I7", 2: "I6", 3: "I5", 4: "I4", 5: "I3", 6: "I2", 7: "Z_LOW", 8: "AC7",
        9: "PIXEL_ENABLE", 10: "Q0", 11: "PC_ENABLE", 13: "Z_HIGH", 14: "COUT",
        21: "LOAD_PC_LOW", 22: "LOAD_PC_HIGH", 23: "BRANCH_BLOCK", 18: None, 19: "STALL_IN",
        16: "~{SRC_EN}", 20: None, 15: "~{PIX_LD}"}), bare=("23", "10", "11"))
    decap(s, 2, 314.96, y2 - 33.02, lift=0)
    # Q0 and PC_ENABLE straight across; PC_ENABLE also leaves the sheet
    for net, a_, b_ in (("Q0", "18", "10"), ("PC_ENABLE", "15", "11")):
        path(s, net, u1[a_], u2[b_])
    name(s, "Q0", u1["18"][0] + 2.54, u1["18"][1])
    # PC_ENABLE leaves the sheet: a tee up over Q0 to its label
    xt, yp = u1["15"][0] + 10.16, u1["15"][1]
    s.junction(xt, yp, owner="PC_ENABLE")
    path(s, "PC_ENABLE", (xt, yp), (xt, yp - 7.62))
    name(s, "PC_ENABLE", xt, yp - 7.62, 90)
    # BRANCH_BLOCK: from U2 back over the top into U1
    (bx, by), (ux, uy) = u2["23"], u1["8"]
    ytop = y2 - 45.72
    xl = ux - 2.54
    path(s, "BRANCH_BLOCK", (bx, by), (bx + 5.08, by), (bx + 5.08, ytop), (xl, ytop), (xl, uy), (ux, uy))
    name(s, "BRANCH_BLOCK", xl + 40.64, ytop)
    note(s, 40, 215, ["U17 loads the opcode in FETCH (/LOAD_INSTR) and holds 02h while RUN is low.",
                      "U2's STALL (STALL_IN) goes to the cartridge; STALL_OUT comes back to U1 and the PC.",
                      "U1 State: FETCH / LOAD / EXEC, register loads (active low, F377 /E), RW (1 = read).",
                      "U2 Branch: NEG is AC7.  ALU_DONE (18) and CARRY (20) are internal registers: no connection.",
                      "Bring-up straps S1-S3 go in U1's socket (BRINGUP.md), not on the board."])
    return s


def sheet_pc_mux(b):
    s = b.sheet("pc_mux.kicad_sch", "Program counter and address mux", 4)
    heading(s, "Program counter and address mux", "Mux inputs: A = D / 0, B = X / Y, C = video address, D = PC")
    # the buses from other sheets get a label at each chip; PC runs from U3 / U4 to the muxes' D inputs
    s.label_each |= {"DR", "X", "Y", "VA", "V", "H", "A", "D"}
    u3 = s.part("placard:ATF22V10C_PC_COUNTER8", "U3", 91.44, 93.98,
                pc_counter(D, "LOAD_PC_LOW", "+5V", PC[0:8], "PC_CO"), bare=("13", "23"))
    decap(s, 3, 111.76, 63.5, lift=0)
    u4 = s.part("placard:ATF22V10C_PC_COUNTER8", "U4", 91.44, 195.58,
                pc_counter(Y, "LOAD_PC_HIGH", "PC_CO", PC[8:16], None), bare=("13",))
    decap(s, 4, 111.76, 165.1, lift=0)
    # U3 CIN tied high; U3 CO down between the two and into U4 CIN
    (cx, cy) = u3["13"]
    path(s, "+5V", (cx, cy), (cx - 2.54, cy), (cx - 2.54, cy - 5.08))
    s.power("+5V", cx - 2.54, cy - 5.08)
    (ox, oy), (ix, iy) = u3["23"], u4["13"]
    yg = 142.24
    path(s, "PC_CO", (ox, oy), (ox + 2.54, oy), (ox + 2.54, yg), (ix - 2.54, yg), (ix - 2.54, iy), (ix, iy))
    mux = {}
    for ref, x, y, nib, lo in [("U7", 223.52, 93.98, 0, True), ("U8", 337.82, 93.98, 1, True),
                               ("U9", 223.52, 195.58, 2, False), ("U10", 337.82, 195.58, 3, False)]:
        bits = range(nib * 4, nib * 4 + 4)
        if lo:
            n = quad_mux([DR[i] for i in bits], [X[i] for i in bits], [VA[i] for i in bits], [PC[i] for i in bits],
                         "ADDR_SEL_LO", "ADDR_SEL", [A[i] for i in bits])
        else:
            n = quad_mux(["GND"] * 4, [Y[i - 8] for i in bits], [VA[i] for i in bits], [PC[i] for i in bits],
                         "ADDR_SEL_HI", "ADDR_SEL", [A[i] for i in bits])
        mux[ref] = s.part("placard:ATF22V10C_QUAD_MUX", ref, x, y, n, bare=("9", "10") if lo else ("9", "10", "1", "5", "11", "16"))
        if not lo:      # A3:A0 tied low
            m = mux[ref]
            xg = m["1"][0] - 2.54
            for pn in ("1", "5", "11", "16"):
                path(s, "GND", m[pn], (xg, m[pn][1]))
            path(s, "GND", (xg, m["1"][1]), (xg, m["16"][1]))
            for pn in ("5", "11", "16"):
                s.junction(xg, m[pn][1], owner="GND")
            s.power("GND", xg, m["16"][1])
        decap(s, int(ref[1:]), x + 20.32, y - 33.02, lift=0)
    # select lines over the top of each row: S0 (ADDR_SEL_LO / _HI) joins its pair,
    # S1 (ADDR_SEL) runs along the top and down the right edge to the lower row
    xw, xe, xr = 167.64, 284.48, 391.16
    rows = (("U7", "U8", "ADDR_SEL_LO", 43.18), ("U9", "U10", "ADDR_SEL_HI", 147.32))
    for left, right, s0, ylane in rows:
        (lx, ly0), (_, ly1) = mux[left]["9"], mux[left]["10"]
        (rx, ry0), (_, ry1) = mux[right]["9"], mux[right]["10"]
        path(s, s0, (lx - 15.24, ly0), (lx - 2.54, ly0), (lx, ly0))
        path(s, s0, (lx - 2.54, ly0), (lx - 2.54, ylane + 2.54), (rx - 2.54, ylane + 2.54), (rx - 2.54, ry0), (rx, ry0))
        s.junction(lx - 2.54, ly0, owner=s0)
        name(s, s0, lx - 15.24, ly0, 180)
        path(s, "ADDR_SEL", (xw, ylane), (xw, ly1), (lx, ly1))
        path(s, "ADDR_SEL", (xe, ylane), (xe, ry1), (rx, ry1))
        path(s, "ADDR_SEL", (xw, ylane), (xe, ylane), (xr, ylane))
        s.junction(xe, ylane, owner="ADDR_SEL")
    path(s, "ADDR_SEL", (xr, rows[0][3]), (xr, rows[1][3]))
    name(s, "ADDR_SEL", xw, rows[0][3], 180)
    # PC: down from U3 and U4, then along under each row of muxes
    s.bus_piece("PC", [(127.0, 99.06), (127.0, 243.84), (312.42, 243.84)])
    s.bus_piece("PC", [(127.0, 139.7), (312.42, 139.7)])
    s.junction(127.0, 139.7, owner="BUS:PC")
    note(s, 20, 258, ["Video address: VA0, VA1, VA7, VA8 from the audio slot PLD (line repeat), A6:A2 = V6:V2, A15:A9 = H9:H3.",
                      "U3 CIN tied high (always counts); U3 CO carries into U4.  STALL_OUT holds the PC (video reads, ALU wait, cartridge load)."],
         size=2.2)
    return s


def sheet_alu(b):
    s = b.sheet("alu_regs.kicad_sch", "ALU and registers", 5)
    heading(s, "ALU and registers", "Two 4-bit ALU PLDs; F7:F0 loads AC, X or Y")
    s.label_each |= {"D", "X", "Y", "I"}
    s.force_bus |= {"I"}
    s.label_nets |= {"CLK"}
    u5 = s.part("placard:ATF22V10C_ALU_SHR", "U5", 91.44, 88.9,
                alu(AC[0:4], D[0:4], "GND", "AC4", F[0:4], "ALU_C3", "Z_LOW"), bare=("18",))
    decap(s, 5, 111.76, 58.42, lift=0)
    u6 = s.part("placard:ATF22V10C_ALU_SHR", "U6", 91.44, 190.5,
                alu(AC[4:8], D[4:8], "ALU_C3", "GND", F[4:8], "COUT", "Z_HIGH"), bare=("13",))
    decap(s, 6, 111.76, 160.02, lift=0)
    # the low nibble's carry out goes down between the two into the high nibble's CIN
    (ox, oy), (ix, iy) = u5["18"], u6["13"]
    yg = 137.16
    path(s, "ALU_C3", (ox, oy), (ox + 2.54, oy), (ox + 2.54, yg), (ix - 2.54, yg), (ix - 2.54, iy), (ix, iy))
    # F7:F0 from both ALUs down one bus line to the three registers
    for ref, y, q, load in (("U19", 78.74, AC, "~{LOAD_AC}"), ("U21", 147.32, Y, "~{LOAD_Y}"),
                            ("U20", 215.9, X, "~{LOAD_X}")):
        s.part("placard_std:74LS377", ref, 243.84, y + 5.08, f377(F, q, load), value="SN74F377AN", footprint=FP_DIP20)
        decap(s, int(ref[1:]), 264.16, y - 20.32, lift=0)
    s.bus_piece("F", [(167.64, 63.5), (167.64, 175.26)])
    # AC back over the top and down the left side to the A inputs
    s.bus_piece("AC", [(276.86, 40.64), (30.48, 40.64), (30.48, 167.64)])
    note(s, 290, 180, ["A = AC, B = the data bus (the source in EXEC).",
                       "S2:S0 = I7:I5.",
                       "Low nibble: CIN = 0, shift-right in = AC4.",
                       "High nibble: CIN = low COUT, shift-right in = 0.",
                       "COUT (high) is the carry for the Branch PLD.",
                       "D1-D3 (15, 19, 22) are internal carry nodes."])
    return s


def sheet_databus(b):
    s = b.sheet("data_bus.kicad_sch", "Data bus", 6)
    heading(s, "Data bus", "D register, source drivers (D or AC) onto the one data bus through series resistors, read pull-ups")
    s.part("placard_std:74LS377", "U18", 76.2, 101.6, f377(D, DR, "~{LOAD_IMM}"), value="SN74F377AN", footprint=FP_DIP20)
    decap(s, 18, 96.52, 73.66, lift=0)
    u26 = s.part("placard_std:74LS541", "U26", 157.48, 101.6, f541(DR, SRC, "~{SRC_EN}", "I1"), value="SN74F541N",
                 footprint=FP_DIP20, bare=("1",))
    decap(s, 26, 177.8, 73.66, lift=0)
    u27 = s.part("placard_std:74LS541", "U27", 157.48, 200.66, f541(AC, SRC, "~{SRC_EN}", "~{AC_SEL}"), value="SN74F541N",
                 footprint=FP_DIP20, bare=("1",))
    decap(s, 27, 177.8, 172.72, lift=0)
    # /SRC_EN to both /OE1 pins, down the far side of U27's AC label
    (ax, ay), (bx_, by_) = u26["1"], u27["1"]
    xv = ax - 35.56
    path(s, "~{SRC_EN}", (ax, ay), (xv, ay), (xv, by_), (bx_, by_))
    name(s, "~{SRC_EN}", xv, ay, 180)
    # the series resistors in a row: SRC on the bus line under them, D on the one above
    for i in range(8):
        x = 226.06 + i * 12.7
        s.part("placard_std:R_US", f"R{5 + i}", x, 147.32, R2(D[i], SRC[i]), value="47", footprint=FP_R,
               ref_at=(x + 1.6, 146.3), value_at=(x + 1.6, 149.4))
    s.bus_piece("SRC", [(198.12, 162.56), (320.04, 162.56)])
    s.bus_piece("D", [(373.38, 132.08), (215.9, 132.08), (215.9, 48.26), (33.02, 48.26), (33.02, 91.44)])
    s.part("placard_std:R_Network08_US", "RN1", 355.6, 116.84, {"1": "+5V", **{str(2 + i): D[i] for i in range(8)}},
           value="10k", footprint=FP_SIP9, ref_at=(359, 104.5), value_at=(375, 104.5))
    note(s, 230, 200, ["SRC7:SRC0: the two source F541s' joined outputs.",
                       "R5-R12 (47 ohm) limit the current while the",
                       "bus changes hands at the start of EXEC (CPU.md).",
                       "U26 drives D (sources 00, 01: /OE2 = I1),",
                       "U27 drives AC (10, 11: /OE2 = /AC_SEL).",
                       "RN1: D7:D0 read FFh when nothing drives them",
                       "(empty slots, the cartridge loader's feed byte)."])
    return s


def sheet_memory(b):
    s = b.sheet("memory.kicad_sch", "Memory and I/O decode", 7)
    heading(s, "Memory and I/O decode", "RAM, ROM cartridge slot, memory control, I/O decode, map register")
    # A and D come from other sheets: a label at each chip.  The clock and the CPU's control
    # lines that arrive from other sheets are labelled at each pin; the memory strobes are wired.
    s.label_each |= {"A", "D"}
    s.label_nets |= {"CLK", "RUN", "PIXEL_ENABLE", "RW"}
    # map register U25 feeds RAMSEL7:0 straight across into U11
    u25 = s.part("placard_std:74LS273", "U25", 66.04, 101.6, ls273(D, RAMSEL, "RUN", "~{MAP_WR}"), value="CD74ACT273E",
                 footprint=FP_DIP20, bare=("11",))
    decap(s, 25, 45.72, 73.66, lift=0)
    u11 = s.part("placard:ATF22V10C_MEM_CTRL", "U11", 154.94, 101.6, pld({
        1: "CLK", 2: "A15", 3: "A14", 4: "A13", 5: "A12", 6: "RAMSEL0", 7: "RAMSEL1", 8: "RAMSEL3",
        9: "RAMSEL4", 10: "RAMSEL5", 11: "RAMSEL6", 13: "RAMSEL7", 15: "RAMSEL2", 14: "RW",
        23: "PIXEL_ENABLE", 20: "A11", 21: "A10", 22: "~{SRC_EN}", 17: "RUN",
        16: "~{WE}", 19: "~{ROM_OE}", 18: "~{RAM_OE}"}), bare=("16", "18", "19"))
    decap(s, 11, 175.26, 58.42, lift=0)
    u12 = s.part("placard:ATF22V10C_IO_DECODE", "U12", 154.94, 208.28, pld({
        1: "~{WE}", 2: "ADDR_SEL", 3: "ADDR_SEL_HI", 4: "PC15", 5: "H9", 6: "Y7", 7: "A14", 8: "A13",
        9: "A12", 10: "A10", 11: "A9", 13: "A8", 14: "RW", 18: "A11", 23: "~{LOAD_IMM}",
        15: "~{CE_HI}", 16: "~{MAP_WR}", 17: "~{LINE_RD}", 19: "~{PORT_WR}", 20: "~{PORT_RD}",
        21: "~{EXP1}", 22: "~{EXP2}"}), bare=("1", "15", "16"))
    decap(s, 12, 121.92, 172.72, lift=0)      # left of VCC: /MAP_WR goes up on the right
    u31 = s.part("placard_parts:AS7C256C", "U31", 264.16, 198.12, sram("A15", "~{RAM_OE}", "~{WE}"),
                 value="AS7C256C-15PCN", bare=("22", "27"))
    decap(s, 31, 284.48, 165.1, lift=0)
    u32 = s.part("placard_parts:AS7C256C", "U32", 345.44, 198.12, sram("~{CE_HI}", "~{RAM_OE}", "~{WE}"),
                 value="AS7C256C-15PCN", bare=("20", "22", "27"))
    decap(s, 32, 365.76, 165.1, lift=0)
    cart = {"A3": "A0", "B3": "A1", "A4": "A2", "B4": "A3", "A5": "A4", "B5": "A5", "A6": "A6", "B6": "A7",
            "A7": "A8", "B7": "A9", "A8": "A10", "B8": "A11", "A9": "A12", "B9": "A13", "A10": "A14",
            "A16": "A15", "B16": "~{CE_HI}", "A17": "~{ROM_OE}", "B10": "~{CART}",
            "A12": "D0", "B12": "D1", "A13": "D2", "B13": "D3", "A14": "D4", "B14": "D5", "A15": "D6", "B15": "D7",
            "A20": "CLK", "B17": "STALL_IN", "A18": "PIXEL_ENABLE", "B18": "STALL_OUT", "A19": "RUN",
            "B19": "PC_ENABLE",
            "A2": "+5V", "A1": "GND"}
    for c in ["A22", "A23", "A24", "A25", "A26", "A27", "A28", "A29", "A30", "A32", "B20",
              "B22", "B23", "B24", "B25", "B26", "B27", "B28", "B29", "B30", "B32"]:
        cart[c] = None
    j8 = s.part("placard_parts:Cartridge_Slot", "J8", 320.04, 95.25, cart, value="Molex 87715-9106",
                ref_at=(304.8, 44), value_at=(304.8, 150), bare=("B16", "A17"))
    # the memory strobes: U11's down to lanes under the RAMs, /CE_HI from U12 up to J8 and down to U32,
    # /MAP_WR from U12 back round to U25's clock
    yl = {"~{WE}": 246.38, "~{RAM_OE}": 248.92, "~{CE_HI}": 251.46}
    xv = {"~{WE}": 208.28, "~{RAM_OE}": 210.82, "~{ROM_OE}": 215.9, "~{CE_HI}": 205.74}
    for net, pn in (("~{WE}", "16"), ("~{RAM_OE}", "18")):
        (px, py) = u11[pn]
        path(s, net, (px, py), (xv[net], py), (xv[net], yl[net]))
    (px, py) = u11["19"]
    path(s, "~{ROM_OE}", (px, py), (xv["~{ROM_OE}"], py), (xv["~{ROM_OE}"], j8["A17"][1]), j8["A17"])
    (px, py) = u12["15"]
    path(s, "~{CE_HI}", (px, py), (xv["~{CE_HI}"], py))
    path(s, "~{CE_HI}", (xv["~{CE_HI}"], j8["B16"][1]), (xv["~{CE_HI}"], py), (xv["~{CE_HI}"], yl["~{CE_HI}"]))
    path(s, "~{CE_HI}", (xv["~{CE_HI}"], j8["B16"][1]), j8["B16"])
    s.junction(xv["~{CE_HI}"], py, owner="~{CE_HI}")
    (px, py) = u12["1"]
    path(s, "~{WE}", (px, py), (px - 2.54, py), (px - 2.54, yl["~{WE}"]), (xv["~{WE}"], yl["~{WE}"]))
    s.junction(xv["~{WE}"], yl["~{WE}"], owner="~{WE}")
    risers = [(u31, "27", "~{WE}", 2.54), (u31, "22", "~{RAM_OE}", 5.08),
              (u32, "27", "~{WE}", 2.54), (u32, "22", "~{RAM_OE}", 5.08), (u32, "20", "~{CE_HI}", 7.62)]
    xend = {}
    for u, pn, net, dx in risers:
        (px, py) = u[pn]
        path(s, net, (px, py), (px - dx, py), (px - dx, yl[net]))
        xend[net] = max(xend.get(net, 0), px - dx)
    xend["~{WE}"] = 383.54     # /WE also goes to the expansion slots: its label at the lane's end
    name(s, "~{WE}", xend["~{WE}"], yl["~{WE}"], 0)
    for net, y in yl.items():
        x0 = xv[net]
        path(s, net, (x0, y), (xend[net], y))
    for u, pn, net, dx in risers:
        x = u[pn][0] - dx
        if x < xend[net] - 0.01:
            s.junction(x, yl[net], owner=net)
    (px, py) = u12["16"]
    path(s, "~{MAP_WR}", (px, py), (px + 2.54, py), (px + 2.54, 154.94), (20.32, 154.94), (20.32, u25["11"][1]),
         u25["11"])
    res(s, "R13", 271.78, 132.08, "+5V", "~{CART}", "10k")
    note(s, 20, 258, ["Lower 32K: /CE = A15 (RAM U31, cartridge /CE_LO); upper: /CE_HI from U12.",
                       "RUN low (cartridge loading): /ROM_OE held off, map register clear (all ROM).",
                       "/CART reads low with a cartridge in; nothing reads it yet.  21 spare contacts."],
         size=2.2)
    return s


def sheet_video_timing(b):
    s = b.sheet("video_timing.kicad_sch", "Video timing", 8)
    heading(s, "Video timing", "640 x 480 at 60 Hz: H and V counters, Sync, mode and audio slots, line read")
    s.label_nets |= {"CLK"}
    u13 = s.part("placard:ATF22V10C_HCOUNT", "U13", 76.2, 99.06, pld({
        1: "CLK", 2: "GND", 3: "H0", 4: "H1", 5: "H2", 14: "H3", 15: "H4", 16: "H5", 17: "H6", 18: "H7",
        19: "H8", 20: "H9", 21: "~{HSYNC}", 22: "H_VIDEO_ACTIVE", 23: "H_TC"}), bare=("23",))
    decap(s, 13, 96.52, 63.5, lift=0)
    u14 = s.part("placard:ATF22V10C_VCOUNT", "U14", 76.2, 208.28, pld({
        1: "CLK", 2: "H_TC", 14: "V0", 23: "V1", 22: "V2", 15: "V3", 16: "V4", 21: "V5", 20: "V6",
        17: "V7", 18: "V8", 19: "V9"}), bare=("2",))
    decap(s, 14, 96.52, 175.26, lift=0)
    # H_TC: out of the H counter, down between the two and into the V counter's EN
    (ox, oy), (ix, iy) = u13["23"], u14["2"]
    yg = 152.4
    path(s, "H_TC", (ox, oy), (ox + 2.54, oy), (ox + 2.54, yg), (ix - 2.54, yg), (ix - 2.54, iy), (ix, iy))
    s.part("placard:ATF22V10C_SYNC", "U15", 233.68, 99.06, pld({
        1: "CLK", 2: "V9", 3: "V5", 4: "V4", 5: "V3", 6: "V2", 7: "V1", 8: "H_VIDEO_ACTIVE",
        9: "PC_ENABLE", 10: "Y_ENABLE", 11: "X_ENABLE", 13: "BLANK_RD", 14: "H0", 15: "H1", 16: "H2",
        17: "VIDEN", 18: "VSYNC", 19: "PIXEL_ENABLE", 20: "ADDR_SEL", 21: "ADDR_SEL_HI", 22: "ADDR_SEL_LO",
        23: None}))
    decap(s, 15, 254.0, 60.96, lift=0)
    s.part("placard:ATF22V10C_AUDIO", "U35", 233.68, 205.74, pld({
        1: "V0", 2: "H9", 3: "H8", 4: "H7", 5: "H6", 6: "H5", 7: "H4", 8: "H3", 9: "V9", 10: "V1",
        11: "V7", 13: "V8", 14: "LC2", 15: "LC3", 16: "I1", 17: "VA0", 18: "VA1", 19: "VA7", 20: "VA8",
        22: "~{MODE_LD}", 23: "BLANK_RD", 21: "~{AC_SEL}"}))
    decap(s, 35, 254.0, 167.64, lift=0)
    s.part("placard_std:74LS541", "U29", 345.44, 154.94, f541(V[2:10], D, "~{LINE_RD}", "GND"), value="SN74F541N",
           footprint=FP_DIP20)
    decap(s, 29, 365.76, 129.54, lift=0)
    # H: over the top from the Sync PLD to the H counter, and down to the audio slot PLD
    s.bus_piece("H", [(157.48, 43.18), (40.64, 43.18), (40.64, 66.04)])
    s.bus_piece("H", [(157.48, 43.18), (157.48, 182.88)])
    s.bus_piece("H", [(157.48, 43.18), (289.56, 43.18), (289.56, 66.04)])
    s.junction(157.48, 43.18, owner="BUS:H")
    # V: up from the V counter to the Sync PLD, along under it to U29
    s.bus_piece("V", [(152.4, 203.2), (152.4, 104.14)])
    s.bus_piece("V", [(152.4, 154.94), (325.12, 154.94)])
    s.junction(152.4, 154.94, owner="BUS:V")
    note(s, 290, 200, ["H2:H0 come from the Sync PLD (two clocks",
                       "behind the group), into the H counter and",
                       "the color decoder.  H counter pin 2 (RESET)",
                       "is unused: tied low.",
                       "U35 also makes /AC_SEL (= !I1) for the AC",
                       "source driver, and remaps video A0, A1, A7, A8",
                       "for line repeat (VA0, VA1, VA7, VA8).",
                       "V_VIDEO_ACTIVE (U15 pin 23) is internal.",
                       "U29: x5000 read gives V9:V2.",
                       "Strap S4 goes in U35's socket (BRINGUP.md)."])
    return s


def sheet_video_out(b):
    s = b.sheet("video_out.kicad_sch", "Video and audio out", 9)
    heading(s, "Video and audio out", "Pixel buffer, line code, color decoder and VGA DAC; audio DAC register, R-2R ladder, headphones")
    PIXB = tuple(str(p) for p in F377_Q)
    # ---- video: D -> U22 pixel buffer -> U16 color decoder -> resistor DAC -> VGA
    u22 = s.part("placard_std:74LS377", "U22", 63.5, 101.6, f377(D, PIX, "~{PIX_LD}"), value="SN74F377AN",
                 footprint=FP_DIP20, bare=PIXB)
    decap(s, 22, 78.74, 76.2, lift=0)
    u16 = s.part("placard:ATF22V10C_COLORDECODER", "U16", 190.5, 109.22, pld({
        2: "PIX0", 3: "PIX1", 4: "PIX2", 5: "PIX3", 6: "PIX4", 7: "PIX5", 8: "PIX6", 9: "PIX7",
        10: "LC0", 11: "LC1", 13: "H0", 1: "H1", 14: "H2", 23: "VIDEN",
        15: "RED1", 16: "RED2", 21: "RED3", 22: "BLU2", 18: "BLU3", 17: "GRN1", 20: "GRN2", 19: "GRN3"}),
        bare=("2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "15", "16", "21", "17", "20", "19", "22", "18"))
    decap(s, 16, 213.36, 76.2, lift=0)
    # PIX7:PIX0 straight across, tapped onto the PIX bus that feeds U23 and U36
    xt = 101.6
    for i in range(8):
        (x1, y), (x2, _) = u22[str(F377_Q[i])], u16[str(2 + i)]
        path(s, PIX[i], (x1, y), (xt, y), (x2, y))
        tag(s, PIX[i], x1 + 2.54, y)
        s.junction(xt, y, owner=PIX[i])
        s.bus_entry(xt, y, 1.27, 1.27, PIX[i], "BUS:PIX")
    yb0 = u22[str(F377_Q[0])][1] + 1.27
    s.bus_piece("PIX", [(xt + 1.27, yb0), (xt + 1.27, u22[str(F377_Q[7])][1] + 1.27)])
    # U23 line code: PIX in, LC1:LC0 up into U16, LC3:LC2 to the audio slot PLD (sheet 8)
    u23 = s.part("placard_std:74LS377", "U23", 132.08, 152.4,
                 f377(PIX, ["LC0", "LC1", "LC2", "LC3", None, None, None, None], "~{MODE_LD}"),
                 value="SN74F377AN", footprint=FP_DIP20, bare=("2", "5"))
    decap(s, 23, 180.34, 152.4, lift=0)
    for k, xj in ((0, 147.32), (1, 149.86)):   # clear of U16's H0-H2 and VIDEN tabs
        (qx, qy), (mx, my) = u23[str(F377_Q[k])], u16[str(10 + k)]
        path(s, f"LC{k}", (qx, qy), (xj, qy), (xj, my), (mx, my))
        name(s, f"LC{k}", mx - 10.16, my)
    # RGB: U16 outputs fan out to one resistor per row, then into J7
    outs = [("RED1", "15", "3.24k"), ("RED2", "16", "1.69k"), ("RED3", "21", "825"),
            ("GRN1", "17", "3.24k"), ("GRN2", "20", "1.69k"), ("GRN3", "19", "825"),
            ("BLU2", "22", "1.43k"), ("BLU3", "18", "715")]
    xr = 245.11
    y0 = u16["15"][1]
    links, rpins = [], []
    for i, (net, pin, v) in enumerate(outs):
        yr = y0 + i * 5.08
        color = "VGA_" + net[0]
        rp = s.part("placard_std:R_US", f"R{14 + i}", xr, yr, R2(net, color), value=v, footprint=FP_R, angle=90,
                    bare=("1", "2"), ref_at=(xr - 9.0, yr - 1.3), value_at=(xr + 5.6, yr - 3.4))
        links.append((net, u16[pin], rp["1"]))
        rpins.append((color, rp["2"]))
        name(s, net, u16[pin][0] + 1.27, u16[pin][1])
    fan(s, links, 215.9)
    j7 = s.part("placard_std:DE15_Receptacle_HighDensity_MountingHoles", "J7", 316.23, 101.6, {
        "1": "VGA_R", "2": "VGA_G", "3": "VGA_B", "4": None, "5": "GND", "6": "GND", "7": "GND", "8": "GND",
        "9": None, "10": "GND", "11": None, "12": None, "13": "~{HSYNC}", "14": "VSYNC", "15": None, "0": "GND"},
        value="VGA", ref_at=(311, 84), value_at=(311, 126), bare=("1", "2", "3"))
    xc = 264.16
    for color, pin, xj in (("VGA_R", "1", None), ("VGA_G", "2", 274.32), ("VGA_B", "3", 281.94)):
        ys = [p[1] for c, p in rpins if c == color]
        for (c, p) in rpins:
            if c == color:
                path(s, color, p, (xc, p[1]))
        path(s, color, (xc, min(ys)), (xc, max(ys)))
        jx, jy = j7[pin]
        if xj is None:      # red: straight across from the middle of its group
            path(s, color, (xc, jy), (jx, jy))
        else:
            path(s, color, (xc, ys[0]), (xj, ys[0]), (xj, jy), (jx, jy))
        name(s, color, jx - 15.24, jy)
    # ---- audio: PIX -> U36 DAC register -> R-2R ladder -> C46 -> J6
    u36 = s.part("placard_std:74LS574", "U36", 139.7, 218.44,
                 ls574(PIX, bus("DAC", 8), "GNDA", "H_VIDEO_ACTIVE", vcc="DAC_5V", gnd="GNDA"),
                 value="SN74HCT574N", footprint=FP_DIP20, bare=tuple(str(19 - i) for i in range(8)) + ("20",))
    # U36's own filtered supply, one straight rail: +5V -> 2.2 ohm -> DAC_5V, 220u and 100n to GNDA
    yr = 187.96
    r921 = s.part("placard_std:R_US", "R22", 45.72, yr, R2("+5V", "DAC_5V"), value="2.2", footprint=FP_R, angle=90,
                  bare=("2",), ref_at=(41.9, yr - 1.6), value_at=(42.9, yr + 1.6))
    taps = []
    for ref, x, v, polar in (("C44", 60.96, "220u", True), ("C36", 78.74, "100n", False)):
        c = s.part("placard_std:C_Polarized" if polar else "placard_std:C", ref, x, yr + 3.81,
                   {"1": "DAC_5V", "2": "GNDA"}, value=v, footprint=FP_CP_S if polar else FP_C, bare=("1",),
                   ref_at=(x + 2.5, yr + 3.3), value_at=(x + 2.5, yr + 6.4))
        taps.append(c["1"][0])
    xf = 96.52
    vcc = u36["20"]
    pts = [r921["2"]] + [(x, yr) for x in taps] + [(xf, yr), (vcc[0], yr), vcc]
    for k in range(len(pts) - 1):
        path(s, "DAC_5V", pts[k], pts[k + 1])
    for x in taps:
        s.junction(x, yr, owner="DAC_5V")
    s.pwr_flag(xf, yr)
    s.named.add("DAC_5V")
    name(s, "DAC_5V", xf + 5.08, yr)
    # R-2R ladder: a 2k from each bit into its node, 1k between nodes, 2k from node 0 to GNDA
    xr2, xn, pitch = 185.42, 203.2, 10.16
    yk = [167.64 + k * pitch for k in range(8)]
    links = []
    for k in range(8):
        rp = s.part("placard_std:R_US", f"R{23 + k}", xr2, yk[k], {"1": f"DAC{k}", "2": f"LAD{k}"}, value="2k",
                    footprint=FP_R, angle=90, bare=("1", "2"), ref_at=(xr2 - 3.8, yk[k] - 1.3),
                    value_at=(xr2 - 1.5, yk[k] + 1.4))
        links.append((f"DAC{k}", u36[str(19 - k)], rp["1"]))
        path(s, f"LAD{k}", rp["2"], (xn, yk[k]))
        name(s, f"DAC{k}", rp["1"][0] - 11.43, yk[k])
    fan(s, links, 157.48)
    for k in range(7):
        yc = yk[k] + pitch / 2
        rp = s.part("placard_std:R_US", f"R{32 + k}", xn, yc, {"1": f"LAD{k}", "2": f"LAD{k + 1}"}, value="1k",
                    footprint=FP_R, bare=("1", "2"), ref_at=(xn + 2.0, yc - 0.3), value_at=(xn + 2.0, yc + 2.4))
        path(s, f"LAD{k}", (xn, yk[k]), rp["1"])
        path(s, f"LAD{k + 1}", rp["2"], (xn, yk[k + 1]))
    rp = s.part("placard_std:R_US", "R31", xn, yk[0] - 7.62, {"1": "GNDA", "2": "LAD0"}, value="2k", footprint=FP_R,
                bare=("2",), ref_at=(xn + 2.0, yk[0] - 7.9), value_at=(xn + 2.0, yk[0] - 5.3))
    path(s, "LAD0", rp["2"], (xn, yk[0]))
    # out: LAD7 -> C45 (15n to GNDA) -> C46 (22u ceramic) -> AUDIO -> R39 (10k to GNDA) -> J6 tip and ring
    yo = yk[7]
    c902 = s.part("placard_std:C", "C45", 220.98, yo + 3.81, {"1": "LAD7", "2": "GNDA"}, value="15n C0G",
                  footprint=FP_C, bare=("1",), ref_at=(223.5, yo + 3.3), value_at=(223.5, yo + 6.4))
    c903 = s.part("placard_std:C", "C46", 238.76, yo, {"1": "LAD7", "2": "AUDIO"}, value="22u",
                  footprint=FP_C, angle=90, bare=("1", "2"), ref_at=(234.5, yo - 3.4), value_at=(241.0, yo - 3.4))
    path(s, "LAD7", (xn, yo), c903["1"])
    s.junction(c902["1"][0], yo, owner="LAD7")     # C45's pin sits on the line: cut it there
    name(s, "LAD7", xn + 7.62, yo)
    r957 = s.part("placard_std:R_US", "R39", 256.54, yo + 3.81, {"1": "AUDIO", "2": "GNDA"}, value="10k",
                  footprint=FP_R, bare=("1",), ref_at=(259.0, yo + 3.3), value_at=(259.0, yo + 6.4))
    j6 = s.part("placard_std:AudioJack3", "J6", 281.94, yo + 2.54, {"T": "AUDIO", "R": "AUDIO", "S": "GNDA"},
                value="3.5 mm", ref_at=(278, yo - 6.5), value_at=(285, yo + 8.0), angle=180, bare=("T", "R"))
    path(s, "AUDIO", c903["2"], j6["T"])
    s.junction(r957["1"][0], yo, owner="AUDIO")
    xa = j6["T"][0] - 2.54
    path(s, "AUDIO", (xa, yo), (xa, j6["R"][1]), j6["R"])
    name(s, "AUDIO", r957["1"][0] + 2.54, yo)
    note(s, 15, 262, ["U23 Q3:Q2 = line repeat to U35 (sheet 8); Q1:Q0 = color mode.  DAC_5V: U36's own filtered rail (2.2 ohm, 220u, C36).",
                      "Ladder: 2k 1 % per bit + 2k termination, 1k between nodes (LAD7 = out).  AGND (GNDA) joins GND at the power input."],
         size=2.2)
    return s


def sheet_port(b):
    s = b.sheet("shared_port.kicad_sch", "Shared port", 10)
    heading(s, "Shared port x5200", "Keyboard, two SNES pads, SD card (SPI), PS/2 mouse")
    s.label_each |= {"D", "ROW"}
    # the port lines go to three corners of the sheet, so each pin carries its name
    s.label_nets |= {"~{PORT_RD}", "A0", "P_SCK", "P_MOSI", "P_CS", "P_PS2D", "PAD1_DATA", "PAD2_DATA"}
    # U37 latch -> K3:K0 straight into U38 -> /COL7:/COL0 straight into the keyboard header J1
    pq = ["P_SCK", "P_MOSI", "P_CS", "P_PS2D"]
    u37 = s.part("placard_std:74LS574", "U37", 63.5, 109.22, ls574(D, pq + ["K0", "K1", "K2", "K3"], "GND", "~{PORT_WR}"),
                 value="SN74HC574N", footprint=FP_DIP20, bare=("15", "14", "13", "12"))
    decap(s, 37, 43.18, 81.28, lift=0)
    u38 = s.part("placard:ATF22V10C_PORT", "U38", 144.78, 129.54, pld({
        1: "~{PORT_RD}", 2: "A0", 3: "K0", 4: "K1", 5: "K2", 6: "K3", 7: "PAD1_DATA", 8: "PAD2_DATA",
        14: "~{COL0}", 15: "~{COL1}", 16: "~{COL2}", 17: "~{COL3}", 18: "~{COL4}", 19: "~{COL5}",
        20: "~{COL6}", 21: "~{COL7}", 22: "D6", 23: "D7"}), bare=("3", "4", "5", "6") + tuple(str(n) for n in range(14, 22)))
    decap(s, 38, 165.1, 93.98, lift=0)
    kb = {str(1 + i): f"~{{COL{i}}}" for i in range(8)}
    kb.update({str(9 + i): f"ROW{i}" for i in range(8)})
    kb.update({"17": "+5V", "18": "GND", "19": "GND"})
    j1 = s.part("placard_parts:Keyboard_Header", "J1", 231.14, 129.54, kb, value="Keyboard (2x10 box)",
                bare=tuple(str(1 + i) for i in range(8)))
    for i in range(4):
        path(s, f"K{i}", u37[str(15 - i)], u38[str(3 + i)])
    for i in range(8):
        path(s, f"~{{COL{i}}}", u38[str(14 + i)], j1[str(1 + i)])
    # keyboard rows: U39 reads them, RN2 pulls them up; rows 5-7 also carry PS/2 and SD MISO
    s.part("placard_std:R_Network08_US", "RN2", 152.4, 205.74, {"1": "+5V", **{str(2 + i): f"ROW{i}" for i in range(8)}},
           value="4.7k", footprint=FP_SIP9, angle=270, ref_at=(160.02, 201.93), value_at=(160.02, 204.47))
    s.part("placard_std:74LS541", "U39", 76.2, 220.98, f541(bus("ROW", 8), D, "~{PORT_RD}", "A0"), value="SN74F541N",
           footprint=FP_DIP20)
    decap(s, 39, 96.52, 193.04, lift=0)
    vref = lambda x, y: dict(ref_at=(x + 2.0, y - 1.3), value_at=(x + 2.0, y + 1.5))
    href = lambda x, y: dict(ref_at=(x - 3.0, y - 3.2), value_at=(x - 3.0, y + 3.4))
    # PS/2 mouse: DATA along the top row, CLK along the bottom row, each with its row diode at the left,
    # pull-up and port diode above (P_PS2D and P_CS pull DATA and CLK low)
    for net, row, y, dref, rref, pref, pnet in [("PS2_DATA", "ROW6", 203.2, "D5", "R50", "D3", "P_PS2D"),
                                              ("PS2_CLK", "ROW5", 233.68, "D4", "R49", "D2", "P_CS")]:
        diode(s, dref, 229.87, y, net, row, angle=180, bare=("1",), **href(229.87, y))
        res(s, rref, 243.84, y - 3.81, "+5V", net, "4.7k", bare=("2",), **vref(243.84, y - 3.81))
        diode(s, pref, 261.62, y - 3.81, pnet, net, angle=270, bare=("2",), **vref(261.62, y - 3.81))
        pin = 215.9 if net == "PS2_DATA" else 220.98
        path(s, net, (233.68, y), (243.84, y), (261.62, y), (281.94, y), (281.94, pin), (289.56, pin))
        s.junction(243.84, y, owner=net)
        s.junction(261.62, y, owner=net)
    s.part("placard_std:Mini-DIN-6", "J5", 297.18, 218.44, {"1": "PS2_DATA", "2": None, "3": "GND", "4": "+5V",
                                                         "5": "PS2_CLK", "6": None}, value="PS/2 mouse",
           angle=180, bare=("1", "5"), ref_at=(292, 207.5), value_at=(292, 229.5))
    # SD card: 1.8k / 3.3k dividers bring SCK, MOSI and /CS down to 3.2 V; CS and DI come in from above,
    # CLK from below, MISO goes back down to row 7 through D1
    for src, net, y, rs, rp, pin, xv in [("P_CS", "SD_CS", 134.62, "R44", "R47", 162.56, 345.44),
                                         ("P_MOSI", "SD_DI", 152.4, "R43", "R46", 165.1, 342.9),
                                         ("P_SCK", "SD_CLK", 190.5, "R42", "R45", 172.72, 342.9)]:
        res(s, rs, 309.88, y, src, net, "1.8k", angle=90, bare=("2",), **href(309.88, y))
        res(s, rp, 322.58, y + 3.81, net, "GND", "3.3k", bare=("1",), **vref(322.58, y + 3.81))
        path(s, net, (313.69, y), (322.58, y), (xv, y), (xv, pin), (350.52, pin))
        s.junction(322.58, y, owner=net)
    s.part("placard_std:SD_Card", "J4", 373.38, 170.18, {"1": "SD_CS", "2": "SD_DI", "3": "GND", "4": "+3V3", "5": "SD_CLK",
                                                        "6": "GND", "7": "SD_MISO", "8": None, "9": None, "10": None,
                                                        "11": None, "12": "GND", "13": "GND"}, value="SD (SPI)",
           bare=("1", "2", "5", "7"), ref_at=(353, 153), value_at=(353, 187))
    path(s, "SD_MISO", (350.52, 177.8), (345.44, 177.8), (345.44, 213.36), (340.36, 213.36), (330.2, 213.36))
    s.junction(340.36, 213.36, owner="SD_MISO")
    res(s, "R48", 340.36, 209.55, "+3V3", "SD_MISO", "10k", bare=("2",), ref_at=(326.4, 206.0), value_at=(326.4, 206.6))
    diode(s, "D1", 330.2, 217.17, "SD_MISO", "ROW7", angle=270, bare=("1",), ref_at=(332.2, 218.4),
          value_at=(346.5, 215.4))
    # SNES pads, top right: CLOCK = P_SCK, LATCH = P_MOSI, DATA back to U38 with a pull-up
    for ref, y, data, rp in [("J2", 81.28, "PAD1_DATA", "R40"), ("J3", 121.92, "PAD2_DATA", "R41")]:
        s.part("placard_parts:SNES_Pad_Socket", ref, 388.62, y, {"1": "+5V", "2": "P_SCK", "3": "P_MOSI", "4": data,
                                                               "5": None, "6": None, "7": "GND"}, value="SNES pad",
               bare=("2", "3", "4"), value_at=(392.5, y + 17.0))
        for net, yy in [("P_SCK", y - 5.08), ("P_MOSI", y - 2.54)]:
            path(s, net, (373.38, yy), (358.14, yy))
            name(s, net, 358.14, yy, 180)
        res(s, rp, 330.2, y - 3.81, "+5V", data, "10k", bare=("2",), **vref(330.2, y - 3.81))
        path(s, data, (373.38, y), (330.2, y), (325.12, y))
        s.junction(330.2, y, owner=data)
        name(s, data, 325.12, y, 180)
    note(s, 15, 252, ["Latch Q0 = SCK and pad CLOCK, Q1 = MOSI and pad LATCH, Q2 = SD /CS (low also holds PS/2 CLK), Q3 = PS/2 DATA,",
                      "Q7:Q4 = key column.  SD lines come down to 3.2 V through 1.8k / 3.3k; MISO reaches row 7 through a Schottky."],
         size=2.2)
    return s


def sheet_slots(b):
    s = b.sheet("expansion.kicad_sch", "Expansion slots", 11)
    heading(s, "Expansion slots", "Four 2 x 20 card-edge slots, x5100-x53FF, 128 bytes each (EXPANSION.md)")
    s.label_nets |= {"RW", "~{LOAD_IMM}", "~{WE}", "CLK", "RUN", "~{EXP1}", "~{EXP2}"}
    for k in range(4):
        ref = f"J{9 + k}"
        x = 60 + k * 95
        n = {"A1": "GND", "A2": "+5V"}
        for i in range(8):
            n[["A3", "B3", "A4", "B4", "A5", "B5", "A6", "B6"][i]] = D[i]
            n[["A8", "B8", "A9", "B9", "A10", "B10", "A11", "B11"][i]] = SRC[i]
            n[["A13", "B13", "A14", "B14", "A15", "B15", "A16", "B16"][i]] = A[i]
        n.update({"A17": "~{EXP1}" if k in (0, 2) else "~{EXP2}", "B17": f"SEL{k + 1}", "A18": "RW",
                  "B18": "~{LOAD_IMM}", "A19": "~{WE}", "B12": "CLK", "B19": "RUN"})
        j = s.part("placard_parts:Expansion_Slot", ref, x, 110, n, value=f"Slot {k + 1}", ref_at=(x - 12, 78),
                   value_at=(x - 12, 142), bare=("B17",))
        # SEL: a 1k straight off the last pin to GND or +5V
        px, py = j["B17"]
        r = res(s, f"R{51 + k}", px + 7.62, py, f"SEL{k + 1}", "GND" if k < 2 else "+5V", "1k", angle=90, bare=("1",),
                ref_at=(px + 3.0, py + 5.5), value_at=(px + 3.0, py + 6.2))
        path(s, f"SEL{k + 1}", (px, py), r["1"])
    note(s, 30, 205, ["SEL: GND on slots 1 and 2, +5 V on slots 3 and 4 (through 1k): the A7 half the card answers.",
                      "/EXP1 goes to slots 1 and 3, /EXP2 to slots 2 and 4.  /RESET = RUN (low while the cartridge loads).",
                      "SD7:SD0 = SRC7:SRC0, the source drivers' side of the series resistors (the write data).",
                      "LOAD_IMM carries the State PLD's /LOAD_IMM (low when the CPU latches the read bus into D)."], size=2.5)
    return s


ROOT_BOXES = [  # (page, x, y, w, h)
    (2, 20, 50, 80, 35),
    (3, 115, 50, 80, 35),
    (4, 210, 50, 80, 35),
    (7, 305, 50, 95, 35),
    (5, 115, 105, 80, 35),
    (6, 210, 105, 80, 35),
    (8, 20, 105, 80, 35),
    (9, 20, 160, 80, 35),
    (10, 115, 160, 80, 35),
    (11, 305, 105, 95, 35),
]


def root_sheet(b, sheets):
    s = K.Sheet(b.project, "placard.kicad_sch", "Main board", 1, b.root_uuid, None, DATE)
    s.uid = b.root_uuid
    heading(s, "Placard main board", "Hierarchy: each box is one sheet; the sheets connect through global labels")
    boxes = []
    by_page = {sh.page: sh for sh in sheets}
    for page, x, y, w, h in ROOT_BOXES:
        sh = by_page[page]
        boxes.append(
            f"(sheet (at {x} {y}) (size {w} {h}) (fields_autoplaced) (stroke (width 0.3) (type solid)) "
            f"(fill (color 255 255 225 1.0000)) (uuid {sh.sheet_uuid}) "
            f"(property \"Sheetname\" {K.q(sh.title)} (at {x} {y - 0.8} 0) (effects (font (size 3 3) bold) (justify left bottom))) "
            f"(property \"Sheetfile\" {K.q(sh.filename)} (at {x} {y + h + 0.8} 0) (effects (font (size 2 2)) (justify left top))) "
            f"(instances (project {K.q(b.project)} (path \"/{b.root_uuid}\" (page {K.q(str(page))})))))")
    contents = {
        2: ["J13 USB-C, F1, U40 3.3 V", "X1 25.175 MHz clock", "STALL / RUN jumpers"],
        3: ["U1 State, U2 Branch", "U17 instruction register PLD"],
        4: ["U3, U4 program counter", "U7-U10 address mux"],
        7: ["U31, U32 RAM, J8 cartridge", "U11 memory control", "U12 I/O decode, U25 map"],
        5: ["U5, U6 ALU", "U19 AC, U20 X, U21 Y"],
        6: ["U18 D register", "U26, U27 source drivers", "R5-R12, RN1"],
        8: ["U13 H, U14 V counters", "U15 Sync, U35 audio slots", "U29 line read"],
        9: ["U22 pixel buffer, U23 line code", "U16 color decoder, VGA", "U36 audio DAC, J6"],
        10: ["U37 latch, U38 port PLD", "U39 rows, J1-J5"],
        11: ["J9-J12 card-edge slots"],
    }
    for page, x, y, w, h in ROOT_BOXES:
        for i, ln in enumerate(contents[page]):
            s.text(ln, x + 3, y + 10 + i * 7, size=2.5)
    note(s, 20, 220, ["34 chips + U40 regulator (docs/CHIPS.md numbers; U24, U28, U30, U33, U34 are not used).",
                      "Decoupling: every chip's 100 nF Cn sits beside Un on its own sheet.",
                      "Power: +5V, GND, +3V3 (SD card), GNDA (audio, joined to GND on sheet 2).",
                      "The ROM cartridge is its own project: kicad/cartridge/."], size=3)
    return s, "\n  ".join(boxes)


def build_main():
    root_uuid = K.det_uuid("placard", "root")
    b = Board("placard", root_uuid)
    sheets = [sheet_power(b), sheet_control(b), sheet_pc_mux(b), sheet_alu(b), sheet_databus(b),
              sheet_memory(b), sheet_video_timing(b), sheet_video_out(b), sheet_port(b), sheet_slots(b)]
    count = {}
    for sh in sheets:
        for net in sh.nets_here:
            count[net] = count.get(net, 0) + 1
    glob = {n for n, c in count.items() if c > 1}
    for sh in sheets:
        sh.finish(glob)
    root, boxes = root_sheet(b, sheets)
    return root, boxes, sheets, glob


def build_cart():
    root_uuid = K.det_uuid("cartridge", "root")
    s = K.Sheet("cartridge", "cartridge.kicad_sch", "ROM cartridge", 1, root_uuid, None, DATE)
    s.uid = root_uuid
    s.comment2 = "Cartridge chips U1-U5 (docs/CHIPS.md, ROM cartridge); decoupling Cn goes with Un"
    s.names = {"U1": "Loader PLD"}
    heading(s, "ROM cartridge", "Two EEPROMs copied into two SRAMs at power-up by the loader PLD (ROM.md, \"Loading the cartridge\")")
    cart = {"A3": "A0", "B3": "A1", "A4": "A2", "B4": "A3", "A5": "A4", "B5": "A5", "A6": "A6", "B6": "A7",
            "A7": "A8", "B7": "A9", "A8": "A10", "B8": "A11", "A9": "A12", "B9": "A13", "A10": "A14",
            "A16": "~{CE_LO}", "B16": "~{CE_HI}", "A17": "~{ROM_OE}", "B10": "GND",
            "A12": "D0", "B12": "D1", "A13": "D2", "B13": "D3", "A14": "D4", "B14": "D5", "A15": "D6", "B15": "D7",
            "A20": "CLK", "B17": "STALL_IN", "A18": "PIXEL_ENABLE", "B18": "STALL_OUT", "A19": "RUN",
            "B19": "PC_ENABLE",
            "A2": "+5V", "A1": "GND"}
    for c in ["A22", "A23", "A24", "A25", "A26", "A27", "A28", "A29", "A30", "A32", "B20",
              "B22", "B23", "B24", "B25", "B26", "B27", "B28", "B29", "B30", "B32"]:
        cart[c] = None
    s.label_each |= {"A"}
    s.label_nets |= {"~{CE_LO}", "~{CE_HI}", "~{CE_UP}", "~{ROM_OE}", "~{EE_OE}", "~{SR_WE}"}
    # the loader lines run straight across from the connector to U1, whose pins are a row apart like the connector's
    ld = {"A20": "1", "A18": "3", "B19": "4", "B17": "5", "B18": "23", "A19": "22"}
    j1 = s.part("placard_parts:Cartridge_Slot", "J1", 82.55, 120, cart, value="Card edge (87715-9106 mate)",
                footprint="", ref_at=(67, 69), value_at=(88, 176), bare=tuple(ld) + ("A16", "B16", "A17"))
    for c in ("A16", "B16", "A17"):     # labels in a column, not staggered
        path(s, cart[c], j1[c], (j1[c][0] - 5.08, j1[c][1]))
        name(s, cart[c], j1[c][0] - 5.08, j1[c][1], 180)
    u1 = s.part("placard:ATF22V10C_CART", "U1", 175.26, 134.62, pld({
        1: "CLK", 2: "~{CE_LO}", 3: "PIXEL_ENABLE", 4: "PC_ENABLE", 5: "STALL_IN", 14: None, 15: None,
        16: None, 17: None, 18: None, 21: None, 19: "~{SR_WE}", 20: "~{EE_OE}", 22: "RUN", 23: "STALL_OUT"}),
        bare=tuple(ld.values()))
    for c, n in ld.items():
        path(s, cart[c], j1[c], u1[n])
    decap(s, 1, 149.86, 86.36, lift=0)
    # power flags, each on a short arm of its own
    s.power("+5V", 160.02, 205.74)
    path(s, "+5V", (160.02, 205.74), (167.64, 205.74))
    s.pwr_flag(167.64, 205.74)
    s.pwr_flag(182.88, 205.74)
    path(s, "GND", (182.88, 205.74), (182.88, 210.82))
    s.power("GND", 182.88, 210.82)
    # D: one bus along the top, down the right of each column of chips; A: a labelled bus at each chip
    s.bus_piece("D", [(116.84, 43.18), (384.81, 43.18)])

    def mem(lib, ref, x, y, ce, oe, we, value, fp=None):
        n = {"20": ce, "22": oe, "27": we, "28": "+5V", "14": "GND"}
        for i, p in enumerate([10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2, 26, 1]):
            n[str(p)] = A[i]
        for i, p in enumerate([11, 12, 13, 15, 16, 17, 18, 19]):
            n[str(p)] = D[i]
        u = s.part(lib, ref, x, y, n, value=value, footprint=fp, bare=("20", "22", "27"))
        # /CE, /OE, /WE: labels in a column (not staggered), the tie to +5V on an arm past them
        for pn in ("20", "22", "27"):
            px, py = u[pn]
            if n[pn] == "+5V":
                path(s, "+5V", (px, py), (px - 19.05, py))
                s.power("+5V", px - 19.05, py, toward=(-1, 0))
            else:
                path(s, n[pn], (px, py), (px - 5.08, py))
                name(s, n[pn], px - 5.08, py, 180)
        decap(s, int(ref[1:]), x - 20.32, y - 38.1, lift=0)
    mem("Memory_EEPROM:28C256", "U2", 270.51, 95.25, "~{CE_LO}", "~{EE_OE}", "+5V", "AT28C256-15PU", FP_DIP28W)
    mem("Memory_EEPROM:28C256", "U3", 365.76, 95.25, "~{CE_UP}", "~{EE_OE}", "+5V", "AT28C256-15PU", FP_DIP28W)
    mem("placard_parts:AS7C256C", "U4", 267.97, 195.58, "~{CE_LO}", "~{ROM_OE}", "~{SR_WE}", "AS7C256C-15PCN")
    mem("placard_parts:AS7C256C", "U5", 363.22, 195.58, "~{CE_UP}", "~{ROM_OE}", "~{SR_WE}", "AS7C256C-15PCN")
    # ROM size: the upper pair's /CE.  1-2 (as made) = /CE_HI: the 64K cart used in development;
    # cut 1-2 and bridge 2-3 = GND: a 32K cart with U3, U5 only, seen in both halves
    s.part("Jumper:SolderJumper_3_Bridged12", "JP1", 175.26, 228.6,
           {"1": "~{CE_HI}", "2": "~{CE_UP}", "3": "GND"}, value="32K / 64K",
           footprint="Jumper:SolderJumper-3_P1.3mm_Bridged12_RoundedPad1.0x1.5mm_NumberLabels",
           ref_at=(170, 220), value_at=(185, 220))
    note(s, 22, 192, ["U2 (lower 32K) and U3 (upper) hold the image,",
                       "programmed off the board; their /WE is tied high.",
                       "U4, U5 are the ROM the CPU reads (15 ns).",
                       "/CE_LO is the main board's A15.",
                       "JP1 64K (as made, 1-2): fit U2-U5.  32K: cut",
                       "1-2, bridge 2-3, fit U3, U5 only; the 32K reads",
                       "in both halves.",
                       "U1 stalls the CPU at each PC address",
                       "(STALL_OUT), pulses /SR_WE, lets the CPU",
                       "step, and raises RUN when the PC wraps.",
                       "/CART (B10) is tied to GND: cartridge present.",
                       "Spare contacts are unassigned (EXPANSION.md)."])
    s.finish(set())
    return s


# the keyboard: (legend, keycap size) by column and row, as docs/IO.md "Planned layout: 63 keys";
# None = the spare place (column 7 row 4)
KEYS = [
    [("Esc", "1.00"), ("1 !", "1.00"), ("2 @", "1.00"), ("3 #", "1.00"), ("4 $", "1.00"), ("5 %", "1.00"), ("6 ^", "1.00"), ("7 &", "1.00")],
    [("8 *", "1.00"), ("9 (", "1.00"), ("0 )", "1.00"), ("- _", "1.00"), ("= +", "1.00"), ("Bksp", "2.00"), ("Tab", "1.50"), ("Q", "1.00")],
    [("W", "1.00"), ("E", "1.00"), ("R", "1.00"), ("T", "1.00"), ("Y", "1.00"), ("U", "1.00"), ("I", "1.00"), ("O", "1.00")],
    [("P", "1.00"), ("[ {", "1.00"), ("] }", "1.00"), ("\\ |", "1.50"), ("LCtrl", "1.25"), ("A", "1.00"), ("S", "1.00"), ("D", "1.00")],
    [("F", "1.00"), ("G", "1.00"), ("H", "1.00"), ("J", "1.00"), ("K", "1.00"), ("L", "1.00"), ("; :", "1.00"), ("' \"", "1.00")],
    [("Enter", "2.25"), ("LShift", "2.25"), ("Z", "1.00"), ("X", "1.00"), ("C", "1.00"), ("V", "1.00"), ("B", "1.00"), ("N", "1.00")],
    [("M", "1.00"), (", <", "1.00"), (". >", "1.00"), ("/ ?", "1.00"), ("RShift", "1.75"), ("Up", "1.00"), ("Caps", "1.75"), ("Fn", "1.25")],
    [("RAlt", "1.00"), ("LAlt", "1.25"), ("Space", "6.25"), ("RCtrl", "1.00"), None, ("Left", "1.00"), ("Down", "1.00"), ("Right", "1.00")],
]


def build_keyboard():
    """The keyboard board: 63 Cherry MX switches in the 8 x 8 matrix, each with its Schottky diode
    (cathode toward the column) and an always-on LED with its resistor.  Drawn as the matrix:
    a ROW line along the top of each row of keys, a /COL line down the right of each column, a
    +5V rail under each row for the LEDs.  Keys are numbered from 1 in reading order (row by row,
    left to right); SWn, Dn and Rn belong to the same key."""
    root_uuid = K.det_uuid("keyboard", "root")
    s = K.Sheet("keyboard", "keyboard.kicad_sch", "Keyboard", 1, root_uuid, None, DATE)
    s.uid = root_uuid
    s.comment2 = "Key n = SWn, Dn, Rn, numbered row by row; LED and resistor optional"
    heading(s, "Keyboard", "63 Cherry MX keys, 8 x 8 matrix with a diode per key, optional always-on LED per key")
    s.label_nets |= {f"ROW{i}" for i in range(8)} | {f"~{{COL{i}}}" for i in range(8)}
    x0, y0, cw, ch = 80.01, 48.26, 40.64, 25.4
    key = 0
    for r in range(8):
        cy = y0 + r * ch
        rail = cy + 20.32
        a_last = None
        for c in range(8):
            cx = x0 + c * cw
            sx, sy = cx + 20.32, cy + 7.62
            k = KEYS[c][r]
            if k is None:
                s.text("spare", sx - 5.08, sy + 1.27, size=2.0)
                continue
            legend, size = k
            n = f"{c}{r}"
            key += 1
            fp = f"placard:SW_Cherry_MX_LED_{size}u_PCB"
            sw = s.part("Switch:SW_Push_LED", f"SW{key}", sx, sy, {"1": f"ROW{r}", "2": f"K1{n}", "3": "GND", "4": f"LA1{n}"},
                        value=legend, footprint=fp, bare=("1", "2", "3", "4"),
                        ref_at=(cx + 1.27, sy - 0.25), value_at=(cx + 1.27, sy + 0.75))
            d = s.part("placard_std:D_Schottky", f"D{key}", sx + 11.43, cy + 5.08, {"1": f"~{{COL{c}}}", "2": f"K1{n}"},
                       value="BAT85", footprint=FP_D, angle=180, bare=("1", "2"), hide_value=True,
                       ref_at=(sx + 7.0, cy + 3.3), value_at=(sx + 7.0, cy + 6.5))
            rr = s.part("placard_std:R_US", f"R{key}", sx + 5.08, sy + 6.35, {"1": f"LA1{n}", "2": "+5V"},
                        value="1k", footprint=FP_R, bare=("1", "2"), hide_value=True,
                        ref_at=(sx + 7.0, sy + 7.6), value_at=(sx + 7.0, sy + 9.0))
            # the switch: ROW above, diode to the /COL line on the right
            path(s, f"ROW{r}", sw["1"], (sw["1"][0], cy))
            s.junction(sw["1"][0], cy, owner=f"ROW{r}")
            path(s, f"K1{n}", sw["2"], d["2"])
            colx = cx + 38.1
            last = all(KEYS[c][rr_] is None for rr_ in range(r + 1, 8))
            path(s, f"~{{COL{c}}}", d["1"], (colx, cy + 5.08))
            if not last:
                s.junction(colx, cy + 5.08, owner=f"~{{COL{c}}}")
            # the LED: cathode to GND, anode through the resistor down to the row's +5V rail
            path(s, "GND", sw["3"], (sw["3"][0], sy + 2.54))
            s.power("GND", sw["3"][0], sy + 2.54)
            path(s, f"LA1{n}", sw["4"], rr["1"])
            path(s, "+5V", rr["2"], (rr["2"][0], rail))
            a_last = rr["2"][0]
            if c < 7 and any(KEYS[cc][r] is not None for cc in range(c + 1, 8)):
                s.junction(rr["2"][0], rail, owner="+5V")
        path(s, "+5V", (x0 + 2.54, rail), (a_last, rail))
        s.power("+5V", x0 + 2.54, rail)
        # rows: one line across, named at the left
        path(s, f"ROW{r}", (x0, cy), (x0 + 7 * cw + 15.24, cy))
        name(s, f"ROW{r}", x0, cy, 180)
    # columns: one line down, named at the top
    for c in range(8):
        colx = x0 + c * cw + 38.1
        lastr = max(r for r in range(8) if KEYS[c][r] is not None)
        path(s, f"~{{COL{c}}}", (colx, y0 - 7.62), (colx, y0 + lastr * ch + 5.08))
        name(s, f"~{{COL{c}}}", colx, y0 - 7.62, 90)
    # the connector to the main board, and its power flags
    kb = {str(1 + i): f"~{{COL{i}}}" for i in range(8)}
    kb.update({str(9 + i): f"ROW{i}" for i in range(8)})
    kb.update({"17": "+5V", "18": "GND", "19": "GND"})
    j1 = s.part("placard_parts:Keyboard_Header", "J1", 48.26, 135.89, kb, value="To main board J1",
                bare=tuple(str(i) for i in range(1, 17)))
    for i in range(1, 17):      # the matrix lines leave J1 by name (the rows are not drawn as a bus here)
        px, py = j1[str(i)]
        path(s, kb[str(i)], (px, py), (px - 5.08, py))
        name(s, kb[str(i)], px - 5.08, py, 180)
    s.power("+5V", 30.48, 205.74)
    path(s, "+5V", (30.48, 205.74), (38.1, 205.74))
    s.pwr_flag(38.1, 205.74)
    s.pwr_flag(53.34, 205.74)
    path(s, "GND", (53.34, 205.74), (53.34, 210.82))
    s.power("GND", 53.34, 210.82)
    note(s, 15, 222, ["J1: 2 x 10 keyed box header,",
                      "ribbon to main board J1",
                      "(same pinout both ends).",
                      "SW: Cherry MX, PCB mount,",
                      "footprint by keycap size.",
                      "D: BAT85, cathode to /COL.",
                      "LED: 3 mm, always on, optional",
                      "(fit with its R).  R: 1k."], size=2.0)
    s.finish(set())
    return s


# nets that carry a PWR_FLAG (the netlist leaves the flags out)
FLAGGED = {"+5V", "GND", "GNDA", "DAC_5V", "+3V3"}

# ---------------------------------------------------------------- write + check
def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def expected_nets(sheets, glob):
    exp = {}
    for sh in sheets:
        for ref, pin, net in sh.pin_nets:
            if net is None:
                continue
            exp.setdefault(net, set()).add((ref, pin))
    return exp


def kicad_nets(sch):
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "n.xml")
        subprocess.run(["kicad-cli", "sch", "export", "netlist", "--format", "kicadxml", "-o", out, sch],
                       check=True, capture_output=True)
        xml = open(out).read()
    nets = {}
    for m in re.finditer(r'<net code="\d+" name="([^"]*)"[^>]*>(.*?)</net>', xml, re.S):
        name = m.group(1).replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
        nodes = set(re.findall(r'<node ref="([^"]+)" pin="([^"]+)"', m.group(2)))
        nets[name] = nodes
    return nets


def compare(exp, got, label):
    # map each expected net to the KiCad net holding its first pin
    pin2net = {}
    for name, nodes in got.items():
        for n in nodes:
            pin2net[n] = name
    bad = 0
    for net, pins in sorted(exp.items()):
        names = {pin2net.get(p) for p in pins}
        if len(names) != 1 or None in names:
            print(f"  {label}: net {net} is split: {sorted(names, key=str)}")
            bad += 1
            continue
        kn = names.pop()
        extra = {p for p in got[kn] if not p[0].startswith("#")} - pins
        if extra:
            print(f"  {label}: net {net} ({kn}) also has {sorted(extra)}")
            bad += 1
    print(f"{label}: {len(exp)} nets checked, {bad} problems")
    return bad


def erc(sch, label, flagged):
    """Electrical checks on the exported netlist (kicad-cli 7 has no ERC)."""
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "n.xml")
        subprocess.run(["kicad-cli", "sch", "export", "netlist", "--format", "kicadxml", "-o", out, sch],
                       check=True, capture_output=True)
        xml = open(out).read()
    probs = []
    for m in re.finditer(r'<net code="\d+" name="([^"]*)"[^>]*>(.*?)</net>', xml, re.S):
        name = m.group(1)
        nodes = re.findall(r'<node ref="([^"]+)" pin="([^"]+)"[^>]*?pintype="([^"]+)"', m.group(2))
        real = [n for n in nodes if not n[0].startswith("#")]
        types = [n[2].split("+")[0] for n in nodes]
        if len(real) < 2 and not name.startswith("unconnected"):
            probs.append(f"{name}: only {real}")
        outs = [n for n in nodes if n[2] == "output"]
        if len(outs) > 1:
            probs.append(f"{name}: {len(outs)} outputs {outs}")
        if outs and any(t in ("tri_state", "bidirectional") for t in types) and name not in ("D6", "D7"):
            probs.append(f"{name}: output and 3-state drivers {nodes}")
        drivers = [t for t in types if t in ("output", "tri_state", "bidirectional", "passive", "power_out", "open_collector")]
        if any(t == "input" for t in types) and not drivers and not name.startswith("unconnected"):
            probs.append(f"{name}: inputs with no driver")
        if any(t == "power_in" for t in types) and not any(t in ("power_out",) for t in types):
            if name.split("/")[-1] not in flagged:
                probs.append(f"{name}: power input with no source or PWR_FLAG")
    print(f"{label} checks: {len(probs)} problems")
    return probs


def export_pdf(sch, pdf):
    """kicad-cli's PDF, set to open without the bookmarks panel (Justin, 2026-10-21):
    the outline is dropped and the page mode is UseNone."""
    import pypdf
    subprocess.run(["kicad-cli", "sch", "export", "pdf", "-o", pdf, sch], check=True, capture_output=True)
    w = pypdf.PdfWriter(clone_from=pdf)
    root = w._root_object
    for k in ("/Outlines", "/PageMode"):
        if k in root:
            del root[k]
    w.page_mode = "/UseNone"
    with open(pdf, "wb") as f:
        w.write(f)


def check_refs(sheets, label):
    """References count up from 1 for each kind of part (Justin, 2026-10-22): no gaps, no
    hundreds.  U and J keep the CHIPS.md / IO.md numbers, and C1-C40 go with their chips,
    so the other capacitors start at C41."""
    got = {}
    for sh in sheets:
        for ref, _num, _net in sh.pin_nets:
            m = re.match(r"([A-Z]+)(\d+)$", ref)
            if m and m.group(1) not in ("U", "J"):
                got.setdefault(m.group(1), set()).add(int(m.group(2)))
    out = []
    for pre, nums in sorted(got.items()):
        if pre == "C":
            nums = {n for n in nums if n > 40} or nums
        first = 41 if pre == "C" and min(nums) > 40 else 1
        if nums != set(range(first, first + len(nums))):
            out.append(f"{label}: {pre} numbers are not {pre}{first}-{pre}{first + len(nums) - 1}: {sorted(nums)}")
    return out


def main():
    root, boxes, sheets, glob = build_main()
    for sh in sheets:
        write(os.path.join(KDIR, sh.filename), sh.render())
        for o in sh.overlaps():
            print("overlap", sh.filename, o)
        for r in sh.report:
            print("route", sh.filename, r)
    write(os.path.join(KDIR, "placard.kicad_sch"), root.render(extra=boxes))
    cart = build_cart()
    write(os.path.join(CDIR, "cartridge.kicad_sch"), cart.render())
    for o in cart.overlaps():
        print("overlap cartridge", o)
    for r in cart.report:
        print("route cartridge", r)
    kbd = build_keyboard()
    write(os.path.join(BDIR, "keyboard.kicad_sch"), kbd.render())
    for o in kbd.overlaps():
        print("overlap keyboard", o)
    for r in kbd.report:
        print("route keyboard", r)
    if "--pdf" in sys.argv:
        export_pdf(os.path.join(BDIR, "keyboard.kicad_sch"), os.path.join(ROOT, "schematics", "placard_keyboard.pdf"))
        export_pdf(os.path.join(KDIR, "placard.kicad_sch"), os.path.join(ROOT, "schematics", "placard_main.pdf"))
        export_pdf(os.path.join(CDIR, "cartridge.kicad_sch"), os.path.join(ROOT, "schematics", "placard_cartridge.pdf"))
    if "--check" in sys.argv:
        bad = compare(expected_nets(sheets, glob), kicad_nets(os.path.join(KDIR, "placard.kicad_sch")), "main board")
        bad += compare(expected_nets([cart], set()), kicad_nets(os.path.join(CDIR, "cartridge.kicad_sch")), "cartridge")
        bad += compare(expected_nets([kbd], set()), kicad_nets(os.path.join(BDIR, "keyboard.kicad_sch")), "keyboard")
        for path, label in [(os.path.join(KDIR, "placard.kicad_sch"), "main board"),
                            (os.path.join(CDIR, "cartridge.kicad_sch"), "cartridge"),
                            (os.path.join(BDIR, "keyboard.kicad_sch"), "keyboard")]:
            for it in erc(path, label, FLAGGED):
                print("  ", it)
        for shs, label in [(sheets, "main board"), ([cart], "cartridge"), ([kbd], "keyboard")]:
            for it in check_refs(shs, label):
                print("  ", it)
                bad += 1
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
