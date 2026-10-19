--------------------------------------------------------------------------------
-- Name     H_COUNTER
-- PartNo   00
-- Date     10/19/2026
-- Revision 07
-- Designer
-- Company
-- Assembly
-- Location
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_HCOUNT.pld (Revision 07)
--
-- Pin assignments (ATF22V10C, 24-pin DIP/SOIC; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = CLK
--   PIN 2  = RESET             (declared in the original, not used in any equation)
--
--   PIN 3  = H0                (input, from the Sync PLD)
--   PIN 4  = H1                (input, from the Sync PLD)
--   PIN 5  = H2                (input, from the Sync PLD)
--
--   PIN 14 = H3                (registered output)
--   PIN 15 = H4                (registered output)
--   PIN 16 = H5                (registered output)
--   PIN 17 = H6                (registered output)
--   PIN 18 = H7                (registered output)
--   PIN 19 = H8                (registered output)
--   PIN 20 = H9                (registered output)
--
--   PIN 21 = HSYNC             (registered output, ACTIVE LOW)
--   PIN 22 = H_VIDEO_ACTIVE    (registered output)
--   PIN 23 = H_TC              (combinatorial output)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity hcount_pld is
    port (
        CLK            : in  std_logic;   -- PIN 1
        RESET          : in  std_logic;   -- PIN 2  (unused, as in original)

        H0             : in  std_logic;   -- PIN 3
        H1             : in  std_logic;   -- PIN 4
        H2             : in  std_logic;   -- PIN 5

        H3             : out std_logic;   -- PIN 14
        H4             : out std_logic;   -- PIN 15
        H5             : out std_logic;   -- PIN 16
        H6             : out std_logic;   -- PIN 17
        H7             : out std_logic;   -- PIN 18
        H8             : out std_logic;   -- PIN 19
        H9             : out std_logic;   -- PIN 20

        HSYNC          : out std_logic;   -- PIN 21  (active low)
        H_VIDEO_ACTIVE : out std_logic;   -- PIN 22
        H_TC           : out std_logic    -- PIN 23
    );

    -- Pin number attributes for the fitter
    attribute pin_numbers : string;
    attribute pin_numbers of hcount_pld : entity is
        "CLK:1 RESET:2 H0:3 H1:4 H2:5 " &
        "H3:14 H4:15 H5:16 H6:17 H7:18 H8:19 H9:20 " &
        "HSYNC:21 H_VIDEO_ACTIVE:22 H_TC:23";
end entity hcount_pld;


architecture rtl of hcount_pld is

    -- Internal copies of the output pins (outputs are also used as feedback).
    -- The ATF22V10C powers up with all registers at 0, so the registers are
    -- initialized to '0' to match the device in simulation.
    signal H3_Q             : std_logic := '0';
    signal H4_Q             : std_logic := '0';
    signal H5_Q             : std_logic := '0';
    signal H6_Q             : std_logic := '0';
    signal H7_Q             : std_logic := '0';
    signal H8_Q             : std_logic := '0';
    signal H9_Q             : std_logic := '0';
    signal HSYNC_Q          : std_logic := '0';
    signal H_VIDEO_ACTIVE_Q : std_logic := '0';

    -- Intermediate (node) equations
    signal H_ENABLE         : std_logic;
    signal H_TC_I           : std_logic;
    signal HSYNC_START      : std_logic;
    signal HSYNC_STOP       : std_logic;
    signal VIDEO_OFF        : std_logic;
    signal VIDEO_ON         : std_logic;

    -- Next-state (D input) equations
    signal H3_D             : std_logic;
    signal H4_D             : std_logic;
    signal H5_D             : std_logic;
    signal H6_D             : std_logic;
    signal H7_D             : std_logic;
    signal H8_D             : std_logic;
    signal H9_D             : std_logic;
    signal HSYNC_D          : std_logic;
    signal H_VIDEO_ACTIVE_D : std_logic;

begin

    -- -------------------------------------------------
    -- H3:H9 = 7-bit horizontal group counter
    --
    -- H2:H0 come from the Sync PLD and count
    -- the individual pixels within each 8-pixel group.
    --
    -- Revision 07: H2:H0 is the colour decoder's pixel
    -- select, so it runs two clocks behind the group:
    -- it is 110 on the first clock of a group, 111 on
    -- the second (the video read), 000 on the third
    -- (the first pixel of the byte read in the second)
    -- and 101 on the last.  This replaces the two-stage
    -- pixel select and video enable delay register
    -- (F574) that used to sit between the Sync PLD and
    -- the colour decoder (see docs/VIDEO_TIMING.md).
    --
    -- H3:H9 advance whenever H2:H0 = 101, the last
    -- clock of the group (H2:H0 = 111 before revision 07).
    -- At all other times they HOLD their value.
    --
    -- Counter sequence:
    --     28 -> 29 -> ... -> 127 -> 28
    --
    -- 100 groups x 8 pixels = 800 clocks per line.
    -- -------------------------------------------------

    H_ENABLE <= H2 and (not H1) and H0;


    -- Terminal count: H9:H3 = 1111111 and H2:H0 = 101
    -- i.e. the last clock of the line.  One clock wide.
    -- Used to reload the counter and as the line-end
    -- pulse for the external vertical counter.

    H_TC_I <= H_ENABLE and H9_Q and H8_Q and H7_Q and H6_Q and H5_Q and H4_Q and H3_Q;


    -- -------------------------------------------------
    -- Counter next-state equations
    --
    -- Each bit toggles when H_ENABLE is high and all
    -- lower bits are 1, otherwise it holds.
    --
    -- At terminal count every bit toggles to 0
    -- (127 + 1 = 0).  The reload value is 28 = 0011100,
    -- so H5, H6 and H7 are forced to 1 by H_TC.
    -- H3, H4, H8 and H9 need no extra term because
    -- they are already 0 after the toggle.
    -- -------------------------------------------------

    -- H3 = bit 0
    H3_D <= H3_Q xor H_ENABLE;


    -- H4 = bit 1
    H4_D <= H4_Q xor (H_ENABLE and H3_Q);


    -- H5 = bit 2
    H5_D <= (H5_Q xor (H_ENABLE and H4_Q and H3_Q))
            or H_TC_I;


    -- H6 = bit 3
    H6_D <= (H6_Q xor (H_ENABLE and H5_Q and H4_Q and H3_Q))
            or H_TC_I;


    -- H7 = bit 4
    H7_D <= (H7_Q xor (H_ENABLE and H6_Q and H5_Q and H4_Q and H3_Q))
            or H_TC_I;


    -- H8 = bit 5
    H8_D <= H8_Q xor (H_ENABLE and H7_Q and H6_Q and H5_Q and H4_Q and H3_Q);


    -- H9 = bit 6
    H9_D <= H9_Q xor (H_ENABLE and H8_Q and H7_Q and H6_Q and H5_Q and H4_Q and H3_Q);


    -- -------------------------------------------------
    -- Horizontal timing (per line, in groups of 8 clocks)
    --
    --     28 - 29    front porch    (2 groups =  16 clocks)
    --     30 - 41    HSYNC          (12 groups = 96 clocks)
    --     42 - 47    back porch     (6 groups =  48 clocks)
    --     48 - 127   active video   (80 groups = 640 clocks)
    --
    -- HSYNC and H_VIDEO_ACTIVE are registered, so each
    -- change is decoded on the LAST clock of the previous
    -- group (H_ENABLE = 1).  The register then changes on
    -- the same clock edge as the group counter, and the
    -- new state is in place for the first clock (H2:H0 = 110)
    -- of the new group.
    -- -------------------------------------------------


    -- -------------------------------------------------
    -- Horizontal sync state
    -- -------------------------------------------------

    -- HSYNC starts at H=30: 0011110
    -- decode H=29:  H9..H3 = 0011101, last clock of the group
    HSYNC_START <= H_ENABLE and (not H9_Q) and (not H8_Q) and H7_Q and H6_Q and H5_Q
                   and (not H4_Q) and H3_Q;


    -- HSYNC stops at H=42: 0101010
    -- decode H=41:  H9..H3 = 0101001, last clock of the group
    HSYNC_STOP <= H_ENABLE and (not H9_Q) and H8_Q and (not H7_Q) and H6_Q and (not H5_Q)
                  and (not H4_Q) and H3_Q;


    -- Registered HSYNC state.
    -- HSYNC_Q is logically true during sync; the HSYNC pin is the
    -- inverse (active low), so it is low during groups 30-41.
    -- The register powers up to 0, which is the inactive (high) pin level.
    HSYNC_D <= HSYNC_START
               or (HSYNC_Q and (not HSYNC_STOP));


    -- -------------------------------------------------
    -- Horizontal active-video state
    -- -------------------------------------------------

    -- Video turns off at H=28: 0011100 (start of the next line).
    -- decode H=127, last clock of the line: this is H_TC.
    VIDEO_OFF <= H_TC_I;


    -- Video turns on at H=48: 0110000
    -- decode H=47:  H9..H3 = 0101111, last clock of the group
    VIDEO_ON <= H_ENABLE and (not H9_Q) and H8_Q and (not H7_Q) and H6_Q and H5_Q
                and H4_Q and H3_Q;


    -- Registered horizontal active-video state
    H_VIDEO_ACTIVE_D <= VIDEO_ON
                        or (H_VIDEO_ACTIVE_Q and (not VIDEO_OFF));


    -- -------------------------------------------------
    -- Registers (rising-edge D flip-flops, ATF22V10C
    -- output macrocells in registered mode)
    -- -------------------------------------------------

    process (CLK)
    begin
        if rising_edge(CLK) then
            H3_Q             <= H3_D;
            H4_Q             <= H4_D;
            H5_Q             <= H5_D;
            H6_Q             <= H6_D;
            H7_Q             <= H7_D;
            H8_Q             <= H8_D;
            H9_Q             <= H9_D;
            HSYNC_Q          <= HSYNC_D;
            H_VIDEO_ACTIVE_Q <= H_VIDEO_ACTIVE_D;
        end if;
    end process;


    -- -------------------------------------------------
    -- Output pin connections
    -- -------------------------------------------------

    H3             <= H3_Q;
    H4             <= H4_Q;
    H5             <= H5_Q;
    H6             <= H6_Q;
    H7             <= H7_Q;
    H8             <= H8_Q;
    H9             <= H9_Q;
    HSYNC          <= not HSYNC_Q;   -- active-low pin
    H_VIDEO_ACTIVE <= H_VIDEO_ACTIVE_Q;
    H_TC           <= H_TC_I;       -- combinatorial output, pin 23

end architecture rtl;
