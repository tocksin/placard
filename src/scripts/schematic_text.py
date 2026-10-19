"""
schematic_text.py - size the text of a matplotlib schematic after the
drawing is laid out (used by gen_io_schematic.py and gen_audio_schematic.py).

The blocks, wires and labels are placed first at their base font sizes.
fit_text() then scales every text up by SCALE and shrinks, a step at a time,
only the ones that run into another text, a wire or a chip outline, so the
text ends up as large as the placement allows (never below its base size).

Date: 2026-10-19
"""
import numpy as np
from matplotlib.patches import Rectangle

SCALE = 1.8         # start every text at this multiple of its base size
STEP = 0.94         # shrink factor per pass for a text that collides
GAP = 2             # pixels kept clear around each text


def _segments(fig, ax):
    """every wire (Line2D), chip outline and frame (Rectangle) and the
    edge of the figure as display-space segments, an (N, 4) array of
    x0, y0, x1, y1"""
    segs = []
    tr = ax.transData
    for ln in ax.lines:
        xy = tr.transform(np.column_stack(ln.get_data()))
        segs.append(np.hstack([xy[:-1], xy[1:]]))
    for p in ax.patches:
        if isinstance(p, Rectangle):
            c = p.get_patch_transform().transform([(0, 0), (1, 0), (1, 1), (0, 1), (0, 0)])
            xy = tr.transform(c)
            segs.append(np.hstack([xy[:-1], xy[1:]]))
    w, h = fig.canvas.get_width_height()
    xy = np.array([(1, 1), (w - 1, 1), (w - 1, h - 1), (1, h - 1), (1, 1)], dtype=float)
    segs.append(np.hstack([xy[:-1], xy[1:]]))
    return np.vstack(segs)


def _hits(box, segs):
    """indices of the segments that cross the box (x0, y0, x1, y1)"""
    bx0, by0, bx1, by1 = box
    x0, y0, x1, y1 = segs.T
    near = np.nonzero((np.minimum(x0, x1) <= bx1) & (np.maximum(x0, x1) >= bx0) &
                      (np.minimum(y0, y1) <= by1) & (np.maximum(y0, y1) >= by0))[0]
    if not len(near):
        return set()
    sx, sy, ex, ey = segs[near].T
    dx, dy = ex - sx, ey - sy
    s = np.vstack([np.sign(dx * (cy - sy) - dy * (cx - sx))
                   for cx, cy in ((bx0, by0), (bx1, by0), (bx1, by1), (bx0, by1))])
    # a segment crosses unless all four corners are strictly on one side of it
    return set(near[~((s > 0).all(axis=0) | (s < 0).all(axis=0))].tolist())


def _boxes(texts, renderer, gap=GAP):
    out = []
    for t in texts:
        b = t.get_window_extent(renderer)
        out.append((b.x0 - gap, b.y0 - gap, b.x1 + gap, b.y1 + gap))
    return np.array(out)


def _overlaps(arr, i):
    b = arr[i]
    o = (arr[:, 0] < b[2]) & (arr[:, 2] > b[0]) & (arr[:, 1] < b[3]) & (arr[:, 3] > b[1])
    o[i] = False
    return set(np.nonzero(o)[0].tolist())


def fit_text(fig, ax, scale=SCALE, passes=80):
    """Collisions already there at the base sizes are left alone.  A text
    that runs into something new first tries growing from its top or its
    bottom edge instead of its middle (a label just above or below a wire),
    then shrinks if it still collides; between two texts the one with the
    larger scale shrinks."""
    texts = [t for t in ax.texts if t.get_text().strip()]
    base = [t.get_fontsize() for t in texts]
    segs = _segments(fig, ax)
    renderer = fig.canvas.get_renderer()
    arr = _boxes(texts, renderer, 0)
    inv = ax.transData.inverted()
    # data y of each text's display bottom and top edge at its base size
    edges = [(inv.transform((0, b[1]))[1], inv.transform((0, b[3]))[1]) for b in arr]
    # a framed label (white box) sits on its frame line on purpose
    framed = [t.get_bbox_patch() is not None for t in texts]
    old_t = [_overlaps(arr, i) for i in range(len(texts))]
    old_s = [_hits(arr[i], segs) for i in range(len(texts))]
    # anchors still to try: vertically centred texts may pin an edge instead
    tries = [["bottom", "top"] if t.get_va() == "center" and t.get_rotation() == 0 else []
             for t in texts]
    for t, b in zip(texts, base):
        t.set_fontsize(b * scale)
    for _ in range(passes):
        arr = _boxes(texts, renderer)
        ratio = [t.get_fontsize() / b for t, b in zip(texts, base)]
        bad = set()
        for i in range(len(texts)):
            for j in _overlaps(arr, i) - old_t[i]:
                if ratio[i] >= ratio[j] - 1e-6:
                    bad.add(i)
            if not framed[i] and _hits(arr[i], segs) - old_s[i]:
                bad.add(i)
        bad = [i for i in bad if ratio[i] > 1.0 or tries[i]]
        if not bad:
            break
        for i in bad:
            t = texts[i]
            if tries[i]:
                va = tries[i].pop(0)
                t.set_va(va)
                t.set_y(edges[i][0] if va == "bottom" else edges[i][1])
            else:
                t.set_fontsize(max(base[i], t.get_fontsize() * STEP))

    # shrinking is one way, so a text that shrank before its neighbour moved
    # may have room again: grow each one back a step at a time while it fits
    arr = _boxes(texts, renderer)

    def clear(i):
        arr[i] = _boxes([texts[i]], renderer)[0]
        if _overlaps(arr, i) - old_t[i]:
            return False
        return framed[i] or not (_hits(arr[i], segs) - old_s[i])

    for _ in range(passes):
        grown = False
        for i, t in enumerate(texts):
            fs = t.get_fontsize()
            if fs >= base[i] * scale - 1e-6:
                continue
            t.set_fontsize(min(base[i] * scale, fs / STEP))
            if clear(i):
                grown = True
            else:
                t.set_fontsize(fs)
                arr[i] = _boxes([t], renderer)[0]
        if not grown:
            break
    return {t.get_text(): t.get_fontsize() / b for t, b in zip(texts, base)}
