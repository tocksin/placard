# router_v4: ideas from other routers and the literature (2026-11-08)

Router v4 today: a PathFinder-style negotiated-congestion grid router on two routing layers (F.Cu / B.Cu, inner planes
fixed), one CUDA block per net (delta-stepping near/far buckets), then `tidy.py`, which rips up each chain or whole net and
re-routes it alone, pair moves with a neighbour, and a via-cost ladder (400 -> 800 -> 1600 -> 3200 cells), then `corner45.py`.
The two open problems from rounds 5-6: the route spends most of its 6 h in two late iterations with a handful of
board-spanning nets, and vias stop falling at about 500 on the whole board.

Ranked by expected gain for the effort. "Paper" entries were checked against the publication record; "tool" entries
describe how the tool works from its documentation and source.

## 1. GAMER: one net over the whole GPU (attacks the 55-min iterations)
Paper: S. Lin, J. Liu, E. F. Y. Young, M. D. F. Wong, "GAMER: GPU Accelerated Maze Routing", ICCAD 2021 and IEEE TCAD 2023.
The shortest-path search becomes alternating horizontal and vertical sweeps; each sweep is a parallel prefix-min scan
along every row (column) of the grid, so one net uses every SM instead of one block. 2.7x end-to-end over CUGR, 16-20x on
the maze stage.
For us: v4 runs one block per net, so the late iterations (4-8 long nets left) leave most of the RTX 4070's 46 SMs idle;
`DISJOINT=16` cannot help there (there are not 16 nets to batch). A sweep kernel for nets whose window is above a size
threshold (layers as a third sweep direction with the via cost) would turn those iterations from 55 min into a few
minutes. Bend and wrong-way costs need the state per direction (4 channels), as GAMER does for its turn cost.

## 2. Constrained via minimisation (CVM): layer reassignment with geometry fixed
Papers: Joy and Ciesielski, "Layer assignment for printed circuit boards and integrated circuits", Proc. IEEE 1992 (survey);
Xiong and Kuh, via minimisation for two-layer PCB and VLSI routing; Chang and Cong, extended conflict-continuation graph
(optimal when the graph is a tree, iterative over induced subtrees otherwise, 13-15 % fewer vias on V4R layouts); Chang and Fang,
graph contractability heuristic (38.5 % on Deutsch's difficult example).
Two-layer CVM is the classic case (Pinter, Hsu): split every routed net into pieces at possible via points, build a graph
whose edges say "same layer" (continuation, no via) or "different layers" (crossing or clearance conflict with another net),
and the via count is the number of cut continuation edges: a max-cut / signed-graph problem that is exact on planar instances
and good with local search otherwise.
For us: `tidy.py` already finds single-piece flips (a chain re-routed alone finds the same XY on the other layer if it is
free) and some two-net swaps (pair moves), but not a chain of flips across 3+ nets that only works together. A CVM pass after
the ladder keeps track length exactly (no geometry change) and works on all nets at once. SMD pads pin their piece to F.Cu;
through-hole pads and existing vias are free points. It is CPU-only and runs on the finished board, so it can be measured
against the 3200 rung without a route.

**Measured (`cvm.py`, round 6 board at VIA 3200, 494 vias): 0 vias removed.** Only 134 runs have a via at both ends (the other
vias join pads, junctions or fanouts), and all 134 are blocked on the other layer: 120 by 3 or more other nets, 8 by 2, 6 by
1, and those 6 had no legal partner run. After the tidy ladder the layers are too full for geometry-preserving flips, so
CVM only helps right after the router (10 -> 2 vias on a 3-net test, which the tidy also achieves). Deprioritised; the widened
pair search of the tidy (`NEIGH=8 NEIGHMM=2.5`) is what still removed vias (494 -> 478).

## 3. Negotiation tuning from global routers (NTHU-Route 2.0, FastRoute 4.0, CUGR)
Papers: McMurchie and Ebeling, "PathFinder", FPGA 1995 (what v4 is); Chang, Lee, Wang, NTHU-Route 2.0, ICCAD 2008 / TCAD 2010;
Xu, Zhang, Chu, FastRoute 4.0 (via-aware), ASP-DAC 2009; Liu et al., CUGR, DAC 2020.
- History cost that grows only on cells that stay congested over iterations, and a present-cost factor that rises per
  iteration (v4 has PRES0/PRESF/PRESMAX; NTHU adds a bounded history term and ripping only nets through congested cells).
- Re-route only the nets that touch an overflow cell in the late iterations, and grow their search box gradually
  (NTHU's adaptive bounding box) instead of a board-sized window. This alone shrinks the late searches GAMER would speed up.
- Via-aware cost in the negotiation itself (FastRoute 4.0 "3-bend + via-aware" routing): v4 negotiates at VIA 240 and leaves
  via reduction to the tidy; round 5 found ramping VIA inside the router worse (`VIAEND`), so this is low priority.

## 4. Steiner topology for multi-pin nets (FLUTE)
Paper: Chu and Wong, "FLUTE", IEEE TCAD 2008 (fast rectilinear Steiner minimal trees from lookup tables).
v4 and the tidy's net pass grow a tree by joining the nearest component each step (Prim-like). Routing towards FLUTE's
Steiner points (or using its tree to order the connections) gives shorter trees for 4+ pin nets such as the data and
address buses (DATABUS0-7 are the longest nets, 0.8-0.9 m each). Gain is track length, not vias.

## 5. Push-and-shove and walkaround (KiCad PNS router, Freerouting)
Tools: KiCad's interactive router (push-and-shove, walkaround, via dragging) and Freerouting (Specctra-style batch router:
fanout, autoroute passes with rip-up, then an optimisation pass that re-routes each connection).
Freerouting's optimisation pass is what the tidy ladder already does (rip one connection, re-route with the rest fixed,
keep it when cheaper). Shove-based moves were tried (`SHOVE=8`, round 4: 4 vias in 2 h on the whole board); on a grid they
are expensive. Not a priority unless done on segments (gridless) rather than cells.

## 6. Any-angle and topological routing (Theta*, SURF / rubber-band, TopoR)
Papers: Nash, Daniel, Koenig, Felner, "Theta*: any-angle path planning on grids", AAAI 2007; Dai, Dayan, Staepelaere,
rubber-band routing (SURF), DAC 1991. Tool: TopoR (topological, any-angle router).
v4 routes in 90 degrees and `corner45.py` chamfers afterwards (2-3 % of the track ends diagonal). Theta*-style line-of-sight
parent links would make 45-degree runs part of the search (shorter track, fewer cells), and rubber-band routing keeps
topology and lets geometry relax, which is the gridless version of the tidy. Larger rewrite; length gain, not vias.

## 7. Search speed-ups that keep optimality
- Delta-stepping (Meyer and Sanders, J. Algorithms 2003) is what the GPU kernel uses; a DELTA sweep on the late iterations is free to try.
- Bidirectional A* for two-pin connections, and jump-point style pruning on uniform-cost stretches of the grid (the cost
  field is not uniform near copper, so only the open board areas benefit).

## Suggested round 7
1. Late-iteration fix in the router: only nets on overflow cells, NTHU adaptive boxes, then a GAMER sweep kernel for the few
   board-spanning nets.
2. Keep widening the tidy's pair moves (more neighbours, then moves of three chains), now that the streaming pool makes them affordable.
3. FLUTE-guided trees in the tidy net pass for the bus nets.
