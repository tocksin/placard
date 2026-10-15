# Feature plan: I/O (bare bones)

This is a planning list, not a design.  Nothing here is implemented yet.  It
covers the I/O the Placard still needs: video line position, sound, keyboard,
SNES controllers, SD card storage and two expansion ports.

The goal is the **fewest added chips**, even at the cost of features.
Software does whatever hardware can be left out.  Things that were cut are
listed at the end in case they are wanted later.

## Starting point

These facts from the current design shape every choice below.

- **The I/O window is already reserved.**  The README memory map puts I/O at
  x5000-x5FFF, one 256-byte page per device, with priority over RAM/ROM.
  Nothing decodes it yet: the ROM/RAM map register in `ATF22V10_ROMRAM_SEL.pld`
  needs "a decoded I/O write strobe" on WR_CLK, and in `basys_top.vhd` that
  input is tied to a constant.
- **Only `[Y,X]` reaches I/O.**  `[0,D]` and `[0,X]` only address the zero
  page, so every I/O access is `ld 0x5n, y` then `ld [y,x], ac` (read) or
  `ld ac, [y,x]` / `ld n, [y,x]` (write).
- **There are no interrupts.**  All I/O is polled.
- **There are no wait states.**  Every device must answer a read within one
  CPU clock (about 40 ns at 25 MHz) and take a write pulse of about 20 ns.
  RAM writes use `/WE = RW | CLK`; I/O writes use the same pulse and latch on
  its rising edge.
- **The CPU's speed is not a clock.**  Video reads stall the CPU on one clock
  in eight during visible lines and never during blanking, so time has to
  come from the video counters.
- **The ROM/RAM select PLD is full** (every pin used), so the "I/O has
  priority" rule has to go outside it.

## Chip count

| Feature | Added chips |
|---|---|
| I/O decode | 1 x ATF22V10C |
| Video line read | 1 x 74F541 |
| Serial port (SD card + 2 SNES pads) | 74HC574, 74HCT251, CD4050, plus a 3.3 V regulator |
| Keyboard (64 keys) | 74F138, 74F541 |
| Sound (one voice) | 74F574, 1 x ATF22V10C |
| Expansion ports (2) | none, connectors only |
| **Total** | **10 logic chips + 1 regulator** |

The RAM/ROM read gating uses two of the three spare OR gates in the existing
74HC32 that makes /WE, so it adds nothing.

## Parts rule and stock check

Only DIP parts with active stock at Digikey or Mouser, and 74F where it is in
stock, for the better timing.  Checked 2026-10-15 (stock moves, so recheck
before ordering):

| Part | DIP part number | Status |
|---|---|---|
| 74F541 | SN74F541N (TI) | Mouser: 723 in stock |
| 74F574 | SN74F574N (TI) | Mouser: 466 in stock |
| 74F138 | SN74F138N (TI) | Listed at Digikey and Mouser as 16-PDIP; stock count not confirmed |
| 74F251 | SN74F251BN (TI) | TI lists it active but out of stock; Digikey/Mouser stock not confirmed.  Use the HCT part below unless it shows up in stock. |
| 74HCT251 | CD74HCT251E (TI) | Mouser: 1,059 in stock |
| CD4050 | CD4050BE (TI) | Mouser: 10,831 in stock |
| ATF22V10C | already used in the design | n/a |

**Where 74F is not used, and why:**

- **Serial output latch stays 74HC574.**  74F outputs only guarantee about
  2.7 V for a high, and the SNES pad's CMOS 4021s need 3.5 V at 5 V.  The HC
  latch swings rail to rail.
- **Serial mux is 74HCT251**, not HC: the SD card's 3.3 V MISO needs a
  TTL-level input.  A 74F251 would also take 3.3 V, if it comes back into
  stock.
- **CD4050** has no 74F equivalent: it runs from 3.3 V to shift the SD lines
  down, which a 5 V-only family can't do.

**74F caveat on the data bus:** the 74F541s drive the CPU's read bus.  That
is fine for TTL-level inputs (the ATF22V10C and typical SRAM), but if any
register that latches the read bus is a plain 74HC part, its 3.5 V input
threshold is above the 74F's guaranteed high.  Use HCT (or F) on those
inputs, or keep HC541s on the bus.

## 1. I/O decode (one ATF22V10C)

Instead of one chip select plus shared read and write strobes (which would
need an OR gate per device), the PLD puts out the exact strobe each device
needs.  That way no device needs glue logic.

| Pin use | Signals |
|---|---|
| Inputs (11) | A15, A14, A13, A12, A11, A10, A9, A8, RW, CLK, LOAD_IMM (D register strobe from the State PLD) |
| Outputs (10) | IO_SEL, /MAP_WR, /LINE_RD, /SND_WR, /KEY_RD, /SER_WR, /SER_RD, /EXP1, /EXP2, one spare |

Proposed equations (written out in full in the PLD when it is designed):

    IO      = !A15 & A14 & !A13 & A12                 /* x5000-x5FFF        */
    RD      = IO & RW & LOAD_IMM                      /* CPU is latching D  */
    WR      = IO & !RW & !CLK                         /* same pulse as /WE  */

    IO_SEL  = IO                                      /* blocks RAM/ROM     */
    MAP_WR  = WR & page 0     LINE_RD = RD & page 0   /* x50                */
    SND_WR  = WR & page 1                             /* x51                */
    KEY_RD  = RD & page 2                             /* x52                */
    SER_WR  = WR & page 4     SER_RD  = RD & page 4   /* x54                */
    EXP1    = IO & page 5     EXP2    = IO & page 6   /* x55, x56           */

- **RAM/ROM priority.**  Spare 74HC32 gates make `/ROM_OE = /ROM_EN | IO_SEL`
  and `/RAM_OE = !RW | IO_SEL`.  Writes to x5000-x5FFF also land in the RAM
  underneath, which is harmless.
- **Reads are qualified by LOAD_IMM**, which already includes !PIXEL_ENABLE,
  so a device only sees the real CPU read.
- **x5300 is spare** (the controllers moved to the serial port), and so is
  the tenth output.
- **Expansion selects are address-only.**  The two ports also get RW, CLK and
  LOAD_IMM so a card builds its own read and write strobes.  That keeps the
  decode PLD to 10 outputs.

## 2. Video line read (x50, one 74F541)

| Address | R/W | Function |
|---|---|---|
| x5000 | W | ROM/RAM section map: /MAP_WR drives WR_CLK of the ROM/RAM select PLD.  Bit n = 1 makes section n RAM.  No added chip. |
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

## 3. Serial port: SD card and SNES pads (x54)

Bit-banged.  Software drives the clock and data lines one bit at a time.
There is no hardware shifter.

| Address | R/W | Function |
|---|---|---|
| x5400 | W | Output latch (74HC574): bit 0 SD SCK, bit 1 SD MOSI, bit 2 SD /CS, bit 3 pad CLOCK, bit 4 pad LATCH, bits 5-7 spare |
| x5400 + n | R | Input n on D7 through a 74HCT251 (8-to-1 mux, tri-state): 0 SD MISO, 1 pad 1 DATA, 2 pad 2 DATA, 3-7 spare |

- **The mux picks the input from the address**, A2:A0, so there is no select
  register, and the pad's data line, which is never tri-stated, is never
  shared.
- **The bit lands on D7** so that loading it into AC sets the negative flag,
  and `blt` / `bge` can test it directly.
- **The latch is write-only**, so software keeps a copy of it in zero page and
  changes one bit at a time from that copy.
- **SNES pad:** pulse LATCH, then read DATA and pulse CLOCK 16 times.  The
  first bit (B) is ready right after LATCH.  The bits are B, Y, Select, Start,
  Up, Down, Left, Right, A, X, L, R, then four 1s, with 0 meaning pressed.
  Both pads share LATCH and CLOCK, so one pass reads both.  The pads run at
  5 V and need no level shifting.
- **SD card:** SPI mode 0 in software.  SCK, MOSI and /CS go through a CD4050
  powered from 3.3 V.  MISO comes back directly, which needs the HCT version
  of the mux (74HCT251): plain HC wants 3.5 V for a high, and the card only
  gives 3.3 V.  The CD74HCT251E is in stock in DIP.  A 3.3 V
  regulator powers the card.  Software runs at roughly 10 instructions per bit
  (an estimate), so tens of KB/s, which is fine for loading and saving
  programs.
- **Software:** raw sectors first (a fixed sector range per saved program),
  FAT later if cards need to be filled from a PC.
- **Spare bits** (3 outputs, 5 inputs) can carry a third SPI device, an SD
  card-detect switch or a one-bit beeper (see Sound).

## 4. Keyboard (x52, 74F138 + 74F541)

A built-in 8 x 8 matrix (64 keys) with a diode per key, scanned by software.

| Address | R/W | Function |
|---|---|---|
| x5200 + n | R | Rows of column n (0-7), 0 = pressed |

- /KEY_RD enables a 74F138 that drives column A2:A0 low, and the same strobe
  enables a 74F541 that reads the 8 rows (with pull-ups).  One read per
  column.
- Debounce, shift, rollover and repeat are all in software, run once per
  frame using the line read.

## 5. Sound (x51, 74F574 + ATF22V10C)

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
- **Zero-chip fallback:** a spare serial latch bit as a one-bit beeper that
  software toggles.  The pitch is only as steady as the software loop.

## 6. Expansion ports (x55, x56, connectors only)

| Signal | Meaning |
|---|---|
| D7:D0 | RAM-side data bus |
| A7:A0 | Register select inside the port's page |
| /EXPn | Port select (address only) |
| RW, CLK, LOAD_IMM | So a card can build its own read and write strobes: read = /EXPn low, RW high and LOAD_IMM high; write = /EXPn low, RW low and CLK low |
| RESET, +5 V, GND | Several grounds between the fast signals |

- **Unbuffered.**  Keep the cable short (or use a direct board-edge
  connector) and keep the card's load light: one or two HC/AC inputs per
  line.
- A 2 x 20 box header fits all of it.

## Suggested order

1. I/O decode PLD, ROM/RAM map write and line read.
2. Serial port with the SNES pads (the easiest way to test it).
3. SD card on the serial port.
4. Keyboard.
5. Sound.
6. Expansion connectors (the interface is fixed by step 1).

For the FPGA model, each step adds its PLD as a VHDL entity (no optimization,
individual pins, lowerCamelCase signals) and a branch on the read mux in
`basys_top.vhd`.  `placard_sim.py` gets a matching I/O hook.

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
- **Keyboard size:** 64 keys (default) or a larger matrix (needs a second
  decoder)?
