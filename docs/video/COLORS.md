# ATF22V10 VGA Color Decoder

Date: 2026-11-16

## Overview

This chip design is the color decoder for each of the 4 color modes.  It take the 8-bit RAM data value and outputs to the VGA color-pin resistor DAC.
This design is implemented in an **ATF22V10** PLD.

## Color Modes

| `MODE1 MODE0` | Mode | Pixels per byte | Colors |
|:-------------:|:----:|:---------------:|:------:|
| `00` | 1-bit | 8 | 2 |
| `01` | 2-bit | 4 | 4 |
| `10` | 4-bit | 2 | 16 |
| `11` | 8-bit | 1 | 256 |

MODE1:MODE0 come from the line code register (74HCT377 Q1:Q0), which copies
each line's mode byte (VIDEO.md, "Mode byte").

---

### Inputs

- `D0..D7`: the pixel byte from the pixel buffer
- `MODE1..MODE0`: color depth for the line
- `H2..H0`: pixel select, the low three bits of the horizontal count from
  the Sync PLD.  The pixel buffer loads in clock 1 of each 8-clock group
  (H2:H0 = 111) and its first pixel is shown at H2:H0 = 000.
- `VIDEN`: video enable from the Sync PLD.  Low forces every output to 0
  (black).  It is folded into the mode decode, so it costs no product terms.

### Outputs

| Output | VGA signal |
|:------:|:----------:|
| `RED1` | Red bit 1 (LSB) |
| `RED2` | Red bit 2 |
| `RED3` | Red bit 3 (MSB) |
| `BLU2` | Blue bit 2 (LSB) |
| `BLU3` | Blue bit 3 (MSB) |
| `GRN1` | Green bit 1 (LSB) |
| `GRN2` | Green bit 2 |
| `GRN3` | Green bit 3 (MSB) |

All outputs are combinational.

---

## 1-bit Color Mode

`H2:H0` selects one of the eight input bits, one pixel per clock.

| `H2:H0` | Selected Bit |
|:-------:|:------------:|
| `000` | `D0` |
| `001` | `D1` |
| `010` | `D2` |
| `011` | `D3` |
| `100` | `D4` |
| `101` | `D5` |
| `110` | `D6` |
| `111` | `D7` |

GRN3 computes the selected bit itself (an 8:1 mux in its own product
terms), and the other seven outputs take GRN3 back through the array, so
every output carries the same bit.

- `0` = Black
- `1` = White (R 7, G 7, B 3)

---

## 2-bit Color Mode

`H2:H1` selects one of four two-bit values, one pixel per two clocks.

| `H2:H1` | Input Bits |
|:-------:|:----------:|
| `00` | `D1:D0` |
| `01` | `D3:D2` |
| `10` | `D5:D4` |
| `11` | `D7:D6` |

The 2-bit palette is:

| Value | Color  | Red   | Green | Blue |
|:-----:|:------:|:-----:|:-----:|:----:|
| `00`  | Black  | `000` | `000` | `00` |
| `01`  | Blue   | `000` | `001` | `11` |
| `10`  | Gold   | `111` | `101` | `00` |
| `11`  | White  | `111` | `111` | `11` |

The selected low bit (C0) controls blue and the selected high bit (C1)
controls red.  For green, `GRN1 = C1 | C0`, `GRN2 = C1 & C0` and
`GRN3 = C1`, so blue gets a little green (G 1), gold gets G 5 and white
gets G 7.

---

## 4-bit Color Mode

`H2` selects which four-bit nibble is decoded, one pixel per four clocks.

| `H2` | Input   |
|:----:|:-------:|
| `0`  | `D3:D0` |
| `1`  | `D7:D4` |

The palette has 16 colors (4 grays, 8 hues, dark and light variants) on the
**3-bit red / 3-bit green / 2-bit blue** output.  The index order was chosen
so that GRN3 = X3 (one term) and every output fits its pin's product-term
limit.

### 4-bit Color Table

| Hex | Color       | Red   | Green | Blue |
|-----|-------------|-------|-------|------|
| `0` | Black       | `000` | `000` | `00` |
| `1` | Dark blue   | `000` | `000` | `01` |
| `2` | Purple      | `100` | `000` | `10` |
| `3` | Blue        | `000` | `000` | `11` |
| `4` | Red         | `111` | `000` | `00` |
| `5` | Magenta     | `111` | `000` | `11` |
| `6` | Brown       | `100` | `010` | `00` |
| `7` | Dark gray   | `010` | `010` | `01` |
| `8` | Cyan        | `000` | `111` | `11` |
| `9` | Dark green  | `000` | `100` | `00` |
| `A` | White       | `111` | `111` | `11` |
| `B` | Light gray  | `101` | `101` | `10` |
| `C` | Pink        | `111` | `100` | `10` |
| `D` | Orange      | `111` | `100` | `00` |
| `E` | Yellow      | `111` | `111` | `00` |
| `F` | Green       | `001` | `111` | `00` |

For selected nibble `X3:X0`, the decoder equations (from
`ATF22V10_COLORDECODER.pld`) are:

```text
RED1_4 = X2 & !X1 # X3 & X1
RED2_4 = X2 & !X1 # !X3 & X2 & X0 # X3 & X1 & !X0
RED3_4 = X1 & !X0 # X2 & !X1 # X3 & !X2 & X1

GRN1_4 = X3 & !X2 & !X0 # X3 & X1
GRN2_4 = X2 & X1 # X3 & !X2 & !X0
GRN3_4 = X3

BLU2_4 = !X3 & X0 # X3 & !X2 & !X0
BLU3_4 = !X2 & X1 # !X3 & X2 & !X1 & X0 # X3 & !X1 & !X0
```

---

## 8-bit Color Mode

In 8-bit mode the data is passed directly to the VGA outputs, and H2:H0 is
ignored (one pixel per eight clocks):

```text
RED1 = D0    RED2 = D1    RED3 = D2
BLU2 = D3    BLU3 = D4
GRN1 = D5    GRN2 = D6    GRN3 = D7
```

So the byte is `GGGBBRRR` (D7..D0): green in bits 7:5, blue in 4:3, red in
2:0.

### 8-bit grays

Blue has only two DAC bits, so a plain pass-through has just two exact
grays (black and white).  From revision 08, five more codes with red equal
to green are **blended grays**: the decoder switches blue between two
neighboring DAC levels during the pixel's eight clocks (it uses H2:H0 for
this), so that the average blue matches red and green.  Use these eight
bytes for a gray ramp:

| Gray | Byte | R = G | B | Red, green | Blue in clocks H = 0..7 (`BLU3 BLU2`) | Blue average | Blue error |
|:----:|:----:|:-----:|:-:|-----------:|---------------------------------------|-------------:|-----------:|
| 0 | `x00` | 0 | 0 | 0 mV | steady `00` | 0 mV | 0 |
| 1 | `x21` | 1 | 0 | 98 mV | `00 01 00 01 00 01 00 01` | 113 mV | +2.2 % |
| 2 | `x4A` | 2 | 1 | 202 mV | steady `01` (not blended) | 227 mV | +3.6 % |
| 3 | `x6B` | 3 | 1 | 300 mV | `01 01 01 10 01 01 01 10` | 284 mV | -2.4 % |
| 4 | `x8C` | 4 | 1 | 394 mV | `01 10 10 10 01 10 10 10` | 397 mV | +0.4 % |
| 5 | `xB5` | 5 | 2 | 492 mV | `10 10 10 10 10 10 10 11` | 481 mV | -1.5 % |
| 6 | `xD6` | 6 | 2 | 596 mV | `10 11 10 11 10 11 10 11` | 567 mV | -4.3 % |
| 7 | `xFF` | 7 | 3 | 694 mV | steady `11` | 680 mV | -2.0 % |

The error is the blue average minus the red and green level, in percent of
full scale (694 mV).  Blue's DAC levels are 0, 227, 453 and 680 mV.  Before
revision 08 the five blended codes were off by 5.6 to 24 %.

The blend is a fine pattern one dot clock wide inside the pixel, so it is
blue stripes at 640-pixel pitch, one blue step (227 mV) high.  All other 8-bit codes, and
the 1, 2 and 4-bit modes, are unchanged.

```text
GRAY1 = M8 & (D7..D0 = x21)     GRAY3 = M8 & (x6B)     GRAY4 = M8 & (x8C)
GRAY5 = M8 & (xB5)              GRAY6 = M8 & (xD6)

BLU3 = ... # M8 & D4 # GRAY3 & H1 & H0 # GRAY4 & H0 # GRAY4 & H1
BLU2 = ... # M8 & D3 & D4 # M8 & D3 & !BLU3
           # GRAY1 & H0 # GRAY5 & H2 & H1 & H0 # GRAY6 & H0
```

In a code with blue = `01`, BLU2 is the opposite of the BLU3 pin, so a BLU3
blend term swaps blue between `01` and `10`.

**Room for the terms.**  BLU2's cell has only 10 product terms and was
full, so BLU2 now reads other output pins back, as every output already
does with GRN3 in 1-bit mode: in 2-bit mode BLU2 = the BLU3 pin (both are
C0), and in 4-bit mode indexes 8 and A come from `GRN2 & GRN1 & BLU3`.  BLU2
then follows those pins by one more gate delay (7.5 ns at most) in the 2
and 4-bit modes; the 1-bit mode's timing is unchanged.

---

# ATF22V10 Pinout

The design uses the 24-pin ATF22V10 package and every non-power pin
(14 inputs, 8 outputs).  Pins 14 and 23 are I/O pins used as inputs.

| Pin | Signal | Function |
|:---:|:------:|:--------:|
| 1 | `H1` | Pixel select bit 1 (pin 1 is used as a plain input; nothing is registered) |
| 2 | `D0` | Data input |
| 3 | `D1` | Data input |
| 4 | `D2` | Data input |
| 5 | `D3` | Data input |
| 6 | `D4` | Data input |
| 7 | `D5` | Data input |
| 8 | `D6` | Data input |
| 9 | `D7` | Data input |
| 10 | `MODE0` | Mode select |
| 11 | `MODE1` | Mode select |
| 12 | `GND` | Ground |
| 13 | `H0` | Pixel select bit 0 |
| 14 | `H2` | Pixel select bit 2 (I/O pin used as input) |
| 15 | `RED1` | Red bit 1 |
| 16 | `RED2` | Red bit 2 |
| 17 | `GRN1` | Green bit 1 |
| 18 | `BLU3` | Blue bit 3 |
| 19 | `GRN3` | Green bit 3, also the 1-bit pixel |
| 20 | `GRN2` | Green bit 2 |
| 21 | `RED3` | Red bit 3 |
| 22 | `BLU2` | Blue bit 2 |
| 23 | `VIDEN` | Video enable (I/O pin used as input) |
| 24 | `VCC` | +5 V |

This is the fullest PLD in the design: RED1, RED2, RED3, GRN1 and BLU2 use
every product term of their pins, and GRN3 and BLU3 have one to spare
([PLD_USAGE.md](../architecture/PLD_USAGE.md) has the counts).

---

# VGA Resistor DAC

The VGA interface uses the standard **75 Ω termination**.

The resistor values below are the selected values for the passive DAC, all 1 %
parts.  Red and green use E24 values (820 Ω / 1.6 kΩ / 3.3 kΩ): at a 5 V
output high, white is 694 mV and the steps are 94-104 mV.  Blue uses E96
values, which match its full scale to red and green (680 mV).

## Red

| Output | Weight | Resistor |
|---|---:|---:|
| `VGA_RED(1)` | 1 | **3.3 kΩ** |
| `VGA_RED(2)` | 2 | **1.6 kΩ** |
| `VGA_RED(3)` | 4 | **820 Ω** |

## Green

| Output | Weight | Resistor |
|---|---:|---:|
| `VGA_GREEN(1)` | 1 | **3.3 kΩ** |
| `VGA_GREEN(2)` | 2 | **1.6 kΩ** |
| `VGA_GREEN(3)` | 4 | **820 Ω** |

## Blue

Blue has only two output bits.

| Output | Weight | Resistor |
|---|---:|---:|
| `VGA_BLUE(2)` | 2 | **1.43 kΩ** |
| `VGA_BLUE(3)` | 4 | **715 Ω** |

### Physical Connections

```text
RED1 / RED(1)    -- 3.3 kΩ  --+
RED2 / RED(2)    -- 1.6 kΩ  --+
RED3 / RED(3)    -- 820 Ω  ---+---- VGA RED
                                      |
                                     75 Ω
                                      |
                                     GND


BLU2 / BLUE(2)   -- 1.43 kΩ --+
BLU3 / BLUE(3)   -- 715 Ω  ---+---- VGA BLUE
                                      |
                                     75 Ω
                                      |
                                     GND


GRN1 / GREEN(1)  -- 3.3 kΩ  --+
GRN2 / GREEN(2)  -- 1.6 kΩ  --+
GRN3 / GREEN(3)  -- 820 Ω  ---+---- VGA GREEN
                                      |
                                     75 Ω
                                      |
                                     GND
```

These resistor values assume a 5 V PLD supply and a 75 Ω VGA load. Actual output voltages will depend on the ATF22V10 output high voltage and output resistance.

## Row tint

Each VGA color line also has a row tint input: the line code register's
Q4 (red), Q5 (green) or Q6 (blue) through 910 Ω and two 1N4148s in series,
with a 1N5817 from the 910 Ω node to VIDEN so the tint is off in blanking.
A set bit lifts that channel by about 0.2 V for the whole row.  See
[VIDEO.md, "Row tint"](VIDEO.md#row-tint).

---

# Design Summary

| Feature | Configuration |
|---------|---------------|
| PLD | ATF22V10C (`ATF22V10_COLORDECODER.pld`, revision 08) |
| Package | 24-pin |
| Supply | +5 V |
| Pixel inputs | 8 |
| Mode inputs | 2 |
| Pixel select inputs | 3 (H2:H0) |
| Video enable input | 1 (VIDEN) |
| VGA outputs | 8 |
| Color modes | 1, 2, 4, 8 bit |
| Maximum colors | 256 |
| Grays in 8-bit mode | 8 (five blended) |
| VGA red bits | 3 |
| VGA green bits | 3 |
| VGA blue bits | 2 |
| VGA termination | 75 Ω |
| Red/green resistors | 3.3 kΩ / 1.6 kΩ / 820 Ω |
| Blue resistors | 1.43 kΩ / 715 Ω |
| Logic type | Combinational |
| Pixel clock required | No (H2:H0 come from the Sync PLD) |

## Mode Selection Summary

```text
MODE1 MODE0

  00       1-bit
  01       2-bit
  10       4-bit
  11       8-bit
```

## Output Summary

```text
pin 15 RED1 = RED(1)
pin 16 RED2 = RED(2)
pin 21 RED3 = RED(3)

pin 22 BLU2 = BLUE(2)
pin 18 BLU3 = BLUE(3)

pin 17 GRN1 = GREEN(1)
pin 20 GRN2 = GREEN(2)
pin 19 GRN3 = GREEN(3)
```
