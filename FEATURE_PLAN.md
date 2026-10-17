# Feature plan: I/O (bare bones) and software

This is a planning list, not a design.  Nothing here is implemented yet.  It
covers the I/O the Placard still needs: keyboard, SNES controllers, SD card
storage, a mouse and four expansion ports.  The Software section lists the
programs planned for the machine itself.

The goal is the **fewest added chips**, even at the cost of features.
Software does whatever hardware can be left out.  Things that were cut are
listed at the end in case they are wanted later.

## Starting point

These facts from the current design shape every choice below.

- **Device strobes.**  Each device gets its own strobe from the I/O decode
  PLD: /PORT_WR and /PORT_RD (x52), /EXP1 (x51) and /EXP2 (x53), both address
  only.  Write strobes are low for the /WE pulse; read strobes are qualified
  by LOAD_IMM.  The PLD has no spare pins.
- **Only `[Y,X]` reaches I/O.**  `[0,D]` and `[0,X]` only address the zero
  page, so every I/O access is `ld 0x5n, y` then `ld [y,x], ac` (read) or
  `ld ac, [y,x]` / `ld n, [y,x]` (write).
- **There are no interrupts.**  All I/O is polled.
- **There are no wait states.**  Every device must answer a read within one
  CPU clock (about 40 ns at 25 MHz) and take a write pulse of about 20 ns.
  /WE is low only in the low half of a CPU write clock, and memory reads also
  use only the low half.  The I/O read strobes are qualified by LOAD_IMM, not
  the clock, which is worth checking against that rule when the first read
  device is designed.  Devices that drive the read bus must enable in 9.5 ns
  or less (see TIMING_FIXES.md).
- **The CPU's speed is not a clock.**  Video reads stall the CPU on one clock
  in eight during visible lines and never during blanking, so time has to
  come from the video counters.
- **Free PLD pins** that a feature could use instead of adding a chip:
  MEM_CTRL PLD pins 20-22.
- **Device latches take data from the source bus**, not the RAM-side data
  bus, and latch on the rising edge of their write strobe.  The source bus
  holds the data past the end of the write; the RAM-side bus does not.

## Chip count

| Feature | Added chips |
|---|---|
| Shared port: keyboard (65 keys), 2 SNES pads, SD card | 74HC574, 74F138, 74F541, CD4050, plus a 3.3 V regulator |
| Expansion ports (4) | none, connectors only |
| **Total** | **4 logic chips + 1 regulator** |

## Parts rule and stock check

Only DIP parts with active stock at Digikey or Mouser, and 74F where it is in
stock, for the better timing.  Checked 2026-10-15 (stock moves, so recheck
before ordering):

| Part | DIP part number | Status |
|---|---|---|
| 74F541 | SN74F541N (TI) | Mouser: 723 in stock |
| 74F138 | SN74F138N (TI) | Listed at Digikey and Mouser as 16-PDIP; stock count not confirmed |
| CD4050 | CD4050BE (TI) | Mouser: 10,831 in stock |

**Where 74F is not used, and why:**

- **Shared port output latch stays 74HC574.**  74F outputs only guarantee about
  2.7 V for a high, and the SNES pad's CMOS 4021s need 3.5 V at 5 V.  The HC
  latch swings rail to rail.
- **No level shifter on MISO.**  The SD card's 3.3 V MISO goes straight into
  the shared port's 74F541, whose TTL-level inputs read 3.3 V as a high.
- **CD4050** has no 74F equivalent: it runs from 3.3 V to shift the SD lines
  down, which a 5 V-only family can't do.

**74F caveat on the data bus:** the 74F541s drive the CPU's read bus.  That
is fine for TTL-level inputs (the ATF22V10C and typical SRAM), but if any
register that latches the read bus is a plain 74HC part, its 3.5 V input
threshold is above the 74F's guaranteed high.  Use HCT (or F) on those
inputs, or keep HC541s on the bus.

## 1. Shared port: keyboard, SNES pads and SD card (x52)

The keyboard, the pads and the SD card are never needed at the same moment,
so software takes turns: scan the keyboard, then read the pads, and talk to
the SD card only when loading or saving.  They share one output latch and one
input buffer.  Everything is bit-banged; there is no hardware shifter.

| Address | R/W | Function |
|---|---|---|
| x5200 | W | Output latch (74HC574): bit 0 SCK / pad CLOCK, bit 1 SD MOSI / pad LATCH, bit 2 SD /CS, bits 7:3 keyboard columns 8-12 (0 = drive the column) |
| x5200 | R | 74F541 with no decoder column driven: bits 4:0 rows of whichever latch column is low, bit 5 pad 2 DATA, bit 6 pad 1 DATA, bit 7 SD MISO |
| x5208 + n | R | The same, with decoder column n (0-7) driven low for the read |

**Keyboard: 13 columns x 5 rows = 65 keys**, with no added chips.  Only 5 of
the buffer's 8 bits are rows, because the other 3 carry the serial inputs, so
the extra keys come from extra columns:

- **Columns 0-7 come from the 74F138**, decoded from A2:A0 and driven low only
  for the length of a read.  Its active-high enable (G1) is wired to A3, so
  only reads of x5208-x520F drive a column; reads of x5200-x5207 drive none.
  /PORT_RD goes to the active-low enable, as before.
- **Columns 8-12 come from the output latch**, bits 7:3.  They are static, so
  software drives one low, reads x5200 (no decoder column), then sets it high
  again.  Keep all five high while scanning columns 0-7.
- **The latch bits come free** by putting the pads' LATCH on the MOSI line.
  The SD card ignores MOSI while its /CS is high, and the pads' LATCH being
  toggled during an SD transfer only reloads their shift registers, which
  software does again before every pad read anyway.
- **A full scan is 13 reads and 10 latch writes.**  Debounce, shift, rollover
  and repeat are in software, once per frame using the line read.  Each key
  has a diode and each row a pull-up, as before.

**Serial inputs ride along on every read.**  Bits 7:5 show MISO and both pad
data lines on every read.  The serial code reads x5200, so it never drives a
decoder column.  MISO is on D7 so that loading it into AC sets the
negative flag and `blt` / `bge` can test it directly.  The buffer's inputs
are TTL level, so the card's 3.3 V MISO needs no level shifting coming back.

**One clock line for both pads and the SD card.**  The SD card ignores SCK
while its /CS is high, and the pads' extra shifting during an SD transfer
does no harm because software pulses LATCH before every pad read.  Only the
software's idle level differs (the pads idle with CLOCK high, SPI mode 0
idles low), which costs nothing in bit-bang.

**SNES pads:** with SD /CS high, pulse LATCH (the MOSI bit), then read DATA and pulse CLOCK 16 times.  The
first bit (B) is ready right after LATCH.  The bits are B, Y, Select, Start,
Up, Down, Left, Right, A, X, L, R, then four 1s, with 0 meaning pressed.  Both
pads share LATCH and CLOCK and land on different bits, so one pass reads
both.  The pads run at 5 V and need no level shifting.

**SD card:** SPI mode 0 in software.  SCK, MOSI and /CS go through a CD4050
powered from 3.3 V, and a 3.3 V regulator powers the card.  Software runs at
roughly 10 instructions per bit (an estimate), so tens of KB/s, which is fine
for loading and saving programs.  Raw sectors first (a fixed sector range per
saved program), FAT later if cards need to be filled from a PC.

**The latch is write-only**, so software keeps a copy of it in zero page and
changes one bit at a time from that copy.  It has no spare bits now; they all
went to keyboard columns.  The latch stays 74HC
because the pads' CMOS inputs need a full 5 V high.

**Timing to check:** a decoder-column read goes /PORT_RD, 74F138, column wire, key diode,
row, 74F541, data bus inside one clock.  The 74F parts keep that short, but
the diode and the row's pull-up are the slow part of the path.

## 2. Mouse (interface not chosen yet)

A two-button mouse, read once per frame like the pads.  Which kind of mouse
is still open; the two practical choices are below.

| | SNES mouse (default) | PS/2 mouse |
|---|---|---|
| Where it plugs in | One of the two SNES pad ports on the shared port | An expansion card |
| Added chips | none | about 2 (a latch with open-collector outputs, and a buffer) |
| Mice to buy | Original Super NES Mouse (1992, used only) or Hyperkin Hyper Click (new) | Still sold new |
| Uses up | One pad port while it is plugged in | One expansion port |

**SNES mouse** (protocol from the SNESdev wiki):
- Same LATCH, CLOCK and DATA as a pad, but 32 bits per read: a zero byte,
  then signature, sensitivity and the two buttons, then 7-bit Y and X
  movement since the last read.  Movement is sign and magnitude, not two's
  complement.
- Needs at least about 8 us between bits and 16 us after bit 16, so a read is
  about 0.3 ms.  Bit-banged software has to pace itself; the Hyper Click is
  the most sensitive to reading too fast.
- The original mouse's sensitivity is cycled through LATCH and CLOCK; the
  Hyper Click ignores that and uses a button on its underside.
- Software tells a mouse from a pad by the signature bits, so either port
  can take either.

**PS/2 mouse:**
- A two-wire serial link (clock and data, both open-collector) where the
  mouse drives the clock at about 10-17 kHz.  The host can hold the clock low
  to make the mouse wait, and can ask for one 3-byte packet at a time (remote
  mode), so it can be polled without interrupts.
- The shared port has no spare bits, so it needs its own 2 open-collector
  outputs and 2 inputs.  An expansion card has the read and write strobes
  for that.

**Not considered:** quadrature (bus) mice need a hardware counter, because
the CPU can't catch every edge without interrupts; serial (RS-232) mice need
a ±12 V level shifter as well as a software UART.

## 3. Expansion ports (x51, x53, connectors only; 4 ports)

| Signal | Meaning |
|---|---|
| D7:D0 | Read bus (the card drives it on a read, enabling in 9.5 ns or less) |
| SD7:SD0 | Source bus (the card latches writes from it) |
| A7:A0 | Register select inside the port's page |
| /EXPn | Port select (address only) |
| RW, /WE, LOAD_IMM, CLK | So a card can build its own read and write strobes: read = /EXPn low, RW high and LOAD_IMM high; write = /EXPn low and /WE low, latching on the rising edge of /WE |
| RESET, +5 V, GND | Several grounds between the fast signals |

- **Unbuffered.**  Keep the cable short (or use a direct board-edge
  connector) and keep the card's load light: one or two HC/AC inputs per
  line.
- A 2 x 20 box header fits all of it.

### Four ports on two selects

The board has four expansion connectors.  The I/O decode PLD has only two
expansion selects and no spare pins, so ports 3 and 4 share the selects
of ports 1 and 2 and split each page in half by A7.  No main-board chips are
added; the card does the split.

| Port | Select | Card responds when | Addresses |
|---|---|---|---|
| 1 | /EXP1 | A7 = 0 | x5100-x517F |
| 3 | /EXP1 | A7 = 1 | x5180-x51FF |
| 2 | /EXP2 | A7 = 0 | x5300-x537F |
| 4 | /EXP2 | A7 = 1 | x5380-x53FF |

- **Each card gets 128 registers instead of 256**, which is still far more
  than a typical card uses.
- **A jumper on each card** picks which half it answers (A7 = 0 or 1), so one
  card design works in any of the four ports.  The card already builds its
  own read and write strobes, so adding A7 to that is one more input to the
  same gate or PLD on the card.
- **Bus loading.**  With four unbuffered ports, every line sees up to four
  cards.  Keep each card to one HC/AC/F input per line and the cables short.
  If that proves too much, buffered ports are in the cut list below.

## Software

Software that runs on the Placard itself.  It all builds on the standard
library (LIBRARY.md: calling convention, software stack, text console at
x3000-x3FFF) and the ROM layout in ROM.md.  Free ROM for it today is
x0004-x2FFF (12 KB) plus x4000-x4FFF and x5400-x5FFF; free RAM is about
18 KB (x0100-x2FFF, x4000-x4FFF and the small pieces in section 2), plus up
to 20-30 KB of video RAM when rows use 2x or 4x line repeat.

### Drivers first (needed by everything below)

- **Keyboard:** scan the 13 x 5 matrix once per frame, debounce, map to ASCII
  with shift and control, and keep a small key buffer.
- **SNES pad / mouse:** read the pads (and the mouse, if that is the choice)
  once per frame.
- **SD card:** SPI mode 0 init, read and write one 512-byte sector.
- **FAT filesystem:** FAT16/FAT32 read first (open a file, read it, list a
  directory), write later.  This is what lets a PC put files on the card.
  Raw-sector storage can come first and stay as a fallback.

These go in the library, which needs more code space than its 2 KB page
(LIBRARY.md says it is full), probably the free ROM at x0004-x2FFF.

### Monitor

A machine-code monitor in ROM: examine and change memory, show the
registers' last values, jump to an address, hex dump, fill and copy, load
and save memory ranges to the SD card, and a small disassembler using the
opcode table in `reference/opcode_map.html`.  It is the first program to
write once the keyboard driver works, because it is how everything after it
gets debugged on the real machine.

### Boot menu

Replaces the boot loader's fixed choice (the boot mode byte at xFC00).  At
power-up it shows a menu: the programs built into ROM (monitor, BASIC,
file browser, demos), and "boot from SD", which loads a named file (for
example `BOOT.PLC`) into RAM and runs it.  Remember the last choice in a
setting on the card, and hold a key (or a pad button) at power-up to get the
menu back.

### File browser

Lists the SD card's directories with the cursor keys or the pad, and acts
on the selected file by its extension: run a program (load into RAM and
jump), open a text file in a viewer, load a BASIC program into BASIC, start
an emulator with a ROM or disk image, or show an image file on screen.
Later: copy, rename and delete once FAT write works.

### BASIC interpreter

A 16-bit integer BASIC in the style of Tiny BASIC or Apple Integer BASIC:
line-numbered programs, `PRINT`, `INPUT`, `IF`, `GOTO`, `GOSUB`, `FOR`, one
array, `PEEK`/`POKE`, `CALL`, and `LOAD`/`SAVE` to the SD card.  Placard
extras: `PLOT`, `LINE`, `MODE` (per-row color mode), `PAD` (read a pad) and
`SOUND` (write to the audio buffer).  An interpreter of this size usually
fits in 4-8 KB, so it fits the free ROM.  Floating point can come later.

### Emulators

Placard runs roughly 7 million native instructions per second, and an
emulated instruction typically costs tens of native ones, so an emulated
CPU runs at roughly a few hundred thousand instructions per second (an
estimate, to check with a prototype).  In order of fit:

| Target | Why it fits | Memory needed | Notes |
|---|---|---|---|
| CHIP-8 | Tiny virtual machine made for hobby games; 35 opcodes, 64 x 32 display, 16-key pad, 60 Hz timers | 4 KB | Best first emulator.  Timers from the line read, beep from the audio buffer, keys from the keyboard or the SNES pad.  Many free games exist. |
| Apple 1 (6502) | Simple text terminal, keyboard in, 40 x 24 text out | 4-8 KB | Needs a 6502 core.  The Woz Monitor is tiny; check the license of any ROM before shipping it. |
| CP/M 2.2 (8080) | A real OS with a large library of software (editors, assemblers, compilers, games) on disk images | 20 KB minimum system, ideally much more | The most useful, and the hardest: 8080 core, BIOS for console and disk images on the SD card, and memory spread over the free RAM pieces (or 4x-repeat video RAM).  Expect it to run below a real 2 MHz 8080.  Digital Research's CP/M was released for free use; confirm the terms. |

A native OS of our own (a small DOS with a command line, file commands and
program loading) is the alternative to CP/M.  Most of it is the boot menu,
file browser and monitor joined behind one command line.

### Software order

1. Keyboard and SD drivers, raw sectors.
2. Monitor.
3. FAT read, file browser, boot menu.
4. BASIC.
5. CHIP-8, then a 6502 or 8080 emulator.

## Suggested order (hardware)

1. Shared port with the SNES pads (the easiest way to test it).
2. Keyboard on the shared port.
3. SD card on the shared port.
4. Expansion connectors (the interface is fixed by the I/O decode).
5. Mouse (SNES: software only, once the pad port works; PS/2: as an
   expansion card).

For the FPGA model, each step adds its PLD as a VHDL entity (no optimization,
individual pins, lowerCamelCase signals) and a branch on the read mux in
`basys_top.vhd`.  `placard_sim.py` gets a matching I/O hook.

## Cut for now (can be added later)

| Feature | Cost to add back |
|---|---|
| Hardware frame counter | 1 x 22V10 |
| Hardware SPI byte shifter (faster SD) | 74HC595, 74HC165, 22V10 |
| Buffered expansion ports | 74F245 + 74F541 per port (stock not checked) |

## Risks and open questions

- **Timing.**  One clock for reads and a 20 ns write pulse is tight.  The plan
  uses 74F where it is in stock; recheck read timing with 74F delays.
- **Polling once per frame** is a rule all software must follow if it keeps
  time from the line read.
- **Mouse type:** SNES mouse (no chips, uses a pad port) or PS/2 (about 2
  chips on an expansion card)?
- **Keyboard layout:** 65 keys (13 x 5) with no added chips.  Which 2 of the
  65 positions stay unused, or become extra keys, is a layout choice.
