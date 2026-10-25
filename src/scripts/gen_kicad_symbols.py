#!/usr/bin/env python3
"""
gen_kicad_symbols.py - make the KiCad symbol library kicad/lib/placard.kicad_sym:
one ATF22V10C symbol per PLD file in src/pld, with the pin names from its
PIN statements, plus a generic ATF22V10C.

    python3 gen_kicad_symbols.py              writes kicad/lib/placard.kicad_sym
    python3 gen_kicad_symbols.py out.kicad_sym

The symbols are drawn like the chip blocks in schematics/placard_io_schematic.png:
a cream box, pin names inside, pin numbers outside, VCC (24) on top and GND
(12) underneath, the reference above the box, the part number and the .pld
file under the GND pin.  Active-low pins (!NAME, or NAME_N) are named
/NAME, as in the drawings.

The pins are placed by LAYOUT below, not by pin number: inputs on the left
and outputs on the right, buses together and in bit order, and the pins of
each function in their own group.  Where one PLD does two unrelated jobs
(the audio PLD's /AC_SEL, the port PLD's pad read, the memory control's
RUN) a dashed line across the box separates them.  Pins a PLD does not
use are "nc" (no-connect type).  A .pld without a LAYOUT entry gets its
inputs on the left and outputs on the right in declaration order.

A pin is an output if the .pld has an equation for it (NAME = or NAME.D =);
an output with a .OE equation is 3-state, and a pin whose PIN comment says
"no external connection" is a no-connect pin.  Everything else is an input.
Rerun after changing a .pld's pins (and fix its LAYOUT entry: the script
stops if a pin is missing from it); the file is KiCad 7 format.

symbol() is also used by gen_kicad_parts.py for the other project symbols.

Date: 2026-10-25
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
PLD_DIR = os.path.join(ROOT, "src", "pld")
OUT = os.path.join(ROOT, "kicad", "lib", "placard.kicad_sym")

PART = "ATF22V10C-7PX"
# PLDs with enough timing margin for the slower -10 grade (CHIPS.md, "PLD speed grades")
PART_10 = "ATF22V10C-10PU"
# Empty since 2026-10-23: every PLD is a -7PX (Justin: one part number; the -10PU saved $0.36 a chip).
# Seven main-board PLDs and the cartridge's would fit the -10 grade; CHIPS.md lists them.
SLOW_OK = set()
FOOTPRINT = "placard:DIP-24_W7.62mm_Socket_Puller"   # socket, puller room, part number (gen_kicad_kit_footprints.py)
DATASHEET = "https://ww1.microchip.com/downloads/en/DeviceDoc/doc0735.pdf"
G = 2.54                       # pin pitch and pin length (100 mil)
FILL = "(fill (type color) (color 255 248 225 1))"   # the drawings' chip colour #FFF8E1
CHAR_W = 1.7                   # width of one 1.8 mm pin-name character, with a little to spare
MIN_W = 3 * 2 * G              # 15.24 mm

SEP = "---"                    # in a layout: a dashed line between unrelated functions

# Pin placement per .pld file: a list of blocks, each (left, right) with the
# .pld pin names (no "!") top to bottom; None is an empty row inside a block,
# "nc" is every unused pin.  Blocks are one empty row apart; SEP between two
# blocks draws a dashed line in that row.
LAYOUT = {
    "ALU_SHR": [
        (["CIN", None, "A0", "A1", "A2", "A3", "SHIFT_RIGHT_IN", None, "B0", "B1", "B2", "B3", None, "S0", "S1", "S2"],
         [None, None, "F0", "F1", "F2", "F3", None, None, "Z", None, None, None, None, "nc", None, "COUT"]),
    ],
    "ATF22V10_AUDIO": [
        (["H3", "H4", "H5", "H6", "H7", "H8", "H9", None,
          "V0", "V1", "V7", "V8", "V9", None, "LC2", None, "LC3"],
         ["R0", "R1", "R7", "R8", None, "MODE_LD", None, "BLANK_RD"]),
        SEP,
        (["I1"], ["AC_SEL"]),
    ],
    "ATF22V10_BRANCH": [
        (["I7", "I6", "I5", None, "M2", "M1", "M0", None, "Z_LOW", "Z_HIGH", "NEG"],
         ["BRANCH_BLOCK", None, "LOAD_PC_LOW", "LOAD_PC_HIGH"]),
        (["CLK", "Q0", "PC_ENABLE", "PIXEL_ENABLE"], ["STALL", "SRC_EN", "PIX_LD", "ALU_DONE"]),
        (["COUT"], ["CARRY"]),
    ],
    "ATF22V10_COLORDECODER": [
        (["D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7", None, "MODE0", "MODE1", None,
          "H0", "H1", "H2", None, "VIDEN"],
         ["RED1", "RED2", "RED3", None, "GRN1", "GRN2", "GRN3", None, "BLU2", "BLU3"]),
    ],
    "ATF22V10_HCOUNT": [
        (["H0", "H1", "H2", None, "LC7", None, "CLK", "RESET"],
         ["H3", "H4", "H5", "H6", "H7", "H8", "H9", None, "HSYNC", None, "H_VIDEO_ACTIVE", None, "H_TC"]),
        (["nc"], []),
    ],
    "ATF22V10_IO_DECODE": [
        (["ADDR_SEL", "ADDR_SEL_HI", "PC15", "H9", "Y7"], ["MAP_WR", None, "CE_HI"]),
        (["A14", "A13", "A12", "A11", "A10", "A9", "A8", None, "RW", "LOAD_IMM", "WE_N"],
         ["LINE_RD", None, "PORT_WR", None, "PORT_RD", None, "EXP1", None, "EXP2"]),
    ],
    "ATF22V10_MEM_CTRL": [
        (["A15", "A14", "A13", "A12", "A11", "A10", None,
          "RAMSEL0", "RAMSEL1", "RAMSEL2", "RAMSEL3", "RAMSEL4", "RAMSEL5", "RAMSEL6", "RAMSEL7",
          None, "RW", None, "PIXEL_ENABLE", None, "SRC_EN"],
         ["ROM_OE", "RAM_OE", "WE"]),
        SEP,
        (["CLK", None, "RUN"], []),
    ],
    "ATF22V10_CART": [
        # the loader pins line up with the cartridge connector's, a row apart
        (["CLK", None, "PIXEL_ENABLE", None, "PC_ENABLE", None, "STALL_IN", None, "STALL_OUT", None, "RUN",
          None, "A15"],
         ["EE_OE", None, "SR_WE"]),
        (["nc"], []),
    ],
    "ATF22V10_IR": [
        (["D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7", None, "LOAD_INSTR", "RUN", None, "CLK"],
         ["I0", "I1", "I2", "I3", "I4", "I5", "I6", "I7"]),
        (["nc"], []),
    ],
    "ATF22V10_PC_COUNTER8": [
        (["CIN", None, "D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7", None,
          "LOAD", "EN", "PIXEL_ENABLE", None, "CLK"],
         [None, None, "Q0", "Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Q7", None, None, None, None, None, "CO"]),
    ],
    "ATF22V10_PORT": [
        # the output register (was the 74HC574 latch) above, the reads (was the 74F541) below
        (["PORT_WR", None, "D0", "D1", "D2", "D3", "D4"],
         [None, None, "SCKN", "MOSIN", "SDCS", "DHOLD", "K0"]),
        SEP,
        (["PORT_RD", "A0", "A1", None, "MISO", "PAD1", "PAD2", "RXCLK"], [None, None, None, None, None, "D5", "D6", "D7"]),
        (["nc"], []),
    ],
    "ATF22V10_PS2": [
        # the byte pins in bus order (N8 = d0 at the top), then the ready flag and the inhibit
        (["RXCLK", "PDATA", None, "PORT_RD", "PORT_WR", "A0", "A1"],
         ["N8", "N7", "N6", "N5", "N4", "N3", "N2", "N1", None, "A", None, "B"]),
        (["nc"], []),
    ],
    "ATF22V10_QUAD_MUX": [
        (["S0", "S1"], []),
        (["A0", "A1", "A2", "A3", None, "B0", "B1", "B2", "B3", None,
          "C0", "C1", "C2", "C3", None, "D0", "D1", "D2", "D3"],
         [None] * 15 + ["Y0", "Y1", "Y2", "Y3"]),
    ],
    "ATF22V10_STATE": [
        (["CLK", "PIXEL_ENABLE", "BRANCH_BLOCK", None, "MEM2", "MEM1", "MEM0", "SRC0", None,
          "DB_MEM2", "DB_MEM1", "DB_MEM0", "DB_SRC1", "DB_SRC0"],
         ["Q0", "Q1", None, "X_ENABLE", "Y_ENABLE", None,
          "LOAD_INSTR", "LOAD_IMM", "LOAD_AC", "LOAD_X", "LOAD_Y", "MEM_WR"]),
    ],
    "ATF22V10_SYNC": [
        (["CLK", None, "H_VIDEO_ACTIVE", None, "BLANK_RD", None, "V9", "V5", "V4", "V3", "V2", "V1"],
         ["H0", "H1", "H2", None, "VIDEN", None, "PIXEL_ENABLE", None, "VSYNC", "V_VIDEO_ACTIVE"]),
        (["PC_ENABLE", None, "X_ENABLE", None, "Y_ENABLE"], ["ADDR_SEL", None, "ADDR_SEL_HI", None, "ADDR_SEL_LO"]),
    ],
    "ATF22V10_VCOUNT": [
        (["EN", None, "CLK"], ["Q0", "Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Q7", "Q8", "Q9"]),
        (["nc"], []),
    ],
}


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", " ", text, flags=re.S)


def parse_pld(path):
    """Returns the header fields and the pins as (number, pld name, shown name, kind)."""
    raw = open(path, encoding="latin-1").read()
    head = {}
    for key, val in re.findall(r"(?m)^(Name|Date|Revision)[ \t]+([^;\n]*);", raw):
        head.setdefault(key, val)               # the header, not later notes
    body = strip_comments(raw)
    unwired = {int(n) for n in re.findall(
        r"(?im)^\s*PIN\s+(\d+)\s*=[^;]*;[^\n]*no external connection", raw)}
    pins = []                                   # (number, name, active_low), in declaration order
    for num, bang, name in re.findall(r"(?im)^\s*PIN\s+(\d+)\s*=\s*(!?)\s*(\w+)\s*;", body):
        pins.append((int(num), name, bool(bang)))
    eqs = body
    eqs = re.sub(r"(?im)^\s*PIN\s+.*$", "", eqs)

    def has_eq(name, ext=r"(\.\w+)?"):
        return re.search(r"(?im)^\s*!?\s*%s%s\s*=" % (re.escape(name), ext), eqs) is not None

    out = []
    for num, name, low in pins:
        kind = "input"
        if has_eq(name):
            kind = "tri_state" if has_eq(name, r"\.oe") else "output"
        shown = name
        if shown.upper().endswith("_N"):
            shown, low = shown[:-2], True
        shown = ("/" if low else "") + shown
        if num in unwired:
            kind, shown = "no_connect", "nc"    # an internal node, e.g. ALU_SHR carry nodes
        out.append((num, name, shown, kind))
    return head, out


def fmt(v):
    return ("%.4f" % v).rstrip("0").rstrip(".")


def pin(kind, x, y, rot, name, num, hide=False, length=G):
    return ('      (pin %s line (at %s %s %d) (length %s)%s\n'
            '        (name "%s" (effects (font (size 1.8 1.8))))\n'
            '        (number "%s" (effects (font (size 1.5 1.5))))\n'
            '      )\n' % (kind, fmt(x), fmt(y), rot, fmt(length), " hide" if hide else "", name, num))


def pins_at(entry, x, y, rot, length=G):
    """entry: (number, name, kind), or a list of them stacked on one spot
    (the first one shown, the others hidden, as KiCad's connectors do)."""
    if isinstance(entry, list):
        return "".join(pin(k, x, y, rot, n, num, i > 0, length) for i, (num, n, k) in enumerate(entry))
    num, name, kind = entry
    return pin(kind, x, y, rot, name, num, length=length)


def entry_name(entry):
    return entry[0][1] if isinstance(entry, list) else entry[1]


def prop(name, value, x, y, effects):
    return ('    (property "%s" "%s" (at %s %s 0)\n      (effects %s)\n    )\n'
            % (name, value, fmt(x), fmt(y), effects))


def symbol(sym, blocks, part, desc, keywords, footprint=FOOTPRINT, datasheet=DATASHEET,
           vcc=(24, "VCC"), gnd=(12, "GND"), ref="U", note=None, min_w=MIN_W, pin_len=G):
    """Draws one symbol.

    blocks: list of (left, right) with entries (number, name, kind), a list of
    such entries stacked on one spot, or None for an empty row; SEP between
    two blocks draws a dashed line.  vcc / gnd: (number, name) or a list of
    them (stacked), the pin in the middle of the top / bottom; None for none.
    note: an extra line under the part number (the PLD's file name).
    pin_len: 2 * G for pin numbers like A13 (the card-edge slots)."""
    rows_l, rows_r, seps = [], [], []
    for i, b in enumerate(blocks):
        if b == SEP:
            continue
        if rows_l:                                     # one empty row between blocks
            if i > 0 and blocks[i - 1] == SEP:
                seps.append(len(rows_l))
            rows_l.append(None)
            rows_r.append(None)
        left, right = b
        n = max(len(left), len(right))
        rows_l += list(left) + [None] * (n - len(left))
        rows_r += list(right) + [None] * (n - len(right))
    n = len(rows_l)
    lw = max([len(entry_name(p)) for p in rows_l if p] + [0])
    rw = max([len(entry_name(p)) for p in rows_r if p] + [0])
    w = (lw + rw) * CHAR_W + 2 * G
    # the VCC and GND names run down / up the middle: keep the names of the
    # rows they reach (two at each end) clear of them
    ends = [p for p in rows_l[:2] + rows_l[-2:] + rows_r[:2] + rows_r[-2:] if p]
    w = max([w] + [2 * (len(entry_name(p)) * CHAR_W + 2) for p in ends])
    w = max(min_w, int(-(-w // (2 * G))) * 2 * G)     # whole 200 mil steps, so the pins are on grid
    h = (n + 1) * G
    x0, x1 = -w / 2, w / 2
    y0 = G * ((n + 1) // 2)                            # top edge, on grid
    y1 = y0 - h
    s = ['  (symbol "%s" (in_bom yes) (on_board yes)\n' % sym]
    s.append(prop("Reference", ref, x0, y0 + 0.8,
                  "(font (size 1.524 1.524) bold) (justify left bottom)"))
    s.append(prop("Value", part, x0, y1 - pin_len - 0.8, "(font (size 1.27 1.27)) (justify left top)"))
    s.append(prop("Footprint", footprint, 0, 0, "(font (size 1.27 1.27)) hide"))
    s.append(prop("Datasheet", datasheet, 0, 0, "(font (size 1.27 1.27)) hide"))
    if note:
        s.append(prop("PLD", note, x0, y1 - pin_len - 3.0,
                      "(font (size 1.27 1.27) italic) (justify left top)"))
    s.append(prop("ki_keywords", keywords, 0, 0, "(font (size 1.27 1.27)) hide"))
    s.append(prop("ki_description", desc, 0, 0, "(font (size 1.27 1.27)) hide"))
    s.append('    (symbol "%s_0_1"\n'
             '      (rectangle (start %s %s) (end %s %s)\n'
             '        (stroke (width 0.254) (type default))\n        %s\n      )\n'
             % (sym, fmt(x0), fmt(y0), fmt(x1), fmt(y1), FILL))
    for r in seps:
        y = y0 - G * (r + 1)
        s.append('      (polyline\n        (pts (xy %s %s) (xy %s %s))\n'
                 '        (stroke (width 0.254) (type dash))\n        (fill (type none))\n      )\n'
                 % (fmt(x0), fmt(y), fmt(x1), fmt(y)))
    s.append('    )\n')
    s.append('    (symbol "%s_1_1"\n' % sym)
    for i, e in enumerate(rows_l):
        if e:
            s.append(pins_at(e, x0 - pin_len, y0 - G * (i + 1), 0, pin_len))
    for i, e in enumerate(rows_r):
        if e:
            s.append(pins_at(e, x1 + pin_len, y0 - G * (i + 1), 180, pin_len))
    px = 0
    for p, y, rot in ((vcc, y0 + pin_len, 270), (gnd, y1 - pin_len, 90)):
        if p:
            stack = p if isinstance(p, list) else [p]
            s.append(pins_at([(num, name, "power_in") for num, name in stack], px, y, rot, pin_len))
    s.append('    )\n  )\n')
    return "".join(s)


def default_layout(pins):
    return [([p[1] for p in pins if p[3] == "input"], [p[1] for p in pins if p[3] != "input"]),
            (["nc"], [])]


def pld_symbol(path):
    head, pins = parse_pld(path)
    fname = os.path.basename(path)
    stem = os.path.splitext(fname)[0]
    sym = "ATF22V10C_" + re.sub(r"^ATF22V10_", "", stem)
    by_name = {p[1]: (p[0], p[2], p[3]) for p in pins if p[3] != "no_connect"}
    used = {p[0] for p in pins}
    spare = [(p[0], p[2], p[3]) for p in pins if p[3] == "no_connect"]
    spare += [(n, "nc", "no_connect") for n in list(range(1, 12)) + list(range(13, 24))
              if n not in used]
    spare.sort()
    placed = []

    def resolve(names):
        out = []
        for nm in names:
            if nm is None:
                out.append(None)
            elif nm == "nc":
                out += spare
                placed.extend(p[0] for p in spare)
            else:
                if nm not in by_name:
                    sys.exit("%s: LAYOUT names %s, which is not a pin" % (fname, nm))
                out.append(by_name[nm])
                placed.append(by_name[nm][0])
        return out

    blocks = []
    for b in LAYOUT.get(stem) or default_layout(pins):
        blocks.append(b if b == SEP else (resolve(b[0]), resolve(b[1])))
    blocks = [b for b in blocks if b == SEP or b[0] or b[1]]
    missing = sorted(set(range(1, 24)) - {12} - set(placed))
    if missing or len(placed) != len(set(placed)):
        sys.exit("%s: LAYOUT leaves out pins %s or places one twice" % (fname, missing))
    desc = "ATF22V10C programmed with %s (Name %s), 24-pin 300 mil DIP" % (
        fname, head.get("Name", "").strip())
    part = PART_10 if stem in SLOW_OK else PART
    return sym, symbol(sym, blocks, part, desc, "PLD GAL 22V10 Placard " + stem, note=fname)


def generic_symbol():
    left = [(1, "CLK/I0", "input")] + [(n, "I%d" % (n - 1), "input") for n in range(2, 12)] + [(13, "I11", "input")]
    right = [(n, "IO%d" % (n - 14), "bidirectional") for n in range(14, 24)]
    desc = "ATF22V10C, 22V10 PLD, 12 inputs (pin 1 is also the register clock), 10 I/O macrocells, 300 mil DIP-24"
    return symbol("ATF22V10C", [(left, right)], PART, desc, "PLD GAL 22V10")


def write_lib(out, parts):
    with open(out, "w", newline="\n") as fh:
        fh.write("(kicad_symbol_lib (version 20220914) (generator gen_kicad_symbols)\n")
        fh.write("".join(parts))
        fh.write(")\n")
    print("wrote", os.path.normpath(out))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    parts = [generic_symbol()]
    for f in sorted(os.listdir(PLD_DIR)):
        if f.lower().endswith(".pld"):
            name, text = pld_symbol(os.path.join(PLD_DIR, f))
            parts.append(text)
            print(name)
    write_lib(out, parts)


if __name__ == "__main__":
    main()
