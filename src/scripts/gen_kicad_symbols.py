#!/usr/bin/env python3
"""
gen_kicad_symbols.py - make the KiCad symbol library kicad/lib/placard.kicad_sym:
one ATF22V10C symbol per PLD file in src/pld, with the pin names from its
PIN statements, plus a generic ATF22V10C.

    python3 gen_kicad_symbols.py              writes kicad/lib/placard.kicad_sym
    python3 gen_kicad_symbols.py out.kicad_sym

The symbols are drawn like the chip blocks in schematics/placard_io_schematic.png:
a cream box, inputs on the left and outputs on the right in the order the .pld
declares them, pin names inside, pin numbers outside, VCC (24) on top, GND (12)
underneath, unused pins as "nc" at the bottom of the left side, the part
number above the box on the right and the .pld file under it.  Active-low
pins (!NAME, or NAME_N) are named /NAME, as in the drawings.

A pin is an output if the .pld has an equation for it (NAME = or NAME.D =);
an output with a .OE equation is 3-state, and a pin whose PIN comment says
"no external connection" is a no-connect pin.  Everything else is an input.
Rerun after changing a .pld's pins; the file is KiCad 7 format.

Date: 2026-10-19
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
SLOW_OK = {"ATF22V10_PC_COUNTER8", "ATF22V10_HCOUNT", "ATF22V10_VCOUNT",
           "ATF22V10_COLORDECODER"}    # the audio PLD is -7 since rev 04 (/AC_SEL)
FOOTPRINT = "Package_DIP:DIP-24_W7.62mm"
DATASHEET = "https://ww1.microchip.com/downloads/en/DeviceDoc/doc0735.pdf"
G = 2.54                       # pin pitch and pin length (100 mil)
FILL = "(fill (type color) (color 255 248 225 1))"   # the drawings' chip colour #FFF8E1
CHAR_W = 1.05                  # rough width of one 1.27 mm character


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", " ", text, flags=re.S)


def parse_pld(path):
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
        if num in unwired:
            kind = "no_connect"                 # an internal node, e.g. ALU_SHR carry nodes
        if name.upper().endswith("_N"):
            name, low = name[:-2], True
        out.append((num, ("/" if low else "") + name, kind))
    return head, out


def pin(kind, x, y, rot, name, num):
    return ('      (pin %s line (at %s %s %d) (length %s)\n'
            '        (name "%s" (effects (font (size 1.27 1.27))))\n'
            '        (number "%s" (effects (font (size 1.27 1.27))))\n'
            '      )\n' % (kind, fmt(x), fmt(y), rot, fmt(G), name, num))


def fmt(v):
    return ("%.4f" % v).rstrip("0").rstrip(".")


def symbol(sym, left, right, pld_text, desc, keywords, part=PART):
    """left/right: lists of (number, name, kind)."""
    n = max(len(left), len(right))
    lw = max([len(p[1]) for p in left] + [1])
    rw = max([len(p[1]) for p in right] + [1])
    w = (lw + rw) * CHAR_W + 4 * G
    w = max(w, 2 * (len(part) * CHAR_W + 2))           # the part number clears the VCC pin
    w = max(6, int(-(-w // (2 * G)))) * 2 * G          # whole 200 mil steps, so the centre is on grid
    h = (n + 1) * G
    x0, x1 = -w / 2, w / 2
    y0 = G * ((n + 1) // 2)                            # top edge, on grid
    y1 = y0 - h
    s = ['  (symbol "%s" (in_bom yes) (on_board yes)\n' % sym]
    s.append('    (property "Reference" "U" (at %s %s 0)\n'
             '      (effects (font (size 1.524 1.524) bold) (justify left bottom))\n    )\n'
             % (fmt(x0), fmt(y0 + 0.6)))
    s.append('    (property "Value" "%s" (at %s %s 0)\n'
             '      (effects (font (size 1.27 1.27)) (justify right bottom))\n    )\n'
             % (part, fmt(x1), fmt(y0 + 0.6)))
    s.append('    (property "Footprint" "%s" (at 0 0 0)\n'
             '      (effects (font (size 1.27 1.27)) hide)\n    )\n' % FOOTPRINT)
    s.append('    (property "Datasheet" "%s" (at 0 0 0)\n'
             '      (effects (font (size 1.27 1.27)) hide)\n    )\n' % DATASHEET)
    if pld_text:
        s.append('    (property "PLD" "%s" (at 0 %s 0)\n'
                 '      (effects (font (size 1.27 1.27) italic))\n    )\n' % (pld_text, fmt(y1 - G - 2.2)))
    s.append('    (property "ki_keywords" "%s" (at 0 0 0)\n'
             '      (effects (font (size 1.27 1.27)) hide)\n    )\n' % keywords)
    s.append('    (property "ki_description" "%s" (at 0 0 0)\n'
             '      (effects (font (size 1.27 1.27)) hide)\n    )\n' % desc)
    s.append('    (symbol "%s_0_1"\n'
             '      (rectangle (start %s %s) (end %s %s)\n'
             '        (stroke (width 0.254) (type default))\n        %s\n      )\n    )\n'
             % (sym, fmt(x0), fmt(y0), fmt(x1), fmt(y1), FILL))
    s.append('    (symbol "%s_1_1"\n' % sym)
    for i, (num, name, kind) in enumerate(left):
        s.append(pin(kind, x0 - G, y0 - G * (i + 1), 0, name, num))
    for i, (num, name, kind) in enumerate(right):
        s.append(pin(kind, x1 + G, y0 - G * (i + 1), 180, name, num))
    s.append(pin("power_in", 0, y0 + G, 270, "VCC", 24))
    s.append(pin("power_in", 0, y1 - G, 90, "GND", 12))
    s.append('    )\n  )\n')
    return "".join(s)


def pld_symbol(path):
    head, pins = parse_pld(path)
    fname = os.path.basename(path)
    stem = os.path.splitext(fname)[0]
    sym = "ATF22V10C_" + re.sub(r"^ATF22V10_", "", stem)
    used = {p[0] for p in pins}
    left = [p for p in pins if p[2] == "input"]
    right = [p for p in pins if p[2] != "input"]
    left += [(n, "nc", "input") for n in list(range(1, 12)) + list(range(13, 24)) if n not in used]
    rev = head.get("Revision", "").strip()
    date = head.get("Date", "").strip()
    pld_text = fname + (" rev " + rev if rev else "")
    desc = "ATF22V10C programmed with %s (Name %s, revision %s, %s), 24-pin 300 mil DIP" % (
        fname, head.get("Name", "").strip(), rev, date)
    part = PART_10 if stem in SLOW_OK else PART
    return sym, symbol(sym, left, right, pld_text, desc, "PLD GAL 22V10 Placard " + stem, part)


def generic_symbol():
    left = [(1, "CLK/I0", "input")] + [(n, "I%d" % (n - 1), "input") for n in range(2, 12)] + [(13, "I11", "input")]
    right = [(n, "IO%d" % (n - 14), "bidirectional") for n in range(14, 24)]
    desc = "ATF22V10C, 22V10 PLD, 12 inputs (pin 1 is also the register clock), 10 I/O macrocells, 300 mil DIP-24"
    return symbol("ATF22V10C", left, right, None, desc, "PLD GAL 22V10")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    parts = [generic_symbol()]
    for f in sorted(os.listdir(PLD_DIR)):
        if f.lower().endswith(".pld"):
            name, text = pld_symbol(os.path.join(PLD_DIR, f))
            parts.append(text)
            print(name)
    with open(out, "w", newline="\n") as fh:
        fh.write("(kicad_symbol_lib (version 20220914) (generator gen_kicad_symbols)\n")
        fh.write("".join(parts))
        fh.write(")\n")
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    main()
