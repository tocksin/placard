#!/usr/bin/env python3
"""160-read lines (rev B board, mode byte bit 7): placard_sim against the
browser emulator's core (web/placard_emu.js, needs node).

Fills the RAM with random bytes and random mode bytes (every color mode and
repeat, bit 7 on half the rows), then compares the two renderers pixel for
pixel and the two stall models clock for clock, for rev A and rev B.

  python3 src/scripts/test_hires.py [--png out.png]
"""
import argparse, json, os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import placard_sim as ps

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JS = r'''
const fs = require('fs');
const P = require(process.argv[2]);
const cfg = JSON.parse(fs.readFileSync(process.argv[3]));
const ram = new Uint8Array(fs.readFileSync(cfg.ram));
const out = {};
for (const rev of ['a', 'b']) {
    const fb = new Uint32Array(640 * 480);
    for (let y = 0; y < 480; y++) P.renderRow(ram, y, fb, rev === 'b');
    fs.writeFileSync(cfg.out + rev, Buffer.from(fb.buffer));
    const m = new P.Machine();
    m.ram.set(ram);
    m.revB = rev === 'b';
    const st = [];
    for (const [t, n] of cfg.steps) { m.clocks = t; st.push(m.withStalls(n)); }
    out[rev] = st;
}
console.log(JSON.stringify(out));
'''


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--png', help='the rev B screen as a PNG')
    args = ap.parse_args(argv)
    rnd = random.Random(160)
    mem = {a: rnd.randrange(256) for a in range(0x10000)}
    for y in range(480):
        band = y // 8
        mem[ps.MODE_BASE + y] = (band & 0x0F) | (0x80 if band & 0x10 else 0) | (0x20 if band % 7 == 0 else 0)
    steps = [(rnd.randrange(800 * 525 * 3), rnd.randrange(1, 40)) for _ in range(4000)]
    errs = 0
    with tempfile.TemporaryDirectory() as tmp:
        ramf = os.path.join(tmp, 'ram.bin')
        open(ramf, 'wb').write(bytes(mem[a] for a in range(0x10000)))
        cfg = os.path.join(tmp, 'cfg.json')
        json.dump({'ram': ramf, 'out': os.path.join(tmp, 'fb_'), 'steps': steps}, open(cfg, 'w'))
        jsf = os.path.join(tmp, 't.js')
        open(jsf, 'w').write(JS)
        r = subprocess.run(['node', jsf, os.path.join(ROOT, 'web', 'placard_emu.js'), cfg],
                           capture_output=True, text=True)
        if r.returncode:
            print(r.stderr)
            return 1
        js = json.loads(r.stdout)
        from PIL import Image
        for rev in 'ab':
            png = os.path.join(tmp, rev + '.png')
            ps.render(mem, png, rev == 'b')
            py = Image.open(png).convert('RGB').tobytes()
            raw = open(os.path.join(tmp, 'fb_' + rev), 'rb').read()
            jsrgb = bytes(b for i in range(0, len(raw), 4) for b in raw[i:i + 3])
            bad = sum(1 for i in range(0, len(py), 3) if py[i:i + 3] != jsrgb[i:i + 3])
            print(f'rev {rev.upper()}: screen, {bad} of 307200 pixels differ')
            errs += bad
            cpu = ps.Cpu(dict(mem))
            cpu.rev_b = rev == 'b'
            st = []
            for t, n in steps:
                cpu.clocks = t
                st.append(cpu.with_stalls(n))
            bad = sum(1 for a, b in zip(st, js[rev]) if a != b)
            print(f'rev {rev.upper()}: stall clocks, {bad} of {len(steps)} steps differ '
                  f'({sum(st) - sum(n for _, n in steps)} stall clocks in all)')
            errs += bad
            if rev == 'b' and args.png:
                ps.render(mem, args.png, True)
        # the share of clocks the video takes on a full 160-read screen
        for y in range(480):
            mem[ps.MODE_BASE + y] = 0x86
        cpu = ps.Cpu(dict(mem))
        cpu.rev_b = True
        cpu.clocks = 0
        n = 300000
        wall = cpu.with_stalls(n)
        share = 100.0 * (wall - n) / wall
        print(f'full 160-read screen: {share:.1f} % of the clocks are video reads')
        if not 18.0 < share < 18.6:
            errs += 1
    print('PASS' if not errs else f'FAIL ({errs})')
    return 1 if errs else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
