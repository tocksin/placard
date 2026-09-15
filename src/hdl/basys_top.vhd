/*
* @file basys_top.vhd
* @brief Top level design for the BASYS3 development board.
*        Experimental test platform for various ideas.
* @author Justin Davis
*
* Copyright: ©2023 by Southwest Research Institute®; all rights reserved
**************************************************************************/
library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;

library unisim;         use unisim.vcomponents.all;

library work;           use work.sys_description_pkg.all;
                        use work.tools_pkg.all;

entity basys_top is
 generic ( DATE_CODE    : slv(31 downto 0) := x"00000000";
           HASH_CODE    : slv(31 downto 0) := x"00000000");
    port ( SW           : in  slv (15 downto 0);
           BTN          : in  slv (4 downto 0);
           CLK          : in  sl;
           LED          : out  slv (15 downto 0);
           SSEG_CA      : out  slv (7 downto 0);
           SSEG_AN      : out  slv (3 downto 0);
           uartTxOut    : out  sl;
           uartRxIn     : in   sl;
           VGA_RED      : out  slv (3 downto 0);
           VGA_BLUE     : out  slv (3 downto 0);
           VGA_GREEN    : out  slv (3 downto 0);
           VGA_VS       : out  sl;
           VGA_HS       : out  sl;
           PS2_CLK      : inout sl;
           PS2_DATA     : inout sl;
           JB           : out   slv(4 downto 0)
    );
end entity basys_top;

architecture Behavioral of basys_top is

    attribute IOB : string;
    attribute IOB of SW         : signal is "TRUE";
    attribute IOB of BTN        : signal is "TRUE";
    attribute IOB of LED        : signal is "TRUE";
    attribute IOB of SSEG_CA    : signal is "TRUE";
    attribute IOB of SSEG_AN    : signal is "TRUE";
    attribute IOB of uartTxOut  : signal is "TRUE";
    attribute IOB of uartRxIn   : signal is "TRUE";
    attribute IOB of VGA_RED    : signal is "TRUE";
    attribute IOB of VGA_BLUE   : signal is "TRUE";
    attribute IOB of VGA_GREEN  : signal is "TRUE";
    attribute IOB of VGA_VS     : signal is "TRUE";
    attribute IOB of VGA_HS     : signal is "TRUE";
    attribute IOB of PS2_CLK    : signal is "TRUE";
    attribute IOB of PS2_DATA   : signal is "TRUE";

    component clk_wiz_0
    port
     (-- Clock in ports
      clk_in1           : in     sl;
      -- Clock out ports
      clk_out1          : out    sl;
      reset             : in     sl;
      locked            : out    sl
     );
    end component;


    constant TMR_CNTR_INT   : integer := 100000000;
    constant TMR_CNTR_SIZE  : integer := log2(TMR_CNTR_INT,UP);
    constant TMR_CNTR_MAX   : slv(TMR_CNTR_SIZE-1 downto 0) := slv(to_unsigned(TMR_CNTR_INT, TMR_CNTR_SIZE));

    constant TMR_VAL_MAX    : slv(3 downto 0) := "1111"; --9

    constant DEBOUNCE_CLKS  : integer := 2**16
    -- synthesis translate_off
     -2**16 + 10              -- reduce debounce time to 10 clocks in simulation
    -- synthesis translate_on
    ;

    --Used to determine when a button press has occured
    signal btnReg    : slv (3 downto 0);
    signal btnPulse  : slv (3 downto 0);

    --UART_TX_CTRL control signals
    signal uartRdy          : sl;
    signal uartSend         : sl := '0';
    signal uartTx           : sl;
    signal recvByte         : slv(7 downto 0);
    signal uartStrb         : sl;
    signal uartRxFifoData   : slv(7 downto 0);
    signal uartTxFifoData   : slv(7 downto 0);
    signal uartRdFifo       : sl;
    signal uartRxEmpty      : sl;
    signal uartTxFull       : sl;
    signal uartTxEn         : sl;
    signal uartRxEn         : sl;
    signal uartTxFullEn     : sl;
    signal uartRxEmptyEn    : sl;

    --Debounced btn signals used to prevent single button presses
    --from being interpreted as multiple button presses.
    signal btnDeBnc         : slv(4 downto 0);

    signal clkVGA           : sl;

    signal rstSystem        : sl;
    signal rstVGA           : sl;
    signal rstComponent     : sl;
    signal rstBtn           : sl;
    signal locked           : sl;

    signal videoEn          : sl;
    signal pixelRow         : slv(9 downto 0);
    signal pixelCol         : slv(9 downto 0);
    signal subpixelRow      : slv(8 downto 0);
    signal subpixelCol      : slv(8 downto 0);
    signal hSync            : sl;
    signal vSync            : sl;
    signal videoPixel       : slv(7 downto 0);
    signal videoAddr        : slv(15 downto 0);

    signal addrRom          : slv(10 downto 0);
    signal dataRom          : slv(15 downto 0);
    signal romEn            : sl;

    signal dipR             : slv(15 downto 0);
    signal dipRR            : slv(15 downto 0);
    signal dipEn            : sl;

    signal ledR             : slv(15 downto 0);
    signal ledEn            : sl;

    signal ssegR            : slv(15 downto 0);

    signal sync             : sl;
    signal blank            : sl;
    
    signal pixelBuffer      : slv(7 downto 0);
    signal loadPixel        : sl;
    
begin

--    rstBtn <= '0';
    rstBtn <= BTN(4);

    clk_wiz_0_inst : clk_wiz_0
    port map (
        clk_in1  => CLK,        -- expecting 100 MHz
        clk_out1 => clkVGA,     -- requesting 25.17483  MHz
        locked   => locked,
        reset    => rstBtn
     );

    rstVGA <= not locked;
    rstSystem <= not locked;

    ----------------------------------------------------------
    ------                DIP Input                    -------
    ----------------------------------------------------------
    dipProcess : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            dipR <= SW;
            dipRR <= dipR;
        end if;
    end process dipProcess;

    ----------------------------------------------------------
    ------                LED Control                  -------
    ----------------------------------------------------------
    ledProcess : process (clkVGA, rstVGA)
    begin
        if (rstVGA = '1') then
            ledR <= (others => '0');
        elsif (rising_edge(clkVGA)) then
            if (ledEn='1') then
                ledR <= dipRR;
            end if;
        end if;
    end process ledProcess;

    LED <= ledR;

    ----------------------------------------------------------
    ------              Button Control                 -------
    ----------------------------------------------------------
    --Buttons are debounced and their rising edges are detected
    --to trigger UART messages

    debounceComp: entity work.debouncer
        generic map(
            DEBNC_CLOCKS => DEBOUNCE_CLKS,
            PORT_WIDTH => 5)
        port map(
            clkIn => clkVGA,
            rstIn => rstVGA,
            rawIn => BTN,
            debouncedOut => btnDeBnc
        );

    onePulse(clkVGA, rstVGA, btnDeBnc(0), btnReg(0), btnPulse(0));
    onePulse(clkVGA, rstVGA, btnDeBnc(1), btnReg(1), btnPulse(1));
    onePulse(clkVGA, rstVGA, btnDeBnc(2), btnReg(2), btnPulse(2));
    onePulse(clkVGA, rstVGA, btnDeBnc(3), btnReg(3), btnPulse(3));

    ----------------------------------------------------------
    ------              VGA Control                    -------
    ----------------------------------------------------------
    vgaGenComp: entity work.vgaSync
    port map(   clkIn           => clkVGA,
                rstIn           => rstVGA,
                hSyncOut        => hSync,
                vSyncOut        => vSync,
                videoEnOut      => videoEn,
                pixelRowOut     => pixelRow,
                pixelColOut     => pixelCol,
                subpixelRowOut  => subpixelRow,
                subpixelColOut  => subpixelCol
    );

    VGA_VS <= vSync;
    VGA_HS <= hSync;
    VGA_RED <= pixelBuffer(7 downto 5) & "0";
    VGA_BLUE <= pixelBuffer(4 downto 3) & "00";
    VGA_GREEN <= pixelBuffer(2 downto 0) & "0";
        
    loadPixel <= '1' when pixelCol(2 downto 0) = "000" else '0';
    
    ramComp : entity work.sp_ram 
    port map(   iClk    => clkVGA,
                iWrEn   => '0',
                iRamEn  => '1',
                iAddr   => videoAddr,
                iData   => (videoPixel'range => '0'),
                oData   => videoPixel);  -- must be same size as input data

    videoAddr <= (pixelRow(8 downto 0) & pixelCol(9 downto 3));

    videoOutProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA = '1') then
             pixelBuffer <= (others => '0');
        elsif (rising_edge(clkVGA)) then
            if loadPixel = '1' then
                pixelBuffer <= videoPixel;
            end if;
        end if;
    end process videoOutProc;

    -- Stall CPU one cycle when reading from RAM
--    onePulse(clkVGA, rstSystem, ramEn, ramEnR, ramStall);
/*
    ----------------------------------------------------------
    ------                ROM                          -------
    ----------------------------------------------------------
    romComp : entity work.rom_synth
    port map(   addrIn      => addrRom,
                dataOut     => dataRom);
*/

end architecture Behavioral;
