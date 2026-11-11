# PLD pin-swap check (wbf11_ps, 2026-11-11)

Each ATF22V10C on the bench board: the router's pin permutation applied to today's .pld PIN lines, then compiled with WinCUPL (`cupl -j -l -x -f`, g22v10). A compile fails when an output lands on an input-only pin or needs more product terms than its OLMC has (checked: moving BRANCH's LOAD_PC_LOW, 10 terms, to pin 23 with 8 fails).

**All 20 PLDs compile after the swaps (295 signal moves). Every moved output fits its new pin.** Some margins did change, because outputs moved between pins of different size: U4 Q5 (10 terms) went from pin 17 (14) to pin 15 (10) and U14 Q6 (10 terms) from pin 20 (14) to pin 15 (10), so both are now full; U16 RED1/BLU2 10/10 and RED2/RED3 12/12 are full as before. The term count of every moved output against its new pin is in wbf11_ps_pldcheck/pldcheck.md (static check, pldcheck.py).

| part | source | signal moves | before | after |
|---|---|---|---|---|
| U1 | ATF22V10_STATE.pld | 15 | fits | fits |
| U2 | ATF22V10_BRANCH.pld | 14 | fits | fits |
| U3 | ATF22V10_PC_COUNTER8.pld | 14 | fits | fits |
| U4 | ATF22V10_PC_COUNTER8.pld | 16 | fits | fits |
| U5 | ALU_SHR.pld | 12 | fits | fits |
| U6 | ALU_SHR.pld | 12 | fits | fits |
| U7 | ATF22V10_QUAD_MUX.pld | 18 | fits | fits |
| U8 | ATF22V10_QUAD_MUX.pld | 18 | fits | fits |
| U9 | ATF22V10_QUAD_MUX.pld | 15 | fits | fits |
| U10 | ATF22V10_QUAD_MUX.pld | 20 | fits | fits |
| U11 | ATF22V10_MEM_CTRL.pld | 17 | fits | fits |
| U12 | ATF22V10_IO_DECODE.pld | 17 | fits | fits |
| U13 | ATF22V10_HCOUNT.pld | 10 | fits | fits |
| U14 | ATF22V10_VCOUNT.pld | 8 | fits | fits |
| U15 | ATF22V10_SYNC.pld | 18 | fits | fits |
| U16 | ATF22V10_COLORDECODER.pld | 14 | fits | fits |
| U17 | ATF22V10_IR.pld | 12 | fits | fits |
| U35 | ATF22V10_AUDIO.pld | 16 | fits | fits |
| U38 | ATF22V10_PORT.pld | 17 | fits | fits |
| U42 | ATF22V10_PS2.pld | 12 | fits | fits |

## Moves per part (signal: old pin -> new pin)

**U1** ATF22V10_STATE.pld: PIXEL_ENABLE 2->11, MEM2 5->10, MEM1 6->5, MEM0 7->9, BRANCH_BLOCK 8->13, DB_MEM1 9->8, DB_MEM0 10->7, DB_MEM2 11->6, SRC0 13->2, LOAD_INSTR 14->23, Q1 15->19, LOAD_IMM 19->15, LOAD_X 20->22, LOAD_AC 22->20, MEM_WR 23->14

**U2** ATF22V10_BRANCH.pld: I6 2->21, I5 3->13, Z_LOW 7->2, PIXEL_ENABLE 9->11, PC_ENABLE 11->9, Z_HIGH 13->7, COUT 14->3, SRC_EN 16->18, I7 17->20, ALU_DONE 18->16, STALL 19->22, CARRY 20->14, LOAD_PC_LOW 21->19, LOAD_PC_HIGH 22->17

**U3** ATF22V10_PC_COUNTER8.pld: D0 2->4, D2 4->7, D3 5->8, D5 7->5, D6 8->2, D7 9->10, LOAD 10->11, EN 11->9, Q0 15->23, Q5 17->20, Q7 18->17, Q6 19->18, Q4 20->19, CO 23->15

**U4** ATF22V10_PC_COUNTER8.pld: D0 2->3, D1 3->2, D2 4->8, D4 6->7, D5 7->19, D6 8->9, D7 9->13, CIN 13->4, PIXEL_ENABLE 14->6, Q0 15->23, Q3 16->21, Q5 17->15, Q6 19->17, Q4 20->16, Q2 21->20, CO 23->14

**U5** ALU_SHR.pld: A1 2->7, A2 3->6, A3 4->13, B1 6->3, B2 7->2, B3 8->23, CIN 13->4, F0 17->21, D2 19->20, F1 20->19, F3 21->17, SHIFT_RIGHT_IN 23->8

**U6** ALU_SHR.pld: A1 2->7, A2 3->8, A3 4->13, B0 5->6, B1 6->9, B2 7->10, B3 8->11, S0 9->5, S1 10->3, S2 11->4, CIN 13->23, SHIFT_RIGHT_IN 23->2

**U7** ATF22V10_QUAD_MUX.pld: PC_ENABLE 2->14, X_ENABLE 3->15, Y_ENABLE 4->16, D0 5->3, X0 6->2, V0 7->17, D1 9->5, X1 10->4, V1 11->13, PC1 13->9, Y2 14->7, V2 15->19, PC2 16->10, Y3 17->6, PC3 19->11, LO0 20->21, LO1 21->22, HI0 22->20

**U8** ATF22V10_QUAD_MUX.pld: PC_ENABLE 2->22, X_ENABLE 3->16, Y_ENABLE 4->8, D0 5->3, X0 6->5, V0 7->13, PC0 8->4, D1 9->23, X1 10->2, V1 11->15, PC1 13->9, Y2 14->7, V2 15->17, PC2 16->11, Y3 17->6, PC3 19->10, HI0 22->14, HI1 23->19

**U9** ATF22V10_QUAD_MUX.pld: PC_ENABLE 2->11, X_ENABLE 3->17, Y_ENABLE 4->8, X0 6->19, V0 7->16, PC0 8->7, D1 9->4, X1 10->2, V1 11->13, PC1 13->3, Y2 14->18, PC2 16->9, Y3 17->6, V3 18->14, PC3 19->10

**U10** ATF22V10_QUAD_MUX.pld: PC_ENABLE 2->4, X_ENABLE 3->20, Y_ENABLE 4->3, D0 5->7, X0 6->5, V0 7->14, PC0 8->6, D1 9->10, X1 10->22, V1 11->15, PC1 13->8, Y2 14->11, V2 15->13, PC2 16->9, Y3 17->2, V3 18->16, PC3 19->23, LO0 20->17, HI0 22->18, HI1 23->19

**U11** ATF22V10_MEM_CTRL.pld: A15 2->15, A14 3->8, A13 4->11, A12 5->13, RAMSEL1 7->5, RAMSEL3 8->2, RAMSEL4 9->17, RAMSEL5 10->23, RAMSEL6 11->22, RAMSEL7 13->20, RW 14->21, RAMSEL2 15->3, RUN 17->4, A11 20->14, A10 21->7, SRC_EN 22->9, PIXEL_ENABLE 23->10

**U12** ATF22V10_IO_DECODE.pld: PIXEL_ENABLE 2->15, PC_ENABLE 3->4, PC15 4->8, H9 5->13, Y7 6->11, Y6 7->9, Y5 8->5, Y4 9->20, Y2 10->3, Y1 11->7, Y0 13->18, Y_ENABLE 14->10, CE_HI 15->17, P0 17->14, Y3 18->6, PORT 20->23, X7 23->2

**U13** ATF22V10_HCOUNT.pld: RESET 2->5, H2 5->6, LC7 6->2, H3 14->17, H5 16->18, H6 17->22, H7 18->19, H8 19->16, H_VIDEO_ACTIVE 22->23, H_TC 23->14

**U14** ATF22V10_VCOUNT.pld: Q3 15->22, Q4 16->17, Q7 17->16, Q8 18->19, Q9 19->21, Q6 20->15, Q5 21->20, Q2 22->18

**U15** ATF22V10_SYNC.pld: V9 2->3, V5 3->11, V4 4->13, V3 5->8, V2 6->15, H_VIDEO_ACTIVE 8->2, RUN 11->4, BLANK_RD 13->5, H0 14->22, H1 15->21, H2 16->19, VIDEN 17->20, VSYNC 18->23, PIXEL_ENABLE 19->14, WE 20->16, P0 21->6, MAP_WR 22->18, V_VIDEO_ACTIVE 23->17

**U16** ATF22V10_COLORDECODER.pld: D0 2->3, D1 3->6, D2 4->10, D3 5->8, D4 6->2, D6 8->4, MODE0 10->23, MODE1 11->5, H2 14->11, RED1 15->22, RED2 16->21, RED3 21->16, BLU2 22->15, VIDEN 23->14

**U17** ATF22V10_IR.pld: D1 3->9, D2 4->11, D3 5->8, D6 8->19, D7 9->13, LOAD_INSTR 10->15, RUN 11->10, I0 14->18, I1 15->23, I4 18->14, I5 19->20, I6 20->22

**U35** ATF22V10_AUDIO.pld: H9 2->5, H8 3->16, H7 4->6, H6 5->4, H5 6->7, H4 7->10, V9 9->3, V1 10->18, LC2 14->2, LC3 15->23, I1 16->9, R1 18->15, R7 19->14, R8 20->21, AC_SEL 21->19, BLANK_RD 23->20

**U38** ATF22V10_PORT.pld: PORT 2->9, A0 3->11, D0 4->8, D2 6->17, D3 7->13, D4 8->14, PAD1 9->3, PAD2 10->4, RXCLK 11->10, MISO 13->2, A1 14->7, Q0 15->6, DHOLD 17->15, MOSIN 19->22, SCKN 20->23, D6 22->20, D7 23->19

**U42** ATF22V10_PS2.pld: PDATA 2->13, A0 5->2, A1 6->5, A 15->18, N8 16->23, N7 17->22, N6 18->15, N5 19->17, N4 20->21, N3 21->19, N2 22->16, N1 23->20

## Not covered by the compile
- **Stale bench netlist.** The wb bench board is the 2026-11-01 netlist. Several PLDs have new pins since: U12 IO_DECODE pins 15-23 (revision 07, X7 on 23 where the board has /LOAD_IMM), U15 SYNC 21-23 (P0, MAP_WR, V_VIDEO_ACTIVE are unconnected on the board), U38 PORT pin 15 (Q0) and U42 PS2 pin 7 (Q0). The router routed the old nets, so the swaps have to be recomputed on the current board before they are adopted.
- **Shared sources.** U7-U10 share QUAD_MUX, U3/U4 PC_COUNTER8 and U5/U6 ALU_SHR. With different swaps each chip needs its own .pld (and .jed, VHDL and KiCad symbol): 8 more sources.
- **U42 DATABUS7** is driven by two pins on purpose (!A on 15, N1 on 23, at different times). Which of the two new DATABUS7 pins (18, 20) gets which signal is free; both pins have 14+ terms, so either way fits.
- Timing is unchanged: every ATF22V10C pin has the same tpd and every OLMC the same register.
