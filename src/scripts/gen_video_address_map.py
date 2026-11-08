#!/usr/bin/env python3
"""
gen_video_address_map.py - draw how the video counters map onto the RAM
address, the usual way (horizontal count in the low bits) against the PLACARD
way (horizontal count in the high bits), and how much consecutive memory
each one leaves free.

    python3 gen_video_address_map.py      writes docs/video/video_address_map.png

Date: 11/08/2026

Counters (docs/video/VIDEO.md, ATF22V10_HCOUNT.pld rev 08, ATF22V10_VCOUNT.pld
rev 03):
    H9:H3 counts 28 -> 127 (8-pixel groups, pixels 224-1023);
          active video is groups 48-127 (80 byte columns).
    V9:V0 counts 499 -> 1023; active video is lines 544-1023 (480 lines),
          so V8:V0 = 32-511 on visible lines.
Usual:   A15:A7 = V8:V0, A6:A0 = H9:H3, address = V8:V0 * 128 + H9:H3
PLACARD: A15:A9 = H9:H3, A8:A0 = V8:V0, address = H9:H3 * 512 + V8:V0
(1x line repeat; the 2x/4x remap only shuffles A8:A0 inside a column).
"""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from matplotlib.colors import ListedColormap

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "video",
                                    "video_address_map.png"))

H_ACTIVE = range(48, 128)        # byte columns with pixels
V_ACTIVE = range(32, 512)        # V8:V0 of visible lines
ROW = 256                        # bytes per drawn row of the memory picture

PIX, BIG, FRAG = 0, 1, 2         # pixel byte, free in a big block, free fragment
COL_PIX = "#4a7fc1"
COL_BIG = "#47a447"
COL_FRAG = "#d9534f"


def build(usual):
    """Return a 64K array: True where the byte holds a visible pixel."""
    pix = np.zeros(65536, dtype=bool)
    for v in V_ACTIVE:
        for h in H_ACTIVE:
            a = (v << 7 | h) if usual else (h << 9 | v)
            pix[a] = True
    return pix


def runs(pix):
    """Free runs (start, length) of non-pixel bytes."""
    out, a = [], 0
    while a < 65536:
        if pix[a]:
            a += 1
            continue
        b = a
        while b < 65536 and not pix[b]:
            b += 1
        out.append((a, b - a))
        a = b
    return out


def classify(pix, big=1024):
    cls = np.full(65536, PIX, dtype=np.uint8)
    rs = runs(pix)
    for s, n in rs:
        cls[s:s + n] = BIG if n >= big else FRAG
    return cls, rs


def kb(n):
    return f"{n / 1024:.1f} KB" if n % 1024 else f"{n // 1024} KB"


def bitfield(ax, x0, y0, w, fields, title):
    """Draw A15..A0 as boxes, grouped into labelled fields."""
    bw = w / 16
    ax.text(x0, y0 + 1.55, title, fontsize=19, fontweight="bold", va="bottom")
    for i in range(16):
        ax.text(x0 + (i + 0.5) * bw, y0 + 1.05, f"A{15 - i}", ha="center",
                va="bottom", fontsize=13)
    pos = 0
    for n, label, col in fields:
        ax.add_patch(Rectangle((x0 + pos * bw, y0), n * bw, 1.0, fc=col,
                               ec="black", lw=2))
        ax.text(x0 + (pos + n / 2) * bw, y0 + 0.5, label, ha="center",
                va="center", fontsize=17, fontweight="bold", color="white")
        pos += n


def panel(fig, left, usual):
    pix = build(usual)
    cls, rs = classify(pix)
    free = [r for r in rs]
    total_free = sum(n for _, n in free)
    largest = max(free, key=lambda r: r[1])
    frags = [r for r in free if r[1] < 1024]

    # header: title + bit field
    hx = fig.add_axes([left, 0.80, 0.44, 0.17])
    hx.set_xlim(0, 16)
    hx.set_ylim(-0.3, 3.6)
    hx.axis("off")
    if usual:
        hx.text(0, 3.0, "1. The usual way: horizontal count in the low bits",
                fontsize=23, fontweight="bold")
        bitfield(hx, 0, 0, 16, [(9, "V8 : V0   (line)", "#8e44ad"),
                                (7, "H9 : H3   (byte)", "#e67e22")],
                 "address = line x 128 + byte column")
    else:
        hx.text(0, 3.0, "2. PLACARD: the counts swapped (H in the high bits)",
                fontsize=23, fontweight="bold")
        bitfield(hx, 0, 0, 16, [(7, "H9 : H3   (byte)", "#e67e22"),
                                (9, "V8 : V0   (line)", "#8e44ad")],
                 "address = byte column x 512 + line")

    # memory picture: 64 KB as 256 rows of 256 bytes, x0000 at the top
    mx = fig.add_axes([left + 0.055, 0.30, 0.25, 0.48])
    img = cls.reshape(65536 // ROW, ROW)
    mx.imshow(img, cmap=ListedColormap([COL_PIX, COL_BIG, COL_FRAG]),
              vmin=0, vmax=2, aspect="auto", interpolation="nearest")
    mx.set_xticks([0, 64, 128, 192, 255])
    mx.set_xticklabels(["+00", "+40", "+80", "+C0", "+FF"], fontsize=13)
    rows = list(range(0, 257, 16))
    mx.set_yticks([r - 0.5 for r in rows])
    mx.set_yticklabels([f"x{min(r * ROW, 0xFFFF) if r < 256 else 0xFFFF:04X}"
                        for r in rows], fontsize=13, family="monospace")
    mx.set_xlabel("byte within a 256-byte row", fontsize=14)
    mx.set_title("RAM, x0000 (top) to xFFFF (bottom)", fontsize=16)
    for s in mx.spines.values():
        s.set_linewidth(2)

    # side notes beside the picture
    nx = fig.add_axes([left + 0.31, 0.30, 0.14, 0.48])
    nx.set_xlim(0, 1)
    nx.set_ylim(256, 0)
    nx.axis("off")
    if usual:
        notes = [
            (8, "x0000-x0FFF\nlines 0-31\n(vertical\nblanking)\n4 KB free", COL_BIG),
            (60, "every line:\n80 pixel bytes\n+ 48 bytes of\nhorizontal\nblanking", COL_PIX),
            (140, "a 48-byte hole\non every line,\nall through\nx1000-xFFFF\n(the first one\njoins the\n4 KB block)", COL_FRAG),
        ]
    else:
        notes = [
            (40, "x0000-x5FFF\nbyte columns\n0-47 (all\nhorizontal\nblanking)\n24 KB in\none block", COL_BIG),
            (150, "x6000-xFFFF\n80 columns of\n512 bytes:\n480 pixels\n+ 32 bytes of\nvertical\nblanking", COL_PIX),
            (222, "only one\n32-byte hole\nper column\n(the first one\njoins the\n24 KB block)", COL_FRAG),
        ]
    for y, t, c in notes:
        nx.text(0.05, y, t, fontsize=15, va="center", color="black",
                bbox=dict(boxstyle="round,pad=0.4", fc=c, alpha=0.30, ec=c, lw=2))

    # summary
    sx = fig.add_axes([left, 0.01, 0.44, 0.17])
    sx.axis("off")
    s, n = largest
    lines = [
        ("Pixel bytes", f"38,400 (37.5 KB)  in {kb(0x10000 - (0x1000 if usual else 0x6000))} of address space"),
        ("Free (not pixels)", f"{total_free:,} B ({kb(total_free)})"),
        ("Largest free block", f"{n:,} B,  x{s:04X}-x{s + n - 1:04X}"),
        ("Wasted in small holes", f"{sum(m for _, m in frags):,} B in {len(frags)} holes of "
                           f"{frags[0][1]} B"),
    ]
    col = "#a52a2a" if usual else "#1e6b1e"
    for i, (k, v) in enumerate(lines):
        y = 0.88 - i * 0.22
        sx.text(0.0, y, k + ":", fontsize=17, fontweight="bold", va="top")
        sx.text(0.36, y, v, fontsize=17, va="top",
                color=col if i >= 2 else "black",
                fontweight="bold" if i == 2 else "normal")
    return total_free, largest, frags


def main():
    fig = plt.figure(figsize=(26, 17), dpi=100)
    fig.patch.set_facecolor("white")
    panel(fig, 0.03, True)
    panel(fig, 0.53, False)
    # divider and legend
    for y0, y1 in ((0.24, 0.97), (0.02, 0.185)):
        fig.add_artist(plt.Line2D([0.505, 0.505], [y0, y1], color="#999999",
                                  lw=2))
    lx = fig.add_axes([0.03, 0.195, 0.94, 0.03])
    lx.axis("off")
    for i, (c, t) in enumerate([(COL_PIX, "visible pixel bytes (640 x 480, 1 bpp)"),
                                (COL_BIG, "free, in a block of 1 KB or more"),
                                (COL_FRAG, "free, but in small holes (hard to use)")]):
        x = 0.02 + i * 0.33
        lx.add_patch(Rectangle((x, 0.1), 0.025, 0.8, fc=c, ec="black",
                               transform=lx.transAxes))
        lx.text(x + 0.032, 0.5, t, fontsize=17, va="center",
                transform=lx.transAxes)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    fig.savefig(OUT, dpi=100)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
