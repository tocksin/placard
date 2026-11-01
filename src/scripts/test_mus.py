#!/usr/bin/env python3
"""
test_mus.py - test the music player (placard_mus.masm) in the simulator

    python3 test_mus.py              run every test
    python3 test_mus.py -k sfx       run the tests whose name contains "sfx"
    python3 test_mus.py --cpu        also print the CPU time the player takes

A small program plays a song (src/music/*.mus, built with mus_tool.py)
and calls mus_frame in a loop, with a random amount of other work between
calls (up to most of a frame) or once a frame.  The test plays the buffer
the way the video circuit does, one byte per line (the read 144 clocks
into line V, from x5C00 + V), with the video stall clocks modeled, and
checks that what comes out is exactly what mus_tool.Model makes, sample
for sample: no sample lost, repeated or out of order, every tick on its
line.

Date: 11/01/2026
"""

import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import asm_expand           # noqa: E402
import mus_tool             # noqa: E402

ARG_AC, ARG_R0, ARG_R1, DELAY, MODE = 0x20, 0x21, 0x22, 0x23, 0x24
LINE, FRAME = 800, 800 * 525
SONG = 0x2000                  # the song's page in the test program
MUSIC = os.path.join(HERE, '..', 'music')

ROUTINES = ['mus_init', 'mus_play', 'mus_frame', 'mus_stop', 'mus_sfx']


def build_source():
    src = ['#include "placard.asm"', '#include "placard_lib.asm"', '',
           'MUS_TABLES = 0x3400', 'MUS_RAM    = 0x4000', '',
           '.fixed 0x0000', 'reset:', '    ld   main >> 8, y', '    jmp  main', '',
           '.region 0x0100, 0x2000', '.prefix tm']
    src += ['.chunk', 'main:', '    bra  main']
    for r in ROUTINES:
        src += ['.chunk', 'drv_%s:' % r,
                '    ld   [0x%02X], ac' % ARG_R0, '    ld   ac, [R0]',
                '    ld   [0x%02X], ac' % ARG_R1, '    ld   ac, [R1]',
                '    ld   [0x%02X], ac' % ARG_AC,
                '    CALL %s' % r,
                '    ld   ac, [0x%02X]' % ARG_AC,
                'halt_%s:' % r, '    bra  halt_%s' % r]
    # the loop: MODE 0 = random work (DELAY x 256 x 7 clocks) then
    # mus_frame; MODE 1 = wait_frames(1) then mus_frame
    src += ['.chunk', 'loop:',
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
            '    ld   1, ac',
            '    CALL wait_frames',
            'lp_upd:',
            '    CALL mus_frame',
            'lp_top:',
            '    ld   loop >> 8, y', '    jmp  loop']
    src += ['', '.include "placard_mus.masm"']
    return '\n'.join(src) + '\n'


def assemble():
    name = os.path.join(HERE, 'test_mus.masm')     # for .include paths; not written
    head, chunks = asm_expand.expand(build_source(), name)
    asm_expand.place(chunks, name)
    text = asm_expand.render(head, chunks, name)
    mem, syms, _ = ps.assemble(text, HERE)
    return mem, syms, chunks


_BUILT = None


class Rig:
    def __init__(self, song, seed=1):
        global _BUILT
        if _BUILT is None:
            _BUILT = assemble()
        mem, self.syms, self.chunks = _BUILT
        self.cpu = ps.Cpu(mem)
        self.cpu.stalls = True
        self.cpu.mem[self.syms['SP']] = 0xFF
        for i, b in enumerate(song):
            self.cpu.mem[SONG + i] = b
        self.rnd = random.Random(seed)
        self.out = []           # (address, value) as played
        self.next_line = 0
        self.frame_clocks = []
        self.ticks = 0          # ticks played by run()

    def sym(self, n):
        return self.syms[n]

    def play_to(self, t):
        cpu = self.cpu
        while (self.next_line * LINE + 144) <= t:
            ad = 0x5C00 + 499 + self.next_line % 525
            self.out.append((ad, cpu.mem[ad]))
            self.next_line += 1

    def call(self, name, ac=0, r0=0, r1=0):
        cpu = self.cpu
        cpu.mem[ARG_AC], cpu.mem[ARG_R0], cpu.mem[ARG_R1] = ac, r0, r1
        cpu.pc = self.sym('drv_' + name)
        stop = self.sym('halt_' + name)
        c0 = cpu.clocks
        while cpu.pc != stop:
            cpu.step()
            self.play_to(cpu.clocks)
            assert cpu.clocks - c0 < 2 * FRAME, '%s did not return' % name
        self.clocks = cpu.clocks - c0
        return cpu.mem[ARG_AC]

    def run(self, frames, mode=0, max_delay=150, until=None):
        """the loop for a number of frames; the clocks of each mus_frame
        call go in frame_clocks"""
        cpu = self.cpu
        cpu.mem[MODE] = mode
        cpu.pc = self.sym('loop')
        loop, upd, top = self.sym('loop'), self.sym('lp_upd'), self.sym('lp_top')
        tick = self.sym('mus_tick')
        end = cpu.clocks + frames * FRAME
        t_upd = None
        while cpu.clocks < end or cpu.pc != loop:    # stop at the top of the loop
            if cpu.pc == loop:
                cpu.mem[DELAY] = self.rnd.randint(0, max_delay)
            elif cpu.pc == upd:
                t_upd = cpu.clocks
            elif cpu.pc == top and t_upd is not None:
                self.frame_clocks.append(cpu.clocks - t_upd)
                t_upd = None
            elif cpu.pc == tick:
                self.ticks += 1
            cpu.step()
            self.play_to(cpu.clocks)


def song_bytes(name='demo.mus'):
    return mus_tool.parse_mus(open(os.path.join(MUSIC, name)).read()).binary()


def played(rig, start):
    """the values played from the first lap with sound after line `start`:
    what mus_frame writes is heard a lap later, and the silent lap or two
    before the first tick is heard are the x80 fill of mus_init"""
    out = rig.out[start:]
    for i, (ad, _) in enumerate(out):
        if ad == 0x5DF3:
            vals = [v for _, v in out[i:]]
            break
    else:
        return []
    for i, v in enumerate(vals):
        if v != 0x80:
            return vals[i - i % 525:]
    return []


def compare(got, want, what):
    n = min(len(got), len(want))
    for i in range(n):
        if got[i] != want[i]:
            lo = max(0, i - 4)
            raise AssertionError('%s: sample %d (lap %d, line %d) is %d, model %d\n'
                                 '  got   %s\n  model %s'
                                 % (what, i, i // 525, i % 525, got[i], want[i],
                                    got[lo:i + 6], want[lo:i + 6]))
    return n


def start(song, sub=0, seed=1):
    rig = Rig(song, seed)
    rig.call('mus_init', r1=SONG >> 8)
    rig.call('mus_play', ac=sub)
    m = mus_tool.Model(song)
    m.play(sub)
    return rig, m


def check_run(frames, mode, max_delay=150, seed=1, song=None, sub=0, between=None):
    """play for a number of frames and compare with the model; between(rig, m)
    is called halfway, after the same tick in both (a call on the player, the
    same on the model)"""
    song = song or song_bytes()
    rig, m = start(song, sub, seed)
    line0 = len(rig.out)
    want = []
    if between:
        rig.run(frames // 2, mode, max_delay)
        want = m.samples(rig.ticks * 525)       # the model up to the same tick
        between(rig, m)
        frames -= frames // 2
    rig.run(frames, mode, max_delay)
    got = played(rig, line0)
    got = got[:len(got) - 2 * 525]       # the last laps may not be written yet
    want += m.samples(len(got) - len(want))
    n = compare(got, want, 'mode %d' % mode)
    assert n > (frames - 4) * 525, 'only %d samples played' % n
    return rig


def test_demo_random_calls():
    check_run(60, 0)


def test_demo_once_per_frame():
    check_run(60, 1)


def test_demo_busy_program():
    check_run(40, 0, max_delay=180, seed=7)


def test_stop():
    def stop(rig, m):
        rig.call('mus_stop')
        m.stop()
    rig = check_run(50, 1, between=stop)
    rig.run(100, 1)                 # the longest release playing (1.5 s) ends
    tail = [v for _, v in rig.out[-525:]]
    assert len(set(tail)) == 1, 'not silent after mus_stop: %s' % tail[:20]


def test_sfx():
    def sfx(rig, m):
        rig.call('mus_sfx', ac=48, r0=1, r1=20)
        m.sfx(48, 1, 20)
    check_run(50, 0, between=sfx)


def test_sfx_once_per_frame():
    def sfx(rig, m):
        rig.call('mus_sfx', ac=60, r0=2, r1=8)
        m.sfx(60, 2, 8)
    check_run(30, 1, between=sfx)


TESTS = [v for k, v in sorted(globals().items()) if k.startswith('test_')]


def cpu_report():
    song = song_bytes()
    rig, _ = start(song)
    rig.run(120, 1)
    fc = rig.frame_clocks[2:]
    avg = sum(fc) / len(fc)
    print('mus_frame: %d calls, %.0f clocks a frame on average (%.1f%% of a frame), max %d'
          % (len(fc), avg, 100.0 * avg / FRAME, max(fc)))
    code = sum(c.size for c in rig.chunks if c.region)
    print('player + test code: %d bytes' % code)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-k', default='')
    ap.add_argument('--cpu', action='store_true')
    a = ap.parse_args(argv)
    bad = 0
    for t in TESTS:
        if a.k not in t.__name__:
            continue
        try:
            t()
            print('ok    %s' % t.__name__)
        except AssertionError as ex:
            bad += 1
            print('FAIL  %s: %s' % (t.__name__, ex))
    if a.cpu:
        cpu_report()
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
