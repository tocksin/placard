# Feature plan: software, and what was cut

The I/O hardware from this plan is designed: the shared port with the
keyboard, SNES pads, SD card and PS/2 mouse is in [IO.md](IO.md), and the
expansion slots and ROM cartridge slot are in [EXPANSION.md](EXPANSION.md).
What is left here is the software to write on top of it, and the hardware
that was cut to keep the chip count down.

## Software

The program list, what each program needs and the order to write them are
in [SOFTWARE_ROADMAP.md](SOFTWARE_ROADMAP.md) (2026-10-23).  The drivers
(keyboard, pads, SD card, mouse, PS/2) and the FAT reader are written
([IO.md](IO.md), [LIBRARY.md](LIBRARY.md)); FAT write is the next library
piece.

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
