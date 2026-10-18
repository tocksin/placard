# Feature plan: software, and what was cut

The I/O hardware from this plan is designed: the shared port with the
keyboard, SNES pads, SD card and PS/2 mouse is in [IO.md](IO.md), and the
expansion slots and ROM cartridge slot are in [EXPANSION.md](EXPANSION.md).
What is left here is the software to write on top of it, and the hardware
that was cut to keep the chip count down.

## Software

Software that runs on the Placard itself.  It all builds on the standard
library (LIBRARY.md: calling convention, software stack, text console at
x3000-x3FFF, I/O drivers at x2000-x2FFF) and the ROM layout in ROM.md.
Free ROM for it today is x0004-x1FFF (8 KB) plus x4000-x4FFF and
x5400-x5FFF; free RAM is about 14 KB (x0100-x1FFF, x4000-x4FFF and the
small pieces in section 2, while section 1 reads the ROM), plus up to
20-30 KB of video RAM when rows use 2x or 4x line repeat.

### Drivers

The keyboard, pad, SD card (raw 512-byte blocks) and mouse drivers are
written: `placard_io.asm` at x2000-x2FFF ([IO.md](IO.md)).  Still to write:

- **FAT filesystem:** FAT16/FAT32 read first (open a file, read it, list a
  directory), write later.  This is what lets a PC put files on the card.
  Raw-block storage works now and stays as a fallback.

### Monitor

A machine-code monitor in ROM: examine and change memory, show the
registers' last values, jump to an address, hex dump, fill and copy, load
and save memory ranges to the SD card, and a small disassembler using the
opcode table in `reference/opcode_map.html`.  It is the first program to
write once the keyboard driver works, because it is how everything after it
gets debugged on the real machine.

### Boot menu

Replaces the boot loader's fixed choice (the boot mode byte at xFC00).  At
power-up it shows a menu: the programs built into ROM (monitor, BASIC,
file browser, demos), and "boot from SD", which loads a named file (for
example `BOOT.PLC`) into RAM and runs it.  Remember the last choice in a
setting on the card, and hold a key (or a pad button) at power-up to get the
menu back.

### File browser

Lists the SD card's directories with the cursor keys or the pad, and acts
on the selected file by its extension: run a program (load into RAM and
jump), open a text file in a viewer, load a BASIC program into BASIC, start
an emulator with a ROM or disk image, or show an image file on screen.
Later: copy, rename and delete once FAT write works.

### BASIC interpreter

A 16-bit integer BASIC in the style of Tiny BASIC or Apple Integer BASIC:
line-numbered programs, `PRINT`, `INPUT`, `IF`, `GOTO`, `GOSUB`, `FOR`, one
array, `PEEK`/`POKE`, `CALL`, and `LOAD`/`SAVE` to the SD card.  Placard
extras: `PLOT`, `LINE`, `MODE` (per-row color mode), `PAD` (read a pad) and
`SOUND` (write to the audio buffer).  An interpreter of this size usually
fits in 4-8 KB, so it fits the free ROM.  Floating point can come later.

### Emulators

Placard runs roughly 7 million native instructions per second, and an
emulated instruction typically costs tens of native ones, so an emulated
CPU runs at roughly a few hundred thousand instructions per second (an
estimate, to check with a prototype).  In order of fit:

| Target | Why it fits | Memory needed | Notes |
|---|---|---|---|
| CHIP-8 | Tiny virtual machine made for hobby games; 35 opcodes, 64 x 32 display, 16-key pad, 60 Hz timers | 4 KB | Best first emulator.  Timers from the line read, beep from the audio buffer, keys from the keyboard or the SNES pad.  Many free games exist. |
| Apple 1 (6502) | Simple text terminal, keyboard in, 40 x 24 text out | 4-8 KB | Needs a 6502 core.  The Woz Monitor is tiny; check the license of any ROM before shipping it. |
| CP/M 2.2 (8080) | A real OS with a large library of software (editors, assemblers, compilers, games) on disk images | 20 KB minimum system, ideally much more | The most useful, and the hardest: 8080 core, BIOS for console and disk images on the SD card, and memory spread over the free RAM pieces (or 4x-repeat video RAM).  Expect it to run below a real 2 MHz 8080.  Digital Research's CP/M was released for free use; confirm the terms. |

A native OS of our own (a small DOS with a command line, file commands and
program loading) is the alternative to CP/M.  Most of it is the boot menu,
file browser and monitor joined behind one command line.

### Software order

1. Keyboard and SD drivers, raw sectors (done).
2. Monitor.
3. FAT read, file browser, boot menu.
4. BASIC.
5. CHIP-8, then a 6502 or 8080 emulator.

## Cut for now (can be added later)

| Feature | Cost to add back |
|---|---|
| Hardware frame counter | 1 x 22V10 |
| Hardware SPI byte shifter (faster SD) | 74HC595, 74HC165, 22V10 |
| Buffered expansion slots | 74F245 + 74F541 per slot (stock not checked) |

## Risks and open questions

- **Polling once per frame** is a rule all software must follow if it keeps
  time from the line read.
- **Hardware checks** for the I/O are listed in IO.md and EXPANSION.md,
  "To check".
