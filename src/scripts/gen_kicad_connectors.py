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
| Molex_87715-9106_PCIe_x4_Vertical | cartridge slot J8 (+ cartridge shell keepout) | A1-A32, B1-B32, 1.0 mm, key after 11 |
| CardEdge_2x20_P2.54mm_Vertical | expansion slots J9-J12 (Sullins EBC20DCAN family) (+ card shell keepout) | A1-A20, B1-B20 |
| PS2_Kycon_KMDGX-6S-6S-S4N | stacked PS/2 J5 | A1-A6 (top), B1-B6 (bottom), SH |
| SNES_Pad_Socket_Horizontal | SNES pad ports J2, J3 | 1-7 |
| SW_Toggle_CIT_ANT11TFHQE | power switch SW1 | 1 on throw, 2 common, 3 unused throw |
| Jack_3.5mm_Tensility_54-00174_Horizontal | audio line out jack J6 | T (two legs), R1, R2, S |
| USB_C_Receptacle_GCT_USB4125_6P_HandSolder | USB-C power J13 | A5 A9 A12 B5 B9 B12, S1 |
| Relay_SPDT_CIT_J107 | reset relay K1 (CIT J1071CS5VDC.36) | 1 COM, 2/5 coil, 3 NO, 4 NC (as the G5LE) |

Copies of KiCad's own footprints, unchanged but for the 3D model path (and,
for J4 and J7, the silk stopped inside the board edge where they overhang it):
SD_Hirose_DM1AA_SF_PEJ82 (J4; its pads renamed to the SD_Card symbol's pins: SW 10,
WP 11, shield SH 12 front / 13 back, CP left without a pin), Fuse_Bourns_MF-RG300 (F1),
SW_Tactile_SPST_Angled_PTS645Vx58-2LFS (SW2), DSUB-15-HD_Female_Horizontal_...
(J7 VGA).

3D models: every footprint here names its model as
${KIPRJMOD}/lib/placard.3dshapes/<footprint>.step, in the repo, so the main
board shows them whatever KiCad version or 3D library is installed.
gen_kicad_3d_models.py makes them (generated from the drawings, or copies of
KiCad's own models); run it after this script.

The USB-C footprint is KiCad's own GCT USB4125 one (true to GCT's drawing)
with its six SMD pads lengthened 1.5 mm out the back of the body, so a
soldering iron has room to touch each pad beside the contact.

The two card slots' courtyards are the keepout of the shell that encloses
the card (shell_box(), from the constants above it), so DRC's courtyard
check keeps other parts and neighbouring shells out; the same box is drawn
on User.Eco1 with a label.

Silkscreen: the body outline in silk is cut back around the pads and holes
(SILK_PAD_GAP) and stops SILK_EDGE_GAP inside the board edge on an edge
connector, so DRC's silk-over-mask and silk-to-edge checks pass.

Date: 2026-10-25
"""

import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib", "placard.pretty"))
STOCK = os.environ.get("KICAD7_FOOTPRINT_DIR", "/usr/share/kicad/footprints")
# 3D models live in the repo (kicad/lib/placard.3dshapes, made by gen_kicad_3d_models.py)
# so the board shows them whatever KiCad version or 3D library path is installed
MODELS = "${KIPRJMOD}/lib/placard.3dshapes"


def model(name):
    """The footprint's 3D model: kicad/lib/placard.3dshapes/<name>.step, drawn in
    the footprint's own coordinates, so no offset or rotation."""
    return ('  (model "%s/%s.step"\n    (offset (xyz 0 0 0))\n    (scale (xyz 1 1 1))\n'
            '    (rotate (xyz 0 0 0))\n  )\n' % (MODELS, name))


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


# Silkscreen is kept off the pads and holes and inside the board edge: each silk
# line is cut back to SILK_PAD_GAP from any pad or hole (stroke edge to copper
# or hole edge) and, on an edge connector, to SILK_EDGE_GAP inside the board
# edge; leftover pieces shorter than SILK_MIN_LEN are dropped.
SILK_PAD_GAP = 0.05
SILK_EDGE_GAP = 0.2
SILK_MIN_LEN = 0.25


def keepouts(items):
    """Pads and holes in footprint text -> circles (x, y, r) and boxes (x0, y0, x1, y1).
    Generated pads are never rotated."""
    circ, boxes = [], []
    for m in re.finditer(r'\(pad "[^"]*" \w+ (\w+) \(at (\S+) (\S+)\) \(size (\S+) (\S+)\)', items):
        shape, x, y, w, h = m.group(1), *map(float, m.groups()[1:])
        if shape == "circle":
            circ.append((x, y, w / 2))
        elif shape == "oval":
            r = min(w, h) / 2
            dx, dy = (w / 2 - r, 0) if w > h else (0, h / 2 - r)
            circ += [(x - dx, y - dy, r), (x + dx, y + dy, r)]
            boxes.append((x - dx - (r if dy else 0), y - dy - (r if dx else 0),
                          x + dx + (r if dy else 0), y + dy + (r if dx else 0)))
        else:
            boxes.append((x - w / 2, y - h / 2, x + w / 2, y + h / 2))
    return circ, boxes


def silk_line(x1, y1, x2, y2, w, items, edge=None):
    """An axis-aligned F.SilkS line, cut back from the pads and holes in items
    (and from the board edge at y = edge), as fp_lines."""
    vert = x1 == x2
    a, b = (y1, y2) if vert else (x1, x2)
    c = x1 if vert else y1                  # the fixed coordinate
    lo, hi = min(a, b), max(a, b)
    d = w / 2 + SILK_PAD_GAP
    cuts = []
    circ, boxes = keepouts(items)
    for x, y, r in circ:
        along, across = (y, x) if vert else (x, y)
        if abs(c - across) < r + d:
            h = ((r + d) ** 2 - (c - across) ** 2) ** 0.5
            cuts.append((along - h, along + h))
    for bx0, by0, bx1, by1 in boxes:
        (s0, s1), (t0, t1) = ((by0, by1), (bx0, bx1)) if vert else ((bx0, bx1), (by0, by1))
        if t0 - d < c < t1 + d:
            cuts.append((s0 - d, s1 + d))
    if edge is not None:
        e = edge + SILK_EDGE_GAP + w / 2
        if vert:
            cuts.append((-1e9, e))
        elif c < e:
            return ""
    keep = [(lo, hi)]
    for c0, c1 in cuts:
        keep = [p for k0, k1 in keep for p in ((k0, min(k1, c0)), (max(k0, c1), k1)) if p[1] > p[0]]
    if a > b:                               # keep the line's own direction
        keep = [(k1, k0) for k0, k1 in reversed(keep)]
    s = ""
    for k0, k1 in keep:
        if abs(k1 - k0) >= SILK_MIN_LEN:
            s += line(x1, k0, x1, k1, "F.SilkS", w) if vert else line(k0, y1, k1, y1, "F.SilkS", w)
    return s


def silk_rect(x0, y0, x1, y1, w, items, edge=None):
    return "".join(silk_line(*p, w, items, edge) for p in
                   ((x0, y0, x1, y0), (x1, y0, x1, y1), (x1, y1, x0, y1), (x0, y1, x0, y0)))


def text(kind, val, x, y, layer, size=1.0, hide=False):
    return ('  (fp_text %s "%s" (at %s %s) (layer "%s")%s\n    (effects (font (size %s %s) (thickness %s)))\n  )\n'
            % (kind, val, f(x), f(y), layer, " hide" if hide else "", f(size), f(size), f(size * 0.15)))


def footprint(name, descr, body, pads, edge=None, extra="", crtyd=None):
    """body = (x0, y0, x1, y1) of the part on the board (F.Fab, silk, courtyard).
    edge = y of the front face for an edge connector (drawn on Dwgs.User).
    crtyd = (x0, y0, x1, y1) of a courtyard larger than the body (a card's shell)."""
    x0, y0, x1, y1 = body
    s = '(footprint "%s" (version 20221018) (generator pcbnew)\n  (layer "F.Cu")\n' % name
    s += '  (descr "%s (Placard, gen_kicad_connectors.py; PRELIMINARY, check the datasheet)")\n' % descr
    s += '  (tags "%s")\n  (attr through_hole)\n' % name.replace("_", " ")
    s += text("reference", "REF**", (x0 + x1) / 2, y1 + 1.5, "F.SilkS")
    s += text("value", name, (x0 + x1) / 2, y1 + 3.0, "F.Fab")
    s += text("user", "${REFERENCE}", (x0 + x1) / 2, (y0 + y1) / 2, "F.Fab", size=2.0)
    s += rect(x0, y0, x1, y1, "F.Fab", 0.1)
    s += silk_rect(x0 - 0.12, y0 - 0.12, x1 + 0.12, y1 + 0.12, 0.12, extra + "".join(pads), edge)
    s += rect(*(crtyd or (x0 - 0.5, y0 - 0.5, x1 + 0.5, y1 + 0.5)), "F.CrtYd", 0.05)
    if edge is not None:
        s += line(x0 - 2, edge, x1 + 2, edge, "Dwgs.User", 0.1)
        s += text("user", "PCB edge", (x0 + x1) / 2, edge + 1.2, "Dwgs.User", size=0.8)
    s += extra + "".join(pads) + model(name) + ")\n"
    with open(os.path.join(OUT, name + ".kicad_mod"), "w", newline="\n") as fh:
        fh.write(s)
    print("wrote", name)


# Shell keepouts (EXPANSION.md "Shell keepouts").  Cartridges and expansion
# cards are enclosed in shells whose edges come down to the main board, so
# nothing else may stand inside a shell's outline.  Across the slot (y, mm
# from the card's mid-plane, +y = side A, the card's component side):
CARD_PCB = 1.6               # card thickness (both slots take 1.57 mm)
CARD_PARTS = 9.2             # socketed 28-pin DIP, the tallest part: socket seat 4.3 + PDIP 4.83 max (AT28C256 28P6)
EXP_PARTS = 12.55            # expansion card: a right-angle VGA (DE-15) at its outer end, flange 12.55 mm from the card face
CARD_LEADS = 2.0             # trimmed through-hole leads on side B
SHELL_AIR = 0.5              # gap inside the shell, each side (1.0 over the chips)
SHELL_WALL = 2.0             # shell wall (2 mm printed or moulded)
MARGIN = 1.0                 # shell placement tolerance on the main board
CART_W = 39.0                # cartridge card width = the J8 body (39 mm): chips lie horizontally (gen_kicad_cart_pcb.py)
EXP_W = 72.0                 # expansion card width: the slot body (71.1 mm) plus 0.5 mm a side


def shell_box(mid, card_w, slot_half, parts=CARD_PARTS):
    """Outline of the shell around a vertical card slot, plus MARGIN: the slot's
    courtyard, so KiCad's courtyard check keeps every other part, and the
    neighbouring slots' shells, out of it (tracks, vias and pours may run under
    the shell).  mid = x of the card's centre, slot_half = half the slot body's
    width (the shell's skirt goes round it), parts = tallest part on side A."""
    ya = CARD_PCB / 2 + parts + 2 * SHELL_AIR + SHELL_WALL + MARGIN
    yb = max(CARD_PCB / 2 + CARD_LEADS, slot_half) + SHELL_AIR + SHELL_WALL + MARGIN
    hx = card_w / 2 + SHELL_AIR + SHELL_WALL + MARGIN
    return mid - hx, -yb, mid + hx, ya


def shell_drawing(box, label):
    """The shell keepout drawn on User.Eco1 (beside the puller room boxes), with a label."""
    x0, y0, x1, y1 = box
    return (rect(x0, y0, x1, y1, "Eco1.User", 0.15) +
            text("user", "%s shell keepout (side A parts this way)" % label, (x0 + x1) / 2, y1 - 1.5,
                 "Eco1.User", size=1.2))


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
    box = shell_box(16.5, CART_W, 3.75)      # card centred on the contacts; body 7.5 mm wide
    extra += shell_drawing(box, "cartridge")
    footprint("Molex_87715-9106_PCIe_x4_Vertical",
              "Molex 87715-9106 card edge slot, PCIe x4 style, 64 contacts, 1.0 mm, vertical, through hole",
              (-2.75, -3.75, 35.75, 3.75), pads, extra=extra, crtyd=box)


def card_edge():
    # The cartridge's own fingers, the mate of J8: KiCad's Connector_PCBEdge:BUS_PCIexpress_x4
    # contact pattern (1.0 mm, key between 11 and 12, A1 and B31 short), but with the A row on
    # F.Cu: the cartridge's parts are on side A, the side J8's A row faces (shell keepout).
    # No Edge.Cuts here: gen_kicad_cart_pcb.py draws the whole card outline, tab and key included.
    # Origin = contact 1, card edge at y = +3.45 (KiCad's card), the card body toward -y.
    name = "Card_Edge_87715-9106"
    s = '(footprint "%s" (version 20221018) (generator pcbnew)\n  (layer "F.Cu")\n' % name
    s += ('  (descr "Cartridge card edge fingers for Molex 87715-9106 (PCIe x4 style), 64 contacts, 1.0 mm, '
          '1.57 mm card, A row on F.Cu (Placard, gen_kicad_connectors.py, from KiCad BUS_PCIexpress_x4)")\n')
    s += '  (tags "card edge fingers PCIe x4")\n  (attr exclude_from_pos_files exclude_from_bom)\n'
    s += text("reference", "REF**", 16.5, -4.0, "F.SilkS", hide=True)
    s += text("value", name, 16.5, -6.0, "F.Fab")
    s += text("user", "A row (side A, parts) on F.Cu, B row on B.Cu; edge at y = 3.45", 16.5, -4.0, "Cmts.User", size=0.5)
    s += text("user", "key", 11.5, -1.0, "F.Fab", size=0.8)
    s += rect(-0.65, -2.4, 33.65, 3.45, "F.CrtYd", 0.05)
    for n in range(1, 33):
        x = n - 1 if n <= 11 else n + 1
        for row, layers in (("A", '"F.Cu" "F.Mask"'), ("B", '"B.Cu" "B.Mask"')):
            short = (row, n) in (("A", 1), ("B", 31))
            y, h = (-0.55, 3.2) if short else (0.0, 4.3)
            s += ('  (pad "%s%d" connect rect (at %s %s) (size 0.7 %s) (layers %s))\n'
                  % (row, n, f(x), f(y), f(h), layers))
    s += ")\n"
    with open(os.path.join(OUT, name + ".kicad_mod"), "w", newline="\n") as fh:
        fh.write(s)
    print("wrote", name)


def exp_slot():
    # 2 x 20 card edge, 0.1" contacts, rows 0.2" apart, mounting ears with 3.2 mm holes
    pads = []
    for n in range(1, 21):
        x = (n - 1) * 2.54
        pads.append(pad("A%d" % n, x, 2.54, 1.6, 1.0))
        pads.append(pad("B%d" % n, x, -2.54, 1.6, 1.0))
    c = 19 * 2.54 / 2
    extra = hole(c - 32.39, 0, 3.2) + hole(c + 32.39, 0, 3.2)
    box = shell_box(c, EXP_W, 4.95, EXP_PARTS)
    extra += shell_drawing(box, "expansion card")
    footprint("CardEdge_2x20_P2.54mm_Vertical",
              "Card edge socket, 2 x 20, 2.54 mm contacts, rows 5.08 mm, 1.6 mm card, vertical, mounting ears",
              (c - 35.56, -4.95, c + 35.56, 4.95), pads, extra=extra, crtyd=box)


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


def relay():
    # CIT J107 (datasheet "Schematics & PC Layouts", bottom view): COM 2.0 mm past the
    # coil pins, coil pins 12.0 mm apart, NO/NC 12.2 mm on; holes 1.3 mm, COM 1.4 mm.
    # Same pin pattern and numbering as KiCad's Relay_SPDT_Omron-G5LE-1 (NC, pad 4,
    # on the same side as coil pad 5).  Body 15.4 x 19.0 mm, its end 1.3 mm past COM.
    pads = [pad("1", 0, 0, 2.6, 1.4), pad("2", -6.0, 2.0, 2.5, 1.3), pad("3", -6.0, 14.2, 2.5, 1.3),
            pad("4", 6.0, 14.2, 2.5, 1.3), pad("5", 6.0, 2.0, 2.5, 1.3)]
    footprint("Relay_SPDT_CIT_J107",
              "CIT J107 relay, SPDT, 15.4 x 19.0 mm, pins as the Omron G5LE (1 COM, 2/5 coil, 3 NO, 4 NC)",
              (-7.7, -1.3, 7.7, 17.7), pads)


def usb_c(extend=1.5):
    # KiCad's USB4125 footprint with the SMD pads lengthened toward -y (out the
    # back of the body); each pad's inner end stays where GCT draws it
    stock = "USB_C_Receptacle_GCT_USB4125-xx-x_6P_TopMnt_Horizontal"
    name = "USB_C_Receptacle_GCT_USB4125_6P_HandSolder"
    with open(os.path.join(STOCK, "Connector_USB.pretty", stock + ".kicad_mod")) as fh:
        s = fh.read()

    def longer(m):
        x, y, rot, w, h = m.group(2), float(m.group(3)), m.group(4) or "", m.group(5), float(m.group(6))
        return '(pad "%s" smd roundrect (at %s %s%s) (size %s %s)' % (
            m.group(1), x, f(y - extend / 2), rot, w, f(h + extend))
    s = re.sub(r'\(pad "(\w+)" smd roundrect \(at (\S+) (\S+)( \d+)?\) \(size (\S+) (\S+)\)', longer, s)
    s = s.replace('(footprint "%s"' % stock, '(footprint "%s"' % name)
    s = s.replace('(fp_text value "%s"' % stock, '(fp_text value "%s"' % name)
    s = s.replace('(descr "USB Type C Receptacle', '(descr "Placard, gen_kicad_connectors.py: SMD pads %s mm longer for hand soldering. USB Type C Receptacle' % f(extend))
    s = s.replace('(at 0 -5.1 unlocked) (layer "F.SilkS")', '(at 0 %s unlocked) (layer "F.SilkS")' % f(-5.1 - extend))
    s = s.replace("(fp_rect (start -5.37 -4.35)", "(fp_rect (start -5.37 %s)" % f(-4.35 - extend))
    s = re.sub(r" \(tstamp [0-9a-f-]+\)", "", s)
    s = re.sub(r'  \(model "[^"]+"', '  (model "%s/%s.step"' % (MODELS, name), s)
    with open(os.path.join(OUT, name + ".kicad_mod"), "w") as fh:
        fh.write(s)
    print("wrote", name)


def trim_silk_past(s, edge):
    """Cut the F.SilkS lines of footprint text s back to SILK_EDGE_GAP short of
    y = edge, the board edge as the part sits on the main board (the part's
    front hangs over it, toward +y)."""
    out = []
    for ln in s.split("\n"):
        m = re.match(r'(\s*)\(fp_line \(start ([-\d.]+) ([-\d.]+)\) \(end ([-\d.]+) ([-\d.]+)\)( \(layer "F.SilkS"\) \(width ([\d.]+)\)\))$', ln)
        if m:
            x1, y1, x2, y2, w = (float(v) for v in m.group(2, 3, 4, 5, 7))
            lim = edge - SILK_EDGE_GAP - w / 2
            if y1 > lim and y2 > lim:
                continue
            if y1 > lim:
                x1, y1 = x1 + (x2 - x1) * (lim - y1) / (y2 - y1), lim
                ln = '%s(fp_line (start %s %s) (end %s %s)%s' % (m.group(1), f(x1), f(y1), m.group(4), m.group(5), m.group(6))
            elif y2 > lim:
                x2, y2 = x2 + (x1 - x2) * (lim - y2) / (y1 - y2), lim
                ln = '%s(fp_line (start %s %s) (end %s %s)%s' % (m.group(1), m.group(2), m.group(3), f(x2), f(y2), m.group(6))
        out.append(ln)
    return "\n".join(out)


def stock(lib, name, note, edge=None, rename=None):
    """A copy of one of KiCad's own footprints, unchanged except that its 3D model is
    the copy in kicad/lib/placard.3dshapes (KiCad's own model, or a generated one
    where KiCad's library names a model it does not have), and, given edge, its
    silk stops inside the board edge at y = edge (trim_silk_past).  rename maps
    (pad name, pad y) to a new name, so the pads match the symbol's pin numbers."""
    with open(os.path.join(STOCK, lib + ".pretty", name + ".kicad_mod")) as fh:
        s = fh.read()
    s = re.sub(r" \(tstamp [0-9a-f-]+\)", "", s)
    for (old, y), new in (rename or {}).items():
        s, n = re.subn(r'\(pad "%s" (\w+ \w+ \(at \S+ %s\))' % (re.escape(old), re.escape(y)),
                       r'(pad "%s" \1' % new, s)
        assert n in (1, 2), (old, y)
    if edge is not None:
        s = trim_silk_past(s, edge)
        note += ", silk stopped %s mm inside the board edge at y = %s" % (f(SILK_EDGE_GAP), f(edge))
    s = s.replace('(descr "', '(descr "Placard, gen_kicad_connectors.py: KiCad %s:%s with %s. ' % (lib, name, note), 1)
    s = re.sub(r'  \(model "[^"]+"', '  (model "%s/%s.step"' % (MODELS, name), s)
    assert MODELS in s
    with open(os.path.join(OUT, name + ".kicad_mod"), "w") as fh:
        fh.write(s)
    print("wrote", name)


def main():
    cart_slot()
    card_edge()
    exp_slot()
    ps2_stacked()
    snes()
    toggle()
    audio_jack()
    usb_c()
    relay()
    # J4 (Hirose DM1AA-SF-PEJ(82); the Kyocera 5638 went obsolete 2026-10-25) sits with
    # its card opening 15.45 mm past its origin on the left board edge
    stock("Connector_Card", "SD_Hirose_DM1AA_SF_PEJ82", "a generated 3D model (KiCad has none) and its "
          "pads renamed to the SD_Card symbol's pins (SW 10, WP 11, SH 12/13)", edge=15.45,
          rename={("SW", "8"): "10", ("WP", "5.4"): "11", ("SH", "10.45"): "12", ("SH", "-8.2"): "13"})
    stock("Fuse", "Fuse_Bourns_MF-RG300", "a generated 3D model (KiCad has none)")
    stock("Button_Switch_THT", "SW_Tactile_SPST_Angled_PTS645Vx58-2LFS", "KiCad's 3D model, copied into the project")
    stock("Connector_Dsub", "DSUB-15-HD_Female_Horizontal_P2.29x1.98mm_EdgePinOffset3.03mm_Housed_MountingHolesOffset4.94mm",
          "KiCad's 3D model, copied into the project", edge=6.99)   # J7's flange over the back edge


if __name__ == "__main__":
    main()
