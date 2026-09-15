# ATF22V10 VGA Color Decoder

## Overview

This chip design is the color decoder for each of the 4 color modes.  It take the 8-bit RAM data value and outputs to the VGA color-pin resistor DAC.
This design is implemented in an **ATF22V10** PLD.

## Color Modes

| `MODE1 MODE0` | Mode | Colors |
|---|---|---:|
| `00` | 1-bit | 2 |
| `01` | 2-bit | 4 |
| `10` | 4-bit | 16 |
| `11` | 8-bit | 256 |

---

### Inputs

- `D0..D7` — 8-bit pixel data
- `MODE1..MODE0` — color-depth selection
- `SEL2..SEL0` — data pin selection for reduced-color modes

### Outputs

The eight outputs are mapped as:

| Output | VGA Signal |
|---|---|
| `OUT0` | `VGA_RED(1)` |
| `OUT1` | `VGA_RED(2)` |
| `OUT2` | `VGA_RED(3)` |
| `OUT3` | `VGA_BLUE(2)` |
| `OUT4` | `VGA_BLUE(3)` |
| `OUT5` | `VGA_GREEN(1)` |
| `OUT6` | `VGA_GREEN(2)` |
| `OUT7` | `VGA_GREEN(3)` |

---

## 1-bit Color Mode

`SEL2:SEL0` selects one of the eight input bits.

| `SEL2:SEL0` | Selected Bit |
|---|---|
| `000` | `D0` |
| `001` | `D1` |
| `010` | `D2` |
| `011` | `D3` |
| `100` | `D4` |
| `101` | `D5` |
| `110` | `D6` |
| `111` | `D7` |

The selected bit is replicated to all eight VGA outputs.

- `0` = Black
- `1` = White

---

## 2-bit Color Mode

`SEL1:SEL0` selects one of four adjacent two-bit values.

| `SEL1:SEL0` | Input Bits |
|---|---|
| `00` | `D1:D0` |
| `01` | `D3:D2` |
| `10` | `D5:D4` |
| `11` | `D7:D6` |

The 2-bit palette is:

| Value | Color | Red | Green | Blue |
|---:|---|---|---|---|
| `00` | Black | `000` | `000` | `00` |
| `01` | Blue | `000` | `000` | `11` |
| `10` | Green | `111` | `111` | `00` |
| `11` | White | `111` | `111` | `11` |

The selected low bit controls blue, while the selected high bit controls red and green.

---

## 4-bit Color Mode

`SEL0` selects which four-bit nibble is decoded.

| `SEL0` | Input |
|---:|---|
| `0` | `D3:D0` |
| `1` | `D7:D4` |

The palette is an EGA/CGA-inspired 16-color palette adapted to the available **3-bit red / 3-bit green / 2-bit blue** output.

### 4-bit Color Table

| Hex | Color | Red `R3:R1` | Green `G3:G1` | Blue `B3:B2` |
|---:|---|---|---|---|
| `0` | Black | `000` | `000` | `00` |
| `1` | Blue | `000` | `000` | `11` |
| `2` | Green | `000` | `111` | `00` |
| `3` | Cyan | `000` | `111` | `11` |
| `4` | Red | `111` | `000` | `00` |
| `5` | Magenta | `111` | `000` | `11` |
| `6` | Brown | `101` | `011` | `00` |
| `7` | Light Gray | `101` | `101` | `01` |
| `8` | Dark Gray | `010` | `010` | `01` |
| `9` | Bright Blue | `010` | `010` | `11` |
| `A` | Bright Green | `010` | `111` | `00` |
| `B` | Bright Cyan | `010` | `111` | `11` |
| `C` | Bright Red | `111` | `010` | `00` |
| `D` | Bright Magenta | `111` | `010` | `11` |
| `E` | Yellow | `111` | `111` | `00` |
| `F` | White | `111` | `111` | `11` |

For selected nibble `X3:X0`, the minimized decoder equations are:

```text
R1_4 = X2
R2_4 = X3 # (X2 & !X1)
R3_4 = X2

G1_4 = X1
G2_4 = X3 # (X1 & !X0) # (X1 & !X2)
G3_4 = (X0 & X1) # (X1 & X3) # (X1 & !X2)

B2_4 = (X0 & X3) # (X0 & !X1) # (X0 & !X2)
B3_4 = X0 # (X3 & !X1 & !X2)
```

---

## 8-bit Color Mode

In 8-bit mode the data is passed directly to the VGA outputs:

```text
OUT0 = D0
OUT1 = D1
OUT2 = D2
OUT3 = D3
OUT4 = D4
OUT5 = D5
OUT6 = D6
OUT7 = D7
```

This gives a 256-color `RRRBBGGG`-style output according to the physical VGA bit mapping.

---

# ATF22V10 Pinout

The design uses the 24-pin ATF22V10 package.

| Pin | Signal | Function |
|---:|---|---|
| 1 | `CLK/IN` | Unused |
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
| 13 | `SEL0` | Data select |
| 14 | `OUT0` | `VGA_RED(1)` |
| 15 | `OUT1` | `VGA_RED(2)` |
| 16 | `OUT2` | `VGA_RED(3)` |
| 17 | `OUT3` | `VGA_BLUE(2)` |
| 18 | `OUT4` | `VGA_BLUE(3)` |
| 19 | `OUT5` | `VGA_GREEN(1)` |
| 20 | `OUT6` | `VGA_GREEN(2)` |
| 21 | `OUT7` | `VGA_GREEN(3)` |
| 22 | `SEL1` | Data select |
| 23 | `SEL2` | Data select |
| 24 | `VCC` | +5 V |

Pins 22 and 23 are bidirectional ATF22V10 I/O pins configured as inputs for this design.

---

# VGA Resistor DAC

The VGA interface uses the standard **75 Ω termination**.

The resistor values below are the selected E96 values for the passive DAC.

## Red

| Output | Weight | Resistor |
|---|---:|---:|
| `VGA_RED(1)` | 1 | **3.24 kΩ** |
| `VGA_RED(2)` | 2 | **1.69 kΩ** |
| `VGA_RED(3)` | 4 | **825 Ω** |

## Green

| Output | Weight | Resistor |
|---|---:|---:|
| `VGA_GREEN(1)` | 1 | **3.24 kΩ** |
| `VGA_GREEN(2)` | 2 | **1.69 kΩ** |
| `VGA_GREEN(3)` | 4 | **825 Ω** |

## Blue

Blue has only two output bits.

| Output | Weight | Resistor |
|---|---:|---:|
| `VGA_BLUE(2)` | 2 | **1.43 kΩ** |
| `VGA_BLUE(3)` | 4 | **715 Ω** |

### Physical Connections

```text
OUT0 / RED(1)    -- 3.24 kΩ --+
OUT1 / RED(2)    -- 1.69 kΩ --+
OUT2 / RED(3)    -- 825 Ω  ---+---- VGA RED
                                      |
                                     75 Ω
                                      |
                                     GND


OUT3 / BLUE(2)   -- 1.43 kΩ --+
OUT4 / BLUE(3)   -- 715 Ω  ---+---- VGA BLUE
                                      |
                                     75 Ω
                                      |
                                     GND


OUT5 / GREEN(1)  -- 3.24 kΩ --+
OUT6 / GREEN(2)  -- 1.69 kΩ --+
OUT7 / GREEN(3)  -- 825 Ω  ---+---- VGA GREEN
                                      |
                                     75 Ω
                                      |
                                     GND
```

These resistor values assume a 5 V PLD supply and a 75 Ω VGA load. Actual output voltages will depend on the ATF22V10 output high voltage and output resistance.

---

# Design Summary

| Feature | Configuration |
|---|---|
| PLD | ATF22V10 |
| Package | 24-pin |
| Supply | +5 V |
| Pixel inputs | 8 |
| Mode inputs | 2 |
| Selection inputs | 3 |
| VGA outputs | 8 |
| Color modes | 1, 2, 4, 8 bit |
| Maximum colors | 256 |
| VGA red bits | 3 |
| VGA green bits | 3 |
| VGA blue bits | 2 |
| VGA termination | 75 Ω |
| Red/green resistors | 3.24 kΩ / 1.69 kΩ / 825 Ω |
| Blue resistors | 1.43 kΩ / 715 Ω |
| Logic type | Combinational |
| Pixel clock required | No |

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
OUT0 = RED(1)
OUT1 = RED(2)
OUT2 = RED(3)

OUT3 = BLUE(2)
OUT4 = BLUE(3)

OUT5 = GREEN(1)
OUT6 = GREEN(2)
OUT7 = GREEN(3)
```