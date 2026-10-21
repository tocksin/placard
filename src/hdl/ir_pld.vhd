-- ============================================================
-- INSTR_REG  (VHDL conversion of ATF22V10_IR.pld, revision 01)
-- Date: 10/21/2026
--
-- The instruction register as a 22V10 in place of the 74F377: it
-- loads the opcode in FETCH and holds 02h (ld ac, ac) while RUN is
-- low, during the ROM cartridge's load.
--
-- Equations are carried over from the PLD without optimization.
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity ir_pld is
    port (
        clk          : in  std_logic;   -- pin 1
        d0           : in  std_logic;   -- pin 2
        d1           : in  std_logic;   -- pin 3
        d2           : in  std_logic;   -- pin 4
        d3           : in  std_logic;   -- pin 5
        d4           : in  std_logic;   -- pin 6
        d5           : in  std_logic;   -- pin 7
        d6           : in  std_logic;   -- pin 8
        d7           : in  std_logic;   -- pin 9
        load_instr_n : in  std_logic;   -- pin 10, State PLD pin 14, low = load
        run          : in  std_logic;   -- pin 11, from the ROM cartridge, low = hold 02h

        i0           : out std_logic;   -- pin 14
        i1           : out std_logic;   -- pin 15
        i2           : out std_logic;   -- pin 16
        i3           : out std_logic;   -- pin 17
        i4           : out std_logic;   -- pin 18
        i5           : out std_logic;   -- pin 19
        i6           : out std_logic;   -- pin 20
        i7           : out std_logic    -- pin 21
    );
end entity ir_pld;

architecture rtl of ir_pld is

    signal loadInstr : std_logic;

    -- registers, all 0 at power-up
    signal i0Q : std_logic := '0';
    signal i1Q : std_logic := '0';
    signal i2Q : std_logic := '0';
    signal i3Q : std_logic := '0';
    signal i4Q : std_logic := '0';
    signal i5Q : std_logic := '0';
    signal i6Q : std_logic := '0';
    signal i7Q : std_logic := '0';

begin

    loadInstr <= not load_instr_n;

    process (clk)
    begin
        if rising_edge(clk) then
            i0Q <= (run and loadInstr and d0) or (run and (not loadInstr) and i0Q);
            i1Q <= (not run) or (loadInstr and d1) or ((not loadInstr) and i1Q);
            i2Q <= (run and loadInstr and d2) or (run and (not loadInstr) and i2Q);
            i3Q <= (run and loadInstr and d3) or (run and (not loadInstr) and i3Q);
            i4Q <= (run and loadInstr and d4) or (run and (not loadInstr) and i4Q);
            i5Q <= (run and loadInstr and d5) or (run and (not loadInstr) and i5Q);
            i6Q <= (run and loadInstr and d6) or (run and (not loadInstr) and i6Q);
            i7Q <= (run and loadInstr and d7) or (run and (not loadInstr) and i7Q);
        end if;
    end process;

    i0 <= i0Q;
    i1 <= i1Q;
    i2 <= i2Q;
    i3 <= i3Q;
    i4 <= i4Q;
    i5 <= i5Q;
    i6 <= i6Q;
    i7 <= i7Q;

end architecture rtl;
