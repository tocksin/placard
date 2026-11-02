# System test

`TEST.PLC` (`src/scripts/test.masm`) is a program on the SD card that
checks the parts of the machine a program can reach and shows one line
for each.  It takes no ROM: the 32K image is unchanged.  **T** in the demo
menu runs it ([MENU.md](MENU.md)), or Enter on it in the DOS's browser, or
`BOOT.CFG` = `TEST.PLC` to run it at every power-up ([DOS.md](DOS.md)).

Date: 11/02/2026

It needs a machine that can boot and read the card.  A board that can't
run that far is checked with the bring-up ROM instead
([BRINGUP.md](../hardware/BRINGUP.md)), which also tests the CPU, the map
register and the ROM chips.

## The screen

```
  PLACARD SYSTEM TEST

  RAM         OK, 2 passes
              x0C00-x1EFF x2000-x4CFF x5400-x59FF x5C00-x5CFF x6000-xFFFF

  Card slots  1: --  2: 4C  3: --  4: --

  Keyboard    found

  Mouse       found

  SD card     ready, SDHC, FAT mounted

  Sound       two beeps: A 440 Hz, then A 880 Hz


  Space: test again   B: beep again   Esc: back
```

| Line | What it does | What it shows |
|------|--------------|---------------|
| RAM | Two passes over the free RAM of both chips: every byte is written with its address (low byte xor high byte, then the complement on the second pass), then all of it is read back.  A stuck data bit fails one of the passes; an address line that is stuck or shorted makes two addresses one cell, which the read-back finds. | `OK, 2 passes`, or `FAILED, errors: n, first xAAAA wrote ww read rr, bad bits bb` (n stops at 65535; bad bits is every bit that was ever wrong) |
| Card slots | `slot_id` for slots 1-4 | the card ID of a card with a "PLC" header; `--` for an empty slot or a card without one (both read FF) |
| Keyboard | Reads `KBD_FLAGS` bit 1, which the library sets when a PS/2 keyboard answers ED (set lights) or sends any byte.  The line is kept up to date, so a keyboard plugged in later (it sends AA when its self test is done) shows. | `found` or `none` |
| Mouse | Sends F5 (disable reporting, harmless) to the mouse socket: a device there acknowledges with FA.  A mouse that a program already started reads as running. | `found`, `found (running)`, `none` (no clock from the socket) or `wrong answer` |
| SD card | `sd_init` and `fs_mount` again | `ready`, `, SDHC` for a block-addressed card, `, FAT mounted`, or the error code ([LIBRARY.md](LIBRARY.md)) |
| Sound | Two beeps (`snd_beep`), A 440 Hz and 20 frames later A 880 Hz | listen for them |

PS/2 has no pin that says a device is plugged in.  The only test is
whether something answers, so a device that is unplugged after it
answered still shows until the test runs again.  A keyboard in the mouse
socket answers F5 too and shows as a mouse.

## The RAM test

It runs with the map at FF (every section RAM) to read the video RAM,
from the program's own code at x0100, which is RAM in either map, and
calls nothing until the map is back.  The screen shows noise while the
video RAM is tested.  The test and the redraw take about 0.3 s in the
simulator.

It tests x0C00-x1EFF, x2000-x4CFF (the DOS's x3000-x3FFF too: the loader
reads `DOS.PLC` again afterwards), x5400-x59FF, x5C00-x5CFF and
x6000-xFFFF, which is 231 pages, 57.75 KB.  It leaves out:

| RAM | Why |
|-----|-----|
| x0000-x00FF | zero page and the stack |
| x0100-x0BFF | this program |
| x1F00-x1FFF | `LIB_RAM` |
| x4D00-x4FFF | the SD, FAT and PS/2 variables and the sector buffer |
| x5000-x53FF | the I/O window (no RAM read there) |
| x5A00-x5BFF | the mode bytes |
| x5D00-x5DF2 | the menu block |
| x5DF3-x5FFF | the audio buffer |

## Building and the simulator

```
python3 asm_expand.py test.masm                 test.asm
python3 gen_plc.py test.asm -o ../../sdcard/TEST.PLC
python3 test_systest.py                         runs it in placard_sim
```

`test_systest.py` boots the 32K ROM from a card with `BOOT.CFG` =
`TEST.PLC` on a good machine (a card with ID 4C in slot 2, a keyboard
and a mouse) and checks every line, then Space and Esc.  It then boots a
machine with no mouse and one RAM cell (x9123) with bit 3 stuck high, and
checks for `FAILED, errors: 1, first x9123 wrote B2 read BA, bad bits 08`
and `none` for the mouse.  `test_menu.py` checks that T in the menu runs
it.
