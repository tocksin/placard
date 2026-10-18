#!/usr/bin/env python3
"""
test_scroller_sim.py - run scroller.asm in placard_sim and check every frame

    python3 test_scroller_sim.py                  20 s of the demo player
    python3 test_scroller_sim.py --seconds 5 --gif sc.gif
                                                  also an animated GIF
    python3 test_scroller_sim.py --png sc.png     the last frame as a PNG

Boots the ROM image like the board (no keys or pads, so the demo player
plays).  For every frame it checks:
  - the background: after the bands are drawn, every byte of the 160 x 112
    playfield matches gen_scroller.background for the scroll in RAM
  - the sprites: after the RAM blitter, the playfield matches the
    background with the sprite list (read from the zero page) drawn over
    it by gen_scroller.draw_sprites_model
  - the beam: each band is finished before the beam reaches its first row,
    and no frame is missed (the program's lag counter stays 0)
and at the end that the demo player got somewhere (score, coins, distance).
Video stalls are not modeled: the board is about 10 % slower, so the
margins printed should be well above 10 %.

Date: 10/18/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import gen_scroller as sc  # noqa: E402

CLOCKS_PER_FRAME = 525 * 800
FIRST_LINE = 45             # line of the frame (from vblank start) that shows row 0


def beam_clock(row):
    """clocks from the start of vertical blanking to the beam at screen row"""
    return (FIRST_LINE + row) * 800


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=float, default=20.0)
    ap.add_argument('--png')
    ap.add_argument('--gif')
    ap.add_argument('--gif-step', type=int, default=2)
    args = ap.parse_args(argv)

    src, _ = sc.gen()
    mem, syms, _ = ps.assemble(src, HERE)
    cpu = ps.Cpu({}, rom=ps.build_rom(mem))
    z = syms
    stops = {syms['frame_go']: 'go', syms['drawn_bg']: 'bg', syms['drawn_all']: 'all'}
    for name, g0, g1, sh in sc.BANDS:
        stops[syms['band_%s_done' % name]] = name
    nframes = int(args.seconds * 60)
    frames = 0
    ok = True
    t0 = 0
    worst = {}
    busy = []
    gif = []
    first_px = None
    dist = 0
    last_px = None
    while frames < nframes:
        cpu.step()
        what = stops.get(cpu.pc)
        if what is None:
            continue
        t = cpu.clocks
        if what == 'go':
            # the frame starts when frame_poll saw the line read wrap; the
            # wrap is at a multiple of 420,000 clocks in the simulator
            t0 = (t // CLOCKS_PER_FRAME) * CLOCKS_PER_FRAME
            if t - t0 > 2000:
                print('frame %d: started %d clocks after vertical blanking' % (frames, t - t0))
                ok = False
            continue
        dt = t - t0
        if what in ('C', 'M', 'H'):
            g0 = [b for b in sc.BANDS if b[0] == what][0][1]
            first = min(g for g in range(g0, g0 + 24) if g not in sc.STATIC[what]) if True else g0
            limit = beam_clock(32 + 4 * first)
            worst[what] = max(worst.get(what, 0), dt / limit)
            if dt > limit:
                print('frame %d: band %s done at %d, the beam was there at %d' % (frames, what, dt, limit))
                ok = False
            continue
        scroll = cpu.mem[z['scl']] | cpu.mem[z['sch']] << 8
        if what == 'bg':
            limit = beam_clock(32 + 4 * sc.GROUND_G)
            worst['G'] = max(worst.get('G', 0), dt / limit)
            want = sc.background(scroll)
            bad = [a for a, v in want.items() if cpu.mem[a] != v]
            if bad:
                a = bad[0]
                print('frame %d: background, %d bytes differ, first %04X: %02X, model %02X'
                      % (frames, len(bad), a, cpu.mem[a], want[a]))
                ok = False
            continue
        # all drawn: background + sprites
        frames += 1
        model = bytearray(65536)
        for a, v in sc.background(scroll).items():
            model[a] = v
        n = cpu.mem[z['sl_n']]
        lst = []
        lo2id = {(sc.BLIT_SYMS['spr_' + nm]): i for i, (nm, _) in enumerate(sc.FRAMES)}
        for i in range(n):
            ad = cpu.mem[z['SL_LO'] + i] | cpu.mem[z['SL_HI'] + i] << 8
            lst.append((lo2id[ad], cpu.mem[z['SL_C'] + i], cpu.mem[z['SL_G'] + i]))
        sc.draw_sprites_model(model, lst)
        want = sc.background(scroll)
        bad = [a for a in want if cpu.mem[a] != model[a]]
        if bad:
            a = bad[0]
            print('frame %d: sprites, %d bytes differ, first %04X: %02X, model %02X (list %s)'
                  % (frames, len(bad), a, cpu.mem[a], model[a], lst))
            ok = False
        worst['spr'] = max(worst.get('spr', 0), dt)
        px = cpu.mem[z['pxl']] | cpu.mem[z['pxh']] << 8
        if last_px is not None:
            dist += ((px - last_px + 512) % 1024) - 512
        last_px = px
        if args.gif and frames % args.gif_step == 0:
            path = os.path.join(HERE, '_sc_frame.png')
            ps.render(cpu.mem, path)
            from PIL import Image
            gif.append(Image.open(path).convert('P', palette=Image.ADAPTIVE, colors=255))
            os.remove(path)
    # busy: run on to the next frame start and see how long the frame took
    lag = cpu.mem[z['lag']]
    score = cpu.mem[z['score_lo']] | cpu.mem[z['score_hi']] << 8
    print('%d frames; drawing done (background + sprites) at most %d clocks into the frame'
          % (frames, worst['spr']))
    for k in ('C', 'M', 'H', 'G'):
        print('  band %s finished at %3.0f %% of the time the beam takes to reach it' % (k, 100 * worst[k]))
    print('frames missed: %d; score %d, coins %d, lives %d, demo ran %d byte columns (%d laps)'
          % (lag, score, cpu.mem[z['coins']], cpu.mem[z['lives']], dist, dist // sc.WRAP))
    if lag:
        print('FAIL: frames were missed')
        ok = False
    if dist < frames // 4:
        print('FAIL: the demo player hardly moved')
        ok = False
    if args.png:
        ps.render(cpu.mem, args.png)
        print('wrote', args.png)
    if args.gif:
        gif[0].save(args.gif, save_all=True, append_images=gif[1:],
                    duration=int(1000 * args.gif_step / 60), loop=0)
        print('wrote', args.gif, len(gif), 'frames')
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
