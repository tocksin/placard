#!/usr/bin/env python3
"""
pinboard_emu.py - run a card program in the web emulator (web/placard_emu.js,
with node) from a script of keys and mouse moves, for test_pinboard.py

    run(files, inputs, shots, frames)
    run(files, inputs, shots, frames, audio=True)     and what the sound DAC
        played, one sample a scan line from power-up, as rams['audio']
        (test_wave.py)

files   {path: bytes} of the card (sdimage.from_folder plus BOOT.CFG)
inputs  [(frame, kind, value)]: 'press' / 'release' a PS/2 set 2 code
        (0x100 = E0), 'mouse' (dx, dy, buttons)
shots   frames at which the RAM is kept
returns {frame: RAM bytes (65536)}, and the card image at the end

screen_png(ram, path) draws a RAM's screen; cells(ram, font) reads the
80 x 60 characters of a 1 bpp screen back through a font.

Date: 11/22/2026
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import sdimage                # noqa: E402

REPO = os.path.join(HERE, '..', '..')

NODE_RUN = r'''
const fs = require('fs');
const P = require(process.argv[2]);
const cfg = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const m = new P.Machine();
m.setRom(new Uint8Array(fs.readFileSync(cfg.rom)));
m.reset(false, 0);
m.revB = !!cfg.revB;
m.audioMax = cfg.audio ? 1e9 : 0;
m.io.kbd = new P.Ps2Keyboard();
if (cfg.mouse) m.io.mouse = new P.Ps2Mouse();
m.io.sd = new P.SdCard(new Uint8Array(fs.readFileSync(cfg.card)));
let k = 0, s = 0, goal = null, nextGo = 0;
const end = cfg.frames * P.FRAME;
while (m.clocks < end) {
    while (k < cfg.inputs.length && m.clocks >= cfg.inputs[k][0] * P.FRAME) {
        const [, kind, v] = cfg.inputs[k++];
        if (kind === 'press') m.io.kbd.press(v);
        else if (kind === 'release') m.io.kbd.release(v);
        else if (kind === 'mouse') m.io.mouse.move(v[0], v[1], v[2]);
        else { goal = v; nextGo = m.clocks; }
    }
    if (goal && m.clocks >= nextGo) {       // 'goto': steer by Pinboard's own PX, PY
        const px = m.ram[cfg.px] | m.ram[cfg.px + 1] << 8;
        const py = m.ram[cfg.px + 2] | m.ram[cfg.px + 3] << 8;
        const dx = Math.max(-20, Math.min(20, goal[0] - px));
        const dy = Math.max(-20, Math.min(20, goal[1] - py));
        if (dx || dy || m.io.mouse.buttons !== goal[2]) m.io.mouse.move(dx, -dy, goal[2]);    // PS/2: up is +
        nextGo = m.clocks + 4 * P.FRAME;
    }
    while (s < cfg.shots.length && m.clocks >= cfg.shots[s] * P.FRAME) {
        fs.writeFileSync(cfg.dir + '/ram' + cfg.shots[s] + '.bin', m.ram);
        s++;
    }
    if (!m.step()) { console.error(m.error); process.exit(2); }
    while (m.clocks >= m.nextEvt) m.event();
}
fs.writeFileSync(cfg.dir + '/card.out', m.io.sd.image);
if (cfg.audio) fs.writeFileSync(cfg.dir + '/audio.bin', Uint8Array.from(m.audio));
console.log(JSON.stringify({pc: m.pc, map: m.map}));
'''

# how cells() shows Pinboard's own characters 00-11: blank, the board, a
# card's edges and corners, the pin, the arrows, the file pictures (F a
# folder, P a program, f a file, { the folder above, i a picture), the
# scroll bar
LEGEND = ' .<>_[]*^v?FPf{:-#i'

_rom = None


def rom_image():
    global _rom
    if _rom is None:
        prog, _, _ = ps.assemble(open(os.path.join(HERE, 'rom32.asm')).read(), HERE)
        _rom = ps.image_32k(ps.build_rom(prog, HERE))
    return _rom


def run(files, inputs, shots, frames, mouse=True, px=0x38, rev_b=False, audio=False, spc=1, size_kb=4096):
    tmp = tempfile.mkdtemp()
    p = lambda n: os.path.join(tmp, n)   # noqa: E731
    open(p('rom.bin'), 'wb').write(rom_image())
    open(p('card.img'), 'wb').write(sdimage.make(files, size_kb=size_kb, spc=spc))
    open(p('run.js'), 'w').write(NODE_RUN)
    shots = sorted(set(shots))
    json.dump({'rom': p('rom.bin'), 'card': p('card.img'), 'frames': frames, 'mouse': mouse, 'px': px, 'revB': rev_b, 'audio': audio,
               'inputs': sorted(inputs, key=lambda i: i[0]), 'shots': shots, 'dir': tmp},
              open(p('cfg.json'), 'w'))
    js = subprocess.run(['node', p('run.js'),
                         os.path.abspath(os.path.join(REPO, 'web', 'placard_emu.js')),
                         p('cfg.json')], capture_output=True, text=True)
    if js.returncode:
        raise RuntimeError('node: ' + js.stderr)
    rams = {f: open(p('ram%d.bin' % f), 'rb').read() for f in shots if f < frames}
    if audio:
        rams['audio'] = open(p('audio.bin'), 'rb').read()
    return rams, open(p('card.out'), 'rb').read()


def screen_png(ram, path, rev_b=False):
    ps.render(bytearray(ram), path, rev_b)


def cells(ram, font):
    """the 60 rows of 80 characters; font = 8 rows of 256 bytes.  A cell
    that matches no character reads as '?' (the pointer is on it);
    inverse characters read as the plain ones (inv[row][col] says which
    were inverse: black ink on a card)."""
    look = {}
    for c in range(255, -1, -1):
        look[tuple(font[k][c] for k in range(8))] = c
    rows, inv = [], []
    for r in range(60):
        line, iline = '', []
        for c in range(80):
            a = 0x6020 + c * 512 + r * 8
            code = look.get(tuple(ram[a:a + 8]))
            if code is None:
                line += '?'
                iline.append(False)
                continue
            iline.append(code >= 0x80)
            code &= 0x7F
            line += chr(code) if 0x20 <= code < 0x7F else LEGEND[code] if code < len(LEGEND) else '?'
        rows.append(line)
        inv.append(iline)
    return rows, inv


def cells_color(ram, bpp, font):
    """the 30 rows of characters of a 160-read screen at 2x (rev B): 80
    across in 2 bpp, 40 in 4 bpp; font = 8 rows of 256 bytes, 1 bpp, as
    cells() takes.  Returns the rows and, for every cell, (ink, paper):
    the color of the character's pixels and of the rest (ink is None for
    a cell of one color, which reads as a space)."""
    look = {}
    for c in range(127, -1, -1):
        look[tuple(font[k][c] for k in range(8))] = c
    per = 8 // bpp                       # pixels in a byte
    cols = 160 * per // 8
    rows, colors = [], []
    for r in range(30):
        line, cline = '', []
        for c in range(cols):
            pix = []
            for k in range(8):
                p = r * 8 + k
                low = (2 * p + 32) if p < 112 else (2 * p - 223)
                row = []
                for x in range(8):
                    col, sub = divmod(c * 8 + x, per)
                    row.append(ram[0x6000 + col * 256 + low] >> (sub * bpp) & ((1 << bpp) - 1))
                pix.append(row)
            used = sorted({v for row in pix for v in row})
            if len(used) == 1:
                line += ' '
                cline.append((None, used[0]))
                continue
            code = None
            if len(used) == 2:
                for ink, paper in (used, used[::-1]):
                    bits = tuple(sum(1 << x for x in range(8) if row[x] == ink) for row in pix)
                    if bits in look:
                        code = look[bits]
                        cline.append((ink, paper))
                        break
            if code is None:
                line += '?'
                cline.append((None, None))
                continue
            line += chr(code) if 0x20 <= code < 0x7F else LEGEND[code] if code < len(LEGEND) else '?'
        rows.append(line)
        colors.append(cline)
    return rows, colors
