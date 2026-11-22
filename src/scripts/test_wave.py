#!/usr/bin/env python3
"""
test_wave.py - run WAVE.PLC (wave.masm) in the web emulator's core and check
every sample the sound DAC plays

    python3 test_wave.py                the checks below
    python3 test_wave.py --png DIR      also the screens as DIR/*.png

Needs node (pinboard_emu.py runs web/placard_emu.js, which models the video
reads' stall clocks and takes the DAC's sample on every scan line).  The
test files are noise with no 80h in it, so every sample played is either
one sample of a file or silence, and which is known exactly.

  1. BOOT.CFG = WAVE.PLC, a SOUNDS folder with four .WAV files and a text
     file: the three good files are played whole, in order, sample for
     sample (31,469 Hz once, 15,734 Hz twice, 8,000 Hz four times each),
     with silence and nothing else between them; a header with other
     chunks before "data" is walked; the 16-bit stereo file is named and
     skipped; after the last the DOS is back
  2. a 300 KB file on a card with one sector a cluster (the FAT is read
     again every 256 sectors) and on one with 8: whole, no sample lost
  3. the keys: Space pauses (silence, no sample lost or repeated when it
     goes on), Right and Left change the file, Esc goes back to the DOS
     with the sound buffer silent
  4. Pinboard: Enter on a .WAV file in the Files card plays it (the
     second of its folder: "2 of 2"), and Pinboard comes back in that
     folder with the file still chosen; with no WAVE.PLC, Files says so
  5. sdcard/WAVE.PLC is wave.asm, and sdcard/SOUNDS/*.WAV are files the
     player takes

Date: 11/22/2026
"""

import argparse
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402
import test_pinboard as tp    # noqa: E402

REPO = os.path.join(HERE, '..', '..')
SD = os.path.join(REPO, 'sdcard')
LINES = 525


def wav(rate, data, ch=1, bits=8, extra=b''):
    fmt = struct.pack('<4sIHHIIHH', b'fmt ', 16, 1, ch, rate, rate * ch * bits // 8, ch * bits // 8, bits)
    body = b'WAVE' + fmt + extra + b'data' + struct.pack('<I', len(data)) + data
    return b'RIFF' + struct.pack('<I', len(body)) + body


def noise(n, seed):
    r = random.Random(seed)
    return bytes(r.choice(NOT80) for _ in range(n))


NOT80 = [b for b in range(256) if b != 0x80]
# what ffmpeg writes before "data", and a chunk of odd size (a pad byte follows)
OTHER = (b'LIST' + struct.pack('<I', 26) + b'INFOISFT' + struct.pack('<I', 13) + b'Lavf60.16.100\0'
         + b'junk' + struct.pack('<I', 3) + b'abc\0')


def played(audio, parts):
    """parts = [(name, samples, times)]: where each is in the DAC's samples
    (whole, in order), and that all the rest from the first on is silence.
    Returns the problems found."""
    bad, at, first = [], 0, None
    rest = bytearray(audio)
    for name, data, times in parts:
        want = bytes(b for b in data for _ in range(times))
        i = audio.find(want, at)
        if i < 0:
            j = audio.find(want[:64], at)
            n = 0
            while j >= 0 and n < len(want) and audio[j + n] == want[n]:
                n += 1
            bad.append('%s is not played whole (%d of %d samples)' % (name, n, len(want)))
            continue
        first = i if first is None else first
        rest[i:i + len(want)] = b'\x80' * len(want)
        at = i + len(want)
    if first is not None:
        extra = sum(1 for b in rest[first:] if b != 0x80)
        if extra:
            bad.append('%d samples that are no file\'s' % extra)
    return bad


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
    check = tp.Checks()
    lib = ps.assemble(open(os.path.join(HERE, 'rom32.asm')).read(), HERE)[0]
    prog, psyms, _ = ps.assemble(open(os.path.join(HERE, 'wave.asm')).read(), HERE)
    plc = gen_plc.make(prog, psyms, lib)[0]
    dos = open(os.path.join(SD, 'DOS.PLC'), 'rb').read()
    base = {'DOS.PLC': dos, 'WAVE.PLC': plc, 'BOOT.CFG': b'WAVE.PLC\r\n'}

    # ---- 1: the folder, three speeds, a file that is not played ----------
    print('1. the SOUNDS folder')
    a, b, c = noise(37001, 1), noise(9001, 2), noise(3999, 3)
    files = dict(base)
    files.update({'SOUNDS/A.WAV': wav(31469, a), 'SOUNDS/B.WAV': wav(15734, b, extra=OTHER),
                  'SOUNDS/README.TXT': b'not a sound\r\n', 'SOUNDS/C.WAV': wav(8000, c),
                  'SOUNDS/D.WAV': wav(44100, noise(4000, 4), ch=2, bits=16)})
    s = tp.Script()
    s.t = 100
    s.shot('a', 0)
    s.shot('b', 60)
    s.shot('c', 35)
    s.shot('d', 40)
    s.shot('dos', 220)
    o = s.run(files, mouse=False, png=args.png, tag='wave1_', audio=True)
    for k in 'abcd':
        print('  %s: %s' % (k, ' | '.join(o[k].rows[r].strip() for r in (3, 5, 7))))
    bad = played(s.audio, [('A.WAV', a, 1), ('B.WAV', b, 2), ('C.WAV', c, 4)])
    check('three files played whole, in order, silence between: %s' % (bad or 'yes'), not bad)
    check('the screen: name, number, speed, time', o['a'].has('PLACARD SOUND PLAYER', 1)
          and o['a'].rows[3].split() == ['A.WAV', '1', 'of', '4'] and o['a'].has('31.5 kHz', 5)
          and o['a'].has(' of 0:01', 7) and o['b'].has('B.WAV', 3) and o['b'].has('15.7 kHz', 5)
          and o['c'].has('C.WAV', 3) and o['c'].has('7.9 kHz', 5) and o['c'].has('0:00 of 0:00', 7))
    check('the 16-bit stereo file is named and not played',
          o['d'].rows[3].split() == ['D.WAV', '4', 'of', '4'] and o['d'].has('Not a WAV file with 8 bits, 1 channel', 5))
    check('after the last file the DOS is back', o['dos'].has('WAVE.PLC') and o['dos'].has('SOUNDS')
          and not o['dos'].has('SOUND PLAYER'))
    print('  the DOS: %r' % o['dos'].rows[0].strip())

    # ---- 2: a long file across the FAT's sectors --------------------------
    print('2. a 300 KB file')
    big = noise(300001, 5)
    for spc in (1, 8):
        files = dict(base)
        files['SOUNDS/BIG.WAV'] = wav(31469, big)
        s = tp.Script()
        s.t = 100 + 300001 * 60 // 31469 + 40
        s.shot('end', 0)
        o = s.run(files, mouse=False, audio=True, spc=spc, size_kb=None if spc == 1 else 20480)
        bad = played(s.audio, [('BIG.WAV', big, 1)])
        check('%d sector%s a cluster: whole, no sample lost: %s' % (spc, '' if spc == 1 else 's', bad or 'yes'), not bad)

    # ---- 3: the keys ------------------------------------------------------
    print('3. the keys')
    one, two = noise(150000, 6), noise(60000, 7)
    files = dict(base)
    files.update({'SOUNDS/ONE.WAV': wav(31469, one), 'SOUNDS/TWO.WAV': wav(31469, two)})
    s = tp.Script()
    s.t = 130
    s.type(' ')                         # pause
    s.shot('paused', 40)
    t_pause = s.t
    s.type(' ')                         # go on
    s.shot('going', 30)
    s.key(tp.K_RIGHT)                   # TWO
    s.shot('two', 40)
    s.key(tp.K_LEFT)                    # ONE again, from its start
    s.shot('one', 40)
    s.key(tp.K_BKSP)                    # before the first: the last
    s.shot('last', 40)
    s.key(tp.K_ESC, hold=20)
    s.shot('dos', 200)
    o = s.run(files, mouse=False, png=args.png, tag='wave3_', audio=True)
    au = s.audio
    i = au.find(one[:64])
    quiet = au[(t_pause - 20) * LINES:(t_pause - 5) * LINES]
    check('Space: silence while paused, "paused" on the screen',
          set(quiet) == {0x80} and o['paused'].has('paused', 7) and not o['going'].has('paused', 7))
    seg = bytes(x for x in au[i:(o_frame(s, 'going')) * LINES] if x != 0x80)
    check('and no sample lost or repeated when it goes on (%d samples)' % len(seg),
          i > 0 and len(seg) > 40000 and one.startswith(seg))
    j = au.find(two[:64], i)
    k = au.find(one[:64], j + 1) if j > 0 else -1
    m = au.find(two[:64], k + 1) if k > 0 else -1
    check('Right: the next file from its start; Left: the one before; Backspace before the first: the last',
          j > 0 and k > j and m > k and o['two'].has('TWO.WAV', 3) and o['one'].has('ONE.WAV', 3)
          and o['last'].rows[3].split() == ['TWO.WAV', '2', 'of', '2'])
    end = o['dos'].ram
    check('Esc: the DOS, the sound buffer silent',
          o['dos'].has('WAVE.PLC') and not o['dos'].has('SOUND PLAYER')
          and set(end[0x5DF3:0x6000]) == {0x80} and set(au[-60 * LINES:]) == {0x80})

    # ---- 4: from Pinboard --------------------------------------------------
    print('4. Pinboard')
    files = sdimage.from_folder(SD)
    files['BOOT.CFG'] = b'PINBOARD.PLC\r\n'
    files['WAVE.PLC'] = plc
    t1, t2 = noise(20000, 8), noise(47000, 9)
    files.update({'TUNES/ONE.WAV': wav(31469, t1), 'TUNES/NOTE.TXT': b'two sounds\r\n',
                  'TUNES/TWO.WAV': wav(31469, t2)})
    img = sdimage.make(files)
    names = [e[0] for e in sdimage.listdir(img)]
    tunes = [e[0] for e in sdimage.listdir(img, 'TUNES') if not e[0].startswith('.')]

    def choose(s, f):
        for _ in range(names.index('TUNES')):
            s.key(tp.K_DOWN)
        s.key(tp.K_ENTER)
        s.wait(40)
        for _ in range(tunes.index(f)):
            s.key(tp.K_DOWN)
    s = tp.Script()
    choose(s, 'TWO.WAV')
    s.shot('chosen')
    s.key(tp.K_ENTER)
    s.shot('playing', 110)
    s.shot('back', 47000 * 60 // 31469 + 180)
    o = s.run(files, png=args.png, tag='wave4_', audio=True)
    p = o['playing']
    print('  %s' % ' | '.join(p.rows[r].strip() for r in (1, 3, 5, 7)))
    bad = played(s.audio[o_frame(s, 'chosen') * LINES:], [('TWO.WAV', t2, 1)])
    check('Enter on TWO.WAV: the player, "2 of 2", the file played whole: %s' % (bad or 'yes'),
          o['chosen'].chosen() == 'TWO.WAV' and p.has('PLACARD SOUND PLAYER', 1)
          and p.rows[3].split() == ['TWO.WAV', '2', 'of', '2'] and not bad)
    bk = o['back']
    check('at its end Pinboard is back, in the folder, the file still chosen',
          bk.has(' Pinboard ', 58) and bk.has('{ TUNES', 2) and bk.chosen() == 'TWO.WAV')
    bare = {k: v for k, v in files.items() if k != 'WAVE.PLC'}
    names = [e[0] for e in sdimage.listdir(sdimage.make(bare))]
    s = tp.Script()
    choose(s, 'ONE.WAV')
    s.key(tp.K_ENTER)
    s.shot('none', 60)
    o = s.run(bare, png=args.png, tag='wave4b_')
    check('no WAVE.PLC on the card: Files says so and stays in the folder',
          o['none'].has('Its program is not on the card', 29) and o['none'].has('{ TUNES', 2))

    # ---- 5: the files on the card -----------------------------------------
    print('5. sdcard/')
    check('sdcard/WAVE.PLC is wave.asm', open(os.path.join(SD, 'WAVE.PLC'), 'rb').read() == plc)
    for n in sorted(os.listdir(os.path.join(SD, 'SOUNDS'))):
        d = open(os.path.join(SD, 'SOUNDS', n), 'rb').read()
        fmt = struct.unpack('<HHIIHH', d[20:36])
        ok = (d[:4] == b'RIFF' and d[8:16] == b'WAVEfmt ' and fmt[0] == 1 and fmt[1] == 1 and fmt[5] == 8
              and fmt[2] in (31469, 15734, 7867) and d[36:40] == b'data'
              and struct.unpack('<I', d[40:44])[0] == len(d) - 44)
        check('%s: 8 bits, 1 channel, %d Hz, %.1f s' % (n, fmt[2], (len(d) - 44) / fmt[2]), ok)

    print('PASS' if check.ok else 'FAIL')
    return 0 if check.ok else 1


def o_frame(s, name):
    return next(t for t, n, _ in s.shots if n == name)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
