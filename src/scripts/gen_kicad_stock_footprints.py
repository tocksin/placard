#!/usr/bin/env python3
"""
gen_kicad_stock_footprints.py - copy the KiCad stock footprints the boards use
(capacitors, diodes, LED, pin header, oscillator, TO-92, SIP resistor network,
mounting holes, net tie) into kicad/lib/placard.pretty, and their 3D models,
plus the models of the DIP socket and resistor footprints that
gen_kicad_kit_footprints.py makes, into kicad/lib/placard.3dshapes.  With every
part in the project library, KiCad finds them on any PC and DRC has nothing to
report as missing or different from its library.

    python3 gen_kicad_stock_footprints.py

The copies are KiCad 9.0.6's own files (KiCad 9 format, the version the boards
were made in), unchanged except that each model line points at the copy in
${PLACARD_LIB}/placard.3dshapes/<footprint>.step.  PLACARD_LIB is a text
variable in each .kicad_pro (main board ${KIPRJMOD}/lib, cartridges
${KIPRJMOD}/../lib), because these footprints sit on the cartridges too and
KIPRJMOD alone points at a different folder in each project.  The boards' copies of these
footprints match KiCad 9.0.6, not 7.  Source: KICAD9_FOOTPRINT_DIR and
KICAD9_3DMODEL_DIR if set (a KiCad 9 install), otherwise KiCad's GitLab
libraries at tag 9.0.6.  KiCad's libraries are CC-BY-SA 4.0 with an exception
for designs that use them.

DERIVED footprints are stock ones with one change, written under their own
name: D_DO-41_SOD81_P7.62mm_Horizontal_Pad1.6 is KiCad's DO-41 at 7.62 mm
with the DO-35's 1.6 mm pads and a 1.0 mm drill (2026-10-28, the 1N5817
Schottkys), so it drops onto the DO-35 places on the routed board with the
same copper.

Run gen_kicad_kit_footprints.py first (its footprints name the socket models).

Date: 2026-10-28
"""

import os
import re
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.normpath(os.path.join(HERE, "..", "..", "kicad", "lib"))
OUT = os.path.join(LIB, "placard.pretty")
OUT3D = os.path.join(LIB, "placard.3dshapes")
MODELS = "${PLACARD_LIB}/placard.3dshapes"   # PLACARD_LIB: text variable in each .kicad_pro
TAG = "9.0.6"
FP_DIR = os.environ.get("KICAD9_FOOTPRINT_DIR")
MODEL_DIR = os.environ.get("KICAD9_3DMODEL_DIR")
FP_URL = "https://gitlab.com/kicad/libraries/kicad-footprints/-/raw/%s/%s.pretty/%s.kicad_mod"
MODEL_URL = "https://gitlab.com/kicad/libraries/kicad-packages3D/-/raw/%s/%s.3dshapes/%s.step"

# (KiCad library, footprint) for every stock footprint on the main board and cartridges
STOCK = [("Capacitor_THT", "C_Disc_D5.0mm_W2.5mm_P5.00mm"), ("Capacitor_THT", "CP_Radial_D6.3mm_P2.50mm"),
         ("Capacitor_THT", "CP_Radial_D8.0mm_P3.50mm"),
         ("Connector_PinHeader_2.54mm", "PinHeader_1x02_P2.54mm_Vertical"),
         ("Diode_THT", "D_DO-15_P10.16mm_Horizontal"), ("Diode_THT", "D_DO-35_SOD27_P7.62mm_Horizontal"),
         ("LED_THT", "LED_D5.0mm"), ("MountingHole", "MountingHole_3.2mm_M3"),
         ("MountingHole", "MountingHole_3.2mm_M3_Pad_Via"), ("NetTie", "NetTie-2_THT_Pad0.3mm"),
         ("Oscillator", "Oscillator_DIP-14"), ("Package_TO_SOT_THT", "TO-92_Inline"),
         ("Resistor_THT", "R_Array_SIP9")]

# (KiCad library, stock footprint, placard name, pad size, drill): stock footprint, pads changed
DERIVED = [("Diode_THT", "D_DO-41_SOD81_P7.62mm_Horizontal", "D_DO-41_SOD81_P7.62mm_Horizontal_Pad1.6", 1.6, 1.0)]

# placard footprint (gen_kicad_kit_footprints.py) -> the KiCad model it shows
KIT_MODELS = {"DIP-%s_Socket_Puller" % d: ("Package_DIP", "DIP-%s_Socket" % d)
              for d in ("14_W7.62mm", "20_W7.62mm", "24_W7.62mm", "28_W7.62mm", "28_W15.24mm")}
KIT_MODELS["R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal_Value"] = \
    ("Resistor_THT", "R_Axial_DIN0207_L6.3mm_D2.5mm_P10.16mm_Horizontal")


def fetch(local_dir, sub, name, url):
    if local_dir:
        with open(os.path.join(local_dir, sub, name), "rb") as fh:
            return fh.read()
    with urllib.request.urlopen(url) as r:
        return r.read()


def model(lib, stock, name):
    data = fetch(MODEL_DIR, lib + ".3dshapes", stock + ".step", MODEL_URL % (TAG, lib, stock))
    with open(os.path.join(OUT3D, name + ".step"), "wb") as fh:
        fh.write(data)
    print("wrote", name + ".step")


def main():
    for lib, name in STOCK:
        s = fetch(FP_DIR, lib + ".pretty", name + ".kicad_mod", FP_URL % (TAG, lib, name)).decode()
        m = re.search(r'\(model "\$\{KICAD9_3DMODEL_DIR\}/([^/]+)\.3dshapes/([^"]+)\.step"', s)
        if m:
            model(m.group(1), m.group(2), name)
            s = s.replace(m.group(0), '(model "%s/%s.step"' % (MODELS, name))
        assert "KICAD9_3DMODEL_DIR" not in s, name
        with open(os.path.join(OUT, name + ".kicad_mod"), "w", newline="\n") as fh:
            fh.write(s)
        print("wrote", name)
    for lib, stock, name, size, drill in DERIVED:
        s = fetch(FP_DIR, lib + ".pretty", stock + ".kicad_mod", FP_URL % (TAG, lib, stock)).decode()
        s = s.replace('(footprint "%s"' % stock, '(footprint "%s"' % name, 1)
        s, n = re.subn(r'\(size [0-9.]+ [0-9.]+\)(\s*)\(drill [0-9.]+\)',
                       lambda m: "(size %g %g)%s(drill %g)" % (size, size, m.group(1), drill), s)
        assert n == 2, name
        m = re.search(r'\(model "\$\{KICAD9_3DMODEL_DIR\}/([^/]+)\.3dshapes/([^"]+)\.step"', s)
        model(m.group(1), m.group(2), name)
        s = s.replace(m.group(0), '(model "%s/%s.step"' % (MODELS, name))
        with open(os.path.join(OUT, name + ".kicad_mod"), "w", newline="\n") as fh:
            fh.write(s)
        print("wrote", name)
    for name, (lib, stock) in KIT_MODELS.items():
        with open(os.path.join(OUT, name + ".kicad_mod")) as fh:
            assert '(model "%s/%s.step"' % (MODELS, name) in fh.read(), name
        model(lib, stock, name)


if __name__ == "__main__":
    main()
