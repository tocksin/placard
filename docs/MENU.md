# Demo menu

The demo menu is a program on the SD card, `MENU.PLC` (`src/scripts/menu.masm`),
that the DOS ([DOS.md](DOS.md)) runs at power-up when `BOOT.CFG` names it.
It shows the demo programs and runs them in turn, asking the DOS to load
each one from the card.

Date: 10/26/2026

Until 2026-10-26 the menu and six demos were built into one 64 KB ROM
(`gen_menu_rom.py`, `build\menu.bat`).  The 32K ROM image replaced that
([ROM.md](ROM.md#the-32k-image)): the ROM holds the DOS and the library,
and the demos are files.

## What it does

| # | Program | File | Done when |
|---|---------|------|-----------|
| 1 | CPU test (`cpu_test.asm`) | `CPUTEST.PLC` | every test has run; the pass / fail grid stays 10 s |
| 2 | Pi (`pi_spigot.asm`) | `PI.PLC` | 1000 digits and the time are shown; they stay 10 s |
| 3 | Mandelbrot (`mandelbrot.asm`) | `MANDEL.PLC` | all four color depths are drawn (about 2 min 15 s on the board; its limit is 3 minutes) |
| 4 | Game of Life (`game_of_life.asm`) | `LIFE.PLC` | 1000 generations (about 4 min 40 s, so in turn it stops at 2 minutes) |

- At power-up the programs run **in turn**, in the order above: each one
  until it is done or for 2 minutes (Mandelbrot 3, so it finishes), then
  the next, and after the last the first again.
- **Esc** in any program shows the menu (the older RAM programs can't
  reach the library's PS/2 driver, so each carries a small hook,
  `menu_hook.py`, that reads the PS/2 receiver once per frame and looks
  for Esc's make code).
- In the menu, **Up / Down** move the highlight and **Enter** (or Space)
  runs the highlighted program; **1-4** run that program at once.  A
  program picked from the menu has no time limit: it runs until Esc (a
  program that finishes stays on its result).
- With **no key for 2 minutes** in the menu, it goes back to running them
  in turn, starting with the highlighted program.  The menu counts the
  seconds down on the screen.
- **Esc in the menu** goes to the DOS's file browser.
- The highlighted program sits on a blue bar and the title on a gold band
  (row tints, mode byte bits 6:4, [VIDEO.md](VIDEO.md#row-tint)).

The text demo, the ray caster and the side scroller are not in the menu:
they run in place from ROM x6000-xBFFF and don't fit the 16 KB of program
RAM yet ([DOS.md](DOS.md#not-done-yet)).  `build\text_demo.bat` and the
others still build each as its own 64K development image.

## How a program is run

The menu writes the program's time limit and mode into the menu block,
its own name into `MB_PARENT` and "M" into `MB_MENU`, and jumps to the
DOS's `dos_run` vector (x800C) with the file's name.  The DOS loads the
RAM image (RAM x0000-x49FF cleared, the file copied in, map FF, x0000
through `MB_GO`, as the old loader and the boot loader's RAM image copy
did).  When the program's hook comes back to the DOS (through `MB_EXIT`,
with the reason in `MB_WHY`), the DOS runs `MB_PARENT`, the menu, again;
`MB_MENU` tells the menu it is being run again rather than started from
the browser, and `MB_WHY` whether to run the next program (time up or
done) or show the menu (Esc).

## The hook

There are no interrupts, so each program gives the menu a chance about
once per frame:

- a library program calls the library's `menu_poll` (`placard_menu.asm`,
  jump table entry 54);
- a RAM program (map FF, no library) carries its own copy of the same
  check, written by `menu_hook.py`: `hk_poll` every frame, `hk_hold` when
  it starts showing a final result, `hk_done` when a run is complete.

They talk to the menu through the menu block at RAM x5D00, which the DOS
sets up at power-up ("MNU", mode 1, the exit stubs), so a program started
from the browser also leaves on Esc:

| Address | Name | Use |
|---------|------|-----|
| x5D00-x5D02 | `MB_MAGIC` | "MNU" while the DOS or the menu is in charge |
| x5D03 | `MB_MODE` | 0 = in turn (time limit), 1 = picked (until Esc) |
| x5D04-x5D05 | `MB_LEFT` | frames left (in turn) |
| x5D06 | `MB_LAST` | last line read (RAM programs' hook) |
| x5D07-x5D08 | `MB_FRAME`, `MB_SYNC` | `menu_poll`'s frame count |
| x5D09 | `MB_WHY` | why the program stopped: 1 = Esc, 2 = time up or done |
| x5D0A | `MB_CUR` | scratch for the RAM programs' hook |
| x5D0B-x5D0C | `MB_HOLD` | frames a finished result stays (10 s) |
| x5D0D | `MB_PROG` | the program running |
| x5D0E-x5D0F | `MB_IA` | the DOS's page 0 copy count |
| x5D10 | `MB_KB` | the RAM programs' hook: the keyboard's last byte |
| x5D11 | `MB_MENU` | "M" while a program the menu started runs |
| x5D20-x5D27 | `MB_EXIT` | code: map 05, jump to the DOS (x8008) |
| x5D28-x5D2F | `MB_GO` | code: map FF, jump to RAM x0000 |
| x5D30-x5D3C | `MB_CHILD` | the DOS: the program to run |
| x5D40-x5D4C | `MB_PARENT` | the program to run again when that one comes back |
| x5D50-x5D53 | `MB_DCLUS` | the DOS's current folder while a program runs |
| x5D60-x5D6C | `MB_FNAME` | the current folder's name (the DOS's title) |

Without the block's "MNU" every hook returns at once, so each program
still builds and runs on its own (`build\<program>.bat`) exactly as
before.  `menu_poll` costs 15 clocks a call then.

## Building

```
cd src\scripts
python asm_expand.py menu.masm                   menu.asm
python gen_plc.py menu.asm -o ..\..\sdcard\MENU.PLC
```

`sdcard\` in the repository holds `MENU.PLC`, the four demos' files
(`gen_plc.py cpu_test.asm -o ..\..\sdcard\CPUTEST.PLC` and so on after a
change) and `BOOT.CFG` (`MENU.PLC`): copy the folder onto a FAT16 or FAT32
card.  The ROM is the DOS, `build\dos.bat`.

`src/scripts/test_menu.py` runs the menu through the DOS in
`placard_sim.py` with short times and checks the rotation order, that each
RAM program's RAM is exactly its own file when it starts, Esc, the keys, a
picked program running past the time limit, the idle return and Esc to the
DOS (`--png` saves the menu screen).
