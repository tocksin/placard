-- @file tb_video.vhd
-- @brief Testbench to exercise the timing of the vga signals
-- @author Justin Davis
--
-- Date: 09/14/2026
-------------------------------------------------------------------------------

library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;
                        
library work;           use work.tools_pkg.all;

entity tb_video is
end tb_video;

architecture Behavioral of tb_video is
    constant CLK_PERIOD     : time := 39.721 ns;

    signal clkSys           : sl                := '0';
    signal rstSys           : sl                := '0';

    signal hSync            : sl;
    signal vSync            : sl;
    signal videoEn          : sl;
    signal pixelRow         : slv(9 downto 0);
    signal pixelCol         : slv(9 downto 0);
    signal subpixelRow      : slv(8 downto 0);
    signal subpixelCol      : slv(8 downto 0);

begin
    clkSys <= not clkSys after CLK_PERIOD/2;
    rstSys <= '1', '0' after CLK_PERIOD*10;

    vgaGenComp: entity work.vgaSync
    port map(   clkIn           => clkSys,
                rstIn           => rstSys,
                hSyncOut        => hSync,
                vSyncOut        => vSync,
                videoEnOut      => videoEn,
                pixelRowOut     => pixelRow,
                pixelColOut     => pixelCol,
                subpixelRowOut  => subpixelRow,
                subpixelColOut  => subpixelCol
    );


end Behavioral;
