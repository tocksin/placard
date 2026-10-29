#!/usr/bin/env python3
"""Write the Placard KiCad schematic: kicad/*.kicad_sch (main board, root plus
ten sheets) and kicad/cartridge_64k/ and kicad/cartridge_32k/ (the two ROM
cartridge boards, one sheet each).

The sheet split follows docs/SCHEMATIC_PLAN.md.  The connections follow the
PLD pin lists (src/pld/*.pld), basys_top.vhd and the docs (CHIPS.md, IO.md,
SOUND.md, COLORS.md, EXPANSION.md, ROM.md).  Every pin of every part is listed
here with its net, so a pin left out stops the script.

Nets with several pins on a sheet are wired (kicad_route.py), numbered groups
are drawn as buses, nets that run between sheets get global labels, each chip has its decoupling capacitor Cn beside it (n = the
chip's U number), and the text is large.  Rerun after a pin or part change:

    python3 src/scripts/gen_kicad_schematic.py [--pdf] [--check]

--pdf exports schematics/placard_main.pdf, placard_cartridge_64k.pdf and
placard_cartridge_32k.pdf, set to open without the bookmarks panel.

--check exports the netlist with kicad-cli and compares it with the nets
listed here, then runs the ERC.

Date: 2026-10-29
"""
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kicad_sch_lib as K  # noqa: E402

DATE = "2026-10-29"
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
KDIR = os.path.join(ROOT, "kicad")
CDIRS = {64: os.path.join(KDIR, "cartridge_64k"), 32: os.path.join(KDIR, "cartridge_32k")}

# ---------------------------------------------------------------- footprints
# DIPs: kit versions of KiCad's socket footprints (puller room, part number in silkscreen) and
# resistors with their value in silkscreen, from gen_kicad_kit_footprints.py (Justin, 2026-10-23)
FP_DIP14 = "placard:DIP-14_W7.62mm_Socket_Puller"
FP_DIP20 = "placard:DIP-20_W7.62mm_Socket_Puller"
FP_DIP28W = "placard:DIP-28_W15.24mm_Socket_Puller"
FP_R = "placard:R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal_Value"
FP_C = "placard:C_Disc_D5.0mm_W2.5mm_P5.00mm"
FP_CP_S = "placard:CP_Radial_D6.3mm_P2.50mm"
FP_D = "placard:D_DO-35_SOD27_P7.62mm_Horizontal"
# Schottkys are black DO-41 1N5817s so they can't be mixed up with the glass 1N4148s (Justin, 2026-10-28);
# DO-41 at 7.62 mm with 1.6 mm pads, the same copper as the DO-35 places they replaced
FP_DS = "placard:D_DO-41_SOD81_P7.62mm_Horizontal_Pad1.6"
FP_LED = "placard:LED_D5.0mm"
FP_SIP9 = "placard:R_Array_SIP9"
FP_JP = "placard:PinHeader_1x02_P2.54mm_Vertical"

# ---------------------------------------------------------------- part numbers
# Manufacturer and MPN fields by part value, so KiCad's BOM export carries them.
# A part with no chosen part number gets empty fields to fill in later.
# the BOMs (docs/BOM.md and the BOM_*.md/.csv it lists) are written from the sheets by gen_bom.py.
MPN = {
    "ATF22V10C-7PX": ("Microchip", "ATF22V10C-7PX"),
    "ATF22V10C-10PU": ("Microchip", "ATF22V10C-10PU"),
    "SN74F377AN": ("Texas Instruments", "SN74F377AN"),
    "CD74HCT377E": ("Texas Instruments", "CD74HCT377E"),
    "SN74F541N": ("Texas Instruments", "SN74F541N"),
    "CD74ACT273E": ("Texas Instruments", "CD74ACT273E"),
    "SN74HCT574N": ("Texas Instruments", "SN74HCT574N"),
    "AS7C256C-15PCN": ("Alliance Memory", "AS7C256C-15PCN"),
    "AT28C256-15PU": ("Microchip", "AT28C256-15PU"),
    "MCP1700-3302E/TO": ("Microchip", "MCP1700-3302E/TO"),
    "USB4125-GF-A": ("GCT", "USB4125-GF-A-0190"),
    "3 A hold": ("Bourns", "MF-RG300-0"),
    "Molex 87715-9106": ("Molex", "87715-9106"),
    "1N5817": ("Micro Commercial Co", "1N5817-TP"),
    "1N4148": ("Vishay", "1N4148-TAP"),
    "SA5.0A": ("Littelfuse", "SA5.0A"),
    "WP7113ID": ("Kingbright", "WP7113ID"),
    "J1071CS5VDC.36": ("CIT Relay and Switch", "J1071CS5VDC.36"),
    "PTS645VL58-2 LFS": ("C&K", "PTS645VL58-2 LFS"),
    "PS/2 kbd + mouse": ("Kycon", "KMDGX-6S/6S-S4N"),
    "25.175 MHz": ("ECS Inc.", "ECS-100A-251.7"),
    "VGA": ("Assmann WSW", "A-HDF 15 A-KG/T"),
    "3.5 mm": ("Tensility", "54-00174"),
    "SD (SPI)": ("Hirose", "DM1AA-SF-PEJ(82)"),
}


# by symbol: parts whose Value is a label (slot name, net) rather than the part
MPN_LIB = {
    "placard_parts:Expansion_Slot": ("Sullins", "EBC20DCAN"),
    "placard_std:Jumper_2_Open": ("Sullins", "PREC002SAAN-RC"),
    "Switch:SW_Push_LED": ("Cherry", "MX2A-L1NB"),
}
# passives by (symbol, value): Yageo MFR-25 1 % metal film, Bourns 4609X SIP-9, KEMET/TDK ceramics,
# Rubycon YXJ electrolytic for C41 and C44 (25 V, 6.3 x 11 mm, 2.5 mm pitch; Justin, 2026-10-28)
R_CODE = {"5.1k": "5K1", "10k": "10K", "47": "47R", "3.3k": "3K3", "1.6k": "1K6", "820": "820R",
          "1.43k": "1K43", "715": "715R", "2.2": "2R2", "2k": "2K", "1k": "1K", "1.8k": "1K8",
          "4.7k": "4K7", "910": "910R", "22k": "22K"}
MPN_PASSIVE = {
    ("placard_std:R_Network08_US", "10k"): ("Bourns", "4609X-101-103LF"),
    ("placard_std:C", "100n"): ("TDK", "FG28X7R1H104KNT00"),
    ("placard_std:C", "1u"): ("KEMET", "C330C105K5R5TA"),
    ("placard_std:C", "15n C0G"): ("TDK", "FG24C0G1H153JNT06"),
    ("placard_std:C", "22u"): ("TDK", "FG22X7R1E226MRT06"),
    ("placard_std:C_Polarized", "220u"): ("Rubycon", "25YXJ220M6.3X11"),
}


def part_fields(lib_id, value):
    if lib_id.endswith(":R_US") and value in R_CODE:
        m, p = "Yageo", "MFR-25FBF52-" + R_CODE[value]
    else:
        m, p = MPN.get(value) or MPN_LIB.get(lib_id) or MPN_PASSIVE.get((lib_id, value), ("", ""))
    return {"Manufacturer": m, "MPN": p}


K.PART_FIELDS = part_fields


def bus(name, n, start=0):
    return [f"{name}{i}" for i in range(start, start + n)]


D = bus("DATABUS", 8)
A = bus("ADDR", 16)
SRC = bus("SRC", 8)
DR = bus("D", 8)
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
             "U5": "ALU low PLD", "U6": "ALU high PLD", "U7": "Address mux 1:0, 9:8", "U8": "Address mux 3:2, 11:10",
             "U9": "Address mux 5:4, 13:12", "U10": "Address mux 7:6, 15:14", "U11": "Memory control PLD",
             "U12": "I/O decode PLD", "U13": "H counter PLD", "U14": "V counter PLD", "U15": "Sync PLD",
             "U16": "Color decoder PLD", "U17": "Instruction register PLD", "U35": "Audio slot PLD", "U38": "Shared port PLD",
             "U42": "PS/2 receiver PLD"}


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


def quad_mux(d, x, y, va, pc, out):
    """Mux PLD revision 02: address bits n, n+1 (low: D, X, video, PC) and n+8, n+9 (high: Y,
    video, PC).  d, x, y are the two low / high register bits, va, pc and out the four address
    bits in the order n, n+1, n+8, n+9; the selects are the enables themselves (pins 1-4)."""
    n = {1: "PIXEL_ENABLE", 2: "PC_ENABLE", 3: "X_ENABLE", 4: "Y_ENABLE",
         5: d[0], 6: x[0], 7: va[0], 8: pc[0],
         9: d[1], 10: x[1], 11: va[1], 13: pc[1],
         14: y[0], 15: va[2], 16: pc[2],
         17: y[1], 18: va[3], 19: pc[3]}
    for i in range(4):
        n[20 + i] = out[i]
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


def diode(s, ref, x, y, k, a, angle=0, value="1N5817", bare=(), ref_at=None, value_at=None):
    # angle 0: cathode (pin 1) on the left; 180: on the right; 270: on top
    return s.part("placard_std:D_Schottky", ref, x, y, {"1": k, "2": a}, value=value, footprint=FP_DS, angle=angle,
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
    f201 = s.part("placard_std:Polyfuse", "F1", 91.44, yr, {"1": "VBUS", "2": "VFUSE"}, value="3 A hold",
                  footprint="placard:Fuse_Bourns_MF-RG300", angle=90, bare=("1", "2"),
                  ref_at=(86.4, yr - 2.0), value_at=(86.4, yr + 2.0))
    path(s, "VBUS", j13["A9"], f201["1"])
    # after the fuse: the on/off toggle, then the reset button (push to open), both in series
    sw1 = s.part("placard_std:SW_SPST", "SW1", 124.46, yr, {"1": "VFUSE", "2": "VON"}, value="ANT11TFHQE",
                 footprint="placard:SW_Toggle_CIT_ANT11TFHQE", bare=("1", "2"), ref_at=(119.8, yr - 4.6), value_at=(118.5, yr + 2.6),
                 extra_props={"Manufacturer": "CIT Relay and Switch", "MPN": "ANT11TFHQE",
                              "Description": "Power on/off: SPDT on-on toggle, 5 A 28 V DC, right-angle PCB, 1/4-40 bushing"})
    # TVS from the fused VBUS to GND: clamps the spike the cable's inductance throws when SW1 or K1
    # opens under load (and plug-in ringing, ESD); after the fuse, so a lasting overvoltage trips F1
    tvs = s.part("placard_std:D_Zener", "D7", 104.14, yr + 3.81, {"1": "VFUSE", "2": "GND"}, value="SA5.0A",
                 footprint="placard:D_DO-15_P10.16mm_Horizontal", angle=270, bare=("1",), ref_at=(106.2, yr + 3.3), value_at=(106.2, yr + 6.4))
    path(s, "VFUSE", f201["2"], tvs["1"])
    path(s, "VFUSE", tvs["1"], sw1["1"])
    s.junction(tvs["1"][0], yr, owner="VFUSE")
    # reset (Justin, 2026-10-22): relay K1's NC contact carries the power; the small button SW2 drives
    # its coil from VON, so holding it opens the contact.  D8 takes the coil's kick when SW2 lets go.
    # C41, the bulk cap, sits on VON ahead of the relay so the board side drains fast.
    # K1 is a CIT J1071CS5VDC.36 (Justin, 2026-10-25): same pins as the G5LE, so the G5LE symbol stays; footprint
    # placard:Relay_SPDT_CIT_J107 (gen_kicad_connectors.py) has the same pads under the smaller body.
    xk = 170.18
    k1 = s.part("placard_std:G5LE-1", "K1", xk, yr - 2.54, {"1": "VON", "4": "+5V", "3": None, "2": "KCOIL", "5": "GND"},
                value="J1071CS5VDC.36", footprint="placard:Relay_SPDT_CIT_J107", angle=270, bare=("1", "4", "2", "5"),
                ref_at=(xk - 2.5, yr + 8.5), value_at=(xk - 2.5, yr + 11.0))
    xt = 152.4
    sw2 = s.part("placard_std:SW_Push", "SW2", xt + 5.08, yr - 7.62, {"1": "VON", "2": "KCOIL"}, value="PTS645VL58-2 LFS",
                 footprint="placard:SW_Tactile_SPST_Angled_PTS645Vx58-2LFS", bare=("1", "2"),
                 ref_at=(xt + 2.5, yr - 12.6), value_at=(xt - 8.0, yr - 26.5))
    yd = yr - 17.78
    d8 = s.part("placard_std:D_Schottky", "D8", xk, yd, {"1": "KCOIL", "2": "GND"}, value="1N5817", footprint=FP_DS,
                 bare=("1", "2"), ref_at=(xk - 7.0, yd - 3.2), value_at=(xk + 1.0, yd - 3.2))
    c201 = s.part("placard_std:C_Polarized", "C41", 142.24, yr + 3.81, {"1": "VON", "2": "GND"},
                  value="220u", footprint=FP_CP_S, bare=("1",), ref_at=(144.7, yr + 3.3), value_at=(144.7, yr + 6.4))
    xj = k1["1"][0] - 2.54
    path(s, "VON", sw1["2"], (c201["1"][0], yr), (xt, yr), (xj, yr), (xj, k1["1"][1]), k1["1"])
    s.junction(c201["1"][0], yr, owner="VON")
    s.junction(xt, yr, owner="VON")
    path(s, "VON", (xt, yr), (xt, sw2["1"][1]), sw2["1"])
    path(s, "KCOIL", sw2["2"], k1["2"])
    path(s, "KCOIL", k1["2"], (k1["2"][0], yd), d8["1"])
    s.junction(k1["2"][0], k1["2"][1], owner="KCOIL")
    xg = k1["5"][0] + 5.08
    path(s, "GND", d8["2"], (k1["5"][0], yd), k1["5"])
    path(s, "GND", (k1["5"][0], yd), (xg, yd), (xg, yd + 2.54))
    s.junction(k1["5"][0], yd, owner="GND")
    s.power("GND", xg, yd + 2.54)
    for net, pin, x in (("CC2", "B5", 73.66), ("CC1", "A5", 88.9)):
        r = s.part("placard_std:R_US", "R1" if net == "CC1" else "R2", x, 104.14, R2(net, "GND"), value="5.1k",
                   footprint=FP_R, bare=("1",), ref_at=(x + 2.0, 103.6), value_at=(x + 2.0, 106.7))
        path(s, net, j13[pin], (x, j13[pin][1]), r["1"])
    # 3.3 V regulator on the same line
    u40 = s.part("placard_parts:MCP1700_TO92", "U40", 233.68, yr, {"1": "GND", "2": "+5V", "3": "+3V3"},
                 value="MCP1700-3302E/TO", bare=("2", "3"), ref_at=(223.5, yr - 10.5), value_at=(223.5, yr - 9.0))
    c40 = s.part("placard_std:C", "C40", 203.2, yr + 3.81, {"1": "+5V", "2": "GND"}, value="1u", footprint=FP_C,
                 bare=("1",), ref_at=(205.7, yr + 3.3), value_at=(205.7, yr + 6.4))
    xp, xf = 195.58, 187.96
    for pts in ([k1["4"], (xf, yr)], [(xf, yr), (xp, yr)],
                [(xp, yr), (c40["1"][0], yr)], [(c40["1"][0], yr), u40["2"]]):
        path(s, "+5V", *pts)
    s.junction(c40["1"][0], yr, owner="+5V")
    s.pwr_flag(xf, yr)
    s.power("+5V", xp, yr)
    c202 = s.part("placard_std:C", "C47", 254.0, yr + 3.81, {"1": "+3V3", "2": "GND"}, value="1u", footprint=FP_C,
                  bare=("1",), ref_at=(256.5, yr + 3.3), value_at=(256.5, yr + 6.4))
    x3, xf3 = 264.16, 274.32
    path(s, "+3V3", u40["3"], (c202["1"][0], yr))
    path(s, "+3V3", (c202["1"][0], yr), (x3, yr))
    path(s, "+3V3", (x3, yr), (xf3, yr))
    s.junction(c202["1"][0], yr, owner="+3V3")
    s.power("+3V3", x3, yr)
    s.pwr_flag(xf3, yr)
    note(s, 25, 122, ["5.1k on CC1 and CC2: a USB-C source gives 5 V.",
                      "19 PLDs draw up to about 2.5 A (130 mA each at",
                      "-7, worst case): use a 3 A supply; the polyfuse",
                      "trips on a short.  SW1 power: toggle, common +",
                      "one throw.  SW2 reset: holding it pulls in K1,",
                      "whose NC contact opens the 5 V line."])
    note(s, 200, 112, ["U40: 3.3 V for the SD card only (sheet 10).", "C40 input, C47 output (1 uF ceramic)."])
    # power LED (Justin, 2026-10-24): on +5V after K1's contact, so it goes dark while reset holds K1 in
    xl = 304.8
    s.power("+5V", xl, yr - 2.54)
    r59 = res(s, "R59", xl, yr + 7.62, "+5V", "PWR_LED", "1k", bare=("1", "2"))
    d18 = s.part("placard_std:LED", "D18", xl, yr + 22.86, {"1": "GND", "2": "PWR_LED"}, value="WP7113ID",
                 footprint=FP_LED, angle=90, bare=("1", "2"), ref_at=(xl + 3.0, yr + 22.3), value_at=(xl + 3.0, yr + 25.4))
    path(s, "+5V", (xl, yr - 2.54), r59["1"])
    path(s, "PWR_LED", r59["2"], d18["2"])
    path(s, "GND", d18["1"], (xl, d18["1"][1] + 2.54))
    s.power("GND", xl, d18["1"][1] + 2.54)
    note(s, 282, 124, ["D18 power LED (red, 5 mm) on +5V,", "after K1: dark while reset is held.", "R59 1k: about 3 mA."])
    # analog ground joins logic ground at the power input
    # (each side has its power flag on the pin end and its ground symbol below)
    nt = s.part("placard_std:NetTie_2", "NT1", 165.1, 109.22, {"1": "GND", "2": "GNDA"}, value="AGND tie",
                footprint="placard:NetTie-2_THT_Pad0.3mm", ref_at=(158, 102), value_at=(160.5, 112),
                bare=("1", "2"), in_bom=False)
    for net in ("GND", "GNDA"):
        (px, py) = nt["1" if net == "GND" else "2"]
        xa = px - 7.62 if net == "GND" else px + 7.62
        path(s, net, (px, py), (xa, py), (xa, py + 5.08))
        s.pwr_flag(xa, py)
        s.power(net, xa, py + 5.08)
    note(s, 152, 128, ["AGND (audio) meets GND", "here, at the power input"])
    # oscillator
    # X1 drives CLK_E, which reaches only the Sync PLD's pin 9 (the RAM /WE) and net tie NT2;
    # CLK, to every other chip, is the far side of NT2.  On the board NT2 goes at least 420 mm
    # of track (500 nominal, 3 ns) from X1, so /WE rises before the rest of the board sees the
    # edge (docs/FETCH_TIMING.md, docs/WE_TIMING.md).
    s.part("placard_parts:Oscillator_DIP14", "X1", 63.5, 170.18, {"14": "+5V", "7": "GND", "8": "CLK_E"},
           value="25.175 MHz", ref_at=(50, 160), value_at=(66, 181.0))
    decap(s, 43, 81.28, 160.02, lift=0)     # C43: the oscillator's, X1 has no U-number
    nt2 = s.part("placard_std:NetTie_2", "NT2", 109.22, 187.96, {"1": "CLK_E", "2": "CLK"}, value="CLK tap",
                 footprint="placard:NetTie-2_THT_Pad0.3mm", ref_at=(104, 181), value_at=(104.5, 194),
                 bare=("1", "2"), in_bom=False)
    path(s, "CLK_E", nt2["1"], (nt2["1"][0] - 5.08, nt2["1"][1]))
    name(s, "CLK_E", nt2["1"][0] - 5.08, nt2["1"][1], 180)
    path(s, "CLK", nt2["2"], (nt2["2"][0] + 5.08, nt2["2"][1]))
    name(s, "CLK", nt2["2"][0] + 5.08, nt2["2"][1], 0)
    note(s, 40, 224, ["NT2: CLK_E (X1, U15 pin 9) to CLK (every other chip) through",
                      "at least 420 mm of track (500 nominal): the RAM /WE's early clock."], size=2.2)
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
        1: "CLK", 2: "DATABUS0", 3: "DATABUS1", 4: "DATABUS2", 5: "DATABUS3", 6: "DATABUS4", 7: "DATABUS5", 8: "DATABUS6", 9: "DATABUS7",
        10: "~{LOAD_INSTR}", 11: "RUN", 14: "I0", 15: "I1", 16: "I2", 17: "I3", 18: "I4", 19: "I5",
        20: "I6", 21: "I7"}))
    decap(s, 17, 91.44, y1 - 33.02, lift=0)
    u1 = s.part("placard:ATF22V10C_STATE", "U1", 172.72, y1, pld({
        1: "CLK", 2: "STALL_OUT", 3: "DATABUS1", 4: "DATABUS0", 5: "I4", 6: "I3", 7: "I2", 8: "BRANCH_BLOCK",
        9: "DATABUS3", 10: "DATABUS2", 11: "DATABUS4", 13: "I0", 18: "Q0", 15: "PC_ENABLE", 16: "X_ENABLE", 17: "Y_ENABLE",
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
    heading(s, "Program counter and address mux", "Each mux: two low bits (D, X, video, PC) and two high bits (0, Y, video, PC); the enables select")
    # the buses from other sheets get a label at each chip; PC runs from U3 / U4 to the muxes' PC inputs;
    # the selects (PIXEL_ENABLE from U15, the enables from U1) are labels at pins 1-4 of each mux
    s.label_each |= {"D", "X", "Y", "VA", "V", "H", "ADDR", "DATABUS"}
    s.label_nets |= {"PIXEL_ENABLE", "PC_ENABLE", "X_ENABLE", "Y_ENABLE"}
    u3 = s.part("placard:ATF22V10C_PC_COUNTER8", "U3", 104.14, 93.98,
                pc_counter(D, "LOAD_PC_LOW", "+5V", PC[0:8], "PC_CO"), bare=("11", "13", "23"))
    decap(s, 3, 124.46, 63.5, lift=0)
    u4 = s.part("placard:ATF22V10C_PC_COUNTER8", "U4", 104.14, 195.58,
                pc_counter(Y, "LOAD_PC_HIGH", "PC_CO", PC[8:16], None), bare=("11", "13"))
    # PC_ENABLE is a label at each mux's pin 2; at the PC PLDs it gets a stub and its own label
    for u in (u3, u4):
        (px, py) = u["11"]
        path(s, "PC_ENABLE", (px, py), (px - 10.16, py))
        name(s, "PC_ENABLE", px - 10.16, py, 180)
    decap(s, 4, 124.46, 165.1, lift=0)
    # U3 CIN tied high; U3 CO down between the two and into U4 CIN
    (cx, cy) = u3["13"]
    path(s, "+5V", (cx, cy), (cx - 2.54, cy), (cx - 2.54, cy - 5.08))
    s.power("+5V", cx - 2.54, cy - 5.08)
    (ox, oy), (ix, iy) = u3["23"], u4["13"]
    yg = 142.24
    path(s, "PC_CO", (ox, oy), (ox + 2.54, oy), (ox + 2.54, yg), (ix - 2.54, yg), (ix - 2.54, iy), (ix, iy))
    # mux PLD revision 02 (docs/FETCH_TIMING.md): chip n makes address bits 2n, 2n+1 (low: D, X,
    # video, PC) and 2n+8, 2n+9 (high: Y, video, PC); the four enables are its selects
    for ref, x, y, n in [("U7", 223.52, 93.98, 0), ("U8", 337.82, 93.98, 1),
                         ("U9", 223.52, 195.58, 2), ("U10", 337.82, 195.58, 3)]:
        lo, hi = (2 * n, 2 * n + 1), (2 * n + 8, 2 * n + 9)
        bits = lo + hi
        s.part("placard:ATF22V10C_QUAD_MUX", ref, x, y,
               quad_mux([DR[i] for i in lo], [X[i] for i in lo], [Y[i - 8] for i in hi],
                        [VA[i] for i in bits], [PC[i] for i in bits], [A[i] for i in bits]))
        decap(s, int(ref[1:]), x + 27.94, y - 33.02, lift=0)     # the wider symbol (long select names)
    # PC: down from U3 and U4, then along under each row of muxes
    xb = 139.7
    s.bus_piece("PC", [(xb, 99.06), (xb, 243.84), (312.42, 243.84)])
    s.bus_piece("PC", [(xb, 139.7), (312.42, 139.7)])
    s.junction(xb, 139.7, owner="BUS:PC")
    note(s, 20, 258, ["Selects: PIXEL_ENABLE (U15) = video address; else PC_ENABLE = PC; else X_ENABLE / Y_ENABLE = X / Y register; else D / 00h.",
                      "Video address: VA0, VA1, VA7, VA8 from the audio slot PLD (line repeat), ADDR6:2 = V6:V2, ADDR15:9 = H9:H3.",
                      "U3 CIN tied high (always counts); U3 CO carries into U4.  STALL_OUT holds the PC (video reads, ALU wait, cartridge load)."],
         size=2.2)
    return s


def sheet_alu(b):
    s = b.sheet("alu_regs.kicad_sch", "ALU and registers", 5)
    heading(s, "ALU and registers", "Two 4-bit ALU PLDs; F7:F0 loads AC, X or Y")
    s.label_each |= {"DATABUS", "X", "Y", "I"}
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
    s.part("placard_std:74LS377", "U18", 81.28, 101.6, f377(D, DR, "~{LOAD_IMM}"), value="SN74F377AN", footprint=FP_DIP20)
    decap(s, 18, 101.6, 73.66, lift=0)
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
        s.part("placard_std:R_US", f"R{5 + i}", x, 154.94, R2(D[i], SRC[i]), value="47", footprint=FP_R,
               ref_at=(x + 1.6, 153.9), value_at=(x + 1.6, 157.0))
    s.bus_piece("SRC", [(198.12, 170.18), (320.04, 170.18)])
    s.bus_piece("DATABUS", [(373.38, 132.08), (215.9, 132.08), (215.9, 48.26), (33.02, 48.26), (33.02, 91.44)])
    s.part("placard_std:R_Network08_US", "RN1", 355.6, 106.68, {"1": "+5V", **{str(2 + i): D[i] for i in range(8)}},
           value="10k", footprint=FP_SIP9, ref_at=(359, 94.3), value_at=(375, 94.3))
    note(s, 230, 200, ["SRC7:SRC0: the two source F541s' joined outputs.",
                       "R5-R12 (47 ohm) limit the current while the",
                       "bus changes hands at the start of EXEC (CPU.md).",
                       "U26 drives D (sources 00, 01: /OE2 = I1),",
                       "U27 drives AC (10, 11: /OE2 = /AC_SEL).",
                       "RN1: DATABUS7:0 read FFh when nothing drives it",
                       "(empty slots, the cartridge loader's feed byte)."])
    return s


def sheet_memory(b):
    s = b.sheet("memory.kicad_sch", "Memory and I/O decode", 7)
    heading(s, "Memory and I/O decode", "RAM, ROM cartridge slot, memory control, I/O decode, map register")
    # A and D come from other sheets: a label at each chip.  The clock and the CPU's control
    # lines that arrive from other sheets are labelled at each pin; the memory strobes are wired.
    s.label_each |= {"ADDR", "DATABUS"}
    s.label_nets |= {"CLK", "RUN", "PIXEL_ENABLE", "RW"}
    # map register U25 feeds RAMSEL7:0 straight across into U11
    u25 = s.part("placard_std:74LS273", "U25", 66.04, 101.6, ls273(D, RAMSEL, "RUN", "~{MAP_WR}"), value="CD74ACT273E",
                 footprint=FP_DIP20, bare=("11",))
    decap(s, 25, 45.72, 73.66, lift=0)
    u11 = s.part("placard:ATF22V10C_MEM_CTRL", "U11", 177.8, 101.6, pld({
        1: "CLK", 2: "ADDR15", 3: "ADDR14", 4: "ADDR13", 5: "ADDR12", 6: "RAMSEL0", 7: "RAMSEL1", 8: "RAMSEL3",
        9: "RAMSEL4", 10: "RAMSEL5", 11: "RAMSEL6", 13: "RAMSEL7", 15: "RAMSEL2", 14: "RW",
        23: "PIXEL_ENABLE", 20: "ADDR11", 21: "ADDR10", 22: "~{SRC_EN}", 17: "RUN",
        16: None, 19: "~{ROM_OE}", 18: "~{RAM_OE}"}), bare=("18", "19"))
    decap(s, 11, 198.12, 58.42, lift=0)
    u12 = s.part("placard:ATF22V10C_IO_DECODE", "U12", 154.94, 208.28, pld({
        1: "~{WE}", 2: "PIXEL_ENABLE", 3: "PC_ENABLE", 4: "PC15", 5: "H9", 6: "Y7", 7: "ADDR14", 8: "ADDR13",
        9: "ADDR12", 10: "ADDR10", 11: "ADDR9", 13: "ADDR8", 14: "Y_ENABLE", 18: "ADDR11", 23: "~{LOAD_IMM}",
        15: "~{CE_HI}", 16: "~{MAP_WR}", 17: "~{LINE_RD}", 19: "~{PORT_WR}", 20: "~{PORT_RD}",
        21: "~{EXP1}", 22: "~{EXP2}"}), bare=("1", "15", "16"))
    decap(s, 12, 121.92, 172.72, lift=0)      # left of VCC: /MAP_WR goes up on the right
    u31 = s.part("placard_parts:AS7C256C", "U31", 256.54, 198.12, sram("ADDR15", "~{RAM_OE}", "~{WE}"),
                 value="AS7C256C-15PCN", bare=("22", "27"))
    decap(s, 31, 276.86, 165.1, lift=0)
    u32 = s.part("placard_parts:AS7C256C", "U32", 355.6, 198.12, sram("~{CE_HI}", "~{RAM_OE}", "~{WE}"),
                 value="AS7C256C-15PCN", bare=("20", "22", "27"))
    decap(s, 32, 375.92, 165.1, lift=0)
    cart = dict(CART_PINOUT, A5="ADDR15", B10="~{CART}")     # A15 selects the lower chip: /CE_LO on the cartridge
    j8 = s.part("placard_parts:Cartridge_Slot", "J8", 320.04, 95.25, cart, value="Molex 87715-9106",
                footprint="placard:Molex_87715-9106_PCIe_x4_Vertical", ref_at=(304.8, 44), value_at=(304.8, 150), bare=("B16", "A16"))
    # the memory strobes: /RAM_OE from U11 down to a lane under the RAMs, /WE (from U15 on the video
    # timing sheet, since Sync revision 10) along a lane from U12's input to the RAMs and its label,
    # /CE_HI from U12 up to J8 and down to U32, /MAP_WR from U12 back round to U25's clock
    yl = {"~{WE}": 246.38, "~{RAM_OE}": 248.92, "~{CE_HI}": 251.46}
    xv = {"~{WE}": 208.28, "~{RAM_OE}": 210.82, "~{ROM_OE}": 215.9, "~{CE_HI}": 205.74}
    for net, pn in (("~{RAM_OE}", "18"),):
        (px, py) = u11[pn]
        path(s, net, (px, py), (xv[net], py), (xv[net], yl[net]))
    (px, py) = u11["19"]
    path(s, "~{ROM_OE}", (px, py), (xv["~{ROM_OE}"], py), (xv["~{ROM_OE}"], j8["A16"][1]), j8["A16"])
    (px, py) = u12["15"]
    path(s, "~{CE_HI}", (px, py), (xv["~{CE_HI}"], py))
    path(s, "~{CE_HI}", (xv["~{CE_HI}"], j8["B16"][1]), (xv["~{CE_HI}"], py), (xv["~{CE_HI}"], yl["~{CE_HI}"]))
    path(s, "~{CE_HI}", (xv["~{CE_HI}"], j8["B16"][1]), j8["B16"])
    s.junction(xv["~{CE_HI}"], py, owner="~{CE_HI}")
    (px, py) = u12["1"]
    path(s, "~{WE}", (px, py), (px - 2.54, py), (px - 2.54, yl["~{WE}"]), (xv["~{WE}"], yl["~{WE}"]))
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
    # /WE pull-up: U15 lets go of /WE while RUN is low (Sync revision 10; memory control 09 before)
    r63 = res(s, "R63", 377.19, 242.57, "+5V", "~{WE}", "10k", bare=("2",),
              ref_at=(367.03, 241.3), value_at=(367.03, 243.84))
    s.junction(r63["2"][0], yl["~{WE}"], owner="~{WE}")
    note(s, 20, 258, ["Lower 32K: /CE = A15 (RAM U31, cartridge /CE_LO); upper: /CE_HI from U12.",
                       "/WE comes from U15 (Sync, sheet 8).  RUN low (cartridge loading): /ROM_OE held off, map register clear (all ROM), /WE let go (R63).",
                       "/CART reads low with a cartridge in; nothing reads it yet.  21 spare contacts."],
         size=2.2)
    return s


def sheet_video_timing(b):
    s = b.sheet("video_timing.kicad_sch", "Video timing", 8)
    heading(s, "Video timing", "640 x 480 at 60 Hz: H and V counters, Sync (and the RAM /WE), mode and audio slots, line read")
    s.label_nets |= {"CLK", "CLK_E", "RW", "RUN", "~{WE}"}
    u13 = s.part("placard:ATF22V10C_HCOUNT", "U13", 76.2, 99.06, pld({
        1: "CLK", 2: "GND", 3: "H0", 4: "H1", 5: "H2", 6: "LC7", 14: "H3", 15: "H4", 16: "H5", 17: "H6", 18: "H7",
        19: "H8", 20: "H9", 21: "~{HSYNC}", 22: "H_VIDEO_ACTIVE", 23: "H_TC"}), bare=("21", "23"))
    decap(s, 13, 96.52, 63.5, lift=0)
    u14 = s.part("placard:ATF22V10C_VCOUNT", "U14", 76.2, 208.28, pld({
        1: "CLK", 2: "H_TC", 14: "V0", 23: "V1", 22: "V2", 15: "V3", 16: "V4", 21: "V5", 20: "V6",
        17: "V7", 18: "V8", 19: "V9"}), bare=("2",))
    decap(s, 14, 96.52, 175.26, lift=0)
    # H_TC: out of the H counter, down between the two and into the V counter's EN
    (ox, oy), (ix, iy) = u13["23"], u14["2"]
    yg = 152.4
    path(s, "H_TC", (ox, oy), (ox + 2.54, oy), (ox + 2.54, yg), (ix - 2.54, yg), (ix - 2.54, iy), (ix, iy))
    u15 = s.part("placard:ATF22V10C_SYNC", "U15", 233.68, 99.06, pld({
        1: "CLK", 2: "V9", 3: "V5", 4: "V4", 5: "V3", 6: "V2", 7: "V1", 8: "H_VIDEO_ACTIVE",
        9: "CLK_E", 10: "RW", 11: "RUN", 13: "BLANK_RD", 14: "H0", 15: "H1", 16: "H2",
        17: "VIDEN", 18: "~{VSYNC}", 19: "PIXEL_ENABLE", 20: "~{WE}", 21: None, 22: None,
        23: None}), bare=("18",))
    decap(s, 15, 254.0, 60.96, lift=0)
    # Sync series resistors, right at the PLD pins: they slow the edges going down the VGA cable (less
    # ringing and noise) and limit the current into a shorted pin.  The monitor's sync inputs are TTL.
    # (R62 sits past U15's label column, clear of the PIXEL_ENABLE label just above.)
    for ref, u, pin, xr in (("R61", u13, "21", 119.38), ("R62", u15, "18", 312.42)):
        net = "~{HSYNC}" if pin == "21" else "~{VSYNC}"
        out = "~{VGA_HSYNC}" if pin == "21" else "~{VGA_VSYNC}"
        px, py = u[pin]
        rp = res(s, ref, xr, py, net, out, "47", angle=90, bare=("1", "2"),
                 ref_at=(xr - 4.5, py - 3.4), value_at=(xr + 4.0, py - 3.4))
        path(s, net, (px, py), rp["1"])
        path(s, out, rp["2"], (rp["2"][0] + 7.62, py))
        name(s, out, rp["2"][0] + 7.62, py)
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
                       "LC7 (mode byte bit 7, U23 Q7) blanks the line.",
                       "Strap S4 goes in U35's socket (BRINGUP.md)."])
    return s


def sheet_video_out(b):
    s = b.sheet("video_out.kicad_sch", "Video and audio out", 9)
    heading(s, "Video and audio out", "Pixel buffer, line code, color decoder and VGA DAC; audio DAC register, R-2R ladder, audio line out")
    PIXB = tuple(str(p) for p in F377_Q)
    # ---- video: D -> U22 pixel buffer -> U16 color decoder -> resistor DAC -> VGA
    u22 = s.part("placard_std:74LS377", "U22", 76.2, 101.6, f377(D, PIX, "~{PIX_LD}"), value="SN74F377AN",
                 footprint=FP_DIP20, bare=PIXB)
    decap(s, 22, 91.44, 76.2, lift=0)
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
    # U23 line code: PIX in, LC1:LC0 up into U16, LC3:LC2 to the audio slot PLD and LC7 to the H counter
    # (sheet 8), LC6:LC4 to the row tint below.  HCT: each tint output sources about 3 mA.
    u23 = s.part("placard_std:74LS377", "U23", 132.08, 152.4,
                 f377(PIX, ["LC0", "LC1", "LC2", "LC3", "LC4", "LC5", "LC6", "LC7"], "~{MODE_LD}"),
                 value="CD74HCT377E", footprint=FP_DIP20, bare=("2", "5", "12", "15", "16"))
    for k in (4, 5, 6):
        qx, qy = u23[str(F377_Q[k])]
        path(s, f"LC{k}", (qx, qy), (qx + 7.62, qy))
        tag(s, f"LC{k}", qx + 2.54, qy)
    decap(s, 23, 180.34, 152.4, lift=0)
    for k, xj in ((0, 147.32), (1, 149.86)):   # clear of U16's H0-H2 and VIDEN tabs
        (qx, qy), (mx, my) = u23[str(F377_Q[k])], u16[str(10 + k)]
        path(s, f"LC{k}", (qx, qy), (xj, qy), (xj, my), (mx, my))
        name(s, f"LC{k}", mx - 10.16, my)
    # RGB: U16 outputs fan out to one resistor per row, then into J7
    outs = [("RED1", "15", "3.3k"), ("RED2", "16", "1.6k"), ("RED3", "21", "820"),
            ("GRN1", "17", "3.3k"), ("GRN2", "20", "1.6k"), ("GRN3", "19", "820"),
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
        "9": None, "10": "GND", "11": None, "12": None, "13": "~{VGA_HSYNC}", "14": "~{VGA_VSYNC}", "15": None, "0": "GND"},
        value="VGA", footprint="placard:DSUB-15-HD_Female_Horizontal_P2.29x1.98mm_EdgePinOffset3.03mm_Housed_MountingHolesOffset4.94mm",
        ref_at=(311, 84), value_at=(311, 126), bare=("1", "2", "3"))
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
    # Row tint: LCn -> 910 -> node -> two 1N4148 -> VGA line; a 1N5817 from the node to VIDEN holds the
    # node at about 0.7 V in blanking, too low to pass the two silicon diodes, so the tint is off there.
    # Labels only (no routing): LCn from U23, VGA_x to J7, VIDEN from the Sync PLD.
    xv, xn = 215.9, 240.03
    vys = []
    for k, (lc, color) in enumerate((("LC4", "VGA_R"), ("LC5", "VGA_G"), ("LC6", "VGA_B"))):
        yt = 144.78 + k * 20.32
        node = f"TINT_{color[-1]}"
        mid = f"TINT_{color[-1]}2"
        rt = s.part("placard_std:R_US", f"R{56 + k}", 229.87, yt, R2(lc, node), value="910", footprint=FP_R,
                    angle=90, bare=("1", "2"), ref_at=(226.5, yt - 7.0), value_at=(227.0, yt + 3.4))
        da = s.part("placard_std:D", f"D{12 + 2 * k}", 248.92, yt, {"1": mid, "2": node}, value="1N4148",
                    footprint=FP_D, angle=180, bare=("1", "2"), ref_at=(245.0, yt - 7.0), value_at=(245.0, yt - 4.2))
        db = s.part("placard_std:D", f"D{13 + 2 * k}", 261.62, yt, {"1": color, "2": mid}, value="1N4148",
                    footprint=FP_D, angle=180, bare=("1", "2"), ref_at=(257.7, yt - 7.0), value_at=(257.7, yt - 4.2))
        dc = s.part("placard_std:D_Schottky", f"D{9 + k}", xn, yt + 3.81, {"1": "VIDEN", "2": node}, value="1N5817",
                    footprint=FP_DS, angle=90, bare=("1", "2"), ref_at=(xn + 2.5, yt + 5.0), value_at=(xn + 2.5, yt + 7.8))
        path(s, lc, (rt["1"][0] - 3.81, yt), rt["1"])
        tag(s, lc, rt["1"][0] - 3.81, yt)
        path(s, node, rt["2"], (xn, yt), da["2"])
        path(s, node, dc["2"], (xn, yt))
        s.junction(xn, yt, owner=node)
        path(s, mid, da["1"], db["2"])
        path(s, color, db["1"], (db["1"][0] + 10.16, yt))
        tag(s, color, db["1"][0] + 3.81, yt)
        cx, cy = dc["1"]
        path(s, "VIDEN", (cx, cy), (xv, cy))
        vys.append(cy)
    path(s, "VIDEN", (xv, vys[0]), (xv, vys[-1] + 5.08))
    for cy in vys[1:]:
        s.junction(xv, cy, owner="VIDEN")
    s.label("VIDEN", xv, vys[-1] + 5.08, 270, "passive", True)
    note(s, 226.06, 210.82, ["Row tint: mode byte bits 6:4 lift R, G, B by about 0.2 V",
                             "for the whole row.  Off in blanking (1N5817 to VIDEN)."], size=2.2)
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
    # J6 is a TRRS jack: a TRS plug's sleeve spans R2 and S, so both go to GNDA
    j6 = s.part("placard_std:AudioJack4", "J6", 281.94, yo + 5.08, {"T": "AUDIO", "R1": "AUDIO", "R2": "GNDA", "S": "GNDA"},
                value="3.5 mm", footprint="placard:Jack_3.5mm_Tensility_54-00174_Horizontal", ref_at=(278, yo - 6.5),
                value_at=(285, yo + 11.0), angle=180, bare=("T", "R1"))
    path(s, "AUDIO", c903["2"], j6["T"])
    s.junction(r957["1"][0], yo, owner="AUDIO")
    xa = j6["T"][0] - 2.54
    path(s, "AUDIO", (xa, yo), (xa, j6["R1"][1]), j6["R1"])
    name(s, "AUDIO", r957["1"][0] + 2.54, yo)
    note(s, 15, 258, ["U23 Q1:Q0 = color mode; Q3:Q2 = line repeat to U35 and Q7 = blank line to U13 (sheet 8); Q6:Q4 = row tint.",
                      "DAC_5V: U36's own filtered rail (2.2 ohm, 220u, C36).",
                      "Ladder: 2k 1 % per bit + 2k termination, 1k between nodes (LAD7 = out).  AGND (GNDA) joins GND at the power input."],
         size=2.2)
    return s


def sheet_port(b):
    s = b.sheet("shared_port.kicad_sch", "Shared port", 10)
    heading(s, "Shared port x5200", "Two SNES pads, SD card (SPI), PS/2 keyboard and mouse: port PLD U38, PS/2 receiver PLD U42")
    s.label_each |= {"DATABUS"}
    # the inputs carry their names at each pin; U38's five outputs are wired to the pads, the SD
    # dividers and the PS/2 hold diodes (below)
    s.label_nets |= {"~{PORT_RD}", "~{PORT_WR}", "ADDR0", "ADDR1",
                     "PAD1_DATA", "PAD2_DATA", "SD_MISO", "KBD_CLK", "PS2_DATA", "RXCLK", "PS2_INH"}
    # U38 (port PLD rev 04): the output register (five bits) and the reads of MISO, the pads
    # and RXCLK while A1 = 0.  U42 (PS/2 receiver rev 02): one byte at x5202, ready at x5203.
    u38 = s.part("placard:ATF22V10C_PORT", "U38", 127.0, 121.92, pld({
        1: "~{PORT_WR}", 2: "~{PORT_RD}", 3: "ADDR0", 4: "DATABUS0", 5: "DATABUS1", 6: "DATABUS2", 7: "DATABUS3", 8: "DATABUS4",
        9: "PAD1_DATA", 10: "PAD2_DATA", 11: "RXCLK", 13: "SD_MISO", 14: "ADDR1", 15: None,
        16: "K0", 17: "P_PS2D", 18: "P_CS", 19: "P_MOSI", 20: "P_SCK", 21: "DATABUS5", 22: "DATABUS6", 23: "DATABUS7"}),
               bare=("16", "17", "18", "19", "20"))
    decap(s, 38, 147.32, 86.36, lift=0)
    s.part("placard:ATF22V10C_PS2", "U42", 127.0, 210.82, pld({
        1: "RXCLK", 2: "PS2_DATA", 3: "~{PORT_RD}", 4: "~{PORT_WR}", 5: "ADDR0", 6: "ADDR1",
        7: None, 8: None, 9: None, 10: None, 11: None, 13: None,
        14: "PS2_INH", 15: "DATABUS7", 16: "DATABUS0", 17: "DATABUS1", 18: "DATABUS2", 19: "DATABUS3", 20: "DATABUS4", 21: "DATABUS5", 22: "DATABUS6", 23: "DATABUS7"}))
    decap(s, 42, 147.32, 175.26, lift=0)
    vref = lambda x, y: dict(ref_at=(x + 2.0, y - 1.3), value_at=(x + 2.0, y + 1.5))
    # PS/2 keyboard and mouse, J5 a stacked dual socket: the keyboard CLK along the top row, DATA
    # (shared by both) along the middle row, the mouse CLK along the bottom row, each with its
    # 4.7k pull-up and the port diode that pulls it low (K0, P_PS2D, P_CS) above.  The two clock
    # lines also carry, at the left, the receiver's inhibit diode (PS2_INH, U42 pin 14, pulls both
    # low) and the diode-OR into RXCLK (22k to GND): the clock of whichever device is let go.
    yk, yd, yc = 177.8, 203.2, 233.68
    res(s, "R55", 243.84, yk - 3.81, "+5V", "KBD_CLK", "4.7k", bare=("2",), **vref(243.84, yk - 3.81))
    d6 = diode(s, "D6", 261.62, yk - 3.81, "K0", "KBD_CLK", angle=270, bare=("1", "2"), **vref(261.62, yk - 3.81))
    diode(s, "D19", 203.2, yk + 3.81, "PS2_INH", "KBD_CLK", angle=90, bare=("1", "2"), **vref(203.2, yk + 3.81))
    diode(s, "D1", 215.9, yk + 3.81, "RXCLK", "KBD_CLK", angle=90, bare=("1", "2"), **vref(215.9, yk + 3.81))
    xk = 284.48
    path(s, "KBD_CLK", (200.66, yk), (203.2, yk), (215.9, yk), (243.84, yk), (261.62, yk), (xk, yk))
    name(s, "KBD_CLK", 200.66, yk, 180)
    for x in (203.2, 215.9, 243.84, 261.62):
        s.junction(x, yk, owner="KBD_CLK")
    res(s, "R50", 243.84, yd - 3.81, "+5V", "PS2_DATA", "4.7k", bare=("2",), **vref(243.84, yd - 3.81))
    d3 = diode(s, "D3", 261.62, yd - 3.81, "P_PS2D", "PS2_DATA", angle=270, bare=("1", "2"), **vref(261.62, yd - 3.81))
    path(s, "PS2_DATA", (243.84, yd), (261.62, yd), (279.4, yd))
    name(s, "PS2_DATA", 243.84, yd, 180)
    s.junction(261.62, yd, owner="PS2_DATA")
    res(s, "R49", 243.84, yc - 3.81, "+5V", "MOUS_CLK", "4.7k", bare=("2",), **vref(243.84, yc - 3.81))
    d2 = diode(s, "D2", 261.62, yc - 3.81, "P_CS", "MOUS_CLK", angle=270, bare=("1", "2"), **vref(261.62, yc - 3.81))
    diode(s, "D5", 203.2, yc - 3.81, "PS2_INH", "MOUS_CLK", angle=270, bare=("1", "2"), **vref(203.2, yc - 3.81))
    diode(s, "D4", 215.9, yc - 3.81, "RXCLK", "MOUS_CLK", angle=270, bare=("1", "2"), **vref(215.9, yc - 3.81))
    path(s, "MOUS_CLK", (200.66, yc), (203.2, yc), (215.9, yc), (243.84, yc), (261.62, yc), (279.4, yc))
    name(s, "MOUS_CLK", 200.66, yc, 180)
    for x in (203.2, 215.9, 243.84, 261.62):
        s.junction(x, yc, owner="MOUS_CLK")
    # the inhibit and RXCLK run down between the two clock rows
    path(s, "PS2_INH", (203.2, yk + 7.62), (203.2, 205.74), (203.2, yc - 7.62))
    path(s, "PS2_INH", (203.2, 205.74), (195.58, 205.74))
    s.junction(203.2, 205.74, owner="PS2_INH")
    name(s, "PS2_INH", 195.58, 205.74, 180)
    path(s, "RXCLK", (215.9, yk + 7.62), (215.9, 210.82), (215.9, yc - 7.62))
    path(s, "RXCLK", (215.9, 210.82), (223.52, 210.82), (231.14, 210.82))
    s.junction(215.9, 210.82, owner="RXCLK")
    s.junction(223.52, 210.82, owner="RXCLK")
    res(s, "R60", 223.52, 214.63, "RXCLK", "GND", "22k", bare=("1",), **vref(223.52, 214.63))
    name(s, "RXCLK", 231.14, 210.82, 0)
    j5 = s.part("placard_parts:PS2_Dual_Stacked", "J5", 307.34, 218.44,
                {"B5": "KBD_CLK", "B1": "PS2_DATA", "A1": "PS2_DATA", "A5": "MOUS_CLK", "B6": None, "B2": None,
                 "A2": None, "A6": None, "A4": "+5V", "B4": "+5V", "A3": "GND", "B3": "GND", "SH": "GND"},
                value="PS/2 kbd + mouse", footprint="placard:PS2_Kycon_KMDGX-6S-6S-S4N", bare=("B5", "B1", "A1", "A5"))
    path(s, "KBD_CLK", (xk, yk), (xk, j5["B5"][1]), j5["B5"])
    path(s, "PS2_DATA", (279.4, yd), (279.4, j5["B1"][1]), j5["B1"])
    path(s, "PS2_DATA", (279.4, j5["B1"][1]), (279.4, j5["A1"][1]), j5["A1"])
    s.junction(279.4, j5["B1"][1], owner="PS2_DATA")
    path(s, "MOUS_CLK", (279.4, yc), (279.4, j5["A5"][1]), j5["A5"])
    # SD card: 1.8k / 3.3k dividers bring SCK, MOSI and /CS down to 3.2 V; CS and DI come in from above,
    # CLK from below; MISO (3.3 V, 10k pull-up) goes straight to U38 pin 13
    href = lambda x, y: dict(ref_at=(x - 3.0, y - 3.2), value_at=(x - 3.0, y + 3.4))
    div = {}
    for src, net, y, rs, rp, pin, xv in [("P_CS", "SD_CS", 134.62, "R44", "R47", 162.56, 345.44),
                                         ("P_MOSI", "SD_DI", 152.4, "R43", "R46", 165.1, 342.9),
                                         ("P_SCK", "SD_CLK", 190.5, "R42", "R45", 172.72, 342.9)]:
        div[src] = res(s, rs, 309.88, y, src, net, "1.8k", angle=90, bare=("1", "2"), **href(309.88, y))["1"]
        res(s, rp, 322.58, y + 3.81, net, "GND", "3.3k", bare=("1",), **vref(322.58, y + 3.81))
        path(s, net, (313.69, y), (322.58, y), (xv, y), (xv, pin), (350.52, pin))
        s.junction(322.58, y, owner=net)
    s.part("placard_std:SD_Card", "J4", 373.38, 170.18, {"1": "SD_CS", "2": "SD_DI", "3": "GND", "4": "+3V3", "5": "SD_CLK",
                                                        "6": "GND", "7": "SD_MISO", "8": None, "9": None, "10": None,
                                                        "11": None, "12": "GND", "13": "GND"}, value="SD (SPI)",
           footprint="placard:SD_Hirose_DM1AA_SF_PEJ82",
           bare=("1", "2", "5", "7"), ref_at=(353, 153), value_at=(353, 187))
    path(s, "SD_MISO", (350.52, 177.8), (345.44, 177.8), (345.44, 208.28), (353.06, 208.28), (360.68, 208.28))
    s.junction(353.06, 208.28, owner="SD_MISO")
    res(s, "R48", 353.06, 204.47, "+3V3", "SD_MISO", "10k", bare=("2",), ref_at=(355.1, 201.0), value_at=(355.1, 203.6))
    name(s, "SD_MISO", 360.68, 208.28, 0)
    # SNES pads at the right: J3 level with U38's SCK and MOSI pins, J2 above it.  DATA drops
    # below the pins to its 10k pull-up and goes back to U38 by name.
    jx = 388.62
    for ref, y, data, rp in [("J2", 66.04, "PAD1_DATA", "R40"), ("J3", 111.76, "PAD2_DATA", "R41")]:
        s.part("placard_parts:SNES_Pad_Socket", ref, jx, y, {"1": "+5V", "2": "P_SCK", "3": "P_MOSI", "4": data,
                                                           "5": None, "6": None, "7": "GND"}, value="SNES pad",
               footprint="placard:SNES_Pad_Socket_Horizontal",
               bare=("2", "3", "4"), value_at=(392.5, y + 17.0))
        yp = y + 15.24
        res(s, rp, 355.6, yp - 3.81, "+5V", data, "10k", bare=("2",), **vref(355.6, yp - 3.81))
        path(s, data, (373.38, y), (368.3, y), (368.3, yp), (355.6, yp), (345.44, yp))
        s.junction(355.6, yp, owner=data)
        name(s, data, 345.44, yp, 180)
    # U38's outputs, straight out to the right: K0, P_PS2D and P_CS drop to their hold diodes;
    # P_CS, P_MOSI and P_SCK to their SD dividers; P_MOSI and P_SCK on to J3 and up to J2
    sck, mosi, cs, ps2d, k0 = (u38[p] for p in ("20", "19", "18", "17", "16"))
    path(s, "K0", k0, (d6["1"][0], k0[1]), d6["1"])
    xd = 274.32
    path(s, "P_PS2D", ps2d, (xd, ps2d[1]), (xd, d3["1"][1] - 2.54), (d3["1"][0], d3["1"][1] - 2.54), d3["1"])
    xc, xsd = 276.86, {"P_SCK": 297.18, "P_MOSI": 299.72, "P_CS": 302.26}
    path(s, "P_CS", cs, (xc, cs[1]), (xsd["P_CS"], cs[1]))
    path(s, "P_CS", (xc, cs[1]), (xc, d2["1"][1] - 2.54), (d2["1"][0], d2["1"][1] - 2.54), d2["1"])
    s.junction(xc, cs[1], owner="P_CS")
    xup = {"P_SCK": 314.96, "P_MOSI": 317.5}
    for net, pin, dy in (("P_SCK", sck, -5.08), ("P_MOSI", mosi, -2.54)):
        path(s, net, pin, (xsd[net], pin[1]), (xup[net], pin[1]), (373.38, pin[1]))
        path(s, net, (xup[net], pin[1]), (xup[net], 66.04 + dy), (373.38, 66.04 + dy))
        s.junction(xsd[net], pin[1], owner=net)
        s.junction(xup[net], pin[1], owner=net)
    for net, pin in (("P_SCK", sck), ("P_MOSI", mosi), ("P_CS", cs)):
        path(s, net, (xsd[net], pin[1]), (xsd[net], div[net][1]), div[net])
    for k, (net, pin) in enumerate((("P_SCK", sck), ("P_MOSI", mosi), ("P_CS", cs), ("P_PS2D", ps2d), ("K0", k0))):
        name(s, net, pin[0] + 5.08 + 15.24 * k, pin[1], 0)     # staggered: the rows are 2.54 apart
    note(s, 15, 252, ["U38 register (rests at EB): bit 0 = SCK and pad CLOCK, bit 1 = MOSI and pad LATCH, bit 2 = SD /CS (low also holds the mouse CLK),",
                      "bit 3 = PS/2 DATA hold, bit 4 = K0 (low holds the keyboard CLK).  Reads x5200/x5201: D7 MISO or pad 1, D6 pad 2, D5 RXCLK.",
                      "U42 clocks on RXCLK (the free device's clock through D1/D4, 22k down) and holds the byte: read at x5202, ready = x5203 D7 low;",
                      "after the 11th clock it pulls both clocks low through D19/D5 until a write to x5202 re-arms it.  PS/2 DATA is shared by both sockets.",
                      "SD lines come down to 3.2 V through 1.8k / 3.3k; MISO (3.3 V) goes straight to the PLD's TTL input."],
         size=2.2)
    return s


def sheet_slots(b):
    s = b.sheet("expansion.kicad_sch", "Expansion slots", 11)
    heading(s, "Expansion slots", "Four 2 x 20 card-edge slots, x5100-x53FF, 128 bytes each (EXPANSION.md)")
    s.label_nets |= {"RW", "~{LOAD_IMM}", "~{WE}", "CLK", "RUN", "~{EXP1}", "~{EXP2}",
                     "STALL_IN", "STALL_OUT", "PC_ENABLE", "PIXEL_ENABLE", "~{CART}"}
    for k in range(4):
        ref = f"J{9 + k}"
        x, y = 110 + (k % 2) * 180, 105 + (k // 2) * 95     # two rows: the long bus labels need the width
        n = {"A1": "GND", "A2": "+5V"}
        for i in range(8):
            n[["A3", "B3", "A4", "B4", "A5", "B5", "A6", "B6"][i]] = D[i]
            n[["A13", "B13", "A14", "B14", "A15", "B15", "A16", "B16"][i]] = A[i]
        # BT1-BT8: slot 1's boot contacts (EXPANSION.md, "Booting from slot 1"); not connected on slots 2-4
        bt = ["STALL_IN", "STALL_OUT", "PC_ENABLE", "PIXEL_ENABLE", "~{CART}", None, None, None] if k == 0 else [None] * 8
        for i, net in enumerate(bt):
            n[["A8", "B8", "A9", "B9", "A10", "B10", "A11", "B11"][i]] = net
        n.update({"A17": "~{EXP1}" if k in (0, 2) else "~{EXP2}", "B17": f"SEL{k + 1}", "A18": "RW",
                  "B18": "~{LOAD_IMM}", "A19": "~{WE}", "B12": "CLK", "B19": "RUN"})
        j = s.part("placard_parts:Expansion_Slot", ref, x, y, n, value=f"Slot {k + 1}",
                   footprint="placard:CardEdge_2x20_P2.54mm_Vertical", ref_at=(x - 12, y - 32),
                   value_at=(x - 12, y + 32), bare=("B17",))
        # SEL: a 1k straight off the last pin to GND or +5V
        px, py = j["B17"]
        r = res(s, f"R{51 + k}", px + 7.62, py, f"SEL{k + 1}", "GND" if k < 2 else "+5V", "1k", angle=90, bare=("1",),
                ref_at=(px + 3.0, py + 5.5), value_at=(px + 3.0, py + 6.2))
        path(s, f"SEL{k + 1}", (px, py), r["1"])
    note(s, 30, 252, ["SEL: GND on slots 1 and 2, +5 V on slots 3 and 4 (through 1k): the A7 half the card answers.",
                      "/EXP1 goes to slots 1 and 3, /EXP2 to slots 2 and 4.  /RESET = RUN (low while the cartridge loads).",
                      "BT1-BT8 (boot contacts): slot 1 only, STALL_IN, STALL_OUT, PC_ENABLE, PIXEL_ENABLE, /CART; cards latch DATABUS7:0.",
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
        10: ["U38 port PLD, U42 PS/2 receiver", "J2-J5"],
        11: ["J9-J12 card-edge slots"],
    }
    for page, x, y, w, h in ROOT_BOXES:
        for i, ln in enumerate(contents[page]):
            s.text(ln, x + 3, y + 10 + i * 7, size=2.5)
    note(s, 20, 220, ["34 chips + U40 regulator (docs/CHIPS.md numbers; U24, U28, U30, U33, U34 are not used).",
                      "Decoupling: every chip's 100 nF Cn sits beside Un on its own sheet.",
                      "Power: +5V, GND, +3V3 (SD card), GNDA (audio, joined to GND on sheet 2).",
                      "The ROM cartridges are their own projects: kicad/cartridge_64k/, kicad/cartridge_32k/."], size=3)
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


# The cartridge slot's contacts (EXPANSION.md "ROM cartridge slot"; 2026-10-26: contacts follow the
# cartridge chips' pins so the autorouted cartridge boards fit; J8 on the main board uses the same
# names, except A5 = A15 and B10 = /CART).  Spares are None (no-connects).
CART_PINOUT = {"A1": "GND", "A2": "+5V",
               "A3": "ADDR14", "B3": "ADDR12", "A4": "ADDR7", "B4": "CLK", "A5": "~{CE_LO}", "B5": "STALL_OUT",
               "A6": "ADDR13", "B6": "RUN", "A7": "PIXEL_ENABLE", "B7": "ADDR6", "A8": "ADDR8", "B8": "PC_ENABLE",
               "A9": "ADDR9", "B9": "ADDR5", "B10": "GND",
               "B12": "STALL_IN", "A13": "ADDR11", "A14": "ADDR4", "A15": "ADDR3", "A16": "~{ROM_OE}", "B16": "~{CE_HI}",
               "A17": "ADDR2", "A18": "ADDR10", "A19": "ADDR1",
               "A22": "ADDR0", "B22": "DATABUS7", "A24": "DATABUS0", "A25": "DATABUS6", "A27": "DATABUS1", "B27": "DATABUS5", "A29": "DATABUS2",
               "A30": "DATABUS4", "A32": "DATABUS3"}
for _c in ["A10", "A12", "B13", "B14", "B15", "B17", "B18", "B19", "A20", "B20", "A23", "B23", "B24", "B25",
           "A26", "B26", "A28", "B28", "B29", "B30", "B32"]:     # the 21 spares
    CART_PINOUT[_c] = None


def build_cart(size):
    """The ROM cartridge, two boards (Justin, 2026-10-24): the 64K board (U1 loader PLD, U2/U3
    EEPROMs, U4/U5 SRAMs, /CE_LO for the lower pair and /CE_HI for the upper) and the 32K board
    (U1 loader PLD, U2 EEPROM, U3 SRAM, /CE tied to GND, so the 32K reads in both halves)."""
    proj = "cartridge_%dk" % size
    # the 64K board keeps the old one-board cartridge's root uuid (its symbols keep theirs too)
    root_uuid = K.det_uuid("cartridge" if size == 64 else proj, "root")
    s = K.Sheet(proj, proj + ".kicad_sch", "ROM cartridge, %dK" % size, 1, root_uuid, None, DATE)
    s.uid = root_uuid
    s.comment2 = "Cartridge chips U1-U%d (docs/CHIPS.md, ROM cartridge); decoupling Cn goes with Un" % (5 if size == 64 else 3)
    s.names = {"U1": "Loader PLD"}
    heading(s, "ROM cartridge, %dK" % size,
            ("Two EEPROMs copied into two SRAMs" if size == 64 else "One EEPROM copied into one SRAM") +
            " at power-up by the loader PLD (ROM.md, \"Loading the cartridge\")")
    cart = dict(CART_PINOUT, B16="~{CE_HI}" if size == 64 else None)
    s.label_each |= {"ADDR"}
    s.label_nets |= {"~{CE_LO}", "~{CE_HI}", "~{ROM_OE}", "~{EE_OE}", "~{SR_WE}"}
    # the loader lines run straight across from the connector to U1, whose pins are a row apart like the connector's
    ld = {"B4": "1", "A7": "3", "B8": "4", "B12": "5", "B5": "23", "B6": "22"}
    lab = ("A5", "B16", "A16") if size == 64 else ("A5", "A16")
    j1 = s.part("placard_parts:Cartridge_Slot", "J1", 82.55, 120, cart, value="Card edge (87715-9106 mate)",
                footprint="placard:Card_Edge_87715-9106", ref_at=(67, 69), value_at=(88, 176),
                bare=tuple(ld) + lab, in_bom=False)    # gold fingers on the cartridge PCB, not a part
    for c in lab:     # labels in a column, not staggered
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
    s.bus_piece("DATABUS", [(116.84, 43.18), (384.81, 43.18)])

    def mem(lib, ref, x, y, ce, oe, we, value, fp=None):
        n = {"20": ce, "22": oe, "27": we, "28": "+5V", "14": "GND"}
        for i, p in enumerate([10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2, 26, 1]):
            n[str(p)] = A[i]
        for i, p in enumerate([11, 12, 13, 15, 16, 17, 18, 19]):
            n[str(p)] = D[i]
        u = s.part(lib, ref, x, y, n, value=value, footprint=fp, bare=("20", "22", "27"))
        # /CE, /OE, /WE: labels in a column (not staggered), a tie to +5V or GND on an arm past them
        for pn in ("20", "22", "27"):
            px, py = u[pn]
            if n[pn] in ("+5V", "GND"):
                path(s, n[pn], (px, py), (px - 19.05, py))
                s.power(n[pn], px - 19.05, py, toward=(-1, 0))
            else:
                path(s, n[pn], (px, py), (px - 5.08, py))
                name(s, n[pn], px - 5.08, py, 180)
        decap(s, int(ref[1:]), x - 20.32, y - 38.1, lift=0)
    if size == 64:
        mem("placard_std:28C256", "U2", 270.51, 95.25, "~{CE_LO}", "~{EE_OE}", "+5V", "AT28C256-15PU", FP_DIP28W)
        mem("placard_std:28C256", "U3", 365.76, 95.25, "~{CE_HI}", "~{EE_OE}", "+5V", "AT28C256-15PU", FP_DIP28W)
        mem("placard_parts:AS7C256C", "U4", 267.97, 195.58, "~{CE_LO}", "~{ROM_OE}", "~{SR_WE}", "AS7C256C-15PCN")
        mem("placard_parts:AS7C256C", "U5", 363.22, 195.58, "~{CE_HI}", "~{ROM_OE}", "~{SR_WE}", "AS7C256C-15PCN")
        lines = ["U2 (lower 32K) and U3 (upper) hold the image,",
                 "programmed off the board; their /WE is tied high.",
                 "U4, U5 are the ROM the CPU reads (15 ns).",
                 "/CE_LO is the main board's A15; /CE_HI the upper",
                 "32K select.  The 32K cartridge is its own board",
                 "(kicad/cartridge_32k)."]
    else:
        # one EEPROM and one SRAM, always selected: the main board's /ROM_OE picks the ROM, and the
        # 32K is seen in both halves of the address space
        mem("placard_std:28C256", "U2", 270.51, 95.25, "GND", "~{EE_OE}", "+5V", "AT28C256-15PU", FP_DIP28W)
        mem("placard_parts:AS7C256C", "U3", 267.97, 195.58, "GND", "~{ROM_OE}", "~{SR_WE}", "AS7C256C-15PCN")
        lines = ["U2 holds the 32K image, programmed off the board;",
                 "its /WE is tied high.  U3 is the ROM the CPU",
                 "reads (15 ns).  Both /CE are tied to GND: the",
                 "32K is seen in both halves (x0000 = x8000), and",
                 "the loader copies it twice.  /CE_HI (B16) is",
                 "not used.  The 64K cartridge is its own board",
                 "(kicad/cartridge_64k)."]
    note(s, 22, 192, lines + [
                       "U1 stalls the CPU at each PC address",
                       "(STALL_OUT), pulses /SR_WE, lets the CPU",
                       "step, and raises RUN when the PC wraps.",
                       "/CART (B10) is tied to GND: cartridge present.",
                       "Spare contacts are unassigned (EXPANSION.md)."])
    s.finish(set())
    return s


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
        if outs and any(t in ("tri_state", "bidirectional") for t in types) and name not in ("DATABUS6", "DATABUS7"):
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
    hundreds.  U and J keep the CHIPS.md / IO.md numbers, and C1-C42 go with their chips,
    so the other capacitors start at C43 (C41, the bulk capacitor, came before U42 existed)."""
    got = {}
    for sh in sheets:
        for ref, _num, _net in sh.pin_nets:
            m = re.match(r"([A-Z]+)(\d+)$", ref)
            if m and m.group(1) not in ("U", "J"):
                got.setdefault(m.group(1), set()).add(int(m.group(2)))
    out = []
    for pre, nums in sorted(got.items()):
        if pre == "C":
            nums = {n for n in nums if n > 42 or n == 41} or nums
            nums.discard(41)
        first = 43 if pre == "C" and min(nums) > 42 else 1
        if nums != set(range(first, first + len(nums))):
            out.append(f"{label}: {pre} numbers are not {pre}{first}-{pre}{first + len(nums) - 1}: {sorted(nums)}")
    return out


def main():
    # keep every symbol's uuid from the files already there (Update PCB from Schematic matches on it)
    for d in (KDIR, *CDIRS.values()):
        for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if f.endswith(".kicad_sch"):
                K.keep_uuids(os.path.join(d, f))
    root, boxes, sheets, glob = build_main()
    for sh in sheets:
        write(os.path.join(KDIR, sh.filename), sh.render())
        for o in sh.overlaps():
            print("overlap", sh.filename, o)
        for r in sh.report:
            print("route", sh.filename, r)
    write(os.path.join(KDIR, "placard.kicad_sch"), root.render(extra=boxes))
    carts = {}
    for size, cdir in CDIRS.items():
        cart = carts[size] = build_cart(size)
        write(os.path.join(cdir, cart.filename), cart.render())
        for o in cart.overlaps():
            print("overlap", cart.filename, o)
        for r in cart.report:
            print("route", cart.filename, r)
    if "--pdf" in sys.argv:
        export_pdf(os.path.join(KDIR, "placard.kicad_sch"), os.path.join(ROOT, "schematics", "placard_main.pdf"))
        for size, cdir in CDIRS.items():
            export_pdf(os.path.join(cdir, carts[size].filename),
                       os.path.join(ROOT, "schematics", "placard_cartridge_%dk.pdf" % size))
    if "--check" in sys.argv:
        bad = compare(expected_nets(sheets, glob), kicad_nets(os.path.join(KDIR, "placard.kicad_sch")), "main board")
        for size, cdir in CDIRS.items():
            bad += compare(expected_nets([carts[size]], set()), kicad_nets(os.path.join(cdir, carts[size].filename)),
                           "cartridge %dK" % size)
        for path, label in [(os.path.join(KDIR, "placard.kicad_sch"), "main board"),
                            *[(os.path.join(cdir, carts[size].filename), "cartridge %dK" % size)
                              for size, cdir in CDIRS.items()]]:
            for it in erc(path, label, FLAGGED):
                print("  ", it)
        for shs, label in [(sheets, "main board"), ([carts[64]], "cartridge 64K"), ([carts[32]], "cartridge 32K")]:
            for it in check_refs(shs, label):
                print("  ", it)
                bad += 1
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
