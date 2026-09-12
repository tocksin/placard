-- @file tb_alu.vhd
-- @brief This is a testbench for the ALU
-- @author Justin Davis
--
-- Date: 09/10/2026
--
-------------------------------------------------------------------------------

library ieee;       use ieee.std_logic_1164.all;
                    use ieee.numeric_std.all;
                    use std.textio.all;

library work;       use work.tools_pkg.all;
                    use work.logging_pkg.all;

entity tb_alu is
end tb_alu;

architecture behavioral of tb_alu is

    type aluCommandType is (F_AND, F_OR, F_XOR, F_NOT, F_ADD, F_SUB, F_INC, F_DEC);

    signal aluCommand   : aluCommandType := F_AND;
    signal a            : slv(7 downto 0) := x"00";
    signal b            : slv(7 downto 0) := x"FF";
    signal q            : slv(7 downto 0);
    signal c            : slv(8 downto 1);
    signal s            : slv(2 downto 0);
    signal z            : slv(1 downto 0);
    signal v            : slv(1 downto 0);
    signal carryin      : sl := '0';
    signal aluComStr    : string(1 to 3);
    signal result       : slv(7 downto 0) := x"00";
    signal carryout     : sl;
    
begin

    aluComStr <= "AND" when aluCommand = F_AND else
                 "OR " when aluCommand = F_OR else
                 "XOR" when aluCommand = F_XOR else
                 "NOT" when aluCommand = F_NOT else
                 "ADD" when aluCommand = F_ADD else
                 "SUB" when aluCommand = F_SUB else
                 "INC" when aluCommand = F_INC else
                 "DEC";
    s         <= "000" when aluCommand = F_AND else
                 "001" when aluCommand = F_OR else
                 "010" when aluCommand = F_XOR else
                 "011" when aluCommand = F_NOT else
                 "100" when aluCommand = F_ADD else
                 "101" when aluCommand = F_SUB else
                 "110" when aluCommand = F_INC else
                 "111";

                 
    aluLsbComp : entity work.alu
    port map (
        -- Inputs
        A0  => a(0), -- PIN 1
        A1  => a(1), -- PIN 2
        A2  => a(2), -- PIN 3
        A3  => a(3), -- PIN 4
        B0  => b(0), -- PIN 5
        B1  => b(1), -- PIN 6
        B2  => b(2), -- PIN 7
        B3  => b(3), -- PIN 8
        S0  => s(0), -- PIN 9
        S1  => s(1), -- PIN 10
        M   => s(2), -- PIN 11
        CIN => carryin, -- PIN 13

        -- Outputs
        F0  => q(0), -- PIN 18
        F1  => q(1), -- PIN 19
        F2  => q(2), -- PIN 17
        F3  => q(3), -- PIN 20
        C1  => c(1), -- PIN 14
        C2  => c(2), -- PIN 23
        C3  => c(3), -- PIN 15
        C4  => c(4), -- PIN 22
        Z   => z(0), -- PIN 16
        V   => v(0) -- PIN 21
    );

    aluMsbComp : entity work.alu
    port map (
        -- Inputs
        A0  => a(4), -- PIN 1
        A1  => a(5), -- PIN 2
        A2  => a(6), -- PIN 3
        A3  => a(7), -- PIN 4
        B0  => b(4), -- PIN 5
        B1  => b(5), -- PIN 6
        B2  => b(6), -- PIN 7
        B3  => b(7), -- PIN 8
        S0  => s(0), -- PIN 9
        S1  => s(1), -- PIN 10
        M   => s(2), -- PIN 11
        CIN => c(4), -- PIN 13

        -- Outputs
        F0  => q(4), -- PIN 18
        F1  => q(5), -- PIN 19
        F2  => q(6), -- PIN 17
        F3  => q(7), -- PIN 20
        C1  => c(5), -- PIN 14
        C2  => c(6), -- PIN 23
        C3  => c(7), -- PIN 15
        C4  => c(8), -- PIN 22
        Z   => z(1), -- PIN 16
        V   => v(1) -- PIN 21
    );

    carryout <= c(8);
    
    process 
        variable errCnt       : integer := 0;
    begin
        report "Start testbench";
        wait for 100 ns;
        
--------------------------------------------------------------------------------
        report "Carryin=0 tests";
        aluCommand <= F_OR;
        wait for 100 ns;
        errCnt := errCnt + check(q, a or b, "A OR B doesn't match");
        
        aluCommand <= F_XOR;
        wait for 100 ns;
        errCnt := errCnt + check(q, a xor b, "A XOR B doesn't match");

        aluCommand <= F_NOT;
        wait for 100 ns;
        errCnt := errCnt + check(q, not a, "NOT A doesn't match");

        aluCommand <= F_ADD;
        result <= slv(unsigned(a) + unsigned(b) + carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A + B + C doesn't match");

        aluCommand <= F_SUB;
        result <= slv(unsigned(a) - unsigned(b) - carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A - B - C doesn't match");

        aluCommand <= F_INC;
        result <= slv(unsigned(a) + carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A + C doesn't match");

        aluCommand <= F_DEC;
        result <= slv(unsigned(a) - carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A - C doesn't match");

        a <= x"55";
        wait for 1 ns;
        aluCommand <= F_DEC;
        result <= slv(unsigned(a) - carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A - C doesn't match");

        a <= x"FF";
        wait for 1 ns;
        aluCommand <= F_DEC;
        result <= slv(unsigned(a) - carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A - C doesn't match");

--------------------------------------------------------------------------------
        report "Carryin=1 tests";
        carryin <= '1';

        a <= x"00";
        wait for 1 ns;
        aluCommand <= F_AND;
        wait for 100 ns;
        errCnt := errCnt + check(q, a and b, "A OR B doesn't match");

        aluCommand <= F_OR;
        wait for 100 ns;
        errCnt := errCnt + check(q, a or b, "A OR B doesn't match");
        
        aluCommand <= F_XOR;
        wait for 100 ns;
        errCnt := errCnt + check(q, a xor b, "A XOR B doesn't match");

        aluCommand <= F_NOT;
        wait for 100 ns;
        errCnt := errCnt + check(q, not a, "NOT A doesn't match");

        aluCommand <= F_ADD;
        result <= slv(unsigned(a) + unsigned(b) + carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A + B + C doesn't match");

        aluCommand <= F_SUB;
        result <= slv(unsigned(a) - unsigned(b) - carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A - B - C doesn't match");

        aluCommand <= F_INC;
        result <= slv(unsigned(a) + carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A + C doesn't match");

        aluCommand <= F_DEC;
        result <= slv(unsigned(a) - carryin);
        wait for 100 ns;
        errCnt := errCnt + check(q, result, "A - C doesn't match");

        report "THERE IS A TOTAL OF " & integer'IMAGE(errCnt) & " ERROR(S)";
        wait;
    end process;
    
end architecture behavioral;
