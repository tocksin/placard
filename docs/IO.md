# I/O: SNES pads, SD card, PS/2 keyboard and mouse

Date: 2026-10-26

Both SNES pads, the SD card, a PS/2 mouse and a PS/2 keyboard share one
port at x5200-x52FF.  They are polled, never used at the same moment, so
they share one PLD: its output register is the port latch and it drives
the inputs onto the bus on reads.  A second PLD, the PS/2 receiver,
takes in the PS/2 bytes by itself (2026-10-25, below).

**No built-in keyboard (Justin, 2026-10-25).**  The Cherry MX key matrix,
its keyboard board and header J1 are dropped; the keyboard is any PS/2
keyboard in the lower PS/2 socket.  Without key columns and rows the port
PLD (rev 03) took over the port latch (74HC574, U37) and the row buffer
(74F541, U39), so the main board loses two chips and J1.  Carried through
the schematic, BOM, library, simulator, FPGA model and bring-up ROM the
same day (the board layout is Justin's: he pulls the schematic change in
with Update PCB from Schematic).

**PS/2 receiver (Justin, 2026-10-25).**  Reading PS/2 bit by bit cost the
CPU about 6 % of its time, which goes against "programming is fun", so
one PLD is added back as a PS/2 receiver: it shifts a byte in on the
device's own clock, holds the device off after the stop bit and hands
the byte to the CPU in one read (`ATF22V10_PS2.pld`, port PLD rev 04).
Net: 33 main-board chips.  A byte costs the CPU about 60 clocks instead
of 25,000, and nothing is spent waiting for a device to start.

The expansion slots are described in [EXPANSION.md](EXPANSION.md).

| Part | Job |
|---|---|
| ATF22V10C-7PX | Port PLD (`ATF22V10_PORT.pld`, rev 04): the port latch (5 registers written at any x52xx, clocked by /PORT_WR, I/O decode PLD pin 19), MISO and the free PS/2 clock on reads of x5200, pad DATA on reads of x5201 |
| ATF22V10C-7PX | PS/2 receiver (`ATF22V10_PS2.pld`, rev 02): shifts in one byte from the mouse or the keyboard on its clock, holds the device off after it, byte at x5202, ready flag at x5203 (D7 = 0), re-armed by a write there |
| 3.3 V regulator | SD card (not chosen yet; an LM1117-3.3 in TO-220 is one choice) |

Besides the chips: 3 Schottky diodes from the latch outputs to the PS/2
lines (D2 /CS to the mouse CLK, D3 to DATA, D6 K0 to the keyboard CLK),
2 from the receiver's inhibit pin to the two PS/2 clock lines (D19, D5),
2 more (D1, D4) and a 22k pull-down (R60) that OR the two clock lines
into the receiver's clock (RXCLK), the pull-ups on the pad DATA lines,
MISO and the three PS/2 lines, three resistor dividers for the SD card,
the SD socket, two pad sockets and a stacked dual mini-DIN 6 (mouse on
top, keyboard below).  The key diodes, the 3 row diodes (MISO, PS/2 DATA,
mouse CLK onto the rows) and the 8 row pull-ups (RN2) went with the
matrix: those lines now go straight to port PLD inputs.

## Schematic

![Placard I/O schematic](../schematics/placard_io_schematic.png)

The drawing is the shared port sheet of the KiCad schematic
(`kicad/shared_port.kicad_sch`, page 10 of `schematics/placard_main.pdf`,
drawn by `src/scripts/gen_kicad_schematic.py`; the PNG is that page
rendered).  It shows the two PLDs, the diodes and the connectors
(the hand-drawn sketch and `gen_io_schematic.py` went on 2026-10-25):

| Ref | Connector | Pins |
|---|---|---|
| J2, J3 | SNES pad 1 and 2 | 1 +5 V, 2 CLOCK (latch Q0), 3 LATCH (latch Q1), 4 DATA (port PLD pin 7 or 8), 5-6 not used, 7 GND |
| J4 | Full-size SD socket (SPI) | 1 CS, 2 DI, 5 CLK from the dividers R42-R47; 7 DO = MISO (port PLD pin 13); 4 VDD 3.3 V; 3, 6 GND; 8, 9 not used |
| J5 | Stacked dual mini-DIN 6 (Kycon KMDGX-6S/6S-S4N): top A = PS/2 mouse, bottom B = PS/2 keyboard | Each: 1 DATA, 3 GND, 4 +5 V, 5 CLK.  The two DATA pins are joined (one PS/2 DATA line, receiver pin 2); mouse CLK = MOUS_CLK, keyboard CLK = KBD_CLK, both into RXCLK (receiver pin 1, port PLD pin 11) through D4 and D1 |

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
| 4 | PS/2 keyboard CLK | 0 holds the PS/2 keyboard's CLK low through a Schottky diode; 1 lets the keyboard send |
| 7:5 | (not stored) | Were the key column code (bits 7:4) until rev 03; write them as 1 so the latch values below stay the same |

**Read x5200 (port PLD):** D7 = SD MISO, D5 = RXCLK, the clock line of
the PS/2 device whose clock the latch has let go.  The other bits are not
driven (the bus pull-ups read them as 1), so software masks them.  MISO
is in the bit the 74F541's row 7 gave before rev 03, so the SD driver
reads it unchanged.

**Read x5201 (port PLD):** D7 = pad 1 DATA, D6 = pad 2 DATA (0 = button
down), D5 = RXCLK.  The other bits are not driven, so software masks them.

**Read x5202 and x5203, write x5202 or x5203 (PS/2 receiver):** the
received byte, the ready flag and the re-arm, see "PS/2 receiver" below.
The port PLD stays off the bus while A1 = 1; a write there also loads the
latch, so software writes the latch's current value.

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
against a 39.7 ns I/O read.  Rev 03 read the PS/2 DATA line and both
clocks itself (D6 and D5 on even reads, the keyboard clock on D6 on odd
reads) for the bit-by-bit PS/2 driver; rev 04 leaves the bits to the
receiver.

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
`scroller.asm`) don't change.  The 63-key layout behind the numbers (the
keys the PS/2 driver decodes; a PC keyboard's other keys are ignored):

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

`kbd_scan` (call it once per frame) puts each new press in an 8-entry
buffer (`kbd_getc` takes them).  `con_gets` (in the library at `INPUT_CODE`) reads a typed line
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
| CLK (KBD_CLK) | latch bit 4 low (D6), or the receiver after a byte (D19) | the receiver's clock (RXCLK, through D1), and D5 of x5200/x5201 |
| DATA | latch bit 3 low (D3, shared with the mouse) | the receiver's DATA input (pin 2), shared with the mouse |

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
| EB | Rest (`P_IDLE`): both PS/2 clocks held, /CS low |
| EF | Listen to the mouse (`P_FREE`: mouse CLK free, keyboard held) |
| FB | Listen to the keyboard (`P_KFREE`: keyboard CLK free, mouse held by /CS low; the SD card sees no SCK edges) |
| E8-EB | SD transfers |
| EC-EF | Pad reads (/CS high: the mouse's clock is let go for the 30 us of the read) |
| E3, then F3 | Send to the keyboard: DATA low with both clocks held, then free the keyboard clock only |

The drivers keep the value of the device being listened to in zero page
`PS2_LSN` (EB, EF or FB) and every port routine leaves the latch equal to
it.  (The 0F-7F key scan values went with the matrix.)

Buyer note: the keyboard must be a PS/2 keyboard, or a USB keyboard that
supports PS/2 through a passive adapter (many don't).

## PS/2 receiver

`ATF22V10_PS2.pld` (2026-10-25, rev 02) receives one byte from either
PS/2 device without the CPU.  Before it, the driver watched every clock
edge of a byte (about 1 ms, 25,000 clocks) and busy-waited up to 1 ms for
the device to start, about 6 % of the CPU with both devices polled every
frame; the receiver makes a byte cost about 60 clocks and the waiting
nothing.

**Clock.**  The two PS/2 clock lines go through a Schottky diode each
(anodes on the lines) into one node, RXCLK, with a 22k pull-down.  The
latch holds the clock of the device not in use low, so RXCLK is the free
device's clock alone (about 3.9 V high); with both held it stays low.
RXCLK is the receiver's register clock (pin 1) and the port PLD reads it
on D5 for the routines that send to a device.  The receiver samples
DATA on the RISING edge of the clock: a PS/2 device holds its bit at
least 5 us after its clock rises, so the bit is still there, and the
edge the latch makes when it lets a clock go shifts in the idle level,
which is harmless (next paragraph).

**Shift register.**  Eight registers shift in the inverse of DATA.  All
registers are 0 after a reset, and a 1 on DATA (idle, the stop bit, a
released clock) shifts in a 0 and changes nothing, so the first 1 to
appear is the start bit.  When it reaches the last stage (8 clocks) the
next clock shifts d7 in and starts a two-bit count of the parity and stop
clocks (states 01, 11, 10); from then on the data holds.  After the stop
clock, the 11th, the last state (10) does two things at once: it drives
the inhibit pin low, through a Schottky diode onto each PS/2 clock line
(pulling the held one changes nothing), so the device keeps its next byte
until the CPU re-arms the receiver; and it is the ready flag.  The device
is inhibited only after its 11th clock, as a PS/2 host must do, so it
never resends a byte the receiver has.  Parity is not checked.

| Address | Read | Write |
|---|---|---|
| x5202 | D7:D0 = the byte, valid while the ready flag shows | re-arm (clears the receiver and lets the device's clock go) |
| x5203 | D7 = 0 while a byte is ready, 1 otherwise; D6:D0 read as 1 | re-arm |

Ready reads as a 0 (rev 02): the A state pin is enabled, inverted, on a
read of x5203 only while B = 0, so a sign test (`blt`) on the read says
"nothing yet".  Rev 01 had the flag at the 10th clock, 80 us before the
inhibit; the CPU could then hold the device's clock in the middle of its
stop bit, and the device sent the byte again (seen in the simulator).
With the flag and the inhibit the same state the CPU may hold the
device's clock the moment it has the byte.

A write to either address also clocks the port latch, so the re-arm is a
write of the latch's current value (`PS2_LSN`: `P_IDLE`, or the listen
value while a device is free).  A byte takes: read x5203 (sign test),
read x5202, write the re-arm, about 60 clocks; a check with nothing in
costs one read.  A re-arm while the stop bit is still coming is harmless
(it shifts in a 0).  A device whose clock is held in the middle of a byte
sends its whole chunk again later (a mouse: the three-byte packet), but
only if it sees the hold, which PS/2 promises for 100 us: `ps2_pause`
keeps its hold that long, and first takes the byte a mouse is sending
when part of a packet is already in hand.  While the CPU sends a command
(DATA held low, the device clocks), the receiver counts those clocks too,
so the send routine re-arms it at every bit, and it never reaches 11
before the device's acknowledge clock; after the send the receiver takes
the device's answer.

The receiver uses all ten output cells: the eight data bits (three
product terms each, 3-state onto D7:D0), the state bit A (3-state,
inverted, onto D7 on reads of x5203 while B = 0; its pin shares the D7
wire with d7's pin, the two are never enabled together) and the state
bit B (its output enable is A, so the pin floats while receiving and
drives low only in the ready state).  Six input pins are spare (7-11,
13).  It is the one chip in the design whose registers are not clocked
by the 25 MHz clock; the CPU reads them asynchronously, which is safe
because the byte holds from its 9th clock on, before the ready flag can
be seen.

**Why not fit it in the port PLD.**  Eight data registers plus two state
bits are ten cells; the latch (five), the three read bits and the inhibit
make eighteen.  No other PLD has ten free cells (PLD_USAGE.md), and a
74HC595 shift register would still need a PLD to count the clocks and
inhibit.  Two spare input pins of the port PLD (pins 11, 14) now take
RXCLK and A1 instead of the two clocks and DATA, and its pin 15 is free.

**Drivers.**  `kbd_scan`, `mouse_poll`, `ps2_poll` and `wait_frames_io`
take whatever the receiver has (`ps2_take`: the byte goes to the keyboard
decoder or the mouse's packet, whichever device is listened to), re-arm,
and then give the line to the right device (`ps2_turn`, below).  A
program with no spare time calls the drivers once a frame and loses
nothing: the device keeps its bytes behind the one the receiver holds.
The bit-by-bit `ps2_listen`, `ps2_rx`, the adaptive window and
`MOUSE_WAIT` are gone.

### The PS/2 keyboard driver

**Plug in the keyboard and mouse before turning the machine on.**  They
are not hot-pluggable: one plugged in later is not recognized until the
machine is reset (SW2, the reset button).

`placard_ps2.asm` (rewritten 2026-10-25 for the receiver), in the library
at `PS2_CODE` (xC000-xC4FF, plus pieces in free ends of other library
pages: the mouse routines and `ps2_tx`/`ps2_rx` in I/O pages B-E, `ps2_poll`,
`ps2_cmd` and `kbd_lights` in I/O page 1).  Programs don't change:
`kbd_scan` reads the PS/2 keyboard into the same `KBD_NOW` bits and key
buffer the key matrix used, with the same key numbers.

- **Finding it.**  `port_init` sends ED (set the lights) and expects FA
  twice; `KBD_FLAGS` bit 1 = 1 when it answered.  A keyboard can still
  be testing itself after power-up, so with none found `kbd_scan` asks
  again every 32nd call, 4 times.  With no mouse running, the keyboard
  socket is listened to even when nothing answered, and the first byte
  that comes from it (a key, or the AA a keyboard sends when it is
  plugged in) marks the keyboard found, so a keyboard that missed the
  ED (or was plugged in later) still works.  A keyboard that stops
  answering when its light is set counts as unplugged.
- **Scan codes.**  Set 2, the keyboard's default.  A make code clears the
  key's bit in `KBD_NOW` and buffers its character (through `kbd_key`, so
  Shift, Ctrl, Caps Lock and Fn work as on the matrix); a break code (F0)
  sets the bit again.  E0 keys: the arrows, right Ctrl, right Alt, keypad
  Enter, and either Windows key as Fn.  The PC keys the 63-key layout has
  no key for give their character straight away: Delete 7F, Home 15,
  \` (Shift: ~).  Pause (E1 and 7 bytes) and the keys with no place (F1-F12,
  the keypad, End, Page Up/Down, Insert) are ignored.
- **Caps Lock** lights the keyboard's Caps Lock light: `kbd_scan` sends
  ED and the light byte when they are out of step (`kbd_lights`, about
  3 ms, once per press).
- **Held keys** repeat: the keyboard sends the make code again by itself,
  and each one types the character again.
- **One byte per turn.**  The receiver holds one byte and the keyboard
  keeps about 16 more while it is held off, so nothing is lost when a
  burst takes several frames; `wait_frames_io` and `ps2_poll` take bytes
  as fast as they land (a byte every 1.2 ms or so).
- The older RAM demos run by the DOS or the menu (CPU test, pi, Mandelbrot, Life)
  can't reach the library; a small hook in each (`menu_hook.py`) reads
  the receiver once per frame, so Esc works there too.

| Routine | Does | Clocks |
|---|---|---|
| `kbd_scan` | Takes the bytes in the receiver, decodes keyboard bytes, gives the line to the right device (`ps2_turn`), puts new presses in the buffer | about 240 with nothing typed; about 1,500 per key byte (a press is 1-2 bytes, a release 2-3; one byte per frame while a mouse is there too) |
| `ps2_poll` | Takes and decodes whatever the receiver has, then the turn; jump table xFBE0.  For a program that polls more than once a frame, or a loop with no `kbd_scan` | about 150 with nothing in; a byte every 1.2 ms in a burst |
| `wait_frames_io` | `wait_frames`, taking the devices' bytes while it waits (below) | AC frames |
| `kbd_probe` | Looks for a PS/2 keyboard again (as `port_init` does) | about 3 ms; longer with none (the ED times out) |
| `kbd_cmd` | Sends one command byte to the PS/2 keyboard and reads its FA (the mouse is held meanwhile, and the line goes back to whoever had it) | about 2 ms |

### Turns: who has the line

Only one PS/2 device may be let go at a time (they share DATA), and a
device sends only while its clock is free.  `ps2_turn` (the end of every
poll) picks the device: with both present the mouse gets even frames
(`FRAME_LO` bit 0 = 0) and the keyboard odd ones, so each is listened to
30 times a second and a key press or a packet is never more than two
frames late.  A mouse with part of a packet in keeps the line until the
packet is complete (a half packet older than 4 frames is dropped and the
turn goes on).  With one device it has the line all the time.  The chosen
value is kept in `PS2_LSN` and written to x5202, which re-arms the
receiver in the same write.

- **Once a frame is enough.**  The receiver holds one byte and both
  devices buffer behind it, so a program that calls `kbd_scan` and
  `mouse_poll` once per frame (about 500 clocks together when nothing
  comes in) misses nothing; the mouse adds up its movement and the
  keyboard keeps its codes.  A byte, when one came, costs about 1,500
  clocks of decoding.
- **`wait_frames_io`** takes bytes as they land during the time a program
  spends waiting for the next frame (call it in place of `wait_frames`,
  same arguments, jump table xFBDC), and does the turn at each frame
  tick, so the devices stream at full speed while the program idles.
  `mouse_poll` and `kbd_scan` then only hand over what it took.
- **`mouse_poll`** waits for the rest of a packet that is half in when the
  mouse has the line (up to about 2 ms per byte), so a packet is not
  spread over three frames; not after `wait_frames_io`, which took the
  bytes as they came.
- **`ps2_pause`** (inside `pad_read`, `sd_init`, `sd_read`, `sd_write`)
  takes the byte in the receiver, holds both devices for at least 100 us
  (so a device in the middle of a byte is sure to give it up and send
  its chunk again) and re-arms; the routine writes `PS2_LSN` back to
  x5202 when it is done.  With part of a mouse packet in hand it first
  waits for the byte the mouse is sending, so the packet in hand is not
  sent twice.

`menu_poll` checks the PS/2 keyboard's Esc too.  A ROM program that calls
`menu_poll` but neither `kbd_scan` nor `wait_frames_io` would never see
that Esc, so when `kbd_scan` has not run this frame `menu_poll` calls
`ps2_poll` itself.

## PS/2 mouse

The mouse needs no chips of its own: its CLK and DATA lines are open
collector, so the latch pulls them low through Schottky diodes and the
receiver takes its bytes.

| PS/2 line | Pulled low by | Read on |
|---|---|---|
| CLK (MOUS_CLK) | latch bit 2 (= SD /CS) low (D2), or the receiver after a byte (D5) | the receiver's clock (RXCLK, through D4), and D5 of x5200/x5201 |
| DATA | latch bit 3 low (D3) | the receiver's DATA input (pin 2) |

Both lines have 4.7k pull-ups to 5 V on the main board, as a PS/2 host
must.  Because /CS is low at rest, the mouse is held off (CLK low) except
while it has the line (`ps2_turn`).  A pad read raises /CS for about
30 us, shorter than a PS/2 device waits before it starts to send, so the
mouse can't start a packet then (`ps2_pause` has held it for 100 us just
before, so a packet it was sending is given up and sent again).
`sd_init` is the one exception: its start clocks keep /CS high for about
370 us, once, when a card is started, with the receiver re-armed after.

| Routine | Does | Clocks |
|---|---|---|
| `mouse_init` | Resets the mouse (FF: FA, then AA 00 after its self test) and turns reporting on (F4: FA).  AC = 0 running, 1 no mouse, 2 wrong answer | up to 1 s while the mouse tests itself |
| `mouse_poll` | Takes the bytes in the receiver (a keyboard byte too) and hands over the movement of the packets that came since the last poll, added up and held to -127..127; waits for the rest of a half packet while the mouse has the line; then the turn.  AC = 1 something new, 0 nothing.  `MOUSE_B` bit 0 left, 1 right, 2 middle; `MOUSE_DX` right and `MOUSE_DY` down | about 250 with nothing new or after `wait_frames_io`; about 2,000 more with a packet, plus up to about 2 ms waiting for the rest of one that is half in |
| `mouse_cmd` | Sends one command byte and reads the FA acknowledge, for other settings (sample rate F3, resolution E8); the keyboard is held meanwhile | about 2 ms |

The mouse runs in stream mode.  While it is held off it keeps adding up
its movement, so a poll once per frame loses nothing; one packet carries
up to 255 counts each way, and the driver adds the packets up and holds
the sum to ±127.  A packet that is cut off (a hold in the middle of a
byte) is sent again by the mouse, whole, as PS/2 requires; the driver
starts the packet over when that happens (a first byte always has bit 3
set).

`mouse_move` (in the library at `INPUT_CODE`) adds a packet's movement to a pointer
position in R1:R0 (X) and R3:R2 (Y), held to 0-639 and 0-479.  Call it
after `mouse_poll` returns 1.

## Rules for software

- Use the drivers, or leave the latch at `PS2_LSN` when done (EB,
  `P_IDLE`, when no device is being listened to: before `kbd_scan` or
  `ps2_poll` first runs; after that the keyboard socket, FB, when no
  mouse runs).
- Hold both PS/2 devices (`ps2_pause`) around anything that changes
  latch bits 2-4 or makes an edge on a clock line, then write `PS2_LSN`
  back to x5202; the SD data transfers (SCK, MOSI only) need no pause.
- Only one PS/2 clock free at a time (they share DATA).
- Call `kbd_scan` and `mouse_poll` once per frame, or `ps2_poll` when
  polling more often; `wait_frames_io` in place of `wait_frames`.
- Mask D5:D0 when reading the pads at an odd address; test the
  receiver's ready flag with a sign test (D7 = 0 is ready).
- Re-arm the receiver (write `PS2_LSN` to x5202) after taking a byte,
  when changing the device, and at each bit of a send.

## Zero page

The drivers use xA0-xBF (`zeropage.asm`); programs have x20-x8F.

| Address | Name | Use |
|---|---|---|
| xA0-xA7 | KBD_NOW | One bit per key number (byte = column, bit = row), 0 = down |
| xA8-xAF | KBD_BUF | Key buffer (8 entries, holds 7) |
| xB0, xB1 | KBD_HEAD, KBD_TAIL | Key buffer indexes |
| xB2 | KBD_FLAGS | bit 0 caps lock, bit 1 a PS/2 keyboard answered, bit 2 its Caps Lock light is on |
| xB3 | IO_TMP | Driver scratch |
| xB4 | SD_FLAGS | bit 0 block addressing (SDHC), bit 1 slow clock, bit 7 ready |
| xB5-xB8 | MOUSE_B, MOUSE_DX, MOUSE_DY, MOUSE_ST | Mouse buttons, movement and state (`MOUSE_ST` bit 7 running, bit 6 `wait_frames_io` polled since `mouse_poll` last ran) |
| xB9-xBC | IO_T0-IO_T3 | Driver scratch |
| xBD | FS_IDX | FAT reader scratch |
| xBE | PS2_LSN | The latch value letting the listened PS/2 device send: EB none, EF the mouse, FB the keyboard |
| xBF | — | spare |

The PS/2 driver's state is in RAM at x4D80-x4D99 (next to the FAT
reader's x4D00-x4D7F): new presses, the decoder state, the probe retry
count, the mouse's packet in hand and its added-up movement, and the
command being sent.

## Code

The drivers are `src/scripts/placard_io.asm`, at `IO_CODE` (ROM
xDC00-xEBFF), part of the library block at the top of the ROM, running in
place (ROM.md).  They use the library's calling convention, and the public
ones have fixed jump table entries ([LIBRARY.md](LIBRARY.md#jump-table)).
`placard_lib.asm` includes them.

The PS/2 driver (keyboard, mouse, the turns, `ps2_pause`) is
`src/scripts/placard_ps2.asm` at `PS2_CODE` (above).

- `src/scripts/io_devices.py`: models of the port PLD, the PS/2 receiver
  (clocked by the device models' clock edges), pads, SD card, mouse and
  PS/2 keyboard (scan code set 2) for `placard_sim.py`
  (`Cpu(..., io=SharedPort())`).  The port counts any moment both PS/2
  devices drive the shared DATA line; the mouse model counts the bytes
  it had to give up and the holds it saw.
- `src/scripts/test_io.py`: tests every driver against the models, and
  checks that each leaves the latch at `PS2_LSN` and keeps the /CS-high
  time under 50 us outside `sd_init`.  The PS/2 tests cover finding the
  keyboard (and finding it later), every key, the E0 and PC keys, the
  light, held keys and bursts, the mouse and keyboard together on the
  shared DATA line, `pad_read` with both devices, a mouse that starts
  late, `wait_frames_io` and `con_gets`.
- `src/scripts/io_demo.asm` (`build\io_demo.bat`): starts the SD card,
  shows the end of block 0, starts the mouse, echoes typed keys and prints
  pad buttons and mouse packets.  It waits with `wait_frames_io`.  On the
  Basys3, set SW15 before reset to use the mouse, or SW14 to use the USB
  keyboard as a PS/2 keyboard.

## FPGA model (Basys3)

`basys_top.vhd` has the port PLD (`port_pld.vhd`, rev 04, with the
register inside) and the PS/2 receiver (`ps2_pld.vhd`, rev 02), both
transcribed from the `.pld` files; the model's data bus mux follows
their output enables (x5200/x5201 from the port PLD, x5202/x5203 from
the receiver).  `ps2_key_matrix.vhd` went with the matrix.

| Placard | Basys3 |
|---|---|
| PS/2 mouse | The USB mouse on the board's PS/2 port, while SW15 = 1 (the register's /CS and DATA bits and the receiver's inhibit drive the PS/2 pins open drain) |
| PS/2 keyboard socket | The USB keyboard on the same port, while SW14 = 1 and SW15 = 0: register bit 4 holds its CLK and bit 3 DATA (open drain), so it goes through `placard_ps2.asm`.  Not tried on a Basys3 yet: its USB-to-PS/2 bridge has to answer the ED (lights) command for `port_init` to find it |
| RXCLK | The PS/2 port's clock line while either switch is on (one port, so no diode-OR), 0 with both off |
| SD card | PmodMicroSD on JB (top row): JB1 /CS, JB2 MOSI, JB3 MISO, JB4 SCK |
| Pads | SNES pads on JC (top row): JC1 CLOCK, JC2 LATCH, JC3 pad 1 DATA, JC4 pad 2 DATA, plus the Pmod's 3.3 V and GND |

The Basys3's USB port is one PS/2 port, so the model uses it as the mouse
or as the keyboard, picked by SW15 and SW14 (set them before reset: the
keyboard is looked for by `port_init`; both off = no PS/2 device).  The pads run from the Pmod's 3.3 V in the
model.  A SNES pad is CMOS shift registers and is generally run at 3.3 V by
FPGA projects, but that is not checked here.

## To check before building

- **Port PLD high level.**  The pads' CLOCK and LATCH need 3.5 V and the
  SD dividers need at least 3.2 V for the card's 2.06 V minimum high.  Measure
  the port PLD's SCK and MOSI highs (pins 20 and 19) with a pad and a card
  plugged in.  The ATF22V10C only promises 2.4 V at 4 mA.
- **RXCLK levels and edges.**  The diode-OR gives about 3.9 V high (4.7k
  pull-up, diode, 22k pull-down) against the PLD's 2.0 V; the edges are
  the slow PS/2 line edges into a clock input without hysteresis.  Check
  with a scope that one PS/2 clock gives one count (no double clocking);
  a smaller pull-down (10k) or a 100 pF to ground on RXCLK is the fix.
- **Rising-edge sampling.**  Check a few keyboards and mice hold DATA
  past the clock's rise (the spec gives 5 us); the receiver samples there.
- **Stock:** the regulator is not stock-checked yet.  The ATF22V10C-7PX is
  the same part as elsewhere in the design.

## Carried through

The keyboard removal and the receiver were carried through on 2026-10-25
(Justin: "modify everything except the layout"): schematic and symbols
(`gen_kicad_schematic.py`, `gen_kicad_symbols.py`, `gen_kicad_parts.py`;
the `kicad/keyboard/` project, `placard_keyboard.pdf` and the key switch
footprints are gone), BOM, kit pricing, block diagram, library
(`placard_ps2.asm`, `placard_io.asm`, `placard_menu.asm`, `menu_hook.py`,
the boot ROM's Esc check), simulator (`io_devices.py`, `test_io.py`,
`test_menu.py`, `test_dos.py`, `test_slots.py`, `test_bringup_sim.py`), FPGA
(`port_pld.vhd`, `ps2_pld.vhd`, `basys_top.vhd`) and BRINGUP.md.  The
board file `kicad/placard.kicad_pcb` is Justin's: he brings the new parts
in with Update PCB from Schematic (U37, U39, J1, RN2 go; U42, C42, D19
and R60 come; D1, D4, D5 change nets; the regulator's output capacitor is
C47 now, renamed in place).
