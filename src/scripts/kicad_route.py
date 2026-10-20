"""A small grid router for the generated KiCad sheets (gen_kicad_schematic.py).

Wires run on the 1.27 mm grid, horizontally and vertically.  A wire may cross
another net's wire at right angles, but never runs along it, never bends or
ends on it, and never touches another net's pin, label or wire end.  Parts,
labels and text are obstacles.  A net with several pins is routed as a tree:
each pin in turn is joined to the nearest point of the wires already drawn.

Date: 2026-10-20
"""
import heapq

G = 1.27
DIRS = [(1, 0), (0, 1), (-1, 0), (0, -1)]


def gi(v):
    return int(round(v / G))


class Grid:
    def __init__(self, x0=12.0, y0=12.0, x1=408.0, y1=285.0, title=(300.0, 255.0)):
        self.i0, self.j0, self.i1, self.j1 = gi(x0), gi(y0), gi(x1), gi(y1)
        self.ti, self.tj = gi(title[0]), gi(title[1])
        self.blocked = set()
        self.point = {}      # cell -> owner of a pin, wire end, junction or label anchor
        self.h = {}          # cell -> set of owners of horizontal segments through it
        self.v = {}          # cell -> set of owners of vertical segments
        self.segs = {}       # owner -> list of ((i, j), (i2, j2))

    # ------------------------------------------------------------ occupancy
    def inside(self, c):
        i, j = c
        if not (self.i0 <= i <= self.i1 and self.j0 <= j <= self.j1):
            return False
        return not (i >= self.ti and j >= self.tj)

    def block_box(self, x0, y0, x1, y1, keep=()):
        for i in range(gi(min(x0, x1)), gi(max(x0, x1)) + 1):
            for j in range(gi(min(y0, y1)), gi(max(y0, y1)) + 1):
                if (i, j) not in keep:
                    self.blocked.add((i, j))

    def block_inside(self, x0, y0, x1, y1):
        """Cells strictly inside a box (its edges hold the pin ends)."""
        a, b, c, d = gi(min(x0, x1)), gi(max(x0, x1)), gi(min(y0, y1)), gi(max(y0, y1))
        for i in range(a + 1, b):
            for j in range(c + 1, d):
                self.blocked.add((i, j))

    def add_point(self, x, y, owner):
        self.point.setdefault((gi(x), gi(y)), owner)

    def add_seg(self, x1, y1, x2, y2, owner):
        a, b = (gi(x1), gi(y1)), (gi(x2), gi(y2))
        self._add_seg_cells(a, b, owner)

    def _add_seg_cells(self, a, b, owner):
        if a == b:
            self.point.setdefault(a, owner)
            return
        self.segs.setdefault(owner, []).append((a, b))
        self.point.setdefault(a, owner)
        self.point.setdefault(b, owner)
        if a[1] == b[1]:
            for i in range(min(a[0], b[0]), max(a[0], b[0]) + 1):
                self.h.setdefault((i, a[1]), set()).add(owner)
        elif a[0] == b[0]:
            for j in range(min(a[1], b[1]), max(a[1], b[1]) + 1):
                self.v.setdefault((a[0], j), set()).add(owner)
        else:   # a diagonal (bus entry): block its middle
            self.blocked.add(((a[0] + b[0]) // 2, (a[1] + b[1]) // 2))

    def foreign(self, table, c, net):
        s = table.get(c)
        return bool(s) and any(o != net for o in s)

    def cells_of(self, net):
        out = set()
        for a, b in self.segs.get(net, []):
            if a[1] == b[1]:
                out.update((i, a[1]) for i in range(min(a[0], b[0]), max(a[0], b[0]) + 1))
            elif a[0] == b[0]:
                out.update((a[0], j) for j in range(min(a[1], b[1]), max(a[1], b[1]) + 1))
        out.update(c for c, o in self.point.items() if o == net)
        return out

    # ------------------------------------------------------------ search
    def route(self, net, start, tree, avoid=(), no_end=()):
        """Cells from start to any cell of tree, or None.  avoid: cells not to use."""
        tree = set(tree) - set(no_end)
        if not tree:
            return None
        avoid = set(avoid)
        ti = [c[0] for c in tree]
        tj = [c[1] for c in tree]
        bx0, bx1, by0, by1 = min(ti), max(ti), min(tj), max(tj)

        def h(c):
            dx = bx0 - c[0] if c[0] < bx0 else (c[0] - bx1 if c[0] > bx1 else 0)
            dy = by0 - c[1] if c[1] < by0 else (c[1] - by1 if c[1] > by1 else 0)
            return dx + dy

        start_state = (start, -1)
        best = {start_state: 0.0}
        prev = {}
        heap = [(h(start), 0.0, start, -1)]
        n = 0
        while heap:
            f, g, c, d = heapq.heappop(heap)
            if g > best.get((c, d), 1e18):
                continue
            n += 1
            if n > 2500000:
                return None
            crossing_here = c != start and (self.foreign(self.h, c, net) or self.foreign(self.v, c, net))
            for k, (dx, dy) in enumerate(DIRS):
                if d >= 0 and k == (d + 2) % 4:
                    continue
                if crossing_here and k != d:
                    continue
                c2 = (c[0] + dx, c[1] + dy)
                if not self.inside(c2) or c2 in self.blocked or c2 in avoid:
                    continue
                owner = self.point.get(c2)
                if owner is not None and owner != net:
                    continue
                horiz = dy == 0
                if horiz and self.foreign(self.h, c2, net):
                    continue
                if not horiz and self.foreign(self.v, c2, net):
                    continue
                cross = self.foreign(self.v if horiz else self.h, c2, net)
                if c2 in tree and not cross:
                    path = [c2, c]
                    st = (c, d)
                    while st in prev:
                        st = prev[st]
                        path.append(st[0])
                    path.reverse()
                    return path
                cost = 1.0
                if d >= 0 and k != d:
                    cost += 3.0
                if cross:
                    cost += 1.5
                # keep a cell of space from other nets' parallel wires
                side = [(c2[0], c2[1] - 1), (c2[0], c2[1] + 1)] if horiz else [(c2[0] - 1, c2[1]), (c2[0] + 1, c2[1])]
                tab = self.h if horiz else self.v
                if any(self.foreign(tab, s, net) for s in side):
                    cost += 0.8
                g2 = g + cost
                st2 = (c2, k)
                if g2 < best.get(st2, 1e18):
                    best[st2] = g2
                    prev[st2] = (c, d)
                    heapq.heappush(heap, (g2 + h(c2), g2, c2, k))
        return None


def path_segments(path):
    """Merge a cell path into straight segments [(a, b), ...]."""
    segs = []
    a = path[0]
    for k in range(1, len(path) - 1):
        p, c, nx = path[k - 1], path[k], path[k + 1]
        if (c[0] - p[0], c[1] - p[1]) != (nx[0] - c[0], nx[1] - c[1]):
            segs.append((a, c))
            a = c
    segs.append((a, path[-1]))
    return segs
