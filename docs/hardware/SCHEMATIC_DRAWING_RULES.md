# Schematic drawing rules

Date: 2026-11-10

These are the changes Justin asked for while the PLACARD schematics,
symbols and diagrams were being drawn, written as rules so any new or
revised drawing starts out the way he wants.  Each rule quotes his request
(or gives the decision) with its date and where it was made.
[SCHEMATIC_PLAN.md](SCHEMATIC_PLAN.md) has the sheet list, net names and
how the KiCad generator carries these rules out.

## 1. Plan the sheets before drawing

1.1. **Start with a page plan:** how many sheets, and which chips go on
each.  *"create a schematic organization plan.  how many schematic pages
will you need, and which chips will go on which pages."* (2026-10-20,
thread "Schematic page plan")

1.2. **Keep a sheet to about six chips** so it can be drawn with large
text (follows from rules 1.1 and 2.1).  A new part goes on the sheet of the
block it belongs to.

1.3. **The root sheet is the block diagram**, with the sheets laid out like
the system block diagram (2026-10-20 page plan).

## 2. Placement first, then large text

2.1. **Place blocks and nets first, then make the text as large as fits.**
*"you need to use larger text for these schematics.  set the text size
after placing everything else - the placement of blocks and nets should
take priority.  but keep the text on the larger size"* (2026-10-19, I/O
and audio schematic PNGs)
- Matplotlib drawings: call `schematic_text.fit_text(fig, ax)` just before
  saving.  It starts every label at 1.8x and shrinks only those that hit
  another label, a wire, a chip or a frame.
- KiCad sheets: references 2.5 mm, values 2 mm, labels 2 mm, on a sheet
  with room around each chip.

2.2. **Spread parts out so no text overlaps.**  *"spread out the
components when needed so the text isn't overlapping other text or
symbols."* (2026-10-21, "Schematic page plan")

2.3. **Move parts to make room for wires.**  *"you can move the j2/j3
symbols or any others around if you need to make more space for the net
lines."* (2026-10-27, "Rename schematic buses and wire shared port")

## 3. Wires, buses and labels

3.1. **Wire a net that appears more than once on a sheet.**  *"ok on each
page, if there is a net that has more than one callout on the page, can
you wire a net between them."* (2026-10-20, "Schematic page plan")  A net
with only one pin on the sheet keeps a label.

3.2. **Draw outputs to where they go.**  *"on the shared port page, can you
draw lines for the shared port pld outputs to their on page nets.  also
I'm not seeing where K0 output goes."* (2026-10-27)  A reader must be able
to follow every output to its load on the sheet without hunting for a
matching label.

3.3. **One bus per sheet.**  *"if there's a bus, make it into a single bus
net and route the bus net across the board."* (2026-10-20)  Three or more
numbered nets form a bus with bus entries and one bus label.

3.4. **Buses stay buses.**  *"keep the bus lines as bus lines (for example,
PIX[0..7]."* (2026-10-21)

3.5. **Straight wires, few bends.**  *"maintain straight lines with as few
bends as possible."* (2026-10-21)  Wires may cross another net at right
angles but never run along it.

3.6. **Keep nets off the page-exit tabs, and keep the tabs horizontal.**
*"try to keep the nets from overlapping the page exit tabs like H1 ...
if possible keep the page exit tabs like D[0..7] horizontal"* (2026-10-21)
Power symbols on a side pin point away from the part, and their names read
across too.

3.7. **No jumbles.**  *"avoid strange net jumbles like around the PWR_FLAG
symbol."* (2026-10-21)  Power flags and power symbols get their own clear
space.

## 4. Net names

4.1. **Spell the main buses out** (2026-10-27): *"I'd like the address bus
to be ADDR instead of A.  I'd like the databus to be DATABUS instead of D,
and change the d register from DR to D."*  So `ADDR15`-`ADDR0`,
`DATABUS7`-`DATABUS0` and the D register's `D7`-`D0`.

4.2. **Name a net for what it does.**  Justin renamed the mouse clock
`PS2_CLK` to `MOUS_CLK` (2026-10-25) and the audio output to a line out
(2026-10-23), so names say which port or job they belong to.

## 5. Parts and symbols

5.1. **Decoupling caps sit next to their chip.**  *"i would like caps to be
next to their adjacent chip on the schematic"* (2026-10-20)  Each Cn is
drawn beside its Un, between its VCC and GND pins.

5.2. **A decoupling cap takes its chip's number.**  *"if possible name the
decap the same number as the chip it's going with"* (2026-10-20)  C1 goes
with U1.

5.3. **Every PLD shows its job.**  *"you need the name of each pld next to
it"* (2026-10-20)  For example "Branch PLD" in bold under the part number.

5.4. **PLD symbols** (2026-10-20, thread "KiCad symbols for the project"):
*"don't include the pld revisions on them, but the file names are ok.
those pld symbols could be a little smaller in the X direction.  the pins
don't need to be in numerical order, in fact, they should be oriented in
whichever way makes the schematic more straightforward.  the functions
should be grouped together if they are unrelated in the pld."*
- No revision on the symbol; the .pld file name is fine.
- Narrow boxes.
- Pins placed for straight wiring: inputs left, outputs right, buses
  together in bit order, so they line up with the part they connect to.
- Functions that are unrelated inside the PLD get their own group.

5.5. **Send PNGs of new symbols for review.**  *"when finished, create
pngs with all the symbols for me to review"* (2026-10-20)

5.6. **Count reference numbers up from 1** (2026-10-22, decision recorded
in [SCHEMATIC_PLAN.md](SCHEMATIC_PLAN.md)): no per-sheet hundreds or
thousands, no numbers built from a position such as a keyboard matrix
(SW153 became SW1-SW63), no gaps.  U keeps the CHIPS.md numbers, J the
IO.md numbers.  A new part takes the next free number of its kind.

5.7. **Resistors use the US zigzag symbol**, not the IEC box (2026-10-22).

5.8. **Through-hole parts wherever possible.**  *"i'd lke through hole
parts wherever possible"* (2026-10-22)  Every part carries Value,
Manufacturer and an active MPN; parts a builder can leave out (the
expansion slot sockets, the keyboard header) are marked optional (*"make
the expansion slot connector optional to try to bring the price down"*,
2026-10-22).

## 6. Who owns the files

6.1. **Justin's KiCad edits are the source for the main board sheets**
(2026-10-30): *"i've been updating schematic and layout so integrate those
changes as well"*.  Since then, take in his saved sheets first and change
only what was asked.  Never commit a full regeneration of the main-board
sheets from `gen_kicad_schematic.py`; regenerate in a scratch copy, take
only the sheet you need, and check the netlist against his.

6.2. **Keep the rules when a plan is done.**  *"clean up the schematic plan
document.  its been implemented, but leave the rules in case we need to
make revisions"* (2026-10-27)

## 7. Output

7.1. **PDFs open without the bookmarks panel** (2026-10-21): drop the
outline and set PageMode to UseNone after every export.
`gen_kicad_schematic.py --pdf` does this.

7.2. **Check before handing over:** the netlist check must report 0
problems and no text overlaps, and the ERC runs in KiCad 8 or 9 on
Justin's PC.

## 8. Block diagrams

8.1. **Leave clocks off.**  *"remove the clock routes as they are implied
in a block diagram"* (2026-10-04, original project chat "Block diagram
software output formats")

8.2. **Group by function:** *"have the video components on the right, the
cpu components on the left, and the memory and i/o and audio in the
middle."* (2026-10-23, "Block diagram regrouped")

8.3. **Draw what the reader needs, not every part, and avoid crossings:**
*"combine the source and databus and remove the resistors inbetween them.
just call it the source bus.  move the control and instruction register
below the d/ac/source drivers.  move the d register below the AC register.
and swap the outputs of the ac."* (2026-10-23)  Series resistors are left
out of the block diagram, and outputs are ordered so lines don't cross.
