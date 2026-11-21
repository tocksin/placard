-- ============================================================
-- tb_wifi: the WiFi card's SPI port PLD (wifi_pld, revision 01) on
-- a timed slot, with an SPI slave that echoes
-- Date: 11/21/2026
--
-- The PLD is the real VHDL (zero delay inside; its pins D7:D2 are on
-- the bus directly, D3 and D2 both ways, and its register pins get
-- the ATF22V10C-7 clock-to-output time here, 5.5 ns).  The slot is the behavioural
-- model of tb_memcard.vhd, with the times of
-- docs/architecture/EXPANSION.md "Card timing" in a 39.72 ns clock:
--   address, /EXP   valid 13 ns into the clock, held 2 ns past /WE
--   /WE             low from the middle of a write clock to its end
--   write data      valid 9 ns before /WE rises, held 2 ns after
--   Q0              low in a read clock, 6 ns in
-- The bus has pull-ups (an undriven line reads 1).  The module is a
-- small SPI slave, mode 3: it takes MOSI on each rising SCK while
-- /CS is low and answers each byte with the byte before it,
-- complemented (the first with 5Ah); MISO and READY have pull-downs.
--
-- Checked: the power-up state (SCK, MOSI, /CS high, reset free);
-- the fixed bits of the two read addresses, and that nothing is
-- driven below offset 60h; the register loads only on a write to
-- 60h-7Fh (not below, not with /EXP high) and bits 7:4 are ignored;
-- the reset pin pulls low only while bit 3 is 0; READY reads on D6;
-- bytes clocked the way the driver does it come back right; the bus
-- is free again once Q0 rises.
--
--   ghdl -a --std=08 src/hdl/wifi_pld.vhd src/sim/tb_wifi.vhd
--   ghdl -e --std=08 tb_wifi && ghdl -r --std=08 tb_wifi
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_wifi is
end entity tb_wifi;

architecture sim of tb_wifi is

    constant tClk : time := 39.72 ns;
    constant tCo  : time := 5.5 ns;

    signal weN      : std_logic := '1';
    signal expN     : std_logic := '1';
    signal q0       : std_logic := '1';
    signal slotAddr : std_logic_vector(6 downto 0) := (others => '0');
    signal dataBus  : std_logic_vector(7 downto 0) := (others => 'H');   -- pull-ups

    signal sckPin, mosiPin, csPin : std_logic;
    signal sck, mosi, csN         : std_logic := '1';
    signal mrstN    : std_logic;
    signal rstLine  : std_logic;
    signal miso     : std_logic := 'L';
    signal ready    : std_logic := 'L';
    signal readyDrv : std_logic := 'Z';
    signal misoIn   : std_logic;
    signal readyIn  : std_logic;

    signal slaveRx  : std_logic_vector(7 downto 0) := x"00";
    signal slaveGot : integer := -1;
    signal done     : boolean := false;

begin

    dataBus <= (others => 'H');

    dut : entity work.wifi_pld
        port map (
            weN => weN, expN => expN, q0 => q0,
            a0 => slotAddr(0), a5 => slotAddr(5), a6 => slotAddr(6),
            d0 => dataBus(0), d1 => dataBus(1),
            miso => misoIn, ready => readyIn,
            sck => sckPin, mosi => mosiPin, csN => csPin, mrstN => mrstN,
            d2 => dataBus(2), d3 => dataBus(3), d4 => dataBus(4), d5 => dataBus(5), d6 => dataBus(6), d7 => dataBus(7));

    sck  <= transport sckPin after tCo;
    mosi <= transport mosiPin after tCo;
    csN  <= transport csPin after tCo;

    misoIn  <= to_x01(miso);        -- the PLD's inputs see a level, its outputs drive one
    readyIn <= to_x01(ready);
    rstLine <= 'H';                 -- the module's own pull-up
    rstLine <= mrstN;
    miso    <= 'L';                 -- 10k to ground
    ready   <= 'L';
    ready   <= readyDrv;

    -- the SPI slave, mode 3: shifts MOSI in on rising SCK, changes MISO on falling SCK
    slave : process (sck, csN)
        variable sh    : std_logic_vector(7 downto 0);
        variable tx    : std_logic_vector(7 downto 0);
        variable n     : integer := 0;
    begin
        if csN = '1' then
            n := 0;
            tx := x"5A";
            miso <= 'Z';
        elsif falling_edge(sck) then
            miso <= tx(7);
            tx := tx(6 downto 0) & '0';
        elsif rising_edge(sck) then
            sh := sh(6 downto 0) & to_x01(mosi);
            n := n + 1;
            if n = 8 then
                n := 0;
                slaveRx <= sh;
                slaveGot <= to_integer(unsigned(sh));
                tx := not sh;
            end if;
        end if;
    end process slave;

    stim : process

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

        procedure busRead (offset : in integer; value : out integer) is
        begin
            wait for 6 ns;
            q0 <= '0';
            wait for 7 ns;
            slotAddr <= std_logic_vector(to_unsigned(offset, 7));
            expN <= '0';
            wait for tClk - 13 ns;
            value := to_integer(unsigned(to_x01(dataBus)));
            q0 <= '1';
            expN <= '1';
            wait for 0.1 ns;
            assert to_x01(dataBus) = x"FF" report "bus still driven after a read" severity failure;
            wait for tClk - 0.1 ns;
        end procedure busRead;

        procedure expect (offset : in integer; mask : in integer; value : in integer; what : in string) is
            variable got : integer;
        begin
            busRead(offset, got);
            got := to_integer(unsigned(std_logic_vector(to_unsigned(got, 8)) and std_logic_vector(to_unsigned(mask, 8))));
            assert got = value
                report what & ": read " & integer'image(got) & ", expected " & integer'image(value)
                severity failure;
        end procedure expect;

        -- one byte the way wf_byte does it: /CS low, run bit high, SCK low with the bit, SCK high, read D7
        procedure spiByte (txByte : in integer; rxByte : out integer) is
            variable t   : std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(txByte, 8));
            variable r   : std_logic_vector(7 downto 0);
            variable got : integer;
        begin
            for i in 7 downto 0 loop
                if t(i) = '1' then
                    busWrite(16#60#, 16#0A#);
                    busWrite(16#60#, 16#0B#);
                else
                    busWrite(16#60#, 16#08#);
                    busWrite(16#60#, 16#09#);
                end if;
                busRead(16#60#, got);
                if got >= 128 then r(i) := '1'; else r(i) := '0'; end if;
            end loop;
            rxByte := to_integer(unsigned(r));
        end procedure spiByte;

        variable got : integer;
    begin
        wait for tClk;

        -- power-up: SCK, MOSI and /CS high, the reset pin off
        assert sck = '1' and mosi = '1' and csN = '1' report "power-up pins" severity failure;
        assert mrstN = 'Z' and to_x01(rstLine) = '1' report "reset pin at power-up" severity failure;

        -- the two read addresses: D5:D2 fixed, D7 and D6 low from the pull-downs, D1:D0 not driven
        expect(16#60#, 16#FF#, 16#2B#, "even read");
        expect(16#61#, 16#FF#, 16#17#, "odd read");
        expect(16#7E#, 16#FC#, 16#28#, "even read at 7Eh");
        expect(16#7F#, 16#FC#, 16#14#, "odd read at 7Fh");
        -- nothing below 60h
        expect(16#00#, 16#FF#, 16#FF#, "read at 00h");
        expect(16#5F#, 16#FF#, 16#FF#, "read at 5Fh");
        expect(16#40#, 16#FF#, 16#FF#, "read at 40h");
        expect(16#20#, 16#FF#, 16#FF#, "read at 20h");

        -- READY on D6
        readyDrv <= '1';
        expect(16#60#, 16#C0#, 16#40#, "READY high");
        readyDrv <= 'Z';
        expect(16#60#, 16#C0#, 16#00#, "READY low");

        -- the register: each bit to its pin; bits 7:4 ignored
        busWrite(16#60#, 16#FE#);
        wait for tCo;
        assert sck = '0' and mosi = '1' and csN = '1' and mrstN = 'Z' report "write FEh" severity failure;
        busWrite(16#7F#, 16#0D#);
        wait for tCo;
        assert sck = '1' and mosi = '0' and csN = '1' and mrstN = 'Z' report "write 0Dh" severity failure;
        busWrite(16#60#, 16#0B#);
        wait for tCo;
        assert sck = '1' and mosi = '1' and csN = '0' and mrstN = 'Z' report "write 0Bh" severity failure;
        busWrite(16#60#, 16#07#);
        wait for tCo;
        assert sck = '1' and mosi = '1' and csN = '1' and mrstN = '0' and to_x01(rstLine) = '0'
            report "write 07h: reset low" severity failure;

        -- writes that are not the card's registers leave it alone
        busWrite(16#5F#, 16#00#);
        busWrite(16#00#, 16#00#);
        busWrite(16#60#, 16#00#, false);
        wait for tCo;
        assert sck = '1' and mosi = '1' and csN = '1' and mrstN = '0' report "writes elsewhere" severity failure;
        busWrite(16#60#, 16#0F#);
        wait for tCo;
        assert mrstN = 'Z' and to_x01(rstLine) = '1' report "reset released" severity failure;

        -- bytes through the SPI slave
        busWrite(16#60#, 16#0B#);            -- /CS low, SCK high
        spiByte(16#C3#, got);
        assert slaveGot = 16#C3# report "slave got " & integer'image(slaveGot) severity failure;
        assert got = 16#5A# report "first byte back " & integer'image(got) severity failure;
        spiByte(16#00#, got);
        assert got = 16#3C# report "second byte back " & integer'image(got) severity failure;
        spiByte(16#FF#, got);
        assert slaveGot = 16#FF# and got = 16#FF# report "third byte" severity failure;
        spiByte(16#81#, got);
        assert slaveGot = 16#81# and got = 16#00# report "fourth byte" severity failure;
        busWrite(16#60#, 16#0F#);            -- /CS high
        expect(16#60#, 16#80#, 16#00#, "MISO off after /CS");

        report "tb_wifi: all checks passed" severity note;
        done <= true;
        wait;
    end process stim;

end architecture sim;
