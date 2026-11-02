#!/usr/bin/env python3
"""
test_tracker.py - run TRACKER.PLC (tracker.masm) through the ROM's loader in
placard_sim

    python3 test_tracker.py                    the checks below
    python3 test_tracker.py --png tracker.png  also the screen as a PNG

Builds the 32K ROM and a card holding DOS.PLC, TRACKER.PLC and TRACKER.OVL
(from tracker.asm, gen_plc.split_overlay) and DEMO.SNG (from
../music/demo.mus), BOOT.CFG = TRACKER.PLC, and boots it like the board
(test_dos.Rig):
  1. the DOS loads TRACKER.PLC, which reads the overlay, loads DEMO.SNG and
     reaches its frame loop with the map at FF
  2. the screen (80 x 30 on 2x lines): header, order list, instrument, the
     pattern grid; the grid's first rows match the song's pattern bytes
  3. Enter plays the song: the audio buffer fills, the header says PLAY, the
     row being played is tinted green; Esc stops it
  4. editing: Z puts a C-4 with the current instrument in the cell, Down
     moves, Del clears, Tab cycles the panes, the cursor row is tinted blue
  5. Ctrl-W saves TEST.SNG; the file on the card holds the edited note;
     Ctrl-O loads it back and the grid still shows it
  6. Ctrl-X twice brings the DOS's browser back

Date: 11/02/2026
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
OVL_START, OVL_STEP = 0xA800, 2
CTRL = 0x14                   # PS/2 set 2: left Ctrl


class Rig(test_dos.Rig):
    def __init__(self, *a):
        super().__init__(*a)
        self.glyphs7 = {}            # the cursor underlines a glyph's last line
        for ch in ['.'] + [chr(c) for c in range(0x20, 0x7F)]:    # '.' before ','
            rows = next((k for k, v in self.glyphs.items() if v == ch), None)
            if rows is not None:
                self.glyphs7.setdefault(rows[:7], ch)

    def row(self, r):
        """text row r of the 2x screen (tracker.masm TADDR: the odd pages)"""
        mem = self.cpu.mem
        out = ''
        for col in range(80):
            base = 0x6100 + col * 512
            off = 32 + 16 * r if r < 14 else 1 + 16 * (r - 14)
            rows = tuple(mem[base + off + 2 * k] for k in range(8))
            out += self.glyphs.get(rows) or self.glyphs7.get(rows[:7], '?')
        return out.rstrip()

    def zp(self, name):
        return self.cpu.mem[self.tsyms[name]]

    def grid_row(self):
        """the screen row of the pattern cursor"""
        return 14 + self.zp('c_row') - self.zp('c_top')

    def tint(self, r):
        """the tint bits of text row r's mode bytes"""
        return self.cpu.mem[0x5A20 + 16 * r] & 0x70

    def ctrl(self, ch):
        self.port.kbd.press(CTRL)
        self.run(2)
        self.key(ch)
        self.port.kbd.release(CTRL)
        self.run(2)


def cell(row, v):
    """voice v's cell of a grid row: 'C-4 03 ...'"""
    return row[6 + 12 * v:16 + 12 * v]


def expect_cell(song, pat, r):
    """the cell text the tracker shows for row r of pattern pat"""
    rows = mus_tool.unpack_rows(song.patterns[pat])
    note, ins, fx, par = rows[r] if r < len(rows) else (None, None, None, 0)
    n = '...' if note is None else '===' if note == 'off' else mus_tool.note_name(note)
    i = '--' if ins is None else '%02X' % ins
    f = '...' if fx is None else '%X%02X' % (fx, par)
    return '%s %s %s' % (n, i, f)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    rom, syms, dsyms, lib, dos_plc = test_dos.build()
    trk, tsyms, _ = ps.assemble(open(os.path.join(HERE, 'tracker.asm')).read(), HERE)
    for name in ('main', 'ovl_load', 'exit_dos', 'tr_leave', 'tputc', 'l_fs_open', 'l_kbd_getc', 'l_vid_mode'):
        if tsyms[name] >= 0x3400:
            raise SystemExit('%s is at x%04X: it must stay below the overlay (tracker.masm)'
                             % (name, tsyms[name]))
    low, ovl = gen_plc.split_overlay(trk, lib, OVL_START, OVL_STEP)
    trk_plc = gen_plc.make(low, tsyms, lib)[0]
    song = mus_tool.parse_mus(open(os.path.join(HERE, '..', 'music', 'demo.mus')).read())
    files = {'DOS.PLC': dos_plc, 'TRACKER.PLC': trk_plc, 'TRACKER.OVL': ovl,
             'DEMO.SNG': song.binary(), 'BOOT.CFG': b'TRACKER.PLC\r\n'}
    r = Rig(rom, syms, dsyms, lib, sdimage.make(files))
    r.tsyms = tsyms
    cpu, mem = r.cpu, r.cpu.mem
    cpu.stalls = True
    loop = tsyms['loop']

    print('1. TRACKER.PLC starts, reads the overlay and loads DEMO.SNG')
    if r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7, 300, 'TRACKER.PLC to start'):
        print('  started at frame %d' % (cpu.clocks // FRAME))
    if r.run_until(lambda: cpu.pc == loop and cpu.map == 0xFF, 600, 'the frame loop'):
        print('  frame loop at frame %d, map %02X' % (cpu.clocks // FRAME, cpu.map))
    pages = [bytes(mem[(OVL_START >> 8) + OVL_STEP * k << 8:((OVL_START >> 8) + OVL_STEP * k << 8) + 256])
             for k in range(len(ovl) // 256)]
    # the player patches its own mixer code (a few dozen bytes), the rest must match
    diffs = sum(a != b for a, b in zip(b''.join(pages), ovl))
    if diffs > 64:
        r.fail('the overlay is not in its pages: %d bytes differ' % diffs)
    if bytes(mem[tsyms['SONG'] + 0x20:tsyms['SONG'] + 0x2C]) != b'PLACARD DEMO':
        r.fail('the song title is not at SONG + x20')

    print('2. the screen')
    r.run(12)                   # the grid is drawn a voice column a frame
    for row in (0, 2, 3, 4, 12, 13, 14, 15, 16, 28, 29):
        print('  row %2d: %r' % (row, r.row(row)))
    if not r.row(0).startswith(' PLACARD TRACKER') or 'DEMO.SNG' not in r.row(0):
        r.fail('the header')
    if not r.row(2).startswith('  ORDER') or 'INSTRUMENT' not in r.row(2):
        r.fail('the order and instrument titles')
    if not r.row(12).startswith(' PATTERN') or not r.row(13).startswith('  ROW'):
        r.fail('the pattern title rows')
    if r.tint(0) != 0x30 or r.tint(29) != 0x30:
        r.fail('the header and keys rows are not gold (%02X, %02X)' % (r.tint(0), r.tint(29)))
    # the orderlists' first position: pattern per voice, and the grid's rows
    pats = [mem[tsyms['VSPAGE'] * 256 + v * 256 + tsyms['OD_PAT']] for v in range(4)]
    print('  position 0 patterns: %s' % pats)
    for rr in range(4):
        row = r.row(14 + rr)
        for v in range(4):
            want = expect_cell(song, pats[v], rr)
            if cell(row, v) != want:
                r.fail('row %d voice %d: %r, song says %r' % (rr, v + 1, cell(row, v), want))
    if args.png:
        ps.render(mem, args.png)
        print('  wrote', args.png)

    print('3. play')
    r.key('\n')
    r.run(60)
    if all(b == 0x80 for b in mem[0x5DF3:0x6000]):
        r.fail('the audio buffer is silent a second after Enter')
    if 'PLAY' not in r.row(0):
        r.fail('the header does not say PLAY: %r' % r.row(0))
    greens = [rr for rr in range(14, 28) if r.tint(rr) in (0x20, 0x60)]  # cyan: cursor follows
    print('  header: %r' % r.row(0))
    print('  green rows: %s' % greens)
    if not greens:
        r.fail('no row is tinted green while playing')
    r.key('\x1b')
    r.run(2)
    if 'STOP' not in r.row(0):
        r.fail('Esc did not stop: %r' % r.row(0))
    r.run(100)
    if not all(b == 0x80 for b in mem[0x5DF3:0x6000]):
        r.fail('not silent after Esc')
    print('  Esc: stopped, silent')

    print('4. editing')
    g = r.grid_row()            # the cursor followed the song: wherever it stopped
    prow = r.zp('c_row')
    r.key('z')
    r.run(2)
    c = cell(r.row(g), 0)
    print('  Z: pattern row %d voice 1 = %r' % (prow, c))
    if not c.startswith('C-4 '):
        r.fail('Z did not put C-4 in the cell')
    g2 = r.grid_row()
    if g2 != g + 1:
        r.fail('Z did not step down (%d -> %d)' % (g, g2))
    if r.tint(g2) != 0x40 or r.tint(g) == 0x40:
        r.fail('the blue row did not follow the cursor (%02X %02X)' % (r.tint(g), r.tint(g2)))
    r.key('q')                  # C-5 on the next row
    r.run(2)
    if not cell(r.row(g2), 0).startswith('C-5 '):
        r.fail('Q did not put C-5 in the next row: %r' % cell(r.row(g2), 0))
    r.ctrl('q')                 # up
    r.run(2)
    if r.grid_row() != g2:
        r.fail('Up did not move the cursor back (%d)' % r.grid_row())
    r.key('\x7f')               # clear it
    r.run(2)
    if not cell(r.row(g2), 0).startswith('... --'):
        r.fail('Del did not clear the cell: %r' % cell(r.row(g2), 0))
    print('  Q, Up, Del: %r' % cell(r.row(g2), 0))
    for pane in range(5):
        r.key('\t')
        r.run(2)
        if pane == 0 and r.tint(3) != 0x40:
            r.fail('Tab: the order pane cursor row is not blue (%02X)' % r.tint(3))
    if r.zp('e_pane') != 0:
        r.fail('five Tabs did not come back to the pattern pane (%d)' % r.zp('e_pane'))
    print('  Tab x5: pane back to the pattern, rows 2-3: %r | %r' % (r.row(3)[:40], r.row(3)[40:]))

    print('5. save and load')
    r.ctrl('w')
    r.run(2)
    print('  status: %r' % r.row(28))
    if not r.row(28).startswith(' Save as:'):
        r.fail('Ctrl-W did not ask for a name')
    r.type('test.sng')
    r.key('\n')
    r.run(30)
    print('  status: %r' % r.row(28))
    if 'Saved' not in r.row(28):
        r.fail('not saved')
    img = r.port.sd.image
    saved = sdimage.read(img, 'TEST.SNG')
    print('  TEST.SNG: %d bytes' % len(saved))
    if saved[:4] != b'PMU\x01':
        r.fail('TEST.SNG has no song header')
    else:
        n = saved[5]
        off = saved[0x80 + pats[0]] | saved[0xC0 + pats[0]] << 8
        rows = mus_tool.unpack_rows(saved[off:])
        print('  %d patterns; pattern %d row %d: %s' % (n, pats[0], prow, rows[prow] if prow < len(rows) else None))
        if prow >= len(rows) or rows[prow][0] != 48:
            r.fail('the saved file does not hold the C-4')
    r.ctrl('o')
    r.run(2)
    if not r.row(28).startswith(' Load:'):
        r.fail('Ctrl-O did not ask for a name: %r' % r.row(28))
    r.type('test.sng')
    r.key('\n')
    r.run(30)
    print('  status: %r' % r.row(28))
    if 'Loaded' not in r.row(28):
        r.fail('not loaded')
    c = cell(r.row(14 + prow), 0)
    if not c.startswith('C-4 '):
        r.fail('the saved note is gone after loading: %r' % c)
    print('  pattern row %d voice 1 after the reload: %r' % (prow, c))

    print('6. Ctrl-X')
    r.ctrl('x')
    r.run(2)
    print('  status: %r' % r.row(28))
    r.ctrl('x')
    if r.wait_browser(300):
        print('  the browser is back at frame %d' % (cpu.clocks // FRAME))
    print('all passed' if r.ok else 'FAILED')
    return 0 if r.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
