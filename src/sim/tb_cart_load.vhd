-- ============================================================
-- tb_cart_load: the ROM cartridge loader (cart_pld) against a timed
-- model of the main board
-- Date: 10/20/2026
--
-- The cartridge PLD and the memory control PLD are the real VHDL; the
-- rest of the board is a behavioural model with the delays from
-- docs/TIMING.md:
--   CLK       = OSC or HOLD through a 74AC32 (5 ns); the cartridge
--             PLD's outputs come 7 ns after OSC (-10 grade tCO) and
--             its inputs must be steady 7 ns before OSC rises
--   CPU       FETCH / EXEC state machine for 02h (ld ac, ac); the PC
--             and the address mux settle 21 ns after the edge, /SRC_EN
--             13 ns after it; a video read (PIXEL_ENABLE) every 8th
--             board clock stalls the CPU and puts a video address on
--             the bus
--   EEPROM    AT28C256-15: tACC 150, tOE 70, tDF 50 ns
--   SRAM      AS7C256C-15: tOE 7 ns; a write checks the address is
--             steady through /WE low, the pulse is 10 ns or more and
--             the data is settled 7 ns before /WE rises
--   74AC541   02h, 8 ns on and off
--   F541      the source buffer in EXEC, 9.5 ns on, 6.5 ns off
--   RAM       video reads, 7 ns on and off
--
-- Checks: every CPU fetch while loading reads 02h; no two drivers on
-- the data bus overlap by more than 8 ns (the board already accepts
-- up to about 7 ns at the start of EXEC); after the hand-off the CPU
-- fetches x0000 from the SRAM; the SRAM holds the whole image.
--
-- Run (from the repository root):
--   ghdl -a --std=08 src/hdl/cart_pld.vhd src/hdl/mem_ctrl_pld.vhd src/sim/tb_cart_load.vhd
--   ghdl -e --std=08 tb_cart_load
--   ghdl -r --std=08 tb_cart_load
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cart_load is
end entity tb_cart_load;

architecture sim of tb_cart_load is

    constant OSC_PERIOD : time := 39.72 ns;

    type memType is array (0 to 65535) of std_logic_vector(7 downto 0);

    function imageByte(a : natural) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned((a * 7 + (a / 256) * 13 + 5) mod 256, 8));
    end function;

    signal osc          : std_logic := '0';
    signal clk          : std_logic := '1';
    signal hold         : std_logic := '1';
    signal run          : std_logic;
    signal eeOeN        : std_logic;
    signal srWeN        : std_logic;
    signal bufOeN       : std_logic;
    signal holdQ        : std_logic;
    signal runQ         : std_logic;
    signal eeOeNQ       : std_logic;
    signal srWeNQ       : std_logic;
    signal bufOeNQ      : std_logic;

    signal addr         : std_logic_vector(15 downto 0) := x"0000";
    signal pixelEnable  : std_logic := '0';
    signal srcEnN       : std_logic := '1';
    signal romOeN       : std_logic;
    signal ramOeN       : std_logic;
    signal weN          : std_logic;

    signal dataBus      : std_logic_vector(7 downto 0) := (others => 'Z');

    -- driver enables (after their turn-on and turn-off delays)
    signal eeOn         : std_logic := '0';
    signal bufOn        : std_logic := '0';
    signal sramOn       : std_logic := '0';
    signal srcOn        : std_logic := '0';
    signal ramOn        : std_logic := '0';
    signal eeAddrOkS    : std_logic := '1';   -- the address has been steady since power-up
    signal eeOeOkS      : std_logic := '0';

    signal sram         : memType := (others => x"FF");
    signal done         : boolean := false;
    signal handedOff    : boolean := false;
    signal addrChanged  : time := 0 ns;
    signal busChanged   : time := 0 ns;

begin

    osc <= not osc after OSC_PERIOD / 2 when not done;

    clk <= (osc or hold) after 5 ns;

    cartComp : entity work.cart_pld
    port map (
        osc         => osc,
        a15         => addr(15),
        pixelEnable => pixelEnable,
        srcEnN      => srcEnN,
        cnt0        => open,
        cnt1        => open,
        cnt2        => open,
        cnt3        => open,
        prev15      => open,
        srWeN       => srWeNQ,
        eeOeN       => eeOeNQ,
        bufOeN      => bufOeNQ,
        run         => runQ,
        hold        => holdQ
    );

    -- ATF22V10C-10 clock to output
    srWeN  <= srWeNQ after 7 ns;
    eeOeN  <= eeOeNQ after 7 ns;
    bufOeN <= bufOeNQ after 7 ns;
    run    <= runQ after 7 ns;
    hold   <= holdQ after 7 ns;

    -- ATF22V10C-10 input setup: the inputs must be steady 7 ns before OSC rises
    setupCheck : process
        variable lastChange : time := 0 ns;
    begin
        wait on osc, addr(15), pixelEnable, srcEnN;
        if addr(15)'event or pixelEnable'event or srcEnN'event then
            lastChange := now;
        elsif rising_edge(osc) and now > 0 ns then
            assert now - lastChange >= 7 ns or lastChange = 0 ns
                report "cartridge PLD input changed " & time'image(now - lastChange) & " before OSC"
                severity failure;
        end if;
    end process setupCheck;

    -- the map register is held clear (all ROM) while run is low, and
    -- the boot has not written it yet when the CPU starts
    memCtrlComp : entity work.mem_ctrl_pld
    port map (
        clk         => clk,
        a15         => addr(15),
        a14         => addr(14),
        a13         => addr(13),
        a12         => addr(12),
        ramsel0     => '0',
        ramsel1     => '0',
        ramsel3     => '0',
        ramsel4     => '0',
        ramsel5     => '0',
        ramsel6     => '0',
        ramsel7     => '0',
        ramsel2     => '0',
        rw          => '1',
        pixelEnable => pixelEnable,
        a11         => addr(11),
        a10         => addr(10),
        srcEnN      => srcEnN,
        run         => run,
        weN         => weN,
        romOeN      => romOeN,
        ramOeN      => ramOeN
    );

    -- ---------------- CPU, video and address mux ----------------

    cpuProc : process
        variable pc       : natural := 0;
        variable inExec   : boolean := false;
        variable boardClk : natural := 0;
        variable pix      : std_logic := '0';
        variable fetches  : natural := 0;
        variable afterRun : natural := 0;
    begin
        wait until rising_edge(clk);
        -- the clock that just ended
        if pix = '0' then
            if not inExec then
                -- FETCH: the IR and the State PLD take the bus
                if run = '0' then
                    assert dataBus = x"02"
                        report "fetch at " & to_hstring(to_unsigned(pc, 16)) & " read "
                               & to_hstring(dataBus) & ", not 02h" severity failure;
                    fetches := fetches + 1;
                else
                    -- first fetch from the SRAM after the hand-off
                    assert pc = 0
                        report "hand-off fetch at " & to_hstring(to_unsigned(pc, 16)) severity failure;
                    assert dataBus = imageByte(0)
                        report "hand-off fetch read " & to_hstring(dataBus) severity failure;
                    report "hand-off at " & time'image(now) & " after " & integer'image(fetches)
                           & " fetches; first instruction from the SRAM read correctly";
                    handedOff <= true;
                    afterRun := afterRun + 1;
                end if;
                pc := (pc + 1) mod 65536;
                inExec := true;
            else
                inExec := false;
            end if;
        end if;
        if handedOff then
            done <= true;
            wait;
        end if;

        -- the clock that starts now
        boardClk := boardClk + 1;
        if boardClk mod 8 = 1 then
            pix := '1';
        else
            pix := '0';
        end if;
        pixelEnable <= pix after 5.5 ns;
        if inExec and pix = '0' then
            srcEnN <= '0' after 13 ns;
        else
            srcEnN <= '1' after 13 ns;
        end if;
        if pix = '1' then
            addr <= std_logic_vector(to_unsigned((boardClk * 37 + 4096) mod 65536, 16)) after 13 ns;
        elsif inExec then
            addr <= x"0042" after 21 ns;     -- whatever the EXEC addresses
        else
            addr <= std_logic_vector(to_unsigned(pc, 16)) after 21 ns;
        end if;
    end process cpuProc;

    addrTime : process
    begin
        wait on addr;
        addrChanged <= now;
    end process addrTime;
    busTime : process
    begin
        wait on dataBus;
        busChanged <= now;
    end process busTime;

    -- ---------------- bus drivers ----------------

    -- EEPROM (AT28C256-15): low-Z from /OE, data after tACC / tOE, off tDF after /OE
    eeOn <= '1' when eeOeN = '0' else '0' after 50 ns;
    eeAddrOk : process
    begin
        wait on addr;
        eeAddrOkS <= '0', '1' after 150 ns;
    end process eeAddrOk;
    eeOeOkS <= '1' after 70 ns when eeOeN = '0' else '0';
    dataBus <= imageByte(to_integer(unsigned(addr))) when eeOn = '1' and eeAddrOkS = '1' and eeOeOkS = '1'
          else (others => 'X') when eeOn = '1'
          else (others => 'Z');

    -- 74AC541, inputs wired to 02h
    bufOn <= not bufOeN after 8 ns;
    dataBus <= x"02" when bufOn = '1' else (others => 'Z');

    -- cartridge SRAM (AS7C256C-15): reads on /ROM_OE
    sramOn <= not romOeN after 7 ns;
    dataBus <= sram(to_integer(unsigned(addr))) when sramOn = '1' else (others => 'Z');

    -- source F541 in EXEC
    srcOn <= '1' after 9.5 ns when srcEnN = '0' else '0' after 6.5 ns;
    dataBus <= x"5A" when srcOn = '1' else (others => 'Z');

    -- main RAM on video reads
    ramOn <= not ramOeN after 7 ns;
    dataBus <= x"C3" when ramOn = '1' else (others => 'Z');

    -- ---------------- SRAM write ----------------

    sramWrite : process
        variable fell   : time;
        variable a      : std_logic_vector(15 downto 0);
    begin
        wait until falling_edge(srWeN);
        fell := now;
        a := addr;
        wait until rising_edge(srWeN);
        assert addr = a and addrChanged <= fell
            report "SRAM address changed during /WE" severity failure;
        assert now - fell >= 10 ns
            report "SRAM write pulse too short" severity failure;
        assert now - busChanged >= 7 ns and not is_x(dataBus)
            report "SRAM write data not settled at " & to_hstring(a) severity failure;
        sram(to_integer(unsigned(a))) <= dataBus;
    end process sramWrite;

    -- ---------------- contention ----------------

    contention : process
        variable n        : natural;
        variable since    : time := 0 ns;
        variable longest  : time := 0 ns;
        variable inside   : boolean := false;
    begin
        wait on eeOn, bufOn, sramOn, srcOn, ramOn, done;
        if done then
            report "longest bus overlap: " & time'image(longest);
            wait;
        end if;
        n := 0;
        if eeOn = '1' then n := n + 1; end if;
        if bufOn = '1' then n := n + 1; end if;
        if sramOn = '1' then n := n + 1; end if;
        if srcOn = '1' then n := n + 1; end if;
        if ramOn = '1' then n := n + 1; end if;
        if n > 1 and not inside then
            inside := true;
            since := now;
        elsif n <= 1 and inside then
            inside := false;
            if now - since > longest then
                longest := now - since;
            end if;
            assert now - since <= 8 ns
                report "bus contention for " & time'image(now - since) & " ending at " & time'image(now)
                severity failure;
        end if;
    end process contention;

    -- ---------------- result ----------------

    check : process
        variable bad : natural := 0;
    begin
        wait until done;
        for a in 0 to 65535 loop
            if sram(a) /= imageByte(a) then
                if bad < 5 then
                    report "SRAM " & to_hstring(to_unsigned(a, 16)) & " = " & to_hstring(sram(a))
                           & ", image " & to_hstring(imageByte(a)) severity error;
                end if;
                bad := bad + 1;
            end if;
        end loop;
        assert bad = 0 report integer'image(bad) & " SRAM bytes wrong" severity failure;
        report "PASS: all 65536 bytes loaded, load time " & time'image(now);
        wait;
    end process check;

end architecture sim;
