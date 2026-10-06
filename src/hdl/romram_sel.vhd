-- ============================================================
-- ROM / RAM SECTION SELECT
-- VHDL conversion of ATF22V10_ROMRAM_SEL.pld (revision 02)
-- Date: 10/05/2026
--
-- The 64K address space is split into 8 sections of 8K,
-- selected by A15:A13.  Eight registers hold the map:
--     ramselN = 0 -> section N is ROM
--     ramselN = 1 -> section N is RAM
--
-- rw = 1 is a read, rw = 0 is a write.
-- rom_en = (section is ROM) and rw
-- The RAM enable is the inverse of rom_en (external inverter).
--
-- The map loads from d7..d0 on the rising edge of wr_clk.
-- Registers power up to 0 (all sections ROM), as on the
-- ATF22V10C.
--
-- Pin assignments (ATF22V10C):
--   1  wr_clk     2  a15      3  a14      4  a13
--   5  d0         6  d1       7  d2       8  d3
--   9  d4        10  d5      11  d6      13  d7
--  14  rom_en    15  ramsel0 16  ramsel1 17  ramsel2
--  18  ramsel3   19  ramsel4 20  ramsel5 21  ramsel6
--  22  ramsel7   23  rw
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity romram_sel is
    port (
        wr_clk  : in  std_logic;   -- pin 1
        a15     : in  std_logic;   -- pin 2
        a14     : in  std_logic;   -- pin 3
        a13     : in  std_logic;   -- pin 4
        d0      : in  std_logic;   -- pin 5
        d1      : in  std_logic;   -- pin 6
        d2      : in  std_logic;   -- pin 7
        d3      : in  std_logic;   -- pin 8
        d4      : in  std_logic;   -- pin 9
        d5      : in  std_logic;   -- pin 10
        d6      : in  std_logic;   -- pin 11
        d7      : in  std_logic;   -- pin 13
        rw      : in  std_logic;   -- pin 23, 1 = read, 0 = write

        rom_en  : out std_logic;   -- pin 14
        ramsel0 : out std_logic;   -- pin 15
        ramsel1 : out std_logic;   -- pin 16
        ramsel2 : out std_logic;   -- pin 17
        ramsel3 : out std_logic;   -- pin 18
        ramsel4 : out std_logic;   -- pin 19
        ramsel5 : out std_logic;   -- pin 20
        ramsel6 : out std_logic;   -- pin 21
        ramsel7 : out std_logic    -- pin 22
    );
end entity romram_sel;

architecture rtl of romram_sel is

    -- stored map registers (power up to 0)
    signal ramsel0_q : std_logic := '0';
    signal ramsel1_q : std_logic := '0';
    signal ramsel2_q : std_logic := '0';
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

begin

    -- ---------------- stored map ----------------

    process (wr_clk)
    begin
        if rising_edge(wr_clk) then
            ramsel0_q <= d0;
            ramsel1_q <= d1;
            ramsel2_q <= d2;
            ramsel3_q <= d3;
            ramsel4_q <= d4;
            ramsel5_q <= d5;
            ramsel6_q <= d6;
            ramsel7_q <= d7;
        end if;
    end process;

    ramsel0 <= ramsel0_q;
    ramsel1 <= ramsel1_q;
    ramsel2 <= ramsel2_q;
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

    -- ---------------- rom enable ----------------

    rom_en <= (sec0 and (not ramsel0_q) and rw)
           or (sec1 and (not ramsel1_q) and rw)
           or (sec2 and (not ramsel2_q) and rw)
           or (sec3 and (not ramsel3_q) and rw)
           or (sec4 and (not ramsel4_q) and rw)
           or (sec5 and (not ramsel5_q) and rw)
           or (sec6 and (not ramsel6_q) and rw)
           or (sec7 and (not ramsel7_q) and rw);

end architecture rtl;
