#!/usr/bin/env python3
"""
gen_wave_demo.py - the two demo sound files of sdcard/SOUNDS for WAVE.PLC

    python3 gen_wave_demo.py            writes sdcard/SOUNDS/HELLO.WAV, MUSIC.WAV
    python3 gen_wave_demo.py --mp3 DIR  also DIR/hello.mp3, music.mp3 (the
                                        files as the board plays them)

HELLO.WAV   speech at the half rate (15,734 Hz): espeak-ng says the text
            below (it must be installed: apt-get install espeak-ng)
MUSIC.WAV   20 seconds of music at the full rate (31,469 Hz), made here:
            plucked strings (Karplus-Strong), a bass, a soft chord pad, a
            kick and hats, and a little room echo.  More at once than the
            four-voice player (docs/sound/MUSIC.md) mixes, which is the
            point of playing a recording.  The tune is this project's own.

Both go through gen_wave.py's level, dither and header.

Date: 11/22/2026
"""

import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_wave               # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'sdcard', 'SOUNDS')
SR = gen_wave.RATES['full']
TEXT = ('Hello. This is the Placard computer. You are hearing a recording, '
        'read from the S D card while it plays.')

BPM = 96
BEAT = 60.0 / BPM
BARS = 8
# two rounds of A minor, F, C, G: the bass note and the chord (MIDI numbers)
CHORDS = [(45, (57, 60, 64)), (41, (57, 60, 65)), (48, (55, 60, 64)), (43, (55, 59, 62))] * 2
ARP = (0, 1, 2, 1, 0, 2, 1, 2)          # which chord note on each eighth
# the tune over the second round: (beat in the bar, MIDI note, beats long)
TUNE = [[(0, 76, 1.5), (1.5, 74, 0.5), (2, 72, 1), (3, 69, 1)],
        [(0, 72, 1), (1, 77, 1), (2, 76, 1.5), (3.5, 72, 0.5)],
        [(0, 79, 1.5), (1.5, 76, 0.5), (2, 72, 1), (3, 76, 1)],
        [(0, 74, 1), (1, 71, 1), (2, 67, 2)]]


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def pluck(f, secs, r, bright=0.5):
    """a plucked string: a burst of noise around a delay line that averages
    neighbors (Karplus-Strong), a period at a time"""
    p = max(2, int(round(SR / f)))
    n = int(secs * SR)
    buf = r.uniform(-1, 1, p)
    buf = buf - buf.mean()
    for _ in range(int(4 * (1 - bright)) + 1):          # a softer pick
        buf = 0.5 * (buf + np.roll(buf, 1))
    out = np.empty(n + p)
    for k in range(0, n + p, p):
        out[k:k + p] = buf[:len(out[k:k + p])]
        buf = 0.498 * (buf + np.roll(buf, 1))
    return out[:n] * np.minimum(1, np.arange(n) / (0.002 * SR))


def put(mix, t, x, gain=1.0):
    a = int(t * SR)
    x = x[:max(0, len(mix) - a)]
    mix[a:a + len(x)] += gain * x


def music(seed=7):
    r = np.random.default_rng(seed)
    total = BARS * 4 * BEAT + 2.0
    mix = np.zeros(int(total * SR))
    for bar, (root, chord) in enumerate(CHORDS):
        t0 = bar * 4 * BEAT
        # the pad: three slightly detuned waves a chord note, slow in and out
        n = int(4 * BEAT * SR)
        tt = np.arange(n) / SR
        env = np.minimum(1, tt / 0.4) * np.minimum(1, (4 * BEAT - tt) / 0.4)
        pad = np.zeros(n)
        for m in chord:
            for det in (-0.004, 0, 0.004):
                f = hz(m) * (1 + det)
                pad += np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(4 * np.pi * f * tt)
        put(mix, t0, pad * env, 0.022)
        # the bass: the root on beats 1 and 3, with the fifth leading in
        for b, m, ln in ((0, root, 1.9), (2, root, 1.4), (3.5, root + 7, 0.5)):
            n = int(ln * BEAT * SR)
            tt = np.arange(n) / SR
            f = hz(m)
            x = (np.sin(2 * np.pi * f * tt) + 0.5 * np.sin(4 * np.pi * f * tt)
                 + 0.2 * np.sin(6 * np.pi * f * tt))
            put(mix, t0 + b * BEAT, x * np.exp(-tt * 1.6) * np.minimum(1, tt / 0.005), 0.16)
        # the plucked chord notes, an eighth each
        for e, k in enumerate(ARP):
            m = chord[k] + (12 if e % 4 == 3 else 0)
            put(mix, t0 + e * BEAT / 2, pluck(hz(m), 1.6, r, 0.5), 0.26)
        # the tune, an octave of brighter strings (second round)
        if bar >= 4:
            for b, m, ln in TUNE[bar - 4]:
                put(mix, t0 + b * BEAT, pluck(hz(m), ln * BEAT + 0.9, r, 0.9), 0.36)
        # a kick on 1 and 3, hats on the off-beats (from the third bar)
        if bar >= 2:
            for b in (0, 2):
                tt = np.arange(int(0.25 * SR)) / SR
                put(mix, t0 + b * BEAT,
                    np.sin(2 * np.pi * (48 * tt + 60 * (1 - np.exp(-tt * 30)) / 30)) * np.exp(-tt * 14), 0.28)
            for b in (0.5, 1.5, 2.5, 3.5):
                n = int(0.05 * SR)
                h = r.uniform(-1, 1, n)
                h = h - np.concatenate(([0], h[:-1]))            # the highs only
                put(mix, t0 + b * BEAT, h * np.exp(-np.arange(n) / (0.012 * SR)), 0.05)
    # a little room: four echoes that feed themselves
    wet = np.zeros_like(mix)
    for d, g in ((0.0297, 0.72), (0.0371, 0.70), (0.0411, 0.68), (0.0437, 0.66)):
        k = int(d * SR)
        y = mix.copy()
        for a in range(k, len(y), k):
            y[a:a + k] += g * y[a - k:a - k + len(y[a:a + k])]
        wet += y
    mix = mix + 0.045 * wet
    mix = np.tanh(mix * 1.6 / np.max(np.abs(mix)))      # the peaks rounded off: louder for 8 bits
    n = len(mix)
    tail = int(1.5 * SR)
    mix[n - tail:] *= np.linspace(1, 0, tail) ** 2
    return mix


def speech():
    tmp = tempfile.mkdtemp()
    w = os.path.join(tmp, 'say.wav')
    try:
        subprocess.run(['espeak-ng', '-v', 'en-us', '-s', '140', '-w', w, TEXT], check=True)
    except FileNotFoundError:
        sys.exit('gen_wave_demo.py needs espeak-ng for HELLO.WAV')
    x = gen_wave.decode(w, gen_wave.RATES['half'])
    pad = np.zeros(gen_wave.RATES['half'] // 4, dtype=x.dtype)
    return np.concatenate((pad, x, pad))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--mp3', metavar='DIR')
    args = ap.parse_args(argv)
    os.makedirs(OUT, exist_ok=True)
    for name, x, rate in (('HELLO.WAV', speech(), gen_wave.RATES['half']),
                          ('MUSIC.WAV', music(), SR)):
        d = gen_wave.make(x, rate)
        p = os.path.join(OUT, name)
        open(p, 'wb').write(d)
        print('%s: %.1f s at %d Hz, %d bytes' % (name, (len(d) - 44) / rate, rate, len(d)))
        if args.mp3:
            os.makedirs(args.mp3, exist_ok=True)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', p, '-ar', '44100', '-b:a', '128k',
                            os.path.join(args.mp3, name[:-4].lower() + '.mp3')], check=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
