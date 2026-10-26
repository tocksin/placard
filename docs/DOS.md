# The DOS

The Placard DOS is a program on the SD card, `DOS.PLC` (`src/scripts/dos.masm`).
It shows the card's files, runs a program from the card, and saves and
loads memory as files.  The 32K ROM image ([ROM.md](ROM.md#the-32k-image))
holds the boot loader, the library, BASIC and a small loader
(`src/scripts/rom32.masm`) that starts the DOS and runs the programs.

Date: 10/26/2026

Until 2026-10-26 the DOS itself was in the ROM.  It moved to the card so
the ROM could hold BASIC, which is useful with no card at all.

## At power-up

1. The boot loader (mode 02) jumps to the ROM's loader at x8100 with map
   05.  The loader sets map **07** (RAM x0000-x5FFF, ROM x6000-xFFFF: the
   loader, BASIC and the library run in place), clears the screen and shows
   "PLACARD".
2. For about a second it watches the keyboard for **Esc**.
3. It mounts the card.  **No card** (or one it can't read): BASIC starts.
4. **Esc held**: `DOS.PLC` runs, so the browser comes up.
5. Otherwise it reads **BOOT.CFG** in the root folder: its first word is
   the name of the program to run, for example `MENU.PLC`, or `BASIC`.
   The browser's **B** key writes it, so does the `BOOT` command.  With no
   BOOT.CFG or an empty one, `DOS.PLC` runs.
6. When `DOS.PLC` is not in the root folder, BASIC starts.

When a program comes back (it jumps to x8008, or a RAM image goes through
`MB_EXIT`), the loader mounts the card again, goes back to the folder it was
in, and runs `MB_PARENT` if the program named one (the menu does).
Otherwise it loads `DOS.PLC` again from the root folder, as MS-DOS reloaded
COMMAND.COM.  It takes a fraction of a second.  The DOS comes back with the
same entry chosen (`MB_SEL`, `MB_TOP`).

A file that can't be run (not found, not a `.PLC` file, a folder, a read
error) brings the DOS back with the reason in `MB_ERR`, which it shows.  A
menu's `MB_PARENT` is dropped then, so the DOS comes up instead of the menu.

## The file browser

```
PLACARD DOS    folder \
  BOOT.CFG      10
  CPUTEST.PLC   14226
  GAMES         <DIR>
  MENU.PLC      1528
  ...
Up/Down move  Enter run/open  Bksp up  Del delete  B boot  R reread  Esc command
```

| Key | Does |
|-----|------|
| Up, Down | move the blue bar (a row tint, 8 mode bytes); the list scrolls by a screen of 50 |
| Enter | run the `.PLC` file, or open the folder; another file says "Not a program (.PLC)" |
| Backspace | the folder above |
| Del | delete the file (a folder gives error 13) |
| B | write BOOT.CFG = this file, so it runs at power-up (root folder only, where the boot reads it) |
| R | read the folder again (after changing the card) |
| Esc | a command line on row 57 |

Up to 128 entries of a folder are shown (name, size in bytes or `<DIR>`;
sizes of 64 KB or more show as `>64K`).  "." and ".." are left out.
Messages and errors appear on row 55: `Error n` with the FAT driver's
codes (1 end, 2 not found, 4-7 SD read / write, 8 not mounted, 9 no FAT
file system, 10 FAT12, 11 folder full, 12 no file open, 13 a folder, 14
card full).

### Commands

Esc opens a line (`con_gets`, 60 characters, Backspace works).  Words are
separated by spaces; case does not matter; numbers are hex.

| Command | Does |
|---------|------|
| `RUN name` | load and run `name` (a `.PLC` file) |
| `LOAD name hhhh` | load the file's bytes at address hhhh (whole sectors: up to 511 bytes past the end are written too).  x3000-x3FFF holds the DOS, so a start there is refused |
| `SAVE name hhhh hhhh [hhhh]` | save memory as a `.PLC` program: start, length, entry (= start when left out).  A start of 0000 makes a RAM image (type 1), anything else a library program (type 0) |
| `DEL name` | delete a file |
| `CD name` | open a folder (`CD ..` goes up) |
| `BOOT name` | write BOOT.CFG = `name` (root folder) |
| `DIR`, or nothing | back to the list |
| `BASIC` | start BASIC |

## Program files (.PLC)

A program file starts with a 16-byte header, then the program's bytes from
its load address to its last byte (gaps as 00):

| Bytes | Holds |
|-------|-------|
| 0-2 | `PLC` |
| 3 | type: 0 = library program, 1 = RAM image |
| 4-5 | load address, low byte first |
| 6-7 | length of the bytes that follow, low byte first |
| 8-9 | entry address (type 0; a RAM image starts at x0000) |
| 10-15 | 0 |

`src/scripts/gen_plc.py prog.asm -o NAME.PLC` makes one from an assembled
program; the repository's `sdcard/` folder holds the demos' files and
`BOOT.CFG` (copy the folder onto a FAT16 or FAT32 card).

The ROM's loader loads them (the DOS hands it the name through
`dos_run`), because a program loads over the DOS in the RAM.

**Type 0, a library program**, is a normal Placard program assembled to run
in RAM at x0100-x3FFF (it includes `placard_lib.asm` and calls the library
in the ROM).  The loader copies the file to its load address, puts `LIB_RAM`
back (a program may span x1F00-x1FFF), sets SP = FF, map 07 and
`MAP_SHADOW` = 07, and jumps to the entry.  The program keeps the zero
page map and the menu block x5D00-x5D6F (its `MB_DCLUS` is the folder);
the loader mounts the card again when the program calls `dos_run` or comes
back.  It comes back with

```
    ld   0x80, y                ; dos_back
    jmp  0x08
```

**Type 1, a RAM image**, is one of the older demos written to run from
RAM x0000 with map FF (CPU test, pi, Mandelbrot, Game of Life).  The loader
clears RAM x0100-x49FF, copies the image in (page 0 last, with no zero page
of its own, as the boot loader's RAM image copy did), lets the keyboard
send (the image's hook, `menu_hook.py`, reads the PS/2 receiver itself)
and starts it through `MB_GO` (x5D28: map FF, jump x0000).  Its hook comes
back through `MB_EXIT` (x5D20: map 05, jump x8008) on Esc.

`DOS.PLC` is a type 0 program with its load address at x3000, so `SAVE`
and `LOAD` can work on a program at x0100-x2FFF.

## DOS vectors

The first page of the 32K image, x8000-x80FF, is fixed, so a program can
use these whatever the ROM's code looks like later.  They are in the ROM
(`rom32.masm`), so they work with or without the DOS in the RAM:

| Address | Name | Use |
|---------|------|-----|
| x8000 | reset | nop and the jump to the boot loader (a 32K cartridge shows it at x0000) |
| x8008 | `dos_back` | a program is done: jump here (map 05 or 07) |
| x800C | `dos_run` | R1:R0 = "NAME.PLC", 0 in RAM, in the current folder: the loader loads and runs it (it never returns; it runs `MB_PARENT` when the program comes back) |
| x8010 | `fs_create` | the FAT writer (`placard_fsw.masm`): CALL like a library routine, with LINK set (`ld 0x80, y / jmp 0x10`) |
| x8014 | `fs_write` | |
| x8018 | `fs_close` | |
| x801C | `fs_delete` | |
| x8020 | `fs_save` | |
| x8024 | `basic` | start BASIC (a jump; it never returns) |

The reader (`fs_mount`, `fs_open`, `fs_next`, `fs_read`, `fs_load`) is in
the library as before ([LIBRARY.md](LIBRARY.md#sd-card-files-fat16-and-fat32)).

### The FAT writer

`placard_fsw.masm` (xB000-xBFFF of the image) writes FAT16 and FAT32 cards:

| Routine | In | Out |
|---------|----|-----|
| `fs_create` | R1:R0 = name | AC = 0: an empty file exists and is open for writing (a file of that name is deleted first) |
| `fs_write` | R5:R4 = 512 bytes | AC = 0 and R5:R4 + 512; 12 no file open, 14 card full |
| `fs_close` | R3:R0 = the size in bytes | AC = 0: the size and first cluster are in the folder entry |
| `fs_delete` | R1:R0 = name | AC = 0, 2 not found, 13 a folder |
| `fs_save` | R1:R0 = name, R5:R4 = first byte, R3:R2 = length | create + write + close; when it fails the file is left empty |

Between `fs_create` and `fs_close` only `fs_write` may be called.  Clusters
are taken from the first free FAT entry after the file's last one, every
FAT is kept up to date after each cluster, and the folder entry is written
at create and at close, so a card pulled out early holds an empty file,
not a broken one.  Folders are not made or grown (error 11 when full);
FAT32's free-cluster count is left to the PC.  `test_fsw.py` checks the
files with `fsck.fat` and `mtools`.

## Memory the DOS uses

| Where | Use |
|-------|-----|
| zero page x20-x5F | the DOS's variables (the ROM's loader uses x20-x2B between programs) |
| x3000-x3FFF | `DOS.PLC` itself |
| x4000-x47FF | `DOS_DIR`: the folder read, 128 entries × 16 bytes (name 11, attributes, size 4) |
| x4800 | `DOS_LINE`: the command line |
| x4D00-x4FFF | the FAT driver's variables and sector buffer |
| x5400-x57FF | `DOS_BUF`: BOOT.CFG, the header of a SAVE; the loader's sectors while loading (`DOS_BUF0` x5600: a RAM image's page 0) |
| x5D00-x5D6F | the menu block ([MENU.md](MENU.md#the-hook)): "MNU", mode 1, `MB_ERR` x5D12, `MB_SEL` x5D13, `MB_TOP` x5D14, `MB_EXIT`, `MB_GO`, `MB_CHILD` x5D30, `MB_PARENT` x5D40, `MB_DCLUS` x5D50 (the folder), `MB_FNAME` x5D60 |

## Building and testing

```
cd src\scripts
python asm_expand.py dos.masm                       dos.asm (committed)
python gen_plc.py dos.asm -o ..\..\sdcard\DOS.PLC    the card's DOS
python asm_expand.py rom32.masm                     rom32.asm (committed)
build\rom32.bat                     assembles rom32.asm, builds the FPGA with the 32K
                                    image in both halves of rom.mem, writes
                                    src\hdl\rom_32k.bin for the EEPROM
python gen_plc.py prog.asm -o X.PLC a program file for the card
python test_dos.py                  the ROM and DOS.PLC in the simulator with a card image
python test_menu.py                 the demo menu
```

`test_dos.py` makes a FAT16 card in Python (`sdimage.py`), boots the ROM
with a PS/2 keyboard model and checks: BOOT.CFG runs a program that asks
for another through `dos_run` and comes back through `dos_back`, then
`DOS.PLC` loads; the browser's screen (read back through the font);
folders, and coming back to the folder after a program; "Not a program";
a RAM image's RAM is exactly its file; Del and B; SAVE, LOAD (and LOAD over
the DOS refused), DEL, CD, BASIC on the command line; Esc held at
power-up; no card, and a card with no `DOS.PLC` (BASIC); BOOT.CFG naming
BASIC; BOOT.CFG naming a missing file.

## Not done yet

- The text demo and the ray caster run in place from ROM x6000-xBFFF and
  can't yet be loaded into the 16 KB of program RAM (x0100-x3FFF): the ray
  caster alone needs 7 KB of code and 10 KB of tables; the text demo 11 KB.
  They stay buildable as 64K development images (`build\text_demo.bat`,
  `build\raycast.bat`).  Making them SD programs means reworking them for
  RAM x0100-x3FFF.
- BASIC in the ROM: only a placeholder screen so far (Esc goes to the
  DOS); the plan is waiting for review.
- A monitor, now planned as a program on the card (`MON.PLC`).
- Making folders, renaming, copying.
