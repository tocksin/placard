"""snapends.py in.kicad_pcb out.kicad_pcb [plan.json [report.json]] : give every off-centre track end that lies in a same-net pad a
straight segment (same width and layer) to the exact pad centre; GND/+5V/CLK_E are left alone, an end on a via is only reported.
plan.json {"move": [keys], "skip": [keys]} moves that end point (every segment ending there) to the centre instead, or leaves it; key = "layer|net|x_nm|y_nm".
Run it with KiCad's python (it imports pcbnew)."""
import sys, json, os, pcbnew
fin, fout = sys.argv[1:3]
planf = sys.argv[3] if len(sys.argv) > 3 else ""
addf = sys.argv[4] if len(sys.argv) > 4 else ""
plan = json.load(open(planf)) if planf and os.path.exists(planf) else {}
move, skip = set(plan.get("move", [])), set(plan.get("skip", []))
b = pcbnew.LoadBoard(fin)
SKIPNET = {"GND", "+5V", "CLK_E"}
pads = list(b.GetPads())
padsByNet = {}
for p in pads: padsByNet.setdefault(p.GetNetCode(), []).append(p)
tracks = [t for t in b.GetTracks() if t.GetClass() == "PCB_TRACK" and t.GetNetname() not in SKIPNET]
vias = [t for t in b.GetTracks() if t.GetClass() == "PCB_VIA" and t.GetNetname() not in SKIPNET]
lname = b.GetLayerName
# end points grouped by (layer, net, point)
pts = {}
for t in tracks:
    for which, q in (("s", t.GetStart()), ("e", t.GetEnd())):
        k = (t.GetLayer(), t.GetNetCode(), q.x, q.y)
        pts.setdefault(k, []).append((t, which))
TOL = 10000  # 0.01 mm
added, moved, viaInPad, rows = {}, [], [], []
for (layer, net, x, y), segs in pts.items():
    pt = pcbnew.VECTOR2I(x, y)
    pad = next((p for p in padsByNet.get(net, []) if p.IsOnLayer(layer) and p.HitTest(pt)), None)
    if pad is None: continue
    c = pad.GetPosition()
    d = ((x - c.x) ** 2 + (y - c.y) ** 2) ** 0.5
    if d <= TOL: continue
    key = f"{lname(layer)}|{segs[0][0].GetNetname()}|{x}|{y}"
    ref = f"{pad.GetParentFootprint().GetReference()}-{pad.GetNumber()}"
    v = next((v for v in vias if v.GetNetCode() == net and v.GetPosition().x == x and v.GetPosition().y == y), None)
    if v is not None:
        viaInPad.append((key, ref, d / 1e6)); continue
    if key in skip: rows.append(("skip", key, ref, d / 1e6)); continue
    if key in move:
        for t, which in segs:
            (t.SetStart if which == "s" else t.SetEnd)(pcbnew.VECTOR2I(c.x, c.y))
        moved.append(key); rows.append(("move", key, ref, d / 1e6)); continue
    s = pcbnew.PCB_TRACK(b)
    s.SetStart(pt); s.SetEnd(pcbnew.VECTOR2I(c.x, c.y))
    s.SetWidth(max(t.GetWidth() for t, _ in segs)); s.SetLayer(layer); s.SetNetCode(net)
    b.Add(s)
    added[key] = s.m_Uuid.AsString(); rows.append(("add", key, ref, d / 1e6))
pcbnew.SaveBoard(fout, b)
if addf: json.dump({"added": added, "moved": moved, "viaInPad": viaInPad, "rows": rows}, open(addf, "w"), indent=0)
from collections import Counter
print(Counter(r[0] for r in rows), "via in pad:", len(viaInPad))
