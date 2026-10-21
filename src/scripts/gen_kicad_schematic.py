#!/usr/bin/env python3
"""Write the Placard KiCad schematic: kicad/*.kicad_sch (main board, root plus
ten sheets) and kicad/cartridge/ (the ROM cartridge, one sheet).

The sheet split follows docs/SCHEMATIC_PLAN.md.  The connections follow the
PLD pin lists (src/pld/*.pld), basys_top.vhd and the docs (CHIPS.md, IO.md,
SOUND.md, COLORS.md, EXPANSION.md, ROM.md).  Every pin of every part is listed
here with its net, so a pin left out stops the script.

Nets with several pins on a sheet are wired (kicad_route.py), numbered groups
are drawn as buses, nets that run between sheets get global labels, each chip has its decoupling capacitor Cn beside it (n = the
chip's U number), and the text is large.  Rerun after a pin or part change:

    python3 src/scripts/gen_kicad_schematic.py [--pdf] [--check]

--pdf exports schematics/placard_main.pdf and placard_cartridge.pdf, set to
open without the bookmarks panel.

--check exports the netlist with kicad-cli and compares it with the nets
listed here, then runs the ERC.

Date: 2026-10-21
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kicad_sch_lib as K  # noqa: E402

DATE = "2026-10-21"
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
KDIR = os.path.join(ROOT, "kicad")
CDIR = os.path.join(KDIR, "cartridge")

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


def res(s, ref, x, y, a, b, value, angle=0, fp=FP_R):
    # angle 0: pin 1 on top; 90: pin 1 on the left
    s.part("placard_std:R", ref, x, y, R2(a, b), value=value, footprint=fp, angle=angle,
           ref_at=(x + 2.0, y - 0.5) if angle == 0 else (x - 3.5, y - 1.6),
           value_at=(x + 2.0, y + 2.6) if angle == 0 else (x - 3.5, y + 1.6))


def cap(s, ref, x, y, a, b, value, polar=False, angle=0, fp=None):
    s.part("placard_std:C_Polarized" if polar else "placard_std:C", ref, x, y, R2(a, b), value=value,
           footprint=fp or (FP_CP_S if polar else FP_C), angle=angle,
           ref_at=(x + 2.5, y - 0.5) if angle == 0 else (x - 3.5, y - 2.4),
           value_at=(x + 2.5, y + 2.6) if angle == 0 else (x - 3.5, y + 2.4))


def diode(s, ref, x, y, k, a, angle=0, value="BAT85"):
    s.part("placard_std:D_Schottky", ref, x, y, {"1": k, "2": a}, value=value, footprint=FP_D, angle=angle,
           ref_at=(x - 3.5, y - 1.8), value_at=(x - 3.5, y + 1.8))


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
    # USB-C input
    s.part("placard_parts:USB_C_Power", "J13", 50, 80,
           {"A9": "VBUS", "A5": "CC1", "B5": "CC2", "A12": "GND", "S1": "GND"}, stub=5.08,
           ref_at=(36, 68), value_at=(36, 92))
    res(s, "R201", 95, 100, "CC1", "GND", "5.1k")
    res(s, "R202", 110, 100, "CC2", "GND", "5.1k")
    s.part("placard_std:Polyfuse", "F201", 130, 66, {"1": "VBUS", "2": "+5V"}, value="3 A hold",
           footprint="Fuse:Fuse_Bourns_MF-RG300", angle=90, ref_at=(126, 61), value_at=(126, 72.5))
    cap(s, "C201", 160, 80, "+5V", "GND", "220u 10V", polar=True, fp=FP_CP_L)
    s.pwr_flag(175, 66)
    s.power("+5V", 175, 66)
    s.pwr_flag(175, 96)
    s.power("GND", 175, 96)
    note(s, 30, 120, ["5.1k on CC1 and CC2: a USB-C source gives 5 V.",
                      "19 PLDs draw up to about 2.5 A (130 mA each at -7, worst case):",
                      "use a 3 A supply; the polyfuse trips on a short."])
    # analog ground joins logic ground at the power input
    s.part("placard_std:NetTie_2", "NT201", 210, 80, {"1": "GND", "2": "GNDA"}, value="AGND tie",
           footprint="NetTie:NetTie-2_THT_Pad0.3mm", ref_at=(206, 74), value_at=(206, 86))
    s.pwr_flag(234, 92)
    s.power("GNDA", 234, 92)
    note(s, 196, 100, ["AGND (audio) meets GND", "here, at the power input"])
    # 3.3 V regulator
    s.part("placard_std:MCP1700x-330xxTO", "U40", 300, 80, {"1": "GND", "2": "+5V", "3": "+3V3"},
           value="MCP1700-3302E/TO", ref_at=(292, 72), value_at=(292, 88))
    cap(s, "C40", 280, 104, "+5V", "GND", "1u")
    cap(s, "C202", 322, 104, "+3V3", "GND", "1u")
    s.pwr_flag(345, 112)
    s.power("+3V3", 345, 112)
    note(s, 268, 126, ["U40: 3.3 V for the SD card only (sheet 10).", "C40 input, C202 output (1 uF ceramic)."])
    # oscillator, and the cartridge's STALL and RUN
    s.part("placard_std:ACO-xxxMHz", "X1", 60, 185, {"14": "+5V", "7": "GND", "8": "CLK"},
           value="25.175 MHz", footprint="Oscillator:Oscillator_DIP-14", ref_at=(52, 175), value_at=(52, 196))
    decap(s, 203, 80, 172, lift=0)
    res(s, "R203", 150, 160, "+5V", "STALL_OUT", "10k")
    res(s, "R204", 290, 200, "RUN", "GND", "10k")
    s.part("placard_std:Jumper_2_Open", "JP201", 150, 215, {"1": "STALL_IN", "2": "STALL_OUT"}, value="STALL",
           footprint=FP_JP, ref_at=(143, 209), value_at=(143, 220))
    s.part("placard_std:Jumper_2_Open", "JP202", 320, 175, {"1": "RUN", "2": "+5V"}, value="RUN",
           footprint=FP_JP, ref_at=(313, 169), value_at=(313, 180))
    note(s, 200, 222, ["STALL_OUT (10k up) and RUN (10k down) come from the",
                       "cartridge: STALL_IN (the Branch PLD's STALL) goes out to it.",
                       "Without one, fit JP201 and JP202 for bring-up",
                       "(BRINGUP.md); take them out with a cartridge."])
    return s


def sheet_control(b):
    s = b.sheet("control.kicad_sch", "Control", 3)
    heading(s, "Control", "State and Branch PLDs, instruction register")
    s.part("placard:ATF22V10C_IR", "U17", 72, 130, pld({
        1: "CLK", 2: "D0", 3: "D1", 4: "D2", 5: "D3", 6: "D4", 7: "D5", 8: "D6", 9: "D7",
        10: "~{LOAD_INSTR}", 11: "RUN", 14: "I0", 15: "I1", 16: "I2", 17: "I3", 18: "I4", 19: "I5",
        20: "I6", 21: "I7"}))
    decap(s, 17, 92, 98)
    s.part("placard:ATF22V10C_STATE", "U1", 190, 130, pld({
        1: "CLK", 2: "STALL_OUT", 3: "D1", 4: "D0", 5: "I4", 6: "I3", 7: "I2", 8: "BRANCH_BLOCK",
        9: "D3", 10: "D2", 11: "D4", 13: "I0", 18: "Q0", 15: "PC_ENABLE", 16: "X_ENABLE", 17: "Y_ENABLE",
        14: "~{LOAD_INSTR}", 19: "~{LOAD_IMM}", 20: "~{LOAD_X}", 21: "~{LOAD_Y}", 22: "~{LOAD_AC}", 23: "RW"}))
    decap(s, 1, 210, 98)
    s.part("placard:ATF22V10C_BRANCH", "U2", 322, 130, pld({
        1: "CLK", 17: "I7", 2: "I6", 3: "I5", 4: "I4", 5: "I3", 6: "I2", 7: "Z_LOW", 8: "AC7",
        9: "PIXEL_ENABLE", 10: "Q0", 11: "PC_ENABLE", 13: "Z_HIGH", 14: "COUT",
        21: "LOAD_PC_LOW", 22: "LOAD_PC_HIGH", 23: "BRANCH_BLOCK", 18: None, 19: "STALL_IN",
        16: "~{SRC_EN}", 20: None, 15: "~{PIX_LD}"}))
    decap(s, 2, 342, 98)
    note(s, 40, 205, ["U17 loads the opcode in FETCH (/LOAD_INSTR) and holds 02h while RUN is low.",
                      "U2's STALL (STALL_IN) goes to the cartridge; STALL_OUT comes back to U1 and the PC.",
                      "U1 State: FETCH / LOAD / EXEC, register loads (active low, F377 /E), RW (1 = read).",
                      "U2 Branch: NEG is AC7.  ALU_DONE (18) and CARRY (20) are internal registers: no connection.",
                      "Bring-up straps S1-S3 go in U1's socket (BRINGUP.md), not on the board."])
    return s


def sheet_pc_mux(b):
    s = b.sheet("pc_mux.kicad_sch", "Program counter and address mux", 4)
    heading(s, "Program counter and address mux", "Mux inputs: A = D / 0, B = X / Y, C = video address, D = PC")
    s.part("placard:ATF22V10C_PC_COUNTER8", "U3", 95, 95, pc_counter(D, "LOAD_PC_LOW", "+5V", PC[0:8], "PC_CO"))
    decap(s, 3, 115, 63)
    s.part("placard:ATF22V10C_PC_COUNTER8", "U4", 95, 200, pc_counter(Y, "LOAD_PC_HIGH", "PC_CO", PC[8:16], None))
    decap(s, 4, 115, 168)
    for ref, x, y, nib, lo in [("U7", 225, 95, 0, True), ("U8", 345, 95, 1, True),
                               ("U9", 225, 200, 2, False), ("U10", 345, 200, 3, False)]:
        bits = range(nib * 4, nib * 4 + 4)
        if lo:
            n = quad_mux([DR[i] for i in bits], [X[i] for i in bits], [VA[i] for i in bits], [PC[i] for i in bits],
                         "ADDR_SEL_LO", "ADDR_SEL", [A[i] for i in bits])
        else:
            n = quad_mux(["GND"] * 4, [Y[i - 8] for i in bits], [VA[i] for i in bits], [PC[i] for i in bits],
                         "ADDR_SEL_HI", "ADDR_SEL", [A[i] for i in bits])
        s.part("placard:ATF22V10C_QUAD_MUX", ref, x, y, n)
        decap(s, int(ref[1:]), x + 20, y - 32)
    note(s, 20, 252, ["Video address: VA0, VA1, VA7, VA8 from the audio slot PLD (line repeat), A6:A2 = V6:V2, A15:A9 = H9:H3.",
                      "U3 CIN tied high (always counts); U3 CO carries into U4.  STALL_OUT holds the PC (video reads, ALU wait, cartridge load)."],
         size=2.2)
    return s


def sheet_alu(b):
    s = b.sheet("alu_regs.kicad_sch", "ALU and registers", 5)
    heading(s, "ALU and registers", "Two 4-bit ALU PLDs; F7:F0 loads AC, X or Y")
    s.part("placard:ATF22V10C_ALU_SHR", "U5", 75, 95, alu(AC[0:4], D[0:4], "GND", "AC4", F[0:4], "ALU_C3", "Z_LOW"))
    decap(s, 5, 95, 63)
    s.part("placard:ATF22V10C_ALU_SHR", "U6", 75, 200, alu(AC[4:8], D[4:8], "ALU_C3", "GND", F[4:8], "COUT", "Z_HIGH"))
    decap(s, 6, 95, 168)
    s.part("placard_std:74LS377", "U19", 205, 95, f377(F, AC, "~{LOAD_AC}"), value="SN74F377AN", footprint=FP_DIP20)
    decap(s, 19, 225, 66)
    s.part("placard_std:74LS377", "U20", 325, 95, f377(F, X, "~{LOAD_X}"), value="SN74F377AN", footprint=FP_DIP20)
    decap(s, 20, 345, 66)
    s.part("placard_std:74LS377", "U21", 205, 200, f377(F, Y, "~{LOAD_Y}"), value="SN74F377AN", footprint=FP_DIP20)
    decap(s, 21, 225, 171)
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
    s.part("placard_std:74LS377", "U18", 70, 105, f377(D, DR, "~{LOAD_IMM}"), value="SN74F377AN", footprint=FP_DIP20)
    decap(s, 18, 90, 76)
    s.part("placard_std:74LS541", "U26", 190, 105, f541(DR, SRC, "~{SRC_EN}", "I1"), value="SN74F541N", footprint=FP_DIP20)
    decap(s, 26, 210, 76)
    s.part("placard_std:74LS541", "U27", 190, 200, f541(AC, SRC, "~{SRC_EN}", "~{AC_SEL}"), value="SN74F541N", footprint=FP_DIP20)
    decap(s, 27, 210, 171)
    for i in range(8):
        res(s, f"R{601 + i}", 290, 80 + i * 14, SRC[i], D[i], "47", angle=90)
    s.part("placard_std:R_Network08", "RN601", 360, 105, {"1": "+5V", **{str(2 + i): D[i] for i in range(8)}},
           value="10k", footprint=FP_SIP9, ref_at=(352, 96), value_at=(352, 114))
    note(s, 250, 205, ["SRC7:SRC0: the two source F541s' joined outputs.",
                       "R601-R608 (47 ohm) limit the current while the",
                       "bus changes hands at the start of EXEC (CPU.md).",
                       "U26 drives D (sources 00, 01: /OE2 = I1),",
                       "U27 drives AC (10, 11: /OE2 = /AC_SEL).",
                       "RN601: D7:D0 read FFh when nothing drives them",
                       "(empty slots, the cartridge loader's feed byte)."])
    return s


def sheet_memory(b):
    s = b.sheet("memory.kicad_sch", "Memory and I/O decode", 7)
    heading(s, "Memory and I/O decode", "RAM, ROM cartridge slot, memory control, I/O decode, map register")
    s.part("placard:ATF22V10C_MEM_CTRL", "U11", 100, 95, pld({
        1: "CLK", 2: "A15", 3: "A14", 4: "A13", 5: "A12", 6: "RAMSEL0", 7: "RAMSEL1", 8: "RAMSEL3",
        9: "RAMSEL4", 10: "RAMSEL5", 11: "RAMSEL6", 13: "RAMSEL7", 15: "RAMSEL2", 14: "RW",
        23: "PIXEL_ENABLE", 20: "A11", 21: "A10", 22: "~{SRC_EN}", 17: "RUN",
        16: "~{WE}", 19: "~{ROM_OE}", 18: "~{RAM_OE}"}))
    decap(s, 11, 120, 63)
    s.part("placard:ATF22V10C_IO_DECODE", "U12", 100, 205, pld({
        1: "~{WE}", 2: "ADDR_SEL", 3: "ADDR_SEL_HI", 4: "PC15", 5: "H9", 6: "Y7", 7: "A14", 8: "A13",
        9: "A12", 10: "A10", 11: "A9", 13: "A8", 14: "RW", 18: "A11", 23: "~{LOAD_IMM}",
        15: "~{CE_HI}", 16: "~{MAP_WR}", 17: "~{LINE_RD}", 19: "~{PORT_WR}", 20: "~{PORT_RD}",
        21: "~{EXP1}", 22: "~{EXP2}"}))
    decap(s, 12, 120, 173)
    s.part("placard_std:74LS273", "U25", 212, 95, ls273(D, RAMSEL, "RUN", "~{MAP_WR}"), value="CD74ACT273E", footprint=FP_DIP20)
    decap(s, 25, 232, 66)
    s.part("placard_parts:AS7C256C", "U31", 212, 205, sram("A15", "~{RAM_OE}", "~{WE}"), value="AS7C256C-15PCN")
    decap(s, 31, 232, 168)
    s.part("placard_parts:AS7C256C", "U32", 310, 205, sram("~{CE_HI}", "~{RAM_OE}", "~{WE}"), value="AS7C256C-15PCN")
    decap(s, 32, 330, 168)
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
    s.part("placard_parts:Cartridge_Slot", "J8", 337, 95, cart, value="Molex 87715-9106",
           ref_at=(322, 44), value_at=(322, 146))
    res(s, "R701", 395, 175, "+5V", "~{CART}", "10k")
    note(s, 20, 252, ["Lower 32K: /CE = A15 (RAM U31, cartridge /CE_LO); upper: /CE_HI from U12.",
                       "RUN low (cartridge loading): /ROM_OE held off, map register clear (all ROM).",
                       "/CART reads low with a cartridge in; nothing reads it yet.  21 spare contacts."],
         size=2.2)
    return s


def sheet_video_timing(b):
    s = b.sheet("video_timing.kicad_sch", "Video timing", 8)
    heading(s, "Video timing", "640 x 480 at 60 Hz: H and V counters, Sync, mode and audio slots, line read")
    s.part("placard:ATF22V10C_HCOUNT", "U13", 70, 95, pld({
        1: "CLK", 2: "GND", 3: "H0", 4: "H1", 5: "H2", 14: "H3", 15: "H4", 16: "H5", 17: "H6", 18: "H7",
        19: "H8", 20: "H9", 21: "~{HSYNC}", 22: "H_VIDEO_ACTIVE", 23: "H_TC"}))
    decap(s, 13, 90, 63)
    s.part("placard:ATF22V10C_VCOUNT", "U14", 70, 205, pld({
        1: "CLK", 2: "H_TC", 14: "V0", 23: "V1", 22: "V2", 15: "V3", 16: "V4", 21: "V5", 20: "V6",
        17: "V7", 18: "V8", 19: "V9"}))
    decap(s, 14, 90, 173)
    s.part("placard:ATF22V10C_SYNC", "U15", 195, 95, pld({
        1: "CLK", 2: "V9", 3: "V5", 4: "V4", 5: "V3", 6: "V2", 7: "V1", 8: "H_VIDEO_ACTIVE",
        9: "PC_ENABLE", 10: "Y_ENABLE", 11: "X_ENABLE", 13: "BLANK_RD", 14: "H0", 15: "H1", 16: "H2",
        17: "VIDEN", 18: "VSYNC", 19: "PIXEL_ENABLE", 20: "ADDR_SEL", 21: "ADDR_SEL_HI", 22: "ADDR_SEL_LO",
        23: None}))
    decap(s, 15, 215, 63)
    s.part("placard:ATF22V10C_AUDIO", "U35", 195, 205, pld({
        1: "V0", 2: "H9", 3: "H8", 4: "H7", 5: "H6", 6: "H5", 7: "H4", 8: "H3", 9: "V9", 10: "V1",
        11: "V7", 13: "V8", 14: "LC2", 15: "LC3", 16: "I1", 17: "VA0", 18: "VA1", 19: "VA7", 20: "VA8",
        22: "~{MODE_LD}", 23: "BLANK_RD", 21: "~{AC_SEL}"}))
    decap(s, 35, 215, 173)
    s.part("placard_std:74LS541", "U29", 340, 95, f541(V[2:10], D, "~{LINE_RD}", "GND"), value="SN74F541N", footprint=FP_DIP20)
    decap(s, 29, 360, 66)
    note(s, 285, 165, ["H2:H0 come from the Sync PLD (two clocks",
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
    u23 = s.part("placard_std:74LS377", "U23", 139.7, 152.4,
                 f377(PIX, ["LC0", "LC1", "LC2", "LC3", None, None, None, None], "~{MODE_LD}"),
                 value="SN74F377AN", footprint=FP_DIP20, bare=("2", "5"))
    decap(s, 23, 182.88, 156.21, lift=0)
    for k, xj in ((0, 154.94), (1, 157.48)):
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
        rp = s.part("placard_std:R", f"R{901 + i}", xr, yr, R2(net, color), value=v, footprint=FP_R, angle=90,
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
    # ---- audio: PIX -> U36 DAC register -> R-2R ladder -> C903 -> J6
    u36 = s.part("placard_std:74LS574", "U36", 139.7, 218.44,
                 ls574(PIX, bus("DAC", 8), "GNDA", "H_VIDEO_ACTIVE", vcc="DAC_5V", gnd="GNDA"),
                 value="SN74HCT574N", footprint=FP_DIP20, bare=tuple(str(19 - i) for i in range(8)))
    # U36's own filtered supply: +5V -> 2.2 ohm -> DAC_5V, 220u and 100n to GNDA
    res(s, "R921", 38.1, 190.5, "+5V", "DAC_5V", "2.2", angle=90)
    cap(s, "C901", 53.34, 198.12, "DAC_5V", "GNDA", "220u", polar=True)
    s.part("placard_std:C", "C36", 68.58, 198.12, {"1": "DAC_5V", "2": "GNDA"}, value="100n", footprint=FP_C,
           ref_at=(71.1, 197.6), value_at=(71.1, 200.7))
    flag(s, "DAC_5V", 81.28, 182.88)
    # R-2R ladder: a 2k from each bit into its node, 1k between nodes, 2k from node 0 to GNDA
    xr2, xn, pitch = 185.42, 203.2, 10.16
    yk = [167.64 + k * pitch for k in range(8)]
    links = []
    for k in range(8):
        rp = s.part("placard_std:R", f"R{940 + k}", xr2, yk[k], {"1": f"DAC{k}", "2": f"LAD{k}"}, value="2k",
                    footprint=FP_R, angle=90, bare=("1", "2"), ref_at=(xr2 - 3.8, yk[k] - 1.3),
                    value_at=(xr2 - 1.5, yk[k] + 1.4))
        links.append((f"DAC{k}", u36[str(19 - k)], rp["1"]))
        path(s, f"LAD{k}", rp["2"], (xn, yk[k]))
        name(s, f"DAC{k}", rp["1"][0] - 11.43, yk[k])
    fan(s, links, 157.48)
    for k in range(7):
        yc = yk[k] + pitch / 2
        rp = s.part("placard_std:R", f"R{950 + k}", xn, yc, {"1": f"LAD{k}", "2": f"LAD{k + 1}"}, value="1k",
                    footprint=FP_R, bare=("1", "2"), ref_at=(xn + 2.0, yc - 0.3), value_at=(xn + 2.0, yc + 2.4))
        path(s, f"LAD{k}", (xn, yk[k]), rp["1"])
        path(s, f"LAD{k + 1}", rp["2"], (xn, yk[k + 1]))
    rp = s.part("placard_std:R", "R948", xn, yk[0] - 7.62, {"1": "GNDA", "2": "LAD0"}, value="2k", footprint=FP_R,
                bare=("2",), ref_at=(xn + 2.0, yk[0] - 7.9), value_at=(xn + 2.0, yk[0] - 5.3))
    path(s, "LAD0", rp["2"], (xn, yk[0]))
    # out: LAD7 -> C902 (15n to GNDA) -> C903 (22u ceramic) -> AUDIO -> R957 (10k to GNDA) -> J6 tip and ring
    yo = yk[7]
    c902 = s.part("placard_std:C", "C902", 220.98, yo + 3.81, {"1": "LAD7", "2": "GNDA"}, value="15n C0G",
                  footprint=FP_C, bare=("1",), ref_at=(223.5, yo + 3.3), value_at=(223.5, yo + 6.4))
    c903 = s.part("placard_std:C", "C903", 238.76, yo, {"1": "LAD7", "2": "AUDIO"}, value="22u",
                  footprint=FP_C, angle=90, bare=("1", "2"), ref_at=(234.5, yo - 3.4), value_at=(241.0, yo - 3.4))
    path(s, "LAD7", (xn, yo), c903["1"])
    s.junction(c902["1"][0], yo, owner="LAD7")     # C902's pin sits on the line: cut it there
    name(s, "LAD7", xn + 7.62, yo)
    r957 = s.part("placard_std:R", "R957", 256.54, yo + 3.81, {"1": "AUDIO", "2": "GNDA"}, value="10k",
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
    s.part("placard_std:74LS574", "U37", 60, 95, ls574(D, ["P_SCK", "P_MOSI", "P_CS", "P_PS2D", "K0", "K1", "K2", "K3"],
                                                 "GND", "~{PORT_WR}"), value="SN74HC574N", footprint=FP_DIP20)
    decap(s, 37, 80, 66)
    s.part("placard:ATF22V10C_PORT", "U38", 170, 95, pld({
        1: "~{PORT_RD}", 2: "A0", 3: "K0", 4: "K1", 5: "K2", 6: "K3", 7: "PAD1_DATA", 8: "PAD2_DATA",
        14: "~{COL0}", 15: "~{COL1}", 16: "~{COL2}", 17: "~{COL3}", 18: "~{COL4}", 19: "~{COL5}",
        20: "~{COL6}", 21: "~{COL7}", 22: "D6", 23: "D7"}))
    decap(s, 38, 190, 63)
    s.part("placard_std:74LS541", "U39", 60, 200, f541(bus("ROW", 8), D, "~{PORT_RD}", "A0"), value="SN74F541N", footprint=FP_DIP20)
    decap(s, 39, 80, 171)
    s.part("placard_std:R_Network08", "RN1001", 130, 165, {"1": "+5V", **{str(2 + i): f"ROW{i}" for i in range(8)}},
           value="4.7k", footprint=FP_SIP9, ref_at=(122, 156), value_at=(122, 174))
    kb = {str(1 + i): f"~{{COL{i}}}" for i in range(8)}
    kb.update({str(9 + i): f"ROW{i}" for i in range(8)})
    s.part("placard_parts:Keyboard_Header", "J1", 285, 80, kb, value="Keyboard")
    # SNES pads
    for ref, x, y, data in [("J2", 375, 55, "PAD1_DATA"), ("J3", 375, 105, "PAD2_DATA")]:
        s.part("placard_parts:SNES_Pad_Socket", ref, x, y, {"1": "+5V", "2": "P_SCK", "3": "P_MOSI", "4": data,
                                                            "5": None, "6": None, "7": "GND"}, value="SNES pad")
    res(s, "R1001", 330, 125, "+5V", "PAD1_DATA", "10k")
    res(s, "R1002", 345, 125, "+5V", "PAD2_DATA", "10k")
    # SD card
    for i, (src, mid) in enumerate([("P_SCK", "SD_CLK"), ("P_MOSI", "SD_DI"), ("P_CS", "SD_CS")]):
        res(s, f"R{1003 + i}", 185, 165 + i * 14, src, mid, "1.8k", angle=90)
        res(s, f"R{1006 + i}", 215 + i * 15, 182, mid, "GND", "3.3k")
    s.part("placard_std:SD_Card", "J4", 300, 200, {"1": "SD_CS", "2": "SD_DI", "3": "GND", "4": "+3V3", "5": "SD_CLK",
                                                 "6": "GND", "7": "SD_MISO", "8": None, "9": None, "10": None,
                                                 "11": None, "12": "GND", "13": "GND"}, value="SD (SPI)",
           ref_at=(280, 183), value_at=(280, 218))
    res(s, "R1009", 245, 240, "+3V3", "SD_MISO", "10k")
    diode(s, "D1001", 195, 240, "SD_MISO", "ROW7", angle=180)
    # PS/2 mouse
    s.part("placard_std:Mini-DIN-6", "J5", 360, 180, {"1": "PS2_DATA", "2": None, "3": "GND", "4": "+5V",
                                                    "5": "PS2_CLK", "6": None}, value="PS/2 mouse",
           ref_at=(352, 171), value_at=(352, 189))
    res(s, "R1010", 335, 150, "+5V", "PS2_CLK", "4.7k")
    res(s, "R1011", 350, 150, "+5V", "PS2_DATA", "4.7k")
    diode(s, "D1002", 330, 225, "P_CS", "PS2_CLK", angle=180)
    diode(s, "D1003", 330, 240, "P_PS2D", "PS2_DATA", angle=180)
    diode(s, "D1004", 372, 225, "PS2_CLK", "ROW5", angle=180)
    diode(s, "D1005", 372, 240, "PS2_DATA", "ROW6", angle=180)
    note(s, 15, 252, ["Latch Q0 = SCK and pad CLOCK, Q1 = MOSI and pad LATCH, Q2 = SD /CS (low also holds PS/2 CLK), Q3 = PS/2 DATA,",
                      "Q7:Q4 = key column.  SD lines come down to 3.2 V through 1.8k / 3.3k; MISO reaches row 7 through a Schottky."],
         size=2.2)
    return s


def sheet_slots(b):
    s = b.sheet("expansion.kicad_sch", "Expansion slots", 11)
    heading(s, "Expansion slots", "Four 2 x 20 card-edge slots, x5100-x53FF, 128 bytes each (EXPANSION.md)")
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
        s.part("placard_parts:Expansion_Slot", ref, x, 110, n, value=f"Slot {k + 1}", ref_at=(x - 12, 78),
               value_at=(x - 12, 142))
        res(s, f"R{1101 + k}", x + 5, 175, f"SEL{k + 1}", "GND" if k < 2 else "+5V", "1k")
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
        2: ["J13 USB-C, F201, U40 3.3 V", "X1 25.175 MHz clock", "STALL / RUN jumpers"],
        3: ["U1 State, U2 Branch", "U17 instruction register PLD"],
        4: ["U3, U4 program counter", "U7-U10 address mux"],
        7: ["U31, U32 RAM, J8 cartridge", "U11 memory control", "U12 I/O decode, U25 map"],
        5: ["U5, U6 ALU", "U19 AC, U20 X, U21 Y"],
        6: ["U18 D register", "U26, U27 source drivers", "R601-R608, RN601"],
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
    s.part("placard_parts:Cartridge_Slot", "J1", 72, 120, cart, value="Card edge (87715-9106 mate)",
           footprint="", ref_at=(57, 69), value_at=(57, 171))
    s.part("placard:ATF22V10C_CART", "U1", 175, 95, pld({
        1: "CLK", 2: "~{CE_LO}", 3: "PIXEL_ENABLE", 4: "PC_ENABLE", 5: "STALL_IN", 14: None, 15: None,
        16: None, 17: None, 18: None, 21: None, 19: "~{SR_WE}", 20: "~{EE_OE}", 22: "RUN", 23: "STALL_OUT"}))
    decap(s, 1, 195, 63)
    s.pwr_flag(30, 200)
    s.power("+5V", 30, 200)
    s.pwr_flag(45, 200)
    s.power("GND", 45, 200)

    def mem(lib, ref, x, y, ce, oe, we, value, fp=None):
        n = {"20": ce, "22": oe, "27": we, "28": "+5V", "14": "GND"}
        for i, p in enumerate([10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2, 26, 1]):
            n[str(p)] = A[i]
        for i, p in enumerate([11, 12, 13, 15, 16, 17, 18, 19]):
            n[str(p)] = D[i]
        s.part(lib, ref, x, y, n, value=value, footprint=fp)
        decap(s, int(ref[1:]), x + 20, y - 37)
    mem("Memory_EEPROM:28C256", "U2", 270, 95, "~{CE_LO}", "~{EE_OE}", "+5V", "AT28C256-15PU", FP_DIP28W)
    mem("Memory_EEPROM:28C256", "U3", 365, 95, "~{CE_HI}", "~{EE_OE}", "+5V", "AT28C256-15PU", FP_DIP28W)
    mem("placard_parts:AS7C256C", "U4", 270, 210, "~{CE_LO}", "~{ROM_OE}", "~{SR_WE}", "AS7C256C-15PCN")
    mem("placard_parts:AS7C256C", "U5", 365, 210, "~{CE_HI}", "~{ROM_OE}", "~{SR_WE}", "AS7C256C-15PCN")
    note(s, 30, 215, ["U2 (lower 32K) and U3 (upper) hold the image,",
                       "programmed off the board; their /WE is tied high.",
                       "U4, U5 are the ROM the CPU reads (15 ns).",
                       "/CE_LO is the main board's A15.",
                       "U1 stalls the CPU at each PC address",
                       "(STALL_OUT), pulses /SR_WE, lets the CPU",
                       "step, and raises RUN when the PC wraps.",
                       "/CART (B10) is tied to GND: cartridge present.",
                       "Spare contacts are unassigned (EXPANSION.md)."])
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
    if "--pdf" in sys.argv:
        export_pdf(os.path.join(KDIR, "placard.kicad_sch"), os.path.join(ROOT, "schematics", "placard_main.pdf"))
        export_pdf(os.path.join(CDIR, "cartridge.kicad_sch"), os.path.join(ROOT, "schematics", "placard_cartridge.pdf"))
    if "--check" in sys.argv:
        bad = compare(expected_nets(sheets, glob), kicad_nets(os.path.join(KDIR, "placard.kicad_sch")), "main board")
        bad += compare(expected_nets([cart], set()), kicad_nets(os.path.join(CDIR, "cartridge.kicad_sch")), "cartridge")
        for path, label in [(os.path.join(KDIR, "placard.kicad_sch"), "main board"),
                            (os.path.join(CDIR, "cartridge.kicad_sch"), "cartridge")]:
            for it in erc(path, label, FLAGGED):
                print("  ", it)
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
