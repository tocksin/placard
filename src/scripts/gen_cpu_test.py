#!/usr/bin/env python3
"""
gen_cpu_test.py - generate cpu_test.asm, a self-checking test of every valid
Placard CPU instruction with a pass/fail grid on the video output.

    python3 gen_cpu_test.py            writes cpu_test.asm next to this script

Then assemble with customasm (or placard_sim.py), put into rom.mem
with gen_rom.tcl (set ::ASM_FILE to cpu_test.hex) and run.

SCREEN (8 bpp, every row)
    A grid laid out like the opcode map: 8 columns = ALU op (I7:I5:
    LD AND OR XOR ADD SUB SHR BRA), 32 rows = memory mode / source
    (M2:M0 S1:S0, row = opcode bits 4:0).  One cell per opcode.
        black        not a valid instruction (not tested)
        grey         valid, test not run yet (CPU stopped before it)
        green        test passed
        red          test failed
    A bar across the top shows the overall result once every test has
    run: green = all passed, red = at least one failure.  No bar means
    the program never reached the end.

    Cell for opcode OP: column j = OP >> 5, row k = OP & 31
        byte columns 4 + 9j .. 11 + 9j  (8 pixels of 8 screen pixels each)
        screen rows  32 + 12k .. 41 + 12k

MEMORY
    0000-0003   reset: jump to main
    0008        scratch for Y-destination tests ([Y,08])
    0010-001F   test framework variables
    0020-007F   test data (zero page)
    0100, 0200  drawing tables indexed by opcode (row, page)
    0320-03DA   list of valid opcodes
    0400-...    framework and tests
    4200-42FF   test data page for [y,x] tests
    4300-43FF   marks for the X-destination tests
    5A20-5BFF   mode bytes: 8 bpp, and rows with nothing on them blanked
    6000-FFFF   video RAM (cleared and set to 8 bpp by the program)

Every test reads memory back, so the test areas must read as RAM (the
current FPGA build reads all addresses from the RAM copy).

Date: 10/22/2026
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from placard_sim import instr_size   # noqa: E402
from menu_hook import hook_blocks   # noqa: E402

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------
ZOP, ZRES, ZRETL, ZRETH = 0x10, 0x11, 0x12, 0x13
ZPG, ZROW, ZCNT, ZI, ZFAIL, ZCOL = 0x14, 0x15, 0x16, 0x17, 0x18, 0x19
ROWPG, PAGEPG, VALPG, DATAPG = 0x01, 0x02, 0x03, 0x42
TX = 0x08            # X used for the Y-destination tests
MARK = 0xA5

COLORS = {0: 0x4A, 1: 0xE0, 2: 0x07, 3: 0xFF}   # grey, green, red, white (G3G2G1 B3B2 R3R2R1)
COLOR_NAMES = {0: 'grey', 1: 'green', 2: 'red', 3: 'white'}

ALU = ['ld', 'and', 'or', 'xor', 'add', 'sub', 'shr', 'bra']
BR = ['jmp', 'bcs', 'blt', 'bne', 'beq', 'bcc', 'ble', 'bra']
DST = {0: 'ac', 3: 'x', 4: 'y'}
SRC = {2: 'ac', 3: 'ac'}   # source 11 drives AC like 10 (no X source, 2026-10-19)
XPG = 0x43           # page for the X-destination tests ([XPG, X] marks)
ZHRET = 0x1E         # return address for the menu hook (0x1E, 0x1F), after the tests


def h(v):
    return '0x%02X' % v


def zp(a):
    return '[0x%02X]' % a


def valid(opc):
    a, m, s = opc >> 5, (opc >> 2) & 7, opc & 3
    if a <= 5:
        if m == 5 and s == 1:
            return False
        if m in (1, 2) and s in (0, 2, 3):
            return False
        return True
    if a == 6:
        return s == 2 and m not in (1, 2)
    return not (m == 5 and s == 1)


VALID = [o for o in range(256) if valid(o)]
assert len(VALID) == 187


def alu(a, A, B):
    return [B, A & B, A | B, A ^ B, (A + B) & 0xFF, (A - B) & 0xFF, A >> 1, A][a]


def taken(c, ac, carry=0):
    z = ac == 0
    n = ac >> 7
    return [True, carry, not z and n, not z, z, not carry, z or n, True][c]


def is_carry_branch(c):
    return c in (1, 5)


# ways to set the carry flag before a BCS / BCC test: (instructions, carry).
# The flag is latched by ADD / SUB with an AC, X or Y destination (carry out,
# or borrow out for SUB) and kept by everything else, the loads and stores
# between here and the branch included, and an ADD that stores to RAM.
CARRY_SETS = [
    (['ld 0xFF, ac', 'add 0x01, ac'], 1),                   # carry out
    (['ld 0x10, ac', 'add 0x10, ac'], 0),
    (['ld 0x00, ac', 'sub 0x01, ac'], 1),                   # borrow
    (['ld 0x05, ac', 'sub 0x03, x'], 0),                    # X destination
    (['ld 0xF0, ac', 'add 0x20, y'], 1),                    # Y destination
    (['ld 0x01, ac', 'sub 0x01, ac'], 0),                   # equal: no borrow
    (['ld 0x80, ac', 'add 0x80, ac', 'ld 0x7F, ac', 'add ac, %s' % zp(0x44)], 1),
    (['ld 0x00, ac', 'add 0x00, ac', 'ld 0xFF, ac', 'add ac, %s' % zp(0x44)], 0),
]


# ---------------------------------------------------------------------------
# block placement
# ---------------------------------------------------------------------------
class Block:
    """a run of code that never falls through to the next block"""

    def __init__(self, name, page_start=False, at=None):
        self.name = name
        self.items = []          # ('L', label) | ('I', text, comment) | ('R', raw, size)
        self.page_start = page_start
        self.at = at

    def L(self, label):
        self.items.append(('L', label))

    def I(self, text, comment=''):
        self.items.append(('I', text, comment))

    def T(self, opc, text, comment=''):
        """the instruction under test.  Source 11 has no assembler syntax
        (it drives AC like 10), so it is written as bytes: the opcode, then
        the operand byte of the same instruction with source 10"""
        if opc & 3 != 3:
            self.I(text, comment)
            return
        n = instr_size(text)
        out = '#d8 %s' % h(opc)
        if n == 2:
            m = re.search(r'\[(0x[0-9A-Fa-f]+)\]', text)
            out += ', ' + (m.group(1) if m else '0x00')
        self.raw('%-26s; %s (%s, source 11)' % (out, comment, text), n)

    def raw(self, text, size):
        self.items.append(('R', text, size))

    def size(self):
        n = 0
        for it in self.items:
            if it[0] == 'I':
                n += instr_size(it[1])
            elif it[0] == 'R':
                n += it[2]
        return n

    def offset_of(self, label):
        n = 0
        for it in self.items:
            if it[0] == 'L' and it[1] == label:
                return n
            if it[0] == 'I':
                n += instr_size(it[1])
            elif it[0] == 'R':
                n += it[2]
        raise KeyError(label)


class Program:
    def __init__(self):
        self.out = []
        self.addr = 0
        self.limit = 0x10000

    def place(self, b):
        size = b.size()
        if b.at is not None:
            start = b.at
        elif b.page_start:
            start = self.addr if (self.addr & 0xFF) == 0 else (self.addr | 0xFF) + 1
        else:
            start = self.addr
            if (start & 0xFF) + size > 0x100:
                start = (start | 0xFF) + 1
        if start < self.addr:
            raise ValueError('block %s at %04X overlaps (current %04X)' % (b.name, start, self.addr))
        if start + size > self.limit:
            raise ValueError('block %s does not fit below %04X' % (b.name, self.limit))
        if (start & 0xFF) + size > 0x100 and not getattr(b, 'may_cross', False):
            raise ValueError('block %s crosses a page (%04X + %d)' % (b.name, start, size))
        if start != self.addr or not self.out:
            self.out.append('')
            self.out.append('#addr 0x%04X' % start)
        for it in b.items:
            if it[0] == 'L':
                self.out.append('%s:' % it[1])
            elif it[0] == 'I':
                line = '    %-26s' % it[1]
                if it[2]:
                    line += '; ' + it[2]
                self.out.append(line.rstrip())
            else:
                self.out.append('    ' + it[1])
        self.addr = start + size
        return start


def epilogue(b, opc, nxt):
    """AC = 0 (pass) or not 0 (fail): record and draw the result, then
    continue at label nxt"""
    b.I('ld ac, %s' % zp(ZRES), 'result (0 = pass)')
    b.I('ld %s, ac' % h(opc))
    b.I('ld ac, %s' % zp(ZOP), 'opcode under test')
    b.I('ld %s & 0xFF, ac' % nxt)
    b.I('ld ac, %s' % zp(ZRETL))
    b.I('ld %s >> 8, ac' % nxt)
    b.I('ld ac, %s' % zp(ZRETH), 'return to the next test')
    b.I('ld report >> 8, y')
    b.I('jmp report')


def far(b, label):
    b.I('ld %s >> 8, y' % label)
    b.I('jmp %s' % label)


# ---------------------------------------------------------------------------
# instruction text for an opcode
# ---------------------------------------------------------------------------
MEMSRC = {0: zp(0x40), 3: zp(0x40), 4: zp(0x40), 1: '[x]', 2: '[y,x]', 6: '[x]', 7: '[y,x]'}


def text_of(opc, imm=None, zpaddr=None):
    a, m, s = opc >> 5, (opc >> 2) & 7, opc & 3
    if a == 6:
        d = {0: 'ac', 3: 'x', 4: 'y', 6: '[x]', 7: '[y,x]'}.get(m) or zp(zpaddr)
        return 'shr %s' % d
    name = ALU[a]
    if m in (0, 3, 4):
        dst = DST[m]
    elif m in (1, 2):
        dst = 'ac'
    elif m == 5:
        dst = zp(zpaddr)
    else:
        dst = {6: '[x]', 7: '[y,x]'}[m]
    if s == 0:
        src = h(imm)
    elif s == 1:
        src = zp(zpaddr) if m in (0, 3, 4) else ('[x]' if m in (1, 6) else '[y,x]')
    else:
        src = SRC[s]
    return '%s %s, %s' % (name, src, dst)


# ---------------------------------------------------------------------------
# ALU / SHR tests
# ---------------------------------------------------------------------------
def alu_test(b, opc, nxt):
    a, m, s = opc >> 5, (opc >> 2) & 7, opc & 3
    ydest = (m == 4)
    A, B = (0xE6, 0x7C) if ydest else (0xC6, 0x5A)
    if a == 6:
        A = 0xCC if ydest else 0xD6
    tag = 't%02X' % opc

    if a == 6:                                   # SHR, source = AC
        if m in (0, 3, 4):
            res = A >> 1
        else:
            res = A                              # stores write the source bus (AC)
    elif m in (0, 1, 2, 3, 4):
        bval = {0: B, 1: B, 2: A, 3: A}[s]
        res = alu(a, A, bval)
    else:
        res = None

    # ---- register destinations ----
    if m in (0, 1, 2, 3) or (a == 6 and m in (0, 3)):
        if m == 3:                                # X is checked through a mark at [XPG, X]
            b.I('ld %s, y' % h(XPG)); b.I('ld %s, x' % h(res)); b.I('ld 0, [y,x]', 'clear [%02X%02X]' % (XPG, res))
        if s == 1:
            if m in (0, 3):
                b.I('ld %s, ac' % h(B)); b.I('ld ac, %s' % zp(0x40), 'memory operand')
            elif m == 1:
                b.I('ld %s, ac' % h(B)); b.I('ld ac, %s' % zp(0x41)); b.I('ld 0x41, x')
            else:
                b.I('ld %s, ac' % h(B)); b.I('ld %s, y' % h(DATAPG)); b.I('ld 0x41, x')
                b.I('ld ac, [y,x]')
        if s == 3:
            b.I('ld %s, x' % h(B), 'X must not be the source')
        elif m == 3:
            b.I('ld %s, x' % h(res ^ 0xFF), 'X != expected before the test')
        b.I('ld %s, ac' % h(A))
        t = text_of(opc, imm=B, zpaddr=0x40)
        b.T(opc, t, 'TEST %02X' % opc)
        if m == 3:
            b.I('ld %s, [y,x]' % h(MARK), 'mark [%02X,X]' % XPG)
            b.I('ld %s, x' % h(res)); b.I('ld [y,x], ac', 'read [%02X%02X]' % (XPG, res))
            b.I('xor %s, ac' % h(MARK))
            epilogue(b, opc, nxt)
            return
        b.I('xor %s, ac' % h(res), 'expect %02X' % res)
        epilogue(b, opc, nxt)
        return

    # ---- Y destination: check through a store at [Y,08] ----
    if m == 4:
        b.I('ld %s, y' % h(res)); b.I('ld %s, x' % h(TX)); b.I('ld 0, [y,x]', 'clear [%02X%02X]' % (res, TX))
        b.I('ld %s, y' % h(DATAPG), 'Y != expected before the test')
        if s == 1:
            b.I('ld %s, ac' % h(B)); b.I('ld ac, %s' % zp(0x40))
        if s == 3:
            b.I('ld %s, x' % h(B), 'X must not be the source')
        b.I('ld %s, ac' % h(A))
        b.T(opc, text_of(opc, imm=B, zpaddr=0x40), 'TEST %02X, Y = %02X' % (opc, res))
        b.I('ld %s, x' % h(TX)); b.I('ld %s, [y,x]' % h(MARK), 'mark [Y,08]')
        b.I('ld %s, y' % h(res)); b.I('ld [y,x], ac', 'read [%02X%02X]' % (res, TX))
        b.I('xor %s, ac' % h(MARK))
        epilogue(b, opc, nxt)
        return

    # ---- stores ----
    if s == 1:                                    # memory -> same location
        if m == 6:
            b.I('ld %s, ac' % h(B)); b.I('ld ac, %s' % zp(0x43)); b.I('ld 0x43, x')
        else:
            b.I('ld %s, ac' % h(B)); b.I('ld %s, y' % h(DATAPG)); b.I('ld 0x43, x'); b.I('ld ac, [y,x]')
        b.I('ld %s, ac' % h(A))
        b.I(text_of(opc), 'TEST %02X (writes the value back)' % opc)
        b.I('ld [x], ac' if m == 6 else 'ld [y,x], ac')
        b.I('xor %s, ac' % h(B))
        epilogue(b, opc, nxt)
        return

    if s == 0:
        val = MARK
        if m == 5:
            n = 0x60 + a
            b.I('ld 0, ac'); b.I('ld ac, %s' % zp(n), 'clear')
            b.I('ld %s, ac' % h(A))
            b.I('%s %s, %s' % (ALU[a], h(n), zp(n)), 'TEST %02X: [%02X] = %02X' % (opc, n, n))
            b.I('ld %s, ac' % zp(n)); b.I('xor %s, ac' % h(n))
            epilogue(b, opc, nxt)
            return
        addr_x = 0x31
    elif s == 2:
        val, addr_x = A, 0x30
    else:
        val, addr_x = A, B                        # source 11 = AC; X is only the address
    if m == 5:
        n = {0: None, 2: 0x51, 3: 0x50}[s] if a != 6 else 0x52
        b.I('ld 0, ac'); b.I('ld ac, %s' % zp(n), 'clear')
        if s == 3:
            b.I('ld %s, x' % h(B))
        b.I('ld %s, ac' % h(A))
        b.T(opc, text_of(opc, zpaddr=n), 'TEST %02X' % opc)
        b.I('ld %s, ac' % zp(n))
    else:
        if a == 6:
            addr_x = 0x33
        if m == 7:
            b.I('ld %s, y' % h(DATAPG))
        b.I('ld %s, x' % h(addr_x))
        if m == 6:
            b.I('ld 0, ac'); b.I('ld ac, [x]', 'clear')
        else:
            b.I('ld 0, [y,x]', 'clear')
        b.I('ld %s, ac' % h(A))
        b.T(opc, text_of(opc, imm=val), 'TEST %02X' % opc)
        b.I('ld [x], ac' if m == 6 else 'ld [y,x], ac')
    b.I('xor %s, ac' % h(val), 'expect %02X (source bus)' % val)
    epilogue(b, opc, nxt)


# ---------------------------------------------------------------------------
# branch tests
# ---------------------------------------------------------------------------
CASES = [0x00, 0x01, 0x10, 0x7F, 0x80, 0xFF]


def branch_target_setup(b, m, s, target):
    """make the branch under test point at label target"""
    if s == 1:
        if m in (0, 3, 4):
            b.I('ld %s & 0xFF, ac' % target); b.I('ld ac, %s' % zp(0x45))
        elif m in (1, 6):
            b.I('ld %s & 0xFF, ac' % target); b.I('ld ac, %s' % zp(0x46)); b.I('ld 0x46, x')
        else:
            b.I('ld %s & 0xFF, ac' % target); b.I('ld %s, y' % h(DATAPG)); b.I('ld 0x46, x')
            b.I('ld ac, [y,x]')


def branch_text(c, m, s, target=None):
    if s == 0:
        return '%s %s' % (BR[c], target)
    if s == 2:
        return '%s ac' % BR[c]
    if m in (0, 3, 4):
        return '%s %s' % (BR[c], zp(0x45))
    return '%s %s' % (BR[c], '[x]' if m in (1, 6) else '[y,x]')


def cond_test(prog, entry, opc, nxt):
    """conditional branch / BRA with an immediate or memory target"""
    c, m, s = opc >> 2 & 7, (opc >> 2) & 7, opc & 3
    tag = 't%02X' % opc
    b = Block(tag)
    b.L(entry)
    if is_carry_branch(c):
        cases = [(CASES[i % len(CASES)], st) for i, st in enumerate(CARRY_SETS)]
    else:
        cases = [(v, ([], 0)) for v in (CASES if c != 7 else [0x00, 0x80])]
    for i, (v, (setc, cy)) in enumerate(cases):
        tk = taken(c, v, cy)
        nxt_case = '%s_c%d' % (tag, i + 1)
        target = nxt_case if tk else '%s_fail' % tag
        for t in setc:
            b.I(t)
        branch_target_setup(b, m, s, target)
        b.I('ld %s, ac' % h(v))
        cmt = 'AC=%02X' % v + (', carry %d' % cy if is_carry_branch(c) else '')
        b.I(branch_text(c, m, s, target), 'TEST %02X, %s %s' % (opc, cmt, 'taken' if tk else 'not taken'))
        if tk:
            b.I('bra %s_fail' % tag)
        b.L(nxt_case)
    b.I('ld 0, ac')
    b.I('bra %s_rep' % tag)
    b.L('%s_fail' % tag)
    b.I('ld 1, ac')
    b.L('%s_rep' % tag)
    epilogue(b, opc, nxt)
    prog.place(b)


def ac_branch_test(prog, entry, opc, nxt):
    """conditional branch / BRA with the accumulator as target: the AC value
    is both the condition and the target offset, so landing pads sit at
    offsets 00, 40 and 80 of the page"""
    c = (opc >> 2) & 7
    tag = 't%02X' % opc
    vals = [0x00, 0x40, 0x80]
    # BCS / BCC: carry 1, 0, 1 (an ADD carry, an equal SUB, a SUB borrow)
    csets = [CARRY_SETS[0], CARRY_SETS[5], CARRY_SETS[2]] if is_carry_branch(c) else [([], 0)] * 3
    b = Block(tag, page_start=True)
    pads = {}
    for i, v in enumerate(vals):
        tk = taken(c, v, csets[i][1])
        pads[v] = '%s_c%d' % (tag, i + 1) if tk else '%s_fail' % tag
    b.L('%s_pad00' % tag)
    b.I('bra %s' % pads[0x00], 'landing pad for AC = 00')
    b.L(entry)
    for i, v in enumerate(vals):
        setc, cy = csets[i]
        tk = taken(c, v, cy)
        for t in setc:
            b.I(t)
        b.I('ld %s, ac' % h(v))
        cmt = 'AC=%02X' % v + (', carry %d' % cy if is_carry_branch(c) else '')
        b.T(opc, '%s ac' % BR[c], 'TEST %02X, %s %s' % (opc, cmt, 'taken' if tk else 'not taken'))
        if tk:
            b.I('bra %s_fail' % tag)
        b.L('%s_c%d' % (tag, i + 1))
    b.I('ld 0, ac')
    b.I('bra %s_rep' % tag)
    b.L('%s_fail' % tag)
    b.I('ld 1, ac')
    b.L('%s_rep' % tag)
    epilogue(b, opc, nxt)
    if b.size() > 0x40:
        raise ValueError('%s too big for the pad layout' % tag)
    start = prog.place(b)
    for v in (0x40, 0x80):
        p = Block('%s_pad%02X' % (tag, v), at=start + v)
        p.L('%s_pad%02X' % (tag, v))
        p.I('bra %s' % pads[v], 'landing pad for AC = %02X' % v)
        prog.place(p)


def jmp_test(prog, entry, opc, nxt):
    """JMP: 16-bit target.  The landing point is in the next page at the
    same offset as this test's fail label, so a JMP that does not load PC
    high lands on the fail path."""
    s = opc & 3
    tag = 't%02X' % opc
    land = '%s_land' % tag
    b = Block(tag, page_start=True)
    b.L(entry)
    b.I('ld %s >> 8, y' % land, 'PC high comes from Y')
    if s in (2, 3):
        b.I('ld %s & 0xFF, ac' % land)
    elif s == 1:
        b.I('ld %s & 0xFF, ac' % land); b.I('ld ac, %s' % zp(0x47))
    b.T(opc, {0: 'jmp %s' % land, 1: 'jmp %s' % zp(0x47), 2: 'jmp ac', 3: 'jmp ac'}[s], 'TEST %02X' % opc)
    b.L('%s_fail' % tag)
    b.I('ld 1, ac', 'fall-through or PC high not loaded')
    epilogue(b, opc, nxt)
    start = prog.place(b)
    f = b.offset_of('%s_fail' % tag)
    lb = Block(land, at=((start >> 8) + 1 << 8) + f)
    lb.L(land)
    lb.I('ld 0, ac')
    epilogue(lb, opc, nxt)
    prog.place(lb)


# ---------------------------------------------------------------------------
# framework
# ---------------------------------------------------------------------------
def framework_blocks(prog, first_test):
    # reset
    b = Block('reset', at=0)
    b.L('reset')
    b.I('ld main >> 8, y')
    b.I('jmp main')
    prog.place(b)

    # tables, indexed by opcode: first row (low address byte) and first
    # page of the cell.  Using lookups keeps AND / SHR out of the drawing
    # code, so a broken AND or SHR shows up as red cells, not a garbled grid.
    rowlo = Block('tab_rowlo', at=ROWPG << 8)
    rowlo.L('tab_rowlo')
    page = Block('tab_page', at=PAGEPG << 8)
    page.L('tab_page')
    for i in range(0, 256, 16):
        rl, pg = [], []
        for o in range(i, i + 16):
            j, k = o >> 5, o & 31
            off = 0x40 + 12 * k
            rl.append(h(off & 0xFF))
            pg.append(h(0x60 + 2 * (4 + 9 * j) + (off >> 8)))
        rowlo.raw('#d8 ' + ', '.join(rl), 16)
        page.raw('#d8 ' + ', '.join(pg), 16)
    prog.place(rowlo)
    prog.place(page)
    v = Block('tab_valid', at=(VALPG << 8) + 0x20)
    v.L('tab_valid')
    for i in range(0, len(VALID), 16):
        chunk = VALID[i:i + 16]
        v.raw('#d8 ' + ', '.join(h(o) for o in chunk), len(chunk))
    prog.place(v)

    # main: clear video RAM, 8 bpp everywhere, draw pending cells
    b = Block('main', at=0x0400)
    b.L('main')
    b.I('ld 0x60, ac'); b.I('ld ac, %s' % zp(ZPG), 'clear pages 60..FF')
    b.L('clr_pg')
    b.I('ld %s, y' % zp(ZPG))
    b.I('ld 0, ac')
    b.L('clr_in')
    b.I('ld ac, x'); b.I('ld 0, [y,x]'); b.I('inc'); b.I('bne clr_in')
    b.I('ld %s, ac' % zp(ZPG)); b.I('inc'); b.I('ld ac, %s' % zp(ZPG)); b.I('bne clr_pg')
    b.I('ld 0x5A, y', 'mode byte of every row = 83 (8 bpp, blanked), x5A20-x5BFF')
    b.I('ld 0x20, ac')
    b.L('mode1')
    b.I('ld ac, x'); b.I('ld 0x83, [y,x]'); b.I('inc'); b.I('bne mode1')
    b.I('ld 0x5B, y')
    b.L('mode2')
    b.I('ld ac, x'); b.I('ld 0x83, [y,x]'); b.I('inc'); b.I('bne mode2')
    far(b, 'modes')
    prog.place(b)

    # the rows with something on them are shown (mode byte 3); the rest stay
    # blanked: black, and the video makes no reads on them, so the CPU is not
    # stalled there (VIDEO.md "Blank line")
    b = Block('modes')
    b.L('modes')
    b.I('ld 0x5A, y', 'the bar, screen rows 8-19')
    b.I('ld 11, ac')
    b.L('mbar')
    b.I('add 0x28, x'); b.I('ld 3, [y,x]'); b.I('sub 1, ac'); b.I('bcc mbar')
    b.I('ld 0x40, ac'); b.I('ld ac, %s' % zp(ZROW), 'the cells, 10 of every 12 rows from row 32')
    b.I('ld 0x5A, ac'); b.I('ld ac, %s' % zp(ZPG))
    b.I('ld 32, ac'); b.I('ld ac, %s' % zp(ZCNT))
    b.L('mcell')
    b.I('ld %s, y' % zp(ZPG)); b.I('ld 9, ac')
    b.L('mcrow')
    b.I('add %s, x' % zp(ZROW)); b.I('ld 3, [y,x]'); b.I('sub 1, ac'); b.I('bcc mcrow')
    b.I('ld %s, ac' % zp(ZROW)); b.I('add 12, ac'); b.I('ld ac, %s' % zp(ZROW))
    b.I('bcc mcnc')
    b.I('ld %s, ac' % zp(ZPG)); b.I('inc'); b.I('ld ac, %s' % zp(ZPG))
    b.L('mcnc')
    b.I('ld %s, ac' % zp(ZCNT)); b.I('sub 1, ac'); b.I('ld ac, %s' % zp(ZCNT))
    b.I('bne mcell')
    far(b, 'pend')
    prog.place(b)

    b = Block('pend')
    b.L('pend')
    b.I('ld 0, ac'); b.I('ld ac, %s' % zp(ZFAIL)); b.I('ld ac, %s' % zp(ZI))
    b.L('pend_loop')
    b.I('ld %s, ac' % zp(ZI), 'draw every valid cell grey')
    b.I('add 0x20, ac'); b.I('ld ac, x'); b.I('ld %s, y' % h(VALPG)); b.I('ld [y,x], ac')
    b.I('ld ac, %s' % zp(ZOP))
    b.I('ld 0, ac'); b.I('ld ac, %s' % zp(ZCOL))
    b.I('ld pend_ret & 0xFF, ac'); b.I('ld ac, %s' % zp(ZRETL))
    b.I('ld pend_ret >> 8, ac'); b.I('ld ac, %s' % zp(ZRETH))
    far(b, 'draw')
    b.L('pend_ret')
    b.I('ld %s, ac' % zp(ZI)); b.I('inc'); b.I('ld ac, %s' % zp(ZI))
    b.I('xor %d, ac' % len(VALID)); b.I('bne pend_loop')
    far(b, first_test)
    prog.place(b)

    # report: ZRES -> colour, count failures, draw, return
    b = Block('report')
    b.L('report')
    b.I('ld %s, ac' % zp(ZRES))
    b.I('bne rep_fail')
    b.I('ld 1, ac'); b.I('ld ac, %s' % zp(ZCOL))
    far(b, 'draw')
    b.L('rep_fail')
    b.I('ld 2, ac'); b.I('ld ac, %s' % zp(ZCOL))
    b.I('ld %s, ac' % zp(ZFAIL)); b.I('inc'); b.I('ld ac, %s' % zp(ZFAIL))
    far(b, 'draw')
    prog.place(b)

    # draw: cell for opcode ZOP in colour ZCOL, return to ZRETH:ZRETL
    b = Block('draw')
    b.L('draw')
    b.I('ld %s, ac' % zp(ZOP)); b.I('ld ac, x')
    b.I('ld %s, y' % h(ROWPG)); b.I('ld [y,x], ac'); b.I('ld ac, %s' % zp(ZROW), 'first row (low address byte)')
    b.I('ld %s, y' % h(PAGEPG)); b.I('ld [y,x], ac'); b.I('ld ac, %s' % zp(ZPG), 'first page')
    b.I('ld 8, ac'); b.I('ld ac, %s' % zp(ZCNT), '8 byte columns')
    b.I('ld %s, ac' % zp(ZCOL))
    b.I('beq draw_c0'); b.I('xor 1, ac'); b.I('beq draw_c1'); b.I('xor 3, ac'); b.I('beq draw_c2')
    far(b, 'fill3')
    b.L('draw_c0'); far(b, 'fill0')
    b.L('draw_c1'); far(b, 'fill1')
    b.L('draw_c2'); far(b, 'fill2')
    prog.place(b)

    for k in range(4):
        b = Block('fill%d' % k)
        b.L('fill%d' % k)
        b.I('ld %s, y' % zp(ZPG)); b.I('ld %s, ac' % zp(ZROW))
        for r in range(10):
            b.I('ld ac, x'); b.I('ld %s, [y,x]' % h(COLORS[k]), COLOR_NAMES[k] if r == 0 else ''); b.I('inc')
        b.I('ld %s, ac' % zp(ZPG)); b.I('add 2, ac'); b.I('ld ac, %s' % zp(ZPG))
        b.I('ld %s, ac' % zp(ZCNT)); b.I('add 0xFF, ac'); b.I('ld ac, %s' % zp(ZCNT))
        b.I('bne fill%d' % k)
        b.I('ld %s, y' % zp(ZRETH)); b.I('jmp %s' % zp(ZRETL), 'return')
        prog.place(b)

    # final: status bar
    b = Block('final')
    b.L('final')
    b.I('ld %s, ac' % zp(ZFAIL))
    b.I('beq final_ok')
    far(b, 'bar2')
    b.L('final_ok')
    far(b, 'bar1')
    prog.place(b)
    for k in (1, 2):
        b = Block('bar%d' % k)
        b.L('bar%d' % k)
        b.I('ld 0x68, ac'); b.I('ld ac, %s' % zp(ZPG))
        b.I('ld 71, ac'); b.I('ld ac, %s' % zp(ZCNT))
        b.L('bar%d_l' % k)
        b.I('ld %s, y' % zp(ZPG)); b.I('ld 0x28, ac')
        for r in range(12):
            b.I('ld ac, x'); b.I('ld %s, [y,x]' % h(COLORS[k])); b.I('inc')
        b.I('ld %s, ac' % zp(ZPG)); b.I('add 2, ac'); b.I('ld ac, %s' % zp(ZPG))
        b.I('ld %s, ac' % zp(ZCNT)); b.I('add 0xFF, ac'); b.I('ld ac, %s' % zp(ZCNT))
        b.I('bne bar%d_l' % k)
        b.I('ld halt%d & 0xFF, ac' % k, 'done: show the result (10 s when the')
        b.I('ld ac, %s' % zp(ZHRET), 'menu is rotating, menu_hook.py)')
        b.I('ld halt%d >> 8, ac' % k)
        b.I('ld ac, %s' % zp(ZHRET + 1))
        far(b, 'hk_hold')
        b.L('halt%d' % k)
        b.I('ld halt%d & 0xFF, ac' % k, 'then poll the menu hook (Esc, time up)')
        b.I('ld ac, %s' % zp(ZHRET))
        b.I('ld halt%d >> 8, ac' % k)
        b.I('ld ac, %s' % zp(ZHRET + 1))
        far(b, 'hk_poll')
        prog.place(b)

    for name, items in hook_blocks(ZHRET, ZHRET + 1):
        b = Block(name)
        for kind, text in items:
            if kind == 'L':
                b.L(text)
            else:
                code, _, comment = text.partition(';')
                b.I(code.strip(), comment.strip())
        prog.place(b)


def generate():
    prog = Program()
    prog.limit = DATAPG << 8
    entries = ['t%02X' % o for o in VALID] + ['final']
    framework_blocks(prog, entries[0])
    for i, opc in enumerate(VALID):
        entry, nxt = entries[i], entries[i + 1]
        a, m, s = opc >> 5, (opc >> 2) & 7, opc & 3
        if a < 7:
            b = Block(entry)
            b.L(entry)
            alu_test(b, opc, nxt)
            prog.place(b)
        elif m == 0:
            jmp_test(prog, entry, opc, nxt)
        elif s in (2, 3):
            ac_branch_test(prog, entry, opc, nxt)
        else:
            cond_test(prog, entry, opc, nxt)
    head = __doc__.strip().splitlines()
    lines = ['; ' + l if l else ';' for l in head[:-1]]
    lines[0] = '; cpu_test.asm - generated by gen_cpu_test.py, do not edit by hand'
    lines += [';', '; Date: 10/22/2026', '', '#include "placard.asm"']
    return '\n'.join(lines + prog.out) + '\n', prog.addr


if __name__ == '__main__':
    text, top = generate()
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, 'cpu_test.asm')
    open(path, 'w').write(text)
    print('wrote %s, %d tests, code ends at %04X' % (path, len(VALID), top))
