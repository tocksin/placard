# VGA Timing Generator

## Overview

The VGA timing generator uses three ATF22V10C PLDs to generate the timing
signals for a 640×480 @ 60 Hz VGA display.

The three PLDs are:

1. **H Counter PLD** — generates the upper seven horizontal count bits and
   horizontal timing signals.
2. **V Counter PLD** — generates the ten vertical count bits, advancing
   once per line on the H counter's line-end signal (H_TC).
3. **Sync / Pixel Counter PLD** — generates the lower three horizontal count
   bits, VGA vertical sync, the color decoder's video enable (VIDEN), the
   video read (PIXEL_ENABLE) and, since revision 10, the RAM write strobe
   /WE (the address-mux selects went to the mux PLDs on 2026-10-27,
   FETCH_TIMING.md).

## Horizontal Counter (total)
The horizontal counter is a 10-bit counter but divided between two chips:

```text
| H9 H8 H7 H6 H5 H4 H3 | H2 H1 H0            |
|----------------------|---------------------|
|      7-bit counter   | 3-bit pixel counter |
```

Together these form the complete 10-bit horizontal count.  

H9:H0 = 0..1023

For the horizontal VGA timing, it must count 800 times and then repeat.  For 
this implementation, it counts from 224 → 1023 pixels.

The three low bits identify the individual pixel within an 8-pixel byte,
while the upper seven bits identify the byte position within a scan line.

## Horizontal Counter PLD

### Function
The Horizontal Counter PLD (`ATF22V10_HCOUNT.pld`, revision 08) contains the
upper seven bits of the horizontal counter.  The low three bits, H2:H0, are
in the Sync PLD.

It counts horizontal byte positions (8-clock groups) from:

28 → 127

corresponding to:

224 → 1023 pixels

The counter reloads to 28 after reaching 127.  H9:H3 advance on the last
clock of each group (H2:H0 = 101, since H2:H0 runs two clocks behind the
group; see VIDEO_TIMING.md).

The PLD also generates:

- Horizontal sync (HSYNC, active low)
- Horizontal video-active state (H_VIDEO_ACTIVE)
- Line terminal count (H_TC), the vertical counter's clock enable

The horizontal video-active signal is high when the counter is in a range where
there is active video.  It is sent to the Sync PLD and combined with the
vertical counter to determine the full video active region.  On a line whose
mode byte has bit 7 set it is only a one-clock pulse (revision 08, see
[Blank line](#blank-line)).

(An earlier version also had a first-active-pixel signal to capture the
display mode.  The mode byte is now read in horizontal blanking; see
[Mode byte](#mode-byte).)

### Horizontal Timing
| Pixel range | Function |
|-------------|----------| 
| 224-239 | Front Porch |
| 240-335 | HSYNC |
| 336-383 | Back Porch |
| 384-1023 | Active Video |

### Pinout

| Pin | Signal | Direction | Function |
|---:|---|---|---|
| 1 | `CLK` | Input | Pixel clock |
| 2 | `RESET` | Input | Declared but not used in any equation (tie low) |
| 3 | `H0` | Input | Horizontal pixel bit 0 (Sync PLD pin 14) |
| 4 | `H1` | Input | Horizontal pixel bit 1 (Sync PLD pin 15) |
| 5 | `H2` | Input | Horizontal pixel bit 2 (Sync PLD pin 16) |
| 6 | `LC7` | Input | Line code register Q7 (mode byte bit 7, blank line) |
| 7 | — | — | Unused |
| 8 | — | — | Unused |
| 9 | — | — | Unused |
| 10 | — | — | Unused |
| 11 | — | — | Unused |
| 12 | `GND` | Power | Ground |
| 13 | — | — | Unused |
| 14 | `H3` | Output | Horizontal count bit 3 |
| 15 | `H4` | Output | Horizontal count bit 4 |
| 16 | `H5` | Output | Horizontal count bit 5 |
| 17 | `H6` | Output | Horizontal count bit 6 |
| 18 | `H7` | Output | Horizontal count bit 7 |
| 19 | `H8` | Output | Horizontal count bit 8 |
| 20 | `H9` | Output | Horizontal count bit 9 (MSB) |
| 21 | `/HSYNC` | Output | Horizontal sync, active low (registered); to VGA pin 13 through R61 (47 ohm) |
| 22 | `H_VIDEO_ACTIVE` | Output | Horizontal active-video state (registered) |
| 23 | `H_TC` | Output | Last clock of the line (H = 127, H2:H0 = 101); V counter EN |
| 24 | `VCC` | Power | +5 V |

- H9:H3 = Upper 7 bits of horizontal count (registered)
- H2:H0 = Supplied by the Sync PLD
- All ten output cells are used; inputs 2, 7-11 and 13 are free.

## Vertical Counter PLD

### Function
The Vertical Counter PLD (`ATF22V10_VCOUNT.pld`, revision 03) generates the
ten-bit vertical count.

Its only inputs are the clock and EN, a clock enable driven by the H
counter PLD's H_TC, which is high on the last clock of each line.  The
counter advances once per line.

The vertical counter counts:

499 → 1023

and reloads to 499 after 1023.  An all-zero count (power-up) also loads
499.  The global reset and preset terms are not used.

There is no vertical decoding of the timing in this PLD because every
output is a counter bit.  All decoding is done in the Sync PLD and the
audio slot PLD.

### Pinout
| Pin | Signal | Direction | Function |
|---:|---|---|---|
| 1 | `CLK` | Input | Pixel clock |
| 2 | `EN` | Input | Count enable, from H counter PLD pin 23 (H_TC) |
| 3-11 | — | — | Unused |
| 12 | `GND` | Power | Ground |
| 13 | — | — | Unused |
| 14 | `V0` | Output | Vertical count bit 0 |
| 15 | `V3` | Output | Vertical count bit 3 |
| 16 | `V4` | Output | Vertical count bit 4 |
| 17 | `V7` | Output | Vertical count bit 7 |
| 18 | `V8` | Output | Vertical count bit 8 |
| 19 | `V9` | Output | Vertical count bit 9 (MSB) |
| 20 | `V6` | Output | Vertical count bit 6 |
| 21 | `V5` | Output | Vertical count bit 5 |
| 22 | `V2` | Output | Vertical count bit 2 |
| 23 | `V1` | Output | Vertical count bit 1 |
| 24 | `VCC` | Power | +5 V |

The bits are placed by product terms (higher bits need more), so they are
not in pin order.  The source names them Q9:Q0.

## Sync Decoder / Pixel counter PLD

### Function
The Sync Decoder / Pixel Counter PLD (`ATF22V10_SYNC.pld`, revision 09)
contains the three lowest horizontal count bits.  These bits select the
individual pixel within an 8-pixel video byte, and go straight to the color
decoder.  They run two clocks behind the H counter's group: H2:H0 is 110 in
clock 0 of a group, 111 in clock 1 (the video read) and 000 in clock 2,
where the first pixel of the byte is shown (VIDEO_TIMING.md).

It also generates:

- VSYNC
- VIDEN, the color decoder's video enable (registered)
- PIXEL_ENABLE, the video read (registered)
- The RAM write strobe /WE, from the early clock tap CLK_E (revision 10;
  the address-mux selects ADDR_SEL, ADDR_SEL_HI and ADDR_SEL_LO before)
- V_VIDEO_ACTIVE, the vertical active-region state

### Vertical Timing
| Line range | Function |
|-------------|----------|
| 499-531 | Front Porch |
| 532-533 | VSYNC |
| 534-543 | Back Porch |
| 544-1023 | Active Video |

PIXEL_ENABLE is high in clock 1 of each group (H2:H0 = 111) when a byte is
read: on active-video lines during active video, and on every line in the
group that the audio slot PLD marks with BLANK_RD (the mode byte and audio
reads).  It also stalls the CPU so that it does not use the RAM/ROM during
video reads.

### Pinout

| Pin | Signal | Direction | Function |
|---:|---|---|---|
| 1 | `CLK` | Input | Pixel clock |
| 2 | `V9` | Input | Vertical count bit 9 |
| 3 | `V5` | Input | Vertical count bit 5 |
| 4 | `V4` | Input | Vertical count bit 4 |
| 5 | `V3` | Input | Vertical count bit 3 |
| 6 | `V2` | Input | Vertical count bit 2 |
| 7 | `V1` | Input | Vertical count bit 1 |
| 8 | `H_VIDEO_ACTIVE` | Input | Horizontal active-video state (H counter PLD pin 22) |
| 9 | `CLK_E` | Input | Early clock tap: X1 before the 500 mm of track to every other chip (revision 10; was PC_ENABLE) |
| 10 | `RW` | Input | State PLD pin 23, 0 = store (revision 10; was Y_ENABLE) |
| 11 | `RUN` | Input | From the cartridge (revision 10; was X_ENABLE) |
| 12 | `GND` | Power | Ground |
| 13 | `BLANK_RD` | Input | Mode byte / audio read slot (audio slot PLD pin 23) |
| 14 | `H0` | Output | Horizontal pixel bit 0 (registered) |
| 15 | `H1` | Output | Horizontal pixel bit 1 (registered) |
| 16 | `H2` | Output | Horizontal pixel bit 2 (registered) |
| 17 | `VIDEN` | Output | Color decoder video enable: active video, two clocks late (registered) |
| 18 | `/VSYNC` | Output | Vertical sync, active low; to VGA pin 14 through R62 (47 ohm) |
| 19 | `PIXEL_ENABLE` | Output | Video read, clock 1 of each group (registered) |
| 20 | `/WE` | Output | RAM write strobe, low in the low half of a store clock; floats while RUN is low (revision 10; was ADDR_SEL) |
| 21 | — | Free | Was ADDR_SEL_HI (revision 10) |
| 22 | — | Free | Was ADDR_SEL_LO (revision 10) |
| 23 | `V_VIDEO_ACTIVE` | Output | Vertical active region, counts 544-1023 (registered) |
| 24 | `VCC` | Power | +5 V |

Pins 21 and 22 are free.  V0 and V8:V6 are not needed: each vertical decode
covers two counts at once.

```text
H0.D = !H0;
H1.D = H1 $ H0;
H2.D = H2 $ (H1 & H0);

V_VIDEO_ACTIVE.D = V9 & (V5 # V_VIDEO_ACTIVE);

VIDEN.D = V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & H2 & H1 & H0
        # VIDEN & !(H2 & H1 & H0);              /* holds between reads */

PIXEL_ENABLE.D = (V_VIDEO_ACTIVE & H_VIDEO_ACTIVE # BLANK_RD) & H2 & H1 & !H0;

VSYNC = V9 & !V_VIDEO_ACTIVE & V4 & !V3 & V2 & !V1;      /* counts 532-533; pin declared !VSYNC */

WE = !CLK_E & !RW & !PIXEL_ENABLE;      /* pin declared !WE; WE.OE = RUN */
```

Until revision 09 the PLD also decoded the address-mux selects
(`ADDR_SEL = PIXEL_ENABLE # PC_ENABLE`, `ADDR_SEL_HI = !PIXEL_ENABLE &
(PC_ENABLE # Y_ENABLE)`, `ADDR_SEL_LO = !PIXEL_ENABLE & (PC_ENABLE #
X_ENABLE)`); since 2026-10-27 the four mux PLDs take PIXEL_ENABLE,
PC_ENABLE, X_ENABLE and Y_ENABLE directly, with the same priority, which
takes one PLD pass out of every memory address (FETCH_TIMING.md).

(The equations are written compactly here; the source spells them out.)

## Mode byte

Date: 2026-10-25

Each row has a mode byte; bits 1:0 pick 1, 2, 4 or 8 bpp for that row (the
color decoder's MODE1:MODE0), bits 3:2 pick the line repeat (see
[Line repeat](#line-repeat)), bits 6:4 tint the row (see
[Row tint](#row-tint)) and bit 7 blanks it (see [Blank line](#blank-line)).

| Bits | Name | Line code register output | Goes to |
|---|---|---|---|
| 1:0 | Color mode: 1, 2, 4, 8 bpp | Q1:Q0 | Color decoder MODE1:MODE0 |
| 3:2 | Line repeat: 1x, 2x, 4x (10 and 11 are both 4x) | Q3:Q2 | Audio slot PLD (row address remap) |
| 6:4 | Row tint: red, green, blue (1 = lift that channel) | Q6:Q4 | Tint resistors on the VGA lines, gated by VIDEN |
| 7 | Blank line (1 = black, no pixel reads) | Q7 | H counter PLD pin 6 |

Bits 7:4 were ignored by the hardware before 2026-10-22, so 0 in them keeps
the old behaviour.  It is read in horizontal blanking, so it
takes no screen space: all 80 byte columns (x6020 + column × 512 + row,
columns 0-79, in 1x) are pixels, 640 pixels across in 1 bpp.

| | |
|---|---|
| Address | row r's mode byte is at x5A20 + r (x5A20-x5BFF) |
| When | clock 1 of group 45 (H9:H3 = 0101101), in the back porch, on every line |
| Memory | video reads always come from the RAM |
| Chips added | none |
| CPU cost | one stall clock per line (525 per frame, 0.13 %), the same as the audio read |

**How it is read.**  The audio slot PLD (revision 03) raises BLANK_RD for
group 45 as well as for the audio group (46 or 47), so the Sync PLD raises
PIXEL_ENABLE in clock 1 of group 45.  That is a video read like any other:
the address mux takes the video address, H9:H3 on A15:A9 and V8:V0 on A8:A0
(the row address bits are not remapped in blanking), so it is x5A00 + V8:V0,
and visible row r (line 544 + r) gives x5A20 + r.  The byte lands in the
pixel buffer.

**How it is kept.**  The line code register (74HCT377) takes its D inputs from
the pixel buffer outputs, and its /E is /MODE_LD from the audio slot PLD
(pin 22, low for all of group 45).  It loads the mode byte from the pixel
buffer on clocks 2-7 of group 45 and holds it until group 45 of the next
line, so it is steady through all the active video.  Q1:Q0 go to the color
decoder, Q3:Q2 back to the audio slot PLD for the line repeat, Q6:Q4 to the
row tint resistors and Q7 to the H counter PLD (blank line).  It is a
74HCT377 since 2026-10-22 (was a 74F377): the tint resistors need about
3 mA from a high output, and the 74F377 is only rated for 1 mA.  The order
on each line is: group 45 mode byte, group 46/47 audio sample, start of
group 48 the DAC register copies the sample (H_VIDEO_ACTIVE rises), group 48
first pixel.  The audio read replaces the mode byte in the pixel buffer, but
by then the line code register has it.

**Why group 45.**  A blanking read can only reach x3800-x5FFF (groups
28-47).  Since the I/O window shrank to x5000-x53FF (groups 40-41), groups
42-47 are memory.  The audio read takes groups 46-47 (it needs a pair, see
SOUND.md), and the mode read must come before it, so group 45 is the
nearest.  That leaves x4000-x4FFF free for programs in one block.

**Timing.**  /MODE_LD is decoded from H9:H3 alone: H counter tCO 5.5 ns plus
the audio PLD tPD 7.5 ns is 13 ns after the group starts, long before the
edge at the end of clock 1, and it goes high 13 ns after the last edge of
the group (the F377 needs 0 ns hold).  The line code register's data is the
pixel buffer output, which only changes at the end of clock 1, so it is
steady for six clock edges; nothing in it races the data bus any more.  With
the 74HCT377 (2026-10-22, slower than the F377) the margins still hold:
/MODE_LD is low by about 15.5 ns into group 45 (H counter tCO 5.5 + audio
PLD 10), leaving about 24 ns before the first edge, and if the part misses
/MODE_LD going high at the first edge of group 46 it only loads the mode
byte again (the pixel buffer takes the audio sample one edge later).  Its
outputs are used from group 48 on.

**History.**  Until 2026-10-16 (first change) the mode byte was the first
byte read on each line (group 48, x6020 + row), so byte column 0 held mode
bytes and the screen showed 632 pixels in 1 bpp.  Then it was read in group
37 from x4A20 + row, with the audio in groups 38/39 (x4DF3-x4FFF) and the
DAC clocked by HSYNC, while x5000-x5FFF was all I/O.  Both moves were
checked in GHDL against the design before them.

## Blank line

Date: 2026-10-22

Bit 7 of a row's mode byte blanks every line of that row: the line is black
and the video makes no pixel reads on it, so the CPU is not stalled for its
80 groups.  HSYNC and VSYNC keep running, so the monitor stays locked.

| | |
|---|---|
| Chips added | none (one trace, line code register Q7 to H counter pin 6) |
| PLD change | H counter revision 08 |
| CPU gain | 80 clocks per blanked line; the whole picture blanked gives about 38,400 clocks per frame back, about +10 % |
| Audio | unaffected: the DAC register still gets its edge |

**How.**  The H counter makes H_VIDEO_ACTIVE.  On a blanked line it is high
for one clock only, the third clock of group 48 (H2:H0 = 000), instead of
groups 48-127.  The Sync PLD raises PIXEL_ENABLE only when H_VIDEO_ACTIVE is
high on a clock with H2:H0 = 110, and VIDEN only on H2:H0 = 111, so there
are no reads and VIDEN stays low (black).  The audio DAC register is
clocked by the rising edge of H_VIDEO_ACTIVE, so it still copies the line's
sample, two clocks later than on a shown line; the sample is still in the
pixel buffer because no pixel read has replaced it.

```text
BLANK_PULSE = LC7 & (H9:H3 = 48) & H2 & H1 & H0;
H_VIDEO_ACTIVE.D = VIDEO_ON & !LC7
                 # H_VIDEO_ACTIVE & !VIDEO_OFF & !LC7
                 # BLANK_PULSE;
```

**Timing.**  LC7 changes only in group 45 and is first used at the end of
group 47, more than two groups (640 ns) later.  H_VIDEO_ACTIVE is still a
registered output, so nothing downstream changes.

**Uses.**  Black separator rows, letterbox bars, hiding rows that are being
drawn, and a "fast mode": blank the whole picture while computing, loading
or decompressing, with sound still playing.  The pixel bytes of a blanked
row are not read, so they are free for other data.

**In the programs** (2026-10-22, measured with `placard_sim.py --stalls`,
which models the stall clocks and skips them on blanked rows):

| Program | What is blanked | Gain |
|---|---|---|
| Pi spigot | every row until its first digit is drawn | 7.7 % less time (1000 digits: 75.2 s to 69.5 s) |
| Mandelbrot | each pass now draws top to bottom; rows not drawn yet | 4.8 % less time (1 bpp: 85.0 s to 81.0 s) |
| CPU test | the empty rows around the grid | none to see (the test runs in 40 ms) |
| Game of Life, text demo, ray caster, scroller | nothing: every row shows something | none |

The most any program can gain is the 9.1 % of clocks the pixel reads take,
so blanking is worth about 5-9 % for a program with empty or not yet drawn
rows, not more.

## Row tint

Date: 2026-10-22

Bits 6:4 of a row's mode byte lift the red, green and blue levels of every
pixel in that row by about 0.2 V (about 30 % of full scale), black pixels
included.  So a row can have a colored background behind 1 bpp text, and a
program can make sky gradients or raster bars without touching the pixels.
Each bit is one fixed level; all three together give a neutral grey lift.
It adds to the color, it does not remap it, and it can only lift.

| | |
|---|---|
| Chips added | none (line code register becomes a 74HCT377, same pinout) |
| Parts | per channel: 910 Ω, BAT85, two 1N4148 in series (3 resistors, 3 BAT85, 6 1N4148), all through-hole |
| Level | about 200 mV on black, about 155 mV on full white (the DAC load is about 65 Ω) |

```text
U23 Q4 (red) --[910]--+--|>|--|>|--> VGA RED   (same for Q5 green, Q6 blue)
                      |  2x 1N4148
                    BAT85, anode at the node, cathode to VIDEN (Sync PLD pin 17)
```

**Why the diodes.**  Monitors take the back porch as their black level, and
the line code register changes in the middle of it (group 45), so the tint
must be off whenever the picture is blanked.  When VIDEN is low the BAT85
holds the node at about 0.7 V (VIDEN's VOL plus the Schottky drop), which is
too low to pass two silicon diodes (about 1.2 V), so nothing reaches the
line: the blanking level stays at 0 V.  When VIDEN is high the BAT85 is off
and Qn drives about 3 mA through the 910 Ω and the two 1N4148s.  With Qn low
the 1N4148s are reversed, so a row without tint sees no extra load at all.

**Loads.**  Each tint output sources about 3.1 mA (the 74HCT377 is rated for
4 mA).  During blanking VIDEN sinks about (4.4 - 0.7) / 910 = 4.1 mA per set
tint bit, 12.3 mA with all three, under the ATF22V10's 16 mA I_OL; its VOL
stays well below the color decoder's 0.8 V VIL.  Check VIDEN's low level on
the bench with all three tint bits set.

**Level spread.**  The lift follows the 74HCT377's VOH: 175-220 mV for VOH
4.0-4.7 V.

A mock-up of the look is in the project files (video/line_tint_mockup.png,
"strong" column).

**In the programs** (2026-10-22): the menu's highlight bar (blue) and title
band (gold), the text demo's blue status panel and a rainbow raster bar that
bounces behind its 80 column text (only 40 mode byte writes a frame, no
pixels), green-bar paper stripes behind the pi digits, and a rainbow of
bands behind the Game of Life.

## Line repeat

Date: 2026-10-16

Bits 3:2 of a row's mode byte say how many lines show each byte of video
memory, so a lower vertical resolution takes less RAM:

| Bits 3:2 | Repeat | Full screen | Video RAM used | Free per byte column |
|---|---|---|---|---|
| 00 | 1x | 640 × 480 (1 bpp) | 480 B per column, 37.5 KB | the 32 bytes of vertical blanking |
| 01 | 2x | 640 × 240 | 240 B per column, 18.75 KB | the low 256 bytes (page x60 + 2 × column) |
| 10, 11 | 4x | 640 × 120 | 120 B per column, 9.4 KB | everything but the top 128 bytes |

Pixels across don't change (bits 1:0 still pick 1, 2, 4 or 8 bpp).  A full
2x screen frees the even pages x60, x62 ... xFE, 80 pages of 256 bytes
(20 KB); a full 4x screen frees x6000-x617F, x6200-x637F and so on, 80 × 384
bytes (30 KB).  [reference/line_repeat_map.png](../reference/line_repeat_map.png)
(made by `src/scripts/gen_line_repeat_map.py`) shows one column in each
mode.

**The row address.**  The video address is column-major (A15:A9 = H9:H3,
A8:A0 = the row), so just ignoring V0 would free every other byte of each
column.  Instead the audio slot PLD (revision 03) makes four of the row
address bits, and the bits that would vary go to the bottom:

| Address bit | 1x | 2x | 4x |
|---|---|---|---|
| A0 | V0 | V8 | V7 |
| A1 | V1 | V1 | V8 |
| A2-A6 | V2-V6 | V2-V6 | V2-V6 |
| A7 | V7 | V7 | 1 |
| A8 | V8 | 1 | 1 |

With v = row + 32 (V8:V0 of the line), a row's byte in column c is at
x6000 + c × 512 + offset:

    1x:  offset = v
    2x:  offset = x100 + (v & xFE) + v8
    4x:  offset = x180 + (v & x7C) + 2 × v8 + v7

So every 2x pair (rows 2k and 2k + 1) and every 4x group (rows 4k to 4k + 3)
has its own byte; the order within the column is shuffled.  `vid_addr` and
`plot1` in the library work this out from the row's own mode byte, and
`row_offset` in `placard_sim.py` is the same thing in Python.

**Each line uses its own mode byte.**  The remap is driven by that line's
line code, so rows can mix 1x, 2x and 4x.  Rows in different modes can land
on the same byte, though:

| Rows in this mode | Use offsets | Can share bytes with |
|---|---|---|
| 1x, rows 0-223 | 32-255 | nothing |
| 1x, rows 224-479 | 256-511 | 2x and 4x rows |
| 2x, any rows | 256-511 | 1x rows 224-479, 4x rows |
| 4x, any rows | 384-511 | 1x rows 352-479, 2x rows |

The high bits are set to 1 rather than 0 so that a full-resolution band in
rows 0-223 (a text area, say) can sit over a 2x or 4x picture without ever
sharing a byte.  Other mixes work as long as no two drawn rows share a byte.
Give both lines of a 2x pair, or all four lines of a 4x group, the same
repeat bits; a pair split between modes shows two different bytes.

**The hardware.**  The address mux's video (C) inputs for A0, A1, A7 and A8
come from the audio slot PLD's R0, R1, R7 and R8 (pins 17-20) instead of
straight from the V counter; A2-A6 are still V2-V6, and the mux PLDs are
unchanged.  The PLD takes V0, V1, V7, V8 (pins 1, 10, 11, 13) and the line
code register's Q2 and Q3 (pins 14, 15).  In groups 32-47 (RAW = !H9 & !H7)
the outputs are the plain V bits, so the mode byte and audio reads are not
remapped.

**Timing.**  Only video reads use the mux's C inputs, so no CPU path
changes.  The worst case is the switch from raw to remapped at the start of
group 48: H counter tCO 5.5 ns + audio PLD 7.5 ns = 13 ns, while the first
pixel read is in clock 1 (39.7 ns in), so the address has settled a whole
clock early.  V changes once per line, and the line code in group 45, where
RAW blocks it.

**8x (not built).**  Bits 3:2 = 11 act like 10.  An 8x mode needs six bits
remapped and doesn't fit in the audio slot PLD; a separate row address PLD
(V8:V0 and LC3:LC2 in, nine row bits out) could do 8x and keep the rows in
order.

**Checked in simulation** (GHDL, `basys_top.vhd`, 860,000 clocks, two
frames, CPU looping in ROM):

- *1x and the moved bytes:* a random screen with random 1x mode bytes, and
  the same bytes in x4A00-x4FFF and x5A00-x5FFF.  Against the design before
  this change, RGB, HSYNC and VSYNC were identical on every clock, and the
  audio DAC took the same 1068 values in the same order, each exactly 48
  clocks later (group 48 instead of group 42).
- *Line repeat:* rows 0-95 in 4x, 96-223 in 1x and 224-479 in 2x, with
  random bpp per row and the pixel bytes at their remapped addresses.  The
  RGB output was identical, clock for clock, to the design before this
  change showing a 1x image with each 2x row pair and 4x group written out
  in full.
