#!/usr/bin/env python3
"""
gen_text_demo_sd.py - the text demo (text_demo.asm) as a program on the SD
card: writes text_demo_sd.asm and ../../sdcard/TEXT.PLC

    python3 gen_text_demo_sd.py
    python3 text_demo_sim.py --sd           boots it from a card and checks it

text_demo.asm is a ROM program: its code and tables run in place from ROM
x6000-xB0FF (60 pages are used).  A library program loads into RAM
x0100-x3FFF, so this moves every page the demo uses down into that RAM
and changes nothing else:
  - the used pages are grouped into runs (a page whose last byte is used
    and whose next page's first byte is used runs on into it: unrolled
    code or a table that crosses a page), and the runs are packed into RAM
    pages x01-x3F, longest first, around x1F (LIB_RAM);
  - every #addr, the TBL / TBL2 constants and the page bytes in
    SC_LPAGE / SC_RPAGE get the new page; everything else uses labels;
  - the RAM test (PAGES, NPAGES, NBAR, the progress bar's ] and the
    "RAM AREA" line) covers only
    the free RAM: the x01-x3F pages the program doesn't use, x4000-x4CFF,
    x5400-x59FF and x5C00-x5CFF.  It leaves out the program, LIB_RAM, the
    FAT driver's variables and buffer at x4D00-x4FFF (the DOS's files stay
    open), the I/O window, the mode bytes, the menu block and the audio
    buffer.
The demo already calls menu_poll, so Esc goes back to the DOS (or the demo
menu) and the menu's time limit works.

Date: 11/02/2026
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import gen_plc            # noqa: E402

SDCARD = os.path.join(HERE, '..', '..', 'sdcard')
EXTRA_FREE = list(range(0x40, 0x4D)) + list(range(0x54, 0x5A)) + [0x5C]


def source():
    """text_demo.asm with text_demo_tables.asm in line"""
    src = open(os.path.join(HERE, 'text_demo.asm')).read()
    tables = open(os.path.join(HERE, 'text_demo_tables.asm')).read()
    return src.replace('#include "text_demo_tables.asm"', tables)


def own_pages(src):
    """{page: set of low bytes} the program itself uses (not the library)"""
    mem, syms, _ = ps.assemble(src, HERE)
    lib, _, _ = ps.assemble('#include "placard.asm"\n#include "placard_lib.asm"\n', HERE)
    pages = {}
    for a in mem:
        if a in lib:
            continue
        pages.setdefault(a >> 8, set()).add(a & 0xFF)
    return pages


def page_map(pages):
    """{ROM page: RAM page}, runs kept together"""
    runs, run = [], []
    for p in sorted(pages):
        if run and p == run[-1] + 1 and 0xFF in pages[run[-1]] and 0x00 in pages[p]:
            run.append(p)
        else:
            if run:
                runs.append(run)
            run = [p]
    runs.append(run)
    free = [p for p in range(0x01, 0x40) if p != 0x1F]
    out = {}
    for run in sorted(runs, key=lambda r: (-len(r), r[0])):
        for i, start in enumerate(free):
            want = list(range(start, start + len(run)))
            if all(q in free for q in want):
                for q in want:
                    free.remove(q)
                out.update(zip(run, want))
                break
        else:
            raise SystemExit('no room for pages x%02X-x%02X' % (run[0], run[-1]))
    return out


def ranges(pages):
    """'3E00-3EFF 4000-4CFF' for a sorted page list"""
    out, start = [], pages[0]
    for a, b in zip(pages, pages[1:] + [None]):
        if b != a + 1:
            out.append('%02X00-%02XFF' % (start, a))
            start = b
    return out


def gen():
    """(source of text_demo_sd.asm, the RAM test pages)"""
    src = source()
    pages = own_pages(src)
    pm = page_map(pages)
    used = set(pm.values())
    test = [p for p in range(0x01, 0x40) if p != 0x1F and p not in used] + EXTRA_FREE

    def addr(m):
        v = int(m.group(2), 16)
        return '%s0x%04X' % (m.group(1), (pm[v >> 8] << 8) | (v & 0xFF))
    src = re.sub(r'^(#addr\s+)0x([0-9A-Fa-f]{4})\b', addr, src, flags=re.M)
    src = re.sub(r'^(TBL2?\s*=\s*)0x([0-9A-Fa-f]{4})\b', addr, src, flags=re.M)
    for lab in ('SC_LPAGE', 'SC_RPAGE'):
        m = re.search(r'^%s:.*\n(\s*#d8 )(.*)$' % lab, src, flags=re.M)
        vals = ', '.join('0x%02X' % pm[int(v, 16)] for v in m.group(2).split(','))
        src = src[:m.start(2)] + vals + src[m.end(2):]
    # the RAM test: the free pages only
    src, n = re.subn(r'^NPAGES\s*=\s*\d+', 'NPAGES     = %d' % len(test), src, flags=re.M)
    assert n == 1
    src, n = re.subn(r'^NBAR\s*=\s*\d+', 'NBAR       = %d' % ((len(test) + 1) // 2), src, flags=re.M)
    assert n == 1
    src, n = re.subn(r'#d8 54, 8, 0, s_close', '#d8 BAR_COL + NBAR, 8, 0, s_close', src)
    assert n == 1                                     # the bar's ] after its last cell
    m = re.search(r'^PAGES:.*\n((?:\s*#d8 .*\n)+)', src, flags=re.M)
    rows = ['    #d8 ' + ', '.join('0x%02X' % p for p in test[i:i + 8]) for i in range(0, len(test), 8)]
    src = src[:m.start(1)] + '\n'.join(rows) + '\n' + src[m.end(1):]
    area = 'RAM AREA    %s  (%d FREE PAGES, %.2f KB)' % (' '.join(ranges(test)), len(test), len(test) / 4)
    assert len(area) <= 80, area
    src, n = re.subn(r'#d "RAM AREA .*?", 0x00', '#d "%s", 0x00' % area, src)
    assert n == 1
    head = ('; text_demo_sd.asm - generated by gen_text_demo_sd.py, do not edit\n'
            ';\n'
            '; THE SD CARD BUILD (TEXT.PLC): text_demo.asm with the pages it uses\n'
            '; moved into RAM %s (page map: %s),\n'
            '; and the RAM test on the free RAM only: %s.\n'
            ';\n' % (' '.join(ranges(sorted(used))),
                     ' '.join('%02X>%02X' % kv for kv in sorted(pm.items())), ' '.join(ranges(test))))
    return head + src, test


def build():
    """(source, mem, syms, test pages)"""
    src, test = gen()
    mem, syms, _ = ps.assemble(src, HERE)
    return src, mem, syms, test


def main(argv):
    src, mem, syms, test = build()
    out = os.path.join(HERE, 'text_demo_sd.asm')
    with open(out, 'w', newline='\n') as f:
        f.write(src)
    lib, _, _ = ps.assemble('#include "placard.asm"\n#include "placard_lib.asm"\n', HERE)
    data, kind, load, entry = gen_plc.make(mem, syms, lib)
    path = os.path.join(SDCARD, 'TEXT.PLC')
    with open(path, 'wb') as f:
        f.write(data)
    print('wrote %s and %s: %d bytes, load x%04X, entry x%04X; RAM test %d pages: %s'
          % (out, os.path.normpath(path), len(data), load, entry, len(test), ' '.join(ranges(test))))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
