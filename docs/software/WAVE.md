# Sound player (`WAVE.PLC`)

Date: 2026-11-22

`sdcard/WAVE.PLC` (`src/scripts/wave.masm`) plays the `.WAV` files in the
card's `SOUNDS` folder.  It reads each file from the SD card while it
plays, so a recording of any length plays from a card: speech, a song,
any number of instruments.

![The player in the emulator, part way through BRAHMS.WAV](wave_player.png)

## The file

A plain WAV file with these settings:

| | |
|---|---|
| Format | PCM (not compressed) |
| Bits | 8, unsigned |
| Channels | 1 (mono) |
| Sample rate | 31,469 Hz, 15,734 Hz or 7,867 Hz |
| Name on the card | up to 8 letters or digits and `.WAV` |

That is the board's own sound ([SOUND.md](../sound/SOUND.md)): the video
circuit reads one unsigned 8-bit sample on every scan line, 31,469 a
second, and the file's samples go to the sound buffer as they are.  The
two slower rates write every sample two or four times.

| Rate | Card space | Sounds like | CPU the player uses |
|---|---|---|---|
| 31,469 Hz | 1.9 MB a minute | everything the board's 10.6 kHz output filter passes | 55 % |
| 15,734 Hz | 0.9 MB a minute | AM radio: fine for speech, dull for music | 31 % |
| 7,867 Hz | 0.5 MB a minute | a telephone | 18 % |

The player reads the rate from the file and takes the nearest of the
three, so a file at another rate plays faster or slower than it was
recorded: 32,000 Hz plays 1.7 % slow, which is hard to hear; 44,100 Hz
or 22,050 Hz are far off and should be converted.  A file with 16 bits
or two channels is named on the screen and skipped.  Other chunks in
front of the samples (the `LIST` chunk ffmpeg writes) are fine as long
as the samples start in the file's first 512 bytes.

### Making one

`src/scripts/gen_wave.py` makes a file from any sound file ffmpeg reads
(MP3, WAV, FLAC, OGG, M4A, a video's sound):

    python3 gen_wave.py song.mp3 -o ../../sdcard/SOUNDS/SONG.WAV
    python3 gen_wave.py talk.wav -o TALK.WAV --rate half
    python3 gen_wave.py song.flac -o PART.WAV --start 30 --seconds 20

It mixes to one channel at the exact rate, brings the loudest sample to
97 % of full scale, and adds half a step of noise before rounding to 8
bits, which turns the rounding error into a steady soft hiss instead of
a distortion that follows the sound.

ffmpeg alone also makes a file the player takes (no level or noise
step):

    ffmpeg -i song.mp3 -ac 1 -ar 31469 -c:a pcm_u8 SONG.WAV

So does any sound editor that exports "WAV, unsigned 8-bit PCM, mono" at
a project rate of 31469 Hz (Audacity: Tracks, Resample; Export, Other
uncompressed files).

8 bits leave about 48 dB between the loudest sound and the hiss, so the
soft parts of music with loud and soft parts sit close to it.
`--compress` brings them up first (the level over a third of a second,
halved in dB against the loudest part, at most 12 dB up).

The two files on the card are made by `gen_wave_demo.py`:

| File | What | Rate | Size |
|---|---|---|---|
| `BRAHMS.WAV` | Brahms, Hungarian Dance No. 5, played by the United States Army Strings: a public domain recording from Musopen (`src/sounds/README.md`), 46 seconds, with `--compress` | 31,469 Hz | 1.4 MB |
| `HELLO.WAV` | speech from espeak-ng, 9 seconds | 15,734 Hz | 138 KB |

## Keys

| Key | Does |
|---|---|
| Space | pause, and go on |
| Right, Enter | the next file (after the last, the first) |
| Left, Backspace | the file before |
| Esc | back to the DOS, or to Pinboard |

The files play in the order they are in the folder (255 at most).  After
the last one the player goes back by itself.

## From Pinboard

In [Pinboard](PINBOARD.md)'s Files card, Enter on a `.WAV` file (or a
click on the chosen one) runs the player on that file.  The files are
then those of its folder, which need not be `SOUNDS`; when the folder's
last file ends, or at Esc, Pinboard comes back in that folder with the
file still chosen.  Pinboard leaves the folder's first cluster, the
file's number among the folder's `.WAV` files and the mark "S" in the
menu block (x5D19-x5D1F, `placard_menu.asm`), the bytes the photo viewer
uses with the mark "V".

## How it keeps up

The sound buffer x5DF3-x5FFF is a ring of 525 bytes that the video reads
once a frame.  The line read (x5000) says where the video is in it, in
groups of four lines.

1. `fs_read` reads a sector to x4000.  That takes about 7 ms, 227 scan
   lines.
2. The sector goes to the ring in pieces of 256 ring bytes.  A piece is
   written when 268 lines or more are free between the write pointer
   and the video, starting just behind what was written last.  Copying
   a piece takes about 33 lines.
3. With the sector used up, the next is read at once.  The ring then
   holds about 495 samples not played yet and the read uses 227 of them.

So the ring never runs empty and the video never passes the writing: the
samples come out in order, none lost and none twice.  A card can answer
about 7 ms late before a gap would be heard.

**The FAT.**  When a sector is the first of a new cluster, `fs_read` may
have to read a FAT sector first, and two reads in a row are as long as
the whole ring.  So when the sector just read was its cluster's last,
the player looks the next cluster up itself (`fs_nextc`, putting the
reader's cluster back afterwards) right after a piece, when the ring is
full.  The FAT sector is then already in the reader's buffer when
`fs_read` needs it.

**The ends.**  After a file's last sample the player writes a piece of
silence, waits until the video is in it, and then fills the whole ring
with silence, so the end is clean.  Pause writes silence in place of
samples; Esc and the keys that change the file silence the ring first.

RAM: the program at x0100, zero page x20-x8F, the sector at x4000-x41FF,
a page of silence at x4200.

## Next to the four-voice music player

| | This player | [Music player](../sound/MUSIC.md) |
|---|---|---|
| Plays | a recording: anything | four voices of its instruments |
| Rate | 31,469 Hz (or 15,734, 7,867) | 15,734 Hz |
| CPU | 55 % (31 %, 18 %) | 20 % |
| Card space | 1.9 MB a minute (0.9, 0.5) | 1 to 2 KB a song |
| The SD card while it plays | in use | free |

A game that wants a recorded tune under it has the half rate's 69 % of
the CPU left, but can't load from the card meanwhile.

## Test

`src/scripts/test_wave.py` (needs node) runs the player in the web
emulator's core, which takes the DAC's sample on every scan line.  Its
test files are noise with no 80h in it, so every sample played is known
to be a file's or silence.  It checks that three files at the three
rates play whole and in order with only silence between them, a header
with other chunks, a 16-bit stereo file skipped, a 300 KB file on cards
with 1 and 8 sectors a cluster (the first reads the FAT again every 256
sectors), the keys (no sample lost or repeated over a pause), Esc with
the ring silent, and Pinboard: Enter on a file, the file played, Pinboard
back in the folder.

Not tried on hardware yet.
