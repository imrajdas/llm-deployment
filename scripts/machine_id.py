#!/usr/bin/env python3
"""Print machine_id from a JarvisLabs JSON document on stdin."""

from __future__ import annotations

import json
import sys
from typing import Any


def find(obj: Any, key: str) -> Any:
    if isinstance(obj, dict):
        if key in obj and obj[key] not in (None, ""):
            return obj[key]
        for value in obj.values():
            found = find(value, key)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = find(item, key)
            if found is not None:
                return found
    return None


def main() -> int:
    data = json.load(sys.stdin)
    machine_id = find(data, "machine_id")
    if machine_id is None:
        print("JSON did not include machine_id.", file=sys.stderr)
        return 1
    print(machine_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
