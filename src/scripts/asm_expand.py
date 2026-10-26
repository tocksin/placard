#!/usr/bin/env python3
"""
asm_expand.py - expand the call macros of a .masm file and pack its code
into 256-byte pages, writing a plain .asm file for customasm or placard_sim

    python3 asm_expand.py dos.masm            writes dos.asm
    python3 asm_expand.py a.masm b.masm ...

The Placard has no call instruction and its branches stay in their page,
so hand-written library code spells out every CALL (6 instructions and a
return label) and places its code page by page with #addr (LIBRARY.md,
"Calling convention").  A .masm file is the same assembly with:

  macros (on a line of their own, an optional ; comment after them)
    CALL name       ld LINK_LO, x / ld back, [x] / ld LINK_HI, x /
                    ld back >> 8, [x] / ld name >> 8, y / jmp name, and
                    the return label back (<prefix>_r<n>)
    PUSH_LINK       the 12-instruction prologue of a routine that calls
    LEAVE           ld lib_leave >> 8, y / jmp lib_leave
    RET             ld [LINK_HI], y / jmp [LINK_LO]  (a leaf's return)
    GOTO name       ld name >> 8, y / jmp name  (a jump to another page)
    PUSH / POP      AC onto / off the software stack

  directives
    .prefix p       return labels are p_r1, p_r2, ...
    .region a, b    the chunks that follow go in a up to (not including)
                    b: numbers or expressions in the constants defined
                    above (FSW_CODE, FSW_CODE + 0x1000)
    .chunk          a piece of code that must stay in one page: its
                    branches are local.  It must end with a jump (jmp,
                    bra, GOTO, LEAVE, RET) or be data.  Chunks are placed
                    in the region first fit, in order, never across a page
    .fixed a        a chunk at address a (not moved); the rest of its page
                    (from its end) is used by the chunks that follow

Lines before the first .chunk or .fixed (constants, #include, comments)
are copied as they are.  The .asm made is the file to read and assemble;
the .masm is its source (change that and run this again).

Date: 10/26/2026
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402

PUSH_LINK = ['    ld   ac, [SAVE_AC]          ; PUSH_LINK',
             '    ld   [SP], x',
             '    ld   [LINK_HI], ac',
             '    ld   ac, [x]',
             '    ld   [SP], ac',
             '    dec',
             '    ld   ac, x',
             '    dec',
             '    ld   ac, [SP]',
             '    ld   [LINK_LO], ac',
             '    ld   ac, [x]',
             '    ld   [SAVE_AC], ac']
PUSH = ['    ld   [SP], x', '    ld   ac, [x]', '    ld   [SP], ac', '    dec',
        '    ld   ac, [SP]', '    ld   [x], ac']
POP = ['    ld   [SP], ac', '    inc', '    ld   ac, [SP]', '    ld   ac, x', '    ld   [x], ac']
ENDERS = ('jmp', 'bra')


class ExpandError(Exception):
    pass


def with_comment(line, comment):
    if not comment:
        return line
    return '%-31s ; %s' % (line, comment) if len(line) < 31 else line + '  ; ' + comment


def size_of(text):
    """bytes of one instruction or data line (no label)"""
    t = text.split(';', 1)[0].strip()
    if not t:
        return 0
    low = t.lower()
    if low.startswith('#d8'):
        return len([v for v in t[3:].split(',') if v.strip()])
    if low.startswith('#d'):
        return len(ps.d8_items(t[2:].strip(), 0))
    if t.startswith('#') or ps.CONST_RE.match(t):
        return 0
    return ps.instr_size(t)


class Chunk:
    def __init__(self, fixed=None, region=None, lineno=0):
        self.lines = []          # expanded lines
        self.fixed = fixed
        self.region = region
        self.lineno = lineno
        self.size = 0
        self.last = None         # last instruction mnemonic
        self.data = False
        self.addr = None


def expand(src, name='?'):
    head, chunks = [], []
    cur = None
    prefix = os.path.splitext(os.path.basename(name))[0]
    nret = 0
    region = None
    consts = {}

    def value(expr):
        try:
            return ps.evaluate(expr, consts)
        except ps.AsmError as ex:
            raise ExpandError('%s:%d: %s' % (name, lineno, ex))
    for lineno, raw in enumerate(src.splitlines(), 1):
        code, _, comment = raw.partition(';')
        comment = comment.strip()
        body = code.strip()
        word = body.split(None, 1)[0] if body else ''
        rest = body.split(None, 1)[1].strip() if len(body.split(None, 1)) > 1 else ''
        if word == '.prefix':
            prefix = rest
            continue
        if word == '.region':
            a, b = rest.split(',')
            region = [value(a), value(b)]
            continue
        if word in ('.chunk', '.fixed'):
            if word == '.chunk' and region is None:
                raise ExpandError('%s:%d: .chunk before .region' % (name, lineno))
            cur = Chunk(fixed=value(rest) if word == '.fixed' else None,
                        region=None if word == '.fixed' else region, lineno=lineno)
            if comment:
                cur.lines.append('; ' + comment)
            chunks.append(cur)
            continue
        if cur is None:
            head.append(raw)
            m = ps.CONST_RE.match(body)
            if m:
                try:
                    consts[m.group(1)] = ps.evaluate(m.group(2), consts)
                except ps.AsmError:
                    pass
            continue
        out = []
        labels, text = ps.parse_line(code)
        mword = text.split(None, 1)[0] if text else ''
        marg = text.split(None, 1)[1].strip() if len(text.split(None, 1)) > 1 else ''
        lab = ''.join('%s:\n' % lb for lb in labels)
        if mword == 'CALL':
            nret += 1
            back = '%s_r%d' % (prefix, nret)
            out = [with_comment('    ld   LINK_LO, x', comment or 'CALL ' + marg),
                   '    ld   %s, [x]' % back, '    ld   LINK_HI, x',
                   '    ld   %s >> 8, [x]' % back, '    ld   %s >> 8, y' % marg,
                   '    jmp  %s' % marg, back + ':']
            cur.last = None
        elif mword == 'PUSH_LINK':
            out = list(PUSH_LINK)
            if comment:
                out[0] = out[0] + ', ' + comment
            cur.last = None
        elif mword == 'LEAVE':
            out = [with_comment('    ld   lib_leave >> 8, y', comment), '    jmp  lib_leave']
            cur.last = 'jmp'
        elif mword == 'RET':
            out = [with_comment('    ld   [LINK_HI], y', comment), '    jmp  [LINK_LO]']
            cur.last = 'jmp'
        elif mword == 'GOTO':
            out = [with_comment('    ld   %s >> 8, y' % marg, comment), '    jmp  %s' % marg]
            cur.last = 'jmp'
        elif mword == 'PUSH':
            out = list(PUSH)
            out[0] = with_comment(out[0], comment or 'PUSH AC')
            cur.last = None
        elif mword == 'POP':
            out = list(POP)
            out[0] = with_comment(out[0], comment or 'POP AC')
            cur.last = None
        else:
            out = [raw.rstrip()]
            if text and not text.startswith('#') and not ps.CONST_RE.match(text):
                cur.last = mword.lower()
            elif text.lower().startswith('#d'):
                cur.data = True
                cur.last = 'data'
            cur.lines.extend(out)
            cur.size += size_of(text)
            continue
        if labels:
            out = [lb + ':' for lb in labels] + out
        for ln in out:
            _, t = ps.parse_line(ln)
            cur.size += size_of(t)
        cur.lines.extend(out)
    return head, chunks


def place(chunks, name):
    used = {}                               # page -> bytes used
    for c in chunks:                        # a fixed chunk takes its page up to its end
        if c.fixed is not None:
            c.addr = c.fixed
            page = c.addr >> 8
            used[page] = max(used.get(page, 0), (c.addr & 0xFF) + c.size)
    for c in chunks:
        if c.fixed is not None:
            continue
        if c.size > 256:
            raise ExpandError('%s:%d: chunk of %d bytes, more than a page' % (name, c.lineno, c.size))
        if c.last not in ENDERS and c.last != 'data' and c.size:
            raise ExpandError('%s:%d: chunk does not end with a jump (last: %s)'
                              % (name, c.lineno, c.last))
        lo, hi = c.region
        page = lo >> 8
        start_off = lo & 0xFF
        while True:
            if page << 8 >= hi:
                raise ExpandError('%s:%d: no room for a %d-byte chunk in x%04X-x%04X'
                                  % (name, c.lineno, c.size, lo, hi - 1))
            off = used.get(page, start_off if page == lo >> 8 else 0)
            end = min(256, hi - (page << 8))
            if off + c.size <= end:
                c.addr = (page << 8) + off
                used[page] = off + c.size
                break
            page += 1
    return used


def render(head, chunks, name):
    out = ['; ' + '=' * 60,
           '; made by asm_expand.py from %s: change that file, then run' % os.path.basename(name),
           ';     python3 asm_expand.py %s' % os.path.basename(name),
           '; ' + '=' * 60, '']
    out += head
    nxt = None
    for c in sorted(chunks, key=lambda c: c.addr):
        if c.addr != nxt:
            out.append('')
            out.append('#addr 0x%04X' % c.addr)
        out.extend(c.lines)
        nxt = c.addr + c.size
    return '\n'.join(out) + '\n'


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    for path in argv:
        src = open(path).read()
        head, chunks = expand(src, path)
        place(chunks, path)
        text = render(head, chunks, path)
        dst = re.sub(r'\.masm$', '', path) + '.asm'
        open(dst, 'w', newline='\n').write(text)
        regions = {}
        for c in chunks:
            if c.region:
                regions.setdefault(tuple(c.region), []).append(c)
        for (lo, hi), cs in regions.items():
            top = max(c.addr + c.size for c in cs)
            print('%s: x%04X-x%04X, %d bytes in %d chunks, top x%04X'
                  % (dst, lo, hi - 1, sum(c.size for c in cs), len(cs), top))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
