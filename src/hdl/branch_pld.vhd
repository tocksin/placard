-- ============================================================
-- BRANCH_CTRL  (VHDL conversion of ATF22V10_BRANCH.pld, Rev 13)
-- Date: 10/19/2026
--
-- Branch / jump control, plus the ALU wait clock (Rev 06, Rev 07).
--
-- ALU WAIT: the first EXEC clock of an ADD/SUB whose destination is
-- AC, X or Y is a stall clock, so the result loads at the end of the
-- second:
--     stall      = pixel_enable or (exec and addsub_reg and not alu_done)
--     alu_done.D = (exec and not pixel_enable and addsub_reg and not alu_done)
--               or (alu_done and pixel_enable)
-- stall replaces pixel_enable on the State PLD and both PC PLDs.  The
-- video keeps the real pixel_enable.  (Rev 06 stalled the clock after
-- the load; see the PLD source.)
--
-- Rev 08: block B (the FETCH decode of db7:db5) is removed.  The State
-- PLD no longer needs branch_block in FETCH, because BGE with an AC or
-- X target now has a pad byte (State PLD Rev 11).  Pins 14-16 are unused.
--
-- Rev 09: branch_block = i7 and i6 and i5, straight from the instruction
-- register, so the State PLD's mem_wr settles early in EXEC (see the PLD
-- source).  The State PLD only uses branch_block in EXEC.
--
-- Rev 10: srcEn (pin 16) = exec and not pixel_enable, the time the
-- source F541s drive the one data bus (the RAM write-data buffer is
-- gone).  It goes to the memory control PLD, which blocks CPU reads.
--
-- Rev 11: carry flag.  BGT (001) and BGE (101) become BCS and BCC.
-- cout (pin 14) is the high ALU's carry out (borrow out for SUB);
-- carry (pin 20, registered) latches it on the clock that loads an
-- ADD/SUB result into AC, X or Y (alu_done set, pixel_enable low) and
-- holds it on every other clock:
--     carry.D = (alu_done and not pixel_enable and cout)
--            or (alu_done and pixel_enable and carry)
--            or (not alu_done and carry)
--
-- Rev 12: pix_ld_n (pin 15, free until now) = not pixel_enable, the
-- pixel buffer F377's /E (it loads when /E is low, on the video read).
-- Rev 13: pin 16 is active low, srcEnN.  It drives /OE1 of both source
-- F541s (D and AC; X is no longer a source and the source '138 is gone)
-- and the memory control PLD's pin 22.
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- ALU field I7:I5 = 111 selects branch/jump.
-- Memory-mode field M2:M0 (instruction bits 4:2) selects type:
--
--     000 JMP  always, 16-bit load (PC low + PC high)
--     001 BCS  carry flag set     (was BGT)
--     010 BLT  AC < 0
--     011 BNE  AC <> 0
--     100 BEQ  AC = 0
--     101 BCC  carry flag clear   (was BGE)
--     110 BLE  AC <= 0
--     111 BRA  always, 8-bit load (PC low only)
--
-- The ALU performs PASS A for the branch opcode, so each ALU Z output
-- is the zero flag of one nibble of the accumulator.
--
-- z_low  = low  ALU nibble is zero
-- z_high = high ALU nibble is zero
-- AC = 0 is  z_low and z_high;  AC <> 0 is  not z_low or not z_high
-- neg    = accumulator MSB (negative)
-- AC = 0 and neg are never both true.
--
-- pixel_enable = 1 means video owns the bus.
--
-- EXEC state: exec = q0 and not pc_enable
--     q0        = State PLD pin 18 (true polarity)
--     pc_enable = State PLD pin 15 (= not Q1)
--
-- load_pc_low and load_pc_high are active only in EXEC with
-- pixel_enable = 0.
--
-- Branch decode (EXEC): i7:i5 from the instruction register
--     branch_a = i7 and i6 and i5 and exec and not pixel_enable
--
-- branch_block = i7 and i6 and i5: high whenever the instruction
-- register holds a branch/jump.  It is active high here.
--
-- Pin assignments (ATF22V10C, 24-pin DIP; pin 12 = GND, pin 24 = VCC):
--   1  clk          17  i7            2  i6            3  i5
--   4  m2            5  m1            6  m0
--   7  z_low         8  neg           9  pixel_enable
--  10  q0           11  pc_enable    13  z_high
--  14  cout         15  pix_ld_n     16  srcEnN
--  18  alu_done     19  stall        20  carry
--  21  load_pc_low  22  load_pc_high 23  branch_block
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity branch_pld is
    port (
        clk           : in  std_logic;   -- pin 1, CPU clock (alu_done register)

        i7            : in  std_logic;   -- pin 17 (I/O pin used as an input)
        i6            : in  std_logic;   -- pin 2
        i5            : in  std_logic;   -- pin 3

        m2            : in  std_logic;   -- pin 4
        m1            : in  std_logic;   -- pin 5
        m0            : in  std_logic;   -- pin 6

        z_low         : in  std_logic;   -- pin 7, low  ALU nibble zero
        neg           : in  std_logic;   -- pin 8

        pixel_enable  : in  std_logic;   -- pin 9, 1 = video owns the bus

        q0            : in  std_logic;   -- pin 10, State PLD pin 18, state bit 0
        pc_enable     : in  std_logic;   -- pin 11, State PLD pin 15, = not Q1

        z_high        : in  std_logic;   -- pin 13, high ALU nibble zero

        cout          : in  std_logic;   -- pin 14, high ALU carry / borrow out

        load_pc_low   : out std_logic;   -- pin 21
        load_pc_high  : out std_logic;   -- pin 22
        branch_block  : out std_logic;   -- pin 23

        alu_done      : out std_logic;   -- pin 18, registered
        stall         : out std_logic;   -- pin 19
        srcEnN        : out std_logic;   -- pin 16, low = source F541s drive the bus (Rev 13)
        carry         : out std_logic;   -- pin 20, registered carry flag
        pix_ld_n      : out std_logic    -- pin 15, pixel buffer /E (Rev 12)
    );
end entity branch_pld;

architecture rtl of branch_pld is

    -- common terms
    signal exec     : std_logic;
    signal branch_a : std_logic;   -- block A, EXEC state, instruction register

    signal addsub_reg : std_logic; -- ADD/SUB with an AC, X or Y destination
    signal alu_done_q : std_logic := '0';   -- powers up to 0, as on the ATF22V10C
    signal carry_q    : std_logic := '0';   -- powers up to 0, as on the ATF22V10C

begin

    -- --------------------------------------------------------
    -- Common terms
    -- --------------------------------------------------------
    exec     <= q0 and not pc_enable;

    branch_a <= i7 and i6 and i5 and exec and not pixel_enable;

    -- ADD (100) or SUB (101), destination AC, X or Y
    -- (M = 000..100; 101, 110, 111 are RAM destinations).
    addsub_reg <= i7 and not i6 and not (m2 and (m1 or m0));

    -- --------------------------------------------------------
    -- ALU wait: first EXEC clock of an ADD/SUB is a stall clock
    -- --------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            alu_done_q <= (exec and not pixel_enable and addsub_reg and not alu_done_q)
                       or (alu_done_q and pixel_enable);
        end if;
    end process;

    alu_done <= alu_done_q;

    -- --------------------------------------------------------
    -- Carry flag (Rev 11)
    -- --------------------------------------------------------
    process (clk)
    begin
        if rising_edge(clk) then
            carry_q <= (alu_done_q and not pixel_enable and cout)
                    or (alu_done_q and pixel_enable and carry_q)
                    or (not alu_done_q and carry_q);
        end if;
    end process;

    carry <= carry_q;
    stall    <= pixel_enable
             or (exec and addsub_reg and not alu_done_q);

    -- --------------------------------------------------------
    -- Equations
    -- --------------------------------------------------------
    branch_block <= i7 and i6 and i5;

    -- --------------------------------------------------------
    -- Source bus enable (Rev 10), active low since Rev 13
    -- --------------------------------------------------------
    srcEnN <= not (exec and not pixel_enable);

    -- Rev 12: pixel buffer load, pin declared !PIX_LD
    pix_ld_n <= not pixel_enable;

    load_pc_high <= branch_a and not m2 and not m1 and not m0;            -- JMP

    load_pc_low  <= (branch_a and not m2 and not m1 and not m0)                                -- JMP
                 or (branch_a and not m2 and not m1 and     m0 and     carry_q)                -- BCS
                 or (branch_a and not m2 and     m1 and not m0 and not z_low  and     neg)     -- BLT, low nibble <> 0
                 or (branch_a and not m2 and     m1 and not m0 and not z_high and     neg)     -- BLT, high nibble <> 0
                 or (branch_a and not m2 and     m1 and     m0 and not z_low)                  -- BNE, low nibble <> 0
                 or (branch_a and not m2 and     m1 and     m0 and not z_high)                 -- BNE, high nibble <> 0
                 or (branch_a and     m2 and not m1 and not m0 and     z_low and z_high)       -- BEQ
                 or (branch_a and     m2 and not m1 and     m0 and not carry_q)                -- BCC
                 or (branch_a and     m2 and     m1 and not m0 and     z_low and z_high)       -- BLE, AC=0
                 or (branch_a and     m2 and     m1 and not m0 and     neg)                    -- BLE, AC<0
                 or (branch_a and     m2 and     m1 and     m0);                               -- BRA

end architecture rtl;
