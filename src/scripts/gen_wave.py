#!/usr/bin/env python3
"""
gen_wave.py - make a sound file for WAVE.PLC (wave.masm) from any sound file

    python3 gen_wave.py song.mp3 -o ../../sdcard/SOUNDS/SONG.WAV
    python3 gen_wave.py talk.wav -o TALK.WAV --rate half
    python3 gen_wave.py song.flac -o PART.WAV --start 30 --seconds 20

The player takes a plain WAV file: PCM, 8 bits unsigned, one channel, at
one of the board's three speeds (docs/software/WAVE.md):

    full      31,469 Hz   the line rate: 1.9 MB a minute
    half      15,734 Hz   0.9 MB a minute (speech, or a long song)
    quarter    7,867 Hz   0.5 MB a minute (speech)

ffmpeg reads the source (anything it knows: MP3, WAV, FLAC, OGG, M4A, a
video's sound) and makes it one channel at the rate.  This script then
sets the level (the loudest sample to 97 % of full scale, unless
--gain says how many dB), adds half a step of noise before rounding to 8
bits (dither: the rounding becomes a steady hiss instead of a distortion
that follows the sound; --no-dither leaves it out) and writes the file
with a 44-byte header.

Without this script, ffmpeg alone makes a file the player takes:

    ffmpeg -i song.mp3 -ac 1 -ar 31469 -c:a pcm_u8 SONG.WAV

The name on the card must be a short one: up to 8 letters or digits and
.WAV.

Date: 11/22/2026
"""

import argparse
import os
import struct
import subprocess
import sys

import numpy as np

RATES = {'full': 31469, 'half': 15734, 'quarter': 7867}


def header(rate, n):
    """the 44 bytes in front of n samples"""
    return (b'RIFF' + struct.pack('<I', 36 + n) + b'WAVE'
            + b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate, 1, 8)
            + b'data' + struct.pack('<I', n))


def to_bytes(x, gain_db=None, dither=True, seed=1):
    """samples -1..1 (numpy) -> the file's bytes, 80h = 0"""
    x = np.asarray(x, dtype=np.float64)
    if gain_db is None:
        peak = float(np.max(np.abs(x))) if len(x) else 0.0
        x = x * (0.97 / peak) if peak > 0 else x
    else:
        x = x * 10 ** (gain_db / 20)
    v = x * 127.0 + 128.0
    if dither:
        r = np.random.default_rng(seed)
        v = v + r.random(len(v)) - r.random(len(v))     # triangular, +-1 step
    return np.clip(np.floor(v + 0.5), 0, 255).astype(np.uint8).tobytes()


def decode(path, rate, start=None, seconds=None):
    """the source as one channel of floats at the rate (ffmpeg)"""
    cmd = ['ffmpeg', '-v', 'error', '-nostdin']
    if start:
        cmd += ['-ss', str(start)]
    cmd += ['-i', path]
    if seconds:
        cmd += ['-t', str(seconds)]
    cmd += ['-ac', '1', '-ar', str(rate), '-f', 'f32le', '-']
    try:
        r = subprocess.run(cmd, capture_output=True)
    except FileNotFoundError:
        sys.exit('gen_wave.py needs ffmpeg (https://ffmpeg.org) on the path')
    if r.returncode:
        sys.exit('ffmpeg: ' + r.stderr.decode(errors='replace').strip())
    return np.frombuffer(r.stdout, dtype='<f4')


def make(x, rate, gain_db=None, dither=True):
    d = to_bytes(x, gain_db, dither)
    return header(rate, len(d)) + d


def main(argv):
    ap = argparse.ArgumentParser(description='make a .WAV file for WAVE.PLC')
    ap.add_argument('source')
    ap.add_argument('-o', '--out', help='the file to write (default: the source\'s name, .WAV)')
    ap.add_argument('--rate', choices=sorted(RATES), default='full')
    ap.add_argument('--start', type=float, help='seconds into the source to start at')
    ap.add_argument('--seconds', type=float, help='how much of it')
    ap.add_argument('--gain', type=float, metavar='DB', help='this many dB instead of the loudest sample to 97 %%')
    ap.add_argument('--no-dither', action='store_true')
    args = ap.parse_args(argv)
    rate = RATES[args.rate]
    out = args.out
    if not out:
        base = ''.join(c for c in os.path.splitext(os.path.basename(args.source))[0].upper() if c.isalnum())
        out = (base[:8] or 'SOUND') + '.WAV'
    name = os.path.basename(out)
    stem, ext = os.path.splitext(name)
    if ext.upper() != '.WAV' or not 1 <= len(stem) <= 8 or not stem.isalnum():
        print('note: %s is not a short name (8 letters or digits and .WAV); '
              'give it one on the card' % name)
    x = decode(args.source, rate, args.start, args.seconds)
    if not len(x):
        sys.exit('no sound in ' + args.source)
    data = make(x, rate, args.gain, not args.no_dither)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, 'wb').write(data)
    s = len(x) / rate
    print('%s: %d:%02d at %d Hz, %d bytes' % (out, int(s) // 60, int(s) % 60, rate, len(data)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
