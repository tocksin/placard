# X/Y address timing after FETCH

Date: 2026-10-15

An X/Y-indexed read straight after FETCH is the worst path left in
[TIMING.md](TIMING.md) after the ALU and video fixes: 50.0 ns against a
39.72 ns clock (25.175 MHz).  A store straight after FETCH to [0,X] or
[Y,X] has the same late address, so the RAM write misses its address setup
by 10.9 ns and its address-valid-to-end-of-write by 3.1 ns.  Timing figures
are the same worst-case datasheet values as TIMING.md (ATF22V10C-7, 74F
glue).

**Status:** implemented (State PLD revision 09, 2026-10-15).

## The fix

**Register X_ENABLE and Y_ENABLE in the State PLD, loaded from the data
bus during FETCH.**  It adds no chips, no clocks and no pins, and the
selects behave exactly as before.

X_ENABLE and Y_ENABLE were a combinational decode of the instruction
register's memory field, so they waited for the instruction register that
loads at the end of FETCH:

    instruction register (F377) clock to Q   10.5
    State PLD X_ENABLE                         7.5
    Sync PLD ADDR_SEL_LO                       7.5
    address mux                                7.5
    RAM tAA                                   15.0
    D register setup                           2.0
    total                                     50.0

The State PLD already reads the memory field straight off the data bus
during FETCH (DB_MEM2:0, for its next state).  Decoding X_ENABLE and
Y_ENABLE from those pins, and loading them on the same condition as the
instruction register (FETCH and not STALL), gives registers that always
hold the same value as the old decode of the instruction register, but
are valid at tCO = 5.5 ns:

    X_ENABLE.D = (FETCH & !STALL & memory field 001, 010, 110 or 111)
               # (hold: Q1 # Q0 # STALL) & X_ENABLE;
    Y_ENABLE.D = (FETCH & !STALL & memory field 010 or 111)
               # (hold: Q1 # Q0 # STALL) & Y_ENABLE;

X_ENABLE takes 7 product terms (pin 16 has 12) and Y_ENABLE 5 (pin 17 has
14).  Both pins stay where they are, so the board wiring does not change.

## Timing

| Path | Before | After | Slack after |
|---|---:|---:|---:|
| X/Y-indexed read after FETCH: select tCO, ADDR_SEL_LO/HI, mux, tAA, D setup | 50.0 | 5.5 + 7.5 + 7.5 + 15 + 2 = 37.5 | +2.2 |
| Store after FETCH to [0,X]/[Y,X]: address on the RAM before /WE goes low (22.1 ns) | 33.0 | 20.5 | +1.6 (was −10.9) |
| Store after FETCH: address valid to end of write (tAW = 12 ns, 29.9 ns) | 33.0 | 20.5 | +9.4 (was −3.1) |
| New: data bus memory field into X_ENABLE.D / Y_ENABLE.D during FETCH | | 35.5 + 3.5 = 39.0 | +0.7 |

The new setup path is the same as the one the State PLD's Q0 and Q1
registers already have from the same data bus pins (TIMING.md rank 9), so
it adds no new limit.

Not fixed by this change:

- The upper-32K chip select still goes through the '04 inverter, so an
  X/Y read whose address crosses into the upper chip is 43.5 ns (−3.8), as
  every other read is (TIMING.md rank 5, "What it would take" item 4).
- A store straight after FETCH still gets its data 1.1 ns late, because the
  source register's F541 is enabled by the instruction register in the same
  clock (TIMING.md "RAM write cycle").

## Impact on the rest of the system

- **Chips and wiring**: none.  The State PLD gets new equations on the same
  pins.
- **CPU**: no clock count changes.  The instruction register still holds
  the memory field for the destination decode (LOAD_AC, LOAD_X, LOAD_Y,
  MEM_WR) and the Branch PLD.
- **Power-up**: both registers start at 0, the same as the old decode of an
  instruction register at 0 (memory field 000), and the Sync PLD ignores
  them in FETCH anyway.
- **Files changed**: `ATF22V10_STATE.pld` and `state_pld.vhd`.

## Checked in simulation

The FPGA model was run in GHDL for the first 36 ms of `cpu_test`, before
and after the change.  The 73,403 RAM writes (address and data) and the
VGA output (RGB, HSYNC, VSYNC on every clock) are identical.
