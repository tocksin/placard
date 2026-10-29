-- @file tb_basys_demo.vhd
-- @brief Top level testbench for the basys_demo
-- @author Justin Davis
--
-- Date: 09/14/2026
-------------------------------------------------------------------------------
library std;            use std.env.all;

library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;
                        
library work;           use work.tools_pkg.all;
                        use work.sys_description_pkg.all;
                        

entity tb_basys_demo is
end tb_basys_demo;

architecture Behavioral of tb_basys_demo is

    signal clkSys           : sl                := '0';
    signal rstSys           : sl                := '1';

    signal switches         : slv(15 downto 0)  := x"ABCD";
    signal buttons          : slv(4 downto 0);
    signal leds             : slv(15 downto 0);

    signal vgaRed           : slv(3 downto 0);
    signal vgaBlue          : slv(3 downto 0);
    signal vgaGreen         : slv(3 downto 0);
    signal vgaVertSync      : sl;
    signal vgaHorSync       : sl;
    signal sync             : sl;
    signal blank            : sl;
    
    signal ps2Clk           : sl;
    signal ps2Data          : sl;
    signal pmodB            : slv(4 downto 0);
    signal uartFromDut      : sl;
    signal uartToDut        : sl;
    signal sevensegCA       : slv(7 downto 0);
    signal sevensegAN       : slv(3 downto 0);

begin

    clkSys <= not clkSys after INPUT_CLOCK_PERIOD/2;
    rstSys <= '1', '0' after 1us;
    ps2Clk <= 'H';
    ps2Data <= 'H';

    dut: entity work.basys_top(Behavioral)
    port map( 
            SW          => switches,
            BTN         => buttons,
            CLK         => clkSys,
            LED         => leds,
            SSEG_CA     => sevensegCA,
            SSEG_AN     => sevensegAN,
            uartTxOut   => uartFromDut,
            uartRxIn    => uartToDut,
            VGA_RED     => vgaRed,
            VGA_BLUE    => vgaBlue,
            VGA_GREEN   => vgaGreen,
            VGA_VS      => vgaVertSync,
            VGA_HS      => vgaHorSync,
            PS2_CLK     => ps2Clk,
            PS2_DATA    => ps2Data,
            JB          => pmodB
        );

        
    sync <= pmodB(0);
    blank <= pmodB(1);
    

    initializeProc: process
    begin
        buttons <= "00000";
        wait for 1ms;
        buttons <= "00001";
        wait for 1ms;
        buttons <= "00000";
        wait for 1ms;
        buttons <= "01111";
        wait for 1ms;
        buttons <= "00000";
        wait;
    end process initializeProc;
    
    
    -------------------------------------------------------------------------------
    -- Initialize - Displays device configuration - memory map and index examples
    -------------------------------------------------------------------------------
    Initialize: process
    begin
        if (now = 0 ps) then
        end if;
        --stop;
        wait;
    end process Initialize;
        
end Behavioral;
