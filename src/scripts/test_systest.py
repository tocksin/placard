#!/usr/bin/env python3
"""
test_systest.py - run TEST.PLC (test.masm, the system test) through the ROM's
loader in placard_sim

    python3 test_systest.py                 the checks below
    python3 test_systest.py --png t.png     also the first screen as a PNG

Builds the 32K ROM and a card holding DOS.PLC and TEST.PLC (from test.asm),
BOOT.CFG = TEST.PLC, and boots it like the board (test_dos.Rig) with the
video stalls modeled:
  1. a good machine with a card (ID 4C) in slot 2, a PS/2 keyboard and a
     mouse: the screen says RAM OK, the slots, keyboard found, mouse found,
     SD ready and mounted; the beeps reach the audio buffer
  2. Space runs the tests again; Esc goes back to the DOS
  3. no mouse and one RAM cell with a bit stuck high (x9123 bit 3, the
     upper chip): mouse none, RAM FAILED, 1 error, at x9123, wrote B2
     read BA, bad bits 08

Date: 11/02/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402
import io_devices             # noqa: E402
import test_dos               # noqa: E402

FRAME = test_dos.FRAME
BAD_AD, BAD_BIT = 0x9123, 0x08


class StuckMem(bytearray):
    """the RAM with one cell's bit stuck high"""

    def __getitem__(self, i):
        v = bytearray.__getitem__(self, i)
        if isinstance(i, int) and i == BAD_AD:
            v |= BAD_BIT
        return v


def rig(build, mouse=True, stuck=False):
    rom, syms, dsyms, lib, dos_plc = build
    test, tsyms, _ = ps.assemble(open(os.path.join(HERE, 'test.asm')).read(), HERE)
    test_plc = gen_plc.make(test, tsyms, lib)[0]
    files = {'DOS.PLC': dos_plc, 'TEST.PLC': test_plc, 'BOOT.CFG': b'TEST.PLC\r\n'}
    r = test_dos.Rig(rom, syms, dsyms, lib, sdimage.make(files))
    if mouse:
        r.port.mouse = io_devices.Ps2Mouse()
    slots = io_devices.Slots()
    slots.cards[1] = io_devices.ExpansionCard(io_devices.card_rom(0x4C, [0x02], bad_sum=True))   # bad checksum: the boot skips it
    r.cpu.slots = slots
    if stuck:
        r.cpu.mem = StuckMem(r.cpu.mem)
    r.cpu.stalls = True
    return r, tsyms


def wait_loop(r, tsyms, frames, what):
    return r.run_until(lambda: r.cpu.pc == tsyms['loop'] and r.cpu.map == 7, frames, what)


def value(r, row):
    return r.row(row)[14:]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    build = test_dos.build()

    print('1. a good machine')
    r, tsyms = rig(build)
    cpu, mem = r.cpu, r.cpu.mem
    start = cpu.clocks
    if r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7, 300, 'TEST.PLC to start'):
        start = cpu.clocks
        print('  started at frame %d' % (cpu.clocks // FRAME))
    if r.run_until(lambda: cpu.pc == tsyms['rt_done'], 200, 'the RAM test'):
        print('  RAM test took %.2f s' % ((cpu.clocks - start) / (FRAME * 60.0)))
    wait_loop(r, tsyms, 200, 'the frame loop')
    r.run(3)
    for row in range(0, 18):
        if r.row(row):
            print('  row %2d: %r' % (row, r.row(row)))
    want = {3: 'OK, 2 passes',
            6: '1: --  2: 4C  3: --  4: --',
            8: 'found',
            10: 'found',
            12: 'ready, SDHC, FAT mounted'}
    for row, text in want.items():
        if value(r, row).strip() != text:
            r.fail('row %d: %r, want %r' % (row, value(r, row), text))
    if r.row(0).strip() != 'PLACARD SYSTEM TEST':
        r.fail('the title')
    r.run(30)
    buf = mem[0x5DF3:0x6000]
    if all(b == 0x80 for b in buf):
        r.fail('no beep in the audio buffer')
    if args.png:
        ps.render(mem, args.png)
        print('  wrote', args.png)

    print('2. Space, then Esc')
    r.key(' ')
    if r.run_until(lambda: cpu.pc == tsyms['rt_done'], 120, 'the RAM test again'):
        print('  the tests run again')
    wait_loop(r, tsyms, 200, 'the frame loop again')
    if value(r, 3).strip() != 'OK, 2 passes':
        r.fail('RAM again: %r' % value(r, 3))
    test_dos.esc_to_dos(r)
    ok = r.ok

    print('3. no mouse, a RAM bit stuck high at x%04X' % BAD_AD)
    r, tsyms = rig(build, mouse=False, stuck=True)
    wait_loop(r, tsyms, 600, 'the frame loop')
    r.run(3)
    for row in (3, 10):
        print('  row %2d: %r' % (row, r.row(row)))
    want = 'FAILED, errors: 1, first x9123 wrote B2 read BA, bad bits 08'
    if value(r, 3).strip() != want:
        r.fail('RAM: %r, want %r' % (value(r, 3), want))
    if value(r, 10).strip() != 'none':
        r.fail('mouse: %r, want none' % value(r, 10))
    ok &= r.ok

    print('PASS' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
