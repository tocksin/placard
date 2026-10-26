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

    signal viden            : sl;   -- Sync PLD VIDEN (color decoder video enable)
    signal pixelEn          : sl;
    signal pixLdN           : sl;   -- pixel buffer /E (Branch PLD pin 15)
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
    signal cartData         : slv(7 downto 0);  -- the ROM cartridge's byte (EEPROM, SRAM or bus charge)
    signal cartEeDrive      : sl;   -- 1 = the cartridge EEPROMs drive the data bus (loading)
    signal dipR             : slv(15 downto 0);
    signal dipRR            : slv(15 downto 0);
    signal dipEn            : sl;

    signal ledR             : slv(15 downto 0);
    signal ledEn            : sl;

    signal ssegR            : slv(15 downto 0);    -- 7-segment digits 3-0 (4 bits each)
    signal ssegCnt          : unsigned(17 downto 0) := (others => '0');
    signal ssegNib          : slv(3 downto 0);

    -- PS/2 sniffer (debug only, not part of the Placard): decodes every
    -- byte on the PS/2 pins by itself, so the display shows whether bytes
    -- reach the FPGA at all, whatever the CPU and the receiver PLD do
    signal snfClkD          : sl := '1';
    signal snfShift         : slv(10 downto 0) := (others => '0');
    signal snfBits          : unsigned(3 downto 0) := (others => '0');
    signal snfIdle          : unsigned(15 downto 0) := (others => '0');
    signal snfByte          : slv(7 downto 0) := (others => '0');
    signal snfCount         : unsigned(7 downto 0) := (others => '0');
    signal cpuRdR           : sl := '0';
    signal cpuRdToggle      : sl := '0';
    signal ps2ClkDrive      : sl;

    signal sync             : sl;
    signal blank            : sl;
    
    
    signal pixelBuffer      : slv(7 downto 0) := x"00";
    signal loadPixel        : sl;
    signal loadCode         : sl;
    signal lineCode         : slv(7 downto 0) := x"00";
    signal audioDac         : slv(7 downto 0) := x"80";  -- 74HC574 audio DAC register
    signal vRed             : slv(3 downto 0);
    signal vBlue            : slv(3 downto 0);
    signal vGreen           : slv(3 downto 0);
    signal tintRed          : sl;   -- row tint on (line code Q4 and VIDEN)
    signal tintGreen        : sl;   -- line code Q5 and VIDEN
    signal tintBlue         : sl;   -- line code Q6 and VIDEN

    -- one DAC channel plus the row tint (+4 of 15), held at 15
    function tintAdd(v : slv(3 downto 0); tint : sl) return slv is
        variable sum : unsigned(4 downto 0);
    begin
        if tint = '0' then
            return v;
        end if;
        sum := ('0' & unsigned(v)) + 4;
        if sum(4) = '1' then
            return "1111";
        end if;
        return slv(sum(3 downto 0));
    end function tintAdd;
    
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
    signal pSck             : sl;   -- port PLD register bit 0: SCK, pad CLOCK
    signal pMosi            : sl;   -- bit 1: MOSI, pad LATCH
    signal pCs              : sl;   -- bit 2: SD /CS, 0 also holds the mouse's CLK
    signal pDholdN          : sl;   -- bit 3: 0 holds the PS/2 DATA line
    signal pK0              : sl;   -- bit 4: 0 holds the PS/2 keyboard's CLK
    signal portD5           : sl;   -- port PLD D5 (RXCLK)
    signal portD6           : sl;   -- port PLD D6 (pad 2 DATA)
    signal portD7           : sl;   -- port PLD D7 (MISO or pad 1 DATA)
    signal portD5En         : sl;   -- and their output enables
    signal portD6En         : sl;
    signal portD7En         : sl;
    signal rxClk            : sl;   -- RXCLK: the free PS/2 device's clock (the two lines diode-ORed)
    signal rxData           : slv(7 downto 0);  -- PS/2 receiver PLD: the byte
    signal rxDEn            : sl;   -- its enable (a read of x5202)
    signal rxAN             : sl;   -- the receiver's /A pin (D7 of x5203: 0 = ready)
    signal rxAEn            : sl;
    signal rxB              : sl;   -- the receiver's B pin (the inhibit) and its enable
    signal rxBEn            : sl;
    signal rxInhibit        : sl;   -- 1 = the receiver holds the PS/2 clock lines low
    signal mouseOn          : sl;   -- SW15 = 1: the PS/2 port is the mouse
    signal kbdOn            : sl;   -- SW14 = 1 (SW15 = 0): the PS/2 port is the PS/2 keyboard socket
    signal ps2ClkR          : slv(1 downto 0) := "11";  -- PS/2 lines, synchronized
    signal ps2DataR         : slv(1 downto 0) := "11";
    signal ps2ClkF          : sl := '1';    -- PS/2 CLK, glitch-filtered (the receiver's clock)
    signal ps2DataF         : sl := '1';    -- PS/2 DATA, glitch-filtered
    signal ps2DataD         : slv(3 downto 0) := "1111";  -- ps2DataF delayed: the bit before the CLK edge
    signal ps2ClkCnt        : unsigned(4 downto 0) := (others => '0');
    signal ps2DataCnt       : unsigned(4 downto 0) := (others => '0');
    signal sdMisoR          : slv(1 downto 0) := "11";
    signal pad1R            : slv(1 downto 0) := "11";
    signal pad2R            : slv(1 downto 0) := "11";
    signal romOeN           : sl;   -- ROM /OE
    signal ramOeN           : sl;   -- RAM /OE
    signal mapReg           : slv(7 downto 0) := (others => '0');  -- 74ACT273 map register
    signal run              : sl;   -- RUN from the ROM cartridge: map register /MR, memory control pin 17, IR PLD pin 11
    signal stall            : sl;   -- STALL_OUT from the ROM cartridge: State PLD pin 2, PC PLDs pin 14
    signal ramSel0          : sl;   -- ROM/RAM map, 1 = RAM
    signal ramSel1          : sl;
    signal ramSel2          : sl;
    signal ramSel3          : sl;
    signal ramSel4          : sl;
    signal ramSel5          : sl;
    signal ramSel6          : sl;
    signal ramSel7          : sl;
    signal acLoadN          : sl;   -- State PLD strobes, active low (F377 /E)
    signal xLoadN           : sl;
    signal yLoadN           : sl;
    signal xEnable          : sl;
    signal yEnable          : sl;
    signal instLoadN        : sl;
    signal dLoadN           : sl;
    signal memRdWr          : sl;
    signal ramWeN           : sl;   -- RAM /WE, active low
    signal srcBus           : slv(7 downto 0);
    signal srcEnN           : std_logic;   -- branch PLD pin 16: low = source F541s drive the data bus
    signal acSelN           : std_logic;   -- audio slot PLD pin 21: low = AC source F541 selected

    signal dReg             : slv(7 downto 0) := x"00";
    signal instReg          : slv(7 downto 0);   -- IR PLD outputs I7:I0
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
            -- LD15-LD5 show their switches; LD4-LD0 the PS/2 debug lines
            ledR <= dipRR(15 downto 5) & cpuRdToggle & ps2ClkDrive & rxInhibit
                    & ps2DataF & ps2ClkF;
        end if;
    end process ledProcess;

    LED <= ledR;

    ----------------------------------------------------------
    ------        7-segment display: PS/2 debug        -------
    ----------------------------------------------------------
    -- Left two digits: the last byte the sniffer decoded on the PS/2
    -- pins.  Right two digits: how many bytes it has decoded (mod 256).
    -- LD0 PS/2 CLK, LD1 PS/2 DATA (filtered), LD2 the receiver holds the
    -- clock (a byte waits for the CPU), LD3 the FPGA drives PS/2 CLK low,
    -- LD4 toggles on every CPU read of the byte (x5202).
    ssegR <= snfByte & slv(snfCount);

    snifferProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            snfClkD <= ps2ClkF;
            if ps2ClkDrive = '1' then                        -- the FPGA holds the clock: not a bit
                snfBits <= (others => '0');
                snfIdle <= (others => '0');
            elsif snfClkD = '1' and ps2ClkF = '0' then       -- a falling edge: a bit
                snfIdle  <= (others => '0');
                snfShift <= ps2DataF & snfShift(10 downto 1);
                if snfBits = 10 then
                    snfBits  <= (others => '0');
                    snfByte  <= snfShift(9 downto 2);   -- d7..d0 (bit 0 start, 9 parity, 10 stop)
                    snfCount <= snfCount + 1;
                else
                    snfBits <= snfBits + 1;
                end if;
            elsif snfIdle = 50000 then                       -- 2 ms without a clock: start over
                snfBits <= (others => '0');
            else
                snfIdle <= snfIdle + 1;
            end if;
            cpuRdR <= '0';
            if portRdN = '0' and ramAddress(1) = '1' and ramAddress(0) = '0' then
                cpuRdR <= '1';
                if cpuRdR = '0' then
                    cpuRdToggle <= not cpuRdToggle;
                end if;
            end if;
        end if;
    end process snifferProc;

    ssegProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            ssegCnt <= ssegCnt + 1;
            case ssegCnt(17 downto 16) is
                when "00"   => SSEG_AN <= "1110"; ssegNib <= ssegR(3 downto 0);
                when "01"   => SSEG_AN <= "1101"; ssegNib <= ssegR(7 downto 4);
                when "10"   => SSEG_AN <= "1011"; ssegNib <= ssegR(11 downto 8);
                when others => SSEG_AN <= "0111"; ssegNib <= ssegR(15 downto 12);
            end case;
        end if;
    end process ssegProc;

    -- segments g..a active low, decimal point off
    with ssegNib select SSEG_CA <=
        "11000000" when x"0", "11111001" when x"1", "10100100" when x"2",
        "10110000" when x"3", "10011001" when x"4", "10010010" when x"5",
        "10000010" when x"6", "11111000" when x"7", "10000000" when x"8",
        "10010000" when x"9", "10001000" when x"A", "10000011" when x"B",
        "11000110" when x"C", "10100001" when x"D", "10000110" when x"E",
        "10001110" when others;

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
        pixel_enable => stall,        -- STALL_OUT from the cartridge (Branch PLD STALL, or held while loading)
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
        load_instr_n => instLoadN,
        load_imm_n  => dLoadN,
        load_x_n    => xLoadN,
        load_y_n    => yLoadN,
        load_ac_n   => acLoadN,
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
        srcEnN       => srcEnN,
        cout         => carryout,
        carry        => open,
        pix_ld_n     => pixLdN
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
        pixel_enable => stall,        -- STALL_OUT from the cartridge

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
        pixel_enable => stall,        -- STALL_OUT from the cartridge

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
    
    -- Instruction register: an ATF22V10C-7 (ATF22V10_IR.pld) in place of
    -- the 74F377.  It loads the opcode in FETCH and holds 02h (ld ac, ac)
    -- while RUN is low, so the CPU only walks the image while the
    -- cartridge loads.  Its registers power up 00h (no reset pin).
    irComp : entity work.ir_pld
    port map(
        clk          => clkVGA,
        d0           => dataBus(0),
        d1           => dataBus(1),
        d2           => dataBus(2),
        d3           => dataBus(3),
        d4           => dataBus(4),
        d5           => dataBus(5),
        d6           => dataBus(6),
        d7           => dataBus(7),
        load_instr_n => instLoadN,
        run          => run,

        i0           => instReg(0),
        i1           => instReg(1),
        i2           => instReg(2),
        i3           => instReg(3),
        i4           => instReg(4),
        i5           => instReg(5),
        i6           => instReg(6),
        i7           => instReg(7)
    );

    -- All CPU registers process 
    cpuRegProc : process (clkVGA, rstVGA)
    begin
        if (rstVGA='1') then
            dReg    <= x"00";
            acReg   <= x"00";
            xReg    <= x"00";
            yReg    <= x"00";
        elsif rising_edge(clkVGA) then
            if (dLoadN='0') then
                dReg <= databus;
            end if;
            if (acLoadN='0') then
                acReg <= aluResult;
            end if;
            if (xLoadN = '0') then
                xReg <= aluResult;
            end if;
            if (yLoadN = '0') then
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
                videnOut        => viden,
                pixelEnOut      => pixelEn,
                modeLdNOut      => modeLdN,
                hVideoActiveOut => hVideoActive,
                rowA0Out        => rowA0,
                rowA1Out        => rowA1,
                rowA7Out        => rowA7,
                rowA8Out        => rowA8,
                lc2In           => lineCode(2),
                lc3In           => lineCode(3),
                lc7In           => lineCode(7),
                i1In            => instReg(1),
                acSelNOut       => acSelN,
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
    -- See docs/VIDEO.md (line repeat).
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

    -- RUN comes from the ROM cartridge (cartridge.vhd, docs/ROM.md,
    -- "Loading the cartridge").  It is low for about 33 ms after power-up
    -- while the cartridge copies its EEPROMs into its SRAM, stalling the
    -- CPU at each address the PC reaches; then the CPU runs from x0000.

    -- ROM/RAM map register: 74ACT273, an I/O device at 5000h (write only).
    -- It loads the source bus on the rising edge of /MAP_WR, and /MR
    -- (RUN) clears it to all ROM until the cartridge is loaded.
    mapRegProc : process (mapWrN, run)
    begin
        if run = '0' then
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
        srcEnN      => srcEnN,
        run         => run,

        weN         => ramWeN,
        romOeN      => romOeN,
        ramOeN      => ramOeN
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
        load_imm_n  => dLoadN,

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
        elsif run = '0' then
            romSel <= '1';      -- loading: only the cartridge is on the bus
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
    --   Reads follow the ROM/RAM map (romSel).  The map is clear (all ROM)
    --   while RUN is low, so after the cartridge loads, the CPU starts in
    --   the ROM's boot loader (see docs/ROM.md).  While the cartridge
    --   loads, its EEPROMs drive the bus (cartEeDrive).
    --
    --   Video line read: a 74F541 enabled by /LINE_RD (an I/O read at
    --   x5000-x50FF) drives the upper 8 bits of the V counter, V9:V2, onto
    --   the data bus.  The shared port (x5200-x52FF) is the port PLD
    --   while A1 = 0 and the PS/2 receiver PLD while A1 = 1.  The memory control PLD keeps the RAM and ROM off the
    --   bus in the I/O window, so the buffer is the only driver there.
    ----------------------------------------------------------
    ------    Shared port at 5200h (docs/IO.md)            -------
    ----------------------------------------------------------
    -- Port PLD (rev 04): the output register loads D4:D0 of the source
    -- bus on the rising edge of /PORT_WR and clears at power-up (the port
    -- rests at EB).  bit 0 SCK / pad CLOCK, bit 1 MOSI / pad LATCH, bit 2
    -- SD /CS (0 also holds the mouse's CLK low), bit 3 (0 holds the PS/2
    -- DATA low), bit 4 (0 holds the PS/2 keyboard's CLK low).  It reads
    -- MISO, the pads' DATA and RXCLK on D7:D5 while A1 = 0.
    portPldComp: entity work.port_pld
    port map(
        portWrN => portWrN,
        portRdN => portRdN,
        a0      => ramAddress(0),
        d0      => srcBus(0),
        d1      => srcBus(1),
        d2      => srcBus(2),
        d3      => srcBus(3),
        d4      => srcBus(4),
        pad1    => pad1R(1),
        pad2    => pad2R(1),
        rxclk   => rxClk,
        miso    => sdMisoR(1),
        a1      => ramAddress(1),
        k0      => pK0,
        dholdN  => pDholdN,
        sdcs    => pCs,
        mosi    => pMosi,
        sck     => pSck,
        d5      => portD5,
        d6      => portD6,
        d7      => portD7,
        d5En    => portD5En,
        d6En    => portD6En,
        d7En    => portD7En
    );

    -- PS/2 receiver PLD (rev 02): clocked by RXCLK, the clock line of the
    -- device the port register has let go (on the board the two clock
    -- lines are diode-ORed with a 22k pull-down; here there is one PS/2
    -- socket, so RXCLK is its clock line while the device is free).  The
    -- byte reads at x5202, the ready flag (D7 = 0) at x5203; a write to
    -- either re-arms it.  After the 11th clock its B pin drives the
    -- clock lines low (the inhibit) until the re-arm.
    ps2PldComp: entity work.ps2_pld
    port map(
        rxclk   => rxClk,
        pdata   => ps2DataD(3) or not (mouseOn or kbdOn),
        portRdN => portRdN,
        portWrN => portWrN,
        a0      => ramAddress(0),
        a1      => ramAddress(1),
        b       => rxB,
        aN      => rxAN,
        d0      => rxData(0),
        d1      => rxData(1),
        d2      => rxData(2),
        d3      => rxData(3),
        d4      => rxData(4),
        d5      => rxData(5),
        d6      => rxData(6),
        d7      => rxData(7),
        dEn     => rxDEn,
        aEn     => rxAEn,
        bEn     => rxBEn
    );
    rxInhibit <= rxBEn and not rxB;
    rxClk     <= ps2ClkF when (mouseOn or kbdOn) = '1' else '0';

    -- SW15 = 1: the PS/2 port is the Placard's mouse port.  The register's
    -- /CS and bit 3 pull the lines low through Schottky diodes, as does
    -- the receiver's inhibit; here they are open-drain pins (the xdc has
    -- the pull-ups).
    -- SW14 = 1 (SW15 = 0): it is the PS/2 keyboard socket (the lower half
    -- of J5): register bit 4 holds its CLK, bit 3 the shared DATA, so the
    -- board's USB keyboard (which its host presents as a PS/2 keyboard)
    -- goes to the driver in placard_ps2.asm.  Both off: no PS/2 device.
    mouseOn  <= dipRR(15);
    kbdOn    <= dipRR(14) and not dipRR(15);
    ps2ClkDrive <= '1' when (mouseOn = '1' and pCs = '0') or
                            (kbdOn = '1' and pK0 = '0') or
                            ((mouseOn = '1' or kbdOn = '1') and rxInhibit = '1') else '0';
    PS2_CLK  <= '0' when ps2ClkDrive = '1' else 'Z';
    PS2_DATA <= '0' when (mouseOn = '1' or kbdOn = '1') and pDholdN = '0' else 'Z';

    -- SD card (PmodMicroSD on JB) and SNES pads (JC)
    JB(0) <= pCs;               -- /CS
    JB(1) <= pMosi;             -- MOSI
    JB(2) <= 'Z';               -- MISO (pull-up in the xdc)
    JB(3) <= pSck;              -- SCK
    JB(4) <= 'Z';
    JC(0) <= pSck;              -- pad CLOCK (both pads)
    JC(1) <= pMosi;             -- pad LATCH (both pads)
    JC(2) <= 'Z';               -- pad 1 DATA (pull-up in the xdc)
    JC(3) <= 'Z';               -- pad 2 DATA

    -- input pins are synchronized (the real PLDs read the lines directly)
    portSyncProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            ps2ClkR  <= ps2ClkR(0)  & to_x01(PS2_CLK);
            ps2DataR <= ps2DataR(0) & to_x01(PS2_DATA);
            -- The PS/2 lines are slow (open drain, pull-ups) and the
            -- receiver is clocked by CLK, so a little noise on an edge
            -- would clock it twice.  A line only changes here after 24
            -- clocks (about 1 us) of the new level.  DATA is then used a
            -- few clocks late, so the receiver takes the bit that was on
            -- DATA before CLK rose even if the device changes DATA right
            -- at the rising edge.  (The board's PLD reads the lines
            -- directly; this is the FPGA model only.)
            if ps2ClkR(1) = ps2ClkF then
                ps2ClkCnt <= (others => '0');
            elsif ps2ClkCnt = 23 then
                ps2ClkF   <= ps2ClkR(1);
                ps2ClkCnt <= (others => '0');
            else
                ps2ClkCnt <= ps2ClkCnt + 1;
            end if;
            if ps2DataR(1) = ps2DataF then
                ps2DataCnt <= (others => '0');
            elsif ps2DataCnt = 23 then
                ps2DataF   <= ps2DataR(1);
                ps2DataCnt <= (others => '0');
            else
                ps2DataCnt <= ps2DataCnt + 1;
            end if;
            ps2DataD <= ps2DataD(2 downto 0) & ps2DataF;
            sdMisoR  <= sdMisoR(0)  & to_x01(JB(2));
            pad1R    <= pad1R(0)    & to_x01(JC(2));
            pad2R    <= pad2R(0)    & to_x01(JC(3));
        end if;
    end process portSyncProc;

    rambusSelectorProc: process (all)
    begin
        if portRdN = '0' then
            -- the shared port: bits no chip drives float (the model reads
            -- them as 1, like the board's pull-ups)
            databus <= (others => '1');
            if rxDEn = '1' then
                databus <= rxData;              -- x5202: the receiver's byte
            end if;
            if rxAEn = '1' then
                databus(7) <= rxAN;             -- x5203: 0 = a byte is ready
            end if;
            if portD7En = '1' then
                databus(7) <= portD7;           -- x5200 MISO, x5201 pad 1
            end if;
            if portD6En = '1' then
                databus(6) <= portD6;           -- x5201 pad 2
            end if;
            if portD5En = '1' then
                databus(5) <= portD5;           -- x5200, x5201: RXCLK
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
        elsif cartEeDrive = '1' then
            databus <= to_01(cartData);     -- loading: the cartridge EEPROMs
        elsif romSel = '1' then
            databus <= to_01(cartData);     -- the cartridge SRAM (or, loading, the bus charge)
        else
            databus <= to_01(ramData);
        end if;
    end process rambusSelectorProc;
/*
    -- D register process 
    dRegProc : process (clkVGA)
    begin
        if rising_edge(clkVGA) then
            if (dLoadN = '0') then
                dReg <= databus;
            end if;
        end if;
    end process dRegProc;
*/
    -- Source bus process - replaces the tri-state bus.  On the board the
    -- source bus and the memory data bus are one bus (no write-data
    -- buffer): the two source F541s (D and AC; X is no longer a source)
    -- are enabled only in EXEC with pixel enable low (/OE1 = srcEnN), and
    -- the memory control PLD blocks CPU reads then.  /OE2 picks the one:
    -- instruction bit 1 for D, acSelN (= not bit 1, audio slot PLD) for
    -- AC, so source codes 00 and 01 are D and 10 and 11 are AC.  The
    -- model keeps the two buses apart because it has no tri-state buses,
    -- and drives the selected register whether or not srcEnN is low.
    srcBusProc : process (all)
    begin
        if acSelN = '0' then
            srcBus <= acReg;
        else
            srcBus <= dReg;
        end if;
    end process srcBusProc;

    srcMode  <= " IMM " when instReg(7 downto 5)="00" else
                " MEM " when instReg(7 downto 5)="01" else
                " ACC " when instReg(7 downto 5)="10" else
                " ACC " when instReg(7 downto 5)="11" else
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
    --   first byte column of the screen (see docs/VIDEO.md).  Q1:Q0 go to the
    --   color decoder, Q3:Q2 to the audio slot PLD (line repeat), Q6:Q4 to
    --   the row tint resistors and Q7 to the H counter PLD (blank line).
    --   A 74HCT377 since 2026-10-22, for the tint drive.
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
            if pixLdN='0' then        -- /E from the Branch PLD's /PIX_LD
                pixelBuffer <= databus;
            end if;
        end if;
    end process pixelProc;

    -- Audio DAC register (74HC574, see docs/SOUND.md)
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


    -- Pixel select and video enable (2026-10-19)
    --   The color decoder takes H2:H0 and VIDEN straight from the Sync PLD
    --   (revision 08).  H2:H0 runs two clocks behind the 8-clock group
    --   (000 in clock 2, the first pixel of the byte read in clock 1), and
    --   VIDEN is registered to match, so the F574 that delayed H2:H0 and
    --   videoActive by two clocks is gone (see docs/VIDEO_TIMING.md).
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
        H0  => pixelCol(0),
        H1  => pixelCol(1),
        H2  => pixelCol(2),
        
        VIDEN => viden,

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

    -- Row tint (2026-10-22, docs/VIDEO.md "Row tint")
    --   On the board, line code Q4/Q5/Q6 each feed 910 ohm and two 1N4148s
    --   into the red/green/blue line, about 0.2 V (30 % of full scale), and a
    --   BAT85 to VIDEN turns it off in blanking.  Here the 4-bit Basys DAC
    --   gets +4 of 15 on that channel while VIDEN is high, held at 15.
    tintRed   <= viden and lineCode(4);
    tintGreen <= viden and lineCode(5);
    tintBlue  <= viden and lineCode(6);
    VGA_RED   <= tintAdd(vRed, tintRed);
    VGA_GREEN <= tintAdd(vGreen, tintGreen);
    VGA_BLUE  <= tintAdd(vBlue, tintBlue);
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
            if viden='1' then
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
    -- The ROM cartridge (cartridge.vhd): loader PLD, EEPROMs (rom.mem:
    -- boot loader, standard library and font, and the program; see
    -- docs/ROM.md) and the SRAM the CPU reads after the load.  CPU writes
    -- always go to the main RAM.
    cartComp : entity work.cartridge
    port map(
        clk         => clkVGA,
        clkSystem   => clkSystem,
        addr        => ramAddress,
        pixelEnable => pixelEn,
        pcEnable    => pcEnable,
        stallIn     => cpuStall,

        data        => cartData,
        eeDrive     => cartEeDrive,
        run         => run,
        stallOut    => stall
    );

end architecture Behavioral;
