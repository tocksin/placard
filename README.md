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
The Placard has 64kB of memory arranged in a 16-bit address bus and 8-bit databus.  The video RAM starts at x6020 and ends at xFFFF.  The memory is divided into 8kB banks which can each be selected to read the ROM instead of RAM.  The RAM will always be the target when writing even if ROM is select for that bank.  By default, ROM is selected for all banks.  There is a fixed I/O address space at x5000-x5FFF which always has priority over RAM/ROM access.

The RAM is two AS7C256C-15PCN (32K × 8, 15 ns) chips.  The ROM is not chosen yet; for now it is the same AS7C256C-15PCN with battery backup.  See [CPU.md](CPU.md#memory-parts) and [TIMING.md](TIMING.md).

| Address | Function  |
|---------|------|
| x0000-x1FFF | RAM/ROM |
| x2000-x3FFF | RAM/ROM |
| x4000-x4FFF | RAM/ROM |
| x5000-x50FF | Memory configuration |
| x5100-x51FF | Sound |
| x5200-x52FF | Keyboard |
| x5300-x53FF | Joystick |
| x5400-x54FF | Storage  |
| x5500-x55FF | Expansion 1 |
| x5600-x56FF | Expansion 2 |
| x5700-x5FFF | RESERVED |
| x6000-x7FFF | RAM/ROM (Video Memory) |
| x8000-x9FFF | RAM/ROM (Video Memory) |
| xA000-xBFFF | RAM/ROM (Video Memory) |
| xC000-xDFFF | RAM/ROM (Video Memory) |
| xE000-xFFFF | RAM/ROM (Video Memory) |


## Video
The video is designed to be 640x480 VGA 60Hz standard.  This means a 25.175 MHz clock.  This requires two counters: a horizontal and vertical.  They count 800 and 600 pixels.  This needs a 10-bit counter for each.  The counters form the RAM address space to read the pixel values.  The video memory is organized in a non-traditional way with H,V instead of V,H.

### Pixel fill
An easy function is the fill function.  Putting a color in a pixel starts drawing that color.  That color continues to draw until that same color is placed again.  So putting two pixels one a row is enough to draw a whole row of that color.  It's much faster than having the CPU add that color along that entire row.  This is how to get to filled polygons quickly.  The CPU only needs to decide what the boundaries of a shape is, and the video circuit does the rest.  The CPU only drawing wireframes, but gets fully filled polygons.

This is done by just XORing the current color with the RAM value.  So you start with a blue pixel, then put another blue pixel to stop it.  But if you put a purple pixel instead, it will stop drawing blue and start drawing red.  It would normally require multiple chips - at least two quad XOR chips and a 8-bit FF register array.  But this is easily done in a single PLA/PLD


## Building and loading a program
The `build` folder has one Windows batch file per assembly program
(`cpu_test.bat`, `test_video.bat`, `mandelbrot.bat`,
`pi_spigot.bat`, `game_of_life.bat`).  Each one assembles
`src/scripts/<program>.asm` (customasm, or `placard_sim.py` if customasm is not
on the PATH), writes `src/hdl/video_ram.mem` with `gen_video_ram.tcl`, runs
Vivado in batch mode through synthesis, implementation and bitstream, and
programs the Basys 3 over JTAG.  Any other program builds with
`build\build_and_load.bat <program>`.  Add `noasm` (e.g. `cpu_test.bat noasm`)
to skip assembly and use the existing `.hex` file.  Vivado is found on the PATH or under
`C:\AMDDesignTools` / `C:\Xilinx`; set `VIVADO` to the full path of
`vivado.bat` to pick a version.  Logs go to `build/logs`.
`build\download_latest.bat` programs the board with the last bitstream built
(`project/placard.runs/impl_1/basys_top.bit`) without rebuilding.
