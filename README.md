# OpenClaw on Raspberry Pi

Self-hosted AI development assistant running on the Pi, accessible from anywhere on the tailnet via Tailscale HTTPS. Manages multiple codebases as isolated agents, each with its own workspace.

## What this sets up

- **OpenClaw gateway** — WebSocket-based AI assistant server (Claude Sonnet via Anthropic API)
- **Tailscale** — Provides a stable `https://openclaw-pi.tail2d60.ts.net` URL accessible from any device on the tailnet, with a valid TLS certificate (no self-signed certs, no port forwarding)
- **Multi-agent routing** — Each codebase (`engine`, `console-ui`, etc.) gets its own isolated agent with its own workspace

## Architecture

```
Browser (on tailnet)
  │
  │  HTTPS 443
  ▼
Tailscale container (openclaw-pi.tail2d60.ts.net)
  │
  │  HTTP → 172.18.0.1:18789  (Docker bridge gateway)
  ▼
Host port 18789
  │
  │  NAT → container port 18790
  ▼
OpenClaw container (openclaw-gateway)
  │  TCP proxy (entrypoint.sh) listening on 0.0.0.0:18790
  │  forwards to loopback
  ▼
OpenClaw gateway  127.0.0.1:18789
```

### Why the TCP proxy?

OpenClaw's gateway only binds to `127.0.0.1:18789` (loopback). Docker's port NAT routes to the bridge network, not the loopback inside the container. A small Node.js TCP proxy in `entrypoint.sh` bridges the gap: it listens on `0.0.0.0:18790` inside the container and pipes traffic to the loopback. This survives container restarts (unlike the alternative of sharing network namespaces with a sidecar proxy).

### Why `172.18.0.1` instead of the container hostname?

The Tailscale container overrides DNS with Tailscale's own resolver (`100.100.100.100`), which doesn't know about Docker's internal hostnames. `172.18.0.1` is the Docker bridge gateway — the host's interface on the `proxy-net` network — and is always reachable from any container on that network at that fixed address.

---

## Directory structure

```
/home/pi/openclaw/
├── compose.yaml          # Docker Compose: openclaw + tailscale services
├── entrypoint.sh         # Loads secrets; starts TCP proxy; execs OpenClaw
├── Caddyfile             # Not currently used (kept for reference)
├── serve.json            # Not currently used (Tailscale serve set via CLI)
├── secrets/
│   ├── anthropic_api_key.txt      # Anthropic API key (chmod 600)
│   └── openclaw_gateway_token.txt # Gateway token for remote CLI auth (chmod 600)
└── app-disk/             # App Disk template (see App Disk section below)
```

OpenClaw's persistent state (config, agent memory, device tokens) lives in a Docker volume:

```
Docker volume: openclaw_openclaw-data  →  /root/.openclaw  inside the container
```

The key config file inside that volume:

```
/root/.openclaw/openclaw.json
```

On the host this is at:

```
/var/lib/docker/volumes/openclaw_openclaw-data/_data/openclaw.json
```

---

## openclaw.json (agent + gateway config)

```json
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
  },
  "gateway": {
    "remote": {
      "token": "<your-gateway-token>"
    },
    "trustedProxies": ["127.0.0.1"]
  }
}
```

- **`agents.defaults.model.primary`** — Model used for all agents. Matches `anthropic/` prefix + model ID.
- **`agents.list`** — Each entry defines one agent. `id` is used for routing in the UI. `workspace` is the path inside the container (mapped from `/home/pi/projects` on the host). `sandbox.mode: "all"` means Docker sandbox is enabled.
- **`gateway.remote.token`** — Used for remote CLI calls (e.g. `openclaw health` pointed at this gateway from another machine). **Not** used for browser auth — that uses device pairing (see below).
- **`gateway.trustedProxies`** — Tells OpenClaw to trust `X-Forwarded-For` from `127.0.0.1` (the TCP proxy). Without this, all requests look like they come from loopback and Tailscale's forwarded IP is ignored.

The workspace volume mount: `/home/pi/projects` on the host → `/home/node/workspace` in the container. So each codebase at `/home/pi/projects/<name>` is available in the container as `/home/node/workspace/<name>`.

To edit openclaw.json:

```bash
sudo nano /var/lib/docker/volumes/openclaw_openclaw-data/_data/openclaw.json
sudo docker restart openclaw-gateway
```

---

## Initial setup (from scratch)

### 1. Secrets

```bash
# Anthropic API key
echo -n 'sk-ant-api03-...' | sudo tee /home/pi/openclaw/secrets/anthropic_api_key.txt
sudo chmod 600 /home/pi/openclaw/secrets/anthropic_api_key.txt

# Gateway token (for remote CLI use — generate a random one)
openssl rand -base64 32 | sudo tee /home/pi/openclaw/secrets/openclaw_gateway_token.txt
sudo chmod 600 /home/pi/openclaw/secrets/openclaw_gateway_token.txt
```

### 2. Start the stack

```bash
cd /home/pi/openclaw
sudo docker compose up -d
```

### 3. Configure Tailscale Serve

This only needs to be done once. The config persists in the `tailscale-state` volume.

```bash
sudo docker exec tailscale tailscale serve --bg --https=443 http://172.18.0.1:18789
```

Verify:

```bash
sudo docker exec tailscale tailscale serve status
# Expected:
# https://openclaw-pi.tail2d60.ts.net (tailnet only)
# |-- / proxy http://172.18.0.1:18789
```

### 4. Write openclaw.json

```bash
sudo tee /var/lib/docker/volumes/openclaw_openclaw-data/_data/openclaw.json > /dev/null << 'EOF'
{
  "agents": {
    "defaults": {
      "model": { "primary": "anthropic/claude-sonnet-4-6" }
    },
    "list": [
      {
        "id": "engine",
        "workspace": "/home/node/workspace/engine",
        "sandbox": { "mode": "all", "scope": "agent" }
      }
    ]
  },
  "gateway": {
    "remote": { "token": "<contents of secrets/openclaw_gateway_token.txt>" },
    "trustedProxies": ["127.0.0.1"]
  }
}
EOF
sudo docker restart openclaw-gateway
```

---

## Accessing the UI

### URL

```
https://openclaw-pi.tail2d60.ts.net
```

Your device must be on the tailnet (logged in to Tailscale). The URL is **not** publicly accessible — `AllowFunnel` is off.

### First-time browser pairing

OpenClaw uses per-device pairing to authorise browsers. On first visit, the UI will show **"disconnected (1008): pairing required"**. This is expected — the browser has submitted a pairing request in the background.

**Approve it from the Pi:**

```bash
# List pending requests
sudo docker exec openclaw-gateway node dist/index.js devices list

# Approve the request (use the Request ID from the output)
sudo docker exec openclaw-gateway node dist/index.js devices approve <request-id>
```

After approval the browser reconnects automatically. The pairing token is stored in the browser — future visits work without re-pairing.

Each new browser or device needs its own approval. To revoke a device:

```bash
sudo docker exec openclaw-gateway node dist/index.js devices revoke <device-id>
```

---

## Adding a codebase

1. Clone the repo to `/home/pi/projects/<name>` on the Pi.
2. Add an agent entry to `openclaw.json`:

```json
{
  "id": "my-new-project",
  "workspace": "/home/node/workspace/my-new-project",
  "sandbox": { "mode": "all", "scope": "agent" }
}
```

3. Optionally create `/home/pi/projects/<name>/AGENTS.md` with codebase-specific instructions for the agent (tech stack, key commands, safety rules, etc.).
4. Restart: `sudo docker restart openclaw-gateway`

---

## Day-to-day operations

```bash
# View logs
sudo docker logs -f openclaw-gateway

# Restart OpenClaw (e.g. after editing openclaw.json)
sudo docker restart openclaw-gateway

# Restart everything
cd /home/pi/openclaw && sudo docker compose restart

# Update to latest OpenClaw image
cd /home/pi/openclaw && sudo docker compose pull && sudo docker compose up -d

# Check gateway health
sudo docker exec openclaw-gateway node dist/index.js health

# List paired devices
sudo docker exec openclaw-gateway node dist/index.js devices list
```

---

## Tailscale Serve (reference)

Tailscale Serve config is set via the CLI and persists in the `tailscale-state` Docker volume — it is **not** loaded from `serve.json` (that file is kept for reference only).

```bash
# Check current config
sudo docker exec tailscale tailscale serve status

# Reset and reconfigure (if something breaks)
sudo docker exec tailscale tailscale serve reset
sudo docker exec tailscale tailscale serve --bg --https=443 http://172.18.0.1:18789
```

If Tailscale needs to re-authenticate (auth key expired):

```bash
sudo docker exec tailscale tailscale up --authkey=<new-key>
```

---

## App Disk (bonus)

The `app-disk/` directory contains a template for packaging this entire setup as an Engine App Disk — a USB/SSD that auto-loads when inserted into any Engine Pi, turning it into an AI development machine.

See `app-disk/META.yaml` for the disk metadata and `build-app-disk.sh` for the script that formats a drive and writes the template.

---

## VS Code & Claude Code Integration

This directory is configured as a VS Code Remote-SSH project with a dedicated Claude Code session.

Opening `/home/pi/openclaw` in VS Code via Remote-SSH will automatically attach to (or create) the `claude-openclaw` tmux session. Mouse scrolling is enabled automatically. Claude's memory for this project is stored at:

```
~/.claude/projects/-home-pi-openclaw/memory/
```

This isolates Claude's context for OpenClaw operations from other projects on the same device.

**Per-project session convention:**

Each project on this Pi uses a uniquely named tmux session so VS Code always connects to the correct Claude context:

| Project | tmux session | Claude memory |
|---------|-------------|---------------|
| `/home/pi/openclaw` | `claude-openclaw` | `~/.claude/projects/-home-pi-openclaw/` |
| `/home/pi/projects/engine` | `claude-engine` | `~/.claude/projects/-home-pi-projects-engine/` |
| `/home/pi/projects/idea-proposal` | `claude-idea` | `~/.claude/projects/-home-pi-projects-idea-proposal/` |

The session name and memory path are configured in `.vscode/settings.json` in each project.

---

## Troubleshooting

**"pairing required" in the UI**
Normal on first visit. Approve the pending request via `devices approve` (see above).

**"device_token_mismatch"**
The browser has a stale token from a previous session (e.g. after a full data reset). Clear site data for `openclaw-pi.tail2d60.ts.net` in browser DevTools → Application → Storage, then reload. A new pairing request will be submitted.

**502 Bad Gateway**
The TCP proxy in the container hasn't started yet, or OpenClaw is still initialising (it takes ~15–20s). Wait and reload. If persistent, check logs: `sudo docker logs openclaw-gateway`.

**Tailscale not connecting**
```bash
sudo docker exec tailscale tailscale status
sudo docker logs tailscale
```
If the auth key has expired, generate a new one at https://login.tailscale.com/admin/settings/keys and update `TS_AUTHKEY` in `compose.yaml`.

**openclaw.json changes not taking effect**
The file is read at startup. Always restart after editing: `sudo docker restart openclaw-gateway`.
