#!/usr/bin/env python3
"""Legacy wrapper — use scripts/e2e.py --workspace PATH instead."""

import sys
from pathlib import Path

from e2e import main as matrix_main


def main() -> int:
    ws = Path(sys.argv[1] if len(sys.argv) > 1 else Path.cwd())
    cases = ["cli", "slash-good", "slash-bad", "slash-sys", "features", "models", "skills"]
    argv = [sys.argv[0], "--workspace", str(ws.resolve())]
    for c in cases:
        argv += ["--case", c]
    return matrix_main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
