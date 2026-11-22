// ============================================================
// html.cpp - a page's HTML into lines of text (see browser.h)
// ============================================================
//
// Reads the page as its bytes come in and gives the browser lines that
// fit the Placard's screen: the words wrapped to the width asked for,
// headings and other bold text marked, lists, quotes and preformatted
// text set in, table cells side by side, the links and the pictures
// numbered where they are.  Scripts, styles and hidden parts are passed
// over.  Letters the Placard's font does not have are written with the
// ones it has (e for e-acute, " for curly quotes, ? for other writing).
//
// A line is its characters (20-7E) with these marks among them:
//   01 hi lo   a link starts (its number; 8000 + n: picture n)
//   02         the link ends
//   03, 04     bold starts, ends
// Marks do not carry over to the next line: each line says its own.
//
// Date: 2026-11-22
// ============================================================
#include "browser.h"

#include <stdlib.h>

namespace pb {
namespace {

static const char *const LATIN[224] = {
    " ", "!", "c", "GBP", "$", "JPY", "|", "S", "", "(c)", "a", "<<", "-", "", "(R)", "-", "deg", "+/-", "2", "3",
    "'", "u", "P", "*", "", "1", "o", ">>", "1/4", "1/2", "3/4", "?", "A", "A", "A", "A", "A", "A", "AE", "C", "E",
    "E", "E", "E", "I", "I", "I", "I", "D", "N", "O", "O", "O", "O", "O", "x", "O", "U", "U", "U", "U", "Y", "Th",
    "ss", "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i", "d", "n", "o", "o", "o",
    "o", "o", "/", "o", "u", "u", "u", "u", "y", "th", "y", "A", "a", "A", "a", "A", "a", "C", "c", "C", "c", "C",
    "c", "C", "c", "D", "d", "D", "d", "E", "e", "E", "e", "E", "e", "E", "e", "E", "e", "G", "g", "G", "g", "G",
    "g", "G", "g", "H", "h", "H", "h", "I", "i", "I", "i", "I", "i", "I", "i", "I", "i", "IJ", "ij", "J", "j", "K",
    "k", "k", "L", "l", "L", "l", "L", "l", "L", "l", "L", "l", "N", "n", "N", "n", "N", "n", "'n", "N", "n", "O",
    "o", "O", "o", "O", "o", "OE", "oe", "R", "r", "R", "r", "R", "r", "S", "s", "S", "s", "S", "s", "S", "s", "T",
    "t", "T", "t", "T", "t", "U", "u", "U", "u", "U", "u", "U", "u", "U", "u", "U", "u", "W", "w", "Y", "y", "Y",
    "Z", "z", "Z", "z", "Z", "z", "s",
};

// a character of any writing, with the letters the font has ("" = nothing; 0 = no way to write it)
const char *fold(int cp, char *one) {
  if (cp < 0x20) return " ";
  if (cp < 0x7F) {
    one[0] = (char)cp;
    one[1] = 0;
    return one;
  }
  if (cp < 0xA0) return "";
  if (cp < 0x180) return LATIN[cp - 0xA0];
  if ((cp >= 0x2000 && cp <= 0x200A) || cp == 0x202F || cp == 0x205F || cp == 0x3000) return " ";
  if ((cp >= 0x200B && cp <= 0x200F) || (cp >= 0x2028 && cp <= 0x202E) || (cp >= 0x2060 && cp <= 0x206F) ||
      cp == 0xFEFF || (cp >= 0xFE00 && cp <= 0xFE0F) || (cp >= 0x0300 && cp <= 0x036F))
    return "";
  if ((cp >= 0x2010 && cp <= 0x2015) || cp == 0x2212) return "-";
  if ((cp >= 0x2018 && cp <= 0x201B) || cp == 0x2032 || cp == 0x02BC) return "'";
  if ((cp >= 0x201C && cp <= 0x201F) || cp == 0x2033) return "\"";
  switch (cp) {
    case 0x2022: case 0x2023: case 0x2043: case 0x2219: case 0x25CF: case 0x25E6: case 0x25AA: case 0x25A0:
    case 0x2605: case 0x2606:
      return "*";
    case 0x2026: return "...";
    case 0x2039: case 0x25C0: case 0x25C4: return "<";
    case 0x203A: case 0x25B6: case 0x25B8: case 0x25BA: return ">";
    case 0x2044: return "/";
    case 0x20AC: return "EUR";
    case 0x2122: return "(TM)";
    case 0x2190: return "<-";
    case 0x2192: return "->";
    case 0x2191: case 0x25B2: return "^";
    case 0x2193: case 0x25BC: return "v";
    case 0x2248: return "~";
    case 0x2260: return "!=";
    case 0x2264: return "<=";
    case 0x2265: return ">=";
    case 0x2713: case 0x2714: return "+";
    case 0x2717: case 0x2718: return "x";
  }
  if ((cp >= 0x2600 && cp <= 0x27BF) || cp >= 0x1F000 || (cp >= 0xE000 && cp <= 0xF8FF)) return "";   // signs, emoji
  return 0;
}

struct Named {
  const char *name;
  uint16_t cp;
};
const Named NAMED[] = {
    {"amp", '&'},      {"lt", '<'},        {"gt", '>'},        {"quot", '"'},      {"apos", '\''},     {"nbsp", 0xA0},
    {"copy", 0xA9},    {"reg", 0xAE},      {"trade", 0x2122},  {"mdash", 0x2014},  {"ndash", 0x2013},  {"hellip", 0x2026},
    {"lsquo", 0x2018}, {"rsquo", 0x2019},  {"ldquo", 0x201C},  {"rdquo", 0x201D},  {"sbquo", 0x2018},  {"bdquo", 0x201C},
    {"bull", 0x2022},  {"middot", 0xB7},   {"laquo", 0xAB},    {"raquo", 0xBB},    {"lsaquo", 0x2039}, {"rsaquo", 0x203A},
    {"times", 0xD7},   {"divide", 0xF7},   {"deg", 0xB0},      {"plusmn", 0xB1},   {"euro", 0x20AC},   {"pound", 0xA3},
    {"yen", 0xA5},     {"cent", 0xA2},     {"sect", 0xA7},     {"para", 0xB6},     {"larr", 0x2190},   {"rarr", 0x2192},
    {"uarr", 0x2191},  {"darr", 0x2193},   {"frac12", 0xBD},   {"frac14", 0xBC},   {"frac34", 0xBE},   {"shy", 0xAD},
    {"ensp", 0x2002},  {"emsp", 0x2003},   {"thinsp", 0x2009}, {"minus", 0x2212},  {"prime", 0x2032},  {"Prime", 0x2033},
    {"iexcl", 0xA1},   {"iquest", 0xBF},   {"szlig", 0xDF},    {"aelig", 0xE6},    {"AElig", 0xC6},    {"oslash", 0xF8},
    {"Oslash", 0xD8},  {"zwnj", 0x200C},   {"zwj", 0x200D},    {"lrm", 0x200E},    {"rlm", 0x200F},    {"micro", 0xB5},
    {"ne", 0x2260},    {"le", 0x2264},     {"ge", 0x2265},     {"asymp", 0x2248},  {"sup2", 0xB2},     {"sup3", 0xB3},
    {"ordm", 0xBA},    {"ordf", 0xAA},     {"check", 0x2713},  {"hyphen", 0x2010}, {"dash", 0x2010},   {"oelig", 0x153},
    {"OElig", 0x152},  {"eth", 0xF0},      {"ETH", 0xD0},      {"thorn", 0xFE},    {"THORN", 0xDE},    {"nbsp;", 0xA0},
};

int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
bool isSpace(int c) { return c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\f'; }
bool isAlnum(int c) { return (c >= '0' && c <= '9') || (lower(c) >= 'a' && lower(c) <= 'z'); }
bool same(const char *a, const char *b) { return !strcmp(a, b); }

bool oneOf(const char *name, const char *list) {          // list: " a b c "
  size_t n = strlen(name);
  for (const char *p = list; (p = strstr(p, name)) != 0; p += n)
    if (p > list && p[-1] == ' ' && p[n] == ' ') return true;
  return false;
}

// an entity's name -> its character, or -1
int entityCp(const char *name) {
  if (name[0] == '#') {
    long v = (name[1] == 'x' || name[1] == 'X') ? strtol(name + 2, 0, 16) : strtol(name + 1, 0, 10);
    return v > 0 && v < 0x110000 ? (int)v : -1;
  }
  for (size_t i = 0; i < sizeof(NAMED) / sizeof(NAMED[0]); i++)
    if (same(name, NAMED[i].name)) return NAMED[i].cp;
  // a letter with a mark: eacute, Uuml, ntilde, ccedil, aring ...
  static const char *const MARKS[] = {"acute", "grave", "circ", "uml", "tilde", "ring", "cedil", "caron", 0};
  if (isAlnum(name[0]) && name[0] > '9')
    for (int i = 0; MARKS[i]; i++)
      if (same(name + 1, MARKS[i])) return name[0];
  return -1;
}

int putUtf8(char *d, int cp) {
  if (cp < 0x80) {
    d[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    d[0] = (char)(0xC0 | cp >> 6);
    d[1] = (char)(0x80 | (cp & 63));
    return 2;
  }
  if (cp < 0x10000) {
    d[0] = (char)(0xE0 | cp >> 12);
    d[1] = (char)(0x80 | ((cp >> 6) & 63));
    d[2] = (char)(0x80 | (cp & 63));
    return 3;
  }
  d[0] = (char)(0xF0 | cp >> 18);
  d[1] = (char)(0x80 | ((cp >> 12) & 63));
  d[2] = (char)(0x80 | ((cp >> 6) & 63));
  d[3] = (char)(0x80 | (cp & 63));
  return 4;
}

struct Cell {
  char ch;
  uint8_t bold;
  uint16_t link;                      // 0 = none, else its number + 1
};

struct Attrs {
  char url[URL_MAX], url2[URL_MAX], content[URL_MAX];
  char alt[72], label[48], equiv[16], type[16], value[40], place[40], style[96], name[24];
  int width, height;
  bool hidden;
};

class Layout {
 public:
  Layout(Browser &b, Source &in, bool latin1)
      : b(b), in(in), latin1(latin1), held(-1), cols(b.cols()), len(0), wlen(0), space(false), any(false),
        lastBlank(true), blankOwed(false), stop(false), pre(false), preStart(false), inTitle(false), unknown(false),
        bold(0), curLink(0), anchorCells(0), quote(0), nlists(0), inDd(false), cellNo(0), prefixLen(0), tlen(0),
        hideDepth(0), button(0) {
    alabel[0] = 0;
  }
  void html();
  void plain();

 private:
  int next() {
    if (held >= 0) {
      int c = held;
      held = -1;
      return c;
    }
    return in.get();
  }
  void back(int c) { held = c; }

  int indent() const {
    int n = 2 * quote + (inDd ? 4 : 0);
    if (nlists) n++;
    for (int i = 0; i < nlists; i++) n += lists[i].ordered ? 4 : 2;
    return n > cols - 24 ? cols - 24 : n;
  }

  void startLine() {
    int ind = indent();
    if (ind < prefixLen) ind = prefixLen;
    Cell s = {' ', 0, 0};
    for (int i = 0; i < ind - prefixLen; i++) line[len++] = s;
    for (int i = 0; i < prefixLen; i++) {
      s.ch = prefix[i];
      line[len++] = s;
    }
    prefixLen = 0;
  }

  void emitLine() {
    if (blankOwed && any && !lastBlank && !b.addLine(0, 0)) stop = true;
    blankOwed = false;
    while (len && line[len - 1].ch == ' ') len--;
    uint8_t out[252];
    int n = 0;
    unsigned link = 0, bd = 0;
    for (int i = 0; i < len; i++) {
      bool room = n + (len - i) + 8 < 250;
      if (line[i].link != link && room) {
        if (link) out[n++] = T_LINKEND;
        link = line[i].link;
        if (link) {
          out[n++] = T_LINK;
          out[n++] = (link - 1) >> 8;
          out[n++] = (link - 1) & 255;
        }
      }
      if (line[i].bold != bd && room) {
        bd = line[i].bold;
        out[n++] = bd ? T_BOLD : T_BOLDEND;
      }
      out[n++] = line[i].ch;
    }
    if (!b.addLine(out, n)) stop = true;
    any = true;
    lastBlank = len == 0;
    len = 0;
  }

  void flushWord() {
    if (!wlen) return;
    if (len && len + wlen + (space ? 1 : 0) > cols) emitLine();
    if (!len) {
      startLine();
    } else if (space) {
      Cell s = {' ', 0, 0};
      if (line[len - 1].link && line[len - 1].link == word[0].link) s.link = word[0].link;
      if (line[len - 1].bold && word[0].bold) s.bold = 1;
      line[len++] = s;
    }
    for (int i = 0; i < wlen && len < cols; i++) line[len++] = word[i];
    wlen = 0;
    space = false;
  }

  void breakLine() {
    flushWord();
    if (len) emitLine();
    space = false;
  }

  void para() {
    breakLine();
    blankOwed = true;
  }

  void br() {
    flushWord();
    if (len) emitLine();
    else if (any && !lastBlank && !blankOwed) {
      if (!b.addLine(0, 0)) stop = true;
      lastBlank = true;
    }
    space = false;
  }

  void put(char c) {                  // a character of the page's words
    if (hideDepth) return;
    if (inTitle) {
      if (c == ' ' && (!tlen || title[tlen - 1] == ' ')) return;
      if (tlen < 60) title[tlen++] = c;
      return;
    }
    if (pre) {
      if (c == '\n') {
        if (len) emitLine();
        else if (!preStart && !b.addLine(0, 0)) stop = true;
        preStart = false;
        return;
      }
      preStart = false;
      if (!len) startLine();
      if (len >= cols) {
        emitLine();
        startLine();
      }
      Cell k = {c, (uint8_t)(bold > 0), curLink};
      line[len++] = k;
      return;
    }
    if (c == ' ') {
      flushWord();
      if (len) space = true;
      return;
    }
    if (button == 1) {                // a button's "[" waits for its first character
      button = 2;
      put('[');
    }
    int room = cols - indent();
    if (wlen >= room) flushWord();
    Cell k = {c, (uint8_t)(bold > 0), curLink};
    word[wlen++] = k;
    if (curLink) anchorCells++;
  }

  void puts(const char *s) {
    for (; *s; s++) put(*s == '\n' && !pre ? ' ' : *s);
  }

  void cp(int c) {                    // a character of any writing
    char one[2];
    const char *s = fold(c, one);
    if (!s) {
      if (!unknown) put('?');
      unknown = true;
      return;
    }
    if (*s) unknown = false;
    if (pre && (c == '\n' || c == '\t')) {
      if (c == '\n') put('\n');
      else
        do put(' ');
        while (len % 8);
      return;
    }
    puts(s);
  }

  void text(int c) {                  // a byte of 80 or more: UTF-8, or Latin-1 where it is not
    if (latin1) {
      static const char *const W[32] = {"EUR", "", "'", "f", "\"", "...", "+", "+", "^", "%", "S", "<", "OE", "", "Z", "",
                                        "",    "'", "'", "\"", "\"", "*", "-", "-", "~", "(TM)", "s", ">", "oe", "", "z", "Y"};
      if (c < 0xA0) puts(W[c - 0x80]);
      else cp(c);
      return;
    }
    int v, need;
    if ((c & 0xE0) == 0xC0) v = c & 0x1F, need = 1;
    else if ((c & 0xF0) == 0xE0) v = c & 0x0F, need = 2;
    else if ((c & 0xF8) == 0xF0) v = c & 7, need = 3;
    else {
      cp(c >= 0xA0 ? c : '?');
      return;
    }
    while (need--) {
      int d = next();
      if (d < 0 || (d & 0xC0) != 0x80) {
        if (d >= 0) back(d);
        cp(c >= 0xA0 ? c : '?');
        return;
      }
      v = v << 6 | (d & 0x3F);
    }
    cp(v);
  }

  // after "&": the character, or -1 with what was read in raw (to show as it is)
  int entity(char *raw) {
    int n = 0;
    for (;;) {
      int c = next();
      if (c == ';' && n) {
        raw[n] = 0;
        int v = entityCp(raw);
        if (v < 0) {
          raw[n++] = ';';
          raw[n] = 0;
        }
        return v;
      }
      if (c < 0 || n >= 10 || !(isAlnum(c) || (c == '#' && n == 0))) {
        if (c >= 0) back(c);
        raw[n] = 0;
        int v = n ? entityCp(raw) : -1;
        return (v >= 0 && (raw[0] == '#' || v < 0x100)) ? v : -1;      // old pages leave the ";" out
      }
      raw[n++] = (char)c;
    }
  }

  void skipTo(int end) {
    int c;
    do c = next();
    while (c >= 0 && c != end);
  }

  // pass everything up to and with </name>
  void rawSkip(const char *name) {
    for (;;) {
      int c = next();
      if (c < 0) return;
      if (c != '<') continue;
      c = next();
      if (c != '/') {
        if (c == '<') back(c);
        continue;
      }
      int i = 0;
      while (name[i]) {
        c = next();
        if (lower(c) != name[i]) break;
        i++;
      }
      if (!name[i]) {
        skipTo('>');
        return;
      }
      if (c == '<') back(c);
    }
  }

  // an attribute's value into dst (max bytes with the 00); the delimiter is read
  void readValue(char *dst, int max) {
    int c = next(), n = 0;
    while (isSpace(c)) c = next();
    int q = (c == '"' || c == '\'') ? c : 0;
    if (q) c = next();
    for (; c >= 0; c = next()) {
      if (q ? c == q : (isSpace(c) || c == '>')) break;
      if (c == '&') {
        char raw[16], u[4];
        int v = entity(raw);
        if (v >= 0) {
          int k = putUtf8(u, v);
          for (int i = 0; i < k; i++)
            if (dst && n < max - 1) dst[n++] = u[i];
        } else {
          if (dst && n < max - 1) dst[n++] = '&';
          for (int i = 0; raw[i]; i++)
            if (dst && n < max - 1) dst[n++] = raw[i];
        }
        continue;
      }
      if (dst && n < max - 1) dst[n++] = (char)c;
    }
    if (dst) dst[n] = 0;
    if (!q && c == '>') back(c);
  }

  // the tag's attributes; true if it ends in "/>"
  bool attributes() {
    memset(&a, 0, sizeof(a));
    a.width = a.height = -1;
    bool slash = false;
    for (;;) {
      int c = next();
      while (isSpace(c)) c = next();
      if (c < 0 || c == '>') return slash;
      slash = c == '/';
      if (slash) continue;
      char name[20];
      int n = 0;
      while (c >= 0 && !isSpace(c) && c != '=' && c != '>' && c != '/') {
        if (n < 19) name[n++] = (char)lower(c);
        c = next();
      }
      name[n] = 0;
      while (isSpace(c)) c = next();
      if (c != '=') {
        if (c >= 0) back(c);
        if (same(name, "hidden")) a.hidden = true;
        continue;
      }
      char num[12];
      if (same(name, "href") || same(name, "src")) readValue(a.url, sizeof(a.url));
      else if (same(name, "data-src") || same(name, "data-lazy-src") || same(name, "data-original")) readValue(a.url2, sizeof(a.url2));
      else if (same(name, "content") || same(name, "charset")) readValue(a.content, sizeof(a.content));
      else if (same(name, "alt")) readValue(a.alt, sizeof(a.alt));
      else if (same(name, "aria-label") || (same(name, "title") && !a.label[0])) readValue(a.label, sizeof(a.label));
      else if (same(name, "http-equiv")) readValue(a.equiv, sizeof(a.equiv));
      else if (same(name, "type")) readValue(a.type, sizeof(a.type));
      else if (same(name, "value")) readValue(a.value, sizeof(a.value));
      else if (same(name, "placeholder")) readValue(a.place, sizeof(a.place));
      else if (same(name, "style")) readValue(a.style, sizeof(a.style));
      else if (same(name, "name")) readValue(a.name, sizeof(a.name));
      else if (same(name, "width")) {
        readValue(num, sizeof(num));
        a.width = atoi(num);
      } else if (same(name, "height")) {
        readValue(num, sizeof(num));
        a.height = atoi(num);
      } else if (same(name, "hidden")) {
        readValue(0, 0);
        a.hidden = true;
      } else {
        readValue(0, 0);
      }
    }
  }

  // text from an attribute (UTF-8) as words of the page
  void words(const char *s, int most) {
    const uint8_t *p = (const uint8_t *)s;
    int n = 0;
    while (*p && n < most) {
      int c = *p++, v = c;
      if (c >= 0xC0 && !latin1) {
        int need = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1;
        v = c & (0x3F >> need);
        while (need-- && (*p & 0xC0) == 0x80) v = v << 6 | (*p++ & 0x3F);
      }
      cp(isSpace(v) ? ' ' : v);
      n++;
    }
  }

  void lowerCopy(char *d, const char *s, int max, bool spaces) {
    int n = 0;
    for (; *s && n < max - 1; s++)
      if (spaces || !isSpace(*s)) d[n++] = (char)lower(*s);
    d[n] = 0;
  }

  void image() {
    const char *src = a.url;
    if ((!src[0] || !strncmp(src, "data:", 5)) && a.url2[0]) src = a.url2;
    if ((a.width >= 0 && a.width < 12) || (a.height >= 0 && a.height < 12)) return;      // a spacer
    bool alt = a.alt[0] != 0;
    int i = b.addImage(src, !alt);
    if (i < 0) {
      if (alt) {
        put('[');
        words(a.alt, 40);
        put(']');
      }
      return;
    }
    // "[picture: its words]" follows the link the picture is in, if any,
    // and then "[view]" shows the picture; with no words it only shows it
    uint16_t was = curLink, pic = (uint16_t)((LINK_PICTURE | i) + 1);
    int cells = anchorCells;
    if (!was || !alt) curLink = pic;
    puts(alt ? "[picture: " : "[picture");
    if (alt) words(a.alt, 40);
    put(']');
    if (was && alt) {
      curLink = pic;
      puts("[view]");
      cells = anchorCells;
    }
    curLink = was;
    if (!alt) anchorCells = cells;
  }

  void input() {
    char t[16];
    lowerCopy(t, a.type, sizeof(t), false);
    if (same(t, "hidden")) return;
    if (same(t, "submit") || same(t, "button") || same(t, "reset")) {
      put('[');
      words(a.value[0] ? a.value : "Submit", 30);
      put(']');
    } else if (same(t, "checkbox")) {
      puts("[ ]");
    } else if (same(t, "radio")) {
      puts("( )");
    } else if (!same(t, "image") && !same(t, "file")) {
      put('[');
      if (a.value[0]) words(a.value, 30);
      else if (a.place[0]) words(a.place, 30);
      puts("____]");
    }
  }

  void startTag(const char *t, bool slash) {
    if (oneOf(t, " script style noscript template svg select textarea iframe object canvas audio video datalist math ")) {
      if (same(t, "iframe") && a.url[0] && !hideDepth) {
        para();
        uint16_t was = curLink;
        int id = b.addLink(a.url);
        curLink = id >= 0 ? id + 1 : 0;
        puts("[frame]");
        curLink = was;
        para();
      }
      if (!slash || !same(t, "svg")) rawSkip(t);
      return;
    }
    bool isVoid = oneOf(t, " area base br col embed hr img input link meta source track wbr ");
    if (hideDepth) {
      if (!isVoid && !slash && same(t, hideName)) hideDepth++;
      return;
    }
    if (!isVoid && !slash) {
      char st[96];
      lowerCopy(st, a.style, sizeof(st), false);
      if (a.hidden || strstr(st, "display:none") || strstr(st, "visibility:hidden")) {
        strncpy(hideName, t, sizeof(hideName) - 1);
        hideName[sizeof(hideName) - 1] = 0;
        hideDepth = 1;
        return;
      }
    }
    if (same(t, "title")) {
      inTitle = true;
      tlen = 0;
    } else if (same(t, "meta")) {
      char e[16], c[URL_MAX];
      lowerCopy(e, a.equiv, sizeof(e), false);
      lowerCopy(c, a.content, sizeof(c), true);
      if (same(e, "refresh")) {
        const char *u = strstr(c, "url=");
        if (u && atoi(c) <= 5) {
          u = a.content + (u - c) + 4;
          if (*u == '\'' || *u == '"') u++;
          char r[URL_MAX];
          int n = 0;
          for (; *u && *u != '\'' && *u != '"' && n < URL_MAX - 1; u++) r[n++] = *u;
          r[n] = 0;
          b.setRefresh(r);
        }
      } else if (strstr(c, "8859-1") || strstr(c, "windows-1252") || strstr(c, "latin1")) {
        latin1 = true;
      } else if (strstr(c, "utf-8")) {
        latin1 = false;
      }
    } else if (same(t, "base")) {
      if (a.url[0]) b.setBase(a.url);
    } else if (same(t, "a")) {
      curLink = 0;
      anchorCells = 0;
      strncpy(alabel, a.label, sizeof(alabel) - 1);
      alabel[sizeof(alabel) - 1] = 0;
      if (a.url[0]) {
        int id = b.addLink(a.url);
        curLink = id >= 0 ? id + 1 : 0;
      }
    } else if (same(t, "img")) {
      image();
    } else if (same(t, "br")) {
      br();
    } else if (same(t, "hr")) {
      para();
      if (!len) {
        Cell k = {'-', 0, 0};
        while (len < cols) line[len++] = k;
        emitLine();
      }
      blankOwed = true;
    } else if (same(t, "p") || same(t, "figure") || same(t, "dl") || same(t, "form") || same(t, "address")) {
      para();
    } else if (t[0] == 'h' && t[1] >= '1' && t[1] <= '6' && !t[2]) {
      para();
      bold++;
    } else if (same(t, "b") || same(t, "strong") || same(t, "th") || same(t, "dt")) {
      if (same(t, "th")) cell();
      if (same(t, "dt")) {
        breakLine();
        inDd = false;
      }
      bold++;
    } else if (same(t, "ul") || same(t, "ol") || same(t, "menu")) {
      if (nlists) breakLine();
      else para();
      if (nlists < 8) {
        lists[nlists].ordered = same(t, "ol");
        lists[nlists].n = 0;
        nlists++;
      }
    } else if (same(t, "li")) {
      breakLine();
      prefixLen = 0;
      if (nlists && lists[nlists - 1].ordered) {
        int v = ++lists[nlists - 1].n;
        char d[6];
        int k = 0;
        do d[k++] = '0' + v % 10;
        while ((v /= 10) && k < 3);
        if (k < 2) prefix[prefixLen++] = ' ';
        while (k) prefix[prefixLen++] = d[--k];
        prefix[prefixLen++] = '.';
        prefix[prefixLen++] = ' ';
      } else {
        prefix[prefixLen++] = '*';
        prefix[prefixLen++] = ' ';
      }
    } else if (same(t, "dd")) {
      breakLine();
      inDd = true;
    } else if (same(t, "pre") || same(t, "listing") || same(t, "xmp")) {
      para();
      pre = true;
      preStart = true;
    } else if (same(t, "blockquote")) {
      para();
      if (quote < 6) quote++;
    } else if (same(t, "tr")) {
      breakLine();
      cellNo = 0;
    } else if (same(t, "td")) {
      cell();
    } else if (same(t, "input")) {
      input();
    } else if (same(t, "button")) {
      button = 1;
    } else if (same(t, "q")) {
      put('"');
    } else if (same(t, "sup")) {
      put('^');
    } else if (same(t, "frame")) {
      if (a.url[0]) {
        breakLine();
        int id = b.addLink(a.url);
        curLink = id >= 0 ? id + 1 : 0;
        puts("[frame: ");
        words(a.name[0] ? a.name : a.url, 40);
        put(']');
        curLink = 0;
        breakLine();
      }
    } else if (oneOf(t, " div section article header footer nav main aside table thead tbody tfoot caption figcaption "
                        "fieldset legend details summary center option optgroup ")) {
      breakLine();
    }
  }

  void cell() {                       // a table's next cell: two columns from the last
    flushWord();
    if (cellNo++ && len) {
      Cell s = {' ', 0, 0};
      if (len < cols) line[len++] = s;
      space = true;
    }
  }

  void endTag(const char *t) {
    if (hideDepth) {
      if (same(t, hideName)) hideDepth--;
      return;
    }
    if (same(t, "title")) {
      inTitle = false;
      while (tlen && title[tlen - 1] == ' ') tlen--;
      title[tlen] = 0;
      b.setTitle(title);
    } else if (same(t, "a")) {
      if (curLink && !anchorCells) {             // a link with no words of its own
        if (alabel[0]) words(alabel, 40);
        else puts("[link]");
      }
      curLink = 0;
    } else if (same(t, "p") || same(t, "figure") || same(t, "dl") || same(t, "form") || same(t, "address")) {
      if (same(t, "dl")) inDd = false;
      para();
    } else if (t[0] == 'h' && t[1] >= '1' && t[1] <= '6' && !t[2]) {
      flushWord();
      if (bold) bold--;
      para();
    } else if (same(t, "b") || same(t, "strong") || same(t, "th") || same(t, "dt")) {
      if (bold) bold--;
      if (same(t, "dt")) breakLine();
    } else if (same(t, "ul") || same(t, "ol") || same(t, "menu")) {
      breakLine();
      prefixLen = 0;
      if (nlists) nlists--;
      if (!nlists) blankOwed = true;
    } else if (same(t, "li")) {
      breakLine();
      prefixLen = 0;
    } else if (same(t, "dd")) {
      breakLine();
      inDd = false;
    } else if (same(t, "pre") || same(t, "listing") || same(t, "xmp")) {
      if (len) emitLine();
      pre = false;
      blankOwed = true;
    } else if (same(t, "blockquote")) {
      para();
      if (quote) quote--;
    } else if (same(t, "button")) {
      if (button == 2) {
        flushWord();
        space = false;
        put(']');
      }
      button = 0;
    } else if (same(t, "q")) {
      put('"');
    } else if (oneOf(t, " div section article header footer nav main aside table thead tbody tfoot tr caption "
                        "figcaption fieldset legend details summary center ")) {
      breakLine();
    }
  }

  void tag() {
    int c = next();
    if (c == '!') {
      c = next();
      if (c == '-') {
        c = next();
        if (c == '-') {               // a comment, to "-->"
          int dashes = 0;
          for (;;) {
            c = next();
            if (c < 0) return;
            if (c == '-') dashes++;
            else if (c == '>' && dashes >= 2) return;
            else dashes = 0;
          }
        }
      }
      if (c != '>') skipTo('>');
      return;
    }
    if (c == '?') {
      skipTo('>');
      return;
    }
    bool end = c == '/';
    if (end) c = next();
    if (!(lower(c) >= 'a' && lower(c) <= 'z')) {          // not a tag: a "<" in the words
      if (!end) put('<');
      if (c >= 0) back(c);
      return;
    }
    char name[16];
    int n = 0;
    while (c >= 0 && !isSpace(c) && c != '>' && c != '/') {
      if (n < 15) name[n++] = (char)lower(c);
      c = next();
    }
    name[n] = 0;
    if (c >= 0) back(c);
    if (end) {
      skipTo('>');
      endTag(name);
    } else {
      bool slash = attributes();
      startTag(name, slash);
    }
  }

  Browser &b;
  Source &in;
  bool latin1;
  int held, cols;
  Cell line[COLS_MAX + 2], word[COLS_MAX + 2];
  int len, wlen;
  bool space, any, lastBlank, blankOwed, stop, pre, preStart, inTitle, unknown;
  int bold;
  uint16_t curLink;
  int anchorCells, quote;
  struct {
    bool ordered;
    int n;
  } lists[8];
  int nlists;
  bool inDd;
  int cellNo;
  char prefix[8];
  int prefixLen;
  char title[64];
  int tlen;
  char hideName[16];
  int hideDepth, button;
  char alabel[48];
  Attrs a;
};

void Layout::html() {
  while (!stop) {
    int c = next();
    if (c < 0) break;
    if (c == '<') {
      tag();
    } else if (c == '&') {
      char raw[16];
      int v = entity(raw);
      if (v >= 0) {
        cp(v);
      } else {
        put('&');
        puts(raw);
      }
    } else if (c >= 0x80) {
      text(c);
    } else if (pre) {
      if (c != '\r') cp(c);
    } else {
      unknown = false;
      put(isSpace(c) || c < 0x20 || c == 0x7F ? ' ' : (char)c);
    }
  }
  breakLine();
}

void Layout::plain() {
  pre = true;
  while (!stop) {
    int c = next();
    if (c < 0) break;
    if (c >= 0x80) text(c);
    else if (c != '\r') cp(c);
  }
  if (len) emitLine();
}

}  // namespace

void layoutHtml(Browser &b, Source &in, bool latin1) {
  Layout *l = new Layout(b, in, latin1);
  l->html();
  delete l;
}

void layoutText(Browser &b, Source &in) {
  Layout *l = new Layout(b, in, false);
  l->plain();
  delete l;
}

}  // namespace pb
