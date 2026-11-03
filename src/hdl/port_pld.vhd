--------------------------------------------------------------------------------
-- Name     PORT
-- PartNo   00
-- Date     11/03/2026
-- Revision 05
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_PORT.pld (Revision 05)
--
-- The whole shared port at 5200h (docs/architecture/IO.md) in one chip: the output
-- register (it was the 74HC574 latch U37) and the read of the SD card's
-- MISO, the two SNES pads' DATA and the free PS/2 device's clock (it was
-- the 74F541 row buffer U39).  The Cherry MX key matrix is gone (revision
-- 03); the PS/2 bytes are received by the PS/2 receiver PLD (ps2_pld.vhd)
-- at x5202 and x5203, so this chip only drives the bus while A1 = 0
-- (revision 04).
-- Revision 05: the I/O decode PLD (rev 07) gives the address-only select
-- /PORT (pin 2, the old /PORT_RD net).  Pin 1 is /WE: the registers clock
-- on every /WE and load D4:D0 only while /PORT is low (hold terms).  Pin
-- 15 is Q0; reads are PORT and not Q0 (LOAD_MEM).
--
--   - The five registers load D4:D0 on the rising edge of /WE (pin 1,
--     the register clock) while /PORT is low, the end of a write to any
--     x52xx, and hold their value on every other /WE.  They
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
--   PIN 1  = WE                (ACTIVE LOW, register clock; Sync PLD pin 20)
--   PIN 2  = PORT              (ACTIVE LOW, I/O decode PLD pin 20)
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
--   PIN 15 = Q0                (State PLD pin 18, state bit 0)
--   PIN 16 = K0                (register)
--   PIN 17 = DHOLD             (ACTIVE LOW, register)
--   PIN 18 = SDCS              (register)
--   PIN 19 = MOSIN             (ACTIVE LOW, register: the pin follows D1)
--   PIN 20 = SCKN              (ACTIVE LOW, register: the pin follows D0)
--   PIN 21 = D5                (3-state, enable PORT_RD & !A1)
--   PIN 22 = D6                (3-state, enable PORT_RD & !A1 & A0)
--   PIN 23 = D7                (3-state, enable PORT_RD & !A1)
--   Unused: none
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity port_pld is
    port (
        weN     : in  std_logic;   -- pin 1, active low, register clock (rev 05, was portWrN)
        portN   : in  std_logic;   -- pin 2, active low (rev 05, was portRdN)
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
        q0      : in  std_logic;   -- pin 15 (rev 05)

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

    signal we       : std_logic;
    signal portSel     : std_logic;
    signal portRd   : std_logic;

    -- the registers, as the PLD holds them (cleared at power-up)
    signal sckNReg  : std_logic := '0';
    signal mosiNReg : std_logic := '0';
    signal sdcsReg  : std_logic := '0';
    signal dholdReg : std_logic := '0';
    signal k0Reg    : std_logic := '0';

begin

    we     <= not weN;
    portSel   <= not portN;
    portRd <= portSel and (not q0);        -- PORT_RD = PORT & !Q0

    -- Output register: the pin follows the data bit written while /PORT
    -- is low, and holds on every other /WE.
    regProc : process (we)
    begin
        if rising_edge(we) then
            sckNReg  <= (portSel and (not d0)) or ((not portSel) and sckNReg);    -- SCKN.D  = PORT & !D0 # !PORT & SCKN
            mosiNReg <= (portSel and (not d1)) or ((not portSel) and mosiNReg);   -- MOSIN.D = PORT & !D1 # !PORT & MOSIN
            sdcsReg  <= (portSel and (    d2)) or ((not portSel) and sdcsReg);    -- SDCS.D  = PORT &  D2 # !PORT & SDCS
            dholdReg <= (portSel and (not d3)) or ((not portSel) and dholdReg);   -- DHOLD.D = PORT & !D3 # !PORT & DHOLD
            k0Reg    <= (portSel and (    d4)) or ((not portSel) and k0Reg);      -- K0.D    = PORT &  D4 # !PORT & K0
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
