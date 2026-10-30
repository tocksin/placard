#!/usr/bin/env python3
"""
gen_case_quote.py - the quote package for the PLACARD case's metal and acrylic
parts, for sheet metal services (SendCutSend, PCBWay sheet metal, Xometry,
Protocase) and laser cutters.  From gen_case.py's parts it writes case/quote/:

- step/      the tray and both plates as bent parts with real bends (inside
             radius BEND_R, corner and end reliefs), flat parts as cut;
- dxf/       flat patterns of the bent parts (layer CUT = outline and holes,
             layer BEND = bend lines, K = K_FACTOR), and the acrylic parts;
- pdf/       one drawing per part: flat pattern with sizes, bends, holes and
             hardware, material, finish and tolerances;
- PARTS.csv and README.md.

and zips it all to case/quote.zip.

    pip install cadquery ezdxf
    python3 gen_case_quote.py [--pcb path/to/placard.kicad_pcb] [--out case/quote]

The board file is only read.  See docs/CASE.md, "Getting a quote".

Date: 2026-10-30
"""

import argparse
import csv
import math
import os
import shutil
import zipfile

import cadquery as cq
import ezdxf
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

import gen_case as g

T, R = g.T, g.BEND_R
K_FACTOR = 0.44                       # 5052-H32, air bend, R = 1T
OSSB = R + T                          # outside setback of a 90 degree bend
BA = math.pi / 2 * (R + K_FACTOR * T)   # bend allowance (neutral axis arc length)
BD = 2 * OSSB - BA                    # bend deduction
RELIEF = 0.5                          # corner and end reliefs: past the neighbouring bend
CORNER_GAP = 0.5                      # tray: front wall end to the right wall's inside face
DATE = "2026-10-30"
REV = "A"

MATERIAL = "Aluminium 5052-H32, 2.0 mm (0.080 in)"
FINISH = "Black powder coat, stock color, texture or matte, both sides"
TOLS = ["Laser cut features +/-0.1 mm, holes +0.1/-0 mm",
        "Bends 90 deg +/-0.5 deg, inside radius %.1f mm, flange lengths +/-0.25 mm" % R,
        "Unless shown: ISO 2768-m; break sharp edges",
        "Flat pattern for reference: K = %.2f, bend allowance %.3f mm, bend deduction %.3f mm; "
        "develop from the STEP with your own bend table" % (K_FACTOR, BA, BD)]


def box(x0, x1, y0, y1, z0, z1):
    return cq.Workplane("XY").box(x1 - x0, y1 - y0, z1 - z0, centered=False).translate((x0, y0, z0))


def sel(wp, p0, p1):
    return wp.edges(cq.selectors.BoxSelector(p0, p1))


# ---------------------------------------------------------------- the bent parts
def tray_parts(parts, cuts):
    """(sharp, bent) tray.  The front wall stops CORNER_GAP short of the right
    wall; a corner relief clears both bends."""
    W, D, Zf, Zt = g.W, g.D, g.Z_FLOOR, g.Z_TOP
    s = g.rounded_plate(0, W, 0, D, Zf, T)
    s = s.union(g.rounded_plate(0, W - T - CORNER_GAP, 0, T, Zf, Zt - Zf))
    s = s.union(g.rounded_plate(W - T, W, 0, D, Zf, Zt - Zf))
    s = s.cut(box(W - OSSB - RELIEF, W + 1, -1, OSSB + RELIEF, Zf - 1, Zf + OSSB + RELIEF))
    bent = sel(s, (-1, -0.1, Zf - 0.1), (W - OSSB, 0.1, Zf + 0.1)).fillet(OSSB)
    bent = sel(bent, (W - 0.1, OSSB, Zf - 0.1), (W + 0.1, D + 1, Zf + 0.1)).fillet(OSSB)
    bent = sel(bent, (-1, T - 0.1, Zf + T - 0.1), (W - OSSB, T + 0.1, Zf + T + 0.1)).fillet(R)
    bent = sel(bent, (W - T - 0.1, OSSB, Zf + T - 0.1), (W - T + 0.1, D + 1, Zf + T + 0.1)).fillet(R)
    out = []
    for i, sol in enumerate((s, bent)):
        for ref, side, u, z, prof, note in cuts:
            if side in ("front", "right"):
                sol = sol.cut(g.cutter(side, u, z, prof))
        for u in g.side_vents(cuts, "right"):
            sol = sol.cut(g.vent_cutter("right", u))
        for x, y in g.board_hole_xys(parts):
            sol = sol.cut(g.hole(x, y, 3.4, Zf - 1))
            if i:   # countersunk for the M3 screw up into the floor standoff
                sol = sol.cut(cq.Workplane("XY").center(x, y).circle(3.25).workplane(offset=3.25)
                              .circle(0.0001).loft().translate((0, 0, Zf)))
        for x, y, l in g.vents(parts):
            sol = sol.cut(cq.Workplane("XY").center(x, y).slot2D(l, 5).extrude(10).translate((0, 0, Zf - 1)))
        for x, y in g.slot_magnets(parts):
            sol = sol.cut(g.hole(x, y, g.DISC_D, Zf - 1, T + 2))
        for x, y in g.plate_screws():
            sol = sol.cut(g.hole(x, y, 3.4, Zf - 1))
            if i:   # the bent model only: the flat pattern shows the 3.4 mm through hole
                sol = sol.cut(cq.Workplane("XY").center(x, y).circle(3.25).workplane(offset=3.25)
                              .circle(0.0001).loft().translate((0, 0, Zf)))      # 90 deg countersink, 6.5 mm
        out.append(sol)
    return out


def plate_parts(parts, cuts, side):
    """(sharp, bent) back or left plate: gen_case's plate with end reliefs,
    then the bend filleted."""
    W, D, Zf = g.W, g.D, g.Z_FLOOR
    zb = Zf + T
    s = g.plate(parts, cuts, side)
    hr = zb + OSSB + RELIEF
    if side == "back":
        s = s.cut(box(T - 1, T + R + RELIEF, D - T - g.PLATE_FLANGE - 1, D + 1, zb - 1, hr))
        s = s.cut(box(W - T - R - RELIEF, W, D - T - g.PLATE_FLANGE - 1, D + 1, zb - 1, hr))
    else:
        s = s.cut(box(-1, T + g.PLATE_FLANGE + 1, T - 1, T + R + RELIEF, zb - 1, hr))
        s = s.cut(box(-1, T + g.PLATE_FLANGE + 1, D - T - g.NOTCH_ROOT, D + 1, zb - 1, hr))
    if side == "back":
        bent = sel(s, (0, D - 0.1, zb - 0.1), (W, D + 0.1, zb + 0.1)).fillet(OSSB)
        bent = sel(bent, (0, D - T - 0.1, zb + T - 0.1), (W, D - T + 0.1, zb + T + 0.1)).fillet(R)
    else:
        bent = sel(s, (-0.1, 0, zb - 0.1), (0.1, D, zb + 0.1)).fillet(OSSB)
        bent = sel(bent, (T - 0.1, 0, zb + T - 0.1), (T + 0.1, D, zb + T + 0.1)).fillet(R)
    return s, bent


# ---------------------------------------------------------------- flat patterns
def rot(sol, axis, deg):
    return sol.rotate((0, 0, 0), axis, deg)


def intervals(sol, axis):
    """[(lo, hi)] along x or y of the separate solids in sol."""
    out = []
    for so in sol.val().Solids() if hasattr(sol.val(), "Solids") else [sol.val()]:
        b = so.BoundingBox()
        out.append((b.xmin, b.xmax) if axis == "x" else (b.ymin, b.ymax))
    return sorted(out)


def flat_tray(sharp):
    """Flat tray in (X, Y), inside face up at z = 0: the floor keeps its x and y;
    the front wall unrolls toward -Y and the right wall toward +X."""
    W, D, Zf, Zt = g.W, g.D, g.Z_FLOOR, g.Z_TOP
    floor = sharp.intersect(box(-1, W - OSSB, OSSB, D + 1, Zf - 1, Zf + T + 0.01)).translate((0, 0, -(Zf + T)))
    front = sharp.intersect(box(-1, W - T - 0.01, -1, T + 0.01, Zf + OSSB, Zt + 1))
    front = rot(front, (1, 0, 0), 90).translate((0, Zf + 2 * OSSB - BA, -T))
    right = sharp.intersect(box(W - T - 0.01, W + 1, -1, D + 1, Zf + OSSB, Zt + 1))
    right = rot(right, (0, 1, 0), 90).translate((W - Zf - 2 * OSSB + BA, 0, W - T))
    bends, lines = [], []
    for x0, x1 in intervals(sharp.intersect(box(-1, W - OSSB, -1, OSSB, Zf - 1, Zf + OSSB)), "x"):
        bends.append(box(x0, x1, OSSB - BA, OSSB, -T, 0))
        lines.append(((x0, OSSB - BA / 2), (x1, OSSB - BA / 2)))
    for y0, y1 in intervals(sharp.intersect(box(W - OSSB, W + 1, OSSB, D + 1, Zf - 1, Zf + OSSB)), "y"):
        bends.append(box(W - OSSB, W - OSSB + BA, y0, y1, -T, 0))
        lines.append(((W - OSSB + BA / 2, y0), (W - OSSB + BA / 2, y1)))
    flat = floor.union(front).union(right)
    for b in bends:
        flat = flat.union(b)
    return flat, lines


def flat_plate(sharp, side):
    """Flat plate seen from inside: X along the plate (x for the back, y for the
    left), the wall up (+Y) from the bend line at Y = 0, the flange down."""
    D, zb = g.D, g.Z_FLOOR + T
    s = sharp if side == "back" else rot(sharp, (0, 0, 1), -90).translate((0, D, 0))
    # now the outside face is at y = D, the inside at D - T, the flange toward -y
    wall = s.intersect(box(-300, 300, D - T - 0.01, D + 1, zb + OSSB, 100))
    wall = rot(wall, (1, 0, 0), -90).translate((0, BA / 2 - (zb + OSSB), D - T))
    flange = s.intersect(box(-300, 300, -300, D - OSSB, zb - 1, zb + T + 0.01))
    flange = flange.translate((0, -D - BA / 2 + OSSB, -(zb + T)))
    flat, lines = wall.union(flange), []
    for x0, x1 in intervals(s.intersect(box(-300, 300, D - OSSB, D + 1, zb - 1, zb + OSSB)), "x"):
        flat = flat.union(box(x0, x1, -BA / 2, BA / 2, -T, 0))
        lines.append(((x0, 0.0), (x1, 0.0)))
    return flat, lines


def flat_cut(sol, z0, t):
    """A flat (cut-only) part laid inside face up at z = 0."""
    return sol.translate((0, 0, -(z0 + t)))


# ---------------------------------------------------------------- outputs
def export_dxf(flat, t, lines, path, notes):
    tmp = path + ".tmp.dxf"
    cq.exporters.export(flat.section(-t / 2), tmp, exportType="DXF")
    doc = ezdxf.readfile(tmp)
    os.remove(tmp)
    doc.layers.add("CUT", color=7)
    doc.layers.add("BEND", color=1)
    doc.layers.add("NOTES", color=3)
    msp = doc.modelspace()
    for e in msp:
        e.dxf.layer = "CUT"
    for (x0, y0), (x1, y1) in lines:
        msp.add_line((x0, y0), (x1, y1), dxfattribs={"layer": "BEND"})
    doc.header["$INSUNITS"] = 4        # mm
    doc.saveas(path)


def outline_xy(flat, t):
    """Edges of the flat pattern's section as polylines, and its circles."""
    sec = flat.section(-t / 2).val()
    polys, circles = [], []
    for e in sec.Edges():
        if e.geomType() == "CIRCLE" and e.IsClosed():
            c = e.Center()
            circles.append((c.x, c.y, e.radius()))
        n = 2 if e.geomType() == "LINE" else 24
        pts = [e.positionAt(i / n) for i in range(n + 1)]
        polys.append([(p.x, p.y) for p in pts])
    return polys, circles


HARDWARE = {
    "tray": ["No PEM hardware in the tray.",
             "14 x 3.4 mm holes with a 90 deg countersink, 6.5 mm on the underside (M3 flat head screws: "
             "8 at the board holes H1-H8 into the floor standoffs, 6 through the plates' flanges into nuts)",
             "10 x 6.0 mm holes for the steel parking discs (the builder presses them in; no hardware)"],
    "back_plate": ["No PEM hardware.", "3 x 3.4 mm plain holes in the flange (M3 screws, loose nuts "
                   "fitted by the builder)"],
    "left_plate": ["No PEM hardware.", "3 x 3.4 mm plain holes in the flange (M3 screws, loose nuts "
                   "fitted by the builder)"],
}
PROCESS = {"tray": "laser cut, bend (press brake), countersink, powder coat",
           "back_plate": "laser cut, bend (press brake), powder coat",
           "left_plate": "laser cut, bend (press brake), powder coat"}
TITLES = {"tray": "Tray: floor, front and right walls (2 bends)",
          "back_plate": "Back plate (1 bend)", "left_plate": "Left plate (1 bend)",
          "acrylic_top": "Top, 4 mm clear acrylic", "slot_cover_plug": "Slot cover plug, 4 mm clear acrylic",
          "slot_cover_cap": "Slot cover cap, 3 mm clear acrylic", "cart_cover_plug": "Cartridge cover plug, 4 mm "
          "clear acrylic", "cart_cover_cap": "Cartridge cover cap, 3 mm clear acrylic"}


def draw_pdf(name, flat, t, lines, path, material, finish, qty, extra, process, tols, bend_note=None):
    polys, circles = outline_xy(flat, t)
    xs = [p[0] for pl in polys for p in pl]
    ys = [p[1] for pl in polys for p in pl]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    fig = plt.figure(figsize=(16.54, 11.69))     # A3 landscape
    ax = fig.add_axes([0.04, 0.30, 0.92, 0.62])
    for pl in polys:
        ax.plot([p[0] for p in pl], [p[1] for p in pl], color="black", lw=0.8)
    for (a, b), (c, d) in lines:
        ax.plot([a, c], [b, d], color="#c0392b", lw=1.0, ls=(0, (6, 3)))
    # overall sizes
    off = 0.06 * max(x1 - x0, y1 - y0)
    ax.annotate("", (x0, y0 - off), (x1, y0 - off), arrowprops=dict(arrowstyle="<->", lw=0.8))
    ax.text((x0 + x1) / 2, y0 - off * 1.25, "%.2f" % (x1 - x0), ha="center", va="top", fontsize=10)
    ax.annotate("", (x1 + off, y0), (x1 + off, y1), arrowprops=dict(arrowstyle="<->", lw=0.8))
    ax.text(x1 + off * 1.2, (y0 + y1) / 2, "%.2f" % (y1 - y0), ha="left", va="center", fontsize=10, rotation=90)
    for i, ((a, b), (c, d)) in enumerate(lines):
        ax.text((a + c) / 2, (b + d) / 2, "BEND %d UP 90 R%.0f" % (i + 1, R), color="#c0392b", fontsize=8,
                ha="center", va="bottom", rotation=90 if abs(a - c) < 1e-6 else 0)
    ax.set_aspect("equal")
    ax.set_xlim(x0 - 2 * off, x1 + 2.5 * off)
    ax.set_ylim(y0 - 2 * off, y1 + off)
    ax.axis("off")
    ax.set_title("%s - flat pattern, inside face up (mm)" % TITLES[name], loc="left", fontsize=13)
    # notes and title block
    holes = {}
    for cx_, cy_, r in circles:
        holes.setdefault(round(2 * r, 2), []).append((cx_, cy_))
    hole_lines = ["%d x %.2f mm" % (len(v), k) for k, v in sorted(holes.items())]
    notes = (["Material: " + material, "Finish: " + finish, "Process: " + process, "Quantity: " + qty] +
             (["Bends: " + bend_note] if bend_note else []) +
             ["Hardware: " + h for h in extra] + ["Round holes: " + ", ".join(hole_lines)] +
             ["Tolerances: " + t_ for t_ in tols] +
             ["Bend lines (red, dashed) at the middle of each bend; all bends up toward the viewer."
              if lines else "Cut only, no bends.",
              "STEP and DXF of the same part: case/quote/step, case/quote/dxf."])
    fig.text(0.04, 0.27, "\n".join(notes), va="top", ha="left", fontsize=9, family="DejaVu Sans", wrap=True)
    fig.text(0.96, 0.04, "PLACARD case  |  %s  |  %s  |  rev %s  |  %s" % (name, TITLES[name], REV, DATE),
             ha="right", va="bottom", fontsize=10, weight="bold")
    with PdfPages(path, metadata={"Title": "PLACARD case - " + TITLES[name], "Subject": "quote drawing"}) as pdf:
        pdf.savefig(fig)
    plt.close(fig)


def build(pcb, out, zip_path):
    parts = g.read_board(pcb)
    cuts = g.wall_cutouts(parts)
    if os.path.isdir(out):
        shutil.rmtree(out)
    for d in ("step", "dxf", "pdf"):
        os.makedirs(os.path.join(out, d))
    rows = []
    # bent metal
    sharp_t, bent_t = tray_parts(parts, cuts)
    metal = {"tray": (bent_t,) + flat_tray(sharp_t)}
    for side in ("back", "left"):
        sh, be = plate_parts(parts, cuts, side)
        metal[side + "_plate"] = (be,) + flat_plate(sh, side)
    qty_metal = "1 per case (quote 1, 10 and 100)"
    for name, (bent, flat, lines) in metal.items():
        cq.exporters.export(bent, os.path.join(out, "step", name + ".step"))
        export_dxf(flat, T, lines, os.path.join(out, "dxf", name + "_flat.dxf"), [])
        draw_pdf(name, flat, T, lines, os.path.join(out, "pdf", name + ".pdf"), MATERIAL, FINISH, qty_metal,
                 HARDWARE[name], PROCESS[name], TOLS,
                 "%d x 90 deg, inside radius %.1f mm" % (len(lines), R))
        b = bent.val().BoundingBox()
        f = flat.val().BoundingBox()
        rows.append(dict(part=name, description=TITLES[name], qty_per_case=1, material=MATERIAL, finish=FINISH,
                         process=PROCESS[name],
                         hardware="; ".join(HARDWARE[name]),
                         size_mm="bent %.1f x %.1f x %.1f; flat %.1f x %.1f" % (b.xlen, b.ylen, b.zlen, f.xlen, f.ylen),
                         files="step/%s.step, dxf/%s_flat.dxf, pdf/%s.pdf" % (name, name, name)))
    # acrylic
    acr_tols = ["Laser cut +/-0.15 mm, holes +0.1/-0 mm (magnet holes 6.1 mm: a 6 mm magnet is a slip fit)",
                "Unless shown: ISO 2768-m"]
    top = g.acrylic_top(parts)
    sc = g.slot_covers(parts)[0]
    cc = g.cart_cover(parts)
    zt, A, C = g.Z_TOP, g.ACRYLIC, g.CAP
    acr = {"acrylic_top": (flat_cut(top, zt, A), A, 1, "4 mm"),
           "slot_cover_plug": (flat_cut(sc.intersect(box(-1, 400, -1, 400, zt - 1, zt + A)), zt, A), A, 4, "4 mm"),
           "slot_cover_cap": (flat_cut(sc.intersect(box(-1, 400, -1, 400, zt + A, zt + A + C + 1)), zt + A, C),
                              C, 4, "3 mm"),
           "cart_cover_plug": (flat_cut(cc.intersect(box(-1, 400, -1, 400, zt - 1, zt + A)), zt, A), A, 1, "4 mm"),
           "cart_cover_cap": (flat_cut(cc.intersect(box(-1, 400, -1, 400, zt + A, zt + A + C + 1)), zt + A, C),
                              C, 1, "3 mm")}
    for name, (flat, t, q, th) in acr.items():
        mat = "Clear cast acrylic (PMMA), %s, protective film both sides" % th
        cq.exporters.export(flat, os.path.join(out, "step", name + ".step"))
        export_dxf(flat, t, [], os.path.join(out, "dxf", name + ".dxf"), [])
        draw_pdf(name, flat, t, [], os.path.join(out, "pdf", name + ".pdf"), mat, "none (clear, as cut; "
                 "flame-polished or clean laser edges)", "%d per case" % q, [], "laser cut", acr_tols)
        f = flat.val().BoundingBox()
        rows.append(dict(part=name, description=TITLES[name], qty_per_case=q, material=mat, finish="none",
                         process="laser cut", hardware="", size_mm="%.1f x %.1f x %.0f" % (f.xlen, f.ylen, t),
                         files="step/%s.step, dxf/%s.dxf, pdf/%s.pdf" % (name, name, name)))
    with open(os.path.join(out, "PARTS.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(out, "README.md"), "w") as fh:
        fh.write(readme(rows))
    if zip_path:
        os.makedirs(os.path.dirname(zip_path), exist_ok=True)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            for root, _, files in os.walk(out):
                for fn in sorted(files):
                    p = os.path.join(root, fn)
                    z.write(p, os.path.join("placard_case_quote", os.path.relpath(p, out)))
    return rows


def readme(rows):
    lines = ["# PLACARD case: quote package", "", "Date: %s  " % DATE, "Revision: %s" % REV, "",
             "Everything a sheet metal service or a laser cutter needs to quote the PLACARD computer case:",
             "three bent aluminium parts and the clear acrylic top and covers. Quote quantities 1, 10 and "
             "100 sets.", "", "## Parts", "",
             "| Part | Qty per case | Material | Finish | Process | Size (mm) |", "|---|--:|---|---|---|---|"]
    for r in rows:
        lines.append("| %s | %s | %s | %s | %s | %s |" % (r["part"], r["qty_per_case"], r["material"],
                                                         r["finish"], r["process"], r["size_mm"]))
    lines += ["", "PARTS.csv has the same list with the hardware and the files for each part.", "",
              "## Files", "",
              "- `step/`: 3D models. The tray and plates are bent, with %.1f mm inside bend radius and "
              "corner and end reliefs. The acrylic parts are flat." % R,
              "- `dxf/`: cutting files in mm. `*_flat.dxf` are the flat patterns of the bent parts: layer "
              "CUT is the outline and holes, and layer BEND is the bend lines, at the middle of each bend. "
              "All bends go up 90 degrees toward the viewer, with the inside face up.",
              "- `pdf/`: one A3 drawing per part, with the flat pattern, overall sizes, bends, hole sizes, "
              "hardware, material, finish and tolerances.", "",
              "## Sheet metal (tray, back plate, left plate)", "",
              "- %s." % MATERIAL,
              "- Four bends in all (two in the tray, one in each plate), each 90 degrees, inside radius "
              "%.1f mm. The flat patterns use K = %.2f (bend allowance %.3f mm). Please develop the flat "
              "from the STEP with your own bend tables and tell us if anything changes." % (R, K_FACTOR, BA),
              "- No PEM or other pressed hardware in any part. Each plate's flange has 3 plain 3.4 mm "
              "holes.",
              "- Tray: 14 countersunk holes, 90 degrees, 6.5 mm on the underside.",
              "- Finish: black powder coat on all three parts, in a stock color, matte or fine texture. "
              "Mask the tray's 14 countersinks.",
              "- No printing, engraving or silkscreen.",
              "- Some cut-outs sit close to a bend, so check them. On the back plate, the bottom of the "
              "USB-C cut-out is about 1.8 mm above the bend tangent. On the left plate, the bottom of the "
              "SD slot is about 3 mm above it. Tell us if those need moving or cutting after the bend.",
              "- Suggested services:",
              "  - SendCutSend: upload the STEP for bent parts, or the flat DXF for the cut alone.",
              "  - PCBWay sheet metal, Xometry and Protocase: STEP plus the PDF.", "",
              "## Acrylic (top and covers)", "",
              "- Clear cast acrylic, 4 mm (the top and the cover plugs) and 3 mm (the cover caps), laser cut "
              "from the DXF.",
              "- The 6.1 mm holes take 6 x 3 mm magnets, which we glue in ourselves.",
              "- Per case: 1 top, 4 slot cover plugs and 4 caps, 1 cartridge cover plug and 1 cap.", "",
              "## Not in this package", "",
              "- Fasteners, standoffs, magnets, steel discs and feet. We supply those; see "
              "docs/BOM_CASE.md in the PLACARD repository.",
              "- The magnet gluing jig, which is tooling made once, is in case/dxf/magnet_jig_*.", "",
              "Made by `src/scripts/gen_case_quote.py` from the board file. Rerun it after the board or the "
              "case changes.", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcb", default=os.path.join(g.REPO, "kicad", "placard.kicad_pcb"))
    ap.add_argument("--out", default=os.path.join(g.REPO, "case", "quote"))
    ap.add_argument("--zip", default=os.path.join(g.REPO, "case", "quote.zip"))
    a = ap.parse_args()
    for r in build(a.pcb, a.out, a.zip):
        print("%-16s %s" % (r["part"], r["size_mm"]))
