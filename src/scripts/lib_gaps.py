#!/usr/bin/env python3
"""
lib_gaps.py - the free ends of the library's pages in ROM section 6, as
.region lines for placard_fsw.masm

    python3 lib_gaps.py            prints the lines
    python3 lib_gaps.py --write    puts them in placard_fsw.masm (between its
                                   "gaps" marker lines)

Section 6 (xC000-xDFFF) holds everything that reads and writes files: the
SD card driver (SD_CODE), the FAT reader (FS_CODE) and the FAT writer
(placard_fsw.masm).  The driver and the reader are written a page at a
time and leave the end of most pages free; the writer needs more than the
pages after the reader, so asm_expand.py also places its chunks in those
free ends.  Run this again with --write (then asm_expand.py placard_fsw.masm
and rom32.masm) after a change to placard_io.asm's SD pages or
placard_fs.asm; the assembler stops on an overlap if it is forgotten.

Date: 11/11/2026
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402

MIN = 16            # shorter ends are not worth a region
BEGIN, END = '; gaps: begin (lib_gaps.py --write)', '; gaps: end'


def gaps():
    mem, syms, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    out = []
    for page in range(syms['SD_CODE'] >> 8, (syms['FS_CODE'] >> 8) + 14):
        used = [a & 0xFF for a in mem if a >> 8 == page]
        lo = max(used) + 1 if used else 0
        if 256 - lo >= MIN:
            out.append(((page << 8) + lo, (page + 1) << 8))
    return out


def main(argv):
    lines = ['.region 0x%04X, 0x%04X' % g for g in gaps()]
    if '--write' not in argv:
        print('\n'.join(lines))
        return 0
    path = os.path.join(HERE, 'placard_fsw.masm')
    s = open(path).read()
    m = re.search(re.escape(BEGIN) + r'\n.*?' + re.escape(END), s, re.S)
    if not m:
        raise SystemExit('no gaps marker lines in placard_fsw.masm')
    s = s[:m.start()] + BEGIN + '\n' + '\n'.join(lines) + '\n' + END + s[m.end():]
    open(path, 'w', newline='\n').write(s)
    print('placard_fsw.masm: %d regions, %d bytes' % (len(lines), sum(b - a for a, b in gaps())))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
