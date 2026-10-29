#!/usr/bin/env python3
"""
gen_kicad_kit_footprints.py - kit-builder versions of KiCad's DIP socket and
axial resistor footprints, written to kicad/lib/placard.pretty.

    python3 gen_kicad_kit_footprints.py

Each one is the stock KiCad footprint with assembly help added (Justin,
2026-10-23):

- DIP-nn_W7.62mm_Socket_Puller (and the 15.24 mm wide DIP-28): the stock
  "_Socket" footprint (socket body outline and courtyard) plus
  - two hatched boxes on User.Eco1 reaching PULL mm past each end of the
    socket body: room for a chip puller's hooks.  Keep other parts out of
    them (gen_kicad_pcb.py checks this);
  - the part number (${VALUE}) in silkscreen down the middle of the socket,
    between the pin rows, so the builder sees which chip goes where.
- R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal_Value: the stock
  resistor footprint plus its value (${VALUE}) in silkscreen in the middle
  of the body outline.

Needs KiCad 7's stock footprints (apt-get install kicad-footprints, or set
KICAD7_FOOTPRINT_DIR).  Their 3D models are copies in kicad/lib/placard.3dshapes
(gen_kicad_stock_footprints.py, run after this).

Date: 2026-10-26
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib", "placard.pretty"))
STOCK = os.environ.get("KICAD7_FOOTPRINT_DIR", "/usr/share/kicad/footprints")

MODELS = "${PLACARD_LIB}/placard.3dshapes"   # PLACARD_LIB: text variable in each .kicad_pro
PULL = 2.5                   # puller room past each socket end, mm

DIPS = [("DIP-14_W7.62mm_Socket", 14, 7.62), ("DIP-20_W7.62mm_Socket", 20, 7.62),
        ("DIP-24_W7.62mm_Socket", 24, 7.62), ("DIP-28_W7.62mm_Socket", 28, 7.62),
        ("DIP-28_W15.24mm_Socket", 28, 15.24)]
RES = "R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal"


def f(v):
    return ("%.3f" % v).rstrip("0").rstrip(".")


def line(x1, y1, x2, y2, layer, w):
    return '  (fp_line (start %s %s) (end %s %s) (layer "%s") (width %s))\n' % (
        f(x1), f(y1), f(x2), f(y2), layer, f(w))


def silk_text(s, x, y, angle, size, thick):
    return ('  (fp_text user "%s" (at %s %s %s) (layer "F.SilkS")\n'
            '    (effects (font (size %s %s) (thickness %s)))\n  )\n') % (
        s, f(x), f(y), f(angle), f(size), f(size), f(thick))


def fab_box(src):
    """Bounding box of the F.Fab lines: the socket body or resistor body."""
    xs, ys = [], []
    for m in re.finditer(r'\(fp_line \(start ([-\d.]+) ([-\d.]+)\) \(end ([-\d.]+) ([-\d.]+)\) \(layer "F.Fab"\)', src):
        x1, y1, x2, y2 = map(float, m.groups())
        xs += [x1, x2]
        ys += [y1, y2]
    return min(xs), min(ys), max(xs), max(ys)


def derive(lib, stock, name, descr, extra, ref_at=None):
    src = open(os.path.join(STOCK, lib + ".pretty", stock + ".kicad_mod")).read()
    out = src.replace('(footprint "%s"' % stock, '(footprint "%s"' % name, 1)
    out = re.sub(r'\(descr "([^"]*)"\)', lambda m: '(descr "%s; %s")' % (m.group(1), descr), out, count=1)
    out = re.sub(r'\(fp_text value "[^"]*"', '(fp_text value "%s"' % name, out, count=1)
    out = re.sub(r'\(tedit [0-9A-Fa-f]+\)\n', '', out)
    # the 3D model is KiCad's, copied into the project by gen_kicad_stock_footprints.py
    out, n = re.subn(r'\(model "[^"]+"', '(model "%s/%s.step"' % (MODELS, name), out)
    assert n == 1, name
    if ref_at:
        out = re.sub(r'\(fp_text reference "REF\*\*" \(at [-\d.]+ [-\d.]+\)',
                     '(fp_text reference "REF**" (at %s %s)' % (f(ref_at(src)[0]), f(ref_at(src)[1])), out, count=1)
    i = out.index("  (pad ")
    out = out[:i] + extra(src) + out[i:]
    with open(os.path.join(OUT, name + ".kicad_mod"), "w", newline="\n") as fh:
        fh.write(out)
    print("wrote", name)


def dip_extra(pins, row):
    def extra(src):
        x0, y0, x1, y1 = fab_box(src)
        s = ""
        for ya, yb in [(y0 - PULL, y0), (y1, y1 + PULL)]:
            for a, b, c, d in [(x0, ya, x1, ya), (x1, ya, x1, yb), (x1, yb, x0, yb), (x0, yb, x0, ya)]:
                s += line(a, b, c, d, "Eco1.User", 0.1)
            n = int(round((x1 - x0) / 1.0))
            for k in range(1, n):          # hatch across the box
                x = x0 + (x1 - x0) * k / n
                s += line(x, ya, x, yb, "Eco1.User", 0.05)
        length = (pins // 2 - 1) * 2.54
        size = 1.5 if row > 10 else 1.27
        s += silk_text("${VALUE}", row / 2, length / 2, 90, size, 0.2)
        return s
    return extra


def res_extra(src):
    x0, y0, x1, y1 = fab_box(src)
    # the leads are F.Fab lines too: use the body only (its outline is the 2.5 mm tall part)
    xs = [float(m.group(1)) for m in re.finditer(r'\(fp_line \(start ([-\d.]+) -1.25\)', src)]
    xs += [float(m.group(1)) for m in re.finditer(r'\(end ([-\d.]+) -1.25\)', src)]
    return silk_text("${VALUE}", (min(xs) + max(xs)) / 2, 0, 0, 1.0, 0.15)


def main():
    for stock, pins, row in DIPS:
        derive("Package_DIP", stock, stock + "_Puller",
               "with chip-puller room on User.Eco1 (%g mm past each end) and the part number in silkscreen "
               "(PLACARD kit)" % PULL, dip_extra(pins, row),
               ref_at=lambda src: (row / 2, fab_box(src)[1] - PULL - 1.2))   # reference above the puller room
    derive("Resistor_THT", RES, RES + "_Value", "with the value in silkscreen on the body (PLACARD kit)", res_extra)


if __name__ == "__main__":
    main()
