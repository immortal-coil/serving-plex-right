# nginx config

← [Back to README](README.md)

### nginx.conf additions to the `http {}` block

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

### Plex vhost: `/etc/nginx/sites-enabled/plex.conf`

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
    proxy_set_header X-Forwarded-For   $remote_addr;
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
same poster art. They never share.

The fix is to build the key from only the parameters that identify the image:
`$arg_url`, `$arg_width`, `$arg_height`. This excludes the token while keeping
the parts that distinguish one image from another.

Do not use `"$host$uri"` alone (path only, no query string). All thumbnail
requests share the same path `/photo/:/transcode`, so that key would collapse
every image to a single cache entry and serve one image for everything.

**`proxy_ignore_headers Cache-Control Expires`**

Plex sends `Cache-Control: no-cache` on `/photo/:/` responses. By default nginx
respects this and skips the cache, making every thumbnail request a cache miss.
This directive tells nginx to ignore Plex's Cache-Control and apply your own TTL.

It's safe to ignore Cache-Control on thumbnails. Poster art doesn't change
mid-session. Don't use this on the UI or API locations where Plex's cache
headers are intentional.
