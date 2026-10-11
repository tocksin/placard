-- ============================================================
-- BRANCH_CTRL  (VHDL conversion of ATF22V10_BRANCH.pld, Rev 04)
-- Date: 10/10/2026
--
-- Branch / jump control.  Combinational only.
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- ALU field I7:I5 = 111 selects branch/jump.
-- Memory-mode field M2:M0 (instruction bits 4:2) selects type:
--
--     000 JMP  always, 16-bit load (PC low + PC high)
--     001 BGT  AC > 0
--     010 BLT  AC < 0
--     011 BNE  AC <> 0
--     100 BEQ  AC = 0
--     101 BGE  AC >= 0
--     110 BLE  AC <= 0
--     111 BRA  always, 8-bit load (PC low only)
--
-- The ALU performs PASS A for the branch opcode, so each ALU Z output
-- is the zero flag of one nibble of the accumulator.
--
-- z_low  = low  ALU nibble is zero
-- z_high = high ALU nibble is zero
-- AC = 0 is  z_low and z_high;  AC <> 0 is  not z_low or not z_high
-- neg    = accumulator MSB (negative)
-- AC = 0 and neg are never both true.
--
-- byte_enable (pixel enable) = 1 means video owns the bus.
--
-- EXEC state: exec = q0 and not pc_enable
--     q0        = State PLD pin 14 (true polarity)
--     pc_enable = State PLD pin 15 (= not Q1)
--
-- Every output is active only in EXEC with byte_enable = 0.
--
-- branch_block is active whenever a branch/jump executes,
-- whether or not it is taken.  It is active high here.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   1  i7            2  i6            3  i5
--   4  m2            5  m1            6  m0
--   7  z_low         8  neg           9  byte_enable
--  10  q0           11  pc_enable    13  z_high
--  21  load_pc_low  22  load_pc_high 23  branch_block
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity branch_pld is
    port (
        i7            : in  std_logic;   -- pin 1
        i6            : in  std_logic;   -- pin 2
        i5            : in  std_logic;   -- pin 3

        m2            : in  std_logic;   -- pin 4
        m1            : in  std_logic;   -- pin 5
        m0            : in  std_logic;   -- pin 6

        z_low         : in  std_logic;   -- pin 7, low  ALU nibble zero
        neg           : in  std_logic;   -- pin 8

        byte_enable   : in  std_logic;   -- pin 9, 1 = video owns the bus

        q0            : in  std_logic;   -- pin 10, State PLD pin 14, state bit 0
        pc_enable     : in  std_logic;   -- pin 11, State PLD pin 15, = not Q1

        z_high        : in  std_logic;   -- pin 13, high ALU nibble zero

        load_pc_low   : out std_logic;   -- pin 21
        load_pc_high  : out std_logic;   -- pin 22
        branch_block  : out std_logic    -- pin 23
    );
end entity branch_pld;

architecture rtl of branch_pld is

    -- common terms
    signal exec   : std_logic;
    signal branch : std_logic;

begin

    -- --------------------------------------------------------
    -- Common terms
    -- --------------------------------------------------------
    exec   <= q0 and not pc_enable;

    branch <= i7 and i6 and i5 and exec and not byte_enable;

    -- --------------------------------------------------------
    -- Equations
    -- --------------------------------------------------------
    branch_block <= branch;

    load_pc_high <= branch and not m2 and not m1 and not m0;            -- JMP

    load_pc_low  <= (branch and not m2 and not m1 and not m0)                                -- JMP
                 or (branch and not m2 and not m1 and     m0 and not z_low  and not neg)     -- BGT, low nibble <> 0
                 or (branch and not m2 and not m1 and     m0 and not z_high and not neg)     -- BGT, high nibble <> 0
                 or (branch and not m2 and     m1 and not m0 and not z_low  and     neg)     -- BLT, low nibble <> 0
                 or (branch and not m2 and     m1 and not m0 and not z_high and     neg)     -- BLT, high nibble <> 0
                 or (branch and not m2 and     m1 and     m0 and not z_low)                  -- BNE, low nibble <> 0
                 or (branch and not m2 and     m1 and     m0 and not z_high)                 -- BNE, high nibble <> 0
                 or (branch and     m2 and not m1 and not m0 and     z_low and z_high)       -- BEQ
                 or (branch and     m2 and not m1 and     m0 and not neg)                    -- BGE
                 or (branch and     m2 and     m1 and not m0 and     z_low and z_high)       -- BLE, AC=0
                 or (branch and     m2 and     m1 and not m0 and     neg)                    -- BLE, AC<0
                 or (branch and     m2 and     m1 and     m0);                               -- BRA

end architecture rtl;
