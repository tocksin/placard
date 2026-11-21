#!/usr/bin/env python3
"""gen_photos.py - the pictures of the photo viewer (PHOTO.PLC, photo.masm)

Turns the photographs in src/photos/ into sdcard/PHOTOS/*.PIC: 160 x 240
pixels in the board's 256 colors, for a screen of 160-read rows with 2x line
repeat on a rev B board (mode byte x87, docs/video/HIRES.md).

    python3 gen_photos.py                    writes sdcard/PHOTOS/*.PIC
    python3 gen_photos.py --png DIR          also DIR/<name>_native.png (160 x 240,
                                             one pixel per screen pixel of the mode)
                                             and DIR/<name>_screen.png (640 x 480,
                                             the monitor's picture, drawn by
                                             placard_sim.py from the file's bytes)

A .PIC file is the video RAM x6000-xFFFF as it is, 40,960 bytes (80
sectors), so the viewer reads it straight to the screen:

    byte column c (0-159), picture row r (0-239), v = 32 + 2r:
    offset = c * 256 + ((v & xFE) | (v >> 8))
    the 16 bytes of every 256 that the mode never shows are 00

A pixel is 4 x 2 screen pixels, so the photograph is cut to 4:3 and squeezed
to 160 x 240.  The colors: byte = GGG BB RRR, each channel a resistor DAC
(docs/video/COLORS.md).  The five codes that color decoder revision 08
blends into grays (x21, x6B, x8C, xB5, xD6) are not used, so a picture looks
the same on every decoder revision.  Error diffusion (Floyd-Steinberg, back
and forth) in linear light; the nearest color is chosen in Oklab.

Date: 2026-11-21
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402

SRC = os.path.join(HERE, '..', 'photos')
OUT = os.path.join(HERE, '..', '..', 'sdcard', 'PHOTOS')
W, H = 160, 240
SIZE = 160 * 256
MODE = 0x87                   # 160-read row, 2x, 8 bits per pixel
BLENDED = (0x21, 0x6B, 0x8C, 0xB5, 0xD6)

# file name on the card, source in src/photos, where the 4:3 cut sits when the
# source is not 4:3 (0 = left or top, 0.5 = middle, 1 = right or bottom)
PHOTOS = (
    ('TEMPLE', 'temple.jpg', 0.35),
    ('SUNFLOWR', 'sunflowers.jpg', 0.5),
    ('TULIPS', 'tulips.jpg', 0.5),
    ('PURPLE', 'purple.jpg', 0.5),
    ('ASTRONAU', 'astronaut.jpg', 0.0),
)


def to_linear(c):
    c = np.asarray(c, dtype=float)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def oklab(lin):
    m = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                  [0.2119034982, 0.6806995451, 0.1073969566],
                  [0.0883024619, 0.2817188376, 0.6299787005]])
    lms = np.cbrt(np.clip(lin, 0, None) @ m.T)
    n = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                  [1.9779984951, -2.4285922050, 0.4505937099],
                  [0.0259040371, 0.7827717662, -0.8086757660]])
    return lms @ n.T


def palette():
    codes = [b for b in range(256) if b not in BLENDED]
    lin = to_linear(np.array([ps.rgb8(b) for b in codes]) / 255.0)
    return np.array(codes), lin, oklab(lin)


def cut(im, where):
    """the 4:3 part of the photograph, squeezed to 160 x 240"""
    w, h = im.size
    if w * 3 > h * 4:
        cw = h * 4 // 3
        x = int((w - cw) * where)
        im = im.crop((x, 0, x + cw, h))
    else:
        ch = w * 3 // 4
        y = int((h - ch) * where)
        im = im.crop((0, y, w, y + ch))
    return im.resize((W, H), Image.LANCZOS)


def dither(im):
    """160 x 240 RGB -> 240 rows of 160 color bytes"""
    codes, plin, plab = palette()
    lin = to_linear(np.asarray(im, dtype=float) / 255.0)
    out = np.zeros((H, W), dtype=np.uint8)
    for y in range(H):
        xs = range(W) if y % 2 == 0 else range(W - 1, -1, -1)
        d = 1 if y % 2 == 0 else -1
        for x in xs:
            want = np.clip(lin[y, x], -0.25, 1.25)
            k = int(np.argmin(((plab - oklab(np.clip(want, 0, 1))) ** 2).sum(axis=1)))
            out[y, x] = codes[k]
            err = want - plin[k]
            if 0 <= x + d < W:
                lin[y, x + d] += err * 7 / 16
            if y + 1 < H:
                if 0 <= x - d < W:
                    lin[y + 1, x - d] += err * 3 / 16
                lin[y + 1, x] += err * 5 / 16
                if 0 <= x + d < W:
                    lin[y + 1, x + d] += err * 1 / 16
    return out


def offset(c, r):
    v = 32 + 2 * r
    return c * 256 + ((v & 0xFE) | (v >> 8))


def pic_bytes(px):
    data = bytearray(SIZE)
    for r in range(H):
        for c in range(W):
            data[offset(c, r)] = int(px[r, c])
    return bytes(data)


def screen(data, path):
    """the monitor's picture of a .PIC file: placard_sim's rev B renderer"""
    mem = [0] * 0x10000
    mem[0x6000:0x6000 + SIZE] = data
    for y in range(480):
        mem[ps.MODE_BASE + y] = MODE
    ps.render(mem, path, True)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png', metavar='DIR')
    args = ap.parse_args(argv)
    os.makedirs(OUT, exist_ok=True)
    for name, src, where in PHOTOS:
        im = Image.open(os.path.join(SRC, src)).convert('RGB')
        im = ImageEnhance.Color(cut(im, where)).enhance(1.1)
        px = dither(im)
        data = pic_bytes(px)
        with open(os.path.join(OUT, name + '.PIC'), 'wb') as f:
            f.write(data)
        print('%-8s.PIC  %d colors used' % (name, len(set(px.flatten().tolist()))))
        if args.png:
            os.makedirs(args.png, exist_ok=True)
            native = Image.new('RGB', (W, H))
            native.putdata([ps.rgb8(int(b)) for b in px.flatten()])
            native.save(os.path.join(args.png, name.lower() + '_native.png'))
            screen(data, os.path.join(args.png, name.lower() + '_screen.png'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
