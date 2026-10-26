#!/usr/bin/env python3
"""
test_dos.py - run the DOS (dos.masm) in placard_sim with a card image

    python3 test_dos.py                 the checks below
    python3 test_dos.py --png dos.png   also the browser screen as a PNG

Builds the 32K ROM image from dos.asm as gen_rom.tcl does (build_rom), a
FAT16 card (sdimage.py) holding the demo .PLC files from ../../sdcard, two
small library programs made here, a folder, a text file and BOOT.CFG, and
boots it like the board with a PS/2 keyboard (io_devices) on the port:
  1. BOOT.CFG runs PARENT.PLC, which names itself in MB_PARENT and asks the
     DOS (dos_run) for HELLO.PLC; HELLO comes back (x8008), the DOS runs
     PARENT again, which comes back too: the browser
  2. the browser's screen: the title, the folder's entries and sizes
  3. Down and Enter open a folder, Backspace comes back up
  4. Enter on a text file: "Not a program"
  5. Enter on PI.PLC (a RAM image): RAM x0000-x49FF is the image when it
     starts (through MB_GO); Esc brings the browser back
  6. Del deletes the file, B writes BOOT.CFG
  7. the command line: SAVE, LOAD, DEL, CD, an unknown command
  8. Esc held at power-up skips BOOT.CFG
  9. no card: the browser with its message
The screen is read back through the font (LIB_FONT).

Date: 10/26/2026
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import io_devices             # noqa: E402
import sdimage                # noqa: E402
import gen_plc                # noqa: E402

FRAME = 525 * 800
MB = 0x5D00
MB_GO = MB + 0x28
SDCARD = os.path.join(HERE, '..', '..', 'sdcard')

PARENT_SRC = '''
#include "placard.asm"
#include "placard_lib.asm"
#addr 0x0100
main:
    ld   0x5D, y                ; the first run: MB_PARENT = this, run HELLO
    ld   0x11, x
    ld   [y,x], ac
    bne  second
    ld   1, [y,x]
    clr  ac
    ld   ac, [0x20]
cp:
    ld   [0x20], ac
    add  pname & 0xFF, x
    ld   pname >> 8, y
    ld   [y,x], ac
    ld   ac, [0x21]
    ld   [0x20], ac
    add  0x40, x
    ld   0x5D, y
    ld   [0x21], ac
    ld   ac, [y,x]
    beq  go
    ld   [0x20], ac
    inc
    ld   ac, [0x20]
    bra  cp
go:
    ld   hname & 0xFF, ac
    ld   ac, [R0]
    ld   hname >> 8, ac
    ld   ac, [R1]
    ld   0x80, y                ; dos_run
    jmp  0x0C
second:                         ; run again by the DOS: done
    ld   0x13, x
    ld   1, [y,x]
    ld   0x80, y                ; dos_back
    jmp  0x08
pname: #d "PARENT.PLC", 0x00
hname: #d "HELLO.PLC", 0x00
'''

HELLO_SRC = '''
#include "placard.asm"
#include "placard_lib.asm"
#addr 0x0200
main:
    ld   0x5D, y
    ld   0x12, x
    ld   0x42, [y,x]
    ld   0x80, y                ; dos_back
    jmp  0x08
'''


def plc(src, lib):
    mem, syms, _ = ps.assemble(src, HERE)
    data, kind, load, entry = gen_plc.make(mem, syms, lib)
    return data


class Rig:
    def __init__(self, rom, syms, lib, image):
        self.rom, self.syms = rom, syms
        self.port = io_devices.SharedPort()
        self.port.kbd = io_devices.Ps2Keyboard()
        if image is not None:
            self.port.sd = io_devices.SdCard(image)
        self.cpu = ps.Cpu({}, rom=rom, io=self.port)
        self.ok = True
        # the font, for reading the screen
        self.glyphs = {}
        for ch in range(0x20, 0x7F):
            rows = tuple(rom.get(ps.LIB_FONT + k * 256 + ch, 0) if hasattr(ps, 'LIB_FONT')
                         else rom.get(syms['LIB_FONT'] + k * 256 + ch, 0) for k in range(8))
            self.glyphs.setdefault(rows, chr(ch))
        # characters -> PS/2 set 2 codes, through the keyboard map and the decoder's table
        key2code = {}
        s2 = syms['ps2_set2']
        for code in range(0x84):
            k = rom[s2 + code]
            if k != 0xFF:
                key2code.setdefault(k, code)
        e0 = syms['ps2_e0']
        while rom[e0]:
            key2code.setdefault(rom[e0 + 1], 0x100 | rom[e0])
            e0 += 2
        self.codes = {}
        for key in range(64):
            ch = rom[syms['kbd_map'] + key]
            if ch and key in key2code:
                self.codes.setdefault(chr(ch), key2code[key])
        self.codes['\x7f'] = 0x171                    # Delete

    def fail(self, msg):
        self.ok = False
        print('FAIL:', msg)

    def at(self, name):
        a = self.syms[name]
        return self.cpu.pc == a and not (self.cpu.map >> (a >> 13)) & 1

    def run(self, frames):
        end = self.cpu.clocks + frames * FRAME
        while self.cpu.clocks < end:
            self.cpu.step()

    def run_until(self, cond, frames, what):
        end = self.cpu.clocks + frames * FRAME
        while self.cpu.clocks < end:
            self.cpu.step()
            if cond():
                return True
        self.fail('%s: not within %d frames (PC x%04X)' % (what, frames, self.cpu.pc))
        return False

    def wait_browser(self, frames=120):
        """the browser's key loop (after it drew the screen)"""
        return self.run_until(lambda: self.at('br_loop'), frames, 'the browser')

    def key(self, ch, hold=3):
        code = self.codes[ch]
        self.port.kbd.press(code)
        self.run(hold)
        self.port.kbd.release(code)
        self.run(hold)

    def type(self, text):
        for ch in text:
            self.key(ch)

    def row(self, r):
        """text row r of the screen (1 bpp rows)"""
        mem = self.cpu.mem
        out = ''
        for col in range(80):
            rows = tuple(mem[0x6020 + col * 512 + 8 * r + k] for k in range(8))
            out += self.glyphs.get(rows, '?')
        return out.rstrip()

    def rows(self, a, b):
        return [self.row(r) for r in range(a, b)]

    def find_row(self, text, a=2, b=52):
        for r in range(a, b):
            if text in self.row(r):
                return r
        return None

    def bar_row(self):
        """the text row whose mode bytes carry the bar's tint"""
        for r in range(60):
            if self.cpu.mem[0x5A20 + 8 * r] == 0x40:
                return r
        return None

    def select(self, name):
        """Up / Down until the bar is on the entry named"""
        want = self.find_row(name)
        if want is None:
            self.fail('%s is not on the screen' % name)
            return False
        for _ in range(60):
            have = self.bar_row()
            if have == want:
                return True
            self.key('\x12' if have < want else '\x11')
        self.fail('could not move the bar to %s' % name)
        return False

    def card(self):
        return self.port.sd.image


def build():
    lib, _, _ = ps.assemble(open(os.path.join(HERE, 'rom_lib.asm')).read(), HERE)
    dos, syms, _ = ps.assemble(open(os.path.join(HERE, 'dos.asm')).read(), HERE)
    rom = ps.build_rom(dos, HERE)
    return rom, syms, lib


def make_card(lib, cfg=b'PARENT.PLC\r\n'):
    files = {}
    for n in ('PI.PLC', 'LIFE.PLC', 'CPUTEST.PLC', 'MANDEL.PLC'):
        files[n] = open(os.path.join(SDCARD, n), 'rb').read()
    files['PARENT.PLC'] = plc(PARENT_SRC, lib)
    files['HELLO.PLC'] = plc(HELLO_SRC, lib)
    files['README.TXT'] = b'The Placard DOS reads this card.\r\n'
    files['GAMES/PONG.PLC'] = files['HELLO.PLC']
    if cfg is not None:
        files['BOOT.CFG'] = cfg
    return sdimage.make(files), files


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png')
    args = ap.parse_args(argv)
    rom, syms, lib = build()
    image, files = make_card(lib)
    r = Rig(rom, syms, lib, image)
    cpu, mem = r.cpu, r.cpu.mem

    # 1. BOOT.CFG -> PARENT -> dos_run HELLO -> dos_back -> PARENT again -> browser
    print('1. BOOT.CFG, dos_run, dos_back')
    if r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7, 200, 'PARENT.PLC to start'):
        print('  PARENT.PLC started at frame %d, map %02X, SP %02X' % (cpu.clocks // FRAME, cpu.map, mem[6]))
        if mem[6] != 0xFF:
            r.fail('SP = %02X at the program start' % mem[6])
    r.run_until(lambda: cpu.pc == 0x0200 and cpu.map == 7, 200, 'HELLO.PLC to start')
    r.run_until(lambda: cpu.pc == 0x0100 and cpu.map == 7 and mem[MB + 0x11] == 1, 200,
                'PARENT.PLC to run again')
    if r.wait_browser(200):
        print('  browser at frame %d' % (cpu.clocks // FRAME))
    if mem[MB + 0x12] != 0x42:
        r.fail('HELLO.PLC did not run (x5D12 = %02X)' % mem[MB + 0x12])
    if mem[MB + 0x13] != 1:
        r.fail('PARENT.PLC did not run again')
    if mem[MB + 0x40] != 0:
        r.fail('MB_PARENT not cleared')
    if mem[0x1F00:0x2000] != bytes(rom.get(a, 0) for a in range(0x9F00, 0xA000)):
        r.fail('LIB_RAM is not in place')

    # 2. the screen
    print('2. the screen')
    title = r.row(0)
    print('  row 0: %r' % title)
    if not title.startswith('PLACARD DOS') or not title.endswith('\\'):
        r.fail('the title')
    listing = [l for l in r.rows(2, 52) if l]
    for l in listing:
        print('  ' + l)
    names = [l.split()[0] for l in listing]
    want = sorted(n for n in files if '/' not in n) + ['GAMES']
    if sorted(names) != sorted(want):
        r.fail('the entries: %s' % names)
    for l in listing:
        n = l.split()[0]
        if n == 'GAMES':
            if '<DIR>' not in l:
                r.fail('GAMES is not shown as a folder')
        elif str(len(files[n])) != l.split()[1]:
            r.fail('%s: size shown %s, not %d' % (n, l.split()[1], len(files[n])))
    if r.bar_row() != 2:
        r.fail('the bar is not on the first entry (row %s)' % r.bar_row())
    if args.png:
        ps.render(mem, args.png)
        print('  wrote', args.png)

    # 3. a folder
    print('3. folder')
    if r.select('GAMES'):
        r.key('\n')
        if r.wait_browser():
            print('  row 0: %r' % r.row(0))
            if not r.row(0).endswith('GAMES') or r.find_row('PONG.PLC') is None:
                r.fail('GAMES not opened')
            r.key('\x08')
            if r.wait_browser() and (not r.row(0).endswith('\\') or r.find_row('PI.PLC') is None):
                r.fail('Backspace did not go back to the root')

    # 4. not a program
    print('4. a text file')
    if r.select('README.TXT'):
        r.key('\n')
        r.wait_browser()
        print('  message: %r' % r.row(55))
        if 'Not a program' not in r.row(55):
            r.fail('no "Not a program" message')

    # 5. a RAM image
    print('5. PI.PLC')
    if r.select('PI.PLC'):
        r.key('\n', hold=1)
        if r.run_until(lambda: cpu.pc == MB_GO, 120, 'the RAM image to start'):
            body = files['PI.PLC'][16:]
            want = bytes(body) + bytes(0x4A00 - len(body))
            got = bytes(mem[0:0x4A00])
            if got != want:
                bad = [a for a in range(0x4A00) if got[a] != want[a]]
                r.fail('RAM differs from the image at %d bytes, first x%04X' % (len(bad), bad[0]))
            else:
                print('  RAM x0000-x49FF is the image')
            r.run(30)
            if cpu.map != 0xFF:
                r.fail('map %02X while the RAM image runs' % cpu.map)
            r.port.kbd.press(r.codes['\x1b'])
            found = r.run_until(lambda: r.at('br_loop'), 120, 'the browser after Esc')
            r.port.kbd.release(r.codes['\x1b'])
            if found:
                print('  Esc: the browser is back, map %02X' % cpu.map)
                r.run(6)

    # 6. Del, B
    print('6. Del, B')
    if r.select('README.TXT'):
        r.key('\x7f')
        r.wait_browser()
        print('  message: %r' % r.row(55))
        left = [n for n, a, s in sdimage.listdir(r.card())]
        if 'README.TXT' in left or r.find_row('README.TXT') is not None:
            r.fail('README.TXT not deleted')
    if r.select('HELLO.PLC'):
        r.key('b')
        r.wait_browser()
        print('  message: %r' % r.row(55))
        cfg = sdimage.read(r.card(), 'BOOT.CFG')
        if cfg != b'HELLO.PLC\r\n':
            r.fail('BOOT.CFG = %r' % cfg)

    # 7. the command line
    print('7. the command line')
    for a in range(0x200, 0x240):
        mem[a] = (a * 7) & 0xFF
    r.key('\x1b')
    r.run(3)
    r.type('save test.plc 0200 0040 0205\n')
    r.wait_browser()
    print('  SAVE: %r' % r.row(55))
    try:
        data = sdimage.read(r.card(), 'TEST.PLC')
    except FileNotFoundError:
        data = None
        r.fail('TEST.PLC not written')
    want = gen_plc.header(0, 0x200, 0x40, 0x205) + bytes(mem[0x200:0x240])
    if data is not None and data != want:
        r.fail('TEST.PLC holds %d bytes: %r...' % (len(data), data[:20]))
    r.key('\x1b')
    r.run(3)
    r.type('load test.plc 3000\n')
    r.wait_browser()
    print('  LOAD: %r' % r.row(55))
    if bytes(mem[0x3000:0x3000 + len(want)]) != want:
        r.fail('LOAD did not put the file at x3000')
    r.key('\x1b')
    r.run(3)
    r.type('del test.plc\n')
    r.wait_browser()
    if 'TEST.PLC' in [n for n, a, s in sdimage.listdir(r.card())]:
        r.fail('DEL did not delete TEST.PLC')
    r.key('\x1b')
    r.run(3)
    r.type('cd games\n')
    r.wait_browser()
    if not r.row(0).endswith('GAMES'):
        r.fail('CD GAMES: title %r' % r.row(0))
    r.key('\x1b')
    r.run(3)
    r.type('cd ..\n')
    r.wait_browser()
    if not r.row(0).endswith('\\'):
        r.fail('CD ..: title %r' % r.row(0))
    r.key('\x1b')
    r.run(3)
    r.type('frobnicate\n')
    r.wait_browser()
    print('  unknown: %r' % r.row(55))
    if 'Commands' not in r.row(55):
        r.fail('no command list for an unknown command')

    # 8. Esc at power-up
    print('8. Esc held at power-up')
    image, files = make_card(lib)
    r2 = Rig(rom, syms, lib, image)
    started = []
    r2.run_until(lambda: r2.at('ds_w'), 60, 'the Esc wait')
    r2.port.kbd.press(r2.codes['\x1b'])
    end = r2.cpu.clocks + 150 * FRAME
    while r2.cpu.clocks < end and not r2.at('br_loop'):
        r2.cpu.step()
        if r2.cpu.pc == 0x0100 and r2.cpu.map == 7:
            started.append(r2.cpu.clocks)
    r2.port.kbd.release(r2.codes['\x1b'])
    if not r2.at('br_loop'):
        r2.fail('no browser after Esc at power-up')
    elif started:
        r2.fail('PARENT.PLC ran although Esc was held')
    else:
        print('  browser, BOOT.CFG skipped')

    # 9. no card
    print('9. no card')
    r3 = Rig(rom, syms, lib, None)
    if r3.run_until(lambda: r3.at('br_loop'), 400, 'the browser without a card'):
        print('  message: %r' % r3.row(55))
        if 'No SD card' not in r3.row(55):
            r3.fail('no "No SD card" message')

    ok = r.ok and r2.ok and r3.ok
    print('OK' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
