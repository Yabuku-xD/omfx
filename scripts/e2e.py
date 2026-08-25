#!/usr/bin/env python3
"""Unified omfx end-to-end matrix.

  python3 scripts/e2e.py                  # all cases for current mode
  python3 scripts/e2e.py --case write     # one case
  python3 scripts/e2e.py --list-cases
  OMFX_E2E_OFFLINE=1 python3 scripts/e2e.py

Live cases need OMFX_PROVIDER + API key, or OMFX_E2E_ARGS.
Workspace cases (slash, models, skills) need --workspace PATH.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from e2e_lib import (
    InterruptResult,
    PtySession,
    free_port,
    has_live_credentials,
    isolated_home,
    main_interrupt,
    mock_provider_env,
    omfx_bin,
    plain_tui,
    provider_cli_args,
    run_interrupt_test,
    start_mock_server,
    strip_ansi,
)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent


@dataclass
class Case:
    name: str
    group: str  # offline | live | workspace
    fn: Callable[["Runner"], tuple[bool, str]]


class Runner:
    def __init__(self, binary: str, work_root: Path, offline: bool, workspace: Path | None):
        self.binary = binary
        self.work_root = work_root
        self.offline = offline
        self.workspace = workspace
        self.pass_n = 0
        self.fail_n = 0

    def ok(self, msg: str) -> None:
        self.pass_n += 1
        print(f"  PASS  {msg}")

    def bad(self, case: str, msg: str, detail: str = "") -> None:
        self.fail_n += 1
        print(f"  FAIL  {case}")
        print(f"     {msg}")
        if detail:
            for line in detail.strip().splitlines()[-15:]:
                print(f"       {line}")

    def case_dir(self, name: str) -> Path:
        d = self.work_root / name
        d.mkdir(parents=True, exist_ok=True)
        if name not in ("launch",):
            subprocess.run(["git", "init", "-q", "."], cwd=d, check=False)
        return d

    def ask(self, case_dir: Path, prompt: str, timeout: float = 300) -> str:
        argv = [self.binary, "ask", "--yolo"] + provider_cli_args() + [prompt]
        r = subprocess.run(
            argv,
            cwd=case_dir,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        out = (r.stdout or "") + (r.stderr or "")
        (case_dir / ".omfx-out").write_text(out, encoding="utf-8")
        return out

    def run_cmd(self, argv: list[str], cwd: Path | None = None, timeout: float = 60) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        if self.workspace:
            env.setdefault("HOME", str(Path.home()))
        return subprocess.run(
            argv,
            cwd=str(cwd or self.workspace or REPO),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )

    def pty_lines(self, lines: list[str], cwd: Path, timeout: float = 45, env: dict | None = None) -> str:
        sess = PtySession.spawn(self.binary, str(cwd), env=env)
        try:
            sess.pump(2.5)
            ready = False
            end = __import__("time").time() + timeout
            sent = 0
            last_send = 0.0
            while __import__("time").time() < end and sent < len(lines):
                sess.pump(0.3)
                text = plain_tui(sess.buf)
                if not ready and (
                    "enter send" in text.lower()
                    or "shift+tab" in text
                    or "yolo" in text.lower()
                    or "ask" in text.lower()
                ):
                    ready = True
                    __import__("time").sleep(0.3)
                if ready and __import__("time").time() - last_send > 0.8:
                    raw = lines[sent]
                    payload = raw.encode() if raw == "\x1b" else (raw + "\n").encode()
                    sess.write(payload)
                    sent += 1
                    last_send = __import__("time").time()
            if sent >= len(lines):
                __import__("time").sleep(1.2)
                try:
                    sess.write(b"/quit\n")
                except OSError:
                    pass
            sess.pump(2)
            return plain_tui(sess.buf)
        finally:
            sess.close()


# --- offline cases -----------------------------------------------------------

def case_launch(r: Runner) -> tuple[bool, str]:
    v = r.run_cmd([r.binary, "version"], cwd=REPO).stdout.strip()
    if not v:
        return False, "version empty"
    h = r.run_cmd([r.binary, "help"], cwd=REPO)
    if h.returncode != 0:
        return False, "help failed"
    return True, f"launch: {v}"


def case_interrupt_harness_unit(r: Runner) -> tuple[bool, str]:
    p = subprocess.run(
        ["zig", "build", "test", "--", "--test-filter", "interrupt harness"],
        cwd=REPO,
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        return False, (p.stderr or p.stdout)[-800:]
    return True, "interrupt harness unit tests pass"


def case_mock_interrupt(r: Runner) -> tuple[bool, str]:
    port = free_port()
    home = isolated_home()
    d = r.case_dir("mock-interrupt")
    server = start_mock_server(str(SCRIPT_DIR), port)
    try:
        env = mock_provider_env(port, home=home)
        result = run_interrupt_test(r.binary, str(d), env=env)
        ok, msg = result.ok(require_notice=True)
        return ok, msg if ok else msg + f"\n{plain_tui(result.raw)[-600:]}"
    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except Exception:
            server.kill()


def case_mock_steer(r: Runner) -> tuple[bool, str]:
    port = free_port()
    home = isolated_home()
    d = r.case_dir("mock-steer")
    server = start_mock_server(str(SCRIPT_DIR), port)
    marker = "steer-queued-test"
    try:
        env = mock_provider_env(port, home=home)
        sess = PtySession.spawn(r.binary, str(d), env=env)
        try:
            sess.pump(3.5)
            sess.write(b"count from 1 to 2000, one number per line, nothing else\r")
            sess.pump(6)
            from e2e_lib import highest_counting_line

            if highest_counting_line(sess.buf) < 3:
                return False, "counting never started before steer"
            sess.write(marker.encode())
            sess.pump(1.5)
            plain = plain_tui(sess.buf)
            if marker not in plain:
                return False, "steer text not visible during turn"
            sess.write(b"\r")
            sess.pump(2)
            sess.write(b"\x1b")
            sess.pump(4)
            plain = plain_tui(sess.buf)
            if marker not in plain:
                return False, "steer text lost after Enter/Esc"
            return True, "steer visible during turn and retained"
        finally:
            sess.close()
    finally:
        server.terminate()
        try:
            server.wait(timeout=3)
        except Exception:
            server.kill()


# --- live tool cases ---------------------------------------------------------

def case_write(r: Runner) -> tuple[bool, str]:
    d = r.case_dir("write")
    r.ask(d, 'Use the write tool to create hello.py containing exactly two lines: "def f():" then "    return 1"')
    got = (d / "hello.py").read_text(encoding="utf-8") if (d / "hello.py").is_file() else ""
    want = "def f():\n    return 1"
    got_norm = got.rstrip()
    return got_norm == want, f"got {got_norm!r}"


def case_edit(r: Runner) -> tuple[bool, str]:
    d = r.case_dir("edit")
    (d / "calc.py").write_text("def div(a, b):\n    return a / b\n", encoding="utf-8")
    r.ask(d, "In calc.py, make div return None when b is 0. Keep the rest of the function.")
    text = (d / "calc.py").read_text(encoding="utf-8")
    ok = "return None" in text and "b == 0" in text
    return ok, text[-400:]


def case_search(r: Runner) -> tuple[bool, str]:
    d = r.case_dir("search")
    (d / "src/deep/nested").mkdir(parents=True)
    (d / "src/deep/nested/target.zig").write_text("const MarkerSymbol = 1;\n", encoding="utf-8")
    (d / "top.txt").write_text("unrelated\n", encoding="utf-8")
    out = r.ask(d, "Find which file defines MarkerSymbol and reply with just its path.")
    ok = "src/deep/nested/target.zig" in out
    return ok, out[-800:]


def case_task(r: Runner) -> tuple[bool, str]:
    d = r.case_dir("task")
    (d / "calc.py").write_text("def add(a, b):\n    return a + b\n\ndef div(a, b):\n    return a / b\n", encoding="utf-8")
    (d / "test_calc.py").write_text("from calc import add\n\ndef test_add():\n    assert add(2, 3) == 5\n", encoding="utf-8")
    (d / ".gitignore").write_text("__pycache__/\n", encoding="utf-8")
    r.ask(d, "div crashes on a zero divisor. Make it return None instead, add a test for that case to test_calc.py, then run pytest and confirm both tests pass.")
    p = subprocess.run(["python3", "-m", "pytest", "-q"], cwd=d, capture_output=True, text=True)
    calc = (d / "calc.py").read_text(encoding="utf-8")
    tests = (d / "test_calc.py").read_text(encoding="utf-8")
    ok = p.returncode == 0 and "return None" in calc and "div" in tests
    return ok, (p.stdout or "") + (p.stderr or "")


def case_interrupt(r: Runner) -> tuple[bool, str]:
    d = r.case_dir("interrupt")
    if not has_live_credentials() and not os.environ.get("OMFX_BASE_URL"):
        return False, "no provider configured"
    out_path = d / ".omfx-out"
    p = subprocess.run(
        [sys.executable, str(SCRIPT_DIR / "e2e-interrupt.py"), r.binary, str(d)],
        capture_output=True,
        text=True,
    )
    out = (p.stdout or "") + (p.stderr or "")
    out_path.write_text(out, encoding="utf-8")
    if p.returncode != 0:
        return False, out[-800:]
    m = re.search(r"reached=(\d+) after_esc=(\d+)", out)
    if not m:
        return False, out[-800:]
    reached, after = int(m.group(1)), int(m.group(2))
    ir = InterruptResult(reached, after, "interrupted=1" in out, b"")
    ok, msg = ir.ok()
    return ok, msg


# --- workspace / live-ws cases -----------------------------------------------

def _ws(r: Runner) -> Path:
    if not r.workspace or not r.workspace.is_dir():
        raise RuntimeError("workspace case needs --workspace PATH")
    return r.workspace


def case_cli(r: Runner) -> tuple[bool, str]:
    ws = _ws(r)
    fails = []
    for name, check in (
        ("version", lambda o: "omfx" in o),
        ("help", lambda o: "ask" in o),
        ("doctor", lambda o: "provider=" in o),
    ):
        p = r.run_cmd([r.binary, name if name != "doctor" else "doctor"], cwd=ws)
        out = (p.stdout or "") + (p.stderr or "")
        if p.returncode != 0 or not check(out):
            fails.append(name)
    p = r.run_cmd([r.binary, "ask"], cwd=ws)
    if p.returncode == 0:
        fails.append("ask-no-prompt")
    p = r.run_cmd([r.binary, "not-a-command"], cwd=ws)
    if p.returncode == 0:
        fails.append("unknown-cmd")
    return len(fails) == 0, "failed: " + ", ".join(fails) if fails else "cli good/bad"


def case_slash_good(r: Runner) -> tuple[bool, str]:
    ws = _ws(r)
    cap = r.pty_lines(
        ["/version", "/stats", "/permissions ask", "/plan on", "/plan off", "/effort none", "/context", "\x1b", "/help plan"],
        ws,
        timeout=45,
    )
    checks = [
        "omfx" in cap.lower() or "0.0.1" in cap,
        "plan" in cap.lower(),
        "ask" in cap.lower() or "permission" in cap.lower(),
    ]
    return all(checks), cap[-1200:]


def case_slash_bad(r: Runner) -> tuple[bool, str]:
    ws = _ws(r)
    cap = r.pty_lines(
        ["/permissions nope", "/effort not-a-level", "/plan go", "/wake not-a-real-id", "/spec next"],
        ws,
        timeout=35,
    )
    ok = "plan" in cap.lower() or "no" in cap.lower() or "wake" in cap.lower()
    return ok, cap[-1200:]


def case_slash_sys(r: Runner) -> tuple[bool, str]:
    ws = _ws(r)
    cap = r.pty_lines(
        ["/checkpoint e2e-note", "/sleep e2e-sleep", "/wake list", "/spec list", "/handoff e2e handoff goal", "/compact"],
        ws,
        timeout=45,
    )
    ok = "checkpoint" in cap.lower() or "handoff" in cap.lower() or "compact" in cap.lower()
    return ok, cap[-1200:]


def case_features(r: Runner) -> tuple[bool, str]:
    ws = _ws(r)
    home = Path(os.environ.get("HOME", Path.home()))
    p = r.run_cmd(["zig", "test", "src/tools/fs.zig", "--test-filter", "directory"], cwd=REPO, timeout=90)
    if p.returncode != 0:
        return False, (p.stderr or p.stdout)[-600:]
    settings = home / ".omfx" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)
    try:
        data = json.loads(settings.read_text(encoding="utf-8")) if settings.is_file() else {}
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    data.setdefault("web_search", {"order": [], "exclude": [], "searxng_endpoint": ""})
    prov = os.environ.get("OMFX_PROVIDER", "commandcode")
    model = os.environ.get("OMFX_MODEL", "deepseek/deepseek-v4-flash")
    data["models"] = {prov: model}
    settings.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return True, "features smoke ok"


def _live_ask(r: Runner, prompt: str, timeout: float = 180) -> tuple[bool, str]:
    ws = _ws(r)
    argv = [r.binary, "ask", "--yolo", "--effort", "none"] + provider_cli_args() + [prompt]
    p = r.run_cmd(argv, cwd=ws, timeout=timeout)
    out = (p.stdout or "") + (p.stderr or "")
    return p.returncode == 0 and len(out.strip()) > 0, out


def case_models(r: Runner) -> tuple[bool, str]:
    _ws(r)
    ok, out = _live_ask(r, "Reply with exactly: PONG", timeout=120)
    return ok and "pong" in out.lower(), out[-1000:]


def case_skills(r: Runner) -> tuple[bool, str]:
    home = Path(os.environ.get("HOME", Path.home()))
    skill = "e2e-ping"
    skill_dir = home / ".omfx" / "skills" / skill
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        "---\nname: e2e-ping\ndescription: e2e harness skill\n---\n\nWhen invoked, reply with exactly: SKILL_OK\n",
        encoding="utf-8",
    )
    _ws(r)
    ok, out = _live_ask(r, f"/{skill} Follow the skill. One line only.", timeout=180)
    return ok and ("skill_ok" in out.lower() or "e2e-ping" in out.lower()), out[-1200:]


CASES: list[Case] = [
    Case("launch", "offline", case_launch),
    Case("interrupt-harness", "offline", case_interrupt_harness_unit),
    Case("mock-interrupt", "offline", case_mock_interrupt),
    Case("mock-steer", "offline", case_mock_steer),
    Case("write", "live", case_write),
    Case("edit", "live", case_edit),
    Case("search", "live", case_search),
    Case("task", "live", case_task),
    Case("interrupt", "live", case_interrupt),
    Case("cli", "workspace", case_cli),
    Case("slash-good", "workspace", case_slash_good),
    Case("slash-bad", "workspace", case_slash_bad),
    Case("slash-sys", "workspace", case_slash_sys),
    Case("features", "workspace", case_features),
    Case("models", "workspace", case_models),
    Case("skills", "workspace", case_skills),
]

CASE_MAP = {c.name: c for c in CASES}


def default_cases(offline: bool, workspace: Path | None) -> list[str]:
    if offline:
        return [c.name for c in CASES if c.group == "offline"]
    names = [c.name for c in CASES if c.group == "live"]
    if workspace:
        names += [c.name for c in CASES if c.group == "workspace"]
    return names


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="omfx unified e2e matrix")
    parser.add_argument("--case", action="append", help="run one case (repeatable)")
    parser.add_argument("--list-cases", action="store_true")
    parser.add_argument("--workspace", type=Path, help="workspace for pty/live-ws cases")
    parser.add_argument("legacy_case", nargs="?", help="compat: scripts/e2e.sh write")
    args = parser.parse_args(argv[1:])

    if args.list_cases:
        for c in CASES:
            print(f"{c.name}\t{c.group}")
        return 0

    offline = bool(os.environ.get("OMFX_E2E_OFFLINE"))
    binary = omfx_bin()
    if not os.access(binary, os.X_OK):
        print(f"no binary at {binary}; run: zig build", file=sys.stderr)
        return 2

    work_root = Path(tempfile.mkdtemp(prefix="omfx-e2e-"))
    workspace = args.workspace
    if workspace:
        workspace = workspace.resolve()

    selected: list[str] = []
    if args.case:
        selected = args.case
    elif args.legacy_case:
        selected = [args.legacy_case]
    else:
        selected = default_cases(offline, workspace)

    runner = Runner(binary, work_root, offline, workspace)
    print(f"bin={binary}\nmode={'offline' if offline else 'live'}\ncases={','.join(selected)}")

    for name in selected:
        case = CASE_MAP.get(name)
        if not case:
            runner.bad(name, f"unknown case (try --list-cases)")
            continue
        if offline and case.group != "offline":
            print(f"  SKIP  {name} (offline mode)")
            continue
        if case.group == "workspace" and not workspace:
            print(f"  SKIP  {name} (needs --workspace)")
            continue
        if case.group == "live" and not offline and not has_live_credentials() and not os.environ.get("OMFX_BASE_URL"):
            runner.bad(name, "no provider configured")
            continue
        try:
            ok, detail = case.fn(runner)
            if ok:
                runner.ok(f"{name}: {detail}" if detail else name)
            else:
                runner.bad(name, detail or "failed")
        except Exception as exc:
            runner.bad(name, str(exc))

    suffix = " (offline: model cases not run)" if offline else ""
    print(f"\n{runner.pass_n} passed, {runner.fail_n} failed{suffix}")
    return 0 if runner.fail_n == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
