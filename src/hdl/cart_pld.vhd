-- ============================================================
-- ROM CARTRIDGE LOADER
-- revision 03 is the same logic as revision 01; revision 02 (opcode byte stored XOR FDh) was reverted 2026-10-21.
-- VHDL conversion of ATF22V10_CART.pld (revision 03)
-- Date: 10/21/2026
--
-- On the ROM cartridge.  Holds the main board's clock (HOLD, pin 23)
-- from power-up, steps the CPU through the 64K one clock at a time,
-- copies each EEPROM byte into the cartridge SRAM at the address the
-- PC puts on the bus, feeds the CPU 02h (ld ac, ac) from a 74AC541,
-- and raises RUN when the PC wraps to x0000.  See the PLD source and
-- docs/ROM.md, "Loading the cartridge".
--
--     decide  = not run and not release and cnt = 0
--     read    = not pixelEnable and srcEnN
--     wrap    = not a15 and prev15
--     copy    = decide and read and not wrap
--     handoff = decide and read and wrap
--
-- Every register clears at power-up, as on the ATF22V10C, so HOLD is
-- high and RUN low until the load is done.
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- Pin assignments (ATF22V10C):
--   1  osc        2  a15        3  pixelEnable   4  srcEnN
--  14  cnt0      15  cnt1      16  cnt2         17  cnt3
--  18  prev15    19  srWeN     20  eeOeN        21  bufOeN
--  22  run       23  hold
--   5-11, 13  not used
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity cart_pld is
    port (
        osc         : in  std_logic;   -- pin 1, 25.175 MHz oscillator (register clock)
        a15         : in  std_logic;   -- pin 2, /CE_LO = address mux A15
        pixelEnable : in  std_logic;   -- pin 3, Sync PLD pin 19
        srcEnN      : in  std_logic;   -- pin 4, branch PLD pin 16, 0 = EXEC

        cnt0        : out std_logic;   -- pin 14, step counter (not connected)
        cnt1        : out std_logic;   -- pin 15
        cnt2        : out std_logic;   -- pin 16
        cnt3        : out std_logic;   -- pin 17
        prev15      : out std_logic;   -- pin 18, A15 at the last CPU read (not connected)
        srWeN       : out std_logic;   -- pin 19, cartridge SRAM /WE
        eeOeN       : out std_logic;   -- pin 20, EEPROM /OE
        bufOeN      : out std_logic;   -- pin 21, 74AC541 /OE (inputs wired to 02h)
        run         : out std_logic;   -- pin 22, to memory control pin 17, map /MR, card /RESET
        hold        : out std_logic    -- pin 23, to the main board's clock gate
    );
end entity cart_pld;

architecture rtl of cart_pld is

    -- registers, all 0 at power-up
    signal cnt0Q    : std_logic := '0';
    signal cnt1Q    : std_logic := '0';
    signal cnt2Q    : std_logic := '0';
    signal cnt3Q    : std_logic := '0';
    signal prev15Q  : std_logic := '0';
    signal srWeQ    : std_logic := '0';
    signal eeOeQ    : std_logic := '0';
    signal bufOeQ   : std_logic := '0';
    signal runQ     : std_logic := '0';
    signal releaseQ : std_logic := '0';

    signal cntIs0   : std_logic;
    signal cntIs4   : std_logic;
    signal cntIs6   : std_logic;
    signal cntIs8   : std_logic;
    signal decide   : std_logic;
    signal read     : std_logic;
    signal wrap     : std_logic;
    signal copy     : std_logic;
    signal handoff  : std_logic;

begin

    -- ---------------- decode ----------------

    cntIs0 <= (not cnt3Q) and (not cnt2Q) and (not cnt1Q) and (not cnt0Q);
    cntIs4 <= (not cnt3Q) and (    cnt2Q) and (not cnt1Q) and (not cnt0Q);
    cntIs6 <= (not cnt3Q) and (    cnt2Q) and (    cnt1Q) and (not cnt0Q);
    cntIs8 <= (    cnt3Q) and (not cnt2Q) and (not cnt1Q) and (not cnt0Q);

    decide  <= (not runQ) and (not releaseQ) and cntIs0;
    read    <= (not pixelEnable) and srcEnN;
    wrap    <= (not a15) and prev15Q;
    copy    <= decide and read and (not wrap);
    handoff <= decide and read and wrap;

    -- ---------------- registers ----------------

    process (osc)
    begin
        if rising_edge(osc) then
            releaseQ <= runQ
                     or (decide and (not read))
                     or handoff
                     or ((not runQ) and cntIs8);

            runQ <= runQ or handoff;

            cnt0Q <= copy
                  or ((not cnt3Q) and (not cnt0Q) and cnt1Q)
                  or ((not cnt3Q) and (not cnt0Q) and cnt2Q);
            cnt1Q <= ((not cnt3Q) and cnt1Q and (not cnt0Q))
                  or ((not cnt3Q) and (not cnt1Q) and cnt0Q);
            cnt2Q <= ((not cnt3Q) and (not cnt2Q) and cnt1Q and cnt0Q)
                  or ((not cnt3Q) and cnt2Q and (not cnt1Q))
                  or ((not cnt3Q) and cnt2Q and (not cnt0Q));
            cnt3Q <= (not cnt3Q) and cnt2Q and cnt1Q and cnt0Q;

            prev15Q <= (copy and a15)
                    or ((not decide) and prev15Q)
                    or ((not read) and prev15Q);

            eeOeQ <= copy or (eeOeQ and (not cntIs6));

            srWeQ <= cntIs4;

            bufOeQ <= (not runQ) and cntIs8;
        end if;
    end process;

    -- ---------------- outputs ----------------

    cnt0   <= cnt0Q;
    cnt1   <= cnt1Q;
    cnt2   <= cnt2Q;
    cnt3   <= cnt3Q;
    prev15 <= prev15Q;
    srWeN  <= not srWeQ;
    eeOeN  <= not eeOeQ;
    bufOeN <= not bufOeQ;
    run    <= runQ;
    hold   <= not releaseQ;

end architecture rtl;
