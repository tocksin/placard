# PLACARD grid router v4 (2026-11-01)

Routes a KiCad board file outside KiCad on a 0.125 mm grid, two signal layers (F.Cu horizontal preferred,
B.Cu vertical preferred, 90-degree moves), with Justin's rules: 1 mm copper-to-outline clearance, nothing
between a mounting hole and the board edge, a net never runs parallel to itself. The board file is never
modified: every tool reads one file and writes another.

## Tools
- `mroute4.py in.kicad_pcb out.kicad_pcb` : negotiated-congestion router. Every open net is routed, in parallel batches,
  against the occupancy of all other nets (PathFinder style); conflicted nets are re-routed with the others blocked;
  what is still open is written out unrouted. `BACKEND=gpu` runs one CUDA block per net (CuPy), `BACKEND=cpu` one
  OpenMP thread per net, `auto` picks the GPU when CuPy finds one.
- `tidy.py in out BASE=base.kicad_pcb` : clean-up of the copper added after BASE: every chain is re-routed alone and
  kept only when cheaper (fewer vias / bends / wrong-way track); redundant chains are deleted.
- `score.py pcb BASE=base.kicad_pcb` : one report (open nets, track, vias, wrong-way %, diagonal %, detour, rule
  breaks, self-parallel places, clearance collisions, worst nets). `NETS=a,b` scores only those nets.
- `mroute3.py` (v3, single-thread A*, rip-up-and-retry) is kept for finishing leftovers in the container.
- `gridcore.py` shared rasteriser/A*/output; `pfcommon.h` cost rules shared by `pfcpu.c` (CPU) and `pfgpu.cu` (CUDA).

Environment variables: see the docstring at the top of each script (VIA, AGAINST, RING, WIN, ITERS, BATCH, THREADS ...).

## Windows (Justin's laptop, RTX 4070)
1. Python 3.10+ with `pip install numpy scipy shapely "cupy-cuda12x[ctk]"` (the [ctk] extra brings the NVRTC headers; no CUDA Toolkit install needed, the NVIDIA driver is enough).
2. The prebuilt `astar.dll` and `pfcpu.dll` (MinGW, static) are in this folder; no compiler needed.
3. `run_bench.bat` routes the mux benchmark (`r1.kicad_pcb`, 108 nets stripped from the main board) on the GPU
   and scores the result. `set BACKEND=cpu` to compare.

## Linux / container
`gcc -O3 -shared -fPIC -o astar.so astar.c` and `gcc -O3 -fopenmp -shared -fPIC -o pfcpu.so pfcpu.c` (mroute4 builds
pfcpu.so itself when missing). `pip install numpy scipy shapely`; CuPy only for a GPU.

## Benchmark (2026-11-01, r1: main board with the 108 mux-region nets removed)
Scope = the nets the run routed (the GPU run also ripped and re-routed CLK, PIXEL_ENABLE, Y_ENABLE and BRANCH_BLOCK
because PROT was not set, so its scope is 112 nets and its totals include CLK's 875 mm / 10 vias).

| run | open | track | vias | time | files |
|---|---|---|---|---|---|
| Freerouting 1.9 (reference, 19 nets left open) | 19 | - | 390 | ~1 h | hardware/routing/freerouting_trial_2026-10-28 |
| v3 (single thread A*, batches, b8) | 0 | 26.74 m | 605 | ~40 min | tools_v3 |
| v4 CPU, 4 threads (`bench_cpu.score`) | 0 | 27.71 m | 657 | 19 min | bench_cpu.log |
| v4 CPU + tidy 3 passes (`bench_cpu_tidy.score`) | 0 | 27.11 m | 588 | +6 min | bench/bench_cpu_tidy.kicad_pcb.zip |
| v4 GPU, RTX 4070 laptop, game sharing the GPU (`bench_gpu2.score`) | 0 | 30.69 m | 780 (112 nets) | 58 min | bench_gpu2.log |
| v4 GPU + tidy (`bench_gpu2_tidy.score`) | 0 | 29.74 m | 692 (112 nets) | +3 min | bench/bench_gpu2_tidy.kicad_pcb.zip |

GPU timing: iterations with few conflicted nets take 9-20 s (CPU-4: 7-50 s), but the two early full iterations took
694 s and 2181 s (one CUDA block per net; the long nets have near-board-size windows and run on a single SM each, and
the frontier search re-relaxes a lot once present costs make the cost field uneven). Next step for the GPU backend:
split the big nets over several blocks or use a near/far bucket frontier. Set PROT=CLK,... (comma list) for nets that
must not be ripped.
