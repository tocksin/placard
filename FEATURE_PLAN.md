# Feature plan: I/O

This is a planning list, not a design.  Nothing here is implemented yet.  It
covers the I/O the Placard still needs (sound, keyboard, controller, SD card
storage and two expansion ports) and proposes one common I/O bus that every
one of them plugs into.  Each feature lists the approach, a register map,
the likely parts and the open questions.

## Starting point

These facts from the current design shape every choice below.

- **The I/O window is already reserved.**  The README memory map puts I/O at
  x5000-x5FFF, one 256-byte page per device, with priority over RAM/ROM.
  Nothing decodes it yet: the ROM/RAM map register in `ATF22V10_ROMRAM_SEL.pld`
  needs "a decoded I/O write strobe" on WR_CLK, and in `basys_top.vhd` that
  input is tied to a constant.
- **Only `[Y,X]` reaches I/O.**  `[0,D]` and `[0,X]` only address the zero
  page, so every I/O access is `ld 0x5n, y` then `ld [y,x], ac` (read) or
  `ld ac, [y,x]` / `ld n, [y,x]` (write).  Loading Y once and stepping X
  through a device's registers is the cheap pattern.
- **There are no interrupts.**  All I/O is polled.  Anything that cannot wait
  for the CPU to look (key presses, audio, SPI clocking) needs a latch, a flag
  or its own small state machine.
- **There are no wait states.**  The State PLD's Q0 and Q1 have no product
  terms left, and holding PIXEL_ENABLE to stall would hand the address bus to
  the video.  Every device must answer within one CPU clock (about 40 ns at
  the 25 MHz pixel clock) and take writes from a write pulse of about 20 ns.
- **Writes use the existing strobe.**  RAM writes use `/WE = RW | CLK`, low only
  in the low half of an EXEC write cycle.  I/O writes use the same pulse and
  latch on its rising edge.
- **The ROM/RAM select PLD is full.**  Every pin is in use (12 inputs, 9
  outputs, and pin 23 as the RW input), so the "I/O has priority" rule cannot
  be added inside it.

## 1. Common I/O bus (do this first)

Every feature below sits on the same set of signals, so the bus is defined
once and each device only needs its own chip select.

### I/O decode PLD (new ATF22V10C)

| Pin use | Signals |
|---|---|
| Inputs (11) | A15, A14, A13, A12, A11, A10, A9, A8, RW, CLK, LOAD_IMM (D register strobe from the State PLD) |
| Outputs (10) | IO_SEL, /IORD, /IOWR, /CS50, /CS51, /CS52, /CS53, /CS54, /CS55, /CS56 |

Proposed equations (written out in full in the PLD when it is designed):

    IO     = !A15 & A14 & !A13 & A12                  /* x5000-x5FFF */
    IO_SEL = IO                                       /* blocks RAM/ROM reads */
    IORD   = IO & RW & LOAD_IMM                       /* CPU is latching D    */
    IOWR   = IO & !RW & !CLK                          /* same pulse as /WE    */
    CS5n   = IO & (A11:A8 = n)                        /* n = 0..6             */

- **RAM/ROM priority.**  IO_SEL disables both memories during reads: two spare
  OR gates in the existing 74HC32 (the one that makes /WE) give
  `/ROM_OE = /ROM_EN | IO_SEL` and `/RAM_OE = !RW | IO_SEL`.  Writes to
  x5000-x5FFF still land in the RAM underneath, which is harmless and saves
  gating /WE.
- **Read qualification.**  /IORD only goes low while the State PLD is loading
  D (LOAD_IMM includes !PIXEL_ENABLE), so a device with a read side effect,
  such as "read clears the key flag", only sees the real read.  The plan still
  prefers explicit write-to-acknowledge registers over read side effects.
- **x5300** is spare now that the controllers are on the serial port, so
  /CS53 is free for a later device.
- **x5700-x5FFF** stays reserved.  It costs no decode outputs today; a third
  expansion port would need either a second decoder or dropping a /CS.

### Device interface

Each device (internal or on an expansion card) sees the same signals:

| Signal | Meaning |
|---|---|
| D7:D0 | RAM-side data bus.  The CPU's source-bus buffer drives it during /WE; RAM, ROM or the selected device drives it during reads. |
| A7:A0 | Register select inside the device's 256-byte page (most devices use A1:A0 or A3:A0). |
| /CSn | Device select from the I/O decode PLD. |
| /IORD | Drive D7:D0 now.  Gate a 74HC541/74HC245 with `/CSn | /IORD`. |
| /IOWR | Latch D7:D0 on the rising edge.  Clock a 74HC574 with `/CSn | /IOWR` (one OR gate per device). |
| RESET | System reset. |
| CLK | 25 MHz pixel/CPU clock, for devices with their own state machine. |

### Config page (x50)

| Address | R/W | Function |
|---|---|---|
| x5000 | W | ROM/RAM section map: drives WR_CLK of the ROM/RAM select PLD.  Bit n = 1 makes section n RAM. |
| x5000 | R | Video status: VSYNC, VIDEO_ACTIVE and (optionally) a frame counter, so software can time to the frame without interrupts.  One 74HC541. |
| x5001 | R | (Optional) Read back the ROM/RAM map from the RAMSEL7:0 pins. |

### FPGA model and tools

- Add the I/O decode PLD as `io_decode_pld.vhd` (per the project rules: no
  optimization, individual pins, lowerCamelCase signals) and wire its WR
  strobe into `romram_sel_pld`.
- `basys_top.vhd` has no tri-state buses, so the read mux in
  `rambusSelectorProc` gains an I/O branch alongside ROM and RAM.
- `placard_sim.py` gets an I/O hook so programs that poll devices can run in
  the simulator.
- `placard.asm` can add `#const` names for the device pages and registers.

## 2. Serial port: SD card and SNES controllers (x54)

The SD card and the SNES pads are both clocked serial devices, so they share
one byte shifter and differ only in which device is selected.  The controller
no longer needs its own page; x5300 is free.

### Shared shifter

- **Byte shifter.**  Writing x5400 starts 8 clocks that shift the byte out on
  MOSI (MSB first) while shifting the selected device's MISO in; reading
  x5400 returns the received byte.  A 74HC595-style shift-out plus a
  74HC165-style shift-in, with one 22V10 for the bit counter and clock.
  Software writes, polls BUSY, and reads.
- **SPI mode 0.**  SCK idles low, data is sampled on the rising edge and
  changes on the falling edge, which is what SD cards use.
- **Device select.**  Three control bits pick one of up to seven devices.  A
  74HC138 turns them into the per-device selects, and a 74HC151 (8-to-1 mux)
  routes only the selected device's data line back into the shift-in
  register.  The mux is needed because the SNES pad's data output is never
  tri-stated, and some SD modules don't release MISO either.
- **Two clock rates.**  Slow (under 400 kHz) for SD initialization and for the
  pads; fast for SD data transfers.
- **Alternative: bit-banged.**  One 74HC574 for clock, data and selects plus
  one buffer for the data lines.  Fewest chips, but each bit costs several
  instructions.

| Address | R/W | Function |
|---|---|---|
| x5400 | W | Transmit byte (starts a transfer) |
| x5400 | R | Received byte |
| x5401 | W | Control: bits 2:0 device select, bit 3 fast clock, bit 4 pad LATCH |
| x5401 | R | Status: bit 0 BUSY, bit 1 card detect |

Device select codes:

| Code | Device |
|---|---|
| 0 | None (all deselected) |
| 1 | SD card |
| 2 | SNES pad 1 |
| 3 | SNES pad 2 |
| 4-7 | Spare (for example a serial device on an expansion card) |

### SNES pads

- **How the pad works.**  A pad is a 16-bit parallel-in, serial-out shift
  register (two 4021s in the original).  A high pulse on LATCH captures the
  buttons and puts the first bit on DATA; each rising edge of CLOCK shifts the
  next bit out.  CLOCK idles high and DATA is active low.
- **Fit to the shifter.**  The pad's CLOCK is the shifter's SCK through an
  inverter.  CLOCK then idles high, the shifter samples on an SCK rising edge
  (pad CLOCK falling, data stable) and the pad shifts on an SCK falling edge.
  The first bit is already on DATA when the first sample happens, so the
  bits come out in order.
- **LATCH** is a control-register bit rather than a select, because it is a
  pulse before the transfer, not a level held during it.  Both pads share
  LATCH and CLOCK; each has its own DATA line into the mux.
- **Reading a pad:** set LATCH, clear LATCH, select the pad, transfer two dummy
  bytes.  Byte 0 is B, Y, Select, Start, Up, Down, Left, Right (bit 7 = B);
  byte 1 is A, X, L, R and four 1s.  A 0 bit means pressed.  Both pads shift
  on every clock, so latch again before reading pad 2.
- **Speed.**  Use the slow clock rate.  The original console clocks the pad
  at about 83 kHz, and 4000-series CMOS (and clone pads) may not keep up with
  MHz rates.
- **Power:** the pads run at 5 V and connect directly, with no level shifting.

### SD card

Meets the "save and load programs on the computer" goal.

- **Levels:** SD cards are 3.3 V.  SCK, MOSI and the card select go through a
  CD4050 powered from 3.3 V; MISO comes back into a 74HCT input (3.3 V clears
  the HCT input threshold).  A 3.3 V regulator powers the card.
- **Speed:** initialize at the slow rate, then switch to the fast rate.  The
  CD4050 at 3.3 V is slow, so the fast rate is limited to a few MHz unless a
  faster level shifter is used.
- **Software:** start with raw sectors (a fixed sector range per saved
  program), then add a FAT filesystem later so cards can be filled from a PC.

Parts: 74HC595, 74HC165, 22V10 (shift control), 74HC574 (control register),
74HC138, 74HC151, 74HC04 (pad clock inverter), CD4050, 3.3 V regulator, SD
socket, 2 x SNES controller sockets.

## 3. Keyboard (x52)

The project goal is a built-in keyboard, not USB or PS/2, so this is a key
matrix.

- **Default: software-scanned matrix.**  An 8 x 8 matrix (64 keys) with a
  diode per key.  A read from x5200 + n drives column n low through a
  74HC138 enabled by `/CS52 | /IORD`, and the same read returns the 8 rows
  through a 74HC541 with pull-ups.  One `ld [y,x], ac` per column, two chips
  total.  Debounce, rollover, shift and repeat are done in software, called
  once per frame using the vblank status bit.
- **Alternative: hardware scanner.**  A 22V10 that scans the matrix by itself
  and latches a key code plus a "key ready" flag, so software only polls one
  register.  Fewer CPU cycles, but the PLD has to hold the scan counter and
  the code, which is tight in 10 macrocells.
- A 64-key matrix is small; a 10-column matrix (80 keys) needs A3:A0 and a
  second decoder or a 74HC4017-style counter.

| Address | R/W | Function |
|---|---|---|
| x5200-x5207 | R | Rows of column 0-7 (bit = 0 means pressed) |

Parts: 74HC138, 74HC541, 64 key switches, 64 diodes, pull-ups.

## 4. Sound (x51)

With no interrupts the CPU cannot feed samples at a steady rate, so the sound
hardware has to run on its own once set up.

- **Default: three square-wave voices plus noise.**  Each voice is a 74HC574
  holding a period value and a 22V10 that counts from that value to 255,
  reloads and toggles its output (the same count-and-reload idea as the H
  counter PLD).  Clocked from a prescaled pixel clock, e.g. 25 MHz / 256 =
  98 kHz, an 8-bit period gives roughly 190 Hz to 49 kHz.  A 10-bit period
  (two registers) would reach bass notes.
- **Noise:** a 22V10 LFSR (up to 10 bits fits the macrocells) clocked by a
  voice or its own divider.
- **Volume and mix:** a 4-bit volume per voice (one 74HC574 holds two voices)
  through resistor weights or a 74HC4066 switch ladder, summed into a small
  amplifier (e.g. LM386) and a 3.5 mm jack.
- **Alternative: 8-bit DAC.**  A 74HC574 into an R-2R ladder.  Any waveform,
  but the CPU must write it at the sample rate, which is only practical in a
  tight loop.  Worth adding as a fourth "voice" since it costs one latch.

| Address | R/W | Function |
|---|---|---|
| x5100-x5102 | W | Voice 0-2 period |
| x5103 | W | Noise rate / mode |
| x5104-x5105 | W | Volumes (4 bits per voice, noise in x5105 high nibble) |
| x5106 | W | (Optional) DAC sample |

Parts: about 4 x 22V10, 5 x 74HC574, resistors, amplifier.

## 5. Expansion ports (x55, x56)

The ports carry the device interface from section 1 to a connector, so a card
works the same as an internal device.

- **Connector:** a 2 x 20 (40-pin) box header per port.  Pins: D7:D0, A7:A0,
  /CSn, /IORD, /IOWR, RESET, CLK, VSYNC, VIDEO_ACTIVE, +5 V and several
  grounds interleaved with the fast signals.
- **Buffering:** a 74HC245 on D7:D0 (direction from /IORD, enabled only by the
  port's /CS) and a 74HC541 for A7:A0 and the strobes, so cable loading never
  reaches the CPU bus.
- **Prototyping:** because internal devices and cards share one interface,
  each feature above can first be built on an expansion card, then moved onto
  the main board.

## Suggested order

1. I/O decode PLD and config page (unblocks the ROM/RAM map register and gives
   vblank status).
2. Serial port with the SNES pads (the pads are an easy first test of the
   shifter, and the device select makes the SD card a second device, not a
   new circuit).
3. SD card on the serial port.
4. Keyboard.
5. Sound.
6. Expansion port connectors and buffers (the interface is fixed in step 1,
   so cards can be built at any point after it).

## Risks and open questions

- **Timing.**  One clock for reads and a 20 ns write pulse is tight, and
  every buffer on the expansion path adds delay.  If 74HC does not close
  timing, use 74AC/74ACT parts on the I/O path.
- **Keyboard size:** 64 keys (default) or a larger matrix?
- **Sound depth:** 8-bit periods (default) or 10-bit for lower notes?
- **SD level shifting:** confirm a through-hole, in-production 3.3 V buffer
  faster than the CD4050 if the fast SPI rate matters.
- **More than seven devices:** the decode PLD has no free outputs, so a third
  expansion port or more devices needs a second decoder.
