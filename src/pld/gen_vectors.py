# gen_vectors.py - writes Counter499EN.si for WinSim
def bits(n):
    return "".join("H" if (n >> i) & 1 else "L" for i in range(9, -1, -1))

hdr = """Name     Counter499EN;
PartNo   U1;
Date     10/01/2026;
Revision 03;
Designer Engineer;
Company  ;
Assembly ;
Location ;
Device   g22v10;

ORDER: CLK, %1, EN, %2, Q9, Q8, Q7, Q6, Q5, Q4, Q3, Q2, Q1, Q0;

VECTORS:
"""

rows = []
def clk(en, state):
    rows.append(f"C {en} {bits(state)}")

rows.append('$msg "first clock from 0 jumps to 499";')
state = 499
clk(1, state)

rows.append('$msg "count 499 through rollover";')
for _ in range(530):
    state = 499 if state == 1023 else state + 1
    clk(1, state)

# hold tests at 1023, 511->512 region, and mid-count
def run_to(target):
    global state
    while state != target:
        state = 499 if state == 1023 else state + 1
        clk(1, state)

run_to(511)
rows.append('$msg "EN low at 511, should hold";')
for _ in range(3): clk(0, state)
rows.append('$msg "EN high, 511 -> 512";')
state += 1; clk(1, state)

run_to(1023)
rows.append('$msg "EN low at 1023, should hold";')
for _ in range(3): clk(0, state)
rows.append('$msg "EN high, 1023 -> 499";')
state = 499; clk(1, state)

with open("Counter499EN.si", "w") as f:
    f.write(hdr + "\n".join(rows) + "\n")