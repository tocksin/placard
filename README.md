# Placard
## PLA computer
This project is a computer designed using some PLA/PLD chips.  This started as a pure 7400-series chip computer, but changed over to using some PLA/PLDs to increase the usability while not greatly increasing the chip count.

## Project goals
The project has some hard-goals to maintain:
- Use only through-hole chips similar to the 7400-series DIP chips (or PLA of course)
- Use only active production chips.  No hunting sketchy websites for parts.
- Design true von Neumann CPU from scratch.  No Harvard.  Bare-metal programming on the computer is a must (native compiler).
- Have a video output.  The video format is TBD, but probably a legacy output (VGA/Composite/etc).
- Make the instruction set "fun" to program.  This means no racing the beam to draw the screen.  Counting instructions is not fun.
- Built-in keyboard.  No USB/PS2 keyboard.
- Native storage capabilities.  Need to be able to save/load programs as you create them on the computer.

## Memory Map
The Placard has 64kB of memory arranged in a 16-bit address bus and 8-bit databus.  The video RAM starts at x6020 and ends at xFFFF.  The memory is divided into 8kB banks which can each be selected to read the ROM instead of RAM.  The RAM will always be the target when writing even if ROM is select for that bank.  By default, ROM is selected for all banks.  There is a fixed I/O address space at x5000-x5FFF which always has priority over RAM/ROM access.

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


## ALU
There are not many good retro options for ALUs today.  Gigatron uses 10 MUX chips.  Novasaur uses ROM lookup tables.  An ALU is simply a combinational truth table of operations.  There are three mode inputs for the whole chip and three data inputs (per bit).  There aren't enough logic/pins to support a full 8-bit ALU, but a 4-bit ALU is possible.  It needs 4 outputs for data, and 4 outputs for flags (carryout C, zero Z, overflow V, negative N).    

| S2   | S1 | S0 | Function  | Instruction |
|------|----|----|-----------|------|
| 0    |  0 |  0 | PASS B    | LD   |
| 0    |  0 |  1 | A AND B   | AND  |
| 0    |  1 |  0 | A OR B    | OR   |
| 0    |  1 |  1 | A XOR B   | XOR  |
| 1    |  0 |  0 | A + B + C | ADD  |
| 1    |  0 |  1 | A - B - C | SUB  |
| 1    |  1 |  0 | A >> 1    | SHR  |
| 1    |  1 |  1 | NOT A     | NOT  |

Adding the three data bits (A, B, and C for carry), the entire truth table of 6 inputs can be created.  The two outputs from the table are the data bit and the carry bit, so two functions are needed for each bit.  That makes 8 total blocks.  Each output pin is coupled with a logic block, so 8 output pins are needed.

For the flags, the negative flag is simply the output of the highest data bit.  The carryout is the output of the highest carry output.  So only two more pins are needed for zero and overflow.  Zero only uses the four data outputs which is trivial for one output block. 

## Video
The video is designed to be 640x480 VGA 60Hz standard.  This means a 25.125 MHz clock.  This requires two counters: a horizontal and vertical.  They count 800 and 600 pixels.  This needs a 10-bit counter for each.  The counters form the RAM address space to read the pixel values.  The video memory is organized in a non-traditional way with H,V instead of V,H.

### Pixel fill
An easy function is the fill function.  Putting a color in a pixel starts drawing that color.  That color continues to draw until that same color is placed again.  So putting two pixels one a row is enough to draw a whole row of that color.  It's much faster than having the CPU add that color along that entire row.  This is how to get to filled polygons quickly.  The CPU only needs to decide what the boundaries of a shape is, and the video circuit does the rest.  The CPU only drawing wireframes, but gets fully filled polygons.

This is done by just XORing the current color with the RAM value.  So you start with a blue pixel, then put another blue pixel to stop it.  But if you put a purple pixel instead, it will stop drawing blue and start drawing red.  It would normally require multiple chips - at least two quad XOR chips and a 8-bit FF register array.  But this is easily done in a single PLA/PLD

