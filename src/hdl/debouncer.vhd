----------------------------------------------------------------------------
--  debouncer.vhd -- Signal Debouncer
----------------------------------------------------------------------------
-- Author:  Sam Bobrowicz
--          Copyright 2011 Digilent, Inc.
----------------------------------------------------------------------------
--
----------------------------------------------------------------------------
-- This component is used to debounce signals. It is designed to
-- independently debounce a variable number of signals, the number of which
-- are set using the PORT_WIDTH generic. Debouncing is done by only 
-- registering a change in a button state if it remains constant for 
-- the number of clocks determined by the DEBNC_CLOCKS generic. 
--                      
-- Generic Descriptions:
--
--   PORT_WIDTH - The number of signals to debounce. determines the width
--                of the rawIn and debouncedOut std_logic_vectors
--   DEBNC_CLOCKS - The number of clocks (clkIn) to wait before registering
--                  a change.
--
-- Port Descriptions:
--
--   rawIn - The input signals. A vector of width equal to PORT_WIDTH
--   clkIn  - Input clock
--   debouncedOut - The debounced signals. A vector of width equal to PORT_WIDTH
--                                              
----------------------------------------------------------------------------
--
----------------------------------------------------------------------------
-- Revision History:
--  08/08/2011(SamB): Created using Xilinx Tools 13.2
--  08/29/2013(SamB): Improved reuseability by using generics
----------------------------------------------------------------------------

library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;
                        
library work;           use work.tools_pkg.all;

entity debouncer is
    Generic(DEBNC_CLOCKS    : INTEGER range 2 to (INTEGER'high) := 2**16;
            PORT_WIDTH      : INTEGER range 1 to (INTEGER'high) := 5);
    Port(   clkIn           : in    std_logic;
            rstIn           : in    std_logic;
            rawIn           : in    std_logic_vector;
            debouncedOut    :   out std_logic_vector
    );
end entity debouncer;

architecture Behavioral of debouncer is

    constant CNTR_WIDTH : integer := log2(DEBNC_CLOCKS);
    constant CNTR_MAX   : std_logic_vector((CNTR_WIDTH - 1) downto 0) := std_logic_vector(to_unsigned((DEBNC_CLOCKS - 1), CNTR_WIDTH));
    type VECTOR_ARRAY_TYPE is array (integer range <>) of std_logic_vector((CNTR_WIDTH - 1) downto 0);

    signal sig_cntrs_ary : VECTOR_ARRAY_TYPE (0 to (rawIn'length - 1));

    signal sig_out_reg   : std_logic_vector((rawIn'length - 1) downto 0);

    signal inR           : std_logic_vector(rawIn'range);
    signal inRR          : std_logic_vector(rawIn'range);

begin

    inRegProc: process (clkIn, rstIn)
    begin
        if (rstIn = '1') then
            inR <= (others => '0');
            inRR <= (others => '0');
        elsif rising_edge(clkIn) then
            inR <= rawIn;
            inRR <= inR;
        end if;
    end process inRegProc;

    debounce_process : process (clkIn, rstIn)
    begin
        if (rstIn = '1') then
            sig_out_reg <= (others => '0');
        elsif (rising_edge(clkIn)) then
            for index in 0 to (rawIn'length - 1) loop
                if (sig_cntrs_ary(index) = CNTR_MAX) then
                    sig_out_reg(index) <= not(sig_out_reg(index));
                end if;
            end loop;
        end if;
    end process debounce_process;

    counter_process : process (clkIn, rstIn)
    begin
        if (rstIn = '1') then
            for index in 0 to (rawIn'length - 1) loop
                sig_cntrs_ary(index) <= (others => '0');
            end loop;
        elsif (rising_edge(clkIn)) then
            for index in 0 to (rawIn'length - 1) loop
                if ((sig_out_reg(index) = '1') xor (inRR(index) = '1')) then
                    if (sig_cntrs_ary(index) = CNTR_MAX) then
                        sig_cntrs_ary(index) <= (others => '0');
                    else
                        sig_cntrs_ary(index) <= std_logic_vector(unsigned(sig_cntrs_ary(index)) + 1);
                    end if;
                else
                    sig_cntrs_ary(index) <= (others => '0');
                end if;
            end loop;
        end if;
    end process;

    debouncedOut <= sig_out_reg;

end architecture Behavioral;

