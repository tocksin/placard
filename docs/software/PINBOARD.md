# Pinboard

Pinboard is a windowed desktop for the Placard: a program on the SD card,
`PINBOARD.PLC` (`src/scripts/pinboard.masm` and `pinboard.vm`, built by
`gen_pinboard.py`).  Its windows are **cards** pinned on a board.  A card
shows the card's files and runs programs from it; others are a clock and
a calculator.  It works with the PS/2 mouse, the keyboard, or both.

Date: 11/16/2026

![Pinboard in the emulator: the Files, Clock, Calc and About cards](../../reference/pinboard.png)

The board, the cards, the Files card, the Clock, the calculator and the
launcher are here.  A text editor comes next.

## Starting it

Run `PINBOARD.PLC` from the DOS's file browser, or make it the program the
machine starts with: choose it in the DOS and press **B**, which writes
`BOOT.CFG` ([DOS.md](DOS.md#at-power-up)).

Plug in the mouse before turning the machine on.  With no mouse there is
no pointer and everything is done with the keys.

## The board

The screen is 80 x 60 character cells of the 640 x 480, 1 bpp mode.  The
woven board fills the top 57 rows and the **rail** the bottom three, in
blue.  The rail holds the launcher's button, a tab for every card that is
up (the front one in white) and the time.

| Mouse | Does |
|-------|------|
| click on a card | brings it to the front |
| drag a card's title | moves the card: its outline follows the pointer |
| click the pin at the left of a title | takes the card down |
| click a card's tab on the rail | brings it to the front |
| click `Pinboard` on the rail | opens the launcher |

| Key | Does |
|-----|------|
| Tab | the next card to the front |
| Ctrl+W | takes the front card down |
| Esc | the launcher: Up, Down and Enter, Esc closes it |
| any other | goes to the front card |

The launcher puts up Files, Clock, Calculator or About, starts BASIC, or
goes back to the DOS.

## Files

The Files card lists the folder: a picture for a folder, a program
(`.PLC`) or another file, the name, and the size.  The line under the
title names the folder; the last line counts the entries or says why
something did not work.

| Key | Mouse | Does |
|-----|-------|------|
| Up, Down | click a row | moves the bar; the list scrolls |
| Enter | click the chosen row again | runs the program, or opens the folder; another file says "Not a program (.PLC)" |
| Backspace | click the arrow by the folder's name | the folder above |
| | click the scroll bar, above or below its middle | scrolls 5 rows |

A program runs as it does from the DOS, with the whole machine.  When it
ends (Esc in most), Pinboard comes back with the same folder entry chosen
and the clock's time kept.

- A program started from a folder below the root comes back to the DOS,
  not to Pinboard: the loader looks for the program to come back to in the
  folder it is in.
- A program that can't be loaded brings up the DOS, which says why.
- A folder shows its first 96 entries.

## Clock

The machine has no clock chip, so the Clock counts frames (59.94 a
second) from 00:00:00 when Pinboard starts, and you set it: **H+** and
**M+** (keys H and M) add an hour and a minute, **:00** (S or 0) clears the
seconds.  The rail shows the hours and minutes.  The time is kept while a
program runs, but not counted.

## Calc

The calculator works in whole numbers up to 2,147,483,647 either side of
0.  Click its buttons or type:

| Key | Button | Does |
|-----|--------|------|
| 0-9 | 0-9, 00 | the number, up to 9 digits |
| + - * / | the same | add, subtract, multiply, divide (the whole part) |
| % or M | mod | what is left over from a division, with the sign of the first number |
| = or Enter | = | the answer |
| N | +- | changes the sign |
| Backspace | <- | takes the last digit back |
| C or Del | C | clears everything |

The operation that is waiting for its second number shows at the left of
the display.  An answer that is too big, or a division by 0, shows
"Error" until C.  The numbers are kept as a sign and 32 bits, and the
arithmetic is done 16 bits at a time in the bytecode: a multiply or a
divide is 32 shift and add steps, about a twentieth of a second.

## How it is built

Pinboard is written in the Forth-like language of BASIC's interpreter
([BASIC.md](BASIC.md)): `pinboard.vm` compiles (`vmc.py`) to bytecode for
a stack machine, a copy of BASIC's inner interpreter that `pinboard.masm`
carries so it does not depend on where BASIC is in the ROM.  A call in the
bytecode is two bytes; `vmc.py`'s `RAMCALLS` sets bit 7 of the first so
that addresses in RAM, x0100-x3FFF, can't be taken for a primitive's
number.  The desktop is about 7 KB of bytecode and 1.4 KB of machine
code, so over a third of the room of a `.PLC` program is still free.

Machine code does what has to be quick:

| Primitive | Does |
|-----------|------|
| `EMIT`, `GTYPE`, `HFILL` | draw characters: 8 stores a cell, straight into the video RAM, clipped to the card being painted |
| `INVC` | turns a cell over (the outline of a card being dragged) |
| `PTR` | hides or shows the pointer: it saves the 2 x 12 bytes under it |
| `POLL` | waits for the next frame, reads the keyboard and the mouse, moves the pointer |

- **The font** is Pinboard's own table (`gen_pinboard.py`): the library's
  characters at 20-7E, the board, the card edges, the pin, the arrows and
  the file pictures at 01-11, and all of them again in inverse video at
  80-FF, which is what a white card with black ink uses.
- **Painting** goes back to front: every card is drawn whole, clipped to
  the part that changed.  A full screen takes about 10 frames, a moved bar
  2.  There is no saved copy of what a card covers.
- **The pointer** is drawn by the program: it is taken off before
  anything is drawn and put back after.
- **Long repaints** count the frames (`frame_poll`) and take the mouse's
  bytes as they come (`ps2_poll`) once per string, so the clock stays right
  and a click during a repaint is not lost.
- **Leaving** for a program, BASIC or the DOS waits until every key is up,
  so the key's release does not land in the next program.

| Memory | Holds |
|--------|-------|
| zero page x20-x52 | the interpreter, drawing and pointer state |
| zero page x90-x9F | the desktop's variables (the sound driver's bytes: Pinboard makes no sound) |
| x0100-x35FF | machine code and bytecode |
| x3600-x37FF | the pointer, shifted 0-7 pixels: mask and picture |
| x3800-x3FFF | the font, a page per pixel row |
| x4800-x48FF | the interpreter's return stack |
| x4900-x49FF | the bytes under the pointer, the cards' table and order, the clock, the calculator's numbers |
| x5400-x59FF | the folder: 96 entries of 16 bytes |
| x5D15-x5D17 | the time, kept in the menu block while a program runs |

A card is a row of five tables in `pinboard.vm`: its title, its first
place and size (`WINIT`), and the words that draw it (`DRAWTAB`), take a
key (`KEYTAB`) and take a click (`CLICKTAB`).

## Testing

`src/scripts/test_pinboard.py` runs Pinboard in the emulator's core
(`web/placard_emu.js`, under node, through `pinboard_emu.py`) with the
ROM, a card image of `sdcard/`, a PS/2 keyboard and a mouse, and reads the
screen back as characters: power-up, the keys, the pointer, the launcher,
setting the clock, dragging, Tab, the pin, Ctrl+W, running `PI.PLC` and
coming back, running with no mouse, going back to the DOS, and the
calculator's sums by clicks and by keys.
`--png folder` saves each step's screen.
