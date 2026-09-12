--------------------------------------------------------------------------------
-- File Name:     alu.vhd
-- Description:   4-bit ALU slice for cascading into wider ALUs.
--                Converted from CUPL PLD code 
--
-- Arithmetic:
--   M=0:
--     S1 S0 = 00  A AND B
--     S1 S0 = 01  A OR B
--     S1 S0 = 10  A XOR B
--     S1 S0 = 11  NOT A
--
--   M=1:
--     S1 S0 = 00  A + B + CIN
--     S1 S0 = 01  A - B - CIN
--     S1 S0 = 10  A + CIN   (CIN=0 passes A, CIN=1 increments)
--     S1 S0 = 11  A - CIN   (CIN=0 passes A, CIN=1 decrements)
--
-- C1-C4 are RAW arithmetic carry/borrow signals:
--   ADD/INC: 1 = carry out
--   SUB/DEC: 1 = borrow out
--
-- This makes C4 directly chainable to the CIN of the next 4-bit slice.
--
-- For a CPU-style carry flag, invert C4 during SUB/DEC:
--   CPU_C = C4 XOR (M & S0)
--
-- V is signed overflow. Z is zero detect. N is F3 externally.

library ieee;   use ieee.std_logic_1164.all;

entity alu is
    Port (
        A0   : in  std_logic;
        A1   : in  std_logic;
        A2   : in  std_logic;
        A3   : in  std_logic;
        B0   : in  std_logic;
        B1   : in  std_logic;
        B2   : in  std_logic;
        B3   : in  std_logic;
        S0   : in  std_logic;
        S1   : in  std_logic;
        M    : in  std_logic;
        CIN  : in  std_logic;
        F0   : out std_logic;
        F1   : out std_logic;
        F2   : out std_logic;
        F3   : out std_logic;
        C1   : out std_logic;
        C2   : out std_logic;
        C3   : out std_logic;
        C4   : out std_logic;
        Z    : out std_logic;
        V    : out std_logic
    );
end alu;

architecture Dataflow of alu is
    -- Internal signals for carry/borrow to allow reading in F and V calculations
    signal C1_sig : std_logic;
    signal C2_sig : std_logic;
    signal C3_sig : std_logic;
    signal C4_sig : std_logic;
begin

    -- ============================================================
    -- RAW CARRY / BORROW OUTPUT C1
    -- ============================================================
    C1_sig <=
          (A0 and CIN and M and not S0)
        or (B0 and CIN and M and not S1)
        or (CIN and M and S0 and not A0)
        or (A0 and B0 and M and not S0 and not S1)
        or (B0 and M and S0 and not A0 and not S1);

    -- ============================================================
    -- RAW CARRY / BORROW OUTPUT C2
    -- ============================================================
    C2_sig <=
          (A1 and C1_sig and M and not S0)
        or (B1 and C1_sig and M and not S1)
        or (C1_sig and M and S0 and not A1)
        or (A1 and B1 and M and not S0 and not S1)
        or (B1 and M and S0 and not A1 and not S1);

    -- ============================================================
    -- RAW CARRY / BORROW OUTPUT C3
    -- ============================================================
    C3_sig <=
          (A2 and C2_sig and M and not S0)
        or (B2 and C2_sig and M and not S1)
        or (C2_sig and M and S0 and not A2)
        or (A2 and B2 and M and not S0 and not S1)
        or (B2 and M and S0 and not A2 and not S1);

    -- ============================================================
    -- RAW CARRY / BORROW OUTPUT C4
    -- ============================================================
    C4_sig <=
          (A3 and C3_sig and M and not S0)
        or (B3 and C3_sig and M and not S1)
        or (C3_sig and M and S0 and not A3)
        or (A3 and B3 and M and not S0 and not S1)
        or (B3 and M and S0 and not A3 and not S1);

    -- ============================================================
    -- DATA OUTPUT F0
    -- ============================================================
    F0 <=
          (A0 and B0 and CIN and not S1)
        or (A0 and M and S1 and not CIN)
        or (CIN and M and S1 and not A0)
        or (A0 and B0 and not M and not S1)
        or (A0 and M and not B0 and not CIN)
        or (A0 and S0 and not M and not S1)
        or (B0 and S0 and not A0 and not M)
        or (B0 and S1 and not A0 and not M)
        or (CIN and M and not A0 and not B0)
        or (S0 and S1 and not A0 and not M)
        or (A0 and S1 and not B0 and not M and not S0)
        or (B0 and M and not A0 and not CIN and not S1);

    -- ============================================================
    -- DATA OUTPUT F1
    -- ============================================================
    F1 <=
          (A1 and B1 and C1_sig and not S1)
        or (A1 and M and S1 and not C1_sig)
        or (C1_sig and M and S1 and not A1)
        or (A1 and B1 and not M and not S1)
        or (A1 and M and not B1 and not C1_sig)
        or (A1 and S0 and not M and not S1)
        or (B1 and S0 and not A1 and not M)
        or (B1 and S1 and not A1 and not M)
        or (C1_sig and M and not A1 and not B1)
        or (S0 and S1 and not A1 and not M)
        or (A1 and S1 and not B1 and not M and not S0)
        or (B1 and M and not A1 and not C1_sig and not S1);

    -- ============================================================
    -- DATA OUTPUT F2
    -- ============================================================
    F2 <=
          (A2 and B2 and C2_sig and not S1)
        or (A2 and M and S1 and not C2_sig)
        or (C2_sig and M and S1 and not A2)
        or (A2 and B2 and not M and not S1)
        or (A2 and M and not B2 and not C2_sig)
        or (A2 and S0 and not M and not S1)
        or (B2 and S0 and not A2 and not M)
        or (B2 and S1 and not A2 and not M)
        or (C2_sig and M and not A2 and not B2)
        or (S0 and S1 and not A2 and not M)
        or (A2 and S1 and not B2 and not M and not S0)
        or (B2 and M and not A2 and not C2_sig and not S1);

    -- ============================================================
    -- DATA OUTPUT F3
    -- ============================================================
    F3 <=
          (A3 and B3 and C3_sig and not S1)
        or (A3 and M and S1 and not C3_sig)
        or (C3_sig and M and S1 and not A3)
        or (A3 and B3 and not M and not S1)
        or (A3 and M and not B3 and not C3_sig)
        or (A3 and S0 and not M and not S1)
        or (B3 and S0 and not A3 and not M)
        or (B3 and S1 and not A3 and not M)
        or (C3_sig and M and not A3 and not B3)
        or (S0 and S1 and not A3 and not M)
        or (A3 and S1 and not B3 and not M and not S0)
        or (B3 and M and not A3 and not C3_sig and not S1);

    -- ============================================================
    -- ZERO FLAG
    -- ============================================================
    Z <=
          (not F3 and not F2 and not F1 and not F0);

    -- ============================================================
    -- SIGNED OVERFLOW FLAG
    -- ============================================================
    V <=
          (A3 and C3_sig and M and S0 and S1)
        or (A3 and C3_sig and M and S0 and not B3)
        or (C3_sig and M and S1 and not A3 and not S0)
        or (C3_sig and M and not A3 and not B3 and not S0)
        or (A3 and B3 and M and not C3_sig and not S0 and not S1)
        or (B3 and M and S0 and not A3 and not C3_sig and not S1);

    -- Output Assignments
    C1 <= C1_sig;
    C2 <= C2_sig;
    C3 <= C3_sig;
    C4 <= C4_sig;

end Dataflow;


-- Name     ATF22V10_ALU;
-- PartNo   22V10;
-- Date     09/11/2026;
-- Revision 08;
-- Designer ;
-- Company  ;
-- Assembly ;
-- Location ;
-- Device   v22v10;

-- /* ============================================================
   -- 4-BIT ALU
   -- ============================================================

   -- Logic mode (M = 0):
       -- S1 S0
        -- 0  0    A AND B
        -- 0  1    A OR B
        -- 1  0    A XOR B
        -- 1  1    NOT A

   -- Arithmetic mode (M = 1):
       -- S1 S0
        -- 0  0    A + B + CIN
        -- 0  1    A - B - CIN
        -- 1  0    A + CIN
        -- 1  1    A - CIN

   -- C1-C4 are RAW carry/borrow outputs:
       -- ADD/INC : 1 = carry
       -- SUB/DEC : 1 = borrow

   -- ============================================================ */


-- /* ============================================================
   -- INPUTS
   -- ============================================================ */

-- PIN 1  = A0;
-- PIN 2  = A1;
-- PIN 3  = A2;
-- PIN 4  = A3;

-- PIN 5  = B0;
-- PIN 6  = B1;
-- PIN 7  = B2;
-- PIN 8  = B3;

-- PIN 9  = S0;
-- PIN 10 = S1;
-- PIN 11 = M;

-- PIN 13 = CIN;


-- /* ============================================================
   -- OUTPUTS
   -- ============================================================ */

-- PIN 18 = F0;
-- PIN 19 = F1;
-- PIN 17 = F2;
-- PIN 20 = F3;

-- PIN 14 = C1;
-- PIN 23 = C2;
-- PIN 15 = C3;
-- PIN 22 = C4;

-- PIN 16 = Z;
-- PIN 21 = V;


-- /* ============================================================
   -- DATA OUTPUT F0
   -- ============================================================ */

-- F0 =
      -- (A0 & B0 & CIN & !S1)
    -- # (A0 & M & S1 & !CIN)
    -- # (CIN & M & S1 & !A0)
    -- # (A0 & B0 & !M & !S1)
    -- # (A0 & M & !B0 & !CIN)
    -- # (A0 & S0 & !M & !S1)
    -- # (B0 & S0 & !A0 & !M)
    -- # (B0 & S1 & !A0 & !M)
    -- # (CIN & M & !A0 & !B0)
    -- # (S0 & S1 & !A0 & !M)
    -- # (A0 & S1 & !B0 & !M & !S0)
    -- # (B0 & M & !A0 & !CIN & !S1);


-- /* ============================================================
   -- DATA OUTPUT F1
   -- ============================================================ */

-- F1 =
      -- (A1 & B1 & C1 & !S1)
    -- # (A1 & M & S1 & !C1)
    -- # (C1 & M & S1 & !A1)
    -- # (A1 & B1 & !M & !S1)
    -- # (A1 & M & !B1 & !C1)
    -- # (A1 & S0 & !M & !S1)
    -- # (B1 & S0 & !A1 & !M)
    -- # (B1 & S1 & !A1 & !M)
    -- # (C1 & M & !A1 & !B1)
    -- # (S0 & S1 & !A1 & !M)
    -- # (A1 & S1 & !B1 & !M & !S0)
    -- # (B1 & M & !A1 & !C1 & !S1);


-- /* ============================================================
   -- DATA OUTPUT F2
   -- ============================================================ */

-- F2 =
      -- (A2 & B2 & C2 & !S1)
    -- # (A2 & M & S1 & !C2)
    -- # (C2 & M & S1 & !A2)
    -- # (A2 & B2 & !M & !S1)
    -- # (A2 & M & !B2 & !C2)
    -- # (A2 & S0 & !M & !S1)
    -- # (B2 & S0 & !A2 & !M)
    -- # (B2 & S1 & !A2 & !M)
    -- # (C2 & M & !A2 & !B2)
    -- # (S0 & S1 & !A2 & !M)
    -- # (A2 & S1 & !B2 & !M & !S0)
    -- # (B2 & M & !A2 & !C2 & !S1);


-- /* ============================================================
   -- DATA OUTPUT F3
   -- ============================================================ */

-- F3 =
      -- (A3 & B3 & C3 & !S1)
    -- # (A3 & M & S1 & !C3)
    -- # (C3 & M & S1 & !A3)
    -- # (A3 & B3 & !M & !S1)
    -- # (A3 & M & !B3 & !C3)
    -- # (A3 & S0 & !M & !S1)
    -- # (B3 & S0 & !A3 & !M)
    -- # (B3 & S1 & !A3 & !M)
    -- # (C3 & M & !A3 & !B3)
    -- # (S0 & S1 & !A3 & !M)
    -- # (A3 & S1 & !B3 & !M & !S0)
    -- # (B3 & M & !A3 & !C3 & !S1);


-- /* ============================================================
   -- RAW CARRY / BORROW OUTPUT C1
   -- ============================================================ */

-- C1 =
      -- (A0 & CIN & M & !S0)
    -- # (B0 & CIN & M & !S1)
    -- # (CIN & M & S0 & !A0)
    -- # (A0 & B0 & M & !S0 & !S1)
    -- # (B0 & M & S0 & !A0 & !S1);


-- /* ============================================================
   -- RAW CARRY / BORROW OUTPUT C2
   -- ============================================================ */

-- C2 =
      -- (A1 & C1 & M & !S0)
    -- # (B1 & C1 & M & !S1)
    -- # (C1 & M & S0 & !A1)
    -- # (A1 & B1 & M & !S0 & !S1)
    -- # (B1 & M & S0 & !A1 & !S1);


-- /* ============================================================
   -- RAW CARRY / BORROW OUTPUT C3
   -- ============================================================ */

-- C3 =
      -- (A2 & C2 & M & !S0)
    -- # (B2 & C2 & M & !S1)
    -- # (C2 & M & S0 & !A2)
    -- # (A2 & B2 & M & !S0 & !S1)
    -- # (B2 & M & S0 & !A2 & !S1);


-- /* ============================================================
   -- RAW CARRY / BORROW OUTPUT C4
   -- ============================================================ */

-- C4 =
      -- (A3 & C3 & M & !S0)
    -- # (B3 & C3 & M & !S1)
    -- # (C3 & M & S0 & !A3)
    -- # (A3 & B3 & M & !S0 & !S1)
    -- # (B3 & M & S0 & !A3 & !S1);


-- /* ============================================================
   -- ZERO FLAG
   -- ============================================================ */

-- Z =
      -- (!F3 & !F2 & !F1 & !F0);


-- /* ============================================================
   -- SIGNED OVERFLOW FLAG
   -- ============================================================ */

-- V =
      -- (A3 & C3 & M & S0 & S1)
    -- # (A3 & C3 & M & S0 & !B3)
    -- # (C3 & M & S1 & !A3 & !S0)
    -- # (C3 & M & !A3 & !B3 & !S0)
    -- # (A3 & B3 & M & !C3 & !S0 & !S1)
    -- # (B3 & M & S0 & !A3 & !C3 & !S1);
    