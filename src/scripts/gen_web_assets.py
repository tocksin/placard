#!/usr/bin/env python3
"""
gen_web_assets.py - the built-in ROM and SD card of the web emulator

    python3 gen_web_assets.py

Writes web/default_rom.js (the 32K image, built from rom32.asm the way
gen_rom.tcl and test_dos.py build it) and web/default_sd.js (the files of
the sdcard/ folder).  They are plain scripts with the bytes in base64, so
web/index.html works when opened straight from the disk (a page opened
from a file may not fetch other files).  Run it again after a change to
the ROM sources or to sdcard/.

Date: 10/27/2026
"""

import base64
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps    # noqa: E402

REPO = os.path.join(HERE, '..', '..')
WEB = os.path.join(REPO, 'web')
SDCARD = os.path.join(REPO, 'sdcard')


def rom_32k():
    prog, _, _ = ps.assemble(open(os.path.join(HERE, 'rom32.asm')).read(), HERE)
    return ps.image_32k(ps.build_rom(prog, HERE))


def wrap(b64, width=100):
    return '\n'.join("    '%s' +" % b64[i:i + width] for i in range(0, len(b64), width)).rstrip(' +')


def main():
    rom = rom_32k()
    with open(os.path.join(WEB, 'default_rom.js'), 'w', newline='\n') as f:
        f.write('// the 32K ROM image (rom32.asm), made by src/scripts/gen_web_assets.py\n')
        f.write('var PLACARD_DEFAULT_ROM =\n%s;\n' % wrap(base64.b64encode(rom).decode()))
    files = sorted(n for n in os.listdir(SDCARD) if os.path.isfile(os.path.join(SDCARD, n)))
    with open(os.path.join(WEB, 'default_sd.js'), 'w', newline='\n') as f:
        f.write('// the files of the sdcard/ folder, made by src/scripts/gen_web_assets.py\n')
        f.write('var PLACARD_DEFAULT_SD = {\n')
        for n in files:
            data = open(os.path.join(SDCARD, n), 'rb').read()
            f.write("  '%s':\n%s,\n" % (n, wrap(base64.b64encode(data).decode())))
        f.write('};\n')
    print('wrote web/default_rom.js (%d bytes of ROM) and web/default_sd.js (%d files)'
          % (len(rom), len(files)))


if __name__ == '__main__':
    main()
