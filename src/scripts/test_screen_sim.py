#!/usr/bin/env python3
"""
test_screen_sim.py - run test_screen.asm in placard_sim and check it

    python3 test_screen_sim.py                    run 3 s and check the screen
    python3 test_screen_sim.py --png ts.png       also save the last frame
    python3 test_screen_sim.py --gif ts.gif       also an animated GIF
    python3 test_screen_sim.py --fault 0x4321     make one RAM bit fail at that
                                                  address and check that the
                                                  RAM test reports it

Boots the ROM image like the board (placard_sim --boot), runs the program
for --seconds of simulated time (60 frames per second, 420,000 clocks per
frame, from the simulator's video line read), then checks the screen text:
the frame count and uptime match the frames run, PASS counts up and ERRORS
is 0 (or, with --fault, not 0 and the page is marked E on the progress bar).
Video stalls are not modeled, so the CPU runs about 10 % faster than on the
board; the program only does a bounded amount of work per frame, so the
frame timing is the same.

Date: 10/17/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402

CLOCKS_PER_FRAME = 525 * 800


def text_row(cpu, row, font):
    """the 80 characters of 1 bpp text row 0-11, read back from the video
    RAM by matching each 8x8 cell against the library font (? if none)"""
    out = []
    for col in range(80):
        cell = tuple(cpu.mem[0x6000 + col * 512 + 32 + row * 8 + k] for k in range(8))
        out.append(font.get(cell, '?'))
    return ''.join(out)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=float, default=3.0)
    ap.add_argument('--png')
    ap.add_argument('--gif')
    ap.add_argument('--gif-step', type=int, default=3, help='frames per GIF frame')
    ap.add_argument('--fault', type=lambda s: int(s, 0),
                    help='RAM address whose bit 3 always reads back flipped')
    args = ap.parse_args(argv)

    src = open(os.path.join(HERE, 'test_screen.asm')).read()
    mem, syms, _ = ps.assemble(src, HERE)
    rom = ps.build_rom(mem)
    cpu = ps.Cpu({}, rom=rom)
    if args.fault is not None:
        plain = cpu.read

        def faulty(ad):
            v = plain(ad)
            return v ^ 0x08 if ad == args.fault else v
        cpu.read = faulty

    # font: cell bytes -> character (the console draws codes 20-7E and their
    # inverse 80-FF; this reads a cell back as the character it shows)
    font = {}
    for code in list(range(0x20, 0x7F)) + list(range(0xA0, 0xFF)):
        cell = tuple(rom[ps.LIB_START + 0x800 + k * 256 + code] for k in range(8))
        font.setdefault(cell, chr(code) if code < 0x80 else chr(code - 0x80).lower()
                        if chr(code - 0x80).isalpha() else '#')

    # draw the screen: run until the frame loop starts
    r = cpu.run(50_000_000, halt_detect=False, stop_pc=syms['ts_loop'])
    if r != 'stop':
        sys.exit('did not reach the frame loop: ' + r)
    t_draw = cpu.clocks
    print('screen drawn in %d clocks (%.1f ms)' % (t_draw, t_draw / 25175.0))

    frames = []
    nframes = int(args.seconds * 60)
    start = cpu.clocks
    for f in range(1, nframes + 1):
        target = start + f * CLOCKS_PER_FRAME
        while cpu.clocks < target:
            cpu.step()
        if args.gif and f % args.gif_step == 0:
            path = os.path.join(HERE, '_ts_frame.png')
            ps.render(cpu.mem, path)
            from PIL import Image
            frames.append(Image.open(path).convert('P', palette=Image.ADAPTIVE, colors=255))
            os.remove(path)
    if args.png:
        ps.render(cpu.mem, args.png)
        print('wrote', args.png)
    if args.gif:
        frames[0].save(args.gif, save_all=True, append_images=frames[1:],
                       duration=int(1000 * args.gif_step / 60), loop=0)
        print('wrote', args.gif, len(frames), 'frames')

    rows = {r: text_row(cpu, r, font) for r in (6, 7, 8)}
    for r in rows.values():
        print('|' + r + '|')
    ok = True
    frm = int(rows[6][58:63])
    up = rows[6][37:45]
    secs = int(up[0:2]) * 3600 + int(up[3:5]) * 60 + int(up[6:8])
    passes = int(rows[7][47:53].split()[0])
    errors = int(rows[7][63:70].split()[0])
    # the frame loop counts frames from its first poll, so allow one off
    if abs(frm - nframes) > 1:
        print('FAIL: frame count %d, expected %d' % (frm, nframes))
        ok = False
    if secs != frm // 60:
        print('FAIL: uptime %s for %d frames' % (up, frm))
        ok = False
    if passes != frm // 47:
        print('FAIL: %d passes for %d frames (47 pages a pass)' % (passes, frm))
        ok = False
    if args.fault is None:
        if errors or 'e' in rows[8]:
            print('FAIL: RAM test errors %d' % errors)
            ok = False
    else:
        page = args.fault >> 8
        pages = list(range(0x01, 0x20)) + list(range(0x40, 0x50))
        idx = pages.index(page)
        # a bad page: one bad read for each pattern whose bit 3 differs,
        # every pattern but none (bit 3 always matters), so 14 per pass
        expect = 14 * (passes + (1 if (frm % 47) > idx else 0))
        if errors != expect:
            print('FAIL: %d errors, expected %d' % (errors, expect))
            ok = False
        if passes == 0 and rows[8][11 + idx] != 'e':
            print('FAIL: page %02X not marked on the progress bar' % page)
            ok = False
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
