--------------------------------------------------------------------------------
-- Name     MEMCARD_LO
-- PartNo   00
-- Date     11/16/2026
-- Revision 01
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_MEMCARD_LO.pld (Revision 01)
--
-- Page bits 7:0 of the 512K memory expansion card
-- (docs/architecture/MEMCARD.md): the SRAM's A14:A7.
--
--   - The eight registers clock on the rising edge of /WE (pin 1, the
--     register clock), the end of every write.  They load D7:D0 while
--     /PGLO is low (the page high PLD's decode of the card's offset 7Eh,
--     memcard_hi_pld.vhd) and hold their value on every other /WE.
--   - They clear at power-up, so the card starts at page 0.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = WE                (ACTIVE LOW, register clock; slot B24)
--   PIN 2  = PGLO              (ACTIVE LOW, page high PLD pin 16)
--   PIN 3  = D0
--   PIN 4  = D1
--   PIN 5  = D2
--   PIN 6  = D3
--   PIN 7  = D4
--   PIN 8  = D5
--   PIN 9  = D6
--   PIN 10 = D7
--   PIN 16 = PG7               (register, SRAM A14)
--   PIN 17 = PG6               (register, SRAM A13)
--   PIN 18 = PG5               (register, SRAM A12)
--   PIN 19 = PG4               (register, SRAM A11)
--   PIN 20 = PG3               (register, SRAM A10)
--   PIN 21 = PG2               (register, SRAM A9)
--   PIN 22 = PG1               (register, SRAM A8)
--   PIN 23 = PG0               (register, SRAM A7)
--   Unused: 11, 13, 14, 15
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity memcard_lo_pld is
    port (
        weN   : in  std_logic;   -- pin 1, active low, register clock
        pgLoN : in  std_logic;   -- pin 2, active low
        d0    : in  std_logic;   -- pin 3
        d1    : in  std_logic;   -- pin 4
        d2    : in  std_logic;   -- pin 5
        d3    : in  std_logic;   -- pin 6
        d4    : in  std_logic;   -- pin 7
        d5    : in  std_logic;   -- pin 8
        d6    : in  std_logic;   -- pin 9
        d7    : in  std_logic;   -- pin 10

        pg7   : out std_logic;   -- pin 16
        pg6   : out std_logic;   -- pin 17
        pg5   : out std_logic;   -- pin 18
        pg4   : out std_logic;   -- pin 19
        pg3   : out std_logic;   -- pin 20
        pg2   : out std_logic;   -- pin 21
        pg1   : out std_logic;   -- pin 22
        pg0   : out std_logic    -- pin 23
    );
end entity memcard_lo_pld;

architecture rtl of memcard_lo_pld is

    signal pgLo   : std_logic;

    -- the registers, as the PLD holds them (cleared at power-up)
    signal pg0Reg : std_logic := '0';
    signal pg1Reg : std_logic := '0';
    signal pg2Reg : std_logic := '0';
    signal pg3Reg : std_logic := '0';
    signal pg4Reg : std_logic := '0';
    signal pg5Reg : std_logic := '0';
    signal pg6Reg : std_logic := '0';
    signal pg7Reg : std_logic := '0';

begin

    pgLo <= not pgLoN;

    -- Page bits 7:0: load the data bus on a write to offset 7Eh, and hold
    -- on every other /WE.  The clock is pin 1, /WE: its rising edge.
    regProc : process (weN)
    begin
        if rising_edge(weN) then
            pg0Reg <= (pgLo and d0) or ((not pgLo) and pg0Reg);   -- PG0.D = PGLO & D0 # !PGLO & PG0
            pg1Reg <= (pgLo and d1) or ((not pgLo) and pg1Reg);   -- PG1.D = PGLO & D1 # !PGLO & PG1
            pg2Reg <= (pgLo and d2) or ((not pgLo) and pg2Reg);   -- PG2.D = PGLO & D2 # !PGLO & PG2
            pg3Reg <= (pgLo and d3) or ((not pgLo) and pg3Reg);   -- PG3.D = PGLO & D3 # !PGLO & PG3
            pg4Reg <= (pgLo and d4) or ((not pgLo) and pg4Reg);   -- PG4.D = PGLO & D4 # !PGLO & PG4
            pg5Reg <= (pgLo and d5) or ((not pgLo) and pg5Reg);   -- PG5.D = PGLO & D5 # !PGLO & PG5
            pg6Reg <= (pgLo and d6) or ((not pgLo) and pg6Reg);   -- PG6.D = PGLO & D6 # !PGLO & PG6
            pg7Reg <= (pgLo and d7) or ((not pgLo) and pg7Reg);   -- PG7.D = PGLO & D7 # !PGLO & PG7
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
