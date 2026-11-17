-- @file ATF22V10_COLORDECODER.vhd
-- @brief 8-bit pixel-pack color decoder (VHDL conversion of src/pld/rev_b/ATF22V10_COLORDECODER.pld, rev 09)
--
-- Date: 11/17/2026
--
-- Rev B board only; the rev A board is color_decoder.vhd, rev 08.  Revision 09:
-- on a 160-read line the Sync PLD puts H1 on the H2 pin and H0 on the H1 pin, so
-- a byte is shown in 4 clocks.  The gray blends use H2 and H1 alone (quarters):
-- x21 H1, x6B H2 & H1, x8C H2 # H1, xB5 H2 & H1 (was 1 of 8), xD6 H1.
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
--    8 bpp : H ignored, except in the five gray  (8 clocks per pixel)
--            codes below, where H2:H0 blends blue
--
-- OUTPUTS (resistor DAC, bit 3 = MSB of each channel)
--    RED1..RED3 = R LSB..MSB   (3 bits)
--    GRN1..GRN3 = G LSB..MSB   (3 bits)
--    BLU2..BLU3 = B LSB..MSB   (2 bits)
--
-- 8 bpp pass-through byte format (D7..D0) = G3 G2 G1 B3 B2 R3 R2 R1
--
-- 8 bpp GRAYS (revision 08).  Blue has only two DAC bits, so for five codes
-- with R = G the decoder switches blue between two neighboring DAC levels
-- during the pixel's 8 clocks, so that its average matches red and green.
-- Blue DAC levels (BLU3 BLU2): 00 = 0, 01 = 227, 10 = 453, 11 = 680 mV.
--
--    Gray  Byte  R=G  B   R,G mV   Blue per clock H = 0..7        Blue mV
--     0    x00    0   0      0     steady 00                         0
--     1    x21    1   0     98     00 01 00 01 00 01 00 01         113
--     2    x4A    2   1    202     steady 01 (not blended)         227
--     3    x6B    3   1    300     01 01 01 10 01 01 01 10         284
--     4    x8C    4   1    394     01 10 10 10 01 10 10 10         397
--     5    xB5    5   2    492     10 10 10 10 10 10 10 11         481
--     6    xD6    6   2    596     10 11 10 11 10 11 10 11         567
--     7    xFF    7   3    694     steady 11                       680
--
-- BLU2 reads the BLU3, GRN1 and GRN2 pins back (the PLD's PIN NOTES say why).
-- In VHDL an output port cannot be read, so blu3Int, grn1Int and grn2Int
-- carry those values internally, as GRN3_INT does for GRN3.
--
-- GRN3 computes the 1 bpp pixel mux itself (in 1 bpp mode GRN3 = the selected
-- pixel) and the other seven outputs use GRN3.  In VHDL an output port cannot
-- be read, so GRN3_INT carries the GRN3 value internally.
-------------------------------------------------------------------------------
library ieee;       use ieee.std_logic_1164.all;

entity color_decoder_revb is
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
end entity color_decoder_revb;

architecture rtl of color_decoder_revb is

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

    -- 8 bpp blended gray codes
    signal gray1    : std_logic;
    signal gray3    : std_logic;
    signal gray4    : std_logic;
    signal gray5    : std_logic;
    signal gray6    : std_logic;

    -- internal copies of BLU3, GRN1 and GRN2 (read back by BLU2)
    signal blu3Int  : std_logic;
    signal grn1Int  : std_logic;
    signal grn2Int  : std_logic;

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
    -- 8 bpp: blended gray codes
    ---------------------------------------------------------------------------
    gray1 <= M8 and (not D7) and (not D6) and (    D5) and (not D4) and (not D3) and (not D2) and (not D1) and (    D0);   -- x21
    gray3 <= M8 and (not D7) and (    D6) and (    D5) and (not D4) and (    D3) and (not D2) and (    D1) and (    D0);   -- x6B
    gray4 <= M8 and (    D7) and (not D6) and (not D5) and (not D4) and (    D3) and (    D2) and (not D1) and (not D0);   -- x8C
    gray5 <= M8 and (    D7) and (not D6) and (    D5) and (    D4) and (not D3) and (    D2) and (not D1) and (    D0);   -- xB5
    gray6 <= M8 and (    D7) and (    D6) and (not D5) and (    D4) and (not D3) and (    D2) and (    D1) and (not D0);   -- xD6


    ---------------------------------------------------------------------------
    -- FINAL OUTPUTS
    ---------------------------------------------------------------------------
    RED1 <= (M1 and GRN3_INT) or (M2 and C1) or (M4 and RED1_4) or (M8 and D0);
    RED2 <= (M1 and GRN3_INT) or (M2 and C1) or (M4 and RED2_4) or (M8 and D1);
    RED3 <= (M1 and GRN3_INT) or (M2 and C1) or (M4 and RED3_4) or (M8 and D2);

    -- BLU3: revision 07 terms, plus the blends up from blue = 01
    blu3Int <= (M1 and GRN3_INT) or (M2 and C0) or (M4 and BLU3_4) or (M8 and D4)
            or (gray3 and H2 and H1)                        -- 1 of 4
            or (gray4 and H2) or (gray4 and H1);            -- 3 of 4

    BLU3 <= blu3Int;

    -- BLU2: reads BLU3, GRN1 and GRN2 back
    BLU2 <= (M1 and GRN3_INT)
         or ((not MODE1) and MODE0 and blu3Int)             -- 2 bpp
         or (M4 and (not X3) and X0)                        -- 4 bpp indexes 1, 3, 5, 7
         or (MODE1 and (not MODE0) and grn2Int and grn1Int and blu3Int)   -- 4 bpp indexes 8, A
         or (M8 and D3 and D4)                              -- 8 bpp blue = 11
         or (M8 and D3 and (not blu3Int))                   -- 8 bpp blue = 01, off while BLU3 blends
         or (gray1 and H1)                                  -- 2 of 4
         or (gray5 and H2 and H1)                           -- 1 of 4
         or (gray6 and H1);                                 -- 2 of 4

    grn1Int <= (M1 and GRN3_INT) or (M2 and C1) or (M2 and C0) or (M4 and GRN1_4) or (M8 and D5);
    grn2Int <= (M1 and GRN3_INT) or (M2 and C1 and C0) or (M4 and GRN2_4) or (M8 and D6);

    GRN1 <= grn1Int;
    GRN2 <= grn2Int;

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
