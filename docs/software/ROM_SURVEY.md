# What other machines' ROMs have

A look at the ROMs of other 8-bit and TTL computers for things worth
having in the PLACARD ROM: routines they offer that ours lacks, and the
tricks they use for speed.  It is written from the published ROM listings
and disassemblies of these machines as remembered, not from a fresh
reading of each, so treat a detail as a pointer and check it before
building on it.

Date: 2026-11-11

## Speed tricks, and where we stand

| Trick | Who used it | PLACARD |
|-------|-------------|---------|
| Tables instead of arithmetic.  The quarter-square multiply: a × b = f(a + b) - f(\|a - b\|), f(n) = n² / 4 | 6502 games and demos (the stock ROMs multiply by shifting); the Gigatron's ROM keeps tables for what its CPU can't do (shift right) | **Done 2026-11-11**: `mul8` uses two 256-byte tables in the boot loader's free pages.  123 clocks on average, was 459 (and 565 before 2026-11-10) |
| Self-modifying loops kept in RAM.  CHRGET, the routine BASIC calls for every character, is copied from ROM to the zero page so its pointer is part of its own instructions | Commodore and Apple II BASIC | **Done 2026-11-11**: `memset`'s loop is in `LIB_RAM` with the value and offset in its own operands: 14 clocks a byte, was 43.  `plot1`, `con_scroll` and `lib_far` already run there |
| Block moves a page at a time: whole pages with the index register alone, then the odd bytes | Microsoft BASIC's block move, the C64 KERNAL | `memset` now works by runs within a page.  `memcpy` still carries two 16-bit pointers a byte (64 clocks); runs within a page would make it about 45.  Not done: both pointers still need loading for every byte, so the gain is small |
| Short paths for small numbers | most integer BASICs skip leading zero bytes | **Done 2026-11-11**: `div16` takes 8 steps instead of 16 for a dividend under 256 (about 740 clocks, was 1,500).  `mul8` stopped early on small factors since 2026-11-10; the tables replace that |
| Unrolled inner loops | the Gigatron's video loop, most games | `con_putc` already draws its 8 rows unrolled |
| Row address tables | the C64's screen line table, Apple II hi-res tables in games | `vid_addr` works a row's address out in 72 clocks; a table would save little of that and cost about 1 KB.  Not worth the ROM |
| Scrolling in hardware (moving the start address of the screen) | BBC Micro, Amstrad CPC, Atari display lists | Not possible here: the video address counter can't be offset, so `con_scroll` moves the pixels (46 ms).  BASIC already skips blank rows |
| A compact virtual machine for code that need not be fast | Apple II Sweet16, the Gigatron's vCPU | BASIC is built on one (`basic.vm`).  It is private to BASIC; see below |

## Things they have that we don't

In rough order of how useful they look for this machine:

1. **Pixels and lines for every color depth.**  The BBC's `PLOT` (lines,
   triangles, fills), the Spectrum's `PLOT` / `DRAW` / `CIRCLE`, MSX
   `LINE` and `PAINT` are all in ROM.  Ours has `plot1` (1 bpp) only;
   BASIC has its own `LINE`.  A `plot` for 2, 4 and 8 bpp rows and a
   line routine are the clearest gap ([LIBRARY.md](LIBRARY.md#not-in-the-library-yet)
   already lists them).  They would need perhaps 400-600 bytes (an estimate); the library has
   that only in scattered page ends, so they would take program ROM.
2. **RAM vectors for character in and out.**  The C64 (x0314-x0333), the
   BBC (x0200 up) and the Atari jump through addresses in RAM for
   "print a character", "read a key" and so on, so a program can
   redirect them (to a printer, a file, a different text layout) and
   everything that prints follows.  Our jump table is in ROM, so
   `con_puts` and `con_dec16` can only ever call the 1x `con_putc`.  One
   vector pair for `con_putc` would let SCRAPWRIGHT's and the tracker's
   2x text use `con_puts` and `con_dec16` instead of their own copies.
   Cost: 2 bytes of zero page or `LIB_RAM` and a few clocks a character (estimates).
3. **A machine-language monitor.**  The Apple II's (dump, change, move,
   go, a mini-assembler) and the C128's.  For a home-built CPU it is the
   natural bring-up and debugging tool.  It need not be in ROM: a
   `MON.PLC` on the card (planned, not built) does the job, and the
   bring-up ROM covers the case of no working card.
4. **Device-independent I/O.**  Atari CIO, CP/M's BDOS and the C64's
   channels let one `PRINT` go to screen, file or serial port.  With
   item 2 this is mostly free for output.
5. **A text-to-number routine.**  Every BASIC ROM has one and exposes it
   (programs on those machines call it directly).  Ours is inside BASIC's
   bytecode; the DOS has its own for hex.  A library `str_dec16` would be
   small (well under 100 bytes).
6. **A callable virtual machine.**  Sweet16 and the vCPU are open to any
   program, which makes big, slow-path code (menus, file handling) a
   third of the size.  SCRAPWRIGHT's overlays exist because its code does
   not fit; a public VM would attack the same problem.  A large change;
   only worth it if program size keeps being the limit.
7. **Envelopes and a music language** (BBC `ENVELOPE`, MSX `PLAY`).  We
   have the tone and noise routines in ROM and the four-voice player on
   the card, which is the better split for 32K.
8. **Floating point** (Spectrum calculator, Microsoft BASIC).  Decided
   2026-10-27: not in the ROM; a float BASIC would be a card program.
9. **Power-on self-test and a ROM checksum** (Atari XL, most later
   machines).  `TEST.PLC` and the bring-up ROM do the tests; a checksum
   of the ROM at boot would cost about 40 bytes and is not there.

## What we have that they mostly don't

A FAT file system reader and loader in ROM (most kept the DOS on disk or
in a cartridge), mouse and PS/2 drivers, a sample-playback sound driver,
and a jump table that never moves (the Apple II and the Spectrum have
none, which froze their ROMs' internal addresses forever).
