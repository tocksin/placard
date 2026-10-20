#!/usr/bin/env python3
"""
test_menu.py - run the menu ROM (menu.asm, gen_menu_rom.py) in placard_sim

    python3 test_menu.py                 the checks below, with short times
    python3 test_menu.py --png m.png     also the menu screen as a PNG

Builds the ROM in memory with short times (each program 40 frames in turn,
Mandelbrot 60 (its 3 minutes scaled the same way),
a finished result 20 frames, the menu's idle time 2 s; the files on disk
are not changed), boots it like the board and checks:
  1. in turn: the programs start in order 1-6 and then 1 again; each RAM
     program's RAM x0000-x49FF is exactly its image when it starts (the
     loader), and the CPU test's grid is all green when it leaves
  2. Esc in a program (the text demo) shows the menu (MB_WHY = 1)
  3. Down moves the highlight; 3 runs Mandelbrot, picked: it runs past the
     time limit, until Esc brings the menu back
  4. with no key for the idle time the menu runs them in turn again, from
     the highlighted program
Keys are pressed on the keyboard model (io_devices.SharedPort).

Date: 10/20/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import io_devices             # noqa: E402
import gen_menu_rom           # noqa: E402

FRAME = 525 * 800
ESC, DOWN, ENTER, KEY3 = (0, 0), (7, 6), (5, 0), (0, 3)
MB = 0x5D00


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    rom, syms, progs = gen_menu_rom.build(rotate_frames=40, hold_frames=20, idle_s=2,
                                          write=False, quiet=True)
    port = io_devices.SharedPort()
    cpu = ps.Cpu({}, rom=rom, io=port)
    p_launch, p_back, p_loop = syms['launch'], syms['menu_back'], syms['menu_loop']
    ok = True

    def at(a):
        """the CPU is at menu code a (a ROM address, not a RAM program's)"""
        return cpu.pc == a and not (cpu.map >> (a >> 13)) & 1

    def fail(msg):
        nonlocal ok
        ok = False
        print('FAIL:', msg)

    def run_until(cond, frames, what):
        end = cpu.clocks + frames * FRAME
        while cpu.clocks < end:
            cpu.step()
            if cond():
                return True
        fail('%s: not within %d frames' % (what, frames))
        return False

    def press(key, frames=3):
        """hold a key for some frames; True if a program starts meanwhile
        (then it is let go there)"""
        port.keys.add(key)
        end = cpu.clocks + frames * FRAME
        while cpu.clocks < end:
            cpu.step()
            if at(p_launch):
                break
        port.keys.discard(key)
        return at(p_launch)

    def expected_ram(p):
        img = bytearray(0x4A00)
        for a, v in p['own'].items():
            img[a] = v
        return img

    launches = []

    def next_launch(frames, here=False):
        """run to the next start of a program (here: at it now): (index, mode)"""
        if not here and not run_until(lambda: at(p_launch), frames,
                                      'a program start'):
            return None
        i = cpu.mem[syms['m_p']]
        mode = cpu.mem[MB + 3]
        # follow it into the program: a RAM one through the loader to MB_GO
        p = progs[i]
        if p['kind'] == 'ram':
            if run_until(lambda: cpu.pc == MB + 0x28, 20, 'the loader'):
                got = bytes(cpu.mem[0:0x4A00])
                want = bytes(expected_ram(p))
                if got != want:
                    bad = [a for a in range(0x4A00) if got[a] != want[a]]
                    fail('%s: RAM differs from the image at %d bytes, first x%04X'
                         % (p['file'], len(bad), bad[0]))
        left = cpu.mem[MB + 4] + 256 * cpu.mem[MB + 5]
        if p['kind'] == 'ram' and mode == 0 and left != p['rot']:
            fail('%s: time limit %d frames, not %d' % (p['file'], left, p['rot']))
        launches.append((i, mode))
        print('  start %d %-17s %s  (frame %d)' % (i + 1, p['file'],
              'in turn' if mode == 0 else 'picked', cpu.clocks // FRAME))
        return i, mode

    # 1. in turn, 1-6 then 1 again
    print('1. in turn')
    for want in [0, 1, 2, 3, 4, 5, 0]:
        r = next_launch(120)
        if r is None:
            break
        if r != (want, 0):
            fail('expected program %d in turn, got %s' % (want + 1, r))
        if want == 0 and len(launches) == 1:
            # the CPU test finishes, shows its grid, then the next program
            if run_until(lambda: at(p_back), 120, 'the CPU test to finish'):
                bar = [cpu.mem[0x6828 + 2 * k * 256] for k in range(71)]
                if set(bar) != {0xE0}:
                    fail('the CPU test bar is not all green: %s' % sorted(set(bar)))
                else:
                    print('  CPU test: green bar, every test passed')
    # 2. Esc in the text demo
    print('2. Esc')
    while launches[-1][0] != 4:
        if next_launch(120) is None:
            break
    for _ in range(5 * FRAME // 3):
        cpu.step()
    press(ESC)
    if run_until(lambda: at(p_loop), 60, 'the menu after Esc'):
        if cpu.mem[MB + 9] != 1:
            fail('MB_WHY = %d, not 1 (Esc)' % cpu.mem[MB + 9])
        print('  menu shown, highlight on %d' % (cpu.mem[syms['m_sel']] + 1))
        if cpu.mem[syms['m_sel']] != 4:
            fail('the highlight is not on the text demo')
    if args.png:
        ps.render(cpu.mem, args.png)
        print('  wrote', args.png)
    # 3. Down, then 3: Mandelbrot picked, runs past the limit
    print('3. pick')
    press(DOWN)
    for _ in range(3 * FRAME // 3):
        cpu.step()
    if cpu.mem[syms['m_sel']] != 5:
        fail('Down: highlight on %d, not 6' % (cpu.mem[syms['m_sel']] + 1))
    else:
        print('  Down: highlight on 6')
    r = next_launch(10, press(KEY3))
    if r != (2, 1):
        fail('3: expected Mandelbrot picked, got %s' % (r,))
    n0 = len(launches)
    end = cpu.clocks + 100 * FRAME
    while cpu.clocks < end:
        cpu.step()
        if at(p_launch) or at(p_back):
            fail('the picked program stopped at frame %d' % (cpu.clocks // FRAME))
            break
    else:
        print('  still running after 100 frames (limit 40)')
    press(ESC)
    if run_until(lambda: at(p_loop), 60, 'the menu after Esc'):
        print('  Esc: menu, highlight on %d' % (cpu.mem[syms['m_sel']] + 1))
    # 4. idle: in turn again from the highlighted program
    print('4. idle')
    r = next_launch(3 * 60 + 30)
    if r != (2, 0):
        fail('idle: expected Mandelbrot in turn, got %s' % (r,))
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
