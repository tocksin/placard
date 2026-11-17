#!/usr/bin/env python3
"""
finish_memcard_pcb.py routed.kicad_pcb out.kicad_pcb - last step of the memory
card's layout: adds the two inner planes (In1.Cu GND, In2.Cu +5V, the
settings of the cartridge boards) to a routed copy of the board and fills
them.  First it joins track ends and surface-mount pads that only touch a
via's copper to the via's centre.  Run it with KiCad 9's python (it imports pcbnew).

The whole flow, from src/scripts (router_v4/README.md, "Memory card"):

    gen_kicad_memcard_pcb.py --out placed.kicad_pcb     placement, nets from the schematic
    router_v4/powerstubs.py                              plane vias for the fingers and the SRAM
    router_v4/mroute4.py, ladder.py                      route, tidy (VIAJOIN=2 WORKERS=1)
    router_v4/snapends.py                                track ends to pad centres
    finish_memcard_pcb.py                                planes, fill

Date: 2026-11-17
"""

import sys

import pcbnew

MM = pcbnew.FromMM


def plane(board, net, layer, name, box):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNetCode(board.GetNetcodeFromNetname(net))
    z.SetZoneName(name)
    z.SetLocalClearance(MM(0.3))
    z.SetMinThickness(MM(0.25))
    z.SetThermalReliefGap(MM(0.5))
    z.SetThermalReliefSpokeWidth(MM(0.5))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    o = z.Outline()
    o.NewOutline()
    x0, y0, x1, y1 = box
    for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        o.Append(x, y)
    board.Add(z)
    return z


def seg(board, a, b, layer, net, width):
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(a)
    t.SetEnd(b)
    t.SetLayer(layer)
    t.SetNetCode(net)
    t.SetWidth(width)
    board.Add(t)


def join_centres(board):
    """The grid router lets a track end, or a surface-mount pad, anywhere under a via's copper.  Give each
    such track end a short piece to the via's centre, and each such pad a piece from the via's centre to
    its own, so every join is centre to centre.  Plane vias have their stubs already."""
    tracks = [t for t in board.GetTracks() if t.Type() == pcbnew.PCB_TRACE_T]
    vias = [t for t in board.GetTracks() if t.Type() == pcbnew.PCB_VIA_T]
    ends, pads = 0, 0
    for v in vias:
        c, r, net = v.GetPosition(), v.GetWidth(pcbnew.F_Cu) // 2, v.GetNetCode()
        if board.FindNet(net).GetNetname() in ("GND", "+5V"):
            continue
        at_centre = set()
        for t in tracks:
            if t.GetNetCode() != net:
                continue
            for p, q in ((t.GetStart(), t.GetEnd()), (t.GetEnd(), t.GetStart())):
                d = (p - c).EuclideanNorm()
                if d == 0:
                    at_centre.add(t.GetLayer())
                elif d < r and (q - c).EuclideanNorm() >= r:
                    seg(board, pcbnew.VECTOR2I(p), pcbnew.VECTOR2I(c), t.GetLayer(), net, t.GetWidth())
                    at_centre.add(t.GetLayer())
                    ends += 1
        for fp in board.GetFootprints():
            for pad in fp.Pads():
                if pad.GetNetCode() != net or pad.GetAttribute() == pcbnew.PAD_ATTRIB_PTH:
                    continue
                layer = pcbnew.F_Cu if pad.IsOnLayer(pcbnew.F_Cu) else pcbnew.B_Cu
                if layer in at_centre or pad.GetPosition() == c:
                    continue
                if pad.GetEffectiveShape(layer).Collide(pcbnew.VECTOR2I(c), r):
                    seg(board, pcbnew.VECTOR2I(c), pad.GetPosition(), layer, net, MM(0.3))
                    pads += 1
    return ends, pads


def main():
    src, dst = sys.argv[1:3]
    board = pcbnew.LoadBoard(src)
    print("joined to via centres: %d track ends, %d pads" % join_centres(board))
    for z in list(board.Zones()):
        board.Remove(z)
    bb = board.GetBoardEdgesBoundingBox()
    box = (bb.GetLeft(), bb.GetTop(), bb.GetRight(), bb.GetBottom())
    zones = [plane(board, "GND", pcbnew.In1_Cu, "GND plane", box), plane(board, "+5V", pcbnew.In2_Cu, "+5V plane", box)]
    tb = board.GetTitleBlock()
    tb.SetComment(0, "PCB PLC-1004.  Placed by gen_kicad_memcard_pcb.py, routed by router_v4 (docs/architecture/MEMCARD.md)")
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    board.Save(dst)
    s = open(dst).read()
    open(dst, "w", newline="\n").write(s)
    for z in zones:
        print("%s: %d filled piece(s) on %s" % (z.GetZoneName(), z.GetFilledPolysList(z.GetLayer()).OutlineCount(),
                                                 board.GetLayerName(z.GetLayer())))
    print("wrote", dst, ":", len(board.GetTracks()), "tracks and vias")


if __name__ == "__main__":
    main()
