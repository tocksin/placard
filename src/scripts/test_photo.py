#!/usr/bin/env python3
"""
test_photo.py - run PHOTO.PLC (photo.masm) through the ROM's loader in placard_sim

    python3 test_photo.py                the checks below
    python3 test_photo.py --png DIR      also every picture's screen as
                                         DIR/<name>_screen.png (160 across, rev B)
                                         and DIR/<name>_80.png (80 across)

Builds the 32K ROM and a card holding DOS.PLC, PHOTO.PLC (from photo.asm),
the folder PHOTOS with the .PIC files of sdcard/PHOTOS and a file that is
not a picture, BOOT.CFG = PHOTO.PLC, and boots it like a rev B board
(test_dos.Rig) with the video stalls modeled:
  1. the DOS loads PHOTO.PLC, which counts the pictures and asks
  2. H: every row's mode byte is x87 and the video RAM x6000-xFFFF is the
     first file, byte for byte; how long the picture took
  3. Space, Right, Enter go through the pictures and around to the first;
     Left and Backspace go back
  4. H changes the rows to x07 (80 across) and back, the picture stays
  5. S starts the slide show: the next picture by itself within 10 s
  6. Esc brings the DOS's browser back
  7. a card without the folder: the message

Date: 11/21/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402
import test_dos               # noqa: E402

FRAME = test_dos.FRAME
PHOTOS = os.path.join(HERE, '..', '..', 'sdcard', 'PHOTOS')


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png', metavar='DIR')
    args = ap.parse_args(argv)
    rom, syms, dsyms, lib, dos_plc = test_dos.build()
    prog, psyms, _ = ps.assemble(open(os.path.join(HERE, 'photo.asm')).read(), HERE)
    plc = gen_plc.make(prog, psyms, lib)[0]
    if plc != open(os.path.join(HERE, '..', '..', 'sdcard', 'PHOTO.PLC'), 'rb').read():
        print('FAIL: sdcard/PHOTO.PLC is not photo.asm (run gen_plc.py)')
        return 1
    names = sorted(n for n in os.listdir(PHOTOS) if n.endswith('.PIC'))
    pics = [open(os.path.join(PHOTOS, n), 'rb').read() for n in names]
    files = {'DOS.PLC': dos_plc, 'PHOTO.PLC': plc, 'BOOT.CFG': b'PHOTO.PLC\r\n',
             'PHOTOS/README.TXT': b'not a picture\r\n'}
    for n, d in zip(names, pics):
        files['PHOTOS/' + n] = d
    r = test_dos.Rig(rom, syms, dsyms, lib, sdimage.make(files))
    cpu, mem = r.cpu, r.cpu.mem
    cpu.stalls = True
    cpu.rev_b = True

    def at_loop():
        return cpu.pc == psyms['loop'] and cpu.map == 7

    def shown():
        got = bytes(mem[0x6000:0x10000])
        return pics.index(got) if got in pics else None

    def press(ch, want, what):
        r.port.kbd.press(r.codes[ch])
        r.run(3)
        r.port.kbd.release(r.codes[ch])
        r.run(2)
        if not at_loop():
            r.run_until(at_loop, 120, what)
        if shown() != want:
            r.fail('%s: picture %r, not %d' % (what, shown(), want))
        else:
            print('  %-10s %s' % (what + ':', names[want]))

    print('1. PHOTO.PLC starts and counts the pictures')
    r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7, 300, 'PHOTO.PLC to start')
    r.run_until(lambda: cpu.pc == psyms['in_loop'] and cpu.map == 7, 200, 'the question')
    for row in (1, 3, 6, 7, 10, 11):
        print('  row %2d: %r' % (row, r.row(row)))
    if r.row(3).strip() != '%d pictures in the PHOTOS folder' % len(pics):
        r.fail('the count')

    print('2. H: 160 across')
    t0 = cpu.clocks
    r.port.kbd.press(r.codes['h'])
    r.run(3)
    r.port.kbd.release(r.codes['h'])
    r.run_until(at_loop, 200, 'the first picture')
    print('  the picture took %d frames from the key' % ((cpu.clocks - t0) // FRAME))
    if any(mem[ps.MODE_BASE + y] != 0x87 for y in range(480)):
        r.fail('mode bytes are not x87')
    if any(mem[0x5A00 + k] for k in range(32)):
        r.fail('mode bytes x5A00-x5A1F are not 0')
    if shown() != 0:
        r.fail('the video RAM is not %s' % names[0])
    if args.png:
        os.makedirs(args.png, exist_ok=True)

    def shot(k):
        if args.png:
            base = os.path.join(args.png, names[k][:-4].lower())
            ps.render(mem, base + '_screen.png', True)
            for y in range(480):
                mem[ps.MODE_BASE + y] = 0x07
            ps.render(mem, base + '_80.png', True)
            for y in range(480):
                mem[ps.MODE_BASE + y] = 0x87
    shot(0)

    print('3. the keys')
    n = len(pics)
    keys = [(' ', 'Space'), ('\x14', 'Right'), ('\n', 'Enter')]
    k = 0
    for i in range(n):
        k = (k + 1) % n
        press(keys[i % 3][0], k, keys[i % 3][1])
        shot(k)
    press('\x13', n - 1, 'Left')
    press('\x08', n - 2, 'Backspace')
    k = n - 2

    print('4. H: 80 across and back')
    r.key('h')
    r.run(2)
    if any(mem[ps.MODE_BASE + y] != 0x07 for y in range(480)) or shown() != k:
        r.fail('H did not make the rows x07')
    r.key('h')
    r.run(2)
    if any(mem[ps.MODE_BASE + y] != 0x87 for y in range(480)) or shown() != k:
        r.fail('H did not make the rows x87 again')
    print('  x07, then x87, the picture stays')

    print('5. S: the slide show')
    r.key('s')
    t0 = cpu.clocks
    r.run_until(lambda: shown() == (k + 1) % n and at_loop(), 600, 'the next picture by itself')
    print('  next picture after %.1f s' % ((cpu.clocks - t0) / FRAME / 60))
    r.key('s')

    print('6. Esc')
    r.key('\x1b', hold=6)
    if r.wait_browser(300):
        print('  the browser is back at frame %d' % (cpu.clocks // FRAME))

    print('7. a card without the folder')
    del files['PHOTOS/README.TXT']
    for nm in names:
        del files['PHOTOS/' + nm]
    r2 = test_dos.Rig(rom, syms, dsyms, lib, sdimage.make(files))
    r2.cpu.stalls = True
    r2.run_until(lambda: r2.cpu.pc == psyms['fl_loop'] and r2.cpu.map == 7, 500, 'the message')
    print('  row 3: %r' % r2.row(3))
    if 'no PHOTOS folder' not in r2.row(3):
        r2.fail('the message')
    ok = r.ok and r2.ok
    print('all passed' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
