-- ============================================================
-- Name     : quad_4to1_mux
-- PartNo   : ATF22V10C
-- Device   : g22v10 (WinCUPL 2)
-- Source   : ATF22V10_QUAD_MUX.pld revision 02 (direct conversion,
--            equations unchanged)
-- Date     : 10/27/2026
--
-- Address mux, two low bits and two high bits per chip
-- (docs/FETCH_TIMING.md, option B).  The selects are the
-- address-source enables themselves, with the priority the Sync PLD
-- used before revision 02:
--
--   1. video address    pixelEnable
--   2. program counter  pcEnable
--   3. X / Y registers  xEnable (low byte), yEnable (high byte)
--   4. default          D register (low byte), 00h (high byte)
--
-- Low pair = address bits n, n+1 (sources D, X, video, PC);
-- high pair = address bits n+8, n+9 (sources 00h, Y, video, PC).
-- U7 n = 0, U8 n = 2, U9 n = 4, U10 n = 6.
--
-- Revision 01 was a plain quad 4:1 mux with selects s1 s0 from the
-- Sync PLD.
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity quad_4to1_mux is
    port (
        -- Selects
        pixelEnable : in  std_logic;  -- pin 1, Sync PLD pin 19
        pcEnable    : in  std_logic;  -- pin 2, State PLD
        xEnable     : in  std_logic;  -- pin 3, State PLD
        yEnable     : in  std_logic;  -- pin 4, State PLD

        -- Low bit 0 (address bit n)
        d0          : in  std_logic;  -- pin 5, D register
        x0          : in  std_logic;  -- pin 6, X register
        v0          : in  std_logic;  -- pin 7, video address
        pc0         : in  std_logic;  -- pin 8, program counter

        -- Low bit 1 (address bit n + 1)
        d1          : in  std_logic;  -- pin 9
        x1          : in  std_logic;  -- pin 10
        v1          : in  std_logic;  -- pin 11
        pc1         : in  std_logic;  -- pin 13

        -- High bit 0 (address bit n + 8)
        y2          : in  std_logic;  -- pin 14, Y register
        v2          : in  std_logic;  -- pin 15, video address
        pc2         : in  std_logic;  -- pin 16, program counter

        -- High bit 1 (address bit n + 9)
        y3          : in  std_logic;  -- pin 17
        v3          : in  std_logic;  -- pin 18
        pc3         : in  std_logic;  -- pin 19

        -- Outputs
        lo0         : out std_logic;  -- pin 20, address bit n
        lo1         : out std_logic;  -- pin 21, address bit n + 1
        hi0         : out std_logic;  -- pin 22, address bit n + 8
        hi1         : out std_logic   -- pin 23, address bit n + 9
    );
end entity quad_4to1_mux;

architecture rtl of quad_4to1_mux is
begin

    -- LOW BITS: D register, X register, video address, PC
    lo0 <= (pixelEnable and v0)
        or ((not pixelEnable) and pcEnable and pc0)
        or ((not pixelEnable) and (not pcEnable) and xEnable and x0)
        or ((not pixelEnable) and (not pcEnable) and (not xEnable) and d0);

    lo1 <= (pixelEnable and v1)
        or ((not pixelEnable) and pcEnable and pc1)
        or ((not pixelEnable) and (not pcEnable) and xEnable and x1)
        or ((not pixelEnable) and (not pcEnable) and (not xEnable) and d1);

    -- HIGH BITS: 00h, Y register, video address, PC
    hi0 <= (pixelEnable and v2)
        or ((not pixelEnable) and pcEnable and pc2)
        or ((not pixelEnable) and (not pcEnable) and yEnable and y2);

    hi1 <= (pixelEnable and v3)
        or ((not pixelEnable) and pcEnable and pc3)
        or ((not pixelEnable) and (not pcEnable) and yEnable and y3);

end architecture rtl;
