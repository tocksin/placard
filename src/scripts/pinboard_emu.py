#!/usr/bin/env python3
"""
pinboard_emu.py - run a card program in the web emulator (web/placard_emu.js,
with node) from a script of keys and mouse moves, for test_pinboard.py

    run(files, inputs, shots, frames)

files   {path: bytes} of the card (sdimage.from_folder plus BOOT.CFG)
inputs  [(frame, kind, value)]: 'press' / 'release' a PS/2 set 2 code
        (0x100 = E0), 'mouse' (dx, dy, buttons)
shots   frames at which the RAM is kept
returns {frame: RAM bytes (65536)}, and the card image at the end

screen_png(ram, path) draws a RAM's screen; cells(ram, font) reads the
80 x 60 characters of a 1 bpp screen back through a font.

Date: 11/16/2026
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
m.audioMax = 0;
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
console.log(JSON.stringify({pc: m.pc, map: m.map}));
'''

# how cells() shows Pinboard's own characters 00-11: blank, the board, a
# card's edges and corners, the pin, the arrows, the file pictures (F a
# folder, P a program, f a file, { the folder above), the scroll bar
LEGEND = ' .<>_[]*^v?FPf{:-#'

_rom = None


def rom_image():
    global _rom
    if _rom is None:
        prog, _, _ = ps.assemble(open(os.path.join(HERE, 'rom32.asm')).read(), HERE)
        _rom = ps.image_32k(ps.build_rom(prog, HERE))
    return _rom


def run(files, inputs, shots, frames, mouse=True, px=0x38):
    tmp = tempfile.mkdtemp()
    p = lambda n: os.path.join(tmp, n)   # noqa: E731
    open(p('rom.bin'), 'wb').write(rom_image())
    open(p('card.img'), 'wb').write(sdimage.make(files))
    open(p('run.js'), 'w').write(NODE_RUN)
    shots = sorted(set(shots))
    json.dump({'rom': p('rom.bin'), 'card': p('card.img'), 'frames': frames, 'mouse': mouse, 'px': px,
               'inputs': sorted(inputs, key=lambda i: i[0]), 'shots': shots, 'dir': tmp},
              open(p('cfg.json'), 'w'))
    js = subprocess.run(['node', p('run.js'),
                         os.path.abspath(os.path.join(REPO, 'web', 'placard_emu.js')),
                         p('cfg.json')], capture_output=True, text=True)
    if js.returncode:
        raise RuntimeError('node: ' + js.stderr)
    rams = {f: open(p('ram%d.bin' % f), 'rb').read() for f in shots if f < frames}
    return rams, open(p('card.out'), 'rb').read()


def screen_png(ram, path):
    ps.render(bytearray(ram), path)


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
