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

Date: 2026-11-09
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


FL = 0x4000                 # scrap_fl.masm's flight variables (FL_PG)


def fl_get(mem, off, n, signed=True):
    v = int.from_bytes(bytes(mem[FL + off:FL + off + n]), 'little')
    return v - (1 << 8 * n) if signed and v >> (8 * n - 1) else v


def fl_put(mem, off, n, v):
    mem[FL + off:FL + off + n] = (v & ((1 << 8 * n) - 1)).to_bytes(n, 'little')


def nav_pixel(mem, x, y):
    """the nav map's pixel x, y (2 bpp, 256 wide from byte column 8, under
    the status row: line pair y + 8)"""
    b = mem[((0x71 + ((x >> 1) & 0x7E)) << 8) + line_off(y + 8)]
    return (b >> 2 * (x & 3)) & 3


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
                ch = self.inv.get(rows)
                ch = ch.lower() if ch else ch
            if ch is None:              # a box's line on it (the nav panel: bit 7, line 7)
                ch = self.glyphs.get(tuple(b & 0x7F for b in rows[:7]) + (0,), '?')
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
        return self.map_raw(x, y)[0] & 0x3F

    def bolted(self, x, y):
        return bool(self.map_raw(x, y)[0] & 0x80)

    def room(self, x, y):
        ty, fl = self.map_raw(x, y)
        return (ty & 0x40) >> 2 | fl >> 4

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
            pg, ix = mem[(gen_scrap.DOOR_PAGE << 8) + k], mem[(gen_scrap.DOOR_PAGE << 8) + 0x40 + k]
            ck = (pg - 0x60) // 4
            x, y = 16 * (ck % 6) + (ix & 15), 16 * (ck // 6) + (ix >> 4)
            got.append((x, y, mem[(gen_scrap.DOOR_PAGE << 8) + 0x80 + k], mem[(gen_scrap.DOOR_PAGE << 8) + 0xC0 + k]))
        lk = []
        while mem[(gen_scrap.ROOM_PAGE << 8) + 0xC0 + len(lk)]:
            lk.append(mem[(gen_scrap.ROOM_PAGE << 8) + 0xC0 + len(lk)])
        tg = set(r for r in range(1, gen_scrap.ROOMS_MAX) if mem[(gen_scrap.ROOM_PAGE << 8) + 0x80 + r] & 1)
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
            if self.wait_for(lambda: self.cpu.mem[self.tsyms['JB_N']] >= half or not self.zp('cut_t'), 3000, 'half the job'):
                self.run(2)
                last = None
                for _ in range(12):     # (the row is cleared, then written: wait till it holds still)
                    row = self.panel()[5]
                    if row.strip() and row == last:
                        break
                    last = row
                    self.run(1)
                self.mid = (self.cpu.mem[self.tsyms['JB_N']], self.panel()[5], d0, self.map_raw(x, y)[1] & 15,
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

    def check_view(self, what, pv=None):
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
                elif x >= gen_scrap.WRECK_LOCK[0] and not self.cpu.mem[FL + 0x21]:
                    t = T['SPACE']              # undocked: the KESTREL 9 is away
                elif x < gen_scrap.MAP_W and y < gen_scrap.MAP_H:
                    t = self.map_t(x, y)
                    if t == T['FLOOR'] and self.cpu.mem[0x4040 + self.room(x, y)]:
                        t = T['VENT']           # a deck in a room without air
                else:
                    t = T['SPACE']
                art = ARTS[t]
                away = x >= gen_scrap.WRECK_LOCK[0] and not self.cpu.mem[FL + 0x21]
                if ((x, y) != (px, py) and x < gen_scrap.MAP_W and y < gen_scrap.MAP_H and not away
                        and self.map_raw(x, y)[1] & 15 >= gen_scrap.BROKEN_STEP):
                    art = gen_scrap.broken_art(art)     # broken: cracked
                if (gen_scrap.TYPES[t][3] & gen_scrap.F_ITEM and (x, y) != (px, py)
                        and not self.bolted(x, y)):
                    art = gen_scrap.crate_art(art)      # a loose part: crated
                if pv and not away and x < gen_scrap.MAP_W and y < gen_scrap.MAP_H:
                    art = pw_overlay(self, art, x, y, pv)       # the power view's lines
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
    nav = gen_plc.split_swap(prog, 0x4100, 0x4D00, 2)   # SCRAP.NAV
    if not nav or len(nav) > 0xC00:
        raise SystemExit('SCRAP.NAV is %d bytes' % len(nav))
    nav2 = gen_plc.split_swap(prog, 0x3600, 0x4000, 2)  # SCRAP.NV2, over the actions and the cell art
    nav3 = gen_plc.split_swap(prog, 0x4E00, 0x5000, 2)  # SCRAP.NV3, in the file system's buffer
    art = gen_plc.split_swap(prog, 0x3600, 0x4000, 0)   # SCRAP.ART: the actions and the art back
    if gen_scrap.ART_PAGE > 0x37 or not nav2 or len(nav2) > 0xA00 or not nav3 or len(nav3) > 0x200:
        raise SystemExit('SCRAP.NV2 is %d bytes, NV3 %d, the art at x%02X00' % (len(nav2), len(nav3), gen_scrap.ART_PAGE))
    if not 0x4100 <= tsyms['nav_main'] < 0x4D00 and not 0x3600 <= tsyms['nav_main'] < 0x4000:
        raise SystemExit('nav_main is in SCRAP.NV3 (x%04X): it reads that in' % tsyms['nav_main'])
    dck = gen_plc.split_swap(prog, 0x4100, 0x4D00, 3)   # SCRAP.DCK, the docking screen
    dk2 = gen_plc.split_swap(prog, 0x3600, 0x4000, 3)   # SCRAP.DK2, over SCRAP.NV2's
    dk3 = gen_plc.split_swap(prog, 0x4E00, 0x5000, 3)   # SCRAP.DK3, in the file system's buffer
    dk4 = gen_plc.split_swap(prog, 0x5400, 0x5600, 3)   # SCRAP.DK4, in the part text's
    if not dck or len(dck) > 0xC00 or len(dk2) > 0xA00 or len(dk3) > 0x200 or len(dk4) > 0x200:
        raise SystemExit('SCRAP.DCK is %d bytes, DK2 %d, DK3 %d, DK4 %d' % (len(dck), len(dk2), len(dk3), len(dk4)))
    if any(0x5D00 <= a < 0x5D70 for a in prog):     # the DOS's menu block: Esc needs it
        raise SystemExit('scrap.asm puts bytes in x5D00-x5D6F (the menu block)')
    for lab in ('l_mul8', 'l_div16', 'l_rand8'):     # MAP07: the library over x6000 up
        if tsyms[lab] >= 0x6000:
            raise SystemExit('%s is at x%04X: it runs under map 07' % (lab, tsyms[lab]))
    pwr = gen_plc.split_swap(prog, 0x4700, 0x4D00, 4)   # SCRAP.PWR, the power view
    ini = gen_plc.split_swap(prog, 0x4100, 0x4500, 4)   # SCRAP.INI, the start
    if not pwr or len(pwr) > 0x600 or not ini or len(ini) > 0x400:
        raise SystemExit('SCRAP.PWR is %d bytes, SCRAP.INI %d' % (len(pwr), len(ini)))
    pw_src = open(os.path.join(HERE, 'scrap_pwr.masm')).read()
    k = pw_src.index('; SCRAP.INI: the start')
    for lab in re.findall(r'^([A-Za-z_]\w*):', pw_src[:k], re.M):     # each in its own file
        if not 0x4700 <= tsyms[lab] < 0x4D00:
            raise SystemExit('%s (SCRAP.PWR) is at x%04X' % (lab, tsyms[lab]))
    for lab in re.findall(r'^([A-Za-z_]\w*):', pw_src[k:], re.M):
        if not 0x4100 <= tsyms[lab] < 0x4500:
            raise SystemExit('%s (SCRAP.INI) is at x%04X' % (lab, tsyms[lab]))
    if not 0x4100 <= tsyms['dock_main'] < 0x4D00:
        raise SystemExit('dock_main is not in SCRAP.DCK (x%04X): it reads the rest in' % tsyms['dock_main'])
    own = set()
    for f in ('scrap_inv.masm', 'scrap_inv_data.masm', 'scrap_nav.masm', 'scrap_dck.masm', 'scrap_pwr.masm',
              'scrap_pwr_data.masm'):
        own |= set(re.findall(r'^([A-Za-z_]\w*):', open(os.path.join(HERE, f)).read(), re.M))
    for lab in re.findall(r'^([A-Za-z_]\w*):', src, re.M):
        if lab not in own and not lab.startswith('scw_') and 0x4100 <= tsyms.get(lab, 0) < 0x4D00:
            raise SystemExit('%s is in SCRAP.INV (x%04X)' % (lab, tsyms[lab]))  # resident code spilled
    prog, code = gen_plc.split_overlay(prog, lib, 0xC000, 2, [(0x5600, 0x5A00, 1), (0x5C00, 0x5E00, 1)])
    if any(0x4000 <= a < 0xC000 for a in prog):
        raise SystemExit('scrap.asm reaches past x3FFF')
    if gen_scrap.DOOR_PAGE != 0x32:     # scrap.masm's .region 0x2000, 0x3200 ends there
        raise SystemExit('the fixed pages start at x%02X00: change the region' % gen_scrap.DOOR_PAGE)
    plc = gen_plc.make(prog, tsyms, lib)[0]
    ovl += code                 # the code pages from xC000, after the map's
    return rom, syms, dsyms, lib, dos_plc, plc, tsyms, ovl, inv, (nav, nav2, nav3, art, dck, dk2, dk3, dk4, pwr, ini)


def swap_files(inv, navs):
    """the swap files for the SD image: build()'s inv and nav"""
    nav, nav2, nav3, art, dck, dk2, dk3, dk4, pwr, ini = navs
    return {'SCRAP.INV': inv, 'SCRAP.NAV': nav, 'SCRAP.NV2': nav2, 'SCRAP.NV3': nav3, 'SCRAP.ART': art,
            'SCRAP.DCK': dck, 'SCRAP.DK2': dk2, 'SCRAP.DK3': dk3, 'SCRAP.DK4': dk4,
            'SCRAP.PWR': pwr, 'SCRAP.INI': ini}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    ap.add_argument('--power', action='store_true', help='only the conduits and the power view (quick)')
    args = ap.parse_args(argv)
    rom, syms, dsyms, lib, dos_plc, plc, tsyms, ovl, inv, nav = build()
    files = {'DOS.PLC': dos_plc, 'SCRAP.PLC': plc, 'SCRAP.OVL': ovl, 'BOOT.CFG': b'SCRAP.PLC\r\n'}
    files.update(swap_files(inv, nav))
    for n, data in gen_scrap.prt_files().items():   # the part text (SCRAP/Kxy)
        files[gen_scrap.PRT_DIR + '/' + n] = data
    r = Rig(rom, syms, dsyms, lib, sdimage.make(files))
    r.args = args
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
    if (not p[0].strip().startswith('YOU') or 'AIR ON' not in p[0] or 'COMMS' in p[0] or 'MK1 WORK SUIT' not in p[1]
            or '1: SKILLS' not in p[1]
            or '2: TAKE OFF SUIT' not in p[2] or 'INVENTORY' in ''.join(p[1:5])):
        r.fail('the panel does not show the player')
    if not p[5].strip().startswith('DOCKED TO THE KESTREL 9'):
        r.fail('the welcome message')
    if mem[0x5BA0] & 0x70 != 0x40 or mem[0x5BF0] & 0x70 != 0x30:
        r.fail('the panel tints (%02X %02X)' % (mem[0x5BA0], mem[0x5BF0]))

    if args.power:
        deck_rules(r)
        power(r, args)
        print('PASS' if r.ok else 'FAILED')
        return 0 if r.ok else 1

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
    if test_dos.esc_to_dos(r) and r.cpu.map == 0xFF:     # (the DOS runs under map 07)
        r.fail('Esc: the game\'s map, not the DOS\'s')
    print('PASS' if r.ok else 'FAILED')
    return 0 if r.ok else 1


def phase3(r, args):
    """carrying, cutting, the tug, the air (phase 3)"""
    cpu, mem, z = r.cpu, r.cpu.mem, r.zp
    r.check_rooms('the rooms at the start')
    print('7. the tug: uninstalling its O2 tank, carrying it away, back, installing it')
    tank = (23, 33)
    r.go((24, 32), (24, 33))             # down to the cabin's O2 tank
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
        for _ in range(10):                     # (the text is read from the SD card)
            r.run(1)
            if 'OXYGEN TANK' in r.panel()[5]:
                break
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
    r.go((24, 32), (38, 32), (38, 29), (34, 29))   # the mess room (its door opens)
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
    r.go((24, 33))
    mem[r.tsyms['o2']] = 5
    tank = (23, 33)
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
    air0 = bytes(mem[0x4000:0x4020])        # the rooms' air before (the cabin shares the
    deck = (25, 34)                         #   wreck corridor's: the leaks drain both)
    if not r.act(*deck, gen_scrap.A_UNINST):
        return
    r.settle()
    r.check_job('UNINSTALL the deck', INST, T['FLOOR'], 35)
    q = r.room(24, 33)
    print('  %r: left hand %s, %d,%d %s' % (r.panel()[5].strip(), gen_scrap.TYPES[z('cl_t')][0],
                                          deck[0], deck[1], gen_scrap.TYPES[r.map_t(*deck)][0]))
    if r.map_t(*deck) != T['SPACE'] or z('cl_t') != T['PLATE']:
        r.fail('UNINSTALL did not take the deck plate up')
    r.check_rooms('a hole in the deck')
    p0 = r.press(q)
    r.run(120)
    print('  the cabin\'s air: %d -> %d in 2 s' % (p0, r.press(q)))
    if r.press(q) >= p0:
        r.fail('the hole in the deck does not leak')
    r.go((25, 33), deck)                    # out onto open space: a spacewalk
    print('  standing on the hole at %d,%d (%s)' % (z('p_x'), z('p_y'),
                                                  gen_scrap.TYPES[r.map_t(*deck)][0]))
    if (z('p_x'), z('p_y')) != deck:
        r.fail('could not walk onto open space')
    r.check_view('on open space')
    r.go((25, 33))
    if not r.act(*deck, gen_scrap.A_LAY):
        return
    r.run(4)
    if r.map_t(*deck) != T['FLOOR'] or z('cl_t'):
        r.fail('LAY DECK PLATE did not lay it')
    r.check_rooms('the deck laid again')

    r.go((26, 32))
    wall, hull = (26, 31), (22, 33)
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
    print('  %r: %d,%d %s; cabin room %d, cockpit room %d'
          % (r.panel()[5].strip(), wall[0], wall[1], gen_scrap.TYPES[r.map_t(*wall)][0],
             r.room(26, 32), r.room(26, 30)))
    if r.map_t(*wall) != T['PANEL'] or r.room(26, 32) != r.room(26, 30):
        r.fail('UNINSTALL of the wall did not join the cabin and the cockpit')
    r.check_rooms('the wall out, a broken hull wall')
    q = r.room(26, 32)
    saved = bytes(mem[0x4000:0x4020])
    lo = min(r.press(q) for _ in range(180) if r.run(1) is None)
    print('  the broken hull wall: the room\'s air down to %d in 3 s' % lo)
    if lo >= 100:
        r.fail('the broken hull wall does not leak')
    mem[a + 0x200] = fl                           # mended, the air back
    mem[0x4000:0x4020] = saved
    if not (r.act(*wall, gen_scrap.A_PICK) and r.act(*wall, gen_scrap.A_PUTL)):
        return
    if r.map_t(*wall) != T['PANEL'] or r.bolted(*wall):
        r.fail('the wall panel was not put down loose')
    if not r.act(*wall, gen_scrap.A_INSTALL):
        return
    r.settle()
    r.check_job('INSTALL the panel', INST, T['PANEL'], 35)
    if r.map_t(*wall) != T['WALL'] or r.room(26, 32) == r.room(26, 30):
        r.fail('INSTALL of the wall panel did not part the rooms')
    else:
        print('  the panel installed: a wall again, two rooms')
    r.check_rooms('the wall in again')
    mem[0x4000:0x4020] = air0                     # the air back (the same rooms again)
    r.wait_for(lambda: z('o2') == 90, 200, 'the suit filled again')   # (it used its own)
    r.check_view('the tug changed')


def set_cell(r, x, y, ty=None, fl=None):
    """map cell x, y's type byte and flag byte (None: kept)"""
    k = 6 * (y >> 4) + (x >> 4)
    a = ((0x60 + 4 * k) << 8) + 16 * (y & 15) + (x & 15)
    if ty is not None:
        r.cpu.mem[a] = ty
    if fl is not None:
        r.cpu.mem[a + 0x200] = fl


def pump_intake(r):
    """the tug's air needs a working pump by its O2 tank; its fuel is the
    nitrogen tanks with a working intake by them (one of its two)"""
    z = r.zp
    print('  O2 tanks with a pump %d, nitrogen tanks with an intake %d, air %s'
          % (z('n_o2'), z('n_fuel'), 'on' if z('sup') else 'off'))
    if (z('n_o2'), z('n_fuel')) != (1, 1) or not z('sup'):
        r.fail('the tug\'s pump and intake at the start')
    for cell, what in (((23, 34), 'pump'), ((28, 30), 'intake')):
        ty, fl = r.map_raw(*cell)
        want = (0, 1, 0) if what == 'pump' else (1, 0, 1)
        state = lambda: (z('n_o2'), z('n_fuel'), 1 if z('sup') else 0)
        set_cell(r, *cell, fl=(fl & 0xF0) | 10)      # broken (the scan is once a second)
        ok = r.wait_for(lambda: state() == want, 200, 'the tug with its %s broken' % what)
        got = state()
        set_cell(r, *cell, fl=fl)
        ok = r.wait_for(lambda: state() == (1, 1, 1), 200, 'the %s working again' % what) and ok
        print('  the %s broken: O2 %d, fuel %d, air %s; working again: %s'
              % (what, got[0], got[1], 'on' if got[2] else 'off', 'yes' if ok else 'no'))


def partial_repair(r):
    """REPAIR on a deck at 75 % damage, stopped part way by a step: the
    steps done stay done"""
    z, mem = r.zp, r.cpu.mem
    deck = (24, 34)
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
    r.wait_for(lambda: mem[r.tsyms['JB_N']] >= 4, 3000, 'four repair steps')
    if '[' in r.panel()[5]:
        r.fail('a job bar while repairing: %r' % r.panel()[5])
    r.go((z('p_x') + 2, z('p_y')))        # away (not by it, diagonals count): the job stops
    n, d = mem[r.tsyms['JB_N']], r.map_raw(*deck)[1] & 15
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
    door = (24, 31)
    ty, fl = r.map_raw(*door)
    r.go((24, 32))
    set_cell(r, *door, ty=(ty & 0xC0) | T["DOOR"], fl=(fl & 0xF0) | 10)
    r.hold(UP, 2)
    r.run(2)
    print('  into the jammed door: at %d,%d, %r' % (z('p_x'), z('p_y'), r.panel()[5].strip()))
    if (z('p_x'), z('p_y')) != (24, 32) or 'JAMMED' not in r.panel()[5] or r.map_t(*door) != T['DOOR']:
        r.fail('the jammed door let the player through')
    if r.act(*door, gen_scrap.A_OPEN):
        if r.map_t(*door) != T['DOOR'] or 'JAMMED' not in r.panel()[5]:
            r.fail('OPEN opened the jammed door')
    set_cell(r, *door, ty=ty, fl=fl)
    r.mouse_cell(*door)
    r.run(2)
    r.check_view('the door mended')


def cbit(r, x, y):
    """cell x, y's conduit bit (cb_get: the screen bytes no line shows)"""
    a = ((0xA1 + (x & 0xF8) + 2 * (y >> 4)) << 8) + 2 * (y & 15)
    return bool(r.cpu.mem[a] >> (x & 7) & 1)


def cbits(r):
    """every cell with a conduit"""
    return {(x, y) for y in range(gen_scrap.MAP_H) for x in range(gen_scrap.MAP_W) if cbit(r, x, y)}


def ram_map(r):
    """the map in RAM: kinds, damage, bolted (rows of cells)"""
    t = [[r.map_t(x, y) for x in range(gen_scrap.MAP_W)] for y in range(gen_scrap.MAP_H)]
    d = [[r.map_raw(x, y)[1] & 15 for x in range(gen_scrap.MAP_W)] for y in range(gen_scrap.MAP_H)]
    b = [[r.bolted(x, y) for x in range(gen_scrap.MAP_W)] for y in range(gen_scrap.MAP_H)]
    return t, d, b


PW_SEGT = ((4, 8, 1, 0, 0), (4, 8, 4, 1, 0), (0, 8, 5, 1, 0), (4, 8, 4, 0, 2), (4, 0, 5, 0, 2))
PW_ADJ = ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1))


def pw_seg(b, side, col):
    """scrap_pwr.masm's seg on art bytes b (16 c + row): the half line to
    side (PW_ADJ's), colour col (a nibble)"""
    px, row, n, dpx, drow = PW_SEGT[side]
    for _ in range(n):
        for rr in (row, row + 1):
            i = 16 * (px >> 1) + rr
            b[i] = (b[i] & 0xF0) | col if px & 1 else (b[i] & 0x0F) | col << 4
        px, row = px + dpx, row + drow


def pw_overlay(r, art, x, y, st):
    """the power view's lines over cell x, y's art (ov_cell); st = (kinds,
    bolted, conduits, live)"""
    t, b, cond, lv = st
    name = gen_scrap.TYPES[t[y][x]][0]
    if name == 'SPACE':
        return art
    me_c, me_p = (x, y) in cond, gen_scrap.plugged(name, b[y][x])
    if not me_c and not me_p:
        return art
    out, drawn = bytearray(art), False
    mine = 0xE if (x, y) in lv else 0xD
    for s in range(1, 5):
        n = (x + PW_ADJ[s][0], y + PW_ADJ[s][1])
        if n in cond:
            pw_seg(out, s, mine if me_c else (0xE if n in lv else 0xD))
            drawn = True
        elif me_c and gen_scrap.plugged(gen_scrap.TYPES[t[n[1]][n[0]]][0], b[n[1]][n[0]]):
            pw_seg(out, s, mine)
            drawn = True
    if me_c and not drawn:
        pw_seg(out, 0, mine)
    return bytes(out)


def power(r, args):
    """conduits are a bit a cell (under parts, in walls); V: the power
    view, live conduits yellow, dead ones orange, plugged-in stubs; a
    conduit section placed in a wall and under a part"""
    z, mem = r.zp, r.cpu.mem
    st_a = r.tsyms['PW_ST']
    print('7e. conduits and the power view')
    t0, d0 = gen_scrap.build_map()
    want = set(gen_scrap.conduits(t0))
    got = cbits(r)
    print('  %d conduits at the start (%d in walls), the bits: %d' % (len(want), len(gen_scrap.TUG_WIRE), len(got)))
    if got != want:
        r.fail('the conduit bits: %s missing, %s extra' % (sorted(want - got)[:4], sorted(got - want)[:4]))
    def view_on(what, cells=()):
        c0 = r.cpu.clocks
        r.key('v')
        r.run_until(lambda: mem[st_a] == 3 and r.cpu.pc == r.tsyms['loop'], 600, 'the power view')
        r.run(2)
        t, d, b = ram_map(r)
        cond = cbits(r)
        lv = gen_scrap.live(t, d, cond, b)
        vis = {(x, y) for y in range(64) for x in range(96)
               if (x, y) in cond and mem[((0x43 + (y >> 4)) << 8) + 16 * (y & 15) + (x >> 3)] >> (x & 7) & 1}
        print('  V (%s): %d frames, %d of %d conduits live' % (what, (r.cpu.clocks - c0) // FRAME, len(vis), len(cond)))
        if vis != lv:
            r.fail('%s: live conduits %s missing, %s extra' % (what, sorted(lv - vis)[:4], sorted(vis - lv)[:4]))
        r.check_view('the power view, %s' % what, pv=(t, b, cond, lv))
        for c, col in cells:
            cx, cy = c[0] - z('v_x'), c[1] - z('v_y')
            got = r.cell_bytes(cx, cy)[16 * 2 + 8] >> 4      # pixel 4, row 8
            if got != col:
                r.fail('%s: %d,%d is colour %X, not %X' % (what, c[0], c[1], got, col))
        return lv
    def view_off():
        r.key('v')
        r.run(4)
        if mem[st_a] & 1:
            r.fail('V did not turn the power view off')
        r.check_view('the power view off')
    react, batt = (25, 29), (26, 29)
    lv = view_on('the start', [((24, 28), 0xE), ((23, 35), 0xE), ((26, 30), 0xE)])
    if not {(22, 28), (25, 30), (27, 30)} <= lv:
        r.fail('the tug\'s conduits are not live')
    if args.png:
        ps.render(mem, args.png.replace('.png', '_power.png'))
        print('  wrote', args.png.replace('.png', '_power.png'))
    view_off()
    rd, bd = r.map_raw(*react), r.map_raw(*batt)
    set_cell(r, *react, fl=(rd[1] & 0xF0) | 9)          # the reactor and battery broken: all dark
    set_cell(r, *batt, fl=(bd[1] & 0xF0) | 8)
    lv = view_on('no working source', [((24, 28), 0xD), ((26, 30), 0xD)])
    if lv & set(gen_scrap.TUG_WIRE):
        r.fail('the tug\'s conduits live with no working source')
    view_off()
    set_cell(r, *react, fl=rd[1])
    set_cell(r, *batt, fl=bd[1])
    # a conduit section in a wall, under a part (from a carry slot)
    slots = [z('cl_t'), z('cr_t'), z('cb_t')]
    k = slots.index(0) if 0 in slots else None
    if k is None:
        r.fail('no free carry slot: %s' % slots)
        return
    r.go((24, 33))
    for target, kind in (((23, 33), 'O2'), ((24, 32), None)):
        mem[r.tsyms['cl_t'] + k] = T['COND']
        mem[r.tsyms['cl_d'] + k] = 0
        r.key('i')
        r.run(4)
        inv_mouse(r, k)
        r.click(1)
        if not r.key_act(gen_scrap.A_INSTALL):
            return
        r.run(4)
        r.mouse_cell(*target)
        r.click(1)
        r.run(2)
        r.settle()
        r.click(2)
        name = gen_scrap.TYPES[r.map_t(*target)][0]
        print('  a conduit section placed at %d,%d: %s, bit %s, slot %d' % (target[0], target[1], name, cbit(r, *target),
                                                                            mem[r.tsyms['cl_t'] + k]))
        if not cbit(r, *target) or mem[r.tsyms['cl_t'] + k] or name != (kind or 'PIPE'):
            r.fail('a conduit section at %d,%d: %s, bit %s' % (target[0], target[1], name, cbit(r, *target)))
    mem[r.tsyms['cl_t'] + k] = T['COND']               # where there is one: refused
    r.key('i')
    r.run(4)
    inv_mouse(r, k)
    r.click(1)
    if r.key_act(gen_scrap.A_INSTALL):
        r.run(4)
        r.mouse_cell(23, 33)                           # (under the O2 tank: the one just placed)
        r.click(1)
        r.run(2)
        print('  where there is a conduit: %r' % r.panel()[5].strip())
        if z('cut_t') or 'CONDUIT THERE ALREADY' not in r.panel()[5]:
            r.fail('a second conduit in a cell was not refused')
        r.click(2)
    mem[r.tsyms['cl_t'] + k] = 0
    r.run(4)
    view_on('two sections placed', [((23, 33), 0xE), ((24, 32), 0xD)])   # (24,32: by no conduit, dark)
    view_off()
    r.go((24, 32))


def deck_rules(r):
    """a part goes on a deck or a conduit, never a broken one; the conduit
    under a part comes back when it is picked up; a second click on a
    part shows what is under it; a conduit uninstalls to a section that
    installs again"""
    z, mem = r.zp, r.cpu.mem
    print('7d. decks, conduits')
    r.go((24, 30))
    pipe, deck = (25, 30), (23, 30)
    p0, d0 = r.map_raw(*pipe), r.map_raw(*deck)
    if r.map_t(*pipe) != T['PIPE'] or (z('p_x'), z('p_y')) != (24, 30):
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
        print('  a crate put down on the conduit: %s, its bit %s' % (gen_scrap.TYPES[r.map_t(*pipe)][0], cbit(r, *pipe)))
        if r.map_t(*pipe) != T['CRATE'] or not cbit(r, *pipe):
            r.fail('PUT DOWN on a conduit: %d, bit %s' % (r.map_t(*pipe), cbit(r, *pipe)))
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
        print('  picked up: %s, its bit %s' % (gen_scrap.TYPES[r.map_t(*pipe)][0], cbit(r, *pipe)))
        if r.map_t(*pipe) != T['PIPE'] or not cbit(r, *pipe) or mem[r.tsyms['cl_t'] + k] != T['CRATE']:
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
        if r.map_t(*pipe) != T['COND'] or r.bolted(*pipe) or cbit(r, *pipe):
            r.fail('UNINSTALL of a conduit: not a loose conduit section')
    if r.act(*pipe, gen_scrap.A_PICK):
        if r.map_t(*pipe) != T['FLOOR'] or mem[r.tsyms['cl_t'] + k] != T['COND']:
            r.fail('PICK UP of the conduit section')
    if r.act(*deck, gen_scrap.A_PUTL + k) and r.act(*deck, gen_scrap.A_INSTALL):
        print('  the section put down and installed: %s' % gen_scrap.TYPES[r.map_t(*deck)][0])
        if r.map_t(*deck) != T['PIPE'] or not cbit(r, *deck):
            r.fail('INSTALL of a conduit section: not a conduit')
    if r.act(*deck, gen_scrap.A_UNINST) and r.act(*deck, gen_scrap.A_PICK):   # and back
        if r.act(*pipe, gen_scrap.A_PUTL + k) and r.act(*pipe, gen_scrap.A_INSTALL):
            pass
    if (r.map_t(*pipe) != T['PIPE'] or r.map_t(*deck) != T['FLOOR'] or mem[r.tsyms['cl_t'] + k]
            or not cbit(r, *pipe) or cbit(r, *deck)):
        r.fail('the conduit not back: %d %d' % (r.map_t(*pipe), r.map_t(*deck)))
    set_cell(r, *pipe, fl=p0[1])            # (the damage: under 8, drawn the same)
    set_cell(r, *deck, fl=d0[1])
    r.mouse_cell(*deck)
    r.run(2)
    r.check_view('the conduits back')
    r.go((24, 32))


def comms(r):
    """the tug's antenna, barely working at the start: comms (N_ANT 1, for
    the navigation mode); broken: N_ANT 0; the player's panel says nothing"""
    z = r.zp
    ant = gen_scrap.TUG_ANT
    a0 = r.map_raw(*ant)
    if r.map_t(*ant) != T['ANT'] or not r.bolted(*ant):
        r.fail('no antenna on the tug at %d,%d' % ant)
        return
    rows = []
    for d in (11, a0[1] & 15):
        set_cell(r, *ant, fl=(a0[1] & 0xF0) | d)
        r.run(70)                           # tug_scan: once a second
        seen = 0                            # (it takes more than a frame: N_ANT is 0
        for _ in range(70):                 # while it counts)
            r.run(1)
            seen |= r.cpu.mem[r.tsyms['N_ANT']]
        r.mouse_cell(z('p_x'), z('p_y'))
        r.run(2)
        rows.append((seen, r.panel()[0][22:52].strip()))
    print('  the antenna broken: %r; as at the start: %r' % tuple(rows))
    if rows[0][0] != 0 or rows[1][0] != 1 or any('COMMS' in p for _, p in rows):
        r.fail('comms: %r' % rows)
    set_cell(r, *ant, fl=a0[1])
    r.run(70)


def dk_pix(mem, x, p):
    """the docking screen's 2 pixels x (x / 2) at line pair p (1 bpp: 0-3)"""
    b = mem[((0x61 + ((x >> 1) & 0x7E)) << 8) + line_off(p)]
    return (b >> 2 * (x & 3)) & 3


def dock_open(r):
    """C on the map: the docking screen (SCRAP.DCK, DK2, DK3 read in)"""
    mem = r.cpu.mem
    r.mouse_to(0, 27 * 16 + 4)             # the pointer off the text (a blank panel row)
    r.key('c')
    if not r.wait_for(lambda: mem[FL + 0x20] == 2 and 'COMMS CONTROL' in r.text(0).upper()
                      and 'HAIL' in r.text(7).upper(), 300, 'the docking screen'):
        return False
    r.run(20)
    return True


def dock_close(r):
    """Esc: back to the map"""
    mem = r.cpu.mem
    r.port.kbd.press(r.codes['\x1b'])
    r.run(10)
    r.port.kbd.release(r.codes['\x1b'])
    if not r.wait_for(lambda: mem[FL + 0x20] == 1 and 'target' in r.text(24), 300, 'the map again'):
        return False
    r.run(20)
    return True


# the tug's shapes for headings 0-4 (scrap_nav.masm NV_TS): (first x, length)
# for each row from y = -4 down
TUG_ROWS = [[(-3, 1), (-3, 3), (-2, 5), (-2, 7), (-1, 8), (-2, 7), (-2, 5), (-3, 3), (-3, 1)],
            [(-2, 1), (-2, 3), (-2, 4), (-1, 5), (-1, 6), (-2, 9), (-3, 7), (-4, 3)],
            [(-2, 2), (-1, 2), (-1, 3), (0, 3), (0, 4), (-2, 7), (-4, 10)],
            [(-1, 2), (-1, 3), (-1, 3), (-1, 4), (-3, 7), (-4, 8), (-3, 8), (2, 4)],
            [(0, 2), (0, 2), (0, 2), (-1, 4), (-4, 7), (-4, 8), (-1, 5), (1, 4), (3, 2)]]


def tug_shape(h):
    """the tug's pixels (dx, dy) at heading h (0-31): 5-7 are 3-1 with x and
    y swapped, then quarter turns clockwise"""
    b = h & 7
    k = 8 - b if b > 4 else b
    pts = {(x0 + i, y - 4) for y, (x0, n) in enumerate(TUG_ROWS[k]) for i in range(n)}
    if b > 4:
        pts = {(y, x) for x, y in pts}
    for _ in range(h >> 3 & 3):
        pts = {(-y, x) for x, y in pts}
    return pts


def tug_headings(r):
    """the tug in the middle of the map (128, 92) at every one of its 32
    headings, then back to the one it had"""
    mem = r.cpu.mem
    h0 = mem[FL + 0x22]
    bad = []
    for h in list(range(32)) + [h0]:
        mem[FL + 0x22] = h
        r.run(20)
        got = {(x - 128, y - 92) for y in range(84, 101) for x in range(120, 137) if nav_pixel(mem, x, y) == 3}
        if got != tug_shape(h):
            bad.append(h)
    print('  the tug drawn at all 32 headings%s' % (': wrong at %s' % bad if bad else ''))
    if bad:
        r.fail('the tug at headings %s' % bad)


def navigation(r):
    """NAVIGATE at the helm: the nav screen, the tug's mass and thrusters,
    the docking screen (hail, undock), thrust, turning, cruising while
    walking, a collision and docking again (declared, a miss, the rings
    lined up, the clamps)"""
    z, mem, cpu = r.zp, r.cpu.mem, r.cpu
    print('7e. navigation')
    W = gen_scrap.MASS
    mass = nt = 0
    for y in range(gen_scrap.TUG[1], gen_scrap.TUG[3] + 1):
        for x in range(gen_scrap.TUG[0], gen_scrap.TUG[2] + 1):
            t = r.map_t(x, y)
            name = gen_scrap.TYPES[t][0]
            if gen_scrap.TYPES[t][3] & gen_scrap.F_ITEM and not r.bolted(x, y):
                continue
            mass += W.get(name, 0)
            nt += name == 'THRUST' and r.map_raw(x, y)[1] & 15 < 8
    got = (fl_get(mem, 0x25, 2, False), mem[FL + 0x24])
    print('  the tug: %d00 kg, %d thrusters (the map: %d00 kg, %d); docked %d'
          % (got[0], got[1], mass, nt, mem[FL + 0x21]))
    if got != (mass, nt) or mem[FL + 0x21] != 1:
        r.fail('the tug\'s mass and thrusters: %s, wanted %s' % (got, (mass, nt)))
    helm = (24, 29)
    if not r.go((24, 30)):
        return
    r.mouse_cell(*helm)
    r.click(1)
    acts = [mem[r.tsyms['act0'] + i] for i in range(z('n_act'))]
    if gen_scrap.A_NAV not in acts:
        r.fail('no NAVIGATE at the helm: %s' % acts)
        r.click(2)
        return
    r.key(str(1 + acts.index(gen_scrap.A_NAV)))
    if not r.wait_for(lambda: mem[FL + 0x20] and 'flight' in r.text(24), 200, 'the nav screen'):
        return
    r.run(20)
    pos0 = bytes(mem[0x4022:0x4023]) + bytes(mem[0x4060:0x4070])
    r.hold(RIGHT, 20)       # docked: no turning, no thrust
    r.hold(UP, 20)
    if bytes(mem[0x4022:0x4023]) + bytes(mem[0x4060:0x4070]) != pos0:
        r.fail('docked, the tug turned or moved: heading %d' % mem[FL + 0x22])
    r.run(20)
    p = [' '.join(line.replace('_', ' ').split()) for line in r.panel()]
    for line in p[:5]:
        print('  |%s' % line)
    fuel0 = fl_get(mem, 0x2D, 2, False)
    if ('DOCKED' not in p[2] or 'SPEED' in ''.join(p) or 'N2 KG %d' % fuel0 not in p[1]
            or 'THRUSTERS %d' % nt not in p[3] or 'HEADING 0' not in p[1]
            or 'target: kestrel 9' not in p[0] or 'DERELICT FREIGHTER' not in p[1] or 'REG KS-0917-D' not in p[1]
            or 'RANGE M 20 ' not in p[2] or ' VISITED' not in p[2] or 'NOT VISITED' in p[2]
            or 'range 1 km' not in p[4]):
        r.fail('the nav panel: %r' % p[:5])
    modes = [mem[0x5A20 + i] & 15 for i in (0, 15, 16, 383, 384)]
    if modes != [0x04, 0x04, 0x05, 0x05, 0x04]:
        r.fail('the status row 1 bpp, the map\'s lines 2 bpp: %s' % modes)
    st = r.text(0)
    mass5 = min(255, fl_get(mem, 0x25, 2, False) // 5)
    dv = fuel0 * 40 // mass5
    print('  status: |%s|' % st.rstrip())
    clk = mem[0x35E6] | mem[0x35E7] << 8 | mem[0x35FF] << 16
    times = ['%02d:%02d:%02d' % (t // 3600 % 24, t // 60 % 60, t % 60) for t in (clk, clk - 1)]
    if (not re.search(r'05-07-2175 +\d\d:\d\d:\d\d +NITROGEN %d KG +DELTA-V %d M/S +BATTERIES \d' % (fuel0, dv), st)
            or not any(t in st for t in times) or not 28800 < clk < 28800 + 3600):
        r.fail('the status row: %r (delta-v %d, clock %s)' % (st, dv, times))
    tug_headings(r)
    gx = (fl_get(mem, 0x62, 2, False) >> 2) & 63      # the grid: world lines every 64 pixels
    gy = ((fl_get(mem, 0x66, 2, False) >> 2) + 36) & 63
    if (mem[0x40B8], mem[0x40B9]) != (gx, gy):
        r.fail('the grid\'s offsets %s, not %s' % ((mem[0x40B8], mem[0x40B9]), (gx, gy)))
    gxs = (-gx) & 63
    gys = [y for y in range(0, 60) if (y + gy) & 3 == 0 and (y + gy) & 63]
    if nav_pixel(mem, gxs, gys[0]) != 1 or nav_pixel(mem, gxs + 1, gys[0]) != 0 or nav_pixel(mem, gxs, gys[0] + 1) != 0:
        r.fail('the grid (blue) at x %d' % gxs)
    k9 = 128 + 100 // 4                     # the KESTREL 9: 100 m east, a diamond (visited), the target
    if nav_pixel(mem, k9, 92 - 2) != 2 or nav_pixel(mem, k9 - 5, 92 - 5) != 2 or nav_pixel(mem, k9, 92) == 2:
        r.fail('the KESTREL 9 on the map (%X %X)' % (nav_pixel(mem, k9, 90), nav_pixel(mem, k9 - 5, 87)))
    r.key('\t')
    r.run(20)
    p = [' '.join(line.replace('_', ' ').split()) for line in r.panel()]
    print('  Tab: |%s|%s|%s' % tuple(p[:3]))
    if (mem[0x4080] != 1 or 'target: halvard rock' not in p[0] or 'STATION ASTEROID BASE' not in p[1]
            or 'RANGE M 4800 ' not in p[2] or 'NOT VISITED' not in p[2]):
        r.fail('Tab: the next target: %r' % p[:3])
    r.mouse_to(64 + 2 * k9 + 1, 2 * (92 + 8) + 1)     # a click on the KESTREL 9
    r.click(1)
    r.run(20)
    if mem[0x4080] != 0 or 'target: kestrel 9' not in r.text(24):
        r.fail('a click on the KESTREL 9: target %d, %r' % (mem[0x4080], r.text(24)))
    if not dock_open(r):
        return
    rows = [r.text(k).upper() for k in range(24)]
    for k in (0, 1, 2, 4, 7, 13, 22):
        print('  |%s' % rows[k])
    modes = [mem[0x5A20 + k] & 15 for k in (0, 200, 383, 384)]
    ring = [mem[FL + k] for k in range(0xE4, 0xE8)]
    if (' DOCKING ' not in rows[0] or ' COMMS CONTROL ' not in rows[0] or 'CLAMPED TO PORT 1' not in rows[4]
            or ' 1  HAIL' not in rows[7] or ' 4  RELEASE CLAMPS' not in rows[13] or 'RANGE M  0' not in rows[1]
            or 'DOCKED: CLAMPS ON' not in rows[22] or modes != [4, 4, 4, 4]):
        r.fail('the docking screen: %r, modes %s' % (rows[:23], modes))
    if dk_pix(mem, 80 + 48, 104) != 3 or dk_pix(mem, 80, 104 - 48) != 3 or ring != [1, 80, 104, 60] \
            or dk_pix(mem, 80 + 60, 104) != 1:
        r.fail('the rings: the tug\'s %d %d, the port\'s %s %d'
               % (dk_pix(mem, 128, 104), dk_pix(mem, 80, 56), ring, dk_pix(mem, 140, 104)))
    for key, want in (('4', 'CLAMPS LOCKED'), ('3', 'HAIL THE KESTREL 9 FIRST'), ('1', 'NO REPLY'),
                      ('3', 'UNDOCKING DECLARED')):
        r.key(key)
        r.run(4)
        print('  %s: %r' % (key, r.panel()[5].strip()))
        if want not in r.panel()[5] or not mem[FL + 0x21]:
            r.fail('docked, %s: %r' % (key, r.panel()[5]))
    r.run(16)
    if 'CLAMPED, UNDOCK DECLARED' not in r.text(4):
        r.fail('the status: %r' % r.text(4))
    r.key('4')
    r.run(4)
    vx = fl_get(mem, 0x68, 4)
    print('  4: %r; vx %d (%d wanted), the locks %s %s'
          % (r.panel()[5].strip(), vx, -gen_scrap.UNDOCK_V,
             gen_scrap.TYPES[r.map_t(29, 32)][0], gen_scrap.TYPES[r.map_t(30, 32)][0]))
    if (mem[FL + 0x21] or vx not in (-gen_scrap.UNDOCK_V, -gen_scrap.UNDOCK_V - 1)
            or 'CLAMPS RELEASED' not in r.panel()[5]
            or r.map_t(29, 32) != T['DOOR'] or r.map_t(30, 32) != T['WALL']):
        r.fail('undocking')
    r.run(64)
    rows = [r.text(k).upper() for k in range(24)]
    d2, rr = mem[FL + 0xE0], mem[FL + 0xE7]
    print('  |%s' % rows[1])
    print('  a second out: %.1f m, the port\'s ring radius %d (range %d half metres)'
          % (((gen_scrap.DOCK_POS[0] << 16) - fl_get(mem, 0x60, 4)) / 65536, rr, d2))
    if (not re.search(r'RANGE M \+[4-6] .*CLOSE M/S -(4\.[89]|5\.0)', rows[1]) or rr != max(2, 960 // (d2 + 16))
            or not 10 <= d2 <= 12 or 'NOT HAILED' in rows[4] or not rows[13].endswith(' 4  CLAMP')
            or 'DOCKED' in rows[22] or 'CLEAR' in rows[22]):
        r.fail('undocked: the readouts %r, the ring %d (%d)' % (rows[1:5] + rows[13:14] + rows[22:23], rr, d2))
    if not dock_close(r):
        return
    p = [' '.join(line.replace('_', ' ').split()) for line in r.panel()]
    m = re.search(r'TOWARD M/S (-?\d+) ACROSS M/S (\d+)', p[3])
    print('  |%s' % p[3])
    if 'FREE FLIGHT' not in p[2] or not m or int(m.group(1)) not in (-4, -5) or m.group(2) != '0':
        r.fail('undocked: the speed toward the KESTREL 9: %r' % p[3])
    dvx = fl_get(mem, 0x70, 2)
    want = nt * 20000 / (mass * 100) / 3600 * 2 ** 24      # 20 kN a thruster
    print('  a frame of thrust: %d (%.0f from 20 kN a thruster)' % (dvx, want))
    if not 0.85 * want <= dvx <= 1.05 * want:
        r.fail('the thrust per frame: %d, not %.0f' % (dvx, want))
    r.hold(UP, 60)
    n = (fl_get(mem, 0x68, 4) - vx) / dvx if dvx else 0
    fuel1 = fl_get(mem, 0x2D, 2, False)
    print('  Up held 60 frames: %.2f frames of thrust, nitrogen %d -> %d kg' % (n, fuel0, fuel1))
    if n != int(n) or not 58 <= n <= 64 or not nt * n // 60 - 1 <= fuel0 - fuel1 <= nt * n // 60 + 1:
        r.fail('thrust: %.2f frames, %d L' % (n, fuel0 - fuel1))
    rvx = fl_get(mem, 0x74, 2)              # back: half, west while heading east
    v0 = (fl_get(mem, 0x68, 4), fl_get(mem, 0x6C, 4))
    r.hold('q', 30)
    dq = (fl_get(mem, 0x68, 4) - v0[0], fl_get(mem, 0x6C, 4) - v0[1])
    r.hold('e', 30)
    de = (fl_get(mem, 0x68, 4) - v0[0], fl_get(mem, 0x6C, 4) - v0[1])
    nq = dq[1] / rvx if rvx else 0
    print('  Q held 30 frames: velocity +%s (%.2f frames of half thrust north); then E: +%s' % (dq, nq, de))
    if dq[0] or nq != int(nq) or not 28 <= nq <= 34 or de[0] or abs(de[1]) > abs(rvx) * 4:
        r.fail('sideways thrust (Q, E): %s %s' % (dq, de))
    r.run(16)
    g = ((fl_get(mem, 0x62, 2, False) >> 2) & 63, ((fl_get(mem, 0x66, 2, False) >> 2) + 36) & 63)
    print('  the grid moved with the tug: offsets %s, then %s' % ((gx, gy), (mem[0x40B8], mem[0x40B9])))
    if (mem[0x40B8], mem[0x40B9]) != g or g == (gx, gy):
        r.fail('the grid does not move with the tug: %s, wanted %s' % ((mem[0x40B8], mem[0x40B9]), g))
    h0 = mem[FL + 0x22]                 # the spin: Left / Right spin up, it goes on, R stops it
    r.hold(RIGHT, 2 * gen_scrap.NAV_SPIN)
    s1 = mem[FL + 0xBA]
    h1 = mem[FL + 0x22]
    r.run(40)
    h2 = mem[FL + 0x22]
    r.key('r')
    r.run(2 * gen_scrap.NAV_SPIN)
    s3, h3 = mem[FL + 0xBA], mem[FL + 0x22]
    r.run(30)
    print('  heading %d; Right held: spin %d/256 a frame, heading %d, 40 frames on %d; R: spin %d, heading %d, then %d'
          % (h0, s1, h1, h2, s3, h3, mem[FL + 0x22]))
    if (s1 != gen_scrap.NAV_SPIN or h1 == h0 or not 4 <= (h2 - h1) & 31 <= 6
            or s3 or mem[FL + 0x22] != h3):
        r.fail('the spin')
    r.hold(LEFT, 10)
    if not 256 - 13 <= mem[FL + 0xBA] <= 256 - 8:
        r.fail('Left: spin %d' % mem[FL + 0xBA])
    mem[FL + 0x22], mem[FL + 0xBB], mem[FL + 0xBA], mem[FL + 0xBE] = (h0 - 1) & 31, 0xFF, 1, 0
    r.run(2)                            # heading h0 again (by a step: the thrust worked out), no spin
    mem[FL + 0xBA] = 0
    if mem[FL + 0x22] != h0:
        r.fail('back to heading %d: %d' % (h0, mem[FL + 0x22]))
    for _ in range(8):
        r.key('-')
    r.run(10)
    zoom = mem[FL + 0x2F]
    if zoom != 7 or 'range 128 km' not in r.panel()[4]:
        r.fail('-: zoom %d, %r' % (zoom, r.panel()[4]))
    for _ in range(6):
        r.key('=')
    r.run(20)
    p = r.panel()
    for line in p[:5]:
        print('  |%s' % line)
    if 'FREE FLIGHT' not in p[2] or mem[FL + 0x2F] != 1 or 'range 2 km' not in p[4]:
        r.fail('the panel undocked, zoom 1: %r' % p[3:5])
    r.key('=')

    print('  a collision: 30 m/s at the KESTREL 9')
    saved = {pg: bytes(mem[pg << 8:(pg + 1) << 8]) for pg in range(0x60, 0xC0, 2)}
    fl_put(mem, 0x60, 4, (gen_scrap.WRECK_POS[0] - gen_scrap.WRECK_BOX - 150) << 16)   # 5 s out
    fl_put(mem, 0x64, 4, gen_scrap.WRECK_POS[1] << 16)
    fl_put(mem, 0x68, 4, 0x800000)          # 0.5 m a frame east
    fl_put(mem, 0x6C, 4, 0)
    al = []
    for _ in range(8 * 60):
        r.run(1)
        if mem[FL + 0x27] not in al:
            al.append(mem[FL + 0x27])
        if not fl_get(mem, 0x68, 4):
            break
    r.run(30)
    hit = []                                # the flag pages (x62 + 4 k): damage
    for pg, b in saved.items():
        if (pg - 0x62) % 4 == 0:
            k = (pg - 0x62) // 4
            hit += [(16 * (k % 6) + (i & 15), 16 * (k // 6) + (i >> 4)) for i in range(256)
                    if mem[(pg << 8) + i] != b[i]]
    px = fl_get(mem, 0x62, 2, False)
    print('  alarms %s; %r; %d cells damaged; stopped at x %d m (hull at %d)'
          % (al, r.panel()[5].strip(), len(hit), px, gen_scrap.WRECK_POS[0] - gen_scrap.WRECK_BOX))
    if 2 not in al or 'IMPACT!' not in r.panel()[5] or not 1 <= len(hit) <= 16 or fl_get(mem, 0x68, 4):
        r.fail('the collision')
    if any(not gen_scrap.TUG[0] <= x <= gen_scrap.TUG[2] for x, _ in hit):
        r.fail('damage off the tug: %s' % hit[:4])
    for pg, b in saved.items():             # the tug mended
        mem[pg << 8:(pg + 1) << 8] = b

    fl_put(mem, 0x60, 4, (gen_scrap.DOCK_POS[0] - 3000) << 16)   # cruising: 3 km out
    fl_put(mem, 0x68, 4, -0x100000)         # 1/16 m a frame west
    r.run(8)
    print('  Esc: back to the ship, cruising')
    r.port.kbd.press(r.codes['\x1b'])
    r.run(10)
    r.port.kbd.release(r.codes['\x1b'])
    if not r.run_until(lambda: cpu.pc == r.tsyms['loop'] and not mem[FL + 0x20], 300, 'the ship again'):
        return
    r.run(30)
    if [mem[0x5A20 + i] for i in (0, 383)] != [0x06, 0x06]:
        r.fail('the ship\'s view is not 4 bpp again')
    x0 = fl_get(mem, 0x60, 4)
    r.hold(DOWN, 2)
    r.run(60)
    d = (fl_get(mem, 0x60, 4) - x0) / 65536
    print('  walking: the tug moved %.1f m in about a second; at %d,%d' % (d, z('p_x'), z('p_y')))
    if not -6 <= d <= -3:
        r.fail('the tug does not cruise while walking')
    r.check_view('undocked')
    r.check_rooms('undocked')

    r.go((24, 30))
    r.mouse_cell(*helm)
    r.click(1)
    r.key(str(1 + acts.index(gen_scrap.A_NAV)))
    if not r.wait_for(lambda: mem[FL + 0x20], 200, 'the nav screen again'):
        return
    fl_put(mem, 0x60, 4, (gen_scrap.DOCK_POS[0] - 2) << 16)     # 2 m from the port, still
    fl_put(mem, 0x64, 4, gen_scrap.DOCK_POS[1] << 16)
    fl_put(mem, 0x68, 4, 0)
    fl_put(mem, 0x6C, 4, 0)
    mem[FL + 0xBA], mem[FL + 0xBE] = 16, 0  # spinning on the map
    if not dock_open(r):
        return
    yr, pr = mem[FL + 0xEE], mem[FL + 0xF1]
    yw0 = mem[FL + 0xEF] | mem[FL + 0xF0] << 8
    r.run(40)
    yw = ((mem[FL + 0xEF] | mem[FL + 0xF0] << 8) - yw0) & 0x1FFF
    rx, dx = mem[FL + 0xF8], mem[FL + 0xE1]
    r.key('r')
    r.run(2 * gen_scrap.NAV_SPIN)
    print('  the spin carried: yaw rate %d, pitch rate %d; 40 frames on: yaw +x%04X, the ring %d (the side %d);'
          ' R: rates %d %d' % (yr, pr, yw, rx, dx, mem[FL + 0xEE], mem[FL + 0xF1]))
    if (yr != 16 or pr not in (8, 248) or not 0x200 <= yw <= 0x300 or rx == (dx >> 1)
            or mem[FL + 0xEE] or mem[FL + 0xF1]):
        r.fail('turning on the docking screen')
    mem[FL + 0xEF:FL + 0xF4] = bytes(5)     # lined up again
    r.run(8)
    if mem[FL + 0x22]:
        r.fail('the heading after the yaw went to 0: %d' % mem[FL + 0x22])
    mem[FL + 0xD4:FL + 0xDC] = bytes(8)     # level with the port
    for key, want in (('4', 'NOT CLEARED'), ('2', 'HAIL THE KESTREL 9 FIRST'), ('1', 'NO REPLY'),
                      ('2', 'DOCKING DECLARED')):
        r.key(key)
        r.run(4)
        print('  %s: %r' % (key, r.panel()[5].strip()))
        if want not in r.panel()[5] or mem[FL + 0x21]:
            r.fail('by the port, %s: %r' % (key, r.panel()[5]))
    fl_put(mem, 0x64, 4, (gen_scrap.DOCK_POS[1] + 3) << 16)     # 3 m off to the side
    fl_put(mem, 0x6C, 4, 0)
    r.run(8)
    ring = [mem[FL + k] for k in range(0xE4, 0xE8)]
    r.key('4')
    r.run(4)
    print('  3 m off: the port\'s ring %s; 4: %r' % (ring, r.panel()[5].strip()))
    if (mem[FL + 0x21] or 'CLAMPS MISSED' not in r.panel()[5] or mem[FL + 0xE3]
            or ring[:3] != [1, 80 - 24, 104] or ring[3] != 960 // (4 + 16)):
        r.fail('a clamp 3 m off: %s %r' % (ring, r.panel()[5]))
    fl_put(mem, 0x64, 4, gen_scrap.DOCK_POS[1] << 16)
    fl_put(mem, 0x6C, 4, 0)
    mem[FL + 0xD4:FL + 0xDC] = bytes(8)
    if not r.wait_for(lambda: mem[FL + 0xE3] == 1, 30, 'clear to clamp'):
        print('  the docking state: %s, v %d %d' % (bytes(mem[FL + 0xD0:FL + 0xE8]).hex(), fl_get(mem, 0x68, 4),
                                                     fl_get(mem, 0x6C, 4)))
        return
    flash = set()
    for _ in range(40):
        r.run(1)
        t = r.text(22)
        if 'CLEAR TO CLAMP' in t.upper():
            flash.add(t.strip())
    print('  clear to clamp: %s' % sorted(flash))
    if len(flash) != 2:
        r.fail('CLEAR TO CLAMP does not flash: %s' % flash)
    r.mouse_to(60 * 8 + 4, 13 * 16 + 8)     # the mouse on 4 CLAMP (its blank end)
    r.run(20)
    if mem[FL + 0xD2] != 3 or ' 4  CLAMP' not in r.text(13).upper():
        r.fail('the mouse over 4: %d %r' % (mem[FL + 0xD2], r.text(13)))
    r.click(1)
    r.run(20)
    print('  a click on 4: %r; locks %s %s; |%s' % (r.panel()[5].strip(), gen_scrap.TYPES[r.map_t(29, 32)][0],
                                                   gen_scrap.TYPES[r.map_t(30, 32)][0], r.text(4).strip()))
    if (mem[FL + 0x21] != 1 or 'CLAMPS ON' not in r.panel()[5] or 'CLAMPED TO PORT 1' not in r.text(4)
            or r.map_t(29, 32) != T['LOCK'] or r.map_t(30, 32) != T['LOCK'] or fl_get(mem, 0x68, 4)):
        r.fail('docking')
    if not dock_close(r):
        return
    r.port.kbd.press(r.codes['\x1b'])
    r.run(10)
    r.port.kbd.release(r.codes['\x1b'])
    if not r.run_until(lambda: cpu.pc == r.tsyms['loop'] and not mem[FL + 0x20], 300, 'the ship again'):
        return
    r.settle()
    r.check_view('docked again')
    r.check_rooms('docked again')
    r.click(2)
    r.go((24, 32), (24, 33))


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
    r.go((24, 33))
    tank = (23, 33)
    dmg = r.map_raw(*tank)[1] & 15
    if not dmg:
        r.fail('the tank has no damage to repair')
    elif r.act(*tank, gen_scrap.A_REPAIR):
        r.check_job('REPAIR (no suit)', gen_scrap.REPAIR_FRAMES * dmg, T['O2'])
        print('  %r: damage %d -> %d' % (r.panel()[5].strip(), dmg, r.map_raw(*tank)[1] & 15))
        if r.map_raw(*tank)[1] & 15:
            r.fail('REPAIR left damage')
    partial_repair(r)
    pump_intake(r)
    jammed_door(r)
    deck_rules(r)
    power(r, r.args)
    comms(r)
    navigation(r)
    q = r.room(z('p_x'), z('p_y'))
    saved = bytes(mem[0x4000:0x4020])
    for _ in range(140):                           # the room's air gone
        mem[0x4000 + q] = 0
        r.run(1)
        if z('stage') == 4 and 'BLACKING OUT' in r.panel()[5]:
            break
    print('  no air, no suit: stage %d, %r, O2 %d' % (z('stage'), r.panel()[5].strip(), z('o2')))
    if z('stage') != 4 or 'BLACKING OUT' not in r.panel()[5]:
        r.fail('no air without the suit is not blacking out')
    mem[0x4000:0x4020] = saved                     # and back
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
