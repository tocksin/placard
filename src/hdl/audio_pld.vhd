--------------------------------------------------------------------------------
-- Name     AUDIO_SLOT
-- PartNo   00
-- Date     2026-10-18
-- Revision 03
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_AUDIO.pld (Revision 03)
--
-- Picks the 8-clock groups on each scan line where the video circuit reads
-- a byte in horizontal blanking, and remaps four row address bits for the
-- line repeat modes:
--   - the mode byte: group 45 on every line, so row r's mode byte is at
--     5A20h + r.  /MODE_LD is the line code register's /E for the whole
--     group.  See docs/VIDEO.md.
--   - the audio sample: group 46 on lines 499-511 (V9 = 0) and group 47 on
--     lines 512-1023 (V9 = 1).  That puts V9 on A9 (H3), so one frame reads
--     5DF3h-5FFFh in order, one byte per line.  See docs/SOUND.md.
--   - R0, R1, R7, R8: the video address bits A0, A1, A7, A8.  Outside
--     groups 32-47 (RAW) they follow line code bits 3:2:
--         1x (00): V0, V1, V7, V8   2x (01): V8, V1, V7, 1
--         4x (1x): V7, V8, 1, 1
--
-- Revision 03 moved the blanking reads up from groups 37-39 (4A20h,
-- 4DF3h) when the I/O window shrank to 5000h-53FFh, and added the row
-- address outputs.  The audio DAC register is now clocked by
-- H_VIDEO_ACTIVE (start of group 48) instead of HSYNC.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = V0
--   PIN 2  = H9
--   PIN 3  = H8
--   PIN 4  = H7
--   PIN 5  = H6
--   PIN 6  = H5
--   PIN 7  = H4
--   PIN 8  = H3
--   PIN 9  = V9
--   PIN 10 = V1
--   PIN 11 = V7
--   PIN 13 = V8
--   PIN 14 = LC2               (line code register Q2)
--   PIN 15 = LC3               (line code register Q3)
--   PIN 17 = R0                (combinatorial output, video A0)
--   PIN 18 = R1                (combinatorial output, video A1)
--   PIN 19 = R7                (combinatorial output, video A7)
--   PIN 20 = R8                (combinatorial output, video A8)
--   PIN 22 = MODE_LD           (combinatorial output, ACTIVE LOW, to line
--                               code register /E)
--   PIN 23 = BLANK_RD          (combinatorial output, to Sync PLD pin 13)
--   Unused: pins 16, 21
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity audio_pld is
    port (
        V0       : in  std_logic;   -- PIN 1, V counter PLD Q0
        H9       : in  std_logic;   -- PIN 2, H counter PLD pin 20
        H8       : in  std_logic;   -- PIN 3, H counter PLD pin 19
        H7       : in  std_logic;   -- PIN 4, H counter PLD pin 18
        H6       : in  std_logic;   -- PIN 5, H counter PLD pin 17
        H5       : in  std_logic;   -- PIN 6, H counter PLD pin 16
        H4       : in  std_logic;   -- PIN 7, H counter PLD pin 15
        H3       : in  std_logic;   -- PIN 8, H counter PLD pin 14
        V9       : in  std_logic;   -- PIN 9, V counter PLD Q9
        V1       : in  std_logic;   -- PIN 10, V counter PLD Q1
        V7       : in  std_logic;   -- PIN 11, V counter PLD Q7
        V8       : in  std_logic;   -- PIN 13, V counter PLD Q8
        LC2      : in  std_logic;   -- PIN 14, line code register Q2
        LC3      : in  std_logic;   -- PIN 15, line code register Q3

        R0       : out std_logic;   -- PIN 17, video address A0
        R1       : out std_logic;   -- PIN 18, video address A1
        R7       : out std_logic;   -- PIN 19, video address A7
        R8       : out std_logic;   -- PIN 20, video address A8
        MODE_LD  : out std_logic;   -- PIN 22 (active low), to line code register /E
        BLANK_RD : out std_logic    -- PIN 23, to Sync PLD pin 13
    );

    -- Pin number attributes for the fitter
    attribute pin_numbers : string;
    attribute pin_numbers of audio_pld : entity is
        "V0:1 H9:2 H8:3 H7:4 H6:5 H5:6 H4:7 H3:8 V9:9 V1:10 V7:11 V8:13 " &
        "LC2:14 LC3:15 R0:17 R1:18 R7:19 R8:20 MODE_LD:22 BLANK_RD:23";
end entity audio_pld;


architecture rtl of audio_pld is

    -- Logical (active-high) value of the active-low MODE_LD pin
    signal MODE_LD_Q : std_logic;

    -- Groups 32-47: the blanking reads use the plain V8:V0
    signal RAW : std_logic;

begin

    -- ============================================================
    -- BLANKING READ SLOTS
    -- ============================================================

    --
    -- !H9 & H8 & !H7 & H6 & H5 & H4 is groups 46 and 47 only.
    -- H3 = V9 picks group 47 on lines 512-1023 and group 46 on
    -- lines 499-511.  !H9 & H8 & !H7 & H6 & H5 & !H4 & H3 is
    -- group 45 (the mode byte).
    --

    BLANK_RD <=
          ((not H9) and H8 and (not H7) and H6 and H5 and H4 and H3 and V9)              -- group 47, lines 512-1023
       or ((not H9) and H8 and (not H7) and H6 and H5 and H4 and (not H3) and (not V9))  -- group 46, lines 499-511
       or ((not H9) and H8 and (not H7) and H6 and H5 and (not H4) and H3);              -- group 45, every line

    -- ============================================================
    -- MODE BYTE LOAD (active-low pin)
    -- ============================================================

    MODE_LD_Q <= (not H9) and H8 and (not H7) and H6 and H5 and (not H4) and H3;  -- group 45, every line

    MODE_LD <= not MODE_LD_Q;

    -- ============================================================
    -- ROW ADDRESS (line repeat)
    -- ============================================================

    RAW <= (not H9) and (not H7);   -- groups 32-47

    R0 <= (V0 and RAW)
       or (V0 and (not LC3) and (not LC2))
       or (V8 and (not RAW) and (not LC3) and LC2)   -- 2x
       or (V7 and (not RAW) and LC3);                -- 4x

    R1 <= (V1 and RAW)
       or (V1 and (not LC3))
       or (V8 and (not RAW) and LC3);                -- 4x

    R7 <= (V7 and RAW)
       or (V7 and (not LC3))
       or ((not RAW) and LC3);                       -- 4x: 1

    R8 <= (V8 and RAW)
       or (V8 and (not LC3) and (not LC2))
       or ((not RAW) and LC3)                        -- 4x: 1
       or ((not RAW) and LC2);                       -- 2x: 1

end architecture rtl;
