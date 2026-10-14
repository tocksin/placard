-- ============================================================
-- STATE_CTRL  (VHDL conversion of ATF22V10_STATE.pld, Rev 06)
-- Date: 2026-10-13
--
-- Binary state machine:  Q1 Q0
--     00 FETCH, 01 LOAD_IMM, 10 LOAD_MEM, 11 EXEC
--
-- Zero-page ([0,D]) accesses chain LOAD_IMM (operand byte -> D)
-- into LOAD_MEM (D used as the address).
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- Pin 15 is !Q1 (= PC_ENABLE) and pin 23 is !MEM_WR (= R/W,
-- 1 = read), exactly as declared in the PLD.
-- PC_INC is not generated here: PC_INC = pc_enable and not byte_enable.
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity state_pld is
    port (
        clk         : in  std_logic;   -- pin 1
        byte_enable : in  std_logic;   -- pin 2, pixel enable from sync PLD
        db_src1     : in  std_logic;   -- pin 3, data bus bit 1 (instruction being fetched)
        db_src0     : in  std_logic;   -- pin 4, data bus bit 0 (instruction being fetched)
        mem2        : in  std_logic;   -- pin 5, memory field bit 2 (from instruction FF)
        mem1        : in  std_logic;   -- pin 6
        mem0        : in  std_logic;   -- pin 7
        db_mem2     : in  std_logic;   -- pin 8, data bus bit 4 (instruction being fetched)
        db_mem1     : in  std_logic;   -- pin 9, data bus bit 3
        db_mem0     : in  std_logic;   -- pin 10, data bus bit 2
        src1        : in  std_logic;   -- pin 11, source field bit 1 (from instruction FF)
        src0        : in  std_logic;   -- pin 13, source field bit 0 (from instruction FF)

        q0          : out std_logic;   -- pin 14, state bit 0
        pc_enable   : out std_logic;   -- pin 15, = not q1
        x_enable    : out std_logic;   -- pin 16
        y_enable    : out std_logic;   -- pin 17
        load_instr  : out std_logic;   -- pin 18
        load_imm    : out std_logic;   -- pin 19
        load_x      : out std_logic;   -- pin 20
        load_y      : out std_logic;   -- pin 21
        load_ac     : out std_logic;   -- pin 22
        mem_rw      : out std_logic    -- pin 23, 1 = read, 0 = write
    );
end entity state_pld;

architecture rtl of state_pld is

    -- Internal copies of the state registers so they can be
    -- read back inside the architecture.  Registers power up
    -- to 0 (FETCH), as on the ATF22V10C.
    signal q0_r     : std_logic := '0';
    signal q1_r     : std_logic := '0';

    signal s_fetch  : std_logic;
    signal s_limm   : std_logic;
    signal s_lmem   : std_logic;
    signal s_exec   : std_logic;

    signal dest_ac  : std_logic;
    signal dest_x   : std_logic;
    signal dest_y   : std_logic;
    signal dest_ram : std_logic;

    signal mem_wr   : std_logic;

begin

    -- --------------------------------------------------------
    -- State decode
    -- --------------------------------------------------------
    s_fetch <= not q1_r and not q0_r;
    s_limm  <= not q1_r and q0_r;
    s_lmem  <= q1_r and not q0_r;
    s_exec  <= q1_r and q0_r;

    -- --------------------------------------------------------
    -- State registers
    -- --------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            q0_r <= (q0_r and byte_enable)
                 or (s_fetch and not byte_enable and db_src1)
                 or (s_fetch and not byte_enable and not db_src0)
                 or (s_fetch and not byte_enable and not db_mem1 and not db_mem0)
                 or (s_fetch and not byte_enable and not db_mem2 and db_mem1 and db_mem0)
                 or (s_limm  and not byte_enable and src1)
                 or (s_limm  and not byte_enable and not src0)
                 or (s_lmem  and not byte_enable);

            q1_r <= (q1_r and byte_enable)
                 or (s_fetch and not byte_enable and not db_src1 and db_src0 and not db_mem1 and db_mem0)
                 or (s_fetch and not byte_enable and not db_src1 and db_src0 and db_mem2 and db_mem1)
                 or (s_fetch and not byte_enable and not db_src1 and db_src0 and not db_mem2 and db_mem1 and not db_mem0)
                 or (s_fetch and not byte_enable and db_src1 and not db_mem2)
                 or (s_fetch and not byte_enable and db_src1 and db_mem1)
                 or (s_fetch and not byte_enable and db_src1 and not db_mem0)
                 or (s_limm  and not byte_enable)
                 or (s_lmem  and not byte_enable);
        end if;
    end process;

    q0        <= q0_r;
    pc_enable <= not q1_r;

    -- --------------------------------------------------------
    -- Memory field decode
    -- --------------------------------------------------------
    x_enable <= (not mem2 and not mem1 and mem0)
             or (not mem2 and mem1 and not mem0)
             or (mem2 and mem1 and not mem0)
             or (mem2 and mem1 and mem0);

    y_enable <= (not mem2 and mem1 and not mem0)
             or (mem2 and mem1 and mem0);

    dest_ac  <= (not mem2 and not mem1 and not mem0)
             or (not mem2 and not mem1 and mem0)
             or (not mem2 and mem1 and not mem0);

    dest_x   <= not mem2 and mem1 and mem0;

    dest_y   <= mem2 and not mem1 and not mem0;

    dest_ram <= (mem2 and not mem1 and mem0)
             or (mem2 and mem1 and not mem0)
             or (mem2 and mem1 and mem0);

    -- --------------------------------------------------------
    -- Strobes
    -- --------------------------------------------------------
    load_instr <= s_fetch and not byte_enable;

    load_imm   <= (s_limm and not byte_enable)
               or (s_lmem and not byte_enable);

    load_ac    <= s_exec and not byte_enable and dest_ac;

    load_x     <= s_exec and not byte_enable and dest_x;

    load_y     <= s_exec and not byte_enable and dest_y;

    mem_wr     <= s_exec and not byte_enable and dest_ram;

    mem_rw     <= not mem_wr;

end architecture rtl;
