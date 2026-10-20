#!/usr/bin/env python3
"""
test_io.py - test the I/O drivers (placard_io.asm) in the simulator

    python3 test_io.py              run every test
    python3 test_io.py -k sd        run the tests whose name contains "sd"

Each routine is called through the standard CALL sequence from a small
driver, as test_lib.py does, with the shared port modeled by io_devices.py:
the key matrix, two SNES pads, an SD card and a PS/2 mouse.  Besides the
results, the tests check the port rules from docs/IO.md: every routine leaves
the latch at rest (P_IDLE, FB), and /CS (which also frees the PS/2 clock)
is never high for 50 us or more at a time, so the mouse can't start
sending while nobody listens.
It also checks con_gets (line input) and mouse_move (placard_input.asm).

Date: 10/19/2026
"""

import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import io_devices as iod    # noqa: E402

ROUTINES = ['port_init', 'kbd_scan', 'kbd_getc', 'kbd_key', 'pad_read',
            'spi_byte', 'sd_init', 'sd_read', 'sd_write', 'mouse_init', 'mouse_poll',
            'con_clear', 'con_gets', 'mouse_move']
ARG_AC, OUT_AC, OUT_X = 0x20, 0x21, 0x22
P_IDLE = 0xFB
CS_LIMIT = iod.us(50)


def call(target, n):
    back = 'back_%d' % n
    return ['    ld   LINK_LO, x',
            '    ld   %s, [x]' % back,
            '    ld   LINK_HI, x',
            '    ld   %s >> 8, [x]' % back,
            '    ld   %s >> 8, y' % target,
            '    jmp  %s' % target,
            back + ':']


def build_source():
    src = ['#include "placard.asm"', '#include "placard_lib.asm"', '',
           '#addr 0x0000', 'reset:', '    ld   main >> 8, y', '    jmp  main', '',
           '#addr 0x0100', 'main:', '    bra  main']
    for n, r in enumerate(ROUTINES):
        if n % 6 == 0:
            src.append('#addr 0x%04X' % (0x0200 + (n // 6) * 0x100))
        src.append('drv_%s:' % r)
        src.append('    ld   [0x%02X], ac' % ARG_AC)
        src += call(r, n)
        src += ['    ld   ac, [0x%02X]' % OUT_AC,
                'halt_%s:' % r,
                '    bra  halt_%s' % r]
    return '\n'.join(src) + '\n'


class LoggingPort(iod.SharedPort):
    """the shared port, also timing how long /CS stays high"""

    def __init__(self):
        iod.SharedPort.__init__(self)
        self.cs_high_at = None
        self.cs_longest = 0

    def write(self, ad, v, t):
        cs_was = (self.latch >> 2) & 1
        iod.SharedPort.write(self, ad, v, t)
        cs = (v >> 2) & 1
        if cs and not cs_was:
            self.cs_high_at = t
        elif cs_was and not cs and self.cs_high_at is not None:
            self.cs_longest = max(self.cs_longest, t - self.cs_high_at)
            self.cs_high_at = None


class Rig:
    def __init__(self):
        self.mem, self.syms, _ = ps.assemble(build_source(), HERE)
        self.port = LoggingPort()
        self.cpu = ps.Cpu(self.mem, io=self.port)
        self.cpu.mem[self.syms['SP']] = 0xFF
        self.call('port_init')

    def call(self, name, ac=0, max_steps=3_000_000, check_rest=True):
        cpu = self.cpu
        self.port.cs_longest = 0
        cpu.mem[ARG_AC] = ac
        cpu.pc = self.syms['drv_' + name]
        sp = cpu.mem[self.syms['SP']]
        c0 = cpu.clocks
        r = cpu.run(max_steps, halt_detect=False, stop_pc=self.syms['halt_' + name])
        assert r == 'stop', '%s did not return (%s, PC=%04X)' % (name, r, cpu.pc)
        assert cpu.mem[self.syms['SP']] == sp, '%s moved SP' % name
        if check_rest:
            assert self.port.latch == P_IDLE, '%s left the latch at %02X' % (name, self.port.latch)
            # sd_init is the one exception (the card's start clocks), and
            # the mouse routines, which listen to the mouse while /CS is high
            assert name == 'sd_init' or name.startswith('mouse') or \
                self.port.cs_longest < CS_LIMIT, \
                '%s held /CS high for %d clocks' % (name, self.port.cs_longest)
        self.clocks = cpu.clocks - c0
        return cpu.mem[OUT_AC]

    def zp(self, name):
        return self.cpu.mem[self.syms[name]]


# ---------------------------------------------------------------------------
# keyboard
# ---------------------------------------------------------------------------
# key number (column * 8 + row) -> (character, shifted character)
KEYS = ("\x1b1234567" "890-=\x08\tq" "wertyuio" "p[]\\\x00asd"
        "fghjkl;'" "\n\x00zxcvbn" "m,./\x00\x11\x00\x00" "`\x00 \x7f\x15\x13\x12\x14")
KEYS_SH = ("\x1b!@#$%^&" "*()_+\x08\tQ" "WERTYUIO" "P{}|\x00ASD"
           "FGHJKL:\"" "\n\x00ZXCVBN" "M<>?\x00\x11\x00\x00" "~\x00 \x7f\x15\x13\x12\x14")
K_CTRL, K_LSHIFT, K_RSHIFT, K_CAPS = 28, 41, 52, 54


def key(k):
    return (k >> 3, k & 7)


def drain(rig):
    out = ''
    while True:
        c = rig.call('kbd_getc')
        if c == 0:
            return out
        out += chr(c)


def test_kbd_every_key():
    rig = Rig()
    worst = cs_worst = 0
    for k in range(64):
        rig.port.keys = {key(k)}
        rig.call('kbd_scan')
        worst = max(worst, rig.clocks)
        cs_worst = max(cs_worst, rig.port.cs_longest)
        rig.port.keys = set()
        rig.call('kbd_scan')
        got = drain(rig)
        want = KEYS[k].replace('\x00', '')
        if k == K_CAPS:
            want = ''
            rig.port.keys = {key(k)}            # turn caps lock off again
            rig.call('kbd_scan')
            rig.port.keys = set()
            rig.call('kbd_scan')
        assert got == want, 'key %d: %r, want %r' % (k, got, want)
    return 'scan with one new key %d clocks; /CS high at most %d clocks (%.1f us)' % (
        worst, cs_worst, cs_worst / 25.175)


def test_kbd_idle_scan():
    rig = Rig()
    rig.call('kbd_scan')
    clocks = rig.clocks
    assert drain(rig) == ''
    assert all(rig.cpu.mem[0xA0 + c] == 0xFF for c in range(8))
    return 'scan with no key %d clocks' % clocks


def test_kbd_shift_ctrl_caps():
    rig = Rig()
    for sh in (K_LSHIFT, K_RSHIFT):
        for k in range(64):
            if k in (K_LSHIFT, K_RSHIFT, K_CAPS, K_CTRL):
                continue
            rig.port.keys = {key(sh)}
            rig.call('kbd_scan')
            rig.port.keys = {key(sh), key(k)}
            rig.call('kbd_scan')
            rig.port.keys = set()
            rig.call('kbd_scan')
            got = drain(rig)
            assert got == KEYS_SH[k].replace('\x00', ''), 'shift+%d: %r' % (k, got)
    # Ctrl: control codes
    rig.port.keys = {key(K_CTRL)}
    rig.call('kbd_scan')
    rig.port.keys = {key(K_CTRL), key(44)}      # c
    rig.call('kbd_scan')
    rig.port.keys = set()
    rig.call('kbd_scan')
    assert drain(rig) == '\x03'
    # Caps Lock: letters only
    for k in (K_CAPS, 29, 1, K_CAPS, 29):       # caps on, a, 1, caps off, a
        rig.port.keys = {key(k)}
        rig.call('kbd_scan')
        rig.port.keys = set()
        rig.call('kbd_scan')
    assert drain(rig) == 'A1a'
    # caps lock and Shift together give lower case
    for keys in ({key(K_CAPS)}, set(), {key(K_LSHIFT)}, {key(K_LSHIFT), key(29)}, set(),
                 {key(K_CAPS)}, set()):
        rig.port.keys = keys
        rig.call('kbd_scan')
    assert drain(rig) == 'a'


def test_kbd_held_rollover_buffer():
    rig = Rig()
    # a held key gives one character
    rig.port.keys = {key(29)}
    for _ in range(5):
        rig.call('kbd_scan')
    assert drain(rig) == 'a'
    # several new keys in one scan, all columns
    rig.port.keys = {key(k) for k in (1, 15, 16, 31, 32, 48, 58)}
    rig.call('kbd_scan')
    assert drain(rig) == '1qwdfm '
    # the buffer holds 7, the rest are dropped
    rig.port.keys = set()
    rig.call('kbd_scan')
    rig.port.keys = {key(k) for k in range(1, 11)}   # 1-9, 0
    rig.call('kbd_scan')
    assert drain(rig) == '1234567'
    # KBD_NOW shows held keys
    rig.port.keys = {key(29), key(63)}
    rig.call('kbd_scan')
    now = [rig.cpu.mem[0xA0 + c] for c in range(8)]
    want = [0xFF] * 8
    want[3] &= ~(1 << 5)
    want[7] &= ~(1 << 7)
    assert now == want, now


def test_kbd_key_direct():
    rig = Rig()
    rig.call('kbd_key', 29)
    rig.call('kbd_key', 1)
    assert drain(rig) == 'a1'


# ---------------------------------------------------------------------------
# pads
# ---------------------------------------------------------------------------
def test_pad_read():
    rig = Rig()
    rnd = random.Random(5)
    for i in range(60):
        b1, b2 = rnd.getrandbits(12), rnd.getrandbits(12)
        rig.port.pads[0].buttons = b1
        rig.port.pads[1].buttons = b2
        rig.call('pad_read')
        m = rig.cpu.mem
        got1 = m[0x10] | m[0x11] << 8
        got2 = m[0x12] | m[0x13] << 8
        assert (got1, got2) == (b1, b2), '%03X %03X -> %04X %04X' % (b1, b2, got1, got2)
    clocks = rig.clocks
    rig.port.pads[1].connected = False
    rig.port.pads[0].buttons = 0x0801
    rig.call('pad_read')
    m = rig.cpu.mem
    assert (m[0x10] | m[0x11] << 8, m[0x12] | m[0x13] << 8) == (0x0801, 0)
    return 'pad_read %d clocks; /CS high at most %.1f us' % (clocks, rig.port.cs_longest / 25.175)


# ---------------------------------------------------------------------------
# SD card
# ---------------------------------------------------------------------------
def card_image(blocks=64, seed=1):
    rnd = random.Random(seed)
    return bytearray(rnd.getrandbits(8) for _ in range(512 * blocks))


def set_block(rig, block, buf):
    m = rig.cpu.mem
    for i in range(4):
        m[0x10 + i] = (block >> (8 * i)) & 0xFF
    m[0x14], m[0x15] = buf & 0xFF, buf >> 8


def test_sd_no_card():
    rig = Rig()
    ac = rig.call('sd_init')
    assert ac == 1, ac
    return 'start clocks: /CS high %.0f us' % (rig.port.cs_longest / iod.CPU_HZ * 1e6)


def test_sd_init_types():
    out = []
    for sdhc in (True, False):
        rig = Rig()
        rig.port.sd = iod.SdCard(card_image(), sdhc=sdhc, acmd41_busy=5)
        ac = rig.call('sd_init')
        assert ac == 0, 'sd_init %d (%s)' % (ac, rig.port.sd.log)
        assert rig.zp('SD_FLAGS') == (0x81 if sdhc else 0x80), hex(rig.zp('SD_FLAGS'))
        assert rig.port.sd.pre_clocks >= 74
        # the start clocks run below 400 kHz
        assert rig.port.cs_longest >= rig.port.sd.pre_clocks * iod.us(2.5), rig.port.cs_longest
        out.append('%s %d clocks' % ('SDHC' if sdhc else 'SDSC', rig.clocks))
    return 'sd_init: ' + ', '.join(out)


def test_sd_read_write():
    out = []
    for sdhc in (True, False):
        img = card_image(seed=7)
        rig = Rig()
        rig.port.sd = iod.SdCard(img, sdhc=sdhc, acmd41_busy=1)
        assert rig.call('sd_init') == 0
        for block in (0, 3, 63):
            set_block(rig, block, 0x0400)
            ac = rig.call('sd_read')
            assert ac == 0, 'sd_read %d' % ac
            got = bytes(rig.cpu.mem[0x0400:0x0600])
            assert got == bytes(img[block * 512:block * 512 + 512]), 'block %d differs' % block
            m = rig.cpu.mem
            assert (m[0x14], m[0x15]) == (0x00, 0x06)
        rd = rig.clocks
        data = bytes(random.Random(block).getrandbits(8) for _ in range(512))
        rig.cpu.mem[0x0800:0x0A00] = data
        set_block(rig, 5, 0x0800)
        ac = rig.call('sd_write')
        assert ac == 0, 'sd_write %d' % ac
        assert bytes(img[5 * 512:6 * 512]) == data
        out.append('%s read %d, write %d clocks' % ('SDHC' if sdhc else 'SDSC', rd, rig.clocks))
        # out of range: the card refuses the command
        set_block(rig, 64, 0x0400)
        assert rig.call('sd_read') == 4
    return ', '.join(out)


# ---------------------------------------------------------------------------
# PS/2 mouse
# ---------------------------------------------------------------------------
def signed(v):
    return v - 256 if v & 0x80 else v


def mouse_rig(**kw):
    rig = Rig()
    rig.port.mouse = iod.Ps2Mouse(bat_ms=50, **kw)
    ac = rig.call('mouse_init', max_steps=20_000_000)
    assert ac == 0, 'mouse_init %d (got %s)' % (ac, rig.port.mouse.received)
    return rig


def poll(rig):
    rig.cpu.clocks += iod.us(16_700)             # a frame of other work
    ac = rig.call('mouse_poll')
    m = rig.cpu.mem
    return ac, m[0xB5], signed(m[0xB6]), signed(m[0xB7])


def test_mouse_none():
    rig = Rig()
    assert rig.call('mouse_init') == 1
    assert rig.call('mouse_poll') == 0
    return 'no mouse: poll %d clocks' % rig.clocks


def test_mouse_init_poll():
    rig = mouse_rig()
    mouse = rig.port.mouse
    assert mouse.received == [0xFF, 0xF4], mouse.received
    assert rig.zp('MOUSE_ST') == 0x80
    assert mouse.reporting
    assert poll(rig)[0] == 0                     # nothing to report
    idle = rig.clocks
    cases = [((5, 3, 1), (1, 5, -3)), ((-7, -2, 2), (2, -7, 2)),
             ((0, 0, 4), (4, 0, 0)), ((127, -127, 0), (0, 127, 127)),
             ((-128, 128, 0), (0, -127, -127)), ((200, -300, 3), (3, 127, 127)),
             ((-300, 200, 0), (0, -127, -127))]
    worst = 0
    for (dx, dy, b), want in cases:
        mouse.move(dx, dy, b)
        got = poll(rig)
        assert got == (1,) + want, '%s -> %s' % ((dx, dy, b), got)
        worst = max(worst, rig.clocks)
        assert poll(rig)[0] == 0
    # movement adds up while the mouse is held off
    mouse.move(10, 0)
    rig.call('kbd_scan')
    mouse.move(10, -5)
    rig.call('pad_read')
    assert poll(rig) == (1, 0, 20, 5)
    assert mouse.aborts == 0, mouse.aborts
    return 'poll: %d clocks idle, %d with a packet' % (idle, worst)


def test_mouse_late_start():
    # mice that start sending near the end of the poll's 1 ms window
    out = []
    for lat in range(0, 900, 60):
        rig = mouse_rig(latency_us=lat)
        mouse = rig.port.mouse
        mouse.move(9, 9, 1)
        r = poll(rig)
        assert r == (1, 1, 9, -9), (lat, r)
        assert mouse.aborts == 0, (lat, mouse.aborts)
    return 'packets read with the mouse starting up to 0.84 ms late'


# ---------------------------------------------------------------------------
# line input and the mouse pointer (placard_input.asm)
# ---------------------------------------------------------------------------
def test_con_gets():
    rig = Rig()
    cpu, m = rig.cpu, rig.cpu.mem
    # as on the board: the library at xC000+ is ROM under the video RAM
    # that con_clear clears (map 05, sections 0 and 2 read RAM)
    cpu.rom = bytearray(m)
    cpu.map = 0x05
    rig.call('con_clear', max_steps=5_000_000)
    sy = rig.syms
    # typed: "Hi" Shift+h i, "x" then Backspace, "!" Shift+1, "abc" (one
    # too many for R2 = 4), Enter
    keys = {c: k for k, c in enumerate(KEYS) if c not in '\x00'}
    script = [{K_LSHIFT, keys['h']}, {keys['i']}, {keys['x']}, {keys['\x08']},
              {K_LSHIFT, keys['1']}, {keys['a']}, {keys['b']}, {keys['c']}, {keys['\n']}]
    frames = []
    for ks in script:
        frames += [{key(k) for k in ks}] * 2 + [set()] * 2
    m[sy['R0']], m[sy['R1']], m[sy['R2']] = 0x00, 0x07, 4
    m[ARG_AC] = 0
    cpu.pc = sy['drv_con_gets']
    stop = sy['halt_con_gets']
    frame = 800 * 525
    t0 = cpu.clocks
    while cpu.pc != stop:
        f = (cpu.clocks - t0) // frame
        rig.port.keys = frames[f] if f < len(frames) else set()
        cpu.step()
        assert f < len(frames) + 10, 'con_gets did not end'
    n = m[OUT_AC]
    got = bytes(m[0x0700:0x0700 + n + 1])
    assert got == b'Hi!a\0', got
    assert (m[sy['CUR_COL']], m[sy['CUR_ROW']]) == (0, 1), 'cursor %d,%d' % (
        m[sy['CUR_COL']], m[sy['CUR_ROW']])
    return 'typed Hi x <BS> ! abc <Enter> into 4 places: "Hi!a"'


def test_mouse_move():
    rig = Rig()
    m, sy = rig.cpu.mem, rig.syms
    cases = [((320, 240), (5, -7), (325, 233)), ((0, 0), (-3, -3), (0, 0)),
             ((637, 478), (9, 9), (639, 479)), ((250, 250), (10, 10), (260, 260)),
             ((5, 300), (-127, -127), (0, 173)), ((600, 100), (127, 127), (639, 227)),
             ((255, 255), (1, 1), (256, 256)), ((256, 256), (-1, -1), (255, 255)),
             ((520, 470), (127, 0), (639, 470))]
    for (x, y), (dx, dy), want in cases:
        m[sy['R0']], m[sy['R1']], m[sy['R2']], m[sy['R3']] = x & 255, x >> 8, y & 255, y >> 8
        m[sy['MOUSE_DX']], m[sy['MOUSE_DY']] = dx & 255, dy & 255
        rig.call('mouse_move')
        got = (m[sy['R0']] | m[sy['R1']] << 8, m[sy['R2']] | m[sy['R3']] << 8)
        assert got == want, '%s + %s: %s, want %s' % ((x, y), (dx, dy), got, want)
    return 'adds the packet, held to 0-639, 0-479 (%d clocks)' % rig.clocks


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
