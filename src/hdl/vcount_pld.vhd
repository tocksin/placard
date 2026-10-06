------------------------------------------------------------------------------
-- Name     : VCOUNT_PLD
-- PartNo   : U1
-- Date     : 10/01/2026
-- Revision : 03
-- Designer : Engineer
-- Company  :
-- Assembly :
-- Location :
-- Device   : g22v10
------------------------------------------------------------------------------
--
-- PIN 1  = CLK;
-- PIN 2  = EN;      -- clock enable, active high
--
-- PIN 14 = Q0;      -- 8 PT avail,  4 used
-- PIN 23 = Q1;      -- 8 PT avail,  5 used
-- PIN 22 = Q2;      -- 10 PT avail, 4 used
-- PIN 15 = Q3;      -- 10 PT avail, 5 used
-- PIN 16 = Q4;      -- 12 PT avail, 8 used
-- PIN 21 = Q5;      -- 12 PT avail, 9 used
-- PIN 20 = Q6;      -- 14 PT avail, 10 used
-- PIN 17 = Q7;      -- 14 PT avail, 11 used
-- PIN 18 = Q8;      -- 16 PT avail, 12 used
-- PIN 19 = Q9;      -- 16 PT avail, 11 used
--
-- all  = Q9 & Q8 & Q7 & Q6 & Q5 & Q4 & Q3 & Q2 & Q1 & Q0;
-- ZERO = !Q9 & !Q8 & !Q7 & !Q6 & !Q5 & !Q4 & !Q3 & !Q2 & !Q1 & !Q0;
--
-- [Q9..Q0].AR = 'b'0;   -- Asynchronous Reset disabled
-- [Q9..Q0].SP = 'b'0;   -- Synchronous Preset disabled
------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.ALL;

entity vcount_pld is
    port (
        CLK : in  std_logic;  -- PIN 1
        EN  : in  std_logic;  -- PIN 2
        Q0  : out std_logic;  -- PIN 14
        Q1  : out std_logic;  -- PIN 23
        Q2  : out std_logic;  -- PIN 22
        Q3  : out std_logic;  -- PIN 15
        Q4  : out std_logic;  -- PIN 16
        Q5  : out std_logic;  -- PIN 21
        Q6  : out std_logic;  -- PIN 20
        Q7  : out std_logic;  -- PIN 17
        Q8  : out std_logic;  -- PIN 18
        Q9  : out std_logic   -- PIN 19
    );
end entity vcount_pld;

architecture RTL of vcount_pld is

    -- Internal state registers (flip-flop outputs)
    signal Q0_r : std_logic := '0';
    signal Q1_r : std_logic := '0';
    signal Q2_r : std_logic := '0';
    signal Q3_r : std_logic := '0';
    signal Q4_r : std_logic := '0';
    signal Q5_r : std_logic := '0';
    signal Q6_r : std_logic := '0';
    signal Q7_r : std_logic := '0';
    signal Q8_r : std_logic := '0';
    signal Q9_r : std_logic := '0';

    -- D-input signals
    signal Q0_d : std_logic := '0';
    signal Q1_d : std_logic := '0';
    signal Q2_d : std_logic := '0';
    signal Q3_d : std_logic := '0';
    signal Q4_d : std_logic := '0';
    signal Q5_d : std_logic := '0';
    signal Q6_d : std_logic := '0';
    signal Q7_d : std_logic := '0';
    signal Q8_d : std_logic := '0';
    signal Q9_d : std_logic := '0';

    -- Derived combinational signals
    -- all  = Q9 & Q8 & Q7 & Q6 & Q5 & Q4 & Q3 & Q2 & Q1 & Q0
    -- ZERO = !Q9 & !Q8 & !Q7 & !Q6 & !Q5 & !Q4 & !Q3 & !Q2 & !Q1 & !Q0
    signal ALLx : std_logic := '0';
    signal ZERO : std_logic := '0';

begin

    -- all = Q9 & Q8 & Q7 & Q6 & Q5 & Q4 & Q3 & Q2 & Q1 & Q0
    ALLx  <= Q9_r and Q8_r and Q7_r and Q6_r and Q5_r
            and Q4_r and Q3_r and Q2_r and Q1_r and Q0_r;

    -- ZERO = !Q9 & !Q8 & !Q7 & !Q6 & !Q5 & !Q4 & !Q3 & !Q2 & !Q1 & !Q0
    ZERO <= not Q9_r and not Q8_r and not Q7_r and not Q6_r and not Q5_r
            and not Q4_r and not Q3_r and not Q2_r and not Q1_r and not Q0_r;

    ---------------------------------------------------------------------------
    -- Q0.d = Q0 & !EN # !Q0 & EN # ALLx # ZERO
    ---------------------------------------------------------------------------
    Q0_d <= (Q0_r and not EN)
          or (not Q0_r and EN)
          or ALLx
          or ZERO;

    ---------------------------------------------------------------------------
    -- Q1.d = Q1 & !EN # Q1 & !Q0 # !Q1 & Q0 & EN # ALLx # ZERO
    ---------------------------------------------------------------------------
    Q1_d <= (Q1_r and not EN)
          or (Q1_r and not Q0_r)
          or (not Q1_r and Q0_r and EN)
          or ALLx
          or ZERO;

    ---------------------------------------------------------------------------
    -- Q2.d = Q2 & !EN # Q2 & !Q0 # Q2 & !Q1 # !Q2 & Q1 & Q0 & EN
    ---------------------------------------------------------------------------
    Q2_d <= (Q2_r and not EN)
          or (Q2_r and not Q0_r)
          or (Q2_r and not Q1_r)
          or (not Q2_r and Q1_r and Q0_r and EN);

    ---------------------------------------------------------------------------
    -- Q3.d = Q3 & !EN # Q3 & !Q0 # Q3 & !Q1 # Q3 & !Q2 # !Q3 & Q2 & Q1 & Q0 & EN
    ---------------------------------------------------------------------------
    Q3_d <= (Q3_r and not EN)
          or (Q3_r and not Q0_r)
          or (Q3_r and not Q1_r)
          or (Q3_r and not Q2_r)
          or (not Q3_r and Q2_r and Q1_r and Q0_r and EN);

    ---------------------------------------------------------------------------
    -- Q4.d = Q4 & !EN # Q4 & !Q0 # Q4 & !Q1 # Q4 & !Q2 # Q4 & !Q3
    --        # !Q4 & Q3 & Q2 & Q1 & Q0 & EN # ALLx # ZERO
    ---------------------------------------------------------------------------
    Q4_d <= (Q4_r and not EN)
          or (Q4_r and not Q0_r)
          or (Q4_r and not Q1_r)
          or (Q4_r and not Q2_r)
          or (Q4_r and not Q3_r)
          or (not Q4_r and Q3_r and Q2_r and Q1_r and Q0_r and EN)
          or ALLx
          or ZERO;

    ---------------------------------------------------------------------------
    -- Q5.d = Q5 & !EN # Q5 & !Q0 # Q5 & !Q1 # Q5 & !Q2 # Q5 & !Q3 # Q5 & !Q4
    --        # !Q5 & Q4 & Q3 & Q2 & Q1 & Q0 & EN # ALLx # ZERO
    ---------------------------------------------------------------------------
    Q5_d <= (Q5_r and not EN)
          or (Q5_r and not Q0_r)
          or (Q5_r and not Q1_r)
          or (Q5_r and not Q2_r)
          or (Q5_r and not Q3_r)
          or (Q5_r and not Q4_r)
          or (not Q5_r and Q4_r and Q3_r and Q2_r and Q1_r and Q0_r and EN)
          or ALLx
          or ZERO;

    ---------------------------------------------------------------------------
    -- Q6.d = Q6 & !EN # Q6 & !Q0 # Q6 & !Q1 # Q6 & !Q2 # Q6 & !Q3
    --        # Q6 & !Q4 # Q6 & !Q5 # !Q6 & Q5 & Q4 & Q3 & Q2 & Q1 & Q0 & EN
    --        # ALLx # ZERO
    ---------------------------------------------------------------------------
    Q6_d <= (Q6_r and not EN)
          or (Q6_r and not Q0_r)
          or (Q6_r and not Q1_r)
          or (Q6_r and not Q2_r)
          or (Q6_r and not Q3_r)
          or (Q6_r and not Q4_r)
          or (Q6_r and not Q5_r)
          or (not Q6_r and Q5_r and Q4_r and Q3_r and Q2_r and Q1_r and Q0_r and EN)
          or ALLx
          or ZERO;

    ---------------------------------------------------------------------------
    -- Q7.d = Q7 & !EN # Q7 & !Q0 # Q7 & !Q1 # Q7 & !Q2 # Q7 & !Q3
    --        # Q7 & !Q4 # Q7 & !Q5 # Q7 & !Q6
    --        # !Q7 & Q6 & Q5 & Q4 & Q3 & Q2 & Q1 & Q0 & EN # ALLx # ZERO
    ---------------------------------------------------------------------------
    Q7_d <= (Q7_r and not EN)
          or (Q7_r and not Q0_r)
          or (Q7_r and not Q1_r)
          or (Q7_r and not Q2_r)
          or (Q7_r and not Q3_r)
          or (Q7_r and not Q4_r)
          or (Q7_r and not Q5_r)
          or (Q7_r and not Q6_r)
          or (not Q7_r and Q6_r and Q5_r and Q4_r and Q3_r and Q2_r and Q1_r and Q0_r and EN)
          or ALLx
          or ZERO;

    ---------------------------------------------------------------------------
    -- Q8.d = Q8 & !EN # Q8 & !Q0 # Q8 & !Q1 # Q8 & !Q2 # Q8 & !Q3
    --        # Q8 & !Q4 # Q8 & !Q5 # Q8 & !Q6 # Q8 & !Q7
    --        # !Q8 & Q7 & Q6 & Q5 & Q4 & Q3 & Q2 & Q1 & Q0 & EN # ALLx # ZERO
    ---------------------------------------------------------------------------
    Q8_d <= (Q8_r and not EN)
          or (Q8_r and not Q0_r)
          or (Q8_r and not Q1_r)
          or (Q8_r and not Q2_r)
          or (Q8_r and not Q3_r)
          or (Q8_r and not Q4_r)
          or (Q8_r and not Q5_r)
          or (Q8_r and not Q6_r)
          or (Q8_r and not Q7_r)
          or (not Q8_r and Q7_r and Q6_r and Q5_r and Q4_r and Q3_r and Q2_r and Q1_r and Q0_r and EN)
          or ALLx
          or ZERO;

    ---------------------------------------------------------------------------
    -- Q9.d = Q9 & !EN # Q9 & !Q0 # Q9 & !Q1 # Q9 & !Q2 # Q9 & !Q3
    --        # Q9 & !Q4 # Q9 & !Q5 # Q9 & !Q6 # Q9 & !Q7 # Q9 & !Q8
    --        # !Q9 & Q8 & Q7 & Q6 & Q5 & Q4 & Q3 & Q2 & Q1 & Q0 & EN
    ---------------------------------------------------------------------------
    Q9_d <= (Q9_r and not EN)
          or (Q9_r and not Q0_r)
          or (Q9_r and not Q1_r)
          or (Q9_r and not Q2_r)
          or (Q9_r and not Q3_r)
          or (Q9_r and not Q4_r)
          or (Q9_r and not Q5_r)
          or (Q9_r and not Q6_r)
          or (Q9_r and not Q7_r)
          or (Q9_r and not Q8_r)
          or (not Q9_r and Q8_r and Q7_r and Q6_r and Q5_r and Q4_r and Q3_r and Q2_r and Q1_r and Q0_r and EN);

    ---------------------------------------------------------------------------
    -- Flip-flop state registers
    -- [Q9..Q0].AR = 'b'0;  -- Asynchronous Reset disabled
    -- [Q9..Q0].SP = 'b'0;  -- Synchronous Preset disabled
    ---------------------------------------------------------------------------
    process (CLK)
    begin
        if rising_edge(CLK) then
            Q0_r <= Q0_d;
            Q1_r <= Q1_d;
            Q2_r <= Q2_d;
            Q3_r <= Q3_d;
            Q4_r <= Q4_d;
            Q5_r <= Q5_d;
            Q6_r <= Q6_d;
            Q7_r <= Q7_d;
            Q8_r <= Q8_d;
            Q9_r <= Q9_d;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Output assignments
    ---------------------------------------------------------------------------
    Q0 <= Q0_r;
    Q1 <= Q1_r;
    Q2 <= Q2_r;
    Q3 <= Q3_r;
    Q4 <= Q4_r;
    Q5 <= Q5_r;
    Q6 <= Q6_r;
    Q7 <= Q7_r;
    Q8 <= Q8_r;
    Q9 <= Q9_r;

end architecture RTL;
