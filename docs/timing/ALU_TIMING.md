# ALU timing

Date: 2026-11-02

The ALU is two ATF22V10C-7 PLDs (`ALU_SHR.pld`, one program for both
nibbles).  The logic functions take one array pass; ADD and SUB ripple a
carry through both chips and need two clocks, which the Branch PLD gives
them with one wait clock.  The summary of all paths is in
[TIMING.md](TIMING.md).

## The carry chain

The 22V10 has no buried nodes, so the carry is split into nodes D1, D2
and D3 on spare output pins, fed back into the array.  Each node holds the
carry XORed with S0 (0 for ADD, 1 for SUB), so every sum bit is a plain
3-input XOR and the low chip's COUT drives the high chip's CIN directly
for both ADD and SUB.

D2 and COUT each look two bits ahead, through intermediate carries C1 and
C3 that are not pins (WinCUPL expands them into the equations):

    C1   = ((A0 $ S0) & B0) # ((A0 $ S0) & CIN) # (B0 & CIN);   /* not a pin */
    D2   = ((A1 $ S0) & B1) # ((A1 $ S0) & C1)  # (B1 & C1);    /* 1 level from the inputs */
    C3   = ((A2 $ S0) & B2) # ((A2 $ S0) & D2)  # (B2 & D2);    /* not a pin */
    COUT = (ARITH_SEL & D4) # (SHR_SEL & A0);                   /* 2 levels */

So the 8-bit add is five array passes:

    low chip:   B → D2 → COUT                     2 levels
    high chip:  CIN → D2 → D3 → F3                3 levels
    total                                         5 levels = 37.5 ns

| Output | Product terms | Pin (terms available) |
|---|---:|---|
| F0, F1 | 10 | 17, 20 (14) |
| F2, F3 | 10 | 16, 21 (12) |
| COUT | 14 | 18 (16) |
| D2 | 13 | 19 (16) |
| D1, D3 | 5 | 15, 22 (10) |
| Z | 1 | 14 (8) |

## The wait clock

ADD and SUB with an AC, X or Y destination take two EXEC clocks.  The
Branch PLD stalls the first one with the same STALL line the video uses:

    STALL      = PIXEL_ENABLE
               # EXEC & ADDSUB_REG & !ALU_DONE
    ALU_DONE.D = EXEC & !PIXEL_ENABLE & ADDSUB_REG & !ALU_DONE
               # ALU_DONE & PIXEL_ENABLE

ALU_DONE (pin 18) is set by the first EXEC clock the CPU owns, so the
second clock loads the result.  It holds through a video stall, so a
stalled second clock does not cost another wait.  STALL goes, through the
cartridge's STALL_IN/STALL_OUT, to the State PLD and both PC PLDs; the
Sync PLD, the address muxes and the pixel buffer keep the real
PIXEL_ENABLE, so a wait clock never takes the bus from the video.

A store (destination RAM) writes the source bus, not the ALU result, so
it does not wait.

**Speed.**  From `placard_sim.py`, the wait clock costs:

| Program | ADD/SUB to a register | Extra clocks |
|---|---:|---:|
| pi_spigot.asm (first 30 M instructions) | 19.9 % | +6.0 % |
| mandelbrot.asm (first 30 M instructions) | 22.2 % | +6.7 % |
| cpu_test.asm (to completion) | 26.2 % | +9.3 % |

## Paths

| Path | Stages (ns) | Total | Slack |
|---|---|---:|---:|
| ADD/SUB, source AC after FETCH: IR 5.5, /AC_SEL 7.5, F541 enable 9.5, ALU 37.5, AC setup 2 | two clocks, 79.44 | 62.0 | +17.4 |
| ADD/SUB, source D: /SRC_EN (State 5.5 + Branch 7.5), F541 enable 9.5, ALU 37.5, AC setup 2 | two clocks | 62.0 | +17.4 |
| Logic op (PASS B, AND, OR, XOR, SHR, PASS A), source AC after FETCH | 5.5 + 7.5 + 9.5 + 7.5 + 2 | 32.0 | +7.7 (+3.6 on the board) |
| Logic op, source D | 13 + 9.5 + 7.5 + 2 | 32.0 | +7.7 |
| Carry flag (Branch PLD CARRY, from the high chip's COUT, 4 levels) | 22.5 + 30 + 3.5, two clocks | 56.0 | +23.4 |
| Branch decision: IR 5.5, ALU F (PASS A) 7.5, Z 7.5, LOAD_PC_LOW 7.5, PC setup 3.5 | | 31.5 | +8.2 |
| STALL (wait clock) to an F377 /E: EXEC tCO 5.5, Branch 7.5, cartridge 7.5, State 7.5, /E setup 4.5 | | 32.5 | +7.2 (+1.2 on the board) |

The logic functions stay single-clock: their carry-node terms are gated
by ARITH_SEL (S2 & !S1), which is settled early in the clock, so the
ripple cannot reach F.

**Carry flag.**  CARRY (Branch PLD pin 20, registered) latches the high
chip's COUT on the clock that loads an ADD or SUB result into AC, X or Y
(ALU_DONE set, PIXEL_ENABLE low), and holds on every other clock.  The
carry settles one level before F3 (four passes), so it is in time with
room to spare.  BCS and BCC read it through the register feedback.
