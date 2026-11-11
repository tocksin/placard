#!/usr/bin/env python3
"""
test_raycast_tex_sim.py - run raycast_tex.asm (the textured ray caster) in placard_sim and check every view

    python3 test_raycast_tex_sim.py                 30 views, compared with the model
    python3 test_raycast_tex_sim.py --views 200 --gif rc.gif
                                                also an animated GIF of the views
    python3 test_raycast_tex_sim.py --png rc.png    the last view as a PNG

Boots the ROM image like the board (no keys or pads, so the demo walk
drives).  For each view it checks:
  - the movement: the player's angle and position match the model
    (gen_raycast.tick and the demo walk script, the same as raycast.asm) after the same number of
    ticks (frames) the program counted
  - the picture: every byte of the 80 x 112 view matches
    gen_raycast_tex.view_bytes for that position
  - the T key: pressed after view 10 and again after view 20 (held for 3
    views), it turns the textures off (one flat color a wall) and on again:
    views 11-20 must be flat, the rest textured.  The ROM build holds the
    key in the keyboard state (KBD_NOW); the card build presses it on the
    PS/2 keyboard model, so there the flat views may start a view or two
    later, but the toggle must happen and each view must match the model
and it prints the clocks a view and a column took.  Video stalls are not
modeled (the board is about 10 % slower: 1 clock in 8 during active video).

Date: 11/02/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import gen_raycast_tex as rc  # noqa: E402
import test_dos               # noqa: E402

CLOCKS_PER_FRAME = 525 * 800


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--views', type=int, default=30)
    ap.add_argument('--png')
    ap.add_argument('--gif')
    ap.add_argument('--sd', action='store_true',
                    help='the SD card program (RAYTEX.PLC + .OVL, gen_raycast_tex.py --sd), '
                         'booted from a card as the board does')
    args = ap.parse_args(argv)
    args.sd = True      # the ROM build went on 2026-11-11 (docs/architecture/ROM.md)

    src, mem, syms, info = rc.build(sd=args.sd)
    if args.sd:
        plc, ovl = rc.sd_files(mem, syms)
        rig = test_dos.boot_plc('RAYTEX.PLC', plc, syms['main'], {'RAYTEX.OVL': ovl})
        if rig is None:
            return 1
        cpu = rig.cpu
        print('started at frame %d' % (cpu.clocks // CLOCKS_PER_FRAME))
    else:
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
    flat_seen = []
    t_down = {10: True, 13: False, 20: True, 23: False}
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
            flat = cpu.mem[z['flat']]
            flat_seen.append(flat)
            if not args.sd and flat != (11 <= views <= 20):
                print('view %d: flat %d, expected %d' % (views, flat, 11 <= views <= 20))
                ok = False
            if views in t_down:
                if args.sd:
                    (rig.port.kbd.press if t_down[views] else rig.port.kbd.release)(rig.codes['t'])
                elif t_down[views]:
                    cpu.mem[0xA2] &= 0xF7           # KBD_NOW + 2, bit 3: T down
                else:
                    cpu.mem[0xA2] |= 0x08
            if got != st:
                print('view %d: player %s, model %s' % (views, got, st))
                ok = False
                st = got
            want = rc.view_bytes(st['pa'], st['px'], st['py'], info['hs'], flat)
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
                path = os.path.join(HERE, '_rct_frame.png')
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
    if args.views >= 30:
        print('flat (T) by view: %s' % ''.join(str(f) for f in flat_seen[:30]))
        if args.sd and not (flat_seen[0] == 0 and any(flat_seen[10:20]) and not any(flat_seen[26:30])):
            print('the T key did not toggle the textures')
            ok = False
    if args.sd:
        if not test_dos.esc_to_dos(rig):
            ok = False
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
