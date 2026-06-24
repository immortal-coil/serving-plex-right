#!/usr/bin/env bash
# Usage: ./swap.sh original | optimized
set -euo pipefail

NGINX_HOST="${NGINX_HOST:-user@192.168.1.x}"  # set via env or edit directly
REMOTE_CONF="/etc/nginx/sites-enabled/plex.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -ne 1 ]] || [[ "$1" != "original" && "$1" != "optimized" ]]; then
    echo "Usage: $0 original|optimized"
    exit 1
fi

CONFIG="$SCRIPT_DIR/configs/$1.conf"

echo "==> Deploying $1..."
scp "$CONFIG" "$NGINX_HOST:/tmp/plex.conf"
ssh "$NGINX_HOST" "sudo cp /tmp/plex.conf $REMOTE_CONF && sudo nginx -t && sudo systemctl reload nginx"
echo "==> Active config: $1"
