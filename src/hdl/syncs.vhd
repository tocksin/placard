library IEEE;
use IEEE.STD_LOGIC_1164.all;

entity syncs is
    Port (
        -- Horizontal counter bits
        H9, H8, H7, H6, H5, H4 : in STD_LOGIC;
        -- Vertical counter bits
        V9, V8, V7, V6, V5, V4, V3, V2, V1 : in STD_LOGIC;
        -- Outputs
        HSYNC, VSYNC, VIDEO_ENABLE : out STD_LOGIC
    );
end syncs;

architecture Behavioral of syncs is

    -- Horizontal Active Video (HCOUNT = 0..639)
    signal H_ACTIVE : STD_LOGIC;

    -- Vertical Active Video (VCOUNT = 0..479)
    signal V_ACTIVE : STD_LOGIC;

    -- Horizontal Sync Active LOW (HCOUNT = 656..751)
    signal HSYNC_ACTIVE : STD_LOGIC;

    -- Vertical Sync Active LOW (VCOUNT = 490..491)
    signal VSYNC_ACTIVE : STD_LOGIC;

begin

    -- H_ACTIVE = !H9 # (!H8 & !H7)
    H_ACTIVE <= not H9 or (not H8 and not H7);

    -- HSYNC_ACTIVE = (H9 & H7 & !H8 & !H5 & H4) # (H9 & H7 & !H8 & H6 & H5) # (H9 & H7 & !H8 & !H6 & !H4)
    HSYNC_ACTIVE <= (H9 and H7 and not H8 and not H5 and H4) or
                    (H9 and H7 and not H8 and H6 and H5) or
                    (H9 and H7 and not H8 and not H6 and not H4);

    -- HSYNC = !HSYNC_ACTIVE
    HSYNC <= not HSYNC_ACTIVE;

    -- V_ACTIVE = (!V9 & !V8) # (!V9 & !V7) # (!V9 & !V6) # (!V9 & !V5)
    V_ACTIVE <= (not V9 and not V8) or
                (not V9 and not V7) or
                (not V9 and not V6) or
                (not V9 and not V5);

    -- VSYNC_ACTIVE = !V9 & V8 & V7 & V6 & V5 & !V4 & V3 & !V2 & V1
    VSYNC_ACTIVE <= not V9 and V8 and V7 and V6 and V5 and not V4 and V3 and not V2 and V1;

    -- VSYNC = !VSYNC_ACTIVE
    VSYNC <= not VSYNC_ACTIVE;

    -- VIDEO_ENABLE = (!H9 & !V9 & !V8) # (!H9 & !V9 & !V7) # (!H9 & !V9 & !V6) # (!H9 & !V9 & !V5)
    --              # (!H8 & !H7 & !V9 & !V8) # (!H8 & !H7 & !V9 & !V7) # (!H8 & !H7 & !V9 & !V6) # (!H8 & !H7 & !V9 & !V5)
    VIDEO_ENABLE <= (not H9 and not V9 and not V8) or
                    (not H9 and not V9 and not V7) or
                    (not H9 and not V9 and not V6) or
                    (not H9 and not V9 and not V5) or
                    (not H8 and not H7 and not V9 and not V8) or
                    (not H8 and not H7 and not V9 and not V7) or
                    (not H8 and not H7 and not V9 and not V6) or
                    (not H8 and not H7 and not V9 and not V5);

    -- Output signals are driven by the internal signals defined above
end Behavioral;
