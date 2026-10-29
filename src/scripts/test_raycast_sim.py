#!/usr/bin/env python3
"""
test_raycast_sim.py - run raycast.asm in placard_sim and check every view

    python3 test_raycast_sim.py                 30 views, compared with the model
    python3 test_raycast_sim.py --views 200 --gif rc.gif
                                                also an animated GIF of the views
    python3 test_raycast_sim.py --png rc.png    the last view as a PNG

Boots the ROM image like the board (no keys or pads, so the demo walk
drives).  For each view it checks:
  - the movement: the player's angle and position match the model
    (gen_raycast.tick and the demo walk script) after the same number of
    ticks (frames) the program counted
  - the picture: every byte of the 80 x 112 view matches
    gen_raycast.view_bytes for that position
and it prints the clocks a view and a column took.  Video stalls are not
modeled (the board is about 10 % slower: 1 clock in 8 during active video).

Date: 10/18/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import gen_raycast as rc  # noqa: E402

CLOCKS_PER_FRAME = 525 * 800


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--views', type=int, default=30)
    ap.add_argument('--png')
    ap.add_argument('--gif')
    args = ap.parse_args(argv)

    src, _ = rc.gen()
    mem, syms, _ = ps.assemble(src, HERE)
    cpu = ps.Cpu({}, rom=ps.build_rom(mem))
    z = syms
    st = dict(rc.START)
    script = rc.Script()
    first_tick = True
    view_start = None
    col0 = None
    views = 0
    ok = True
    frames = []
    clocks = []
    col_clocks = []
    p_ticks, p_done, p_col = syms['ticks'], syms['view_done'], syms['col_top']
    while views < args.views:
        cpu.step()
        pc = cpu.pc
        if pc == p_ticks and first_tick:
            first_tick = False
            n = cpu.mem[z['nticks']]
            for _ in range(n):
                rc.tick(st, script.bits())
            view_start = cpu.clocks
        elif pc == p_col:
            if cpu.mem[z['col']] == 1 and col0 is not None:
                col_clocks.append(cpu.clocks - col0)
            if cpu.mem[z['col']] == 0:
                col0 = cpu.clocks
        elif pc == p_done:
            first_tick = True
            views += 1
            got = dict(pa=cpu.mem[z['pa']],
                       px=cpu.mem[z['pxl']] | cpu.mem[z['pxh']] << 8,
                       py=cpu.mem[z['pyl']] | cpu.mem[z['pyh']] << 8)
            if got != st:
                print('view %d: player %s, model %s' % (views, got, st))
                ok = False
                st = got
            want = rc.view_bytes(st['pa'], st['px'], st['py'])
            bad = [a for a, v in want.items() if cpu.mem[a] != v]
            if bad:
                a = bad[0]
                print('view %d: %d bytes differ, first at %04X: %02X, model %02X (column %d)'
                      % (views, len(bad), a, cpu.mem[a], want[a], (a - 0x6100) // 512))
                ok = False
            clocks.append(cpu.clocks - view_start)
            if rc.wall_at(st['px'], st['py']):
                print('view %d: the player is in a wall' % views)
                ok = False
            if args.gif:
                path = os.path.join(HERE, '_rc_frame.png')
                ps.render(cpu.mem, path)
                from PIL import Image
                frames.append(Image.open(path).convert('P', palette=Image.ADAPTIVE, colors=255))
                os.remove(path)
    avg = sum(clocks) / len(clocks)
    print('%d views, %d to %d clocks each (average %d = %.2f frames, %.1f views a second;'
          ' about %.1f on the board)' % (views, min(clocks), max(clocks), avg,
                                         avg / CLOCKS_PER_FRAME, 60 * CLOCKS_PER_FRAME / avg,
                                         60 * CLOCKS_PER_FRAME / avg / 1.1))
    print('column: %d to %d clocks (average %d)' % (min(col_clocks), max(col_clocks),
                                                     sum(col_clocks) / len(col_clocks)))
    print('player at %s' % st)
    if args.png:
        ps.render(cpu.mem, args.png)
        print('wrote', args.png)
    if args.gif:
        frames[0].save(args.gif, save_all=True, append_images=frames[1:],
                       duration=int(1000 * avg / CLOCKS_PER_FRAME / 60), loop=0)
        print('wrote', args.gif, len(frames), 'frames')
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
