-- ============================================================
-- tb_top_load: the whole FPGA top level (basys_top) from power-up:
-- the ROM cartridge copies its EEPROMs (rom.mem) into its SRAM, then
-- the CPU boots from the SRAM
-- Date: 10/21/2026
--
-- Needs rom.mem, ram.mem and cart_ram.mem where the simulator finds
-- them (gen_rom.tcl, gen_random_ram.tcl).  CLOCKS is the run length
-- in 25 MHz clocks; the load takes about 0.7-0.8 M of them (28-33 ms,
-- depending on how the image walks), so run 1 M or more.
--
-- Checks: nothing writes while RUN is low; the IR is 02h at every
-- fetch while loading; after RUN every CPU read of the cartridge
-- returns rom.mem's byte.  Reports when RUN rises, the first fetches
-- after it (x0000 or x0001), and when the boot loader (xFD00) and a
-- ROM program (x6000) are reached.
--
-- GHDL: stub the unisim library and clk_wiz_0 (clk_out1 = 25 MHz,
-- clk_out2 = 100 MHz), then
--   ghdl -i --std=08 -frelaxed src/hdl/*.vhd <stubs> src/sim/tb_top_load.vhd
--   ghdl -m --std=08 -frelaxed tb_top_load
--   ghdl -r --std=08 -frelaxed tb_top_load -gCLOCKS=1300000 --ieee-asserts=disable
-- (about 1.5 minutes).
-- ============================================================

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
entity tb_top_load is generic (CLOCKS : natural := 1200000); end;
architecture s of tb_top_load is
    signal clk : std_logic := '0';
    signal sw : std_logic_vector(15 downto 0) := x"0000";
    signal btn : std_logic_vector(4 downto 0) := "00000";
    signal ps2c, ps2d : std_logic := 'H';
    signal jb : std_logic_vector(4 downto 0);
    signal jc : std_logic_vector(3 downto 0);
    signal done : boolean := false;
    type romT is array (0 to 65535) of std_logic_vector(7 downto 0);
    impure function loadRom return romT is
        file f : text open read_mode is "rom.mem";
        variable l : line; variable r : romT; variable v : std_logic_vector(7 downto 0);
    begin
        for i in 0 to 65535 loop readline(f, l); hread(l, v); r(i) := v; end loop;
        return r;
    end;
begin
    clk <= not clk after 5 ns when not done;
    jb <= (others => 'H'); jc <= (others => 'H');
    dut: entity work.basys_top port map(SW => sw, BTN => btn, CLK => clk, LED => open, SSEG_CA => open,
        SSEG_AN => open, uartTxOut => open, uartRxIn => '1', VGA_RED => open, VGA_BLUE => open,
        VGA_GREEN => open, VGA_VS => open, VGA_HS => open, PS2_CLK => ps2c, PS2_DATA => ps2d, JB => jb,
        JC => jc, JA => open);
    tr: process
        alias vclk is <<signal .tb_top_load.dut.clkVGA : std_logic>>;
        alias run is <<signal .tb_top_load.dut.run : std_logic>>;
        alias ad is <<signal .tb_top_load.dut.ramAddress : std_logic_vector(15 downto 0)>>;
        alias pc is <<signal .tb_top_load.dut.programCounter : std_logic_vector(15 downto 0)>>;
        alias db is <<signal .tb_top_load.dut.dataBus : std_logic_vector(7 downto 0)>>;
        alias ir is <<signal .tb_top_load.dut.instReg : std_logic_vector(7 downto 0)>>;
        alias we is <<signal .tb_top_load.dut.ramWeN : std_logic>>;
        alias romSel is <<signal .tb_top_load.dut.romSel : std_logic>>;
        alias eeDrv is <<signal .tb_top_load.dut.cartEeDrive : std_logic>>;
        alias ldi is <<signal .tb_top_load.dut.instLoadN : std_logic>>;
        alias pen is <<signal .tb_top_load.dut.pcEnable : std_logic>>;
        alias stall is <<signal .tb_top_load.dut.stall : std_logic>>;
        alias mp is <<signal .tb_top_load.dut.mapReg : std_logic_vector(7 downto 0)>>;
        variable rom : romT := loadRom;
        variable n, runAt, checked, bad, writesLoad, fetches : natural := 0;
        variable seen6000, seenFD00 : boolean := false;
        variable l : line;
    begin
        loop
            wait until rising_edge(vclk);
            n := n + 1;
            if run = '0' then
                if we = '0' then writesLoad := writesLoad + 1; end if;
                if ldi = '0' and ir /= x"02" and n > 2 then
                    report "IR not 02 while loading: " & to_hstring(ir) severity error;
                end if;
            else
                if runAt = 0 then
                    runAt := n;
                    report "RUN high at clock " & integer'image(n) & " (" & integer'image(n / 25) & " us), PC " & to_hstring(pc);
                end if;
                wait until falling_edge(vclk);   -- the memory models answer within the clock
                if romSel = '1' and eeDrv = '0' and is_x(db) = false and is_x(ad) = false then
                    checked := checked + 1;
                    if db /= rom(to_integer(unsigned(ad))) then
                        bad := bad + 1;
                        if bad < 10 then
                            report "cart SRAM " & to_hstring(ad) & " = " & to_hstring(db) & ", rom.mem " & to_hstring(rom(to_integer(unsigned(ad)))) severity error;
                        end if;
                    end if;
                end if;
                if ldi = '0' and stall = '0' then
                    fetches := fetches + 1;
                    if fetches <= 4 then
                        report "fetch " & integer'image(fetches) & " at " & to_hstring(ad) & " opcode " & to_hstring(db);
                    end if;
                    if ad = x"FD00" and not seenFD00 then seenFD00 := true; report "boot loader reached at clock " & integer'image(n); end if;
                    if ad = x"6000" and not seen6000 then seen6000 := true; report "program x6000 reached at clock " & integer'image(n) & ", map " & to_hstring(mp); end if;
                end if;
            end if;
            if n = CLOCKS then
                report "clocks " & integer'image(n) & ", writes while loading " & integer'image(writesLoad)
                     & ", cart reads checked " & integer'image(checked) & ", wrong " & integer'image(bad)
                     & ", fetches after RUN " & integer'image(fetches);
                done <= true; wait;
            end if;
        end loop;
    end process;
end;
