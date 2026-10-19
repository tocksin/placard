-- ============================================================
-- IO_DECODE  (VHDL conversion of ATF22V10_IO_DECODE.pld, Rev 04)
-- Date: 10/19/2026
--
-- Rev 02: comments only.  map_wr_n clocks the 74ACT273 map register.
-- Rev 03: the I/O window is 5000h-53FFh.  Pin 18 (was snd_wr_n, unused)
-- is the a11 input; exp1_n and exp2_n moved to pages 1 and 3.
-- Rev 04: pin 23 is load_imm_n, active low, as the State PLD (Rev 13)
-- now drives it; the equations still use load_imm as logical true.
--
-- I/O decode for 5000h-53FFh and the upper 32K chip enable.
--
-- ce_hi_n is !A15, with A15 rebuilt from the high-byte address
-- mux selects and sources so it settles with the mux output:
--     addr_sel addr_sel_hi : 00 -> 0, 01 -> y7, 10 -> h9, 11 -> pc15
--
-- I/O pages (A11 = A10 = 0):
--     0  map_wr_n, line_rd_n     1  exp1_n
--     2  port_wr_n, port_rd_n    3  exp2_n
-- Writes are low with /WE; reads are low with LOAD_IMM.
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- Pin assignments (ATF22V10C):
--   1  we_n        2  addr_sel    3  addr_sel_hi  4  pc15
--   5  h9          6  y7          7  a14          8  a13
--   9  a12        10  a10        11  a9          13  a8
--  14  rw         18  a11        23  load_imm_n
--  15  ce_hi_n    16  map_wr_n   17  line_rd_n
--  19  port_wr_n  20  port_rd_n  21  exp1_n      22  exp2_n
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity io_decode_pld is
    port (
        we_n        : in  std_logic;   -- pin 1, RAM /WE
        addr_sel    : in  std_logic;   -- pin 2, mux S1
        addr_sel_hi : in  std_logic;   -- pin 3, high-byte mux S0
        pc15        : in  std_logic;   -- pin 4
        h9          : in  std_logic;   -- pin 5, video address bit 15
        y7          : in  std_logic;   -- pin 6
        a14         : in  std_logic;   -- pin 7
        a13         : in  std_logic;   -- pin 8
        a12         : in  std_logic;   -- pin 9
        a10         : in  std_logic;   -- pin 10
        a9          : in  std_logic;   -- pin 11
        a8          : in  std_logic;   -- pin 13
        rw          : in  std_logic;   -- pin 14, 1 = read, 0 = write
        a11         : in  std_logic;   -- pin 18 (rev 03, was snd_wr_n)
        load_imm_n  : in  std_logic;   -- pin 23, State PLD D-register strobe, low = load

        ce_hi_n     : out std_logic;   -- pin 15
        map_wr_n    : out std_logic;   -- pin 16
        line_rd_n   : out std_logic;   -- pin 17
        port_wr_n   : out std_logic;   -- pin 19
        port_rd_n   : out std_logic;   -- pin 20
        exp1_n      : out std_logic;   -- pin 21
        exp2_n      : out std_logic    -- pin 22
    );
end entity io_decode_pld;

architecture rtl of io_decode_pld is

    signal a15   : std_logic;
    signal load_imm : std_logic;   -- pin 23 as logical true (Rev 04)
    signal io    : std_logic;
    signal page0 : std_logic;
    signal page1 : std_logic;
    signal page2 : std_logic;
    signal page3 : std_logic;
    signal wr    : std_logic;
    signal rd    : std_logic;

begin

    load_imm <= not load_imm_n;

    -- A15, rebuilt from the mux inputs
    a15 <= ((not addr_sel) and addr_sel_hi and y7)
        or (addr_sel and (not addr_sel_hi) and h9)
        or (addr_sel and addr_sel_hi and pc15);

    -- I/O window and pages
    io    <= (not a15) and a14 and (not a13) and a12 and (not a11) and (not a10);

    page0 <= (not a10) and (not a9) and (not a8);
    page1 <= (not a10) and (not a9) and (    a8);
    page2 <= (not a10) and (    a9) and (not a8);
    page3 <= (not a10) and (    a9) and (    a8);

    wr    <= io and (not we_n);
    rd    <= io and rw and load_imm;

    -- outputs (pins are active low)
    ce_hi_n   <= not a15;
    map_wr_n  <= not (wr and page0);
    line_rd_n <= not (rd and page0);
    port_wr_n <= not (wr and page2);
    port_rd_n <= not (rd and page2);
    exp1_n    <= not (io and page1);
    exp2_n    <= not (io and page3);

end architecture rtl;
