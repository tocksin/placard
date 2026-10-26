#!/usr/bin/env python3
"""
test_fsw.py - test the FAT file writer (placard_fsw.masm) in the simulator

    python3 test_fsw.py              run every test
    python3 test_fsw.py -k fat32     the tests whose name contains "fat32"

Cards are made with mkfs.fat and mtools (as test_fs.py does); after the
Placard has written to them, the result is checked with the PC's tools:
fsck.fat finds no errors, mtype reads back the files, mdir lists them.
Without the tools the tests are skipped.

Date: 10/25/2026
"""

import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402
import io_devices as iod    # noqa: E402
import test_fs as tf        # noqa: E402

ROUTINES = ['port_init', 'sd_init', 'fs_mount', 'fs_root', 'fs_next', 'fs_open',
            'fs_read', 'fs_load', 'fs_create', 'fs_write', 'fs_close', 'fs_delete', 'fs_save']
TOOLS = tf.TOOLS and shutil.which('fsck.fat') and shutil.which('mtype') and shutil.which('mdir')
SRC = 0x7000                # memory written from


def build_source():
    src = ['#include "placard.asm"', '#include "placard_lib.asm"', '#include "placard_fsw.asm"', '',
           '#addr 0x0000', 'reset:', '    ld   main >> 8, y', '    jmp  main', '',
           '#addr 0x0100', 'main:', '    bra  main']
    for n, r in enumerate(ROUTINES):
        if n % 6 == 0:
            src.append('#addr 0x%04X' % (0x0200 + (n // 6) * 0x100))
        src += ['drv_%s:' % r, '    ld   [0x%02X], ac' % tf.ARG_AC]
        src += tf.call(r, n)
        src += ['    ld   ac, [0x%02X]' % tf.ARG_AC, 'halt_%s:' % r, '    bra  halt_%s' % r]
    return '\n'.join(src) + '\n'


class Rig(tf.Rig):
    def __init__(self, image):
        self.mem, self.syms, _ = ps.assemble(build_source(), HERE)
        self.port = iod.SharedPort()
        self.port.sd = iod.SdCard(image)
        self.cpu = ps.Cpu(self.mem, io=self.port)
        self.cpu.mem[self.syms['SP']] = 0xFF
        self.call('port_init')
        assert self.call('sd_init') == 0, 'sd_init'

    def put(self, data, at=SRC):
        for i, b in enumerate(data):
            self.cpu.mem[at + i] = b

    def save(self, name, data, at=SRC):
        self.put(data, at)
        n = len(data)
        return self.call('fs_save', **self.name(name), R4=at & 0xFF, R5=at >> 8,
                         R2=n & 0xFF, R3=n >> 8, max_steps=400_000_000)


class Card:
    """a card image on disk, checked with the PC's tools"""

    def __init__(self, image, part_at=0):
        self.dir = __import__('tempfile').mkdtemp()
        self.path = os.path.join(self.dir, 'card.img')
        self.image = image
        self.off = part_at * 512

    def write(self):
        open(self.path, 'wb').write(bytes(self.image[self.off:]))

    def fsck(self):
        self.write()
        r = subprocess.run(['fsck.fat', '-n', self.path], capture_output=True, text=True)
        out = r.stdout + r.stderr
        bad = [ln for ln in out.splitlines() if 'differs' in ln or 'rror' in ln or 'Wrong' in ln
               or 'Bad' in ln or 'orphan' in ln.lower() or 'Free cluster summary' in ln and 'wrong' in ln]
        return r.returncode, bad, out

    def read(self, name):
        self.write()
        r = subprocess.run(['mtype', '-i', self.path, '::' + name], capture_output=True)
        return r.stdout if r.returncode == 0 else None

    def names(self, folder=''):
        self.write()
        r = subprocess.run(['mdir', '-i', self.path, '-b', '::' + folder], capture_output=True, text=True)
        return sorted(ln.rstrip('/').split('/')[-1] for ln in r.stdout.split())

    def done(self):
        shutil.rmtree(self.dir)


def skip(f):
    def g():
        if not TOOLS:
            return 'skipped: needs dosfstools (mkfs.fat, fsck.fat) and mtools'
        return f()
    g.__name__ = f.__name__
    return g


def fsck_ok(card):
    code, bad, out = card.fsck()
    # fsck.fat -n returns 1 when it would change something: the FAT32 free
    # count (FSInfo) is left stale on purpose, which it reports as a
    # difference, so look at the complaints themselves
    real = [b for b in bad if 'free cluster' not in b.lower()]
    assert not real, 'fsck.fat: %s\n%s' % (real, out)


def first_free(image, part_at):
    """the first free cluster of a fresh image, from its FAT"""
    b = image[part_at * 512:part_at * 512 + 512]
    rs = int.from_bytes(b[14:16], 'little')
    fat = image[(part_at + rs) * 512:(part_at + rs) * 512 + 65536]
    fat32 = int.from_bytes(b[22:24], 'little') == 0
    n = 4 if fat32 else 2
    c = 2
    while int.from_bytes(fat[c * n:c * n + n], 'little'):
        c += 1
    return c, (128 if fat32 else 256)


def run_card(fat, mb, spc, part_at):
    def make(filler):
        im = tf.Image(fat, mb, spc, part_at)
        im.put('HELLO.TXT', b'Hello from the SD card!\n' * 4)
        im.put('OLD.BIN', tf.data(2000, 7))
        im.mkdir('GAMES')
        im.put('PONG.BIN', tf.data(1300, 5), 'GAMES')
        if filler:
            im.put('FILLER.BIN', bytes(filler))
        return im, im.card()
    # a filler so that the clusters the Placard takes later (after NEW.BIN
    # 6, TWO.DAT 2, the replaced OLD.BIN 1, SAVED.BIN 1-3) end 2 short of a
    # FAT sector boundary: SPAN.BIN then crosses it
    im, image = make(0)
    free, per = first_free(image, part_at)
    taken = 6 if spc == 1 else 2
    taken += 2 if spc == 1 else 1
    taken += 1
    taken += 3 if spc == 1 else 1
    im, image = make((per - 2 - taken - free) * spc * 512)
    free2, _ = first_free(image, part_at)
    assert free2 + taken == per - 2, (free, free2, taken, per)
    card = Card(image, part_at)
    rig = Rig(image)
    assert rig.call('fs_mount') == 0, 'fs_mount'
    notes = []

    # a new file of a few clusters, fs_save
    d1 = tf.data(3001, 11)
    a = rig.save('NEW.BIN', d1)
    assert a == 0, 'fs_save NEW.BIN: %d' % a
    notes.append('save 3001 bytes %d clocks' % rig.clocks)
    fsck_ok(card)
    assert card.read('NEW.BIN') == d1, 'NEW.BIN read back by mtype'
    # the Placard reads it back too
    a, _ = rig.load('NEW.BIN')
    assert a == 0 and rig.got(3001) == d1, 'fs_load NEW.BIN: %d' % a

    # create / write / close by hand: 2 sectors, size 700
    d2 = tf.data(700, 12)
    rig.put(d2 + bytes(1024 - 700))
    assert rig.call('fs_create', **rig.name('two.dat')) == 0, 'fs_create'
    assert rig.call('fs_write', R4=SRC & 0xFF, R5=SRC >> 8) == 0, 'fs_write 1'
    assert (rig.r(4) | rig.r(5) << 8) == SRC + 512, 'R5:R4 not advanced'
    assert rig.call('fs_write', R4=rig.r(4), R5=rig.r(5)) == 0, 'fs_write 2'
    assert rig.call('fs_close', R0=700 & 0xFF, R1=700 >> 8, R2=0, R3=0) == 0, 'fs_close'
    fsck_ok(card)
    assert card.read('TWO.DAT') == d2, 'TWO.DAT'
    assert rig.call('fs_write', R4=0, R5=SRC >> 8) == 12, 'write after close'
    assert rig.call('fs_close', R0=0, R1=0, R2=0, R3=0) == 12, 'close after close'

    # an empty file, and a file replaced by a shorter one (its old clusters freed)
    assert rig.call('fs_create', **rig.name('EMPTY.TXT')) == 0
    assert rig.call('fs_close', R0=0, R1=0, R2=0, R3=0) == 0
    d3 = tf.data(100, 13)
    assert rig.save('OLD.BIN', d3) == 0, 'replace OLD.BIN'
    fsck_ok(card)
    assert card.read('OLD.BIN') == d3, 'OLD.BIN replaced'
    assert card.read('EMPTY.TXT') == b'', 'EMPTY.TXT'

    # delete: a file, a missing file, a folder (refused)
    assert rig.call('fs_delete', **rig.name('HELLO.TXT')) == 0, 'fs_delete'
    assert rig.call('fs_delete', **rig.name('HELLO.TXT')) == 2, 'delete twice'
    assert rig.call('fs_delete', **rig.name('GAMES')) == 13, 'delete a folder'
    fsck_ok(card)
    names = card.names()
    assert 'HELLO.TXT' not in names and 'NEW.BIN' in names and 'GAMES' in names, names

    # in a folder: save, list, then a big file that spans FAT sectors
    assert rig.call('fs_open', **rig.name('GAMES')) == 0
    d4 = tf.data(1500, 14)
    assert rig.save('SAVED.BIN', d4) == 0, 'save in a folder'
    assert card.read('GAMES/SAVED.BIN') == d4, 'GAMES/SAVED.BIN'
    assert card.read('GAMES/PONG.BIN') == tf.data(1300, 5), 'PONG.BIN kept'
    assert rig.call('fs_root') == 0
    span = tf.data(5 * spc * 512 + 300, 15)   # 6 clusters, the FILLER puts
    assert rig.save('SPAN.BIN', span, at=0x5400) == 0, 'save SPAN.BIN'  # them across a FAT sector
    notes.append('6 clusters across a FAT sector %d clocks' % rig.clocks)
    fsck_ok(card)
    assert card.read('SPAN.BIN') == span, 'SPAN.BIN'
    a, _ = rig.load('SPAN.BIN', at=0x5400)
    assert a == 0 and bytes(rig.cpu.mem[0x5400:0x5400 + len(span)]) == span, 'fs_load SPAN.BIN'
    # and the files written before are still right
    assert card.read('NEW.BIN') == d1 and card.read('TWO.DAT') == d2
    card.done()
    return '; '.join(notes)


@skip
def test_fat16_no_partition():
    return run_card(16, 4, 1, 0)


@skip
def test_fat16_partition_4spc():
    return run_card(16, 20, 4, 63)


@skip
def test_fat32_partition():
    return run_card(32, 34, 1, 2048)


@skip
def test_full():
    """a tiny FAT16 volume runs out of clusters and out of root entries"""
    # a 5 MB card, 1 sector per cluster, filled by the PC's tools but for
    # 30 clusters
    im = tf.Image(16, 5, 1)
    image = im.card()
    b = image[:512]
    total = int.from_bytes(b[19:21], 'little') or int.from_bytes(b[32:36], 'little')
    rs, nf, fsz = int.from_bytes(b[14:16], 'little'), b[16], int.from_bytes(b[22:24], 'little')
    rootsecs = int.from_bytes(b[17:19], 'little') * 32 // 512
    clusters = total - rs - nf * fsz - rootsecs
    im2 = tf.Image(16, 5, 1)
    im2.put('FILL.BIN', bytes((clusters - 30) * 512))
    image = im2.card()
    card = Card(image)
    rig = Rig(image)
    assert rig.call('fs_mount') == 0
    a = rig.save('A.BIN', tf.data(20 * 512, 21), at=0x1000)
    assert a == 0, '20 clusters: %d' % a
    a = rig.save('B.BIN', tf.data(20 * 512, 22), at=0x1000)
    assert a == 14, 'card full: %d' % a
    fsck_ok(card)
    names = card.names()
    assert 'A.BIN' in names and 'B.BIN' in names, names
    assert card.read('A.BIN') == tf.data(20 * 512, 21)
    assert card.read('B.BIN') == b'', 'B.BIN left empty'
    card.done()
    # a root folder of 32 entries (the volume name takes one): 31 files
    path = os.path.join(__import__('tempfile').mkdtemp(), 'small.img')
    tf.sh('mkfs.fat', '-C', '-F', '16', '-s', '1', '-r', '32', '-n', 'PLACARD', path, '4200')
    image = bytearray(open(path, 'rb').read())
    card = Card(image)
    rig = Rig(image)
    assert rig.call('fs_mount') == 0
    code = 0
    for i in range(40):
        a = rig.call('fs_create', **rig.name('F%03d.X' % i))
        if a == 11:
            break
        assert a == 0, 'fs_create %d: %d' % (i, a)
        assert rig.call('fs_close', R0=0, R1=0, R2=0, R3=0) == 0
    assert i == 31, 'root folder full at %d' % i
    fsck_ok(card)
    assert len(card.names()) == 31
    card.done()
    return 'full card 14, full root folder 11'


@skip
def test_not_mounted():
    rig = Rig(bytearray(512 * 64))
    assert rig.call('fs_create', **rig.name('X.Y')) == 8
    assert rig.call('fs_delete', **rig.name('X.Y')) == 8
    assert rig.call('fs_write', R4=0, R5=0x70) == 12
    return 'not mounted 8, nothing open 12'


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
