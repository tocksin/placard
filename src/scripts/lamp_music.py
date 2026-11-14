#!/usr/bin/env python3
"""
lamp_music.py - LAMPLIGHTER's songs for the four-voice music player
(placard_mus.masm, docs/sound/MUSIC.md), one for each area

    python3 lamp_music.py                 the size of every song
    python3 lamp_music.py --wav DIR       renders every subtune (mus_tool's model)
    python3 lamp_music.py --mus DIR       writes every song as song text

gen_lamp.py puts area n's song (area_song(n)) at the start of LAMP/An.TS,
so it is read with the area's tiles.  Every song has the same instruments
(INSTRUMENTS), the sound effects' at E (noise) and F (a fading note), none
past F and no custom waves (gen_lamp.py puts player code in those pages),
and is at most 8 pages.  Subtune 0 plays in the area; area 0's subtune 1 is
the title's, area 7's subtune 1 the ending's.

The voices: 1 bass, 2 drums, 3 the tune, 4 chords (a sound effect takes
voice 4's place while it lasts, so it carries the part that can drop out).

All the music here is original, written for this game.

Date: 11/14/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mus_tool as mt   # noqa: E402

SONG_MAX = 8 * 256

INSTRUMENTS = '''
wave  bass    pulse +0, end
wave  kick    noise C-6, pulse C-3, pulse G#2, pulse E-2, pulse C-2, pulse A-1, pulse F-1, end
wave  snare   noise D-6, pulse D-3, noise C#6, noise C-6, noise B-5, noise A#5, end
wave  hat     noise C-7, end
wave  saw     saw +0, end
wave  minor   pulse +0, +3, +7, loop 0
wave  major   pulse +0, +4, +7, loop 0
wave  tri     tri +0, end
wave  bell    pulse +0, +12, +0, end
wave  wind    noise +0, end
wave  maj7    pulse +0, +7, +11, +4, loop 0
wave  pluck   pulse +0, end
wave  fifth   saw +0, +7, loop 0
wave  sfxn    noise +0, end
wave  sfxb    pulse +0, end

pulse bass    set 20, 40x+2, 40x-2, loop 1
pulse chord   set 40, 60x+1, 60x-1, loop 1
pulse bell    set 12, end
pulse pluck   set 10, 10x+4, 20x-1, end
pulse sfxb    set 30, end

instrument $0 bass    ad=08 sr=A5 wave=bass   pulse=bass  hr
instrument $1 kick    ad=08 sr=00 wave=kick   hr
instrument $2 snare   ad=06 sr=00 vol=11 wave=snare hr
instrument $3 hat     ad=03 sr=00 vol=7  wave=hat   hr
instrument $4 lead    ad=0A sr=A8 vol=12 wave=saw    vib=34 vdelay=12
instrument $5 minor   ad=26 sr=79 vol=9  wave=minor  pulse=chord
instrument $6 major   ad=26 sr=79 vol=9  wave=major  pulse=chord
instrument $7 tripl   ad=09 sr=06 vol=12 wave=tri
instrument $8 bell    ad=08 sr=05 vol=10 wave=bell   pulse=bell hr
instrument $9 trilead ad=1A sr=B8 vol=14 wave=tri    vib=24 vdelay=16
instrument $A wind    ad=8A sr=F8 vol=5  wave=wind
instrument $B maj7    ad=48 sr=8A vol=8  wave=maj7   pulse=chord
instrument $C pluck   ad=07 sr=46 vol=12 wave=pluck  pulse=pluck hr
instrument $D fifth   ad=05 sr=86 vol=11 wave=fifth
instrument $E sfxnoise ad=02 sr=03 wave=sfxn hr
instrument $F sfxbeep  ad=04 sr=05 wave=sfxb pulse=sfxb hr
'''

BASS, KICK, SNARE, HAT, LEAD, MINOR, MAJOR, TRIPL, BELL, TRILEAD, WIND, MAJ7, PLUCK, FIFTH = range(14)


# ---------------------------------------------------------------------------
# writing patterns: a part is a list of (note, rows) or (note, rows, ins),
# note 'C-4' / '.' (a rest: nothing new) / '=' (key off)
# ---------------------------------------------------------------------------
def rows_of(part, ins):
    """-> pattern text lines; ins: the instrument of notes that name none"""
    out, cur = [], None
    for item in part:
        note, n = item[0], item[1]
        i = item[2] if len(item) > 2 else ins
        if note == '.':
            out.append('  ...')
        elif note == '=':
            out.append('  ===')
        else:
            if i != cur:
                out.append('  %s %02X' % (note, i))
                cur = i
            else:
                out.append('  %s' % note)
        out += ['  ...'] * (n - 1)
    return out


def length(part):
    return sum(item[1] for item in part)


def notes(text, step, ins=None):
    """'A-4 D-5 . F-5' -> [(note, step), ...] (a quick way to write even rows)"""
    return [(t, step) + ((ins,) if ins is not None else ()) for t in text.split()]


def drums(text):
    """'K . H . S . H .' one row each: K kick, S snare, H hat"""
    m = {'K': KICK, 'S': SNARE, 'H': HAT}
    return [('.', 1) if t == '.' else ('C-4', 1, m[t]) for t in text.split()]


class Song:
    def __init__(self, title):
        self.title = title
        self.pats = []          # [(key, lines)]
        self.index = {}
        self.subs = []

    def pat(self, part, ins, rows=None):
        """the pattern's number (one pattern for the same rows)"""
        lines = rows_of(part, ins)
        if rows is not None:
            assert length(part) == rows, (self.title, length(part), rows)
        key = tuple(lines)
        if key not in self.index:
            self.index[key] = len(self.pats)
            self.pats.append(lines)
        return self.index[key]

    def sub(self, speed, voices):
        """voices: 4 lists of pattern numbers, transposes (+n / -n as
        strings) and 'loop' (where the loop starts: the next entry)"""
        self.subs.append((speed, voices))

    def text(self):
        out = ['title "%s"' % self.title, INSTRUMENTS]
        for i, lines in enumerate(self.pats):
            out.append('pattern $%X' % i)
            out += lines
        for s, (speed, voices) in enumerate(self.subs):
            out.append('subtune %d speed=%d' % (s, speed))
            for v, ol in enumerate(voices):
                toks, at, loop = [], 0, 0
                for e in ol:
                    if e == 'loop':
                        loop = at
                        continue
                    toks.append(e if isinstance(e, str) else '%02X' % e)
                    at += 1
                out.append('order %d.%d: %s loop %d' % (s, v + 1, ' '.join(toks), loop))
        return '\n'.join(out) + '\n'


# ---------------------------------------------------------------------------
# area 0: the Wellshaft (A minor, slow, a long way down) and the title
# (D minor, the lamp's theme)
# ---------------------------------------------------------------------------
def wellshaft():
    s = Song('LAMPLIGHTER: THE WELLSHAFT')
    rest32 = s.pat([('.', 32)], LEAD)
    # the hub: low pulse bass, a triangle arpeggio, a few falling notes
    hb1 = s.pat([('A-1', 12), ('=', 4), ('F-1', 12), ('=', 4)], BASS, 32)
    hb2 = s.pat([('G-1', 12), ('=', 4), ('E-1', 12), ('=', 4)], BASS, 32)
    hd = s.pat(drums('K . . . . . . . H . . . . . . . . . . . . . . . H . . . . . . .'), KICK, 32)
    ha1 = s.pat(notes('A-3 C-4 E-4 A-4 E-4 C-4 B-3 C-4  F-3 A-3 C-4 F-4 C-4 A-3 G-3 A-3', 2), TRIPL, 32)
    ha2 = s.pat(notes('G-3 B-3 D-4 G-4 D-4 B-3 A-3 B-3  E-3 G#3 B-3 E-4 B-3 G#3 F#3 G#3', 2), TRIPL, 32)
    hl1 = s.pat([('.', 16), ('E-5', 4), ('D-5', 2), ('C-5', 2), ('B-4', 6), ('=', 2)], TRILEAD, 32)
    hl2 = s.pat([('.', 16), ('C-5', 4), ('B-4', 2), ('A-4', 2), ('G#4', 6), ('=', 2)], TRILEAD, 32)
    hl3 = s.pat([('A-4', 4), ('C-5', 4), ('E-5', 8), ('F-5', 4), ('E-5', 2), ('D-5', 2), ('C-5', 6), ('=', 2)], TRILEAD, 32)
    hl4 = s.pat([('B-4', 4), ('D-5', 4), ('G-5', 8), ('E-5', 8), ('.', 6), ('=', 2)], TRILEAD, 32)
    s.sub(8, [[hb1, hb2],
              [hd],
              [rest32, rest32, hl1, hl2, hl3, hl4, 'loop', rest32, hl1, rest32, hl2, hl3, hl4],
              [ha1, ha2]])
    # the title: the lamp's theme
    tb1 = s.pat(notes('D-2 D-3 D-2 D-3 D-2 D-3 D-2 D-3 A#1 A#2 A#1 A#2 A#1 A#2 A#1 A#2', 2), BASS, 32)
    tb2 = s.pat(notes('F-2 F-3 F-2 F-3 F-2 F-3 F-2 F-3 C-2 C-3 C-2 C-3 C-2 C-3 C-2 C-3', 2), BASS, 32)
    tb3 = s.pat(notes('G-2 G-3 G-2 G-3 G-2 G-3 G-2 G-3 A-1 A-2 A-1 A-2 A-1 A-2 C#2 E-2', 2), BASS, 32)
    td0 = s.pat(drums('K . . . H . . . K . . . H . . . K . . . H . . . K . . . H . H .'), KICK, 32)
    td1 = s.pat(drums('K . . . H . . . S . . . H . . . K . . K H . . . S . . . H . K .'), KICK, 32)
    td2 = s.pat(drums('K . . . H . . . S . . . H . . . K . . K H . . . S . S . S S S S'), KICK, 32)
    ta1 = s.pat([('D-4', 16, MINOR), ('A#3', 16, MAJOR)], MINOR, 32)
    ta2 = s.pat([('F-4', 16, MAJOR), ('C-4', 16, MAJOR)], MAJOR, 32)
    ta3 = s.pat([('G-3', 16, MINOR), ('A-3', 16, MAJOR)], MINOR, 32)
    tl1 = s.pat([('A-4', 4), ('D-5', 4), ('F-5', 4), ('E-5', 2), ('D-5', 2),
                 ('F-5', 6), ('E-5', 2), ('D-5', 4), ('A#4', 4)], LEAD, 32)
    tl2 = s.pat([('C-5', 4), ('F-5', 4), ('A-5', 6), ('G-5', 2),
                 ('G-5', 8), ('E-5', 4), ('C-5', 4)], LEAD, 32)
    tl3 = s.pat([('A-4', 4), ('D-5', 4), ('F-5', 4), ('A-5', 4),
                 ('A#5', 6), ('A-5', 2), ('G-5', 4), ('F-5', 4)], LEAD, 32)
    tl4 = s.pat([('G-5', 4), ('A#5', 4), ('D-6', 6), ('C-6', 2),
                 ('A-5', 12), ('=', 4)], LEAD, 32)
    s.sub(6, [[tb1, 'loop', tb1, tb2, tb1, tb3],
              [td0, 'loop', td1, td1, td1, td2],
              [rest32, 'loop', tl1, tl2, tl3, tl4],
              [ta1, 'loop', ta1, ta2, ta1, ta3]])
    return s


# ---------------------------------------------------------------------------
# area 1: the Glasswort Gardens (E dorian, plucked, light on its feet)
# ---------------------------------------------------------------------------
def gardens():
    s = Song('LAMPLIGHTER: GLASSWORT GARDENS')
    b1 = s.pat(notes('E-2 . E-3 . B-1 . E-2 E-3 A-1 . A-2 . E-2 . A-1 C#2', 2), BASS, 32)
    b2 = s.pat(notes('E-2 . E-3 . B-1 . E-2 E-3 D-2 . D-3 . A-1 . D-2 F#2', 2), BASS, 32)
    d1 = s.pat(drums('K . H . S . H . K . K . S . H H'), KICK, 16)
    d2 = s.pat(drums('K . H . S . H . K . K . S S S S'), KICK, 16)
    a1 = s.pat([('E-4', 16, MINOR), ('A-3', 16, MAJOR)], MINOR, 32)
    a2 = s.pat([('E-4', 16, MINOR), ('D-4', 16, MAJOR)], MINOR, 32)
    l1 = s.pat([('B-4', 2), ('E-5', 2), ('F#5', 2), ('G-5', 4), ('F#5', 2), ('E-5', 4),
                ('C#5', 2), ('E-5', 2), ('A-5', 4), ('G-5', 2), ('F#5', 2), ('E-5', 4)], PLUCK, 32)
    l2 = s.pat([('G-5', 2), ('F#5', 2), ('E-5', 2), ('D-5', 2), ('E-5', 4), ('B-4', 4),
                ('A-4', 2), ('D-5', 2), ('F#5', 4), ('E-5', 2), ('D-5', 2), ('A-4', 4)], PLUCK, 32)
    l3 = s.pat([('E-5', 6), ('G-5', 2), ('B-5', 8), ('A-5', 4), ('G-5', 2), ('F#5', 2), ('E-5', 8)], LEAD, 32)
    l4 = s.pat([('D-5', 6), ('F#5', 2), ('A-5', 8), ('G-5', 4), ('F#5', 4), ('D-5', 4), ('.', 2), ('=', 2)], LEAD, 32)
    s.sub(7, [[b1, b2],
              [d1, d1, d1, d2],
              [l1, l2, l1, l2, l3, l4, l3, l4],
              [a1, a2]])
    return s


# ---------------------------------------------------------------------------
# area 3: the Slagworks (C, phrygian: hammering, hot)
# ---------------------------------------------------------------------------
def slagworks():
    s = Song('LAMPLIGHTER: THE SLAGWORKS')
    b1 = s.pat(notes('C-2 . C-2 C-3 . C-2 C#2 . C-2 . C-2 C-3 . G-1 A#1 .', 1), BASS, 16)
    d1 = s.pat(drums('K . . K S . K . K . . K S . S S'), KICK, 16)
    d2 = s.pat(drums('K . . K S . K . K . K K S S S S'), KICK, 16)
    hit = s.pat([('C-6', 6), ('C-6', 6), ('C-6', 4)], BELL, 16)
    hit2 = s.pat([('C-6', 6), ('C#6', 6), ('G-5', 4)], BELL, 16)
    l1 = s.pat([('C-4', 4), ('D#4', 2), ('C#4', 2), ('C-4', 8),
                ('G-4', 4), ('F-4', 2), ('D#4', 2), ('C#4', 8)], FIFTH, 32)
    l2 = s.pat([('C-4', 4), ('D#4', 2), ('F-4', 2), ('G-4', 8),
                ('G#4', 4), ('G-4', 2), ('F-4', 2), ('G-4', 6), ('=', 2)], FIFTH, 32)
    l3 = s.pat([('C-5', 8), ('A#4', 4), ('G#4', 4), ('G-4', 8), ('C#5', 8)], LEAD, 32)
    l4 = s.pat([('C-5', 8), ('D#5', 4), ('C#5', 4), ('C-5', 12), ('=', 4)], LEAD, 32)
    s.sub(5, [[b1, b1, b1, b1, '+5', b1, b1, '+0', b1, b1],
              [d1, d1, d1, d2],
              [l1, l2, l3, l4],
              [hit, hit, hit, hit2]])
    return s


# ---------------------------------------------------------------------------
# area 5: the Brine Vaults (B minor: slow, dripping, under water)
# ---------------------------------------------------------------------------
def brine():
    s = Song('LAMPLIGHTER: THE BRINE VAULTS')
    b1 = s.pat([('B-1', 14), ('=', 2), ('G-1', 14), ('=', 2)], BASS, 32)
    b2 = s.pat([('D-2', 14), ('=', 2), ('F#1', 14), ('=', 2)], BASS, 32)
    a1 = s.pat(notes('B-3 D-4 F#4 B-4 F#4 D-4 B-3 F#3 G-3 B-3 D-4 G-4 D-4 B-3 G-3 D-3', 2), TRIPL, 32)
    a2 = s.pat(notes('D-4 F#4 A-4 D-5 A-4 F#4 D-4 A-3 F#3 A#3 C#4 F#4 C#4 A#3 F#3 C#3', 2), TRIPL, 32)
    drip = s.pat([('F#6', 10, BELL), ('B-5', 6, BELL), ('.', 8), ('C#6', 8, BELL)], BELL, 32)
    drip2 = s.pat([('.', 4), ('D-6', 12, BELL), ('A-5', 10, BELL), ('.', 6)], BELL, 32)
    l1 = s.pat([('F#5', 8), ('E-5', 4), ('D-5', 4), ('D-5', 8), ('B-4', 8)], TRILEAD, 32)
    l2 = s.pat([('A-4', 6), ('B-4', 2), ('D-5', 8), ('C#5', 12), ('=', 4)], TRILEAD, 32)
    rest = s.pat([('.', 32)], TRILEAD)
    s.sub(9, [[b1, b2],
              [drip, drip2],
              [rest, rest, l1, l2, 'loop', l1, l2, rest, rest],
              [a1, a2]])
    return s


# ---------------------------------------------------------------------------
# area 7: the Orrery (G lydian: clockwork and starlight) and the ending
# (the title's theme in D major)
# ---------------------------------------------------------------------------
def orrery():
    s = Song('LAMPLIGHTER: THE ORRERY')
    b1 = s.pat(notes('G-1 . . . G-2 . . . G-1 . . . G-2 . . . A-1 . . . A-2 . . . A-1 . . . A-2 . E-2 .', 1), BASS, 32)
    b2 = s.pat(notes('B-1 . . . B-2 . . . B-1 . . . B-2 . . . A-1 . . . A-2 . . . A-1 . . . C#2 . E-2 .', 1), BASS, 32)
    tick = s.pat(drums('K . H . H . H . H . H . H . H . K . H . H . H . H . H . H . H H'), KICK, 32)
    c1 = s.pat([('G-3', 16, MAJ7), ('A-3', 16, MAJOR)], MAJ7, 32)
    c2 = s.pat([('B-3', 16, MINOR), ('A-3', 16, MAJOR)], MINOR, 32)
    l1 = s.pat([('D-5', 4), ('F#5', 4), ('A-5', 4), ('C#6', 4), ('B-5', 8), ('A-5', 4), ('E-5', 4)], BELL, 32)
    l2 = s.pat([('F#5', 8), ('D-5', 4), ('B-4', 4), ('C#5', 12), ('E-5', 4)], BELL, 32)
    l3 = s.pat([('B-4', 4), ('D-5', 4), ('F#5', 8), ('E-5', 4), ('C#5', 4), ('A-4', 8)], TRILEAD, 32)
    l4 = s.pat([('G-4', 4), ('B-4', 4), ('D-5', 8), ('C#5', 8), ('.', 6), ('=', 2)], TRILEAD, 32)
    s.sub(7, [[b1, b2],
              [tick],
              [l1, l2, l1, l2, l3, l4],
              [c1, c2]])
    # the ending: the lamp burns again
    eb1 = s.pat(notes('D-2 D-3 D-2 D-3 D-2 D-3 D-2 D-3 G-1 G-2 G-1 G-2 G-1 G-2 G-1 G-2', 2), BASS, 32)
    eb2 = s.pat(notes('D-2 D-3 D-2 D-3 D-2 D-3 D-2 D-3 A-1 A-2 A-1 A-2 A-1 A-2 C#2 E-2', 2), BASS, 32)
    ed = s.pat(drums('K . . . H . . . S . . . H . . . K . . K H . . . S . . . H . K .'), KICK, 32)
    ea1 = s.pat([('D-4', 16, MAJOR), ('G-3', 16, MAJOR)], MAJOR, 32)
    ea2 = s.pat([('D-4', 16, MAJOR), ('A-3', 16, MAJOR)], MAJOR, 32)
    el1 = s.pat([('A-4', 4), ('D-5', 4), ('F#5', 4), ('E-5', 2), ('D-5', 2),
                 ('G-5', 6), ('F#5', 2), ('E-5', 4), ('D-5', 4)], LEAD, 32)
    el2 = s.pat([('F#5', 4), ('A-5', 4), ('D-6', 6), ('C#6', 2),
                 ('B-5', 8), ('A-5', 4), ('E-5', 4)], LEAD, 32)
    el3 = s.pat([('A-5', 4), ('C#6', 4), ('E-6', 6), ('D-6', 2),
                 ('D-6', 12), ('=', 4)], LEAD, 32)
    s.sub(6, [[eb1, eb2, eb1, eb2],
              [ed],
              [el1, el2, el1, el3],
              [ea1, ea2]])
    return s


# ---------------------------------------------------------------------------
# the keepers' dens: fast, low, with a riff of their own
# ---------------------------------------------------------------------------
def den(title, speed, riff, stab, lead1, lead2, chords, drum1, drum2):
    s = Song('LAMPLIGHTER: ' + title)
    b = s.pat(notes(riff, 1), BASS, 16)
    d1 = s.pat(drums(drum1), KICK, 16)
    d2 = s.pat(drums(drum2), KICK, 16)
    l1 = s.pat(lead1, LEAD, 32)
    l2 = s.pat(lead2, LEAD, 32)
    st = s.pat(stab, FIFTH, 32)
    c = s.pat(chords, MINOR, 32)
    s.sub(speed, [[b],
                  [d1, d1, d1, d2],
                  [st, st, l1, l2],
                  [c]])
    return s


def bramblejaw():
    return den("BRAMBLEJAW'S DEN", 5,
               'E-2 . E-2 E-3 . E-2 G-2 . E-2 . E-2 E-3 A#2 . B-2 .',
               [('E-4', 2), ('.', 6), ('E-4', 2), ('.', 2), ('G-4', 4), ('A#4', 2), ('.', 6), ('B-4', 4), ('=', 4)],
               [('E-5', 4), ('G-5', 4), ('A#5', 4), ('B-5', 4), ('A#5', 4), ('G-5', 4), ('E-5', 8)],
               [('D-5', 4), ('E-5', 4), ('G-5', 4), ('F#5', 4), ('E-5', 12), ('=', 4)],
               [('E-4', 16, MINOR), ('C-4', 16, MAJOR)],
               'K . . . S . . K K . K . S . . .', 'K . . . S . . K K . K . S S S S')


def clinker():
    return den("CLINKER'S FORGE", 5,
               'F-1 F-2 . F-1 . F-2 F#1 . F-1 F-2 . F-1 C-2 . B-1 .',
               [('F-4', 2), ('.', 2), ('F-4', 2), ('.', 2), ('F#4', 4), ('.', 4), ('C-5', 4), ('B-4', 4), ('.', 4), ('=', 4)],
               [('F-5', 6), ('G#5', 2), ('F#5', 4), ('F-5', 4), ('C-5', 8), ('B-4', 8)],
               [('F-5', 4), ('G#5', 4), ('C-6', 8), ('B-5', 4), ('F#5', 4), ('F-5', 4), ('=', 4)],
               [('F-4', 16, MINOR), ('F#4', 16, MAJOR)],
               'K . K . S . K . K . K . S . K K', 'K K K . S . K . K K K . S S S S')


def gulper():
    return den("OLD GULPER'S CISTERN", 6,
               'G-1 . . G-1 G-2 . D-2 . G-1 . . G-1 A#1 . A-1 .',
               [('G-3', 6), ('.', 2), ('A#3', 4), ('A-3', 4), ('D-4', 8), ('C#4', 4), ('=', 4)],
               [('G-4', 8), ('A#4', 4), ('A-4', 4), ('D-5', 8), ('C#5', 8)],
               [('D-5', 4), ('C-5', 4), ('A#4', 4), ('A-4', 4), ('G-4', 12), ('=', 4)],
               [('G-3', 16, MINOR), ('D#4', 16, MAJOR)],
               'K . . . S . . . K . K . S . . .', 'K . . . S . . . K . K . S . S S')


def snuffer():
    s = Song("LAMPLIGHTER: THE SNUFFER'S VAULT")
    b1 = s.pat(notes('C-2 C-2 C-3 C-2 . C-2 D#2 . C-2 C-2 C-3 C-2 . F#2 G-2 .', 1), BASS, 16)
    d1 = s.pat(drums('K . H K S . H . K K H . S . H H'), KICK, 16)
    d2 = s.pat(drums('K . K K S . K . K K K . S S S S'), KICK, 16)
    st = s.pat([('C-4', 2), ('.', 2), ('C-4', 2), ('.', 2), ('D#4', 4), ('F#4', 4),
                ('G-4', 2), ('.', 2), ('G-4', 2), ('.', 2), ('F#4', 4), ('D#4', 4)], FIFTH, 32)
    l1 = s.pat([('C-5', 4), ('D#5', 4), ('G-5', 4), ('F#5', 4), ('D#5', 4), ('C-5', 4), ('G-4', 8)], LEAD, 32)
    l2 = s.pat([('G#4', 4), ('C-5', 4), ('D#5', 4), ('D-5', 4), ('C-5', 8), ('B-4', 8)], LEAD, 32)
    l3 = s.pat([('C-6', 8), ('G-5', 4), ('F#5', 4), ('G-5', 8), ('D#5', 8)], LEAD, 32)
    l4 = s.pat([('D-5', 4), ('D#5', 4), ('F-5', 4), ('G-5', 4), ('C-5', 12), ('=', 4)], LEAD, 32)
    c1 = s.pat([('C-4', 16, MINOR), ('G#3', 16, MAJOR)], MINOR, 32)
    c2 = s.pat([('F-3', 16, MINOR), ('G-3', 16, MAJOR)], MINOR, 32)
    s.sub(5, [[b1, b1, b1, b1, '+8', b1, b1, '+5', b1, '+7', b1, '+0'],
              [d1, d1, d1, d2],
              [st, st, l1, l2, l3, l4],
              [c1, c2]])
    return s


SONGS = [wellshaft, gardens, bramblejaw, slagworks, clinker, brine, gulper, orrery, snuffer]


def area_text(n):
    """the song text of area n"""
    return SONGS[n]().text()


def area_song(n):
    """the .SNG bytes of area n's song"""
    song = mt.parse_mus(area_text(n))
    assert len(song.instruments) <= 16 and not song.custom
    b = song.binary()
    assert len(b) <= SONG_MAX, 'area %d: the song is %d bytes' % (n, len(b))
    return b


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--wav')
    ap.add_argument('--mus')
    ap.add_argument('--seconds', type=float, default=40)
    args = ap.parse_args(argv)
    for n, f in enumerate(SONGS):
        b = area_song(n)
        print('area %d %-38s %5d bytes (%d pages), %d subtunes' % (n, f().title, len(b), (len(b) + 255) // 256, b[4]))
        if args.mus:
            os.makedirs(args.mus, exist_ok=True)
            open(os.path.join(args.mus, 'area%d.mus' % n), 'w').write(area_text(n))
        if args.wav:
            os.makedirs(args.wav, exist_ok=True)
            for s in range(b[4]):
                mt.render_wav(b, os.path.join(args.wav, 'area%d_%d.wav' % (n, s)), args.seconds, sub=s)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
