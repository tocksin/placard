// ============================================================
// browser.cpp - the Placard's web browser, the module's side
// ============================================================
//
// The commands of the link that WEB.PLC uses (browser.h has the list,
// docs/architecture/WIFICARD.md the bytes), the page kept for it, where
// it has been, and the fetching: HTTP/1.1 over the platform's
// connection, redirects, chunked and gzip bodies, one connection kept
// open between fetches from the same site.
//
// Date: 2026-11-22
// ============================================================
#include "browser.h"
#include "image.h"

#include <stdio.h>
#include <stdlib.h>

namespace pb {

static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

static bool startsNoCase(const char *s, const char *p) {
  for (; *p; s++, p++)
    if (lower(*s) != *p) return false;
  return true;
}

// ============================================================
// addresses
// ============================================================
bool parseUrl(const char *s, Url &u) {
  if (startsNoCase(s, "https://")) {
    u.tls = true;
    s += 8;
  } else if (startsNoCase(s, "http://")) {
    u.tls = false;
    s += 7;
  } else {
    return false;
  }
  u.port = u.tls ? 443 : 80;
  const char *at = 0;                            // "user:password@" is passed over
  for (const char *p = s; *p && *p != '/' && *p != '?' && *p != '#'; p++)
    if (*p == '@') at = p;
  if (at) s = at + 1;
  size_t n = 0;
  while (*s && *s != '/' && *s != '?' && *s != '#' && *s != ':') {
    if (n >= sizeof(u.host) - 1) return false;
    u.host[n++] = (char)lower(*s++);
  }
  u.host[n] = 0;
  if (!n) return false;
  if (*s == ':') {
    long port = strtol(s + 1, (char **)&s, 10);
    if (port <= 0 || port > 65535) return false;
    u.port = (uint16_t)port;
  }
  n = 0;
  if (*s != '/') u.path[n++] = '/';
  for (; *s && *s != '#'; s++) {
    unsigned char c = (unsigned char)*s;
    if (c <= 0x20 || c >= 0x7F || strchr("\"<>\\^`{|}", c)) {
      if (n + 3 >= sizeof(u.path)) return false;
      n += snprintf(u.path + n, 4, "%%%02X", c);
    } else {
      if (n + 1 >= sizeof(u.path)) return false;
      u.path[n++] = (char)c;
    }
  }
  u.path[n] = 0;
  return true;
}

static int hexVal(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  c = lower(c);
  return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

bool resolveUrl(const char *base, const char *ref, char *out) {
  char r[URL_MAX];
  size_t n = 0;
  while (*ref == ' ' || *ref == '\n' || *ref == '\t' || *ref == '\r') ref++;
  for (; *ref; ref++) {
    if (*ref == '\n' || *ref == '\t' || *ref == '\r') continue;
    if (n >= sizeof(r) - 1) return false;
    r[n++] = *ref;
  }
  while (n && r[n - 1] == ' ') n--;
  r[n] = 0;
  if (!n || r[0] == '#') return false;

  // where the base's parts end
  const char *host = strstr(base, "://");
  if (!host) return false;
  host += 3;
  const char *path = host;
  while (*path && *path != '/' && *path != '?' && *path != '#') path++;
  const char *query = path;
  while (*query && *query != '?' && *query != '#') query++;
  const char *dir = query;
  while (dir > path && dir[-1] != '/') dir--;

  const char *p = r;
  while ((lower(*p) >= 'a' && lower(*p) <= 'z') || (p > r && ((*p >= '0' && *p <= '9') || *p == '+' || *p == '-' || *p == '.'))) p++;
  char t[URL_MAX * 2];
  if (*p == ':' && p > r) {                      // it names its own scheme
    if (!startsNoCase(r, "http://") && !startsNoCase(r, "https://")) return false;
    snprintf(t, sizeof(t), "%s", r);
  } else if (r[0] == '/' && r[1] == '/') {
    snprintf(t, sizeof(t), "%.*s%s", (int)(host - base - 2), base, r);
  } else if (r[0] == '/') {
    snprintf(t, sizeof(t), "%.*s%s", (int)(path - base), base, r);
  } else if (r[0] == '?') {
    snprintf(t, sizeof(t), "%.*s%s%s", (int)(query - base), base, query == path ? "/" : "", r);
  } else {
    snprintf(t, sizeof(t), "%.*s%s%s", (int)(dir - base), base, dir == path ? "/" : "", r);
  }

  // the path's "." and ".." parts, and no "#..."
  char *start = strstr(t, "://");
  start = start ? start + 3 : t;
  while (*start && *start != '/' && *start != '?' && *start != '#') start++;
  char *w = start;
  const char *s = start;
  while (*s && *s != '?' && *s != '#') {
    if (s[0] == '/' && s[1] == '.' && (s[2] == '/' || !s[2] || s[2] == '?' || s[2] == '#')) {
      s += 2;
      if (*s != '/') *w++ = '/';
    } else if (s[0] == '/' && s[1] == '.' && s[2] == '.' && (s[3] == '/' || !s[3] || s[3] == '?' || s[3] == '#')) {
      s += 3;
      while (w > start && *--w != '/') {
      }
      if (*s != '/') *w++ = '/';
    } else {
      *w++ = *s++;
    }
  }
  while (*s && *s != '#') *w++ = *s++;
  *w = 0;

  // a search result that goes through the search site's redirect: the page itself
  const char *dd = strstr(t, "duckduckgo.com/l/?");
  const char *ud = dd ? strstr(dd, "uddg=") : 0;
  if (ud) {
    char d[URL_MAX];
    size_t k = 0;
    for (ud += 5; *ud && *ud != '&' && k < sizeof(d) - 1; ud++) {
      if (*ud == '%' && hexVal(ud[1]) >= 0 && hexVal(ud[2]) >= 0) {
        d[k++] = (char)(hexVal(ud[1]) << 4 | hexVal(ud[2]));
        ud += 2;
      } else {
        d[k++] = *ud;
      }
    }
    d[k] = 0;
    if (startsNoCase(d, "http")) snprintf(t, sizeof(t), "%s", d);
  }
  if (strlen(t) >= URL_MAX) return false;
  strcpy(out, t);
  return true;
}

// ============================================================
// a fetch: the request, the reply's head, the body as a Source
// ============================================================
struct Fetch : Source {
  Browser &b;
  Net &net;
  uint8_t buf[512];
  int n, i;
  uint32_t deadline;
  bool timedOut, closed, broken;
  int status;
  long length, chunkLeft;
  bool chunked, gzip, zlib, keep, bodyDone, latin1;
  char type[48], location[URL_MAX];

  Fetch(Browser &br, uint32_t ms)
      : b(br), net(br.net), n(0), i(0), deadline(br.net.ms() + ms), timedOut(false), closed(false), broken(false),
        status(0), length(-1), chunkLeft(0), chunked(false), gzip(false), zlib(false), keep(true), bodyDone(false),
        latin1(false) {
    type[0] = location[0] = 0;
  }

  int raw() {
    if (i < n) return buf[i++];
    if (closed || timedOut) return -1;
    for (;;) {
      if ((int32_t)(net.ms() - deadline) > 0) {
        timedOut = true;
        return -1;
      }
      int r = net.recv(buf, sizeof(buf), 200);
      if (r > 0) {
        n = r;
        i = 1;
        return buf[0];
      }
      if (r < 0) {
        closed = true;
        return -1;
      }
    }
  }

  bool readLine(char *line, int max) {
    int k = 0;
    for (;;) {
      int c = raw();
      if (c < 0) return false;
      if (c == '\n') break;
      if (c != '\r' && k < max - 1) line[k++] = (char)c;
    }
    line[k] = 0;
    return true;
  }

  bool head() {                                  // the status line and the header lines
    char *line = (char *)malloc(URL_MAX + 64);
    if (!line) return false;
    bool ok = false;
    for (;;) {
      if (!readLine(line, URL_MAX + 64) || strncmp(line, "HTTP/", 5)) break;
      keep = line[5] == '1' && line[7] == '1';
      const char *sp = strchr(line, ' ');
      status = sp ? atoi(sp + 1) : 0;
      length = -1;
      chunked = gzip = zlib = false;
      bool end = false;
      while (readLine(line, URL_MAX + 64)) {
        if (!line[0]) {
          end = true;
          break;
        }
        char *v = strchr(line, ':');
        if (!v) continue;
        *v++ = 0;
        while (*v == ' ') v++;
        if (startsNoCase(line, "content-length") && !line[14]) length = atol(v);
        else if (startsNoCase(line, "transfer-encoding")) chunked = strstr(v, "chunked") != 0;
        else if (startsNoCase(line, "content-encoding")) {
          gzip = strstr(v, "gzip") != 0;
          zlib = strstr(v, "deflate") != 0;
        } else if (startsNoCase(line, "content-type")) {
          int k = 0;
          for (const char *p = v; *p && *p != ';' && *p != ' ' && k < (int)sizeof(type) - 1; p++) type[k++] = (char)lower(*p);
          type[k] = 0;
          for (char *p = v; *p; p++) *p = (char)lower(*p);
          latin1 = strstr(v, "8859-1") || strstr(v, "windows-1252");
        } else if (startsNoCase(line, "location") && !line[8]) {
          snprintf(location, sizeof(location), "%s", v);
        } else if (startsNoCase(line, "connection")) {
          for (char *p = v; *p; p++) *p = (char)lower(*p);
          if (strstr(v, "close")) keep = false;
          if (strstr(v, "keep-alive")) keep = true;
        }
      }
      if (!end) break;
      if (status >= 100 && status < 200) continue;         // "100 Continue": the real reply follows
      ok = true;
      break;
    }
    free(line);
    if (status == 204 || status == 304) length = 0;
    if (!chunked && length < 0) keep = false;
    return ok;
  }

  bool request(const Url &u, const char *accept, bool gz) {
    char *req = (char *)malloc(URL_MAX + 420);
    if (!req) return false;
    char port[8] = "";
    if (u.port != (u.tls ? 443 : 80)) snprintf(port, sizeof(port), ":%u", u.port);
    int len = snprintf(req, URL_MAX + 420,
                       "GET %s HTTP/1.1\r\nHost: %s%s\r\nUser-Agent: Mozilla/5.0 (compatible; Placard/1.0)\r\n"
                       "Accept: %s\r\nAccept-Encoding: %s\r\nAccept-Language: en\r\nConnection: keep-alive\r\n\r\n",
                       u.path, u.host, port, accept, gz ? "gzip" : "identity");
    bool ok = false;
    for (int attempt = 0; attempt < 2 && !ok; attempt++) {
      bool reuse = attempt == 0 && b.connOpen && b.connTls == u.tls && b.connPort == u.port && !strcmp(b.connHost, u.host);
      if (!reuse) {
        net.close();
        b.connOpen = false;
        if (!net.open(u.host, u.port, u.tls)) break;
        b.connOpen = true;
        b.connTls = u.tls;
        b.connPort = u.port;
        snprintf(b.connHost, sizeof(b.connHost), "%s", u.host);
      }
      n = i = 0;
      closed = timedOut = false;
      ok = net.send((const uint8_t *)req, len) && head();
      if (!ok) {
        net.close();
        b.connOpen = false;
        if (!reuse || timedOut) break;           // a kept connection the site has dropped: once more, fresh
      }
    }
    free(req);
    return ok;
  }

  int get() {
    if (bodyDone) return -1;
    int c;
    if (chunked) {
      if (!chunkLeft) {
        char line[40];
        if (!readLine(line, sizeof(line))) return fail();
        chunkLeft = strtol(line, 0, 16);
        if (chunkLeft <= 0) {
          while (readLine(line, sizeof(line)) && line[0]) {
          }
          bodyDone = true;
          return -1;
        }
      }
      c = raw();
      if (c < 0) return fail();
      if (!--chunkLeft) {
        raw();
        raw();
      }
      return c;
    }
    if (length == 0) {
      bodyDone = true;
      return -1;
    }
    c = raw();
    if (c < 0) {
      if (length > 0) return fail();
      bodyDone = true;
      return -1;
    }
    if (length > 0 && !--length) bodyDone = true;
    return c;
  }

  int fail() {
    broken = bodyDone = true;
    return -1;
  }

  void finish() {                                // the connection is kept only when the body was read to its end
    if (chunked && !bodyDone && !chunkLeft) get();
    if (!(bodyDone && !broken && keep && !closed && !timedOut && i >= n)) {
      net.close();
      b.connOpen = false;
    }
  }
};

// ============================================================
// the page
// ============================================================
Browser::Browser(Net &n)
    : net(n), viewCols(76), viewPitch(10), viewFlags(1), nLines(0), pageUsed(0), pageFull(false), skipLines(0),
      seenLines(0), more(false), nLinks(0), linkUsed(0), nImgs(0), pixUsed(0), isPicture(false), restoreTop(0),
      nHist(0), pic(0), picW(0), connPort(0), connTls(false), connOpen(false) {
  title[0] = url[0] = base[0] = refresh[0] = msg[0] = connHost[0] = 0;
  lineOff[0] = 0;
}

void Browser::clearPage() {
  nLines = pageUsed = 0;
  lineOff[0] = 0;
  pageFull = more = isPicture = false;
  seenLines = 0;
  nLinks = linkUsed = 0;
  nImgs = 0;
  pixUsed = 0;
  title[0] = refresh[0] = msg[0] = 0;
  snprintf(base, sizeof(base), "%s", url);
}

bool Browser::insertLines(int at, const uint8_t *recs, int bytes, int count) {
  if (nLines + count > MAX_LINES || pageUsed + bytes > PAGE_BYTES || at > nLines) return false;
  uint16_t off = lineOff[at];
  memmove(page + off + bytes, page + off, pageUsed - off);
  memcpy(page + off, recs, bytes);
  pageUsed += bytes;
  for (int i = nLines; i >= at; i--) lineOff[i + count] = lineOff[i] + bytes;
  for (int i = 0, o = off; i < count; i++) {
    lineOff[at + i] = o;
    o += page[o] + 1;
  }
  nLines += count;
  for (int i = 0; i < nImgs; i++)
    if (imgs[i].line != 0xFFFF && imgs[i].line >= at) imgs[i].line += count;
  return true;
}

bool Browser::addLine(const uint8_t *bytes, int n) {
  if (seenLines < skipLines) {                   // a part of the page shown before
    seenLines++;
    return true;
  }
  if (nLines >= MAX_LINES - 200 || pageUsed + n + 1 > PAGE_BYTES - 1280) {
    pageFull = more = true;                      // (not seen: the next part starts with it)
    return false;
  }
  seenLines++;
  if (!n && !nLines && skipLines) return true;   // a part does not start with an empty line
  uint8_t rec[256];
  rec[0] = (uint8_t)n;
  if (n) memcpy(rec + 1, bytes, n);
  if (!insertLines(nLines, rec, n + 1, 1)) return false;
  for (int i = 0; i + 2 < n; i++)                // a picture's caption: the line it is in
    if (bytes[i] == T_LINK) {
      int id = bytes[i + 1] << 8 | bytes[i + 2];
      if (id >= LINK_PICTURE && id - LINK_PICTURE < nImgs && imgs[id - LINK_PICTURE].line == 0xFFFF)
        imgs[id - LINK_PICTURE].line = nLines - 1;
      i += 2;
    }
  return true;
}

int Browser::addLink(const char *href) {
  if (seenLines < skipLines) return -1;
  while (*href == ' ') href++;
  if (!*href || *href == '#' || startsNoCase(href, "javascript:") || startsNoCase(href, "mailto:") ||
      startsNoCase(href, "tel:") || startsNoCase(href, "data:"))
    return -1;
  size_t n = strlen(href);
  if (n >= URL_MAX) return -1;
  if (nLinks && !strcmp(linkText(nLinks - 1), href)) return nLinks - 1;
  if (nLinks >= MAX_LINKS || linkUsed + n + 1 > LINK_BYTES) return -1;
  linkOff[nLinks] = linkUsed;
  memcpy(links + linkUsed, href, n + 1);
  linkUsed += n + 1;
  return nLinks++;
}

int Browser::addImage(const char *src, bool quiet) {
  if (nImgs >= MAX_IMAGES) return -1;
  uint16_t was = nLinks;
  int id = addLink(src);
  if (id < 0) return -1;
  if (id < was) {                                // the same address as the link before it: its own entry
    size_t n = strlen(src);
    if (nLinks >= MAX_LINKS || linkUsed + n + 1 > LINK_BYTES) return -1;
    linkOff[nLinks] = linkUsed;
    memcpy(links + linkUsed, src, n + 1);
    linkUsed += n + 1;
    id = nLinks++;
  }
  Image &im = imgs[nImgs];
  memset(&im, 0, sizeof(im));
  im.src = (uint16_t)id;
  im.line = 0xFFFF;
  im.quiet = quiet;
  return nImgs++;
}

void Browser::setTitle(const char *t) {
  if (!title[0]) snprintf(title, sizeof(title), "%s", t);
}

void Browser::setBase(const char *href) {
  char t[URL_MAX];
  if (resolveUrl(url, href, t)) strcpy(base, t);
}

void Browser::setRefresh(const char *href) {
  if (!refresh[0]) snprintf(refresh, sizeof(refresh), "%s", href);
}

static void addText(Browser &b, const char *s, bool bold) {
  uint8_t out[COLS_MAX + 4];
  int cols = b.cols();
  do {
    int n = 0, k = 0;
    if (bold) out[n++] = T_BOLD;
    for (; s[k] && k < cols; k++) out[n++] = (uint8_t)s[k];
    s += k;
    b.addLine(out, n);
  } while (*s);
}

void Browser::fail(const char *why) {
  snprintf(msg, sizeof(msg), "%s", why);
  char keep[sizeof(msg)];
  strcpy(keep, msg);
  uint32_t skip = skipLines;
  skipLines = 0;
  clearPage();
  strcpy(msg, keep);
  snprintf(title, sizeof(title), "Not shown");
  addText(*this, "This page can't be shown", true);
  addLine(0, 0);
  addText(*this, msg, false);
  addLine(0, 0);
  addText(*this, url, false);
  skipLines = skip;
}

// true = the page is made, or it is at another address (redirect is set then)
bool Browser::loadOnce(char *redirect) {
  redirect[0] = 0;
  Url *u = new Url;
  Fetch *f = new Fetch(*this, 20000);
  Inflate *z = 0;
  bool ok = false;
  do {
    if (!parseUrl(url, *u)) {
      fail("That is not a web address");
      break;
    }
    if (!f->request(*u, "text/html,text/plain;q=0.9,image/jpeg;q=0.8,image/png;q=0.8,image/gif;q=0.8", true)) {
      char m[96];
      snprintf(m, sizeof(m), f->timedOut ? "%.60s did not answer in time" : "Could not reach %.60s", u->host);
      fail(m);
      break;
    }
    if ((f->status == 301 || f->status == 302 || f->status == 303 || f->status == 307 || f->status == 308) &&
        f->location[0] && resolveUrl(url, f->location, redirect)) {
      ok = true;
      break;
    }
    redirect[0] = 0;
    const char *name = strrchr(u->path, '/');
    name = name && name[1] ? name + 1 : u->host;
    if (!strncmp(f->type, "image/", 6)) {
      isPicture = true;
      snprintf(title, sizeof(title), "%.60s", name);
      uint8_t line[80];
      int n = 0;
      line[n++] = T_LINK;
      line[n++] = LINK_SELF >> 8;
      line[n++] = LINK_SELF & 255;
      n += snprintf((char *)line + n, 60, "[picture: %.40s]", name);
      addLine(line, n);
      ok = true;
      break;
    }
    bool html = !f->type[0] || strstr(f->type, "html") || strstr(f->type, "xml");
    if (!html && strncmp(f->type, "text/", 5) && !strstr(f->type, "json")) {
      char m[96];
      snprintf(m, sizeof(m), "This kind of file can't be shown (%.40s)", f->type);
      fail(m);
      break;
    }
    Source *src = f;
    if (f->gzip || f->zlib) {
      z = new Inflate(*f);
      if (!z->ok() || !(f->gzip ? z->skipGzipHeader() : z->skipZlibHeader())) {
        fail("The page could not be unpacked");
        break;
      }
      src = z;
    }
    if (html) layoutHtml(*this, *src, f->latin1);
    else layoutText(*this, *src);
    if (!nLines && !refresh[0]) {
      char m[96];
      if (f->status >= 400) snprintf(m, sizeof(m), "The site answered: error %d", f->status);
      else if (f->timedOut) snprintf(m, sizeof(m), "%.60s did not answer in time", u->host);
      else snprintf(m, sizeof(m), skipLines ? "That is the end of the page" : "The page has no words to show");
      fail(m);
      break;
    }
    if (!title[0]) snprintf(title, sizeof(title), "%.60s", name);
    uint32_t seen = seenLines;                   // the lines the page gave; not the ones added here
    if (more) {
      static const char MORE[] = "\x01\xFF\xFE[More of this page]\x02";
      if (nLines && page[lineOff[nLines - 1]]) insertLines(nLines, (const uint8_t *)"\0", 1, 1);
      uint8_t rec[40];
      rec[0] = sizeof(MORE) - 1;
      memcpy(rec + 1, MORE, sizeof(MORE) - 1);
      insertLines(nLines, rec, sizeof(MORE), 1);
    } else if (f->timedOut || f->broken) {
      insertLines(nLines, (const uint8_t *)"\0", 1, 1);
      static const char CUT[] = "[The rest of the page did not come]";
      uint8_t rec[40];
      rec[0] = sizeof(CUT) - 1;
      memcpy(rec + 1, CUT, sizeof(CUT) - 1);
      insertLines(nLines, rec, sizeof(CUT), 1);
    }
    seenLines = seen;
    for (int i = 0; i < nImgs; i++)
      if (imgs[i].line == 0xFFFF) imgs[i].state = 2;
    if (refresh[0] && nLines < 12 && resolveUrl(base, refresh, redirect)) {
    }
    ok = true;
  } while (0);
  f->finish();
  delete z;
  delete f;
  delete u;
  return ok;
}

bool Browser::load() {
  char *redirect = (char *)malloc(URL_MAX);
  if (!redirect) return false;
  bool ok = false;
  for (int hops = 0; hops < 7; hops++) {
    clearPage();
    ok = loadOnce(redirect);
    if (!ok || !redirect[0] || !strcmp(redirect, url)) break;
    if (hops == 6) {
      fail("The site sends the browser round in circles");
      ok = false;
      break;
    }
    strcpy(url, redirect);
    skipLines = 0;
  }
  free(redirect);
  return ok;
}

void Browser::pushHistory(uint16_t top) {
  if (!url[0]) return;
  if (nHist == HISTORY) {
    memmove(hist, hist + 1, sizeof(hist[0]) * (HISTORY - 1));
    nHist--;
  }
  strcpy(hist[nHist].url, url);
  hist[nHist].skip = skipLines;
  hist[nHist].top = top;
  nHist++;
}

uint8_t Browser::pageInfo(uint8_t *reply, uint8_t *replyLen) {
  int pending = 0;
  if (viewFlags & 1)
    for (int i = 0; i < nImgs; i++)
      if (imgs[i].state == 0) pending++;
  reply[0] = (pending ? 1 : 0) | (isPicture ? 2 : 0) | (msg[0] ? 4 : 0) | (nHist ? 8 : 0);
  reply[1] = nLines & 255;
  reply[2] = nLines >> 8;
  reply[3] = (uint8_t)pending;
  reply[4] = restoreTop & 255;
  reply[5] = restoreTop >> 8;
  *replyLen = 6;
  return ST_OK;
}

uint8_t Browser::go(uint8_t *reply, uint8_t *replyLen) {
  if (pic) {
    free(pic);
    pic = 0;
  }
  load();
  if (restoreTop >= nLines) restoreTop = 0;
  return pageInfo(reply, replyLen);
}

bool Browser::linkUrl(int id, char *out) {
  if (id == LINK_SELF) {
    strcpy(out, url);
    return true;
  }
  if (id >= LINK_PICTURE) {
    id -= LINK_PICTURE;
    if (id >= nImgs) return false;
    id = imgs[id].src;
  }
  if (id >= nLinks) return false;
  return resolveUrl(base, linkText(id), out);
}

uint8_t Browser::row(const uint8_t *d, int n, uint8_t *reply, uint8_t *replyLen) {
  if (n < 2) return ST_CANT;
  int ln = d[0] | d[1] << 8, part = n > 2 ? d[2] : 0;
  if (ln >= nLines) return ST_CANT;
  const uint8_t *rec = page + lineOff[ln];
  int len = rec[0], o = 0;
  rec++;
  if (len == 3 && rec[0] == T_STRIP && rec[1] < nImgs) {
    const Image &im = imgs[rec[1]];
    int per = 250 / viewPitch, col0 = part * per;
    int cols = im.wbytes - col0;
    if (cols < 0) cols = 0;
    if (cols > per) cols = per;
    reply[o++] = 1;
    reply[o++] = (uint8_t)col0;
    reply[o++] = (uint8_t)cols;
    reply[o++] = col0 + cols >= im.wbytes;
    for (int c = col0; c < col0 + cols; c++)
      for (int r = 0; r < viewPitch; r++) {
        int y = rec[2] * viewPitch + r;
        reply[o++] = y < im.h ? pix[im.pix + (long)y * im.wbytes + c] : 0xFF;
      }
  } else {
    reply[o++] = 0;
    for (int i = 0; i < len; i++) {
      if (rec[i] == T_LINK && i + 2 < len) {
        int id = rec[i + 1] << 8 | rec[i + 2];
        if (id >= LINK_PICTURE && id - LINK_PICTURE < nImgs && imgs[id - LINK_PICTURE].state == 2 &&
            imgs[id - LINK_PICTURE].quiet) {     // a picture with no words that can't be shown: left out
          while (i < len && rec[i] != T_LINKEND) i++;
          continue;
        }
        reply[o++] = rec[i++];
        reply[o++] = rec[i++];
      }
      reply[o++] = rec[i];
    }
  }
  *replyLen = (uint8_t)o;
  return ST_OK;
}

struct Got {                          // a picture's bytes fetched: the body, unpacked if it must be
  Url u;
  Fetch f;
  Got(Browser &b) : f(b, 12000) {}
};

uint8_t Browser::imgLoad(uint8_t *reply, uint8_t *replyLen) {
  int k = -1, pending = 0, at = 0, added = 0;
  if (viewFlags & 1)
    for (int i = 0; i < nImgs; i++)
      if (imgs[i].state == 0) {
        if (k < 0) k = i;
        else pending++;
      }
  if (k >= 0) {
    Image &im = imgs[k];
    im.state = 2;
    char *addr = (char *)malloc(URL_MAX);
    Got *g = new Got(*this);
    if (addr && linkUrl(LINK_PICTURE + k, addr) && parseUrl(addr, g->u) &&
        g->f.request(g->u, "image/jpeg,image/png,image/gif", false) && g->f.status == 200) {
      MonoSink sink(pix + pixUsed, PIX_BYTES - pixUsed, viewCols * 8, 200);
      const char *err = decodeImage(g->f, sink);
      if (!err && sink.th > 0) {
        uint8_t recs[4 * 32];
        int strips = (sink.th + viewPitch - 1) / viewPitch;
        if (strips > 32) strips = 32;
        for (int s = 0; s < strips; s++) {
          recs[4 * s] = 3;
          recs[4 * s + 1] = T_STRIP;
          recs[4 * s + 2] = (uint8_t)k;
          recs[4 * s + 3] = (uint8_t)s;
        }
        at = im.line;
        im.wbytes = (uint8_t)sink.wbytes;
        im.h = (uint16_t)sink.th;
        im.pix = pixUsed;
        if (insertLines(at, recs, 4 * strips, strips)) {
          im.state = 1;
          im.strips = (uint8_t)strips;
          pixUsed += sink.wbytes * sink.th;
          added = strips;
        }
      } else if (sink.why && sink.why[0]) {
        im.quiet = 0;                            // a real picture there is no room for: its caption stays
      }
    }
    g->f.finish();
    delete g;
    free(addr);
    if (im.state == 2 && im.quiet) added = 0;
  }
  reply[0] = (uint8_t)pending;
  reply[1] = at & 255;
  reply[2] = at >> 8;
  reply[3] = added & 255;
  reply[4] = added >> 8;
  reply[5] = nLines & 255;
  reply[6] = nLines >> 8;
  *replyLen = 7;
  return ST_OK;
}

uint8_t Browser::picture(const uint8_t *d, int n, uint8_t *reply, uint8_t *replyLen) {
  if (n < 3) return ST_CANT;
  int id = d[0] | d[1] << 8, wide = d[2] ? 160 : 80;
  const char *err = 0;
  char *addr = (char *)malloc(URL_MAX);
  Got *g = new Got(*this);
  free(pic);
  pic = (uint8_t *)calloc(wide, PIC_ROWS);
  picW = (uint8_t)wide;
  if (!pic || !addr) err = "Not enough memory for the picture";
  else if (!linkUrl(id, addr) || !parseUrl(addr, g->u)) err = "The picture has no address";
  else if (!g->f.request(g->u, "image/jpeg,image/png,image/gif", false)) err = "Could not fetch the picture";
  else if (g->f.status != 200) err = "The site does not give the picture";
  else {
    ColorSink sink(pic, wide);
    err = decodeImage(g->f, sink);
    if (err && !err[0]) err = "The picture could not be shown";
  }
  g->f.finish();
  delete g;
  free(addr);
  if (err) {
    free(pic);
    pic = 0;
    *replyLen = (uint8_t)snprintf((char *)reply, 80, "%s", err);
    return ST_CANT;
  }
  reply[0] = (uint8_t)wide;
  reply[1] = PIC_ROWS;
  *replyLen = 2;
  return ST_OK;
}

static int hexDigit(int v) { return v < 10 ? '0' + v : 'A' + v - 10; }

uint8_t Browser::command(uint8_t cmd, const uint8_t *d, int n, uint8_t *reply, uint8_t *replyLen) {
  *replyLen = 0;
  switch (cmd) {
    case C_VIEW:
      if (n < 3 || d[0] < 20 || d[0] > COLS_MAX || d[1] < 8 || d[1] > 16) return ST_CANT;
      viewCols = d[0];
      viewPitch = d[1];
      viewFlags = d[2];
      return ST_OK;

    case C_GO: {                                 // the top line of the page being left, then what was typed
      if (n < 3) return ST_CANT;
      char text[256], *t = text;
      memcpy(text, d + 2, n - 2);
      text[n - 2] = 0;
      while (*t == ' ') t++;
      for (int k = (int)strlen(t); k && t[k - 1] == ' '; k--) t[k - 1] = 0;
      if (!*t) return ST_CANT;
      pushHistory(d[0] | d[1] << 8);
      bool scheme = strstr(t, "://") != 0;
      if (!scheme && (strchr(t, ' ') || !strchr(t, '.'))) {          // words, not an address: search for them
        int k = snprintf(url, sizeof(url), "https://html.duckduckgo.com/html/?q=");
        for (; *t && k < URL_MAX - 4; t++) {
          unsigned char c = (unsigned char)*t;
          if ((c >= '0' && c <= '9') || (lower(c) >= 'a' && lower(c) <= 'z') || c == '-' || c == '.' || c == '_') {
            url[k++] = (char)c;
          } else if (c == ' ') {
            url[k++] = '+';
          } else {
            url[k++] = '%';
            url[k++] = (char)hexDigit(c >> 4);
            url[k++] = (char)hexDigit(c & 15);
          }
        }
        url[k] = 0;
      } else {
        snprintf(url, sizeof(url), "%s%s", scheme ? "" : "https://", t);
      }
      skipLines = 0;
      restoreTop = 0;
      if (scheme) return go(reply, replyLen);
      free(pic);                                 // no scheme typed: HTTPS first, plain HTTP where the site has none
      pic = 0;
      if (!load() && strstr(msg, "Could not reach") && !strchr(t, ' ') && strlen(t) < URL_MAX - 8) {
        snprintf(url, sizeof(url), "http://%s", t);
        load();
      }
      return pageInfo(reply, replyLen);
    }

    case C_LINK: {                               // the link's number, the top line of the page being left
      if (n < 4) return ST_CANT;
      int id = d[0] | d[1] << 8;
      if (id == LINK_MORE) {
        if (!more) return ST_CANT;
        pushHistory(d[2] | d[3] << 8);
        skipLines = seenLines;
      } else {
        char *t = (char *)malloc(URL_MAX);
        if (!t || id >= LINK_PICTURE || !linkUrl(id, t)) {
          free(t);
          return ST_CANT;
        }
        pushHistory(d[2] | d[3] << 8);
        strcpy(url, t);
        free(t);
        skipLines = 0;
      }
      restoreTop = 0;
      return go(reply, replyLen);
    }

    case C_BACK:
      if (!nHist) return ST_CANT;
      nHist--;
      strcpy(url, hist[nHist].url);
      skipLines = hist[nHist].skip;
      restoreTop = hist[nHist].top;
      return go(reply, replyLen);

    case C_RELOAD:
      if (!url[0]) return ST_CANT;
      restoreTop = n >= 2 ? d[0] | d[1] << 8 : 0;
      return go(reply, replyLen);

    case C_INFO: {
      const char *s = n && d[0] == 1 ? url : n && d[0] == 2 ? msg : title;
      *replyLen = (uint8_t)snprintf((char *)reply, 250, "%s", s);
      if (strlen(s) > 249) *replyLen = 249;
      return ST_OK;
    }

    case C_ROW:
      return row(d, n, reply, replyLen);

    case C_IMGLOAD:
      return imgLoad(reply, replyLen);

    case C_LINKINFO: {
      if (n < 2) return ST_CANT;
      int id = d[0] | d[1] << 8;
      if (id == LINK_MORE) {
        *replyLen = (uint8_t)snprintf((char *)reply, 250, "The next part of this page");
        return ST_OK;
      }
      char *t = (char *)malloc(URL_MAX);
      bool ok = t && linkUrl(id, t);
      if (ok) {
        *replyLen = (uint8_t)snprintf((char *)reply, 250, "%s", t);
        if (strlen(t) > 249) *replyLen = 249;
      }
      free(t);
      return ok ? ST_OK : ST_CANT;
    }

    case C_PICTURE:
      return picture(d, n, reply, replyLen);

    case C_PICDATA: {
      if (!pic || n < 1 || d[0] >= picW) return ST_CANT;
      for (int r = 0; r < PIC_ROWS; r++) reply[r] = pic[r * picW + d[0]];
      *replyLen = PIC_ROWS;
      return ST_OK;
    }

    case C_PICEND:
      free(pic);
      pic = 0;
      return ST_OK;
  }
  return ST_UNKNOWN;
}

}  // namespace pb
