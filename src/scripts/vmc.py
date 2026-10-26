#!/usr/bin/env python3
"""
vmc.py - compile a .vm file (BASIC's bytecode, a small Forth-like
language) into .masm text for asm_expand.py

    python3 vmc.py basic.vm          writes basic_vm.masm (to look at)

asm_expand.py calls compile_vm() itself for  .include "basic.vm",  so the
build is one step (asm_expand.py rom32.masm).

The bytecode machine (docs/BASIC.md, "The bytecode machine") runs 16-bit
cells on a data stack, with the top cell in TL/TH.  An instruction is one
byte: x00-x3F is a primitive (native code, through the jump page
vm_jump), x80-xFF is the high byte of a word's address and the next byte
its low byte: a call of a word in x8000-xFFFF.

THE LANGUAGE

  \\ text           a comment to the end of the line
  ( text )         a comment (the ( must stand alone)
  PRIM name label  primitive number n (in order from 0) is name, its native
                   code at label; a primitive may take inline bytes: PRIM
                   name label 1 (one byte) or 2 (two bytes)
  : name ... ;     a word
  CONST name v     name is the number v (a number or {asm expression})
  BYTES name ... ; bytes in the ROM: numbers, "strings", c"counted
                   strings" (a length byte first), k"keywords" (the last
                   character + x80), {expressions}; name pushes their address
  WORDS name ...   ;  a table of word addresses (low, high), name pushes
                   its address
  123 -5 0x1F 'c'  numbers: LIT8 n (0-255) or LIT16 n
  {expr}           LIT16 of an assembler expression; c{expr} is LIT8
  ' name           LIT16 of a word's (or BYTES/WORDS table's) address
  S" text"         SLIT: pushes the address of a counted string (length byte,
                   then the characters) held in the code
  ." text"         S" text" then a call of the word TYPE
  IF ELSE THEN  BEGIN AGAIN  BEGIN UNTIL  BEGIN WHILE REPEAT
  RECURSE          a call of the word being defined

Branches are 8-bit relative (BR, 0BR) where the target is close and 16-bit
absolute (LBR, L0BR) otherwise.  LIT8 n followed by @, !, C@ or C! becomes
ZP@ n, ZP! n, ZPC@ n, ZPC! n.

Each word becomes a .flow chunk of #d8 lines: asm_expand.py places them in
the free space of the regions, across pages.

Date: 10/26/2026
"""

import re
import sys

# fixed primitives the compiler itself emits (they must be declared by PRIM
# with these names)
NEEDED = ('EXIT', 'LIT8', 'LIT16', 'BR', '0BR', 'LBR', 'L0BR', 'SLIT',
          'ZP@', 'ZP!', 'ZPC@', 'ZPC!')

SAFE = {'+': 'P', '-': 'M', '*': 'X', '/': 'S', '@': 'AT', '!': 'ST', '<': 'LT',
        '>': 'GT', '=': 'EQ', '?': 'Q', '.': 'D', '$': 'STR', "'": 'T', '#': 'H',
        ',': 'C', '"': 'QU', '&': 'A', '|': 'OR', '^': 'XO', '~': 'TL', '[': 'LB',
        ']': 'RB', '%': 'PC', ':': 'CO', ';': 'SC'}


class VmError(Exception):
    pass


def label_of(name):
    out = []
    for ch in name:
        if ch.isalnum() or ch == '_':
            out.append(ch)
        else:
            out.append('_' + SAFE.get(ch, 'U%02X' % ord(ch)) + '_')
    return 'w_' + ''.join(out)


def tokenize(src, fname):
    """tokens with line numbers; strings as ('str', text) after S" or ." """
    toks = []
    for ln, line in enumerate(src.splitlines(), 1):
        i = 0
        n = len(line)
        while i < n:
            while i < n and line[i] in ' \t':
                i += 1
            if i >= n:
                break
            j = i
            while j < n and line[j] not in ' \t':
                j += 1
            word = line[i:j]
            if word == '\\':
                break
            if word == '(':
                k = line.find(')', j)
                if k < 0:
                    raise VmError('%s:%d: ( without )' % (fname, ln))
                i = k + 1
                continue
            if word in ('S"', '."'):
                k = line.find('"', j + 1)
                if k < 0:
                    raise VmError('%s:%d: string without its closing "' % (fname, ln))
                toks.append((ln, word))
                toks.append((ln, ('str', line[j + 1:k])))
                i = k + 1
                continue
            if word[:1] == '"' or word[:2] in ('k"', 'c"'):   # in BYTES (may hold spaces)
                q = i + (0 if word[0] == '"' else 1)
                k = line.find('"', q + 1)
                if k < 0:
                    raise VmError('%s:%d: string without its closing "' % (fname, ln))
                kind = {'"': 'str', 'k': 'kstr', 'c': 'cstr'}[word[0]]
                toks.append((ln, (kind, line[q + 1:k])))
                i = k + 1
                continue
            if (word.startswith('{') or word.startswith('c{')) and not word.endswith('}'):
                k = line.find('}', i)
                if k < 0:
                    raise VmError('%s:%d: { without }' % (fname, ln))
                word = line[i:k + 1]
                j = k + 1
            toks.append((ln, word))
            i = j
    return toks


def number(word):
    """the value of a number token, or None"""
    if re.match(r'^-?[0-9]+$', word):
        return int(word)
    if re.match(r'^-?0x[0-9A-Fa-f]+$', word):
        return int(word, 16)
    if len(word) == 3 and word[0] == "'" and word[2] == "'":
        return ord(word[1])
    return None


class Item:
    """one piece of a word's code: bytes (list of ints or expression
    strings), or a branch to a mark"""
    def __init__(self, kind, data=None, target=None):
        self.kind = kind            # 'bytes', 'br', '0br', 'mark'
        self.data = data or []
        self.target = target
        self.long = False


class Compiler:
    def __init__(self, fname='?'):
        self.fname = fname
        self.prims = {}             # name -> (opcode, label, inline bytes)
        self.consts = {}            # name -> int or '{expr}'
        self.words = {}             # name -> label
        self.tables = {}            # name -> label (BYTES, WORDS)
        self.defs = []              # (label, [Item]) in order
        self.order = []             # primitive names in opcode order

    # -- pass 1: names ------------------------------------------------
    def collect(self, toks):
        i = 0
        while i < len(toks):
            ln, w = toks[i]
            if w == ':':
                name = toks[i + 1][1]
                if name in self.words or name in self.prims:
                    raise VmError('%s:%d: %s defined twice' % (self.fname, ln, name))
                self.words[name] = label_of(name)
            elif w in ('BYTES', 'WORDS'):
                name = toks[i + 1][1]
                self.tables[name] = label_of(name)
            i += 1

    def op(self, name, ln):
        if name not in self.prims:
            raise VmError('%s:%d: no primitive %s' % (self.fname, ln, name))
        return self.prims[name][0]

    def lit(self, v, ln):
        if isinstance(v, str):                  # an assembler expression
            e = v[1:-1]
            return [self.op('LIT16', ln), '(%s) & 0xFF' % e, '(%s) >> 8' % e]
        v &= 0xFFFF
        if v < 256:
            return [self.op('LIT8', ln), v]
        return [self.op('LIT16', ln), v & 0xFF, v >> 8]

    def call(self, label):
        return ['%s >> 8' % label, '%s & 0xFF' % label]

    # -- pass 2: code -------------------------------------------------
    def compile(self, toks):
        self.collect(toks)
        i = 0
        while i < len(toks):
            ln, w = toks[i]
            if w == 'PRIM':
                name, label = toks[i + 1][1], toks[i + 2][1]
                inline = 0
                if i + 3 < len(toks) and toks[i + 3][1] in ('1', '2') and toks[i + 3][0] == ln:
                    inline = int(toks[i + 3][1])
                    i += 1
                self.prims[name] = (len(self.order), label, inline)
                self.order.append(name)
                i += 3
                continue
            if w == 'CONST':
                name, v = toks[i + 1][1], toks[i + 2][1]
                n = number(v)
                if n is None and v in self.consts:
                    n = self.consts[v]
                self.consts[name] = n if n is not None else v
                i += 3
                continue
            if w == 'BYTES':
                name = toks[i + 1][1]
                data = []
                i += 2
                while toks[i][1] != ';':
                    t = toks[i][1]
                    if isinstance(t, tuple):
                        b = [ord(c) for c in t[1]]
                        if t[0] == 'kstr':      # the last character + x80
                            b[-1] |= 0x80
                        elif t[0] == 'cstr':    # counted: the length first
                            b = [len(b)] + b
                        data.extend(b)
                    elif number(t) is not None:
                        data.append(number(t) & 0xFF)
                    elif t in self.consts:
                        c = self.consts[t]
                        data.append(c & 0xFF if isinstance(c, int) else '(%s) & 0xFF' % c[1:-1])
                    elif t.startswith('{'):
                        data.append('(%s) & 0xFF' % t[1:-1])
                    else:
                        raise VmError('%s:%d: bad byte %s' % (self.fname, toks[i][0], t))
                    i += 1
                self.defs.append((self.tables[name], [Item('bytes', data)]))
                i += 1
                continue
            if w == 'WORDS':
                name = toks[i + 1][1]
                data = []
                i += 2
                while toks[i][1] != ';':
                    t = toks[i][1]
                    lab = self.words.get(t) or self.tables.get(t)
                    if lab is None:
                        raise VmError('%s:%d: no word %s' % (self.fname, toks[i][0], t))
                    data += ['%s & 0xFF' % lab, '%s >> 8' % lab]
                    i += 1
                self.defs.append((self.tables[name], [Item('bytes', data)]))
                i += 1
                continue
            if w == ':':
                i = self.word(toks, i)
                continue
            raise VmError('%s:%d: %s outside a word' % (self.fname, ln, w))
        for n in NEEDED:
            if n not in self.prims:
                raise VmError('primitive %s is not declared' % n)
        if len(self.order) > 128:
            raise VmError('%d primitives, at most 128' % len(self.order))

    def word(self, toks, i):
        ln, _ = toks[i]
        name = toks[i + 1][1]
        label = self.words[name]
        items = []
        ctl = []                    # control stack: (kind, mark)
        nmark = [0]

        def mark():
            nmark[0] += 1
            m = Item('mark')
            items.append(m)
            return m

        def emit(*b):
            items.append(Item('bytes', list(b)))
        i += 2
        while True:
            if i >= len(toks):
                raise VmError('%s:%d: %s has no ;' % (self.fname, ln, name))
            ln, w = toks[i]
            i += 1
            if w == ';':
                emit(self.op('EXIT', ln))
                break
            if isinstance(w, tuple):
                raise VmError('%s:%d: a string out of place' % (self.fname, ln))
            if w in ('S"', '."'):
                s = toks[i][1][1]
                i += 1
                emit(self.op('SLIT', ln), len(s), *[ord(c) for c in s])
                if w == '."':
                    if 'TYPE' not in self.words:
                        raise VmError('%s:%d: ." needs a word TYPE' % (self.fname, ln))
                    emit(*self.call(self.words['TYPE']))
                continue
            if w == 'IF':
                br = Item('0br')
                items.append(br)
                ctl.append(('if', br))
                continue
            if w == 'ELSE':
                kind, br = ctl.pop()
                if kind != 'if':
                    raise VmError('%s:%d: ELSE without IF' % (self.fname, ln))
                br2 = Item('br')
                items.append(br2)
                br.target = mark()
                ctl.append(('if', br2))
                continue
            if w == 'THEN':
                kind, br = ctl.pop()
                if kind != 'if':
                    raise VmError('%s:%d: THEN without IF' % (self.fname, ln))
                br.target = mark()
                continue
            if w == 'BEGIN':
                ctl.append(('begin', mark()))
                continue
            if w in ('AGAIN', 'UNTIL'):
                kind, m = ctl.pop()
                if kind != 'begin':
                    raise VmError('%s:%d: %s without BEGIN' % (self.fname, ln, w))
                items.append(Item('br' if w == 'AGAIN' else '0br', target=m))
                continue
            if w == 'WHILE':
                br = Item('0br')
                items.append(br)
                ctl.append(('while', br))
                continue
            if w == 'REPEAT':
                kind, br = ctl.pop()
                kind2, m = ctl.pop()
                if kind != 'while' or kind2 != 'begin':
                    raise VmError('%s:%d: REPEAT without BEGIN ... WHILE' % (self.fname, ln))
                items.append(Item('br', target=m))
                br.target = mark()
                continue
            if w == 'RECURSE':
                emit(*self.call(label))
                continue
            if w == "'":
                t = toks[i][1]
                i += 1
                lab = self.words.get(t) or self.tables.get(t)
                if lab is None:
                    raise VmError("%s:%d: ' of no word %s" % (self.fname, ln, t))
                emit(*self.lit('{%s}' % lab, ln))
                continue
            n = number(w)
            if n is not None:
                emit(*self.lit(n, ln))
                continue
            if w.startswith('c{') and w.endswith('}'):
                emit(self.op('LIT8', ln), '(%s) & 0xFF' % w[2:-1])
                continue
            if w.startswith('{') and w.endswith('}'):
                emit(*self.lit(w, ln))
                continue
            if w in self.consts:
                emit(*self.lit(self.consts[w], ln))
                continue
            if w in self.tables:
                emit(*self.lit('{%s}' % self.tables[w], ln))
                continue
            if w in self.prims:
                op, _, inline = self.prims[w]
                if inline:
                    raise VmError('%s:%d: %s takes inline bytes (the compiler emits it)'
                                  % (self.fname, ln, w))
                # LIT8 n then @ ! C@ C!: the zero-page forms
                if w in ('@', '!', 'C@', 'C!') and items and items[-1].kind == 'bytes' \
                        and len(items[-1].data) == 2 and items[-1].data[0] == self.op('LIT8', ln):
                    items[-1].data[0] = self.op({'@': 'ZP@', '!': 'ZP!', 'C@': 'ZPC@',
                                                 'C!': 'ZPC!'}[w], ln)
                    continue
                emit(op)
                continue
            if w in self.words:
                emit(*self.call(self.words[w]))
                continue
            raise VmError('%s:%d: unknown word %s' % (self.fname, ln, w))
        if ctl:
            raise VmError('%s: %s: unfinished %s' % (self.fname, name, ctl[-1][0]))
        self.defs.append((label, items))
        return i

    # -- layout -------------------------------------------------------
    def layout(self, items):
        """offsets with branches relaxed (short until out of range)"""
        while True:
            pos = 0
            where = {}
            for it in items:
                where[id(it)] = pos
                if it.kind == 'bytes':
                    pos += len(it.data)
                elif it.kind in ('br', '0br'):
                    pos += 3 if it.long else 2
            grew = False
            for it in items:
                if it.kind in ('br', '0br') and not it.long:
                    d = where[id(it.target)] - (where[id(it)] + 2)
                    if not -128 <= d <= 127:
                        it.long = True
                        grew = True
            if not grew:
                return where, pos

    def render(self):
        out = ['; ' + '=' * 60,
               '; made by vmc.py from %s: change that file' % self.fname,
               '; ' + '=' * 60, '']
        for name in self.order:
            op, label, _ = self.prims[name]
            out.append('VM_%s = %d' % (label.upper(), op))
        out.append('')
        if len(self.order) > 64:
            raise VmError('more than 64 primitives (next jumps to opcode x 4)')
        out.append('.page  the primitives: next jumps to vm_jump + opcode x 4')
        out.append('vm_jump:')
        for n in self.order:
            label = self.prims[n][1]
            out.append('    ld   %s >> 8, y' % label)
            out.append('    jmp  %s' % label)
        total = 0
        for label, items in self.defs:
            where, size = self.layout(items)
            data = []
            for it in items:
                if it.kind == 'bytes':
                    data.extend(it.data)
                elif it.kind in ('br', '0br'):
                    nm = ('L' if it.long else '') + ('BR' if it.kind == 'br' else '0BR')
                    data.append(self.prims[nm][0])
                    if it.long:
                        data += ['(%s + %d) & 0xFF' % (label, where[id(it.target)]),
                                 '(%s + %d) >> 8' % (label, where[id(it.target)])]
                    else:
                        d = where[id(it.target)] - (where[id(it)] + 2)
                        data.append(d & 0xFF)
            total += len(data)
            out.append('.flow')
            out.append(label + ':')
            for k in range(0, len(data), 12):
                out.append('    #d8 ' + ', '.join(str(b) for b in data[k:k + 12]))
        self.total = total
        return '\n'.join(out) + '\n'


def compile_vm(src, fname='?'):
    c = Compiler(fname)
    c.compile(tokenize(src, fname), )
    return c.render(), c


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    for path in argv:
        text, c = compile_vm(open(path).read(), path)
        dst = re.sub(r'\.vm$', '', path) + '_vm.masm'
        open(dst, 'w', newline='\n').write(text)
        print('%s: %d words, %d primitives, %d bytes of bytecode'
              % (dst, len(c.words), len(c.order), c.total))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
