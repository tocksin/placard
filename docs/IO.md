# I/O: keyboard, SNES pads, SD card, PS/2 keyboard and mouse

Date: 2026-10-25

Both SNES pads, the SD card, a PS/2 mouse and a PS/2 keyboard share one
port at x5200-x52FF.  They are polled, never used at the same moment, so
they share one PLD: its output register is the port latch and it drives
the inputs onto the bus on reads.

**No built-in keyboard (Justin, 2026-10-25).**  The Cherry MX key matrix,
its keyboard board and header J1 are dropped; the keyboard is any PS/2
keyboard in the lower PS/2 socket.  Without key columns and rows the port
PLD (rev 03) took over the port latch (74HC574, U37) and the row buffer
(74F541, U39), so the main board loses two chips and J1.  The schematic,
BOM, library, simulator and FPGA model still have the matrix until Justin
says to carry the change through (see "Still to carry through" below).  The expansion slots
are described in [EXPANSION.md](EXPANSION.md).

| Part | Job |
|---|---|
| ATF22V10C-7PX | Port PLD (`ATF22V10_PORT.pld`, rev 03): the port latch (5 registers written at any x52xx, clocked by /PORT_WR, I/O decode PLD pin 19), MISO and the PS/2 lines on even reads, pad DATA and the PS/2 keyboard's CLK on odd reads |
| 3.3 V regulator | SD card (not chosen yet; an LM1117-3.3 in TO-220 is one choice) |

Besides the chips: 3 Schottky diodes from the latch outputs to the PS/2
lines, the pull-ups on the pad DATA lines, MISO and the three PS/2 lines,
three resistor dividers for the SD card, the SD socket, two pad sockets
and a stacked dual mini-DIN 6 (mouse on top, keyboard below).  The key
diodes, the 3 row diodes (MISO, PS/2 DATA, mouse CLK onto the rows) and
the 8 row pull-ups went with the matrix: those lines now go straight to
port PLD inputs.

## Schematic

![Placard I/O schematic](../schematics/placard_io_schematic.png)

The drawing is made by `src/scripts/gen_io_schematic.py` (2026-10-18);
rerun it when the pins change.  It shows the I/O decode PLD, the port
chips and the connectors:

| Ref | Connector | Pins |
|---|---|---|
| J2, J3 | SNES pad 1 and 2 | 1 +5 V, 2 CLOCK (latch Q0), 3 LATCH (latch Q1), 4 DATA (port PLD pin 7 or 8), 5-6 not used, 7 GND |
| J4 | Full-size SD socket (SPI) | 1 CS, 2 DI, 5 CLK from the dividers R42-R47; 7 DO = MISO (port PLD pin 13); 4 VDD 3.3 V; 3, 6 GND; 8, 9 not used |
| J5 | Stacked dual mini-DIN 6 (Kycon KMDGX-6S/6S-S4N): top A = PS/2 mouse, bottom B = PS/2 keyboard | Each: 1 DATA, 3 GND, 4 +5 V, 5 CLK.  The two DATA pins are joined (one PS/2 DATA line); mouse CLK = PS2_CLK, keyboard CLK = KBD_CLK |

No ESD clamps on any of these connectors (taken out 2026-10-23, see
SCHEMATIC_PLAN.md).

## The port

**Write, any address x5200-x52FF (the latch, the port PLD's registers):**

| Bit | Line | Notes |
|---|---|---|
| 0 | SCK, pads' CLOCK | SPI mode 3: SCK idles high.  The pads also idle with CLOCK high |
| 1 | MOSI, pads' LATCH | The card ignores MOSI while /CS is high; LATCH high only reloads the pads |
| 2 | SD /CS | 0 also holds the mouse's CLK line low through a Schottky diode, which stops the mouse |
| 3 | PS/2 DATA | 0 holds the shared PS/2 DATA line low through a Schottky diode (to send to the mouse or the PS/2 keyboard) |
| 4 | PS/2 keyboard CLK, pad select | 0 holds the PS/2 keyboard's CLK low through a Schottky diode and picks pad 2 on odd reads; 1 lets the keyboard send and shows its CLK on odd reads |
| 7:5 | (not stored) | Were the key column code (bits 7:4) until rev 03; write them as 1 so the latch values below stay the same |

**Read an even address (port PLD):** D7 = SD MISO, D6 = the PS/2 DATA
line, D5 = the mouse's CLK line.  D4:D0 are not driven (the bus pull-ups
read them as 1), so software masks them.  These are the bits the 74F541's
rows 7, 6 and 5 gave before rev 03, so the drivers read them unchanged.

**Read an odd address (port PLD):** D7 = pad 1 DATA, D6 = pad 2 DATA
(0 = button down) while latch bit 4 is 0, or the PS/2 keyboard's CLK line
while latch bit 4 is 1.  D5:D0 are not driven, so software masks them.

**At rest** the latch holds **EB** (`P_IDLE`): PS/2 DATA free, /CS low
(card selected and idle, mouse held off), bit 4 low (PS/2 keyboard held
off), MOSI and SCK high.  Every driver leaves the latch at EB.  The port
PLD powers up at EB by itself (its registers clear at power-up and SCK,
MOSI and the DATA hold are declared active low); the boot loader still
writes EB first, as it did when the 74HC574 powered up with random bits.
(Before the PS/2 keyboard socket, rest was FB.)

**The PLD's high level.**  The latch outputs drive the pads' CLOCK and
LATCH (CMOS 4021, high at least 3.5 V) and the SD dividers (about 1 mA).
The 74HC574 was chosen for its full 5 V high.  The ATF22V10C's data sheet
only promises 2.4 V at 4 mA (a TTL-style figure), but into CMOS loads and
1 mA its high is expected near 5 V.  Measure it at bring-up.

**History.**  Until rev 03 a 74HC574 was the latch and a 74F541 read the
key rows (with MISO and the PS/2 lines on rows 7-5) on even reads, and
the port PLD decoded the key column from latch bits 7:4.  The column came
from the latch, not from the address during the read, because an
address-decoded column ('138, key diode, row, 74F541) took about 45 ns
against a 39.7 ns I/O read.

## Keyboard

The keyboard is a PS/2 keyboard in the lower PS/2 socket (below, "PS/2
keyboard socket").  The Cherry MX matrix keyboard (63 keys, an 8 x 8
matrix read through the 74F541, its own board in `kicad/keyboard/`) was
dropped on 2026-10-25: it cost two chips and J1 on the main board, it was
the most expensive part of the kit, it didn't fit the case well, and
mechanical PS/2 keyboards are easy to buy.

The library still uses the matrix's key numbers (column x 8 + row, with
`kbd_map` giving the characters and `KBD_NOW` holding a bit per key), and
the PS/2 driver turns scan codes into those same numbers, so programs and
games that read `KBD_NOW` (the arrows and Space in `raycast.asm` and
`scroller.asm`) don't change.  The 63-key layout behind the numbers:

| Column | Row 0 | Row 1 | Row 2 | Row 3 | Row 4 | Row 5 | Row 6 | Row 7 |
|---|---|---|---|---|---|---|---|---|
| 0 | Esc | 1 ! | 2 @ | 3 # | 4 $ | 5 % | 6 ^ | 7 & |
| 1 | 8 * | 9 ( | 0 ) | - _ | = + | Backspace | Tab | Q |
| 2 | W | E | R | T | Y | U | I | O |
| 3 | P | [ { | ] } | \ \| | Left Ctrl | A | S | D |
| 4 | F | G | H | J | K | L | ; : | ' " |
| 5 | Enter | Left Shift | Z | X | C | V | B | N |
| 6 | M | , < | . > | / ? | Right Shift | Up | Caps Lock | Fn |
| 7 | Right Alt | Left Alt | Space | Right Ctrl | *spare* | Left | Down | Right |

Key number = column x 8 + row.  Codes: Enter 0A, Backspace 08,
Tab 09, Esc 1B, Up 11, Down 12, Left 13, Right 14, Delete 7F, Home 15.
Either Ctrl gives the character AND 1F.  Shift, Ctrl, Alt, Fn (either
Windows key) and Caps Lock give no character; Caps Lock toggles caps lock
and lights the keyboard's Caps Lock light.

`kbd_scan` puts each new press in an 8-entry buffer (`kbd_getc` takes
them).  `con_gets` (in the library at `INPUT_CODE`) reads a typed line
into a buffer (R1:R0, at most R2 characters, ending with a 00), echoing it
on the console with Backspace on the same text row; Enter ends it and AC =
the length.  It waits with `wait_frames_io`, so the keyboard costs it
nothing extra.

## SNES pads

Two 7-pin SNES sockets: +5 V, CLOCK (latch bit 0), LATCH (latch bit 1),
DATA, GND.  The DATA lines have 10k pull-ups and go to the port PLD's
PAD1 and PAD2 inputs.  The pads' DATA lines are never tri-stated and read
low after the 16th bit, so they can't share the key rows.

`pad_read` reads both pads in one pass, about 800 clocks: R1:R0 = pad 1,
R3:R2 = pad 2, bit n = 1 while button n is down (0 B, 1 Y, 2 Select,
3 Start, 4 Up, 5 Down, 6 Left, 7 Right, 8 A, 9 X, 10 L, 11 R).  An empty
socket reads 0000.

## SD card

SPI mode 3, bit-banged.  SCK, MOSI and /CS come down from the 5 V latch
through a resistor divider each, at the SD socket: 1.8k from the latch
(R42-R44), 3.3k to ground (R45-R47).

- **Levels:** a 5 V high gives 3.24 V (3.17 V with a high
  of about 4.9 V at 1 mA), inside the card's 2.06 V (0.625 x VDD) to
  3.6 V input high.  A low is under 0.1 V.
- **Speed:** the divider is a 1.17k source.  Into about 15 pF (card input
  plus trace) that is a 17 ns time constant, so an edge crosses the card's
  threshold in about 20 ns.  The drivers' fastest SCK half period is
  several instructions (over 300 ns, SCK is under 1 MHz), and `sd_init`'s
  slow clocks are far slower.
- **Current:** about 1 mA per line while it is high.  At rest (EB) SCK and
  MOSI are high and /CS is low, so about 2 mA.  The latch also drives the
  pads' CLOCK and LATCH from the same pins; 1 mA is well inside the port
  PLD's 4 mA drive.

MISO needs no buffer going the other way.  The card drives it at 3.3 V
straight into port PLD pin 13, whose TTL input reads 2.0 V and up as a
high.  The 10k pull-up to 3.3 V holds MISO high when the card lets go of
it.  (Before rev 03 MISO reached the 74F541's row 7 through a Schottky
diode, so a key could share the row.)

| Routine | Does | Clocks |
|---|---|---|
| `sd_init` | Starts the card: 80 clocks below 400 kHz with /CS high, CMD0, CMD8, ACMD41 until ready, CMD58, CMD16.  Takes SDSC (version 1 and 2) and SDHC/SDXC cards.  AC = 0 ready, 1 no card, 2 did not start, 3 unusable | about 200,000 (8 ms) |
| `sd_read` | One 512-byte block (R3:R0 = block number, R5:R4 = buffer).  AC = 0, 4 refused, 5 no data | about 140,000 (5.5 ms) |
| `sd_write` | One 512-byte block.  AC = 0, 4 refused, 6 not accepted, 7 card stayed busy | about 195,000 |

Block numbers are always 512-byte blocks; `sd_read` and `sd_write` turn them
into byte addresses for SDSC cards.  About 90 KB/s reading.

### Files on the SD card

`src/scripts/placard_fs.asm` (in the library at `FS_CODE`, ROM xC700-xD4FF) reads files
from a card formatted on a PC, FAT16 or FAT32, with a partition table (the
first partition) or without one.  It is read only, finds short 8.3 names
("LONGFI~1.TXT" for a long name), and does not read FAT12 (volumes under
about 16 MB).

```
    (CALL sd_init)              ; AC = 0 when the card is ready
    (CALL fs_mount)             ; AC = 0: the root is the current folder
    ld   name & 0xFF, ac        ; R1:R0 = "GAME.BIN", 00
    ld   ac, [R0]
    ld   name >> 8, ac
    ld   ac, [R1]
    ld   0x00, ac               ; R5:R4 = x0100, where to load it
    ld   ac, [R4]
    ld   0x01, ac
    ld   ac, [R5]
    (CALL fs_load)              ; AC = 0 when loaded
```

| Routine | Does | Clocks |
|---|---|---|
| `fs_mount` | Finds the file system; the root becomes the current folder | about 130,000, 260,000 with a partition table |
| `fs_root` | The root becomes the current folder | about 2,000 |
| `fs_next` | The next entry of the current folder in `FS_ENTRY` (name 0-10, attributes 11 with 10h = folder, size 28-31); AC = 1 at the end.  Skips deleted entries, long name parts and the volume name | about 1,000, or 140,000 when it reads a sector |
| `fs_open` | R1:R0 = a name ending in 00 (any case).  A file opens for `fs_read` with `FS_REM` = its size; a folder (or "..") becomes the current folder | about 1,000 per entry passed plus 140,000 per sector |
| `fs_read` | The next 512 bytes of the open file to R5:R4, which moves on by 512; AC = 1 at the end | about 160,000 (75 KB/s) |
| `fs_load` | `fs_open` and `fs_read` to the end, to R5:R4 | about 160,000 per 512 bytes |

Errors in AC: 1 end, 2 not found, 4 and 5 from `sd_read`, 8 not mounted,
9 no FAT file system, 10 FAT12.  There is one reader: after `fs_open` of a
file, `fs_next` starts the folder over, and `fs_read` can't go on after
`fs_next` or another `fs_open`.  The last sector is read whole, so up to
511 bytes past the end of the file are written.  The reader's variables are
at x4D00-x4D7F and its sector buffer at x4E00-x4FFF (section 2, RAM in map
05).  `test_fs.py` checks it on FAT16 and FAT32 images made by `mkfs.fat`
and `mtools` (it skips when they are not installed).

## PS/2 keyboard socket (rev 02 hardware)

J5 is a stacked dual PS/2 socket (2026-10-22): the mouse on top, as
before, and the keyboard below.  It adds no chips: one BAT85 (D6), one
4.7k pull-up (R55) and one input on the port PLD.

| PS/2 keyboard line | Pulled low by | Read on |
|---|---|---|
| CLK (KBD_CLK) | latch bit 4 low | port PLD pin 11, D6 on odd reads while latch bit 4 = 1 |
| DATA | latch bit 3 low (shared with the mouse) | port PLD pin 15, D6 on even reads (shared with the mouse) |

The two devices share one DATA line.  That works because a PS/2 device
may only send while its CLK is free, and the driver frees one clock at a
time: the other device's clock stays held low, so it never drives DATA.
When the host sends a command (CLK held, DATA low, then that one CLK
freed), the other device still sees its own CLK low, which means
"inhibited", so it ignores it.

Latch values with the keyboard socket (the high nibble moves from F to E
so bit 4 holds the keyboard off):

| Latch | Meaning |
|---|---|
| EB | Rest: both PS/2 clocks held, /CS low |
| EF | Listen to the mouse (mouse CLK free, keyboard held) |
| FB | Listen to the keyboard (keyboard CLK free, mouse held by /CS low; the SD card sees no SCK edges) |
| E8-EB | SD transfers |
| EC, ED | Pad reads (bit 4 = 0 selects pad 2 on D6) |
| E3, then F3 | Send to the keyboard: DATA low with both clocks held, then free the keyboard clock only |

(The 0F-7F key scan values went with the matrix.)

Buyer note: the keyboard must be a PS/2 keyboard, or a USB keyboard that
supports PS/2 through a passive adapter (many don't).

### The PS/2 keyboard driver

`placard_ps2.asm` (2026-10-22), in the library at `PS2_CODE` (xC000-xC4FF,
plus three small pieces in free ends of other library pages).  Programs
don't change: `kbd_scan` reads the PS/2 keyboard into the same `KBD_NOW`
bits and key buffer as the key matrix, using the same key numbers.

- **Finding it.**  `port_init` sends ED (set the lights) and expects FA
  twice; `KBD_FLAGS` bit 1 = 1 when it answered.  About 5 ms with a
  keyboard, 16 ms without.  A keyboard can still be testing itself after
  power-up, so with none found `kbd_scan` asks again every 32nd call, 4
  times (16 ms each).  A keyboard that stops answering when its light is
  set counts as unplugged.
- **Scan codes.**  Set 2, the keyboard's default.  A make code clears the
  key's bit in `KBD_NOW` and buffers its character (through `kbd_key`, so
  Shift, Ctrl, Caps Lock and Fn work as on the matrix); a break code (F0)
  sets the bit again.  E0 keys: the arrows, right Ctrl, right Alt, keypad
  Enter, and either Windows key as Fn.  The PC keys the 63-key layout has
  no key for give their character straight away: Delete 7F, Home 15,
  \` (Shift: ~).  Pause (E1 and 7 bytes) and the keys with no place (F1-F12,
  the keypad, End, Page Up/Down, Insert) are ignored.  The mapping is the
  same as the FPGA's `ps2_key_matrix.vhd`.
- **Caps Lock** (either keyboard) lights the PS/2 keyboard's Caps Lock
  light: `kbd_scan` sends ED and the light byte when they are out of step
  (about 110,000 clocks, once per press).
- **Held keys** repeat: the keyboard sends the make code again by itself,
  and each one types the character again.
- **One byte at a time.**  A poll reads up to 6 bytes, listening again
  before each.  The keyboard keeps about 16 bytes while it is held off,
  so nothing is lost when a burst takes more than one frame.
- The older RAM demos in the menu ROM (CPU test, pi, Mandelbrot, Life)
  can't reach the library, so in them only the matrix Esc goes back to
  the menu.  ROM programs and the menu itself take either keyboard.

| Routine | Does | Clocks |
|---|---|---|
| `kbd_scan` | As above; with a PS/2 keyboard, also listens to it (unless `wait_frames_io` already did) and reads what it sends | about 2,500 + the listen (about 8,000-26,000) with nothing typed; about 25,000 per byte (a key press is 1-2 bytes, a release 2-3) |
| `wait_frames_io` | `wait_frames`, listening to the mouse and the PS/2 keyboard while it waits (below) | AC frames |
| `kbd_probe` | Looks for a PS/2 keyboard again (as `port_init` does) | about 120,000 (5 ms); 400,000 (16 ms) with none |
| `kbd_cmd` | Sends one command byte to the PS/2 keyboard and reads its FA | about 55,000 |

### Listening costs time

A PS/2 device starts sending only some time after its clock is let go,
and the CPU has to watch every clock edge of a byte (a byte takes 0.7-1.1
ms whatever the code does).  Two things keep the cost down:

- **The listen window adapts** (`ps2_listen`).  It lasts as long as the
  device has been seen to take to start, plus 0.19 ms, up to the full 1 ms
  (`MOUSE_WAIT` = 16 units of 64 us).  Every 32nd listen, and until the
  device has been seen to start at all, it uses the full 1 ms, in case a
  slower start was missed.  A window that is too short never loses data:
  the device is held off before it starts, keeps the data and tries again.
  Measured in the simulator with nothing typed: `kbd_scan` about 11,000
  clocks with a keyboard that starts in 0.05 ms, 19,000 at 0.4 ms, 27,000
  at 0.8 ms.  Real start delays get measured at bring-up (BRINGUP.md).
- **`wait_frames_io`** listens during the time a program spends waiting for
  the next frame.  Call it in place of `wait_frames` (same arguments, jump
  table xFBDC).  With both devices it listens to the mouse in even frames
  and the keyboard in odd ones; in the last frame of the wait it lets a
  device go only while there is time to finish (a mouse packet before line
  read 227, about 3.6 ms before the frame ends; a keyboard byte before 244,
  about 1.4 ms), so the wait still ends at the frame's start.  `mouse_poll`
  and `kbd_scan` then only take what it read: about 150 and 1,600 clocks.
  A program with no spare time in its frame gets nothing from it and
  should keep calling `mouse_poll` and `kbd_scan` as before (or poll every
  second frame: the mouse adds up its movement and the keyboard keeps its
  bytes, so only the delay grows).

`menu_poll` checks the PS/2 keyboard's Esc too.  A ROM program that calls
`menu_poll` but neither `kbd_scan` nor `wait_frames_io` would never hear
that Esc, so when the keyboard hasn't been listened to for 4 frames
`menu_poll` listens to it itself.

## PS/2 mouse

The mouse needs no chips: its CLK and DATA lines are open collector, so the
latch pulls them low through Schottky diodes and the port PLD reads them
back on even reads.

| PS/2 line | Pulled low by | Read on |
|---|---|---|
| CLK | latch bit 2 (= SD /CS) low | port PLD pin 14, D5 on even reads |
| DATA | latch bit 3 low | port PLD pin 15, D6 on even reads |

Both lines have 4.7k pull-ups to 5 V on the main board, as a PS/2 host
must.  Because /CS is low at rest, the mouse is held off (CLK low) except
while software listens to it.  A keyboard scan or pad read raises /CS for
under 50 us, shorter than a PS/2 device waits before it starts to send, so
the mouse can't start a packet then.  `sd_init` is the one exception: its
start clocks keep /CS high for about 370 us, once, when a card is started.

| Routine | Does | Clocks |
|---|---|---|
| `mouse_init` | Resets the mouse (FF: FA, then AA 00 after its self test) and turns reporting on (F4: FA).  AC = 0 running, 1 no mouse, 2 wrong answer | up to 1 s while the mouse tests itself |
| `mouse_poll` | Lets the mouse send (up to 1 ms, as long as it has been seen to take to start: "Listening costs time" above); reads one 3-byte packet if it starts.  After `wait_frames_io` it only returns what that read.  AC = 1 new packet, 0 nothing, 2 bad packet.  `MOUSE_B` bit 0 left, 1 right, 2 middle; `MOUSE_DX` right and `MOUSE_DY` down, -127 to 127 | up to about 25,000 (1 ms) with nothing new, about 76,000 (3 ms) with a packet; about 150 after `wait_frames_io` |
| `mouse_cmd` | Sends one command byte and reads the FA acknowledge, for other settings (sample rate F3, resolution E8) | about 55,000 |

The mouse runs in stream mode.  While it is held off it keeps adding up
its movement, so a poll once per frame loses nothing; one packet carries
up to 255 counts each way, and the driver clamps to ±127.  If a frame or
the packet is cut off (the poll gives up just as the mouse starts), the
mouse sends the whole packet again at the next poll, as PS/2 requires.
A mouse must start sending within about 0.85 ms of being let go; if one
is slower, raise `MOUSE_WAIT` in `placard_io.asm` (each step adds 64 us
to the full-length listens).

`mouse_move` (in the library at `INPUT_CODE`) adds a packet's movement to a pointer
position in R1:R0 (X) and R3:R2 (Y), held to 0-639 and 0-479.  Call it
after `mouse_poll` returns 1.

## Rules for software

- Use the drivers, or leave the latch at EB (`P_IDLE`) when done.
- Never hold /CS high for 50 us or more outside `sd_init` and the mouse
  routines, or latch bit 4 high outside the PS/2 keyboard
  routines (a device would start sending with nobody listening).
- Only one PS/2 clock free at a time (they share DATA).
- Poll once per frame if the program keeps time from the line read.
- Mask D5:D0 when reading the pads at an odd address.

## Zero page

The drivers use xA0-xBF (`zeropage.asm`); programs have x20-x8F.

| Address | Name | Use |
|---|---|---|
| xA0-xA7 | KBD_NOW | One bit per key number (byte = column, bit = row), 0 = down |
| xA8-xAF | KBD_BUF | Key buffer (8 entries, holds 7) |
| xB0, xB1 | KBD_HEAD, KBD_TAIL | Key buffer indexes |
| xB2 | KBD_FLAGS | bit 0 caps lock, bit 1 a PS/2 keyboard answered, bit 2 its Caps Lock light is on, bit 6 `wait_frames_io` listened to it |
| xB3 | IO_TMP | Driver scratch |
| xB4 | SD_FLAGS | bit 0 block addressing (SDHC), bit 1 slow clock, bit 7 ready |
| xB5-xB8 | MOUSE_B, MOUSE_DX, MOUSE_DY, MOUSE_ST | Mouse buttons, movement and state (`MOUSE_ST` bit 7 running, bit 6 `wait_frames_io` listened, bit 0 it read a packet) |
| xB9-xBC | IO_T0-IO_T3 | Driver scratch |
| xBD | FS_IDX | FAT reader scratch |
| xBE, xBF | PS2_DEV, PS2_CM | The PS/2 device being talked to (0 mouse, 1 keyboard) and its CLK bit (20, 40) |

The PS/2 keyboard's state is in RAM at x4D80-x4D9D (next to the FAT
reader's x4D00-x4D7F): its keys (like `KBD_NOW`), new presses, the decoder
state, each device's start delay and the `wait_frames_io` state.

## Code

The drivers are `src/scripts/placard_io.asm`, at `IO_CODE` (ROM
xDC00-xEBFF), part of the library block at the top of the ROM, running in
place (ROM.md).  They use the library's calling convention, and the public
ones have fixed jump table entries ([LIBRARY.md](LIBRARY.md#jump-table)).
`placard_lib.asm` includes them.

The PS/2 keyboard driver and the listening are `src/scripts/placard_ps2.asm`
at `PS2_CODE` (above).

- `src/scripts/io_devices.py`: models of the port, key matrix, pads, SD
  card, mouse and PS/2 keyboard (scan code set 2) for `placard_sim.py`
  (`Cpu(..., io=SharedPort())`).  The port counts any moment both PS/2
  devices drive the shared DATA line.
- `src/scripts/test_io.py`: tests every driver against the models, and
  checks that each leaves the latch at EB and keeps the /CS-high and
  keyboard-clock-free times under 50 us.  The PS/2 keyboard tests cover
  finding it (and finding it later), every key, the E0 and PC keys, the
  light, both keyboards at once, the adaptive window, the mouse and
  keyboard together on the shared DATA line, and `wait_frames_io`.
- `src/scripts/io_demo.asm` (`build\io_demo.bat`): starts the SD card,
  shows the end of block 0, starts the mouse, echoes typed keys and prints
  pad buttons and mouse packets.  It waits with `wait_frames_io`.  On the
  Basys3, set SW15 before reset to use the mouse, or SW14 to use the USB
  keyboard as a PS/2 keyboard (the key matrix is then not connected).

## FPGA model (Basys3)

`basys_top.vhd` has the latch, the port PLD (`port_pld.vhd`, rev 02) and
the 74F541's inputs, with the key matrix; it moves to rev 03 when the
keyboard removal is carried through.

| Placard | Basys3 |
|---|---|
| Key matrix | The USB keyboard, through `ps2_key_matrix.vhd`, while SW15 = 0 |
| PS/2 mouse | The USB mouse on the same port, while SW15 = 1 (the latch drives the PS/2 pins open drain) |
| PS/2 keyboard socket | The USB keyboard on the same port, while SW14 = 1 and SW15 = 0: latch bit 4 holds its CLK and bit 3 DATA (open drain), and the port PLD reads its CLK on pin 9, so it goes through `placard_ps2.asm`.  Not tried on a Basys3 yet: its USB-to-PS/2 bridge has to answer the ED (lights) command for `port_init` to find it |
| SD card | PmodMicroSD on JB (top row): JB1 /CS, JB2 MOSI, JB3 MISO, JB4 SCK |
| Pads | SNES pads on JC (top row): JC1 CLOCK, JC2 LATCH, JC3 pad 1 DATA, JC4 pad 2 DATA, plus the Pmod's 3.3 V and GND |

The Basys3's USB port is one PS/2 port, so the model uses one of the
three, picked by SW15 and SW14 (set them before reset: the keyboard is
looked for by `port_init`).  The pads run from the Pmod's 3.3 V in the
model.  A SNES pad is CMOS shift registers and is generally run at 3.3 V by
FPGA projects, but that is not checked here.

## To check before building

- **Port PLD high level.**  The pads' CLOCK and LATCH need 3.5 V and the
  SD dividers need at least 3.2 V for the card's 2.06 V minimum high.  Measure
  the port PLD's SCK and MOSI highs (pins 20 and 19) with a pad and a card
  plugged in.  The ATF22V10C only promises 2.4 V at 4 mA.
- **Stock:** the regulator is not stock-checked yet.  The ATF22V10C-7PX is
  the same part as elsewhere in the design.

## Still to carry through

Held until Justin says go (2026-10-25), for the keyboard removal:

- Schematic (`gen_kicad_schematic.py`, shared port sheet): remove U37,
  U39, J1, RN2 (row pull-ups) and the 3 row diodes; port PLD rev 03 pins;
  renumber per the numbering rules; drop the `kicad/keyboard/` project and
  `schematics/placard_keyboard.pdf`; BOM (main and keyboard sections),
  kit pricing, CHIPS tally already updated in CHIPS.md.
- `gen_io_schematic.py` drawing, block diagram chip counts, README.
- Library: the matrix part of `kbd_scan`, `KBD_NOW` from PS/2 only,
  `menu_poll`'s matrix Esc, bring-up tests that read rows; latch values
  can stay (bits 7:5 ignored).  Suggested: `kbd_scan` listens only every
  2nd or 4th call (the keyboard keeps its bytes) to cut its CPU time.
- Simulator (`io_devices.py` port model, `test_io.py`), FPGA
  (`port_pld.vhd` rev 03 with the latch, `basys_top.vhd` without the 574,
  541 and `ps2_key_matrix.vhd`; SW14/SW15 choices), BRINGUP.md port steps.
- The old RAM demos in the menu ROM only see the matrix Esc, so without
  the matrix they can't go back to the menu (reset instead).
