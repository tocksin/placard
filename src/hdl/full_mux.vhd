/*
* @file full_mux.vhd
* @brief The four address mux PLDs (U7-U10): the whole 16-bit address
* @author Justin Davis
*
*
* 10/27/2026: mux PLD revision 02 (docs/FETCH_TIMING.md, option B).
* Each chip makes two low and two high address bits and takes the
* address-source enables as its selects, so this entity is the whole
* address mux (it was one byte, with the Sync PLD's selects, before).
**************************************************************************/
library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;

library work;           use work.tools_pkg.all;

entity full_mux is
    port ( pixelEnable  : in sl;                 -- Sync PLD PIXEL_ENABLE
           pcEnable     : in sl;                 -- State PLD PC_ENABLE
           xEnable      : in sl;                 -- State PLD X_ENABLE
           yEnable      : in sl;                 -- State PLD Y_ENABLE
           dPort        : in slv(7 downto 0);    -- D register (low byte default)
           xPort        : in slv(7 downto 0);    -- X register
           yPort        : in slv(7 downto 0);    -- Y register
           videoPort    : in slv(15 downto 0);   -- video address
           pcPort       : in slv(15 downto 0);   -- program counter
           addrPort     : out slv(15 downto 0)
    );
end entity full_mux;

architecture Behavioral of full_mux is

begin

    -- U7: A1:A0 and A9:A8; U8: A3:A2 and A11:A10;
    -- U9: A5:A4 and A13:A12; U10: A7:A6 and A15:A14
    muxGen : for n in 0 to 3 generate
        muxComp : entity work.quad_4to1_mux
        port map(
            pixelEnable => pixelEnable,
            pcEnable    => pcEnable,
            xEnable     => xEnable,
            yEnable     => yEnable,

            d0          => dPort(2 * n),
            x0          => xPort(2 * n),
            v0          => videoPort(2 * n),
            pc0         => pcPort(2 * n),

            d1          => dPort(2 * n + 1),
            x1          => xPort(2 * n + 1),
            v1          => videoPort(2 * n + 1),
            pc1         => pcPort(2 * n + 1),

            y2          => yPort(2 * n),
            v2          => videoPort(2 * n + 8),
            pc2         => pcPort(2 * n + 8),

            y3          => yPort(2 * n + 1),
            v3          => videoPort(2 * n + 9),
            pc3         => pcPort(2 * n + 9),

            lo0         => addrPort(2 * n),
            lo1         => addrPort(2 * n + 1),
            hi0         => addrPort(2 * n + 8),
            hi1         => addrPort(2 * n + 9)
        );
    end generate muxGen;

end architecture Behavioral;
