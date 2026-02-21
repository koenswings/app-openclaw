#!/bin/sh
set -e

[ -f "/run/secrets/anthropic_api_key" ] && export ANTHROPIC_API_KEY=$(cat /run/secrets/anthropic_api_key | tr -d '\n')
[ -f "/run/secrets/openclaw_gateway_token" ] && export OPENCLAW_GATEWAY_TOKEN=$(cat /run/secrets/openclaw_gateway_token | tr -d '\n')

exec "$@"
