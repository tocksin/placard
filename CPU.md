# CPU operations

The CPU in this system is made of logic gates and registers.  The CPU 
interfaces to the memory space (RAM/ROM) by outputting a memory address, and 
then reading/writing using the data bus.

The CPU executes one instruction in either 2 or 3 clocks.  The CPU first 
performs a FETCH to get the next instruction from memory.  The next state 
depends on the instruction.  If it is an immediate instruction or a memory 
load, then it goes to a LOAD state which transfers from the memory to a 
temporary register D.  The last state is the EXECUTE state which will use the 
ALU and write a value to a register or to memory.  The LOAD state can be 
skipped if an instruction does not need data from memory; for example, a 
shift-left instruction adds the Accumulator to itself.

ADD and SUB with an AC, X or Y destination take one more clock: the first
EXEC clock is a wait clock so the carry can ripple through both ALU PLDs at
25.175 MHz (see [ALU_TIMING.md](ALU_TIMING.md)).  The Branch PLD makes the
wait by sending STALL to the State PLD and the PC PLDs (the same stall the
video uses) for the first EXEC clock, and its ALU_DONE register ends the
wait on the second.  Stores do not wait, because they write the source bus,
not the ALU result.  A store from AC or X to [0,X] or [Y,X] goes through
LOAD_MEM (one more clock) so its address and data settle a clock before the
write (see [TIMING_FIXES.md](TIMING_FIXES.md)).  So an instruction takes 2
to 4 clocks, plus any video stall clocks.

## Registers

There are 4 registers in the system that are accessble for use in instructions. 
- Accumulator
- X
- Y
- D (immediate/memory)

The D register can be loaded either from the program counter location (immediate
 instruction) or from a memory location indicated in the instruction.

## Memory access mode

The memory can be accessed through four access modes using the X and Y 
registers.
- [Y,X] will access a 16-bit address based on both Registers
- [0,D] will access the zero page of memory using an immediate value stored
alongside the instruction.
- [0,X] will access the zero page of memory using the X register to access one 
of the 256 zero locations.
- [Y,D] is a possible combination, but not supported in the instruction set.

The memory space consists of both a 64kB RAM and a 64kB ROM.  All writes go to 
the RAM module.  Reads are controlled by a memory bank selector register which 
is configurable by software.  The memory space is divided into 8 sections. 
Each section can be configured as either ROM or RAM.  At startup, all regions
are selected as ROM.  The software will execute from ROM initially until 
reconfigured.  The video hardware will always read from RAM.

### Memory parts

- RAM: 2 × AS7C256C-15PCN (Alliance Memory, 32K × 8, 15 ns, 28-pin PDIP).
  A15 selects which chip is accessed: the lower chip's /CE is the address
  mux's A15 and the upper chip's /CE is /CE_HI from the I/O decode PLD.
  Both chips' /OE is RAM_OE from the ROM/RAM select PLD (see
  [TIMING_FIXES.md](TIMING_FIXES.md)).
- ROM: not chosen yet.  The interim solution is the same AS7C256C-15PCN
  (2 chips) with battery backup.  The AS7C256C keeps its data down to
  VCC = 2.0 V as long as /CE is held at or above VCC − 0.2 V, so the battery
  switch must hold /CE high while power is off.  The two ROM chips take
  their /CE the same way as the RAM (A15 and /CE_HI, through the battery
  switch) and their /OE from ROM_OE.

See [TIMING.md](TIMING.md) for the timing analysis with these parts.

### RAM write timing

The RAM is asynchronous, so the write pulse must start after the address, data
and R/W have settled and must end before they change.  The State PLD's R/W
(pin 23, 1 = read) is a decode of the registered state, so it changes just
after the rising clock edge.  The write strobe is gated with the clock:

    /WE = RW | CLK        (one OR gate, e.g. 74HC32)

/WE is low only during the low half of an EXEC write cycle.  The address and
source bus have the whole high half to settle, and /WE returns high at the
rising edge, before the state, address and data change (the SRAM's write
recovery and data hold times are normally 0 ns).  At 25 MHz the pulse is about
20 ns, which suits a 10-15 ns SRAM.
(TIMING.md shows that the gate delay and the buffer enable time break this
at 25.175 MHz; see "RAM write cycle" there.)

Avoiding bus contention on the RAM data pins: the buffer that drives the
source bus onto them is enabled only by the write pulse itself (its enable is
/WE), and the RAM's /OE is the read strobe (/OE = !RW, active only when RW = 1).
RW falls early in the cycle, so the RAM stops driving long before /WE goes low
and the buffer turns on.  At the end of the cycle /WE rises on the clock edge,
turning the buffer off, and RW rises a PLD clock-to-output delay later, so the
RAM only starts driving after the buffer is off.  Do not enable the buffer with
RW alone, and do not use RAM_EN (the complement of ROM_EN, which is also high
for writes) as the RAM's /OE.  The FPGA model keeps the read bus (ROM/RAM
data) and the source bus separate because it cannot use tri-state buses.

## Source mode

The source bus drives to three locations: the B-input of the ALU, the low-side 
of the program counter, and into the memory.  The instruction determines which 
source is placed on the source bus.
- D register containing the immediate value
- D register containing a memory value
- Accumulator 

The source bus is how the CPU writes data back into the RAM.  It's possible to
read a location from the ROM and then write it back to the RAM in one
instruction.

Note: there is a chance to expand this since there is one more decoded mode 
available.

## ALU

There are not many good retro options for ALUs today.  Gigatron uses 10 MUX 
chips.  Novasaur uses ROM lookup tables.  An ALU is simply a combinational 
truth table of operations.  There are three mode inputs for the whole chip and 
two input data ports (4-bits per port).  There aren't enough logic/pins to 
support a full 8-bit ALU, but a 4-bit ALU is possible.  It needs 4 outputs for 
data, and 2 outputs for flags (zero Z, negative N).

| S2   | S1 | S0 | Function  | Instruction |
|------|----|----|-----------|------|
| 0    |  0 |  0 | PASS B    | LD   |
| 0    |  0 |  1 | A AND B   | AND  |
| 0    |  1 |  0 | A OR B    | OR   |
| 0    |  1 |  1 | A XOR B   | XOR  |
| 1    |  0 |  0 | A + B     | ADD  |
| 1    |  0 |  1 | A - B     | SUB  |
| 1    |  1 |  0 | A >> 1    | SHR  |
| 1    |  1 |  1 | PASS A    | BRA/JMP |

Adding the three data bits (A, B, and C for carry), the entire truth table of 6 
inputs can be created.  The two outputs from the table are the data bit and the 
carry bit, so two functions are needed for each bit.  That makes 8 total blocks.  
Each output pin is coupled with a logic block, so 8 output pins are needed.

For the flags, the negative flag is simply the output of the highest data bit.  
Zero only uses the four data outputs which is trivial for one output block. 

## Branching

Branching happens similar to the Gigatron.  The ALU instruction bits (7:5) 
111 indicates a branch/jump.  The instruction memory mode bits (4:2) dictate
the type of branch/jump.  A value of 000 will cause a jump (16-bit load of PC).
A value of 111 will cause a branch (8-bit load of lower PC byte).  The others
are conditional based on the ALU result.  

BGE with an AC or X target (`bge ac`, `bge x`) is two bytes: the opcode and a
pad byte.  Its memory field (101) is the same as a zero-page store's, and the
State PLD sends both through LOAD_IMM rather than decoding the opcode in FETCH,
which was too slow at 25.175 MHz (see TIMING_FIXES.md).  The assembler adds
the pad byte.

Using the Zero flag, the value of the Accumulator can be determined if it is 
equal-to-zero.  The Negative flag (the MSB of the Accumulator) 
determines if the Accumulator is positive or negative.  This determines 
greater-than-zero or less-than-zero.  These two flags together can determine 
all of the branching mode.

| MemMode | Branch | Z | NEG | Meaning | LoadPCLow | LoadPCHigh |
|---------|--------|---|-----|---------|-----------|------------|
|   000   |   JMP  | X |  X  | Always  |     1     |      1     |
|   001   |   BGT  | 0 |  0  |  AC>0   |     1     |      0     |
|   001   |   BGT  | 0 |  1  |  AC<0   |     0     |      0     |
|   001   |   BGT  | 1 |  0  |  AC=0   |     0     |      0     |
|   010   |   BLT  | 0 |  0  |  AC>0   |     0     |      0     |
|   010   |   BLT  | 0 |  1  |  AC<0   |     1     |      0     |
|   010   |   BLT  | 1 |  0  |  AC=0   |     0     |      0     |
|   011   |   BNE  | 0 |  0  |  AC>0   |     1     |      0     |
|   011   |   BNE  | 0 |  1  |  AC<0   |     1     |      0     |
|   011   |   BNE  | 1 |  0  |  AC=0   |     0     |      0     |
|   100   |   BEQ  | 0 |  0  |  AC>0   |     0     |      0     |
|   100   |   BEQ  | 0 |  1  |  AC<0   |     0     |      0     |
|   100   |   BEQ  | 1 |  0  |  AC=0   |     1     |      0     |
|   101   |   BGE  | 0 |  0  |  AC>0   |     1     |      0     |
|   101   |   BGE  | 0 |  1  |  AC<0   |     0     |      0     |
|   101   |   BGE  | 1 |  0  |  AC=0   |     1     |      0     |
|   110   |   BLE  | 0 |  0  |  AC>0   |     0     |      0     |
|   110   |   BLE  | 0 |  1  |  AC<0   |     1     |      0     |
|   110   |   BLE  | 1 |  0  |  AC=0   |     1     |      0     |
|   111   |   BRA  | 0 |  0  |  AC>0   |     1     |      0     |
|   111   |   BRA  | 0 |  1  |  AC<0   |     1     |      0     |
|   111   |   BRA  | 1 |  0  |  AC=0   |     1     |      0     |


