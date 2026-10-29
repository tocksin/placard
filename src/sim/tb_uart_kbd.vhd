-- ============================================================
-- tb_uart_kbd: the PC-terminal keyboard (uart_ps2_kbd.vhd) on its own
-- Date: 10/27/2026
--
-- A 1 MHz clock and 100,000 baud (10 clocks a bit) keep it quick; the
-- FIFO is 64 characters (FIFO_BITS = 6: XOFF at 48 waiting, XON at 16).
--   1. "aB" is typed: expect the PS/2 bytes 1C F0 1C 12 32 F0 32 F0 12,
--      the B's make code 20 ms (the hold) or more after the a's, and the
--      echo 61 42.
--   2. 60 characters "0".."9" sent back to back at full speed: expect
--      XOFF (13) on the echo line once 48 are waiting, every character
--      typed in order, and XON (11) once the FIFO is down to 16.
-- The host never holds the clock (hostHold = 0).
--
-- GHDL:
--   ghdl -i --std=08 src/hdl/uart_ps2_kbd.vhd src/sim/tb_uart_kbd.vhd
--   ghdl -m --std=08 tb_uart_kbd
--   ghdl -r --std=08 tb_uart_kbd
-- (under a minute).  It ends with "tb_uart_kbd: PASS".
-- ============================================================

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_uart_kbd is end;
architecture s of tb_uart_kbd is
    constant CLK_HZ : natural := 1000000;
    constant BIT_T  : time := 10 us;
    signal clk        : std_logic := '0';
    signal rxIn       : std_logic := '1';
    signal kbdClkLow  : std_logic;
    signal kbdDataLow : std_logic;
    signal txOut      : std_logic;
    signal done       : boolean := false;

    type byteList is array (natural range <>) of std_logic_vector(7 downto 0);
    signal ps2Bytes   : byteList(0 to 1023);
    signal ps2Count   : natural := 0;
    signal makeAt     : time := 0 ns;              -- when the B's make code came
    signal aMakeAt    : time := 0 ns;
    signal txBytes    : byteList(0 to 1023);
    signal txCount    : natural := 0;
    signal xoffAt     : integer := -1;             -- PS/2 bytes in when XOFF / XON came
    signal xonAt      : integer := -1;
    signal sentChars  : natural := 0;
begin
    clk <= not clk after 500 ns when not done;

    dut : entity work.uart_ps2_kbd
    generic map (CLK_HZ => CLK_HZ, BAUD => 100000, FIFO_BITS => 6)
    port map (
        clk => clk, rxIn => rxIn, hostHold => '0',
        kbdClkLow => kbdClkLow, kbdDataLow => kbdDataLow, txOut => txOut,
        rxToggle => open, dbgTaken => open, dbgSent => open);

    -- the PS/2 host: a bit is read while CLK is low
    ps2Rx : process
        variable frame : std_logic_vector(10 downto 0);
    begin
        loop
            for i in 0 to 10 loop
                wait until rising_edge(kbdClkLow);
                frame(i) := not kbdDataLow;
            end loop;
            assert frame(0) = '0' and frame(10) = '1' report "PS/2 frame error" severity failure;
            assert (frame(1) xor frame(2) xor frame(3) xor frame(4) xor frame(5) xor frame(6)
                    xor frame(7) xor frame(8) xor frame(9)) = '1' report "PS/2 parity" severity failure;
            ps2Bytes(ps2Count) <= frame(8 downto 1);
            if ps2Count = 0 then aMakeAt <= now; end if;
            if ps2Count = 4 then makeAt <= now; end if;
            ps2Count <= ps2Count + 1;
        end loop;
    end process;

    -- the PC's receiver: the echo and the flow control
    pcRx : process
        variable b : std_logic_vector(7 downto 0);
    begin
        loop
            wait until falling_edge(txOut);
            wait for BIT_T * 1.5;
            for i in 0 to 7 loop
                b(i) := txOut;
                wait for BIT_T;
            end loop;
            assert txOut = '1' report "echo stop bit" severity failure;
            txBytes(txCount) <= b;
            txCount <= txCount + 1;
            if b = x"13" then xoffAt <= sentChars; end if;
            if b = x"11" then xonAt <= ps2Count; end if;
        end loop;
    end process;

    stim : process
        procedure send(c : std_logic_vector(7 downto 0)) is
        begin
            rxIn <= '0'; wait for BIT_T;
            for i in 0 to 7 loop rxIn <= c(i); wait for BIT_T; end loop;
            rxIn <= '1'; wait for BIT_T;
            sentChars <= sentChars + 1;
        end procedure;
        constant WANT1 : byteList := (x"1C", x"F0", x"1C", x"12", x"32", x"F0", x"32", x"F0", x"12");
        constant DIGIT : byteList(0 to 9) := (x"45", x"16", x"1E", x"26", x"25", x"2E", x"36", x"3D", x"3E", x"46");
        variable ok : boolean := true;
        variable n0, t0 : natural;
    begin
        wait for 100 us;
        send(x"61"); send(x"42");
        wait for 100 ms;
        for i in WANT1'range loop
            if ps2Bytes(i) /= WANT1(i) then
                report "1: PS/2 byte " & integer'image(i) & " = " & to_hstring(ps2Bytes(i)) severity error;
                ok := false;
            end if;
        end loop;
        assert ps2Count = 9 report "1: PS/2 bytes " & integer'image(ps2Count) severity error;
        report "1: a to B make " & integer'image((makeAt - aMakeAt) / 1 us) & " us";
        if makeAt - aMakeAt < 20 ms then ok := false; report "1: hold too short" severity error; end if;
        if txCount /= 2 or txBytes(0) /= x"61" or txBytes(1) /= x"42" then
            ok := false; report "1: echo" severity error;
        end if;

        -- 2: a flood
        n0 := ps2Count; t0 := txCount;
        for i in 0 to 59 loop
            send(std_logic_vector(to_unsigned(16#30# + i mod 10, 8)));
        end loop;
        wait until ps2Count = n0 + 180 for 3000 ms;
        wait for 1 ms;
        report "2: XOFF after " & integer'image(xoffAt - 2) & " characters sent, XON after "
               & integer'image((xonAt - n0) / 3) & " typed";
        if xoffAt < 0 or xonAt < 0 then ok := false; report "2: no XOFF or XON" severity error; end if;
        for i in 0 to 59 loop
            if ps2Bytes(n0 + 3 * i) /= DIGIT(i mod 10) or ps2Bytes(n0 + 3 * i + 1) /= x"F0"
               or ps2Bytes(n0 + 3 * i + 2) /= DIGIT(i mod 10) then
                ok := false;
                report "2: character " & integer'image(i) & " wrong" severity error;
            end if;
        end loop;
        if ps2Count /= n0 + 180 then
            ok := false; report "2: PS/2 bytes " & integer'image(ps2Count - n0) severity error;
        end if;
        -- the echo: the 60 digits in order, with XOFF and XON among them
        n0 := 0;
        for i in t0 to txCount - 1 loop
            if txBytes(i) /= x"11" and txBytes(i) /= x"13" then
                if txBytes(i) /= std_logic_vector(to_unsigned(16#30# + n0 mod 10, 8)) then
                    ok := false; report "2: echo " & integer'image(n0) & " wrong" severity error;
                end if;
                n0 := n0 + 1;
            end if;
        end loop;
        if n0 /= 60 then ok := false; report "2: echoed " & integer'image(n0) severity error; end if;

        if ok then report "tb_uart_kbd: PASS"; else report "tb_uart_kbd: FAIL" severity failure; end if;
        done <= true;
        wait;
    end process;
end;
