#!/usr/bin/env python3
"""
test_fs.py - test the FAT file reading (placard_fs.asm) in the simulator

    python3 test_fs.py              run every test
    python3 test_fs.py -k fat32     run the tests whose name contains "fat32"

The card images are made with the standard Linux tools (mkfs.fat from
dosfstools, mcopy and mmd from mtools), so the driver is checked against
file systems it did not make itself: FAT16 and FAT32, with and without a
partition table, 1 to 4 sectors per cluster, a fragmented file, files
whose cluster chains cross a FAT sector, a folder, a long file name and
an empty file.  The SD card is io_devices.SdCard on the shared port.
Without those tools the tests are skipped.

Date: 10/18/2026
"""

import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import io_devices as iod    # noqa: E402

ROUTINES = ['port_init', 'sd_init', 'fs_mount', 'fs_root', 'fs_next', 'fs_open',
            'fs_read', 'fs_load']
ARG_AC = 0x20
NAME = 0x0700               # name strings for fs_open and fs_load
LOAD = 0x7000               # fs_load / fs_read buffer, up to xDFFF
TOOLS = all(shutil.which(t) for t in ('mkfs.fat', 'mcopy', 'mmd', 'mdel'))


def call(target, n):
    back = 'back_%d' % n
    return ['    ld   LINK_LO, x', '    ld   %s, [x]' % back, '    ld   LINK_HI, x',
            '    ld   %s >> 8, [x]' % back, '    ld   %s >> 8, y' % target,
            '    jmp  %s' % target, back + ':']


def build_source():
    src = ['#include "placard.asm"', '#include "placard_lib.asm"', '',
           '#addr 0x0000', 'reset:', '    ld   main >> 8, y', '    jmp  main', '',
           '#addr 0x0100', 'main:', '    bra  main']
    for n, r in enumerate(ROUTINES):
        if n % 6 == 0:
            src.append('#addr 0x%04X' % (0x0200 + (n // 6) * 0x100))
        src += ['drv_%s:' % r, '    ld   [0x%02X], ac' % ARG_AC]
        src += call(r, n)
        src += ['    ld   ac, [0x%02X]' % ARG_AC, 'halt_%s:' % r, '    bra  halt_%s' % r]
    return '\n'.join(src) + '\n'


# ---------------------------------------------------------------------------
# card images
# ---------------------------------------------------------------------------
def sh(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Image:
    """a FAT volume made by mkfs.fat, optionally behind a partition table"""

    def __init__(self, fat, mb, spc, part_at=0):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, 'vol.img')
        sh('mkfs.fat', '-C', '-F', str(fat), '-s', str(spc), '-n', 'PLACARD', self.path, str(mb * 1024))
        self.part_at = part_at
        self.files = {}

    def put(self, name, data, folder=''):
        p = os.path.join(self.dir, 'f.bin')
        open(p, 'wb').write(bytes(data))
        sh('mcopy', '-i', self.path, p, '::' + folder + '/' + name)
        self.files[(folder + '/' + name).upper()] = bytes(data)

    def mkdir(self, name):
        sh('mmd', '-i', self.path, '::' + name)

    def delete(self, name):
        sh('mdel', '-i', self.path, '::' + name)

    def card(self):
        vol = open(self.path, 'rb').read()
        shutil.rmtree(self.dir)
        if not self.part_at:
            return bytearray(vol)
        img = bytearray(self.part_at * 512) + bytearray(vol)
        e = 0x1BE                                  # partition 1
        img[e + 4] = 0x0E                          # FAT16 LBA (0x0C for FAT32 works the same)
        img[e + 8:e + 12] = self.part_at.to_bytes(4, 'little')
        img[e + 12:e + 16] = (len(vol) // 512).to_bytes(4, 'little')
        img[0x1FE], img[0x1FF] = 0x55, 0xAA
        return img


def data(n, seed):
    r = random.Random(seed)
    return bytes(r.randrange(256) for _ in range(n))


# ---------------------------------------------------------------------------
# the CPU side
# ---------------------------------------------------------------------------
class Rig:
    def __init__(self, image):
        self.mem, self.syms, _ = ps.assemble(build_source(), HERE)
        self.port = iod.SharedPort()
        self.port.sd = iod.SdCard(image)
        self.cpu = ps.Cpu(self.mem, io=self.port)
        self.cpu.mem[self.syms['SP']] = 0xFF
        self.call('port_init')
        assert self.call('sd_init') == 0, 'sd_init'

    def call(self, name, ac=0, max_steps=40_000_000, **regs):
        cpu = self.cpu
        for k, v in regs.items():
            cpu.mem[self.syms[k]] = v & 0xFF
        cpu.mem[ARG_AC] = ac
        cpu.pc = self.syms['drv_' + name]
        sp = cpu.mem[self.syms['SP']]
        c0 = cpu.clocks
        r = cpu.run(max_steps, halt_detect=False, stop_pc=self.syms['halt_' + name])
        assert r == 'stop', '%s did not return (PC=%04X)' % (name, cpu.pc)
        assert cpu.mem[self.syms['SP']] == sp, '%s moved SP' % name
        self.clocks = cpu.clocks - c0
        return cpu.mem[ARG_AC]

    def r(self, n):
        return self.cpu.mem[self.syms['R%d' % n]]

    def name(self, s):
        for i, c in enumerate(s.encode() + b'\0'):
            self.cpu.mem[NAME + i] = c
        return dict(R0=NAME & 0xFF, R1=NAME >> 8)

    def entry(self):
        m = self.cpu.mem
        a = self.syms['FS_ENTRY']
        e = bytes(m[a:a + 32])
        base, ext = e[0:8].decode().rstrip(), e[8:11].decode().rstrip()
        return (base + ('.' + ext if ext else '')), e[11], int.from_bytes(e[28:32], 'little')

    def listing(self):
        assert self.call('fs_root') == 0
        out = []
        while True:
            a = self.call('fs_next')
            if a == 1:
                return out
            assert a == 0, 'fs_next error %d' % a
            assert (self.r(0) | self.r(1) << 8) == self.syms['FS_ENTRY']
            out.append(self.entry())

    def load(self, name, at=LOAD):
        a = self.call('fs_load', **self.name(name), R4=at & 0xFF, R5=at >> 8)
        return a, self.clocks

    def got(self, n, at=LOAD):
        return bytes(self.cpu.mem[at:at + n])


def skip_without_tools(f):
    def g():
        if not TOOLS:
            return 'skipped: needs mkfs.fat (dosfstools) and mtools'
        return f()
    g.__name__ = f.__name__
    return g


def standard(fat, mb, spc, part_at, filler):
    """an image with: HELLO.TXT, a file crossing a FAT sector and
    fragmented around a deleted file, a folder with a file, a long name
    and an empty file"""
    im = Image(fat, mb, spc, part_at)
    im.put('HELLO.TXT', b'Hello from the SD card!\n' * 4)
    im.put('FILLER.BIN', data(filler, 1))
    im.put('GAP.BIN', data(3000, 2))
    im.put('MID.BIN', data(700, 3))
    im.delete('GAP.BIN')
    im.put('BIG.BIN', data(9000, 4))           # fills the gap, then goes on
    im.mkdir('GAMES')
    im.put('PONG.BIN', data(1300, 5), 'GAMES')
    im.put('longfilename.txt', b'long name\n')
    im.put('EMPTY.DAT', b'')
    return im


def check_volume(rig, im):
    names = [n for n, _, _ in rig.listing()]
    for want in ('HELLO.TXT', 'FILLER.BIN', 'MID.BIN', 'BIG.BIN', 'GAMES', 'LONGFI~1.TXT',
                 'EMPTY.DAT'):
        assert want in names, '%s not listed: %s' % (want, names)
    assert 'GAP.BIN' not in names, 'deleted file listed'
    worst = 0
    for name in ('HELLO.TXT', 'MID.BIN', 'BIG.BIN', 'longfi~1.txt'):
        want = im.files['/' + name.upper()] if name != 'longfi~1.txt' else b'long name\n'
        a, clocks = rig.load(name)
        assert a == 0, 'fs_load %s: %d' % (name, a)
        assert rig.got(len(want)) == want, '%s: wrong data' % name
        if name == 'BIG.BIN':
            worst = clocks / ((len(want) + 511) // 512)
    a, _ = rig.load('NOPE.TXT')
    assert a == 2, 'missing file: %d' % a
    rig.cpu.mem[LOAD] = 0x5A
    a, _ = rig.load('EMPTY.DAT')
    assert a == 0 and rig.cpu.mem[LOAD] == 0x5A, 'empty file: %d' % a
    # a folder, its listing, a file in it, and back up with ".."
    assert rig.call('fs_root') == 0
    assert rig.call('fs_open', **rig.name('games')) == 0
    sub = [n for n, _, _ in sub_listing(rig)]
    assert sub == ['.', '..', 'PONG.BIN'], sub
    assert rig.call('fs_open', **rig.name('PONG.BIN')) == 0
    want = im.files['GAMES/PONG.BIN']
    at, n = LOAD, 0
    while True:
        a = rig.call('fs_read', R4=at & 0xFF, R5=at >> 8)
        if a == 1:
            break
        assert a == 0, 'fs_read %d' % a
        at += 512
        n += 1
    assert n == 3 and rig.got(len(want)) == want, 'PONG.BIN: %d sectors' % n
    assert rig.call('fs_root') == 0
    assert rig.call('fs_open', **rig.name('GAMES')) == 0
    assert rig.call('fs_open', **rig.name('..')) == 0
    assert rig.call('fs_open', **rig.name('hello.txt')) == 0
    assert rig.call('fs_read', R4=0, R5=LOAD >> 8) == 0
    assert rig.got(24) == b'Hello from the SD card!\n'
    first = rig.call('fs_next') == 0 and rig.entry()[0]
    assert first == 'HELLO.TXT', 'fs_next after a file did not start over: %r' % (first,)
    assert rig.call('fs_open', **rig.name('GAMES')) == 0
    a, _ = rig.load('pong.bin')
    assert a == 0 and rig.got(1300) == im.files['GAMES/PONG.BIN'], 'fs_load in a folder'
    return worst


def sub_listing(rig):
    out = []
    while True:
        a = rig.call('fs_next')
        if a == 1:
            return out
        assert a == 0
        out.append(rig.entry())


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------
@skip_without_tools
def test_fat16_no_partition():
    im = standard(16, 3, 1, 0, 120_000)        # BIG.BIN's chain crosses cluster 256
    rig = Rig(im.card())
    assert rig.call('fs_mount') == 0, 'fs_mount'
    mount = rig.clocks
    per = check_volume(rig, im)
    return 'mount %d clocks; BIG.BIN %d clocks per 512 bytes (%.0f KB/s)' % (
        mount, per, 25.175e6 / per / 2)


@skip_without_tools
def test_fat16_partition_4spc():
    im = standard(16, 20, 4, 63, 200_000)
    rig = Rig(im.card())
    assert rig.call('fs_mount') == 0, 'fs_mount'
    check_volume(rig, im)
    return 'partition at sector 63, 4 sectors per cluster'


@skip_without_tools
def test_fat32_partition():
    im = standard(32, 34, 1, 2048, 60_000)     # chains cross FAT sectors (128 entries)
    rig = Rig(im.card())
    assert rig.call('fs_mount') == 0, 'fs_mount'
    check_volume(rig, im)
    return 'FAT32, partition at sector 2048, 1 sector per cluster'


@skip_without_tools
def test_errors():
    rig = Rig(bytearray(512 * 64))
    assert rig.call('fs_root') == 8, 'not mounted'
    assert rig.call('fs_mount') == 9, 'blank card'
    im = Image(12, 1, 1)
    rig = Rig(im.card())
    assert rig.call('fs_mount') == 10, 'FAT12'
    return 'not mounted 8, blank card 9, FAT12 10'


TESTS = [(n, f) for n, f in sorted(globals().items()) if n.startswith('test_')]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('-k', default='')
    args = ap.parse_args(argv)
    bad = 0
    for name, f in TESTS:
        if args.k not in name:
            continue
        try:
            print('ok    %-28s %s' % (name, f() or ''))
        except AssertionError as e:
            bad += 1
            print('FAIL  %-28s %s' % (name, e))
    print('%d failed' % bad if bad else 'all passed')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
