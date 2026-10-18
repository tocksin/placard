--------------------------------------------------------------------------------
-- Name     PORT
-- PartNo   00
-- Date     10/18/2026
-- Revision 01
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_PORT.pld (Revision 01)
--
-- Shared port at 5200h (docs/IO.md): keyboard columns and the SNES pad read.
--   - colNN: keyboard column n is low when the port latch's bits 7:4
--     (k3:k0) hold n (0-7); codes 8-15 drive no column.
--   - d7, d6: pad 1 and pad 2 DATA onto the read bus on a read of an odd
--     address (portRdN = 0 and a0 = 1).  The 74F541 (key rows) is enabled
--     on even addresses only.  d7 and d6 are 3-state; the FPGA model has no
--     internal 3-state bus, so the enable is a separate output (dEn) and
--     basys_top.vhd uses it to pick the read bus source.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = PORT_RD           (ACTIVE LOW, I/O decode PLD pin 20)
--   PIN 2  = A0
--   PIN 3  = K0                (port latch Q4)
--   PIN 4  = K1                (port latch Q5)
--   PIN 5  = K2                (port latch Q6)
--   PIN 6  = K3                (port latch Q7)
--   PIN 7  = PAD1              (pad 1 DATA)
--   PIN 8  = PAD2              (pad 2 DATA)
--   PIN 14 = COL0              (ACTIVE LOW)
--   PIN 15 = COL1              (ACTIVE LOW)
--   PIN 16 = COL2              (ACTIVE LOW)
--   PIN 17 = COL3              (ACTIVE LOW)
--   PIN 18 = COL4              (ACTIVE LOW)
--   PIN 19 = COL5              (ACTIVE LOW)
--   PIN 20 = COL6              (ACTIVE LOW)
--   PIN 21 = COL7              (ACTIVE LOW)
--   PIN 22 = D6                (3-state, enable PORT_RD & A0)
--   PIN 23 = D7                (3-state, enable PORT_RD & A0)
--   Unused: pins 9, 10, 11, 13
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity port_pld is
    port (
        portRdN : in  std_logic;   -- pin 1, active low
        a0      : in  std_logic;   -- pin 2
        k0      : in  std_logic;   -- pin 3
        k1      : in  std_logic;   -- pin 4
        k2      : in  std_logic;   -- pin 5
        k3      : in  std_logic;   -- pin 6
        pad1    : in  std_logic;   -- pin 7
        pad2    : in  std_logic;   -- pin 8

        col0N   : out std_logic;   -- pin 14
        col1N   : out std_logic;   -- pin 15
        col2N   : out std_logic;   -- pin 16
        col3N   : out std_logic;   -- pin 17
        col4N   : out std_logic;   -- pin 18
        col5N   : out std_logic;   -- pin 19
        col6N   : out std_logic;   -- pin 20
        col7N   : out std_logic;   -- pin 21
        d6      : out std_logic;   -- pin 22
        d7      : out std_logic;   -- pin 23
        dEn     : out std_logic    -- output enable of pins 22 and 23 (model only)
    );
end entity port_pld;

architecture rtl of port_pld is

    signal portRd : std_logic;
    signal col0   : std_logic;
    signal col1   : std_logic;
    signal col2   : std_logic;
    signal col3   : std_logic;
    signal col4   : std_logic;
    signal col5   : std_logic;
    signal col6   : std_logic;
    signal col7   : std_logic;

begin

    portRd <= not portRdN;

    col0 <= (not k3) and (not k2) and (not k1) and (not k0);
    col1 <= (not k3) and (not k2) and (not k1) and (    k0);
    col2 <= (not k3) and (not k2) and (    k1) and (not k0);
    col3 <= (not k3) and (not k2) and (    k1) and (    k0);
    col4 <= (not k3) and (    k2) and (not k1) and (not k0);
    col5 <= (not k3) and (    k2) and (not k1) and (    k0);
    col6 <= (not k3) and (    k2) and (    k1) and (not k0);
    col7 <= (not k3) and (    k2) and (    k1) and (    k0);

    -- outputs (column pins are active low)
    col0N <= not col0;
    col1N <= not col1;
    col2N <= not col2;
    col3N <= not col3;
    col4N <= not col4;
    col5N <= not col5;
    col6N <= not col6;
    col7N <= not col7;

    d7  <= pad1;
    d6  <= pad2;
    dEn <= portRd and a0;

end architecture rtl;
