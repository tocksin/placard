#!/usr/bin/env python3
"""
bringup_signals.py - expected multimeter readings for docs/BRINGUP.md

A clock-by-clock model of the video PLDs (Sync rev 08, H counter rev 08,
V counter rev 03, audio slot rev 04, color decoder rev 07) as
they are wired in the early build steps, and the CPU's "FF free run"
(State rev 15, Branch rev 15, PC counters rev 02) with no memory on the
data bus.  Every equation is the PLD source's, written out per clock.

It runs one frame to settle, then measures one whole frame (800 x 525 =
420,000 clocks, the pattern repeats exactly every frame) and prints, for
each pin, what a multimeter's frequency counter reads (rising edges per
second, 25.175 MHz clock), the duty cycle (fraction of the time high) and
the average DC voltage that duty gives with a 5 V swing.  The tables in
BRINGUP.md are this script's output:

    python3 bringup_signals.py            all tables (markdown)
    python3 bringup_signals.py --step 4   one step

Signals that change inside a clock (the memory control PLD's /RAM_OE,
/ROM_OE and /WE are low only in the low half of the clock) are counted
with a 50 % clock.
"""

import sys

CLK_HZ = 25.175e6
FRAME = 800 * 525
FPS = CLK_HZ / FRAME


class Video:
    """the video PLDs.  Registers power up to 0, as the ATF22V10C does."""

    def __init__(self, blank_rd=True, lc_from_bus=True, bus=0xFF):
        self.blank_rd_on = blank_rd        # audio slot PLD installed
        self.lc_from_bus = lc_from_bus     # pixel buffer + line code installed
                                           # (before that, strap S4 holds LC7 low)
        self.bus = bus                     # what a video read sees
        # Sync PLD registers
        self.h0 = self.h1 = self.h2 = 0
        self.viden = self.pe = self.vva = 0
        # H counter PLD registers (H9:H3 as one number) and states
        self.hc = 0
        self.hsync = 0                     # logical: 1 = in sync (pin low)
        self.hva = 0
        # V counter
        self.v = 0
        # pixel buffer, line code
        self.pix = 0
        self.lc = 0

    def comb(self):
        """combinational outputs from the registers (one clock's levels)"""
        h0, h1, h2, hc, v = self.h0, self.h1, self.h2, self.hc, self.v
        b = lambda n: (hc >> (n - 3)) & 1      # H bit n (3-9)
        vb = lambda n: (v >> n) & 1
        h_enable = h2 & (1 - h1) & h0
        h_tc = h_enable & (hc == 127)
        H9, H8, H7, H6, H5, H4, H3 = (b(n) for n in (9, 8, 7, 6, 5, 4, 3))
        g = hc
        if self.blank_rd_on:
            blank_rd = int((g == 47 and vb(9)) or (g == 46 and not vb(9)) or g == 45)
            mode_ld = int(g == 45)
        else:
            blank_rd = 0
            mode_ld = 0
        lc2, lc3 = (self.lc >> 2) & 1, (self.lc >> 3) & 1
        raw = (1 - H9) & (1 - H7)
        V0, V1, V7, V8 = vb(0), vb(1), vb(7), vb(8)
        r0 = (V0 & raw) | (V0 & (1 - lc3) & (1 - lc2)) | (V8 & (1 - raw) & (1 - lc3) & lc2) | (V7 & (1 - raw) & lc3)
        r1 = (V1 & raw) | (V1 & (1 - lc3)) | (V8 & (1 - raw) & lc3)
        r7 = (V7 & raw) | (V7 & (1 - lc3)) | ((1 - raw) & lc3)
        r8 = (V8 & raw) | (V8 & (1 - lc3) & (1 - lc2)) | ((1 - raw) & lc3) | ((1 - raw) & lc2)
        vsync_n = 1 - (vb(9) & (1 - self.vva) & vb(4) & (1 - vb(3)) & vb(2) & (1 - vb(1)))
        return dict(h_enable=h_enable, h_tc=h_tc, blank_rd=blank_rd, mode_ld=mode_ld,
                    r0=r0, r1=r1, r7=r7, r8=r8, vsync_n=vsync_n)

    def video_addr(self, c):
        """A15:A0 of a video read: H9:H3, R8, R7, V6:V2, R1, R0"""
        return ((self.hc << 9) | (c['r8'] << 8) | (c['r7'] << 7) | (((self.v >> 2) & 31) << 2)
                | (c['r1'] << 1) | c['r0'])

    def clock(self, c):
        """the clock edge: next state of every register"""
        h0, h1, h2, hc, v = self.h0, self.h1, self.h2, self.hc, self.v
        vb = lambda n: (v >> n) & 1
        h_enable, h_tc = c['h_enable'], c['h_tc']
        # Sync PLD
        n_h0 = 1 - h0
        n_h1 = h1 ^ h0
        n_h2 = h2 ^ (h1 & h0)
        n_vva = vb(9) & (vb(5) | self.vva)
        n_viden = (self.vva & self.hva & h2 & h1 & h0) | (self.viden & (1 - (h2 & h1 & h0)))
        n_pe = ((self.vva & self.hva) | c['blank_rd']) & h2 & h1 & (1 - h0)
        # H counter PLD
        if h_tc:
            n_hc = 28
        elif h_enable:
            n_hc = (hc + 1) & 127
        else:
            n_hc = hc
        hsync_start = h_enable and hc == 29
        hsync_stop = h_enable and hc == 41
        n_hsync = int(hsync_start or (self.hsync and not hsync_stop))
        video_on = h_enable and hc == 47
        lc7 = (self.lc >> 7) & 1             # blank line (rev 08)
        blank_pulse = lc7 and hc == 48 and h2 and h1 and h0
        n_hva = int((video_on and not lc7) or (self.hva and not h_tc and not lc7) or blank_pulse)
        # V counter PLD
        if v == 0:
            n_v = 499
        elif h_tc:
            n_v = 499 if v == 1023 else v + 1
        else:
            n_v = v
        # pixel buffer (loads on the read clock), line code (/MODE_LD)
        if self.lc_from_bus:
            n_pix = self.bus if self.pe else self.pix
            n_lc = self.pix if c['mode_ld'] else self.lc
        else:
            n_pix, n_lc = self.pix, self.lc
        self.h0, self.h1, self.h2, self.vva, self.viden, self.pe = n_h0, n_h1, n_h2, n_vva, n_viden, n_pe
        self.hc, self.hsync, self.hva, self.v = n_hc, n_hsync, n_hva, n_v
        self.pix, self.lc = n_pix, n_lc


def color(pix, mode, h, viden):
    """color decoder rev 07 outputs (RED1-3, GRN1-3, BLU2-3) as a dict"""
    D = lambda n: (pix >> n) & 1
    h2, h1, h0 = (h >> 2) & 1, (h >> 1) & 1, h & 1
    m1, m0 = (mode >> 1) & 1, mode & 1
    M1 = viden & (1 - m1) & (1 - m0)
    M2 = viden & (1 - m1) & m0
    M4 = viden & m1 & (1 - m0)
    M8 = viden & m1 & m0
    C0 = D(h2 * 4 + h1 * 2)
    C1 = D(h2 * 4 + h1 * 2 + 1)
    X = (pix >> (4 * h2)) & 15
    X0, X1, X2, X3 = X & 1, (X >> 1) & 1, (X >> 2) & 1, (X >> 3) & 1
    n = lambda x: 1 - x
    red1_4 = (X2 & n(X1)) | (X3 & X1)
    red2_4 = (X2 & n(X1)) | (n(X3) & X2 & X0) | (X3 & X1 & n(X0))
    red3_4 = (X1 & n(X0)) | (X2 & n(X1)) | (X3 & n(X2) & X1)
    blu2_4 = (n(X3) & X0) | (X3 & n(X2) & n(X0))
    blu3_4 = (n(X2) & X1) | (n(X3) & X2 & n(X1) & X0) | (X3 & n(X1) & n(X0))
    grn1_4 = (X3 & n(X2) & n(X0)) | (X3 & X1)
    grn2_4 = (X2 & X1) | (X3 & n(X2) & n(X0))
    grn3_4 = X3
    grn3 = (M1 & D(h)) | (M2 & C1) | (M4 & grn3_4) | (M8 & D(7))
    return {
        'RED1 (pin 15)': (M1 & grn3) | (M2 & C1) | (M4 & red1_4) | (M8 & D(0)),
        'RED2 (pin 16)': (M1 & grn3) | (M2 & C1) | (M4 & red2_4) | (M8 & D(1)),
        'RED3 (pin 21)': (M1 & grn3) | (M2 & C1) | (M4 & red3_4) | (M8 & D(2)),
        'BLU2 (pin 22)': (M1 & grn3) | (M2 & C0) | (M4 & blu2_4) | (M8 & D(3)),
        'BLU3 (pin 18)': (M1 & grn3) | (M2 & C0) | (M4 & blu3_4) | (M8 & D(4)),
        'GRN1 (pin 17)': (M1 & grn3) | (M2 & C1) | (M2 & C0) | (M4 & grn1_4) | (M8 & D(5)),
        'GRN2 (pin 20)': (M1 & grn3) | (M2 & C1 & C0) | (M4 & grn2_4) | (M8 & D(6)),
        'GRN3 (pin 19)': grn3,
    }


class Meter:
    """counts rising edges and high time of named signals"""

    def __init__(self):
        self.prev = {}
        self.edges = {}
        self.high = {}
        self.order = []

    def add(self, name, level, weight=1.0):
        """level for one clock; weight < 1 for a signal high only part of it"""
        if name not in self.edges:
            self.edges[name] = 0
            self.high[name] = 0.0
            self.order.append(name)
        p = self.prev.get(name)
        if p is not None and level and not p:
            self.edges[name] += 1
        self.prev[name] = level
        self.high[name] += level * weight

    def add_pulse_low(self, name, low_half):
        """a signal that goes low in the low half of the clock when low_half,
        else stays high: one rising edge per such clock"""
        if name not in self.edges:
            self.edges[name] = 0
            self.high[name] = 0.0
            self.order.append(name)
        if low_half:
            self.edges[name] += 1
            self.high[name] += 0.5
        else:
            self.high[name] += 1.0

    def rows(self, clocks=FRAME):
        out = []
        for n in self.order:
            f = self.edges[n] * CLK_HZ / clocks
            duty = self.high[n] / clocks
            out.append((n, f, duty))
        return out


def fmt_f(f):
    if f == 0:
        return '0 (DC)'
    if f >= 1e6:
        return '%.4g MHz' % (f / 1e6)
    if f >= 1e3:
        return '%.4g kHz' % (f / 1e3)
    return '%.4g Hz' % f


def table(rows, title):
    lines = ['%s' % title, '', '| Pin | Frequency | Duty (high) | DC average |', '|---|---|---|---|']
    for n, f, duty in rows:
        if f == 0:
            dc = 'high, 5 V' if duty > 0.5 else 'low, 0 V'
            lines.append('| %s | %s | %s | %s |' % (n, '0 (DC)', '-', dc))
        else:
            lines.append('| %s | %s | %.1f %% | %.2f V |' % (n, fmt_f(f), duty * 100, duty * 5))
    return '\n'.join(lines) + '\n'


def run_video(step, bus=0xFF):
    """steps 3-5, 11 and 12: the video chips (steps 11 and 12 with LC7 low,
    no blank lines; random mode bytes may blank some).  Step 12: the memory
    control PLD's /RAM_OE (low in the low half of each video read, the map
    clear so no CPU read is of RAM) and /WE with RUN high and RW grounded
    (low in the low half of every other clock)"""
    vid = Video(blank_rd=step >= 11, lc_from_bus=False, bus=bus)
    m = Meter()
    for clk in range(2 * FRAME):
        c = vid.comb()
        if clk >= FRAME:
            if step == 3:
                m.add('Sync H0 (pin 14)', vid.h0)
                m.add('Sync H1 (pin 15)', vid.h1)
                m.add('Sync H2 (pin 16)', vid.h2)
            if step == 4:
                for n in range(3, 10):
                    m.add('H counter H%d (pin %d)' % (n, 11 + n), (vid.hc >> (n - 3)) & 1)
                m.add('H counter /HSYNC (pin 21)', 1 - vid.hsync)
                m.add('H counter H_VIDEO_ACTIVE (pin 22)', vid.hva)
                m.add('H counter H_TC (pin 23)', c['h_tc'])
            if step == 5:
                pins = {0: 14, 1: 23, 2: 22, 3: 15, 4: 16, 5: 21, 6: 20, 7: 17, 8: 18, 9: 19}
                for n in range(10):
                    m.add('V counter V%d (pin %d)' % (n, pins[n]), (vid.v >> n) & 1)
                m.add('Sync VIDEN (pin 17)', vid.viden)
                m.add('Sync /VSYNC (pin 18)', c['vsync_n'])
                m.add('Sync PIXEL_ENABLE (pin 19)', vid.pe)
                m.add('Sync /WE (pin 20)', 1)                  # output off while RUN is low, pull-up R63
                m.add('Sync V_VIDEO_ACTIVE (pin 23)', vid.vva)
            if step == 11:
                m.add('Audio BLANK_RD (pin 23)', c['blank_rd'])
                m.add('Audio /MODE_LD (pin 22)', 1 - c['mode_ld'])
            if step == 12:
                m.add('Sync PIXEL_ENABLE (pin 19)', vid.pe)
                m.add_pulse_low('Mem ctrl /RAM_OE (pin 18)', vid.pe)
                m.add_pulse_low('Mem ctrl /WE (pin 16), RUN high, RW low', 1 - vid.pe)
        vid.clock(c)
    return m.rows()


def run_probes(cases):
    """step 6: the color decoder alone, its pixel and mode inputs set by the
    probes (pin keepers), LC7 held low by strap S4"""
    out = {}
    for pix, mode in cases:
        vid = Video(blank_rd=False, lc_from_bus=False)
        m = Meter()
        for clk in range(2 * FRAME):
            c = vid.comb()
            if clk >= FRAME:
                h = vid.h2 * 4 + vid.h1 * 2 + vid.h0
                for n, lv in color(pix, mode, h, vid.viden).items():
                    m.add(n, lv)
            vid.clock(c)
        out[(pix, mode)] = m.rows()
    return out


def run_free_run(step):
    """steps 13-15: the CPU with nothing driving the data bus, so every byte
    it reads is FF (the 10k pull-ups): BRA with source 11 (AC), through
    LOAD_MEM.  The source bus is FF too (no source F541s), so EXEC loads
    PC low = FF."""
    vid = Video(blank_rd=True, lc_from_bus=True, bus=0xFF)
    m = Meter()
    q0 = q1 = 0
    x_en = y_en = 0
    alu_done = 0
    pc = 0
    ir = 0xFF
    for clk in range(3 * FRAME):
        c = vid.comb()
        pe = vid.pe
        # Branch PLD (IR = FF: branch, BRA, never ADD/SUB)
        pc_enable = 1 - q1
        exec_ = q0 & (1 - pc_enable)
        stall = pe                      # ADDSUB_REG = 0
        branch_a = exec_ & (1 - pe)
        load_pc_low = branch_a          # BRA
        src_en = exec_ & (1 - pe)
        s_fetch = (1 - q1) & (1 - q0)
        s_lmem = q1 & (1 - q0)
        s_limm = (1 - q1) & q0
        load_instr = s_fetch & (1 - stall)
        load_imm = (s_limm | s_lmem) & (1 - stall)
        lo, hi = pc & 0xFF, pc >> 8
        co = int(lo == 0xFF)
        if clk >= 2 * FRAME:
            if step == 13:
                m.add('State Q0 (pin 18)', q0)
                m.add('State PC_ENABLE (pin 15)', pc_enable)
                m.add('State X_ENABLE (pin 16)', x_en)
                m.add('State Y_ENABLE (pin 17)', y_en)
                m.add('State /LOAD_INSTR (pin 14)', 1 - load_instr)
                m.add('State /LOAD_IMM (pin 19)', 1 - load_imm)
                m.add('State /LOAD_X, /LOAD_Y, /LOAD_AC (pins 20-22)', 1)
                m.add('State R/W (pin 23)', 1)
                m.add('Branch STALL (pin 19)', stall)
                m.add('Branch LOAD_PC_LOW (pin 21)', load_pc_low)
                m.add('Branch LOAD_PC_HIGH (pin 22)', 0)
                m.add('Branch BRANCH_BLOCK (pin 23)', 1)
                m.add('Branch /SRC_EN (pin 16)', 1 - src_en)
                m.add('Branch ALU_DONE (pin 18)', alu_done)
                m.add('Audio /AC_SEL (pin 21)', 0)          # I1 = 1
                m.add('Instruction register Q0-Q7', 1)
            if step == 14:
                pins = [15, 22, 21, 16, 20, 17, 19, 18]
                for n in range(8):
                    m.add('PC low Q%d (pin %d)' % (n, pins[n]), (lo >> n) & 1)
                m.add('PC low CO (pin 23)', co)
            if step == 15:
                pins = [15, 22, 21, 16, 20, 17, 19, 18]
                for n in range(8):
                    m.add('PC high Q%d = A%d (pin %d)' % (n, n + 8, pins[n]), (hi >> n) & 1)
        # clock edge
        if stall:
            n_q0, n_q1 = q0, q1
            n_x, n_y = x_en, y_en
        else:
            if s_fetch:               # data bus FF: source 11, mem 111 -> LOAD_MEM
                n_q1, n_q0 = 1, 0
                n_x, n_y = 1, 1       # mem 111 = [Y,X]
            elif s_lmem:
                n_q1, n_q0 = 1, 1
                n_x, n_y = x_en, y_en
            elif s_limm:
                n_q1, n_q0 = 1, 1
                n_x, n_y = x_en, y_en
            else:                     # EXEC -> FETCH
                n_q1, n_q0 = 0, 0
                n_x, n_y = x_en, y_en
        if load_pc_low:
            n_pc = (pc & 0xFF00) | 0xFF
        elif pc_enable and not stall:
            n_pc = (pc + 1) & 0xFFFF
        else:
            n_pc = pc
        q0, q1, x_en, y_en, pc = n_q0, n_q1, n_x, n_y, n_pc
        vid.clock(c)
    return m.rows()


def main(argv):
    only = None
    if '--step' in argv:
        only = int(argv[argv.index('--step') + 1])
    want = lambda s: only is None or only == s
    print('Clock %.3f MHz, frame %.4f Hz, line %.4f kHz\n' % (CLK_HZ / 1e6, FPS, CLK_HZ / 800 / 1e3))
    for s, t in ((3, 'Step 3: Sync PLD'), (4, 'Step 4: H counter PLD'), (5, 'Step 5: V counter PLD')):
        if want(s):
            print(table(run_video(s), t))
    if want(6):
        cases = [(0xFF, 3)] + [(0xFF ^ (1 << n), 3) for n in range(8)] + [(0xFF, 2), (0xFF, 0)]
        res = run_probes(cases)
        for pix, mode in cases:
            print(table(res[(pix, mode)], 'Step 6: color decoder, pixel %02X, mode %d' % (pix, mode)))
    if want(11):
        print(table(run_video(11), 'Step 11: audio slot PLD'))
    if want(12):
        print(table(run_video(12), 'Step 12: memory control PLD'))
    for s, t in ((13, 'Step 13: State PLD (and the Branch PLD), FF free run'), (14, 'Step 14: PC low'),
                 (15, 'Step 15: PC high')):
        if want(s):
            print(table(run_free_run(s), t))


if __name__ == '__main__':
    main(sys.argv[1:])
