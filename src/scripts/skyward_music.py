#!/usr/bin/env python3
"""
skyward_music.py - Skyward Tobi's songs for the Placard's four-voice music
player (placard_mus.masm, docs/sound/MUSIC.md)

    python3 skyward_music.py                 the size of every song
    python3 skyward_music.py --wav DIR       renders every song (mus_tool's model)
    python3 skyward_music.py --mus DIR       writes every song as song text

The songs are Mark Szlemko's, written for the NES game (Skyward Tobi 4,
MIT License; skyward_nes_songs.py and skyward_nes_instruments.py are his
music/songs.py and music/instruments.py, unchanged).  This script arranges
them for the player: pulse 1 (the melody) on voice 1, pulse 2 (harmony,
chord stabs) on voice 2, the triangle bass on voice 3 and the noise drums
on voice 4; the NES per-frame volume lists become attack / decay / sustain
envelopes, the per-frame arpeggios wave programs, and the engine's
fractional tempo a whole number of frames a row.  The MMC5's echo and pad
channels are left out.  gen_skyward.py puts one song in each course file.

Every song file has the game's sound effect instruments first (SFX), so the
game plays them with mus_sfx whatever the song.

Date: 11/14/2026
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mus_tool as mt
from skyward_nes_songs import SONGS
from skyward_nes_instruments import INSTRUMENTS, DRUMS

SEMI = {'c': 0, 'd': 2, 'e': 4, 'f': 5, 'g': 7, 'a': 9, 'b': 11}
FRAME_MS = 1000 / 59.94
DUTY_PW = {0: 0x20, 1: 0x40, 2: 0x80, 3: 0xC0}

# the game's sound effects: instrument numbers the game's code uses
#   name: (ad, sr, vol, pulse width, wave program)
SFX = [
    ('beep',  0x06, 0x00, 13, 0x80, ['pulse +0', 'end']),
    ('jump',  0x06, 0x00, 12, 0x80, ['pulse +0', 'pulse +2', 'pulse +4', 'pulse +6', 'pulse +8',
                                     'pulse +10', 'pulse +12', 'end']),
    ('noise', 0x06, 0x00, 13, 0x80, ['noise +0', 'noise -2', 'noise -4', 'noise -6', 'end']),
    ('chime', 0x09, 0x00, 13, 0x20, ['pulse +0', '+0', '+0', '+0', 'pulse +5', 'end']),
]
SFX_ID = {s[0]: i for i, s in enumerate(SFX)}

# the drums: wave programs in the SID trackers' way (a noise click, then a
# falling triangle for the body)
#   letter: (name, ad, sr, vol, wave program)
DRUM_INS = {
    'K': ('kick',  0x06, 0x00, 15, ['noise A-5', 'tri C-3', 'tri G-2', 'tri D#2', 'tri C-2', 'tri A-1', 'end']),
    'S': ('snare', 0x05, 0x00, 13, ['noise D-6', 'tri D-3', 'noise C#6', 'noise C-6', 'noise B-5', 'end']),
    'H': ('hat',   0x02, 0x00, 7,  ['noise C-7', 'end']),
    'Q': ('qhat',  0x01, 0x00, 5,  ['noise C-7', 'end']),
    'O': ('ohat',  0x06, 0x00, 7,  ['noise B-6', 'end']),
    'X': ('crash', 0x09, 0x00, 12, ['noise A#6', 'noise G-6', 'end']),
    'T': ('tom',   0x06, 0x00, 13, ['tri G-3', 'tri E-3', 'tri C-3', 'tri A-2', 'tri F-2', 'end']),
    'B': ('bigsn', 0x07, 0x00, 15, ['noise C-6', 'tri C-3', 'noise B-5', 'noise A-5', 'noise G-5', 'end']),
}

# which song a course plays (gen_skyward's course names; the NES levels' own)
COURSE_SONG = dict(
    title='TITLE', meadow='OVERWORLD', bluffs='OVERWORLD', cliffs='SKY', cave='CAVE',
    fort='FORTRESS', shore='OVERWORLD', skyrail='SKY', thorn='OVERWORLD', boughs='OVERWORLD',
    cellar='SKY', keep='FORTRESS', boat='MAP2', trail='DESERT', ridge='DESERT',
    canyon='DESERT', drywell='CAVE', gulch='DESERT', gorge='DESERT', skywalk='SKY',
    mirage='DESERT', fort2='FORTRESS', keep2='FORTRESS', ending='STORY',
    **{'s_' + k: 'STORY' for k in ('o1', 'o2', 'o3', 'o4', 'o5', 'o6', 'e1', 'e2', 'e3')})
# the short tunes every course file carries after its own song: subtunes 1, 2
JINGLES = ['CLEAR', 'DEATH']


def nearest(table, ms):
    return min(range(16), key=lambda i: abs(table[i] - ms) / (table[i] + ms))


def wave_entry(step):
    """'pulse +4' / 'noise C-6' / '+7' / 'end' -> (left, right) (as mus_tool.parse_mus)"""
    if step == 'end':
        return (0xFE, 0)
    toks = step.split()
    w = mt.WAVE_NAMES[toks[0]] if len(toks) > 1 else 0
    r = toks[-1]
    if r[0] in '+-':
        return (w, int(r) & 0x7F)
    return (w, 0x80 | mt.parse_note(r))


class Build:
    """one .SNG: the sound effect instruments, then the songs given as subtunes"""

    def __init__(self, title):
        self.song = mt.Song()
        self.song.title = title
        self.ins = {}           # NES instrument (or drum letter) -> number
        self.sus = {}           # number -> the instrument holds until a key off
        self.waves = {}         # wave program -> entry
        self.pats = {}          # (text, kind) -> number
        for name, ad, sr, vol, pw, prog in SFX:
            self.add_ins(name, ad, sr, vol, pw, prog)

    def wave(self, prog, loop=None):
        key = (tuple(prog), loop)
        if key not in self.waves:
            start = len(self.song.wave) + 1
            self.waves[key] = start
            for s in prog:
                self.song.wave.append(wave_entry(s))
            if loop is not None:
                self.song.wave.append((0xFF, start + loop))
        return self.waves[key]

    def add_ins(self, name, ad, sr, vol, pw, prog, loop=None, vib=0, vdly=0):
        ins = [0] * 16
        ins[mt.I_AD], ins[mt.I_SR], ins[mt.I_VOL], ins[mt.I_PW] = ad, sr, vol, pw
        ins[mt.I_WAVE] = self.wave(prog, loop)
        ins[mt.I_VIB], ins[mt.I_VDLY] = vib, vdly
        ins[mt.I_FLAGS] = mt.F_HARD
        nm = name.upper().encode()[:mt.NAME_LEN]
        ins[mt.I_NAME:mt.I_NAME + mt.NAME_LEN] = list(nm + b' ' * (mt.NAME_LEN - len(nm)))
        self.song.instruments.append(ins)
        self.sus[len(self.song.instruments) - 1] = sr >> 4 != 0
        return len(self.song.instruments) - 1

    def nes_ins(self, name, kind):
        """an NES instrument -> the player's (made the first time it is used)"""
        if (name, kind) in self.ins:
            return self.ins[(name, kind)]
        if kind == 'noise':
            nm, ad, sr, vol, prog = DRUM_INS[name]
            n = self.add_ins(nm, ad, sr, vol, 0x80, prog)
        else:
            d = INSTRUMENTS[name]
            env = d['env']
            if kind == 'tri':
                # the NES triangle has one level: sounding, then off
                on = len(env) - 1 if env[-1] == 0 else 0
                if on == 0 or name.startswith('trid'):
                    ad, sr = 0x00, 0xF1                 # held to the next note
                else:
                    ad, sr = nearest(mt.DEC_MS, 1.5 * on * FRAME_MS), 0x00
                vol, pw, w = 13, 0x80, 'tri'
            else:
                peak = max(env)
                at = env.index(peak)
                last = env[-1]
                if last == 0:
                    dec = (len(env) - 1 - at) * FRAME_MS
                    s = 0
                else:
                    s = max(1, round(15 * last / peak))
                    dec = (len(env) - 1 - at) * FRAME_MS * peak / (peak - last)
                ad = (2 if at else 0) << 4 | nearest(mt.DEC_MS, dec)
                sr = s << 4 | 2
                vol, pw, w = min(15, round(peak * 1.4)), DUTY_PW[d.get('duty', 1)], 'pulse'
            arp = d.get('arp')
            if arp:
                prog = ['%s %+d' % (w, arp[0])] + ['%+d' % a for a in arp[1:]]
                loop = d.get('aloop')
                if loop is None:
                    prog.append('end')
            else:
                prog, loop = ['%s +0' % w, 'end'], None
            vib = (0, 0x31, 0x32, 0x33, 0x35)[d.get('vib', 0)]
            n = self.add_ins(name, ad, sr, vol, pw, prog, loop, vib, d.get('vdel', 0))
        self.ins[(name, kind)] = n
        return n

    def pattern(self, text, kind, ins):
        """one NES pattern (its tokens) for a channel kind, entered with the
        NES instrument ins in force -> (pattern number, the instrument after it)"""
        out = ins
        for tok in text.split():
            if tok.startswith('@'):
                out = tok[1:]
        if text.split()[0].startswith('@'):
            ins = None
        key = (text, kind, ins)
        if key in self.pats:
            return self.pats[key], out
        rows = []
        sent = None             # the instrument number the last note row gave
        ln = None
        for tok in text.split():
            if tok.startswith('@'):
                ins = tok[1:]
                continue
            if ':' in tok:
                tok, l = tok.split(':')
                ln = int(l)
            if tok == '~':
                row = (None, None, None, 0)
            elif tok == 'r':
                # a key off, unless the instrument dies away by itself
                row = ('off', None, None, 0) if sent is None or self.sus[sent] else (None, None, None, 0)
            else:
                if kind == 'noise':
                    n, note = self.nes_ins(tok, kind), 48
                else:
                    m = re.fullmatch(r'([a-g])([#b]?)(\d)', tok)
                    note = int(m.group(3)) * 12 + SEMI[m.group(1)] + {'#': 1, 'b': -1, '': 0}[m.group(2)]
                    n = self.nes_ins(ins, kind)
                row = (note, n if n != sent else None, None, 0)
                sent = n
            rows.append(row)
            rows += [(None, None, None, 0)] * (ln - 1)
        self.song.patterns.append(mt.pack_rows(rows))
        self.pats[key] = len(self.song.patterns) - 1
        return self.pats[key], out

    def subtune(self, name):
        s = SONGS[name]
        kinds = ['pulse', 'pulse', 'tri', 'noise']
        ols = []
        for ch, kind in zip(s['ch'][:4], kinds):
            ol = bytearray()
            loop_at = 0
            trans = None
            ins = None
            for it in ch:
                if it == '|':
                    loop_at = len(ol)
                    trans = None            # the transpose is said again at the loop point
                    continue
                pn, tr = it if isinstance(it, tuple) else (it, 0)
                if tr != trans and kind != 'noise':
                    ol.append(0xA0 + tr)
                    trans = tr
                pat, ins = self.pattern(s['pats'][pn], kind, ins)
                ol.append(pat)
            ol += bytes([mt.O_LOOP, loop_at]) if s['loop'] else bytes([mt.O_STOP])
            ols.append(bytes(ol))
        speed = max(1, round(256 / s['tempo']))
        self.song.subtunes.append((speed, ols))


def build(names, title=None):
    """-> the .SNG bytes with the songs named as subtunes 0 on"""
    b = Build(title or 'SKYWARD ' + names[0])
    for n in names:
        b.subtune(n)
    return b.song.binary()


def course_song(course_name):
    return build([COURSE_SONG[course_name]] + JINGLES)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--wav')
    ap.add_argument('--mus')
    args = ap.parse_args(argv)
    for name in SONGS:
        data = build([name])
        full = build([name] + JINGLES) if name not in JINGLES else data
        print('%-10s %5d bytes of orderlists and patterns (%d with the jingles), %d patterns, speed %d'
              % (name, len(data) - 1280, len(full) - 1280, data[5], data[0x40]))
        if args.wav:
            os.makedirs(args.wav, exist_ok=True)
            mt.render_wav(data, os.path.join(args.wav, name.lower() + '.wav'), 30 if SONGS[name]['loop'] else 8)
        if args.mus:
            os.makedirs(args.mus, exist_ok=True)
            open(os.path.join(args.mus, name.lower() + '.mus'), 'w').write(mt.dump(data))


if __name__ == '__main__':
    main(sys.argv[1:])
