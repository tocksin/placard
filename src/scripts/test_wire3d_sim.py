#!/usr/bin/env python3
"""
test_wire3d_sim.py - run the 3D wireframe demo (gen_wire3d.py) in placard_sim

    python3 test_wire3d_sim.py                 4 ships, 40 frames: check, time, report
    python3 test_wire3d_sim.py --frames 150 --gif ../../reference/wire3d.gif
    python3 test_wire3d_sim.py --ships 8       a stress build (written to a scratch .masm)
    python3 test_wire3d_sim.py --rom           the ROM build from power-up (build\\wire3d.bat)

The program runs as the DOS would start it (a library program at x0100,
map 07, the library in ROM), with the video stall clocks modeled.  After
every frame (the label fe_mark) the picture is compared pixel for pixel
with the Python model in gen_wire3d.py (the same integer arithmetic: the
lines of this frame XORed together, so it also checks that the erase put
the old lines back).  The clocks of each part are added up by the labels
the program passes (pm_* in gen_wire3d.gen_ships), and the pixels drawn
are counted at the px_* labels of the line loops.

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


def build(nships, pace=0):
    if nships == 4 and pace == 2:
        masm = os.path.join(HERE, 'wire3d.masm')
    else:
        masm = os.path.join(tempfile.mkdtemp(), 'wire3d_%d.masm' % nships)
    gw.main(['--ships', str(nships), '--pace', str(pace), '-o', masm, '--plc', 'none'])
    asm = masm[:-5] + '.asm'
    src = open(asm).read()
    # the include paths are relative to this folder
    mem, syms, _ = ps.assemble(src, HERE)
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
    """lit pixels (x, line) of the 2 bpp picture; raises on a pixel that is not 0 or 3"""
    lit = set()
    for l in range(gw.Y_TOP, gw.Y_BOT + 1):
        off = gw.TAB['ROW'][l]
        for col in range(80):
            b = mem[((0x61 + 2 * col) << 8) | off]
            for p in range(4):
                v = (b >> (2 * p)) & 3
                if v == 3:
                    lit.add((col * 4 + p, l))
                elif v:
                    raise AssertionError('pixel value %d at %d,%d' % (v, col * 4 + p, l))
    return lit


def phase_labels(syms, n):
    marks = {syms['matrix']: 'matrix', syms['frame_end']: 'frame end, HUD, menu_poll'}
    for s in range(n):
        marks[syms['pm_x%d' % s]] = 'transform + project'
        marks[syms['pm_f%d' % s]] = 'faces (hidden lines)'
        marks[syms['pm_e%d' % s]] = 'line setup (records)'
        marks[syms['pm_r%d' % s]] = 'erase (old records)'
        marks[syms['pm_d%d' % s]] = 'draw (new records)'
        marks[syms['pm_o%d' % s]] = 'ship motion, calls'
        marks[syms['ship_%d' % s]] = 'ship motion, calls'
    return marks


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
    for l in range(gw.HUD_ROWS // 2, 240):
        off = gw.TAB['ROW'][l]
        for col in range(80):
            b = mem[((0x61 + 2 * col) << 8) | off]
            if not b:
                continue
            for p in range(4):
                if (b >> (2 * p)) & 3:
                    x = (col * 4 + p) * 2
                    for dy in (0, 1):
                        px[x, 2 * l + dy] = (255, 255, 255)
                        px[x + 1, 2 * l + dy] = (255, 255, 255)
    if path:
        img.save(path)
    return img


def run(nships, frames, gif=None, check=True, png=None, quiet=False, pace=0):
    mem, syms, lib = build(nships, pace)
    ships = gw.ship_set(nships)
    model = gw.Model(ships)
    cpu = make_cpu(mem, syms, lib)
    marks = phase_labels(syms, len(ships))
    px_addrs = {v for k, v in syms.items() if k.startswith('px_')}
    fe = syms['fe_mark']
    # run to the first frame's start (screen clear, title)
    first = syms['frame']
    while cpu.pc != first:
        cpu.step()
    t_start = cpu.clocks
    stall0 = cpu.stall_clocks
    phase = 'ship motion, calls'
    clocks = {}
    pixels = 0
    nrec_tot = 0
    frame_clocks = []
    images = []
    last = cpu.clocks
    done = 0
    vframes0 = cpu.mem[0x08] | cpu.mem[0x09] << 8
    while done < frames:
        pc = cpu.pc
        ph = marks.get(pc)
        if ph:
            phase = ph
        if pc in px_addrs:
            pixels += 1
        if pc == fe:
            done += 1
            lines = model.frame()
            nl = sum(len(x) for x in lines)
            nrec = cpu.mem[0x20 + gw.ZP.index('nrec')]
            if nl != nrec:
                raise AssertionError('frame %d: %d lines, the model has %d' % (done, nrec, nl))
            nrec_tot += nrec
            if check:
                got = picture(cpu.mem)
                want = gw.screen_of(lines)
                if got != want:
                    raise AssertionError('frame %d: picture differs: %d extra, %d missing'
                                         % (done, len(got - want), len(want - got)))
            frame_clocks.append(cpu.clocks - last)
            last = cpu.clocks
            if gif is not None:
                images.append((render_frame(cpu.mem), frame_clocks[-1]))
            if not quiet:
                print('frame %3d: %7d clocks (%5.1f fps), %3d lines' %
                      (done, frame_clocks[-1], CLK / frame_clocks[-1], nrec), flush=True)
        before = cpu.clocks
        cpu.step()
        clocks[phase] = clocks.get(phase, 0) + cpu.clocks - before
    total = cpu.clocks - t_start
    vframes = (cpu.mem[0x08] | cpu.mem[0x09] << 8) - vframes0
    if png:
        render_frame(cpu.mem, png)
    if gif:
        save_gif(images, gif)
    return {'ships': nships, 'frames': frames, 'clocks': total, 'phases': clocks,
            'pixels': pixels, 'lines': nrec_tot, 'stalls': cpu.stall_clocks - stall0,
            'frame_clocks': frame_clocks, 'vframes': vframes,
            'verts': sum(len(gw.MODELS[s[0]]['v']) for s in ships),
            'faces': sum(len(gw.MODELS[s[0]]['f']) for s in ships),
            'edges': sum(len(gw.MODELS[s[0]]['e']) for s in ships)}


def run_rom(frames):
    """the ROM build (wire3d_rom.asm, build\\wire3d.bat) from power-up, as the
    board runs it: boot loader, the stub's copy to RAM, then the program"""
    mem, syms, _ = ps.assemble(open(os.path.join(HERE, 'wire3d_rom.asm')).read(), HERE)
    cpu = ps.Cpu({}, rom=ps.build_rom(mem))
    cpu.stalls = True
    model = gw.Model(gw.ship_set(4))
    fe = syms['W_FE_MARK']
    for f in range(frames):
        while cpu.pc != fe:
            cpu.step()
        cpu.step()
        if picture(cpu.mem) != gw.screen_of(model.frame()):
            raise AssertionError('ROM build, frame %d: picture differs' % (f + 1))
    print('ROM build: %d frames match the model, %.2f s from power-up'
          % (frames, cpu.clocks / CLK))


def save_gif(images, path):
    frames = []
    durs = []
    for img, clk in images:
        frames.append(img.resize((320, 240)).convert('P', palette=0, colors=4))
        durs.append(max(20, round(clk / CLK * 1000 / 10) * 10))
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durs, loop=0,
                   optimize=True)
    print('wrote %s (%d frames)' % (path, len(frames)))


def report(r):
    f = r['frames']
    print()
    print('%d ships, %d vertices, %d faces, %d edges; %d frames, %d clocks (%.2f s), '
          '%.1f fps (video frames counted by the program: %d)'
          % (r['ships'], r['verts'], r['faces'], r['edges'], f, r['clocks'], r['clocks'] / CLK,
             f * CLK / r['clocks'], r['vframes']))
    print('per frame: %.1f lines, %.0f pixels drawn (and as many erased)'
          % (r['lines'] / f, r['pixels'] / f / 2))
    for k, v in sorted(r['phases'].items(), key=lambda kv: -kv[1]):
        print('  %-28s %9.0f clocks a frame  %5.1f %%' % (k, v / f, 100 * v / r['clocks']))
    ph = r['phases']
    print('per vertex (matrix and transform): %.0f clocks'
          % ((ph.get('transform + project', 0)) / f / r['verts']))
    print('per face: %.0f clocks' % (ph.get('faces (hidden lines)', 0) / f / r['faces']))
    print('per edge (all, visible or not): %.0f clocks; per line record: %.0f'
          % (ph.get('line setup (records)', 0) / f / r['edges'],
             ph.get('line setup (records)', 0) / max(1, r['lines'])))
    dr = ph.get('draw (new records)', 0) + ph.get('erase (old records)', 0)
    print('draw + erase: %.1f clocks a pixel (with the record start-up)' % (dr / max(1, r['pixels'])))
    print('video stall clocks: %.1f %%' % (100 * r['stalls'] / r['clocks']))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--ships', type=int, default=4)
    ap.add_argument('--frames', type=int, default=40)
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
    r = run(a.ships, a.frames, gif=a.gif, check=not a.no_check, png=a.png, quiet=a.quiet,
            pace=a.pace)
    report(r)
    print('PASS' if not a.no_check else 'done (not checked)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))


def bench_lines(syms, mem, lib):
    """clocks a pixel of the line loops alone, for each kind of line (draw
    pass, stalls modeled), by running drawl on records made by the program's
    own setup (ls) for lines across the picture"""
    cpu = make_cpu(mem, syms, lib)
    while cpu.pc != syms['frame']:
        cpu.step()
    z = lambda n: 0x20 + gw.ZP.index(n)
    halt = syms['fe_mark']
    res = {}
    cases = {'horizontal (x-major)': (0, 120, 319, 120),
             'shallow 1:4 (x-major)': (0, 80, 319, 160),
             'diagonal 1:1': (20, 8, 250, 238),
             'steep 4:1 (y-major)': (100, 8, 157, 238),
             'vertical (y-major)': (200, 8, 200, 238)}
    for name, (x0, y0, x1, y1) in cases.items():
        npx = len(gw.line_pixels(x0, y0, x1, y1))
        # make the record with ls, then run it; ls returns through ed_next
        cpu.mem[z('par')] = 0
        cpu.mem[z('nrec')] = 0
        for n, v in (('x0l', x0 & 255), ('x0h', x0 >> 8), ('y0', y0),
                     ('x1l', x1 & 255), ('x1h', x1 >> 8), ('y1', y1)):
            cpu.mem[z(n)] = v
        cpu.pc = syms['ls']
        c0 = cpu.clocks
        while cpu.pc != syms['ed_next']:
            cpu.step()
        setup = cpu.clocks - c0
        cpu.mem[z('rk')] = 0
        cpu.mem[z('rend')] = 1
        cpu.mem[0x04] = halt & 255
        cpu.mem[0x05] = halt >> 8
        cpu.ac = 0
        cpu.pc = syms['drawl']
        c0 = cpu.clocks
        while cpu.pc != halt:
            cpu.step()
        run_ = cpu.clocks - c0
        res[name] = (npx, setup, run_)
    return res
