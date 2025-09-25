#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <Adafruit_NeoPixel.h>

// ====== WIFI CONFIG ======
const char* STA_SSID     = "Raspbain";
const char* STA_PASSWORD = "Zombie1986X2";

// SoftAP (optional – can remove if you only need STA)
const char* AP_SSID      = "WhiteHat-Source";
const char* AP_PASSWORD  = "Zombie1986X2";

// ====== GITEA BACKEND ======
const char* GITEA_BACKEND_HOST = "192.168.0.130";  // Pi with Gitea
const uint16_t GITEA_BACKEND_PORT = 3000;
const char* PROXY_PREFIX = "/gitea";

WebServer server(80);

// ====== LED CONFIG (NeoPixel on GPIO4) ======
const int NEO_PIN = 4;
Adafruit_NeoPixel strip(1, NEO_PIN, NEO_GRB + NEO_KHZ800);

struct RGB { uint8_t r,g,b; };
const RGB COL_BLUE{0,0,255}, COL_TEAL{0,128,128}, COL_GREEN{0,255,0}, COL_RED{255,0,0};
RGB g_color = COL_BLUE;

void ledSet(const RGB& c) {
  g_color = c;
  strip.setPixelColor(0, strip.Color(c.r, c.g, c.b));
  strip.show();
}

// ====== PROXY LOGIC ======
void proxyToGitea() {
  String uri = server.uri();
  if (!uri.startsWith(PROXY_PREFIX)) uri = PROXY_PREFIX + uri;

  String url = "http://" + String(GITEA_BACKEND_HOST) + ":" + String(GITEA_BACKEND_PORT) + uri;

  HTTPClient http;
  http.begin(url);

  if (server.hasHeader("Content-Type"))
    http.addHeader("Content-Type", server.header("Content-Type"));

  int code = -1;
  String resp;

  if (server.method() == HTTP_POST) {
    String body = server.arg("plain");
    code = http.POST(body);
  } else {
    code = http.GET();
  }

  resp = (code > 0) ? http.getString() : String("Proxy error: ") + http.errorToString(code);
  String ct = http.header("Content-Type");
  if (ct.isEmpty()) ct = "text/html; charset=utf-8";

  server.send(code > 0 ? code : 502, ct, resp);
  http.end();
}

// ====== SETUP ======
void setup() {
  Serial.begin(115200);
  strip.begin(); strip.show();
  ledSet(COL_BLUE);

  WiFi.mode(WIFI_AP_STA);

  // Connect to router
  WiFi.begin(STA_SSID, STA_PASSWORD);
  Serial.printf("Connecting to %s", STA_SSID);
  int tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 60) {
    delay(500); Serial.print(".");
    tries++;
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("✅ STA connected: %s\n", WiFi.localIP().toString().c_str());
    ledSet(COL_GREEN);
  } else {
    Serial.println("⚠️ STA connect failed, AP only.");
    ledSet(COL_TEAL);
  }

  // Start AP too (optional)
  WiFi.softAP(AP_SSID, AP_PASSWORD);
  Serial.printf("AP started: %s (IP %s)\n", AP_SSID, WiFi.softAPIP().toString().c_str());

  // Routes
  server.on("/", HTTP_GET, []() {
    server.sendHeader("Location", String(PROXY_PREFIX) + "/");
    server.send(302, "text/plain", "Redirecting to Gitea…");
  });

  // Catch-all: proxy everything under /gitea/*
  server.onNotFound([]() {
    if (server.uri().startsWith(PROXY_PREFIX))
      proxyToGitea();
    else {
      server.sendHeader("Location", String(PROXY_PREFIX) + "/");
      server.send(302, "text/plain", "Redirecting to Gitea…");
    }
  });

  server.begin();
  Serial.println("🌐 Web proxy started → open ESP32 IP to reach Gitea.");
}

// ====== LOOP ======
void loop() {
  server.handleClient();
}
