#!/usr/bin/env bash
# Runs on a JarvisLabs instance at launch and resume, when this script is registered.
# Register it from your laptop with: bash scripts/register-startup.sh
set -euo pipefail

APP_DIR=/home/llm-deployment
if [[ ! -f "$APP_DIR/scripts/serve.sh" ]]; then
  echo "llm-deployment is not on this instance yet."
  exit 0
fi

mkdir -p "$APP_DIR/logs"
cd "$APP_DIR"
nohup bash scripts/serve.sh >>"$APP_DIR/logs/startup.log" 2>&1 &
