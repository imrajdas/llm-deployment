#!/usr/bin/env bash
# Show the recorded JarvisLabs instance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"

require_jl
MID="$(resolve_machine_id "${1:-}")"
jl get "$MID"
