#!/usr/bin/env bash
# Unified end-to-end matrix. See scripts/e2e.py --list-cases
exec python3 "$(cd "$(dirname "$0")" && pwd)/e2e.py" "$@"
