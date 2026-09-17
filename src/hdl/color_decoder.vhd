-- @file color_decoder.vhd
-- @brief Takes a data value read from memory and converts it to a specific color
-- @author Justin Davis
--
-- Date: 09/16/2026
-------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity color_decoder is
    Port (
        -- Input Data
        D0    : in  std_logic;
        D1    : in  std_logic;
        D2    : in  std_logic;
        D3    : in  std_logic;
        D4    : in  std_logic;
        D5    : in  std_logic;
        D6    : in  std_logic;
        D7    : in  std_logic;

        -- Mode Selection
        MODE0 : in  std_logic;
        MODE1 : in  std_logic;

        -- Selection Signals
        SEL0  : in  std_logic;
        SEL1  : in  std_logic;
        SEL2  : in  std_logic;

        -- VGA Outputs
        OUT0  : out std_logic; -- VGA_RED(1)
        OUT1  : out std_logic; -- VGA_RED(2)
        OUT2  : out std_logic; -- VGA_RED(3)
        OUT3  : out std_logic; -- VGA_BLUE(2)
        OUT4  : out std_logic; -- VGA_BLUE(3)
        OUT5  : out std_logic; -- VGA_GREEN(1)
        OUT6  : out std_logic; -- VGA_GREEN(2)
        OUT7  : out std_logic  -- VGA_GREEN(3)
    );
end color_decoder;

architecture Behavioral of color_decoder is

    -- Internal signals for mode decoding
    signal M1, M2, M4, M8 : std_logic;

    -- Internal signals for 1-bit mode
    signal SEL_D1 : std_logic;

    -- Internal signals for 2-bit mode
    signal C0, C1 : std_logic;

    -- Internal signals for 4-bit mode
    signal X0, X1, X2, X3 : std_logic;

    -- Internal signals for 4-bit palette
    signal R1_4, R2_4, R3_4 : std_logic;
    signal B2_4, B3_4       : std_logic;
    signal G1_4, G2_4, G3_4 : std_logic;

begin

    ------------------------------------------------------------
    -- MODE DECODING
    ------------------------------------------------------------
    M1 <= (NOT MODE1) AND (NOT MODE0);
    M2 <= (NOT MODE1) AND MODE0;
    M4 <= MODE1 AND (NOT MODE0);
    M8 <= MODE1 AND MODE0;

    ------------------------------------------------------------
    -- 1-BIT MODE LOGIC
    -- SEL2:SEL0 selects one of D0-D7. The selected bit is replicated.
    ------------------------------------------------------------
    SEL_D1 <= (D7 AND (NOT SEL2) AND (NOT SEL1) AND (NOT SEL0)) OR
              (D6 AND (NOT SEL2) AND (NOT SEL1) AND SEL0) OR
              (D5 AND (NOT SEL2) AND SEL1 AND (NOT SEL0)) OR
              (D4 AND (NOT SEL2) AND SEL1 AND SEL0) OR
              (D3 AND SEL2 AND (NOT SEL1) AND (NOT SEL0)) OR
              (D2 AND SEL2 AND (NOT SEL1) AND SEL0) OR
              (D1 AND SEL2 AND SEL1 AND (NOT SEL0)) OR
              (D0 AND SEL2 AND SEL1 AND SEL0);

    ------------------------------------------------------------
    -- 2-BIT MODE LOGIC
    -- SEL1:SEL0 selects one of four 2-bit values.
    ------------------------------------------------------------
    C0 <= (D6 AND (NOT SEL2) AND (NOT SEL1)) OR
          (D4 AND (NOT SEL2) AND SEL1) OR
          (D2 AND SEL2 AND (NOT SEL1)) OR
          (D0 AND SEL2 AND SEL1);

    C1 <= (D7 AND (NOT SEL2) AND (NOT SEL1)) OR
          (D5 AND (NOT SEL2) AND SEL1) OR
          (D3 AND SEL2 AND (NOT SEL1)) OR
          (D1 AND SEL2 AND SEL1);

    ------------------------------------------------------------
    -- 4-BIT MODE LOGIC
    -- SEL0 selects which nibble is used.
    ------------------------------------------------------------
/*
    | Hex | Color          | Red   | Green | Blue |
    |-----|----------------| ------|-------|------|
    | `0` | Black          | `000` | `000` | `00` |
    | `1` | Blue           | `000` | `000` | `11` |
    | `2` | Green          | `000` | `111` | `00` |
    | `3` | Cyan           | `000` | `111` | `11` |
    | `4` | Red            | `111` | `000` | `00` |
    | `5` | Magenta        | `111` | `000` | `11` |
    | `6` | Brown          | `101` | `011` | `00` |
    | `7` | Light Gray     | `101` | `101` | `01` |
    | `8` | Dark Gray      | `010` | `010` | `01` |
    | `9` | Bright Blue    | `010` | `010` | `11` |
    | `A` | Bright Green   | `010` | `111` | `00` |
    | `B` | Bright Cyan    | `010` | `111` | `11` |
    | `C` | Bright Red     | `111` | `010` | `00` |
    | `D` | Bright Magenta | `111` | `010` | `11` |
    | `E` | Yellow         | `111` | `111` | `00` |
    | `F` | White          | `111` | `111` | `11` |
*/

    X0 <= (D0 AND SEL2) OR (D4 AND (NOT SEL2));
    X1 <= (D1 AND SEL2) OR (D5 AND (NOT SEL2));
    X2 <= (D2 AND SEL2) OR (D6 AND (NOT SEL2));
    X3 <= (D3 AND SEL2) OR (D7 AND (NOT SEL2));

    ------------------------------------------------------------
    -- 4-BIT PALETTE LOGIC
    ------------------------------------------------------------
    -- RED
    R1_4 <= X2;
    R2_4 <= X3 OR (X2 AND (NOT X1));
    R3_4 <= X2;

    -- BLUE
    B2_4 <= (X0 AND X3) OR (X0 AND (NOT X1)) OR (X0 AND (NOT X2));
    B3_4 <= X0 OR (X3 AND (NOT X1) AND (NOT X2));

    -- GREEN
    G1_4 <= X1;
    G2_4 <= X1 OR X3;
    G3_4 <= (X1 AND X3) OR (X1 AND (NOT X2));

    ------------------------------------------------------------
    -- FINAL VGA OUTPUTS
    ------------------------------------------------------------
    -- Red Outputs
    OUT0 <= (M1 AND SEL_D1) OR (M2 AND C1) OR (M4 AND R1_4) OR (M8 AND D0);
    OUT1 <= (M1 AND SEL_D1) OR (M2 AND C1) OR (M4 AND R2_4) OR (M8 AND D1);
    OUT2 <= (M1 AND SEL_D1) OR (M2 AND C1) OR (M4 AND R3_4) OR (M8 AND D2);

    -- Blue Outputs
    OUT3 <= (M1 AND SEL_D1) OR (M2 AND C0) OR (M4 AND B2_4) OR (M8 AND D3);
    OUT4 <= (M1 AND SEL_D1) OR (M2 AND C0) OR (M4 AND B3_4) OR (M8 AND D4);

    -- Green Outputs
    OUT5 <= (M1 AND SEL_D1) OR (M2 AND C1) OR (M4 AND G1_4) OR (M8 AND D5);
    OUT6 <= (M1 AND SEL_D1) OR (M2 AND C1) OR (M4 AND G2_4) OR (M8 AND D6);
    OUT7 <= (M1 AND SEL_D1) OR (M2 AND C1) OR (M4 AND G3_4) OR (M8 AND D7);

end Behavioral;
