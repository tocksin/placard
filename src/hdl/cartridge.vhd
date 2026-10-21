-- ============================================================
-- ROM CARTRIDGE model
-- Date: 10/21/2026
--
-- The cartridge as the board sees it (docs/ROM.md, "Loading the
-- cartridge"): the loader PLD (cart_pld, ATF22V10_CART.pld rev 04),
-- the two AT28C256 EEPROMs that hold the image and the two AS7C256C
-- SRAMs the CPU reads once the image is loaded.  Each pair is one
-- 64K block here (A15 is the /CE_LO / /CE_HI split on the cartridge).
--
--   romComp   the EEPROMs, initialized from rom.mem (gen_rom.tcl).
--             Keep the name: the updatemem scripts find it by it.
--   sramComp  the SRAMs, initialized from cart_ram.mem
--             (gen_random_ram.tcl: random bytes, as a real SRAM
--             powers up).  /WE is the loader's /SR_WE and the write
--             data is the EEPROM byte on the bus.
--
-- At power-up RUN is low and the loader holds STALL_OUT high while
-- the PC is on the address bus, copies the EEPROM byte at the PC
-- into the SRAM, then lets the CPU take one step (the instruction
-- register holds 02h, so the CPU only walks the image).  When the PC
-- wraps to x0000 RUN goes high and the CPU runs from the SRAM.
--
-- The FPGA has no tri-state data bus, so the cartridge gives its
-- byte (data) and whether its EEPROMs drive the bus (eeDrive); the
-- top level picks it.  The SRAMs drive when the board's /ROM_OE
-- selects them, which the top level decodes as romSel.  While RUN is
-- low and nothing drives the bus, the real bus keeps the last EEPROM
-- byte for a while (its capacitance against the 10k pull-ups), and
-- the State PLD reads that byte at the end of the release clock:
-- data gives the last EEPROM byte then.
-- ============================================================

library ieee;
use ieee.std_logic_1164.all;

entity cartridge is
    port (
        clk         : in  std_logic;                     -- the board clock (OSC)
        clkSystem   : in  std_logic;                     -- faster clock for the memory models
        addr        : in  std_logic_vector(15 downto 0); -- address bus (A15 = /CE_LO)
        pixelEnable : in  std_logic;                     -- Sync PLD PIXEL_ENABLE
        pcEnable    : in  std_logic;                     -- State PLD PC_ENABLE
        stallIn     : in  std_logic;                     -- Branch PLD STALL

        data        : out std_logic_vector(7 downto 0);  -- the cartridge's byte for the data bus
        eeDrive     : out std_logic;                     -- 1 = the EEPROMs drive the data bus
        run         : out std_logic;                     -- RUN to the board
        stallOut    : out std_logic                      -- STALL to the State and PC PLDs
    );
end entity cartridge;

architecture rtl of cartridge is

    signal srWeN    : std_logic;
    signal eeOeN    : std_logic;
    signal runI     : std_logic;
    signal eeData   : std_logic_vector(7 downto 0);
    signal sramData : std_logic_vector(7 downto 0);
    signal lastEe   : std_logic_vector(7 downto 0) := x"FF";  -- bus charge after the EEPROM lets go

begin

    loaderComp : entity work.cart_pld
    port map(
        clk         => clk,
        a15         => addr(15),
        pixelEnable => pixelEnable,
        pcEnable    => pcEnable,
        stallIn     => stallIn,

        g0          => open,
        g1          => open,
        g2          => open,
        copy        => open,
        prev15      => open,
        srWeN       => srWeN,
        eeOeN       => eeOeN,
        synced      => open,
        run         => runI,
        stallOut    => stallOut
    );

    -- EEPROMs: read only on the board (/WE tied high)
    romComp : entity work.sp_ram
    generic map( initFile => "rom.mem" )
    port map(   iClk    => clkSystem,  -- faster clock to simulate the async part
                iWrEn   => '0',
                iRamEn  => '1',
                iAddr   => addr,
                iData   => (eeData'range => '0'),
                oData   => eeData);

    -- SRAMs: written by the loader with the EEPROM byte on the bus
    sramComp : entity work.sp_ram
    generic map( initFile => "cart_ram.mem" )
    port map(   iClk    => clkSystem,
                iWrEn   => not srWeN,
                iRamEn  => '1',
                iAddr   => addr,
                iData   => eeData,
                oData   => sramData);

    -- the bus keeps the EEPROM's last byte once /EE_OE goes high
    lastEeProc : process (clkSystem)
    begin
        if rising_edge(clkSystem) then
            if eeOeN = '0' then
                lastEe <= eeData;
            end if;
        end if;
    end process lastEeProc;

    data    <= eeData   when eeOeN = '0' else
               sramData when runI = '1'  else
               lastEe;
    eeDrive <= not eeOeN;
    run     <= runI;

end architecture rtl;
