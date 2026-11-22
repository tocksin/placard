// ============================================================
// image.h - the picture sinks of the Placard's browser (image.cpp)
// ============================================================
//
// A Scaler takes a picture's rows at any size and gives rows of the size
// its fit() chose; MonoSink and ColorSink turn those into the Placard's
// pixels.
//
// Date: 2026-11-22
// ============================================================
#ifndef PLACARD_IMAGE_H
#define PLACARD_IMAGE_H

#include "browser.h"

namespace pb {

class Scaler : public RowSink {
 public:
  Scaler();
  ~Scaler();
  int want(int w, int h);
  bool begin(int w, int h);
  void row(const uint8_t *rgb);
  int tw, th;                         // the size made

 protected:
  virtual bool fit(int w, int h) = 0; // sets tw, th from the picture's size; false: not wanted
  virtual bool start() = 0;
  virtual void out(int y, const uint8_t *rgb) = 0;

 private:
  int sw, sh, sy, ty, rows;
  bool refused;
  uint32_t *acc;
  uint8_t *line;
};

// a picture in the page: 1 bit a pixel, rows of wbytes bytes, bit 0 the
// left pixel, 1 = white; never larger than the picture itself
class MonoSink : public Scaler {
 public:
  MonoSink(uint8_t *buf, long room, int maxW, int maxH);
  ~MonoSink();
  int wbytes;
  const char *why;                    // when it was not wanted: "" = too small to be a picture

 protected:
  bool fit(int w, int h);
  bool start();
  void out(int y, const uint8_t *rgb);

 private:
  uint8_t *buf;
  long room;
  int maxW, maxH;
  int16_t *e0, *e1, *e2;
};

// a picture alone: PIC_ROWS rows of wide bytes (80 or 160), the board's
// 256 colors, the picture in the middle with its shape kept
class ColorSink : public Scaler {
 public:
  ColorSink(uint8_t *buf, int wide);
  ~ColorSink();

 protected:
  bool fit(int w, int h);
  bool start();
  void out(int y, const uint8_t *rgb);

 private:
  uint8_t *buf;
  int wide, ox, oy;
  int16_t *cur, *next;
};

}  // namespace pb

#endif
