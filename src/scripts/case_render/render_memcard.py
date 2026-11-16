#!/usr/bin/env python3
"""
render_memcard.py - 3D pictures of the 512K memory card and its shell,
docs/case/memcard_*.png, with KiCad 9's renderer (kicad-cli pcb render).

    python3 render_memcard.py [outdir]

Needs CadQuery and KiCad 9's kicad-cli; KICAD_CLI names the command if it is
not plain "kicad-cli" (for example a chroot), and TMPDIR must then be a
directory that command can see under the same path.  It works on a scratch
copy of kicad/memory_card/memory_card.kicad_pcb: the PLDs are put in their
sockets and the shell halves (gen_memcard_shell.py), their screws, nuts and
insert are added as footprints that carry only a 3D model.  The board file
in the repo is not changed.

Date: 2026-11-16
"""

import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

import cadquery as cq

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import gen_memcard_shell as g  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
LIB = os.path.join(ROOT, "kicad", "lib")
PCB = os.path.join(ROOT, "kicad", "memory_card", "memory_card.kicad_pcb")
MODELS = os.environ.get("KICAD9_3DMODEL_DIR", "/usr/share/kicad/3dmodels")
X0, Y0 = 100.0, 200.0        # the card frame's origin on the KiCad page (gen_kicad_cart_pcb.py)
SEAT = 4.0                   # socket seat above the card
SHELL = cq.Color(0.16, 0.17, 0.19)
STEEL = cq.Color(0.75, 0.76, 0.78)
BRASS = cq.Color(0.80, 0.62, 0.25)


def step(solid, color, path):
    a = cq.Assembly()
    a.add(solid, color=color)
    a.save(path)
    return path


def hardware(d):
    screws, nuts = None, None
    for x, y in g.HOLES:
        seat = g.ZB + g.HEAD_H
        s = g.cyl(x, y, 1.5, seat, seat + 8.0).union(g.cyl(x, y, 2.8, seat - 2.4, seat))
        s = s.cut(g.box(x - 1.6, x + 1.6, y - 0.4, y + 0.4, seat - 2.5, seat - 1.4))
        n = g.hexprism(x, y, 5.5, 0.8, 3.2).cut(g.cyl(x, y, 1.5, 0.7, 3.3))
        screws = s if screws is None else screws.union(s)
        nuts = n if nuts is None else nuts.union(n)
    ins = (cq.Workplane("YZ").moveTo(g.INSERT_Y, g.INSERT_Z).circle(2.3).circle(1.25).extrude(5.7)
           .translate((g.X1 + g.PROUD - 5.7, 0, 0)))
    return (step(screws, STEEL, os.path.join(d, "screws.step")), step(nuts, STEEL, os.path.join(d, "nuts.step")),
            step(ins, BRASS, os.path.join(d, "insert.step")))


def model_fp(path, dz):
    """A footprint at the card frame's origin carrying one model, moved dz across the card."""
    return ('\t(footprint "render:%s" (layer "F.Cu") (uuid "%s") (at %g %g)\n'
            '\t\t(attr exclude_from_pos_files exclude_from_bom board_only)\n'
            '\t\t(model "%s" (offset (xyz 0 0 %g)) (scale (xyz 1 1 1)) (rotate (xyz 0 0 0)))\n\t)\n'
            % (os.path.basename(path), uuid.uuid4(), X0, Y0, path, dz - 0.785))


def scene(d, name, extra):
    s = open(PCB).read()
    sock = '(model "${PLACARD_LIB}/placard.3dshapes/DIP-24_W7.62mm_Socket_Puller.step"'
    chip = ('(model "%s/Package_DIP.3dshapes/DIP-24_W7.62mm.step" (offset (xyz 0 0 %g)) (scale (xyz 1 1 1)) '
            '(rotate (xyz 0 0 0)))\n\t\t' % (MODELS, SEAT))
    assert s.count(sock) == 2
    s = s.replace(sock, chip + sock)
    s = s.rstrip()[:-1] + "".join(model_fp(p, dz) for p, dz in extra) + ")\n"
    out = os.path.join(d, name + ".kicad_pcb")
    open(out, "w").write(s)
    return out


def render(pcb, out, rotate, zoom=1.0, pan=None, size=(2400, 1600)):
    cmd = shlex.split(os.environ.get("KICAD_CLI", "kicad-cli")) + ["pcb", "render", "-D", "PLACARD_LIB=" + LIB, "--quality", "high", "--perspective", "--floor",
           "--background", "opaque", "-w", str(size[0]), "-h", str(size[1]), "--rotate", rotate, "--zoom", str(zoom)]
    if pan:
        cmd += ["--pan", pan]
    subprocess.run(cmd + ["-o", out, pcb], check=True, capture_output=True)
    print("wrote", out)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs", "case")
    d = tempfile.mkdtemp()
    front = step(g.front(), SHELL, os.path.join(d, "front.step"))
    back = step(g.back(), SHELL, os.path.join(d, "back.step"))
    screws, nuts, ins = hardware(d)
    bare = scene(d, "bare", [])
    closed = scene(d, "closed", [(front, 0), (back, 0), (screws, 0), (ins, 0)])
    opened = scene(d, "opened", [(back, 0), (screws, 0), (nuts, 0)])
    apart = scene(d, "apart", [(front, 34), (ins, 34), (nuts, 16), (back, -16), (screws, -32)])
    render(bare, os.path.join(outdir, "memcard_board_front.png"), "-50,0,25", zoom=0.9)
    render(bare, os.path.join(outdir, "memcard_board_back.png"), "-130,0,-25", zoom=0.8)
    render(closed, os.path.join(outdir, "memcard_shell_closed.png"), "-55,0,35", zoom=0.8)
    render(closed, os.path.join(outdir, "memcard_shell_back_end.png"), "-60,0,-55", zoom=0.8)
    render(opened, os.path.join(outdir, "memcard_shell_open.png"), "-50,0,25", zoom=0.85)
    render(apart, os.path.join(outdir, "memcard_shell_exploded.png"), "-72,0,35", zoom=0.6)
    shutil.rmtree(d)


if __name__ == "__main__":
    main()
