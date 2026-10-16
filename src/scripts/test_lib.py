#!/usr/bin/env python3
"""
test_lib.py - test placard_lib.asm in the instruction-level simulator

    python3 test_lib.py              run every test
    python3 test_lib.py -k div       run the tests whose name contains "div"
    python3 test_lib.py --quick      fewer random cases

Each routine is called through the standard CALL sequence from a small
driver, with its inputs written straight into the simulator's memory.  The
test checks the outputs against a Python model, and also checks that the
routine changed nothing in the zero page except what its documentation in
placard_lib.asm says it changes (AC, X, the listed R and T registers, LINK,
SAVE_AC and the bytes above SP).  The clock counts it prints are what
LIBRARY.md quotes.

The simulator does not model the video line read at x5000, so this script
supplies it: a read of x5000-x50FF returns V9:V2 of a V counter that steps
every 800 clocks through 499-1023 (525 lines, one frame = 420,000 clocks).

Date: 10/16/2026
"""

import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402

CLOCKS_PER_LINE = 800
LINES = 525
FRAME = CLOCKS_PER_LINE * LINES

# driver: AC from ARG_AC, call the routine, save AC and X, halt
ARG_AC, OUT_AC, OUT_X = 0x20, 0x21, 0x22

ROUTINES = ['vid_addr', 'map_set', 'frame_poll', 'wait_frames', 'rand8',
            'add16', 'sub16', 'mul8', 'memset', 'div8', 'div16', 'memcpy',
            'vid_clear', 'vid_mode', 'plot1', 'con_scroll', 'con_putc',
            'con_newline', 'con_home', 'con_clear', 'con_puts', 'con_hex8',
            'con_dec16', 'con_dec8']

# zero page bytes each routine may change, besides LINK, SAVE_AC, the
# driver's outputs and the free stack area (from the routine headers)
T = {('T%d' % i): 0x18 + i for i in range(8)}
R = {('R%d' % i): 0x10 + i for i in range(8)}
Z = dict(T, **R, FRAME_LO=0x08, FRAME_HI=0x09, LINE_LAST=0x0A, RAND_LO=0x0B,
         RAND_HI=0x0C, CUR_COL=0x0D, CUR_ROW=0x0E, MAP_SHADOW=0x07)


def zset(*names):
    out = set()
    for n in names:
        if '-' in n:                       # T0-T5
            a, b = n.split('-')
            out |= {Z[a] + i for i in range(Z[b] - Z[a] + 1)}
        else:
            out.add(Z[n])
    return out


CHANGES = {
    'vid_addr': zset('T0', 'T1', 'T4'),
    'map_set': zset('MAP_SHADOW'),
    'frame_poll': zset('T0', 'FRAME_LO', 'FRAME_HI', 'LINE_LAST'),
    'wait_frames': zset('T0', 'T1', 'FRAME_LO', 'FRAME_HI', 'LINE_LAST'),
    'rand8': zset('T0', 'RAND_LO', 'RAND_HI'),
    'add16': zset('R0', 'R1', 'T0-T2'),
    'sub16': zset('R0', 'R1', 'T0-T2'),
    'mul8': zset('R2', 'R3', 'T0-T4'),
    'div8': zset('T0-T3'),
    'div16': zset('R0', 'R1', 'T1-T3'),
    'memset': zset('R0', 'R1', 'R2', 'T0'),
    'memcpy': zset('R0-R4'),
    'vid_clear': zset('T0', 'T1'),
    'vid_mode': zset('T0'),
    'plot1': zset('T0-T6'),
    'con_putc': zset('T0-T5', 'CUR_COL', 'CUR_ROW'),
    'con_newline': zset('T0-T5', 'CUR_COL', 'CUR_ROW'),
    'con_home': zset('CUR_COL', 'CUR_ROW'),
    'con_clear': zset('T0', 'T1', 'CUR_COL', 'CUR_ROW'),
    'con_scroll': zset('T1-T5'),
    'con_puts': zset('R0', 'R1', 'T0-T5', 'CUR_COL', 'CUR_ROW'),
    'con_hex8': zset('T0-T5', 'CUR_COL', 'CUR_ROW'),
    'con_dec8': zset('T0-T7', 'CUR_COL', 'CUR_ROW'),
    'con_dec16': zset('R0', 'R1', 'R2', 'T0-T5', 'CUR_COL', 'CUR_ROW'),
}
ALWAYS = {0x04, 0x05, 0x0F, OUT_AC, OUT_X}


def call(target, n):
    back = 'back_%d' % n
    return ['    ld   LINK_LO, x',
            '    ld   %s, [x]' % back,
            '    ld   LINK_HI, x',
            '    ld   %s >> 8, [x]' % back,
            '    ld   %s >> 8, y' % target,
            '    jmp  %s' % target,
            back + ':']


def build_source(extra=()):
    src = ['#include "placard.asm"', '#include "placard_lib.asm"', '',
           '#addr 0x0000', 'reset:', '    ld   main >> 8, y', '    jmp  main', '',
           '#addr 0x0100', 'main:', '    bra  main']
    n = 0
    for r in ROUTINES:
        if n % 6 == 0:
            src.append('#addr 0x%04X' % (0x0200 + (n // 6) * 0x100))
        src.append('drv_%s:' % r)
        src.append('    ld   [0x%02X], ac' % ARG_AC)
        src += call(r, n)
        src += ['    ld   ac, [0x%02X]' % OUT_AC,
                '    ld   x, ac',
                '    ld   ac, [0x%02X]' % OUT_X,
                'halt_%s:' % r,
                '    bra  halt_%s' % r]
        n += 1
    src += list(extra)
    return '\n'.join(src) + '\n'


class Mem(bytearray):
    """RAM plus the video line read at x5000-x50FF"""
    cpu = None

    def __getitem__(self, i):
        if isinstance(i, int) and 0x5000 <= i <= 0x50FF and self.cpu is not None:
            line = (self.cpu.clocks // CLOCKS_PER_LINE) % LINES
            return (499 + line) >> 2
        return bytearray.__getitem__(self, i)


class Lib:
    def __init__(self, extra=()):
        self.mem, self.syms, _ = ps.assemble(build_source(extra), HERE)
        self.image = bytearray(65536)
        for a, v in self.mem.items():
            self.image[a] = v

    def cpu(self):
        c = ps.Cpu({})
        c.mem = Mem(self.image)
        c.mem.cpu = c
        return c

    def call(self, name, ac=0, zp=None, cpu=None, clocks0=0, max_steps=5_000_000):
        """run one call; returns (cpu, clocks for CALL + routine + RETURN)"""
        c = cpu or self.cpu()
        c.clocks = clocks0
        c.mem[SP] = c.mem[SP] or 0xFF
        c.mem[ARG_AC] = ac & 0xFF
        for k, v in (zp or {}).items():
            c.mem[Z[k] if isinstance(k, str) else k] = v & 0xFF
        before = bytes(c.mem[0:256])
        c.pc = self.syms['drv_' + name]
        start = c.clocks
        steps0 = c.steps
        halt = self.syms['halt_' + name]
        while c.pc != halt:
            c.step()
            if c.steps - steps0 > max_steps:
                raise AssertionError('%s did not return' % name)
        clocks = c.clocks - start - 3 - 3 - 2 - 3      # less the driver's own moves
        c.ac = c.mem[OUT_AC]                            # the routine's AC
        after = bytes(c.mem[0:256])
        sp = c.mem[SP]
        allowed = CHANGES[name] | ALWAYS | set(range(0xC0, 0x100))
        bad = [a for a in range(256) if before[a] != after[a] and a not in allowed]
        assert not bad, '%s changed zero page %s' % (name, ', '.join('%02X' % a for a in bad))
        assert sp == before[SP], '%s left SP %02X, was %02X' % (name, sp, before[SP])
        return c, clocks


SP = 0x06


class Stats:
    def __init__(self):
        self.d = {}

    def add(self, name, clocks):
        lo, hi, n, tot = self.d.get(name, (clocks, clocks, 0, 0))
        self.d[name] = (min(lo, clocks), max(hi, clocks), n + 1, tot + clocks)

    def report(self):
        print('\nclocks per call (CALL + routine + RETURN):')
        for k, (lo, hi, n, tot) in self.d.items():
            print('  %-12s min %8d  max %8d  mean %10.0f  (%d calls)' % (k, lo, hi, tot / n, n))


STATS = Stats()


# ---------------------------------------------------------------------------
# screen helpers (same layout as placard_sim.render)
# ---------------------------------------------------------------------------
def byte_addr(col, row):
    return 0x6020 + col * 512 + row


def mode_addr(row):
    return 0x5A20 + row


def rep_addr(col, row, mode):
    """byte address of a row in line repeat mode (bits 3:2 of the mode byte)"""
    return 0x6000 + col * 512 + ps.row_offset(row, mode)


def font_rows(lib):
    base = lib.syms['LIB_FONT']
    return {c: tuple(lib.image[base + k * 256 + c] for k in range(8)) for c in range(256)}


def read_text(lib, mem, row, cols=range(0, 80)):
    glyphs = {}
    for c, rows in font_rows(lib).items():
        glyphs.setdefault(rows, c)
    out = ''
    for col in cols:
        cell = tuple(mem[byte_addr(col, row * 8 + k)] for k in range(8))
        ch = glyphs.get(cell)
        out += '?' if ch is None else chr(ch) if 0x20 <= ch < 0x7F else ' ' if ch == 0 else '?'
    return out.rstrip()


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------
def t_add_sub(lib, n):
    cases = [(0, 0), (0xFFFF, 1), (0x00FF, 0x0001), (0x8000, 0x8000), (0x7FFF, 0x0001),
             (0x0080, 0x0080), (0x00FF, 0x00FF), (0x1234, 0xFEDC)]
    cases += [(random.randrange(65536), random.randrange(65536)) for _ in range(n)]
    for a, b in cases:
        zp = {'R0': a, 'R1': a >> 8, 'R2': b, 'R3': b >> 8}
        c, k = lib.call('add16', zp=zp)
        STATS.add('add16', k)
        got = c.mem[0x10] | c.mem[0x11] << 8
        assert got == (a + b) & 0xFFFF, 'add16 %04X + %04X = %04X' % (a, b, got)
        assert c.ac == c.mem[0x11]
        c, k = lib.call('sub16', zp=zp)
        STATS.add('sub16', k)
        got = c.mem[0x10] | c.mem[0x11] << 8
        assert got == (a - b) & 0xFFFF, 'sub16 %04X - %04X = %04X' % (a, b, got)
        assert c.ac == c.mem[0x11]


def t_mul8(lib, n):
    cases = [(0, 0), (255, 255), (1, 255), (255, 1), (128, 2), (16, 16), (200, 0)]
    cases += [(random.randrange(256), random.randrange(256)) for _ in range(n)]
    for a, b in cases:
        c, k = lib.call('mul8', zp={'R0': a, 'R1': b})
        STATS.add('mul8', k)
        got = c.mem[0x12] | c.mem[0x13] << 8
        assert got == a * b, 'mul8 %d * %d = %d' % (a, b, got)
        assert c.ac == c.mem[0x13]


def t_div8(lib, n):
    cases = [(255, 1), (255, 255), (0, 7), (254, 255), (255, 128), (128, 129), (200, 3), (7, 0)]
    cases += [(random.randrange(256), random.randrange(1, 256)) for _ in range(n)]
    for a, b in cases:
        c, k = lib.call('div8', zp={'R0': a, 'R1': b})
        STATS.add('div8', k)
        q, r = (a // b, a % b) if b else (255, a)
        assert (c.ac, c.x) == (q, r), 'div8 %d / %d = %d r %d' % (a, b, c.ac, c.x)


def t_div16(lib, n):
    cases = [(65535, 1), (65535, 255), (0, 9), (65535, 10), (12345, 10), (256, 129), (65280, 255)]
    cases += [(random.randrange(65536), random.randrange(1, 256)) for _ in range(n)]
    for a, b in cases:
        c, k = lib.call('div16', zp={'R0': a, 'R1': a >> 8, 'R2': b})
        STATS.add('div16', k)
        q = c.mem[0x10] | c.mem[0x11] << 8
        assert (q, c.ac, c.x) == (a // b, a % b, a % b), \
            'div16 %d / %d = %d r %d' % (a, b, q, c.ac)


def xorshift16(x):
    x ^= (x << 7) & 0xFFFF
    x ^= x >> 9
    x ^= (x << 8) & 0xFFFF
    return x


def t_rand8(lib, n):
    x = 0x1234
    c = lib.cpu()
    c.mem[0x0B], c.mem[0x0C] = x & 0xFF, x >> 8
    for _ in range(n):
        c, k = lib.call('rand8', cpu=c)
        STATS.add('rand8', k)
        x = xorshift16(x)
        assert (c.mem[0x0C] << 8 | c.mem[0x0B]) == x and c.ac == x & 0xFF, 'rand8 state'
    y, period = 1, 0
    while True:
        y = xorshift16(y)
        period += 1
        if y == 1:
            break
    assert period == 65535, 'xorshift16 period %d' % period


def t_memory(lib, n):
    for i in range(n):
        dst = random.randrange(0x0800, 0x2E00)
        cnt = random.choice([1, 2, 255, 256, random.randrange(1, 257)])
        val = random.randrange(256)
        c = lib.cpu()
        c, k = lib.call('memset', ac=val, cpu=c, zp={'R0': dst, 'R1': dst >> 8, 'R2': cnt})
        STATS.add('memset', k)
        assert all(c.mem[dst + j] == val for j in range(cnt)), 'memset'
        assert c.mem[dst + cnt] == 0 and c.mem[dst - 1] == 0, 'memset wrote outside'
        end = dst + cnt
        assert (c.mem[0x10] | c.mem[0x11] << 8, c.mem[0x12]) == (end, 0)
        # memcpy from random data
        src = random.randrange(0x0800, 0x1800)
        dst = random.randrange(0x1A00, 0x2E00)
        data = [random.randrange(256) for _ in range(cnt)]
        c = lib.cpu()
        for j, v in enumerate(data):
            c.mem[src + j] = v
        c, k = lib.call('memcpy', cpu=c, zp={'R0': src, 'R1': src >> 8, 'R2': dst,
                                             'R3': dst >> 8, 'R4': cnt})
        STATS.add('memcpy', k)
        assert [c.mem[dst + j] for j in range(cnt)] == data, 'memcpy'
        assert c.mem[dst + cnt] == 0 and c.mem[dst - 1] == 0, 'memcpy wrote outside'


def t_vid_addr(lib, n):
    cases = [(0, 0), (79, 479), (1, 223), (1, 224), (5, 255), (5, 256)]
    cases += [(random.randrange(80), random.randrange(480)) for _ in range(n)]
    for col, row in cases:
        c, k = lib.call('vid_addr', ac=col, zp={'R2': row, 'R3': row >> 8})
        STATS.add('vid_addr', k)
        assert (c.ac << 8 | c.x) == byte_addr(col, row), 'vid_addr %d %d' % (col, row)
    # line repeat: the row's own mode byte picks the address
    for mode in (0x04, 0x08, 0x0C, 0x07, 0x0B):
        seen = {}
        for row in list(range(480)) if n else [0, 1, 223, 224, 255, 256, 479]:
            col = random.randrange(80)
            c = lib.cpu()
            c.mem[mode_addr(row)] = mode
            c, k = lib.call('vid_addr', ac=col, cpu=c, zp={'R2': row, 'R3': row >> 8})
            STATS.add('vid_addr %dx' % (2 if mode & 0x0C == 4 else 4), k)
            got = c.ac << 8 | c.x
            assert got == rep_addr(col, row, mode), 'vid_addr mode %02X %d %d' % (mode, col, row)
            off = got - 0x6000 - col * 512
            rows = 2 if mode & 0x0C == 4 else 4
            seen.setdefault(off, set()).add(row // rows)
        assert all(len(v) == 1 for v in seen.values()), 'vid_addr mode %02X: groups share a byte' % mode


def t_vid_clear(lib, n):
    for mode in (0, 3):
        c = lib.cpu()
        for a in range(0x5A00, 0x5C00):
            c.mem[a] = 0xA5
        for a in range(0x6000, 0x10000):
            c.mem[a] = 0xA5
        c, k = lib.call('vid_clear', ac=mode, cpu=c)
        STATS.add('vid_clear', k)
        assert all(c.mem[a] == 0 for a in range(0x6000, 0x10000)), 'vid_clear pixels'
        assert all(c.mem[mode_addr(r)] == mode for r in range(480)), 'vid_clear modes'
        assert all(c.mem[a] == 0xA5 for a in range(0x5A00, 0x5A20)), 'vid_clear x5A00'
        c, k = lib.call('vid_mode', ac=2, cpu=c)
        STATS.add('vid_mode', k)
        assert all(c.mem[mode_addr(r)] == 2 for r in range(480)), 'vid_mode'
        assert all(c.mem[a] == 0 for a in range(0x6000, 0x10000)), 'vid_mode pixels'


def t_plot1(lib, n):
    c = lib.cpu()
    pts = {(0, 0), (639, 479), (7, 223), (8, 224), (300, 255), (300, 256), (632, 0)}
    pts |= {(random.randrange(640), random.randrange(480)) for _ in range(n)}
    model = bytearray(65536)
    for (x, y) in sorted(pts):
        c, k = lib.call('plot1', ac=1, cpu=c, zp={'R0': x, 'R1': x >> 8, 'R2': y, 'R3': y >> 8})
        STATS.add('plot1', k)
        model[byte_addr(x // 8, y)] |= 1 << (x % 8)
    for (x, y) in sorted(pts)[::2]:
        c, k = lib.call('plot1', ac=0, cpu=c, zp={'R0': x, 'R1': x >> 8, 'R2': y, 'R3': y >> 8})
        STATS.add('plot1', k)
        model[byte_addr(x // 8, y)] &= ~(1 << (x % 8)) & 0xFF
    assert c.mem[0x6000:] == model[0x6000:], 'plot1'
    # 2x rows over the bottom half, 4x over rows 0-95 (1x rows 96-239 keep
    # their own bytes): each pixel lands at its row's remapped address
    c = lib.cpu()
    for r in range(480):
        c.mem[mode_addr(r)] = 0x08 if r < 96 else (0x04 if r >= 240 else 0x00)
    model = bytearray(65536)
    for (x, y) in sorted(pts):
        c, k = lib.call('plot1', ac=1, cpu=c, zp={'R0': x, 'R1': x >> 8, 'R2': y, 'R3': y >> 8})
        STATS.add('plot1 mixed', k)
        model[rep_addr(x // 8, y, c.mem[mode_addr(y)])] |= 1 << (x % 8)
    assert c.mem[0x6000:] == model[0x6000:], 'plot1 line repeat'


def t_console(lib, n):
    c = lib.cpu()
    c, k = lib.call('con_clear', cpu=c)
    STATS.add('con_clear', k)
    assert (c.mem[0x0D], c.mem[0x0E]) == (0, 0)
    for ch in 'Hello, Placard!':
        c, k = lib.call('con_putc', ac=ord(ch), cpu=c)
        STATS.add('con_putc', k)
        assert c.ac == ord(ch)
    assert read_text(lib, c.mem, 0) == 'Hello, Placard!', read_text(lib, c.mem, 0)
    c, k = lib.call('con_newline', cpu=c)
    STATS.add('con_newline', k)
    # string in RAM at x2000
    s = b'The quick brown fox jumps over the lazy dog 0123456789\n2nd line\0'
    for j, v in enumerate(s):
        c.mem[0x2000 + j] = v
    c, k = lib.call('con_puts', cpu=c, zp={'R0': 0x00, 'R1': 0x20})
    STATS.add('con_puts', k)
    assert (c.mem[0x10] | c.mem[0x11] << 8) == 0x2000 + len(s) - 1
    assert read_text(lib, c.mem, 1) == 'The quick brown fox jumps over the lazy dog 0123456789'
    assert read_text(lib, c.mem, 2) == '2nd line'
    assert (c.mem[0x0D], c.mem[0x0E]) == (8, 2)
    # numbers, each on its own line
    c, _ = lib.call('con_home', cpu=c)
    c, _ = lib.call('con_clear', cpu=c)
    vals = sorted({0, 1, 9, 10, 99, 100, 127, 128, 199, 200, 209, 255} |
                  {random.randrange(256) for _ in range(n // 4)})
    for v in vals:
        c.mem[0x0D], c.mem[0x0E] = 0, 0
        c, k = lib.call('con_dec8', ac=v, cpu=c)
        STATS.add('con_dec8', k)
        c, k = lib.call('con_putc', ac=ord(' '), cpu=c)
        c, k = lib.call('con_hex8', ac=v, cpu=c)
        STATS.add('con_hex8', k)
        assert c.ac == v
        got = read_text(lib, c.mem, 0)
        assert got.startswith('%d %02X' % (v, v)), 'dec8/hex8 %d -> %r' % (v, got)
        for col in range(0, 8):
            c.mem[0x0D] = col
            lib.call('con_putc', ac=ord(' '), cpu=c)
    vals = sorted({0, 7, 10, 255, 256, 9999, 10000, 65535} |
                  {random.randrange(65536) for _ in range(n // 4)})
    for v in vals:
        c.mem[0x0D], c.mem[0x0E] = 0, 59
        c, k = lib.call('con_dec16', cpu=c, zp={'R0': v, 'R1': v >> 8})
        STATS.add('con_dec16', k)
        got = read_text(lib, c.mem, 59)
        assert got.startswith(str(v)) and (got + ' ')[len(str(v))] == ' ', \
            'dec16 %d -> %r' % (v, got)
        for col in range(0, 7):
            c.mem[0x0D] = col
            lib.call('con_putc', ac=ord(' '), cpu=c)
    # inverse video
    c.mem[0x0D], c.mem[0x0E] = 10, 30
    lib.call('con_putc', ac=0x80 + ord('A'), cpu=c)
    assert tuple(c.mem[byte_addr(10, 240 + k)] for k in range(8)) == \
        tuple(r ^ 0xFF for r in font_rows(lib)[ord('A')])


def t_scroll(lib, n):
    c = lib.cpu()
    c, _ = lib.call('con_clear', cpu=c)
    lines = ['line %d %s' % (i, '#' * (i % 70)) for i in range(62)]
    for i, line in enumerate(lines):
        for ch in line + '\n':
            c, k = lib.call('con_putc', ac=ord(ch), cpu=c)
            if ch == '\n' and i >= 59:
                STATS.add('con_putc+scroll', k)
    # 62 newlines from row 0: the last 3 scrolled, so row 0 shows line 3
    for r in range(57):
        assert read_text(lib, c.mem, r) == lines[r + 3], 'scroll row %d: %r' % (r, read_text(lib, c.mem, r))
    assert read_text(lib, c.mem, 59) == '', 'scroll: last row not cleared'
    assert (c.mem[0x0D], c.mem[0x0E]) == (0, 59)
    # the mode bytes are not touched
    assert all(c.mem[mode_addr(r)] == 0 for r in range(480))
    c, k = lib.call('con_scroll', cpu=c)
    STATS.add('con_scroll', k)
    assert read_text(lib, c.mem, 0) == lines[4]


def t_frames(lib, n):
    c = lib.cpu()
    c, k = lib.call('frame_poll', cpu=c, clocks0=0)
    frames0 = c.mem[0x08] | c.mem[0x09] << 8
    while c.clocks < 10 * FRAME + 1000:
        c, k = lib.call('frame_poll', cpu=c, clocks0=c.clocks)
        STATS.add('frame_poll', k)
        assert 124 <= c.ac <= 255, 'frame_poll line value %d' % c.ac
    frames = (c.mem[0x08] | c.mem[0x09] << 8) - frames0
    assert frames == 10, 'frame_poll counted %d frames in 10' % frames
    for nf in (1, 3, 6):
        start = random.randrange(FRAME)
        c, k = lib.call('wait_frames', ac=nf, cpu=c, clocks0=start)
        STATS.add('wait_frames(%d)' % nf, k)
        # it ends just after the nf-th frame start (V wraps at clock 0 mod FRAME)
        end = start + k
        assert (nf - 1) * FRAME < k <= nf * FRAME + 200, 'wait_frames(%d) %d clocks' % (nf, k)
        assert end % FRAME < 400, 'wait_frames ended %d clocks into the frame' % (end % FRAME)


def t_map_set(lib, n):
    c, k = lib.call('map_set', ac=0x5A)
    STATS.add('map_set', k)
    assert c.mem[0x07] == 0x5A and c.ac == 0x5A


def t_stack(lib, n):
    """PUSH / POP and a three-deep chain of non-leaf routines"""
    extra = ['#addr 0x1000',
             'stk_test:',
             '    ld   STACK_TOP, ac',
             '    ld   ac, [SP]']
    for v in (0x11, 0x22, 0x33):
        extra += ['    ld   0x%02X, ac' % v, '    ld   [SP], x', '    ld   ac, [x]',
                  '    ld   x, ac', '    dec', '    ld   ac, [SP]', '    ld   [x], ac']
    extra += ['    ld   0x40, ac']
    extra += call('outer', 100)
    extra += ['    ld   ac, [0x30]']               # outer's result
    for i in range(3):
        extra += ['    ld   [SP], ac', '    inc', '    ld   ac, [SP]', '    ld   ac, x',
                  '    ld   [x], ac', '    ld   ac, [0x%02X]' % (0x31 + i)]
    extra += ['stk_halt:', '    bra  stk_halt',
              '#addr 0x1100',
              'outer:',                            # AC + 1, then inner
              '    ld   ac, [SAVE_AC]', '    ld   [SP], x', '    ld   [LINK_HI], ac',
              '    ld   ac, [x]', '    ld   x, ac', '    dec', '    ld   ac, x',
              '    ld   [LINK_LO], ac', '    ld   ac, [x]', '    ld   x, ac', '    dec',
              '    ld   ac, [SP]', '    ld   [SAVE_AC], ac',
              '    inc']
    extra += call('inner', 101)
    extra += ['    ld   lib_leave >> 8, y', '    jmp  lib_leave',
              '#addr 0x1200',
              'inner:',                            # AC * 2 through con-free leaf mul
              '    ld   ac, [SAVE_AC]', '    ld   [SP], x', '    ld   [LINK_HI], ac',
              '    ld   ac, [x]', '    ld   x, ac', '    dec', '    ld   ac, x',
              '    ld   [LINK_LO], ac', '    ld   ac, [x]', '    ld   x, ac', '    dec',
              '    ld   ac, [SP]', '    ld   [SAVE_AC], ac',
              '    ld   ac, [R0]', '    ld   2, ac', '    ld   ac, [R1]']
    extra += call('mul8', 102)
    extra += ['    ld   [R2], ac', '    ld   lib_leave >> 8, y', '    jmp  lib_leave']
    lib2 = Lib(extra)
    c = lib2.cpu()
    c.pc = lib2.syms['stk_test']
    while c.pc != lib2.syms['stk_halt']:
        c.step()
        assert c.steps < 100000
    assert c.mem[0x30] == (0x40 + 1) * 2, 'non-leaf chain result %02X' % c.mem[0x30]
    assert [c.mem[0x31], c.mem[0x32], c.mem[0x33]] == [0x33, 0x22, 0x11], 'push / pop order'
    assert c.mem[SP] == 0xFF, 'SP not restored'


TESTS = [('add16/sub16', t_add_sub), ('mul8', t_mul8), ('div8', t_div8), ('div16', t_div16),
         ('rand8', t_rand8), ('memset/memcpy', t_memory), ('vid_addr', t_vid_addr),
         ('vid_clear/vid_mode', t_vid_clear), ('plot1', t_plot1), ('console', t_console),
         ('scroll', t_scroll), ('frames', t_frames), ('map_set', t_map_set), ('stack', t_stack)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-k', default='')
    ap.add_argument('--quick', action='store_true')
    ap.add_argument('--seed', type=int, default=1970)
    a = ap.parse_args()
    random.seed(a.seed)
    n = 60 if a.quick else 600
    lib = Lib()
    print('library x%04X-x%04X, %d bytes of code' % (
        lib.syms['LIB_CODE'], lib.syms['LIB_FONT'] + 0x7FF,
        sum(1 for k in lib.mem if lib.syms['LIB_CODE'] <= k < lib.syms['LIB_FONT'])))
    fails = 0
    for name, fn in TESTS:
        if a.k not in name:
            continue
        try:
            fn(lib, n)
            print('PASS  %s' % name)
        except AssertionError as ex:
            fails += 1
            print('FAIL  %s: %s' % (name, ex))
    STATS.report()
    print('\n%s' % ('all passed' if not fails else '%d failed' % fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
