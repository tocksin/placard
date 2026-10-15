-- Exhaustive self-checking testbench for alu4 (8192 input combinations)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity alu4_tb is
end entity alu4_tb;

architecture sim of alu4_tb is
    signal a, b : std_logic_vector(3 downto 0) := (others => '0');
    signal s    : std_logic_vector(2 downto 0) := (others => '0');
    signal cin  : std_logic := '0';
    signal sri  : std_logic := '0';
    signal f    : std_logic_vector(3 downto 0);
    signal cout, z, d1, d2, d3 : std_logic;
begin

    dut : entity work.alu4
        port map (
            a => a, b => b, s => s, cin => cin,
            shift_right_in => sri,
            f => f, cout => cout, z => z,
            d1 => d1, d2 => d2, d3 => d3
        );

    stim : process
        variable ai, bi, si, ci, ri : integer;
        variable sum    : unsigned(4 downto 0);
        variable exp_f  : std_logic_vector(3 downto 0);
        variable exp_c  : std_logic;
        variable exp_z  : std_logic;
        variable errors : integer := 0;
    begin
        for n in 0 to 8191 loop
            ai := n mod 16;
            bi := (n / 16) mod 16;
            si := (n / 256) mod 8;
            ci := (n / 2048) mod 2;
            ri := (n / 4096) mod 2;

            a   <= std_logic_vector(to_unsigned(ai, 4));
            b   <= std_logic_vector(to_unsigned(bi, 4));
            s   <= std_logic_vector(to_unsigned(si, 3));
            if ci = 1 then cin <= '1'; else cin <= '0'; end if;
            if ri = 1 then sri <= '1'; else sri <= '0'; end if;
            wait for 10 ns;

            exp_c := '0';
            case si is
                when 0 =>                                   -- PASS B
                    exp_f := b;
                when 1 =>                                   -- AND
                    exp_f := a and b;
                when 2 =>                                   -- OR
                    exp_f := a or b;
                when 3 =>                                   -- XOR
                    exp_f := a xor b;
                when 4 =>                                   -- ADD
                    sum   := to_unsigned(ai + bi + ci, 5);
                    exp_f := std_logic_vector(sum(3 downto 0));
                    exp_c := sum(4);
                when 5 =>                                   -- SUB: A - B - CIN
                    sum   := to_unsigned(ai + (15 - bi) + (1 - ci), 5);
                    exp_f := std_logic_vector(sum(3 downto 0));
                    exp_c := not sum(4);                    -- 1 = borrow
                when 6 =>                                   -- SHIFT RIGHT
                    exp_f := sri & a(3 downto 1);
                    exp_c := a(0);
                when others =>                              -- PASS A
                    exp_f := a;
            end case;

            if exp_f = "0000" then exp_z := '1'; else exp_z := '0'; end if;

            if f /= exp_f or cout /= exp_c or z /= exp_z then
                errors := errors + 1;
                if errors <= 10 then
                    report "MISMATCH: S=" & integer'image(si) &
                           " A=" & integer'image(ai) &
                           " B=" & integer'image(bi) &
                           " CIN=" & integer'image(ci) &
                           " SRI=" & integer'image(ri)
                           severity error;
                end if;
            end if;
        end loop;

        if errors = 0 then
            report "PASS: all 8192 combinations correct" severity note;
        else
            report "FAIL: " & integer'image(errors) & " mismatches" severity failure;
        end if;
        wait;
    end process stim;

end architecture sim;
