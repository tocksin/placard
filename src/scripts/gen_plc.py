#!/usr/bin/env python3
"""
gen_plc.py - make a program file (.PLC) for the SD card from a program

    python3 gen_plc.py cpu_test.asm -o ../../sdcard/CPUTEST.PLC
    python3 gen_plc.py text_demo.asm --entry td_main -o ../../sdcard/TEXT.PLC

The DOS (docs/DOS.md) loads a .PLC file into the RAM and runs it.  The
file starts with a 16-byte header, then the program's bytes from its load
address to its last byte (gaps as 00):

    0-2   "PLC"
    3     type: 0 = a program that uses the library (it runs with map 07:
          RAM x0000-x5FFF, the library in ROM), 1 = a RAM image (the older
          demos, written to run from RAM x0000 with map FF: every section RAM)
    4-5   load address, low byte first
    6-7   length of the program bytes, low byte first
    8-9   entry address (type 0; a RAM image starts at x0000)
    10-15 0

The type is worked out from the program: bytes in x0000-x00FF make it a RAM
image; else it is a library program whose load address is its lowest byte
(x0100 as a rule) and whose entry is its "main" label (or --entry, or the
load address).  A library program must keep to RAM x0100-x1EFF and
x2000-x3FFF (x1F00-x1FFF is LIB_RAM; the DOS puts LIB_RAM back after
loading, so a program spanning it is fine); a RAM image to x0000-x49FF.
The program's own copy of the library (it includes placard_lib.asm) is not
part of the file.

Date: 10/26/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402

RAM_TOP = 0x4A00            # RAM images end below this
PROG_LOW, PROG_HIGH = 0x0100, 0x4000   # library programs live here


def own_bytes(mem, lib):
    return {a: v for a, v in mem.items()
            if not (ps.lib_area(a) and a in lib and lib[a] == v) and not (a >= 0x8000)}


def header(kind, load, length, entry):
    return (b'PLC' + bytes([kind, load & 0xFF, load >> 8, length & 0xFF, length >> 8,
                            entry & 0xFF, entry >> 8]) + bytes(6))


def make(mem, syms, lib, entry_label=None, kind=None):
    """(bytes of the .PLC file, kind, load, entry) for an assembled program"""
    own = own_bytes(mem, lib)
    if not own:
        raise SystemExit('the program has no bytes of its own')
    if kind is None:
        kind = 1 if any(a < 0x100 for a in own) else 0
    if kind == 1:
        load, entry = 0, 0
        top = max(own)
        if top >= RAM_TOP:
            raise SystemExit('RAM image byte at x%04X, past x%04X' % (top, RAM_TOP - 1))
    else:
        load = min(own)
        top = max(own)
        if load < PROG_LOW or top >= PROG_HIGH:
            raise SystemExit('program bytes x%04X-x%04X are outside RAM x%04X-x%04X'
                             % (load, top, PROG_LOW, PROG_HIGH - 1))
        if entry_label:
            entry = syms[entry_label]
        elif 'main' in syms:
            entry = syms['main']
        else:
            entry = load
    body = bytes(own.get(a, 0) for a in range(load, top + 1))
    return header(kind, load, len(body), entry) + body, kind, load, entry


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('asm')
    ap.add_argument('-o', '--out', help='the .PLC file (default: NAME.PLC next to the .asm)')
    ap.add_argument('--entry', help='the entry label (default: main, or the load address)')
    ap.add_argument('--type', type=int, choices=(0, 1), help='force the type')
    a = ap.parse_args(argv)
    src = open(a.asm).read()
    base = os.path.dirname(os.path.abspath(a.asm))
    mem, syms, _ = ps.assemble(src, base)
    lib, _, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    data, kind, load, entry = make(mem, syms, lib, a.entry, a.type)
    out = a.out or os.path.splitext(a.asm)[0][:8].upper().replace('_', '') + '.PLC'
    open(out, 'wb').write(data)
    print('%s: %d bytes, %s, load x%04X, entry x%04X'
          % (out, len(data), 'RAM image' if kind else 'library program', load, entry))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
