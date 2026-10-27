/*
 * app.js - the PLACARD emulator page: the machine (placard_emu.js) run in
 * real time, the screen, Web Audio, keyboard / mouse / game controllers,
 * the ROM picker and the SD card
 *
 * Generated: 10/27/2026
 */
(function () {
'use strict';
const P = window.Placard;
const $ = (id) => document.getElementById(id);

function b64(s) {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
}

function show(el, text, bad) {
    el.hidden = !text;
    el.textContent = text || '';
    el.classList.toggle('bad', !!bad);
}

// ---------------------------------------------------------------------------
// The machine
// ---------------------------------------------------------------------------
const m = new P.Machine();
let romBytes = b64(PLACARD_DEFAULT_ROM);
let cardImage = null;             // Uint8Array, or null: no card
let cardDirty = false;
let paused = false;
let lastSdReads = 0, lastSdWrites = 0, sdLedUntil = 0;

function defaultCard() {
    const files = {};
    for (const k in PLACARD_DEFAULT_SD) files[k] = b64(PLACARD_DEFAULT_SD[k]);
    return P.makeFat16(files, 0);
}

function insertCard(image) {
    cardImage = image;
    cardDirty = false;
    m.io.sd = image ? new P.SdCard(image) : null;
    if (m.io.sd) m.io.sd.onWrite = () => { cardDirty = true; };
    lastSdReads = lastSdWrites = 0;
}

// power cycle: the relay drops the 5 V, so everything starts again; the
// cartridge copies its EEPROM (about 33 ms) before the CPU runs
function powerCycle() {
    m.setRom(romBytes);
    m.io = new P.SharedPort();
    m.io.kbd = new P.Ps2Keyboard();
    m.io.mouse = $('optMouse').checked ? new P.Ps2Mouse() : null;
    insertCard(cardImage);
    for (const code of heldKeys) m.io.kbd.press(P.SCANCODES[code]);   // keys held through power-up
    m.reset($('optRandom').checked, m.cartLoadClocks());
    m.audio.length = 0;
    clockTarget = 0;
    lastTime = performance.now();
    show($('powerMsg'), '');
}

// ---------------------------------------------------------------------------
// Screen and main loop
// ---------------------------------------------------------------------------
const canvas = $('screen');
const ctx = canvas.getContext('2d', { alpha: false });
const image = new ImageData(new Uint8ClampedArray(m.fb.buffer), 640, 480);
let clockTarget = 0;
let lastTime = performance.now();
let speedClocks = 0, speedTime = 0, shownFrame = -1;

function frame(now) {
    requestAnimationFrame(frame);
    let dt = (now - lastTime) / 1000;
    lastTime = now;
    if (dt > 0.1) dt = 0.1;           // a hidden tab or a slow frame: don't catch up
    pollPads();
    if (!paused && !m.error) {
        clockTarget = Math.max(clockTarget, m.clocks) + dt * P.CPU_HZ * audioTrim;
        const t0 = performance.now();
        const before = m.clocks;
        // run in slices so a slow computer still draws
        while (m.clocks < clockTarget && performance.now() - t0 < 40) {
            if (!m.runTo(Math.min(clockTarget, m.clocks + P.FRAME / 4))) break;
        }
        if (m.clocks < clockTarget) clockTarget = m.clocks;   // fell behind: run slower
        speedClocks += m.clocks - before;
        if (m.error) {
            show($('powerMsg'), 'Stopped: ' + m.error + '. Power cycle to start again.', true);
        }
    }
    speedTime += dt;
    if (m.frames !== shownFrame) {
        shownFrame = m.frames;
        ctx.putImageData(image, 0, 0);
    }
    pumpAudio();
    if (speedTime >= 0.5) {
        $('stSpeed').textContent = paused ? 'paused' : Math.round(speedClocks / speedTime / P.CPU_HZ * 100) + '%';
        speedClocks = speedTime = 0;
    }
    $('stFrame').textContent = m.frames;
    $('stPc').textContent = m.pc.toString(16).toUpperCase().padStart(4, '0');
    $('stMap').textContent = m.map.toString(16).toUpperCase().padStart(2, '0');
    const leds = m.io.kbd ? m.io.kbd.leds : 0;
    $('ledScroll').classList.toggle('on', !!(leds & 1));
    $('ledNum').classList.toggle('on', !!(leds & 2));
    $('ledCaps').classList.toggle('on', !!(leds & 4));
    const sd = m.io.sd;
    if (sd && (sd.reads !== lastSdReads || sd.writes !== lastSdWrites)) {
        lastSdReads = sd.reads;
        lastSdWrites = sd.writes;
        sdLedUntil = now + 120;
    }
    $('ledSd').classList.toggle('on', now < sdLedUntil);
}

// ---------------------------------------------------------------------------
// Sound: one DAC sample per line (31.469 kHz), the board's filter (one pole
// at 10.6 kHz) and coupling capacitor, resampled to the sound card's rate
// ---------------------------------------------------------------------------
let actx = null, node = null, useWorklet = false, gain = null, workletQueue = 0, audioTrim = 1;
let lp = 0, hpIn = 0, hpOut = 0, resPos = 0, prev = 0;
const LP_A = 1 - Math.exp(-2 * Math.PI * 10600 / P.LINE_HZ);
const HP_R = Math.exp(-2 * Math.PI * 5 / P.LINE_HZ);
// the ScriptProcessor fallback (pages opened from a file can't load a worklet)
const fifo = new Float32Array(65536);
let fifoIn = 0, fifoOut = 0;

const WORKLET = `
class PlacardOut extends AudioWorkletProcessor {
  constructor() {
    super();
    this.q = []; this.pos = 0; this.last = 0; this.n = 0;
    this.port.onmessage = (e) => { this.q.push(e.data); };
  }
  process(inputs, outputs) {
    const out = outputs[0][0];
    for (let i = 0; i < out.length; i++) {
      while (this.q.length && this.pos >= this.q[0].length) { this.pos = 0; this.q.shift(); }
      if (this.q.length) this.last = this.q[0][this.pos++];
      else this.last *= 0.999;
      out[i] = this.last;
    }
    for (let c = 1; c < outputs[0].length; c++) outputs[0][c].set(out);
    if (++this.n % 16 === 0) {
      let left = 0;
      for (const b of this.q) left += b.length;
      this.port.postMessage(left - this.pos);
    }
    return true;
  }
}
registerProcessor('placard-out', PlacardOut);
`;

async function startAudio() {
    if (actx) {
        if (actx.state !== 'running') actx.resume();
        return;
    }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    actx = new AC();
    gain = actx.createGain();
    gain.gain.value = volume();
    gain.connect(actx.destination);
    try {
        const url = URL.createObjectURL(new Blob([WORKLET], { type: 'application/javascript' }));
        await actx.audioWorklet.addModule(url);
        node = new AudioWorkletNode(actx, 'placard-out', { outputChannelCount: [2] });
        node.port.onmessage = (e) => { workletQueue = e.data; };
        useWorklet = true;
    } catch (err) {
        node = actx.createScriptProcessor(2048, 0, 2);
        let last = 0;
        node.onaudioprocess = (e) => {
            const l = e.outputBuffer.getChannelData(0), r = e.outputBuffer.getChannelData(1);
            for (let i = 0; i < l.length; i++) {
                if (fifoOut !== fifoIn) {
                    last = fifo[fifoOut];
                    fifoOut = (fifoOut + 1) & 65535;
                } else {
                    last *= 0.999;
                }
                l[i] = r[i] = last;
            }
            workletQueue = (fifoIn - fifoOut) & 65535;
        };
    }
    node.connect(gain);
    m.audio.length = 0;
}

function volume() {
    const v = $('optVolume').value / 100;
    return v * v;
}

// move the line-rate samples to the sound card; the emulator's speed is
// trimmed by up to 0.5 % to keep about 60 ms queued
function pumpAudio() {
    const src = m.audio;
    if (!actx || !node || actx.state !== 'running') {
        src.length = 0;
        return;
    }
    const rate = actx.sampleRate;
    const step = P.LINE_HZ / rate;
    const out = [];
    for (let i = 0; i < src.length; i++) {
        const v = (src[i] - 128) / 128;
        lp += LP_A * (v - lp);
        hpOut = HP_R * (hpOut + lp - hpIn);
        hpIn = lp;
        // linear interpolation between the previous sample and this one
        while (resPos < 1) {
            out.push(prev + (hpOut - prev) * resPos);
            resPos += step;
        }
        resPos -= 1;
        prev = hpOut;
    }
    src.length = 0;
    if (!out.length) return;
    const buf = Float32Array.from(out);
    if (useWorklet) node.port.postMessage(buf, [buf.buffer]);
    else {
        for (const v of buf) {
            if (((fifoIn + 1) & 65535) === fifoOut) break;
            fifo[fifoIn] = v;
            fifoIn = (fifoIn + 1) & 65535;
        }
    }
    const target = rate * 0.06;
    const err = (target - workletQueue) / target;
    audioTrim = 1 + Math.max(-0.005, Math.min(0.005, err * 0.01));
}

$('optVolume').addEventListener('input', () => { if (gain) gain.gain.value = volume(); });

// ---------------------------------------------------------------------------
// Keyboard and mouse
// ---------------------------------------------------------------------------
const bezel = $('bezel');
const heldKeys = new Set();
let captured = false;

function capture(on) {
    captured = on;
    bezel.classList.toggle('captured', on);
    $('overlay').hidden = on;
    if (!on) releaseAll();
}

function releaseAll() {
    for (const code of heldKeys) if (m.io.kbd) m.io.kbd.release(P.SCANCODES[code]);
    heldKeys.clear();
    if (m.io.mouse) m.io.mouse.move(0, 0, 0);
}

bezel.addEventListener('focus', () => capture(true));
bezel.addEventListener('blur', () => capture(false));
bezel.addEventListener('mousedown', (e) => {
    startAudio();
    if (document.activeElement !== bezel) bezel.focus();
    capture(true);
    if (m.io.mouse && document.pointerLockElement !== canvas && canvas.requestPointerLock) {
        try {
            const r = canvas.requestPointerLock();
            if (r && r.catch) r.catch(() => {});
        } catch (err) { /* not allowed here: keyboard only */ }
        e.preventDefault();
        return;
    }
    mouseButton(e, true);
});
document.addEventListener('mouseup', (e) => mouseButton(e, false));
document.addEventListener('mousemove', (e) => {
    if (document.pointerLockElement !== canvas || !m.io.mouse) return;
    m.io.mouse.move(e.movementX, -e.movementY);     // PS/2: Y counts up
});
bezel.addEventListener('contextmenu', (e) => e.preventDefault());
let mouseButtons = 0;
function mouseButton(e, down) {
    if (document.pointerLockElement !== canvas || !m.io.mouse) return;
    const bit = [1, 4, 2][e.button] || 0;          // PS/2: bit 0 left, 1 right, 2 middle
    mouseButtons = down ? mouseButtons | bit : mouseButtons & ~bit;
    m.io.mouse.move(0, 0, mouseButtons);
}

bezel.addEventListener('keydown', (e) => {
    if (e.code === 'Pause') {
        if (!e.repeat && m.io.kbd) m.io.kbd.pause();
        e.preventDefault();
        return;
    }
    const sc = P.SCANCODES[e.code];
    if (sc === undefined) return;
    e.preventDefault();
    if (!m.io.kbd) return;
    m.io.kbd.press(sc);            // a repeat is the keyboard's typematic make code
    heldKeys.add(e.code);
});
bezel.addEventListener('keyup', (e) => {
    const sc = P.SCANCODES[e.code];
    if (sc === undefined) return;
    e.preventDefault();
    if (heldKeys.delete(e.code) && m.io.kbd) m.io.kbd.release(sc);
});

$('btnFull').addEventListener('click', async () => {
    try {
        if (document.fullscreenElement) await document.exitFullscreen();
        else {
            await bezel.requestFullscreen();
            bezel.focus();
            if (navigator.keyboard && navigator.keyboard.lock) navigator.keyboard.lock(['Escape']).catch(() => {});
        }
    } catch (err) {
        show($('powerMsg'), 'Full screen is not available here.', false);
    }
});

// ---------------------------------------------------------------------------
// Game controllers as SNES pads (standard mapping)
// ---------------------------------------------------------------------------
// SNES bits: 0 B, 1 Y, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left, 7 Right, 8 A, 9 X, 10 L, 11 R
const PAD_MAP = [[0, 0], [2, 1], [8, 2], [9, 3], [12, 4], [13, 5], [14, 6], [15, 7],
    [1, 8], [3, 9], [4, 10], [5, 11], [6, 10], [7, 11]];
let padText = '';
function pollPads() {
    const pads = navigator.getGamepads ? Array.from(navigator.getGamepads()).filter((g) => g && g.connected) : [];
    const names = [];
    for (let i = 0; i < 2; i++) {
        const sp = m.io.pads[i];
        const g = pads[i];
        sp.connected = !!g;
        if (!g) {
            sp.buttons = 0;
            names.push('Pad ' + (i + 1) + ': none');
            continue;
        }
        let b = 0;
        for (const [gi, bit] of PAD_MAP) if (g.buttons[gi] && g.buttons[gi].pressed) b |= 1 << bit;
        const ax = g.axes[0] || 0, ay = g.axes[1] || 0;
        if (ay < -0.5) b |= 1 << 4;
        if (ay > 0.5) b |= 1 << 5;
        if (ax < -0.5) b |= 1 << 6;
        if (ax > 0.5) b |= 1 << 7;
        sp.buttons = b;
        names.push('Pad ' + (i + 1) + ': ' + g.id.replace(/\s*\(.*$/, '').slice(0, 28));
    }
    const t = names.join(' · ');
    if (t !== padText) $('padStatus').textContent = padText = t;
}

// ---------------------------------------------------------------------------
// ROM and SD card
// ---------------------------------------------------------------------------
function readFile(f) {
    return new Promise((ok, fail) => {
        const r = new FileReader();
        r.onload = () => ok(new Uint8Array(r.result));
        r.onerror = () => fail(r.error);
        r.readAsArrayBuffer(f);
    });
}

function kb(n) { return n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.round(n / 1024) + ' KB'; }

function setWhat(el, title, sub) {
    el.textContent = title;
    const s = document.createElement('small');
    s.textContent = sub;
    el.appendChild(s);
}

async function loadRom(f) {
    try {
        romBytes = P.parseRom(await readFile(f));
        setWhat($('romName'), f.name, kb(romBytes.length) + (romBytes.length === 32768 ? ', read in both halves' : ''));
        show($('romMsg'), '');
        powerCycle();
    } catch (err) {
        show($('romMsg'), err.message, true);
    }
}
$('fileRom').addEventListener('change', (e) => { if (e.target.files[0]) loadRom(e.target.files[0]); e.target.value = ''; });
$('btnRomDefault').addEventListener('click', () => {
    romBytes = b64(PLACARD_DEFAULT_ROM);
    setWhat($('romName'), 'Built-in 32K image', 'boot loader, library, BASIC, DOS loader');
    show($('romMsg'), '');
    powerCycle();
});

function confirmLoseCard() {
    if (!cardDirty) return true;
    show($('sdMsg'), 'The card has unsaved writes. Save image first, or click again to discard them.', true);
    cardDirty = false;
    return false;
}

$('fileSdDir').addEventListener('change', async (e) => {
    const list = Array.from(e.target.files);
    e.target.value = '';
    if (!list.length || !confirmLoseCard()) return;
    const files = {};
    const skipped = [];
    let top = '';
    for (const f of list) {
        const parts = (f.webkitRelativePath || f.name).split('/');
        top = parts.length > 1 ? parts[0] : '';
        const rel = parts.slice(parts.length > 1 ? 1 : 0);
        if (rel.some((p) => p.startsWith('.'))) continue;
        try {
            files[rel.join('/')] = await readFile(f);
        } catch (err) { skipped.push(rel.join('/')); }
    }
    // drop files whose names are not 8.3 (the FAT reader has no long names)
    for (const k of Object.keys(files)) {
        try { P.makeFat16({ [k]: new Uint8Array(0) }, 4096); } catch (err) { skipped.push(k); delete files[k]; }
    }
    try {
        const img = P.makeFat16(files, 0);
        insertCard(img);
        setWhat($('sdName'), (top || 'Folder') + ' (FAT16)',
            Object.keys(files).length + ' files, ' + kb(img.length) + ' card');
        show($('sdMsg'), skipped.length ? 'Left out (not 8.3 names): ' + skipped.slice(0, 6).join(', ') +
            (skipped.length > 6 ? ' and ' + (skipped.length - 6) + ' more' : '') : '');
    } catch (err) {
        show($('sdMsg'), err.message, true);
    }
});

$('fileSdImg').addEventListener('change', async (e) => {
    const f = e.target.files[0];
    e.target.value = '';
    if (!f || !confirmLoseCard()) return;
    const img = await readFile(f);
    if (img.length % 512) {
        show($('sdMsg'), f.name + ' is not a whole number of 512-byte blocks.', true);
        return;
    }
    insertCard(img);
    setWhat($('sdName'), f.name, kb(img.length) + ' image');
    show($('sdMsg'), '');
});

$('btnSdDefault').addEventListener('click', () => {
    if (!confirmLoseCard()) return;
    insertCard(defaultCard());
    setWhat($('sdName'), 'Built-in card', 'the sdcard folder');
    show($('sdMsg'), '');
});
$('btnSdEject').addEventListener('click', () => {
    if (!confirmLoseCard()) return;
    insertCard(null);
    setWhat($('sdName'), 'No card', 'BASIC starts at power-up');
    show($('sdMsg'), '');
});
$('btnSdSave').addEventListener('click', () => {
    if (!cardImage) {
        show($('sdMsg'), 'There is no card to save.', true);
        return;
    }
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([cardImage], { type: 'application/octet-stream' }));
    a.download = 'placard_sd.img';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 10000);
    cardDirty = false;
    show($('sdMsg'), 'Saved placard_sd.img. Load it with Load image next time.');
});

// drop a ROM (.bin/.mem/.hex) or a card image (.img) on the page
document.addEventListener('dragover', (e) => e.preventDefault());
document.addEventListener('drop', async (e) => {
    e.preventDefault();
    const f = e.dataTransfer.files[0];
    if (!f) return;
    if (/\.(img|ima)$/i.test(f.name)) {
        const img = await readFile(f);
        insertCard(img);
        setWhat($('sdName'), f.name, kb(img.length) + ' image');
    } else {
        loadRom(f);
    }
});

// ---------------------------------------------------------------------------
// Power and pause
// ---------------------------------------------------------------------------
$('btnPower').addEventListener('click', () => { startAudio(); powerCycle(); bezel.focus(); });
$('btnPause').addEventListener('click', () => {
    paused = !paused;
    $('btnPause').setAttribute('aria-pressed', String(paused));
    $('btnPause').textContent = paused ? 'Resume' : 'Pause';
    if (paused && actx) actx.suspend();
    else if (actx) actx.resume();
});
$('optMouse').addEventListener('change', () => {
    show($('powerMsg'), 'The mouse change takes effect at the next power cycle (plug PS/2 devices in with the power off).');
});
document.addEventListener('pointerlockchange', () => {
    if (document.pointerLockElement !== canvas && m.io.mouse) {
        mouseButtons = 0;
        m.io.mouse.move(0, 0, 0);
    }
});

insertCard(defaultCard());
powerCycle();
requestAnimationFrame(frame);
})();
