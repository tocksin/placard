# Pin-swap suggestions

Board `work11\wb.kicad_pcb`. Model cost 47432 -> 42257, expected vias 532 -> 418, MST length 38.25 -> 35.45 m (369 greedy steps).

Suggestions only: each change needs the schematic (and for a PLD its PIN lines) changed and rechecked.

393 pins change on 31 parts.

| part | pin | was | now |
|---|---|---|---|
| U1 | 2 | STALL_OUT | I0 |
| U1 | 5 | I4 | I3 |
| U1 | 6 | I3 | DATABUS4 |
| U1 | 7 | I2 | DATABUS2 |
| U1 | 8 | /Control/BRANCH_BLOCK | DATABUS3 |
| U1 | 9 | DATABUS3 | I2 |
| U1 | 10 | DATABUS2 | I4 |
| U1 | 11 | DATABUS4 | STALL_OUT |
| U1 | 13 | I0 | /Control/BRANCH_BLOCK |
| U1 | 14 | Net-(U1-{slash}LOAD_INSTR) | RW |
| U1 | 15 | PC_ENABLE | ~{LOAD_IMM} |
| U1 | 19 | ~{LOAD_IMM} | PC_ENABLE |
| U1 | 20 | ~{LOAD_X} | ~{LOAD_AC} |
| U1 | 22 | ~{LOAD_AC} | ~{LOAD_X} |
| U1 | 23 | RW | Net-(U1-{slash}LOAD_INSTR) |
| U42 | 2 | /Shared port/PS2_DATA | ADDR0 |
| U42 | 5 | ADDR0 | ADDR1 |
| U42 | 6 | ADDR1 | unconnected-(U42-nc-Pad13) |
| U42 | 13 | unconnected-(U42-nc-Pad13) | /Shared port/PS2_DATA |
| U42 | 15 | DATABUS7 | DATABUS2 |
| U42 | 16 | DATABUS0 | DATABUS6 |
| U42 | 17 | DATABUS1 | DATABUS3 |
| U42 | 18 | DATABUS2 | DATABUS7 |
| U42 | 19 | DATABUS3 | DATABUS5 |
| U42 | 20 | DATABUS4 | DATABUS7 |
| U42 | 21 | DATABUS5 | DATABUS4 |
| U42 | 22 | DATABUS6 | DATABUS1 |
| U42 | 23 | DATABUS7 | DATABUS0 |
| U10 | 2 | PC_ENABLE | Y7 |
| U10 | 3 | X_ENABLE | Y_ENABLE |
| U10 | 4 | Y_ENABLE | PC_ENABLE |
| U10 | 5 | D6 | X6 |
| U10 | 6 | X6 | PC6 |
| U10 | 7 | V6 | D6 |
| U10 | 8 | PC6 | PC7 |
| U10 | 9 | D7 | PC14 |
| U10 | 10 | X7 | D7 |
| U10 | 11 | VA7 | Y6 |
| U10 | 13 | PC7 | H8 |
| U10 | 14 | Y6 | V6 |
| U10 | 15 | H8 | VA7 |
| U10 | 16 | PC14 | H9 |
| U10 | 17 | Y7 | ADDR6 |
| U10 | 18 | H9 | ADDR14 |
| U10 | 19 | PC15 | ADDR15 |
| U10 | 20 | ADDR6 | X_ENABLE |
| U10 | 22 | ADDR14 | X7 |
| U10 | 23 | ADDR15 | PC15 |
| U11 | 2 | ADDR15 | /Memory and I/O decode/RAMSEL3 |
| U11 | 3 | ADDR14 | /Memory and I/O decode/RAMSEL2 |
| U11 | 4 | ADDR13 | RUN |
| U11 | 5 | ADDR12 | /Memory and I/O decode/RAMSEL1 |
| U11 | 7 | /Memory and I/O decode/RAMSEL1 | ADDR10 |
| U11 | 8 | /Memory and I/O decode/RAMSEL3 | ADDR14 |
| U11 | 9 | /Memory and I/O decode/RAMSEL4 | ~{SRC_EN} |
| U11 | 10 | /Memory and I/O decode/RAMSEL5 | PIXEL_ENABLE |
| U11 | 11 | /Memory and I/O decode/RAMSEL6 | ADDR13 |
| U11 | 13 | /Memory and I/O decode/RAMSEL7 | ADDR12 |
| U11 | 14 | RW | ADDR11 |
| U11 | 15 | /Memory and I/O decode/RAMSEL2 | ADDR15 |
| U11 | 17 | RUN | /Memory and I/O decode/RAMSEL4 |
| U11 | 20 | ADDR11 | /Memory and I/O decode/RAMSEL7 |
| U11 | 21 | ADDR10 | RW |
| U11 | 22 | ~{SRC_EN} | /Memory and I/O decode/RAMSEL6 |
| U11 | 23 | PIXEL_ENABLE | /Memory and I/O decode/RAMSEL5 |
| U20 | 2 | X0 | X7 |
| U20 | 3 | /ALU and registers/F0 | /ALU and registers/F7 |
| U20 | 4 | /ALU and registers/F1 | /ALU and registers/F6 |
| U20 | 5 | X1 | X6 |
| U20 | 8 | /ALU and registers/F3 | /ALU and registers/F5 |
| U20 | 9 | X3 | X5 |
| U20 | 12 | X4 | X3 |
| U20 | 13 | /ALU and registers/F4 | /ALU and registers/F3 |
| U20 | 14 | /ALU and registers/F5 | /ALU and registers/F4 |
| U20 | 15 | X5 | X4 |
| U20 | 16 | X6 | X1 |
| U20 | 17 | /ALU and registers/F6 | /ALU and registers/F1 |
| U20 | 18 | /ALU and registers/F7 | /ALU and registers/F0 |
| U20 | 19 | X7 | X0 |
| U29 | 2 | V2 | V8 |
| U29 | 3 | V3 | V9 |
| U29 | 4 | V4 | V7 |
| U29 | 6 | V6 | V3 |
| U29 | 7 | V7 | V2 |
| U29 | 8 | V8 | V4 |
| U29 | 9 | V9 | V6 |
| U29 | 11 | DATABUS7 | DATABUS4 |
| U29 | 12 | DATABUS6 | DATABUS2 |
| U29 | 13 | DATABUS5 | DATABUS0 |
| U29 | 14 | DATABUS4 | DATABUS1 |
| U29 | 16 | DATABUS2 | DATABUS5 |
| U29 | 17 | DATABUS1 | DATABUS7 |
| U29 | 18 | DATABUS0 | DATABUS6 |
| U7 | 2 | PC_ENABLE | X0 |
| U7 | 3 | X_ENABLE | D0 |
| U7 | 4 | Y_ENABLE | X1 |
| U7 | 5 | D0 | D1 |
| U7 | 6 | X0 | Y1 |
| U7 | 7 | VA0 | Y0 |
| U7 | 9 | D1 | PC1 |
| U7 | 10 | X1 | PC8 |
| U7 | 11 | VA1 | PC9 |
| U7 | 13 | PC1 | VA1 |
| U7 | 14 | Y0 | PC_ENABLE |
| U7 | 15 | VA8 | X_ENABLE |
| U7 | 16 | PC8 | Y_ENABLE |
| U7 | 17 | Y1 | VA0 |
| U7 | 19 | PC9 | VA8 |
| U7 | 20 | ADDR0 | ADDR8 |
| U7 | 21 | ADDR1 | ADDR0 |
| U7 | 22 | ADDR8 | ADDR1 |
| U3 | 2 | DATABUS0 | DATABUS6 |
| U3 | 4 | DATABUS2 | DATABUS0 |
| U3 | 5 | DATABUS3 | DATABUS5 |
| U3 | 7 | DATABUS5 | DATABUS2 |
| U3 | 8 | DATABUS6 | DATABUS3 |
| U3 | 9 | DATABUS7 | PC_ENABLE |
| U3 | 10 | LOAD_PC_LOW | DATABUS7 |
| U3 | 11 | PC_ENABLE | LOAD_PC_LOW |
| U3 | 15 | PC0 | Net-(U3-CO) |
| U3 | 17 | PC5 | PC7 |
| U3 | 18 | PC7 | PC6 |
| U3 | 19 | PC6 | PC4 |
| U3 | 20 | PC4 | PC5 |
| U3 | 23 | Net-(U3-CO) | PC0 |
| U6 | 2 | AC5 | GND |
| U6 | 3 | AC6 | I6 |
| U6 | 4 | AC7 | I7 |
| U6 | 5 | DATABUS4 | I5 |
| U6 | 6 | DATABUS5 | DATABUS4 |
| U6 | 7 | DATABUS6 | AC5 |
| U6 | 8 | DATABUS7 | AC6 |
| U6 | 9 | I5 | DATABUS5 |
| U6 | 10 | I6 | DATABUS6 |
| U6 | 11 | I7 | DATABUS7 |
| U6 | 13 | Net-(U5-COUT) | AC7 |
| U6 | 23 | GND | Net-(U5-COUT) |
| U38 | 2 | ~{PORT_RD} | /Shared port/SD_MISO |
| U38 | 3 | ADDR0 | /Shared port/PAD1_DATA |
| U38 | 4 | DATABUS0 | /Shared port/PAD2_DATA |
| U38 | 6 | DATABUS2 | unconnected-(U38-nc-Pad15) |
| U38 | 7 | DATABUS3 | ADDR1 |
| U38 | 8 | DATABUS4 | DATABUS0 |
| U38 | 9 | /Shared port/PAD1_DATA | ~{PORT_RD} |
| U38 | 10 | /Shared port/PAD2_DATA | /Shared port/RXCLK |
| U38 | 11 | /Shared port/RXCLK | ADDR0 |
| U38 | 13 | /Shared port/SD_MISO | DATABUS3 |
| U38 | 14 | ADDR1 | DATABUS4 |
| U38 | 15 | unconnected-(U38-nc-Pad15) | /Shared port/P_PS2D |
| U38 | 17 | /Shared port/P_PS2D | DATABUS2 |
| U38 | 19 | /Shared port/P_MOSI | DATABUS7 |
| U38 | 20 | /Shared port/P_SCK | DATABUS6 |
| U38 | 22 | DATABUS6 | /Shared port/P_MOSI |
| U38 | 23 | DATABUS7 | /Shared port/P_SCK |
| U17 | 3 | DATABUS1 | unconnected-(U17-nc-Pad13) |
| U17 | 4 | DATABUS2 | unconnected-(U17-nc-Pad23) |
| U17 | 5 | DATABUS3 | unconnected-(U17-nc-Pad22) |
| U17 | 8 | DATABUS6 | DATABUS3 |
| U17 | 9 | DATABUS7 | DATABUS1 |
| U17 | 10 | Net-(U1-{slash}LOAD_INSTR) | RUN |
| U17 | 11 | RUN | DATABUS2 |
| U17 | 13 | unconnected-(U17-nc-Pad13) | DATABUS7 |
| U17 | 14 | I0 | I4 |
| U17 | 15 | I1 | Net-(U1-{slash}LOAD_INSTR) |
| U17 | 18 | I4 | I0 |
| U17 | 19 | I5 | DATABUS6 |
| U17 | 20 | I6 | I5 |
| U17 | 22 | unconnected-(U17-nc-Pad22) | I6 |
| U17 | 23 | unconnected-(U17-nc-Pad23) | I1 |
| U5 | 2 | AC1 | DATABUS2 |
| U5 | 3 | AC2 | DATABUS1 |
| U5 | 4 | AC3 | GND |
| U5 | 6 | DATABUS1 | AC2 |
| U5 | 7 | DATABUS2 | AC1 |
| U5 | 8 | DATABUS3 | AC4 |
| U5 | 13 | GND | AC3 |
| U5 | 17 | /ALU and registers/F0 | /ALU and registers/F3 |
| U5 | 19 | unconnected-(U5-nc-Pad19) | /ALU and registers/F1 |
| U5 | 20 | /ALU and registers/F1 | unconnected-(U5-nc-Pad19) |
| U5 | 21 | /ALU and registers/F3 | /ALU and registers/F0 |
| U5 | 23 | AC4 | DATABUS3 |
| U36 | 2 | /Video and audio out/PIX0 | /Video and audio out/PIX1 |
| U36 | 3 | /Video and audio out/PIX1 | /Video and audio out/PIX0 |
| U36 | 18 | /Video and audio out/DAC1 | /Video and audio out/DAC0 |
| U36 | 19 | /Video and audio out/DAC0 | /Video and audio out/DAC1 |
| U12 | 2 | PIXEL_ENABLE | ~{LOAD_IMM} |
| U12 | 3 | PC_ENABLE | ADDR10 |
| U12 | 4 | PC15 | PC_ENABLE |
| U12 | 5 | H9 | ADDR13 |
| U12 | 6 | Y7 | ADDR11 |
| U12 | 7 | ADDR14 | ADDR9 |
| U12 | 8 | ADDR13 | PC15 |
| U12 | 9 | ADDR12 | ADDR14 |
| U12 | 10 | ADDR10 | Y_ENABLE |
| U12 | 11 | ADDR9 | Y7 |
| U12 | 13 | ADDR8 | H9 |
| U12 | 14 | Y_ENABLE | ~{LINE_RD} |
| U12 | 15 | Net-(J8-{slash}CE_HI) | PIXEL_ENABLE |
| U12 | 17 | ~{LINE_RD} | Net-(J8-{slash}CE_HI) |
| U12 | 18 | ADDR11 | ADDR8 |
| U12 | 20 | ~{PORT_RD} | ADDR12 |
| U12 | 23 | ~{LOAD_IMM} | ~{PORT_RD} |
| U32 | 3 | ADDR7 | ADDR13 |
| U32 | 4 | ADDR6 | ADDR11 |
| U32 | 9 | ADDR1 | ADDR10 |
| U32 | 12 | DATABUS1 | DATABUS5 |
| U32 | 17 | DATABUS5 | DATABUS1 |
| U32 | 21 | ADDR10 | ADDR1 |
| U32 | 23 | ADDR11 | ADDR6 |
| U32 | 26 | ADDR13 | ADDR7 |
| U25 | 6 | /Memory and I/O decode/RAMSEL2 | /Memory and I/O decode/RAMSEL3 |
| U25 | 7 | DATABUS2 | DATABUS3 |
| U25 | 8 | DATABUS3 | DATABUS2 |
| U25 | 9 | /Memory and I/O decode/RAMSEL3 | /Memory and I/O decode/RAMSEL2 |
| U25 | 12 | /Memory and I/O decode/RAMSEL4 | /Memory and I/O decode/RAMSEL5 |
| U25 | 13 | DATABUS4 | DATABUS5 |
| U25 | 14 | DATABUS5 | DATABUS6 |
| U25 | 15 | /Memory and I/O decode/RAMSEL5 | /Memory and I/O decode/RAMSEL6 |
| U25 | 16 | /Memory and I/O decode/RAMSEL6 | /Memory and I/O decode/RAMSEL4 |
| U25 | 17 | DATABUS6 | DATABUS4 |
| U16 | 2 | /Video and audio out/PIX0 | /Video and audio out/PIX4 |
| U16 | 3 | /Video and audio out/PIX1 | /Video and audio out/PIX0 |
| U16 | 4 | /Video and audio out/PIX2 | /Video and audio out/PIX6 |
| U16 | 5 | /Video and audio out/PIX3 | /Video and audio out/LC1 |
| U16 | 6 | /Video and audio out/PIX4 | /Video and audio out/PIX1 |
| U16 | 8 | /Video and audio out/PIX6 | /Video and audio out/PIX3 |
| U16 | 10 | /Video and audio out/LC0 | /Video and audio out/PIX2 |
| U16 | 11 | /Video and audio out/LC1 | H2 |
| U16 | 14 | H2 | VIDEN |
| U16 | 15 | /Video and audio out/RED1 | /Video and audio out/BLU2 |
| U16 | 16 | /Video and audio out/RED2 | /Video and audio out/RED3 |
| U16 | 21 | /Video and audio out/RED3 | /Video and audio out/RED2 |
| U16 | 22 | /Video and audio out/BLU2 | /Video and audio out/RED1 |
| U16 | 23 | VIDEN | /Video and audio out/LC0 |
| U35 | 2 | H9 | LC2 |
| U35 | 3 | H8 | V9 |
| U35 | 4 | H7 | H6 |
| U35 | 5 | H6 | H9 |
| U35 | 6 | H5 | H7 |
| U35 | 7 | H4 | H5 |
| U35 | 9 | V9 | I1 |
| U35 | 10 | V1 | H4 |
| U35 | 14 | LC2 | VA7 |
| U35 | 15 | LC3 | VA1 |
| U35 | 16 | I1 | H8 |
| U35 | 18 | VA1 | V1 |
| U35 | 19 | VA7 | ~{AC_SEL} |
| U35 | 20 | VA8 | Net-(U15-BLANK_RD) |
| U35 | 21 | ~{AC_SEL} | VA8 |
| U35 | 23 | Net-(U15-BLANK_RD) | LC3 |
| U14 | 15 | V3 | V6 |
| U14 | 16 | V4 | V7 |
| U14 | 17 | V7 | V4 |
| U14 | 18 | V8 | V2 |
| U14 | 19 | V9 | V8 |
| U14 | 20 | V6 | V5 |
| U14 | 21 | V5 | V9 |
| U14 | 22 | V2 | V3 |
| U21 | 2 | Y0 | Y5 |
| U21 | 3 | /ALU and registers/F0 | /ALU and registers/F5 |
| U21 | 4 | /ALU and registers/F1 | /ALU and registers/F7 |
| U21 | 5 | Y1 | Y7 |
| U21 | 8 | /ALU and registers/F3 | /ALU and registers/F6 |
| U21 | 9 | Y3 | Y6 |
| U21 | 14 | /ALU and registers/F5 | /ALU and registers/F3 |
| U21 | 15 | Y5 | Y3 |
| U21 | 16 | Y6 | Y0 |
| U21 | 17 | /ALU and registers/F6 | /ALU and registers/F0 |
| U21 | 18 | /ALU and registers/F7 | /ALU and registers/F1 |
| U21 | 19 | Y7 | Y1 |
| U23 | 12 | /Video and audio out/LC4 | LC7 |
| U23 | 13 | /Video and audio out/PIX4 | /Video and audio out/PIX7 |
| U23 | 18 | /Video and audio out/PIX7 | /Video and audio out/PIX4 |
| U23 | 19 | LC7 | /Video and audio out/LC4 |
| U13 | 2 | GND | LC7 |
| U13 | 5 | H2 | GND |
| U13 | 6 | LC7 | H2 |
| U13 | 14 | H3 | Net-(U13-H_TC) |
| U13 | 16 | H5 | H8 |
| U13 | 17 | H6 | H3 |
| U13 | 18 | H7 | H5 |
| U13 | 19 | H8 | H7 |
| U13 | 22 | H_VIDEO_ACTIVE | H6 |
| U13 | 23 | Net-(U13-H_TC) | H_VIDEO_ACTIVE |
| U22 | 12 | /Video and audio out/PIX4 | /Video and audio out/PIX5 |
| U22 | 13 | DATABUS4 | DATABUS5 |
| U22 | 14 | DATABUS5 | DATABUS7 |
| U22 | 15 | /Video and audio out/PIX5 | /Video and audio out/PIX7 |
| U22 | 18 | DATABUS7 | DATABUS4 |
| U22 | 19 | /Video and audio out/PIX7 | /Video and audio out/PIX4 |
| U9 | 2 | PC_ENABLE | X5 |
| U9 | 3 | X_ENABLE | PC5 |
| U9 | 4 | Y_ENABLE | D5 |
| U9 | 6 | X4 | Y5 |
| U9 | 7 | V4 | PC4 |
| U9 | 8 | PC4 | Y_ENABLE |
| U9 | 9 | D5 | PC12 |
| U9 | 10 | X5 | PC13 |
| U9 | 11 | V5 | PC_ENABLE |
| U9 | 13 | PC5 | V5 |
| U9 | 14 | Y4 | H7 |
| U9 | 16 | PC12 | V4 |
| U9 | 17 | Y5 | X_ENABLE |
| U9 | 18 | H7 | Y4 |
| U9 | 19 | PC13 | X4 |
| U4 | 2 | Y0 | Y1 |
| U4 | 3 | Y1 | Y0 |
| U4 | 4 | Y2 | Net-(U3-CO) |
| U4 | 6 | Y4 | STALL_OUT |
| U4 | 7 | Y5 | Y4 |
| U4 | 8 | Y6 | Y2 |
| U4 | 9 | Y7 | Y6 |
| U4 | 13 | Net-(U3-CO) | Y7 |
| U4 | 14 | STALL_OUT | unconnected-(U4-CO-Pad23) |
| U4 | 15 | PC8 | PC13 |
| U4 | 16 | PC11 | PC12 |
| U4 | 17 | PC13 | PC14 |
| U4 | 19 | PC14 | Y5 |
| U4 | 20 | PC12 | PC10 |
| U4 | 21 | PC10 | PC11 |
| U4 | 23 | unconnected-(U4-CO-Pad23) | PC8 |
| U31 | 4 | ADDR6 | ADDR11 |
| U31 | 9 | ADDR1 | ADDR10 |
| U31 | 21 | ADDR10 | ADDR1 |
| U31 | 23 | ADDR11 | ADDR6 |
| U18 | 2 | D0 | D3 |
| U18 | 3 | DATABUS0 | DATABUS3 |
| U18 | 4 | DATABUS1 | DATABUS0 |
| U18 | 5 | D1 | D0 |
| U18 | 6 | D2 | D7 |
| U18 | 7 | DATABUS2 | DATABUS7 |
| U18 | 8 | DATABUS3 | DATABUS4 |
| U18 | 9 | D3 | D4 |
| U18 | 12 | D4 | D6 |
| U18 | 13 | DATABUS4 | DATABUS6 |
| U18 | 16 | D6 | D2 |
| U18 | 17 | DATABUS6 | DATABUS2 |
| U18 | 18 | DATABUS7 | DATABUS1 |
| U18 | 19 | D7 | D1 |
| U2 | 2 | I6 | Z_LOW |
| U2 | 3 | I5 | COUT |
| U2 | 7 | Z_LOW | Z_HIGH |
| U2 | 9 | PIXEL_ENABLE | PC_ENABLE |
| U2 | 11 | PC_ENABLE | PIXEL_ENABLE |
| U2 | 13 | Z_HIGH | I5 |
| U2 | 14 | COUT | unconnected-(U2-CARRY-Pad20) |
| U2 | 16 | ~{SRC_EN} | unconnected-(U2-ALU_DONE-Pad18) |
| U2 | 17 | I7 | LOAD_PC_HIGH |
| U2 | 18 | unconnected-(U2-ALU_DONE-Pad18) | ~{SRC_EN} |
| U2 | 19 | STALL_IN | LOAD_PC_LOW |
| U2 | 20 | unconnected-(U2-CARRY-Pad20) | I7 |
| U2 | 21 | LOAD_PC_LOW | I6 |
| U2 | 22 | LOAD_PC_HIGH | STALL_IN |
| U19 | 12 | AC4 | AC5 |
| U19 | 13 | /ALU and registers/F4 | /ALU and registers/F5 |
| U19 | 14 | /ALU and registers/F5 | /ALU and registers/F4 |
| U19 | 15 | AC5 | AC4 |
| U8 | 2 | PC_ENABLE | X3 |
| U8 | 3 | X_ENABLE | D2 |
| U8 | 4 | Y_ENABLE | PC2 |
| U8 | 5 | D2 | X2 |
| U8 | 6 | X2 | Y3 |
| U8 | 7 | V2 | Y2 |
| U8 | 8 | PC2 | Y_ENABLE |
| U8 | 9 | D3 | PC3 |
| U8 | 10 | X3 | PC11 |
| U8 | 11 | V3 | PC10 |
| U8 | 13 | PC3 | V2 |
| U8 | 14 | Y2 | ADDR10 |
| U8 | 15 | H4 | V3 |
| U8 | 16 | PC10 | X_ENABLE |
| U8 | 17 | Y3 | H4 |
| U8 | 19 | PC11 | ADDR11 |
| U8 | 22 | ADDR10 | PC_ENABLE |
| U8 | 23 | ADDR11 | D3 |
| U15 | 2 | V9 | H_VIDEO_ACTIVE |
| U15 | 3 | V5 | V9 |
| U15 | 4 | V4 | RUN |
| U15 | 5 | V3 | Net-(U15-BLANK_RD) |
| U15 | 6 | V2 | unconnected-(U15-nc-Pad21) |
| U15 | 8 | H_VIDEO_ACTIVE | V3 |
| U15 | 11 | RUN | V5 |
| U15 | 13 | Net-(U15-BLANK_RD) | V4 |
| U15 | 14 | H0 | PIXEL_ENABLE |
| U15 | 15 | H1 | V2 |
| U15 | 16 | H2 | ~{WE} |
| U15 | 17 | VIDEN | unconnected-(U15-V_VIDEO_ACTIVE-Pad23) |
| U15 | 18 | ~{VSYNC} | unconnected-(U15-nc-Pad22) |
| U15 | 19 | PIXEL_ENABLE | H2 |
| U15 | 20 | ~{WE} | VIDEN |
| U15 | 21 | unconnected-(U15-nc-Pad21) | H1 |
| U15 | 22 | unconnected-(U15-nc-Pad22) | H0 |
| U15 | 23 | unconnected-(U15-V_VIDEO_ACTIVE-Pad23) | ~{VSYNC} |
