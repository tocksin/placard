#!/usr/bin/env python3
"""
test_play.py - run PLAY.PLC (play.masm) through the ROM's loader in placard_sim

    python3 test_play.py                 the checks below
    python3 test_play.py --png play.png  also the screen as a PNG

Builds the 32K ROM and a card holding DOS.PLC, PLAY.PLC (from play.asm) and
DEMO.SNG (from ../music/demo.mus), BOOT.CFG = PLAY.PLC, and boots it like the
board (test_dos.Rig) with the video stalls modeled:
  1. the DOS loads PLAY.PLC, which loads DEMO.SNG and reaches its frame loop
  2. the screen: the title, the song's title, the four voices
  3. after a second the audio buffer holds the song (not all 80h) and the
     voices show notes and instruments
  4. 1 starts a sound effect (the fifth voice); S stops the song; Space
     starts it again
  5. Esc brings the DOS's browser back

Date: 11/01/2026
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
import mus_tool               # noqa: E402

FRAME = test_dos.FRAME


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    rom, syms, dsyms, lib, dos_plc = test_dos.build()
    play, psyms, _ = ps.assemble(open(os.path.join(HERE, 'play.asm')).read(), HERE)
    play_plc = gen_plc.make(play, psyms, lib)[0]
    song = mus_tool.parse_mus(open(os.path.join(HERE, '..', 'music', 'demo.mus')).read()).binary()
    files = {'DOS.PLC': dos_plc, 'PLAY.PLC': play_plc, 'DEMO.SNG': song,
             'BOOT.CFG': b'PLAY.PLC\r\n'}
    r = test_dos.Rig(rom, syms, dsyms, lib, sdimage.make(files))
    cpu, mem = r.cpu, r.cpu.mem
    cpu.stalls = True

    print('1. PLAY.PLC starts and loads the song')
    if r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7, 300, 'PLAY.PLC to start'):
        print('  started at frame %d' % (cpu.clocks // FRAME))
    if r.run_until(lambda: cpu.pc == psyms['loop'] and cpu.map == 7, 200, 'the frame loop'):
        print('  frame loop at frame %d' % (cpu.clocks // FRAME))
    if bytes(mem[0x2A00:0x2A00 + len(song)]) != song:
        r.fail('DEMO.SNG is not at x2A00')

    print('2. the screen')
    r.run(2)
    for row in (0, 1, 3, 6, 8, 10, 12):
        print('  row %2d: %r' % (row, r.row(row)))
    if r.row(0).strip() != 'PLACARD MUSIC PLAYER':
        r.fail('the title')
    if r.row(1).strip() != 'PLACARD DEMO':
        r.fail("the song's title")
    for v in range(4):
        if not r.row(6 + 2 * v).strip().startswith('Voice %d' % (v + 1)):
            r.fail('voice %d row' % (v + 1))

    print('3. the song plays')
    r.run(60)
    buf = mem[0x5DF3:0x6000]
    if all(b == 0x80 for b in buf):
        r.fail('the audio buffer is silent after a second')
    rows = [r.row(6 + 2 * v) for v in range(4)]
    for row in rows:
        print('  ' + row)
    if not rows[0].split()[2:3] or rows[0].split()[2] == '---':
        r.fail('voice 1 shows no note')
    if 'BASS' not in rows[0] or 'KICK' not in rows[1] and 'HAT' not in rows[1]:
        r.fail('the instrument names')
    m_sfxn = psyms['M_SFXN']
    if mem[psyms['M_PLAY']] != 0x81:
        r.fail('M_PLAY = %02X' % mem[psyms['M_PLAY']])
    if args.png:
        ps.render(mem, args.png)
        print('  wrote', args.png)

    print('4. keys')
    r.key('1')
    if mem[m_sfxn] == 0:
        r.fail('1 did not start a sound effect')
    print('  1: sound effect, %d frames left; row 4: %r' % (mem[m_sfxn], r.row(12)))
    r.key('s')
    r.run(2)
    if mem[psyms['M_PLAY']] != 0x80:
        r.fail('S did not stop the song (M_PLAY = %02X)' % mem[psyms['M_PLAY']])
    r.run(120)
    buf = mem[0x5DF3:0x6000]
    if not all(b == 0x80 for b in buf):
        r.fail('not silent two seconds after S')
    print('  S: stopped, silent')
    r.key(' ')
    r.run(30)
    if mem[psyms['M_PLAY']] != 0x81 or all(b == 0x80 for b in mem[0x5DF3:0x6000]):
        r.fail('Space did not start the song again')
    print('  Space: playing again, row 1: %r' % r.row(6))

    print('5. Esc')
    r.key('\x1b', hold=6)
    if r.wait_browser(300):
        print('  the browser is back at frame %d' % (cpu.clocks // FRAME))
    print('all passed' if r.ok else 'FAILED')
    return 0 if r.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
