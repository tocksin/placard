"""Helpers to write KiCad 7 schematic files (.kicad_sch) from Python.

Used by gen_kicad_schematic.py.  A sheet is built from symbols whose pins are
each given a net; every connected pin gets a short wire stub and a label (a
global label when the net is on more than one sheet, a local label otherwise,
a power symbol for +5V, GND, +3V3 and GNDA).  Unconnected pins get a
no-connect flag.  Symbols are copied out of the KiCad libraries into each
sheet's lib_symbols cache, so the files open without the libraries.

Date: 2026-10-20
"""
import math
import os
import re
import uuid as uuidlib

import kicad_route as KR

KICAD_SYM = "/usr/share/kicad/symbols"
HERE = os.path.dirname(os.path.abspath(__file__))
PROJ_LIB = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib"))

LIBS = {
    "placard": os.path.join(PROJ_LIB, "placard.kicad_sym"),
    "placard_parts": os.path.join(PROJ_LIB, "placard_parts.kicad_sym"),
}

POWER_NETS = {"+5V": "power:+5V", "GND": "power:GND", "+3V3": "power:+3V3",
              "GNDA": "power:GNDA"}

# Text sizes (mm).  Large text: labels fill most of the 2.54 mm pin pitch.
LABEL_SIZE = 2.0
REF_SIZE = 2.54
VALUE_SIZE = 2.0
STUB = 5.08
BUS_RE = re.compile(r"^([A-Z]+)(\d+)$")
NOT_BUS = {"LAD", "COL"}
POWER_STUB = 2.54

_uuid_ns = uuidlib.UUID("6f1d3c3e-6c5e-4a57-9a43-2e1f6f0b7a10")


def det_uuid(*parts):
    """Deterministic uuid, so regenerating gives the same files."""
    return str(uuidlib.uuid5(_uuid_ns, "/".join(str(p) for p in parts)))


# ---------------------------------------------------------------- s-expr
_tok = re.compile(r'\s*(\(|\)|"(?:[^"\\]|\\.)*"|[^\s()"]+)')


def parse(text):
    pos = 0
    stack = [[]]
    n = len(text)
    while pos < n:
        m = _tok.match(text, pos)
        if not m:
            break
        t = m.group(1)
        pos = m.end()
        if t == "(":
            stack.append([])
        elif t == ")":
            lst = stack.pop()
            stack[-1].append(lst)
        else:
            stack[-1].append(t)
    return stack[0][0]


def dump(x, indent=0):
    if not isinstance(x, list):
        return x
    simple = all(not isinstance(e, list) for e in x)
    if simple or indent > 6:
        return "(" + " ".join(dump(e, indent + 1) for e in x) + ")"
    head = []
    rest = []
    for e in x:
        if not isinstance(e, list) and not rest:
            head.append(e)
        else:
            rest.append(e)
    pad = "  " * (indent + 1)
    s = "(" + " ".join(head)
    for e in rest:
        if isinstance(e, list):
            s += "\n" + pad + dump(e, indent + 1)
        else:
            s += " " + e
    return s + ")"


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def uq(s):
    return s[1:-1].replace('\\"', '"').replace("\\\\", "\\") if s.startswith('"') else s


def find(lst, key):
    return [e for e in lst if isinstance(e, list) and e and e[0] == key]


# ---------------------------------------------------------------- libraries
_lib_cache = {}


def _load_lib(nick):
    if nick not in _lib_cache:
        path = LIBS.get(nick) or os.path.join(KICAD_SYM, nick + ".kicad_sym")
        tree = parse(open(path).read())
        _lib_cache[nick] = {uq(s[1]): s for s in find(tree, "symbol")}
    return _lib_cache[nick]


def _rename(sym, old, new):
    sym = [e for e in sym]
    sym[1] = q(new)
    out = []
    for e in sym:
        if isinstance(e, list) and e and e[0] == "symbol":
            e = list(e)
            n = uq(e[1])
            if n.startswith(old + "_"):
                e[1] = q(new + n[len(old):])
        out.append(e)
    return out


def lib_symbol(lib_id):
    """The flattened symbol definition (extends resolved), named lib_id."""
    nick, name = lib_id.split(":", 1)
    lib = _load_lib(nick)
    sym = lib[name]
    ext = find(sym, "extends")
    if ext:
        parent_name = uq(ext[0][1])
        parent = lib_symbol(nick + ":" + parent_name)
        pname = uq(parent[1]).split(":", 1)[1]
        flat = [parent[0], q(name)]
        props = find(sym, "property")
        for e in parent[2:]:
            if isinstance(e, list) and e and e[0] == "property":
                continue
            if isinstance(e, list) and e and e[0] == "symbol":
                e = list(e)
                n = uq(e[1])
                e[1] = q(name + n[len(pname):])
            flat.append(e)
        # properties go before the sub-symbols
        idx = next(i for i, e in enumerate(flat) if isinstance(e, list) and e[0] == "symbol")
        flat[idx:idx] = props
        sym = flat
    else:
        sym = list(sym)
    sym = list(sym)
    sym[1] = q(lib_id)
    return sym


def sym_pins(symdef):
    """[(number, name, type, x, y, angle, length, hidden, unit)] from a flattened symbol."""
    name = uq(symdef[1]).split(":", 1)[1]
    pins = []
    for sub in find(symdef, "symbol"):
        sname = uq(sub[1])
        m = re.match(re.escape(name) + r"_(\d+)_(\d+)$", sname)
        unit = int(m.group(1)) if m else 0
        for p in find(sub, "pin"):
            etype = p[1]
            at = find(p, "at")[0]
            x, y = float(at[1]), float(at[2])
            ang = int(float(at[3])) if len(at) > 3 else 0
            length = float(find(p, "length")[0][1])
            hidden = "hide" in p
            pname = uq(find(p, "name")[0][1])
            num = uq(find(p, "number")[0][1])
            pins.append((num, pname, etype, x, y, ang, length, hidden, unit))
    return pins


def sym_props(symdef):
    return {uq(p[1]): p for p in find(symdef, "property")}


# ---------------------------------------------------------------- geometry
def rot(dx, dy, r):
    """Rotate a schematic-space offset (y down) by r degrees counterclockwise on screen."""
    r %= 360
    if r == 0:
        return dx, dy
    if r == 90:
        return dy, -dx
    if r == 180:
        return -dx, -dy
    if r == 270:
        return -dy, dx
    raise ValueError(r)


def _dir(angle):
    # lib pin angle: direction from the connection point toward the body (y up)
    return {0: (1, 0), 90: (0, 1), 180: (-1, 0), 270: (0, -1)}[angle % 360]


def label_len(net, glob=True):
    """Estimated length of a label in mm (KiCad's stroke font, plus the global label's arrow)."""
    n = len(net.replace("~{", "").replace("}", ""))
    return n * LABEL_SIZE * 0.95 + (LABEL_SIZE * 1.6 if glob else 0.5)


def hide_val_for(net):
    return net in ("GND", "GNDA")


def snap(v):
    return round(v / 1.27) * 1.27


def R(v):
    return f"{round(v, 4):g}"


def font(size, extra=""):
    return f"(effects (font (size {R(size)} {R(size)})){extra})"


# ---------------------------------------------------------------- sheet
class Sheet:
    def __init__(self, project, filename, title, page, root_uuid, sheet_uuid, date, rev="1"):
        self.project = project
        self.filename = filename
        self.title = title
        self.page = page
        self.root_uuid = root_uuid
        self.sheet_uuid = sheet_uuid   # uuid of this sheet's box in the root (None for root)
        self.date = date
        self.rev = rev
        self.items = []
        self.libs = {}
        self.pin_nets = []       # (ref, pin, net) for checking
        self.nets_here = set()
        self.pwr_n = 0
        self.boxes = []          # (x0, y0, x1, y1, what) for the overlap check
        self.uid = uuidlib.uuid5(_uuid_ns, filename)
        self.comment2 = "Chip numbers U1-U40 = docs/CHIPS.md; decoupling Cn goes with Un"
        self.n = 0
        self.grid = KR.Grid()
        self.sig = []            # signal pins waiting for finish(): dicts
        self.terms = []          # extra wire ends that belong to a net: (net, x, y)
        self.report = []
        self.term_angle = {}
        self.named = set()       # local nets that keep a label (their PWR_FLAG is checked by name)
        self.names = {}          # ref -> function name printed under the part (the PLDs)

    def u(self, *k):
        self.n += 1
        return det_uuid(self.filename, self.n, *k)

    @property
    def path(self):
        return "/" + self.root_uuid + ("/" + self.sheet_uuid if self.sheet_uuid else "")

    def _lib(self, lib_id):
        if lib_id not in self.libs:
            self.libs[lib_id] = lib_symbol(lib_id)
        return self.libs[lib_id]

    # ------------------------------------------------------------ primitives
    def wire(self, x1, y1, x2, y2, owner="~wire"):
        self.items.append(("wire", x1, y1, x2, y2, self.u()))   # written by render(), split at junctions
        self.grid.add_seg(x1, y1, x2, y2, owner)

    def bus(self, x1, y1, x2, y2, owner):
        self.items.append(("bus", x1, y1, x2, y2, self.u()))
        self.grid.add_seg(x1, y1, x2, y2, owner)

    def _segments(self):
        """Wires and buses as text.  KiCad joins a wire to another one's middle only where the
        other is cut, so every wire is cut at the junctions and bus entries on it."""
        cuts = set()
        for it in self.items:
            if isinstance(it, str):
                m = re.match(r"\(junction \(at ([-\d.]+) ([-\d.]+)\)", it)
                if m:
                    cuts.add((KR.gi(float(m.group(1))), KR.gi(float(m.group(2)))))
                m = re.match(r"\(bus_entry \(at ([-\d.]+) ([-\d.]+)\) \(size ([-\d.]+) ([-\d.]+)\)", it)
                if m:
                    x, y, dx, dy = map(float, m.groups())
                    cuts.add((KR.gi(x + dx), KR.gi(y + dy)))
        out = []
        for it in self.items:
            if isinstance(it, str):
                out.append(it)
                continue
            kind, x1, y1, x2, y2, uid = it
            a, b = (KR.gi(x1), KR.gi(y1)), (KR.gi(x2), KR.gi(y2))
            inner = sorted(c for c in self._seg_cells((x1, y1), (x2, y2)) - {a, b} if c in cuts) if a != b else []
            if a[0] == b[0] or a[1] == b[1]:
                inner.sort(key=lambda c: abs(c[0] - a[0]) + abs(c[1] - a[1]))
            else:
                inner = []
            pts = [(x1, y1)] + [(c[0] * KR.G, c[1] * KR.G) for c in inner] + [(x2, y2)]
            for k in range(len(pts) - 1):
                u = uid if k == 0 else det_uuid(self.filename, uid, k)
                out.append(f"({kind} (pts (xy {R(pts[k][0])} {R(pts[k][1])}) (xy {R(pts[k + 1][0])} {R(pts[k + 1][1])})) "
                           f"(stroke (width 0) (type default)) (uuid {u}))")
        return out

    def bus_entry(self, x, y, dx, dy, wire_owner, bus_owner):
        self.items.append(f"(bus_entry (at {R(x)} {R(y)}) (size {R(dx)} {R(dy)}) "
                          f"(stroke (width 0) (type default)) (uuid {self.u()}))")
        self.grid.add_point(x, y, wire_owner)
        self.grid.add_point(x + dx, y + dy, bus_owner)
        self.grid.blocked.add((KR.gi(x + dx / 2), KR.gi(y + dy / 2)))

    def junction(self, x, y, owner="~junction"):
        self.items.append(f"(junction (at {R(x)} {R(y)}) (diameter 0) (color 0 0 0 0) (uuid {self.u()}))")
        self.grid.add_point(x, y, owner)

    def terminal(self, net, x, y, angle=0):
        """A wire end the caller drew that belongs to net, to be wired or labelled by finish()."""
        self.terms.append((net, x, y))
        self.term_angle[(net, x, y)] = angle
        self.grid.point[(KR.gi(x), KR.gi(y))] = net
        self.nets_here.add(net)

    def no_connect(self, x, y):
        self.items.append(f"(no_connect (at {R(x)} {R(y)}) (uuid {self.u()}))")
        self.grid.add_point(x, y, "~nc")

    def text(self, s, x, y, size=3.0, bold=False, angle=0):
        b = " bold" if bold else ""
        self.boxes.append((x, y - size * 1.1, x + len(s) * size * 0.92, y + 0.3, "text " + s[:20]))
        self.grid.block_box(x, y - size * 1.1, x + len(s) * size * 0.92, y + 0.3)
        self.items.append(f"(text {q(s)} (at {R(x)} {R(y)} {angle}) "
                          f"(effects (font (size {R(size)} {R(size)}){b}) (justify left bottom)) (uuid {self.u()}))")

    def label(self, net, x, y, angle, etype, glob):
        just = "left" if angle in (0, 90) else "right"
        if glob:
            shape = {"output": "output", "input": "input", "tri_state": "tri_state",
                     "bidirectional": "bidirectional"}.get(etype, "passive")
            self.items.append(
                f"(global_label {q(net)} (shape {shape}) (at {R(x)} {R(y)} {angle}) (fields_autoplaced) "
                f"{font(LABEL_SIZE, f' (justify {just})')} (uuid {self.u()}) "
                f"(property \"Intersheetrefs\" \"${{INTERSHEET_REFS}}\" (at {R(x)} {R(y)} 0) "
                f"{font(LABEL_SIZE, ' (justify left) hide')}))")
        else:
            self.items.append(
                f"(label {q(net)} (at {R(x)} {R(y)} {angle}) (fields_autoplaced) "
                f"{font(LABEL_SIZE, f' (justify {just} bottom)')} (uuid {self.u()}))")
        w = label_len(net, glob)
        dx, dy = {0: (1, 0), 180: (-1, 0), 90: (0, -1), 270: (0, 1)}[angle]
        x2, y2 = x + dx * w, y + dy * w
        if angle in (0, 180):
            box = (min(x, x2), y - (1.0 if glob else 2.2), max(x, x2), y + (1.0 if glob else 0.0))
            gbox = (box[0], y - (1.0 if glob else 1.8), box[2], box[3])
        else:
            box = (x - (1.0 if glob else 2.2), min(y, y2), x + (1.0 if glob else 0.0), max(y, y2))
            gbox = (x - (1.0 if glob else 1.8), box[1], box[2], box[3])
        self.boxes.append(box + ("label " + net,))
        self.grid.block_box(*gbox, keep={(KR.gi(x), KR.gi(y))})
        self.grid.add_point(x, y, net)

    def power(self, net, x, y, angle=0, toward=None):
        """A power symbol whose pin is at (x, y); toward = the stub direction (sx, sy) it points along."""
        lib_id = POWER_NETS[net] if net in POWER_NETS else net
        self._lib(lib_id)
        x, y = snap(x), snap(y)
        self.pwr_n += 1
        ref = f"#PWR{self.page:02d}{self.pwr_n:02d}"
        down = net in ("GND", "GNDA")
        vx, vy = x, (y + 6.35 if down else y - 6.35)
        if toward is not None:
            sx, sy = toward
            if down:
                angle = {(0, 1): 0, (0, -1): 180, (-1, 0): 270, (1, 0): 90}[(sx, sy)]
            else:
                angle = {(0, -1): 0, (0, 1): 180, (-1, 0): 90, (1, 0): 270}[(sx, sy)]
            if sx:
                vx, vy = x + sx * 6.0, y - 1.5
            else:
                vx, vy = x, y + sy * 6.35
        dirv = {0: (0, -1), 180: (0, 1), 90: (-1, 0), 270: (1, 0)}[angle % 360]
        if down:
            dirv = (-dirv[0], -dirv[1])
        self.grid.add_point(x, y, net)
        ex, ey = x + dirv[0] * 4.5, y + dirv[1] * 4.5
        self.grid.block_box(min(x, ex) - (1.3 if dirv[1] else 0), min(y, ey) - (1.3 if dirv[0] else 0),
                            max(x, ex) + (1.3 if dirv[1] else 0), max(y, ey) + (1.3 if dirv[0] else 0),
                            keep={(KR.gi(x), KR.gi(y))})
        if not hide_val_for(net):
            self.grid.block_box(vx - 1.0, vy - 2.2, vx + len(net) * 1.9, vy + 0.5)
        val = net if lib_id.startswith("power:") and "PWR_FLAG" not in lib_id else uq(sym_props(self._lib(lib_id))["Value"][2])
        hide_val = " hide" if net in ("GND", "GNDA") else ""
        self.items.append(
            f"(symbol (lib_id {q(lib_id)}) (at {R(x)} {R(y)} {angle}) (unit 1) (in_bom yes) (on_board yes) (dnp no) "
            f"(uuid {self.u()}) "
            f"(property \"Reference\" {q(ref)} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')}) "
            f"(property \"Value\" {q(val)} (at {R(vx)} {R(vy)} 0) {font(LABEL_SIZE, hide_val)}) "
            f"(property \"Footprint\" \"\" (at {R(x)} {R(y)} 0) {font(1.27, ' hide')}) "
            f"(property \"Datasheet\" \"\" (at {R(x)} {R(y)} 0) {font(1.27, ' hide')}) "
            f"(pin \"1\" (uuid {self.u()})) "
            f"(instances (project {q(self.project)} (path {q(self.path)} (reference {q(ref)}) (unit 1)))))")

    def pwr_flag(self, x, y):
        self._lib("power:PWR_FLAG")
        self.pwr_n += 1
        ref = f"#FLG{self.page:02d}{self.pwr_n:02d}"
        x, y = snap(x), snap(y)
        self.grid.add_point(x, y, "~flag")
        self.grid.block_box(x - 1.5, y - 5.5, x + 1.5, y - 1.0)
        self.items.append(
            f"(symbol (lib_id \"power:PWR_FLAG\") (at {R(x)} {R(y)} 0) (unit 1) (in_bom yes) (on_board yes) (dnp no) "
            f"(uuid {self.u()}) "
            f"(property \"Reference\" {q(ref)} (at {R(x)} {R(y - 2)} 0) {font(1.27, ' hide')}) "
            f"(property \"Value\" \"PWR_FLAG\" (at {R(x)} {R(y - 4)} 0) {font(1.5)}) "
            f"(property \"Footprint\" \"\" (at {R(x)} {R(y)} 0) {font(1.27, ' hide')}) "
            f"(property \"Datasheet\" \"~\" (at {R(x)} {R(y)} 0) {font(1.27, ' hide')}) "
            f"(pin \"1\" (uuid {self.u()})) "
            f"(instances (project {q(self.project)} (path {q(self.path)} (reference {q(ref)}) (unit 1)))))")

    # ------------------------------------------------------------ parts
    def part(self, lib_id, ref, x, y, nets, value=None, footprint=None, unit=1, angle=0,
             ref_at=None, value_at=None, extra_props=None, stub=None, hide_value=False, dnp=False, bare=()):
        """Place a symbol and connect its pins.  nets maps pin number -> net (None = no connect)."""
        symdef = self._lib(lib_id)
        props = sym_props(symdef)
        pins = [p for p in sym_pins(symdef) if p[8] in (0, unit)]
        x, y = snap(x), snap(y)
        # pin positions in schematic space
        placed = {}
        for num, pname, etype, px, py, pang, plen, hidden, _u in pins:
            ox, oy = rot(px, -py, angle)
            dx, dy = _dir(pang)
            ddx, ddy = rot(dx, -dy, angle)
            placed.setdefault(num, []).append((x + ox, y + oy, -ddx, -ddy, etype, hidden, pname))
        # body extent for the overlap check and text placement
        xs = [x + rot(p[3], -p[4], angle)[0] for p in pins] or [x]
        ys = [y + rot(p[3], -p[4], angle)[1] for p in pins] or [y]
        self.boxes.append((min(xs), min(ys), max(xs), max(ys), "part " + ref))
        bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
        if bx1 - bx0 < 2.6:
            bx0, bx1 = bx0 - 1.27, bx1 + 1.27
        if by1 - by0 < 2.6:
            by0, by1 = by0 - 1.27, by1 + 1.27
        self.grid.block_box(bx0, by0, bx1, by1)   # body and pin ends: no wire runs along a row of pins
        for num, plist in placed.items():
            self.grid.add_point(plist[0][0], plist[0][1], ("~pin", ref, num))
        missing = []
        done_pos = set()
        pos_net = {}
        side = {}
        pgroups = {}
        for num, plist in sorted(placed.items(), key=lambda kv: kv[1][0][5]):
            px, py, sx, sy, etype, hidden, pname = plist[0]
            if etype == "no_connect":
                continue
            key = (round(px, 3), round(py, 3))
            if num not in nets:
                if hidden and key in done_pos:
                    self.pin_nets.append((ref, num, pos_net.get(key)))
                    continue
                missing.append(num)
                continue
            net = nets[num]
            if hidden and key in done_pos:
                self.pin_nets.append((ref, num, pos_net.get(key)))
                continue
            pos_net[key] = net
            done_pos.add(key)
            self.pin_nets.append((ref, num, net))
            self.grid.point[(KR.gi(px), KR.gi(py))] = net if net is not None else "~nc"
            if num in bare:     # wired by the caller
                continue
            if net is None:
                self.no_connect(px, py)
                continue
            if net in POWER_NETS:
                pgroups.setdefault((round(sx), round(sy), net), []).append((px, py))
            else:
                side.setdefault((round(sx), round(sy)), []).append((px, py, net, etype))
        # power pins: one symbol per pin, or one symbol for a row of neighbouring pins tied together
        for (sx, sy, net), pl in pgroups.items():
            ln = POWER_STUB if stub is None else stub
            along = (lambda t: t[1]) if sx else (lambda t: t[0])
            pl.sort(key=along)
            runs = [[pl[0]]]
            for t in pl[1:]:
                if abs(along(t) - along(runs[-1][-1])) < 2.6:
                    runs[-1].append(t)
                else:
                    runs.append([t])
            for run in runs:
                ends = []
                for px, py in run:
                    ex, ey = px + sx * ln, py + sy * ln
                    if ln > 0:
                        self.wire(px, py, ex, ey, owner=net)
                    ends.append((ex, ey))
                for k in range(1, len(ends)):
                    self.wire(ends[k - 1][0], ends[k - 1][1], ends[k][0], ends[k][1], owner=net)
                for k in range(1, len(ends) - 1):
                    self.junction(*ends[k], owner=net)
                down = net in ("GND", "GNDA")
                ex, ey = ends[-1] if (down or not sx) else ends[0]
                self.power(net, ex, ey, toward=(sx, sy))
        for (sx, sy), lst in side.items():
            for px, py, net, etype in lst:
                self.sig.append(dict(ref=ref, net=net, x=px, y=py, sx=sx, sy=sy, etype=etype,
                                     stub=STUB if stub is None else stub))
                self.nets_here.add(net)
        extra = set(nets) - set(placed)
        if missing or extra:
            raise SystemExit(f"{self.filename} {ref}: pins without a net {sorted(missing)}, unknown pins {sorted(extra)}")
        # properties
        val = value or uq(props["Value"][2])
        fp = footprint if footprint is not None else uq(props.get("Footprint", [0, 0, '""'])[2])
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        if ref_at is None:
            ref_at = (x0 + (x1 - x0) * 0.15 if x1 - x0 > 8 else x1 + 1.5, y0 - 1.5 if y1 - y0 > 8 else y0 - 1.0)
        if value_at is None:
            value_at = (ref_at[0], y1 + 4.0 if y1 - y0 > 8 else y1 + 3.5)
        plist_out = []
        fa = angle % 180   # field angle that reads horizontally on a rotated symbol
        # KiCad turns a field that would read upside down, which mirrors its justification
        flip = angle % 360 in (90, 180)
        jr = "right top" if flip else "left bottom"
        jv = "right bottom" if flip else "left top"
        plist_out.append(f"(property \"Reference\" {q(ref)} (at {R(ref_at[0])} {R(ref_at[1])} {fa}) "
                         f"(effects (font (size {REF_SIZE} {REF_SIZE}) bold) (justify {jr})))")
        plist_out.append(f"(property \"Value\" {q(val)} (at {R(value_at[0])} {R(value_at[1])} {fa}) "
                         f"{font(VALUE_SIZE, f' (justify {jv})' + (' hide' if hide_value else ''))})")
        fname = self.names.get(ref)
        if fname:
            fn_at = (value_at[0], value_at[1] + VALUE_SIZE * 1.7)   # under the value (the PLDs are not rotated)
            plist_out.append(f"(property \"Function\" {q(fname)} (at {R(fn_at[0])} {R(fn_at[1])} {fa}) "
                             f"(effects (font (size {REF_SIZE} {REF_SIZE}) bold) (justify {jv})))")
            wf = len(fname) * REF_SIZE * 0.95
            self.grid.block_box(fn_at[0], fn_at[1], fn_at[0] + wf, fn_at[1] + REF_SIZE * 1.1)
            self.boxes.append((fn_at[0], fn_at[1], fn_at[0] + wf, fn_at[1] + REF_SIZE * 1.1, "name " + ref))
        plist_out.append(f"(property \"Footprint\" {q(fp)} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        ds = uq(props["Datasheet"][2]) if "Datasheet" in props else ""
        plist_out.append(f"(property \"Datasheet\" {q(ds)} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        for k, v in (extra_props or {}).items():
            plist_out.append(f"(property {q(k)} {q(v)} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        for k, p in props.items():
            if k in ("Reference", "Value", "Footprint", "Datasheet") or k.startswith("ki_") or k in (extra_props or {}):
                continue
            plist_out.append(f"(property {q(k)} {p[2]} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        wr = len(ref) * REF_SIZE * 0.95
        wv = 0 if hide_value else len(val) * VALUE_SIZE * 0.9
        # on the page the fields read as on an unrotated part (the flipped justification undoes the turn)
        self.grid.block_box(ref_at[0], ref_at[1] - REF_SIZE * 1.1, ref_at[0] + wr, ref_at[1])
        if wv:
            self.grid.block_box(value_at[0], value_at[1], value_at[0] + wv, value_at[1] + VALUE_SIZE * 1.1)
        pin_uuids = " ".join(f"(pin {q(num)} (uuid {self.u()}))" for num in placed)
        self.items.append(
            f"(symbol (lib_id {q(lib_id)}) (at {R(x)} {R(y)} {angle}) (unit {unit}) (in_bom yes) (on_board yes) "
            f"(dnp {'yes' if dnp else 'no'}) (uuid {self.u(ref)}) " + " ".join(plist_out) + " " + pin_uuids +
            f" (instances (project {q(self.project)} (path {q(self.path)} (reference {q(ref)}) (unit {unit})))))")
        return {num: (pl[0][0], pl[0][1]) for num, pl in placed.items()}

    # ------------------------------------------------------------ wiring
    def finish(self, global_nets):
        """Wire the signal pins: buses get bus entries and one routed bus line per bus,
        nets with several pins on the sheet are wired together, a net that leaves the
        sheet gets a global label, and a net with one pin a label on a stub."""
        G = KR.G
        sig = self.sig
        count = {}
        for p in sig:
            count[p["net"]] = count.get(p["net"], 0) + 1
        for net, _x, _y in self.terms:
            count[net] = count.get(net, 0) + 1
        # buses: a prefix with three or more numbered nets on this sheet
        members = {}
        for net in count:
            m = BUS_RE.match(net)
            if m and m.group(1) not in NOT_BUS:
                members.setdefault(m.group(1), set()).add(net)
        buses = {pre: ms for pre, ms in members.items() if len(ms) >= 3}
        bus_of = {n: pre for pre, ms in buses.items() for n in ms}
        bus_term = {n for n, _x, _y in self.terms if n in bus_of}
        if bus_term:
            raise SystemExit(f"{self.filename}: bus member drawn by hand: {sorted(bus_term)}")
        groups = {}
        for p in sig:
            groups.setdefault((p["ref"], p["sx"], p["sy"]), []).append(p)
        # which pin of a multi-pin net carries its label (only nets that leave the sheet)
        anchor = {}
        for net, x, y in self.terms:
            anchor.setdefault(net, ("term", x, y))
        for p in sig:
            anchor.setdefault(p["net"], ("pin", id(p)))
        bus_segs = {}     # prefix -> [((x1, y1), (x2, y2)), ...] in mm
        seed = {}         # net -> cells already joined to the net's label (the routes grow from these)
        routes = []       # (net, start cell, avoid cells)
        for (ref, sx, sy), lst in groups.items():
            along = (lambda t: t["y"]) if sx else (lambda t: t["x"])
            lst.sort(key=along)
            ang = {(1, 0): 0, (-1, 0): 180, (0, -1): 90, (0, 1): 270}[(sx, sy)]
            # bus members of this side, one column per bus
            outer = 0.0
            pres = []
            for p in lst:
                pre = bus_of.get(p["net"])
                if pre and pre not in pres:
                    pres.append(pre)
            for gi_, pre in enumerate(pres):
                ps = [p for p in lst if bus_of.get(p["net"]) == pre]
                lw = max(label_len(p["net"], False) for p in ps) + G
                d = math.ceil((lw + G) / G - 1e-6) * G + gi_ * 2 * G
                outer = max(outer, d + G)
                ex, ey = (sx * G if sx else -G), (sy * G if sy else -G)
                pts = []
                for p in ps:
                    wx, wy = p["x"] + sx * d, p["y"] + sy * d
                    self.wire(p["x"], p["y"], wx, wy, owner=p["net"])
                    self.label(p["net"], p["x"], p["y"], ang, p["etype"], False)
                    self.bus_entry(wx, wy, ex, ey, p["net"], "BUS:" + pre)
                    pts.append((wx + ex, wy + ey))
                pts.sort(key=lambda t: t[1] if sx else t[0])
                if len(pts) > 1:
                    self.bus(pts[0][0], pts[0][1], pts[-1][0], pts[-1][1], "BUS:" + pre)
                bus_segs.setdefault(pre, []).append((pts[0], pts[-1]))
            # labelled pins: nets with one connection here, and the label pin of a net that leaves the sheet
            rest = [p for p in lst if p["net"] not in bus_of]
            lab = [p for p in rest if count[p["net"]] == 1 or
                   ((p["net"] in global_nets or p["net"] in self.named) and anchor[p["net"]] == ("pin", id(p)))]
            far = [False] * len(lab)
            for i in range(1, len(lab)):
                if abs(along(lab[i]) - along(lab[i - 1])) < 3.5 and not far[i - 1]:
                    far[i] = True
            labset = {id(p) for p in lab}
            for i, (p, f) in enumerate(zip(lab, far)):
                base = max(p["stub"], outer + 2 * G if outer else 0)
                ln = base
                if f:   # clear the near labels on both sides of this one
                    w = max(label_len(lab[j]["net"]) for j in (i - 1, i + 1) if 0 <= j < len(lab) and not far[j])
                    ln = base + math.ceil((w + 2.0) / 2.54) * 2.54
                lx, ly = p["x"] + sx * ln, p["y"] + sy * ln
                if ln > 0:
                    self.wire(p["x"], p["y"], lx, ly, owner=p["net"])
                if count[p["net"]] > 1:
                    seed[p["net"]] = self._seg_cells((p["x"], p["y"]), (lx, ly))
                self.label(p["net"], lx, ly, ang, p["etype"], p["net"] in global_nets)
            for p in rest:
                if id(p) in labset:
                    continue
                tx, ty = p["x"] + sx * 2 * G, p["y"] + sy * 2 * G
                self.wire(p["x"], p["y"], tx, ty, owner=p["net"])
                own = {(KR.gi(p["x"] + sx * G), KR.gi(p["y"] + sy * G))}
                routes.append((p["net"], (KR.gi(tx), KR.gi(ty)), own))
        for net, x, y in self.terms:
            if count[net] > 1:
                if (net in global_nets or net in self.named) and anchor[net][1:] == (x, y):
                    seed[net] = {(KR.gi(x), KR.gi(y))}
                else:
                    routes.append((net, (KR.gi(x), KR.gi(y)), set()))
        term_labels = [(net, x, y) for net, x, y in self.terms
                       if count[net] == 1 or ((net in global_nets or net in self.named) and anchor[net][1:] == (x, y))]
        for net, x, y in term_labels:
            self.label(net, x, y, self.term_angle.get((net, x, y), 0), "passive", net in global_nets)
        # bus lines: join the pieces of each bus
        for pre, segs in bus_segs.items():
            owner = "BUS:" + pre
            conn = self._seg_cells(*segs[0])
            alone = []
            for a, b in segs[1:]:
                tree = conn
                mine = self._seg_cells(a, b)
                best = None
                for st in ((KR.gi(a[0]), KR.gi(a[1])), (KR.gi(b[0]), KR.gi(b[1]))):
                    path = self.grid.route(owner, st, tree - mine, avoid=mine - {st})
                    if path and (best is None or len(path) < len(best)):
                        best = path
                if best is None:
                    self.report.append(f"bus {pre} piece at {a} not joined: labelled")
                    alone.append(mine)
                    continue
                for c1, c2 in KR.path_segments(best):
                    self.bus(c1[0] * G, c1[1] * G, c2[0] * G, c2[1] * G, owner)
                conn = conn | mine | set(best)
            nets = sorted(buses[pre], key=lambda n: int(BUS_RE.match(n).group(2)))
            glob = any(n in global_nets for n in buses[pre])
            self._bus_label(pre, nets, glob, conn)
            for cells in alone:
                self._bus_label(pre, nets, glob, cells)
        # nets: short ones first
        pins_of = {}
        for p in sig:
            pins_of.setdefault(p["net"], set()).add((KR.gi(p["x"]), KR.gi(p["y"])))

        def span(r):
            cs = self.grid.cells_of(r[0])
            return max(c[0] for c in cs) - min(c[0] for c in cs) + max(c[1] for c in cs) - min(c[1] for c in cs)
        routes.sort(key=span)
        first = {}
        for net, st, own in routes:
            if net not in seed:     # the first pin of a net without a label: the others join it
                seed[net] = own | {st}
                first[net] = st
                continue
            tree = seed[net] - own - {st}
            path = self.grid.route(net, st, tree, avoid=own, no_end=pins_of.get(net, ()))
            if path is None:
                self.report.append(f"{net}: not routed from {st[0] * G:.2f},{st[1] * G:.2f}")
                if os.environ.get("ROUTE_DEBUG"):
                    g = self.grid
                    for j in range(st[1] - 4, st[1] + 5):
                        print("".join("S" if (i, j) == st else "T" if (i, j) in tree else "#" if (i, j) in g.blocked
                                      else "a" if (i, j) in own else "o" if g.point.get((i, j)) not in (None, net)
                                      else "-" if g.foreign(g.h, (i, j), net) else "|" if g.foreign(g.v, (i, j), net)
                                      else "." for i in range(st[0] - 8, st[0] + 9)))
                glob = net in global_nets
                self._term_label(net, st, glob)
                if not glob and net in first:   # a local net also needs its name where the wires start
                    self._term_label(net, first.pop(net), False)
                continue
            for c1, c2 in KR.path_segments(path):
                self.wire(c1[0] * G, c1[1] * G, c2[0] * G, c2[1] * G, owner=net)
            seed[net] |= own | set(path)
        self._junctions(pins_of)

    def _term_label(self, net, c, glob):
        """A label on a stub end, pointing away from its pin."""
        g = self.grid
        ang = 0
        for d, a in (((1, 0), 0), ((-1, 0), 180), ((0, -1), 90), ((0, 1), 270)):
            back = (c[0] - d[0], c[1] - d[1])
            if net in g.h.get(back, ()) or net in g.v.get(back, ()):
                ang = a
                break
        self.label(net, c[0] * KR.G, c[1] * KR.G, ang, "passive", glob)

    def _seg_cells(self, a, b):
        a, b = (KR.gi(a[0]), KR.gi(a[1])), (KR.gi(b[0]), KR.gi(b[1]))
        if a[0] == b[0]:
            return {(a[0], j) for j in range(min(a[1], b[1]), max(a[1], b[1]) + 1)}
        return {(i, a[1]) for i in range(min(a[0], b[0]), max(a[0], b[0]) + 1)}

    def _bus_label(self, pre, nets, glob, piece):
        """A label on a short bus stub off a free end of the bus."""
        G = KR.G
        nums = [int(BUS_RE.match(n).group(2)) for n in nets]
        name = f"{pre}[{min(nums)}..{max(nums)}]"
        owner = "BUS:" + pre
        w = label_len(name, glob)
        ends = []
        mine = [(a, b) for a, b in self.grid.segs.get(owner, []) if a in piece and b in piece]
        for a, b in mine:
            for c, o in ((a, b), (b, a)):
                d = (c[0] - o[0], c[1] - o[1])
                d = (d[0] and (1 if d[0] > 0 else -1), d[1] and (1 if d[1] > 0 else -1))
                ends.append((c, d))
        for c, o in [(c, o) for c, o in self.grid.point.items() if o == owner and c in piece]:
            if not any(c == e[0] for e in ends):
                ends.extend([(c, (0, -1)), (c, (0, 1)), (c, (-1, 0)), (c, (1, 0))])
        g = self.grid
        inner = []
        for a, b in mine:
            if a[0] == b[0] or a[1] == b[1]:
                perp = ((1, 0), (-1, 0)) if a[0] == b[0] else ((0, -1), (0, 1))
                inner += [(c, d) for c in sorted(self._seg_cells((a[0] * G, a[1] * G), (b[0] * G, b[1] * G)) - {a, b})
                          for d in perp]
        cands = [(c, d) for c, d in ends + [(c, dd) for c, _ in ends for dd in ((0, -1), (0, 1), (-1, 0), (1, 0))] + inner
                 if d != (0, 0)]
        nt = int(math.ceil(w / G)) + 1

        def free(c, d, stub, strict):
            for k in range(1, stub + nt + 1):
                cc = (c[0] + d[0] * k, c[1] + d[1] * k)
                if not g.inside(cc):
                    return False
                wire_cell = k <= stub     # the bus stub and the label's anchor: nothing else may touch them
                if wire_cell or strict:
                    if g.point.get(cc) is not None or g.h.get(cc) or g.v.get(cc):
                        return False
                if strict:
                    side = [(cc[0] + d[1] * t, cc[1] + d[0] * t) for t in (-1, 1)]
                    if cc in g.blocked or any(t in g.blocked or g.point.get(t) for t in side):
                        return False
            return True

        for stub, strict in ((2, True), (4, True), (6, True), (2, False), (4, False)):
            for c, d in cands:
                if not free(c, d, stub, strict):
                    continue
                x2, y2 = (c[0] + d[0] * stub) * G, (c[1] + d[1] * stub) * G
                self.bus(c[0] * G, c[1] * G, x2, y2, owner)
                if (c, d) in inner:
                    self.junction(c[0] * G, c[1] * G, owner=owner)
                ang = {(1, 0): 0, (-1, 0): 180, (0, -1): 90, (0, 1): 270}[d]
                self.label(name, x2, y2, ang, "bidirectional" if glob else "passive", glob)
                if not strict:
                    self.report.append(f"bus {pre}: label squeezed in at {x2:.2f},{y2:.2f}")
                return
        self.report.append(f"bus {pre}: no room for its label")

    def _junctions(self, pins_of):
        """A junction where three or more wire arms of a net meet."""
        have = set()
        for it in self.items:
            if isinstance(it, str) and it.startswith("(junction"):
                m = re.match(r"\(junction \(at ([-\d.]+) ([-\d.]+)\)", it)
                have.add((KR.gi(float(m.group(1))), KR.gi(float(m.group(2)))))
        extra = {}
        for net, x, y in self.terms:
            extra.setdefault(net, []).append((KR.gi(x), KR.gi(y)))
        for owner, segs in self.grid.segs.items():
            if owner.startswith("~") and not owner.startswith("~{"):   # hand-drawn wires
                continue
            arms = {}
            for a, b in segs:
                if a[0] != b[0] and a[1] != b[1]:
                    continue
                arms[a] = arms.get(a, 0) + 1
                arms[b] = arms.get(b, 0) + 1
                for c in self._seg_cells((a[0] * KR.G, a[1] * KR.G), (b[0] * KR.G, b[1] * KR.G)) - {a, b}:
                    arms[c] = arms.get(c, 0) + 2
            for c in list(pins_of.get(owner, ())) + extra.get(owner, []):
                if c in arms:
                    arms[c] += 1
            for c, k in arms.items():
                if k >= 3 and c not in have:
                    self.junction(c[0] * KR.G, c[1] * KR.G, owner=owner)
                    have.add(c)

    # ------------------------------------------------------------ output
    def render(self, paper="A3", extra=""):
        lib = "\n    ".join(dump(v, 2) for v in self.libs.values())
        tb = (f"(title_block (title {q('Placard: ' + self.title)}) (date {q(self.date)}) (rev {q(self.rev)}) "
              f"(company \"Placard computer\") (comment 1 \"Generated by src/scripts/gen_kicad_schematic.py; "
              f"plan in docs/SCHEMATIC_PLAN.md\") (comment 2 {q(self.comment2)}))")
        body = "\n  ".join(self._segments())
        tail = ""
        if self.sheet_uuid is None:
            tail = "\n  (sheet_instances (path \"/\" (page \"1\")))"
        return (f"(kicad_sch (version 20230121) (generator eeschema)\n  (uuid {self.uid})\n  (paper {q(paper)})\n  {tb}\n"
                f"  (lib_symbols\n    {lib}\n  )\n  {body}\n  {extra}{tail}\n)\n")

    def overlaps(self, frame=(12, 12, 408, 285), title=(300, 255)):
        out = []
        b = self.boxes
        for i in range(len(b)):
            p = b[i]
            if p[0] < frame[0] or p[1] < frame[1] or p[2] > frame[2] or p[3] > frame[3]:
                out.append(("off the page", p[4], round(p[0]), round(p[1])))
            elif p[2] > title[0] and p[3] > title[1]:
                out.append(("title block", p[4], round(p[0]), round(p[1])))
            for j in range(i + 1, len(b)):
                r = b[j]
                if p[0] < r[2] - 0.3 and r[0] < p[2] - 0.3 and p[1] < r[3] - 0.3 and r[1] < p[3] - 0.3:
                    if p[4] == r[4]:
                        continue
                    out.append((p[4], r[4], round(p[0]), round(p[1])))
        return out
