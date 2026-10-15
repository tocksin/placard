-- ============================================================
-- BRANCH_CTRL  (VHDL conversion of ATF22V10_BRANCH.pld, Rev 06)
-- Date: 10/15/2026
--
-- Branch / jump control, plus the ALU wait clock (Rev 06).
--
-- ALU WAIT: alu_wait is a register set for one clock at the start
-- of EXEC of an ADD/SUB whose destination is AC, X or Y:
--     alu_wait.D = exec and not pixel_enable and i7 and not i6
--                  and (destination is not RAM) and not alu_wait
-- stall = pixel_enable or alu_wait replaces pixel_enable on the
-- State PLD and both PC PLDs, so the CPU holds EXEC for one clock
-- while the carry ripples through both ALU PLDs.  The video keeps
-- the real pixel_enable.
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
-- pixel_enable = 1 means video owns the bus.
--
-- EXEC state: exec = q0 and not pc_enable
--     q0        = State PLD pin 14 (true polarity)
--     pc_enable = State PLD pin 15 (= not Q1)
--
-- load_pc_low and load_pc_high are active only in EXEC with
-- pixel_enable = 0.
--
-- Two decode blocks:
--   block A (EXEC):  i7:i5 from the instruction register
--       branch_a = i7 and i6 and i5 and exec and not pixel_enable
--   block B (FETCH): db7:db5 from the data bus, because the instruction
--       register still holds the previous opcode during FETCH
--       fetch    = not q0 and pc_enable
--       branch_b = db7 and db6 and db5 and fetch and not pixel_enable
--
-- branch_block = branch_a or branch_b.  In FETCH it tells the State PLD
-- that the opcode being fetched is a branch.  In EXEC it is active
-- whenever a branch/jump executes, whether or not it is taken.
-- It is active high here.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   1  clk          17  i7            2  i6            3  i5
--   4  m2            5  m1            6  m0
--   7  z_low         8  neg           9  pixel_enable
--  10  q0           11  pc_enable    13  z_high
--  14  db7          15  db6          16  db5
--  18  alu_wait     19  stall
--  21  load_pc_low  22  load_pc_high 23  branch_block
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity branch_pld is
    port (
        clk           : in  std_logic;   -- pin 1, CPU clock (alu_wait register)

        i7            : in  std_logic;   -- pin 17 (I/O pin used as an input)
        i6            : in  std_logic;   -- pin 2
        i5            : in  std_logic;   -- pin 3

        m2            : in  std_logic;   -- pin 4
        m1            : in  std_logic;   -- pin 5
        m0            : in  std_logic;   -- pin 6

        z_low         : in  std_logic;   -- pin 7, low  ALU nibble zero
        neg           : in  std_logic;   -- pin 8

        pixel_enable  : in  std_logic;   -- pin 9, 1 = video owns the bus

        q0            : in  std_logic;   -- pin 10, State PLD pin 14, state bit 0
        pc_enable     : in  std_logic;   -- pin 11, State PLD pin 15, = not Q1

        z_high        : in  std_logic;   -- pin 13, high ALU nibble zero

        db7           : in  std_logic;   -- pin 14, data bus bit 7 (opcode being fetched)
        db6           : in  std_logic;   -- pin 15, data bus bit 6
        db5           : in  std_logic;   -- pin 16, data bus bit 5

        load_pc_low   : out std_logic;   -- pin 21
        load_pc_high  : out std_logic;   -- pin 22
        branch_block  : out std_logic;   -- pin 23

        alu_wait      : out std_logic;   -- pin 18, registered
        stall         : out std_logic    -- pin 19, pixel_enable or alu_wait
    );
end entity branch_pld;

architecture rtl of branch_pld is

    -- common terms
    signal exec     : std_logic;
    signal fetch    : std_logic;
    signal branch_a : std_logic;   -- block A, EXEC state, instruction register
    signal branch_b : std_logic;   -- block B, FETCH state, data bus

    signal addsub_reg : std_logic; -- ADD/SUB with an AC, X or Y destination
    signal alu_wait_q : std_logic := '0';   -- powers up to 0, as on the ATF22V10C

begin

    -- --------------------------------------------------------
    -- Common terms
    -- --------------------------------------------------------
    exec     <= q0 and not pc_enable;
    fetch    <= not q0 and pc_enable;

    branch_a <= i7 and i6 and i5 and exec and not pixel_enable;

    branch_b <= db7 and db6 and db5 and fetch and not pixel_enable;

    -- ADD (100) or SUB (101), destination AC, X or Y
    -- (M = 000..100; 101, 110, 111 are RAM destinations).
    addsub_reg <= i7 and not i6 and not (m2 and (m1 or m0));

    -- --------------------------------------------------------
    -- ALU wait register
    -- --------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            alu_wait_q <= exec and not pixel_enable and addsub_reg and not alu_wait_q;
        end if;
    end process;

    alu_wait <= alu_wait_q;
    stall    <= pixel_enable or alu_wait_q;

    -- --------------------------------------------------------
    -- Equations
    -- --------------------------------------------------------
    branch_block <= branch_a or branch_b;

    load_pc_high <= branch_a and not m2 and not m1 and not m0;            -- JMP

    load_pc_low  <= (branch_a and not m2 and not m1 and not m0)                                -- JMP
                 or (branch_a and not m2 and not m1 and     m0 and not z_low  and not neg)     -- BGT, low nibble <> 0
                 or (branch_a and not m2 and not m1 and     m0 and not z_high and not neg)     -- BGT, high nibble <> 0
                 or (branch_a and not m2 and     m1 and not m0 and not z_low  and     neg)     -- BLT, low nibble <> 0
                 or (branch_a and not m2 and     m1 and not m0 and not z_high and     neg)     -- BLT, high nibble <> 0
                 or (branch_a and not m2 and     m1 and     m0 and not z_low)                  -- BNE, low nibble <> 0
                 or (branch_a and not m2 and     m1 and     m0 and not z_high)                 -- BNE, high nibble <> 0
                 or (branch_a and     m2 and not m1 and not m0 and     z_low and z_high)       -- BEQ
                 or (branch_a and     m2 and not m1 and     m0 and not neg)                    -- BGE
                 or (branch_a and     m2 and     m1 and not m0 and     z_low and z_high)       -- BLE, AC=0
                 or (branch_a and     m2 and     m1 and not m0 and     neg)                    -- BLE, AC<0
                 or (branch_a and     m2 and     m1 and     m0);                               -- BRA

end architecture rtl;
