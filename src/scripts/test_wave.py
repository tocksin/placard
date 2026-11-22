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
     sample (31,469 Hz once; 15,734 Hz and 8,000 Hz on 2 and 4 lines a
     sample, the lines between two samples with the values between them),
     with silence and nothing else between them; a header with other
     chunks before "data" is walked; the 16-bit stereo file is named and
     skipped; after the last the DOS is back
  2. a 300 KB file on a card with one sector a cluster (the FAT is read
     again every 256 sectors) and on one with 8: whole, no sample lost
     (on the first card the mouse moves all the time)
  3. the keys: Space pauses (silence, no sample lost or repeated when it
     goes on), Enter and Backspace change the file, Esc goes back to the
     DOS with the sound buffer silent
  4. moving in a file: Right and Left go a slider cell on and back; a
     click on the slider goes to that cell, holding the button and moving
     goes along, a click on its first cell starts the file again.  After
     each, the DAC plays the file from the first sample of the sector
     that cell starts at, and nothing else but silence; the time and the
     slider show the place.  The waveform is the samples of a sector of
     the file, a pixel a sample.  The buttons: pause and go on, the next
     file, the one before; the pin goes back to the DOS
  5. Pinboard: Enter on a .WAV file in the Files card plays it (the
     second of its folder: "2 of 2"), and Pinboard comes back in that
     folder with the file still chosen; with no WAVE.PLC, Files says so
  6. sdcard/WAVE.PLC is wave.asm, and sdcard/SOUNDS/*.WAV are files the
     player takes

Date: 11/22/2026
"""

import argparse
import os
import random
import re
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
PX = 0x90                   # wave.masm: wv_pxl, the pointer's X and Y
ROW_T, ROW_INFO, ROW_WAVE, ROW_BAR, ROW_TIME, ROW_BTN = 24, 26, 28, 37, 38, 40
BAR_COL, BTN_P, BTN_H, BTN_N = 8, 27, 36, 47


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


def smooth(data, times):
    """what the DAC plays for a file at 1, 2 or 4 lines a sample: the
    values on the straight line from the sample before (silence before
    the first) to each sample, the sample last (wave.masm: smooth)"""
    if times == 1:
        return bytes(data)
    half = lambda p, c: (p >> 1) + c - (c >> 1)
    out, p = bytearray(), 0x80
    for c in data:
        m = half(p, c)
        out += bytes([m, c]) if times == 2 else bytes([half(p, m), m, half(m, c), c])
        p = c
    return bytes(out)


def played(audio, parts):
    """parts = [(name, samples, times)]: where each is in the DAC's samples
    (whole, in order), and that all the rest from the first on is silence.
    Returns the problems found."""
    bad, at, first = [], 0, None
    rest = bytearray(audio)
    for name, data, times in parts:
        want = smooth(data, times)
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


def card(scr, row):
    """a row of the card, between its edges"""
    return scr.rows[row][8:72]


def info(scr):
    return card(scr, ROW_INFO).split()


def runs(audio, data, start=0):
    """the stretches of the file the DAC played from audio[start] on:
    [(place in audio, place in the file, samples)].  A stretch is found
    by its first 24 samples; a shorter one (the ring is silenced while
    the video reads it, in three pieces) must go on where the stretch
    before it would be."""
    out, i = [], start
    while i < len(audio):
        if audio[i] == 0x80:
            i += 1
            continue
        m = 0
        while m < 24 and i + m < len(audio) and audio[i + m] != 0x80:
            m += 1
        if m == 24:
            j = data.find(audio[i:i + 24])
        else:
            j = out[-1][1] + i - out[-1][0] if out else -1
            if j < 0 or data[j:j + m] != audio[i:i + m]:
                j = -1
        if j < 0:
            i += 1
            continue
        n = 0
        while i + n < len(audio) and j + n < len(data) and audio[i + n] == data[j + n]:
            n += 1
        out.append((i, j, n))
        i += n
    return out


def trace(ram):
    """the waveform's 512 columns: the rows lit in each (0 = the top)"""
    cols = []
    for x in range(512):
        a = 0x6020 + (8 + x // 8) * 512 + ROW_WAVE * 8
        cols.append([y for y in range(64) if ram[a + y] >> (x & 7) & 1])
    return cols


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
    for k in range(40):
        s.shot('f%d' % k, 12)
    o = s.run(files, mouse=False, png=None, audio=True)
    seen = {}
    for k in range(40):
        scr = o['f%d' % k]
        name = (info(scr) or ['?'])[0] if scr.has(' Sound player', ROW_T) else 'dos'
        seen.setdefault(name, scr)
    if args.png:
        for n in seen:
            ps.render(bytearray(seen[n].ram), os.path.join(args.png, 'wave1_%s.png' % n.split('.')[0].lower()))
    for k in ('A.WAV', 'B.WAV', 'C.WAV', 'D.WAV'):
        if k in seen:
            print('  %s | %s' % (' '.join(info(seen[k])), card(seen[k], ROW_TIME).strip()))
    bad = played(s.audio, [('A.WAV', a, 1), ('B.WAV', b, 2), ('C.WAV', c, 4)])
    check('three files played whole, in order, silence between: %s' % (bad or 'yes'), not bad)
    check('the card: its title, the name, number, speed, time',
          all(k in seen for k in ('A.WAV', 'B.WAV', 'C.WAV'))
          and info(seen['A.WAV']) == ['A.WAV', '1', 'of', '4', '31.5', 'kHz']
          and ' of 0:01' in card(seen['A.WAV'], ROW_TIME)
          and info(seen['B.WAV']) == ['B.WAV', '2', 'of', '4', '15.7', 'kHz']
          and info(seen['C.WAV']) == ['C.WAV', '3', 'of', '4', '7.9', 'kHz']
          and ' of 0:00' in card(seen['C.WAV'], ROW_TIME))
    check('the 16-bit stereo file is named and not played',
          'Not' in seen and 'Not a WAV file with 8 bits, 1 channel' in card(seen['Not'], ROW_INFO))
    check('after the last file the DOS is back', 'dos' in seen and seen['dos'].has('WAVE.PLC')
          and seen['dos'].has('SOUNDS'))
    if 'dos' in seen:
        print('  the DOS: %r' % seen['dos'].rows[0].strip())

    # ---- 2: a long file across the FAT's sectors --------------------------
    print('2. a 300 KB file')
    big = noise(300001, 5)
    for spc in (1, 8):
        files = dict(base)
        files['SOUNDS/BIG.WAV'] = wav(31469, big)
        s = tp.Script()
        s.t = 130 + 300001 * 60 // 31469 + 40
        if spc == 1:                    # the mouse moves all the time
            s.inp += [(f, 'mouse', ((f * 7) % 11 - 5, (f * 5) % 9 - 4, 0)) for f in range(60, s.t)]
        s.shot('end', 0)
        o = s.run(files, mouse=spc == 1, audio=True, spc=spc, size_kb=None if spc == 1 else 20480, px=PX)
        bad = played(s.audio, [('BIG.WAV', big, 1)])
        check('%d sector%s a cluster%s: whole, no sample lost: %s'
              % (spc, '' if spc == 1 else 's', ', the mouse moving' if spc == 1 else '', bad or 'yes'), not bad)

    # ---- 3: the keys ------------------------------------------------------
    print('3. the keys')
    one, two = noise(150000, 6), noise(60000, 7)
    files = dict(base)
    files.update({'SOUNDS/ONE.WAV': wav(31469, one), 'SOUNDS/TWO.WAV': wav(31469, two)})
    s = tp.Script()
    s.t = 150
    s.type(' ')                         # pause
    s.shot('paused', 40)
    t_pause = s.t
    s.type(' ')                         # go on
    s.shot('going', 30)
    s.key(tp.K_ENTER)                   # TWO
    s.shot('two', 40)
    s.key(tp.K_BKSP)                    # ONE again, from its start
    s.shot('one', 40)
    s.key(tp.K_BKSP)                    # before the first: the last
    s.shot('last', 40)
    s.key(tp.K_ESC, hold=20)
    s.shot('dos', 200)
    o = s.run(files, mouse=False, png=args.png, tag='wave3_', audio=True)
    au = s.audio
    i = au.find(one[:64])
    quiet = au[(t_pause - 20) * LINES:(t_pause - 5) * LINES]
    check('Space: silence while paused, "paused" on the card, the button says Play',
          set(quiet) == {0x80} and 'paused' in card(o['paused'], ROW_TIME)
          and 'paused' not in card(o['going'], ROW_TIME)
          and 'Play' in card(o['paused'], ROW_BTN) and 'Pause' in card(o['going'], ROW_BTN))
    seg = bytes(x for x in au[i:(o_frame(s, 'going')) * LINES] if x != 0x80)
    check('and no sample lost or repeated when it goes on (%d samples)' % len(seg),
          i > 0 and len(seg) > 40000 and one.startswith(seg))
    j = au.find(two[:64], i)
    k = au.find(one[:64], j + 1) if j > 0 else -1
    m = au.find(two[:64], k + 1) if k > 0 else -1
    check('Enter: the next file from its start; Backspace: the one before; before the first: the last',
          j > 0 and k > j and m > k and info(o['two'])[:1] == ['TWO.WAV'] and info(o['one'])[:1] == ['ONE.WAV']
          and info(o['last'])[:4] == ['TWO.WAV', '2', 'of', '2'])
    end = o['dos'].ram
    check('Esc: the DOS, the sound buffer silent',
          o['dos'].has('WAVE.PLC') and not o['dos'].has('Sound player')
          and set(end[0x5DF3:0x6000]) == {0x80} and set(au[-60 * LINES:]) == {0x80})

    # ---- 4: moving in a file ------------------------------------------------
    print('4. moving in a file')
    lng, sec = noise(200000, 10), noise(150000, 11)
    ts = len(lng) // 512 + 1            # the player's count of the file's sectors

    def place(cell):                    # the file's sample a slider cell starts at
        return -(-cell * ts // 64) * 512 - 44

    cells = {place(c): c for c in range(1, 64)}
    files = dict(base)
    files.update({'SOUNDS/LONG.WAV': wav(31469, lng), 'SOUNDS/SEC.WAV': wav(31469, sec)})
    s = tp.Script()
    s.x, s.y = 320, 368                 # where the player puts the pointer
    s.t = 160
    s.shot('play', 0)
    s.key(tp.K_RIGHT)
    s.key(tp.K_RIGHT)
    s.key(tp.K_LEFT)
    t_keys = s.t + 10
    s.wait(20)
    s.click(BAR_COL + 40, ROW_BAR)      # the slider's cell 40
    s.shot('cell40', 0)
    s.cell(60, 46)
    t_click = s.t
    s.cell(BAR_COL + 50, ROW_BAR)       # hold and move back to cell 20
    s.down()
    s.cell(BAR_COL + 20, ROW_BAR)
    s.wait(10)
    s.up()
    s.cell(60, 46)
    s.shot('cell20', 4)
    t_drag = s.t
    s.click(BAR_COL, ROW_BAR)           # the first cell: from the start
    s.shot('cell0', 0)
    s.cell(60, 46)
    t_zero = s.t
    s.click(BTN_H + 3, ROW_BTN)         # pause
    s.cell(60, 46)
    s.shot('paused', 30)
    t_pause = s.t
    s.click(BTN_H + 3, ROW_BTN)         # go on
    s.cell(60, 46)
    s.shot('going', 20)
    t_going = s.t
    s.click(BTN_N + 2, ROW_BTN)         # the next file
    s.cell(60, 46)
    s.shot('next', 30)
    s.click(BTN_P + 2, ROW_BTN)         # the one before
    s.cell(60, 46)
    s.shot('prev', 30)
    s.click(7, ROW_T)                   # the pin
    s.shot('dos', 200)
    o = s.run(files, png=args.png, tag='wave4_', audio=True, px=PX)
    au = s.audio
    rr = [r for r in runs(au, lng, 0) if r[2] >= 24]
    tails = sum(n for _, _, n in runs(au, lng, 0) if n < 24)
    first = [r for r in rr if r[0] < t_keys * LINES]
    print('  the keys: %s' % ', '.join('sample %d (cell %s), %d played' % (j, cells.get(j, '-'), n) for _, j, n in first))
    ok = (len(first) == 4 and first[0][1] == 0 and all(r[1] in cells for r in first[1:]))
    if ok:
        # the cell that was playing when the key came (the sector read is up
        # to two ahead of the sample heard)
        at = [(j + n + 44) * 64 // (512 * ts) for _, j, n in first[:3]]
        c1, c2, c3 = (cells[r[1]] for r in first[1:])
        ok = c1 - at[0] in (1, 2) and c2 - at[1] in (1, 2) and c3 - at[2] in (-1, 0)
    check('Right, Right, Left: a cell on, on, and back, each from its sector\'s first sample', ok)
    p = o['play']
    tr = trace(p.ram)
    halves = []
    for h in (0, 256):
        want = [63 - (v >> 2) for v in lng]
        got = [t[0] if len(t) == 1 else None for t in tr[h:h + 256]]
        halves.append(any(got == want[n * 512 - 44 + h:n * 512 - 44 + h + 256] for n in range(1, ts)))
    check('the waveform: one pixel a column, each half the samples of a sector of the file', all(halves))
    click = [r for r in rr if t_keys * LINES <= r[0] < t_click * LINES]
    scr = o['cell40']
    bar = card(scr, ROW_BAR)
    print('  cell 40: sample %s, "%s", slider "%s"' % (click[-1][1] if click else None,
                                                     card(scr, ROW_TIME).strip(), bar))
    check('a click on the slider\'s cell 40: the file from that cell\'s first sample (%d)' % place(40),
          len(click) == 1 and click[0][1] == place(40))
    check('the time and the slider show the place (the pointer is on the slider)',
          card(scr, ROW_TIME).strip()[:12] in ('0:03 of 0:06', '0:04 of 0:06') and set(bar[:40]) == {' '}
          and set(bar[46:]) == {'-'} and set(bar[40:46]) <= set(' -?'))
    drag = [r for r in rr if t_click * LINES <= r[0] < t_drag * LINES]
    got = [cells.get(r[1]) for r in drag]
    print('  held from 50 to 20: cells %s' % got)
    check('holding the button and moving: cell 50, cells on the way, cell 20 last',
          len(got) >= 3 and got[0] == 50 and got[-1] == 20 and None not in got and got == sorted(got, reverse=True))
    zero = [r for r in rr if t_drag * LINES <= r[0] < t_zero * LINES]
    print('  first cell: sample %s, "%s"' % (zero[0][1] if zero else None, card(o['cell0'], ROW_TIME).strip()))
    check('a click on its first cell: the file from its start', len(zero) == 1 and zero[0][1] == 0
          and re.search(r':0[01] of 0:06', card(o['cell0'], ROW_TIME)))
    quiet = au[(t_pause - 20) * LINES:(t_pause - 5) * LINES]
    seg = bytes(x for x in au[zero[-1][0]:t_going * LINES] if x != 0x80) if zero else b''
    check('the pause button: silence, "paused", and on again with no sample lost',
          set(quiet) == {0x80} and 'paused' in card(o['paused'], ROW_TIME) and 'Play' in card(o['paused'], ROW_BTN)
          and 'Pause' in card(o['going'], ROW_BTN) and len(seg) > 20000 and lng.startswith(seg))
    j = au.find(sec[:64])
    k = au.find(lng[:64], j) if j > 0 else -1
    check('the >> and << buttons: the next file, the one before',
          j > t_going * LINES and k > j and info(o['next'])[:1] == ['SEC.WAV'] and info(o['prev'])[:1] == ['LONG.WAV'])
    rest = runs(au, sec, 0)
    n_files = sum(n for _, _, n in rr) + tails + sum(n for _, _, n in rest)
    n_all = sum(1 for x in au[60 * LINES:] if x != 0x80)
    print('  %d samples played, %d of them the files\'' % (n_all, n_files))
    check('nothing played but the files\' samples and silence', n_files == n_all)
    end = o['dos'].ram
    check('the pin: the DOS, the sound buffer silent',
          o['dos'].has('WAVE.PLC') and not o['dos'].has('Sound player')
          and set(end[0x5DF3:0x6000]) == {0x80} and set(au[-60 * LINES:]) == {0x80})

    # ---- 5: from Pinboard --------------------------------------------------
    print('5. Pinboard')
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
    o = s.run(files, png=args.png, tag='wave5_', audio=True)
    p = o['playing']
    print('  %s | %s' % (' '.join(info(p)), card(p, ROW_TIME).strip()))
    bad = played(s.audio[o_frame(s, 'chosen') * LINES:], [('TWO.WAV', t2, 1)])
    check('Enter on TWO.WAV: the player\'s card, "2 of 2", its pointer, the file played whole: %s' % (bad or 'yes'),
          o['chosen'].chosen() == 'TWO.WAV' and p.has(' Sound player', ROW_T)
          and info(p) == ['TWO.WAV', '2', 'of', '2', '31.5', 'kHz'] and len(p.pointer()) > 0 and not bad)
    bk = o['back']
    check('at its end Pinboard is back, in the folder, the file still chosen',
          bk.has(' Pinboard ', 58) and bk.has('{ TUNES', 2) and bk.chosen() == 'TWO.WAV')
    bare = {k: v for k, v in files.items() if k != 'WAVE.PLC'}
    names = [e[0] for e in sdimage.listdir(sdimage.make(bare))]
    s = tp.Script()
    choose(s, 'ONE.WAV')
    s.key(tp.K_ENTER)
    s.shot('none', 60)
    o = s.run(bare, png=args.png, tag='wave5b_')
    check('no WAVE.PLC on the card: Files says so and stays in the folder',
          o['none'].has('Its program is not on the card', 29) and o['none'].has('{ TUNES', 2))

    # ---- 6: the files on the card -----------------------------------------
    print('6. sdcard/')
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
