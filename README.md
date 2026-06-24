# Plex nginx Performance Tuning

A guide to running nginx as a reverse proxy in front of Plex Media Server with
tuning for fast UI loading and zero-buffer direct-play streaming. Covers nginx
config, OS TCP settings, and Plex network settings.

Tested with nginx 1.30, Plex on Debian/Ubuntu, clients on a LAN (smart TVs,
streaming sticks, Chrome on Windows). Direct-play HEVC/AC3 library — no transcoding.

> **Disclaimer:** This is a reference guide documenting one homelab configuration.
> It is provided for educational purposes only — not as hardened production advice.
> Test any changes in your own environment before deploying. No warranty is implied.
> This project is not affiliated with, endorsed by, or sponsored by Plex Inc.

---

## Why a reverse proxy in front of Plex?

Plex already has its own HTTP server, so why add nginx?

- **HTTPS with a real cert** — nginx handles TLS termination with a Let's Encrypt
  cert. Plex's built-in HTTPS uses a self-signed cert that causes browser warnings
  and can't be verified by apps.
- **HTTP/2** — nginx speaks HTTP/2 to clients, which multiplexes the ~20 parallel
  requests a Plex page load fires (posters, metadata, assets). Plex's own server
  uses HTTP/1.1.
- **Thumbnail caching** — nginx can cache poster and artwork responses so repeated
  requests (opening a library, scrolling) skip the round-trip to Plex entirely.
- **Compression** — nginx gzips JSON and web assets before they leave the server.
  Plex's built-in compression is less controllable.
- **Streaming control** — `proxy_buffering off` on media paths means nginx passes
  video chunks straight through to the client instead of accumulating them first,
  eliminating nginx-induced buffering stalls.

---

## Topology

This guide assumes nginx and Plex run on the **same host**:

```
Client → nginx :443 (TLS) → Plex :32400 (localhost)
```

If you have an SNI router or another reverse proxy in front of nginx (common in
homelab setups), that outer layer should do passthrough — TLS must terminate at
nginx for HTTP/2 and the cert to work correctly.

---

## Prerequisites

- nginx 1.25.1 or newer (for `http2 on;` syntax — older versions use `listen 443 ssl http2;`)
- A valid TLS certificate for your Plex domain (Let's Encrypt recommended)
- Plex Media Server running and accessible on `localhost:32400`
- The nginx cache directory created before first use:

```bash
mkdir -p /var/cache/nginx
chown www-data:www-data /var/cache/nginx   # adjust user for your distro
```

---

## nginx config

### nginx.conf — additions to the `http {}` block

```nginx
# Proxy cache zone for Plex thumbnails/posters
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=CACHE:10m max_size=512m inactive=60m use_temp_path=off;

# WebSocket upgrade map — the "" → "" mapping (not "close") is critical
# Using "close" here would send Connection: close to Plex and break upstream keepalive
map $http_upgrade $connection_upgrade {
    default  "upgrade";
    ""       "";
}

# Global proxy defaults
proxy_connect_timeout   10s;
proxy_read_timeout      60s;
proxy_send_timeout      60s;
proxy_request_buffering off;   # Plex sync/resumption POSTs must reach Plex immediately
proxy_buffer_size       8k;
proxy_buffers           8 16k;
proxy_busy_buffers_size 32k;

# Performance
server_tokens     off;
tcp_nodelay       on;
keepalive_timeout 65;
open_file_cache   max=200 inactive=60s;
open_file_cache_valid 120s;
access_log /var/log/nginx/access.log combined buffer=16k flush=5m;
```

### Plex vhost — `/etc/nginx/sites-enabled/plex.conf`

```nginx
upstream plex {
    server 127.0.0.1:32400;
    keepalive 16;   # reuse TCP connections to Plex across UI requests
}

# Redirect HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name plex.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name plex.example.com;

    ssl_certificate     /etc/letsencrypt/live/plex.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/plex.example.com/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/plex.example.com/chain.pem;

    include include/ssl.conf;
    include include/gzip.conf;

    # IMPORTANT: all proxy_set_header directives live here at the server level.
    # If any location block defines proxy_set_header, nginx drops ALL parent-level
    # headers for that location — it's a full replacement, not additive.
    # Keeping headers here and nothing in location blocks avoids that pitfall.
    proxy_http_version 1.1;
    proxy_set_header Host              $host;           # required for Plex DNS rebinding protection
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        $connection_upgrade;
    proxy_set_header Accept-Encoding   "";              # let nginx own compression, not Plex

    proxy_buffering off;   # default off; thumbnail location overrides to on

    # 1. WebSocket — Plex web client uses this for real-time library and playback updates
    location /:/websockets/ {
        proxy_pass http://plex;
        proxy_read_timeout 3600s;   # WebSocket must survive the full browser session
    }

    # 2. Direct-play streaming — video must flow through immediately, not accumulate in nginx
    location ~ ^/(library/parts|video)/ {
        proxy_pass http://plex;
        proxy_request_buffering off;
        proxy_read_timeout      7200s;   # covers a 2-hour film at direct-play speed
        proxy_send_timeout      7200s;
        access_log              off;     # streaming generates thousands of log lines per film
    }

    # 3. Thumbnails and posters — cache at nginx to avoid repeated round-trips to Plex
    location /photo/:/ {
        proxy_pass http://plex;
        proxy_buffering               on;    # must be on to write to disk cache
        proxy_cache                   CACHE;
        proxy_cache_valid             200 1h;
        proxy_cache_use_stale         error timeout updating;
        proxy_cache_background_update on;
        proxy_cache_lock              on;
        proxy_cache_key               "$host$uri$arg_url$arg_width$arg_height"; # strip X-Plex-Token, keep image identity
        proxy_ignore_headers          Cache-Control Expires; # Plex sends no-cache; override it
        add_header X-Cache-Status     $upstream_cache_status always;
    }

    # 4. Everything else — UI, API, metadata
    location / {
        proxy_pass http://plex;
    }
}
```

### include/ssl.conf

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
ssl_prefer_server_ciphers off;

ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

ssl_stapling        on;
ssl_stapling_verify on;
resolver            1.1.1.1 8.8.8.8 valid=300s;

add_header Strict-Transport-Security "max-age=15768000" always;
add_header Referrer-Policy           strict-origin-when-cross-origin always;
add_header X-Frame-Options           SAMEORIGIN always;
add_header X-Content-Type-Options    nosniff always;
```

### include/gzip.conf

```nginx
gzip              on;
gzip_vary         on;
gzip_proxied      any;
gzip_comp_level   4;
gzip_min_length   1000;
gzip_types
    text/plain text/css text/xml text/javascript
    application/javascript application/json application/xml
    application/rss+xml image/svg+xml;
# Omit video/* and audio/* — Plex serves HEVC as video/mp4 and AC3 as audio/x-ac3
# These are already compressed; running them through gzip wastes CPU and can increase size
```

---

## Why those thumbnail cache directives?

Two directives in the `/photo/:/` location are non-obvious:

**`proxy_cache_key "$host$uri$arg_url$arg_width$arg_height"`**

Plex appends `X-Plex-Token` as a query parameter on thumbnail requests:
`/photo/:/transcode?url=...&width=150&height=225&X-Plex-Token=abc123`

nginx's default cache key includes `$request_uri` (the full query string). Each
device has a different token, so each device gets its own cache entry for the
same poster art — they never share.

The fix is to build the key from only the parameters that identify the image:
`$arg_url`, `$arg_width`, `$arg_height`. This excludes the token while keeping
the parts that distinguish one image from another.

Do not use `"$host$uri"` alone (path only, no query string) — all thumbnail
requests share the same path `/photo/:/transcode`, so that key would collapse
every image to a single cache entry and serve one image for everything.

**`proxy_ignore_headers Cache-Control Expires`**

Plex sends `Cache-Control: no-cache` on `/photo/:/` responses. By default nginx
respects this and skips the cache, making every thumbnail request a cache miss.
This directive tells nginx to ignore Plex's Cache-Control and apply your own TTL.

It's safe to ignore Cache-Control on thumbnails — poster art doesn't change mid-session.
Don't use this on the UI or API locations where Plex's cache headers are intentional.

---

## OS TCP tuning

These kernel settings improve streaming behavior. Apply on the machine running nginx/Plex.

If your Plex host is a **Proxmox LXC container**: `net.ipv4.*` settings must be
applied inside the container (they're per network namespace). `net.core.*` and
`net.ipv4.tcp_congestion_control` must be set on the Proxmox host — the LXC
shares the host kernel for those.

Create `/etc/sysctl.d/99-plex-perf.conf`:

```ini
# BBR congestion control — better throughput on WAN paths
# On Proxmox: set net.core.default_qdisc and tcp_congestion_control on the HOST
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Prevent TCP window reset after idle gaps
# Without this: pausing a Plex stream for ~1s causes the kernel to reset the
# congestion window, forcing nginx to rebuild it on resume — visible as a
# buffer spinner before playback continues
net.ipv4.tcp_slow_start_after_idle = 0

# TCP Fast Open — saves one RTT on repeat connections where supported
# Modern browsers have largely disabled TFO; mainly helps non-browser clients
net.ipv4.tcp_fastopen = 3

# Raise socket buffer ceilings for 4K HEVC throughput
# With proxy_buffering off, the kernel socket buffer is the stream path
# Default 256KB can throttle a 4K stream at 50Mbps before the player pre-buffers enough
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

Apply immediately (no reboot): `sudo sysctl --system`

Verify: `sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_slow_start_after_idle net.core.rmem_max`

---

## Plex Settings

In Plex web → Settings:

**Settings → Remote Access:**
- Disable relay — relay routes connections through Plex's cloud servers when it
  can't confirm a direct path. On LAN this adds unnecessary latency.
- Set LAN Bandwidth to match your network (e.g. `1000 Mbps` for gigabit). A low
  value throttles direct play before nginx sees the traffic.

**Settings → Network:**
- **Custom server access URLs** — add `https://plex.example.com`. Required for
  Plex's DNS rebinding protection to accept requests that arrive with your domain
  as the Host header.
- **List of IP addresses and networks that are allowed without auth** — add your
  LAN subnet (e.g. `192.168.1.0/24`). This skips per-request token validation for
  local clients. Most visible as a TTFB reduction on API calls like `/library/sections`.

---

## Verifying the setup

```bash
# nginx config is valid
sudo nginx -t

# HTTP/2 active
curl -sI --http2 https://plex.example.com/web/index.html | head -1
# → HTTP/2 200

# gzip active on UI responses
curl -sI -H 'Accept-Encoding: gzip' https://plex.example.com/web/index.html | grep content-encoding
# → content-encoding: gzip

# Thumbnail cache working — run the same URL twice
curl -sI 'https://plex.example.com/photo/:/transcode?url=...&X-Plex-Token=TOKEN' | grep x-cache-status
# → x-cache-status: MISS
curl -sI 'https://plex.example.com/photo/:/transcode?url=...&X-Plex-Token=TOKEN' | grep x-cache-status
# → x-cache-status: HIT

# Cross-device cache sharing — different token, same URL should still HIT
curl -sI 'https://plex.example.com/photo/:/transcode?url=...&X-Plex-Token=DIFFERENT_TOKEN' | grep x-cache-status
# → x-cache-status: HIT

# TTFB measurement (run from a LAN client)
curl -w "TTFB: %{time_starttransfer}s\n" -o /dev/null -s https://plex.example.com/web/index.html
```

---

## Direct Play vs Transcode

Whether Plex streams a file directly or transcodes it depends entirely on what
the **client** can decode, not the library encoding. The Plex dashboard
(Settings → Troubleshooting → Dashboard) shows "Direct Play", "Direct Stream",
or "Transcode" for every active session — always verify there rather than
assuming.

**Direct Play** means Plex sends the file bytes to the client unmodified. The
client decodes everything locally. This is the ideal path — zero CPU on the
server, no quality loss, lowest possible latency to first frame.

**Direct Stream** means the container or audio track is remuxed but video is
not re-encoded. Lower CPU than a full transcode.

**Transcode** means Plex is re-encoding video and/or audio in real time.
Server CPU (or GPU) is the bottleneck; nginx's job is just to pass the
HLS segments through.

### Chrome and HEVC/AC3

The common assumption that browsers always transcode HEVC is outdated.
Chrome on Windows supports hardware HEVC decoding as of Chrome 107+, provided:

- The GPU supports HEVC hardware decode (most modern Intel, AMD, and NVIDIA GPUs do)
- Windows has the **HEVC Video Extensions** installed (free from the Microsoft Store, or included with some GPU drivers)

With those in place, Chrome direct plays HEVC to the Plex web client. AC3
audio can also pass through in some configurations. Confirm in the Plex
dashboard — if it shows Direct Play, no transcoding is happening regardless
of the browser.

Chrome on Linux and macOS has more limited HEVC support — those clients are
more likely to trigger a transcode. Check the dashboard rather than assuming.

### Library encoding profile

Files in this library are encoded with HandBrake using the following settings:

```
-e x265_10bit -q 23 --encoder-preset slow
-E ac3 -B 640 -6 5point1 -R Auto
--audio-lang-list eng,und --first-audio
-X 1920 -Y 1080 --auto-anamorphic --keep-display-aspect
--crop 0:0:0:0 --format av_mkv --align-av
--encopts "bframes=3"
```

Key choices and why they matter for direct play:

- **`x265_10bit`** — HEVC 10-bit. Widely supported by hardware decoders on modern devices. 10-bit reduces banding on gradients with no extra storage cost at typical quality settings.
- **`-q 23`** — RF 23 quality. Good balance of size and quality for 1080p; well within the bitrate range all direct-play clients handle comfortably.
- **`ac3 640kbps 5.1`** — AC3 (Dolby Digital) at 640kbps. AC3 is the most compatible surround codec across Plex clients. Virtually every TV, streaming stick, and AV receiver passes it through without transcoding.
- **`--first-audio --audio-lang-list eng,und`** — keeps only the first English or undefined-language track. Avoids multi-track files that confuse some clients into transcoding to pick a different stream.
- **`-X 1920 -Y 1080`** — caps output at 1080p. Keeps file sizes predictable and ensures hardware decoders that max out at 1080p don't fall back to software decode.
- **`--crop 0:0:0:0`** — explicit no-crop. Prevents HandBrake's auto-detect from cropping incorrectly on sources with inconsistent black bars.
- **`--format av_mkv`** — MKV container. Handles any codec combination, supports chapters and subtitle tracks, and is universally supported by Plex.
- **`--encopts "bframes=3"`** — 3 B-frames. Improves x265 compression efficiency without noticeably increasing decode complexity for hardware decoders.

This profile produces files that direct play on every client in the table below.

#### NVENC variant

For faster encodes on a machine with an NVIDIA GPU, swap the encoder and quality value:

```
-e nvenc_h265_10bit -q 27 --encoder-preset slow
-E ac3 -B 640 -6 5point1 -R Auto
--audio-lang-list eng,und --first-audio
-X 1920 -Y 1080 --auto-anamorphic --keep-display-aspect
--crop 0:0:0:0 --format av_mkv --align-av
--encopts "bframes=3"
```

The only differences from the software profile:

- **`nvenc_h265_10bit`** — uses NVIDIA's hardware H.265 encoder instead of x265. Encodes 5–10× faster at the cost of slightly larger files at the same perceptual quality.
- **`-q 27`** — NVENC's quality scale is not the same as x265's RF. RF 27 on NVENC produces roughly equivalent visual quality to RF 23 on x265; using RF 23 with NVENC would result in unnecessarily large files.

Everything else — container, audio, resolution, crop, anamorphic — is identical. Output files are indistinguishable to Plex clients and direct play the same way.

### Clients that reliably direct play HEVC/AC3

| Client | HEVC | AC3 |
|---|---|---|
| Plex for Android TV (Shield, Google TV) | ✓ | ✓ |
| Plex for Roku | ✓ | ✓ |
| Plex for Apple TV | ✓ | ✓ |
| Plex for iOS / tvOS | ✓ | ✓ |
| Chrome on Windows (with HEVC extensions) | ✓ | depends on config |
| Chrome on Linux / macOS | ✗ (usually transcodes) | ✗ |
| Firefox | ✗ | ✗ |
| Plex HTPC | ✓ | ✓ |
| Infuse | ✓ | ✓ |

If your primary clients are all in the "✓" column, `proxy_buffering off` on the
streaming path and the TCP socket buffer tuning in this guide are what matter
most. If you have transcoding clients, hardware transcoding (Intel QSV, NVIDIA
NVENC, Apple VideoToolbox) on the Plex server becomes the dominant factor —
nginx tuning is secondary.

---

## Storage

nginx and TCP tuning have a ceiling: once you're at the TLS handshake floor
(~12ms on a local gigabit network), there's nothing left for nginx to optimize.
The next layer down is storage — and it's often the bigger bottleneck.

### NVMe for Plex metadata

Plex's metadata lives in a SQLite database. Every library browse, search, and
poster load issues multiple queries against it. On spinning disk or even SATA
SSD, this database becomes the bottleneck well before nginx does.

**Put the Plex metadata directory on NVMe.** The default locations:

| Platform | Metadata path |
|---|---|
| Linux | `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/` |
| macOS | `~/Library/Application Support/Plex Media Server/` |
| Windows | `%LOCALAPPDATA%\Plex Media Server\` |
| Docker | wherever you mount `/config` |

The metadata directory contains the SQLite DB (`com.plexapp.plugins.library.db`),
thumbnails Plex generates itself, and episode/movie bundles. It does not need to
be on the same drive as your media — and for performance, it shouldn't be.

If you can't move the whole directory, symlinking `Plug-in Support/Databases/`
to NVMe gets the highest-impact subset (the SQLite DB files).

Media files themselves do not need NVMe — sequential read from spinning disk or
NAS is fine for direct play, since the bottleneck there is network, not seek time.

### PlexDBRepair

Plex's SQLite database accumulates fragmentation and bloat over time. Query
times degrade gradually — you won't notice until browsing feels sluggish.
[PlexDBRepair](https://github.com/ChuckPa/DBRepair) is a free tool that
vacuums, reindexes, and repairs the database without touching your library data.

```bash
# Stop Plex first — never run against a live database
sudo systemctl stop plexmediaserver

# Download and run
wget https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair.sh
chmod +x DBRepair.sh
sudo ./DBRepair.sh

# Restart when done
sudo systemctl start plexmediaserver
```

Run quarterly, or whenever you notice library browse performance degrading.
Back up the database directory first — the tool is safe but a backup costs nothing.

---

## A/B test results

Two configs compared: a baseline single-location config vs the four-location
tuned config from this guide. Tested from both a LAN client and a WAN VPS
(~35ms RTT) against nginx 1.30.

### Measurement method

```bash
curl -w "connect:%{time_connect}s tls:%{time_appconnect}s ttfb:%{time_starttransfer}s total:%{time_total}s\n" \
     -s -o /dev/null https://plex.example.com/web/index.html
```

### A note on LAN testing

LAN results are useful for isolating specific behaviours (cache hit/miss timing,
TLS session resumption) but are not a representative measure of the tuning's
real-world value. On a LAN, clients can reach Plex directly over HTTP on
port 32400, bypassing nginx and TLS entirely — 0.3ms vs 13ms. The 13ms TLS
floor that dominates every LAN measurement is an unavoidable constant, not
something the nginx config can affect. **WAN results are the meaningful
comparison** because transfer time and congestion control matter, gzip savings
are real, and there's no HTTP shortcut available.

### LAN results (same gigabit segment, ~0.2ms RTT)

#### UI and API — no measurable difference on LAN

| Endpoint | Baseline TTFB | Tuned TTFB |
|---|---|---|
| `/web/index.html` | 13.8ms | 13.7ms |
| `/library/sections` | 14.1ms | 14.1ms |

TLS handshake (~12.5ms) dominates. Plex itself responds in under 1ms. Neither
config can improve on this floor, and gzip savings are invisible because gigabit
absorbs the extra uncompressed bytes in microseconds.

#### Thumbnails — large difference even on LAN

| Request | Tuned | Baseline |
|---|---|---|
| First load (cold) | 53ms (MISS) | 67ms (MISS) |
| Second request | **13ms (HIT)** | 43ms (Plex internal cache) |
| Third request | **13ms (HIT)** | 47ms (Plex internal cache) |

Thumbnail caching is visible even on LAN. The baseline round-trips to Plex on
every request; the tuned config serves from nginx at TLS-floor speed after the
first load. At library scale (50 movies): ~650ms vs ~2.5 seconds of thumbnail
load time.

### WAN results (OVH VPS, ~35ms RTT) — tuned config wins clearly

| Endpoint | Baseline TTFB | Tuned TTFB | Delta |
|---|---|---|---|
| `/web/index.html` | 189ms | **153ms** | **−36ms** |
| `/library/sections` | 153ms | 153ms | 0ms |
| Thumbnail MISS | 189ms | 201ms | +12ms (Plex fetch) |
| Thumbnail HIT | 189ms | **152ms** | **−37ms** |

**UI is 36ms faster** due to gzip. The baseline sends uncompressed JS, CSS, and
JSON. Over a 35ms WAN path the extra bytes add measurable transfer time; on LAN
gigabit makes it invisible.

**Thumbnail HITs are 37ms faster** — nginx cache serves at the TLS floor
(152ms) while the baseline always round-trips to Plex (189ms).

**Thumbnail MISSes are 12ms slower** on the first request — this is the cost
of nginx fetching and caching the image. It's a one-time penalty per image per
cache warm cycle; every subsequent request saves 37ms.

**API is identical** — the JSON payload is small enough that gzip savings don't
affect TTFB regardless of path.

### Direct Plex WAN baseline (HTTP :32400, no nginx, no TLS)

Measured from the same VPS with port 32400 temporarily open:

| Endpoint | TTFB | Total |
|---|---|---|
| `/web/index.html` | ~74ms | ~119ms |
| `/library/sections` | ~75ms | ~75ms |
| Thumbnail | ~103ms | ~103ms |

This is the theoretical floor — no proxy overhead, no TLS, same network path.

**UI total (119ms) is comparable to nginx+HTTPS TTFB (153ms).** The 34ms gap
is almost entirely TLS handshake cost (~35ms at this RTT). Gzip saves ~36ms on
transfer, nearly canceling the TLS overhead — so nginx+HTTPS+gzip delivers UI
loading close to what raw HTTP to Plex would.

**Thumbnails via nginx HIT (152ms) vs direct HTTP (103ms):** the ~49ms
difference is TLS cost. You're paying for encryption, not proxy overhead.

**The takeaway:** nginx is not adding meaningful latency beyond TLS. If you're
serving over HTTPS (which you should be), the proxy overhead is negligible and
the gzip and caching gains offset most of the TLS cost.

### What the tuning changes did not affect

- Streaming start time — dominated by Plex's seek-and-respond time, not nginx
- WebSocket reliability — works correctly in both configs
- API TTFB — response payloads too small for gzip to matter

### What the baseline config had wrong

Beyond missing gzip and caching, the baseline had two structural issues:

**File extension media matching.** The baseline matched streaming paths via
`location ~* \.(mp4|mkv|avi|...)$`. Plex streams video at paths like
`/library/parts/12345/1/file.mkv` — these do end in a file extension so the
match technically works, but only for known extensions. The location silently
falls through to the catch-all for anything else. The tuned config uses
`location ~ ^/(library/parts|video)/` which matches all Plex streaming paths
regardless of extension.

**`proxy_set_header` in each location block.** The baseline defined all headers
inside each location block. nginx's inheritance rule means any location that
defines `proxy_set_header` replaces *all* parent-level headers — not just the
ones it explicitly sets. The baseline happens to work because both locations
define the same header set, but it's fragile: adding a location without the
full header set would silently drop headers for that location. The tuned config
keeps all headers at the server block level.

---

## Common gotchas

**Plex crashes on reboot if its Cache directory is a symlink to tmpfs**

If you've symlinked Plex's Cache directory to `/dev/shm/` for RAM-based caching,
the target directory is wiped on every reboot. Plex does not recreate it and
crashes with a `boost::filesystem::create_directories` error instead of starting.

Fix: add `ExecStartPre` to the Plex systemd override so the directory is created
before Plex starts on every boot.

```bash
sudo systemctl edit plexmediaserver
```

Add inside the `[Service]` section:

```ini
ExecStartPre=/bin/mkdir -p /dev/shm/plex-cache
```

The ExecStartPre command runs as the same user as the service. Since `/dev/shm`
is world-writable, no elevated privileges are needed. `mkdir -p` is idempotent —
safe to run even if the directory already exists.

Note: `systemd-tmpfiles` is the usual tool for managing tmpfs directories but
is blocked inside Proxmox LXC containers due to the user namespace path
transition check. ExecStartPre is the correct workaround in that environment.

**`proxy_set_header` in a location block kills parent headers**
nginx's inheritance rule: defining any `proxy_set_header` in a child context
replaces all parent-level headers for that context. Keep all headers at the
server block level and don't add any to location blocks.

**`Connection: close` in the WebSocket map breaks upstream keepalive**
The map must use `""` (empty string) for the non-upgrade case, not `"close"`.
Using `"close"` sends `Connection: close` to Plex for every non-WebSocket
request, preventing keepalive connections from being reused.

**`proxy_buffering off` on the thumbnail location prevents caching**
nginx must buffer a response to write it to the proxy cache. The thumbnail
location explicitly re-enables `proxy_buffering on` to override the server-level
`proxy_buffering off`.

**nginx does not `mkdir` output directories**
The proxy cache directory (`/var/cache/nginx`) must exist before nginx starts.
Create it manually and set the correct ownership for the nginx worker user.

**Let's Encrypt cannot issue certs for `.lan` / `.local` domains**
If your internal hostname is `plex.lan`, you cannot get a public TLS cert for it.
Use a real public domain (even if it only resolves internally via split DNS)
so Let's Encrypt HTTP-01 challenge can complete.
