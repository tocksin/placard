#!/usr/bin/env python3
"""
gen_board_pictures.py - draw the board pictures in docs/hardware/ from the
board files as they are now.

    python3 src/scripts/gen_board_pictures.py            # all pictures
    python3 src/scripts/gen_board_pictures.py main       # one board (main, cart32k, cart64k)

Writes, for the main board, the 32K cartridge and the 64K cartridge:

    docs/hardware/placard_board_layout.png   3D view from above (parts and silkscreen)
    docs/hardware/placard_board_routing.png  copper: front red, back blue, on the outline
    docs/hardware/cart_board_32k.png         3D view of the component side
    docs/hardware/cart_board_64k.png

The board files are only read: each is copied to a temporary folder first,
with the project's libraries, so nothing in kicad/ changes.  Rerun it after
a layout change.

Needs KiCad 9 (kicad-cli), rsvg-convert (librsvg2-bin) and Pillow.

Date: 2026-11-11
"""
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "docs", "hardware")

# name: (board file under kicad/, 3D picture, render size, copper picture or None)
BOARDS = {
    "main": ("placard.kicad_pcb", "placard_board_layout.png", (3200, 2400), "placard_board_routing.png"),
    "cart32k": ("cartridge_32k/cartridge_32k.kicad_pcb", "cart_board_32k.png", (1200, 1800), None),
    "cart64k": ("cartridge_64k/cartridge_64k.kicad_pcb", "cart_board_64k.png", (1200, 2400), None),
}
BG = (255, 255, 255)


def run(*cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        sys.exit("%s\n%s" % (" ".join(cmd), r.stdout))


def crop(path, margin=24):
    """Trim the empty border, leave a small margin, put it on white."""
    im = Image.open(path).convert("RGBA")
    box = im.getchannel("A").getbbox()
    if box:
        im = im.crop(box)
    out = Image.new("RGB", (im.width + 2 * margin, im.height + 2 * margin), BG)
    out.paste(im, (margin, margin), im)
    out.save(path, optimize=True)


def render(pcb, out, size):
    run("kicad-cli", "pcb", "render", "--side", "top", "--quality", "basic",
        "--background", "transparent", "--width", str(size[0]), "--height", str(size[1]),
        "-o", out, pcb)
    crop(out)


def copper(pcb, out, tmp, width=3200):
    """F.Cu red over B.Cu blue on the outline, tracks and pads only (the
    inner layers are planes)."""
    layers = {}
    for layer in ("B.Cu", "F.Cu"):
        svg = os.path.join(tmp, layer + ".svg")
        run("kicad-cli", "pcb", "export", "svg", "--layers", layer + ",Edge.Cuts",
            "--mode-single", "--black-and-white", "--exclude-drawing-sheet",
            "--page-size-mode", "2", "-o", svg, pcb)
        png = os.path.join(tmp, layer + ".png")
        run("rsvg-convert", "-w", str(width), "-b", "white", "-o", png, svg)
        layers[layer] = Image.open(png).convert("L")
    w, h = layers["F.Cu"].size
    img = Image.new("RGB", (w, h), BG)
    for layer, color in (("B.Cu", (60, 110, 220)), ("F.Cu", (200, 50, 40))):
        mask = layers[layer].point(lambda v: 255 - v)
        img.paste(Image.new("RGB", (w, h), color), (0, 0), mask)
    # the plot's page can be larger than the board: trim to what is drawn
    box = Image.eval(img.convert("L"), lambda v: 255 if v < 250 else 0).getbbox()
    m = 24
    img = img.crop((max(box[0] - m, 0), max(box[1] - m, 0), min(box[2] + m, w), min(box[3] + m, h)))
    img.save(out, optimize=True)


def main():
    want = sys.argv[1:] or list(BOARDS)
    with tempfile.TemporaryDirectory() as tmp:
        work = os.path.join(tmp, "kicad")
        shutil.copytree(os.path.join(ROOT, "kicad"), work,
                        ignore=shutil.ignore_patterns("fab", "*-backups", "*.kicad_prl"))
        for name in want:
            board, pic, size, cu = BOARDS[name]
            pcb = os.path.join(work, board)
            render(pcb, os.path.join(OUT, pic), size)
            print("wrote", os.path.join("docs", "hardware", pic))
            if cu:
                copper(pcb, os.path.join(OUT, cu), tmp)
                print("wrote", os.path.join("docs", "hardware", cu))


if __name__ == "__main__":
    main()
