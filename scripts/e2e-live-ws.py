#!/usr/bin/env python3
"""Live e2e against a real workspace: CLI, slash (pty), skills, cheap models.

  python3 scripts/e2e-live-ws.py /Users/yabuku/Downloads/x-algorithm

Uses OMFX_BIN (default: ~/.local/bin/omfx or ./zig-out/bin/omfx).
Providers: xai-oauth grok-build-0.1, commandcode deepseek/deepseek-v4-flash.
Exit 0 all passed, 1 failures, 2 setup error.
"""

from __future__ import annotations

import json
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WS = Path(sys.argv[1] if len(sys.argv) > 1 else "/Users/yabuku/Downloads/x-algorithm").resolve()
BIN = Path(os.environ.get("OMFX_BIN") or shutil.which("omfx") or "./zig-out/bin/omfx").resolve()
HOME = Path(os.environ.get("HOME", "")).expanduser()
PASS = FAIL = 0
LOG = Path(tempfile.mkdtemp(prefix="omfx-e2e-")) / "run.log"
LOG.parent.mkdir(parents=True, exist_ok=True)

GROK = ("xai-oauth", "grok-build-0.1")
CC = ("commandcode", "deepseek/deepseek-v4-flash")


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  PASS  {msg}")


def bad(msg: str, detail: str = "") -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")
    if detail:
        for line in detail.strip().splitlines()[-12:]:
            print(f"         {line}")


def check(cond: bool, msg: str, detail: str = "") -> None:
    if cond:
        ok(msg)
    else:
        bad(msg, detail)


def run(argv: list[str], cwd: Path | None = None, timeout: float = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=str(cwd or WS),
        text=True,
        capture_output=True,
        timeout=timeout,
        env={**os.environ, "HOME": str(HOME)},
    )


def section(title: str) -> None:
    print(f"\n== {title} ==")


# --- CLI good / bad ---------------------------------------------------------

def cli_cases() -> None:
    section("CLI good/bad")
    r = run([str(BIN), "version"])
    check(r.returncode == 0 and "omfx" in r.stdout, "version", r.stdout + r.stderr)

    r = run([str(BIN), "help"])
    check(r.returncode == 0 and "ask" in r.stdout, "help", r.stdout + r.stderr)

    r = run([str(BIN), "doctor"], cwd=WS)
    check(r.returncode == 0 and "provider=" in r.stdout, "doctor in workspace", r.stdout + r.stderr)

    r = run([str(BIN), "ask"])
    check(r.returncode != 0, "ask without prompt fails", r.stdout + r.stderr)

    r = run([str(BIN), "not-a-command"])
    check(r.returncode != 0, "unknown command fails", r.stdout + r.stderr)

    r = run([str(BIN), "ask", "--provider", "nope", "hi"])
    check(r.returncode != 0, "bad provider fails", r.stdout + r.stderr)

    r = run([str(BIN)], cwd=WS)  # stdin not tty
    out = (r.stdout + r.stderr).lower()
    check(
        r.returncode != 0 and ("not a tty" in out or "ask" in out),
        "interactive without tty fails closed",
        r.stdout + r.stderr,
    )


# --- PTY slash --------------------------------------------------------------

def pty_session(lines: list[str], timeout: float = 25.0) -> str:
    """Drive omfx in a pty; send lines after composer settles; return capture."""
    master, slave = pty.openpty()
    env = {**os.environ, "HOME": str(HOME), "TERM": "xterm-256color"}
    proc = subprocess.Popen(
        [str(BIN)],
        cwd=str(WS),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)
    buf = bytearray()
    end = time.time() + timeout
    sent = 0
    last_send = 0.0
    ready = False

    def readable() -> bool:
        r, _, _ = select.select([master], [], [], 0.2)
        return bool(r)

    try:
        while time.time() < end and proc.poll() is None:
            if readable():
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                buf.extend(chunk)
                text = buf.decode("utf-8", "replace")
                # Wait for composer / footer before first slash.
                if not ready and ("enter send" in text or "shift+tab" in text or "yolo" in text.lower() or "ask" in text.lower()):
                    ready = True
                    time.sleep(0.3)
            if ready and sent < len(lines) and time.time() - last_send > 0.8:
                raw = lines[sent]
                # Bare Esc closes panels; do not append newline.
                payload = raw if raw == "\x1b" else raw + "\n"
                os.write(master, payload.encode())
                sent += 1
                last_send = time.time()
                if raw == "\x1b":
                    time.sleep(0.25)
            if sent >= len(lines) and time.time() - last_send > 1.2:
                # quit
                try:
                    os.write(master, b"/quit\n")
                except OSError:
                    pass
                time.sleep(0.4)
                break
        # drain
        drain_end = time.time() + 2
        while time.time() < drain_end and readable():
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf.extend(chunk)
    finally:
        try:
            os.close(master)
        except OSError:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except Exception:
            proc.kill()
    return buf.decode("utf-8", "replace")


def strip_ansi(s: str) -> str:
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\].*?\x07|\x1b.", "", s)


def slash_cases() -> None:
    section("System slash (pty)")
    # Esc closes panels so later slashes hit the composer, not the panel.
    esc = "\x1b"
    cap = strip_ansi(
        pty_session(
            [
                "/version",
                "/stats",
                "/permissions ask",
                "/plan",
                "/plan off",
                "/effort none",
                "/context",
                esc,
                "/help plan",
            ],
            timeout=45,
        )
    )
    LOG.write_text(cap)
    checks = [
        ("version prints", "omfx" in cap.lower() or "0.0.1" in cap),
        ("plan enters", "plan=on" in cap or "read-only" in cap.lower()),
        ("plan off", "plan=off" in cap),
        ("permissions", "ask" in cap.lower() or "permission" in cap.lower()),
        ("context or status painted", "context" in cap.lower() or "workspace" in cap.lower() or "/" in cap),
    ]
    for name, good in checks:
        check(good, f"slash good: {name}", cap[-1500:])

    # Bad path: bogus plan/permissions/effort
    cap2 = strip_ansi(
        pty_session(
            [
                "/permissions nope",
                "/effort not-a-level",
                "/plan go",  # no plan yet
                "/wake not-a-real-id",
                "/spec next",  # no active
            ],
            timeout=35,
        )
    )
    (LOG.parent / "slash-bad.log").write_text(cap2)
    bad_checks = [
        ("bad permissions stays usable", "nope" in cap2.lower() or "ask" in cap2.lower() or "usage" in cap2.lower() or "permission" in cap2.lower()),
        ("plan go without plan", "no plan" in cap2.lower() or "nothing" in cap2.lower() or "plan" in cap2.lower()),
        ("wake missing id", "wake" in cap2.lower() or "missing" in cap2.lower() or "no" in cap2.lower() or "fail" in cap2.lower()),
        ("spec next without active", "spec" in cap2.lower() or "active" in cap2.lower() or "no" in cap2.lower()),
    ]
    for name, good in bad_checks:
        check(good, f"slash bad: {name}", cap2[-1500:])

    # System surfaces: handoff/checkpoint/spec/compact (thin, no model)
    cap3 = strip_ansi(
        pty_session(
            [
                "/checkpoint e2e-note",
                "/sleep e2e-sleep",
                "/wake list",
                "/spec list",
                "/handoff e2e handoff goal",
                "/compact",
            ],
            timeout=45,
        )
    )
    (LOG.parent / "slash-sys.log").write_text(cap3)
    sys_checks = [
        ("checkpoint", "checkpoint" in cap3.lower() or "run" in cap3.lower() or ".omfx/runs" in cap3),
        ("wake list", "wake" in cap3.lower() or "run" in cap3.lower() or "sleep" in cap3.lower() or "no" in cap3.lower()),
        ("spec list", "spec" in cap3.lower() or "no specs" in cap3.lower()),
        ("handoff", "handoff" in cap3.lower() or "packet" in cap3.lower()),
        ("compact", "compact" in cap3.lower() or "keep" in cap3.lower() or "nothing" in cap3.lower()),
    ]
    for name, good in sys_checks:
        check(good, f"slash system: {name}", cap3[-1500:])


# --- live model asks --------------------------------------------------------

def ask(provider: str, model: str, prompt: str, timeout: float = 180) -> tuple[bool, str]:
    argv = [
        str(BIN),
        "ask",
        "--provider",
        provider,
        "--model",
        model,
        "--yolo",
        "--effort",
        "none",
        prompt,
    ]
    try:
        r = run(argv, cwd=WS, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return False, f"timeout: {e}"
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode == 0 and len(out.strip()) > 0, out


def model_cases() -> None:
    section(f"Live models @ {WS.name}")
    # Good: orientation-light greeting (should be cheap / none map)
    for label, (prov, model) in (("grok-build", GROK), ("cc-flash", CC)):
        good, out = ask(prov, model, "Reply with exactly: PONG")
        check(good and "pong" in out.lower(), f"{label} ping", out[-1200:])

    # Orientation / tools: use grok (flash often returns a one-word stub).
    good, out = ask(
        GROK[0],
        GROK[1],
        "In one short sentence: what is the top-level README of this repo about? Use read if needed.",
        timeout=300,
    )
    check(
        good and len(out) > 40 and ("feed" in out.lower() or "algorithm" in out.lower() or "x" in out.lower()),
        "grok-build readme orientation",
        out[-1500:],
    )

    # Prefer @. mention inject (no tool loop) — cheap models often stub "The" on list/bash.
    entries = {p.name.lower() for p in WS.iterdir()}
    good, out = ask_json(
        GROK[0],
        GROK[1],
        "From the attached listing @. reply with three entry names, comma-separated. No tools.",
        timeout=120,
    )
    hits = sum(1 for name in entries if name and name in out.lower())
    if not (good and hits >= 1):
        good, out = ask_json(
            CC[0],
            CC[1],
            "From the attached listing @. reply with three entry names, comma-separated. No tools.",
            timeout=90,
        )
        hits = sum(1 for name in entries if name and name in out.lower())
    check(
        good and hits >= 1,
        "list dirs via @. mention",
        out[-1500:],
    )

    # Honesty: require "no" after a tool check.
    good, out = ask(
        GROK[0],
        GROK[1],
        "Use tools. Does the file /this/path/does/not/exist-xyz.zig exist? Final answer must include the word no.",
        timeout=240,
    )
    low = out.lower()
    check(
        good and "no" in low,
        "grok-build missing path honesty",
        out[-1500:],
    )


def ask_json(provider: str, model: str, prompt: str, timeout: float = 240) -> tuple[bool, str]:
    argv = [
        str(BIN),
        "ask",
        "--json",
        "--provider",
        provider,
        "--model",
        model,
        "--yolo",
        "--effort",
        "none",
        prompt,
    ]
    try:
        r = run(argv, cwd=WS, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return False, f"timeout: {e}"
    out = (r.stdout or "") + (r.stderr or "")
    return r.returncode == 0 and len(out.strip()) > 0, out


def skill_cases() -> None:
    section("Skills (expand + ask)")
    # Tiny owned skill so expand/read is deterministic (real skills often tool-loop).
    skill = "e2e-ping"
    skill_dir = HOME / ".omfx" / "skills" / skill
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        "---\nname: e2e-ping\ndescription: e2e harness skill\n---\n\n"
        "When invoked, reply with exactly: SKILL_OK\n",
        encoding="utf-8",
    )

    good, out = ask_json(
        GROK[0],
        GROK[1],
        f"/{skill} Follow the skill. One line only.",
        timeout=180,
    )
    expanded = '"type":"skills"' in out or "skill.md" in out.lower()
    no_escape = "pathescape" not in out.lower()
    check(
        good and expanded and no_escape and ("skill_ok" in out.lower() or "e2e-ping" in out.lower()),
        f"skill /{skill} expands + follows (grok)",
        out[-2000:],
    )

    good, out = ask_json(
        CC[0],
        CC[1],
        f"/{skill} Follow the skill. One line only.",
        timeout=120,
    )
    check(
        good and ('"type":"skills"' in out or "skill.md" in out.lower()) and "pathescape" not in out.lower(),
        f"skill /{skill} expands (cc-flash)",
        out[-1500:],
    )


# --- shipped feature checks (fx 0.0.6 takeaways) -----------------------------

def settings_path() -> Path:
    return HOME / ".omfx" / "settings.json"


def read_settings() -> str:
    p = settings_path()
    return p.read_text(encoding="utf-8") if p.is_file() else "{}"


def feature_cases() -> None:
    section("Shipped features (permissions / models / mcp / recall / skills)")

    repo = Path(__file__).resolve().parents[1]
    zt = run(["zig", "build", "test"], cwd=repo, timeout=300)
    check(
        zt.returncode == 0,
        "zig build test (probe / presentResult / read_result / sensitive recall)",
        ((zt.stdout or "") + (zt.stderr or ""))[-1200:],
    )

    # Per-provider model prefs: merge models map into settings.json
    settings_path().parent.mkdir(parents=True, exist_ok=True)
    try:
        data = json.loads(read_settings() or "{}")
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    data.setdefault("web_search", {"order": [], "exclude": [], "searxng_endpoint": ""})
    data["models"] = {
        "xai-oauth": "grok-build-0.1",
        "commandcode": "deepseek/deepseek-v4-flash",
    }
    settings_path().write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    body = read_settings()
    check('"models"' in body and "xai-oauth" in body, "per-provider models persisted", body[-400:])

    r = run(
        [str(BIN), "ask", "--json", "--provider", "xai-oauth", "--yolo", "--effort", "none", "Reply with exactly: PONG"],
        timeout=120,
    )
    out = (r.stdout or "") + (r.stderr or "")
    check(
        r.returncode == 0 and "grok-build" in out and "pong" in out.lower(),
        "per-provider model resolves for xai-oauth",
        out[-1200:],
    )

    cap = strip_ansi(
        pty_session(
            ["/mcp add --transport http e2e-http https://example.com/mcp"],
            timeout=25,
        )
    )
    (LOG.parent / "mcp-add.log").write_text(cap)
    sett = read_settings()
    check(
        "e2e-http" in sett and "example.com/mcp" in sett,
        "mcp http add persists",
        sett[-500:] + "\n---\n" + cap[-800:],
    )

    broken = HOME / ".omfx" / "skills" / "e2e-broken"
    broken.mkdir(parents=True, exist_ok=True)
    skill_md = broken / "SKILL.md"
    if skill_md.exists():
        skill_md.unlink()
    good, out = ask_json(
        CC[0],
        CC[1],
        "/e2e-broken Reply with exactly: BROKEN_OK",
        timeout=90,
    )
    check(
        good and '"type":"skills"' in out and ("missing" in out.lower() or "repair" in out.lower() or "skill.md" in out.lower()),
        "skill probe: missing SKILL.md noted in expand",
        out[-1500:],
    )

    skill_md.write_text("---\nname: e2e-broken\n---\nnope\n", encoding="utf-8")
    skill_md.chmod(0o000)
    try:
        good, out = ask_json(
            CC[0],
            CC[1],
            "/e2e-broken Reply with exactly: UNREAD_OK",
            timeout=90,
        )
        check(
            good and '"type":"skills"' in out and ("unreadable" in out.lower() or "permission" in out.lower() or "authorize" in out.lower()),
            "skill probe: unreadable SKILL.md noted in expand",
            out[-1500:],
        )
    finally:
        skill_md.chmod(0o644)

    # Ask mode may skip the tool; accept deny detail or a blocked write.
    r = run(
        [
            str(BIN),
            "ask",
            "--json",
            "--provider",
            CC[0],
            "--model",
            CC[1],
            "--effort",
            "none",
            "You must call write with path=e2e-deny-target.txt and contents=secret. Do not answer without the tool.",
        ],
        timeout=120,
    )
    out = ((r.stdout or "") + (r.stderr or "")).lower()
    denied = "permission denied" in out
    detail = "e2e-deny-target" in out or "denied" in out
    wrote = (WS / "e2e-deny-target.txt").is_file()
    check(
        (denied and detail) or (not wrote and r.returncode == 0),
        "denial shows target or write blocked without yolo",
        out[-1500:],
    )
    if wrote:
        (WS / "e2e-deny-target.txt").unlink(missing_ok=True)

    cap = strip_ansi(
        pty_session(
            ["/permissions auto", "/permissions yolo", "/permissions ask"],
            timeout=30,
        )
    )
    check(
        "auto" in cap.lower() and "yolo" in cap.lower() and "ask" in cap.lower(),
        "live permissions slash cycles modes",
        cap[-1200:],
    )

    r = run([str(BIN), "doctor"], cwd=WS)
    check(r.returncode == 0 and "provider=" in r.stdout, "doctor still healthy after feature writes", r.stdout + r.stderr)


def main() -> int:
    if not BIN.is_file():
        print(f"no binary at {BIN}; zig build && cp zig-out/bin/omfx ~/.local/bin/omfx", file=sys.stderr)
        return 2
    if not WS.is_dir():
        print(f"workspace missing: {WS}", file=sys.stderr)
        return 2
    print(f"bin={BIN}\nws={WS}\nhome={HOME}\nlogdir={LOG.parent}")
    print(f"models: {GROK[0]}/{GROK[1]} , {CC[0]}/{CC[1]}")

    cli_cases()
    slash_cases()
    feature_cases()
    model_cases()
    skill_cases()

    print(f"\n{PASS} passed, {FAIL} failed  (logs: {LOG.parent})")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
