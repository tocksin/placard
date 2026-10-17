# Feature plan: I/O (bare bones)

This is a planning list, not a design.  Nothing here is implemented yet.  It
covers the I/O the Placard still needs: keyboard, SNES controllers, SD card
storage and four expansion ports.  Sound is built (line-rate 8-bit DAC, see
SOUND.md) and is no longer on this list.

The goal is the **fewest added chips**, even at the cost of features.
Software does whatever hardware can be left out.  Things that were cut are
listed at the end in case they are wanted later.

## Starting point

These facts from the current design shape every choice below.

- **The I/O decode is built** (removed from this list).
  `ATF22V10_IO_DECODE.pld` (rev 01, also `io_decode_pld.vhd`, wired into
  `basys_top.vhd`) decodes x5000-x53FF (rev 03, 2026-10-16) and gives each
  device its own strobe: /MAP_WR and /LINE_RD (x50), /EXP1 (x51, address
  only), /PORT_WR and /PORT_RD (x52), /EXP2 (x53, address only).  Write
  strobes are low for the /WE pulse; read strobes are qualified by LOAD_IMM.
  The PLD has no spare pins: the old /SND_WR pin is now the A11 input.
  (Before rev 03 the window was x5000-x5FFF with A11 not decoded, and the
  expansion ports were at x55 and x56.)
  `ATF22V10_MEM_CTRL.pld` (rev 05) keeps both memories off the bus there,
  and map bit 2 covers x4000-x4FFF and x5400-x5FFF.  The ROM/RAM map write at x5000 works.
  The map is a write-only 74ACT273 (CD74ACT273E) clocked by /MAP_WR, in place
  of the ROM/RAM select PLD, so the base chip count did not change; its /MR
  comes from MEM_CTRL's MAP_RUN (pin 17), which clears it to all ROM until
  the first clock after power-up.
- **The video line read is built** (removed from this list).  A 74F541
  enabled by /LINE_RD puts V9:V2 on the data bus for a read at x5000; see
  README.md, "Video line read".  It is wired in `basys_top.vhd`.
- **Only `[Y,X]` reaches I/O.**  `[0,D]` and `[0,X]` only address the zero
  page, so every I/O access is `ld 0x5n, y` then `ld [y,x], ac` (read) or
  `ld ac, [y,x]` / `ld n, [y,x]` (write).
- **There are no interrupts.**  All I/O is polled.
- **There are no wait states.**  Every device must answer a read within one
  CPU clock (about 40 ns at 25 MHz) and take a write pulse of about 20 ns.
  The MEM_CTRL PLD makes /WE (low only in the low half of a CPU write clock),
  and I/O writes use the same pulse.  Memory reads also use only the low half
  of the clock now; the I/O read strobes are qualified by LOAD_IMM, not the
  clock, which is worth checking against that rule when the first read
  device is designed.  Devices
  that drive the read bus must enable in 9.5 ns or less (see TIMING_FIXES.md).
- **The CPU's speed is not a clock.**  Video reads stall the CPU on one clock
  in eight during visible lines and never during blanking, so time has to
  come from the video counters.
- **Free PLD pins** that a feature could use instead of adding a chip:
  MEM_CTRL PLD pins 20-22.  (The 74F32 that made /WE is gone; MEM_CTRL replaced it, so the
  base chip count did not change.)
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
- **No mux is needed any more.**  The SD card's 3.3 V MISO goes straight into
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
- **No separate selects for ports 3 and 4.**  The old idea of turning the
  unused /SND_WR output into /EXP3 is gone: that pin is the A11 input since
  I/O decode rev 03 (2026-10-16).

## Suggested order

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
| Full 10-bit line read | a second 74F541 (or two 74F574 to snapshot it) |
| Hardware frame counter | 1 x 22V10 |
| Hardware SPI byte shifter (faster SD) | 74HC595, 74HC165, 22V10 |
| Buffered expansion ports | 74F245 + 74F541 per port (stock not checked) |
| ROM/RAM map read-back | 1 x 74F541 |

## Risks and open questions

- **Timing.**  One clock for reads and a 20 ns write pulse is tight.  The plan
  uses 74F where it is in stock; recheck read timing with 74F delays.
- **Polling once per frame** is a rule all software must follow if it keeps
  time from the line read.
- **Mouse type:** SNES mouse (no chips, uses a pad port) or PS/2 (about 2
  chips on an expansion card)?
- **Keyboard layout:** 65 keys (13 x 5) with no added chips.  Which 2 of the
  65 positions stay unused, or become extra keys, is a layout choice.
