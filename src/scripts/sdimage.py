#!/usr/bin/env python3
"""
sdimage.py - make and read FAT16 SD card images in plain Python

    python3 sdimage.py card.img ../../sdcard        a card image from a folder
    python3 sdimage.py card.img --list              list it

    import sdimage
    img = sdimage.make({'MENU.PLC': data, 'GAMES/PONG.PLC': data2})
    sdimage.read(img, 'GAMES/PONG.PLC')             the file's bytes
    sdimage.listdir(img, 'GAMES')                   [(name, attr, size), ...]

The simulator tests (test_dos.py, run_dos.py) need a card with the DOS's
files on it without depending on mkfs.fat and mtools; test_fs.py and
test_fsw.py still use those, so the drivers are checked against file
systems made by other tools too.  The image has no partition table, one
reserved sector, two FATs, a 512-entry root folder and one sector per
cluster.  Names are short (8.3) names, upper case; folders are made as
needed from the path.

Date: 10/26/2026
"""

import os
import struct
import sys

SECTOR = 512


def short_name(name):
    """'menu.plc' -> b'MENU    PLC'"""
    base, _, ext = name.upper().partition('.')
    if len(base) > 8 or len(ext) > 3 or not base:
        raise ValueError('not a short name: %s' % name)
    return base.ljust(8).encode() + ext.ljust(3).encode()


def entry(name11, attr, cluster, size, date=(2026, 10, 26)):
    d = ((date[0] - 1980) << 9) | (date[1] << 5) | date[2]
    return name11 + struct.pack('<BBBHHHHHHHI', attr, 0, 0, 0, d, d, cluster >> 16,
                                0, d, cluster & 0xFFFF, size)


def make(files, size_kb=4096, spc=1, label='PLACARD'):
    """a FAT16 image: files = {'NAME.EXT' or 'DIR/NAME.EXT': bytes}"""
    total = size_kb * 1024 // SECTOR
    reserved, nfats, root_entries = 1, 2, 512
    root_secs = root_entries * 32 // SECTOR
    # FAT size: enough entries for every cluster (a slight over-estimate)
    clusters = (total - reserved - root_secs) // spc
    fat_secs = (clusters + 2) * 2 // SECTOR + 1
    data_start = reserved + nfats * fat_secs + root_secs
    clusters = (total - data_start) // spc
    if not 4085 <= clusters < 65525:
        raise ValueError('%d clusters is not a FAT16 count (try another size)' % clusters)
    img = bytearray(total * SECTOR)
    bs = bytearray(SECTOR)
    bs[0:3] = b'\xEB\x3C\x90'
    bs[3:11] = b'PLACARD '
    struct.pack_into('<HBHBHHBHHHII', bs, 11, SECTOR, spc, reserved, nfats, root_entries,
                     total if total < 65536 else 0, 0xF8, fat_secs, 32, 2, 0,
                     total if total >= 65536 else 0)
    struct.pack_into('<BBBI', bs, 36, 0x80, 0, 0x29, 0x20261026)
    bs[43:54] = label.ljust(11).encode()
    bs[54:62] = b'FAT16   '
    bs[510:512] = b'\x55\xAA'
    img[0:SECTOR] = bs
    fat = [0] * (fat_secs * SECTOR // 2)
    fat[0], fat[1] = 0xFFF8, 0xFFFF
    next_free = [2]

    def alloc(nbytes):
        n = max(1, (nbytes + spc * SECTOR - 1) // (spc * SECTOR))
        first = next_free[0]
        if first + n > clusters + 2:
            raise ValueError('image full')
        for c in range(first, first + n):
            fat[c] = c + 1 if c < first + n - 1 else 0xFFFF
        next_free[0] = first + n
        return first, n

    def put(data, first):
        off = (data_start + (first - 2) * spc) * SECTOR
        img[off:off + len(data)] = data

    root = bytearray(root_secs * SECTOR)
    root[0:32] = entry(label.ljust(11).encode(), 0x08, 0, 0)
    folders = {'': [root, 32, 0]}     # path -> [bytes, next offset, cluster]

    def folder(path):
        if path in folders:
            return folders[path]
        parent_path = path.rpartition('/')[0]
        parent = folder(parent_path)
        first, _ = alloc(spc * SECTOR)
        d = bytearray(spc * SECTOR)
        d[0:32] = entry(b'.          ', 0x10, first, 0)
        d[32:64] = entry(b'..         ', 0x10, parent[2], 0)
        folders[path] = [d, 64, first]
        add(parent, entry(short_name(path.rpartition('/')[2]), 0x10, first, 0))
        return folders[path]

    def add(f, e):
        if f[1] + 32 > len(f[0]):
            raise ValueError('folder full')
        f[0][f[1]:f[1] + 32] = e
        f[1] += 32

    for path, data in sorted(files.items()):
        path = path.replace('\\', '/').strip('/')
        folder_path, _, name = path.rpartition('/')
        f = folder(folder_path)
        if data:
            first, _ = alloc(len(data))
            put(data, first)
        else:
            first = 0
        add(f, entry(short_name(name), 0x20, first, len(data)))
    for path, (d, _, first) in folders.items():
        if path:
            put(d, first)
    img[reserved * SECTOR:(reserved + root_secs * 0) * SECTOR] = b''
    fat_bytes = struct.pack('<%dH' % len(fat), *fat)
    for k in range(nfats):
        img[(reserved + k * fat_secs) * SECTOR:(reserved + (k + 1) * fat_secs) * SECTOR] = fat_bytes
    img[(reserved + nfats * fat_secs) * SECTOR:data_start * SECTOR] = root
    return img


# ---------------------------------------------------------------------------
# reading (FAT16, no partition table: what make() writes, and what the
# Placard writes to such a card)
# ---------------------------------------------------------------------------
class Volume:
    def __init__(self, img):
        self.img = img
        self.spc = img[13]
        reserved = struct.unpack_from('<H', img, 14)[0]
        nfats = img[16]
        root_entries = struct.unpack_from('<H', img, 17)[0]
        fat_secs = struct.unpack_from('<H', img, 22)[0]
        self.fat = reserved * SECTOR
        self.root = (reserved + nfats * fat_secs) * SECTOR
        self.root_size = root_entries * 32
        self.data = self.root + self.root_size

    def next_cluster(self, c):
        return struct.unpack_from('<H', self.img, self.fat + c * 2)[0]

    def chain(self, first):
        out = b''
        c = first
        while 2 <= c < 0xFFF8:
            off = self.data + (c - 2) * self.spc * SECTOR
            out += bytes(self.img[off:off + self.spc * SECTOR])
            c = self.next_cluster(c)
        return out

    def entries(self, folder_bytes):
        out = []
        for i in range(0, len(folder_bytes), 32):
            e = folder_bytes[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] & 0x08 or e[11] & 0x0F == 0x0F:
                continue
            base, ext = e[0:8].decode('latin-1').rstrip(), e[8:11].decode('latin-1').rstrip()
            name = base + ('.' + ext if ext else '')
            cluster = struct.unpack_from('<H', e, 26)[0]
            size = struct.unpack_from('<I', e, 28)[0]
            out.append((name, e[11], size, cluster))
        return out

    def folder(self, path):
        d = bytes(self.img[self.root:self.root + self.root_size])
        for part in [p for p in path.replace('\\', '/').split('/') if p]:
            for name, attr, size, cluster in self.entries(d):
                if name.upper() == part.upper() and attr & 0x10:
                    d = self.chain(cluster)
                    break
            else:
                raise FileNotFoundError(path)
        return d

    def find(self, path):
        folder_path, _, name = path.replace('\\', '/').strip('/').rpartition('/')
        for e in self.entries(self.folder(folder_path)):
            if e[0].upper() == name.upper():
                return e
        raise FileNotFoundError(path)


def read(img, path):
    v = Volume(img)
    name, attr, size, cluster = v.find(path)
    return v.chain(cluster)[:size]


def listdir(img, path=''):
    v = Volume(img)
    return [(n, a, s) for n, a, s, c in v.entries(v.folder(path))]


def from_folder(folder):
    """{relative path: bytes} for every file under a folder"""
    files = {}
    for root, dirs, names in os.walk(folder):
        for n in names:
            p = os.path.join(root, n)
            files[os.path.relpath(p, folder).replace(os.sep, '/')] = open(p, 'rb').read()
    return files


def main(argv):
    if len(argv) == 2 and argv[1] == '--list':
        img = bytearray(open(argv[0], 'rb').read())
        for name, attr, size in listdir(img):
            print('%-12s %s %d' % (name, '<DIR>' if attr & 0x10 else '     ', size))
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 1
    img = make(from_folder(argv[1]))
    open(argv[0], 'wb').write(img)
    print('wrote %s, %d KB' % (argv[0], len(img) // 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
