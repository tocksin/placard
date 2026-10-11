/*
* @file basys_top.vhd
* @brief Top level design for the BASYS3 development board.
*        Experimental test platform for various ideas.
* @author Justin Davis
*
* Copyright: 2023 by Southwest Research Institute; all rights reserved
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
      clk_out2          : out    sl;
      reset             : in     sl;
      locked            : out    sl
     );
    end component;

    constant DEBOUNCE_CLKS  : integer := 2**16
    -- synthesis translate_off
     -2**16 + 10              -- reduce debounce time to 10 clocks in simulation
    -- synthesis translate_on
    ;

    type sourceType is (IMM, MEM, ACC, UNDEF);
    signal source : sourceType;

    subtype memModeType is string(1 to 5);
    signal memMode : memModeType;
    signal destMode : memModeType;
    signal aluMode  : memModeType;
    
    --Used to determine when a button press has occured
    signal btnReg    : slv (3 downto 0);
    signal btnPulse  : slv (3 downto 0);

    --Debounced btn signals used to prevent single button presses
    --from being interpreted as multiple button presses.
    signal btnDeBnc         : slv(4 downto 0);

    signal clkVGA           : sl;
    signal clkSystem        : sl;
    signal clkCPU           : sl;

    signal rstSystem        : sl;
    signal rstVGA           : sl;
    signal rstComponent     : sl;
    signal rstBtn           : sl;
    signal locked           : sl;

    signal videoActive          : sl;
    signal videoActiveR         : sl;
    signal pixelEn         : sl;
    signal pixelRow         : slv(9 downto 0);
    signal pixelCol         : slv(9 downto 0);
    signal hSync            : sl;
    signal vSync            : sl;
    signal ramData          : slv(7 downto 0);
    signal dataBus          : slv(7 downto 0);
    signal videoAddr        : slv(15 downto 0) := x"0000";

    signal ramAddress       : slv(15 downto 0);
    signal addrRom          : slv(10 downto 0);
    signal dataRom          : slv(15 downto 0);
    signal romEn            : sl;
    signal romData          : slv(7 downto 0);
    signal dipR             : slv(15 downto 0);
    signal dipRR            : slv(15 downto 0);
    signal dipEn            : sl;

    signal ledR             : slv(15 downto 0);
    signal ledEn            : sl;

    signal ssegR            : slv(15 downto 0);

    signal sync             : sl;
    signal blank            : sl;
    
    
    signal pixelBuffer      : slv(7 downto 0) := x"00";
    signal pixelSel         : slv(2 downto 0) := "000";
    signal loadPixel        : sl;
    signal loadCode         : sl;
    signal lineCode         : slv(7 downto 0) := x"00";
    signal vRed             : slv(3 downto 0);
    signal vBlue            : slv(3 downto 0);
    signal vGreen           : slv(3 downto 0);
    
    signal muxSelBoth       : sl;
    signal muxSelLo         : sl;
    signal muxSelHi         : sl;
    
    signal programCounter   : slv(15 downto 0) := x"0000";
    signal pcEnable         : sl;
    signal pcCarry          : sl;

    signal memorySelEn      : sl := '0';
    signal acLoad           : sl;
    signal xLoad            : sl;
    signal yLoad            : sl;
    signal xEnable          : sl;
    signal yEnable          : sl;
    signal instLoad         : sl;
    signal dLoad            : sl;
    signal memRdWr          : sl;
    signal srcBus           : slv(7 downto 0);

    signal dReg             : slv(7 downto 0) := x"00";
    signal instReg          : slv(7 downto 0) := x"00";
    signal acReg            : slv(7 downto 0) := x"00";
    signal xReg             : slv(7 downto 0) := x"00";
    signal yReg             : slv(7 downto 0) := x"00";
    
    signal aluResult        : slv(7 downto 0);
    signal carryBetween     : sl;
    signal carryout         : sl;
    signal zeroLo           : sl;
    signal zeroHi           : sl;
    
    signal stateQ0          : sl;
    signal branchBlock      : sl;
    signal loadPcLow        : sl;
    signal loadPcHigh       : sl;
    signal acZero           : sl;
    signal acNeg            : sl;    
    
begin

--    rstBtn <= '0';
    rstBtn <= BTN(4);

    clk_wiz_0_inst : clk_wiz_0
    port map (
        clk_in1  => CLK,        -- expecting 100 MHz
        clk_out1 => clkVGA,     -- requesting 25  MHz
        clk_out2 => clkSystem,  -- requesting 100 MHz
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
    ------              CPU Control                    -------
    ----------------------------------------------------------
    clkCPU <= clkVGA;
    
    stateMachineProc: entity work.state_pld
    port map(
        clk         => clkCPU,
        byte_enable => pixelEn,
        db_src1     => dataBus(1),-- only used during fetch cycle - contains instruction bit 1
        db_src0     => dataBus(0),-- only used during fetch cycle - contains instruction bit 1 
        mem2        => instReg(4),-- dst/mem access mode
        mem1        => instReg(3),-- dst/mem access mode
        mem0        => instReg(2),-- dst/mem access mode

        q0          => stateQ0,
        pc_enable   => pcEnable,
        x_enable    => xEnable,
        y_enable    => yEnable,
        load_instr  => instLoad,
        load_imm    => dLoad,
        load_x      => xLoad,
        load_y      => yLoad,
        load_ac     => acLoad,
        branch_block => branchBlock,
        mem_rw      => memRdWr
    );

    acNeg  <= acReg(7);

    branchComp : entity work.branch_pld
    port map(
        i7           => instReg(7),
        i6           => instReg(6),
        i5           => instReg(5),
        m2           => instReg(4),
        m1           => instReg(3),
        m0           => instReg(2),
        z_low        => zeroLo,
        z_high       => zeroHi,
        neg          => acNeg,
        byte_enable  => pixelEn,
        q0           => stateQ0,
        pc_enable    => pcEnable,
        load_pc_low  => loadPcLow,
        load_pc_high => loadPcHigh,
        branch_block => branchBlock
    );
    
    memMode <= "[0,D]" when instReg(4 downto 2)="000" else
               "[0,X]" when instReg(4 downto 2)="001" else
               "[Y,X]" when instReg(4 downto 2)="010" else
               "[0,D]" when instReg(4 downto 2)="011" else
               "[0,D]" when instReg(4 downto 2)="100" else
               "[0,D]" when instReg(4 downto 2)="101" else
               "[0,X]" when instReg(4 downto 2)="110" else
               "[Y,X]" when instReg(4 downto 2)="111";
    
    destMode <= " ACC " when instReg(4 downto 2)="000" else
                " ACC " when instReg(4 downto 2)="001" else
                " ACC " when instReg(4 downto 2)="010" else
                "  X  " when instReg(4 downto 2)="011" else
                "  Y  " when instReg(4 downto 2)="100" else
                " RAM " when instReg(4 downto 2)="101" else
                " RAM " when instReg(4 downto 2)="110" else
                " RAM " when instReg(4 downto 2)="111";

    aluMode  <= "PUSHB" when instReg(7 downto 5)="000" else
                " AND " when instReg(7 downto 5)="001" else
                " OR  " when instReg(7 downto 5)="010" else
                " XOR " when instReg(7 downto 5)="011" else
                " ADD " when instReg(7 downto 5)="100" else
                " SUB " when instReg(7 downto 5)="101" else
                " SHR " when instReg(7 downto 5)="110" else
                " BRA " when instReg(7 downto 5)="111";
    
    pcCntLowerComp : entity work.pc_counter8
    port map (
        clk          => clkCPU,

        d0           => srcBus(0),
        d1           => srcBus(1),
        d2           => srcBus(2),
        d3           => srcBus(3),
        d4           => srcBus(4),
        d5           => srcBus(5),
        d6           => srcBus(6),
        d7           => srcBus(7),

        load         => loadPcLow,
        en           => pcEnable,
        cin          => '1',
        pixel_enable => pixelEn,

        q0           => programCounter(0),
        q1           => programCounter(1),
        q2           => programCounter(2),
        q3           => programCounter(3),
        q4           => programCounter(4),
        q5           => programCounter(5),
        q6           => programCounter(6),
        q7           => programCounter(7),

        co           => pcCarry
    );

    pcCntUpperComp : entity work.pc_counter8
    port map (
        clk          => clkCPU,

        d0           => yReg(0),
        d1           => yReg(1),
        d2           => yReg(2),
        d3           => yReg(3),
        d4           => yReg(4),
        d5           => yReg(5),
        d6           => yReg(6),
        d7           => yReg(7),

        load         => loadPcHigh,
        en           => pcEnable,
        cin          => pcCarry,
        pixel_enable => pixelEn,

        q0           => programCounter(8),
        q1           => programCounter(9),
        q2           => programCounter(10),
        q3           => programCounter(11),
        q4           => programCounter(12),
        q5           => programCounter(13),
        q6           => programCounter(14),
        q7           => programCounter(15),

        co           => open
    );
    
    -- All CPU registers process 
    cpuRegProc : process (clkCPU)
    begin
        if rising_edge(clkCPU) then
            if (instLoad='1') then
                instReg <= databus;
            end if;
            if (dLoad='1') then
                dReg <= databus;
            end if;
            if (acLoad='1') then
                acReg <= aluResult;
            end if;
            if (xLoad = '1') then
                xReg <= aluResult;
            end if;
            if (yLoad = '1') then
                yReg <= aluResult;
            end if;
        end if;
    end process cpuRegProc;

    aluLowerComp: entity work.alu4
    port map(
        a              => acReg(3 downto 0),
        b              => databus(3 downto 0),
        s              => instReg(7 downto 5),
        cin            => '0',
        shift_right_in => acReg(4),
        f              => aluResult(3 downto 0),
        cout           => carryBetween,
        z              => zeroLo,
        d1             => open,
        d2             => open,
        d3             => open
    );
    
    aluUpperComp: entity work.alu4
    port map(
        a              => acReg(7 downto 4),
        b              => databus(7 downto 4),
        s              => instReg(7 downto 5),
        cin            => carryBetween,
        shift_right_in => '0',
        f              => aluResult(7 downto 4),
        cout           => carryout,
        z              => zeroHi,
        d1             => open,
        d2             => open,
        d3             => open
    );
    
    ----------------------------------------------------------
    ------              VGA Timing                     -------
    ----------------------------------------------------------
/*
    vgaGenComp: entity work.vgaSync
    port map(   clkIn           => clkVGA,
                rstIn           => rstVGA,
                hSyncOut        => open,
                vSyncOut        => open,
                videoEnOut      => open,
                ramEnOut        => open,
                pixelRowOut     => open,
                pixelColOut     => open,
                subpixelRowOut  => open,
                subpixelColOut  => open
    );
*/
    vgaPLDComp: entity work.vga_gen_pld
    port map(   clkIn           => clkVGA,
                rstIn           => rstVGA,
                hSyncOut        => hSync,
                vSyncOut        => vSync,
                videoActiveOut  => videoActive,
                pixelEnOut      => pixelEn,
                pixelRowOut     => pixelRow,
                pixelColOut     => pixelCol,
                
                pcEnableIn      => pcEnable,
                xEnableIn       => xEnable,
                yEnableIn       => yEnable,
                
                muxSelBothOut   => muxSelBoth,
                muxSelLoOut     => muxSelLo,
                muxSelHiOut     => muxSelHi
    );

    -- Line code:
    -- bit 0: color mode 0
    -- bit 1: color mode 1
    -- bit 2: address-per-pixel 0
    -- bit 3: address-per-pixel 1
    
    -- Address per pixel
    -- 11 - every 8th
    -- 10 - every 4th
    -- 01 - every 2nd (every other)
    -- 00 - every pixel

    -- 640x480x1 - reads every 8th pixel and every row
    -- videoAddr <= (pixelRow(8 downto 0) & pixelCol(9 downto 3));
    -- reversed layout
    videoAddr <= (pixelCol(9 downto 3) & pixelRow(8 downto 0));
    -- loadPixel <= '1' when pixelCol(2 downto 0) = "000" else '0';

    -- 640x240x1 - reads every 8th pixel and every other row
    -- videoAddr <= (pixelRow(8 downto 1) & '0' & pixelCol(9 downto 3));
    -- loadPixel <= '1' when pixelCol(2 downto 0) = "000" else '0';

    -- 640x120x1 - reads every 8th pixel and every 4th row
    -- videoAddr <= (pixelRow(8 downto 2) & "00" & pixelCol(9 downto 3));
    -- loadPixel <= '1' when pixelCol(2 downto 0) = "000" else '0';

    -- 640x240x1 - reads every 4th pixel and every other row
    -- videoAddr <= (pixelRow(8 downto 1) & pixelCol(9 downto 2));
    -- loadPixel <= '1' when pixelCol(1 downto 0) = "00" else '0';

    ----------------------------------------------------------
    ------              Address bus                    -------
    ----------------------------------------------------------

    lowerMuxComp: entity work.full_mux
    port map( 
           sel          => muxSelBoth & muxSelLo,
           aPort        => x"00",
           bPort        => x"01",
           cPort        => videoAddr(7 downto 0),
           dPort        => programCounter(7 downto 0),
           yPort        => ramAddress(7 downto 0)
    );

    higherMuxComp: entity work.full_mux
    port map (
           sel          => muxSelBoth & muxSelHi,
           aPort        => x"00",
           bPort        => x"01",
           cPort        => videoAddr(15 downto 8),
           dPort        => programCounter(15 downto 8),
           yPort        => ramAddress(15 downto 8)
    );

    memorySelComp: entity work.romram_sel_pld
    port map(
        wr_clk  => memorySelEn,
        a15     => ramAddress(15),
        a14     => ramAddress(14),
        a13     => ramAddress(13),
        d0      => '0',
        d1      => '0',
        d2      => '0',
        d3      => '0',
        d4      => '0',
        d5      => '0',
        d6      => '0',
        d7      => '0',
        rw      => memRdWr,

        rom_en  => romEn,
        ramsel0 => open,
        ramsel1 => open,
        ramsel2 => open,
        ramsel3 => open,
        ramsel4 => open,
        ramsel5 => open,
        ramsel6 => open,
        ramsel7 => open
    );

    ramComp : entity work.sp_ram 
    port map(   iClk    => clkSystem,  -- faster clock to simulate async RAM
                iWrEn   => '0',
                iRamEn  => memRdWr,
                iAddr   => ramAddress,
                iData   => (ramData'range => '0'),
                oData   => ramData);  -- must be same size as input data

    -- Data bus process (from RAM/ROM) - replaces the tri-state databus 
    rambusSelectorProc: process (all)
    begin
        if romEn='0' then 
            databus <= to_01(romData);
        else
            databus <= to_01(ramData);
        end if;        
    end process rambusSelectorProc;

    -- D register process 
    dRegProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            if (dLoad = '1') then
                dReg <= databus;
            end if;
        end if;
    end process dRegProc;

    -- Source bus process - replaces the tri-state bus
    srcBusProc : process (all)
    begin
        case (instReg(1 downto 0)) is
            when "00" => srcBus <= dReg;
            when "01" => srcBus <= dReg;
            when "10" => srcBus <= acReg;
            when "11" => srcBus <= acReg;
            when others => srcBus <= acReg;
        end case;
    end process srcBusProc;

    source <= IMM when instReg(1 downto 0)="00" else
              MEM when instReg(1 downto 0)="01" else
              ACC when instReg(1 downto 0)="10" else
              UNDEF;

    ----------------------------------------------------------
    ------              Pixel Drawing                  -------
    ----------------------------------------------------------

    -- Load Code register process 
    --   uses videoActiveR as clock to load once at the beginning of the video line
    loadCodeProc : process (videoActiveR)
    begin
        if rising_edge(videoActiveR) then
            lineCode <= databus;
        end if;
    end process loadCodeProc;
 
    -- Pixel register process
    --   Holds the 8-bit dataword represting the pixel(s)
    pixelProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            if pixelEn='1' then
                pixelBuffer <= databus;
            end if;
        end if;
    end process pixelProc;

/*
    delayPixelProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA = '1') then
             pixelSel <= (others => '0');
             videoActiveR <= '0';
        elsif (rising_edge(clkVGA)) then
            videoActiveR <= videoActive;              
            pixelSel <= pixelCol(2 downto 0);  -- delay for timing
        end if;
    end process delayPixelProc;
*/
            videoActiveR <= videoActive;              
            pixelSel <= pixelCol(2 downto 0);  -- delay for timing

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

        -- Selection Signals
        H0  => pixelSel(0),
        H1  => pixelSel(1),
        H2  => pixelSel(2),
        
        VIDEN => videoActiveR,

        -- VGA Outputs
        RED1  => vRed(1),   -- VGA_RED(1)
        RED2  => vRed(2),   -- VGA_RED(2)
        RED3  => vRed(3),   -- VGA_RED(3)
        BLU2  => vBlue(2),  -- VGA_BLUE(2)
        BLU3  => vBlue(3),  -- VGA_BLUE(3)
        GRN1  => vGreen(1), -- VGA_GREEN(1)
        GRN2  => vGreen(2), -- VGA_GREEN(2)
        GRN3  => vGreen(3)  -- VGA_GREEN(3)
    );

    vRed(0) <= vRed(1);
    vBlue(1 downto 0) <= vBlue(2) & vBlue(2);
    vGreen(0) <= vGreen(1);

    VGA_RED   <= vRed;
    VGA_BLUE  <= vBlue;
    VGA_GREEN <= vGreen;
    VGA_VS <= vSync;
    VGA_HS <= hSync;

    -- Clocked output for video signals to see if there's a quality change
/*
    videoOutProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA = '1') then
            VGA_RED   <= (others => '0');
            VGA_BLUE  <= (others => '0');
            VGA_GREEN <= (others => '0');
            VGA_VS <= '1';
            VGA_HS <= '1';
        elsif (rising_edge(clkVGA)) then
            if videoActive='1' then
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
    ----------------------------------------------------------
    ------                ROM                          -------
    ----------------------------------------------------------
/*
    romComp : entity work.rom_synth
    port map(   addrIn      => addrRom,
                dataOut     => dataRom);
*/
    romComp : entity work.sp_ram 
    port map(   iClk    => clkSystem,  -- faster clock to simulate async RAM
                iWrEn   => '0',
                iRamEn  => '1',
                iAddr   => ramAddress,
                iData   => (romData'range => '0'),
                oData   => romData);  -- must be same size as input data
    
end architecture Behavioral;
