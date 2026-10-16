#!/usr/bin/env python3
"""
placard_sim.py - assembler and instruction-level simulator for the Placard CPU

    python3 placard_sim.py prog.asm                 assemble, write prog.hex
    python3 placard_sim.py prog.asm --run           assemble and run
    python3 placard_sim.py prog.asm --run --hw-alu  run with the VHDL alu4 model
    python3 placard_sim.py prog.asm --run --png out.png   also render the screen
    python3 placard_sim.py prog.asm --run --stop-at LABEL  stop when PC = LABEL

The assembler accepts the syntax defined in placard.asm (it is not a general
customasm replacement: only #include, #addr, #d8 and #d ("strings" and 0x
hex literals) directives and
"NAME = expression" constants are supported).  #include "file" pastes the
file in, relative to the including file, except placard.asm (the rule
definitions), which is skipped.  A constant must be defined before an #addr
that uses it.  Use it to check programs and to get a hex file
when customasm is not at hand; customasm with placard.asm should produce the
same bytes.

The simulator follows the hardware instruction flow (State PLD rev 12,
Branch PLD rev 09):
  - operand byte fetched for: immediate source; memory source with a [0,D]
    mode (MEM 000, 011, 100); register source with MEM 101 (zero-page store,
    or BGE with an AC or X target, whose second byte is a pad byte)
  - memory source reads into D (LOAD_MEM); the source bus is D, AC or X
  - register source with MEM 110 or 111 also passes through LOAD_MEM (one
    more clock; the read into D is not used)
  - ALU: A = AC, B = source bus
  - dest AC / X / Y load the ALU result; RAM stores take the SOURCE BUS
  - branches: Z and NEG from the accumulator; PC low <- source bus,
    JMP also loads PC high <- Y
  - ADD and SUB with an AC, X or Y destination take one extra clock
    (the Branch PLD's ALU wait clock); stores do not
  - a read of x5000-x50FF (or its x5800 mirror) returns the video line read,
    V9:V2, with one line per 800 CPU clocks and V = 499-1023 (525 lines per
    frame).  Video fetch stalls are not modeled.

--hw-alu evaluates the ALU with the exact alu4.vhd equations wired as in
basys_top.vhd (low nibble CIN = 0, high nibble CIN = low nibble COUT, low
SHIFT_RIGHT_IN = AC bit 4, high SHIFT_RIGHT_IN = 0).  The default is an ideal
8-bit ALU (A - B is a true 8-bit subtraction).

Date: 10/16/2026
"""

import re
import sys

# ---------------------------------------------------------------------------
# Encoding tables (match placard.asm)
# ---------------------------------------------------------------------------
ALU = {'ld': 0, 'and': 1, 'or': 2, 'xor': 3, 'add': 4, 'sub': 5}
REG_SRC = {'ac': 2, 'x': 3}
REG_DST = {'ac': 0, 'x': 3, 'y': 4}
COND = {'bgt': 1, 'blt': 2, 'bne': 3, 'beq': 4, 'bge': 5, 'ble': 6, 'bra': 7}
MEM_BRANCH = {   # indirect branch forms: (mnemonic, operand) -> m
    ('jmp', 'zp'): 0, ('bne', 'zp'): 3, ('beq', 'zp'): 4,
    ('bgt', '[x]'): 1, ('ble', '[x]'): 6,
    ('blt', '[y,x]'): 2, ('bra', '[y,x]'): 7,
}


def op(a, m, s):
    return (a << 5) | (m << 2) | s


class AsmError(Exception):
    pass


ZP_RE = re.compile(r'^\[(?!x\]$|y\s*,\s*x\]$)(.+)\]$')


def norm(t):
    t = t.strip()
    t = re.sub(r'\[\s*y\s*,\s*x\s*\]', '[y,x]', t)
    t = re.sub(r'\[\s*x\s*\]', '[x]', t)
    return t


def split_operands(rest):
    """split 'a, b' at the top-level comma (not inside brackets)"""
    depth, cur, out = 0, '', []
    for ch in rest:
        if ch == '[':
            depth += 1
        elif ch == ']':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [norm(o) for o in out]


def encode(mn, ops):
    """return (list of byte templates); an int is a fixed byte, a str is an
    expression that must evaluate to a byte (low 8 bits taken)"""
    E = lambda e: ('expr', e)
    mn = mn.lower()
    n = len(ops)
    is_reg = lambda t: t in REG_SRC
    is_zp = lambda t: bool(ZP_RE.match(t))
    zp = lambda t: ZP_RE.match(t).group(1)

    # aliases
    if mn == 'nop' and n == 0:
        return [op(0, 0, 2)]
    if mn == 'shl' and (n == 0 or ops == ['ac']):
        return [op(4, 0, 2)]
    if mn == 'clr' and n == 1 and ops[0] in REG_DST:
        return [op(3, REG_DST[ops[0]], 2)]
    if mn == 'inc' and n == 0:
        return [op(4, 0, 0), 1]
    if mn == 'dec' and n == 0:
        return [op(5, 0, 0), 1]
    if mn == 'not' and n == 0:
        return [op(3, 0, 0), 0xFF]

    if mn in ALU and n == 2:
        a = ALU[mn]
        s, d = ops
        if is_reg(s) and d in REG_DST:
            return [op(a, REG_DST[d], REG_SRC[s])]
        if is_reg(s) and d == '[x]':
            return [op(a, 6, REG_SRC[s])]
        if is_reg(s) and d == '[y,x]':
            return [op(a, 7, REG_SRC[s])]
        if is_reg(s) and is_zp(d):
            return [op(a, 5, REG_SRC[s]), E(zp(d))]
        if s == '[x]' and d == 'ac':
            return [op(a, 1, 1)]
        if s == '[y,x]' and d == 'ac':
            return [op(a, 2, 1)]
        if s == '[x]' and d == '[x]':
            return [op(a, 6, 1)]
        if s == '[y,x]' and d == '[y,x]':
            return [op(a, 7, 1)]
        if is_zp(s) and d in REG_DST:
            return [op(a, REG_DST[d], 1), E(zp(s))]
        if is_zp(s) and is_zp(d):
            raise AsmError('zero-page read-modify-write is not supported')
        if not s.startswith('['):           # immediate
            if d in REG_DST:
                return [op(a, REG_DST[d], 0), E(s)]
            if d == '[x]':
                return [op(a, 6, 0), E(s)]
            if d == '[y,x]':
                return [op(a, 7, 0), E(s)]
            if is_zp(d):
                return [op(a, 5, 0), ('same', s, zp(d))]
    if mn == 'shr' and n == 1:
        d = ops[0]
        if d in REG_DST:
            return [op(6, REG_DST[d], 2)]
        if d == '[x]':
            return [op(6, 6, 2)]
        if d == '[y,x]':
            return [op(6, 7, 2)]
        if is_zp(d):
            return [op(6, 5, 2), E(zp(d))]
    if (mn == 'jmp' or mn in COND) and n == 1:
        t = ops[0]
        c = 0 if mn == 'jmp' else COND[mn]
        if is_reg(t):
            if mn == 'bge':                 # MEM 101: pad byte (State PLD rev 11)
                return [op(7, c, REG_SRC[t]), 0]
            return [op(7, c, REG_SRC[t])]
        if t in ('[x]', '[y,x]'):
            key = (mn, t)
            if key in MEM_BRANCH:
                return [op(7, MEM_BRANCH[key], 1)]
            raise AsmError('%s has no %s form' % (mn, t))
        if is_zp(t):
            key = (mn, 'zp')
            if key in MEM_BRANCH:
                return [op(7, MEM_BRANCH[key], 1), E(zp(t))]
            raise AsmError('%s has no [0xNN] form' % mn)
        if mn == 'jmp':
            return [op(7, 0, 0), E(t)]
        return [op(7, c, 0), ('branch', t)]
    raise AsmError('no rule matches: %s %s' % (mn, ', '.join(ops)))


def parse_line(line):
    line = line.split(';', 1)[0].strip()
    labels = []
    while True:
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$', line)
        if not m:
            break
        labels.append(m.group(1))
        line = m.group(2).strip()
    return labels, line


def instr_size(text):
    """size in bytes of one instruction line (no label)"""
    text = text.strip()
    if not text:
        return 0
    parts = text.split(None, 1)
    ops = split_operands(parts[1]) if len(parts) > 1 else []
    return len(encode(parts[0], ops))


def evaluate(expr, syms):
    e = expr.strip()
    e = re.sub(r'\b0x([0-9A-Fa-f]+)\b', lambda m: str(int(m.group(1), 16)), e)
    e = re.sub(r'\b0b([01]+)\b', lambda m: str(int(m.group(1), 2)), e)
    if re.search(r'[^\w\s\+\-\*\(\)<>&|^~]', e):
        raise AsmError('bad expression: ' + expr)
    try:
        return eval(e, {'__builtins__': {}}, syms)
    except NameError as ex:
        raise AsmError('unknown symbol in "%s": %s' % (expr, ex))


INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"', re.I)
CONST_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$')


def expand_includes(src, base_dir, depth=0):
    """paste in #include files (except placard.asm, the rule definitions)"""
    import os
    if depth > 8:
        raise AsmError('#include nested too deep')
    out = []
    for raw in src.splitlines():
        m = INCLUDE_RE.match(raw)
        if m and os.path.basename(m.group(1)).lower() != 'placard.asm':
            path = os.path.join(base_dir, m.group(1))
            try:
                text = open(path).read()
            except OSError:
                raise AsmError('cannot open #include file %s' % path)
            out.extend(expand_includes(text, os.path.dirname(path), depth + 1))
        else:
            out.append(raw)
    return out


def d8_items(text, lineno):
    """bytes of a #d line: "strings" and 0x hex literals (2 digits per byte)"""
    out, i = [], 0
    for item in re.findall(r'"(?:[^"\\]|\\.)*"|[^,]+', text):
        item = item.strip()
        if not item:
            continue
        if item.startswith('"'):
            body = item[1:-1].encode().decode('unicode_escape')
            out.extend(body.encode('latin-1'))
        elif re.match(r'^0x[0-9A-Fa-f]+$', item) and len(item) % 2 == 0:
            v = int(item, 16)
            nb = (len(item) - 2) // 2
            out.extend((v >> (8 * k)) & 0xFF for k in reversed(range(nb)))
        else:
            raise AsmError('line %d: #d takes "strings" and 0x hex literals only' % lineno)
    return out


def assemble(src, base_dir='.'):
    """two-pass assembly; returns (mem dict addr->byte, symbols, listing)"""
    lines = expand_includes(src, base_dir)
    for pass_no in (1, 2):
        addr = 0
        mem = {}
        listing = []
        if pass_no == 1:
            syms = {}
        for lineno, raw in enumerate(lines, 1):
            labels, text = parse_line(raw)
            for lb in labels:
                if pass_no == 1:
                    if lb in syms:
                        raise AsmError('line %d: duplicate label %s' % (lineno, lb))
                    syms[lb] = addr
            if not text:
                continue
            m = CONST_RE.match(text)
            if m:
                if pass_no == 1:
                    if m.group(1) in syms:
                        raise AsmError('line %d: duplicate symbol %s' % (lineno, m.group(1)))
                    try:
                        syms[m.group(1)] = evaluate(m.group(2), syms)
                    except AsmError:        # forward reference: resolve in pass 2
                        syms[m.group(1)] = 0
                else:
                    syms[m.group(1)] = evaluate(m.group(2), syms)
                continue
            if text.startswith('#'):
                d = text.split(None, 1)
                kw = d[0].lower()
                if kw in ('#include', '#bankdef', '#bits', '#outp', '#size', '{', '}'):
                    continue
                if kw == '#addr':
                    # may go backwards, as in customasm; overlapping bytes are an error
                    addr = evaluate(d[1], syms) if pass_no == 2 else evaluate(d[1], dict(syms))
                    continue
                if kw == '#d8':
                    for v in d[1].split(','):
                        if pass_no == 2:
                            if addr in mem:
                                raise AsmError('line %d: overlapping data at %04X' % (lineno, addr))
                            mem[addr] = evaluate(v, syms) & 0xFF
                        addr += 1
                    continue
                if kw == '#d':
                    for v in d8_items(d[1], lineno):
                        if pass_no == 2:
                            if addr in mem:
                                raise AsmError('line %d: overlapping data at %04X' % (lineno, addr))
                            mem[addr] = v
                        addr += 1
                    continue
                raise AsmError('line %d: unsupported directive %s' % (lineno, kw))
            if text in ('{', '}') or text.startswith('#bits') or text.startswith('#addr 0') and False:
                continue
            parts = text.split(None, 1)
            try:
                ops = split_operands(parts[1]) if len(parts) > 1 else []
                tmpl = encode(parts[0], ops)
            except AsmError as ex:
                raise AsmError('line %d: %s  [%s]' % (lineno, ex, raw.strip()))
            if pass_no == 2:
                out = []
                for t in tmpl:
                    if isinstance(t, int):
                        out.append(t)
                    elif t[0] == 'expr':
                        out.append(evaluate(t[1], syms) & 0xFF)
                    elif t[0] == 'same':
                        v = evaluate(t[1], syms)
                        a = evaluate(t[2], syms)
                        if (v & 0xFF) != (a & 0xFF):
                            raise AsmError('line %d: op n, [n] needs value == address' % lineno)
                        out.append(a & 0xFF)
                    elif t[0] == 'branch':
                        tv = evaluate(t[1], syms)
                        if (tv >> 8) != ((addr + 2) >> 8):
                            raise AsmError('line %d: branch target %04X not in the same page as %04X'
                                           % (lineno, tv, addr + 2))
                        out.append(tv & 0xFF)
                for i, b in enumerate(out):
                    if addr + i in mem:
                        raise AsmError('line %d: overlapping code at %04X' % (lineno, addr + i))
                    mem[addr + i] = b
                listing.append((addr, out, raw.strip()))
            addr += len(tmpl)
            if addr > 0x10000:
                raise AsmError('line %d: past end of memory' % lineno)
    return mem, syms, listing


def to_hexstr(mem):
    top = max(mem) + 1 if mem else 0
    return ''.join('%02X' % mem.get(a, 0) for a in range(top))


# ---------------------------------------------------------------------------
# ALU models
# ---------------------------------------------------------------------------
def alu_ideal(s, a, b, sri_low_unused=None):
    if s == 0:
        return b
    if s == 1:
        return a & b
    if s == 2:
        return a | b
    if s == 3:
        return a ^ b
    if s == 4:
        return (a + b) & 0xFF
    if s == 5:
        return (a - b) & 0xFF
    if s == 6:
        return a >> 1
    return a


def alu4(a, b, s, cin, sri):
    """exact alu4.vhd equations; a, b nibbles; returns (f, cout)"""
    bit = lambda v, i: (v >> i) & 1
    s0, s1, s2 = bit(s, 0), bit(s, 1), bit(s, 2)
    pass_sel = (1 - s2) & (1 - s1) & (1 - s0)
    and_sel = (1 - s2) & (1 - s1) & s0
    or_sel = (1 - s2) & s1 & (1 - s0)
    xor_sel = (1 - s2) & s1 & s0
    shr_sel = s2 & s1 & (1 - s0)
    passa_sel = s2 & s1 & s0
    arith_sel = s2 & (1 - s1)
    sh = [bit(a, 1), bit(a, 2), bit(a, 3), sri]
    maj = lambda x, y, z: (x & y) | (x & z) | (y & z)
    d = [cin, 0, 0, 0]
    for i in range(3):
        d[i + 1] = maj(bit(a, i) ^ s0, bit(b, i), d[i])
    d4 = maj(bit(a, 3) ^ s0, bit(b, 3), d[3])   # carry (ADD) / borrow (SUB)
    f = 0
    for i in range(4):
        ai, bi = bit(a, i), bit(b, i)
        fi = ((pass_sel & bi) | (and_sel & ai & bi) | (or_sel & (ai | bi)) |
              (xor_sel & (ai ^ bi)) | (arith_sel & (ai ^ bi ^ d[i])) |
              (shr_sel & sh[i]) | (passa_sel & ai))
        f |= fi << i
    cout = (arith_sel & d4) | (shr_sel & bit(a, 0))
    return f, cout


def alu_hw(s, a, b):
    lo, c = alu4(a & 15, b & 15, s, 0, (a >> 4) & 1)
    hi, _ = alu4(a >> 4, b >> 4, s, c, 0)
    return (hi << 4) | lo


# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------
class CpuError(Exception):
    pass


class Cpu:
    def __init__(self, mem, hw_alu=False):
        self.mem = bytearray(65536)
        for a, v in mem.items():
            self.mem[a] = v
        self.pc = 0
        self.ac = self.x = self.y = self.d = 0
        self.alu = (lambda s, a, b: alu_hw(s, a, b)) if hw_alu else alu_ideal
        self.steps = 0
        self.clocks = 0

    def step(self):
        m_ = self.mem
        opc = m_[self.pc]
        here = self.pc
        self.pc = (self.pc + 1) & 0xFFFF
        a, m, s = opc >> 5, (opc >> 2) & 7, opc & 3
        clocks = 2
        if s == 1 and m == 5:
            raise CpuError('%04X: unsupported opcode %02X (MEM 101 with memory source)' % (here, opc))
        operand = (s == 0) or (s == 1 and m in (0, 3, 4)) or (s >= 2 and m == 5)
        if operand:
            self.d = m_[self.pc]
            self.pc = (self.pc + 1) & 0xFFFF
            clocks += 1

        def addr():
            if m in (0, 3, 4, 5):
                return self.d
            if m in (1, 6):
                return self.x
            return (self.y << 8) | self.x
        if s == 1:
            ad = addr()
            if ad & 0xF700 == 0x5000:             # /LINE_RD (x5000-x50FF, x5800-x58FF)
                self.d = self.line_read()
            else:
                self.d = m_[ad]
            clocks += 1
        if s >= 2 and m in (6, 7):
            clocks += 1                           # through LOAD_MEM (State PLD rev 10)
        src = [self.d, self.d, self.ac, self.x][s]
        res = self.alu(a, self.ac, src)
        if a == 7:
            acv = self.alu(7, self.ac, src)       # PASS A -> Z flags
            z = acv == 0
            neg = (self.ac >> 7) & 1
            take = [True, (not z) and not neg, (not z) and neg, not z, z,
                    not neg, z or neg, True][m]
            if take:
                self.pc = (self.pc & 0xFF00) | src
                if m == 0:
                    self.pc = (self.y << 8) | src
        else:
            if a in (4, 5) and m <= 4:
                clocks += 1                       # ALU wait clock (Branch PLD rev 07)
            if m in (0, 1, 2):
                self.ac = res
            elif m == 3:
                self.x = res
            elif m == 4:
                self.y = res
            else:
                m_[addr()] = src
        self.steps += 1
        self.clocks += clocks
        return here

    def line_read(self):
        """V9:V2 of the video line counter: 800 clocks per line, V = 499-1023"""
        return (499 + (self.clocks // 800) % 525) >> 2

    def run(self, max_steps=20_000_000, halt_detect=True, stop_pc=None):
        while self.steps < max_steps:
            here = self.step()
            if self.pc == stop_pc:
                return 'stop'
            if halt_detect and self.pc == here and m_is_branch(self.mem[here]):
                return 'halt'
        return 'timeout'


def m_is_branch(o):
    return (o >> 5) == 7


# ---------------------------------------------------------------------------
# Screen rendering (matches gen_video_ram.tcl layout)
# ---------------------------------------------------------------------------
VID_BASE = 48 * 512 + 32


def rgb8(b):
    r = (b & 7) * 255 // 7
    bl = ((b >> 3) & 3) * 255 // 3
    g = ((b >> 5) & 7) * 255 // 7
    return (r, g, bl)


def render(mem, path):
    try:
        from PIL import Image
    except ImportError:
        print('PIL not available, no PNG written')
        return
    img = Image.new('RGB', (640, 480))
    px = img.load()
    pal2 = [(0, 0, 0), (0, 80, 255), (255, 182, 0), (255, 255, 255)]
    for y in range(480):
        mode = mem[VID_BASE + y] & 3
        bpp = 1 << mode
        for col in range(1, 80):
            byte = mem[VID_BASE + col * 512 + y]
            per = 8 // bpp
            w = 8 // per
            for i in range(per):
                v = (byte >> (i * bpp)) & ((1 << bpp) - 1)
                if bpp == 1:
                    c = (255, 255, 255) if v else (0, 0, 0)
                elif bpp == 2:
                    c = pal2[v]
                elif bpp == 4:
                    c = ((v & 1) * 255, ((v >> 1) & 1) * 255, ((v >> 2) & 1) * 255) if v < 8 else \
                        (128 + (v & 1) * 127, 128 + ((v >> 1) & 1) * 127, 128 + ((v >> 2) & 1) * 127)
                else:
                    c = rgb8(v)
                for k in range(w):
                    xx = col * 8 + i * w + k
                    if xx < 640:
                        px[xx, y] = c
    img.save(path)


def main(argv):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('asm')
    ap.add_argument('-o', '--hex')
    ap.add_argument('--run', action='store_true')
    ap.add_argument('--hw-alu', action='store_true')
    ap.add_argument('--png')
    ap.add_argument('--max-steps', type=int, default=20_000_000)
    ap.add_argument('--stop-at', metavar='LABEL', help='stop when the PC reaches LABEL')
    args = ap.parse_args(argv)
    src = open(args.asm).read()
    import os
    mem, syms, _ = assemble(src, os.path.dirname(os.path.abspath(args.asm)))
    hexpath = args.hex or re.sub(r'\.asm$', '', args.asm) + '.hex'
    open(hexpath, 'w').write(to_hexstr(mem) + '\n')
    print('assembled %d bytes, top %04X -> %s' % (len(mem), max(mem), hexpath))
    if args.run:
        cpu = Cpu(mem, hw_alu=args.hw_alu)
        r = cpu.run(args.max_steps, stop_pc=syms[args.stop_at] if args.stop_at else None)
        print('%s after %d instructions, %d clocks, PC=%04X' % (r, cpu.steps, cpu.clocks, cpu.pc))
        if args.png:
            render(cpu.mem, args.png)
        return cpu, syms
    return None, syms


if __name__ == '__main__':
    main(sys.argv[1:])
