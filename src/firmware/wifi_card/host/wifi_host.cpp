// ============================================================
// wifi_host.cpp - the WiFi module's browser, run on a PC
// ============================================================
//
// The simulators (io_devices.WifiCard in placard_sim, WifiCard in
// web/placard_emu.js under node) have no module, so for the browser's
// commands they run this: the same browser.cpp, html.cpp and image.cpp
// the module's firmware is built from, with a connection made here.
//
//     g++ -std=c++11 -O2 -o wifi_host wifi_host.cpp ../browser.cpp ../html.cpp ../image.cpp -lssl -lcrypto
//     (-DNO_TLS and no libraries: only --sites)
//
//     wifi_host --sites DIR [--in FIFO --out FIFO]
//     wifi_host --live      [--in FIFO --out FIFO]
//
// It reads requests and writes replies as bytes (standard input and
// output, or the two named pipes):
//     request   command, n, n bytes
//     reply     status, m, m bytes
//
// --sites DIR: the web is the files of DIR.  DIR/index.txt has a line for
// each address, "http://host/path<tab>file": the file holds everything
// the site sends for it, status line and headers too.  A site not listed
// can't be reached; a path not listed gets a 404.  DIR/log.txt gets every
// request line.
// --live: the real web (TLS without checking certificates, as the
// module; through the proxy named in HTTPS_PROXY when there is one).
//
// Date: 2026-11-22
// ============================================================
#include "../browser.h"

#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <map>
#include <chrono>

#ifndef NO_TLS
#include <netdb.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>
#include <openssl/ssl.h>
#endif

static uint32_t nowMs() {
  using namespace std::chrono;
  return (uint32_t)duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// ---- the web as files
struct FileNet : pb::Net {
  std::string dir;
  std::map<std::string, std::string> index;      // "http://host[:port]/path" -> file
  std::string origin, in, out;
  bool isOpen;
  uint32_t clock;

  explicit FileNet(const std::string &d) : dir(d), isOpen(false), clock(0) {
    FILE *f = fopen((dir + "/index.txt").c_str(), "r");
    char line[2048];
    while (f && fgets(line, sizeof(line), f)) {
      std::string s(line);
      while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
      size_t tab = s.find('\t');
      if (tab != std::string::npos) index[s.substr(0, tab)] = s.substr(tab + 1);
    }
    if (f) fclose(f);
  }

  bool open(const char *host, uint16_t port, bool tls) {
    char o[300];
    if (port == (tls ? 443 : 80)) snprintf(o, sizeof(o), "%s://%s", tls ? "https" : "http", host);
    else snprintf(o, sizeof(o), "%s://%s:%u", tls ? "https" : "http", host, port);
    origin = o;
    in.clear();
    out.clear();
    isOpen = false;
    for (auto &e : index)
      if (e.first.compare(0, origin.size(), origin) == 0 && e.first[origin.size()] == '/') isOpen = true;
    return isOpen;
  }

  bool send(const uint8_t *d, int n) {
    if (!isOpen) return false;
    in.append((const char *)d, n);
    size_t end;
    while ((end = in.find("\r\n\r\n")) != std::string::npos) {
      std::string req = in.substr(0, end);
      in.erase(0, end + 4);
      size_t a = req.find(' '), b = req.find(' ', a + 1);
      std::string path = req.substr(a + 1, b - a - 1);
      FILE *log = fopen((dir + "/log.txt").c_str(), "a");
      if (log) {
        fprintf(log, "%s%s\n", origin.c_str(), path.c_str());
        fclose(log);
      }
      auto it = index.find(origin + path);
      if (it == index.end()) {
        out += "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        continue;
      }
      FILE *f = fopen((dir + "/" + it->second).c_str(), "rb");
      char buf[4096];
      size_t k;
      while (f && (k = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, k);
      if (f) fclose(f);
    }
    return true;
  }

  int recv(uint8_t *d, int max, uint32_t) {
    if (!isOpen) return -1;
    if (out.empty()) {
      clock += 250;                              // nothing to wait for: time passes instead
      return 0;
    }
    int n = (int)out.size() < max ? (int)out.size() : max;
    if (n > 97) n = 97;                          // in uneven pieces, as a network gives them
    memcpy(d, out.data(), n);
    out.erase(0, n);
    return n;
  }

  void close() { isOpen = false; }
  uint32_t ms() { return clock; }
};

#ifndef NO_TLS
// ---- the real web
struct LiveNet : pb::Net {
  int fd;
  SSL_CTX *ctx;
  SSL *ssl;
  LiveNet() : fd(-1), ssl(0) { ctx = SSL_CTX_new(TLS_client_method()); }

  bool dial(const char *host, const char *port) {
    struct addrinfo hints, *res = 0;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res)) return false;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
      fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
      if (fd >= 0 && connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
      if (fd >= 0) ::close(fd);
      fd = -1;
    }
    freeaddrinfo(res);
    return fd >= 0;
  }

  bool open(const char *host, uint16_t port, bool tls) {
    close();
    char p[8];
    snprintf(p, sizeof(p), "%u", port);
    const char *proxy = getenv("HTTPS_PROXY");
    if (!proxy) proxy = getenv("https_proxy");
    if (proxy && *proxy) {
      std::string px(proxy);
      size_t s = px.find("://");
      if (s != std::string::npos) px.erase(0, s + 3);
      size_t at = px.rfind('@');
      if (at != std::string::npos) px.erase(0, at + 1);
      while (!px.empty() && px.back() == '/') px.pop_back();
      size_t c = px.rfind(':');
      std::string ph = c == std::string::npos ? px : px.substr(0, c), pp = c == std::string::npos ? "80" : px.substr(c + 1);
      if (!dial(ph.c_str(), pp.c_str())) return false;
      char req[600];
      int n = snprintf(req, sizeof(req), "CONNECT %s:%s HTTP/1.1\r\nHost: %s:%s\r\n\r\n", host, p, host, p);
      if (::write(fd, req, n) != n) return false;
      std::string head;
      char ch;
      while (head.find("\r\n\r\n") == std::string::npos && ::read(fd, &ch, 1) == 1) head += ch;
      if (head.compare(0, 12, "HTTP/1.1 200") && head.compare(0, 12, "HTTP/1.0 200")) {
        close();
        return false;
      }
    } else if (!dial(host, p)) {
      return false;
    }
    if (tls) {
      ssl = SSL_new(ctx);
      SSL_set_fd(ssl, fd);
      SSL_set_tlsext_host_name(ssl, host);
      if (SSL_connect(ssl) != 1) {
        close();
        return false;
      }
    }
    return true;
  }

  bool send(const uint8_t *d, int n) {
    if (fd < 0) return false;
    return (ssl ? SSL_write(ssl, d, n) : (int)::write(fd, d, n)) == n;
  }

  int recv(uint8_t *d, int max, uint32_t waitMs) {
    if (fd < 0) return -1;
    if (!ssl || !SSL_pending(ssl)) {
      fd_set r;
      FD_ZERO(&r);
      FD_SET(fd, &r);
      struct timeval tv = {(long)(waitMs / 1000), (long)(waitMs % 1000) * 1000};
      if (select(fd + 1, &r, 0, 0, &tv) <= 0) return 0;
    }
    int n = ssl ? SSL_read(ssl, d, max) : (int)::read(fd, d, max);
    return n > 0 ? n : -1;
  }

  void close() {
    if (ssl) {
      SSL_free(ssl);
      ssl = 0;
    }
    if (fd >= 0) ::close(fd);
    fd = -1;
  }

  uint32_t ms() { return nowMs(); }
};
#endif

int main(int argc, char **argv) {
  pb::Net *net = 0;
  FILE *in = stdin, *out = stdout;
  const char *inPath = 0, *outPath = 0;
  for (int i = 1; i < argc; i++) {
    std::string a(argv[i]);
    if (a == "--sites" && i + 1 < argc) net = new FileNet(argv[++i]);
#ifndef NO_TLS
    else if (a == "--live") net = new LiveNet();
#endif
    else if (a == "--in" && i + 1 < argc) inPath = argv[++i];
    else if (a == "--out" && i + 1 < argc) outPath = argv[++i];
  }
  if (!net) {
    fprintf(stderr, "wifi_host --sites DIR | --live  [--in FIFO --out FIFO]\n");
    return 2;
  }
  if (inPath) in = fopen(inPath, "rb");
  if (outPath) out = fopen(outPath, "wb");
  if (!in || !out) return 2;
  static pb::Browser browser(*net);
  for (;;) {
    int cmd = fgetc(in), n = fgetc(in);
    if (cmd == EOF || n == EOF) return 0;
    uint8_t d[256], reply[256], m = 0;
    if (n && fread(d, 1, n, in) != (size_t)n) return 0;
    uint8_t st = browser.command((uint8_t)cmd, d, n, reply, &m);
    fputc(st, out);
    fputc(m, out);
    fwrite(reply, 1, m, out);
    fflush(out);
  }
}
