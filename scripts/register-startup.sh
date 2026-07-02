#!/usr/bin/env bash
# Upload scripts/jarvislabs-startup.sh to the JarvisLabs account (max 3 scripts).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/scripts/register_startup.py"
