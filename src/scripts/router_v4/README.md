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

## Track-length budgets (2026-11-02, branch-097)
The timing model of `docs/timing/TIMING.md` becomes length limits the router honours.
- `budgets.py board.kicad_pcb budgets.json` : every timing path (fetch, operand / X / Y / video / zero-page reads, store
  start, RW, STALL loop, cartridge ROM fetch, data setup, ALU single clock, and the expansion slots J9-J12 against the
  card budget at the fingers of EXPANSION.md "Card timing": SLOTS=1, CARD_EXP / CARD_CTL / CARD_OE / CARD_WE / CARD_DS /
  CARD_DH / CARD_EH; since 2026-11-03 the defaults are the plain AS7C256C-15 SRAM card, 16 / 16 / 8 / 13 / 9 / 2 / 2 ns,
  with /EXPn from I/O decode rev 07 and Q0 on A10; plus the I/O reads `io_line_read`, `io_port_read` and the hold
  `port_sel_hold`) is written with each board track length as a
  variable (6 ps/mm), as a set of linear slack forms, one per alternative path (address bit, data bit, RAM, duty-cycle end).
  Each form must keep `MARGIN` (0.5 ns) at both ends of `DUTY` (0.45,0.53); its lengths share the room in proportion to their
  straight pad-to-pad distance on the current placement (one detour ratio per form), and a length's budget is the smallest
  over all forms. Lengths that help a check (a later capture clock) count at their present value; `FIXED` nets (CLK_E)
  are never budgeted; `MINLEN` carries the CLK_E minimum. It prints each check's slack now and its tightest detour
  ratio, the forms that no routing can meet (ratio < 1: needs placement or logic changes), and the present breaks.
  Run it again after every placement change: the budgets depend on where the parts are.
- `lenbudget.py` : the grid measure (shortest path along the net's copper from pad to pad, x `LENSCALE`=1.02 because the
  grid runs 1-3 % short of `tracklen.py`) and the excess (mm over budget summed over a net's pairs).
- `tracklen.py` : the same measure on the real track geometry (from the timing tool `meas.py`); `score.py` uses it.
- `lenfix.py in out BUDGET=budgets.json BASE=...|NETS=@...` : repair pass. A net over budget is lifted and grown again pin by
  pin, tightest budget first; each pin joins the tree by an A* whose start cells carry their copper distance from the pin
  they are budgeted against (`astar2` in astar.c), so the search minimises driver-to-load length. With `LENRIP=1` a net
  that still breaks is grown ignoring the other routes, the nets in its way are lifted and grown again after it. Kept only
  when the excess drops, nothing opens and no moved net gets longer than its budget.
- `BUDGET=budgets.json` in `mroute4.py` routes the budgeted nets first as critical nets; in `tidy.py` no move is kept that
  makes a budget break worse (also in the via-cost ladder); in `score.py` it lists the pairs over budget.
- `run_wb.bat` with `set BUDGET=budgets.json` runs mroute4 -> lenfix -> tidy -> corner45 -> score -> ladder.
- Bench (2026-11-02, round-4 board `wb4_tidy` from `bench/wb4_results`, budgets from the main board with `U11E=1`):
  lenfix took the over-budget track from 17 pairs / 1659 mm to 3 pairs / 58 mm (ADDR7 U10->U31 +54, STALL_IN +4,
  ADDR13 +0.1) in 14 min on 4 CPU threads, 0 open, 0 collisions; 39.33 -> 40.31 m, 656 -> 706 vias before tidy.
- Finding: without timing fix 4 (U11 pin 1 on CLK_E at X1, `U11E=1`) the /OE reads (fetch, cartridge ROM fetch and
  operand) cannot keep the margin at 53 % duty even with straight traces; budgets.py lists them as INFEASIBLE.
- Nov 3 2026 full main-board route with budgets (U11E=1, CLK_E lead 505.9 mm): 0 open, 0 collisions, 0 over budget,
  510 vias, 41.46 m after snap; real-track min slack addr_hold +0.75 ns, write_pulse +1.05 ns; KiCad 9 DRC clean except
  3 pre-existing J7 GND unconnects.

## Snap track ends (2026-11-03, branch-106)
- `snapends.py in.kicad_pcb out.kicad_pcb` : the grid router ends a track on the first cell inside a pad, up to 1.6 mm
  off the pad centre. snapends adds a straight segment (same width and layer) from every such end to the exact pad
  centre so KiCad can make teardrops; GND/+5V/CLK_E are left alone and an end on a via is only reported. Optional
  `plan.json` (`{"move": [...], "skip": [...]}`, key `layer|net|x_nm|y_nm`) moves or skips single ends, `report.json`
  lists what was done. It imports pcbnew, so it runs under KiCad's python, not the router's.
- `run_wb.bat` runs it last on the `%TAG%_c45` board and every ladder board (`*_c45_snap.kicad_pcb`), with
  `KIPY` (default `C:\Program Files\KiCad\9.0\bin\python.exe`); `SNAP=none` skips it.
- Main board: 1276 ends snapped, KiCad 9 DRC (zones refilled) still clearance 0, timing unchanged.

## Windows (Justin's laptop, RTX 4070)
1. Python 3.10+ with `pip install numpy scipy shapely "cupy-cuda12x[ctk]"` (the [ctk] extra brings the NVRTC headers; no CUDA Toolkit install needed, the NVIDIA driver is enough).
2. The prebuilt `astar.dll` and `pfcpu.dll` (MinGW, static) are in `win/`; no compiler needed (`astar.dll` rebuilt 2026-11-02 with `astar2`).
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
| wb4: + THERMCLR 2 mm (was the swappable board until round 4) | 38.96 m | 656 | clean (`bench/wb4_c45_drc.json`; zones refilled before the check) |
| wb4m: bench without CLK_E, MINLEN=CLK_E:420 | 39.62 m | 656 | CLK_E 201 -> 428.6 mm (detour +33.6, bumps the rest), 0 collisions |

Whole-board tidy A/B on the wb3 raw route: NETPASS=0 693 vias / 39.77 m, NETPASS=1 686 / 39.78 (full 256-net scope).
wb4_c45 was delivered as a ready-to-swap copy of the main board (Justin's GND/+5V/CLK_E copper
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

## Round 4 (2026-11-02, branch-084): the via gap
Goal: close the via gap to Freerouting-first (531) without its extra track. What worked is a **via-cost ladder**: after the
normal tidy, further whole-board tidy rounds (net + chain + pair passes) with a rising via cost and `AGAINST=2`, each starting
from the previous result. `run_wb.bat` now runs it by default (`LADDER=400 800 1600`, `LADDER=none` to skip); each round is
about 2 h on 4 CPU cores. Score scope `NETS=@bench/wb.nets` (BASE prefixes no longer match across rounds).

| wb4 stage | track | vias | detour > 2 | DRC |
|---|---|---|---|---|
| tidy as before (`wb4_tidy.score`, VIA 120) | 38.96 m | 656 | 0 | clean |
| + ladder VIA 400 (`wb4_v400.score`) | 39.54 m | 588 | 0 | |
| + ladder VIA 800 (`wb4_v800.score`, `wb4_v800_results.kicad_pcb.zip`) | 39.98 m | 541 | 0 | clean (`wb4_v800_c45_drc.json`) |
| + ladder VIA 1600 (`wb4_v1600.score`, `wb4_v1600_results.kicad_pcb.zip`) | 40.51 m | 524 | 1 | clean (`wb4_v1600_c45_drc.json`) |
| Freerouting first + v4 finishing | 40.95 m | 531 | | 1 clearance fault |
| Justin's hand layout, same scope | 41.18 m | 946 | | clean |

The VIA 800 board (541 vias, -17.5 % vias for +2.6 % track against wb4, 1.2 m shorter than Justin's with 43 % fewer vias) is
now the project's main board `kicad/placard.kicad_pcb` (Justin adopted it 2026-11-02, zones refilled; the separate
`placard_autorouted.kicad_pcb` copy is gone); the VIA 1600 board is the alternative when vias matter more than the last 0.5 m.

Tried and kept as options only:
- `tidy.py SHOVE=8` (off by default): a chain with a via tries to shove a neighbouring chain's straight run sideways by up to
  8 cells and re-route itself; neighbours are found within `NEIGHMM=1.0` mm. r1: 546 -> 522 vias and -0.4 m in 21 min; whole
  board: 588 -> 584 in 2 h. Not worth its time on the whole board once the ladder has run.
- Fine grid (`GRID=0.0625`, `run_wb_fine.bat`): tidy on the fine grid of a 0.125 route took 6 h for 656 -> 575 vias and left
  32 nets open (chains dropped as redundant); the chain bbox now holds the via disk at any grid, but fine-grid tidy of coarse
  routes stays unsupported. **Bug fixed on the way:** `mroute4.py`'s fast occupancy stamps had their radii in cells for the
  0.125 grid (4.44/6.44/8.44), so on the fine grid every clearance stamp was half size and the first fine-grid whole-board
  route had 2508 clearance collisions; the radii now scale with `GRID` (3-net fine-grid test: 0 collisions). The fine-grid
  whole-board route itself (router at GRID 0.0625 on the laptop GPU) is reported below when it finishes.
