#!/usr/bin/env python3
"""Write the bills of materials from the KiCad sheets (main board
kicad/*.kicad_sch, kicad/cartridge_64k/, kicad/cartridge_32k/) and the
case parts list (CASE.md), one BOM per assembly (Justin, 2026-10-25):

    docs/BOM_MAIN_PCB.md/.csv   main board assembly: bare PCB + components
    docs/BOM_CART_64K.md/.csv   64K cartridge assembly: PCB, components, shell, screw
    docs/BOM_CART_32K.md/.csv   32K cartridge assembly: the same for the 32K board
    docs/BOM_CASE.md/.csv       case assembly: the main board assembly as one line,
                                case parts, standoffs, screws and feet
    docs/BOM.md                 the index: what each BOM covers and their costs

Accessories sold with a kit (USB-C power supply, SD card, programmer, ...)
are in no BOM; KITTING.md and KIT_PRICING.md list them.

Parts with the same part number share a line.  Parts with no part number
chosen yet share a line when their description and value match, with the
part number left blank.  The Manufacturer and MPN fields come from the
sheets (gen_kicad_schematic.py, its MPN table); the descriptions and the
parts that are not on the schematic (bare PCBs, sockets, jumper shunts,
shells, screws) are added here.

    python3 src/scripts/gen_kicad_schematic.py    # after a part change
    python3 src/scripts/gen_bom.py

Date: 2026-10-28
"""
import csv
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kicad_sch_lib as K  # noqa: E402

DATE = "2026-10-27"
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
KDIR = os.path.join(ROOT, "kicad")

BOARDS = [
    ("Main board", sorted(glob.glob(os.path.join(KDIR, "*.kicad_sch")))),
    ("Cartridge, 64K", [os.path.join(KDIR, "cartridge_64k", "cartridge_64k.kicad_sch")]),
    ("Cartridge, 32K", [os.path.join(KDIR, "cartridge_32k", "cartridge_32k.kicad_sch")]),
]

# descriptions by value, then by symbol
DESC_VALUE = {
    "ATF22V10C-7PX": "PLD, 22V10, 7.5 ns, PDIP-24 0.3\" (programmed)",
    "ATF22V10C-10PU": "PLD, 22V10, 10 ns, PDIP-24 0.3\" (programmed)",
    "SN74F377AN": "Octal D flip-flop with enable, 74F, DIP-20",
    "CD74HCT377E": "Octal D flip-flop with enable, 74HCT, DIP-20 (line code: drives the row tint)",
    "SN74F541N": "Octal buffer, 3-state, 74F, DIP-20",
    "CD74ACT273E": "Octal D flip-flop with clear, 74ACT, DIP-20",
    "SN74HCT574N": "Octal D flip-flop, 3-state, 74HCT, DIP-20",
    "AS7C256C-15PCN": "SRAM, 32K x 8, 15 ns, PDIP-28 0.3\"",
    "AT28C256-15PU": "EEPROM, 32K x 8, 150 ns, PDIP-28 0.6\" (programmed)",
    "MCP1700-3302E/TO": "3.3 V LDO regulator, 250 mA, TO-92",
    "SA5.0A": "TVS diode, 5 V stand-off, 500 W, DO-15 axial (across the fused USB 5 V)",
    "25.175 MHz": "Clock oscillator, 25.175 MHz, 5 V, full-size DIP-14 can",
    "USB4125-GF-A": "USB-C receptacle, power only (6 pin), top mount",
    "3 A hold": "Polyfuse, 3 A hold, radial",
    "Molex 87715-9106": "Cartridge slot: card edge, 64 contacts, 1.0 mm, keyed (PCIe x4 style), vertical TH",
    "VGA": "DE-15 high-density receptacle (VGA), with mounting holes",
    "3.5 mm": "3.5 mm audio line out jack, 4 pole (TRRS), right angle, TH (a TRS plug's sleeve spans R2 and S)",
    "SD (SPI)": "SD card socket",
    "PS/2 kbd + mouse": "Stacked dual mini-DIN-6 receptacle (PS/2), right angle, shielded: mouse top, keyboard bottom",
    "SNES pad": "SNES controller socket, 7 pin",
}
DESC_LIB = {
    "placard_parts:Expansion_Slot": "Expansion slot: 2 x 20 card-edge socket, 0.1\", 1.6 mm card, TH",
    "placard_std:Jumper_2_Open": "Pin header, 1 x 2, 2.54 mm (bring-up jumper)",
    "placard_std:SW_SPST": "Power on/off: SPDT on-on toggle, 5 A 28 V DC, right-angle PCB, 1/4-40 bushing",
    "placard_std:SW_Push": "Reset button: tactile, SPST momentary, right angle, through hole (drives K1's coil)",
    "placard_std:G5LE-1": "Reset relay: SPDT, 5 V coil (69 ohm, 72 mA), 7 A 30 V DC (NO and NC), through hole, sealed; NC contact carries the 5 V",
    "placard_std:D_Schottky": "Schottky diode, 1 A, DO-41 (black)",
    "placard_std:D": "Small-signal diode, DO-35 (glass)",
    "placard_std:LED": "Power LED, 5 mm, red diffused, through hole (on +5V after K1)",
    "placard_std:R_Network08_US": "Resistor network, 8 bussed, SIP-9",
}
# values that name the part, not a value worth its own column
NO_VALUE = {"placard_parts:Expansion_Slot",
            "placard_std:Jumper_2_Open"}

NOTES = {
    "MF-RG300-0": "Part number from the footprint (Fuse_Bourns_MF-RG300)",
    "1N5817-TP": "Black DO-41 Schottky, so it is not mixed up with the glass 1N4148s; any 1N5817 (MCC, onsemi, Diodes Inc.)",
    "WP7113ID": "D18 with R59 (1k, about 3 mA); any 5 mm LED fits, pick the color (was Lite-On LTL2R3KRD-EM, out of stock 2026-10-25)",
    "1N4148-TAP": "Any 1N4148 (Vishay, onsemi, Diodes Inc.)",
    "Expansion slot": "Optional (Justin, 2026-10-22): fit only the slots a card will go in; the computer "
                      "runs with none.  Sullins EBC20DCAN not stock-checked (EXPANSION.md)",
}

# parts a builder may leave out; the cost summary gives a total without them
OPTIONAL = {("Main board", "EBC20DCAN")}

# ---------------------------------------------------------------- prices
# Unit price in US dollars at the line's quantity for one build, checked 2026-10-22
# (lines marked Mouser re-checked 2026-10-25 for the first parts order, hardware/order/ORDER.md).
# Mouser first, Digi-Key where Mouser has no stock (Justin).  "Mouser" = read from
# Mouser's price breaks; "est." = a typical price for the part named under
# "Priced as", not checked line by line; parts neither distributor sells name the shop.
# Key: the part number, or "description start|value" for a line with none.
PRICES = {
    "ATF22V10C-7PX": (2.99, "Mouser", ""),
    "ATF22V10C-10PU": (2.63, "Mouser", ""),
    "SN74F377AN": (1.54, "Mouser", ""),
    "CD74HCT377E": (1.29, "Mouser", ""),
    "CD74ACT273E": (2.45, "Mouser", ""),
    "SN74F541N": (1.49, "Mouser", ""),
    "AS7C256C-15PCN": (15.21, "Mouser", ""),
    "SN74HCT574N": (1.46, "Mouser", ""),
    "MCP1700-3302E/TO": (0.50, "Mouser", ""),
    "AT28C256-15PU": (12.38, "Mouser", ""),
    "87715-9106": (2.88, "Mouser", ""),
    "USB4125-GF-A-0190": (0.61, "Mouser", ""),
    "KMDGX-6S/6S-S4N": (3.72, "Mouser", ""),
    "MF-RG300-0": (0.73, "Mouser", ""),
    "ANT11TFHQE": (4.50, "est.", "Digi-Key; Mouser has no stock"),
    "J1071CS5VDC.36": (1.15, "Digi-Key", "Justin, 2026-10-25; Mouser does not sell CIT"),
    "PTS645VL58-2 LFS": (0.43, "est.", "Digi-Key; Mouser has no stock until 12/23/2026"),
    "WP7113ID": (0.21, "Mouser", ""),
    "SA5.0A": (0.64, "Mouser", ""),
    "1N5817-TP": None,                              # by quantity, below
    "1N4148-TAP": None,                             # by quantity, below
    "M3AAA-2006J": (6.50, "est.", "Digi-Key (3M 20-way assemblies $6-7.50)"),
    "ECS-100A-251.7": (4.06, "Digi-Key", "Mouser has no stock (Justin, 2026-10-22)"),
    "Box header": (0.60, "est.", "Wurth 61202021621"),
    "SNES controller socket": (4.00, "est.", "ZedLabz right-angle SNES port (Amazon/eBay)"),
    "SD card socket": (4.56, "Mouser", "SMD, push-push (no horizontal through-hole SD socket exists; Kyocera 145638009511859+ went obsolete 2026-10-25)"),
    "54-00174": (0.73, "Digi-Key", "Justin, 2026-10-22"),
    "A-HDF 15 A-KG/T": (1.36, "Digi-Key", "Justin, 2026-10-22"),
    "Expansion slot": (4.50, "est.", "Sullins EBC20DCAN"),
    "Resistor network": (0.39, "Mouser", "Bourns 4609X-101-103LF"),
    "Ceramic capacitor, 5 mm pitch|1u": (0.57, "Mouser", "KEMET C330C105K5R5TA"),
    "Ceramic capacitor, 5 mm pitch|22u": (1.00, "est.", "TDK FG24X5R1A226MRT06 (Digi-Key; Mouser does not list it)"),
    "Ceramic capacitor, 5 mm pitch|15n C0G": (0.58, "Mouser", "TDK FG24C0G1H153JNT06 (KEMET C320C153K1G5TA non-stocked)"),
    "Electrolytic capacitor": (0.35, "est.", "Rubycon YXJ series (Digi-Key; Panasonic EEU-FR1C221 out of stock)"),
    "Pin header": (0.15, "est.", "Sullins PREC002SAAN-RC"),
    "Jumper shunt": (0.10, "est.", "Sullins QPC02SXGN-RC"),
    "IC socket, DIP-14": (0.25, "est.", "On Shore ED14DT"),
    "IC socket, DIP-20": (0.30, "est.", "On Shore ED20DT"),
    "IC socket, DIP-24 0.3": (0.40, "est.", "On Shore ED241DT"),
    "IC socket, DIP-28 0.3": (0.45, "est.", "On Shore ED281DT"),
    "IC socket, DIP-28 0.6": (0.45, "est.", "On Shore ED28DT"),
    "Resistor, 10k (/WE": (0.10, "est.", "Yageo MFR-25FBF52-10K"),
}


def tier(qty, one, ten, hundred):
    return one if qty < 10 else ten if qty < 100 else hundred


def price(d):
    """(unit, source, priced as) for a BOM line, at its quantity."""
    q = d["qty"]
    if d["mpn"] == "1N5817-TP":
        return tier(q, 0.30, 0.15, 0.07), "est.", "MCC 1N5817-TP"
    if d["mpn"] == "1N4148-TAP":
        return tier(q, 0.26, 0.11, 0.05), "Mouser", "Vishay 1N4148-TAP"
    if d["desc"].startswith("Resistor, metal film"):
        return tier(q, 0.10, 0.04, 0.02), "est.", "Yageo MFR-25FBF52 series"
    if d["desc"].startswith("Ceramic capacitor") and d["value"] == "100n":
        return tier(q, 0.23, 0.10, 0.09), "Mouser", "TDK FG28X7R1H104KNT00 (KEMET C320C104K5R5TA is $0.66 at Mouser)"
    if d["mpn"] in PRICES:
        return PRICES[d["mpn"]]
    key = d["desc"] + "|" + d["value"]
    for k, v in PRICES.items():
        if key.startswith(k) or ("|" in k and key == k):
            return v
    return None, "", ""


PLD_JOB = {"STATE": "State", "BRANCH": "Branch", "PC_COUNTER8": "PC", "ALU_SHR": "ALU", "QUAD_MUX": "Address mux",
           "MEM_CTRL": "Memory control", "IO_DECODE": "I/O decode", "HCOUNT": "H counter", "VCOUNT": "V counter",
           "SYNC": "Sync", "COLORDECODER": "Color decoder", "IR": "Instruction register", "AUDIO": "Audio slot",
           "PORT": "Shared port", "PS2": "PS/2 receiver", "CART": "Cartridge loader"}

# On Shore ED sockets: a 1 after the pin count marks the 0.3" version where both widths exist
SOCKET = {(14, False): "ED14DT", (20, False): "ED20DT", (24, False): "ED241DT", (28, False): "ED281DT",
          (28, True): "ED28DT"}

REF_ORDER = ["U", "X", "J", "SW", "K", "F", "D", "R", "RN", "C", "JP"]


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
        if lib_id in K.POWER_SYMBOLS:
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
            m = re.search(r"DIP-(\d+)_W(\d+\.\d+)mm", fp)     # the oscillator X1 is soldered in, no socket
            if m:
                pins = m.group(1)
                wide = m.lastindex > 1 and m.group(2) == "15.24"
                sockets.setdefault((int(pins), wide), []).append(ref)
            if "PinHeader_1x02" in fp and lib_id.endswith("Jumper_2_Open"):
                shunts.append(ref)
    out = []
    for ln in lines.values():
        note = NOTES.get(ln["mpn"]) or NOTES.get(ln["value"]) or next(
            (v for k, v in NOTES.items() if ln["desc"].startswith(k)), "")
        if ln["jobs"]:
            jobs = {}
            for ref, job in sorted(ln["jobs"], key=lambda t: ref_key(t[0])):
                jobs.setdefault(job, []).append(ref)
            note = "; ".join(f"{job} {ranges(r)}" for job, r in jobs.items())
        fps = sorted(f for f in ln["fps"] if f)
        out.append(dict(refs=sorted(ln["refs"], key=ref_key), mpn=ln["mpn"], mfr=ln["mfr"], desc=ln["desc"],
                        value=ln["value"], footprint=fps[0] if len(fps) == 1 else "", notes=note, extra=False))
    out.sort(key=lambda d: ref_key(d["refs"][0]))
    # not on the schematic
    for (pins, wide), refs in sorted(sockets.items()):
        out.append(dict(refs=sorted(refs, key=ref_key), mpn=SOCKET[(pins, wide)], mfr="On Shore",
                        desc=f"IC socket, DIP-{pins} {'0.6' if wide else '0.3'}\"", value="", footprint="",
                        notes="",
                        extra=True))
    if shunts:     # (main board only)
        out.append(dict(refs=shunts, mpn="QPC02SXGN-RC", mfr="Sullins", desc="Jumper shunt, 2.54 mm", value="", footprint="",
                        notes="Bring-up jumpers", extra=True))
    for d in out:
        d.setdefault("qty", len(d["refs"]))
    return out


def md_cell(s):
    return s.replace("|", "\\|")


# ---------------------------------------------------------------- assemblies
# Lines that are on no schematic: the bare PCBs (KIT_PRICING.md fab prices, one board),
# the cartridge shell and its screw (EXPANSION.md "Shell keepouts"), and the case
# (CASE.md "Parts" and "Cost estimate", China sheet metal, one unit).  Each:
# (qty, mpn, mfr, desc, unit price, priced as, notes)
def mech(qty, desc, unit, priced, notes="", mpn="", mfr=""):
    return dict(refs=[], qty=qty, mpn=mpn, mfr=mfr, desc=desc, value="", footprint="", notes=notes,
                extra=True, fixed=(unit, "est.", priced))


CART_SHELL_NOTE = ("Not designed yet: two halves round the card and J8's body, 44 x 19.25 mm outside "
                   "(EXPANSION.md \"Shell keepouts\"); one design takes either card, only its height differs")
PCB_LINES = {
    "Main board": [mech(1, "PCB, main board, 290 x 290 mm, 4-layer, 1.6 mm, HASL lead-free", 16.00,
                        "JLCPCB/PCBWay typical, KIT_PRICING.md")],
    "Cartridge, 64K": [mech(1, "PCB, 64K cartridge, 39 x 102.2 mm, 2-layer, ENIG, hard-gold bevelled fingers", 4.00,
                            "JLCPCB/PCBWay typical, KIT_PRICING.md")],
    "Cartridge, 32K": [mech(1, "PCB, 32K cartridge, 39 x 66.0 mm, 2-layer, ENIG, hard-gold bevelled fingers", 3.50,
                            "JLCPCB/PCBWay typical (smaller than the 64K board)")],
}
SHELL_LINES = {
    "Cartridge, 64K": [mech(1, "Cartridge shell, 64K height (front and back halves)", 4.00,
                            "3D print or moulding, not quoted", CART_SHELL_NOTE),
                       mech(1, "M3 x 6 pan head screw (card to shell at H1)", 0.10, "any M3 x 6 machine screw")],
    "Cartridge, 32K": [mech(1, "Cartridge shell, 32K height (front and back halves)", 3.50,
                            "3D print or moulding, not quoted", CART_SHELL_NOTE),
                       mech(1, "M3 x 6 pan head screw (card to shell at H1)", 0.10, "any M3 x 6 machine screw")],
}
CASE_NOTE = "CASE.md \"Cost estimate\", 1 unit, China sheet metal, not quoted"
ACRYLIC_NOTE = "CASE.md \"Cost estimate\", 1 unit, laser-cut acrylic, not quoted"
CASE_LINES = [
    mech(1, "Tray: 2.0 mm 5052-H32, floor with the front and right walls (two bends), black powder coat, "
            "8 PEM standoffs SO-M3-6 pressed in", 50.00, CASE_NOTE, "case/tray.step"),
    mech(1, "Back plate: 2.0 mm 5052-H32, flat with a bottom flange (one bend), black powder coat, 3 PEM nuts", 23.00,
         CASE_NOTE, "case/back_plate.step"),
    mech(1, "Left plate: 2.0 mm 5052-H32, flat with a bottom flange (one bend), black powder coat, 3 PEM nuts", 23.00,
         CASE_NOTE, "case/left_plate.step"),
    mech(1, "Acrylic top: 4 mm clear cast acrylic, 295 x 220 mm, laser cut, 10 magnet holes", 30.00, ACRYLIC_NOTE,
         "case/acrylic_top.step"),
    mech(4, "Slot cover: 4 mm acrylic plug + 3 mm cap, solvent welded", 3.00, ACRYLIC_NOTE, "case/slot_cover.step"),
    mech(1, "Cartridge cover: 4 mm acrylic plug + 3 mm cap, solvent welded", 8.00, ACRYLIC_NOTE, "case/cart_cover.step"),
    mech(20, "Disc magnet, N52, 6 x 3 mm (10 in the top, 10 through the cover caps, glued)", 0.25,
         "typical N52 magnet price"),
    mech(10, "Steel disc, 6 x 2 mm, zinc plated (flush in the floor: parking for the covers)", 0.10,
         "typical price"),
    mech(8, "M3 male-female hex standoff, 27 mm (H1-H8)", 0.80, "typical standoff price"),
    mech(8, "M3 x 8 button head screw, black or stainless (acrylic top)", 0.15, "typical screw price"),
    mech(6, "M3 x 6 countersunk screw (up through the floor into the plates' flanges)", 0.15, "typical screw price"),
    mech(4, "M3 x 6 button head screw, black (back plate into each expansion card's shell)", 0.15,
         "typical screw price"),
    mech(4, "Rubber foot, 16 mm across, 10 mm tall, adhesive (clears the parked covers)", 0.40, "typical price"),
]

FILES = {"Main board": "BOM_MAIN_PCB", "Cartridge, 64K": "BOM_CART_64K", "Cartridge, 32K": "BOM_CART_32K",
         "Case": "BOM_CASE"}
TITLES = {"Main board": "Main board assembly", "Cartridge, 64K": "64K cartridge assembly",
          "Cartridge, 32K": "32K cartridge assembly", "Case": "Case assembly"}
SCOPE = {
    "Main board": "The main board, built: the bare PCB, every part on the schematic, and the sockets, "
                  "jumper shunts that are not drawn.  It is one line of the case assembly.",
    "Cartridge, 64K": "The 64K ROM cartridge, built: the bare PCB, its parts and sockets, and its shell and "
                      "screw.  A machine takes one cartridge, 64K or 32K.",
    "Cartridge, 32K": "The 32K ROM cartridge, built: the bare PCB, its parts and sockets, and its shell and "
                      "screw.  A machine takes one cartridge, 64K or 32K.",
    "Case": "The computer in its case: the main board assembly ([BOM_MAIN_PCB.md](BOM_MAIN_PCB.md)) as one "
            "line, the case parts from [CASE.md](CASE.md), standoffs, screws and feet.  The cartridge is its own "
            "assembly.",
}
HEADER = ["Qty", "References", "Part number", "Manufacturer", "Description", "Value", "Unit price USD",
          "Line total USD", "Price from", "Notes", "Footprint", "On schematic"]


def write_bom(name, bom, note_opt):
    """docs/<file>.md and .csv for one assembly; returns (total, total without optional, estimated lines)."""
    total = opt = 0.0
    for d in bom:
        d["unit"], d["src"], d["as"] = d["fixed"] if "fixed" in d else price(d)
        total += (d["unit"] or 0) * d["qty"]
        if (name, d["mpn"]) in OPTIONAL:
            opt += (d["unit"] or 0) * d["qty"]
    est = sum(1 for d in bom if d["src"] == "est.")
    parts = sum(d["qty"] for d in bom if not d["extra"])
    md = [f"# Bill of materials: {TITLES[name][0].lower() + TITLES[name][1:]}\n", f"Date: {DATE}\n", SCOPE[name], "",
          f"{len(bom)} lines" + (f", {parts} parts on the schematic" if parts else "") + ".  "
          f"Cost: **${total:,.2f}** for one assembly at these quantities"
          + (f", **${total - opt:,.2f}** without the optional parts ({note_opt})" if opt else "")
          + f".  {est} lines are estimates (*est.*).  Written by `src/scripts/gen_bom.py`; the same list is in "
          f"[{FILES[name]}.csv]({FILES[name]}.csv).  The other BOMs are listed in [BOM.md](BOM.md).\n",
          "| Qty | References | Part number | Manufacturer | Description | Value | Unit $ | Total $ | "
          "Price from | Notes |",
          "|--:|---|---|---|---|---|--:|--:|---|---|"]
    rows = []
    for d in bom:
        if (name, d["mpn"]) in OPTIONAL and not d["notes"].startswith("Optional"):
            d["notes"] = ("Optional (Justin, 2026-10-22).  " + d["notes"]).strip()
        refs = ranges(d["refs"]) if d["refs"] else ""
        note = ("Not on the schematic.  " if d["extra"] and name != "Case" else "") + d["notes"]
        u = d["unit"]
        src = d["src"] + (f": {d['as']}" if d["as"] else "")
        cells = [str(d["qty"]), refs, d["mpn"], d["mfr"], d["desc"], d["value"],
                 f"{u:.2f}" if u is not None else "", f"{u * d['qty']:.2f}" if u is not None else "", src]
        md.append("| " + " | ".join(md_cell(c) for c in cells + [note.strip()]) + " |")
        rows.append([d["qty"], " ".join(d["refs"]), d["mpn"], d["mfr"], d["desc"], d["value"], cells[6], cells[7],
                     src, d["notes"], d["footprint"], "no" if d["extra"] else "yes"])
    with open(os.path.join(ROOT, "docs", FILES[name] + ".md"), "w") as f:
        f.write("\n".join(md) + "\n")
    with open(os.path.join(ROOT, "docs", FILES[name] + ".csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(HEADER)
        w.writerows(rows)
    print(f"{FILES[name]}: {len(bom)} lines, ${total:,.2f}")
    return total, total - opt, est


def main():
    totals = {}
    for name, files in BOARDS:
        bom = PCB_LINES[name] + board_bom(files) + SHELL_LINES.get(name, [])
        totals[name] = write_bom(name, bom, "expansion slot sockets J9-J12")
    main_full, main_base, _ = totals["Main board"]
    case = [mech(1, "Main board assembly (BOM_MAIN_PCB.md)", main_base, "BOM_MAIN_PCB.md total without the "
                 "optional expansion slot sockets", "Add $%.2f with J9-J12 fitted" % (main_full - main_base),
                 mpn="PLACARD main board", mfr="(assembly)")]
    totals["Case"] = write_bom("Case", case + CASE_LINES, "")
    for old in ("BOM.csv",):
        path = os.path.join(ROOT, "docs", old)
        if os.path.exists(path):
            os.remove(path)
    md = [f"# Bills of materials\n", f"Date: {DATE}\n",
          "One BOM per assembly (Justin, 2026-10-25).  The case assembly takes the built main board as one",
          "line; each cartridge assembly is complete with its shell and screw.  Accessories sold with a kit",
          "(USB-C power supply and cable, SD card, programmer, controllers, keyboard and mouse) are in no BOM:",
          "[KITTING.md](KITTING.md) and [KIT_PRICING.md](KIT_PRICING.md) list them.\n",
          "| Assembly | BOM | Contents | Cost | Without optional parts | Lines estimated |",
          "|---|---|---|--:|--:|--:|"]
    contents = {"Main board": "Bare PCB, components, sockets", "Cartridge, 64K": "Bare PCB, components, sockets, "
                "shell, screw", "Cartridge, 32K": "Same, 32K board", "Case": "Main board assembly, tray and plates, "
                "acrylic, magnets, standoffs, screws, feet"}
    for name in ("Main board", "Cartridge, 64K", "Cartridge, 32K", "Case"):
        t, b, est = totals[name]
        f = FILES[name]
        md.append(f"| {TITLES[name]} | [{f}.md]({f}.md), [.csv]({f}.csv) | {contents[name]} | ${t:,.2f} | "
                  f"${b:,.2f} | {est} |")
    md += ["",
           f"A complete machine is the case assembly plus one cartridge: **${totals['Case'][0] + totals['Cartridge, 64K'][0]:,.2f}**"
           f" with the 64K cartridge (the case total already holds the main board without its optional slot",
           "sockets).  Prices are single-unit Mouser (Digi-Key where Mouser has none) for components and",
           "rough single-unit estimates for PCBs, shells and case parts; shipping, tax and tariffs are not",
           "included.  Stock moves, so recheck before ordering.",
           "",
           "Parts with the same part number share a line; where no part number is chosen the column is",
           "blank and parts with the same description and value share the line.  Lines marked \"not on the",
           "schematic\" are bare PCBs, sockets, shunts, shells and screws that KiCad's BOM export leaves out.",
           "The net tie NT1 and the cartridges' edge fingers (their J1) are copper on the PCB, so they are",
           "not listed.  Every PLD is an ATF22V10C-7PX ([CHIPS.md](CHIPS.md#pld-speed-grades)); the notes",
           "give each PLD's job;",
           "[KITTING.md](KITTING.md) lists the images.",
           "",
           "Written by `src/scripts/gen_bom.py` from the KiCad sheets (part numbers are the Manufacturer and",
           "MPN fields set by `gen_kicad_schematic.py`) and the case parts in CASE.md.  Rerun both after a",
           "part change.", ""]
    with open(os.path.join(ROOT, "docs", "BOM.md"), "w") as f:
        f.write("\n".join(md))


if __name__ == "__main__":
    main()
