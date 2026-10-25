--------------------------------------------------------------------------------
-- Name     PS2
-- PartNo   00
-- Date     10/25/2026
-- Revision 02
-- Designer Justin
-- Device   ATF22V10C (CUPL: g22v10)
--
-- Converted from WinCUPL source ATF22V10_PS2.pld (Revision 02)
--
-- PS/2 receiver (docs/IO.md): receives one byte from the PS/2 keyboard or
-- mouse by itself, holds the device off once the byte is in, and gives
-- the byte to the CPU on a read of x5202.
--
--   - The registers clock on the rising edge of RXCLK (pin 1), the clock
--     line of whichever device the port latch has let go (the two clock
--     lines diode-ORed, 22k to GND).
--   - n1 (newest) to n8 shift in the INVERSE of DATA while a = b = 0 and
--     hold otherwise.  All registers are 0 after a reset; a 1 on DATA
--     shifts in a 0 and changes nothing, so the first 1 to appear is the
--     start bit.  After 8 clocks the start bit is in n8; the 9th clock
--     shifts d7 into n1 and sets b.  The state then counts the parity and
--     stop clocks:
--         a b
--         0 0  receiving (or armed and idle)
--         0 1  9 clocks: the byte is complete
--         1 1  10 clocks (parity)
--         1 0  11 clocks (stop): READY; the device is held off
--   - b's pin (14) is enabled by a and drives low only in the last state,
--     through a Schottky diode onto each PS/2 clock line: the inhibit.
--   - Reads (A1 = 1): x5202 (A0 = 0) D7:D0 = the byte (the pins are
--     declared active low, so they show the data itself); x5203 (A0 = 1)
--     D7 = !a while b = 0: 0 when a byte is ready, else 1.
--   - A write to x5202 or x5203 (PORT_WR & A1) is the asynchronous reset:
--     it re-arms the receiver and lets the device's clock go.
--   The pins are 3-state; the FPGA model has no internal 3-state bus, so
--   the enables are separate outputs (dEn, aEn, bEn) and basys_top.vhd
--   uses them to pick the read bus source and to model the inhibit.
--
-- Equations are transcribed directly from the PLD source without
-- optimization.  All pins are kept as individual std_logic signals.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   PIN 1  = RXCLK             (register clock)
--   PIN 2  = PDATA             (shared PS/2 DATA line)
--   PIN 3  = PORT_RD           (ACTIVE LOW, I/O decode PLD pin 20)
--   PIN 4  = PORT_WR           (ACTIVE LOW, I/O decode PLD pin 19)
--   PIN 5  = A0
--   PIN 6  = A1
--   PIN 14 = B                 (inhibit, enabled by A)
--   PIN 15 = A                 (ACTIVE LOW, onto D7 on reads of x5203 while B = 0)
--   PIN 16 = N8                (ACTIVE LOW, d0 onto D0)
--   PIN 17 = N7                (ACTIVE LOW, d1 onto D1)
--   PIN 18 = N6                (ACTIVE LOW, d2 onto D2)
--   PIN 19 = N5                (ACTIVE LOW, d3 onto D3)
--   PIN 20 = N4                (ACTIVE LOW, d4 onto D4)
--   PIN 21 = N3                (ACTIVE LOW, d5 onto D5)
--   PIN 22 = N2                (ACTIVE LOW, d6 onto D6)
--   PIN 23 = N1                (ACTIVE LOW, d7 onto D7, the newest bit)
--   Unused: pins 7, 8, 9, 10, 11, 13
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity ps2_pld is
    port (
        rxclk   : in  std_logic;   -- pin 1, register clock
        pdata   : in  std_logic;   -- pin 2
        portRdN : in  std_logic;   -- pin 3, active low
        portWrN : in  std_logic;   -- pin 4, active low
        a0      : in  std_logic;   -- pin 5
        a1      : in  std_logic;   -- pin 6

        b       : out std_logic;   -- pin 14, the inhibit (low = the clocks are held)
        aN      : out std_logic;   -- pin 15, active low (D7 of x5203: 0 = ready)
        d0      : out std_logic;   -- pin 16 (!N8)
        d1      : out std_logic;   -- pin 17 (!N7)
        d2      : out std_logic;   -- pin 18 (!N6)
        d3      : out std_logic;   -- pin 19 (!N5)
        d4      : out std_logic;   -- pin 20 (!N4)
        d5      : out std_logic;   -- pin 21 (!N3)
        d6      : out std_logic;   -- pin 22 (!N2)
        d7      : out std_logic;   -- pin 23 (!N1)
        dEn     : out std_logic;   -- output enable of pins 16-23 (model only)
        aEn     : out std_logic;   -- output enable of pin 15 (model only)
        bEn     : out std_logic    -- output enable of pin 14 (model only)
    );
end entity ps2_pld;

architecture rtl of ps2_pld is

    signal portRd : std_logic;
    signal portWr : std_logic;
    signal ar     : std_logic;    -- asynchronous reset: the re-arm

    -- the registers (0 after a reset)
    signal n1 : std_logic := '0';
    signal n2 : std_logic := '0';
    signal n3 : std_logic := '0';
    signal n4 : std_logic := '0';
    signal n5 : std_logic := '0';
    signal n6 : std_logic := '0';
    signal n7 : std_logic := '0';
    signal n8 : std_logic := '0';
    signal a  : std_logic := '0';
    signal bR : std_logic := '0';

begin

    portRd <= not portRdN;
    portWr <= not portWrN;

    -- A write to x5202 or x5203 re-arms the receiver.
    ar <= portWr and a1;

    regProc : process (rxclk, ar)
    begin
        if ar = '1' then
            n1 <= '0';
            n2 <= '0';
            n3 <= '0';
            n4 <= '0';
            n5 <= '0';
            n6 <= '0';
            n7 <= '0';
            n8 <= '0';
            a  <= '0';
            bR <= '0';
        elsif rising_edge(rxclk) then
            -- Shift while A = B = 0, hold otherwise.
            n1 <= (a and n1) or (bR and n1) or ((not a) and (not bR) and (not pdata));
            n2 <= (a and n2) or (bR and n2) or ((not a) and (not bR) and n1);
            n3 <= (a and n3) or (bR and n3) or ((not a) and (not bR) and n2);
            n4 <= (a and n4) or (bR and n4) or ((not a) and (not bR) and n3);
            n5 <= (a and n5) or (bR and n5) or ((not a) and (not bR) and n4);
            n6 <= (a and n6) or (bR and n6) or ((not a) and (not bR) and n5);
            n7 <= (a and n7) or (bR and n7) or ((not a) and (not bR) and n6);
            n8 <= (a and n8) or (bR and n8) or ((not a) and (not bR) and n7);
            -- State: 00 -> 01 when the start bit reaches N8 -> 11 -> 10 and stay.
            bR <= ((not a) and n8) or ((not a) and bR);
            a  <= a or bR;
        end if;
    end process regProc;

    -- data pins (declared active low: they show the data itself)
    d7 <= not n1;
    d6 <= not n2;
    d5 <= not n3;
    d4 <= not n4;
    d3 <= not n5;
    d2 <= not n6;
    d1 <= not n7;
    d0 <= not n8;
    dEn <= portRd and a1 and (not a0);

    aN  <= not a;
    aEn <= portRd and a1 and a0 and (not bR);

    b   <= bR;
    bEn <= a;

end architecture rtl;
