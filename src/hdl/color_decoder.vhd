-- @file ATF22V10_COLORDECODER.vhd
-- @brief 8-bit pixel-pack color decoder (VHDL conversion of ATF22V10_COLORDECODER.pld, rev 07)
--
-- Date: 10/16/2026
--
-- Direct conversion of the PLD equations: equations are not optimized and
-- every pin is kept as an individual std_logic port.
--
-- VIDEN = 0  ->  all outputs forced to BLACK (0), regardless of every other
--                input.   VIDEN = 1  ->  normal operation.
--
--    MODE1 MODE0   bits/pixel   pixels/byte   colors
--       0     0        1             8            2
--       0     1        2             4            4
--       1     0        4             2           16
--       1     1        8             1          256
--
-- H2:H0 is the pixel clock count within each 8-clock byte (from the Sync PLD).
-- Each mode uses only the H bits it needs, so a pixel is held for 1, 2, 4 or
-- 8 clocks:
--    1 bpp : H2:H0 -> D0..D7                       (1 clock per pixel)
--    2 bpp : H2:H1 -> D1:0 / D3:2 / D5:4 / D7:6    (2 clocks per pixel)
--    4 bpp : H2    -> D3:0 / D7:4                  (4 clocks per pixel)
--    8 bpp : H ignored                             (8 clocks per pixel)
--
-- OUTPUTS (resistor DAC, bit 3 = MSB of each channel)
--    RED1..RED3 = R LSB..MSB   (3 bits)
--    GRN1..GRN3 = G LSB..MSB   (3 bits)
--    BLU2..BLU3 = B LSB..MSB   (2 bits)
--
-- 8 bpp pass-through byte format (D7..D0) = G3 G2 G1 B3 B2 R3 R2 R1
--
-- GRN3 computes the 1 bpp pixel mux itself (in 1 bpp mode GRN3 = the selected
-- pixel) and the other seven outputs use GRN3.  In VHDL an output port cannot
-- be read, so GRN3_INT carries the GRN3 value internally.
-------------------------------------------------------------------------------
library ieee;       use ieee.std_logic_1164.all;

entity color_decoder is
    port(   -- inputs
            D0      : in    std_logic;   -- PIN 2
            D1      : in    std_logic;   -- PIN 3
            D2      : in    std_logic;   -- PIN 4
            D3      : in    std_logic;   -- PIN 5
            D4      : in    std_logic;   -- PIN 6
            D5      : in    std_logic;   -- PIN 7
            D6      : in    std_logic;   -- PIN 8
            D7      : in    std_logic;   -- PIN 9

            MODE0   : in    std_logic;   -- PIN 10
            MODE1   : in    std_logic;   -- PIN 11

            H0      : in    std_logic;   -- PIN 13
            H1      : in    std_logic;   -- PIN 1
            H2      : in    std_logic;   -- PIN 14

            VIDEN   : in    std_logic;   -- PIN 23, video enable, active high (low = black)

            -- outputs
            RED1    :   out std_logic;   -- PIN 15
            RED2    :   out std_logic;   -- PIN 16
            RED3    :   out std_logic;   -- PIN 21
            BLU2    :   out std_logic;   -- PIN 22
            BLU3    :   out std_logic;   -- PIN 18
            GRN1    :   out std_logic;   -- PIN 17
            GRN2    :   out std_logic;   -- PIN 20
            GRN3    :   out std_logic    -- PIN 19, also the 1 bpp pixel source
    );
end entity color_decoder;

architecture rtl of color_decoder is

    -- mode decode (gated by VIDEN)
    signal M1       : std_logic;
    signal M2       : std_logic;
    signal M4       : std_logic;
    signal M8       : std_logic;

    -- 2 bpp pixel
    signal C0       : std_logic;
    signal C1       : std_logic;

    -- 4 bpp nibble select
    signal X0       : std_logic;
    signal X1       : std_logic;
    signal X2       : std_logic;
    signal X3       : std_logic;

    -- 4 bpp palette
    signal RED1_4   : std_logic;
    signal RED2_4   : std_logic;
    signal RED3_4   : std_logic;
    signal BLU2_4   : std_logic;
    signal BLU3_4   : std_logic;
    signal GRN1_4   : std_logic;
    signal GRN2_4   : std_logic;
    signal GRN3_4   : std_logic;

    -- internal copy of GRN3 (output ports cannot be read)
    signal GRN3_INT : std_logic;

begin

    ---------------------------------------------------------------------------
    -- MODE DECODE (gated by VIDEN)
    ---------------------------------------------------------------------------
    M1 <= VIDEN and (not MODE1) and (not MODE0);
    M2 <= VIDEN and (not MODE1) and (    MODE0);
    M4 <= VIDEN and (    MODE1) and (not MODE0);
    M8 <= VIDEN and (    MODE1) and (    MODE0);


    ---------------------------------------------------------------------------
    -- 2 bpp: 4:1 mux of 2-bit pixel
    ---------------------------------------------------------------------------
    C0 <= (D0 and (not H2) and (not H1))
       or (D2 and (not H2) and (    H1))
       or (D4 and (    H2) and (not H1))
       or (D6 and (    H2) and (    H1));

    C1 <= (D1 and (not H2) and (not H1))
       or (D3 and (not H2) and (    H1))
       or (D5 and (    H2) and (not H1))
       or (D7 and (    H2) and (    H1));

    -- 2 bpp palette (high-contrast, color-blind safe, luminance ramp)
    --
    --  Code  Color   R  G  B    Luminance
    --   00   Black   0  0  0      0.00
    --   01   Blue    0  1  3      0.09
    --   10   Gold    7  5  0      0.55
    --   11   White   7  7  3      1.00
    --
    -- Per output bit (C1 = code bit 1, C0 = code bit 0):
    --    RED1..3 = C1              BLU2,3 = C0
    --    GRN1    = C1 | C0         GRN2   = C1 & C0  GRN3 = C1


    ---------------------------------------------------------------------------
    -- 4 bpp: nibble select
    ---------------------------------------------------------------------------
    X0 <= (D0 and (not H2)) or (D4 and H2);
    X1 <= (D1 and (not H2)) or (D5 and H2);
    X2 <= (D2 and (not H2)) or (D6 and H2);
    X3 <= (D3 and (not H2)) or (D7 and H2);

    -- 4 bpp palette: 16 colors (4 grays, 8 hues, dark/light variants).
    -- Black is index 0.  Channel levels: R,G = 0-7, B = 0-3.
    --
    -- Idx  Color        R  G  B
    --  0   Black        0  0  0
    --  1   Dark blue    0  0  1
    --  2   Purple       4  0  2
    --  3   Blue         0  0  3
    --  4   Red          7  0  0
    --  5   Magenta      7  0  3
    --  6   Brown        4  2  0
    --  7   Dark gray    2  2  1
    --  8   Cyan         0  7  3
    --  9   Dark green   0  4  0
    --  A   White        7  7  3
    --  B   Light gray   5  5  2
    --  C   Pink         7  4  2
    --  D   Orange       7  4  0
    --  E   Yellow       7  7  0
    --  F   Green        1  7  0

    RED1_4 <= (X2 and (not X1))
           or (X3 and X1);

    RED2_4 <= (X2 and (not X1))
           or ((not X3) and X2 and X0)
           or (X3 and X1 and (not X0));

    RED3_4 <= (X1 and (not X0))
           or (X2 and (not X1))
           or (X3 and (not X2) and X1);

    BLU2_4 <= ((not X3) and X0)
           or (X3 and (not X2) and (not X0));

    BLU3_4 <= ((not X2) and X1)
           or ((not X3) and X2 and (not X1) and X0)
           or (X3 and (not X1) and (not X0));

    GRN1_4 <= (X3 and (not X2) and (not X0))
           or (X3 and X1);

    GRN2_4 <= (X2 and X1)
           or (X3 and (not X2) and (not X0));

    GRN3_4 <= X3;


    ---------------------------------------------------------------------------
    -- FINAL OUTPUTS
    ---------------------------------------------------------------------------
    RED1 <= (M1 and GRN3_INT) or (M2 and C1) or (M4 and RED1_4) or (M8 and D0);
    RED2 <= (M1 and GRN3_INT) or (M2 and C1) or (M4 and RED2_4) or (M8 and D1);
    RED3 <= (M1 and GRN3_INT) or (M2 and C1) or (M4 and RED3_4) or (M8 and D2);

    BLU2 <= (M1 and GRN3_INT) or (M2 and C0) or (M4 and BLU2_4) or (M8 and D3);
    BLU3 <= (M1 and GRN3_INT) or (M2 and C0) or (M4 and BLU3_4) or (M8 and D4);

    GRN1 <= (M1 and GRN3_INT) or (M2 and C1) or (M2 and C0) or (M4 and GRN1_4) or (M8 and D5);
    GRN2 <= (M1 and GRN3_INT) or (M2 and C1 and C0) or (M4 and GRN2_4) or (M8 and D6);

    -- GRN3: 1 bpp 8:1 pixel mux written out (8 terms) + its own terms
    GRN3_INT <= (M1 and D0 and (not H2) and (not H1) and (not H0))
             or (M1 and D1 and (not H2) and (not H1) and (    H0))
             or (M1 and D2 and (not H2) and (    H1) and (not H0))
             or (M1 and D3 and (not H2) and (    H1) and (    H0))
             or (M1 and D4 and (    H2) and (not H1) and (not H0))
             or (M1 and D5 and (    H2) and (not H1) and (    H0))
             or (M1 and D6 and (    H2) and (    H1) and (not H0))
             or (M1 and D7 and (    H2) and (    H1) and (    H0))
             or (M2 and C1)
             or (M4 and GRN3_4)
             or (M8 and D7);

    GRN3 <= GRN3_INT;

end architecture rtl;
