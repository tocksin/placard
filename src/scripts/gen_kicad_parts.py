#!/usr/bin/env python3
"""
gen_kicad_parts.py - make kicad/lib/placard_parts.kicad_sym, the project's
symbols for the parts KiCad's own libraries do not have: the AS7C256C SRAM,
the expansion slot, the ROM cartridge slot, the SNES pad socket and the
keyboard header.  They are drawn like the PLD symbols (gen_kicad_symbols.py):
pins grouped by bus and function, not by number.

    python3 gen_kicad_parts.py               writes kicad/lib/placard_parts.kicad_sym
    python3 gen_kicad_parts.py out.kicad_sym

The other parts come from KiCad's libraries (kicad/README.md lists which).
Rerunning this overwrites the library, so make changes here, not in KiCad's
symbol editor.  The pinouts are from CHIPS.md, EXPANSION.md and IO.md.

Date: 2026-10-20
"""

import os
import sys

from gen_kicad_symbols import ROOT, SEP, symbol, write_lib

OUT = os.path.join(ROOT, "kicad", "lib", "placard_parts.kicad_sym")


def bus(prefix, nums, kind, start=0):
    """[(pin, prefix0, kind), (pin, prefix1, kind), ...]"""
    return [(n, "%s%d" % (prefix, i + start), kind) for i, n in enumerate(nums)]


def sram():
    # AS7C256C, 32K x 8, 300 mil DIP-28 (the JEDEC 62256 pinout)
    a = bus("A", [10, 9, 8, 7, 6, 5, 4, 3, 25, 24, 21, 23, 2, 26, 1], "input")
    dq = bus("DQ", [11, 12, 13, 15, 16, 17, 18, 19], "tri_state")
    ctl = [(20, "/CE", "input"), (22, "/OE", "input"), (27, "/WE", "input")]
    return symbol("AS7C256C", [(a + [None] + ctl, dq)], "AS7C256C-15PCN",
                  "32K x 8 SRAM, 15 ns, 5 V, 300 mil DIP-28 (62256 pinout)",
                  "SRAM RAM 32K 62256 Placard",
                  footprint="Package_DIP:DIP-28_W7.62mm",
                  datasheet="~",
                  vcc=(28, "VCC"), gnd=(14, "GND"))


def edge(side, nums):
    return ["%s%d" % (side, n) for n in nums]


def expansion_slot():
    # 2 x 20 card edge, contacts A1-A20 (component side) and B1-B20 (EXPANSION.md)
    p = "passive"
    d = [("A3", "D0"), ("B3", "D1"), ("A4", "D2"), ("B4", "D3"),
         ("A5", "D4"), ("B5", "D5"), ("A6", "D6"), ("B6", "D7")]
    sd = [("A8", "SD0"), ("B8", "SD1"), ("A9", "SD2"), ("B9", "SD3"),
          ("A10", "SD4"), ("B10", "SD5"), ("A11", "SD6"), ("B11", "SD7")]
    a = [("A13", "A0"), ("B13", "A1"), ("A14", "A2"), ("B14", "A3"),
         ("A15", "A4"), ("B15", "A5"), ("A16", "A6"), ("B16", "A7")]
    sel = [("A17", "/EXP"), ("B17", "SEL")]
    ctl = [("A18", "RW"), ("B18", "LOAD_IMM"), ("A19", "/WE"), ("B12", "CLK"), ("B19", "/RESET")]
    e = lambda l: [(n, s, p) for n, s in l]
    gnd = [(n, "GND") for n in ["A1", "B1", "A7", "B7", "A12", "A20", "B20"]]
    return symbol("Expansion_Slot", [(e(d) + [None] + e(sd), e(a) + [None] + e(sel) + [None] + e(ctl))],
                  "EBC20DCAN", "Expansion slot: 2 x 20 contact, 0.1 inch card-edge socket (EXPANSION.md)",
                  "card edge slot expansion Placard", footprint="", datasheet="~",
                  vcc=[("A2", "+5V"), ("B2", "+5V")], gnd=gnd, ref="J", pin_len=2 * 2.54)


def cartridge_slot():
    # 2 x 20 card edge, the ROM cartridge pinout (EXPANSION.md)
    p = "passive"
    a = [("A3", "A0"), ("B3", "A1"), ("A4", "A2"), ("B4", "A3"), ("A5", "A4"),
         ("B5", "A5"), ("A6", "A6"), ("B6", "A7"), ("A8", "A8"), ("B8", "A9"),
         ("A9", "A10"), ("B9", "A11"), ("A10", "A12"), ("B10", "A13"), ("A11", "A14")]
    ce = [("B11", "/CE_LO"), ("B12", "/CE_HI"), ("B17", "/ROM_OE"), ("A18", "/ROM_WE")]
    d = [("A13", "D0"), ("B13", "D1"), ("A14", "D2"), ("B14", "D3"),
         ("A15", "D4"), ("B15", "D5"), ("A16", "D6"), ("B16", "D7")]
    other = [("B18", "/CART"), None, ("A19", "spare"), ("B19", "spare")]
    e = lambda l: [(x[0], x[1], p) if x else None for x in l]
    gnd = [(n, "GND") for n in ["A1", "B1", "A7", "B7", "A12", "A17", "A20", "B20"]]
    return symbol("Cartridge_Slot", [(e(a) + [None] + e(ce), e(d) + [None] + e(other))],
                  "EBC20DCAN", "ROM cartridge slot: 2 x 20 contact, 0.1 inch card-edge socket (EXPANSION.md)",
                  "card edge slot cartridge ROM Placard", footprint="", datasheet="~",
                  vcc=[("A2", "+5V"), ("B2", "+5V")], gnd=gnd, ref="J", pin_len=2 * 2.54)


def snes_socket():
    # SNES controller socket, 7 pins (IO.md, J2 and J3)
    p = "passive"
    sig = [(2, "CLOCK", p), (3, "LATCH", p), (4, "DATA", p), None,
           (5, "nc", "no_connect"), (6, "nc", "no_connect")]
    return symbol("SNES_Pad_Socket", [(sig, [])], "SNES pad socket",
                  "SNES controller socket, 7 pins: 1 +5 V, 2 CLOCK, 3 LATCH, 4 DATA, 5-6 not used, 7 GND",
                  "SNES pad controller socket Placard", footprint="", datasheet="~",
                  vcc=(1, "+5V"), gnd=(7, "GND"), ref="J", min_w=4 * 2.54)


def keyboard_header():
    # 1 x 16 header to the keyboard board (IO.md, J1)
    p = "passive"
    col = bus("/COL", range(1, 9), p)
    row = bus("ROW", range(9, 17), p)
    return symbol("Keyboard_Header", [(col + [None] + row, [])], "Keyboard header",
                  "Keyboard matrix connector, 1 x 16, 2.54 mm: 1-8 /COL0-/COL7, 9-16 ROW0-ROW7",
                  "keyboard matrix header Placard",
                  footprint="Connector_PinHeader_2.54mm:PinHeader_1x16_P2.54mm_Vertical",
                  datasheet="~", vcc=None, gnd=None, ref="J", min_w=4 * 2.54)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    write_lib(out, [sram(), expansion_slot(), cartridge_slot(), snes_socket(), keyboard_header()])


if __name__ == "__main__":
    main()
