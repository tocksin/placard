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

## Benchmark, round 2 (2026-11-01, branch-080: GPU near/far frontier, batch 4 + in-batch repair, chain-level rip-up,
## tidy pair pass, corner45)
r1 (108 mux nets; scope grows by a few nets when the rip-up pulls fixed nets in), after tidy + corner45:

| run | settings | track | vias | router time |
|---|---|---|---|---|
| gpu5 (`bench_gpu5*`) | GPU, BATCH=4, VIA=120 | 26.25 m | 570 (110 nets) | 7.7 min |
| cpulap (`bench_cpulap*`) | CPU 4 threads on the laptop | 27.86 m | 609 (112) | 7.5 min |
| q200 | GPU, BATCH=2, ITERS=60, VIA=200 | 28.26 m | 621 (111) | 15 min |
| q300 | GPU, BATCH=2, ITERS=60, VIA=300 | 29.18 m | 584 (118) | 24 min |
| gpu6 | GPU, BATCH=32 + SEQFIX | 29.39 m | 686 (117) | 9.5 min |
| gpu3 / gpu4 | GPU, BATCH=32 / 8, no SEQFIX | 29.05 / 29.39 m | 669 / 671 | 8 min |
| round 1 best (CPU + tidy) | | 27.11 m | 588 (108) | 25 min |

Whole board (`run_wb.bat`, bench/wb.kicad_pcb.zip: Justin's finished board with all signal copper removed, 256 nets):

| | track | vias | KiCad DRC |
|---|---|---|---|
| Justin's hand layout (`bench/wb_reference_justin.score`) | 41.85 m | 956 | clean |
| router GPU BATCH=4, raw (`wb_gpu.score`) | 39.99 m | 689 | - |
| + tidy + corner45 (`wb_gpu_tidy.score`, `bench/wb_gpu_c45b_drc.kicad_pcb.zip`) | 39.44 m | 662 | 0 unconnected, 0 clearance; 14 NPTH hole-clearance at 0.26-0.29 mm (rule 0.30; router now keeps 0.32) |

Lessons: batch size decides convergence (batch 4 best; 32 never settles even with SEQFIX); a higher via cost trades
length for vias with no net gain; the GPU near/far frontier makes the big nets cheap (11 s instead of 2181 s);
the pattern/lane warm start is neutral. Router time is for the laptop RTX 4070; tidy adds 6-8 min, corner45 seconds.

## Round 3 (2026-11-01, branch-081): whole-net polish, minimum length, thermal via keep-out
- `tidy.py NETPASS=1` (default): before the chain passes every net is lifted entirely and re-routed from scratch
  against everything else (largest component first, nearest component each step); kept when the whole net is
  cheaper. r1 A/B on the same raw route: 511 -> 486 vias and -2.3 % track with the net pass.
- `meander.py in out NET:min_mm[,..]` and `MINLEN=CLK_E:420` in the bench scripts: a delay net is routed normally,
  then trombone bumps are added on its straight runs in free space (clearance and edge checked on the grid) until
  the minimum is reached. Runs last so nothing shortens it again. Test: CLK_E 202 -> 421 mm with 0 collisions.
- `rules.THERMCLR=2.0`: no via centre within 2 mm of a GND/+5V through-hole pad; a via there cuts the inner plane's
  thermal spokes (KiCad `starved_thermal`, seen once on wb3 at U25-20).
- `makebench.py` keeps CLK_E by default (Justin's 458 mm delay lead); the whole-board bench is therefore 255 nets.
- corner45 LMAX 4 or 8 mm instead of 2: no gain (legs are short), left at 2.

Whole board round 3 (`bench/wb3_*`, laptop GPU, 35 min router + 27 min tidy): 39.12 m / 676 vias after tidy + corner45,
0 open, 0 collisions, KiCad DRC 0 clearance / 0 unconnected / 1 starved thermal (fixed by THERMCLR for the next run).
Justin's layout without CLK_E for the same scope: 41.18 m / 946 vias.

### Round 3 results (laptop RTX 4070, `bench/wb3_*`, `bench/wb4_*`, `bench/wb4m_*`)

| | track | vias | KiCad 9 DRC |
|---|---|---|---|
| Justin's layout, same 255-net scope (CLK_E excluded) | 41.18 m | 946 | clean |
| wb3: net pass, no thermal keep-out | 39.12 m | 676 | 0 clearance, 0 unconnected, 1 starved thermal (U25-20) |
| wb4: + THERMCLR 2 mm (`kicad/placard_autorouted.kicad_pcb`) | 38.96 m | 656 | clean (`bench/wb4_c45_drc.json`; zones refilled before the check) |
| wb4m: bench without CLK_E, MINLEN=CLK_E:420 | 39.62 m | 656 | CLK_E 201 -> 428.6 mm (detour +33.6, bumps the rest), 0 collisions |

Whole-board tidy A/B on the wb3 raw route: NETPASS=0 693 vias / 39.77 m, NETPASS=1 686 / 39.78 (full 256-net scope).
`kicad/placard_autorouted.kicad_pcb` is wb4_c45 as a ready-to-swap copy of the main board (Justin's GND/+5V/CLK_E copper
kept, every other net autorouted); it is not the project's board file.

## Freerouting on the whole-board bench (2026-11-01, branch-082)
Same bench (`bench/wb.kicad_pcb.zip`, GND/+5V/CLK_E protected), exported with `PROTECT=1 python dsn.py wb.kicad_pcb wb.dsn 0.3 0.25 0.8 0.4 0.5 "" planes`
(`bench/wb_for_freerouting.dsn`), Freerouting 2.1.0 on Justin's laptop, 40 passes, 1 thread, 72 min; SES merged with `sesnew.py`
(`bench/wb_fr2.ses`, `bench/wb_fr2_results.kicad_pcb.zip`). Freerouting 1.9.0 routes nothing on this board (exits after 8 s).
Pitfall fixed on the way: `dsn.py` used to add the cartridge finger-tab keepout (`tab_y=137`) unconditionally, which on the main
board blanketed the whole board; it is now opt-in (`TAB=137`).

| | open | track | vias | diagonal | clearance faults |
|---|---|---|---|---|---|
| Freerouting 2.1.0, 40 passes (`wb_fr2.score`) | 20 nets / 23 connections | 38.59 m (incomplete) | 445 | 18.6 % | 1 spot (DATABUS0/DATABUS5 at 124,81, from its multi-threaded optimizer) |
| + router v4 finishing the 20 open nets, 3 min (`wb_fr2_fin.score`) | 0 | 40.95 m | 531 | 17.5 % | same spot |
| router v4 alone, wb4 (`wb4_tidy.score`, DRC clean) | 0 | 38.96 m | 656 | 2.3 % | 0 |
| Justin's hand layout, same scope | 0 | 41.18 m | 946 | 14 % | 0 |

Freerouting spends 19 % fewer vias than v4 but 5 % more track once its leftovers are closed, does not finish on its own, leaves a
clearance fault, and routes a fifth of its length diagonally. v4 is complete, DRC clean and shorter; its remaining gap is vias.

### Freerouting as an optimiser over the v4 board (2026-11-02, branch-083): no gain
`bench/wb4_for_freerouting.dsn` = the wb4 board with only GND/+5V/CLK_E protected (`PROTNETS=GND,+5V,CLK_E python dsn.py ...`),
everything else `(type route)`. Freerouting 2.1.0 did not optimise the existing wiring: it ripped it up and ran 40 full passes
(pass 1 took 20 min, stuck at "12 unrouted" from pass 4; its optimiser step ran 0.26 s on 31 threads despite -mt 1). The SES
merged onto the stripped bench (`bench/wb4_fr.score`): 0 open by our connectivity check, 41.51 m / 674 vias, 69 self-parallel
places, 3.7 % diagonal: worse than wb4 (38.96 m / 656) on every count. The only combination that beats v4 on vias is
Freerouting first and v4 closing its leftovers (531 vias, +2 m, one clearance fault).
