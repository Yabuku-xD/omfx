#!/usr/bin/env python3
"""Drive omfx under a pty and press Esc mid-turn.

Prints one line the shell parses:
  reached=<n> after_esc=<n> interrupted=<0|1>

Requires OMFX_PROVIDER + credentials, OMFX_E2E_ARGS, or OMFX_BASE_URL (mock).
"""

import sys

from e2e_lib import main_interrupt

if __name__ == "__main__":
    raise SystemExit(main_interrupt(sys.argv))
