#!/usr/bin/env python3
"""
test_bringup_sim.py - run the bring-up test ROM (bringup.asm) in placard_sim

    python3 gen_bringup.py                  writes bringup.asm
    python3 test_bringup_sim.py             all the checks below
    python3 test_bringup_sim.py --png b.png also save the status screen
    python3 test_bringup_sim.py --bin       also write bringup_lo.bin and
                                            bringup_hi.bin (32 KB each, for
                                            the ROM chips #33 and #34)

The ROM image is the whole 64 KB (its own reset code at x0000, the library
at xC000-xFBFF and its LIB_RAM bytes at x1F00), so the simulator runs it with
no boot loader, from random RAM, with the hardware ALU model and the shared
port model (keyboard, pads, SD card, mouse).  Checks:

  - a good machine passes the startup tests, draws the status screen and
    runs the frame loop: LOOPS and FRAME count up, the RAM test makes
    passes with no errors, SD_INIT and MOUSE_INIT show the attached parts
  - typed keys echo; T turns the test tone on (the audio buffer changes)
    and off; S retries the SD card
  - injected faults stop the CPU in the right fail loop (PC = x0080 + 4N):
    a RAM data bit (13), a map register bit (14), a RAM address line (15),
    a stuck line read bit (16), an ALU result bit (2-8, the first one that
    sees it), and a RAM bit that goes bad later is counted by the RAM page
    test

Video stalls are not modeled, so the CPU runs about 10 % faster than on
the board; the per-frame work is bounded, so the frame loop runs once per
frame on both.

Date: 10/19/2026
"""

import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import io_devices as iod  # noqa: E402
import gen_bringup as gb  # noqa: E402

CLOCKS_PER_FRAME = 525 * 800
FAILS = {gb.FAIL_BASE + 4 * n: n for n in range(1, 17)}


def build():
    src = gb.generate()
    open(os.path.join(HERE, 'bringup.asm'), 'w').write(src)
    mem, syms, _ = ps.assemble(src, HERE)
    return mem, syms


def text_row(cpu, row, font):
    out = []
    for col in range(80):
        cell = tuple(cpu.mem[0x6000 + col * 512 + 32 + row * 8 + k] for k in range(8))
        out.append(font.get(cell, '?'))
    return ''.join(out)


def make_font(rom):
    font = {}
    for code in range(0x20, 0x7F):
        cell = tuple(rom[ps.LIB_FONT + k * 256 + code] for k in range(8))
        font.setdefault(cell, chr(code))
    return font


class Rig:
    def __init__(self, rom, seed=1, sd=True, mouse=True):
        rnd = random.Random(seed)
        ram = {a: rnd.randrange(256) for a in range(65536)}
        self.port = iod.SharedPort()
        if sd:
            self.port.sd = iod.SdCard(bytearray(64 * 512))     # not formatted
        if mouse:
            self.port.mouse = iod.Ps2Mouse()
        self.cpu = ps.Cpu(ram, hw_alu=True, rom=rom, io=self.port)

    def run_clocks(self, n):
        """runs n clocks; returns the fail number if the CPU is in a fail loop"""
        cpu = self.cpu
        end = cpu.clocks + n
        while cpu.clocks < end:
            cpu.step()
            if cpu.pc in FAILS:
                return FAILS[cpu.pc]
        return None

    def frames(self, n):
        return self.run_clocks(n * CLOCKS_PER_FRAME)

    def until(self, pc, limit):
        r = self.cpu.run(limit, halt_detect=False, stop_pc=pc)
        return r == 'stop'


def num(s):
    return int(s.split()[0])


def check_good(rom, syms, font, args):
    rig = Rig(rom)
    cpu = rig.cpu
    fail = None
    # startup tests and the screen, up to the first frame loop pass
    while cpu.pc != syms['frame_loop']:
        cpu.step()
        if cpu.pc in FAILS:
            fail = FAILS[cpu.pc]
            break
        if cpu.clocks > 40 * CLOCKS_PER_FRAME:
            break
    assert fail is None, 'good machine stopped in fail loop %d' % fail
    assert cpu.pc == syms['frame_loop'], 'never reached the frame loop (PC %04X)' % cpu.pc
    t_up = cpu.clocks
    nfr = len(gb.RT_PAGES) + 3
    fail = rig.frames(nfr)
    assert fail is None, 'good machine stopped in fail loop %d in the frame loop' % fail
    rows = {r: text_row(cpu, r, font) for r in range(0, 23)}
    if args.verbose:
        for r in sorted(rows):
            print('%2d |%s|' % (r, rows[r]))
    loops = num(rows[2][58:])
    frame = num(rows[0][66:])
    passes = num(rows[5][23:])
    errors = num(rows[5][39:])
    assert abs(loops - nfr) <= 2, 'LOOPS %d after %d frames' % (loops, nfr)
    # FRAME starts at 0 just before the screen is drawn
    assert t_up // CLOCKS_PER_FRAME <= frame <= nfr + t_up // CLOCKS_PER_FRAME + 1, 'FRAME %d' % frame
    assert passes == 1, 'RAM test passes %d after %d frames' % (passes, nfr)
    assert errors == 0, 'RAM test errors %d' % errors
    assert rows[14][17:19] == '00', 'SD_INIT %r' % rows[14][17:19]
    assert rows[14][31:33] != '00', 'FS_MOUNT %r on an unformatted card' % rows[14][31:33]
    assert rows[17][18:20] == '00', 'MOUSE_INIT %r' % rows[17][18:20]
    assert rows[8][22:46] == 'FF FF FF FF FF FF FF FF ', 'keyboard rows %r' % rows[8][22:46]
    print('good machine: startup tests and screen %.1f ms, LOOPS %d, FRAME %d, RAM passes %d, '
          'errors %d' % (t_up / 25175.0, loops, frame, passes, errors))

    # keys: "a" echoes, "t" starts the tone, "t" again stops it, "s" retries
    def press(k, frames=2):
        rig.port.keys = {(k >> 3, k & 7)}
        assert rig.frames(frames) is None
        rig.port.keys = set()
        assert rig.frames(frames) is None
    press(29)                                      # a
    press(29)
    row9 = text_row(cpu, 9, font)
    assert row9[7:9] == 'aa', 'echo %r' % row9[:20]
    press(19)                                      # t
    row20 = text_row(cpu, 20, font)
    assert row20[32:35] == 'ON ', 'tone %r' % row20[30:36]
    audio = sorted(set(cpu.mem[a] for a in range(0x5DF3, 0x6000)))
    # a square wave, 80h +- 48
    assert {0x50, 0xB0} <= set(audio), 'tone on, but the audio buffer holds %r' % audio[:8]
    press(19)
    row20 = text_row(cpu, 20, font)
    assert row20[32:35] == 'OFF', 'tone %r' % row20[30:36]
    rig.port.mouse.move(dx=20, dy=7)
    assert rig.frames(4) is None
    row17 = text_row(cpu, 17, font)
    mx, my = num(row17[24:]), num(row17[33:])
    assert (mx, my) == (20, 7), 'mouse X %d Y %d, want 20 7' % (mx, my)
    print('mouse: moved 20, 7, shows X %d Y %d' % (mx, my))
    rig.port.sd = None                             # take the card out, retry
    press(30)                                      # s
    row14 = text_row(cpu, 14, font)
    assert row14[17:19] != '00', 'SD_INIT %r with no card' % row14[17:19]
    print('keys: echo %r, T tone on (samples %s) and off, S retry SD_INIT %s'
          % (row9[7:9], ' '.join('%02X' % v for v in audio), row14[17:19]))
    if args.png:
        ps.render(cpu.mem, args.png)
        print('wrote', args.png)


def run_fault(rom, syms, name, want, read=None, line=None, alu=None, limit_frames=40):
    rig = Rig(rom, sd=False, mouse=False)
    cpu = rig.cpu
    if read is not None:
        plain = cpu.read
        cpu.read = lambda ad: read(cpu, ad, plain(ad))
    if line is not None:
        plain_lr = cpu.line_read
        cpu.line_read = lambda: line(plain_lr())
    if alu is not None:
        plain_alu = cpu.alu
        cpu.alu = lambda s, a, b: alu(s, plain_alu(s, a, b))
    got = None
    while cpu.clocks < limit_frames * CLOCKS_PER_FRAME:
        cpu.step()
        if cpu.pc in FAILS:
            got = FAILS[cpu.pc]
            break
    ok = got == want
    print('%-44s fail loop %-4s (want %d)  %s' % (name, got, want, 'ok' if ok else 'WRONG'))
    return ok


def in_ram(cpu, ad):
    return (cpu.map >> (ad >> 13)) & 1


def faults(rom, syms):
    ok = True
    # RAM data bit 5 of the lower chip stuck at 0
    ok &= run_fault(rom, syms, 'RAM data bit 5 stuck low (lower chip)', 13,
                    read=lambda cpu, ad, v: v & ~0x20 if in_ram(cpu, ad) and ad < 0x8000 else v)
    # upper chip data bit 2 stuck high
    ok &= run_fault(rom, syms, 'RAM data bit 2 stuck high (upper chip)', 13,
                    read=lambda cpu, ad, v: v | 0x04 if in_ram(cpu, ad) and ad >= 0x8000 else v)
    # map register bits stuck at 0 (the section reads ROM)
    for b in (1, 2, 5, 7):
        def rd(cpu, ad, v, b=b):
            if (ad >> 13) == b and (cpu.map >> b) & 1:
                return cpu.rom[ad]
            return v
        ok &= run_fault(rom, syms, 'map register bit %d stuck low' % b, 14, read=rd)
    # map bit 6 stuck high: section 6 reads RAM when the map says ROM
    def rd6(cpu, ad, v):
        if (ad >> 13) == 6:
            return cpu.mem[ad]
        return v
    ok &= run_fault(rom, syms, 'map register bit 6 stuck high', 14, read=rd6)
    # RAM address lines stuck low: the RAM reads the cell with that bit clear
    for b in (0, 4, 9, 13, 14):
        def rd(cpu, ad, v, b=b):
            if in_ram(cpu, ad):
                return cpu.mem[ad & ~(1 << b)]
            return v
        ok &= run_fault(rom, syms, 'RAM address line A%d stuck low' % b, 15 if b != 0 else 13, read=rd)
    # line read bit stuck
    ok &= run_fault(rom, syms, 'line read bit V5 stuck low', 16, line=lambda v: v & ~0x08)
    ok &= run_fault(rom, syms, 'line read bit V9 stuck high', 16, line=lambda v: v | 0x80)
    # an ALU output bit stuck: AND (test 2) is the first ALU result checked
    ok &= run_fault(rom, syms, 'ALU result bit 3 stuck low', 2, alu=lambda s, r: r & ~0x08 if s != 7 else r)
    ok &= run_fault(rom, syms, 'ADD result bit 4 stuck low', 5,
                    alu=lambda s, r: r & ~0x10 if s == 4 else r)
    return ok


def ram_late_fault(rom, syms, font):
    """a bit that goes bad after start-up: only the page test sees it"""
    rig = Rig(rom)
    cpu = rig.cpu
    assert rig.until(syms['frame_loop'], 50_000_000)
    bad = 0x4321
    plain = cpu.read
    cpu.read = lambda ad: plain(ad) ^ 0x08 if ad == bad and in_ram(cpu, ad) else plain(ad)
    nfr = len(gb.RT_PAGES) + 2
    assert rig.frames(nfr) is None
    row5 = text_row(cpu, 5, font)
    errors = num(row5[39:])
    where = row5[57:61]
    # every pattern differs in bit 3 when read back flipped: 6 errors a pass
    ok = errors == 6 and where == '4321'
    print('RAM bit 3 at x4321 bad after start-up: ERRORS %d, LAST BAD %s  %s'
          % (errors, where, 'ok' if ok else 'WRONG'))
    return ok


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    ap.add_argument('--bin', action='store_true')
    ap.add_argument('--no-faults', action='store_true')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args(argv)
    mem, syms = build()
    rom = dict(mem)
    font = make_font(rom)
    if args.bin:
        img = bytes(rom.get(a, 0xFF) for a in range(65536))
        open(os.path.join(HERE, 'bringup_lo.bin'), 'wb').write(img[:0x8000])
        open(os.path.join(HERE, 'bringup_hi.bin'), 'wb').write(img[0x8000:])
        print('wrote bringup_lo.bin and bringup_hi.bin')
    check_good(rom, syms, font, args)
    ok = True
    if not args.no_faults:
        ok &= faults(rom, syms)
        ok &= ram_late_fault(rom, syms, font)
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
