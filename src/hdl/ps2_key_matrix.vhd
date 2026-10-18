--------------------------------------------------------------------------------
-- ps2_key_matrix.vhd
--
-- FPGA model fixture (not a board part): turns the Basys3's USB keyboard,
-- which the board's USB host presents as a PS/2 keyboard, into the
-- Placard's 8 x 8 key matrix (docs/IO.md).  It receives scan code set 2 bytes,
-- keeps one bit per matrix key (pressed or not) and answers the column
-- lines like the real matrix: row r is low while a key in row r of a
-- driven (low) column is held.
--
-- Key numbers (column * 8 + row), as kbd_map in placard_io.asm:
--   col 0: Esc 1 2 3 4 5 6 7          col 4: f g h j k l ; '
--   col 1: 8 9 0 - = Backspace Tab q  col 5: Enter LShift z x c v b n
--   col 2: w e r t y u i o            col 6: m , . / RShift Up Caps Fn
--   col 3: p [ ] \ Ctrl a s d         col 7: ` Alt Space Delete Home
--                                              Left Down Right
-- Either Ctrl or Alt key is the matrix Ctrl or Alt; the left Windows key
-- is Fn.  Keys that are not in the matrix are ignored, and so is the
-- Pause key's E1 sequence.
--
-- The receiver only listens (the host never sends to the keyboard), so
-- the keyboard keeps its power-up defaults.
--
-- Date: 10/18/2026
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_key_matrix is
    port (
        clk     : in  std_logic;                     -- system clock
        rst     : in  std_logic;                     -- 1 = all keys up
        ps2Clk  : in  std_logic;
        ps2Data : in  std_logic;
        colN    : in  std_logic_vector(7 downto 0);  -- column lines, low = driven
        rowN    : out std_logic_vector(7 downto 0)   -- row lines, low = a key held
    );
end entity ps2_key_matrix;

architecture rtl of ps2_key_matrix is

    signal clkSync   : std_logic_vector(2 downto 0) := "111";
    signal dataSync  : std_logic_vector(1 downto 0) := "11";
    signal clkFilt   : std_logic := '1';
    signal clkCount  : unsigned(4 downto 0) := (others => '1');
    signal clkFiltR  : std_logic := '1';
    signal frame     : std_logic_vector(10 downto 0) := (others => '0');
    signal bitCount  : unsigned(3 downto 0) := (others => '0');
    signal idleCount : unsigned(15 downto 0) := (others => '0');
    signal byteRdy   : std_logic := '0';
    signal byteIn    : std_logic_vector(7 downto 0) := (others => '0');

    signal ext       : std_logic := '0';   -- E0 seen
    signal brk       : std_logic := '0';   -- F0 seen
    signal skip      : unsigned(2 downto 0) := (others => '0');  -- E1 bytes left
    signal keys      : std_logic_vector(63 downto 0) := (others => '0');

    -- key number for a set 2 code; 64 = not in the matrix
    function key_of(code : std_logic_vector(7 downto 0); e : std_logic) return integer is
    begin
        if e = '0' then
            case code is
                when x"76" => return 0;    -- Esc
                when x"16" => return 1;    -- 1
                when x"1E" => return 2;
                when x"26" => return 3;
                when x"25" => return 4;
                when x"2E" => return 5;
                when x"36" => return 6;
                when x"3D" => return 7;
                when x"3E" => return 8;    -- 8
                when x"46" => return 9;
                when x"45" => return 10;   -- 0
                when x"4E" => return 11;   -- -
                when x"55" => return 12;   -- =
                when x"66" => return 13;   -- Backspace
                when x"0D" => return 14;   -- Tab
                when x"15" => return 15;   -- q
                when x"1D" => return 16;   -- w
                when x"24" => return 17;   -- e
                when x"2D" => return 18;   -- r
                when x"2C" => return 19;   -- t
                when x"35" => return 20;   -- y
                when x"3C" => return 21;   -- u
                when x"43" => return 22;   -- i
                when x"44" => return 23;   -- o
                when x"4D" => return 24;   -- p
                when x"54" => return 25;   -- [
                when x"5B" => return 26;   -- ]
                when x"5D" => return 27;   -- \
                when x"14" => return 28;   -- left Ctrl
                when x"1C" => return 29;   -- a
                when x"1B" => return 30;   -- s
                when x"23" => return 31;   -- d
                when x"2B" => return 32;   -- f
                when x"34" => return 33;   -- g
                when x"33" => return 34;   -- h
                when x"3B" => return 35;   -- j
                when x"42" => return 36;   -- k
                when x"4B" => return 37;   -- l
                when x"4C" => return 38;   -- ;
                when x"52" => return 39;   -- '
                when x"5A" => return 40;   -- Enter
                when x"12" => return 41;   -- left Shift
                when x"1A" => return 42;   -- z
                when x"22" => return 43;   -- x
                when x"21" => return 44;   -- c
                when x"2A" => return 45;   -- v
                when x"32" => return 46;   -- b
                when x"31" => return 47;   -- n
                when x"3A" => return 48;   -- m
                when x"41" => return 49;   -- ,
                when x"49" => return 50;   -- .
                when x"4A" => return 51;   -- /
                when x"59" => return 52;   -- right Shift
                when x"58" => return 54;   -- Caps Lock
                when x"0E" => return 56;   -- `
                when x"11" => return 57;   -- left Alt
                when x"29" => return 58;   -- Space
                when others => return 64;
            end case;
        else
            case code is
                when x"14" => return 28;   -- right Ctrl
                when x"5A" => return 40;   -- keypad Enter
                when x"75" => return 53;   -- Up
                when x"1F" => return 55;   -- left Windows = Fn
                when x"11" => return 57;   -- right Alt
                when x"71" => return 59;   -- Delete
                when x"6C" => return 60;   -- Home
                when x"6B" => return 61;   -- Left
                when x"72" => return 62;   -- Down
                when x"74" => return 63;   -- Right
                when others => return 64;
            end case;
        end if;
    end function key_of;

begin

    -- receiver: the keyboard changes DATA while CLK is high and the host
    -- samples it on the falling CLK edge (filtered against glitches)
    rxProc : process (clk)
    begin
        if rising_edge(clk) then
            clkSync  <= clkSync(1 downto 0) & to_x01(ps2Clk);
            dataSync <= dataSync(0) & to_x01(ps2Data);
            byteRdy  <= '0';

            if clkSync(2) = clkFilt then
                clkCount <= (others => '1');
            elsif clkCount = 0 then
                clkFilt <= clkSync(2);
            else
                clkCount <= clkCount - 1;
            end if;
            clkFiltR <= clkFilt;

            if clkFilt = '1' then
                if idleCount /= x"FFFF" then
                    idleCount <= idleCount + 1;
                else
                    bitCount <= (others => '0');   -- a frame cut off: start over
                end if;
            else
                idleCount <= (others => '0');
            end if;

            if clkFiltR = '1' and clkFilt = '0' then
                frame <= dataSync(1) & frame(10 downto 1);
                if bitCount = 10 then
                    bitCount <= (others => '0');
                    byteIn   <= frame(9 downto 2);   -- the 8 data bits
                    byteRdy  <= '1';
                else
                    bitCount <= bitCount + 1;
                end if;
            end if;
        end if;
    end process rxProc;

    -- scan codes to key states
    keyProc : process (clk)
        variable k : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                keys <= (others => '0');
                ext  <= '0';
                brk  <= '0';
                skip <= (others => '0');
            elsif byteRdy = '1' then
                if skip /= 0 then
                    skip <= skip - 1;
                elsif byteIn = x"E1" then
                    skip <= "111";          -- Pause: E1 14 77 E1 F0 14 F0 77
                elsif byteIn = x"E0" then
                    ext <= '1';
                elsif byteIn = x"F0" then
                    brk <= '1';
                else
                    k := key_of(byteIn, ext);
                    if k < 64 then
                        keys(k) <= not brk;
                    end if;
                    ext <= '0';
                    brk <= '0';
                end if;
            end if;
        end if;
    end process keyProc;

    -- the matrix: a row is low while a held key joins it to a low column
    rowProc : process (all)
        variable r : std_logic_vector(7 downto 0);
    begin
        r := (others => '1');
        for c in 0 to 7 loop
            if colN(c) = '0' then
                for n in 0 to 7 loop
                    if keys(c * 8 + n) = '1' then
                        r(n) := '0';
                    end if;
                end loop;
            end if;
        end loop;
        rowN <= r;
    end process rowProc;

end architecture rtl;
