# The DOS

The Placard DOS is the program in the 32K ROM image (`src/scripts/dos.masm`,
[ROM.md](ROM.md#the-32k-image)).  It shows the SD card's files, runs a
program from the card, and saves and loads memory as files.  Programs come
from the card; the ROM holds only the DOS, the library and the boot loader
(and, later, a monitor).

Date: 10/26/2026

## At power-up

1. The boot loader (mode 02) jumps to the DOS at x8100 with map 05.  The DOS
   sets map **07** (RAM x0000-x5FFF, ROM x6000-xFFFF: the DOS at x8000 and
   the library at xC000 run in place), clears the screen and shows
   "PLACARD DOS".
2. For about a second it watches the keyboard.  **Esc held** (or pressed)
   goes straight to the file browser.
3. Otherwise it mounts the card and reads **BOOT.CFG** in the root folder:
   its first word is the name of the program to run, for example
   `MENU.PLC`.  The browser's **B** key writes it, so does the `BOOT`
   command.  With no card, no BOOT.CFG or an empty one, the browser comes up.
4. When the program comes back (it jumps to the DOS vector x8008, or a RAM
   image goes through `MB_EXIT`), the DOS starts over: it mounts the card
   again, goes back to the folder it was in, runs `MB_PARENT` if the program
   named one (the menu does), and otherwise shows the browser.

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
| `LOAD name hhhh` | load the file's bytes at address hhhh (whole sectors: up to 511 bytes past the end are written too) |
| `SAVE name hhhh hhhh [hhhh]` | save memory as a `.PLC` program: start, length, entry (= start when left out).  A start of 0000 makes a RAM image (type 1), anything else a library program (type 0) |
| `DEL name` | delete a file |
| `CD name` | open a folder (`CD ..` goes up) |
| `BOOT name` | write BOOT.CFG = `name` (root folder) |
| `DIR`, or nothing | back to the list |

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

**Type 0, a library program**, is a normal Placard program assembled to run
in RAM at x0100-x3FFF (it includes `placard_lib.asm` and calls the library
in the ROM).  The DOS copies the file to its load address, puts `LIB_RAM`
back (a program may span x1F00-x1FFF), sets SP = FF, map 07 and
`MAP_SHADOW` = 07, and jumps to the entry.  The program keeps the zero
page map, x4D00-x4FFF (the FAT driver's state) and the menu block
x5D00-x5D6F if it wants the DOS's folder and `dos_run` to work; the DOS
mounts the card again when it comes back anyway.  It comes back with

```
    ld   0x80, y                ; dos_back
    jmp  0x08
```

**Type 1, a RAM image**, is one of the older demos written to run from
RAM x0000 with map FF (CPU test, pi, Mandelbrot, Game of Life).  The DOS
clears RAM x0100-x49FF, copies the image in (page 0 last, with no zero page
of its own, as the boot loader's RAM image copy did), lets the keyboard
send (the image's hook, `menu_hook.py`, reads the PS/2 receiver itself)
and starts it through `MB_GO` (x5D28: map FF, jump x0000).  Its hook comes
back through `MB_EXIT` (x5D20: map 05, jump x8008) on Esc.

## DOS vectors

The first page of the image, x8000-x80FF, is fixed, so a program can use
these whatever the DOS's code looks like later:

| Address | Name | Use |
|---------|------|-----|
| x8000 | reset | nop and the jump to the boot loader (a 32K cartridge shows it at x0000) |
| x8008 | `dos_back` | a program is done: jump here (map 05 or 07) |
| x800C | `dos_run` | R1:R0 = "NAME.PLC", 0 in RAM: the DOS loads and runs it (it never returns; the DOS runs `MB_PARENT` when the program comes back) |
| x8010 | `fs_create` | the FAT writer (`placard_fsw.masm`): CALL like a library routine, with LINK set (`ld 0x80, y / jmp 0x10`) |
| x8014 | `fs_write` | |
| x8018 | `fs_close` | |
| x801C | `fs_delete` | |
| x8020 | `fs_save` | |

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
| zero page x20-x5F | the DOS's variables (a program may use them) |
| x4000-x47FF | `DOS_DIR`: the folder read, 128 entries × 16 bytes (name 11, attributes, size 4) |
| x4800 | `DOS_LINE`: the command line |
| x4D00-x4FFF | the FAT driver's variables and sector buffer |
| x5400-x57FF | `DOS_BUF`, `DOS_BUF0`: sectors while loading and saving, BOOT.CFG, a RAM image's page 0 |
| x5D00-x5D6F | the menu block ([MENU.md](MENU.md#the-hook)): "MNU", mode 1, `MB_EXIT`, `MB_GO`, `MB_CHILD` x5D30, `MB_PARENT` x5D40, `MB_DCLUS` x5D50 (the folder while a program runs), `MB_FNAME` x5D60 |

## Building and testing

```
cd src\scripts
python asm_expand.py dos.masm        dos.asm (committed; no Python needed to build)
build\dos.bat                        assembles dos.asm, builds the FPGA with the 32K
                                     image in both halves of rom.mem, writes
                                     src\hdl\rom_32k.bin for the EEPROM
python gen_plc.py prog.asm -o X.PLC  a program file for the card
python test_dos.py                   the DOS in the simulator with a card image
python test_menu.py                  the demo menu through the DOS
```

`test_dos.py` makes a FAT16 card in Python (`sdimage.py`), boots the image
with a PS/2 keyboard model and checks: BOOT.CFG runs a program that asks
for another through `dos_run` and comes back through `dos_back`; the
browser's screen (read back through the font); folders; "Not a program";
a RAM image's RAM is exactly its file; Del and B; SAVE, LOAD, DEL, CD on
the command line; Esc held at power-up; no card.

## Not done yet

- The text demo and the ray caster run in place from ROM x6000-xBFFF and
  can't yet be loaded into the 16 KB of program RAM (x0100-x3FFF): the ray
  caster alone needs 7 KB of code and 10 KB of tables; the text demo 11 KB.
  They stay buildable as 64K development images (`build\text_demo.bat`,
  `build\raycast.bat`).  Making them SD programs means reworking them for
  RAM x0100-x3FFF.
- A monitor at xA000-xAFFF ([SOFTWARE_ROADMAP.md](SOFTWARE_ROADMAP.md)).
- Making folders, renaming, copying.
