-- ============================================================
-- Name     : quad_4to1_mux
-- PartNo   : ATF22V10C
-- Device   : g22v10 (WinCUPL 2)
-- Source   : ATF22V10_QUAD_MUX.pld (direct conversion, equations unchanged)
--
-- Select table:
--   s1 s0
--    0  0  -> a
--    0  1  -> b
--    1  0  -> c
--    1  1  -> d
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity quad_4to1_mux is
    port (
        -- MUX 0
        a0 : in  std_logic;  -- pin 1
        b0 : in  std_logic;  -- pin 2
        c0 : in  std_logic;  -- pin 3
        d0 : in  std_logic;  -- pin 4

        -- MUX 1
        a1 : in  std_logic;  -- pin 5
        b1 : in  std_logic;  -- pin 6
        c1 : in  std_logic;  -- pin 7
        d1 : in  std_logic;  -- pin 8

        -- Common select
        s0 : in  std_logic;  -- pin 9
        s1 : in  std_logic;  -- pin 10

        -- MUX 2
        a2 : in  std_logic;  -- pin 11
        b2 : in  std_logic;  -- pin 13
        c2 : in  std_logic;  -- pin 14
        d2 : in  std_logic;  -- pin 15

        -- MUX 3
        a3 : in  std_logic;  -- pin 16
        b3 : in  std_logic;  -- pin 17
        c3 : in  std_logic;  -- pin 18
        d3 : in  std_logic;  -- pin 19

        -- Outputs
        y0 : out std_logic;  -- pin 20
        y1 : out std_logic;  -- pin 21
        y2 : out std_logic;  -- pin 22
        y3 : out std_logic   -- pin 23
    );
end entity quad_4to1_mux;

architecture rtl of quad_4to1_mux is
begin

    -- MUX 0
    y0 <= ((not s1) and (not s0) and a0)
       or ((not s1) and (    s0) and b0)
       or ((    s1) and (not s0) and c0)
       or ((    s1) and (    s0) and d0);

    -- MUX 1
    y1 <= ((not s1) and (not s0) and a1)
       or ((not s1) and (    s0) and b1)
       or ((    s1) and (not s0) and c1)
       or ((    s1) and (    s0) and d1);

    -- MUX 2
    y2 <= ((not s1) and (not s0) and a2)
       or ((not s1) and (    s0) and b2)
       or ((    s1) and (not s0) and c2)
       or ((    s1) and (    s0) and d2);

    -- MUX 3
    y3 <= ((not s1) and (not s0) and a3)
       or ((not s1) and (    s0) and b3)
       or ((    s1) and (not s0) and c3)
       or ((    s1) and (    s0) and d3);

end architecture rtl;
