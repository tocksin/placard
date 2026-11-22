// ============================================================
// image.cpp - pictures for the Placard's browser (see browser.h)
// ============================================================
//
// Reads a JPEG, PNG or GIF picture as its bytes come in and gives its
// rows, top to bottom, to a RowSink; the two sinks here scale the rows
// to the size wanted and turn them into the Placard's pixels.  Nothing
// keeps the whole picture: the most held is a band of rows.
//
//   JPEG  baseline, 8 bits, gray or YCbCr; read at 1/1, 1/2, 1/4 or 1/8
//         size, whichever is the smallest that still fills the width
//         wanted.  A progressive JPEG is read from its first scan alone,
//         so at 1/8 size.  Not read: arithmetic coding, 12 bits, CMYK.
//   PNG   every color type and depth; not interlaced ones.
//   GIF   the first picture of the file; not interlaced ones.
//
// Date: 2026-11-22
// ============================================================
#include "browser.h"
#include "image.h"

#include <math.h>
#include <stdlib.h>

namespace pb {

// ============================================================
// Inflate (RFC 1951), a byte at a time
// ============================================================
static const uint16_t LBASE[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
                                   67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint8_t LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t DBASE[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                   1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577};
static const uint8_t DEXT[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

Inflate::Inflate(Source &s)
    : in(s), wpos(0), copyLen(0), copyDist(0), stored(0), bitbuf(0), bitcnt(0), state(0), final(false), bad(false) {
  win = (uint8_t *)malloc(32768);
}

Inflate::~Inflate() { free(win); }

int Inflate::bits(int n) {
  while (bitcnt < n) {
    int c = in.get();
    if (c < 0) {
      bad = true;
      return 0;
    }
    bitbuf |= (uint32_t)c << bitcnt;
    bitcnt += 8;
  }
  int v = bitbuf & ((1u << n) - 1);
  bitbuf >>= n;
  bitcnt -= n;
  return v;
}

int Inflate::decode(const uint16_t *count, const uint16_t *symbol) {
  int code = 0, first = 0, index = 0;
  for (int len = 1; len <= 15; len++) {
    code |= bits(1);
    if (bad) return -1;
    int c = count[len];
    if (code - c < first) return symbol[index + (code - first)];
    index += c;
    first += c;
    first <<= 1;
    code <<= 1;
  }
  bad = true;
  return -1;
}

bool Inflate::build(const uint8_t *lens, int n, uint16_t *count, uint16_t *symbol) {
  uint16_t offs[16];
  for (int i = 0; i < 16; i++) count[i] = 0;
  for (int i = 0; i < n; i++) count[lens[i]]++;
  int left = 1;
  for (int len = 1; len <= 15; len++) {
    left = (left << 1) - count[len];
    if (left < 0) return false;                  // more codes than the lengths allow
  }
  offs[1] = 0;
  for (int len = 1; len < 15; len++) offs[len + 1] = offs[len] + count[len];
  for (int i = 0; i < n; i++)
    if (lens[i]) symbol[offs[lens[i]]++] = i;
  return true;
}

void Inflate::fixed() {
  uint8_t lens[288];
  int i = 0;
  for (; i < 144; i++) lens[i] = 8;
  for (; i < 256; i++) lens[i] = 9;
  for (; i < 280; i++) lens[i] = 7;
  for (; i < 288; i++) lens[i] = 8;
  build(lens, 288, lcount, lsym);
  for (i = 0; i < 30; i++) lens[i] = 5;
  build(lens, 30, dcount, dsym);
}

bool Inflate::dynamic() {
  static const uint8_t ORDER[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};
  uint8_t lens[320];
  int nlen = bits(5) + 257, ndist = bits(5) + 1, ncode = bits(4) + 4;
  if (bad || nlen > 286 || ndist > 30) return false;
  int i;
  for (i = 0; i < ncode; i++) lens[ORDER[i]] = bits(3);
  for (; i < 19; i++) lens[ORDER[i]] = 0;
  if (!build(lens, 19, lcount, lsym)) return false;
  i = 0;
  while (i < nlen + ndist) {
    int sym = decode(lcount, lsym);
    if (sym < 0) return false;
    if (sym < 16) {
      lens[i++] = sym;
      continue;
    }
    int prev = 0, rep;
    if (sym == 16) {
      if (i == 0) return false;
      prev = lens[i - 1];
      rep = 3 + bits(2);
    } else if (sym == 17) {
      rep = 3 + bits(3);
    } else {
      rep = 11 + bits(7);
    }
    if (bad || i + rep > nlen + ndist) return false;
    while (rep--) lens[i++] = prev;
  }
  if (!build(lens, nlen, lcount, lsym)) return false;
  return build(lens + nlen, ndist, dcount, dsym);
}

bool Inflate::skipGzipHeader() {
  uint8_t h[10];
  for (int i = 0; i < 10; i++) {
    int c = in.get();
    if (c < 0) return false;
    h[i] = c;
  }
  if (h[0] != 0x1F || h[1] != 0x8B || h[2] != 8) return false;
  if (h[3] & 4) {
    int n = in.get();
    n |= in.get() << 8;
    while (n-- > 0)
      if (in.get() < 0) return false;
  }
  for (int flag = 8; flag <= 16; flag <<= 1)     // the name, the comment
    if (h[3] & flag) {
      int c;
      do c = in.get();
      while (c > 0);
      if (c < 0) return false;
    }
  if (h[3] & 2) {
    in.get();
    in.get();
  }
  return true;
}

bool Inflate::skipZlibHeader() {
  int a = in.get(), b = in.get();
  return b >= 0 && (a & 15) == 8 && !(b & 0x20);
}

int Inflate::get() {
  if (!win || bad) return -1;
  for (;;) {
    if (copyLen) {
      uint8_t b = win[(wpos - copyDist) & 32767];
      copyLen--;
      win[wpos++ & 32767] = b;
      return b;
    }
    if (state == 0) {                            // a block's first bits
      if (final) return -1;
      final = bits(1) != 0;
      int type = bits(2);
      if (bad) return -1;
      if (type == 0) {
        bitbuf = 0;
        bitcnt = 0;
        int len = bits(16), nlen = bits(16);
        if (bad || (len ^ 0xFFFF) != nlen) {
          bad = true;
          return -1;
        }
        stored = len;
        state = 1;
      } else if (type == 1) {
        fixed();
        state = 2;
      } else if (type == 2 && dynamic()) {
        state = 2;
      } else {
        bad = true;
        return -1;
      }
    } else if (state == 1) {                     // bytes as they are
      if (!stored) {
        state = 0;
        continue;
      }
      int c = in.get();
      if (c < 0) {
        bad = true;
        return -1;
      }
      stored--;
      win[wpos++ & 32767] = c;
      return c;
    } else {
      int sym = decode(lcount, lsym);
      if (sym < 0) return -1;
      if (sym < 256) {
        win[wpos++ & 32767] = sym;
        return sym;
      }
      if (sym == 256) {
        state = 0;
        continue;
      }
      sym -= 257;
      if (sym >= 29) {
        bad = true;
        return -1;
      }
      int len = LBASE[sym] + bits(LEXT[sym]);
      int ds = decode(dcount, dsym);
      if (ds < 0 || ds >= 30) {
        bad = true;
        return -1;
      }
      copyDist = DBASE[ds] + bits(DEXT[ds]);
      copyLen = len;
      if (bad) return -1;
    }
  }
}

namespace {

struct Replay : Source {              // the bytes looked at first, then the rest
  Source &in;
  uint8_t b[4];
  int n, i;
  explicit Replay(Source &s) : in(s), n(0), i(0) {}
  int get() { return i < n ? b[i++] : in.get(); }
};

inline uint8_t clamp8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }

// ============================================================
// JPEG
// ============================================================
const uint8_t ZZ[64] = {0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
                        41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
                        30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

struct Huff {
  uint8_t count[17];
  uint8_t vals[256];
  int32_t maxcode[17], mincode[17], valptr[17];
};

const char DONE[] = "done";

struct Jpeg {
  Source &in;
  RowSink &sink;
  uint16_t qt[4][64];
  Huff *ht;                           // 0-3 DC, 4-7 AC
  struct Comp {
    uint8_t id, h, v, tq, td, ta;
    int pred;
    uint8_t *plane;
    int pw;
    int bw, bh;                       // its blocks, whole MCUs
    int16_t *dc;                      // progressive, kept: a block's DC
    bool dcDone;
  } comp[3];
  int ncomp, W, H, hmax, vmax, restart, n, al;
  int mcux, mcuy, outW, outH;
  bool progressive, haveFrame, begun;
  uint32_t bb;
  int bc;
  bool hit, dead;
  int marker;
  int16_t cosT[8][8];                 // for the n in use: [x][u], 2048 = 1/2
  uint8_t *planes, *rgb;
  // a progressive JPEG kept in part: the first K coefficients of the Y blocks
  int K, acTo;
  int8_t *acs;
  uint8_t acAl[8];

  Jpeg(Source &i, RowSink &s) : in(i), sink(s), ht(0), ncomp(0), restart(0), n(8), al(0), progressive(false),
                                haveFrame(false), begun(false), bb(0), bc(0), hit(false), dead(false), marker(0),
                                planes(0), rgb(0), K(0), acTo(0), acs(0) {
    memset(qt, 0, sizeof(qt));
    memset(comp, 0, sizeof(comp));
    memset(acAl, 0, sizeof(acAl));
  }
  ~Jpeg() {
    free(ht);
    free(planes);
    free(rgb);
    free(acs);
    for (int i = 0; i < 3; i++) free(comp[i].dc);
  }

  int u16() {
    int a = in.get(), b = in.get();
    return b < 0 ? -1 : a << 8 | b;
  }

  int bit() {
    if (!bc) {
      int c = 0;
      if (!hit && !dead) {
        c = in.get();
        if (c < 0) {
          dead = true;
          c = 0;
        } else if (c == 0xFF) {
          int d;
          do d = in.get();
          while (d == 0xFF);
          if (d < 0) dead = true;
          if (d > 0) {                           // a marker: the scan's bits end here
            hit = true;
            marker = d;
            c = 0;
          }
        }
      }
      bb = c;
      bc = 8;
    }
    bc--;
    return (bb >> bc) & 1;
  }

  int receive(int s) {
    int v = 0;
    while (s--) v = v << 1 | bit();
    return v;
  }

  static int extend(int v, int s) { return v < (1 << (s - 1)) ? v - (1 << s) + 1 : v; }

  int huff(const Huff &h) {
    int code = bit();
    for (int i = 1; i <= 16; i++) {
      if (code <= h.maxcode[i]) return h.vals[(h.valptr[i] + code - h.mincode[i]) & 255];
      code = code << 1 | bit();
    }
    dead = true;
    return 0;
  }

  void sync() {                                  // a restart: the marker, the predictions
    bc = 0;
    if (hit) {
      hit = false;
      if ((marker & 0xF8) != 0xD0) dead = true;
    } else {
      int c;
      do c = in.get();
      while (c >= 0 && c != 0xFF);
      do c = in.get();
      while (c == 0xFF);
      if ((c & 0xF8) != 0xD0) dead = true;
    }
    for (int i = 0; i < ncomp; i++) comp[i].pred = 0;
  }

  int nextMarker() {                             // the next marker that is not a restart
    if (hit) {
      hit = false;
      bc = 0;
      return marker;
    }
    bc = 0;
    for (;;) {
      int c = in.get();
      if (c < 0) return -1;
      if (c != 0xFF) continue;
      do c = in.get();
      while (c == 0xFF);
      if (c < 0) return -1;
      if (c == 0 || c == 0x01 || (c >= 0xD0 && c <= 0xD8)) continue;
      return c;
    }
  }

  bool readDht(int len) {
    while (len > 0) {
      int tc = in.get();
      if (tc < 0 || (tc & 15) > 3 || (tc >> 4) > 1) return false;
      Huff &h = ht[(tc >> 4) * 4 + (tc & 15)];
      int total = 0;
      h.count[0] = 0;
      for (int i = 1; i <= 16; i++) {
        h.count[i] = in.get();
        total += h.count[i];
      }
      if (total > 256) return false;
      for (int i = 0; i < total; i++) h.vals[i] = in.get();
      int code = 0, k = 0;
      for (int i = 1; i <= 16; i++) {
        h.valptr[i] = k;
        h.mincode[i] = code;
        code += h.count[i];
        k += h.count[i];
        h.maxcode[i] = h.count[i] ? code - 1 : -1;
        code <<= 1;
      }
      len -= 17 + total;
    }
    return true;
  }

  void makeCos() {
    for (int x = 0; x < n; x++)
      for (int u = 0; u < n; u++)
        cosT[x][u] = (int16_t)lround(2048.0 * (u ? 1.0 : 0.70710678) * cos((2 * x + 1) * u * 3.14159265358979 / (2 * n)));
  }

  // the block's n x n pixels from its coefficients (b, natural order)
  void idct(const int32_t *b, uint8_t *out, int stride) {
    if (n == 1) {
      out[0] = clamp8(((b[0] + 4) >> 3) + 128);
      return;
    }
    int32_t tmp[64];
    for (int v = 0; v < n; v++)
      for (int x = 0; x < n; x++) {
        int32_t s = 0;
        for (int u = 0; u < n; u++) s += cosT[x][u] * b[v * 8 + u];
        s >>= 10;
        tmp[v * 8 + x] = s < -65535 ? -65535 : s > 65535 ? 65535 : s;
      }
    for (int x = 0; x < n; x++)
      for (int y = 0; y < n; y++) {
        int32_t s = 0;
        for (int v = 0; v < n; v++) s += cosT[y][v] * tmp[v * 8 + x];
        out[y * stride + x] = clamp8(((s + 8192) >> 14) + 128);
      }
  }

  void block(Comp &c, int32_t *b) {              // a block of a baseline scan, or its DC alone
    memset(b, 0, 64 * sizeof(int32_t));
    int t = huff(ht[c.td]) & 15;
    c.pred += t ? extend(receive(t), t) : 0;
    b[0] = c.pred * (1 << al) * qt[c.tq][0];
    if (progressive) return;
    const Huff &ac = ht[4 + c.ta];
    for (int k = 1; k < 64;) {
      int rs = huff(ac), r = rs >> 4, s = rs & 15;
      if (!s) {
        if (r != 15) break;
        k += 16;
        continue;
      }
      k += r;
      if (k > 63) break;
      int v = extend(receive(s), s) * qt[c.tq][k];
      b[ZZ[k]] = v < -16383 ? -16383 : v > 16383 ? 16383 : v;
      k++;
    }
  }

  // the size the rows are made at, and the room for a band of them
  const char *setup() {
    outW = (W * n + 7) / 8;
    outH = (H * n + 7) / 8;
    long total = 0;
    for (int i = 0; i < ncomp; i++) {
      comp[i].pw = mcux * comp[i].h * n;
      total += (long)comp[i].pw * comp[i].v * n;
    }
    if (total > 44000 || outW > 2048) return "The picture is too large";
    planes = (uint8_t *)malloc(total);
    rgb = (uint8_t *)malloc(outW * 3);
    if (!planes || !rgb) return "Not enough memory for the picture";
    uint8_t *p = planes;
    for (int i = 0; i < ncomp; i++) {
      comp[i].plane = p;
      p += comp[i].pw * comp[i].v * n;
      comp[i].pred = 0;
    }
    makeCos();
    begun = true;
    return sink.begin(outW, outH) ? 0 : "";
  }

  // the rows of the band in the planes: to color, to the sink
  void rows(int &y) {
    for (int r = 0; r < vmax * n && y < outH; r++, y++) {
      const uint8_t *ys = comp[0].plane + (r * comp[0].v / vmax) * comp[0].pw;
      if (ncomp == 1) {
        for (int x = 0; x < outW; x++) rgb[3 * x] = rgb[3 * x + 1] = rgb[3 * x + 2] = ys[x];
      } else {
        const uint8_t *cb = comp[1].plane + (r * comp[1].v / vmax) * comp[1].pw;
        const uint8_t *cr = comp[2].plane + (r * comp[2].v / vmax) * comp[2].pw;
        int h0 = comp[0].h, h1 = comp[1].h, h2 = comp[2].h;
        for (int x = 0; x < outW; x++) {
          int yy = ys[x * h0 / hmax], u = cb[x * h1 / hmax] - 128, v = cr[x * h2 / hmax] - 128;
          rgb[3 * x] = clamp8(yy + ((359 * v) >> 8));
          rgb[3 * x + 1] = clamp8(yy - ((88 * u + 183 * v) >> 8));
          rgb[3 * x + 2] = clamp8(yy + ((454 * u) >> 8));
        }
      }
      sink.row(rgb);
    }
  }

  // a scan that gives every block whole (baseline), or the first scan of a
  // progressive JPEG taken alone (its DC: the picture at 1/8)
  const char *scan(int ns) {
    if (ns != ncomp) return "This kind of JPEG is not supported";
    const char *err = setup();
    if (err) return err;
    int32_t b[64];
    int count = 0, y = 0;
    for (int my = 0; my < mcuy && y < outH; my++) {
      for (int mx = 0; mx < mcux; mx++) {
        if (restart && count && count % restart == 0) sync();
        count++;
        for (int i = 0; i < ncomp; i++) {
          Comp &c = comp[i];
          for (int by = 0; by < c.v; by++)
            for (int bx = 0; bx < c.h; bx++) {
              block(c, b);
              idct(b, c.plane + by * n * c.pw + (mx * c.h + bx) * n, c.pw);
            }
        }
      }
      rows(y);
      if (dead && y < outH / 2) return "The picture ends early";
    }
    return 0;
  }

  // ---- a progressive JPEG, kept in part
  void skipScan() {                              // to the marker after the scan's bits
    for (;;) {
      int c = in.get();
      if (c < 0) {
        dead = true;
        return;
      }
      if (c != 0xFF) continue;
      do c = in.get();
      while (c == 0xFF);
      if (c < 0) dead = true;
      if (c > 0 && (c < 0xD0 || c > 0xD7)) {
        hit = true;
        marker = c;
        return;
      }
      if (c < 0) return;
    }
  }

  // one scan; true when enough of the picture has been read
  bool progScan(int ns, const int *which, int ss, int se, int ah) {
    if (ah || ss > se || (ss && ns != 1) || (!ss && se)) {       // a second pass over bits already had: not used
      skipScan();
      return false;
    }
    bc = 0;
    hit = false;
    for (int i = 0; i < ncomp; i++) comp[i].pred = 0;
    int count = 0;
    if (!ss) {                                   // DC
      if (ns > 1) {
        for (int my = 0; my < mcuy && !dead; my++)
          for (int mx = 0; mx < mcux; mx++) {
            if (restart && count && count % restart == 0) sync();
            count++;
            for (int j = 0; j < ns; j++) {
              Comp &c = comp[which[j]];
              for (int by = 0; by < c.v; by++)
                for (int bx = 0; bx < c.h; bx++) {
                  int t = huff(ht[c.td]) & 15;
                  c.pred += t ? extend(receive(t), t) : 0;
                  c.dc[(my * c.v + by) * c.bw + mx * c.h + bx] = (int16_t)(c.pred * (1 << al));
                }
            }
          }
      } else {
        Comp &c = comp[which[0]];
        int cw = ((W * c.h + hmax - 1) / hmax + 7) / 8, chh = ((H * c.v + vmax - 1) / vmax + 7) / 8;
        for (int by = 0; by < chh && !dead; by++)
          for (int bx = 0; bx < cw; bx++) {
            if (restart && count && count % restart == 0) sync();
            count++;
            int t = huff(ht[c.td]) & 15;
            c.pred += t ? extend(receive(t), t) : 0;
            c.dc[by * c.bw + bx] = (int16_t)(c.pred * (1 << al));
          }
      }
      for (int j = 0; j < ns; j++) comp[which[j]].dcDone = true;
    } else if (which[0] == 0 && ss < K && acTo == ss - 1) {      // the Y blocks' next coefficients
      Comp &c = comp[0];
      const Huff &ac = ht[4 + c.ta];
      int cw = ((W * c.h + hmax - 1) / hmax + 7) / 8, chh = ((H * c.v + vmax - 1) / vmax + 7) / 8;
      int run = 0;
      for (int k = ss; k <= se && k < K; k++) acAl[k] = (uint8_t)al;
      for (int by = 0; by < chh && !dead; by++)
        for (int bx = 0; bx < cw; bx++) {
          if (restart && count && count % restart == 0) {
            sync();
            run = 0;
          }
          count++;
          if (run) {
            run--;
            continue;
          }
          int8_t *a = acs + (long)(by * c.bw + bx) * (K - 1);
          for (int k = ss; k <= se;) {
            int rs = huff(ac), r = rs >> 4, s = rs & 15;
            if (!s) {
              if (r < 15) {
                run = (1 << r) - 1;
                if (r) run += receive(r);
                break;
              }
              k += 16;
              continue;
            }
            k += r;
            int v = extend(receive(s), s);
            if (k < K) a[k - 1] = (int8_t)(v < -127 ? -127 : v > 127 ? 127 : v);
            k++;
          }
        }
      acTo = se;
    } else {
      skipScan();
      return false;
    }
    for (int i = 0; i < ncomp; i++)
      if (!comp[i].dcDone) return false;
    return K <= 1 || acTo >= K - 1;
  }

  const char *render() {
    for (int i = 0; i < ncomp; i++)
      if (!comp[i].dcDone) return "The picture ends early";
    const char *err = setup();
    if (err) return err;
    int32_t b[64];
    int y = 0;
    for (int my = 0; my < mcuy && y < outH; my++) {
      for (int mx = 0; mx < mcux; mx++)
        for (int i = 0; i < ncomp; i++) {
          Comp &c = comp[i];
          for (int by = 0; by < c.v; by++)
            for (int bx = 0; bx < c.h; bx++) {
              long at = (long)(my * c.v + by) * c.bw + mx * c.h + bx;
              memset(b, 0, sizeof(b));
              b[0] = c.dc[at] * qt[c.tq][0];
              if (i == 0)
                for (int k = 1; k < K && k <= acTo; k++) b[ZZ[k]] = acs[at * (K - 1) + k - 1] * (1 << acAl[k]) * qt[c.tq][k];
              idct(b, c.plane + by * n * c.pw + (mx * c.h + bx) * n, c.pw);
            }
        }
      rows(y);
    }
    return 0;
  }

  const char *sos() {
    int ns = in.get(), which[3] = {0, 0, 0};
    if (ns < 1 || ns > ncomp) return "This kind of JPEG is not supported";
    for (int j = 0; j < ns; j++) {
      int id = in.get(), t = in.get(), i = 0;
      while (i < ncomp && comp[i].id != id) i++;
      if (t < 0 || i == ncomp) return "This kind of JPEG is not supported";
      which[j] = i;
      comp[i].td = (t >> 4) & 3;
      comp[i].ta = t & 3;
    }
    int ss = in.get(), se = in.get(), a = in.get();
    if (a < 0) return "The picture ends early";
    if (!progressive) {
      al = 0;
      int target = sink.want(W, H);
      n = 8;
      while (n > 1 && (W * (n / 2) + 7) / 8 >= target) n /= 2;
      const char *e = scan(ns);
      return e ? e : DONE;
    }
    al = a & 15;
    if (!K) {                                    // the first scan: how much of the picture can be kept
      int target = sink.want(W, H);
      long blocks = 0, yblocks = (long)comp[0].bw * comp[0].bh;
      for (int i = 0; i < ncomp; i++) blocks += (long)comp[i].bw * comp[i].bh;
      K = 1;
      n = 1;
      if ((W + 7) / 8 < target && blocks * 2 + yblocks * 2 <= 40000) K = 3, n = 2;
      if ((W + 3) / 4 < target && blocks * 2 + yblocks * 5 <= 40000) K = 6, n = 4;
      if (K == 1 && ns == ncomp && !ss && !se && !(a >> 4)) {      // its DC alone, as it comes
        const char *e = scan(ns);
        return e ? e : DONE;
      }
      if (blocks * 2 > 60000) return "The picture is too large";
      for (int i = 0; i < ncomp; i++) {
        comp[i].dc = (int16_t *)calloc((long)comp[i].bw * comp[i].bh, sizeof(int16_t));
        if (!comp[i].dc) return "Not enough memory for the picture";
      }
      if (K > 1) {
        acs = (int8_t *)calloc(yblocks, K - 1);
        if (!acs) return "Not enough memory for the picture";
      }
    }
    if (progScan(ns, which, ss, se, a >> 4)) {
      const char *e = render();
      return e ? e : DONE;
    }
    return 0;                                    // more scans to read
  }

  const char *run() {
    ht = (Huff *)calloc(8, sizeof(Huff));
    if (!ht) return "Not enough memory for the picture";
    if (in.get() != 0xFF || in.get() != 0xD8) return "Not a JPEG picture";
    for (;;) {
      int c = nextMarker();
      if (c < 0 || c == 0xD9) {
        if (K && !begun) return render();        // what was read of a progressive JPEG
        return begun ? 0 : c < 0 ? "The picture ends early" : "The picture has no pixels";
      }
      int len = u16() - 2;
      if (len < 0) return "The picture ends early";
      if (c == 0xC0 || c == 0xC1 || c == 0xC2) {
        progressive = c == 0xC2;
        int prec = in.get();
        H = u16();
        W = u16();
        ncomp = in.get();
        if (prec != 8 || (ncomp != 1 && ncomp != 3) || W <= 0 || H <= 0) return "This kind of JPEG is not supported";
        hmax = vmax = 1;
        for (int i = 0; i < ncomp; i++) {
          comp[i].id = in.get();
          int hv = in.get();
          comp[i].h = hv >> 4;
          comp[i].v = hv & 15;
          comp[i].tq = in.get() & 3;
          if (ncomp == 1) comp[i].h = comp[i].v = 1;
          if (comp[i].h < 1 || comp[i].h > 4 || comp[i].v < 1 || comp[i].v > 4) return "This kind of JPEG is not supported";
          if (comp[i].h > hmax) hmax = comp[i].h;
          if (comp[i].v > vmax) vmax = comp[i].v;
        }
        mcux = (W + 8 * hmax - 1) / (8 * hmax);
        mcuy = (H + 8 * vmax - 1) / (8 * vmax);
        for (int i = 0; i < ncomp; i++) {
          comp[i].bw = mcux * comp[i].h;
          comp[i].bh = mcuy * comp[i].v;
        }
        haveFrame = true;
      } else if (c >= 0xC3 && c <= 0xCF && c != 0xC4 && c != 0xC8 && c != 0xCC) {
        return "This kind of JPEG is not supported";
      } else if (c == 0xC4) {
        if (!readDht(len)) return "The picture is damaged";
      } else if (c == 0xDB) {
        while (len > 0) {
          int pq = in.get();
          if (pq < 0) return "The picture ends early";
          for (int i = 0; i < 64; i++) qt[pq & 3][i] = (pq >> 4) ? u16() : in.get();
          len -= 1 + ((pq >> 4) ? 128 : 64);
        }
      } else if (c == 0xDD) {
        restart = u16();
      } else if (c == 0xDA) {
        if (!haveFrame) return "The picture is damaged";
        const char *e = sos();
        if (e) return e == DONE ? 0 : e;
      } else {
        while (len-- > 0)
          if (in.get() < 0) return "The picture ends early";
      }
    }
  }
};

// ============================================================
// PNG
// ============================================================
struct Idat : Source {                // the IDAT chunks' bytes, one after the other
  Source &in;
  uint32_t left;
  bool first, done;
  explicit Idat(Source &s, uint32_t len) : in(s), left(len), first(true), done(false) {}
  int get() {
    while (!left) {
      if (done) return -1;
      uint8_t h[12];
      for (int i = 0; i < 12; i++) {             // the last chunk's check, the next one's head
        int c = in.get();
        if (c < 0) return -1;
        h[i] = c;
      }
      if (memcmp(h + 8, "IDAT", 4)) {
        done = true;
        return -1;
      }
      left = (uint32_t)h[4] << 24 | h[5] << 16 | h[6] << 8 | h[7];
    }
    left--;
    return in.get();
  }
};

const char *png(Source &in, RowSink &sink) {
  uint8_t pal[768], alpha[256];
  uint8_t h[8];
  memset(alpha, 255, sizeof(alpha));
  memset(pal, 0, sizeof(pal));
  for (int i = 0; i < 8; i++) in.get();
  int W = 0, H = 0, depth = 0, type = 0;
  for (;;) {
    for (int i = 0; i < 8; i++) {
      int c = in.get();
      if (c < 0) return "The picture ends early";
      h[i] = c;
    }
    uint32_t len = (uint32_t)h[0] << 24 | h[1] << 16 | h[2] << 8 | h[3];
    if (!memcmp(h + 4, "IDAT", 4)) {
      if (!W) return "The picture is damaged";
      static const uint8_t CH[7] = {1, 0, 3, 1, 2, 0, 4};
      int ch = CH[type], bpp = (ch * depth + 7) / 8;
      long rowBytes = ((long)W * ch * depth + 7) / 8;
      if (rowBytes > 16384) return "The picture is too large";
      int target = sink.want(W, H);
      (void)target;
      Idat idat(in, len);
      Inflate z(idat);
      uint8_t *cur = (uint8_t *)calloc(1, rowBytes + 1), *prev = (uint8_t *)calloc(1, rowBytes + 1);
      uint8_t *rgb = (uint8_t *)malloc(W * 3);
      const char *err = 0;
      if (!z.ok() || !cur || !prev || !rgb) err = "Not enough memory for the picture";
      else if (!z.skipZlibHeader()) err = "The picture is damaged";
      else if (!sink.begin(W, H)) err = "";
      for (int y = 0; !err && y < H; y++) {
        int f = z.get();
        if (f < 0) {
          if (y < H / 2) err = "The picture ends early";
          break;
        }
        for (long i = 0; i < rowBytes; i++) {
          int c = z.get();
          if (c < 0) c = 0;
          int a = i >= bpp ? cur[i - bpp] : 0, b = prev[i], cc = i >= bpp ? prev[i - bpp] : 0;
          if (f == 1) c += a;
          else if (f == 2) c += b;
          else if (f == 3) c += (a + b) >> 1;
          else if (f == 4) {
            int p = a + b - cc, pa = abs(p - a), pb2 = abs(p - b), pc = abs(p - cc);
            c += (pa <= pb2 && pa <= pc) ? a : pb2 <= pc ? b : cc;
          }
          cur[i] = c;
        }
        int step = depth == 16 ? 2 : 1;
        for (int x = 0; x < W; x++) {
          int r, g, b, a = 255;
          if (type == 0 || type == 3) {
            int v;
            if (depth >= 8) v = cur[x * step];
            else v = (cur[x * depth / 8] >> (8 - depth - (x * depth) % 8)) & ((1 << depth) - 1);
            if (type == 3) {
              r = pal[3 * v];
              g = pal[3 * v + 1];
              b = pal[3 * v + 2];
              a = alpha[v];
            } else {
              r = g = b = depth >= 8 ? v : v * 255 / ((1 << depth) - 1);
            }
          } else if (type == 4) {
            r = g = b = cur[x * 2 * step];
            a = cur[x * 2 * step + step];
          } else {
            r = cur[x * ch * step];
            g = cur[x * ch * step + step];
            b = cur[x * ch * step + 2 * step];
            if (type == 6) a = cur[x * ch * step + 3 * step];
          }
          if (a != 255) {                        // on white
            r = (r * a + 255 * (255 - a)) / 255;
            g = (g * a + 255 * (255 - a)) / 255;
            b = (b * a + 255 * (255 - a)) / 255;
          }
          rgb[3 * x] = r;
          rgb[3 * x + 1] = g;
          rgb[3 * x + 2] = b;
        }
        sink.row(rgb);
        uint8_t *t = cur;
        cur = prev;
        prev = t;
      }
      free(cur);
      free(prev);
      free(rgb);
      return err;
    }
    if (!memcmp(h + 4, "IHDR", 4) && len == 13) {
      uint8_t d[13];
      for (int i = 0; i < 13; i++) d[i] = in.get();
      W = d[0] << 24 | d[1] << 16 | d[2] << 8 | d[3];
      H = d[4] << 24 | d[5] << 16 | d[6] << 8 | d[7];
      depth = d[8];
      type = d[9];
      if (W <= 0 || H <= 0 || W > 8192 || type > 6 || type == 1 || type == 5 || depth > 16) return "The picture is damaged";
      if (d[12]) return "Interlaced PNG pictures are not supported";
      len = 0;
    } else if (!memcmp(h + 4, "PLTE", 4) && len <= 768) {
      for (uint32_t i = 0; i < len; i++) pal[i] = in.get();
      len = 0;
    } else if (!memcmp(h + 4, "tRNS", 4) && len <= 256 && type == 3) {
      for (uint32_t i = 0; i < len; i++) alpha[i] = in.get();
      len = 0;
    } else if (!memcmp(h + 4, "IEND", 4)) {
      return "The picture has no pixels";
    }
    for (uint32_t i = 0; i < len + 4; i++)       // what is left of the chunk, its check
      if (in.get() < 0) return "The picture ends early";
  }
}

// ============================================================
// GIF
// ============================================================
struct Blocks : Source {              // a GIF's data blocks as one run of bytes
  Source &in;
  int left;
  bool done;
  explicit Blocks(Source &s) : in(s), left(0), done(false) {}
  int get() {
    if (done) return -1;
    if (!left) {
      left = in.get();
      if (left <= 0) {
        done = true;
        return -1;
      }
    }
    left--;
    return in.get();
  }
};

const char *gif(Source &in, RowSink &sink) {
  uint8_t pal[768];
  memset(pal, 0, sizeof(pal));
  uint8_t h[13];
  for (int i = 0; i < 13; i++) {
    int c = in.get();
    if (c < 0) return "The picture ends early";
    h[i] = c;
  }
  if (h[10] & 0x80)
    for (int i = 0; i < 3 << ((h[10] & 7) + 1); i++) pal[i] = in.get();
  int trans = -1;
  for (;;) {
    int c = in.get();
    if (c < 0 || c == 0x3B) return "The picture has no pixels";
    if (c == 0x21) {
      int label = in.get();
      Blocks ext(in);
      if (label == 0xF9) {
        int flags = ext.get();
        ext.get();
        ext.get();
        int t = ext.get();
        if (flags & 1) trans = t;
      }
      while (ext.get() >= 0) {
      }
      continue;
    }
    if (c != 0x2C) return "The picture is damaged";
    uint8_t d[9];
    for (int i = 0; i < 9; i++) d[i] = in.get();
    int W = d[4] | d[5] << 8, H = d[6] | d[7] << 8;
    if (W <= 0 || H <= 0 || W > 8192) return "The picture is damaged";
    bool lace = (d[8] & 0x40) != 0;                // its rows out of order: kept whole when it is small
    if (lace && (long)W * H > 50000) return "This interlaced GIF is too large";
    if (d[8] & 0x80)
      for (int i = 0; i < 3 << ((d[8] & 7) + 1); i++) pal[i] = in.get();
    int minBits = in.get();
    if (minBits < 2 || minBits > 8) return "The picture is damaged";
    sink.want(W, H);
    uint16_t *prefix = (uint16_t *)malloc(4096 * 2);
    uint8_t *suffix = (uint8_t *)malloc(4096), *stack = (uint8_t *)malloc(4100);
    uint8_t *rgb = (uint8_t *)malloc(W * 3);
    uint8_t *whole = lace ? (uint8_t *)malloc((long)W * H) : 0;
    const char *err = 0;
    if (!prefix || !suffix || !stack || !rgb || (lace && !whole)) err = "Not enough memory for the picture";
    else if (!sink.begin(W, H)) err = "";
    if (!err) {
      Blocks data(in);
      int laceRow = 0, lacePass = 0;
      int clear = 1 << minBits, avail = clear + 2, size = minBits + 1, old = -1, first = 0;
      uint32_t acc = 0;
      int nb = 0, x = 0, y = 0, sp = 0;
      for (int i = 0; i < clear; i++) suffix[i] = i;
      while (y < H) {
        while (nb < size) {
          int b = data.get();
          if (b < 0) break;
          acc |= (uint32_t)b << nb;
          nb += 8;
        }
        if (nb < size) break;
        int code = acc & ((1 << size) - 1);
        acc >>= size;
        nb -= size;
        if (code == clear) {
          avail = clear + 2;
          size = minBits + 1;
          old = -1;
          continue;
        }
        if (code == clear + 1) break;
        if (old < 0) {
          if (code >= clear) break;
          stack[sp++] = first = code;
        } else {
          int cur = code;
          if (cur >= avail) {
            stack[sp++] = first;
            cur = old;
          }
          while (cur >= clear && sp < 4096) {
            stack[sp++] = suffix[cur];
            cur = prefix[cur];
          }
          stack[sp++] = first = cur;
          if (avail < 4096) {
            prefix[avail] = old;
            suffix[avail] = first;
            avail++;
            if (avail == (1 << size) && size < 12) size++;
          }
        }
        old = code;
        while (sp && y < H) {
          int v = stack[--sp];
          if (lace) {
            whole[(long)laceRow * W + x] = (uint8_t)v;
            if (++x == W) {
              static const uint8_t STEP[4] = {8, 8, 4, 2}, FIRST[4] = {0, 4, 2, 1};
              x = 0;
              y++;
              laceRow += STEP[lacePass];
              while (laceRow >= H && lacePass < 3) laceRow = FIRST[++lacePass];
              if (laceRow >= H) y = H;
            }
            continue;
          }
          if (v == trans) rgb[3 * x] = rgb[3 * x + 1] = rgb[3 * x + 2] = 255;
          else memcpy(rgb + 3 * x, pal + 3 * v, 3);
          if (++x == W) {
            sink.row(rgb);
            x = 0;
            y++;
          }
        }
        sp = 0;
      }
      if (y < H / 2) err = "The picture ends early";
      for (int r = 0; lace && !err && r < H; r++) {
        for (x = 0; x < W; x++) {
          int v = whole[(long)r * W + x];
          if (v == trans) rgb[3 * x] = rgb[3 * x + 1] = rgb[3 * x + 2] = 255;
          else memcpy(rgb + 3 * x, pal + 3 * v, 3);
        }
        sink.row(rgb);
      }
    }
    free(prefix);
    free(suffix);
    free(stack);
    free(rgb);
    free(whole);
    return err;
  }
}

}  // namespace

const char *decodeImage(Source &in, RowSink &out) {
  Replay r(in);
  for (r.n = 0; r.n < 4; r.n++) {
    int c = in.get();
    if (c < 0) return "The picture is empty";
    r.b[r.n] = c;
  }
  if (r.b[0] == 0xFF && r.b[1] == 0xD8) {
    Jpeg *j = new Jpeg(r, out);
    const char *e = j->run();
    delete j;
    return e;
  }
  if (r.b[0] == 0x89 && r.b[1] == 'P') return png(r, out);
  if (r.b[0] == 'G' && r.b[1] == 'I' && r.b[2] == 'F') return gif(r, out);
  if (r.b[0] == 'R' && r.b[1] == 'I' && r.b[2] == 'F') return "WebP pictures are not supported";
  if (r.b[0] == '<') return "SVG drawings are not supported";
  return "This kind of picture is not supported";
}

// ============================================================
// The sinks: scale, then the Placard's pixels
// ============================================================
Scaler::Scaler() : tw(0), th(0), sw(0), sh(0), sy(0), ty(0), rows(0), refused(false), acc(0), line(0) {}

Scaler::~Scaler() {
  free(acc);
  free(line);
}

int Scaler::want(int w, int h) {
  refused = !fit(w, h);
  return refused ? 1 : tw;
}

bool Scaler::begin(int w, int h) {
  if (refused || tw < 1 || th < 1) return false;
  sw = w;
  sh = h;
  sy = ty = rows = 0;
  acc = (uint32_t *)calloc(tw * 3, sizeof(uint32_t));
  line = (uint8_t *)malloc(tw * 3);
  return acc && line && start();
}

void Scaler::row(const uint8_t *rgb) {
  while (ty < th) {
    int y0 = (long)ty * sh / th, y1 = (long)(ty + 1) * sh / th;
    if (y1 <= y0) y1 = y0 + 1;
    if (sy < y0) break;
    for (int x = 0; x < tw; x++) {
      int x0 = (long)x * sw / tw, x1 = (long)(x + 1) * sw / tw;
      if (x1 <= x0) x1 = x0 + 1;
      uint32_t *a = acc + 3 * x;
      for (int s = x0; s < x1; s++) {
        a[0] += rgb[3 * s];
        a[1] += rgb[3 * s + 1];
        a[2] += rgb[3 * s + 2];
      }
    }
    rows++;
    if (sy + 1 < y1) break;
    for (int x = 0; x < tw; x++) {
      int x0 = (long)x * sw / tw, x1 = (long)(x + 1) * sw / tw;
      if (x1 <= x0) x1 = x0 + 1;
      uint32_t d = (uint32_t)(x1 - x0) * rows;
      for (int k = 0; k < 3; k++) line[3 * x + k] = (acc[3 * x + k] + d / 2) / d;
    }
    out(ty, line);
    ty++;
    rows = 0;
    memset(acc, 0, tw * 3 * sizeof(uint32_t));
  }
  sy++;
}

// ---- a picture in the page: 1 bit a pixel, bit 0 the left pixel, 1 = white
MonoSink::MonoSink(uint8_t *buf, long room, int maxW, int maxH)
    : wbytes(0), why(0), buf(buf), room(room), maxW(maxW), maxH(maxH), e0(0), e1(0), e2(0) {}

MonoSink::~MonoSink() {
  free(e0);
  free(e1);
  free(e2);
}

bool MonoSink::fit(int w, int h) {
  if (w < 12 || h < 12) {
    why = "";                                    // a spacer or a tracking dot: nothing to show
    return false;
  }
  tw = w < maxW ? w : maxW;
  th = (long)h * tw / w;
  if (th > maxH) {
    th = maxH;
    tw = (long)w * th / h;
  }
  if (tw < 1) tw = 1;
  if (th < 1) th = 1;
  wbytes = (tw + 7) / 8;
  if ((long)wbytes * th > room) {
    why = "no room";
    return false;
  }
  return true;
}

bool MonoSink::start() {
  e0 = (int16_t *)calloc(tw + 4, sizeof(int16_t));
  e1 = (int16_t *)calloc(tw + 4, sizeof(int16_t));
  e2 = (int16_t *)calloc(tw + 4, sizeof(int16_t));
  memset(buf, 0xFF, (long)wbytes * th);
  return e0 && e1 && e2;
}

void MonoSink::out(int y, const uint8_t *rgb) {  // Atkinson's dither
  uint8_t *o = buf + (long)y * wbytes;
  for (int x = 0; x < tw; x++) {
    int v = ((77 * rgb[3 * x] + 150 * rgb[3 * x + 1] + 29 * rgb[3 * x + 2]) >> 8) + e0[x + 1];
    int q = v >= 128 ? 255 : 0;
    if (!q) o[x >> 3] &= ~(1 << (x & 7));
    int d = (v - q) >> 3;
    e0[x + 2] += d;
    e0[x + 3] += d;
    e1[x] += d;
    e1[x + 1] += d;
    e1[x + 2] += d;
    e2[x + 1] += d;
  }
  int16_t *t = e0;
  e0 = e1;
  e1 = e2;
  e2 = t;
  memset(e2, 0, (tw + 4) * sizeof(int16_t));
}

// ---- a picture alone: the board's 256 colors (GGG BB RRR), wide rows of
// 240; a pixel is 8 x 2 (80 across) or 4 x 2 (160 across) of the 640 x 480
ColorSink::ColorSink(uint8_t *buf, int wide) : buf(buf), wide(wide), ox(0), oy(0), cur(0), next(0) {}

ColorSink::~ColorSink() {
  free(cur);
  free(next);
}

bool ColorSink::fit(int w, int h) {
  long dw, dh;                                   // its place on the 640 x 480, at most 4 times its size
  if ((long)w * 480 > (long)h * 640) {
    dw = w * 4L < 640 ? w * 4L : 640;
    dh = dw * h / w;
  } else {
    dh = h * 4L < 480 ? h * 4L : 480;
    dw = dh * w / h;
  }
  tw = dw * wide / 640;
  th = dh / 2;
  if (tw < 1) tw = 1;
  if (th < 1) th = 1;
  ox = (wide - tw) / 2;
  oy = (PIC_ROWS - th) / 2;
  return true;
}

bool ColorSink::start() {
  cur = (int16_t *)calloc((tw + 2) * 3, sizeof(int16_t));
  next = (int16_t *)calloc((tw + 2) * 3, sizeof(int16_t));
  return cur && next;
}

void ColorSink::out(int y, const uint8_t *rgb) { // Floyd and Steinberg's, back and forth
  static const uint8_t LV8[8] = {0, 36, 73, 109, 146, 182, 219, 255}, LV4[4] = {0, 85, 170, 255};
  uint8_t *o = buf + (long)(oy + y) * wide + ox;
  int d = (y & 1) ? -1 : 1;
  for (int i = 0, x = d > 0 ? 0 : tw - 1; i < tw; i++, x += d) {
    int16_t *e = cur + (x + 1) * 3;
    int v[3], q[3];
    for (int k = 0; k < 3; k++) {
      v[k] = rgb[3 * x + k] + e[k] / 16;
      if (v[k] < -64) v[k] = -64;
      if (v[k] > 319) v[k] = 319;
    }
    q[0] = clamp8(v[0]) * 7 + 127;
    q[0] /= 255;
    q[1] = (clamp8(v[1]) * 7 + 127) / 255;
    q[2] = (clamp8(v[2]) * 3 + 127) / 255;
    int code = q[1] << 5 | q[2] << 3 | q[0];
    if (code == 0x21 || code == 0x6B || code == 0x8C || code == 0xB5 || code == 0xD6) {
      q[0]++;                                    // a code the color decoder blends to gray: its neighbor
      code++;
    }
    o[x] = code;
    int err[3] = {v[0] - LV8[q[0]], v[1] - LV8[q[1]], v[2] - LV4[q[2]]};
    for (int k = 0; k < 3; k++) {
      e[3 * d + k] += err[k] * 7;
      next[(x + 1 - d) * 3 + k] += err[k] * 3;
      next[(x + 1) * 3 + k] += err[k] * 5;
      next[(x + 1 + d) * 3 + k] += err[k];
    }
  }
  int16_t *t = cur;
  cur = next;
  next = t;
  memset(next, 0, (tw + 2) * 3 * sizeof(int16_t));
}

}  // namespace pb
