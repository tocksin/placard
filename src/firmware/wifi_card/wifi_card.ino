// ============================================================
// wifi_card.ino - firmware of the Placard WiFi expansion card's module
// ============================================================
//
// The module is an Espressif ESP32-C3-DevKitM-1 board on the card
// (docs/architecture/WIFICARD.md).  It is an SPI slave: the Placard
// clocks it through the card's PLD (src/pld/ATF22V10_WIFI.pld), the
// way it clocks the SD card.
//
// Build with the Arduino IDE (or arduino-cli) and the "esp32" boards
// package by Espressif, version 3.x; board "ESP32C3 Dev Module".
// Flash through the board's USB port WITH THE CARD OUT OF THE
// MACHINE (the board's USB and 5 V pins must not both be powered).
//
// THE LINK
//   SPI mode 3, most significant bit first, any speed up to 1 MHz.
//   A transfer is /CS low to /CS high.  READY (IO4) is high while
//   the module waits for a transfer and low while it works; the
//   Placard only starts a transfer while READY is high.
//
//   Request (Placard to module):   command, n, n bytes (n = 0-255)
//       The module's first byte in this transfer is 52h ("R").
//       Command 00h does nothing and has no reply.
//   Reply (the next transfer):     41h ("A"), status, m, m bytes
//       The Placard sends 00h bytes to clock it out.
//
//   Status: 00 done, 01 can't (see the command), 02 no network
//   joined, 03 no connection (or the other end closed it), FF unknown
//   command.
//
//   01 INFO    -> the firmware's name, text
//   02 JOIN    name 00 password 00 : join that network and keep it in
//              flash.  n = 0: join the network kept (01: none kept).
//              The join goes on by itself: ask with STATE
//   03 STATE   -> state (0 off, 1 joining, 2 joined, 3 failed), the
//              IPv4 address (4 bytes), the signal strength (-dBm)
//   04 LEAVE   radio off
//   10 OPEN    flags (bit 0: TLS), port high, port low, host name :
//              a TCP connection (one at a time)
//   11 SEND    bytes
//   12 RECV    most (1-255) -> the bytes that have come in, none if
//              nothing has; status 03 when the other end has closed
//              and everything was read
//   13 CLOSE
//   20 TIME    -> year - 2000, month, day, hour, minute, second,
//              weekday (0 = Sunday), UTC, from the network's time
//              servers (01: not known yet)
//
// A network kept in flash is joined again at power-up.
//
// NOT YET TRIED ON A BOARD (2026-11-21): written against the card's
// simulator model (src/scripts/io_devices.py, WifiCard), which the
// Placard side is tested with.
//
// Date: 2026-11-21
// ============================================================

#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiClientSecure.h>
#include <Preferences.h>
#include <time.h>
#include "driver/spi_slave.h"
#include "driver/gpio.h"
#include "esp_heap_caps.h"

// module pins (the card's schematic)
#define PIN_READY 4      // J3 pin 11, to the PLD's pin 10
#define PIN_MISO  5      // J3 pin 10, to the PLD's pin 9
#define PIN_SCK   6      // J3 pin 9, from the PLD's pin 14 through a divider
#define PIN_MOSI  7      // J3 pin 8, from pin 15
#define PIN_CS    10     // J1 pin 11, from pin 16

#define BUF_SIZE  260    // command or mark, status, length, 255 bytes; a multiple of 4

enum { ST_OK = 0x00, ST_CANT = 0x01, ST_NO_NET = 0x02, ST_NO_CONN = 0x03, ST_UNKNOWN = 0xFF };
enum { NET_OFF = 0, NET_JOINING = 1, NET_JOINED = 2, NET_FAILED = 3 };

static const char INFO[] = "PLACARD WIFI 1.0";
static const unsigned long JOIN_MS = 20000;      // a join that takes longer has failed
static const int32_t OPEN_MS = 8000;             // and so has a connection

static uint8_t *txBuf;
static uint8_t *rxBuf;
static uint8_t reply[255];
static uint8_t replyLen;

static Preferences prefs;
static WiFiClient plainClient;
static WiFiClientSecure tlsClient;
static WiFiClient *conn = nullptr;
static uint8_t netState = NET_OFF;
static unsigned long joinStart;
static bool clockAsked = false;

// READY follows the SPI driver: high once a transfer is queued, low when it ends
static void IRAM_ATTR onQueued(spi_slave_transaction_t *t) { gpio_set_level((gpio_num_t)PIN_READY, 1); }
static void IRAM_ATTR onDone(spi_slave_transaction_t *t)   { gpio_set_level((gpio_num_t)PIN_READY, 0); }

// one transfer: txBuf goes out, rxBuf comes in; the number of whole bytes the Placard clocked
static int transfer() {
  spi_slave_transaction_t t;
  memset(&t, 0, sizeof(t));
  memset(rxBuf, 0, BUF_SIZE);
  t.length = BUF_SIZE * 8;
  t.tx_buffer = txBuf;
  t.rx_buffer = rxBuf;
  if (spi_slave_transmit(SPI2_HOST, &t, portMAX_DELAY) != ESP_OK) return 0;
  return t.trans_len / 8;
}

static void startJoin(const char *name, const char *password) {
  if (conn) { conn->stop(); conn = nullptr; }
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(name, password);
  netState = NET_JOINING;
  joinStart = millis();
}

static bool joinKept() {
  String name = prefs.getString("name", "");
  if (name.length() == 0) return false;
  String password = prefs.getString("pass", "");
  startJoin(name.c_str(), password.c_str());
  return true;
}

static void follow() {                           // where the join has got to
  wl_status_t s = WiFi.status();
  if (netState == NET_JOINING) {
    if (s == WL_CONNECTED) {
      netState = NET_JOINED;
      if (!clockAsked) { configTime(0, 0, "pool.ntp.org", "time.nist.gov"); clockAsked = true; }
    } else if (millis() - joinStart > JOIN_MS) {
      netState = NET_FAILED;
    }
  } else if (netState == NET_JOINED && s != WL_CONNECTED) {
    netState = NET_JOINING;                      // the radio joins again by itself
    joinStart = millis();
  }
}

static uint8_t handle(uint8_t cmd, const uint8_t *d, uint8_t n) {
  replyLen = 0;
  switch (cmd) {
    case 0x01:
      replyLen = sizeof(INFO) - 1;
      memcpy(reply, INFO, replyLen);
      return ST_OK;

    case 0x02: {
      if (n == 0) {
        follow();
        if (netState == NET_JOINING || netState == NET_JOINED) return ST_OK;   // the kept network, already
        return joinKept() ? ST_OK : ST_CANT;
      }
      char text[256];
      memcpy(text, d, n);
      text[n] = 0;                               // the password's 00, if the Placard left it out
      const char *name = text;
      size_t nameLen = strlen(name);
      const char *password = nameLen + 1 < n ? text + nameLen + 1 : "";
      prefs.putString("name", name);
      prefs.putString("pass", password);
      startJoin(name, password);
      return ST_OK;
    }

    case 0x03: {
      follow();
      IPAddress ip = netState == NET_JOINED ? WiFi.localIP() : IPAddress(0, 0, 0, 0);
      reply[0] = netState;
      for (int i = 0; i < 4; i++) reply[1 + i] = ip[i];
      int rssi = netState == NET_JOINED ? -WiFi.RSSI() : 0;
      reply[5] = rssi < 0 ? 0 : rssi > 255 ? 255 : rssi;
      replyLen = 6;
      return ST_OK;
    }

    case 0x04:
      if (conn) { conn->stop(); conn = nullptr; }
      WiFi.disconnect(true);
      WiFi.mode(WIFI_OFF);
      netState = NET_OFF;
      return ST_OK;

    case 0x10: {
      follow();
      if (netState != NET_JOINED) return ST_NO_NET;
      if (n < 4) return ST_CANT;
      if (conn) { conn->stop(); conn = nullptr; }
      char host[256];
      memcpy(host, d + 3, n - 3);
      host[n - 3] = 0;
      uint16_t port = (uint16_t)d[1] << 8 | d[2];
      WiFiClient *c = &plainClient;
      if (d[0] & 1) {
        tlsClient.setInsecure();                 // the site's certificate is not checked
        c = &tlsClient;
      }
      if (!c->connect(host, port, OPEN_MS)) return ST_NO_CONN;
      conn = c;
      return ST_OK;
    }

    case 0x11:
      if (!conn || !conn->connected()) return ST_NO_CONN;
      return conn->write(d, n) == n ? ST_OK : ST_NO_CONN;

    case 0x12: {
      if (!conn) return ST_NO_CONN;
      int most = (n >= 1 && d[0]) ? d[0] : 255;
      int have = conn->available();
      if (have > 0) {
        int got = conn->read(reply, have < most ? have : most);
        replyLen = got > 0 ? got : 0;
        return ST_OK;
      }
      if (!conn->connected()) {                  // closed, and everything was read
        conn->stop();
        conn = nullptr;
        return ST_NO_CONN;
      }
      return ST_OK;                              // nothing yet
    }

    case 0x13:
      if (conn) { conn->stop(); conn = nullptr; }
      return ST_OK;

    case 0x20: {
      time_t now = time(nullptr);
      if (now < 1700000000) return ST_CANT;      // the time servers have not answered yet
      struct tm t;
      gmtime_r(&now, &t);
      reply[0] = t.tm_year - 100;
      reply[1] = t.tm_mon + 1;
      reply[2] = t.tm_mday;
      reply[3] = t.tm_hour;
      reply[4] = t.tm_min;
      reply[5] = t.tm_sec;
      reply[6] = t.tm_wday;
      replyLen = 7;
      return ST_OK;
    }
  }
  return ST_UNKNOWN;
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_READY, OUTPUT);
  digitalWrite(PIN_READY, LOW);

  txBuf = (uint8_t *)heap_caps_malloc(BUF_SIZE, MALLOC_CAP_DMA);
  rxBuf = (uint8_t *)heap_caps_malloc(BUF_SIZE, MALLOC_CAP_DMA);

  spi_bus_config_t bus;
  memset(&bus, 0, sizeof(bus));
  bus.mosi_io_num = PIN_MOSI;
  bus.miso_io_num = PIN_MISO;
  bus.sclk_io_num = PIN_SCK;
  bus.quadwp_io_num = -1;
  bus.quadhd_io_num = -1;

  spi_slave_interface_config_t slave;
  memset(&slave, 0, sizeof(slave));
  slave.spics_io_num = PIN_CS;
  slave.queue_size = 1;
  slave.mode = 3;
  slave.post_setup_cb = onQueued;
  slave.post_trans_cb = onDone;

  // the card's dividers hold SCK, MOSI and /CS; pull-ups cover a module off the card
  gpio_set_pull_mode((gpio_num_t)PIN_CS, GPIO_PULLUP_ONLY);
  gpio_set_pull_mode((gpio_num_t)PIN_SCK, GPIO_PULLUP_ONLY);
  gpio_set_pull_mode((gpio_num_t)PIN_MOSI, GPIO_PULLUP_ONLY);

  esp_err_t err = spi_slave_initialize(SPI2_HOST, &bus, &slave, SPI_DMA_CH_AUTO);
  Serial.printf("%s: SPI %s\n", INFO, err == ESP_OK ? "ready" : "FAILED");

  prefs.begin("placard", false);
  joinKept();
}

void loop() {
  // a request
  memset(txBuf, 0, BUF_SIZE);
  txBuf[0] = 0x52;
  int got = transfer();
  if (got < 1 || rxBuf[0] == 0x00) return;
  uint8_t cmd = rxBuf[0];
  int n = got >= 2 ? rxBuf[1] : 0;
  if (n > got - 2) n = got - 2 < 0 ? 0 : got - 2;
  static uint8_t request[256];
  memcpy(request, rxBuf + 2, n);

  uint8_t status = handle(cmd, request, (uint8_t)n);
  Serial.printf("command %02X, %d bytes: status %02X, %d bytes\n", cmd, n, status, replyLen);

  // its reply
  memset(txBuf, 0, BUF_SIZE);
  txBuf[0] = 0x41;
  txBuf[1] = status;
  txBuf[2] = replyLen;
  memcpy(txBuf + 3, reply, replyLen);
  transfer();
}
