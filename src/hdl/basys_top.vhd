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
           JB           : inout slv(4 downto 0);  -- PmodMicroSD: 0 /CS, 1 MOSI, 2 MISO (in), 3 SCK
           JC           : inout slv(3 downto 0);  -- SNES pads: 0 CLOCK, 1 LATCH, 2 pad 1 DATA (in), 3 pad 2 DATA (in)
           JA           : out   slv(7 downto 0)   -- audio DAC register (to an R-2R ladder)
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
    signal videoActiveR     : sl;   -- second delay stage (VIDEN)
    signal pixelEn          : sl;
    signal modeLdN          : sl;   -- line code register /E (audio slot PLD pin 22)
    signal hVideoActive     : sl;   -- H counter PLD H_VIDEO_ACTIVE (audio DAC clock)
    signal rowA0            : sl;   -- video address A0 from the audio slot PLD (line repeat)
    signal rowA1            : sl;   -- video address A1
    signal rowA7            : sl;   -- video address A7
    signal rowA8            : sl;   -- video address A8
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
    signal romSel           : sl;   -- 1 = the address reads from the ROM (map decode)
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
    signal audioDac         : slv(7 downto 0) := x"80";  -- 74HC574 audio DAC register
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
    signal lineRdN          : sl;   -- /LINE_RD, video line counter read strobe
    signal portWrN          : sl;   -- /PORT_WR, shared port latch clock
    signal portRdN          : sl;   -- /PORT_RD, shared port read
    signal portLatch        : slv(7 downto 0) := x"FF";  -- 74HC574 shared port latch
    signal colN             : slv(7 downto 0);  -- keyboard columns, from the port PLD
    signal keyRowN          : slv(7 downto 0);  -- keyboard rows (the key matrix)
    signal portRows         : slv(7 downto 0);  -- 74F541 inputs: rows, MISO, PS/2 lines
    signal padD6            : sl;   -- port PLD D6 (pad 2 DATA)
    signal padD7            : sl;   -- port PLD D7 (pad 1 DATA)
    signal padDEn           : sl;   -- port PLD D6/D7 output enable
    signal mouseOn          : sl;   -- SW15 = 1: the PS/2 port is the mouse
    signal ps2ClkR          : slv(1 downto 0) := "11";  -- PS/2 lines, synchronized
    signal ps2DataR         : slv(1 downto 0) := "11";
    signal sdMisoR          : slv(1 downto 0) := "11";
    signal pad1R            : slv(1 downto 0) := "11";
    signal pad2R            : slv(1 downto 0) := "11";
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
    signal srcEn            : std_logic;   -- branch PLD pin 16: source F541s drive the data bus

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
        stall        => cpuStall,
        srcEn        => srcEn,
        cout         => carryout,
        carry        => open
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
                modeLdNOut      => modeLdN,
                hVideoActiveOut => hVideoActive,
                rowA0Out        => rowA0,
                rowA1Out        => rowA1,
                rowA7Out        => rowA7,
                rowA8Out        => rowA8,
                lc2In           => lineCode(2),
                lc3In           => lineCode(3),
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
    -- videoAddr <= (pixelCol(9 downto 3) & pixelRow(8 downto 0));
    -- loadPixel <= '1' when pixelCol(2 downto 0) = "000" else '0';

    -- Line repeat as built (2026-10-16, audio slot PLD revision 03): bits
    -- 3:2 of the line code pick 1x (00), 2x (01) or 4x (10 and 11).  The
    -- audio slot PLD makes A0, A1, A7 and A8 of the row address; A2-A6
    -- are V2-V6.  In the blanking reads (groups 32-47) they are V0, V1,
    -- V7 and V8 whatever the line code is.
    --     1x: A8:A0 = V8:V0
    --     2x: A8 = 1, A7:A1 = V7:V1, A0 = V8
    --     4x: A8 = 1, A7 = 1, A6:A2 = V6:V2, A1 = V8, A0 = V7
    -- See VIDEO.md (line repeat).
    videoAddr(15 downto 9) <= pixelCol(9 downto 3);
    videoAddr(8)           <= rowA8;
    videoAddr(7)           <= rowA7;
    videoAddr(6 downto 2)  <= pixelRow(6 downto 2);
    videoAddr(1)           <= rowA1;
    videoAddr(0)           <= rowA0;

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
        a11         => ramAddress(11),
        a10         => ramAddress(10),
        srcEn       => srcEn,

        weN         => ramWeN,
        romOeN      => romOeN,
        ramOeN      => ramOeN,
        mapRun      => mapRun
    );
    romEn <= not romOeN;

    -- I/O decode and upper 32K chip enable.  The FPGA RAM model is one
    -- 64K block, so ce_hi_n is not used here.  The devices built so far are
    -- the map register (/MAP_WR) and the line read buffer (/LINE_RD).
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
        a11         => ramAddress(11),
        load_imm    => dLoad,

        ce_hi_n     => open,
        map_wr_n    => mapWrN,
        line_rd_n   => lineRdN,
        port_wr_n   => portWrN,
        port_rd_n   => portRdN,
        exp1_n      => open,
        exp2_n      => open
    );

    ramComp : entity work.sp_ram 
    generic map( initFile => "ram.mem" )
    port map(   iClk    => clkSystem,  -- faster clock to simulate async RAM
                iWrEn   => not ramWeN,    -- stand-in for the SRAM's active-low /WE pin
                iRamEn  => '1',
                iAddr   => ramAddress,
                iData   => srcBus,        -- RAM write data: the source bus is the data bus in EXEC
                oData   => ramData);  -- must be same size as input data

    -- ROM or RAM on the read bus: the section decode of the memory control
    -- PLD's /ROM_OE and /RAM_OE (map bit n = 1 reads RAM), without the clock
    -- phase, so the bus does not change at the clock edge that latches it.
    -- A video read (pixelEnAndRst) always reads the RAM (memory control PLD
    -- revision 04).  In the I/O window x5000-x53FF neither memory drives the
    -- bus; the model leaves the RAM there, as before.  x5400-x5FFF is mapped
    -- by ramSel2 (memory control PLD revision 05).
    romSelProc: process (all)
    begin
        if pixelEnAndRst = '1' then
            romSel <= '0';
        else
            case ramAddress(15 downto 13) is
                when "000"  => romSel <= not ramSel0;
                when "001"  => romSel <= not ramSel1;
                when "010"  => romSel <= not ramSel2 and (not ramAddress(12) or ramAddress(11) or ramAddress(10));
                when "011"  => romSel <= not ramSel3;
                when "100"  => romSel <= not ramSel4;
                when "101"  => romSel <= not ramSel5;
                when "110"  => romSel <= not ramSel6;
                when others => romSel <= not ramSel7;
            end case;
        end if;
    end process romSelProc;

    -- Data bus process (from RAM/ROM) - replaces the tri-state databus 
    --   Reads follow the ROM/RAM map (romSel).  The map clears to all ROM
    --   at power-up, so the CPU starts in the ROM's boot loader, which
    --   copies the program and library into the RAM and maps every section
    --   to RAM (see ROM.md).
    --
    --   Video line read: a 74F541 enabled by /LINE_RD (an I/O read at
    --   x5000-x50FF) drives the upper 8 bits of the V counter, V9:V2, onto
    --   the data bus.  The shared port (x5200-x52FF) is the 74F541 of the
    --   key rows on even addresses and the port PLD on odd ones.  The memory control PLD keeps the RAM and ROM off the
    --   bus in the I/O window, so the buffer is the only driver there.
    ----------------------------------------------------------
    ------    Shared port at 5200h (IO.md)            -------
    ----------------------------------------------------------
    -- Port latch: 74HC574, loads the source bus on the rising edge of
    -- /PORT_WR.  The real part powers up random; the boot loader writes
    -- it first.  bit 0 SCK / pad CLOCK, bit 1 MOSI / pad LATCH, bit 2 SD
    -- /CS (0 also holds the PS/2 CLK low), bit 3 (0 holds the PS/2 DATA
    -- low), bits 7:4 keyboard column.
    portLatchProc : process (portWrN)
    begin
        if rising_edge(portWrN) then
            portLatch <= srcBus;
        end if;
    end process portLatchProc;

    portPldComp: entity work.port_pld
    port map(
        portRdN => portRdN,
        a0      => ramAddress(0),
        k0      => portLatch(4),
        k1      => portLatch(5),
        k2      => portLatch(6),
        k3      => portLatch(7),
        pad1    => pad1R(1),
        pad2    => pad2R(1),
        col0N   => colN(0),
        col1N   => colN(1),
        col2N   => colN(2),
        col3N   => colN(3),
        col4N   => colN(4),
        col5N   => colN(5),
        col6N   => colN(6),
        col7N   => colN(7),
        d6      => padD6,
        d7      => padD7,
        dEn     => padDEn
    );

    -- The key matrix: the board's USB keyboard (PS/2) while SW15 = 0
    keyMatrixComp: entity work.ps2_key_matrix
    port map(
        clk     => clkVGA,
        rst     => rstSystem or mouseOn,
        ps2Clk  => PS2_CLK,
        ps2Data => PS2_DATA,
        colN    => colN,
        rowN    => keyRowN
    );

    -- SW15 = 1: the PS/2 port is the Placard's mouse port instead.  The
    -- latch's /CS and bit 3 pull the lines low through Schottky diodes;
    -- here they are open-drain pins (the xdc has the pull-ups).
    mouseOn  <= dipRR(15);
    PS2_CLK  <= '0' when mouseOn = '1' and portLatch(2) = '0' else 'Z';
    PS2_DATA <= '0' when mouseOn = '1' and portLatch(3) = '0' else 'Z';

    -- SD card (PmodMicroSD on JB) and SNES pads (JC)
    JB(0) <= portLatch(2);      -- /CS
    JB(1) <= portLatch(1);      -- MOSI
    JB(2) <= 'Z';               -- MISO (pull-up in the xdc)
    JB(3) <= portLatch(0);      -- SCK
    JB(4) <= 'Z';
    JC(0) <= portLatch(0);      -- pad CLOCK (both pads)
    JC(1) <= portLatch(1);      -- pad LATCH (both pads)
    JC(2) <= 'Z';               -- pad 1 DATA (pull-up in the xdc)
    JC(3) <= 'Z';               -- pad 2 DATA

    -- input pins are synchronized (the real 74F541 is just a buffer)
    portSyncProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            ps2ClkR  <= ps2ClkR(0)  & to_x01(PS2_CLK);
            ps2DataR <= ps2DataR(0) & to_x01(PS2_DATA);
            sdMisoR  <= sdMisoR(0)  & to_x01(JB(2));
            pad1R    <= pad1R(0)    & to_x01(JC(2));
            pad2R    <= pad2R(0)    & to_x01(JC(3));
        end if;
    end process portSyncProc;

    -- 74F541 inputs: the rows, with MISO on row 7 and the PS/2 DATA and
    -- CLK lines on rows 6 and 5 (Schottky diodes: either side pulls low)
    portRows(7) <= keyRowN(7) and sdMisoR(1);
    portRows(6) <= keyRowN(6) and (ps2DataR(1) or not mouseOn);
    portRows(5) <= keyRowN(5) and (ps2ClkR(1) or not mouseOn);
    portRows(4 downto 0) <= keyRowN(4 downto 0);

    rambusSelectorProc: process (all)
    begin
        if portRdN = '0' then
            if padDEn = '1' then
                -- odd address: the port PLD drives D7/D6; D5:D0 float
                -- (the model reads them as 1)
                databus <= padD7 & padD6 & "111111";
            else
                databus <= portRows;    -- even address: the 74F541
            end if;
        elsif lineRdN = '0' then
            databus(0) <= pixelRow(2);  -- '541 A1 = V2
            databus(1) <= pixelRow(3);  -- '541 A2 = V3
            databus(2) <= pixelRow(4);  -- '541 A3 = V4
            databus(3) <= pixelRow(5);  -- '541 A4 = V5
            databus(4) <= pixelRow(6);  -- '541 A5 = V6
            databus(5) <= pixelRow(7);  -- '541 A6 = V7
            databus(6) <= pixelRow(8);  -- '541 A7 = V8
            databus(7) <= pixelRow(9);  -- '541 A8 = V9
        elsif romSel = '1' then
            databus <= to_01(romData);
        else
            databus <= to_01(ramData);
        end if;
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
    -- Source bus process - replaces the tri-state bus.  On the board the
    -- source bus and the memory data bus are one bus (no write-data
    -- buffer): the source '138 is enabled only in EXEC with pixel enable
    -- low (srcEn), and the memory control PLD blocks CPU reads then.  The
    -- model keeps the two apart because it has no tri-state buses.
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
    --   An F377 on the system clock.  /E is /MODE_LD from the audio slot
    --   PLD (low for all of group 45) and D7:D0 come from the pixel buffer
    --   outputs, not the data bus.  The video circuit reads the line's
    --   mode byte (5A00h + V8:V0) into the pixel buffer in clock 1 of
    --   group 45, and this register copies it on clocks 2-7, then holds it
    --   for the rest of the line.  So the mode byte no longer takes the
    --   first byte column of the screen (see VIDEO.md).  Q1:Q0 go to the
    --   color decoder, Q3:Q2 to the audio slot PLD (line repeat).
    --   (Before: enabled while videoActiveR was low, keeping the bus value
    --   of the first pixel read of the line, byte column 0.)
    loadCodeProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            if modeLdN = '0' then
                lineCode <= pixelBuffer;
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

    -- Audio DAC register (74HC574, see SOUND.md)
    --   Clocked by the rising edge of H_VIDEO_ACTIVE (H counter PLD pin
    --   22, start of group 48).  The audio sample was read into the pixel
    --   buffer in group 46 or 47 (after the mode byte in group 45), and
    --   the pixel buffer next loads at the end of clock 1 of group 48, so
    --   its outputs are steady at this edge.  (Until 2026-10-16 the sample
    --   was read in group 38/39 and the clock was HSYNC, group 42.)
    --   Q7:Q0 drive the R-2R ladder; an HC part so the outputs swing rail
    --   to rail.  The FPGA model starts
    --   at 80h (silence); the real part powers up random for one line.
    audioDacProc : process (hVideoActive)
    begin
        if rising_edge(hVideoActive) then
            audioDac <= pixelBuffer;
        end if;
    end process audioDacProc;

    JA <= audioDac;


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
    -- The ROM has its own initialization file (boot loader, standard
    -- library and font, and the program; see ROM.md).  Writes always go
    -- to the RAM, so the ROM block is never written.
    romComp : entity work.sp_ram 
    generic map( initFile => "rom.mem" )
    port map(   iClk    => clkSystem,  -- faster clock to simulate async RAM
                iWrEn   => '0',
                iRamEn  => '1',
                iAddr   => ramAddress,
                iData   => (romData'range => '0'),
                oData   => romData);  -- must be same size as input data
    
end architecture Behavioral;
