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

## Round 5 (2026-11-06, branch-127): fine grid, tidy speed, what did not help
Justin's priority is the algorithms (measured on the benchmarks), not the current board. The bench is r1 (mux region,
`NETS=@c_r1.kicad_pcb.nets`, 4 CPU cores in the container) and the whole board on the laptop GPU (`bench/wbf_*`).

**Fine grid is the real win.** The router on `GRID=0.0625` (`VIA=240`, same mm as 120 on the coarse grid) finds a much better
raw route because 0.3 mm tracks can pass between pads and vias that the 0.125 grid rounds shut:

| r1 | track | vias (scope / board) | detour > 2 | router time |
|---|---|---|---|---|
| coarse raw (GRID 0.125) | 30.42 m | 730 / 882 | 8 | 13 min |
| coarse + ladder 400 / 800 / 1600 (`l400`..`l1600`) | 28.05 / 28.06 / 28.2 m | 514 / 506 / 502 | 2 | +~35 min per rung |
| fine raw (GRID 0.0625) | 28.48 m | 660 / 812 | 4 | 90 min |
| fine + ladder 400 / 800 / 1600 (`fl400`..`fl1600`) | 26.23 / 26.43 / 26.76 m | 514 / 494 / 483 | 0 | +55 / 45 / 13 min (tidy after the speed-ups) |

So the raw fine route is already 2 m shorter than the raw coarse route with 70 fewer vias, before any tidy, and after the
ladder the fine grid ends 1.4 m shorter with 19 fewer vias (483 vs 502) and no detour over 2 (coarse: 2). The price is time: the fine grid has 4x the cells, so the router takes 7x longer on the CPU and every
tidy round on the whole board took hours. That is what the speed-ups below are for.

**Tidy speed-ups (`gridcore.py`, `tidy.py`), same output:** `components()` labels only the window around the net's copper
instead of the full grid; `astar()` keeps persistent full-size buffers and fills only the search window (a custom via-cost
array is applied in its window and reset afterwards); the via keep-out disk is stamped sparsely at via cells instead of a
full-grid dilation. On a 12-net fine-grid tidy test 199 -> 87 s with identical segments and vias; the coarse-grid test is
identical too. `ASTARCHECK=1` recomputes every search the old way and prints `ASTARCHECK MISMATCH` on any difference.
Remaining hot spots in a profile: the window copies for very large windows, `contains_xy` rasterisation at load, and the
full-grid `blocked()` / own-ring passes.

**Fixed:** `corner45.py` cut a 45-degree corner across a same-net T junction on one of its legs and opened net Y2 on r1
(the junction segment then hung in the air). A corner is now kept when the cut leg pieces carry another segment of the
same net (reported as `kept for a junction on the leg`).

**No gain (tried on r1, kept as options or dropped):**
- `VIAEND`/`VIARAMP` in `mroute4.py` (via cost ramped up over the rip-up iterations, e.g. 120 -> 400): 483 vias raw, worse
  than the ladder from a cheap-via route. Kept as an option, off by default.
- Router `AGAINST=2`: 393 vias raw but the same after the ladder (380 vs 514 -> 380 at VIA 400); `AGAINST=1.5`: 742 vias.
- `DIAG=1` in the router: 424 vias, longer track; the corner45 pass already gives the 45-degree corners.
- Tidy `AGAINST=1.5` on the ladder: no better than 2.
- `SHOVE=8` on the whole board (round 4): 4 vias in 2 h.

**Parallel tidy (`WORKERS=N`, default min(cpus, 8), capped by free memory at ~230 bytes per grid cell per worker):** every
pass is split over N worker processes, each with its own copy of the grid, tidying a spatially contiguous group of nets
(stripes along x, then y, alternating per pass; neighbours for pair moves come from the whole board). The main process
accepts each worker's changes as transactions (a pair move is one transaction) when the new copper is still free of all other
copper, drops a transaction that collides with another worker's accepted change (retried in an extra pass, up to twice the
pass count), and sends the accepted state to every worker. `WORKERS=1` is the sequential pass, bit-for-bit as before.
r1 coarse ladder with 3 workers (4-core container): 520 / 502 / 484 vias for 27.85 / 28.08 / 27.95 m in 25 min against
514 / 506 / 502 vias and 28.2 m in about 95 min sequentially (the conflict-retry passes find a few more moves); the first
attempt that merged net by net lost the pair moves across workers (569 vias). The result is not identical to the sequential
pass (moves happen in another order) but of the same kind. A fine-grid whole-board worker needs about 3.7 GB, so on Justin's
laptop (24 cores but 15.7 GB, 8 GB free) the cap gave WORKERS 8 -> 1 and the whole-board ladder below ran sequentially;
slimmer workers (read-only grid arrays in shared memory, no board text or shapes in the workers) are the next step.

Whole-board fine grid (`run_wb_fine.bat`: router VIA 240, tidy VIA 400 + `AGAINST=2` as the first ladder rung, then
`LADDER=800 1600`, corner45, score and snap after each rung; `STAGE=route` / `STAGE=tidy` run the two halves separately):
the first run on the laptop filled the 8 GB card by iteration 2 (the cupy pool kept every launch's buffers; iterations went
from 19 to 85 min) and was stopped; `mroute4.py` now frees the pool after every launch (rerun: peak 7.0 GB). The rerun
(laptop RTX 4070, `bench/wbf_gpu*`; same wb bench as round 4, which is the board before the expansion redesign, so these are
benchmark boards, not swappable into the project):

| whole board, fine grid | track | vias (scope) | detour > 2 | time | coarse grid (round 4) |
|---|---|---|---|---|---|
| router (`wbf_gpu.score`) | 39.33 m | 645 | 1 | 6.0 h | 39.44 m / 685 |
| + tidy VIA 400 (`wbf_gpu_tidy.score`, `wbf_results.kicad_pcb.zip`) | 38.89 m | 572 | 1 | 2.1 h | 39.54 m / 588 |
| + VIA 800 (`wbf_gpu_v800.score`, `wbf_v800_results.kicad_pcb.zip`) | 39.38 m | 531 | 2 | 2.1 h | 39.98 m / 541 |
| + VIA 1600 (`wbf_gpu_v1600.score`, `wbf_v1600_results.kicad_pcb.zip`) | 39.98 m | 506 | 3 | 1.8 h | 40.51 m / 524 |

The fine grid ends 0.5 m shorter with 18 fewer vias than the coarse ladder (or, at the coarse VIA 800 length of 39.98 m,
with 35 fewer vias). KiCad 9 DRC on the VIA 1600 board (zones refilled, `wbf_v1600_c45_drc.json`): 0 clearance faults,
0 unconnected (the only entries are the library-path notes of the container). The router's 6 h are dominated by two
iterations of 55 min (12 and 16) when only a handful of board-spanning nets were left: one CUDA block per net on a
board-sized window; splitting those searches over several blocks, or filling each launch with spatially disjoint nets, is
the other next step.

## Round 6 (2026-11-07, branch-132): slim streaming tidy workers, faster searches
Round 5 left two problems: a fine-grid tidy worker needed ~3.7 GB (the laptop ran the whole-board ladder with one
worker), and the parallel pass lost quality. All numbers are the fine-grid r1 bench (`f_r1`, 116 nets, 4-core container).

**Slim workers (`Grid.share()` / `Grid.attach()`):** the read-only grid arrays (fixed copper, pad and edge masks, cost field)
live once in `multiprocessing.shared_memory`; a worker keeps only its own occupancy and routes, no board text, items or
writer, and the A* core gets window-sized copies (`blocked()`, `own_ring()`, the component masks and `polish_net` are all
windowed). Measured on the fine grid (16.3 M cells): 0.45-0.7 GB private per worker plus 0.43 GB shared once, so the cap is
now ~40 bytes per cell per worker and the laptop (8 GB free) can run 7-8 workers.

**Why the striped pass lost quality:** a third of the moves of every pass were rejected (22 of 61 in the first net pass),
because every worker built on the state at the start of the pass and the long r1 nets cross all stripes; the rejected nets
were retried on a board that had moved on, and lost again. The first fine-grid 3-worker rung ended with 426 raw vias
against 384 sequentially. Fixed by replacing the stripes with a **streaming pool**: the main process hands out one net at a
time in the sequential order (skipping ahead past nets whose windows overlap a net in flight), validates each returned move
on its own grid (new copper free, and the move must not build on a net it had not yet seen updated: per-net versions),
and streams every accepted move to all workers immediately; a rejected move is retried later in the pass. Rejections fell
to 4 of 66, and the pass follows the sequential one closely (same 66 nets improved in the first net pass).

**Faster searches (sequential too):** the A* goal-distance heuristic is now a distance transform on 4x4-cell blocks,
interpolated bilinearly and lowered by the block diagonal (`HCOARSE=4`; the per-cell transform was 25 % of a net pass).
The first version used the block value directly, which is admissible but not consistent, and the C core never reopens a
closed cell, so paths came out suboptimal (520 vias instead of 514 on the first rung); the interpolated one keeps every path
optimal and the sequential rung is cell-for-cell the round 5 result. `components()` caches the bbox of each net's fixed copper
and labels only the window, `polish_net` counts component cells with one `bincount` and ignores copper outside its search
window (nets with an unconnected island elsewhere were never polished before), and the C-core inputs are bool views
instead of converted copies. A sequential fine-grid net pass: 237 s (round 5) -> 191 s.

| fine r1, VIA 400 / 800 / 1600 ladder | track | vias (scope) | detour > 2 | tidy time |
|---|---|---|---|---|
| round 5 sequential (`fl*`) | 26.23 / 26.43 / 26.76 m | 514 / 494 / 483 | 0 | 55 + 45 + 13 min |
| round 5 stripes, 3 workers, first rung only (`pf400`) | 27.27 m | 556 | 3 | 46 min |
| round 6 sequential, first rung (`sh400`) | 26.23 m | 514 | 0 | 38 min |
| round 6 streaming, 3 workers (`ph*`, `bench/r1_fine6_*`) | 26.44 / 26.66 / 26.95 m | 489 / 471 / 460 | 1 | 16 + 12 + 12 min |

The streaming ladder ends with 23 fewer vias than round 5 (460 vs 483) for 0.19 m more track, in 41 min instead of 113: the
retries after a rejected move act like the extra passes of round 5's striped ladder and find more pair moves than the
sequential pass does. `WORKERS=1` is the sequential pass of the new code. Best r1 so far: `bench/r1_fine6_v1600_results.kicad_pcb.zip`.

**Router disjoint batching (`DISJOINT=16`, off by default):** a launch holds up to 16 nets whose boxes (fixed-copper bbox +
`DJPAD=8` mm) do not overlap, under a `GPUMEM=4` GB window budget, so batch-mates cannot collide and the GPU keeps 16 blocks
busy instead of 4 in the late iterations that re-route every net (iterations 12 and 16 of the whole-board fine route took
55 min each). On the CPU (3 threads) the r1 coarse route ends at 739 vias / 30.88 m in 21 min against 730 / 30.42 m with
plain batches (both still 300-400 overlap cells at iteration 29, so the negotiation converges about the same); the GPU
timing is still to be measured on the laptop. Quality first, so it stays off until that run shows it is at least as good.

## Round 7 (2026-11-07/08, branch-134): what did not help in the tidy
Three ideas tried on the fine r1 bench, all kept as options, all off by default:

- **Window rip-up (`REGION=20`)**: cut every chain at the edge of a 20 x 20 mm window, lift the copper inside, re-route
  the nets together. One-after-another re-routing (two orders) walls nets in inside the bus regions (24-28 nets through
  one window); reserving every net's entry points does not help; a window negotiation (pressure x overlap + history,
  mroute4's scheme, 12-40 rounds, all nets every 4th round) still leaves 9-13 nets overlapping in the dense windows and
  converges only in sparse ones, where it finds nothing cheaper. The entry points pin the nets to the old crossing order,
  so the only legal solutions are the old one and its neighbours, which the chain and pair passes already explore.
- **Multi-root whole-net polish (`POLSTARTS=3`)**: growing the tree from the next-largest pieces too and keeping the
  cheapest: 69 nets improved for a gain of 30203 against 66 / 30909 with one root, in twice the time.
- **Branching polish (`POLBRANCH=1`)**: a polish path may start from or cross an earlier path of the same polish (the
  net's own clearance is lifted during the search). The net pass gets much stronger (81 nets improved, 442 vias instead
  of 460, gain 46844 instead of 30909, and 10 % faster), but the chain and pair passes find less afterwards and the rung
  ends at the same cost: sequential VIA 400 rung 372 vias / 26.53 m against 384 / 26.23 m; the 3-worker ladder
  506 / 478 / 469 vias, 26.48 / 26.59 / 26.84 m against round 6's 489 / 471 / 460 (26.44 / 26.66 / 26.95 m) and a
  second run of the round 6 code, 494 / 472 / 449 vias, 26.40 / 26.31 / 26.46 m. The streaming pool's run-to-run
  spread is therefore about 10 vias (the order in which workers finish decides the move order), which is larger than
  any of the three ideas.

So round 7 adds options but no algorithmic gain. The best fine r1 board is now the second round 6 run:
**449 vias / 26.46 m** (`bench/r1_fine7_*`, 43 min with 3 workers) against round 5's 483 / 26.76 m. A cheap way to use the spread is to run the ladder two or three times and keep
the best, which the GPU makes affordable on the whole board. The whole-board round 6 runs on the laptop
(`bench/wbf6_*`, branch-137) are reported there.


## Round 8 (2026-11-08, branch-135, overnight): best-of-N ladder, what the router's all-net iterations cost
Justin's direction for the night: keep improving the metrics unattended, and look at other routers and the
pathfinding literature (the survey is `research.md`, written on the laptop together with the whole-board round 6
results, branch-137; the laptop's constrained-via-minimisation pass `cvm.py` found nothing left to flip after the
tidy ladder: all 134 flippable runs on the final whole board are blocked on the other layer).

- **`ladder.py`** runs the via-cost ladder as a driver: every rung is tried `TRIES` times (`SEED=k` jitters the tidy's
  net order; the streaming pool adds its own spread), each try is chamfered and scored, and the cheapest try
  (`track_m*1000 + VIA*GRID*vias`, the tidy's own objective) feeds the next rung. Finished tries are reused when the
  ladder is restarted. Fine r1, `TRIES=3`, 3 workers (`bench/r1_fine8_*`):
  rung 400 tries 494 / 509 / 501 vias (26.40 / 26.21 / 26.18 m, the cost picks 501 / 26.18), rung 800 all three
  tries 478 / 26.27, rung 1600 all three 473 / 26.40, rung 3200 465 / 469 / 465 (26.66 / 26.61 / 26.67 m); 2.6 h in all.
  So the best of three per rung ends at 473 vias / 26.40 m after 1600, which does not beat the single lucky round 6
  run (449 / 26.46 m, `bench/r1_fine7_*`): once a rung's start board is fixed, the later rungs converge to the same
  moves whatever the seed, so the spread is in the first rung and it is luck, not search. The jitter itself changes
  little (the net and chain passes converge to the same moves). A fourth rung at VIA 3200 saves 8 more vias for
  0.26 m. Verdict: not worth 3x the time; run the plain ladder, and re-run only the first rung if a better start is wanted.
  The same VIA 3200 rung on the best round 6 board (449 / 26.46 m) gives the best fine r1 board so far:
  **438 vias / 26.77 m** (`bench/r1_fine8_best_v3200*`, 13 min, detour mean 1.09, DATABUS5 at 1.4).
- **Wide pair search as a last rung** (found on the laptop's whole-board run, `ladder.py WIDE=1`: `NEIGH=8 NEIGHMM=2.5
  NETPASS=0` at the last VIA): the pair pass tries 8 neighbours within 2.5 mm instead of 3 within 1 mm. Whole board
  494 -> 478 vias for +0.07 m (92 min on one worker while the GPU held the memory); fine r1 438 -> **431 vias / 26.75 m**
  (`bench/r1_fine8_wide*`, 19 min) and the `ALLEVERY=0` board 447 -> 434 / 27.06 m. Pair passes take 3x longer, so it
  is a final rung, not the default for the whole ladder.
- **Router `ALLEVERY`** (default 4: every 4th iteration re-routes every net, not only the conflicted ones). `ALLEVERY=0`
  on the coarse r1 route, single CPU thread, same code: raw 670 vias / 30.09 m in 18 min against 743 / 30.84 m in
  19 min; after an identical coarse ladder (2 workers, one try per rung) 525 / 515 / 514 vias, 28.58 / 28.85 / 28.90 m
  against 549 / 524 / 516 vias, 29.22 / 29.40 / 29.56 m. Fine r1 route (`VIA=240`, 4 threads, `bench/r1_fine8_a0_*`):
  raw 592 vias / 27.52 m in 72 min against 660 / 28.48 m in 90 min, and the round 6 ladder on it
  478 / 462 / 450 / 447 vias, 26.58 / 26.48 / 26.75 / 27.04 m against 489 / 471 / 460 on the old route (26.44 / 26.66 /
  26.95 m). Fewer vias and shorter track at every rung, three times out of three, and on the fine whole board it also
  drops the two 55-minute all-net iterations. The all-net iterations re-route the conflict-free nets under a high
  pressure cost, which makes them detour around copper they were not colliding with. **`ALLEVERY=0` is now the
  default** (`ALLEVERY=4` restores the old behaviour); the whole-board confirmation is the next laptop run.
- **Router `WINLATE`** (search window pad shrinks to `WINLATE` mm from iteration `LATEFROM`, FastRoute-style): bad,
  `WINLATE=10` leaves 9 nets unrouted and 913 overlap cells on the coarse r1. Off.

Whole board, round 6 tidy on round 5's fine route (laptop, 1-3 workers, `bench/wbf6_r5_*`, KiCad 9 DRC clean):
400 / 800 / 1600 / 3200 -> 571 / 533 / 504 / 494 vias, 38.87 / 39.33 / 40.01 / 40.59 m in 3.1 h for all four rungs
(round 5: 572 / 531 / 506 in about 6 h for three). The 3200 rung buys 10 vias for 0.58 m; DATABUS0/1 then run at a
1.4 detour for 5 vias each, so 3200 is about where vias stop paying.

### Round 6 on the whole board (laptop, 2026-11-07/08, `bench/wbf6_*`)
Same wb bench as rounds 4-5. Two runs: the round 6 tidy on round 5's own route (`wbf6_r5`, a copy of `wbf_gpu.kicad_pcb`), and a new
GPU route with `DISJOINT=16` followed by the tidy (`wbf6_dj`). Both ladders got a fourth rung (VIA 3200) and then a wider
pair rung (`VIA=3200 NEIGH=8 NEIGHMM=2.5 NETPASS=0`). Track / vias in scope after corner45:

| | router | VIA 400 | VIA 800 | VIA 1600 | VIA 3200 | wider pairs |
|---|---|---|---|---|---|---|
| round 5 | 39.33 m / 645 | 38.89 / 572 | 39.38 / 531 | 39.98 / 506 | | |
| round 6 tidy, round 5 route (`wbf6_r5`) | as round 5 | 38.87 / 571 | 39.33 / 533 | 40.01 / 504 | 40.59 / 494 | 40.66 / 478 |
| round 6 tidy, DISJOINT route (`wbf6_dj`) | 39.09 / 664 | 38.62 / 591 | 38.90 / 550 | 39.83 / 510 | 40.11 / 504 | 40.17 / 484 |
| tidy time, min (workers), `wbf6_r5` | | 37.5 (2) | 50.1 (2) | 74.5 (1) | 20.6 (3) | 92.5 (1) |
| tidy time, min (workers), `wbf6_dj` | | 14.0 (7) | 12.4 (6) | 15.1 (6) | 12.2 (6) | 55.8 (4) |

All boards: 0 open nets, 0 collisions. KiCad 9 DRC with zones refilled on `wbf6_r5_v3200`, `wbf6_r5_n8`, `wbf6_dj_v3200`
and `wbf6_dj_n8` (`bench/*_c45_drc.json`): 0 unconnected, 0 clearance or copper faults (only the library-path notes).
- **Tidy speed:** with the memory free the four rungs of `wbf6_dj` took 54 min; round 5 took 6 h for three. The `wbf6_r5` run shared
  RAM with the route, so the worker cap gave only 1-3 workers.
- **Wider pair rung:** the best new lever, -16 vias for +0.07 m on `wbf6_r5`, -20 vias for +0.06 m on `wbf6_dj`.
  Best board: `bench/wbf6_r5_n8_results.kicad_pcb.zip`, 478 vias, 40.66 m. Shortest of similar via count: `wbf6_dj_n8`, 484 vias, 40.17 m.
- **DISJOINT=16 on the GPU:** the full re-route iterations (12, 16) took 1350 / 1340 s instead of 3321 / 3173 s, but the route was not
  faster overall (6.3 h vs 6.0 h: all 30 iterations ran, full re-routes came every fourth iteration, early iterations shared the
  machine with the CPU tidy) and left more raw vias (664 vs 645). The two routes differ by no more than run-to-run noise after the ladder.
  It stays off by default.
- **Layer flips (`cvm.py`):** 0 vias removed on the finished board; see `research.md`, which also reviews other routers and papers.

## Round 9 (2026-11-08, branch-138/139): what Freerouting's source suggested
`research.md` section 5 now describes Freerouting from its source (shape-based A*, via cost 50 x radius = our router's 15 mm,
rip-up 100 x pass divided by the victim's detour, an optimiser that tries every move and commits only the best, pull-tight
with via sliding). Two of its ideas tested on the fine r1 bench (`ALLEVERY=0` route, `bench/r1_fine8_a0_route.score`):

- **Commit-by-gain tidy passes (`BEST=1`)**: every net's move is proposed on the pass-start state, then the proposals are
  committed in order of gain, each validated against the ones before it (a conflicting proposal waits for the next pass).
  Ladder 400 / 800 / 1600 / 3200 + wide rung: **472 / 457 / 439 / 437 -> 423 vias, 26.44 / 26.31 / 26.66 / 26.79 -> 26.73 m**
  against the streaming pool's 478 / 462 / 450 / 447 -> 434 vias (26.58 / 26.48 / 26.75 / 27.04 -> 27.06 m) on the same
  route: fewer vias at every rung and shorter track, in 93 min instead of 70 (`bench/r1_fine9_best_*`). The best fine r1
  board is now **423 vias / 26.73 m** (round 5: 483 / 26.76; Freerouting 730 / 30.4). A second run gave the identical
  472 / 457 / 439 / 437 -> 423 board: the proposals are evaluated on the same pass-start state, so the result no longer
  depends on which worker finishes first (the streaming pool's ~10-via run-to-run spread is gone). **`BEST=1` is now the
  default** (`BEST=0` = the streaming pool).
- **Diagonal moves (`DIAG`)**, one VIA 400 rung on the same route: orthogonal 478 vias / 26.58 m; diagonals anywhere
  (`DIAG=1`) 463 / 25.89 m; diagonals only with 8 free cells beside the step (`DIAG=9`, Justin's rule: back out of
  diagonals in tight spots) 475 / 26.00 m. Most of the via saving comes from diagonals in the tight spots, which is
  harmless in the tidy (everything is already routed) but is what the rule should prevent in the router's own search.
  **Diagonal copper is now re-routable**: `gridcore.py` reads exact 45-degree on-grid segments as chain members (before,
  any non-orthogonal segment was fixed copper on re-read), so the later rungs can move what an earlier `DIAG` rung laid.
  **Full `DIAG=1` ladder** with the `BEST=1` tidy on the same route: 462 / 448 / 442 / 437 -> wide **424 vias / 26.34 m**
  (25.72 / 25.84 / 25.86 / 26.26 m), 0 collisions, 0 edge hits, no detour over 2x, in 72 min, against the orthogonal
  472 / 457 / 439 / 437 -> 423 / 26.73 m (93 min; `bench/r1_fine9_diag_*`). Same via count within one, 0.4 m (1.5 %)
  shorter track and cleaner, so the diagonal gain at the low rungs is spent by VIA 3200 but the length gain stays.
  15.6 % of the track is diagonal (12.2 % on the orthogonal board, all from `corner45.py` chamfers).
  **Mixed ladder (`DIAGRUNGS=2`)**, Justin's rule at rung level: the VIA 400 and 800 rungs with diagonals, then VIA 1600,
  3200 and the wide rung orthogonal, so the late rungs back the diagonals out where they boxed something in:
  462 / 448 / 438 / 435 -> wide **422 vias / 26.13 m** (`bench/r1_fine9_mixed_*`), DRC clean, 67 min. New best fine r1
  board: one via fewer than all-orthogonal and 0.6 m (2.2 %) shorter; 14.3 % of the track is diagonal.
- **Junction move (`JUNC=1`, off)**: Freerouting slides junction vias along their tracks; here the chains meeting at a
  junction (three or more at a via or a T) are lifted and the pieces connected again from scratch in their window, so
  the junction moves, changes layer or disappears. On the fine r1 board only 5 of the 411 chain ends are such junctions
  (the trees branch on pads, which are fixed), and none of the 5 moves was cheaper. Kept as an option, no gain here.

### Round 9 on the whole board (cloud CPU, 2026-11-09, `bench/wbf9_dj_*`)
The round 9 ladder (`BEST=1` tidy, `DIAGRUNGS=2`, `WIDE=1`, `TRIES=1`, 3 workers, `AGAINST=2`) on round 6's DISJOINT fine
route `wbf6_dj.kicad_pcb` (39.09 m / 664 vias), the same start as the `wbf6_dj` row above. Track / vias in scope after
corner45:

| | VIA 400 | VIA 800 | VIA 1600 | VIA 3200 | wider pairs |
|---|---|---|---|---|---|
| round 6 tidy (`wbf6_dj`) | 38.62 / 591 | 38.90 / 550 | 39.83 / 510 | 40.11 / 504 | 40.17 / 484 |
| round 9 ladder (`wbf9_dj`) | 38.15 / 563 | 38.29 / 535 | 39.02 / 505 | 39.45 / 493 | **39.69 / 479** |
| round 9 tidy time, min (3 workers) | 59 | 31 | 42 | 39 | 70 |

**479 vias / 39.69 m**, 0 open nets, 0 collisions (score.py; KiCad DRC not run in the cloud), 6.9 % diagonal track. Against
the previous best whole board (round 8, 478 vias / 40.66 m from the round 5 route): one via more and 0.97 m (2.4 %)
shorter, the lowest ladder cost so far. The diagonal rungs give most of the via gain (28 and 15 fewer at VIA 400 / 800),
the orthogonal rungs keep it (11 fewer at VIA 3200) and the wide rung lands 5 below round 6. The run took 4.0 h on 4 CPU
cores (restarted twice at the 2 h background cap; `ladder.py` resumes from the finished rungs).

## Round 10 (2026-11-09, branch-149): whole-board route on the cloud CPU, checkpointing, memory
- **Router checkpoint (`CKPT=file`)**: the route state (routes, PathFinder pressure and conflict history, best iteration,
  then the hard-round, rip-retry and improve phases) is saved after every iteration and phase; a run started with the file
  present resumes there. A resumed run is bit-identical to an uninterrupted one (checked on a 12-net coarse route with the
  `CKPTSTOP=N` test hook). Needed because cloud background jobs are capped at 2 h.
- **Memory**: `groups0` held a full-grid int16 label pair per net (65 MB each on the fine grid, 16 GB for 255 nets): the
  whole-board route was OOM-killed on a 16 GB machine. The labels are now stored sparse (cells and labels per layer) and
  scattered into the search window per job; the route is 2 GB and the output unchanged.
- **Per-victim rip-up costs** (Freerouting idea 4) were not implemented: on the r1 route the rip-retry phase places 4 nets
  in 9 rounds and on the whole board it did not run at all (the negotiation converged at iteration 15), so per-victim
  pricing could only change those few nets. Robustness feature, no via gain to expect here.

### Round 10 on the whole board (cloud CPU, `bench/wbf10_a0_*`)
Fresh fine-grid route with the round 8 router defaults (`ALLEVERY=0`, `VIA=240`, CPU backend, 4 threads, 16 iterations,
about 6 h including the restarts), then the round 9 ladder (`BEST=1` tidy, `DIAGRUNGS=2`, `WIDE=1`, 3 workers, 3.6 h):

| | router | VIA 400 | VIA 800 | VIA 1600 | VIA 3200 | wider pairs |
|---|---|---|---|---|---|---|
| round 5 GPU route + round 6 ladder (`wbf6_r5`) | 39.33 / 645 | 38.87 / 571 | 39.33 / 533 | 40.01 / 504 | 40.59 / 494 | 40.66 / 478 |
| DISJOINT route + round 9 ladder (`wbf9_dj`) | 39.09 / 664 | 38.15 / 563 | 38.29 / 535 | 39.02 / 505 | 39.45 / 493 | 39.69 / 479 |
| **ALLEVERY=0 route + round 9 ladder (`wbf10_a0`)** | 38.88 / 643 | 38.14 / 538 | 38.29 / 520 | 38.66 / 506 | 39.45 / 491 | **39.54 / 468** |

**468 vias / 39.54 m**, 0 open nets, 0 collisions (score.py; KiCad DRC not run in the cloud), 6.5 % diagonal track: 10 fewer
vias than round 8's best board and 1.1 m (2.8 %) shorter. The router without the all-net re-route iterations gives a better
start (643 vias, 38.88 m) and the ladder keeps most of the lead to the end. Justin's hand layout: 956 vias / 41.85 m.

### Round 10: what did not help (fine r1, from the 422-via board or the fa0 route)
- **VIA 6400 rung** after the wide rung: nothing moves (converged at VIA 3200).
- **VIA 3200 rung with `AGAINST=1`** (no layer-direction penalty): 420 vias / 26.14 m, 2 vias for 1 cm of track and 0.3 %
  more wrong-way copper. Not adopted.
- **Router via cost ramped 240 -> 480** (`VIAEND=480`): the raw route is worse (618 vias / 28.95 m against 592 / 27.52,
  30 iterations with 22 nets still conflicting against 18) and the ladder ends at 434 / 26.90 m against 422 / 26.13. The
  router's via cost stays at 240 cells (15 mm); the ladder is where the vias are traded away.
- Diagonal moves in the router's own search would need the `pfcpu.c` / `pfgpu.cu` kernels (today only the tidy's `astar.c`
  has them); the DIAG rungs re-route most chains anyway, so this was not pursued.

## Placement guidance (`placeguide.py`, branch-143, modes and route check branch-146)
`python placeguide.py board.kicad_pcb MODE` judges a placement from the pads and nets alone (no routing, existing copper ignored) and
searches moves, rotations and swaps that should make it easier to route. The board file is never written; `optimize` writes a moved
copy with the signal tracks stripped, ready for the router. The docstring has every setting.

What the score reads (GND / +5V are the inner planes and are left out):
- **length**: each net's rectilinear minimum spanning tree (MST) of pads; each tree edge is one connection.
- **bends**: a connection whose pads differ by more than `ALIGN` (1 mm) in both x and y needs an L; with F.Cu horizontal and
  B.Cu vertical an L costs a via. Pin alignment matters more than distance.
- **crossings**: pairs of connections of different nets whose straight lines cross (any direction, the PR #282 measure); also
  counted by class (same direction, aligned or not), and per chip pair as bus pin-order inversions in the report.
- **congestion**: 5 mm bins. Capacity per direction = tracks at 0.55 mm pitch that pass the bin on its preferred layer (+0.25 x the
  other layer), after pads + clearance, NPTH, the 1 mm outline band and the mounting-hole bands are rasterised at 0.1 mm, averaged
  over 5 slices so a connector pad row blocks only its own slice. Demand = RUDY spread of each connection over its bounding box.
- **expected vias** = KB x bends + KX x crossings + K1/K0 x same-direction crossings + KC x congestion exposure, with the K values
  fitted by `fit` (non-negative least squares of the per-net via counts of a routed board) and kept in `placeguide_fit.json`.
- **cost** = length + 15 mm per expected via + 10 mm per track of overflow (+ `BUDW` per mm a timing budget would be broken with
  `BUDGET=budgets.json`).

Modes: `report` (metrics, worst bus pin-order pairs, hottest bins, nets with the most bends, tightest budgets, congestion PNG),
`fit [routed boards]`, `sweep REF` (heatmap of one part's cost over every legal spot and the 4 rotations), `moves` (best single
move per part with the change in length / bends / crossings / overflow / vias), `swaps` (same-footprint place swaps), `optimize`
(greedy moves and swaps; each part's best move is cached and searched again only when a committed change shares a net with it or
lands within 25 mm).
Legality: courtyards inside the outline by 1 mm and clear of each other, Eco1.User puller boxes clear of other courtyards (overlaps
already in the input are tolerated). Decoupling caps (two pads on GND and +5V) move with the nearest IC; connectors, holes, switches,
the relay, the oscillator, jumpers, test points and net ties stay (`FIXED`, `FREE`, `ONLY`). A part turns about its courtyard
centre and its origin stays on the 0.635 mm grid.

**Calibration** (`fit` on the routed main board, 253 nets, 532 vias): per-net vias r = 0.88 (R2 0.78). Bends alone: R2 0.65;
bends + any-direction crossings: 0.776; bends + same-direction crossings only: 0.73 (so the "only same-layer crossings cost vias"
idea fitted worse than plain crossings); all terms: 0.777.

**Route check (2026-11-09, container CPU, 4 threads).** The current placement and the `optimize` result (20 changes: 5 swaps of
same-footprint chips and 15 moves / rotations, below) were each stripped of signal copper and routed the same way
(`mroute4.py` coarse 0.125 mm grid, CPU; then one `tidy.py` rung VIA=400 AGAINST=2):

| | model length | model vias | routed track | routed vias | router time |
|---|---|---|---|---|---|
| current placement | 38.73 m | 554 | 40.93 m | 735 | 60 min |
| `optimize` (20 changes) | 36.03 m | 496 | 37.94 m | 668 | 44 min |
| change | -7.0 % | -10.5 % | -7.3 % | -9.1 % | -27 % |

After the first tidy rung (VIA=400, 3 workers): current 578 vias / 41.49 m, suggested 532 vias / 38.42 m (-8.0 % vias, -7.4 %
track); both 0 open, 0 collisions.
The model predicted the direction and roughly the size of both gains. Timing (`budgets.py U11E=1` on both placements): every check
stays feasible (worst detour ratio 1.54 on `rom_fetch_oe`); neither route was length-budgeted, so both have some pairs over budget
that `lenfix.py` would repair. The suggested placement is a test bench, not a proposal to change the frozen rev A board.
Moves applied (old pin-1-pivot convention of that run; positions are the footprint origins after the move):
swap U3/U12; U10 to (273.37,203.38) rot 0; swap U10/U8; U35 to (284.69,132.54); U29 to (297.16,170.65) rot -90; U2 to (233.68,243.23);
U14 to (311.08,156.68); U15 to (320.66,142.70) rot 180; swap U42/U11; swap U42/U7; U11 to (185.86,149.85) rot 0; U25 to (182.22,187.19)
rot 180; U42 to (149.56,204.65); U19 to (71.12,213.24); R5 to (78.87,176.74) rot 0; U6 to (116.66,242.69); U21 to (116.66,231.05);
U5 to (76.71,242.69); U20 to (81.28,224.70).

### From scratch (`scratch` mode, 2026-11-09)
`python placeguide.py board.kicad_pcb scratch OUT=dir [ICROTS=90,270] [ROUNDS=40]` keeps only `SCRATCHFIXED` parts (connectors,
slots, cartridge, mounting holes, switches, logo) and places every chip and passive from the netlist alone, ignoring where they
are now:
1. global placement: quadratic (star model per net, the fixed pads as anchors), spread over the free board area by recursive
   bisection and pulled toward the spread positions with growing weight (SimPL style), 25 iterations;
2. legalisation: biggest parts first, each at the cheapest legal spot and rotation near its target (`HALO` 0.5 mm spacing);
   plane-only parts (decoupling caps, GND / +5V test points) then go beside the ICs, at most one more per IC at a time;
3. refinement: `optimize` on the result (moves + swaps, everything but the fixed parts may move).

Routed the same way as the check above (coarse route + tidy VIA 400):

| placement | model cost | routed vias | routed track |
|---|---|---|---|
| current (Justin's) | 48.1 k | 578 | 41.49 m |
| current + 20 `optimize` changes | 44.0 k | **532** | **38.42 m** |
| scratch, free rotation (after the swap-overlap fix) | 44.4 k | 600 | 39.21 m |
| scratch, ICs in horizontal rows (`ICROTS=90,270`) | 47.9 k | 652 | 41.52 m |
| scratch, first two runs (overlap bug, see below) | 43.5 k | 634 / 655 | 39.49 / 39.30 m |

From scratch the tool gets within 4 % of the hand placement's vias with 5.5 % less track, but does not beat it; starting from the
hand placement and refining it is the best result. The via model is too optimistic for layouts far from the board it was fitted
on (it ranked the first scratch runs above the current board): fewer crossings did not turn into fewer vias there, and the bends
went up (497 -> 559-568). Refitting on all six routed boards still mis-ranks them, so the next model change should come from the
routed differences (pin access, packing, mixed orientations), not more weight tuning. Forcing every IC horizontal made it worse.
Fixed in this round: a swap of two parts with different rotations could overlap them (`Legal.ok` saw no moved parts after the swap
had taken them out of its table; now it also checks the moved parts against each other). The 2026-11-09 morning `optimize` result
had no such overlap (its swaps were between parts with the same rotation).

### Rules placement and pin swaps (`rules` and `pinswap` modes, 2026-11-09)
Justin's placement rules (after the `scratch` result "looked like a mess"):
parts whose nets go to one place sit right at it (the VGA resistors at the VGA connector, packed tight), then the one chip they
connect to; chips on the same bus side by side; build from the edge inward and leave the middle free for congestion; horizontal
rows by default, a chip at the end of a bus may turn; gaps around chips; pin swapping goes hand in hand with layout.

`python placeguide.py board.kicad_pcb rules OUT=dir [CENTREW=3] [ROUNDS=20]`: only `SCRATCHFIXED` parts stay; passive banks are
placed at the fixed connectors first (bank orientation from their mates), then each time the chip with the most links to what is
already placed goes on a row grid (`ROWPITCH` 19.05 mm, `ICROTS` 90/270) with its decap at the pin-1 end and its own
single-destination passives beside it. `CENTREW` weights distance from the edge (outside-in), `CHALO` / `PHALO` are the gaps
around chips / passives. `ROUNDS>0` then runs `optimize` with any rotation (`REFINEROTS`).

`python placeguide.py board.kicad_pcb pinswap OUT=dir` changes pin assignments only (no part moves), from the swap table in
`pinswap.py`: (D, Q) pairs of 74x377 / 273 / 574 registers and (A, Y) pairs of 74x541 buffers move together; SRAM address pins
trade among themselves, data pins among themselves; ATF22V10C signals may move to any pin that can carry them (inputs to any
input or I/O pin, outputs to an I/O pin whose OLMC has enough product terms, 8 to 16; pin 1 and power fixed). Product terms are
estimated from the `.pld` equations (intermediate names expanded, the smaller of the function and its complement as sum of
products, never more than the pin it compiles on today), so check each moved output in WinCUPL. ROMs are left out (the image would
need reordering), and a PLD pin the design leaves unused but the board ties to a net stays put. Greedy: every allowed pair is scored
with the model, taken best first and re-scored before each commit, four passes. Writes `pinswaps.md` (final was / now table per
pin) and `pinswapped.kicad_pcb` (a router bench with the pad nets swapped). The swaps are suggestions: applying them means changing
the schematic and the PLD `PIN` lines. Run it on any placement, e.g. `OUT/placed.kicad_pcb` from `optimize` or `rules`.

Routed the same way (coarse route + tidy VIA 400; the main board is only the test bench, rev A is not changed):

| placement | model cost | routed vias | routed track |
|---|---|---|---|
| current (Justin's) | 48.1 k | 578 | 41.49 m |
| current + pin swaps (401 pins on 30 parts) | 42.9 k | 467 | 38.49 m |
| current + 20 `optimize` changes | 44.0 k | 532 | 38.42 m |
| current + `optimize` + pin swaps | 40.7 k | **447** | 36.47 m |
| `rules`, `CENTREW=1` | 48.6 k | 764 | 43.61 m |
| `rules`, `CENTREW=3` | 45.4 k | 603 | 39.48 m |
| `rules`, `CENTREW=3`, wider gaps (`CHALO=3 ROWPITCH=21.59`) | 53.1 k | 757 | 46.44 m |
| `rules`, `CENTREW=3`, `ROUNDS=20` | 42.2 k | 611 | 37.24 m |
| `rules` + `ROUNDS=20` + pin swaps | 39.1 k | 515 | **35.76 m** |

Pin swaps are the biggest single gain found so far: -19 % vias on the hand placement, -16 % on the others, and the router
(not budget-aware in these runs) leaves 10-11 timing lengths over budget instead of 49-55 (`budgets.py U11E=1 DUTY=0.5,0.5`).
The rules placer gives the shortest track (-14 % with swaps) but still more vias than starting from the hand placement; building
outside-in matters (`CENTREW` 1 -> 3: 764 -> 603 vias). Uniformly wider gaps cost length and vias: the room has to be left where
the routing needs it, not everywhere.
