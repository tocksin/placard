#!/usr/bin/env python3
"""
io_devices.py - models of the shared port at x5200 and the devices on it,
for placard_sim.py (see docs/IO.md)

    port = SharedPort()                 # latch, PS/2 receiver, pads, SD, mouse, keyboard
    port.pads[0].buttons = 0x0001       # pad 1: B held (bit n = button n)
    port.sd = SdCard(image)             # an SD card holding image (bytes)
    port.mouse = Ps2Mouse()             # a PS/2 mouse (the upper socket)
    port.kbd = Ps2Keyboard()            # a PS/2 keyboard (the lower socket)
    cpu = Cpu(mem, rom=rom, io=port)

    slots = Slots()                     # the four expansion slots
    slots.cards[0] = ExpansionCard(rom) # a card in slot 1
    cpu = Cpu(mem, rom=rom, slots=slots)

The CPU calls port.read(addr, t) for a read of x5200-x52FF and
port.write(addr, value, t) for a write; t is the CPU clock count, used by
the PS/2 devices (25.175 MHz clocks).

Port latch (write any x52xx), five registers in the port PLD (rev 04):
    bit 0  SCK / pad CLOCK          bit 1  MOSI / pad LATCH
    bit 2  SD /CS; 0 also holds the mouse's CLK line low (Schottky diode)
    bit 3  0 holds the shared PS/2 DATA line low (Schottky diode)
    bit 4  0 holds the PS/2 keyboard's CLK line low (Schottky diode)
    bits 7:5 are not stored
Port read:
    x5200: D7 = SD MISO, D5 = RXCLK (the two PS/2 clock lines diode-ORed,
        so the free device's clock); the rest reads 1 (pull-ups)
    x5201: D7 = pad 1 DATA, D6 = pad 2 DATA, D5 = RXCLK
    x5202: the PS/2 receiver's byte;  x5203: D7 = 0 while a byte is ready
    a write to x5202 or x5203 re-arms the receiver (and loads the latch)
The PS/2 receiver (Ps2Receiver, the ATF22V10_PS2.pld equations) clocks on
every rising edge of RXCLK, from a device's clock or from a clock line let
go by the latch or the receiver's own inhibit.  After the 11th clock of a
byte it pulls both clock lines low (inhibit) until re-armed.
The mouse and the PS/2 keyboard share the DATA line: SharedPort counts
moments both drive it (collisions), which the driver must never cause.

Date: 10/25/2026
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
    positive upward, as on the wire.

    Between the bytes of a packet (the gap) a host that holds CLK low only
    holds the mouse: it goes on with the next byte 50 us after CLK is let
    go, as a mouse does for a host (like the PS/2 receiver PLD, or the PC's
    8042) that holds it off after every byte.  A request to send in the gap
    drops the rest of the packet.

    on_rise(device, t) is called just before every rising edge of the
    device's own CLK, with DATA still at the bit being sent: the shared
    port's receiver samples it there."""

    DT = us(5)

    def __init__(self, latency_us=100, bat_ms=300, half_us=40):
        self.on_rise = None               # called (device, t) just before each rising edge of its CLK
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
        self.holds = 0                    # steps spent held between a packet's bytes
        self.peer = None                  # the other device on the shared DATA line

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
        peer = self.peer.ddata if self.peer is not None else 1
        return self.hdata & self.ddata & peer

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
            self.rise(t)
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
            if not self.hclk:                     # held: go on 50 us after it is let go
                self.phase_end = max(self.phase_end, t + us(50))
                self.holds += 1
                return
            if not self.hdata:                    # a request to send: the packet is dropped
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
                self.rise(t)
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

    def rise(self, t):
        if self.on_rise is not None:
            self.on_rise(self, t)


class Ps2Keyboard(Ps2Mouse):
    """A PS/2 keyboard (scan code set 2), with the same line handling as
    Ps2Mouse.  Each byte is its own chunk: a byte cut off by the host is
    sent again by itself, as a keyboard does.

    press(code) / release(code) queue a key's make / break bytes; code is
    a set 2 code, with 0x100 added for an E0 key (0x175 = Up).  pause()
    queues the Pause key's 8 bytes.  Commands: FF reset (FA, then AA after
    `bat_ms`), ED n lights (FA, FA; self.leds = n), EE echo, F2 ID
    (FA AB 83), F3 n, F4, F5, F6 (FA), others FE.  `answers` = False is a
    keyboard that is still testing itself (or unplugged): it neither
    clocks nor sends."""

    def __init__(self, latency_us=150, bat_ms=300, half_us=40):
        Ps2Mouse.__init__(self, latency_us=latency_us, bat_ms=bat_ms, half_us=half_us)
        self.leds = 0
        self.answers = True

    def _queue(self, bs):
        for b in bs:
            self.queue.append([b])

    def press(self, code):
        self._queue(([0xE0] if code & 0x100 else []) + [code & 0xFF])

    def release(self, code):
        self._queue(([0xE0] if code & 0x100 else []) + [0xF0, code & 0xFF])

    def pause(self):
        self._queue([0xE1, 0x14, 0x77, 0xE1, 0xF0, 0x14, 0xF0, 0x77])

    def respond(self, *bs):
        self._queue(bs)

    def command(self, b):
        self.received.append(b)
        if self.arg_for is not None:
            cmd, self.arg_for = self.arg_for, None
            if cmd == 0xED:
                self.leds = b
            self.respond(0xFA)
            return
        if b == 0xFF:
            self.queue = []
            self.respond(0xFA)
            self.bat_at = self.t + self.bat
        elif b in (0xED, 0xF3):
            self.arg_for = b
            self.respond(0xFA)
        elif b == 0xEE:
            self.respond(0xEE)
        elif b == 0xF2:
            self.respond(0xFA, 0xAB, 0x83)
        elif b in (0xF4, 0xF5, 0xF6):
            self.respond(0xFA)
        else:
            self.respond(0xFE)

    def step(self, t):
        if self.bat_at is not None and t >= self.bat_at:
            self.bat_at = None
            self.respond(0xAA)            # a keyboard sends AA only
        if not self.answers:
            return                        # testing itself: lines left alone
        self.reporting = False            # no mouse packets
        Ps2Mouse.step(self, t)


# ---------------------------------------------------------------------------
# The PS/2 receiver PLD
# ---------------------------------------------------------------------------
class Ps2Receiver:
    """ATF22V10_PS2.pld: N1..N8 shift in the inverse of DATA on each rising
    edge of RXCLK while A = B = 0; the start bit reaching N8 sets B, then
    A; in state A = 1, B = 0 (after the 11th clock) the B pin pulls both
    clock lines low and a read of x5203 shows D7 = 0, ready.  A write to
    x5202/x5203 resets everything."""

    def __init__(self):
        self.n = [0] * 8                  # n[0] = N1 (newest) ... n[7] = N8
        self.a = 0
        self.b = 0
        self.edges = 0
        self.bytes = 0                    # bytes that became ready

    def reset(self):
        self.n = [0] * 8
        self.a = self.b = 0

    def ready(self):
        return 1 if (self.a and not self.b) else 0     # the last state (rev 02)

    def inhibit(self):
        return 1 if (self.a and not self.b) else 0

    def byte(self):
        # the pins are !Nk: d7 = !N1 ... d0 = !N8
        return sum((1 - self.n[7 - i]) << i for i in range(8))

    def edge(self, data):
        self.edges += 1
        a, b, n = self.a, self.b, self.n
        if not a and not b:
            self.n = [1 - data] + n[:7]
        self.b = 1 if (not a and n[7]) or (not a and b) else 0
        self.a = 1 if (a or b) else 0
        if self.a and not a:
            self.bytes += 1


# ---------------------------------------------------------------------------
# The shared port
# ---------------------------------------------------------------------------
class SharedPort:
    def __init__(self, latch=0xEB):
        self.latch = latch                # the port PLD's registers clear: rest value EB
        self.pads = [SnesPad(), SnesPad()]
        self.sd = None
        self.mouse = None
        self.kbd = None                   # a PS/2 keyboard (Ps2Keyboard) in the lower socket
        self.rx = Ps2Receiver()
        self.writes = 0
        self.reads = 0
        self.collisions = 0               # moments both devices drive DATA
        self.t = 0

    def _link(self):
        for dev in (self.mouse, self.kbd):
            if dev is not None and dev.on_rise is None:
                dev.on_rise = self._rise
        if self.mouse is not None and self.kbd is not None:
            self.mouse.peer, self.kbd.peer = self.kbd, self.mouse

    def _advance(self, t):
        self._link()
        self.t = t
        for dev in (self.mouse, self.kbd):
            if dev is not None:
                dev.advance(t)

    # --- the lines ------------------------------------------------------
    def host_clk(self, dev):
        """the host's drive of a device's clock line: the latch bit and the
        receiver's inhibit"""
        bit = 2 if dev is self.mouse else 4
        return ((self.latch >> bit) & 1) & (1 - self.rx.inhibit())

    def clk_line(self, dev, bit):
        """a clock line's level: an absent device leaves it to the host"""
        host = ((self.latch >> bit) & 1) & (1 - self.rx.inhibit())
        return host & (dev.dclk if dev is not None else 1)

    def rxclk(self):
        return self.clk_line(self.mouse, 2) | self.clk_line(self.kbd, 4)

    def ps2_data(self):
        host = (self.latch >> 3) & 1
        m = self.mouse.ddata if self.mouse is not None else 1
        k = self.kbd.ddata if self.kbd is not None else 1
        if not m and not k:
            self.collisions += 1
        return host & m & k

    def _push(self, t):
        """give the devices the host's drive of their lines"""
        data = (self.latch >> 3) & 1
        if self.mouse is not None:
            self.mouse.host(t, self.host_clk(self.mouse), data)
        if self.kbd is not None:
            self.kbd.host(t, self.host_clk(self.kbd), data)

    def _rise(self, dev, t):
        """a device's CLK rises: an RXCLK edge unless the other line holds
        the OR high"""
        other = self.clk_line(self.kbd, 4) if dev is self.mouse else self.clk_line(self.mouse, 2)
        bit = 2 if dev is self.mouse else 4
        if other == 0 and ((self.latch >> bit) & 1) and not self.rx.inhibit():
            self.rx.edge(self.ps2_data())
            self._push(t)                 # the inhibit may have come on

    # --- the CPU --------------------------------------------------------
    def read(self, ad, t):
        self.reads += 1
        self._advance(t)
        rx = self.rxclk()
        if (ad & 3) == 0:
            miso = self.sd.miso() if self.sd is not None else 1
            return 0x5F | (miso << 7) | (rx << 5)
        if (ad & 3) == 1:
            return (self.pads[0].data() << 7) | (self.pads[1].data() << 6) | (rx << 5) | 0x1F
        if (ad & 3) == 2:
            return self.rx.byte()
        return ((1 - self.rx.ready()) << 7) | 0x7F     # D7 = 0 while a byte is ready

    def write(self, ad, v, t):
        self.writes += 1
        self._advance(t)
        before = self.rxclk()
        old, self.latch = self.latch, v & 0x1F | 0xE0
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
        if ad & 2:
            self.rx.reset()               # re-arm: the inhibit goes too
        if not before and self.rxclk():
            self.rx.edge(self.ps2_data())  # a clock line let go: one edge
        self._push(t)


# ---------------------------------------------------------------------------
# expansion slots (docs/EXPANSION.md)
# ---------------------------------------------------------------------------
SLOT_BASE = (0x5100, 0x5300, 0x5180, 0x5380)     # slots 1-4


def card_rom(card_id, code, bad_sum=False):
    """the 96-byte boot area of a card: "PLC", card ID, code length,
    checksum (the sum of the code bytes), the code, then FF"""
    s = sum(code) & 0xFF
    if bad_sum:
        s ^= 0x5A
    rom = [0x50, 0x4C, 0x43, card_id, len(code), s] + list(code)
    return rom + [0xFF] * (0x60 - len(rom))


class ExpansionCard:
    """a card: offsets 00-5F read its boot area (ROM), 60-7F are registers
    (written values read back)"""

    def __init__(self, rom):
        self.rom = list(rom) + [0xFF] * (0x60 - len(rom))
        self.regs = [0xFF] * 0x20
        self.writes = []

    def read(self, off):
        return self.rom[off] if off < 0x60 else self.regs[off - 0x60]

    def write(self, off, v):
        self.writes.append((off, v))
        if off >= 0x60:
            self.regs[off - 0x60] = v


class Slots:
    """the four slots: /EXP1 is x51xx (slot 1 at A7 = 0, slot 3 at A7 = 1),
    /EXP2 is x53xx (slots 2 and 4).  An empty slot reads FF (the pull-ups
    on the read bus)."""

    def __init__(self):
        self.cards = [None, None, None, None]

    def card(self, ad):
        n = (1 if ad & 0x0200 else 0) + (2 if ad & 0x80 else 0)
        return self.cards[n]

    def read(self, ad):
        c = self.card(ad)
        return c.read(ad & 0x7F) if c is not None else 0xFF

    def write(self, ad, v):
        c = self.card(ad)
        if c is not None:
            c.write(ad & 0x7F, v)

