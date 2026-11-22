#!/usr/bin/env python3
"""
test_web.py - the web browser: the module's code (src/firmware/wifi_card/:
browser.cpp, html.cpp, image.cpp, built for this computer by wifi_host.py)
on a made-up web, and WEB.PLC (web.masm) in the web emulator's core with a
WiFi card whose module runs that same code

    python3 test_web.py                the checks below
    python3 test_web.py --png DIR      also the screens as DIR/*.png

Needs node (pinboard_emu.py runs web/placard_emu.js), g++ and Pillow (the
test's pictures).

The module's code alone (wifi_host.Host):
  A1. a page's HTML into lines: the title, wrapping at 76, bold, links,
      lists, entities and letters with accents, what is not shown
  A2. HTTP: a redirect, a chunked body, a gzip body, plain HTTP when a
      site has no HTTPS, a site that is not there
  A3. links: their addresses, the page a link opens, back to the line the
      page was at, words typed are searched for
  A4. pictures: PNG, JPEG and GIF in the page as 1 bit a pixel and alone
      in 256 colors, 80 and 160 across; a file that is no picture
  A5. a long page comes in parts

WEB.PLC in the emulator:
  B1. BOOT.CFG = WEB.PLC, the network the module kept: an address typed,
      and every line on the screen is the module's line
  B2. the page's picture arrives: its pixels on the screen, the lines
      under it moved down
  B3. Tab and Left choose links (white on black, the address in the
      rail), Enter opens one, Backspace comes back
  B4. Down, Space, B, Home move the page; Tab past the screen's last link
      goes on a screen, to its first link
  B5. a picture alone: 80 across, H for 160 across (rev B), a key for
      the page
  B6. the mouse: a click on a link, the right button for back, the pin
      for the DOS
  B7. no network kept: the name and password asked for; a wrong
      password; no card; a module with the 1.0 firmware
  B8. Pinboard: Enter on WEB.PLC in Files, and the pin brings Pinboard
      back
  B9. sdcard/WEB.PLC is web.asm

Date: 11/22/2026
"""

import argparse
import gzip
import io
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402
import gen_pinboard           # noqa: E402
import wifi_host              # noqa: E402
import test_pinboard as tp    # noqa: E402

REPO = os.path.join(HERE, '..', '..')
SD = os.path.join(REPO, 'sdcard')
PX = 0x67                   # web.masm: wb_pxl, the pointer's X and Y
COLS, LINES, PITCH = 76, 43, 10
FONT = gen_pinboard.font_rows()
K_SPACE, K_G, K_B, K_H, K_R = 0x29, 0x34, 0x32, 0x33, 0x2D


# ---- the made-up web --------------------------------------------------------
def picture(kind, w, h, color=None):
    from PIL import Image, ImageDraw
    im = Image.new('RGB', (w, h), color or (0, 0, 0))
    if color is None:
        for y in range(h):
            for x in range(w):
                im.putpixel((x, y), (x * 255 // w, y * 255 // h, 128))
        d = ImageDraw.Draw(im)
        d.ellipse((w // 4, h // 4, 3 * w // 4, 3 * h // 4), fill=(255, 220, 0), outline=(0, 0, 0))
        d.rectangle((2, 2, w - 3, h - 3), outline=(255, 255, 255))
    b = io.BytesIO()
    if kind == 'GIF':
        im = im.convert('P', palette=Image.ADAPTIVE)
    im.save(b, kind)
    return b.getvalue()


PARA = ' '.join('Word%d of a long paragraph that fills the lines of the page.' % i for i in range(140))
HOME = ('<html><head><title>The Placard test site</title><style>p { color: red }</style>'
        '<script>var hidden = "not shown";</script></head><body><h1>Welcome</h1>'
        '<p>This is <b>bold text</b> and a <a href="/two">link to page two</a>, then '
        '<a href="long.html">a longer link that should wrap over the end of the line into the next one for sure</a>.</p>'
        '<p><img src="/pic.png" alt="A sun"></p>'
        '<ul><li>One &amp; two &lt;three&gt; caf&eacute; naïve “quoted”</li>'
        '<li><a href="/pic.png">The picture alone</a></li></ul>'
        '<p style="display:none">Hidden words</p>'
        '<p>' + PARA + '</p><p><a href="/two">Last link</a></p></body></html>').encode('utf-8')
TWO = b'<html><title>Page two</title><body><p>Second page. <a href="/">Home</a></p></body></html>'
LONG = ('<html><title>Long</title><body>' +
        ''.join('<p>Paragraph %d of the long page.</p>' % i for i in range(1500)) + '</body></html>').encode()
CHUNKED = (b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\n\r\n'
           b'1e\r\n<html><title>Chunks</title><p>\r\n' b'10\r\nIn three pieces.\r\n' b'0\r\n\r\n')
GZ = gzip.compress(b'<html><title>Packed</title><p>This page came packed with gzip.</p></html>')


def sites(folder):
    wifi_host.make_sites(folder, {
        'https://a.test/': HOME,
        'https://a.test/two': TWO,
        'https://a.test/long.html': LONG,
        'https://a.test/pic.png': picture('PNG', 200, 120),
        'https://a.test/pic.jpg': picture('JPEG', 320, 200),
        'https://a.test/pic.gif': picture('GIF', 64, 48),
        'https://a.test/red.png': picture('PNG', 40, 40, (255, 0, 0)),
        'https://a.test/not.png': (b'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n', b'this is no picture at all'),
        'https://a.test/pics': b'<html><title>Pictures</title><p>A <img src="pic.jpg" alt="J"> B <img src="pic.gif" alt="G"></p></html>',
        'https://a.test/old': b'HTTP/1.1 301 Moved\r\nLocation: /two\r\nContent-Length: 0\r\n\r\n',
        'https://a.test/chunks': CHUNKED,
        'https://a.test/gz': (b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\n', GZ),
        'http://plain.test/': b'<html><title>Plain</title><p>No HTTPS here.</p></html>',
        'https://html.duckduckgo.com/html/?q=two+words': b'<html><title>two words at DuckDuckGo</title><p>Found.</p></html>',
    })


def host(folder):
    h = wifi_host.Host(sites=folder)
    h.view(COLS, PITCH, True)
    return h


# ---- the screen's page: 43 lines of 76 characters, every 10 pixel rows ------
def looks():
    out = {}
    for c in range(0x7E, 0x1F, -1):
        inv = tuple(FONT[k][c | 0x80] for k in range(8))
        out[tuple(g & ((g << 1 | 1) & 0xFF) for g in inv)] = (chr(c), 'bold')
    for c in range(0x7E, 0x1F, -1):
        out[tuple(FONT[k][c] for k in range(8))] = (chr(c), 'chosen')
    for c in range(0x7E, 0x1F, -1):
        out[tuple(FONT[k][c | 0x80] for k in range(8))] = (chr(c), '')
    return out


LOOK = looks()


class Page:
    """the page on a screen: text[n], and for every line the columns that
    are bold, underlined (links) and white on black (the link chosen); a
    cell that is no character is '?' (a picture's pixels, the pointer)"""

    def __init__(self, ram):
        self.ram = ram
        self.text, self.bold, self.under, self.chosen = [], [], [], []
        for n in range(LINES):
            t, b, u, s = '', set(), set(), set()
            for c in range(COLS):
                cell = self.cell(n, c)
                ch, how = LOOK.get(tuple(cell[:8]), ('?', ''))
                t += ch
                if how == 'bold':
                    b.add(c)
                if how == 'chosen' and cell[8] == 0:
                    s.add(c)
                if cell[9] == 0:
                    u.add(c)
            self.text.append(t.rstrip())
            self.bold.append(b)
            self.under.append(u)
            self.chosen.append(s)

    def cell(self, n, c):
        a = 0x6020 + (c + 2) * 512 + 24 + PITCH * n
        return self.ram[a:a + PITCH]

    def find(self, text):
        for n, t in enumerate(self.text):
            if text in t:
                return n, t.index(text)
        return None

    def chosen_text(self):
        return ' '.join(''.join(self.text[n][c] for c in sorted(self.chosen[n])) for n in range(LINES) if self.chosen[n])


def rail(scr):
    return scr.rows[59].strip()


def title(scr):
    return scr.rows[0][2:].strip()


def same_lines(pg, h, lines, top=0):
    """the screen's lines against the module's from `top`: the problems"""
    bad = []
    for n in range(LINES):
        if top + n >= lines:
            want = ''
        else:
            r = h.row(top + n)
            if isinstance(r, dict):
                for c, col in enumerate(r['cols']):
                    if bytes(pg.cell(n, c)) != bytes(col):
                        bad.append('line %d: the picture\'s pixels at column %d' % (n, c))
                        break
                continue
            want = r[0]
            if pg.bold[n] != set(c for c in r[2] if r[0][c] != ' ') - pg.chosen[n] and not pg.chosen[n]:
                bad.append('line %d: bold %s' % (n, sorted(pg.bold[n])))
            under = set(c for a, e, _ in r[1] for c in range(a, e))
            if pg.under[n] != under:
                bad.append('line %d: underlined %s, links %s' % (n, sorted(pg.under[n]), sorted(under)))
        if pg.text[n] != want.rstrip():
            bad.append('line %d: %r, the module\'s %r' % (n, pg.text[n], want))
    return bad[:3]


# ---- the module's code alone ------------------------------------------------
def module_checks(check, folder):
    print('A1. HTML into lines')
    h = host(folder)
    p = h.go('a.test')
    lines = h.text(p['lines'])
    check('the title and the address', h.info(0) == 'The Placard test site' and h.info(1) == 'https://a.test')
    check('no line is longer than 76, the paragraph fills its lines',
          max(len(t) for t in lines) <= COLS and sum(1 for t in lines if len(t) > 66) > 20)
    n = next(i for i, t in enumerate(lines) if 'bold text' in t)
    text, links, bold = h.row(n)
    a = text.index('bold text')
    check('bold, and a link\'s place in its line', bold == set(range(a, a + 9))
          and (text.index('link to page two'), text.index('link to page two') + 16) in [(x, y) for x, y, _ in links])
    wrapped = [i for i in (n, n + 1) if any('longer link' in h.row(i)[0][x:y] or 'for sure' in h.row(i)[0][x:y]
                                            for x, y, _ in h.row(i)[1])]
    check('a link over two lines is the same link in both', wrapped == [n, n + 1]
          and len({k for i in wrapped for _, _, k in h.row(i)[1]} & {h.row(n)[1][-1][2]}) == 1
          and h.row(n)[1][-1][2] == h.row(n + 1)[1][0][2])
    check('the list, entities, accents and quotes folded to ASCII',
          any(t.strip() == '* One & two <three> cafe naive "quoted"' for t in lines))
    check('scripts, styles and hidden text are left out',
          not any(w in ' '.join(lines) for w in ('not shown', 'color: red', 'Hidden words')))
    check('the picture has a line of its own with its words', any('[picture: A sun]' in t for t in lines))

    print('A2. HTTP')
    h.go('a.test/old')
    check('a redirect is followed', h.info(0) == 'Page two' and h.info(1) == 'https://a.test/two')
    p = h.go('a.test/chunks')
    check('a chunked body', h.info(0) == 'Chunks' and h.text(p['lines'])[0] == 'In three pieces.')
    p = h.go('a.test/gz')
    check('a gzip body', h.info(0) == 'Packed' and h.text(p['lines'])[0] == 'This page came packed with gzip.')
    p = h.go('plain.test')
    check('a site with no HTTPS: plain HTTP', h.info(0) == 'Plain' and h.info(1) == 'http://plain.test')
    p = h.go('nowhere.test')
    t = h.text(p['lines'])
    check('a site that is not there: a page that says so (%s)' % h.info(2),
          p['flags'] & 4 and 'can\'t be shown' in t[0] and 'Could not reach nowhere.test' in h.info(2))
    p = h.go('a.test/none')
    check('a page that is not there (%s)' % h.info(2), p['flags'] & 4 and '404' in h.info(2))

    print('A3. links')
    p = h.go('a.test')
    n = next(i for i in range(p['lines']) if not isinstance(h.row(i), dict) and 'link to page two' in h.row(i)[0])
    ids = [k for _, _, k in h.row(n)[1]]
    adr = [h.command(wifi_host.C_LINKINFO, bytes([k & 255, k >> 8]))[1].decode() for k in ids]
    check('the links\' addresses, a relative one too', adr == ['https://a.test/two', 'https://a.test/long.html'])
    p2 = h.link(ids[0], top=7)
    check('a link opens its page; it can go back', h.info(0) == 'Page two' and p2['flags'] & 8)
    p3 = h.back()
    check('back: the page, at the line it was left at', h.info(0) == 'The Placard test site' and p3['top'] == 7)
    for _ in range(9):
        h.go('a.test/two')
    backs = [h.back() for _ in range(9)]
    check('the module keeps 8 pages to go back to; with nothing before: can\'t',
          all(b is not None for b in backs[:-1]) and backs[-1] is None)
    h.go('two words')
    check('words typed are searched for', h.info(0) == 'two words at DuckDuckGo')

    print('A4. pictures')
    p = h.go('a.test/pics')
    before = p['lines']
    after = h.images()
    strips = [h.row(i) for i in range(after) if isinstance(h.row(i), dict)]
    widths = sorted({len(s['cols']) for s in strips})
    check('a JPEG and a GIF in the page: strips of pixels, %d lines more' % (after - before),
          p['pending'] == 2 and widths == [8, 40] and len(strips) == 20 + 5)
    mid = [s for s in strips if len(s['cols']) == 40][10]['cols']
    ink = sum(bin(b ^ 0xFF).count('1') for c in mid for b in c)
    check('dithered: neither white nor black (%d of %d pixels black)' % (ink, 40 * 80), 400 < ink < 2800)
    p = h.go('a.test')
    h.images()
    n = next(i for i in range(60) if not isinstance(h.row(i), dict) and '[picture: A sun]' in h.row(i)[0])
    pic = h.row(n)[1][0][2]
    check('the picture\'s line is a link to it, pictures are 8000 and up', pic >= 0x8000
          and isinstance(h.row(n - 1), dict) and len(h.row(n - 1)['cols']) == 25)
    for wide, name in ((False, 80), (True, 160)):
        rows = h.picture(pic, wide)
        ok = isinstance(rows, list) and len(rows) == 240 and len(rows[0]) == name
        used = [y for y in range(240) if any(rows[y])] if ok else []
        colors = len({b for r in rows for b in r}) if ok else 0
        yellow = rows[120][name // 2] if ok else -1
        # GGG BB RRR: the middle is yellow (green and red full, no blue)
        check('alone, %d across: 240 rows, its shape kept (rows %d-%d), %d colors, yellow in the middle (%02X)'
              % (name, used[0] if used else -1, used[-1] if used else -1, colors, yellow),
              ok and 20 < used[0] < 40 and 200 < used[-1] < 220 and colors > 40
              and yellow >> 5 >= 6 and yellow & 7 >= 6 and (yellow >> 3 & 3) == 0)
    h.go('a.test/red.png')
    rows = h.picture(0xFFFF, False)
    check('an address that is a picture: shown alone; red is red',
          isinstance(rows, list) and rows[120][40] & 7 == 7 and rows[120][40] >> 3 == 0)
    h.go('a.test/not.png')
    why = h.picture(0xFFFF, False)
    check('a file that is no picture: the reason (%s)' % (why if isinstance(why, str) else '?'), isinstance(why, str) and why)

    print('A5. a long page')
    p = h.go('a.test/long.html')
    t = h.text(p['lines'])
    more = h.row(p['lines'] - 1)
    check('its first part ends in a link to the next (%d lines)' % p['lines'],
          t[0] == 'Paragraph 0 of the long page.' and p['lines'] <= 1400 and more[0] == '[More of this page]'
          and more[1][0][2] == 0xFFFE)
    last = int([x for x in t if x.startswith('Paragraph')][-1].split()[1])
    p = h.link(0xFFFE)
    t = h.text(p['lines'])
    check('the next part goes on where the first ended (paragraph %d)' % (last + 1),
          t[0] == 'Paragraph %d of the long page.' % (last + 1) and t[-1] == '[More of this page]')
    last = int([x for x in t if x.startswith('Paragraph')][-1].split()[1])
    p = h.link(0xFFFE)
    t = h.text(p['lines'])
    check('and the last part ends with the page',
          t[0] == 'Paragraph %d of the long page.' % (last + 1) and t[-1] == 'Paragraph 1499 of the long page.')
    h.back()
    p = h.back()
    check('back is the first part', h.text(1)[0] == 'Paragraph 0 of the long page.')
    h.close()


# ---- WEB.PLC ------------------------------------------------------------------
def park(s):
    """the pointer out of the page's columns"""
    s.move(636, 440)


def line_xy(n, c):
    """the pointer's place for column c of page line n on the screen"""
    return (c + 2) * 8 + 4, 24 + PITCH * n + 4


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    if args.png:
        os.makedirs(args.png, exist_ok=True)
    check = tp.Checks()
    folder = tempfile.mkdtemp()
    sites(folder)
    module_checks(check, folder)

    lib = ps.assemble(open(os.path.join(HERE, 'rom32.asm')).read(), HERE)[0]
    prog, psyms, _ = ps.assemble(open(os.path.join(HERE, 'web.asm')).read(), HERE)
    plc = gen_plc.make(prog, psyms, lib)[0]
    dos = open(os.path.join(SD, 'DOS.PLC'), 'rb').read()
    base = {'DOS.PLC': dos, 'WEB.PLC': plc, 'BOOT.CFG': b'WEB.PLC\r\n'}
    card = {'slot': 3, 'sites': folder, 'networks': {'home': 'secret12'}, 'saved': ['home', 'secret12']}

    def run(s, tag, files=base, wifi=card, rev_b=False):
        return s.run(files, png=args.png, tag=tag, px=PX, wifi=wifi, rev_b=rev_b)

    # ---- B1, B2: a page, its picture ---------------------------------------
    print('B1. an address typed')
    h = host(folder)
    p = h.go('a.test')
    s = tp.Script()
    s.t = 160
    s.shot('ask', 10)
    park(s)
    s.type('a.test\n')
    s.shot('page', 60)
    o = run(s, 'web1_')
    check('it asks for an address', 'Type an address' in rail(o['ask']) and o['ask'].rows[0][0] == '*')
    check('the title, the address, the keys in the rail',
          title(o['page']) == 'The Placard test site' and o['page'].rows[1].strip() == 'https://a.test'
          and o['page'].rows[58].strip().startswith('Arrows, Space, B: move  Tab: link'))
    print('B2. the page\'s picture')
    lines = h.images()
    pg = Page(o['page'].ram)
    late = pg.find('[picture: A sun]')
    bad = same_lines(pg, h, lines)
    check('every line on the screen is the module\'s, the picture\'s 12 lines of pixels too: %s' % (bad or 'yes'),
          not bad and lines == p['lines'] + 12 and late and late[0] == 17 and rail(o['page']) == '')

    # ---- B3: links ---------------------------------------------------------
    print('B3. links')
    s = tp.Script()
    s.t = 160
    park(s)
    s.type('a.test\n')
    s.wait(60)
    s.key(tp.K_TAB)
    s.shot('tab1')
    s.key(tp.K_TAB)
    s.shot('tab2')
    s.key(tp.K_TAB)
    s.shot('tab3')
    s.key(tp.K_LEFT)
    s.key(tp.K_LEFT)
    s.shot('left')
    s.key(tp.K_ENTER)
    s.shot('two', 40)
    s.key(tp.K_TAB)
    s.shot('twotab')
    s.key(tp.K_BKSP)
    s.shot('back', 70)
    s.key(tp.K_BKSP)
    s.shot('nomore', 40)
    o = run(s, 'web3_')
    t1, t2, t3 = (Page(o[k].ram) for k in ('tab1', 'tab2', 'tab3'))
    check('Tab: the first link white on black, its address in the rail',
          t1.chosen_text() == 'link to page two' and rail(o['tab1']) == 'https://a.test/two')
    check('Tab again: the link that is in two lines, both chosen, the first as it was',
          t2.chosen_text() == 'a longer link that should wrap over the end of the line into the next one for sure'
          and rail(o['tab2']) == 'https://a.test/long.html' and len([n for n in range(LINES) if t2.chosen[n]]) == 2)
    check('and again: the picture\'s line (%s)' % t3.chosen_text(), t3.chosen_text() == '[picture: A sun]')
    check('Left twice: the first again', Page(o['left'].ram).chosen_text() == 'link to page two')
    two = Page(o['two'].ram)
    check('Enter opens it', title(o['two']) == 'Page two' and two.text[0] == 'Second page. Home'
          and two.under[0] == set(range(13, 17)))
    check('Backspace: the page before, with its picture', title(o['back']) == 'The Placard test site'
          and not same_lines(Page(o['back'].ram), h, lines))
    check('Backspace with no page before: it says so', 'no page before' in rail(o['nomore']))

    # ---- B4: moving ----------------------------------------------------------
    print('B4. moving in the page')
    s = tp.Script()
    s.t = 160
    park(s)
    s.type('a.test\n')
    s.wait(60)
    s.key(tp.K_DOWN)
    s.shot('down')
    s.key(K_SPACE)
    s.shot('space')
    s.key(K_SPACE)
    s.key(K_SPACE)
    s.shot('end')
    s.key(tp.K_UP)
    s.shot('up')
    s.key(K_B)
    s.shot('b')
    s.key(tp.K_HOME)
    s.shot('home')
    for _ in range(5):
        s.key(tp.K_TAB)
    s.shot('tabs', 40)
    for _ in range(3):
        s.key(tp.K_TAB)
    s.shot('tabs2', 40)
    o = run(s, 'web4_')
    last = max(0, lines - LINES)
    for name, top in (('down', 3), ('space', min(43, last)), ('end', last), ('up', last - 3),
                      ('b', max(0, last - 43)), ('home', 0)):
        bad = same_lines(Page(o[name].ram), h, lines, top)
        check('%s: from line %d: %s' % (name, top, bad or 'yes'), not bad)
    tb, tb2 = Page(o['tabs'].ram), Page(o['tabs2'].ram)
    check('Tab past the screen\'s last link: the next screen (it has no link)',
          tb.chosen_text() == '' and not same_lines(tb, h, lines, 40))
    check('and on to the last screen, its link chosen (%s)' % tb2.chosen_text(),
          tb2.chosen_text() == 'Last link' and last > 83 and rail(o['tabs2']) == 'https://a.test/two')

    # ---- B5: a picture alone -------------------------------------------------
    print('B5. a picture alone')
    n = next(i for i in range(60) if not isinstance(h.row(i), dict) and '[picture: A sun]' in h.row(i)[0])
    pic = h.row(n)[1][0][2]
    p80, p160 = h.picture(pic, False), h.picture(pic, True)
    s = tp.Script()
    s.t = 160
    park(s)
    s.type('a.test\n')
    s.wait(60)
    for _ in range(3):
        s.key(tp.K_TAB)
    s.key(tp.K_ENTER)
    s.shot('pic80', 80)
    s.key(K_H)
    s.shot('pic160', 100)
    s.key(K_SPACE)
    s.shot('after', 60)
    s.type('g')
    s.wait(10)
    s.type('a.test/red.png\n')
    s.shot('red', 80)
    s.key(K_SPACE)
    s.shot('redback', 70)
    o = run(s, 'web5_', rev_b=True)

    def shown(ram, rows, wide):
        for y in range(240):
            low = 32 + 2 * y if y < 112 else 2 * y - 223
            for c in range(len(rows[0])):
                page = 0x60 + c if wide else 0x61 + 2 * c
                if ram[page * 256 + low] != rows[y][c]:
                    return 'row %d, column %d' % (y, c)
        return ''
    r80, r160 = o['pic80'].ram, o['pic160'].ram
    bad = shown(r80, p80, False)
    check('Enter on a picture\'s line: every row 8 bits a pixel and 2x, the module\'s 80 x 240 bytes: %s' % (bad or 'yes'),
          not bad and all(b == 0x07 for b in r80[0x5A20:0x5C00]))
    bad = shown(r160, p160, True)
    check('H: 160-read rows, the module\'s 160 x 240 bytes: %s' % (bad or 'yes'),
          not bad and all(b == 0x87 for b in r160[0x5A20:0x5C00]))
    check('a key: the page again, its link still chosen', not any(o['after'].ram[0x5A20:0x5BE8])
          and title(o['after']) == 'The Placard test site' and Page(o['after'].ram).chosen_text() == '[picture: A sun]')
    red = o['red'].ram
    check('G and a picture\'s address: the picture alone, red', red[0x5A20] == 0x87 and red[(0x60 + 80) * 256 + 2 * 120 - 223] == 0x07)
    check('a key: the page before it', title(o['redback']) == 'The Placard test site')

    # ---- B6: the mouse -------------------------------------------------------
    print('B6. the mouse')
    n2, c2 = pg.find('link to page two')
    s = tp.Script()
    s.t = 160
    park(s)
    s.type('a.test\n')
    s.wait(60)
    s.move(*line_xy(n2, c2 + 3))
    s.shot('over')
    s.down()
    s.up()
    s.shot('clicked', 40)
    s.b = 2
    s.inp.append((s.t, 'goto', (s.x, s.y, 2)))
    s.t += 12
    s.up()
    s.shot('right', 70)
    s.move(*line_xy(20, 70))
    s.down()
    s.up()
    s.shot('nolink', 30)
    s.move(6, 4)
    s.down()
    s.up()
    s.shot('pin', 60)
    o = run(s, 'web6_')
    check('the pointer is on the page', len(o['over'].pointer()) > 0 or '?' in ''.join(Page(o['over'].ram).text))
    check('a click on a link opens it', title(o['clicked']) == 'Page two')
    check('the right button: back', title(o['right']) == 'The Placard test site')
    check('a click on no link: nothing', title(o['nolink']) == 'The Placard test site')
    check('a click on the pin: the DOS is back', o['pin'].has('WEB.PLC') and not o['pin'].has('Arrows, Space', 58))

    # ---- B7: joining, no card, old firmware ---------------------------------
    print('B7. the network, the card')
    s = tp.Script()
    s.t = 160
    s.shot('name', 30)
    s.type('home\n')
    s.shot('pass', 20)
    s.type('wrong\n')
    s.shot('failed', 100)
    s.wait(90)
    s.type('home\n')
    s.wait(20)
    s.type('secret12\n')
    s.shot('joined', 150)
    s.type('a.test/two\n')
    s.shot('page', 50)
    o = run(s, 'web7_', wifi=dict(card, saved=None))
    check('no network kept: it asks for the name, then the password',
          'network\'s name' in rail(o['name']) and 'password' in rail(o['pass']))
    check('a wrong password: it says so and asks again', 'Could not join' in rail(o['failed']))
    check('the right one: joined, an address asked for, a page', 'Type an address' in rail(o['joined'])
          and title(o['page']) == 'Page two')
    s = tp.Script()
    s.t = 160
    s.shot('none', 40)
    o = run(s, 'web7b_', wifi=None)
    check('no card: the message', 'no WiFi card' in rail(o['none']))
    s = tp.Script()
    s.t = 160
    s.shot('old', 60)
    s.key(tp.K_ESC)
    s.shot('esc', 60)
    o = run(s, 'web7c_', wifi={k: v for k, v in card.items() if k != 'sites'})
    check('a module with the 1.0 firmware: the message; Esc: the DOS', 'needs 1.1' in rail(o['old'])
          and o['esc'].has('WEB.PLC') and not o['esc'].has('Arrows, Space', 58))

    # ---- B8: Pinboard --------------------------------------------------------
    print('B8. Pinboard')
    files = sdimage.from_folder(SD)
    files['BOOT.CFG'] = b'PINBOARD.PLC\r\n'
    files['WEB.PLC'] = plc
    names = [e[0] for e in sdimage.listdir(sdimage.make(files))]
    s = tp.Script()
    for _ in range(names.index('WEB.PLC')):
        s.key(tp.K_DOWN)
    s.shot('chosen')
    s.key(tp.K_ENTER)
    s.wait(120)
    s.type('a.test/two\n')
    s.shot('page', 60)
    s.move(6, 4)
    s.down()
    s.up()
    s.shot('pinboard', 150)
    o = s.run(files, png=args.png, tag='web8_', wifi=card)
    check('Enter on WEB.PLC in Files: the browser, with the mouse\'s pointer', o['chosen'].chosen() == 'WEB.PLC'
          and title(o['page']) == 'Page two')
    check('the pin: Pinboard is back', o['pinboard'].has(' Pinboard ', 58) and o['pinboard'].chosen() == 'WEB.PLC')

    # ---- B9 --------------------------------------------------------------------
    print('B9. sdcard/')
    check('sdcard/WEB.PLC is web.asm', open(os.path.join(SD, 'WEB.PLC'), 'rb').read() == plc)
    h.close()
    shutil.rmtree(folder, ignore_errors=True)
    print('PASS' if check.ok else 'FAIL')
    return 0 if check.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
