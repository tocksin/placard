-- Name     VGA_HCOUNTER;
-- PartNo   00;
-- Date     2026-09-11;
-- Revision 05;
-- Designer User;
-- Company  ;
-- Assembly ;
-- Location ;
-- Device   ATF22V10C;

-- =========================================================
-- 10-BIT MODULO-800 COUNTER
--
-- Counts:
--     0 -> 1 -> 2 -> ... -> 798 -> 799 -> 0
--
-- Any state 800-1023 is automatically cleared to zero.
--
-- 800-1023 are exactly:
--     Q9 = 1
--     Q8 = 1
--
-- Therefore Q9 & Q8 provides the asynchronous clear.
--
-- RESET is active LOW and asynchronously clears the
-- counter to zero.
-- =========================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity hcount is
    Port (
        RESET  : in  std_logic;
        LOAD0  : in  std_logic;
        LOAD1  : in  std_logic;
        LOAD2  : in  std_logic;
        LOAD3  : in  std_logic;
        LOAD4  : in  std_logic;
        LOAD5  : in  std_logic;
        LOAD6  : in  std_logic;
        LOAD7  : in  std_logic;
        LOAD8  : in  std_logic;
        LOAD9  : in  std_logic;
        CLK    : in  std_logic;
        COUNT0 : out std_logic;
        COUNT1 : out std_logic;
        COUNT2 : out std_logic;
        COUNT3 : out std_logic;
        COUNT4 : out std_logic;
        COUNT5 : out std_logic;
        COUNT6 : out std_logic;
        COUNT7 : out std_logic;
        COUNT8 : out std_logic;
        COUNT9 : out std_logic
    );
end hcount;

architecture Behavioral of hcount is
        -- Internal signals to hold current state for calculation (since outputs are ports)
        signal s_COUNT0, s_COUNT1, s_COUNT2, s_COUNT3, s_COUNT4, s_COUNT5, s_COUNT6, s_COUNT7, s_COUNT8, s_COUNT9 : std_logic;
        signal v_ZERO : std_logic;
        signal v_B1, v_B2, v_B3, v_B4, v_B5, v_B6, v_B7, v_B8, v_B9 : std_logic;
begin

            -- 1. ZERO DETECTION (based on current state)
            v_ZERO <= (not s_COUNT9) and (not s_COUNT8) and (not s_COUNT7) and (not s_COUNT6) and 
                      (not s_COUNT5) and (not s_COUNT4) and (not s_COUNT3) and (not s_COUNT2) and 
                      (not s_COUNT1) and (not s_COUNT0);

            -- 2. BORROW TERMS FOR BINARY DECREMENT (based on current state)
            v_B1 <= not s_COUNT0;
            v_B2 <= (not s_COUNT1) and (not s_COUNT0);
            v_B3 <= (not s_COUNT2) and (not s_COUNT1) and (not s_COUNT0);
            v_B4 <= (not s_COUNT3) and (not s_COUNT2) and (not s_COUNT1) and (not s_COUNT0);
            v_B5 <= (not s_COUNT4) and (not s_COUNT3) and (not s_COUNT2) and (not s_COUNT1) and (not s_COUNT0);
            v_B6 <= (not s_COUNT5) and (not s_COUNT4) and (not s_COUNT3) and (not s_COUNT2) and (not s_COUNT1) and (not s_COUNT0);
            v_B7 <= (not s_COUNT6) and (not s_COUNT5) and (not s_COUNT4) and (not s_COUNT3) and (not s_COUNT2) and (not s_COUNT1) and (not s_COUNT0);
            v_B8 <= (not s_COUNT7) and (not s_COUNT6) and (not s_COUNT5) and (not s_COUNT4) and (not s_COUNT3) and (not s_COUNT2) and (not s_COUNT1) and (not s_COUNT0);
            v_B9 <= (not s_COUNT8) and (not s_COUNT7) and (not s_COUNT6) and (not s_COUNT5) and (not s_COUNT4) and (not s_COUNT3) and (not s_COUNT2) and (not s_COUNT1) and (not s_COUNT0);


    process(CLK, RESET)
        -- Internal variables to calculate combinational logic based on current state
        
    begin
        -- Asynchronous Reset (Active Low as per /RESET)
        if RESET = '0' then
            s_COUNT0 <= '0';
            s_COUNT1 <= '0';
            s_COUNT2 <= '0';
            s_COUNT3 <= '0';
            s_COUNT4 <= '0';
            s_COUNT5 <= '0';
            s_COUNT6 <= '0';
            s_COUNT7 <= '0';
            s_COUNT8 <= '0';
            s_COUNT9 <= '0';
            
        elsif rising_edge(CLK) then

            -- 3. NEXT STATE LOGIC
            -- Bit 0
            s_COUNT0 <= (v_ZERO and LOAD0) or (not v_ZERO and not s_COUNT0);
            -- Bit 1
            s_COUNT1 <= (v_ZERO and LOAD1) or (not v_ZERO and (s_COUNT1 xor v_B1));
            -- Bit 2
            s_COUNT2 <= (v_ZERO and LOAD2) or (not v_ZERO and (s_COUNT2 xor v_B2));
            -- Bit 3
            s_COUNT3 <= (v_ZERO and LOAD3) or (not v_ZERO and (s_COUNT3 xor v_B3));
            -- Bit 4
            s_COUNT4 <= (v_ZERO and LOAD4) or (not v_ZERO and (s_COUNT4 xor v_B4));
            -- Bit 5
            s_COUNT5 <= (v_ZERO and LOAD5) or (not v_ZERO and (s_COUNT5 xor v_B5));
            -- Bit 6
            s_COUNT6 <= (v_ZERO and LOAD6) or (not v_ZERO and (s_COUNT6 xor v_B6));
            -- Bit 7
            s_COUNT7 <= (v_ZERO and LOAD7) or (not v_ZERO and (s_COUNT7 xor v_B7));
            -- Bit 8
            s_COUNT8 <= (v_ZERO and LOAD8) or (not v_ZERO and (s_COUNT8 xor v_B8));
            -- Bit 9
            s_COUNT9 <= (v_ZERO and LOAD9) or (not v_ZERO and (s_COUNT9 xor v_B9));
        end if;
    end process;

    -- Assign internal signals to output ports
    COUNT0 <= s_COUNT0;
    COUNT1 <= s_COUNT1;
    COUNT2 <= s_COUNT2;
    COUNT3 <= s_COUNT3;
    COUNT4 <= s_COUNT4;
    COUNT5 <= s_COUNT5;
    COUNT6 <= s_COUNT6;
    COUNT7 <= s_COUNT7;
    COUNT8 <= s_COUNT8;
    COUNT9 <= s_COUNT9;

end Behavioral;
