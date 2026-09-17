-- @file sp_ram.vhd
-- @brief Single-port RAM - Will synthesize in block ram
-- @author Justin Davis
--
-- Date: 05/26/2023
-- LastEditedBy: Justin Davis
--
-- Copyright: 2023 Southwest Research Institute
-------------------------------------------------------------------------------
library ieee;       use ieee.std_logic_1164.all;
                    use ieee.numeric_std.all;
                    
library work;       use work.tools_pkg.all;

entity sp_ram is
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

    -- Simple 32-bit LFSR-based pseudo-random generator
    function prng_lfsr32(init : slv(31 downto 0)) return slv is
        variable feedback : sl;
        variable state    : slv(31 downto 0);
    begin
        feedback := init(0) xor init(1) xor init(21) xor init(31);
        state := init(30 downto 0) & feedback;

        return state(31 downto 0);
    end function;

    -- function to initialize memory content
    function initMemory(seed : slv(31 downto 0)) return ramType is
        variable temp_mem : ramType := (others => x"20");
        variable prng_value : slv(31 downto 0);
    begin
    
        prng_value := seed;
        for i in ramType'range loop
--            temp_mem(i) := std_logic_vector(to_unsigned(i,dataLength));
            temp_mem(i) := prng_value(7 downto 0) ;
            prng_value := prng_lfsr32(prng_value);
        end loop;

        temp_mem(0)     := x"00";
        temp_mem(128)   := x"00";
        temp_mem(256)   := x"00";
        temp_mem(384)   := x"00";
        temp_mem(512)   := x"00";
        temp_mem(640)   := x"00";
        temp_mem(768)   := x"00";
        temp_mem(896)   := x"00";
        temp_mem(1024)  := x"00";
        
        temp_mem(1)      := "00000000";
        temp_mem(128+1)  := "00011000";
        temp_mem(256+1)  := "00100100";
        temp_mem(384+1)  := "01000010";
        temp_mem(512+1)  := "01111110";
        temp_mem(640+1)  := "01000010";
        temp_mem(768+1)  := "00100100";
        temp_mem(896+1)  := "00011000";
        temp_mem(1024+1) := "00000000";

        temp_mem(2)      := "10000000";
        temp_mem(128+2)  := "01000000";
        temp_mem(256+2)  := "00100000";
        temp_mem(384+2)  := "00010000";
        temp_mem(512+2)  := "00001000";
        temp_mem(640+2)  := "00000100";
        temp_mem(768+2)  := "00000010";
        temp_mem(896+2)  := "00000001";
        temp_mem(1024+2) := "00000000";

        temp_mem(1152)   := x"02";
        temp_mem(1280)   := x"02";
        temp_mem(1408)   := x"02";
        temp_mem(1536)   := x"02";
        temp_mem(1664)   := x"02";
        temp_mem(1792)   := x"02";
        temp_mem(1920)   := x"02";
        temp_mem(2048)   := x"02";
        temp_mem(2176)   := x"02";

        temp_mem(1152+1) := x"12";
        temp_mem(1280+1) := x"12";
        temp_mem(1408+1) := x"12";
        temp_mem(1536+1) := x"12";
        temp_mem(1664+1) := x"B8";
        temp_mem(1792+1) := x"B8";
        temp_mem(1920+1) := x"B8";
        temp_mem(2048+1) := x"B8";
        temp_mem(2176+1) := x"FF";
        
        return temp_mem;
    end function;

    signal RAM : ramType := initMemory(x"ACE1ACE1");
--    signal RAM : ramType := (others => (others => '0'));

    attribute ram_style : string;
    attribute ram_style of RAM : signal is "block";

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
