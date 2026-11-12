#!/usr/bin/env python3
"""
gen_bringup.py - writes bringup.asm, the bring-up test ROM (docs/hardware/BRINGUP.md)

    python3 gen_bringup.py          writes bringup.asm
    python3 test_bringup_sim.py     runs it in the simulator and checks it

The ROM is one 32 KB image for the 32K cartridge (bringup.bin), with its own
reset code at x0000: it does not use the normal boot loader, so a CPU that
can't run the boot loader yet can still run it.  The cartridge shows its
32 KB in both halves of the ROM, so the byte at file offset f is read at
x0000 + f and at x8000 + f: the library sits where it always does in
x8000-xFFFF and the test code uses the pages it leaves free, at whichever
of the two addresses suits (image() folds the two halves and checks that
no two bytes meet).

It starts with seven chip gates in pages x01-x07, one for each step in
which BRINGUP.md fits a CPU chip with the cartridge already in: the PC
stops in a gate's page until that step's chips work (see gates()), so PC
high is the number of the gate it is waiting in.  Then it runs the CPU
core tests, which need nothing but the CPU, the ROM, the RAM and the map
register:

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
number: PC high all 0 V, PC low Q7 high and Q6:Q2 = N.  Test 16 at
start-up is the exception: it is gate 7, and waits in page x07.

When they all pass it copies the library's RAM code, sets the map to 05,
draws a status screen with the standard library (text, color bands in 4, 2
and 8 bpp) and loops once per frame: it runs tests 1-14 again, tests
one 256-byte RAM page, polls the PS/2 keyboard (typed keys echo; S retries
the SD card, T toggles a 1 kHz test tone), reads the SNES pads and the
mouse, and shows the video line read.

The generator keeps every block of code whose branches stay inside it in
one 256-byte page (branches only change PC low), and jumps to the next page
when a block does not fit.

Date: 11/12/2026
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))

FAIL_BASE = 0x0080              # fail loop N at FAIL_BASE + 4 N

# ROM markers: (address, value).  Y walk: page p offset xF0 = p, for the
# seven address bits 14-8 the ROM has (the 32K cartridge's ROM does not see
# bit 15: tests 14 and 15 check it through the RAM).  xC0F0, the mirror of
# x40F0, is in the free end of the SD card driver's first page.
# The map test uses one marker per 8 KB section, at offset x10 of a page:
# in the video area (sections 3-7) that is an even page's offset below x20,
# so the RAM bytes the test writes there are never on the screen.  Sections
# s and s + 4 share a ROM byte (the mirror); the RAM under them differs.
# The library leaves xD600-xD617 free (after the FAT reader; the bring-up
# ROM has no FAT writer).
Y_MARKS = [(p << 8 | 0xF0, p) for p in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40)]
SEC_MARKS = [(0x0F10, 0x0F), (0x2010, 0x20), (0x5610, 0x56), (0x7E10, 0x7E),
             (0x8F10, 0x0F), (0xA010, 0x20), (0xD610, 0x56), (0xFE10, 0x7E)]
X_PAGE = 0x3A                   # X walk: ROM x3A00 + v = v ^ 5A
# the chip gates (see gates()): pages 1-7, one per build step, run in order
# from the reset by falling off the end of each page
GATE_PAGES = range(1, 8)
# gate 3: pages that hold their own number in every byte, so a read through
# [Y,X] tells the page whatever X is.  Between them every address bit 14-8
# is 0 in one and 1 in another.  (Section 0's map marker x0F10 is one of
# these bytes.)
CONST_PAGES = [0x39, 0x5E, 0x11, 0x0F]
# pages (as the CPU addresses them) for the code after the core tests: the
# free pages under the library, in the order the code fills them.  A page
# with a Y marker ends at xF0.
CODE_PAGES = list(range(0x8A, 0x8F)) + [0xBB, 0xBC, 0xBD, 0xBE] + list(range(0xD7, 0xDE))
HELPER_PAGES = [0x72, 0x73, 0x7C, 0x7D]     # section 3 (the mirror of section 7's free pages)
TBL4, TBL2, RT_TABLE = 0x8900, 0x8800, 0x9000   # tables that start a page (indexed by X)
# free ends for the strings: (start, end)
STR_ROOM = [(0x8950, 0x89F0), (0x8850, 0x88F0), (0x90A0, 0x90F0)]
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
        self.pages = None       # the pages the code may use, in order (None: every page)

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
        if self.pages is not None:
            k = self.pages.index(self.addr >> 8) + 1
            if k >= len(self.pages):
                raise SystemExit('out of pages after x%04X' % self.addr)
            nxt = self.pages[k] << 8
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


def gate_page(a, page, lines, trap=0xFC, fill=(0xFC,), last=False):
    """one gate page.  lines: the code from offset 0 ((label,) or text).  The
    rest of the page is fill, so a PC that lands anywhere in it ends in the
    page's trap; offsets xFE and xFF are the way on (two nops, then the next
    page) unless this is the last gate.  A Y marker at xF0 is left alone."""
    a.org(page << 8, 'gate %d' % page)
    a.lock += 1
    for ln in lines:
        if isinstance(ln, tuple):
            if ln[0].startswith('@'):           # ('@E0', 'label'): code at a fixed offset
                pad_to(a, page, int(ln[0][1:], 16), fill)
                a.label(ln[1])
            else:
                a.label(ln[0])
        else:
            a.i(ln)
    a.lock -= 1
    pad_to(a, page, 0xFE, fill)
    if last:
        pad_to(a, page, 0x100, fill)
    else:
        a.label('gate_exit%d' % page)
        a.lock += 1
        a.i('nop', 'nop')
        a.lock -= 1
    assert a.addr == (page + 1) << 8, 'gate %d: %04X' % (page, a.addr)


def pad_to(a, page, off, fill):
    """fill bytes up to offset off of the page (not the Y marker at xF0)"""
    start = a.addr & 0xFF if a.addr >> 8 == page else 0x100
    assert a.addr >> 8 in (page, page + 1) and start <= off, 'gate %d is too long (%04X)' % (page, a.addr)
    marks = set(ad & 0xFF for ad, v in Y_MARKS if ad >> 8 == page)
    run = []
    for o in range(start, off):
        if o in marks:
            if run:
                a.data(run)
                run = []
            a.org((page << 8) | (o + 1))
            continue
        run.append(fill[o % len(fill)])
    if run:
        a.data(run)
    a.addr = (page << 8) + off


def gates(a):
    """the chip gates: pages 1-7, one per build step of BRINGUP.md.

    The CPU chips go in one build step at a time with the cartridge already
    in, and each gate lets the PC through only when its step's chips work.
    A gate that fails stops in a tight loop in its own page, so PC high
    (U4's Q pins, steady levels on a multimeter) is the number of the gate
    it is waiting in:

        1  accumulator U19, ALU U5 and U6      5  D source buffer U26 (with the RAM in)
        2  AC source buffer U27                6  RAM U31, U32
        3  Y register U21                      7  line read buffer U29
        4  X register U20

    A gate may use only the chips of the gates before it:

      - No jumps until gate 3 has passed (a jump loads PC high from Y):
        the code runs from the reset into page 1 and from each gate into
        the next by falling off the end of the page.
      - The D register U18, the D source buffer U26 and the RAM are in
        before the cartridge (BRINGUP.md step 16), so constants and
        branch targets work from the first gate on, and gates 5 and 6
        pass at once on a good board.  (Gates 1-4 would also run with
        U26 and the RAM both out, on the byte the data bus keeps, but
        the guide no longer builds it that way.)
      - Unused bytes are xFC (bra xFC), and offsets xFC, xFD hold xFC xFC:
        a PC that lands anywhere in the page ends in the loop at xFC.

    Gate 5 is a soak test of U26.  It has to stop for good when U26 is
    bad, although nothing with a D source can be trusted then (not even a
    branch to a fixed place), so its stop uses the AC source only: clr ac, bra ac goes to offset 0,
    where beq ac (one byte) branches to itself while AC is 0.  Its filler
    is those two bytes.  The test loads and checks 15 constants 256 times
    (about 50 lines, 100 video reads or more), twice.
    """
    T = 'bra  0xFC'                             # only as a comment: the trap is the filler
    del T
    for pg in GATE_PAGES:
        a.lines.append('gate%d_stop = 0x%04X' % (pg, (pg << 8) | (0xF0 if pg == 5 else 0xFC)))
    # gate 1: AC and the ALU.  Four stops, by what failed.
    g = [('gate1',)]
    g += ['ld   0x00, ac', 'bne  g1_flags', 'blt  g1_flags',
          'ld   0x80, ac', 'beq  g1_flags', 'blt  g1_neg', 'bra  g1_flags', ('g1_neg',),
          'ld   0x7F, ac', 'beq  g1_flags', 'blt  g1_flags']
    for v in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80):
        g += ['ld   0x%02X, ac' % v, 'beq  g1_bits', 'xor  0x%02X, ac' % v, 'bne  g1_bits']
    g += ['ld   0xFF, ac', 'xor  0xFF, ac', 'bne  g1_bits',
          'ld   0xF0, ac', 'and  0x3C, ac', 'xor  0x30, ac', 'bne  g1_bits',
          'ld   0x12, ac', 'or   0x21, ac', 'xor  0x33, ac', 'bne  g1_bits',
          'ld   0x0F, ac', 'add  0x01, ac', 'xor  0x10, ac', 'bne  g1_carry',
          'ld   0xFF, ac', 'add  0x01, ac', 'bne  g1_carry', 'bcc  g1_carry',
          'ld   0x7F, ac', 'add  0x01, ac', 'bcs  g1_carry',
          'ld   0x00, ac', 'sub  0x01, ac', 'bcc  g1_carry', 'xor  0xFF, ac', 'bne  g1_carry',
          'ld   0x80, ac', 'shr  ac', 'xor  0x40, ac', 'bne  g1_shift',
          'ld   0x10, ac', 'shr  ac', 'xor  0x08, ac', 'bne  g1_shift',
          'ld   0x01, ac', 'shr  ac', 'bne  g1_shift',
          'bra  gate_exit1',
          ('@E0', 'g1_flags'), 'bra  g1_flags',
          ('@E4', 'g1_bits'), 'bra  g1_bits',
          ('@E8', 'g1_carry'), 'bra  g1_carry',
          ('@EC', 'g1_shift'), 'bra  g1_shift']
    gate_page(a, 1, g)
    # gate 2: the AC source buffer.  With an AC source the ALU's B input is
    # AC; with no buffer it is the byte the bus still holds, the opcode
    # itself (clr ac = x62, shl = x82), so the result is wrong for these
    # values.  Then one branch to AC's address.
    g = [('gate2',)]
    for v in (0x55, 0xAA, 0x0F, 0xF0):
        g += ['ld   0x%02X, ac' % v, 'clr  ac', 'bne  gate2_stop']
    for v in (0x01, 0x21, 0x48, 0x14):
        g += ['ld   0x%02X, ac' % v, 'shl  ac', 'xor  0x%02X, ac' % (2 * v), 'bne  gate2_stop']
    g += ['ld   g2_a, ac', 'bra  ac', ('@80', 'g2_a'), 'bra  gate_exit2']
    gate_page(a, 2, g)
    # gate 3: the Y register, as the address high byte
    g = [('gate3',)]
    for pg in CONST_PAGES:
        g += ['ld   0x%02X, y' % pg, 'ld   [y,x], ac', 'xor  0x%02X, ac' % pg, 'bne  gate3_stop']
    g += ['bra  gate_exit3']
    gate_page(a, 3, g)
    # gate 4: the X register, as the address low byte (immediate -> X and
    # AC -> X), read back from the table at x3F00
    g = [('gate4',), 'ld   0x%02X, y' % (ID_TABLE >> 8)]
    for v in WALK:
        g += ['ld   0x%02X, x' % v, 'ld   [y,x], ac', 'xor  0x%02X, ac' % v, 'bne  gate4_stop']
    for v in (0x3C, 0xC3):
        g += ['ld   0x%02X, ac' % v, 'ld   ac, x', 'ld   0x00, ac', 'ld   [y,x], ac',
              'xor  0x%02X, ac' % v, 'bne  gate4_stop']
    g += ['ld   0x5A, ac', 'bra  gate_exit4']       # gate 5 starts with AC not 0
    gate_page(a, 4, g)
    # gate 5: the D source buffer, with the RAM in
    g = [('gate5',), 'beq  ac', 'ld   0x%02X, y' % (ID_TABLE >> 8)]
    vals = [0x00, 0xFF, 0x55, 0xAA, 0x0F, 0xF0, 0x33, 0xCC, 0x01, 0x80, 0x69, 0x96, 0x3C, 0xC3, 0x5A]
    for rnd in range(2):
        g += ['ld   0x00, ac', ('g5_loop%d' % rnd,), 'ld   ac, x']
        for v in vals[rnd * 8:] + vals[:rnd * 8]:
            g += ['ld   0x%02X, ac' % v, 'xor  0x%02X, ac' % v, 'bne  gate5_stop']
        g += ['ld   [y,x], ac', 'sub  0x01, ac', 'bne  g5_loop%d' % rnd]
    g += ['bra  gate_exit5']
    gate_page(a, 5, g, fill=(0x62, 0xFE))
    # gate 6: is the RAM there?  One byte in each chip (sections 1 and 4),
    # two patterns, then on to the core tests.
    g = [('gate6',), 'ld   0x50, y', 'ld   0x00, x', 'ld   0x12, [y,x]']
    for pg, v in ((0x20, 0xA5), (0x90, 0x5A), (0x20, 0x5A), (0x90, 0xA5)):
        g += ['ld   0x%02X, y' % pg, 'ld   0x10, x', 'ld   0x%02X, [y,x]' % v, 'ld   0x00, ac',
              'ld   [y,x], ac', 'xor  0x%02X, ac' % v, 'bne  gate6_stop']
    g += ['ld   0x50, y', 'ld   0x00, x', 'ld   0x00, [y,x]', 'ld   start >> 8, y', 'jmp  start']
    gate_page(a, 6, g)
    # gate 7: where test 16 (the video line read) waits at start-up
    gate_page(a, 7, [('gate7',)], last=True)


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
        a.c('at start-up a failure waits in gate 7 (the line read buffer U29 is the')
        a.c('last chip of the CPU to go in), not in fail loop 16')
        for zp, want in (('LR_AND', 0x00), ('LR_OR', 0xFF)):
            with a.block(20):
                ok = a.uniq('ok')
                a.i('ld   [0x%02X], ac' % ZP[zp], 'xor  0x%02X, ac' % want, 'beq  %s' % ok,
                    'ld   0x50, y', 'ld   0x00, x', 'ld   0x00, [y,x]',
                    'ld   gate7 >> 8, y', 'jmp  gate7')
                a.label(ok)
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
    ('s_kbd', 'KBD_NOW (KEYS HELD):'),
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
    a.org(CODE_PAGES[0] << 8, 'main: library set-up, status screen, frame loop')
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
    a.i('ld   LIB_FONT >> 8, ac', 'ld   ac, [FONT_PG]')    # the RAM tests wrote over the boot's
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
    a.c('frame loop')
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
    # the key state image, KBD_NOW: FF with no key held
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
    a.next_page()
    a.c('RAM page test, one page per frame')
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
    """rows 368-479: mode bytes and the color bands"""
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
    a.c('8 bpp: color = (row band) x 64 + (c and 63)')
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
    L += ['; bringup.asm - the bring-up test ROM (docs/hardware/BRINGUP.md)',
          ';',
          '; Written by gen_bringup.py; edit that, not this file.  A complete 32 KB',
          '; ROM image with its own reset code, for the 32K cartridge, which shows it',
          '; in both halves of the ROM: the byte at file offset f is read at x0000 + f',
          '; and at x8000 + f, so no two bytes here are x8000 apart',
          '; (test_bringup_sim.py --bin writes bringup.bin).',
          ';',
          '; Chip gates: pages x01-x07 stop the PC until the chips of one build step',
          '; work, so PC high = the gate it waits in: 1 AC and ALU, 2 AC source',
          '; buffer, 3 Y, 4 X, 5 D source buffer, 6 RAM, 7 line read buffer.',
          ';',
          '; Fail loops: test N stops at x0080 + 4N (PC high = 00, PC low Q7 = 1,',
          '; Q6:Q2 = N); test 16 at start-up waits in gate 7.  Tests:']
    L += [';   %s' % t for t in (
        '1 branches  2 AND  3 OR  4 XOR  5 ADD  6 SUB  7 carry  8 SHR',
        '9 AC/X  10 Y address  11 X address  12 ROM data  13 RAM data',
        '14 map register  15 RAM address lines  16 video line read')]
    L += [';', '; Date: 11/12/2026', '',
          '#include "placard.asm"', '#include "placard_lib.asm"', '']
    for k, v in ZP.items():
        L.append('%-8s = 0x%02X' % (k, v))
    # reset and fail loops
    a.org(0x0000, 'reset (the CPU starts at x0000 with the map all ROM); the nop is for\n'
             '; the cartridge hand-off, which can skip x0000 (docs/architecture/ROM.md)')
    a.lock += 1
    a.i('nop', 'bra  gate_exit0')
    a.lock -= 1
    a.org(FAIL_BASE + 4, 'fail loops: test N stops here at x0080 + 4N')
    for n in range(1, 17):
        a.org(FAIL_BASE + 4 * n)
        a.label('fail%d' % n)
        a.lock += 1
        a.i('bra  fail%d' % n)
        a.lock -= 1
    a.org(0x00FE, 'the end of the page: on into gate 1 (no jump: Y is not tested yet)')
    a.label('gate_exit0')
    a.lock += 1
    a.i('nop', 'nop')
    a.lock -= 1
    gates(a)
    # markers and tables
    a.org(0x0100, 'ROM markers for tests 10 and 14 (address -> value); sections 4-7 read\n'
                  '; the markers of sections 0-3 through the mirror')
    for ad, v in sorted(set(Y_MARKS) | set(m for m in SEC_MARKS if m[0] < 0x8000)):
        if (ad >> 8) in CONST_PAGES:
            assert v == ad >> 8             # already there: the page holds its number
            continue
        a.org(ad)
        a.data([v])
    for pg in CONST_PAGES:
        a.org(pg << 8, 'gate 3: page x%02X holds x%02X in every byte' % (pg, pg))
        a.data([pg] * 256)
    for (lo, v), (hi, w) in zip(SEC_MARKS[:4], SEC_MARKS[4:]):
        assert hi == lo + 0x8000 and v == w
    a.org(X_PAGE << 8, 'test 11: x%02X00 + v = v xor 5A' % X_PAGE)
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
    a.org(HELPER_PAGES[0] << 8, 'section 3: map test for section 1, RAM address test')
    a.pages = HELPER_PAGES
    fail_handler(a, 'fail_h3')
    for name, back in (('map_s1_a', s1_back_a), ('map_s1_b', s1_back_b)):
        a.label(name)
        ad, m = SEC_MARKS[1]
        map_section_test(a, 1, ad, m, 'fail_h3')
        a.jump(back)
    ram_addr_test(a, t14_back)

    # tables that start a page, and the RAM test's error return after one
    a.pages = None
    a.org(TBL4, 'band tables')
    a.label('tbl4')
    a.data([(c // 5) * 0x11 for c in range(80)])
    a.org(TBL2)
    a.label('tbl2')
    a.data([(c // 20) * 0x55 for c in range(80)])
    a.org(RT_TABLE, 'RAM test pages')
    a.label('rt_pages')
    a.data(RT_PAGES)
    # an error goes back to its pattern's loop: the bad-byte path left the
    # pattern number in T15B
    a.c('RAM test error return')
    a.label('rt_dispatch')
    a.lock += 1
    for pat in range(6):
        nx = a.uniq('dp')
        a.i('ld   [0x%02X], ac' % ZP['T15B'], 'xor  %d, ac' % pat, 'bne  %s' % nx)
        a.i('ld   rt_ret%d >> 8, y' % pat, 'jmp  rt_ret%d' % pat)
        a.label(nx)
    a.i('ld   rt_ret0 >> 8, y', 'jmp  rt_ret0')
    a.lock -= 1
    if a.addr > STR_ROOM[-1][0]:
        raise SystemExit('the RAM test error return is too long (%04X)' % a.addr)

    # strings: in the free ends of those pages, the rest in the last code pages
    room = [list(r) for r in STR_ROOM]
    rest = []
    for lb, st in STRINGS:
        for r in room:
            if r[0] + len(st) + 1 <= r[1]:
                a.org(r[0])
                a.label(lb)
                a.string(st)
                r[0] = a.addr
                break
        else:
            rest.append((lb, st))
    code_pages = list(CODE_PAGES)
    n = sum(len(st) + 1 for lb, st in rest)
    if n:
        npg = (n + 255) // 256
        spages, code_pages = code_pages[-npg:], code_pages[:-npg]
        assert spages == list(range(spages[0], spages[0] + npg))
        a.org(spages[0] << 8, 'strings')
        for lb, st in rest:
            a.label(lb)
            a.string(st)

    # main and the RAM page test fill the free pages under the library
    a.pages = code_pages
    main_program(a)
    ram_page_test(a)
    return '\n'.join(a.lines) + '\n'


def image(mem):
    """the 32 KB ROM file from the assembled bytes {address: value}: address
    a is file offset a & x7FFF.  Two bytes at one offset stop it."""
    img = {}
    for ad, v in mem.items():
        f = ad & 0x7FFF
        if f in img:
            raise SystemExit('x%04X and x%04X both use ROM file offset x%04X' % (f, f | 0x8000, f))
        img[f] = v
    return bytes(img.get(f, 0xFF) for f in range(0x8000))


if __name__ == '__main__':
    import sys
    sys.path.insert(0, HERE)
    src = generate()
    open(os.path.join(HERE, 'bringup.asm'), 'w').write(src)
    print('wrote bringup.asm, %d lines' % src.count('\n'))
