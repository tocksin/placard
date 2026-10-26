#!/usr/bin/env python3
"""
gen_kicad_3d_models.py - make the 3D models (STEP) for the main board's
connectors, switches and polyfuse, in kicad/lib/placard.3dshapes/.

    pip install cadquery
    python3 gen_kicad_connectors.py      # footprints first: the pins come from their pads
    python3 gen_kicad_3d_models.py

Each footprint in kicad/lib/placard.pretty names its model as
${KIPRJMOD}/lib/placard.3dshapes/<footprint>.step with no offset or
rotation, so every model here is drawn in its footprint's own coordinates
(x right, y = -footprint y, z up from the board's top face).  The pins are
put on the footprint's pads (read from the .kicad_mod file), so they line up
by construction.

| Model | Part | Source |
|---|---|---|
| Molex_87715-9106_PCIe_x4_Vertical | cartridge slot J8 | generated: 39 x 7.5 x 11.25 mm body (PCIe x4 vertical), key after contact 11 |
| CardEdge_2x20_P2.54mm_Vertical | expansion slots J9-J12 (Sullins EBC20DCAN) | generated: 0.1" card edge, body 55.9 x 9.9 x 9.1 mm, ears with 3.2 mm holes |
| PS2_Kycon_KMDGX-6S-6S-S4N | stacked PS/2 J5 | generated: 14 x 13.5 x 25 mm shield, mouse (green) top, keyboard (purple) bottom |
| Jack_3.5mm_Tensility_54-00174_Horizontal | audio line out J6 | generated: 6.6 x 12.3 x 5 mm body, 5 mm barrel 2.5 mm past the face |
| SW_Toggle_CIT_ANT11TFHQE | power switch SW1 | generated: bracket, body, 1/4-40 bushing and lever |
| SD_Hirose_DM1AA_SF_PEJ82 | SD socket J4 | generated: 28.4 x 30.9 mm from KiCad's footprint outline, 2.8 mm high, card opening at the +y end |
| Fuse_Bourns_MF-RG300 | polyfuse F1 | generated: 7.1 x 3.0 mm disc, 11 mm high, seated 3 mm up |
| SNES_Pad_Socket_Horizontal | SNES ports J2, J3 | generated: 26 x 16.5 x 13 mm block, pad-shaped opening |
| SW_Tactile_SPST_Angled_PTS645Vx58-2LFS | reset button SW2 | KiCad's own model, copied |
| DSUB-15-HD_Female_Horizontal_..._MountingHolesOffset4.94mm | VGA J7 | KiCad's own model, copied |
| USB_C_Receptacle_GCT_USB4125_6P_HandSolder | USB-C J13 | KiCad's USB4125 model, copied |
| Relay_SPDT_CIT_J107 | reset relay K1 | generated: 15.4 x 19.0 x 15.5 mm sealed box, 1.0 mm standoff (CIT J107 drawing) |

The generated models are drawn from typical dimensions for each part (the
makers' drawings could not be fetched), close enough to check fit and
clearances in KiCad's 3D viewer and the case; replace one with the maker's
STEP file of the same name if it is wanted exact.  KiCad's models are CC-BY-SA
4.0 with the KiCad libraries' exception (designs using them are unaffected).

Date: 2026-10-25
"""

import os
import re
import shutil

import cadquery as cq

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib"))
PRETTY = os.path.join(LIB, "placard.pretty")
OUT = os.path.join(LIB, "placard.3dshapes")
STOCK3D = os.environ.get("KICAD7_3DMODEL_DIR", "/usr/share/kicad/3dmodels")

BLACK = (0.12, 0.12, 0.12)
GREY = (0.35, 0.35, 0.37)
METAL = (0.78, 0.78, 0.80)
TIN = (0.85, 0.85, 0.85)
GOLD = (0.86, 0.70, 0.30)
GREEN = (0.25, 0.62, 0.30)
PURPLE = (0.50, 0.32, 0.72)
PTC = (0.92, 0.76, 0.22)

PIN_DOWN = 3.0               # leads stand 3 mm out of the board's back (1.6 mm board + 1.4)


# --------------------------------------------------------------- geometry
# All sizes in footprint coordinates: x right, y down the footprint drawing, z up.

def box(x0, y0, x1, y1, z0, z1):
    return (cq.Workplane("XY").box(x1 - x0, y1 - y0, z1 - z0)
            .translate(((x0 + x1) / 2, -(y0 + y1) / 2, (z0 + z1) / 2)))


def cyl_z(x, y, d, z0, z1):
    return cq.Workplane("XY").circle(d / 2).extrude(z1 - z0).translate((x, -y, z0))


def cyl_y(x, z, d, y0, y1):
    """A cylinder along footprint y from y0 to y1 (y0 < y1), axis at height z."""
    return (cq.Workplane("XZ").circle(d / 2).extrude(y1 - y0)
            .translate((x, -y0, z)))


def pads(name):
    """The footprint's through-hole pads: (number, x, y, drill w, drill h, plated)."""
    with open(os.path.join(PRETTY, name + ".kicad_mod")) as fh:
        s = fh.read()
    out = []
    for m in re.finditer(r'\(pad "([^"]*)" (thru_hole|np_thru_hole|smd) \w+ \(at (\S+) (\S+?)(?: \S+)?\) '
                         r'\(size (\S+) (\S+)\)(?: \(drill (oval )?(\S+?)(?: (\S+?))?\))?', s):
        num, kind, x, y, sw, sh, oval, dw, dh = m.groups()
        if kind == "smd":
            out.append((num, float(x), float(y), float(sw), float(sh), "smd"))
        else:
            dw = float(dw)
            out.append((num, float(x), float(y), dw, float(dh) if dh else dw, kind == "thru_hole"))
    return out


def pins(name, top, want=None, flat=False):
    """A lead in each plated hole (want: pad numbers to use), from PIN_DOWN under
    the board up to z = top.  Round holes get round leads, slots flat ones."""
    shapes = []
    for num, x, y, w, h, plated in pads(name):
        if plated is not True or (want and num not in want):
            continue
        if w == h and not flat:
            shapes.append(cyl_z(x, y, max(0.4, w * 0.6), -PIN_DOWN, top))
        else:
            tw, th = (w * 0.6, h * 0.35) if flat and w == h else (w * 0.5, h * 0.8)
            shapes.append(box(x - tw / 2, y - th / 2, x + tw / 2, y + th / 2, -PIN_DOWN, top))
    return shapes


def pegs(name, depth=1.6):
    """A plastic peg in each non-plated hole."""
    return [cyl_z(x, y, w * 0.92, -depth, 0.01) for num, x, y, w, h, plated in pads(name) if plated is False]


def save(name, parts):
    """parts = [(label, color, [workplanes])] -> kicad/lib/placard.3dshapes/<name>.step"""
    assy = cq.Assembly(name=re.sub(r"\W", "_", name))
    for label, color, shapes in parts:
        solids = [o for s in shapes for o in s.vals()]
        if solids:
            # one solid per color where the pieces touch (KiCad drops the color of
            # a compound holding several solids that touch)
            shape = solids[0].fuse(*solids[1:]).clean() if len(solids) > 1 else solids[0]
            assy.add(shape, name=label, color=cq.Color(*color))
    path = os.path.join(OUT, name + ".step")
    assy.export(path, exportType="STEP")
    print("wrote", os.path.relpath(path, LIB))


# --------------------------------------------------------------- the parts

def cart_slot():
    # Molex 87715-9106: PCIe x4 vertical, 39 x 7.5 mm body, 11.25 mm high; contacts 1.0 mm,
    # key between contacts 11 and 12 (x 10..12); the card slot is 1.8 mm wide
    name = "Molex_87715-9106_PCIe_x4_Vertical"
    body = box(-2.75, -3.75, 35.75, 3.75, 0, 11.25)
    body = body.cut(box(-0.7, -0.9, 10.6, 0.9, 2.0, 11.3)).cut(box(12.4, -0.9, 33.7, 0.9, 2.0, 11.3))
    contacts = []
    for n in range(1, 33):
        x = n - 1 if n <= 11 else n + 1
        contacts += [box(x - 0.25, -0.95, x + 0.25, -0.8, 4.0, 9.0), box(x - 0.25, 0.8, x + 0.25, 0.95, 4.0, 9.0)]
    save(name, [("housing", BLACK, [body] + pegs(name)), ("contacts", GOLD, contacts + pins(name, 1.0))])


def exp_slot():
    # Sullins EBC20DCAN: 2 x 20 card edge, 0.1" contacts, rows 0.2" apart, 1.6 mm card,
    # insulator 2.2" x 0.39" x 0.36", ears out to 2.8" with 3.2 mm holes 2.55" apart
    name = "CardEdge_2x20_P2.54mm_Vertical"
    c = 19 * 2.54 / 2
    body = box(c - 27.94, -4.95, c + 27.94, 4.95, 0, 9.1).cut(box(c - 25.8, -0.9, c + 25.8, 0.9, 2.0, 9.2))
    for s in (-1, 1):
        ear = box(min(c + s * 27.94, c + s * 35.56), -3.2, max(c + s * 27.94, c + s * 35.56), 3.2, 0, 2.4)
        body = body.union(ear).cut(cyl_z(c + s * 32.39, 0, 3.2, -1, 3))
    contacts = []
    for n in range(20):
        x = n * 2.54
        contacts += [box(x - 0.4, -0.95, x + 0.4, -0.8, 3.0, 8.0), box(x - 0.4, 0.8, x + 0.4, 0.95, 3.0, 8.0)]
    save(name, [("housing", BLACK, [body]), ("contacts", GOLD, contacts + pins(name, 1.0))])


def ps2_stacked():
    # Kycon KMDGX-6S/6S-S4N: stacked mini-DIN 6, right angle, shielded, front face on the
    # board edge; port A (mouse, green) on top, B (keyboard, purple) below
    name = "PS2_Kycon_KMDGX-6S-6S-S4N"
    zb, zt = 6.75, 19.25
    shield = box(-7.0, -0.5, 7.0, 13.0, 0, 25.0)
    inserts = []
    for z, color in ((zt, GREEN), (zb, PURPLE)):
        shield = shield.cut(cyl_y(0, z, 9.6, -0.6, 9.0))
        ins = cyl_y(0, z, 9.6, 1.0, 9.0)
        ins = ins.cut(cyl_y(0, z, 7.0, 0.9, 6.0))
        ins = ins.union(cyl_y(0, z, 4.5, 1.6, 6.0)).union(box(-0.9, 0.9, 0.9, 6.0, z - 4.0, z - 2.4))
        for px, pz in ((-1.3, 1.2), (1.3, 1.2), (-2.4, -0.4), (2.4, -0.4), (-1.0, -1.6), (1.0, -1.6)):
            ins = ins.cut(cyl_y(px, z + pz, 0.8, 1.5, 3.0))
        inserts.append((color, ins))
    pegs_ = [cyl_z(0, 7.6, 2.3, -1.6, 0.01)]
    save(name, [("shield", METAL, [shield] + pins(name, 1.0, want={"SH"}, flat=True)),
                ("mouse", GREEN, [inserts[0][1]]), ("keyboard", PURPLE, [inserts[1][1]]),
                ("pins", TIN, pins(name, 1.0, want={"A%d" % n for n in range(1, 7)} | {"B%d" % n for n in range(1, 7)})),
                ("peg", BLACK, pegs_)])


def audio_jack():
    # Tensility 54-00174: 6.6 x 12.3 mm body behind the face, 5 mm high, 5 mm barrel
    # standing 2.5 mm past the face, 3.6 mm plug hole on the axis
    name = "Jack_3.5mm_Tensility_54-00174_Horizontal"
    z = 2.5
    body = box(-3.3, 0, 3.3, 12.3, 0, 5.0).union(cyl_y(0, z, 5.0, -2.5, 0.01))
    body = body.cut(cyl_y(0, z, 3.6, -2.6, 10.0))
    save(name, [("body", BLACK, [body] + pegs(name, 1.2)), ("pins", TIN, pins(name, 2.0))])


def snes():
    # SNES controller port, PCB mount, right angle: the opening is the pad plug's
    # outline (flat end and round end), pins in a row at the back
    name = "SNES_Pad_Socket_Horizontal"
    z = 7.0
    body = box(-13.0, -0.5, 13.0, 16.0, 0, 13.0)
    hole = (cq.Workplane("XZ").center(-2.0, z).rect(14.0, 7.2).extrude(-9.0)
            .union(cq.Workplane("XZ").center(5.0, z).circle(3.6).extrude(-9.0)))
    body = body.cut(hole.translate((0, 0.6, 0)))
    save(name, [("body", GREY, [body] + pegs(name, 1.6)), ("pins", TIN, pins(name, 3.0))])


def toggle():
    # CIT ANT11TFHQE: right-angle PCB toggle, bracket on the board edge with two legs,
    # 1/4-40 bushing and lever out over the edge, three lugs at the back
    name = "SW_Toggle_CIT_ANT11TFHQE"
    z = 5.2
    bracket = box(-7.0, 0, 7.0, 0.8, 0, 11.5).cut(cyl_y(0, z, 6.4, -0.1, 1.0))
    feet = [box(x - 1.0, 0.8, x + 1.0, 3.8, 0, 0.8) for x in (-6.35, 6.35)]
    bushing = cyl_y(0, z, 6.35, -6.5, 0.01)
    lever = (cq.Workplane("XZ").circle(1.5).workplane(offset=3.0).circle(1.1).loft()
             .translate((0, 6.5, z)))
    body = box(-6.3, 0.8, 6.3, 12.5, z - 4.2, z + 4.2)
    save(name, [("bracket", METAL, [bracket, bushing] + feet + pins(name, 0.8, want={"MP"}, flat=True)),
                ("lever", TIN, [lever]),
                ("body", BLACK, [body]),
                ("lugs", TIN, pins(name, z - 3.0, want={"1", "2", "3"}, flat=True))])


def sd_socket():
    # Hirose DM1AA-SF-PEJ(82): KiCad's footprint outline (silk box 28.4 x 30.9 mm),
    # 2.8 mm high (typical), metal cover; the card goes in at the +y end, contact
    # tails at -y, shield tabs (12, 13) up the sides
    name = "SD_Hirose_DM1AA_SF_PEJ82"
    outline = [(-14.2, -14.0), (14.2, -14.0), (14.2, 15.45), (-14.2, 15.45)]
    pts = [(x, -y) for x, y in outline]
    base = cq.Workplane("XY").polyline(pts).close().extrude(2.5)
    base = base.cut(box(-12.6, 3.0, 12.6, 15.55, 0.4, 2.51))
    cover = cq.Workplane("XY").polyline(pts).close().extrude(0.3).translate((0, 0, 2.5))
    tails = []
    for num, x, y, w, h, kind in pads(name):
        if kind == "smd":
            tw, th = (w * 0.7, h * 0.8)
            if num in ("12", "13"):
                tails.append(box(x - tw / 2, y - th / 2, x + tw / 2, y + th / 2, 0, 2.8))
            elif num in ("1", "2", "3", "4", "5", "6", "7", "8", "9"):
                tails.append(box(x - tw / 2, y - th / 2, x + tw / 2, -14.0, 0, 0.15))
            else:
                tails.append(box(x - tw / 2, y - th / 2, -14.2, y + th / 2, 0, 0.15))
    save(name, [("body", BLACK, [base] + pegs(name, 1.5)), ("cover", METAL, [cover] + tails)])


def fuse():
    # Bourns MF-RG300: radial PPTC disc 7.1 mm wide, 3.0 mm thick, seated on its leads
    # 3 mm above the board, 11 mm high (KiCad's footprint outline)
    name = "Fuse_Bourns_MF-RG300"
    body = box(-1.0, -0.9, 6.1, 2.1, 3.0, 14.0).edges("|Y").fillet(1.4).edges().fillet(0.6)
    save(name, [("body", PTC, [body]), ("leads", TIN, pins(name, 5.0))])


def relay():
    # CIT J107: 15.4 x 19.0 mm box, 15.5 mm high, standing 1.0 mm off the board on its
    # pins; the end of the body is 1.3 mm past COM (datasheet "Dimensions")
    name = "Relay_SPDT_CIT_J107"
    body = box(-7.7, -1.3, 7.7, 17.7, 1.0, 16.5).edges("|Z").fillet(0.5)
    save(name, [("body", BLACK, [body]), ("pins", TIN, pins(name, 1.5, flat=True))])


def copy_stock(stock, name):
    """KiCad's own model for a footprint, copied into the project under the footprint's name."""
    shutil.copyfile(os.path.join(STOCK3D, stock + ".step"), os.path.join(OUT, name + ".step"))
    print("copied", stock, "->", name)


def main():
    os.makedirs(OUT, exist_ok=True)
    cart_slot()
    exp_slot()
    ps2_stacked()
    audio_jack()
    snes()
    toggle()
    sd_socket()
    fuse()
    relay()
    copy_stock("Button_Switch_THT.3dshapes/SW_Tactile_SPST_Angled_PTS645Vx58-2LFS",
               "SW_Tactile_SPST_Angled_PTS645Vx58-2LFS")
    dsub = "DSUB-15-HD_Female_Horizontal_P2.29x1.98mm_EdgePinOffset3.03mm_Housed_MountingHolesOffset4.94mm"
    copy_stock("Connector_Dsub.3dshapes/" + dsub, dsub)
    copy_stock("Connector_USB.3dshapes/USB_C_Receptacle_GCT_USB4125-xx-x_6P_TopMnt_Horizontal",
               "USB_C_Receptacle_GCT_USB4125_6P_HandSolder")


if __name__ == "__main__":
    main()
