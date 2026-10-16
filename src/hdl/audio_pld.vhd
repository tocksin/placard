--------------------------------------------------------------------------------
-- Name     AUDIO_SLOT
-- PartNo   00
-- Date     2026-10-16
-- Revision 02
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_AUDIO.pld (Revision 02)
--
-- Picks the 8-clock groups on each scan line where the video circuit reads
-- a byte in horizontal blanking:
--   - the audio sample: group 38 on lines 499-511 (V9 = 0) and group 39 on
--     lines 512-1023 (V9 = 1).  That puts V9 on A9 (H3), so one frame reads
--     4DF3h-4FFFh in order, one byte per line.  See SOUND.md.
--   - the mode byte (revision 02): group 37 on every line, so row r's mode
--     byte is at 4A20h + r.  /MODE_LD is the line code register's /E for
--     the whole group.  See VIDEO.md.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 2  = H9
--   PIN 3  = H8
--   PIN 4  = H7
--   PIN 5  = H6
--   PIN 6  = H5
--   PIN 7  = H4
--   PIN 8  = H3
--   PIN 9  = V9
--   PIN 22 = MODE_LD           (combinatorial output, ACTIVE LOW, to line
--                               code register /E)
--   PIN 23 = BLANK_RD          (combinatorial output, to Sync PLD pin 13)
--   Unused: pins 1, 10, 11, 13, 14-21
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity audio_pld is
    port (
        H9       : in  std_logic;   -- PIN 2, H counter PLD pin 20
        H8       : in  std_logic;   -- PIN 3, H counter PLD pin 19
        H7       : in  std_logic;   -- PIN 4, H counter PLD pin 18
        H6       : in  std_logic;   -- PIN 5, H counter PLD pin 17
        H5       : in  std_logic;   -- PIN 6, H counter PLD pin 16
        H4       : in  std_logic;   -- PIN 7, H counter PLD pin 15
        H3       : in  std_logic;   -- PIN 8, H counter PLD pin 14
        V9       : in  std_logic;   -- PIN 9, V counter PLD pin 19 (Q9)

        MODE_LD  : out std_logic;   -- PIN 22 (active low), to line code register /E
        BLANK_RD : out std_logic    -- PIN 23, to Sync PLD pin 13
    );

    -- Pin number attributes for the fitter
    attribute pin_numbers : string;
    attribute pin_numbers of audio_pld : entity is
        "H9:2 H8:3 H7:4 H6:5 H5:6 H4:7 H3:8 V9:9 MODE_LD:22 BLANK_RD:23";
end entity audio_pld;


architecture rtl of audio_pld is

    -- Logical (active-high) value of the active-low MODE_LD pin
    signal MODE_LD_Q : std_logic;

begin

    -- ============================================================
    -- BLANKING READ SLOTS
    -- ============================================================

    --
    -- !H9 & H8 & !H7 & !H6 & H5 & H4 is groups 38 and 39 only.
    -- H3 = V9 picks group 39 on lines 512-1023 and group 38 on
    -- lines 499-511.  !H9 & H8 & !H7 & !H6 & H5 & !H4 & H3 is
    -- group 37 (the mode byte).
    --

    BLANK_RD <=
          ((not H9) and H8 and (not H7) and (not H6) and H5 and H4 and H3 and V9)              -- group 39, lines 512-1023
       or ((not H9) and H8 and (not H7) and (not H6) and H5 and H4 and (not H3) and (not V9))  -- group 38, lines 499-511
       or ((not H9) and H8 and (not H7) and (not H6) and H5 and (not H4) and H3);              -- group 37, every line

    -- ============================================================
    -- MODE BYTE LOAD (active-low pin)
    -- ============================================================

    MODE_LD_Q <= (not H9) and H8 and (not H7) and (not H6) and H5 and (not H4) and H3;  -- group 37, every line

    MODE_LD <= not MODE_LD_Q;

end architecture rtl;
