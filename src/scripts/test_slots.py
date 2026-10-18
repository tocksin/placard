#!/usr/bin/env python3
"""
test_slots.py - test the expansion card boot (rom_boot.asm) and slot_id
(placard_slot.asm) in the simulator

    python3 test_slots.py

Each test builds the ROM as gen_rom.tcl does (boot loader, library and a
small ROM program), puts cards in the slots (io_devices.Slots) and starts
the CPU at x0000 with an empty RAM and the map cleared, as at power-up.
The cards' boot code is assembled for RAM x0100 and records what it was
given, so the tests check the scan order, the arguments, the checksum
and length checks, Esc to skip, a card taking the boot over, and a card
calling the library.

Date: 10/18/2026
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import io_devices as iod    # noqa: E402

PROG = '''#include "placard.asm"
#include "placard_lib.asm"
#addr 0x6000
main:
    ld   0x5A, ac
    ld   ac, [0x3F]
done:
    bra  done
'''

# records the call: zp x40 + n = slot (n = calls so far, in x30),
# x50 + slot = R1, x58 + slot = R0; then returns
CARD_LOG = '''#include "placard.asm"
#include "zeropage.asm"
#addr 0x0100
    ld   ac, [0x31]
    ld   [0x30], ac
    add  0x40, x
    ld   [0x31], ac
    ld   ac, [x]
    ld   [0x30], ac
    inc
    ld   ac, [0x30]
    ld   [0x31], ac
    add  0x50, x
    ld   [R1], ac
    ld   ac, [x]
    ld   [0x31], ac
    add  0x58, x
    ld   [R0], ac
    ld   ac, [x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
'''

# takes the boot over: never returns
CARD_TAKE = '''#include "placard.asm"
#addr 0x0100
    ld   0xC3, ac
    ld   ac, [0x3E]
take:
    bra  take
'''

# calls the library: memset(x0400, 200 bytes, AC = slot), then returns
CARD_LIB = '''#include "placard.asm"
#include "placard_lib.asm"
#addr 0x0100
    ld   ac, [0x31]
    ld   [LINK_LO], ac
    ld   ac, [0x32]
    ld   [LINK_HI], ac
    ld   ac, [0x33]
    ld   0x00, ac
    ld   ac, [R0]
    ld   0x04, ac
    ld   ac, [R1]
    ld   200, ac
    ld   ac, [R2]
    ld   [0x31], ac
    ld   LINK_LO, x
    ld   back, [x]
    ld   LINK_HI, x
    ld   back >> 8, [x]
    ld   memset >> 8, y
    jmp  memset
back:
    ld   [0x33], y
    jmp  [0x32]
'''


def code(src):
    mem, _, _ = ps.assemble(src, HERE)
    return [mem.get(a, 0) for a in range(0x100, max(a for a in mem if a < 0x200) + 1)]


def boot(cards, keys=(), steps=400_000):
    prog, syms, _ = ps.assemble(PROG, HERE)
    rom = ps.build_rom(prog)
    slots = iod.Slots()
    for n, c in cards.items():
        slots.cards[n - 1] = c
    port = iod.SharedPort()
    port.keys = set(keys)
    cpu = ps.Cpu({}, rom=rom, io=port, slots=slots)
    cpu.run(steps, halt_detect=False)
    return cpu, syms


def card(src, cid=7, **kw):
    return iod.ExpansionCard(iod.card_rom(cid, code(src), **kw))


def test_no_cards():
    cpu, syms = boot({})
    assert cpu.mem[0x3F] == 0x5A and cpu.pc >= 0x6000, 'program did not start'
    return 'empty slots: straight to the program'


def test_order_and_args():
    cpu, _ = boot({2: card(CARD_LOG), 4: card(CARD_LOG), 3: iod.ExpansionCard([])})
    m = cpu.mem
    assert m[0x30] == 2, 'cards called %d times' % m[0x30]
    assert (m[0x40], m[0x41]) == (4, 2), 'order %d, %d' % (m[0x40], m[0x41])
    assert (m[0x52], m[0x5A]) == (0x53, 0x00), 'slot 2 base %02X%02X' % (m[0x52], m[0x5A])
    assert (m[0x54], m[0x5C]) == (0x53, 0x80), 'slot 4 base %02X%02X' % (m[0x54], m[0x5C])
    assert m[0x3F] == 0x5A, 'program did not start after the cards'
    return 'slot 4 then 2, with AC = slot and R1:R0 = base, then the program'


def test_checks():
    cpu, _ = boot({4: card(CARD_LOG, bad_sum=True), 3: card(CARD_LOG),
                   2: iod.ExpansionCard([0x50, 0x4C, 0x43, 1, 0]),          # no code
                   1: iod.ExpansionCard([0x50, 0x4C, 0x42, 1, 1, 0, 0])})  # not PLC
    m = cpu.mem
    assert m[0x30] == 1 and m[0x40] == 3, 'calls %d, first slot %d' % (m[0x30], m[0x40])
    assert m[0x3F] == 0x5A
    long = iod.ExpansionCard([0x50, 0x4C, 0x43, 1, 91, 0] + [0] * 91)
    cpu, _ = boot({1: long})
    assert cpu.mem[0x3F] == 0x5A
    return 'bad checksum, no code, wrong header and 91 bytes are skipped'


def test_takeover():
    cpu, _ = boot({3: card(CARD_TAKE), 1: card(CARD_LOG)})
    m = cpu.mem
    assert m[0x3E] == 0xC3 and 0x0100 <= cpu.pc < 0x0200, 'PC %04X' % cpu.pc
    assert m[0x30] == 0 and m[0x3F] == 0, 'boot went on after the take-over'
    return 'slot 3 takes the boot; slot 1 and the program never run'


def test_esc_skips():
    cpu, _ = boot({4: card(CARD_TAKE)}, keys=[(0, 0)])
    assert cpu.mem[0x3E] == 0 and cpu.mem[0x3F] == 0x5A
    return 'Esc held at power-up: cards skipped'


def test_card_uses_library():
    cpu, _ = boot({2: card(CARD_LIB)})
    m = cpu.mem
    assert all(m[0x0400 + i] == 2 for i in range(200)), 'memset from the card failed'
    assert m[0x3F] == 0x5A
    return 'a card calls memset and returns'


def test_slot_id():
    src = PROG.replace('done:', '''    ld   1, ac
    ld   LINK_LO, x
    ld   r1, [x]
    ld   LINK_HI, x
    ld   r1 >> 8, [x]
    ld   slot_id >> 8, y
    jmp  slot_id
r1:
    ld   ac, [0x60]
    ld   [R0], ac
    ld   ac, [0x61]
    ld   [R1], ac
    ld   ac, [0x62]
    ld   4, ac
    ld   LINK_LO, x
    ld   r4, [x]
    ld   LINK_HI, x
    ld   r4 >> 8, [x]
    ld   slot_id >> 8, y
    jmp  slot_id
r4:
    ld   ac, [0x63]
    ld   [R0], ac
    ld   ac, [0x64]
    ld   [R1], ac
    ld   ac, [0x65]
done:''')
    prog, _, _ = ps.assemble(src, HERE)
    slots = iod.Slots()
    slots.cards[0] = iod.ExpansionCard([0x50, 0x4C, 0x43, 0x99, 0])
    cpu = ps.Cpu({}, rom=ps.build_rom(prog), io=iod.SharedPort(), slots=slots)
    cpu.run(400_000, halt_detect=False)
    m = cpu.mem
    assert (m[0x60], m[0x61], m[0x62]) == (0x99, 0x00, 0x51), [hex(v) for v in m[0x60:0x63]]
    assert (m[0x63], m[0x64], m[0x65]) == (0x00, 0x80, 0x53), [hex(v) for v in m[0x63:0x66]]
    return 'slot 1 ID 99 at x5100; slot 4 empty (0) at x5380'


TESTS = [(n, f) for n, f in sorted(globals().items()) if n.startswith('test_')]


def main():
    bad = 0
    for name, f in TESTS:
        try:
            print('ok    %-24s %s' % (name, f() or ''))
        except AssertionError as e:
            bad += 1
            print('FAIL  %-24s %s' % (name, e))
    print('%d failed' % bad if bad else 'all passed')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
