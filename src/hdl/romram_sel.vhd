-- ============================================================
-- ROM / RAM SECTION SELECT
-- VHDL conversion of ATF22V10_ROMRAM_SEL.pld (revision 04)
-- Date: 10/15/2026
--
-- The 64K address space is split into 8 sections of 8K,
-- selected by A15:A13.  Seven registers hold the map:
--     ramselN = 0 -> section N is ROM
--     ramselN = 1 -> section N is RAM
-- Section 2 has no map bit: 4000h-4FFFh is always RAM and
-- 5000h-5FFFh is the I/O window.
--
-- Revision 04: the ROM and RAM read enables moved to the memory
-- control PLD (mem_ctrl_pld), which takes the ramsel outputs.
-- This PLD only holds the map.
--
-- The map loads from d7..d0 (source bus, d2 unused) on the
-- rising edge of wr_clk (/MAP_WR from the I/O decode PLD).
-- Registers power up to 0 (all mapped sections ROM), as on the
-- ATF22V10C.
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- Pin assignments (ATF22V10C):
--   1  wr_clk
--   6  d0         7  d1       8  d3       9  d4      10  d5
--  11  d6        13  d7
--  16  ramsel0   17  ramsel1 18  ramsel3 19  ramsel4
--  20  ramsel5   21  ramsel6 22  ramsel7
--   2-5, 14, 15, 23 not used
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity romram_sel_pld is
    port (
        wr_clk   : in  std_logic;   -- pin 1, /MAP_WR
        d0       : in  std_logic;   -- pin 6
        d1       : in  std_logic;   -- pin 7
        d3       : in  std_logic;   -- pin 8
        d4       : in  std_logic;   -- pin 9
        d5       : in  std_logic;   -- pin 10
        d6       : in  std_logic;   -- pin 11
        d7       : in  std_logic;   -- pin 13

        ramsel0  : out std_logic;   -- pin 16
        ramsel1  : out std_logic;   -- pin 17
        ramsel3  : out std_logic;   -- pin 18
        ramsel4  : out std_logic;   -- pin 19
        ramsel5  : out std_logic;   -- pin 20
        ramsel6  : out std_logic;   -- pin 21
        ramsel7  : out std_logic    -- pin 22
    );
end entity romram_sel_pld;

architecture rtl of romram_sel_pld is

    -- stored map registers (power up to 0)
    signal ramsel0_q : std_logic := '0';
    signal ramsel1_q : std_logic := '0';
    signal ramsel3_q : std_logic := '0';
    signal ramsel4_q : std_logic := '0';
    signal ramsel5_q : std_logic := '0';
    signal ramsel6_q : std_logic := '0';
    signal ramsel7_q : std_logic := '0';

begin

    -- ---------------- stored map ----------------

    process (wr_clk)
    begin
        if rising_edge(wr_clk) then
            ramsel0_q <= d0;
            ramsel1_q <= d1;
            ramsel3_q <= d3;
            ramsel4_q <= d4;
            ramsel5_q <= d5;
            ramsel6_q <= d6;
            ramsel7_q <= d7;
        end if;
    end process;

    ramsel0 <= ramsel0_q;
    ramsel1 <= ramsel1_q;
    ramsel3 <= ramsel3_q;
    ramsel4 <= ramsel4_q;
    ramsel5 <= ramsel5_q;
    ramsel6 <= ramsel6_q;
    ramsel7 <= ramsel7_q;

end architecture rtl;
