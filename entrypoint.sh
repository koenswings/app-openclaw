#!/bin/sh
set -e

[ -f "/run/secrets/anthropic_api_key" ] && export ANTHROPIC_API_KEY=$(cat /run/secrets/anthropic_api_key | tr -d '\n')
[ -f "/run/secrets/openclaw_gateway_token" ] && export OPENCLAW_GATEWAY_TOKEN=$(cat /run/secrets/openclaw_gateway_token | tr -d '\n')

# Write token for CLI commands (docker exec)
[ -n "$OPENCLAW_GATEWAY_TOKEN" ] && echo "OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" > /root/.openclaw/.gateway-env

# Start a TCP proxy on 0.0.0.0:18790 that forwards to OpenClaw's loopback 127.0.0.1:18789.
# This makes OpenClaw reachable from the Docker bridge network (Tailscale, other containers)
# without requiring shared network namespaces.
node -e "
const net = require('net');
net.createServer(client => {
  const upstream = net.connect(18789, '127.0.0.1');
  client.pipe(upstream);
  upstream.pipe(client);
  upstream.on('error', () => client.destroy());
  client.on('error', () => upstream.destroy());
}).listen(18790, '0.0.0.0');
" &

exec "$@"
