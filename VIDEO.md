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

The First-active-pixel signal is high for one pixel only.  Specifically this is
the first pixel of each video line.  It is used to capture the display mode
value into the display mode register.

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
| 17 | `VIDEO_ACTIVE` | Output | Combined horizontal/vertical active video |
| 18 | `VSYNC` | Output | Vertical sync |
| 19 | 'BYTE_ENABLE' | Output | VIDEO_ACTIVE but only when H2:H0 = "000" |
| 20 | — | — | Unused |
| 21 | — | — | Unused |
| 22 | — | — | Unused |
| 23 | — | — | Unused |
| 24 | `VCC` | Power | +5 V |

H2:H0 = 3-bit pixel-within-byte counter

VIDEO_ACTIVE.D = (V9 & V5 & !V4 & !V3 & !V2 & !V1)
               # (VIDEO_ACTIVE & V9);
               
VSYNC = !(V4 & !V3 & V2 & !V1)

BYTE_ENABLE = VIDEO_ACTIVE & !H2 & !H1 & !H0
