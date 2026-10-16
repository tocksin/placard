# Sound

Date: 2026-10-16

The video circuit plays sound by itself.  On every scan line it reads one
8-bit sample from RAM, the same way it reads pixels, and a register feeds that
sample to a resistor DAC.  Software only keeps a 525-byte buffer filled.

| | |
|---|---|
| Format | 8-bit unsigned mono, 80h = silence |
| Sample rate | the line rate: 31.469 kHz at 25.175 MHz (31.25 kHz on the FPGA's 25.000 MHz) |
| Buffer | 4DF3h-4FFFh, 525 bytes, one frame, played in address order and repeated |
| Added chips | audio slot PLD (ATF22V10C), DAC register (SN74HCT574N), filter op-amp (MCP6002-I/P) |
| CPU cost | one stall clock per line (525 per frame, 0.13 %) |

## How the sample is read

**The read.**  The Sync PLD (revision 06) raises PIXEL_ENABLE for one more
clock per line, in clock 1 of an 8-clock group in horizontal blanking, on all
525 lines including vertical blanking.  It is a video read in every way: the
address mux selects the video address, the Branch PLD stalls the CPU, the
memory control PLD enables the RAM or ROM by the map, and the pixel buffer
(F377) loads the byte.

**The address.**  The video address is H9:H3 on A15:A9 and V8:V0 on A8:A0.
The V counter runs 499-1023, 525 lines, but only 9 bits of it reach the
address, so lines 499-511 and 1011-1023 would read the same 13 bytes and 13
samples would repeat every frame (a 60 Hz buzz).  The audio slot PLD fixes
that by reading in group 38 when V9 = 0 and in group 39 when V9 = 1, which
puts V9 on A9:

| Lines | V9 | Group | H9:H3 | Addresses |
|---|---|---|---|---|
| 499-511 | 0 | 38 | 0100110 | 4C00h + 499..511 = 4DF3h-4DFFh |
| 512-1023 | 1 | 39 | 0100111 | 4E00h + 0..511 = 4E00h-4FFFh |

One frame reads 4DF3h through 4FFFh in order.  The buffer sits just below the
I/O window and follows map bit 2 (4000h-4FFFh).  Groups 40-47 would be the I/O
window, where no memory answers, so this is as close to video memory as a
blanking read can get.

**The output.**  The pixel buffer holds the sample until the first pixel read
of the line (group 48).  A 74HCT574 clocked by the rising edge of the HSYNC
pin (end of sync, start of group 42) copies it.  So every sample lasts exactly
one line (800 clocks), even though the read itself moves 8 clocks between
group 38 and group 39.

### Audio slot PLD (`ATF22V10_AUDIO.pld`, `audio_pld.vhd`)

    AUD_SLOT = !H9 & H8 & !H7 & !H6 & H5 & H4 &  H3 &  V9     /* group 39 */
             # !H9 & H8 & !H7 & !H6 & H5 & H4 & !H3 & !V9;    /* group 38 */

| Pin | Signal | From / to |
|---:|---|---|
| 2-8 | H9, H8, H7, H6, H5, H4, H3 | H counter PLD pins 20, 19, 18, 17, 16, 15, 14 |
| 9 | V9 | V counter PLD pin 19 (Q9) |
| 23 | AUD_SLOT | Sync PLD pin 13 |
| 1, 10, 11, 13, 14-22 | unused | |

### Sync PLD change (revision 06)

    PIN 13 = AUD_SLOT;

    PIXEL_ENABLE.D = V_VIDEO_ACTIVE & H_VIDEO_ACTIVE & !H2 & !H1 & !H0
                   # AUD_SLOT & !H2 & !H1 & !H0;

PIXEL_ENABLE uses 2 of its 16 product terms.  Nothing else in the PLD changes.

### Timing

| Path | Total | Slack at 39.72 ns |
|---|---:|---:|
| AUD_SLOT to the Sync register: H counter tCO 5.5, audio PLD tPD 7.5, Sync tS 3.5 | 16.5 ns | +23.2 |
| The audio read: the same path as a pixel read (VIDEO_TIMING.md, option A) | 34.5 ns | +5.2 |
| DAC register data: the pixel buffer is steady from group 38/39 to group 48, and the clock edge is at group 42 | at least 22 clocks before the edge and 50 after | |

### Checked in simulation

The FPGA model was run in GHDL for 36 ms of `cpu_test`, with a ramp
(0, 1, 2, ...) written into 4DF3h-4FFFh, against the sources before this
change:

- 1125 audio reads, exactly one per line, at 4DF3h-4FFFh in order with no
  repeats.
- The DAC register stepped by +1 on every line, and wrapped once per frame
  (from sample 524 back to 0).
- HSYNC and VSYNC were identical clock for clock.
- The CPU made the same RAM writes, with the same addresses and data in the
  same order, about 0.15 % later (the extra stall).
- 439 pixels differed, all on one frame only: a store that lands a few
  clocks later shows up on the next frame instead.  None were still different
  one frame later.

## DAC and filter

    +5V ──10Ω──┬── VCC (pin 20) of the 74HCT574 ("DAC 5V")
               ├── 220µF ── AGND
               └── 100nF ── AGND

    74HCT574 Q7 (MSB) ─ 20k ─┬─────────────────────── ladder out (Rth = 10k)
    74HCT574 Q6       ─ 20k ─┼ 10k ┐
                              ...  (each node: 20k from its bit,
    74HCT574 Q1       ─ 20k ─┼ 10k ┐  10k to the next node up)
    74HCT574 Q0 (LSB) ─ 20k ─┤
                              └─ 20k ─ AGND   (termination)

    ladder out ── 10k (R2) ──┬── C2 1nF ── AGND
                 │           └── MCP6002 IN+ (pin 3)
                 └── C1 2.2nF ── MCP6002 OUT (pin 1)
                                 MCP6002 IN- (pin 2) ── OUT (pin 1)

    OUT ── 100Ω ── 10µF (+ toward the op-amp) ──┬── line-out jack tip
                                                └── 100k ── AGND

### The register

- **74HCT574, not 74HC574 or 74F574.**  HCT inputs read the pixel buffer's
  74F outputs (2.7 V minimum high) correctly, which an HC input (3.5 V
  threshold at 5 V) does not.  HCT outputs swing rail to rail, which the
  ladder needs for even steps; 74F outputs only reach about 3.4 V and differ
  from bit to bit.
- D7:D0 from the pixel buffer Q7:Q0.  CLK from the HSYNC pin (H counter PLD
  pin 21).  /OE (pin 1) to ground.
- **Power it from its own filtered rail** (10 Ω, 220 µF and 100 nF above).
  The ladder's full scale is this chip's VCC, so any noise on it comes out in
  the audio in proportion to the sample (at silence, 80h, half of it).  The
  chip draws almost nothing, so the 10 Ω drops only millivolts.
- In the FPGA model the register is `audioDacProc` in `basys_top.vhd`, and
  Q7:Q0 come out on Pmod JA (JA10 = Q7 down to JA1 = Q0, 3.3 V full scale).
  The same ladder and filter work there.

### The R-2R ladder

| Part | Value | Qty |
|---|---|---:|
| 2R: one per bit, plus the termination | 20.0 kΩ, 1 % metal film | 9 |
| R: between neighboring nodes | 10.0 kΩ, 1 % metal film | 7 |

- Output = VCC × code / 256, so 0 V to 4.98 V, 2.49 V at silence (80h).
- The ladder's output resistance is R (10 kΩ) at every code, which becomes
  the first resistor of the filter.
- With 1 % parts the steps are even to about 7 bits, which is not audible as
  distortion in sound like this.  For a true 8-bit match, use 0.1 % parts for
  the MSB's 20 k and the two 10 k / 20 k next to it, or a ready-made 10 k R-2R
  network (for example the Bourns 4310R-R2R-103 SIP; check stock).
- The HCT output resistance (about 50 Ω) against 20 kΩ is a 0.25 % error,
  smaller than the resistor tolerance.

### The filter (2nd-order Sallen-Key, unity gain)

| Part | Value | Notes |
|---|---|---|
| R1 | the ladder itself (10 kΩ) | no part |
| R2 | 10.0 kΩ, 1 % | |
| C1 (feedback, to the op-amp output) | 2.2 nF, C0G or film | |
| C2 (to ground) | 1.0 nF, C0G or film | |
| U | MCP6002-I/P (dual, rail-to-rail in and out, 5 V, DIP-8) | second half unused: wire it as a follower (OUT to IN-) with IN+ tied to the first half's output |
| Supply | 100 nF from pin 8 to AGND, powered from "DAC 5V" | |

- Corner fc = 1 / (2π × 10 k × √(2.2 n × 1 n)) = 10.7 kHz; Q = 0.74
  (Butterworth is 0.71).
- Response: about −1 dB at 8 kHz, −11 dB at 20 kHz, −19 dB at 31.5 kHz (the
  sample rate).  The step-hold of the samples adds its own null at 31.5 kHz,
  so the line-rate whine is well under the audio and above hearing anyway.
- Ceramic capacitors must be C0G (NP0); X7R values move with voltage and
  distort.

### The output

| Part | Value | Why |
|---|---|---|
| Series resistor | 100 Ω | keeps the op-amp stable into a cable, limits a short |
| Coupling capacitor | 10 µF, 16 V or more, + toward the op-amp | removes the 2.49 V offset; with a 10 kΩ load the low corner is 1.6 Hz |
| Bleed resistor | 100 kΩ, jack side to AGND | keeps the jack side at 0 V so plugging in doesn't pop |
| Jack | 3.5 mm stereo, tip and ring both to the output | mono into both ears or channels |

- Level: about 5 V peak to peak (1.75 V rms) at full scale, a little above
  consumer line level.  Software can keep it lower, or a 10 kΩ log trimmer can
  replace the bleed resistor (wiper to the jack).
- A speaker needs an amplifier: an LM386 (DIP-8) fed from the jack node,
  with its own decoupling.  It is not counted here.
- **Grounds:** the ladder's termination, C2, the op-amp, and the jack all
  return to an analog ground (AGND) that meets the logic ground at one point,
  at the power input.

## Click-free rules

The hardware never adds a click on its own:

1. **One sample per line, no gaps, no repeats**, on all 525 lines, and every
   update at the same point in the line.
2. **All 8 bits change on one edge** of the 74HCT574, so the ladder never sees
   a half-updated value; the few-ns skew between bits is far above the audio
   band, and the filter removes it.
3. **Silence is 80h**, and the output is AC coupled, so starting and stopping
   never makes a DC step.
4. **Silent from power-up without a mute circuit.**  The read follows the
   ROM/RAM map, and every section reads ROM after reset.  With 80h in ROM at
   4DF3h-4FFFh, the output sits at mid-scale from the first line.  Software
   fills the RAM buffer with 80h (writes always go to RAM), then sets map bit 2.
   The ROM could also hold a startup chime there.  The 74HCT574 powers up with
   a random value for one line (32 us), which the filter and coupling capacitor
   turn into nothing worth hearing.

Software has its own part:

- Fade a sound in and out over a few milliseconds; never cut it off mid-wave.
- Leave 80h in the buffer when nothing is playing.
- Keep the buffer filled ahead of playback (next section).  If a program stops
  refilling, the last frame repeats, which is a buzz, so fade to 80h first.

## Software

**Playback position.**  The sample playing is line V - 499, and the line read
at 5000h returns V9:V2 (V / 4).

**Double buffering.**  The buffer splits at line 768, which is where the line
read reaches C0h and the address reaches 4F00h:

| Half | Lines | Line read | Bytes | Addresses |
|---|---|---|---|---|
| A | 499-767 | 7Ch-BFh | 269 | 4DF3h-4EFFh |
| B | 768-1023 | C0h-FFh | 256 | 4F00h-4FFFh (one page) |

At least twice per frame (every 8 ms), read the line count and refill the
half that is not playing:

    ld 0x50, y
    ld [y,x], ac          ; line read (V9:V2)
    ; ac >= 0xC0: half B is playing, so refill half A if not done this frame
    ; ac <  0xC0: half A is playing, so refill half B if not done this frame

Each refill has 8 ms to finish, so no exact timing is needed.  If one is
late, the old half plays again (a stutter).

**Other rates.**  Writing each sample twice gives 15.7 kHz, four times
7.9 kHz.  A tone with a whole number of cycles per frame (a multiple of
59.94 Hz) loops with no refills at all.

**CPU time** (estimates from the instruction clock counts in CPU.md, not
measured; about 380,000 CPU clocks per frame):

| Work | Clocks per sample | Per frame |
|---|---:|---:|
| Hardware read (stall) | 1 | 0.14 % |
| Polling the line read twice | | under 0.1 % |
| Silence or a looping tone | 0 | 0 % |
| Copying a stored sound | about 25 | about 3.5 % |
| One generated voice (phase add and wavetable) | about 40 | about 5.5 % |
| Each extra mixed voice | about +25 | about +3.5 % |

## Memory map impact

- 4DF3h-4FFFh is the audio buffer while sound is used.  The rest of 4000h-4DF2h
  is free.
- Sound needs map bit 2 set to RAM (or it plays whatever the ROM holds there).
- The /SND_WR strobe at 5100h is no longer needed for sound and is free.
