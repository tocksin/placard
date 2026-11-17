--------------------------------------------------------------------------------
-- Name     MEMCARD_HI
-- PartNo   00
-- Date     11/17/2026
-- Revision 02
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_MEMCARD_HI.pld (Revision 02)
--
-- Register decode and page bits 11:8 of the 512K memory expansion card
-- (docs/architecture/MEMCARD.md).  The card's SRAM is wired straight to
-- the slot (/CE = /EXP, /OE = Q0, /WE = /WE, A6:A0, D7:D0); the two page
-- PLDs hold its upper address A18:A7 as a 12-bit page number.
--
--   - /PGLO (pin 16) is low for an access to the card's offset 7Eh; it is
--     the select of the page low PLD (memcard_lo_pld.vhd).
--   - The four registers clock on the rising edge of /WE (pin 1, the
--     register clock), the end of every write.  They load D3:D0 when the
--     write is to the card's offset 7Fh and hold their value on every
--     other /WE.  They clear at power-up.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = WE                (ACTIVE LOW, register clock; slot B24)
--   PIN 3  = A5
--   PIN 4  = A4
--   PIN 5  = A6
--   PIN 6  = A2
--   PIN 7  = A3
--   PIN 8  = EXP               (ACTIVE LOW, the slot's select; slot A16)
--   PIN 9  = A0
--   PIN 10 = D1
--   PIN 11 = D0
--   PIN 13 = D2
--   PIN 14 = D3
--   PIN 15 = A1
--   PIN 16 = PGLO              (ACTIVE LOW, combinational)
--   PIN 17 = PG8               (register)
--   PIN 18 = PG9               (register)
--   PIN 19 = PG10              (register)
--   PIN 20 = PG11              (register)
--   Unused: 2, 21, 22, 23
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity memcard_hi_pld is
    port (
        weN   : in  std_logic;   -- pin 1, active low, register clock
        expN  : in  std_logic;   -- pin 8, active low
        a0    : in  std_logic;   -- pin 9
        a1    : in  std_logic;   -- pin 15
        a2    : in  std_logic;   -- pin 6
        a3    : in  std_logic;   -- pin 7
        a4    : in  std_logic;   -- pin 4
        a5    : in  std_logic;   -- pin 3
        a6    : in  std_logic;   -- pin 5
        d0    : in  std_logic;   -- pin 11
        d1    : in  std_logic;   -- pin 10
        d2    : in  std_logic;   -- pin 13
        d3    : in  std_logic;   -- pin 14

        pgLoN : out std_logic;   -- pin 16, active low
        pg10  : out std_logic;   -- pin 19
        pg9   : out std_logic;   -- pin 18
        pg8   : out std_logic;   -- pin 17
        pg11  : out std_logic    -- pin 20
    );
end entity memcard_hi_pld;

architecture rtl of memcard_hi_pld is

    signal expSel  : std_logic;
    signal pageReg : std_logic;
    signal pgLo    : std_logic;
    signal pgHi    : std_logic;

    -- the registers, as the PLD holds them (cleared at power-up)
    signal pg8Reg  : std_logic := '0';
    signal pg9Reg  : std_logic := '0';
    signal pg10Reg : std_logic := '0';
    signal pg11Reg : std_logic := '0';

begin

    expSel  <= not expN;
    pageReg <= expSel and a6 and a5 and a4 and a3 and a2 and a1;   -- PAGE_REG = EXP & A6 & A5 & A4 & A3 & A2 & A1

    pgLo <= pageReg and (not a0);     -- PGLO = PAGE_REG & !A0
    pgHi <= pageReg and (    a0);     -- PGHI = PAGE_REG &  A0

    -- Page bits 11:8: load the data bus on a write to offset 7Fh, and
    -- hold on every other /WE.  The clock is pin 1, /WE: its rising edge.
    regProc : process (weN)
    begin
        if rising_edge(weN) then
            pg8Reg  <= (pgHi and d0) or ((not pgHi) and pg8Reg);     -- PG8.D  = PGHI & D0 # !PGHI & PG8
            pg9Reg  <= (pgHi and d1) or ((not pgHi) and pg9Reg);     -- PG9.D  = PGHI & D1 # !PGHI & PG9
            pg10Reg <= (pgHi and d2) or ((not pgHi) and pg10Reg);    -- PG10.D = PGHI & D2 # !PGHI & PG10
            pg11Reg <= (pgHi and d3) or ((not pgHi) and pg11Reg);    -- PG11.D = PGHI & D3 # !PGHI & PG11
        end if;
    end process regProc;

    pgLoN <= not pgLo;
    pg8   <= pg8Reg;
    pg9   <= pg9Reg;
    pg10  <= pg10Reg;
    pg11  <= pg11Reg;

end architecture rtl;
