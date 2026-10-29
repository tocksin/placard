-- ============================================================
-- ROM CARTRIDGE LOADER
-- VHDL conversion of ATF22V10_CART.pld (revision 04)
-- Date: 10/21/2026
--
-- Revision 04 stalls the CPU (STALL_OUT) at each address the PC
-- reaches instead of holding the board clock, and has no 74AC541:
-- the instruction register PLD holds 02h while RUN is low.  See the
-- .pld for how it works and its timing.
--
-- Equations are carried over from the PLD without optimization.
--
-- Pins:
--   1  clk        2  a15        3  pixelEnable   4  pcEnable
--   5  stallIn
--   14 g0         15 g1         16 g2            17 copy
--   18 prev15     19 srWeN      20 eeOeN         21 synced
--   22 run        23 stallOut
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity cart_pld is
    port (
        clk         : in  std_logic;   -- pin 1, the board clock
        a15         : in  std_logic;   -- pin 2, /CE_LO = address mux A15
        pixelEnable : in  std_logic;   -- pin 3, Sync PLD pin 19
        pcEnable    : in  std_logic;   -- pin 4, State PLD pin 15, FETCH or LOAD_IMM
        stallIn     : in  std_logic;   -- pin 5, Branch PLD pin 19

        g0          : out std_logic;   -- pin 14, group phase (not connected)
        g1          : out std_logic;   -- pin 15
        g2          : out std_logic;   -- pin 16
        copy        : out std_logic;   -- pin 17, a copy is running (not connected)
        prev15      : out std_logic;   -- pin 18, A15 at the last copy (not connected)
        srWeN       : out std_logic;   -- pin 19, cartridge SRAM /WE
        eeOeN       : out std_logic;   -- pin 20, EEPROM /OE
        synced      : out std_logic;   -- pin 21, a video read has been seen (not connected)
        run         : out std_logic;   -- pin 22, to memory control pin 17, IR PLD pin 11, map /MR, card /RESET
        stallOut    : out std_logic    -- pin 23, to State PLD pin 2 and the PC PLDs pin 14 (combinational)
    );
end entity cart_pld;

architecture rtl of cart_pld is

    -- registers, all 0 at power-up
    signal g0Q      : std_logic := '0';
    signal g1Q      : std_logic := '0';
    signal g2Q      : std_logic := '0';
    signal copyQ    : std_logic := '0';
    signal prev15Q  : std_logic := '0';
    signal srWeQ    : std_logic := '0';
    signal eeOeQ    : std_logic := '0';
    signal syncedQ  : std_logic := '0';
    signal runQ     : std_logic := '0';

    signal k0       : std_logic;
    signal k3       : std_logic;

begin

    -- ---------------- decode ----------------

    k0 <= (not g2Q) and (not g1Q) and (not g0Q);
    k3 <= (not g2Q) and (    g1Q) and (not g0Q);

    -- ---------------- registers ----------------

    process (clk)
    begin
        if rising_edge(clk) then
            g0Q <= ((not pixelEnable) and (not g2Q) and (not g1Q))
                or ((not pixelEnable) and g2Q and g1Q);
            g1Q <= ((not pixelEnable) and (not g2Q) and g0Q)
                or ((not pixelEnable) and (not g2Q) and g1Q)
                or ((not pixelEnable) and g1Q and (not g0Q));
            g2Q <= ((not pixelEnable) and g1Q and (not g0Q))
                or ((not pixelEnable) and g2Q and g0Q);

            syncedQ <= syncedQ or pixelEnable;

            copyQ <= (syncedQ and (not runQ) and pcEnable and (not pixelEnable) and k0 and a15)
                  or (syncedQ and (not runQ) and pcEnable and (not pixelEnable) and k0 and (not prev15Q))
                  or (copyQ and (not g2Q))
                  or (copyQ and g1Q)
                  or (copyQ and (not g0Q));

            prev15Q <= prev15Q
                    or (syncedQ and (not runQ) and pcEnable and (not pixelEnable) and k0 and a15);

            runQ <= runQ
                 or (syncedQ and (not runQ) and pcEnable and (not pixelEnable) and k0 and (not a15) and prev15Q);

            srWeQ <= copyQ and k3;

            eeOeQ <= (syncedQ and (not runQ) and pcEnable and (not pixelEnable) and k0 and a15)
                  or (syncedQ and (not runQ) and pcEnable and (not pixelEnable) and k0 and (not prev15Q))
                  or (copyQ and (not g2Q) and g0Q)
                  or (copyQ and (not g2Q) and g1Q);
        end if;
    end process;

    -- ---------------- combinational outputs ----------------

    stallOut <= stallIn
             or ((not runQ) and pcEnable and (not copyQ))
             or ((not runQ) and pcEnable and (not g2Q))
             or ((not runQ) and pcEnable and g1Q)
             or ((not runQ) and pcEnable and (not g0Q));

    -- ---------------- outputs ----------------

    g0     <= g0Q;
    g1     <= g1Q;
    g2     <= g2Q;
    copy   <= copyQ;
    prev15 <= prev15Q;
    srWeN  <= not srWeQ;
    eeOeN  <= not eeOeQ;
    synced <= syncedQ;
    run    <= runQ;

end architecture rtl;
