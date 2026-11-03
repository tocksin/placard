-- ============================================================
-- IO_DECODE  (VHDL conversion of ATF22V10_IO_DECODE.pld, Rev 07)
-- Date: 11/03/2026
--
-- Rev 07 (docs/architecture/EXPANSION.md, "Card timing"): the I/O
-- selects are decoded from the Y register (y7..y0), the address mux
-- selects and x7, not from the mux output, so they are valid with the
-- address (13 ns) instead of one PLD pass later.  The outputs are
-- address-only selects: p0_n (page 0, was line_rd_n), port_n (page 2,
-- was port_rd_n) and one select per slot, exp1_n..exp4_n (x7 picks
-- the 128-byte half).  map_wr_n moved to the Sync PLD (Rev 12); the
-- port and PS/2 PLDs make their own strobes from port_n, /WE and q0.
-- Inputs a14..a8, a11, we_n and q0 are gone; pin 1 is unused.
-- Rev 06: pin 23 was q0, rd = io and LOAD_MEM.
-- Rev 05: A15 rebuilt from pixel_enable, pc_enable and y_enable.
-- Rev 03: the I/O window is 5000h-53FFh.
--
-- I/O decode for 5000h-53FFh and the upper 32K chip enable.
--
-- ce_hi_n is !A15, with A15 rebuilt from the high-byte address
-- mux selects and sources so it settles with the mux output:
--     pixel_enable -> h9, else pc_enable -> pc15, else y_enable -> y7, else 0
--
-- I/O selects (iosel = not pixel_enable, not pc_enable, y_enable,
-- Y = 0101 00xx):
--     5000h-50FFh  p0_n        5200h-52FFh  port_n
--     5100h-517Fh  exp1_n      5300h-537Fh  exp2_n
--     5180h-51FFh  exp3_n      5380h-53FFh  exp4_n
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- Pin assignments (ATF22V10C):
--   2  pixel_enable 3  pc_enable   4  pc15       5  h9
--   6  y7          7  y6          8  y5          9  y4
--  10  y2         11  y1         13  y0         14  y_enable
--  18  y3         23  x7
--  15  ce_hi_n    16  exp3_n     17  p0_n
--  19  exp4_n     20  port_n     21  exp1_n     22  exp2_n
--   Unused: pin 1
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity io_decode_pld is
    port (
        pixel_enable : in std_logic;   -- pin 2, Sync PLD PIXEL_ENABLE
        pc_enable   : in  std_logic;   -- pin 3, State PLD PC_ENABLE
        pc15        : in  std_logic;   -- pin 4
        h9          : in  std_logic;   -- pin 5, video address bit 15
        y7          : in  std_logic;   -- pin 6
        y6          : in  std_logic;   -- pin 7  (Rev 07, was a14)
        y5          : in  std_logic;   -- pin 8  (Rev 07, was a13)
        y4          : in  std_logic;   -- pin 9  (Rev 07, was a12)
        y2          : in  std_logic;   -- pin 10 (Rev 07, was a10)
        y1          : in  std_logic;   -- pin 11 (Rev 07, was a9)
        y0          : in  std_logic;   -- pin 13 (Rev 07, was a8)
        y_enable    : in  std_logic;   -- pin 14, State PLD Y_ENABLE
        y3          : in  std_logic;   -- pin 18 (Rev 07, was a11)
        x7          : in  std_logic;   -- pin 23 (Rev 07, was q0)

        ce_hi_n     : out std_logic;   -- pin 15
        exp3_n      : out std_logic;   -- pin 16 (Rev 07, was map_wr_n)
        p0_n        : out std_logic;   -- pin 17 (Rev 07, was line_rd_n)
        exp4_n      : out std_logic;   -- pin 19 (Rev 07, was port_wr_n)
        port_n      : out std_logic;   -- pin 20 (Rev 07, was port_rd_n)
        exp1_n      : out std_logic;   -- pin 21
        exp2_n      : out std_logic    -- pin 22
    );
end entity io_decode_pld;

architecture rtl of io_decode_pld is

    signal a15   : std_logic;
    signal iosel : std_logic;

begin

    -- A15, rebuilt from the mux inputs
    a15 <= (pixel_enable and h9)
        or ((not pixel_enable) and pc_enable and pc15)
        or ((not pixel_enable) and (not pc_enable) and y_enable and y7);

    -- I/O window from the Y register: Y = 50h - 53h
    iosel <= (not pixel_enable) and (not pc_enable) and y_enable
         and (not y7) and y6 and (not y5) and y4 and (not y3) and (not y2);

    -- outputs (pins are active low)
    ce_hi_n <= not a15;
    p0_n    <= not (iosel and (not y1) and (not y0));
    exp1_n  <= not (iosel and (not y1) and (    y0) and (not x7));
    exp3_n  <= not (iosel and (not y1) and (    y0) and (    x7));
    port_n  <= not (iosel and (    y1) and (not y0));
    exp2_n  <= not (iosel and (    y1) and (    y0) and (not x7));
    exp4_n  <= not (iosel and (    y1) and (    y0) and (    x7));

end architecture rtl;
