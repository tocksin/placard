#!/usr/bin/env python3
"""
test_scrap_sim.py - run SCRAP.PLC (scrap.masm, SCRAPWRIGHT phase 2) through
the ROM's loader in placard_sim

    python3 test_scrap_sim.py                  the checks below
    python3 test_scrap_sim.py --png scrap.png  also the screen as a PNG (and
                                               scrap_air.png)

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
  7. the tug's O2 tank: PICK UP (the tug has no air), PUT DOWN (it has)
  8. CUT FREE a bolted crate in the wreck (time, battery), PICK UP, the
     slower walk; the last step by WALK HERE
  9. the vented section: its decks frosted; opening its door drains the
     corridor's air and the suit uses its O2
 10. each warning (red), then suffocating
 11. Enter starts again; REFILL SUIT from the tug's tank (it is empty
     after, and the tug has no air)
 12. Esc brings the DOS's browser back

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

    def map_raw(self, x, y):
        """the type byte and the flag byte of map cell x, y"""
        k = 6 * (y >> 4) + (x >> 4)
        a = ((0x60 + 4 * k) << 8) + 16 * (y & 15) + (x & 15)
        return self.cpu.mem[a], self.cpu.mem[a + 0x200]

    def map_t(self, x, y):
        return self.map_raw(x, y)[0] & 0x1F

    def bolted(self, x, y):
        return bool(self.map_raw(x, y)[0] & 0x80)

    def room(self, x, y):
        ty, fl = self.map_raw(x, y)
        return (ty & 0x60) >> 1 | fl >> 4

    def press(self, room):
        return self.cpu.mem[0x4000 + room]

    def walk_to(self, x, y, frames=2000):
        """WALK HERE through the mouse menu: the cell locked, its WALK HERE"""
        self.mouse_cell(x, y)
        self.click(1)
        acts = [self.cpu.mem[self.tsyms['act0'] + i] for i in range(self.zp('n_act'))]
        self.click(2)
        if gen_scrap.A_WALK not in acts:
            self.fail('no WALK HERE at %d,%d' % (x, y))
            return
        self.mouse_cell(x, y)
        self.click(1)
        self.key(str(1 + acts.index(gen_scrap.A_WALK)))
        self.click(2)
        self.wait_for(lambda: (self.zp('p_x'), self.zp('p_y')) == (x, y) or not self.zp('wk_on'),
                      frames, 'walking to %d,%d' % (x, y))

    def wait_for(self, cond, frames, what):
        """cond checked once a frame"""
        for _ in range(frames):
            if cond():
                return True
            self.run(1)
        self.fail('%s: not within %d frames' % (what, frames))
        return False

    def go(self, *path):
        """walks with the arrow keys, a cell a press, to each x, y of path
        in turn: across first, then up or down (a closed door opens on the
        first press)"""
        for x, y in path:
            for _ in range(200):
                px, py = self.zp('p_x'), self.zp('p_y')
                if (px, py) == (x, y):
                    break
                if px != x:
                    self.hold(RIGHT if px < x else LEFT, 2)
                else:
                    self.hold(DOWN if py < y else UP, 2)
            else:
                self.fail('could not walk to %d,%d (at %d,%d)' % (x, y, px, py))
                return False
        return True

    def act(self, x, y, code):
        """the panel locked on cell x, y; the key of action code; AC: done"""
        self.mouse_cell(x, y)
        self.click(1)
        acts = [self.cpu.mem[self.tsyms['act0'] + i] for i in range(self.zp('n_act'))]
        if code not in acts:
            self.fail('%s is not in the menu of %d,%d: %s' % (gen_scrap.ACTIONS[code], x, y, acts))
            self.click(2)
            return False
        self.key(str(1 + acts.index(code)))
        self.run(2)
        self.click(2)
        return True

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
                    if t == T['FLOOR'] and self.cpu.mem[0x4040 + self.room(x, y)]:
                        t = T['VENT']           # a deck in a room without air
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
        """moves the pointer to screen x, y (from where the program has it;
        a long move is sent again for what did not arrive)"""
        def at():
            return (self.zp('m_xl') | self.zp('m_xh') << 8, self.zp('m_yl') | self.zp('m_yh') << 8)
        for _ in range(6):
            cx, cy = at()
            if (cx, cy) == (x, y):
                break
            self.port.mouse.move(x - cx, cy - y)    # PS/2 Y counts up
            for _ in range(12):
                self.run(1)
                if at() == (x, y):
                    break
        self.run(2)

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

    phase3(r, args)

    print('12. Esc')
    test_dos.esc_to_dos(r)
    print('PASS' if r.ok else 'FAILED')
    return 0 if r.ok else 1


def phase3(r, args):
    """carrying, cutting, the tug, the air (phase 3)"""
    cpu, mem, z = r.cpu, r.cpu.mem, r.zp
    print('7. the tug: carrying its O2 tank away and back')
    tank = (5, 34)
    r.go((7, 32), (7, 35), (6, 35))   # back west along the tube, into the quarters
    print('  at %d,%d; tug: %d O2 tank, %d scrubber, air %s, worth $%d0'
          % (z('p_x'), z('p_y'), z('n_o2'), z('n_scr'), 'on' if z('sup') else 'off',
             z('val_l') | z('val_h') << 8))
    if not z('sup'):
        r.fail('the tug has no air at the start')
    r.mouse_cell(*tank)
    p = r.panel()
    print('  |%s' % p[0])
    if 'LOOSE' not in p[0] or 'AIR 100%' not in p[0]:
        r.fail('the tug\'s tank is not shown loose, in air: %r' % p[0])
    if not r.act(*tank, gen_scrap.A_PICK):
        return
    if z('cl_t') != T['O2'] or r.map_t(*tank) != T['FLOOR']:
        r.fail('PICK UP did not put the tank in the left hand (%d, cell %d)' % (z('cl_t'), r.map_t(*tank)))
    r.run(62)
    print('  picked up: left hand %s, tug air %s' % (gen_scrap.TYPES[z('cl_t')][0], 'on' if z('sup') else 'off'))
    if z('sup'):
        r.fail('the tug still has air without its O2 tank')
    r.mouse_cell(z('p_x'), z('p_y'))
    p = r.panel()
    for line in p:
        print('  |%s' % line)
    if 'O2 TANK' not in p[3] or 'NO AIR' not in p[4]:
        r.fail('the player panel does not show the tank or the tug without air')
    d0 = mem[r.tsyms['walk_t']]
    if not r.act(*tank, gen_scrap.A_PUTL):
        return
    r.run(62)
    if r.map_t(*tank) != T['O2'] or z('cl_t') or not z('sup'):
        r.fail('PUT DOWN did not give the tug its tank back')
    else:
        print('  put back: the tug has air again')
    r.check_view('the tug')

    print('8. cutting a part free in the wreck')
    r.go((7, 35), (7, 32), (38, 32), (38, 29), (34, 29))   # the mess room (its door opens)
    r.walk_to(33, 29)             # the last step by WALK HERE
    crate = (32, 29)
    print('  at %d,%d' % (z('p_x'), z('p_y')))
    if not r.bolted(*crate):
        r.fail('the wreck\'s crate is not bolted')
    r.mouse_cell(*crate)
    print('  |%s' % r.panel()[0])
    if 'BOLTED' not in r.panel()[0]:
        r.fail('the panel does not say BOLTED')
    b0 = z('batt')
    if not r.act(*crate, gen_scrap.A_CUT):
        return
    print('  %r' % r.panel()[5].strip())
    r.run(gen_scrap_cut_frames() + 4)
    print('  %r, battery %d%% -> %d%%' % (r.panel()[5].strip(), b0, z('batt')))
    if r.bolted(*crate) or z('batt') != b0 - 5:
        r.fail('the cut did not free the crate (bolted %s, battery %d)' % (r.bolted(*crate), z('batt')))
    if not r.act(*crate, gen_scrap.A_PICK):
        return
    if z('cl_t') != T['CRATE']:
        r.fail('the crate is not in the left hand')
    r.port.kbd.press(r.codes[RIGHT])
    r.run(1)
    wd = mem[r.tsyms['walk_t']]
    r.port.kbd.release(r.codes[RIGHT])
    r.run(3)
    print('  carrying it: a step every %d frames (empty-handed 7)' % wd)
    if wd != 7 + 4:
        r.fail('carrying a crate does not slow the walk')
    r.check_view('cut and carried')

    print('9. a room without air: the vented section')
    r.go((38, 29), (38, 32), (61, 32), (61, 52))
    vent = r.room(70, 50)
    corr = r.room(61, 52)
    print('  at %d,%d: corridor air %d, vented room air %d (cold %d)'
          % (z('p_x'), z('p_y'), r.press(corr), r.press(vent), mem[0x4040 + vent]))
    if r.press(vent) != 0 or not mem[0x4040 + vent]:
        r.fail('the vented room has air')
    r.hold(RIGHT, 2)              # into the door (62, 52): it opens
    r.run(300)
    print('  door open 5 s: corridor air %d' % r.press(corr))
    if r.press(corr) >= 60:
        r.fail('the corridor kept its air with the vented room open')
    o0 = z('o2')
    r.run(180)
    print('  3 s more: suit O2 %d -> %d' % (o0, z('o2')))
    if z('o2') >= o0:
        r.fail('the suit does not use its O2 without air')
    r.check_view('frost')
    if args.png:
        r.mouse_cell(64, 52)
        r.run(2)
        ps.render(mem, args.png.replace('.png', '_air.png'))
        print('  wrote', args.png.replace('.png', '_air.png'))

    print('10. the warnings')
    for o2, want in ((44, 'CAUTION'), (20, 'WARNING'), (5, 'CRITICAL'), (1, 'BLACKING OUT')):
        mem[r.tsyms['o2']] = o2
        r.wait_for(lambda: want in r.panel()[5], 200, 'the %s warning' % want)
        print('  suit O2 %d: %r (tint %02X)' % (o2, r.panel()[5].strip(), mem[0x5BF0] & 0x70))
    if mem[0x5BF0] & 0x70 != 0x10:
        r.fail('the warning row is not red')
    r.wait_for(lambda: z('dead'), 900, 'suffocating')
    r.run(2)
    print('  %r' % r.panel()[5].strip())

    print('11. Enter starts again')
    r.key('\n')
    r.run_until(lambda: cpu.pc == r.tsyms['loop'] and cpu.map == 0xFF, 600, 'the frame loop again')
    r.run(4)
    if z('dead') or z('o2') != 90 or (z('p_x'), z('p_y')) != gen_scrap.START:
        r.fail('not a fresh start (dead %d, O2 %d)' % (z('dead'), z('o2')))
    else:
        print('  a fresh start at %d,%d' % (z('p_x'), z('p_y')))
    r.check_view('again')

    print('11. REFILL SUIT from the tug\'s tank')
    r.go((7, 35), (6, 35))
    mem[r.tsyms['o2']] = 5
    tank = (5, 34)
    dmg = r.map_raw(*tank)[1] & 15
    if r.act(*tank, gen_scrap.A_REFILL):
        want = min(90, 5 + 90 - 11 * dmg)
        print('  O2 5 -> %d (tank damage step %d), the tank: %s; %r'
              % (z('o2'), dmg, gen_scrap.TYPES[r.map_t(*tank)][0], r.panel()[5].strip()))
        if z('o2') != want or r.map_t(*tank) != T['O2E']:
            r.fail('REFILL: O2 %d, wanted %d' % (z('o2'), want))
        r.run(62)
        if z('sup'):
            r.fail('the tug still has air with an empty tank')
    r.check_view('refilled')


def gen_scrap_cut_frames():
    return 90


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
