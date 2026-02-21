#!/usr/bin/env bash
# build-app-disk.sh — Write the OpenClaw App Disk template to a physical USB/SSD
#
# Usage: sudo ./build-app-disk.sh --device /dev/sdb [--hostname openclaw-dev] [--api-key sk-ant-...]
#
# The disk will be formatted as ext4, the App Disk structure written, and
# a META.yaml created. On first insert into an Engine, it auto-starts OpenClaw + Tailscale.

set -e

DEVICE=""
HOSTNAME_VAL="openclaw-dev"
API_KEY=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/app-disk"

usage() {
  echo "Usage: sudo $0 --device <device> [--hostname <name>] [--api-key <key>]"
  echo ""
  echo "  --device    Block device to write to, e.g. /dev/sdb  (WILL BE FORMATTED)"
  echo "  --hostname  Tailscale hostname for this disk (default: openclaw-dev)"
  echo "  --api-key   Anthropic API key (can also be entered interactively)"
  echo ""
  echo "Example:"
  echo "  sudo $0 --device /dev/sdb --hostname openclaw-pi --api-key sk-ant-..."
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --device)   DEVICE="$2";       shift 2 ;;
    --hostname) HOSTNAME_VAL="$2"; shift 2 ;;
    --api-key)  API_KEY="$2";      shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$DEVICE" ]] && usage
[[ "$(id -u)" -ne 0 ]] && { echo "Run as root (sudo)"; exit 1; }
[[ ! -b "$DEVICE" ]] && { echo "Error: $DEVICE is not a block device"; exit 1; }

echo "WARNING: This will format $DEVICE as ext4 and erase all data on it."
read -rp "Type YES to continue: " confirm
[[ "$confirm" != "YES" ]] && { echo "Aborted."; exit 1; }

if [[ -z "$API_KEY" ]]; then
  read -rsp "Anthropic API key (sk-ant-...): " API_KEY
  echo
fi

echo "→ Formatting $DEVICE as ext4..."
mkfs.ext4 -L "OpenClaw" "$DEVICE"

MOUNT_POINT="/mnt/openclaw-build-$$"
mkdir -p "$MOUNT_POINT"
mount "$DEVICE" "$MOUNT_POINT"
trap "umount '$MOUNT_POINT' 2>/dev/null; rmdir '$MOUNT_POINT' 2>/dev/null" EXIT

echo "→ Copying App Disk template..."
cp -r "$TEMPLATE_DIR/." "$MOUNT_POINT/"

ENV_FILE="$MOUNT_POINT/instances/openclaw-dev/.env"
cp "$MOUNT_POINT/instances/openclaw-dev/.env.template" "$ENV_FILE"
sed -i "s/^hostname=.*/hostname=$HOSTNAME_VAL/" "$ENV_FILE"

read -rsp "Tailscale auth key (leave blank to fill in later): " TS_KEY
echo
if [[ -n "$TS_KEY" ]]; then
  sed -i "s/^ts_authkey=.*/ts_authkey=$TS_KEY/" "$ENV_FILE"
fi

SECRETS_DIR="$MOUNT_POINT/instances/openclaw-dev/secrets"
echo -n "$API_KEY" > "$SECRETS_DIR/anthropic_api_key.txt"
chmod 600 "$SECRETS_DIR/anthropic_api_key.txt"

openssl rand -base64 48 > "$SECRETS_DIR/openclaw_gateway_token.txt"
chmod 600 "$SECRETS_DIR/openclaw_gateway_token.txt"

chmod +x "$MOUNT_POINT/instances/openclaw-dev/entrypoint.sh"

DISK_ID="openclaw-$(openssl rand -hex 8)"
TIMESTAMP_MS=$(date +%s%3N)
cat > "$MOUNT_POINT/META.yaml" << YAML
diskId: $DISK_ID
diskName: OpenClaw Dev Assistant
created: $TIMESTAMP_MS
lastDocked: $TIMESTAMP_MS
YAML

# Write multi-agent config (openclaw.json) to the data directory (persisted on disk)
OPENCLAW_DATA="$MOUNT_POINT/instances/openclaw-dev/data/openclaw"
mkdir -p "$OPENCLAW_DATA"
cat > "$OPENCLAW_DATA/openclaw.json" << 'JSONEOF'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-6"
      }
    },
    "list": [
      {
        "id": "engine",
        "workspace": "/home/node/workspace/engine",
        "sandbox": { "mode": "all", "scope": "agent" }
      },
      {
        "id": "console-ui",
        "workspace": "/home/node/workspace/console-ui",
        "sandbox": { "mode": "all", "scope": "agent" }
      }
    ]
  }
}
JSONEOF

echo ""
echo "App Disk written to $DEVICE"
echo "  Disk ID:   $DISK_ID"
echo "  Hostname:  $HOSTNAME_VAL"
echo ""
echo "Next steps:"
echo "  1. Eject: umount $DEVICE"
echo "  2. Insert into any Engine (Appdocker Pi)"
echo "  3. OpenClaw + Tailscale auto-start"
echo "  4. Access via https://$HOSTNAME_VAL.<tailnet>.ts.net"
echo "     or locally at http://<engine-ip>:18789"
