# skyward_nes_songs.py - Skyward Tobi 4's music/songs.py, copied unchanged below
# this header (github.com/Zebshine/skyward-tobi-4, v0.9.8) for
# skyward_music.py, which arranges the songs for the Placard's music player.
#
# Copyright (c) 2026 Mark Szlemko.  MIT License (the notice is in
# gen_skyward.py).
#
# Date: 11/14/2026
# SKYWARD music. All melodies are original compositions for this project.
# Tick = one 16th note unless noted. tempo T: ticks/frame = T/256
#   (T = BPM * 4 * 256 / 3600 for 16th-note ticks).
# Pulse notes are written pitch; triangle notes are SOUNDING pitch.
#
# ONE THEME, SPRINKLED (Kondo's SMW lesson, without saturating). The hook is
# the first two bars of SONG_OVERWORLD, in scale degrees:
#     1 1 4 6 5 . . 3 | 4 2 3 1          (short short short short LONG, pickup,
#                                           then a V7->I tail)
# TITLE (fanfare into the theme) and FORTRESS (minor march) re-arrange this
# same line; their B sections quote it in the relative minor. SKY ("Above the
# Clouds") and MAP ("Island Stroll") are their own tunes.
#
# TEMPO LOCKS (60 fps; full jump = 40 frames, run = 3.5 px/frame):
#   T=51  179.3 BPM 16ths: tick 5.02 fr, half note = 40.2 fr = one jump,
#         a 16th ~ one 16-px tile at run speed (5.0 vs 4.6 fr)   OVERWORLD
#   T=51  same tick, written as 32nd notes: 4/4 at 89.6 BPM, beat = 8 ticks
#         = 40.2 fr = one jump, bar = 4 jumps                     FORTRESS
#   T=38  132 BPM 3/4: bar = 12 ticks = 80.8 fr = two jumps           SKY
#   T=31  108 BPM: quarter = 33 fr ~ one 32-frame map-walk cycle      MAP
#   T=32  112.5 BPM: tick = exactly 8 fr, quarter = 32 fr = one PUSH START
#         blink phase (toggles every 32 fr)                          TITLE
# hurry mode (music_hurry): rate = T + T/4, so 51 -> 63, 38 -> 47 (+23..25%).
#
# MMC5 LAYER (optional 5th/6th channel entries in ch): pulse 3 echoes the
# lead (dict(echo=(delay_ticks, 'echo'))), pulse 4 holds a quiet pad on each
# chord's 3rd. Used on the theme arrangements (TITLE, OVERWORLD, FORTRESS),
# BOSS and (echo only) SKY. Echo delays are ODD tick counts and the pad runs
# one tick behind the chords on purpose: every APU part moves on even ticks,
# so the extra channels do their work on ticks that are otherwise idle and
# the worst-case sound_update frame barely grows.
def bpm(b, per_beat=4):
    return round(b * per_beat * 256 / 3600)

SONGS = {}

import re as _re
def down(text, octaves=1):
    """Oct 17 night: move a melodic line down by whole octaves. The leads used to sit in octaves
    5-6 (an octave above the reference Nintendo scores, whose leads live around G3-E5) and read as
    shrill on the 12.5/25 % pulses."""
    return _re.sub(r'\b([a-g](?:#|b)?)(\d)\b', lambda m: m.group(1) + str(int(m.group(2)) - octaves), text)

def down_pats(pats, names, octaves=1):
    for n in names:
        pats[n] = down(pats[n], octaves)

# chord roots as transposes of a c4 (pulse) / c2 (triangle) pattern, kept in
# a one-octave window G..F# so stabs sit below the melody
T = {'C': 0, 'Db': 1, 'D': 2, 'Eb': 3, 'E': 4, 'F': 5, 'F#': 6,
     'G': -5, 'Ab': -4, 'A': -3, 'Bb': -2, 'B': -1}

def prog(spec, name, pats, maker):
    """Expand 'F:4 Bbm:8 C7:4 ...' into order entries using per-length
    patterns named f'{name}{q}{len}' (q = M or m), creating them via maker(q, n)."""
    out = []
    for tok in spec.split():
        ch, n = tok.split(':')
        n = int(n)
        if ch == 'r':                       # silence for n ticks
            pats[f'{name}r{n}'] = f'r:{n}'
            out.append((f'{name}r{n}', 0))
            continue
        q = 'm' if ch.endswith('m') else 'M'
        root = ch.rstrip('m7')
        pn = f'{name}{q}{n}'
        if pn not in pats:
            pats[pn] = maker(q, n)
        out.append((pn, T[root]))
    return out

# ---- offbeat stabs: rest on the beat, chord on the "and" (any length, 4-tick beats)
def stab(q, n):
    return f'@arp{q}s ' + ' '.join(['r:2 c4'] * (n // 4))
# ---- bouncing root-fifth-octave bass in 8ths
def bounce(q, n):
    cyc = ['c2', 'g2', 'c3', 'g2']
    return '@trid9 ' + ' '.join(f'{cyc[i % 4]}:2' for i in range(n // 2))
# ---- MMC5 pulse 4: sustained pad on the chord's 3rd (below the melody)
def pad(q, n):
    # the pad steps one tick behind the chords (CPU spreading, see the MMC5 note above), so it
    # rests on the chord's last tick: otherwise the old 3rd rings into every new downbeat
    return f'@pad {"e3" if q == "M" else "eb3"}:{n - 1} r:1'
ECHO = lambda delay: dict(echo=(delay, 'echo'))

# ---- Oct 18 night: MMC5 pulse 4 doubles the bass an octave up as a short pluck (instrument
# 'pslap'), so the bass line is heard on small speakers and every note has an attack, the way a
# bass guitar's pick does. Built from the triangle's own order list, so it always fits.
def _slapify(text):
    out, inst_done = [], False
    for tok in text.split():
        if tok.startswith('@'):
            if not inst_done:
                out.append('@pslap'); inst_done = True
            continue
        if not inst_done:
            out.append('@pslap'); inst_done = True
        note, _, ln = tok.partition(':')
        if note not in ('r', '~'):
            note = note[:-1] + str(int(note[-1]) + 1)
        out.append(note + (':' + ln if ln else ''))
    return ' '.join(out)

def p4_double(order, pats):
    out = []
    for it in order:
        if it == '|':
            out.append('|'); continue
        pn, tr = it if isinstance(it, tuple) else (it, 0)
        if 'p4_' + pn not in pats:
            pats['p4_' + pn] = _slapify(pats[pn])
        out.append(('p4_' + pn, tr))
    return out
# ---- march: bass "oom" on each beat (8 ticks), chord "pah" on the off 8th
def march_stab(q, n):
    return f'@arp{q}s ' + ' '.join(['r:4 c3:2 r:2'] * (n // 8))   # octave 3: below the (lowered) lead
def march_bass(q, n):
    cyc = ['c2:4 c3:2 c2:2', 'g1:4 c2:2 g1:2']       # Oct 18 night: no repeated pitch (the bass is held now)
    return '@trid16 ' + ' '.join(cyc[i % 2] for i in range(n // 8))
# ---- fanfare (title): sustained block chords on the beat
def block(q, n):
    return f'@arp{q} ' + ' '.join(['c3:4'] * (n // 4))   # octave 3: below the (lowered) lead
def oct_bass(q, n):
    return '@tris ' + ' '.join(['c2:2 c3:2'] * (n // 4))

# ================================================================ OVERWORLD
# F major, T=51 (179.3 BPM), 4/4, 16 ticks/bar. Intro 2 bars, then
# A(8) A'(8) B(8) A(8) = 32 bars, 42.9 s loop. The hook opens A every time.
P = {}
P.update(
    i='@lead r:4 g5:2 a5:2 bb5:2 c6:2 d6:2 e6:2 f6:8 r:8',
    # hook x2: bars 1-4 (second time the tail opens on the 2nd degree)
    a1='@lead f5:2 f5:2 bb5:2 d6:2 c6:6 a5:2 '
       'bb5:2 g5:2 a5:4 f5:4 r:4 '
       'f5:2 f5:2 bb5:2 d6:2 c6:6 a5:2 '
       'd6:2 c6:2 bb5:4 g5:4 r:4',
    # answer, bars 5-6: a climb through Bb and C
    a2='d6:2 c6:2 bb5:2 c6:2 d6:4 f6:4 '
       'e6:2 d6:2 c6:2 d6:2 e6:4 g6:4',
    # ending 1 (bars 7-8): run down and land home
    e1='f6:2 e6:2 d6:2 c6:2 bb5:2 a5:2 g5:2 a5:2 '
       'g5:2 e5:2 f5:8 r:4',
    # ending 2 (bars 7-8): hangs on the 5th, pointing at the minor B section
    e2='f6:2 e6:2 d6:2 c6:2 bb5:2 a5:2 g5:4 '
       'a5:2 g5:2 c6:8 r:4',
    # B: hook in D minor, then in A minor, then a soaring phrase and turnaround
    b1='d5:2 d5:2 g5:2 bb5:2 a5:6 f5:2 '
       'g5:2 e5:2 f5:4 d5:4 r:4 '
       'a5:2 a5:2 d6:2 f6:2 e6:6 c6:2 '
       'd6:2 b5:2 c6:4 a5:4 r:4',
    b2='@leadv f6:6 d6:2 bb5:4 d6:4 '
       'e6:6 c6:2 g5:4 c6:4 '
       'd6:4 f6:2 e6:2 d6:4 c6:2 bb5:2 '
       'g5:2 e5:2 g5:2 c6:2 e6:4 r:4 @lead',
    # harmony for b2 (3rds/4ths below), pulse 2
    hb='@harm2 d6:6 bb5:2 f5:4 bb5:4 '
       'c6:6 g5:2 e5:4 g5:4 '
       'a5:4 d6:2 c6:2 bb5:4 a5:2 g5:2 '
       'e5:2 c5:2 e5:2 g5:2 c6:4 r:4',
    hi='@harm r:4 e5:2 f5:2 g5:2 a5:2 bb5:2 c6:2 a5:8 r:8',
    # the hook in parallel thirds (pulse 2, bars 1-4 of every A): a brass duet, the way SMB3's
    # overworld pairs its pulses; the stabs come back for the wind-up and the run home
    ha='@harm d5:2 d5:2 g5:2 bb5:2 a5:6 f5:2 '
       'g5:2 e5:2 f5:4 d5:4 r:4 '
       'd5:2 d5:2 g5:2 bb5:2 a5:6 f5:2 '
       'bb5:2 a5:2 g5:4 e5:4 r:4',
    bi='@tris r:4 c2:2 c2 c2 c2 c2 c2 @tri f2:8 r:8',
    # drums (tick = 5 fr): 1-tick kicks are 5-frame blips
    d1='K:2 H:2 S:2 H:2 K:2 K:2 S:2 H:2',
    df='K:2 H:2 S:2 H:2 S:1 S S:2 T:2 T:2',
    dx='X:2 H:2 S:2 H:2 K:2 K:2 S:2 H:2',
    di='K:4 H:2 H H H H H X:4 r:4 S:1 S S S S S S S',
)
down_pats(P, ['i', 'a1', 'a2', 'e1', 'e2', 'b1', 'b2', 'hb', 'hi', 'ha'])
A_CH = 'F:4 Bb:4 F:8  C:4 F:12  F:4 Bb:4 F:8  Gm:8 C:8  Bb:16  C:16'
E1_CH = 'Dm:8 Gm:8  C:4 F:12'   # bar 8 'g4 e4 f4:8': the F lands on beat 2, so the chord resolves there (as in A_CH)
E2_CH = 'Dm:8 Gm:8  F:8 C:8'
B1_CH = 'Dm:4 Gm:4 Dm:8  A:4 Dm:12  Am:4 Dm:4 Am:8  G:4 Am:12'
B2_CH = 'Bb:16 C:16 Dm:8 Gm:8 C:16'
A_TAIL = 'Bb:16 C:16'      # bars 5-6 of A (the wind-up); bars 1-4 are the hook, harmonised in 'ha'
ow_p2 = ['hi', '|'] + ['ha'] + prog(A_TAIL + ' ' + E1_CH, 's', P, stab) \
        + ['ha'] + prog(A_TAIL + ' ' + E2_CH + ' ' + B1_CH, 's', P, stab) \
        + ['hb'] + ['ha'] + prog(A_TAIL + ' ' + E1_CH, 's', P, stab)
ow_tri = ['bi', '|'] + prog(A_CH + ' ' + E1_CH + ' ' + A_CH + ' ' + E2_CH + ' ' + B1_CH + ' ' + B2_CH + ' ' + A_CH + ' ' + E1_CH, 'b', P, bounce)
SONGS_OVERWORLD = dict(
    tempo=51, loop=True, pats=P,
    ch=[
        ['i', '|', 'a1', 'a2', 'e1', 'a1', 'a2', 'e2', 'b1', 'b2', 'a1', 'a2', 'e1'],
        ow_p2,
        ow_tri,
        ['di', '|'] + ['dx', 'd1', 'd1', 'df', 'd1', 'd1', 'd1', 'df'] * 2
                    + ['dx', 'd1', 'd1', 'df', 'd1', 'd1', 'd1', 'df']
                    + ['dx', 'd1', 'd1', 'df', 'd1', 'd1', 'd1', 'df'],
        ECHO(3),                                  # MMC5 P3: lead echoed a dotted 8th (15 fr) late
        # (Oct 17 night: the MMC5 pad on pulse 4 is gone from the overworld; it held a tone under
        #  every bar and flattened the dynamics)
        p4_double(ow_tri, P),                     # Oct 18 night: MMC5 P4 plucks the bass an octave up
    ],
)

# ================================================================ SKY
# A major waltz (3/4, 12 ticks per bar), 132 bpm (T=38: a 12-tick bar = 80.8 fr =
# two jumps, so a jump = half a bar). Airy vibrato lead, bell-like "pah-pah"
# chords, hats only. Its own tune ("Above the Clouds"), not the main theme.
SONGS_SKY = dict(
    tempo=bpm(132), loop=True,
    pats=dict(
        m='@leadv e5:6 c#5:2 e5:2 a5:2 '
          'a5:6 g#5:2 f#5:4 '
          'f#5:4 a5:4 d6:4 '
          'b5:8 g#5:4 '
          'a5:6 e5:2 c#5:4 '
          'g#5:6 e5:2 c#5:2 e5:2 '
          'f#5:4 a5:2 g#5:4 b5:2 '
          'a5:12',
        n='c#6:6 b5:2 a5:4 '
          'g#5:6 f#5:2 e5:4 '
          'f#5:2 a5:2 d6:4 c#6:2 b5:2 '
          'c#6:8 a5:4 '
          'b5:6 a5:2 f#5:4 '
          'g#5:4 b5:4 e6:4 '
          'c#6:6 b5:2 a5:4 '
          'b5:8 r:4',
        w='@arpMs r:4 c4:4 c4:4',
        wm='@arpms r:4 c4:4 c4:4',
        wh='@arpMs r:2 c4:2 c4:2',
        b='@trid24 c2:4 g2:4 c3:4',
        bh='@trid24 c2:2 g2:4',
        d='Q:4 H:4 H:4',
        df='Q:4 H:2 Q:2 O:4',
    ),
    ch=[
        ['m', 'n'],
        [('w', -3), ('wm', 6), ('w', 2), ('w', 4), ('w', -3), ('wm', 1), ('wh', 2), ('wh', 4), ('w', -3),
         ('wm', 6), ('wm', 1), ('w', 2), ('w', -3), ('wm', -1), ('w', 4), ('w', -3), ('w', 4)],
        [('b', 9), ('b', 6), ('b', 2), ('b', 4), ('b', 9), ('b', 1), ('bh', 2), ('bh', 4), ('b', 9),
         ('b', 6), ('b', 1), ('b', 2), ('b', 9), ('b', -1), ('b', 4), ('b', 9), ('b', 4)],
        ['d', 'd', 'd', 'df', 'd', 'd', 'd', 'df', 'd', 'd', 'd', 'df', 'd', 'd', 'd', 'df'],
        ECHO(5),                                  # MMC5 P3: floating echo 5 ticks (34 fr) late
    ],
)

# ================================================================ FORTRESS
# C minor march, T=51 written in 32nd-note ticks: 4/4 at 89.6 BPM, 32
# ticks/bar, beat (8 ticks) = one jump. The hook at half speed in minor,
# then the same hook a 4th up in F minor (with its Db) over a G7 turnaround.
# 8-bar loop, 21.4 s.
P = {}
P.update(
    a='@lead c5:4 c5:4 f5:4 ab5:4 g5:12 eb5:4 '
      'f5:4 d5:4 eb5:8 c5:8 r:8 '
      'c5:4 c5:4 f5:4 ab5:4 g5:12 eb5:4 '
      'ab5:4 f5:4 g5:8 d5:8 b4:8',
    b='f5:4 f5:4 bb5:4 db6:4 c6:12 ab5:4 '
      'bb5:4 g5:4 ab5:8 f5:8 r:8 '
      'ab5:8 eb5:8 f5:8 ab5:8 '
      'g5:16 f5:8 d5:4 b4:4',
    d='K:4 S:2 S:2 K:4 S:4 K:4 S:2 S:2 K:2 K:2 S:1 S:1 S:1 S:1',
    df='K:4 S:2 S:2 K:4 S:4 S:1 S:1 S:1 S:1 S:1 S:1 S:1 S:1 S:2 S:2 B:4',
)
down_pats(P, ['a', 'b'])
FORT_CH = ('Cm:8 Fm:8 Cm:16  G:8 Cm:24  Cm:8 Fm:8 Cm:16  Fm:8 G:24 '
           'Fm:8 Bbm:8 Fm:16  C:8 Fm:24  Ab:16 Fm:16  G:32')
SONGS_FORTRESS = dict(
    tempo=51, loop=True, pats=P,
    ch=[
        ['a', 'b'],
        prog(FORT_CH, 's', P, march_stab),
        prog(FORT_CH, 'o', P, march_bass),
        ['d', 'd', 'd', 'df'] * 2,
        ECHO(3),                                  # MMC5 P3: echo a dotted 16th (15 fr) late
        prog(FORT_CH, 'p', P, pad),
    ],
)

# ================================================================ MAP
# G major, 108 bpm (T=31, quarter = 33 fr ~ one 32-frame map-walk cycle), swung 3+1
# "island walk". 16 bars, loops from the top. Its own tune, not the main theme.
SONGS_MAP = dict(
    tempo=bpm(108), loop=True, hurry=False,
    pats=dict(
        m1='@lead d5:3 b4:1 g4:2 b4:2 d5:4 e5:2 d5:2 '
           'b4:3 g4:1 e4:4 r:2 g4:2 b4:2 a4:2 '
           'c5:3 e5:1 g5:4 e5:2 c5:2 e5:2 d5:2 '
           'a4:6 f#4:2 a4:2 d5:4 r:2',
        m2='d5:3 b4:1 g4:2 b4:2 d5:4 g5:2 f#5:2 '
           'e5:3 d5:1 b4:4 g4:2 b4:2 e5:2 d5:2 '
           'c5:3 b4:1 a4:2 c5:2 f#5:3 e5:1 d5:2 c5:2 '
           'b4:2 a4:2 g4:4 r:4 d4:2 g4:2',
        m3='@leadv e5:4 g5:3 e5:1 c5:4 e5:4 '
           'd5:4 b4:3 g4:1 d5:6 r:2 '
           'c5:3 e5:1 a5:4 g5:2 e5:2 c5:2 e5:2 '
           'f#5:4 e5:2 d5:2 a4:8',
        m4='e5:3 f#5:1 g5:4 e5:4 c5:4 '
           'd5:3 e5:1 d5:2 b4:2 g4:8 '
           'a4:3 b4:1 c5:4 d5:3 e5:1 f#5:4 '
           'g5:8 r:4 d5:2 f#5:2',
        sM='@arpMs r:2 c4:1 c4 r:2 c4:2 r:2 c4:1 c4 r:2 c4:2',
        sm='@arpms r:2 c4:1 c4 r:2 c4:2 r:2 c4:1 c4 r:2 c4:2',
        sMh='@arpMs r:2 c4:1 c4 r:2 c4:2',
        smh='@arpms r:2 c4:1 c4 r:2 c4:2',
        b='@tris c2:3 c2:1 g2:2 c2:2 c3:3 c2:1 g2:2 c2:2',
        bh='@tris c2:3 c2:1 g2:2 c2:2',
        d='K:2 Q:1 Q H:2 Q K:1 Q K:2 H Q',
        df='K:2 Q:1 Q H:2 Q T:2 T S S',
    ),
    ch=[
        ['m1', 'm2', 'm3', 'm4'],
        [('sM', 7), ('sm', 4), 'sM', ('sM', 2), ('sM', 7), ('sm', 4), ('smh', -3), ('sMh', 2), ('sM', 7),
         'sM', ('sM', 7), ('sm', -3), ('sM', 2), 'sM', ('sM', 7), ('smh', -3), ('sMh', 2), ('sM', 7)],
        [('b', 7), ('b', 4), 'b', ('b', 2), ('b', 7), ('b', 4), ('bh', -3), ('bh', 2), ('b', 7),
         'b', ('b', 7), ('b', -3), ('b', 2), 'b', ('b', -5), ('bh', -3), ('bh', 2), ('b', 7)],
        # (bar 14 bass is G1, not B1: the root-fifth bounce on B put F#2 on beats 2 and 4 under a G chord)
        ['d', 'd', 'd', 'df', 'd', 'd', 'd', 'df', 'd', 'd', 'd', 'df', 'd', 'd', 'd', 'df'],
    ],
)

# ================================================================ TITLE
# D major, T=32 (112.5 BPM; a quarter = one PUSH START blink phase).
# 2-bar brass call built from the hook's first leap (1 1 4 6 | 5 1'), then
# the theme in parallel thirds like a brass section, then a B minor turn.
# 12-bar loop (25.6 s) after a 4.3 s intro.
P = {}
P.update(
    i='@fan d5:2 r:2 d5:2 r:2 g5:4 b5:4 a5:8 d6:8',
    ih='@fan1 a4:2 r:2 a4:2 r:2 d5:4 g5:4 f#5:8 a5:8',
    a='@fan d5:2 d5:2 g5:2 b5:2 a5:6 f#5:2 '
      'g5:2 e5:2 f#5:4 d5:4 r:4 '
      'd5:2 d5:2 g5:2 b5:2 a5:6 f#5:2 '
      'b5:2 a5:2 g5:4 e5:4 r:4 '
      'g5:4 b5:4 d6:6 b5:2 '
      'a5:4 c#6:4 e6:6 c#6:2 '
      'f#6:2 e6:2 d6:2 c#6:2 b5:2 a5:2 g5:2 a5:2 '
      'e5:2 c#5:2 d5:8 r:4',
    ah='@fan1 a4:2 a4:2 d5:2 g5:2 f#5:6 d5:2 '
       'e5:2 c#5:2 d5:4 a4:4 r:4 '
       'a4:2 a4:2 d5:2 g5:2 f#5:6 d5:2 '
       'g5:2 f#5:2 e5:4 c#5:4 r:4 '
       'd5:4 g5:4 b5:6 g5:2 '
       'e5:4 a5:4 c#6:6 a5:2 '
       'd6:2 c#6:2 b5:2 a5:2 g5:2 f#5:2 e5:2 f#5:2 '
       'c#5:2 a4:2 a4:8 r:4',
    b='b4:2 b4:2 e5:2 g5:2 f#5:6 d5:2 '
      'e5:2 c#5:2 d5:4 b4:4 r:4 '
      'g5:2 b5:2 d6:4 e6:2 d6:2 c#6:2 b5:2 '
      'a5:12 c#5:2 e5:2',
    bi='@tri d2:16 a2:8 d2:8',
    di='K:4 r:4 K:4 r:4 X:4 r:4 S:1 S S S S S S S',
    d='K:2 H S H K:1 K H:2 S H',
    dx='X:2 H S H K:1 K H:2 S H',
    df='K:2 H S H S:1 S S S S:2 S:2',
)
down_pats(P, ['i', 'ih', 'a', 'ah', 'b'])
TITLE_A = 'D:4 G:4 D:8  A:4 D:12  D:4 G:4 D:8  Em:8 A:8  G:16  A:16  Bm:8 G:8  A:4 D:12'
TITLE_B = 'Bm:4 Em:4 Bm:8  F#:4 Bm:12  G:8 A:8  A:16'
SONGS_TITLE = dict(
    tempo=32, loop=True, hurry=False, pats=P,
    ch=[
        ['i', '|', 'a', 'b'],
        ['ih', '|', 'ah'] + prog(TITLE_B, 's', P, block),
        ['bi', '|'] + prog(TITLE_A + ' ' + TITLE_B, 'o', P, oct_bass),
        ['di', '|', 'dx', 'd', 'd', 'df', 'd', 'd', 'd', 'df', 'dx', 'd', 'd', 'df'],
        ECHO(3),                                  # MMC5 P3: echo a dotted 8th (24 fr) late
        # intro bar 1 beats 3-4 are G/D (lead g4 b4 over d4 g4): the pad follows with B, not F#
        prog('D:8 G:8 A:8 D:8', 'p', P, pad) + ['|'] + prog(TITLE_A + ' ' + TITLE_B, 'p', P, pad),
    ],
)

# ================================================================ BOSS
# E minor, 168 bpm. Pounding 16th bass, offbeat stabs, 16th drums.
SONGS_BOSS_PATS = dict(
        a='@lead1 e5:2 r:1 e5:1 f#5:2 g5:2 f#5:2 e5:2 b4:4 '
          'c5:2 r:1 c5:1 b4:2 a4:2 b4:8 '
          'e5:2 r:1 e5:1 f#5:2 g5:2 a5:2 g5:2 e5:4 '
          'd#5:4 f#5:4 b5:8 '
          'g5:2 f#5:1 e5:1 f#5:2 g5:2 b5:4 a5:2 g5:2 '
          'a5:2 g5:1 f#5:1 e5:2 c5:2 e5:4 a5:4 '
          'g5:2 f#5:2 e5:2 g5:2 f#5:2 d#5:2 b4:4 '
          'e5:8 r:4 b4:2 d#5:2',
        b='@leadv c6:4 b5:2 a5:2 g5:4 e5:4 '
          'd6:4 c6:2 b5:2 a5:4 f#5:4 '
          'e6:2 d#6:2 e6:2 f#6:2 g6:4 f#6:2 e6:2 '
          'd#6:4 b5:4 f#5:4 d#5:4',
        s='@arpMs r:1 c4 r c4 r c4 r c4 r c4 r c4 r c4 r c4',
        sm='@arpms r:1 c4 r c4 r c4 r c4 r c4 r c4 r c4 r c4',
        smh='@arpms r:1 c4 r c4 r c4 r c4',
        sh='@arpMs r:1 c4 r c4 r c4 r c4',
        o='@tris c2:1 c2 c3 c2 c2 c2 c3 c2 c2 c2 c3 c2 c2 c3 c2 c3',
        oh='@tris c2:1 c2 c3 c2 c2 c3 c2 c3',
        d='K:1 H S H K H S H K H S H K K S S',
        dx='X:1 H S H K H S H K H S H K K S S',
)
down_pats(SONGS_BOSS_PATS, ['a', 'b', 's', 'sm', 'smh', 'sh'])     # Oct 17 night: boss leads and stabs an octave lower
SONGS_BOSS = dict(
    tempo=bpm(168), loop=True, pats=SONGS_BOSS_PATS,
    ch=[
        ['a', 'b'],
        [('sm', 4), ('sm', 4), 's', ('s', -1), ('sm', 4), ('sm', -3), ('sh', 0), ('sh', -1), ('sm', 4),
         's', ('s', 2), ('sm', 4), ('s', -1)],
        [('o', 4), ('o', 4), 'o', ('o', -1), ('o', 4), ('o', -3), 'oh', ('oh', -1), ('o', 4),
         'o', ('o', 2), ('o', 4), ('o', -1)],
        ['dx', 'd', 'd', 'd', 'd', 'd', 'd', 'd', 'dx', 'd', 'd', 'd'],
        ECHO(3),                                  # MMC5 P3: echo a dotted 16th (16 fr) late
        prog('Em:16 Em:16 C:16 B:16 Em:16 Am:16 C:8 B:8 Em:16 C:16 D:16 Em:16 B:16',
             'p', SONGS_BOSS_PATS, pad),
    ],
)

# ================================================================ CLEAR (one-shot)
# C major, 160 bpm, 3 bars (~4.5 s).
SONGS_CLEAR = dict(
    tempo=bpm(160), loop=False,
    pats=dict(
        m='@fan e5:2 g5:2 c6:3 b5:1 c6:2 g5:2 e5:4 '
          'f5:2 a5:2 d6:3 c6:1 d6:2 b5:2 g5:4 '
          'c6:2 e6:2 g6:10 r:2',
        h='@fan1 c5:2 e5:2 g5:3 g5:1 g5:2 e5:2 c5:4 '
          'c5:2 f5:2 a5:3 a5:1 b5:2 g5:2 d5:4 '
          'e5:2 g5:2 c6:10 r:2',
        b='@tri c2:4 g2 c3 g2 f2 a2 g2 b2 @tris c3:4 @tri c2:10 r:2',
        d='K:2 H S H K H S H K H S H K S S:1 S S S X:12 r:4',
    ),
    ch=[['m'], ['h'], ['b'], ['d']],
)

# ================================================================ DEATH (one-shot)
# D minor, 140 bpm, ~2.6 s. "Uh-oh" pickup then a sinking line.
SONGS_DEATH = dict(
    tempo=bpm(140), loop=False,
    pats=dict(
        m='@stac a5:1 r:1 a5:1 r:1 @leadv f5:4 e5:2 c5:2 d5:2 bb4:2 a4:6 r:2',
        h='r:4 @harm d5:4 c5:2 a4:2 bb4:2 g4:2 c#4:6 r:2',
        b='r:4 @tri d2:4 c2:4 bb1:4 a1:6 r:2',
        d='r:24',
    ),
    ch=[['m'], ['h'], ['b'], ['d']],
)

# ================================================================ GAMEOVER (one-shot)
# A minor, 100 bpm, ~4.2 s. Slow, warm and a little wistful.
SONGS_GAMEOVER = dict(
    tempo=bpm(100), loop=False,
    pats=dict(
        m='@leadv e5:4 c5:2 a4:2 b4:4 g#4:4 a4:10 r:2',
        h='@harm c5:4 a4:2 e4:2 d4:4 e4:4 c4:10 r:2',
        b='@tri a1:8 e2:8 a1:10 r:2',
        d='r:28',
    ),
    ch=[['m'], ['h'], ['b'], ['d']],
)

# ================================================================ KEEPCLEAR (one-shot)
# F major, 150 bpm, 4 bars (~6.4 s). Rising victory fanfare.
SONGS_KEEPCLEAR = dict(
    tempo=bpm(150), loop=False,
    pats=dict(
        m='@fan f5:2 c5:1 f5:1 a5:2 c6:6 a5:2 c6:2 '
          'd6:4 c6:2 bb5:2 a5:2 bb5:2 d6:4 '
          'g5:2 a5:2 bb5:2 c6:2 d6:2 e6:2 g6:4 '
          'f6:14 r:2',
        h='@fan1 c5:2 a4:1 c5:1 f5:2 a5:6 f5:2 a5:2 '
          'bb5:4 a5:2 g5:2 f5:2 g5:2 bb5:4 '
          'd5:2 f5:2 g5:2 a5:2 bb5:2 c6:2 e6:4 '
          'a5:14 r:2',
        b='@tri f2:4 c2 f2 a2 bb1 f2 bb2 d3 g2 bb2 c3 c2 f2:14 r:2',
        d='K:2 H S H K H S H K H S H K H S H S:2 S S S S:1 S S S S:2 S:2 X:14 r:2',
    ),
    ch=[['m'], ['h'], ['b'], ['d']],
)

# ================================================================ STARPOWER
# C mixolydian, 176 bpm, 8-bar loop. Breathless and bright.
SONGS_STARPOWER = dict(
    tempo=bpm(176), loop=True,
    pats=dict(
        m='@lead1 c5:1 e5:1 g5:2 c6:2 g5:2 bb5:2 a5:2 g5:2 e5:2 '
          'f5:2 d5:2 bb4:2 d5:2 f5:4 d5:4 '
          'e5:2 g5:2 c6:2 e6:2 d6:2 c6:2 bb5:2 g5:2 '
          'a5:4 f5:4 g5:4 b5:4 '
          'c5:1 e5:1 g5:2 c6:2 g5:2 bb5:2 a5:2 g5:2 e5:2 '
          'f5:2 d5:2 bb4:2 d5:2 f5:4 d5:4 '
          'c6:2 bb5:2 g5:2 e5:2 f5:2 g5:2 bb5:2 c6:2 '
          'd6:4 b5:4 g5:4 r:4',
        s='@arpMs c4:2 c4 c4 c4 c4 c4 c4 c4',
        sh='@arpMs c4:2 c4 c4 c4',
        o='@tris c2:2 c3 c2 c3 c2 c3 c2 c3',
        oh='@tris c2:2 c3 c2 c3',
        d='K:2 H S H K:1 K H:2 S H',
        df='K:2 H S H S:1 S S S S:2 S',
    ),
    ch=[
        ['m'],
        ['s', ('s', -2), 's', ('sh', 5), ('sh', 7), 's', ('s', -2), 's', ('s', 7)],
        ['o', ('o', -2), 'o', ('oh', 5), ('oh', 7), 'o', ('o', -2), 'o', ('o', 7)],
        ['d', 'd', 'd', 'df', 'd', 'd', 'd', 'df'],
    ],
)

# ================================================================ DESERT (Oct 18 night)
# "Mesa Wind", World 2's desert courses. D harmonic minor (the C# gives it the sand), T=44
# (~155 BPM 16ths), 16 ticks/bar. A: its own line, a slow winding figure over a camel-walk bass
# (dotted root-fifth); B: the main theme's hook in D minor, its answer leaning on the C#.
# Intro 2 bars (bass and hand drums), then A B A B = 16 bars.
P = {}
P.update(
    i='@lead r:16 r:16',
    A='@lead d5:2 e5:2 f5:2 e5:2 d5:4 c#5:2 d5:2 '
      'a4:6 bb4:2 c#5:4 a4:4 '
      'd5:2 f5:2 a5:4 g5:2 f5:2 e5:4 '
      'f5:2 e5:2 d5:2 c#5:2 d5:8',
    B='d5:2 d5:2 g5:2 bb5:2 a5:6 f5:2 '
      'g5:2 e5:2 f5:4 d5:4 r:4 '
      'a5:2 a5:2 d6:2 f6:2 e6:6 c#6:2 '
      'd6:2 bb5:2 c#6:4 a5:4 r:4',
    pi='r:16 r:16',
    d='K:3 H:1 S:2 H:2 K:2 H:2 S:2 H:2',
    df='K:3 H:1 S:2 H:2 S:1 S:1 S:2 T:2 T:2',
    di='K:3 H:1 H:2 H:2 K:2 H:2 H:2 H:2 K:3 H:1 H:2 H:2 S:1 S:1 S:2 T:2 T:2',
)
down_pats(P, ['A', 'B'])
def camel(q, n):
    return '@trid14 ' + ' '.join(['c2:3 g2:1 c3:2 g2:2'] * (n // 8) + (['c2:3 g2:1'] if n % 8 else []))
def desert_stab(q, n):
    return f'@arp{q}s ' + ' '.join(['r:2 c3:2'] * (n // 4))
DES_A = 'Dm:16 A:16 Dm:8 A:8 Dm:16'
DES_B = 'Dm:4 Gm:4 Dm:8 A:4 Dm:12 Dm:4 Bb:4 A:8 Gm:4 A:12'
SONGS_DESERT = dict(
    tempo=44, loop=True, pats=P,
    ch=[
        ['i', '|', 'A', 'B', 'A', 'B'],
        ['pi', '|'] + prog(DES_A + ' ' + DES_B + ' ' + DES_A + ' ' + DES_B, 'q', P, desert_stab),
        prog('Dm:32', 'c', P, camel) + ['|'] + prog(DES_A + ' ' + DES_B + ' ' + DES_A + ' ' + DES_B, 'c', P, camel),
        ['di', '|'] + ['d', 'd', 'd', 'df'] * 4,
        ECHO(3),
    ],
)

# ================================================================ MAP 2 (0.9.1)
# "Gusty Mesa" map walk, World 2's own map tune (SMB3 gives each world's map its own song).
# D minor with the desert song's C#, the same tempo and swung 3+1 walk as World 1's map (a quarter =
# one map-walk cycle), over Mesa Wind's camel-walk bass and hand drums. Its opening figure is Mesa
# Wind's (d e f e d), so the two belong together. 16 bars, loops from the top.
PM2 = {}
PM2.update(
    m1='@lead d5:3 e5:1 f5:2 e5:2 d5:4 a4:4 '
       'f5:3 e5:1 d5:2 c#5:2 d5:6 r:2 '
       'bb4:3 c5:1 d5:2 g5:2 f5:2 e5:2 d5:4 '
       'c#5:3 d5:1 e5:2 a4:2 c#5:6 r:2',
    m2='d5:3 e5:1 f5:2 a5:2 g5:2 f5:2 e5:2 d5:2 '
       'f5:3 e5:1 d5:4 a4:4 r:4 '
       'd5:3 c5:1 bb4:2 d5:2 f5:4 d5:4 '
       'e5:3 d5:1 c#5:2 e5:2 a5:6 r:2',
    m3='@leadv g5:4 bb5:3 g5:1 d5:4 g5:4 '
       'f5:4 e5:3 d5:1 bb4:6 r:2 '
       'a5:3 g5:1 f5:2 e5:2 d5:2 f5:2 a5:4 '
       'g5:3 f5:1 e5:2 d5:2 a4:8',
    m4='bb4:3 c5:1 d5:4 f5:3 g5:1 a5:4 '
       'g5:3 f5:1 e5:2 c#5:2 a4:8 '
       'd5:3 e5:1 f5:2 e5:2 d5:2 c#5:2 d5:4 '
       'a4:8 r:4 a4:2 c#5:2',
    d='K:3 H:1 S:2 H:2 K:2 H:2 S:2 H:2',
    df='K:3 H:1 S:2 H:2 S:1 S:1 S:2 T:2 T:2',
)
down_pats(PM2, ['m1', 'm2', 'm3', 'm4'])
MAP2_CH = 'Dm:16 Dm:16 Gm:16 A:16  Dm:16 Dm:16 Bb:16 A:16  Gm:16 Gm:16 Dm:16 Dm:16  Bb:16 A:16 Dm:16 A:16'
SONGS_MAP2 = dict(
    tempo=bpm(108), loop=True, hurry=False, pats=PM2,
    ch=[
        ['m1', 'm2', 'm3', 'm4'],
        prog(MAP2_CH, 'q', PM2, desert_stab),
        prog(MAP2_CH, 'c', PM2, camel),
        ['d', 'd', 'd', 'df'] * 4,
        ECHO(3),
    ],
)

# ================================================================ STORY (0.9.2)
# "Breezy Isle Long Ago", for the story pages and the ending (Castlevania III gives its prologue a
# tune of its own). A minor, slow (84 BPM), a harp of broken chords under a singing lead with a late
# vibrato and the MMC5 echo, the triangle holding each chord's root. No drums. 16 bars, loops.
PS = {}
PS.update(
    a='@leadv e5:6 a5:2 c6:4 b5:4 a5:6 f5:2 e5:8 e5:6 g5:2 c6:4 d6:4 b5:12 r:4',
    b='e5:6 a5:2 c6:4 e6:4 d6:6 c6:2 a5:8 f5:6 a5:2 d6:4 c6:4 b5:8 g#5:8',
    c='a5:6 c6:2 f6:4 e6:4 d6:6 b5:2 g5:8 g5:6 b5:2 e6:4 d6:4 c6:8 a5:8',
    d='a5:6 c6:2 f6:4 e6:4 d6:4 b5:4 g5:4 b5:4 g#5:6 b5:2 e6:8 d6:4 c6:4 b5:4 g#5:4',
    n='r:16 r:16 r:16 r:16',
)
down_pats(PS, ['a', 'b', 'c', 'd'])
def harp(q, n):
    third = 'e4' if q == 'M' else 'eb4'
    cyc = ['c3', 'g3', 'c4', third, 'g3', 'c4', third, 'c4']
    return '@bell ' + ' '.join(f'{cyc[i % 8]}:2' for i in range(n // 2))
def held(q, n):
    return f'@tri c2:{n}'
STORY_CH = ('Am:16 F:16 C:16 G:16  Am:16 F:16 Dm:16 E:16  '
            'F:16 G:16 Em:16 Am:16  F:16 G:16 E:16 E:16')
SONGS_STORY = dict(
    tempo=bpm(84), loop=True, hurry=False, pats=PS,
    ch=[
        ['a', 'b', 'c', 'd'],
        prog(STORY_CH, 'h', PS, harp),
        prog(STORY_CH, 'o', PS, held),
        ['n', 'n', 'n', 'n'],
        ECHO(6),
    ],
)

# ================================================================ CAVE (Oct 19)
# "Echo Hollow", the cave courses. E minor with a Phrygian F (the drip of the cave), 136 BPM 16ths.
# A: a staccato pluck line full of rests, so the MMC5 echo (5 ticks behind) answers every note like
# a cave wall; B: the main theme's hook in E minor on the singing lead. The triangle walks root and
# octave with rests between, pulse 4 plucks it an octave up, the drums are a hat tick and a soft
# snare. Intro 2 bars (bass and drums), then A B = 16 bars.
PC = {}
PC.update(
    i='@lead r:16 r:16',
    A='@stac e4:2 r:2 e4:2 g4:2 r:2 b4:2 r:4 '
      'a4:2 r:2 g4:2 f4:2 e4:4 r:4 '
      'e4:2 r:2 e4:2 g4:2 r:2 b4:2 d5:2 r:2 '
      'c5:2 b4:2 a4:2 f4:2 e4:4 r:4 '
      'g4:2 r:2 g4:2 b4:2 r:2 d5:2 r:4 '
      'c5:2 r:2 b4:2 a4:2 g4:4 r:4 '
      'f4:2 r:2 f4:2 a4:2 c5:2 b4:2 a4:2 f4:2 '
      'e4:4 b3:4 e4:4 r:4',
    B='@leadv e4:2 e4:2 a4:2 c5:2 b4:6 g4:2 '
      'a4:2 f#4:2 g4:4 e4:4 r:4 '
      'e4:2 e4:2 a4:2 c5:2 d5:6 b4:2 '
      'c5:2 a4:2 b4:4 g4:4 r:4 '
      'c5:2 c5:2 e5:2 g5:2 f#5:6 d5:2 '
      'e5:2 c5:2 d5:4 b4:4 r:4 '
      'a4:2 c5:2 b4:2 a4:2 b4:2 a4:2 f#4:2 d#4:2 '
      'e4:8 r:8',
    pi='r:16 r:16',
    d='K:4 H:2 H:2 S:4 H:2 H:2',
    df='K:4 H:2 H:2 S:2 S:2 T:2 T:2',
    di='K:4 H:2 H:2 H:4 H:2 H:2 K:4 H:2 H:2 S:2 S:2 T:2 T:2',
)
def cave_stab(q, n):
    return f'@arp{q}s ' + ' '.join(['r:4 c3:2 r:2'] * (n // 8) + (['r:4'] if n % 8 else []))
def cave_bass(q, n):
    return '@trid9 ' + ' '.join(['c2:2 r:2 c3:2 g2:2'] * (n // 8) + (['c2:2 r:2'] if n % 8 else []))
# (the consonance audit, music/study/consonance.py, placed the chord changes: each long melody note sits
# on a chord that holds it)
CAVE_A = 'Em:16 F:8 Em:8 Em:16 Am:4 F:4 Em:8 G:16 Am:4 G:12 F:16 Em:16'
CAVE_B = 'Am:8 Em:8 B:4 Em:12 Am:8 G:8 Am:4 Em:12 C:8 D:8 C:8 G:8 Am:8 B:8 Em:16'
SONGS_CAVE = dict(
    tempo=bpm(136), loop=True, pats=PC,
    ch=[
        ['i', '|', 'A', 'B'],
        ['pi', '|'] + prog(CAVE_A + ' ' + CAVE_B, 'q', PC, cave_stab),
        prog('Em:32', 'c', PC, cave_bass) + ['|'] + prog(CAVE_A + ' ' + CAVE_B, 'c', PC, cave_bass),
        ['di', '|'] + ['d', 'd', 'd', 'df'] * 4,
        ECHO(5),
    ],
)
SONGS_CAVE['ch'].append(p4_double(SONGS_CAVE['ch'][2], PC))

SONGS_SKY['ch'].append(p4_double(SONGS_SKY['ch'][2], SONGS_SKY['pats']))   # Oct 18 night
SONGS_DESERT['ch'].append(p4_double(SONGS_DESERT['ch'][2], P))               # Oct 18 night

# ================================================================ PRIZE (one-shot)
# Oct 23 (play-test note 20: "there should be some sort of fanfare"): the treasure-house chest.
# C major, 180 bpm, 16 sixteenths (~1.3 s): a quick climb up the chord, a breath, the octave held.
SONGS_PRIZE = dict(
    tempo=bpm(180), loop=False,
    pats=dict(
        m='@fan c5:1 e5:1 g5:1 c6:1 r:1 g5:1 c6:8 r:2',
        h='@fan1 g4:1 c5:1 e5:1 g5:1 r:1 e5:1 g5:8 r:2',
        b='@tri c3:4 g2:2 c3:8 r:2',
        d='S:1 S S S r:2 X:8 r:2',
    ),
    ch=[['m'], ['h'], ['b'], ['d']],
)

def placeholder(tempo, loop, root_semis=0):
    return dict(tempo=tempo, loop=loop,
                pats=dict(m='@lead c5:4 e5 g5 c6', s=stab('M', 16), b=bounce('M', 16), d='K:2 H S H K H S H'),
                ch=[['m'], ['s'], ['b'], ['d']])

ORDER = ['TITLE', 'MAP', 'OVERWORLD', 'SKY', 'FORTRESS', 'BOSS', 'CLEAR', 'DEATH',
         'GAMEOVER', 'KEEPCLEAR', 'STARPOWER', 'DESERT', 'MAP2', 'STORY', 'CAVE', 'PRIZE']
for n in ORDER:
    g = globals().get('SONGS_' + n)
    SONGS[n] = g if g else placeholder(bpm(120), n not in ('CLEAR', 'DEATH', 'GAMEOVER', 'KEEPCLEAR', 'PRIZE'))
    # hurry mode applies to looping level songs only; jingles, TITLE and MAP
    # keep their written tempo (bit 7 of the tempo byte, see build.py)
    SONGS[n].setdefault('hurry', SONGS[n]['loop'])
