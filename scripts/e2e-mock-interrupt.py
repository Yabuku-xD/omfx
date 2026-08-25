#!/usr/bin/env python3
"""Offline interrupt e2e: mock OpenAI server streams counting, Esc must stop it."""

import os
import sys

from e2e_lib import (
    free_port,
    isolated_home_ctx,
    mock_provider_env,
    plain_tui,
    run_interrupt_test,
    start_mock_server,
)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: e2e-mock-interrupt.py <omfx-binary> <workdir>", file=sys.stderr)
        return 2
    binary, workdir = argv[1], argv[2]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    port = free_port()
    server = start_mock_server(script_dir, port)
    try:
        with isolated_home_ctx() as home:
            env = mock_provider_env(port, home=home)
            result = run_interrupt_test(binary, workdir, env=env)
            print(
                "reached=%d after_esc=%d interrupted=%d"
                % (result.reached, result.after_esc, int(result.interrupted))
            )
            ok, msg = result.ok(require_notice=True)
            if not ok:
                print("mock-interrupt: %s" % msg, file=sys.stderr)
                tail = plain_tui(result.raw)[-1200:]
                if tail.strip():
                    print("transcript tail:", file=sys.stderr)
                    for line in tail.strip().splitlines()[-15:]:
                        print("  %s" % line, file=sys.stderr)
                return 1
            return 0
    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except Exception:
            server.kill()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
