#!/usr/bin/env python3
"""
test_memcard.py - test the 32K memory expansion card model
(io_devices.MemoryCard, docs/architecture/MEMCARD.md) in the simulator

    python3 test_memcard.py

A small program finds the card in slot 2 (x5300), writes a byte to each of
four pages and reads them back into the zero page, the way MEMCARD.md
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
PROG = '''#include "placard.asm"
#addr 0x0100
start:
    ld   0x%(card)02X, y
    ; detect: page 0 gets A5 at offset 0, page 1 gets 5A, page 0 must still read A5
    ld   0x7F, x
    ld   0x00, [y,x]
    ld   0x00, x
    ld   0xA5, [y,x]
    ld   0x7F, x
    ld   0x01, [y,x]
    ld   0x00, x
    ld   0x5A, [y,x]
    ld   0x7F, x
    ld   0x00, [y,x]
    ld   0x00, x
    ld   [y,x], ac
    ld   ac, [0x40]
    ld   0x7F, x
    ld   0x01, [y,x]
    ld   0x00, x
    ld   [y,x], ac
    ld   ac, [0x41]
    ; pages 2, 3 and 255: the last free offset
    ld   0x7F, x
    ld   0x02, [y,x]
    ld   0x77, x
    ld   0x22, [y,x]
    ld   0x7F, x
    ld   0x03, [y,x]
    ld   0x77, x
    ld   0x33, [y,x]
    ld   0x7F, x
    ld   0xFF, [y,x]
    ld   0x77, x
    ld   0xF0, [y,x]
    ld   0x7F, x
    ld   0x02, [y,x]
    ld   0x77, x
    ld   [y,x], ac
    ld   ac, [0x42]
    ld   0x7F, x
    ld   0x03, [y,x]
    ld   0x77, x
    ld   [y,x], ac
    ld   ac, [0x43]
    ld   0x7F, x
    ld   0xFF, [y,x]
    ld   0x77, x
    ld   [y,x], ac
    ld   ac, [0x44]
done:
    bra  done
''' % {"card": CARD}


def run(card):
    mem, syms, _ = ps.assemble(PROG, HERE)
    slots = iod.Slots()
    slots.cards[1] = card
    cpu = ps.Cpu(dict(mem), slots=slots)
    cpu.pc = 0x0100
    cpu.run(2000, halt_detect=False)
    return cpu


def test_card():
    card = iod.MemoryCard()
    m = run(card).mem
    got = [m[a] for a in range(0x40, 0x45)]
    assert got == [0xA5, 0x5A, 0x22, 0x33, 0xF0], 'read back %s' % [hex(v) for v in got]
    assert card.page == 0xFF
    assert card.ram[2 << 7 | 0x77] == 0x22 and card.ram[255 << 7 | 0x77] == 0xF0
    assert card.ram[2 << 7 | 0x7F] == 0x03, 'the page write lands in the page being left'
    return 'card in slot 2: five pages keep their bytes'


def test_empty():
    m = run(None).mem
    assert (m[0x40], m[0x41]) != (0xA5, 0x5A), 'an empty slot passed the detect'
    return 'empty slot: detect fails'


if __name__ == '__main__':
    for t in (test_card, test_empty):
        print('ok  ', t())
