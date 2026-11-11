#!/usr/bin/env python3
"""
gen_bringup_screens.py - example monitor pictures for docs/hardware/BRINGUP.md

For each bring-up step where the picture on the monitor changes, this
draws what the person assembling the board should see.  Steps 5-13 (no
software yet) come from the clock-by-clock video PLD model in
bringup_signals.py (Sync, H counter, V counter, audio slot and color
decoder equations), wired as each step wires them: the straps, the pin
keepers that hold an undriven input where it powered up, the stuck row
bits while the audio slot PLD is out, and the RAM chips that are in.
Every clock gives one pixel: the color decoder's outputs for the pixel
buffer and line code at that clock, gated by VIDEN, so the 8-pixel
stripes, the bands and the blank lines fall where the hardware puts them.

Steps 22-24 run the bring-up ROM in the simulator (test_bringup_sim.py)
and draw its status screen.

The RAM powers up random, so the pictures with RAM in them are examples:
the pattern on a real board differs in its details, not its look.  The
seed is fixed so the images don't change from run to run.

    python3 gen_bringup_screens.py            all images
    python3 gen_bringup_screens.py --hw       steps 5-13 only (fast)
    python3 gen_bringup_screens.py --rom      steps 22-24 only

Images go to docs/hardware/bringup_screens/.  The ROM part takes about
4 minutes.

Date: 2026-11-11
"""

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bringup_signals as bs  # noqa: E402

OUT = os.path.join(HERE, '..', '..', 'docs', 'hardware', 'bringup_screens')
W, H = 640, 480
MODE_NAMES = {0: '1 bpp (2 colors)', 1: '2 bpp (4 colors)', 2: '4 bpp (16 colors)', 3: '8 bpp (256 colors)'}
TINT = 73        # row tint, about 0.2 V of 0.7 V on a channel (as placard_sim.render)


def rgb8(b):
    r = (b & 7) * 255 // 7
    bl = ((b >> 3) & 3) * 255 // 3
    g = ((b >> 5) & 7) * 255 // 7
    return (r, g, bl)


def dac(outs):
    """color decoder outputs (bringup_signals.color) -> the 8-bit RGB332 the
    resistors make (RED1-3 = R, BLU2-3 = B, GRN1-3 = G, low bit first)"""
    v = (outs['RED1 (pin 15)'] | outs['RED2 (pin 16)'] << 1 | outs['RED3 (pin 21)'] << 2
         | outs['BLU2 (pin 22)'] << 3 | outs['BLU3 (pin 18)'] << 4
         | outs['GRN1 (pin 17)'] << 5 | outs['GRN2 (pin 20)'] << 6 | outs['GRN3 (pin 19)'] << 7)
    return v


_COLOR_CACHE = {}


def pixel(pix, mode, h, viden):
    k = (pix, mode, h, viden)
    v = _COLOR_CACHE.get(k)
    if v is None:
        v = dac(bs.color(pix, mode, h, viden))
        _COLOR_CACHE[k] = v
    return v


def raster_positions():
    """the capture start S (a clock in the second frame, at the first
    visible pixel of the top line) and the clock, counted from S, of each
    of the 640 x 480 visible pixels in raster order: the clocks where
    VIDEN is high on a frame with no blank lines"""
    vid = bs.Video(blank_rd=False, lc_from_bus=False)
    on = []
    for clk in range(3 * bs.FRAME):
        c = vid.comb()
        if clk >= bs.FRAME and vid.viden:
            on.append((clk, vid.v))
        vid.clock(c)
    top = min(v for _, v in on)
    start = min(clk for clk, v in on if v == top)
    pos = [clk - start for clk, _ in on if start <= clk < start + bs.FRAME]
    assert len(pos) == W * H, len(pos)
    return start, pos


class Board:
    """the video as wired at one bring-up step.

    pix_load: 'none' (no pixel buffer: pix is the pin-keeper value),
              'every' (strap S3: the buffer loads every clock),
              'pe' (Branch PLD in: loads on PIXEL_ENABLE)
    audio:    the audio slot PLD U35 and line code U23 are in (mode bytes,
              line repeats, tints, blank lines); else MODE1:MODE0 and the
              row bits R8, R7, R1, R0 sit where they powered up
    ram_lo, ram_hi: U31 / U32 in (else that half reads FF from RN1)
    """

    def __init__(self, pix_load='none', audio=False, ram_lo=False, ram_hi=False,
                 pix=0, mode=0, rows=(0, 0, 0, 0), cpu_addr=0, seed=1):
        self.pix_load = pix_load
        self.audio = audio
        self.mode = mode
        self.rows = rows
        self.cpu_addr = cpu_addr
        rnd = random.Random(seed)
        self.ram = bytearray(rnd.getrandbits(8) for _ in range(65536))
        if not ram_lo:
            self.ram[0:0x8000] = b'\xff' * 0x8000
        if not ram_hi:
            self.ram[0x8000:] = b'\xff' * 0x8000
        self.vid = bs.Video(blank_rd=audio, lc_from_bus=False)
        self.vid.pix = pix

    def frame(self, raster):
        start, pos = raster
        vid, ram = self.vid, self.ram
        frame = [0] * bs.FRAME
        tint = [0] * bs.FRAME
        for clk in range(start + bs.FRAME):
            c = vid.comb()
            if not self.audio:
                c['r8'], c['r7'], c['r1'], c['r0'] = self.rows
            mode = (vid.lc & 3) if self.audio else self.mode
            if clk >= start:
                h = vid.h2 * 4 + vid.h1 * 2 + vid.h0
                frame[clk - start] = pixel(vid.pix, mode, h, vid.viden)
                if self.audio and vid.viden:
                    tint[clk - start] = (vid.lc >> 4) & 7
            # the data bus this clock: the video address on a video read,
            # else the CPU side's address (held still with no CPU)
            addr = vid.video_addr(c) if vid.pe else self.cpu_addr
            bus = ram[addr]
            pe = vid.pe
            mode_ld = c['mode_ld']
            old_pix = vid.pix
            vid.clock(c)
            if self.pix_load == 'every' or (self.pix_load == 'pe' and pe):
                vid.pix = bus
            else:
                vid.pix = old_pix
            if self.audio and mode_ld:
                vid.lc = vid.pix
        return to_image(frame, tint, pos)


def to_image(frame, tint, pos):
    from PIL import Image
    img = Image.new('RGB', (W, H))
    px = img.load()
    for i, clk in enumerate(pos):
        r, g, b = rgb8(frame[clk])
        t = tint[clk]
        if t:
            r = min(255, r + (TINT if t & 1 else 0))
            g = min(255, g + (TINT if t & 2 else 0))
            b = min(255, b + (TINT if t & 4 else 0))
        px[i % W, i // W] = (r, g, b)
    return img


def save(img, name):
    """the picture inside a thin gray frame, so a black screen still shows
    as a screen on a white page"""
    from PIL import Image
    f = Image.new('RGB', (img.width + 8, img.height + 8), (96, 96, 96))
    f.paste(img, (4, 4))
    path = os.path.join(OUT, name)
    f.save(path, optimize=True)
    print('wrote', os.path.relpath(path))


def grid(imgs, labels, name):
    """2 x 2 panels, full size, each with its label above it"""
    from PIL import Image, ImageDraw
    lab = 28
    pw, ph = W + 8, H + 8 + lab
    g = Image.new('RGB', (2 * pw + 16, 2 * ph + 8), (255, 255, 255))
    d = ImageDraw.Draw(g)
    font = label_font(20)
    for k, (im, t) in enumerate(zip(imgs, labels)):
        x, y = (k % 2) * (pw + 16), (k // 2) * (ph + 8)
        d.text((x + 4, y + 2), t, fill=(0, 0, 0), font=font)
        d.rectangle((x, y + lab, x + W + 7, y + lab + H + 7), fill=(96, 96, 96))
        g.paste(im, (x + 4, y + lab + 4))
    path = os.path.join(OUT, name)
    g.save(path, optimize=True)
    print('wrote', os.path.relpath(path))


def label_font(size):
    from PIL import ImageFont
    for f in ('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
              '/usr/share/fonts/dejavu/DejaVuSans.ttf'):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def hardware_steps():
    from PIL import Image
    pos = raster_positions()
    # step 5 (no color decoder) and step 13 (no RAM: every line blank)
    save(Image.new('RGB', (W, H)), 'step05_black.png')
    # step 6: the color decoder alone, inputs on the pin keepers
    save(Board(pix=0x6C, mode=1).frame(pos), 'step06_powerup.png')
    save(Board(pix=0x00, mode=0).frame(pos), 'step06_ground.png')
    save(Board(pix=0xFF, mode=3).frame(pos), 'step06_power.png')
    ex = [(0x0F, 0), (0x1B, 1), (0x94, 2), (0x5A, 3)]
    grid([Board(pix=p, mode=m).frame(pos) for p, m in ex],
         ['%s, pixel pins %02X' % (MODE_NAMES[m], p) for p, m in ex], 'step06_explore.png')
    # steps 8-10, each in the four modes MODE1:MODE0 can power up in.
    # The CPU side's address (no PC, D, X, Y yet) is some address in U31.
    cpu = 0x2C35
    for step, kw in ((8, dict(pix_load='every', ram_lo=True)),
                     (9, dict(pix_load='pe', ram_lo=True)),
                     (10, dict(pix_load='pe', ram_lo=True, ram_hi=True))):
        imgs = [Board(mode=m, rows=(1, 0, 1, 0), cpu_addr=cpu, seed=step, **kw).frame(pos)
                for m in range(4)]
        grid(imgs, [MODE_NAMES[m] for m in range(4)], 'step%02d_modes.png' % step)
    # step 11: the audio slot PLD and line code in, random mode bytes
    save(Board(pix_load='pe', audio=True, ram_lo=True, ram_hi=True, seed=11).frame(pos),
         'step11_random.png')


def bringup_rom():
    """the bring-up ROM as the cartridge shows it to the CPU"""
    import placard_sim as ps
    import gen_bringup as gb
    import test_bringup_sim as tb
    mem, syms = tb.build()
    if hasattr(gb, 'image'):                       # the 32K bring-up ROM
        img = gb.image(mem)
        rom = {a: img[a & 0x7FFF] for a in range(65536)}
    else:
        rom = dict(mem)
    return ps, tb, rom, syms


def rom_steps():
    """steps 22-24: the status screen from the simulator"""
    import io_devices as iod
    import sdimage
    ps, tb, rom, syms = bringup_rom()

    def boot(rig):
        cpu = rig.cpu
        while cpu.pc != syms['frame_loop']:
            cpu.step()
            assert cpu.pc not in tb.FAILS, 'fail loop %d' % tb.FAILS[cpu.pc]
            assert cpu.clocks < 40 * tb.CLOCKS_PER_FRAME, 'no frame loop'
        assert rig.frames(60) is None              # about a second of the frame loop

    def shot(rig, name):
        path = os.path.join(OUT, '_tmp.png')
        ps.render(rig.cpu.mem, path)
        from PIL import Image
        save(Image.open(path).convert('RGB'), name)
        os.remove(path)

    # step 22: the shared port PLDs aren't in yet, so nothing answers on
    # the port: no keyboard, mouse or SD card
    rig = tb.Rig(rom, sd=False, mouse=False)
    rig.port.kbd = None
    rig.port._link()
    boot(rig)
    shot(rig, 'step22_status.png')

    # step 23: keyboard, mouse, a FAT card and a pad plugged in (power off)
    rig = tb.Rig(rom, sd=False, mouse=True)
    rig.port.sd = iod.SdCard(bytearray(sdimage.make({})))
    boot(rig)

    def press(k, frames=6):
        rig.port.kbd.press(k)
        assert rig.frames(frames) is None
        rig.port.kbd.release(k)
        assert rig.frames(frames) is None
    for k in (0x4D, 0x4B, 0x1C, 0x21, 0x1C, 0x2D, 0x23):    # "placard"
        press(k)
    rig.port.mouse.move(dx=120, dy=-45)
    rig.port.pads[0].buttons = 0x0001                       # pad 1: B held
    assert rig.frames(4) is None
    rig.port.kbd.press(0x1C)                                # a held: its KBD_NOW bit clears
    assert rig.frames(6) is None
    shot(rig, 'step23_io.png')
    rig.port.kbd.release(0x1C)
    rig.port.pads[0].buttons = 0
    assert rig.frames(6) is None

    # step 24: T turns on the test tone
    press(0x2C)
    shot(rig, 'step24_tone.png')


def main(argv):
    os.makedirs(OUT, exist_ok=True)
    hw = '--rom' not in argv
    rom = '--hw' not in argv
    if hw:
        hardware_steps()
    if rom:
        rom_steps()


if __name__ == '__main__':
    main(sys.argv[1:])
