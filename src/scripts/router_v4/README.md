# PLACARD grid router v4 (2026-10-31)

Routes a KiCad board file outside KiCad on a 0.125 mm grid, two signal layers (F.Cu horizontal preferred,
B.Cu vertical preferred, 90-degree moves), with Justin's rules: 1 mm copper-to-outline clearance, nothing
between a mounting hole and the board edge, a net never runs parallel to itself. The board file is never
modified: every tool reads one file and writes another.

## Tools
- `mroute4.py in.kicad_pcb out.kicad_pcb` : negotiated-congestion router. Every open net is routed, in parallel batches,
  against the occupancy of all other nets (PathFinder style); conflicted nets are re-routed with the others blocked;
  what is still open is written out unrouted. `BACKEND=gpu` runs one CUDA block per net (CuPy), `BACKEND=cpu` one
  OpenMP thread per net, `auto` picks the GPU when CuPy finds one.
- `tidy.py in out BASE=base.kicad_pcb` (or `NETS=@out.nets`) : clean-up of the routed copper: every chain is re-routed
  alone and kept only when cheaper (fewer vias / bends / wrong-way track); redundant chains are deleted. `PAIR=1`
  (default) then re-routes every chain that has a via together with a neighbouring chain of another net.
- `corner45.py in out NETS=@out.nets` : 45-degree finishing: 90-degree corners get a chamfer of up to 2 mm where the
  diagonal keeps clearance to every other net, the edge rule and the hole bands (checked on the original copper).
- `patroute.py in out` / `PATTERN=1` in mroute4: lane-style pattern pass (straight, L, Z shapes on the preferred layers,
  shortest connections first, Z middle run packed next to the start pin). Places 25-40 % of the connections; as a warm
  start for the negotiation it was neutral on the benchmark (407 vs 398 vias), so it is off by default.
- `makebench.py board.kicad_pcb bench.kicad_pcb` : whole-board test bench: all tracks and vias except GND/+5V removed
  from a copy of the board (the board file itself is never written to).
- `score.py pcb BASE=base.kicad_pcb` : one report (open nets, track, vias, wrong-way %, diagonal %, detour, rule
  breaks, self-parallel places, clearance collisions, worst nets). `NETS=a,b` scores only those nets.
- `mroute3.py` (v3, single-thread A*, rip-up-and-retry) is kept for finishing leftovers in the container.
- `gridcore.py` shared rasteriser/A*/output; `pfcommon.h` cost rules shared by `pfcpu.c` (CPU) and `pfgpu.cu` (CUDA).

Environment variables: see the docstring at the top of each script (VIA, AGAINST, RING, WIN, ITERS, BATCH, THREADS ...).
Defaults worth knowing in mroute4: `PROT` (never ripped) and `CRIT` (routed first, via cost x2, yield less to congestion)
both default to CLK, CLK_E, STALL_OUT, STALL_IN, RUN, ~{WE}, PIXEL_ENABLE, ~{HSYNC}, ~{VSYNC}; `CHAINRIP=1` makes rip-up
remove only the crossed chains of a neighbour (shove-like) instead of its whole route; `DELTA=1.5` is the GPU
near/far bucket width.

Pipeline for a board: `mroute4.py` -> `tidy.py` -> `corner45.py` -> `score.py`.

## Windows (Justin's laptop, RTX 4070)
1. Python 3.10+ with `pip install numpy scipy shapely "cupy-cuda12x[ctk]"` (the [ctk] extra brings the NVRTC headers; no CUDA Toolkit install needed, the NVIDIA driver is enough).
2. The prebuilt `astar.dll` and `pfcpu.dll` (MinGW, static) are in this folder; no compiler needed.
3. `run_bench.bat` routes the mux benchmark (`r1.kicad_pcb`, 108 nets stripped from the main board) on the GPU
   and scores the result. `set BACKEND=cpu` to compare.

## Linux / container
`gcc -O3 -shared -fPIC -o astar.so astar.c` and `gcc -O3 -fopenmp -shared -fPIC -o pfcpu.so pfcpu.c` (mroute4 builds
pfcpu.so itself when missing). `pip install numpy scipy shapely`; CuPy only for a GPU.
