# PLACARD BASIC

PLACARD BASIC is the BASIC in the 32K ROM image.  It starts when the
machine has no SD card (or no `DOS.PLC` on it), when `BOOT.CFG` names
`BASIC`, or from the DOS.  It is a 16-bit integer BASIC with strings, in
the style of Microsoft BASIC: line numbers, `FOR`/`NEXT`, `GOSUB`,
strings with `LEFT$`, `MID$` and friends, arrays, `DATA`, plus statements
for the Placard's screen, graphics, sound and SD card.

Date: 10/26/2026

Source: `src/scripts/basic.masm` (the bytecode machine, about 1.5 KB of
native code) and `src/scripts/basic.vm` (the interpreter, in bytecode,
compiled by `src/scripts/vmc.py`).  `src/scripts/test_basic.py` checks it
in the simulator.  Example programs are in `sdcard/` (`*.BAS`).

## Using it

**Plug in the keyboard and mouse before turning the machine on.**  They
are not hot-pluggable: one plugged in later is not recognized until the
machine is reset (SW2, the reset button).

```
PLACARD BASIC
7424 bytes free
Ready
```

A line typed with a number in front is stored in the program (a number
alone deletes that line); anything else runs at once.  Keywords may be
typed in upper or lower case and are listed in upper case.  Spaces are
kept as typed; `FORI=1TO10` works.  A keyword is recognized only when the
character before it is not a letter, so `FOR` inside `XFOR` is not a
keyword (variable names are two characters, so long names are not
useful anyway).

- **Esc** stops a running program (`Break in 120`); `CONT` carries on.
  Esc also stops `LIST`.
- **Esc held at power-up** starts the DOS instead of what `BOOT.CFG`
  names; `DOS` from BASIC goes there too.
- Backspace edits the line being typed; lines are up to 158 characters.

## The language

### Numbers and variables

Numbers are 16-bit integers, -32768 to 32767 (or 0 to 65535 where an
address is meant: `PEEK(65280)` and `PEEK(-256)` are the same).
Arithmetic wraps around without an error.  `&HFF` (or `&FF`) is a hex
number.  True is -1, false 0.

Variable names are a letter and an optional letter or digit (`A`, `X1`,
`HP`).  Longer names are allowed, but only the first two characters count,
as in Microsoft BASIC.  A name ending in `$` is a string.  Variables start
as 0 or "".

Arrays have one dimension: `DIM A(100)` gives `A(0)` to `A(100)`.  An
array used without `DIM` gets 10 (0-10).  `DIM` of an array that exists is
an error.

### Operators

In order of precedence, highest first:

| Operators | |
|---|---|
| `( )` | |
| `-` `+` (unary) | |
| `*` `/` `MOD` | `/` and `MOD` truncate toward zero; `MOD` takes the sign of the left side |
| `+` `-` | `+` also joins strings |
| `=` `<>` `<` `>` `<=` `>=` | numbers or strings (compared by character code); -1 or 0 |
| `NOT` | bitwise |
| `AND` | bitwise |
| `OR` | bitwise |

### Statements

| Statement | |
|---|---|
| `LET v = e` or `v = e` | assign |
| `PRINT` or `?` | items separated by `;` (nothing between) or `,` (to the next column of 10); a `;` or `,` at the end keeps the cursor on the line; `TAB(n)` moves to column n |
| `INPUT ["prompt";] v, v...` | reads values separated by commas; `?? ` asks for more, `?Redo` repeats on a bad number |
| `GET v` / `GET v$` | the key waiting, or 0 / "" when none (no waiting) |
| `IF e THEN statements` / `IF e THEN n` / `IF e GOTO n` | the rest of the line runs when e is not 0 |
| `GOTO n`, `GOSUB n`, `RETURN` | |
| `ON e GOTO n1, n2...` / `ON e GOSUB ...` | goes to the e-th line; out of range carries on |
| `FOR v = a TO b [STEP s]`, `NEXT [v[, v...]]` | the loop runs at least once |
| `DIM a(n), b$(n)...` | |
| `DATA`, `READ v...`, `RESTORE` | items are numbers (hex allowed) or strings (quoted, or up to a comma) |
| `REM` | the rest of the line is a remark |
| `END`, `STOP` | `STOP` acts like Esc (`CONT` carries on) |
| `RUN [n]`, `RUN "name"` | clears the variables first; `RUN "name"` loads and runs a file |
| `LIST [n] [n-] [-n] [n-m]` | |
| `NEW`, `CLEAR`, `CONT` | `CLEAR` clears the variables |
| `POKE a, b`, `CALL a [, ac]` | `CALL` runs machine code with AC = ac (see below) |
| `WAIT f` | waits f frames (60 a second); Esc breaks |
| `CLS` | clears the text window (and the graphics area) |
| `LOCATE row, col` | moves the cursor |
| `TEXT 60` / `TEXT 30` | 80 x 60 text (8-line characters) or 80 x 30 (each line twice, for TVs and big type); the whole screen is text |
| `MODE bpp, rep [, rows]` | graphics under a text window of `rows` text rows (0 = all graphics) |
| `PLOT x, y, c` | |
| `LINE x1, y1, x2, y2, c` | |
| `TINT row, rgb` | tints a text row (bits 2:0 = R, G, B: 1 blue ... 7 white tint, 0 none) |
| `SCAN first, last, mode` | writes the mode byte of lines first-last directly ([VIDEO.md](VIDEO.md)) |
| `BEEP [note]` | a short note (MIDI number, 69 = A 440, the default) |
| `SOUND note, frames [, volume]` | volume 0-127 (96 default); frames 0 = until the next sound |
| `NOISE volume, rate, frames` | rate 1-128 |
| `LOAD "name"`, `SAVE "name"` | the program as a text file; `.BAS` is added when the name has no dot |
| `DIR`, `DEL "name"` | the current folder of the card; `DEL` deletes a file |
| `DOS` | starts the DOS (`DOS.PLC` on the card) |

Several statements may share a line, separated by `:`.

### Functions

| Function | |
|---|---|
| `ABS(n)`, `SGN(n)` | |
| `RND(n)` | a random number 0 to n-1 |
| `PEEK(a)` | a byte of memory |
| `FRE(0)` | free bytes (after collecting the string garbage) |
| `INKEY` | the key waiting, as a number (0 = none); no brackets |
| `PAD(n)` | the game pad on port n (1 or 2): its bits ([IO.md](IO.md)) |
| `LEN(s$)`, `ASC(s$)`, `VAL(s$)` | `VAL` reads a number at the start (leading spaces, `-`, `&H`), 0 when none |
| `CHR$(n)`, `STR$(n)`, `HEX$(n)` | |
| `LEFT$(s$, n)`, `RIGHT$(s$, n)`, `MID$(s$, start [, n])` | `start` counts from 1 |

Strings are up to 255 characters.

### The screen

BASIC uses the library's font: 80 columns, 60 rows of 8 lines (`TEXT 60`,
the default), or 30 rows of 16 lines (`TEXT 30`, each line shown twice).

`MODE bpp, rep, rows` keeps `rows` text rows at the top (the text window,
where `PRINT` and `INPUT` work and scroll) and makes the rest of the 480
lines graphics: `bpp` bits per pixel (1, 2, 4 or 8: 640, 320, 160 or 80
pixels across) and each graphics line shown `rep` times (1, 2 or 4).
`PLOT` and `LINE` count x across and y down from the top of the graphics
area, in pixels of that size; points off the area are ignored.  Colors
are those of the mode ([COLORS.md](COLORS.md)).  `MODE 2,2,4` is a 320 x
224 four-color picture under four rows of text.

`MODE` with 0 rows makes the whole screen graphics; the text comes back
(and the program stops) at the next error, `END` or Esc, after a key.
`CLS` clears both parts; `TEXT` goes back to all text.

With `TEXT 30` the graphics lines can only be repeated 2 or 4 times, and
with 2x repeat the text window takes an even number of 16-line rows below
row 6; other combinations give `?Layout error` (the video hardware
fetches 2 lines at a time, [VIDEO.md](VIDEO.md)).

### Machine code

`POKE`, `PEEK` and `CALL a, ac` reach the hardware and machine code.
`CALL` runs the code at `a` with AC = `ac`, map 07 (RAM x0000-x5FFF), and
the library's stack; the code returns with `ret`.  It may use R0-R7 and
T0-T7 (x10-x1F) and memory BASIC does not use (below), and must leave x20-x4F
and x5000-x5DFF alone.

BASIC's RAM:

| Address | |
|---|---|
| x0020-x004F | BASIC's zero page |
| x0050-x008F | the bytecode machine's data stack |
| x00A0-x00FF | the library (I/O, keyboard, sound, stack) |
| x0100-x1DFF | variables (up) and strings (down) |
| x1E00-x1EFF | `FOR` and `GOSUB` |
| x2000-x4CFF | the program (11.25 KB) |
| x4D00-x53FF | free (for machine code) |
| x5400-x59FF | input line, return stack, sector buffer, temporary strings |
| x5A00-x5DFF | mode bytes, the RAM routines, BASIC's variables, sound |

### Files

`SAVE` writes the program as plain text (`10 PRINT "HI"` with CR LF line
ends), as `LIST` shows it, so a `.BAS` file can be written on a PC.  `LOAD`
reads such a file: lines without a number are skipped, lines may come in
any order, lower-case keywords are fine.  A few seconds for a large
program.  Errors from the card are `?File error n` with the FAT code
([DOS.md](DOS.md)).

## Errors

| Message | |
|---|---|
| `?Syntax error` | |
| `?Out of memory error` | program, variables, strings or `FOR`/`GOSUB` nesting |
| `?Undefined line error` | |
| `?Type mismatch error` | a string where a number belongs, or the other way |
| `?Division by zero error` | |
| `?RETURN without GOSUB error`, `?NEXT without FOR error` | |
| `?Out of data error` | |
| `?Bad subscript error` | |
| `?Illegal quantity error` | a value out of range |
| `?String too long error` | over 255 characters |
| `?Can't continue error` | |
| `?Redim'd array error` | |
| `?Illegal direct error` | `INPUT` typed without a line number |
| `?Layout error` | a `MODE` the video can't show |
| `?File error n` | |

In a program the message ends with `in` and the line number.

## How it works

### The bytecode machine

BASIC is written in a compact bytecode for a small stack machine, like
Forth.  The Placard has no stack pointer, no indexed addressing beyond
`[y,x]` and branches that only reach within a page, so native code is
large; a bytecode instruction is one byte (a primitive) or two (a call),
about a third of the size of the same thing in native code, and fast
enough: the machine runs about 220,000 bytecode instructions a second.

- **IP** (x20-x21) points at the next instruction.
- The **data stack** holds 16-bit cells in x50-x8F, growing down; the top
  cell is kept in **TL/TH** (x22-x23) and DSP (x24) points at the next.
- The **return stack** is page x5500, RSP (x25), growing down.
- An instruction byte x00-x3F runs primitive n: `next` jumps to
  `vm_jump` + 4n, a page of `ld hi, y` / `jmp lo` pairs that vmc.py
  writes from the `PRIM` lines.  x80-xFF is a call to the word at that
  address (high byte, then the low byte), so words live at x8000-xFFFF,
  which is all of the ROM.

`next` fetches the byte at IP: a primitive is a jump through the table, a
call pushes IP on the return stack.  `EXIT` pops it.  The primitives
(stack, memory, arithmetic, `*`, `U/MOD`, `CMOVE`, `FILL`) and the parts
that must be fast (the text pointer's `CH` and `NUM`, `GLYPH` for a
character, `ROWCPY` for scrolling, `VPLOT` for a pixel) are native code in
`basic.masm`.  `SYS` calls library routines with AC and R0-R7.  `POLL`
runs `frame_poll` and, once a frame, `snd_update` and `kbd_scan`, so the
keyboard and sound keep going while a program runs, and returns whether
Esc is down.

Video RAM (x6000-x7FFF and the 64 pages above x8000 in the RAM) is under
the ROM in map 07, so the routines that touch it run from RAM x5C00
(copied there at start) with map FF for a moment.

### basic.vm

`basic.vm` is the interpreter, in a Forth-like language that `vmc.py`
compiles (`asm_expand.py` runs it at `.include "basic.vm"`):

- `: NAME ... ;` defines a word; `IF ELSE THEN`, `BEGIN UNTIL`,
  `BEGIN WHILE REPEAT`, `BEGIN AGAIN` and `RECURSE` compile to branches.
- `PRIM name label [n]` declares a primitive and its inline operand bytes.
- `CONST`, `VAR`, `BYTES` (tables, `k"..."` keywords with bit 7 on the
  last character, `c"..."` counted strings), `WORDS` (address tables),
  `." ..."` and `S" ..."` strings, `' word` (its address) and
  `{expression}` (an assembler symbol, such as a library routine).
- `asm_expand.py`'s `.page` directive puts `vm_jump` at the start of a
  page.
- Each word becomes a `.flow` chunk that `asm_expand.py` places in the free
  space of the ROM regions, so BASIC fills the gaps the loader and FAT
  writer leave.

The words fall into the editor (`ACCEPT`, `CRUNCH` tokenizes the line in
place, `STORELN`), the variables (`FINDVAR`, `NEWVAR`, the string heap and
its garbage collector), the expression evaluator (`EXPR` down to `ATOM`,
recursive descent), the run loop (`EXECLINE`, `STATEMENT` dispatching
through `STMTAB`) and the statements (`PRINT_`, `FOR_`, ...).

A program line is `[length][number low][number high][text][00]`; keywords
are one byte each (x80-xC1, the order of `KWTAB`).  Numbers stay text and
are read when the line runs.  `FOR` and `GOSUB` keep their frames on the
control stack at x1E00-x1EFF.

A string variable holds 0 ("") or the address of its block in the string
space: `[length][characters][length][owner]`.  When the space runs out the
garbage collector walks the blocks from the top, keeps those whose owner
still points at them, and moves them up.  Strings made while a statement
runs (`A$+B$`, `STR$`, `MID$`) go in a temporary area that empties at
every statement; assignment copies them into the string space.

## Speed

`test_basic.py --bench` runs `FOR I=1 TO 1000:A=A+I*2:NEXT` in 2.3 s of
machine time: about 440 passes a second, roughly the speed of the 1 MHz
home computers' BASICs on the same loop (they do it in floating point).
About 500 bytecode instructions a pass, half of the time in `next`.  The
hot paths are native: `next` jumps through a page of four-byte jumps
(`vm_jump`), and `FINDVAR`, `VARNAME`, `DIGIT?` and `ALPHA?` are
primitives; together they made the loop about twice as fast as the first
version.  `LINE` draws about 1,200 pixels a second (each pixel a `PSET`
in bytecode).

`FRE(0)` and the banner count the space for variables and strings
(x0100-x1DFF); the program has its own 11.25 KB.

## Not done yet

- Arrays in the free video RAM (for big arrays in a text-only screen).
- Floating point (planned as a program on the card).
- `RENUM`, `EDIT`, `ELSE`.
- A native `LINE` (and `PSET`) if drawing speed matters; about 770 bytes
  of the ROM are still free at x9BFE-x9EFF.
- The DOS running `.BAS` files directly.
