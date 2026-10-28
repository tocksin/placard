#!/usr/bin/env python3
"""
test_boing_sim.py - run the Boing Ball demo (gen_boing.py) in placard_sim

    python3 test_boing_sim.py                  130 frames (two bounces, a turn at
                                               a wall): check, time, beam margin
    python3 test_boing_sim.py --frames 64 --gif ../../reference/boing_sim.gif
    python3 test_boing_sim.py --rom            the ROM build from power-up (build\\boing.bat)

The program runs as the DOS would start it (a library program at x0100,
map 07, the library in ROM), with the video stall clocks modeled.  After
every frame (the label fe_mark) the picture is compared pixel for pixel with
the Python model in gen_boing.py: the background, the shadow and the ball
of that frame's place and phase, worked out pixel by pixel (not byte by
byte as the program does), so it also checks that nothing of the last
frame is left.  It also checks that no frame is dropped (one video frame a
frame) and that every row is written before the beam reaches it: the
simulator's beam is at line (clocks / 800) mod 525, the frame wraps at line
0 and 4x picture row r starts at line 45 + 4 r.

Date: 10/28/2026
"""

import argparse
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import gen_boing as gb      # noqa: E402

CLK = 25_175_000
FRAME = 800 * 525
PAL4 = [(r * 255 // 7, g * 255 // 7, b * 255 // 3) for r, g, b in (
    (0, 0, 0), (0, 0, 1), (4, 0, 2), (0, 0, 3), (7, 0, 0), (7, 0, 3), (4, 2, 0), (2, 2, 1),
    (0, 7, 3), (0, 4, 0), (7, 7, 3), (5, 5, 2), (7, 4, 2), (7, 4, 0), (7, 7, 0), (1, 7, 0))]


def build():
    masm = os.path.join(tempfile.mkdtemp(), 'boing.masm')
    gb.main(['-o', masm, '--plc', 'none'])
    mem, syms, _ = ps.assemble(open(masm[:-5] + '.asm').read(), HERE)
    lib, _, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    return mem, syms, lib


def make_cpu(mem, syms, lib):
    rom = {a: v for a, v in lib.items() if ps.lib_area(a)}
    ram = {a: v for a, v in mem.items() if a < 0x4000 and not ps.SYS_START <= a}
    for a in range(ps.LIB_RAM_START, ps.LIB_RAM_END):
        ram[a] = lib.get(a, 0)
    cpu = ps.Cpu(ram, rom=rom)
    cpu.map = 0x07
    cpu.pc = syms['main']
    cpu.stalls = True
    return cpu


def picture(mem):
    """the 4 bpp picture: (x, row) -> color"""
    pic = {}
    for r in range(gb.TOP_ROW, gb.ROWS):
        off = gb.row4(r)
        for c in range(80):
            b = mem[((0x61 + 2 * c) << 8) | off]
            pic[(2 * c, r)] = b & 15
            pic[(2 * c + 1, r)] = b >> 4
    return pic


def render_frame(mem, path=None):
    from PIL import Image
    img = Image.new('RGB', (640, 480))
    px = img.load()
    for y in range(16):                       # the text band, 1 bpp 1x, blue tint
        for col in range(80):
            b = mem[0x6000 + col * 512 + 32 + y]
            for i in range(8):
                px[col * 8 + i, y] = (255, 255, 255) if (b >> i) & 1 else (0, 0, 73)
    for (x, r), v in picture(mem).items():
        for dx in range(4):
            for dy in range(4):
                px[4 * x + dx, 4 * r + dy] = PAL4[v]
    if path:
        img.save(path)
    return img


def run(frames, gif=None, png=None, quiet=False, check=True):
    mem, syms, lib = build()
    cpu = make_cpu(mem, syms, lib)
    z = gb.ZPM
    go, done_row, fe, wait = syms['fr_go'], syms['row_done'], syms['fe_mark'], syms['frame']
    while cpu.pc != go:                       # the screen, the background
        cpu.step()
    print('start-up (screen clear, background): %.1f ms' % (cpu.clocks / CLK * 1000))
    motion = gb.Motion()
    images, fclocks, margins, rows, busy = [], [], [], [], []
    start = None
    nrows = 0
    f = 0
    while f < frames:
        pc = cpu.pc
        if pc == go:
            if start is not None:
                fclocks.append(cpu.clocks - start)
            start = cpu.clocks
            pos0 = cpu.clocks % FRAME
            if pos0 > 2000:
                raise AssertionError('frame %d starts %d clocks after the wrap' % (f + 1, pos0))
        elif pc == wait and start is not None and len(busy) < len(fclocks) + 1:
            busy.append(cpu.clocks - start)
        elif pc == done_row:
            r = cpu.mem[z['w_r']]
            pos = cpu.clocks % FRAME
            margins.append((45 + 4 * r) * 800 - pos)
            nrows += 1
        elif pc == fe:
            f += 1
            bx, top, ph = motion.state()
            if check:
                pic = picture(cpu.mem)
                want = gb.screen(bx, top, ph)
                if pic != want:
                    bad = sorted(k for k in want if pic[k] != want[k])
                    raise AssertionError('frame %d (bx %d, top %d, phase %d): picture differs at '
                                         '%d pixels: %s' % (f, bx, top, ph, len(bad), bad[:12]))
            motion.step()
            if (cpu.mem[z['bx']], cpu.mem[z['ny']], cpu.mem[z['ph']]) != motion.state():
                raise AssertionError('frame %d: next state %s, the model has %s' % (
                    f, (cpu.mem[z['bx']], cpu.mem[z['ny']], cpu.mem[z['ph']]), motion.state()))
            rows.append(nrows)
            nrows = 0
            if gif is not None:
                images.append(render_frame(cpu.mem))
            if not quiet:
                print('frame %3d: bx %2d top %2d phase %d, %2d rows, least margin %6d clocks'
                      % (f, bx, top, ph, rows[-1], min(margins[-rows[-1]:])), flush=True)
        cpu.step()
    while cpu.pc != go:                       # the last frame's time
        cpu.step()
    fclocks.append(cpu.clocks - start)
    if png:
        render_frame(cpu.mem, png)
    if gif:
        save_gif(images, gif)
    worst = max(fclocks)
    dropped = sum(1 for c in fclocks if c > FRAME + FRAME // 2)
    print()
    print('%d frames checked against the model' % frames if check else '%d frames' % frames)
    print('frame to frame: %.0f clocks on average, longest %d: %s'
          % (sum(fclocks) / len(fclocks), worst,
             '%d frames dropped' % dropped if dropped else 'every frame in one video frame, 60 fps'))
    print('work a frame (wrap to the wait): %.0f clocks on average, %d at most (%.0f %% of a frame)'
          % (sum(busy) / len(busy), max(busy), 100 * max(busy) / FRAME))
    print('rows drawn a frame: %.1f on average, %d at most' % (sum(rows) / len(rows), max(rows)))
    print('least margin ahead of the beam: %d clocks (%.1f lines)' % (min(margins), min(margins) / 800))
    if dropped:
        raise AssertionError('a frame took more than one video frame')
    if min(margins) <= 0:
        raise AssertionError('the beam caught up with the drawing')


def run_rom(frames):
    """the ROM build (boing_rom.asm, build\\boing.bat) from power-up, as the
    board runs it: boot loader, the stub's copy to RAM, then the program"""
    mem, syms, _ = ps.assemble(open(os.path.join(HERE, 'boing_rom.asm')).read(), HERE)
    cpu = ps.Cpu({}, rom=ps.build_rom(mem))
    cpu.stalls = True
    fe = syms['B_FE_MARK']
    motion = gb.Motion()
    for f in range(frames):
        while cpu.pc != fe:
            cpu.step()
        cpu.step()
        if picture(cpu.mem) != gb.screen(*motion.state()):
            raise AssertionError('ROM build, frame %d: picture differs' % (f + 1))
        motion.step()
    print('ROM build: %d frames match the model, %.2f s from power-up'
          % (frames, cpu.clocks / CLK))


def save_gif(images, path):
    frames = [img.resize((320, 240), 0).convert('P', palette=1, colors=16) for img in images]
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=20, loop=0,
                   optimize=True)
    print('wrote %s (%d frames)' % (path, len(frames)))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', type=int, default=130)
    ap.add_argument('--gif')
    ap.add_argument('--png')
    ap.add_argument('--rom', action='store_true', help='check the ROM build (boing_rom.asm) instead')
    ap.add_argument('--no-check', action='store_true')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args(argv)
    if a.rom:
        run_rom(a.frames)
    else:
        run(a.frames, gif=a.gif, png=a.png, quiet=a.quiet, check=not a.no_check)
    print('PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
