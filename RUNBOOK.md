# Runbook: nginx reverse proxy for Plex

← [Back to README](README.md)

Operational procedures for deploying, verifying, maintaining, and rolling back the
setup in this guide. For rationale and benchmark data, see the README. All commands
assume Debian/Ubuntu and `plex.example.com` as your domain. Replace with your own.

---

## Contents

- [Prerequisites](#prerequisites)
- [1. Place the nginx config](#1-place-the-nginx-config)
- [2. TLS certificate (Let's Encrypt)](#2-tls-certificate-lets-encrypt)
- [3. Apply kernel TCP settings](#3-apply-kernel-tcp-settings)
- [4. Plex settings](#4-plex-settings)
- [5. Verify the setup](#5-verify-the-setup)
- [6. Maintenance](#6-maintenance)
- [7. Rollback](#7-rollback)
- [8. Troubleshooting](#8-troubleshooting)

---

## Prerequisites

Before starting, confirm:

- **nginx ≥ 1.25.1**: the `http2 on;` directive requires it. Check with `nginx -v`.
  Older versions use `listen 443 ssl http2;` in the server block instead.
- **Plex Media Server** running and reachable locally: `curl -s http://127.0.0.1:32400/identity`
  should return an XML response.
- **A public domain** pointing to your server. Let's Encrypt cannot issue certs for
  `.lan` or `.local` hostnames. A domain with split DNS (public A record + internal
  override) works fine.
- **Port 443 open** in your firewall and forwarded from your router.

Create the nginx cache directory before nginx starts. nginx will not create it:

```bash
sudo mkdir -p /var/cache/nginx
sudo chown www-data:www-data /var/cache/nginx   # adjust user for your distro
```

To find the correct nginx worker user: `grep '^user' /etc/nginx/nginx.conf`

---

## 1. Place the nginx config

The repo contains two ready-to-use config files under `configs/`:

| File | Use for |
|---|---|
| `configs/optimized.conf` | Production: full four-location config with caching |
| `configs/original.conf` | Baseline: minimal single-location config (for benchmarking comparison) |

The `http {}` block additions (cache zone, WebSocket map, proxy defaults) go in
`/etc/nginx/nginx.conf` or a file it includes. See [nginx-config.md](nginx-config.md)
for the full annotated config.

The ssl and gzip includes go in `/etc/nginx/include/`:

```bash
sudo mkdir -p /etc/nginx/include
# place include/ssl.conf and include/gzip.conf from nginx-config.md
```

### Deploying with swap.sh (remote host)

`swap.sh` copies a config from `configs/` to a remote nginx host over SSH and
reloads nginx:

```bash
# Set your nginx host (or export NGINX_HOST=user@your-server before running)
# Edit NGINX_HOST in swap.sh, or:
export NGINX_HOST=user@your-server

./swap.sh optimized   # deploy the tuned config
./swap.sh original    # revert to the baseline
```

`swap.sh` runs `nginx -t` before reloading. If the test fails, it stops and the
active config is unchanged.

### Deploying manually (local host)

```bash
sudo cp configs/optimized.conf /etc/nginx/sites-available/plex.conf
sudo ln -sf /etc/nginx/sites-available/plex.conf /etc/nginx/sites-enabled/plex.conf
sudo nginx -t && sudo systemctl reload nginx
```

Expected output from `nginx -t`:
```
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

If this fails: check that the `include/ssl.conf` and `include/gzip.conf` paths
exist, and that `/var/cache/nginx` exists with correct ownership.

---

## 2. TLS certificate (Let's Encrypt)

Install certbot and the nginx plugin if not already present:

```bash
sudo apt install certbot python3-certbot-nginx
```

Obtain a certificate. HTTP-01 challenge requires port 80 to be reachable from the
internet while certbot runs:

```bash
sudo certbot --nginx -d plex.example.com
```

Certbot will update the nginx config with cert paths automatically. After it runs,
verify the paths in your config match what certbot installed:
`/etc/letsencrypt/live/plex.example.com/fullchain.pem` and `privkey.pem`.

Certbot installs a systemd timer that renews certs automatically. Verify it is
active:

```bash
sudo systemctl status certbot.timer
```

Test that renewal will succeed (dry run, no cert is actually renewed):

```bash
sudo certbot renew --dry-run
```

If the dry run fails, fix it now. A renewal failure 30 days before expiry means
no working remote access until it is resolved.

---

## 3. Apply kernel TCP settings

Create `/etc/sysctl.d/99-plex-perf.conf`:

```ini
# BBR congestion control — better throughput on WAN paths
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Prevent TCP window reset after idle gaps (causes buffer spinner on resume)
net.ipv4.tcp_slow_start_after_idle = 0

# TCP Fast Open — saves one RTT on repeat connections where supported
net.ipv4.tcp_fastopen = 3

# Raise socket buffer ceilings for high-bitrate streaming
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

Apply without a reboot:

```bash
sudo sysctl --system
```

Verify the key settings took effect:

```bash
sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_slow_start_after_idle net.core.rmem_max
```

Expected output:
```
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = 16777216
```

### Proxmox LXC caveat

If Plex runs inside an **unprivileged LXC container**, `net.core.default_qdisc`
and `net.ipv4.tcp_congestion_control` must be set on the **Proxmox host**, not
inside the container. The container has a read-only `/proc/sys` for these knobs.

The per-socket buffer settings (`rmem_max`, `wmem_max`, `tcp_rmem`, `tcp_wmem`,
`tcp_slow_start_after_idle`, `tcp_fastopen`) can be set inside the container.

---

## 4. Plex settings

In Plex web → Settings:

**Remote Access:**
- Disable relay.

**Network:**
- **Custom server access URLs:** add `https://plex.example.com`. Required for
  Plex's DNS rebinding protection to accept your domain as the Host header.
- **List of IP addresses allowed without auth:** add your LAN subnet
  (e.g. `192.168.1.0/24`). This skips per-request token validation for local
  clients.
- **LAN Bandwidth:** set to match your network (e.g. `1000 Mbps` for gigabit).
  A low value throttles direct play before nginx touches the traffic.

After adding the custom URL, confirm Plex shows it as reachable in Remote Access
settings. If it shows "Not available outside your network," double-check port
forwarding and the firewall.

---

## 5. Verify the setup

Run these checks after first deploy and after any config change.

```bash
# 1. Config is syntactically valid
sudo nginx -t

# 2. HTTP/2 is active
curl -sI --http2 https://plex.example.com/web/index.html | head -1
# → HTTP/2 200

# 3. gzip active on UI responses
curl -sI -H 'Accept-Encoding: gzip' https://plex.example.com/web/index.html | grep content-encoding
# → content-encoding: gzip

# 4. Thumbnail cache working (run the same URL twice with any valid token)
THUMB="https://plex.example.com/photo/:/transcode?url=LIBRARY_URL&width=150&height=225&X-Plex-Token=TOKEN"
curl -sI "$THUMB" | grep x-cache-status
# → x-cache-status: MISS
curl -sI "$THUMB" | grep x-cache-status
# → x-cache-status: HIT

# 5. Cross-device cache sharing (different token, same image URL → still HIT)
THUMB2="https://plex.example.com/photo/:/transcode?url=LIBRARY_URL&width=150&height=225&X-Plex-Token=DIFFERENT_TOKEN"
curl -sI "$THUMB2" | grep x-cache-status
# → x-cache-status: HIT

# 6. TTFB baseline (run from outside your LAN for a representative number)
curl -w "TTFB: %{time_starttransfer}s  Total: %{time_total}s\n" \
     -o /dev/null -s https://plex.example.com/web/index.html
```

If step 5 returns MISS instead of HIT, the cache key still includes the token.
Verify the `proxy_cache_key` directive in the `/photo/:/` location matches
`"$host$uri$arg_url$arg_width$arg_height"` (no `$query_string` or `$args`).

---

## 6. Maintenance

### Quarterly: PlexDBRepair

The Plex SQLite database accumulates fragmentation. Run when browsing feels
sluggish, or on a quarterly schedule.

```bash
# Stop Plex first — never run against a live database
sudo systemctl stop plexmediaserver

# Back up the database directory first
PLEX_DB="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases"
sudo cp -r "$PLEX_DB" "${PLEX_DB}.bak-$(date +%Y%m%d)"

# Download and run
wget https://github.com/ChuckPa/DBRepair/releases/latest/download/DBRepair.sh
chmod +x DBRepair.sh
sudo ./DBRepair.sh

# Restart when done
sudo systemctl start plexmediaserver
```

### Certificate renewal

Certbot's systemd timer handles this automatically. Check renewal logs if you
suspect a problem:

```bash
sudo journalctl -u certbot --since "30 days ago" | tail -20
```

After any cert renewal, verify nginx picked up the new cert:

```bash
echo | openssl s_client -connect plex.example.com:443 2>/dev/null | openssl x509 -noout -dates
```

### nginx cache management

The cache at `/var/cache/nginx` is self-managing. `inactive=60m` and
`max_size=512m` in the `proxy_cache_path` directive bound its size and age. No
manual pruning needed. To clear it entirely (e.g. after a library refresh):

```bash
sudo rm -rf /var/cache/nginx/*
sudo systemctl reload nginx
```

---

## 7. Rollback

If the nginx config causes problems, revert to direct Plex access:

```bash
# Option A: disable the nginx site and reload
sudo rm /etc/nginx/sites-enabled/plex.conf
sudo systemctl reload nginx
```

LAN clients can reach Plex directly on `http://PLEX_HOST_IP:32400`. Remote
clients fall back to plex.direct HTTPS automatically once nginx is no longer
intercepting.

```bash
# Option B: swap back to the baseline config (if using swap.sh)
./swap.sh original
```

```bash
# Option C: stop nginx entirely (leaves Plex accessible on :32400 locally)
sudo systemctl stop nginx
```

If you need to re-enable nginx after testing:

```bash
sudo ln -sf /etc/nginx/sites-available/plex.conf /etc/nginx/sites-enabled/plex.conf
sudo nginx -t && sudo systemctl reload nginx
```

---

## 8. Troubleshooting

### WebSocket disconnects / Plex web client loses real-time updates

**Symptom:** Library updates don't appear without a page reload; activity spinner
hangs.

**Check:** Ensure the WebSocket map in `nginx.conf` uses `""` (empty string) for
the non-upgrade case, not `"close"`:

```nginx
map $http_upgrade $connection_upgrade {
    default  "upgrade";
    ""       "";      # ← must be empty string, not "close"
}
```

Using `"close"` sends `Connection: close` to Plex on every non-WebSocket request,
breaking upstream keepalive connections.

---

### Thumbnail cache never hits (always MISS)

**Cause 1:** `proxy_buffering off` at the server level is overriding the thumbnail
location. The thumbnail location must explicitly re-enable it:

```nginx
location /photo/:/ {
    proxy_buffering on;   # required — cache writes need buffering
    ...
}
```

**Cause 2:** The cache key includes `X-Plex-Token`. Each device gets its own entry.
Fix: use `$host$uri$arg_url$arg_width$arg_height` as the key.

**Cause 3:** `/var/cache/nginx` does not exist or has wrong ownership. Fix:

```bash
sudo mkdir -p /var/cache/nginx
sudo chown www-data:www-data /var/cache/nginx
```

---

### Missing headers on some paths (401 errors, Plex rejects requests)

**Cause:** A location block defines `proxy_set_header` directives. nginx's
inheritance rule: any `proxy_set_header` in a child block replaces *all*
parent-level headers for that location, including headers the location didn't
explicitly set.

**Fix:** Move all `proxy_set_header` directives to the server block. Location
blocks should not define any.

---

### nginx -t fails after Let's Encrypt renewal

Certbot may write cert paths that don't match the `ssl_certificate` directives in
your config. Check:

```bash
sudo nginx -t 2>&1
ls -la /etc/letsencrypt/live/plex.example.com/
```

Update the cert paths in your config to match what certbot installed, then:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

### Plex shows "Not available outside your network" after adding custom URL

- Confirm port 443 is open in your firewall (`sudo ufw status` or `iptables -L`).
- Confirm your router is forwarding port 443 to the Plex/nginx host.
- Confirm the `server_name` in the nginx config matches the domain exactly.
- Confirm the domain's DNS A record resolves to your external IP:
  `dig +short plex.example.com`

---

### BBR not active after applying sysctl

On Proxmox with LXC: kernel-global sysctl knobs must be set on the **host**, not
inside the container. SSH to the Proxmox host and apply `net.core.default_qdisc`
and `net.ipv4.tcp_congestion_control` there.

Verify BBR is available on the kernel:

```bash
modprobe tcp_bbr
sysctl net.ipv4.tcp_available_congestion_control
# should include "bbr" in the output
```

---

### Streaming triggers buffer spinner after pausing

**Cause:** `tcp_slow_start_after_idle` is not set. After ~1 second of idle, the
kernel resets the congestion window and nginx rebuilds it on resume.

**Fix:** Confirm `net.ipv4.tcp_slow_start_after_idle = 0` is active:

```bash
sysctl net.ipv4.tcp_slow_start_after_idle
```

If it shows `1`, the sysctl file did not apply. On LXC, confirm this setting is
being applied inside the container (it is a per-socket setting, not a kernel-global
one, so the container can set it).
