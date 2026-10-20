#!/usr/bin/env python3
"""
gen_bringup.py - writes bringup.asm, the bring-up test ROM (docs/BRINGUP.md)

    python3 gen_bringup.py          writes bringup.asm
    python3 test_bringup_sim.py     runs it in the simulator and checks it

The ROM is one 64 KB image (both ROM chips) with its own reset code at
x0000: it does not use the normal boot loader, so a CPU that can't run the
boot loader yet can still run it.  It first runs the CPU core tests, which
need nothing but the CPU, the ROM, the RAM and the map register:

     1  branches on AC (BEQ, BNE, BLT, BLE)        9  AC -> X, immediate -> X (read back via x3F00)
     2  AND                                       10  Y as the address high byte
     3  OR                                        11  X as the address low byte
     4  XOR                                       12  ROM data (a 256-byte table)
     5  ADD                                       13  RAM data lines, [0,D] [0,X] [Y,X]
     6  SUB                                       14  ROM/RAM map register, all 8 bits
     7  carry flag (BCS, BCC)                     15  RAM address lines, both chips
     8  SHR                                       16  video line read (x5000)

A test that fails sets the map back to all ROM and jumps to a loop of its
own at ROM x0080 + 4 x N, where it stays.  The PC then holds still at
x00(80 + 4N) to x00(82 + 4N), so a multimeter on the PC PLDs reads the test
number: PC high all 0 V, PC low Q7 high and Q6:Q2 = N.

When they all pass it copies the library's RAM code, sets the map to 05,
draws a status screen with the standard library (text, colour bands in 4, 2
and 8 bpp) and loops once per frame: it runs tests 1-14 again, tests
one 256-byte RAM page, scans the keyboard (typed keys echo; S retries the
SD card, T toggles a 1 kHz test tone), reads the SNES pads and the mouse,
and shows the video line read.

The generator keeps every block of code whose branches stay inside it in
one 256-byte page (branches only change PC low), and jumps to the next page
when a block does not fit.

Date: 10/19/2026
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))

FAIL_BASE = 0x0080              # fail loop N at FAIL_BASE + 4 N

# ROM markers: (address, value).  Y walk: page p offset x10 = p.  The map
# test uses one marker per 8 KB section, all at offsets x10 of a page whose
# column offset is below x20, so the RAM bytes it writes there are never on
# the screen.
Y_MARKS = [(p << 8 | 0x10, p) for p in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80)]
SEC_MARKS = [(0x0110, 0x01), (0x2010, 0x20), (0x4010, 0x40), (0x7E10, 0x7E),
             (0x8010, 0x80), (0xA010, 0xA0), (0xC010, 0xC0), (0xFE10, 0xE7)]
X_PAGE = 0x0F                   # X walk: ROM x0F00 + v = v ^ 5A
X_VALUES = [0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0xFF]
ID_TABLE = 0x3F00               # ROM data test: x3F00 + n = n

WALK = [0x00, 0xFF, 0x55, 0xAA, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]

# zero page (program area x20-x8F)
ZP = dict(
    T15A=0x30, T15B=0x31, T15C=0x32,                  # test 13 scratch (T15B: RAM test pattern)
    LR_AND=0x33, LR_OR=0x34, LR_TMP=0x35, LR_CL=0x36, LR_CH=0x37,
    LASTF=0x40, LOOP_LO=0x41, LOOP_HI=0x42,
    RT_IDX=0x43, RT_PAGE=0x44, RT_GOT=0x45, RT_EXP=0x46,
    RT_PL=0x47, RT_PH=0x48, RT_EL=0x49, RT_EH=0x4A,
    RT_BADH=0x4B, RT_BADL=0x4C, RT_BADE=0x4D, RT_BADG=0x4E,
    ECHO=0x4F, TONE=0x50, SD_R=0x51, FS_R=0x52,
    M_INIT=0x53, MX_LO=0x54, MX_HI=0x55, MY_LO=0x56, MY_HI=0x57,
    B_C=0x58, B_Y=0x59, B_V=0x5A, LINEV=0x5B, KEYV=0x5C,
    RT_I=0x5D, B_I=0x5E,                              # loop indexes (X is not a source)
)

RT_PAGES = list(range(0x01, 0x1F)) + list(range(0x40, 0x4D)) + list(range(0x54, 0x5A))


class Asm:
    """emits assembly lines and keeps the address, so blocks can be kept in
    one page"""

    def __init__(self):
        import placard_sim as ps
        self.size = ps.instr_size
        self.lines = []
        self.addr = 0
        self.lock = 0
        self.n = 0

    def org(self, a, comment=None):
        if comment:
            self.lines.append('')
            self.lines.append('; ' + comment)
        self.lines.append('#addr 0x%04X' % a)
        self.addr = a

    def c(self, text=''):
        self.lines.append(('; ' + text) if text else '')

    def label(self, name):
        self.lines.append(name + ':')

    def uniq(self, stem='L'):
        self.n += 1
        return '%s_%d' % (stem, self.n)

    def i(self, *ins):
        """instructions kept together in one page (a page jump changes Y)"""
        total = sum(self.size(t) for t in ins)
        if not self.lock and (self.addr & 0xFF) + total + 4 > 0x100:
            self.next_page()
        for t in ins:
            self.lines.append('    ' + t)
            self.addr += self.size(t)

    def next_page(self):
        nxt = (self.addr | 0xFF) + 1
        lb = self.uniq('pg')
        self.lines.append('    ld   %s >> 8, y' % lb)
        self.lines.append('    jmp  %s' % lb)
        self.lines.append('#addr 0x%04X' % nxt)
        self.lines.append(lb + ':')
        self.addr = nxt

    def block(self, nbytes):
        """start a block of at most nbytes that must not cross a page"""
        if (self.addr & 0xFF) + nbytes + 4 > 0x100:
            self.next_page()
        self.lock += 1
        return self

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.lock -= 1

    def data(self, values):
        for k in range(0, len(values), 16):
            self.lines.append('    #d8 ' + ', '.join('0x%02X' % v for v in values[k:k + 16]))
        self.addr += len(values)

    def string(self, s):
        self.lines.append('    #d "%s", 0x00' % s)
        self.addr += len(s) + 1

    # ---- macros ----
    def call(self, routine):
        back = self.uniq('ret')
        self.i('ld   LINK_LO, x', 'ld   %s, [x]' % back, 'ld   LINK_HI, x',
               'ld   %s >> 8, [x]' % back, 'ld   %s >> 8, y' % routine, 'jmp  %s' % routine)
        self.label(back)

    def jump(self, target):
        with self.block(4):
            self.i('ld   %s >> 8, y' % target, 'jmp  %s' % target)

    def map(self, v):
        with self.block(6):
            self.i('ld   0x50, y', 'ld   0x00, x', 'ld   0x%02X, [y,x]' % v)


def fail_jump(a, n, handler):
    """AC = slot low byte, then the fail handler (which sets map 00)"""
    a.i('ld   0x%02X, ac' % (FAIL_BASE + 4 * n), 'ld   %s >> 8, y' % handler, 'jmp  %s' % handler)


def expect(a, value, n, handler):
    """AC must equal value, else test n fails"""
    with a.block(10):
        ok = a.uniq('ok')
        a.i('xor  0x%02X, ac' % value, 'beq  %s' % ok)
        fail_jump(a, n, handler)
        a.label(ok)


def core_tests(a, tag, handler, helper_s1, startup):
    """tests 1-14 (and 15, 16 at startup).  Runs in section 1."""
    h = handler
    a.c('---- core tests (%s) ----' % tag)
    a.map(0x00)
    # 1: branches.  Each value: which of BEQ, BNE, BLT, BLE must branch
    a.c('test 1: branches on AC')
    for v in (0x00, 0x01, 0x10, 0x80, 0xFF, 0x7F):
        z = v == 0
        neg = v >= 0x80
        with a.block(60):
            f = a.uniq('t1f')
            a.i('ld   0x%02X, ac' % v)
            for br, taken in (('beq', z), ('bne', not z), ('blt', neg), ('ble', z or neg)):
                if taken:
                    ok = a.uniq('t1t')
                    a.i('%s  %s' % (br, ok), 'bra  %s' % f)
                    a.label(ok)
                else:
                    a.i('%s  %s' % (br, f))
            ok = a.uniq('t1ok')
            a.i('bra  %s' % ok)
            a.label(f)
            fail_jump(a, 1, h)
            a.label(ok)
    # 2-6: ALU
    cases = {
        ('and', 2): [(0xFF, 0x0F, 0x0F), (0xF0, 0x3C, 0x30), (0x55, 0xAA, 0x00), (0xA5, 0xFF, 0xA5),
                     (0x00, 0xFF, 0x00)],
        ('or', 3): [(0x55, 0xAA, 0xFF), (0x0F, 0xF0, 0xFF), (0x00, 0x00, 0x00), (0x12, 0x21, 0x33),
                    (0x80, 0x01, 0x81)],
        ('xor', 4): [(0xFF, 0x0F, 0xF0), (0x55, 0xFF, 0xAA), (0xA5, 0xA5, 0x00), (0x3C, 0x0F, 0x33)],
        ('add', 5): [(0x0F, 0x01, 0x10), (0x01, 0x0F, 0x10), (0x7F, 0x01, 0x80), (0xFF, 0x01, 0x00),
                     (0x55, 0xAA, 0xFF), (0x88, 0x88, 0x10), (0x12, 0x34, 0x46), (0xF0, 0xF0, 0xE0)],
        ('sub', 6): [(0x10, 0x01, 0x0F), (0x00, 0x01, 0xFF), (0x80, 0x01, 0x7F), (0x55, 0x55, 0x00),
                     (0x46, 0x34, 0x12), (0xFF, 0x0F, 0xF0), (0x01, 0xFF, 0x02)],
    }
    for (op, n), lst in cases.items():
        a.c('test %d: %s' % (n, op.upper()))
        for x, y, r in lst:
            a.i('ld   0x%02X, ac' % x, '%-4s 0x%02X, ac' % (op, y))
            expect(a, r, n, h)
    # 7: carry
    a.c('test 7: carry flag')
    for setup, carry in ((['ld 0xFF, ac', 'add 0x01, ac'], 1), (['ld 0x7F, ac', 'add 0x01, ac'], 0),
                         (['ld 0x00, ac', 'sub 0x01, ac'], 1), (['ld 0x10, ac', 'sub 0x01, ac'], 0),
                         (['ld 0x80, ac', 'shl ac'], 1), (['ld 0x40, ac', 'shl ac'], 0),
                         (['ld 0xFF, ac', 'add 0x01, ac', 'ld 0x00, ac', 'ld ac, x'], 1)):
        with a.block(40):
            f = a.uniq('t7f')
            ok = a.uniq('t7ok')
            a.i(*setup)
            if carry:
                t = a.uniq('t7t')
                a.i('bcc  %s' % f, 'bcs  %s' % t, 'bra  %s' % f)
                a.label(t)
            else:
                t = a.uniq('t7t')
                a.i('bcs  %s' % f, 'bcc  %s' % t, 'bra  %s' % f)
                a.label(t)
            a.i('bra  %s' % ok)
            a.label(f)
            fail_jump(a, 7, h)
            a.label(ok)
    # 8: SHR
    a.c('test 8: SHR')
    for x, r in ((0x80, 0x40), (0x01, 0x00), (0x10, 0x08), (0xFE, 0x7F), (0xAA, 0x55), (0x55, 0x2A)):
        a.i('ld   0x%02X, ac' % x, 'shr  ac')
        expect(a, r, 8, h)
    # 9: AC -> X -> AC, immediate -> X
    a.c('test 9: X register (AC -> X, read back through the ROM table at x%04X)' % ID_TABLE)
    for v in WALK:
        with a.block(40):                   # Y must not change at a page jump
            a.i('ld   0x%02X, ac' % v, 'ld   ac, x', 'ld   0x00, ac', 'ld   0x%02X, y' % (ID_TABLE >> 8),
                'ld   [y,x], ac')
            expect(a, v, 9, h)
            a.i('ld   0x%02X, x' % (v ^ 0xFF), 'ld   [y,x], ac')
            expect(a, v ^ 0xFF, 9, h)
    # 10: Y as the address high byte
    a.c('test 10: Y register, address bits 15-8')
    for ad, v in Y_MARKS:
        a.i('ld   0x%02X, y' % (ad >> 8), 'ld   0x%02X, x' % (ad & 0xFF), 'ld   [y,x], ac')
        expect(a, v, 10, h)
    # 11: X as the address low byte
    a.c('test 11: X register, address bits 7-0')
    for v in X_VALUES:
        a.i('ld   0x%02X, y' % X_PAGE, 'ld   0x%02X, x' % v, 'ld   [y,x], ac')
        expect(a, v ^ 0x5A, 11, h)
    # 12: ROM data
    a.c('test 12: ROM data, table at x%04X' % ID_TABLE)
    with a.block(40):
        lp = a.uniq('t12')
        f = a.uniq('t12f')
        ok = a.uniq('t12ok')
        a.i('ld   0x%02X, y' % (ID_TABLE >> 8), 'ld   0x00, ac')
        a.label(lp)
        # AC = X = n: n xor [n] is 0, and then [n] is n again for the next pass
        a.i('ld   ac, x', 'xor  [y,x], ac', 'bne  %s' % f, 'ld   [y,x], ac', 'inc',
            'bne  %s' % lp, 'bra  %s' % ok)
        a.label(f)
        fail_jump(a, 12, h)
        a.label(ok)
    # 13: RAM data, zero page modes, upper chip
    a.c('test 13: RAM data lines')
    a.map(0x11)
    for v in WALK:
        a.i('ld   0x%02X, ac' % v, 'ld   ac, [0x%02X]' % ZP['T15A'], 'ld   0x00, ac',
            'ld   [0x%02X], ac' % ZP['T15A'])
        expect(a, v, 13, h)
        a.i('ld   0x%02X, x' % ZP['T15B'], 'ld   0x%02X, [x]' % (v ^ 0xFF), 'ld   [x], ac')
        expect(a, v ^ 0xFF, 13, h)
        a.i('ld   0x%02X, x' % ZP['T15C'], 'ld   0x%02X, ac' % v, 'ld   ac, [x]', 'ld   0x00, ac',
            'ld   [0x%02X], ac' % ZP['T15C'])
        expect(a, v, 13, h)
        with a.block(44):                   # Y must not change at a page jump
            a.i('ld   0x90, y', 'ld   0x10, x', 'ld   0x%02X, [y,x]' % v, 'ld   0x00, ac', 'ld   [y,x], ac')
            expect(a, v, 13, h)
            a.i('ld   0x%02X, ac' % (v ^ 0xFF), 'ld   ac, [y,x]', 'ld   0x00, ac', 'ld   [y,x], ac')
            expect(a, v ^ 0xFF, 13, h)
    # 14: map register.  Section 1 (this code) is done by the helper in section 3.
    a.c('test 14: ROM/RAM map register')
    for sec, (ad, m) in enumerate(SEC_MARKS):
        if sec == 1:
            back = a.uniq('t13b')
            a.jump(helper_s1)
            a.label(back)
            helper_s1_back = back
            continue
        map_section_test(a, sec, ad, m, h)
    # 15: RAM address lines (startup only), from section 3
    if startup:
        back = a.uniq('t14b')
        a.jump('ram_addr_test')
        a.label(back)
        t14_back = back
    else:
        t14_back = None
    # 16: video line read (startup only)
    if startup:
        a.c('test 16: video line read, AND and OR of about 1.5 frames of reads')
        a.map(0x01)
        a.i('ld   0xFF, ac', 'ld   ac, [0x%02X]' % ZP['LR_AND'], 'ld   0x00, ac',
            'ld   ac, [0x%02X]' % ZP['LR_OR'], 'ld   0x00, ac', 'ld   ac, [0x%02X]' % ZP['LR_CL'],
            'ld   0x40, ac', 'ld   ac, [0x%02X]' % ZP['LR_CH'])
        with a.block(60):
            lp = a.uniq('t16')
            a.i('ld   0x50, y', 'ld   0x00, x')
            a.label(lp)
            a.i('ld   [y,x], ac', 'ld   ac, [0x%02X]' % ZP['LR_TMP'],
                'and  [0x%02X], ac' % ZP['LR_AND'], 'ld   ac, [0x%02X]' % ZP['LR_AND'],
                'ld   [0x%02X], ac' % ZP['LR_TMP'], 'or   [0x%02X], ac' % ZP['LR_OR'],
                'ld   ac, [0x%02X]' % ZP['LR_OR'],
                'ld   [0x%02X], ac' % ZP['LR_CL'], 'dec', 'ld   ac, [0x%02X]' % ZP['LR_CL'],
                'bne  %s' % lp,
                'ld   [0x%02X], ac' % ZP['LR_CH'], 'dec', 'ld   ac, [0x%02X]' % ZP['LR_CH'],
                'bne  %s' % lp)
        a.i('ld   [0x%02X], ac' % ZP['LR_AND'])
        expect(a, 0x00, 16, h)
        a.i('ld   [0x%02X], ac' % ZP['LR_OR'])
        expect(a, 0xFF, 16, h)
    return helper_s1_back, t14_back


def map_section_test(a, sec, ad, m, h):
    """RAM under the marker gets ~m; map bit sec = 1 must read ~m, map 00 m"""
    a.i('ld   0x%02X, y' % (ad >> 8), 'ld   0x%02X, x' % (ad & 0xFF), 'ld   0x%02X, [y,x]' % (m ^ 0xFF))
    a.map(1 << sec)
    a.i('ld   0x%02X, y' % (ad >> 8), 'ld   0x%02X, x' % (ad & 0xFF), 'ld   [y,x], ac')
    expect(a, m ^ 0xFF, 14, h)
    a.map(0x00)
    a.i('ld   0x%02X, y' % (ad >> 8), 'ld   0x%02X, x' % (ad & 0xFF), 'ld   [y,x], ac')
    expect(a, m, 14, h)


def fail_handler(a, name):
    """AC = fail loop low byte: map = 00 (page 0 reads ROM), jump there"""
    with a.block(16):
        a.label(name)
        a.i('ld   0x50, y', 'ld   0x00, x', 'ld   0x00, [y,x]', 'ld   0x00, y', 'jmp  ac')


def ram_addr_test(a, back_label):
    """test 15, in section 3, map F7 (all RAM but section 3)"""
    a.label('ram_addr_test')
    a.c('test 15: RAM address lines.  Writes a different byte at the base of')
    a.c('each RAM chip and at base + 2^k, then reads them all back.')
    a.map(0xF7)
    cells = [(0x0000, 0xA5)] + [(1 << k, k + 1) for k in range(15)] + \
            [(0x8000, 0x5A)] + [(0x8000 | (1 << k), 0x41 + k) for k in range(15)]
    for ad, v in cells:
        a.i('ld   0x%02X, y' % (ad >> 8), 'ld   0x%02X, x' % (ad & 0xFF), 'ld   0x%02X, [y,x]' % v)
    for ad, v in cells:
        a.i('ld   0x%02X, y' % (ad >> 8), 'ld   0x%02X, x' % (ad & 0xFF), 'ld   [y,x], ac')
        expect(a, v, 15, 'fail_h3')
    a.map(0x00)
    a.jump(back_label)


def put_str(a, col, row, label):
    a.i('ld   %d, ac' % col, 'ld   ac, [CUR_COL]', 'ld   %d, ac' % row, 'ld   ac, [CUR_ROW]',
        'ld   %s, ac' % label, 'ld   ac, [R0]', 'ld   %s >> 8, ac' % label, 'ld   ac, [R1]')
    a.call('con_puts')


def at(a, col, row):
    a.i('ld   %d, ac' % col, 'ld   ac, [CUR_COL]', 'ld   %d, ac' % row, 'ld   ac, [CUR_ROW]')


def hex_zp(a, col, row, zp):
    at(a, col, row)
    a.i('ld   [0x%02X], ac' % zp)
    a.call('con_hex8')


def dec16_zp(a, col, row, lo):
    at(a, col, row)
    a.i('ld   [0x%02X], ac' % lo, 'ld   ac, [R0]', 'ld   [0x%02X], ac' % (lo + 1), 'ld   ac, [R1]')
    a.call('con_dec16')
    a.i('ld   0x20, ac')
    a.call('con_putc')


def inc16(a, lo):
    with a.block(20):
        nc = a.uniq('nc')
        a.i('ld   [0x%02X], ac' % lo, 'inc', 'ld   ac, [0x%02X]' % lo, 'bne  %s' % nc,
            'ld   [0x%02X], ac' % (lo + 1), 'inc', 'ld   ac, [0x%02X]' % (lo + 1))
        a.label(nc)


STRINGS = [
    ('s_title', 'PLACARD BRING-UP ROM                                         FRAME'),
    ('s_core', 'CPU CORE TESTS 1-16 PASSED.  REPEATED EVERY FRAME, LOOPS:'),
    ('s_core2', 'A FAILED TEST STOPS THE CPU IN A LOOP AT x0080 + 4 x TEST (SEE BRINGUP.MD)'),
    ('s_ram', 'RAM PAGE        PASSES          ERRORS          LAST BAD       WROTE     READ'),
    ('s_kbd', 'KEYBOARD COLUMNS 0-7:'),
    ('s_kbd2', 'TYPED:'),
    ('s_pad', 'SNES PADS:  1:          2:'),
    ('s_sd', 'SD CARD: SD_INIT      FS_MOUNT      (S = TRY AGAIN)'),
    ('s_sd2', '  SD_INIT 00 READY, 01 NO CARD, 02 DID NOT START, 03 UNUSABLE.  FS_MOUNT 00 OK'),
    ('s_mouse', 'MOUSE: MOUSE_INIT      X        Y        BUTTONS'),
    ('s_mouse2', '  MOUSE_INIT 00 RUNNING, 01 NO MOUSE, 02 WRONG ANSWER'),
    ('s_snd', 'SOUND: T = 1 KHZ TEST TONE, NOW'),
    ('s_on', 'ON '),
    ('s_off', 'OFF'),
    ('s_line', 'VIDEO LINE READ (V9:V2):'),
    ('s_bands', 'BANDS BELOW: 16 COLORS (4 BPP), 4 COLORS (2 BPP), 256 COLORS (8 BPP)'),
]


def main_program(a):
    a.org(0x8100, 'main: library set-up, status screen, frame loop (section 4)')
    a.label('main')
    a.c('copy LIB_RAM (ROM x1F00-x1FFF) into the RAM under it, map 00')
    a.map(0x00)
    with a.block(30):
        lp = a.uniq('cp')
        a.i('ld   0x1F, y', 'ld   0x00, ac')
        a.label(lp)
        a.i('ld   ac, x', 'ld   [y,x], [y,x]', 'inc', 'bne  %s' % lp)
    a.map(0x05)
    a.i('ld   0x05, ac', 'ld   ac, [MAP_SHADOW]', 'ld   STACK_TOP, ac', 'ld   ac, [SP]')
    for k in ('LOOP_LO', 'LOOP_HI', 'RT_IDX', 'RT_PL', 'RT_PH', 'RT_EL', 'RT_EH', 'RT_BADH', 'RT_BADL',
              'RT_BADE', 'RT_BADG', 'TONE', 'MX_LO', 'MX_HI', 'MY_LO', 'MY_HI', 'KEYV'):
        a.i('ld   0x00, ac', 'ld   ac, [0x%02X]' % ZP[k])
    a.i('ld   0x00, ac', 'ld   ac, [FRAME_LO]', 'ld   ac, [FRAME_HI]')
    a.i('ld   7, ac', 'ld   ac, [0x%02X]' % ZP['ECHO'], 'ld   0xEE, ac', 'ld   ac, [0x%02X]' % ZP['M_INIT'])
    a.call('port_init')
    a.call('snd_init')
    a.call('con_clear')
    draw_bands(a)
    for lb, col, row in (('s_title', 0, 0), ('s_core', 0, 2), ('s_core2', 0, 3), ('s_ram', 0, 5),
                         ('s_kbd', 0, 8), ('s_kbd2', 0, 9), ('s_pad', 0, 12), ('s_sd', 0, 14),
                         ('s_sd2', 0, 15), ('s_mouse', 0, 17), ('s_mouse2', 0, 18), ('s_snd', 0, 20),
                         ('s_line', 0, 22), ('s_bands', 0, 44)):
        put_str(a, col, row, lb)
    put_str(a, 32, 20, 's_off')
    a.label('sd_try')
    a.call('sd_init')
    with a.block(30):
        ok = a.uniq('sdok')
        dn = a.uniq('sddn')
        a.i('ld   ac, [0x%02X]' % ZP['SD_R'], 'beq  %s' % ok, 'ld   0xFF, ac', 'ld   ac, [0x%02X]' % ZP['FS_R'],
            'bra  %s' % dn)
        a.label(ok)
        a.jump('sd_mount')
        a.label(dn)
    a.jump('sd_show')
    a.label('sd_mount')
    a.call('fs_mount')
    a.i('ld   ac, [0x%02X]' % ZP['FS_R'])
    a.label('sd_show')
    hex_zp(a, 17, 14, ZP['SD_R'])
    hex_zp(a, 31, 14, ZP['FS_R'])
    a.c('the first pass also starts the mouse; a retry (S) only does the card')
    with a.block(20):
        a.i('ld   [0x%02X], ac' % ZP['M_INIT'], 'xor  0xEE, ac')
        go = a.uniq('mgo')
        a.i('beq  %s' % go)
        a.jump('frame_loop')
        a.label(go)
    a.call('mouse_init')
    a.i('ld   ac, [0x%02X]' % ZP['M_INIT'])
    hex_zp(a, 18, 17, ZP['M_INIT'])
    a.i('ld   [LINE_LAST], ac')     # harmless; frame_poll sets it
    a.call('frame_poll')
    a.i('ld   [FRAME_LO], ac', 'ld   ac, [0x%02X]' % ZP['LASTF'])

    a.org(0x9000, 'frame loop')
    a.label('frame_loop')
    with a.block(40):
        w = a.uniq('wait')
        a.label(w)
        a.call('frame_poll')
        a.i('ld   ac, [0x%02X]' % ZP['LINEV'], 'ld   [FRAME_LO], ac', 'xor  [0x%02X], ac' % ZP['LASTF'],
            'beq  %s' % w)
    a.i('ld   [FRAME_LO], ac', 'ld   ac, [0x%02X]' % ZP['LASTF'])
    a.call('snd_update')
    a.call('kbd_scan')
    # keys
    a.label('key_loop')
    a.call('kbd_getc')
    with a.block(12):
        some = a.uniq('key')
        a.i('bne  %s' % some)
        a.jump('keys_done')
        a.label(some)
    a.i('ld   ac, [0x%02X]' % ZP['KEYV'])
    for ch, target in (('S', 'sd_key'), ('s', 'sd_key'), ('T', 't_key'), ('t', 't_key')):
        with a.block(14):
            no = a.uniq('nk')
            a.i('ld   [0x%02X], ac' % ZP['KEYV'], 'xor  0x%02X, ac' % ord(ch), 'bne  %s' % no)
            a.jump(target)
            a.label(no)
    a.label('echo_key')
    a.c('echo it on row 9 (control codes as a dot), wrapping at column 79')
    with a.block(20):
        pr = a.uniq('pr')
        a.i('ld   [0x%02X], ac' % ZP['KEYV'], 'sub  0x20, ac', 'bcc  %s' % pr, 'ld   0x2E, ac',
            'ld   ac, [0x%02X]' % ZP['KEYV'])
        a.label(pr)
    a.i('ld   [0x%02X], ac' % ZP['ECHO'], 'ld   ac, [CUR_COL]', 'ld   9, ac', 'ld   ac, [CUR_ROW]',
        'ld   [0x%02X], ac' % ZP['KEYV'])
    a.call('con_putc')
    with a.block(24):
        nw = a.uniq('nw')
        a.i('ld   [0x%02X], ac' % ZP['ECHO'], 'inc', 'ld   ac, [0x%02X]' % ZP['ECHO'], 'xor  80, ac',
            'bne  %s' % nw, 'ld   7, ac', 'ld   ac, [0x%02X]' % ZP['ECHO'])
        a.label(nw)
    a.jump('key_loop')
    a.label('sd_key')
    a.jump('sd_try')
    a.label('t_key')
    with a.block(12):
        on = a.uniq('ton')
        a.i('ld   [0x%02X], ac' % ZP['TONE'], 'beq  %s' % on)
        a.jump('tone_off')
        a.label(on)
    a.i('ld   1, ac', 'ld   ac, [0x%02X]' % ZP['TONE'], 'ld   0x11, ac', 'ld   ac, [R0]', 'ld   0x04, ac',
        'ld   ac, [R1]', 'ld   0x00, ac', 'ld   ac, [R2]', 'ld   ac, [R3]', 'ld   48, ac')
    a.call('snd_tone')
    put_str(a, 32, 20, 's_on')
    a.jump('key_loop')
    a.label('tone_off')
    a.i('ld   0x00, ac', 'ld   ac, [0x%02X]' % ZP['TONE'])
    a.call('snd_stop')
    put_str(a, 32, 20, 's_off')
    a.jump('key_loop')
    a.label('keys_done')
    # keyboard rows
    for c in range(8):
        hex_zp(a, 22 + 3 * c, 8, 0xA0 + c)
    # pads
    a.call('pad_read')
    for col, zp in ((15, 0x11), (17, 0x10), (27, 0x13), (29, 0x12)):
        hex_zp(a, col, 12, zp)
    # mouse
    with a.block(12):
        go = a.uniq('mp')
        a.i('ld   [0x%02X], ac' % ZP['M_INIT'], 'beq  %s' % go)
        a.jump('mouse_done')
        a.label(go)
    a.call('mouse_poll')
    with a.block(12):
        go = a.uniq('mm')
        a.i('xor  1, ac', 'beq  %s' % go)
        a.jump('mouse_show')
        a.label(go)
    for src, dst in (('MX_LO', 'R0'), ('MX_HI', 'R1'), ('MY_LO', 'R2'), ('MY_HI', 'R3')):
        a.i('ld   [0x%02X], ac' % ZP[src], 'ld   ac, [%s]' % dst)
    a.call('mouse_move')
    for src, dst in (('MX_LO', 'R0'), ('MX_HI', 'R1'), ('MY_LO', 'R2'), ('MY_HI', 'R3')):
        a.i('ld   [%s], ac' % dst, 'ld   ac, [0x%02X]' % ZP[src])
    a.label('mouse_show')
    dec16_zp(a, 25, 17, ZP['MX_LO'])
    dec16_zp(a, 34, 17, ZP['MY_LO'])
    at(a, 49, 17)
    a.i('ld   [MOUSE_B], ac')
    a.call('con_hex8')
    a.label('mouse_done')
    # video line read
    hex_zp(a, 25, 22, ZP['LINEV'])
    # RAM page test
    a.jump('ram_page_test')
    a.label('rt_back')
    hex_zp(a, 9, 5, ZP['RT_PAGE'])
    dec16_zp(a, 23, 5, ZP['RT_PL'])
    dec16_zp(a, 39, 5, ZP['RT_EL'])
    hex_zp(a, 57, 5, ZP['RT_BADH'])
    hex_zp(a, 59, 5, ZP['RT_BADL'])
    hex_zp(a, 69, 5, ZP['RT_BADE'])
    hex_zp(a, 78, 5, ZP['RT_BADG'])
    # the core tests again
    a.jump('core_loop')
    a.label('core_back')
    a.map(0x05)
    inc16(a, ZP['LOOP_LO'])
    dec16_zp(a, 58, 2, ZP['LOOP_LO'])
    dec16_zp(a, 67, 0, 0x08)            # FRAME_HI:FRAME_LO
    a.jump('frame_loop')


def ram_page_test(a):
    """one page a frame, 6 patterns: 00 FF 55 AA, the address low byte, its
    complement.  Counts errors and keeps the last bad address."""
    a.org(0xA100, 'RAM page test, one page per frame (section 5)')
    a.label('ram_page_test')
    a.i('ld   [0x%02X], x' % ZP['RT_IDX'], 'ld   rt_pages >> 8, y', 'ld   [y,x], ac',
        'ld   ac, [0x%02X]' % ZP['RT_PAGE'])
    rets = []
    for pat in range(6):
        with a.block(60):
            wl = a.uniq('rw')
            a.i('ld   [0x%02X], y' % ZP['RT_PAGE'], 'ld   0x00, ac')
            a.label(wl)
            a.i('ld   ac, x')
            if pat < 4:
                a.i('ld   0x%02X, [y,x]' % (0x00, 0xFF, 0x55, 0xAA)[pat])
            elif pat == 4:
                a.i('ld   ac, [y,x]')
            else:
                a.i('xor  0xFF, ac', 'ld   ac, [y,x]', 'xor  0xFF, ac')
            a.i('inc', 'bne  %s' % wl)
        rl = a.uniq('rr')
        nx = a.uniq('rn')
        with a.block(70):
            a.i('ld   0x00, ac', 'ld   ac, [0x%02X]' % ZP['RT_I'])
            a.label(rl)
            a.i('ld   [0x%02X], x' % ZP['RT_I'])
            a.i('ld   [0x%02X], y' % ZP['RT_PAGE'], 'ld   [y,x], ac', 'ld   ac, [0x%02X]' % ZP['RT_GOT'])
            if pat < 4:
                v = (0x00, 0xFF, 0x55, 0xAA)[pat]
                a.i('ld   0x%02X, ac' % v, 'ld   ac, [0x%02X]' % ZP['RT_EXP'])
            elif pat == 4:
                a.i('ld   [0x%02X], ac' % ZP['RT_I'], 'ld   ac, [0x%02X]' % ZP['RT_EXP'])
            else:
                a.i('ld   [0x%02X], ac' % ZP['RT_I'], 'xor  0xFF, ac', 'ld   ac, [0x%02X]' % ZP['RT_EXP'])
            bad = a.uniq('rb')
            a.i('xor  [0x%02X], ac' % ZP['RT_GOT'], 'bne  %s' % bad)
            a.label(nx)
            a.i('ld   [0x%02X], ac' % ZP['RT_I'], 'inc', 'ld   ac, [0x%02X]' % ZP['RT_I'], 'bne  %s' % rl)
            done = a.uniq('rd')
            a.i('bra  %s' % done)
            a.label(bad)
            a.i('ld   [0x%02X], ac' % ZP['RT_I'], 'ld   ac, [0x%02X]' % ZP['RT_BADL'],
                'ld   %d, ac' % pat, 'ld   ac, [0x%02X]' % ZP['T15B'])
            a.jump('rt_err')
            a.label(done)
        rets.append(nx)
    # end of the page
    with a.block(30):
        a.i('ld   [0x%02X], ac' % ZP['RT_IDX'], 'inc', 'ld   ac, [0x%02X]' % ZP['RT_IDX'],
            'xor  %d, ac' % len(RT_PAGES))
        nw = a.uniq('rtw')
        a.i('bne  %s' % nw, 'ld   0x00, ac', 'ld   ac, [0x%02X]' % ZP['RT_IDX'])
        a.label(nw)
    a.c('a pass is done when the index wraps')
    with a.block(12):
        nw = a.uniq('rtp')
        a.i('ld   [0x%02X], ac' % ZP['RT_IDX'], 'bne  %s' % nw)
        a.jump('rt_pass')
        a.label(nw)
    a.jump('rt_back')
    a.label('rt_pass')
    inc16(a, ZP['RT_PL'])
    a.jump('rt_back')
    # error: count, remember, and go back to the pattern's loop
    a.label('rt_err')
    a.i('ld   [0x%02X], ac' % ZP['RT_PAGE'], 'ld   ac, [0x%02X]' % ZP['RT_BADH'],
        'ld   [0x%02X], ac' % ZP['RT_EXP'], 'ld   ac, [0x%02X]' % ZP['RT_BADE'],
        'ld   [0x%02X], ac' % ZP['RT_GOT'], 'ld   ac, [0x%02X]' % ZP['RT_BADG'])
    inc16(a, ZP['RT_EL'])
    a.c('back to the right pattern (its number is in T15B)')
    a.jump('rt_dispatch')
    for pat, nx in enumerate(rets):
        a.c('error return for pattern %d: on to the next byte' % pat)
        a.label('rt_ret%d' % pat)
        a.jump(nx)


def draw_bands(a):
    """rows 368-479: mode bytes and the colour bands"""
    a.c('mode bytes: rows 368-399 4 bpp, 400-415 2 bpp, 416-479 8 bpp (all 1x)')
    for lo, hi, m in ((0x90, 0xB0, 0x02), (0xB0, 0xC0, 0x01), (0xC0, 0x100, 0x03)):
        with a.block(30):
            lp = a.uniq('mb')
            a.i('ld   0x5B, y', 'ld   0x%02X, ac' % (hi - lo - 1))
            a.label(lp)
            # X = lo + AC, AC counts down to 0
            a.i('add  0x%02X, x' % lo, 'ld   0x%02X, [y,x]' % m, 'sub  1, ac', 'bcc  %s' % lp)
    a.c('pixels: byte column c is at page x61 + 2c, rows 368-479 at x90-xFF')
    a.i('ld   0x00, ac', 'ld   ac, [0x%02X]' % ZP['B_C'])
    a.label('band_col')
    a.i('ld   [0x%02X], ac' % ZP['B_C'], 'shl  ac', 'add  0x61, ac', 'ld   ac, [0x%02X]' % ZP['B_Y'])
    for lo, hi, table in ((0x90, 0xB0, 'tbl4'), (0xB0, 0xC0, 'tbl2')):
        a.i('ld   %s >> 8, y' % table, 'ld   [0x%02X], x' % ZP['B_C'], 'ld   [y,x], ac',
            'ld   ac, [0x%02X]' % ZP['B_V'])
        with a.block(30):
            lp = a.uniq('bp')
            a.i('ld   [0x%02X], y' % ZP['B_Y'], 'ld   0x%02X, ac' % lo, 'ld   ac, [0x%02X]' % ZP['B_I'])
            a.label(lp)
            a.i('ld   [0x%02X], x' % ZP['B_I'], 'ld   [0x%02X], ac' % ZP['B_V'], 'ld   ac, [y,x]',
                'ld   [0x%02X], ac' % ZP['B_I'], 'inc', 'ld   ac, [0x%02X]' % ZP['B_I'],
                'xor  0x%02X, ac' % hi, 'bne  %s' % lp)
    a.c('8 bpp: colour = (row band) x 64 + (c and 63)')
    a.i('ld   [0x%02X], ac' % ZP['B_C'], 'and  0x3F, ac', 'ld   ac, [0x%02X]' % ZP['B_V'])
    with a.block(40):
        lp = a.uniq('b8')
        a.i('ld   [0x%02X], y' % ZP['B_Y'], 'ld   0xC0, ac')
        a.label(lp)
        a.i('ld   ac, x', 'ld   ac, [0x%02X]' % ZP['B_I'], 'and  0x30, ac', 'shl  ac', 'shl  ac',
            'or   [0x%02X], ac' % ZP['B_V'], 'ld   ac, [y,x]', 'ld   [0x%02X], ac' % ZP['B_I'], 'inc',
            'bne  %s' % lp)
    with a.block(20):
        a.i('ld   [0x%02X], ac' % ZP['B_C'], 'inc', 'ld   ac, [0x%02X]' % ZP['B_C'], 'xor  80, ac')
        dn = a.uniq('bd')
        a.i('beq  %s' % dn)
        a.jump('band_col')
        a.label(dn)


def generate():
    a = Asm()
    L = a.lines
    L += ['; bringup.asm - the bring-up test ROM (docs/BRINGUP.md)',
          ';',
          '; Written by gen_bringup.py; edit that, not this file.  A complete 64 KB',
          '; ROM image with its own reset code: burn x0000-x7FFF into the lower ROM',
          '; chip (#33) and x8000-xFFFF into the upper one (#34)',
          '; (test_bringup_sim.py --bin writes bringup_lo.bin and bringup_hi.bin).',
          ';',
          '; Fail loops: test N stops at x0080 + 4N (PC high = 00, PC low Q7 = 1,',
          '; Q6:Q2 = N).  Tests:']
    L += [';   %s' % t for t in (
        '1 branches  2 AND  3 OR  4 XOR  5 ADD  6 SUB  7 carry  8 SHR',
        '9 AC/X  10 Y address  11 X address  12 ROM data  13 RAM data',
        '14 map register  15 RAM address lines  16 video line read')]
    L += [';', '; Date: 10/19/2026', '',
          '#include "placard.asm"', '#include "placard_lib.asm"', '']
    for k, v in ZP.items():
        L.append('%-8s = 0x%02X' % (k, v))
    # reset and fail loops
    a.org(0x0000, 'reset (the CPU starts at x0000 with the map all ROM)')
    a.lock += 1
    a.i('ld   start >> 8, y', 'jmp  start')
    a.lock -= 1
    a.org(FAIL_BASE + 4, 'fail loops: test N stops here at x0080 + 4N')
    for n in range(1, 17):
        a.org(FAIL_BASE + 4 * n)
        a.label('fail%d' % n)
        a.lock += 1
        a.i('bra  fail%d' % n)
        a.lock -= 1
    # markers and tables
    a.org(0x0100, 'ROM markers for tests 10 and 13 (address -> value)')
    for ad, v in sorted(set(Y_MARKS) | set(SEC_MARKS)):
        a.org(ad)
        a.data([v])
    a.org(X_PAGE << 8, 'test 11: x0F00 + v = v xor 5A')
    for v in X_VALUES:
        a.org((X_PAGE << 8) | v)
        a.data([v ^ 0x5A])
    a.org(ID_TABLE, 'test 12: x3F00 + n = n')
    a.data(list(range(256)))

    # section 1: core tests, startup copy and loop copy
    a.org(0x2100, 'section 1: the core tests')
    fail_handler(a, 'fail_h')
    a.label('start')
    a.c('startup copy: tests 1-16')
    s1_back_a, t14_back = core_tests(a, 'startup', 'fail_h', 'map_s1_a', startup=True)
    a.jump('main')
    a.label('core_loop')
    a.c('frame loop copy: tests 1-14')
    s1_back_b, _ = core_tests(a, 'loop', 'fail_h', 'map_s1_b', startup=False)
    a.jump('core_back')
    if a.addr > 0x3F00:
        raise SystemExit('section 1 code runs into the x3F00 table (%04X)' % a.addr)

    # section 3: helpers that can't run in section 1
    a.org(0x6000, 'section 3: map test for section 1, RAM address test')
    fail_handler(a, 'fail_h3')
    for name, back in (('map_s1_a', s1_back_a), ('map_s1_b', s1_back_b)):
        a.label(name)
        ad, m = SEC_MARKS[1]
        map_section_test(a, 1, ad, m, 'fail_h3')
        a.jump(back)
    ram_addr_test(a, t14_back)
    a.org(0x6E00, 'band tables')
    a.label('tbl4')
    a.data([(c // 5) * 0x11 for c in range(80)])
    a.org(0x6F00)
    a.label('tbl2')
    a.data([(c // 20) * 0x55 for c in range(80)])

    main_program(a)
    if a.addr > 0xA000:
        raise SystemExit('main runs into the RAM test (%04X)' % a.addr)
    ram_page_test(a)
    # an error goes back to its pattern's loop: the bad-byte path left the
    # pattern number in T15B
    a.org(0xB000, 'RAM test error return and tables')
    a.label('rt_dispatch')
    for pat in range(6):
        with a.block(14):
            nx = a.uniq('dp')
            a.i('ld   [0x%02X], ac' % ZP['T15B'], 'xor  %d, ac' % pat, 'bne  %s' % nx)
            a.jump('rt_ret%d' % pat)
            a.label(nx)
    a.jump('rt_ret0')
    a.org(0xB200)
    a.label('rt_pages')
    a.data(RT_PAGES)
    a.org(0xB300, 'strings')
    for lb, s in STRINGS:
        a.label(lb)
        a.string(s)
    return '\n'.join(a.lines) + '\n'


if __name__ == '__main__':
    import sys
    sys.path.insert(0, HERE)
    src = generate()
    open(os.path.join(HERE, 'bringup.asm'), 'w').write(src)
    print('wrote bringup.asm, %d lines' % src.count('\n'))
