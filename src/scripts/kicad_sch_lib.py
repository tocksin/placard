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
        self.pending_labels = []  # (net, x, y, angle, etype)
        self.pwr_n = 0
        self.boxes = []          # (x0, y0, x1, y1, what) for the overlap check
        self.uid = uuidlib.uuid5(_uuid_ns, filename)
        self.comment2 = "Chip numbers U1-U41 = docs/CHIPS.md; decoupling Cn goes with Un"
        self.n = 0

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
    def wire(self, x1, y1, x2, y2):
        self.items.append(f"(wire (pts (xy {R(x1)} {R(y1)}) (xy {R(x2)} {R(y2)})) "
                          f"(stroke (width 0) (type default)) (uuid {self.u()}))")

    def junction(self, x, y):
        self.items.append(f"(junction (at {R(x)} {R(y)}) (diameter 0) (color 0 0 0 0) (uuid {self.u()}))")

    def no_connect(self, x, y):
        self.items.append(f"(no_connect (at {R(x)} {R(y)}) (uuid {self.u()}))")

    def text(self, s, x, y, size=3.0, bold=False, angle=0):
        b = " bold" if bold else ""
        self.boxes.append((x, y - size * 1.1, x + len(s) * size * 0.92, y + 0.3, "text " + s[:20]))
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
        self.boxes.append((min(x, x2), min(y, y2) - 1.2, max(x, x2), max(y, y2) + 1.2, "label " + net))

    def power(self, net, x, y, angle=0, toward=None):
        """A power symbol whose pin is at (x, y); toward = the stub direction (sx, sy) it points along."""
        lib_id = POWER_NETS[net] if net in POWER_NETS else net
        self._lib(lib_id)
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
                        self.wire(px, py, ex, ey)
                    ends.append((ex, ey))
                for k in range(1, len(ends)):
                    self.wire(ends[k - 1][0], ends[k - 1][1], ends[k][0], ends[k][1])
                for k in range(1, len(ends) - 1):
                    self.junction(*ends[k])
                down = net in ("GND", "GNDA")
                ex, ey = ends[-1] if (down or not sx) else ends[0]
                self.power(net, ex, ey, toward=(sx, sy))
        # signal labels: neighbours closer than a label's height are staggered
        # (near and far), so the labels never sit on top of each other
        for (sx, sy), lst in side.items():
            along = (lambda t: t[1]) if sx else (lambda t: t[0])
            lst.sort(key=along)
            far = [False] * len(lst)
            for i in range(1, len(lst)):
                if abs(along(lst[i]) - along(lst[i - 1])) < 3.5 and not far[i - 1]:
                    far[i] = True
            base = STUB if stub is None else stub
            ang = {(1, 0): 0, (-1, 0): 180, (0, -1): 90, (0, 1): 270}[(sx, sy)]
            for i, ((px, py, net, etype), f) in enumerate(zip(lst, far)):
                ln = base
                if f:   # clear the near labels on both sides of this one
                    w = max(label_len(lst[j][2]) for j in (i - 1, i + 1) if 0 <= j < len(lst) and not far[j])
                    ln = base + math.ceil((w + 2.0) / 2.54) * 2.54
                ex, ey = px + sx * ln, py + sy * ln
                if ln > 0:
                    self.wire(px, py, ex, ey)
                self.nets_here.add(net)
                self.pending_labels.append((net, ex, ey, ang, etype))
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
        plist_out.append(f"(property \"Footprint\" {q(fp)} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        ds = uq(props["Datasheet"][2]) if "Datasheet" in props else ""
        plist_out.append(f"(property \"Datasheet\" {q(ds)} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        for k, v in (extra_props or {}).items():
            plist_out.append(f"(property {q(k)} {q(v)} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        for k, p in props.items():
            if k in ("Reference", "Value", "Footprint", "Datasheet") or k.startswith("ki_") or k in (extra_props or {}):
                continue
            plist_out.append(f"(property {q(k)} {p[2]} (at {R(x)} {R(y)} 0) {font(1.27, ' hide')})")
        pin_uuids = " ".join(f"(pin {q(num)} (uuid {self.u()}))" for num in placed)
        self.items.append(
            f"(symbol (lib_id {q(lib_id)}) (at {R(x)} {R(y)} {angle}) (unit {unit}) (in_bom yes) (on_board yes) "
            f"(dnp {'yes' if dnp else 'no'}) (uuid {self.u(ref)}) " + " ".join(plist_out) + " " + pin_uuids +
            f" (instances (project {q(self.project)} (path {q(self.path)} (reference {q(ref)}) (unit {unit})))))")
        return {num: (pl[0][0], pl[0][1]) for num, pl in placed.items()}

    def finish_labels(self, global_nets):
        for net, x, y, ang, etype in self.pending_labels:
            self.label(net, x, y, ang, etype, net in global_nets)
        self.pending_labels = []

    # ------------------------------------------------------------ output
    def render(self, paper="A3", extra=""):
        lib = "\n    ".join(dump(v, 2) for v in self.libs.values())
        tb = (f"(title_block (title {q('Placard: ' + self.title)}) (date {q(self.date)}) (rev {q(self.rev)}) "
              f"(company \"Placard computer\") (comment 1 \"Generated by src/scripts/gen_kicad_schematic.py; "
              f"plan in docs/SCHEMATIC_PLAN.md\") (comment 2 {q(self.comment2)}))")
        body = "\n  ".join(self.items)
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
