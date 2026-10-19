--------------------------------------------------------------------------------
-- Name     VGA_SYNC
-- PartNo   01
-- Date     2026-10-19
-- Revision 08
-- Designer Justin
-- Company
-- Assembly
-- Location
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_SYNC.pld (Revision 08)
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
--   PIN 17 = VIDEN             (registered output; VIDEO_ACTIVE before revision 08)
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

        VIDEN            : out std_logic;   -- PIN 17
        VSYNC            : out std_logic;   -- PIN 18

        PIXEL_ENABLE     : out std_logic;   -- PIN 19

        ADDR_SEL         : out std_logic;   -- PIN 20
        ADDR_SEL_HI      : out std_logic;   -- PIN 21
        ADDR_SEL_LO      : out std_logic;   -- PIN 22

        -- Vertical active-region state (registered).
        -- Needed internally by VIDEN, PIXEL_ENABLE and VSYNC.
        -- Brought out on pin 23 because the 22V10 has no buried registers.
        V_VIDEO_ACTIVE   : out std_logic    -- PIN 23
    );

    -- Pin number attributes for the fitter
    attribute pin_numbers : string;
    attribute pin_numbers of sync_pld : entity is
        "CLK:1 V9:2 V5:3 V4:4 V3:5 V2:6 V1:7 H_VIDEO_ACTIVE:8 " &
        "PC_ENABLE:9 Y_ENABLE:10 X_ENABLE:11 BLANK_RD:13 " &
        "H0:14 H1:15 H2:16 VIDEN:17 VSYNC:18 PIXEL_ENABLE:19 " &
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
    signal VIDEN_Q           : std_logic := '0';
    signal PIXEL_ENABLE_Q    : std_logic := '0';

    -- Next-state (D input) equations
    signal H0_D              : std_logic;
    signal H1_D              : std_logic;
    signal H2_D              : std_logic;
    signal V_VIDEO_ACTIVE_D  : std_logic;
    signal VIDEN_D           : std_logic;
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
    -- Revision 08: H2:H0 goes straight to the colour decoder as its
    -- pixel select, so the count runs two clocks behind the 8-clock
    -- group of the H counter PLD (revision 07):
    --
    --     clock of the group   0    1    2    3    4    5    6    7
    --     H2:H0               110  111  000  001  010  011  100  101
    --
    -- The byte is read in clock 1 (H2:H0 = 111), the pixel buffer
    -- loads at the end of it, and its first pixel is shown in clock 2
    -- (H2:H0 = 000).  The H counter PLD advances the group on 101.
    -- The counter equations do not change; only the decodes that use
    -- H2:H0 do.  Before revision 08, H2:H0 was 000 in clock 0 and a
    -- two-stage delay register (F574) between this PLD and the colour
    -- decoder delayed H2:H0 and VIDEO_ACTIVE by two clocks.
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
    -- VIDEO ENABLE (colour decoder VIDEN)
    -- ============================================================

    --
    -- VIDEN blanks the colour decoder.  It is high for the 640 clocks
    -- in which pixels are shown: from clock 2 of group 48 (the first
    -- pixel of the first byte) to clock 1 of group 28 of the next line
    -- (the last pixel of the last byte), on lines where V_VIDEO_ACTIVE
    -- is high (counts 544-1023).
    --
    -- Revision 08: registered, and loaded only in clock 1 of each group
    -- (H2:H0 = 111, the video read clock).  It holds on the other seven
    -- clocks.  In clock 1 of group 48 H_VIDEO_ACTIVE has just gone high,
    -- so VIDEN goes high at the end of it; in clock 1 of group 28 it has
    -- just gone low, so VIDEN goes low at the end of it.  That is
    -- exactly the old VIDEO_ACTIVE (V_VIDEO_ACTIVE & H_VIDEO_ACTIVE,
    -- combinational) delayed by two clocks in the delay register, which
    -- is no longer needed.  Nothing else used VIDEO_ACTIVE.
    --

    VIDEN_D <=
          (V_VIDEO_ACTIVE_Q
      and H_VIDEO_ACTIVE
      and H2_Q
      and H1_Q
      and H0_Q)
       or (VIDEN_Q
      and (not H2_Q))
       or (VIDEN_Q
      and (not H1_Q))
       or (VIDEN_Q
      and (not H0_Q));


    -- ============================================================
    -- PIXEL ENABLE
    -- ============================================================

    --
    -- One byte is read every eight clocks during active video.
    --
    -- PIXEL_ENABLE is registered, so it is decoded in the first clock
    -- of the group and is high in the second one, where the byte is
    -- read.  Since revision 08 those are H2:H0 = 110 and 111 (000 and
    -- 001 before).  Being registered,
    -- it reaches ADDR_SEL through the register feedback (tCF) and the
    -- State, PC and Branch PLDs at tCO, instead of three array passes
    -- after the clock (see docs/VIDEO_TIMING.md).
    --
    -- It is decoded from the V_VIDEO_ACTIVE register and the
    -- H_VIDEO_ACTIVE input, so it is one array pass.
    --
    -- The pixel buffer loads at the end of the second clock, so its
    -- first pixel is shown in the third (H2:H0 = 000), and the colour
    -- decoder takes H2:H0 and VIDEN from this PLD directly.
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
      and H2_Q
      and H1_Q
      and (not H0_Q))
       or (BLANK_RD
      and H2_Q
      and H1_Q
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
            VIDEN_Q          <= VIDEN_D;
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
    VIDEN          <= VIDEN_Q;
    PIXEL_ENABLE    <= PIXEL_ENABLE_Q;

end architecture rtl;
