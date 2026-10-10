-- @file tb_counters.vhd
-- @brief This is a testbench for the horizontal and vertical counters
-- @author Justin Davis
--
-- Date: 09/11/2026
--
-------------------------------------------------------------------------------

library ieee;       use ieee.std_logic_1164.all;
                    use ieee.numeric_std.all;
                    use std.textio.all;

library work;       use work.tools_pkg.all;
                    use work.logging_pkg.all;

entity tb_counters is
end entity tb_counters;

architecture behavioral of tb_counters is

    constant VGA_PERIOD : time := 39.721 ns;

    signal reloadH      : slv(9 downto 0) := slv(to_unsigned(799, 10));
    signal reloadV      : slv(9 downto 0) := slv(to_unsigned(524, 10));
    signal h            : slv(9 downto 0);
    signal v            : slv(9 downto 0);
    signal clk          : sl := '0';
    signal reset        : sl := '0';
    signal eol          : sl;
    
    signal hsync        : sl;
    signal vsync        : sl;
    signal videoEn      : sl;
    
begin

    reset <= '0', '1' after 10 ns;
    clk <= not clk after VGA_PERIOD/2;

    hcountComp : entity work.hcount
    port map(
        RESET  => reset,
        LOAD0  => reloadH(0),
        LOAD1  => reloadH(1),
        LOAD2  => reloadH(2),
        LOAD3  => reloadH(3),
        LOAD4  => reloadH(4),
        LOAD5  => reloadH(5),
        LOAD6  => reloadH(6),
        LOAD7  => reloadH(7),
        LOAD8  => reloadH(8),
        LOAD9  => reloadH(9),
        CLK    => clk,
        COUNT0 => h(0),
        COUNT1 => h(1),
        COUNT2 => h(2),
        COUNT3 => h(3),
        COUNT4 => h(4),
        COUNT5 => h(5),
        COUNT6 => h(6),
        COUNT7 => h(7),
        COUNT8 => h(8),
        COUNT9 => h(9)
        );

    eol <= '1' when h="0000000000" else '0';

    vcountComp : entity work.hcount
    port map(
        RESET  => reset,
        LOAD0  => reloadV(0),
        LOAD1  => reloadV(1),
        LOAD2  => reloadV(2),
        LOAD3  => reloadV(3),
        LOAD4  => reloadV(4),
        LOAD5  => reloadV(5),
        LOAD6  => reloadV(6),
        LOAD7  => reloadV(7),
        LOAD8  => reloadV(8),
        LOAD9  => reloadV(9),
        CLK    => eol,
        COUNT0 => v(0),
        COUNT1 => v(1),
        COUNT2 => v(2),
        COUNT3 => v(3),
        COUNT4 => v(4),
        COUNT5 => v(5),
        COUNT6 => v(6),
        COUNT7 => v(7),
        COUNT8 => v(8),
        COUNT9 => v(9)
        );

    syncComp : entity work.syncs
    port map(
        -- Horizontal counter bits
        H9 => h(9), 
        H8 => h(8), 
        H7 => h(7), 
        H6 => h(6), 
        H5 => h(5), 
        H4 => h(4),
        -- Vertical counter bits
        V9 => v(9), 
        V8 => v(8), 
        V7 => v(7), 
        V6 => v(6), 
        V5 => v(5), 
        V4 => v(4), 
        V3 => v(3), 
        V2 => v(2), 
        V1 => v(1),
        -- Outputs
        HSYNC => hsync,
        VSYNC => vsync, 
        VIDEO_ENABLE => videoEn
    );

end architecture behavioral;
