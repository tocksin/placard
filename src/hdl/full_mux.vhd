/*
* @file full_mux.vhd
* @brief Dual mux for each side of the memory address
* @author Justin Davis
*
* Copyright: 2026 by Southwest Research Institute; all rights reserved
**************************************************************************/
library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;

library work;           use work.tools_pkg.all;

entity full_mux is
    port ( sel          : in slv(1 downto 0);
           aPort        : in slv(7 downto 0);
           bPort        : in slv(7 downto 0);
           cPort        : in slv(7 downto 0);
           dPort        : in slv(7 downto 0);
           yPort        : out slv(7 downto 0)
    );
end entity full_mux;

architecture Behavioral of full_mux is

begin

    lowerComp : entity work.quad_4to1_mux
    port map(
        -- MUX 0
        a0 => aPort(0),
        b0 => bPort(0),
        c0 => cPort(0),
        d0 => dPort(0),

        -- MUX 1
        a1 => aPort(1),
        b1 => bPort(1),
        c1 => cPort(1),
        d1 => dPort(1),

        -- Common select
        s0 => sel(0),
        s1 => sel(1),

        -- MUX 2
        a2 => aPort(2),
        b2 => bPort(2),
        c2 => cPort(2),
        d2 => dPort(2),

        -- MUX 3
        a3 => aPort(3),
        b3 => bPort(3),
        c3 => cPort(3),
        d3 => dPort(3),

        -- Outputs
        y0 => yPort(0),
        y1 => yPort(1),
        y2 => yPort(2),
        y3 => yPort(3)
    );

    upperComp : entity work.quad_4to1_mux
    port map(
        -- MUX 0
        a0 => aPort(4),
        b0 => bPort(4),
        c0 => cPort(4),
        d0 => dPort(4),

        -- MUX 1
        a1 => aPort(5),
        b1 => bPort(5),
        c1 => cPort(5),
        d1 => dPort(5),

        -- Common select
        s0 => sel(0),
        s1 => sel(1),

        -- MUX 2
        a2 => aPort(6),
        b2 => bPort(6),
        c2 => cPort(6),
        d2 => dPort(6),

        -- MUX 3
        a3 => aPort(7),
        b3 => bPort(7),
        c3 => cPort(7),
        d3 => dPort(7),

        -- Outputs
        y0 => yPort(4),
        y1 => yPort(5),
        y2 => yPort(6),
        y3 => yPort(7)
    );

end architecture Behavioral;
