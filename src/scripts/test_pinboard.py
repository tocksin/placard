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
     comes back; Enter on a file that is not a program opens it in the Editor
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
  9. the Editor: a file opened from Files, typing, the arrows, joining and
     splitting lines, a click, long lines and long texts, saving (line
     ends kept as the file had them), a new text saved under a typed name,
     files it won't open, and unsaved text keeping Pinboard from leaving

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
K_LEFT, K_RIGHT, K_HOME, K_DEL = 0x16B, 0x174, 0x16C, 0x171
CALC_KEYS = {'1': 0x16, '2': 0x1E, '3': 0x26, '4': 0x25, '5': 0x2E, '6': 0x36, '7': 0x3D,
             '8': 0x3E, '9': 0x46, '0': 0x45, '-': 0x4E, '=': 0x55, '/': 0x4A, 'n': 0x31,
             'c': 0x21, 'm': 0x3A, '\n': K_ENTER, '\b': K_BKSP}
CALC_KEYS.update(zip('abcdefghijklmnopqrstuvwxyz',
                     (0x1C, 0x32, 0x21, 0x23, 0x24, 0x2B, 0x34, 0x33, 0x43, 0x3B, 0x42, 0x4B, 0x3A,
                      0x31, 0x44, 0x4D, 0x15, 0x2D, 0x1B, 0x2C, 0x3C, 0x2A, 0x1D, 0x22, 0x35, 0x1A)))
CALC_KEYS.update({' ': 0x29, '.': 0x49, ',': 0x41})
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
        self.card = card
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
    np = o['notprog']
    check('a file that is not a program opens in the Editor',
          np.has('* Editor', 10) and np.has('BOOT.CFG', 11) and np.has('PINBOARD.PLC', 12))

    # ---- 3, 4: the mouse ----------------------------------------------
    print('3. the mouse')
    s = Script()
    s.cell(10, 40)
    s.shot('moved', 5)
    s.click(3, 58)
    s.shot('menu')
    s.click(5, 51)                      # Clock
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
                              enumerate(('Files', 'Clock', 'Calculator', 'Editor', 'About', 'BASIC', 'Back to DOS'), 50)))
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
    s.click(5, 51)                      # Clock
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
    for _ in range(4):
        s.key(K_DOWN)
    s.shot('menu', 5)
    s.key(K_ENTER)
    s.shot('about')
    o = s.run(files, mouse=False, png=args.png, tag='6_')
    check('no pointer', o['up'].has('* Files', 1) and not o['up'].pointer())
    check('Esc: the launcher, Down four times, Enter: About',
          o['menu'].has(' Back to DOS') and o['about'].has('* About') and o['about'].has('PINBOARD'))

    # ---- 7: back to the DOS ---------------------------------------------
    print('7. the DOS')
    s = Script()
    s.key(K_ESC)
    for _ in range(6):
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
    s.click(5, 52)
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

    # ---- 9: the Editor (its card is at 20, 10) ---------------------------
    print('9. the Editor')
    etch = names.index('ETCH.BAS')
    s = Script()
    for _ in range(etch):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.shot('open', 60)
    s.key(K_DOWN)
    s.key(K_DOWN)
    s.key(K_RIGHT)
    s.type('abc\nxy')
    s.shot('typed')
    s.key(K_UP)
    s.key(K_HOME)
    s.key(K_DEL)
    s.key(K_BKSP)
    s.shot('joined')
    s.click(30, 16)                     # row 4 of the text, column 9
    s.cell(70, 50)
    s.type('q')
    s.shot('clicked')
    s.chord(K_CTRL, CALC_KEYS['e'])     # the line's end
    s.type(' ' + 'z' * 30)
    s.shot('wide')
    s.chord(K_CTRL, CALC_KEYS['o'])
    s.shot('saved', 150)
    s.type('k')                         # unsaved text: no leaving
    s.key(K_ESC)
    for _ in range(6):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.shot('guard', 60)
    s.chord(K_CTRL, CALC_KEYS['n'])
    s.shot('warn')
    s.chord(K_CTRL, CALC_KEYS['n'])
    s.shot('new')
    s.type('a\n' * 30 + 'end')
    s.shot('long', 40)
    s.chord(K_CTRL, CALC_KEYS['o'])
    s.shot('ask')
    s.type('note.txt\n')
    s.shot('named', 200)
    o = s.run(files, png=args.png, tag='9_')
    card = s.card
    src = files['ETCH.BAS'].decode('latin-1').split('\n')

    def text(scr, n=26):
        return [r[21:63].rstrip() for r in scr.rows[12:12 + n]]
    check('ETCH.BAS opens in the Editor', o['open'].has('* Editor', 10) and o['open'].has('ETCH.BAS', 11)
          and text(o['open'], 5) == [l[:42] for l in src[:5]])
    want = src[:2] + [src[2][:1] + 'abc', 'xy' + src[2][1:]] + src[3:]
    check('typing and Enter', text(o['typed'], 6) == [l[:42] for l in want[:6]]
          and o['typed'].has('ETCH.BAS *', 11))
    want = src[:1] + [src[1] + 'abc', 'xy' + src[2][1:]] + src[3:]
    check('Up, Home, Del, Backspace join the lines', text(o['joined'], 6) == [l[:42] for l in want[:6]])
    want[4] = want[4][:9] + 'q' + want[4][9:]
    check('a click puts the cursor there', text(o['clicked'], 6) == [l[:42] for l in want[:6]])
    want[4] += ' ' + 'z' * 30
    shift = len(want[4]) - 41
    check('a long line scrolls sideways', shift > 0
          and text(o['wide'], 6) == [l[shift:shift + 42] for l in want[:6]])
    check('Ctrl+O saves it, line ends as they were', o['saved'].has('Saved', 11)
          and sdimage.read(card, 'ETCH.BAS') == '\n'.join(want).encode('latin-1'))
    check('unsaved text keeps Pinboard from leaving',
          o['guard'].has('Not saved: Ctrl+O, or Ctrl+N twice', 11) and o['guard'].has('* Editor', 10))
    check('Ctrl+N asks once, then clears', o['warn'].has('Ctrl+N again', 11)
          and o['new'].has('(new text)', 11) and text(o['new']) == [''] * 26)
    check('a long text scrolls', text(o['long']) == ['a'] * 25 + ['end'])
    check('a new text asks for its name', o['ask'].has('Save as: _', 11))
    check('and is saved under it, with CR LF', sdimage.read(card, 'NOTE.TXT') == b'a\r\n' * 30 + b'end'
          and o['named'].has('Saved', 11))

    s = Script()
    for _ in range(boot):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.chord(K_CTRL, CALC_KEYS['e'])
    s.type('x')
    s.chord(K_CTRL, CALC_KEYS['o'])
    s.shot('cfg', 150)
    s.key(K_TAB)
    for _ in range(names.index('DEMO.SNG') - boot):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.shot('binary', 80)
    for _ in range(names.index('RAYTEX.OVL') - names.index('DEMO.SNG')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.shot('big', 40)
    o = s.run(files, png=args.png, tag='9b_')
    check('a CR LF file is saved with CR LF', sdimage.read(s.card, 'BOOT.CFG') == b'PINBOARD.PLCx\r\n')
    check('a file that is not text', o['binary'].has('Not a text file', 29))
    check('a file that is too big', o['big'].has('Too big for the Editor', 29))

    print('PASS' if check.ok else 'FAIL')
    return 0 if check.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
