#!/usr/bin/env python3
"""
gen_kicad_std.py - make kicad/lib/placard_std.kicad_sym: copies of the KiCad
library symbols the schematic uses (74xx chips, R, C, connectors), with
larger pin names and numbers so the sheets read like the hand-drawn PNGs.

    python3 gen_kicad_std.py                 writes kicad/lib/placard_std.kicad_sym

The source is KiCad's own symbol library (/usr/share/kicad/symbols, KiCad 7;
apt-get install kicad-symbols).  Each symbol is flattened (no "extends"),
renamed to its plain name, and its pin text set to PIN_NAME / PIN_NUMBER mm.
Because the schematic uses these copies, KiCad's ERC does not report the
symbols as different from their library.

Date: 2026-10-21
"""

import os
import sys

import kicad_sch_lib as K

OUT = os.path.join(K.PROJ_LIB, "placard_std.kicad_sym")
PIN_NAME = 1.8
PIN_NUMBER = 1.5

# (library, symbol) for every stock part the schematic places
USED = [("74xx", "74LS273"), ("74xx", "74LS32"), ("74xx", "74LS377"), ("74xx", "74LS541"),
        ("74xx", "74LS574"),
        ("Connector", "DE15_Receptacle_HighDensity_MountingHoles"), ("Connector", "Mini-DIN-6"),
        ("Connector", "SD_Card"), ("Connector_Audio", "AudioJack3"),
        ("Device", "C"), ("Device", "C_Polarized"), ("Device", "D_Schottky"), ("Device", "NetTie_2"),
        ("Device", "Polyfuse"), ("Device", "R"), ("Device", "R_Network08"),
        ("Jumper", "Jumper_2_Open"), ("Regulator_Linear", "MCP1700x-330xxTO"),
        ("Oscillator", "ACO-xxxMHz")]


def _font(e, size):
    """Set every (font (size w h)) inside e to size."""
    if not isinstance(e, list):
        return e
    if e and e[0] == "size" and len(e) == 3:
        return ["size", K.R(size), K.R(size)]
    return [_font(x, size) for x in e]


def _bigger(e):
    if not isinstance(e, list) or not e:
        return e
    if e[0] == "pin":
        out = []
        for x in e:
            if isinstance(x, list) and x and x[0] == "name":
                x = _font(x, PIN_NAME)
            elif isinstance(x, list) and x and x[0] == "number":
                x = _font(x, PIN_NUMBER)
            out.append(x)
        return out
    return [_bigger(x) for x in e]


def std_symbol(nick, name):
    sym = K.lib_symbol(nick + ":" + name)
    sym = list(sym)
    sym[1] = K.q(name)
    out = []
    for e in sym:
        if isinstance(e, list) and e and e[0] == "symbol":
            if not K.uq(e[1]).startswith(name + "_"):
                raise SystemExit(f"{name}: unexpected unit name {e[1]}")
        out.append(_bigger(e))
    return "  " + K.dump(out, 1) + "\n"


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    with open(out, "w", newline="\n") as fh:
        fh.write("(kicad_symbol_lib (version 20220914) (generator gen_kicad_std)\n")
        for nick, name in USED:
            fh.write(std_symbol(nick, name))
        fh.write(")\n")
    print("wrote", os.path.normpath(out))


if __name__ == "__main__":
    main()
