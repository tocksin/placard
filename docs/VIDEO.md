# VGA Timing Generator

## Overview

The VGA timing generator uses three ATF22V10C PLDs to generate the timing
signals for a 640×480 @ 60 Hz VGA display.

The three PLDs are:

1. **H Counter PLD** — generates the upper seven horizontal count bits and
   horizontal timing signals.
2. **V Counter PLD** — generates the ten vertical count bits and determines
   the end of each horizontal line.
3. **Sync / Pixel Counter PLD** — generates the lower three horizontal count
   bits, VGA vertical sync, combined video enable, and the byte-load signal.

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
The Horizontal Counter PLD contains the upper seven bits of the horizontal
counter.

It counts horizontal byte positions from:

28 → 127

corresponding to:

224 → 1023 pixels

The counter reloads to 28 after reaching 127.

The PLD also generates:

- Horizontal video-active state
- First-active-pixel signal
- Horizontal Sync

The horizontal video-active signal is high when the counter is in a range where
there is active video.  It is sent to the Sync PLD and combined with the
vertical counter to determine the full video active region.

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
| 2 | `RESET` | Input | Horizontal counter reset |
| 3 | `H0` | Input | Horizontal pixel bit 0 |
| 4 | `H1` | Input | Horizontal pixel bit 1 |
| 5 | `H2` | Input | Horizontal pixel bit 2 |
| 6 | — | — | Unused |
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
| 21 | `HSYNC` | Output | Horizontal sync |
| 22 | `H_VIDEO_ACTIVE` | Output | Horizontal active-video state |
| 23 | `H_ACTIVE_START` | Output | High only at H = 384 |
| 24 | `VCC` | Power | +5 V |

- H9:H3 = Upper 7 bits of horizontal count
- H2:H0 = Supplied by Sync/Pixel PLD
- HSYNC = Horizontal sync output
- H_VIDEO_ACTIVE = Horizontal active-video indication
- H_ACTIVE_START = One-clock pulse at H = 384

## Vertical Counter PLD

### Function
The Vertical Counter PLD generates the ten-bit vertical count.

It receives the complete ten-bit horizontal count from the other two PLDs.

This allows it to determine the exact end of each horizontal line without
requiring a separate horizontal terminal count signal.

The vertical counter counts:

499 → 1023

and reloads to 499.

There is no vertical decoding of the timing in this PLD due to the lack of 
macrocells and outputs.  Therefore, all decoding is done in the Sync PLD.

### Pinout
| Pin | Signal | Direction | Function |
|---:|---|---|---|
| 1 | `CLK` | Input | Pixel clock |
| 2 | `RESET` | Input | Vertical counter reset |
| 3 | `H0` | Input | Horizontal count bit 0 |
| 4 | `H1` | Input | Horizontal count bit 1 |
| 5 | `H2` | Input | Horizontal count bit 2 |
| 6 | `H3` | Input | Horizontal count bit 3 |
| 7 | `H4` | Input | Horizontal count bit 4 |
| 8 | `H5` | Input | Horizontal count bit 5 |
| 9 | `H6` | Input | Horizontal count bit 6 |
| 10 | `H7` | Input | Horizontal count bit 7 |
| 11 | `H8` | Input | Horizontal count bit 8 |
| 12 | `GND` | Power | Ground |
| 13 | `H9` | Input | Horizontal count bit 9 (MSB) |
| 14 | `V0` | Output | Vertical count bit 0 |
| 15 | `V1` | Output | Vertical count bit 1 |
| 16 | `V2` | Output | Vertical count bit 2 |
| 17 | `V3` | Output | Vertical count bit 3 |
| 18 | `V4` | Output | Vertical count bit 4 |
| 19 | `V5` | Output | Vertical count bit 5 |
| 20 | `V6` | Output | Vertical count bit 6 |
| 21 | `V7` | Output | Vertical count bit 7 |
| 22 | `V8` | Output | Vertical count bit 8 |
| 23 | `V9` | Output | Vertical count bit 9 (MSB) |
| 24 | `VCC` | Power | +5 V |

- H9:H0 = Complete horizontal count input
- V9:V0 = Vertical count

Horizontal count is used to determine when to increment the vertical count.
It calculates the terminal count internally - it is true only at H = 1023.

## Sync Decoder / Pixel counter PLD

### Function
The Sync Decoder / Pixel Counter PLD contains the three lowest horizontal count
bits.  These bits select the individual pixel within an 8-pixel video byte.

It also generates:

- VSYNC
- Video-enable signal

### Vertical Timing
| Line range | Function |
|-------------|----------|
| 499-531 | Front Porch |
| 532-533 | VSYNC |
| 534-543 | Back Porch |
| 544-1023 | Active Video |

The video-enable signal indicates when the RAM/ROM should be enabled to load an
active-video pixel.  This signal is also used to stall the CPU to prevent it 
from accessing the RAM/ROM during video reads.

### Pinout

| Pin | Signal | Direction | Function |
|---:|---|---|---|
| 1 | `CLK` | Input | Pixel clock |
| 2 | `V1` | Input | Vertical count bit 1 |
| 3 | `V2` | Input | Vertical count bit 2 |
| 4 | `V3` | Input | Vertical count bit 3 |
| 5 | `V4` | Input | Vertical count bit 4 |
| 6 | `V5` | Input | Vertical count bit 5 |
| 7 | `V9` | Input | Vertical count bit 9 |
| 8 | - | Input | Unused |
| 9 | - | Input | Unused |
| 10 | - | Input | Unused |
| 11 | - | Input | Unused |
| 12 | `GND` | Power | Ground |
| 13 | `H_VIDEO_ACTIVE` | Input | Horizontal active-video state |
| 14 | `H0` | Output | Horizontal pixel bit 0 |
| 15 | `H1` | Output | Horizontal pixel bit 1 |
| 16 | `H2` | Output | Horizontal pixel bit 2 |
| 17 | `VIDEN` | Output | Colour decoder video enable: active video, two clocks late (registered, revision 08; was `VIDEO_ACTIVE`) |
| 18 | `VSYNC` | Output | Vertical sync |
| 19 | 'PIXEL_ENABLE' | Output | Video read, clock 1 of each group (H2:H0 = "111" since revision 08) |
| 20 | — | — | Unused |
| 21 | — | — | Unused |
| 22 | — | — | Unused |
| 23 | — | — | Unused |
| 24 | `VCC` | Power | +5 V |

H2:H0 = 3-bit pixel-within-byte counter

VIDEO_ACTIVE.D = (V9 & V5 & !V4 & !V3 & !V2 & !V1)
               # (VIDEO_ACTIVE & V9);
               
VSYNC = !(V4 & !V3 & V2 & !V1)

PIXEL_ENABLE = VIDEO_ACTIVE & !H2 & !H1 & !H0

## Mode byte

Date: 2026-10-16

Each row has a mode byte; bits 1:0 pick 1, 2, 4 or 8 bpp for that row (the
color decoder's MODE1:MODE0), and bits 3:2 pick the line repeat (see
[Line repeat](#line-repeat)).  It is read in horizontal blanking, so it
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

**How it is kept.**  The line code register (F377) takes its D inputs from
the pixel buffer outputs, and its /E is /MODE_LD from the audio slot PLD
(pin 22, low for all of group 45).  It loads the mode byte from the pixel
buffer on clocks 2-7 of group 45 and holds it until group 45 of the next
line, so it is steady through all the active video.  Q1:Q0 go to the color
decoder and Q3:Q2 back to the audio slot PLD for the line repeat.  The order
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
steady for six clock edges; nothing in it races the data bus any more.

**History.**  Until 2026-10-16 (first change) the mode byte was the first
byte read on each line (group 48, x6020 + row), so byte column 0 held mode
bytes and the screen showed 632 pixels in 1 bpp.  Then it was read in group
37 from x4A20 + row, with the audio in groups 38/39 (x4DF3-x4FFF) and the
DAC clocked by HSYNC, while x5000-x5FFF was all I/O.  Both moves were
checked in GHDL against the design before them.

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
