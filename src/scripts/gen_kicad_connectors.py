#!/usr/bin/env python3
"""
gen_kicad_connectors.py - make the main board's connector and switch
footprints that KiCad's libraries do not have, in kicad/lib/placard.pretty/.

    python3 gen_kicad_connectors.py

PRELIMINARY: these footprints are drawn from typical dimensions for each
part family, not from the manufacturers' drawings, so the board outline
and placement (gen_kicad_pcb.py) can be worked out.  Each one's body
outline (F.Fab), courtyard and pad numbers are right for planning; check
the hole positions and sizes against the datasheet before ordering boards.

Orientation: an edge connector's opening faces up (-y), so at rotation 0
it sits on the back edge (the top of the layout drawing) with its front
face on the line y = 0 of the footprint.  The slots stand up (+z) and
have no edge.

| Footprint | Part | Pads (as the symbol) |
|---|---|---|
| Molex_87715-9106_PCIe_x4_Vertical | cartridge slot J8 | A1-A32, B1-B32, 1.0 mm, key after 11 |
| CardEdge_2x20_P2.54mm_Vertical | expansion slots J9-J12 (Sullins EBC20DCAN family) | A1-A20, B1-B20 |
| PS2_Kycon_KMDGX-6S-6S-S4N | stacked PS/2 J5 | A1-A6 (top), B1-B6 (bottom), SH |
| SNES_Pad_Socket_Horizontal | SNES pad ports J2, J3 | 1-7 |
| SW_Toggle_CIT_ANT11TFHQE | power switch SW1 | 1 on throw, 2 common, 3 unused throw |
| SW_Push_CK_E112SD1A3QE | reset button SW2 | 1 NC, 2 common, 3 unused NO |
| Jack_3.5mm_Tensility_54-00174_Horizontal | headphone jack J6 | T (two legs), R1, R2, S |

Date: 2026-10-22
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib", "placard.pretty"))


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


def pad(num, x, y, size, drill, shape=None):
    shape = shape or ("rect" if num in ("1", "A1") else "circle")
    return ('  (pad "%s" thru_hole %s (at %s %s) (size %s %s) (drill %s) (layers "*.Cu" "*.Mask"))\n'
            % (num, shape, f(x), f(y), f(size), f(size), f(drill)))


def text(kind, val, x, y, layer, size=1.0, hide=False):
    return ('  (fp_text %s "%s" (at %s %s) (layer "%s")%s\n    (effects (font (size %s %s) (thickness %s)))\n  )\n'
            % (kind, val, f(x), f(y), layer, " hide" if hide else "", f(size), f(size), f(size * 0.15)))


def footprint(name, descr, body, pads, edge=None, extra=""):
    """body = (x0, y0, x1, y1) of the part on the board (F.Fab, silk, courtyard).
    edge = y of the front face for an edge connector (drawn on Dwgs.User)."""
    x0, y0, x1, y1 = body
    s = '(footprint "%s" (version 20221018) (generator pcbnew)\n  (layer "F.Cu")\n' % name
    s += '  (descr "%s (Placard, gen_kicad_connectors.py; PRELIMINARY, check the datasheet)")\n' % descr
    s += '  (tags "%s")\n  (attr through_hole)\n' % name.replace("_", " ")
    s += text("reference", "REF**", (x0 + x1) / 2, y1 + 1.5, "F.SilkS")
    s += text("value", name, (x0 + x1) / 2, y1 + 3.0, "F.Fab")
    s += text("user", "${REFERENCE}", (x0 + x1) / 2, (y0 + y1) / 2, "F.Fab", size=2.0)
    s += rect(x0, y0, x1, y1, "F.Fab", 0.1)
    s += rect(x0 - 0.12, y0 - 0.12, x1 + 0.12, y1 + 0.12, "F.SilkS", 0.12)
    s += rect(x0 - 0.5, y0 - 0.5, x1 + 0.5, y1 + 0.5, "F.CrtYd", 0.05)
    if edge is not None:
        s += line(x0 - 2, edge, x1 + 2, edge, "Dwgs.User", 0.1)
        s += text("user", "PCB edge", (x0 + x1) / 2, edge + 1.2, "Dwgs.User", size=0.8)
    s += extra + "".join(pads) + ")\n"
    with open(os.path.join(OUT, name + ".kicad_mod"), "w", newline="\n") as fh:
        fh.write(s)
    print("wrote", name)


def cart_slot():
    # PCIe x4 vertical through-hole: 32 contacts a side at 1.0 mm, key between 11 and 12
    # (2 mm gap, the same x as KiCad's Connector_PCBEdge:BUS_PCIexpress_x4 card), 39 mm body.
    # Each side's contacts alternate between two staggered rows.
    pads = []
    for n in range(1, 33):
        x = n - 1 if n <= 11 else n + 1
        stag = 1.9 if n % 2 else 0.0
        pads.append(pad("B%d" % n, x, -1.0 - stag, 0.95, 0.65))
        pads.append(pad("A%d" % n, x, 1.0 + stag, 0.95, 0.65))
    extra = hole(-1.6, 0, 1.6) + hole(34.6, 0, 1.6)
    extra += text("user", "key", 11.5, 0, "F.Fab", size=0.8)
    footprint("Molex_87715-9106_PCIe_x4_Vertical",
              "Molex 87715-9106 card edge slot, PCIe x4 style, 64 contacts, 1.0 mm, vertical, through hole",
              (-2.75, -3.75, 35.75, 3.75), pads, extra=extra)


def exp_slot():
    # 2 x 20 card edge, 0.1" contacts, rows 0.2" apart, mounting ears with 3.2 mm holes
    pads = []
    for n in range(1, 21):
        x = (n - 1) * 2.54
        pads.append(pad("A%d" % n, x, 2.54, 1.6, 1.0))
        pads.append(pad("B%d" % n, x, -2.54, 1.6, 1.0))
    c = 19 * 2.54 / 2
    extra = hole(c - 32.39, 0, 3.2) + hole(c + 32.39, 0, 3.2)
    footprint("CardEdge_2x20_P2.54mm_Vertical",
              "Card edge socket, 2 x 20, 2.54 mm contacts, rows 5.08 mm, 1.6 mm card, vertical, mounting ears",
              (c - 35.56, -4.95, c + 35.56, 4.95), pads, extra=extra)


def slot(num, x, y, w, h):
    """A plated slot w x h (mm), pad 0.6 mm larger all round."""
    return ('  (pad "%s" thru_hole oval (at %s %s) (size %s %s) (drill oval %s %s) (layers "*.Cu" "*.Mask"))\n'
            % (num, f(x), f(y), f(w + 0.6), f(h + 0.6), f(w), f(h)))


def audio_jack():
    # Tensility 54-00174, 4-pole (TRRS) 3.5 mm jack, right angle, from its drawing (rev A, 2020-05-07):
    # body 6.6 x 12.3 mm behind the face, 1.5 x 0.8 mm slots, two 1.2 mm pegs on the axis.
    # Drawing pins: 4 tip (two legs), 3 ring 1, 2 ring 2, 1 sleeve; here named as the symbol.
    pads = [slot("T", -3.3, 3.5, 0.8, 1.5), slot("T", 3.3, 3.5, 0.8, 1.5),
            slot("R1", -2.85, 11.5, 0.8, 1.5), slot("R2", 2.85, 11.5, 0.8, 1.5),
            slot("S", 0.0, 12.3, 1.5, 0.8)]
    extra = hole(0.0, 2.0, 1.2) + hole(0.0, 9.0, 1.2)
    footprint("Jack_3.5mm_Tensility_54-00174_Horizontal",
              "Tensility 54-00174 3.5 mm TRRS jack, right angle, through hole, opening over the edge",
              (-3.3, -2.5, 3.3, 12.9), pads, edge=0.0, extra=extra)


def ps2_stacked():
    # stacked dual mini-DIN 6, right angle: 14 mm wide, 13 mm deep, front face on the edge
    pads = []
    for num, x, y in [("A1", -1.3, 4.6), ("A2", 1.3, 4.6), ("A3", -3.4, 6.6),
                      ("A4", 3.4, 6.6), ("A5", -3.4, 4.6), ("A6", 3.4, 4.6),
                      ("B1", -1.3, 9.6), ("B2", 1.3, 9.6), ("B3", -3.4, 11.6),
                      ("B4", 3.4, 11.6), ("B5", -3.4, 9.6), ("B6", 3.4, 9.6)]:
        pads.append(pad(num, x, y, 1.5, 0.9, "rect" if num == "A1" else "circle"))
    for x in (-6.75, 6.75):
        pads.append(pad("SH", x, 3.0, 2.8, 2.0, "circle"))
        pads.append(pad("SH", x, 10.0, 2.8, 2.0, "circle"))
    footprint("PS2_Kycon_KMDGX-6S-6S-S4N",
              "Kycon KMDGX-6S/6S-S4N stacked dual mini-DIN 6 (PS/2), right angle, shielded: A top, B bottom",
              (-7.0, -0.5, 7.0, 13.0), pads, edge=0.0, extra=hole(0, 7.6, 2.5))


def snes():
    # PCB-mount SNES controller port (replacement part), right angle: 7 pins in a row
    pads = [pad(str(n), (n - 4) * 2.54, 14.0, 1.6, 1.0) for n in range(1, 8)]
    extra = hole(-11.0, 7.0, 3.0) + hole(11.0, 7.0, 3.0)
    footprint("SNES_Pad_Socket_Horizontal",
              "SNES controller port, PCB mount, right angle, 7 pins",
              (-13.0, -0.5, 13.0, 16.0), pads, edge=0.0, extra=extra)


def toggle():
    # right-angle PCB toggle, 1/4-40 bushing out the case side: 3 pins at 4.7 mm, 2 bracket pins
    pads = [pad(str(n), (n - 2) * 4.7, 10.0, 2.5, 1.6, "oval" if n != 1 else "rect") for n in (1, 2, 3)]
    pads += [pad("MP", -6.35, 3.0, 2.8, 1.8), pad("MP", 6.35, 3.0, 2.8, 1.8)]
    footprint("SW_Toggle_CIT_ANT11TFHQE",
              "CIT ANT11TFHQE toggle switch, SPDT, right angle PCB, 1/4-40 bushing over the edge",
              (-7.0, -9.5, 7.0, 12.5), pads, edge=0.0)


def pushbutton():
    # right-angle PCB pushbutton, snap-in: 3 pins at 4.7 mm, 2 snap-in legs
    pads = [pad(str(n), (n - 2) * 4.7, 9.0, 2.2, 1.4) for n in (1, 2, 3)]
    pads += [pad("MP", -5.5, 3.0, 2.6, 1.8), pad("MP", 5.5, 3.0, 2.6, 1.8)]
    footprint("SW_Push_CK_E112SD1A3QE",
              "C&K E112SD1A3QE pushbutton, SPDT momentary, right angle PCB, snap-in, plunger over the edge",
              (-6.5, -7.0, 6.5, 11.0), pads, edge=0.0)


def main():
    cart_slot()
    exp_slot()
    ps2_stacked()
    snes()
    toggle()
    pushbutton()
    audio_jack()


if __name__ == "__main__":
    main()
