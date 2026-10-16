-- @file sp_ram.vhd
-- @brief Single-port RAM - Will synthesize in block ram
-- @author Justin Davis
--
-- Date: 10/16/2026
-- LastEditedBy: Justin Davis
--
-- Copyright: 2023 Southwest Research Institute
-------------------------------------------------------------------------------
-- The memory is initialized from a text file (generic initFile) containing one
-- hex byte per line, address 0 first.  basys_top.vhd uses two instances:
--     ramComp  initFile => "ram.mem"  made by gen_video_ram.tcl (video test
--              patterns: a mode byte for each row at 4A20h + row, framed
--              1/2/4/8 bpp bands, text, and the 16 color palette)
--     romComp  initFile => "rom.mem"  made by gen_rom.tcl (boot loader,
--              standard library and font, and the program; see ROM.md)
--
-- Vivado: add the .mem files to the project as design sources AND simulation
-- sources (they are treated as data files), so the synthesizer and simulator
-- can find them by name (create_project.tcl does this).  If one is not found,
-- pass a full path in initFile.
-------------------------------------------------------------------------------
library ieee;       use ieee.std_logic_1164.all;
                    use ieee.numeric_std.all;
                    use ieee.std_logic_textio.all;

library std;        use std.textio.all;
                    
library work;       use work.tools_pkg.all;

entity sp_ram is
    generic( initFile : string := "ram.mem" );  -- memory initialization file
    port(   iClk    : in    std_logic;
            iWrEn   : in    std_logic;
            iRamEn  : in    std_logic;
            iAddr   : in    std_logic_vector;
            iData   : in    std_logic_vector;
            oData   :   out std_logic_vector  -- must be same size as input data
    );
end entity sp_ram;

-- attribute ram_style of {signal_name | entity_name }: {signal | entity} is "{auto | block | distributed | pipe_distributed | block_power1 | block_power2}";

architecture rtl of sp_ram is

    type ramType is array ((2**iAddr'length)-1 downto 0) of std_logic_vector(iData'range);

    -- Simple 32-bit LFSR-based pseudo-random generator (unused, kept for reuse)
    function prng_lfsr32(init : slv(31 downto 0)) return slv is
        variable feedback : sl;
        variable state    : slv(31 downto 0);
    begin
        feedback := init(0) xor init(1) xor init(21) xor init(31);
        state := init(30 downto 0) & feedback;

        return state(31 downto 0);
    end function;

    -- function to initialize memory content from a hex text file
    -- (one hex value per line, first line = address 0).  Addresses past the
    -- end of the file stay 0.
    impure function initMemory(fileName : string) return ramType is
        file     f : text open read_mode is fileName;
        variable l : line;
        variable m : ramType := (others => (others => '0'));
        variable v : std_logic_vector(iData'range);
        variable i : integer := 0;
    begin
        while (not endfile(f)) and (i <= ramType'high) loop
            readline(f, l);
            hread(l, v);
            m(i) := v;
            i := i + 1;
        end loop;
        file_close(f);
        return m;
    end function;

    signal RAM : ramType := initMemory(initFile);
--    signal RAM : ramType := (others => (others => '0'));

--    attribute ram_style : string;
--    attribute ram_style of RAM : signal is "block";

begin

    process(iClk)
    begin
        if rising_edge(iClk) then
            if iRamEn = '1' then
                if iWrEn = '1' then
                    RAM(to_integer(unsigned(iAddr))) <= iData;
                    oData <= iData;
                else
                    oData <= RAM(to_integer(unsigned(iAddr)));
                end if;
            end if;
        end if;
    end process;
/*
    process(all)
    begin
        if iRamEn = '1' then
            if iWrEn = '1' then
                RAM(to_integer(unsigned(iAddr))) <= iData;
                oData <= iData;
            else
                oData <= RAM(to_integer(unsigned(iAddr)));
            end if;
        end if;
    end process;
*/
end architecture rtl;
