-- ============================================================
-- STATE_CTRL  (VHDL conversion of ATF22V10_STATE.pld, Rev 03)
-- Date: 2026-10-05
--
-- Binary state machine:  Q1 Q0
--     00 FETCH, 01 IMM, 10 EXEC, 11 unused
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity state_ctrl is
    port (
        clk         : in  std_logic;   -- pin 1
        byte_enable : in  std_logic;   -- pin 2, from sync PLD

        q0          : out std_logic;   -- pin 14, state bit 0
        q1          : out std_logic;   -- pin 15, state bit 1

        pc_enable   : out std_logic;   -- pin 17
        fetch_en    : out std_logic;   -- pin 18
        imm_en      : out std_logic;   -- pin 19
        exec_en     : out std_logic;   -- pin 20
        pc_inc      : out std_logic    -- pin 21
    );
end entity state_ctrl;

architecture rtl of state_ctrl is

    -- Internal copies of the state registers so they can be
    -- read back inside the architecture.  Registers power up
    -- to 0 (FETCH), as on the ATF22V10C.
    signal q0_r : std_logic := '0';
    signal q1_r : std_logic := '0';

begin

    -- --------------------------------------------------------
    -- State registers
    -- --------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            q0_r <= (q0_r and byte_enable)
                 or (not q1_r and not q0_r and not byte_enable);

            q1_r <= (q1_r and byte_enable)
                 or (not q1_r and q0_r and not byte_enable);
        end if;
    end process;

    q0 <= q0_r;
    q1 <= q1_r;

    -- --------------------------------------------------------
    -- Output decode
    -- --------------------------------------------------------
    pc_enable <= not q1_r;

    fetch_en  <= not q1_r and not q0_r and not byte_enable;

    imm_en    <= not q1_r and q0_r and not byte_enable;

    exec_en   <= q1_r and not q0_r and not byte_enable;

    pc_inc    <= not q1_r and not byte_enable;

end architecture rtl;
