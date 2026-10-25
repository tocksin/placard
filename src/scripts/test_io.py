#!/usr/bin/env python3
"""
test_io.py - test the I/O drivers (placard_io.asm) in the simulator

    python3 test_io.py              run every test
    python3 test_io.py -k sd        run the tests whose name contains "sd"

Each routine is called through the standard CALL sequence from a small
driver, as test_lib.py does, with the shared port modeled by io_devices.py:
the PS/2 receiver PLD, two SNES pads, an SD card, a PS/2 mouse and a PS/2
keyboard.  Besides the results, the tests check the port rules from
docs/IO.md: every routine leaves the latch at the value in PS2_LSN (the
listened device let go, the receiver armed), and a write that is not a
re-arm (x5200, x5201) never lifts /CS (the mouse's clock hold) or latch
bit 4 (the keyboard's) for 50 us or more, so a device can't start sending
into a receiver that isn't armed for it.  The keyboard (placard_ps2.asm)
is tested alone and with the mouse on the shared DATA line.
It also checks con_gets (line input) and mouse_move (placard_input.asm).

Date: 10/25/2026
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
            'con_clear', 'con_gets', 'mouse_move', 'wait_frames_io', 'ps2_poll']
ARG_AC, OUT_AC, OUT_X = 0x20, 0x21, 0x22
P_IDLE, P_FREE, P_KFREE = 0xEB, 0xEF, 0xFB
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
    """the shared port, also timing how long a write that is not a re-arm
    leaves /CS or latch bit 4 high"""

    def __init__(self):
        iod.SharedPort.__init__(self)
        self.cs_high_at = None
        self.cs_longest = 0
        self.k_high_at = None             # the same for latch bit 4
        self.k_longest = 0

    def write(self, ad, v, t):
        cs_was = (self.latch >> 2) & 1
        k_was = (self.latch >> 4) & 1
        iod.SharedPort.write(self, ad, v, t)
        if ad & 2:
            # a re-arm: the device is let go to send into the receiver
            self.cs_high_at = self.k_high_at = None
            return
        cs = (v >> 2) & 1
        if cs and not cs_was:
            self.cs_high_at = t
        elif cs_was and not cs and self.cs_high_at is not None:
            self.cs_longest = max(self.cs_longest, t - self.cs_high_at)
            self.cs_high_at = None
        k = (v >> 4) & 1
        if k and not k_was:
            self.k_high_at = t
        elif k_was and not k and self.k_high_at is not None:
            self.k_longest = max(self.k_longest, t - self.k_high_at)
            self.k_high_at = None


SOURCE = []


class Rig:
    def __init__(self, kbd=None, mouse=None):
        if not SOURCE:
            SOURCE.append(ps.assemble(build_source(), HERE))
        self.mem, self.syms, _ = SOURCE[0]
        self.port = LoggingPort()
        self.port.kbd = kbd
        self.port.mouse = mouse
        self.cpu = ps.Cpu(self.mem, io=self.port)
        self.cpu.mem[self.syms['SP']] = 0xFF
        self.init = self.call('port_init', max_steps=10_000_000)

    def call(self, name, ac=0, max_steps=3_000_000, check_rest=True):
        cpu = self.cpu
        self.port.cs_longest = 0
        self.port.k_longest = 0
        cpu.mem[ARG_AC] = ac
        cpu.pc = self.syms['drv_' + name]
        sp = cpu.mem[self.syms['SP']]
        c0 = cpu.clocks
        r = cpu.run(cpu.steps + max_steps, halt_detect=False, stop_pc=self.syms['halt_' + name])
        assert r == 'stop', '%s did not return (%s, PC=%04X)' % (name, r, cpu.pc)
        assert cpu.mem[self.syms['SP']] == sp, '%s moved SP' % name
        if check_rest:
            lsn = self.zp('PS2_LSN')
            assert lsn in (P_IDLE, P_FREE, P_KFREE), '%s left PS2_LSN at %02X' % (name, lsn)
            assert self.port.latch == lsn, '%s left the latch at %02X, PS2_LSN %02X' % (
                name, self.port.latch, lsn)
            # sd_init is the one exception (the card's start clocks)
            assert name == 'sd_init' or self.port.cs_longest < CS_LIMIT, \
                '%s held /CS high for %d clocks' % (name, self.port.cs_longest)
            assert self.port.k_longest < CS_LIMIT, \
                '%s let the PS/2 keyboard go for %d clocks' % (name, self.port.k_longest)
        self.clocks = cpu.clocks - c0
        return cpu.mem[OUT_AC]

    def zp(self, name):
        return self.cpu.mem[self.syms[name]]


# ---------------------------------------------------------------------------
# keyboard
# ---------------------------------------------------------------------------
# key number (column * 8 + row) -> (character, shifted character)
KEYS = ("\x1b1234567" "890-=\x08\tq" "wertyuio" "p[]\\\x00asd"
        "fghjkl;'" "\n\x00zxcvbn" "m,./\x00\x11\x00\x00" "\x00\x00 \x00\x00\x13\x12\x14")
KEYS_SH = ("\x1b!@#$%^&" "*()_+\x08\tQ" "WERTYUIO" "P{}|\x00ASD"
           "FGHJKL:\"" "\n\x00ZXCVBN" "M<>?\x00\x11\x00\x00" "\x00\x00 \x00\x00\x13\x12\x14")
K_CTRL, K_LSHIFT, K_RSHIFT, K_CAPS = 28, 41, 52, 54
K_FN, K_RCTRL, K_BKSP, K_LEFT, K_ESC = 55, 59, 13, 61, 0


def frame(rig, n=1):
    """n frames of other work: the time passes and FRAME_LO moves on, as
    frame_poll would"""
    for _ in range(n):
        rig.cpu.clocks += iod.us(16_700)
        rig.cpu.mem[rig.syms['FRAME_LO']] = (rig.cpu.mem[rig.syms['FRAME_LO']] + 1) & 0xFF


def drain(rig):
    out = ''
    while True:
        c = rig.call('kbd_getc')
        if c == 0:
            return out
        out += chr(c)


def test_kbd_idle_scan():
    rig = Rig()
    frame(rig)
    rig.call('kbd_scan')
    clocks = rig.clocks
    assert drain(rig) == ''
    assert all(rig.cpu.mem[0xA0 + c] == 0xFF for c in range(8))
    assert clocks < 400, clocks
    return 'kbd_scan with no keyboard %d clocks' % clocks


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


def test_pad_read_with_ps2():
    # the pads clock while a keyboard byte is half in and a mouse packet
    # waits: nothing is lost or garbled
    kb = iod.Ps2Keyboard()
    mouse = iod.Ps2Mouse(bat_ms=50)
    rig = Rig(kbd=kb, mouse=mouse)
    assert rig.call('mouse_init', max_steps=20_000_000) == 0
    codes = set2_codes(rig)
    rig.port.pads[0].buttons = 0x0123
    typed = ''
    moved = [0, 0]
    for i in range(12):
        if i % 4 == 0:
            kb.press(codes[29])
            kb.release(codes[29])
            mouse.move(3, -2)
        frame(rig)
        # the pads are read at a different moment each time
        rig.cpu.clocks += iod.us(37 * i)
        rig.call('pad_read')
        m = rig.cpu.mem
        assert m[0x10] | m[0x11] << 8 == 0x0123
        rig.call('kbd_scan')
        typed += drain(rig)
        if rig.call('mouse_poll'):
            moved[0] += signed(rig.zp('MOUSE_DX'))
            moved[1] += signed(rig.zp('MOUSE_DY'))
    for _ in range(12):
        frame(rig)
        rig.call('kbd_scan')
        typed += drain(rig)
        if rig.call('mouse_poll'):
            moved[0] += signed(rig.zp('MOUSE_DX'))
            moved[1] += signed(rig.zp('MOUSE_DY'))
    assert typed == 'aaa', typed
    assert moved == [9, 6], moved
    assert rig.port.collisions == 0


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
    frame(rig)
    ac = rig.call('mouse_poll')
    m = rig.cpu.mem
    return ac, m[0xB5], signed(m[0xB6]), signed(m[0xB7])


def poll_all(rig, frames=6):
    """polls over some frames; the movement added up, the last buttons"""
    dx = dy = 0
    b = None
    for _ in range(frames):
        ac, bt, x, y = poll(rig)
        if ac:
            dx, dy, b = dx + x, dy + y, bt
    return b, dx, dy


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
    assert mouse.aborts == 0, mouse.aborts
    # movement adds up while the mouse is held off (pad_read holds it, in
    # the middle of a byte here: the mouse sends the packet again), and
    # over the packets that come between two polls (held to +-127)
    mouse.move(10, 0)
    rig.call('kbd_scan')
    mouse.move(10, -5)
    rig.call('pad_read')
    assert poll_all(rig) == (0, 20, 5)
    for _ in range(3):
        mouse.move(100, -100)
        rig.cpu.clocks += iod.us(12_000)
    assert poll_all(rig) == (0, 127, 127)
    return 'poll: %d clocks idle, %d with a packet' % (idle, worst)


def test_mouse_late_start():
    # mice that start sending near the end of the poll's 1 ms window
    out = []
    for lat in range(0, 3000, 200):
        rig = mouse_rig(latency_us=lat)
        mouse = rig.port.mouse
        mouse.move(9, 9, 1)
        r = poll(rig)
        assert r == (1, 1, 9, -9), (lat, r)
        assert mouse.aborts == 0, (lat, mouse.aborts)
    return 'packets read with the mouse starting up to 2.8 ms late'


# ---------------------------------------------------------------------------
# PS/2 keyboard (placard_ps2.asm)
# ---------------------------------------------------------------------------
FRAME = 800 * 525
KF_PS2, KF_LED = 0x02, 0x04
E0 = 0x100
# E0 keys: set 2 code + E0 -> key number (ps2_e0)
E0_KEYS = {E0 | 0x14: K_RCTRL, E0 | 0x11: 56, E0 | 0x1F: K_FN, E0 | 0x27: K_FN,
           E0 | 0x5A: 40, E0 | 0x75: 53, E0 | 0x6B: K_LEFT, E0 | 0x72: 62, E0 | 0x74: 63}
DEL, HOME, GRAVE = E0 | 0x71, E0 | 0x6C, 0x0E


def set2_codes(rig):
    """key number -> set 2 code, read from the ROM's ps2_set2"""
    base = rig.syms['ps2_set2']
    out = {}
    for code in range(0x84):
        k = rig.mem[base + code]
        if k < 64:
            out.setdefault(k, code)
    return out


def kbd_rig(**kw):
    kb = iod.Ps2Keyboard(**kw)
    rig = Rig(kbd=kb)
    assert rig.init == 0, 'port_init %d (got %s)' % (rig.init, kb.received)
    return rig, kb


def scan(rig, n=1, settle=True):
    """n frames, each ending in kbd_scan; then (settle) frames until the
    keyboard has nothing more to send: it sends one byte per frame it is
    listened to, when only kbd_scan takes them"""
    kb = rig.port.kbd
    for i in range(n + 40):
        if i >= n and not (settle and kb is not None and
                           (kb.queue or kb.state != 'idle' or rig.port.rx.ready())):
            break
        frame(rig)
        rig.call('kbd_scan')
        rig.scan_worst = max(getattr(rig, 'scan_worst', 0), rig.clocks)
        assert rig.port.collisions == 0


def tap(rig, kb, *codes):
    """press the codes in order, then let them go in reverse"""
    for c in codes:
        kb.press(c)
        scan(rig)
    for c in reversed(codes):
        kb.release(c)
        scan(rig)
    return drain(rig)


def test_ps2_kbd_detect():
    rig = Rig()
    assert rig.init == 1 and not rig.zp('KBD_FLAGS') & KF_PS2
    none = rig.clocks
    rig, kb = kbd_rig()
    assert kb.received == [0xED, 0x00], kb.received
    assert rig.zp('KBD_FLAGS') & KF_PS2
    # still testing itself at port_init: kbd_scan looks again later
    kb = iod.Ps2Keyboard()
    kb.answers = False
    rig = Rig(kbd=kb)
    assert rig.init == 1
    for n in range(40):
        if n == 10:
            kb.answers = True
        scan(rig)
        if rig.zp('KBD_FLAGS') & KF_PS2:
            break
    assert rig.zp('KBD_FLAGS') & KF_PS2 and n == 31, n
    return 'port_init %d clocks with no PS/2 keyboard; found again after %d kbd_scan calls' % (
        none, n + 1)


def test_ps2_kbd_every_key():
    rig, kb = kbd_rig()
    codes = set2_codes(rig)
    for k in range(64):
        if k in (K_CAPS, K_FN) or k not in codes:
            continue
        got = tap(rig, kb, codes[k])
        assert got == KEYS[k].replace('\x00', ''), 'key %d: %r' % (k, got)
    missing = sorted(set(range(64)) - set(codes) - set(E0_KEYS.values()))
    assert missing == [60], missing                # the spare place
    assert kb.aborts == 0
    return 'every key; kbd_scan up to %d clocks reading a make or break' % rig.scan_worst


def test_ps2_kbd_e0_and_own_keys():
    rig, kb = kbd_rig()
    codes = set2_codes(rig)
    for code, k in E0_KEYS.items():
        if k in (K_FN, K_RCTRL, 56):
            assert tap(rig, kb, code) == '', hex(code)
        else:
            assert tap(rig, kb, code) == KEYS[k], hex(code)
    assert tap(rig, kb, E0 | 0x14, codes[44]) == '\x03'          # right Ctrl + c
    assert tap(rig, kb, DEL) == '\x7f'
    assert tap(rig, kb, HOME) == '\x15'
    assert tap(rig, kb, GRAVE) == '`'
    assert tap(rig, kb, codes[K_LSHIFT], GRAVE) == '~'
    assert tap(rig, kb, E0 | 0x1F, codes[K_BKSP]) == '\x7f'      # Windows key = Fn
    kb.pause()
    scan(rig, 3)
    assert drain(rig) == ''
    assert tap(rig, kb, codes[29]) == 'a'
    # unknown codes (F1 = 05, keypad 7 = 6C... here F12 = 07) do nothing
    assert tap(rig, kb, 0x07, 0x05) == ''
    assert tap(rig, kb, codes[30]) == 's'


def test_ps2_kbd_held_and_burst():
    rig, kb = kbd_rig()
    codes = set2_codes(rig)
    kb.press(codes[29])
    kb.press(E0 | 0x75)
    scan(rig, 2)
    now = [rig.cpu.mem[0xA0 + c] for c in range(8)]
    want = [0xFF] * 8
    want[3] &= ~(1 << 5)
    want[6] &= ~(1 << 5)
    assert now == want, now
    assert drain(rig) == 'a\x11'
    for c in (codes[29], E0 | 0x75):
        kb.release(c)
    scan(rig, 2)
    assert all(rig.cpu.mem[0xA0 + c] == 0xFF for c in range(8))
    # a burst of bytes: one per frame when only kbd_scan takes them,
    # nothing lost
    for c in (codes[k] for k in (15, 16, 17, 18, 19)):
        kb.press(c)
        kb.release(c)
    scan(rig, 15, settle=False)
    assert drain(rig) == 'qwert'
    assert kb.aborts == 0
    # the same burst taken by ps2_poll as it comes: a byte about every 1.3 ms
    for c in (codes[k] for k in (15, 16, 17, 18, 19)):
        kb.press(c)
        kb.release(c)
    polls = 0
    while kb.queue or kb.state != 'idle' or rig.port.rx.ready():
        rig.cpu.clocks += iod.us(200)
        rig.call('ps2_poll')
        polls += 1
        assert polls < 400
    rig.call('kbd_scan')
    assert drain(rig) == 'qwert'
    took = polls * 200
    assert took < 15 * 1700, took
    return '15 bytes taken by ps2_poll in %.1f ms' % (took / 1000)


def test_ps2_kbd_shift_ctrl_caps():
    rig, kb = kbd_rig()
    codes = set2_codes(rig)
    for sh in (K_LSHIFT, K_RSHIFT):
        for k in range(64):
            if k in (K_LSHIFT, K_RSHIFT, K_CAPS, K_CTRL, K_FN, K_RCTRL, 56, 60) or k not in codes:
                continue
            got = tap(rig, kb, codes[sh], codes[k])
            assert got == KEYS_SH[k].replace('\x00', ''), 'shift+%d: %r' % (k, got)
    # Ctrl: control codes, either Ctrl
    assert tap(rig, kb, codes[K_CTRL], codes[44]) == '\x03'
    assert tap(rig, kb, E0 | 0x14, codes[44]) == '\x03'
    # Caps Lock: letters only; with Shift, lower case
    assert tap(rig, kb, codes[K_CAPS]) == ''
    assert tap(rig, kb, codes[29]) + tap(rig, kb, codes[1]) == 'A1'
    assert tap(rig, kb, codes[K_LSHIFT], codes[29]) == 'a'
    assert tap(rig, kb, codes[K_CAPS]) == ''
    assert tap(rig, kb, codes[29]) == 'a'


def test_ps2_kbd_fn():
    rig, kb = kbd_rig()
    codes = set2_codes(rig)
    FN = E0 | 0x1F                                 # left Windows
    assert tap(rig, kb, FN, codes[K_BKSP]) == '\x7f'    # Delete
    assert tap(rig, kb, FN, codes[K_ESC]) == '`'
    assert tap(rig, kb, FN, codes[K_LSHIFT], codes[K_ESC]) == '~'
    assert tap(rig, kb, FN, codes[K_RSHIFT], codes[K_ESC]) == '~'
    assert tap(rig, kb, FN, E0 | 0x6B) == '\x15'        # Home
    assert tap(rig, kb, FN, codes[29]) == 'a'            # other keys as without Fn
    assert tap(rig, kb, FN, codes[K_LSHIFT], codes[29]) == 'A'
    assert tap(rig, kb, codes[K_BKSP]) == '\x08' and tap(rig, kb, codes[K_ESC]) == '\x1b'
    assert tap(rig, kb, E0 | 0x6B) == '\x13'
    for c in (FN, E0 | 0x14, E0 | 0x11):                 # Fn, right Ctrl, right Alt: no character
        assert tap(rig, kb, c) == '', hex(c)
    # the key buffer holds 7, the rest are dropped
    for k in range(1, 11):                               # 1-9, 0
        kb.press(codes[k])
        kb.release(codes[k])
    scan(rig)
    assert drain(rig) == '1234567'


def test_ps2_kbd_caps_light():
    rig, kb = kbd_rig()
    codes = set2_codes(rig)
    assert tap(rig, kb, codes[K_CAPS]) == ''
    scan(rig)
    assert kb.leds == 0x04 and rig.zp('KBD_FLAGS') & KF_LED
    assert tap(rig, kb, codes[29]) == 'A'
    # caps lock turned off by the program (kbd_key): the light follows
    rig.call('kbd_key', K_CAPS)
    scan(rig)
    assert kb.leds == 0x00 and not rig.zp('KBD_FLAGS') & KF_LED
    assert kb.received[-4:] == [0xED, 0x04, 0xED, 0x00], kb.received
    # unplugged: the light can't be set, so it counts as gone
    kb.answers = False
    rig.call('kbd_key', K_CAPS)
    scan(rig)
    assert not rig.zp('KBD_FLAGS') & KF_PS2


def test_ps2_kbd_cost():
    out = []
    for lat in (50, 400, 2000):
        rig, kb = kbd_rig(latency_us=lat)
        codes = set2_codes(rig)
        assert tap(rig, kb, codes[29]) == 'a'
        idle = []
        for _ in range(8):
            scan(rig)
            idle.append(rig.clocks)
        assert max(idle) < 400, idle
        out.append('%d us: %d' % (lat, max(idle)))
        kb.press(codes[30])
        scan(rig, settle=False)
        byte = rig.clocks
        kb.release(codes[30])
        scan(rig)
        assert drain(rig) == 's', lat
    return 'kbd_scan with nothing typed, by the keyboard\'s start delay: %s; %d with a key' % (
        ', '.join(out), byte)


def test_ps2_mouse_and_kbd():
    kb = iod.Ps2Keyboard()
    mouse = iod.Ps2Mouse(bat_ms=50)
    rig = Rig(kbd=kb, mouse=mouse)
    assert rig.init == 0
    assert rig.call('mouse_init', max_steps=20_000_000) == 0
    assert kb.received == [0xED, 0x00], kb.received
    codes = set2_codes(rig)
    typed = ''
    for i, ch in enumerate('hello'):
        mouse.move(i + 1, -i, i & 1)
        kb.press(codes[KEYS.index(ch)])
        kb.release(codes[KEYS.index(ch)])
        # the mouse has the even frames, the keyboard the odd ones
        dx = dy = 0
        for _ in range(8):
            frame(rig)
            ac = rig.call('mouse_poll')
            if ac:
                dx += signed(rig.zp('MOUSE_DX'))
                dy += signed(rig.zp('MOUSE_DY'))
                assert rig.zp('MOUSE_B') == (i & 1)
            rig.call('kbd_scan')
            typed += drain(rig)
        assert (dx, dy) == (i + 1, i), (ch, dx, dy)
    assert typed == 'hello', typed
    assert mouse.aborts == 0 and kb.aborts == 0, (mouse.aborts, kb.aborts)
    assert rig.port.collisions == 0
    assert mouse.received == [0xFF, 0xF4], mouse.received
    assert kb.received == [0xED, 0x00], kb.received
    return 'mouse packets and keys on the shared DATA line, no collisions'


def wait_io(rig, frames):
    """wait_frames_io(frames); returns the clocks into the frame it ended at"""
    rig.call('wait_frames_io', frames)
    return rig.cpu.clocks % FRAME


def test_wait_frames_io():
    kb = iod.Ps2Keyboard()
    mouse = iod.Ps2Mouse(bat_ms=50)
    rig = Rig(kbd=kb, mouse=mouse)
    assert rig.call('mouse_init', max_steps=20_000_000) == 0
    codes = set2_codes(rig)
    late = 0
    typed = ''
    moved = [0, 0]
    for i in range(40):
        rig.cpu.clocks += iod.us(3000 + 997 * (i % 13))  # work of different lengths
        if i % 3 == 0:
            mouse.move(2, 1)
        if i % 5 == 0:
            kb.press(codes[29 + i // 5 % 4])
            kb.release(codes[29 + i // 5 % 4])
        late = max(late, wait_io(rig, 1))
        ac = rig.call('mouse_poll')
        assert rig.clocks < 500, 'mouse_poll after wait_frames_io %d clocks' % rig.clocks
        if ac:
            moved[0] += signed(rig.zp('MOUSE_DX'))
            moved[1] += signed(rig.zp('MOUSE_DY'))
        rig.call('kbd_scan')
        assert rig.clocks < 3000, 'kbd_scan after wait_frames_io %d clocks' % rig.clocks
        typed += drain(rig)
        assert rig.port.collisions == 0
    for _ in range(8):
        wait_io(rig, 1)
        if rig.call('mouse_poll'):
            moved[0] += signed(rig.zp('MOUSE_DX'))
            moved[1] += signed(rig.zp('MOUSE_DY'))
        rig.call('kbd_scan')
        typed += drain(rig)
    assert moved == [28, -14], moved
    assert typed == 'asdfasdf', typed
    # it waits like wait_frames: AC frames, ending at a frame's start
    assert late < 1500, 'wait_frames_io ended %d clocks into the frame' % late
    t0 = rig.cpu.clocks
    wait_io(rig, 3)
    assert 2 * FRAME < rig.cpu.clocks - t0 <= 3 * FRAME + 1500
    return 'mouse and keys read while waiting; ends at most %d clocks into the frame' % late


# ---------------------------------------------------------------------------
# line input and the mouse pointer (placard_input.asm)
# ---------------------------------------------------------------------------
def test_con_gets():
    kb = iod.Ps2Keyboard()
    rig = Rig(kbd=kb)
    cpu, m = rig.cpu, rig.cpu.mem
    codes = set2_codes(rig)
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
    # each step: the keys pressed (Shift first) at a frame, let go 4 frames later
    events = set(range(0, 8 * len(script), 4))
    m[sy['R0']], m[sy['R1']], m[sy['R2']] = 0x00, 0x07, 4
    m[ARG_AC] = 0
    cpu.pc = sy['drv_con_gets']
    stop = sy['halt_con_gets']
    frame_clocks = 800 * 525
    t0 = cpu.clocks
    done = set()
    while cpu.pc != stop:
        f = (cpu.clocks - t0) // frame_clocks
        if f in events and f not in done:
            done.add(f)
            for i, ks in enumerate(script):
                if f == 8 * i:
                    for k in sorted(ks, key=lambda k: k != K_LSHIFT):
                        kb.press(codes[k])
                if f == 8 * i + 4:
                    for k in sorted(ks, key=lambda k: k == K_LSHIFT):
                        kb.release(codes[k])
        cpu.step()
        assert f < 8 * len(script) + 20, 'con_gets did not end'
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
