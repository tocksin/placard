#!/usr/bin/env python3
"""
test_bringup_sim.py - run the bring-up test ROM (bringup.asm) in placard_sim

    python3 gen_bringup.py                  writes bringup.asm
    python3 test_bringup_sim.py             all the checks below
    python3 test_bringup_sim.py --png b.png also save the status screen
    python3 test_bringup_sim.py --bin       also write bringup.bin (32 KB, for
                                            the 32K cartridge's EEPROM)

The ROM image is 32 KB, read in both halves of the ROM as the 32K cartridge
shows it (its own reset code at x0000, the library at x8000-xFBFF and its
LIB_RAM bytes at x1F00), so the simulator runs it with
no boot loader, from random RAM, with the hardware ALU model and the shared
port model (PS/2 keyboard and mouse, pads, SD card).  Checks:

  - the chip gates: for each build step of BRINGUP.md, with only the chips
    fitted so far (PartCpu: the missing chips' pins float, the bus keeps
    its last byte) the PC stops in that step's gate page and no other;
    with the D source buffer missing but the RAM in, it never settles in
    gate 7 or reaches the status screen
  - a good machine passes the startup tests, draws the status screen and
    runs the frame loop: LOOPS and FRAME count up, the RAM test makes
    passes with no errors, SD_INIT and MOUSE_INIT show the attached parts
  - typed keys echo; T turns the test tone on (the audio buffer changes)
    and off; S retries the SD card
  - injected faults stop the CPU in the right place: an ALU output pin in
    gate 1, a RAM data bit (or the map bit gate 6 uses) in gate 6, a
    stuck line read bit in gate 7, and in the fail loops (PC = x0080 + 4N)
    a map register bit (14) and a RAM address line (15); a RAM bit that goes bad later is counted by
    the RAM page test

Video stalls are not modeled, so the CPU runs about 10 % faster than on
the board; the per-frame work is bounded, so the frame loop runs once per
frame on both.

Date: 11/11/2026
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
        self.port.kbd = iod.Ps2Keyboard()
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
    assert rows[8][22:46] == 'FF FF FF FF FF FF FF FF ', 'KBD_NOW %r' % rows[8][22:46]
    print('good machine: startup tests and screen %.1f ms, LOOPS %d, FRAME %d, RAM passes %d, '
          'errors %d' % (t_up / 25175.0, loops, frame, passes, errors))

    # keys: "a" echoes, "t" starts the tone, "t" again stops it, "s" retries
    # (PS/2 set-2 codes; the keyboard gets the line every other frame while
    # the mouse is there, and sends one byte per turn)
    def press(k, frames=6):
        rig.port.kbd.press(k)
        assert rig.frames(frames) is None
        rig.port.kbd.release(k)
        assert rig.frames(frames) is None
    press(0x1C)                                    # a
    press(0x1C)
    row9 = text_row(cpu, 9, font)
    assert row9[7:9] == 'aa', 'echo %r' % row9[:20]
    press(0x2C)                                    # t
    row20 = text_row(cpu, 20, font)
    assert row20[32:35] == 'ON ', 'tone %r' % row20[30:36]
    audio = sorted(set(cpu.mem[a] for a in range(0x5DF3, 0x6000)))
    # a square wave, 80h +- 48
    assert {0x50, 0xB0} <= set(audio), 'tone on, but the audio buffer holds %r' % audio[:8]
    press(0x2C)
    row20 = text_row(cpu, 20, font)
    assert row20[32:35] == 'OFF', 'tone %r' % row20[30:36]
    rig.port.mouse.move(dx=20, dy=-7)                # PS/2 Y counts up
    assert rig.frames(4) is None
    row17 = text_row(cpu, 17, font)
    mx, my = num(row17[25:]), num(row17[34:])
    assert (mx, my) == (20, 7), 'mouse X %d Y %d, want 20 7' % (mx, my)
    print('mouse: moved right 20, down 7, shows X %d Y %d' % (mx, my))
    rig.port.sd = None                             # take the card out, retry
    press(0x1B)                                    # s
    row14 = text_row(cpu, 14, font)
    assert row14[17:19] != '00', 'SD_INIT %r with no card' % row14[17:19]
    print('keys: echo %r, T tone on (samples %s) and off, S retry SD_INIT %s'
          % (row9[7:9], ' '.join('%02X' % v for v in audio), row14[17:19]))
    if args.png:
        ps.render(cpu.mem, args.png)
        print('wrote', args.png)


class AliasMem(bytearray):
    """the RAM with address lines stuck low (mask): reads and writes both
    go to the cell with those bits clear"""
    mask = 0

    def __getitem__(self, i):
        if isinstance(i, int):
            i &= ~self.mask
        return bytearray.__getitem__(self, i)

    def __setitem__(self, i, v):
        if isinstance(i, int):
            i &= ~self.mask
        bytearray.__setitem__(self, i, v)


def run_fault(rom, syms, name, want, read=None, line=None, alu=None, addr_mask=0,
              limit_frames=40):
    """want: the fail loop, or a tuple of the ones that may catch it first"""
    rig = Rig(rom, sd=False, mouse=False)
    cpu = rig.cpu
    if addr_mask:
        cpu.mem = AliasMem(cpu.mem)
        cpu.mem.mask = addr_mask
    if read is not None:
        plain = cpu.read
        cpu.read = lambda ad: read(cpu, ad, plain(ad))
    if line is not None:
        plain_lr = cpu.line_read
        cpu.line_read = lambda: line(plain_lr())
    if alu is not None:
        plain_alu = cpu.alu
        cpu.alu = lambda s, a, b: alu(s, plain_alu(s, a, b))
    stops = {syms[k]: 'gate 1' for k in ('g1_flags', 'g1_bits', 'g1_carry', 'g1_shift')}
    stops.update({syms['gate%d_stop' % n]: 'gate %d' % n for n in gb.GATE_PAGES if n != 5})
    got = None
    while cpu.clocks < limit_frames * CLOCKS_PER_FRAME:
        cpu.step()
        if cpu.pc in FAILS:
            got = FAILS[cpu.pc]
            break
        if cpu.pc in stops:
            got = stops[cpu.pc]
            break
    wants = want if isinstance(want, tuple) else (want,)
    ok = got in wants
    print('%-44s stops in %-7s (want %s)  %s' % (name, got if isinstance(got, str) else 'fail loop %s' % got,
                                                 ' or '.join(map(str, wants)), 'ok' if ok else 'WRONG'))
    return ok


def in_ram(cpu, ad):
    return (cpu.map >> (ad >> 13)) & 1


def faults(rom, syms):
    ok = True
    # RAM data bit 5 of the lower chip stuck at 0
    ok &= run_fault(rom, syms, 'RAM data bit 5 stuck low (lower chip)', 'gate 6',
                    read=lambda cpu, ad, v: v & ~0x20 if in_ram(cpu, ad) and ad < 0x8000 else v)
    # upper chip data bit 2 stuck high
    ok &= run_fault(rom, syms, 'RAM data bit 2 stuck high (upper chip)', 'gate 6',
                    read=lambda cpu, ad, v: v | 0x04 if in_ram(cpu, ad) and ad >= 0x8000 else v)
    # map register bits stuck at 0 (the section reads ROM)
    for b in (1, 2, 5, 7):
        def rd(cpu, ad, v, b=b):
            if (ad >> 13) == b and (cpu.map >> b) & 1:
                return cpu.rom[ad]
            return v
        ok &= run_fault(rom, syms, 'map register bit %d stuck low' % b,
                        'gate 6' if b == 1 else 14, read=rd)   # gate 6 puts its RAM in sections 1 and 4
    # map bit 6 stuck high: section 6 reads RAM when the map says ROM
    def rd6(cpu, ad, v):
        if (ad >> 13) == 6:
            return cpu.mem[ad]
        return v
    ok &= run_fault(rom, syms, 'map register bit 6 stuck high', 14, read=rd6)
    # map bits 2 and 6 swapped: their sections share a ROM marker (the mirror)
    def rd26(cpu, ad, v):
        sec = ad >> 13
        if sec in (2, 6) and not 0x5000 <= ad < 0x5400:
            return cpu.mem[ad] if (cpu.map >> (sec ^ 4)) & 1 else cpu.rom[ad]
        return v
    ok &= run_fault(rom, syms, 'map register bits 2 and 6 swapped', 14, read=rd26)
    # RAM address lines stuck low (both chips share A14:A0)
    for b in (0, 4, 9, 13, 14):
        ok &= run_fault(rom, syms, 'RAM address line A%d stuck low' % b, 15, addr_mask=1 << b)
    # line read bit stuck
    # line read bit stuck: at start-up test 16 waits in gate 7
    ok &= run_fault(rom, syms, 'line read bit V5 stuck low', 'gate 7', line=lambda v: v & ~0x08)
    ok &= run_fault(rom, syms, 'line read bit V9 stuck high', 'gate 7', line=lambda v: v | 0x80)
    # an ALU output pin stuck: gate 1 stops it before the first jump (every
    # register, the jump's page in Y too, loads through the ALU)
    for b in range(8):
        ok &= run_fault(rom, syms, 'ALU output F%d stuck low' % b, 'gate 1',
                        alu=lambda s, r, b=b: r & ~(1 << b))
        ok &= run_fault(rom, syms, 'ALU output F%d stuck high' % b, 'gate 1',
                        alu=lambda s, r, b=b: r | (1 << b))
    ok &= run_fault(rom, syms, 'ADD result bit 4 stuck low', 'gate 1',
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


# ---------------------------------------------------------------------------
# The chip gates: the CPU with chips missing, as it is in the build steps
# ---------------------------------------------------------------------------
CHIPS = ('alu', 'u27', 'y', 'x', 'u26', 'ram', 'u29')    # 'alu' is AC + both ALU PLDs


class PartCpu(ps.Cpu):
    """the CPU with some chips not fitted yet (have: the ones that are).

    What a missing chip does:
      - no ALU and AC: the flags Z, N and the carry are pins that float at
        some level (fz, fn, fc); nothing loads AC, X or Y with sense (the
        registers' inputs float high: FF)
      - no X or Y register: that address byte floats (fx, fy)
      - no source buffer (U26 for D, U27 for AC): the data bus keeps the
        last byte a memory put on it.  For a D source that is the byte D
        holds, so it works, unless the RAM is in: then a video read between
        the load and the execute clock leaves the RAM's byte there instead
        (chance hit per instruction, a random byte)
      - no RAM: a RAM read, and no line read buffer U29: a read of x5000,
        leaves the bus as it was
    float_rnd: the floating values are taken again at every use (they need
    not hold still) instead of once."""

    def __init__(self, rom, have, seed=1, hit=0.05, float_rnd=False):
        super().__init__({}, hw_alu=True, rom=rom)
        self.have = set(have)
        self.rnd = random.Random(seed)
        r = self.rnd
        self.mem = bytearray(r.randrange(256) for _ in range(65536))
        self.fl = dict(z=r.randrange(2), n=r.randrange(2), c=r.randrange(2),
                       x=r.randrange(256), y=r.randrange(256))
        self.float_rnd = float_rnd
        self.hit = hit
        self.bus = 0xFF
        self.ac = r.randrange(256)
        self.pages = set()                # the PC high bytes it has run in

    def f(self, k):
        if self.float_rnd:
            return self.rnd.randrange(2 if k in 'znc' else 256)
        return self.fl[k]

    def rd(self, ad):
        if 0x5000 <= ad < 0x5400:
            if ad < 0x5100 and 'u29' in self.have:
                self.bus = self.line_read()
            return self.bus                       # nothing else answers in the I/O window
        if (self.map >> (ad >> 13)) & 1:
            if 'ram' in self.have:
                self.bus = self.mem[ad]
        else:
            self.bus = self.rom[ad]
        return self.bus

    def step(self):
        have = self.have
        here = self.pc
        self.pages.add(here >> 8)
        opc = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        a, m, s = opc >> 5, (opc >> 2) & 7, opc & 3
        clocks = 2
        if (s == 0) or (s == 1 and m in (0, 3, 4, 5)) or (s >= 2 and m == 5):
            self.d = self.rd(self.pc)
            self.pc = (self.pc + 1) & 0xFFFF
            clocks += 1
        x = self.x if 'x' in have else self.f('x')
        y = self.y if 'y' in have else self.f('y')
        if m in (0, 3, 4, 5):
            ad = self.d
        elif m in (1, 6):
            ad = x
        else:
            ad = (y << 8) | x
        if s == 1 or (s >= 2 and m in (6, 7)):
            v = self.rd(ad)                       # LOAD_MEM (for an AC source the byte is not used)
            if s == 1:
                self.d = v
            clocks += 1
        if s < 2:
            src = self.d
            if 'u26' not in have:
                src = self.bus
                if 'ram' in have and self.rnd.random() < self.hit:
                    src = self.rnd.randrange(256)     # a video read got in between
        else:
            src = self.ac if 'u27' in have else self.bus
        self.bus = src
        alu = 'alu' in have
        res = self.alu(a, self.ac, src) if alu else 0xFF
        if a == 7:
            if alu:
                z, neg, c = self.ac == 0, (self.ac >> 7) & 1, self.c
            else:
                z, neg, c = self.f('z'), self.f('n'), self.f('c')
            if [True, c, (not z) and neg, not z, z, not c, z or neg, True][m]:
                self.pc = (self.pc & 0xFF00) | src
                if m == 0:
                    self.pc = (y << 8) | src
        else:
            if a in (4, 5) and m <= 4:
                clocks += 1
                if alu:
                    self.c = self.carry(a, self.ac, src)
            if m in (0, 1, 2):
                if alu:
                    self.ac = res
            elif m == 3:
                self.x = res
            elif m == 4:
                self.y = res
            else:
                if 'ram' in have:
                    self.mem[ad] = src
                if ad & 0xFF00 == 0x5000:
                    self.map = src
        self.steps += 1
        self.clocks += clocks
        return here


def settle(cpu, syms, clocks):
    """runs it; returns the gate page it stopped in (PC high held still for
    the last half of the run), 'main' if it reached the status screen code,
    or None"""
    half = None
    while cpu.clocks < clocks:
        cpu.step()
        if cpu.pc == syms['main']:
            return 'main'
        if half is None and cpu.clocks >= clocks // 2:
            half = cpu.pc >> 8
            cpu.pages = set()
    return half if cpu.pages == {half} else None


def gate_checks(rom, syms):
    """each build step: with the chips fitted so far the PC must stop in the
    next chip's gate page, whatever the missing chips' pins float at, and
    never get past it"""
    ok = True
    steps = [((), 1, 'the cartridge alone'),
             (('alu',), 2, 'then AC and the ALU (U19, U5, U6)'),
             (('alu', 'u27'), 3, 'then the AC source buffer (U27)'),
             (('alu', 'u27', 'y'), 4, 'then the Y register (U21)'),
             (('alu', 'u27', 'y', 'x'), 6, 'then the X register (U20)'),
             (('alu', 'u27', 'y', 'x', 'u26', 'ram'), 7, 'then the D source buffer (U26) and the RAM'),
             (('alu', 'u27', 'y', 'x', 'u26', 'ram', 'u29'), 'main', 'then the line read buffer (U29)')]
    for have, want, name in steps:
        bad = {}
        n = 0
        for float_rnd in (False, True):
            for seed in range({7: 5, 'main': 2}.get(want, 60)):
                cpu = PartCpu(rom, have, seed=seed, float_rnd=float_rnd)
                got = settle(cpu, syms, {7: 2_000_000, 'main': 60_000_000}.get(want, 400_000))
                n += 1
                if got != want:
                    bad[got] = bad.get(got, 0) + 1
        good = not bad
        ok &= good
        print('%-46s %-16s %3d runs  %s'
              % (name, 'status screen' if want == 'main' else 'stops in gate %s' % want, n, 'ok' if good else 'WRONG: %r' % bad))
    # the D source buffer missing with the RAM in: where it ends up depends on
    # how often a video read lands between LOAD and EXEC, but it must never
    # look like a pass (steady in gate 7, or the status screen)
    past = 0
    where = {}
    runs = 60
    for seed in range(runs):
        cpu = PartCpu(rom, ('alu', 'u27', 'y', 'x', 'ram'), seed=seed, hit=(0.01, 0.05, 0.2)[seed % 3])
        got = settle(cpu, syms, 2_000_000)
        if got in (7, 'main'):
            past += 1
        key = 'main' if got == 'main' else 'wanders' if got is None else '%02X' % got
        where[key] = where.get(key, 0) + 1
    good = past == 0
    ok &= good
    print('%-46s never gate 7 or the status screen: %d of %d runs did  %s  (%s)'
          % ('no U26 with the RAM in', past, runs, 'ok' if good else 'WRONG',
             ', '.join('%s: %d' % kv for kv in sorted(where.items()))))
    return ok


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    ap.add_argument('--bin', action='store_true')
    ap.add_argument('--no-faults', action='store_true')
    ap.add_argument('--faults-only', action='store_true')
    ap.add_argument('--gates-only', action='store_true')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args(argv)
    mem, syms = build()
    img = gb.image(mem)            # 32 KB, read in both halves of the ROM
    rom = {a: img[a & 0x7FFF] for a in range(65536)}
    font = make_font(rom)
    if args.bin:
        open(os.path.join(HERE, 'bringup.bin'), 'wb').write(img)
        print('wrote bringup.bin (%d bytes)' % len(img))
    if args.gates_only:
        ok = gate_checks(rom, syms)
        print('OK' if ok else 'FAILED')
        return 0 if ok else 1
    if not args.faults_only:
        check_good(rom, syms, font, args)
    ok = gate_checks(rom, syms)
    if not args.no_faults:
        ok &= faults(rom, syms)
        ok &= ram_late_fault(rom, syms, font)
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
