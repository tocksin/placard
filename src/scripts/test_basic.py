#!/usr/bin/env python3
"""
test_basic.py - run PLACARD BASIC (rom32.masm, basic.masm, basic.vm) in
placard_sim and check what it prints

    python3 test_basic.py               the checks
    python3 test_basic.py -k print      only the checks whose name has "print"
    python3 test_basic.py --png s.png   also the last screen as a PNG
    python3 test_basic.py --bench       also time a FOR loop

The card checks ("files") boot a second time with a card (sdimage.py)
whose BOOT.CFG says BASIC, holding the example programs in ../../sdcard.

The 32K ROM boots with no card, so the loader starts BASIC.  Lines are
typed by putting their characters straight into the key buffer (KBD_BUF,
as kbd_scan would), which is much faster than the PS/2 keyboard model;
BASIC is idle when its bytecode is in KEY with the buffer empty.  The
screen is read back through the font (80 x 60 and 80 x 30 text).

Date: 10/27/2026
"""

import argparse
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import io_devices             # noqa: E402
import sdimage                # noqa: E402

FRAME = 525 * 800
KBD_BUF, KBD_HEAD, KBD_TAIL = 0xA8, 0xB0, 0xB1


def build():
    prog, syms, _ = ps.assemble(open(os.path.join(HERE, 'rom32.asm')).read(), HERE)
    return ps.build_rom(prog, HERE), syms


class Basic:
    def __init__(self, rom, syms, image=None):
        self.rom, self.syms = rom, syms
        self.port = io_devices.SharedPort()
        self.port.kbd = io_devices.Ps2Keyboard()
        if image is not None:
            self.port.sd = io_devices.SdCard(image)
        self.cpu = ps.Cpu({}, rom=rom, io=self.port)
        self.glyphs = {}
        for ch in range(0x20, 0x7F):
            rows = tuple(rom.get(syms['LIB_FONT'] + k * 256 + ch, 0) for k in range(8))
            self.glyphs.setdefault(rows, chr(ch))
        labels = sorted(v for k, v in syms.items() if k.startswith('w_'))
        a = syms['w_KEY']
        self.key_lo, self.key_hi = a, labels[labels.index(a) + 1]
        self.p_poll = syms['p_poll']
        self.ok = True

    def idle(self):
        m = self.cpu.mem
        ip = m[0x20] | m[0x21] << 8
        return (self.cpu.pc == self.p_poll and self.key_lo <= ip < self.key_hi
                and m[KBD_HEAD] == m[KBD_TAIL])

    def run(self, frames=600, until=None):
        """run until idle (or until(), or frames)"""
        until = until or self.idle
        cpu = self.cpu
        end = cpu.clocks + frames * FRAME
        n = 0
        while cpu.clocks < end:
            cpu.step()
            n += 1
            if cpu.pc == self.p_poll and until():
                return True
        return False

    def put(self, ch):
        m = self.cpu.mem
        while (m[KBD_HEAD] + 1) & 7 == m[KBD_TAIL]:
            for _ in range(2000):
                self.cpu.step()
        m[KBD_BUF + m[KBD_HEAD]] = ord(ch)
        m[KBD_HEAD] = (m[KBD_HEAD] + 1) & 7

    def type(self, text, frames=600):
        for ch in text:
            self.put(ch)
        return self.run(frames)

    def row(self, r):
        mem = self.cpu.mem
        two = mem[0x33]
        out = ''
        cursor = tuple(rom ^ 0xFF for rom in (0,) * 8)
        for col in range(80):
            if two:
                off = 0x120 + 16 * r if r < 14 else 0x101 + 16 * (r - 14)
                rows = tuple(mem[0x6000 + col * 512 + off + 2 * k] for k in range(8))
            else:
                rows = tuple(mem[0x6020 + col * 512 + 8 * r + k] for k in range(8))
            out += ' ' if rows == cursor else self.glyphs.get(rows, '?')
        return out.rstrip()

    def screen(self):
        n = 30 if self.cpu.mem[0x33] else 60
        lines = [self.row(r) for r in range(n)]
        while lines and not lines[-1]:
            lines.pop()
        return lines

    def cmd(self, line, frames=600):
        """type a line and Enter; the lines printed after it"""
        before = self.cpu.mem[0x0E]
        done = self.type(line + '\n', frames)
        if not done:
            print('  (still running after %d frames)' % frames)
        lines = self.screen()
        # the lines from the one typed, Ready dropped
        cut = [i for i, l in enumerate(lines) if l == line[:80]]
        out = lines[cut[-1] + 1:] if cut else lines[before:]
        if out and out[-1] == 'Ready':
            out = out[:-1]
        return out


CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


def expect(b, name, got, want):
    if got != want:
        b.ok = False
        print('FAIL %s:\n  got  %r\n  want %r' % (name, got, want))
    else:
        print('  ok  %s' % name)


@check
def t_start(b):
    s = b.screen()
    expect(b, 'banner', s[:3], ['PLACARD BASIC', s[1], 'Ready'])


@check
def t_print(b):
    expect(b, 'print number', b.cmd('PRINT 1+2*3'), ['7'])
    expect(b, 'print string', b.cmd('PRINT "HELLO";" ";"WORLD"'), ['HELLO WORLD'])
    expect(b, 'precedence', b.cmd('? (1+2)*3, -7/2, 7 MOD 3, -5+2'), ['9         -3        1         -3'])
    expect(b, 'compare', b.cmd('? 1<2, 2<1, 3=3, "A"<"B", 5 AND 3, 5 OR 3, NOT 0'),
           ['-1        0         -1        -1        1         7         -1'])
    expect(b, 'hex', b.cmd('? &HFF, HEX$(255), -32768'), ['255       FF        -32768'])
    expect(b, 'operators', b.cmd('? 2*3+4*5-6/2, 10-2-3, 7 MOD 4*2, NOT 1=2, 1 OR 2 AND 4'),
           ['23        5         6         -1        1'])
    expect(b, 'unary', b.cmd('? -2*-3, +5-+3, -(3), NOT NOT 7, NOT 0 AND 5'),
           ['6         2         -3        7         5'])


@check
def t_vars(b):
    b.cmd('A=5:B1=A*2:AB$="X"+"YZ"')
    expect(b, 'variables', b.cmd('? A;B1;AB$;LEN(AB$)'), ['510XYZ3'])


@check
def t_program(b):
    b.cmd('NEW')
    for l in ['10 FOR I=1 TO 5', '20 S=S+I', '30 NEXT I', '40 PRINT "SUM";S', '50 END']:
        b.cmd(l)
    expect(b, 'run', b.cmd('RUN'), ['SUM15'])
    expect(b, 'list', b.cmd('LIST'), ['10 FOR I=1 TO 5', '20 S=S+I', '30 NEXT I',
                                      '40 PRINT "SUM";S', '50 END'])


def prog(b, lines):
    b.cmd('NEW')
    for l in lines:
        b.cmd(l)


@check
def t_flow(b):
    prog(b, ['10 GOSUB 100:PRINT "B";', '20 IF X=1 THEN PRINT "C";:GOTO 40',
             '30 PRINT "N";', '40 ON 2 GOTO 50,60,70', '50 PRINT "X"', '60 PRINT "D";',
             '65 ON 3 GOSUB 200,200,210:PRINT "F"', '70 END',
             '100 PRINT "A";:X=1:RETURN', '200 PRINT "Y":RETURN', '210 PRINT "E";:RETURN'])
    expect(b, 'gosub, if, on', b.cmd('RUN'), ['ABCDEF'])
    prog(b, ['10 FOR I=10 TO 1 STEP -3:PRINT I;:NEXT:PRINT', '20 FOR I=1 TO 2:FOR J=1 TO 2',
             '30 PRINT I*10+J;" ";:NEXT J,I:PRINT', '40 IF 0 THEN PRINT "NO"', '50 PRINT "END"'])
    expect(b, 'for step, nested', b.cmd('RUN'), ['10741', '11 12 21 22', 'END'])


@check
def t_strings(b):
    expect(b, 'substrings', b.cmd('? LEFT$("HELLO",2);MID$("HELLO",2,3);RIGHT$("HELLO",2)'), ['HEELLLO'])
    expect(b, 'chr asc len', b.cmd('? CHR$(65);ASC("B");LEN("");MID$("AB",3);"."'), ['A660.'])
    expect(b, 'str val', b.cmd('? STR$(-12)+"!";VAL("  -34X")+1;VAL("&H10")'), ['-12!-3316'])
    expect(b, 'compare', b.cmd('? "AB"="AB";"AB"<"ABC";"B">"AC";"A"<>"A"'), ['-1-1-10'])
    b.cmd('A$="":FOR I=1 TO 20:A$=A$+CHR$(64+I):NEXT')
    expect(b, 'build', b.cmd('? A$;LEN(A$)'), ['ABCDEFGHIJKLMNOPQRST20'])


@check
def t_gc(b):
    prog(b, ['10 DIM S$(20):F=FRE(0)', '20 FOR N=1 TO 300', '30 S$(N MOD 20)=STR$(N)+"ABCDEFGHIJ"',
             '40 NEXT', '50 PRINT S$(0);" ";S$(19);" ";F-FRE(0)'])
    expect(b, 'garbage collector', b.cmd('RUN', 3000), ['300ABCDEFGHIJ 299ABCDEFGHIJ 346'])


@check
def t_arrays(b):
    prog(b, ['10 DIM A(5),B$(3)', '20 FOR I=0 TO 5:A(I)=I*I:NEXT', '30 B$(2)="TWO"',
             '40 PRINT A(5);A(3);B$(2);C(7)', '50 PRINT A(6)'])
    expect(b, 'arrays', b.cmd('RUN'), ['259TWO0', '?Bad subscript error in 50'])
    expect(b, 'redim', b.cmd('DIM A(3)'), ['?Redim\'d array error'])


@check
def t_data(b):
    prog(b, ['10 READ A,B$,C', '20 PRINT A;B$;C', '30 RESTORE:READ D:PRINT D',
             '40 READ X$,Y,Z', '50 DATA 1,"HI, THERE"', '60 DATA -5'])
    expect(b, 'read', b.cmd('RUN'), ['1HI, THERE-5', '1', '?Out of data error in 40'])


@check
def t_input(b):
    prog(b, ['10 INPUT "NAME";N$:INPUT A,B', '20 PRINT N$;A+B'])
    b.type('RUN\n')
    b.type('BOB\n')
    b.type('3\n')
    b.type('X\n')
    out = b.cmd('4,5')
    expect(b, 'input', b.screen()[-8:-1], ['RUN', 'NAME? BOB', '? 3', '?? X', '?Redo', '? 4,5', 'BOB9'])


@check
def t_errors(b):
    expect(b, 'syntax', b.cmd('PRINT 1+'), ['?Syntax error'])
    expect(b, 'type', b.cmd('A=""'), ['?Type mismatch error'])
    expect(b, 'div0', b.cmd('? 1/0'), ['?Division by zero error'])
    expect(b, 'undefined line', b.cmd('GOTO 999'), ['?Undefined line error'])
    expect(b, 'return', b.cmd('RETURN'), ['?RETURN without GOSUB error'])
    expect(b, 'next', b.cmd('NEXT'), ['?NEXT without FOR error'])
    expect(b, 'direct input', b.cmd('INPUT A'), ['?Illegal direct error'])
    expect(b, 'cont', b.cmd('CONT'), ['?Can\'t continue error'])


@check
def t_edit(b):
    prog(b, ['30 C', '10 A', '20 B', '20 BB', '40 D', '40', '5 Z'])
    expect(b, 'line edits', b.cmd('LIST'), ['5 Z', '10 A', '20 BB', '30 C'])
    expect(b, 'list range', b.cmd('LIST 10-20'), ['10 A', '20 BB'])
    expect(b, 'list from', b.cmd('LIST 20-'), ['20 BB', '30 C'])
    b.cmd('NEW')
    expect(b, 'tokens', [b.cmd('10 print"x";:fori=1to2:next'), b.cmd('LIST')],
           [[], ['10 PRINT"x";:FORI=1TO2:NEXT']])


@check
def t_break(b):
    prog(b, ['10 I=I+1:GOTO 10'])
    b.type('RUN\n', 30)
    b.cpu.mem[0xA0] &= 0xFE             # Esc down
    b.run(30)
    b.cpu.mem[0xA0] |= 1
    b.run(30)
    s = b.screen()
    expect(b, 'break', s[-2:], ['Break in 10', 'Ready'])
    out = b.cmd('PRINT I>100')
    expect(b, 'loop ran', out, ['-1'])
    b.type('CONT\n', 20)
    b.cpu.mem[0xA0] &= 0xFE
    b.run(30)
    b.cpu.mem[0xA0] |= 1
    b.run(30)
    expect(b, 'cont', b.screen()[-2:], ['Break in 10', 'Ready'])
    b.type('CONT\n', 20)
    b.cpu.mem[0xA3] &= ~0x10            # left Ctrl and C down
    b.cpu.mem[0xA5] &= ~0x10
    b.run(30)
    b.cpu.mem[0xA3] |= 0x10
    b.cpu.mem[0xA5] |= 0x10
    b.run(30)
    expect(b, 'ctrl-c', b.screen()[-2:], ['Break in 10', 'Ready'])
    b.cmd('TEXT 60')
    prog(b, ['10 MODE 1,1,8', '20 LINE 0,0,639,415,1:LINE 639,0,0,415,1:GOTO 20'])
    b.type('RUN\n', 10)
    b.cpu.mem[0xA0] &= 0xFE             # Esc in the middle of a long LINE
    b.run(10)
    b.cpu.mem[0xA0] |= 1
    b.run(30)
    s = b.screen()
    expect(b, 'break in line', s[s.index('Break in 20'):][:2] if 'Break in 20' in s else s[-2:],
           ['Break in 20', 'Ready'])
    b.cmd('TEXT 60')


@check
def t_scroll(b):
    prog(b, ['10 FOR I=1 TO 70:PRINT "LINE";I:NEXT'])
    b.cmd('RUN', 2000)
    s = b.screen()
    expect(b, 'scrolled', [s[0], s[57], s[58]], ['LINE13', 'LINE70', 'Ready'])


@check
def t_text30(b):
    b.cmd('TEXT 30')
    out = b.cmd('PRINT "THIRTY";12')
    expect(b, '80 x 30', out, ['THIRTY12'])
    prog(b, ['10 FOR I=1 TO 40:PRINT "ROW";I:NEXT'])
    b.cmd('RUN', 2000)
    s = b.screen()
    expect(b, '80 x 30 scrolled', [len(s), s[0], s[27], s[28]], [29, 'ROW13', 'ROW40', 'Ready'])
    b.cmd('TEXT 60')


@check
def t_graphics(b):
    m = b.cpu.mem
    b.cmd('MODE 2,2,4:PLOT 0,0,3:PLOT 5,1,2:LINE 0,10,9,10,1')
    # row 3 of the text window is blanked: nothing written there yet
    expect(b, 'mode bytes', [m[0x5A20], m[0x5A20 + 31], m[0x5A20 + 32], m[0x5A20 + 479]], [0, 0x80, 5, 5])
    a = lambda line: 0x6000 + ps.row_offset(line, 5)
    expect(b, 'plot', [m[a(32)] & 3, (m[a(34) + 512] >> 2) & 3, m[a(52)], m[a(52) + 512] & 3],
           [3, 2, 0x55, 1])
    b.cmd('TEXT 60')


@check
def t_blank(b):
    m = b.cpu.mem
    blanked = lambda: ''.join('B' if m[0x5A20 + 8 * r] & 0x80 else '.' for r in range(60))
    b.cmd('CLS')
    expect(b, 'blank after CLS', blanked(), '..' + 'B' * 58)
    b.cmd('LOCATE 5,0:PRINT "X"')
    expect(b, 'shown down to the cursor', blanked(), '.' * 8 + 'B' * 52)
    b.cmd('TINT 30,1')
    expect(b, 'TINT shows its row', blanked(), '.' * 10 + 'B' * 20 + '.' + 'B' * 29)
    for i in range(60):
        b.cmd('?')
    expect(b, 'all shown after a scroll', blanked(), '.' * 60)
    b.cmd('CLS')


@check
def t_machine(b):
    expect(b, 'poke peek', b.cmd('POKE 4000,77:? PEEK(4000);PEEK(&HFC00)'), ['772'])
    expect(b, 'abs sgn', b.cmd('? ABS(-3);SGN(-9);SGN(0);SGN(4)'), ['3-101'])
    expect(b, 'rnd', b.cmd('X=RND(6):? X>=0 AND X<6'), ['-1'])
    b.cmd('LOCATE 5,10:PRINT "@";')
    expect(b, 'locate', b.row(5)[10], '@')


SDCARD = os.path.join(HERE, '..', '..', 'sdcard')
EXAMPLES = sorted(n for n in os.listdir(SDCARD) if n.endswith('.BAS'))


# the PC-terminal keyboard of the Basys 3 (src/hdl/uart_ps2_kbd.vhd): each
# character's key, from the VHDL's own table, sent one byte at a time with
# the key held down HOLD_CLKS after its make code
def uart_keys():
    vhd = open(os.path.join(HERE, '..', 'hdl', 'uart_ps2_kbd.vhd')).read()
    table = vhd[vhd.index('KEY_TABLE : keyTableType'):]
    table = table[:table.index(');')]
    keys = [int(k, 16) for k in re.findall(r'x"([0-9A-F]{3})"', table)]
    hold = int(re.search(r'HOLD_CLKS *: natural := (\d+) \* US', vhd).group(1)) / 1000
    return keys, hold


def uart_type(b, text, keys, hold_ms):
    """type text as the terminal keyboard does; the time it took, in ms"""
    kbd, cpu = b.port.kbd, b.cpu
    c0 = cpu.clocks
    for ch in text:
        k = keys[0x0D if ch == '\n' else ord(ch)]
        code = k & 0xFF
        seq = []
        if k & 0x100:
            seq.append(0x12)
        if k & 0x200:
            seq.append(0x14)
        if k & 0x400:
            seq.append(0xE0)
        make = len(seq)
        seq.append(code)
        if k & 0x400:
            seq.append(0xE0)
        seq += [0xF0, code]
        if k & 0x100:
            seq += [0xF0, 0x12]
        elif k & 0x200:
            seq += [0xF0, 0x14]
        for i, byte in enumerate(seq):
            n = len(kbd.sent)
            kbd.respond(byte)
            while len(kbd.sent) == n:
                for _ in range(200):
                    cpu.step()
                b.port._advance(cpu.clocks)
            if i == make:
                end = cpu.clocks + io_devices.us(hold_ms * 1000)
                while cpu.clocks < end:
                    cpu.step()
    t = (cpu.clocks - c0) / io_devices.CPU_HZ * 1000
    b.run(60)
    return t


@check
def t_uart_kbd(b):
    keys, hold = uart_keys()
    b.cmd('CLS')
    line = '? "Ab(1)*2",1+2:rem typed from the terminal'
    ms = uart_type(b, line + '\n', keys, hold)
    print('  terminal keyboard: %d characters in %.0f ms, %.1f ms each (hold %g ms)'
          % (len(line) + 1, ms, ms / (len(line) + 1), hold))
    s = b.screen()
    expect(b, 'terminal keyboard', s[-3:], [line, 'Ab(1)*2   3', 'Ready'])
    # typed on while BASIC is busy (a 0.3 s loop): the keys stay in order
    uart_type(b, 'for i=1 to 300:next\n? 12+30,"Ab"\n', keys, hold)
    expect(b, 'terminal keyboard, busy', b.screen()[-3:], ['? 12+30,"Ab"', '42        Ab', 'Ready'])


def file_checks(rom, syms):
    """SAVE, LOAD, DIR, DEL and the example programs, on a card"""
    files = {'BOOT.CFG': b'BASIC\r\n',
             'MIXED.BAS': b'20 print "two"\n\nREM no number\r\n10 Print "one";\r\n30 end'}
    for n in EXAMPLES:
        files[n] = open(os.path.join(SDCARD, n), 'rb').read()
    b = Basic(rom, syms, sdimage.make(files))
    if not b.run(1500):
        print('FAIL: BASIC did not start from the card; screen:', b.screen())
        return False
    print('files')
    names = [n for n, a, s in sdimage.listdir(b.port.sd.image)]
    dir_ = ' '.join(b.cmd('DIR', 1200)).split()
    expect(b, 'dir', sorted(dir_), sorted(names))
    expect(b, 'load', [b.cmd('LOAD "MIXED"', 1200), b.cmd('LIST')],
           [[], ['10 PRINT "one";', '20 PRINT "two"', '30 END']])
    expect(b, 'run', b.cmd('RUN'), ['onetwo'])
    expect(b, 'save', b.cmd('SAVE "OUT"', 1200), [])
    expect(b, 'saved text', sdimage.read(b.port.sd.image, 'OUT.BAS'),
           b'10 PRINT "one";\r\n20 PRINT "two"\r\n30 END\r\n')
    b.cmd('NEW')
    expect(b, 'run file', b.cmd('RUN "OUT.BAS"', 1200), ['onetwo'])
    expect(b, 'del', b.cmd('DEL "OUT"', 1200), [])
    expect(b, 'deleted', 'OUT.BAS' in [n for n, a, s in sdimage.listdir(b.port.sd.image)], False)
    out = b.cmd('LOAD "NOPE"', 1200)
    expect(b, 'not found', [l[:12] for l in out], ['?File error '])
    for n in EXAMPLES:
        b.cmd('LOAD "%s"' % n, 1500)
        b.type('LIST\n', 1500)
        want = [l for l in files[n].decode().splitlines() if l]
        got = b.screen()[-1 - len(want):-1]
        expect(b, 'example %s lists back' % n, got, want)
    return b.ok


def bench(b):
    prog(b, ['10 FOR I=1 TO 1000:A=A+I*2:NEXT'])
    b.type('RUN\n', 1)
    c0 = b.cpu.clocks
    b.run(2000)
    ms = (b.cpu.clocks - c0) / 25e3
    print('bench: 1000 passes of A=A+I*2 in %.0f ms (%.0f a second)' % (ms, 1000 / ms * 1000))


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-k')
    ap.add_argument('--png')
    ap.add_argument('--bench', action='store_true', help='time a FOR loop')
    args = ap.parse_args(argv)
    t0 = time.time()
    rom, syms = build()
    b = Basic(rom, syms)
    if not b.run(800):
        print('FAIL: BASIC did not start; screen:', b.screen())
        return 1
    print('BASIC ready at frame %d (%.1f s)' % (b.cpu.clocks // FRAME, time.time() - t0))
    for fn in CHECKS:
        if args.k and args.k not in fn.__name__:
            continue
        print(fn.__name__[2:])
        fn(b)
    if not b.ok:
        print('\n'.join(b.screen()))
    if args.bench:
        bench(b)
    if not args.k or args.k in 'files':
        b.ok = file_checks(rom, syms) and b.ok
    if args.png:
        ps.render(b.cpu.mem, args.png)
    print('%s (%.0f s)' % ('PASS' if b.ok else 'FAIL', time.time() - t0))
    return 0 if b.ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
