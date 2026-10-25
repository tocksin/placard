# PLD usage: unused pins and product terms

Date: 2026-10-25. Taken from `src/pld/*.pld` on main (commit b476a68), then updated for the F377 load-enable fix (State PLD revision 13, Branch PLD revision 12, I/O decode PLD revision 04: the five State PLD load strobes are active low, and the Branch PLD's pin 15 makes the pixel buffer's /PIX_LD), and for X no longer being a source (Branch PLD revision 13: pin 16 is /SRC_EN, active low, on the source F541s' /OE1; memory control PLD revision 07; audio slot PLD revision 04 uses pins 16 and 21 for I1 and /AC_SEL). State 15, Branch 15, ALU 07 and cartridge 03 are the same logic as State 13, Branch 13, ALU 05 and cartridge 01: the revisions between them stored the opcode byte XOR FDh and were reverted on 2026-10-21. Later on 2026-10-21 the cartridge PLD went to revision 04 (it holds the CPU's STALL instead of the clock) and the instruction register became a PLD (`ATF22V10_IR.pld`, #17). On 2026-10-22 the memory control PLD went to revision 09 (/WE output enable for a slot-1 boot card), and the H counter PLD went to revision 08 (pin 6 = LC7, blank line). On 2026-10-25 the port PLD went to revision 03 (the port latch moved in, the matrix keyboard dropped) and then 04, and the PS/2 receiver PLD (`ATF22V10_PS2.pld`, #42) was added.

The main board has 19 ATF22V10C chips built from 13 PLD sources, and the ROM cartridge one more (`ATF22V10_CART.pld`). Each 22V10 has 12 dedicated inputs (pins 1-11 and 13; pin 1 is also the register clock) and 10 I/O pins (14-23), each with an output macrocell (OLMC) of 8, 10, 12, 14, 16, 16, 14, 12, 10 or 8 product terms. An I/O pin used as an input gives up its cell's terms. Every chip also has one asynchronous reset (AR) and one synchronous preset (SP) term shared by all registers, and each cell has its own output-enable term.

## How the counts were made

Each output equation was expanded with its intermediate variables (names that are not pins) substituted, then minimized to a sum of products. Signals that are pins (D1-D3 in the ALU, GRN3 in the color decoder, CARRY, etc.) are treated as feedback inputs, as WinCUPL does. XOR is expanded, since the 22V10 has none. Outputs with up to 13 inputs were minimized exactly; the larger ones (six color decoder outputs, two I/O decode strobes, ROM_OE and RAM_OE) were reduced by removing redundant literals and terms, which is close to minimal but not proven.  WinCUPL's fitter can land a few terms higher (the I/O decode source records 7 terms where the minimum is 4), so WinCUPL's `.doc` report is the final word on the cells marked full or tight. Where the source files give their own counts, they agree with these except the two noted below.

## Things that apply to every PLD

- **AR and SP terms**: unused on every design except PS2, whose AR is the re-arm (a write to x5202/x5203); VCOUNT, IR, CART and PS2 set the unused ones to 0 explicitly, the others leave them at the default 0.
- **Output-enable terms**: unused (always enabled) everywhere except PORT's D5, D6 and D7 and every output of PS2 (its inhibit is enabled by its ready bit).
- **Registers**: every combinational output cell could be registered instead; those are marked "combinational" in the tables.

## Summary

| PLD source | Chip(s) | Free input pins | Free I/O pins (OLMC size) | I/O pins used as inputs | Output cells | Product terms used / available on output cells |
|---|---|---|---|---|---:|---:|
| `ATF22V10_STATE.pld` | #1 | none | none | 0 | 10 | 38 / 120 |
| `ATF22V10_BRANCH.pld` | #2 | none | none | 2 | 8 | 23 / 98 |
| `ATF22V10_PC_COUNTER8.pld` | #3, #4 | none | none | 1 | 9 | 69 / 112 |
| `ALU_SHR.pld` | #5, #6 | none | none | 1 | 9 | 78 / 112 |
| `ATF22V10_QUAD_MUX.pld` | #7-#10 | none | none | 6 | 4 | 16 / 44 |
| `ATF22V10_MEM_CTRL.pld` | #11 | none | none | 6 | 4 | 28 / 58 |
| `ATF22V10_IO_DECODE.pld` | #12 | none | none | 3 | 7 | 27 / 88 |
| `ATF22V10_HCOUNT.pld` | #13 | 7, 8, 9, 10, 11, 13, 2* | none | 0 | 10 | 66 / 120 |
| `ATF22V10_VCOUNT.pld` | #14 | 3, 4, 5, 6, 7, 8, 9, 10, 11, 13 | none | 0 | 10 | 79 / 120 |
| `ATF22V10_SYNC.pld` | #15 | none | none | 0 | 10 | 21 / 120 |
| `ATF22V10_COLORDECODER.pld` | #16 | none | none | 2 | 8 | 95 / 104 |
| `ATF22V10_IR.pld` | #17 | 13 | 22 (10), 23 (8) | 0 | 8 | 17 / 102 |
| `ATF22V10_AUDIO.pld` | #35 | none | none | 3 | 7 | 23 / 78 |
| `ATF22V10_PORT.pld` | #38 | none | 15 (10) | 1 | 8 | 9 / 102 |
| `ATF22V10_PS2.pld` | #42 | 7, 8, 9, 10, 11, 13 | none | 0 | 10 | 28 / 120 |
| `ATF22V10_CART.pld` | cartridge | 6, 7, 8, 9, 10, 11, 13 | none | 0 | 10 | 28 / 120 |

\* pin 2 on HCOUNT is declared (RESET) but used in no equation.

Free inputs in total: HCOUNT 7, VCOUNT 10, PORT 0, PS2 6, IR 1 (main board); CART 7. Free I/O cells: IR pins 22 and 23 and PORT pin 15 (rev 04) only (BRANCH pin 15 became /PIX_LD in revision 12, and AUDIO pins 16 and 21 became I1 and /AC_SEL in revision 04).

**Full or tight cells** (0-1 spare): COLORDECODER RED1, RED2, RED3, GRN1, BLU2 (full) and GRN3 (1 spare); MEM_CTRL RAM_OE (full); HCOUNT HSYNC (1 spare); STATE Q1 (1 spare).

## Per PLD

### `ATF22V10_STATE.pld` (#1)

Every pin is used. Plenty of spare terms everywhere except Q1 on pin 15 (9 of 10). The combinational outputs on pins 14 and 19-23 could be registered if ever needed. Since revision 13 the five load strobes (pins 14, 19-22) are active low, because each drives a 74F377's /E.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | !LOAD_INSTR | combinational | 1 | 7 |
| 15 | 10 | !Q1 | registered | 9 | 1 tight |
| 16 | 12 | X_ENABLE | registered | 6 | 6 |
| 17 | 14 | Y_ENABLE | registered | 5 | 9 |
| 18 | 16 | Q0 | registered | 9 | 7 |
| 19 | 16 | !LOAD_IMM | combinational | 2 | 14 |
| 20 | 14 | !LOAD_X | combinational | 1 | 13 |
| 21 | 12 | !LOAD_Y | combinational | 1 | 11 |
| 22 | 10 | !LOAD_AC | combinational | 2 | 8 |
| 23 | 8 | !MEM_WR | combinational | 2 | 6 |

### `ATF22V10_BRANCH.pld` (#2)

Pin 15 (a 10-term cell, free until revision 12) is !PIX_LD, PIXEL_ENABLE inverted for the pixel buffer F377's /E. Pin 20 (CARRY) is only a register for the carry flag and needs no board connection, as the source says. LOAD_PC_LOW is 11 terms as written; it minimizes to 10, so it has 1-2 spare of 12.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | COUT | input | — | — |
| 15 | 10 | !PIX_LD | combinational | 1 | 9 |
| 16 | 12 | !SRC_EN | combinational | 1 | 11 |
| 17 | 14 | I7 | input | — | — |
| 18 | 16 | ALU_DONE | registered | 3 | 13 |
| 19 | 16 | STALL | combinational | 3 | 13 |
| 20 | 14 | CARRY | registered | 3 | 11 |
| 21 | 12 | LOAD_PC_LOW | combinational | 10 | 2 |
| 22 | 10 | LOAD_PC_HIGH | combinational | 1 | 9 |
| 23 | 8 | BRANCH_BLOCK | combinational | 1 | 7 |

### `ATF22V10_PC_COUNTER8.pld` (#3, #4)

Every pin is used. Per instance on the board: the low byte (#3) has CIN tied high, so its CIN input is effectively a constant; the high byte (#4) leaves CO (pin 23) unconnected. Bit n uses n + 5 terms, so each counter bit has 4-5 spare terms.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | PIXEL_ENABLE | input | — | — |
| 15 | 10 | Q0 | registered | 5 | 5 |
| 16 | 12 | Q3 | registered | 8 | 4 |
| 17 | 14 | Q5 | registered | 10 | 4 |
| 18 | 16 | Q7 | registered | 12 | 4 |
| 19 | 16 | Q6 | registered | 11 | 5 |
| 20 | 14 | Q4 | registered | 9 | 5 |
| 21 | 12 | Q2 | registered | 7 | 5 |
| 22 | 10 | Q1 | registered | 6 | 4 |
| 23 | 8 | CO | combinational | 1 | 7 |

### `ALU_SHR.pld` (#5, #6)

Every pin is used. D1, D2, D3 (pins 15, 19, 22) are internal carry nodes with no board connection. Per instance: the low nibble (#5) has CIN tied low in the FPGA model, and the high nibble (#6) has SHIFT_RIGHT_IN tied low (logical shift right).

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | Z | combinational | 1 | 7 |
| 15 | 10 | D1 | combinational | 5 | 5 |
| 16 | 12 | F2 | combinational | 10 | 2 |
| 17 | 14 | F0 | combinational | 10 | 4 |
| 18 | 16 | COUT | combinational | 14 | 2 |
| 19 | 16 | D2 | combinational | 13 | 3 |
| 20 | 14 | F1 | combinational | 10 | 4 |
| 21 | 12 | F3 | combinational | 10 | 2 |
| 22 | 10 | D3 | combinational | 5 | 5 |
| 23 | 8 | SHIFT_RIGHT_IN | input | — | — |

### `ATF22V10_QUAD_MUX.pld` (#7-#10)

Every pin is used, but six of the ten output cells are spent as inputs and the four Y outputs use only 4 terms each. Per instance: on the two high-byte muxes (#9, #10) the A inputs are tied low (zero page = 00), so pins 1, 5, 11, 16 on those chips carry a constant and the A term in each output is dead.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | C2 | input | — | — |
| 15 | 10 | D2 | input | — | — |
| 16 | 12 | A3 | input | — | — |
| 17 | 14 | B3 | input | — | — |
| 18 | 16 | C3 | input | — | — |
| 19 | 16 | D3 | input | — | — |
| 20 | 14 | Y0 | combinational | 4 | 10 |
| 21 | 12 | Y1 | combinational | 4 | 8 |
| 22 | 10 | Y2 | combinational | 4 | 6 |
| 23 | 8 | Y3 | combinational | 4 | 4 |

### `ATF22V10_MEM_CTRL.pld` (#11)

No free pins. RAM_OE on pin 18 is **16 of 16 terms, completely full**. ROM_OE has 6 spare and /WE almost all of its. Since revision 08 pin 17 is the RUN input from the cartridge (it was the MAP_RUN register), and RUN is ANDed into each ROM_OE term, so the term count is unchanged.  Revision 09 adds an output enable term on /WE (= RUN) for a slot-1 boot card; the OE term is separate from the 12 sum terms.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | RW | input | — | — |
| 15 | 10 | RAMSEL2 | input | — | — |
| 16 | 12 | !WE | combinational | 1 | 11 |
| 17 | 14 | RUN | input | — | — |
| 18 | 16 | !RAM_OE | combinational | 16 | 0 **full** |
| 19 | 16 | !ROM_OE | combinational | 10 | 6 |
| 20 | 14 | A11 | input | — | — |
| 21 | 12 | A10 | input | — | — |
| 22 | 10 | !SRC_EN | input | — | — |
| 23 | 8 | PIXEL_ENABLE | input | — | — |

### `ATF22V10_IO_DECODE.pld` (#12)

No free pins. Each strobe minimizes to 4 terms (CE_HI to 3); the source notes WinCUPL fitted the strobes in 7, so the real spare is 3-8 terms per cell, smallest on EXP2 (pin 22, 7 of 10 per WinCUPL).

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | RW | input | — | — |
| 15 | 10 | !CE_HI | combinational | 3 | 7 |
| 16 | 12 | !MAP_WR | combinational | 4 | 8 |
| 17 | 14 | !LINE_RD | combinational | 4 | 10 |
| 18 | 16 | A11 | input | — | — |
| 19 | 16 | !PORT_WR | combinational | 4 | 12 |
| 20 | 14 | !PORT_RD | combinational | 4 | 10 |
| 21 | 12 | !EXP1 | combinational | 4 | 8 |
| 22 | 10 | !EXP2 | combinational | 4 | 6 |
| 23 | 8 | !LOAD_IMM | input (active low since revision 04) | — | — |

### `ATF22V10_HCOUNT.pld` (#13)

Pins 7-11 and 13 are not declared, and pin 2 (RESET) is declared but used in no equation (tied low in the FPGA model), so 7 inputs are free.  Pin 6 is LC7 (blank line) since revision 08. All ten output cells are used; HSYNC on pin 21 is tight (11 of 12).

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | H3 | registered | 4 | 4 |
| 15 | 10 | H4 | registered | 5 | 5 |
| 16 | 12 | H5 | registered | 7 | 5 |
| 17 | 14 | H6 | registered | 8 | 6 |
| 18 | 16 | H7 | registered | 9 | 7 |
| 19 | 16 | H8 | registered | 9 | 7 |
| 20 | 14 | H9 | registered | 10 | 4 |
| 21 | 12 | !HSYNC | registered | 11 | 1 tight |
| 22 | 10 | H_VIDEO_ACTIVE | registered | 3 | 7 |
| 23 | 8 | H_TC | combinational | 1 | 7 |

### `ATF22V10_VCOUNT.pld` (#14)

Only CLK and EN are used: pins 3-11 and 13 (ten inputs) are free. All ten output cells are used as counter bits. The global asynchronous reset (AR) and synchronous preset (SP) terms are explicitly set to 0 (unused).

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | Q0 | registered | 4 | 4 |
| 15 | 10 | Q3 | registered | 5 | 5 |
| 16 | 12 | Q4 | registered | 8 | 4 |
| 17 | 14 | Q7 | registered | 11 | 3 |
| 18 | 16 | Q8 | registered | 12 | 4 |
| 19 | 16 | Q9 | registered | 11 | 5 |
| 20 | 14 | Q6 | registered | 10 | 4 |
| 21 | 12 | Q5 | registered | 9 | 3 |
| 22 | 10 | Q2 | registered | 4 | 6 |
| 23 | 8 | Q1 | registered | 5 | 3 |

### `ATF22V10_SYNC.pld` (#15)

Every pin is used, but the logic is light: 21 of 120 terms. Since revision 09 the VSYNC pin is declared active low (!VSYNC, like !HSYNC), so its equation is 1 term (it was 6 when written as !(...) on an active-high pin).

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | H0 | registered | 1 | 7 |
| 15 | 10 | H1 | registered | 2 | 8 |
| 16 | 12 | H2 | registered | 3 | 9 |
| 17 | 14 | VIDEN | registered | 4 | 10 |
| 18 | 16 | !VSYNC | combinational | 1 | 15 |
| 19 | 16 | PIXEL_ENABLE | registered | 2 | 14 |
| 20 | 14 | ADDR_SEL | combinational | 2 | 12 |
| 21 | 12 | ADDR_SEL_HI | combinational | 2 | 10 |
| 22 | 10 | ADDR_SEL_LO | combinational | 2 | 8 |
| 23 | 8 | V_VIDEO_ACTIVE | registered | 2 | 6 |

### `ATF22V10_COLORDECODER.pld` (#16)

The fullest PLD. Every pin is used (14 inputs, 8 outputs), and five output cells are **full by this count**: RED1 (pin 15, 10/10), RED2 (pin 16, 12/12), RED3 (pin 21, 12/12), GRN1 (pin 17, 14/14) and BLU2 (pin 22, 10/10). GRN3 has 1 spare. Only BLU3 (4 spare) and GRN2 (4 spare) have room.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | H2 | input | — | — |
| 15 | 10 | RED1 | combinational | 10 | 0 **full** |
| 16 | 12 | RED2 | combinational | 12 | 0 **full** |
| 17 | 14 | GRN1 | combinational | 14 | 0 **full** |
| 18 | 16 | BLU3 | combinational | 12 | 4 |
| 19 | 16 | GRN3 | combinational | 15 | 1 tight |
| 20 | 14 | GRN2 | combinational | 10 | 4 |
| 21 | 12 | RED3 | combinational | 12 | 0 **full** |
| 22 | 10 | BLU2 | combinational | 10 | 0 **full** |
| 23 | 8 | VIDEN | input | — | — |

### `ATF22V10_AUDIO.pld` (#35)

Every pin is used since revision 04: pin 16 takes I1 (instruction register bit 1) and pin 21 puts out /AC_SEL for the AC source F541 (CPU.md, "Source mode"). All cells have plenty of spare terms.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | LC2 | input | — | — |
| 15 | 10 | LC3 | input | — | — |
| 16 | 12 | I1 | input | — | — |
| 17 | 14 | R0 | combinational | 6 | 8 |
| 18 | 16 | R1 | combinational | 4 | 12 |
| 19 | 16 | R7 | combinational | 3 | 13 |
| 20 | 14 | R8 | combinational | 5 | 9 |
| 21 | 12 | !AC_SEL | combinational | 1 | 11 |
| 22 | 10 | !MODE_LD | combinational | 1 | 9 |
| 23 | 8 | BLANK_RD | combinational | 3 | 5 |

### `ATF22V10_CART.pld` (on the ROM cartridge)

Revision 04.  Every output cell is used; pins 6-11 and 13 are free inputs.
The group phase G2:G0, COPY, PREV15 and SYNCED are buried (no external
connection).  Term counts are worked out by hand from the equations,
since this PLD has no WinCUPL fit report yet.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 1 | — | CLK | clock | — | — |
| 2 | — | A15 | input | — | — |
| 3 | — | PIXEL_ENABLE | input | — | — |
| 4 | — | PC_ENABLE | input | — | — |
| 5 | — | STALL_IN | input | — | — |
| 14 | 8 | G0 | registered | 2 | 6 |
| 15 | 10 | G1 | registered | 3 | 7 |
| 16 | 12 | G2 | registered | 2 | 10 |
| 17 | 14 | COPY | registered | 5 | 9 |
| 18 | 16 | PREV15 | registered | 2 | 14 |
| 19 | 16 | !SR_WE | registered | 1 | 15 |
| 20 | 14 | !EE_OE | registered | 4 | 10 |
| 21 | 12 | SYNCED | registered | 2 | 10 |
| 22 | 10 | RUN | registered | 2 | 8 |
| 23 | 8 | STALL_OUT | combinational | 5 | 3 |

### `ATF22V10_IR.pld` (#17)

The instruction register: eight registers, each the opcode bit on
/LOAD_INSTR, held otherwise, and its bit of 02h while RUN is low.  Pin 13
is a free input, pins 22 and 23 free I/O.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 1 | — | CLK | clock | — | — |
| 2-9 | — | D0-D7 | input | — | — |
| 10 | — | !LOAD_INSTR | input | — | — |
| 11 | — | RUN | input | — | — |
| 14 | 8 | I0 | registered | 2 | 6 |
| 15 | 10 | I1 | registered | 3 | 7 |
| 16 | 12 | I2 | registered | 2 | 10 |
| 17 | 14 | I3 | registered | 2 | 12 |
| 18 | 16 | I4 | registered | 2 | 14 |
| 19 | 16 | I5 | registered | 2 | 14 |
| 20 | 14 | I6 | registered | 2 | 12 |
| 21 | 12 | I7 | registered | 2 | 10 |

### `ATF22V10_PORT.pld` (#38)

Revision 04 (2026-10-25, the matrix keyboard dropped, the PS/2 receiver added): the PLD is the port latch as well. Pin 1 is /PORT_WR, the clock of the five latch registers; pin 14 is an I/O cell used as an input (A1) and pin 15 is free. Each cell uses 1 term except D7 (2), so 93 of the 102 terms on the output cells are spare. D5, D6 and D7 use their output-enable term.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | A1 | input | — | — |
| 15 | 10 | — | free | — | 10 |
| 16 | 12 | K0 | registered | 1 | 11 |
| 17 | 14 | !DHOLD | registered | 1 | 13 |
| 18 | 16 | SDCS | registered | 1 | 15 |
| 19 | 16 | !MOSIN | registered | 1 | 15 |
| 20 | 14 | !SCKN | registered | 1 | 13 |
| 21 | 12 | D5 | combinational, OE term (1) | 1 | 11 |
| 22 | 10 | D6 | combinational, OE term (1) | 1 | 9 |
| 23 | 8 | D7 | combinational, OE term (1) | 2 | 6 |

### `ATF22V10_PS2.pld` (#42)

Added 2026-10-25, revision 02 the same day. Clocked by the PS/2 device's clock (RXCLK), not the 25 MHz clock. Six input pins are free (7-11, 13). All ten cells are registered: the eight data bits (3 terms each: hold, hold, shift), the state bit A (2) and the state bit B (2), 28 of 120 terms. Every cell has an output-enable term: the data bits onto the bus on reads of x5202, A (inverted: 0 = ready) on reads of x5203 while B = 0, and B's is A (the inhibit floats while receiving and drives low only in the ready state, after the 11th clock). AR = a write to x5202/x5203 (the re-arm); SP is 0.

| Pin | Terms in cell | Signal | Use | Terms used | Spare |
|---:|---:|---|---|---:|---:|
| 14 | 8 | B | registered, OE term (1) | 2 | 6 |
| 15 | 10 | A | registered, OE term (1) | 2 | 8 |
| 16 | 12 | !N8 | registered, OE term (1) | 3 | 9 |
| 17 | 14 | !N7 | registered, OE term (1) | 3 | 11 |
| 18 | 16 | !N6 | registered, OE term (1) | 3 | 13 |
| 19 | 16 | !N5 | registered, OE term (1) | 3 | 13 |
| 20 | 14 | !N4 | registered, OE term (1) | 3 | 11 |
| 21 | 12 | !N3 | registered, OE term (1) | 3 | 9 |
| 22 | 10 | !N2 | registered, OE term (1) | 3 | 7 |
| 23 | 8 | !N1 | registered, OE term (1) | 3 | 5 |
