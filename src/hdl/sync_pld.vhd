--------------------------------------------------------------------------------
-- Name     VGA_SYNC
-- PartNo   01
-- Date     2026-10-18
-- Revision 07
-- Designer Justin
-- Company
-- Assembly
-- Location
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_SYNC.pld (Revision 07)
--
-- Pin assignments (ATF22V10C, 24-pin DIP/SOIC; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = CLK
--   PIN 2  = V9
--   PIN 3  = V5
--   PIN 4  = V4
--   PIN 5  = V3
--   PIN 6  = V2
--   PIN 7  = V1
--   PIN 8  = H_VIDEO_ACTIVE
--   PIN 9  = PC_ENABLE
--   PIN 10 = Y_ENABLE
--   PIN 11 = X_ENABLE
--   PIN 13 = BLANK_RD
--
--   PIN 14 = H0                (registered output)
--   PIN 15 = H1                (registered output)
--   PIN 16 = H2                (registered output)
--   PIN 17 = VIDEO_ACTIVE      (combinatorial output)
--   PIN 18 = VSYNC             (combinatorial output)
--   PIN 19 = PIXEL_ENABLE      (registered output)
--   PIN 20 = ADDR_SEL          (combinatorial output)
--   PIN 21 = ADDR_SEL_HI       (combinatorial output)
--   PIN 22 = ADDR_SEL_LO       (combinatorial output)
--   PIN 23 = V_VIDEO_ACTIVE    (registered output)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity sync_pld is
    port (
        -- ============================================================
        -- INPUTS
        -- ============================================================

        CLK              : in  std_logic;   -- PIN 1

        -- Vertical counter inputs
        -- V9:V1 are bits 9..1 of the external 10-bit vertical counter.
        -- V0 is not connected, so each decode below sees two counts at
        -- once (e.g. 532 and 533 look identical to this PLD).
        -- V8, V7 and V6 are not connected and are not needed.
        V9               : in  std_logic;   -- PIN 2
        V5               : in  std_logic;   -- PIN 3
        V4               : in  std_logic;   -- PIN 4
        V3               : in  std_logic;   -- PIN 5
        V2               : in  std_logic;   -- PIN 6
        V1               : in  std_logic;   -- PIN 7

        -- Horizontal active-video indication
        H_VIDEO_ACTIVE   : in  std_logic;   -- PIN 8

        -- Address-source enables
        PC_ENABLE        : in  std_logic;   -- PIN 9
        Y_ENABLE         : in  std_logic;   -- PIN 10
        X_ENABLE         : in  std_logic;   -- PIN 11

        -- Blanking read slot, from the audio slot PLD (revision 06; named
        -- AUD_SLOT before revision 07).  High for the whole 8-clock group
        -- of each line where the mode byte (group 45, see docs/VIDEO.md) or the
        -- audio sample (group 46 or 47, see docs/SOUND.md) is read (groups
        -- 37-39 before audio slot PLD revision 03).
        BLANK_RD         : in  std_logic;   -- PIN 13

        -- ============================================================
        -- OUTPUTS
        -- ============================================================

        H0               : out std_logic;   -- PIN 14
        H1               : out std_logic;   -- PIN 15
        H2               : out std_logic;   -- PIN 16

        VIDEO_ACTIVE     : out std_logic;   -- PIN 17
        VSYNC            : out std_logic;   -- PIN 18

        PIXEL_ENABLE     : out std_logic;   -- PIN 19

        ADDR_SEL         : out std_logic;   -- PIN 20
        ADDR_SEL_HI      : out std_logic;   -- PIN 21
        ADDR_SEL_LO      : out std_logic;   -- PIN 22

        -- Vertical active-region state (registered).
        -- Needed internally by VIDEO_ACTIVE and VSYNC.
        -- Brought out on pin 23 because the 22V10 has no buried registers.
        V_VIDEO_ACTIVE   : out std_logic    -- PIN 23
    );

    -- Pin number attributes for the fitter
    attribute pin_numbers : string;
    attribute pin_numbers of sync_pld : entity is
        "CLK:1 V9:2 V5:3 V4:4 V3:5 V2:6 V1:7 H_VIDEO_ACTIVE:8 " &
        "PC_ENABLE:9 Y_ENABLE:10 X_ENABLE:11 BLANK_RD:13 " &
        "H0:14 H1:15 H2:16 VIDEO_ACTIVE:17 VSYNC:18 PIXEL_ENABLE:19 " &
        "ADDR_SEL:20 ADDR_SEL_HI:21 ADDR_SEL_LO:22 V_VIDEO_ACTIVE:23";
end entity sync_pld;


architecture rtl of sync_pld is

    -- Internal copies of the output pins (outputs are also used as feedback).
    -- The ATF22V10C powers up with all registers at 0, so the registers are
    -- initialized to '0' to match the device in simulation.
    signal H0_Q              : std_logic := '0';
    signal H1_Q              : std_logic := '0';
    signal H2_Q              : std_logic := '0';
    signal V_VIDEO_ACTIVE_Q  : std_logic := '0';
    signal VIDEO_ACTIVE_I    : std_logic;
    signal PIXEL_ENABLE_Q    : std_logic := '0';

    -- Next-state (D input) equations
    signal H0_D              : std_logic;
    signal H1_D              : std_logic;
    signal H2_D              : std_logic;
    signal V_VIDEO_ACTIVE_D  : std_logic;
    signal PIXEL_ENABLE_D    : std_logic;

begin

    -- ============================================================
    -- HORIZONTAL LOW-BIT COUNTER
    -- ============================================================

    --
    -- H0 toggles every clock.
    --
    -- H1 toggles whenever H0 is high.
    --
    -- H2 toggles whenever H1 and H0 are both high.
    --

    H0_D <= not H0_Q;

    H1_D <= H1_Q xor H0_Q;

    H2_D <= H2_Q xor (H1_Q and H0_Q);


    -- ============================================================
    -- VERTICAL ACTIVE-REGION STATE
    -- ============================================================

    --
    -- V_VIDEO_ACTIVE is high for vertical counts 544-1023.
    --
    -- Counts 512-543 have V9 = 1 and V5 = 0.
    -- Count 544 is the first count with V9 = 1 and V5 = 1.
    -- Only V9 and V5 are needed to detect it.
    --
    -- Set:
    --     V9 = 1
    --     V5 = 1
    --
    -- Once set, it holds while V9 is high.  V5 returns low at
    -- count 576, but the held state keeps the region active.
    --
    -- V9 going low (counter wraps from 1023) clears it.
    --

    V_VIDEO_ACTIVE_D <= V9 and (V5 or V_VIDEO_ACTIVE_Q);


    -- ============================================================
    -- VIDEO ACTIVE
    -- ============================================================

    --
    -- VIDEO_ACTIVE is high when both the vertical active region
    -- (counts 544-1023) and the horizontal active region are active.
    --

    VIDEO_ACTIVE_I <=
          V_VIDEO_ACTIVE_Q
      and H_VIDEO_ACTIVE;


    -- ============================================================
    -- PIXEL ENABLE
    -- ============================================================

    --
    -- One byte is read every eight clocks during active video.
    --
    -- PIXEL_ENABLE is registered, so it is decoded on the clock where
    -- H2:H0 = 000 and is high on the next one, H2:H0 = 001.  The byte is
    -- read in the second clock of each 8-clock group.  Being registered,
    -- it reaches ADDR_SEL through the register feedback (tCF) and the
    -- State, PC and Branch PLDs at tCO, instead of three array passes
    -- after the clock (see docs/VIDEO_TIMING.md).
    --
    -- It is decoded from the V_VIDEO_ACTIVE register and the
    -- H_VIDEO_ACTIVE input, not from the VIDEO_ACTIVE pin, so it is one
    -- array pass.
    --
    -- The pixel buffer loads one clock later than a clock-0 read, so the
    -- pixel select (H2:H0) and video-enable delay register on the board
    -- has two stages.
    --
    -- Audio (revision 06): one more read per line, on every line
    -- including vertical blanking, in clock 1 of the group that
    -- BLANK_RD marks (group 38 or 39, in horizontal blanking).  It is
    -- a video read in every way: the address mux takes the video
    -- address, the CPU stalls, MEM_CTRL enables the RAM or ROM by the
    -- map, and the pixel buffer loads the byte.  The pixel buffer
    -- holds it until the first pixel read of the line (group 48), and
    -- the DAC register copies it at the end of HSYNC (group 42).
    --
    -- Mode byte (revision 07): the audio slot PLD (revision 02) also
    -- marks group 37 on every line, so the same term reads the line's
    -- mode byte there, and the line code register copies it from the
    -- pixel buffer.  The input is renamed BLANK_RD; the equations do
    -- not change.
    --

    PIXEL_ENABLE_D <=
          (V_VIDEO_ACTIVE_Q
      and H_VIDEO_ACTIVE
      and (not H2_Q)
      and (not H1_Q)
      and (not H0_Q))
       or (BLANK_RD
      and (not H2_Q)
      and (not H1_Q)
      and (not H0_Q));


    -- ============================================================
    -- VERTICAL SYNC
    -- ============================================================

    --
    -- VSYNC is active low during counts 532-533.
    --
    -- V0 is not available, so counts 532 and 533 are decoded together:
    --
    --     532 = 10 0001 0100
    --     533 = 10 0001 0101
    --
    -- V4:V1 = 1010 selects 532-533 within any 32-count window.
    -- V9 = 1 restricts the match to counts 512-1023, and
    -- !V_VIDEO_ACTIVE restricts it to counts 512-543 (before the
    -- active region begins at 544).  The only count in 512-543 with
    -- V4:V1 = 1010 is 532-533, so V8, V7, V6 and V5 are not needed.
    --

    VSYNC <= not (V9 and (not V_VIDEO_ACTIVE_Q) and V4 and (not V3) and V2 and (not V1));


    -- ============================================================
    -- ADDRESS MUX CONTROL
    -- ============================================================

    --
    -- Four-way address selection:
    --
    --     S1 S0
    --     -----
    --      00   Default
    --      01   X/Y register
    --      10   Video address
    --      11   Program counter
    --
    -- Priority (highest first):
    --
    --     1. Video address    PIXEL_ENABLE            -> 10
    --     2. Program counter  PC_ENABLE              -> 11
    --     3. X / Y registers  X_ENABLE, Y_ENABLE     -> 01
    --     4. Default                                 -> 00
    --
    -- PIXEL_ENABLE overrides PC_ENABLE, X_ENABLE and Y_ENABLE.
    -- PC_ENABLE overrides X_ENABLE and Y_ENABLE.
    --


    --
    -- Shared S1 input to ALL FOUR 4:1 muxes.
    --
    -- Video is selected only during PIXEL_ENABLE.
    -- PC is selected whenever PC_ENABLE is active.
    --

    ADDR_SEL <=
          PIXEL_ENABLE_Q
       or PC_ENABLE;


    --
    -- Upper-byte S0.
    --
    --     S1 S0
    --     00 = 00h
    --     01 = Y register
    --     10 = Video address
    --     11 = PC
    --
    -- S0 is forced low during PIXEL_ENABLE so that S1 S0 = 10
    -- (video) regardless of PC_ENABLE and Y_ENABLE.
    --

    ADDR_SEL_HI <=
          (not PIXEL_ENABLE_Q)
      and (PC_ENABLE or Y_ENABLE);


    --
    -- Lower-byte S0.
    --
    --     S1 S0
    --     00 = D register
    --     01 = X register
    --     10 = Video address
    --     11 = PC
    --
    -- S0 is forced low during PIXEL_ENABLE so that S1 S0 = 10
    -- (video) regardless of PC_ENABLE and X_ENABLE.
    --

    ADDR_SEL_LO <=
          (not PIXEL_ENABLE_Q)
      and (PC_ENABLE or X_ENABLE);


    -- ============================================================
    -- Registers (rising-edge D flip-flops, ATF22V10C
    -- output macrocells in registered mode)
    -- ============================================================

    process (CLK)
    begin
        if rising_edge(CLK) then
            H0_Q             <= H0_D;
            H1_Q             <= H1_D;
            H2_Q             <= H2_D;
            V_VIDEO_ACTIVE_Q <= V_VIDEO_ACTIVE_D;
            PIXEL_ENABLE_Q   <= PIXEL_ENABLE_D;
        end if;
    end process;


    -- ============================================================
    -- Output pin connections
    -- ============================================================

    H0             <= H0_Q;
    H1             <= H1_Q;
    H2             <= H2_Q;
    V_VIDEO_ACTIVE <= V_VIDEO_ACTIVE_Q;
    VIDEO_ACTIVE   <= VIDEO_ACTIVE_I;
    PIXEL_ENABLE    <= PIXEL_ENABLE_Q;

end architecture rtl;
