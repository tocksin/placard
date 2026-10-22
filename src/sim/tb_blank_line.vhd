-- ============================================================
-- tb_blank_line: the video timing PLDs (vga_gen_pld: H counter,
-- V counter, Sync, audio slot) with the blank line bit (line code
-- Q7, H counter revision 08)
-- Date: 10/22/2026
--
-- The line code register is modelled here: Q7 loads at the end of
-- each group 45 (when /MODE_LD goes high), alternating 0 and 1 from
-- line to line.  Each line is checked from one /MODE_LD rising edge
-- to the next:
--   - H_VIDEO_ACTIVE rises exactly once (the audio DAC clock), on
--     shown and blanked lineNum alike;
--   - a blanked active line has no VIDEN and only the two blanking
--     reads (audio sample, next line's mode byte): no pixel reads, so
--     the CPU is not stalled;
--   - a shown active line has 640 VIDEN clocks and 82 reads.
--
-- GHDL:
--   ghdl -i --std=08 -frelaxed src/hdl/tools_pkg.vhd src/hdl/hcount_pld.vhd \
--       src/hdl/vcount_pld.vhd src/hdl/sync_pld.vhd src/hdl/audio_pld.vhd \
--       src/hdl/vga_gen_pld.vhd src/sim/tb_blank_line.vhd
--   ghdl -m --std=08 -frelaxed tb_blank_line
--   ghdl -r --std=08 -frelaxed tb_blank_line --ieee-asserts=disable
-- ============================================================

library ieee; use ieee.std_logic_1164.all;
entity tb_blank_line is generic (LINES : natural := 600); end;
architecture s of tb_blank_line is
    signal clk : std_logic := '0';
    signal done : boolean := false;
    signal viden, pixelEn, modeLdN, hVideoActive : std_logic;
    signal lc7 : std_logic := '0';
begin
    clk <= not clk after 20 ns when not done;
    dut: entity work.vga_gen_pld port map(
        clkIn => clk, rstIn => '0', hSyncOut => open, vSyncOut => open, videnOut => viden,
        pixelEnOut => pixelEn, modeLdNOut => modeLdN, hVideoActiveOut => hVideoActive,
        rowA0Out => open, rowA1Out => open, rowA7Out => open, rowA8Out => open,
        lc2In => '0', lc3In => '0', lc7In => lc7, i1In => '0', acSelNOut => open,
        pixelRowOut => open, pixelColOut => open,
        pcEnableIn => '0', yEnableIn => '0', xEnableIn => '0',
        muxSelBothOut => open, muxSelLoOut => open, muxSelHiOut => open);

    check: process
        variable reads, vidClocks, dacEdges, lineNum, shown, blanked, errs : natural := 0;
        variable lastMode, lastPe, lastHva : std_logic := '1';
    begin
        while lineNum < LINES loop
            wait until rising_edge(clk);
            if pixelEn = '1' and lastPe = '0' then reads := reads + 1; end if;
            if viden = '1' then vidClocks := vidClocks + 1; end if;
            if hVideoActive = '1' and lastHva = '0' then dacEdges := dacEdges + 1; end if;
            lastPe := pixelEn; lastHva := hVideoActive;
            if modeLdN = '1' and lastMode = '0' then        -- end of group 45: one line done
                if lineNum > 0 then
                    if dacEdges /= 1 then
                        report "line " & integer'image(lineNum) & ": " & integer'image(dacEdges)
                            & " H_VIDEO_ACTIVE edges" severity error;
                        errs := errs + 1;
                    end if;
                    if vidClocks > 0 or reads > 2 then      -- an active line
                        if lc7 = '1' then
                            report "blanked line " & integer'image(lineNum) & ": " & integer'image(vidClocks)
                                & " VIDEN clocks, " & integer'image(reads) & " reads" severity error;
                            errs := errs + 1;
                        elsif vidClocks /= 640 or reads /= 82 then
                            report "shown line " & integer'image(lineNum) & ": " & integer'image(vidClocks)
                                & " VIDEN clocks, " & integer'image(reads) & " reads" severity error;
                            errs := errs + 1;
                        else
                            shown := shown + 1;
                        end if;
                    elsif lc7 = '1' then
                        blanked := blanked + 1;
                    end if;
                end if;
                lineNum := lineNum + 1;
                reads := 0; vidClocks := 0; dacEdges := 0;
                lc7 <= not lc7;                             -- the next line's mode byte
            end if;
            lastMode := modeLdN;
        end loop;
        report "lines " & integer'image(lineNum) & ", shown " & integer'image(shown) & ", blanked "
            & integer'image(blanked) & ", errors " & integer'image(errs) severity note;
        done <= true;
        wait;
    end process;
end;
