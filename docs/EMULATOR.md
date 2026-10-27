# Web emulator

`web/index.html` runs the PLACARD in a browser: the CPU with the ROM/RAM
map, the VGA screen, the line-rate audio, a PS/2 keyboard and mouse, two
SNES pads (game controllers) and an SD card.  It is a plain static page
with no server and no build step:

- **On your own computer:** open `web/index.html` (double-click it).  The
  built-in ROM and SD card are in `default_rom.js` and `default_sd.js`, so
  nothing has to be fetched, and your own files come in through the file
  pickers.
- **On the web:** any static host works, for example GitHub Pages serving
  the `web/` folder (Settings > Pages, deploy from a GitHub Actions workflow
  that uploads `web/`).  Nothing is sent anywhere; the files you load stay
  in the browser.

Date: 10/27/2026

## What it models

The machine is `web/placard_emu.js`, a JavaScript port of
`src/scripts/placard_sim.py` (the instruction-level CPU), `io_devices.py`
(the shared port, PS/2 receiver PLD, keyboard, mouse, SNES pads and SD
card) and `sdimage.py` (FAT16 card images).  It is not a gate or VHDL
simulation; the timing comes from the same rules the Python simulator uses:

| Part | Model |
|---|---|
| Clock | 25.175 MHz; every clock counted, 800 per line, 525 lines per frame (59.94 Hz) |
| CPU | each instruction's clocks (fetch, operand, LOAD_MEM, the ALU wait clock), ROM/RAM map at x5000, line read at x5000 |
| Video stalls | the clock lost in each 8-clock group the video reads in: mode byte (group 45) and audio (46) on every line, pixels (groups 48-127) on active lines that are not blanked |
| Screen | drawn one line at a time at the end of that line, from the RAM as it is then: 1/2/4/8 bpp, line repeat, row tint, blank lines (VIDEO.md, COLORS.md) |
| Audio | one DAC sample per line, read from x5DF3-x5FFF at the audio slot's clock (group 46 or 47), the board's 10.6 kHz filter and coupling capacitor, resampled to the sound card (SOUND.md) |
| Cartridge | a 32K image is read in both halves, a 64K one as is; the CPU waits while the cartridge copies its EEPROM (about 33 ms from the image's own walk) and the screen shows the RAM meanwhile |
| Power-up | random RAM (can be turned off), map clear, registers 0; Power cycle starts everything again, as the reset relay does |
| PS/2 | keyboard (scan code set 2, typematic repeats from the browser's key repeat, LEDs shown under the screen) and mouse, at the line level in 5 us steps, through the receiver PLD and the port latch |
| SNES pads | the browser's game controllers (standard mapping: bottom B, right A, left Y, top X, shoulders L/R, back Select, start Start, D-pad and left stick) |
| SD card | SPI-mode SDHC card: CMD0/8/55/ACMD41/58/16/17/24, reads and writes |
| Expansion slots | empty (read FF) |

The video stall clock is placed in clock 7 of its group and the audio stall
in group 46 on every line, as placard_sim.py does; the hardware's audio
read moves to group 47 on lines 512-1023 (8 clocks later), which changes no
count.

`src/scripts/test_web_emu.py` (needs node) runs the emulator and
placard_sim.py side by side for 200 frames of the 32K image with the
`sdcard/` card, keys and mouse moves, and checks the PC, registers, map,
clock count and RAM every 50,000 instructions, then the SD card and the
screen.  They are the same clock for clock.

## Using it

- **Click the screen** to give it the keyboard and the mouse (the pointer is
  locked to the page).  The browser keeps Esc to free the pointer, so press
  Esc a second time to send it to the PLACARD, or use Full screen, where
  Chrome and Edge pass Esc through.  Keys held while you press Power cycle
  are held at power-up (Esc skips BOOT.CFG).
- **Cartridge ROM:** Load ROM takes a 32K or 64K binary (`rom_32k.bin`, an
  EEPROM file) or a text image (`rom.mem`, a hex string).  Loading one power
  cycles the machine.  Dropping a file on the page does the same.
- **SD card:** Built-in is the `sdcard/` folder.  Load folder makes a FAT16
  card from a folder on your computer (8.3 names only; others are left out
  and listed).  Load image takes a raw card image (`.img`, FAT16 or FAT32).
  The card can be changed while the machine runs, like pulling a card out.
  Save image downloads the card with everything the PLACARD wrote to it (the
  DOS's SAVE, BASIC's SAVE); the page warns before a card with unsaved writes
  is replaced.
- The status line shows the speed (100 % is real time), the frame count,
  the PC and the map.

## Rebuilding the built-in ROM and card

`python3 src/scripts/gen_web_assets.py` writes `web/default_rom.js` (the
32K image built from `rom32.asm` the way `gen_rom.tcl` builds it) and
`web/default_sd.js` (the files of `sdcard/`).  Run it after a change to the
ROM sources or to `sdcard/`.
