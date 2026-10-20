#!/usr/bin/env python3
"""
gen_menu_rom.py - build the menu ROM: the demo programs in one 64 KB ROM
image with a menu that runs them in turn (docs/MENU.md, menu.asm)

    python3 gen_menu_rom.py                writes menu_data.asm and menu.hex
                                           (the whole ROM)
    python3 gen_menu_rom.py --rotate 30 --hold 20 --idle 2
                                           short times, for the simulator

The programs are assembled from their .asm files as they are (run their
generators first after a change).  Two kinds:

  ROM programs (text demo, ray caster) run in place.  Their pages must not
  overlap (gen_raycast.py uses only the pages text_demo.asm leaves free);
  x6000-x6003, their own jump to the entry, is the menu's jump here.
  RAM programs (CPU test, pi, Mandelbrot, Game of Life) were written to run
  from RAM x0000 with map FF.  The menu copies one into the RAM when it
  runs it, so they are stored packed:
    - the one with the most bytes in x0100-x1EFF keeps those bytes at the
      same address in ROM section 0 (the zero page reads RAM while any
      program runs, so that ROM is free); the menu copies those pages with
      map 00 (pages P_IA up to P_IB in menu_data.asm);
    - every other byte goes in runs (destination, length up to 256, gaps
      of a few zero bytes merged) stored one after the other in the free
      ROM: x2800-x3FFF, x4000-x4FFF, x5400-x5FFF and xBF00-xBFFF.  The
      menu reads them with map 01.
  The RAM is cleared to x49FF first, as the boot loader's copy leaves it.

menu.hex is the whole ROM as one hex string: rom_boot.asm, the library
(rom_lib.asm), menu.asm with menu_data.asm, and the two ROM programs.
gen_rom.tcl takes it as ::ASM_FILE as it is (65536 bytes is a whole ROM
image), and build\\menu.bat builds the FPGA with it.

Date: 10/20/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402

# (file, kind, entry label, name shown in the menu)
PROGRAMS = [
    ('cpu_test.asm', 'ram', None, 'CPU test        every instruction, checked on a pass / fail grid'),
    ('pi_spigot.asm', 'ram', None, 'Pi              1000 digits with a spigot, timed'),
    ('mandelbrot.asm', 'ram', None, 'Mandelbrot      the set in 1, 2, 4 and 8 bpp, timed'),
    ('game_of_life.asm', 'ram', None, 'Game of Life    632 x 480 cells, 1000 generations'),
    ('text_demo.asm', 'rom', 'td_main', 'Text demo       four color depths, scrolling, live RAM test'),
    ('raycast.asm', 'rom', 'main', 'Ray caster      first person 3D, walk with the arrow keys'),
]

# programs whose whole run is longer than the usual limit (seconds); on the
# board Mandelbrot takes about 113 s plus a 5 s pause after each of 4 modes
LIMIT_S = {'mandelbrot.asm': 180}

FRAME_HZ = 25.175e6 / (800 * 525)       # 59.94 frames a second
MENU_CODE = (0x2000, 0x2600)            # menu.asm
MENU_DATA = 0x2600                      # menu_data.asm tables and id code
DATA_REGIONS = [(0x2800, 0x4000), (0x4000, 0x5000), (0x5400, 0x6000), (0xBF00, 0xC000)]
ID_RANGE = (0x0100, 0x1F00)             # kept in place in ROM section 0
LOADER_ZP = range(0xF0, 0xFA)           # menu.asm L_PG-L_T
RAM_TOP = 0x4A00                        # RAM programs end below this
MENU_BLK = (0x5D00, 0x5D30)
GAP = 6                                 # merge runs this close


def assemble(name):
    return ps.assemble(open(os.path.join(HERE, name)).read(), HERE)


def runs_of(addrs):
    """sorted addresses -> [(start, length)], gaps up to GAP merged, at most 256"""
    out = []
    for a in addrs:
        if out and a - (out[-1][0] + out[-1][1]) <= GAP and a - out[-1][0] < 256:
            out[-1] = (out[-1][0], a - out[-1][0] + 1)
        else:
            out.append((a, 1))
    return out


def assemble_menu(data_src):
    """menu.asm with this menu_data.asm text in place of its #include"""
    src = open(os.path.join(HERE, 'menu.asm')).read()
    inc = '#include "menu_data.asm"'
    assert inc in src
    return ps.assemble(src.replace(inc, data_src), HERE)


def build(rotate_s=120.0, hold_s=10.0, idle_s=120, rotate_frames=None, hold_frames=None,
          write=True, quiet=False):
    lib, _, _ = assemble('rom_lib.asm')
    boot, _, _ = assemble('rom_boot.asm')
    rom = {}

    def put(a, v, who):
        if a in rom and rom[a][0] != v:
            raise SystemExit('ROM x%04X: %s and %s both use it' % (a, rom[a][1], who))
        rom[a] = (v, who)

    progs = []
    for fname, kind, entry, title in PROGRAMS:
        mem, syms, _ = assemble(fname)
        own = {a: v for a, v in mem.items()
               if not (ps.lib_area(a) and a in lib and lib[a] == v)}
        p = dict(file=fname, kind=kind, title=title, own=own)
        if kind == 'rom':
            p['entry'] = syms[entry]
            for a in range(0x6000, 0x6004):
                own.pop(a, None)
            bad = [a for a in own if not (0x6000 <= a < 0xC000)]
            if bad:
                raise SystemExit('%s has bytes outside x6000-xBFFF (x%04X)' % (fname, bad[0]))
        else:
            for a in own:
                if a >= RAM_TOP or MENU_BLK[0] <= a < MENU_BLK[1]:
                    raise SystemExit('%s has a byte at x%04X' % (fname, a))
                if a in LOADER_ZP:
                    raise SystemExit('%s has a byte at x%04X (the loader\'s zero page)' % (fname, a))
        progs.append(p)

    # the RAM program with the most bytes in x0100-x1EFF keeps them in place
    ram = [p for p in progs if p['kind'] == 'ram']
    idp = max(ram, key=lambda p: sum(1 for a in p['own'] if ID_RANGE[0] <= a < ID_RANGE[1]))
    idp['id'] = sorted(a for a in idp['own'] if ID_RANGE[0] <= a < ID_RANGE[1])

    def place(data_start):
        regions = [list(r) for r in DATA_REGIONS]
        regions[0][0] = data_start
        run_tab, blob = [], {}
        for p in progs:
            if p['kind'] != 'ram':
                continue
            keep = set(p.get('id', []))
            addrs = sorted(a for a in p['own'] if a not in keep)
            p['rf'] = len(run_tab)
            for start, n in runs_of(addrs):
                while n:
                    while regions and regions[0][0] >= regions[0][1]:
                        regions.pop(0)
                    if not regions:
                        raise SystemExit('the RAM programs do not fit the free ROM')
                    src = regions[0][0]
                    k = min(n, regions[0][1] - src)
                    for i in range(k):
                        blob[src + i] = p['own'].get(start + i, 0)
                    run_tab.append((src, start, k))
                    regions[0][0] += k
                    start += k
                    n -= k
            p['re'] = len(run_tab)
        if len(run_tab) > 255:
            raise SystemExit('%d runs, more than 255' % len(run_tab))
        return run_tab, blob, regions

    rot = rotate_frames if rotate_frames is not None else int(round(rotate_s * FRAME_HZ))
    hold = hold_frames if hold_frames is not None else int(round(hold_s * FRAME_HZ))
    for p in progs:
        lim = LIMIT_S.get(p['file'])
        # (with rotate_frames, as in test_menu.py, scaled the same way)
        p['rot'] = int(round(rot * lim / rotate_s)) if lim else rot

    data_start = DATA_REGIONS[0][0]
    while True:
        run_tab, blob, regions = place(data_start)
        # ---------------------------------------------------------------- menu_data.asm
        o = []
        o.append('; menu_data.asm - generated by gen_menu_rom.py, do not edit')
        o.append('; The program table, names and screen text of the menu (menu.asm), and')
        o.append('; the RAM programs packed into the free ROM (gen_menu_rom.py says how).')
        o.append(';')
        o.append('; Date: 10/20/2026')
        o.append('')
        o.append('NPROG       = %d' % len(progs))
        o.append('ROT_FRAMES  = %d          ; %.0f s in turn' % (rot, rot / FRAME_HZ))
        o.append('HOLD_FRAMES = %d          ; %.0f s to show a finished result' % (hold, hold / FRAME_HZ))
        o.append('IDLE_SECS   = %d          ; menu idle time before running in turn again' % idle_s)
        o.append('')
        o.append('#addr 0x%04X' % MENU_DATA)

        def tab(label, vals):
            o.append('%s:' % label)
            o.append('    #d8 ' + ', '.join(vals))

        # run tables first, each inside one page
        names = ['R_SH', 'R_SL', 'R_DH', 'R_DL', 'R_N']
        cols = [[s >> 8 for s, d, n in run_tab], [s & 0xFF for s, d, n in run_tab],
                [d >> 8 for s, d, n in run_tab], [d & 0xFF for s, d, n in run_tab],
                [n & 0xFF for s, d, n in run_tab]]
        o.append('; runs: source, destination, length (0 = 256) of run i')
        addr = MENU_DATA
        for name, vals in zip(names, cols):
            n = max(len(vals), 1)
            if (addr & 0xFF) + n > 0x100:
                addr = (addr | 0xFF) + 1
            o.append('#addr 0x%04X' % addr)
            o.append('%s:' % name)
            for i in range(0, len(vals), 16):
                o.append('    #d8 ' + ', '.join('0x%02X' % v for v in vals[i:i + 16]))
            if not vals:
                o.append('    #d8 0x00')
            addr += n
        # program table, screen text
        longer = ''.join(' (%s %d)' % (p['title'].split('  ')[0], round(p['rot'] / FRAME_HZ / 60))
                         for p in progs if p['rot'] != rot)
        sec_text = 'With no key pressed, the programs run in turn again in'
        sec_col = LIST_COL + len(sec_text) + 1
        text = [
            (17, 3, 'P L A C A R D       D E M O       P R O G R A M S'),
            (LIST_COL, 9, 'Pick a program:'),
            (LIST_COL, 26, 'Up / Down or 1-%d choose, Enter runs it.  Esc in a program comes back.' % len(progs)),
            (LIST_COL, 30, sec_text),
            (sec_col + 4, 30, 's.'),
            (LIST_COL, 32, 'In turn, each runs until it is done, or for %d minutes%s.' % (round(rot / FRAME_HZ / 60), longer)),
        ]
        ntab = 9 * len(progs) + 2 * len(progs) + 4 * len(text) + 1
        if (addr & 0xFF) + ntab > 0x100:
            addr = (addr | 0xFF) + 1
        o.append('#addr 0x%04X' % addr)
        o.append('LIST_ROW    = %d' % LIST_ROW)
        o.append('LIST_COL    = %d' % LIST_COL)
        o.append('SEC_ROW     = 30')
        o.append('SEC_COL     = %d' % sec_col)

        def tab(label, vals):
            o.append('%s:' % label)
            o.append('    #d8 ' + ', '.join(vals))

        tab('P_RL', ['0x%02X' % (p['rot'] & 0xFF) for p in progs])
        tab('P_RH', ['0x%02X' % (p['rot'] >> 8) for p in progs])
        tab('P_KIND', ['%d' % (p['kind'] == 'ram') for p in progs])
        tab('P_EH', ['0x%02X' % (p.get('entry', 0) >> 8) for p in progs])
        tab('P_EL', ['0x%02X' % (p.get('entry', 0) & 0xFF) for p in progs])
        tab('P_RF', ['%d' % p.get('rf', 0) for p in progs])
        tab('P_RE', ['%d' % p.get('re', 0) for p in progs])
        tab('P_IA', ['0x%02X' % (p['id'][0] >> 8) if 'id' in p else '0' for p in progs])
        tab('P_IB', ['0x%02X' % ((p['id'][-1] >> 8) + 1) if 'id' in p else '0' for p in progs])
        tab('NAME_L', ['nm_%d & 0xFF' % i for i in range(len(progs))])
        tab('NAME_H', ['nm_%d >> 8' % i for i in range(len(progs))])
        tab('TEXT_COL', ['%d' % c for c, r, s in text] + ['0'])
        tab('TEXT_ROW', ['%d' % r for c, r, s in text])
        tab('TEXT_L', ['tx_%d & 0xFF' % i for i in range(len(text))])
        tab('TEXT_H', ['tx_%d >> 8' % i for i in range(len(text))])
        for i, (c, r, s) in enumerate(text):
            assert c + len(s) <= 80, s
            o.append('tx_%d: #d "%s", 0x00' % (i, s))
        for i, p in enumerate(progs):
            o.append('nm_%d: #d " %d  %-62s", 0x00' % (i, i + 1, p['title']))
            assert LIST_COL + 66 <= 80

        # the data
        o.append('')
        o.append('; the RAM programs\' bytes')
        for i, p in enumerate(progs):
            if 'id' not in p:
                continue
            ids = p['id']
            o.append('; %s, x%04X-x%04X, in place' % (p['file'], ids[0], ids[-1]))
            for start, n in runs_of(ids):
                o.append('#addr 0x%04X' % start)
                vals = [p['own'].get(start + k, 0) for k in range(n)]
                for k in range(0, n, 16):
                    o.append('    #d8 ' + ', '.join('0x%02X' % v for v in vals[k:k + 16]))
        head = '\n'.join(o) + '\n'
        for src, dst, n in run_tab:
            o.append('#addr 0x%04X                 ; -> x%04X' % (src, dst))
            vals = [blob[src + k] for k in range(n)]
            for k in range(0, n, 16):
                o.append('    #d8 ' + ', '.join('0x%02X' % v for v in vals[k:k + 16]))
        src = '\n'.join(o) + '\n'

        mem, syms, _ = assemble_menu(head)
        head_end = max(a for a in mem if MENU_DATA <= a < 0x4000) + 1
        if head_end <= data_start:
            mem, syms, _ = assemble_menu(src)
            break
        data_start = head_end
    code_end = max(a for a in mem if MENU_CODE[0] <= a < MENU_CODE[1])
    tab_end = data_start - 1
    if write:
        open(os.path.join(HERE, 'menu_data.asm'), 'w', newline='\n').write(src)

    # ---------------------------------------------------------------- the ROM
    for a, v in boot.items():
        put(a, v, 'rom_boot.asm')
    for a, v in lib.items():
        if ps.lib_area(a):
            put(a, v, 'the library')
    for a, v in mem.items():
        if ps.lib_area(a) and a in lib:
            continue
        put(a, v, 'menu.asm')
    for p in progs:
        if p['kind'] == 'rom':
            for a, v in p['own'].items():
                put(a, v, p['file'])
    put(ps.BOOT_MODE, 0, 'boot mode (ROM program)')
    image = bytes(rom.get(a, (0,))[0] for a in range(0x10000))
    if write:
        with open(os.path.join(HERE, 'menu.hex'), 'w') as f:
            f.write(image.hex().upper() + '\n')

    # report
    if quiet:
        return {a: v for a, (v, _) in rom.items()}, syms, progs
    print('menu.asm code x%04X-x%04X, tables and copy code x%04X-x%04X'
          % (MENU_CODE[0], code_end, MENU_DATA, tab_end))
    for p in progs:
        if p['kind'] == 'rom':
            print('  %-17s ROM, in place, %5d bytes, entry x%04X'
                  % (p['file'], len(p['own']), p['entry']))
        else:
            nid = len(p.get('id', []))
            print('  %-17s RAM, %5d bytes: %3d runs%s'
                  % (p['file'], len(p['own']), p['re'] - p['rf'],
                     ', x%04X-x%04X in place' % (p['id'][0], p['id'][-1]) if nid else ''))
    used = sum(n for s, d, n in run_tab)
    free = sum(e - s for s, e in regions)
    print('runs: %d, %d bytes; free in the data regions: %d bytes' % (len(run_tab), used, free))
    print('rotate %d frames, hold %d frames, idle %d s' % (rot, hold, idle_s))
    if write:
        print('wrote menu_data.asm and menu.hex (the whole ROM)')
    return {a: v for a, (v, _) in rom.items()}, syms, progs


LIST_ROW, LIST_COL = 12, 6     # text row of program 1 (then every other row), column


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--rotate', type=float, default=120.0, help='seconds each program runs in turn')
    ap.add_argument('--hold', type=float, default=10.0, help='seconds a finished result stays')
    ap.add_argument('--idle', type=int, default=120, help='menu seconds with no key before running in turn')
    ap.add_argument('--rotate-frames', type=int, help='the same in frames (overrides --rotate)')
    ap.add_argument('--hold-frames', type=int, help='the same in frames (overrides --hold)')
    a = ap.parse_args(argv)
    build(a.rotate, a.hold, a.idle, a.rotate_frames, a.hold_frames)


if __name__ == '__main__':
    main(sys.argv[1:])
