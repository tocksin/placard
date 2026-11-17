#!/usr/bin/env python3
"""gen_hires_fold_example.py - docs/video/hires_fold_example.png

A 320 x 480, 16-color screen in the fold mode of a rev B board (mode byte
x82: 160-read line, repeat code 00, 4 bpp; docs/video/HIRES.md), rendered
by placard_sim.py: left alone, and with 36 rows rewritten between the two
passes of the beam.

    python3 gen_hires_fold_example.py [out.png]

Date: 2026-11-17
"""
import tempfile
import sys, math
import os
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps
from PIL import Image, ImageDraw, ImageFont
pal4 = [(r * 255 // 7, g * 255 // 7, b * 255 // 3) for r, g, b in (
    (0, 0, 0), (0, 0, 1), (4, 0, 2), (0, 0, 3), (7, 0, 0), (7, 0, 3), (4, 2, 0), (2, 2, 1),
    (0, 7, 3), (0, 4, 0), (7, 7, 3), (5, 5, 2), (7, 4, 2), (7, 4, 0), (7, 7, 0), (1, 7, 0))]
F = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
def scene(band_text, band_col):
    """a 320 x 256 picture in palette indexes: rows 0-223 the shared part, 224-255 the own band"""
    im = Image.new('P', (320, 256), 3)
    im.putpalette([c for p in pal4 for c in p] + [0] * (768 - 48))
    d = ImageDraw.Draw(im)
    for y in range(224):                       # sky bands
        d.line([(0, y), (319, y)], fill=[1, 3, 8, 10][min(3, y // 40)] if y < 150 else 9)
    d.ellipse([230, 22, 280, 72], fill=14)     # sun
    d.polygon([(0, 150), (60, 70), (110, 130), (170, 50), (240, 140), (319, 90), (319, 150)], fill=7)
    d.polygon([(150, 80), (170, 50), (190, 80), (178, 74), (168, 82), (160, 72)], fill=10)
    for x in range(0, 320, 16):                # field stripes
        d.polygon([(x, 223), (x + 8, 223), (160 + (x + 8 - 160) // 3, 150), (160 + (x - 160) // 3, 150)], fill=15)
    f = ImageFont.truetype(F, 26)
    d.text((14, 12), 'PLACARD', font=f, fill=10)
    d.text((14, 180), '320 x 480, 16 colors', font=ImageFont.truetype(F, 16), fill=0)
    d.rectangle([0, 224, 319, 255], fill=band_col)
    d.text((8, 229), band_text, font=ImageFont.truetype(F, 18), fill=10)
    return im
def to_mem(im, mem, rows):
    px = im.load()
    for row in rows:
        v = (row + 32) & 0xFF                 # the fold: low byte v7:v0
        src = row if row < 256 else row - 256
        for col in range(160):
            b = px[col * 2, src] | px[col * 2 + 1, src] << 4
            mem[0x6000 + (col >> 1) * 512 + (col & 1) * 256 + v] = b
TMP = os.path.join(tempfile.gettempdir(), 'hires_fold_shot.png')


def shot(mem):
    ps.render(mem, TMP, True)
    return Image.open(TMP).convert('RGB')
mem = {a: 0 for a in range(0x10000)}
for y in range(480):
    mem[ps.MODE_BASE + y] = 0x82              # bit 7, repeat code 00 (fold), 4 bpp
a = scene('rows 224-255: own memory', 2)
to_mem(a, mem, range(256))
plain = shot(mem)
# racing the beam: after the beam has passed row 223, rewrite 36 rows; they show in rows 256+
b = a.copy()
d = ImageDraw.Draw(b)
d.rectangle([0, 0, 319, 35], fill=4)
d.text((10, 6), 'SCORE 004200   LIVES 3', font=ImageFont.truetype(F, 18), fill=14)
mem2 = dict(mem)
to_mem(b, mem2, range(0, 36))
raced_bottom = shot(mem2)
raced = plain.copy()
raced.paste(raced_bottom.crop((0, 256, 640, 480)), (0, 256))
W = 640 * 2 + 3 * 30 + 150
out = Image.new('RGB', (W, 480 + 110), (255, 255, 255))
d = ImageDraw.Draw(out)
f = ImageFont.truetype(F, 17); fs = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 14)
x0 = 180
for k, (img, t) in enumerate(((plain, 'Left alone: the bottom repeats the top'),
                              (raced, '36 rows rewritten between the two passes of the beam'))):
    x = x0 + k * (640 + 30)
    out.paste(img, (x, 60))
    d.text((x, 28), t, font=f, fill=(0, 0, 0))
for y0, y1, t, c in ((0, 223, 'rows 0-223', (21, 101, 192)), (224, 255, 'rows 224-255\nown memory', (106, 27, 154)),
                     (256, 479, 'rows 256-479\nsame bytes as\nrows 0-223', (21, 101, 192))):
    d.line([(x0 - 14, 60 + y0), (x0 - 14, 60 + y1)], fill=c, width=5)
    d.multiline_text((12, 60 + (y0 + y1) // 2 - 8 * (t.count('\n') + 1)), t, font=fs, fill=c)
d.text((x0, 60 + 480 + 14), 'Rev B, mode byte x82 on every row (bit 7 = 160-read line, repeat code 00 = fold, 4 bits per pixel).  '
       'Rendered by placard_sim.py.', font=fs, fill=(60, 60, 60))
out.save(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', '..', 'docs', 'video', 'hires_fold_example.png'))
