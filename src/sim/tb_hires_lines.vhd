-- ============================================================
-- tb_hires_lines: the rev B video timing PLDs (vga_gen_pld_revb:
-- H counter revision 09, V counter, Sync revision 13, audio slot
-- revision 05) and the color decoder (revision 09) with 160-read
-- lines (mode byte bit 7).
-- Date: 11/17/2026
--
-- The line code register is modelled here: its bits load at the end
-- of each group 45 (when /MODE_LD goes high) from a pseudo-random
-- sequence, so 160-read and normal lines, 2x and 4x, and the three
-- color modes follow each other in every order.  Each line is checked
-- from one /MODE_LD rising edge to the next:
--   - it is exactly 800 clocks long;
--   - H_VIDEO_ACTIVE rises exactly once (the audio DAC clock);
--   - a shown line has 640 VIDEN clocks;
--   - a normal line makes 82 reads, a 160-read line 162, and its
--     pixel reads alternate A8 = 0, 1 (the half column);
--   - while VIDEN is high the pixel selects go 000 .. 111 on a normal
--     line and 00x 01x 10x 11x twice per group on a 160-read line;
--   - with the pixel byte xE4 (2 bpp pixels 0, 1, 2, 3) a 2 bpp
--     160-read line shows black, blue, gold, white in four clocks,
--     and with x4E a 4 bpp one shows index E then 4, two clocks each.
-- With RUN low (the cartridge loading) a 160-read line makes only
-- the 82 reads, 8 clocks apart.
--
-- GHDL:
--   ghdl -i --std=08 -frelaxed src/hdl/tools_pkg.vhd src/hdl/hcount_pld_revb.vhd \
--       src/hdl/vcount_pld.vhd src/hdl/sync_pld_revb.vhd src/hdl/audio_pld_revb.vhd \
--       src/hdl/vga_gen_pld_revb.vhd src/hdl/color_decoder_revb.vhd src/sim/tb_hires_lines.vhd
--   ghdl -m --std=08 -frelaxed tb_hires_lines
--   ghdl -r --std=08 -frelaxed tb_hires_lines --ieee-asserts=disable
-- ============================================================

library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
entity tb_hires_lines is generic (LINES : natural := 1200; RUN_LEVEL : std_logic := '1'); end;
architecture s of tb_hires_lines is
    signal clk : std_logic := '0';
    signal done : boolean := false;
    signal viden, pixelEn, modeLdN, hVideoActive, rowA8 : std_logic;
    signal pixelCol : std_logic_vector(9 downto 0);
    signal lineCode : std_logic_vector(7 downto 0) := x"00";
    signal pixelByte : std_logic_vector(7 downto 0) := x"E4";
    signal red1, red2, red3, blu2, blu3, grn1, grn2, grn3 : std_logic;
begin
    clk <= not clk after 20 ns when not done;
    dut: entity work.vga_gen_pld_revb port map(
        clkIn => clk, rstIn => '0', hSyncOut => open, vSyncOut => open, videnOut => viden,
        pixelEnOut => pixelEn, modeLdNOut => modeLdN, hVideoActiveOut => hVideoActive,
        rowA0Out => open, rowA1Out => open, rowA7Out => open, rowA8Out => rowA8,
        lc2In => lineCode(2), lc3In => lineCode(3), lc7In => lineCode(7),
        pixelRowOut => open, pixelColOut => pixelCol,
        rwIn => '1', runIn => RUN_LEVEL, weNOut => open, p0NIn => '1', mapWrNOut => open);

    dec: entity work.color_decoder_revb port map(
        D0 => pixelByte(0), D1 => pixelByte(1), D2 => pixelByte(2), D3 => pixelByte(3),
        D4 => pixelByte(4), D5 => pixelByte(5), D6 => pixelByte(6), D7 => pixelByte(7),
        MODE0 => lineCode(0), MODE1 => lineCode(1),
        H0 => pixelCol(0), H1 => pixelCol(1), H2 => pixelCol(2), VIDEN => viden,
        RED1 => red1, RED2 => red2, RED3 => red3, BLU2 => blu2, BLU3 => blu3,
        GRN1 => grn1, GRN2 => grn2, GRN3 => grn3);

    pixelByte <= x"4E" when lineCode(1 downto 0) = "10" else x"E4";

    check: process
        variable reads, vidClocks, dacEdges, clocks, lineNum, normalLines, hiLines, errs : natural := 0;
        variable a8Bad, selBad, colBad : natural := 0;
        variable vidIdx, readIdx : natural := 0;
        variable lastMode, lastPe, lastHva : std_logic := '1';
        variable lfsr : unsigned(15 downto 0) := x"ACE1";
        variable hi : boolean;
        variable sel : std_logic_vector(2 downto 0);
        variable want : std_logic_vector(2 downto 0);
        variable rgb, wantRgb : std_logic_vector(7 downto 0);
        variable ph : natural;
        procedure fail(msg : string) is
        begin
            report "line " & integer'image(lineNum) & ": " & msg severity error;
            errs := errs + 1;
        end procedure;
    begin
        while lineNum < LINES loop
            wait until rising_edge(clk);
            clocks := clocks + 1;
            hi := lineCode(7) = '1';
            if pixelEn = '1' and lastPe = '0' then
                reads := reads + 1;
                if viden = '1' and hi and RUN_LEVEL = '1' then  -- a pixel read after the first: A8 alternates 1, 0 from read B on
                    null;
                end if;
            end if;
            if pixelEn = '1' and pixelCol(9 downto 3) /= "0101101" and pixelCol(9 downto 3) /= "0101110"
                    and pixelCol(9 downto 3) /= "0101111" then  -- a pixel read (not group 45-47)
                if hi and RUN_LEVEL = '1' then
                    if (readIdx mod 2 = 0 and rowA8 /= '0') or (readIdx mod 2 = 1 and rowA8 /= '1') then a8Bad := a8Bad + 1; end if;
                end if;
                readIdx := readIdx + 1;
            end if;
            if viden = '1' then
                sel := pixelCol(2 downto 0);
                ph := vidIdx mod 8;
                if hi then
                    want := std_logic_vector(to_unsigned(ph mod 4, 2)) & sel(0);
                    if sel(2 downto 1) /= want(2 downto 1) or sel(0) /= sel(1) then selBad := selBad + 1; end if;
                else
                    want := std_logic_vector(to_unsigned(ph, 3));
                    if sel /= want then selBad := selBad + 1; end if;
                end if;
                rgb := red3 & red2 & red1 & grn3 & grn2 & grn1 & blu3 & blu2;
                if hi and lineCode(1 downto 0) = "01" then      -- 2 bpp, byte xE4: pixels 0 1 2 3
                    case ph mod 4 is
                        when 0 => wantRgb := "00000000";        -- black
                        when 1 => wantRgb := "00000111";        -- blue  R0 G1 B3
                        when 2 => wantRgb := "11110100";        -- gold  R7 G5 B0
                        when others => wantRgb := "11111111";   -- white
                    end case;
                    if rgb /= wantRgb then colBad := colBad + 1; end if;
                elsif hi and lineCode(1 downto 0) = "10" then   -- 4 bpp, byte x4E: index E (yellow 7 7 0) then 4 (red 7 0 0)
                    if ph mod 4 < 2 then wantRgb := "11111100"; else wantRgb := "11100000"; end if;
                    if rgb /= wantRgb then colBad := colBad + 1; end if;
                end if;
                vidIdx := vidIdx + 1;
            end if;
            vidClocks := vidClocks + to_integer(unsigned'("" & viden));
            if hVideoActive = '1' and lastHva = '0' then dacEdges := dacEdges + 1; end if;
            lastPe := pixelEn; lastHva := hVideoActive;
            if modeLdN = '1' and lastMode = '0' then            -- end of group 45: one line done
                if lineNum > 1 then
                    if clocks /= 800 then fail(integer'image(clocks) & " clocks"); end if;
                    if dacEdges /= 1 then fail(integer'image(dacEdges) & " H_VIDEO_ACTIVE edges"); end if;
                    if vidClocks > 0 then                       -- a shown line
                        if vidClocks /= 640 then fail(integer'image(vidClocks) & " VIDEN clocks"); end if;
                        if hi and RUN_LEVEL = '1' then
                            if reads /= 162 then fail("160-read line made " & integer'image(reads) & " reads"); end if;
                            hiLines := hiLines + 1;
                        else
                            if reads /= 82 then fail("made " & integer'image(reads) & " reads"); end if;
                            if hi then hiLines := hiLines + 1; else normalLines := normalLines + 1; end if;
                        end if;
                        if a8Bad > 0 then fail(integer'image(a8Bad) & " reads with the wrong A8"); end if;
                        if selBad > 0 then fail(integer'image(selBad) & " clocks with the wrong pixel select"); end if;
                        if colBad > 0 then fail(integer'image(colBad) & " clocks with the wrong color"); end if;
                    end if;
                end if;
                lineNum := lineNum + 1;
                reads := 0; vidClocks := 0; dacEdges := 0; clocks := 0;
                a8Bad := 0; selBad := 0; colBad := 0; vidIdx := 0; readIdx := 0;
                -- the next line's mode byte
                lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
                lineCode <= std_logic(lfsr(7)) & "000" & std_logic_vector(lfsr(3 downto 0));
                if lfsr(1 downto 0) = "00" then lineCode(1 downto 0) <= "11"; end if;   -- no 1 bpp: 8 bpp instead
            end if;
            lastMode := modeLdN;
        end loop;
        report "lines " & integer'image(lineNum) & ", shown normal " & integer'image(normalLines)
            & ", shown 160-read " & integer'image(hiLines) & ", errors " & integer'image(errs) severity note;
        done <= true;
        wait;
    end process;
end;
