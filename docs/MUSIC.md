# Music player

Date: 2026-11-02

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

`test_mus.py` plays the demo song in `placard_sim` with the video stalls
modeled, with `mus_frame` called at random times, once a frame, and from a
busy program, and compares every byte the video reads with the model; it
also checks a sound effect and a stop, and `--cpu` measures the clocks a
frame.

## TRACKER.PLC: the editor

`sdcard/TRACKER.PLC` (`tracker.masm`) edits a song on the machine: the
orderlists, the four voices' patterns side by side, the instruments and the
wave and pulse tables, plays it while you edit, and loads and saves `.SNG`
files on the card (the same files `mus_tool.py` makes, so a song can go
back and forth between the card and `.mus` text).  It starts with
`DEMO.SNG` when the card's folder has it, else with a blank song.  With
`BOOT.CFG` = `TRACKER.PLC` it comes up at power-up; `TRACKER.OVL` must be
next to it (below).

The screen is 80 x 30 text on 2x lines (the editor and the player are more
code than the RAM beside a 1x screen holds; the video RAM that 2x frees
holds most of the code and the patterns):

| Rows | |
|------|---|
| 0 | the header: file, title, octave, instrument, STOP / PLAY (gold) |
| 2-10 | left: the orderlists, 8 positions, `>` on the one shown below; right: the instrument and its fields, or the wave or pulse table |
| 12-13 | the pattern's title and the voice columns |
| 14-27 | the four patterns at the order position, a row per line: note, instrument, effect and parameter |
| 28-29 | the status line and the keys (gold) |

The cursor's row is blue; the row being played is green.  `Tab` cycles the
panes: pattern, order, instrument, wave table, pulse table.

| Keys | |
|------|---|
| `Z`-`M` `,` `L` `.` | notes of the lower octave (the piano row, as in every tracker) |
| `Q`-`I` `9` `O` `0` `P` | the upper octave |
| `1` | key off (in the note column) |
| `-` `=` | octave down / up |
| `<` `>` | the instrument for new notes |
| arrows | move (Ctrl-Q/R/S/T on the 63-key layout) |
| `Del`, `Backspace` | clear the cell |
| `0`-`9` `A`-`F` | a hex digit into the field under the cursor (instrument, effect, parameter, order entry, table entry) |
| `[` `]` | order pane: transpose -1 / +1; instrument and table panes: the field -1 / +1 |
| `I` `L` `S` | order pane: insert a position, loop here, stop here |
| `Enter` | play the song from the start |
| `Space` | play from the order position shown (stop when playing) |
| `Esc` | stop |
| `Ctrl-L` | the pattern's length: 64, 16, 32 |
| `Ctrl-O` / `Ctrl-W` | load / save a `.SNG` (the name is asked on the status row) |
| `Ctrl-N` | a blank song |
| `Ctrl-X` | back to the DOS (twice when the song is not saved) |

Every pattern has a 256-byte slot of its own: 40 slots, the even video
pages x60 ... xA6 and four RAM pages, so a pattern can hold anything up to
64 rows with a note in every row.  The player reads the patterns where
they are, through the offsets in the song's page 0, so a saved song is a
normal `.SNG` with its patterns packed one after the other.  The
orderlists are kept decoded (a pattern and a transpose per position, up
to 30, a loop or stop at the end) and encoded again when saved.

**Memory and the map.**  `TRACKER.PLC` loads at x0100-x3DFF (code to
x33FF, then the player's tables); the rest of the code is in
`TRACKER.OVL`, which the program reads into the even video pages xA8, xAA
... xFE at start (`gen_plc.py --overlay`).  Code and patterns in the video
RAM need the map to read RAM there, so the tracker runs with the map at
FF (every section RAM) and switches to the library's 07 only inside
stubs around each library and DOS call, and while it reads the font
(`asm_expand.py`'s `.region a, b, 2, overlay` and `placard_sim.py`'s
`#overlay` place that code).

## Building

```
cd src\scripts
python mus_tool.py tables                            mus_tables.masm (after a table change)
python mus_tool.py build ..\music\demo.mus -o ..\..\sdcard\DEMO.SNG
python mus_tool.py wav ..\music\demo.mus -o demo.wav --seconds 60
python asm_expand.py play.masm                       play.asm
python gen_plc.py play.asm -o ..\..\sdcard\PLAY.PLC
python asm_expand.py tracker.masm                    tracker.asm
python gen_plc.py tracker.asm -o ..\..\sdcard\TRACKER.PLC --overlay 0xA800,2
                                                     (and TRACKER.OVL)
python test_mus.py                                   the player against the model (a few minutes)
python test_play.py --png play.png                   PLAY.PLC through the DOS
python test_tracker.py --png tracker.png             TRACKER.PLC through the DOS: edit, play, save, load
```
