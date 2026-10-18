#!/usr/bin/env python3
"""
io_devices.py - models of the shared port at x5200 and the devices on it,
for placard_sim.py (see IO.md)

    port = SharedPort()                 # latch, key matrix, pads, SD, mouse
    port.keys.add((col, row))           # hold a key down
    port.pads[0].buttons = 0x0001       # pad 1: B held (bit n = button n)
    port.sd = SdCard(image)             # an SD card holding image (bytes)
    port.mouse = Ps2Mouse()             # a PS/2 mouse
    cpu = Cpu(mem, rom=rom, io=port)

The CPU calls port.read(addr, t) for a read of x5200-x52FF and
port.write(addr, value, t) for a write; t is the CPU clock count, used by
the PS/2 mouse (25.175 MHz clocks).

Port latch (write any x52xx), 74HC574:
    bit 0  SCK / pad CLOCK          bit 1  MOSI / pad LATCH
    bit 2  SD /CS; 0 also holds the PS/2 CLK line low (Schottky diode)
    bit 3  0 holds the PS/2 DATA line low (Schottky diode)
    bits 7:4  keyboard column 0-7 driven low; 8-15 none
Port read:
    even address (74F541): D7:D0 = key rows 7:0 of the driven column.
        Row 7 is also SD MISO, row 6 PS/2 DATA and row 5 PS/2 CLK
        (Schottky diodes), so with no column driven a read shows those.
    odd address (port PLD): D7 = pad 1 DATA, D6 = pad 2 DATA.  D5:D0 are
        not driven; the model returns 1s there.

Date: 10/18/2026
"""

CPU_HZ = 25_175_000


def us(t):
    """microseconds to CPU clocks"""
    return int(round(t * CPU_HZ / 1_000_000))


# ---------------------------------------------------------------------------
# SNES pad
# ---------------------------------------------------------------------------
class SnesPad:
    """A standard SNES pad.  buttons: bit n = 1 while button n is held,
    n = 0 B, 1 Y, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left, 7 Right, 8 A,
    9 X, 10 L, 11 R.  On the wire a held button is 0.  While LATCH is high
    the shift register loads continuously; each rising CLOCK edge with LATCH
    low shifts the next bit out.  After the 16th bit DATA is low (the shift
    register's serial input is grounded), like an official pad.
    connected = False models an empty socket (the pull-up reads 1)."""

    def __init__(self, connected=True):
        self.buttons = 0
        self.connected = connected
        self.shift = 0
        self.count = 16
        self.clocks = 0             # rising CLOCK edges with LATCH low

    def load(self):
        self.shift = (~self.buttons) & 0x0FFF | 0xF000   # bits 12-15 read 1
        self.count = 0

    def data(self):
        if not self.connected:
            return 1
        if self.count >= 16:
            return 0
        return (self.shift >> self.count) & 1

    def lines(self, clock, latch, rising):
        if latch:
            self.load()
        elif rising:
            self.clocks += 1
            if self.count < 16:
                self.count += 1


# ---------------------------------------------------------------------------
# SD card (SPI mode)
# ---------------------------------------------------------------------------
class SdCard:
    """An SD card in SPI mode.  image: bytearray, a multiple of 512 bytes.
    sdhc = True: SDHC (CMD8 accepted, CCS = 1, block addressing);
    sdhc = False: a version 1 SDSC card (CMD8 illegal, byte addressing).
    Samples MOSI on rising SCK edges and changes MISO on falling ones
    (SPI mode 0 and 3 use the same edges).  With /CS high MISO is
    tri-stated (the board's pull-up reads 1)."""

    def __init__(self, image=None, sdhc=True, acmd41_busy=3):
        self.image = image if image is not None else bytearray(512 * 64)
        self.sdhc = sdhc
        self.acmd41_busy = acmd41_busy    # ACMD41 answers "busy" this many times
        self.cs = 1
        self.spi = False                  # in SPI mode (after CMD0 with /CS low)
        self.idle = True
        self.app = False                  # next command is an ACMD
        self.inbyte = 0
        self.bits = 0
        self.out = []                     # bytes queued to send
        self.cur = 0xFF                   # byte being shifted out
        self.miso_bit = 1
        self.cmd = []
        self.rx_data = None               # CMD24: collecting a data block
        self.rx_addr = 0
        self.pre_clocks = 0               # clocks with /CS high before CMD0
        self.log = []
        self.reads = self.writes = 0

    def miso(self):
        return 1 if self.cs else self.miso_bit

    def set_cs(self, cs):
        if cs == self.cs:
            return
        self.cs = cs
        self.bits = 0
        self.inbyte = 0

    def edge(self, rising, mosi):
        if self.cs:
            if rising:
                self.pre_clocks += 1
            return
        if rising:
            self.inbyte = ((self.inbyte << 1) | mosi) & 0xFF
            self.bits += 1
            if self.bits == 8:
                self.bits = 0
                self.cur = self.out.pop(0) if self.out else 0xFF
                self.byte(self.inbyte)
        else:
            self.miso_bit = (self.cur >> (7 - self.bits)) & 1

    # --- byte level -----------------------------------------------------
    def r1(self):
        return 0x01 if self.idle else 0x00

    def byte(self, b):
        if self.rx_data is not None:
            self.rx_byte(b)
            return
        if not self.cmd:
            if b & 0xC0 != 0x40:
                return
        self.cmd.append(b)
        if len(self.cmd) == 6:
            c, self.cmd = self.cmd, []
            self.command(c[0] & 0x3F, (c[1] << 24) | (c[2] << 16) | (c[3] << 8) | c[4], c[5])

    def respond(self, *bs):
        self.out += [0xFF] + list(bs)     # Ncr = 1 byte

    def command(self, n, arg, crc):
        app, self.app = self.app, False
        self.log.append(('ACMD' if app else 'CMD') + str(n))
        if n == 0:
            if crc != 0x95:
                self.respond(0x09)        # CRC error (CRC is checked for CMD0)
                return
            self.spi = True
            self.idle = True
            self.respond(0x01)
            return
        if not self.spi:
            return
        if n == 8:
            if not self.sdhc:
                self.respond(0x05)
                return
            self.respond(0x01 if self.idle else 0x00, 0x00, 0x00, (arg >> 8) & 0x0F, arg & 0xFF)
        elif n == 55:
            self.app = True
            self.respond(self.r1())
        elif n == 41 and app:
            if self.acmd41_busy > 0:
                self.acmd41_busy -= 1
            else:
                self.idle = False
            self.respond(self.r1())
        elif n == 58:
            ocr = 0x80FF8000 | (0x40000000 if self.sdhc else 0)
            self.respond(self.r1(), ocr >> 24, (ocr >> 16) & 0xFF, (ocr >> 8) & 0xFF, ocr & 0xFF)
        elif n == 16:
            self.respond(self.r1() | (0 if arg == 512 else 0x40))
        elif n == 17:
            addr = self.addr(arg)
            if self.idle or addr is None:
                self.respond(self.r1() | 0x40)
                return
            self.reads += 1
            blk = self.image[addr:addr + 512]
            self.respond(0x00, 0xFF, 0xFF, 0xFE, *blk, 0x12, 0x34)
        elif n == 24:
            addr = self.addr(arg)
            if self.idle or addr is None:
                self.respond(self.r1() | 0x40)
                return
            self.respond(0x00)
            self.rx_data = []
            self.rx_addr = addr
        else:
            self.respond(self.r1() | 0x04)  # illegal command

    def addr(self, arg):
        a = arg * 512 if self.sdhc else arg
        if a % 512 or a + 512 > len(self.image):
            return None
        return a

    def rx_byte(self, b):
        d = self.rx_data
        if not d:
            if b == 0xFE:
                d.append(b)
            return
        d.append(b)
        if len(d) == 1 + 512 + 2:
            self.image[self.rx_addr:self.rx_addr + 512] = bytes(d[1:513])
            self.writes += 1
            self.rx_data = None
            self.out += [0x05, 0x00, 0x00, 0x00, 0xFF]   # accepted, busy, ready


# ---------------------------------------------------------------------------
# PS/2 mouse
# ---------------------------------------------------------------------------
class Ps2Mouse:
    """Placeholder: a PS/2 line pair with nothing attached (both lines idle
    high).  The mouse model replaces it."""

    def clk(self, t):
        return 1

    def data(self, t):
        return 1

    def host(self, t, clk, data):
        pass


# ---------------------------------------------------------------------------
# The shared port
# ---------------------------------------------------------------------------
class SharedPort:
    def __init__(self, latch=0x00):
        self.latch = latch                # a 74HC574 powers up random; 00 here
        self.keys = set()                 # (col, row) held down
        self.pads = [SnesPad(), SnesPad()]
        self.sd = None
        self.mouse = None
        self.writes = 0
        self.reads = 0

    # lines from the latch
    def col(self):
        c = self.latch >> 4
        return c if c < 8 else None

    def rows(self, t):
        r = 0xFF
        c = self.col()
        if c is not None:
            for (kc, kr) in self.keys:
                if kc == c:
                    r &= ~(1 << kr)
        if self.sd is not None and not self.sd.miso():
            r &= ~0x80
        if not self.ps2_data(t):
            r &= ~0x40
        if not self.ps2_clk(t):
            r &= ~0x20
        return r & 0xFF

    def ps2_clk(self, t):
        host = (self.latch >> 2) & 1
        dev = self.mouse.clk(t) if self.mouse is not None else 1
        return host & dev

    def ps2_data(self, t):
        host = (self.latch >> 3) & 1
        dev = self.mouse.data(t) if self.mouse is not None else 1
        return host & dev

    def read(self, ad, t):
        self.reads += 1
        if ad & 1:
            return (self.pads[0].data() << 7) | (self.pads[1].data() << 6) | 0x3F
        return self.rows(t)

    def write(self, ad, v, t):
        self.writes += 1
        old, self.latch = self.latch, v & 0xFF
        sck, mosi, cs = v & 1, (v >> 1) & 1, (v >> 2) & 1
        rising = sck and not (old & 1)
        falling = (not sck) and (old & 1)
        for p in self.pads:
            p.lines(sck, mosi, rising)
        if self.sd is not None:
            # the latch changes all bits together; /CS first when it falls,
            # last when it rises (the card ignores a clock edge at the same
            # moment as /CS rising)
            if not cs:
                self.sd.set_cs(0)
            if rising or falling:
                self.sd.edge(rising, mosi)
            if cs:
                self.sd.set_cs(1)
        if self.mouse is not None:
            self.mouse.host(t, (v >> 2) & 1, (v >> 3) & 1)
