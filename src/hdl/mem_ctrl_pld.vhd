-- ============================================================
-- MEMORY READ AND WRITE STROBES
-- VHDL conversion of ATF22V10_MEM_CTRL.pld (revision 04)
-- Date: 10/16/2026
--
-- Replaces the '32 OR gate (/WE = RW or CLK) and the read enables
-- of ROM/RAM select revision 03.  Every memory bus cycle uses the
-- low half of the clock only, so nothing drives the RAM data bus in
-- the high half and a read can't overlap the write buffer turning
-- off (see the PLD source and TIMING_FIXES.md).
--
-- Revision 02: mapRun (pin 19) is a register that powers up to 0 and
-- loads 1 on every clock, so it is low from power-up to the first
-- clock.  It drives /MR of the 74ACT273 map register, which clears the
-- map to all ROM before the CPU starts.
--
-- Revision 03: ramsel2 (pin 15) maps 4000h-4FFFh like the other
-- sections (it was always RAM).  romOeN moved to pin 19 and mapRun to
-- pin 17.
--
-- Revision 04: a video read (pixelEnable = 1) always reads the RAM;
-- only CPU reads follow the map, so the CPU can run from the ROM under
-- the video area while the video shows the RAM.
--
--     write  = not rw and not pixelEnable
--     cpuRead   = rw and not pixelEnable
--     videoRead = pixelEnable
--     weN    = low while clk = 0 and a write
--     romOeN = low while clk = 0 and a CPU read of a ROM section
--     ramOeN = low while clk = 0 and a CPU read of a RAM section,
--              or a video read
--              (section 2 is mapped for 4000h-4FFFh only; neither
--              memory reads in the I/O window 5000h-5FFFh)
--
-- rw is State PLD pin 23 (Rev 12: low for the whole EXEC state of a
-- store).  pixelEnable is the Sync PLD's PIXEL_ENABLE, not STALL.
--
-- Equations are transcribed directly from the PLD source
-- without optimization.  All pins are kept as individual
-- std_logic signals.
--
-- Pin assignments (ATF22V10C):
--   1  clk         2  a15        3  a14        4  a13       5  a12
--   6  ramsel0     7  ramsel1    8  ramsel3    9  ramsel4  10  ramsel5
--  11  ramsel6    13  ramsel7   14  rw        15  ramsel2
--  23  pixelEnable
--  16  weN        17  mapRun    18  ramOeN    19  romOeN
--  20-22 not used
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity mem_ctrl_pld is
    port (
        clk         : in  std_logic;   -- pin 1, CPU clock (array input only)
        a15         : in  std_logic;   -- pin 2
        a14         : in  std_logic;   -- pin 3
        a13         : in  std_logic;   -- pin 4
        a12         : in  std_logic;   -- pin 5
        ramsel0     : in  std_logic;   -- pin 6, map from the 74ACT273 map register
        ramsel1     : in  std_logic;   -- pin 7
        ramsel3     : in  std_logic;   -- pin 8
        ramsel4     : in  std_logic;   -- pin 9
        ramsel5     : in  std_logic;   -- pin 10
        ramsel6     : in  std_logic;   -- pin 11
        ramsel7     : in  std_logic;   -- pin 13
        ramsel2     : in  std_logic;   -- pin 15 (I/O pin used as input)
        rw          : in  std_logic;   -- pin 14, State PLD pin 23, 0 = store
        pixelEnable : in  std_logic;   -- pin 23, Sync PLD PIXEL_ENABLE

        weN         : out std_logic;   -- pin 16, RAM /WE and write buffer enable
        romOeN      : out std_logic;   -- pin 19, ROM /OE
        ramOeN      : out std_logic;   -- pin 18, RAM /OE
        mapRun      : out std_logic    -- pin 17, registered, map register /MR
    );
end entity mem_ctrl_pld;

architecture rtl of mem_ctrl_pld is

    -- section decode
    signal sec0 : std_logic;
    signal sec1 : std_logic;
    signal sec2 : std_logic;
    signal sec3 : std_logic;
    signal sec4 : std_logic;
    signal sec5 : std_logic;
    signal sec6 : std_logic;
    signal sec7 : std_logic;

    signal cpuRead   : std_logic;
    signal videoRead : std_logic;
    signal we      : std_logic;
    signal romOe   : std_logic;
    signal ramOe   : std_logic;
    signal mapRunQ : std_logic := '0';   -- powers up to 0, as on the ATF22V10C

begin

    -- ---------------- section decode ----------------

    sec0 <= (not a15) and (not a14) and (not a13);
    sec1 <= (not a15) and (not a14) and (    a13);
    sec2 <= (not a15) and (    a14) and (not a13);
    sec3 <= (not a15) and (    a14) and (    a13);
    sec4 <= (    a15) and (not a14) and (not a13);
    sec5 <= (    a15) and (not a14) and (    a13);
    sec6 <= (    a15) and (    a14) and (not a13);
    sec7 <= (    a15) and (    a14) and (    a13);

    -- ---------------- bus cycle ----------------

    cpuRead   <= (not clk) and rw and (not pixelEnable);
    videoRead <= (not clk) and pixelEnable;

    -- ---------------- equations ----------------

    we <= (not clk) and (not rw) and (not pixelEnable);

    romOe <= (sec0 and (not ramsel0) and cpuRead)
          or (sec1 and (not ramsel1) and cpuRead)
          or (sec2 and (not a12) and (not ramsel2) and cpuRead)
          or (sec3 and (not ramsel3) and cpuRead)
          or (sec4 and (not ramsel4) and cpuRead)
          or (sec5 and (not ramsel5) and cpuRead)
          or (sec6 and (not ramsel6) and cpuRead)
          or (sec7 and (not ramsel7) and cpuRead);

    ramOe <= (sec0 and ramsel0 and cpuRead)
          or (sec1 and ramsel1 and cpuRead)
          or (sec2 and (not a12) and ramsel2 and cpuRead)
          or (sec3 and ramsel3 and cpuRead)
          or (sec4 and ramsel4 and cpuRead)
          or (sec5 and ramsel5 and cpuRead)
          or (sec6 and ramsel6 and cpuRead)
          or (sec7 and ramsel7 and cpuRead)
          or (a15 and videoRead)
          or ((not a14) and videoRead)
          or (a13 and videoRead)
          or ((not a12) and videoRead);

    process (clk)
    begin
        if rising_edge(clk) then
            mapRunQ <= '1';
        end if;
    end process;

    mapRun <= mapRunQ;

    weN    <= not we;
    romOeN <= not romOe;
    ramOeN <= not ramOe;

end architecture rtl;
