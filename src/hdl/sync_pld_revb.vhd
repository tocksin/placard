--------------------------------------------------------------------------------
-- Name     VGA_SYNC
-- Date     2026-11-17
-- Revision 13 (rev B board only; the rev A board is sync_pld.vhd, revision 12)
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source src/pld/rev_b/ATF22V10_SYNC.pld (Revision 13).
-- The equations are translated as written, one signal per pin.
--
-- Revision 13: 160-read lines.  On a line whose mode byte has bit 7 set,
-- while VIDEN is high, pins 16 and 15 (S2, S1) carry H1 and H0 instead of
-- H2 and H1, so the color decoder steps through a byte in 4 clocks.  Pin 21
-- (T2) is always the true H2.  A second video read is made at count 011.
-- /P0 moves to pin 4 (was V4) and VSYNC is lines 508-509.
--
-- Pin assignments (pin 12 = GND, pin 24 = VCC):
--   PIN 1  = CLK               PIN 13 = BLANK_RD
--   PIN 2  = V9                PIN 14 = H0
--   PIN 3  = V5                PIN 15 = S1
--   PIN 4  = !P0               PIN 16 = S2
--   PIN 5  = V3                PIN 17 = VIDEN
--   PIN 6  = V2                PIN 18 = !VSYNC
--   PIN 7  = V1                PIN 19 = PIXEL_ENABLE
--   PIN 8  = H_VIDEO_ACTIVE    PIN 20 = !WE
--   PIN 9  = CLK_E             PIN 21 = T2
--   PIN 10 = RW                PIN 22 = !MAP_WR
--   PIN 11 = RUN               PIN 23 = V_VIDEO_ACTIVE
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity sync_pld_revb is
    port (
        CLK              : in  std_logic;   -- PIN 1
        V9               : in  std_logic;   -- PIN 2
        V5               : in  std_logic;   -- PIN 3
        P0_N             : in  std_logic;   -- PIN 4  (active low, I/O decode PLD pin 17)
        V3               : in  std_logic;   -- PIN 5
        V2               : in  std_logic;   -- PIN 6
        V1               : in  std_logic;   -- PIN 7
        H_VIDEO_ACTIVE   : in  std_logic;   -- PIN 8
        CLK_E            : in  std_logic;   -- PIN 9, early clock tap (the same clock in the FPGA model)
        RW               : in  std_logic;   -- PIN 10, State PLD pin 23, 0 = store
        RUN              : in  std_logic;   -- PIN 11, ROM cartridge, 0 = loading
        BLANK_RD         : in  std_logic;   -- PIN 13, blanking read slot and 160-read line marker
        H0               : out std_logic;   -- PIN 14
        S1               : out std_logic;   -- PIN 15, H1, or H0 on a 160-read line
        S2               : out std_logic;   -- PIN 16, H2, or H1 on a 160-read line
        VIDEN            : out std_logic;   -- PIN 17
        VSYNC            : out std_logic;   -- PIN 18  (active low)
        PIXEL_ENABLE     : out std_logic;   -- PIN 19
        WE_N             : out std_logic;   -- PIN 20  (active low; floats while RUN = 0 on the real part)
        T2               : out std_logic;   -- PIN 21, true H2
        MAP_WR_N         : out std_logic;   -- PIN 22  (active low, map register clock)
        V_VIDEO_ACTIVE   : out std_logic    -- PIN 23
    );
end entity sync_pld_revb;

architecture rtl of sync_pld_revb is
    signal h0Q           : std_logic := '0';
    signal s1Q           : std_logic := '0';
    signal s2Q           : std_logic := '0';
    signal t2Q           : std_logic := '0';
    signal vVideoActiveQ : std_logic := '0';
    signal videnQ        : std_logic := '0';
    signal pixelEnableQ  : std_logic := '0';

    signal m             : std_logic;   -- 160-read line, picture on
    signal t1            : std_logic;   -- true H1

    signal h0D           : std_logic;
    signal s1D           : std_logic;
    signal s2D           : std_logic;
    signal t2D           : std_logic;
    signal vVideoActiveD : std_logic;
    signal videnD        : std_logic;
    signal pixelEnableD  : std_logic;
begin

    -- M  = VIDEN & BLANK_RD;
    m <= videnQ and BLANK_RD;

    -- T1 = M & S2 # !M & S1;
    t1 <= (m and s2Q) or ((not m) and s1Q);

    -- H0.D = !H0;
    h0D <= not h0Q;

    -- T2.D = T2 $ (T1 & H0);
    t2D <= t2Q xor (t1 and h0Q);

    -- S1.D = M & !H0 # !M & (S1 $ H0);
    s1D <= (m and (not h0Q))
        or ((not m) and (s1Q xor h0Q));

    -- S2.D = M & (S2 $ H0) # !M & (T2 $ (S1 & H0));
    s2D <= (m and (s2Q xor h0Q))
        or ((not m) and (t2Q xor (s1Q and h0Q)));

    -- V_VIDEO_ACTIVE.D = V9 & (V5 # V_VIDEO_ACTIVE);
    vVideoActiveD <= V9 and (V5 or vVideoActiveQ);

    -- VIDEN.D
    videnD <= (vVideoActiveQ and H_VIDEO_ACTIVE and t2Q and s2Q and s1Q and h0Q)
           or (videnQ and (not t2Q))
           or (videnQ and (not s2Q))
           or (videnQ and (not s1Q))
           or (videnQ and (not h0Q));

    -- PIXEL_ENABLE.D
    pixelEnableD <=
           (vVideoActiveQ and H_VIDEO_ACTIVE and (not m) and t2Q and s1Q and (not h0Q))                    -- read A, normal line
        or (vVideoActiveQ and H_VIDEO_ACTIVE and m and t2Q and s2Q and (not s1Q) and (not h0Q))            -- read A, 160-read line
        or (vVideoActiveQ and H_VIDEO_ACTIVE and m and RUN and (not t2Q) and s2Q and (not s1Q) and (not h0Q))  -- read B
        or (BLANK_RD and (not videnQ) and t2Q and s1Q and (not h0Q));                                      -- mode byte and audio reads

    -- VSYNC = !V9 & V3 & V2 & !V1;   (pin declared !VSYNC)
    VSYNC <= not ((not V9) and V3 and V2 and (not V1));

    -- WE = !CLK_E & !CLK & !RW & !PIXEL_ENABLE;   (pin declared !WE; WE.OE = RUN)
    WE_N <= not ((not CLK_E) and (not CLK) and (not RW) and (not pixelEnableQ));

    -- MAP_WR = !CLK_E & !CLK & !RW & !PIXEL_ENABLE & P0;   (pin declared !MAP_WR)
    MAP_WR_N <= not ((not CLK_E) and (not CLK) and (not RW) and (not pixelEnableQ) and (not P0_N));

    process (CLK)
    begin
        if rising_edge(CLK) then
            h0Q           <= h0D;
            s1Q           <= s1D;
            s2Q           <= s2D;
            t2Q           <= t2D;
            vVideoActiveQ <= vVideoActiveD;
            videnQ        <= videnD;
            pixelEnableQ  <= pixelEnableD;
        end if;
    end process;

    H0             <= h0Q;
    S1             <= s1Q;
    S2             <= s2Q;
    T2             <= t2Q;
    V_VIDEO_ACTIVE <= vVideoActiveQ;
    VIDEN          <= videnQ;
    PIXEL_ENABLE   <= pixelEnableQ;

end architecture rtl;
