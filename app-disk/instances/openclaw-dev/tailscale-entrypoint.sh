#!/bin/sh
set -e

# Read Tailscale auth key from Docker secret file (preferred over .env)
if [ -f "/run/secrets/tailscale_authkey" ]; then
  export TS_AUTHKEY=$(cat /run/secrets/tailscale_authkey | tr -d '\n')
fi

exec /usr/local/bin/containerboot "$@"
