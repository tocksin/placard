# Demo menu

The demo menu is a program on the SD card, `MENU.PLC` (`src/scripts/menu.masm`),
that the ROM's loader ([DOS.md](DOS.md)) runs at power-up when `BOOT.CFG`
names it.  It shows the demo programs and runs them in turn, asking the
loader to load each one from the card.

Date: 11/02/2026

The menu and the demos are files on the card.  The 32K ROM image
([ROM.md](../architecture/ROM.md#the-32k-image)) holds the loader, BASIC and the
library, and the DOS and the demos are files.

## What it does

| # | Program | File | Done when |
|---|---------|------|-----------|
| 1 | CPU test (`cpu_test.asm`) | `CPUTEST.PLC` | every test has run; the pass / fail grid stays 10 s |
| 2 | Pi (`pi_spigot.asm`) | `PI.PLC` | 1000 digits and the time are shown; they stay 10 s |
| 3 | Mandelbrot (`mandelbrot.asm`) | `MANDEL.PLC` | all four color depths are drawn (about 2 min 15 s on the board; its limit is 3 minutes) |
| 4 | Game of Life (`game_of_life.asm`) | `LIFE.PLC` | 1000 generations (about 4 min 40 s, so in turn it stops at 2 minutes) |
| 5 | Boing ball (`gen_boing.py`, [BOING.md](BOING.md)) | `BOING.PLC` | never: 2 minutes in turn |
| 6 | 3D ships (`gen_wire3d.py`, [WIRE3D.md](WIRE3D.md)) | `WIRE3D.PLC` | never: 2 minutes in turn |
| 7 | Ray caster (`gen_raycast.py --sd`) | `RAYCAST.PLC` | never: 2 minutes in turn |
| 8 | Runner, the side scroller (`gen_scroller.py --sd`) | `SCROLLER.PLC` (and `SCROLLER.OVL`) | never: 2 minutes in turn |
| 9 | Textured maze, the textured ray caster (`gen_raycast_tex.py --sd`) | `RAYTEX.PLC` (and `RAYTEX.OVL`) | never: 2 minutes in turn |
| 10 (key 0) | Video test, the text demo (`gen_text_demo_sd.py`) | `TEXT.PLC` | never: 2 minutes in turn |

- At power-up the programs run **in turn**, in the order above: each one
  until it is done or for 2 minutes (Mandelbrot 3, so it finishes), then
  the next, and after the last the first again.
- **Esc** in any program shows the menu (the older RAM programs can't
  reach the library's PS/2 driver, so each carries a small hook,
  `menu_hook.py`, that reads the PS/2 receiver once per frame and looks
  for Esc's make code).
- In the menu, **Up / Down** move the highlight and **Enter** (or Space)
  runs the highlighted program; **1-9** and **0** (program 10) run that program at once.
  **T** runs the system test, `TEST.PLC` ([TEST.md](TEST.md)), which is not
  in the list and never runs in turn; Esc in it brings the menu back with
  the highlight on program 1.  A
  program picked from the menu has no time limit: it runs until Esc (a
  program that finishes stays on its result).
- With **no key for 2 minutes** in the menu, it goes back to running them
  in turn, starting with the highlighted program.  The menu counts the
  seconds down on the screen.
- **Esc in the menu** goes to the DOS's file browser (the loader loads
  `DOS.PLC`).
- The highlighted program sits on a blue bar and the title on a gold band
  (row tints, mode byte bits 6:4, [VIDEO.md](../video/VIDEO.md#row-tint)).

The ray caster, the side scroller, the textured ray caster and the text
demo were ROM programs; their generators now also make card versions
(below).  The ROM versions still build each as its own 64K development
image (`build\text_demo.bat`, `build\raycast_tex.bat` and so on).

### The ray casters and the scroller on the card

- `RAYCAST.PLC` (`python gen_raycast.py --sd`, which writes
  `raycast_sd.asm` too) is the same code and tables moved into the RAM:
  x0100-x1EFF holds the code and most tables, and x2000-x28FF of the file
  holds the store runs, strings and table sources that main copies up to
  x4200-x4AFF (a library program loads at x0100-x3FFF only) before it
  builds its height and distance tables in x2000-x41FF as before.
- `SCROLLER.PLC` and `SCROLLER.OVL` (`python gen_scroller.py --sd`, which
  writes `scroller_sd.asm` too): the file holds the sprite blitter at
  x0100 (no copy needed) and the code, text and tables at x2000-x39FF.
  The 16 KB of unrolled background strips go into the video RAM the
  screen leaves free: with 4x line repeat and four 1x text lines, offsets
  x040-x17F of each 512-byte byte column are never shown (column 0 and
  offset x110, where the blitter puts off-screen bytes, are left out).
  `SCROLLER.OVL` is a straight image of the RAM from x6000, one sector a
  byte column, which main reads after clearing the screen; the strips run
  with map FF (the frame sets it before the bands, `draw_sprites` puts
  map 07 back).
- Both leave on Esc (`menu_poll`) and don't call `port_init` (the DOS has
  set up the port).  `test_raycast_sim.py --sd` and
  `test_scroller_sim.py --sd` boot each from a card image and check every
  frame against the models, as the ROM versions' tests do.
- `RAYTEX.PLC` and `RAYTEX.OVL` (`python gen_raycast_tex.py --sd`, which
  writes `raycast_tex_sd.asm` too) hold the 32 KB the ROM build keeps in
  program ROM.  The file (x1E00-x3FFF) has the code at x2000-x309F, the
  shading tables, the strings and the table sources that `build` reads to
  make the height and distance tables (x0100-x1DFF and x4200-x46FF, as in
  the ROM build).  After that, main reads `RAYTEX.OVL`, one sector to each
  page pair in a list: the other page tables (into x3C00-x41FF,
  x4800-x4BFF and x5400-x59FF, over the used table sources), then the
  textures, the hit tables and the compiled scalers into the video RAM the
  screen leaves free, as the scroller does.  Texel row t is the even page
  of byte column 48 + t, with the seven textures in 32-byte slots around
  the text rows' x20-x3F; the scalers fill x040-x17F of byte columns 0-46
  and x100-x17F of columns 48-79.  The program runs with map 3F and sets
  map FF only from the texture column copy through the scaler.  The
  scalers are the same as the ROM build's, so each view is the same, and
  `test_raycast_tex_sim.py --sd` boots it from a card and checks every
  view against the model.  Loading the OVL takes about 0.4 s.  T turns
  the textures off (each wall one flat color, its texture's commonest
  texel, still shaded) and on again, in the ROM build too.

### The text demo on the card

`TEXT.PLC` (`python gen_text_demo_sd.py`, which writes `text_demo_sd.asm`
too) is `text_demo.asm` unchanged but for its addresses and the RAM test.
The 60 pages the demo uses in ROM x6000-xB0FF move into RAM
x0100-x3AFF (pages that run on into the next stay together, x1F00 is
left out), and the RAM test covers only the free RAM: x3B00-x4CFF,
x5400-x59FF and x5C00-x5CFF (25 pages, 6.25 KB; the "RAM AREA" line says
so).  It leaves out the program itself, LIB_RAM, the FAT driver's
variables and sector buffer (x4D00-x4FFF, the DOS's files stay open), the
I/O window, the mode bytes, the menu block and the audio buffer.
`text_demo_sim.py --sd` boots it from a card and checks the screen, the
RAM test passes (and, with `--fault`, a failing bit) and Esc back to the
DOS.

## How a program is run

The menu writes the program's time limit and mode into the menu block,
its own name into `MB_PARENT` and "M" into `MB_MENU`, and jumps to the
ROM's `dos_run` vector (x800C) with the file's name.  The loader loads the
RAM image (RAM x0000-x49FF cleared, the file copied in, map FF, x0000
through `MB_GO`, as the old loader and the boot loader's RAM image copy
did).  When the program's hook comes back (through `MB_EXIT`,
with the reason in `MB_WHY`), the loader runs `MB_PARENT`, the menu, again;
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

They talk to the menu through the menu block at RAM x5D00, which the ROM's
loader sets up at power-up ("MNU", mode 1, the exit stubs), so a program started
from the browser also leaves on Esc:

| Address | Name | Use |
|---------|------|-----|
| x5D00-x5D02 | `MB_MAGIC` | "MNU" while the loader, the DOS or the menu is in charge |
| x5D03 | `MB_MODE` | 0 = in turn (time limit), 1 = picked (until Esc) |
| x5D04-x5D05 | `MB_LEFT` | frames left (in turn) |
| x5D06 | `MB_LAST` | last line read (RAM programs' hook) |
| x5D07-x5D08 | `MB_FRAME`, `MB_SYNC` | `menu_poll`'s frame count |
| x5D09 | `MB_WHY` | why the program stopped: 1 = Esc, 2 = time up or done |
| x5D0A | `MB_CUR` | scratch for the RAM programs' hook |
| x5D0B-x5D0C | `MB_HOLD` | frames a finished result stays (10 s) |
| x5D0D | `MB_PROG` | the program running |
| x5D0E-x5D0F | `MB_IA` | the loader's page 0 copy count |
| x5D10 | `MB_KB` | the RAM programs' hook: the keyboard's last byte |
| x5D11 | `MB_MENU` | "M" while a program the menu started runs |
| x5D12 | `MB_ERR` | why the last program could not run (the DOS shows it) |
| x5D13-x5D14 | `MB_SEL`, `MB_TOP` | the DOS's chosen entry while a program runs |
| x5D20-x5D27 | `MB_EXIT` | code: map 05, jump to `dos_back` (x8008) |
| x5D28-x5D2F | `MB_GO` | code: map FF, jump to RAM x0000 |
| x5D30-x5D3C | `MB_CHILD` | the loader: the program to run |
| x5D40-x5D4C | `MB_PARENT` | the program to run again when that one comes back |
| x5D50-x5D53 | `MB_DCLUS` | the current folder (programs are run from it) |
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

`sdcard\` in the repository holds `MENU.PLC`, the eight demos' files
(`gen_plc.py cpu_test.asm -o ..\..\sdcard\CPUTEST.PLC` and so on after a
change), `DOS.PLC` and `BOOT.CFG` (`MENU.PLC`): copy the folder onto a FAT16
or FAT32 card.  The ROM is `build\rom32.bat`.

`src/scripts/test_menu.py` runs the menu through the ROM's loader in
`placard_sim.py` with short times and checks the rotation order, that each
program's RAM is exactly its own file when it starts, Esc, the keys, a
picked program running past the time limit, the idle return and Esc to the
DOS (`--png` saves the menu screen).
