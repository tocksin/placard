#!/usr/bin/env python3
"""
test_pinboard.py - Pinboard (pinboard.masm, pinboard.vm) from a card in the
web emulator (web/placard_emu.js; needs node), driven by keys and the mouse

    python3 test_pinboard.py            the checks below, about 20 s
    python3 test_pinboard.py --png DIR  also writes each step's screen

The card is the sdcard/ folder with BOOT.CFG = PINBOARD.PLC.  Each step
reads the screen back through Pinboard's font (pinboard_emu.cells).

  1. power-up: the board, the Files card listing the card's root folder
     in the card's order with sizes, the rail with the Pinboard button,
     the Files button and 00:00
  2. keys: Down moves the bar; Enter on a folder opens it, Backspace
     comes back; Enter on a file that is not a program says so
  3. the mouse: the pointer follows it; a click on the rail's Pinboard
     button shows the launcher, a click on Clock opens the Clock card;
     its H+ and M+ buttons set the time, which the rail shows; the
     seconds count
  4. a title dragged moves its card (an outline follows the pointer); a
     click on a card behind brings it to the front; Tab too; the pin
     takes a card down, Ctrl+W too
  5. Enter on PI.PLC runs it (the screen is the program's); Esc comes
     back to Pinboard with the same entry chosen and the clock kept
  6. with no mouse: no pointer, the keys work (Esc, the launcher, About)
  7. the launcher's "Back to DOS" starts the DOS
  8. the calculator, by clicks and by keys

Date: 11/16/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pinboard_emu as pe     # noqa: E402
import sdimage                # noqa: E402
import gen_pinboard           # noqa: E402

REPO = os.path.join(HERE, '..', '..')
FONT = gen_pinboard.font_rows()
K_DOWN, K_UP, K_ENTER, K_BKSP, K_ESC, K_TAB, K_CTRL, K_W = 0x172, 0x175, 0x5A, 0x66, 0x76, 0x0D, 0x14, 0x1D
K_SHIFT = 0x12
CALC_KEYS = {'1': 0x16, '2': 0x1E, '3': 0x26, '4': 0x25, '5': 0x2E, '6': 0x36, '7': 0x3D,
             '8': 0x3E, '9': 0x46, '0': 0x45, '-': 0x4E, '=': 0x55, '/': 0x4A, 'n': 0x31,
             'c': 0x21, 'm': 0x3A, '\n': K_ENTER, '\b': K_BKSP}
CALC_SHIFT = {'*': 0x3E, '+': 0x55, '%': 0x2E}


class Script:
    """keys and mouse moves on a time line of frames, and the screens to keep"""
    def __init__(self):
        self.t = 150            # Pinboard is up by then
        self.inp = []
        self.shots = []
        self.x, self.y, self.b = 320, 240, 0

    def wait(self, n):
        self.t += n

    def key(self, code, hold=3):
        # an arrow key is 5 bytes down and up, and with a mouse the keyboard
        # has the line every other frame
        self.inp += [(self.t, 'press', code), (self.t + hold, 'release', code)]
        self.t += hold + 11

    def chord(self, mod, code):
        self.inp += [(self.t, 'press', mod), (self.t + 4, 'press', code),
                     (self.t + 8, 'release', code), (self.t + 12, 'release', mod)]
        self.t += 20

    def move(self, x, y):
        # the emulator steers by Pinboard's pointer: 4 frames a step of 20
        d = max(abs(x - self.x), abs(y - self.y))
        self.inp.append((self.t, 'goto', (x, y, self.b)))
        self.x, self.y = x, y
        self.t += 4 * (d // 20 + 6)

    def type(self, text):
        for ch in text:
            if ch in CALC_SHIFT:
                self.chord(K_SHIFT, CALC_SHIFT[ch])
            else:
                self.key(CALC_KEYS[ch])

    def cell(self, c, r):
        self.move(c * 8 + 4, r * 8 + 4)

    def down(self):
        self.b = 1
        self.inp.append((self.t, 'goto', (self.x, self.y, 1)))
        self.t += 12

    def up(self):
        self.b = 0
        self.inp.append((self.t, 'goto', (self.x, self.y, 0)))
        self.t += 12

    def click(self, c, r):
        self.cell(c, r)
        self.down()
        self.up()

    def shot(self, name, settle=25):
        self.t += settle
        self.shots.append((self.t, name))

    def run(self, files, mouse=True, png=None, tag=''):
        rams, card = pe.run(files, self.inp, [t for t, _ in self.shots], self.t + 5, mouse=mouse)
        out = {}
        for t, name in self.shots:
            if png:
                pe.screen_png(rams[t], os.path.join(png, tag + name + '.png'))
            out[name] = Screen(rams[t])
        return out


class Screen:
    def __init__(self, ram):
        self.ram = ram
        self.rows, self.inv = pe.cells(ram, FONT)

    def has(self, text, row=None):
        rows = self.rows if row is None else [self.rows[row]]
        return any(text in r for r in rows)

    def find(self, text):
        for r, line in enumerate(self.rows):
            if text in line:
                return line.index(text), r
        return None

    def chosen(self):
        """the Files list's entry on the bar: its row's text, or None"""
        for r, line in enumerate(self.rows):
            for c in range(80):
                if line[c] in 'FPf' and not self.inv[r][c] and c + 2 < 80 and line[c + 1] == ' ':
                    return line[c + 2:c + 15].strip()
        return None

    def pointer(self):
        return [(c, r) for r in range(60) for c in range(80) if self.rows[r][c] == '?']


class Checks:
    def __init__(self):
        self.ok = True

    def __call__(self, what, cond):
        print('  %s %s' % ('ok  ' if cond else 'FAIL', what))
        self.ok &= bool(cond)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png', help='a folder for each step\'s screen')
    args = ap.parse_args(argv)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
    files = sdimage.from_folder(os.path.join(REPO, 'sdcard'))
    files['BOOT.CFG'] = b'PINBOARD.PLC\r\n'
    check = Checks()

    img = sdimage.make(files)
    names = [e[0] for e in sdimage.listdir(img)]
    pi = names.index('PI.PLC')
    lamp = names.index('LAMP')
    boot = names.index('BOOT.CFG')

    # ---- 1, 2: power-up and the keys ---------------------------------
    print('1. power-up')
    s = Script()
    s.shot('up', 0)
    for _ in range(lamp):
        s.key(K_DOWN)
    s.shot('lamp')
    s.key(K_ENTER)
    s.shot('in_lamp', 40)
    s.key(K_BKSP)
    s.shot('back', 40)
    for _ in range(boot):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.shot('notprog')
    o = s.run(files, png=args.png, tag='1_')
    up = o['up']
    check('the board and the rail', up.rows[0] == '.' * 80 and up.has(' Pinboard ', 58)
          and up.has('Files', 58) and up.has('00:00', 58))
    check('the Files card: title, the root folder', up.has('* Files', 1) and up.has('{ \\', 2))
    shown = [line[5:18].strip() for line in up.rows[3:29] if line[3] in 'FPf']
    check('the list is the card\'s root folder (%d entries shown)' % len(shown),
          shown == names[:26] and up.has('%d items' % len(names), 29))
    size = len(files['PI.PLC'])
    check('sizes and <DIR>', up.has('PI.PLC', 3 + pi) and up.has(' %d ' % size, 3 + pi)
          and up.has('<DIR>', 3 + lamp))
    check('the first entry is chosen; the pointer is in the middle',
          up.chosen() == names[0] and (40, 30) in up.pointer())
    print('2. keys')
    check('Down moves the bar', o['lamp'].chosen() == 'LAMP')
    inl = o['in_lamp']
    lamp_files = [e[0] for e in sdimage.listdir(img, 'LAMP') if not e[0].startswith('.')]
    check('Enter opens the folder', inl.has('{ LAMP', 2) and inl.has(lamp_files[0], 3)
          and inl.chosen() == lamp_files[0])
    check('Backspace goes back up', o['back'].has('{ \\', 2) and o['back'].chosen() == names[0])
    check('a file that is not a program', o['notprog'].has('Not a program (.PLC)', 29))

    # ---- 3, 4: the mouse ----------------------------------------------
    print('3. the mouse')
    s = Script()
    s.cell(10, 40)
    s.shot('moved', 5)
    s.click(3, 58)
    s.shot('menu')
    s.click(5, 52)                      # Clock
    s.shot('clock')
    s.click(49, 11)                     # H+ twice, M+ once (the card is at 46, 3)
    s.click(49, 11)
    s.click(54, 11)
    s.shot('set')
    s.wait(130)
    s.shot('later', 0)
    s.cell(60, 3)                       # the Clock card by its title to 26, 30
    s.down()
    s.cell(40, 30)
    s.shot('dragging', 5)
    s.up()
    s.shot('dropped')
    s.click(20, 20)                     # Files, behind
    s.shot('files_front')
    s.key(K_TAB)
    s.shot('clock_front')
    s.click(26, 30)                     # the Clock's pin
    s.shot('pinned')
    s.chord(K_CTRL, K_W)
    s.shot('empty')
    o = s.run(files, png=args.png, tag='3_')
    check('the pointer follows the mouse', (10, 40) in o['moved'].pointer())
    m = o['menu']
    check('the launcher', all(m.has(' ' + t, r) for r, t in
                              enumerate(('Files', 'Clock', 'Calculator', 'About', 'BASIC', 'Back to DOS'), 51)))
    c = o['clock']
    check('the Clock card, in front', c.has('* Clock', 3) and c.has('H+', 11)
          and c.has('Clock', 58) and not c.has(' Back to DOS'))
    check('H+ H+ M+ set 02:01', o['set'].has('02:01', 58))

    def secs(scr, x, y):                # the seconds' two big digits, as cells
        return [scr.inv[y + r][x + 22:x + 29] for r in range(2, 7)]
    check('the seconds count', secs(o['set'], 46, 3) != secs(o['later'], 46, 3))
    print('4. cards')
    d = o['dropped']
    check('a dragged title moves the card', d.has('* Clock', 30) and d.find('* Clock')[0] == 26
          and d.rows[3][46:77] == '.' * 31)
    ff = o['files_front']
    check('a click brings the card behind to the front',
          ff.rows[30][2] == '[' and ff.rows[30][26] == '_' and ff.has('* Files', 1))
    cf = o['clock_front']
    check('Tab brings the next card to the front', cf.has('* Clock', 30))
    p = o['pinned']
    check('the pin takes the card down', not p.has('Clock') and p.has('* Files', 1))
    check('Ctrl+W takes the front card down',
          all(set(r) <= set('.?') for r in o['empty'].rows[:57]) and not o['empty'].has('Files', 58))

    # ---- 5: a program and back ----------------------------------------
    print('5. a program')
    s = Script()
    s.click(3, 58)
    s.click(5, 52)                      # Clock
    s.click(49, 11)                     # 01:00
    s.key(K_TAB)
    for _ in range(pi):
        s.key(K_DOWN)
    s.shot('chosen', 5)
    s.key(K_ENTER)
    s.shot('running', 300)
    s.key(K_ESC, hold=20)
    s.shot('returned', 200)
    o = s.run(files, png=args.png, tag='5_')
    check('PI.PLC is chosen', o['chosen'].chosen() == 'PI.PLC')
    run = o['running']
    check('Enter runs it: the screen is the program\'s',
          not run.has('Pinboard') and not run.has('Files') and run.ram[0x5BE8] != 0x40)
    r = o['returned']
    check('Esc comes back to Pinboard, the entry still chosen, the clock kept',
          r.has(' Pinboard ', 58) and r.chosen() == 'PI.PLC' and r.has('01:0', 58))

    # ---- 6: no mouse ----------------------------------------------------
    print('6. no mouse')
    s = Script()
    s.t = 220                           # mouse_init waits for a mouse first
    s.shot('up', 0)
    s.key(K_ESC)
    for _ in range(3):
        s.key(K_DOWN)
    s.shot('menu', 5)
    s.key(K_ENTER)
    s.shot('about')
    o = s.run(files, mouse=False, png=args.png, tag='6_')
    check('no pointer', o['up'].has('* Files', 1) and not o['up'].pointer())
    check('Esc: the launcher, Down Down Down Enter: About',
          o['menu'].has(' Back to DOS') and o['about'].has('* About') and o['about'].has('PINBOARD'))

    # ---- 7: back to the DOS ---------------------------------------------
    print('7. the DOS')
    s = Script()
    s.key(K_ESC)
    for _ in range(5):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.shot('dos', 120)
    o = s.run(files, png=args.png, tag='7_')
    dos_font = [[0] * 256 for _ in range(8)]
    import gen_lib_font
    for i, rows in enumerate(gen_lib_font.FONT):
        for k in range(8):
            dos_font[k][0x20 + i] = rows[k]
    rows, _ = pe.cells(o['dos'].ram, dos_font)
    check('"Back to DOS" starts the DOS', 'PLACARD DOS' in rows[0] and o['dos'].ram[0x5BE8] == 0)

    # ---- 8: the calculator (its card is at 52, 20) ----------------------
    print('8. the calculator')
    s = Script()
    s.click(3, 58)
    s.click(5, 53)
    s.shot('calc')
    for c, r in ((55, 26), (70, 26), (65, 28), (70, 32)):      # 7 * 6 =
        s.click(c, r)
    s.shot('clicks')
    sums = (('c100-250=', '-150'), ('c7/2=', '3'), ('c22m5=', '2'), ('c99999*99999=', 'Error'),
            ('c5/0=', 'Error'), ('c123456789*17=', '2098765413'), ('c12\bn+20\n', '19'),
            ('cn5*n6=', '30'), ('c1000000/7=', '142857'), ('cn17%5=', '-2'), ('c8+', '+'))
    for i, (keys, _) in enumerate(sums):
        s.type(keys)
        s.shot('k%d' % i)
    o = s.run(files, png=args.png, tag='8_')

    def shows(scr):
        return scr.rows[22][54:73].split()
    check('the Calc card', o['calc'].has('* Calc', 20) and shows(o['calc']) == ['0']
          and o['calc'].has('mod', 32))
    check('clicks: 7 * 6 = 42', shows(o['clicks']) == ['42'])
    for i, (keys, want) in enumerate(sums):
        check('keys: %s  %s' % (keys[1:].replace('\n', '=').replace('\b', '<'), want),
              shows(o['k%d' % i])[-1 if i < len(sums) - 1 else 0] == want)

    print('PASS' if check.ok else 'FAIL')
    return 0 if check.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
