#!/usr/bin/env python3
"""Write the bill of materials, docs/BOM.md and docs/BOM.csv, from the KiCad
sheets (main board kicad/*.kicad_sch, kicad/cartridge/, kicad/keyboard/).

Parts with the same part number share a line.  Parts with no part number
chosen yet share a line when their description and value match, with the
part number left blank.  The Manufacturer and MPN fields come from the
sheets (gen_kicad_schematic.py, its MPN table); the descriptions and the
parts that are not on the schematic (sockets, jumper shunts, keyboard
stabilizers, keycaps, LEDs and the keyboard cable) are added here.

    python3 src/scripts/gen_kicad_schematic.py    # after a part change
    python3 src/scripts/gen_bom.py

Date: 2026-10-22
"""
import csv
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kicad_sch_lib as K  # noqa: E402

DATE = "2026-10-22"
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
KDIR = os.path.join(ROOT, "kicad")

BOARDS = [
    ("Main board", sorted(glob.glob(os.path.join(KDIR, "*.kicad_sch")))),
    ("Cartridge", [os.path.join(KDIR, "cartridge", "cartridge.kicad_sch")]),
    ("Keyboard", [os.path.join(KDIR, "keyboard", "keyboard.kicad_sch")]),
]

# descriptions by value, then by symbol
DESC_VALUE = {
    "ATF22V10C-7PX": "PLD, 22V10, 7.5 ns, PDIP-24 0.3\" (programmed)",
    "ATF22V10C-10PU": "PLD, 22V10, 10 ns, PDIP-24 0.3\" (programmed)",
    "SN74F377AN": "Octal D flip-flop with enable, 74F, DIP-20",
    "SN74F541N": "Octal buffer, 3-state, 74F, DIP-20",
    "CD74ACT273E": "Octal D flip-flop with clear, 74ACT, DIP-20",
    "SN74HCT574N": "Octal D flip-flop, 3-state, 74HCT, DIP-20",
    "SN74HC574N": "Octal D flip-flop, 3-state, 74HC, DIP-20",
    "AS7C256C-15PCN": "SRAM, 32K x 8, 15 ns, PDIP-28 0.3\"",
    "AT28C256-15PU": "EEPROM, 32K x 8, 150 ns, PDIP-28 0.6\" (programmed)",
    "MCP1700-3302E/TO": "3.3 V LDO regulator, 250 mA, TO-92",
    "25.175 MHz": "Clock oscillator, 25.175 MHz, 5 V, full-size DIP-14 can",
    "USB4125-GF-A": "USB-C receptacle, power only (6 pin), top mount",
    "3 A hold": "Polyfuse, 3 A hold, radial",
    "Molex 87715-9106": "Cartridge slot: card edge, 64 contacts, 1.0 mm, keyed (PCIe x4 style), vertical TH",
    "VGA": "DE-15 high-density receptacle (VGA), with mounting holes",
    "3.5 mm": "3.5 mm stereo headphone jack",
    "SD (SPI)": "SD card socket",
    "PS/2 mouse": "Mini-DIN-6 receptacle (PS/2)",
    "SNES pad": "SNES controller socket, 7 pin",
}
DESC_LIB = {
    "placard_parts:Expansion_Slot": "Expansion slot: 2 x 20 card-edge socket, 0.1\", 1.6 mm card, TH",
    "placard_parts:Keyboard_Header": "Box header, 2 x 10, 2.54 mm, shrouded and keyed, vertical",
    "placard_std:Jumper_2_Open": "Pin header, 1 x 2, 2.54 mm (bring-up jumper)",
    "placard_std:SW_SPST": "Power on/off: SPDT on-on toggle, 5 A 28 V DC, right-angle PCB, 1/4-40 bushing",
    "placard_std:SW_Push_Open": "Reset: SPDT momentary pushbutton, NC contact used, 4 A 28 V DC, right-angle PCB",
    "Switch:SW_Push_LED": "Key switch, Cherry MX style, PCB mount (5 pin)",
    "placard_std:D_Schottky": "Schottky diode, DO-35",
    "placard_std:R_Network08_US": "Resistor network, 8 bussed, SIP-9",
}
# values that name the part, not a value worth its own column
NO_VALUE = {"Switch:SW_Push_LED", "placard_parts:Expansion_Slot", "placard_parts:Keyboard_Header",
            "placard_std:Jumper_2_Open"}

NOTES = {
    "MF-RG300": "Part number from the footprint (Fuse_Bourns_MF-RG300)",
    "BAT85": "Any BAT85 (Vishay, Nexperia, onsemi)",
    "Expansion slot": "Candidate: Sullins EBC20DCAN family, not stock-checked (EXPANSION.md)",
    "Key switch": "Switch type (color) not chosen; footprints have LED pads 3/4",
    "25.175 MHz": "Not chosen yet",
}

PLD_JOB = {"STATE": "State", "BRANCH": "Branch", "PC_COUNTER8": "PC", "ALU_SHR": "ALU", "QUAD_MUX": "Address mux",
           "MEM_CTRL": "Memory control", "IO_DECODE": "I/O decode", "HCOUNT": "H counter", "VCOUNT": "V counter",
           "SYNC": "Sync", "COLORDECODER": "Color decoder", "IR": "Instruction register", "AUDIO": "Audio slot",
           "PORT": "Shared port", "CART": "Cartridge loader"}

REF_ORDER = ["U", "X", "J", "SW", "F", "D", "R", "RN", "C", "JP"]


def ref_key(r):
    m = re.match(r"([A-Z]+)(\d+)", r)
    p, n = m.group(1), int(m.group(2))
    return (REF_ORDER.index(p) if p in REF_ORDER else 99, p, n)


def ranges(refs):
    """U18, U19, U20, U22 -> U18-U20, U22"""
    refs = sorted(refs, key=ref_key)
    out = []
    for r in refs:
        p, n = ref_key(r)[1], ref_key(r)[2]
        if out and out[-1][0] == p and out[-1][2] == n - 1:
            out[-1][2] = n
        else:
            out.append([p, n, n])
    return ", ".join(f"{p}{a}" if a == b else f"{p}{a}{'-' if b > a + 1 else ', '}{p}{b}" for p, a, b in out)


def symbols(path):
    tree = K.parse(open(path).read())
    for sym in K.find(tree, "symbol"):
        lib = K.find(sym, "lib_id")
        if not lib:
            continue
        lib_id = K.uq(lib[0][1])
        if lib_id.startswith("power:"):
            continue
        if K.find(sym, "in_bom")[0][1] != "yes":
            continue
        props = {K.uq(p[1]): K.uq(p[2]) for p in K.find(sym, "property")}
        if props["Reference"].startswith("#"):
            continue
        yield lib_id, props


def describe(lib_id, props):
    v = props["Value"]
    if v in DESC_VALUE:
        return DESC_VALUE[v]
    if lib_id in DESC_LIB:
        return DESC_LIB[lib_id]
    fp = props.get("Footprint", "")
    if lib_id.endswith(":R_US"):
        return "Resistor, metal film 1%, 1/4 W, axial"
    if lib_id.endswith(":C_Polarized"):
        m = re.search(r"D(\d+\.?\d*)mm_P(\d+\.?\d*)mm", fp)
        return f"Electrolytic capacitor, radial {m.group(1)} mm, {m.group(2)} mm pitch"
    if lib_id.endswith(":C"):
        return "Ceramic capacitor, 5 mm pitch"
    return lib_id.split(":")[1]


def board_bom(files):
    lines = {}
    sockets = {}
    shunts = []
    stabs = {}
    keys = []
    for f in files:
        for lib_id, p in symbols(f):
            ref = p["Reference"]
            mpn = p.get("MPN", "")
            desc = describe(lib_id, p)
            value = "" if lib_id in NO_VALUE or p["Value"] in (mpn, "Molex " + mpn) else p["Value"]
            key = ("mpn", mpn) if mpn else ("desc", desc, value)
            ln = lines.setdefault(key, dict(refs=[], mpn=mpn, mfr=p.get("Manufacturer", ""), desc=desc,
                                            value=value, fps=set(), jobs=[]))
            ln["refs"].append(ref)
            ln["fps"].add(p.get("Footprint", ""))
            if lib_id.startswith("placard:ATF22V10C_"):
                ln["jobs"].append((ref, PLD_JOB.get(lib_id.split("_", 1)[1], lib_id)))
            fp = p.get("Footprint", "")
            m = re.search(r"DIP-(\d+)_W(\d+\.\d+)mm", fp) or (re.search(r"Oscillator_DIP-(\d+)", fp))
            if m:
                pins = m.group(1)
                wide = m.lastindex > 1 and m.group(2) == "15.24"
                sockets.setdefault((int(pins), wide), []).append(ref)
            if "PinHeader_1x02" in fp and lib_id.endswith("Jumper_2_Open"):
                shunts.append(ref)
            m = re.search(r"SW_Cherry_MX_LED_(\d\.\d\d)u", fp)
            if m:
                keys.append(ref)
                if m.group(1) in ("2.00", "2.25", "6.25"):
                    stabs.setdefault(m.group(1), []).append(ref)
    out = []
    for ln in lines.values():
        note = NOTES.get(ln["mpn"]) or NOTES.get(ln["value"]) or next(
            (v for k, v in NOTES.items() if ln["desc"].startswith(k)), "")
        if ln["jobs"]:
            jobs = {}
            for ref, job in sorted(ln["jobs"], key=lambda t: ref_key(t[0])):
                jobs.setdefault(job, []).append(ref)
            note = "; ".join(f"{job} {ranges(r)}" for job, r in jobs.items())
        if ln["desc"].startswith("Key switch"):
            sizes = sorted({re.search(r"(\d\.\d\d)u", f).group(1) for f in ln["fps"]})
            note += "; sizes " + ", ".join(s.rstrip("0").rstrip(".") + " u" for s in sizes)
        fps = sorted(f for f in ln["fps"] if f)
        out.append(dict(refs=sorted(ln["refs"], key=ref_key), mpn=ln["mpn"], mfr=ln["mfr"], desc=ln["desc"],
                        value=ln["value"], footprint=fps[0] if len(fps) == 1 else "", notes=note, extra=False))
    out.sort(key=lambda d: ref_key(d["refs"][0]))
    # not on the schematic
    for (pins, wide), refs in sorted(sockets.items()):
        out.append(dict(refs=sorted(refs, key=ref_key), mpn="", mfr="",
                        desc=f"IC socket, DIP-{pins} {'0.6' if wide else '0.3'}\"", value="", footprint="",
                        notes="Or a 4-pin oscillator socket" if refs == ["X1"] else "",
                        extra=True))
    if shunts:
        out.append(dict(refs=shunts, mpn="", mfr="", desc="Jumper shunt, 2.54 mm", value="", footprint="",
                        notes="Bring-up jumpers", extra=True))
    if keys:
        out.append(dict(refs=sorted(keys, key=ref_key), mpn="", mfr="", desc="LED, 3 mm, through-hole", value="",
                        footprint="", notes="Optional, always on; one in each key switch (pads 3 K, 4 A)",
                        extra=True))
        out.append(dict(refs=sorted(keys, key=ref_key), mpn="", mfr="", desc="Keycap, Cherry MX stem", value="",
                        footprint="", notes="Sizes as the key switches", extra=True))
        for size, refs in sorted(stabs.items()):
            out.append(dict(refs=sorted(refs, key=ref_key), mpn="", mfr="",
                            desc=f"Stabilizer, Cherry MX PCB mount, {size.rstrip('0').rstrip('.')} u", value="",
                            footprint="", notes="", extra=True))
        out.append(dict(refs=[], qty=1, mpn="", mfr="", desc="Ribbon cable, 20 way, 1.27 mm pitch flat",
                        value="", footprint="", notes="Keyboard to main board J1; length to suit the case",
                        extra=True))
        out.append(dict(refs=[], qty=2, mpn="", mfr="",
                        desc="IDC socket, 2 x 10, 2.54 mm, polarized, with strain relief", value="", footprint="",
                        notes="Crimped on each end of the ribbon cable; mates with J1 on both boards", extra=True))
    for d in out:
        d.setdefault("qty", len(d["refs"]))
    return out


def md_cell(s):
    return s.replace("|", "\\|")


def main():
    boards = [(name, board_bom(files)) for name, files in BOARDS]
    md = [f"# Bill of materials\n\nDate: {DATE}\n",
          "Every part of the three boards, one line per part number: the main",
          "board, the ROM cartridge and the keyboard.  Parts with the same part",
          "number share a line; where no part number is chosen yet the column is",
          "blank and parts with the same description and value share the line.",
          "Lines marked \"not on the schematic\" are sockets, shunts, keyboard",
          "parts and the keyboard cable that KiCad's own BOM export leaves out.",
          "The net tie NT1, the cartridge's edge fingers (its J1) and its 32K/64K",
          "solder jumper JP1 are copper on the PCB, so they are not listed.",
          "",
          "Written by `src/scripts/gen_bom.py` from the KiCad sheets (the part",
          "numbers are the Manufacturer and MPN fields set by",
          "`gen_kicad_schematic.py`); the same list is in [BOM.csv](BOM.csv).",
          "Rerun both after a part change.  Stock moves, so recheck before",
          "ordering.",
          "",
          "The PLDs come in two speed grades, so they are two lines: each chip's",
          "grade follows its timing ([CHIPS.md](CHIPS.md#pld-speed-grades)).  The",
          "notes give each PLD's job; [KITTING.md](KITTING.md) lists the images.",
          ""]
    rows = []
    for name, bom in boards:
        parts = sum(d["qty"] for d in bom if not d["extra"])
        md.append(f"## {name}\n")
        md.append(f"{len(bom)} lines, {parts} parts on the schematic.\n")
        md.append("| Qty | References | Part number | Manufacturer | Description | Value | Notes |")
        md.append("|--:|---|---|---|---|---|---|")
        for d in bom:
            refs = ranges(d["refs"]) if d["refs"] else ""
            note = ("Not on the schematic.  " if d["extra"] else "") + d["notes"]
            md.append("| " + " | ".join(md_cell(c) for c in (str(d["qty"]), refs, d["mpn"], d["mfr"], d["desc"],
                                                              d["value"], note.strip())) + " |")
            rows.append([name, d["qty"], " ".join(d["refs"]), d["mfr"], d["mpn"], d["desc"], d["value"],
                         d["footprint"], "yes" if not d["extra"] else "no", d["notes"]])
        md.append("")
    with open(os.path.join(ROOT, "docs", "BOM.md"), "w") as f:
        f.write("\n".join(md))
    with open(os.path.join(ROOT, "docs", "BOM.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Board", "Qty", "References", "Manufacturer", "Part number", "Description", "Value",
                    "Footprint", "On schematic", "Notes"])
        w.writerows(rows)
    for name, bom in boards:
        print(f"{name}: {len(bom)} lines, {sum(d['qty'] for d in bom)} parts")


if __name__ == "__main__":
    main()
