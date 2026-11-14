#!/usr/bin/env python3
"""
test_skyward_sim.py - run SKYWARD TOBI (gen_skyward.py) in placard_sim from a card

    python3 test_skyward_sim.py                   plays every course with a bot
    python3 test_skyward_sim.py --course 3        starts at course 3 (pokes the
                                                  course number before the title's
                                                  key press)
    python3 test_skyward_sim.py --shots DIR       a PNG at the start of every
                                                  course, and some on the way
    python3 test_skyward_sim.py --stop-after 4    stops when course 4 loads
    python3 test_skyward_sim.py --stomp           the bot lands on every enemy it
                                                  can (shells, hits, power-ups)
    python3 test_skyward_sim.py --course 1 --lives 1 --walk --stop-after 0
                                                  the last life lost: the title
                                                  comes back

The 32K ROM boots from a card with BOOT.CFG = SKYWARD.PLC and the SKYWARD
folder.  A bot plays through pad 1: it presses B at the title and the
course cards, runs right, and jumps at gaps, walls and enemies (it reads
the course from gen_skyward and the player from the zero page), holding B
in the air to glide and throwing embers (pad Y) when it has the Ember
Pepper.  For every frame the test checks:
  - the background: after the bands and the course are drawn, every byte
    of the 160 x 112 playfield matches gen_skyward's model for the scroll
  - the sprites: after the blitter, the playfield matches the background
    with the sprite list drawn over it by the model
  - the beam: the background is finished before the beam reaches the
    course's first row
and at the end that the bot cleared every course and the ending came up,
that the strips in the video RAM are unchanged and that Esc brings the DOS
back.

Date: 11/14/2026
"""

import argparse
import copy
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import gen_skyward as sk  # noqa: E402
import test_dos            # noqa: E402

FRAME = 525 * 800
FIRST_LINE = 45
B, Y, LEFT, RIGHT = 0x0001, 0x0002, 0x0040, 0x0080      # pad 1's buttons


def bot(cs, st, held):
    """the pad for the next frame: run right; jump at gaps, walls and
    enemies; hold B in the air to glide; go for Baron Rook when he is near"""
    px, py = st['px'], st['py']
    if st['mode'] == 1:
        return 0 if held else B
    if st['mode'] != 0:
        return 0
    boss = [e for e in st['en'] if e['alive'] and e['kind'] & 1 and abs(e['x'] - px) < 72]
    if boss:
        d = boss[0]['x'] + 4 - px
        btn = RIGHT if d > 0 else LEFT
        if st['onground'] and 14 <= abs(d) <= 34 and not held:
            btn |= B
        return btn
    btn = RIGHT
    feet = py + 16
    if st['power'] == 2 and not st['emb'] and not st['fprev'] and not st['facing']:
        # the Ember Pepper: an ember at whatever is ahead at Tobi's height
        if any(e['alive'] and not e['kind'] & 0x13 and 10 <= e['x'] - px <= 44 and abs(e['g'] - py) <= 10
               for e in st['en']):
            btn |= Y
    if st['onground']:
        want = False
        if not any(cs.solid_at(px + 7, feet + 16 * k) for k in range(3)):
            want = True
        if st['attr'](px + 7, feet) & sk.A_THORN and not st['geta']:
            want = True         # thorns: as a gap
        if cs.solid_at(px + 9, py + 8) or cs.solid_at(px + 9, py + 15):
            want = True
        for e in st['en']:
            if not e['alive'] or e['kind'] & 0x12:
                continue
            d = e['x'] - px
            if 6 <= d <= 22 and -40 <= e['g'] - py <= 20:
                want = True
        if any(st['attr'](px + 3, py + 8 - 16 * k) & sk.A_CRATE for k in (1, 2, 3)):
            want = True         # a crate overhead
        if want:
            btn |= 0 if held else B
    elif st['glider']:
        # glide over a gap; let go above ground, to land on it
        if not any(cs.solid_at(px + dx, feet + 16 * k) for k in range(6) for dx in (1, 6)):
            btn |= B
        elif any(e['alive'] and not e['kind'] & 0x12 and -10 <= e['x'] - px <= 30 and e['g'] > py
                 for e in st['en']):
            btn |= B            # and over an enemy underneath
    elif held:
        btn |= B
    return btn


class Model:
    """the game's rules in Python (as skyward.asm has them), for the bot's look ahead"""
    def __init__(self, cs):
        self.cs = cs
        self.px = cs.start; self.py = 0; self.pyl = 0; self.vy = 0; self.onground = 0
        self.chk = cs.start; self.inv = sk.INV_FRAMES; self.mode = 1; self.lives = 3
        self.jprev = 0; self.frame = 0; self.medals = 0; self.deaths = []
        self.en = [dict(x=o['x'], g=o['g'], lo=o['lo'], hi=o['hi'], dir=0, alive=1, kind=sk.KIND[o['ch']], hp=sk.HP.get(o['ch'], 3)) for o in cs.objs]
        self.got = [0] * len(cs.medals)
        self.clear = False
        self.power = 0; self.geta = 0; self.glider = cs.c['glider']
        self.used = set()       # (tile column, tile row) of the crates taken
        self.frame0 = 0
        self.facing = 0; self.fprev = 0
        self.emb = 0; self.emx = 0; self.emg = 0; self.emd = 0     # the ember: frames left, where, direction

    def clone(self):
        m = copy.copy(self)
        m.en = [dict(e) for e in self.en]
        m.got = list(self.got); m.deaths = list(self.deaths); m.used = set(self.used)
        return m

    def state(self):
        return dict(px=self.px, py=self.py, mode=self.mode, onground=self.onground, en=self.en,
                    frame=self.frame, geta=self.geta, glider=self.glider, attr=self.attr,
                    power=self.power, emb=self.emb, fprev=self.fprev, facing=self.facing)

    def attr(self, x, g):
        tr = self.cs.cell_tr(x, g)
        if tr is None:
            return 0
        return 1 if tr in self.used else self.cs.attr_t(*tr)

    def die(self, why):
        self.deaths.append((self.frame, self.px, self.py, why))
        self.lives -= 1
        self.power = self.geta = 0; self.glider = self.cs.c['glider']
        self.px = self.chk; self.py = 0; self.pyl = 0; self.vy = 0; self.onground = 0; self.inv = sk.INV_FRAMES

    def hurt(self, why):
        if self.geta:
            self.geta = 0
        elif self.power:
            self.power = 0; self.glider = self.cs.c['glider']
        else:
            return self.die(why)
        self.inv = sk.INV_FRAMES

    def step(self, btn):
        cs = self.cs
        s = lambda x, g: self.attr(x, g) & 1
        self.frame = (self.frame + 1) & 255
        jnow = btn & B
        inp = btn
        if self.mode == 1:
            if jnow and not self.jprev:
                self.mode = 0
            inp = 0
        if inp & RIGHT:
            self.facing = 0
            if not (s(self.px + 8, self.py + 1) or s(self.px + 8, self.py + 8) or s(self.px + 8, self.py + 15)):
                self.px = (self.px + 1) & 1023
        elif inp & LEFT:
            self.facing = 1
            if not (s(self.px - 1, self.py + 1) or s(self.px - 1, self.py + 8) or s(self.px - 1, self.py + 15)):
                self.px = (self.px - 1) & 1023
        if self.attr(self.px + 4, self.py + 8) & sk.A_UP:
            self.vy = -sk.UPV - sk.GRAV
        if (inp & B) and not self.jprev and self.onground and self.mode == 0:
            self.vy = -sk.JUMPV
        self.vy += sk.GRAV
        if self.vy >= 0:
            if self.glider and (inp & B) and not self.onground:
                if self.vy >= sk.GLIDE:
                    self.vy = sk.GLIDE
            if self.vy >= sk.MAXFALL:
                self.vy = sk.MAXFALL
        y = self.py * 256 + self.pyl + self.vy
        if self.vy < 0:
            if y < 0:
                self.py = self.pyl = 0; self.vy = 0
            else:
                self.py, self.pyl = y >> 8, y & 255
                at = self.attr(self.px + 1, self.py)
                xx = self.px + 1
                if not at & 1:
                    at = self.attr(self.px + 6, self.py); xx = self.px + 6
                if at & 1:
                    if at & sk.A_CRATE:
                        self.used.add(cs.cell_tr(xx, self.py))
                        p = at >> 5
                        if p == 3:
                            self.geta = 1
                        else:
                            self.power = p + 1
                            self.glider = 1 if p == 2 else cs.c['glider']
                    self.py = ((self.py - 32) & 0xF0) + 48; self.pyl = 0; self.vy = 0
                self.onground = 0
        else:
            self.py, self.pyl = y >> 8, y & 255
            if self.py >= sk.DROWN_G:
                self.die('fell')
            else:
                at = self.attr(self.px + 1, self.py + 16)
                if not at & 1:
                    at = self.attr(self.px + 6, self.py + 16)
                if at & 1:
                    top = ((self.py + 16 - 32) & 0xF0) + 16
                    if at & sk.A_BOUNCE:
                        self.py = top; self.pyl = 0; self.onground = 0; self.vy = -sk.BOUNCEV
                    elif at & sk.A_THORN and not self.geta and not self.inv:
                        self.hurt('thorns')
                    else:
                        self.py = top; self.pyl = 0; self.vy = 0
                        self.onground = 1; self.chk = self.px
                else:
                    self.onground = 0
                    for e in self.en:
                        if e['kind'] & sk.K_LIFT and ((e['x'] + 6 - self.px) & 1023) < 13 \
                                and ((self.py + 16 - e['g']) & 255) < 8:
                            self.py = e['g'] - 16; self.pyl = 0; self.vy = 0; self.onground = 1
                            if self.frame & 1:
                                self.px = (self.px + (-1 if e['dir'] else 1)) & 1023
                            break
        if self.inv:
            self.inv -= 1
        if self.mode == 0 and self.px >= cs.goal:
            self.clear = True
        for i, (cx, cg) in enumerate(cs.medals):
            if not self.got[i] and -3 <= cx - self.px <= 6 and -7 <= cg - self.py <= 15:
                self.got[i] = 1; self.medals += 1
        fire = inp & Y
        if fire and not self.fprev and self.mode == 0 and self.power == 2 and not self.emb:
            self.emb = sk.EMBER_LIFE; self.emx = self.px; self.emg = self.py; self.emd = self.facing
        self.fprev = fire
        if self.emb:
            self.emb -= 1
            self.emx = (self.emx + (-2 if self.emd else 2)) & 1023
            if s(self.emx + 4, self.emg + 8):
                self.emb = 0
        for e in self.en:
            if not e['alive']:
                continue
            k = e['kind']
            shell = e['hp'] if k & sk.K_SHELL else 3
            if shell == 1:      # sliding
                if e['x'] in (e['lo'], e['hi']):
                    e['alive'] = 0
                    continue
                for o in self.en:
                    if o is not e and o['alive'] and not o['kind'] & 0x13 and o['g'] == e['g'] \
                            and ((o['x'] + 6 - e['x']) & 1023) < 13:
                        o['alive'] = 0
            if shell != 2 and not k & (sk.K_PIC | sk.K_SNAP) and (k & sk.K_FAST or shell == 1 or self.frame & 1):
                if e['dir'] == 0:
                    e['x'] = (e['x'] + 1) & 1023
                    if e['x'] == e['hi']: e['dir'] = 1
                else:
                    e['x'] = (e['x'] - 1) & 1023
                    if e['x'] == e['lo']: e['dir'] = 0
            if k & sk.K_SNAP and not self.frame & 0x40:
                continue
            if ((e['x'] - self.px + sk.SCREEN_X + 8) & 1023) >= 88:
                continue        # off the screen
            if self.emb and not k & 0x13 and ((e['x'] - self.emx + 6) & 255) < 13 \
                    and ((e['g'] - self.emg + 12) & 255) < 25:
                e['alive'] = 0; self.emb = 0
                continue
            if self.mode or self.inv or k & (sk.K_PIC | sk.K_LIFT):
                continue
            dx, dy = e['x'] - self.px, e['g'] - self.py
            hit = (-14 <= dx <= 5 and -30 <= dy <= 14) if k & 1 else (-6 <= dx <= 6 and -14 <= dy <= 14)
            if hit and k & sk.K_SHELL:
                if shell == 2:
                    e['hp'] = 1; e['dir'] = 0 if dx >= 0 else 1; self.inv = sk.ROOK_SAFE
                elif self.vy >= 0 and dy >= 8:
                    e['hp'] = 2; self.vy = -0x300
                else:
                    self.hurt('shell at %d' % e['x'])
            elif hit:
                if (not k & sk.K_SPIKE or self.geta) and self.vy >= 0 and dy >= 8:
                    self.vy = -0x300
                    if k & 1:
                        e['hp'] -= 1
                        self.inv = sk.ROOK_SAFE
                        if e['hp'] == 0:
                            e['alive'] = 0; self.clear = True
                    else:
                        e['alive'] = 0
                else:
                    self.hurt('enemy at %d' % e['x'])
        self.jprev = jnow


STOMP = False      # --stomp: the bot goes for every enemy it can land on


def rollout(m, first, held, horizon, hold=1):
    """(frames survived (horizon if no life lost), Rook's hits left) with the
    pad at first for hold frames, and the simple bot's choices after that"""
    m = m.clone()
    n0 = len(m.deaths)
    btn = first
    t = horizon
    for k in range(horizon):
        m.step(btn)
        if len(m.deaths) > n0:
            t = k
            break
        if m.clear:
            break
        held = bool(btn & B)
        btn = first if k + 1 < hold else bot(m.cs, m.state(), held)
    left = sum(e['hp'] for e in m.en if e['kind'] & 1 and e['alive'])
    if STOMP:       # every enemy counts: a walking Shellby 3, its shell 2, sliding 1
        left += sum((e['hp'] if e['kind'] & sk.K_SHELL else 1) for e in m.en
                    if e['alive'] and not e['kind'] & 0x1B) + 4 * (3 - m.lives) - m.power
    return t, left


COMMIT = [0, 0]     # plan()'s pad for the next frames: [buttons, frames left]


def plan(m, held, horizon=150):
    """the pad for the next frame: the simple bot's choice, unless it loses
    a life within the horizon and another choice does not; with Baron Rook
    near, the choice that lands on him soonest"""
    st = m.state()
    first = bot(m.cs, st, held)
    if st['mode'] != 0:
        COMMIT[1] = 0
        return first
    if COMMIT[1]:       # a pad held for some frames (below), while it still works
        if rollout(m, COMMIT[0], held, horizon, COMMIT[1])[0] >= horizon:
            COMMIT[1] -= 1
            return COMMIT[0]
        COMMIT[1] = 0
    fight = any(e['alive'] and e['kind'] & 1 and abs(e['x'] - m.px) < 72 for e in m.en)
    if STOMP and any(e['alive'] and not e['kind'] & 0x1B and abs(e['x'] - m.px) < 48 for e in m.en):
        fight = True
    best = None
    opts = [first, RIGHT, RIGHT | B, 0, B, LEFT, LEFT | B]
    if st['onground'] and held:     # B still down from the last jump: let it go, or
        opts = [first, RIGHT, 0, LEFT]      # there is never a new press
    for btn in opts:
        t, hp = rollout(m, btn, held, horizon)
        if t >= horizon and not fight:
            return btn
        if best is None and t > 60 and not fight and not st['glider']:
            return btn      # trouble that far off is dealt with nearer to it
        key = (t, -hp)
        if best is None or key > best[0]:
            best = (key, btn)
    if not fight:       # every choice loses a life: a shorter jump (in the air,
        m2, h2 = m, held        # the same pad for longer), also for a jump from here
        if st['onground'] and first & B:
            m2 = m.clone()
            m2.step(first)
            h2 = True
        if not m2.onground:
            for hold in (6, 16, 30):
                for btn in (0, B, LEFT):
                    if rollout(m2, btn, h2, horizon, hold)[0] >= horizon:
                        if m2 is not m:
                            COMMIT[:] = [btn, hold]
                            return first
                        COMMIT[:] = [btn, hold - 1]
                        return btn
    return best[1]


def used_crates(cs, mem):
    """{(tile column, tile row)} of the crates taken, from the tile map in the RAM"""
    lv = [sk.PAGES['LVA'], sk.PAGES['LVA'] + 128, sk.PAGES['LVB'], sk.PAGES['LVB'] + 128, sk.PAGES['LVC']]
    return set((t, r) for r, t in cs.crates if mem[lv[r] + t] == 8 * cs.cid[(r, 'X')])


def model_of(cs, mem, z):
    """a Model in the state the program is in (read from its RAM)"""
    m = Model(cs)
    m.px = mem[z['pxl']] | mem[z['pxh']] << 8
    m.py, m.pyl = mem[z['pyh']], mem[z['pyl']]
    vy = mem[z['vyl']] | mem[z['vyh']] << 8
    m.vy = vy - 65536 if vy & 0x8000 else vy
    m.onground = mem[z['onground']]
    m.chk = mem[z['chk_lo']] | mem[z['chk_hi']] << 8
    m.inv = mem[z['inv']]
    m.mode = mem[z['mode']]
    m.jprev = mem[z['jprev']]
    m.frame = (mem[0x08] - 1) & 255     # (step() counts it first)
    e = sk.ENEMY
    for i, en in enumerate(m.en):
        en.update(x=mem[e + i] | mem[e + 8 + i] << 8, dir=mem[e + 0x18 + i], alive=mem[e + 0x40 + i],
                  hp=mem[e + 0x58 + i])
    m.power, m.geta, m.glider = mem[e + 0x68], mem[e + 0x69], mem[z['glider']]
    m.used = used_crates(cs, mem)
    m.facing = 1 if mem[z['facing']] else 0
    m.emb, m.emx, m.emg = mem[e + 0x6A], mem[e + 0x6B] | mem[e + 0x73] << 8, mem[e + 0x6D]
    m.emd, m.fprev = (1 if mem[e + 0x6E] else 0), mem[e + 0x6F]
    return m


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--course', type=int, default=0)
    ap.add_argument('--max-frames', type=int, default=40000)
    ap.add_argument('--shots')
    ap.add_argument('--shot-every', type=int, default=0)
    ap.add_argument('--fast', action='store_true', help='skip the idle wait for the next frame')
    ap.add_argument('--walk', action='store_true', help='the bot only walks right (to lose a life)')
    ap.add_argument('--stomp', action='store_true', help='the bot lands on every enemy it can')
    ap.add_argument('--lives', type=int, default=0,
                    help='with --course: start that course with this many lives')
    ap.add_argument('--stop-after', type=int, default=sk.NCOURSE - 1,
                    help='stop when this course has come up')
    args = ap.parse_args(argv)
    global STOMP
    STOMP = args.stomp

    plc, files, z, info = sk.sd_files()
    rig = test_dos.boot_plc('SKYWARD.PLC', plc, z['main'], files)
    if rig is None:
        return 1
    cpu, mem = rig.cpu, rig.cpu.mem
    pad = rig.port.pads[0]
    print('started at frame %d' % (cpu.clocks // FRAME))
    courses = [ci['course'] for ci in info['courses']]
    ok = True
    frames = 0
    cur = None
    t0 = 0
    worst_bg = 0
    pics = {}                   # story picture: [(address, byte)]
    heard = [0, 0]              # frames of a course with the song in the sound buffer, frames
    held = False
    seen = []
    deaths = 0
    lives_last = 3
    stuck = 0
    last_px = None
    pred = None
    drift = 0
    wait = 0
    if args.shots:
        os.makedirs(args.shots, exist_ok=True)

    def shot(name):
        if args.shots:
            ps.render(mem, os.path.join(args.shots, name + '.png'))

    stops = {z['frame_go']: 'go', z['drawn_bg']: 'bg', z['drawn_all']: 'all', z['f_wait']: 'wait',
             z['lc_5']: 'loaded'}
    def check_sprites():
        nonlocal ok
        heard[1] += 1
        heard[0] += any(mem[a] != 0x80 for a in range(0x5DF3, 0x6000))
        want = cs.background(scroll, used_crates(cs, mem))
        model = bytearray(65536)
        for a, v in want.items():
            model[a] = v
        n = mem[z['sl_n']]
        ad2id = {}
        for fi, (nm, _) in enumerate(cs.frames):
            ad = mem[sk.PAGES['FR'] + fi] | mem[sk.PAGES['FR'] + sk.FR_HI + fi] << 8
            ad2id.setdefault(ad, fi)
        lst = []
        for i in range(n):
            ad = mem[z['SL_LO'] + i] | mem[z['SL_HI'] + i] << 8
            lst.append((ad2id[ad], mem[z['SL_C'] + i], mem[z['SL_G'] + i]))
        sk.draw_sprites_model(model, lst, cs.frames)
        bad = [a for a in want if mem[a] != model[a]]
        if bad:
            a = bad[0]
            print('frame %d: sprites, %d bytes differ, first %04X: %02X, model %02X (list %s)'
                  % (frames, len(bad), a, mem[a], model[a], lst))
            ok = False

    poked = False
    while frames < args.max_frames:
        cpu.step()
        what = stops.get(cpu.pc)
        if what is None or (cpu.map & 0x07) != 0x07:
            continue
        if what == 'wait':
            if args.fast:
                nxt = (cpu.clocks // FRAME + 1) * FRAME - 600
                if cpu.clocks < nxt:
                    cpu.clocks = nxt
            continue
        if what == 'loaded':
            cur = mem[z['course']]
            seen.append(cur)
            print('frame %5d: course %d (%s) loaded, score %d, medals %d, lives %d'
                  % (frames, cur, courses[cur].c['name'], mem[z['score_lo']] | mem[z['score_hi']] << 8,
                     mem[z['coins']], mem[z['lives']]))
            new = True
            if args.lives and cur == args.course and len(seen) == 2:
                mem[z['lives']] = args.lives
                lives_last = args.lives
            if cur == args.stop_after and len(seen) > 1:
                # let it draw a few frames, then stop
                args.max_frames = min(args.max_frames, frames + 20)
            continue
        if cur is None:
            continue
        cs = courses[cur]
        t = cpu.clocks
        if what == 'go':
            t0 = (t // FRAME) * FRAME
            continue
        scroll = mem[z['scl']] | mem[z['sch']] << 8
        if what == 'bg':
            dt = t - t0
            limit = (FIRST_LINE + 32 + 4 * sk.GROUND_G) * 800
            worst_bg = max(worst_bg, dt / limit)
            want = cs.background(scroll, used_crates(cs, mem))
            bad = [a for a, v in want.items() if mem[a] != v]
            if bad:
                a = bad[0]
                print('frame %d: background, %d bytes differ, first %04X: %02X, model %02X'
                      % (frames, len(bad), a, mem[a], want[a]))
                ok = False
            continue
        # all drawn
        frames += 1
        if cs.c.get('pic'):
            # a story picture: the loader drew it, nothing is drawn after
            key = cs.c['pic']
            if key not in pics:
                pix = sk.story_pixels(key)
                pics[key] = [(0x6100 + 512 * c + sk.row_x(g), pix[(2 * c, g)] | pix[(2 * c + 1, g)] << 4)
                             for c in range(sk.NCOL) for g in range(sk.NROW)]
            bad = [a for a, v in pics[key] if mem[a] != v]
            if bad:
                print('frame %d: story picture %s, %d bytes differ' % (frames, cs.c['pic'], len(bad)))
                ok = False
        else:
            check_sprites()
        if new and frames > 2:
            new = False
            shot('course%d_start' % cur)
        if args.shot_every and frames % args.shot_every == 0:
            shot('f%05d' % frames)
        # ---- the bot: the pad for the next frame
        mode = mem[z['mode']]
        px = mem[z['pxl']] | mem[z['pxh']] << 8
        py = mem[z['pyh']]
        onground = mem[z['onground']]
        lives = mem[z['lives']]
        if lives < lives_last:
            deaths += 1
            print('frame %5d: a life lost at x %d (tile %d), y %d' % (frames, px, px // 8, py))
            shot('death%d_course%d' % (deaths, cur))
        lives_last = lives
        if not poked and args.course and cur == 0:
            mem[z['course']] = args.course - 1
            poked = True
        btn = 0
        if mode != 0:
            pred = None
        if mode == 1:
            wait += 1
            btn = B if wait > (60 if cs.c['kind'] else 20) and not held else 0
        elif mode == 0:
            wait = 0
            m = model_of(cs, mem, z)
            if pred is not None and pred != (m.px, m.py, m.pyl):
                drift += 1
                if drift <= 5:
                    print('frame %d: the model said x, y %s, the program has %s' % (frames, pred, (m.px, m.py, m.pyl)))
            btn = RIGHT if args.walk else plan(m, held)
            m.step(btn)
            pred = (m.px, m.py, m.pyl) if m.mode == 0 and not m.clear else None
            if last_px == px:
                stuck += 1
                if stuck > 900:
                    print('frame %d: the bot is stuck at x %d (tile %d)' % (frames, px, px // 8))
                    shot('stuck_course%d' % cur)
                    ok = False
                    break
            else:
                stuck = 0
            last_px = px
        held = bool(btn & B)
        pad.buttons = btn
    if drift:
        print('FAIL: the model and the program disagreed on %d frames' % drift)
        ok = False
    print('music: the song in the sound buffer in %d of %d frames of the courses' % tuple(heard))
    if heard[1] > 100 and heard[0] < heard[1] * 3 // 4:
        print('FAIL: no music')
        ok = False
    print('%d frames; courses seen %s; lives lost %d; background done at %d %% of the beam\'s time'
          % (frames, seen, deaths, 100 * worst_bg))
    shot('last')
    if args.course == 0 and args.stop_after == sk.NCOURSE - 1 and seen[:sk.NCOURSE] != list(range(sk.NCOURSE)):
        print('FAIL: the bot did not get through the courses in order')
        ok = False
    if worst_bg > 0.9:
        print('FAIL: the drawing is not ahead of the beam')
        ok = False
    ci = info['courses'][cur]
    bad = [a for a, v in ci['image'].items() if mem[a] != v]
    if bad:
        print('FAIL: %d bytes of the strips changed, first x%04X' % (len(bad), bad[0]))
        ok = False
    pad.buttons = 0
    if not test_dos.esc_to_dos(rig):
        ok = False
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
