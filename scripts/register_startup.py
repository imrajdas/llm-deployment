#!/usr/bin/env python3
"""Register scripts/jarvislabs-startup.sh on the JarvisLabs account.

Prints the script id. Put that value in manifest.yaml at
jarvislabs.startup_script_id so new instances run it on boot.
Accounts can store at most 3 startup scripts.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT_NAME = "llm-deployment-serve"
SCRIPT_PATH = ROOT / "scripts" / "jarvislabs-startup.sh"


def main() -> int:
    try:
        from jarvislabs import Client, JarvislabsError
    except ImportError:
        print("Install operator dependencies: pip install -r requirements-operator.txt", file=sys.stderr)
        print("Then run: jl setup", file=sys.stderr)
        return 1

    body = SCRIPT_PATH.read_text(encoding="utf-8")
    try:
        with Client() as client:
            existing = next((item for item in client.scripts.list() if item.script_name == SCRIPT_NAME), None)
            if existing is None:
                client.scripts.add(script=body, name=SCRIPT_NAME)
                existing = next(
                    (item for item in client.scripts.list() if item.script_name == SCRIPT_NAME),
                    None,
                )
            else:
                client.scripts.update(script_id=existing.script_id, script=body)
    except JarvislabsError as exc:
        print(exc, file=sys.stderr)
        print("JarvisLabs stores at most 3 startup scripts per account.", file=sys.stderr)
        return 1

    if existing is None:
        print("Startup script upload succeeded, but the id was not listed yet.", file=sys.stderr)
        print("Open https://jarvislabs.ai settings, copy the script id, and set jarvislabs.startup_script_id.")
        return 1

    print(existing.script_id)
    print(
        f"Set jarvislabs.startup_script_id to {existing.script_id} in manifest.yaml",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
