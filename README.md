# Serving Plex Right: nginx proxy, TCP tuning, and benchmark results

This guide covers using nginx as a reverse proxy for Plex, with benchmark
results comparing a baseline nginx config, a tuned nginx config, and Plex's
own built-in HTTPS (plex.direct). The primary value of nginx for Plex is cert
independence: your own Let's Encrypt cert, your domain, and no dependency on
Plex's rate-limited certificate infrastructure. The performance delta over
Plex's native HTTPS is modest — both gzip their responses, and in 20-run WAN
averages the two are within 1ms of each other on TTFB and ~5ms on total time.

Tested with nginx 1.30 on Debian/Ubuntu. LAN clients: smart TVs, streaming
sticks, Chrome on Windows. WAN tested from an OVH VPS at ~35ms RTT.
Direct-play HEVC/AC3 library. No transcoding.

> **Disclaimer:** This is a reference guide documenting one homelab configuration.
> It is provided for educational purposes only. Not hardened production advice.
> Test any changes in your own environment before deploying. No warranty is implied.
> This project is not affiliated with, endorsed by, or sponsored by Plex Inc.

---

## Contents

- [Why a reverse proxy in front of Plex?](#why-a-reverse-proxy-in-front-of-plex)
- [Topology](#topology)
- [Prerequisites](#prerequisites)
- [Benchmark results](#benchmark-results)
  - [LAN results](#lan-results-same-gigabit-segment-02ms-rtt)
  - [WAN results — OVH VPS (~35ms RTT)](#wan-results-ovh-vps-35ms-rtt)
  - [WAN results — site-b, residential (~25ms RTT)](#wan-results-site-b-residential-25ms-rtt)
  - [Parallel thumbnail load test](#parallel-thumbnail-load-test-20-simultaneous-requests)
  - [Direct Plex WAN baseline](#direct-plex-wan-baseline-http-32400-no-nginx-no-tls)
- [nginx config](nginx-config.md)
- [TCP tuning](#tcp-tuning)
- [Plex settings](#plex-settings)
- [Verifying the setup](#verifying-the-setup)
- [Direct Play vs Transcode](#direct-play-vs-transcode)
- [Storage](#storage)
- [Common gotchas](#common-gotchas)
- [Conclusions](#conclusions)

---

## Why a reverse proxy in front of Plex?

Plex already has its own HTTP server, so why add nginx?

- **HTTPS with a cert you control:** nginx handles TLS termination with a
  Let's Encrypt cert on your own domain. Plex's built-in HTTPS uses a self-signed
  cert that causes browser warnings. Plex's `*.plex.direct` wildcard cert is
  provisioned by Plex's servers and [may be subject to rate limits](https://forums.plex.tv/t/certificate-stuck-on-429-rate-limit-request-reset/938830) and outages.
  With nginx you own the cert, the renewal cycle, and the domain. If Plex's cert
  infrastructure has problems, your setup is unaffected.
- **HTTP/2:** nginx speaks HTTP/2 to clients. Plex's own server uses HTTP/1.1.
  In practice the benefit is minimal — curl parallel tests show Plex's HTTP/1.1
  with multiple connections is competitive with nginx's HTTP/2 multiplexing at
  typical homelab scales.
- **Thumbnail caching:** nginx can cache poster and artwork responses in RAM. On
  LAN this adds nothing — Plex's PhotoTranscoder cache is fast enough. Over WAN
  the nginx cache and Plex direct are within a few ms of each other in parallel
  load tests.
- **Compression:** nginx gzips JSON and web assets with configurable levels and
  MIME-type filtering. Plex's own server also gzips responses — so this is not
  a unique nginx advantage. The benefit is control: which types, at what level,
  and without depending on Plex's behavior.
- **Streaming control:** `proxy_buffering off` on media paths means nginx passes
  video chunks straight through to the client instead of accumulating them first,
  eliminating nginx-induced buffering stalls.

---

## Topology

This guide assumes nginx and Plex run on the **same host**:

```
Client → nginx :443 (TLS) → Plex :32400 (localhost)
```

If you have an SNI router or another reverse proxy in front of nginx, that outer
layer should do passthrough. TLS must terminate at nginx for HTTP/2 and the cert
to work correctly.

---

## Prerequisites

- nginx 1.25.1 or newer (for `http2 on;` syntax; older versions use `listen 443 ssl http2;`)
- A valid TLS certificate for your Plex domain (Let's Encrypt recommended)
- Plex Media Server running and accessible on `localhost:32400`
- The nginx cache directory created before first use:

```bash
mkdir -p /var/cache/nginx
chown www-data:www-data /var/cache/nginx   # adjust user for your distro
```

---

## Benchmark results

Baseline: a minimal single-location config. Tuned: the four-location config
from this guide. Tested from a LAN client, a WAN VPS (~35ms RTT), and a residential machine
300 miles away (~25ms RTT, referred to as site-b) against nginx 1.30.

### Measurement method

```bash
curl -w "connect:%{time_connect}s tls:%{time_appconnect}s ttfb:%{time_starttransfer}s total:%{time_total}s\n" \
     -s -o /dev/null https://plex.example.com/web/index.html
```

### A note on LAN testing

LAN results are useful for isolating specific behaviors (cache hit/miss timing,
TLS session resumption) but are not a representative measure of the tuning's
real-world value. On a LAN, clients can reach Plex directly over HTTP on
port 32400, bypassing nginx and TLS entirely (0.3ms vs 13ms). The 13ms TLS
floor that dominates every LAN measurement is an unavoidable constant, not
something the nginx config can affect. **WAN results are the meaningful
comparison** because transfer time and congestion control matter, gzip savings
are real, and there's no HTTP shortcut available.

### LAN results (same gigabit segment, ~0.2ms RTT)

#### UI and API: no measurable difference on LAN

| Endpoint | Baseline TTFB | Tuned TTFB |
|---|---|---|
| `/web/index.html` | 11ms | 10ms |
| `/library/sections` | 11ms | 11ms |

Plex's own response latency sets the floor. TLS on a 0.2ms LAN adds under 1ms
and is not the bottleneck. Neither config can move this floor, and gzip savings
are invisible because gigabit absorbs the extra uncompressed bytes in
microseconds.

#### Thumbnails: negligible difference on LAN

| Request | Baseline | Tuned |
|---|---|---|
| First load (cold) | 10ms | 11ms (MISS) |
| Second request | 11ms (PhotoTranscoder cache) | **10ms (HIT)** |
| Third request | 11ms (PhotoTranscoder cache) | **9ms (HIT)** |

With Plex's PhotoTranscoder cache working, the baseline serves warm thumbnails
nearly as fast as nginx's cache on LAN. Both configs land within 1–2ms of each
other. The nginx cache benefit is a WAN story, not a LAN one.

### WAN results (OVH VPS, ~35ms RTT)

Steady-state numbers (warm TCP connection, TLS session resumed), 20-run averages.
Both TTFB (`time_starttransfer`) and total time (`time_total`) shown:

| Endpoint | Direct HTTP | plex.direct HTTPS | Baseline nginx | Tuned nginx |
|---|---|---|---|---|
| `/web/index.html` TTFB | 70ms | 107ms | 142ms | **108ms** |
| `/web/index.html` Total | 112ms | 147ms | 143ms | **142ms** |
| `/library/sections` TTFB | 73ms | 109ms | 110ms | **108ms** |
| `/library/sections` Total | 73ms | 109ms | 110ms | **108ms** |
| Thumbnail TTFB | 72ms | 108ms | 143ms | **107ms** |
| Thumbnail Total | 73ms | 113ms | 143ms | 119ms |

**UI: nginx tuned and plex.direct are statistically tied on TTFB** (108ms vs
107ms). Total time shows nginx 5ms faster on index.html (142ms vs 147ms). Both
gzip their responses — the advantage is not from gzip but from nginx's TLS
session cache reducing handshake overhead.

**Baseline nginx TTFB ≈ total time** on every endpoint. That's the buffering
artifact: the baseline config's default `proxy_buffering on` causes nginx to
accumulate the full response before sending the first byte. The tuned config
sets `proxy_buffering off` to eliminate this.

**Thumbnail: plex.direct and nginx tuned are effectively tied** on single
requests (108ms vs 119ms total). Once Plex's PhotoTranscoder cache is
functioning, the nginx proxy hop offsets the caching benefit.

**API: all configs are within noise** of each other.

### Parallel thumbnail load test (20 simultaneous requests)

This tests what actually happens when a Plex client opens a library grid. 20
distinct thumbnails fetched in parallel from the VPS, wall-clock time:

| Config | Run 1 | Run 2 | Run 3 | Avg |
|---|---|---|---|---|
| nginx HTTP/2 (cached) | 183ms | 187ms | 180ms | 183ms |
| plex.direct HTTP/1.1 | 162ms | 149ms | 153ms | **155ms** |

plex.direct wins by ~28ms on parallel loads. HTTP/2 multiplexing over a single
connection does not overcome the nginx proxy hop at this scale. Plex's HTTP/1.1
opens parallel connections and finishes first.

### Direct Plex WAN baseline (HTTP :32400, no nginx, no TLS)

Measured from the same VPS with port 32400 temporarily open (20-run averages):

| Endpoint | TTFB | Total |
|---|---|---|
| `/web/index.html` | 70ms | 112ms |
| `/library/sections` | 73ms | 73ms |
| Thumbnail | 72ms | 73ms |

This is the theoretical floor: no proxy overhead, no TLS, same network path.

**nginx+HTTPS TTFB (108ms) vs direct HTTP TTFB (70ms):** the ~38ms gap is
almost entirely the TLS 1.3 handshake (~35ms, one RTT). The proxy hop itself
adds negligible overhead.

**plex.direct HTTPS (107ms) vs direct HTTP (70ms):** the same ~37ms gap —
pure TLS cost. Both nginx and plex.direct gzip their responses; neither has a
compression advantage over the other.

**Thumbnails:** all three HTTPS options (nginx 119ms, plex.direct 113ms, HTTP
73ms) are within a few ms of each other. TLS is the dominant cost; the
proxy hop and caching effects are in the noise.

**The takeaway:** nginx is not adding meaningful latency beyond TLS. If you're
serving over HTTPS (which you should be), the proxy overhead is negligible.

### WAN results (site-b, residential, ~25ms RTT)

20-run averages from a residential machine 300 miles from the Plex server.
Port 32400 is not exposed from site-b, so there is no direct HTTP baseline.
plex.direct and nginx resolve to the same IP — same physical path, different
TLS termination.

| Endpoint | plex.direct HTTPS | Tuned nginx |
|---|---|---|
| `/web/index.html` TTFB | 76ms avg / 63ms median | **63ms avg / 61ms median** |
| `/web/index.html` Total | 92ms avg / 81ms median | **79ms avg / 78ms median** |
| `/library/sections` TTFB | 63ms avg | **62ms avg** |
| Thumbnail TTFB (warm cache) | 66ms avg | **66ms avg** |
| Thumbnail Total (warm cache) | 81ms avg | **77ms avg** |

**plex.direct variance is the headline finding.** nginx TTFB stayed between
52–77ms across all 20 UI runs. plex.direct ranged from 53–208ms, with three
runs spiking above 120ms. The spikes are cold TLS handshakes routing to
different PoPs in Plex's certificate infrastructure — the median is competitive,
but the worst case is 3× nginx's worst case, and you have no control over which
PoP you land on.

**Thumbnail cache cold vs warm.** The first four nginx thumbnail requests
averaged 151ms (cache-cold, fetching from disk and caching the response). Runs
5–20 averaged 66ms, matching plex.direct. plex.direct showed the same TLS
spike pattern on its first and fourth runs (128ms and 121ms).

**Parallel 20-thumbnail wall time:** nginx 104ms, plex.direct 112ms. nginx
wins here, the reverse of the OVH result where plex.direct won by 28ms. The
OVH test had a methodology confound (`curl --parallel` opens 20 HTTP/1.1
connections to plex.direct but only one HTTP/2 connection to nginx), which
likely over-favored plex.direct. At 300 miles with a residential connection,
the HTTP/2 multiplexing advantage is visible.

### What the tuning changes did not affect

- Streaming start time: dominated by Plex's seek-and-respond time, not nginx
- WebSocket reliability: works correctly in both configs
- API TTFB: response payloads too small for gzip to matter

### What the baseline config had wrong

Beyond missing gzip and caching, the baseline had two structural issues:

**File extension media matching.** The baseline matched streaming paths via
`location ~* \.(mp4|mkv|avi|...)$`. Plex streams video at paths like
`/library/parts/12345/1/file.mkv`. These do end in a file extension so the
match technically works, but only for known extensions. The location silently
falls through to the catch-all for anything else. The tuned config uses
`location ~ ^/(library/parts|video)/` which matches all Plex streaming paths
regardless of extension.

**`proxy_set_header` in each location block.** The baseline defined all headers
inside each location block. nginx's inheritance rule means any location that
defines `proxy_set_header` replaces *all* parent-level headers. Not just the
ones it explicitly sets. The baseline happens to work because both locations
define the same header set, but it's fragile: adding a location without the
full header set would silently drop headers for that location. The tuned config
keeps all headers at the server block level.

---

## nginx config

Full config with annotated explanations: [nginx-config.md](nginx-config.md)

Four location blocks — WebSocket, streaming, thumbnail cache, and catch-all — plus
separate include files for TLS settings and gzip. Key points:

- All `proxy_set_header` directives at the server block level (never in location blocks)
- `proxy_buffering off` globally; thumbnail cache location overrides to `on`
- Thumbnail cache key excludes `X-Plex-Token` so all devices share cache entries
- `ssl_session_cache` allows TLS session resumption, eliminating the full handshake on repeat connections

---

## TCP tuning

These kernel settings improve streaming behavior. Apply on the machine running nginx/Plex.

BBR (Bottleneck Bandwidth and Round-trip propagation time) is a congestion control algorithm developed by Google. Unlike older algorithms that back off when they detect packet loss, BBR models the network path to keep throughput high. On WAN paths it delivers noticeably better sustained bitrates, which matters for remote Plex clients.

If your Plex host is a **Proxmox LXC container**: kernel-global settings
(`net.core.default_qdisc`, `net.ipv4.tcp_congestion_control`) must be set on
the Proxmox host. Unprivileged LXC has a read-only `/proc/sys` for these knobs.
The per-socket buffer settings (`rmem_max`, `wmem_max`, `tcp_rmem`, `tcp_wmem`,
`tcp_slow_start_after_idle`, `tcp_fastopen`) can be set inside the container.

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

# Raise socket buffer ceilings for high-bitrate streaming
# tcp_rmem[2] sets the autotuning ceiling (default ~6MB on most distros); rmem_max
# caps applications that set SO_RCVBUF explicitly. Both raised to 16MB for headroom
# on high-bitrate HEVC at higher-latency WAN paths.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

Apply immediately (no reboot): `sudo sysctl --system`

Verify: `sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_slow_start_after_idle net.core.rmem_max`

---

## Plex settings

In Plex web → Settings:

**Settings → Remote Access:**
- Disable relay. It routes connections through Plex's cloud servers when it
  can't confirm a direct path. On LAN this adds unnecessary latency.
- Set LAN Bandwidth to match your network (e.g. `1000 Mbps` for gigabit). A low
  value throttles direct play before nginx sees the traffic.

**Settings → Network:**
- **Custom server access URLs:** add `https://plex.example.com`. Required for
  Plex's DNS rebinding protection to accept requests that arrive with your domain
  as the Host header.
- **List of IP addresses and networks that are allowed without auth:** add your
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
or "Transcode" for every active session. Always verify there rather than assuming.

**Direct Play** means Plex sends the file bytes to the client unmodified. The
client decodes everything locally. This is the ideal path. Zero CPU on the
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
dashboard. If it shows Direct Play, no transcoding is happening regardless
of the browser.

Chrome on Linux and macOS has more limited HEVC support. Those clients are
more likely to trigger a transcode. Check the dashboard rather than assuming.

### Library encoding profile

Files in this test library are encoded with HandBrake using the following settings:

```
-e x265_10bit -q 23 --encoder-preset slow
-E ac3 -B 640 -6 5point1 -R Auto
--audio-lang-list eng,und --first-audio
-X 1920 -Y 1080 --auto-anamorphic --keep-display-aspect
--crop 0:0:0:0 --format av_mkv --align-av
--encopts "bframes=3"
```

Key choices and why they matter for direct play:

- **`x265_10bit`:** HEVC 10-bit. Widely supported by hardware decoders on modern devices. 10-bit reduces banding on gradients with no extra storage cost at typical quality settings.
- **`-q 23`:** RF 23 quality. Good balance of size and quality for 1080p; well within the bitrate range all direct-play clients handle comfortably.
- **`ac3 640 kbps 5.1`:** AC3 (Dolby Digital) at 640 kbps. AC3 is the most compatible surround codec across Plex clients. Virtually every TV, streaming stick, and AV receiver passes it through without transcoding.
- **`--first-audio --audio-lang-list eng,und`:** keeps only the first English or undefined-language track. Drops unwanted tracks, keeps file size predictable, and ensures a single known-good stream is always selected.
- **`-X 1920 -Y 1080`:** caps output at 1080p. Keeps file sizes predictable and ensures hardware decoders that max out at 1080p don't fall back to software decode.
- **`--crop 0:0:0:0`:** explicit no-crop. Prevents HandBrake's auto-detect from cropping incorrectly on sources with inconsistent black bars.
- **`--format av_mkv`:** MKV container. Handles any codec combination, supports chapters and subtitle tracks, and is universally supported by Plex.
- **`--encopts "bframes=3"`:** 3 B-frames. Improves x265 compression efficiency without noticeably increasing decode complexity for hardware decoders.

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

- **`nvenc_h265_10bit`:** uses NVIDIA's hardware H.265 encoder instead of x265. Encodes 5–10× faster at the cost of slightly larger files at the same perceptual quality.
- **`-q 27`:** NVENC's quality scale differs from x265's RF; a higher RF targets similar perceptual quality and bitrate. The right value depends on your GPU and source material. Treat 27 as a starting point and adjust by comparing output.

Container, audio, resolution, crop, and anamorphic settings are identical.
Output files are indistinguishable to Plex clients and direct play the same way.

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

**All direct-play:** `proxy_buffering off` on the streaming path and the TCP
socket buffer tuning in this guide are what matter most. nginx's job is to
stay out of the way.

**Mixed or transcoding clients:** hardware transcoding (Intel QSV, NVIDIA NVENC,
Apple VideoToolbox) on the Plex server becomes the dominant factor. nginx tuning
is secondary to having adequate GPU capacity on the server.

---

## Storage

nginx and TCP tuning have a ceiling: once you're at the TLS handshake floor
(~12.5 ms on a local gigabit network), there's nothing left for nginx to optimize.
The next layer down is storage. It's often the bigger bottleneck.

### NVMe for Plex metadata

Plex's Library directory contains the SQLite database (under
`Plug-in Support/Databases/`), poster and artwork files (under separate
subdirectories), and other metadata. Every library browse and search queries
the database; every poster load reads from disk. These are spread across
different subdirectories but all live under the same Library root. On spinning
disk or even SATA SSD, this becomes the bottleneck well before nginx does.

**Put the entire Plex Library directory on NVMe.** The default locations:

| Platform | Library path |
|---|---|
| Linux | `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/` |
| macOS | `~/Library/Application Support/Plex Media Server/` |
| Windows | `%LOCALAPPDATA%\Plex Media Server\` |
| Docker | wherever you mount `/config` |

This directory does not need to be on the same drive as your media. For
performance, it shouldn't be.

If you can't move the whole directory, symlinking `Plug-in Support/Databases/`
to NVMe gets the highest-impact subset (the SQLite DB files).

Media files themselves do not need NVMe. Sequential read from spinning disk or
NAS is fine for direct play, since the bottleneck there is network, not seek time.

### PlexDBRepair

Plex's SQLite database accumulates fragmentation and bloat over time. Query
times degrade gradually. You won't notice until browsing feels sluggish.
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
Back up the database directory first. The tool is safe, but a backup costs nothing.

---


## Common gotchas

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

---

## Conclusions

After testing baseline nginx, tuned nginx, plex.direct HTTPS, and direct HTTP
across LAN and WAN with sequential and parallel workloads, the results are
clearer than the initial numbers suggested.

**The real reason to use nginx is cert control, not performance.** Plex's
`*.plex.direct` cert is provisioned by Plex's servers, [may be subject to rate limits](https://forums.plex.tv/t/certificate-stuck-on-429-rate-limit-request-reset/938830),
and can leave you with no working remote access while you wait for a reset.
nginx with Let's Encrypt gives you your own cert, your own domain, and no
dependency on Plex's infrastructure.

**nginx and plex.direct HTTPS are effectively tied on median performance, but
plex.direct has an unpredictable tail.** From the OVH VPS (35ms RTT), TTFB is
within 1ms and total time differs by 5ms on index.html — noise margin territory.
From site-b (residential, 25ms RTT, 300 miles away), the median is again
competitive, but plex.direct spiked to 122–208ms on three of 20 UI runs.
Those spikes are cold TLS handshakes routed to distant PoPs in Plex's
certificate infrastructure. nginx is stable across every run because it
terminates TLS on your own server.

**HTTP/2 is a wash at VPS distance; nginx wins at residential distance.**
The OVH parallel thumbnail test showed plex.direct at 155ms vs nginx 183ms —
but `curl --parallel` opens 20 HTTP/1.1 connections to plex.direct and only
one HTTP/2 connection to nginx, over-favoring plex.direct. From site-b, the
same test reversed: nginx 104ms, plex.direct 112ms. The safe read is that
they are close to even at realistic browser concurrency (~6 connections).

**Thumbnail caching is a wash.** With Plex's PhotoTranscoder cache working,
single-request TTFB is tied (108ms vs 107ms) and plex.direct is slightly
faster on total time (113ms vs 119ms). On parallel loads, plex.direct also
wins. The nginx cache only showed a clear advantage when PhotoTranscoder was
broken.

**Streaming is unaffected by nginx tuning.** Start times, buffering behavior,
and playback quality are dominated by Plex's own seek-and-respond time and the
client's decode capability. The nginx config's job on the streaming path is to
stay out of the way: `proxy_buffering off` and large socket buffers ensure it
does.

**The structural fixes matter more than the performance tuning.** The baseline
config had two silent failure modes: file-extension media matching that falls
through for unknown extensions, and `proxy_set_header` in location blocks that
drops parent headers for any location that doesn't repeat them. These don't show
up in benchmarks but cause subtle breakage in real deployments. The tuned config
eliminates both.

### Recommendations checklist

The items below have the most impact, roughly in priority order:

- **NVMe for Plex metadata.** Put the entire Plex Library directory on NVMe
  (database, cache, metadata). Spinning disk or SATA SSD becomes the bottleneck
  well before nginx does. If you can only move one thing, move
  `Plug-in Support/Databases/` — that's the SQLite database, and every library
  browse hits it. If you're stuck on SATA SSD, the nginx thumbnail cache in this
  guide may provide measurable relief on library grid loads — it serves warm
  thumbnails from RAM instead of hitting the disk. That benefit is untested on
  SATA; results would depend on your library size and read patterns.
- **Let the Cache directory be a real directory.** Do not symlink
  `Cache/` to a tmpfs or `/dev/shm` path that disappears on reboot. Plex
  stores `cert-v2.p12` and the PhotoTranscoder cache there. A missing Cache
  directory causes every Plex restart to re-request a cert (triggering
  rate limiting) and disables thumbnail caching silently.
- **Run PlexDBRepair quarterly.** The SQLite database accumulates fragmentation
  over time. [PlexDBRepair](https://github.com/ChuckPa/DBRepair) vacuums and
  reindexes it without touching library data. Run it when browsing feels sluggish.
  Always stop Plex first and back up the database directory.
- **nginx with Let's Encrypt for cert control.** Plex's `*.plex.direct` cert
  is provisioned by Plex's servers and [may be subject to rate limits](https://forums.plex.tv/t/certificate-stuck-on-429-rate-limit-request-reset/938830). If you hit the
  limit, you have no working remote access until Plex resets your quota. Your
  own cert on your own domain has no such dependency.
- **Standardize media encoding for direct play.** Transcoding is the largest
  CPU cost on a Plex server and the biggest source of playback quality loss.
  Encoding to HEVC (x265) + AC3 5.1 at 1080p targets the codec combination
  that direct plays on every common client (Shield, Roku, Apple TV, Plex HTPC,
  Infuse, Chrome on Windows). Verify in the Plex dashboard — not by assumption.
- **Disable Plex relay.** Settings → Remote Access → disable relay. Relay
  routes connections through Plex's cloud servers when it cannot confirm a
  direct path. On a properly port-forwarded setup this only adds latency.
- **LAN subnet auth bypass.** Settings → Network → allowed IPs without auth:
  add your LAN subnet. This skips per-request token validation for local
  clients and is the most visible TTFB improvement for LAN API calls.
- **BBR congestion control on the host.** Set `net.ipv4.tcp_congestion_control
  = bbr` and `net.core.default_qdisc = fq` on the machine running Plex (or
  on the Proxmox host if Plex is in an LXC container). BBR maintains throughput
  on WAN paths where packet loss would cause older algorithms to back off.
- **`proxy_buffering off` on streaming paths.** nginx must not buffer video
  chunks. The tuned config sets this at the server level and explicitly
  overrides it only for the thumbnail cache location.
- **Thumbnail cache key excludes the token.** The default nginx cache key
  includes the full query string — including `X-Plex-Token`. Every device gets
  its own cache entry for the same poster. The fix (`$host$uri$arg_url
  $arg_width$arg_height`) shares entries across devices for the same image.

---

Built with the assistance of [Claude Code](https://claude.ai/code).
