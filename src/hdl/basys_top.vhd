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

    subtype memModeType is string(1 to 5);
    signal memMode : memModeType;
    signal destMode : memModeType;
    signal aluMode  : memModeType;
    signal srcMode  : memModeType;
    
    --Used to determine when a button press has occured
    signal btnReg    : slv (3 downto 0);
    signal btnPulse  : slv (3 downto 0);

    --Debounced btn signals used to prevent single button presses
    --from being interpreted as multiple button presses.
    signal btnDeBnc         : slv(4 downto 0);

    signal clkVGA           : sl;
    signal clkSystem        : sl;

    signal rstSystem        : sl;
    signal rstVGA           : sl;
    signal rstComponent     : sl;
    signal rstBtn           : sl;
    signal locked           : sl;

    signal videoActive      : sl;
    signal videoActiveR1    : sl;   -- first delay stage
    signal videoActiveR     : sl;   -- second delay stage (VIDEN, lineCode clock)
    signal pixelEn          : sl;
    signal pixelEnAndRst    : sl;
    signal cpuStall         : sl;   -- Branch PLD STALL = pixel enable or ALU wait
    signal aluDone          : sl;   -- Branch PLD ALU_DONE (second ADD/SUB clock)
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
    signal pixelSel1        : slv(2 downto 0) := "000";
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

    signal mapWrN           : sl;   -- /MAP_WR, ROM/RAM map write strobe
    signal romOeN           : sl;   -- ROM /OE
    signal ramOeN           : sl;   -- RAM /OE
    signal mapReg           : slv(7 downto 0) := (others => '0');  -- 74ACT273 map register
    signal mapRun           : sl;   -- map register /MR, from the memory control PLD
    signal ramSel0          : sl;   -- ROM/RAM map, 1 = RAM
    signal ramSel1          : sl;
    signal ramSel2          : sl;
    signal ramSel3          : sl;
    signal ramSel4          : sl;
    signal ramSel5          : sl;
    signal ramSel6          : sl;
    signal ramSel7          : sl;
    signal acLoad           : sl;
    signal xLoad            : sl;
    signal yLoad            : sl;
    signal xEnable          : sl;
    signal yEnable          : sl;
    signal instLoad         : sl;
    signal dLoad            : sl;
    signal memRdWr          : sl;
    signal ramWeN           : sl;   -- RAM /WE, active low
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

    pixelEnAndRst <= pixelEn or rstVGA;
    
    stateMachineProc: entity work.state_pld
    port map(
        clk         => clkVGA,
        pixel_enable => cpuStall,     -- STALL from the Branch PLD
        db_src1     => dataBus(1),-- only used during fetch cycle - contains instruction bit 1
        db_src0     => dataBus(0),-- only used during fetch cycle - contains instruction bit 1 
        mem2        => instReg(4),-- dst/mem access mode
        mem1        => instReg(3),-- dst/mem access mode
        mem0        => instReg(2),-- dst/mem access mode
        db_mem2     => dataBus(4),-- only used during fetch cycle - contains instruction bit 4
        db_mem1     => dataBus(3),-- only used during fetch cycle - contains instruction bit 3
        db_mem0     => dataBus(2),-- only used during fetch cycle - contains instruction bit 2
        src0        => instReg(0),-- source field bit 0 (used in LOAD_IMM)
        branch_block => branchBlock,

        q0          => stateQ0,
        pc_enable   => pcEnable,
        x_enable    => xEnable,
        y_enable    => yEnable,
        load_instr  => instLoad,
        load_imm    => dLoad,
        load_x      => xLoad,
        load_y      => yLoad,
        load_ac     => acLoad,
        mem_rw      => memRdWr
    );

    acNeg  <= acReg(7);

    branchComp : entity work.branch_pld
    port map(
        clk          => clkVGA,
        i7           => instReg(7),
        i6           => instReg(6),
        i5           => instReg(5),
        m2           => instReg(4),
        m1           => instReg(3),
        m0           => instReg(2),
        z_low        => zeroLo,
        z_high       => zeroHi,
        neg          => acNeg,
        pixel_enable => pixelEnAndRst,
        q0           => stateQ0,
        pc_enable    => pcEnable,
        load_pc_low  => loadPcLow,
        load_pc_high => loadPcHigh,
        branch_block => branchBlock,
        alu_done     => aluDone,
        stall        => cpuStall
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
        clk          => clkVGA,

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
        pixel_enable => cpuStall,     -- STALL from the Branch PLD

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
        clk          => clkVGA,

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
        pixel_enable => cpuStall,     -- STALL from the Branch PLD

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
    cpuRegProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA='1') then
            instReg <= x"00";
            dReg    <= x"00";
            acReg   <= x"00";
            xReg    <= x"00";
            yReg    <= x"00";
        elsif rising_edge(clkVGA) then
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
        b              => srcBus(3 downto 0),
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
        b              => srcBus(7 downto 4),
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
           aPort        => dReg,
           bPort        => xReg,
           cPort        => videoAddr(7 downto 0),
           dPort        => programCounter(7 downto 0),
           yPort        => ramAddress(7 downto 0)
    );

    higherMuxComp: entity work.full_mux
    port map (
           sel          => muxSelBoth & muxSelHi,
           aPort        => x"00",
           bPort        => yReg,
           cPort        => videoAddr(15 downto 8),
           dPort        => programCounter(15 downto 8),
           yPort        => ramAddress(15 downto 8)
    );

    -- ROM/RAM map register: 74ACT273, an I/O device at 5000h (write only).
    -- It loads the source bus on the rising edge of /MAP_WR, and /MR
    -- (mapRun from the memory control PLD) clears it to all ROM until the
    -- first clock after power-up.
    mapRegProc : process (mapWrN, mapRun)
    begin
        if mapRun = '0' then
            mapReg <= (others => '0');
        elsif rising_edge(mapWrN) then
            mapReg <= srcBus;
        end if;
    end process mapRegProc;

    ramSel0 <= mapReg(0);
    ramSel1 <= mapReg(1);
    ramSel2 <= mapReg(2);
    ramSel3 <= mapReg(3);
    ramSel4 <= mapReg(4);
    ramSel5 <= mapReg(5);
    ramSel6 <= mapReg(6);
    ramSel7 <= mapReg(7);

    -- Memory read and write strobes (replaces the '32 OR gate).  Every
    -- memory cycle uses the low half of the clock only; see
    -- ATF22V10_MEM_CTRL.pld.
    memCtrlComp: entity work.mem_ctrl_pld
    port map(
        clk         => clkVGA,
        a15         => ramAddress(15),
        a14         => ramAddress(14),
        a13         => ramAddress(13),
        a12         => ramAddress(12),
        ramsel0     => ramSel0,
        ramsel1     => ramSel1,
        ramsel3     => ramSel3,
        ramsel4     => ramSel4,
        ramsel5     => ramSel5,
        ramsel6     => ramSel6,
        ramsel7     => ramSel7,
        ramsel2     => ramSel2,
        rw          => memRdWr,
        pixelEnable => pixelEnAndRst,

        weN         => ramWeN,
        romOeN      => romOeN,
        ramOeN      => ramOeN,
        mapRun      => mapRun
    );
    romEn <= not romOeN;

    -- I/O decode and upper 32K chip enable.  The FPGA RAM model is one
    -- 64K block, so ce_hi_n is not used here, and no I/O devices exist yet.
    ioDecodeComp: entity work.io_decode_pld
    port map(
        we_n        => ramWeN,
        addr_sel    => muxSelBoth,
        addr_sel_hi => muxSelHi,
        pc15        => programCounter(15),
        h9          => pixelCol(9),
        y7          => yReg(7),
        a14         => ramAddress(14),
        a13         => ramAddress(13),
        a12         => ramAddress(12),
        a10         => ramAddress(10),
        a9          => ramAddress(9),
        a8          => ramAddress(8),
        rw          => memRdWr,
        load_imm    => dLoad,

        ce_hi_n     => open,
        map_wr_n    => mapWrN,
        line_rd_n   => open,
        snd_wr_n    => open,
        port_wr_n   => open,
        port_rd_n   => open,
        exp1_n      => open,
        exp2_n      => open
    );

    ramComp : entity work.sp_ram 
    port map(   iClk    => clkSystem,  -- faster clock to simulate async RAM
                iWrEn   => not ramWeN,    -- stand-in for the SRAM's active-low /WE pin
                iRamEn  => '1',
                iAddr   => ramAddress,
                iData   => srcBus,        -- RAM write data comes from the source bus
                oData   => ramData);  -- must be same size as input data

    -- Data bus process (from RAM/ROM) - replaces the tri-state databus 
    --   The model reads every address from the RAM block.  The ROM/RAM
    --   map register clears at power-up with every mapped section set to ROM and no
    --   program writes the map yet, so following romOeN/ramOeN would read
    --   the unwritten ROM block everywhere.  (Before ROM/RAM select rev 03
    --   this process tested rom_en with the wrong polarity, which had the
    --   same effect; see TIMING.md, "Other observations".)  The ROM block
    --   and romEn are kept for when the map is used.
    rambusSelectorProc: process (all)
    begin
        databus <= to_01(ramData);
    end process rambusSelectorProc;
/*
    -- D register process 
    dRegProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            if (dLoad = '1') then
                dReg <= databus;
            end if;
        end if;
    end process dRegProc;
*/
    -- Source bus process - replaces the tri-state bus
    srcBusProc : process (all)
    begin
        case (instReg(1 downto 0)) is
            when "00" => srcBus <= dReg;
            when "01" => srcBus <= dReg;
            when "10" => srcBus <= acReg;
            when "11" => srcBus <= xReg;
            when others => srcBus <= acReg;
        end case;
    end process srcBusProc;

    srcMode  <= " IMM " when instReg(7 downto 5)="00" else
                " MEM " when instReg(7 downto 5)="01" else
                " ACC " when instReg(7 downto 5)="10" else
                "  X  " when instReg(7 downto 5)="11" else
                "UNDEF";


    ----------------------------------------------------------
    ------              Pixel Drawing                  -------
    ----------------------------------------------------------

    -- Load Code register process
    --   An F377 on the system clock, enabled while videoActiveR is low.
    --   It loads the data bus on every clock of the blanking interval and
    --   stops when videoActiveR rises, so it keeps the bus value from the
    --   edge that ends the first byte read of the line (the same edge that
    --   raises videoActiveR).  The colour decoder blanks the output while
    --   videoActiveR is low, so the loads during blanking are not seen.
    --   (Clocking it from videoActiveR raced the data bus by 1 ns.)
    loadCodeProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            if videoActiveR = '0' then
                lineCode <= databus;
            end if;
        end if;
    end process loadCodeProc;
 
    -- Pixel register process
    --   Holds the 8-bit dataword represting the pixel(s)
    pixelProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA='1') then
            pixelBuffer <= x"00";
        elsif rising_edge(clkVGA) then
            if pixelEn='1' then
                pixelBuffer <= databus;
            end if;
        end if;
    end process pixelProc;


    -- Pixel select and video enable delay (one F574, two 4-bit stages)
    --   The Sync PLD reads the byte in clock 1 of each 8-clock group
    --   (PIXEL_ENABLE is registered), so the pixel buffer loads at the end
    --   of clock 1.  H2:H0 and videoActive are delayed two clocks to line
    --   up with it (see VIDEO_TIMING.md).
    delayPixelProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA = '1') then
             pixelSel1 <= (others => '0');
             videoActiveR1 <= '0';
             pixelSel <= (others => '0');
             videoActiveR <= '0';
        elsif (rising_edge(clkVGA)) then
            videoActiveR1 <= videoActive;
            pixelSel1 <= pixelCol(2 downto 0);
            videoActiveR <= videoActiveR1;
            pixelSel <= pixelSel1;
        end if;
    end process delayPixelProc;
/*
            videoActiveR <= videoActive;              
            pixelSel <= pixelCol(2 downto 0);  -- delay for timing
*/
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
