#!/usr/bin/env python3
"""
gen_kicad_parts.py - make kicad/lib/placard_parts.kicad_sym, the project's
symbols for the parts KiCad's own libraries do not have: the AS7C256C SRAM,
the expansion slot, the ROM cartridge slot, the SNES pad socket, the
stacked dual PS/2 socket and the USB-C power input.  They are drawn like the PLD
symbols (gen_kicad_symbols.py): pins grouped by bus and function, not by
number.

    python3 gen_kicad_parts.py               writes kicad/lib/placard_parts.kicad_sym
    python3 gen_kicad_parts.py out.kicad_sym

The other parts come from KiCad's libraries (kicad/README.md lists which).
Rerunning this overwrites the library, so make changes here, not in KiCad's
symbol editor.  The pinouts are from CHIPS.md, EXPANSION.md and IO.md.

Date: 2026-10-25
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
                  footprint="placard:DIP-28_W7.62mm_Socket_Puller",
                  datasheet="~",
                  vcc=(28, "VCC"), gnd=(14, "GND"))


def edge(side, nums):
    return ["%s%d" % (side, n) for n in nums]


def expansion_slot():
    # 2 x 20 card edge, contacts A1-A20 (component side) and B1-B20 (EXPANSION.md)
    p = "passive"
    d = [("A3", "D0"), ("B3", "D1"), ("A4", "D2"), ("B4", "D3"),
         ("A5", "D4"), ("B5", "D5"), ("A6", "D6"), ("B6", "D7")]
    sd = [("A8", "BT1"), ("B8", "BT2"), ("A9", "BT3"), ("B9", "BT4"),
          ("A10", "BT5"), ("B10", "BT6"), ("A11", "BT7"), ("B11", "BT8")]   # boot contacts (slot 1)
    a = [("A13", "A0"), ("B13", "A1"), ("A14", "A2"), ("B14", "A3"),
         ("A15", "A4"), ("B15", "A5"), ("A16", "A6"), ("B16", "A7")]
    sel = [("A17", "/EXP")]
    ctl = [("A18", "RW"), ("B18", "LOAD_IMM"), ("A19", "/WE"), ("B12", "CLK"), ("B19", "/RESET")]
    e = lambda l: [(n, s, p) for n, s in l]
    gnd = [(n, "GND") for n in ["A1", "B1", "A7", "B7", "A12", "A20", "B20"]]
    return symbol("Expansion_Slot", [(e(d) + [None] + e(sd), e(a) + [None] + e(sel) + [None] + e(ctl) + [None, None] + e([("B17", "SEL")]))],
                  "EBC20DCAN", "Expansion slot: 2 x 20 contact, 0.1 inch card-edge socket (EXPANSION.md)",
                  "card edge slot expansion Placard", footprint="", datasheet="~",
                  vcc=[("A2", "+5V"), ("B2", "+5V")], gnd=gnd, ref="J", pin_len=2 * 2.54)


def cartridge_slot():
    # Molex 87715-9106, 2 x 32 keyed card edge, the ROM cartridge pinout (EXPANSION.md)
    p = "passive"
    # contacts follow the chip pins on the cartridge (2026-10-26: the cartridge boards are autorouted
    # with this order; each side's signals leave the fingers in the order of the pins they go to)
    a = [("A22", "A0"), ("A19", "A1"), ("A17", "A2"), ("A15", "A3"), ("A14", "A4"),
         ("B9", "A5"), ("B7", "A6"), ("A4", "A7"), ("A8", "A8"), ("A9", "A9"),
         ("A18", "A10"), ("A13", "A11"), ("B3", "A12"), ("A6", "A13"), ("A3", "A14")]
    ce = [("A5", "/CE_LO"), ("B16", "/CE_HI"), ("A16", "/ROM_OE"), None, ("B10", "/CART")]
    d = [("A24", "D0"), ("A27", "D1"), ("A29", "D2"), ("A32", "D3"),
         ("A30", "D4"), ("B27", "D5"), ("A25", "D6"), ("B22", "D7")]
    ld = [("B4", "CLK"), None, ("A7", "PIXEL_ENABLE"), None, ("B8", "PC_ENABLE"), None, ("B12", "STALL_IN"),
          None, ("B5", "STALL_OUT"), None, ("B6", "RUN")]     # a row apart, so their labels line up
    used = {x[0] for x in a + d + ld + ce if x}
    spare = [(s + str(n), "spare") for n in range(3, 33) for s in "AB"
             if s + str(n) not in used and n not in (11, 21, 31)]
    e = lambda l: [(x[0], x[1], p) if x else None for x in l]
    gnd = [(n, "GND") for n in ["A1", "B1", "A11", "B11", "A21", "B21", "A31", "B31"]]
    return symbol("Cartridge_Slot", [(e(a) + [None] + e(ce), e(d) + [None] + e(ld)), (e(spare[:11]), e(spare[11:]))],
                  "87715-9106", "ROM cartridge slot: Molex 87715-9106, 2 x 32 contact, 1.0 mm keyed card-edge socket (EXPANSION.md)",
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


def ps2_dual():
    # Kycon KMDGX-6S/6S-S4N: two mini-DIN 6 sockets stacked, PS/2 mouse on top (A),
    # PS/2 keyboard below (B), as on a PC (IO.md, J5).  Each socket: 1 DATA,
    # 2 nc, 3 GND, 4 +5 V, 5 CLK, 6 nc.  The two DATA lines are joined on the board.
    p = "passive"
    nc = lambda n: (n, "nc", "no_connect")
    # keyboard pins above the mouse pins, so the wires from the board reach them without crossing
    left = [("B5", "KCLK", p), ("B1", "KDATA", p), None, ("A1", "MDATA", p), ("A5", "MCLK", p)]
    right = [nc("B6"), nc("B2"), None, nc("A2"), nc("A6")]
    return symbol("PS2_Dual_Stacked", [(left, right)], "KMDGX-6S/6S-S4N",
                  "Stacked dual mini-DIN 6 (PS/2), right angle, shielded: top A = mouse, bottom B = keyboard; "
                  "each 1 DATA, 3 GND, 4 +5 V, 5 CLK",
                  "PS/2 mini-DIN stacked dual keyboard mouse Placard", footprint="", datasheet="~",
                  vcc=[("A4", "+5V"), ("B4", "+5V")], gnd=[("A3", "GND"), ("B3", "GND"), ("SH", "SHIELD")],
                  ref="J", min_w=4 * 2.54)


def usb_c_power():
    # USB-C receptacle, power only (6 contacts), the board's 5 V input.  A 5.1k
    # resistor from each CC pin to GND asks the charger for 5 V.
    p = "passive"
    right = [[("A9", "VBUS", p), ("B9", "VBUS", p)], None,
             ("A5", "CC1", p), ("B5", "CC2", p), None,
             [("A12", "GND", p), ("B12", "GND", p)], ("S1", "SHIELD", p)]
    return symbol("USB_C_Power", [([], right)], "USB4125-GF-A",
                  "USB-C receptacle, power only (6P): VBUS, CC1, CC2, GND, shield; 5.1k from CC1 and CC2 to GND for 5 V",
                  "USB C type-C power receptacle Placard",
                  footprint="placard:USB_C_Receptacle_GCT_USB4125_6P_HandSolder",
                  datasheet="~", vcc=None, gnd=None, ref="J", min_w=4 * 2.54, pin_len=2 * 2.54)


def mcp1700():
    # MCP1700-3302E/TO, 3.3 V LDO, TO-92: drawn with the input on the left, the
    # output on the right and GND at the bottom, so the power flows left to right
    return symbol("MCP1700_TO92", [([None, (2, "VI", "power_in"), None], [None, (3, "VO", "power_out"), None])], "MCP1700-3302E/TO",
                  "3.3 V 250 mA low-quiescent LDO regulator, TO-92 (pin 1 GND, 2 VI, 3 VO)",
                  "LDO regulator 3.3V MCP1700 Placard",
                  footprint="Package_TO_SOT_THT:TO-92_Inline", datasheet="~",
                  vcc=None, gnd=(1, "GND"), min_w=8 * 2.54)


def oscillator():
    # 25.175 MHz full-can oscillator, DIP-14 footprint (pin 1 NC, 7 GND, 8 OUT, 14 VCC),
    # drawn large enough for its pin names
    return symbol("Oscillator_DIP14", [([None] * 5, [None, None, (8, "OUT", "output"), None, None])], "25.175 MHz",
                  "Crystal oscillator, full can, DIP-14 footprint: 1 NC, 7 GND, 8 OUT, 14 VCC",
                  "oscillator clock DIP-14 Placard",
                  footprint="Oscillator:Oscillator_DIP-14", datasheet="~",
                  vcc=(14, "VCC"), gnd=(7, "GND"), ref="X", min_w=8 * 2.54)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    write_lib(out, [sram(), expansion_slot(), cartridge_slot(), snes_socket(), ps2_dual(), mcp1700(),
                    oscillator(), usb_c_power()])


if __name__ == "__main__":
    main()
