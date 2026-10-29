--------------------------------------------------------------------------------
-- Name     PORT
-- PartNo   00
-- Date     10/25/2026
-- Revision 04
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_PORT.pld (Revision 04)
--
-- The whole shared port at 5200h (docs/IO.md) in one chip: the output
-- register (it was the 74HC574 latch U37) and the read of the SD card's
-- MISO, the two SNES pads' DATA and the free PS/2 device's clock (it was
-- the 74F541 row buffer U39).  The Cherry MX key matrix is gone (revision
-- 03); the PS/2 bytes are received by the PS/2 receiver PLD (ps2_pld.vhd)
-- at x5202 and x5203, so this chip only drives the bus while A1 = 0
-- (revision 04).
--
--   - The five registers load D4:D0 on the rising edge of /PORT_WR (pin
--     1, the register clock), the end of a write to any x52xx.  They
--     clear at power-up; SCK, MOSI and the DATA hold are declared active
--     low, so their pins start high and the port rests at EB.
--       bit 0  sck    SCK and the pads' CLOCK
--       bit 1  mosi   MOSI and the pads' LATCH
--       bit 2  sdcs   SD /CS; 0 also holds the mouse's CLK low (diode)
--       bit 3  dholdN 0 holds the shared PS/2 DATA line low (diode)
--       bit 4  k0     0 holds the PS/2 keyboard's CLK low (diode)
--   - Reads while A1 = 0: D7 = MISO (even address) or pad 1 DATA (odd),
--     D6 = pad 2 DATA (odd), D5 = RXCLK (both).  The pins are 3-state;
--     the FPGA model has no internal 3-state bus, so each has a separate
--     enable output (d5En, d6En, d7En) and basys_top.vhd uses them to
--     pick the read bus source.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = PORT_WR           (ACTIVE LOW, register clock; I/O decode PLD pin 19)
--   PIN 2  = PORT_RD           (ACTIVE LOW, I/O decode PLD pin 20)
--   PIN 3  = A0
--   PIN 4  = D0
--   PIN 5  = D1
--   PIN 6  = D2
--   PIN 7  = D3
--   PIN 8  = D4
--   PIN 9  = PAD1              (pad 1 DATA)
--   PIN 10 = PAD2              (pad 2 DATA)
--   PIN 11 = RXCLK             (the free PS/2 device's clock, diode-ORed)
--   PIN 13 = MISO              (SD card DO, 3.3 V)
--   PIN 14 = A1
--   PIN 16 = K0                (register)
--   PIN 17 = DHOLD             (ACTIVE LOW, register)
--   PIN 18 = SDCS              (register)
--   PIN 19 = MOSIN             (ACTIVE LOW, register: the pin follows D1)
--   PIN 20 = SCKN              (ACTIVE LOW, register: the pin follows D0)
--   PIN 21 = D5                (3-state, enable PORT_RD & !A1)
--   PIN 22 = D6                (3-state, enable PORT_RD & !A1 & A0)
--   PIN 23 = D7                (3-state, enable PORT_RD & !A1)
--   Unused: pin 15
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity port_pld is
    port (
        portWrN : in  std_logic;   -- pin 1, active low, register clock
        portRdN : in  std_logic;   -- pin 2, active low
        a0      : in  std_logic;   -- pin 3
        d0      : in  std_logic;   -- pin 4
        d1      : in  std_logic;   -- pin 5
        d2      : in  std_logic;   -- pin 6
        d3      : in  std_logic;   -- pin 7
        d4      : in  std_logic;   -- pin 8
        pad1    : in  std_logic;   -- pin 9
        pad2    : in  std_logic;   -- pin 10
        rxclk   : in  std_logic;   -- pin 11
        miso    : in  std_logic;   -- pin 13
        a1      : in  std_logic;   -- pin 14

        k0      : out std_logic;   -- pin 16
        dholdN  : out std_logic;   -- pin 17, active low
        sdcs    : out std_logic;   -- pin 18
        mosi    : out std_logic;   -- pin 19 (the pin of the MOSIN register)
        sck     : out std_logic;   -- pin 20 (the pin of the SCKN register)
        d5      : out std_logic;   -- pin 21
        d6      : out std_logic;   -- pin 22
        d7      : out std_logic;   -- pin 23
        d5En    : out std_logic;   -- output enable of pin 21 (model only)
        d6En    : out std_logic;   -- output enable of pin 22 (model only)
        d7En    : out std_logic    -- output enable of pin 23 (model only)
    );
end entity port_pld;

architecture rtl of port_pld is

    signal portWr   : std_logic;
    signal portRd   : std_logic;

    -- the registers, as the PLD holds them (cleared at power-up)
    signal sckNReg  : std_logic := '0';
    signal mosiNReg : std_logic := '0';
    signal sdcsReg  : std_logic := '0';
    signal dholdReg : std_logic := '0';
    signal k0Reg    : std_logic := '0';

begin

    portWr <= not portWrN;
    portRd <= not portRdN;

    -- Output register: the pin follows the data bit written.
    regProc : process (portWr)
    begin
        if rising_edge(portWr) then
            sckNReg  <= not d0;         -- SCKN.D  = !D0
            mosiNReg <= not d1;         -- MOSIN.D = !D1
            sdcsReg  <= d2;             -- SDCS.D  =  D2
            dholdReg <= not d3;         -- DHOLD.D = !D3
            k0Reg    <= d4;             -- K0.D    =  D4
        end if;
    end process regProc;

    -- register pins (SCKN, MOSIN and DHOLD are declared active low)
    sck    <= not sckNReg;
    mosi   <= not mosiNReg;
    sdcs   <= sdcsReg;
    dholdN <= not dholdReg;
    k0     <= k0Reg;

    d7   <= ((not a0) and miso)
         or ((    a0) and pad1);
    d7En <= portRd and (not a1);

    d6   <= pad2;
    d6En <= portRd and (not a1) and a0;

    d5   <= rxclk;
    d5En <= portRd and (not a1);

end architecture rtl;
