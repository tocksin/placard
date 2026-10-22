#!/usr/bin/env python3
"""
gen_kicad_keyswitch.py - make the keyboard's key switch footprints in
kicad/lib/placard.pretty/: Cherry MX, PCB mount (5 pin), with the two holes
for an optional 3 mm LED, one footprint per keycap size the layout uses.

    python3 gen_kicad_keyswitch.py

Each is KiCad's Button_Switch_Keyboard:SW_Cherry_MX_<size>_PCB with the LED
pads added, and the origin moved to the middle of the switch so the keys
sit on a 19.05 mm grid.  Pads 1 and 2 are the switch, 3 the LED cathode
(square) and 4 the anode, matching the Switch:SW_Push_LED symbol.  The LED
holes are 2.54 mm apart, 5.08 mm below the middle (Cherry MX LED position);
leave the LED and its resistor out for a plain key.

2 u and longer get the Cherry PCB-mount stabilizer holes (3.05 mm at the
top, 3.988 mm at the bottom): 11.9 mm either side for 2 u and 2.25 u,
50 mm for the 6.25 u space bar.  docs/IO.md "Keyboard" lists the keys.

Date: 2026-10-22
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib", "placard.pretty"))

U = 19.05                    # one keycap unit
SIZES = ["1.00", "1.25", "1.50", "1.75", "2.00", "2.25", "6.25"]
STAB = {"2.00": 11.9, "2.25": 11.9, "6.25": 50.0}     # half the stabilizer spacing
STAB_TOP, STAB_BOT = -6.985, 8.255


def f(v):
    return ("%.4f" % v).rstrip("0").rstrip(".")


def line(x1, y1, x2, y2, layer, w):
    return '  (fp_line (start %s %s) (end %s %s) (stroke (width %s) (type solid)) (layer "%s"))\n' % (
        f(x1), f(y1), f(x2), f(y2), f(w), layer)


def rect(x0, y0, x1, y1, layer, w):
    return (line(x0, y0, x1, y0, layer, w) + line(x1, y0, x1, y1, layer, w) +
            line(x1, y1, x0, y1, layer, w) + line(x0, y1, x0, y0, layer, w))


def hole(x, y, d):
    return ('  (pad "" np_thru_hole circle (at %s %s) (size %s %s) (drill %s) (layers "*.Cu" "*.Mask"))\n'
            % (f(x), f(y), f(d), f(d), f(d)))


def pad(num, shape, x, y, size, drill):
    return ('  (pad "%s" thru_hole %s (at %s %s) (size %s %s) (drill %s) (layers "*.Cu" "*.Mask"))\n'
            % (num, shape, f(x), f(y), f(size), f(size), f(drill)))


def text(kind, val, x, y, layer, hide=False):
    return ('  (fp_text %s "%s" (at %s %s) (layer "%s")%s\n    (effects (font (size 1 1) (thickness 0.15)))\n  )\n'
            % (kind, val, f(x), f(y), layer, " hide" if hide else ""))


def footprint(size):
    name = "SW_Cherry_MX_LED_%su_PCB" % size
    w = float(size) * U
    d = STAB.get(size)
    s = '(footprint "%s" (version 20221018) (generator pcbnew)\n  (layer "F.Cu")\n' % name
    s += ('  (descr "Cherry MX keyswitch, %su, PCB mount, with 3 mm LED holes%s (Placard, gen_kicad_keyswitch.py)")\n'
          % (size, ", Cherry PCB-mount stabilizer" if d else ""))
    s += '  (tags "Cherry MX keyswitch %su PCB LED%s")\n  (attr through_hole)\n' % (size, " stabilizer" if d else "")
    s += text("reference", "REF**", 0, -8.3, "F.SilkS")
    s += text("value", name, 0, 10.6 if not d else 11.6, "F.Fab")
    s += text("user", "${REFERENCE}", 0, -2.5, "F.Fab")
    # switch body (14 mm square), keycap, courtyard
    s += rect(-7.0, -7.0, 7.0, 7.0, "F.Fab", 0.1)
    s += rect(-7.1, -7.1, 7.1, 7.1, "F.SilkS", 0.12)
    s += rect(-w / 2, -U / 2, w / 2, U / 2, "Dwgs.User", 0.15)
    if d:
        s += rect(-d - 2.3, -7.6 - 1.7, d + 2.3, 10.5, "F.CrtYd", 0.05)
    else:
        s += rect(-7.35, -7.35, 7.35, 7.35, "F.CrtYd", 0.05)
    # switch: middle post, two PCB-mount pegs, the two contacts
    s += hole(0, 0, 4.0)
    s += hole(-5.08, 0, 1.7)
    s += hole(5.08, 0, 1.7)
    s += pad("1", "circle", 2.54, -5.08, 2.2, 1.5)
    s += pad("2", "circle", -3.81, -2.54, 2.2, 1.5)
    # LED: 3 = cathode (square), 4 = anode
    s += pad("3", "rect", -1.27, 5.08, 1.6, 1.0)
    s += pad("4", "circle", 1.27, 5.08, 1.6, 1.0)
    s += line(-2.6, 6.4, -2.6, 3.8, "F.SilkS", 0.12)     # cathode mark
    if d:
        for x in (-d, d):
            s += hole(x, STAB_TOP, 3.05)
            s += hole(x, STAB_BOT, 3.988)
    s += ('  (model "${KICAD7_3DMODEL_DIR}/Button_Switch_Keyboard.3dshapes/SW_Cherry_MX_%su_PCB.wrl"\n'
          '    (offset (xyz 2.54 5.08 0)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0))\n  )\n' % size)
    return name, s + ")\n"


def main():
    os.makedirs(OUT, exist_ok=True)
    for size in SIZES:
        name, s = footprint(size)
        with open(os.path.join(OUT, name + ".kicad_mod"), "w") as fh:
            fh.write(s)
        print("wrote", name)


if __name__ == "__main__":
    main()
