#!/usr/bin/env python3
"""
test_lamp_sim.py - play LAMPLIGHTER (gen_lamp.py) in placard_sim from a card

    python3 test_lamp_sim.py                 the bot walks the route below
    python3 test_lamp_sim.py --shots DIR     a PNG in every room, and some on the way
    python3 test_lamp_sim.py --goals 2       only the first 2 goals of the route
    python3 test_lamp_sim.py --route "[('kill', 0, 0)]"     another route

The 32K ROM boots from a card with BOOT.CFG = LAMP.PLC and the LAMP folder.
A bot plays through pad 1.  It plans each leg of its route with
gen_lamp's Python model of the rules (a search over the model: which
buttons, 4 frames at a time, reach the next room or place), so the model
and the program are compared on every frame too.  For every frame the
test checks:
  - the rules: the hero, his energy and power-ups, the camera, the shots,
    the door, the room and its creatures and items are what the model says
  - the background: after the tile rows are drawn, every byte of the
    160 x 112 playfield matches the model's picture of the tile map
  - the sprites: after the blitter, the playfield matches that with the
    model's sprite list drawn over it
  - the beam: each tile row is drawn after the beam has passed it, and
    each sprite is finished before the beam is back at its first row
and at the end that the bot got through its route, that the tile and
sprite routines in the video RAM are unchanged and that Esc brings the
DOS back.

Date: 11/13/2026
"""

import argparse
import heapq
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps  # noqa: E402
import gen_lamp as gl     # noqa: E402
import test_dos            # noqa: E402

FRAME = 525 * 800
FIRST_LINE = 45
GO_CLOCK = (gl.LINE_GO * 4 - 499) * 800         # the frame's clock where the drawing may start
TOP_CLOCK = (FIRST_LINE + 32) * 800             # the beam at the playfield's first row
B, Y, UP, DOWN, LEFT, RIGHT = gl.PAD_B, gl.PAD_Y, gl.PAD_UP, gl.PAD_DOWN, gl.PAD_LEFT, gl.PAD_RIGHT
ACTIONS = [RIGHT, LEFT, RIGHT | B, LEFT | B, B, 0, RIGHT | DOWN, LEFT | DOWN, Y, RIGHT | Y, LEFT | Y, UP | Y]
HOLD = 4

# the route: ('room', n) get into room n; ('at', n, tx, ty) stand in tile (tx, ty) of room n;
# ('item', n, i) take thing i of room n; ('kill', n, i) shoot creature i of room n;
# ('dead', n, i) let creature i of room n hurt Wick until his energy is gone;
# ('fight', n, i) the boss, thing i of room n: keep away, jump its low bolts, fire
ROUTE = [('dead', 0, 0), ('kill', 0, 0), ('room', 1), ('room', 3), ('room', 4), ('kill', 4, 2), ('item', 4, 0),
         ('room', 6), ('room', 7), ('room', 8), ('item', 8, 0), ('room', 7), ('room', 9), ('kill', 9, 0),
         ('room', 10), ('item', 10, 0), ('room', 9), ('room', 7), ('room', 11), ('room', 12), ('room', 13),
         ('fight', 13, 0), ('item', 13, 0), ('room', 12), ('room', 11), ('at', 11, 4, 1), ('room', 7),
         ('at', 7, 6, 12), ('at', 7, 2, 8), ('at', 7, 6, 3), ('room', 6), ('room', 4),
         ('room', 3), ('at', 3, 4, 1), ('room', 1), ('room', 2), ('item', 2, 0), ('room', 1), ('room', 0)]


def target(m, goal):
    """the place (byte column, cell) the goal is at, in the room the model is in"""
    if goal[0] == 'at' and m.room == goal[1]:
        return goal[2] * 8, goal[3] * 16
    if goal[0] in ('item', 'kill', 'dead', 'fight') and m.room == goal[1]:
        return m.objs[goal[2]][1], m.objs[goal[2]][2]
    want = goal[1]
    for side, lo, hi, dest, delta in m.rm.exits:
        if dest == want:
            mid = (lo + hi + 1) / 2
            return {gl.EX_L: (0, mid * 16 - 8), gl.EX_R: (m.rm.rwx, mid * 16 - 8), gl.EX_U: (mid * 8 - 4, 0),
                    gl.EX_D: (mid * 8 - 4, m.rm.rhy)}[side]
    raise ValueError('room %d has no exit to room %d' % (m.room, want))


def reached(m, goal):
    if goal[0] == 'room':
        return m.room == goal[1] and m.onground
    if goal[0] == 'item':
        return m.room == goal[1] and m.onground and not m.objs[goal[2]][0]
    if goal[0] == 'dead':
        return m.msg == len(gl.ITEM_MSG) + 1 and m.msg_t > gl.MSG_FRAMES - 8
    if goal[0] in ('kill', 'fight'):
        return m.room == goal[1] and m.onground and m.beh(m.objs[goal[2]]) < gl.B_WALK
    return (m.room == goal[1] and m.onground and (m.px + 4) >> 3 == goal[2]
            and (m.py + 15) >> 4 == goal[3])


def plan(m0, goal, max_nodes=400000, unhurt=True):
    """the pad buttons, frame by frame, that take the model from m0 to the
    goal: A* over the model, HOLD frames an action.  unhurt: only ways
    that cost no energy"""
    room0 = m0.room
    tx, ty = target(m0, goal)
    kill = goal[0] == 'kill' and m0.room == goal[1]
    if goal[0] == 'fight':
        return fight(m0, goal)
    dead = goal[0] == 'dead'
    if dead:            # no search: walk and hop into the creature until the energy is gone
        c, out = m0.clone(), []
        while not reached(c, goal) and len(out) < 2000:
            o = c.objs[goal[2]]
            b = RIGHT if o[1] > c.px + 2 else (LEFT if o[1] < c.px - 2 else 0)
            if abs(o[1] - c.px) > 24 and (len(out) >> 4) & 1:   # (over what is in the way)
                b |= B
            out.append(b)
            c.step(gl.pad_to_inp(b))
        return out if reached(c, goal) else None

    def h(m):
        if m.room != room0:
            return 0
        if kill:        # anywhere near will do: the shots do the rest
            o = m.objs[goal[2]]
            return max(abs(m.px - o[1]) - 16, 0) / 0.75 + abs(m.py - o[2]) / 4.0
        return max(abs(m.px - tx) / 0.75, abs(m.py - ty) / 4.0)

    def key(m):
        k = (m.room, m.px, m.py, m.vy >> 5, m.onground, m.crawl, m.inp & (gl.IN_JUMP | gl.IN_FIRE),
             m.door_t > 0, tuple(s[0] > 0 for s in m.shots), m.fcnt & 3, m.ajump, m.inv > 0)
        if kill:
            k += (m.objs[goal[2]][1], m.objs[goal[2]][5], m.facing)
        return k

    heap = [(h(m0), 0, 0, m0, None, None)]
    seen = {key(m0)}
    n = 0
    while heap:
        f, g, _, m, parent, act = heapq.heappop(heap)
        node = (parent, act)
        if reached(m, goal):
            out = []
            while node[1] is not None:
                out += [node[1]] * HOLD
                node = node[0]
            return out[::-1]
        if m.room != room0 and m.room != goal[1]:
            continue
        for a in ACTIONS:
            c = m.clone()
            inp = gl.pad_to_inp(a)
            for _ in range(HOLD):
                c.step(inp)
            if c.energy < m.energy and (unhurt or c.energy < 10):
                continue
            k = key(c)
            if k in seen:
                continue
            seen.add(k)
            n += 1
            if n > max_nodes:
                return None
            heapq.heappush(heap, (g + HOLD + 1.5 * h(c), g + HOLD, n, c, node, a))
    return None


def fight(m0, goal):
    """the buttons that beat the boss, by rule: face it from 5 to 9 tiles
    away, jump when a bolt at Wick's height is near, fire all the time"""
    c, out = m0.clone(), []
    while not reached(c, goal) and len(out) < 6000:
        if c.room != goal[1]:
            return None
        o = c.objs[goal[2]]
        b = 0
        if c.beh(o) >= gl.B_WALK:
            away = abs(o[1] + 4 - c.px)
            side = RIGHT if o[1] > c.px else LEFT
            back = LEFT if side == RIGHT else RIGHT
            if c.py > o[2] + 16:        # in a pit: out, away from it
                b = back | (0 if c.inp & gl.IN_JUMP else B)
            elif away < 40:
                b = back
            elif c.facing != (side == LEFT) or (away > 72 and c.solid(c.px + (12 if side == RIGHT else -6),
                                                                      c.py + 16)):
                b = side
            for q in c.objs:
                if (q[0] == gl.S_BOLT and abs(q[1] - c.px) < 14 and (c.py - q[2] + 13) & 255 < 21
                        and c.onground and not c.inp & gl.IN_JUMP):
                    b |= B
            if not c.onground and c.vy < 0:
                b |= B                  # (the whole jump)
            if len(out) & 1 and c.facing == (side == LEFT):
                b |= Y
        out.append(b)
        c.step(gl.pad_to_inp(b))
    return out if reached(c, goal) else None


def replay(m0, btns):
    """the model after the buttons (for the frames a plan cut short)"""
    m = m0.clone()
    for b in btns:
        m.step(gl.pad_to_inp(b))
    return m


def read_state(mem, z):
    vy = mem[z['vyl']] | mem[z['vyh']] << 8
    return dict(room=mem[z['room']], px=mem[z['px']], py=mem[z['py']], pyf=mem[z['pyf']],
                vy=vy - 65536 if vy & 0x8000 else vy, onground=mem[z['onground']], crawl=mem[z['crawl']],
                facing=mem[z['facing']], sx=mem[z['sx']], sy=mem[z['sy']], door=mem[z['door_t']],
                shots=[(mem[z['SH_T'] + i], mem[z['SH_X'] + i], mem[z['SH_Y'] + i]) for i in range(3)],
                energy=mem[z['energy']], emax=mem[z['emax']], items=mem[z['items']], inv=mem[z['inv']],
                ajump=mem[z['ajump']], got=bytes(mem[gl.GOT:gl.GOT + 32]),
                objs=[tuple(mem[gl.OBJ + f + i] for f in (gl.O_KIND, gl.O_X, gl.O_Y, gl.O_D, gl.O_T, gl.O_HP,
                                                          gl.O_P)) if mem[gl.OBJ + i] else None
                      for i in range(gl.MAXOBJ)])


def model_state(m):
    return dict(room=m.room, px=m.px, py=m.py, pyf=m.pyf, vy=m.vy, onground=m.onground, crawl=m.crawl,
                facing=m.facing, sx=m.sx, sy=m.sy, door=m.door_t,
                shots=[(s[0], s[1], s[2]) if s[0] else (0, mem_x, mem_y) for s, (mem_x, mem_y) in
                       zip(m.shots, [(s[1], s[2]) for s in m.shots])],
                energy=m.energy, emax=m.emax, items=m.items, inv=m.inv, ajump=m.ajump, got=bytes(m.got),
                objs=[tuple(o) if o[0] else None for o in m.objs])


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--max-frames', type=int, default=20000)
    ap.add_argument('--goals', type=int, default=len(ROUTE))
    ap.add_argument('--route', help='another route, as a Python list of goals')
    ap.add_argument('--shots')
    ap.add_argument('--shot-every', type=int, default=0)
    ap.add_argument('--slow', action='store_true', help='do not skip the wait for the beam')
    args = ap.parse_args(argv)

    plc, files, z, info = gl.sd_files()
    rig = test_dos.boot_plc('LAMP.PLC', plc, z['main'], files)
    if rig is None:
        return 1
    cpu, mem = rig.cpu, rig.cpu.mem
    pad = rig.port.pads[0]
    print('started at frame %d' % (cpu.clocks // FRAME))
    rooms = info['rooms']
    model = gl.Model(rooms)
    route = (eval(args.route) if args.route else ROUTE)[:args.goals]
    goal_i = 0
    queue = []
    ok = True
    frames = 0
    bad_rules = bad_bg = bad_spr = bad_beam = 0
    worst = 0
    t_go = 0
    drawn = None                # (sprites, map, area) of the frame being drawn
    seen = [model.room]
    if args.shots:
        os.makedirs(args.shots, exist_ok=True)

    def shot(name):
        if args.shots:
            ps.render(mem, os.path.join(args.shots, name + '.png'))

    stops = {z[n]: n for n in ('frame', 'frame_go', 'bg_row', 'row_done', 'bg_done', 'ds_next', 'logic')}
    spare = slack = 999
    in_wait = False
    while frames < args.max_frames:
        cpu.step()
        what = stops.get(cpu.pc)
        if what is None:
            continue
        t = cpu.clocks
        if what == 'frame':
            if cpu.map != 0x07:
                continue
            if in_wait:
                if not args.slow:
                    nxt = (t // FRAME) * FRAME + GO_CLOCK - 300
                    if t % FRAME < GO_CLOCK - 300:
                        cpu.clocks = nxt
                continue
            in_wait = True
            # ---- a frame's rules are done: compare, then the pad for the next
            got, want = read_state(mem, z), model_state(model)
            for i, s in enumerate(want['shots']):
                if not s[0]:
                    want['shots'][i] = got['shots'][i] if not got['shots'][i][0] else s
            if got != want:
                bad_rules += 1
                if bad_rules <= 5:
                    diff = {k: (got[k], want[k]) for k in got if got[k] != want[k]}
                    print('frame %d: the program and the model differ (program, model): %s' % (frames, diff))
            mm = bytes(mem[gl.MAP:gl.MAP + 512])
            if mm != bytes(model.map):
                bad_rules += 1
                if bad_rules <= 5:
                    print('frame %d: the tile map differs from the model\'s' % frames)
            if model.room != seen[-1]:
                seen.append(model.room)
                print('frame %5d: room %d (%s)' % (frames, model.room, model.rm.name))
                shot('room%02X_f%05d' % (model.room, frames))
            drawn = (model.sprites() if frames else [], mm, model.rm.area, model.sx, model.sy)
            while goal_i < len(route) and reached(model, route[goal_i]) and not queue:
                print('frame %5d: goal %d %s reached' % (frames, goal_i, route[goal_i]))
                goal_i += 1
            if goal_i >= len(route):
                break
            if not queue:
                queue = plan(model, route[goal_i]) or plan(model, route[goal_i], unhurt=False)
                if not queue:
                    print('frame %d: the bot found no way to %s from room %d (%d, %d)'
                          % (frames, route[goal_i], model.room, model.px, model.py))
                    shot('stuck')
                    ok = False
                    break
            btn = queue.pop(0)
            pad.buttons = btn
            model.step(gl.pad_to_inp(btn))
            frames += 1
            if args.shot_every and frames % args.shot_every == 0:
                shot('f%05d' % frames)
            continue
        if what == 'frame_go':
            in_wait = False
            t_go = t
            continue
        if cpu.map != 0xFF and what != 'logic':
            continue
        if drawn is None:
            continue
        beam_row = (t % FRAME) // 800 - FIRST_LINE      # the screen row the beam is on (< 0: blanking)
        same = t // FRAME == t_go // FRAME
        if what == 'bg_row':
            g_top = mem[z['rowb']] - 32
            bottom = min(g_top + 16, gl.NROW)
            if same:
                slack = min(slack, beam_row - (32 + 4 * bottom))
            if same and beam_row < 32 + 4 * bottom:
                bad_beam += 1
                if bad_beam <= 5:
                    print('frame %d: tile row at cell %d drawn with the beam on screen row %d' % (frames, g_top, beam_row))
            continue
        if what == 'row_done':
            g_top = max(mem[z['rowb']] - 32, 0)
            if not same and beam_row >= 32 + 4 * g_top:
                bad_beam += 1
                if bad_beam <= 5:
                    print('frame %d: tile row at cell %d still being drawn with the beam on screen row %d'
                          % (frames, g_top, beam_row))
            continue
        sprites, mm, area, sx, sy = drawn
        if what == 'ds_next':
            n = mem[z['s_i']]
            if n and n <= len(sprites):
                first = 32 + 4 * max(sprites[n - 1][2] - 32, 0)     # its first screen row
                if not same:
                    spare = min(spare, first - beam_row)
                    if beam_row >= first:
                        bad_beam += 1
                        if bad_beam <= 5:
                            print('frame %d: sprite %d (rows from %d) done with the beam on screen row %d'
                                  % (frames, n - 1, first, beam_row))
            continue
        want = gl.background(area, mm, sx, sy)
        if what == 'bg_done':
            bad = [a for a, v in want.items() if mem[a] != v]
            if bad:
                bad_bg += 1
                if bad_bg <= 5:
                    a = bad[0]
                    print('frame %d: background, %d bytes differ, first %04X: %02X, model %02X'
                          % (frames, len(bad), a, mem[a], want[a]))
            continue
        # logic: the sprites are drawn
        if cpu.map != 0x07:
            continue
        pic = bytearray(65536)
        for a, v in want.items():
            pic[a] = v
        gl.draw_sprites_model(pic, sprites, area.frames)
        bad = [a for a in want if mem[a] != pic[a]]
        if bad:
            bad_spr += 1
            if bad_spr <= 5:
                a = bad[0]
                print('frame %d: sprites, %d bytes differ, first %04X: %02X, model %02X (list %s)'
                      % (frames, len(bad), a, mem[a], pic[a], sprites))
        dt = t - t_go
        limit = FRAME - GO_CLOCK + TOP_CLOCK
        worst = max(worst, dt / limit)
    print('%d frames; rooms %s; drawing done at %d %% of the time before the beam is back at the playfield'
          % (frames, seen, 100 * worst))
    print('a tile row was drawn at least %d screen rows behind the beam' % slack)
    if spare < 999:
        print('a sprite drawn after that was done at least %d screen rows before the beam reached it' % spare)
    shot('last')
    for name, n in (('rules', bad_rules), ('background', bad_bg), ('sprites', bad_spr), ('beam', bad_beam)):
        if n:
            print('FAIL: %s: %d frames' % (name, n))
            ok = False
    if goal_i < len(route):
        print('FAIL: the bot reached %d of %d goals' % (goal_i, len(route)))
        ok = False
    img = info['areas'][model.rm.r['area']]['image']
    bad = [a for a, v in img.items() if mem[a] != v]
    if bad:
        print('FAIL: %d bytes of the tile and sprite routines changed, first x%04X' % (len(bad), bad[0]))
        ok = False
    pad.buttons = 0
    if not test_dos.esc_to_dos(rig):
        print('FAIL: Esc did not bring the DOS back')
        ok = False
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
