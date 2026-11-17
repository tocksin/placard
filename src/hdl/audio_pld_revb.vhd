--------------------------------------------------------------------------------
-- Name     AUDIO_SLOT
-- Date     2026-11-17
-- Revision 06 (rev B board only; the rev A board is audio_pld.vhd, revision 04)
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source src/pld/rev_b/ATF22V10_AUDIO.pld (Revision 06).
-- The equations are translated as written, one signal per pin.
--
-- Revision 05: 160-read lines.  /AC_SEL has moved to the IR PLD; pin 16 is
-- T2 (true H2) and pin 21 is LC7.  On a 160-read line A8 = !T2 (the half
-- column) and BLANK_RD is also the line marker for the Sync PLD (active
-- groups and group 28).
--
-- Revision 06: repeat code 00 on a 160-read line is the fold: the row is
-- V7:V0, one row per line, and the memory wraps every 256 lines.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity audio_pld_revb is
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
        T2       : in  std_logic;   -- PIN 16, Sync PLD pin 21: true H2 (revision 05)

        R0       : out std_logic;   -- PIN 17, video address A0
        R1       : out std_logic;   -- PIN 18, video address A1
        R7       : out std_logic;   -- PIN 19, video address A7
        R8       : out std_logic;   -- PIN 20, video address A8
        LC7      : in  std_logic;   -- PIN 21, line code register Q7: 1 = 160-read line (revision 05)
        MODE_LD  : out std_logic;   -- PIN 22 (active low), to line code register /E
        BLANK_RD : out std_logic    -- PIN 23, to Sync PLD pin 13
    );

    -- Pin number attributes for the fitter
    attribute pin_numbers : string;
    attribute pin_numbers of audio_pld_revb : entity is
        "V0:1 H9:2 H8:3 H7:4 H6:5 H5:6 H4:7 H3:8 V9:9 V1:10 V7:11 V8:13 " &
        "LC2:14 LC3:15 T2:16 R0:17 R1:18 R7:19 R8:20 LC7:21 MODE_LD:22 BLANK_RD:23";
end entity audio_pld_revb;


architecture rtl of audio_pld_revb is

    -- Logical (active-high) value of the active-low MODE_LD pin
    signal MODE_LD_Q : std_logic;

    -- Groups 32-47: the blanking reads use the plain V8:V0
    signal RAW : std_logic;

begin

    BLANK_RD <=
          ((not H9) and H8 and (not H7) and H6 and H5 and H4 and H3 and V9)              -- group 47, lines 512-1023
       or ((not H9) and H8 and (not H7) and H6 and H5 and H4 and (not H3) and (not V9))  -- group 46, lines 499-511
       or ((not H9) and H8 and (not H7) and H6 and H5 and (not H4) and H3)               -- group 45, every line
       or (LC7 and V9 and H9)                                                            -- marker: groups 64-127
       or (LC7 and V9 and H8 and H7)                                                     -- marker: groups 48-63
       or (LC7 and (not H9) and (not H8) and H7 and H6 and H5 and (not H4) and (not H3)); -- marker: group 28

    MODE_LD_Q <= (not H9) and H8 and (not H7) and H6 and H5 and (not H4) and H3;  -- group 45, every line
    MODE_LD <= not MODE_LD_Q;

    RAW <= (not H9) and (not H7);   -- groups 32-47

    R0 <= (V0 and RAW)
       or (V0 and (not LC3) and (not LC2))           -- 1x, and fold on a 160-read line (revision 06)
       or (V8 and (not RAW) and (not LC3) and LC2)   -- 2x
       or (V7 and (not RAW) and LC3);                -- 4x

    R1 <= (V1 and RAW)
       or (V1 and (not LC3))
       or (V8 and (not RAW) and LC3);                -- 4x

    R7 <= (V7 and RAW)
       or (V7 and (not LC3))
       or ((not RAW) and LC3);                       -- 4x: 1

    R8 <= (V8 and RAW)
       or (V8 and (not LC7) and (not LC3) and (not LC2))
       or ((not RAW) and (not LC7) and LC3)          -- 4x: 1
       or ((not RAW) and (not LC7) and LC2)          -- 2x: 1
       or ((not RAW) and LC7 and (not T2));          -- 160-read line: half column

end architecture rtl;
