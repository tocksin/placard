# Feature plan: I/O (bare bones)

This is a planning list, not a design.  Nothing here is implemented yet.  It
covers the I/O the Placard still needs: video line position, sound, keyboard,
SNES controllers, SD card storage and two expansion ports.

The goal is the **fewest added chips**, even at the cost of features.
Software does whatever hardware can be left out.  Things that were cut are
listed at the end in case they are wanted later.

## Starting point

These facts from the current design shape every choice below.

- **The I/O decode is built** (removed from this list).
  `ATF22V10_IO_DECODE.pld` (rev 01, also `io_decode_pld.vhd`, wired into
  `basys_top.vhd`) decodes x5000-x5FFF and gives each device its own strobe:
  /MAP_WR and /LINE_RD (x50), /SND_WR (x51), /PORT_WR and /PORT_RD (x52),
  /EXP1 and /EXP2 (x55, x56, address only).  Write strobes are low for the
  /WE pulse; read strobes are qualified by LOAD_IMM.  A11 is not decoded, so
  x5800-x5FFF repeats x5000-x57FF, and the PLD has no spare outputs.
  `ATF22V10_ROMRAM_SEL.pld` (rev 03) keeps both memories off the bus there,
  and x4000-x4FFF is always RAM.  The ROM/RAM map write at x5000 works.
- **Only `[Y,X]` reaches I/O.**  `[0,D]` and `[0,X]` only address the zero
  page, so every I/O access is `ld 0x5n, y` then `ld [y,x], ac` (read) or
  `ld ac, [y,x]` / `ld n, [y,x]` (write).
- **There are no interrupts.**  All I/O is polled.
- **There are no wait states.**  Every device must answer a read within one
  CPU clock (about 40 ns at 25 MHz) and take a write pulse of about 20 ns.
  RAM writes use `/WE = RW | CLK`; I/O writes use the same pulse.  Devices
  that drive the read bus must enable in 9.5 ns or less (see TIMING_FIXES.md).
- **The CPU's speed is not a clock.**  Video reads stall the CPU on one clock
  in eight during visible lines and never during blanking, so time has to
  come from the video counters.
- **Device latches take data from the source bus**, not the RAM-side data
  bus, and latch on the rising edge of their write strobe.  The source bus
  holds the data past the end of the write; the RAM-side bus does not.

## Chip count

| Feature | Added chips |
|---|---|
| Video line read | 1 x 74F541 |
| Shared port: keyboard (40 keys), 2 SNES pads, SD card | 74HC574, 74F138, 74F541, CD4050, plus a 3.3 V regulator |
| Sound (one voice) | 74F574, 1 x ATF22V10C |
| Expansion ports (2) | none, connectors only |
| **Total** | **7 logic chips + 1 regulator** |

## Parts rule and stock check

Only DIP parts with active stock at Digikey or Mouser, and 74F where it is in
stock, for the better timing.  Checked 2026-10-15 (stock moves, so recheck
before ordering):

| Part | DIP part number | Status |
|---|---|---|
| 74F541 | SN74F541N (TI) | Mouser: 723 in stock |
| 74F574 | SN74F574N (TI) | Mouser: 466 in stock |
| 74F138 | SN74F138N (TI) | Listed at Digikey and Mouser as 16-PDIP; stock count not confirmed |
| CD4050 | CD4050BE (TI) | Mouser: 10,831 in stock |
| ATF22V10C | already used in the design | n/a |

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

## 1. Video line read (x50, one 74F541)

| Address | R/W | Function |
|---|---|---|
| x5000 | W | ROM/RAM section map: /MAP_WR drives WR_CLK of the ROM/RAM select PLD, which latches the source bus.  Bit n = 1 makes section n RAM; bit 2 is ignored (x4000-x4FFF is always RAM).  Already built. |
| x5000 | R | Upper 8 bits of the line counter, V9:V2 |

- The V counter already exists in the V Counter PLD (it counts 499 to 1023).
  One 74F541 enabled by /LINE_RD puts V9:V2 on the data bus.  It is a
  single byte, so it can't tear between reads.
- **Resolution is 4 lines** (128 us).  Visible rows start at V = 544, so
  `row / 4 = value - 136`.  A value below 136 means vertical blanking.
- **No frame counter.**  Software keeps time by polling: each time the value
  goes down (from 255 back to 124), a frame has passed.  At the FPGA's
  25.000 MHz clock a frame is 525 lines, about 16.8 ms (59.5 Hz).
- **Software must poll at least once per frame**, or it misses a wrap.  Elapsed
  time is then frames x 16.8 ms plus the line position for finer detail.

## 2. Shared port: keyboard, SNES pads and SD card (x52)

The keyboard, the pads and the SD card are never needed at the same moment,
so software takes turns: scan the keyboard, then read the pads, and talk to
the SD card only when loading or saving.  They share one output latch and one
input buffer.  Everything is bit-banged; there is no hardware shifter.

| Address | R/W | Function |
|---|---|---|
| x5200 | W | Output latch (74HC574): bit 0 SCK / pad CLOCK, bit 1 SD MOSI, bit 2 SD /CS, bit 3 pad LATCH, bits 4-7 spare |
| x5200 + n | R | 74F541: bits 4:0 keyboard rows of column n (0 = pressed), bit 5 pad 2 DATA, bit 6 pad 1 DATA, bit 7 SD MISO |

**Keyboard: 8 columns x 5 rows = 40 keys** (the same size as the ZX
Spectrum's).  /PORT_RD enables a 74F138 that drives column A2:A0 low for the
length of the read, and the same strobe enables the 74F541 that reads the
rows (with pull-ups and a diode per key).  One read per column, so a full
scan is 8 reads.  Debounce, shift, rollover and repeat are in software, once
per frame using the line read.  Only 5 of the buffer's 8 bits are rows,
because the other 3 carry the serial inputs.

**Serial inputs ride along on every read.**  Bits 7:5 show MISO and both pad
data lines no matter which column is addressed, so the serial code can read
any address in the page.  MISO is on D7 so that loading it into AC sets the
negative flag and `blt` / `bge` can test it directly.  The buffer's inputs
are TTL level, so the card's 3.3 V MISO needs no level shifting coming back.

**One clock line for both pads and the SD card.**  The SD card ignores SCK
while its /CS is high, and the pads' extra shifting during an SD transfer
does no harm because software pulses LATCH before every pad read.  Only the
software's idle level differs (the pads idle with CLOCK high, SPI mode 0
idles low), which costs nothing in bit-bang.

**SNES pads:** pulse LATCH, then read DATA and pulse CLOCK 16 times.  The
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
changes one bit at a time from that copy.  Its 4 spare bits can be a one-bit
beeper (see Sound) or selects for more SPI devices.  The latch stays 74HC
because the pads' CMOS inputs need a full 5 V high.

**Timing to check:** a read goes /PORT_RD, 74F138, column wire, key diode,
row, 74F541, data bus inside one clock.  The 74F parts keep that short, but
the diode and the row's pull-up are the slow part of the path.

## 3. Sound (x51, 74F574 + ATF22V10C)

One square-wave voice that runs on its own once software sets the pitch.

| Address | R/W | Function |
|---|---|---|
| x5100 | W | Pitch P (0 = silent) |

- The 74F574 holds P (it only drives the 22V10's TTL-level inputs).  The
  22V10 is clocked by HSYNC (the line rate,
  31.25 kHz at 25.000 MHz, no prescaler needed) and counts from P up to
  255, reloads, and toggles its output.  That uses 9 of its 10 macrocells.
- Frequency = 31250 / (2 x (256 - P)), so about 61 Hz (P = 1) up to 15.6 kHz
  (P = 255).  High notes are coarse; the middle and low range is fine for
  tunes and effects.
- The output drives a line-out jack through a resistor and capacitor, or a
  small speaker through a transistor.  There is no volume control apart from
  a trimmer.
- **Zero-chip fallback:** a spare bit in the shared port's latch as a one-bit beeper that
  software toggles.  The pitch is only as steady as the software loop.

## 4. Expansion ports (x55, x56, connectors only)

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

## Suggested order

1. Line read.
2. Shared port with the SNES pads (the easiest way to test it).
3. Keyboard on the shared port.
4. SD card on the shared port.
5. Sound.
6. Expansion connectors (the interface is fixed by the I/O decode).

For the FPGA model, each step adds its PLD as a VHDL entity (no optimization,
individual pins, lowerCamelCase signals) and a branch on the read mux in
`basys_top.vhd`.  `placard_sim.py` gets a matching I/O hook.

## Other future tasks

### Gold instead of orange in 4-color mode

The 2 bpp (4-color) palette in `ATF22V10_COLORDECODER.pld` is black, blue,
orange (R 7, G 3, B 0) and white.  Change code 10 to gold.

- **Candidate gold: R 7, G 5, B 0.**  It fits the existing per-bit form by
  swapping two green bits.  Today `GRN2 = C1` and `GRN3 = C1 & C0`; for gold,
  `GRN2 = C1 & C0` and `GRN3 = C1`.  Blue stays G 1 and white stays G 7.  In
  the full equations the 2 bpp term of each pin just gains or loses C0, so
  the product-term counts do not change (GRN3 also carries the 1 bpp pixel
  mux, so that matters).  Red and blue are unchanged.
- Gold is brighter than orange, so it is closer to white; check that the two
  are still easy to tell apart on screen.
- Update the palette comment in the PLD, `color_decoder.vhd`, COLORS.md and
  `reference/Palette.png` to match.

## Cut for now (can be added later)

| Feature | Cost to add back |
|---|---|
| Full 10-bit line read | a second 74F541 (or two 74F574 to snapshot it) |
| Hardware frame counter | 1 x 22V10 |
| Hardware SPI byte shifter (faster SD) | 74HC595, 74HC165, 22V10 |
| More sound voices, noise, volume | about 2 chips per voice |
| Buffered expansion ports | 74F245 + 74F541 per port (stock not checked) |
| ROM/RAM map read-back | 1 x 74F541 |

## Risks and open questions

- **Timing.**  One clock for reads and a 20 ns write pulse is tight.  The plan
  uses 74F where it is in stock; recheck read timing with 74F delays.
- **Polling once per frame** is a rule all software must follow if it keeps
  time from the line read.
- **Keyboard size:** 40 keys fits the shared buffer.  64 keys would need a
  second 74F541 for the serial inputs (one more chip).
