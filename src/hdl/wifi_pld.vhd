--------------------------------------------------------------------------------
-- Name     WIFI
-- PartNo   00
-- Date     11/21/2026
-- Revision 01
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_WIFI.pld (Revision 01)
--
-- The SPI port of the WiFi expansion card (docs/architecture/WIFICARD.md):
-- the card's one chip besides its WiFi module (an ESP32-C3-DevKitM-1 board,
-- an SPI slave).  It answers at the card's offsets 60h-7Fh (A6 and A5 high).
--
--   - The four registers clock on the rising edge of /WE (pin 1, the
--     register clock), the end of every write.  They load D3:D0 when the
--     write is to the card's registers and hold their value on every other
--     /WE.  They clear at power-up; all four are declared active low, so
--     the pins start high (SCK, MOSI, /CS) or off (the reset pin).
--       bit 0  sck     SCK
--       bit 1  mosi    MOSI
--       bit 2  csN     the module's /CS
--       bit 3  mrstN   0 pulls the module's RST low; 1 leaves the pin off
--   - The reset pin (17) only pulls low: its output enable is the register.
--   - Reads (LOAD_MEM, /EXP and Q0 low): D7 = MISO, D6 = READY, D5:D2 = 1010
--     at an even offset and 0101 at an odd one.  The pins are 3-state; d2
--     and d3 are also the register's data inputs on a write, so they are
--     inout here.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = WE                (ACTIVE LOW, register clock; slot B24)
--   PIN 2  = EXP               (ACTIVE LOW, the slot's select; slot A16)
--   PIN 3  = Q0                (slot A10)
--   PIN 4  = A0
--   PIN 5  = A5
--   PIN 6  = A6
--   PIN 7  = D0
--   PIN 8  = D1
--   PIN 9  = MISO              (module IO5, 3.3 V)
--   PIN 10 = READY             (module IO4, 3.3 V)
--   PIN 14 = SCKN              (ACTIVE LOW, register: the pin follows D0)
--   PIN 15 = MOSIN             (ACTIVE LOW, register: the pin follows D1)
--   PIN 16 = CSN               (ACTIVE LOW, register: the pin follows D2)
--   PIN 17 = MRST              (ACTIVE LOW, register; 3-state, enable MRST)
--   PIN 18 = D2                (3-state, enable REG_RD; register data on a write)
--   PIN 19 = D3                (3-state, enable REG_RD; register data on a write)
--   PIN 20 = D4                (3-state, enable REG_RD)
--   PIN 21 = D5                (3-state, enable REG_RD)
--   PIN 22 = D6                (3-state, enable REG_RD)
--   PIN 23 = D7                (3-state, enable REG_RD)
--   Unused: 11, 13
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity wifi_pld is
    port (
        weN   : in    std_logic;   -- pin 1, active low, register clock
        expN  : in    std_logic;   -- pin 2, active low
        q0    : in    std_logic;   -- pin 3
        a0    : in    std_logic;   -- pin 4
        a5    : in    std_logic;   -- pin 5
        a6    : in    std_logic;   -- pin 6
        d0    : in    std_logic;   -- pin 7
        d1    : in    std_logic;   -- pin 8
        miso  : in    std_logic;   -- pin 9
        ready : in    std_logic;   -- pin 10

        sck   : out   std_logic;   -- pin 14 (the pin of the SCKN register)
        mosi  : out   std_logic;   -- pin 15 (the pin of the MOSIN register)
        csN   : out   std_logic;   -- pin 16 (the pin of the CSN register)
        mrstN : out   std_logic;   -- pin 17, active low, 3-state
        d2    : inout std_logic;   -- pin 18
        d3    : inout std_logic;   -- pin 19
        d4    : out   std_logic;   -- pin 20
        d5    : out   std_logic;   -- pin 21
        d6    : out   std_logic;   -- pin 22
        d7    : out   std_logic    -- pin 23
    );
end entity wifi_pld;

architecture rtl of wifi_pld is

    signal expSel   : std_logic;
    signal regSel   : std_logic;
    signal regRd    : std_logic;

    -- the registers, as the PLD holds them (cleared at power-up)
    signal sckNReg  : std_logic := '0';
    signal mosiNReg : std_logic := '0';
    signal csNReg   : std_logic := '0';
    signal mrstReg  : std_logic := '0';

begin

    expSel <= not expN;
    regSel <= expSel and a6 and a5;       -- REG    = EXP & A6 & A5
    regRd  <= regSel and (not q0);        -- REG_RD = REG & !Q0

    -- Output register: the pin follows the data bit written to the card's
    -- registers, and holds on every other /WE.  The clock is pin 1, /WE:
    -- its rising edge.  D2 and D3 are read through their pins.
    regProc : process (weN)
    begin
        if rising_edge(weN) then
            sckNReg  <= (regSel and (not d0)) or ((not regSel) and sckNReg);    -- SCKN.D  = REG & !D0 # !REG & SCKN
            mosiNReg <= (regSel and (not d1)) or ((not regSel) and mosiNReg);   -- MOSIN.D = REG & !D1 # !REG & MOSIN
            csNReg   <= (regSel and (not to_x01(d2))) or ((not regSel) and csNReg);    -- CSN.D   = REG & !D2 # !REG & CSN
            mrstReg  <= (regSel and (not to_x01(d3))) or ((not regSel) and mrstReg);   -- MRST.D  = REG & !D3 # !REG & MRST
        end if;
    end process regProc;

    -- register pins (all declared active low)
    sck   <= not sckNReg;
    mosi  <= not mosiNReg;
    csN   <= not csNReg;
    mrstN <= (not mrstReg) when mrstReg = '1' else 'Z';   -- MRST.OE = MRST

    d7 <= miso      when regRd = '1' else 'Z';   -- D7 = MISO;  D7.OE = REG_RD
    d6 <= ready     when regRd = '1' else 'Z';   -- D6 = READY; D6.OE = REG_RD
    d5 <= (not a0)  when regRd = '1' else 'Z';   -- D5 = !A0;   D5.OE = REG_RD
    d4 <= (    a0)  when regRd = '1' else 'Z';   -- D4 = A0;    D4.OE = REG_RD
    d3 <= (not a0)  when regRd = '1' else 'Z';   -- D3 = !A0;   D3.OE = REG_RD
    d2 <= (    a0)  when regRd = '1' else 'Z';   -- D2 = A0;    D2.OE = REG_RD

end architecture rtl;
