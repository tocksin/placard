#!/usr/bin/env python3
"""
text_demo_sim.py - run text_demo.asm in placard_sim and check it

    python3 text_demo_sim.py                    run 3 s and check the screen
    python3 text_demo_sim.py --png ts.png       also save the last frame
    python3 text_demo_sim.py --gif ts.gif       also an animated GIF
    python3 text_demo_sim.py --fault 0x4321     make one RAM bit fail at that
                                                  address and check that the
                                                  RAM test reports it
    python3 text_demo_sim.py --sd               the SD card program (TEXT.PLC,
                                                  gen_text_demo_sd.py), booted
                                                  from a card as the board does;
                                                  its RAM test covers the free
                                                  RAM only (--fault 0x4321 works)

Boots the ROM image like the board (placard_sim --boot), runs the program
for --seconds of simulated time (60 frames per second, 420,000 clocks per
frame, from the simulator's video line read), then checks the screen text:
the frame count and uptime match the frames run, PASS counts up and ERRORS
is 0 (or, with --fault, 14 a pass and the page's cell is marked E on the
progress bar).
The video stall clocks are modeled (placard_sim Cpu.stalls), and the
busiest frame's work is printed.  It also checks the pixel scroller (the
message row of the 40 column band against the message, the font and the
frame count), the 256-color ring (every ring pixel against HUE and the
phase) and the row tints of rows 0-95 (TINTB, with the raster bar BARP at
BARY[phase / 2]).  Then it presses H and checks the 160-read screen of a
rev B board (check_hires; --hires-png saves it), and H again for the normal
screen.

Date: 11/17/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import test_dos               # noqa: E402

CLOCKS_PER_FRAME = 525 * 800
# the RAM test pages (PAGES in text_demo.asm)
PAGES = list(range(0x01, 0x1F)) + list(range(0x20, 0x50)) + list(range(0x54, 0x5A)) + [0x5C]
NPAGES = len(PAGES)


def check_tint(cpu, syms, rom):
    """rows 0-95: mode byte = TINTB[row], but the raster bar's rows, which
    are BARP from row BARY[phase / 2]"""
    ph = cpu.mem[0x8B]                      # tn_ph
    pos = rom[syms['BARY'] + (ph >> 1)]
    nbar = syms['TN_N']
    bad = []
    for r in range(96):
        want = rom[syms['TINTB'] + r]
        if pos <= r < pos + nbar:
            want = rom[syms['BARP'] + r - pos]
        if cpu.mem[0x5A20 + r] != want:
            bad.append(r)
    if bad:
        print('FAIL: row tints wrong on rows %s (bar at row %d)' % (bad[:8], pos))
        return False
    return True


def check_scroll(cpu, syms, rom, frm):
    """the message row (rows 336-351, 2 bpp 2x): frame 1 shows the message
    from its first pixel and each frame moves it one pixel left, so after
    frm frames screen pixel x is message pixel frm - 1 + x, gold on blue"""
    a = syms['msg']
    msg = []
    while rom[a]:
        msg.append(rom[a])
        a += 1
    # the frame the counter shows may be one behind the frames scrolled
    for s in (frm - 1, frm, frm - 2):
        bad = 0
        for r in range(8):
            off = 0x171 + 2 * r
            for x in range(320):
                p = s + x
                ch = msg[(p // 8) % len(msg)]
                bit = (rom[ps.LIB_FONT + r * 256 + ch] >> (p % 8)) & 1
                byte = cpu.mem[0x6000 + (x // 4) * 512 + off]
                if ((byte >> (2 * (x % 4))) & 3) != (2 if bit else 1):
                    bad += 1
        if not bad:
            print('scroller: the message row matches, %d pixels on' % s)
            return True
    print('FAIL: scroller row does not match the message (%d bad pixels)' % bad)
    return False


def check_ring(cpu, syms, rom):
    n, ph = syms['RING_N'], cpu.mem[syms['wh_ph']]
    bad = 0
    for k in range(n):
        v, x, ang = (rom[syms[t] + k] for t in ('RING_V', 'RING_X', 'RING_A'))
        if cpu.mem[(v << 8) | x] != rom[syms['HUE'] + ((ang + ph) & 0xFF)]:
            bad += 1
    if bad:
        print('FAIL: %d of %d ring pixels wrong' % (bad, n))
        return False
    print('ring: %d pixels, phase %d' % (n, ph))
    return True


def check_hires(rig, syms, rom, png=None):
    """H: the 160-read screen (rev B) and back.  Checks the mode bytes, the
    80 column 4-color text against text_h, "16 COLORS" against SMG, the bars, the wheel's discs, "256" against
    DIGH, the ring against RINGH_R / RINGH_A, and that the normal screen
    comes back as it was."""
    cpu, mem = rig.cpu, rig.cpu.mem
    ok = True

    def fail(msg):
        nonlocal ok
        ok = False
        print('FAIL: 160-read screen: ' + msg)

    def modes(want):
        got = [mem[0x5A20 + r] for r in range(96, 480)]
        return got == want

    def text_cells():
        # the 1 bpp text of the rows that never change (title, character
        # set, RAM AREA, ruler, legend)
        return [mem[0x6020 + col * 512 + 8 * r + k] for r in (0, 1, 2, 3, 4, 9, 10, 11)
                for col in range(80) for k in range(8)]

    normal = [0x0A] * 128 + [0x05] * 128 + [0x0B] * 128
    before = bytes(mem[0x6000:0x10000])
    text_before = text_cells()
    cpu.rev_b = True
    rig.key('h')
    rig.run(40)
    if mem[syms['hx']] != 1 or not modes([0x86] * 128 + [0x05] * 128 + [0x8B] * 128):
        fail('H did not switch the mode bytes')
        return False
    def at(col, row, mode):
        return mem[(0x60 + col) << 8 | ps.hires_offset(row, mode)]

    if [mem[0x5A20 + r] for r in range(96)] != [0x85] * 96:
        fail('rows 0-95 are not 2 bpp 2x 160-read')
    # the 80 column 4-color text: every cell of the 6 text rows
    want = {}
    a = syms['text_h']
    while rom[a] != 0xFF:
        col, row, fg, bg, st = rom[a], rom[a + 1], rom[a + 2], rom[a + 3], rom[a + 4] | rom[a + 5] << 8
        a += 6
        while rom[st]:
            want[(col, row)] = (rom[st], fg, bg)
            col += 1
            st += 1
    if max(c for c, r in want) > 79:
        fail('a line of the 80 column text is too long')
    bad = 0
    for row in range(6):
        for col in range(80):
            ch, fg, bg = want.get((col, row), (0x20, 0, 0))
            for fr in range(8):
                f = rom[ps.LIB_FONT + fr * 256 + ch]
                for k, tab in enumerate(('EXP2_LO', 'EXP2_HI')):
                    bad += at(2 * col + k, 16 * row + 2 * fr, 0x85) != (rom[syms[tab] + f] & fg) ^ bg
    if bad:
        fail('%d bytes of the 80 column 4-color text wrong' % bad)
    frame_h = mem[syms['FRM']:syms['FRM'] + 5]

    # "16 COLORS": 16 x 16 letters from SMG, 8 bytes each from byte column 4
    bad = 0
    for i in range(9):
        g = syms['SMG'] + 32 * rom[syms['S16H'] + i]
        fill = rom[syms['RAINBOW'] + i]
        for k in range(32):
            for j in range(4):
                want = rom[syms['EXP4_%d' % j] + rom[g + k]] & fill
                bad += at(4 + 8 * i + 4 * (k & 1) + j, 96 + 2 * (k >> 1), 0x86) != want
    if bad:
        fail('%d bytes of "16 COLORS" wrong' % bad)
    bad = 0
    for row in range(136, 220, 2):          # the 16 colors, 6 bytes each
        bad += sum(at(4 + c, row, 0x86) != (c // 6) * 0x11 for c in range(96))
    if bad:
        fail('%d bytes of the 16 color bars wrong' % bad)
    bad = 0
    ph = mem[syms['big_ph']]
    for k in range(8):                      # the wheel's discs
        fill = rom[syms['TAIL'] + ((ph - k) & 7)]
        for r in range(8):
            for j in range(4):
                want = rom[syms['DISC'] + 4 * r + j] & fill
                bad += at(rom[syms['DOTCH'] + k] + j, rom[syms['DOTRH'] + k] + 2 * r, 0x86) != want
    if bad:
        fail('%d bytes of the wheel wrong' % bad)
    bad = 0
    for d in range(3):                      # "256", 24 x 28
        for r in range(28):
            bits = sum(rom[syms['DIGH'] + 84 * d + 3 * r + b] << (8 * b) for b in range(3))
            shade = rom[syms['SHADES'] + 8 * d + r // 4]
            for c in range(28):
                want = shade if (bits >> c) & 1 else 0
                bad += at(4 + 28 * d + c, 352 + 4 * (2 + r), 0x8B) != want
    if bad:
        fail('%d bytes of "256" wrong' % bad)
    bad = n = 0
    a, ang, ph = syms['RINGH_R'], syms['RINGH_A'], mem[syms['wh_ph']]
    while rom[a]:                           # the ring
        for i in range(rom[a + 2]):
            bad += mem[(rom[a + 1] + i) << 8 | rom[a]] != rom[syms['HUE'] + ((rom[ang + n] + ph) & 0xFF)]
            n += 1
        a += 3
    if bad:
        fail('%d of %d ring pixels wrong' % (bad, n))
    if png:
        ps.render(mem, png, rev_b=True)
        print('wrote', png)
    # and back
    rig.key('h')
    rig.run(40)
    cpu.rev_b = False
    if mem[syms['hx']] != 0 or not modes(normal):
        fail('H did not switch back')
        return False
    ring = {(rom[syms['RING_V'] + k] << 8) | rom[syms['RING_X'] + k] for k in range(syms['RING_N'])}
    bad = wheel = 0
    for page in range(0x61, 0x100, 2):
        for blk in range(32):
            ad = page << 8 | (0x83 + 4 * blk)             # the 256 band
            if ad not in ring and mem[ad] != before[ad - 0x6000]:
                bad += 1
            ad = page << 8 | (0x81 + 4 * blk)             # the 16-color band
            wheel += mem[ad] != before[ad - 0x6000]
        for off in range(0x101, 0x171, 2):              # 40 column rows 0-6
            bad += mem[page << 8 | off] != before[(page << 8 | off) - 0x6000]
    if text_cells() != text_before:
        fail('the 80 column text did not come back')
    if bad or wheel > 64:
        fail('the normal screen did not come back (%d bytes, %d in the wheel band)' % (bad, wheel))
    if ok:
        print('H: the 160-read screen (80 column 4-color text, letters, bars, wheel, digits, %d ring pixels) and back' % n)
    return ok


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
    ap.add_argument('--sd', action='store_true', help='TEXT.PLC from a card')
    ap.add_argument('--hires-png', help='also save the 160-read screen (H key, rev B)')
    args = ap.parse_args(argv)
    args.sd = True      # the ROM build went on 2026-11-11 (docs/architecture/ROM.md)
    global PAGES, NPAGES

    if args.sd:
        import gen_text_demo_sd
        import gen_plc
        src, mem, syms, PAGES = gen_text_demo_sd.build()
        NPAGES = len(PAGES)
        lib, _, _ = ps.assemble('#include "placard.asm"\n#include "placard_lib.asm"\n', HERE)
        data, _, _, entry = gen_plc.make(mem, syms, lib)
        rig = test_dos.boot_plc('TEXT.PLC', data, entry)
        if rig is None:
            return 1
        cpu = rig.cpu
        rom = bytearray(65536)                  # the ROM's font, the program's tables
        for a, v in ps.build_rom(mem).items():
            rom[a] = v
        for a, v in mem.items():
            if a < 0x4000:
                rom[a] = v
    else:
        src = open(os.path.join(HERE, 'text_demo.asm')).read()
        mem, syms, _ = ps.assemble(src, HERE)
        rom = ps.build_rom(mem)
        cpu = ps.Cpu({}, rom=rom)
    cpu.stalls = True
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
        cell = tuple(rom[ps.LIB_FONT + k * 256 + code] for k in range(8))
        font.setdefault(cell, chr(code) if code < 0x80 else chr(code - 0x80).lower()
                        if chr(code - 0x80).isalpha() else '#')

    # draw the screen: run until the frame loop starts
    t0 = cpu.clocks
    r = cpu.run(50_000_000, halt_detect=False, stop_pc=syms['td_loop'])
    if r != 'stop':
        sys.exit('did not reach the frame loop: ' + r)
    t_draw = cpu.clocks - t0
    print('screen drawn in %d clocks (%.1f ms)' % (t_draw, t_draw / 25175.0))

    frames = []
    nframes = int(args.seconds * 60)
    start = cpu.clocks
    p_work, p_loop = syms['td_tint'], syms['td_loop']
    t_work, busiest = None, 0
    for f in range(1, nframes + 1):
        target = start + f * CLOCKS_PER_FRAME
        while cpu.clocks < target:
            cpu.step()
            if cpu.pc == p_work:
                t_work = cpu.clocks
            elif cpu.pc == p_loop and t_work is not None:
                busiest = max(busiest, cpu.clocks - t_work)
                t_work = None
        if args.gif and f % args.gif_step == 0:
            path = os.path.join(HERE, '_td_frame.png')
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

    print('busiest frame: %d clocks of work (%d in a frame)' % (busiest, CLOCKS_PER_FRAME))
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
    if passes != frm // NPAGES:
        print('FAIL: %d passes for %d frames (%d pages a pass)' % (passes, frm, NPAGES))
        ok = False
    if args.fault is None:
        if errors or 'e' in rows[8]:
            print('FAIL: RAM test errors %d' % errors)
            ok = False
    else:
        page = args.fault >> 8
        idx = PAGES.index(page)
        # a bad page fails every pattern (bit 3 always matters): 14 a pass
        expect = 14 * (passes + (1 if (frm % NPAGES) > idx else 0))
        if errors != expect:
            print('FAIL: %d errors, expected %d' % (errors, expect))
            ok = False
        if passes == 0 and frm > idx and rows[8][11 + idx // 2] != 'e':
            print('FAIL: page %02X not marked on the progress bar' % page)
            ok = False
    ok = check_scroll(cpu, syms, rom, frm) and ok
    ok = check_ring(cpu, syms, rom) and ok
    ok = check_tint(cpu, syms, rom) and ok
    if args.sd:
        ok = check_hires(rig, syms, rom, args.hires_png) and ok
        ok = check_ring(cpu, syms, rom) and ok
        ok = check_tint(cpu, syms, rom) and ok
        ok = test_dos.esc_to_dos(rig) and ok
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
