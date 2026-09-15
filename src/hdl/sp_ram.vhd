-- @file sp_ram.vhd
-- @brief Single-port RAM - Will synthesize in block ram
-- @author Justin Davis
--
-- Date: 05/26/2023
-- LastEditedBy: Justin Davis
--
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

/*
    -- function to initialize memory content
    function initMemory(dataLength : in integer) return ramType is
    
    constant FLIGHT_NUM_STR     : string(1 to 20)  := "    FLIGHT NUMBER   ";
    constant SIX_DIGITS_STR     : string(1 to 20)  := "   ENTER 6 DIGITS   ";
    constant POUNDS_STR         : string(1 to 20)  := "      (######)      ";
    constant INPUT_STR          : string(1 to 20)  := "   I :      123     ";
    constant ENTER_STR          : string(1 to 20)  := "  THEN PRESS ENTER  ";

    constant FLT_STR            : string(1 to 20)  := " FLT   000123/000   ";
    constant TIME_STR           : string(1 to 20)  := " TIME    00:02:33   ";
    constant LAT_STR            : string(1 to 20)  := " LAT   N 00:00:00   ";
    constant LONG_STR           : string(1 to 20)  := " LONG  W000:00:00   ";
    constant AZ_STR             : string(1 to 20)  := " AZ           012   ";
    constant RANGE_STR          : string(1 to 20)  := " RANGE     08280M   ";
    constant RH_STR             : string(1 to 20)  := " R/H    0000/0000   ";
    constant RDR_STR            : string(1 to 20)  := " RDR                ";

    constant FLIGHT_NUM_ARR     : charArray(0 to 19) := to_chararray(FLIGHT_NUM_STR);
    constant SIX_DIGITS_ARR     : charArray(0 to 19) := to_chararray(SIX_DIGITS_STR);
    constant POUNDS_ARR         : charArray(0 to 19) := to_chararray(POUNDS_STR);
    constant INPUT_ARR          : charArray(0 to 19) := to_chararray(INPUT_STR);
    constant ENTER_ARR          : charArray(0 to 19) := to_chararray(ENTER_STR);
    
    constant FLT_ARR            : charArray(0 to 19) := to_chararray(FLT_STR);
    constant TIME_ARR           : charArray(0 to 19) := to_chararray(TIME_STR);
    constant LAT_ARR            : charArray(0 to 19) := to_chararray(LAT_STR);
    constant LONG_ARR           : charArray(0 to 19) := to_chararray(LONG_STR);
    constant AZ_ARR             : charArray(0 to 19) := to_chararray(AZ_STR);
    constant RANGE_ARR          : charArray(0 to 19) := to_chararray(RANGE_STR);
    constant RH_ARR             : charArray(0 to 19) := to_chararray(RH_STR);
    constant RDR_ARR            : charArray(0 to 19) := to_chararray(RDR_STR);
        
        variable temp_mem : ramType := (others => x"20");
    begin
        for i in ramType'range loop
            temp_mem(i) := std_logic_vector(to_unsigned(i,dataLength));
        end loop;
        -- Left window
        for i in FLIGHT_NUM_ARR'range loop
            temp_mem(i+(64*2)+2) := FLIGHT_NUM_ARR(i);
        end loop;

        for i in SIX_DIGITS_ARR'range loop
            temp_mem(i+(64*4)+2) := SIX_DIGITS_ARR(i);
        end loop;

        for i in POUNDS_ARR'range loop
            temp_mem(i+(64*6)+2) := POUNDS_ARR(i);
        end loop;
        
        for i in INPUT_ARR'range loop
            temp_mem(i+(64*8)+2) := INPUT_ARR(i);
        end loop;

        for i in ENTER_ARR'range loop
            temp_mem(i+(64*9)+2) := ENTER_ARR(i);
        end loop;

        -- Right window
        for i in FLT_ARR'range loop
            temp_mem(i+(64*2)+30) := FLT_ARR(i);
        end loop;

        for i in TIME_ARR'range loop
            temp_mem(i+(64*3)+30) := TIME_ARR(i);
        end loop;

        for i in LAT_ARR'range loop
            temp_mem(i+(64*4)+30) := LAT_ARR(i);
        end loop;

        for i in LONG_ARR'range loop
            temp_mem(i+(64*5)+30) := LONG_ARR(i);
        end loop;

        for i in AZ_ARR'range loop
            temp_mem(i+(64*6)+30) := AZ_ARR(i);
        end loop;

        for i in RANGE_ARR'range loop
            temp_mem(i+(64*7)+30) := RANGE_ARR(i);
        end loop;

        for i in RH_ARR'range loop
            temp_mem(i+(64*8)+30) := RH_ARR(i);
        end loop;

        for i in RDR_ARR'range loop
            temp_mem(i+(64*9)+30) := RDR_ARR(i);
        end loop;

        return temp_mem;
    end function;
*/
--    signal RAM : ramType := initMemory(iData'length);
    signal RAM : ramType := (others => (others => '0'));

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
end architecture rtl;
