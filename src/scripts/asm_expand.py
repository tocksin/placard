#!/usr/bin/env python3
r"""
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
    LEAVE           ld lib_leave >> 8, y / jmp lib_leave (or the routine
                    .leave names: a copy in RAM for code that runs with
                    the ROM mapped out, tracker.masm)
    RET             ld [LINK_HI], y / jmp [LINK_LO]  (a leaf's return)
    GOTO name       ld name >> 8, y / jmp name  (a jump to another page)
    PUSH / POP      AC onto / off the software stack

  directives
    .prefix p       return labels are p_r1, p_r2, ...
    .leave name     LEAVE jumps to name instead of lib_leave
    .region a, b    the chunks that follow go in a up to (not including)
                    b: numbers or expressions in the constants defined
                    above (FSW_CODE, FSW_CODE + 0x1000).  A chunk that
                    does not fit goes to the next region of the file
                    that has room (tracker.masm: an overlay)
    .region a, b, s every s-th page only, from a: 2 for the even video
                    pages that 2x line repeat frees (VIDEO.md)
    .region a, b, s, overlay
                    the same, for RAM under a ROM address: its chunks get
                    #overlay instead of #addr (placard_sim.py), and
                    gen_plc.py --overlay puts them in a second file
    .chunk          a piece of code that must stay in one page: its
                    branches are local.  It must end with a jump (jmp,
                    bra, GOTO, LEAVE, RET) or be data.  Chunks are placed
                    in the region first fit, in order, never across a page
    .fixed a        a chunk at address a (not moved); the rest of its page
                    (from its end) is used by the chunks that follow
    .page           a chunk at the start of a page (a jump table that
                    jmp ac reaches: BASIC's primitives)
    .flow           data that may cross pages (BASIC's bytecode words,
                    vmc.py): placed after every .chunk, in the space left
                    in any region of the file, largest first
    .include "f"    the lines of file f (relative to this file) here; a .vm
                    file is compiled by vmc.py first
    .macro NAME     the lines up to .endm are pasted in for each line NAME
                    that follows (no arguments); \@ in them becomes a
                    number of its own for each paste (for local labels)

Lines before the first .chunk or .fixed (constants, #include, comments)
are copied as they are.  The .asm made is the file to read and assemble;
the .masm is its source (change that and run this again).

Date: 11/02/2026
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
        self.flow = False
        self.page = False        # .page: at the start of a page


INCLUDE_RE = re.compile(r'^\s*\.include\s+"([^"]+)"')


def includes(src, base, depth=0):
    """the source with its .include lines replaced by the files"""
    if depth > 8:
        raise ExpandError('.include nested too deep')
    out = []
    for raw in src.splitlines():
        m = INCLUDE_RE.match(raw)
        if not m:
            out.append(raw)
            continue
        path = os.path.join(base, m.group(1))
        text = open(path).read()
        if path.endswith('.vm'):
            import vmc
            try:
                text, _ = vmc.compile_vm(text, os.path.basename(path))
            except vmc.VmError as ex:
                raise ExpandError(str(ex))
        out.append(includes(text, os.path.dirname(path), depth + 1))
    return '\n'.join(out)


def macros(src):
    """the source with its .macro blocks taken out and their uses pasted in"""
    defs, out, cur, n = {}, [], None, 0
    for raw in src.splitlines():
        words = raw.split(';', 1)[0].split()
        if words[:1] == ['.macro']:
            cur = defs[words[1]] = []
            continue
        if words[:1] == ['.endm']:
            cur = None
            continue
        if cur is not None:
            cur.append(raw)
        elif len(words) == 1 and words[0] in defs:
            n += 1
            out.extend(ln.replace('\\@', str(n)) for ln in defs[words[0]])
        else:
            out.append(raw)
    return '\n'.join(out)


def expand(src, name='?'):
    src = macros(includes(src, os.path.dirname(os.path.abspath(name))))
    head, chunks = [], []
    cur = None
    prefix = os.path.splitext(os.path.basename(name))[0]
    leave = 'lib_leave'
    nret = 0
    region = None
    regions = []
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
        if word == '.leave':
            leave = rest
            continue
        if word == '.region':
            parts = rest.split(',')
            region = [value(parts[0]), value(parts[1]), value(parts[2]) if len(parts) > 2 else 1,
                      len(parts) > 3 and parts[3].strip() == 'overlay']
            if region not in regions:
                regions.append(region)
            continue
        if word in ('.chunk', '.fixed', '.flow', '.page'):
            if word != '.fixed' and region is None:
                raise ExpandError('%s:%d: %s before .region' % (name, lineno, word))
            cur = Chunk(fixed=value(rest) if word == '.fixed' else None,
                        region=None if word == '.fixed' else region, lineno=lineno)
            cur.flow = word == '.flow'
            cur.page = word == '.page'
            if region is not None and region not in regions:
                regions.append(region)
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
            out = [with_comment('    ld   %s >> 8, y' % leave, comment), '    jmp  %s' % leave]
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
    for c in chunks:
        c.regions = regions
    return head, chunks


def place(chunks, name):
    used = {}                               # page -> bytes used
    for c in chunks:                        # a fixed chunk takes its page up to its end
        if c.fixed is not None:
            c.addr = c.fixed
            page = c.addr >> 8
            used[page] = max(used.get(page, 0), (c.addr & 0xFF) + c.size)
    for c in sorted(chunks, key=lambda c: not c.page):   # .page chunks first
        if c.fixed is not None or c.flow:
            continue
        if c.size > 256:
            raise ExpandError('%s:%d: chunk of %d bytes, more than a page' % (name, c.lineno, c.size))
        if c.last not in ENDERS and c.last != 'data' and c.size:
            raise ExpandError('%s:%d: chunk does not end with a jump (last: %s)'
                              % (name, c.lineno, c.last))
        own = c.regions.index(c.region)
        for region in c.regions[own:]:
            lo, hi, step, _ = region
            page = lo >> 8
            start_off = lo & 0xFF
            while page << 8 < hi:
                off = used.get(page, start_off if page == lo >> 8 else 0)
                end = min(256, hi - (page << 8))
                if c.page and off:
                    page += step
                    continue
                # a branch takes its page from the address after it, so a chunk
                # that ends with one must not end at the end of the page
                slack = 1 if c.last == 'bra' and end == 256 else 0
                if off + c.size + slack <= end:
                    c.addr = (page << 8) + off
                    used[page] = off + c.size
                    c.region = region
                    break
                page += step
            if c.addr is not None:
                break
        else:
            lo, hi, step, _ = c.regions[own]
            raise ExpandError('%s:%d: no room for a %d-byte chunk in x%04X-x%04X or the regions after it'
                              % (name, c.lineno, c.size, lo, hi - 1))
    flows = sorted((c for c in chunks if c.flow), key=lambda c: -c.size)
    if flows:
        free = []                           # [start, end) gaps, in address order
        for lo, hi, step, _ in flows[0].regions:
            a = lo
            while a < hi:
                page = a >> 8
                off = used.get(page, a & 0xFF if page == lo >> 8 else 0)
                start = max(a, (page << 8) + off)
                end = min(hi, (page + 1) << 8)
                if start < end:
                    if free and free[-1][1] == start:
                        free[-1][1] = end
                    else:
                        free.append([start, end])
                a = (page + step) << 8
        for c in flows:                     # best fit
            best = None
            for f in free:
                room = f[1] - f[0]
                if room >= c.size and (best is None or room < best[1] - best[0]):
                    best = f
            if best is None:
                raise ExpandError('%s:%d: no room for a %d-byte .flow (%d bytes free in %d gaps)'
                                  % (name, c.lineno, c.size, sum(f[1] - f[0] for f in free),
                                     len(free)))
            c.addr = best[0]
            best[0] += c.size
            c.region = [r for r in c.regions if r[0] <= c.addr < r[1]][0]
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
            out.append('%s 0x%04X' % ('#overlay' if c.region and c.region[3] else '#addr', c.addr))
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
        for (lo, hi, step, _), cs in regions.items():
            top = max(c.addr + c.size for c in cs)
            print('%s: x%04X-x%04X%s, %d bytes in %d chunks, top x%04X'
                  % (dst, lo, hi - 1, ' every %d pages' % step if step > 1 else '',
                     sum(c.size for c in cs), len(cs), top))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
