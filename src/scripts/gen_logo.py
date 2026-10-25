#!/usr/bin/env python3
"""
gen_logo.py - draw the PLACARD logo concepts in docs/logo/.

    python3 gen_logo.py            writes the SVGs, PNG previews and the
                                   comparison sheet docs/logo/logo_concepts.png

Five concepts, all one ink colour so they work as PCB silkscreen, case
engraving and README art:

    a_plaque    a screwed-on nameplate: double border, four slotted screws
    b_chip      the name on the top of a 24-pin DIP (the ATF22V10C package)
    c_pixel     the name in the machine's own 8x8 ROM font, on a plaque
    d_fusemap   the letters as blown/intact fuses ("X") in a PLA array
    e_raster    a sign hung from a nail, letters cut by video scan lines

Each concept is written as <name>.svg (black ink on transparent) and
<name>.png.  Plaques also have an _inverse.svg (solid plate, letters cut
out), which is the form for a filled silkscreen badge or an anodised
plate.  a_plaque has a brass colour version for the README.

All lettering is converted to outlines, so the SVGs need no fonts.  The
outlines come from Inter Display (SIL Open Font License) and from the
8x8 font in gen_lib_font.py.  Needs fonttools, cairosvg and Pillow
(pip install fonttools cairosvg pillow) and the Inter font files
(apt-get install fonts-inter).

Date: 2026-10-25
"""

import io
import math
import os
import random
import sys

import cairosvg
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen_lib_font import FONT  # noqa: E402

OUT = os.path.join(HERE, "..", "..", "docs", "logo")
FONT_DIR = "/usr/share/fonts/opentype/inter"
INK = "#000000"
NAME = "PLACARD"


# ---------------------------------------------------------------- lettering

_fonts = {}


def font(name):
    if name not in _fonts:
        _fonts[name] = TTFont(os.path.join(FONT_DIR, name))
    return _fonts[name]


def text_path(text, fontname, cx, baseline, cap_height, tracking=0.0,
              width=None):
    """Outline `text` centred on cx.  cap_height sets the size; if width is
    given the text is scaled to fill it instead.  tracking is extra space
    between letters as a fraction of the cap height.  Returns (d, w, h)."""
    f = font(fontname)
    gs = f.getGlyphSet()
    cmap = f.getBestCmap()
    upm = f["head"].unitsPerEm
    cap = f["OS/2"].sCapHeight or 0.7 * upm
    names = [cmap[ord(c)] for c in text]
    adv = [gs[n].width for n in names]
    track = tracking * cap
    raw_w = sum(adv) + track * (len(text) - 1)
    # drop the side bearing of the last letter so centring is visual
    s = cap_height / cap
    if width is not None:
        s = width / raw_w
    total = raw_w * s
    x = cx - total / 2
    pen = SVGPathPen(gs)
    for n, a in zip(names, adv):
        tp = TransformPen(pen, (s, 0, 0, -s, x, baseline))
        gs[n].draw(tp)
        x += (a + track) * s
    return pen.getCommands(), total, cap * s


def pixel_rects(text, x0, y0, px, gap=0):
    """Squares for `text` in the ROM font, top left at (x0, y0), px per
    pixel.  Each character is 8 wide; trailing blank columns are trimmed
    so the spacing is even.  Returns (list of (x, y), width)."""
    cells = []
    x = x0
    for c in text:
        rows = FONT[ord(c) - 0x20]
        used = [col for col in range(8) if any((r >> col) & 1 for r in rows)]
        lo, hi = min(used), max(used)
        for ry, r in enumerate(rows):
            for col in range(lo, hi + 1):
                if (r >> col) & 1:
                    cells.append((x + (col - lo) * px, y0 + ry * px))
        x += (hi - lo + 1 + gap) * px
    return cells, x - x0 - gap * px


GLYPH5x7 = {
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "D": ["11100", "10010", "10001", "10001", "10001", "10010", "11100"],
}


# ---------------------------------------------------------------- shapes

def rrect(x, y, w, h, r):
    return (f"M{x + r:.2f},{y:.2f} H{x + w - r:.2f} "
            f"A{r},{r} 0 0 1 {x + w:.2f},{y + r:.2f} V{y + h - r:.2f} "
            f"A{r},{r} 0 0 1 {x + w - r:.2f},{y + h:.2f} H{x + r:.2f} "
            f"A{r},{r} 0 0 1 {x:.2f},{y + h - r:.2f} V{y + r:.2f} "
            f"A{r},{r} 0 0 1 {x + r:.2f},{y:.2f} Z")


def circle(cx, cy, r):
    return (f"M{cx - r:.2f},{cy:.2f} A{r},{r} 0 1 0 {cx + r:.2f},{cy:.2f} "
            f"A{r},{r} 0 1 0 {cx - r:.2f},{cy:.2f} Z")


def rect(x, y, w, h):
    return f"M{x:.2f},{y:.2f} h{w:.2f} v{h:.2f} h{-w:.2f} Z"


def screw(cx, cy, r, angle):
    """Slotted screw head: ring with a slot.  Returns filled path data
    (evenodd): disc minus slot."""
    a = math.radians(angle)
    sw = r * 0.34
    dx, dy = math.cos(a), math.sin(a)
    nx, ny = -dy, dx
    L = r * 0.72
    pts = [(cx + dx * L + nx * sw / 2, cy + dy * L + ny * sw / 2),
           (cx - dx * L + nx * sw / 2, cy - dy * L + ny * sw / 2),
           (cx - dx * L - nx * sw / 2, cy - dy * L - ny * sw / 2),
           (cx + dx * L - nx * sw / 2, cy + dy * L - ny * sw / 2)]
    slot = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"
    return circle(cx, cy, r) + " " + slot


def svg(w, h, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" '
            f'width="{w}" height="{h}">\n<title>{title}</title>\n'
            f'{body}\n</svg>\n')


def fill(d, color=INK, rule="nonzero", extra=""):
    return f'<path d="{d}" fill="{color}" fill-rule="{rule}"{extra}/>'


def stroke(d, width, color=INK, extra=""):
    return (f'<path d="{d}" fill="none" stroke="{color}" '
            f'stroke-width="{width}" stroke-linejoin="round"{extra}/>')


# ---------------------------------------------------------------- concepts

SCREW_ANGLES = (35, -20, 75, 10)   # slots point different ways, like real ones


def a_plaque(variant="line", ink=INK, plate=None):
    """Nameplate.  variant line = outline plate, inverse = solid plate
    with the letters and screws cut out; plate sets a second colour
    (brass version) instead of cutting out."""
    W, H = 640, 220
    outer = rrect(8, 8, W - 16, H - 16, 30)
    d_text, tw, th = text_path(NAME, "InterDisplay-Black.otf", W / 2,
                               H / 2 + 33, 66, tracking=0.16, width=430)
    screws = [screw(x, y, 12, a) for (x, y), a in zip(
        [(44, 44), (W - 44, 44), (44, H - 44), (W - 44, H - 44)],
        SCREW_ANGLES)]
    if variant == "line":
        body = [stroke(rrect(13, 13, W - 26, H - 26, 25), 10, ink),
                stroke(rrect(70, 30, W - 140, H - 60, 12), 4, ink),
                fill(d_text, ink)]
        body += [fill(s, ink, "evenodd") for s in screws]
    elif plate is None:
        # one path, evenodd: plate, minus letters, minus screw holes
        # (screws drawn as ring + slot so they read as heads, not holes)
        holes = " ".join(circle(x, y, 16) for x, y in
                         [(44, 44), (W - 44, 44), (44, H - 44),
                          (W - 44, H - 44)])
        frame = rrect(70, 30, W - 140, H - 60, 12) + " " + \
            rrect(74, 34, W - 148, H - 68, 8)
        body = [fill(" ".join([outer, d_text, holes, frame]), ink, "evenodd")]
        body += [fill(s, ink, "evenodd") for s in screws]
    else:
        holes = [circle(x, y, 16) for x, y in
                 [(44, 44), (W - 44, 44), (44, H - 44), (W - 44, H - 44)]]
        body = [fill(outer, plate),
                stroke(rrect(15, 15, W - 30, H - 30, 23), 3, ink,
                       ' opacity="0.55"'),
                stroke(rrect(70, 30, W - 140, H - 60, 12), 4, ink),
                fill(d_text, ink)]
        body += [fill(s, ink, "evenodd") for s in screws]
    return W, H, "\n".join(body)


def b_chip(ink=INK):
    """24-pin DIP seen from above, PLACARD on the lid."""
    pins = 12
    pitch = 46
    W = pins * pitch + 40
    H = 250
    bx, by, bw, bh = 14, 52, W - 28, H - 104
    body = [stroke(rrect(bx, by, bw, bh, 10), 9, ink)]
    # notch at the pin-1 end
    nr = 16
    body.append(fill(f"M{bx:.2f},{by + bh / 2 - nr:.2f} "
                     f"A{nr},{nr} 0 0 1 {bx:.2f},{by + bh / 2 + nr:.2f} Z",
                     ink))
    # pin 1 dot
    body.append(fill(circle(bx + 34, by + bh - 26, 8), ink))
    x0 = (W - (pins - 1) * pitch) / 2
    pin = []
    for i in range(pins):
        x = x0 + i * pitch
        pin.append(rect(x - 11, 10, 22, by - 10 - 2))
        pin.append(rect(x - 11, by + bh + 2, 22, H - 10 - by - bh - 2))
    body.append(fill(" ".join(pin), ink))
    d_text, tw, th = text_path(NAME, "InterDisplay-Black.otf", W / 2 + 12,
                               by + bh / 2 + 26, 52, tracking=0.14,
                               width=bw - 190)
    body.append(fill(d_text, ink))
    return W, H, "\n".join(body)


def c_pixel(variant="inverse", ink=INK):
    """ROM-font lettering on a plaque."""
    px = 10
    cells, tw = pixel_rects(NAME, 0, 0, px, gap=1)
    W = int(tw + 200)
    H = 7 * px + 130
    x0 = (W - tw) / 2
    y0 = (H - 7 * px) / 2
    pix = " ".join(rect(x0 + x, y0 + y, px, px) for x, y in cells)
    holes = [(38, 38), (W - 38, 38), (38, H - 38), (W - 38, H - 38)]
    if variant == "inverse":
        # square-cornered "pixel" holes so the screws match the lettering
        hole = " ".join(rect(x - 10, y - 10, 20, 20) for x, y in holes)
        plate = rrect(6, 6, W - 12, H - 12, 18)
        body = [fill(" ".join([plate, pix, hole]), ink, "evenodd")]
    else:
        body = [stroke(rrect(11, 11, W - 22, H - 22, 14), 10, ink),
                fill(pix, ink),
                fill(" ".join(rect(x - 10, y - 10, 20, 20)
                              for x, y in holes), ink)]
    return W, H, "\n".join(body)


def d_fusemap(ink=INK):
    """PLA fuse map: horizontal input lines, vertical product-term lines,
    an X at every intact fuse.  The X pattern spells the name in 5x7."""
    cell = 16
    cols = len(NAME) * 6 - 1
    rows = 7
    ox, oy = 70, 44
    gw, gh = cols * cell, rows * cell
    W = int(ox + gw + 40)
    H = int(oy + gh + 50)
    body = []
    lines = []
    for r in range(rows):
        y = oy + r * cell + cell / 2
        lines.append(f"M{ox - 14:.2f},{y:.2f} H{ox + gw:.2f}")
    for c in range(cols):
        if c % 6 == 5:
            continue                # no product line between letters
        x = ox + c * cell + cell / 2
        lines.append(f"M{x:.2f},{oy - 12:.2f} V{oy + gh + 8:.2f}")
    body.append(stroke(" ".join(lines), 1.8, ink, ' stroke-linecap="butt"'))
    # input buffers on the left (triangles), as drawn in PLA data sheets
    tri = []
    for r in range(rows):
        y = oy + r * cell + cell / 2
        tri.append(f"M{ox - 44:.2f},{y - 6:.2f} L{ox - 30:.2f},{y:.2f} "
                   f"L{ox - 44:.2f},{y + 6:.2f} Z")
    body.append(fill(" ".join(tri), ink))
    xs = []
    a = cell * 0.40
    for i, ch in enumerate(NAME):
        g = GLYPH5x7[ch]
        for r in range(rows):
            for c in range(5):
                if g[r][c] == "1":
                    cx = ox + (i * 6 + c) * cell + cell / 2
                    cy = oy + r * cell + cell / 2
                    xs.append(f"M{cx - a:.2f},{cy - a:.2f} L{cx + a:.2f},"
                              f"{cy + a:.2f} M{cx + a:.2f},{cy - a:.2f} "
                              f"L{cx - a:.2f},{cy + a:.2f}")
    body.append(stroke(" ".join(xs), 5.2, ink, ' stroke-linecap="round"'))
    # bracket frame top and bottom like a placard edge
    body.append(stroke(rrect(8, 8, W - 16, H - 16, 14), 6, ink))
    return W, H, "\n".join(body)


def e_raster(ink=INK):
    """Hanging sign; letters sliced by scan lines that get thicker downward."""
    W, H = 640, 300
    py, ph = 104, 176
    body = []
    # nail and cord
    nail = (W / 2, 26)
    eye_l, eye_r = (110, py + 20), (W - 110, py + 20)
    body.append(stroke(f"M{eye_l[0]},{eye_l[1]} L{nail[0]},{nail[1]} "
                       f"L{eye_r[0]},{eye_r[1]}", 5, ink,
                       ' stroke-linecap="round"'))
    body.append(fill(circle(*nail, 12), ink))
    plate = rrect(30, py, W - 60, ph, 22)
    eyes = circle(*eye_l, 9) + " " + circle(*eye_r, 9)
    inner = rrect(42, py + 12, W - 84, ph - 24, 14)
    body.append(fill(plate + " " + inner, ink, "evenodd"))
    # letters, then clip with stripes
    d_text, tw, th = text_path(NAME, "InterDisplay-Black.otf", W / 2,
                               py + ph / 2 + 36, 72, tracking=0.08, width=480)
    top = py + ph / 2 + 36 - th
    bot = py + ph / 2 + 36
    stripes = []
    y = top - 1
    n = 9
    for k in range(n):
        frac = k / (n - 1)
        h = (th + 2) / n
        gap = 1.0 + 4.2 * frac          # gaps grow towards the bottom
        stripes.append(rect(0, y, W, h - gap))
        y += h
    body.insert(0, '<defs><clipPath id="scan"><path d="'
                + " ".join(stripes) + '"/></clipPath></defs>')
    body.append(fill(d_text, ink, extra=' clip-path="url(#scan)"'))
    # punch the cord eyes through the plate border
    body.append(fill(eyes + " " + circle(*eye_l, 4) + " "
                     + circle(*eye_r, 4), ink, "evenodd"))
    return W, H, "\n".join(body)


# ---------------------------------------------------------------- output

def write(name, wh_body, title):
    W, H, body = wh_body
    s = svg(W, H, body, title)
    path = os.path.join(OUT, name + ".svg")
    with open(path, "w") as f:
        f.write(s)
    png = cairosvg.svg2png(bytestring=s.encode(), output_width=1200)
    with open(os.path.join(OUT, name + ".png"), "wb") as f:
        f.write(png)
    return s


def render(s, width, ink=None):
    """SVG string -> RGBA image `width` wide, optionally recoloured."""
    if ink is not None:
        s = s.replace(INK, ink)
    png = cairosvg.svg2png(bytestring=s.encode(), output_width=width)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def brushed(w, h):
    rnd = random.Random(7)
    img = Image.new("L", (w, h))
    px = img.load()
    for y in range(h):
        base = 182 + rnd.randint(-10, 10)
        for x in range(w):
            px[x, y] = base + rnd.randint(-6, 6)
    # stretch the noise sideways into horizontal streaks
    streak = img.resize((max(1, w // 40), h)).resize((w, h), Image.BILINEAR)
    return Image.merge("RGB", (streak, streak, streak.point(lambda v: v + 6)))


def sheet(concepts):
    """Comparison sheet: each concept on white, as white silkscreen on a
    green board at about 25 mm wide (8 px/mm, like a close-up photo), and
    engraved on brushed aluminium."""
    colw = [520, 300, 520]
    rowh = 250
    head = 70
    W = sum(colw) + 4 * 30
    H = head + rowh * len(concepts) + 30
    img = Image.new("RGB", (W, H), "#ffffff")
    dr = ImageDraw.Draw(img)
    try:
        fb = ImageFont.truetype(os.path.join(FONT_DIR, "Inter-Bold.otf"), 22)
        fr = ImageFont.truetype(os.path.join(FONT_DIR, "Inter-Medium.otf"),
                                17)
    except OSError:
        fb = fr = ImageFont.load_default()
    xs = [30, 30 + colw[0] + 30, 30 + colw[0] + colw[1] + 60]
    for x, t in zip(xs, ["README (ink)", "Silkscreen, 25 mm wide",
                         "Engraved on brushed aluminium"]):
        dr.text((x, 24), t, fill="#333333", font=fb)
    for i, (label, s) in enumerate(concepts):
        y = head + i * rowh
        dr.text((xs[0], y + 4), label, fill="#666666", font=fr)
        # README
        im = render(s, colw[0] - 40)
        img.paste(im, (xs[0] + 20, y + 30 + (rowh - 50 - im.height) // 2), im)
        # silkscreen: 25 mm at 8 px/mm = 200 px, on solder-mask green
        cell = Image.new("RGB", (colw[1], rowh - 30), "#1d5b33")
        im = render(s, 200, ink="#f4f4ec")
        cell.paste(im, ((colw[1] - 200) // 2,
                        (cell.height - im.height) // 2), im)
        img.paste(cell, (xs[1], y + 26))
        # aluminium
        cell = brushed(colw[2], rowh - 30)
        im = render(s, colw[2] - 60, ink="#3a3d42")
        cell.paste(im, (30, (cell.height - im.height) // 2), im)
        img.paste(cell, (xs[2], y + 26))
    img.save(os.path.join(OUT, "logo_concepts.png"))


def main():
    os.makedirs(OUT, exist_ok=True)
    out = []
    s = write("a_plaque", a_plaque("line"), "PLACARD - nameplate")
    out.append(("A  Nameplate", s))
    write("a_plaque_inverse", a_plaque("inverse"),
          "PLACARD - nameplate, solid")
    write("a_plaque_brass", a_plaque("brass", ink="#2b2116",
                                     plate="#c9a24a"),
          "PLACARD - brass nameplate")
    out.append(("B  Chip", write("b_chip", b_chip(), "PLACARD - DIP chip")))
    out.append(("C  ROM font", write("c_pixel", c_pixel("inverse"),
                                     "PLACARD - ROM font plaque")))
    write("c_pixel_line", c_pixel("line"), "PLACARD - ROM font, outline")
    out.append(("D  Fuse map", write("d_fusemap", d_fusemap(),
                                     "PLACARD - PLA fuse map")))
    out.append(("E  Hanging sign", write("e_raster", e_raster(),
                                         "PLACARD - hanging sign")))
    sheet(out)
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
