/*
* @file basys_top.vhd
* @brief Top level design for the BASYS3 development board.
*        Experimental test platform for various ideas.
* @author Justin Davis
*
**************************************************************************/
library ieee;           use ieee.std_logic_1164.all;
                        use ieee.numeric_std.all;

library unisim;         use unisim.vcomponents.all;

library work;           use work.sys_description_pkg.all;
                        use work.tools_pkg.all;

entity basys_top is
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

    constant DEBOUNCE_CLKS  : integer := 2**16
    -- synthesis translate_off
     -2**16 + 10              -- reduce debounce time to 10 clocks in simulation
    -- synthesis translate_on
    ;

    --Used to determine when a button press has occured
    signal btnReg    : slv (3 downto 0);
    signal btnPulse  : slv (3 downto 0);

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
    signal vidRamEn         : sl;
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
    signal loadCode         : sl;
    signal lineCode         : slv(7 downto 0);
    signal vRed             : slv(3 downto 0);
    signal vBlue            : slv(3 downto 0);
    signal vGreen           : slv(3 downto 0);
    
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
            ledR <= dipRR;
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
                ramEnOut        => vidRamEn,
                pixelRowOut     => pixelRow,
                pixelColOut     => pixelCol,
                subpixelRowOut  => subpixelRow,
                subpixelColOut  => subpixelCol
    );

    loadPixel <= '1' when pixelCol(2 downto 0) = "000" else '0';
    loadCode <= '1' when pixelCol(9 downto 0) = "0000000001" else '0';
    videoAddr <= (pixelRow(8 downto 0) & pixelCol(9 downto 3));

    ramComp : entity work.sp_ram 
    port map(   iClk    => clkVGA,
                iWrEn   => '0',
                iRamEn  => vidRamEn,
                iAddr   => videoAddr,
                iData   => (videoPixel'range => '0'),
                oData   => videoPixel);  -- must be same size as input data

    pixelBuffer <= videoPixel when videoEn='1' else x"00";

    lineCodeProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA = '1') then
             lineCode <= (others => '0');
        elsif (rising_edge(clkVGA)) then
            if loadCode = '1' then
                lineCode <= videoPixel;
            end if;
        end if;
    end process lineCodeProc;

    colorDecoderComp : entity work.color_decoder
    Port map(
        -- Input Data

        D0    => pixelBuffer(0),
        D1    => pixelBuffer(1),
        D2    => pixelBuffer(2),
        D3    => pixelBuffer(3),
        D4    => pixelBuffer(4),
        D5    => pixelBuffer(5),
        D6    => pixelBuffer(6),
        D7    => pixelBuffer(7),

        -- Mode Selection
        MODE0 => lineCode(0),
        MODE1 => lineCode(1),

/*
        D0    => dipRR(0),
        D1    => dipRR(1),
        D2    => dipRR(2),
        D3    => dipRR(3),
        D4    => dipRR(4),
        D5    => dipRR(5),
        D6    => dipRR(6),
        D7    => dipRR(7),
*/
/*
        -- Mode Selection
        MODE0 => dipRR(8),
        MODE1 => dipRR(9),
*/
        -- Selection Signals
        SEL0  => pixelCol(0),
        SEL1  => pixelCol(1),
        SEL2  => pixelCol(2),

        -- VGA Outputs
        OUT0  => vRed(1),   -- VGA_RED(1)
        OUT1  => vRed(2),   -- VGA_RED(2)
        OUT2  => vRed(3),   -- VGA_RED(3)
        OUT3  => vBlue(2),  -- VGA_BLUE(2)
        OUT4  => vBlue(3),  -- VGA_BLUE(3)
        OUT5  => vGreen(1), -- VGA_GREEN(1)
        OUT6  => vGreen(2), -- VGA_GREEN(2)
        OUT7  => vGreen(3)  -- VGA_GREEN(3)
    );

    vRed(0) <= vRed(1);
    vBlue(1 downto 0) <= vBlue(2) & vBlue(2);
    vGreen(0) <= vGreen(1);

    VGA_RED   <= vRed;
    VGA_BLUE  <= vBlue;
    VGA_GREEN <= vGreen;
    VGA_VS <= vSync;
    VGA_HS <= hSync;

/*
    -- Clocked output for video signals to see if there's a quality change
    videoOutProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA = '1') then
            VGA_RED   <= (others => '0');
            VGA_BLUE  <= (others => '0');
            VGA_GREEN <= (others => '0');
            VGA_VS <= '1';
            VGA_HS <= '1';
        elsif (rising_edge(clkVGA)) then
            if videoEn='1' then
                VGA_RED   <= vRed;
                VGA_BLUE  <= vBlue;
                VGA_GREEN <= vGreen;
            else 
                VGA_RED   <= (others => '0');
                VGA_BLUE  <= (others => '0');
                VGA_GREEN <= (others => '0');
            end if;
            VGA_VS <= vSync;
            VGA_HS <= hSync;
        end if;
    end process videoOutProc;
*/

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
