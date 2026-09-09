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


## ALU
There are not many good retro options for ALUs today.  Gigatron uses 10 MUX chips.  Novasaur uses ROM lookup tables.  An ALU is simply a combinational truth table of operations.  There are three mode inputs for the whole chip and three data inputs (per bit).  There aren't enough logic/pins to support a full 8-bit ALU, but a 4-bit ALU is possible.  It needs 4 outputs for data, and 4 outputs for flags (carryout C, zero Z, overflow V, negative N).    

| Mode | S1 | S0 | Function  | Instruction |
|------|----|----|-----------|------|
| 0    |  0 |  0 | A AND B   | ADD  |
| 0    |  0 |  1 | A OR B    | OR   |
| 0    |  1 |  0 | A XOR B   | XOR  |
| 0    |  1 |  1 | NOT A     | NOT  |
| 1    |  0 |  0 | A + B + C | ADD  |
| 1    |  0 |  1 | A - B - C | SUB  |
| 1    |  1 |  0 | A + 1     | INC  |
| 1    |  1 |  1 | A - 1     | DEC  |

Adding the three data bits (A, B, and C for carry), the entire truth table of 6 inputs can be created.  The two outputs from the table are the data bit and the carry bit, so two functions are needed for each bit.  That makes 8 total blocks.  Each output pin is coupled with a logic block, so 8 output pins are needed.

For the flags, the negative flag is simply the output of the highest data bit.  The carryout is the output of the highest carry output.  So only two more pins are needed for zero and overflow.  Zero only uses the four data outputs which is trivial for one output block.  The overflow flag only uses the top two carry outputs (C3 XOR C4).  So we get all four flags with only two extra pins.

## Video
The standard raster RAM video output has been done many times.  I am looking to enhance what's available.  I figure more configurable hardware functions would be the next step to improve performance.  I look to old systems to see what operations they used.

### Pixel fill
An easy function is the fill function.  Putting a color in a pixel starts drawing that color.  That color continues to draw until that same color is placed again.  So putting two pixels one a row is enough to draw a whole row of that color.  It's much faster than having the CPU add that color along that entire row.  This is how to get to filled polygons quickly.  The CPU only needs to decide what the boundaries of a shape is, and the video circuit does the rest.  The CPU only drawing wireframes, but gets fully filled polygons.

This is done by just XORing the current color with the RAM value.  So you start with a blue pixel, then put another blue pixel to stop it.  But if you put a purple pixel instead, it will stop drawing blue and start drawing red.  It would normally require multiple chips - at least two quad XOR chips and a 8-bit FF register array.  But this is easily done in a single PLA/PLD

