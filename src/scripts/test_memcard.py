#!/usr/bin/env python3
"""
test_memcard.py - test the 512K memory expansion card model
(io_devices.MemoryCard, docs/architecture/MEMCARD.md) in the simulator

    python3 test_memcard.py

A small program finds the card in slot 2 (x5300), writes a byte to each of
five pages and reads them back into the zero page, the way MEMCARD.md
"Using the card" shows.  A second run with the slot empty checks that the
same detect code reports no card.

Date: 11/16/2026
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import io_devices as iod    # noqa: E402

CARD = 0x53      # slot 2: x5300-x537F
def set_page(n):
    return '''    ld   0x7E, x
    ld   0x%02X, [y,x]
    ld   0x7F, x
    ld   0x%02X, [y,x]
''' % (n & 0xFF, n >> 8)


def put(off, v):
    return '''    ld   0x%02X, x
    ld   0x%02X, [y,x]
''' % (off, v)


def get(off, zp):
    return '''    ld   0x%02X, x
    ld   [y,x], ac
    ld   ac, [0x%02X]
''' % (off, zp)


# detect: page 0 gets A5 at offset 0, page 1 gets 5A, and both must read back;
# then pages 2, 0x302 and 0xFFF, at the last free offset
PAGES = [(0x002, 0x22), (0x302, 0x33), (0xFFF, 0xF0)]
PROG = ('''#include "placard.asm"
#addr 0x0100
start:
    ld   0x%02X, y
''' % CARD + set_page(0) + put(0, 0xA5) + set_page(1) + put(0, 0x5A)
        + set_page(0) + get(0, 0x40) + set_page(1) + get(0, 0x41)
        + ''.join(set_page(p) + put(0x7D, v) for p, v in PAGES)
        + ''.join(set_page(p) + get(0x7D, 0x42 + i) for i, (p, v) in enumerate(PAGES))
        + '''done:
    bra  done
''')


def run(card):
    mem, syms, _ = ps.assemble(PROG, HERE)
    slots = iod.Slots()
    slots.cards[1] = card
    cpu = ps.Cpu(dict(mem), slots=slots)
    cpu.pc = 0x0100
    cpu.run(4000, halt_detect=False)
    return cpu


def test_card():
    card = iod.MemoryCard()
    m = run(card).mem
    got = [m[a] for a in range(0x40, 0x45)]
    assert got == [0xA5, 0x5A, 0x22, 0x33, 0xF0], 'read back %s' % [hex(v) for v in got]
    assert card.page == 0xFFF
    assert card.ram[0x002 << 7 | 0x7D] == 0x22 and card.ram[0xFFF << 7 | 0x7D] == 0xF0
    assert card.ram[0x302 << 7 | 0x7D] == 0x33
    assert card.ram[0x302 << 7 | 0x7E] == 0xFF, 'the page write lands in the page being left'
    return 'card in slot 2: five pages keep their bytes'


def test_empty():
    m = run(None).mem
    assert (m[0x40], m[0x41]) != (0xA5, 0x5A), 'an empty slot passed the detect'
    return 'empty slot: detect fails'


if __name__ == '__main__':
    for t in (test_card, test_empty):
        print('ok  ', t())
