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
    """A PS/2 mouse, stepped in DT time steps (5 us) as the host's lines
    change.  The host side is the port latch: host(t, clk, data) gives the
    host's own drive at time t (1 = released); clk(t) and data(t) are the
    mouse's own drive (1 = released).  The bus line is the AND of both.

    Device to host: the mouse waits for CLK and DATA released for 50 us
    (plus `latency`), then sends a chunk (one reply, or one 3-byte packet)
    as 11-bit frames: start 0, 8 data bits LSB first, odd parity, stop 1.
    It changes DATA while CLK is high and the host reads it while CLK is
    low.  If the host pulls CLK low before a frame's 11th clock falls, the
    mouse aborts and sends the whole chunk again later.

    Host to device: the host holds CLK low (at least 100 us), pulls DATA low
    and releases CLK.  The mouse clocks in 8 data bits, parity and the stop
    bit (it reads DATA on rising CLK), pulls DATA low for one more clock to
    acknowledge, then answers.  Commands: FF reset (FA, then AA 00 after
    `bat_ms`), F6 defaults, F4 / F5 reporting on / off, F3 n sample rate,
    E8 n resolution, F2 device ID (FA 00), others FE (resend).  A parity
    error gets FE.

    Stream mode: while reporting is on, movement (move()) and button
    changes are sent as 3-byte packets, at most one per sample period.  The
    counters keep adding up while the host holds the mouse off.  Y is
    positive upward, as on the wire."""

    DT = us(5)

    def __init__(self, latency_us=100, bat_ms=300, half_us=40):
        self.latency = us(latency_us)
        self.bat = us(bat_ms * 1000)
        self.half = us(half_us)           # CLK half period
        self.t = 0                        # time the model has reached
        self.hclk = 1                     # host drive
        self.hdata = 1
        self.dclk = 1                     # mouse drive
        self.ddata = 1
        self.free_since = 0               # time both lines were released
        self.rts_since = None             # time CLK released with DATA low
        self.inhibit_since = None
        self.state = 'idle'
        self.queue = []                   # chunks waiting to be sent
        self.chunk = None                 # chunk being sent
        self.byte_i = 0
        self.frame = []                   # bits of the frame being sent
        self.bit_i = 0
        self.phase_end = 0
        self.rx_bits = []
        self.arg_for = None               # command waiting for its argument
        self.reporting = False
        self.rate = 100
        self.next_sample = 0
        self.bat_at = None                # time the reset's AA 00 is queued
        self.dx = self.dy = 0
        self.buttons = 0
        self.sent_buttons = 0
        self.received = []                # commands and arguments from the host
        self.sent = []                    # bytes sent (completed frames)
        self.aborts = 0

    # --- interface ------------------------------------------------------
    def clk(self, t):
        self.advance(t)
        return self.dclk

    def data(self, t):
        self.advance(t)
        return self.ddata

    def host(self, t, clk, data):
        self.advance(t)
        if (clk, data) != (self.hclk, self.hdata):
            self.hclk, self.hdata = clk, data
            if clk and data:
                self.free_since = t
            if clk and not data:
                self.rts_since = t
            if not clk and self.inhibit_since is None:
                self.inhibit_since = t
            if clk:
                self.inhibit_since = None if data else self.inhibit_since

    def move(self, dx=0, dy=0, buttons=None):
        self.dx += dx
        self.dy += dy
        if buttons is not None:
            self.buttons = buttons

    # --- the device -----------------------------------------------------
    def bus_clk(self):
        return self.hclk & self.dclk

    def bus_data(self):
        return self.hdata & self.ddata

    def advance(self, t):
        while self.t + self.DT <= t:
            self.t += self.DT
            self.step(self.t)

    @staticmethod
    def frame_bits(b):
        bits = [0] + [(b >> i) & 1 for i in range(8)]
        bits.append(1 ^ (sum(bits[1:]) & 1))   # odd parity
        bits.append(1)
        return bits

    def respond(self, *bs):
        self.queue.append(list(bs))

    def command(self, b):
        self.received.append(b)
        if self.arg_for is not None:
            cmd, self.arg_for = self.arg_for, None
            if cmd == 0xF3:
                self.rate = b or 100
            self.respond(0xFA)
            return
        if b == 0xFF:
            self.reporting = False
            self.queue = []
            self.respond(0xFA)
            self.bat_at = self.t + self.bat
        elif b in (0xF6, 0xF5):
            self.reporting = False
            self.respond(0xFA)
        elif b == 0xF4:
            self.reporting = True
            self.respond(0xFA)
        elif b in (0xF3, 0xE8):
            self.arg_for = b
            self.respond(0xFA)
        elif b == 0xF2:
            self.respond(0xFA, 0x00)
        else:
            self.respond(0xFE)

    def packet(self):
        def clamp(v):
            return max(-256, min(255, v))
        dx, dy = clamp(self.dx), clamp(self.dy)
        ovx = self.dx != dx
        ovy = self.dy != dy
        self.dx = self.dy = 0
        self.sent_buttons = self.buttons
        b0 = (self.buttons & 7) | 0x08 | (0x10 if dx < 0 else 0) | (0x20 if dy < 0 else 0) \
            | (0x40 if ovx else 0) | (0x80 if ovy else 0)
        return [b0, dx & 0xFF, dy & 0xFF]

    def step(self, t):
        if self.bat_at is not None and t >= self.bat_at:
            self.bat_at = None
            self.respond(0xAA, 0x00)
        if self.state == 'idle':
            if self.reporting and t >= self.next_sample and not self.queue \
                    and (self.dx or self.dy or self.buttons != self.sent_buttons):
                self.queue.append('packet')
                self.next_sample = t + us(1_000_000 // self.rate)
            if self.hclk and not self.hdata:
                if self.rts_since is not None and t - self.rts_since >= us(50):
                    self.state = 'rx'
                    self.rx_bits = []
                    self.dclk = 0                 # first clock low
                    self.phase_end = t + self.half
                return
            if self.hclk and self.hdata and self.queue and \
                    t - self.free_since >= us(50) + self.latency:
                c = self.queue.pop(0)
                self.chunk = self.packet() if c == 'packet' else c
                self.byte_i = 0
                self.start_frame(t)
            return
        if self.state == 'tx':
            if not self.hclk and (self.bit_i < 10 or self.dclk):
                # the host pulled CLK low before the 11th clock fell:
                # abort and send the whole chunk again later
                self.aborts += 1
                self.queue.insert(0, self.chunk)
                self.dclk = self.ddata = 1
                self.state = 'idle'
                return
            if t < self.phase_end:
                return
            if self.dclk:                         # high half done: clock low
                self.dclk = 0
                self.phase_end = t + self.half
                return
            self.dclk = 1                         # low half done: next bit
            self.bit_i += 1
            if self.bit_i < 11:
                self.ddata = self.frame[self.bit_i]
                self.phase_end = t + self.half
                return
            self.ddata = 1
            self.sent.append(self.chunk[self.byte_i])
            self.byte_i += 1
            if self.byte_i < len(self.chunk):
                self.state = 'gap'
                self.phase_end = t + us(100)
            else:
                self.state = 'idle'
                self.free_since = t
            return
        if self.state == 'gap':
            if not self.hclk:
                self.aborts += 1
                self.queue.insert(0, self.chunk)
                self.state = 'idle'
                return
            if t >= self.phase_end:
                self.start_frame(t)
            return
        if self.state == 'rx':
            if t < self.phase_end:
                return
            if not self.dclk:                     # low half done: rising edge, read
                self.dclk = 1
                self.phase_end = t + self.half
                if len(self.rx_bits) < 10:
                    self.rx_bits.append(self.bus_data())
                    return
                # acknowledge clock done
                self.ddata = 1
                self.state = 'idle'
                self.free_since = t
                d = self.rx_bits
                b = sum(d[i] << i for i in range(8))
                if d[9] != 1 or (sum(d[:9]) & 1) != 1:
                    self.respond(0xFE)
                else:
                    self.command(b)
                return
            self.dclk = 0                         # high half done: clock low
            self.phase_end = t + self.half
            if len(self.rx_bits) == 10:
                self.ddata = 0                    # acknowledge
            return

    def start_frame(self, t):
        self.state = 'tx'
        self.frame = self.frame_bits(self.chunk[self.byte_i])
        self.bit_i = 0
        self.ddata = self.frame[0]
        self.dclk = 1
        self.phase_end = t + self.half


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
