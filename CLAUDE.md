# OpenClaw Project Guide

## Overview
This directory contains the self-hosted OpenClaw AI assistant platform running on this Raspberry Pi. OpenClaw manages multiple AI agents, each tied to a project workspace, and is the primary interface for managing the IDEA virtual company.

## Key Files
- **[README.md](README.md)**: Full setup, architecture, and operations reference.
- **`compose.yaml`**: Docker Compose stack (OpenClaw gateway + Tailscale).
- **`entrypoint.sh`**: Container entrypoint — loads secrets, starts TCP proxy, launches OpenClaw.
- **`secrets/`**: API keys and tokens. Never committed to git.

## Key Commands
- `sudo docker compose up -d`: Start the stack.
- `sudo docker compose up -d --force-recreate openclaw`: Restart OpenClaw after config changes.
- `sudo docker logs -f openclaw-gateway`: Tail logs.
- `sudo docker exec openclaw-gateway node dist/index.js devices list`: List paired browsers.
- `sudo docker exec openclaw-gateway node dist/index.js devices approve <id>`: Approve a browser.

## Critical Setup Note
The OpenClaw container must have the Docker socket and CLI mounted or the embedded Claude Code agent will hang:
```yaml
- /var/run/docker.sock:/var/run/docker.sock
- /usr/bin/docker:/usr/bin/docker:ro
```
