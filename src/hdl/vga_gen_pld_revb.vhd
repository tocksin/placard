-- ============================================================
-- vga_gen_pld_revb: the video timing PLDs of the REV B board
-- (H counter revision 09, V counter, Sync revision 13, audio slot
-- revision 05), wired as on the board.  The rev A board is
-- vga_gen_pld.vhd.
-- Date: 11/17/2026
--
-- Differences from vga_gen_pld: pixelColOut(2 downto 1) are the
-- Sync PLD's S2 and S1 (the color decoder's pixel selects, H2 and H1
-- on a normal line, H1 and H0 on a 160-read line); T2 (true H2) goes
-- from the Sync PLD to the H counter and the audio slot PLD; line
-- code bit 7 goes to the audio slot PLD; /AC_SEL is made by the IR
-- PLD (ir_pld_revb), so i1In and acSelNOut are gone.
-- ============================================================
library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;

library work;           use work.tools_pkg.all;

entity vga_gen_pld_revb is 

    port(clkIn          : in  sl;
        rstIn           : in  sl;
        hSyncOut        : out sl;
        vSyncOut        : out sl;
        videnOut        : out sl;   -- Sync PLD VIDEN, color decoder video enable
        pixelEnOut      : out sl;
        modeLdNOut      : out sl;   -- line code register /E, low in group 45
        hVideoActiveOut : out sl;   -- H counter PLD H_VIDEO_ACTIVE, rises at group 48 (audio DAC clock)
        rowA0Out        : out sl;   -- video address A0 (row address, line repeat)
        rowA1Out        : out sl;   -- video address A1
        rowA7Out        : out sl;   -- video address A7
        rowA8Out        : out sl;   -- video address A8
        lc2In           : in  sl;   -- line code register Q2 (line repeat)
        lc3In           : in  sl;   -- line code register Q3
        lc7In           : in  sl;   -- line code register Q7 (160-read line, audio slot PLD pin 21)
        pixelRowOut     : out slv(9 downto 0);
        pixelColOut     : out slv(9 downto 0);

        -- RAM write strobe (Sync PLD revision 10): CLK_E is clkIn in the model
        rwIn            : in sl;    -- State PLD RW, 0 = store
        runIn           : in sl;    -- RUN from the ROM cartridge
        weNOut          : out sl;   -- RAM /WE
        p0NIn           : in  sl;   -- I/O decode /P0, page 0 select (Sync PLD revision 12)
        mapWrNOut       : out sl    -- map register clock /MAP_WR (Sync PLD revision 12)
    );
end entity vga_gen_pld_revb;

architecture Behavioral of vga_gen_pld_revb is

    signal hcount : slv(9 downto 0);
    signal hVideoActive : sl;
    signal vVideoActive : sl;
    signal viden : sl;
 
    signal hTerminal : sl;
    signal vcount : slv(9 downto 0);
    
    signal pixelEnable : sl;
    signal blankRd : sl;    -- blanking read slot, audio PLD pin 23 to Sync PLD pin 13
    signal modeLdN : sl;    -- mode byte load, audio PLD pin 22 (active low)
    signal rowA0   : sl;    -- row address bits from the audio PLD, pins 17-20
    signal rowA1   : sl;
    signal rowA7   : sl;
    signal rowA8   : sl;
    signal trueH2  : sl;    -- T2, Sync PLD pin 21: true H2 (hcount(2 downto 1) are S2 and S1)
    
begin

    hcountPLD: entity work.hcount_pld_revb
    port map(
        CLK            => clkIn,
--        RESET          => rstIn,
        RESET          => '0',

        H0             => hcount(0),
        S1             => hcount(1),
        S2             => hcount(2),
        T2             => trueH2,

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

    -- Blanking read slots: the mode byte in group 45 on every line, at
    -- 5A00h + V8:V0 (see docs/video/VIDEO.md), and the audio sample in group 46 on
    -- lines 499-511 and group 47 on lines 512-1023, so the audio read
    -- address runs 5DF3h-5FFFh (see docs/sound/SOUND.md).  It also remaps the row
    -- address bits A0, A1, A7 and A8 for the line repeat modes (line code
    -- bits 3:2).
    audioPLD : entity work.audio_pld_revb
    port map(
        V0          => vcount(0),
        H9          => hcount(9),
        H8          => hcount(8),
        H7          => hcount(7),
        H6          => hcount(6),
        H5          => hcount(5),
        H4          => hcount(4),
        H3          => hcount(3),
        V9          => vcount(9),
        V1          => vcount(1),
        V7          => vcount(7),
        V8          => vcount(8),
        LC2         => lc2In,
        LC3         => lc3In,
        T2          => trueH2,

        R0          => rowA0,
        R1          => rowA1,
        R7          => rowA7,
        R8          => rowA8,
        LC7         => lc7In,
        MODE_LD     => modeLdN,
        BLANK_RD    => blankRd
    );

    syncPLD : entity work.sync_pld_revb
    port map(
        CLK              => clkIn,

        V9               => vcount(9),
        V5               => vcount(5),
        P0_N             => p0NIn,
        V3               => vcount(3),
        V2               => vcount(2),
        V1               => vcount(1),

        H_VIDEO_ACTIVE   => hVideoActive,

        CLK_E            => clkIn,
        RW               => rwIn,
        RUN              => runIn,

        BLANK_RD         => blankRd,

        H0               => hcount(0),
        S1               => hcount(1),
        S2               => hcount(2),
        T2               => trueH2,

        V_VIDEO_ACTIVE   => vVideoActive,
        VIDEN            => viden,
        VSYNC            => vSyncOut,
        PIXEL_ENABLE     => pixelEnable,

        WE_N             => weNOut,
        MAP_WR_N         => mapWrNOut
    );

    pixelRowOut <= vcount;
    pixelColOut <= hcount;
    videnOut <= viden;
    pixelEnOut <= pixelEnable;
    modeLdNOut <= modeLdN;
    hVideoActiveOut <= hVideoActive;
    rowA0Out <= rowA0;
    rowA1Out <= rowA1;
    rowA7Out <= rowA7;
    rowA8Out <= rowA8;
end Behavioral;
