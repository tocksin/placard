// ============================================================
// browser.h - the web browser's work, done in the WiFi card's module
// ============================================================
//
// The Placard's browser (WEB.PLC, src/scripts/web.masm) only draws: this
// code, in the module, fetches a page (HTTP or HTTPS), turns its HTML
// into lines of text that fit the Placard's screen, keeps the links, and
// turns the page's pictures (JPEG, PNG, GIF) into the Placard's own
// pixels: 1 bit a pixel for a picture in the page, the board's 256
// colors at 80 or 160 across for a picture shown alone.
// docs/architecture/WIFICARD.md, "The browser's commands", has the link's
// side of it; docs/software/WEB.md the program.
//
// It is plain C++ with no Arduino in it, so the same files build into
// the module's firmware (wifi_card.ino) and into wifi_host (host/), the
// program the simulators run in place of a module.  The platform gives
// it a Net: one TCP connection at a time, and a clock.
//
// Date: 2026-11-22
// ============================================================
#ifndef PLACARD_BROWSER_H
#define PLACARD_BROWSER_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace pb {

enum {
  PAGE_BYTES = 24576,   // the page's lines
  MAX_LINES  = 1400,
  LINK_BYTES = 12288,   // the links' and pictures' addresses, as the page gave them
  MAX_LINKS  = 700,
  MAX_IMAGES = 24,      // pictures of a page that can be shown in it or alone
  PIX_BYTES  = 32768,   // the pictures in the page, 1 bit a pixel
  URL_MAX    = 400,
  HISTORY    = 8,
  COLS_MAX   = 80,
  PIC_ROWS   = 240,     // a picture alone: 240 rows of 80 or 160
};

// the link's status bytes (wifi_card.ino has the first four)
enum { ST_OK = 0x00, ST_CANT = 0x01, ST_NO_NET = 0x02, ST_NO_CONN = 0x03, ST_UNKNOWN = 0xFF };

// the browser's commands
enum {
  C_VIEW = 0x30, C_GO = 0x31, C_LINK = 0x32, C_BACK = 0x33, C_RELOAD = 0x34, C_INFO = 0x35,
  C_ROW = 0x36, C_IMGLOAD = 0x37, C_LINKINFO = 0x38, C_PICTURE = 0x39, C_PICDATA = 0x3A,
  C_PICEND = 0x3B,
};

// in a line of text
enum { T_LINK = 0x01, T_LINKEND = 0x02, T_BOLD = 0x03, T_BOLDEND = 0x04, T_STRIP = 0x06 };

enum { LINK_PICTURE = 0x8000, LINK_MORE = 0xFFFE, LINK_SELF = 0xFFFF };

// what the platform gives
struct Net {
  virtual bool open(const char *host, uint16_t port, bool tls) = 0;
  virtual bool send(const uint8_t *d, int n) = 0;
  // bytes read (1 to max); 0 = nothing came within waitMs; -1 = the other end closed
  virtual int recv(uint8_t *d, int max, uint32_t waitMs) = 0;
  virtual void close() = 0;
  virtual uint32_t ms() = 0;
  virtual ~Net() {}
};

struct Source {                       // bytes, one at a time; -1 at the end
  virtual int get() = 0;
  virtual ~Source() {}
};

// ---- pictures (image.cpp)
struct RowSink {
  // the picture's own size: gives the width the rows are wanted at (the
  // decoder may give them wider, never narrower unless the picture is)
  virtual int want(int w, int h) = 0;
  virtual bool begin(int w, int h) = 0;         // the size the rows come in
  virtual void row(const uint8_t *rgb) = 0;     // top to bottom, 3 bytes a pixel
  virtual ~RowSink() {}
};

// 0 = done; else why not, as text
const char *decodeImage(Source &in, RowSink &out);

class Inflate : public Source {       // a deflate stream (RFC 1951) read through
 public:
  explicit Inflate(Source &in);
  ~Inflate();
  bool ok() const { return win != 0 && !bad; }
  bool skipGzipHeader();
  bool skipZlibHeader();
  int get();

 private:
  int bits(int n);
  int decode(const uint16_t *count, const uint16_t *symbol);
  bool build(const uint8_t *lens, int n, uint16_t *count, uint16_t *symbol);
  bool dynamic();
  void fixed();
  Source &in;
  uint8_t *win;
  uint32_t wpos, copyLen, copyDist, stored;
  uint32_t bitbuf;
  int bitcnt, state;
  bool final, bad;
  uint16_t lcount[16], lsym[288], dcount[16], dsym[30];
};

// ---- the page (html.cpp)
class Browser;
void layoutHtml(Browser &b, Source &in, bool latin1);
void layoutText(Browser &b, Source &in);

// ---- the browser (browser.cpp)
struct Url {
  bool tls;
  uint16_t port;
  char host[128];
  char path[URL_MAX];                 // from the first "/", with the query
};

struct Image {
  uint16_t src;                       // its address: an entry of the links
  uint8_t state;                      // 0 not fetched, 1 in the page, 2 not shown in the page
  uint8_t wbytes;                     // in the page: bytes across
  uint16_t h;                         // and rows
  uint16_t pix;                       // where in the pixels
  uint16_t line;                      // the page line of its caption
  uint8_t strips;                     // lines of pixels above the caption
  uint8_t quiet;                      // 1: no words with it (dropped from the page if it can't be shown)
};

class Browser {
 public:
  explicit Browser(Net &net);
  // one command of the link: the status, and the reply's bytes
  uint8_t command(uint8_t cmd, const uint8_t *d, int n, uint8_t *reply, uint8_t *replyLen);

  // ---- for the layout (html.cpp)
  int cols() const { return viewCols; }
  bool addLine(const uint8_t *bytes, int n);    // false: the page is full
  int addLink(const char *href);                // its number, or -1 (no room, or not a link)
  int addImage(const char *src, bool quiet);    // its number, or -1
  void setTitle(const char *t);
  void setBase(const char *href);
  void setRefresh(const char *href);
  bool full() const { return pageFull; }

 private:
  friend struct Fetch;
  uint8_t go(uint8_t *reply, uint8_t *replyLen);
  bool load();
  bool loadOnce(char *redirect);
  uint8_t pageInfo(uint8_t *reply, uint8_t *replyLen);
  uint8_t row(const uint8_t *d, int n, uint8_t *reply, uint8_t *replyLen);
  uint8_t imgLoad(uint8_t *reply, uint8_t *replyLen);
  uint8_t picture(const uint8_t *d, int n, uint8_t *reply, uint8_t *replyLen);
  bool linkUrl(int id, char *out);
  void pushHistory(uint16_t top);
  void clearPage();
  void fail(const char *why);
  bool insertLines(int at, const uint8_t *recs, int bytes, int count);
  void removeLine(int at);
  const char *linkText(int i) const { return (const char *)links + linkOff[i]; }

  Net &net;
  // the view
  uint8_t viewCols, viewPitch, viewFlags;
  // the page
  uint8_t page[PAGE_BYTES];
  uint16_t lineOff[MAX_LINES + 1];
  uint16_t nLines, pageUsed;
  bool pageFull;
  uint32_t skipLines, seenLines;      // a long page comes in parts: lines passed over, lines made
  bool more;                          // there is a part after this one
  uint8_t links[LINK_BYTES];
  uint16_t linkOff[MAX_LINKS];
  uint16_t nLinks, linkUsed;
  Image imgs[MAX_IMAGES];
  uint8_t nImgs;
  uint8_t pix[PIX_BYTES];
  uint16_t pixUsed;
  char title[64];
  char url[URL_MAX], base[URL_MAX], refresh[URL_MAX];
  char msg[96];
  bool isPicture;                     // the address is a picture, not a page
  uint16_t restoreTop;
  // where it has been
  struct Past { char url[URL_MAX]; uint32_t skip; uint16_t top; } hist[HISTORY];
  uint8_t nHist;
  // a picture alone
  uint8_t *pic;
  uint8_t picW;
  // the connection kept between fetches
  char connHost[128];
  uint16_t connPort;
  bool connTls, connOpen;
};

// ---- addresses
bool parseUrl(const char *s, Url &u);
// base + ref -> out (URL_MAX); false: not something to fetch (mailto:, javascript:, #...)
bool resolveUrl(const char *base, const char *ref, char *out);

}  // namespace pb

#endif
