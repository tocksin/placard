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
There are not many good retro options for ALUs today.  Gigatron uses 10 MUX chips.  Novasaur uses ROM lookup tables.  An ALU is simply a combinational truth table of operations.  There are three mode inputs for the whole chip and three data inputs (per bit).  There aren't enough logic/pins to support a full 8-bit ALU, but a 4-bit ALU is possible.  It needs 4 I/O for data, and 4 outputs for flags (carryout, zero, overflow, negative).

## Video
The standard raster RAM video output has been done many times.  I am looking to enhance what's available.  I figure more configurable hardware functions would be the next step to improve performance.  I look to old systems to see what operations they used.  

### Pixel fill
An easy function is the fill function.  Putting a color in a pixel starts drawing that color.  That color continues to draw until that same color is placed again.  So putting two pixels one a row is enough to draw a whole row of that color.  It's much faster than having the CPU add that color along that entire row.  This is how to get to filled polygons quickly.  The CPU only needs to decide what the boundaries of a shape is, and the video circuit does the rest.

This is done by just XORing the current color with the RAM value.  So you start with a blue pixel, then put another blue pixel to stop it.  But if you put a purple pixel instead, it will stop drawing blue and start drawing red.  It would normally require multiple chips - at least two quad XOR chips and a 8-bit FF register array.  But this is easily done in a single PLA/PLD.



