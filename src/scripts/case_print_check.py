#!/usr/bin/env python3
"""
case_print_check.py - checks STL files that are already in print orientation
(flat side on the bed at z = 0) for support-free FDM printing:

- watertight: every edge is shared by exactly two triangles, in opposite
  directions;
- bed: the footprint fits a 256 x 256 mm bed (Bambu Lab A1) with a margin;
- overhangs: no downward-facing surface above the bed steeper than 45 degrees
  from vertical.  Each one found is listed by height, with its area and
  where it is, so it can be read as a short straight bridge or as a floating
  or overhanging feature that has to be fixed;
- islands: every layer's material must rest on material in the layer below.
  The part is sliced on a grid and any cell that has plastic with none
  below it or beside it in the layer below is counted.

    python3 case_print_check.py case/print/*.stl

Exits 1 if any file fails.

Date: 2026-11-24
"""

import struct
import sys
from collections import defaultdict

import numpy as np

BED, MARGIN = 256.0, 5.0
LAYER = 0.2
CELL = 0.4


def load(p):
    d = open(p, "rb").read()
    n = struct.unpack("<I", d[80:84])[0]
    a = np.frombuffer(d[84:84 + n * 50], dtype=np.dtype([("n", "<3f4"), ("v", "<9f4"), ("a", "<u2")]))
    return a["v"].reshape(-1, 3, 3).astype(float)


def watertight(v):
    """(open edges, edges not shared by exactly two triangles in opposite directions)."""
    q = np.round(v / 1e-4).astype(np.int64)
    _, idx = np.unique(q.reshape(-1, 3), axis=0, return_inverse=True)
    f = idx.reshape(-1, 3)
    cnt = defaultdict(int)
    for a, b in ((0, 1), (1, 2), (2, 0)):
        for x, y in zip(f[:, a], f[:, b]):
            if x != y:
                cnt[(x, y)] += 1
    bad = sum(1 for (x, y), c in cnt.items() if c != 1 or cnt.get((y, x), 0) != 1)
    return bad


def overhangs(v):
    z0 = v[:, :, 2].min()
    n = np.cross(v[:, 1] - v[:, 0], v[:, 2] - v[:, 0])
    area = np.linalg.norm(n, axis=1) / 2
    n = n / (2 * area[:, None] + 1e-12)
    zmin = v[:, :, 2].min(1) - z0
    down = (n[:, 2] < -0.71) & (zmin > 0.05) & (area > 1e-9)      # steeper than 45 degrees and not on the bed
    grp = defaultdict(lambda: [0.0, [], []])
    for i in np.where(down)[0]:
        k = round(zmin[i], 1)
        grp[k][0] += area[i]
        grp[k][1].append(v[i, :, 0])
        grp[k][2].append(v[i, :, 1])
    out = []
    for k in sorted(grp):
        a, xs, ys = grp[k]
        xs, ys = np.concatenate(xs), np.concatenate(ys)
        out.append((k, a, xs.min(), xs.max(), ys.min(), ys.max()))
    return out


def islands(v):
    """Cells of plastic with nothing under them: slices the part every LAYER on a
    CELL grid (ray casting along x) and compares each layer with the one below,
    grown by one cell.  Returns (unsupported cell count, [(z, x, y) samples])."""
    lo, hi = v.reshape(-1, 3).min(0), v.reshape(-1, 3).max(0)
    nx = int(np.ceil((hi[0] - lo[0]) / CELL)) + 2
    ny = int(np.ceil((hi[1] - lo[1]) / CELL)) + 2
    ys = lo[1] + (np.arange(ny) - 0.5) * CELL + 0.013
    zs = np.arange(lo[2] + LAYER / 2, hi[2], LAYER)
    tz0, tz1 = v[:, :, 2].min(1), v[:, :, 2].max(1)
    prev, total, where = None, 0, []
    for z in zs:
        t = v[(tz0 <= z) & (tz1 > z)]
        grid = np.zeros((ny, nx), bool)
        if len(t):
            # each triangle's segment in the plane z
            segs = []
            for a, b in ((0, 1), (1, 2), (2, 0)):
                pa, pb = t[:, a], t[:, b]
                m = (pa[:, 2] <= z) != (pb[:, 2] <= z)
                f = np.where(m, (z - pa[:, 2]) / np.where(m, pb[:, 2] - pa[:, 2], 1), np.nan)
                segs.append(pa[:, :2] + f[:, None] * (pb[:, :2] - pa[:, :2]))
            segs = np.stack(segs, 1)                       # n, 3, 2 with one nan row each
            ok = ~np.isnan(segs[:, :, 0])
            keep = ok.sum(1) == 2
            segs, ok = segs[keep], ok[keep]
            p = np.array([s[o] for s, o in zip(segs, ok)])  # n, 2, 2
            if len(p):
                y0, y1 = p[:, 0, 1], p[:, 1, 1]
                for j, y in enumerate(ys):
                    m = (y0 <= y) != (y1 <= y)
                    if not m.any():
                        continue
                    xc = p[m, 0, 0] + (y - y0[m]) / (y1[m] - y0[m]) * (p[m, 1, 0] - p[m, 0, 0])
                    xc.sort()
                    for a, b in zip(xc[0::2], xc[1::2]):
                        i0 = int(np.ceil((a - lo[0]) / CELL + 0.5))
                        i1 = int(np.floor((b - lo[0]) / CELL + 0.5))
                        if i1 >= i0:
                            grid[j, max(i0, 0):i1 + 1] = True
        if prev is not None:
            sup = prev.copy()
            for _ in range(2):                             # 45 degrees per layer and more is fine: grow by 2 cells
                g2 = sup.copy()
                g2[1:] |= sup[:-1]
                g2[:-1] |= sup[1:]
                g2[:, 1:] |= sup[:, :-1]
                g2[:, :-1] |= sup[:, 1:]
                sup = g2
            un = grid & ~sup
            c = int(un.sum())
            if c:
                total += c
                j, i = np.argwhere(un)[0]
                where.append((z - lo[2], lo[0] + (i - 0.5) * CELL, ys[j], c))
        prev = grid
    return total, where


def main(files):
    fail = 0
    for f in files:
        v = load(f)
        size = v.reshape(-1, 3).max(0) - v.reshape(-1, 3).min(0)
        bad_edges = watertight(v)
        oh = overhangs(v)
        isl, where = islands(v)
        fits = max(size[0], size[1]) <= BED - MARGIN
        ok = bad_edges == 0 and fits and not oh and isl == 0
        print("%s  %.1f x %.1f x %.1f mm" % (f.split("/")[-1], *size))
        print("  watertight: %s" % ("OK" if not bad_edges else "%d bad edges" % bad_edges))
        print("  bed: %s" % ("OK" if fits else "too big"))
        if not oh:
            print("  overhangs: OK, no unsupported downward faces")
        for k, a, x0, x1, y0, y1 in oh:
            print("  overhang at z=%5.1f  %7.2f mm2  x %.1f..%.1f  y %.1f..%.1f" % (k, a, x0, x1, y0, y1))
        if isl == 0:
            print("  islands: OK, every layer rests on the one below")
        for z, x, y, c in where[:8]:
            print("  island at z=%5.1f near x %.1f y %.1f (%d cells)" % (z, x, y, c))
        fail += not ok
    print("%d of %d files pass" % (len(files) - fail, len(files)))
    return fail


if __name__ == "__main__":
    sys.exit(1 if main(sys.argv[1:]) else 0)
