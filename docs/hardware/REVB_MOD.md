# Making a rev A board work like rev B

Date: 2026-11-17

A hand modification that gives a rev A main board (PLC-1001 rev A) the
160-read lines of rev B ([HIRES.md](../video/HIRES.md)): 160 across in 256
colors, 320 in 16 and 640 in 4.  Five PLD pins are bent out of their sockets,
five wires go in, and five PLDs get the rev B program.  No trace is cut and
nothing is soldered to the board, so it goes back to rev A by putting the
rev A chips back.

**Do this only on a board that already works as rev A**
([BRINGUP.md](BRINGUP.md)), so that anything wrong afterwards is the
modification.

Status: worked out from the difference between the rev A and rev B
netlists (the same seven nets as in [RELEASES.md](RELEASES.md)), and the
rev B PLDs pass their simulations.  It has not been tried on a board.

![The board with the five wires](revb_mod/revb_mod_board.png)

## What you need

| | |
|---|---|
| Five ATF22V10C-7PX | a second set for U13, U15, U16, U17 and U35, so the rev A chips stay as they are (bent pins do not go back in a programmer or a socket well) |
| Wire | thin insulated solid wire, 24 to 26 AWG (0.4 to 0.5 mm): it has to hold in a socket contact |
| Tools | soldering iron, fine pliers, multimeter |

## 1. Program the five rev B PLDs

Compile the sources in `src/pld/rev_b/` in WinCUPL (device g22v10) and
program one chip from each.  Program before bending any pin.  Label them
"B".

| Chip | Source | Revision | Checksum of the 2026-11-17 compile |
|---|---|---|---|
| U13 H counter | `ATF22V10_HCOUNT.pld` | 09 | A925 |
| U15 Sync | `ATF22V10_SYNC.pld` | 13 | EBEF |
| U16 Color decoder | `ATF22V10_COLORDECODER.pld` | 09 | 154A |
| U17 IR | `ATF22V10_IR.pld` | 02 | 9B03 |
| U35 Audio slot | `ATF22V10_AUDIO.pld` | 05 | C2AB |

All five go in together.  A rev A and a rev B chip do not work side by side.

## 2. Bend out five pins

On the new chips, bend these pins straight out sideways so they stay out of
the socket when the chip is pushed in:

| Chip | Pin | Rev A trace it leaves | What the pin is on rev B |
|---|---|---|---|
| U15 Sync | 4 | V4 | /P0 in |
| U15 Sync | 21 | /P0 | T2 out |
| U13 H counter | 6 | LC7 | T2 in |
| U35 Audio slot | 16 | I1 | T2 in |
| U35 Audio slot | 21 | /AC_SEL | LC7 in |

U16 and U17 keep all their pins.

## 3. Fit the chips and the wires

Power off.  Take out the rev A U13, U15, U16, U17 and U35 and keep them
together.  Fit the five rev B chips.  Each bent pin now sits over an empty
socket contact.

A wire end marked **pin** is soldered to the chip's pin (on the bent pins,
out at the tip; on U17 and U27, on the pin's shoulder above the socket).  A
wire end marked **hole** is stripped 4 mm and pushed into the empty socket
contact under a bent pin: that contact is the board's trace.

| Wire | Signal | From | To | Length |
|---|---|---|---|---|
| 1 | T2 | U15 pin 21 (pin) | U13 pin 6 (pin) | 30 mm |
| 2 | T2 | U13 pin 6 (pin) | U35 pin 16 (pin) | 16 mm |
| 3 | /P0 | U15 socket contact 21 (hole) | U15 pin 4 (pin) | 8 mm, across the chip |
| 4 | LC7 | U13 socket contact 6 (hole) | U35 pin 21 (pin) | 15 mm |
| 5 | /AC_SEL | U17 pin 22 (pin) | U27 pin 19 (pin) | 70 mm |

![Wires 1 to 4](revb_mod/revb_mod_video.png)

![Wire 5](revb_mod/revb_mod_acsel.png)

Notes:

- U15 pin 21 and U13 pin 6 each have a wire on the bent pin and another in
  the contact below it.  Keep the two apart: they are different signals.
- U17 pin 22 goes to nothing on a rev A board, so it stays in its socket.
- U27 keeps driving from the same pin 19 (/OE2).  Its old source, U35
  socket contact 21, is left empty.  Solder wire 5 with U27 out of its
  socket if the iron is hard to get in, and keep the joint high on the pin.
- Lengths are straight-line; add what the routing needs.  Keep wire 5 away
  from the crystal oscillator X1.

## 4. Check with the meter, power off

| Check | Reading |
|---|---|
| U15 pin 21 to U13 pin 6 to U35 pin 16 | 0 ohm (T2) |
| U15 pin 4 to U12 pin 17 | 0 ohm (/P0) |
| U35 pin 21 to U23 pin 19 | 0 ohm (LC7) |
| U17 pin 22 to U27 pin 19 | 0 ohm (/AC_SEL) |
| U15 pin 21 to U15 pin 4 | open (T2 and /P0 apart) |
| U13 pin 6 to U35 pin 21 | open (T2 and LC7 apart) |
| each bent pin to the pins next to it | open |

Measure on the chip pins, not on the wire ends, so the joints are in the
reading.

## 5. Power on

1. The monitor locks and the usual boot screen comes up.  VSYNC is on
   different lines than on rev A, so the picture may sit a little higher
   or lower until the monitor adjusts.
2. Programs that never set bit 7 of a mode byte look and run as on rev A.
3. A row with bit 7 and 2x or 4x repeat set is a 160-read row.  There is no
   test program for this yet; the emulators show what a screen should look
   like (`placard_sim.py --rev b`, or Board: rev B on the web page).

If the screen is wrong:

| What you see | Look at |
|---|---|
| No sync, or the monitor reports a wrong mode | wires 1 and 2 (T2 is part of the H counter's count), U13 or U15 still rev A |
| Picture of random RAM, the CPU does not start | wire 5 (/AC_SEL: U27 never drives, or always drives), U17 still rev A |
| Starts, then stops when the ROM/RAM map should change | wire 3 (/P0: the Sync PLD makes the map register's clock from it) |
| Rows with bit 7 look like normal rows, or every row is a 160-read row | wire 4 (LC7), U35 still rev A |

A rev A U16 left in by mistake is hard to see: only the five blended grays
are a little off on 160-read rows.

## What is different on a modified board

- Bit 7 of a mode byte is the 160-read line, not the blank line.  Programs
  that blank rows for speed (pi, Mandelbrot, the CPU test) show those rows
  as 160-read rows and lose the speed gain.
- Mode bytes x5A00-x5A1F must stay 0.
- The timing of the new nets has only been worked out on paper, with
  plenty of slack (16.5 ns used of 39.7 ns on the tightest), and not with
  these wires.  /AC_SEL gets faster, because it no longer passes through
  the audio slot PLD.

## Going back to rev A

Power off, pull wire ends 3 and 4 out of their socket contacts, take out the
five rev B chips with their wires (unsolder wire 5 at U27, or leave it
hanging on U17's chip), and put the five rev A chips back.

The pictures are drawn by `src/scripts/gen_revb_mod.py`, which also checks
the pin and wire tables against the net changes.
