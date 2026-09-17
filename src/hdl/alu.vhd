--------------------------------------------------------------------------------
-- File Name:     alu.vhd
-- Description:   4-bit ALU slice for cascading into wider ALUs.
--                Converted from CUPL PLD code 
--
/*
 * ============================================================
 * 4-BIT ALU
 * ============================================================
 *
 * FUNCTION SELECT
 *
 * S2 S1 S0
 * --------
 *  0  0  0    AND
 *  0  0  1    OR
 *  0  1  0    XOR
 *  0  1  1    NOT A
 *  1  0  0    ADD
 *  1  0  1    SUB
 *  1  1  0    SHL
 *  1  1  1    SHR
 *
 * ADD:
 *   F = A + B + CIN
 *   COUT = carry
 *
 * SUB:
 *   F = A + !B + CIN
 *   CIN = 1 -> A - B
 *   CIN = 0 -> A - B - 1
 *   COUT = 1 -> no borrow
 *   COUT = 0 -> borrow
 *
 * This convention allows multiple ALU chips to be cascaded:
 *   LOW COUT ---> HIGH CIN 
 *   for BOTH ADD and SUB.
 *
 * SHL:
 *   F = {A2,A1,A0,CIN}
 *   COUT = A3
 *
 * SHR:
 *   F = {CIN,A3,A2,A1}
 *   COUT = A0
 *
 * Z: (zero)
 *   1 when F = 0000
 *
 * V: (overflow)
 *   Signed arithmetic overflow.
 *   V = 0 for logic and shift operations.
 */
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity alu IS
    Port (
        A0, A1, A2, A3 : in  std_logic;
        B0, B1, B2, B3 : in  std_logic;
        S0, S1, S2     : in  std_logic;
        CIN            : in  std_logic;
        SHIFT_RIGHT_IN : in  std_logic;
        F0, F1, F2, F3 : out std_logic;
        COUT           : out std_logic;
        Z              : out std_logic
    );
end alu;

architecture Behavioral of alu is
    signal PASS_SEL, AND_SEL, OR_SEL, XOR_SEL : std_logic;
    signal ADD_SEL, SUB_SEL, SHR_SEL, NOT_SEL : std_logic;
    
    signal ADD_F0, ADD_F1, ADD_F2, ADD_F3 : std_logic;
    signal ADD_C1, ADD_C2, ADD_C3, ADD_C4 : std_logic;
    
    signal SUB_F0, SUB_F1, SUB_F2, SUB_F3 : std_logic;
    signal SUB_C1, SUB_C2, SUB_C3, SUB_C4 : std_logic;
begin
    -- Function Select
    PASS_SEL <= (not S2) and (not S1) and (not S0);
    AND_SEL  <= (not S2) and (not S1) and S0;
    OR_SEL   <= (not S2) and S1 and (not S0);
    XOR_SEL  <= (not S2) and S1 and S0;
    ADD_SEL  <= S2 and (not S1) and (not S0);
    SUB_SEL  <= S2 and (not S1) and S0;
    SHR_SEL  <= S2 and S1 and (not S0);
    NOT_SEL  <= S2 and S1 and S0;

    -- Addition
    ADD_F0 <= A0 xor B0 xor CIN;
    ADD_C1 <= (A0 and B0) or (A0 and CIN) or (B0 and CIN);
    
    ADD_F1 <= A1 xor B1 xor ADD_C1;
    ADD_C2 <= (A1 and B1) or (A1 and ADD_C1) or (B1 and ADD_C1);
    
    ADD_F2 <= A2 xor B2 xor ADD_C2;
    ADD_C3 <= (A2 and B2) or (A2 and ADD_C2) or (B2 and ADD_C2);
    
    ADD_F3 <= A3 xor B3 xor ADD_C3;
    ADD_C4 <= (A3 and B3) or (A3 and ADD_C3) or (B3 and ADD_C3);

    -- Subtraction
    SUB_F0 <= A0 xnor B0 xnor CIN;
    SUB_C1  <= (not A0 and B0) or (not A0 and CIN) or (B0 and CIN);
    
    SUB_F1 <= A1 xnor B1 xnor SUB_C1;
    SUB_C2  <= (not A1 and B1) or (not A1 and SUB_C1) or (B1 and SUB_C1);
    
    SUB_F2 <= A2 xnor B2 xnor SUB_C2;
    SUB_C3  <= (not A2 and B2) or (not A2 and SUB_C2) or (B2 and SUB_C2);
    
    SUB_F3 <= A3 xnor B3 xnor SUB_C3;
    SUB_C4  <= (not A3 and B3) or (not A3 and SUB_C3) or (B3 and SUB_C3);

    -- F0
    F0 <= (PASS_SEL and B0) or
          (AND_SEL  and A0 and B0) or
          (OR_SEL   and (A0 or B0)) or
          (XOR_SEL  and (A0 xor B0)) or
          (ADD_SEL  and ADD_F0) or
          (SUB_SEL  and SUB_F0) or
          (SHR_SEL  and A1) or
          (NOT_SEL  and (not A0));

    -- F1
    F1 <= (PASS_SEL and B1) or
          (AND_SEL  and A1 and B1) or
          (OR_SEL   and (A1 or B1)) or
          (XOR_SEL  and (A1 xor B1)) or
          (ADD_SEL  and ADD_F1) or
          (SUB_SEL  and SUB_F1) or
          (SHR_SEL  and A2) or
          (NOT_SEL  and (not A1));

    -- F2
    F2 <= (PASS_SEL and B2) or
          (AND_SEL  and A2 and B2) or
          (OR_SEL   and (A2 or B2)) or
          (XOR_SEL  and (A2 xor B2)) or
          (ADD_SEL  and ADD_F2) or
          (SUB_SEL  and SUB_F2) or
          (SHR_SEL  and A3) or
          (NOT_SEL  and (not A2));

    -- F3
    F3 <= (PASS_SEL and B3) or
          (AND_SEL  and A3 and B3) or
          (OR_SEL   and (A3 or B3)) or
          (XOR_SEL  and (A3 xor B3)) or
          (ADD_SEL  and ADD_F3) or
          (SUB_SEL  and SUB_F3) or
          (SHR_SEL  and SHIFT_RIGHT_IN) or
          (NOT_SEL  and (not A3));

    -- Carry Output
    COUT <= (ADD_SEL and ADD_C4) or
            (SUB_SEL and SUB_C4) or
            (SHR_SEL and A0);

    -- Zero Flag
    Z <= not (F0 or F1 or F2 or F3);

end Behavioral;
