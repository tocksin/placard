#!/usr/bin/env python3
"""
test_wire3d_sim.py - run the 3D demo (gen_wire3d.py) in placard_sim

    python3 test_wire3d_sim.py                 the demo's ships, 40 frames each mode: check, time
    python3 test_wire3d_sim.py --mode 1        filled faces only (--mode 0: wireframes only)
    python3 test_wire3d_sim.py --ships 10      a stress build (written to a scratch .masm)
    python3 test_wire3d_sim.py --secs 1 --frames 200 --pace 2 --gif ../../reference/wire3d_sim.gif
                                               the demo as it runs, switching every second
    python3 test_wire3d_sim.py --rom           the ROM build from power-up (build\\wire3d.bat)

The program runs as the DOS would start it (a library program at x0100,
map 07, the library in ROM), with the video stall clocks modeled.  After
every frame (the label fe_mark) the picture is compared pixel for pixel
with the Python model in gen_wire3d.py (the same integer arithmetic): in
wireframe mode the lines of this frame XORed together (so it also checks
that the erase put the old lines back), in filled mode the faces painted
far to near (so it also checks that the outline erase left nothing of the
last frame).  The clocks of each part are added up by the labels the
program passes (pm_* in gen_wire3d.py), and the line pixels drawn are
counted at the px_* labels of the line loops.

Date: 10/28/2026
"""

import argparse
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import gen_wire3d as gw     # noqa: E402

CLK = 25_175_000
PAL2 = [(0, 0, 0), (0, 36, 255), (255, 182, 0), (255, 255, 255)]


def build(nships, pace=0, secs=gw.MODE_SECS, start=0):
    masm = os.path.join(tempfile.mkdtemp(), 'wire3d_%d.masm' % nships)
    gw.main(['--ships', str(nships), '--pace', str(pace), '--secs', str(secs),
             '--start', str(start), '-o', masm, '--plc', 'none'])
    src = open(masm[:-5] + '.asm').read()
    mem, syms, _ = ps.assemble(src, HERE)      # the include paths are relative to this folder
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
    """the 2 bpp picture: (x, line) -> pixel value, for the pixels not 0"""
    pic = {}
    for l in range(gw.Y_TOP, gw.Y_BOT + 1):
        off = gw.TAB['ROW'][l]
        for col in range(80):
            b = mem[((0x61 + 2 * col) << 8) | off]
            if b:
                for p in range(4):
                    v = (b >> (2 * p)) & 3
                    if v:
                        pic[(col * 4 + p, l)] = v
    return pic


class Expected:
    """the picture the program should leave after each frame"""

    def __init__(self, n):
        self.n = n
        self.mode = None
        self.stray = 0

    def __call__(self, ships, mode):
        if mode != self.mode:                 # a switch clears the screen
            self.mode = mode
            self.fs = gw.FillScreen(self.n)
        if not mode:
            return gw.screen_of(ships)
        pic = self.fs.frame(ships)
        self.stray += len(set(pic.items()) ^ set(gw.screen_fill(ships).items()))
        return pic


PHASES = {'matrix': 'matrix', 'pm_x': 'transform + project', 'pm_c': 'camera (+ light)',
          'pm_t': 'product tables', 'pm_f': 'faces seen', 'pm_e': 'line setup (records)',
          'pm_r': 'erase (old line records)', 'pm_d': 'draw (new line records)',
          'pm_o': 'ship motion, calls', 'pm_fo': 'outline', 'pm_er': 'erase (outline)',
          'pm_s': 'sort', 'pm_p': 'fill faces', 'pm_n': 'ship motion, calls',
          'ship_pre': 'ship motion, calls', 'frame_end': 'frame end, HUD, menu_poll'}


def zp(name):
    return gw.ZPM[name]


def render_frame(mem, path=None):
    from PIL import Image
    img = Image.new('RGB', (640, 480))
    px = img.load()
    for y in range(gw.HUD_ROWS):              # the text band, 1 bpp 1x, blue tint
        mb = mem[ps.MODE_BASE + y]
        tint = (0, 0, 73) if mb & 0x40 else (0, 0, 0)
        for col in range(80):
            b = mem[0x6000 + col * 512 + 32 + y]
            for i in range(8):
                c = (255, 255, 255) if (b >> i) & 1 else tint
                px[col * 8 + i, y] = c
    for (x, l), v in picture(mem).items():
        for dx in (0, 1):
            for dy in (0, 1):
                px[2 * x + dx, 2 * l + dy] = PAL2[v]
    if path:
        img.save(path)
    return img


def run(nships, frames, gif=None, check=True, png=None, quiet=False, pace=0,
        secs=gw.MODE_SECS, start=0):
    mem, syms, lib = build(nships, pace, secs, start)
    ships = gw.ship_set(nships)
    model = gw.Model(ships)
    expected = Expected(nships)
    cpu = make_cpu(mem, syms, lib)
    marks = {syms[k]: v for k, v in PHASES.items()}
    px_addrs = {v for k, v in syms.items() if k.startswith('px_')}
    fe = syms['fe_mark']
    first = syms['frame']
    while cpu.pc != first:                    # the screen clear, the title
        cpu.step()
    t_start = cpu.clocks
    stall0 = cpu.stall_clocks
    phase = 'ship motion, calls'
    res = {m: {'clocks': {}, 'frames': 0, 'frame_clocks': [], 'pixels': 0, 'lines': 0,
               'faces': 0} for m in (0, 1)}
    images = []
    last = cpu.clocks
    done = 0
    vframes0 = cpu.mem[0x08] | cpu.mem[0x09] << 8
    mode = cpu.mem[zp('mode')]
    switches = 0
    while done < frames:
        pc = cpu.pc
        ph = marks.get(pc)
        if ph:
            phase = ph
        if pc in px_addrs:
            res[mode]['pixels'] += 1
        if pc == first:
            m = cpu.mem[zp('mode')]
            if m != mode:                     # switched: the clear is not a frame's time
                switches += 1
                mode = m
                last = cpu.clocks
        if pc == fe:
            done += 1
            r = res[mode]
            d = model.frame()
            if mode:
                nf = sum(sum(x['vis']) for x in d if x['drawn'])
                got = cpu.mem[zp('nfac')]
                if nf != got:
                    raise AssertionError('frame %d: %d faces filled, the model has %d'
                                         % (done, got, nf))
                r['faces'] += nf
            else:
                nl = sum(len(x['lines']) for x in d)
                got = cpu.mem[zp('nrec')]
                if nl != got:
                    raise AssertionError('frame %d: %d lines, the model has %d' % (done, got, nl))
                r['lines'] += nl
            if check:
                pic = picture(cpu.mem)
                want = expected(d, mode)
                if pic != want:
                    bad = sorted(set(pic.items()) ^ set(want.items()))
                    raise AssertionError('frame %d (%s): picture differs at %d pixels: %s'
                                         % (done, 'filled' if mode else 'wireframe', len(bad),
                                            bad[:12]))
            fc = cpu.clocks - last
            r['frame_clocks'].append(fc)
            r['frames'] += 1
            last = cpu.clocks
            if gif is not None:
                images.append((render_frame(cpu.mem), fc))
            if not quiet:
                print('frame %3d %s: %7d clocks (%5.1f fps), %3d %s' %
                      (done, 'filled' if mode else 'wire  ', fc, CLK / fc, got,
                       'faces' if mode else 'lines'), flush=True)
        before = cpu.clocks
        cpu.step()
        res[mode]['clocks'][phase] = res[mode]['clocks'].get(phase, 0) + cpu.clocks - before
    vframes = (cpu.mem[0x08] | cpu.mem[0x09] << 8) - vframes0
    if png:
        render_frame(cpu.mem, png)
    if gif:
        save_gif(images, gif)
    return {'ships': nships, 'frames': frames, 'clocks': cpu.clocks - t_start, 'modes': res,
            'stalls': cpu.stall_clocks - stall0, 'vframes': vframes, 'switches': switches,
            'stray': expected.stray,
            'verts': sum(len(gw.MODELS[s[0]]['v']) for s in ships),
            'faces': sum(len(gw.MODELS[s[0]]['f']) for s in ships),
            'edges': sum(len(gw.MODELS[s[0]]['e']) for s in ships)}


def run_rom(frames):
    """the ROM build (wire3d_rom.asm, build\\wire3d.bat) from power-up, as the
    board runs it: boot loader, the stub's copy to RAM, then the program"""
    mem, syms, _ = ps.assemble(open(os.path.join(HERE, 'wire3d_rom.asm')).read(), HERE)
    cpu = ps.Cpu({}, rom=ps.build_rom(mem))
    cpu.stalls = True
    model = gw.Model(gw.ship_set(gw.DEMO_SHIPS))
    expected = Expected(gw.DEMO_SHIPS)
    fe = syms['W_FE_MARK']
    for f in range(frames):
        while cpu.pc != fe:
            cpu.step()
        mode = cpu.mem[zp('mode')]
        cpu.step()
        if picture(cpu.mem) != expected(model.frame(), mode):
            raise AssertionError('ROM build, frame %d: picture differs' % (f + 1))
    print('ROM build: %d frames match the model, %.2f s from power-up'
          % (frames, cpu.clocks / CLK))


def save_gif(images, path):
    frames = []
    durs = []
    for img, clk in images:
        frames.append(img.resize((320, 240)).convert('P', palette=1, colors=8))
        durs.append(max(20, round(clk / CLK * 1000 / 10) * 10))
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durs, loop=0,
                   optimize=True)
    print('wrote %s (%d frames)' % (path, len(frames)))


def report(r):
    print()
    print('%d ships, %d vertices, %d faces, %d edges; %d frames, %.2f s, %d mode switches '
          '(video frames counted by the program: %d)'
          % (r['ships'], r['verts'], r['faces'], r['edges'], r['frames'], r['clocks'] / CLK,
             r['switches'], r['vframes']))
    for mode in (0, 1):
        m = r['modes'][mode]
        f = m['frames']
        if not f:
            continue
        tot = sum(m['frame_clocks'])
        print()
        print('%s: %d frames, %.0f clocks a frame (%.1f fps), slowest %d (%.1f fps)'
              % ('filled' if mode else 'wireframe', f, tot / f, f * CLK / tot,
                 max(m['frame_clocks']), CLK / max(m['frame_clocks'])))
        if mode:
            print('  %.1f faces filled a frame; %d pixels in all differ from a perfect painter '
                  '(faces seen but inverted on the screen)' % (m['faces'] / f, r['stray']))
        else:
            print('  %.1f lines, %.0f pixels drawn a frame (and as many erased)'
                  % (m['lines'] / f, m['pixels'] / f / 2))
        ctot = sum(m['clocks'].values())
        for k, v in sorted(m['clocks'].items(), key=lambda kv: -kv[1]):
            print('  %-28s %9.0f clocks a frame  %5.1f %%' % (k, v / f, 100 * v / ctot))
        ph = m['clocks']
        print('  per vertex (transform): %.0f clocks, per face (seen or not): %.0f'
              % (ph.get('transform + project', 0) / f / r['verts'],
                 ph.get('faces seen', 0) / f / r['faces']))
        if not mode:
            print('  per line record: %.0f clocks; draw + erase: %.1f clocks a pixel'
                  % (ph.get('line setup (records)', 0) / max(1, m['lines']),
                     (ph.get('draw (new line records)', 0) + ph.get('erase (old line records)', 0))
                     / max(1, m['pixels'])))
    print()
    print('video stall clocks: %.1f %%' % (100 * r['stalls'] / r['clocks']))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--ships', type=int, default=gw.DEMO_SHIPS)
    ap.add_argument('--frames', type=int, default=40, help='frames (in each mode without --mode)')
    ap.add_argument('--mode', type=int, default=None, help='0: wireframes only, 1: filled only; '
                    'default: both, one after the other')
    ap.add_argument('--secs', type=int, default=None, help='seconds between the switches')
    ap.add_argument('--pace', type=int, default=0, help='2: the 30 fps capped build (the .PLC)')
    ap.add_argument('--gif')
    ap.add_argument('--png')
    ap.add_argument('--no-check', action='store_true')
    ap.add_argument('--rom', action='store_true', help='check the ROM build (wire3d_rom.asm) instead')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args(argv)
    if a.rom:
        run_rom(a.frames)
        print('PASS')
        return 0
    kw = dict(gif=a.gif, check=not a.no_check, png=a.png, quiet=a.quiet, pace=a.pace)
    if a.secs is not None:
        rs = [run(a.ships, a.frames, secs=a.secs, start=a.mode or 0, **kw)]
    elif a.mode is not None:
        rs = [run(a.ships, a.frames, secs=255, start=a.mode, **kw)]
    else:
        rs = [run(a.ships, a.frames, secs=255, start=m, **kw) for m in (0, 1)]
    for r in rs:
        report(r)
    print('PASS' if not a.no_check else 'done (not checked)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
