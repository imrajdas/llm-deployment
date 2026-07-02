#!/usr/bin/env bash
# Build and start the compose stack. Use this on a JarvisLabs VM, where Docker is available.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/render-docker-env.sh"
cd "$ROOT/docker"
docker compose up -d --build
echo "Streamlit publishes on the port in manifest.yaml (default 6006)."
echo "On a VM, allow that port: sudo ufw allow 6006/tcp"
