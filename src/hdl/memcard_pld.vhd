--------------------------------------------------------------------------------
-- Name     MEMCARD
-- PartNo   00
-- Date     11/16/2026
-- Revision 01
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_MEMCARD.pld (Revision 01)
--
-- The page register of the 32K memory expansion card
-- (docs/architecture/MEMCARD.md).  The card's SRAM is wired straight to
-- the slot (/CE = /EXP, /OE = Q0, /WE = /WE, A6:A0, D7:D0); this chip
-- holds the SRAM's upper address A14:A7 as an 8-bit page number.
--
--   - The eight registers clock on the rising edge of /WE (pin 1, the
--     register clock), the end of every write.  They load D7:D0 when the
--     write is to the card's offsets 78h-7Fh (/EXP low and A6:A3 = 1111)
--     and hold their value on every other /WE.
--   - They clear at power-up, so the card starts at page 0.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = WE                (ACTIVE LOW, register clock; slot B24)
--   PIN 2  = EXP               (ACTIVE LOW, the slot's select; slot A16)
--   PIN 3  = D0
--   PIN 4  = D1
--   PIN 5  = D2
--   PIN 6  = D3
--   PIN 7  = D4
--   PIN 8  = D5
--   PIN 9  = D6
--   PIN 10 = D7
--   PIN 11 = A6
--   PIN 13 = A5
--   PIN 14 = A4
--   PIN 15 = A3
--   PIN 16 = PG7               (register, SRAM A14)
--   PIN 17 = PG6               (register, SRAM A13)
--   PIN 18 = PG5               (register, SRAM A12)
--   PIN 19 = PG4               (register, SRAM A11)
--   PIN 20 = PG3               (register, SRAM A10)
--   PIN 21 = PG2               (register, SRAM A9)
--   PIN 22 = PG1               (register, SRAM A8)
--   PIN 23 = PG0               (register, SRAM A7)
--   Unused: none
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity memcard_pld is
    port (
        weN  : in  std_logic;   -- pin 1, active low, register clock
        expN : in  std_logic;   -- pin 2, active low
        d0   : in  std_logic;   -- pin 3
        d1   : in  std_logic;   -- pin 4
        d2   : in  std_logic;   -- pin 5
        d3   : in  std_logic;   -- pin 6
        d4   : in  std_logic;   -- pin 7
        d5   : in  std_logic;   -- pin 8
        d6   : in  std_logic;   -- pin 9
        d7   : in  std_logic;   -- pin 10
        a6   : in  std_logic;   -- pin 11
        a5   : in  std_logic;   -- pin 13
        a4   : in  std_logic;   -- pin 14
        a3   : in  std_logic;   -- pin 15

        pg7  : out std_logic;   -- pin 16
        pg6  : out std_logic;   -- pin 17
        pg5  : out std_logic;   -- pin 18
        pg4  : out std_logic;   -- pin 19
        pg3  : out std_logic;   -- pin 20
        pg2  : out std_logic;   -- pin 21
        pg1  : out std_logic;   -- pin 22
        pg0  : out std_logic    -- pin 23
    );
end entity memcard_pld;

architecture rtl of memcard_pld is

    signal expSel  : std_logic;
    signal pageSel : std_logic;

    -- the registers, as the PLD holds them (cleared at power-up)
    signal pg0Reg  : std_logic := '0';
    signal pg1Reg  : std_logic := '0';
    signal pg2Reg  : std_logic := '0';
    signal pg3Reg  : std_logic := '0';
    signal pg4Reg  : std_logic := '0';
    signal pg5Reg  : std_logic := '0';
    signal pg6Reg  : std_logic := '0';
    signal pg7Reg  : std_logic := '0';

begin

    expSel  <= not expN;
    pageSel <= expSel and a6 and a5 and a4 and a3;     -- PAGE_SEL = EXP & A6 & A5 & A4 & A3

    -- Page register: loads the data bus on a page write, and holds on
    -- every other /WE.  The clock is pin 1, /WE: its rising edge.
    regProc : process (weN)
    begin
        if rising_edge(weN) then
            pg0Reg <= (pageSel and d0) or ((not pageSel) and pg0Reg);   -- PG0.D = PAGE_SEL & D0 # !PAGE_SEL & PG0
            pg1Reg <= (pageSel and d1) or ((not pageSel) and pg1Reg);   -- PG1.D = PAGE_SEL & D1 # !PAGE_SEL & PG1
            pg2Reg <= (pageSel and d2) or ((not pageSel) and pg2Reg);   -- PG2.D = PAGE_SEL & D2 # !PAGE_SEL & PG2
            pg3Reg <= (pageSel and d3) or ((not pageSel) and pg3Reg);   -- PG3.D = PAGE_SEL & D3 # !PAGE_SEL & PG3
            pg4Reg <= (pageSel and d4) or ((not pageSel) and pg4Reg);   -- PG4.D = PAGE_SEL & D4 # !PAGE_SEL & PG4
            pg5Reg <= (pageSel and d5) or ((not pageSel) and pg5Reg);   -- PG5.D = PAGE_SEL & D5 # !PAGE_SEL & PG5
            pg6Reg <= (pageSel and d6) or ((not pageSel) and pg6Reg);   -- PG6.D = PAGE_SEL & D6 # !PAGE_SEL & PG6
            pg7Reg <= (pageSel and d7) or ((not pageSel) and pg7Reg);   -- PG7.D = PAGE_SEL & D7 # !PAGE_SEL & PG7
        end if;
    end process regProc;

    pg0 <= pg0Reg;
    pg1 <= pg1Reg;
    pg2 <= pg2Reg;
    pg3 <= pg3Reg;
    pg4 <= pg4Reg;
    pg5 <= pg5Reg;
    pg6 <= pg6Reg;
    pg7 <= pg7Reg;

end architecture rtl;
