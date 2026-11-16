-- ============================================================
-- tb_memcard: the 32K memory expansion card (memcard_pld
-- revision 01 and an AS7C256C-15 model) on a timed slot
-- Date: 11/16/2026
--
-- The page register PLD is the real VHDL (zero delay inside; its
-- outputs get the ATF22V10C-7 clock-to-output time here, 2 ns, the
-- shortest, which is the hard case for the SRAM's address hold).
-- The slot is a behavioural model with the times of
-- docs/architecture/EXPANSION.md "Card timing", in a 39.72 ns clock:
--   address, /EXP   valid 13 ns into the clock, held 2 ns past /WE
--   /WE             low from the middle of a write clock to its end
--   write data      valid 9 ns before /WE rises, held 2 ns after
--   Q0              low in a read clock (the SRAM's /OE)
-- The SRAM model stores on the rising edge of /WE while /CE is low,
-- and fails the run if its address moves while /WE and /CE are low.
--
-- Checked: the card starts at page 0; a page write (offsets 78h-7Fh)
-- changes the page and nothing else does (a card write below 78h, a
-- write to another address with /EXP high); every one of the 256
-- pages keeps its own 120 bytes; the page write also stores its byte
-- at the same offset of the page being left (the reserved bytes).
--
--   ghdl -a --std=08 src/hdl/memcard_pld.vhd src/sim/tb_memcard.vhd
--   ghdl -e --std=08 tb_memcard && ghdl -r --std=08 tb_memcard
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_memcard is
end entity tb_memcard;

architecture sim of tb_memcard is

    constant tClk   : time := 39.72 ns;
    constant tCoMin : time := 2 ns;

    signal weN      : std_logic := '1';
    signal expN     : std_logic := '1';
    signal q0       : std_logic := '1';
    signal slotAddr : std_logic_vector(6 downto 0) := (others => '0');
    signal dataBus  : std_logic_vector(7 downto 0) := (others => 'Z');

    signal pgPin    : std_logic_vector(7 downto 0);
    signal pgDly    : std_logic_vector(7 downto 0) := (others => '0');
    signal ramAddr  : std_logic_vector(14 downto 0);

    type ramType is array (0 to 32767) of std_logic_vector(7 downto 0);
    signal ram      : ramType := (others => x"E5");
    signal writing  : std_logic;
    signal done     : boolean := false;

begin

    dut : entity work.memcard_pld
        port map (
            weN => weN, expN => expN,
            d0 => dataBus(0), d1 => dataBus(1), d2 => dataBus(2), d3 => dataBus(3),
            d4 => dataBus(4), d5 => dataBus(5), d6 => dataBus(6), d7 => dataBus(7),
            a6 => slotAddr(6), a5 => slotAddr(5), a4 => slotAddr(4), a3 => slotAddr(3),
            pg7 => pgPin(7), pg6 => pgPin(6), pg5 => pgPin(5), pg4 => pgPin(4),
            pg3 => pgPin(3), pg2 => pgPin(2), pg1 => pgPin(1), pg0 => pgPin(0));

    pgDly   <= transport pgPin after tCoMin;
    ramAddr <= pgDly & slotAddr;

    -- AS7C256C: /CE = /EXP, /OE = Q0, /WE = /WE
    writing <= (not weN) and (not expN);

    ramWrite : process (weN)
    begin
        if rising_edge(weN) and expN = '0' then
            ram(to_integer(unsigned(ramAddr))) <= dataBus;
        end if;
    end process ramWrite;

    ramHold : process (ramAddr)
    begin
        assert writing /= '1'
            report "SRAM address moved during a write" severity failure;
    end process ramHold;

    dataBus <= ram(to_integer(unsigned(ramAddr))) after 15 ns when (expN = '0' and q0 = '0' and weN = '1')
               else (others => 'Z') after 6 ns;

    stim : process

        -- one write clock; sel = false is a write somewhere else on the board
        procedure busWrite (offset : in integer; value : in integer; sel : in boolean := true) is
        begin
            wait for 13 ns;
            slotAddr <= std_logic_vector(to_unsigned(offset, 7));
            if sel then
                expN <= '0';
            end if;
            wait for tClk / 2 - 13 ns;
            weN <= '0';
            wait for tClk / 2 - 9 ns;
            dataBus <= std_logic_vector(to_unsigned(value, 8));
            wait for 9 ns;
            weN <= '1';
            wait for 2 ns;
            dataBus <= (others => 'Z');
            expN <= '1';
            slotAddr <= (others => '0');
            wait for tClk - 2 ns;
        end procedure busWrite;

        -- one read clock (LOAD_MEM): the byte is taken at the end of the clock
        procedure busRead (offset : in integer; value : out integer) is
        begin
            wait for 6 ns;
            q0 <= '0';
            wait for 7 ns;
            slotAddr <= std_logic_vector(to_unsigned(offset, 7));
            expN <= '0';
            wait for tClk - 13 ns;
            value := to_integer(unsigned(dataBus));
            q0 <= '1';
            expN <= '1';
            wait for tClk;
        end procedure busRead;

        procedure expect (offset : in integer; value : in integer; what : in string) is
            variable got : integer;
        begin
            busRead(offset, got);
            assert got = value
                report what & ": read " & integer'image(got) & ", expected " & integer'image(value)
                severity failure;
        end procedure expect;

    begin
        wait for tClk;

        -- starts at page 0
        busWrite(0, 16#11#);
        busWrite(16#7F#, 1);                 -- page 1
        busWrite(0, 16#22#);
        expect(0, 16#22#, "page 1");
        busWrite(16#7F#, 0);                 -- page 0
        expect(0, 16#11#, "page 0 kept its byte");

        -- the page write stored its byte in the page being left
        busWrite(16#7F#, 1);
        expect(16#7F#, 0, "reserved byte of page 1");
        busWrite(16#7F#, 0);
        expect(16#7F#, 1, "reserved byte of page 0");

        -- a write somewhere else (/EXP high) with the same low address leaves the page alone
        busWrite(16#7F#, 16#55#, false);
        expect(0, 16#11#, "page after a write elsewhere");

        -- a card write just below the register (77h) is memory, not the page
        busWrite(16#77#, 16#33#);
        expect(0, 16#11#, "page after a write to 77h");
        expect(16#77#, 16#33#, "offset 77h");

        -- every register address 78h-7Fh sets the page
        for k in 16#78# to 16#7F# loop
            busWrite(k, k);
            busWrite(1, k + 1);
        end loop;
        for k in 16#78# to 16#7F# loop
            busWrite(16#7F#, k);
            expect(1, k + 1, "page set through offset " & integer'image(k));
        end loop;

        -- all 256 pages, first and last free offsets
        for p in 0 to 255 loop
            busWrite(16#7F#, p);
            busWrite(0, (p * 7 + 3) mod 256);
            busWrite(16#77#, 255 - p);
        end loop;
        for p in 255 downto 0 loop
            busWrite(16#7F#, p);
            expect(0, (p * 7 + 3) mod 256, "page " & integer'image(p) & " offset 0");
            expect(16#77#, 255 - p, "page " & integer'image(p) & " offset 77h");
        end loop;

        report "tb_memcard: all checks passed" severity note;
        done <= true;
        wait;
    end process stim;

end architecture sim;
