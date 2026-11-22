#!/usr/bin/env python3
"""
gen_wave_demo.py - the two demo sound files of sdcard/SOUNDS for WAVE.PLC

    python3 gen_wave_demo.py            writes sdcard/SOUNDS/BRAHMS.WAV, HELLO.WAV
    python3 gen_wave_demo.py --mp3 DIR  also DIR/brahms.mp3, hello.mp3 (the
                                        files as the board plays them)

BRAHMS.WAV  Brahms, Hungarian Dance No. 5, played by the United States
            Army Strings: a public domain recording (src/sounds/README.md),
            46 seconds at the full rate (31,469 Hz)
HELLO.WAV   speech at the half rate (15,734 Hz): espeak-ng says the text
            below (it must be installed: apt-get install espeak-ng)

Both go through gen_wave.py's level, dither and header (and ffmpeg);
the music also through its --compress, which brings the soft parts up.

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
BRAHMS = os.path.join(HERE, '..', 'sounds', 'brahms_hungarian_dance_5.ogg')
FULL, HALF = gen_wave.RATES['full'], gen_wave.RATES['half']
TEXT = ('Hello. This is the Placard computer. You are hearing a recording, '
        'read from the S D card while it plays.')


def brahms():
    return gen_wave.decode(BRAHMS, FULL)


def speech():
    tmp = tempfile.mkdtemp()
    w = os.path.join(tmp, 'say.wav')
    try:
        subprocess.run(['espeak-ng', '-v', 'en-us', '-s', '140', '-w', w, TEXT], check=True)
    except FileNotFoundError:
        sys.exit('gen_wave_demo.py needs espeak-ng for HELLO.WAV')
    x = gen_wave.decode(w, HALF)
    pad = np.zeros(HALF // 4, dtype=x.dtype)
    return np.concatenate((pad, x, pad))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--mp3', metavar='DIR')
    args = ap.parse_args(argv)
    os.makedirs(OUT, exist_ok=True)
    for name, x, rate, comp in (('BRAHMS.WAV', brahms(), FULL, True), ('HELLO.WAV', speech(), HALF, False)):
        d = gen_wave.make(x, rate, comp=comp)
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
