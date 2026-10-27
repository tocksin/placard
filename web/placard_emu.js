/*
 * placard_emu.js - the PLACARD computer at the instruction and bus level,
 * for the web page (index.html) and for node (test_web_emu.py)
 *
 * A JavaScript port of src/scripts/placard_sim.py (Cpu with the ROM/RAM map
 * and the video stall clocks), src/scripts/io_devices.py (the shared port,
 * PS/2 receiver, keyboard, mouse, SNES pads, SD card) and
 * src/scripts/sdimage.py (FAT16 card images).  Every clock is a 25.175 MHz
 * board clock: the CPU's own clocks, the clocks the video takes from it
 * (mode byte, audio sample and pixel reads) and, at power-up, the time the
 * cartridge takes to copy its EEPROM into its SRAM.  The PS/2 devices, the
 * SD card and the pads see the port lines change at the clock the CPU
 * changes them, as in the Python models.
 *
 * The video is drawn one line at a time (at the end of each line, from the
 * RAM as it is then) and the audio DAC takes one sample per line, read from
 * x5DF3-x5FFF at the clock the audio slot reads it.
 *
 * Generated: 10/27/2026
 */
(function (root) {
'use strict';

const CPU_HZ = 25175000;
const LINE = 800;                 // clocks per line
const LINES = 525;                // lines per frame (V = 499-1023)
const FRAME = LINE * LINES;
const MODE_BASE = 0x5A20;         // row 0's mode byte
const LINE_HZ = CPU_HZ / LINE;    // 31.469 kHz, the audio sample rate

function pyRound(x) {             // Python's round(): halves to even
    const f = Math.floor(x), d = x - f;
    if (d > 0.5) return f + 1;
    if (d < 0.5) return f;
    return (f % 2 === 0) ? f : f + 1;
}

function us(t) {                  // microseconds to CPU clocks
    return pyRound(t * CPU_HZ / 1000000);
}

// ---------------------------------------------------------------------------
// SNES pad
// ---------------------------------------------------------------------------
// buttons: bit n = 1 while button n is held: 0 B, 1 Y, 2 Select, 3 Start,
// 4 Up, 5 Down, 6 Left, 7 Right, 8 A, 9 X, 10 L, 11 R
class SnesPad {
    constructor(connected) {
        this.buttons = 0;
        this.connected = connected !== false;
        this.shift = 0;
        this.count = 16;
        this.clocks = 0;
    }
    load() {
        this.shift = ((~this.buttons) & 0x0FFF) | 0xF000;
        this.count = 0;
    }
    data() {
        if (!this.connected) return 1;
        if (this.count >= 16) return 0;
        return (this.shift >> this.count) & 1;
    }
    lines(clock, latch, rising) {
        if (latch) {
            this.load();
        } else if (rising) {
            this.clocks++;
            if (this.count < 16) this.count++;
        }
    }
}

// ---------------------------------------------------------------------------
// SD card (SPI mode)
// ---------------------------------------------------------------------------
class SdCard {
    constructor(image, sdhc, acmd41Busy) {
        this.image = image || new Uint8Array(512 * 64);
        this.sdhc = sdhc !== false;
        this.acmd41Busy = acmd41Busy === undefined ? 3 : acmd41Busy;
        this.cs = 1;
        this.spi = false;
        this.idle = true;
        this.app = false;
        this.inbyte = 0;
        this.bits = 0;
        this.out = [];
        this.cur = 0xFF;
        this.misoBit = 1;
        this.cmd = [];
        this.rxData = null;
        this.rxAddr = 0;
        this.preClocks = 0;
        this.reads = 0;
        this.writes = 0;
        this.onWrite = null;      // called after a block is written
    }
    miso() { return this.cs ? 1 : this.misoBit; }
    setCs(cs) {
        if (cs === this.cs) return;
        this.cs = cs;
        this.bits = 0;
        this.inbyte = 0;
    }
    edge(rising, mosi) {
        if (this.cs) {
            if (rising) this.preClocks++;
            return;
        }
        if (rising) {
            this.inbyte = ((this.inbyte << 1) | mosi) & 0xFF;
            this.bits++;
            if (this.bits === 8) {
                this.bits = 0;
                this.cur = this.out.length ? this.out.shift() : 0xFF;
                this.byte(this.inbyte);
            }
        } else {
            this.misoBit = (this.cur >> (7 - this.bits)) & 1;
        }
    }
    r1() { return this.idle ? 0x01 : 0x00; }
    byte(b) {
        if (this.rxData !== null) {
            this.rxByte(b);
            return;
        }
        if (!this.cmd.length && (b & 0xC0) !== 0x40) return;
        this.cmd.push(b);
        if (this.cmd.length === 6) {
            const c = this.cmd;
            this.cmd = [];
            this.command(c[0] & 0x3F, ((c[1] << 24) | (c[2] << 16) | (c[3] << 8) | c[4]) >>> 0, c[5]);
        }
    }
    respond(bs) {
        this.out.push(0xFF);
        for (const b of bs) this.out.push(b);
    }
    command(n, arg, crc) {
        const app = this.app;
        this.app = false;
        if (n === 0) {
            if (crc !== 0x95) { this.respond([0x09]); return; }
            this.spi = true;
            this.idle = true;
            this.respond([0x01]);
            return;
        }
        if (!this.spi) return;
        if (n === 8) {
            if (!this.sdhc) { this.respond([0x05]); return; }
            this.respond([this.idle ? 1 : 0, 0, 0, (arg >>> 8) & 0x0F, arg & 0xFF]);
        } else if (n === 55) {
            this.app = true;
            this.respond([this.r1()]);
        } else if (n === 41 && app) {
            if (this.acmd41Busy > 0) this.acmd41Busy--;
            else this.idle = false;
            this.respond([this.r1()]);
        } else if (n === 58) {
            const ocr = (0x80FF8000 | (this.sdhc ? 0x40000000 : 0)) >>> 0;
            this.respond([this.r1(), ocr >>> 24, (ocr >>> 16) & 0xFF, (ocr >>> 8) & 0xFF, ocr & 0xFF]);
        } else if (n === 16) {
            this.respond([this.r1() | (arg === 512 ? 0 : 0x40)]);
        } else if (n === 17) {
            const addr = this.addr(arg);
            if (this.idle || addr === null) { this.respond([this.r1() | 0x40]); return; }
            this.reads++;
            const blk = this.image.subarray(addr, addr + 512);
            this.out.push(0xFF, 0x00, 0xFF, 0xFF, 0xFE);
            for (let i = 0; i < 512; i++) this.out.push(blk[i]);
            this.out.push(0x12, 0x34);
        } else if (n === 24) {
            const addr = this.addr(arg);
            if (this.idle || addr === null) { this.respond([this.r1() | 0x40]); return; }
            this.respond([0x00]);
            this.rxData = [];
            this.rxAddr = addr;
        } else {
            this.respond([this.r1() | 0x04]);
        }
    }
    addr(arg) {
        const a = this.sdhc ? arg * 512 : arg;
        if (a % 512 || a + 512 > this.image.length) return null;
        return a;
    }
    rxByte(b) {
        const d = this.rxData;
        if (!d.length) {
            if (b === 0xFE) d.push(b);
            return;
        }
        d.push(b);
        if (d.length === 1 + 512 + 2) {
            this.image.set(d.slice(1, 513), this.rxAddr);
            this.writes++;
            this.rxData = null;
            this.out.push(0x05, 0x00, 0x00, 0x00, 0xFF);
            if (this.onWrite) this.onWrite(this.rxAddr);
        }
    }
}

// ---------------------------------------------------------------------------
// PS/2 mouse (io_devices.Ps2Mouse), stepped in 5 us steps
// ---------------------------------------------------------------------------
const DT = us(5);

class Ps2Mouse {
    constructor(latencyUs, batMs, halfUs) {
        this.onRise = null;
        this.latency = us(latencyUs === undefined ? 100 : latencyUs);
        this.bat = us((batMs === undefined ? 300 : batMs) * 1000);
        this.half = us(halfUs === undefined ? 40 : halfUs);
        this.t = 0;
        this.hclk = 1;
        this.hdata = 1;
        this.dclk = 1;
        this.ddata = 1;
        this.freeSince = 0;
        this.rtsSince = null;
        this.inhibitSince = null;
        this.state = 'idle';
        this.queue = [];
        this.chunk = null;
        this.byteI = 0;
        this.frame = [];
        this.bitI = 0;
        this.phaseEnd = 0;
        this.rxBits = [];
        this.argFor = null;
        this.reporting = false;
        this.rate = 100;
        this.nextSample = 0;
        this.batAt = null;
        this.dx = 0;
        this.dy = 0;
        this.buttons = 0;
        this.sentButtons = 0;
        this.received = [];
        this.sent = [];
        this.aborts = 0;
        this.holds = 0;
        this.peer = null;
    }
    clk(t) { this.advance(t); return this.dclk; }
    data(t) { this.advance(t); return this.ddata; }
    host(t, clk, data) {
        this.advance(t);
        if (clk !== this.hclk || data !== this.hdata) {
            this.hclk = clk;
            this.hdata = data;
            if (clk && data) this.freeSince = t;
            if (clk && !data) this.rtsSince = t;
            if (!clk && this.inhibitSince === null) this.inhibitSince = t;
            if (clk) this.inhibitSince = data ? null : this.inhibitSince;
        }
    }
    move(dx, dy, buttons) {
        this.dx += dx || 0;
        this.dy += dy || 0;
        if (buttons !== undefined && buttons !== null) this.buttons = buttons;
    }
    busData() {
        const peer = this.peer !== null ? this.peer.ddata : 1;
        return this.hdata & this.ddata & peer;
    }
    advance(t) {
        while (this.t + DT <= t) {
            this.t += DT;
            this.step(this.t);
        }
    }
    static frameBits(b) {
        const bits = [0];
        let ones = 0;
        for (let i = 0; i < 8; i++) {
            const v = (b >> i) & 1;
            bits.push(v);
            ones += v;
        }
        bits.push(1 ^ (ones & 1));
        bits.push(1);
        return bits;
    }
    respond(bs) { this.queue.push(bs.slice()); }
    command(b) {
        this.received.push(b);
        if (this.argFor !== null) {
            const cmd = this.argFor;
            this.argFor = null;
            if (cmd === 0xF3) this.rate = b || 100;
            this.respond([0xFA]);
            return;
        }
        if (b === 0xFF) {
            this.reporting = false;
            this.queue = [];
            this.respond([0xFA]);
            this.batAt = this.t + this.bat;
        } else if (b === 0xF6 || b === 0xF5) {
            this.reporting = false;
            this.respond([0xFA]);
        } else if (b === 0xF4) {
            this.reporting = true;
            this.respond([0xFA]);
        } else if (b === 0xF3 || b === 0xE8) {
            this.argFor = b;
            this.respond([0xFA]);
        } else if (b === 0xF2) {
            this.respond([0xFA, 0x00]);
        } else {
            this.respond([0xFE]);
        }
    }
    packet() {
        const clamp = (v) => Math.max(-256, Math.min(255, v));
        const dx = clamp(this.dx), dy = clamp(this.dy);
        const ovx = this.dx !== dx, ovy = this.dy !== dy;
        this.dx = this.dy = 0;
        this.sentButtons = this.buttons;
        const b0 = (this.buttons & 7) | 0x08 | (dx < 0 ? 0x10 : 0) | (dy < 0 ? 0x20 : 0)
            | (ovx ? 0x40 : 0) | (ovy ? 0x80 : 0);
        return [b0, dx & 0xFF, dy & 0xFF];
    }
    step(t) {
        if (this.batAt !== null && t >= this.batAt) {
            this.batAt = null;
            this.respond([0xAA, 0x00]);
        }
        if (this.state === 'idle') {
            if (this.reporting && t >= this.nextSample && !this.queue.length
                    && (this.dx || this.dy || this.buttons !== this.sentButtons)) {
                this.queue.push('packet');
                this.nextSample = t + us(Math.floor(1000000 / this.rate));
            }
            if (this.hclk && !this.hdata) {
                if (this.rtsSince !== null && t - this.rtsSince >= us(50)) {
                    this.state = 'rx';
                    this.rxBits = [];
                    this.dclk = 0;
                    this.phaseEnd = t + this.half;
                }
                return;
            }
            if (this.hclk && this.hdata && this.queue.length
                    && t - this.freeSince >= us(50) + this.latency) {
                const c = this.queue.shift();
                this.chunk = c === 'packet' ? this.packet() : c;
                this.byteI = 0;
                this.startFrame(t);
            }
            return;
        }
        if (this.state === 'tx') {
            if (!this.hclk && (this.bitI < 10 || this.dclk)) {
                this.aborts++;
                this.queue.unshift(this.chunk);
                this.dclk = this.ddata = 1;
                this.state = 'idle';
                return;
            }
            if (t < this.phaseEnd) return;
            if (this.dclk) {
                this.dclk = 0;
                this.phaseEnd = t + this.half;
                return;
            }
            this.dclk = 1;
            this.rise(t);
            this.bitI++;
            if (this.bitI < 11) {
                this.ddata = this.frame[this.bitI];
                this.phaseEnd = t + this.half;
                return;
            }
            this.ddata = 1;
            this.sent.push(this.chunk[this.byteI]);
            if (this.sent.length > 64) this.sent.shift();
            this.byteI++;
            if (this.byteI < this.chunk.length) {
                this.state = 'gap';
                this.phaseEnd = t + us(100);
            } else {
                this.state = 'idle';
                this.freeSince = t;
            }
            return;
        }
        if (this.state === 'gap') {
            if (!this.hclk) {
                this.phaseEnd = Math.max(this.phaseEnd, t + us(50));
                this.holds++;
                return;
            }
            if (!this.hdata) {
                this.state = 'idle';
                return;
            }
            if (t >= this.phaseEnd) this.startFrame(t);
            return;
        }
        if (this.state === 'rx') {
            if (t < this.phaseEnd) return;
            if (!this.dclk) {
                this.dclk = 1;
                this.rise(t);
                this.phaseEnd = t + this.half;
                if (this.rxBits.length < 10) {
                    this.rxBits.push(this.busData());
                    return;
                }
                this.ddata = 1;
                this.state = 'idle';
                this.freeSince = t;
                const d = this.rxBits;
                let b = 0, ones = 0;
                for (let i = 0; i < 8; i++) b |= d[i] << i;
                for (let i = 0; i < 9; i++) ones += d[i];
                if (d[9] !== 1 || (ones & 1) !== 1) this.respond([0xFE]);
                else this.command(b);
                return;
            }
            this.dclk = 0;
            this.phaseEnd = t + this.half;
            if (this.rxBits.length === 10) this.ddata = 0;
        }
    }
    startFrame(t) {
        this.state = 'tx';
        this.frame = Ps2Mouse.frameBits(this.chunk[this.byteI]);
        this.bitI = 0;
        this.ddata = this.frame[0];
        this.dclk = 1;
        this.phaseEnd = t + this.half;
    }
    rise(t) {
        if (this.onRise !== null) this.onRise(this, t);
    }
}

// a PS/2 keyboard, scan code set 2; code + 0x100 is an E0 key
class Ps2Keyboard extends Ps2Mouse {
    constructor(latencyUs, batMs, halfUs) {
        super(latencyUs === undefined ? 150 : latencyUs, batMs, halfUs);
        this.leds = 0;
        this.answers = true;
    }
    _queue(bs) { for (const b of bs) this.queue.push([b]); }
    press(code) { this._queue((code & 0x100 ? [0xE0] : []).concat([code & 0xFF])); }
    release(code) { this._queue((code & 0x100 ? [0xE0] : []).concat([0xF0, code & 0xFF])); }
    pause() { this._queue([0xE1, 0x14, 0x77, 0xE1, 0xF0, 0x14, 0xF0, 0x77]); }
    respond(bs) { this._queue(bs); }
    command(b) {
        this.received.push(b);
        if (this.argFor !== null) {
            const cmd = this.argFor;
            this.argFor = null;
            if (cmd === 0xED) this.leds = b;
            this.respond([0xFA]);
            return;
        }
        if (b === 0xFF) {
            this.queue = [];
            this.respond([0xFA]);
            this.batAt = this.t + this.bat;
        } else if (b === 0xED || b === 0xF3) {
            this.argFor = b;
            this.respond([0xFA]);
        } else if (b === 0xEE) {
            this.respond([0xEE]);
        } else if (b === 0xF2) {
            this.respond([0xFA, 0xAB, 0x83]);
        } else if (b === 0xF4 || b === 0xF5 || b === 0xF6) {
            this.respond([0xFA]);
        } else {
            this.respond([0xFE]);
        }
    }
    step(t) {
        if (this.batAt !== null && t >= this.batAt) {
            this.batAt = null;
            this.respond([0xAA]);
        }
        if (!this.answers) return;
        this.reporting = false;
        super.step(t);
    }
}

// ---------------------------------------------------------------------------
// The PS/2 receiver PLD (ATF22V10_PS2.pld)
// ---------------------------------------------------------------------------
class Ps2Receiver {
    constructor() {
        this.n = [0, 0, 0, 0, 0, 0, 0, 0];
        this.a = 0;
        this.b = 0;
        this.edges = 0;
        this.bytes = 0;
    }
    reset() {
        this.n = [0, 0, 0, 0, 0, 0, 0, 0];
        this.a = this.b = 0;
    }
    ready() { return (this.a && !this.b) ? 1 : 0; }
    inhibit() { return (this.a && !this.b) ? 1 : 0; }
    byte() {
        let v = 0;
        for (let i = 0; i < 8; i++) v |= (1 - this.n[7 - i]) << i;
        return v;
    }
    edge(data) {
        this.edges++;
        const a = this.a, b = this.b, n = this.n;
        if (!a && !b) this.n = [1 - data].concat(n.slice(0, 7));
        this.b = ((!a && n[7]) || (!a && b)) ? 1 : 0;
        this.a = (a || b) ? 1 : 0;
        if (this.a && !a) this.bytes++;
    }
}

// ---------------------------------------------------------------------------
// The shared port at x5200
// ---------------------------------------------------------------------------
class SharedPort {
    constructor(latch) {
        this.latch = latch === undefined ? 0xEB : latch;
        this.pads = [new SnesPad(), new SnesPad()];
        this.sd = null;
        this.mouse = null;
        this.kbd = null;
        this.rx = new Ps2Receiver();
        this.writes = 0;
        this.reads = 0;
        this.collisions = 0;
        this.t = 0;
        this._rise = this._rise.bind(this);
    }
    _link() {
        for (const dev of [this.mouse, this.kbd]) {
            if (dev !== null && dev.onRise === null) dev.onRise = this._rise;
        }
        if (this.mouse !== null && this.kbd !== null) {
            this.mouse.peer = this.kbd;
            this.kbd.peer = this.mouse;
        }
    }
    _advance(t) {
        this._link();
        this.t = t;
        if (this.mouse !== null) this.mouse.advance(t);
        if (this.kbd !== null) this.kbd.advance(t);
    }
    hostClk(dev) {
        const bit = dev === this.mouse ? 2 : 4;
        return ((this.latch >> bit) & 1) & (1 - this.rx.inhibit());
    }
    clkLine(dev, bit) {
        const host = ((this.latch >> bit) & 1) & (1 - this.rx.inhibit());
        return host & (dev !== null ? dev.dclk : 1);
    }
    rxclk() { return this.clkLine(this.mouse, 2) | this.clkLine(this.kbd, 4); }
    ps2Data() {
        const host = (this.latch >> 3) & 1;
        const m = this.mouse !== null ? this.mouse.ddata : 1;
        const k = this.kbd !== null ? this.kbd.ddata : 1;
        if (!m && !k) this.collisions++;
        return host & m & k;
    }
    _push(t) {
        const data = (this.latch >> 3) & 1;
        if (this.mouse !== null) this.mouse.host(t, this.hostClk(this.mouse), data);
        if (this.kbd !== null) this.kbd.host(t, this.hostClk(this.kbd), data);
    }
    _rise(dev, t) {
        const other = dev === this.mouse ? this.clkLine(this.kbd, 4) : this.clkLine(this.mouse, 2);
        const bit = dev === this.mouse ? 2 : 4;
        if (other === 0 && ((this.latch >> bit) & 1) && !this.rx.inhibit()) {
            this.rx.edge(this.ps2Data());
            this._push(t);
        }
    }
    read(ad, t) {
        this.reads++;
        this._advance(t);
        const rx = this.rxclk();
        switch (ad & 3) {
        case 0: {
            const miso = this.sd !== null ? this.sd.miso() : 1;
            return 0x5F | (miso << 7) | (rx << 5);
        }
        case 1:
            return (this.pads[0].data() << 7) | (this.pads[1].data() << 6) | (rx << 5) | 0x1F;
        case 2:
            return this.rx.byte();
        default:
            return ((1 - this.rx.ready()) << 7) | 0x7F;
        }
    }
    write(ad, v, t) {
        this.writes++;
        this._advance(t);
        const before = this.rxclk();
        const old = this.latch;
        this.latch = (v & 0x1F) | 0xE0;
        const sck = v & 1, mosi = (v >> 1) & 1, cs = (v >> 2) & 1;
        const rising = sck && !(old & 1);
        const falling = !sck && (old & 1);
        for (const p of this.pads) p.lines(sck, mosi, rising);
        if (this.sd !== null) {
            if (!cs) this.sd.setCs(0);
            if (rising || falling) this.sd.edge(!!rising, mosi);
            if (cs) this.sd.setCs(1);
        }
        if (ad & 2) this.rx.reset();
        if (!before && this.rxclk()) this.rx.edge(this.ps2Data());
        this._push(t);
    }
}

// ---------------------------------------------------------------------------
// Video: one screen row from the RAM (placard_sim.render, docs/VIDEO.md)
// ---------------------------------------------------------------------------
function rgba(r, g, b) {          // little-endian ImageData word
    return ((255 << 24) | (b << 16) | (g << 8) | r) >>> 0;
}

const PAL2 = [[0, 0, 0], [0, 36, 255], [255, 182, 0], [255, 255, 255]];
// 16-color palette, docs/COLORS.md: (R 0-7, G 0-7, B 0-3)
const PAL4 = [[0, 0, 0], [0, 0, 3], [0, 7, 0], [0, 7, 3], [7, 0, 0], [7, 0, 3], [5, 3, 0], [5, 5, 1],
    [2, 2, 1], [2, 2, 3], [2, 7, 0], [2, 7, 3], [7, 2, 0], [7, 2, 3], [7, 7, 0], [7, 7, 3]]
    .map(([r, g, b]) => [Math.floor(r * 255 / 7), Math.floor(g * 255 / 7), Math.floor(b * 255 / 3)]);
const PAL1 = [[0, 0, 0], [255, 255, 255]];
const PAL8 = [];
for (let v = 0; v < 256; v++) {
    PAL8.push([Math.floor((v & 7) * 255 / 7), Math.floor(((v >> 5) & 7) * 255 / 7),
        Math.floor(((v >> 3) & 3) * 255 / 3)]);
}
const PALS = [PAL1, PAL2, PAL4, PAL8];

// the colors of every mode byte's palette with its tint, built when first used
const tintedCache = new Map();
function palette(mbyte) {
    const key = mbyte & 0x73;
    let p = tintedCache.get(key);
    if (p) return p;
    const tint = [0, 1, 2].map((k) => (mbyte & (0x10 << k)) ? 73 : 0);
    p = new Uint32Array(PALS[mbyte & 3].map(([r, g, b]) => rgba(
        Math.min(255, r + tint[0]), Math.min(255, g + tint[1]), Math.min(255, b + tint[2]))));
    tintedCache.set(key, p);
    return p;
}

function rowOffset(row, mode) {
    const v = 32 + row;
    const rep = (mode >> 2) & 3;
    if (rep === 0) return v;
    const v8 = (v >> 8) & 1, v7 = (v >> 7) & 1;
    if (rep === 1) return 0x100 | (v & 0xFE) | v8;
    return 0x180 | (v & 0x7C) | (v8 << 1) | v7;
}

const BLACK = rgba(0, 0, 0);

function renderRow(ram, y, fb) {
    const mbyte = ram[MODE_BASE + y];
    const base = y * 640;
    if (mbyte & 0x80) {           // blank line: black, no pixel reads
        fb.fill(BLACK, base, base + 640);
        return;
    }
    const pal = palette(mbyte);
    const bpp = 1 << (mbyte & 3);
    const per = 8 / bpp, w = 8 / per, mask = (1 << bpp) - 1;
    const off = rowOffset(y, mbyte);
    let x = base;
    for (let col = 0; col < 80; col++) {
        const byte = ram[0x6000 + col * 512 + off];
        for (let i = 0; i < per; i++) {
            const c = pal[(byte >> (i * bpp)) & mask];
            for (let k = 0; k < w; k++) fb[x++] = c;
        }
    }
}

// ---------------------------------------------------------------------------
// The machine
// ---------------------------------------------------------------------------
class Machine {
    constructor() {
        this.ram = new Uint8Array(65536);
        this.rom = new Uint8Array(65536);
        this.io = new SharedPort();
        this.fb = new Uint32Array(640 * 480);
        this.audio = [];              // DAC samples (0-255), one per line, taken by the page
        this.audioMax = 8192;
        this.frames = 0;
        this.onFrame = null;
        this.error = null;
        this.reset(false);
    }

    // power-up: the RAM as an SRAM powers up (random) or zero, the map
    // clear, the registers 0, and the cartridge loader holding the CPU
    reset(randomRam, loadClocks) {
        if (randomRam) {
            for (let i = 0; i < 65536; i += 4) {
                const r = (Math.random() * 4294967296) >>> 0;
                this.ram[i] = r & 0xFF;
                this.ram[i + 1] = (r >> 8) & 0xFF;
                this.ram[i + 2] = (r >> 16) & 0xFF;
                this.ram[i + 3] = r >>> 24;
            }
        } else {
            this.ram.fill(0);
        }
        this.map = 0;
        this.pc = 0;
        this.ac = this.x = this.y = this.d = 0;
        this.c = 0;
        this.steps = 0;
        this.clocks = 0;
        this.stallClocks = 0;
        this.holdUntil = loadClocks || 0;
        this.line = 0;                // absolute line number of the next event
        this.evPhase = 0;             // 0: the audio read, 1: the end of the line
        this.nextEvt = this.audioReadClock(0);
        this.sample = 0x80;
        this.error = null;
    }

    setRom(bytes) {
        // 64K as is; 32K (one EEPROM, or the 32K image) read in both halves
        if (bytes.length === 65536) {
            this.rom.set(bytes);
        } else if (bytes.length === 32768) {
            this.rom.set(bytes, 0);
            this.rom.set(bytes, 32768);
        } else {
            throw new Error('a ROM image is 32768 or 65536 bytes, not ' + bytes.length);
        }
    }

    // the time the cartridge takes to copy its EEPROM to its SRAM: the PC
    // walks all 64K, each address copied in its own 8-clock video group, and
    // each instruction's LOAD_MEM / EXEC clocks lose about one more group
    // (docs/ROM.md, "Loading the cartridge": 28-33 ms)
    cartLoadClocks() {
        const rom = this.rom;
        let pc = 0, groups = 0;
        while (pc < 65536) {
            const opc = rom[pc];
            const m = (opc >> 2) & 7, s = opc & 3;
            const operand = (s === 0) || (s === 1 && (m === 0 || m === 3 || m === 4)) || (s >= 2 && m === 5);
            const n = operand ? 2 : 1;
            groups += n + 1;
            pc += n;
        }
        return groups * 8;
    }

    audioReadClock(line) {
        // the audio slot reads in group 46 (V9 = 0, lines 499-511) or 47
        const idx = line % LINES;
        return line * LINE + ((idx < 13 ? 46 : 47) - 28) * 8 + 7;
    }

    event() {
        const idx = this.line % LINES;
        if (this.evPhase === 0) {
            this.sample = this.ram[idx < 13 ? 0x5DF3 + idx : 0x5E00 + idx - 13];
            this.evPhase = 1;
            this.nextEvt = (this.line + 1) * LINE;
            return;
        }
        if (this.audio.length < this.audioMax) this.audio.push(this.sample);
        if (idx >= 45) renderRow(this.ram, idx - 45, this.fb);
        this.line++;
        this.evPhase = 0;
        this.nextEvt = this.audioReadClock(this.line);
        if (idx === LINES - 1) {
            this.frames++;
            if (this.onFrame) this.onFrame();
        }
    }

    read(ad) {
        return ((this.map >> (ad >> 13)) & 1) ? this.ram[ad] : this.rom[ad];
    }

    lineRead() {
        return ((499 + Math.floor(this.clocks / LINE) % LINES) >> 2) & 0xFF;
    }

    // one instruction (placard_sim.Cpu.step, with the stall clocks)
    step() {
        const ram = this.ram;
        const opc = this.read(this.pc);
        this.pc = (this.pc + 1) & 0xFFFF;
        const a = opc >> 5, m = (opc >> 2) & 7, s = opc & 3;
        let clocks = 2;
        if (s === 1 && m === 5) {
            this.error = 'unsupported opcode ' + hex2(opc) + ' (MEM 101 with a memory source) at ' +
                hex4((this.pc - 1) & 0xFFFF);
            this.pc = (this.pc - 1) & 0xFFFF;
            return false;
        }
        if ((s === 0) || (s === 1 && (m === 0 || m === 3 || m === 4)) || (s >= 2 && m === 5)) {
            this.d = this.read(this.pc);
            this.pc = (this.pc + 1) & 0xFFFF;
            clocks++;
        }
        let ad = 0;
        if (m === 0 || m === 3 || m === 4 || m === 5) ad = this.d;
        else if (m === 1 || m === 6) ad = this.x;
        else ad = (this.y << 8) | this.x;
        if (s === 1) {
            if ((ad & 0xFF00) === 0x5000) this.d = this.lineRead();
            else if ((ad & 0xFF00) === 0x5200) this.d = this.io.read(ad, this.clocks + clocks);
            else if ((ad & 0xFD00) === 0x5100) this.d = 0xFF;      // empty expansion slots
            else this.d = this.read(ad);
            clocks++;
        }
        if (s >= 2 && (m === 6 || m === 7)) clocks++;
        const src = s < 2 ? this.d : this.ac;
        if (a === 7) {
            const z = this.ac === 0;
            const neg = this.ac >> 7;
            let take;
            switch (m) {
            case 1: take = this.c; break;
            case 2: take = !z && neg; break;
            case 3: take = !z; break;
            case 4: take = z; break;
            case 5: take = !this.c; break;
            case 6: take = z || neg; break;
            default: take = true;
            }
            if (take) this.pc = m === 0 ? (this.y << 8) | src : (this.pc & 0xFF00) | src;
        } else {
            const acc = this.ac;
            let res;
            switch (a) {
            case 0: res = src; break;
            case 1: res = acc & src; break;
            case 2: res = acc | src; break;
            case 3: res = acc ^ src; break;
            case 4: res = (acc + src) & 0xFF; break;
            case 5: res = (acc - src) & 0xFF; break;
            default: res = acc >> 1;
            }
            if ((a === 4 || a === 5) && m <= 4) {
                clocks++;
                this.c = a === 4 ? (acc + src) >> 8 : (acc < src ? 1 : 0);
            }
            if (m <= 2) this.ac = res;
            else if (m === 3) this.x = res;
            else if (m === 4) this.y = res;
            else {
                ram[ad] = src;
                if ((ad & 0xFF00) === 0x5000) this.map = src;
                else if ((ad & 0xFF00) === 0x5200) this.io.write(ad, src, this.clocks + clocks);
            }
        }
        this.steps++;
        this.clocks += this.withStalls(clocks);
        return true;
    }

    // wall clocks for n CPU clocks: a clock with H2:H0 = 111 that the video
    // uses for a read is lost to the CPU (placard_sim.Cpu.with_stalls)
    withStalls(n) {
        const t = this.clocks;
        let end = t + n;
        let c = t - (t % 8) + 7;
        while (c < end) {
            const pos = c % LINE;
            const g = 28 + (pos >> 3);
            if (g === 45 || g === 46) {
                end++;
            } else if (g >= 48) {
                const line = Math.floor(c / LINE) % LINES;
                if (line >= 45 && !(this.ram[MODE_BASE + line - 45] & 0x80)) end++;
            }
            c += 8;
        }
        this.stallClocks += end - t - n;
        return end - t;
    }

    // run until the clock count reaches target (or an error)
    runTo(target) {
        while (this.clocks < target) {
            if (this.holdUntil > this.clocks) {
                this.clocks = Math.min(target, this.holdUntil, this.nextEvt);
            } else if (!this.step()) {
                return false;
            }
            while (this.clocks >= this.nextEvt) this.event();
        }
        return true;
    }
}

function hex2(v) { return v.toString(16).toUpperCase().padStart(2, '0'); }
function hex4(v) { return v.toString(16).toUpperCase().padStart(4, '0'); }

// ---------------------------------------------------------------------------
// FAT16 card images (sdimage.make)
// ---------------------------------------------------------------------------
const SECTOR = 512;

function shortName(name) {
    const up = name.toUpperCase();
    const dot = up.indexOf('.');
    const base = dot < 0 ? up : up.slice(0, dot);
    const ext = dot < 0 ? '' : up.slice(dot + 1);
    if (base.length > 8 || ext.length > 3 || !base || ext.indexOf('.') >= 0 ||
            /[^A-Z0-9_\-~!#$%&'(){}^@`]/.test(base + ext)) {
        throw new Error('not a short (8.3) name: ' + name);
    }
    return base.padEnd(8) + ext.padEnd(3);
}

function dirEntry(name11, attr, cluster, size) {
    const e = new Uint8Array(32);
    const v = new DataView(e.buffer);
    for (let i = 0; i < 11; i++) e[i] = name11.charCodeAt(i);
    const d = ((2026 - 1980) << 9) | (10 << 5) | 26;
    e[11] = attr;
    v.setUint16(16, d, true);
    v.setUint16(18, d, true);
    v.setUint16(20, cluster >>> 16, true);
    v.setUint16(24, d, true);
    v.setUint16(26, cluster & 0xFFFF, true);
    v.setUint32(28, size, true);
    return e;
}

// files: {'NAME.EXT' or 'DIR/NAME.EXT': Uint8Array}; sizeKb 0 picks a size
function makeFat16(files, sizeKb, label) {
    label = (label || 'PLACARD').toUpperCase().slice(0, 11);
    let need = 0;
    for (const k in files) need += files[k].length + 1024;
    if (!sizeKb) {
        sizeKb = 4096;
        while (sizeKb * 1024 < need * 1.25 + 65536) sizeKb *= 2;
    }
    let spc = 1;
    while (sizeKb * 1024 / SECTOR / spc >= 65000) spc *= 2;
    const total = sizeKb * 1024 / SECTOR;
    const reserved = 1, nfats = 2, rootEntries = 512;
    const rootSecs = rootEntries * 32 / SECTOR;
    let clusters = Math.floor((total - reserved - rootSecs) / spc);
    const fatSecs = Math.floor((clusters + 2) * 2 / SECTOR) + 1;
    const dataStart = reserved + nfats * fatSecs + rootSecs;
    clusters = Math.floor((total - dataStart) / spc);
    if (clusters < 4085 || clusters >= 65525) throw new Error(clusters + ' clusters is not a FAT16 count');
    const img = new Uint8Array(total * SECTOR);
    const bv = new DataView(img.buffer);
    img.set([0xEB, 0x3C, 0x90], 0);
    for (let i = 0; i < 8; i++) img[3 + i] = 'PLACARD '.charCodeAt(i);
    bv.setUint16(11, SECTOR, true);
    img[13] = spc;
    bv.setUint16(14, reserved, true);
    img[16] = nfats;
    bv.setUint16(17, rootEntries, true);
    bv.setUint16(19, total < 65536 ? total : 0, true);
    img[21] = 0xF8;
    bv.setUint16(22, fatSecs, true);
    bv.setUint16(24, 32, true);
    bv.setUint16(26, 2, true);
    bv.setUint32(28, 0, true);
    bv.setUint32(32, total >= 65536 ? total : 0, true);
    img[36] = 0x80;
    img[38] = 0x29;
    bv.setUint32(39, 0x20261026, true);
    const lab = label.padEnd(11);
    for (let i = 0; i < 11; i++) img[43 + i] = lab.charCodeAt(i);
    for (let i = 0; i < 8; i++) img[54 + i] = 'FAT16   '.charCodeAt(i);
    img[510] = 0x55;
    img[511] = 0xAA;
    const fat = new Uint16Array(fatSecs * SECTOR / 2);
    fat[0] = 0xFFF8;
    fat[1] = 0xFFFF;
    let nextFree = 2;
    const clusterBytes = spc * SECTOR;
    function alloc(nbytes) {
        const n = Math.max(1, Math.ceil(nbytes / clusterBytes));
        const first = nextFree;
        if (first + n > clusters + 2) throw new Error('the card image is full');
        for (let c = first; c < first + n; c++) fat[c] = c < first + n - 1 ? c + 1 : 0xFFFF;
        nextFree = first + n;
        return first;
    }
    function put(data, first) {
        img.set(data, (dataStart + (first - 2) * spc) * SECTOR);
    }
    const rootBuf = new Uint8Array(rootSecs * SECTOR);
    rootBuf.set(dirEntry(lab, 0x08, 0, 0), 0);
    const folders = new Map([['', { buf: rootBuf, next: 32, cluster: 0 }]]);
    function add(f, e) {
        if (f.next + 32 > f.buf.length) throw new Error('a folder is full');
        f.buf.set(e, f.next);
        f.next += 32;
    }
    function folder(path) {
        if (folders.has(path)) return folders.get(path);
        const cut = path.lastIndexOf('/');
        const parent = folder(cut < 0 ? '' : path.slice(0, cut));
        const first = alloc(clusterBytes);
        const d = new Uint8Array(clusterBytes);
        d.set(dirEntry('.          ', 0x10, first, 0), 0);
        d.set(dirEntry('..         ', 0x10, parent.cluster, 0), 32);
        const f = { buf: d, next: 64, cluster: first };
        folders.set(path, f);
        add(parent, dirEntry(shortName(path.slice(cut + 1)), 0x10, first, 0));
        return f;
    }
    const paths = Object.keys(files).map((p) => [p.replace(/\\/g, '/').replace(/^\/+|\/+$/g, ''), p]);
    paths.sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
    for (const [path, key] of paths) {
        const data = files[key];
        const cut = path.lastIndexOf('/');
        const f = folder(cut < 0 ? '' : path.slice(0, cut));
        let first = 0;
        if (data.length) {
            first = alloc(data.length);
            put(data, first);
        }
        add(f, dirEntry(shortName(path.slice(cut + 1)), 0x20, first, data.length));
    }
    for (const [path, f] of folders) if (path) put(f.buf, f.cluster);
    const fatBytes = new Uint8Array(fat.buffer);
    for (let k = 0; k < nfats; k++) img.set(fatBytes, (reserved + k * fatSecs) * SECTOR);
    img.set(rootBuf, (reserved + nfats * fatSecs) * SECTOR);
    return img;
}

// ---------------------------------------------------------------------------
// ROM files: binary (32K or 64K), or text: a hex string or one hex byte per
// line (rom.mem); 32K images are read in both halves
// ---------------------------------------------------------------------------
function parseRom(bytes) {
    if (bytes.length === 32768 || bytes.length === 65536) return bytes;
    const text = new TextDecoder('latin1').decode(bytes);
    if (/^[\s0-9A-Fa-f]*$/.test(text)) {
        let digits;
        const tokens = text.trim().split(/\s+/);
        if (tokens.length > 1 && tokens.every((t) => t.length === 2)) digits = tokens.join('');
        else digits = text.replace(/\s+/g, '');
        if (digits.length % 2 === 0) {
            const out = new Uint8Array(digits.length / 2);
            for (let i = 0; i < out.length; i++) out[i] = parseInt(digits.substr(i * 2, 2), 16);
            if (out.length === 32768 || out.length === 65536) return out;
            throw new Error('a ROM image is 32K or 64K; this hex file holds ' + out.length +
                ' bytes (an assembled program, not a ROM image?)');
        }
    }
    throw new Error('not a ROM image: ' + bytes.length + ' bytes (want a 32K or 64K binary, or a hex file)');
}

// PS/2 scan code set 2 for KeyboardEvent.code (0x100 = an E0 key)
const SCANCODES = {
    KeyA: 0x1C, KeyB: 0x32, KeyC: 0x21, KeyD: 0x23, KeyE: 0x24, KeyF: 0x2B, KeyG: 0x34,
    KeyH: 0x33, KeyI: 0x43, KeyJ: 0x3B, KeyK: 0x42, KeyL: 0x4B, KeyM: 0x3A, KeyN: 0x31,
    KeyO: 0x44, KeyP: 0x4D, KeyQ: 0x15, KeyR: 0x2D, KeyS: 0x1B, KeyT: 0x2C, KeyU: 0x3C,
    KeyV: 0x2A, KeyW: 0x1D, KeyX: 0x22, KeyY: 0x35, KeyZ: 0x1A,
    Digit1: 0x16, Digit2: 0x1E, Digit3: 0x26, Digit4: 0x25, Digit5: 0x2E,
    Digit6: 0x36, Digit7: 0x3D, Digit8: 0x3E, Digit9: 0x46, Digit0: 0x45,
    Backquote: 0x0E, Minus: 0x4E, Equal: 0x55, Backslash: 0x5D, Backspace: 0x66,
    Space: 0x29, Tab: 0x0D, CapsLock: 0x58, ShiftLeft: 0x12, ControlLeft: 0x14,
    MetaLeft: 0x11F, AltLeft: 0x11, ShiftRight: 0x59, ControlRight: 0x114,
    MetaRight: 0x127, AltRight: 0x111, ContextMenu: 0x12F, Enter: 0x5A, Escape: 0x76,
    F1: 0x05, F2: 0x06, F3: 0x04, F4: 0x0C, F5: 0x03, F6: 0x0B, F7: 0x83, F8: 0x0A,
    F9: 0x01, F10: 0x09, F11: 0x78, F12: 0x07, ScrollLock: 0x7E,
    BracketLeft: 0x54, BracketRight: 0x5B, Semicolon: 0x4C, Quote: 0x52,
    Comma: 0x41, Period: 0x49, Slash: 0x4A, IntlBackslash: 0x61,
    Insert: 0x170, Home: 0x16C, PageUp: 0x17D, Delete: 0x171, End: 0x169, PageDown: 0x17A,
    ArrowUp: 0x175, ArrowLeft: 0x16B, ArrowDown: 0x172, ArrowRight: 0x174,
    NumLock: 0x77, NumpadDivide: 0x14A, NumpadMultiply: 0x7C, NumpadSubtract: 0x7B,
    NumpadAdd: 0x79, NumpadEnter: 0x15A, NumpadDecimal: 0x71,
    Numpad0: 0x70, Numpad1: 0x69, Numpad2: 0x72, Numpad3: 0x7A, Numpad4: 0x6B,
    Numpad5: 0x73, Numpad6: 0x74, Numpad7: 0x6C, Numpad8: 0x75, Numpad9: 0x7D,
};

const api = {
    CPU_HZ, LINE, LINES, FRAME, LINE_HZ, us,
    SnesPad, SdCard, Ps2Mouse, Ps2Keyboard, Ps2Receiver, SharedPort, Machine,
    renderRow, makeFat16, parseRom, SCANCODES,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
else root.Placard = api;
})(typeof self !== 'undefined' ? self : this);
