#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
docker compose logs cloudflared 2>&1 \
  | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' \
  | tail -n 1
