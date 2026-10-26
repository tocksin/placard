-- ============================================================
-- tb_ps2_kbd: the whole FPGA top level (basys_top) with a PS/2 keyboard
-- model on PS2_CLK / PS2_DATA (SW14 = 1: the PS/2 keyboard socket)
-- Date: 10/26/2026
--
-- Build rom.mem from a program that reads the keyboard (io_demo.asm:
-- port_init, then kbd_scan every frame), plus ram.mem and cart_ram.mem
-- (gen_random_ram.tcl).  The keyboard answers no commands (like one that
-- missed port_init's probe); at 150 ms it types A and B (make and break
-- codes).  The monitor reports writes to the key buffer (xA8-xAF),
-- KBD_HEAD (xB0), KBD_FLAGS (xB2), PS2_LSN (xBE) and the first port
-- writes.  Expect "write 00A8 = 61" and later "write 00A9 = 62".
-- HARSH = true gives CLK slow, bouncing rising edges and changes DATA
-- right at each rising edge, which the PS/2 input filter in basys_top
-- must ride through (before the filter nothing was typed).
--
-- GHDL: stub the unisim library and clk_wiz_0 (as for tb_top_load), then
--   ghdl -i --std=08 -frelaxed src/hdl/*.vhd <stubs> src/sim/tb_ps2_kbd.vhd
--   ghdl -m --std=08 -frelaxed tb_ps2_kbd
--   ghdl -r --std=08 -frelaxed tb_ps2_kbd -gCLOCKS=4500000 -gHARSH=true --ieee-asserts=disable
-- (a few minutes).
-- ============================================================

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_ps2_kbd is generic (CLOCKS : natural := 6000000; HARSH : boolean := false); end;
architecture s of tb_ps2_kbd is
    signal clk : std_logic := '0';
    signal sw : std_logic_vector(15 downto 0) := x"4000";
    signal btn : std_logic_vector(4 downto 0) := "00000";
    signal ps2c, ps2d : std_logic;
    signal jb : std_logic_vector(4 downto 0);
    signal jc : std_logic_vector(3 downto 0);
    signal done : boolean := false;
begin
    clk <= not clk after 5 ns when not done;
    jb <= (others => 'H'); jc <= (others => 'H');
    ps2c <= 'H'; ps2d <= 'H';
    dut: entity work.basys_top port map(SW => sw, BTN => btn, CLK => clk, LED => open, SSEG_CA => open,
        SSEG_AN => open, uartTxOut => open, uartRxIn => '1', VGA_RED => open, VGA_BLUE => open,
        VGA_GREEN => open, VGA_VS => open, VGA_HS => open, PS2_CLK => ps2c, PS2_DATA => ps2d, JB => jb,
        JC => jc, JA => open);

    kbd: process
        procedure waitFree is
        begin
            loop
                if to_x01(ps2c) /= '1' then wait until to_x01(ps2c) = '1'; end if;
                wait on ps2c for 60 us;
                exit when to_x01(ps2c) = '1';
            end loop;
        end;
        procedure send(b : std_logic_vector(7 downto 0)) is
            variable bits : std_logic_vector(10 downto 0);
            variable ok : boolean;
        begin
            bits := '1' & not (b(0) xor b(1) xor b(2) xor b(3) xor b(4) xor b(5) xor b(6) xor b(7)) & b & '0';
            loop
                waitFree;
                ok := true;
                if HARSH then
                    if bits(0) = '0' then ps2d <= '0'; else ps2d <= 'Z'; end if;
                    wait for 20 us;
                    for i in 0 to 10 loop
                        if to_x01(ps2c) = '0' then ok := false; exit; end if;
                        ps2c <= '0'; wait for 40 us;
                        -- a slow, noisy rising edge, and DATA changes at once
                        for k in 1 to 3 loop
                            ps2c <= 'Z'; wait for 120 ns; ps2c <= '0'; wait for 80 ns;
                        end loop;
                        ps2c <= 'Z';
                        if i < 10 then
                            if bits(i + 1) = '0' then ps2d <= '0'; else ps2d <= 'Z'; end if;
                        end if;
                        wait for 40 us;
                    end loop;
                else
                for i in 0 to 10 loop
                    if to_x01(ps2c) = '0' then ok := false; exit; end if;
                    if bits(i) = '0' then ps2d <= '0'; else ps2d <= 'Z'; end if;
                    wait for 15 us;
                    if to_x01(ps2c) = '0' then ok := false; exit; end if;
                    ps2c <= '0'; wait for 40 us; ps2c <= 'Z'; wait for 25 us;
                end loop;
                end if;
                ps2d <= 'Z'; ps2c <= 'Z';
                if ok then report "kbd sent " & to_hstring(b) & " at " & time'image(now); exit;
                else report "kbd byte " & to_hstring(b) & " cut off, again"; end if;
            end loop;
        end;
    begin
        ps2c <= 'Z'; ps2d <= 'Z';
        wait for 150 ms;
        send(x"1C"); send(x"F0"); send(x"1C");
        send(x"32"); send(x"F0"); send(x"32");
        wait;
    end process;

    mon: process
        alias vclk is <<signal .tb_ps2_kbd.dut.clkVGA : std_logic>>;
        alias ad is <<signal .tb_ps2_kbd.dut.ramAddress : std_logic_vector(15 downto 0)>>;
        alias src is <<signal .tb_ps2_kbd.dut.srcBus : std_logic_vector(7 downto 0)>>;
        alias pc is <<signal .tb_ps2_kbd.dut.programCounter : std_logic_vector(15 downto 0)>>;
        alias we is <<signal .tb_ps2_kbd.dut.ramWeN : std_logic>>;
        alias pw is <<signal .tb_ps2_kbd.dut.portWrN : std_logic>>;
        variable n, pws : natural := 0;
        variable wasLow, pwLow : boolean := false;
        variable seen6000 : boolean := false;
    begin
        loop
            wait until rising_edge(vclk);
            n := n + 1;
            if we = '0' and not wasLow then
                if ad = x"00B2" or ad = x"00B0" or ad = x"00BE" or (unsigned(ad) >= x"00A8" and unsigned(ad) <= x"00AF") then
                    report "write " & to_hstring(ad) & " = " & to_hstring(src) & " at " & time'image(now);
                end if;
            end if;
            wasLow := we = '0';
            if pw = '0' and not pwLow then
                pws := pws + 1;
                if pws < 40 then report "port write " & to_hstring(ad) & " = " & to_hstring(src) & " at " & time'image(now); end if;
            end if;
            pwLow := pw = '0';
            if pc = x"6000" and not seen6000 then seen6000 := true; report "x6000 at " & time'image(now); end if;
            if n = CLOCKS then report "end, port writes " & integer'image(pws); done <= true; wait; end if;
        end loop;
    end process;
end;
