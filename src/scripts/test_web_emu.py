#!/usr/bin/env python3
"""
test_web_emu.py - check the web emulator (web/placard_emu.js) against
placard_sim.py and io_devices.py

    python3 test_web_emu.py                 the checks below (needs node)
    python3 test_web_emu.py --frames 600 --png web.png

Both boot the 32K image (rom32.asm) from a zeroed RAM, with the video
stall clocks, a PS/2 keyboard and mouse and an SD card holding the
sdcard/ folder, and are given the same keys and mouse moves at the same
clocks.  Checked:
  1. every 50,000 instructions: the PC, AC, X, Y, carry, map, clock count
     and a CRC of the RAM are the same
  2. at the end: the SD card image and the screen (the JS row renderer on
     the final RAM against placard_sim.render) are the same
The JS run's own screen (drawn line by line as the beam goes) is written
with --png.

Date: 10/27/2026
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import io_devices             # noqa: E402
import sdimage                # noqa: E402

REPO = os.path.join(HERE, '..', '..')
FRAME = 525 * 800
EVERY = 50000

# (frame, kind, value): keys are PS/2 set 2 codes (0x100 = E0)
INPUTS = [
    (100, 'press', 0x172), (102, 'release', 0x172),     # Down
    (110, 'press', 0x172), (112, 'release', 0x172),
    (120, 'mouse', (5, -3, 1)), (126, 'mouse', (-2, 7, 0)),
    (140, 'press', 0x76), (142, 'release', 0x76),       # Esc
    (160, 'press', 0x5A), (162, 'release', 0x5A),       # Enter
]

NODE_RUN = r'''
const fs = require('fs');
const P = require(process.argv[2]);
const cfg = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const m = new P.Machine();
m.setRom(new Uint8Array(fs.readFileSync(cfg.rom)));
m.reset(false, 0);
m.audioMax = 0;
m.io.kbd = new P.Ps2Keyboard();
m.io.mouse = new P.Ps2Mouse();
m.io.sd = new P.SdCard(new Uint8Array(fs.readFileSync(cfg.card)));
const zlib = require('zlib');
const out = [];
let k = 0;
const end = cfg.frames * P.FRAME;
while (m.clocks < end) {
    while (k < cfg.inputs.length && m.clocks >= cfg.inputs[k][0]) {
        const [, kind, v] = cfg.inputs[k++];
        if (kind === 'press') m.io.kbd.press(v);
        else if (kind === 'release') m.io.kbd.release(v);
        else m.io.mouse.move(v[0], v[1], v[2]);
    }
    if (!m.step()) { console.error(m.error); process.exit(2); }
    while (m.clocks >= m.nextEvt) m.event();
    if (m.steps % cfg.every === 0) {
        out.push([m.steps, m.pc, m.ac, m.x, m.y, m.c, m.map, m.clocks, zlib.crc32(m.ram)]);
    }
}
fs.writeFileSync(cfg.cardOut, m.io.sd.image);
const fb = new Uint32Array(640 * 480);
for (let y = 0; y < 480; y++) P.renderRow(m.ram, y, fb);
fs.writeFileSync(cfg.screenOut, Buffer.from(fb.buffer));
fs.writeFileSync(cfg.liveOut, Buffer.from(m.fb.buffer));
console.log(JSON.stringify(out));
'''


def rgb_bytes(raw):
    """RGB bytes of an RGBA little-endian word buffer"""
    out = bytearray()
    for i in range(0, len(raw), 4):
        out += raw[i:i + 3]
    return bytes(out)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', type=int, default=200)
    ap.add_argument('--png', help='the JS run\'s screen as a PNG')
    args = ap.parse_args(argv)

    prog, _, _ = ps.assemble(open(os.path.join(HERE, 'rom32.asm')).read(), HERE)
    rom = ps.build_rom(prog, HERE)
    card = sdimage.make(sdimage.from_folder(os.path.join(REPO, 'sdcard')))
    inputs = [(f * FRAME, kind, v) for f, kind, v in INPUTS]

    tmp = tempfile.mkdtemp()
    p = lambda n: os.path.join(tmp, n)
    open(p('rom.bin'), 'wb').write(ps.image_32k(rom))
    open(p('card.img'), 'wb').write(card)
    open(p('run.js'), 'w').write(NODE_RUN)
    json.dump({'rom': p('rom.bin'), 'card': p('card.img'), 'frames': args.frames,
               'every': EVERY, 'inputs': inputs, 'cardOut': p('card_js.img'),
               'screenOut': p('screen.raw'), 'liveOut': p('live.raw')}, open(p('cfg.json'), 'w'))
    js = subprocess.run(['node', p('run.js'), os.path.abspath(os.path.join(REPO, 'web', 'placard_emu.js')),
                         p('cfg.json')], capture_output=True, text=True)
    if js.returncode:
        print(js.stderr)
        print('FAIL: node run')
        return 1
    js_points = json.loads(js.stdout)

    port = io_devices.SharedPort()
    port.kbd = io_devices.Ps2Keyboard()
    port.mouse = io_devices.Ps2Mouse()
    port.sd = io_devices.SdCard(bytearray(card))
    cpu = ps.Cpu({}, rom=rom, io=port)
    cpu.stalls = True
    py_points = []
    k = 0
    end = args.frames * FRAME
    while cpu.clocks < end:
        while k < len(inputs) and cpu.clocks >= inputs[k][0]:
            _, kind, v = inputs[k]
            k += 1
            if kind == 'press':
                port.kbd.press(v)
            elif kind == 'release':
                port.kbd.release(v)
            else:
                port.mouse.move(*v)
        cpu.step()
        if cpu.steps % EVERY == 0:
            py_points.append([cpu.steps, cpu.pc, cpu.ac, cpu.x, cpu.y, int(cpu.c), cpu.map,
                              cpu.clocks, zlib.crc32(bytes(cpu.mem))])

    ok = True
    names = ['steps', 'PC', 'AC', 'X', 'Y', 'C', 'map', 'clocks', 'RAM CRC']
    for a, b in zip(py_points, js_points):
        if a != b:
            diff = ', '.join('%s %s/%s' % (n, x, y) for n, x, y in zip(names, a, b) if x != y)
            print('FAIL: at %d instructions (Python/JS): %s' % (a[0], diff))
            ok = False
            break
    if len(py_points) != len(js_points):
        print('FAIL: %d checkpoints in Python, %d in JS' % (len(py_points), len(js_points)))
        ok = False
    print('1. %d checkpoints over %d frames (%d instructions, %d clocks, %d stall clocks): %s'
          % (len(py_points), args.frames, cpu.steps, cpu.clocks, cpu.stall_clocks,
             'same' if ok else 'DIFFERENT'))

    card_same = bytes(port.sd.image) == open(p('card_js.img'), 'rb').read()
    print('2. SD card after the run: %s (%d block reads, %d writes in Python)'
          % ('same' if card_same else 'DIFFERENT', port.sd.reads, port.sd.writes))
    ok &= card_same
    try:
        from PIL import Image
        ps.render(cpu.mem, p('py.png'))
        py_rgb = Image.open(p('py.png')).convert('RGB').tobytes()
        js_rgb = rgb_bytes(open(p('screen.raw'), 'rb').read())
        same = py_rgb == js_rgb
        print('   screen: %s' % ('same' if same else 'DIFFERENT'))
        ok &= same
        if args.png:
            Image.frombytes('RGB', (640, 480), rgb_bytes(open(p('live.raw'), 'rb').read())).save(args.png)
            print('   wrote', args.png)
    except ImportError:
        print('   (no PIL: screen not compared)')
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
