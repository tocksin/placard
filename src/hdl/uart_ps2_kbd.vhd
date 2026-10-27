--------------------------------------------------------------------------------
-- uart_ps2_kbd.vhd
-- Date: 10/27/2026
--
-- A PS/2 keyboard typed from a PC terminal (Basys 3 test platform only, not
-- part of the Placard).  Characters arrive on the Basys 3's USB serial port
-- (115200 baud, 8 data bits, no parity, 1 stop bit), wait in a 16K-character
-- FIFO (block RAM) and are sent as the scan code set 2 bytes of the key that types them
-- on the Placard (with Shift or Ctrl around it when needed), the way a
-- PS/2 keyboard sends them: a byte only while the host leaves the clock
-- free, 11 bits of about 80 us, and a byte cut off by the host is sent
-- again.  The outputs pull the PS/2 clock and data lines low (wired-AND
-- with the real lines in basys_top.vhd), so the receiver PLD and the
-- driver in placard_ps2.asm see an ordinary keyboard.
--
--   Enter (0D, or 0A not after 0D), Backspace (08 or 7F), Tab, Esc, Ctrl+A-Z
--   (01-1A) and the arrow keys (ESC [ A/B/C/D) are typed too.  ESC alone is
--   Esc once nothing follows it for about 20 ms.
--   Each key stays down 20 ms (a little over a frame) before its break
--   code (and the Shift or Ctrl after it), so kbd_scan, once a frame, sees
--   the keys one at a time, in order, with Shift still down: about 40
--   characters a second to a program that takes the PS/2 bytes as they
--   come (con_gets, BASIC's KEY), one byte per frame (3 for a plain key, 6
--   for a shifted one) to one that only calls kbd_scan.
--   Flow control: XOFF (13) goes to the PC when the FIFO is three quarters
--   full and XON (11) when it is down to a quarter, so a terminal set to
--   XON/XOFF can send (paste) at full speed with no delay per character.
--   Each character is echoed back as it is typed (taken from the FIFO).
--   hostHold = 1 while the host holds the clock low (it is also held to
--   keep the keyboard quiet when it is not selected).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_ps2_kbd is
    generic (
        CLK_HZ  : natural := 25000000;
        BAUD    : natural := 115200;
        FIFO_BITS : natural := 14             -- 16K characters
    );
    port (
        clk         : in  std_logic;
        rxIn        : in  std_logic;   -- serial data from the PC (idle 1)
        hostHold    : in  std_logic;   -- 1 = the host holds the PS/2 clock low
        kbdClkLow   : out std_logic;   -- 1 = pull the PS/2 clock low
        kbdDataLow  : out std_logic;   -- 1 = pull the PS/2 data low
        txOut       : out std_logic;   -- each character echoed back to the PC (idle 1)
        rxToggle    : out std_logic;   -- changes with every character received (debug LED)
        dbgTaken    : out std_logic_vector(7 downto 0);  -- characters taken from the FIFO (debug)
        dbgSent     : out std_logic_vector(7 downto 0)   -- PS/2 bytes sent (debug)
    );
end entity uart_ps2_kbd;

architecture rtl of uart_ps2_kbd is

    constant BIT_CLKS  : natural := CLK_HZ / BAUD;
    constant US        : natural := CLK_HZ / 1000000;
    constant FREE_CLKS : natural := 60 * US;     -- clock free this long before a byte
    constant SETUP_CLKS: natural := 20 * US;     -- data set, clock high
    constant LOW_CLKS  : natural := 40 * US;     -- clock low
    constant HIGH_CLKS : natural := 20 * US;     -- clock high after the edge
    constant ESC_CLKS  : natural := 20000 * US;  -- ESC alone after 20 ms
    constant HOLD_CLKS : natural := 20000 * US;  -- the key stays down 20 ms
    constant XOFF_AT   : natural := 3 * 2 ** (FIFO_BITS - 2);  -- characters waiting: XOFF
    constant XON_AT    : natural := 2 ** (FIFO_BITS - 2);      -- and XON again
    constant XON       : std_logic_vector(7 downto 0) := x"11";
    constant XOFF      : std_logic_vector(7 downto 0) := x"13";

    -- the key of each character: bit 11 valid, 10 E0 key, 9 Ctrl, 8 Shift,
    -- 7:0 the set 2 code (made from kbd_map and ps2_set2 in the library)
    type keyTableType is array (0 to 127) of std_logic_vector(11 downto 0);
    constant KEY_TABLE : keyTableType := (
        x"000", x"A1C", x"A32", x"A21", x"A23", x"A24", x"A2B", x"A34",  -- 00-07
        x"866", x"80D", x"85A", x"A42", x"A4B", x"85A", x"A31", x"A44",  -- 08-0F
        x"A4D", x"A15", x"A2D", x"A1B", x"A2C", x"A3C", x"A2A", x"A1D",  -- 10-17
        x"A22", x"A35", x"A1A", x"876", x"000", x"000", x"000", x"000",  -- 18-1F
        x"829", x"916", x"952", x"926", x"925", x"92E", x"93D", x"852",  -- 20-27
        x"946", x"945", x"93E", x"955", x"841", x"84E", x"849", x"84A",  -- 28-2F
        x"845", x"816", x"81E", x"826", x"825", x"82E", x"836", x"83D",  -- 30-37
        x"83E", x"846", x"94C", x"84C", x"941", x"855", x"949", x"94A",  -- 38-3F
        x"91E", x"91C", x"932", x"921", x"923", x"924", x"92B", x"934",  -- 40-47
        x"933", x"943", x"93B", x"942", x"94B", x"93A", x"931", x"944",  -- 48-4F
        x"94D", x"915", x"92D", x"91B", x"92C", x"93C", x"92A", x"91D",  -- 50-57
        x"922", x"935", x"91A", x"854", x"85D", x"85B", x"936", x"94E",  -- 58-5F
        x"80E", x"81C", x"832", x"821", x"823", x"824", x"82B", x"834",  -- 60-67
        x"833", x"843", x"83B", x"842", x"84B", x"83A", x"831", x"844",  -- 68-6F
        x"84D", x"815", x"82D", x"81B", x"82C", x"83C", x"82A", x"81D",  -- 70-77
        x"822", x"835", x"81A", x"954", x"95D", x"95B", x"90E", x"866"  -- 78-7F
    );

    -- serial receiver
    signal rxSync      : std_logic_vector(1 downto 0) := "11";
    signal rxBusy      : std_logic := '0';
    signal rxCnt       : natural range 0 to BIT_CLKS * 2 := 0;
    signal rxBit       : natural range 0 to 9 := 0;
    signal rxShift     : std_logic_vector(7 downto 0) := (others => '0');
    signal rxValid     : std_logic := '0';
    signal rxByte      : std_logic_vector(7 downto 0) := (others => '0');

    -- the echo and the flow control
    signal echoBusy    : std_logic := '0';
    signal echoPend    : std_logic := '0';                      -- a character to echo
    signal echoChar    : std_logic_vector(7 downto 0) := (others => '0');
    signal flowPend    : std_logic := '0';                      -- XON or XOFF to send
    signal flowChar    : std_logic_vector(7 downto 0) := (others => '0');
    signal xoffSent    : std_logic := '0';                      -- 1 = the PC was sent XOFF
    signal takenValid  : std_logic := '0';                      -- a character taken from the FIFO
    signal takenChar   : std_logic_vector(7 downto 0) := (others => '0');
    signal echoCnt     : natural range 0 to BIT_CLKS := 0;
    signal echoBit     : natural range 0 to 9 := 0;
    signal echoShift   : std_logic_vector(9 downto 0) := (others => '1');
    signal rxToggleR   : std_logic := '0';

    -- character FIFO
    type fifoType is array (0 to 2 ** FIFO_BITS - 1) of std_logic_vector(7 downto 0);
    signal fifo        : fifoType;
    signal wrPtr       : unsigned(FIFO_BITS - 1 downto 0) := (others => '0');
    signal rdPtr       : unsigned(FIFO_BITS - 1 downto 0) := (others => '0');
    signal rdData      : std_logic_vector(7 downto 0) := (others => '0');
    signal rdWait      : natural range 0 to 2 := 0;

    -- the bytes of the key being typed
    type seqType is array (0 to 7) of std_logic_vector(7 downto 0);
    signal seq         : seqType := (others => (others => '0'));
    signal seqLen      : natural range 0 to 8 := 0;
    signal seqIdx      : natural range 0 to 8 := 0;
    signal seqMake     : natural range 0 to 7 := 0;      -- the key's own make code in seq
    signal holdCnt     : natural range 0 to HOLD_CLKS := 0;
    signal escState    : natural range 0 to 2 := 0;
    signal escCnt      : natural range 0 to ESC_CLKS := 0;
    signal lastCr      : std_logic := '0';

    -- PS/2 sender
    type txStateType is (txWait, txSetup, txLow, txHigh);
    signal txState     : txStateType := txWait;
    signal txCnt       : natural range 0 to FREE_CLKS := 0;
    signal txBitIdx    : natural range 0 to 10 := 0;
    signal txFrame     : std_logic_vector(10 downto 0) := (others => '1');
    signal clkLowR     : std_logic := '0';
    signal dataLowR    : std_logic := '0';
    signal sentCnt     : unsigned(7 downto 0) := (others => '0');

begin

    kbdClkLow  <= clkLowR;
    kbdDataLow <= dataLowR;
    txOut      <= echoShift(0);
    rxToggle   <= rxToggleR;
    dbgTaken   <= std_logic_vector(resize(rdPtr, 8));
    dbgSent    <= std_logic_vector(sentCnt);

    -- each character goes back to the terminal as it is typed, so typing
    -- shows there too (LD5, rxToggle, shows each one arriving); XOFF and
    -- XON go ahead of it.  The characters are typed at least 20 ms apart,
    -- so one waiting echo is enough.
    echoProc : process (clk)
        variable level : unsigned(FIFO_BITS - 1 downto 0);
    begin
        if rising_edge(clk) then
            if rxValid = '1' then
                rxToggleR <= not rxToggleR;
            end if;
            level := wrPtr - rdPtr;
            if xoffSent = '0' and level >= XOFF_AT then
                flowPend <= '1';
                flowChar <= XOFF;
                xoffSent <= '1';
            elsif xoffSent = '1' and level <= XON_AT then
                flowPend <= '1';
                flowChar <= XON;
                xoffSent <= '0';
            end if;
            if echoBusy = '0' then
                if flowPend = '1' then
                    echoShift <= '1' & flowChar & '0';
                    echoBusy  <= '1';
                    echoCnt   <= BIT_CLKS - 1;
                    echoBit   <= 0;
                    flowPend  <= '0';
                elsif echoPend = '1' then
                    echoShift <= '1' & echoChar & '0';
                    echoBusy  <= '1';
                    echoCnt   <= BIT_CLKS - 1;
                    echoBit   <= 0;
                    echoPend  <= '0';
                end if;
            elsif echoCnt /= 0 then
                echoCnt <= echoCnt - 1;
            else
                echoCnt   <= BIT_CLKS - 1;
                echoShift <= '1' & echoShift(9 downto 1);
                if echoBit = 9 then
                    echoBusy <= '0';
                else
                    echoBit <= echoBit + 1;
                end if;
            end if;
            if takenValid = '1' then
                echoPend <= '1';
                echoChar <= takenChar;
            end if;
        end if;
    end process echoProc;

    rxProc : process (clk)
    begin
        if rising_edge(clk) then
            rxSync  <= rxSync(0) & rxIn;
            rxValid <= '0';
            if rxBusy = '0' then
                if rxSync(1) = '0' then                 -- a start bit
                    rxBusy <= '1';
                    rxCnt  <= BIT_CLKS / 2;
                    rxBit  <= 0;
                end if;
            elsif rxCnt /= 0 then
                rxCnt <= rxCnt - 1;
            else
                rxCnt <= BIT_CLKS - 1;
                if rxBit = 0 then
                    if rxSync(1) = '1' then             -- not a start bit after all
                        rxBusy <= '0';
                    end if;
                    rxBit <= 1;
                elsif rxBit <= 8 then
                    rxShift <= rxSync(1) & rxShift(7 downto 1);
                    rxBit   <= rxBit + 1;
                else                                    -- the stop bit
                    rxBusy <= '0';
                    if rxSync(1) = '1' then
                        rxValid <= '1';
                        rxByte  <= rxShift;
                    end if;
                end if;
            end if;
        end if;
    end process rxProc;

    seqProc : process (clk)
        variable c     : std_logic_vector(7 downto 0);
        variable k     : std_logic_vector(11 downto 0);
        variable s     : seqType;
        variable n     : natural range 0 to 8;
        variable go    : boolean;
    begin
        if rising_edge(clk) then
            if rxValid = '1' and wrPtr + 1 /= rdPtr then
                fifo(to_integer(wrPtr)) <= rxByte;
                wrPtr <= wrPtr + 1;
            end if;
            -- the FIFO is read through a register (block RAM or not, the
            -- character is the one at rdPtr): it is used two clocks after
            -- rdPtr points at it
            rdData <= fifo(to_integer(rdPtr));
            takenValid <= '0';

            if txState = txWait and txCnt = 0 and seqIdx = seqLen and seqLen /= 0 then
                seqLen <= 0;                            -- the key is done
                seqIdx <= 0;
            elsif seqLen = 0 then
                go := false;
                k  := (others => '0');
                if escState = 1 and escCnt = ESC_CLKS then
                    escState <= 0;                      -- ESC alone: Esc
                    k  := KEY_TABLE(16#1B#);
                    go := true;
                elsif escState = 1 and rdPtr = wrPtr then
                    escCnt <= escCnt + 1;
                elsif rdPtr /= wrPtr and rdWait /= 2 then
                    rdWait <= rdWait + 1;
                elsif rdPtr /= wrPtr then
                    c := rdData;
                    rdPtr  <= rdPtr + 1;
                    rdWait <= 0;
                    takenValid <= '1';
                    takenChar  <= c;
                    if escState = 2 then
                        escState <= 0;                  -- ESC [ A-D: an arrow
                        case c is
                            when x"41"  => k := x"C75"; go := true;     -- Up
                            when x"42"  => k := x"C72"; go := true;     -- Down
                            when x"43"  => k := x"C74"; go := true;     -- Right
                            when x"44"  => k := x"C6B"; go := true;     -- Left
                            when others => null;
                        end case;
                    elsif escState = 1 then
                        if c = x"5B" then
                            escState <= 2;
                        else                            -- Esc, and the character is lost
                            escState <= 0;
                            k  := KEY_TABLE(16#1B#);
                            go := true;
                        end if;
                    elsif c = x"1B" then
                        escState <= 1;
                        escCnt   <= 0;
                    elsif c(7) = '0' and not (c = x"0A" and lastCr = '1') then
                        k  := KEY_TABLE(to_integer(unsigned(c(6 downto 0))));
                        go := k(11) = '1';
                    end if;
                    if c = x"0D" then lastCr <= '1'; else lastCr <= '0'; end if;
                end if;
                if go then                              -- the key's bytes
                    n := 0;
                    s := (others => (others => '0'));
                    if k(8) = '1' then s(n) := x"12"; n := n + 1; end if;
                    if k(9) = '1' then s(n) := x"14"; n := n + 1; end if;
                    if k(10) = '1' then s(n) := x"E0"; n := n + 1; end if;
                    s(n) := k(7 downto 0); seqMake <= n; n := n + 1;
                    if k(10) = '1' then s(n) := x"E0"; n := n + 1; end if;
                    s(n) := x"F0"; n := n + 1;
                    s(n) := k(7 downto 0); n := n + 1;
                    if k(8) = '1' then s(n) := x"F0"; s(n + 1) := x"12"; n := n + 2;
                    elsif k(9) = '1' then s(n) := x"F0"; s(n + 1) := x"14"; n := n + 2;
                    end if;
                    seq    <= s;
                    seqLen <= n;
                    seqIdx <= 0;
                end if;
            end if;

            -- the PS/2 sender
            case txState is
                when txWait =>
                    clkLowR  <= '0';
                    dataLowR <= '0';
                    if holdCnt /= 0 then
                        holdCnt <= holdCnt - 1;         -- the key is held down
                        txCnt   <= 0;
                    elsif hostHold = '1' or seqIdx = seqLen then
                        txCnt <= 0;
                    elsif txCnt = FREE_CLKS then
                        txCnt    <= 0;
                        txBitIdx <= 0;
                        txFrame  <= '1' & not (seq(seqIdx)(0) xor seq(seqIdx)(1) xor seq(seqIdx)(2)
                                    xor seq(seqIdx)(3) xor seq(seqIdx)(4) xor seq(seqIdx)(5)
                                    xor seq(seqIdx)(6) xor seq(seqIdx)(7)) & seq(seqIdx) & '0';
                        txState  <= txSetup;
                    else
                        txCnt <= txCnt + 1;
                    end if;
                when txSetup =>                         -- the bit on DATA, CLK high
                    dataLowR <= not txFrame(txBitIdx);
                    if hostHold = '1' then
                        txState <= txWait;              -- cut off: send it again
                        txCnt   <= 0;
                    elsif txCnt = SETUP_CLKS then
                        txCnt   <= 0;
                        clkLowR <= '1';
                        txState <= txLow;
                    else
                        txCnt <= txCnt + 1;
                    end if;
                when txLow =>
                    if txCnt = LOW_CLKS then
                        txCnt   <= 0;
                        clkLowR <= '0';
                        txState <= txHigh;
                    else
                        txCnt <= txCnt + 1;
                    end if;
                when txHigh =>
                    if txBitIdx = 10 then               -- the stop bit: the byte is in
                        if txCnt = HIGH_CLKS then
                            txCnt    <= 0;
                            dataLowR <= '0';
                            seqIdx   <= seqIdx + 1;
                            sentCnt  <= sentCnt + 1;
                            if seqIdx = seqMake then
                                holdCnt <= HOLD_CLKS;   -- one key per frame or two, in order
                            end if;
                            txState  <= txWait;
                        else
                            txCnt <= txCnt + 1;
                        end if;
                    elsif hostHold = '1' then
                        txState <= txWait;              -- cut off: send it again
                        txCnt   <= 0;
                    elsif txCnt = HIGH_CLKS then
                        txCnt    <= 0;
                        txBitIdx <= txBitIdx + 1;
                        txState  <= txSetup;
                    else
                        txCnt <= txCnt + 1;
                    end if;
            end case;
        end if;
    end process seqProc;

end architecture rtl;
