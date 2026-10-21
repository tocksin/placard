-- ============================================================
-- tb_cart_load: the ROM cartridge loader (cart_pld revision 04)
-- against a timed model of the main board
-- Date: 10/21/2026
--
-- The cartridge PLD, the instruction register PLD, the State PLD,
-- the Branch PLD and the memory control PLD are the real VHDL; the
-- rest of the board is a behavioural model with the delays from
-- docs/TIMING.md (ATF22V10C-7: tCO 5.5 ns, tPD 7.5 ns; the PLD
-- models are zero-delay, so each output gets its delay here, 10 ns
-- for an output that can change from a register inside the chip):
--   clock     free-running 25.175 MHz, no gate
--   Sync      a video read (PIXEL_ENABLE) in the last clock of an
--             8-clock group: in the first 80 groups of each line
--             and groups 90-92, and only 90-92 on the 45 blank
--             lines; it is registered (5.5 ns)
--   mux       the address is settled 15 ns after the Sync and State
--             outputs that pick it (20.5 ns after the edge)
--   PC        counts at the edge when PC_ENABLE is high and STALL
--             is low; D loads on /LOAD_IMM (F377, 10.5 ns)
--   I/O       a read of x5000-x53FF while /LOAD_IMM is low drives
--             the bus (I/O decode 7.5 ns, F541 9.5 ns on, 6.5 off)
--   EEPROM    AT28C256-15: tACC 150 ns (+7.5 for /CE_HI after A15),
--             tOE 70 ns, tDF 50 ns (the byte stays until it floats)
--   SRAM      AS7C256C-15: tOE 7 ns; a write checks the address is
--             steady through /WE low, the pulse is 10 ns or more and
--             the data is settled 7 ns before /WE rises
--   F541      the source buffer in EXEC, 9.5 ns on, 6.5 ns off
--   RAM       video reads, 7 ns on and off
--   the bus   keeps its last value when nothing drives it (the 10k
--             pull-ups take microseconds)
--
-- Checks: the cartridge PLD's and the State PLD's inputs are steady
-- 3.5 ns before the edge; the IR is 02h in every EXEC while loading;
-- nothing writes; no two drivers on the data bus overlap by more
-- than 3 ns; after the hand-off the CPU's first fetch from the SRAM
-- is at x0000 or x0001 (x0000 holds 02h); the SRAM holds the whole
-- image.  SEED picks the image (the bytes steer the State PLD, so
-- each image walks the 64K differently).
--
-- Run (from the repository root):
--   ghdl -a --std=08 src/hdl/cart_pld.vhd src/hdl/ir_pld.vhd src/hdl/state_pld.vhd \
--       src/hdl/branch_pld.vhd src/hdl/mem_ctrl_pld.vhd src/sim/tb_cart_load.vhd
--   ghdl -e --std=08 tb_cart_load
--   ghdl -r --std=08 tb_cart_load [-gSEED=2]
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_cart_load is
    generic (
        SEED : natural := 1
    );
end entity tb_cart_load;

architecture sim of tb_cart_load is

    constant CLK_PERIOD : time := 39.72 ns;
    constant T_CO       : time := 5.5 ns;    -- ATF22V10C-7 clock to output
    constant T_PD       : time := 7.5 ns;    -- ATF22V10C-7 input to output
    constant T_REG_PD   : time := 10 ns;     -- clock to a combinational output (tCF + tPD)
    constant T_SETUP    : time := 3.5 ns;

    type memType is array (0 to 65535) of std_logic_vector(7 downto 0);

    function imageByte(a : natural) return std_logic_vector is
    begin
        if a = 0 then
            return x"02";    -- the image keeps a nop at x0000 (ATF22V10_CART.pld, HAND-OFF)
        end if;
        return std_logic_vector(to_unsigned((a * 7 + (a / 256) * 13 + SEED * 101 + (a / 4093) * SEED) mod 256, 8));
    end function;

    signal clk          : std_logic := '0';
    signal done         : boolean := false;
    signal handedOff    : boolean := false;

    -- cartridge PLD
    signal runQ         : std_logic;
    signal srWeNQ       : std_logic;
    signal eeOeNQ       : std_logic;
    signal stallOutQ    : std_logic;
    signal run          : std_logic := '0';
    signal srWeN        : std_logic := '1';
    signal eeOeN        : std_logic := '1';
    signal stallOut     : std_logic := '1';

    -- instruction register PLD
    signal irQ          : std_logic_vector(7 downto 0);
    signal ir           : std_logic_vector(7 downto 0) := x"00";

    -- State PLD
    signal q0Q          : std_logic;
    signal pcEnableQ    : std_logic;
    signal xEnableQ     : std_logic;
    signal yEnableQ     : std_logic;
    signal loadInstrNQ  : std_logic;
    signal loadImmNQ    : std_logic;
    signal memRwQ       : std_logic;
    signal q0           : std_logic := '0';
    signal pcEnable     : std_logic := '1';
    signal xEnable      : std_logic := '0';
    signal yEnable      : std_logic := '0';
    signal loadInstrN   : std_logic := '1';
    signal loadImmN     : std_logic := '1';
    signal memRw        : std_logic := '1';

    -- Branch PLD
    signal stallInQ     : std_logic;
    signal srcEnNQ      : std_logic;
    signal branchBlockQ : std_logic;
    signal stallIn      : std_logic := '0';
    signal srcEnN       : std_logic := '1';
    signal branchBlock  : std_logic := '0';

    -- memory control PLD
    signal weNQ         : std_logic;
    signal romOeNQ      : std_logic;
    signal ramOeNQ      : std_logic;
    signal weN          : std_logic := '1';
    signal romOeN       : std_logic := '1';
    signal ramOeN       : std_logic := '1';

    -- the rest of the board
    signal pixelEnable  : std_logic := '0';
    signal pc           : natural := 0;
    signal pcOut        : natural := 0;
    signal dReg         : std_logic_vector(7 downto 0) := x"00";
    signal dOut         : std_logic_vector(7 downto 0) := x"00";
    signal videoAddr    : std_logic_vector(15 downto 0) := x"0000";
    signal addr         : std_logic_vector(15 downto 0) := x"0000";
    constant X_REG      : std_logic_vector(7 downto 0) := x"37";
    constant Y_REG      : std_logic_vector(7 downto 0) := x"52";   -- [Y,X] reads land in the port page
    signal ioRd         : std_logic := '0';
    signal ioRdD        : std_logic := '0';

    signal dataBus      : std_logic_vector(7 downto 0) := (others => 'Z');
    signal db           : std_logic_vector(7 downto 0) := x"FF";   -- as the PLD inputs see it
    signal keep         : std_logic_vector(7 downto 0) := (others => 'H');

    -- driver enables (after their turn-on and turn-off delays)
    signal eeOn         : std_logic := '0';
    signal sramOn       : std_logic := '0';
    signal srcOn        : std_logic := '0';
    signal ramOn        : std_logic := '0';
    signal ioOn         : std_logic := '0';
    signal eeAddrOkS    : std_logic := '1';
    signal eeOeOkS      : std_logic := '0';

    signal sram         : memType := (others => x"FF");
    signal addrChanged  : time := 0 ns;
    signal busChanged   : time := 0 ns;

begin

    clk <= not clk after CLK_PERIOD / 2 when not done;

    -- An X (the EEPROM's data after its /OE rises, tOH = 0) still sits
    -- at some logic level on the bus: the PLDs see a pseudo-random one.
    -- Any value is fine there, because the PC steps by one in FETCH and
    -- LOAD_IMM whatever the State PLD decides (ATF22V10_CART.pld).
    dbProc : process (dataBus, clk)
        variable r : natural := 12345 + SEED;
    begin
        r := (r * 75 + 74) mod 65537;
        for i in 0 to 7 loop
            if to_X01(dataBus(i)) = 'X' then
                if (r / (2 ** (i + 4))) mod 2 = 1 then
                    db(i) <= '1';
                else
                    db(i) <= '0';
                end if;
            else
                db(i) <= to_X01(dataBus(i));
            end if;
        end loop;
    end process dbProc;

    -- ---------------- the real PLD equations ----------------

    cartComp : entity work.cart_pld
    port map (
        clk         => clk,
        a15         => addr(15),
        pixelEnable => pixelEnable,
        pcEnable    => pcEnable,
        stallIn     => stallIn,
        g0          => open,
        g1          => open,
        g2          => open,
        copy        => open,
        prev15      => open,
        srWeN       => srWeNQ,
        eeOeN       => eeOeNQ,
        synced      => open,
        run         => runQ,
        stallOut    => stallOutQ
    );
    run      <= runQ after T_CO;
    srWeN    <= srWeNQ after T_CO;
    eeOeN    <= eeOeNQ after T_CO;
    stallOut <= transport stallOutQ after T_REG_PD + 1 ns;   -- + the connector, both ways

    irComp : entity work.ir_pld
    port map (
        clk          => clk,
        d0           => db(0),
        d1           => db(1),
        d2           => db(2),
        d3           => db(3),
        d4           => db(4),
        d5           => db(5),
        d6           => db(6),
        d7           => db(7),
        load_instr_n => loadInstrN,
        run          => run,
        i0           => irQ(0),
        i1           => irQ(1),
        i2           => irQ(2),
        i3           => irQ(3),
        i4           => irQ(4),
        i5           => irQ(5),
        i6           => irQ(6),
        i7           => irQ(7)
    );
    ir <= irQ after T_CO;

    stateComp : entity work.state_pld
    port map (
        clk          => clk,
        pixel_enable => stallOut,
        db_src1      => db(1),
        db_src0      => db(0),
        mem2         => ir(4),
        mem1         => ir(3),
        mem0         => ir(2),
        branch_block => branchBlock,
        db_mem1      => db(3),
        db_mem0      => db(2),
        db_mem2      => db(4),
        src0         => ir(0),
        q0           => q0Q,
        pc_enable    => pcEnableQ,
        x_enable     => xEnableQ,
        y_enable     => yEnableQ,
        load_instr_n => loadInstrNQ,
        load_imm_n   => loadImmNQ,
        load_x_n     => open,
        load_y_n     => open,
        load_ac_n    => open,
        mem_rw       => memRwQ
    );
    q0         <= q0Q after T_CO;
    pcEnable   <= pcEnableQ after T_CO;
    xEnable    <= xEnableQ after T_CO;
    yEnable    <= yEnableQ after T_CO;
    loadInstrN <= transport loadInstrNQ after T_REG_PD;
    loadImmN   <= transport loadImmNQ after T_REG_PD;
    memRw      <= transport memRwQ after T_REG_PD;

    branchComp : entity work.branch_pld
    port map (
        clk          => clk,
        i7           => ir(7),
        i6           => ir(6),
        i5           => ir(5),
        m2           => ir(4),
        m1           => ir(3),
        m0           => ir(2),
        z_low        => '0',
        neg          => '0',
        pixel_enable => pixelEnable,
        q0           => q0,
        pc_enable    => pcEnable,
        z_high       => '0',
        cout         => '0',
        load_pc_low  => open,
        load_pc_high => open,
        branch_block => branchBlockQ,
        alu_done     => open,
        stall        => stallInQ,
        srcEnN       => srcEnNQ,
        carry        => open,
        pix_ld_n     => open
    );
    stallIn     <= transport stallInQ after T_REG_PD;
    srcEnN      <= transport srcEnNQ after T_REG_PD;
    branchBlock <= transport branchBlockQ after T_REG_PD;

    -- the map register is held clear (all ROM) while RUN is low
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
        rw          => memRw,
        pixelEnable => pixelEnable,
        a11         => addr(11),
        a10         => addr(10),
        srcEnN      => srcEnN,
        run         => run,
        weN         => weNQ,
        romOeN      => romOeNQ,
        ramOeN      => ramOeNQ
    );
    weN    <= transport weNQ after T_PD;
    romOeN <= transport romOeNQ after T_PD;
    ramOeN <= transport ramOeNQ after T_PD;

    -- ---------------- Sync, PC, D and the address mux ----------------

    syncProc : process
        variable n     : natural := 0;
        variable grp   : natural;
        variable col   : natural;
        variable line  : natural;
        variable pix   : std_logic;
    begin
        wait until rising_edge(clk);
        n := n + 1;
        grp := n / 8;
        col := grp mod 100;
        line := (grp / 100) mod 525;
        pix := '0';
        if n mod 8 = 7 then
            if (line < 480 and col < 80) or (col >= 90 and col <= 92) then
                pix := '1';
            end if;
        end if;
        pixelEnable <= pix after T_CO;
        videoAddr <= std_logic_vector(to_unsigned((n * 37 + 4096) mod 65536, 16));
    end process syncProc;

    pcProc : process
    begin
        wait until rising_edge(clk);
        if pcEnable = '1' and stallOut = '0' then
            pc <= (pc + 1) mod 65536;
            pcOut <= (pc + 1) mod 65536 after T_CO;
        end if;
        if loadImmN = '0' then
            dReg <= db;
            dOut <= db after 10.5 ns;
        end if;
    end process pcProc;

    -- Sync ADDR_SEL / ADDR_SEL_HI / ADDR_SEL_LO and the four mux PLDs
    muxProc : process (pixelEnable, pcEnable, xEnable, yEnable, pcOut, dOut, videoAddr)
        variable a : std_logic_vector(15 downto 0);
    begin
        if pixelEnable = '1' then
            a := videoAddr;
        elsif pcEnable = '1' then
            a := std_logic_vector(to_unsigned(pcOut, 16));
        elsif yEnable = '1' then
            a := Y_REG & X_REG;
        elsif xEnable = '1' then
            a := x"00" & X_REG;
        else
            a := x"00" & dOut;
        end if;
        addr <= transport a after 15 ns;
    end process muxProc;

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
        eeAddrOkS <= '0', '1' after 157.5 ns;
    end process eeAddrOk;
    -- after /OE rises the outputs only go to high impedance (tDF): the
    -- byte stays on the bus, held by its capacitance after that
    eeOeOkS <= '1' after 70 ns when eeOeN = '0' else '0' when eeOn = '0';
    dataBus <= imageByte(to_integer(unsigned(addr))) when eeOn = '1' and eeAddrOkS = '1' and eeOeOkS = '1'
          else (others => 'X') when eeOn = '1'
          else (others => 'Z');

    -- cartridge SRAM (AS7C256C-15): reads on /ROM_OE
    sramOn <= not romOeN after 7 ns;
    dataBus <= sram(to_integer(unsigned(addr))) when sramOn = '1' else (others => 'Z');

    -- source F541 in EXEC (AC)
    srcOn <= '1' after 9.5 ns when srcEnN = '0' else '0' after 6.5 ns;
    dataBus <= x"5A" when srcOn = '1' else (others => 'Z');

    -- main RAM on video reads
    ramOn <= not ramOeN after 7 ns;
    dataBus <= x"C3" when ramOn = '1' else (others => 'Z');

    -- I/O reads (line read F541, port F541 and port PLD) in x5000-x53FF
    ioRd <= '1' when addr(15 downto 10) = "010100" and memRw = '1' and loadImmN = '0' else '0';
    ioRdD <= ioRd after T_PD;
    ioOn <= '1' after 9.5 ns when ioRdD = '1' else '0' after 6.5 ns;
    dataBus <= x"A5" when ioOn = '1' else (others => 'Z');

    -- the bus's own capacitance keeps the last value
    keepProc : process (dataBus)
    begin
        for i in 0 to 7 loop
            if dataBus(i) = '0' then
                keep(i) <= 'L';
            elsif dataBus(i) = '1' then
                keep(i) <= 'H';
            end if;
        end loop;
    end process keepProc;
    dataBus <= keep;

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
        assert now - busChanged >= 7 ns and not is_x(to_X01(dataBus)) and eeOn = '1'
            report "SRAM write data not settled at " & to_hstring(a) severity failure;
        sram(to_integer(unsigned(a))) <= to_X01(dataBus);
    end process sramWrite;

    -- ---------------- setup and behaviour checks ----------------

    setupCheck : process
        variable lastCart  : time := 0 ns;
        variable lastStall : time := 0 ns;
    begin
        wait on clk, addr(15), pixelEnable, pcEnable, stallOut;
        if addr(15)'event or pixelEnable'event or pcEnable'event then
            lastCart := now;
        end if;
        if stallOut'event then
            lastStall := now;
        end if;
        if rising_edge(clk) and now > 100 ns then
            assert now - lastCart >= T_SETUP or lastCart = now
                report "cartridge PLD input changed " & time'image(now - lastCart) & " before the edge"
                severity failure;
            assert now - lastStall >= T_SETUP
                report "STALL_OUT changed " & time'image(now - lastStall) & " before the edge"
                severity failure;
        end if;
    end process setupCheck;

    cpuCheck : process
        variable fetches  : natural := 0;
        variable limms    : natural := 0;
        variable lmems    : natural := 0;
        variable execs    : natural := 0;
        variable ioReads  : natural := 0;
        variable clocks   : natural := 0;
        variable seenRun  : boolean := false;
        variable xReads   : natural := 0;
    begin
        wait until rising_edge(clk);
        clocks := clocks + 1;
        if ioRdD = '1' and not seenRun then
            ioReads := ioReads + 1;
        end if;
        assert weN = '1' or seenRun report "a write while loading" severity failure;
        if stallOut = '0' then
            -- the CPU takes a step at this edge
            if q0 = '0' and pcEnable = '1' then             -- FETCH
                if is_x(to_X01(dataBus(4 downto 0))) then
                    xReads := xReads + 1;
                end if;
                if run = '1' then
                    assert pc = 0 or pc = 1
                        report "first fetch after the hand-off at " & to_hstring(to_unsigned(pc, 16)) severity failure;
                    assert db = imageByte(pc)
                        report "first fetch after the hand-off read " & to_hstring(db) severity failure;
                    report "hand-off: first fetch from the SRAM at " & to_hstring(to_unsigned(pc, 16))
                           & ", read correctly";
                    report "while loading: " & integer'image(fetches) & " fetches, " & integer'image(limms)
                           & " operand reads, " & integer'image(lmems) & " memory reads, "
                           & integer'image(execs) & " EXECs, " & integer'image(ioReads)
                           & " I/O read clocks, " & integer'image(clocks) & " clocks; "
                           & integer'image(xReads) & " fetches read a byte that was changing";
                    done <= true;
                    wait;
                end if;
                fetches := fetches + 1;
            elsif q0 = '1' and pcEnable = '1' then          -- LOAD_IMM
                limms := limms + 1;
                if run = '1' then
                    seenRun := true;
                end if;
            elsif q0 = '0' then                             -- LOAD_MEM
                lmems := lmems + 1;
            else                                            -- EXEC
                if run = '0' then
                    assert ir = x"02" report "IR is " & to_hstring(ir) & " in EXEC while loading" severity failure;
                end if;
                execs := execs + 1;
            end if;
        end if;
        if run = '1' then
            seenRun := true;
        end if;
    end process cpuCheck;

    -- ---------------- contention ----------------

    contention : process
        variable n        : natural;
        variable since    : time := 0 ns;
        variable longest  : time := 0 ns;
        variable inside   : boolean := false;
        variable who      : string(1 to 5);
        variable startWho : string(1 to 5);
        variable worstWho : string(1 to 5) := ".....";
    begin
        wait on eeOn, sramOn, srcOn, ramOn, ioOn, done;
        if done then
            report "longest bus overlap: " & time'image(longest) & " (" & worstWho & ")";
            wait;
        end if;
        n := 0;
        who := ".....";
        if eeOn = '1' then n := n + 1; who(1) := 'E'; end if;
        if sramOn = '1' then n := n + 1; who(2) := 'S'; end if;
        if srcOn = '1' then n := n + 1; who(3) := 'F'; end if;
        if ramOn = '1' then n := n + 1; who(4) := 'R'; end if;
        if ioOn = '1' then n := n + 1; who(5) := 'I'; end if;
        if n > 1 and not inside then
            inside := true;
            since := now;
            startWho := who;
        elsif n <= 1 and inside then
            inside := false;
            if now - since > longest then
                longest := now - since;
                worstWho := startWho;
            end if;
            assert now - since <= 3 ns
                report "bus contention (" & startWho & ") for " & time'image(now - since) & " ending at " & time'image(now)
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
