# Documentation

Date: 2026-11-06

The design documents, grouped by subject.  Drawings sit next to the document that uses them.

## [architecture/](architecture/)

- [CPU.md](architecture/CPU.md): CPU operations, instruction set and memory parts
- [CHIPS.md](architecture/CHIPS.md): every chip, one per line (U numbers used on the schematic)
- [ROM.md](architecture/ROM.md): ROM layout, cartridge loading and boot
- [IO.md](architecture/IO.md): the shared port (SNES pads, SD card, PS/2 keyboard and mouse)
- [EXPANSION.md](architecture/EXPANSION.md): expansion slots and the ROM cartridge slot
- [PLD_USAGE.md](architecture/PLD_USAGE.md): unused pins and product terms in each 22V10

## [timing/](timing/)

- [TIMING.md](timing/TIMING.md): every timing path at 25.175 MHz, from the datasheets and on the routed main board
- [ALU_TIMING.md](timing/ALU_TIMING.md), [FETCH_TIMING.md](timing/FETCH_TIMING.md), [VIDEO_TIMING.md](timing/VIDEO_TIMING.md), [WE_TIMING.md](timing/WE_TIMING.md), [XY_TIMING.md](timing/XY_TIMING.md): individual paths

## [video/](video/) and [sound/](sound/)

- [VIDEO.md](video/VIDEO.md): VGA timing, video modes, line repeat, row tint
- [COLORS.md](video/COLORS.md): the color decoder PLD
- [SOUND.md](sound/SOUND.md): line-fetched audio, DAC and the sound driver
- [MUSIC.md](sound/MUSIC.md): music player and tracker

## [software/](software/)

- [LIBRARY.md](software/LIBRARY.md): the standard library and jump table
- [BASIC.md](software/BASIC.md): PLACARD BASIC
- [DOS.md](software/DOS.md): the DOS and `.PLC` program files
- [MENU.md](software/MENU.md): the demo menu
- [TEST.md](software/TEST.md): the system test on the SD card (`TEST.PLC`)
- [SCRAP.md](software/SCRAP.md): SCRAPWRIGHT, a ship salvage game (`SCRAP.PLC`, phase 3)
- [EMULATOR.md](software/EMULATOR.md): the web emulator
- [BOING.md](software/BOING.md), [WIRE3D.md](software/WIRE3D.md): demos
- [SOFTWARE_ROADMAP.md](software/SOFTWARE_ROADMAP.md): what comes next

## [hardware/](hardware/)

- [SCHEMATIC_PLAN.md](hardware/SCHEMATIC_PLAN.md): schematic rules
- [BRINGUP.md](hardware/BRINGUP.md): build order and a test for each chip
- [RELEASES.md](hardware/RELEASES.md): board revisions (rev A as ordered, rev B working)
- Board drawings: layout, placement, the dimension drawing (`placard_main_dimensions.pdf`), cartridge placement, connector models, shell keepout

## [case/](case/)

- [CASE.md](case/CASE.md): the case, with its drawings and renders

## [bom/](bom/)

- [BOM.md](bom/BOM.md): index of the bills of materials (one per assembly, `.md` and `.csv`), written by `src/scripts/gen_bom.py`

## Other

- [WORKFLOW.md](WORKFLOW.md): how changes reach `main`
- [logo/](logo/README.md): the logo
