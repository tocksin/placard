#!/usr/bin/env python3
"""
test_snd.py - test the sound driver (placard_snd.asm) in the simulator

    python3 test_snd.py              run every test
    python3 test_snd.py -k noise     run the tests whose name contains "noise"

A small program starts a sound and then calls snd_update in a loop, with
a random amount of other work between calls (up to most of a frame), or
once per frame after wait_frames.  The test plays the buffer the way the
video circuit does, one byte per line (the read 144 clocks into line V,
from x5C00 + V), and checks that what comes out is exactly the stream a
Python model of each sound makes: no sample lost, repeated or out of
order, and the sound stops on the right frame.

Date: 10/18/2026
"""

import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402

ARG_AC, DELAY, MODE = 0x20, 0x21, 0x22
LINE, FRAME = 800, 800 * 525
BUF0, BUF1 = 0x5DF3, 0x6000


def call(target, n):
    back = 'back_%d' % n
    return ['    ld   LINK_LO, x',
            '    ld   %s, [x]' % back,
            '    ld   LINK_HI, x',
            '    ld   %s >> 8, [x]' % back,
            '    ld   %s >> 8, y' % target,
            '    jmp  %s' % target,
            back + ':']


ROUTINES = ['snd_init', 'snd_tone', 'snd_noise', 'snd_play', 'snd_beep',
            'snd_note', 'snd_stop', 'snd_busy', 'snd_update']


def build_source():
    src = ['#include "placard.asm"', '#include "placard_lib.asm"', '',
           '#addr 0x0000', 'reset:', '    ld   main >> 8, y', '    jmp  main', '',
           '#addr 0x0100', 'main:', '    bra  main']
    n = 0
    for i, r in enumerate(ROUTINES):
        if i % 6 == 0:
            src.append('#addr 0x%04X' % (0x0200 + (i // 6) * 0x100))
        src.append('drv_%s:' % r)
        src.append('    ld   [0x%02X], ac' % ARG_AC)
        src += call(r, n)
        n += 1
        src += ['    ld   ac, [0x%02X]' % ARG_AC, 'halt_%s:' % r, '    bra  halt_%s' % r]
    # the player loop: MODE 0 = random work (DELAY x 256 x 7 clocks) then
    # snd_update; MODE 1 = wait_frames(1) then snd_update
    src += ['#addr 0x0500', 'loop:',
            '    ld   [0x%02X], ac' % MODE,
            '    bne  lp_frame',
            '    ld   [0x%02X], ac' % DELAY,
            '    beq  lp_upd',
            'lp_out:',
            '    clr  ac',
            'lp_in:',
            '    dec',
            '    bne  lp_in',
            '    ld   [0x%02X], ac' % DELAY,
            '    dec',
            '    ld   ac, [0x%02X]' % DELAY,
            '    bne  lp_out',
            '    bra  lp_upd',
            'lp_frame:',
            '    ld   1, ac']
    src += call('wait_frames', n)
    n += 1
    src += ['lp_upd:']
    src += call('snd_update', n)
    src += ['    ld   loop >> 8, y', '    jmp  loop']
    return '\n'.join(src) + '\n'


class Rig:
    def __init__(self, seed=1):
        self.mem, self.syms, _ = ps.assemble(build_source(), HERE)
        self.cpu = ps.Cpu(self.mem)
        self.cpu.mem[self.syms['SP']] = 0xFF
        self.rnd = random.Random(seed)
        self.out = []           # (slot, value) as played
        self.next_line = 0
        self.call('snd_init')

    def sym(self, n):
        return self.syms[n]

    def zp(self, n):
        return self.cpu.mem[self.syms[n]]

    def set(self, **kw):
        for k, v in kw.items():
            self.cpu.mem[self.syms[k]] = v & 0xFF

    def play_to(self, t):
        cpu = self.cpu
        while (self.next_line * LINE + 144) <= t:
            v = 499 + self.next_line % 525
            slot = 0x5C00 + v
            self.out.append((slot, cpu.mem[slot]))
            self.next_line += 1

    def call(self, name, ac=0):
        cpu = self.cpu
        cpu.mem[ARG_AC] = ac
        cpu.pc = self.sym('drv_' + name)
        stop = self.sym('halt_' + name)
        c0 = cpu.clocks
        while cpu.pc != stop:
            cpu.step()
            self.play_to(cpu.clocks)
            assert cpu.clocks - c0 < 2 * FRAME, '%s did not return' % name
        self.clocks = cpu.clocks - c0
        return cpu.mem[ARG_AC]

    def run(self, frames, mode=0, max_delay=150):
        """the player loop for a number of frames; returns the clocks spent
        in snd_update per frame, on average"""
        cpu = self.cpu
        cpu.mem[MODE] = mode
        cpu.pc = self.sym('loop')
        loop, upd = self.sym('loop'), self.sym('snd_update')
        end = cpu.clocks + frames * FRAME
        spent = t_upd = 0
        while cpu.clocks < end:
            if cpu.pc == loop:
                cpu.mem[DELAY] = self.rnd.randint(0, max_delay)
                if t_upd:
                    spent += cpu.clocks - t_upd - 21    # less the return jmp
                    t_upd = 0
            elif cpu.pc == upd:
                t_upd = cpu.clocks
            cpu.step()
            self.play_to(cpu.clocks)
        return spent // max(frames, 1)


# ---------------------------------------------------------------------------
# models of the sounds, sample by sample, with the per-lap work
# ---------------------------------------------------------------------------
class Model:
    def __init__(self, slot, vol, frames, decay):
        self.slot = slot
        self.vol, self.frames, self.decay = vol, frames, decay
        self.on = True

    def levels(self):
        return (0x80 + self.vol) & 0xFF, (0x80 - self.vol) & 0xFF

    def lap(self):
        if not self.on:
            return
        if self.frames:
            self.frames -= 1
            if self.frames == 0:
                self.on = False
                return
        if self.decay:
            v = self.vol - self.decay
            if v <= 0:
                self.on = False
            else:
                self.vol = v

    def stream(self, n):
        out = []
        for _ in range(n):
            out.append(self.sample() if self.on else 0x80)
            self.slot += 1
            if self.slot == BUF1:
                self.slot = BUF0
                self.lap()
        return out


class Tone(Model):
    def __init__(self, slot, step, vol, frames=0, decay=0):
        Model.__init__(self, slot, vol, frames, decay)
        self.inl, self.inh = step & 0x7F, (step >> 7) & 0xFF
        self.acl = self.ach = 0

    def sample(self):
        self.acl += self.inl
        if self.acl & 0x80:
            self.acl &= 0x7F
            self.ach = (self.ach + self.inh + 1) & 0xFF
        else:
            self.ach = (self.ach + self.inh) & 0xFF
        hi, lo = self.levels()
        return hi if self.ach & 0x80 else lo


class Noise(Model):
    def __init__(self, slot, rate, vol, frames=0, decay=0):
        Model.__init__(self, slot, vol, frames, decay)
        self.rate, self.acl, self.lfsr = rate, 0, 0xACE1

    def sample(self):
        self.acl += self.rate
        if self.acl & 0x80:
            self.acl &= 0x7F
            b = self.lfsr & 1
            self.lfsr >>= 1
            if b:
                self.lfsr ^= 0xB400
        hi, lo = self.levels()
        return hi if self.lfsr & 1 else lo


class Samples(Model):
    def __init__(self, slot, data, rate):
        Model.__init__(self, slot, 0, 0, 0)
        self.data, self.rate, self.acl, self.i = data, rate, 0, 0

    def sample(self):
        v = self.data[self.i]
        self.acl += self.rate
        if self.acl & 0x80:
            self.acl &= 0x7F
            self.i += 1
            if self.i == len(self.data):
                self.on = False
        return v


def check(rig, model_of, n):
    """compare the played stream from the first non-silent sample with the
    model started at that sample's slot"""
    vals = [v for _, v in rig.out]
    i0 = next((i for i, v in enumerate(vals) if v != 0x80), None)
    assert i0 is not None, 'no sound came out'
    got = vals[i0:i0 + n]
    assert len(got) == n, 'only %d samples played' % len(got)
    want = model_of(rig.out[i0][0]).stream(n)
    for k, (g, w) in enumerate(zip(got, want)):
        assert g == w, 'sample %d (slot %04X): %02X, want %02X' % (
            k, rig.out[i0 + k][0], g, w)
    return i0


def start_tone(rig, step, vol, frames=0, decay=0):
    rig.cpu.mem[rig.sym('R0')] = step & 0xFF
    rig.cpu.mem[rig.sym('R1')] = step >> 8
    rig.cpu.mem[rig.sym('R2')] = frames
    rig.cpu.mem[rig.sym('R3')] = decay
    rig.call('snd_tone', vol)


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------
def test_silence():
    rig = Rig()
    per = rig.run(3, mode=1)
    assert all(v == 0x80 for _, v in rig.out)
    assert rig.call('snd_busy') == 0
    return 'silence: snd_update %d clocks per frame' % per


def test_tone_random_calls():
    out = []
    for seed in range(3):
        rig = Rig(seed)
        rig.run(1)
        step = 440 * 32768 // 31469
        start_tone(rig, step, 100)
        assert rig.call('snd_busy') != 0
        rig.run(8)
        check(rig, lambda s: Tone(s, step, 100), 5 * 525)
    return 'A 440 Hz, update at random times: exact for 5 frames'


def test_tone_once_per_frame():
    rig = Rig()
    rig.run(1, mode=1)
    step = 1000
    start_tone(rig, step, 60)
    t0 = rig.cpu.clocks
    rig.run(8, mode=1)
    check(rig, lambda s: Tone(s, step, 60), 6 * 525)
    return 'update after wait_frames(1): exact for 6 frames'


def test_tone_frames_and_decay():
    for frames, decay in ((5, 0), (0, 30), (4, 20)):
        rig = Rig(frames)
        rig.run(1)
        start_tone(rig, 3000, 100, frames, decay)
        rig.run(9)
        check(rig, lambda s: Tone(s, 3000, 100, frames, decay), 7 * 525)
        assert rig.call('snd_busy') == 0
    return 'stops after its frames, fades by its step'


def test_noise():
    for rate in (128, 37, 5):
        rig = Rig(rate)
        rig.run(1)
        rig.cpu.mem[rig.sym('R0')] = rate
        rig.cpu.mem[rig.sym('R2')] = 0
        rig.cpu.mem[rig.sym('R3')] = 25
        rig.call('snd_noise', 120)
        rig.run(8)
        check(rig, lambda s: Noise(s, rate, 120, 0, 25), 6 * 525)
    return 'rates 128, 37, 5 with a fade'


def test_samples():
    rnd = random.Random(5)
    data = [rnd.randint(1, 255) for _ in range(1500)]
    data[0] = 0x10                    # not silence, to find the start
    for rate in (128, 64, 33):
        rig = Rig(rate)
        for i, v in enumerate(data):
            rig.cpu.mem[0x7000 + i] = v
        rig.run(1)
        m = rig.cpu.mem
        m[rig.sym('R0')], m[rig.sym('R1')] = 0x00, 0x70
        m[rig.sym('R2')], m[rig.sym('R3')] = len(data) & 0xFF, len(data) >> 8
        rig.call('snd_play', rate)
        frames = len(data) * 128 // rate // 525 + 3
        rig.run(frames)
        n = len(data) * 128 // rate + 600
        check(rig, lambda s: Samples(s, data, rate), n)
        assert rig.call('snd_busy') == 0
    return '1500 samples at rates 128, 64, 33, then silence'


def test_beep_and_note():
    rig = Rig()
    rig.call('snd_note', 69)
    step = rig.zp('R0') | rig.zp('R1') << 8
    assert step == round(440 * 32768 / 31469), step
    rig.run(1)
    rig.call('snd_beep', 81)
    step = rig.zp('R0') | rig.zp('R1') << 8
    rig.run(16)
    check(rig, lambda s: Tone(s, step, 96, 12, 8), 14 * 525)
    return 'note 69 = step %d; beep plays and ends' % round(440 * 32768 / 31469)


def test_stop_and_cost():
    rig = Rig()
    rig.run(1, mode=1)
    start_tone(rig, 2000, 50)
    rig.run(1, mode=1)
    tone = rig.run(3, mode=1)
    rig.call('snd_stop')
    assert rig.call('snd_busy') == 0
    rig.run(3, mode=1)
    tail = [v for _, v in rig.out[-525:]]
    assert all(v == 0x80 for v in tail), 'not silent after snd_stop'
    data = [0x40] * 3000
    m = rig.cpu.mem
    m[rig.sym('R0')], m[rig.sym('R1')] = 0x00, 0x70
    m[rig.sym('R2')], m[rig.sym('R3')] = len(data) & 0xFF, len(data) >> 8
    rig.call('snd_play', 128)
    samp = rig.run(3, mode=1)
    m[rig.sym('R0')], m[rig.sym('R2')], m[rig.sym('R3')] = 128, 0, 0
    rig.call('snd_noise', 50)
    noise = rig.run(3, mode=1)
    return ('snd_update per frame, with its wait for the line: tone %d, noise %d, '
            'samples %d clocks (of %d)' % (tone, noise, samp, FRAME))


TESTS = [(n, f) for n, f in sorted(globals().items()) if n.startswith('test_')]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-k', default='')
    args = ap.parse_args(argv)
    bad = 0
    for name, f in TESTS:
        if args.k not in name:
            continue
        try:
            note = f()
            print('ok    %-28s %s' % (name, note or ''))
        except AssertionError as e:
            bad += 1
            print('FAIL  %-28s %s' % (name, e))
    print('%d failed' % bad if bad else 'all passed')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
