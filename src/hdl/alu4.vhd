-- =========================================================
-- ATF22V10C 4-BIT ALU  (VHDL version of ALU_SHR.pld, Rev 04)
-- Date: 10/15/2026
--
-- FUNCTION SELECT
--
--     S2 S1 S0
--     --------
--     0  0  0     PASS B
--     0  0  1     AND
--     0  1  0     OR
--     0  1  1     XOR
--     1  0  0     ADD
--     1  0  1     SUB
--     1  1  0     SHIFT RIGHT
--     1  1  1     PASS A
--
-- SUBTRACTION:  A - B - CIN = A + not B + not CIN
--     CIN = 1 means borrow in, COUT = 1 means borrow out.
--     COUT carries the raw borrow (not the adder's no-borrow
--     carry) so the low chip's COUT can drive the high chip's
--     CIN directly for both ADD and SUB, with no inverter or
--     XOR gate between the chips.
--
-- PASS A:  F = A.  B and CIN are ignored and COUT = 0.
--     Used by the branch/jump opcode (I7:I5 = 111): Z of each
--     chip is then the zero flag of that nibble of the
--     accumulator, and F3 of the high chip is the accumulator
--     sign bit.  Because CIN is ignored, the zero flag of the
--     high chip does not depend on the low chip.
--
-- SHIFT RIGHT:
--     F3 = SHIFT_RIGHT_IN, F2 = A3, F1 = A2, F0 = A1, COUT = A0
--
-- CARRY NODES D1..D3
-- ------------------
-- The 22V10 allows only 8 to 16 product terms per output and
-- has no buried nodes, so the carry chain is split using three
-- spare I/O pins (D1, D2, D3) that are fed back into the array.
-- They are declared as BUFFER ports so the synthesis tool sees
-- them as pins with feedback.  Leave them unconnected on the
-- board (or use them as test points).
--
-- ADD and SUB share one carry chain (S0 = 0 for ADD, 1 for SUB):
--     A + (B xor S0) + (CIN xor S0)
-- Each node holds the carry XORed with S0, so every sum bit is
-- a plain 3-input XOR:
--     Fi     = Ai xor Bi xor Di          (D0 = CIN)
--     D(i+1) = MAJ( Ai xor S0, Bi, Di )
--     D4 = carry out for ADD, borrow out for SUB  (= COUT)
--
-- SUGGESTED PIN ASSIGNMENT (24-pin DIP; pin 12 = GND, 24 = VCC)
--     A0..A3  = 1,2,3,4          B0..B3 = 5,6,7,8
--     S0..S2  = 9,10,11          CIN    = 13
--     F0..F3  = 20,17,18,19      COUT   = 15      Z = 14
--     SHIFT_RIGHT_IN = 23 (input only)
--     D1 = 22, D2 = 21, D3 = 16  (internal carry nodes)
-- F0..F3 need ~11 to 14 product terms each, so they must stay on
-- pins with at least 14 terms available (pins 17, 18, 19, 20).
-- F3 (about 14 terms) belongs on pin 18 or 19 (16 terms available).
-- =========================================================

library ieee;
use ieee.std_logic_1164.all;

entity alu4 is
    port (
        a              : in     std_logic_vector(3 downto 0);
        b              : in     std_logic_vector(3 downto 0);
        s              : in     std_logic_vector(2 downto 0);
        cin            : in     std_logic;
        shift_right_in : in     std_logic;
        f              : buffer std_logic_vector(3 downto 0);
        cout           : out    std_logic;
        z              : out    std_logic;
        d1             : buffer std_logic;   -- carry node
        d2             : buffer std_logic;   -- carry node
        d3             : buffer std_logic    -- carry node
    );
end entity alu4;

architecture rtl of alu4 is
    signal pass_sel   : std_logic;
    signal and_sel    : std_logic;
    signal or_sel     : std_logic;
    signal xor_sel    : std_logic;
    signal shr_sel    : std_logic;
    signal passa_sel  : std_logic;
    signal arith_sel  : std_logic;   -- ADD (S0=0) or SUB (S0=1)
    signal d4         : std_logic;   -- carry (ADD) / borrow (SUB) out of bit 3
    signal sh         : std_logic_vector(3 downto 0);   -- shift-right source
begin

    -- function select terms
    pass_sel   <= (not s(2)) and (not s(1)) and (not s(0));
    and_sel    <= (not s(2)) and (not s(1)) and s(0);
    or_sel     <= (not s(2)) and s(1) and (not s(0));
    xor_sel    <= (not s(2)) and s(1) and s(0);
    shr_sel    <= s(2) and s(1) and (not s(0));
    passa_sel  <= s(2) and s(1) and s(0);
    arith_sel  <= s(2) and (not s(1));

    -- shift-right source bits
    sh(0) <= a(1);
    sh(1) <= a(2);
    sh(2) <= a(3);
    sh(3) <= shift_right_in;

    -- carry nodes (D = carry xor S0)
    d1 <= (((a(0) xor s(0)) and b(0)) or ((a(0) xor s(0)) and cin) or (b(0) and cin));
    d2 <= (((a(1) xor s(0)) and b(1)) or ((a(1) xor s(0)) and d1)  or (b(1) and d1));
    d3 <= (((a(2) xor s(0)) and b(2)) or ((a(2) xor s(0)) and d2)  or (b(2) and d2));

    -- carry out of bit 3: carry for ADD, borrow for SUB
    d4 <= (((a(3) xor s(0)) and b(3)) or ((a(3) xor s(0)) and d3) or (b(3) and d3));

    -- function outputs
    f(0) <= (pass_sel  and b(0))
         or (and_sel   and (a(0) and b(0)))
         or (or_sel    and (a(0) or b(0)))
         or (xor_sel   and (a(0) xor b(0)))
         or (arith_sel and ((a(0) xor b(0)) xor cin))
         or (shr_sel   and sh(0))
         or (passa_sel and a(0));

    f(1) <= (pass_sel  and b(1))
         or (and_sel   and (a(1) and b(1)))
         or (or_sel    and (a(1) or b(1)))
         or (xor_sel   and (a(1) xor b(1)))
         or (arith_sel and ((a(1) xor b(1)) xor d1))
         or (shr_sel   and sh(1))
         or (passa_sel and a(1));

    f(2) <= (pass_sel  and b(2))
         or (and_sel   and (a(2) and b(2)))
         or (or_sel    and (a(2) or b(2)))
         or (xor_sel   and (a(2) xor b(2)))
         or (arith_sel and ((a(2) xor b(2)) xor d2))
         or (shr_sel   and sh(2))
         or (passa_sel and a(2));

    f(3) <= (pass_sel  and b(3))
         or (and_sel   and (a(3) and b(3)))
         or (or_sel    and (a(3) or b(3)))
         or (xor_sel   and (a(3) xor b(3)))
         or (arith_sel and ((a(3) xor b(3)) xor d3))
         or (shr_sel   and sh(3))
         or (passa_sel and a(3));

    -- carry output: ADD carry, SUB borrow, SHR shifts out A0,
    -- PASS A gives 0
    cout <= (arith_sel and d4)
         or (shr_sel and a(0));

    -- zero flag (uses the F pin feedback, a single product term)
    z <= (not f(0)) and (not f(1)) and (not f(2)) and (not f(3));

end architecture rtl;
