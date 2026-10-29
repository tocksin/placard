-- @file vga_sync.vhd
-- @brief Creates VGA timing for sync signals
-- @author Justin Davis
--
-- Date: 09/14/2026
-------------------------------------------------------------------------------

library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;

library work;           use work.tools_pkg.all;

entity vgaSync is 

    port(clkIn            : in  sl;
         rstIn            : in  sl;
         hSyncOut         : out sl;
         vSyncOut         : out sl;
         videoEnOut       : out sl;
         ramEnOut         : out sl;
         pixelRowOut      : out slv(9 downto 0);
         pixelColOut      : out slv(9 downto 0);
         subpixelRowOut   : out slv(8 downto 0);
         subpixelColOut   : out slv(8 downto 0)
    );
end entity vgaSync;

architecture rtl of vgaSync is
    constant divider      : integer := 4;
    
    --  As implemented:
    --  Horiz_sync  ------------------------------------__________--------
    --  H_count     0                 639             655       751    799

    --  Alternatives:
    --  Horiz_sync  ------------------------------------__________--------
    --  H_count     224               863             879       975   1023
    --
    --  Active video___________________________------------------------------
    --  Horiz_sync  --------__________---------------------------------------
    --  H_count     224     240       336      384                       1023
    constant H_CNT_START  : integer := 224;
    constant H_SYNC_START : integer := H_CNT_START + 16;
    constant H_SYNC_END   : integer := H_SYNC_START + 96;
    constant H_VIS_START  : integer := H_SYNC_END+48;
    constant H_VIS_END    : integer := H_VIS_START+639;
    constant H_SCREEN_END : integer := 1023;

    --  As implemented:
    --  Vert_sync      ----------------------------------_______------------
    --  V_count        0                         479     489-491         524
    --
    --  Alternatives:
    --  Active video   _______________________------------------------------
    --  Vert_sync      --------_______--------------------------------------
    --  V_count        499     532    534     544                       1023
    constant V_CNT_START  : integer := 499;
    constant V_SYNC_START : integer := V_CNT_START + 33;
    constant V_SYNC_END   : integer := V_SYNC_START + 2;
    constant V_VIS_START  : integer := V_SYNC_END + 10;
    constant V_VIS_END    : integer := V_VIS_START+479;
    constant V_SCREEN_END : integer := 1023;
   
    signal horiz_sync     : sl; 
    signal vert_sync      : sl;
    signal video_on_v     : sl; 
    signal video_on_h     : sl;
    signal h_count        : unsigned(9 downto 0); 
    signal v_count        : unsigned(9 downto 0);
    signal h_divider      : unsigned(2 downto 0);
    signal v_divider      : unsigned(2 downto 0);
    signal h_subcount     : unsigned(8 downto 0);
    signal v_subcount     : unsigned(8 downto 0);
    signal h_terminal       : sl;
    signal v_terminal       : sl;
     
begin

    cntProc : process (clkIn, rstIn)
    begin
        if (rstIn = '1') then
            h_count <= to_unsigned(H_CNT_START, h_count'length);
            v_count <= to_unsigned(V_CNT_START, h_count'length);
        elsif rising_edge(clkIn) then
            -- H_count counts horizontal pixels
            if (h_terminal = '1') then 
                h_count <= to_unsigned(H_CNT_START, h_count'length);
                -- V_count counts rows of pixels
                -- increment only at the end of row
                if (v_terminal = '1') then 
                    v_count <= to_unsigned(V_CNT_START, h_count'length);
                else 
                    v_count <= v_count + 1;
                end if;
            else
                h_count <= h_count + 1;
            end if;
        end if;
    end process cntProc;

    h_terminal <= '1' when (h_count = to_unsigned(H_SCREEN_END, h_count'length)) else '0';
    v_terminal <= '1' when (v_count = to_unsigned(V_SCREEN_END, v_count'length)) else '0';
    
    syncProc : process (all)
    begin
        --Generate Horizontal Sync Signal using H_count
        if (h_count >= to_unsigned(H_SYNC_START, h_count'length)) and 
           (h_count <= to_unsigned(H_SYNC_END, h_count'length)) then
            horiz_sync <= '0';
        else
            horiz_sync <= '1';
        end if;
    
            -- Generate Vertical Sync Signal using V_count
        if (v_count >= to_unsigned(V_SYNC_START, v_count'length)) and 
           (v_count <= to_unsigned(V_SYNC_END, v_count'length)) then
            vert_sync <= '0';
        else
            vert_sync <= '1';
        end if;
    
            -- Generate Video on Screen Signals for Pixel Data
        if (h_count >= to_unsigned(H_VIS_START+1, h_count'length)) and
           (h_count <= to_unsigned(H_VIS_END, h_count'length)) then
            video_on_h <= '1';
        else
            video_on_h <= '0';
        end if;
    
        if (v_count >= to_unsigned(V_VIS_START, h_count'length)) and
           (v_count <= to_unsigned(V_VIS_END, v_count'length)) then
            video_on_v <= '1';
        else
            video_on_v <= '0';
        end if;

            -- Generate Video on Screen Signals for Pixel Data
        if (h_count >= to_unsigned(H_VIS_START, h_count'length)) and
           (h_count <= to_unsigned(H_VIS_END, h_count'length)) and 
           (v_count >= to_unsigned(V_VIS_START, h_count'length)) and
           (v_count <= to_unsigned(V_VIS_END, v_count'length)) then
            ramEnOut <= '1';
        else
            ramEnOut <= '0';
        end if;
    
    end process syncProc;

    hSyncOut <= horiz_sync;
    vSyncOut <= vert_sync;

    -- videoEnOut is high only when RGB data is being displayed
    videoEnOut <= video_on_H and video_on_V;
    
    pixelColOut <= slv(h_count);
    pixelRowOut <= slv(v_count);

    subpixelRowOut <= slv(h_count(8 downto 0)) when videoEnOut='1' else (8 downto 0 => '0');
    subpixelColOut <= slv(v_count(8 downto 0)) when videoEnOut='1' else (8 downto 0 => '0');

/*
    subCountProc: process (clkIn, rstIn)
    begin
        if (rstIn = '1') then
            h_divider      <= (others => '0');
            h_subcount     <= (others => '0'); 
            v_divider      <= (others => '0');
            v_subcount     <= (others => '0');
            subpixelRowOut <= (others => '0');
            subpixelColOut <= (others => '0');

        elsif rising_edge(clkIn) then
            if (h_terminal = '1') then
                h_divider <= "000";
                h_subcount <= "000000000";
            elsif (h_divider = to_unsigned(divider, h_divider'length)) then
                h_divider <= "000";
                h_subcount <= h_subcount +1;
            else
                h_divider <= h_divider +1;
            end if;
        
            if (v_terminal = '1') then
                v_divider <= "000";
                v_subcount <= "000000000";
            elsif ((v_divider=divider) and (h_count = to_unsigned(H_TRIGGER, h_count'length)))then
                v_divider <= "000";
                v_subcount <= v_subcount +1;
            elsif (h_count = to_unsigned(H_TRIGGER, h_count'length)) then
                v_divider <= v_divider +1;
            end if;
        
        end if;      
    end process subCountProc;
*/

end architecture rtl;
