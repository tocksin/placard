#!/usr/bin/env python3
"""
wifi_host.py - the WiFi module's browser for the simulators

The browser's work is done in the module (src/firmware/wifi_card/:
browser.cpp, html.cpp, image.cpp).  The simulators have no module, so
they run the same code built for this computer, host/wifi_host.cpp.
This builds that program (g++, once; again when a source changes) and
talks to it.

    h = Host(sites=DIR)             the web is the files of DIR (make_sites)
    h = Host(live=True)             the real web
    status, data = h.command(0x31, b'\0\0example.com')

    python3 wifi_host.py ADDRESS [LINES]        a page of the real web as
                                                the Placard gets it
    python3 wifi_host.py ADDRESS --png OUT.png  and as a picture of its
                                                first screens

make_sites(DIR, {address: bytes or (head, body)}) writes the files of a
made-up web: each address's whole reply (status line and headers too),
or a body that gets "200 OK" and its length.

Date: 11/22/2026
"""

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.join(HERE, '..', 'firmware', 'wifi_card')
SOURCES = ['host/wifi_host.cpp', 'browser.cpp', 'html.cpp', 'image.cpp']
HEADERS = ['browser.h', 'image.h']

C_VIEW, C_GO, C_LINK, C_BACK, C_RELOAD, C_INFO, C_ROW = 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36
C_IMGLOAD, C_LINKINFO, C_PICTURE, C_PICDATA, C_PICEND = 0x37, 0x38, 0x39, 0x3A, 0x3B


def build():
    """the path of the program, built when it is older than its sources"""
    out = os.path.join(tempfile.gettempdir(), 'placard_wifi_host')
    src = [os.path.join(FW, s) for s in SOURCES]
    newest = max(os.path.getmtime(os.path.join(FW, f)) for f in SOURCES + HEADERS)
    if not os.path.exists(out) or os.path.getmtime(out) < newest:
        tls = subprocess.run(['g++', '-std=c++11', '-O2', '-Wall', '-o', out] + src + ['-lssl', '-lcrypto'],
                             capture_output=True, text=True)
        if tls.returncode:                  # no OpenSSL here: without the real web
            r = subprocess.run(['g++', '-std=c++11', '-O2', '-Wall', '-DNO_TLS', '-o', out] + src,
                               capture_output=True, text=True)
            if r.returncode:
                raise RuntimeError('wifi_host does not build:\n' + r.stderr)
    return out


def make_sites(folder, pages):
    os.makedirs(folder, exist_ok=True)
    index = []
    for k, (address, what) in enumerate(pages.items()):
        if isinstance(what, tuple):
            head, body = what
            data = (head.encode() if isinstance(head, str) else head) + b'Content-Length: %d\r\n\r\n' % len(body) + body
        elif what.startswith(b'HTTP/'):
            data = what
        else:
            kind = (b'image/jpeg' if what[:2] == b'\xff\xd8' else b'image/png' if what[:2] == b'\x89P' else
                    b'image/gif' if what[:3] == b'GIF' else b'text/html; charset=utf-8')
            data = b'HTTP/1.1 200 OK\r\nContent-Type: ' + kind + b'\r\nContent-Length: %d\r\n\r\n' % len(what) + what
        name = 'f%03d.bin' % k
        open(os.path.join(folder, name), 'wb').write(data)
        index.append('%s\t%s\n' % (address, name))
    open(os.path.join(folder, 'index.txt'), 'w').write(''.join(index))
    log = os.path.join(folder, 'log.txt')
    if os.path.exists(log):
        os.remove(log)


class Host:
    def __init__(self, sites=None, live=False):
        args = ['--live'] if live else ['--sites', sites]
        self.p = subprocess.Popen([build()] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def command(self, c, d=b''):
        self.p.stdin.write(bytes([c, len(d)]) + bytes(d))
        self.p.stdin.flush()
        head = self.p.stdout.read(2)
        if len(head) < 2:
            raise RuntimeError('wifi_host stopped')
        return head[0], self.p.stdout.read(head[1])

    def close(self):
        self.p.stdin.close()
        self.p.wait()

    # ---- what the Placard's program does, in Python (for tests and pictures)
    def view(self, cols=76, pitch=10, pictures=True):
        self.cols, self.pitch = cols, pitch
        return self.command(C_VIEW, bytes([cols, pitch, 1 if pictures else 0]))

    def go(self, text, top=0):
        return self.page(self.command(C_GO, bytes([top & 255, top >> 8]) + text.encode()))

    def link(self, n, top=0):
        return self.page(self.command(C_LINK, bytes([n & 255, n >> 8, top & 255, top >> 8])))

    def back(self):
        return self.page(self.command(C_BACK))

    def page(self, reply):
        st, r = reply
        if st:
            return None
        return {'flags': r[0], 'lines': r[1] | r[2] << 8, 'pending': r[3], 'top': r[4] | r[5] << 8}

    def info(self, what=0):
        return self.command(C_INFO, bytes([what]))[1].decode('latin-1')

    def images(self):
        """fetch the page's pictures; the number of lines then"""
        while True:
            st, r = self.command(C_IMGLOAD)
            if st or not r[0]:
                return r[5] | r[6] << 8

    def row(self, n):
        """a line: (text, [(first column, end column, link)], bold columns)
        or the pixels of a strip of a picture: {'cols': [bytes of a byte
        column, top to bottom]}"""
        st, r = self.command(C_ROW, bytes([n & 255, n >> 8, 0]))
        if st:
            return None
        if r[0] == 1:
            cols, part = [], 0
            while True:
                for k in range(r[2]):
                    cols.append(r[4 + k * self.pitch:4 + (k + 1) * self.pitch])
                if r[3]:
                    return {'cols': cols}
                part += 1
                st, r = self.command(C_ROW, bytes([n & 255, n >> 8, part]))
        text, links, bold, cur, b, k = '', [], set(), None, False, 1
        while k < len(r):
            c = r[k]
            if c == 1:
                cur = [len(text), len(text), r[k + 1] << 8 | r[k + 2]]
                links.append(cur)
                k += 3
                continue
            if c == 2:
                cur = None
            elif c == 3:
                b = True
            elif c == 4:
                b = False
            else:
                if b:
                    bold.add(len(text))
                text += chr(c)
                if cur:
                    cur[1] = len(text)
            k += 1
        return text, [tuple(x) for x in links], bold

    def text(self, lines):
        out = []
        for n in range(lines):
            r = self.row(n)
            out.append('<pixels %d>' % (len(r['cols']) * 8) if isinstance(r, dict) else r[0])
        return out

    def picture(self, link, wide):
        """a picture alone: rows of color bytes, or the reason as text"""
        st, r = self.command(C_PICTURE, bytes([link & 255, link >> 8, 1 if wide else 0]))
        if st:
            return r.decode('latin-1')
        cols = [self.command(C_PICDATA, bytes([c]))[1] for c in range(r[0])]
        return [bytes(cols[c][y] for c in range(r[0])) for y in range(r[1])]


def screen_png(h, lines, path, first=0, rows=43, font=None):
    """the lines as the browser draws them: black on white, links
    underlined, 8 x 8 characters every `pitch` rows"""
    from PIL import Image
    if font is None:
        import gen_pinboard
        font = gen_pinboard.font_rows()
    img = Image.new('L', (h.cols * 8, rows * h.pitch), 255)
    px = img.load()
    for k in range(rows):
        if first + k >= lines:
            break
        r = h.row(first + k)
        y0 = k * h.pitch
        if isinstance(r, dict):
            for c, col in enumerate(r['cols']):
                for y, b in enumerate(col):
                    for bit in range(8):
                        px[c * 8 + bit, y0 + y] = 255 if b >> bit & 1 else 0
            continue
        text, links, bold = r
        for c, ch in enumerate(text):
            for y in range(8):
                b = font[y][ord(ch)]
                if c in bold:
                    b |= b << 1
                for bit in range(8):
                    if b >> bit & 1:
                        px[c * 8 + bit, y0 + y] = 0
        for a, e, _ in links:
            for x in range(a * 8, e * 8):
                px[x, y0 + 8] = 0
    img.save(path)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    h = Host(live=True)
    h.view()
    p = h.go(argv[1])
    print('title: %s\naddress: %s' % (h.info(0), h.info(1)))
    if p is None:
        print('no page')
        return 1
    if '--png' in argv:
        lines = h.images()
        screen_png(h, lines, argv[argv.index('--png') + 1], rows=min(lines, 130))
        return 0
    most = int(argv[2]) if len(argv) > 2 else p['lines']
    for line in h.text(min(most, p['lines'])):
        print('|' + line)
    print('%d lines' % p['lines'])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
