#!/usr/bin/env python3
"""
test_menu.py - run the demo menu (menu.masm, MENU.PLC) through the ROM's loader in
placard_sim

    python3 test_menu.py                 the checks below, with short times
    python3 test_menu.py --png m.png     also the menu screen as a PNG

Builds the 32K ROM (rom32.asm) and a card holding DOS.PLC, the demo .PLC files from
../../sdcard and a MENU.PLC assembled here with short times (each program
40 frames in turn, Mandelbrot 60, the menu's idle time 2 s), BOOT.CFG =
MENU.PLC, and boots it like the board (test_dos.Rig):
  1. in turn: the DOS runs MENU.PLC, which asks for the programs in order
     1-9 and then 1 again; when each one starts, its RAM is exactly its file
     (a RAM image: x0000-x49FF; a library program: from its load address),
     MB_PARENT names the menu, MB_LEFT is the time limit
  2. Esc on the PS/2 keyboard in a program brings the menu's screen back
     (through the DOS), with the highlight on that program
  3. Down moves the highlight; 3 runs Mandelbrot, picked: it runs past the
     time limit, until Esc brings the menu back
  4. with no key for the idle time the menu runs them in turn again, from
     the highlighted program
  5. Esc in the menu goes to the DOS's file browser

Date: 11/02/2026
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402
import test_dos               # noqa: E402

FRAME = test_dos.FRAME
MB, MB_GO = test_dos.MB, test_dos.MB_GO
PROGS = ['CPUTEST.PLC', 'PI.PLC', 'MANDEL.PLC', 'LIFE.PLC',
         'BOING.PLC', 'WIRE3D.PLC', 'RAYCAST.PLC', 'SCROLLER.PLC', 'RAYTEX.PLC']
EXTRA = ['SCROLLER.OVL', 'RAYTEX.OVL']            # files the programs read themselves


def menu_plc(lib, rot, man, idle):
    """MENU.PLC from menu.asm with other times, and its symbols"""
    src = open(os.path.join(HERE, 'menu.asm')).read()
    for name, v in (('ROT_FRAMES', rot), ('MAN_FRAMES', man), ('IDLE_SECS', idle)):
        src, n = re.subn(r'^(%s\s*=\s*)\d+' % name, r'\g<1>%d' % v, src, flags=re.M)
        assert n == 1, name
    mem, syms, _ = ps.assemble(src, HERE)
    data, kind, load, entry = gen_plc.make(mem, syms, lib)
    return data, syms


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    rom, syms, dsyms, lib, dos_plc = test_dos.build()
    rot, man, idle = 40, 60, 2
    files = {n: open(os.path.join(test_dos.SDCARD, n), 'rb').read() for n in PROGS + EXTRA}
    hdr = {}
    for n in PROGS:
        f = files[n]
        hdr[n] = (f[3], f[4] | f[5] << 8, f[16:16 + 64], f[8] | f[9] << 8)   # type, load, bytes, entry
    files['MENU.PLC'], msyms = menu_plc(lib, rot, man, idle)
    files['BOOT.CFG'] = b'MENU.PLC\r\n'
    files['DOS.PLC'] = dos_plc
    r = test_dos.Rig(rom, syms, dsyms, lib, sdimage.make(files))
    cpu, mem = r.cpu, r.cpu.mem

    def in_menu(label):
        a = msyms[label]
        return cpu.pc == a and cpu.map == 7 and mem[MB + 0x11] != 0x4D

    launches = []

    def started():
        """a RAM image at MB_GO, or a library program at its entry (map 07,
        its first bytes at its load address, MB_MENU = "M")"""
        if cpu.pc == MB_GO:
            return True
        if cpu.map != 7 or mem[MB + 0x11] != 0x4D:
            return False
        i = mem[MB + 0x0D]
        if i >= len(PROGS):
            return False
        kind, load, first, entry = hdr[PROGS[i]]
        return kind == 0 and cpu.pc == entry and bytes(mem[load:load + len(first)]) == first

    def next_launch(frames):
        """run to the next program start: (program, mode)"""
        if not r.run_until(started, frames, 'a program start'):
            return None
        i = mem[MB + 0x0D]
        mode = mem[MB + 3]
        body = files[PROGS[i]][16:]
        if hdr[PROGS[i]][0] == 1:
            want = bytes(body) + bytes(0x4A00 - len(body))
            got = bytes(mem[0:0x4A00])
            base = 0
        else:
            base = hdr[PROGS[i]][1]
            want = bytes(body)
            got = bytes(mem[base:base + len(body)])
            if base <= 0x1F00 < base + len(body):     # LIB_RAM is put back over the file's bytes
                n = min(0x2000, base + len(body)) - 0x1F00
                want = want[:0x1F00 - base] + got[0x1F00 - base:0x1F00 - base + n] + want[0x1F00 - base + n:]
        if got != want:
            bad = [a for a in range(len(want)) if got[a] != want[a]]
            r.fail('%s: RAM differs from the file at %d bytes, first x%04X'
                   % (PROGS[i], len(bad), base + bad[0]))
        left = mem[MB + 4] + 256 * mem[MB + 5]
        want_left = man if PROGS[i] == 'MANDEL.PLC' else rot
        if mode == 0 and left != want_left:
            r.fail('%s: time limit %d frames, not %d' % (PROGS[i], left, want_left))
        parent = bytes(mem[MB + 0x40:MB + 0x49])
        if parent != b'MENU.PLC\0':
            r.fail('MB_PARENT = %r' % parent)
        launches.append((i, mode))
        print('  start %d %-12s %s  (frame %d)' % (i + 1, PROGS[i],
              'in turn' if mode == 0 else 'picked', cpu.clocks // FRAME))
        return i, mode

    # 1. in turn, 1-9 then 1 again
    print('1. in turn')
    if r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7, 200, 'MENU.PLC to start'):
        print('  MENU.PLC started at frame %d' % (cpu.clocks // FRAME))
    for want in list(range(len(PROGS))) + [0]:
        got = next_launch(150)
        if got is None:
            break
        if got != (want, 0):
            r.fail('expected program %d in turn, got %s' % (want + 1, got))
    # 2. Esc in a program (the CPU test is running again now)
    print('2. Esc')
    r.run(5)
    r.port.kbd.press(r.codes['\x1b'])
    found = r.run_until(lambda: in_menu('menu_loop'), 120, 'the menu after Esc')
    r.port.kbd.release(r.codes['\x1b'])
    if found:
        r.run(6)
        sel = mem[msyms['m_sel']]
        print('  menu shown at frame %d, highlight on %d, MB_WHY %d' % (cpu.clocks // FRAME, sel + 1, mem[MB + 9]))
        if mem[MB + 9] != 1:
            r.fail('MB_WHY = %d, not 1 (Esc)' % mem[MB + 9])
        if sel != 0:
            r.fail('the highlight is not on the CPU test')
        if 'P L A C A R D' not in r.row(3):
            r.fail('the menu title is not on row 3: %r' % r.row(3))
        titles = ['CPU test', 'Pi', 'Mandelbrot', 'Game of Life', 'Boing ball', '3D ships',
                  'Ray caster', 'Runner', 'Textured maze']
        row0 = msyms['LIST_ROW']
        for k in range(len(PROGS)):
            if titles[k] not in r.row(row0 + 2 * k):
                r.fail('row %d: %r' % (row0 + 2 * k, r.row(row0 + 2 * k)))
    if args.png:
        ps.render(mem, args.png)
        print('  wrote', args.png)
    # 3. Down, then 3: Mandelbrot picked, runs past the limit
    print('3. pick')
    r.key('\x12')
    if mem[msyms['m_sel']] != 1:
        r.fail('Down: highlight on %d, not 2' % (mem[msyms['m_sel']] + 1))
    else:
        print('  Down: highlight on 2')
    r.port.kbd.press(r.codes['3'])
    got = next_launch(20)
    r.port.kbd.release(r.codes['3'])
    if got != (2, 1):
        r.fail('3: expected Mandelbrot picked, got %s' % (got,))
    end = cpu.clocks + 100 * FRAME
    while cpu.clocks < end:
        cpu.step()
        if cpu.pc == MB_GO or in_menu('menu_loop'):
            r.fail('the picked program stopped at frame %d' % (cpu.clocks // FRAME))
            break
    else:
        print('  still running after 100 frames (limit %d)' % man)
    r.port.kbd.press(r.codes['\x1b'])
    found = r.run_until(lambda: in_menu('menu_loop'), 120, 'the menu after Esc')
    r.port.kbd.release(r.codes['\x1b'])
    if found:
        r.run(6)
        print('  Esc: menu, highlight on %d' % (mem[msyms['m_sel']] + 1))
    # 4. idle: in turn again from the highlighted program
    print('4. idle')
    got = next_launch(idle * 60 + 60)
    if got != (2, 0):
        r.fail('idle: expected Mandelbrot in turn, got %s' % (got,))
    # 5. Esc in the menu: the DOS
    print('5. Esc to the DOS')
    r.port.kbd.press(r.codes['\x1b'])
    found = r.run_until(lambda: in_menu('menu_loop'), 120, 'the menu after Esc')
    r.port.kbd.release(r.codes['\x1b'])
    if found:
        r.run(6)
        r.key('\x1b')
        if r.wait_browser(120):
            print('  the DOS browser: %r' % r.row(0))
            if r.find_row('MENU.PLC') is None:
                r.fail('MENU.PLC is not in the browser\'s list')
    print('OK' if r.ok else 'FAILED')
    return 0 if r.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
