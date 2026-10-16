# Placard
## PLA computer
This project is a computer designed using some Programmable Logic Arrays (PLA) 
or Programable Array Logic (PAL) or Programmable Array Devices (PLD) chips.  
This started as a pure 7400-series chip computer, but changed over to using 
some PLA/PLDs to increase the usability while not greatly increasing the chip 
count.  The first PLA was created in 1970 by Texas Instruments.  The PAL was 
created in 1978 by Monolithic Memories which is owned by Lattice Semi today. 
There are some differences between the three types of chips, but this project 
isn't going to distinguished between them.

## Project goals
The project has some hard-goals to maintain:
- Use only through-hole chips similar to the 7400-series DIP chips (or PLA of course)
- Use only active production chips.  No hunting sketchy websites for parts.
- Design true von Neumann CPU from scratch.  No Harvard.  Bare-metal programming on the computer is a must (native compiler).
- Have a video output.  The video standard is open, but probably a legacy output (VGA/Composite/etc).
- Make the instruction set "fun" to program.  This means no racing the beam to draw the screen.  Counting instructions is not fun.
- Built-in keyboard.  No USB/PS2 keyboard.
- Native storage capabilities.  Need to be able to save/load programs as you create them on the computer.

## Memory Map
The Placard has 64kB of memory arranged in a 16-bit address bus and 8-bit databus.  The video RAM starts at x6020 and ends at xFFFF.  There is a 64kB RAM and a 64kB ROM behind the same addresses.  The address space is divided into eight 8kB sections, and a write-only map register at x5000 picks whether each section reads from the RAM or the ROM.

- **Writes always go to the RAM**, even in a section mapped to ROM.  The write strobe (/WE) is not decoded by address, so a write in the I/O window x5000-x5FFF also lands in the RAM underneath it.
- **The map register** is a CD74ACT273E clocked by /MAP_WR from the I/O decode PLD; it latches the source bus at the end of the write.  Bit n = 1 makes section n read from RAM, 0 from ROM.  Bit 2 maps only x4000-x4FFF, because x5000-x5FFF is the I/O window.  It is write only, so software keeps a copy of the last value it wrote.
- **At power-up every section reads as ROM.**  The memory control PLD's MAP_RUN output holds the register's /MR low from power-up until the first clock edge, which is where the CPU starts, so the CPU boots from ROM.
- **x5000-x5FFF is the I/O window.**  The memory control PLD keeps both the RAM and the ROM off the bus there, so I/O always has priority.  A11 is not decoded, so x5800-x5FFF repeats x5000-x57FF.
- **Only `[Y,X]` reaches the I/O window**; `[0,D]` and `[0,X]` only address the zero page.
- **Video reads follow the map too**: /RAM_OE and /ROM_OE are decoded the same way for a video read as for a CPU read, so a video section shows the RAM only once it is mapped to RAM.
- **After a map write**, the next instruction must not be fetched from a section whose map bit that write changed, unless the ROM and RAM hold the same byte there (the new map arrives 4.1 ns too late for that fetch).  Copying the ROM into the RAM underneath and then switching the section is safe.  See [TIMING_FIXES.md](TIMING_FIXES.md#romram-map-register-74act273).

The memory control PLD (`ATF22V10_MEM_CTRL.pld`) makes /WE, /ROM_OE and /RAM_OE from the address, the map, RW and PIXEL_ENABLE, using only the low half of each clock.  The I/O decode PLD (`ATF22V10_IO_DECODE.pld`) makes the upper RAM/ROM chip select (/CE_HI) and the I/O strobes.

The RAM is two AS7C256C-15PCN (32K × 8, 15 ns) chips.  The ROM is not chosen yet; for now it is the same AS7C256C-15PCN with battery backup.  See [CPU.md](CPU.md#memory-parts) and [TIMING.md](TIMING.md).

| Address | Map bit | Function  |
|---------|---------|------|
| x0000-x1FFF | 0 | RAM/ROM |
| x2000-x3FFF | 1 | RAM/ROM |
| x4000-x4FFF | 2 | RAM/ROM (audio buffer at x4DF3-x4FFF) |
| x5000-x5FFF | none | I/O window (see below) |
| x6000-x7FFF | 3 | RAM/ROM (Video Memory from x6020) |
| x8000-x9FFF | 4 | RAM/ROM (Video Memory) |
| xA000-xBFFF | 5 | RAM/ROM (Video Memory) |
| xC000-xDFFF | 6 | RAM/ROM (Video Memory) |
| xE000-xFFFF | 7 | RAM/ROM (Video Memory) |

### I/O window
Each 256-byte page has its own strobe from the I/O decode PLD.  Write strobes are low with /WE, and devices latch the source bus on the rising edge at the end of the write.  Read strobes are low on a read the CPU latches into D (LOAD_IMM).  Devices other than the map register and the line read are planned in [FEATURE_PLAN.md](FEATURE_PLAN.md) and not built yet.

| Address | Strobe | R/W | Function |
|---------|--------|-----|----------|
| x5000-x50FF | /MAP_WR | W | ROM/RAM map register (built) |
| x5000-x50FF | /LINE_RD | R | Video line counter, V9:V2 (built) |
| x5100-x51FF | /SND_WR | W | Unused (sound reads its samples from RAM, see [SOUND.md](SOUND.md)) |
| x5200-x52FF | /PORT_WR | W | Shared port output latch: SD card, SNES pad clock and latch (planned) |
| x5200-x52FF | /PORT_RD | R | Shared port input: keyboard rows of column A2:A0, SNES pad data, SD card MISO (planned) |
| x5300-x54FF | none | | Unused |
| x5500-x55FF | /EXP1 | R/W | Expansion port 1 |
| x5600-x56FF | /EXP2 | R/W | Expansion port 2 |
| x5700-x57FF | none | | Unused |
| x5800-x5FFF | | | Repeats x5000-x57FF |

### Sound
The video circuit reads one 8-bit sample per scan line from x4DF3-x4FFF (525 bytes, one frame) and plays it through a 74HCT574 and a resistor ladder DAC, at the line rate of 31.47 kHz.  80h is silence.  Software refills the half of the buffer that is not playing, using the line read.  See [SOUND.md](SOUND.md).

### Video line read
A read anywhere in x5000-x50FF returns the upper 8 bits of the video line counter, V9:V2.  The V counter in the V Counter PLD counts 499 to 1023, and one 74F541 enabled by /LINE_RD puts V9:V2 on the data bus.  The ROM/RAM map register shares the page but is write only, so there is no conflict.  Read it with `ld 0x50, y` then `ld [y,x], ac`.

- **It is a single byte**, so it can't tear between reads.
- **Resolution is 4 lines** (128 us).  Visible rows start at V = 544, so `row / 4 = value - 136`.  A value below 136 means vertical blanking.
- **There is no frame counter.**  Software keeps time by polling: each time the value goes down (from 255 back to 124), a frame has passed.  At the FPGA's 25.000 MHz clock a frame is 525 lines, about 16.8 ms (59.5 Hz).
- **Software must poll at least once per frame**, or it misses a wrap.  Elapsed time is then frames x 16.8 ms plus the line position for finer detail.

## Video
The video is designed to be 640x480 VGA 60Hz standard.  This means a 25.175 MHz clock.  This requires two counters: a horizontal and vertical.  They count 800 and 600 pixels.  This needs a 10-bit counter for each.  The counters form the RAM address space to read the pixel values.  The video memory is organized in a non-traditional way with H,V instead of V,H.

### Pixel fill
An easy function is the fill function.  Putting a color in a pixel starts drawing that color.  That color continues to draw until that same color is placed again.  So putting two pixels one a row is enough to draw a whole row of that color.  It's much faster than having the CPU add that color along that entire row.  This is how to get to filled polygons quickly.  The CPU only needs to decide what the boundaries of a shape is, and the video circuit does the rest.  The CPU only drawing wireframes, but gets fully filled polygons.

This is done by just XORing the current color with the RAM value.  So you start with a blue pixel, then put another blue pixel to stop it.  But if you put a purple pixel instead, it will stop drawing blue and start drawing red.  It would normally require multiple chips - at least two quad XOR chips and a 8-bit FF register array.  But this is easily done in a single PLA/PLD


## Standard library
`src/scripts/placard_lib.asm` holds subroutines for new programs: 16-bit
arithmetic, multiply and divide, memory fill and copy, random numbers, frame
timing, pixels and a text console.  It also sets the calling convention, the
software stack and the zero page variable map (`zeropage.asm`).  See
[LIBRARY.md](LIBRARY.md).

## Building and loading a program
The `build` folder has one Windows batch file per assembly program
(`cpu_test.bat`, `test_video.bat`, `mandelbrot.bat`,
`pi_spigot.bat`, `game_of_life.bat`, `lib_demo.bat`).  Each one assembles
`src/scripts/<program>.asm` (customasm, or `placard_sim.py` if customasm is not
on the PATH), writes `src/hdl/video_ram.mem` with `gen_video_ram.tcl`, runs
Vivado in batch mode through synthesis, implementation and bitstream, and
programs the Basys 3 over JTAG.  Any other program builds with
`build\build_and_load.bat <program>`.  Add `noasm` (e.g. `cpu_test.bat noasm`)
to skip assembly and use the existing `.hex` file.  Vivado is found on the PATH or under
`C:\AMDDesignTools` / `C:\Xilinx`; set `VIVADO` to the full path of
`vivado.bat` to pick a version.  Logs go to `build/logs`; the Vivado Tcl scripts
behind the batch files are in `build/tcl`.
Add `fast` (e.g. `mandelbrot.bat fast`) to change only the memory contents:
the new `video_ram.mem` is written into the last implemented bitstream with
`updatemem` (block RAM map from `build/tcl/write_mmi.tcl`), so synthesis and
implementation are skipped.  It needs one full build first, and a full build
again after any HDL or constraint change.
`build\download_latest.bat` programs the board with the newest bitstream in
`project/placard.runs/impl_1` (`basys_top.bit` or `basys_top_fast.bit`) without
rebuilding.

### Vivado project
The Vivado project (`project/placard.xpr` and everything else in `project/`)
is not kept in git, because Vivado rewrites the `.xpr` every time it opens it.
`build/tcl/create_project.tcl` makes it from the sources in `src/`, with the
part, file list, testbench and run settings.  The first build makes it by
itself; to open the project in the GUI after a fresh clone, run
`build\create_project.bat` once.  Every `.vhd` file in `src/hdl` is a design
source, so after adding or removing one run `build\create_project.bat force`.
Testbenches and other settings are listed in `create_project.tcl`; change them
there, because a change made only in the GUI is lost the next time the project
is made.
`src/hdl/video_ram.mem` is not kept in git either; every build makes it, and
`create_project.tcl` makes the default image if it is missing.
