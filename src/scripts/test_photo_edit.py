#!/usr/bin/env python3
"""
test_photo_edit.py - run the picture editor of PHOTO.PLC (photo_edit.masm)
in the web emulator's core and check what it draws and saves

    python3 test_photo_edit.py              the checks below
    python3 test_photo_edit.py --png DIR    also the screens as DIR/*.png

Needs node (pinboard_emu.py runs web/placard_emu.js).  Every part runs on
a rev B board in 160 across and on a rev A board in 80 across.

  1. E in the viewer: the bar (tools, status row, the 256 colors) over the
     picture's last 32 rows, the rest of the picture untouched
  2. a new picture: rectangle, line, a color from the bar, fill, brush,
     undo, pencil, save under a typed name: the pixels after each step,
     and the file on the card (the rows under the bar too)
  3. on a photograph: the bar away, a line into the rows it covered, the
     bar back, undo of something the bar now covers, the bar at the top,
     save: the file is the photograph with only those pixels changed
  4. fill and its undo, pick and the eraser, the right button (paper
     color, the bar away and back), the brush sizes
  5. the keyboard alone: the arrows and Space draw
  6. more drawn than the journal holds: undo says so and changes nothing
  7. leaving: a changed picture asks first; N stays, Y goes back to the
     viewer with the picture as it is on the card and every row's mode
     byte back; the viewer then counts the new file
  8. sdcard/PHOTO.PLC is photo.asm

Date: 11/23/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402
import pinboard_emu as pe     # noqa: E402
import test_pinboard as tp    # noqa: E402

REPO = os.path.join(HERE, '..', '..')
SD = os.path.join(REPO, 'sdcard')
K = dict(tp.CALC_KEYS)
K.update({'[': 0x54, ']': 0x5B})
PX = 0x40                   # photo_edit.masm: ed_pxl, the pointer's X and Y
ED_INK, ED_PAPER, ED_SIZE, PH_TOT, PH_MODE = 0x51, 0x52, 0x53, 0x21, 0x23
MODES = 0x5A20
SIZE = 40960
ok = True


def check(what, cond, more=''):
    global ok
    print('  %-66s %s%s' % (what, 'ok' if cond else 'FAILED', '  ' + str(more) if more and not cond else ''))
    ok = ok and bool(cond)


def low(y):
    return 2 * y + 32 if y < 112 else 2 * y - 223


class Pic:
    """a picture's 40,960 bytes (a file, or the video RAM), by pixel"""
    def __init__(self, data, wide):
        self.d = bytearray(data[:SIZE])
        self.wide = wide
        self.w = 160 if wide else 80

    def get(self, x, y):
        return self.d[(x if self.wide else 2 * x + 1) * 256 + low(y)]

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < 240:
            if self.wide:
                self.d[x * 256 + low(y)] = c
            else:
                self.d[2 * x * 256 + low(y)] = self.d[(2 * x + 1) * 256 + low(y)] = c

    def line(self, x0, y0, x1, y1, c):
        """the editor's line (photo_edit.masm: e_line)"""
        dx, dy = abs(x1 - x0), abs(y1 - y0)
        sx, sy = (1 if x1 >= x0 else -1), (1 if y1 >= y0 else -1)
        x, y = x0, y0
        if dx >= dy:
            err = dx >> 1
            for _ in range(dx + 1):
                self.put(x, y, c)
                x += sx
                err -= dy
                if err < 0:
                    err += dx
                    y += sy
        else:
            err = dy >> 1
            for _ in range(dy + 1):
                self.put(x, y, c)
                y += sy
                err -= dx
                if err < 0:
                    err += dy
                    x += sx

    def rect(self, x0, y0, x1, y1, c):
        for a, b, e, f in ((x0, y0, x1, y0), (x0, y1, x1, y1), (x0, y0, x0, y1), (x1, y0, x1, y1)):
            self.line(a, b, e, f, c)

    def rows(self, y0, y1):
        """the bytes of rows y0 to y1 of every page"""
        return bytes(self.d[p * 256 + low(y)] for p in range(160) for y in range(y0, y1 + 1))


def screen(ram, wide):
    return Pic(ram[0x6000:], wide)


def bar_text(ram, top=208):
    """the bar's two text rows, and which of their characters are white on black"""
    rom = pe.rom_image()
    font = [rom[0x1700 + 256 * k:0x1800 + 256 * k] for k in range(8)]
    look = {tuple(font[k][c] for k in range(8)): c for c in range(255, -1, -1)}
    rows, plain = [], []
    for tr in range(2):
        line, pl = '', []
        for c in range(80):
            code = look.get(tuple(ram[0x6100 + c * 512 + low(top + tr * 8 + k)] for k in range(8)))
            line += '?' if code is None else chr(code & 0x7F) if code & 0x60 else ' '
            pl.append(code is not None and code < 0x80)
        rows.append(line)
        plain.append(pl)
    return rows, plain


class Ed(tp.Script):
    """a script that starts in the editor"""
    def __init__(self, wide, first=0):
        super().__init__()
        self.wide = wide
        self.W = 4 if wide else 8
        self.xm = 159 if wide else 79
        self.t = 200
        self.key(K['h'] if wide else K['n'])
        self.wait(80)
        for _ in range(first):
            self.key(K[' '])
            self.wait(80)
        self.key(K['e'])
        self.wait(120)
        self.x, self.y = 320, 200

    def pt(self, x, y):
        self.move(x * self.W + self.W // 2, y * 2 + 1)

    def drag(self, x0, y0, x1, y1):
        self.pt(x0, y0)
        self.down()
        self.pt(x1, y1)
        self.wait(10)
        self.up()

    def tap(self, x, y):
        self.pt(x, y)
        self.down()
        self.up()

    def color(self, c, top=208, right=False):
        self.move((c & 63) * 8 + 4, (top + 16 + (c >> 6) * 4 + 1) * 2 + 1)
        self.b = 2 if right else 1
        self.inp.append((self.t, 'goto', (self.x, self.y, self.b)))
        self.t += 12
        self.up()

    def rclick(self, x, y):
        self.pt(x, y)
        self.b = 2
        self.inp.append((self.t, 'goto', (self.x, self.y, 2)))
        self.t += 12
        self.up()

    def park(self):
        """the pointer on the bar's status row, off the picture"""
        self.move(636, 208 * 2 + 20)

    def go(self, files, png, tag):
        return self.run(files, png=png, tag=tag, rev_b=self.wide, px=PX)


def card(plc, names=('TEMPLE.PIC', 'TULIPS.PIC')):
    files = {'DOS.PLC': open(os.path.join(SD, 'DOS.PLC'), 'rb').read(), 'PHOTO.PLC': plc,
             'BOOT.CFG': b'PHOTO.PLC\r\n'}
    for n in names:
        files['PHOTOS/' + n] = open(os.path.join(SD, 'PHOTOS', n), 'rb').read()
    return files


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
    src = open(os.path.join(HERE, 'photo.asm')).read()
    mem, syms, _ = ps.assemble(src, HERE)
    plc = gen_plc.plc_bytes(mem, syms) if hasattr(gen_plc, 'plc_bytes') else None
    if plc is None:
        import subprocess
        import tempfile
        tmp = os.path.join(tempfile.mkdtemp(), 'PHOTO.PLC')
        subprocess.run([sys.executable, os.path.join(HERE, 'gen_plc.py'), os.path.join(HERE, 'photo.asm'), '-o', tmp],
                       check=True, capture_output=True)
        plc = open(tmp, 'rb').read()
    files = card(plc)
    photo = files['PHOTOS/TEMPLE.PIC']

    for wide in (True, False):
        tag = 'b_' if wide else 'a_'
        mode = 0x87 if wide else 0x07
        print('=== %s ===' % ('rev B, 160 across' if wide else 'rev A, 80 across'))
        xm = 159 if wide else 79

        print('1. E in the viewer')
        s = Ed(wide)
        s.park()
        s.shot('bar')
        out = s.go(files, args.png, tag)
        ram = out['bar'].ram
        rows, plain = bar_text(ram)
        check('the tools, Pencil chosen', rows[0] == ' Pencil  Brush  Eraser  Line  Rect  Fill  Pick  Undo  Save  As  New  Hide  Exit '
              and plain[0][:8] == [True] * 8 and not any(plain[0][8:]), rows[0])
        check('the name and the brush size', rows[1][1:11] == 'TEMPLE.PIC' and 'Size < 2 >' in rows[1], rows[1])
        orig = Pic(photo, wide)
        check('the picture above the bar is the file', screen(ram, wide).rows(0, 207) == orig.rows(0, 207))
        check('the mode bytes: 416 lines the picture, 32 text, 32 colors',
              all(ram[MODES + k] == mode for k in range(416)) and all(ram[MODES + k] == 0x04 for k in range(416, 448))
              and all(ram[MODES + k] == 0x07 for k in range(448, 480)))
        pal = all(ram[0x6000 + (2 * c + h) * 256 + low(224 + 4 * r + k)] == r * 64 + c
                  for c in range(64) for r in range(4) for k in range(4) for h in (0, 1))
        check('the 256 colors', pal)

        print('2. a new picture')
        s = Ed(wide)
        x0, y0, x1, y1 = xm // 4, 40, 3 * xm // 4, 160
        s.key(K['n'])
        s.wait(40)
        s.key(K['r'])
        s.drag(x0, y0, x1, y1)
        s.park()
        s.shot('rect')
        s.key(K['l'])
        s.drag(x0, y0, x1, y1)
        s.color(0x07)
        s.key(K['f'])
        s.tap(x1 - 3, y0 + 20)
        s.wait(60)
        s.park()
        s.shot('fill')
        s.color(0xE0)
        s.key(K['b'])
        s.drag(5, 20, xm - 5, 30)
        s.park()
        s.shot('brush')
        s.key(K['u'])
        s.wait(20)
        s.shot('undo')
        s.key(K['p'])
        s.drag(5, 20, xm - 5, 30)
        s.key(K['s'])
        s.wait(20)
        s.shot('ask')
        for ch in 'test9':
            s.key(K[ch])
        s.key(tp.K_BKSP)
        s.key(tp.K_ENTER)
        s.wait(400)
        s.park()
        s.shot('saved')
        out = s.go(files, args.png, tag)
        want = Pic(bytes(SIZE), wide)
        want.rect(x0, y0, x1, y1, 0xFF)
        check('the rectangle', screen(out['rect'].ram, wide).rows(0, 207) == want.rows(0, 207))
        got = screen(out['fill'].ram, wide)
        want.line(x0, y0, x1, y1, 0xFF)
        red = sum(1 for y in range(208) for x in range(want.w) if got.get(x, y) == 0x07)
        for y in range(y0 + 1, y1):             # right of the line, inside
            for x in range(x0 + 1, x1):
                if want.get(x, y) == 0 and (x - x0) * (y1 - y0) > (y - y0) * (x1 - x0) + (y1 - y0) // 2 + (x1 - x0):
                    want.put(x, y, 0x07)
        inside = all(got.get(x, y) == 0x07 for y in range(y0 + 1, y1) for x in range(x0 + 1, x1) if want.get(x, y) == 0x07)
        check('the line, and the fill on one side of it only', inside and got.get(x0 + 2, y1 - 3) == 0
              and all(got.get(x, y) in (0, 0xFF, 0x07) for y in range(208) for x in range(want.w))
              and red < (x1 - x0) * (y1 - y0) * 0.56 and got.get(0, 0) == 0, red)
        check('the ink shows in the bar', out['fill'].ram[0x6000 + (2 * 68) * 256 + low(230)] == 0x07)
        b = screen(out['brush'].ram, wide)
        n = sum(1 for y in range(10, 40) for x in range(b.w) if b.get(x, y) == 0xE0)
        check('the brush stroke, wider than a pixel', n > 3 * (xm - 10), n)
        check('undo takes it back', screen(out['undo'].ram, wide).rows(0, 207) == got.rows(0, 207)
              and 'Undone' in bar_text(out['undo'].ram)[0][1])
        check('Save asks a name', 'Save as: _' in bar_text(out['ask'].ram)[0][1])
        rows, _ = bar_text(out['saved'].ram)
        check('the name and "Saved"', rows[1][1:9] == 'TEST.PIC' and 'Saved' in rows[1] and rows[1][13] == ' ', rows[1])
        try:
            f = sdimage.read(bytearray(s.card), 'PHOTOS/TEST.PIC')
        except Exception as ex:                 # noqa: BLE001
            f = b''
            print('   ', ex)
        fp = Pic(f, wide) if len(f) == SIZE else None
        check('the file: 40,960 bytes, the pencil line in it', fp is not None and fp.get(5, 20) == 0xE0
              and fp.get(xm - 5, 30) == 0xE0 and fp.get(x0, y0) == 0xFF)
        check('the rows under the bar are the paper', fp is not None and not any(fp.rows(208, 239)))
        check('the screen is the file above the bar', fp is not None
              and screen(out['saved'].ram, wide).rows(0, 207) == fp.rows(0, 207))

        print('3. on a photograph')
        s = Ed(wide)
        s.key(K['h'])
        s.wait(20)
        s.shot('away')
        s.drag(10, 150, 10, 235)
        s.drag(30, 150, 30, 235)
        s.key(K['h'])
        s.wait(30)
        s.key(K['u'])
        s.wait(40)
        s.key(K['m'])
        s.wait(40)
        s.shot('top')
        s.drag(50, 100, 50, 239)
        s.move(500, 20)
        s.key(K['s'])
        s.wait(400)
        s.shot('saved')
        out = s.go(files, args.png, tag + '3_')
        ram = out['away'].ram
        check('H: the bar away, the whole photograph back', sum(1 for k in range(SIZE) if ram[0x6000 + k] != photo[k]) <= 24      # (the pointer's cross)
              and all(ram[MODES + k] == mode for k in range(480)))
        ram = out['top'].ram
        check('M: the bar at the top', bar_text(ram, 0)[0][0].startswith(' Pencil  Brush')
              and all(ram[MODES + k] == 0x04 for k in range(32)) and all(ram[MODES + k] == 0x07 for k in range(32, 64))
              and all(ram[MODES + k] == mode for k in range(64, 480)))
        want = Pic(photo, wide)
        want.line(10, 150, 10, 235, 0xFF)
        want.line(50, 100, 50, 239, 0xFF)
        f = sdimage.read(bytearray(s.card), 'PHOTOS/TEMPLE.PIC')
        diff = sum(1 for k in range(SIZE) if f[k] != want.d[k]) if len(f) == SIZE else -1
        check('the file: the photograph with the two lines, the undone one gone', diff == 0, diff)
        check('"Saved", no mark by the name', 'Saved' in bar_text(out['saved'].ram, 0)[0][1]
              and bar_text(out['saved'].ram, 0)[0][1][13] == ' ')

        print('4. fill and undo, pick, the eraser, the right button, sizes')
        s = Ed(wide)
        s.key(K['n'])
        s.wait(40)
        s.key(K['h'])                           # the bar away: a rectangle into its rows
        s.wait(30)
        s.key(K['r'])
        s.drag(10, 100, xm - 10, 230)
        s.key(K['h'])                           # the bar back over part of it
        s.wait(30)
        s.color(0x1F)
        s.key(K['f'])
        s.tap(20, 120)
        s.wait(80)
        s.park()
        s.shot('fill')
        s.key(K['u'])
        s.wait(80)
        s.shot('undo')
        s.color(0xE7, right=True)               # paper
        s.key(K['k'])
        s.tap(10, 150)                          # the rectangle's white
        s.shot('pick')
        s.key(K[']'])
        s.key(K[']'])
        s.key(K[']'])
        s.key(K['e'])
        s.drag(20, 50, 40, 50)
        s.rclick(60, 20)
        s.shot('right')
        s.rclick(60, 20)
        s.park()
        s.shot('right2')
        out = s.go(files, args.png, tag + '4_')
        g = out['fill'].ram
        check('H after a hidden bar brings it back', bar_text(g)[0][0].startswith(' Pencil'))
        gp = screen(g, wide)
        check('fill inside the rectangle (the part above the bar seen)', all(gp.get(x, y) == 0x1F for x in range(11, xm - 10) for y in range(101, 208))
              and gp.get(5, 150) == 0 and gp.get(10, 150) == 0xFF)
        gu = screen(out['undo'].ram, wide)
        check('undo: black inside again, the bar whole', all(gu.get(x, y) == 0 for x in range(11, xm - 10) for y in range(101, 208))
              and gu.get(10, 150) == 0xFF and bar_text(out['undo'].ram)[0][0].startswith(' Pencil'))
        r = out['pick'].ram
        check('pick: the ink is the pixel\'s color; right click: the paper', r[ED_INK] == 0xFF and r[ED_PAPER] == 0xE7)
        r = out['right'].ram
        gp = screen(r, wide)
        n = sum(1 for y in range(30, 70) for x in range(gp.w) if gp.get(x, y) == 0xE7)
        rows_h = 5 * (2 if wide else 4)
        check('size 5 is not there: 4; the eraser draws the paper, %d rows high' % (4 * (2 if wide else 4)),
              r[ED_SIZE] == 4 and n == 24 * 4 * (2 if wide else 4) and rows_h, n)
        check('right click on the picture: the bar away', all(r[MODES + k] == mode for k in range(480)))
        check('and back', bar_text(out['right2'].ram)[0][0].startswith(' Pencil'))

        print('5. the keyboard alone')
        s = Ed(wide)
        s.key(K['n'])
        s.wait(40)
        s.shot('start')
        for _ in range(3):
            s.key(tp.K_RIGHT)
        for _ in range(2):
            s.key(tp.K_DOWN)
        s.key(K[' '], hold=6)
        s.key(tp.K_LEFT)
        s.key(tp.K_UP)
        s.inp += [(s.t, 'press', K[' ']), (s.t + 8, 'press', tp.K_RIGHT), (s.t + 16, 'release', tp.K_RIGHT),
                  (s.t + 24, 'release', K[' '])]
        s.t += 40
        s.shot('keys')
        out = s.run(files, mouse=False, png=args.png, tag=tag + '5_', rev_b=wide, px=PX)
        r = out['keys'].ram
        cx, cy = 320 // s.W, 100
        gp = screen(r, wide)
        px = r[PX] | r[PX + 1] << 8
        step = 4 if wide else 8
        dots = sorted((x, y) for y in range(208) for x in range(gp.w) if gp.get(x, y) == 0xFF and abs(x - cx) > 2 + 0 * y or
                      (gp.get(x, y) == 0xFF and (x, y) in ((cx + 3 * step // s.W, cy + 2),)))
        want_x = cx + 3 * step // s.W
        check('3 Right, 2 Down, Space: a pixel there', gp.get(want_x, cy + 2) == 0xFF, (px, dots[:6]))
        x2 = want_x - step // s.W
        check('Left, Up, Space held and Right: a pixel, and a line of two',
              gp.get(x2, cy + 1) == 0xFF and gp.get(x2 + step // s.W, cy + 1) == 0xFF, dots[:8])

        print('6. more than the journal holds')
        s = Ed(wide)
        s.key(K['n'])
        s.wait(40)
        for _ in range(3):
            s.key(K[']'])
        s.key(K['b'])
        s.pt(5, 20)
        s.down()
        for k in range(6):
            s.pt(xm - 5, 30 + 20 * k)
            s.pt(5, 40 + 20 * k)
        s.up()
        s.park()
        s.shot('big')
        s.key(K['u'])
        s.wait(30)
        s.shot('undo')
        out = s.go(files, args.png, tag + '6_')
        a, b = screen(out['big'].ram, wide), screen(out['undo'].ram, wide)
        n = sum(1 for y in range(208) for x in range(a.w) if a.get(x, y) == 0xFF)
        check('a big scribble (%d pixels)' % n, n > 1536)
        check('undo: nothing changed, and it says so', a.rows(0, 207) == b.rows(0, 207)
              and 'Too much was drawn' in bar_text(out['undo'].ram)[0][1], bar_text(out['undo'].ram)[0][1])

        print('7. leaving')
        s = Ed(wide)
        s.key(K['l'])
        s.drag(20, 20, 60, 60)
        s.key(tp.K_ESC)
        s.wait(20)
        s.park()
        s.shot('ask')
        s.key(K['n'])
        s.wait(20)
        s.shot('stay')
        s.key(K['a'])
        for ch in 'copy':
            s.key(K[ch])
        s.key(tp.K_ENTER)
        s.wait(400)
        s.drag(20, 60, 60, 20)
        s.key(K['x'])
        s.wait(20)
        s.key(K['y'])
        s.wait(200)
        s.shot('viewer')
        out = s.go(files, args.png, tag + '7_')
        rows, _ = bar_text(out['ask'].ram)
        check('Esc on a changed picture asks', 'Discard the changes?' in rows[1] and rows[1][13] == '*', rows[1])
        rows, _ = bar_text(out['stay'].ram)
        check('N: still in the editor, the question gone', rows[0].startswith(' Pencil') and 'Discard' not in rows[1])
        r = out['viewer'].ram
        f = sdimage.read(bytearray(s.card), 'PHOTOS/COPY.PIC')
        want = Pic(photo, wide)
        want.line(20, 20, 60, 60, 0xFF)
        check('A: saved under another name, the first file as it was', bytes(f) == bytes(want.d)
              and sdimage.read(bytearray(s.card), 'PHOTOS/TEMPLE.PIC') == photo)
        check('X then Y: the viewer, the picture as it is on the card',
              bytes(r[0x6000:0x6000 + SIZE]) == photo[:SIZE] and all(r[MODES + k] == mode for k in range(480)))
        check('the viewer counts 3 pictures now', r[PH_TOT] == 3, r[PH_TOT])

    print('8. the card\'s file')
    check('sdcard/PHOTO.PLC is photo.asm', open(os.path.join(SD, 'PHOTO.PLC'), 'rb').read() == plc)
    print('all passed' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
