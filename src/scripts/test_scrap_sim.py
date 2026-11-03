#!/usr/bin/env python3
"""
test_scrap_sim.py - run SCRAP.PLC (scrap.masm, SCRAPWRIGHT phase 2) through
the ROM's loader in placard_sim

    python3 test_scrap_sim.py                  the checks below
    python3 test_scrap_sim.py --png scrap.png  also the screen as a PNG

Builds the 32K ROM and a card holding DOS.PLC, SCRAP.PLC (from scrap.asm)
and SCRAP.OVL (gen_scrap.py), BOOT.CFG = SCRAP.PLC, with a PS/2 mouse in
the upper socket, and boots it like the board (test_dos.Rig):
  1. the DOS loads SCRAP.PLC, which reads SCRAP.OVL into the even video
     pages (the map) and reaches its frame loop with the map at FF
  2. the view: all 20 x 12 cells match the map and the cell art
     (gen_scrap.py) byte for byte; the panel shows the player (YOU)
  3. walking: Right steps east a cell at a time (keys held), Up / Down /
     W / S too; walls stop the player
  4. doors: walking into a closed door opens it (it is drawn open)
  5. the mouse: moving it frames the cell under it and the panel names it;
     a left click locks the panel, the action keys 1-4 run the menu
     (CLOSE / OPEN on a door next to the player, INSPECT writes the
     message line); a right click unlocks
  6. the camera steps when the player walks off the view, and the view
     still matches the map
  7. Esc brings the DOS's browser back

Date: 2026-11-03
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402
import gen_scrap              # noqa: E402
import io_devices             # noqa: E402
import test_dos               # noqa: E402
import test_tracker           # noqa: E402

FRAME = test_dos.FRAME
VIEW_W, VIEW_H = 20, 12
RIGHT, LEFT, UP, DOWN = '\x14', '\x13', '\x11', '\x12'
T = gen_scrap.TYPE
ARTS = [gen_scrap.art_bytes(t[1]) for t in gen_scrap.TYPES]


def line_off(p):
    """offset in its page of 2x line pair p (VIDEO.md: lines 0-223 at 32 up)"""
    return 2 * p + 32 if p < 112 else 2 * p - 223


class Rig(test_tracker.Rig):
    def __init__(self, *a):
        super().__init__(*a)
        self.inv = {tuple(b ^ 0xFF for b in k): v for k, v in self.glyphs.items()}

    def text(self, r):
        """text row r with inverse letters in lower case"""
        mem = self.cpu.mem
        out = ''
        for col in range(80):
            base = 0x6100 + col * 512
            off = 32 + 16 * r if r < 14 else 1 + 16 * (r - 14)
            rows = tuple(mem[base + off + 2 * k] for k in range(8))
            ch = self.glyphs.get(rows)
            if ch is None:
                ch = self.inv.get(rows, '?').lower()
            out += ch
        return out.rstrip()

    def zp(self, name):
        return self.cpu.mem[self.tsyms[name]]

    def map_t(self, x, y):
        k = 6 * (y >> 4) + (x >> 4)
        return self.cpu.mem[((0x60 + 4 * k) << 8) + 16 * (y & 15) + (x & 15)]

    def cell_bytes(self, cx, cy):
        """the 64 bytes on the screen of view cell cx, cy (art_bytes order)"""
        mem = self.cpu.mem
        out = bytearray(64)
        for c in range(4):
            page = 0x61 + 2 * (4 * cx + c)
            for y in range(16):
                out[16 * c + y] = mem[(page << 8) + line_off(16 * cy + y)]
        return bytes(out)

    def check_view(self, what):
        """every view cell against the map in RAM and the art; the framed
        cell is left out (its border is drawn over it)"""
        vx, vy, px, py = self.zp('v_x'), self.zp('v_y'), self.zp('p_x'), self.zp('p_y')
        frame = (self.zp('fr_x'), self.zp('fr_y')) if self.zp('fr_on') else None
        bad = []
        for cy in range(VIEW_H):
            for cx in range(VIEW_W):
                x, y = vx + cx, vy + cy
                if (x, y) == frame:
                    continue
                if (x, y) == (px, py):
                    t = T['PLAYER']
                elif x < gen_scrap.MAP_W and y < gen_scrap.MAP_H:
                    t = self.map_t(x, y)
                else:
                    t = T['SPACE']
                if self.cell_bytes(cx, cy) != ARTS[t]:
                    bad.append((cx, cy, gen_scrap.TYPES[t][0]))
        if bad:
            self.fail('%s: %d view cells differ from the map, first %s' % (what, len(bad), bad[:4]))
        else:
            print('  %s: all %d view cells match (view at %d,%d, player %d,%d)'
                  % (what, VIEW_W * VIEW_H, vx, vy, px, py))

    def hold(self, ch, frames):
        code = self.codes[ch]
        self.port.kbd.press(code)
        self.run(frames)
        self.port.kbd.release(code)
        self.run(3)

    def mouse_to(self, x, y):
        """moves the pointer to screen x, y (from where the program has it)"""
        cx = self.zp('m_xl') | self.zp('m_xh') << 8
        cy = self.zp('m_yl') | self.zp('m_yh') << 8
        self.port.mouse.move(x - cx, cy - y)        # PS/2 Y counts up
        self.run(4)

    def click(self, b):
        self.port.mouse.move(0, 0, b)
        self.run(3)
        self.port.mouse.move(0, 0, 0)
        self.run(3)

    def mouse_cell(self, x, y):
        """the pointer onto map cell x, y (in the view)"""
        self.mouse_to(32 * (x - self.zp('v_x')) + 16, 32 * (y - self.zp('v_y')) + 16)

    def panel(self):
        return [self.text(r) for r in range(24, 30)]


def build():
    rom, syms, dsyms, lib, dos_plc = test_dos.build()
    t, d = gen_scrap.build_map()
    ovl = b''.join(gen_scrap.map_pages(t, d))
    src = open(os.path.join(HERE, 'scrap.asm')).read()
    prog, tsyms, _ = ps.assemble(src, HERE)
    if any(0x4000 <= a < 0xC000 for a in prog):
        raise SystemExit('scrap.asm reaches past x3FFF')
    plc = gen_plc.make(prog, tsyms, lib)[0]
    return rom, syms, dsyms, lib, dos_plc, plc, tsyms, ovl


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    rom, syms, dsyms, lib, dos_plc, plc, tsyms, ovl = build()
    files = {'DOS.PLC': dos_plc, 'SCRAP.PLC': plc, 'SCRAP.OVL': ovl,
             'BOOT.CFG': b'SCRAP.PLC\r\n'}
    r = Rig(rom, syms, dsyms, lib, sdimage.make(files))
    r.port.mouse = io_devices.Ps2Mouse(bat_ms=50)
    r.tsyms = tsyms
    cpu, mem = r.cpu, r.cpu.mem
    loop = tsyms['loop']

    print('1. SCRAP.PLC starts and reads SCRAP.OVL')
    if r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7, 300, 'SCRAP.PLC to start'):
        print('  started at frame %d' % (cpu.clocks // FRAME))
    if r.run_until(lambda: cpu.pc == loop and cpu.map == 0xFF, 600, 'the frame loop'):
        print('  frame loop at frame %d, map %02X' % (cpu.clocks // FRAME, cpu.map))
    t, d = gen_scrap.build_map()
    pages = gen_scrap.map_pages(t, d)
    diffs = [k for k, p in enumerate(pages) if bytes(mem[(0x60 + 2 * k) << 8:((0x60 + 2 * k) << 8) + 256]) != p]
    if diffs:
        r.fail('map pages differ from SCRAP.OVL: %s' % diffs[:6])
    else:
        print('  the map is in its 48 even pages')
    if not r.zp('m_ok'):
        r.fail('mouse_init did not find the mouse')
    if (r.zp('p_x'), r.zp('p_y')) != gen_scrap.START:
        r.fail('the player starts at %d,%d' % (r.zp('p_x'), r.zp('p_y')))

    print('2. the screen')
    r.run(4)
    r.check_view('start')
    for line in r.panel():
        print('  |%s' % line)
    p = r.panel()
    if p[0].strip() != 'YOU' or 'MK1 WORK SUIT' not in p[1] or 'INSPECT' not in p[1]:
        r.fail('the panel does not show the player')
    if not p[5].strip().startswith('DOCKED TO THE KESTREL 9'):
        r.fail('the welcome message')
    if mem[0x5BA0] & 0x70 != 0x40 or mem[0x5BF0] & 0x70 != 0x30:
        r.fail('the panel tints (%02X %02X)' % (mem[0x5BA0], mem[0x5BF0]))

    print('3. walking')
    x0, y0 = r.zp('p_x'), r.zp('p_y')
    door = (x0, y0 - 1)                         # the open door above the start
    if r.map_t(*door) != T['DOORO']:
        r.fail('no open door above the start')
    r.hold('w', 2)
    if r.zp('p_y') != y0 - 1:
        r.fail('W did not step up into the doorway (y %d)' % r.zp('p_y'))
    r.hold('s', 2)
    r.hold(DOWN, 2)
    if r.zp('p_y') != y0 + 1:
        r.fail('S, Down did not step down (y %d)' % r.zp('p_y'))
    r.hold(UP, 2)
    if r.zp('p_y') != y0:
        r.fail('Up did not step up')
    print('  W, S, Down, Up: one cell each')
    r.hold(RIGHT, 20)
    x1 = r.zp('p_x')
    print('  Right held 20 frames: x %d -> %d' % (x0, x1))
    if not 2 <= x1 - x0 <= 4 or r.zp('p_y') != y0:
        r.fail('Right did not walk east a few cells')
    r.hold(UP, 40)
    print('  Up held into the bulkhead at %d,%d: y stays %d' % (x1, y0 - 1, r.zp('p_y')))
    if r.zp('p_y') != y0:
        r.fail('walked through the wall')
    r.check_view('after walking')
    while r.zp('p_x') != door[0]:
        r.hold(LEFT, 2)

    print('4. the mouse and the menu')
    r.mouse_cell(*door)
    print('  pointer at %d,%d: frame on %d at %d,%d'
          % (r.zp('m_xl') | r.zp('m_xh') << 8, r.zp('m_yl') | r.zp('m_yh') << 8,
             r.zp('fr_on'), r.zp('fr_x'), r.zp('fr_y')))
    if not r.zp('fr_on') or (r.zp('fr_x'), r.zp('fr_y')) != door:
        r.fail('the frame is not on the hovered door')
    p = r.panel()
    for line in p:
        print('  |%s' % line)
    if not p[0].strip().startswith('DOOR (OPEN)'):
        r.fail('the panel does not name the door: %r' % p[0])
    if 'DAMAGE' not in p[0]:
        r.fail('no damage bar for the door')
    if 'CLOSE' not in p[1]:
        r.fail('no CLOSE in the menu')
    r.click(1)
    if not r.zp('lock'):
        r.fail('a left click did not lock the panel')
    r.mouse_cell(door[0] + 3, door[1] + 1)      # away: the panel stays on the door
    if 'DOOR' not in r.panel()[0]:
        r.fail('the locked panel followed the pointer: %r' % r.panel()[0])
    r.key('1')                                  # CLOSE
    r.run(2)
    if r.map_t(*door) != T['DOOR']:
        r.fail('key 1 (CLOSE) did not close the door')
    else:
        print('  key 1: CLOSE -> %r' % r.panel()[0].strip())
    r.key('1')                                  # OPEN
    r.run(2)
    if r.map_t(*door) != T['DOORO']:
        r.fail('key 1 (OPEN) did not open the door')
    r.key('3')                                  # INSPECT (CLOSE, WALK HERE, INSPECT)
    r.run(2)
    msg = r.panel()[5]
    print('  key 1 again: OPEN; key 3: %r' % msg.strip())
    if 'OPEN PRESSURE DOOR' not in msg:
        r.fail('INSPECT did not write the message line')
    r.key('1')                                  # CLOSE, for the bump below
    r.run(2)
    r.click(2)
    if r.zp('lock'):
        r.fail('a right click did not unlock')
    r.mouse_cell(r.zp('p_x'), r.zp('p_y'))
    if r.panel()[0].strip() != 'YOU':
        r.fail('hovering the player does not show YOU: %r' % r.panel()[0])
    r.check_view('after the mouse')

    print('5. doors')
    r.hold(UP, 2)               # bump: the door opens, the player stays
    if r.map_t(*door) != T['DOORO'] or r.zp('p_y') != y0:
        r.fail('the bump did not open the door (type %d, y %d)' % (r.map_t(*door), r.zp('p_y')))
    else:
        print('  walked into the closed door: it opened')
    r.check_view('door open')



    print('6. the camera')
    r.hold(UP, 2)               # back to the corridor, then east to the airlock
    r.hold(DOWN, 2)
    v0 = r.zp('v_x')
    r.hold(RIGHT, 7 * 40)
    print('  Right to x %d: view x %d -> %d' % (r.zp('p_x'), v0, r.zp('v_x')))
    if r.zp('v_x') == v0:
        r.fail('the camera did not step')
    if not 0 < r.zp('p_x') - r.zp('v_x') < VIEW_W - 1:
        r.fail('the player is off the view')
    r.run(4)
    r.check_view('after the camera step')
    if args.png:
        r.mouse_cell(r.zp('p_x') + 2, r.zp('p_y') - 1)
        r.run(2)
        ps.render(mem, args.png)
        print('  wrote', args.png)

    print('7. Esc')
    test_dos.esc_to_dos(r)
    print('PASS' if r.ok else 'FAILED')
    return 0 if r.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
