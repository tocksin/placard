# Schematic rules

Date: 2026-10-27

The KiCad schematic (`kicad/`) is drawn by
`src/scripts/gen_kicad_schematic.py` (with `kicad_sch_lib.py` and the router
`kicad_route.py`).  This page keeps the rules it follows, so a revision
draws the same way.  The nets themselves are the pin-by-pin list in the
script; `--check` compares KiCad's netlist with it.

## Projects and sheets

**Main board:** one project `kicad/placard.kicad_pro`, 11 A3 landscape
sheets: a root sheet and 10 sub-sheets.  **Cartridges:** two projects,
`kicad/cartridge_64k/` and `kicad/cartridge_32k/`, one A3 sheet each (a
KiCad project has one PCB).  All three share the libraries in `kicad/lib/`.

| Sheet | File | Title | What goes on it |
|--:|---|---|---|
| 1 | `placard.kicad_sch` | Root: block diagram | sheet boxes only, laid out like `reference/placard_block_diagram.png` |
| 2 | `power.kicad_sch` | Power and clock | U40 regulator, oscillator X1, USB-C input, F1, D7, SW1, K1/SW2/D8, C41, STALL_OUT pull-up, RUN pull-down, JP1/JP2, power LED |
| 3 | `control.kicad_sch` | Control | U1 State, U2 Branch, U17 instruction register |
| 4 | `pc_mux.kicad_sch` | Program counter and address mux | U3, U4 PC, U7-U10 address mux |
| 5 | `alu_regs.kicad_sch` | ALU and registers | U5, U6 ALU, U19 AC, U20 X, U21 Y |
| 6 | `data_bus.kicad_sch` | Data bus | U18 D register, U26/U27 source F541s, series resistors, data bus pull-up SIP |
| 7 | `memory.kicad_sch` | Memory and I/O decode | U11 memory control, U12 I/O decode, U25 map register, U31/U32 RAM, cartridge slot J8 |
| 8 | `video_timing.kicad_sch` | Video timing | U13 H counter, U14 V counter, U15 Sync, U35 audio/mode PLD, U29 line read, sync resistors |
| 9 | `video_out.kicad_sch` | Video and audio out | U22 pixel buffer, U23 line code, U16 color decoder, U36 audio DAC register, VGA DAC and J7, R-2R ladder, filter, J6, row tint |
| 10 | `shared_port.kicad_sch` | Shared port | U38 port PLD, U42 PS/2 receiver, J2/J3 SNES, J4 SD, J5 PS/2 |
| 11 | `expansion.kicad_sch` | Expansion slots | J9-J12 and their SEL resistors |

Keep a sheet to about six chips so it can be drawn with large text.  A new
part goes on the sheet of the block it belongs to.

## Hierarchy and net names

- **Hierarchical sheets joined by global labels.**  Each sub-sheet is used
  once; the root holds the sheet boxes with no hierarchical pins.  A
  misspelled global label silently makes a new net, so the ERC's "global
  label not connected anywhere else" must be clean.
- **Net names are the PLD pin names**, active low written `/NAME`.  The
  main board and the cartridges use the same names on the cartridge
  connector (`ADDR0`, `DATABUS0`, `/CE_HI`, `STALL_OUT`, ...).
- **The three main buses** (Justin, 2026-10-27): the address bus is
  `ADDR15`-`ADDR0`, the data bus `DATABUS7`-`DATABUS0` and the D register's
  outputs `D7`-`D0`.  The other docs write the address and data bits as
  A15:A0 and D7:D0; those are the CPU's bits, the same signals as
  `ADDR`/`DATABUS` here.  In the script the Python lists keep the short
  names `A`, `D` and `DR`.
- **Each bit is its own net** (`ADDR0`, `ADDR1`, ...).  A group of three or more
  numbered nets on a sheet is drawn as a bus (see "Buses" below).

## Reference designators

- **Chips:** U = the `#` column of [CHIPS.md](CHIPS.md), fixed (annotation
  keeps existing references), gaps left empty so every document's chip
  numbers stay right.  The cartridges number their own chips from U1
  (64K U1-U5, 32K U1-U3).
- **Connectors:** as [IO.md](IO.md) and [SOUND.md](SOUND.md) use them: J2-J6,
  then J7 VGA, J8 cartridge slot, J9-J12 expansion slots 1-4, J13 USB-C.
  The cartridge fingers are J1 on each cartridge.
- **Decoupling capacitors:** Cn goes with Un (C1 with U1), set by hand and
  kept by the annotation; a missing Un leaves Cn unused.  C41 is the bulk
  capacitor, so the decouplers are C1-C40 and C42.
- **Every other part** (Justin, 2026-10-22): numbered from 1 for each kind
  of part, counted up across the board with no gaps and no per-sheet
  hundreds or thousands.  Other capacitors are C41, then C43 on.  A
  new part takes the next free number of its kind.
  `--check` fails on gaps or high numbers.
- **Renumbering** keeps the symbol's uuid (`KEPT_UUIDS` and `RENUMBERED` in
  `kicad_sch_lib.py`) so Update PCB from Schematic renames the footprint instead of
  replacing it.
- **Resistor symbol** (Justin, 2026-10-22): the US / NEMA zigzag (`R_US`,
  `R_Network08_US`), not the IEC box.

## How the sheets are drawn

Edit the script and rerun it after any pin or part change; never edit the
sheets by hand, or the next run overwrites the edit.

- **Blocks first, then nets, then text.**  Chips sit on a grid with room
  around them, then the text is made as large as fits.  References are
  2.5 mm, values 2 mm, labels 2 mm; each PLD also shows its job in bold
  under its part number ("Branch PLD", "Address mux 3:0", ...).
- **Wires between the pins of a net** (Justin, 2026-10-20): a net with two
  or more pins on a sheet is wired pin to pin by the grid router.  Wires
  run on the 1.27 mm grid, may cross another net at right angles but never
  run along it, bend on it or touch its pins, and keep clear of parts and
  text.  A net that also goes to another sheet gets one global label on one
  of its pins; a net with a single pin on the sheet gets a label on a short
  wire (staggered between neighbours).  Junctions mark every T, and the
  wires are cut there (KiCad 7 needs that).
- **Buses:** a group of three or more numbered nets on a sheet (`DATABUS`, `ADDR`,
  `SRC`, `D`, `PC`, `H`, `V`, `VA`, `RAMSEL`, `ROW`, `DAC`, ...; not the
  ladder `LAD`) gets one bus per sheet: each pin has a short wire with its
  member label (`DATABUS3`) and a bus entry onto a bus line beside the chip, the
  router joins the bus lines of all the chips, and one bus label
  (`DATABUS[0..7]`, global when the bus leaves the sheet) names it.  Where the
  router cannot join a bus piece it gets its own bus label.
- **Tidying rules** (Justin, 2026-10-21): parts are spread out so no text
  sits on other text or a symbol; wires run straight with as few bends as
  possible; buses stay buses; nets keep off the page-exit tabs, and the tabs
  read horizontally; no jumbles at PWR_FLAG.  The tools for this:
  - `label_each`: buses that come from other sheets (`DATABUS`, `ADDR`, `ROW`, ...)
    get a bus piece and bus label at each chip instead of one long trunk
    looping round the sheet; a single member (one diode on `ROW7`) gets a
    plain label.
  - `label_nets`: busy control nets (`CLK`, `RUN`, `RW`, the port PLD's
    inputs on the shared port, the slot controls) are labelled at every pin
    instead of wired.  The port PLD's outputs (P_SCK, P_MOSI, P_CS, P_PS2D,
    K0) are wired to the pads, the SD dividers and the PS/2 hold diodes
    (Justin, 2026-10-27).
  - `force_bus`: a short group drawn as a bus anyway (`I[5..7]`).
  - Hand layout where the router's choice is poor: `bare` pins with
    straight `path()` wires, `bus_piece()` trunks the router joins the chip
    pieces to (the cartridge's `DATABUS[0..7]` along the top), `name()` labels in
    an even column instead of staggered.  The shared port, expansion and
    cartridge sheets are hand-laid this way.
  - PLD and connector symbols may have their pins reordered or spaced a row
    apart so the wires run straight (the cartridge loader PLD's pins line up
    with the cartridge connector's; the expansion slot's SEL pin is last,
    with its 1k straight off it).  Symbol pin order is set in
    `gen_kicad_symbols.py` (LAYOUT table).
  - Power symbols on a side pin are turned to point away and their names
    read across.
  - A few crossings are accepted where two identical chips share the same
    pin order (the select lines of the address muxes).
- **Decoupling** (Justin, 2026-10-20): each chip's 100 nF Cn is drawn beside
  its Un, between its VCC and GND pins, with its +5V and GND symbols on its
  own pins, raised 5.08 mm so its GND symbol clears the chip's top pins.  On
  the PCB each one sits at its chip's VCC pin.
- **Hand-drawn wires** where a picture helps: the R-2R ladder is a wired
  chain; rows of pins tied to GND share one GND symbol.
- **Bring-up straps** S1-S5 are temporary wires in the chip sockets
  ([BRINGUP.md](BRINGUP.md)), so they are not on the schematic; the
  jumpers JP1 (STALL) and JP2 (RUN) are.
- **Part fields:** every part carries Value, Manufacturer and MPN (the
  script's `MPN` table), which `gen_bom.py` reads for the BOMs.  Pick a
  through-hole part whenever one exists (Justin, 2026-10-22).

## Checking and output

- `gen_kicad_schematic.py --check` exports KiCad's netlist and compares
  every net with the script's list, then runs simple electrical checks
  (single-pin nets, two outputs on a net, power without a source),
  numbering and text overlaps.  It must report 0 problems.
- The container's KiCad 7.0 command line has no ERC, so after a change
  also run Inspect > Electrical Rules Checker in KiCad 8 or 9.
- `gen_kicad_schematic.py --pdf` writes `schematics/placard_main.pdf`,
  `schematics/placard_cartridge_64k.pdf` and
  `schematics/placard_cartridge_32k.pdf` with kicad-cli and drops the
  bookmarks so they open without the bookmarks panel.

## Design choices to keep

- **The clock tap** (2026-10-27, FETCH_TIMING.md option B): X1 drives
  CLK_E, which goes only to the Sync PLD's pin 9 (the RAM /WE) and to net
  tie NT2 on the power sheet; CLK, to every other chip, is NT2's other
  side.  The tie keeps the two nets apart in the netlist so the board can
  put at least 420 mm of track (500 nominal, 3 ns) between X1/U15 and the
  rest of the clock tree.  NT2 is not in the BOM, like NT1.

Choices made while drawing that a revision should not undo by accident:

- The expansion slots' former SD7:SD0 contacts are BT1-BT8 (boot contacts
  on slot 1, open on slots 2-4); cards latch DATABUS7:0.  /WE has a 10k pull-up
  (R63).  [EXPANSION.md](EXPANSION.md), "Booting from slot 1".
- The slots' LOAD_IMM contact carries the State PLD's `/LOAD_IMM` as it is
  (active low).
- U36 (audio DAC register) is on the audio rail: VCC on DAC_5V, GND on
  GNDA, where its ladder returns.
- Polyfuse F1 holds 3 A (Bourns MF-R300 size); the PLDs can draw about
  2.5 A.  SW1 and K1's contact carry the whole board's current, so each is
  rated 5 A DC or more.
- C41 (bulk) sits on VON ahead of K1, so pressing reset leaves only the
  board-side decouplers to drain.  The power LED hangs from +5V after K1,
  so it goes dark while reset is held.
- D7, the TVS on VBUS, sits after F1 so a lasting overvoltage trips the
  fuse.  No snubbers across SW1 or K1 (a 5 V contact cannot hold an arc).
- **No ESD clamps on the external connectors** (Justin, 2026-10-23).
- /HSYNC and /VSYNC reach J7 through 47 ohm R61 and R62 next to the PLD;
  the nets after them are /VGA_HSYNC and /VGA_VSYNC.
- J9-J12 (expansion slot sockets) are optional parts on the BOM.
