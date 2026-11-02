# X/Y address timing after FETCH

Date: 2026-11-02

An X/Y-indexed read or store needs its address-source selects in the
clock right after FETCH.  This note covers how they are made in time.  The
summary of all paths is in [TIMING.md](TIMING.md).

## Registered X_ENABLE and Y_ENABLE

X_ENABLE and Y_ENABLE are registers in the State PLD (pins 16 and 17),
decoded from the memory field on the data bus during FETCH (DB_MEM2:0,
the same pins the State PLD uses for its next state) and loaded on the
same condition as the instruction register.  They always hold the same
value as a decode of the instruction register's memory field would, but
they are valid at tCO = 5.5 ns instead of after the instruction register
and a decode.

    X_ENABLE.D = (FETCH & !STALL & memory field 001, 010, 110 or 111)
               # (Q1 # Q0 # STALL) & X_ENABLE;      /* hold */
    Y_ENABLE.D = (FETCH & !STALL & memory field 010 or 111)
               # (Q1 # Q0 # STALL) & Y_ENABLE;      /* hold */

X_ENABLE takes 7 product terms (pin 16 has 12) and Y_ENABLE 5 (pin 17 has
14).  They go straight to the four address mux PLDs, where PIXEL_ENABLE
and PC_ENABLE take priority over them
([FETCH_TIMING.md](FETCH_TIMING.md)), and Y_ENABLE also to the I/O decode
PLD for /CE_HI.  Both power up at 0.

Stores from AC or X to `[0,X]` or `[Y,X]` go through LOAD_MEM (which
reads the target into D, unused by the store) before EXEC, so in the write
clock the address, the source bus and the instruction register are all a
clock old.

## Timing

| Path | Stages (ns) | Datasheet | Board |
|---|---|---:|---:|
| X/Y-indexed read after FETCH into D, address side | X_ENABLE 5.5 + mux 7.5 + tAA 15 + D setup 2 = 30.0 | +9.7 | |
| Same, through /RAM_OE (the read starts at the clock fall) | 19.9 + 7.5 + 7 + 2 = 36.4 | +3.4 | +1.2 |
| X/Y read into the upper 32K chip, /CE_HI | Y_ENABLE 5.5 + I/O decode 7.5 + tACE 15 + 2 = 30.0 | +9.7 | |
| Store to `[0,X]` / `[Y,X]`: address before /WE can fall | a clock earlier (LOAD_MEM) | | |
| Data bus memory field into X_ENABLE.D / Y_ENABLE.D during FETCH | as the fetch, 31.5 | +8.2 | +4.5 |
