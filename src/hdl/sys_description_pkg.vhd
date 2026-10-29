-- @file sys_description_pkg.vhd
-- @brief System description
-- @author Justin Davis
--
-- Date: 09/14/2026
-------------------------------------------------------------------------------

library ieee;       use ieee.std_logic_1164.all;
                    use ieee.numeric_std.all;
                    
library work;       use work.tools_pkg.all;

package sys_description_pkg is

    -- Clock periods
    constant INPUT_CLOCK_PERIOD           : time    :=   10 ns; -- 100 MHz
    constant SYS_CLOCK_PERIOD             : time    :=   INPUT_CLOCK_PERIOD/2;
    constant HEARTBEAT_PERIOD             : time    :=  1000 ms; -- 1 Hz
    constant HEARTBEAT_CNTS               : integer := HEARTBEAT_PERIOD / SYS_CLOCK_PERIOD;
    constant HEARTBEAT_CNT_SIZE           : natural := log2(HEARTBEAT_CNTS,UP);
   
end sys_description_pkg;

package body sys_description_pkg is
end sys_description_pkg;