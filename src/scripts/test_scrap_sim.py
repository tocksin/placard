#!/usr/bin/env python3
"""
test_scrap_sim.py - run SCRAP.PLC (scrap.masm, SCRAPWRIGHT) through
the ROM's loader in placard_sim

    python3 test_scrap_sim.py                  the checks below
    python3 test_scrap_sim.py --png scrap.png  also the screen as a PNG (and
                                               scrap_air.png)

Builds the 32K ROM and a card holding DOS.PLC, SCRAP.PLC (from scrap.asm)
and SCRAP.OVL (gen_scrap.py's map, then the code gen_plc.py puts at xC000),
BOOT.CFG = SCRAP.PLC, with a PS/2 mouse in
the upper socket, and boots it like the board (test_dos.Rig):
  1. the DOS loads SCRAP.PLC, which reads SCRAP.OVL into the even video
     pages (the map) and reaches its frame loop with the map at FF
  2. the view: all 20 x 12 cells match the map and the cell art
     (gen_scrap.py) byte for byte; the panel shows the player (YOU)
  3. walking: Right steps east a cell at a time (keys held), Up / Down /
     W / S too; walls stop the player
  4. the mouse: moving it frames the cell under it and the panel names it;
     a left click locks the panel, the action keys 1-8 run the menu (two
     columns; the pointer picks one in the second too)
     (CLOSE / OPEN / HOLD OPEN on a door next to the player, INSPECT
     writes the message line); a right click unlocks
  5. doors: walking into a closed door opens it (it is drawn open); it
     closes behind the player, unless held open
  6. the camera steps when the player walks off the view, and the view
     still matches the map
  7. the tug's O2 tank: UNINSTALL (the tug has no air), PICK UP, PUT DOWN
     (loose: still no air), INSTALL (it has).  The rooms scrap.masm works
     out (rooms_build) match gen_scrap.rooms() at the start and after each
     change: a deck plate taken up (a hole: the room leaks) and laid again;
     a wall uninstalled (two rooms join; a broken hull wall leaks),
     carried, put down, installed (two rooms again)
     Each job's time against gen_scrap.job_frames (the skills it needs,
     the suit) and the skills it raised against skill_gain; a loose part
     drawn in its crate frame
 7c. SKILLS on the message row; TAKE OFF SUIT (the room's air, O2 kept),
     REPAIR without the suit, no air without it (blacking out), PUT ON SUIT
  8. UNINSTALL an installed crate in the wreck with the cutter (time,
     battery), PICK UP, the slower walk; the last step by WALK HERE
  9. the vented section: its decks frosted; opening its door drains the
     corridor's air and the suit uses its O2
 10. each warning (red), then suffocating
 11. Enter starts again; REFILL SUIT from the tug's tank (it is empty
     after, still installed, and the tug has no air)
 12. Esc brings the DOS's browser back

Date: 2026-11-05
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
import gen_scrap              # noqa: E402
import io_devices             # noqa: E402
import test_dos               # noqa: E402
import test_tracker           # noqa: E402

FRAME = test_dos.FRAME
VIEW_W, VIEW_H = 20, 12
RIGHT, LEFT, UP, DOWN = '\x14', '\x13', '\x11', '\x12'
T = gen_scrap.TYPE
ARTS = [gen_scrap.art_bytes(t[1]) for t in gen_scrap.TYPES]
INST, CUT = 60, 90            # scrap.masm INST_FRAMES, CUT_FRAMES: at full speed


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

    def check_rooms(self, what):
        """the rooms scrap.masm worked out (rooms_build) against
        gen_scrap.rooms() on the map in RAM: every cell's room, the links,
        the leaking rooms, the tug's rooms"""
        mem = self.cpu.mem
        W, H = gen_scrap.MAP_W, gen_scrap.MAP_H
        t = [[self.map_t(x, y) for x in range(W)] for y in range(H)]
        d = [[self.map_raw(x, y)[1] & 15 for x in range(W)] for y in range(H)]
        rid, links, leaks, press, tug = gen_scrap.rooms(t, d)
        bad = [(x, y, rid[y][x], self.room(x, y)) for y in range(H) for x in range(W)
               if rid[y][x] != self.room(x, y)]
        n = self.zp('n_door')
        got = []
        for k in range(n):
            pg, ix = mem[0x3400 + k], mem[0x3440 + k]
            ck = (pg - 0x60) // 4
            x, y = 16 * (ck % 6) + (ix & 15), 16 * (ck // 6) + (ix >> 4)
            got.append((x, y, mem[0x3480 + k], mem[0x34C0 + k]))
        lk = []
        while mem[0x35C0 + len(lk)]:
            lk.append(mem[0x35C0 + len(lk)])
        tg = set(r for r in range(1, 64) if mem[0x3580 + r] & 1)
        ok = True
        if bad:
            self.fail('%s: %d cells in another room than rooms() says, first %s' % (what, len(bad), bad[:4]))
            ok = False
        if got != links:
            self.fail('%s: links %s, rooms() %s' % (what, got, links))
            ok = False
        if lk != leaks or tg != tug or self.zp('n_room') != len(press):
            self.fail('%s: leaks %s (%s), tug %s (%s), rooms %d (%d)'
                      % (what, lk, leaks, tg, tug, self.zp('n_room'), len(press)))
            ok = False
        if ok:
            print('  %s: %d rooms, %d links, leaking %s: as rooms() says' % (what, len(press) - 1, n, lk))
        return rid

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
        sk0, suit0, c0 = self.skills(), self.zp('suit_on'), self.cpu.clocks
        self.key(str(1 + acts.index(code)))
        self.run(2)
        self.mid = None
        d0 = self.map_raw(x, y)[1] & 15
        rep = 3 if self.zp('cut_t') and self.zp('cut_m') == 3 else 0
        half = (d0 + 1) // 2 if rep else 8      # a repair: its steps
        if self.zp('cut_t'):            # a job: its bar half way
            if self.wait_for(lambda: self.cpu.mem[0x36F9] >= half or not self.zp('cut_t'), 3000, 'half the job'):
                self.run(2)
                for _ in range(10):     # (the row is cleared, then written)
                    if self.panel()[5].strip():
                        break
                    self.run(1)
                self.mid = (self.cpu.mem[0x36F9], self.panel()[5], d0, self.map_raw(x, y)[1] & 15,
                            self.panel()[0], self.zp('cut_m') if self.zp('cut_t') else rep)
        self.settle()
        self.job = (sk0, suit0, (self.cpu.clocks - c0) // FRAME)
        self.click(2)
        return True

    def skills(self):
        mem = self.cpu.mem
        return ([mem[gen_scrap.SK_LV + k] for k in range(6)],
                [mem[gen_scrap.SK_PR + k] for k in range(6)])

    def check_job(self, what, base, t, extra=0):
        """the last act's job: its time against gen_scrap.job_frames (the
        skills and the suit before it; extra frames for the rooms worked
        out after it), the skills it raised against skill_gain"""
        (lv, pr), suit, frames = self.job
        mask = gen_scrap.NEEDS.get(gen_scrap.TYPES[t][0], 0)
        want = gen_scrap.job_frames(base, lv, mask, suit)
        glv, gpr = gen_scrap.skill_gain(lv, pr, mask, suit)
        print('  %s: %d frames (skills %s, %s): %d wanted; skills now %s'
              % (what, frames, '/'.join(gen_scrap.skill_names(mask)) or '-',
                 'in the suit' if suit else 'no suit', want, self.skills()[0]))
        if self.mid and self.mid[5] == 3 and self.mid[2] < 2:
            print('  one step: no half way')
        elif self.mid and self.mid[5] == 3:
            n, msg, d0, d, top, _ = self.mid    # a repair: the health rises, no job bar
            print('  half way: %d steps, damage %d -> %d, %r' % (n, d0, d, top[54:].strip()))
            if d != d0 - n or '[' in msg or gen_scrap.bar(d) not in top:
                self.fail('%s: half way %r' % (what, self.mid))
        elif not self.mid or gen_scrap.job_bar(self.mid[0]) not in self.mid[1]:
            self.fail('%s: no bar half way: %r' % (what, self.mid))
        else:
            print('  half way: %r' % self.mid[1].strip())
        if not want - 2 <= frames <= want + 10 + extra:   # and the key, the frame loop
            self.fail('%s took %d frames, not %d' % (what, frames, want))
        if self.skills() != (glv, gpr):
            self.fail('%s: skills %s, wanted %s' % (what, self.skills(), (glv, gpr)))

    def key_act(self, code):
        """the key of action code in the locked panel's menu; False if it
        is not there"""
        acts = [self.cpu.mem[self.tsyms['act0'] + i] for i in range(self.zp('n_act'))]
        if code not in acts:
            self.fail('%s is not in the menu: %s' % (gen_scrap.ACTIONS[code], acts))
            return False
        self.key(str(1 + acts.index(code)))
        self.run(2)
        return True

    def settle(self):
        """the work under way done (a cut, an install) and the frame loop
        back: working the rooms out takes about 18 frames"""
        loop = self.tsyms['loop']
        self.run_until(lambda: self.cpu.pc == loop and not self.zp('cut_t'), 3000, 'the work done')
        self.run(1)
        self.run_until(lambda: self.cpu.pc == loop, 60, 'the frame loop')

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
        """every view cell against the map in RAM and the art (a broken one
        cracked, a loose part crated, the mouse pointer over it); the framed
        cell is left out (its border is drawn over it)"""
        vx, vy, px, py = self.zp('v_x'), self.zp('v_y'), self.zp('p_x'), self.zp('p_y')
        frame = (self.zp('fr_x'), self.zp('fr_y')) if self.zp('fr_on') else None
        ptr = self.pointer()            # the mouse pointer over it
        bad = []
        for cy in range(VIEW_H):
            for cx in range(VIEW_W):
                x, y = vx + cx, vy + cy
                if (x, y) == frame:
                    continue
                if (x, y) == (px, py):
                    t = T['PLAYER']
                    if not self.zp('suit_on'):          # out of the suit
                        if self.cell_bytes(cx, cy) != pointer_over(gen_scrap.art_bytes('player_ns'), cx, cy, ptr):
                            bad.append((cx, cy, 'PLAYER without the suit'))
                        continue
                elif x < gen_scrap.MAP_W and y < gen_scrap.MAP_H:
                    t = self.map_t(x, y)
                    if t == T['FLOOR'] and self.cpu.mem[0x4040 + self.room(x, y)]:
                        t = T['VENT']           # a deck in a room without air
                else:
                    t = T['SPACE']
                art = ARTS[t]
                if ((x, y) != (px, py) and x < gen_scrap.MAP_W and y < gen_scrap.MAP_H
                        and self.map_raw(x, y)[1] & 15 >= gen_scrap.BROKEN_STEP):
                    art = gen_scrap.broken_art(art)     # broken: cracked
                if (gen_scrap.TYPES[t][3] & gen_scrap.F_ITEM and (x, y) != (px, py)
                        and not self.bolted(x, y)):
                    art = gen_scrap.crate_art(art)      # a loose part: crated
                art = pointer_over(art, cx, cy, ptr)
                if self.cell_bytes(cx, cy) != art:
                    got = self.cell_bytes(cx, cy)
                    bad.append((cx, cy, gen_scrap.TYPES[t][0], 'damage %d' % (self.map_raw(x, y)[1] & 15
                                if x < gen_scrap.MAP_W and y < gen_scrap.MAP_H else 0),
                                'bytes %s' % [i for i in range(64) if got[i] != art[i]][:6]))
        over = [(k, self.press(k)) for k in range(1, self.zp('n_room'))
                if self.press(k) > gen_scrap.AIR_FULL]
        if over:                        # a leak that went under 0 (air_crack)
            self.fail('%s: rooms over full air: %s' % (what, over))
        if bad:
            self.fail('%s: %d view cells differ from the map, first %s' % (what, len(bad), bad[:4]))
        else:
            print('  %s: all %d view cells match (view at %d,%d, player %d,%d)'
                  % (what, VIEW_W * VIEW_H, vx, vy, px, py))

    def pointer(self):
        """the mouse pointer's tip as drawn (art pixel x, y), None: off; a
        check that it is where the mouse is"""
        m, s = self.cpu.mem, self.tsyms
        if not m[s['PT_ON']]:
            return None
        at = (2 * m[s['PT_C']] + (1 if m[s['PT_B']] else 0), m[s['PT_P']])
        mx, my = self.zp('m_xl') | self.zp('m_xh') << 8, self.zp('m_yl') | self.zp('m_yh') << 8
        if at != (mx // 4, my // 2):
            self.fail('the pointer at %s, the mouse at %s' % (at, (mx // 4, my // 2)))
        return at

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
    inv = gen_plc.split_swap(prog, 0x4100, 0x4D00)      # SCRAP.INV
    if not inv or len(inv) > 0xC00:          # 6 sectors at most (inv_fetch)
        raise SystemExit('SCRAP.INV is %d bytes' % len(inv))
    own = set(re.findall(r'^([A-Za-z_]\w*):', open(os.path.join(HERE, 'scrap_inv.masm')).read(), re.M))
    own |= set(re.findall(r'^([A-Za-z_]\w*):', open(os.path.join(HERE, 'scrap_inv_data.masm')).read(), re.M))
    for lab in re.findall(r'^([A-Za-z_]\w*):', src, re.M):
        if lab not in own and not lab.startswith('scw_') and 0x4100 <= tsyms.get(lab, 0) < 0x4D00:
            raise SystemExit('%s is in SCRAP.INV (x%04X)' % (lab, tsyms[lab]))  # resident code spilled
    prog, code = gen_plc.split_overlay(prog, lib, 0xC000, 2, [(0x5600, 0x5A00, 1), (0x5C00, 0x5E00, 1), (0x5400, 0x5600, 1)])
    if any(0x4000 <= a < 0xC000 for a in prog):
        raise SystemExit('scrap.asm reaches past x3FFF')
    plc = gen_plc.make(prog, tsyms, lib)[0]
    ovl += code                 # the code pages from xC000, after the map's
    return rom, syms, dsyms, lib, dos_plc, plc, tsyms, ovl, inv


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    rom, syms, dsyms, lib, dos_plc, plc, tsyms, ovl, inv = build()
    files = {'DOS.PLC': dos_plc, 'SCRAP.PLC': plc, 'SCRAP.OVL': ovl, 'SCRAP.INV': inv,
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
    if (not p[0].strip().startswith('YOU') or 'AIR ON, NO COMMS' not in p[0] or 'MK1 WORK SUIT' not in p[1]
            or '1: SKILLS' not in p[1]
            or '2: TAKE OFF SUIT' not in p[2] or 'INVENTORY' in ''.join(p[1:5])):
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
    if 'SEALED - NO LEAKS' not in p[2]:
        r.fail('the door (13 %% damage) is not shown sealed: %r' % p[2])
    if 'HEALTH [#########-] 88%' not in p[0]:
        r.fail('no health bar for the door: %r' % p[0])
    if 'CLOSE' not in ''.join(p[1:5]):
        r.fail('no CLOSE in the menu')
    if 'HELD OPEN' not in p[0] or 'HOLD OPEN' in ''.join(p[1:5]):
        r.fail('the tug\'s door is not shown held open (and without HOLD OPEN)')
    r.click(1)
    if not r.zp('lock'):
        r.fail('a left click did not lock the panel')
    r.mouse_cell(door[0] + 3, door[1] + 1)      # away: the panel stays on the door
    if 'DOOR' not in r.panel()[0]:
        r.fail('the locked panel followed the pointer: %r' % r.panel()[0])
    if 'REPAIR' not in ''.join(r.panel()[1:5]):
        r.fail('no REPAIR for the damaged door')
    r.key_act(gen_scrap.A_INSPECT)    # held open: UNINSTALL, REPAIR, CLOSE, INSPECT
    msg = r.panel()[5]
    print('  INSPECT: %r' % msg.strip())
    if 'OPEN PRESSURE DOOR' not in msg:
        r.fail('INSPECT did not write the message line')
    r.key_act(gen_scrap.A_CLOSE)
    if r.map_t(*door) != T['DOOR']:
        r.fail('key 1 (CLOSE) did not close the door')
    else:
        print('  CLOSE -> %r' % r.panel()[0].strip())
    r.key_act(gen_scrap.A_OPEN)
    if r.map_t(*door) != T['DOORO']:
        r.fail('key 1 (OPEN) did not open the door')
    if r.bolted(*door):
        r.fail('OPEN left the door held open')
    r.key_act(gen_scrap.A_HOLD)
    print('  HOLD OPEN -> %r' % r.panel()[0].strip())
    if not r.bolted(*door) or 'HELD OPEN' not in r.panel()[0]:
        r.fail('HOLD OPEN did not hold the door')
    r.key_act(gen_scrap.A_CLOSE)                # for the bump below
    if r.bolted(*door) or r.map_t(*door) != T['DOOR']:
        r.fail('CLOSE did not close the held door')
    r.click(2)
    if r.zp('lock'):
        r.fail('a right click did not unlock')
    r.mouse_cell(r.zp('p_x'), r.zp('p_y'))
    if not r.panel()[0].strip().startswith('YOU'):
        r.fail('hovering the player does not show YOU: %r' % r.panel()[0])
    r.check_view('after the mouse')

    print('5. doors')
    r.hold(UP, 2)               # bump: the door opens, the player stays
    if r.map_t(*door) != T['DOORO'] or r.zp('p_y') != y0:
        r.fail('the bump did not open the door (type %d, y %d)' % (r.map_t(*door), r.zp('p_y')))
    else:
        print('  walked into the closed door: it opened')
    r.check_view('door open')
    r.hold(UP, 2)               # through it: it closes behind
    r.hold(UP, 2)
    if r.zp('p_y') != y0 - 2 or r.map_t(*door) != T['DOOR']:
        r.fail('the door did not close behind (y %d, type %d)' % (r.zp('p_y'), r.map_t(*door)))
    else:
        print('  walked through: it closed behind')
    r.check_view('door closed behind')
    for _ in range(3):          # back: it opens, closes behind again
        r.run(10)               # the last step's keys up
        r.hold(DOWN, 2)
    if r.zp('p_y') != y0 or r.map_t(*door) != T['DOOR']:
        r.fail('back through: the door did not close (y %d, type %d)' % (r.zp('p_y'), r.map_t(*door)))
    if r.act(*door, gen_scrap.A_HOLD):
        for k in (UP, UP, DOWN, DOWN):
            r.run(10)
            r.hold(k, 2)
        if r.zp('p_y') != y0 or r.map_t(*door) != T['DOORO'] or not r.bolted(*door):
            r.fail('the held door did not stay open (y %d, type %d)' % (r.zp('p_y'), r.map_t(*door)))
        else:
            print('  HOLD OPEN, through and back: it stays open')



    print('6. the camera')
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
    r.check_rooms('the rooms at the start')
    print('7. the tug: uninstalling its O2 tank, carrying it away, back, installing it')
    tank = (15, 34)
    r.go((17, 32), (17, 35), (16, 35))   # down into the quarters
    print('  at %d,%d; tug: %d O2 tank, %d scrubber, air %s, worth $%d0'
          % (z('p_x'), z('p_y'), z('n_o2'), z('n_scr'), 'on' if z('sup') else 'off',
             z('val_l') | z('val_h') << 8))
    if not z('sup'):
        r.fail('the tug has no air at the start')
    r.mouse_cell(*tank)
    p = r.panel()
    print('  |%s' % p[0])
    if 'INSTALLED' not in p[0] or 'AIR 100%' not in p[0]:
        r.fail('the tug\'s tank is not shown installed, in air: %r' % p[0])
    if not r.act(*tank, gen_scrap.A_UNINST):
        return
    r.check_job('UNINSTALL', INST, T['O2'])
    print('  %r; tug air %s' % (r.panel()[5].strip(), 'on' if z('sup') else 'off'))
    if r.bolted(*tank) or z('sup'):
        r.fail('UNINSTALL: the tank is still installed (bolted %s, air %d)' % (r.bolted(*tank), z('sup')))
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
    if 'O2 TANK' not in p[3] or 'NO AIR' not in p[0]:
        r.fail('the player panel does not show the tank or the tug without air')
    d0 = mem[r.tsyms['walk_t']]
    if not r.act(*tank, gen_scrap.A_PUTL):
        return
    r.run(62)
    if r.map_t(*tank) != T['O2'] or z('cl_t') or r.bolted(*tank):
        r.fail('PUT DOWN did not put the tank down loose')
    if z('sup'):
        r.fail('a tank put down, not installed, gives the tug air')
    r.check_view('a loose tank (crated)')
    r.mouse_cell(*tank)
    p = r.panel()
    print('  put down: %r' % p[0].strip())
    if 'LOOSE' not in p[0] or 'INSTALL' not in ''.join(p[1:5]):
        r.fail('the loose tank on the tug has no INSTALL')
    r.click(1)                                  # the second column, by the mouse
    acts = [mem[r.tsyms['act0'] + i] for i in range(z('n_act'))]
    print('  its menu: %s' % ', '.join(gen_scrap.ACTIONS[c] for c in acts))
    k = acts.index(gen_scrap.A_INSPECT) if gen_scrap.A_INSPECT in acts else -1
    if k < 4:
        r.fail('INSPECT is not in the second column: %s' % acts)
    else:
        r.mouse_to(8 * (44 + 18 * (k >> 2)) + 40, 16 * (25 + (k & 3)) + 8)
        r.run(2)
        print('  |%s' % r.panel()[1 + (k & 3)])
        if z('m_sel') != k or 'inspect' not in r.panel()[1 + (k & 3)]:
            r.fail('the pointer on column 2 does not pick INSPECT (m_sel %d)' % z('m_sel'))
        r.click(1)
        r.run(2)
        print('  clicked: %r' % r.panel()[5].strip())
        if 'OXYGEN TANK' not in r.panel()[5]:
            r.fail('a click on INSPECT in column 2 did not inspect')
    r.click(2)
    if not r.act(*tank, gen_scrap.A_INSTALL):
        return
    r.check_job('INSTALL', INST, T['O2'])
    print('  %r' % r.panel()[5].strip())
    if not r.bolted(*tank) or not z('sup'):
        r.fail('INSTALL did not give the tug its tank back')
    else:
        print('  installed: the tug has air again')
    r.check_view('the tug')

    rebuild(r)
    skills_suit(r)

    print('8. uninstalling a part in the wreck (the cutter)')
    r.go((17, 35), (17, 32), (38, 32), (38, 29), (34, 29))   # the mess room (its door opens)
    r.walk_to(33, 29)             # the last step by WALK HERE
    crate = (32, 29)
    print('  at %d,%d' % (z('p_x'), z('p_y')))
    if not r.bolted(*crate):
        r.fail('the wreck\'s crate is not bolted')
    r.mouse_cell(*crate)
    print('  |%s' % r.panel()[0])
    if 'INSTALLED' not in r.panel()[0]:
        r.fail('the panel does not say INSTALLED')
    b0 = z('batt')
    if not r.act(*crate, gen_scrap.A_UNINST):
        return
    r.check_job('UNINSTALL with the cutter', CUT, T['CRATE'], 20)
    print('  %r, battery %d%% -> %d%%' % (r.panel()[5].strip(), b0, z('batt')))
    if r.bolted(*crate) or z('batt') != b0 - 5:
        r.fail('the cut did not free the crate (bolted %s, battery %d)' % (r.bolted(*crate), z('batt')))
    if not r.act(*crate, gen_scrap.A_PICK):
        return
    if z('cl_t') != T['CRATE']:
        r.fail('the crate is not in the left hand')
    r.port.kbd.press(r.codes[RIGHT])
    r.wait_for(lambda: mem[r.tsyms['walk_t']], 10, 'the step')
    wd = mem[r.tsyms['walk_t']]
    r.port.kbd.release(r.codes[RIGHT])
    r.run(3)
    print('  carrying it: a step every %d frames (empty-handed 7)' % wd)
    if not 7 + 3 <= wd <= 7 + 4:        # read in the step's frame or the next
        r.fail('carrying a crate does not slow the walk')
    r.check_view('cut and carried')
    inventory(r, args)

    print('9. a room without air: the vented section')
    r.go((38, 29), (38, 32), (61, 32), (61, 52))
    vent = r.room(70, 50)
    corr = r.room(61, 52)
    print('  at %d,%d: corridor air %d, vented room air %d (cold %d)'
          % (z('p_x'), z('p_y'), r.press(corr), r.press(vent), mem[0x4040 + vent]))
    if r.press(vent) != 0 or not mem[0x4040 + vent]:
        r.fail('the vented room has air')
    r.run(10)                     # the last steps' keys up
    r.hold(RIGHT, 2)              # into the door (62, 52): it opens
    print('  the door: %s, the player at %d,%d' % (gen_scrap.TYPES[r.map_t(62, 52)][0], z('p_x'), z('p_y')))
    r.run(300)
    print('  door open 5 s: corridor air %d' % r.press(corr))
    if r.press(corr) >= 60:
        r.fail('the corridor kept its air with the vented room open')
    o0 = z('o2')
    r.run(60 * (gen_scrap.O2_SECS + 1))
    print('  %d s more: suit O2 %d -> %d' % (gen_scrap.O2_SECS + 1, o0, z('o2')))
    if not 1 <= o0 - z('o2') <= 2:              # a litre every O2_SECS: 1 or 2
        r.fail('the suit should use 1 or 2 L of O2 in %d s without air' % (gen_scrap.O2_SECS + 1))
    r.check_view('frost')
    if args.png:
        r.mouse_cell(64, 52)
        r.run(2)
        ps.render(mem, args.png.replace('.png', '_air.png'))
        print('  wrote', args.png.replace('.png', '_air.png'))

    print('10. the warnings')
    for o2, want in ((44, 'CAUTION'), (20, 'WARNING'), (5, 'CRITICAL'), (1, 'BLACKING OUT')):
        mem[r.tsyms['o2']] = o2
        r.wait_for(lambda: want in r.panel()[5], 60 * (gen_scrap.O2_SECS + 1),
                   'the %s warning' % want)             # (O2 1: the next litre)
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
    r.go((17, 35), (16, 35))
    mem[r.tsyms['o2']] = 5
    tank = (15, 34)
    dmg = r.map_raw(*tank)[1] & 15
    if r.act(*tank, gen_scrap.A_REFILL):
        want = min(90, 5 + 90 - 11 * dmg)
        print('  O2 5 -> %d (tank damage step %d), the tank: %s; %r'
              % (z('o2'), dmg, gen_scrap.TYPES[r.map_t(*tank)][0], r.panel()[5].strip()))
        if z('o2') != want or r.map_t(*tank) != T['O2E'] or not r.bolted(*tank):
            r.fail('REFILL: O2 %d, wanted %d (still installed %s)' % (z('o2'), want, r.bolted(*tank)))
        r.run(62)
        if z('sup'):
            r.fail('the tug still has air with an empty tank')
    r.check_view('refilled')


def rebuild(r):
    """taking a deck plate up and laying it again; a wall out, carried,
    put back in; a broken hull wall leaking"""
    z, mem = r.zp, r.cpu.mem
    print('7b. changing the tug: a deck plate, a wall')
    deck = (17, 36)
    if not r.act(*deck, gen_scrap.A_UNINST):
        return
    r.settle()
    r.check_job('UNINSTALL the deck', INST, T['FLOOR'], 35)
    q = r.room(16, 35)
    print('  %r: left hand %s, %d,%d %s' % (r.panel()[5].strip(), gen_scrap.TYPES[z('cl_t')][0],
                                          deck[0], deck[1], gen_scrap.TYPES[r.map_t(*deck)][0]))
    if r.map_t(*deck) != T['SPACE'] or z('cl_t') != T['PLATE']:
        r.fail('UNINSTALL did not take the deck plate up')
    r.check_rooms('a hole in the deck')
    p0 = r.press(q)
    r.run(120)
    print('  the quarters\' air: %d -> %d in 2 s' % (p0, r.press(q)))
    if r.press(q) >= p0:
        r.fail('the hole in the deck does not leak')
    r.go((17, 35), deck)                    # out onto open space: a spacewalk
    print('  standing on the hole at %d,%d (%s)' % (z('p_x'), z('p_y'),
                                                  gen_scrap.TYPES[r.map_t(*deck)][0]))
    if (z('p_x'), z('p_y')) != deck:
        r.fail('could not walk onto open space')
    r.check_view('on open space')
    r.go((17, 35))
    if not r.act(*deck, gen_scrap.A_LAY):
        return
    r.run(4)
    if r.map_t(*deck) != T['FLOOR'] or z('cl_t'):
        r.fail('LAY DECK PLATE did not lay it')
    r.check_rooms('the deck laid again')

    r.go((19, 35))
    wall, hull = (20, 35), (14, 35)
    ty, fl = r.map_raw(*hull)
    a = ((0x60 + 4 * (6 * (hull[1] >> 4) + (hull[0] >> 4))) << 8) + 16 * (hull[1] & 15) + (hull[0] & 15)
    mem[a + 0x200] = (fl & 0xF0) | 9              # the hull wall: 56 % damage
    r.mouse_cell(*hull)
    print('  the hull wall at 56 %%: %r' % r.panel()[2].strip())
    if 'LEAKS AIR - NEEDS REPAIR' not in r.panel()[2]:
        r.fail('the broken hull wall is not shown leaking')
    if not r.act(*wall, gen_scrap.A_UNINST):
        return
    r.settle()
    r.check_job('UNINSTALL the wall', INST, T['WALL'], 35)
    print('  %r: %d,%d %s; quarters room %d, hold room %d'
          % (r.panel()[5].strip(), wall[0], wall[1], gen_scrap.TYPES[r.map_t(*wall)][0],
             r.room(19, 35), r.room(21, 35)))
    if r.map_t(*wall) != T['PANEL'] or r.room(19, 35) != r.room(21, 35):
        r.fail('UNINSTALL of the wall did not join the quarters and the hold')
    r.check_rooms('the wall out, a broken hull wall')
    q = r.room(19, 35)
    saved = bytes(mem[0x4000:0x4040])
    lo = min(r.press(q) for _ in range(180) if r.run(1) is None)
    print('  the broken hull wall: the room\'s air down to %d in 3 s' % lo)
    if lo >= 100:
        r.fail('the broken hull wall does not leak')
    mem[a + 0x200] = fl                           # mended, the air back
    mem[0x4000:0x4040] = saved
    if not (r.act(*wall, gen_scrap.A_PICK) and r.act(*wall, gen_scrap.A_PUTL)):
        return
    if r.map_t(*wall) != T['PANEL'] or r.bolted(*wall):
        r.fail('the wall panel was not put down loose')
    if not r.act(*wall, gen_scrap.A_INSTALL):
        return
    r.settle()
    r.check_job('INSTALL the panel', INST, T['PANEL'], 35)
    if r.map_t(*wall) != T['WALL'] or r.room(19, 35) == r.room(21, 35):
        r.fail('INSTALL of the wall panel did not part the rooms')
    else:
        print('  the panel installed: a wall again, two rooms')
    r.check_rooms('the wall in again')
    r.check_view('the tug changed')


def set_cell(r, x, y, ty=None, fl=None):
    """map cell x, y's type byte and flag byte (None: kept)"""
    k = 6 * (y >> 4) + (x >> 4)
    a = ((0x60 + 4 * k) << 8) + 16 * (y & 15) + (x & 15)
    if ty is not None:
        r.cpu.mem[a] = ty
    if fl is not None:
        r.cpu.mem[a + 0x200] = fl


def partial_repair(r):
    """REPAIR on a deck at 75 % damage, stopped part way by a step: the
    steps done stay done"""
    z, mem = r.zp, r.cpu.mem
    deck = (16, 36)
    ty, fl = r.map_raw(*deck)
    set_cell(r, *deck, fl=(fl & 0xF0) | 12)
    r.mouse_cell(*deck)
    r.run(2)
    print('  a deck at 12: %r' % r.panel()[0][54:].strip())
    if 'HEALTH %s %s' % (gen_scrap.bar(12), gen_scrap.health_pct(12)) not in r.panel()[0]:
        r.fail('the deck\'s health bar: %r' % r.panel()[0])
    r.click(1)
    acts = [mem[r.tsyms['act0'] + i] for i in range(z('n_act'))]
    if gen_scrap.A_REPAIR not in acts:
        r.fail('no REPAIR for the deck: %s' % acts)
        r.click(2)
        return
    r.key(str(1 + acts.index(gen_scrap.A_REPAIR)))
    r.wait_for(lambda: mem[0x36F9] >= 4, 3000, 'four repair steps')
    if '[' in r.panel()[5]:
        r.fail('a job bar while repairing: %r' % r.panel()[5])
    r.hold(LEFT, 2)                       # a step away: the job stops
    n, d = mem[0x36F9], r.map_raw(*deck)[1] & 15
    r.run(60)
    print('  stopped after %d steps: damage %d, then %d; %r' % (n, d, r.map_raw(*deck)[1] & 15,
                                                           r.panel()[5].strip()))
    if z('cut_t') or d != 12 - n or r.map_raw(*deck)[1] & 15 != d:
        r.fail('a stopped repair did not keep its steps')
    r.click(2)
    r.check_view('the partial repair')


def jammed_door(r):
    """a closed door under 50 % health is jammed: no way through, no OPEN"""
    z, mem = r.zp, r.cpu.mem
    door = (17, 33)
    ty, fl = r.map_raw(*door)
    r.go((17, 34))
    set_cell(r, *door, ty=(ty & 0x60) | T['DOOR'], fl=(fl & 0xF0) | 10)
    r.hold(UP, 2)
    r.run(2)
    print('  into the jammed door: at %d,%d, %r' % (z('p_x'), z('p_y'), r.panel()[5].strip()))
    if (z('p_x'), z('p_y')) != (17, 34) or 'JAMMED' not in r.panel()[5] or r.map_t(*door) != T['DOOR']:
        r.fail('the jammed door let the player through')
    if r.act(*door, gen_scrap.A_OPEN):
        if r.map_t(*door) != T['DOOR'] or 'JAMMED' not in r.panel()[5]:
            r.fail('OPEN opened the jammed door')
    set_cell(r, *door, ty=ty, fl=fl)
    r.mouse_cell(*door)
    r.run(2)
    r.check_view('the door mended')


def cnd(r):
    """the CND list: the cells with a part on a conduit"""
    a, n = r.tsyms['CND'], r.tsyms['CND_N']
    m = r.cpu.mem
    return [(m[a + 2 * i], m[a + 2 * i + 1]) for i in range(n) if m[a + 2 * i] != 0xFF]


def deck_rules(r):
    """a part goes on a deck or a conduit, never a broken one; the conduit
    under a part comes back when it is picked up; a second click on a
    part shows what is under it; a conduit uninstalls to a section that
    installs again"""
    z, mem = r.zp, r.cpu.mem
    print('7d. decks, conduits')
    r.go((17, 32), (24, 32), (24, 30), (23, 29))
    pipe, deck = (23, 28), (24, 29)
    p0, d0 = r.map_raw(*pipe), r.map_raw(*deck)
    if r.map_t(*pipe) != T['PIPE'] or (z('p_x'), z('p_y')) != (23, 29):
        r.fail('not by the tug\'s conduit: at %d,%d' % (z('p_x'), z('p_y')))
        return
    slots = [z('cl_t'), z('cr_t'), z('cb_t')]
    if 0 not in slots:
        r.fail('no free carry slot: %s' % slots)
        return
    k = slots.index(0)
    mem[r.tsyms['cl_t'] + k] = T['CRATE']
    mem[r.tsyms['cl_d'] + k] = 0
    if r.act(*pipe, gen_scrap.A_PUTL + k):
        print('  a crate put down on the conduit: %s, CND %s' % (gen_scrap.TYPES[r.map_t(*pipe)][0], cnd(r)))
        if r.map_t(*pipe) != T['CRATE'] or cnd(r) != [pipe]:
            r.fail('PUT DOWN on a conduit: %d, %s' % (r.map_t(*pipe), cnd(r)))
    r.mouse_cell(*pipe)
    r.click(1)
    first = (z('s_who'), r.panel()[0][:40].strip())
    r.click(1)
    under = (z('s_who'), r.panel()[0], [mem[r.tsyms['act0'] + i] for i in range(z('n_act'))])
    r.click(1)
    back = (z('s_who'), r.panel()[0][:40].strip())
    r.click(2)
    print('  clicks on it: %r, then %r %r, then %r' % (first[1], under[1][:40].strip(),
                                                     under[1][54:].strip(), back[1]))
    if (first[0] != 1 or 'CARGO CRATE' not in first[1] or under[0] != 4
            or 'POWER CONDUIT' not in under[1] or 'HEALTH %s %s' % (gen_scrap.bar(0), gen_scrap.health_pct(0)) not in under[1]
            or under[2] != [gen_scrap.A_INSPECT] or back[0] != 1 or 'CARGO CRATE' not in back[1]):
        r.fail('a second click does not show the conduit under the crate: %r %r %r' % (first, under, back))
    if r.act(*pipe, gen_scrap.A_PICK):
        print('  picked up: %s, CND %s' % (gen_scrap.TYPES[r.map_t(*pipe)][0], cnd(r)))
        if r.map_t(*pipe) != T['PIPE'] or cnd(r) or mem[r.tsyms['cl_t'] + k] != T['CRATE']:
            r.fail('PICK UP off a conduit did not leave the conduit')
    set_cell(r, *deck, fl=(d0[1] & 0xF0) | 10)
    if r.act(*deck, gen_scrap.A_PUTL + k):
        print('  on a broken deck: %r' % r.panel()[5].strip())
        if r.map_t(*deck) != T['FLOOR'] or 'BROKEN' not in r.panel()[5] or mem[r.tsyms['cl_t'] + k] != T['CRATE']:
            r.fail('a part was put down on a broken deck')
    set_cell(r, *deck, fl=d0[1])
    mem[r.tsyms['cl_t'] + k] = 0
    if r.act(*pipe, gen_scrap.A_UNINST):
        print('  the conduit uninstalled: %s, bolted %s' % (gen_scrap.TYPES[r.map_t(*pipe)][0], r.bolted(*pipe)))
        if r.map_t(*pipe) != T['COND'] or r.bolted(*pipe):
            r.fail('UNINSTALL of a conduit: not a loose conduit section')
    if r.act(*pipe, gen_scrap.A_PICK):
        if r.map_t(*pipe) != T['FLOOR'] or mem[r.tsyms['cl_t'] + k] != T['COND']:
            r.fail('PICK UP of the conduit section')
    if r.act(*deck, gen_scrap.A_PUTL + k) and r.act(*deck, gen_scrap.A_INSTALL):
        print('  the section put down and installed: %s' % gen_scrap.TYPES[r.map_t(*deck)][0])
        if r.map_t(*deck) != T['PIPE'] or cnd(r):
            r.fail('INSTALL of a conduit section: not a conduit')
    if r.act(*deck, gen_scrap.A_UNINST) and r.act(*deck, gen_scrap.A_PICK):   # and back
        if r.act(*pipe, gen_scrap.A_PUTL + k) and r.act(*pipe, gen_scrap.A_INSTALL):
            pass
    if r.map_t(*pipe) != T['PIPE'] or r.map_t(*deck) != T['FLOOR'] or mem[r.tsyms['cl_t'] + k]:
        r.fail('the conduit not back: %d %d' % (r.map_t(*pipe), r.map_t(*deck)))
    set_cell(r, *pipe, fl=p0[1])            # (the damage: under 8, drawn the same)
    set_cell(r, *deck, fl=d0[1])
    r.mouse_cell(*deck)
    r.run(2)
    r.check_view('the conduits back')
    r.go((24, 30), (24, 32), (17, 32), (17, 34))


def comms(r):
    """the tug's antenna, broken at the start: NO COMMS; working: COMMS"""
    z = r.zp
    ant = gen_scrap.TUG_ANT
    a0 = r.map_raw(*ant)
    if r.map_t(*ant) != T['ANT'] or not r.bolted(*ant):
        r.fail('no antenna on the tug at %d,%d' % ant)
        return
    rows = []
    for d in (a0[1] & 15, 0):
        set_cell(r, *ant, fl=(a0[1] & 0xF0) | d)
        r.run(70)                           # tug_scan: once a second
        r.mouse_cell(z('p_x'), z('p_y'))
        r.run(2)
        rows.append(r.panel()[0][22:52].strip())
    print('  the antenna broken: %r; working: %r' % tuple(rows))
    if 'NO COMMS' not in rows[0] or not rows[1].endswith(', COMMS'):
        r.fail('COMMS: %r' % rows)
    set_cell(r, *ant, fl=a0[1])
    r.run(70)


def skills_suit(r):
    """SKILLS on the message row; the suit off (the room's air, quicker
    work: a REPAIR), no air without it (blacking out), the suit on again"""
    z, mem = r.zp, r.cpu.mem
    print('7c. skills, the suit, REPAIR')
    if not r.act(z('p_x'), z('p_y'), gen_scrap.A_SKILLS):
        return
    msg, pos = gen_scrap.skill_msg()
    for k, lv in enumerate(r.skills()[0]):
        msg = msg[:pos[k]] + '%2d' % lv + msg[pos[k] + 2:]
    print('  %r' % r.panel()[5].strip())
    if r.panel()[5].strip() != msg:
        r.fail('SKILLS: %r, wanted %r' % (r.panel()[5].strip(), msg))
    o0 = z('o2')
    if not r.act(z('p_x'), z('p_y'), gen_scrap.A_SUITOFF):
        return
    r.mouse_cell(z('p_x'), z('p_y'))
    p = r.panel()
    print('  |%s' % p[1])
    print('  %r' % p[5].strip())
    if z('suit_on') or T['SUIT'] not in (z('cl_t'), z('cr_t'), z('cb_t')) or 'NONE' not in p[1]:
        r.fail('TAKE OFF SUIT: suit_on %d, carried %d %d %d' % (z('suit_on'), z('cl_t'), z('cr_t'), z('cb_t')))
    if 'PUT ON SUIT' not in ''.join(p[1:5]):
        r.fail('no PUT ON SUIT in the player\'s menu')
    r.check_view('out of the suit')
    r.run(130)
    if z('o2') != o0 or z('stage'):
        r.fail('without the suit, in air: O2 %d -> %d, stage %d' % (o0, z('o2'), z('stage')))
    r.go((16, 35))
    tank = (15, 34)
    dmg = r.map_raw(*tank)[1] & 15
    if not dmg:
        r.fail('the tank has no damage to repair')
    elif r.act(*tank, gen_scrap.A_REPAIR):
        r.check_job('REPAIR (no suit)', gen_scrap.REPAIR_FRAMES * dmg, T['O2'])
        print('  %r: damage %d -> %d' % (r.panel()[5].strip(), dmg, r.map_raw(*tank)[1] & 15))
        if r.map_raw(*tank)[1] & 15:
            r.fail('REPAIR left damage')
    partial_repair(r)
    jammed_door(r)
    deck_rules(r)
    comms(r)
    q = r.room(z('p_x'), z('p_y'))
    saved = bytes(mem[0x4000:0x4040])
    for _ in range(140):                           # the room's air gone
        mem[0x4000 + q] = 0
        r.run(1)
        if z('stage') == 4 and 'BLACKING OUT' in r.panel()[5]:
            break
    print('  no air, no suit: stage %d, %r, O2 %d' % (z('stage'), r.panel()[5].strip(), z('o2')))
    if z('stage') != 4 or 'BLACKING OUT' not in r.panel()[5]:
        r.fail('no air without the suit is not blacking out')
    mem[0x4000:0x4040] = saved                     # and back
    r.wait_for(lambda: z('stage') == 0, 130, 'the air back')
    if not r.act(z('p_x'), z('p_y'), gen_scrap.A_SUITON):
        return
    if not z('suit_on') or T['SUIT'] in (z('cl_t'), z('cr_t'), z('cb_t')) or z('o2') != o0:
        r.fail('PUT ON SUIT: suit_on %d, O2 %d' % (z('suit_on'), z('o2')))
    else:
        print('  %r: the suit on again, O2 %d' % (r.panel()[5].strip(), z('o2')))
    r.check_view('the suit on again')



def pointer_over(art, cx, cy, ptr):
    """cell art at screen cell cx, cy with the part of the mouse pointer
    (its tip at art pixel ptr, None: not drawn) that falls on it"""
    if ptr is None:
        return art
    out = bytearray(art)
    for r, row in enumerate(gen_scrap.POINTER):
        for i, ch in enumerate(row):
            x, y = ptr[0] + i, ptr[1] + r
            if ch == '.' or x >= 160 or y >= 192 or (x // 8, y // 16) != (cx, cy):
                continue
            b = 16 * ((x & 7) >> 1) + (y & 15)
            c = int(ch, 16)
            out[b] = (out[b] & 0xF0) | c if x & 1 == 0 else (out[b] & 0x0F) | c << 4
    return bytes(out)


def check_inv(r, what):
    """the inventory screen against gen_scrap.inventory_screen (the slots,
    the gear, the frame on the slot under the mouse, a broken part cracked,
    the mouse pointer)"""
    z, mem = r.zp, r.cpu.mem
    carry = [mem[r.tsyms['cl_t'] + i] for i in range(3)]
    dmg = [mem[r.tsyms['cl_d'] + i] for i in range(3)]
    want = gen_scrap.inventory_screen(carry, z('suit_on'), z('batt'), z('o2'), z('inv_k'), dmg,
                                      r.pointer())
    bad = []
    for p in range(192):
        for bc in range(80):
            if mem[((0x61 + 2 * bc) << 8) + line_off(p)] != want[p][bc]:
                bad.append((bc, p))
    if bad:
        r.fail('%s: %d inventory bytes differ, first (column, line) %s' % (what, len(bad), bad[:4]))
    else:
        print('  %s: the inventory screen is as inventory_screen() draws it' % what)
    return not bad


def inv_mouse(r, k):
    """the pointer onto inventory slot k (0-2 carrying, 3-6 the gear)"""
    bc, p = gen_scrap.INV_SLOTS[k]
    r.mouse_to(4 * (2 * bc + 4), 2 * (p + 8))


def inventory(r, args):
    """the inventory screen (I); a wreck wall uninstalled, picked up and
    installed again from the inventory onto the deck it left"""
    z, mem = r.zp, r.cpu.mem
    print('8b. the inventory; installing in the wreck from it')
    px, py = z('p_x'), z('p_y')
    wall = None
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        if r.map_t(px + dx, py + dy) == T['WALL']:
            wall = (px + dx, py + dy)
            break
    if not wall:
        r.fail('no wall next to %d,%d' % (px, py))
        return
    if not r.act(*wall, gen_scrap.A_UNINST):
        return
    if r.map_t(*wall) != T['PANEL'] or not r.act(*wall, gen_scrap.A_PICK):
        r.fail('the wreck wall at %d,%d did not come out as a panel' % wall)
        return
    if z('cb_t') != T['PANEL']:
        r.fail('the panel is not on the back (%d %d %d)' % (z('cl_t'), z('cr_t'), z('cb_t')))
        return
    r.check_rooms('a wreck wall out')
    r.key('i')
    r.run(4)
    print('  I: %r' % r.panel()[5].strip())
    if not z('inv') or 'YOUR GEAR' not in r.panel()[5]:
        r.fail('I did not open the inventory')
    check_inv(r, 'opened')
    inv_mouse(r, 1)                                     # the right hand: the cutter
    p = r.panel()
    print('  |%s' % p[0])
    if 'PLASMA CUTTER' not in p[0] or 'IN YOUR RIGHT HAND' not in p[0]:
        r.fail('the right hand slot is not shown')
    inv_mouse(r, 2)                                     # the back: the panel
    p = r.panel()
    for line in p:
        print('  |%s' % line)
    if 'WALL PANEL' not in p[0] or 'ON YOUR BACK' not in p[0]:
        r.fail('the back slot is not shown')
    check_inv(r, 'the back framed')
    if args.png:
        ps.render(mem, args.png.replace('.png', '_inv.png'))
        print('  wrote', args.png.replace('.png', '_inv.png'))
    inv_mouse(r, 3)                                     # the suit: your panel
    if z('s_who') != 2 or 'MK1 WORK SUIT' not in r.panel()[1]:
        r.fail('the suit slot does not show you')
    inv_mouse(r, 2)
    r.click(1)
    if not r.key_act(gen_scrap.A_INSTALL):
        return
    r.run(4)
    print('  INSTALL: %r' % r.panel()[5].strip())
    if z('inv') or z('place') != r.tsyms['cb_t'] or 'CLICK WHERE IT GOES' not in r.panel()[5]:
        r.fail('INSTALL did not go back to the ship to pick the cell (inv %d, place %02X)'
               % (z('inv'), z('place')))
    r.check_view('picking the cell')
    far = (px + 3, py)
    r.mouse_cell(*far)
    r.click(1)
    print('  a cell 3 away: %r' % r.panel()[5].strip())
    if z('cut_t') or 'TOO FAR' not in r.panel()[5].upper():
        r.fail('placing 3 cells away was not refused')
    sk0 = r.skills()
    r.mouse_cell(*wall)
    r.click(1)
    r.run(2)
    if not z('cut_t'):
        r.fail('clicking the bare deck did not start the install')
        return
    r.settle()
    print('  %r: %d,%d %s, back %d, skills %s -> %s'
          % (r.panel()[5].strip(), wall[0], wall[1], gen_scrap.TYPES[r.map_t(*wall)][0],
             z('cb_t'), sk0[0], r.skills()[0]))
    if r.map_t(*wall) != T['WALL'] or z('cb_t') or z('place'):
        r.fail('the wall was not installed from the inventory')
    if r.skills() != gen_scrap.skill_gain(*sk0, gen_scrap.NEEDS['PANEL'], z('suit_on')):
        r.fail('installing from the inventory: skills %s' % (r.skills(),))
    r.click(2)
    r.check_rooms('the wreck wall in again')
    r.check_view('the wreck wall in again')
    r.key('\t')
    r.run(4)
    if not z('inv'):
        r.fail('Tab did not open the inventory')
    r.key('i')
    r.run(4)
    if z('inv'):
        r.fail('I did not close the inventory')
    r.check_view('back on the ship')


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
