#!/usr/bin/env python3
"""
mus_tool.py - PLACARD music: song text -> .SNG, the reference model of the
player (placard_mus.masm), WAV rendering and the player's tables

    python3 mus_tool.py build song.mus -o SONG.SNG     binary song
    python3 mus_tool.py wav song.mus -o song.wav [--seconds 30] [--sub 0]
    python3 mus_tool.py tables                         writes mus_tables.masm
    python3 mus_tool.py dump SONG.SNG                  the song as text again

The player is SID-like: 4 voices (and a fifth for sound effects that takes
voice 4's place while it plays), each with an oscillator (16-bit phase and
step), a waveform (pulse with a swept width, saw, triangle, noise or one of
8 custom 32-step waves) and an ADSR envelope, mixed at 15.76 kHz (one
sample for two lines; the line at x5DF3 has one of its own).  Once a frame
(a "tick") the player reads the patterns and runs the instruments' wave and
pulse programs, the effects and the envelopes.  docs/MUSIC.md describes the
song format, the text format and the effects.

Model.  Model below is the player tick for tick and sample for sample:
test_mus.py runs placard_mus.masm in placard_sim and checks every sample
in the audio buffer against Model.samples().  Change one, change the other.

Date: 11/01/2026
"""

import argparse
import os
import random
import re
import struct
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# timing and tables
# ---------------------------------------------------------------------------
LINE_HZ = 25175000 / 800
FRAME_HZ = LINE_HZ / 525
RATE = 263 * FRAME_HZ                 # samples per second (263 per frame)
NNOTES = 96                           # C-0 .. B-7
NOTE_NAMES = ['C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-']

WAVE_NAMES = {'off': 0, 'pulse': 1, 'saw': 2, 'tri': 3, 'noise': 4}
for _k in range(8):
    WAVE_NAMES['cw%d' % _k] = 5 + _k
W_OFF, W_PULSE, W_SAW, W_TRI, W_NOISE = 0, 1, 2, 3, 4

ATK_MS = [2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000]
DEC_MS = [6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000]


def rate_table(ms_list):
    out = []
    for ms in ms_list:
        ticks = ms / 1000.0 * FRAME_HZ
        out.append(min(0xFF00, max(1, int(round(0xFF00 / max(ticks, 1.0))))))
    return out


ATK = rate_table(ATK_MS)
DEC = rate_table(DEC_MS)
NOTES = [int(round(440.0 * 2 ** ((n - 57) / 12.0) * 65536 / RATE)) for n in range(NNOTES)]


def vol_value(level, w):
    """one voice's contribution, 0-63 (32 = silence), for wave value w 0-63"""
    return (2 * (w - 32) * level + 15) // 30 + 32


VOLT = [[0] * 256 for _ in range(4)]     # page L >> 2, index (L & 3) * 64 + w
for _L in range(16):
    for _w in range(64):
        VOLT[_L >> 2][(_L & 3) * 64 + _w] = vol_value(_L, _w)
VMUL = [(a * b) // 15 for a in range(16) for b in range(16)]
SAW = [i >> 2 for i in range(256)]
TRI = [(i >> 1) if i < 128 else ((255 - i) >> 1) for i in range(256)]
_r = random.Random(0x5EED)
NOISE = [[_r.randrange(64) for _ in range(256)] for _ in range(2)]


def rng_next(r):
    """8-bit Galois LFSR (x8+x4+x3+x2+1): shl, xor 1Dh on carry"""
    r <<= 1
    if r & 0x100:
        r ^= 0x11D
    return r & 0xFF


# ---------------------------------------------------------------------------
# the song binary (.SNG)
# ---------------------------------------------------------------------------
# page 0: 00-03 "PMU",1; 04 nsub; 05 npat; 06 ninstr; 07 flags; 08-09 length;
#         20-3F title; 40-7E subtunes (7 x 9: speed, 4 orderlist offsets);
#         80-BF pattern offsets low, C0-FF high (64 patterns)
# page 1: wave table: left (waveform) 00-3F, right (note) 40-7F; pulse table:
#         left 80-BF, right C0-FF (entries 1-63; 0 = none)
# pages 2-3: instruments 0-31, 16 bytes each
# page 4: custom waves 0-7, 32 bytes each (values 0-63)
# page 5 on: orderlists and patterns
P_WAVE, P_INS, P_CW, P_DATA = 1, 2, 4, 5
MAX_SUB, MAX_PAT, MAX_INS, MAX_TAB, MAX_CW = 7, 64, 32, 63, 8

# instrument bytes (16): AD, SR, wave program, pulse program, pulse width,
# flags (bit 0 hard restart), vibrato delay, vibrato (speed, depth), volume,
# name (7 characters)
I_AD, I_SR, I_WAVE, I_PULSE, I_PW, I_FLAGS, I_VDLY, I_VIB, I_VOL, I_NAME = range(10)
NAME_LEN = 7
F_HARD = 1

# pattern bytes
B_KEYOFF, B_NONE = 0x60, 0x61
B_EMPTY = 0x80          # 80-BF: this row and (b & 3F) more are empty
B_INS = 0xC0            # C0-DF: instrument for this row's note
B_FX = 0xE0             # E0-EF: effect (b & 0F), the next byte its parameter
B_END = 0xFF

# orderlist bytes: 00-3F pattern, 80-BF transpose (b - A0), FE stop, FF nn loop to nn
O_STOP, O_LOOP = 0xFE, 0xFF


class Song:
    def __init__(self):
        self.title = ''
        self.subtunes = []         # [(speed, [orderlist bytes x 4])]
        self.patterns = []         # [bytes]
        self.instruments = []      # [16 bytes]
        self.wave = []             # [(left, right)] entries 1..
        self.pulse = []
        self.custom = []           # [32 values]

    def binary(self):
        if not self.subtunes:
            raise ValueError('no subtunes')
        for name, lim, n in (('subtunes', MAX_SUB, len(self.subtunes)),
                             ('patterns', MAX_PAT, len(self.patterns)),
                             ('instruments', MAX_INS, len(self.instruments)),
                             ('wave table entries', MAX_TAB, len(self.wave)),
                             ('pulse table entries', MAX_TAB, len(self.pulse)),
                             ('custom waves', MAX_CW, len(self.custom))):
            if n > lim:
                raise ValueError('too many %s: %d (at most %d)' % (name, n, lim))
        img = bytearray(P_DATA * 256)
        img[0:4] = b'PMU\x01'
        img[4], img[5], img[6] = len(self.subtunes), len(self.patterns), len(self.instruments)
        t = self.title.upper().encode('ascii', 'replace')[:32]
        img[0x20:0x40] = t + b' ' * (32 - len(t))
        for i, (wl, wr) in enumerate(self.wave):
            img[0x100 + 1 + i] = wl
            img[0x140 + 1 + i] = wr
        for i, (pl, pr) in enumerate(self.pulse):
            img[0x180 + 1 + i] = pl
            img[0x1C0 + 1 + i] = pr
        for i, ins in enumerate(self.instruments):
            img[P_INS * 256 + 16 * i:P_INS * 256 + 16 * i + 16] = bytes(ins)
        for i, cw in enumerate(self.custom):
            img[P_CW * 256 + 32 * i:P_CW * 256 + 32 * i + 32] = bytes(v & 63 for v in cw)
        for s, (speed, ols) in enumerate(self.subtunes):
            b = 0x40 + 9 * s
            img[b] = speed
            for v in range(4):
                off = len(img)
                img += bytes(ols[v])
                img[b + 1 + 2 * v] = off & 0xFF
                img[b + 2 + 2 * v] = off >> 8
        for p, data in enumerate(self.patterns):
            off = len(img)
            img += bytes(data)
            img[0x80 + p] = off & 0xFF
            img[0xC0 + p] = off >> 8
        img[8], img[9] = len(img) & 0xFF, len(img) >> 8
        return bytes(img)


# ---------------------------------------------------------------------------
# song text (.mus)
# ---------------------------------------------------------------------------
def parse_note(tok):
    """'C-4' -> 48 (C-0 = 0)"""
    m = re.match(r'^([A-Ga-g])([-#])(\d)$', tok)
    if not m:
        raise ValueError('bad note %r' % tok)
    name = m.group(1).upper() + m.group(2)
    n = NOTE_NAMES.index(name) + 12 * int(m.group(3))
    if not 0 <= n < NNOTES:
        raise ValueError('note out of range %r' % tok)
    return n


def note_name(n):
    return NOTE_NAMES[n % 12] + str(n // 12)


def num(tok):
    tok = tok.strip()
    if tok.lower().startswith('0x'):
        return int(tok, 16)
    if tok.startswith('$'):
        return int(tok[1:], 16)
    return int(tok)


def pack_rows(rows):
    """rows: [(note or None or 'off', ins or None, fx or None, param)] -> bytes"""
    out = bytearray()
    i = 0
    while i < len(rows):
        note, ins, fx, par = rows[i]
        if note is None and ins is None and fx is None:
            j = i + 1
            while j < len(rows) and j - i < 64 and rows[j] == (None, None, None, 0):
                j += 1
            out.append(B_EMPTY + (j - i - 1))
            i = j
            continue
        if ins is not None:
            out.append(B_INS + ins)
        if fx is not None:
            out += bytes([B_FX + fx, par & 0xFF])
        if note is None:
            out.append(B_NONE)
        elif note == 'off':
            out.append(B_KEYOFF)
        else:
            out.append(note)
        i += 1
    out.append(B_END)
    return bytes(out)


def unpack_rows(data):
    rows, i = [], 0
    ins = fx = None
    par = 0
    while i < len(data):
        b = data[i]
        i += 1
        if b == B_END:
            break
        if B_INS <= b < B_FX:
            ins = b - B_INS
        elif B_FX <= b < B_END:
            fx, par = b - B_FX, data[i]
            i += 1
        elif B_EMPTY <= b < B_INS:
            rows += [(None, None, None, 0)] * ((b & 0x3F) + 1)
        else:
            note = None if b == B_NONE else ('off' if b == B_KEYOFF else b)
            rows.append((note, ins, fx, par))
            ins = fx = None
            par = 0
    return rows


def parse_row(line):
    """'C-4 01 120' / '... -- ...' / '===' / 'C-4' -> (note, ins, fx, par)"""
    toks = line.split()
    note = ins = fx = None
    par = 0
    if toks:
        t = toks[0]
        if t in ('===', 'off'):
            note = 'off'
        elif t not in ('...', '---', '.'):
            note = parse_note(t)
    if len(toks) > 1 and toks[1] not in ('--', '..', '.'):
        ins = int(toks[1], 16)
    if len(toks) > 2 and toks[2] not in ('...', '---', '.'):
        e = toks[2]
        fx, par = int(e[0], 16), int(e[1:], 16)
    return note, ins, fx, par


def parse_mus(text):
    """the song text format (docs/MUSIC.md) -> Song"""
    song = Song()
    wave_labels, pulse_labels = {}, {}
    instruments = {}
    patterns = {}
    subs = {}
    cur_pat = None
    lines = text.splitlines()
    for lineno, raw in enumerate(lines, 1):
        line = raw.split(';', 1)[0].rstrip()
        if not line.strip():
            continue
        try:
            if cur_pat is not None and raw[:1] in (' ', '\t'):
                patterns[cur_pat].append(parse_row(line.strip()))
                continue
            cur_pat = None
            toks = line.split()
            kw = toks[0].lower()
            if kw == 'title':
                song.title = line.split(None, 1)[1].strip().strip('"')
            elif kw == 'wave':
                label = toks[1]
                steps = [s.strip() for s in line.split(None, 2)[2].split(',')]
                start = len(song.wave) + 1
                wave_labels[label] = start
                for s in steps:
                    sl = s.lower()
                    if sl == 'end':
                        song.wave.append((0xFE, 0))
                    elif sl.startswith('loop'):
                        song.wave.append((0xFF, start + num(sl.split()[1])))
                    else:
                        m = re.match(r'^([a-z0-9]*)\s*(.*)$', sl)
                        wname, rest = m.group(1), m.group(2).strip()
                        if wname and wname not in WAVE_NAMES:
                            rest, wname = (wname + rest), ''
                        w = WAVE_NAMES[wname] if wname else 0
                        if not rest:
                            r = 0
                        elif rest[0] in '+-':
                            r = num(rest) & 0x7F
                        else:
                            r = 0x80 | parse_note(rest.upper())
                        if wname == 'off':
                            w = 0x7F            # waveform off (0 = no change)
                        song.wave.append((w, r))
            elif kw == 'pulse':
                label = toks[1]
                steps = [s.strip() for s in line.split(None, 2)[2].split(',')]
                start = len(song.pulse) + 1
                pulse_labels[label] = start
                for s in steps:
                    sl = s.lower().split()
                    if sl[0] == 'end':
                        song.pulse.append((0, 0))
                    elif sl[0] == 'loop':
                        song.pulse.append((0xFF, start + num(sl[1])))
                    elif sl[0] == 'set':
                        song.pulse.append((0x80, num(sl[1])))
                    else:                       # ticks x speed: "20x+4"
                        m = re.match(r'^(\d+)x([+-]\d+)$', sl[0])
                        if not m:
                            raise ValueError('bad pulse step %r' % s)
                        n, spd = int(m.group(1)), int(m.group(2))
                        if not 1 <= n <= 127:
                            raise ValueError('pulse step ticks must be 1-127')
                        song.pulse.append((n, spd & 0xFF))
            elif kw == 'instrument':
                n = num(toks[1])
                name = toks[2]
                ins = [0] * 16
                ins[I_PW] = 0x80
                ins[I_VOL] = 15
                for kv in toks[3:]:
                    k, _, v = kv.partition('=')
                    k = k.lower()
                    if k == 'ad':
                        ins[I_AD] = int(v, 16)
                    elif k == 'sr':
                        ins[I_SR] = int(v, 16)
                    elif k == 'wave':
                        ins[I_WAVE] = wave_labels[v]
                    elif k == 'pulse':
                        ins[I_PULSE] = pulse_labels[v]
                    elif k == 'pw':
                        ins[I_PW] = int(v, 16)
                    elif k == 'hr':
                        ins[I_FLAGS] |= F_HARD
                    elif k == 'vib':
                        ins[I_VIB] = int(v, 16)
                    elif k == 'vol':
                        ins[I_VOL] = num(v) & 15
                    elif k == 'vdelay':
                        ins[I_VDLY] = num(v)
                    else:
                        raise ValueError('unknown instrument field %r' % k)
                nm = name.upper().encode()[:NAME_LEN]
                ins[I_NAME:I_NAME + NAME_LEN] = list(nm + b' ' * (NAME_LEN - len(nm)))
                instruments[n] = ins
            elif kw == 'pattern':
                cur_pat = num(toks[1])
                patterns[cur_pat] = []
            elif kw == 'custom':
                vals = [num(v) for v in line.split(None, 2)[2].split()]
                if len(vals) != 32:
                    raise ValueError('a custom wave has 32 values')
                k = num(toks[1])
                while len(song.custom) <= k:
                    song.custom.append([32] * 32)
                song.custom[k] = vals
            elif kw == 'subtune':
                s = num(toks[1])
                speed = 6
                for kv in toks[2:]:
                    k, _, v = kv.partition('=')
                    if k == 'speed':
                        speed = num(v)
                subs[s] = [speed, [None] * 4]
            elif kw == 'order':
                s, v = toks[1].rstrip(':').split('.')
                s, v = num(s), num(v) - 1
                subs.setdefault(s, [6, [None] * 4])
                ol = bytearray()
                it = iter(toks[2:])
                for t in it:
                    if t[0] in '+-':
                        ol.append(0xA0 + num(t))
                    elif t == 'loop':
                        ol += bytes([O_LOOP, num(next(it))])
                    elif t == 'stop':
                        ol.append(O_STOP)
                    else:
                        ol.append(int(t, 16))
                if not ol or ol[-1] != O_STOP and (len(ol) < 2 or ol[-2] != O_LOOP):
                    ol += bytes([O_LOOP, 0])
                subs[s][1][v] = bytes(ol)
            elif kw == 'speed':
                pass
            else:
                raise ValueError('unknown line')
        except (ValueError, KeyError, IndexError, StopIteration) as e:
            raise SystemExit('line %d: %s: %s' % (lineno, e, raw.strip()))
    song.instruments = [instruments.get(i, [0] * 8 + [15] + list(b'       '))
                        for i in range(max(instruments) + 1 if instruments else 1)]
    song.patterns = [pack_rows(patterns.get(p, [(None, None, None, 0)]))
                     for p in range(max(patterns) + 1 if patterns else 1)]
    for s in range(max(subs) + 1):
        speed, ols = subs.get(s, [6, [None] * 4])
        song.subtunes.append((speed, [o if o else bytes([O_STOP]) for o in ols]))
    return song


# ---------------------------------------------------------------------------
# the player, tick for tick (placard_mus.masm)
# ---------------------------------------------------------------------------
def s8(v):
    return v - 256 if v & 0x80 else v


class Voice:
    def __init__(self):
        self.stopped = True
        self.ol = self.ol_start = self.pp = 0
        self.trans = self.empty = 0
        self.note = self.ins = 0
        self.step = 0
        self.fx = self.fxp = 0
        self.env = 0
        self.est = 3
        self.ad = self.sr = 0
        self.wptr = self.wnote = 0
        self.pptr = self.pcnt = self.pspd = 0
        self.pw = 0x80
        self.wave = W_OFF
        self.pagek = 0xFF       # what the voice's own page holds: 0xFF none, 1 pulse, 5+k custom k
        self.pagew = 0
        self.vib = self.vdly = 0
        self.vcnt = self.vdir = 0
        self.vhalf = 1
        self.voff = 0
        self.tgt = 0
        self.vol = 15
        self.arpi = 0
        self.flags = 0
        self.sfx = 0            # sfx voice: frames left
        # mixer state
        self.phase = 0
        self.mstep = 0
        self.wpg = None         # ('own', page list) or table
        self.level = 0


class Model:
    """the player: init(song bytes), play(sub), then samples(n) gives the
    mixed buffer values in the order they play"""

    def __init__(self, song):
        self.s = bytes(song) + bytes(256)
        assert self.s[:3] == b'PMU'
        self.v = [Voice() for _ in range(5)]
        self.pages = [[32] * 256 for _ in range(5)]   # each voice's own wave page
        self.master = 15
        self.speed = 6
        self.tick_n = 0
        self.rng = 1
        self.playing = False
        self.lap_pos = 0         # 0 = the single sample at x5DF3, then 1-262 pairs
        self.sfx_n = 0
        self.phase = [0] * 4     # the mixer slots' phases
        self.slot = [(0, SAW, 0)] * 4   # (step, wave page, level) per slot

    # -- song access
    def b(self, off):
        return self.s[off]

    def play(self, sub):
        base = 0x40 + 9 * sub
        self.speed = self.b(base) or 6
        self.tick_n = 0
        self.master = 15
        for i in range(4):
            v = self.v[i]
            v.__init__()
            off = self.b(base + 1 + 2 * i) | self.b(base + 2 + 2 * i) << 8
            v.ol = v.ol_start = off
            v.pp = None             # no pattern: the first row reads the orderlist
            v.stopped = False
            self.phase[i] = 0
            self.slot[i] = (0, SAW, 0)
        self.playing = True

    def stop(self):
        """mus_stop: no more rows; every voice releases"""
        self.playing = False
        for v in self.v[:4]:
            v.est = 3

    def sfx(self, note, ins, frames):
        """mus_sfx: a note on voice 4 for a number of frames, heard in voice 3's place"""
        self.sfx_n = frames
        self.trigger(self.v[4], note, ins)

    # -- one tick
    def tick(self):
        """one frame: rows, instruments, effects, envelopes, then each voice's
        mixer setting (voice 4 goes to mixer slot 3 while a sound effect
        plays, and voice 3 is not heard)"""
        new_row = self.playing and self.tick_n == 0
        for i in range(5):
            v = self.v[i]
            if i == 4 and not self.sfx_n:
                continue
            if i < 4 and new_row and not v.stopped:
                self.read_row(v)
            self.voice_tick(v, self.tick_n if i < 4 else 1)
            if i == 4:
                self.mixer_params(v, 3, 4)
            elif not (i == 3 and self.sfx_n):
                self.mixer_params(v, i, i)
        if self.playing:
            self.tick_n += 1
            if self.tick_n >= self.speed:
                self.tick_n = 0
        if self.sfx_n:
            self.sfx_n -= 1

    def read_row(self, v):
        if v.empty:
            v.empty -= 1
            v.fx = v.fxp = 0
            v.arpi = 0
            return
        ins = None
        fx, fxp = 0, 0
        guard = 0
        while True:
            if v.pp is None:
                b = B_END
            else:
                b = self.b(v.pp)
                v.pp += 1
            if b == B_END:
                guard += 1
                if guard > 2 or not self.next_pattern(v):
                    v.stopped = True
                    v.est = 3
                    return
                continue
            if B_INS <= b < B_FX:
                ins = b - B_INS
            elif B_FX <= b < B_END:
                fx, fxp = b - B_FX, self.b(v.pp)
                v.pp += 1
            elif B_EMPTY <= b < B_INS:
                v.empty = b & 0x3F
                v.fx = v.fxp = 0
                v.arpi = 0
                return
            else:
                break
        v.fx, v.fxp = fx, fxp
        v.arpi = 0
        if ins is not None:
            v.ins = ins
        if b == B_KEYOFF:
            v.est = 3
        elif b < 0x60:
            n = (b + v.trans) & 0xFF
            if n >= 0x80:
                n = 0
            elif n >= NNOTES:
                n = NNOTES - 1
            if fx == 3:
                v.note = n
                v.tgt = NOTES[n]
            else:
                self.trigger(v, n, v.ins)
        # instant effects
        if fx == 5:
            v.ad = fxp
        elif fx == 6:
            v.sr = fxp
        elif fx == 7:
            v.pw = fxp
            v.pptr = 0
        elif fx == 8:
            v.wptr = fxp & 0x3F
        elif fx == 9:
            v.vol = fxp & 15
        elif fx == 0xA:
            self.master = fxp & 15
        elif fx == 0xF:
            if fxp:
                self.speed = fxp

    def next_pattern(self, v):
        """orderlist: the next pattern; False = stop"""
        for _ in range(64):
            b = self.b(v.ol)
            v.ol += 1
            if b == O_STOP:
                v.ol -= 1
                return False
            if b == O_LOOP:
                v.ol = v.ol_start + self.b(v.ol)
                continue
            if 0x80 <= b < 0xC0:
                v.trans = (b - 0xA0) & 0xFF
                continue
            p = b & 0x3F
            v.pp = self.b(0x80 + p) | self.b(0xC0 + p) << 8
            return True
        return False

    def trigger(self, v, n, ins):
        v.ins = ins
        a = P_INS * 256 + 16 * (ins & 31)
        v.ad = self.b(a + I_AD)
        v.sr = self.b(a + I_SR)
        v.wptr = self.b(a + I_WAVE)
        v.pptr = self.b(a + I_PULSE)
        v.pcnt = 0
        v.pw = self.b(a + I_PW)
        v.flags = self.b(a + I_FLAGS)
        v.vdly = self.b(a + I_VDLY)
        v.vib = self.b(a + I_VIB)
        v.vol = self.b(a + I_VOL) & 15
        if v.flags & F_HARD:
            v.env = 0
        v.est = 0
        v.note = n
        v.step = NOTES[n]
        v.wnote = 0
        v.voff = v.vcnt = v.vdir = 0
        v.vhalf = 1

    def voice_tick(self, v, rowtick):
        # wave program
        if v.wptr:
            for _ in range(2):
                wl = self.b(0x100 + v.wptr)
                wr = self.b(0x140 + v.wptr)
                if wl == 0xFF:
                    v.wptr = wr & 0x3F
                    if not v.wptr:
                        break
                    continue
                if wl == 0xFE:
                    v.wptr = 0
                    break
                if wl:
                    v.wave = 0 if wl == 0x7F else wl & 0x0F
                v.wnote = wr
                v.wptr = (v.wptr + 1) & 0x3F
                break
        # pulse program
        if v.pptr and not v.pcnt:
            for _ in range(2):
                pl = self.b(0x180 + v.pptr)
                pr = self.b(0x1C0 + v.pptr)
                if pl == 0xFF:
                    v.pptr = pr & 0x3F
                    if not v.pptr:
                        break
                    continue
                if pl == 0:
                    v.pptr = 0
                    break
                v.pptr = (v.pptr + 1) & 0x3F
                if pl & 0x80:
                    v.pw = pr
                else:
                    v.pcnt, v.pspd = pl, pr
                break
        if v.pcnt:
            v.pw = (v.pw + v.pspd) & 0xFF
            v.pcnt -= 1
        # effects
        fx, p = v.fx, v.fxp
        if rowtick:
            if fx == 1:
                v.step = min(0xFFFF, v.step + 4 * p)
            elif fx == 2:
                v.step = max(0, v.step - 4 * p)
            elif fx == 3:
                if v.step < v.tgt:
                    v.step = min(v.tgt, v.step + 4 * p)
                else:
                    v.step = max(v.tgt, v.step - 4 * p)
        vib = p if fx == 4 else v.vib
        if fx != 4 and v.vdly:
            v.vdly -= 1
            vib = 0
        spd, dep = vib >> 4, vib & 15
        if spd and dep:
            vd = ((v.step >> 8) * dep) >> 2
            if v.vdir:
                v.voff = (v.voff - vd) & 0xFFFF
            else:
                v.voff = (v.voff + vd) & 0xFFFF
            v.vcnt += 1
            lim = (spd >> 1) if v.vhalf else spd
            if v.vcnt >= max(lim, 1):
                v.vcnt = 0
                v.vdir ^= 1
                v.vhalf = 0
        else:
            v.voff = 0
        arp = 0
        if fx == 0 and p:
            arp = (0, p >> 4, p & 15)[v.arpi]
            v.arpi = v.arpi + 1 if v.arpi < 2 else 0
        # envelope
        if v.est == 0:
            e = v.env + ATK[v.ad >> 4]
            if e >= 0xFF00:
                v.env, v.est = 0xFF00, 1
            else:
                v.env = e
        elif v.est == 1:
            tgt = ((v.sr >> 4) * 17) << 8
            e = v.env - DEC[v.ad & 15]
            if e <= tgt:
                v.env, v.est = tgt, 2
            else:
                v.env = e
        elif v.est == 3:
            v.env = max(0, v.env - DEC[v.sr & 15])
        # pitch
        if v.wnote & 0x80:
            n = v.wnote & 0x7F
        else:
            n = v.note + arp + s8(v.wnote if v.wnote < 0x40 else v.wnote | 0x80)
        if v.wnote or arp:
            n = min(max(n, 0), NNOTES - 1)
            st = NOTES[n]
        else:
            st = (v.step + v.voff) & 0xFFFF
        if v.wave == W_NOISE:
            st >>= 4
        v.mstep = st
        lv = VMUL[(v.env >> 12) * 16 + v.vol]
        v.level = VMUL[lv * 16 + self.master] if v.wave else 0

    def mixer_params(self, v, i, vi):
        """voice vi's setting for mixer slot i: step, wave page, level"""
        if v.wave == W_PULSE:
            page = self.pages[vi]
            if v.pagek != W_PULSE:
                for k in range(256):
                    page[k] = 63 if k < v.pw else 0
            elif v.pw != v.pagew:
                lo, hi = sorted((v.pw, v.pagew))
                val = 63 if v.pw > v.pagew else 0
                for k in range(lo, hi):
                    page[k] = val
            v.pagek, v.pagew = W_PULSE, v.pw
            v.wpg = page
        elif v.wave == W_SAW:
            v.wpg = SAW
        elif v.wave == W_TRI:
            v.wpg = TRI
        elif v.wave == W_NOISE:
            self.rng = rng_next(self.rng)
            v.wpg = NOISE[self.rng & 1]
            self.rng = rng_next(self.rng)
            self.phase[i] = (self.phase[i] & 0xFF) | self.rng << 8
        elif v.wave >= 5:
            page = self.pages[vi]
            if v.pagek != v.wave:
                k = v.wave - 5
                cw = P_CW * 256 + ((32 * k) & 0xFF)
                for j in range(256):
                    page[j] = self.b(cw + (j >> 3)) & 63
                v.pagek = v.wave
            v.wpg = page
        else:
            v.wpg = SAW
        self.slot[i] = (v.mstep, v.wpg, v.level)

    # -- the mixer
    def one(self):
        tot = 0
        for i in range(4):
            st, page, L = self.slot[i]
            self.phase[i] = (self.phase[i] + st) & 0xFFFF
            w = page[self.phase[i] >> 8]
            tot += VOLT[L >> 2][(L & 3) * 64 + w]
        return tot

    def samples(self, n):
        """the next n buffer values in play order (x5DF3, x5DF4, ...)"""
        out = []
        while len(out) < n:
            if self.lap_pos == 0:
                out.append(self.one())
                self.tick()
                self.lap_pos = 1
            else:
                s = self.one()
                out += [s, s]
                self.lap_pos += 1
                if self.lap_pos == 263:
                    self.lap_pos = 0
        return out[:n] if len(out) > n else out


# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
def render_wav(song_bytes, path, seconds, sub=0):
    m = Model(song_bytes)
    m.play(sub)
    n = int(seconds * LINE_HZ)
    data = m.samples(n)
    # the board's filter: one pole at 10.6 kHz, then resample to 44.1 kHz
    import math
    a = 1 - math.exp(-2 * math.pi * 10600 / LINE_HZ)
    lp = 128.0
    filt = []
    for v in data:
        lp += a * (v - lp)
        filt.append(lp)
    out_rate = 44100
    nout = int(len(filt) * out_rate / LINE_HZ)
    frames = bytearray()
    dc = 128.0
    for k in range(nout):
        t = k * LINE_HZ / out_rate
        i = int(t)
        f = t - i
        v = filt[i] if i + 1 >= len(filt) else filt[i] * (1 - f) + filt[i + 1] * f
        dc += (v - dc) * 0.0005
        s = int(max(-32768, min(32767, (v - dc) * 200)))
        frames += struct.pack('<h', s)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(out_rate)
        w.writeframes(bytes(frames))


def write_tables(path):
    """mus_tables.masm: the player's tables as .fixed data pages from MUS_TABLES"""
    pages = [('MUS_SAW', SAW), ('MUS_TRI', TRI), ('MUS_NOISE', NOISE[0]),
             ('MUS_NOISE1', NOISE[1])]
    pages += [('MUS_VOLT%d' % k, VOLT[k]) for k in range(4)]
    pages.append(('MUS_VMUL', VMUL))
    tab = ([n & 0xFF for n in NOTES] + [n >> 8 for n in NOTES] +
           [r & 0xFF for r in ATK] + [r >> 8 for r in ATK] +
           [r & 0xFF for r in DEC] + [r >> 8 for r in DEC])
    assert len(tab) == 256
    pages.append(('MUS_TAB', tab))
    out = ['; mus_tables.masm - the music player\'s tables (placard_mus.masm),',
           '; made by "python3 mus_tool.py tables": do not edit, change mus_tool.py',
           ';',
           '; ten pages from MUS_TABLES: SAW, TRI, NOISE (2 pages), VOLT (4 pages,',
           '; volume L 0-15 x sample 0-63 at page L>>2, (L&3)*64+w), VMUL (a*b/15),',
           '; TAB: note steps (low bytes x00-x5F, high x60-xBF) and the envelope rates',
           '; per ADSR value (attack low xC0, high xD0; decay/release low xE0, high xF0).',
           ';', '; Date: 11/01/2026', '']
    for k, (name, vals) in enumerate(pages):
        out.append('.fixed MUS_TABLES + 0x%03X' % (k * 0x100))
        out.append('; %s' % name)
        for i in range(0, 256, 16):
            out.append('    #d8 ' + ', '.join('0x%02X' % v for v in vals[i:i + 16]))
        out.append('')
    with open(path, 'w') as f:
        f.write('\n'.join(out))


def dump(song_bytes):
    s = song_bytes
    print('title %r' % s[0x20:0x40].decode().rstrip())
    nsub, npat, nins = s[4], s[5], s[6]
    for i in range(nsub):
        b = 0x40 + 9 * i
        print('subtune %d speed=%d' % (i, s[b]))
        for v in range(4):
            off = s[b + 1 + 2 * v] | s[b + 2 + 2 * v] << 8
            ol = []
            while True:
                c = s[off]
                ol.append('%02X' % c)
                off += 1
                if c == O_STOP:
                    break
                if c == O_LOOP:
                    ol.append('%02X' % s[off])
                    break
            print('  order %d.%d: %s' % (i, v + 1, ' '.join(ol)))
    for p in range(npat):
        off = s[0x80 + p] | s[0xC0 + p] << 8
        print('pattern %d' % p)
        for note, ins, fx, par in unpack_rows(s[off:]):
            nt = '...' if note is None else ('===' if note == 'off' else note_name(note))
            print('  %s %s %s' % (nt, '--' if ins is None else '%02X' % ins,
                                   '...' if fx is None else '%X%02X' % (fx, par)))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('cmd', choices=['build', 'wav', 'tables', 'dump'])
    ap.add_argument('src', nargs='?')
    ap.add_argument('-o', '--out')
    ap.add_argument('--seconds', type=float, default=30)
    ap.add_argument('--sub', type=int, default=0)
    a = ap.parse_args(argv)
    if a.cmd == 'tables':
        write_tables(a.out or os.path.join(HERE, 'mus_tables.masm'))
        return
    if a.cmd == 'dump':
        dump(open(a.src, 'rb').read())
        return
    song = parse_mus(open(a.src).read()).binary()
    if a.cmd == 'build':
        out = a.out or os.path.splitext(a.src)[0].upper() + '.SNG'
        with open(out, 'wb') as f:
            f.write(song)
        print('%s: %d bytes' % (out, len(song)))
    else:
        out = a.out or os.path.splitext(a.src)[0] + '.wav'
        render_wav(song, out, a.seconds, a.sub)
        print(out)


if __name__ == '__main__':
    main(sys.argv[1:])
