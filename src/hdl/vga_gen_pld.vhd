-- @file vga_gen_pld.vhd
-- @brief Creates VGA timing for sync signals using PLD conversions
-- @author Justin Davis
--
-- Date: 10/01/2026
-------------------------------------------------------------------------------

library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;

library work;           use work.tools_pkg.all;

entity vga_gen_pld is 

    port(clkIn          : in  sl;
        rstIn           : in  sl;
        hSyncOut        : out sl;
        vSyncOut        : out sl;
        videoActiveOut  : out sl;
        pixelEnOut      : out sl;
        pixelRowOut     : out slv(9 downto 0);
        pixelColOut     : out slv(9 downto 0);

        pcEnableIn      : in sl;
        yEnableIn       : in sl;
        xEnableIn       : in sl;

        muxSelBothOut   : out sl;
        muxSelLoOut     : out sl;
        muxSelHiOut     : out sl
    );
end entity vga_gen_pld;

architecture Behavioral of vga_gen_pld is

    signal hcount : slv(9 downto 0);
    signal hVideoActive : sl;
    signal vVideoActive : sl;
    signal videoActive : sl;
 
    signal hTerminal : sl;
    signal vcount : slv(9 downto 0);
    
    signal pixelEnable : sl;
    
begin

    hcountPLD: entity work.hcount_pld
    port map(
        CLK            => clkIn,
--        RESET          => rstIn,
        RESET          => '0',

        H0             => hcount(0),
        H1             => hcount(1),
        H2             => hcount(2),

        H3             => hcount(3),
        H4             => hcount(4),
        H5             => hcount(5),
        H6             => hcount(6),
        H7             => hcount(7),
        H8             => hcount(8),
        H9             => hcount(9),

        HSYNC          => hSyncOut,
        H_VIDEO_ACTIVE => hVideoActive,
        H_TC           => hTerminal
    );

    vcountPLD: entity work.vcount_pld
    port map(
        CLK         => clkIn,
        EN          => hTerminal,
        Q0          => vcount(0),
        Q1          => vcount(1),
        Q2          => vcount(2),
        Q3          => vcount(3),
        Q4          => vcount(4),
        Q5          => vcount(5),
        Q6          => vcount(6),
        Q7          => vcount(7),
        Q8          => vcount(8),
        Q9          => vcount(9)
    );

    syncPLD : entity work.sync_pld
    port map(
        CLK              => clkIn,

        V9               => vcount(9),
        V5               => vcount(5),
        V4               => vcount(4),
        V3               => vcount(3),
        V2               => vcount(2),
        V1               => vcount(1),

        H_VIDEO_ACTIVE   => hVideoActive,

        PC_ENABLE        => pcEnableIn,
        Y_ENABLE         => yEnableIn,
        X_ENABLE         => xEnableIn,

        H0               => hcount(0),
        H1               => hcount(1),
        H2               => hcount(2),

        V_VIDEO_ACTIVE   => vVideoActive,
        VIDEO_ACTIVE     => videoActive,
        VSYNC            => vSyncOut,
        BYTE_ENABLE      => pixelEnable,

        ADDR_SEL         => muxSelBothOut,
        ADDR_SEL_HI      => muxSelLoOut,
        ADDR_SEL_LO      => muxSelHiOut
    );

    pixelRowOut <= vcount;
    pixelColOut <= hcount;
    videoActiveOut <= videoActive;
    pixelEnOut <= pixelEnable;
end Behavioral;
