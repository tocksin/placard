# Music player

Date: 2026-11-01

The music player (`src/scripts/placard_mus.masm`) plays songs in the style
of the C64's SID trackers (GoatTracker, SID-Wizard): four voices, each an
oscillator with a waveform and an ADSR envelope, driven once a frame by
patterns of notes, instruments with wave and pulse programs, and effects.
A fifth voice plays sound effects for a game while the song goes on.  It
mixes into the line-fetched audio buffer ([SOUND.md](SOUND.md)) at 15.7 kHz
and takes about 20 % of the CPU with four voices playing.

| File | What |
|------|------|
| `src/scripts/placard_mus.masm` | The player: a program includes it (`.include`) |
| `src/scripts/mus_tables.masm` | Its tables (waves, volumes, notes, envelope rates), made by `mus_tool.py tables` |
| `src/scripts/mus_tool.py` | Song text (`.mus`) to the binary song (`.SNG`), WAV rendering, the reference model of the player |
| `src/music/demo.mus` | The demo song: every waveform and effect, 54 seconds; `sdcard/DEMO.SNG` |
| `src/scripts/play.masm` | `sdcard/PLAY.PLC`: plays DEMO.SNG from the card, shows the voices |
| `src/scripts/test_mus.py` | Runs the player in `placard_sim` and checks every sample against the model |
| `src/scripts/test_play.py` | Runs PLAY.PLC through the DOS in the simulator |

## In a program

```
MUS_TABLES = 0x2000       ; 10 pages of tables, in the program file
MUS_RAM    = 0x4000       ; 10 pages of RAM, not in the file
.include "placard_mus.masm"

    ld   SONG >> 8, ac          ; the song, loaded at a page boundary
    ld   ac, [R1]
    CALL mus_init               ; silence, the buffer filled
    clr  ac
    CALL mus_play               ; subtune 0
loop:
    ld   1, ac
    CALL wait_frames
    CALL mus_frame              ; once a frame (or more often)
    ...
```

| Routine | In | Does |
|---------|----|------|
| `mus_init` | R1 = the song's page | Fills the buffer with silence, resets the voices |
| `mus_play` | AC = subtune 0-6 | Starts the subtune from its first row |
| `mus_frame` | | Writes the buffer ahead of the video read and plays the ticks it passes; call at least once a frame.  About 84,000 clocks a frame with four voices (20 %), 70,000 with three |
| `mus_stop` | | No more rows; every voice releases |
| `mus_sfx` | AC = note 0-95, R0 = instrument, R1 = frames | A sound effect on the fifth voice, heard in voice 4's place while it lasts |

The player uses zero page x60-x9F and T0-T7, and its RAM: pages 0-4 of
`MUS_RAM` are the voices' own wave pages (pulse and custom waves are drawn
there), pages 5-9 the voices' state (x76-x9F of each page; the rest is
free).  It replaces the library's `snd_*` driver: a program uses one or the
other (both write the same buffer, and `snd_*` keeps its state in x90-x9F).
The player runs from RAM: the mixer's step, wave page and volume are
operands of its own instructions, which the tick rewrites.  The song can be
in RAM or ROM (sections 0-2 as the program has them); `play.masm` loads it
from the card with `fs_load`.

**How `mus_frame` keeps up.**  The buffer is a ring of 132 groups of four
lines (the line read counts them).  Each call takes off the groups the
video read since the last fill, writes ahead of the video again up to 131
groups (never the group being read), and repeats while the video moved
during the fill.  A call more than a lap less a group after the last one
loses the samples in between, so a program calls at least once a frame;
the DOS and the menu hook are transparent to it.  The tick (at group x7C,
the line at x5DF3) takes a few groups' time; if the video passes the
write pointer meanwhile, the groups it passed are skipped so the rest stays
in time.

## The voices

Each voice has a 16-bit phase and step (the step for a note is
440 Hz x 2^((n - 57) / 12) x 65536 / 15,735; C-0 is note 0, B-7 note 95), a
waveform and an envelope.  The mixer takes the top byte of the phase into a
256-byte wave page, scales the 6-bit wave value by the voice's 16 levels
through a table (`VOLT`: level x value), and adds the four voices; 80h is
silence.

| Waveform | Page |
|----------|------|
| pulse | The voice's own page: 63 below the pulse width, 0 above; pulse programs and effect 7 sweep it |
| saw | A table, 0-63 over the phase |
| tri | A table, up and down |
| noise | Two pages of random values; the tick re-seeds the phase's high byte from an 8-bit LFSR, so the step sets the pitch |
| cw0-cw7 | A custom wave of 32 values 0-63 from the song, 8 samples each, drawn into the voice's page |

The envelope is the SID's: attack 2 ms to 8 s and decay/release 6 ms to
24 s in 16 steps each (`ATK_MS`, `DEC_MS` in `mus_tool.py`), sustain 0-15.
The level is envelope (top 4 bits) x voice volume x master volume, each
0-15, through a multiply table.  A hard-restart instrument starts its
envelope from 0; otherwise a new note attacks from where the envelope is.

## The song (.SNG)

A page-aligned binary, offsets relative to its start (so it loads
anywhere), built by `mus_tool.py build`:

| Page | Bytes | What |
|------|-------|------|
| 0 | 00-03 | `PMU`, 01 |
| | 04-06 | Subtunes, patterns, instruments |
| | 08-09 | Length |
| | 20-3F | Title, 32 characters |
| | 40-7E | 7 subtunes x 9 bytes: speed (frames per row), four 16-bit orderlist offsets |
| | 80-BF, C0-FF | 64 pattern offsets, low bytes then high |
| 1 | 00-3F, 40-7F | Wave table: left (waveform) and right (note) columns, entries 1-63 |
| | 80-BF, C0-FF | Pulse table: left and right columns |
| 2-3 | | 32 instruments x 16 bytes |
| 4 | | 8 custom waves x 32 values |
| 5 on | | Orderlists and patterns |

**Instrument** (16 bytes): attack/decay, sustain/release, wave program
entry, pulse program entry, pulse width, flags (bit 0 hard restart),
vibrato delay (ticks), vibrato (speed, depth), volume 0-15, a 7-character
name.

**Wave table entry**: left = waveform 1-12 (0 keeps it, 7F off), FE end
(the voice holds the last), FF loop to the entry in the right column;
right = the note: 80 + n absolute, else semitones from the note played
(two's complement in 7 bits).  One entry a tick from the instrument's entry.

**Pulse table entry**: left 80 = set the width to the right byte; 1-7F =
that many ticks adding the right byte (signed) each tick; FF loop; 00 end.

**Pattern** bytes: 00-5F a note (C-0 to B-7), 60 key-off, 61 a row with no
note, 80-BF this row and up to 63 more empty, C0-DF the instrument for the
note that follows, E0-EF an effect and the next byte its parameter, FF end.
A note row is `[instrument] [effect param] note`.

**Orderlist** bytes: 00-3F a pattern, 80-BF transpose by (b - A0)
semitones until changed, FE stop, FF nn loop to entry nn.  The four voices
have orderlists of their own, so a voice can run on patterns of another
length.

## Song text (.mus)

`mus_tool.py build song.mus -o SONG.SNG` reads this; `wav` renders it (the
model, the board's 10.6 kHz filter, 44.1 kHz) and `dump` prints a `.SNG`
as text again.  `src/music/demo.mus` is the example.  `;` starts a comment.

```
title "NAME"
wave  label   pulse +0, noise C-6, +12, loop 0        ; waveform and note per tick
wave  label   saw +0, end
pulse label   set 20, 40x+2, 40x-2, loop 1            ; width, then ticks x change
custom 0  32 values 0-63
instrument $N name ad=08 sr=40 wave=label pulse=label pw=80 hr vib=34 vdelay=10 vol=15
pattern $N
  C-4 01 120          ; note, instrument (hex), effect (hex digit + parameter)
  ...                 ; an empty row
  ... -- 4A6          ; an effect alone
  ===                 ; key off
subtune 0 speed=6
order 0.1: +0 00 01 -4 00 01 loop 0                   ; voice 1: transposes, patterns, loop
order 0.2: 02 02 stop
```

Numbers in `instrument`, `pattern`, `custom` and `subtune` lines are
decimal, or hex with `$` or `0x`; the instrument and pattern numbers in rows
and orderlists are hex.  `wave=` names a wave program by its label, `pulse=`
a pulse program; `hr` is hard restart; `vib=` is speed and depth as two hex
digits.  A waveform in a wave program is `pulse`, `saw`, `tri`, `noise`,
`cw0`-`cw7` or `off`; a note is `C-4` (absolute) or `+3` / `-12` (from the
note played).

## Effects

| Effect | Does |
|--------|------|
| `0xy` | Arpeggio: the note, +x, +y, one a tick |
| `1xx` | Slide up by 4 x xx steps a tick |
| `2xx` | Slide down |
| `3xx` | Portamento: toward the row's note by 4 x xx a tick (the note is not retriggered) |
| `4xy` | Vibrato for this row: speed x, depth y (the instrument's otherwise) |
| `5xx` | Attack/decay = xx |
| `6xx` | Sustain/release = xx |
| `7xx` | Pulse width = xx (the pulse program stops) |
| `8xx` | Wave program from entry xx |
| `9xx` | Voice volume 0-15 |
| `Axx` | Master volume 0-15 |
| `Fxx` | Speed: xx frames per row |

An effect lasts for its row (the slides and vibrato run on every tick of
the row but the first).  Effects 5-A and F take effect at once.

## The tick

Once a lap of the buffer, before the sample at x5DF3 is followed by the
next, the player plays a tick for each voice: on the first frame of a row,
the next row of its pattern (the orderlist when the pattern ends; a new
note triggers the instrument); then the wave program, the pulse program,
the effects, vibrato, the envelope and the pitch; then the voice's mixer
setting (step, wave page, level) goes into the mixer's instructions.  The
sound effect voice ticks like a voice with a row of its own each frame and
takes mixer slot 3 while it lasts.  `mus_tool.Model` is the same, tick for
tick and sample for sample, and `test_mus.py` checks it.

## PLAY.PLC and the demo song

`sdcard/PLAY.PLC` (`play.masm`) loads `DEMO.SNG` from the card's current
folder, plays it and shows the title and each voice's note, instrument
number and name, its row tinted while the voice sounds.  Space starts the
song again, S stops it, 1-4 play a sound effect with instruments 1-4 on the
fifth voice (heard in voice 4's row), Esc goes back to the DOS.  With
`BOOT.CFG` = `PLAY.PLC` it plays at power-up.

The demo song (`src/music/demo.mus`, A minor, 150 bpm, 54 s) has a PWM
bass, drums from wave programs (noise then pulse), triangle pads and pulse
chords arpeggiated by wave programs, the arpeggio effect, a saw lead with
vibrato, slides and portamento, a custom-wave organ and bells, a noise
riser, pulse-width, voice-volume and master-volume effects, a speed change
to double time and back, transposed orderlists and a key change.

## Building

```
cd src\scripts
python mus_tool.py tables                            mus_tables.masm (after a table change)
python mus_tool.py build ..\music\demo.mus -o ..\..\sdcard\DEMO.SNG
python mus_tool.py wav ..\music\demo.mus -o demo.wav --seconds 60
python asm_expand.py play.masm                       play.asm
python gen_plc.py play.asm -o ..\..\sdcard\PLAY.PLC
python test_mus.py                                   the player against the model (a few minutes)
python test_play.py --png play.png                   PLAY.PLC through the DOS
```

`test_mus.py` plays the demo song in `placard_sim` with the video stalls
modeled, with `mus_frame` called at random times, once a frame, and from a
busy program, and compares every byte the video reads with the model; it
also checks a sound effect and a stop, and `--cpu` measures the clocks a
frame.

## Next

An on-machine editor, `TRACKER.PLC`, with the pattern editor, instrument
and table editors, row tints for the beat and the cursor, and a 2x line
repeat mode that frees video RAM for a longer song buffer.
