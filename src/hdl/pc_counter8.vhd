-- ============================================================
-- 8-bit loadable counter (VHDL version of ATF22V10_PC_COUNTER8.pld)
--
-- Equations are carried over from the PLD without optimization.
--
--   LOW  byte: cin tied high,     en = pc_enable
--   HIGH byte: cin = co of LOW,   en = pc_enable
--
--   cnt = en and cin and not pixel_enable
--   load = 1           : q <= d7..d0   (load has priority)
--   load = 0, cnt = 1  : q <= q + 1
--   load = 0, cnt = 0  : q <= q
--   co = cin and (q7..q0 all ones)
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity pc_counter8 is
    port (
        clk          : in  std_logic;

        d0           : in  std_logic;
        d1           : in  std_logic;
        d2           : in  std_logic;
        d3           : in  std_logic;
        d4           : in  std_logic;
        d5           : in  std_logic;
        d6           : in  std_logic;
        d7           : in  std_logic;

        load         : in  std_logic;
        en           : in  std_logic;
        cin          : in  std_logic;
        pixel_enable : in  std_logic;

        q0           : out std_logic;
        q1           : out std_logic;
        q2           : out std_logic;
        q3           : out std_logic;
        q4           : out std_logic;
        q5           : out std_logic;
        q6           : out std_logic;
        q7           : out std_logic;

        co           : out std_logic
    );
end entity pc_counter8;

architecture rtl of pc_counter8 is

    -- internal register copies (outputs are read back in the equations)
    signal q0_r : std_logic := '0';
    signal q1_r : std_logic := '0';
    signal q2_r : std_logic := '0';
    signal q3_r : std_logic := '0';
    signal q4_r : std_logic := '0';
    signal q5_r : std_logic := '0';
    signal q6_r : std_logic := '0';
    signal q7_r : std_logic := '0';

begin

    q0 <= q0_r;
    q1 <= q1_r;
    q2 <= q2_r;
    q3 <= q3_r;
    q4 <= q4_r;
    q5 <= q5_r;
    q6 <= q6_r;
    q7 <= q7_r;

    -- carry out
    co <= cin and q7_r and q6_r and q5_r and q4_r and q3_r and q2_r and q1_r and q0_r;

    process (clk)
    begin
        if rising_edge(clk) then

            q0_r <= (load and d0)
                 or (not load and q0_r and not en)
                 or (not load and q0_r and not cin)
                 or (not load and q0_r and pixel_enable)
                 or (not load and not q0_r and en and cin and not pixel_enable);

            q1_r <= (load and d1)
                 or (not load and q1_r and not en)
                 or (not load and q1_r and not cin)
                 or (not load and q1_r and pixel_enable)
                 or (not load and q1_r and not q0_r)
                 or (not load and not q1_r and q0_r and en and cin and not pixel_enable);

            q2_r <= (load and d2)
                 or (not load and q2_r and not en)
                 or (not load and q2_r and not cin)
                 or (not load and q2_r and pixel_enable)
                 or (not load and q2_r and not q0_r)
                 or (not load and q2_r and not q1_r)
                 or (not load and not q2_r and q1_r and q0_r and en and cin and not pixel_enable);

            q3_r <= (load and d3)
                 or (not load and q3_r and not en)
                 or (not load and q3_r and not cin)
                 or (not load and q3_r and pixel_enable)
                 or (not load and q3_r and not q0_r)
                 or (not load and q3_r and not q1_r)
                 or (not load and q3_r and not q2_r)
                 or (not load and not q3_r and q2_r and q1_r and q0_r and en and cin and not pixel_enable);

            q4_r <= (load and d4)
                 or (not load and q4_r and not en)
                 or (not load and q4_r and not cin)
                 or (not load and q4_r and pixel_enable)
                 or (not load and q4_r and not q0_r)
                 or (not load and q4_r and not q1_r)
                 or (not load and q4_r and not q2_r)
                 or (not load and q4_r and not q3_r)
                 or (not load and not q4_r and q3_r and q2_r and q1_r and q0_r and en and cin and not pixel_enable);

            q5_r <= (load and d5)
                 or (not load and q5_r and not en)
                 or (not load and q5_r and not cin)
                 or (not load and q5_r and pixel_enable)
                 or (not load and q5_r and not q0_r)
                 or (not load and q5_r and not q1_r)
                 or (not load and q5_r and not q2_r)
                 or (not load and q5_r and not q3_r)
                 or (not load and q5_r and not q4_r)
                 or (not load and not q5_r and q4_r and q3_r and q2_r and q1_r and q0_r and en and cin and not pixel_enable);

            q6_r <= (load and d6)
                 or (not load and q6_r and not en)
                 or (not load and q6_r and not cin)
                 or (not load and q6_r and pixel_enable)
                 or (not load and q6_r and not q0_r)
                 or (not load and q6_r and not q1_r)
                 or (not load and q6_r and not q2_r)
                 or (not load and q6_r and not q3_r)
                 or (not load and q6_r and not q4_r)
                 or (not load and q6_r and not q5_r)
                 or (not load and not q6_r and q5_r and q4_r and q3_r and q2_r and q1_r and q0_r and en and cin and not pixel_enable);

            q7_r <= (load and d7)
                 or (not load and q7_r and not en)
                 or (not load and q7_r and not cin)
                 or (not load and q7_r and pixel_enable)
                 or (not load and q7_r and not q0_r)
                 or (not load and q7_r and not q1_r)
                 or (not load and q7_r and not q2_r)
                 or (not load and q7_r and not q3_r)
                 or (not load and q7_r and not q4_r)
                 or (not load and q7_r and not q5_r)
                 or (not load and q7_r and not q6_r)
                 or (not load and not q7_r and q6_r and q5_r and q4_r and q3_r and q2_r and q1_r and q0_r and en and cin and not pixel_enable);

        end if;
    end process;

end architecture rtl;
