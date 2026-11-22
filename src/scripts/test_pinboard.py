#!/usr/bin/env python3
"""
test_pinboard.py - Pinboard (pinboard.masm, pinboard.vm) from a card in the
web emulator (web/placard_emu.js; needs node), driven by keys and the mouse

    python3 test_pinboard.py            the checks below, about 2 minutes
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
 10. the Display card on a rev B board: 4 colors and 16 colors (their
     drivers read from the card's PINBOARD folder), kept with Y or a
     click; the pointer, a click, a drag and the Calc card in them; a
     mode not kept goes back after 10 seconds; the mode is kept over a
     program's run; on a rev A board the color rows are blank and the
     2-color screen comes back
 11. pictures: Enter on a .PIC file runs the photo viewer (PHOTO.PLC),
     which shows that picture and the others of its folder; it asks 160
     or 80 across once, and not at all from a color mode; Esc comes back
     to Pinboard in the picture's folder; a card with no PHOTO.PLC
     (.WAV files and the sound player: test_wave.py)
 12. Ctrl+B in the Editor saves the text and runs it in BASIC; Ctrl+B at
     BASIC's prompt (or DOS) comes back to the Editor with the text and
     the cursor; a program in a folder; Esc stops a program and stays in
     BASIC; a new text is named first; EXIT in BASIC; the launcher's BASIC
     comes back to Pinboard too

Date: 11/22/2026
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
        self.cw, self.ch = 8, 8         # a cell in the pointer's 640 x 480

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
        self.move(c * self.cw + self.cw // 2, r * self.ch + self.ch // 2)

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

    def shot(self, name, settle=25, bpp=1):
        self.t += settle
        self.shots.append((self.t, name, bpp))

    def run(self, files, mouse=True, png=None, tag='', rev_b=False, audio=False, spc=1, size_kb=None, px=0x38, wifi=None):
        rams, card = pe.run(files, self.inp, [t for t, _, _ in self.shots], self.t + 5,
                            mouse=mouse, rev_b=rev_b, audio=audio, spc=spc, size_kb=size_kb, px=px, wifi=wifi)
        self.audio = rams.get('audio')
        out = {}
        for t, name, bpp in self.shots:
            if png:
                pe.screen_png(rams[t], os.path.join(png, tag + name + '.png'), rev_b)
            out[name] = Screen(rams[t]) if bpp == 1 else ColorScreen(rams[t], bpp)
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
                if line[c] in 'FPfi' and not self.inv[r][c] and c + 2 < 80 and line[c + 1] == ' ':
                    return line[c + 2:c + 15].strip()
        return None

    def pointer(self):
        return [(c, r) for r in range(60) for c in range(80) if self.rows[r][c] == '?']


class ColorScreen(Screen):
    """a 160-read screen (rev B): 80 x 30 cells in 2 bpp, 40 x 30 in 4 bpp"""
    def __init__(self, ram, bpp):
        self.ram = ram
        self.rows, self.colors = pe.cells_color(ram, bpp, FONT)

    def chosen(self):
        """the entry on the bar: white on blue"""
        bar = {(3, 1), (10, 3)}
        for r, line in enumerate(self.rows):
            for c in range(len(line) - 2):
                if line[c] in 'FPfi' and self.colors[r][c] in bar and line[c + 1] == ' ':
                    return line[c + 2:c + 15].strip()
        return None

    def pointer(self):
        return [(c, r) for r, line in enumerate(self.rows) for c in range(len(line)) if line[c] == '?']

    def color_of(self, text):
        """(ink, paper) of the first character of text"""
        c, r = self.find(text)
        return self.colors[r][c + len(text) - len(text.lstrip())]


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
    s.click(5, 50)                      # Clock
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
                              enumerate(('Files', 'Clock', 'Calculator', 'Editor', 'About', 'Display', 'BASIC', 'Back to DOS'), 49)))
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
    s.click(5, 50)                      # Clock
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
    for _ in range(7):
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
    s.click(5, 51)
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
    for _ in range(7):
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
    s.wait(60)
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

    # ---- 10: the Display card (rev B) -----------------------------------
    print('10. the display modes')

    def launcher(s, n, settle=40):
        s.key(K_ESC)
        for _ in range(n):
            s.key(K_DOWN)
        s.key(K_ENTER)
        s.wait(settle)

    s = Script()
    launcher(s, 5)
    s.cell(70, 50)                      # the pointer off the cards
    s.shot('disp', 0)
    s.type('2')
    s.shot('ask4', 150, 2)
    s.type('y')
    s.shot('kept4', 40, 2)
    s.cw, s.ch = 8, 16
    s.cell(10, 20)
    s.shot('ptr4', 5, 2)
    s.click(10, 2 + 3)                  # the Files card is at 1, 0: its fourth entry
    s.cell(70, 25)
    s.shot('click4', 25, 2)
    s.cell(45, 10)                      # the Display card (27, 10) by its title to 32, 5
    s.down()
    s.cell(50, 5)
    s.up()
    s.cell(70, 25)
    s.shot('drag4', 40, 2)
    launcher(s, 2)
    s.type('6*7=')
    s.shot('calc4', 25, 2)
    launcher(s, 5)
    s.cell(70, 25)
    s.type('3')
    s.shot('ask16', 150, 4)
    s.down()                            # a click keeps it
    s.up()
    s.shot('kept16', 40, 4)
    s.cw, s.ch = 16, 16
    s.cell(30, 25)
    s.shot('ptr16', 5, 4)
    s.cell(35, 26)
    launcher(s, 0)                      # Files to the front, then PI.PLC
    for _ in range(pi - 3):
        s.key(K_DOWN)
    s.shot('files16', 25, 4)
    s.key(K_ENTER)
    s.shot('running', 300)
    s.key(K_ESC, hold=20)
    s.shot('returned', 300, 4)
    launcher(s, 5)
    s.type('1')
    s.shot('mono', 150)
    s.type('2')
    s.shot('ask', 150, 2)
    s.shot('timeout', 560)
    o = s.run(files, png=args.png, tag='10_', rev_b=True)
    d = o['disp']
    c, r = d.find('1 640 x 480   2 colors')
    check('the Display card: the three modes, 2 colors in use',
          d.has('* Display') and not d.inv[r][c] and d.inv[r + 1][c]
          and d.has('2 640 x 240   4 colors', r + 1) and d.has('3 320 x 240  16 colors', r + 2))
    a = o['ask4']
    check('2: 640 x 240 in 4 colors, and it asks', a.ram[0x5A20] == 0x85 and a.ram[0x5BFF] == 0x85
          and not any(a.ram[0x5A00:0x5A20]) and a.has('Keep? Y or click, 10 s')
          and a.has('* Files', 0) and a.has(' Pinboard ', 29) and a.rows[27][60:] == ' ' * 20 and a.colors[27][60] == (None, 1))
    k = o['kept4']
    check('Y keeps it; black on gold, white on blue, gold on black',
          k.has('4, 16: rev B boards') and k.color_of('* Display') == (0, 2)
          and k.color_of('2 640 x 240') == (3, 1) and k.color_of('00:00') == (2, 0)
          and k.color_of(' Pinboard ') == (0, 2))
    check('the pointer follows the mouse', (10, 20) in o['ptr4'].pointer())
    check('a click chooses an entry', o['click4'].chosen() == names[3])
    check('a dragged title moves the card', o['drag4'].find('* Display') == (32, 5))
    check('Calc: 6 * 7 = 42', o['calc4'].has('* Calc', 12) and '42' in o['calc4'].rows[14][56:75])
    a = o['ask16']
    check('3: 320 x 240 in 16 colors', a.ram[0x5A20] == 0x86 and len(a.rows[0]) == 40
          and a.has('Keep? Y or click, 10 s') and a.has(' Pinboard ', 29))
    k = o['kept16']
    check('a click keeps it; black on cyan, white on blue, yellow on dark blue',
          k.has('4, 16: rev B boards') and k.color_of('* Display') == (0, 8)
          and k.color_of('3 320 x 240') == (10, 3) and k.color_of('00:0') == (14, 1))
    check('the pointer follows the mouse', (30, 25) in o['ptr16'].pointer())
    check('PI.PLC is chosen in the narrow Files card', o['files16'].chosen() == 'PI.PLC')
    run = o['running']
    check('it runs', run.ram[0x5A20] != 0x86 and not run.has('Pinboard'))
    r = o['returned']
    check('and Pinboard comes back in 16 colors', r.ram[0x5A20] == 0x86 and r.has(' Pinboard ', 29)
          and r.chosen() == 'PI.PLC')
    check('1: 2 colors again, no question', o['mono'].ram[0x5A20] == 0 and o['mono'].ram[0x5BE8] == 0x40
          and o['mono'].has('* Display') and o['mono'].has('4, 16: rev B boards'))
    t = o['timeout']
    check('a mode not kept goes back after 10 seconds', o['ask'].ram[0x5A20] == 0x85
          and t.ram[0x5A20] == 0 and t.has('* Display') and t.has('4, 16: rev B boards'))

    s = Script()                        # a rev A board: bit 7 blanks the rows
    launcher(s, 5)
    s.type('2')
    s.shot('ask', 150, 2)
    s.shot('timeout', 560)
    o = s.run(files, png=args.png, tag='10a_')
    t = o['timeout']
    check('rev A: the rows are blank, then 2 colors again', o['ask'].ram[0x5A20] == 0x85
          and t.ram[0x5A20] == 0 and t.has('* Display') and t.has(' Pinboard ', 58))

    # ---- 11: pictures ---------------------------------------------------
    print('11. pictures')
    photos = [e[0] for e in sdimage.listdir(img, 'PHOTOS') if not e[0].startswith('.')]
    pics = [n for n in photos if n.endswith('.PIC')]
    pic = pics[2]

    def screen_is(scr, data):
        return scr.ram[0x6000:0x10000] == data

    def rows_are(scr, mode):
        return set(scr.ram[0x5A20:0x5C00]) == {mode}

    s = Script()
    for _ in range(names.index('PHOTOS')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.wait(40)
    for _ in range(photos.index(pic)):
        s.key(K_DOWN)
    s.shot('chosen')
    s.key(K_ENTER)
    s.shot('ask', 250)
    s.type(' ')
    s.shot('pic', 120)
    s.key(K_RIGHT)
    s.shot('next', 120)
    s.key(K_ESC, hold=20)
    s.shot('back', 300)
    s.key(K_ENTER)
    s.shot('again', 300)
    s.key(K_ESC, hold=20)
    s.wait(300)
    s.key(K_BKSP)
    s.shot('root', 40)
    o = s.run(files, png=args.png, tag='11_')
    c = o['chosen']
    check('.PIC files have the picture mark', c.has('{ PHOTOS', 2) and c.chosen() == pic
          and all(c.has('i ' + n) for n in pics))
    a = o['ask']
    check('Enter runs the photo viewer, which asks 160 or 80 across',
          a.has('PLACARD PHOTOS') and a.has('%d pictures in this folder' % len(pics))
          and a.has('Press H for 160 across') and not a.has('Pinboard'))
    check('a key: the picture chosen, 80 across',
          screen_is(o['pic'], files['PHOTOS/' + pic]) and rows_are(o['pic'], 0x07))
    check('Right: the folder\'s next picture', screen_is(o['next'], files['PHOTOS/' + pics[3]]))
    b = o['back']
    check('Esc comes back to Pinboard, in the folder, the picture still chosen',
          b.has(' Pinboard ', 58) and b.has('{ PHOTOS', 2) and b.chosen() == pic
          and b.ram[0x5BE8] == 0x40)
    check('Enter again: the picture with no question',
          screen_is(o['again'], files['PHOTOS/' + pic]) and rows_are(o['again'], 0x07))
    check('and back again: Backspace goes up to the root folder',
          o['root'].has('{ \\', 2) and o['root'].chosen() == names[0])

    art = dict(files)                   # pictures in another folder, a color mode
    art['ART/NOTE.TXT'] = b'two pictures\r\n'
    art['ART/ONE.PIC'] = bytes((x * 7 + 1) & 0xFF for x in range(40960))
    art['ART/TWO.PIC'] = bytes((x * 13 + 5) & 0xFF for x in range(40960))
    aimg = sdimage.make(art)
    anames = [e[0] for e in sdimage.listdir(aimg)]
    alist = [e[0] for e in sdimage.listdir(aimg, 'ART') if not e[0].startswith('.')]
    s = Script()
    launcher(s, 5)
    s.type('2')
    s.wait(150)
    s.type('y')
    s.wait(40)
    launcher(s, 0)
    for _ in range(anames.index('ART')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.wait(40)
    for _ in range(alist.index('TWO.PIC')):
        s.key(K_DOWN)
    s.shot('chosen', 25, 2)
    s.key(K_ENTER)
    s.shot('pic', 300)
    s.key(K_LEFT)
    s.shot('prev', 120)
    s.key(K_ESC, hold=20)
    s.shot('back', 300, 2)
    o = s.run(art, png=args.png, tag='11b_', rev_b=True)
    check('4 colors: TWO.PIC chosen in the ART folder', o['chosen'].chosen() == 'TWO.PIC')
    check('Enter: the picture at once, 160 across',
          screen_is(o['pic'], art['ART/TWO.PIC']) and rows_are(o['pic'], 0x87))
    check('Left: the picture before, of the same folder', screen_is(o['prev'], art['ART/ONE.PIC']))
    b = o['back']
    check('Esc: Pinboard again in 4 colors, in the ART folder',
          b.ram[0x5A20] == 0x85 and b.has('{ ART') and b.chosen() == 'TWO.PIC')

    bare = {k: v for k, v in files.items() if k != 'PHOTO.PLC'}
    bnames = [e[0] for e in sdimage.listdir(sdimage.make(bare))]
    s = Script()
    for _ in range(bnames.index('PHOTOS')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.wait(40)
    s.key(K_ENTER)
    s.shot('none', 60)
    s.key(K_DOWN)
    s.key(K_BKSP)
    s.shot('root', 40)
    o = s.run(bare, png=args.png, tag='11c_')
    n = o['none']
    check('no PHOTO.PLC on the card: Files says so and stays in the folder',
          n.has('Its program is not on the card', 29) and n.has('{ PHOTOS', 2) and n.chosen() == photos[0])
    check('and Backspace still goes up', o['root'].has('{ \\', 2))

    # ---- 12: the Editor's text run in BASIC -----------------------------
    print('12. Ctrl+B: the text run in BASIC, and back')
    bas = dict(files)
    bas['HELLO.BAS'] = b'10 PRINT "HI FROM BASIC"\r\n20 A=6*7\r\n30 PRINT A\r\n'
    bas['ART/NOTE.TXT'] = b'a folder\r\n'
    bas['ART/LOOP.BAS'] = b'10 PRINT "LOOPING"\n20 GOTO 20\n'
    bimg = sdimage.make(bas)
    bnames = [e[0] for e in sdimage.listdir(bimg)]
    blist = [e[0] for e in sdimage.listdir(bimg, 'ART') if not e[0].startswith('.')]

    def btext(scr, n=4):
        return [r.rstrip() for r in scr.rows if r.strip()][:n]

    s = Script()
    for _ in range(bnames.index('HELLO.BAS')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.wait(60)
    s.key(K_DOWN)
    s.chord(K_CTRL, CALC_KEYS['e'])
    s.type('+1')
    s.shot('edited')
    s.chord(K_CTRL, CALC_KEYS['b'])
    s.shot('ran', 500)
    s.type('print a*2\n')
    s.shot('typed', 60)
    s.chord(K_CTRL, CALC_KEYS['b'])
    s.shot('back', 400)
    s.type('z')
    s.shot('cursor')
    s.key(K_TAB)
    s.shot('files', 40)
    o = s.run(bas, png=args.png, tag='12_')
    want = b'10 PRINT "HI FROM BASIC"\r\n20 A=6*7+1\r\n30 PRINT A\r\n'
    r = o['ran']
    check('Ctrl+B saves the text', o['edited'].has('HELLO.BAS *', 11)
          and sdimage.read(s.card, 'HELLO.BAS') == want)
    check('and BASIC runs it', r.has('PLACARD BASIC', 0) and r.has('HI FROM BASIC') and r.has('43')
          and r.has('Ready (EXIT or Ctrl+B: Pinboard)') and not r.has('Pinboard ', 58))
    check('BASIC takes commands after it', o['typed'].has('86'))
    b = o['back']
    check('Ctrl+B in BASIC: the Editor again, with the text',
          b.has(' Pinboard ', 58) and b.has('* Editor', 10) and b.has('HELLO.BAS', 11)
          and not b.has('HELLO.BAS *', 11)
          and text(b, 3) == ['10 PRINT "HI FROM BASIC"', '20 A=6*7+1', '30 PRINT A'])
    check('and the cursor where it was', text(o['cursor'], 3)[1] == '20 A=6*7+1z')
    check('the Files card as it was', o['files'].has('{ \\', 2) and o['files'].chosen() == 'HELLO.BAS')

    s = Script()                        # from a folder; Esc stops it; DIR, DOS
    for _ in range(bnames.index('ART')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.wait(40)
    for _ in range(blist.index('LOOP.BAS')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.wait(60)
    s.chord(K_CTRL, CALC_KEYS['b'])
    s.shot('loop', 500)
    s.key(K_ESC, hold=20)
    s.shot('break', 60)
    s.type('dir\n')
    s.shot('dir', 120)
    s.type('dos\n')
    s.shot('back', 400)
    s.key(K_TAB)
    s.shot('files', 40)
    o = s.run(bas, png=args.png, tag='12b_')
    check('a program in a folder runs', o['loop'].has('LOOPING') and not o['loop'].has('Ready'))
    check('Esc stops it and stays in BASIC', o['break'].has('Break in 20')
          and o['break'].has('Ready (EXIT or Ctrl+B: Pinboard)'))
    check('BASIC\'s DIR is the program\'s folder', o['dir'].has('LOOP.BAS') and o['dir'].has('NOTE.TXT')
          and not o['dir'].has('PINBOARD'))
    b = o['back']
    check('DOS: the Editor again', b.has('* Editor', 10) and b.has('LOOP.BAS', 11)
          and text(b, 2) == ['10 PRINT "LOOPING"', '20 GOTO 20'])
    check('and Files in the folder', o['files'].has('{ ART', 2) and o['files'].chosen() == 'LOOP.BAS')

    s = Script()                        # a new text: its name is asked first
    launcher(s, 3)
    s.type('10 print 5*5\n')
    s.chord(K_CTRL, CALC_KEYS['b'])
    s.shot('ask')
    s.type('five.bas\n')
    s.shot('ran', 500)
    s.type('exit\n')
    s.shot('back', 400)
    o = s.run(bas, png=args.png, tag='12c_')
    check('a new text asks for its name', o['ask'].has('Save as: _', 11))
    check('then it is saved and run', sdimage.read(s.card, 'FIVE.BAS') == b'10 print 5*5\r\n'
          and o['ran'].has('25') and o['ran'].has('Ready (EXIT or Ctrl+B: Pinboard)'))
    check('EXIT comes back', o['back'].has('FIVE.BAS', 11) and text(o['back'], 1) == ['10 print 5*5'])

    s = Script()                        # the launcher's BASIC: empty, and EXIT comes back
    for _ in range(bnames.index('ART')):
        s.key(K_DOWN)
    s.key(K_ENTER)
    s.wait(40)
    s.key(K_DOWN)
    launcher(s, 6)
    s.shot('basic', 300)
    s.type('exit\n')
    s.shot('back', 400)
    o = s.run(bas, png=args.png, tag='12d_')
    check('the launcher\'s BASIC starts with no program',
          o['basic'].has('PLACARD BASIC', 0) and btext(o['basic'], 3)[2] == 'Ready')
    b = o['back']
    check('EXIT: Pinboard again, Files in its folder, no Editor',
          b.has(' Pinboard ', 58) and b.has('{ ART', 2) and b.chosen() == blist[1]
          and not b.has('Editor'))

    print('PASS' if check.ok else 'FAIL')
    return 0 if check.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
