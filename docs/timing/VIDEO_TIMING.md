# Video read timing

Date: 2026-11-02

The video reads one byte from RAM every eight clocks during active video,
plus the mode byte and the audio sample in horizontal blanking, by taking
the bus from the CPU for one clock.  This note covers that read and the
pixel pipeline behind it.  The summary of all paths is in
[TIMING.md](TIMING.md).

## The read clock

The Sync PLD's H2:H0 is a free-running 3-bit counter that runs two clocks
behind the H counter's 8-clock group:

| Clock of the group | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| H2:H0 | 110 | 111 | 000 | 001 | 010 | 011 | 100 | 101 |

PIXEL_ENABLE is a registered output of the Sync PLD, decoded in clock 0 and
high in clock 1, where the byte is read:

    PIXEL_ENABLE.D = V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & H2 & H1 & !H0
                   # BLANK_RD & H2 & H1 & !H0;

BLANK_RD (audio slot PLD) marks the mode byte group and the audio group in
blanking.  PIXEL_ENABLE goes straight to the four address muxes (their top
select), the memory control PLD (the RAM's /OE for a video read), the
Branch PLD (STALL and /PIX_LD) and the I/O decode PLD.  The pixel buffer
(F377) loads at the end of clock 1 with /E from the Branch PLD's /PIX_LD,
and its first pixel is shown in clock 2, when H2:H0 = 000.

The color decoder takes H2:H0 as its pixel select and VIDEN as its blank
straight from the Sync PLD.  VIDEN is registered and loads only in clock 1:

    VIDEN.D = V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & H2 & H1 & H0
            # VIDEN & !H2 # VIDEN & !H1 # VIDEN & !H0;

so it is high from clock 2 of group 48 to clock 1 of group 28: the 640
clocks in which pixels are shown.

## Paths

| Path | Stages (ns) | Datasheet | Board |
|---|---|---:|---:|
| Video read, address side: PIXEL_ENABLE tCO, mux, tAA, pixel buffer setup | 5.5 + 7.5 + 15 + 2 = 30.0 | +9.7 | |
| Video read through /RAM_OE (clock fall, memory control, tOE, setup) | 19.9 + 7.5 + 7 + 2 = 36.4 | +3.4 | **−1.1** |
| Video read into the upper 32K chip: /CE_HI 13, tACE 15, setup 2 | 30.0 | +9.7 | |
| Pixel buffer /E (/PIX_LD): PIXEL_ENABLE 5.5, Branch 7.5, /E setup 4.5 | 17.5 | +22.2 | |
| PIXEL_ENABLE.D: H_VIDEO_ACTIVE tCO, Sync setup | 5.5 + 3.5 = 9.0 | +30.7 | |
| STALL to the State PLD strobes and an F377 /E (through the cartridge) | 32.5 | +7.2 | +1.2 |
| Store in the clock after a stall: video address gone before /WE falls | 13 vs 19.9 | +6.9 | +3.0 |
| Pixel select and VIDEN to the color decoder | Sync tCO 5.5 | | |
| Color decoder output (GRN3, 1 bpp): select 5.5, decode, feedback | 20.5 into a 39.7 ns pixel | | |
| Color decoder output from the pixel buffer: F377 10.5, two levels | 25.5 into a 39.7 ns pixel | | |

On the board the video read is short because DATABUS0 is one daisy chain
of 1042 mm with the pixel buffer U22 at its far end, 819 mm from U31.  The
other bits reach U22 in 60 to 340 mm.

The video address itself (H counter, V counter and the audio slot PLD's
row bits) changes at the start of clock 0 of a group and is read in clock
1, so it has over a clock to settle.

## Writes during a video read

A video read can land on the EXEC clock of a store.  The Sync PLD's /WE
term has !PIXEL_ENABLE in it, and PIXEL_ENABLE is a register valid at
5.5 ns, long before /WE can fall (T/2 − 3 ns), so no write pulse happens
in a video read clock.  RW stays low through the stall and the store is
done in the next clock ([WE_TIMING.md](WE_TIMING.md)).

## Power-up

The PLD registers power up at 0, so the first group after power-up is 6
clocks long instead of 8.  Nothing depends on that phase.
