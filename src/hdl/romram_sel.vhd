-- ============================================================
-- ROM / RAM SECTION SELECT
-- VHDL conversion of ATF22V10_ROMRAM_SEL.pld (revision 03)
-- Date: 10/15/2026
--
-- The 64K address space is split into 8 sections of 8K,
-- selected by A15:A13.  Seven registers hold the map:
--     ramselN = 0 -> section N is ROM
--     ramselN = 1 -> section N is RAM
-- Section 2 has no map bit: 4000h-4FFFh is always RAM and
-- 5000h-5FFFh is the I/O window (neither memory reads there).
--
-- rw = 1 is a read, rw = 0 is a write.
-- rom_oe_n = low for a read of a ROM section    (ROM /OE)
-- ram_oe_n = low for a read of a RAM section,   (RAM /OE)
--            not the I/O window
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
--   1  wr_clk     2  a15      3  a14      4  a13      5  a12
--   6  d0         7  d1       8  d3       9  d4      10  d5
--  11  d6        13  d7      23  rw
--  14  rom_oe_n  15  ram_oe_n
--  16  ramsel0   17  ramsel1 18  ramsel3 19  ramsel4
--  20  ramsel5   21  ramsel6 22  ramsel7
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity romram_sel_pld is
    port (
        wr_clk   : in  std_logic;   -- pin 1, /MAP_WR
        a15      : in  std_logic;   -- pin 2
        a14      : in  std_logic;   -- pin 3
        a13      : in  std_logic;   -- pin 4
        a12      : in  std_logic;   -- pin 5
        d0       : in  std_logic;   -- pin 6
        d1       : in  std_logic;   -- pin 7
        d3       : in  std_logic;   -- pin 8
        d4       : in  std_logic;   -- pin 9
        d5       : in  std_logic;   -- pin 10
        d6       : in  std_logic;   -- pin 11
        d7       : in  std_logic;   -- pin 13
        rw       : in  std_logic;   -- pin 23, 1 = read, 0 = write

        rom_oe_n : out std_logic;   -- pin 14, active low
        ram_oe_n : out std_logic;   -- pin 15, active low
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

    -- section decode
    signal sec0 : std_logic;
    signal sec1 : std_logic;
    signal sec2 : std_logic;
    signal sec3 : std_logic;
    signal sec4 : std_logic;
    signal sec5 : std_logic;
    signal sec6 : std_logic;
    signal sec7 : std_logic;

    signal rom_oe : std_logic;
    signal ram_oe : std_logic;

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

    -- ---------------- section decode ----------------

    sec0 <= (not a15) and (not a14) and (not a13);
    sec1 <= (not a15) and (not a14) and (    a13);
    sec2 <= (not a15) and (    a14) and (not a13);
    sec3 <= (not a15) and (    a14) and (    a13);
    sec4 <= (    a15) and (not a14) and (not a13);
    sec5 <= (    a15) and (not a14) and (    a13);
    sec6 <= (    a15) and (    a14) and (not a13);
    sec7 <= (    a15) and (    a14) and (    a13);

    -- ---------------- read enables ----------------

    rom_oe <= (sec0 and (not ramsel0_q) and rw)
           or (sec1 and (not ramsel1_q) and rw)
           or (sec3 and (not ramsel3_q) and rw)
           or (sec4 and (not ramsel4_q) and rw)
           or (sec5 and (not ramsel5_q) and rw)
           or (sec6 and (not ramsel6_q) and rw)
           or (sec7 and (not ramsel7_q) and rw);

    ram_oe <= (sec0 and ramsel0_q and rw)
           or (sec1 and ramsel1_q and rw)
           or (sec2 and (not a12) and rw)
           or (sec3 and ramsel3_q and rw)
           or (sec4 and ramsel4_q and rw)
           or (sec5 and ramsel5_q and rw)
           or (sec6 and ramsel6_q and rw)
           or (sec7 and ramsel7_q and rw);

    rom_oe_n <= not rom_oe;
    ram_oe_n <= not ram_oe;

end architecture rtl;
