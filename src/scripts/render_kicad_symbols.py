#!/usr/bin/env python3
"""
render_kicad_symbols.py - draw the project's KiCad symbols as PNG review sheets.

    python3 render_kicad_symbols.py OUTDIR

Exports every symbol of kicad/lib/placard.kicad_sym and placard_parts.kicad_sym
with kicad-cli (KiCad 7+), converts them to PNG at one scale (cairosvg), and
lays them out in rows with the symbol's name over each one:
OUTDIR/kicad_symbols_pld.png, kicad_symbols_parts.png, and
kicad_symbols_stock.png with the KiCad library symbols the board uses
(STOCK below).  Needs kicad-cli, cairosvg and Pillow.

Date: 2026-10-23
"""

import glob
import os
import re
import subprocess
import sys
import tempfile

import cairosvg
from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
LIB = os.path.join(ROOT, "kicad", "lib")
KICAD_SYMS = "/usr/share/kicad/symbols"
PX_PER_MM = 16
MAX_W = 3600                   # sheet width in pixels

# KiCad library symbols for the other parts: (library, symbol, what it is on the board)
STOCK = [
    ("74xx", "74LS377", "SN74F377AN x7: IR, D, AC, X, Y, pixel buffer, line code"),
    ("74xx", "74LS541", "SN74F541N x3: D and AC source drivers, line read, port input"),
    ("74xx", "74HC273", "CD74ACT273E: ROM/RAM map register"),
    ("74xx", "74HCT574", "SN74HCT574N audio DAC, SN74HC574N port latch"),
    ("Oscillator", "ACO-xxxMHz", "25.175 MHz clock oscillator (DIP-14 can)"),
    ("Regulator_Linear", "MCP1700x-330xxTO", "U40: 3.3 V for the SD card (MCP1700-3302E/TO)"),
    ("Connector", "DE15_Receptacle_HighDensity_MountingHoles", "VGA"),
    ("Connector", "SD_Card", "J4: SD socket"),
    ("Connector_Audio", "AudioJack3", "J6: audio line out"),
    ("Device", "R_Network08", "10k pull-ups, data bus and keyboard rows"),
]


def font(size):
    for f in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def export(lib, outdir, symbol=None):
    cmd = ["kicad-cli", "sym", "export", "svg", "-o", outdir, lib]
    if symbol:
        cmd[4:4] = ["-s", symbol]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def png(svg):
    out = svg[:-4] + ".png"
    cairosvg.svg2png(url=svg, write_to=out, scale=PX_PER_MM / 3.7795, background_color="white")
    im = Image.open(out).convert("RGB")
    bg = Image.new("RGB", im.size, "white")
    box = ImageChops.difference(im, bg).getbbox()
    return im.crop(box) if box else im


def sheet(items, title, out):
    """items: (label, sublabel, image)"""
    tf, lf, sf = font(64), font(40), font(30)
    pad, gap = 50, 70
    rows, row, x = [], [], pad
    for it in items:
        w = int(max(it[2].width, lf.getlength(it[0]), sf.getlength(it[1])))
        if row and x + w > MAX_W - pad:
            rows.append(row)
            row, x = [], pad
        row.append((x, w, it))
        x += w + gap
    rows.append(row)
    heights = [max(it[2].height for _, _, it in r) + 110 for r in rows]
    H = 140 + sum(heights) + gap * len(rows)
    W = min(MAX_W, max(x + w for r in rows for x, w, _ in r[-1:]) + pad)
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    d.text((pad, 40), title, font=tf, fill="black")
    y = 160
    for r, h in zip(rows, heights):
        for x, w, (label, sub, im) in r:
            d.text((x, y), label, font=lf, fill="black")
            if sub:
                d.text((x, y + 48), sub, font=sf, fill=(90, 90, 90))
            img.paste(im, (x, y + 110))
        y += h + gap
    img.save(out)
    print("wrote", out, img.size)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(outdir, exist_ok=True)
    tmp = tempfile.mkdtemp()
    for lib, name, title in (("placard.kicad_sym", "kicad_symbols_pld.png",
                              "placard.kicad_sym: PLD symbols"),
                             ("placard_parts.kicad_sym", "kicad_symbols_parts.png",
                              "placard_parts.kicad_sym: other project symbols")):
        path = os.path.join(LIB, lib)
        d = os.path.join(tmp, lib)
        os.makedirs(d)
        export(path, d)
        names = re.findall(r'(?m)^  \(symbol "([^"]+)"', open(path).read())
        items = [(n, "", png(os.path.join(d, n.lower() + ".svg"))) for n in names]
        sheet(items, title, os.path.join(outdir, name))
    items = []
    for lib, sym, what in STOCK:
        d = os.path.join(tmp, "stock_" + sym)
        os.makedirs(d)
        export(os.path.join(KICAD_SYMS, lib + ".kicad_sym"), d, sym)
        svg = glob.glob(os.path.join(d, "*.svg"))[0]
        items.append(("%s:%s" % (lib, sym), what, png(svg)))
    sheet(items, "KiCad library symbols used for the other parts", os.path.join(outdir, "kicad_symbols_stock.png"))


if __name__ == "__main__":
    main()
