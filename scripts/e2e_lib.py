#!/usr/bin/env python3
"""Shared helpers for omfx end-to-end scripts (pty, ANSI, provider env)."""

from __future__ import annotations

from contextlib import contextmanager
import os
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

CUP = re.compile(r"\x1b\[[0-9;]*[Hf]")
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][B0]|\x1b[=>]")


def omfx_bin() -> str:
    raw = os.environ.get("OMFX_BIN") or "./zig-out/bin/omfx"
    path = shutil.which(raw) or raw
    return os.path.abspath(path)


def provider_cli_args() -> list[str]:
    extra = os.environ.get("OMFX_E2E_ARGS", "").strip()
    if extra:
        return extra.split()
    argv: list[str] = []
    provider = os.environ.get("OMFX_PROVIDER")
    model = os.environ.get("OMFX_MODEL")
    if provider:
        argv += ["--provider", provider]
    if model:
        argv += ["--model", model]
    return argv


_PROVIDER_KEYS = (
    "OMFX_PROVIDER",
    "OMFX_MODEL",
    "OMFX_BASE_URL",
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "COMMANDCODE_API_KEY",
    "GROQ_API_KEY",
    "XAI_API_KEY",
    "OMFX_API_KEY",
)


def provider_env(base: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ)
    if base:
        env.update(base)
    return env


def has_live_credentials(env: dict[str, str] | None = None) -> bool:
    e = provider_env(env)
    if e.get("OMFX_BASE_URL"):
        return True
    if e.get("OMFX_PROVIDER") and (
        e.get("COMMANDCODE_API_KEY")
        or e.get("OPENAI_API_KEY")
        or e.get("ANTHROPIC_API_KEY")
        or e.get("GROQ_API_KEY")
        or e.get("XAI_API_KEY")
        or e.get("OMFX_API_KEY")
    ):
        return True
    for key in (
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "COMMANDCODE_API_KEY",
        "GROQ_API_KEY",
        "XAI_API_KEY",
    ):
        if e.get(key):
            return True
    return False


def plain_tui(raw: bytes) -> str:
    return ANSI.sub("", CUP.sub("\n", raw.decode("utf8", "replace")))


def strip_ansi(s: str) -> str:
    return ANSI.sub("", s)


def highest_counting_line(raw: bytes) -> int:
    plain = plain_tui(raw)
    seen = [int(n) for n in re.findall(r"^\s*(\d{1,4})\s*$", plain, re.M)]
    return max(seen, default=0)


def saw_interrupted(raw: bytes) -> bool:
    return "Interrupted" in plain_tui(raw)


@dataclass
class InterruptResult:
    reached: int
    after_esc: int
    interrupted: bool
    raw: bytes

    def ok(
        self,
        *,
        min_reached: int = 3,
        max_after: int = 1900,
        max_delta: int = 60,
        require_notice: bool = False,
    ) -> tuple[bool, str]:
        if self.reached <= min_reached:
            return False, f"counting never started (reached={self.reached})"
        if self.after_esc >= max_after:
            return False, f"still counting after Esc (after_esc={self.after_esc})"
        delta = self.after_esc - self.reached
        if delta >= max_delta:
            return False, f"kept counting after Esc (delta={delta})"
        if require_notice and not self.interrupted:
            return False, "Esc stopped counting but no Interrupted notice in transcript"
        return True, f"reached={self.reached} after_esc={self.after_esc}"


@dataclass
class PtySession:
    binary: str
    workdir: str
    argv: list[str]
    env: dict[str, str]
    fd: int
    pid: int
    buf: bytes = b""

    @classmethod
    def spawn(
        cls,
        binary: str,
        workdir: str,
        *,
        argv_tail: list[str] | None = None,
        env: dict[str, str] | None = None,
    ) -> PtySession:
        argv = [binary] + (argv_tail or [])
        child_env = provider_env(env)
        child_env.setdefault("TERM", "xterm-256color")
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(workdir)
            os.execvpe(binary, argv, child_env)
        return cls(binary, workdir, argv, child_env, fd, pid)

    def pump(self, seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.2)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.buf += chunk

    def write(self, data: bytes) -> None:
        os.write(self.fd, data)

    def close(self, grace: float = 0.5) -> None:
        try:
            self.write(b"\x03")
        except OSError:
            pass
        self.pump(grace)
        try:
            os.close(self.fd)
        except OSError:
            pass


def run_interrupt_test(
    binary: str,
    workdir: str,
    *,
    env: dict[str, str] | None = None,
    warmup: float = 3.5,
    pre_esc: float = 8.0,
    post_esc: float = 8.0,
    prompt: bytes = b"count from 1 to 2000, one number per line, nothing else\r",
) -> InterruptResult:
    sess = PtySession.spawn(binary, workdir, env=env)
    try:
        sess.pump(warmup)
        sess.write(prompt)
        sess.pump(pre_esc)
        reached = highest_counting_line(sess.buf)
        sess.write(b"\x1b")
        sess.pump(post_esc)
        after = highest_counting_line(sess.buf)
        interrupted = saw_interrupted(sess.buf)
        return InterruptResult(reached, after, interrupted, sess.buf)
    finally:
        sess.close()


def start_mock_server(script_dir: str, port: int = 8765) -> subprocess.Popen[str]:
    stub = os.path.join(script_dir, "omfx_stub.py")
    if not os.path.isfile(stub):
        raise FileNotFoundError(stub)
    proc = subprocess.Popen(
        [sys.executable, stub],
        cwd=script_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**os.environ, "OMFX_STUB_PORT": str(port)},
    )
    deadline = time.time() + 10
    while time.time() < deadline:
        if proc.poll() is not None:
            out = proc.stdout.read() if proc.stdout else ""
            raise RuntimeError(f"mock server exited early: {out}")
        if proc.stdout and proc.stdout.readline().strip():
            break
        time.sleep(0.05)
    return proc


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


@contextmanager
def isolated_home_ctx():
    home = tempfile.mkdtemp(prefix="omfx-e2e-")
    try:
        yield home
    finally:
        shutil.rmtree(home, ignore_errors=True)


def isolated_home() -> str:
    return tempfile.mkdtemp(prefix="omfx-e2e-")


def mock_provider_env(port: int = 8765, home: str | None = None) -> dict[str, str]:
    env = {
        "OMFX_PROVIDER": "openai",
        "OMFX_MODEL": "gpt-4o",
        "OPENAI_API_KEY": "e2e-mock-key",
        "OMFX_BASE_URL": f"http://127.0.0.1:{port}/v1",
    }
    if home:
        env["HOME"] = home
    return env


def main_interrupt(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: e2e-interrupt.py <omfx-binary> <workdir>", file=sys.stderr)
        return 2
    binary, workdir = argv[1], argv[2]
    if not has_live_credentials() and not os.environ.get("OMFX_BASE_URL"):
        print(
            "no provider configured: set OMFX_PROVIDER + API key, "
            "OMFX_E2E_ARGS, or OMFX_BASE_URL for mock",
            file=sys.stderr,
        )
        return 2
    result = run_interrupt_test(binary, workdir)
    print("reached=%d after_esc=%d interrupted=%d" % (
        result.reached,
        result.after_esc,
        int(result.interrupted),
    ))
    ok, _ = result.ok()
    return 0 if ok else 1
